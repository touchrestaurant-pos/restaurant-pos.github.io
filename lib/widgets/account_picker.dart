import 'package:flutter/material.dart';

import '../data/accounts_repo.dart';
import '../data/repo.dart';
import '../theme.dart';

/// Lets the cashier put (part of) a bill on a customer account.
/// Returns a payment map for the order, or null if cancelled.
Future<Map<String, dynamic>?> pickAccountPayment(BuildContext context, double due) =>
    showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AccountPicker(due: due),
    );

class _AccountPicker extends StatefulWidget {
  const _AccountPicker({required this.due});
  final double due;

  @override
  State<_AccountPicker> createState() => _AccountPickerState();
}

class _AccountPickerState extends State<_AccountPicker> {
  List<Map<String, dynamic>>? _accounts;
  String? _error;
  Map<String, dynamic>? _picked;
  final _amount = TextEditingController();
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _amount.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _accounts = null;
    });
    try {
      final a = await AccountsRepo.tillAccounts();
      if (mounted) setState(() => _accounts = a);
    } catch (e) {
      if (mounted) setState(() => _error = AccountsRepo.message(e));
    }
  }

  double get _max {
    final a = _picked;
    if (a == null) return 0;
    final avail = n(a['available']).toDouble();
    return round2(avail < widget.due ? avail : widget.due);
  }

  double get _value => double.tryParse(_amount.text.trim().replaceAll(',', '.')) ?? 0;

  String? get _problem {
    if (_picked == null) return null;
    final v = round2(_value);
    if (v <= 0) return 'Enter the amount to put on the account';
    if (v > widget.due + 0.005) return 'That is more than the bill (${money(widget.due)})';
    if (v > _max + 0.005) return 'That is more than this account can still be charged (${money(_max)})';
    return null;
  }

  void _choose(Map<String, dynamic> a) {
    final avail = n(a['available']).toDouble();
    final m = round2(avail < widget.due ? avail : widget.due);
    setState(() {
      _picked = a;
      _amount.text = m.toStringAsFixed(2);
    });
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    final list = (_accounts ?? const <Map<String, dynamic>>[])
        .where((a) => q.isEmpty || '${a['name']} ${a['account_no']}'.toLowerCase().contains(q))
        .toList();
    final picked = _picked;

    Widget body;
    if (_error != null) {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        Text(_error!, style: const TextStyle(color: Brand.red, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: _load, child: const Text('Try again')),
      ]);
    } else if (_accounts == null) {
      body = const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    } else if (picked == null) {
      body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: _search,
          autofocus: true,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search name or account number', isDense: true),
        ),
        const SizedBox(height: 8),
        if (list.isEmpty)
          const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No accounts to show. An admin makes accounts available to the till.'))
        else
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final a in list)
                ListTile(
                  enabled: a['can_charge'] == true,
                  title: Text('${a['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(a['can_charge'] == true
                      ? '${a['account_no']} · available ${money(n(a['available']))}${n(a['available']) + 0.005 < widget.due ? ' · LIMIT TOO LOW FOR THIS BILL' : ''}'
                      : '${a['account_no']} · ${a['reason'] ?? 'Cannot be charged'}'),
                  trailing: a['can_charge'] == true ? const Icon(Icons.chevron_right) : const Icon(Icons.block, color: Brand.red),
                  onTap: a['can_charge'] == true ? () => _choose(a) : null,
                ),
            ]),
          ),
      ]);
    } else {
      body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: const Color(0xFFF0F3FA), borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${picked['name']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                Text('${picked['account_no']} · can still be charged ${money(n(picked['available']))}',
                    style: const TextStyle(color: Brand.muted)),
              ]),
            ),
            TextButton(onPressed: () => setState(() => _picked = null), child: const Text('Change')),
          ]),
        ),
        if (n(picked['available']) + 0.005 < widget.due) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFFFDE7EA), borderRadius: BorderRadius.circular(12), border: Border.all(color: Brand.red)),
            child: Text(
                'Over the account limit. This bill is ${money(widget.due)} but ${picked['name']} can only be charged ${money(n(picked['available']))} more. '
                'Do NOT process this whole order on account. Ask the customer to pay the rest another way, or call the manager.',
                style: const TextStyle(color: Brand.red, fontWeight: FontWeight.w800)),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _amount,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setState(() {}),
          onTap: () => _amount.selection = TextSelection(baseOffset: 0, extentOffset: _amount.text.length),
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          decoration: InputDecoration(
              labelText: 'Amount on account', prefixText: 'R ', isDense: true, errorText: _problem),
        ),
        const SizedBox(height: 8),
        const Text(
            'The customer owes this amount and will be sent a statement. The account balance is updated as soon as the sale is saved.',
            style: TextStyle(color: Brand.muted, fontSize: 12)),
      ]);
    }

    return AlertDialog(
      title: Text('On account · ${money(widget.due)}', style: const TextStyle(fontWeight: FontWeight.w800)),
      content: SizedBox(width: 440, child: body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        if (picked != null)
          FilledButton(
            onPressed: _problem != null
                ? null
                : () => Navigator.pop(context, {
                      'method': 'account',
                      'amount': round2(_value),
                      'tip': 0,
                      'account_id': picked['id'],
                      'account_no': picked['account_no'],
                      'account_name': picked['name'],
                      'account_vat_no': picked['vat_no'],
                      'account_address': picked['billing_address'],
                    }),
            child: const Text('Charge to account'),
          ),
      ],
    );
  }
}
