import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/local_store.dart';
import '../data/repo.dart';
import '../data/sync_service.dart';
import '../receipt/receipt_service.dart';
import '../theme.dart';

/// Orders: the last 2 days from this device, or any dates looked up on the
/// server. Tap one for its receipt (print, download, email, refund).
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  String _search = '';
  String _filter = 'all'; // all, unpaid, paid, cancelled

  /// Set when older dates were looked up on the server.
  DateTime? _from;
  DateTime? _to;
  List<Map<String, dynamic>>? _server;
  bool _loading = false;
  String? _error;

  String _d(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pick({required bool from}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: now,
      initialDate: (from ? _from : _to) ?? now,
      helpText: from ? 'From date' : 'To date',
    );
    if (picked == null) return;
    setState(() {
      if (from) {
        _from = picked;
        if (_to == null || _to!.isBefore(picked)) _to = picked;
      } else {
        _to = picked;
        if (_from == null || _from!.isAfter(picked)) _from = picked;
      }
    });
    _fetch();
  }

  Future<void> _fetch() async {
    final from = _from, to = _to;
    if (from == null || to == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      var q = Supabase.instance.client
          .from('orders')
          .select('*, order_items(*), payments(*)')
          .gte('created_at', DateTime(from.year, from.month, from.day).toUtc().toIso8601String())
          .lt('created_at', DateTime(to.year, to.month, to.day + 1).toUtc().toIso8601String());
      if (_search.trim().isNotEmpty) q = q.ilike('order_ref', '%${_search.trim()}%');
      final rows = await q.order('created_at', ascending: false).limit(500);
      _server = rows.map((e) => Map<String, dynamic>.from(e)).toList();
    } on PostgrestException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Looking up older orders needs an internet connection.';
    }
    if (mounted) setState(() => _loading = false);
  }

  void _backToRecent() => setState(() {
        _from = null;
        _to = null;
        _server = null;
        _error = null;
      });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SyncService.instance,
      builder: (context, _) {
        final fromServer = _server != null;
        final all = (fromServer ? _server! : LocalStore.rows('orders').toList())
          ..sort((a, b) => '${b['created_at']}'.compareTo('${a['created_at']}'));
        final shown = all.where((o) {
          final term = _search.trim().toLowerCase();
          if (term.isNotEmpty &&
              !'${o['order_ref']}'.toLowerCase().contains(term) &&
              !'${o['invoice_no'] ?? ''}'.contains(term) &&
              !'${o['customer_name'] ?? ''}'.toLowerCase().contains(term)) {
            return false;
          }
          switch (_filter) {
            case 'unpaid':
              return o['paid'] != true && o['status'] != 'void';
            case 'paid':
              return o['paid'] == true && o['status'] != 'void';
            case 'cancelled':
              return o['status'] == 'void';
            default:
              return true;
          }
        }).toList();

        Widget chip(String k, String label) => ChoiceChip(
            label: Text(label), selected: _filter == k, onSelected: (_) => setState(() => _filter = k));

        return ListView(padding: const EdgeInsets.all(20), children: [
          const Text('Orders', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Brand.navy)),
          const SizedBox(height: 4),
          Text(
              fromServer
                  ? 'Orders from ${_d(_from!)} to ${_d(_to!)} (up to 500). Tap an order to see its receipt.'
                  : 'The last 2 days. Choose dates to look up older orders. Tap an order to see its receipt.',
              style: const TextStyle(color: Brand.muted)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: 240,
              child: TextField(
                onChanged: (v) => setState(() => _search = v),
                onSubmitted: (_) {
                  if (fromServer) _fetch();
                },
                decoration: const InputDecoration(
                    hintText: 'Order no., invoice no. or name', prefixIcon: Icon(Icons.search), isDense: true),
              ),
            ),
            OutlinedButton.icon(
                onPressed: () => _pick(from: true),
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text(_from == null ? 'From date' : 'From  ${_d(_from!)}')),
            OutlinedButton.icon(
                onPressed: () => _pick(from: false),
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text(_to == null ? 'To date' : 'To  ${_d(_to!)}')),
            if (_from != null) TextButton(onPressed: _backToRecent, child: const Text('Back to last 2 days')),
            chip('all', 'All · ${all.length}'),
            chip('paid', 'Paid'),
            chip('unpaid', 'Unpaid'),
            chip('cancelled', 'Cancelled'),
          ]),
          const SizedBox(height: 12),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(8), child: Text(_error!, style: const TextStyle(color: Brand.red))),
          Card(
            child: shown.isEmpty
                ? const Padding(padding: EdgeInsets.all(24), child: Text('No orders found.'))
                : Column(children: [
                    for (final o in shown)
                      ListTile(
                        onTap: () => showReceiptDialog(context, o['id'] as String,
                            data: fromServer ? ReceiptData.fromServer(o) : null),
                        leading: const Icon(Icons.receipt_long, color: Brand.navy),
                        title: Text(
                            '#${o['order_ref']} · ${money(n(o['total']))}'
                            '${o['invoice_no'] != null ? ' · INV-${'${o['invoice_no']}'.padLeft(6, '0')}' : ''}',
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(_subtitle(o, fromServer)),
                        trailing: _badge(o, fromServer),
                      ),
                  ]),
          ),
        ]);
      },
    );
  }

  List<Map<String, dynamic>> _items(Map<String, dynamic> o, bool fromServer) => fromServer
      ? ((o['order_items'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((i) => i['voided'] != true)
          .toList()
      : OrderRepo.liveItemsFor(o['id'] as String);

  String _subtitle(Map<String, dynamic> o, bool fromServer) {
    final t = parseTime(o['created_at']);
    final when = t == null
        ? ''
        : '${_d(t)} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    const types = {'eat_in': 'Eat in', 'take_away': 'Take away', 'delivery': 'Delivery'};
    final items = _items(o, fromServer).map((e) => '${e['qty']}x ${e['name']}').join(', ');
    final who = '${o['customer_name'] ?? ''}'.trim();
    return '$when · ${types[o['order_type']] ?? ''}${o['table_no'] != null ? ' ${o['table_no']}' : ''}'
        '${who.isEmpty ? '' : ' · $who'}\n$items';
  }

  Widget _badge(Map<String, dynamic> o, bool fromServer) {
    String text;
    Color bg;
    if (o['status'] == 'void') {
      text = 'Cancelled';
      bg = const Color(0xFFF8D7DB);
    } else if (o['paid'] != true) {
      final paid = fromServer
          ? ((o['payments'] as List?) ?? const []).fold<double>(0, (s, p) => s + n((p as Map)['amount']).toDouble())
          : OrderRepo.paidAmount(o['id'] as String);
      text = paid > 0 ? 'Part paid' : 'Unpaid';
      bg = const Color(0xFFFFF1CC);
    } else {
      text = 'Paid';
      bg = const Color(0xFFDDF3E6);
    }
    return Chip(label: Text(text), backgroundColor: bg);
  }
}
