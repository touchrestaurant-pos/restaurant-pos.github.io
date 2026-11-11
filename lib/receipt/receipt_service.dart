import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/auth_service.dart';
import '../data/local_store.dart';
import '../data/repo.dart';
import '../data/sync_service.dart';
import '../theme.dart';

/// Everything printed on a customer receipt.
class ReceiptData {
  ReceiptData({
    required this.order,
    required this.items,
    required this.payments,
    required this.company,
    this.refunded = 0,
    this.creditNotes = const [],
  });
  final Map<String, dynamic> order;
  final List<Map<String, dynamic>> items;
  final List<Map<String, dynamic>> payments;
  final Map<String, dynamic> company;
  final double refunded;

  /// Numbers of the credit notes issued for refunds on this order.
  final List<int> creditNotes;

  String get ref => '${order['order_ref']}';
  bool get paid => order['paid'] == true;
  bool get cancelled => order['status'] == 'void';
  double get total => n(order['total']).toDouble();
  double get vat => n(order['vat']).toDouble();
  double get subtotal => n(order['subtotal']).toDouble();
  double get discount => n(order['discount']).toDouble();
  double get paidAmount => payments.fold<double>(0, (s, p) => s + n(p['amount']).toDouble());
  double get tips => payments.fold<double>(0, (s, p) => s + n(p['tip']).toDouble());
  DateTime get when => parseTime(order['created_at']) ?? DateTime.now();
  String get vatNumber => '${company['vat_number'] ?? ''}'.trim();

  /// Sequential number given by the server once the order is paid.
  String? get invoiceNo {
    final v = order['invoice_no'];
    if (v == null) return null;
    final prefix = '${company['invoice_prefix'] ?? 'INV'}'.trim();
    return '${prefix.isEmpty ? 'INV' : prefix}-${'$v'.padLeft(6, '0')}';
  }

  String get companyName {
    final t = '${company['trading_name'] ?? ''}'.trim();
    final c = '${company['company_name'] ?? ''}'.trim();
    return t.isNotEmpty ? t : (c.isNotEmpty ? c : 'Receipt');
  }

  String get typeText {
    const names = {'eat_in': 'Eat in', 'take_away': 'Take away', 'delivery': 'Delivery'};
    final base = names[order['order_type']] ?? '';
    final table = '${order['table_no'] ?? ''}'.trim();
    return table.isEmpty ? base : '$base, table $table';
  }

