import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../data/repo.dart';
import 'ledger.dart';

String _co(String k) => '${companyRow()?[k == 'name' ? ((companyRow()?['trading_name'] ?? '') == '' ? 'company_name' : 'trading_name') : k] ?? ''}'.trim();

pw.Widget _head(String title) {
  final lines = <String>[
    if (_co('name').isNotEmpty) _co('name'),
    if (_co('address').isNotEmpty) _co('address'),
    [if (_co('phone').isNotEmpty) 'Tel ${_co('phone')}', if (_co('vat_number').isNotEmpty) 'VAT no ${_co('vat_number')}']
        .join('  ·  '),
  ].where((e) => e.isNotEmpty).toList();
  return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
    pw.Text(title, style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
    pw.SizedBox(height: 4),
    for (final l in lines) pw.Text(l, style: const pw.TextStyle(fontSize: 9)),
    pw.Divider(),
  ]);
}

String _d(dynamic v) => '${v ?? ''}'.split('T').first;

/// Statement of account for one customer (same layout as a supplier statement).
Future<Uint8List> statementPdf(Map<String, dynamic> st) => ledgerPdf(ledgerFromAccountStatement(st));

/// Receipt for money received on an account.
Future<Uint8List> accountReceiptPdf(Map<String, dynamic> r, {String? reference}) async {
  final doc = pw.Document();
  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.a5,
    margin: const pw.EdgeInsets.all(28),
    build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      _head('Receipt for account payment'),
      pw.Text('Receipt no: ARC${'${r['receipt_no']}'.padLeft(5, '0')}'),
      pw.Text('Date: ${_d(r['date'])}'),
      pw.SizedBox(height: 8),
      pw.Text('Received from: ${r['name']} (${r['account_no']})'),
      pw.Text('Paid by: ${{'cash': 'Cash', 'card': 'Card', 'eft': 'EFT'}[r['method']] ?? r['method']}'),
      if ((reference ?? '').isNotEmpty) pw.Text('Reference: $reference'),
      pw.SizedBox(height: 10),
      pw.Text('Amount received: ${money(n(r['amount']))}', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 4),
      pw.Text('Balance now owing on the account: ${money(n(r['balance']))}'),
      pw.SizedBox(height: 14),
      pw.Text('Thank you.', style: const pw.TextStyle(fontSize: 9)),
    ]),
  ));
  return doc.save();
}

/// Blank account application with terms and consent. A starting point only:
/// the wording must be reviewed by the business's own attorney before use.
Future<Uint8List> applicationFormPdf({int termsDays = 30}) async {
  final co = _co('name').isEmpty ? 'the Business' : _co('name');
  pw.Widget field(String label) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 9),
        child: pw.Row(children: [
          pw.SizedBox(width: 150, child: pw.Text(label, style: const pw.TextStyle(fontSize: 10))),
          pw.Expanded(child: pw.Container(height: 14, decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(width: 0.5))))),
        ]),
      );
  pw.Widget p(String t) => pw.Padding(padding: const pw.EdgeInsets.only(bottom: 5), child: pw.Text(t, style: const pw.TextStyle(fontSize: 8.5)));
  final doc = pw.Document();
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    build: (_) => [
      _head('Customer account application'),
      field('Business / customer name'),
      field('Registration or ID number'),
      field('VAT number (if any)'),
      field('Contact person'),
      field('Phone'),
      field('Email'),
      field('Billing address'),
      field('Credit limit requested (R)'),
      pw.SizedBox(height: 6),
      pw.Text('Account terms', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
      p('1. $co may give the customer a credit account up to the limit it sets. The limit and the terms may be changed, or the account blocked or stopped, at any time.'),
      p('2. The customer pays each invoice within $termsDays days of the invoice date. No interest or fees are added to the account.'),
      p('3. A statement is sent to the customer. Any query must be raised within 7 days of the statement.'),
      p('4. Everyone the customer authorises to buy on the account binds the customer for those purchases.'),
      p('5. If an amount is not paid, $co may stop the account and take the steps the law allows to recover it.'),
      pw.SizedBox(height: 4),
      pw.Text('Use of personal information (POPIA)', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
      p('$co will keep the details on this form, and the purchases and payments on the account, to run and collect the account and to meet tax and accounting law. '
          'They are kept for at least 5 years, are not sold, and are shared only where the law requires it or with those who help run the account. '
          'The customer may ask to see or correct their details, or object to their use, by contacting $co.'),
      pw.SizedBox(height: 6),
      pw.Text('I confirm the details above are correct, I accept the account terms, and I agree to $co keeping and using my information as set out above.',
          style: const pw.TextStyle(fontSize: 9)),
      pw.SizedBox(height: 14),
      field('Name'),
      field('Signature'),
      field('Date'),
      pw.SizedBox(height: 8),
      pw.Text('Draft wording: have your attorney review this form before you use it.',
          style: pw.TextStyle(fontSize: 7, color: PdfColors.grey700, fontStyle: pw.FontStyle.italic)),
    ],
  ));
  return doc.save();
}

Future<void> openPdf(Uint8List bytes, String name) => Printing.layoutPdf(name: name, onLayout: (_) async => bytes);
