import 'dart:typed_data';

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
  });
  final Map<String, dynamic> order;
  final List<Map<String, dynamic>> items;
  final List<Map<String, dynamic>> payments;
  final Map<String, dynamic> company;
  final double refunded;

  String get ref => '${order['order_ref']}';
  bool get paid => order['paid'] == true;
  bool get cancelled => order['status'] == 'void';
  double get total => n(order['total']).toDouble();
  double get vat => n(order['vat']).toDouble();
  double get subtotal => n(order['subtotal']).toDouble();
  DateTime get when => parseTime(order['created_at']) ?? DateTime.now();
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

  static ReceiptData? forOrder(String orderId, {double refunded = 0}) {
    Map<String, dynamic>? order;
    for (final o in LocalStore.rows('orders')) {
      if (o['id'] == orderId) order = o;
    }
    if (order == null) return null;
    final items = LocalStore.rows('order_items').where((i) => i['order_id'] == orderId).toList()
      ..sort((a, b) => '${a['created_at']}'.compareTo('${b['created_at']}'));
    final pays = LocalStore.rows('payments').where((p) => p['order_id'] == orderId).toList();
    return ReceiptData(
        order: order,
        items: items,
        payments: pays,
        company: companyRow() ?? const {},
        refunded: refunded);
  }
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

String _method(dynamic m) => m == 'cash' ? 'Cash' : 'Credit card';

String _lineTotal(Map<String, dynamic> i) => money(n(i['qty']) * n(i['unit_price']));

final _when = DateFormat('yyyy-MM-dd HH:mm');