  /// From rows fetched from the server (orders older than the device keeps).
  factory ReceiptData.fromServer(Map<String, dynamic> row) {
    final items = ((row['order_items'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((i) => i['voided'] != true)
        .toList()
      ..sort((a, b) => '${a['created_at']}'.compareTo('${b['created_at']}'));
    final pays = ((row['payments'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList()
      ..sort((a, b) => '${a['created_at']}'.compareTo('${b['created_at']}'));
    return ReceiptData(order: row, items: items, payments: pays, company: companyRow() ?? const {});
  }

  ReceiptData withRefunds(double refunded, List<int> notes) => ReceiptData(
      order: order, items: items, payments: payments, company: company, refunded: refunded, creditNotes: notes);

  static ReceiptData? forOrder(String orderId, {double refunded = 0}) {
    final order = LocalStore.row('orders', orderId);
    if (order == null) return null;
    final items = LocalStore.rows('order_items')
        .where((i) => i['order_id'] == orderId && i['voided'] != true)
        .toList()
      ..sort((a, b) => '${a['created_at']}'.compareTo('${b['created_at']}'));
    final pays = LocalStore.rows('payments').where((p) => p['order_id'] == orderId).toList()
      ..sort((a, b) => '${a['created_at']}'.compareTo('${b['created_at']}'));
    return ReceiptData(order: order, items: items, payments: pays, company: companyRow() ?? const {}, refunded: refunded);
  }
}

/// One line of a receipt. The screen, the PDF and the email are all drawn from
/// the same list, so they always say the same thing.
class RLine {
  const RLine.center(this.left, {this.size = 9, this.bold = false})
      : right = null,
        kind = 'center';
  const RLine.row(this.left, this.right, {this.size = 9, this.bold = false}) : kind = 'row';
  const RLine.note(this.left)
      : right = null,
        size = 8,
        bold = false,
        kind = 'note';
  const RLine.divider()
      : left = '',
        right = null,
        size = 0,
        bold = false,
        kind = 'divider';
  const RLine.gap()
      : left = '',
        right = null,
        size = 0,
        bold = false,
        kind = 'gap';
  final String kind;
  final String left;
  final String? right;
  final double size;
  final bool bold;
}

String _method(dynamic m) => m == 'cash' ? 'Cash' : (m == 'account' ? 'On account' : 'Card');
String _lineTotal(Map<String, dynamic> i) => money(n(i['qty']) * n(i['unit_price']));
final _when = DateFormat('yyyy-MM-dd HH:mm');
String _rate() => vatRate().toStringAsFixed(vatRate() == vatRate().roundToDouble() ? 0 : 1);

/// How the bill was paid. One payment reads "Paid by Cash"; a split bill lists
/// each part and a total. Cash received and change show only when change was given.
List<RLine> _paymentLines(ReceiptData r) {
  final pays = r.payments;
  if (pays.isEmpty) return const [];
  final split = pays.length > 1;
  final out = <RLine>[];
  if (split) out.add(const RLine.row('PAYMENTS', '', size: 8, bold: true));
  for (final p in pays) {
    out.add(RLine.row(split ? '  ${_method(p['method'])}' : 'Paid by ${_method(p['method'])}', money(n(p['amount'])), size: 8));
  }
  final onAcct = pays.where((p) => p['method'] == 'account').toList();
  if (onAcct.isNotEmpty) {
    final first = onAcct.first;
    out.add(const RLine.divider());
    out.add(RLine.row('Charged to account', money(onAcct.fold<double>(0, (s, p) => s + n(p['amount']).toDouble())), size: 8, bold: true));
    out.add(RLine.note('${first['account_name'] ?? ''} (${first['account_no'] ?? ''})'));
    if ('${first['account_vat_no'] ?? ''}'.isNotEmpty) out.add(RLine.note('Customer VAT no: ${first['account_vat_no']}'));
    if ('${first['account_address'] ?? ''}'.isNotEmpty) out.add(RLine.note('${first['account_address']}'));
    out.add(const RLine.note('Amount owing is payable on the terms of your account.'));
    out.add(const RLine.gap());
    out.add(const RLine.note('Customer signature: ____________________'));
  }
  if (split) out.add(RLine.row('Total paid', money(r.paidAmount), size: 8, bold: true));
  if (r.tips > 0) out.add(RLine.row('Tip (thank you)', money(r.tips), size: 8));
  final received = pays
      .where((p) => p['method'] == 'cash' && n(p['change_given']) > 0)
      .fold<double>(0, (s, p) => s + n(p['tendered']).toDouble());
  final change = pays.fold<double>(0, (s, p) => s + n(p['change_given']).toDouble());
  if (change > 0) {
    out.add(RLine.row('Cash received', money(received), size: 8));
    out.add(RLine.row('Change', money(change), size: 8));
  }
  return out;
}

/// Zero-rated and exempt items, shown separately as a tax invoice requires.
List<RLine> _vatSplit(ReceiptData r) {
  final byType = <String, double>{};
  final itemsTotal = r.items.fold<double>(0, (s, i) => s + n(i['qty']) * n(i['unit_price']).toDouble());
  if (itemsTotal <= 0) return const [];
  final factor = r.total / itemsTotal;
  for (final i in r.items) {
    final t = '${i['vat_type'] ?? 'standard'}';
    byType[t] = (byType[t] ?? 0) + n(i['qty']) * n(i['unit_price']).toDouble() * factor;
  }
  if (byType.keys.every((k) => k == 'standard')) return const [];
  return [
    if ((byType['standard'] ?? 0) > 0) RLine.row('  Standard rated', money(round2(byType['standard']!)), size: 7),
    if ((byType['zero'] ?? 0) > 0) RLine.row('  Zero-rated (Z)', money(round2(byType['zero']!)), size: 7),
    if ((byType['exempt'] ?? 0) > 0) RLine.row('  Exempt (E)', money(round2(byType['exempt']!)), size: 7),
  ];
}

List<RLine> receiptLines(ReceiptData r) {
  final c = r.company;
  final taxInvoice = r.vatNumber.isNotEmpty;
  final footer = '${c['receipt_footer'] ?? ''}'.trim();
  final lines = <RLine>[
    RLine.center(r.companyName, size: 13, bold: true),
    for (final k in ['company_name', 'address', 'phone', 'email'])
      if ('${c[k] ?? ''}'.trim().isNotEmpty && !(k == 'company_name' && '${c[k]}'.trim() == r.companyName))
        RLine.center(k == 'phone' ? 'Tel ${c[k]}' : '${c[k]}'.trim(), size: 8),
    if (taxInvoice) RLine.center('VAT no. ${r.vatNumber}', size: 8),
    const RLine.divider(),
    RLine.center(taxInvoice ? 'TAX INVOICE' : 'RECEIPT', size: 11, bold: true),
    if (r.invoiceNo != null)
      RLine.center('No. ${r.invoiceNo}', size: 10, bold: true)
    else if (r.paid)
      const RLine.center('Invoice number given when synced', size: 7),
    RLine.center('Order #${r.ref} · ${_when.format(r.when)}', size: 8),
    if (r.typeText.isNotEmpty) RLine.center(r.typeText, size: 8),
    if ('${r.order['customer_name'] ?? ''}'.trim().isNotEmpty)
      RLine.center(
          'Customer: ${r.order['customer_name']}${'${r.order['customer_phone'] ?? ''}'.trim().isEmpty ? '' : ' · ${r.order['customer_phone']}'}',
          size: 8),
    if ('${r.order['delivery_address'] ?? ''}'.trim().isNotEmpty)
      RLine.center('Deliver to: ${r.order['delivery_address']}', size: 8),
    if (r.cancelled) const RLine.center('CANCELLED', size: 11, bold: true),
    if (!r.paid && !r.cancelled)
      RLine.center(r.paidAmount > 0 ? 'PART PAID' : 'NOT PAID - BILL', size: 11, bold: true),
    const RLine.divider(),
    for (final i in r.items) ...[
      RLine.row('${i['qty']} x ${i['name']}${i['vat_type'] == 'zero' ? ' (Z)' : (i['vat_type'] == 'exempt' ? ' (E)' : '')}',
          _lineTotal(i)),
      if ('${i['notes'] ?? ''}'.trim().isNotEmpty) RLine.note('${i['notes']}'.trim()),
    ],
    const RLine.divider(),
    if (r.discount > 0) ...[
      RLine.row('Items', money(r.total + r.discount), size: 8),
      RLine.row(
          'Discount${'${r.order['discount_reason'] ?? ''}'.trim().isEmpty ? '' : ' (${r.order['discount_reason']})'}',
          '-${money(r.discount)}',
          size: 8),
    ],
    RLine.row('TOTAL (incl. VAT)', money(r.total), bold: true, size: 12),
    RLine.row('Excl. VAT', money(r.subtotal), size: 8),
    RLine.row('VAT ${_rate()}%', money(r.vat), size: 8),
    ..._vatSplit(r),
    const RLine.gap(),
    ..._paymentLines(r),
    if (!r.paid && !r.cancelled) RLine.row('STILL TO PAY', money(r.total - r.paidAmount), bold: true, size: 10),
    if (r.refunded > 0) ...[
      RLine.row('Refunded', money(r.refunded), bold: true, size: 8),
      if (r.creditNotes.isNotEmpty)
        RLine.row('  Credit note', r.creditNotes.map((c) => 'CN-${'$c'.padLeft(6, '0')}').join(', '), size: 8),
    ],
    if (footer.isNotEmpty) ...[const RLine.gap(), RLine.center(footer, size: 8)],
  ];
  return lines;
}

/// Plain text version, used for email.
String receiptText(ReceiptData r) {
  final b = StringBuffer();
  for (final l in receiptLines(r)) {
    switch (l.kind) {
      case 'divider':
        b.writeln('------------------------------');
      case 'gap':
        b.writeln('');
      case 'row':
        b.writeln('${l.left}   ${l.right}');
      case 'note':
        b.writeln('   (${l.left})');
      default:
        b.writeln(l.left);
    }
  }
  return b.toString();
}

/// Slip paper: 80 mm rolls print 72 mm wide, 58 mm rolls print about 48 mm wide.
int slipPaperMm() => (LocalStore.getMeta('slip_paper_mm') as int?) ?? 80;

PdfPageFormat slipFormat() {
  final printable = slipPaperMm() == 58 ? 48.0 : 72.0;
  return PdfPageFormat(printable * PdfPageFormat.mm, double.infinity,
      marginLeft: 2 * PdfPageFormat.mm,
      marginRight: 2 * PdfPageFormat.mm,
      marginTop: 3 * PdfPageFormat.mm,
      marginBottom: 6 * PdfPageFormat.mm);
}

/// Roll PDF sized to the printable width of a standard slip printer.
Future<Uint8List> receiptPdf(ReceiptData r) async {
  final c = r.company;
  pw.ImageProvider? logo;
  final url = '${c['logo_url'] ?? ''}';
  if (url.isNotEmpty) {
    try {
      logo = await networkImage(url);
    } catch (_) {
      logo = null; // print without the logo if it cannot be fetched
    }
  }
  final small = slipPaperMm() == 58;
  pw.TextStyle t(double size, {bool bold = false, bool italic = false}) => pw.TextStyle(
      fontSize: small ? size * 0.85 : size,
      fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      fontStyle: italic ? pw.FontStyle.italic : pw.FontStyle.normal);

  pw.Widget draw(RLine l) {
    switch (l.kind) {
      case 'divider':
        return pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 4), child: pw.Divider(thickness: 0.6, height: 1));
      case 'gap':
        return pw.SizedBox(height: 4);
      case 'row':
        return pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 1),
          child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Expanded(child: pw.Text(l.left, style: t(l.size, bold: l.bold))),
            pw.SizedBox(width: 6),
            pw.Text(l.right ?? '', style: t(l.size, bold: l.bold)),
          ]),
        );
      case 'note':
        return pw.Padding(
            padding: const pw.EdgeInsets.only(left: 8, bottom: 2), child: pw.Text(l.left, style: t(8, italic: true)));
      default:
        return pw.SizedBox(
            width: double.infinity,
            child: pw.Text(l.left, style: t(l.size, bold: l.bold), textAlign: pw.TextAlign.center));
    }
  }

