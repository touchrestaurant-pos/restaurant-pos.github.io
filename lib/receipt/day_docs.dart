import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../data/repo.dart';

const _kindNames = {
  'drop': 'Cash drop (safe / bank)',
  'payout': 'Pay-out',
  'tip_payout': 'Tips paid to staff',
  'float_in': 'Cash added to drawer',
};

List<Map<String, dynamic>> _l(dynamic v) =>
    ((v as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

String _m(dynamic v) => money(n(v));

String _time(dynamic v) {
  final t = parseTime(v);
  if (t == null) return '';
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// One day on paper: sales, VAT, payments, money out of the tills, and the cash-up counts.
/// Every figure comes from the server's `daily_summary`, nothing is worked out here.
Future<Uint8List> dailySummaryPdf(Map<String, dynamic> d, {String company = ''}) async {
  final s = Map<String, dynamic>.from((d['summary'] as Map?) ?? const {});
  final cash = Map<String, dynamic>.from((d['cash'] as Map?) ?? const {});
  final unpaid = Map<String, dynamic>.from((d['unpaid'] as Map?) ?? const {});
  final voided = Map<String, dynamic>.from((d['voided'] as Map?) ?? const {});
  final moves = _l(cash['movements']);
  final cashUps = _l(d['cash_ups']);
  const methodNames = {'cash': 'Cash', 'card_manual': 'Card', 'account': 'On account'};
  const vatNames = {'standard': 'Standard rated', 'zero': 'Zero rated', 'exempt': 'Exempt'};

  pw.Widget title(String t) => pw.Padding(
      padding: const pw.EdgeInsets.only(top: 12, bottom: 4),
      child: pw.Text(t, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)));

  pw.Widget kv(List<List<String>> rows) => pw.TableHelper.fromTextArray(
        cellStyle: const pw.TextStyle(fontSize: 9),
        cellAlignments: {1: pw.Alignment.centerRight},
        border: pw.TableBorder(horizontalInside: pw.BorderSide(width: 0.3, color: PdfColors.grey500)),
        headerCount: 0,
        data: rows,
      );

  pw.Widget table(List<String> head, List<List<String>> rows, {Set<int> right = const {}}) => pw.TableHelper.fromTextArray(
        headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
        cellStyle: const pw.TextStyle(fontSize: 9),
        headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
        cellAlignments: {for (final i in right) i: pw.Alignment.centerRight},
        headers: head,
        data: rows,
      );

  final doc = pw.Document();
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    footer: (c) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('Page ${c.pageNumber} of ${c.pagesCount}', style: const pw.TextStyle(fontSize: 8))),
    build: (_) => [
      pw.Text(company.isEmpty ? 'Daily summary' : company, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
      pw.Text('Daily summary and cash-up report · ${d['date']}${d['closed'] == true ? ' · day closed' : ' · day still open'}',
          style: const pw.TextStyle(fontSize: 10)),
      pw.Divider(),
      title('Sales'),
      kv([
        ['Paid orders', '${s['orders'] ?? 0}'],
        ['Sales incl. VAT', _m(s['gross'])],
        ['Discounts given', _m(s['discounts'])],
        ['Refunds', _m(s['refunds'])],
        ['Sales after refunds', _m(s['after_refunds'])],
        ['VAT', _m(s['vat'])],
        ['Sales excl. VAT', _m(s['net'])],
        ['Tips (not part of sales)', _m(s['tips'])],
        ['Unpaid orders', '${unpaid['orders'] ?? 0} (${_m(unpaid['total'])})'],
        ['Cancelled orders', '${voided['orders'] ?? 0} (${_m(voided['total'])})'],
      ]),
      title('VAT by type'),
      table(['VAT type', 'Sales incl. VAT', 'Excl. VAT', 'VAT'], [
        for (final v in _l(d['vat']))
          [vatNames[v['vat_type']] ?? '${v['vat_type']}', _m(v['sales']), _m(v['excl']), _m(v['vat'])]
      ], right: {1, 2, 3}),
      title('Payments received'),
      table(['Method', 'Payments', 'Amount'], [
        for (final p in _l(d['payments'])) [methodName(methodNames, p['method']), '${p['count']}', _m(p['amount'])]
      ], right: {1, 2}),
      title('Cash in the drawer'),
      kv([
        ['Cash sales', _m(cash['cash_sales'])],
        ['Cash tips', _m(cash['cash_tips'])],
        ['Cash received on accounts', _m(cash['acct_cash'])],
        ['Cash added to the drawer', _m(cash['cash_in'])],
        ['Cash refunds', '-${_m(cash['cash_refunds'])}'],
        ['Account credit paid back in cash', '-${_m(cash['acct_cash_back'])}'],
        ['Money taken out of the till', '-${_m(cash['cash_out'])}'],
        ['Card payments (to match the machine)', _m(cash['card_sales'])],
        ['Sold on account today (not paid yet)', _m(cash['account_sales'])],
      ]),
      title('Money taken out of the till'),
      if (moves.where((m) => m['kind'] != 'float_in').isEmpty)
        pw.Text('Nothing was taken out.', style: const pw.TextStyle(fontSize: 9))
      else ...[
        table(['Time', 'What', 'Reference', 'Note', 'By', 'Amount'], [
          for (final m in moves.where((m) => m['kind'] != 'float_in'))
            [
              _time(m['at']),
              '${m['category'] ?? _kindNames[m['kind']] ?? m['kind']}',
              '${m['reference'] ?? ''}',
              '${m['note'] ?? ''}',
              '${m['by'] ?? ''}',
              _m(m['amount'])
            ]
        ], right: {5}),
        pw.SizedBox(height: 6),
        table(['Category', 'Total'], [
          for (final c in _l(cash['out_by_category'])) ['${c['category']}', _m(c['total'])]
        ], right: {1}),
      ],
      title('Cash-up'),
      if (cashUps.isEmpty)
        pw.Text('No cash-up has been saved for this day.', style: const pw.TextStyle(fontSize: 9))
      else
        table(['Till', 'Float', 'Expected', 'Counted', 'Over / short'], [
          for (final c in cashUps)
            ['${c['staff']}', _m(c['float']), _m(c['expected']), _m(c['counted']), _m(c['variance'])]
        ], right: {1, 2, 3, 4}),
      title('Sales by staff'),
      table(['Staff', 'Paid orders', 'Sales', 'Discounts', 'Cancelled'], [
        for (final r in _l(d['by_staff']))
          ['${r['name']}', '${r['orders']}', _m(r['total']), _m(r['discounts']), '${r['cancelled']}']
      ], right: {1, 2, 3, 4}),
      title('Customer accounts'),
      kv([
        ['Total owed by all accounts now', _m(d['account_owed'])],
      ]),
      pw.SizedBox(height: 20),
      pw.Row(children: [
        pw.Expanded(child: pw.Text('Prepared by: ______________________', style: const pw.TextStyle(fontSize: 9))),
        pw.Expanded(child: pw.Text('Checked by: ______________________', style: const pw.TextStyle(fontSize: 9))),
      ]),
    ],
  ));
  return doc.save();
}

String methodName(Map<String, String> names, dynamic m) => names['$m'] ?? '$m';
