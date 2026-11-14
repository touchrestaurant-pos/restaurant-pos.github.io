import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/local_store.dart';
import '../data/repo.dart';
import '../data/sync_service.dart';
import '../receipt/download_file.dart';
import '../theme.dart';
import 'stock_screen.dart';
import '../data/app_db.dart';

SupabaseClient get _db => Supabase.instance.client;

String _q(dynamic v) {
  final x = n(v);
  return x == x.roundToDouble() ? x.toInt().toString() : x.toStringAsFixed(2);
}

/// Makes one draft purchase order per supplier from the buying list.
/// Quantities are rounded up to whole packs when the item is bought in packs.
/// Returns how many orders were made.
Future<int> createPurchaseOrdersFromReorder(List<Map<String, dynamic>> reorder) async {
  final bySupplier = <String, List<Map<String, dynamic>>>{};
  for (final r in reorder) {
    final sup = r['supplier_id'] as String?;
    if (sup == null || n(r['suggested']) <= 0) continue;
    bySupplier.putIfAbsent(sup, () => []).add(r);
  }
  var made = 0;
  for (final e in bySupplier.entries) {
    final po = await _db
        .from('purchase_orders')
        .insert({'supplier_id': e.key, 'notes': 'From the buying list'})
        .select('id')
        .single();
    await AppDb.from('purchase_order_lines').insert([
      for (final r in e.value)
        {
          'po_id': po['id'],
          'stock_item_id': r['item_id'],
          'qty': n(r['purchase_factor']) > 1
              ? (n(r['suggested_packs']) > 0 ? n(r['suggested_packs']) : 1) * n(r['purchase_factor'])
              : n(r['suggested']),
          'unit_cost': n(r['avg_cost']),
        }
    ]);
    made++;
  }
  return made;
}

/// Purchase orders: what to order from each supplier. Send by email or PDF,
/// then turn into a delivery (GRV) when the stock arrives.
class PurchaseOrdersTab extends StatefulWidget {
  const PurchaseOrdersTab({super.key});

  @override
  State<PurchaseOrdersTab> createState() => _PurchaseOrdersTabState();
}

class _PurchaseOrdersTabState extends State<PurchaseOrdersTab> {
  List<Map<String, dynamic>> _list = [];
  bool _loading = true;
  String? _error;
  String _filter = 'open';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _db
          .from('purchase_orders')
          .select('*, purchase_order_lines(*)')
          .order('created_at', ascending: false)
          .limit(100);
      _list = rows.map((e) => Map<String, dynamic>.from(e)).toList();
    } on PostgrestException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Purchase orders need an internet connection.';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _open(Map<String, dynamic>? po) async {
    await Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => _PoEditor(po: po)));
    _load();
  }

  Future<void> _fromBuyingList() async {
    try {
      final now = DateTime.now();
      final report = await AppDb.rpc('admin_report', params: {
        'p_from': now.subtract(const Duration(days: 1)).toUtc().toIso8601String(),
        'p_to': now.toUtc().toIso8601String(),
      });
      final reorder = ((report as Map)['reorder'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final made = await createPurchaseOrdersFromReorder(reorder);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(made == 0
                ? 'Nothing to order: no items with a supplier are below their minimum.'
                : '$made draft purchase order${made == 1 ? '' : 's'} made from the buying list.')));
      }
      _load();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This needs an internet connection.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = _list.where((p) {
      if (_filter == 'open') return p['status'] == 'draft' || p['status'] == 'sent';
      if (_filter == 'done') return p['status'] == 'received' || p['status'] == 'cancelled';
      return true;
    }).toList();
    return ListView(padding: const EdgeInsets.all(20), children: [
      Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        FilledButton.icon(onPressed: () => _open(null), icon: const Icon(Icons.add), label: const Text('New purchase order')),
        OutlinedButton.icon(
            onPressed: _fromBuyingList,
            icon: const Icon(Icons.playlist_add),
            label: const Text('Make from buying list')),
        IconButton(onPressed: _load, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
        for (final f in const [['open', 'Open'], ['done', 'Received / cancelled'], ['all', 'All']])
          ChoiceChip(label: Text(f[1]), selected: _filter == f[0], onSelected: (_) => setState(() => _filter = f[0])),
      ]),
      const SizedBox(height: 12),
      if (_loading) const LinearProgressIndicator(),
      if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: const TextStyle(color: Brand.red))),
      Card(
        child: shown.isEmpty && !_loading
            ? const Padding(padding: EdgeInsets.all(24), child: Text('No purchase orders here.'))
            : Column(children: [
                for (final p in shown)
                  ListTile(
                    onTap: () => _open(p),
                    title: Text('${p['po_no']} · ${LocalStore.row('suppliers', p['supplier_id'])?['name'] ?? 'Supplier'}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(
                        '${'${p['created_at']}'.substring(0, 10)} · ${(p['purchase_order_lines'] as List?)?.length ?? 0} items · '
                        '${money(((p['purchase_order_lines'] as List?) ?? const []).fold<double>(0, (s, l) => s + n(l['qty']) * n(l['unit_cost']).toDouble()))} excl. VAT'),
                    trailing: Chip(
                      label: Text(const {'draft': 'Draft', 'sent': 'Sent', 'received': 'Received', 'cancelled': 'Cancelled'}[p['status']] ??
                          '${p['status']}'),
                      backgroundColor: switch (p['status']) {
                        'sent' => const Color(0xFFDCE8FF),
                        'received' => const Color(0xFFDDF3E6),
                        'cancelled' => const Color(0xFFEDEFF4),
                        _ => const Color(0xFFFFF1CC),
                      },
                    ),
                  ),
              ]),
      ),
    ]);
  }
}