  final doc = pw.Document(title: 'Receipt ${r.ref}', author: r.companyName);
  doc.addPage(pw.Page(
    pageFormat: slipFormat(),
    build: (ctx) => pw.Container(
      // A very short slip (one item, no notes) can print on its side on some
      // slip printers, whose driver rotates anything much shorter than the
      // roll's fixed page length. A minimum length avoids that.
      constraints: const pw.BoxConstraints(minHeight: 70 * PdfPageFormat.mm),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        if (logo != null) pw.Center(child: pw.Image(logo, width: 46, height: 46, fit: pw.BoxFit.contain)),
        if (logo != null) pw.SizedBox(height: 4),
        for (final l in receiptLines(r)) draw(l),
        pw.SizedBox(height: 6),
      ]),
    ),
  ));
  return doc.save();
}

// ---- printing ----------------------------------------------------------------

/// Print straight after a sale is fully paid (per device).
bool autoPrintOn() => LocalStore.getMeta('auto_print') == true;
Future<void> setAutoPrint(bool v) => LocalStore.setMeta('auto_print', v);

/// On the Windows and Android apps a slip printer can be chosen once; receipts
/// then print without a dialog. Browsers always show their print dialog.
String? savedPrinterName() => LocalStore.getMeta('printer_name') as String?;

