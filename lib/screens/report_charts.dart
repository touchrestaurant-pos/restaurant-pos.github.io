import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

const chartColors = [
  Color(0xFF1A2F6C),
  Color(0xFFE8A900),
  Color(0xFF2C7BE5),
  Color(0xFF1E7A4A),
  Color(0xFFC8283A),
  Color(0xFF8E5BD6),
  Color(0xFF17A2B8),
  Color(0xFF8A94A8),
];

class ChartPoint {
  const ChartPoint(this.label, this.value, {this.detail = ''});
  final String label;
  final double value;

  /// Shown under the chart when this point is tapped.
  final String detail;
}

Widget _chartCard(String title, Widget child, {String? note, Widget? action}) => Card(
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
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );

Widget _selected(String? text, {String hint = 'Tap a bar for details.'}) => Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
          color: const Color(0xFFF3F5FA), borderRadius: BorderRadius.circular(8)),
      child: Text(text ?? hint,
          style: TextStyle(
              color: text == null ? Brand.muted : Brand.navy,
              fontSize: 13,
              fontWeight: text == null ? FontWeight.w400 : FontWeight.w600)),
    );

String _short(double v) {
  final a = v.abs();
  if (a >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
  if (a >= 1000) return '${(v / 1000).toStringAsFixed(a >= 10000 ? 0 : 1)}k';
  return v.toStringAsFixed(0);
}

/// Gives a chart enough room for its points: when there are too many to fit, the chart becomes
/// wider than the card and scrolls sideways (with a scrollbar) so nothing is squashed or cut off.
/// [build] gets the width each point has and how many labels to skip so they never overlap.
Widget _fitChart(List<ChartPoint> pts, double minPerPoint, Widget Function(int labelStep) build) =>
    LayoutBuilder(builder: (context, box) {
      final avail = box.maxWidth.isFinite ? box.maxWidth : 600.0;
      final need = 60 + pts.length * minPerPoint;
      final width = need > avail ? need : avail;
      final per = (width - 60) / pts.length;
      final longest = pts.fold<int>(0, (m, p) => p.label.length > m ? p.label.length : m);
      final labelW = longest * 6.2 + 14;
      final step = (labelW / per).ceil().clamp(1, pts.length);
      final chart = SizedBox(width: width, height: 220, child: build(step));
      if (width <= avail + 0.5) return chart;
      final ctl = ScrollController();
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Scrollbar(
          controller: ctl,
          thumbVisibility: true,
          child: SingleChildScrollView(
              controller: ctl,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(bottom: 12),
              child: chart),
        ),
        const Text('Drag sideways to see the rest.', style: TextStyle(color: Brand.muted, fontSize: 11)),
      ]);
    });

/// Vertical bars. Hover or tap for the value, tap to pin the details underneath.
class BarCard extends StatefulWidget {
  const BarCard({
    super.key,
    required this.title,
    required this.points,
    required this.format,
    this.note,
    this.color = Brand.navy,
  });
  final String title;
  final List<ChartPoint> points;
  final String Function(double) format;
  final String? note;
  final Color color;

  @override
  State<BarCard> createState() => _BarCardState();
}

class _BarCardState extends State<BarCard> {
  int? _sel;

  @override
  Widget build(BuildContext context) {
    final pts = widget.points;
    if (pts.isEmpty) {
      return _chartCard(widget.title, const Text('Nothing to chart for this period.', style: TextStyle(color: Brand.muted)),
          note: widget.note);
    }
    final maxV = pts.map((p) => p.value).reduce((a, b) => a > b ? a : b);
    final minV = pts.map((p) => p.value).reduce((a, b) => a < b ? a : b);
    final sel = _sel != null && _sel! < pts.length ? pts[_sel!] : null;
    return _chartCard(
      widget.title,
      Column(children: [
        _fitChart(
          pts,
          26,
          (step) => BarChart(BarChartData(
            minY: minV < 0 ? minV * 1.15 : 0,
            maxY: maxV <= 0 ? 1 : maxV * 1.15,
            gridData: FlGridData(
                drawVerticalLine: false,
                getDrawingHorizontalLine: (_) => const FlLine(color: Color(0xFFE3E8F2), strokeWidth: 1)),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 44,
                      getTitlesWidget: (v, meta) => Text(_short(v),
                          style: const TextStyle(fontSize: 11, color: Brand.muted)))),
              bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      getTitlesWidget: (v, meta) {
                        final i = v.toInt();
                        if (i < 0 || i >= pts.length || i % step != 0) return const SizedBox();
                        return Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(pts[i].label,
                                style: const TextStyle(fontSize: 11, color: Brand.muted)));
                      })),
            ),
            barTouchData: BarTouchData(
              touchCallback: (event, resp) {
                final i = resp?.spot?.touchedBarGroupIndex;
                if (event.isInterestedForInteractions && i != null && event is FlTapUpEvent) {
                  setState(() => _sel = i);
                }
              },
              touchTooltipData: BarTouchTooltipData(
                getTooltipColor: (_) => Brand.navy,
                getTooltipItem: (group, gi, rod, ri) => BarTooltipItem(
                    '${pts[group.x].label}\n${widget.format(rod.toY)}',
                    const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)),
              ),
            ),
            barGroups: [
              for (var i = 0; i < pts.length; i++)
                BarChartGroupData(x: i, barRods: [
                  BarChartRodData(
                    toY: pts[i].value,
                    width: pts.length > 20 ? 12 : 18,
                    color: _sel == i ? Brand.gold : widget.color,
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
                  )
                ]),
            ],
          )),
        ),
        _selected(sel == null
            ? null
            : '${sel.label}: ${widget.format(sel.value)}${sel.detail.isEmpty ? '' : ' · ${sel.detail}'}'),
      ]),
      note: widget.note,
    );
  }
}

