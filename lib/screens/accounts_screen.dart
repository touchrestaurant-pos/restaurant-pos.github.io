import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../auth/auth_service.dart';
import '../data/accounts_repo.dart';
import '../data/local_store.dart';
import '../data/repo.dart';
import '../receipt/account_docs.dart';
import '../theme.dart';

const _statusNames = {'active': 'Active', 'blocked': 'Blocked', 'stopped': 'Stopped'};

/// Customer accounts: balances, limits, allow / block / stop, payments and statements.
/// Admin does everything; a supervisor can look and take payments.
class AccountsScreen extends StatefulWidget {
  const AccountsScreen({super.key});

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;
  String _filter = 'all';
  final _search = TextEditingController();

  bool get _admin => AuthService.instance.role == 'admin';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await AccountsRepo.ageing();
      if (mounted) setState(() => _rows = r);
    } catch (e) {
      if (mounted) setState(() => _error = AccountsRepo.message(e));
    }
    if (mounted) setState(() => _loading = false);
  }

  void _say(String m, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), backgroundColor: error ? Brand.red : null));
  }

  /// Runs a server call, shows its message if it is refused, then reloads.
  Future<bool> _run(Future<void> Function() f, {String? done}) async {
    try {
      await f();
      if (done != null) _say(done);
      await _load();
      return true;
    } catch (e) {
      _say(AccountsRepo.message(e), error: true);
      return false;
    }
  }

  Future<String?> _askText(String title, String label, {int min = 5, String? hint}) async {
    final c = TextEditingController();
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 380,
            child: TextField(
              controller: c,
              autofocus: true,
              maxLines: 2,
              onChanged: (_) => set(() {}),
              decoration: InputDecoration(labelText: label, helperText: hint ?? 'At least $min letters'),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
                onPressed: c.text.trim().length < min ? null : () => Navigator.pop(ctx, c.text.trim()),
                child: const Text('Save')),
          ],
        ),
      ),
    );
    return r;
  }

  // ---- add / edit ----

  Future<void> _edit([Map<String, dynamic>? a]) async {
    final isNew = a == null;
    final c = {
      for (final k in ['name', 'contact_name', 'phone', 'email', 'billing_address', 'vat_no', 'consent_note'])
        k: TextEditingController(text: '${a?[k] ?? ''}')
    };
    final limit = TextEditingController(text: a == null ? '' : n(a['credit_limit']).toStringAsFixed(2));
    final maxSale = TextEditingController(text: a?['max_sale'] == null ? '' : n(a!['max_sale']).toStringAsFixed(2));
    final terms = TextEditingController(text: '${a?['terms_days'] ?? 30}');
    var visible = a?['cashier_visible'] == true;
    var consent = false;
    String? err;

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        Widget tf(String label, TextEditingController ctl, {bool num = false, String? helper, int lines = 1}) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TextField(
                controller: ctl,
                maxLines: lines,
                keyboardType: num ? const TextInputType.numberWithOptions(decimal: true) : null,
                onChanged: (_) => set(() {}),
                decoration: InputDecoration(labelText: label, helperText: helper, isDense: true),
              ),
            );
        final canSave = c['name']!.text.trim().isNotEmpty && (!isNew || consent);
        return AlertDialog(
          title: Text(isNew ? 'New customer account' : 'Edit ${a!['name']}'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                tf('Customer / business name', c['name']!),
                tf('Contact person', c['contact_name']!),
                tf('Phone', c['phone']!),
                tf('Email', c['email']!),
                tf('Billing address', c['billing_address']!, lines: 2),
                tf('Customer VAT number', c['vat_no']!, helper: '10 digits. Needed on tax invoices over R5 000.'),
                tf('Credit limit (R)', limit, num: true, helper: 'The most this customer may owe at any time'),
                tf('Most on one sale (R), optional', maxSale, num: true),
                tf('Payment terms (days)', terms, num: true, helper: 'Invoices older than this (plus grace days) count as overdue'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: visible,
                  onChanged: (v) => set(() => visible = v),
                  title: const Text('Show this account to cashiers'),
                  subtitle: const Text('Off: only you and supervisors can see it, and it cannot be used at the till.'),
                ),
                if (isNew) ...[
                  tf('Signed form reference (optional)', c['consent_note']!, helper: 'For example the form number or date signed'),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: consent,
                    onChanged: (v) => set(() => consent = v ?? false),
                    title: const Text('The customer has signed the account application'),
                    subtitle: const Text('They agreed to the terms and to us keeping their details (POPIA). Print the form from the top of the Accounts page.'),
                  ),
                ],
                const Text('No interest or fees are charged on accounts.', style: TextStyle(color: Brand.muted, fontSize: 12)),
                if (err != null)
                  Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Brand.red, fontWeight: FontWeight.w600))),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: !canSave
                  ? null
                  : () async {
                      try {
                        await AccountsRepo.save({
                          if (!isNew) 'id': a!['id'],
                          for (final e in c.entries) e.key: e.value.text.trim(),
                          'credit_limit': double.tryParse(limit.text.trim().replaceAll(',', '.')) ?? 0,
                          'max_sale': double.tryParse(maxSale.text.trim().replaceAll(',', '.')),
                          'terms_days': int.tryParse(terms.text.trim()) ?? 30,
                          'cashier_visible': visible,
                          if (isNew) 'consent': consent,
                        });
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } catch (e) {
                        set(() => err = AccountsRepo.message(e));
                      }
                    },
              child: const Text('Save'),
            ),
          ],
        );
      }),
    );
    if (ok == true) {
      _say(isNew ? 'Account created.' : 'Account saved.');
      await _load();
    }
  }

  // ---- status ----

  Future<void> _setStatus(Map<String, dynamic> a, String status) async {
    String reason = '';
    if (status != 'active') {
      final r = await _askText(status == 'blocked' ? 'Block ${a['name']}' : 'Stop ${a['name']}', 'Reason',
          hint: status == 'blocked'
              ? 'No new sales on this account until you allow it again. Payments can still be taken.'
              : 'For closing the account for good. The balance must be zero. At least 5 letters.');
      if (r == null) return;
      reason = r;
    }
    await _run(() => AccountsRepo.setStatus('${a['id']}', status, reason),
        done: status == 'active' ? 'Account allowed.' : 'Account ${_statusNames[status]!.toLowerCase()}.');
  }

  // ---- payments ----

  Future<void> _takePayment(Map<String, dynamic> a) async {
    final bal = n(a['balance']).toDouble();
    if (bal <= 0.005) {
      _say('This account has nothing to pay.');
      return;
    }
    final amount = TextEditingController(text: bal.toStringAsFixed(2));
    final ref = TextEditingController();
    var method = 'eft';
    final payId = LocalStore.newId(); // a retry after a bad connection cannot take the money twice
    String? err;
    final res = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final v = double.tryParse(amount.text.trim().replaceAll(',', '.')) ?? 0;
        final bad = v <= 0 ? 'Enter the amount received' : (v > bal + 0.005 ? 'More than the balance owing (${money(bal)})' : null);
        return AlertDialog(
          title: Text('Payment from ${a['name']}'),
          content: SizedBox(
            width: 400,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Owing ${money(bal)}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
              const SizedBox(height: 10),
              TextField(
                controller: amount,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => set(() {}),
                decoration: InputDecoration(labelText: 'Amount received', prefixText: 'R ', errorText: bad),
              ),
              const SizedBox(height: 10),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'eft', label: Text('EFT')),
                  ButtonSegment(value: 'cash', label: Text('Cash')),
                  ButtonSegment(value: 'card', label: Text('Card')),
                ],
                selected: {method},
                onSelectionChanged: (s) => set(() => method = s.first),
              ),
              if (method == 'cash')
                const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text('Cash goes into the drawer: it is added to the expected cash in the cash-up for today.',
                        style: TextStyle(color: Brand.muted, fontSize: 12))),
              const SizedBox(height: 10),
              TextField(controller: ref, decoration: const InputDecoration(labelText: 'Bank reference (optional)')),
              if (err != null)
                Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Brand.red, fontWeight: FontWeight.w600))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: bad != null
                  ? null
                  : () async {
                      try {
                        final r = await AccountsRepo.recordPayment(
                            account: '${a['id']}', amount: v, method: method, reference: ref.text.trim(), note: null, id: payId);
                        if (ctx.mounted) Navigator.pop(ctx, r);
                      } catch (e) {
                        set(() => err = AccountsRepo.message(e));
                      }
                    },
              child: const Text('Record payment'),
            ),
          ],
        );
      }),
    );
    if (res == null) return;
    await _load();
    if (!mounted) return;
    final wantsPrint = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Payment recorded'),
        content: Text('Receipt ARC${'${res['receipt_no']}'.padLeft(5, '0')}. Balance now owing: ${money(n(res['balance']))}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Done')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Print receipt')),
        ],
      ),
    );
    if (wantsPrint == true) await openPdf(await accountReceiptPdf(res, reference: ref.text.trim()), 'Account-receipt');
  }

  Future<void> _writeOff(Map<String, dynamic> a) async {
    final bal = n(a['balance']).toDouble();
    if (bal <= 0.005) return;
    final reason = await _askText('Write off bad debt: ${a['name']}', 'Why is this being written off?',
        min: 10, hint: 'At least 10 letters. Keep proof you tried to collect it. Ask your accountant about the VAT.');
    if (reason == null || !mounted) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Write off the whole balance?'),
        content: Text('${money(bal)} will be written off. It is kept on record and can be reinstated, but not deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Brand.red, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Write off')),
        ],
      ),
    );
    if (sure == true) await _run(() => AccountsRepo.writeOff('${a['id']}', bal, reason), done: 'Written off.');
  }

  Future<void> _reinstate(Map<String, dynamic> a) async {
    final amount = TextEditingController();
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reinstate a written-off amount'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Amount', prefixText: 'R ')),
            const SizedBox(height: 8),
            TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason (10+ letters)')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reinstate')),
        ],
      ),
    );
    final v = double.tryParse(amount.text.trim().replaceAll(',', '.'));
    if (ok == true && v != null) await _run(() => AccountsRepo.reinstate('${a['id']}', v, reason.text.trim()), done: 'Reinstated.');
  }

  // ---- statement ----

  Future<void> _statement(Map<String, dynamic> a) async {
    final now = DateTime.now();
    var from = DateTime(now.year, now.month, 1);
    var to = DateTime(now.year, now.month, now.day);
    Map<String, dynamic>? st;
    String? err;
    bool busy = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        Future<void> load() async {
          set(() {
            busy = true;
            err = null;
          });
          try {
            st = await AccountsRepo.statement('${a['id']}', from, to);
          } catch (e) {
            err = AccountsRepo.message(e);
          }
          set(() => busy = false);
        }

        Future<void> pick(bool isFrom) async {
          final d = await showDatePicker(
              context: ctx, initialDate: isFrom ? from : to, firstDate: DateTime(2020), lastDate: DateTime(now.year + 1));
          if (d == null) return;
          set(() => isFrom ? from = d : to = d);
        }

        String f(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
        final lines = ((st?['lines'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        return AlertDialog(
          title: Text('Statement · ${a['name']}'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  OutlinedButton(onPressed: () => pick(true), child: Text('From ${f(from)}')),
                  OutlinedButton(onPressed: () => pick(false), child: Text('To ${f(to)}')),
                  FilledButton(onPressed: busy ? null : load, child: Text(busy ? 'Loading...' : 'Show')),
                ]),
                if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Brand.red))),
                if (st != null) ...[
                  const SizedBox(height: 10),
                  Text('Opening ${money(n(st!['opening']))}   ·   Closing ${money(n(st!['closing']))}',
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  if (lines.isEmpty)
                    const Text('No activity in this period.')
                  else
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        columns: const [
                          DataColumn(label: Text('Date')),
                          DataColumn(label: Text('What')),
                          DataColumn(label: Text('Amount'), numeric: true),
                          DataColumn(label: Text('Balance'), numeric: true),
                        ],
                        rows: [
                          for (final l in lines)
                            DataRow(cells: [
                              DataCell(Text('${l['date']}')),
                              DataCell(Text('${const {
                                    'sale': 'Sale',
                                    'payment': 'Payment',
                                    'credit_note': 'Credit note',
                                    'writeoff': 'Written off',
                                    'writeoff_reversal': 'Write-off reversed'
                                  }[l['kind']] ?? l['kind']} ${l['invoice_no'] ?? l['ref'] ?? ''}')),
                              DataCell(Text(money(n(l['amount'])))),
                              DataCell(Text(money(n(l['running'])))),
                            ]),
                        ],
                      ),
                    ),
                ],
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
            if (st != null)
              FilledButton.icon(
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('Print / save PDF'),
                onPressed: () async => Printing.layoutPdf(name: 'Statement-${a['account_no']}', onLayout: (_) => statementPdf(st!)),
              ),
          ],
        );
      }),
    );
  }

  // ---- rules ----

  Future<void> _rules() async {
    final c = companyRow() ?? {};
    var enabled = c['accounts_enabled'] == true;
    var blockOverdue = c['account_block_overdue'] != false;
    final grace = TextEditingController(text: '${c['account_grace_days'] ?? 7}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Account rules'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: enabled,
                onChanged: (v) => set(() => enabled = v),
                title: const Text('Sell on account'),
                subtitle: const Text('Shows an "On account" button on the payment screen.'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: blockOverdue,
                onChanged: (v) => set(() => blockOverdue = v),
                title: const Text('Stop sales when an account is overdue'),
                subtitle: const Text('Until the overdue amount is paid.'),
              ),
              TextField(
                controller: grace,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Grace days after the terms', helperText: '0 to 60'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final g = (int.tryParse(grace.text.trim()) ?? 7).clamp(0, 60);
    await LocalStore.patch('company_settings', 1, {
      'accounts_enabled': enabled,
      'account_block_overdue': blockOverdue,
      'account_grace_days': g,
    });
    _say('Saved. It reaches the other tills when they sync.');
    if (mounted) setState(() {});
  }

  // ---- build ----

  Color _statusColor(String s) => s == 'active' ? Brand.green : (s == 'blocked' ? Brand.amber : Brand.red);

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    bool match(Map<String, dynamic> a) {
      if (q.isNotEmpty && !'${a['name']} ${a['account_no']}'.toLowerCase().contains(q)) return false;
      switch (_filter) {
        case 'owing':
          return n(a['balance']) > 0.005;
        case 'overdue':
          return n(a['overdue']) > 0.005;
        case 'blocked':
          return a['status'] != 'active';
      }
      return true;
    }

    final shown = _rows.where(match).toList();
    final owed = _rows.fold<double>(0, (s, a) => s + n(a['balance']).toDouble());
    final overdue = _rows.fold<double>(0, (s, a) => s + n(a['overdue']).toDouble());

    return ListView(padding: const EdgeInsets.all(16), children: [
      Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        const Text('Customer accounts', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        if (_admin) FilledButton.icon(onPressed: () => _edit(), icon: const Icon(Icons.add), label: const Text('New account')),
        if (_admin) OutlinedButton.icon(onPressed: _rules, icon: const Icon(Icons.tune), label: const Text('Rules')),
        OutlinedButton.icon(
            onPressed: () async => Printing.layoutPdf(name: 'Account-application', onLayout: (_) => applicationFormPdf()),
            icon: const Icon(Icons.description_outlined),
            label: const Text('Print application form')),
        IconButton(onPressed: _load, tooltip: 'Refresh', icon: const Icon(Icons.refresh)),
      ]),
      const SizedBox(height: 6),
      if (companyRow()?['accounts_enabled'] != true)
        const Card(
          color: Color(0xFFFFF4D6),
          child: Padding(
              padding: EdgeInsets.all(12),
              child: Text('Selling on account is switched off, so the till does not offer it. An admin turns it on under Rules.')),
        ),
      Row(children: [
        Expanded(child: _stat('Owed to you', money(owed), Brand.navy)),
        const SizedBox(width: 10),
        Expanded(child: _stat('Overdue', money(overdue), overdue > 0 ? Brand.red : Brand.green)),
        const SizedBox(width: 10),
        Expanded(child: _stat('Accounts', '${_rows.length}', Brand.navy)),
      ]),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: 260,
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search name or number', isDense: true),
          ),
        ),
        for (final f in const {'all': 'All', 'owing': 'Owing', 'overdue': 'Overdue', 'blocked': 'Blocked / stopped'}.entries)
          ChoiceChip(label: Text(f.value), selected: _filter == f.key, onSelected: (_) => setState(() => _filter = f.key)),
      ]),
      const SizedBox(height: 10),
      if (_loading)
        const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
      else if (_error != null)
        Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_error!, style: const TextStyle(color: Brand.red, fontWeight: FontWeight.w600)))
      else if (shown.isEmpty)
        const Padding(padding: EdgeInsets.all(24), child: Text('No accounts to show.'))
      else
        for (final a in shown) _card(a),
    ]);
  }

  Widget _stat(String label, String value, Color color) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(color: Brand.muted, fontWeight: FontWeight.w600)),
            Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color)),
          ]),
        ),
      );

  Widget _card(Map<String, dynamic> a) {
    final status = '${a['status']}';
    final bal = n(a['balance']).toDouble();
    final od = n(a['overdue']).toDouble();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('${a['name']}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                Text('${a['account_no']}', style: const TextStyle(color: Brand.muted)),
                Chip(
                  label: Text(_statusNames[status] ?? status, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                  backgroundColor: _statusColor(status),
                  visualDensity: VisualDensity.compact,
                ),
                if (a['cashier_visible'] == true) const Chip(label: Text('Visible to cashiers'), visualDensity: VisualDensity.compact),
                if (a['consent_at'] == null) const Chip(label: Text('Not activated'), visualDensity: VisualDensity.compact),
              ]),
            ),
            Text(money(bal), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: bal > 0.005 ? Brand.navy : Brand.green)),
          ]),
          if ('${a['status_reason'] ?? ''}'.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text('Reason: ${a['status_reason']}', style: const TextStyle(color: Brand.muted))),
          const SizedBox(height: 6),
          Text(
              'Limit ${money(n(a['credit_limit']))} · available ${money(n(a['available']))}'
              '${a['max_sale'] != null ? ' · max per sale ${money(n(a['max_sale']))}' : ''} · terms ${a['terms_days']} days'
              '${od > 0.005 ? ' · overdue ${money(od)}' : ''}',
              style: TextStyle(color: od > 0.005 ? Brand.red : Brand.muted, fontWeight: FontWeight.w600)),
          if (bal > 0.005)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                  '0-30 ${money(n(a['current']))} · 31-60 ${money(n(a['d31']))} · 61-90 ${money(n(a['d61']))} · 90+ ${money(n(a['d90']))}',
                  style: const TextStyle(color: Brand.muted, fontSize: 12)),
            ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: [
            FilledButton.tonalIcon(
                onPressed: bal > 0.005 ? () => _takePayment(a) : null, icon: const Icon(Icons.payments_outlined), label: const Text('Take payment')),
            OutlinedButton.icon(onPressed: () => _statement(a), icon: const Icon(Icons.receipt_long), label: const Text('Statement')),
            if (_admin) ...[
              OutlinedButton(onPressed: () => _edit(a), child: const Text('Edit / limits')),
              if (status != 'active') OutlinedButton(onPressed: () => _setStatus(a, 'active'), child: const Text('Allow')),
              if (status == 'active') OutlinedButton(onPressed: () => _setStatus(a, 'blocked'), child: const Text('Block')),
              if (status != 'stopped') OutlinedButton(onPressed: () => _setStatus(a, 'stopped'), child: const Text('Stop')),
              if (bal > 0.005) OutlinedButton(onPressed: () => _writeOff(a), child: const Text('Write off')),
              TextButton(onPressed: () => _reinstate(a), child: const Text('Reinstate write-off')),
            ],
          ]),
        ]),
      ),
    );
  }
}
