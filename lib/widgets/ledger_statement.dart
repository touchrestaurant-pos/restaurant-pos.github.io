import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../data/repo.dart';
import '../receipt/download_file.dart';
import '../receipt/ledger.dart';
import '../screens/report_charts.dart';
import '../theme.dart';

typedef LedgerLoader = Future<Ledger> Function(DateTime from, DateTime to);

String _f(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// The statement window used for customers (debtors) and suppliers (creditors):
/// a date range, a grid list or charts, and print / PDF / spreadsheet export.
///
/// [onPay] adds a Pay / Take payment button that closes the window and gets the balance.
Future<void> showLedgerStatement(
  BuildContext context, {
  required String heading,
  required LedgerLoader load,
  String initialPreset = 'This month',
  String? payLabel,
  void Function(double owing)? onPay,
  String fileName = 'Statement',
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _LedgerDialog(
          heading: heading, load: load, initialPreset: initialPreset, payLabel: payLabel, onPay: onPay, fileName: fileName),
    );

class _LedgerDialog extends StatefulWidget {
  const _LedgerDialog(
      {required this.heading, required this.load, required this.initialPreset, this.payLabel, this.onPay, required this.fileName});
  final String heading;
  final LedgerLoader load;
  final String initialPreset;
  final String? payLabel;
  final void Function(double owing)? onPay;
  final String fileName;

  @override
  State<_LedgerDialog> createState() => _LedgerDialogState();
}

class _LedgerDialogState extends State<_LedgerDialog> {
  static const _presets = ['This month', 'Last month', 'Last 3 months', 'This year', 'All time'];
  late DateTime _from;
  late DateTime _to;
  String _preset = '';
  Ledger? _g;
  bool _busy = true;
  String? _err;
  String _view = 'list';

  @override
  void initState() {
    super.initState();
    _applyPreset(widget.initialPreset, reload: false);
    _reload();
  }

  void _applyPreset(String p, {bool reload = true}) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (p) {
      case 'Last month':
        _from = DateTime(now.year, now.month - 1, 1);
        _to = DateTime(now.year, now.month, 0);
      case 'Last 3 months':
        _from = DateTime(now.year, now.month - 2, 1);
        _to = today;
      case 'This year':
        _from = DateTime(now.year, 1, 1);
        _to = today;
      case 'All time':
        _from = DateTime(2020, 1, 1);
        _to = today;
      default:
        p = 'This month';
        _from = DateTime(now.year, now.month, 1);
        _to = today;
    }
    _preset = p;
    if (reload) _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final g = await widget.load(_from, _to);
      if (!mounted) return;
      setState(() {
        _g = g;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = _message(e);
        _busy = false;
      });
    }
  }

  String _message(Object e) {
    final s = '$e';
    if (s.contains('SocketException') || s.contains('Failed host lookup') || s.contains('ClientException')) {
      return 'This needs an internet connection.';
    }
    final m = RegExp(r'message: ([^,}]+)').firstMatch(s);
    return m?.group(1) ?? s;
  }

  Future<void> _pick(bool isFrom) async {
    final d = await showDatePicker(
        context: context,
        initialDate: isFrom ? _from : _to,
        firstDate: DateTime(2020),
        lastDate: DateTime(DateTime.now().year + 1));
    if (d == null) return;
    setState(() {
      if (isFrom) {
        _from = d;
      } else {
        _to = d;
      }
      _preset = '';
    });
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final g = _g;
    final close = g?.closing ?? 0;
    return AlertDialog(
      title: Row(children: [
        Expanded(
            child: Text(g?.partyName ?? widget.heading, style: const TextStyle(fontWeight: FontWeight.w800), overflow: TextOverflow.ellipsis)),
        if (g != null)
          Text(close < -0.005 ? 'In credit ${money(-close)}' : money(close),
              style: TextStyle(fontWeight: FontWeight.w800, color: close > 0.005 ? Brand.red : Brand.green)),
      ]),
      content: SizedBox(
        width: 760,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (final p in _presets)
              ChoiceChip(label: Text(p), selected: _preset == p, onSelected: (_) => setState(() => _applyPreset(p))),
            OutlinedButton(onPressed: () => _pick(true), child: Text('From ${_f(_from)}')),
            OutlinedButton(onPressed: () => _pick(false), child: Text('To ${_f(_to)}')),
          ]),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<String>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              const ButtonSegment(value: 'list', icon: Icon(Icons.grid_on, size: 16), label: Text('List')),
              const ButtonSegment(value: 'analysis', icon: Icon(Icons.insights, size: 16), label: Text('Analysis')),
              const ButtonSegment(value: 'balance', icon: Icon(Icons.show_chart, size: 16), label: Text('Balance')),
              if (g != null && g.lines.any((l) => l.party.isNotEmpty))
                const ButtonSegment(value: 'party', icon: Icon(Icons.groups_outlined, size: 16), label: Text('By name')),
              const ButtonSegment(value: 'month', icon: Icon(Icons.bar_chart, size: 16), label: Text('By month')),
              const ButtonSegment(value: 'mix', icon: Icon(Icons.pie_chart_outline, size: 16), label: Text('How paid')),
            ],
            selected: {_view},
            onSelectionChanged: (v) => setState(() => _view = v.first),
          )),
          const SizedBox(height: 8),
          if (_busy) const LinearProgressIndicator(),
          if (_err != null) Text(_err!, style: const TextStyle(color: Brand.red, fontWeight: FontWeight.w600)),
          if (g != null) Flexible(child: SingleChildScrollView(child: _body(g))),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        if (g != null) ...[
          OutlinedButton.icon(
              icon: const Icon(Icons.table_chart_outlined, size: 18),
              label: const Text('Spreadsheet'),
              onPressed: () => downloadBytes('${widget.fileName}.csv', ledgerCsv(g), 'text/csv')),
          FilledButton.tonalIcon(
              icon: const Icon(Icons.print_outlined, size: 18),
              label: const Text('Print / save PDF'),
              onPressed: () => Printing.layoutPdf(name: widget.fileName, onLayout: (_) => ledgerPdf(g))),
          if (widget.onPay != null && g.closing > 0.005)
            FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  widget.onPay!(g.closing);
                },
                child: Text('${widget.payLabel ?? 'Pay'} ${money(g.closing)}')),
        ],
      ],
    );
  }

  Widget _body(Ledger g) {
    final summary = Wrap(spacing: 8, runSpacing: 8, children: [
      _chip('Opening', money(g.opening)),
      _chip(g.chargeLabel, money(g.totalCharges)),
      _chip(g.paidLabel, money(g.totalPaid)),
      _chip('Closing', money(g.closing), bold: true),
    ]);
    switch (_view) {
      case 'analysis':
        return _analysis(g, summary);
      case 'balance':
        final pts = [for (final l in g.lines.where((l) => !l.muted)) ChartPoint(l.date, l.balance, detail: l.what)];
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          summary,
          const SizedBox(height: 8),
          pts.length < 2
              ? const Padding(padding: EdgeInsets.all(16), child: Text('Not enough activity in this period to draw a line.'))
              : LineCard(title: 'Balance after each entry', points: pts, format: (v) => money(v)),
        ]);
      case 'party':
        final ch = <String, double>{}, pd = <String, double>{};
        for (final l in g.lines) {
          if (l.party.isEmpty) continue;
          if (!l.muted) ch[l.party] = (ch[l.party] ?? 0) + l.charge;
          pd[l.party] = (pd[l.party] ?? 0) + l.paid;
        }
        final net = {for (final k in {...ch.keys, ...pd.keys}) k: (ch[k] ?? 0) - (pd[k] ?? 0)};
        List<ChartPoint> top(Map<String, double> m, {bool positiveOnly = false}) {
          final e = m.entries.where((x) => positiveOnly ? x.value > 0.005 : x.value > 0.005).toList()..sort((a, b) => b.value.compareTo(a.value));
          return [for (final x in e.take(10)) ChartPoint(x.key, x.value)];
        }
        return Column(children: [
          summary,
          const SizedBox(height: 8),
          RankedBars(title: 'Biggest balance growth (charged minus paid)', points: top(net, positiveOnly: true), format: (v) => money(v), colorFor: (_) => Brand.red),
          RankedBars(title: g.chargeLabel, points: top(ch), format: (v) => money(v)),
          RankedBars(title: g.paidLabel, points: top(pd), format: (v) => money(v), colorFor: (_) => Brand.green),
        ]);
      case 'month':
        final charge = <String, double>{};
        final paid = <String, double>{};
        for (final l in g.lines) {
          final m = l.date.length >= 7 ? l.date.substring(0, 7) : l.date;
          if (!l.muted) charge[m] = (charge[m] ?? 0) + l.charge;
          paid[m] = (paid[m] ?? 0) + l.paid;
        }
        final months = ({...charge.keys, ...paid.keys}.toList()..sort());
        if (months.isEmpty) return const Padding(padding: EdgeInsets.all(16), child: Text('No activity in this period.'));
        return Column(children: [
          summary,
          const SizedBox(height: 8),
          BarCard(title: g.chargeLabel, points: [for (final m in months) ChartPoint(m, charge[m] ?? 0)], format: (v) => money(v), color: Brand.navy),
          BarCard(title: g.paidLabel, points: [for (final m in months) ChartPoint(m, paid[m] ?? 0)], format: (v) => money(v), color: Brand.green),
        ]);
      case 'mix':
        final by = <String, double>{};
        for (final l in g.lines.where((l) => l.paid > 0)) {
          final k = l.group.isEmpty ? 'Payment' : l.group;
          by[k] = (by[k] ?? 0) + l.paid;
        }
        if (by.isEmpty) return const Padding(padding: EdgeInsets.all(16), child: Text('Nothing paid in this period.'));
        return Column(children: [
          summary,
          const SizedBox(height: 8),
          PieCard(
              title: 'How it was paid',
              slices: [for (final e in by.entries) ChartPoint(e.key, e.value)],
              format: (v) => money(v)),
        ]);
      default:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          summary,
          const SizedBox(height: 8),
          if (g.lines.isEmpty)
            Padding(
                padding: const EdgeInsets.all(12),
                child: Text('No activity in this period. Balance brought forward ${money(g.opening)}.'))
          else
            _grid(g),
          if (g.ageing != null && g.closing > 0.005)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                  'Owing by age:  0-30 ${money(g.ageing!['current'] ?? 0)}  ·  31-60 ${money(g.ageing!['d31'] ?? 0)}  ·  61-90 ${money(g.ageing!['d61'] ?? 0)}  ·  90+ ${money(g.ageing!['d90'] ?? 0)}',
                  style: const TextStyle(color: Brand.muted, fontSize: 12)),
            ),
        ]);
    }
  }

  /// Plain-language numbers about this account over the chosen dates.
  Widget _analysis(Ledger g, Widget summary) {
    final st = analyseLedger(g);
    if (st.chargeCount + st.paymentCount == 0) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        summary,
        const Padding(padding: EdgeInsets.all(16), child: Text('No activity in this period to analyse. Try a longer date range.')),
      ]);
    }
    final what = g.chargeLabel.toLowerCase();
    String days(double? v) => v == null ? 'n/a' : '${v.round()} days';
    final tips = <String>[
      if (st.avgDaysToPay != null) 'Items were settled on average ${st.avgDaysToPay!.round()} days after they were raised (oldest paid first).',
      if (st.oldestOpenDays != null && g.closing > 0.005) 'The oldest unpaid item is ${st.oldestOpenDays} days old.',
      if (g.totalCharges > 0.005)
        'Payments covered ${(st.paidShare * 100).round()}% of what was ${g.chargeLabel == 'Sales' ? 'sold on account' : 'bought'} in this period${st.paidShare < 0.999 ? ', so the balance grew by ${money(g.totalCharges - g.totalPaid)}' : (st.paidShare > 1.001 ? ', so the balance shrank by ${money(g.totalPaid - g.totalCharges)}' : '')}.',
      if (g.closing < -0.005) 'The account is in credit by ${money(-g.closing)}: more was paid than was charged.',
    ];
    final topCharges = ([...g.lines.where((l) => !l.muted && l.charge > 0)]..sort((a, b) => b.charge.compareTo(a.charge))).take(5);
    final topPays = ([...g.lines.where((l) => l.paid > 0)]..sort((a, b) => b.paid.compareTo(a.paid))).take(5);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      summary,
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        _chip('Number of $what', '${st.chargeCount}'),
        _chip('Average each', money(st.avgCharge)),
        _chip('Average per month', money(st.perMonthCharge)),
        _chip('Number of payments', '${st.paymentCount}'),
        _chip('Average payment', money(st.avgPayment)),
        _chip('Average days to pay', days(st.avgDaysToPay)),
        _chip('Oldest unpaid', st.oldestOpenDays == null ? 'none' : '${st.oldestOpenDays} days'),
        _chip('Paid vs charged', '${(st.paidShare * 100).round()}%'),
      ]),
      const SizedBox(height: 10),
      for (final t in tips)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(padding: EdgeInsets.only(top: 2, right: 6), child: Icon(Icons.insights, size: 16, color: Brand.navy)),
            Expanded(child: Text(t)),
          ]),
        ),
      const SizedBox(height: 8),
      if (topCharges.isNotEmpty)
        RankedBars(
            title: 'Biggest ${g.chargeLabel == 'Sales' ? 'sales' : 'deliveries'}',
            points: [for (final l in topCharges) ChartPoint('${l.date}  ${l.what}', l.charge)],
            format: (v) => money(v)),
      if (topPays.isNotEmpty)
        RankedBars(
            title: 'Biggest payments',
            points: [for (final l in topPays) ChartPoint('${l.date}  ${l.what}', l.paid)],
            format: (v) => money(v),
            colorFor: (_) => Brand.green),
    ]);
  }

  Widget _chip(String label, String value, {bool bold = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
            color: bold ? const Color(0xFFEEF2FB) : Colors.white,
            border: Border.all(color: Brand.border),
            borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: Brand.muted, fontSize: 11)),
          Text(value, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w700)),
        ]),
      );

  /// Light grid lines between every row and column, like a spreadsheet.
  Widget _grid(Ledger g) {
    const line = BorderSide(color: Brand.border);
    TextStyle? muted(LedgerLine l) =>
        l.muted ? const TextStyle(color: Brand.muted, decoration: TextDecoration.lineThrough) : null;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        border: const TableBorder(
            top: line, bottom: line, left: line, right: line, horizontalInside: line, verticalInside: line),
        columnSpacing: 20,
        headingRowHeight: 38,
        headingRowColor: WidgetStatePropertyAll(const Color(0xFFEEF2FB)),
        dataRowMinHeight: 38,
        dataRowMaxHeight: 58,
        columns: [
          const DataColumn(label: Text('Date')),
          const DataColumn(label: Text('What')),
          DataColumn(label: Text(g.chargeLabel == 'Sales' ? 'Sales' : 'Bought'), numeric: true),
          const DataColumn(label: Text('Paid'), numeric: true),
          const DataColumn(label: Text('Balance'), numeric: true),
        ],
        rows: [
          DataRow(cells: [
            const DataCell(Text('')),
            const DataCell(Text('Opening balance', style: TextStyle(fontWeight: FontWeight.w700))),
            const DataCell(Text('')),
            const DataCell(Text('')),
            DataCell(Text(money(g.opening), style: const TextStyle(fontWeight: FontWeight.w700))),
          ]),
          for (final l in g.lines)
            DataRow(cells: [
              DataCell(Text(l.date)),
              DataCell(ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: Text('${l.what}${l.tag.isEmpty ? '' : '\n${l.tag}'}', style: muted(l)))),
              DataCell(Text(!l.muted && l.charge > 0 ? money(l.charge) : '')),
              DataCell(Text(l.paid > 0 ? money(l.paid) : '')),
              DataCell(Text(money(l.balance), style: const TextStyle(fontWeight: FontWeight.w700))),
            ]),
          DataRow(color: WidgetStatePropertyAll(const Color(0xFFEEF2FB)), cells: [
            const DataCell(Text('')),
            const DataCell(Text('Closing balance', style: TextStyle(fontWeight: FontWeight.w800))),
            DataCell(Text(money(g.totalCharges), style: const TextStyle(fontWeight: FontWeight.w800))),
            DataCell(Text(money(g.totalPaid), style: const TextStyle(fontWeight: FontWeight.w800))),
            DataCell(Text(money(g.closing), style: const TextStyle(fontWeight: FontWeight.w800))),
          ]),
        ],
      ),
    );
  }
}