/// Line with area under it, for trends over days.
class LineCard extends StatefulWidget {
  const LineCard({
    super.key,
    required this.title,
    required this.points,
    required this.format,
    this.note,
  });
  final String title;
  final List<ChartPoint> points;
  final String Function(double) format;
  final String? note;

  @override
  State<LineCard> createState() => _LineCardState();
}

class _LineCardState extends State<LineCard> {
  int? _sel;

  @override
  Widget build(BuildContext context) {
    final pts = widget.points;
    if (pts.length < 2) {
      return _chartCard(
          widget.title,
          Text(pts.isEmpty ? 'Nothing to chart for this period.' : 'Choose a longer period to see a trend.',
              style: const TextStyle(color: Brand.muted)),
          note: widget.note);
    }
    final maxV = pts.map((p) => p.value).reduce((a, b) => a > b ? a : b);
    final minV = pts.map((p) => p.value).reduce((a, b) => a < b ? a : b);
    final sel = _sel != null && _sel! < pts.length ? pts[_sel!] : null;
    return _chartCard(
      widget.title,
      Column(children: [
        _fitChart(
          pts,
          34,
          (step) => LineChart(LineChartData(
            minY: minV < 0 ? minV * 1.15 : 0, // amounts below zero (in credit) are drawn, not cut off
            maxY: maxV <= 0 ? 1 : maxV * 1.15,
            clipData: const FlClipData.all(),
            gridData: FlGridData(
                drawVerticalLine: false,
                getDrawingHorizontalLine: (_) => const FlLine(color: Color(0xFFE3E8F2), strokeWidth: 1)),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 44,
                      getTitlesWidget: (v, meta) => Text(_short(v),
                          style: const TextStyle(fontSize: 11, color: Brand.muted)))),
              bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      interval: 1,
                      getTitlesWidget: (v, meta) {
                        final i = v.toInt();
                        if (v != i.toDouble() || i < 0 || i >= pts.length || i % step != 0) {
                          return const SizedBox();
                        }
                        return Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(pts[i].label,
                                style: const TextStyle(fontSize: 11, color: Brand.muted)));
                      })),
            ),
            lineTouchData: LineTouchData(
              touchCallback: (event, resp) {
                final spots = resp?.lineBarSpots;
                if (event is FlTapUpEvent && spots != null && spots.isNotEmpty) {
                  setState(() => _sel = spots.first.spotIndex);
                }
              },
              touchTooltipData: LineTouchTooltipData(
                getTooltipColor: (_) => Brand.navy,
                getTooltipItems: (spots) => [
                  for (final s in spots)
                    LineTooltipItem('${pts[s.spotIndex].label}\n${widget.format(s.y)}',
                        const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12))
                ],
              ),
            ),
            lineBarsData: [
              LineChartBarData(
                spots: [for (var i = 0; i < pts.length; i++) FlSpot(i.toDouble(), pts[i].value)],
                isCurved: true,
                curveSmoothness: 0.2,
                preventCurveOverShooting: true, // the line never dips below or above the real values
                color: Brand.navy,
                barWidth: 3,
                dotData: FlDotData(
                    show: true,
                    getDotPainter: (spot, _, __, i) => FlDotCirclePainter(
                        radius: _sel == i ? 6 : 3.5,
                        color: _sel == i ? Brand.gold : Brand.navy,
                        strokeWidth: 2,
                        strokeColor: Colors.white)),
                belowBarData: BarAreaData(show: true, color: Brand.navy.withOpacity(0.08)),
              ),
            ],
          )),
        ),
        _selected(
            sel == null
                ? null
                : '${sel.label}: ${widget.format(sel.value)}${sel.detail.isEmpty ? '' : ' · ${sel.detail}'}',
            hint: 'Tap a point for details.'),
      ]),
      note: widget.note,
    );
  }
}

