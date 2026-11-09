import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/repo.dart';
import '../theme.dart';

/// One payment: cash (amount tendered and change) or manual credit card (card
/// type, last 4 digits, slip number), with an optional tip.
///
/// [due] is what is still owed. With "Split bill" the cashier can take part of it
/// now; the till then asks for the next payment. Returns null if cancelled.
Future<Map<String, dynamic>?> showPaymentDialog(BuildContext context, double due,
    {double alreadyPaid = 0, int paymentNo = 1}) {
  return showDialog<Map<String, dynamic>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PaymentDialog(due: due, alreadyPaid: alreadyPaid, paymentNo: paymentNo),
  );
}

/// Takes payments until [total] is covered. Returns the payments taken (possibly
/// fewer than needed if the cashier stopped part-way), or null if none.
Future<List<Map<String, dynamic>>?> collectPayments(BuildContext context, double total) async {
  final taken = <Map<String, dynamic>>[];
  var balance = round2(total);
  while (balance > 0.005) {
    final paid = taken.fold<double>(0, (s, p) => s + n(p['amount']).toDouble());
    final p = await showPaymentDialog(context, balance, alreadyPaid: paid, paymentNo: taken.length + 1);
    if (!context.mounted) return taken.isEmpty ? null : taken;
    if (p == null) {
      if (taken.isEmpty) return null;
      final keep = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Stop taking payment?'),
          content: Text(
              '${money(paid)} has been taken. The order will be sent with ${money(balance)} still to pay, and you can take the rest under Open orders.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Take the rest now')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send with balance due')),
          ],
        ),
      );
      if (keep == true) return taken;
      continue;
    }
    taken.add(p);
    balance = round2(balance - n(p['amount']).toDouble());
  }
  return taken;
}

