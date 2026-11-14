import 'dart:math';

import 'package:flutter/material.dart';

import '../auth/permissions.dart';

import '../data/accounts_repo.dart';
import '../data/repo.dart';
import '../data/sync_service.dart';
import '../theme.dart';
import 'account_picker.dart';

/// Payment window: cash, card or both on one screen, with an optional tip.
///
/// [due] is what is still owed. Returns the payments taken (one or two), which
/// may cover only part of it, or null if cancelled.
Future<List<Map<String, dynamic>>?> showPaymentDialog(BuildContext context, double due,
    {double alreadyPaid = 0}) {
  return showDialog<List<Map<String, dynamic>>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PaymentDialog(due: due, alreadyPaid: alreadyPaid),
  );
}

/// Takes payments until [total] is covered. Returns the payments taken (possibly
/// fewer than needed if the cashier stopped part-way), or null if none.
Future<List<Map<String, dynamic>>?> collectPayments(BuildContext context, double total) async {
  final taken = <Map<String, dynamic>>[];
  var balance = round2(total);
  while (balance > 0.005) {
    final paid = taken.fold<double>(0, (s, p) => s + n(p['amount']).toDouble());
    final got = await showPaymentDialog(context, balance, alreadyPaid: paid);
    if (!context.mounted) return taken.isEmpty ? null : taken;
    if (got == null) {
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
    taken.addAll(got);
    balance = round2(balance - got.fold<double>(0, (s, p) => s + n(p['amount']).toDouble()));
  }
  return taken;
}

class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog({required this.due, required this.alreadyPaid});
  final double due;
  final double alreadyPaid;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  late bool _cashOk;
  late bool _cardOk;
  late bool _eftOk;
  late bool _eftOffline;
  late String _eftDetails;
  final _cash = TextEditingController();
  final _card = TextEditingController();
  final _eft = TextEditingController();
  final _eftRef = TextEditingController();
  final _tip = TextEditingController();
  bool _showTip = false;

  @override
  void initState() {
    super.initState();
    final c = companyRow();
    _cashOk = c?['accept_cash'] != false;
    _cardOk = c?['accept_card_manual'] != false;
    // EFT needs the internet so the payment can be checked by the server before the slip is printed.
    _eftOk = c?['accept_eft'] == true && Perms.canTakeEft && SyncService.instance.online;
    _eftOffline = c?['accept_eft'] == true && Perms.canTakeEft && !SyncService.instance.online;
    _eftDetails = '${c?['eft_details'] ?? ''}'.trim();
    if (!_cashOk && !_cardOk && !_eftOk) _cashOk = true;
  }

  @override
  void dispose() {
    _cash.dispose();
    _card.dispose();
    _eft.dispose();
    _eftRef.dispose();
    _tip.dispose();
    super.dispose();
  }

  double _num(TextEditingController c) => double.tryParse(c.text.trim().replaceAll(',', '.')) ?? 0;
  double get _tipValue => _num(_tip) < 0 ? 0 : round2(_num(_tip));
  TenderResult get _result =>
      splitTender(
          due: widget.due,
          cash: _num(_cash),
          card: _num(_card),
          eft: _num(_eft),
          eftReference: _eftRef.text,
          tip: _tipValue);

  /// What cash covers of the bill, used to work out "balance on card".
  double get _cashPart => splitTender(due: widget.due, cash: _num(_cash), tip: _num(_card) > 0 ? 0 : _tipValue)
      .payments
      .fold<double>(0, (s, p) => s + n(p['amount']).toDouble());

  void _setCash(double v) => setState(() => _cash.text = v.toStringAsFixed(2));
  void _setCard(double v) => setState(() => _card.text = v <= 0 ? '' : v.toStringAsFixed(2));
  void _setEft(double v) => setState(() => _eft.text = v <= 0 ? '' : v.toStringAsFixed(2));

  List<double> _notes() {
    final d = widget.due;
    final set = <double>{
      (d / 10).ceil() * 10.0,
      (d / 50).ceil() * 50.0,
      (d / 100).ceil() * 100.0,
      (d / 200).ceil() * 200.0,
    };
    return set.where((v) => v > d).toList()..sort();
  }

  /// One person's share goes into the box being used; the next person pays on the next screen.
  void _splitEvenly(int people) {
    final share = (widget.due / people * 100).ceil() / 100;
    final v = share > widget.due ? widget.due : share;
    if (_cardOk && (!_cashOk || (_num(_card) > 0 && _num(_cash) <= 0))) {
      _cash.clear();
      _setCard(v);
    } else {
      _card.clear();
      _setCash(v);
    }
    _eft.clear();
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    final cashOnCard = round2(widget.due - _cashPart - _num(_eft)); // balance a card would need to cover
    final nothing = r.payments.isEmpty && r.error == null;
    final part = !nothing && r.error == null && r.remaining > 0.005;

    Widget amountField(TextEditingController c, String label, {bool focus = false}) => TextField(
          controller: c,
          autofocus: focus,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setState(() {}),
          onTap: () => c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length),
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          decoration: InputDecoration(labelText: label, prefixText: 'R ', hintText: '0.00', isDense: true),
        );

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
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('Already paid ${money(widget.alreadyPaid)}',
                      style: const TextStyle(color: Brand.muted, fontWeight: FontWeight.w600)),
                ),
              // Result first, so it is always in view.
              if (r.error != null)
                _box(const Color(0xFFFDE7EA), Brand.red, r.error!, null)
              else if (nothing)
                _box(const Color(0xFFF0F3FA), Brand.navy, 'Enter cash, card, EFT or a mix', null)
              else if (part)
                _box(const Color(0xFFFFF4D6), const Color(0xFF7A4B00), 'Balance still to pay', money(r.remaining))
              else if (r.change > 0)
                _box(const Color(0xFFE3F3EA), const Color(0xFF0F5733), 'Change to give', money(r.change))
              else
                _box(const Color(0xFFE3F3EA), const Color(0xFF0F5733), 'Paid in full', 'No change'),
              const SizedBox(height: 12),
              if (_cashOk) ...[
                amountField(_cash, 'Cash received', focus: true),
                const SizedBox(height: 6),
                Wrap(spacing: 8, runSpacing: 6, children: [
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 38)),
                    onPressed: () {
                      _card.clear();
                      _eft.clear();
                      _setCash(widget.due + _tipValue);
                    },
                    child: const Text('Exact cash'),
                  ),
                  for (final v in _notes())
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 38)),
                      onPressed: () {
                        _card.clear();
                        _eft.clear();
                        _setCash(v);
                      },
                      child: Text('R${v.toStringAsFixed(0)}'),
                    ),
                ]),
                const SizedBox(height: 12),
              ],
              if (_cardOk) ...[
                amountField(_card, 'Card amount', focus: !_cashOk),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 38)),
                    onPressed: cashOnCard <= 0.005
                        ? null
                        : () {
                            // Cash above the bill cannot be mixed with card.
                            if (_num(_cash) > widget.due) _cash.clear();
                            _setCard(round2(widget.due - _num(_eft) - (_num(_cash) > widget.due ? 0 : _cashPart)));
                          },
                    child: Text(_cashPart > 0 && cashOnCard > 0.005
                        ? 'Balance ${money(cashOnCard)} on card'
                        : 'Full amount on card'),
                  ),
                ),
                if (_num(_card) > 0 && _tipValue > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('Charge ${money(_num(_card) + _tipValue)} on the card machine (includes the tip).',
                        style: const TextStyle(fontWeight: FontWeight.w700, color: Brand.navy)),
                  ),
              ],
              if (_eftOffline)
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text('EFT needs the internet. Take cash or card, or wait until the till is back online.',
                      style: TextStyle(color: Brand.muted, fontSize: 12)),
                ),
              if (_eftOk) ...[
                const SizedBox(height: 12),
                amountField(_eft, 'EFT / bank transfer amount', focus: !_cashOk && !_cardOk),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 38)),
                    onPressed: () {
                      final taken = round2(_cashPart + _num(_card));
                      _setEft(round2(max(0, widget.due - (_num(_cash) > widget.due ? 0 : taken))));
                      if (_num(_cash) > widget.due) _cash.clear();
                    },
                    child: Text(_cashPart + _num(_card) > 0.005 && widget.due - _cashPart - _num(_card) > 0.005
                        ? 'Balance ${money(round2(widget.due - _cashPart - _num(_card)))} by EFT'
                        : 'Full amount by EFT'),
                  ),
                ),
                if (_num(_eft) > 0) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _eftRef,
                    onChanged: (_) => setState(() {}),
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                        labelText: 'Bank reference (required)',
                        isDense: true,
                        helperText: 'The reference or name shown on the proof of payment'),
                  ),
                  if (_eftDetails.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('Banking details to give the customer:\n$_eftDetails',
                          style: const TextStyle(fontSize: 12, color: Brand.muted)),
                    ),
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('Only record this once the money has reached the account (check the proof of payment or the banking app).',
                        style: TextStyle(fontSize: 12, color: Brand.muted)),
                  ),
                ],
              ],
              const SizedBox(height: 4),
              Row(children: [
                if (!_showTip)
                  TextButton.icon(
                      onPressed: () => setState(() => _showTip = true),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add a tip')),
                if (AccountsRepo.enabled && Perms.canAccountSale && widget.due > 0.005)
                  TextButton.icon(
                      onPressed: () async {
                        final a = await pickAccountPayment(context, widget.due);
                        if (a != null && context.mounted) Navigator.pop(context, [a]);
                      },
                      icon: const Icon(Icons.account_balance_wallet_outlined, size: 16),
                      label: const Text('On account')),
                const Spacer(),
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
              ]),
              if (_showTip)
                TextField(
                  controller: _tip,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                      labelText: 'Tip',
                      prefixText: 'R ',
                      isDense: true,
                      helperText: 'Goes on the card if a card is used, otherwise it comes out of the cash'),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: r.error != null || r.payments.isEmpty ? null : () => Navigator.pop(context, r.payments),
          child: Text(part ? 'Take this, then pay ${money(r.remaining)}' : 'Record payment'),
        ),
      ],
    );
  }

  Widget _box(Color bg, Color fg, String label, String? value) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
        child: Row(
          children: [
            Expanded(child: Text(label, style: TextStyle(fontWeight: FontWeight.w700, color: fg))),
            if (value != null)
              Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: fg)),
          ],
        ),
      );
}
