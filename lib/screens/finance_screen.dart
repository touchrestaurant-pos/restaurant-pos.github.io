import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/local_store.dart';
import '../data/repo.dart';
import '../data/supplier_ledger.dart';
import '../receipt/ledger.dart';
import '../theme.dart';

SupabaseClient get _db => Supabase.instance.client;

String _d(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void _say(BuildContext context, String m) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

Future<void> _guard(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
  } on PostgrestException catch (e) {
    if (context.mounted) _say(context, e.message);
  } catch (_) {
    if (context.mounted) _say(context, 'This needs an internet connection.');
  }
}

/// Admin money screens: profit and VAT, expenses, and what is owed to suppliers.
class FinanceScreen extends StatelessWidget {
  const FinanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(children: const [
        Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Finance', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Brand.navy)),
          ),
        ),
        TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelColor: Brand.navy,
          indicatorColor: Brand.gold,
          tabs: [Tab(text: 'Profit and VAT'), Tab(text: 'Expenses'), Tab(text: 'Supplier accounts')],
        ),
        Expanded(child: TabBarView(children: [_ProfitTab(), _ExpensesTab(), _SuppliersTab()])),
      ]),
    );
  }
}

/// From and To date buttons shared by the tabs.
class _RangeBar extends StatelessWidget {
  const _RangeBar({required this.from, required this.to, required this.onChanged});
  final DateTime from;
  final DateTime to;
  final void Function(DateTime from, DateTime to) onChanged;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    Future<void> pick(bool isFrom) async {
      final p = await showDatePicker(
          context: context,
          firstDate: DateTime(now.year - 5),
          lastDate: DateTime(now.year + 1),
          initialDate: isFrom ? from : to,
          helpText: isFrom ? 'From date' : 'To date');
      if (p == null) return;
      var f = isFrom ? p : from, t = isFrom ? to : p;
      if (t.isBefore(f)) {
        if (isFrom) {
          t = f;
        } else {
          f = t;
        }
      }
      onChanged(f, t);
    }

    Widget preset(String label, DateTime f, DateTime t) => ActionChip(label: Text(label), onPressed: () => onChanged(f, t));
    final today = DateTime(now.year, now.month, now.day);
    return Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      OutlinedButton.icon(
          onPressed: () => pick(true), icon: const Icon(Icons.calendar_today, size: 16), label: Text('From  ${_d(from)}')),
      OutlinedButton.icon(
          onPressed: () => pick(false), icon: const Icon(Icons.calendar_today, size: 16), label: Text('To  ${_d(to)}')),
      preset('Today', today, today),
      preset('This month', DateTime(now.year, now.month, 1), today),
      preset('Last month', DateTime(now.year, now.month - 1, 1), DateTime(now.year, now.month, 0)),
      preset('This year', DateTime(now.year, 1, 1), today),
    ]);
  }
}

// ============================================================================ Profit and VAT

class _ProfitTab extends StatefulWidget {
  const _ProfitTab();

  @override
  State<_ProfitTab> createState() => _ProfitTabState();
}

