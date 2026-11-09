import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/repo.dart';
import '../theme.dart';
import 'report_charts.dart';

/// Admin reports. All figures are calculated on the server for the chosen dates,
/// so they are exact and do not depend on what is stored on this device.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  String _period = 'today';
  DateTimeRange? _custom;
  Map<String, dynamic>? _data;
  Map<String, dynamic>? _prev;
  String _metric = 'revenue';
  int _topN = 10;
  String _category = 'All';
  bool _loading = false;
  String? _error;
  DateTimeRange? _loaded;

  static const _periods = {
    'today': 'Today',
    'yesterday': 'Yesterday',
    'week': 'Last 7 days',
    'month': 'This month',
    'days30': 'Last 30 days',
    'custom': 'Custom',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Start (inclusive) and end (exclusive) in this device's local time.
  DateTimeRange _range() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    switch (_period) {
      case 'yesterday':
        return DateTimeRange(start: DateTime(now.year, now.month, now.day - 1), end: today);
      case 'week':
        return DateTimeRange(start: DateTime(now.year, now.month, now.day - 6), end: tomorrow);
      case 'month':
        return DateTimeRange(start: DateTime(now.year, now.month, 1), end: tomorrow);
      case 'days30':
        return DateTimeRange(start: DateTime(now.year, now.month, now.day - 29), end: tomorrow);
      case 'custom':
        final c = _custom!;
        return DateTimeRange(
            start: DateTime(c.start.year, c.start.month, c.start.day),
            end: DateTime(c.end.year, c.end.month, c.end.day + 1));
      default:
        return DateTimeRange(start: today, end: tomorrow);
    }
  }

  Future<void> _pickCustom() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: now,
      initialDateRange: _custom,
    );
    if (picked == null) return;
    setState(() {
      _custom = picked;
      _period = 'custom';
    });
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final range = _range();
    try {
      final res = await Supabase.instance.client.rpc('admin_report', params: {
        'p_from': range.start.toUtc().toIso8601String(),
        'p_to': range.end.toUtc().toIso8601String(),
      });
      _data = Map<String, dynamic>.from(res as Map);
      _loaded = range;
      try {
        final len = range.end.difference(range.start);
        final prev = await Supabase.instance.client.rpc('admin_report', params: {
          'p_from': range.start.subtract(len).toUtc().toIso8601String(),
          'p_to': range.start.toUtc().toIso8601String(),
        });
        _prev = Map<String, dynamic>.from(prev as Map);
      } catch (_) {
        _prev = null;
      }
    } on PostgrestException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Reports need an internet connection. Connect and press Refresh.';
    }
    if (mounted) setState(() => _loading = false);
  }

  String _dateText(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  List<Map<String, dynamic>> _list(String key) =>
      ((_data?[key] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  Map<String, dynamic> _map(String key) =>
      Map<String, dynamic>.from((_data?[key] as Map?) ?? const {});

  @override
  Widget build(BuildContext context) {
    final range = _loaded;
    return DefaultTabController(
      length: 6,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('Reports',
                          style: TextStyle(
                              fontSize: 24, fontWeight: FontWeight.w800, color: Brand.navy)),
                    ),
                    OutlinedButton.icon(
                        onPressed: _loading ? null : _load,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Refresh')),
                  ],
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final e in _periods.entries)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(e.key == 'custom' && _custom != null
                                ? '${_dateText(_custom!.start)} to ${_dateText(_custom!.end)}'
                                : e.value),
                            selected: _period == e.key,
                            onSelected: (_) {
                              if (e.key == 'custom') {
                                _pickCustom();
                              } else {
                                setState(() => _period = e.key);
                                _load();
                              }
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                if (range != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                        'Showing ${_dateText(range.start)} to ${_dateText(range.end.subtract(const Duration(days: 1)))}'
                        ' · Sales count paid orders only · Amounts include VAT unless stated',
                        style: const TextStyle(color: Brand.muted, fontSize: 12)),
                  ),
              ],
            ),
          ),
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: Brand.navy,
            indicatorColor: Brand.gold,
            tabs: [
              Tab(text: 'Sales'),
              Tab(text: 'Products'),
              Tab(text: 'Buying list'),
              Tab(text: 'Stock usage'),
              Tab(text: 'Stock value & purchases'),
              Tab(text: 'Cancelled orders'),
            ],
          ),
          Expanded(
            child: _loading && _data == null
                ? const Center(child: CircularProgressIndicator())
                : _error != null && _data == null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_error!, style: const TextStyle(color: Brand.red)),
                        ))
                    : Stack(
                        children: [
                          TabBarView(children: [
                            _sales(),
                            _products(),
                            _buying(),
                            _usage(),
                            _valuation(),
                            _voids(),
                          ]),
                          if (_loading) const LinearProgressIndicator(),
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  // ---- shared bits ---------------------------------------------------------

  Widget _tile(String label, String value, {String? sub, Color? color}) => Container(
        width: 190,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Brand.border)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: Brand.muted, fontSize: 12)),
            const SizedBox(height: 4),
            Text(value,
                style: TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w800, color: color ?? Brand.navy)),
            if (sub != null) Text(sub, style: const TextStyle(color: Brand.muted, fontSize: 12)),
          ],
        ),
      );

  Widget _section(String title, Widget child, {Widget? action, String? note}) => Card(
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                    child: Text(title,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                if (action != null) action,
              ]),
              if (note != null)
                Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(note, style: const TextStyle(color: Brand.muted, fontSize: 12))),
              const SizedBox(height: 8),
              child,
            ],
          ),
        ),
      );

  Widget _table(List<String> cols, List<List<String>> rows,
      {Set<int> right = const {}, List<String>? total}) {
    if (rows.isEmpty) {
      return const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('Nothing to show for this period.', style: TextStyle(color: Brand.muted)));
    }
    DataRow row(List<String> r, {bool bold = false}) => DataRow(cells: [
          for (var i = 0; i < r.length; i++)
            DataCell(Align(
                alignment: right.contains(i) ? Alignment.centerRight : Alignment.centerLeft,
                child: Text(r[i],
                    style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w400)))),
        ]);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 40,
        dataRowMinHeight: 38,
        dataRowMaxHeight: 52,
        columnSpacing: 28,
        columns: [
          for (var i = 0; i < cols.length; i++)
            DataColumn(label: Text(cols[i], style: const TextStyle(fontWeight: FontWeight.w700)), numeric: right.contains(i)),
        ],
        rows: [for (final r in rows) row(r), if (total != null) row(total, bold: true)],
      ),
    );
  }

  String _q(dynamic v) {
    final x = n(v);
    return x == x.roundToDouble() ? x.toInt().toString() : x.toStringAsFixed(2);
  }

  /// "Up 12.3% on the previous period" under a tile.
  String? _vs(String section, String field) {
    if (_prev == null) return null;
    final cur = n((_data?[section] as Map?)?[field]).toDouble();
    final old = n((_prev?[section] as Map?)?[field]).toDouble();
    if (old == 0) return cur == 0 ? null : 'New, none in previous period';
    final d = (cur - old) / old * 100;
    return '${d >= 0 ? 'Up' : 'Down'} ${d.abs().toStringAsFixed(1)}% on previous period';
  }

  String _pct(num part, num whole) =>
      whole == 0 ? '-' : '${(part / whole * 100).toStringAsFixed(1)}%';

  // ---- Sales ---------------------------------------------------------------

  Widget _sales() {
    final s = _map('summary');
    final unpaid = _map('unpaid');
    final voided = _map('voided');
    const typeNames = {'eat_in': 'Eat in', 'take_away': 'Take away', 'delivery': 'Delivery'};
    return ListView(padding: const EdgeInsets.all(20), children: [
      Wrap(spacing: 12, runSpacing: 12, children: [
        _tile('Sales (incl. VAT)', money(n(s['gross'])), sub: _vs('summary', 'gross')),
        _tile('Sales (excl. VAT)', money(n(s['net'])), sub: _vs('summary', 'net')),
        _tile('VAT collected', money(n(s['vat']))),
        _tile('Paid orders', '${s['orders'] ?? 0}',
            sub: 'Average ${money(n(s['avg_order']))}\n${_vs('summary', 'orders') ?? ''}'),
        _tile('Unpaid orders', '${unpaid['orders'] ?? 0}',
            sub: money(n(unpaid['total'])), color: n(unpaid['orders']) > 0 ? Brand.amber : null),
        _tile('Cancelled orders', '${voided['orders'] ?? 0}',
            sub: money(n(voided['total'])), color: n(voided['orders']) > 0 ? Brand.red : null),
      ]),
      const SizedBox(height: 16),
      LineCard(
        title: 'Sales trend',
        points: [
          for (final d in _list('by_day'))
            ChartPoint('${d['day']}'.substring(5), n(d['total']).toDouble(),
                detail: '${d['orders']} orders')
        ],
        format: (v) => money(v),
        note: 'Tap a point to pin its figures.',
      ),
      BarCard(
        title: 'Busiest hours',
        points: [
          for (final h in _list('by_hour'))
            ChartPoint('${n(h['hour']).toInt()}h', n(h['total']).toDouble(),
                detail: '${h['orders']} orders')
        ],
        format: (v) => money(v),
        color: const Color(0xFF2C7BE5),
        note: 'Use this to plan staffing and prep.',
      ),
      LayoutBuilder(builder: (context, box) {
        final pay = PieCard(
          title: 'Payment methods',
          slices: [
            for (final p in _list('payments'))
              ChartPoint(p['method'] == 'cash' ? 'Cash' : 'Credit card', n(p['amount']).toDouble())
          ],
          format: (v) => money(v),
        );
        final type = PieCard(
          title: 'Order types',
          slices: [
            for (final t in _list('by_type'))
              ChartPoint(typeNames[t['type']] ?? '${t['type']}', n(t['total']).toDouble())
          ],
          format: (v) => money(v),
        );
        if (box.maxWidth > 1000) {
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: pay),
            const SizedBox(width: 16),
            Expanded(child: type),
          ]);
        }
        return Column(children: [pay, type]);
      }),
      _section(
          'Payments received',
          _table(['Method', 'Payments', 'Amount'], [
            for (final p in _list('payments'))
              [p['method'] == 'cash' ? 'Cash' : 'Credit card (manual)', '${p['count']}', money(n(p['amount']))]
          ], right: {1, 2})),
      _section(
          'Sales by day',
          _table(['Date', 'Orders', 'Sales'], [
            for (final d in _list('by_day')) ['${d['day']}', '${d['orders']}', money(n(d['total']))]
          ], right: {1, 2})),
      _section(
          'Sales by order type',
          _table(['Type', 'Orders', 'Sales'], [
            for (final t in _list('by_type'))
              [typeNames[t['type']] ?? '${t['type']}', '${t['orders']}', money(n(t['total']))]
          ], right: {1, 2})),
    ]);
  }

  // ---- Products ------------------------------------------------------------

  Widget _products() {
    final rows = _list('products');
    final cats = _list('categories');
    double q = 0, rev = 0, net = 0, cost = 0;
    for (final p in rows) {
      q += n(p['qty']);
      rev += n(p['revenue']);
      net += n(p['net']);
      cost += n(p['cost']);
    }
    final cats2 = ['All', ...{for (final p in rows) '${p['category']}'}];
    if (!cats2.contains(_category)) _category = 'All';
    final filtered = rows.where((p) => _category == 'All' || p['category'] == _category).toList();
    double metricOf(Map<String, dynamic> p) {
      switch (_metric) {
        case 'qty':
          return n(p['qty']).toDouble();
        case 'profit':
          return n(p['net']).toDouble() - n(p['cost']).toDouble();
        default:
          return n(p['revenue']).toDouble();
      }
    }

    filtered.sort((a, b) => metricOf(b).compareTo(metricOf(a)));
    final shown = filtered.take(_topN).toList();
    String fmtMetric(double v) => _metric == 'qty' ? '${v.toStringAsFixed(0)} sold' : money(v);

    return ListView(padding: const EdgeInsets.all(20), children: [
      RankedBars(
        title: 'Top products',
        points: [
          for (final p in shown)
            ChartPoint('${p['name']}', metricOf(p),
                detail:
                    '${_q(p['qty'])} sold · sales ${money(n(p['revenue']))} · profit ${money(n(p['net']) - n(p['cost']))} · margin ${_pct(n(p['net']) - n(p['cost']), n(p['net']))}')
        ],
        format: fmtMetric,
        note: 'Tap a product for its figures. Change what is measured, the category or how many to show.',
        action: Wrap(spacing: 8, children: [
          SegmentedButton<String>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: 'revenue', label: Text('Sales')),
              ButtonSegment(value: 'profit', label: Text('Profit')),
              ButtonSegment(value: 'qty', label: Text('Qty')),
            ],
            selected: {_metric},
            onSelectionChanged: (v) => setState(() => _metric = v.first),
          ),
          DropdownButton<String>(
            value: _category,
            underline: const SizedBox(),
            items: [for (final c in cats2) DropdownMenuItem(value: c, child: Text(c))],
            onChanged: (v) => setState(() => _category = v ?? 'All'),
          ),
          DropdownButton<int>(
            value: _topN,
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(value: 5, child: Text('Top 5')),
              DropdownMenuItem(value: 10, child: Text('Top 10')),
              DropdownMenuItem(value: 20, child: Text('Top 20')),
              DropdownMenuItem(value: 100, child: Text('All')),
            ],
            onChanged: (v) => setState(() => _topN = v ?? 10),
          ),
        ]),
      ),
      PieCard(
        title: 'Sales share by category',
        slices: [for (final c in cats) ChartPoint('${c['category']}', n(c['revenue']).toDouble())],
        format: (v) => money(v),
      ),
      RankedBars(
        title: 'Lowest margin products',
        points: [
          for (final p in ([...rows.where((p) => n(p['net']) > 0)]
                ..sort((a, b) => ((n(a['net']) - n(a['cost'])) / n(a['net']))
                    .compareTo((n(b['net']) - n(b['cost'])) / n(b['net']))))
              .take(8))
            ChartPoint('${p['name']}', (n(p['net']) - n(p['cost'])) / n(p['net']) * 100,
                detail: 'Sales excl. VAT ${money(n(p['net']))}, ingredient cost ${money(n(p['cost']))}')
        ],
        format: (v) => '${v.toStringAsFixed(1)}%',
        colorFor: (p) => p.value < 55 ? Brand.red : (p.value < 65 ? Brand.amber : Brand.green),
        note: 'Red is under 55% margin, amber under 65%. Consider repricing these or checking portion sizes.',
      ),
      _section(
          'Product sales and profit',
          _table(
            ['Product', 'Category', 'Sold', 'Sales incl. VAT', 'Sales excl. VAT', 'Ingredient cost', 'Profit', 'Margin'],
            [
              for (final p in rows)
                [
                  '${p['name']}',
                  '${p['category']}',
                  _q(p['qty']),
                  money(n(p['revenue'])),
                  money(n(p['net'])),
                  money(n(p['cost'])),
                  money(n(p['net']) - n(p['cost'])),
                  _pct(n(p['net']) - n(p['cost']), n(p['net'])),
                ]
            ],
            right: {2, 3, 4, 5, 6, 7},
            total: rows.isEmpty
                ? null
                : ['Total', '', _q(q), money(rev), money(net), money(cost), money(net - cost), _pct(net - cost, net)],
          ),
          note: 'Ingredient cost uses each ingredient\'s current average cost and the product recipe. Profit = sales excl. VAT minus ingredient cost.'),
      _section(
          'By category',
          _table(['Category', 'Sold', 'Sales incl. VAT', 'Ingredient cost', 'Margin'], [
            for (final c in cats)
              [
                '${c['category']}',
                _q(c['qty']),
                money(n(c['revenue'])),
                money(n(c['cost'])),
                _pct(n(c['net']) - n(c['cost']), n(c['net'])),
              ]
          ], right: {1, 2, 3, 4})),
    ]);
  }

  // ---- Buying list ---------------------------------------------------------

  Widget _buying() {
    final rows = _list('reorder');
    final bySupplier = <String, List<Map<String, dynamic>>>{};
    for (final r in rows) {
      bySupplier.putIfAbsent('${r['supplier']}', () => []).add(r);
    }
    final grand = rows.fold<double>(0, (s, r) => s + n(r['est_cost']).toDouble());

    return ListView(padding: const EdgeInsets.all(20), children: [
      Wrap(spacing: 12, runSpacing: 12, children: [
        _tile('Items to buy', '${rows.length}',
            color: rows.isEmpty ? Brand.green : Brand.red),
        _tile('Estimated cost', money(grand), sub: 'At current average cost, excl. VAT'),
        _tile('Out of stock', '${rows.where((r) => n(r['on_hand']) <= 0).length}',
            color: Brand.red),
      ]),
      const SizedBox(height: 16),
      RankedBars(
        title: 'How long stock will last',
        points: [
          for (final r in ([...rows.where((r) => r['days_left'] != null)]
                ..sort((a, b) => n(a['days_left']).compareTo(n(b['days_left']))))
              .take(12))
            ChartPoint('${r['item']}', n(r['days_left']).toDouble(),
                detail:
                    '${_q(r['on_hand'])} ${r['unit']} on hand, using about ${_q(r['daily_use'])} ${r['unit']} a day, order ${_q(r['suggested'])} ${r['unit']} from ${r['supplier']}')
        ],
        format: (v) => '${v.toStringAsFixed(1)} days',
        colorFor: (p) => p.value < 2 ? Brand.red : (p.value < 5 ? Brand.amber : Brand.green),
        note: 'Based on the last 14 days of use. Red is under 2 days left.',
      ),
      const SizedBox(height: 8),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
            'Every item at or below its minimum level, grouped by supplier. Suggested order brings stock up to twice the minimum level. '
            'Days left uses the last 14 days of usage. Always current, the date range above does not apply.',
            style: TextStyle(color: Brand.muted, fontSize: 12)),
      ),
      if (rows.isEmpty)
        const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Nothing is below its minimum level.', style: TextStyle(color: Brand.green))),
      for (final e in bySupplier.entries)
        _section(
          e.key,
          _table(
            ['Item', 'On hand', 'Minimum', 'Days left', 'Suggested order', 'Est. cost'],
            [
              for (final r in e.value)
                [
                  '${r['item']}',
                  '${_q(r['on_hand'])} ${r['unit']}',
                  _q(r['min_level']),
                  r['days_left'] == null ? '-' : '${r['days_left']}',
                  '${_q(r['suggested'])} ${r['unit']}',
                  money(n(r['est_cost'])),
                ]
            ],
            right: {1, 2, 3, 4, 5},
            total: [
              'Supplier total',
              '',
              '',
              '',
              '',
              money(e.value.fold<double>(0, (s, r) => s + n(r['est_cost']).toDouble()))
            ],
          ),
          action: TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy order list'),
            onPressed: () async {
              final text = StringBuffer('Order for ${e.key}\n');
              for (final r in e.value) {
                text.writeln('${_q(r['suggested'])} ${r['unit']}  ${r['item']}');
              }
              await Clipboard.setData(ClipboardData(text: text.toString()));
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Order list for ${e.key} copied.')));
              }
            },
          ),
        ),
    ]);
  }

  // ---- Stock usage ---------------------------------------------------------

  Widget _usage() {
    final rows = _list('usage');
    final cost = rows.fold<double>(0, (s, r) => s + n(r['cost_used']).toDouble());
    return ListView(padding: const EdgeInsets.all(20), children: [
      Wrap(spacing: 12, runSpacing: 12, children: [
        _tile('Ingredient cost used', money(cost), sub: 'From sales, at average cost'),
      ]),
      const SizedBox(height: 16),
      RankedBars(
        title: 'Biggest ingredient costs',
        points: [
          for (final r in ([...rows]..sort((a, b) => n(b['cost_used']).compareTo(n(a['cost_used'])))).take(10))
            ChartPoint('${r['item']}', n(r['cost_used']).toDouble(),
                detail: 'Used ${_q(r['sold'])} ${r['unit']}, wasted ${_q(r['waste'])} ${r['unit']}')
        ],
        format: (v) => money(v),
        note: 'Where your food spend goes. Tap a bar for the quantity used.',
      ),
      RankedBars(
        title: 'Waste',
        points: [
          for (final r in ([...rows.where((r) => n(r['waste']) > 0)]
                ..sort((a, b) => (n(b['waste']) * 1).compareTo(n(a['waste']) * 1))).take(10))
            ChartPoint('${r['item']}', n(r['waste']).toDouble(), detail: r['unit'] == null ? '' : 'Unit: ${r['unit']}')
        ],
        format: (v) => _q(v),
        colorFor: (_) => Brand.red,
        note: 'Quantity written off as waste in the period.',
      ),
      _section(
          'Stock movement by item',
          _table(
            ['Item', 'Used in sales', 'Received', 'Waste', 'Adjusted', 'Cost of use'],
            [
              for (final r in rows)
                [
                  '${r['item']}',
                  '${_q(r['sold'])} ${r['unit']}',
                  '${_q(r['received'])} ${r['unit']}',
                  '${_q(r['waste'])} ${r['unit']}',
                  _q(r['adjusted']),
                  money(n(r['cost_used'])),
                ]
            ],
            right: {1, 2, 3, 4, 5},
          ),
          note: 'Used in sales is net of cancelled orders (their stock is returned).'),
    ]);
  }

  // ---- Stock value & purchases ----------------------------------------------

  Widget _valuation() {
    final purchases = _list('purchases');
    final total = purchases.fold<double>(0, (s, p) => s + n(p['total']).toDouble());
    return ListView(padding: const EdgeInsets.all(20), children: [
      Wrap(spacing: 12, runSpacing: 12, children: [
        _tile('Stock on hand (value)', money(n(_data?['valuation_total'])),
            sub: 'At average cost, excl. VAT'),
        _tile('Purchased in period', money(total), sub: 'Posted GRVs, incl. VAT'),
      ]),
      const SizedBox(height: 16),
      PieCard(
        title: 'Where your stock money is',
        slices: [for (final v in _list('valuation')) ChartPoint('${v['category']}', n(v['value']).toDouble())],
        format: (v) => money(v),
        note: 'Tap a slice to see its value.',
      ),
      BarCard(
        title: 'Purchases by supplier',
        points: [
          for (final p in purchases)
            ChartPoint('${p['supplier']}'.split(' ').first, n(p['total']).toDouble(),
                detail: '${p['supplier']}, ${p['grvs']} deliveries')
        ],
        format: (v) => money(v),
        color: const Color(0xFF1E7A4A),
      ),
      _section(
          'Stock value by category',
          _table(['Category', 'Items', 'Value'], [
            for (final v in _list('valuation')) ['${v['category']}', '${v['items']}', money(n(v['value']))]
          ], right: {1, 2}),
          note: 'Current stock, the date range above does not apply.'),
      _section(
          'Purchases by supplier',
          _table(['Supplier', 'GRVs', 'Excl. VAT', 'VAT', 'Total'], [
            for (final p in purchases)
              [
                '${p['supplier']}',
                '${p['grvs']}',
                money(n(p['subtotal'])),
                money(n(p['vat'])),
                money(n(p['total']))
              ]
          ], right: {1, 2, 3, 4}),
          note: 'Only stock that has been received and posted counts.'),
    ]);
  }

  // ---- Cancelled orders ------------------------------------------------------

  Widget _voids() {
    final rows = _list('voids');
    String when(dynamic v) {
      final t = parseTime(v);
      if (t == null) return '';
      return '${_dateText(t)} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }

    return ListView(padding: const EdgeInsets.all(20), children: [
      _section(
          'Cancelled orders',
          _table(['Order', 'When', 'Amount', 'Was paid', 'Reason'], [
            for (final v in rows)
              [
                '#${v['ref']}',
                when(v['at']),
                money(n(v['total'])),
                v['paid'] == true ? 'Yes' : 'No',
                '${v['reason'] ?? ''}',
              ]
          ], right: {2}),
          note: 'A paid order that was cancelled needs a refund. Check these against the till.'),
    ]);
  }
}
