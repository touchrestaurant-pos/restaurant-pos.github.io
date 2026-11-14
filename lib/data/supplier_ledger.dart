import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../receipt/ledger.dart';
import '../widgets/ledger_statement.dart';
import 'accounts_repo.dart';
import 'local_store.dart';
import 'repo.dart';
import 'app_db.dart';

String _d(DateTime x) => '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';

const _methodNames = {'eft': 'EFT payment', 'cash': 'Cash payment', 'card': 'Card payment', 'credit_note': 'Supplier credit note'};

/// What we owe one supplier between two dates: deliveries raise it, payments and credit notes lower it.
Future<Ledger> loadSupplierLedger(String supplierId, DateTime from, DateTime to) async {
  final db = Supabase.instance.client;
  final grvs = List<Map<String, dynamic>>.from(await db
      .from('grvs')
      .select('id, grv_no, received_on, delivery_note, total, status, created_at')
      .eq('supplier_id', supplierId)
      .inFilter('status', ['posted', 'reversed']));
  final pays = List<Map<String, dynamic>>.from(await db
      .from('supplier_payments')
      .select('id, grv_id, amount, method, paid_on, note, created_at')
      .eq('supplier_id', supplierId));
  final grvNo = {for (final g in grvs) g['id']: '${g['grv_no']}'};

  final entries = <Map<String, dynamic>>[
    for (final g in grvs)
      {
        'date': '${g['received_on']}',
        'at': '${g['created_at']}',
        'what': 'Delivery ${g['grv_no']}${'${g['delivery_note'] ?? ''}'.isEmpty ? '' : ' · ${g['delivery_note']}'}',
        'charge': g['status'] == 'posted' ? n(g['total']).toDouble() : 0.0,
        'paid': 0.0,
        'muted': g['status'] != 'posted',
        'tag': g['status'] == 'posted' ? '' : 'Reversed, not counted (R${n(g['total']).toStringAsFixed(2)})',
        'group': '',
      },
    for (final p in pays)
      {
        'date': '${p['paid_on']}',
        'at': '${p['created_at']}',
        'what': '${_methodNames[p['method']] ?? p['method']}'
            '${p['grv_id'] == null ? '' : ' · for ${grvNo[p['grv_id']] ?? 'a delivery'}'}${'${p['note'] ?? ''}'.isEmpty ? '' : ' · ${p['note']}'}',
        'charge': 0.0,
        'paid': n(p['amount']).toDouble(),
        'muted': false,
        'tag': '',
        'group': '${_methodNames[p['method']] ?? p['method']}'.replaceAll(' payment', ''),
      },
  ]..sort((a, b) {
      final c = '${a['date']}'.compareTo('${b['date']}');
      return c != 0 ? c : '${a['at']}'.compareTo('${b['at']}');
    });

  final f = _d(from), t = _d(to);
  var bal = 0.0, opening = 0.0;
  final lines = <LedgerLine>[];
  for (final e in entries) {
    bal = round2(bal + (e['charge'] as double) - (e['paid'] as double));
    final date = e['date'] as String;
    if (date.compareTo(f) < 0) {
      opening = bal;
    } else if (date.compareTo(t) <= 0) {
      lines.add(LedgerLine(
        date: date,
        what: e['what'] as String,
        charge: e['charge'] as double,
        paid: e['paid'] as double,
        balance: bal,
        group: e['group'] as String,
        muted: e['muted'] as bool,
        tag: e['tag'] as String,
      ));
    }
  }
  final closing = lines.isEmpty ? opening : lines.last.balance;
  final s = LocalStore.row('suppliers', supplierId) ?? const {};
  String v(String k) => '${s[k] ?? ''}'.trim();
  return Ledger(
    partyName: v('name').isEmpty ? 'Supplier' : v('name'),
    from: f,
    to: t,
    opening: opening,
    closing: closing,
    lines: lines,
    partyInfo: [
      if (v('address').isNotEmpty) v('address'),
      if (v('vat_no').isNotEmpty) 'Supplier VAT no: ${v('vat_no')}',
      if (v('contact_person').isNotEmpty || v('phone').isNotEmpty) [v('contact_person'), v('phone')].where((e) => e.isNotEmpty).join(' · '),
    ],
    metaRight: [
      if (v('account_ref').isNotEmpty) 'Our account ${v('account_ref')}',
      if (v('terms_days').isNotEmpty) 'Terms ${v('terms_days')} days',
    ],
    title: 'Supplier statement',
    chargeLabel: 'Bought',
    paidLabel: 'Paid and credited',
    owedWord: 'we owe',
    footer: 'Our record of deliveries received and payments made. Tell us if anything here differs from your records.',
  );
}

