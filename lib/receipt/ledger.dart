import 'dart:convert';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../data/repo.dart';

/// One row of an account statement. [charge] raises what is owed, [paid] lowers it.
class LedgerLine {
  const LedgerLine({
    required this.date,
    required this.what,
    this.charge = 0,
    this.paid = 0,
    this.balance = 0,
    this.group = '',
    this.muted = false,
    this.tag = '',
    this.party = '',
  });
  final String date;
  final String what;
  final double charge;
  final double paid;
  final double balance;

  /// What kind of payment this is, for the "how it was paid" chart.
  final String group;

  /// Shown greyed out and struck through (does not count).
  final bool muted;
  final String tag;

  /// Who it belongs to, on a combined statement of all customers or all suppliers.
  final String party;
}

/// A statement for one customer (debtor) or supplier (creditor). Both kinds are
/// shown, printed and exported by the same code, so they always look the same.
class Ledger {
  const Ledger({
    required this.partyName,
    required this.from,
    required this.to,
    required this.opening,
    required this.closing,
    required this.lines,
    this.partyInfo = const [],
    this.metaRight = const [],
    this.title = 'Statement of account',
    this.chargeLabel = 'Charges',
    this.paidLabel = 'Payments',
    this.owedWord = 'owing',
    this.ageing,
    this.footer = '',
  });
  final String partyName;
  final String from;
  final String to;
  final double opening;
  final double closing;
  final List<LedgerLine> lines;
  final List<String> partyInfo;
  final List<String> metaRight;
  final String title;
  final String chargeLabel;
  final String paidLabel;
  final String owedWord;

  /// current, d31, d61, d90
  final Map<String, double>? ageing;
  final String footer;

  double get totalCharges => lines.fold(0, (s, l) => s + (l.muted ? 0 : l.charge));
  double get totalPaid => lines.fold(0, (s, l) => s + l.paid);
}

/// Numbers worked out from a statement's lines, for the analysis view and the printout.
class LedgerStats {
  const LedgerStats({
    required this.chargeCount,
    required this.paymentCount,
    required this.avgCharge,
    required this.avgPayment,
    this.largestCharge,
    this.largestPayment,
    this.avgDaysToPay,
    this.oldestOpenDays,
    required this.paidShare,
    required this.perMonthCharge,
  });
  final int chargeCount;
  final int paymentCount;
  final double avgCharge;
  final double avgPayment;
  final LedgerLine? largestCharge;
  final LedgerLine? largestPayment;

  /// Average days between an item and the payment that settled it, oldest item paid first.
  final double? avgDaysToPay;

  /// Age in days of the oldest item still unpaid at the end of the period.
  final int? oldestOpenDays;

  /// Payments as a share of what was charged in the period (0 to 1+).
  final double paidShare;
  final double perMonthCharge;
}

LedgerStats analyseLedger(Ledger g) {
  final charges = g.lines.where((l) => !l.muted && l.charge > 0).toList();
  final pays = g.lines.where((l) => l.paid > 0).toList();
  LedgerLine? biggest(List<LedgerLine> xs, double Function(LedgerLine) f) {
    LedgerLine? best;
    for (final x in xs) {
      if (best == null || f(x) > f(best)) best = x;
    }
    return best;
  }

  // Pay the oldest items first and see how long each took.
  final open = <(DateTime, double)>[];
  final start = DateTime.tryParse(g.from);
  if (g.opening > 0.005 && start != null) open.add((start, g.opening));
  var weighted = 0.0, settled = 0.0;
  for (final l in g.lines) {
    final d = DateTime.tryParse(l.date);
    if (d == null) continue;
    if (!l.muted && l.charge > 0) open.add((d, l.charge));
    var left = l.paid;
    while (left > 0.005 && open.isNotEmpty) {
      final take = left < open.first.$2 ? left : open.first.$2;
      weighted += take * d.difference(open.first.$1).inDays;
      settled += take;
      left -= take;
      if (take >= open.first.$2 - 0.005) {
        open.removeAt(0);
      } else {
        open[0] = (open.first.$1, open.first.$2 - take);
      }
    }
  }
  final end = DateTime.tryParse(g.to);
  final today = DateTime.now();
  final asAt = end == null ? today : (end.isAfter(today) ? today : end);
  final months = start == null || end == null
      ? 1.0
      : ((end.difference(start).inDays + 1) / 30.4).clamp(1.0, 1000.0);
  return LedgerStats(
    chargeCount: charges.length,
    paymentCount: pays.length,
    avgCharge: charges.isEmpty ? 0 : g.totalCharges / charges.length,
    avgPayment: pays.isEmpty ? 0 : g.totalPaid / pays.length,
    largestCharge: biggest(charges, (l) => l.charge),
    largestPayment: biggest(pays, (l) => l.paid),
    avgDaysToPay: settled > 0.005 ? weighted / settled : null,
    oldestOpenDays: open.isEmpty ? null : asAt.difference(open.first.$1).inDays,
    paidShare: g.totalCharges > 0.005 ? g.totalPaid / g.totalCharges : 0,
    perMonthCharge: g.totalCharges / months,
  );
}

