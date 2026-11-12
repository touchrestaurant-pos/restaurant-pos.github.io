import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/repo.dart';
import '../receipt/download_file.dart';
import '../theme.dart';
import 'report_charts.dart';

/// Loads the server's disbursement_report for a range of days (both ends included).
class _Loader extends StatefulWidget {
  const _Loader({required this.range, required this.builder});
  final DateTimeRange range;
  final Widget Function(BuildContext, Map<String, dynamic>) builder;

  @override
  State<_Loader> createState() => _LoaderState();
}

class _LoaderState extends State<_Loader> {
  Map<String, dynamic>? _d;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _Loader old) {
    super.didUpdateWidget(old);
    if (old.range != widget.range) _load();
  }

  String _day(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // The reports screen's range ends the day after the last day, so step back one day.
      final last = widget.range.end.subtract(const Duration(days: 1));
      final r = await Supabase.instance.client
          .rpc('disbursement_report', params: {'p_from': _day(widget.range.start), 'p_to': _day(last.isBefore(widget.range.start) ? widget.range.start : last)});
      _d = Map<String, dynamic>.from(r as Map);
    } on PostgrestException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'This report needs an internet connection.';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _d == null) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, style: const TextStyle(color: Brand.red))));
    return Stack(children: [
      widget.builder(context, _d!),
      if (_loading) const LinearProgressIndicator(),
    ]);
  }
}

List<Map<String, dynamic>> _l(dynamic v) => ((v as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

Widget _tile(String label, String value, {String? sub, Color? color}) => SizedBox(
      width: 210,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(color: Brand.muted, fontWeight: FontWeight.w600)),
            Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color ?? Brand.navy)),
            if (sub != null) Text(sub, style: const TextStyle(color: Brand.muted, fontSize: 12)),
          ]),
        ),
      ),
    );

Widget _card(String title, Widget child, {Widget? action, String? note}) => Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
            if (action != null) action,
          ]),
          if (note != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(note, style: const TextStyle(color: Brand.muted, fontSize: 12))),
          const SizedBox(height: 10),
          child,
        ]),
      ),
    );

Widget _table(List<String> cols, List<List<String>> rows, {Set<int> right = const {}, List<String>? total}) {
  if (rows.isEmpty) return const Text('Nothing to show for this period.', style: TextStyle(color: Brand.muted));
  DataRow row(List<String> r, {bool bold = false}) => DataRow(cells: [
        for (var i = 0; i < r.length; i++)
          DataCell(Align(
              alignment: right.contains(i) ? Alignment.centerRight : Alignment.centerLeft,
              child: Text(r[i], style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w400)))),
      ]);
  return SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: DataTable(
      headingRowHeight: 40,
      dataRowMinHeight: 38,
      dataRowMaxHeight: 56,
      columnSpacing: 24,
      columns: [for (var i = 0; i < cols.length; i++) DataColumn(label: Text(cols[i], style: const TextStyle(fontWeight: FontWeight.w700)), numeric: right.contains(i))],
      rows: [for (final r in rows) row(r), if (total != null) row(total, bold: true)],
    ),
  );
}

Widget _csvButton(BuildContext context, String name, List<List<String>> rows) => OutlinedButton.icon(
      icon: const Icon(Icons.download, size: 18),
      label: const Text('Excel (CSV)'),
      onPressed: () async {
        String q(String v) => '"${v.replaceAll('"', '""')}"';
        final text = '﻿${rows.map((r) => r.map(q).join(',')).join('\n')}\n';
        await downloadBytes(name, Uint8List.fromList(utf8.encode(text)), 'text/csv');
      },
    );

String _short(dynamic day) => '$day'.length >= 10 ? '$day'.substring(5, 10) : '$day';

/// Money taken out of the tills: by what it was for, by day, by till user, with every reference.
class TillMoneyReport extends StatelessWidget {
  const TillMoneyReport({super.key, required this.range});
  final DateTimeRange range;

  @override
  Widget build(BuildContext context) => _Loader(
        range: range,
        builder: (context, d) {
          final cats = _l(d['by_category']);
          final days = _l(d['by_day']);
          final staff = _l(d['by_staff']);
          final items = _l(d['items']);
          final csv = [
            ['Date', 'Category', 'Reference', 'Note', 'Taken by', 'Amount'],
            for (final i in items) ['${i['day']}', '${i['category']}', '${i['reference'] ?? ''}', '${i['note'] ?? ''}', '${i['by']}', n(i['amount']).toStringAsFixed(2)],
          ];
          return ListView(padding: const EdgeInsets.all(20), children: [
            Wrap(spacing: 12, runSpacing: 12, children: [
              _tile('Taken out of tills', money(n(d['total'])), sub: '${d['count']} pay-outs', color: n(d['total']) > 0 ? Brand.amber : null),
              _tile('Cash added to drawers', money(n(d['float_in']))),
              _tile('Biggest category', cats.isEmpty ? '-' : '${cats.first['category']}', sub: cats.isEmpty ? null : money(n(cats.first['total']))),
            ]),
            const SizedBox(height: 16),
            AdaptivePie(
              title: 'What the money was for',
              slices: [for (final c in cats) ChartPoint('${c['category']}', n(c['total']).toDouble(), detail: '${c['count']} pay-outs')],
              format: (v) => money(v),
            ),
            AdaptiveBars(
              title: 'Taken out each day',
              points: [for (final x in days) ChartPoint(_short(x['day']), n(x['total']).toDouble(), detail: '${x['count']} pay-outs')],
              format: (v) => money(v),
              color: Brand.amber,
            ),
            AdaptiveRanked(
              title: 'By till user',
              points: [for (final x in staff) ChartPoint('${x['name']}', n(x['total']).toDouble(), detail: '${x['count']} pay-outs')],
              format: (v) => money(v),
              note: 'Who took the cash out.',
            ),
            _card(
              'Every pay-out',
              _table(['Date', 'What', 'Reference', 'Note', 'Taken by', 'Amount'], [
                for (final i in items)
                  ['${i['day']}', '${i['category']}', '${i['reference'] ?? ''}', '${i['note'] ?? ''}', '${i['by']}', money(n(i['amount']))]
              ], right: {5}, total: ['', '', '', '', 'Total', money(n(d['total']))]),
              action: _csvButton(context, 'Till-money_${_short(range.start)}.csv', csv),
              note: 'Match the reference to the slip or invoice kept at the till.',
            ),
          ]);
        },
      );
}