Future<String?> chooseSlipPrinter(BuildContext context) async {
  final p = await Printing.pickPrinter(context: context, title: 'Choose the slip printer');
  if (p == null) return null;
  await LocalStore.setMeta('printer_url', p.url);
  await LocalStore.setMeta('printer_name', p.name);
  return p.name;
}

Future<void> forgetSlipPrinter() async {
  await LocalStore.removeMeta('printer_url');
  await LocalStore.removeMeta('printer_name');
}

Future<void> printSlip(ReceiptData r) async {
  final url = LocalStore.getMeta('printer_url') as String?;
  if (!kIsWeb && url != null) {
    final ok = await Printing.directPrintPdf(
      printer: Printer(url: url, name: savedPrinterName()),
      name: 'Receipt-${r.ref}',
      format: slipFormat(),
      usePrinterSettings: false,
      onLayout: (_) => receiptPdf(r),
    );
    if (ok) return;
  }
  await Printing.layoutPdf(
    name: 'Receipt-${r.ref}',
    format: slipFormat(),
    dynamicLayout: false,
    usePrinterSettings: false,
    onLayout: (_) => receiptPdf(r),
  );
}

/// Called by the till after a sale is fully paid.
Future<void> maybeAutoPrint(String orderId) async {
  if (!autoPrintOn()) return;
  final r = ReceiptData.forOrder(orderId);
  if (r == null) return;
  try {
    await printSlip(r);
  } catch (_) {
    // A printer problem must never stop the till.
  }
}