/// Donut with a legend. Tap a slice or a legend row to pull it out.
class PieCard extends StatefulWidget {
  const PieCard({
    super.key,
    required this.title,
    required this.slices,
    required this.format,
    this.note,
  });
  final String title;
  final List<ChartPoint> slices;
  final String Function(double) format;
  final String? note;

  @override
  State<PieCard> createState() => _PieCardState();
}

class _PieCardState extends State<PieCard> {
  int? _sel;

  @override
  Widget build(BuildContext context) {
    final data = widget.slices.where((s) => s.value > 0).toList();
    if (data.isEmpty) {
      return _chartCard(widget.title, const Text('Nothing to chart for this period.', style: TextStyle(color: Brand.muted)),
          note: widget.note);
    }
    final total = data.fold<double>(0, (s, p) => s + p.value);
    final sel = _sel != null && _sel! < data.length ? data[_sel!] : null;
    final chart = SizedBox(
      height: 200,
      width: 200,
      child: Stack(alignment: Alignment.center, children: [
        PieChart(PieChartData(
          sectionsSpace: 2,
          centerSpaceRadius: 54,
          pieTouchData: PieTouchData(touchCallback: (event, resp) {
            final i = resp?.touchedSection?.touchedSectionIndex;
            if (event is FlTapUpEvent && i != null && i >= 0) {
              setState(() => _sel = _sel == i ? null : i);
            }
          }),
          sections: [
            for (var i = 0; i < data.length; i++)
              PieChartSectionData(
                value: data[i].value,
                color: chartColors[i % chartColors.length],
                radius: _sel == i ? 46 : 38,
                showTitle: false,
              ),
          ],
        )),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 30),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(sel == null ? 'Total' : sel.label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Brand.muted)),
            Text(widget.format(sel?.value ?? total),
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Brand.navy)),
            if (sel != null)
              Text('${(sel.value / total * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(fontSize: 11, color: Brand.muted)),
          ]),
        ),
      ]),
    );
    final legend = Column(children: [
      for (var i = 0; i < data.length; i++)
        InkWell(
          onTap: () => setState(() => _sel = _sel == i ? null : i),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
            decoration: BoxDecoration(
                color: _sel == i ? const Color(0xFFF3F5FA) : null,
                borderRadius: BorderRadius.circular(6)),
            child: Row(children: [
              Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                      color: chartColors[i % chartColors.length],
                      borderRadius: BorderRadius.circular(3))),
              const SizedBox(width: 8),
              Expanded(child: Text(data[i].label, overflow: TextOverflow.ellipsis)),
              Text(widget.format(data[i].value),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              SizedBox(
                  width: 52,
                  child: Text('${(data[i].value / total * 100).toStringAsFixed(1)}%',
                      textAlign: TextAlign.right,
                      style: const TextStyle(color: Brand.muted, fontSize: 12))),
            ]),
          ),
        ),
    ]);
    return _chartCard(
      widget.title,
      LayoutBuilder(builder: (context, box) {
        if (box.maxWidth > 560) {
          return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            chart,
            const SizedBox(width: 24),
            Expanded(child: legend),
          ]);
        }
        return Column(children: [chart, const SizedBox(height: 12), legend]);
      }),
      note: widget.note,
    );
  }
}

/// Horizontal ranked bars with an optional switch of what is measured. Tap a row for details.
class RankedBars extends StatefulWidget {
  const RankedBars({
    super.key,
    required this.title,
    required this.points,
    required this.format,
    this.note,
    this.action,
    this.colorFor,
  });
  final String title;
  final List<ChartPoint> points;
  final String Function(double) format;
  final String? note;
  final Widget? action;
  final Color Function(ChartPoint)? colorFor;

  @override
  State<RankedBars> createState() => _RankedBarsState();
}

class _RankedBarsState extends State<RankedBars> {
  String? _sel;