/// Cash in and out of the drawers, day by day.
class CashFlowReport extends StatelessWidget {
  const CashFlowReport({super.key, required this.range});
  final DateTimeRange range;

  @override
  Widget build(BuildContext context) => _Loader(
        range: range,
        builder: (context, d) {
          final flow = _l(d['cash_flow']);
          double sum(String k) => flow.fold<double>(0, (s, r) => s + n(r[k]).toDouble());
          double inn(Map r) => n(r['sales']).toDouble() + n(r['accounts']).toDouble() + n(r['float_in']).toDouble();
          double out(Map r) => n(r['refunds']).toDouble() + n(r['credit_back']).toDouble() + n(r['payouts']).toDouble();
          final totalIn = flow.fold<double>(0, (s, r) => s + inn(r));
          final totalOut = flow.fold<double>(0, (s, r) => s + out(r));
          final rows = [
            for (final r in flow)
              [
                '${r['day']}',
                money(n(r['sales'])),
                money(n(r['accounts'])),
                money(n(r['float_in'])),
                '-${money(n(r['refunds']))}',
                '-${money(n(r['credit_back']))}',
                '-${money(n(r['payouts']))}',
                money(inn(r) - out(r)),
              ]
          ];
          final csv = [
            ['Date', 'Cash sales and tips', 'Cash on accounts', 'Added to drawer', 'Cash refunds', 'Account credit paid back', 'Paid out', 'Net'],
            for (final r in flow)
              [
                '${r['day']}',
                n(r['sales']).toStringAsFixed(2),
                n(r['accounts']).toStringAsFixed(2),
                n(r['float_in']).toStringAsFixed(2),
                n(r['refunds']).toStringAsFixed(2),
                n(r['credit_back']).toStringAsFixed(2),
                n(r['payouts']).toStringAsFixed(2),
                (inn(r) - out(r)).toStringAsFixed(2),
              ]
          ];
          return ListView(padding: const EdgeInsets.all(20), children: [
            Wrap(spacing: 12, runSpacing: 12, children: [
              _tile('Cash in', money(totalIn), sub: 'Sales, tips, accounts, drawer top-ups', color: Brand.green),
              _tile('Cash out', money(totalOut), sub: 'Refunds, credit paid back, pay-outs', color: totalOut > 0 ? Brand.amber : null),
              _tile('Net cash', money(totalIn - totalOut), sub: 'Before opening floats and counts'),
            ]),
            const SizedBox(height: 16),
            AdaptiveLine(
              title: 'Net cash each day',
              points: [for (final r in flow) ChartPoint(_short(r['day']), inn(r) - out(r), detail: 'In ${money(inn(r))} · out ${money(out(r))}')],
              format: (v) => money(v),
            ),
            AdaptiveBars(
              title: 'Cash taken in each day',
              points: [for (final r in flow) ChartPoint(_short(r['day']), inn(r))],
              format: (v) => money(v),
              color: Brand.green,
            ),
            AdaptivePie(
              title: 'Where cash went out',
              slices: [
                ChartPoint('Pay-outs', sum('payouts')),
                ChartPoint('Cash refunds', sum('refunds')),
                ChartPoint('Account credit paid back', sum('credit_back')),
              ].where((p) => p.value > 0).toList(),
              format: (v) => money(v),
            ),
            _card(
              'Cash flow by day',
              _table(['Date', 'Cash sales + tips', 'Cash on accounts', 'Added to drawer', 'Cash refunds', 'Credit paid back', 'Paid out', 'Net'], rows,
                  right: {1, 2, 3, 4, 5, 6, 7},
                  total: ['Total', money(sum('sales')), money(sum('accounts')), money(sum('float_in')), '-${money(sum('refunds'))}', '-${money(sum('credit_back'))}', '-${money(sum('payouts'))}', money(totalIn - totalOut)]),
              action: _csvButton(context, 'Cash-flow_${_short(range.start)}.csv', csv),
              note: 'Counts cash only. Card payments and sales on account are not in the drawer.',
            ),
          ]);
        },
      );
}
