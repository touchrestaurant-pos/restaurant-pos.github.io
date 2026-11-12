import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_service.dart';
import '../data/local_store.dart';
import '../data/repo.dart';
import '../receipt/day_docs.dart';
import '../receipt/download_file.dart';
import 'package:printing/printing.dart';
import 'till_screen.dart' show tillCategories;
import '../theme.dart';

SupabaseClient get _db => Supabase.instance.client;

/// Supervisor end-of-day cash-up. Expected cash is worked out on the server from
/// the day's payments and refunds, so the count can be checked against it.
class CashUpScreen extends StatefulWidget {
  const CashUpScreen({super.key});

  @override
  State<CashUpScreen> createState() => _CashUpScreenState();
}

class _CashUpScreenState extends State<CashUpScreen> {
  DateTime _day = DateTime.now();
  String? _staff; // null = the whole day, every till
  Map<String, dynamic>? _sum;
  List<Map<String, dynamic>> _history = [];
  String? _error;
  bool _loading = false;
  bool _saving = false;
  final _float = TextEditingController(text: '0');
  final _counted = TextEditingController();
  final _notes = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _float.dispose();
    _counted.dispose();
    _notes.dispose();
    super.dispose();
  }

  String _d(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  double _num(TextEditingController c) => double.tryParse(c.text.replaceAll(',', '.')) ?? 0;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await _db.rpc('cash_up_summary', params: {'p_date': _d(_day), 'p_staff': _staff});
      _sum = Map<String, dynamic>.from(res as Map);
      final hist = await _db
          .from('cash_ups')
          .select()
          .order('created_at', ascending: false)
          .limit(14);
      _history = hist.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } on PostgrestException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Cash-up needs an internet connection. Connect and press Refresh.';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save(double expected, double variance) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save this cash-up?'),
        content: Text(
            'Expected ${money(expected)}, counted ${money(_num(_counted))}. '
            '${variance == 0 ? 'The drawer balances.' : (variance > 0 ? 'Over by ${money(variance)}.' : 'Short by ${money(-variance)}.')}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Check again')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save cash-up')),
        ],
      ),
    );
    if (go != true) return;
    setState(() => _saving = true);
    try {
      await _db.rpc('save_cash_up', params: {
        'p_date': _d(_day),
        'p_float': _num(_float),
        'p_counted': _num(_counted),
        'p_notes': _notes.text.trim(),
        'p_staff': _staff,
      });
      _counted.clear();
      _notes.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cash-up saved.')));
      }
      await _load();
    } on PostgrestException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Saving needs an internet connection.')));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  /// The whole day on one page: sales, VAT, payments, money out of the tills, cash-up counts.
  Future<void> _summaryReport() async {
    try {
      final r = Map<String, dynamic>.from(await _db.rpc('daily_summary', params: {'p_date': _d(_day)}) as Map);
      final bytes = await dailySummaryPdf(r, company: '${companyRow()?['trading_name'] ?? ''}'.isEmpty ? '${companyRow()?['company_name'] ?? ''}' : '${companyRow()?['trading_name']}');
      await Printing.layoutPdf(name: 'Daily-summary-${_d(_day)}', onLayout: (_) async => bytes);
    } on PostgrestException catch (e) {
      _say(e.message);
    } catch (_) {
      _say('The summary report needs an internet connection.');
    }
  }

  static const _kinds = {
    'drop': 'Cash drop (safe / bank)',
    'payout': 'Pay-out (petty cash)',
    'tip_payout': 'Tips paid to staff',
    'float_in': 'Cash added to drawer',
  };

  void _say(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _addMovement() async {
    String kind = 'drop';
    String category = 'Cash drop to safe';
    final amount = TextEditingController();
    final note = TextEditingController();
    final reference = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final a = double.tryParse(amount.text.replaceAll(',', '.')) ?? 0;
        return AlertDialog(
          title: const Text('Cash in or out'),
          content: SizedBox(
            width: 400,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                initialValue: kind,
                decoration: const InputDecoration(labelText: 'What happened'),
                items: [for (final e in _kinds.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                onChanged: (v) => set(() {
                  kind = v ?? 'drop';
                  category = kind == 'drop' ? 'Cash drop to safe' : (kind == 'tip_payout' ? 'Tips paid out' : (kind == 'float_in' ? '' : 'Petty cash'));
                }),
              ),
              if (kind == 'payout')
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: DropdownButtonFormField<String>(
                    initialValue: tillCategories.contains(category) ? category : 'Petty cash',
                    decoration: const InputDecoration(labelText: 'What is the money for?'),
                    items: [for (final c in tillCategories.where((c) => c != 'Cash drop to safe' && c != 'Tips paid out')) DropdownMenuItem(value: c, child: Text(c))],
                    onChanged: (v) => set(() => category = v ?? category),
                  ),
                ),
              const SizedBox(height: 8),
              TextField(
                  controller: amount,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => set(() {}),
                  decoration: const InputDecoration(labelText: 'Amount', prefixText: 'R ')),
              const SizedBox(height: 8),
              TextField(
                  controller: reference,
                  onChanged: (_) => set(() {}),
                  decoration: const InputDecoration(labelText: 'Reference (slip, invoice or receipt number)')),
              const SizedBox(height: 8),
              TextField(
                  controller: note,
                  onChanged: (_) => set(() {}),
                  decoration: const InputDecoration(labelText: 'Note (required), for example "bread from Spar"')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
                onPressed: a > 0 && note.text.trim().isNotEmpty && (kind == 'float_in' || reference.text.trim().isNotEmpty)
                    ? () => Navigator.pop(ctx, true)
                    : null,
                child: const Text('Save')),
          ],
        );
      }),
    );
    if (ok != true) return;
    try {
      await _db.from('cash_movements').insert({
        'business_date': _d(_day),
        'kind': kind,
        'amount': double.parse(amount.text.replaceAll(',', '.')),
        'note': note.text.trim(),
        'staff_id': _staff,
        if (category.isNotEmpty) 'category': category,
        if (reference.text.trim().isNotEmpty) 'reference': reference.text.trim(),
      });
      await _load();
    } on PostgrestException catch (e) {
      _say(e.message);
    } catch (_) {
      _say('This needs an internet connection.');
    }
  }

  Future<void> _closeDay() async {
    final unpaid = LocalStore.rows('orders').where((o) {
      final t = parseTime(o['created_at']);
      return o['paid'] != true && o['status'] != 'void' && t != null && _d(t) == _d(_day);
    }).length;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Close ${_d(_day)}?'),
        content: Text([
          if (_sum?['done'] == null) 'No cash-up has been saved for this day yet.',
          if (unpaid > 0) '$unpaid order${unpaid == 1 ? ' is' : 's are'} still unpaid.',
          'Closing freezes the figures and locks cash-ups and cash movements. Only an admin can reopen the day.',
        ].join('\n\n')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not yet')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Close the day')),
        ],
      ),
    );
    if (go != true) return;
    try {
      await _db.rpc('close_day', params: {'p_date': _d(_day)});
      await _load();
      await _showClose();
    } on PostgrestException catch (e) {
      _say(e.message);
    } catch (_) {
      _say('Closing the day needs an internet connection.');
    }
  }

  Future<void> _reopen() async {
    try {
      await _db.rpc('reopen_day', params: {'p_date': _d(_day)});
      await _load();
    } on PostgrestException catch (e) {
      _say(e.message);
    } catch (_) {
      _say('This needs an internet connection.');
    }
  }

  /// The frozen figures, next to the live ones so late arrivals stand out.
  Future<void> _showClose() async {
    try {
      final row = await _db.from('day_closes').select().eq('business_date', _d(_day)).single();
      final sum = Map<String, dynamic>.from(row['summary'] as Map);
      final sm = Map<String, dynamic>.from((sum['summary'] as Map?) ?? const {});
      final cash = Map<String, dynamic>.from((sum['cash'] as Map?) ?? const {});
      final liveCash = n(_sum?['cash_sales']) + n(_sum?['card_sales']);
      final frozenCash = n(cash['cash_sales']) + n(cash['card_sales']);
      final lines = <List<String>>[
        ['Paid orders', '${sm['orders'] ?? 0}'],
        ['Sales incl. VAT', money(n(sm['gross']))],
        ['Discounts given', money(n(sm['discounts']))],
        ['Refunds', money(n(sm['refunds']))],
        ['Sales after refunds', money(n(sm['after_refunds']))],
        ['VAT', money(n(sm['vat']))],
        ['Sales excl. VAT', money(n(sm['net']))],
        ['Tips', money(n(sm['tips']))],
        ['Cash payments', money(n(cash['cash_sales']))],
        ['Card payments', money(n(cash['card_sales']))],
        if (n(cash['account_sales']) > 0) ['Sold on account', money(n(cash['account_sales']))],
        ['Cash refunds', money(n(cash['cash_refunds']))],
        ['Cash taken out', money(n(cash['cash_out']))],
        for (final c in (sum['cash_ups'] as List? ?? const []))
          ['Cash-up variance', money(n((c as Map)['variance']))],
        ['Unpaid orders at close', '${(sum['unpaid'] as Map?)?['orders'] ?? 0}'],
        ['Cancelled orders', '${(sum['voided'] as Map?)?['orders'] ?? 0}'],
      ];
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Day-end summary · ${_d(_day)}'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Closed ${'${row['closed_at']}'.replaceFirst('T', ' ').split('.').first} (UTC)',
                    style: const TextStyle(color: Brand.muted, fontSize: 12)),
                const SizedBox(height: 8),
                for (final l in lines) _row(l[0], l[1]),
                if ((liveCash - frozenCash).abs() > 0.005)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                        '${money(liveCash - frozenCash)} in payments arrived after the day was closed (a till synced late). The reports include it.',
                        style: const TextStyle(color: Brand.amber, fontWeight: FontWeight.w700)),
                  ),
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () async {
                  await downloadBytes(
                      'Day-end_${_d(_day)}.csv',
                      Uint8List.fromList(utf8.encode('\uFEFFDay-end summary,${_d(_day)}\n${lines.map((l) => '"${l[0]}","${l[1]}"').join('\n')}\n')),
                      'text/csv');
                },
                child: const Text('Download')),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ],
        ),
      );
    } on PostgrestException catch (e) {
      _say(e.message);
    } catch (_) {
      _say('This needs an internet connection.');
    }
  }

  Widget _row(String l, String r, {bool bold = false, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(l, style: TextStyle(fontWeight: bold ? FontWeight.w800 : null))),
          Text(r, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w600, color: color)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final s = _sum;
    final cashSales = n(s?['cash_sales']).toDouble();
    final cashRefunds = n(s?['cash_refunds']).toDouble();
    final cashTips = n(s?['cash_tips']).toDouble();
    final cashOut = n(s?['cash_out']).toDouble();
    final cashIn = n(s?['cash_in']).toDouble();
    final acctCash = n(s?['acct_cash']).toDouble();
    final acctBack = n(s?['acct_cash_back']).toDouble();
    final acctSales = n(s?['account_sales']).toDouble();
    final closed = s?['closed'] == true;
    final moves = ((s?['movements'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final expected = _num(_float) + cashSales + cashTips - cashRefunds - cashOut + cashIn + acctCash - acctBack;
    final staffList = LocalStore.rows('staff_profiles')
        .where((p) => p['active'] != false && const ['cashier', 'supervisor', 'admin'].contains(p['role']))
        .toList()
      ..sort((a, b) => '${a['full_name']}'.compareTo('${b['full_name']}'));
    final counted = _counted.text.trim().isEmpty ? null : _num(_counted);
    final variance = counted == null ? 0.0 : round2(counted - expected);
    final done = s?['done'] as Map?;

    return ListView(padding: const EdgeInsets.all(20), children: [
      Row(children: [
        const Expanded(
            child: Text('Cash-up',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Brand.navy))),
        OutlinedButton.icon(
            onPressed: _loading ? null : _summaryReport, icon: const Icon(Icons.summarize_outlined, size: 18), label: const Text('Summary report')),
        const SizedBox(width: 8),
        OutlinedButton.icon(
            onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh, size: 18), label: const Text('Refresh')),
      ]),
      const SizedBox(height: 8),
      Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.calendar_today, size: 16),
          label: Text(_d(_day)),
          onPressed: () async {
            final p = await showDatePicker(
                context: context,
                initialDate: _day,
                firstDate: DateTime.now().subtract(const Duration(days: 90)),
                lastDate: DateTime.now());
            if (p != null) {
              setState(() => _day = p);
              _load();
            }
          },
        ),
        DropdownButton<String?>(
          value: _staff,
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('Whole day (all tills)')),
            for (final p in staffList)
              DropdownMenuItem<String?>(value: p['id'] as String, child: Text('${p['full_name']}')),
          ],
          onChanged: (v) {
            setState(() => _staff = v);
            _load();
          },
        ),
        Text(_staff == null ? 'Counts every payment and refund on this day.' : 'Only what this person took, for a drawer of their own.',
            style: const TextStyle(color: Brand.muted)),
      ]),
      const SizedBox(height: 16),
      if (_loading && s == null) const Center(child: CircularProgressIndicator()),
      if (_error != null)
        Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: const TextStyle(color: Brand.red))),
      if (s != null) ...[
        if (done != null)
          Card(
            color: const Color(0xFFDDF3E6),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                  'A cash-up was already saved for this day: expected ${money(n(done['expected_cash']))}, counted ${money(n(done['counted_cash']))}, '
                  'variance ${money(n(done['variance']))}. You can save another if needed.'),
            ),
          ),
        LayoutBuilder(builder: (context, box) {
          final cash = Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Cash drawer', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                TextField(
                    controller: _float,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Opening float', prefixText: 'R')),
                const SizedBox(height: 10),
                _row('Cash sales (${s['cash_count']} payments)', money(cashSales)),
                _row('Cash tips (pay out to staff)', money(cashTips)),
                _row('Cash refunds', '-${money(cashRefunds)}'),
                if (cashOut > 0) _row('Taken out (drops, pay-outs)', '-${money(cashOut)}'),
                if (cashIn > 0) _row('Added to the drawer', money(cashIn)),
                if (acctCash > 0) _row('Cash received on accounts', money(acctCash)),
                if (acctBack > 0) _row('Account credit paid back in cash', '-${money(acctBack)}'),
                const Divider(),
                _row('Expected in drawer', money(expected), bold: true),
                const SizedBox(height: 10),
                TextField(
                    controller: _counted,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Cash counted', prefixText: 'R')),
                const SizedBox(height: 8),
                if (counted != null)
                  Text(
                      variance == 0
                          ? 'The drawer balances.'
                          : (variance > 0 ? 'Over by ${money(variance)}' : 'Short by ${money(-variance)}'),
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: variance == 0 ? Brand.green : (variance.abs() < 20 ? Brand.amber : Brand.red))),
                const SizedBox(height: 8),
                TextField(controller: _notes, decoration: const InputDecoration(labelText: 'Notes (optional)')),
                const SizedBox(height: 12),
                FilledButton(
                    onPressed: counted == null || _saving || closed ? null : () => _save(expected, variance),
                    child: Text(_saving ? 'Saving...' : 'Save cash-up')),
              ]),
            ),
          );
          final card = Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Card payments', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                _row('Card sales', money(n(s['card_sales']))),
                _row('Card slips to match', '${s['card_slips']}'),
                _row('Card refunds', '-${money(n(s['card_refunds']))}'),
                _row('Card tips (pay out to staff)', money(n(s['card_tips']))),
                if (acctSales > 0 || n(s?['acct_card']) > 0 || n(s?['acct_eft']) > 0) ...[
                  const Divider(),
                  _row('Sold on account today (not paid yet)', money(acctSales)),
                  if (n(s?['acct_card']) > 0) _row('Account payments by card', money(n(s?['acct_card']))),
                  if (n(s?['acct_eft']) > 0) _row('Account payments by EFT', money(n(s?['acct_eft']))),
                ],
                const Divider(),
                _row('Card total to match against the machine',
                    money(n(s['card_sales']) + n(s['card_tips']) - n(s['card_refunds'])), bold: true),
                const SizedBox(height: 8),
                const Text('Compare this with the card machine settlement report for the day.',
                    style: TextStyle(color: Brand.muted, fontSize: 12)),
              ]),
            ),
          );
          if (box.maxWidth > 900) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: cash),
              const SizedBox(width: 16),
              Expanded(child: card),
            ]);
          }
          return Column(children: [cash, card]);
        }),
      ],
      if (s != null)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Expanded(
                    child: Text('Cash in and out of the drawer', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                if (!closed)
                  OutlinedButton.icon(onPressed: _addMovement, icon: const Icon(Icons.add), label: const Text('Record')),
              ]),
              const Text('Cash taken to the safe or bank, petty-cash pay-outs, tips paid to staff, or change added.',
                  style: TextStyle(color: Brand.muted, fontSize: 12)),
              if (moves.isEmpty) const Padding(padding: EdgeInsets.only(top: 8), child: Text('Nothing recorded for this day.')),
              for (final m in moves)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${m['category'] ?? _kinds[m['kind']] ?? m['kind']} · ${m['note']}'),
                  subtitle: Text('${m['by']}${'${m['reference'] ?? ''}'.isEmpty ? '' : ' · Ref ${m['reference']}'}'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('${m['kind'] == 'float_in' ? '+' : '-'}${money(n(m['amount']))}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    if (!closed)
                      IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () async {
                            try {
                              await _db.from('cash_movements').delete().eq('id', m['id']);
                              _load();
                            } catch (_) {}
                          }),
                  ]),
                ),
            ]),
          ),
        ),
      if (s != null && _staff == null)
        Card(
          color: closed ? const Color(0xFFDDF3E6) : null,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(closed ? 'This day is closed' : 'Close the day',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                  closed
                      ? 'The figures were frozen at closing. Cash-ups and cash movements for this day are locked.'
                      : 'Do this after the cash-up. It freezes a copy of the day\'s sales, payments, VAT and cash figures, and locks cash-ups and cash movements for the day.',
                  style: const TextStyle(color: Brand.muted)),
              const SizedBox(height: 10),
              Wrap(spacing: 10, runSpacing: 10, children: [
                if (!closed) FilledButton.icon(onPressed: _closeDay, icon: const Icon(Icons.lock), label: const Text('Close the day')),
                if (closed) OutlinedButton.icon(onPressed: _showClose, icon: const Icon(Icons.summarize), label: const Text('Day-end summary')),
                if (closed && AuthService.instance.role == 'admin')
                  TextButton(onPressed: _reopen, child: const Text('Reopen (admin)')),
              ]),
            ]),
          ),
        ),
      if (s != null && _staff == null && ((s['by_staff'] as List?) ?? const []).isNotEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Taken by each staff member', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(columns: const [
                  DataColumn(label: Text('Staff member')),
                  DataColumn(label: Text('Cash'), numeric: true),
                  DataColumn(label: Text('Card'), numeric: true),
                  DataColumn(label: Text('Tips'), numeric: true),
                  DataColumn(label: Text('Payments'), numeric: true),
                ], rows: [
                  for (final b in (s['by_staff'] as List).map((e) => Map<String, dynamic>.from(e as Map)))
                    DataRow(cells: [
                      DataCell(Text('${b['name']}')),
                      DataCell(Text(money(n(b['cash'])))),
                      DataCell(Text(money(n(b['card'])))),
                      DataCell(Text(money(n(b['tips'])))),
                      DataCell(Text('${b['payments']}')),
                    ]),
                ]),
              ),
            ]),
          ),
        ),
      if (_history.isNotEmpty)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Recent cash-ups', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(columns: const [
                  DataColumn(label: Text('Date')),
                  DataColumn(label: Text('Drawer')),
                  DataColumn(label: Text('Expected'), numeric: true),
                  DataColumn(label: Text('Counted'), numeric: true),
                  DataColumn(label: Text('Variance'), numeric: true),
                  DataColumn(label: Text('Card total'), numeric: true),
                  DataColumn(label: Text('Notes')),
                ], rows: [
                  for (final h in _history)
                    DataRow(cells: [
                      DataCell(Text('${h['business_date']}')),
                      DataCell(Text(h['staff_id'] == null
                          ? 'Whole day'
                          : '${LocalStore.row('staff_profiles', h['staff_id'])?['full_name'] ?? 'Staff'}')),
                      DataCell(Text(money(n(h['expected_cash'])))),
                      DataCell(Text(money(n(h['counted_cash'])))),
                      DataCell(Text(money(n(h['variance'])),
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: n(h['variance']) == 0 ? Brand.green : Brand.red))),
                      DataCell(Text(money(n(h['card_sales']) - n(h['card_refunds'])))),
                      DataCell(Text('${h['notes'] ?? ''}')),
                    ]),
                ]),
              ),
            ]),
          ),
        ),
    ]);
  }
}