/// Opens the statement window for one supplier. [onPay] is called with the balance when "Pay" is pressed.
Future<void> openSupplierStatement(BuildContext context, String supplierId, String name, {void Function(double owing)? onPay}) =>
    showLedgerStatement(
      context,
      heading: name,
      initialPreset: 'All time',
      payLabel: 'Pay',
      onPay: onPay,
      fileName: 'Supplier-statement-${name.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')}',
      load: (from, to) => loadSupplierLedger(supplierId, from, to),
    );

/// The Pay supplier window: records a payment, or a supplier credit note. Returns true if saved.
Future<bool> recordSupplierPayment(BuildContext context,
    {required String supplierId, Map<String, dynamic>? delivery, double? owing}) async {
    final balance = delivery == null ? (owing ?? 0) : n(delivery['total']).toDouble() - n(delivery['paid']).toDouble();
    final amount = TextEditingController(text: balance > 0 ? balance.toStringAsFixed(2) : '');
    final note = TextEditingController();
    String method = 'eft';
    DateTime day = DateTime.now();
    bool advance = false;
    final payId = LocalStore.newId();   // the same id is resent on a retry, so it is saved once
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final a = double.tryParse(amount.text.replaceAll(',', '.')) ?? 0;
        return AlertDialog(
          title: Text(delivery == null ? 'Pay supplier' : 'Pay ${delivery['grv_no']}'),
          content: SizedBox(
            width: 400,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: amount,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => set(() {}),
                  decoration: const InputDecoration(labelText: 'Amount', prefixText: 'R ')),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: method,
                decoration: const InputDecoration(labelText: 'How'),
                items: const [
                  DropdownMenuItem(value: 'eft', child: Text('EFT')),
                  DropdownMenuItem(value: 'cash', child: Text('Cash')),
                  DropdownMenuItem(value: 'card', child: Text('Card')),
                  DropdownMenuItem(value: 'credit_note', child: Text('Supplier credit note (goods returned or short)')),
                ],
                onChanged: (v) => set(() => method = v ?? 'eft'),
              ),
              const SizedBox(height: 8),
              TextField(controller: note, decoration: const InputDecoration(labelText: 'Reference / note')),
              if (delivery == null)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: advance,
                  onChanged: (v) => set(() => advance = v ?? false),
                  title: const Text('Paying in advance'),
                  subtitle: Text(owing == null
                      ? 'Tick only if you are paying before the goods arrive.'
                      : 'Owed now: ${money(owing < 0 ? 0 : owing)}. Tick only to pay more than that on purpose.'),
                ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.calendar_today, size: 16),
                  label: Text('Date  ${_d(day)}'),
                  onPressed: () async {
                    final p = await showDatePicker(
                        context: ctx, firstDate: DateTime(day.year - 3), lastDate: DateTime.now(), initialDate: day);
                    if (p != null) set(() => day = p);
                  },
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: a > 0 ? () => Navigator.pop(ctx, true) : null, child: const Text('Save payment')),
          ],
        );
      }),
    );
    if (ok != true || !context.mounted) return false;
    var saved = false;
    try {
      await AppDb.rpc('record_supplier_payment', params: {
        'p_id': payId,
        'p_supplier': supplierId,
        'p_grv': delivery?['id'],
        'p_amount': double.parse(amount.text.replaceAll(',', '.')),
        'p_method': method,
        'p_paid_on': _d(day),
        'p_note': note.text.trim(),
        'p_advance': advance,
      });
      saved = true;
    } on PostgrestException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This needs an internet connection.')));
      }
    }
    return saved;
  }




/// Every supplier together: what was bought and paid between two dates, one running total.
Future<Ledger> loadAllSuppliersLedger(DateTime from, DateTime to) async {
  final db = Supabase.instance.client;
  final grvs = List<Map<String, dynamic>>.from(await db
      .from('grvs')
      .select('grv_no, supplier_id, received_on, total, status, created_at')
      .inFilter('status', ['posted']));
  final pays = List<Map<String, dynamic>>.from(
      await db.from('supplier_payments').select('supplier_id, amount, method, paid_on, note, created_at'));
  String name(dynamic id) => '${LocalStore.row('suppliers', id)?['name'] ?? 'Supplier'}';
  final entries = <Map<String, dynamic>>[
    for (final g in grvs)
      {
        'date': '${g['received_on']}',
        'at': '${g['created_at']}',
        'what': '${name(g['supplier_id'])} · Delivery ${g['grv_no']}',
        'party': name(g['supplier_id']),
        'charge': n(g['total']).toDouble(),
        'paid': 0.0,
        'group': '',
      },
    for (final p in pays)
      {
        'date': '${p['paid_on']}',
        'at': '${p['created_at']}',
        'what': '${name(p['supplier_id'])} · ${_methodNames[p['method']] ?? p['method']}${'${p['note'] ?? ''}'.isEmpty ? '' : ' · ${p['note']}'}',
        'party': name(p['supplier_id']),
        'charge': 0.0,
        'paid': n(p['amount']).toDouble(),
        'group': '${_methodNames[p['method']] ?? p['method']}'.replaceAll(' payment', ''),
      },
  ]..sort((a, b) {
      final c = '${a['date']}'.compareTo('${b['date']}');
      return c != 0 ? c : '${a['at']}'.compareTo('${b['at']}');
    });
  return _combine('All suppliers', 'Creditors transactions', entries, from, to,
      chargeLabel: 'Bought', paidLabel: 'Paid and credited', owedWord: 'we owe');
}