class _PoLine {
  _PoLine(this.itemId, {String qty = '', String cost = ''})
      : qty = TextEditingController(text: qty),
        cost = TextEditingController(text: cost);
  final String itemId;
  final TextEditingController qty; // in stock units
  final TextEditingController cost; // per stock unit
  double get q => double.tryParse(qty.text.replaceAll(',', '.')) ?? 0;
  double get c => double.tryParse(cost.text.replaceAll(',', '.')) ?? 0;
}

class _PoEditor extends StatefulWidget {
  const _PoEditor({this.po});
  final Map<String, dynamic>? po;

  @override
  State<_PoEditor> createState() => _PoEditorState();
}

class _PoEditorState extends State<_PoEditor> {
  String? _supplier;
  final _notes = TextEditingController();
  final List<_PoLine> _lines = [];
  bool _busy = false;
  late String _status = '${widget.po?['status'] ?? 'draft'}';
  String? _id;

  bool get _locked => _status == 'received' || _status == 'cancelled';

  @override
  void initState() {
    super.initState();
    final p = widget.po;
    _id = p?['id'] as String?;
    if (p != null) {
      _supplier = p['supplier_id'] as String?;
      _notes.text = '${p['notes'] ?? ''}';
      for (final l in (p['purchase_order_lines'] as List? ?? const [])) {
        _lines.add(_PoLine(l['stock_item_id'] as String, qty: _q(l['qty']), cost: '${n(l['unit_cost'])}'));
      }
    }
  }

  Map<String, dynamic>? _item(String id) => LocalStore.row('stock_items', id);
  double get _total => _lines.fold<double>(0, (s, l) => s + l.q * l.c);
  Map<String, dynamic>? get _sup => LocalStore.row('suppliers', _supplier);

  Future<void> _addLine() async {
    final used = _lines.map((l) => l.itemId).toSet();
    final all = LocalStore.rows('stock_items').where((i) => i['active'] != false && !used.contains(i['id'])).toList()
      ..sort((a, b) {
        final am = a['supplier_id'] == _supplier ? 0 : 1;
        final bm = b['supplier_id'] == _supplier ? 0 : 1;
        return am != bm ? am - bm : '${a['name']}'.compareTo('${b['name']}');
      });
    var q = '';
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final shown = all.where((i) => '${i['name']}'.toLowerCase().contains(q.toLowerCase())).toList();
        return AlertDialog(
          title: const Text('Add item'),
          content: SizedBox(
            width: 420,
            height: 420,
            child: Column(children: [
              TextField(
                  autofocus: true,
                  onChanged: (v) => set(() => q = v),
                  decoration: const InputDecoration(hintText: 'Search stock items', prefixIcon: Icon(Icons.search))),
              Expanded(
                child: ListView(children: [
                  for (final i in shown)
                    ListTile(
                      dense: true,
                      title: Text('${i['name']}'),
                      subtitle: Text('On hand ${_q(i['qty_on_hand'])} ${i['unit']} · minimum ${_q(i['min_level'])}'),
                      onTap: () => Navigator.pop(ctx, i),
                    ),
                ]),
              ),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
        );
      }),
    );
    if (picked == null) return;
    final factor = n(picked['purchase_factor']);
    final need = (n(picked['min_level']) * 2 - n(picked['qty_on_hand'])).clamp(0, double.infinity);
    final qty = factor > 1 ? ((need / factor).ceil().clamp(1, 1000000) * factor) : (need > 0 ? need : 1);
    setState(() => _lines.add(_PoLine(picked['id'] as String, qty: _q(qty), cost: '${n(picked['avg_cost'])}')));
  }

