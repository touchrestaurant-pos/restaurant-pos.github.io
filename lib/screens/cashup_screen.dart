import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/local_store.dart';
import '../data/repo.dart';
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
    final expected = _num(_float) + cashSales + cashTips - cashRefunds;
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
                    onPressed: counted == null || _saving ? null : () => _save(expected, variance),
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