Ledger _combine(String name, String title, List<Map<String, dynamic>> entries, DateTime from, DateTime to,
    {required String chargeLabel, required String paidLabel, required String owedWord}) {
  final f = _d(from), t = _d(to);
  var bal = 0.0, opening = 0.0;
  final lines = <LedgerLine>[];
  for (final e in entries) {
    bal = round2(bal + (e['charge'] as double) - (e['paid'] as double));
    final date = e['date'] as String;
    if (date.compareTo(f) < 0) {
      opening = bal;
    } else if (date.compareTo(t) <= 0) {
      lines.add(LedgerLine(
          date: date,
          what: e['what'] as String,
          charge: e['charge'] as double,
          paid: e['paid'] as double,
          balance: bal,
          group: e['group'] as String,
          party: e['party'] as String));
    }
  }
  return Ledger(
    partyName: name,
    from: f,
    to: t,
    opening: opening,
    closing: lines.isEmpty ? opening : lines.last.balance,
    lines: lines,
    title: title,
    chargeLabel: chargeLabel,
    paidLabel: paidLabel,
    owedWord: owedWord,
    footer: 'Combined record of every ${chargeLabel == 'Sales' ? 'customer account' : 'supplier'} for the period.',
  );
}

/// Every customer account together, from the account ledger.
Future<Ledger> loadAllAccountsLedger(DateTime from, DateTime to) async {
  final db = Supabase.instance.client;
  final accounts = {for (final a in await AccountsRepo.ageing()) '${a['id']}': '${a['name']}'};
  final tx = List<Map<String, dynamic>>.from(await db
      .from('account_transactions')
      .select('account_id, kind, amount, method, reference, business_date, created_at, orders(order_ref, invoice_no)'));
  const kinds = {
    'sale': 'Sale',
    'payment': 'Payment received',
    'credit_note': 'Credit note',
    'writeoff': 'Written off',
    'writeoff_reversal': 'Write-off reversed',
    'credit_refund': 'Credit paid back',
  };
  final entries = <Map<String, dynamic>>[
    for (final x in tx)
      () {
        final amt = n(x['amount']).toDouble();
        final k = kinds[x['kind']] ?? '${x['kind']}';
        final o = x['orders'] is Map ? x['orders'] as Map : const {};
        final ref = '${o['invoice_no'] ?? o['order_ref'] ?? ''}';
        final who = accounts['${x['account_id']}'] ?? 'Account';
        return {
          'date': '${x['business_date']}',
          'at': '${x['created_at']}',
          'what': '$who · $k${ref.isEmpty ? '' : ' $ref'}${x['method'] == null ? '' : ' (${x['method']})'}',
          'party': who,
          'charge': amt > 0 ? amt : 0.0,
          'paid': amt < 0 ? -amt : 0.0,
          'group': k,
        };
      }(),
  ]..sort((a, b) {
      final c = '${a['date']}'.compareTo('${b['date']}');
      return c != 0 ? c : '${a['at']}'.compareTo('${b['at']}');
    });
  return _combine('All customers', 'Debtors transactions', entries, from, to,
      chargeLabel: 'Sales', paidLabel: 'Payments and credits', owedWord: 'owing');
}

Future<void> openAllSuppliersAnalysis(BuildContext context) => showLedgerStatement(context,
    heading: 'All suppliers', initialPreset: 'This year', fileName: 'Creditors-transactions', load: loadAllSuppliersLedger);

Future<void> openAllAccountsAnalysis(BuildContext context) => showLedgerStatement(context,
    heading: 'All customers', initialPreset: 'This year', fileName: 'Debtors-transactions', load: loadAllAccountsLedger);