String _day(dynamic v) => '${v ?? ''}'.split('T').first;

/// Turns the server's customer statement into a [Ledger].
Ledger ledgerFromAccountStatement(Map<String, dynamic> st) {
  final a = Map<String, dynamic>.from(st['account'] as Map);
  const kinds = {
    'sale': 'Sale',
    'payment': 'Payment received',
    'credit_note': 'Credit note',
    'writeoff': 'Written off',
    'writeoff_reversal': 'Write-off reversed',
    'credit_refund': 'Credit paid back',
  };
  final raw = ((st['lines'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map));
  final lines = <LedgerLine>[];
  for (final l in raw) {
    final k = kinds[l['kind']] ?? '${l['kind']}';
    final ref = '${l['invoice_no'] ?? l['ref'] ?? ''}';
    final m = {'cash': 'cash', 'card': 'card', 'eft': 'EFT'}[l['method']];
    final what = [k, if (ref.isNotEmpty) ref, if (m != null) '($m)', if ('${l['reference'] ?? ''}'.isNotEmpty) '${l['reference']}'].join(' ');
    final amt = n(l['amount']).toDouble();
    lines.add(LedgerLine(
      date: _day(l['date']),
      what: what,
      charge: amt > 0 ? amt : 0,
      paid: amt < 0 ? -amt : 0,
      balance: n(l['running']).toDouble(),
      group: k,
    ));
  }
  final age = Map<String, dynamic>.from((st['ageing'] as Map?) ?? const {});
  return Ledger(
    partyName: '${a['name']}',
    from: _day(st['from']),
    to: _day(st['to']),
    opening: n(st['opening']).toDouble(),
    closing: n(st['closing']).toDouble(),
    lines: lines,
    partyInfo: [
      if ('${a['billing_address'] ?? ''}'.isNotEmpty) '${a['billing_address']}',
      if ('${a['vat_no'] ?? ''}'.isNotEmpty) 'Customer VAT no: ${a['vat_no']}',
    ],
    metaRight: ['Account ${a['account_no']}', 'Terms ${a['terms_days']} days'],
    title: 'Statement of account',
    chargeLabel: 'Sales',
    paidLabel: 'Payments and credits',
    ageing: {
      'current': n(age['current']).toDouble(),
      'd31': n(age['d31']).toDouble(),
      'd61': n(age['d61']).toDouble(),
      'd90': n(age['d90']).toDouble(),
    },
    footer: 'No interest or fees are charged on this account. Please pay within ${a['terms_days']} days of each invoice. '
        'Tell us within 7 days if anything on this statement looks wrong. Statement date ${_day(st['as_at'])}.',
  );
}

String _co(String k) {
  final c = companyRow() ?? const {};
  if (k == 'name') {
    final t = '${c['trading_name'] ?? ''}'.trim();
    return t.isNotEmpty ? t : '${c['company_name'] ?? ''}'.trim();
  }
  return '${c[k] ?? ''}'.trim();
}

pw.Widget _letterhead(String title) {
  final lines = <String>[
    if (_co('name').isNotEmpty) _co('name'),
    if (_co('address').isNotEmpty) _co('address'),
    [if (_co('phone').isNotEmpty) 'Tel ${_co('phone')}', if (_co('vat_number').isNotEmpty) 'VAT no ${_co('vat_number')}'].join('  ·  '),
  ].where((e) => e.isNotEmpty).toList();
  return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
    pw.Text(title, style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
    pw.SizedBox(height: 4),
    for (final l in lines) pw.Text(l, style: const pw.TextStyle(fontSize: 9)),
    pw.Divider(),
  ]);
}

