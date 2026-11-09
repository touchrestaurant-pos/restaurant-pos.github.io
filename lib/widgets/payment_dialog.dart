import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/repo.dart';
import '../theme.dart';

/// Cash (amount tendered and change) or manual credit card (card type, last 4
/// digits, slip number). Returns the payment to save, or null if cancelled.
Future<Map<String, dynamic>?> showPaymentDialog(
    BuildContext context, double due) {
  return showDialog<Map<String, dynamic>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PaymentDialog(due: due),
  );
}

class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog({required this.due});
  final double due;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  late bool _cashOk;
  late bool _cardOk;
  late String _method;
  late final TextEditingController _tendered;
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
    _tendered = TextEditingController(text: widget.due.toStringAsFixed(2));
  }

  @override
  void dispose() {
    _tendered.dispose();
    _last4.dispose();
    _slip.dispose();
    super.dispose();
  }

  double get _tenderedValue => double.tryParse(_tendered.text.replaceAll(',', '.')) ?? 0;
  double get _change => max(0, round2(_tenderedValue - widget.due));

  bool get _valid {
    if (_method == 'cash') return _tenderedValue + 0.001 >= widget.due;
    return _last4.text.length == 4 && _slip.text.trim().isNotEmpty;
  }

  void _confirm() {
    if (_method == 'cash') {
      Navigator.pop(context, {
        'method': 'cash',
        'amount': widget.due,
        'tendered': round2(_tenderedValue),
        'change_given': _change,
      });
    } else {
      Navigator.pop(context, {
        'method': 'card_manual',
        'amount': widget.due,
        'card_brand': _brand,
        'card_last4': _last4.text,
        'slip_no': _slip.text.trim(),
      });
    }
  }

  List<double> _quick() {
    final d = widget.due;
    final set = <double>{
      (d / 10).ceil() * 10.0,
      (d / 50).ceil() * 50.0,
      (d / 100).ceil() * 100.0,
      (d / 200).ceil() * 200.0,
    };
    return set.where((v) => v > d).toList()..sort();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('Payment', style: TextStyle(fontWeight: FontWeight.w800)),
          Text(money(widget.due),
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 26)),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<String>(
                segments: [
                  if (_cashOk)
                    const ButtonSegment(value: 'cash', label: Text('Cash')),
                  if (_cardOk)
                    const ButtonSegment(
                        value: 'card_manual', label: Text('Credit card (manual)')),
                ],
                selected: {_method},
                onSelectionChanged: (s) => setState(() => _method = s.first),
              ),
              const SizedBox(height: 16),
              if (_method == 'cash') ...[
                TextField(
                  controller: _tendered,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                  decoration: const InputDecoration(
                      labelText: 'Amount tendered', prefixText: 'R '),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: () => setState(
                          () => _tendered.text = widget.due.toStringAsFixed(2)),
                      child: const Text('Exact'),
                    ),
                    for (final v in _quick())
                      OutlinedButton(
                        onPressed: () =>
                            setState(() => _tendered.text = v.toStringAsFixed(2)),
                        child: Text('R${v.toStringAsFixed(0)}'),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE3F3EA),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Change due',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, color: Color(0xFF0F5733))),
                      Text(money(_change),
                          style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF0F5733))),
                    ],
                  ),
                ),
              ] else ...[
                const Text(
                    'Take the payment on your card machine first, then record it here.',
                    style: TextStyle(color: Brand.muted)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final b in ['Visa', 'Mastercard', 'Other'])
                      ChoiceChip(
                        label: Text(b),
                        selected: _brand == b,
                        onSelected: (_) => setState(() => _brand = b),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _last4,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                      labelText: 'Last 4 digits of the card', counterText: ''),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _slip,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                      labelText: 'Slip / approval number'),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _valid ? _confirm : null,
          child: Text(_method == 'cash' ? 'Record cash payment' : 'Record card payment'),
        ),
      ],
    );
  }
}