/// Plain text version, used for email and as a fallback.
String receiptText(ReceiptData r) {
  final c = r.company;
  final b = StringBuffer();
  b.writeln(r.companyName);
  for (final k in ['address', 'phone', 'email']) {
    final v = '${c[k] ?? ''}'.trim();
    if (v.isNotEmpty) b.writeln(k == 'phone' ? 'Tel $v' : v);
  }
  final vatNo = '${c['vat_number'] ?? ''}'.trim();
  if (vatNo.isNotEmpty) b.writeln('VAT no. $vatNo');
  b.writeln('');
  b.writeln('Receipt #${r.ref}');
  b.writeln(_when.format(r.when));
  if (r.typeText.isNotEmpty) b.writeln(r.typeText);
  if (r.cancelled) b.writeln('*** CANCELLED ***');
  if (!r.paid) b.writeln('*** NOT PAID ***');
  b.writeln('------------------------------');
  for (final i in r.items) {
    b.writeln('${i['qty']} x ${i['name']}   ${_lineTotal(i)}');
    final note = '${i['notes'] ?? ''}'.trim();
    if (note.isNotEmpty) b.writeln('   ($note)');
  }
  b.writeln('------------------------------');
  b.writeln('Subtotal (excl. VAT): ${money(r.subtotal)}');
  b.writeln('VAT ${vatRate().toStringAsFixed(vatRate() == vatRate().roundToDouble() ? 0 : 1)}%: ${money(r.vat)}');
  b.writeln('TOTAL: ${money(r.total)}');
  for (final p in r.payments) {
    b.writeln('Paid by ${_method(p['method'])}: ${money(n(p['amount']))}');
    if (p['method'] == 'cash' && n(p['tendered']) > 0) {
      b.writeln('Tendered ${money(n(p['tendered']))}, change ${money(n(p['change_given']))}');
    }
    if (p['method'] != 'cash' && '${p['card_last4'] ?? ''}'.isNotEmpty) {
      b.writeln('Card ending ${p['card_last4']}');
    }
  }
  if (r.refunded > 0) b.writeln('Refunded: ${money(r.refunded)}');
  final footer = '${c['receipt_footer'] ?? ''}'.trim();
  if (footer.isNotEmpty) {
    b.writeln('');
    b.writeln(footer);
  }
  return b.toString();
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
  pw.TextStyle t(double size, {bool bold = false, bool italic = false}) => pw.TextStyle(
      fontSize: size,
      fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      fontStyle: italic ? pw.FontStyle.italic : pw.FontStyle.normal);
  pw.Widget center(String s, pw.TextStyle st) =>
      pw.SizedBox(width: double.infinity, child: pw.Text(s, style: st, textAlign: pw.TextAlign.center));
  pw.Widget row(String l, String rr, {bool bold = false, double size = 9}) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(child: pw.Text(l, style: t(size, bold: bold))),
            pw.SizedBox(width: 6),
            pw.Text(rr, style: t(size, bold: bold)),
          ]);
  final divider = pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 5),
      child: pw.Divider(thickness: 0.6, height: 1));

  final doc = pw.Document(title: 'Receipt ${r.ref}', author: r.companyName);
  doc.addPage(pw.Page(
    pageFormat: slipFormat(),
    build: (ctx) {
      final vatNo = '${c['vat_number'] ?? ''}'.trim();
      final footer = '${c['receipt_footer'] ?? ''}'.trim();
      return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        if (logo != null)
          pw.Center(child: pw.Image(logo, width: 46, height: 46, fit: pw.BoxFit.contain)),
        if (logo != null) pw.SizedBox(height: 4),
        center(r.companyName, t(13, bold: true)),
        for (final k in ['address', 'phone', 'email'])
          if ('${c[k] ?? ''}'.trim().isNotEmpty)
            center(k == 'phone' ? 'Tel ${c[k]}' : '${c[k]}', t(8)),
        if (vatNo.isNotEmpty) center('VAT no. $vatNo', t(8)),
        divider,
        center('RECEIPT #${r.ref}', t(11, bold: true)),
        center(_when.format(r.when), t(8)),
        if (r.typeText.isNotEmpty) center(r.typeText, t(8)),
        if (r.cancelled) center('CANCELLED', t(11, bold: true)),
        if (!r.paid) center('NOT PAID', t(11, bold: true)),
        divider,
        for (final i in r.items) ...[
          row('${i['qty']} x ${i['name']}', _lineTotal(i)),
          if ('${i['notes'] ?? ''}'.trim().isNotEmpty)
            pw.Padding(
                padding: const pw.EdgeInsets.only(left: 8, bottom: 2),
                child: pw.Text('${i['notes']}'.trim(), style: t(8, italic: true))),
          pw.SizedBox(height: 2),
        ],
        divider,
        row('Subtotal (excl. VAT)', money(r.subtotal), size: 8),
        row('VAT ${vatRate().toStringAsFixed(vatRate() == vatRate().roundToDouble() ? 0 : 1)}%', money(r.vat), size: 8),
        pw.SizedBox(height: 3),
        row('TOTAL', money(r.total), bold: true, size: 12),
        pw.SizedBox(height: 4),
        for (final p in r.payments) ...[
          row('Paid by ${_method(p['method'])}', money(n(p['amount'])), size: 8),
          if (p['method'] == 'cash' && n(p['tendered']) > 0) ...[
            row('Tendered', money(n(p['tendered'])), size: 8),
            row('Change', money(n(p['change_given'])), size: 8),
          ],
          if (p['method'] != 'cash' && '${p['card_last4'] ?? ''}'.isNotEmpty)
            row('Card ending', '${p['card_last4']}', size: 8),
        ],
        if (r.refunded > 0) row('Refunded', money(r.refunded), bold: true, size: 8),
        if (footer.isNotEmpty) ...[pw.SizedBox(height: 8), center(footer, t(8))],
        pw.SizedBox(height: 6),
      ]);
    },
  ));
  return doc.save();
}