/// Print a ticket for the kitchen after an order is sent (per device).
bool kitchenTicketOn() => LocalStore.getMeta('kitchen_ticket') == true;
Future<void> setKitchenTicket(bool v) => LocalStore.setMeta('kitchen_ticket', v);

/// Kitchen ticket: big item names and special requests, no prices.
Future<Uint8List> kitchenTicketPdf(String orderId, {Set<dynamic>? onlyItemIds}) async {
  final o = LocalStore.row('orders', orderId) ?? const {};
  final items = LocalStore.rows('order_items')
      .where((i) => i['order_id'] == orderId && i['voided'] != true && (onlyItemIds == null || onlyItemIds.contains(i['id'])))
      .toList()
    ..sort((a, b) => '${a['created_at']}'.compareTo('${b['created_at']}'));
  const types = {'eat_in': 'EAT IN', 'take_away': 'TAKE AWAY', 'delivery': 'DELIVERY'};
  final t = parseTime(o['created_at']) ?? DateTime.now();
  final doc = pw.Document(title: 'Kitchen ${o['order_ref']}');
  pw.TextStyle st(double size, {bool bold = true}) =>
      pw.TextStyle(fontSize: size, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal);
  doc.addPage(pw.Page(
    pageFormat: slipFormat(),
    build: (ctx) => pw.Container(
      // A short order (1-2 items) can print on its side on some slip
      // printers, whose driver rotates anything much shorter than the roll's
      // fixed page length. A minimum length avoids that.
      constraints: const pw.BoxConstraints(minHeight: 70 * PdfPageFormat.mm),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        pw.Text('#${o['order_ref']}', style: st(22), textAlign: pw.TextAlign.center),
        pw.Text(
            '${types[o['order_type']] ?? ''}${o['table_no'] != null ? '  TABLE ${o['table_no']}' : ''}',
            style: st(13),
            textAlign: pw.TextAlign.center),
        if ('${o['customer_name'] ?? ''}'.trim().isNotEmpty)
          pw.Text('${o['customer_name']}', style: st(11), textAlign: pw.TextAlign.center),
        pw.Text('${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}${onlyItemIds != null ? '  ** ADDED ITEMS **' : ''}',
            style: st(10, bold: false), textAlign: pw.TextAlign.center),
        pw.Divider(thickness: 0.8),
        for (final i in items) ...[
          pw.Text('${i['qty']} x ${i['name']}', style: st(14)),
          if ('${i['notes'] ?? ''}'.trim().isNotEmpty)
            pw.Padding(
                padding: const pw.EdgeInsets.only(left: 10, bottom: 2),
                child: pw.Text('>> ${'${i['notes']}'.trim().toUpperCase()}', style: st(11))),
          pw.SizedBox(height: 4),
        ],
        pw.SizedBox(height: 8),
      ]),
    ),
  ));
  return doc.save();
}

Future<void> maybePrintKitchenTicket(String orderId, {Set<dynamic>? onlyItemIds}) async {
  if (!kitchenTicketOn()) return;
  try {
    final url = LocalStore.getMeta('kitchen_printer_url') as String? ?? LocalStore.getMeta('printer_url') as String?;
    if (!kIsWeb && url != null) {
      final ok = await Printing.directPrintPdf(
        printer: Printer(url: url),
        name: 'Kitchen-$orderId',
        format: slipFormat(),
        usePrinterSettings: false,
        onLayout: (_) => kitchenTicketPdf(orderId, onlyItemIds: onlyItemIds),
      );
      if (ok) return;
    }
    await Printing.layoutPdf(
      name: 'Kitchen ticket',
      format: slipFormat(),
      dynamicLayout: false,
      usePrinterSettings: false,
      onLayout: (_) => kitchenTicketPdf(orderId, onlyItemIds: onlyItemIds),
    );
  } catch (_) {
    // A printer problem must never stop the till.
  }
}

Future<void> downloadReceipt(ReceiptData r) async {
  await Printing.sharePdf(bytes: await receiptPdf(r), filename: 'Receipt-${r.ref}.pdf');
}

