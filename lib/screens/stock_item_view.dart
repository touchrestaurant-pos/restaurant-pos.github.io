import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/local_store.dart';
import '../data/repo.dart';
import '../theme.dart';

const _reasons = {
  'grv': 'Delivery received',
  'sale': 'Sold',
  'sale_void': 'Sale cancelled, put back',
  'adjustment': 'Adjustment',
  'waste': 'Waste',
  'stocktake': 'Stock-take',
};

String _q(num v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

/// One stock item in full, with every movement that changed its quantity.
Future<void> showStockItemView(
  BuildContext context,
  Map<String, dynamic> item, {
  required VoidCallback onAdjust,
  required VoidCallback onEdit,
  VoidCallback? onDelete,
}) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820, maxHeight: 760),
          child: _View(item: item, onAdjust: onAdjust, onEdit: onEdit, onDelete: onDelete),
        ),
      ),
    );

class _View extends StatefulWidget {
  const _View({required this.item, required this.onAdjust, required this.onEdit, this.onDelete});
  final Map<String, dynamic> item;
  final VoidCallback onAdjust;
  final VoidCallback onEdit;
  final VoidCallback? onDelete;

  @override
  State<_View> createState() => _ViewState();
}

class _ViewState extends State<_View> {
  List<Map<String, dynamic>> _moves = [];
  bool _loading = true;
  String? _error;
  String _reason = 'all';

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
      final r = await Supabase.instance.client
          .from('stock_movements')
          .select('id,qty_change,reason,ref_id,note,created_by,created_at')
          .eq('stock_item_id', widget.item['id'])
          .order('created_at', ascending: false)
          .limit(500);
      _moves = (r as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } on PostgrestException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'The movement history needs an internet connection.';
    }
    if (mounted) setState(() => _loading = false);
  }

  String _who(dynamic id) {
    for (final p in LocalStore.rows('staff_profiles')) {
      if (p['id'] == id) return '${p['full_name']}';
    }
    return id == null ? 'Till sale' : '';
  }

  String _ref(Map<String, dynamic> m) {
    if (m['reason'] == 'grv') {
      final g = LocalStore.row('grvs', m['ref_id']);
      if (g != null) return '${g['grv_no']}';
    }
    return '';
  }

  String _when(dynamic v) {
    final t = parseTime(v);
    if (t == null) return '';
    String two(int x) => x.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.item;
    final onHand = n(i['qty_on_hand']).toDouble();
    // Balance after each movement, worked back from what is on hand now (newest first).
    final balances = <double>[];
    var run = onHand;
    for (final m in _moves) {
      balances.add(run);
      run -= n(m['qty_change']).toDouble();
    }
    final shown = <int>[for (var k = 0; k < _moves.length; k++) if (_reason == 'all' || _moves[k]['reason'] == _reason) k];
    final totalIn = _moves.where((m) => n(m['qty_change']) > 0).fold<double>(0, (s, m) => s + n(m['qty_change']).toDouble());
    final totalOut = _moves.where((m) => n(m['qty_change']) < 0).fold<double>(0, (s, m) => s + n(m['qty_change']).toDouble());
    final unit = '${i['unit']}';
    Widget fact(String l, String v) => SizedBox(
          width: 190,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l, style: const TextStyle(color: Brand.muted, fontSize: 12)),
              Text(v, style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
          ),
        );
    final pack = '${i['purchase_unit'] ?? ''}'.isEmpty ? '-' : '1 ${i['purchase_unit']} = ${_q(n(i['purchase_factor']))} $unit';
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('${i['name']}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
          IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
        ]),
        Wrap(children: [
          fact('Category', '${i['category'] ?? '-'}'),
          fact('On hand', '${_q(onHand)} $unit'),
          fact('Minimum level', '${_q(n(i['min_level']))} $unit'),
          fact('Average cost', money(n(i['avg_cost']))),
          fact('Stock value', money(onHand * n(i['avg_cost']))),
          fact('Supplier', '${_supplier(i['supplier_id'])}'),
          fact('VAT', {'standard': 'Standard rated', 'zero': 'Zero rated', 'exempt': 'Exempt'}['${i['vat_type'] ?? 'standard'}'] ?? '-'),
          fact('Bought in', pack),
          fact('Status', i['active'] == false ? 'Hidden' : 'Active'),
        ]),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.tonal(onPressed: () { Navigator.pop(context); widget.onAdjust(); }, child: const Text('Adjust stock')),
          OutlinedButton(onPressed: () { Navigator.pop(context); widget.onEdit(); }, child: const Text('Edit details')),
          if (widget.onDelete != null)
            OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: Brand.red),
                onPressed: () { Navigator.pop(context); widget.onDelete!(); },
                child: const Text('Delete')),
        ]),
        if (_usedIn().isNotEmpty) ...[
          const SizedBox(height: 4),
          const Text('Used in', style: TextStyle(fontWeight: FontWeight.w700)),
          Text(_usedIn().join(' · '), style: const TextStyle(color: Brand.muted, fontSize: 12), maxLines: 3, overflow: TextOverflow.ellipsis),
        ],
        const Divider(height: 24),
        Row(children: [
          const Expanded(child: Text('Stock movements', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
          DropdownButton<String>(
            value: _reason,
            items: [
              const DropdownMenuItem(value: 'all', child: Text('All movements')),
              for (final e in _reasons.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) => setState(() => _reason = v ?? 'all'),
          ),
        ]),
        if (!_loading && _error == null)
          Text('In ${_q(totalIn)} $unit · out ${_q(-totalOut)} $unit${_moves.length >= 500 ? ' · latest 500 movements' : ''}',
              style: const TextStyle(color: Brand.muted, fontSize: 12)),
        const SizedBox(height: 6),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Text(_error!, style: const TextStyle(color: Brand.red, fontWeight: FontWeight.w600))
                  : shown.isEmpty
                      ? const Text('No movements to show.')
                      : SingleChildScrollView(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: DataTable(
                              headingRowHeight: 38,
                              dataRowMinHeight: 36,
                              dataRowMaxHeight: 52,
                              columnSpacing: 20,
                              columns: const [
                                DataColumn(label: Text('When')),
                                DataColumn(label: Text('What')),
                                DataColumn(label: Text('Change'), numeric: true),
                                DataColumn(label: Text('Balance after'), numeric: true),
                                DataColumn(label: Text('Reference / note')),
                                DataColumn(label: Text('By')),
                              ],
                              rows: [
                                for (final k in shown)
                                  DataRow(cells: [
                                    DataCell(Text(_when(_moves[k]['created_at']))),
                                    DataCell(Text(_reasons['${_moves[k]['reason']}'] ?? '${_moves[k]['reason']}')),
                                    DataCell(Text('${n(_moves[k]['qty_change']) > 0 ? '+' : ''}${_q(n(_moves[k]['qty_change']))} $unit',
                                        style: TextStyle(fontWeight: FontWeight.w700, color: n(_moves[k]['qty_change']) < 0 ? Brand.red : Brand.green))),
                                    DataCell(Text('${_q(balances[k])} $unit')),
                                    DataCell(ConstrainedBox(
                                        constraints: const BoxConstraints(maxWidth: 240),
                                        child: Text([_ref(_moves[k]), '${_moves[k]['note'] ?? ''}'].where((x) => x.isNotEmpty).join(' · '),
                                            overflow: TextOverflow.ellipsis, maxLines: 2))),
                                    DataCell(Text(_who(_moves[k]['created_by']))),
                                  ]),
                              ],
                            ),
                          ),
                        ),
        ),
      ]),
    );
  }

  /// Menu items and special requests that take this item out of stock.
  List<String> _usedIn() {
    final id = widget.item['id'];
    final unit = '${widget.item['unit']}';
    return [
      for (final r in LocalStore.rows('recipe_lines'))
        if (r['stock_item_id'] == id)
          '${LocalStore.row('products', r['product_id'])?['name'] ?? 'Menu item'} (${_q(n(r['qty']))} $unit)',
      for (final m in LocalStore.rows('modifiers'))
        if (m['stock_item_id'] == id) '${m['name']} (extra)',
    ];
  }

  String _supplier(dynamic id) {
    for (final s in LocalStore.rows('suppliers')) {
      if (s['id'] == id) return '${s['name']}';
    }
    return 'No supplier';
  }
}