class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog({required this.due, required this.alreadyPaid, required this.paymentNo});
  final double due;
  final double alreadyPaid;
  final int paymentNo;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  late bool _cashOk;
  late bool _cardOk;
  late String _method;
  bool _split = false;
  late final TextEditingController _amount;
  late final TextEditingController _tendered;
  final _tip = TextEditingController();
  final _last4 = TextEditingController();
  final _slip = TextEditingController();
  String _brand = 'Visa';

  @override
  void initState() {
    super.initState();
    final c = companyRow();
    _cashOk = c?['accept_cash'] != false;
    _cardOk = c?['accept_card_manual'] != false;
    if (!_cashOk && !_cardOk) _cashOk = true;
    _method = _cashOk ? 'cash' : 'card_manual';
    _amount = TextEditingController(text: widget.due.toStringAsFixed(2));
    _tendered = TextEditingController(text: widget.due.toStringAsFixed(2));
  }

  @override
  void dispose() {
    _amount.dispose();
    _tendered.dispose();
    _tip.dispose();
    _last4.dispose();
    _slip.dispose();
    super.dispose();
  }

  double _num(TextEditingController c) => double.tryParse(c.text.replaceAll(',', '.')) ?? 0;
  double get _payAmount => _split ? round2(min(_num(_amount), widget.due)) : widget.due;
  double get _tipValue => round2(max(0, _num(_tip)));
  double get _change => max(0, round2(_num(_tendered) - _payAmount - _tipValue));

  bool get _valid {
    if (_payAmount <= 0) return false;
    if (_method == 'cash') return _num(_tendered) + 0.001 >= _payAmount + _tipValue;
    return _last4.text.length == 4 && _slip.text.trim().isNotEmpty;
  }

  void _confirm() {
    final base = {'method': _method, 'amount': _payAmount, 'tip': _tipValue};
    if (_method == 'cash') {
      Navigator.pop(context, {
        ...base,
        'tendered': round2(_num(_tendered)),
        'change_given': _change,
      });
    } else {
      Navigator.pop(context, {
        ...base,
        'card_brand': _brand,
        'card_last4': _last4.text,
        'slip_no': _slip.text.trim(),
      });
    }
  }

  List<double> _quick() {
    final d = _payAmount + _tipValue;
    final set = <double>{
      (d / 10).ceil() * 10.0,
      (d / 50).ceil() * 50.0,
      (d / 100).ceil() * 100.0,
      (d / 200).ceil() * 200.0,
    };
    return set.where((v) => v > d).toList()..sort();
  }

  void _splitEvenly(int people) {
    final share = (widget.due / people * 100).ceil() / 100;
    setState(() {
      _split = true;
      _amount.text = min(share, widget.due).toStringAsFixed(2);
      _tendered.text = _amount.text;
    });
  }

  @override
  Widget build(BuildContext context) {
    final showDue = _payAmount + _tipValue;
    return AlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(widget.paymentNo > 1 ? 'Payment ${widget.paymentNo}' : 'Payment',
              style: const TextStyle(fontWeight: FontWeight.w800)),
          Text(money(showDue), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 26)),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.alreadyPaid > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text('Already paid ${money(widget.alreadyPaid)} · still owed ${money(widget.due)}',
                      style: const TextStyle(color: Brand.muted, fontWeight: FontWeight.w600)),
                ),
              SegmentedButton<String>(
                segments: [
                  if (_cashOk) const ButtonSegment(value: 'cash', label: Text('Cash')),
                  if (_cardOk) const ButtonSegment(value: 'card_manual', label: Text('Credit card (manual)')),
                ],
                selected: {_method},
                onSelectionChanged: (s) => setState(() => _method = s.first),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    value: _split,
                    onChanged: (v) => setState(() {
                      _split = v ?? false;
                      if (!_split) _amount.text = widget.due.toStringAsFixed(2);
                    }),
                    title: const Text('Split bill (pay part now)'),
                  ),
                ),
                PopupMenuButton<int>(
                  tooltip: 'Split evenly',
                  onSelected: _splitEvenly,
                  itemBuilder: (_) => [
                    for (final p in [2, 3, 4, 5, 6]) PopupMenuItem(value: p, child: Text('Split between $p')),
                  ],
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Text('Split evenly ▾', style: TextStyle(fontWeight: FontWeight.w700, color: Brand.navy)),
                  ),
                ),
              ]),
              if (_split)
                TextField(
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                      labelText: 'Amount for this payment', prefixText: 'R ', helperText: 'Up to ${money(widget.due)}'),
                ),
              const SizedBox(height: 10),
              TextField(
                controller: _tip,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'Tip (optional)', prefixText: 'R ', isDense: true),
              ),
              const SizedBox(height: 14),
              if (_method == 'cash') ...[
                TextField(
                  controller: _tendered,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                  decoration: const InputDecoration(labelText: 'Amount tendered', prefixText: 'R '),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: () => setState(() => _tendered.text = showDue.toStringAsFixed(2)),
                      child: const Text('Exact'),
                    ),
                    for (final v in _quick())
                      OutlinedButton(
                        onPressed: () => setState(() => _tendered.text = v.toStringAsFixed(2)),
                        child: Text('R${v.toStringAsFixed(0)}'),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: const Color(0xFFE3F3EA), borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Change due', style: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF0F5733))),
                      Text(money(_change),
                          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Color(0xFF0F5733))),
                    ],
                  ),
                ),
              ] else ...[
                const Text('Take the payment on your card machine first, then record it here.',
                    style: TextStyle(color: Brand.muted)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final b in ['Visa', 'Mastercard', 'Other'])
                      ChoiceChip(label: Text(b), selected: _brand == b, onSelected: (_) => setState(() => _brand = b)),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _last4,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(labelText: 'Last 4 digits of the card', counterText: ''),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _slip,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(labelText: 'Slip / approval number'),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _valid ? _confirm : null,
          child: Text(_method == 'cash' ? 'Record cash payment' : 'Record card payment'),
        ),
      ],
    );
  }
}