/// Opens the customer's mail app with the receipt written in the message.
Future<bool> emailReceipt(ReceiptData r, String to) {
  final subject = Uri.encodeComponent('Your receipt from ${r.companyName} (#${r.ref})');
  final body = Uri.encodeComponent('${receiptText(r)}\nThank you for your order.');
  return launchUrl(Uri.parse('mailto:${to.trim()}?subject=$subject&body=$body'));
}

/// Shows the receipt with Print, Download PDF and Email buttons.
/// Supervisors and admins also get Refund for paid orders.
Future<void> showReceiptDialog(BuildContext context, String orderId, {ReceiptData? data}) async {
  await showDialog<void>(context: context, builder: (_) => _ReceiptDialog(orderId: orderId, preset: data));
}

class _ReceiptDialog extends StatefulWidget {
  const _ReceiptDialog({required this.orderId, this.preset});
  final String orderId;

  /// Set for an older order that was fetched from the server.
  final ReceiptData? preset;

  @override
  State<_ReceiptDialog> createState() => _ReceiptDialogState();
}

class _ReceiptDialogState extends State<_ReceiptDialog> {
  double _refunded = 0;
  List<int> _notes = [];

  bool get _canRefund => const ['admin', 'supervisor'].contains(AuthService.instance.role);

  @override
  void initState() {
    super.initState();
    _loadRefunds();
  }

  Future<void> _loadRefunds() async {
    if (!_canRefund) return;
    try {
      final rows = await Supabase.instance.client
          .from('refunds')
          .select('amount, credit_note_no')
          .eq('order_id', widget.orderId)
          .order('created_at');
      final sum = rows.fold<double>(0, (s, e) => s + n(e['amount']).toDouble());
      if (mounted) {
        setState(() {
          _refunded = sum;
          _notes = [for (final e in rows) if (e['credit_note_no'] != null) n(e['credit_note_no']).toInt()];
        });
      }
    } catch (_) {
      // offline: refunds are simply not shown
    }
  }