class _ProfitTabState extends State<_ProfitTab> {
  late DateTime _from = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _to = DateTime.now();
  Map<String, dynamic>? _r;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await _db.rpc('profit_report', params: {'p_from': _d(_from), 'p_to': _d(_to)});
      _r = Map<String, dynamic>.from(res as Map);
    } on PostgrestException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'This needs an internet connection.';
    }
    if (mounted) setState(() => _loading = false);
  }

  Widget _line(String label, dynamic value, {bool bold = false, bool minus = false, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Expanded(child: Text(label, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w400))),
          Text('${minus ? '-' : ''}${money(n(value))}',
              style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w600, fontSize: bold ? 17 : 14, color: color)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final r = _r;
    return ListView(padding: const EdgeInsets.all(20), children: [
      _RangeBar(
          from: _from,
          to: _to,
          onChanged: (f, t) {
            setState(() {
              _from = f;
              _to = t;
            });
            _load();
          }),
      const SizedBox(height: 12),
      if (_loading) const LinearProgressIndicator(),
      if (_error != null) Text(_error!, style: const TextStyle(color: Brand.red)),
      if (r != null)
        LayoutBuilder(builder: (context, box) {
          final profit = Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Profit and loss (excluding VAT)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                _line('Sales', r['sales_excl']),
                _line('Refunds', r['refunds_excl'], minus: true),
                _line('Net sales', r['net_sales'], bold: true),
                const Divider(),
                _line('Cost of food sold', r['cost_of_sales'], minus: true),
                _line('Waste', r['waste'], minus: true),
                _line('Gross profit', r['gross_profit'], bold: true),
                const Divider(),
                for (final e in (r['expense_categories'] as List))
                  _line('${(e as Map)['category']}', e['amount'], minus: true),
                _line('Total expenses', r['expenses'], minus: true),
                const Divider(),
                _line(n(r['net_profit']) >= 0 ? 'Net profit' : 'Net loss', n(r['net_profit']).abs(),
                    bold: true, color: n(r['net_profit']) >= 0 ? Brand.green : Brand.red),
                const SizedBox(height: 8),
                const Text(
                    'Cost of food uses each item\'s cost when it was sold. Wages, rent and other costs only count once you capture them under Expenses.',
                    style: TextStyle(color: Brand.muted, fontSize: 12)),
              ]),
            ),
          );
          final vat = Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('VAT summary', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                _line('VAT on sales (output), after refunds', r['vat_output']),
                _line('VAT on stock deliveries (input)', r['vat_input_purchases'], minus: true),
                _line('VAT on expenses (input)', r['vat_input_expenses'], minus: true),
                const Divider(),
                _line(n(r['vat_payable']) >= 0 ? 'VAT to pay' : 'VAT refund due', n(r['vat_payable']).abs(), bold: true),
                const SizedBox(height: 8),
                Text('Stock received in this period: ${money(n(r['purchases_excl']))} excl. VAT.',
                    style: const TextStyle(color: Brand.muted, fontSize: 12)),
                const Text(
                    'A working figure to give your accountant, not a VAT return. Input VAT only counts with valid tax invoices from VAT-registered suppliers.',
                    style: TextStyle(color: Brand.muted, fontSize: 12)),
              ]),
            ),
          );
          if (box.maxWidth > 900) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: profit),
              const SizedBox(width: 16),
              Expanded(child: vat),
            ]);
          }
          return Column(children: [profit, vat]);
        }),
    ]);
  }
}

// ============================================================================ Expenses

const _expenseCategories = [
  'Wages',
  'Rent',
  'Electricity and water',
  'Gas',
  'Cleaning',
  'Repairs',
  'Marketing',
  'Bank charges',
  'Insurance',
  'Transport',
  'Other',
];

class _ExpensesTab extends StatefulWidget {
  const _ExpensesTab();

  @override
  State<_ExpensesTab> createState() => _ExpensesTabState();
}