  @override
  Widget build(BuildContext context) {
    final pts = widget.points;
    if (pts.isEmpty) {
      return _chartCard(widget.title, const Text('Nothing to chart for this period.', style: TextStyle(color: Brand.muted)),
          note: widget.note, action: widget.action);
    }
    final maxV = pts.map((p) => p.value.abs()).reduce((a, b) => a > b ? a : b);
    ChartPoint? sel;
    for (final p in pts) {
      if (p.label == _sel) sel = p;
    }
    return _chartCard(
      widget.title,
      Column(children: [
        for (final p in pts)
          InkWell(
            onTap: () => setState(() => _sel = _sel == p.label ? null : p.label),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                SizedBox(
                    width: 130,
                    child: Text(p.label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: _sel == p.label ? FontWeight.w800 : FontWeight.w500))),
                Expanded(
                  child: LayoutBuilder(builder: (context, box) {
                    final w = maxV <= 0 ? 0.0 : box.maxWidth * (p.value.abs() / maxV);
                    return Stack(children: [
                      Container(
                          height: 22,
                          decoration: BoxDecoration(
                              color: const Color(0xFFF0F3FA), borderRadius: BorderRadius.circular(6))),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        height: 22,
                        width: w < 3 && p.value != 0 ? 3 : w,
                        decoration: BoxDecoration(
                            color: _sel == p.label
                                ? Brand.gold
                                : (widget.colorFor?.call(p) ?? Brand.navy),
                            borderRadius: BorderRadius.circular(6)),
                      ),
                    ]);
                  }),
                ),
                SizedBox(
                    width: 92,
                    child: Text(widget.format(p.value),
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
              ]),
            ),
          ),
        _selected(sel == null ? null : '${sel.label}: ${widget.format(sel.value)}${sel.detail.isEmpty ? '' : ' · ${sel.detail}'}'),
      ]),
      note: widget.note,
      action: widget.action,
    );
  }
}

// ---- Graph style chosen by the admin (Settings, saved in company_settings.chart_style) ----

/// 'auto' keeps each chart's own style. The others redraw every chart in the chosen style.
final ValueNotifier<String> chartStyle = ValueNotifier<String>('auto');

const chartStyleNames = {
  'auto': 'Automatic',
  'bars': 'Bars',
  'line': 'Line',
  'pie': 'Pie',
  'ranked': 'Ranked list',
};

/// Drop-in for BarCard that follows the chosen graph style.
class AdaptiveBars extends StatelessWidget {
  const AdaptiveBars({super.key, required this.title, required this.points, required this.format, this.note, this.color = Brand.navy});
  final String title;
  final List<ChartPoint> points;
  final String Function(double) format;
  final String? note;
  final Color color;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
        valueListenable: chartStyle,
        builder: (_, s, __) => _styled(s, 'bars', title, points, format, note, color: color),
      );
}

/// Drop-in for LineCard.
class AdaptiveLine extends StatelessWidget {
  const AdaptiveLine({super.key, required this.title, required this.points, required this.format, this.note});
  final String title;
  final List<ChartPoint> points;
  final String Function(double) format;
  final String? note;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
        valueListenable: chartStyle,
        builder: (_, s, __) => _styled(s, 'line', title, points, format, note),
      );
}

/// Drop-in for PieCard (give the slices as points).
class AdaptivePie extends StatelessWidget {
  const AdaptivePie({super.key, required this.title, required this.slices, required this.format, this.note});
  final String title;
  final List<ChartPoint> slices;
  final String Function(double) format;
  final String? note;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
        valueListenable: chartStyle,
        builder: (_, s, __) => _styled(s, 'pie', title, slices, format, note),
      );
}

/// Drop-in for RankedBars.
class AdaptiveRanked extends StatelessWidget {
  const AdaptiveRanked({super.key, required this.title, required this.points, required this.format, this.note, this.action, this.colorFor});
  final String title;
  final List<ChartPoint> points;
  final String Function(double) format;
  final String? note;
  final Widget? action;
  final Color Function(ChartPoint)? colorFor;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
        valueListenable: chartStyle,
        builder: (_, s, __) => _styled(s, 'ranked', title, points, format, note, action: action, colorFor: colorFor),
      );
}

Widget _styled(String style, String own, String title, List<ChartPoint> points, String Function(double) format, String? note,
    {Color color = Brand.navy, Widget? action, Color Function(ChartPoint)? colorFor}) {
  final use = (style == 'auto' || !chartStyleNames.containsKey(style)) ? own : style;
  // A pie cannot show negative values, so those keep their own style.
  final negative = points.any((p) => p.value < 0);
  switch (negative && use == 'pie' ? own == 'pie' ? 'bars' : own : use) {
    case 'line':
      return LineCard(title: title, points: points, format: format, note: note);
    case 'pie':
      return PieCard(title: title, slices: points, format: format, note: note);
    case 'ranked':
      return RankedBars(title: title, points: points, format: format, note: note, action: action, colorFor: colorFor);
    default:
      return BarCard(title: title, points: points, format: format, note: note, color: color);
  }
}