/// A4 statement with a grid table, the same for customers and suppliers.
Future<Uint8List> ledgerPdf(Ledger g) async {
  const grid = pw.TableBorder(
    horizontalInside: pw.BorderSide(color: PdfColors.grey400, width: 0.4),
    verticalInside: pw.BorderSide(color: PdfColors.grey400, width: 0.4),
    left: pw.BorderSide(color: PdfColors.grey400, width: 0.4),
    right: pw.BorderSide(color: PdfColors.grey400, width: 0.4),
    top: pw.BorderSide(color: PdfColors.grey400, width: 0.4),
    bottom: pw.BorderSide(color: PdfColors.grey400, width: 0.4),
  );
  String cell(double v) => v > 0.004 ? money(v) : '';
  final doc = pw.Document(title: '${g.title} ${g.partyName}', author: _co('name'));
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    footer: (c) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('Page ${c.pageNumber} of ${c.pagesCount}', style: const pw.TextStyle(fontSize: 8))),
    build: (_) => [
      _letterhead(g.title),
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(g.partyName, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12)),
            for (final l in g.partyInfo) pw.Text(l),
          ]),
        ),
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          for (final l in g.metaRight) pw.Text(l),
          pw.Text('Period ${g.from} to ${g.to}'),
        ]),
      ]),
      pw.SizedBox(height: 12),
      pw.TableHelper.fromTextArray(
        border: grid,
        headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
        cellStyle: const pw.TextStyle(fontSize: 9),
        headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
        cellAlignments: {2: pw.Alignment.centerRight, 3: pw.Alignment.centerRight, 4: pw.Alignment.centerRight},
        columnWidths: {
          0: const pw.FixedColumnWidth(58),
          1: const pw.FlexColumnWidth(3),
          2: const pw.FixedColumnWidth(66),
          3: const pw.FixedColumnWidth(66),
          4: const pw.FixedColumnWidth(70),
        },
        headers: ['Date', 'Description', g.chargeLabel == 'Sales' ? 'Sales' : 'Bought', 'Paid', 'Balance'],
        data: [
          ['', 'Opening balance', '', '', money(g.opening)],
          for (final l in g.lines)
            [l.date, l.tag.isEmpty ? l.what : '${l.what} (${l.tag})', l.muted ? '' : cell(l.charge), cell(l.paid), money(l.balance)],
          ['', 'Closing balance', cell(g.totalCharges), cell(g.totalPaid), money(g.closing)],
        ],
      ),
      pw.SizedBox(height: 8),
      pw.Text(
          g.closing < -0.004
              ? 'Overpaid: ${money(-g.closing)} is in credit.'
              : (g.closing > 0.004 ? 'Amount ${g.owedWord}: ${money(g.closing)}' : 'Nothing ${g.owedWord}.'),
          style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
      ...(() {
        final st = analyseLedger(g);
        if (st.chargeCount + st.paymentCount == 0) return <pw.Widget>[];
        return <pw.Widget>[
          pw.SizedBox(height: 6),
          pw.Text(
              '${st.chargeCount} ${g.chargeLabel.toLowerCase()} averaging ${money(st.avgCharge)} · ${st.paymentCount} payments averaging ${money(st.avgPayment)}'
              '${st.avgDaysToPay == null ? '' : ' · paid on average after ${st.avgDaysToPay!.round()} days'}'
              '${st.oldestOpenDays == null ? '' : ' · oldest unpaid item ${st.oldestOpenDays} days old'}',
              style: const pw.TextStyle(fontSize: 8)),
        ];
      })(),
      if (g.ageing != null) ...[
        pw.SizedBox(height: 12),
        pw.Text('Amount owing by age', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
        pw.TableHelper.fromTextArray(
          border: grid,
          headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
          cellStyle: const pw.TextStyle(fontSize: 9),
          cellAlignment: pw.Alignment.centerRight,
          headers: ['0-30 days', '31-60 days', '61-90 days', 'Over 90 days'],
          data: [
            [money(g.ageing!['current'] ?? 0), money(g.ageing!['d31'] ?? 0), money(g.ageing!['d61'] ?? 0), money(g.ageing!['d90'] ?? 0)]
          ],
        ),
      ],
      if (g.footer.isNotEmpty) ...[pw.SizedBox(height: 10), pw.Text(g.footer, style: const pw.TextStyle(fontSize: 8))],
    ],
  ));
  return doc.save();
}