Future<void> printSlip(ReceiptData r) async {
  await Printing.layoutPdf(
    name: 'Receipt-${r.ref}',
    format: slipFormat(),
    dynamicLayout: false,
    usePrinterSettings: false,
    onLayout: (_) => receiptPdf(r),
  );
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
Future<void> showReceiptDialog(BuildContext context, String orderId) async {
  await showDialog<void>(context: context, builder: (_) => _ReceiptDialog(orderId: orderId));
}

class _ReceiptDialog extends StatefulWidget {
  const _ReceiptDialog({required this.orderId});
  final String orderId;

  @override
  State<_ReceiptDialog> createState() => _ReceiptDialogState();
}

class _ReceiptDialogState extends State<_ReceiptDialog> {
  double _refunded = 0;

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
          .select('amount')
          .eq('order_id', widget.orderId);
      final sum = rows.fold<double>(0, (s, e) => s + n(e['amount']).toDouble());
      if (mounted) setState(() => _refunded = sum);
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
    final remaining = r.total - _refunded;
    if (remaining <= 0) {
      _say('This order has already been fully refunded.');
      return;
    }
    final amount = TextEditingController(text: remaining.toStringAsFixed(2));
    final reason = TextEditingController();
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
              Text('Order total ${money(r.total)}${_refunded > 0 ? ', already refunded ${money(_refunded)}' : ''}. Refundable: ${money(remaining)}'),
              const SizedBox(height: 12),
              TextField(
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => set(() {}),
                  decoration: const InputDecoration(labelText: 'Refund amount', prefixText: 'R')),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'cash', label: Text('Cash back')),
                  ButtonSegment(value: 'card_manual', label: Text('Back to card')),
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
      _say('Refund recorded.');
      await SyncService.instance.syncNow();
    } on PostgrestException catch (e) {
      _say(e.message);
    } catch (_) {
      _say('Refunds need an internet connection.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = ReceiptData.forOrder(widget.orderId, refunded: _refunded);
    if (r == null) {
      return AlertDialog(
          content: const Text('This order is not stored on this device.'),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))]);
    }
    return AlertDialog(
      title: Text('Receipt #${r.ref}'),
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
          if (_canRefund && r.paid)
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
    final c = r.company;
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.35);
    Widget line(String l, String rr, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(l, style: mono.copyWith(fontWeight: bold ? FontWeight.w800 : null))),
            Text(rr, style: mono.copyWith(fontWeight: bold ? FontWeight.w800 : null)),
          ]),
        );
    Widget center(String s, {bool bold = false, double size = 13}) => SizedBox(
        width: double.infinity,
        child: Text(s,
            textAlign: TextAlign.center,
            style: mono.copyWith(fontWeight: bold ? FontWeight.w800 : null, fontSize: size)));
    const dash = Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Divider(height: 1, thickness: 1));
    final logo = '${c['logo_url'] ?? ''}';
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
        center(r.companyName, bold: true, size: 16),
        for (final k in ['address', 'phone', 'email'])
          if ('${c[k] ?? ''}'.trim().isNotEmpty) center(k == 'phone' ? 'Tel ${c[k]}' : '${c[k]}', size: 11),
        if ('${c['vat_number'] ?? ''}'.trim().isNotEmpty) center('VAT no. ${c['vat_number']}', size: 11),
        dash,
        center('RECEIPT #${r.ref}', bold: true),
        center(_when.format(r.when), size: 11),
        if (r.typeText.isNotEmpty) center(r.typeText, size: 11),
        if (r.cancelled) center('CANCELLED', bold: true, size: 15),
        if (!r.paid) center('NOT PAID', bold: true, size: 15),
        dash,
        for (final i in r.items) ...[
          line('${i['qty']} x ${i['name']}', _lineTotal(i)),
          if ('${i['notes'] ?? ''}'.trim().isNotEmpty)
            Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: Text('${i['notes']}'.trim(), style: mono.copyWith(fontSize: 11, fontStyle: FontStyle.italic)))),
        ],
        dash,
        line('Subtotal (excl. VAT)', money(r.subtotal)),
        line('VAT ${vatRate().toStringAsFixed(vatRate() == vatRate().roundToDouble() ? 0 : 1)}%', money(r.vat)),
        line('TOTAL', money(r.total), bold: true),
        const SizedBox(height: 6),
        for (final p in r.payments) ...[
          line('Paid by ${_method(p['method'])}', money(n(p['amount']))),
          if (p['method'] == 'cash' && n(p['tendered']) > 0) ...[
            line('Tendered', money(n(p['tendered']))),
            line('Change', money(n(p['change_given']))),
          ],
          if (p['method'] != 'cash' && '${p['card_last4'] ?? ''}'.isNotEmpty)
            line('Card ending', '${p['card_last4']}'),
        ],
        if (r.refunded > 0) line('Refunded', money(r.refunded), bold: true),
        if ('${c['receipt_footer'] ?? ''}'.trim().isNotEmpty) ...[
          const SizedBox(height: 10),
          center('${c['receipt_footer']}', size: 11),
        ],
      ]),
    );
  }
}
