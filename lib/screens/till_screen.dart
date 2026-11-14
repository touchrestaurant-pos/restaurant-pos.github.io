import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/local_store.dart';
import '../data/repo.dart';
import '../theme.dart';
import '../data/app_db.dart';

/// What the money is for. The text is stored with each pay-out and used in the reports.
const tillCategories = [
  'Petty cash',
  'Supplier payment',
  'Staff advance',
  'Delivery / transport',
  'Cleaning & supplies',
  'Tips paid out',
  'Cash drop to safe',
  'Other',
];

/// Money taken out of the till (petty cash and so on). It comes off that till's cash for the day
/// and is listed in the day's cash-up. A till user sees only their own pay-outs, never sales.
class TillScreen extends StatefulWidget {
  const TillScreen({super.key});

  @override
  State<TillScreen> createState() => _TillScreenState();
}

class _TillScreenState extends State<TillScreen> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  String _category = 'Petty cash';
  final _amount = TextEditingController();
  final _reference = TextEditingController();
  final _note = TextEditingController();
  // One id per entry, so a retry after a bad connection cannot record the money twice.
  String _entryId = LocalStore.newId();
  String? _formError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await AppDb.rpc('my_payouts');
      _data = Map<String, dynamic>.from(r as Map);
    } catch (e) {
      _error = _msg(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  String _msg(Object e) {
    if (e is PostgrestException) return e.message;
    final s = '$e';
    if (s.contains('SocketException') || s.contains('Failed host lookup') || s.contains('ClientException')) {
      return 'No internet. Taking money from the till is only recorded when you are online.';
    }
    return s;
  }

  double get _value => double.tryParse(_amount.text.trim().replaceAll(',', '.')) ?? 0;

  String? get _amountProblem {
    if (_amount.text.trim().isEmpty) return null;
    final v = _value;
    if (v <= 0) return 'Enter an amount more than R0';
    final lim = n(_data?['limit']).toDouble();
    if (lim > 0 && v > lim) return 'The most you can take at one time is ${money(lim)}. Ask a supervisor.';
    return null;
  }

  bool get _ready =>
      _value > 0 &&
      _amountProblem == null &&
      _reference.text.trim().isNotEmpty &&
      _note.text.trim().length >= 3 &&
      _data?['closed'] != true;

  Future<void> _save() async {
    final v = round2(_value);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Take ${money(v)} out of the till?'),
        content: Text('$_category\nReference: ${_reference.text.trim()}\n${_note.text.trim()}\n\nThis comes off the cash in this till today.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Go back')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes, take it')),
        ],
      ),
    );
    if (go != true) return;
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      await AppDb.rpc('till_payout', params: {
        'p_amount': v,
        'p_category': _category,
        'p_reference': _reference.text.trim(),
        'p_note': _note.text.trim(),
        'p_id': _entryId,
      });
      _amount.clear();
      _reference.clear();
      _note.clear();
      _entryId = LocalStore.newId();
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('${money(v)} recorded. Take the cash and keep the slip with the reference.')));
      }
      await _load();
    } catch (e) {
      _formError = _msg(e);
    }
    if (mounted) setState(() => _saving = false);
  }

  String _time(dynamic v) {
    final t = parseTime(v);
    if (t == null) return '';
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final items = ((_data?['items'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final closed = _data?['closed'] == true;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        const Expanded(child: Text('Money out of the till', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800))),
        IconButton(onPressed: _load, tooltip: 'Refresh', icon: const Icon(Icons.refresh)),
      ]),
      const Text('Use this whenever cash leaves the till: petty cash, paying a supplier, a cash drop to the safe. It comes off today\'s cash and shows in the cash-up.',
          style: TextStyle(color: Brand.muted)),
      const SizedBox(height: 12),
      if (closed)
        const Card(
            color: Color(0xFFFFF4D6),
            child: Padding(padding: EdgeInsets.all(12), child: Text('Today has been closed, so nothing more can be recorded. Ask an admin.')))
      else
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              DropdownButtonFormField<String>(
                value: _category,
                decoration: const InputDecoration(labelText: 'What is the money for?'),
                items: [for (final c in tillCategories) DropdownMenuItem(value: c, child: Text(c))],
                onChanged: (v) => setState(() => _category = v ?? _category),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                decoration: InputDecoration(labelText: 'Amount', prefixText: 'R ', errorText: _amountProblem),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _reference,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                    labelText: 'Reference (required)', helperText: 'Slip, invoice or receipt number, or who it was given to'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _note,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'What was it used for? (required)', helperText: 'For example: bread from Spar'),
              ),
              if (_formError != null)
                Padding(padding: const EdgeInsets.only(top: 10), child: Text(_formError!, style: const TextStyle(color: Brand.red, fontWeight: FontWeight.w700))),
              const SizedBox(height: 12),
              FilledButton(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: _ready && !_saving ? _save : null,
                child: Text(_saving ? 'Saving...' : 'Take money out'),
              ),
            ]),
          ),
        ),
      const SizedBox(height: 12),
      Row(children: [
        const Expanded(child: Text('Taken out today', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
        Text(money(n(_data?['total'])), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      ]),
      const SizedBox(height: 6),
      if (_loading)
        const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
      else if (_error != null)
        Text(_error!, style: const TextStyle(color: Brand.red, fontWeight: FontWeight.w600))
      else if (items.isEmpty)
        const Padding(padding: EdgeInsets.all(12), child: Text('Nothing taken out yet today.'))
      else
        for (final m in items)
          Card(
            child: ListTile(
              title: Text('${m['category'] ?? 'Pay-out'} · ${m['note']}', style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('${_time(m['at'])} · Ref ${m['reference'] ?? '-'}${'${m['by']}'.isEmpty ? '' : ' · ${m['by']}'}'),
              trailing: Text('-${money(n(m['amount']))}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            ),
          ),
    ]);
  }
}