String _csv(Object? v) {
  final s = '${v ?? ''}';
  return s.contains(',') || s.contains('"') || s.contains('\n') ? '"${s.replaceAll('"', '""')}"' : s;
}

/// The statement as a spreadsheet file.
Uint8List ledgerCsv(Ledger g) {
  final b = StringBuffer()
    ..writeln('${g.title},${_csv(g.partyName)}')
    ..writeln('Period,${g.from} to ${g.to}')
    ..writeln('Date,Description,Charge,Paid,Balance')
    ..writeln(',Opening balance,,,${g.opening.toStringAsFixed(2)}');
  for (final l in g.lines) {
    b.writeln([l.date, _csv(l.tag.isEmpty ? l.what : '${l.what} (${l.tag})'), l.muted ? '' : l.charge.toStringAsFixed(2), l.paid.toStringAsFixed(2), l.balance.toStringAsFixed(2)].join(','));
  }
  b.writeln(',Closing balance,${g.totalCharges.toStringAsFixed(2)},${g.totalPaid.toStringAsFixed(2)},${g.closing.toStringAsFixed(2)}');
  return Uint8List.fromList(utf8.encode(b.toString()));
}

/// A printed list of everybody and what they owe, or are owed.
Future<Uint8List> partyListPdf({
  required String title,
  required List<String> headers,
  required List<List<String>> rows,
  List<String> totals = const [],
}) async {
  const grid = pw.TableBorder(
    horizontalInside: pw.BorderSide(color: PdfColors.grey400, width: 0.4),
    verticalInside: pw.BorderSide(color: PdfColors.grey400, width: 0.4),
    left: pw.BorderSide(color: PdfColors.grey400, width: 0.4),
    right: pw.BorderSide(color: PdfColors.grey400, width: 0.4),
    top: pw.BorderSide(color: PdfColors.grey400, width: 0.4),
    bottom: pw.BorderSide(color: PdfColors.grey400, width: 0.4),
  );
  final now = DateTime.now();
  final doc = pw.Document(title: title, author: _co('name'));
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4.landscape,
    margin: const pw.EdgeInsets.all(28),
    footer: (c) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text('Page ${c.pageNumber} of ${c.pagesCount}', style: const pw.TextStyle(fontSize: 8))),
    build: (_) => [
      _letterhead(title),
      pw.Text('As at ${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}', style: const pw.TextStyle(fontSize: 9)),
      pw.SizedBox(height: 8),
      pw.TableHelper.fromTextArray(
        border: grid,
        headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9),
        cellStyle: const pw.TextStyle(fontSize: 9),
        headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
        cellAlignments: {for (var i = 2; i < headers.length; i++) i: pw.Alignment.centerRight},
        headers: headers,
        data: [...rows, if (totals.isNotEmpty) totals],
      ),
    ],
  ));
  return doc.save();
}
