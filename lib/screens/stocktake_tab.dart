import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/local_store.dart';
import '../data/repo.dart';
import '../data/sync_service.dart';
import '../theme.dart';

SupabaseClient get _db => Supabase.instance.client;

String _q(dynamic v) {
  final x = n(v);
  return x == x.roundToDouble() ? x.toInt().toString() : x.toStringAsFixed(2);
}

/// Stock-take: count everything, compare with what the system expects, and
/// correct the stock. The difference (variance) shows theft, waste and mistakes.
class StocktakeTab extends StatefulWidget {
  const StocktakeTab({super.key});

  @override
  State<StocktakeTab> createState() => _StocktakeTabState();
}

class _StocktakeTabState extends State<StocktakeTab> {
  List<Map<String, dynamic>> _list = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _say(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = await _db.from('stocktakes').select().order('created_at', ascending: false).limit(30);
      _list = rows.map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {
      if (mounted) _say('Stock-takes need an internet connection.');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _start() async {
    try {
      final id = await _db.rpc('start_stocktake', params: {'p_note': null});
      await _load();
      final t = _list.firstWhere((e) => e['id'] == id, orElse: () => {'id': id, 'status': 'draft'});
      if (mounted) _open(t);
    } on PostgrestException catch (e) {
      _say(e.message);
    } catch (_) {
      _say('This needs an internet connection.');
    }
  }

  Future<void> _open(Map<String, dynamic> t) async {
    await Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => _StocktakeEditor(take: t)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(20), children: [
      Row(children: [
        const Expanded(
            child: Text(
                'Count the stock weekly or monthly. Posting a count corrects the stock levels and shows the variance in Rands.',
                style: TextStyle(color: Brand.muted))),
        const SizedBox(width: 12),
        FilledButton.icon(onPressed: _start, icon: const Icon(Icons.fact_check_outlined), label: const Text('Start a stock-take')),
      ]),
      const SizedBox(height: 12),
      if (_loading) const LinearProgressIndicator(),
      Card(
        child: _list.isEmpty && !_loading
            ? const Padding(padding: EdgeInsets.all(24), child: Text('No stock-takes yet.'))
            : Column(children: [
                for (final t in _list)
                  ListTile(
                    onTap: () => _open(t),
                    title: Text('Stock-take ${'${t['created_at']}'.substring(0, 10)}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(t['status'] == 'posted' ? 'Posted · tap for the variance report' : 'In progress · tap to continue counting'),
                    trailing: Chip(
                        label: Text(t['status'] == 'posted' ? 'Posted' : 'In progress'),
                        backgroundColor: t['status'] == 'posted' ? const Color(0xFFDDF3E6) : const Color(0xFFFFF1CC)),
                  ),
              ]),
      ),
    ]);
  }
}

class _StocktakeEditor extends StatefulWidget {
  const _StocktakeEditor({required this.take});
  final Map<String, dynamic> take;

  @override
  State<_StocktakeEditor> createState() => _StocktakeEditorState();
}

class _StocktakeEditorState extends State<_StocktakeEditor> {
  List<Map<String, dynamic>> _lines = [];
  final _ctrl = <String, TextEditingController>{};
  bool _loading = true;
  bool _busy = false;
  late bool _posted = widget.take['status'] == 'posted';
  String _search = '';
  bool _onlyDiff = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _ctrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _say(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Map<String, dynamic>? _item(dynamic id) => LocalStore.row('stock_items', id);

  Future<void> _load() async {
    try {
      final rows = await _db.from('stocktake_lines').select().eq('stocktake_id', widget.take['id']);
      _lines = rows.map((e) => Map<String, dynamic>.from(e)).toList()
        ..sort((a, b) {
          final ia = _item(a['stock_item_id']), ib = _item(b['stock_item_id']);
          final c = '${ia?['category']}'.compareTo('${ib?['category']}');
          return c != 0 ? c : '${ia?['name']}'.compareTo('${ib?['name']}');
        });
      for (final l in _lines) {
        _ctrl['${l['stock_item_id']}'] =
            TextEditingController(text: l['counted_qty'] == null ? '' : _q(l['counted_qty']));
      }
    } catch (_) {
      if (mounted) _say('This needs an internet connection.');
    }
    if (mounted) setState(() => _loading = false);
  }

  double? _counted(Map<String, dynamic> l) {
    final t = _ctrl['${l['stock_item_id']}']?.text.trim().replaceAll(',', '.') ?? '';
    return t.isEmpty ? null : double.tryParse(t);
  }

  /// While counting, compare with the live stock level; after posting, with the level frozen at posting.
  double _expected(Map<String, dynamic> l) =>
      _posted ? n(l['expected_qty']).toDouble() : n(_item(l['stock_item_id'])?['qty_on_hand']).toDouble();

  Future<void> _saveLine(Map<String, dynamic> l) async {
    try {
      await _db
          .from('stocktake_lines')
          .update({'counted_qty': _counted(l)})
          .eq('stocktake_id', widget.take['id'])
          .eq('stock_item_id', l['stock_item_id']);
    } catch (_) {
      if (mounted) _say('Could not save that count. Check the connection.');
    }
  }

  Future<void> _post() async {
    final counted = _lines.where((l) => _counted(l) != null).length;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Post this stock-take?'),
        content: Text(
            '$counted of ${_lines.length} items were counted. Stock levels for the counted items will be changed to your counts. '
            'Items left blank are not changed. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep counting')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Post and correct stock')),
        ],
      ),
    );
    if (go != true) return;
    setState(() => _busy = true);
    try {
      for (final l in _lines) {
        await _saveLine(l);
      }
      await _db.rpc('post_stocktake', params: {'p_id': widget.take['id']});
      await SyncService.instance.syncNow();
      _posted = true;
      await _load();
    } on PostgrestException catch (e) {
      _say(e.message);
    } catch (_) {
      _say('This needs an internet connection.');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    var varianceValue = 0.0;
    for (final l in _lines) {
      final c = _posted ? (l['counted_qty'] == null ? null : n(l['counted_qty']).toDouble()) : _counted(l);
      if (c != null) varianceValue += (c - _expected(l)) * n(_posted ? l['unit_cost'] : _item(l['stock_item_id'])?['avg_cost']);
    }
    final shown = _lines.where((l) {
      final name = '${_item(l['stock_item_id'])?['name'] ?? ''}'.toLowerCase();
      if (_search.isNotEmpty && !name.contains(_search.toLowerCase())) return false;
      if (_onlyDiff) {
        final c = _posted ? (l['counted_qty'] == null ? null : n(l['counted_qty']).toDouble()) : _counted(l);
        return c != null && (c - _expected(l)).abs() > 0.0005;
      }
      return true;
    }).toList();

    return Scaffold(
      appBar: AppBar(title: Text(_posted ? 'Stock-take: variance report' : 'Stock-take: counting')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  SizedBox(
                    width: 240,
                    child: TextField(
                      onChanged: (v) => setState(() => _search = v),
                      decoration: const InputDecoration(hintText: 'Search items', prefixIcon: Icon(Icons.search), isDense: true),
                    ),
                  ),
                  FilterChip(
                      label: const Text('Only differences'),
                      selected: _onlyDiff,
                      onSelected: (v) => setState(() => _onlyDiff = v)),
                  Text(
                      'Variance ${varianceValue >= 0 ? '+' : '-'}${money(varianceValue.abs())}',
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: varianceValue.abs() < 0.005 ? Brand.green : (varianceValue < 0 ? Brand.red : Brand.amber))),
                  if (!_posted)
                    FilledButton(onPressed: _busy ? null : _post, child: Text(_busy ? 'Posting...' : 'Post and correct stock')),
                ]),
              ),
              if (!_posted)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                      'Type what you counted. Counts save as you go, so you can stop and come back. Best done when the shop is closed, so sales do not move the stock while you count.',
                      style: TextStyle(color: Brand.muted, fontSize: 12)),
                ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final l = shown[i];
                    final it = _item(l['stock_item_id']);
                    final c = _posted ? (l['counted_qty'] == null ? null : n(l['counted_qty']).toDouble()) : _counted(l);
                    final exp = _expected(l);
                    final diff = c == null ? null : c - exp;
                    final cost = n(_posted ? l['unit_cost'] : it?['avg_cost']);
                    final first = i == 0 || _item(shown[i - 1]['stock_item_id'])?['category'] != it?['category'];
                    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (first)
                        Padding(
                          padding: const EdgeInsets.only(top: 10, bottom: 4),
                          child: Text('${it?['category'] ?? 'Other'}',
                              style: const TextStyle(fontWeight: FontWeight.w800, color: Brand.navy)),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${it?['name'] ?? 'Unknown'}', style: const TextStyle(fontWeight: FontWeight.w600)),
                              Text('System: ${_q(exp)} ${it?['unit'] ?? ''}', style: const TextStyle(color: Brand.muted, fontSize: 12)),
                            ]),
                          ),
                          SizedBox(
                            width: 120,
                            child: _posted
                                ? Text(c == null ? 'Not counted' : '${_q(c)} ${it?['unit'] ?? ''}', textAlign: TextAlign.right)
                                : Focus(
                                    onFocusChange: (has) {
                                      if (!has) _saveLine(l);
                                    },
                                    child: TextField(
                                      controller: _ctrl['${l['stock_item_id']}'],
                                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                      onChanged: (_) => setState(() {}),
                                      decoration: InputDecoration(isDense: true, hintText: 'Count', suffixText: '${it?['unit'] ?? ''}'),
                                    ),
                                  ),
                          ),
                          SizedBox(
                            width: 150,
                            child: Text(
                                diff == null || diff.abs() < 0.0005
                                    ? (diff == null ? '' : 'OK')
                                    : '${diff > 0 ? '+' : ''}${_q(diff)} (${diff > 0 ? '+' : '-'}${money((diff * cost).abs())})',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: diff == null || diff.abs() < 0.0005 ? Brand.green : (diff < 0 ? Brand.red : Brand.amber))),
                          ),
                        ]),
                      ),
                    ]);
                  },
                ),
              ),
            ]),
    );
  }
}
