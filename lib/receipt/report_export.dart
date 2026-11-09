import 'dart:convert';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../data/repo.dart';

class ReportTable {
  ReportTable(this.title, this.headers, this.rows);
  final String title;
  final List<String> headers;
  final List<List<String>> rows;
}

const reportTabNames = [
  'Sales',
  'Products',
  'Staff',
  'Buying list',
  'Stock usage',
  'Stock value and purchases',
  'Cancelled orders and refunds',
];

List<Map<String, dynamic>> _l(Map<String, dynamic>? d, String k) =>
    ((d?[k] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

/// The tables of one report tab. [pretty] gives "R1,234.50" for the PDF and plain numbers for Excel.
List<ReportTable> reportTables(int tab, Map<String, dynamic> d, Map<String, dynamic>? refunds,
    {required bool pretty}) {
  String m(dynamic v) => pretty ? money(n(v)) : n(v).toStringAsFixed(2);
  String q(dynamic v) {
    final x = n(v);
    return x == x.roundToDouble() ? x.toInt().toString() : x.toStringAsFixed(2);
  }

  String pct(num part, num whole) =>
      whole == 0 ? '' : '${(part / whole * 100).toStringAsFixed(1)}%';
  String when(dynamic v) {
    final t = parseTime(v);
    if (t == null) return '';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  const types = {'eat_in': 'Eat in', 'take_away': 'Take away', 'delivery': 'Delivery'};
  String method(dynamic x) => x == 'cash' ? 'Cash' : 'Card';

  // Tab 2 is the staff report; the ones after it keep their old numbers below.
  if (tab == 2) {
    return [
      ReportTable('Sales by staff member', ['Staff member', 'Paid orders', 'Sales', 'Average order', 'Discounts given', 'Orders cancelled'], [
        for (final r in _l(d, 'by_staff'))
          ['${r['name']}', q(r['orders']), m(r['total']), m(r['avg']), m(r['discounts']), q(r['cancelled'])]
      ]),
    ];
  }
  if (tab > 2) tab -= 1;
  switch (tab) {
    case 0:
      final s = Map<String, dynamic>.from((d['summary'] as Map?) ?? const {});
      final u = Map<String, dynamic>.from((d['unpaid'] as Map?) ?? const {});
      final v = Map<String, dynamic>.from((d['voided'] as Map?) ?? const {});
      return [
        ReportTable('Summary (paid orders)', ['Measure', 'Value'], [
          ['Sales including VAT', m(s['gross'])],
          ['Sales excluding VAT', m(s['net'])],
          ['Discounts given', m(s['discounts'])],
          ['Refunds given', m(s['refunds'])],
          ['Sales after refunds', m(s['after_refunds'])],
          ['Tips (not sales)', m(s['tips'])],
          ['VAT collected', m(s['vat'])],
          ['Paid orders', q(s['orders'])],
          ['Average order', m(s['avg_order'])],
          ['Unpaid orders', '${q(u['orders'])} (${m(u['total'])})'],
          ['Cancelled orders', '${q(v['orders'])} (${m(v['total'])})'],
        ]),
        ReportTable('VAT by type', ['VAT type', 'Sales incl. VAT', 'Excl. VAT', 'VAT'], [
          for (final v in _l(d, 'vat_breakdown'))
            [vatTypeNames[v['vat_type']] ?? '${v['vat_type']}', m(v['sales']), m(v['excl']), m(v['vat'])]
        ]),
        ReportTable('Payments received', ['Method', 'Payments', 'Amount'],
            [for (final p in _l(d, 'payments')) [method(p['method']), q(p['count']), m(p['amount'])]]),
        ReportTable('Sales by day', ['Date', 'Orders', 'Sales'],
            [for (final r in _l(d, 'by_day')) ['${r['day']}', q(r['orders']), m(r['total'])]]),
        ReportTable('Sales by order type', ['Type', 'Orders', 'Sales'],
            [for (final r in _l(d, 'by_type')) [types[r['type']] ?? '${r['type']}', q(r['orders']), m(r['total'])]]),
        ReportTable('Sales by hour', ['Hour', 'Orders', 'Sales'], [
          for (final r in _l(d, 'by_hour'))
            ['${n(r['hour']).toInt().toString().padLeft(2, '0')}:00', q(r['orders']), m(r['total'])]
        ]),
      ];
    case 1:
      return [
        ReportTable(
          'Product sales and profit',
          ['Product', 'Category', 'Sold', 'Sales incl. VAT', 'Sales excl. VAT', 'Ingredient cost', 'Profit', 'Margin'],
          [
            for (final p in _l(d, 'products'))
              [
                '${p['name']}',
                '${p['category']}',
                q(p['qty']),
                m(p['revenue']),
                m(p['net']),
                m(p['cost']),
                m(n(p['net']) - n(p['cost'])),
                pct(n(p['net']) - n(p['cost']), n(p['net'])),
              ]
          ],
        ),
        ReportTable('By category', ['Category', 'Sold', 'Sales incl. VAT', 'Ingredient cost', 'Margin'], [
          for (final c in _l(d, 'categories'))
            ['${c['category']}', q(c['qty']), m(c['revenue']), m(c['cost']), pct(n(c['net']) - n(c['cost']), n(c['net']))]
        ]),
      ];
    case 2:
      return [
        ReportTable(
          'Buying list (items at or below minimum level)',
          ['Supplier', 'Item', 'Unit', 'On hand', 'Minimum', 'Days left', 'Suggested order', 'Est. cost excl. VAT'],
          [
            for (final r in _l(d, 'reorder'))
              [
                '${r['supplier']}',
                '${r['item']}',
                '${r['unit']}',
                q(r['on_hand']),
                q(r['min_level']),
                r['days_left'] == null ? '' : '${r['days_left']}',
                q(r['suggested']),
                m(r['est_cost']),
              ]
          ],
        ),
      ];
    case 3:
      return [
        ReportTable('Stock movement by item', ['Item', 'Unit', 'Used in sales', 'Received', 'Waste', 'Adjusted', 'Cost of use'], [
          for (final r in _l(d, 'usage'))
            ['${r['item']}', '${r['unit']}', q(r['sold']), q(r['received']), q(r['waste']), q(r['adjusted']), m(r['cost_used'])]
        ]),
      ];
    case 4:
      return [
        ReportTable('Stock value by category', ['Category', 'Items', 'Value (avg cost, excl. VAT)'],
            [for (final v in _l(d, 'valuation')) ['${v['category']}', q(v['items']), m(v['value'])]]),
        ReportTable('Purchases by supplier (posted deliveries)', ['Supplier', 'Deliveries', 'Excl. VAT', 'VAT', 'Total'], [
          for (final p in _l(d, 'purchases'))
            ['${p['supplier']}', q(p['grvs']), m(p['subtotal']), m(p['vat']), m(p['total'])]
        ]),
      ];
    default:
      final rf = _l(refunds, 'items');
      return [
        ReportTable('Cancelled orders', ['Order', 'When', 'Amount', 'Was paid', 'Reason'], [
          for (final v in _l(d, 'voids'))
            ['#${v['ref']}', when(v['at']), m(v['total']), v['paid'] == true ? 'Yes' : 'No', '${v['reason'] ?? ''}']
        ]),
        ReportTable('Refunds given', ['Order', 'When', 'Amount', 'Method', 'Reason'], [
          for (final r in rf)
            ['#${r['ref']}', when(r['at']), m(r['amount']), r['method'] == 'cash' ? 'Cash' : 'Card', '${r['reason'] ?? ''}']
        ]),
      ];
  }
}

String _csvCell(String v) => '"${v.replaceAll('"', '""')}"';

/// Opens in Excel. Starts with a byte order mark so Rand signs and accents show correctly.
Uint8List reportCsv(int tab, String period, Map<String, dynamic> d, Map<String, dynamic>? refunds) {
  final b = StringBuffer('﻿');
  b.writeln(_csvCell('${reportTabNames[tab]} report, $period'));
  b.writeln();
  for (final t in reportTables(tab, d, refunds, pretty: false)) {
    b.writeln(_csvCell(t.title));
    b.writeln(t.headers.map(_csvCell).join(','));
    for (final r in t.rows) {
      b.writeln(r.map(_csvCell).join(','));
    }
    b.writeln();
  }
  return Uint8List.fromList(utf8.encode(b.toString()));
}

/// Every tab in one printable PDF.
Future<Uint8List> reportPdf(String company, String period, Map<String, dynamic> d, Map<String, dynamic>? refunds) async {
  final doc = pw.Document(title: 'Reports $period', author: company);
  final head = pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold);
  final cell = const pw.TextStyle(fontSize: 8.5);
  final widgets = <pw.Widget>[];
  for (var tab = 0; tab < reportTabNames.length; tab++) {
    widgets.add(pw.Header(level: 0, text: reportTabNames[tab], textStyle: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold)));
    for (final t in reportTables(tab, d, refunds, pretty: true)) {
      widgets.add(pw.Padding(
          padding: const pw.EdgeInsets.only(top: 6, bottom: 3),
          child: pw.Text(t.title, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold))));
      if (t.rows.isEmpty) {
        widgets.add(pw.Text('Nothing for this period.', style: cell));
      } else {
        widgets.add(pw.TableHelper.fromTextArray(
          headers: t.headers,
          data: t.rows,
          headerStyle: head,
          cellStyle: cell,
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
          cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.4),
        ));
      }
    }
  }
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4.landscape,
    margin: const pw.EdgeInsets.all(28),
    header: (c) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 8),
        child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text('$company - Management reports', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
          pw.Text(period, style: const pw.TextStyle(fontSize: 9)),
        ])),
    footer: (c) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('Page ${c.pageNumber} of ${c.pagesCount}', style: const pw.TextStyle(fontSize: 8))),
    build: (c) => widgets,
  ));
  return doc.save();
}
