import 'dart:math';

import 'package:flutter/material.dart';

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

  /// Cash: what the customer hands over. Card: what goes on the card.
  /// Less than what is owed = part payment; more (cash only) = change.
  late final TextEditingController _amount;
  final _tip = TextEditingController();

  @override
  void initState() {
    super.initState();
    final c = companyRow();
    _cashOk = c?['accept_cash'] != false;
    _cardOk = c?['accept_card_manual'] != false;
    if (!_cashOk && !_cardOk) _cashOk = true;
    _method = _cashOk ? 'cash' : 'card_manual';
    _amount = TextEditingController(text: widget.due.toStringAsFixed(2));
  }

  @override
  void dispose() {
    _amount.dispose();
    _tip.dispose();
    super.dispose();
  }

  double _num(TextEditingController c) => double.tryParse(c.text.replaceAll(',', '.')) ?? 0;
  bool get _cash => _method == 'cash';
  double get _entered => round2(max(0, _num(_amount)));
  double get _tipValue => round2(max(0, _num(_tip)));

  /// How much of the bill this payment covers.
  double get _applied =>
      round2(max(0, min(widget.due, _cash ? _entered - _tipValue : _entered)));
  double get _change => _cash ? round2(max(0, _entered - _tipValue - widget.due)) : 0;
  double get _remaining => round2(max(0, widget.due - _applied));
  bool get _valid => _applied > 0;

  void _confirm() {
    final base = {'method': _method, 'amount': _applied, 'tip': _tipValue};
    if (_cash) {
      Navigator.pop(context, {...base, 'tendered': _entered, 'change_given': _change});
    } else {
      Navigator.pop(context, base);
    }
  }

  List<double> _quick() {
    final d = widget.due + _tipValue;
    final set = <double>{
      (d / 10).ceil() * 10.0,
      (d / 50).ceil() * 50.0,
      (d / 100).ceil() * 100.0,
      (d / 200).ceil() * 200.0,
    };
    return set.where((v) => v > d).toList()..sort();
  }

  void _set(double v) => setState(() => _amount.text = v.toStringAsFixed(2));

  void _splitEvenly(int people) {
    final share = (widget.due / people * 100).ceil() / 100;
    _set(min(share, widget.due) + (_cash ? _tipValue : 0));
  }

  @override
  Widget build(BuildContext context) {
    final part = _remaining > 0.005;
    return AlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(widget.alreadyPaid > 0 ? 'Still to pay' : 'To pay',
              style: const TextStyle(fontWeight: FontWeight.w800)),
          Text(money(widget.due), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 26)),
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
                  child: Text('Already paid ${money(widget.alreadyPaid)}',
                      style: const TextStyle(color: Brand.muted, fontWeight: FontWeight.w600)),
                ),
              SegmentedButton<String>(
                segments: [
                  if (_cashOk) const ButtonSegment(value: 'cash', label: Text('Cash')),
                  if (_cardOk) const ButtonSegment(value: 'card_manual', label: Text('Card')),
                ],
                selected: {_method},
                onSelectionChanged: (s) => setState(() {
                  _method = s.first;
                  // A card can never be charged more than what is owed.
                  if (!_cash && _entered > widget.due) _amount.text = widget.due.toStringAsFixed(2);
                }),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _amount,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                onTap: () => _amount.selection = TextSelection(baseOffset: 0, extentOffset: _amount.text.length),
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                decoration: InputDecoration(
                    labelText: _cash ? 'Cash received from customer' : 'Amount on card',
                    prefixText: 'R ',
                    helperText: 'Enter less than ${money(widget.due)} to pay part now and the rest another way'),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton(
                    onPressed: () => _set(widget.due + (_cash ? _tipValue : 0)),
                    child: Text(_cash ? 'Exact' : 'Full amount'),
                  ),
                  if (_cash)
                    for (final v in _quick())
                      OutlinedButton(onPressed: () => _set(v), child: Text('R${v.toStringAsFixed(0)}')),
                  PopupMenuButton<int>(
                    tooltip: 'Split evenly',
                    onSelected: _splitEvenly,
                    itemBuilder: (_) => [
                      for (final p in [2, 3, 4, 5, 6]) PopupMenuItem(value: p, child: Text('Split between $p people')),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      child: Text('Split evenly ▾', style: TextStyle(fontWeight: FontWeight.w700, color: Brand.navy)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _tip,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                    labelText: 'Tip (optional)',
                    prefixText: 'R ',
                    isDense: true,
                    helperText: _cash ? 'Kept out of the cash received' : 'Added on top of the card amount'),
              ),
              const SizedBox(height: 14),
              if (!_cash)
                _box(const Color(0xFFE8EEFB), Brand.navy, 'Charge on card machine', money(_applied + _tipValue)),
              if (_cash && !part) _box(const Color(0xFFE3F3EA), const Color(0xFF0F5733), 'Change to give', money(_change)),
              if (part) ...[
                if (!_cash) const SizedBox(height: 8),
                _box(const Color(0xFFFFF4D6), const Color(0xFF7A4B00), 'Left to pay after this', money(_remaining)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _valid ? _confirm : null,
          child: Text(part
              ? 'Take ${money(_applied)} ${_cash ? 'cash' : 'card'}, then the rest'
              : (_cash ? 'Record cash payment' : 'Record card payment')),
        ),
      ],
    );
  }

  Widget _box(Color bg, Color fg, String label, String value) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: TextStyle(fontWeight: FontWeight.w700, color: fg)),
            Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: fg)),
          ],
        ),
      );
}