class _ExpensesTabState extends State<_ExpensesTab> {
  late DateTime _from = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime _to = DateTime.now();
  List<Map<String, dynamic>> _rows = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    await _guard(context, () async {
      final rows = await _db
          .from('expenses')
          .select()
          .gte('spent_on', _d(_from))
          .lte('spent_on', _d(_to))
          .order('spent_on', ascending: false);
      _rows = rows.map((e) => Map<String, dynamic>.from(e)).toList();
    });
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _edit(Map<String, dynamic>? e) async {
    String category = '${e?['category'] ?? 'Wages'}';
    if (!_expenseCategories.contains(category)) category = 'Other';
    final desc = TextEditingController(text: '${e?['description'] ?? ''}');
    final amount = TextEditingController(text: e == null ? '' : '${n(e['amount'])}');
    bool hasVat = e != null && n(e['vat_amount']) > 0;
    String paidFrom = '${e?['paid_from'] ?? 'bank'}';
    DateTime day = DateTime.tryParse('${e?['spent_on'] ?? ''}') ?? DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final a = double.tryParse(amount.text.replaceAll(',', '.')) ?? 0;
        final vat = hasVat ? round2(a * vatRate() / (100 + vatRate())) : 0.0;
        return AlertDialog(
          title: Text(e == null ? 'Add expense' : 'Edit expense'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                DropdownButtonFormField<String>(
                  value: category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: [for (final c in _expenseCategories) DropdownMenuItem(value: c, child: Text(c))],
                  onChanged: (v) => set(() => category = v ?? 'Other'),
                ),
                const SizedBox(height: 8),
                TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description')),
                const SizedBox(height: 8),
                TextField(
                    controller: amount,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => set(() {}),
                    decoration: const InputDecoration(labelText: 'Amount paid (including VAT)', prefixText: 'R ')),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: hasVat,
                  onChanged: (v) => set(() => hasVat = v ?? false),
                  title: const Text('Includes VAT (I have a tax invoice)'),
                  subtitle: Text(hasVat ? 'VAT ${money(vat)}' : 'Wages, rent from a non-vendor and bank charges usually have none'),
                ),
                DropdownButtonFormField<String>(
                  value: paidFrom,
                  decoration: const InputDecoration(labelText: 'Paid from'),
                  items: const [
                    DropdownMenuItem(value: 'bank', child: Text('Bank (EFT / debit order)')),
                    DropdownMenuItem(value: 'card', child: Text('Business card')),
                    DropdownMenuItem(value: 'cash', child: Text('Cash')),
                  ],
                  onChanged: (v) => set(() => paidFrom = v ?? 'bank'),
                ),
                if (paidFrom == 'cash')
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('If the cash came out of the till, also record a pay-out on the Cash-up screen so the drawer balances.',
                        style: TextStyle(color: Brand.amber, fontSize: 12)),
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
          ),
          actions: [
            if (e != null)
              TextButton(
                  style: TextButton.styleFrom(foregroundColor: Brand.red),
                  onPressed: () async {
                    await _guard(context, () => _db.from('expenses').delete().eq('id', e['id']));
                    if (ctx.mounted) Navigator.pop(ctx, false);
                    _load();
                  },
                  child: const Text('Delete')),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: a > 0 ? () => Navigator.pop(ctx, true) : null, child: const Text('Save')),
          ],
        );
      }),
    );
    if (ok != true || !mounted) return;
    final a = double.parse(amount.text.replaceAll(',', '.'));
    final row = {
      'category': category,
      'description': desc.text.trim().isEmpty ? null : desc.text.trim(),
      'amount': a,
      'vat_amount': hasVat ? round2(a * vatRate() / (100 + vatRate())) : 0,
      'paid_from': paidFrom,
      'spent_on': _d(day),
    };
    await _guard(context, () async {
      if (e == null) {
        await _db.from('expenses').insert(row);
      } else {
        await _db.from('expenses').update(row).eq('id', e['id']);
      }
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final total = _rows.fold<double>(0, (s, r) => s + n(r['amount']).toDouble());
    return ListView(padding: const EdgeInsets.all(20), children: [
      _RangeBar(
          from: _from,
          to: _to,
          onChanged: (f, t) {
            setState(() {
              _from = f;
              _to = t;
            });
            _load();
          }),
      const SizedBox(height: 12),
      Row(children: [
        FilledButton.icon(onPressed: () => _edit(null), icon: const Icon(Icons.add), label: const Text('Add expense')),
        const SizedBox(width: 16),
        Text('Total ${money(total)}', style: const TextStyle(fontWeight: FontWeight.w800)),
      ]),
      const SizedBox(height: 4),
      const Text('Costs that are not stock: wages, rent, electricity and so on. Stock is captured by receiving deliveries.',
          style: TextStyle(color: Brand.muted, fontSize: 12)),
      const SizedBox(height: 8),
      if (_loading) const LinearProgressIndicator(),
      Card(
        child: _rows.isEmpty
            ? const Padding(padding: EdgeInsets.all(24), child: Text('No expenses captured for these dates.'))
            : Column(children: [
                for (final r in _rows)
                  ListTile(
                    onTap: () => _edit(r),
                    title: Text('${r['category']}${r['description'] == null ? '' : ' · ${r['description']}'}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(
                        '${r['spent_on']} · paid from ${r['paid_from']}${n(r['vat_amount']) > 0 ? ' · VAT ${money(n(r['vat_amount']))}' : ''}'),
                    trailing: Text(money(n(r['amount'])), style: const TextStyle(fontWeight: FontWeight.w800)),
                  ),
              ]),
      ),
    ]);
  }
}

