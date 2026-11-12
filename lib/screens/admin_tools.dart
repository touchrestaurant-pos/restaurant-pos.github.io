import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../data/local_store.dart';
import '../data/sync_service.dart';
import '../receipt/download_file.dart';
import '../receipt/receipt_service.dart';
import '../theme.dart';

SupabaseClient get _db => Supabase.instance.client;

const _backupTables = [
  'company_settings',
  'staff_profiles',
  'categories',
  'products',
  'modifiers',
  'suppliers',
  'stock_items',
  'recipe_lines',
  'grvs',
  'grv_lines',
  'stock_movements',
  'orders',
  'order_items',
  'payments',
  'refunds',
  'cash_ups',
  'purchase_orders',
  'purchase_order_lines',
];

/// This device's printing, backups, clearing test sales, and the problem log.
class AdminTools extends StatefulWidget {
  const AdminTools({super.key});

  @override
  State<AdminTools> createState() => _AdminToolsState();
}

class _AdminToolsState extends State<AdminTools> {
  bool _busy = false;
  String? _status;
  List<Map<String, dynamic>> _errors = [];
  bool _errorsLoaded = false;

  void _say(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _backup() async {
    setState(() {
      _busy = true;
      _status = 'Downloading every table...';
    });
    try {
      final out = <String, dynamic>{
        'app': 'RestoPOS',
        'version': AppConfig.appVersion,
        'made_at': DateTime.now().toUtc().toIso8601String(),
      };
      for (final t in _backupTables) {
        final rows = <dynamic>[];
        for (var from = 0;; from += 1000) {
          final page = await _db.from(t).select().range(from, from + 999);
          rows.addAll(page);
          if (page.length < 1000) break;
        }
        out[t] = rows;
        if (mounted) setState(() => _status = 'Downloaded $t (${rows.length})');
      }
      final bytes = Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent(' ').convert(out)));
      final d = DateTime.now();
      await downloadBytes(
          'restopos-backup-${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}.json',
          bytes,
          'application/json');
      _status = 'Backup saved. Keep it somewhere safe, such as Google Drive or a USB stick.';
    } on PostgrestException catch (e) {
      _status = 'Backup failed: ${e.message}';
    } catch (_) {
      _status = 'Backup needs an internet connection.';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _clearSales() async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Clear all sales?'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text(
                  'Use this once, before you start trading, to remove test orders. It deletes every order, payment, refund and cash-up, '
                  'puts back the stock those sales used, and starts invoice numbers again at 1. '
                  'The menu, recipes, stock items, deliveries, suppliers and staff stay. This cannot be undone, so download a backup first.'),
              const SizedBox(height: 12),
              TextField(
                controller: c,
                onChanged: (_) => set(() {}),
                decoration: const InputDecoration(labelText: 'Type DELETE to confirm'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Brand.red, foregroundColor: Colors.white),
              onPressed: c.text.trim() == 'DELETE' ? () => Navigator.pop(ctx, true) : null,
              child: const Text('Clear all sales'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final res = await _db.rpc('clear_test_sales', params: {'p_confirm': 'DELETE'});
      // Drop this device's copies and anything still waiting to be sent for sales.
      for (final t in ['orders', 'order_items', 'payments']) {
        await LocalStore.setRows(t, []);
      }
      for (final e in LocalStore.pending()) {
        if (const ['orders', 'order_items', 'payments'].contains(e.value['table'])) {
          await LocalStore.removePending(e.key);
        }
      }
      await SyncService.instance.syncNow();
      _say('Cleared ${(res as Map)['orders_removed']} orders. Other tills clear when they next sync.');
    } on PostgrestException catch (e) {
      _say(e.message);
    } catch (_) {
      _say('This needs an internet connection.');
    }
    if (mounted) setState(() => _busy = false);
  }

  List<Map<String, dynamic>> _audit = [];
  bool _auditLoaded = false;
  String _auditFilter = 'all';

  static const _auditNames = {
    'all': 'Everything',
    'approval': 'Manager approvals',
    'cash_movements': 'Money out of tills',
    'cash_ups': 'Cash-ups',
    'refunds': 'Refunds',
    'grvs': 'Stock received',
    'stocktakes': 'Stock-takes',
    'products': 'Menu items',
    'stock_items': 'Stock items',
    'staff_profiles': 'Staff',
    'company_settings': 'Settings',
    'customer_accounts': 'Customer accounts',
    'order_items': 'Price differences',
  };