  void _say(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _email(ReceiptData r) async {
    final c = TextEditingController();
    final to = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Email receipt'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
                controller: c,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: "Customer's email address")),
            const SizedBox(height: 8),
            const Text(
                'This opens your email app with the receipt already written. To attach the PDF as well, press Download PDF and add the file.',
                style: TextStyle(color: Brand.muted, fontSize: 12)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () {
                final v = c.text.trim();
                if (RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v)) Navigator.pop(ctx, v);
              },
              child: const Text('Open email')),
        ],
      ),
    );
    if (to == null) return;
    try {
      if (!await emailReceipt(r, to)) _say('Could not open an email app on this device.');
    } catch (_) {
      _say('Could not open an email app on this device.');
    }
  }

  Future<void> _refund(ReceiptData r) async {
    final remaining = round2(r.paidAmount - _refunded);
    if (remaining <= 0) {
      _say('This order has already been fully refunded.');
      return;
    }
    final amount = TextEditingController(text: remaining.toStringAsFixed(2));
    final reason = TextEditingController();
    final hasAcct = r.payments.any((p) => p['method'] == 'account');
    String method = r.payments.isNotEmpty ? '${r.payments.first['method']}' : 'cash';
    bool restock = !r.cancelled;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final a = double.tryParse(amount.text.replaceAll(',', '.'));
        final valid = a != null && a > 0 && a <= remaining + 0.001 && reason.text.trim().isNotEmpty;
        return AlertDialog(
          title: Text('Refund order #${r.ref}'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Paid ${money(r.paidAmount)}${_refunded > 0 ? ', already refunded ${money(_refunded)}' : ''}. Refundable: ${money(remaining)}'),
              const SizedBox(height: 12),
              TextField(
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => set(() {}),
                  decoration: const InputDecoration(labelText: 'Refund amount', prefixText: 'R')),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: 'cash', label: Text('Cash back')),
                  ButtonSegment(value: 'card_manual', label: Text('Back to card')),
                  if (hasAcct) ButtonSegment(value: 'account', label: Text('Account credit')),
                ],
                selected: {method},
                onSelectionChanged: (v) => set(() => method = v.first),
              ),
              const SizedBox(height: 8),
              TextField(
                  controller: reason,
                  onChanged: (_) => set(() {}),
                  decoration: const InputDecoration(labelText: 'Reason (required)')),
              if (r.cancelled)
                const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('This order was cancelled, so its ingredients are already back in stock.',
                        style: TextStyle(color: Brand.muted, fontSize: 12)))
              else
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: restock,
                  onChanged: (v) => set(() => restock = v ?? false),
                  title: const Text('Put the ingredients back in stock'),
                  subtitle: const Text('Tick if the food was not made or can be reused. Leave unticked if it was made and wasted.'),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Brand.red, foregroundColor: Colors.white),
                onPressed: valid ? () => Navigator.pop(ctx, true) : null,
                child: const Text('Refund')),
          ],
        );
      }),
    );
    if (ok != true) return;
    try {
      await Supabase.instance.client.rpc('issue_refund', params: {
        'p_order_id': widget.orderId,
        'p_amount': double.parse(amount.text.replaceAll(',', '.')),
        'p_method': method,
        'p_reason': reason.text.trim(),
        'p_restock': restock && !r.cancelled,
      });
      await _loadRefunds();
      _say(_notes.isEmpty ? 'Refund recorded.' : 'Refund recorded. Credit note CN-${'${_notes.last}'.padLeft(6, '0')}. Print the slip for the customer.');
      await SyncService.instance.syncNow();
    } on PostgrestException catch (e) {
      _say(e.message);
    } catch (_) {
      _say('Refunds need an internet connection.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = (widget.preset ?? ReceiptData.forOrder(widget.orderId))?.withRefunds(_refunded, _notes);
    if (r == null) {
      return AlertDialog(
          content: const Text('This order is not stored on this device.'),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))]);
    }
    return AlertDialog(
      title: Text(r.invoiceNo ?? 'Receipt #${r.ref}'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(child: _ReceiptPaper(r: r)),
      ),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actionsOverflowButtonSpacing: 6,
      actions: [
        Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          DropdownButton<int>(
            value: slipPaperMm(),
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(value: 80, child: Text('80 mm slip')),
              DropdownMenuItem(value: 58, child: Text('58 mm slip')),
            ],
            onChanged: (v) async {
              await LocalStore.setMeta('slip_paper_mm', v ?? 80);
              setState(() {});
            },
          ),
          FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Brand.navy, foregroundColor: Colors.white),
              onPressed: () async {
                try {
                  await printSlip(r);
                } catch (_) {
                  _say('Could not open the printer. Try Download PDF instead.');
                }
              },
              icon: const Icon(Icons.print, size: 18),
              label: const Text('Print slip')),
          OutlinedButton.icon(
              onPressed: () async {
                try {
                  await downloadReceipt(r);
                } catch (_) {
                  _say('Could not create the PDF.');
                }
              },
              icon: const Icon(Icons.picture_as_pdf, size: 18),
              label: const Text('Download PDF')),
          OutlinedButton.icon(
              onPressed: () => _email(r),
              icon: const Icon(Icons.email_outlined, size: 18),
              label: const Text('Email')),
          if (_canRefund && r.paidAmount > 0)
            TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: Brand.red),
                onPressed: () => _refund(r),
                icon: const Icon(Icons.undo, size: 18),
                label: const Text('Refund')),
        ]),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}

/// On-screen look of the slip.
class _ReceiptPaper extends StatelessWidget {
  const _ReceiptPaper({required this.r});
  final ReceiptData r;

  @override
  Widget build(BuildContext context) {
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.35);
    TextStyle st(RLine l) => mono.copyWith(
        fontWeight: l.bold ? FontWeight.w800 : null, fontSize: l.size <= 0 ? 13 : (l.size + 4).clamp(10, 18).toDouble());
    Widget draw(RLine l) {
      switch (l.kind) {
        case 'divider':
          return const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Divider(height: 1, thickness: 1));
        case 'gap':
          return const SizedBox(height: 6);
        case 'row':
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Text(l.left, style: st(l))),
              Text(l.right ?? '', style: st(l)),
            ]),
          );
        case 'note':
          return Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Text(l.left, style: mono.copyWith(fontSize: 11, fontStyle: FontStyle.italic))));
        default:
          return SizedBox(width: double.infinity, child: Text(l.left, textAlign: TextAlign.center, style: st(l)));
      }
    }

    final logo = '${r.company['logo_url'] ?? ''}';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Brand.border),
          boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 6, offset: Offset(0, 2))]),
      child: Column(children: [
        if (logo.isNotEmpty)
          Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Image.network(logo, width: 52, height: 52, errorBuilder: (_, __, ___) => const SizedBox())),
        for (final l in receiptLines(r)) draw(l),
      ]),
    );
  }
}