  Future<String?> _save({String? status}) async {
    if (_supplier == null) {
      _say('Choose the supplier.');
      return null;
    }
    if (_lines.isEmpty || _lines.any((l) => l.q <= 0)) {
      _say('Add items with a quantity above zero.');
      return null;
    }
    setState(() => _busy = true);
    try {
      final head = {
        'supplier_id': _supplier,
        'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        if (status != null) 'status': status,
      };
      if (_id == null) {
        final row = await AppDb.from('purchase_orders').insert(head).select('id').single();
        _id = row['id'] as String;
      } else {
        await AppDb.from('purchase_orders').update(head).eq('id', _id!);
        await AppDb.from('purchase_order_lines').delete().eq('po_id', _id!);
      }
      await AppDb.from('purchase_order_lines').insert([
        for (final l in _lines) {'po_id': _id, 'stock_item_id': l.itemId, 'qty': l.q, 'unit_cost': l.c}
      ]);
      if (status != null) _status = status;
      return _id;
    } on PostgrestException catch (e) {
      _say(e.message);
    } catch (_) {
      _say('Purchase orders need an internet connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return null;
  }

  void _say(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<String> _poNo() async {
    if (_id == null) return 'PO';
    final r = await AppDb.from('purchase_orders').select('po_no').eq('id', _id!).single();
    return '${r['po_no']}';
  }

  String _text(String poNo) {
    final c = companyRow() ?? {};
    final b = StringBuffer('Purchase order $poNo\nFrom: ${c['company_name'] ?? ''}\n${c['address'] ?? ''}\nTel ${c['phone'] ?? ''}\n\n');
    b.writeln('Please supply:');
    for (final l in _lines) {
      final it = _item(l.itemId);
      final f = n(it?['purchase_factor']);
      final qty = f > 1 ? '${_q(l.q / f)} ${it?['purchase_unit'] ?? 'packs'} (${_q(l.q)} ${it?['unit']})' : '${_q(l.q)} ${it?['unit']}';
      b.writeln('- $qty  ${it?['name']}');
    }
    if (_notes.text.trim().isNotEmpty) b.writeln('\nNotes: ${_notes.text.trim()}');
    b.writeln('\nThank you.');
    return b.toString();
  }

  Future<Uint8List> _pdf(String poNo) async {
    final c = companyRow() ?? {};
    final doc = pw.Document(title: poNo);
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(36),
      build: (ctx) => [
        pw.Text('PURCHASE ORDER', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
        pw.Text(poNo, style: const pw.TextStyle(fontSize: 12)),
        pw.SizedBox(height: 12),
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Expanded(
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('From', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            pw.Text('${c['company_name'] ?? ''}'),
            pw.Text('${c['address'] ?? ''}'),
            pw.Text('Tel ${c['phone'] ?? ''}'),
            if ('${c['vat_number'] ?? ''}'.isNotEmpty) pw.Text('VAT no. ${c['vat_number']}'),
          ])),
          pw.Expanded(
              child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('To', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            pw.Text('${_sup?['name'] ?? ''}'),
            if ('${_sup?['contact_person'] ?? ''}'.isNotEmpty) pw.Text('${_sup?['contact_person']}'),
            if ('${_sup?['phone'] ?? ''}'.isNotEmpty) pw.Text('${_sup?['phone']}'),
            if ('${_sup?['email'] ?? ''}'.isNotEmpty) pw.Text('${_sup?['email']}'),
          ])),
        ]),
        pw.SizedBox(height: 16),
        pw.TableHelper.fromTextArray(
          headers: ['Item', 'Quantity', 'Unit cost', 'Total'],
          data: [
            for (final l in _lines)
              () {
                final it = _item(l.itemId);
                final f = n(it?['purchase_factor']);
                return [
                  '${it?['name']}',
                  f > 1 ? '${_q(l.q / f)} ${it?['purchase_unit'] ?? 'packs'} (${_q(l.q)} ${it?['unit']})' : '${_q(l.q)} ${it?['unit']}',
                  money(l.c),
                  money(l.q * l.c),
                ];
              }(),
          ],
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
          cellAlignments: {1: pw.Alignment.centerRight, 2: pw.Alignment.centerRight, 3: pw.Alignment.centerRight},
        ),
        pw.SizedBox(height: 8),
        pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text('Estimated total excl. VAT: ${money(_total)}', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
        if (_notes.text.trim().isNotEmpty) ...[pw.SizedBox(height: 12), pw.Text('Notes: ${_notes.text.trim()}')],
      ],
    ));
    return doc.save();
  }

  Future<void> _send() async {
    final id = await _save(status: 'sent');
    if (id == null) return;
    final poNo = await _poNo();
    final email = '${_sup?['email'] ?? ''}';
    final subject = Uri.encodeComponent('Purchase order $poNo');
    final body = Uri.encodeComponent(_text(poNo));
    try {
      await launchUrl(Uri.parse('mailto:$email?subject=$subject&body=$body'));
    } catch (_) {}
    _say(email.isEmpty
        ? 'Marked as sent. This supplier has no email address: download the PDF and send it another way.'
        : 'Marked as sent and your email app was opened.');
  }

  Future<void> _download() async {
    final id = await _save();
    if (id == null) return;
    final poNo = await _poNo();
    await downloadBytes('$poNo.pdf', await _pdf(poNo), 'application/pdf');
  }

  Future<void> _receive() async {
    final id = await _save();
    if (id == null) return;
    setState(() => _busy = true);
    try {
      final grvId = await AppDb.rpc('po_to_grv', params: {'p_po': id});
      await SyncService.instance.syncNow();
      if (!mounted) return;
      final grv = LocalStore.row('grvs', grvId);
      Navigator.pop(context);
      if (grv != null) {
        await Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => GrvEditor(grv: grv)));
      }
    } on PostgrestException catch (e) {
      _say(e.message);
    } catch (_) {
      _say('This needs an internet connection.');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _cancelPo() async {
    if (_id == null) {
      Navigator.pop(context);
      return;
    }
    try {
      await AppDb.from('purchase_orders').update({'status': 'cancelled'}).eq('id', _id!);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      _say('This needs an internet connection.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final suppliers = LocalStore.rows('suppliers').where((s) => s['active'] != false).toList()
      ..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    return Scaffold(
      appBar: AppBar(title: Text(widget.po == null ? 'New purchase order' : '${widget.po!['po_no']}')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Wrap(spacing: 16, runSpacing: 16, children: [
          SizedBox(
            width: 300,
            child: DropdownButtonFormField<String>(
              value: _supplier,
              decoration: const InputDecoration(labelText: 'Supplier'),
              items: [for (final s in suppliers) DropdownMenuItem(value: s['id'] as String, child: Text('${s['name']}'))],
              onChanged: _locked ? null : (v) => setState(() => _supplier = v),
            ),
          ),
          SizedBox(
              width: 360,
              child: TextField(controller: _notes, enabled: !_locked, decoration: const InputDecoration(labelText: 'Notes for the supplier'))),
        ]),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Expanded(child: Text('Items', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
                if (!_locked) OutlinedButton.icon(onPressed: _addLine, icon: const Icon(Icons.add), label: const Text('Add item')),
              ]),
              if (_lines.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('No items yet.')),
              for (var i = 0; i < _lines.length; i++)
                () {
                  final l = _lines[i];
                  final it = _item(l.itemId);
                  final f = n(it?['purchase_factor']);
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      SizedBox(
                          width: 220,
                          child: Text('${it?['name'] ?? 'Unknown'}', style: const TextStyle(fontWeight: FontWeight.w700))),
                      SizedBox(
                          width: 130,
                          child: TextField(
                              controller: l.qty,
                              enabled: !_locked,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              onChanged: (_) => setState(() {}),
                              decoration: InputDecoration(
                                  labelText: 'Quantity',
                                  suffixText: '${it?['unit'] ?? ''}',
                                  helperText: f > 1 ? '= ${_q(l.q / f)} ${it?['purchase_unit'] ?? 'packs'}' : null,
                                  isDense: true))),
                      SizedBox(
                          width: 130,
                          child: TextField(
                              controller: l.cost,
                              enabled: !_locked,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              onChanged: (_) => setState(() {}),
                              decoration: InputDecoration(labelText: 'Cost per ${it?['unit'] ?? ''}', prefixText: 'R', isDense: true))),
                      Text(money(l.q * l.c), style: const TextStyle(fontWeight: FontWeight.w700)),
                      if (!_locked) IconButton(onPressed: () => setState(() => _lines.removeAt(i)), icon: const Icon(Icons.close)),
                    ]),
                  );
                }(),
            ]),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Text('Estimated total excl. VAT ${money(_total)}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        ),
        const SizedBox(height: 20),
        if (_locked)
          Text(_status == 'received' ? 'This order was received. The delivery is under Receive stock.' : 'This order was cancelled.',
              style: const TextStyle(color: Brand.muted))
        else
          Wrap(spacing: 10, runSpacing: 10, children: [
            OutlinedButton(onPressed: _busy ? null : () async {
              if (await _save() != null) _say('Saved.');
            }, child: const Text('Save draft')),
            OutlinedButton.icon(onPressed: _busy ? null : _download, icon: const Icon(Icons.picture_as_pdf), label: const Text('Download PDF')),
            FilledButton.icon(onPressed: _busy ? null : _send, icon: const Icon(Icons.send), label: const Text('Send to supplier')),
            FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Brand.green, foregroundColor: Colors.white),
                onPressed: _busy ? null : _receive,
                icon: const Icon(Icons.inventory),
                label: const Text('Stock arrived: receive it')),
            TextButton(
                style: TextButton.styleFrom(foregroundColor: Brand.red),
                onPressed: _busy ? null : _cancelPo,
                child: const Text('Cancel order')),
          ]),
      ]),
    );
  }
}