// ============================================================================ Supplier accounts

class _SuppliersTab extends StatefulWidget {
  const _SuppliersTab();

  @override
  State<_SuppliersTab> createState() => _SuppliersTabState();
}

class _SuppliersTabState extends State<_SuppliersTab> {
  Map<String, dynamic>? _data;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    await _guard(context, () async {
      _data = Map<String, dynamic>.from(await _db.rpc('supplier_accounts') as Map);
    });
    if (mounted) setState(() => _loading = false);
  }

  List<Map<String, dynamic>> _l(String k) =>
      ((_data?[k] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  Future<void> _pay({required String supplierId, Map<String, dynamic>? delivery, double? owing}) async {
    await recordSupplierPayment(context, supplierId: supplierId, delivery: delivery, owing: owing);
    _load();
  }

  /// Every delivery and payment for one supplier with a running balance, oldest first.
  Future<void> _statement(Map<String, dynamic> sup) async {
    final id = sup['id'] as String;
    await openSupplierStatement(context, id, '${sup['name']}', onPay: (owing) async {
      await _pay(supplierId: id, owing: owing);
      if (mounted) _statement(sup);
    });
    if (mounted) _load();
  }

  Future<void> _printList(List<Map<String, dynamic>> suppliers) async {
    final owing = suppliers.fold<double>(0, (s, r) => s + n(r['owing']).toDouble());
    await Printing.layoutPdf(
      name: 'Creditors-list',
      onLayout: (_) => partyListPdf(
        title: 'Creditors (what we owe suppliers)',
        headers: const ['Supplier', 'Bought', 'Paid', 'Owing'],
        rows: [for (final r in suppliers) ['${r['name']}', money(n(r['purchased'])), money(n(r['paid'])), money(n(r['owing']))]],
        totals: ['Total', '', '', money(owing)],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final suppliers = _l('suppliers');
    final deliveries = _l('deliveries');
    final payments = _l('payments');
    final owing = suppliers.fold<double>(0, (s, r) => s + (n(r['owing']) > 0 ? n(r['owing']).toDouble() : 0));
    final overpaid = suppliers.fold<double>(0, (s, r) => s + (n(r['owing']) < 0 ? -n(r['owing']).toDouble() : 0));
    String supName(dynamic id) => '${LocalStore.row('suppliers', id)?['name'] ?? 'Supplier'}';
    return ListView(padding: const EdgeInsets.all(20), children: [
      Row(children: [
        Expanded(
            child: Text('You owe suppliers ${money(owing)}',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: owing > 0 ? Brand.red : Brand.green))),
        IconButton(tooltip: 'Transactions and analysis', onPressed: () => openAllSuppliersAnalysis(context), icon: const Icon(Icons.insights)),
        IconButton(tooltip: 'Print the creditors list', onPressed: suppliers.isEmpty ? null : () => _printList(suppliers), icon: const Icon(Icons.print_outlined)),
        IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
      ]),
      const Text('Built from posted deliveries (including VAT) minus the payments you record here.',
          style: TextStyle(color: Brand.muted, fontSize: 12)),
      if (overpaid > 0.005)
        Text('Paid ahead to suppliers: ${money(overpaid)} (more paid than delivered; it is not taken off what you owe other suppliers).',
            style: const TextStyle(color: Brand.green, fontSize: 12, fontWeight: FontWeight.w600)),
      if (_loading) const LinearProgressIndicator(),
      const SizedBox(height: 8),
      Card(
        child: suppliers.isEmpty
            ? const Padding(padding: EdgeInsets.all(24), child: Text('No posted deliveries yet.'))
            : Column(children: [
                for (final s in suppliers)
                  ListTile(
                    onTap: () => _statement(s),
                    title: Text('${s['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text('Tap to see the history · bought ${money(n(s['purchased']))} · paid ${money(n(s['paid']))}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(money(n(s['owing'])),
                          style: TextStyle(fontWeight: FontWeight.w800, color: n(s['owing']) > 0 ? Brand.red : Brand.green)),
                      const SizedBox(width: 8),
                      OutlinedButton(onPressed: () => _statement(s), child: const Text('Statement')),
                      const SizedBox(width: 8),
                      OutlinedButton(
                          onPressed: () => _pay(supplierId: s['id'] as String, owing: n(s['owing']).toDouble()),
                          child: const Text('Pay')),
                    ]),
                  ),
              ]),
      ),
      const SizedBox(height: 12),
      const Text('Deliveries not fully paid', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
      Card(
        child: deliveries.isEmpty
            ? const Padding(padding: EdgeInsets.all(16), child: Text('Every delivery has a payment against it.'))
            : Column(children: [
                for (final g in deliveries)
                  ListTile(
                    title: Text('${g['grv_no']} · ${supName(g['supplier_id'])}'),
                    subtitle: Text(
                        '${g['received_on']}${g['delivery_note'] == null ? '' : ' · ${g['delivery_note']}'} · total ${money(n(g['total']))} · paid ${money(n(g['paid']))}'),
                    trailing: OutlinedButton(
                        onPressed: () => _pay(supplierId: g['supplier_id'] as String, delivery: g),
                        child: Text('Pay ${money(n(g['total']) - n(g['paid']))}')),
                  ),
              ]),
      ),
      const SizedBox(height: 12),
      const Text('Recent payments', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
      Card(
        child: payments.isEmpty
            ? const Padding(padding: EdgeInsets.all(16), child: Text('No payments recorded yet.'))
            : Column(children: [
                for (final p in payments)
                  ListTile(
                    dense: true,
                    title: Text('${supName(p['supplier_id'])} · ${money(n(p['amount']))}'),
                    subtitle: Text(
                        '${p['paid_on']} · ${const {'eft': 'EFT', 'cash': 'Cash', 'card': 'Card', 'credit_note': 'Credit note'}[p['method']] ?? p['method']}'
                        '${p['grv_no'] == null ? '' : ' · ${p['grv_no']}'}${p['note'] == null ? '' : ' · ${p['note']}'}'),
                    trailing: IconButton(
                        tooltip: 'Delete payment',
                        icon: const Icon(Icons.delete_outline, size: 18),
                        onPressed: () async {
                          final go = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Delete this payment?'),
                              content: Text('${supName(p['supplier_id'])} · ${money(n(p['amount']))} · ${p['paid_on']}\n\n'
                                  'The supplier balance goes back up by this amount. The deletion is kept in the change history.'),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
                                FilledButton(
                                    style: FilledButton.styleFrom(backgroundColor: Brand.red, foregroundColor: Colors.white),
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text('Delete')),
                              ],
                            ),
                          );
                          if (go != true || !context.mounted) return;
                          await _guard(context, () => _db.from('supplier_payments').delete().eq('id', p['id']));
                          _load();
                        }),
                  ),
              ]),
      ),
    ]);
  }
}