  Future<void> _loadAudit() async {
    try {
      var q = _db.from('audit_log').select();
      if (_auditFilter != 'all') q = q.eq('table_name', _auditFilter);
      final rows = await q.order('at', ascending: false).limit(300);
      _audit = rows.map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {
      _say('The change history needs an internet connection.');
    }
    if (mounted) setState(() => _auditLoaded = true);
  }

  /// "price: 49.9 -> 54.9" for edits, the name for new or deleted rows.
  String _auditText(Map<String, dynamic> a) {
    final c = a['changes'];
    if (c is! Map) return '${a['row_id'] ?? ''}';
    if (a['action'] == 'update') {
      return c.entries.map((e) => e.value is List ? '${e.key}: ${e.value[0]} -> ${e.value[1]}' : '${e.key}').join(', ');
    }
    if (a['table_name'] == 'approval') {
      return a['action'] == 'failed' ? 'wrong PIN typed (${c['what'] ?? ''})' : '${c['approved_by']} approved ${c['what']}: ${c['detail'] ?? ''}';
    }
    if (a['action'] == 'insert' && c.containsKey('amount')) return '${c['category'] ?? c['kind'] ?? ''} R${c['amount']} ${c['reference'] ?? ''} ${c['note'] ?? ''}'.trim();
    if (a['action'] == 'price_differs') return '${c['item']} charged ${c['charged']}, menu price ${c['menu_price']}';
    return '${c['name'] ?? c['full_name'] ?? a['row_id'] ?? ''}';
  }

  Future<void> _loadErrors() async {
    try {
      final rows = await _db
          .from('app_errors')
          .select('created_at, message, platform, app_version, user_id')
          .order('created_at', ascending: false)
          .limit(30);
      _errors = rows.map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {
      final local = ((LocalStore.getMeta('errors') as List?) ?? const []).reversed;
      _errors = [for (final e in local) Map<String, dynamic>.from(e as Map)..['created_at'] = (e)['at']];
    }
    if (mounted) setState(() => _errorsLoaded = true);
  }

  Future<void> _clearErrors() async {
    try {
      await _db.from('app_errors').delete().gte('created_at', '2000-01-01');
    } catch (_) {}
    await LocalStore.removeMeta('errors');
    await _loadErrors();
  }

  @override
  Widget build(BuildContext context) {
    final printer = savedPrinterName();
    Widget card(String title, List<Widget> children) => Card(
          margin: const EdgeInsets.only(bottom: 16),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              ...children,
            ]),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      card('This device', [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Print the receipt automatically after payment'),
          value: autoPrintOn(),
          onChanged: (v) async {
            await setAutoPrint(v);
            setState(() {});
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Print a kitchen ticket when an order is sent'),
          subtitle: const Text('Item names and special requests in large print, no prices'),
          value: kitchenTicketOn(),
          onChanged: (v) async {
            await setKitchenTicket(v);
            setState(() {});
          },
        ),
        Row(children: [
          const Expanded(child: Text('Slip paper')),
          DropdownButton<int>(
            value: slipPaperMm(),
            items: const [
              DropdownMenuItem(value: 80, child: Text('80 mm')),
              DropdownMenuItem(value: 58, child: Text('58 mm')),
            ],
            onChanged: (v) async {
              await LocalStore.setMeta('slip_paper_mm', v ?? 80);
              setState(() {});
            },
          ),
        ]),
        if (kIsWeb)
          const Text(
              'In a browser the print window always opens. For one-click printing use the Windows or Android app, '
              'or start Chrome with the --kiosk-printing option on the till computer.',
              style: TextStyle(color: Brand.muted, fontSize: 12))
        else
          Row(children: [
            Expanded(child: Text(printer == null ? 'No slip printer chosen: the print window opens each time.' : 'Slip printer: $printer')),
            TextButton(
                onPressed: () async {
                  await chooseSlipPrinter(context);
                  setState(() {});
                },
                child: Text(printer == null ? 'Choose printer' : 'Change')),
            if (printer != null)
              TextButton(
                  onPressed: () async {
                    await forgetSlipPrinter();
                    setState(() {});
                  },
                  child: const Text('Forget')),
          ]),
        const SizedBox(height: 4),
        Text('App version ${AppConfig.appVersion}', style: const TextStyle(color: Brand.muted, fontSize: 12)),
      ]),
      card('Backups and test data', [
        const Text(
            'The free database plan keeps no backups. Download one every week and before big changes.',
            style: TextStyle(color: Brand.muted)),
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 10, children: [
          FilledButton.icon(
              onPressed: _busy ? null : _backup, icon: const Icon(Icons.download), label: const Text('Download backup')),
          OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: Brand.red),
              onPressed: _busy ? null : _clearSales,
              icon: const Icon(Icons.delete_sweep_outlined),
              label: const Text('Clear test sales before going live')),
        ]),
        if (_status != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_status!)),
      ]),
      card('Change history', [
        const Text('Who changed prices, recipes, stock, staff and settings; who took money out of a till, did refunds and cash-ups, received stock, and which manager approved what.',
            style: TextStyle(color: Brand.muted)),
        const SizedBox(height: 8),
        Row(children: [
          DropdownButton<String>(
            value: _auditFilter,
            underline: const SizedBox(),
            items: [for (final e in _auditNames.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (v) {
              setState(() => _auditFilter = v ?? 'all');
              if (_auditLoaded) _loadAudit();
            },
          ),
        ]),
        if (!_auditLoaded)
          OutlinedButton(onPressed: _loadAudit, child: const Text('Show the last 300 changes'))
        else if (_audit.isEmpty)
          const Text('No changes recorded yet.')
        else
          for (final a in _audit)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text(
                  '${'${a['at']}'.replaceFirst('T', ' ').split('.').first} · '
                  '${LocalStore.row('staff_profiles', a['user_id'])?['full_name'] ?? 'System'} · '
                  '${a['table_name']} ${a['action']}: ${_auditText(a)}',
                  style: const TextStyle(fontSize: 12)),
            ),
      ]),
      card('Problems reported by the app', [
        const Text('Errors from every till, so problems can be fixed even when nobody reports them.',
            style: TextStyle(color: Brand.muted)),
        const SizedBox(height: 8),
        if (!_errorsLoaded)
          OutlinedButton(onPressed: _loadErrors, child: const Text('Show problems'))
        else if (_errors.isEmpty)
          const Text('No problems reported.', style: TextStyle(color: Brand.green))
        else ...[
          for (final e in _errors)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                  '${'${e['created_at'] ?? ''}'.replaceFirst('T', ' ').split('.').first} · ${e['platform'] ?? ''} ${e['app_version'] ?? ''}\n${e['message']}',
                  style: const TextStyle(fontSize: 12)),
            ),
          TextButton(onPressed: _clearErrors, child: const Text('Clear the list')),
        ],
      ]),
    ]);
  }
}
