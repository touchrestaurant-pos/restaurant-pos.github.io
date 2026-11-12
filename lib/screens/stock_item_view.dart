import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/local_store.dart';
import '../data/repo.dart';
import '../theme.dart';
import 'report_charts.dart';

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
  String _mode = 'table'; // table or graphs
  String _preset = '30'; // 7, 30, month, all, custom
  DateTime? _from;
  DateTime? _to; // last day shown, inclusive

  DateTime _today() {
    final n0 = DateTime.now();
    return DateTime(n0.year, n0.month, n0.day);
  }

  /// First day of the range, or null for everything.
  DateTime? _rangeFrom() {
    final t = _today();
    switch (_preset) {
      case '7':
        return t.subtract(const Duration(days: 6));
      case '30':
        return t.subtract(const Duration(days: 29));
      case 'month':
        return DateTime(t.year, t.month, 1);
      case 'custom':
        return _from;
      default:
        return null;
    }
  }

  DateTime? _rangeTo() => _preset == 'custom' ? _to : null;

  Future<void> _pickRange() async {
    final t = _today();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(t.year - 5),
      lastDate: t,
      initialDateRange: DateTimeRange(start: _from ?? t.subtract(const Duration(days: 29)), end: _to ?? t),
    );
    if (r == null) return;
    setState(() {
      _preset = 'custom';
      _from = r.start;
      _to = r.end;
    });
    _load();
  }

  String _day(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

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
      // Everything from the start of the range up to now is read, so the balance after each
      // movement can be worked back exactly from what is on hand today.
      var q = Supabase.instance.client
          .from('stock_movements')
          .select('id,qty_change,reason,ref_id,note,created_by,created_at')
          .eq('stock_item_id', widget.item['id']);
      final f = _rangeFrom();
      if (f != null) q = q.gte('created_at', f.toUtc().toIso8601String());
      final r = await q.order('created_at', ascending: false).limit(3000);
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
    final last = _rangeTo();
    bool inRange(Map<String, dynamic> m) {
      if (last == null) return true;
      final t = parseTime(m['created_at']);
      return t != null && t.isBefore(DateTime(last.year, last.month, last.day + 1));
    }

    final shown = <int>[
      for (var k = 0; k < _moves.length; k++)
        if (inRange(_moves[k]) && (_reason == 'all' || _moves[k]['reason'] == _reason)) k
    ];
    final inView = [for (final k in shown) _moves[k]];
    final totalIn = inView.where((m) => n(m['qty_change']) > 0).fold<double>(0, (s, m) => s + n(m['qty_change']).toDouble());
    final totalOut = inView.where((m) => n(m['qty_change']) < 0).fold<double>(0, (s, m) => s + n(m['qty_change']).toDouble());
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
      child: SingleChildScrollView(
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
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'table', icon: Icon(Icons.table_rows_outlined, size: 18), label: Text('List')),
              ButtonSegment(value: 'graphs', icon: Icon(Icons.show_chart, size: 18), label: Text('Graphs')),
            ],
            selected: {_mode},
            onSelectionChanged: (v) => setState(() => _mode = v.first),
          ),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final e in const {'7': 'Last 7 days', '30': 'Last 30 days', 'month': 'This month', 'all': 'All time'}.entries)
            ChoiceChip(
                label: Text(e.value),
                selected: _preset == e.key,
                onSelected: (_) {
                  setState(() => _preset = e.key);
                  _load();
                }),
          ChoiceChip(
              avatar: const Icon(Icons.date_range, size: 16),
              label: Text(_preset == 'custom' && _from != null && _to != null ? '${_day(_from!)} to ${_day(_to!)}' : 'Pick dates'),
              selected: _preset == 'custom',
              onSelected: (_) => _pickRange()),
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
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
                'In ${_q(totalIn)} $unit · out ${_q(-totalOut)} $unit · net ${_q(totalIn + totalOut)} $unit · ${shown.length} movements${_moves.length >= 3000 ? ' · latest 3000 only' : ''}',
                style: const TextStyle(color: Brand.muted, fontSize: 12)),
          ),
        const SizedBox(height: 6),
        Builder(
          builder: (_) => _loading
              ? const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
              : _error != null
                  ? Text(_error!, style: const TextStyle(color: Brand.red, fontWeight: FontWeight.w600))
                  : shown.isEmpty
                      ? const Text('No movements in this period.')
                      : _mode == 'graphs'
                          ? _graphs(inView, balances, onHand, unit)
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
      ),
    );
  }

  /// Balance over time, what came in and went out each day, and what the movements were for.
  Widget _graphs(List<Map<String, dynamic>> inView, List<double> balances, double onHand, String unit) {
    final first = _rangeFrom();
    final t = _today();
    final times = [for (final m in _moves) parseTime(m['created_at'])].whereType<DateTime>().toList();
    var start = first ?? (times.isEmpty ? t : DateTime(times.last.year, times.last.month, times.last.day));
    var end = _rangeTo() ?? t;
    if (end.difference(start).inDays > 180) start = end.subtract(const Duration(days: 180));
    // Opening balance = on hand today minus everything that moved since the start of the range.
    var open = onHand;
    for (final m in _moves) {
      final tm = parseTime(m['created_at']);
      if (tm != null && !tm.isBefore(start)) open -= n(m['qty_change']).toDouble();
    }
    final days = <DateTime>[];
    for (var d = start; !d.isAfter(end); d = DateTime(d.year, d.month, d.day + 1)) {
      days.add(d);
    }
    String key(DateTime d) => _day(d);
    final inBy = <String, double>{}, outBy = <String, double>{}, netBy = <String, double>{};
    for (final m in _moves) {
      final tm = parseTime(m['created_at']);
      if (tm == null || tm.isBefore(start) || !tm.isBefore(DateTime(end.year, end.month, end.day + 1))) continue;
      final c = n(m['qty_change']).toDouble();
      final k = key(DateTime(tm.year, tm.month, tm.day));
      netBy[k] = (netBy[k] ?? 0) + c;
      if (c > 0) inBy[k] = (inBy[k] ?? 0) + c;
      if (c < 0) outBy[k] = (outBy[k] ?? 0) - c;
    }
    var run = open;
    final balancePts = <ChartPoint>[];
    for (final d in days) {
      run += netBy[key(d)] ?? 0;
      balancePts.add(ChartPoint(key(d).substring(5), double.parse(run.toStringAsFixed(3)), detail: 'Net ${_q(netBy[key(d)] ?? 0)} $unit that day'));
    }
    final byReason = <String, double>{};
    for (final m in inView) {
      final r = _reasons['${m['reason']}'] ?? '${m['reason']}';
      byReason[r] = (byReason[r] ?? 0) + n(m['qty_change']).abs().toDouble();
    }
    String f(double v) => '${_q(v)} $unit';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AdaptiveLine(title: 'Quantity on hand', points: balancePts, format: f, note: 'The balance at the end of each day.'),
      AdaptiveBars(
          title: 'Stock in each day',
          points: [for (final d in days) ChartPoint(key(d).substring(5), inBy[key(d)] ?? 0)],
          format: f,
          color: Brand.green),
      AdaptiveBars(
          title: 'Stock out each day',
          points: [for (final d in days) ChartPoint(key(d).substring(5), outBy[key(d)] ?? 0)],
          format: f,
          color: Brand.red),
      AdaptivePie(
          title: 'What moved it',
          slices: [for (final e in byReason.entries) ChartPoint(e.key, e.value)],
          format: f,
          note: 'Quantity moved by reason, counting in and out together.'),
    ]);
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
