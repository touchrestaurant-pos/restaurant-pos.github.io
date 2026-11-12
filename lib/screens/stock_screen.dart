import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/local_store.dart';
import '../data/repo.dart';
import '../data/sync_service.dart';
import '../theme.dart';
import '../auth/auth_service.dart';
import 'purchase_orders.dart';
import 'stock_item_view.dart';
import 'stocktake_tab.dart';

SupabaseClient get _db => Supabase.instance.client;

/// Stock changes are written straight to the server (they must be exact and
/// cannot be queued), then the device refreshes.
Future<bool> _online(BuildContext context, Future<void> Function() action) async {
  try {
    await action();
    await SyncService.instance.syncNow();
    return true;
  } on PostgrestException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Stock changes need an internet connection. Connect and try again.')));
    }
  }
  return false;
}

String _qty(dynamic v) {
  final x = n(v);
  return x == x.roundToDouble() ? x.toInt().toString() : x.toStringAsFixed(2);
}

String _date(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

List<Map<String, dynamic>> _items() {
  final list = LocalStore.rows('stock_items').toList();
  list.sort((a, b) => '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase()));
  return list;
}

List<Map<String, dynamic>> _suppliers() {
  final list = LocalStore.rows('suppliers').where((s) => s['active'] != false).toList();
  list.sort((a, b) => '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase()));
  return list;
}

String _supplierName(dynamic id) {
  for (final s in LocalStore.rows('suppliers')) {
    if (s['id'] == id) return '${s['name']}';
  }
  return 'No supplier';
}

/// Stock master, receiving stock (GRV) and suppliers.
class StockScreen extends StatelessWidget {
  const StockScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      child: Column(children: const [
        Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Stock',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Brand.navy)),
          ),
        ),
        TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelColor: Brand.navy,
          indicatorColor: Brand.gold,
          tabs: [Tab(text: 'Stock levels'), Tab(text: 'Purchase orders'), Tab(text: 'Receive stock (GRV)'), Tab(text: 'Stock-take'), Tab(text: 'Suppliers')],
        ),
        Expanded(
          child: TabBarView(children: [_LevelsTab(), PurchaseOrdersTab(), _GrvTab(), StocktakeTab(), _SuppliersTab()]),
        ),
      ]),
    );
  }
}

// ============================================================================
// Stock levels
// ============================================================================

class _LevelsTab extends StatefulWidget {
  const _LevelsTab();

  @override
  State<_LevelsTab> createState() => _LevelsTabState();
}

class _LevelsTabState extends State<_LevelsTab> {
  String _search = '';
  String _filter = 'all'; // all, low, out
  String _category = 'All';
  DateTime? _lastCount;
  bool _countChecked = false;

  @override
  void initState() {
    super.initState();
    _checkLastCount();
  }

  /// When the last posted stock-take was, so the screen can remind the owner to count.
  Future<void> _checkLastCount() async {
    try {
      final rows = await Supabase.instance.client
          .from('stocktakes')
          .select('created_at')
          .eq('status', 'posted')
          .order('created_at', ascending: false)
          .limit(1);
      if (rows.isNotEmpty) _lastCount = DateTime.tryParse('${rows.first['created_at']}')?.toLocal();
      _countChecked = true;
    } catch (_) {}
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SyncService.instance,
      builder: (context, _) {
        final all = _items().where((i) => i['active'] != false).toList();
        final cats = ['All', ...{for (final i in all) '${i['category']}'}..remove('null')];
        if (!cats.contains(_category)) _category = 'All';
        bool low(Map<String, dynamic> i) =>
            n(i['min_level']) > 0 && n(i['qty_on_hand']) <= n(i['min_level']);
        final shown = all.where((i) {
          if (_category != 'All' && i['category'] != _category) return false;
          if (_search.isNotEmpty &&
              !'${i['name']}'.toLowerCase().contains(_search.toLowerCase())) {
            return false;
          }
          if (_filter == 'low') return low(i);
          if (_filter == 'out') return n(i['qty_on_hand']) <= 0;
          return true;
        }).toList();
        final value = all.fold<double>(0, (s, i) => s + n(i['qty_on_hand']) * n(i['avg_cost']));
        void open(Map<String, dynamic> i) => showStockItemView(context, i,
            onAdjust: () => _adjust(context, i),
            onEdit: () => _editItem(context, i),
            onDelete: AuthService.instance.role == 'admin' ? () => _deleteItem(context, i) : null);

        Widget chip(String key, String label) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                  label: Text(label),
                  selected: _filter == key,
                  onSelected: (_) => setState(() => _filter = key)),
            );

        final today = DateTime.now();
        final soon = DateTime(today.year, today.month, today.day + 3);
        final posted = {for (final g in LocalStore.rows('grvs')) if (g['status'] == 'posted') g['id']: g};
        final expiring = LocalStore.rows('grv_lines').where((l) {
          final d = DateTime.tryParse('${l['expiry_date'] ?? ''}');
          final it = LocalStore.row('stock_items', l['stock_item_id']);
          return d != null &&
              posted.containsKey(l['grv_id']) &&
              !d.isAfter(soon) &&
              d.isAfter(today.subtract(const Duration(days: 7))) &&
              n(it?['qty_on_hand']) > 0;
        }).toList()
          ..sort((a, b) => '${a['expiry_date']}'.compareTo('${b['expiry_date']}'));
        final negative = all.where((i) => n(i['qty_on_hand']) < 0).toList();
        return ListView(padding: const EdgeInsets.all(20), children: [
          if (expiring.isNotEmpty)
            Card(
              color: const Color(0xFFFFF4D6),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Use first: expiring within 3 days',
                      style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF7A4B00))),
                  for (final l in expiring.take(8))
                    Text(
                        '${LocalStore.row('stock_items', l['stock_item_id'])?['name']} · expires ${l['expiry_date']} '
                        '(${posted[l['grv_id']]?['grv_no'] ?? ''}, received ${_qty(l['received_qty'])})'),
                ]),
              ),
            ),
          if (_countChecked && (_lastCount == null || DateTime.now().difference(_lastCount!).inDays >= 7))
            Card(
              color: const Color(0xFFFFF4D6),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                    _lastCount == null
                        ? 'No stock-take has been posted yet. Count the stock to see what is missing or wasted (Stock-take tab).'
                        : 'Last stock-take was ${DateTime.now().difference(_lastCount!).inDays} days ago. Count the stock weekly so losses show up early (Stock-take tab).',
                    style: const TextStyle(color: Color(0xFF7A4B00), fontWeight: FontWeight.w600)),
              ),
            ),
          if (all.any(low))
            Card(
              color: const Color(0xFFFDE7EA),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                    'Running low (${all.where(low).length}): ${all.where(low).take(10).map((i) => i['name']).join(', ')}${all.where(low).length > 10 ? ' ...' : ''}. Use the Low filter, then order from the Purchase orders tab.',
                    style: const TextStyle(color: Brand.red, fontWeight: FontWeight.w600)),
              ),
            ),
          if (negative.isNotEmpty)
            Card(
              color: const Color(0xFFFDE7EA),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                    'Below zero: ${negative.map((i) => i['name']).join(', ')}. More was sold than was received, so a delivery was not captured or a recipe is wrong. Do a stock count.',
                    style: const TextStyle(color: Brand.red, fontWeight: FontWeight.w600)),
              ),
            ),
          Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: 260,
              child: TextField(
                onChanged: (v) => setState(() => _search = v),
                decoration: const InputDecoration(
                    hintText: 'Search stock items', prefixIcon: Icon(Icons.search), isDense: true),
              ),
            ),
            chip('all', 'All · ${all.length}'),
            chip('low', 'Low · ${all.where(low).length}'),
            chip('out', 'Out · ${all.where((i) => n(i['qty_on_hand']) <= 0).length}'),
            DropdownButton<String>(
              value: _category,
              underline: const SizedBox(),
              items: [for (final c in cats) DropdownMenuItem(value: c, child: Text(c))],
              onChanged: (v) => setState(() => _category = v ?? 'All'),
            ),
            FilledButton.icon(
              onPressed: () => _editItem(context, null),
              icon: const Icon(Icons.add),
              label: const Text('Add stock item'),
            ),
          ]),
          const SizedBox(height: 8),
          Text('Stock value ${money(value)} (average cost, excl. VAT)',
              style: const TextStyle(color: Brand.muted)),
          const SizedBox(height: 8),
          Card(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: 24,
                columns: const [
                  DataColumn(label: Text('Item')),
                  DataColumn(label: Text('Category')),
                  DataColumn(label: Text('On hand'), numeric: true),
                  DataColumn(label: Text('Minimum'), numeric: true),
                  DataColumn(label: Text('Avg cost'), numeric: true),
                  DataColumn(label: Text('Value'), numeric: true),
                  DataColumn(label: Text('Supplier')),
                  DataColumn(label: Text('')),
                ],
                rows: [
                  for (final i in shown)
                    DataRow(cells: [
                      DataCell(Text('${i['name']}', style: const TextStyle(fontWeight: FontWeight.w700, color: Brand.navy, decoration: TextDecoration.underline)),
                          onTap: () => open(i)),
                      DataCell(Text('${i['category'] ?? ''}'), onTap: () => open(i)),
                      DataCell(Text('${_qty(i['qty_on_hand'])} ${i['unit']}',
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: n(i['qty_on_hand']) <= 0
                                  ? Brand.red
                                  : (low(i) ? Brand.amber : Brand.navy))),
                          onTap: () => open(i)),
                      DataCell(Text(_qty(i['min_level'])), onTap: () => open(i)),
                      DataCell(Text(money(n(i['avg_cost']))), onTap: () => open(i)),
                      DataCell(Text(money(n(i['qty_on_hand']) * n(i['avg_cost']))), onTap: () => open(i)),
                      DataCell(Text(_supplierName(i['supplier_id'])), onTap: () => open(i)),
                      DataCell(Row(children: [
                        TextButton(onPressed: () => open(i), child: const Text('View')),
                        TextButton(onPressed: () => _adjust(context, i), child: const Text('Adjust')),
                        TextButton(onPressed: () => _editItem(context, i), child: const Text('Edit')),
                        if (AuthService.instance.role == 'admin')
                          TextButton(
                              style: TextButton.styleFrom(foregroundColor: Brand.red),
                              onPressed: () => _deleteItem(context, i),
                              child: const Text('Delete')),
                      ])),
                    ]),
                ],
              ),
            ),
          ),
        ]);
      },
    );
  }

  /// Admin only. An item with no history is removed. One with history is hidden, because the record of what moved is never erased.
  Future<void> _deleteItem(BuildContext context, Map<String, dynamic> item) async {
    final onHand = n(item['qty_on_hand']);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${item['name']}?'),
        content: Text([
          if (onHand != 0) 'There are still ${_qty(onHand)} ${item['unit']} on hand, worth ${money(onHand * n(item['avg_cost']))}.',
          'If this item has never been received, sold or counted it is removed for good.',
          'If it has history, it is hidden from the stock list and the history is kept.',
          'It cannot be deleted while a recipe or special request uses it.',
        ].join('\n\n')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Brand.red, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (go != true || !context.mounted) return;
    String? result;
    final ok = await _online(context, () async {
      result = '${await _db.rpc('delete_stock_item', params: {'p_id': item['id']})}';
    });
    if (ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result == 'archived'
              ? '${item['name']} has history, so it is hidden from the list and the history is kept.'
              : '${item['name']} deleted.')));
    }
  }

  /// Stock take, waste or manual correction. Recorded as a movement so there is a history.
  Future<void> _adjust(BuildContext context, Map<String, dynamic> item) async {
    String kind = 'stocktake';
    final qtyC = TextEditingController();
    final noteC = TextEditingController();
    final unit = '${item['unit']}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final entered = double.tryParse(qtyC.text.replaceAll(',', '.'));
        String preview = '';
        if (entered != null) {
          final on = n(item['qty_on_hand']).toDouble();
          final delta = kind == 'stocktake'
              ? entered - on
              : (kind == 'waste' ? -entered.abs() : entered);
          preview = 'Stock will change by ${delta >= 0 ? '+' : ''}${_qty(delta)} $unit to ${_qty(on + delta)} $unit.';
        }
        return AlertDialog(
          title: Text('Adjust ${item['name']}'),
          content: SizedBox(
            width: 400,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('On hand now: ${_qty(item['qty_on_hand'])} $unit'),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'stocktake', label: Text('Stock count')),
                  ButtonSegment(value: 'waste', label: Text('Waste')),
                  ButtonSegment(value: 'adjustment', label: Text('Correction')),
                ],
                selected: {kind},
                onSelectionChanged: (v) => set(() {
                  kind = v.first;
                  qtyC.clear();
                }),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: qtyC,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                onChanged: (_) => set(() {}),
                decoration: InputDecoration(
                    labelText: kind == 'stocktake'
                        ? 'Counted quantity ($unit)'
                        : (kind == 'waste' ? 'Quantity wasted ($unit)' : 'Change (+ or -, $unit)')),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: noteC,
                onChanged: (_) => set(() {}),
                decoration: const InputDecoration(labelText: 'Reason (required)'),
              ),
              const SizedBox(height: 8),
              Text(preview, style: const TextStyle(color: Brand.muted)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: entered == null || noteC.text.trim().isEmpty ? null : () => Navigator.pop(ctx, true),
              child: const Text('Save'),
            ),
          ],
        );
      }),
    );
    if (ok != true) return;
    final entered = double.parse(qtyC.text.replaceAll(',', '.'));
    final on = n(item['qty_on_hand']).toDouble();
    final delta = kind == 'stocktake' ? entered - on : (kind == 'waste' ? -entered.abs() : entered);
    if (delta == 0) return;
    if (!context.mounted) return;
    await _online(context, () async {
      await _db.from('stock_movements').insert({
        'stock_item_id': item['id'],
        'qty_change': delta,
        'reason': kind,
        'note': noteC.text.trim(),
      });
    });
  }

  Future<void> _editItem(BuildContext context, Map<String, dynamic>? item) async {
    final name = TextEditingController(text: '${item?['name'] ?? ''}');
    final category = TextEditingController(text: '${item?['category'] ?? ''}');
    final unit = TextEditingController(text: '${item?['unit'] ?? ''}');
    final min = TextEditingController(text: item == null ? '' : _qty(item['min_level']));
    final cost = TextEditingController(text: item == null ? '' : '${n(item['avg_cost'])}');
    String? supplier = item?['supplier_id'] as String?;
    String vatType = '${item?['vat_type'] ?? 'standard'}';
    bool active = item?['active'] != false;
    final packUnit = TextEditingController(text: '${item?['purchase_unit'] ?? ''}');
    final packFactor = TextEditingController(
        text: item == null || n(item['purchase_factor']) <= 1 ? '' : _qty(item['purchase_factor']));
    final cats = {for (final i in _items()) if ('${i['category'] ?? ''}'.isNotEmpty) '${i['category']}'}.toList()..sort();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        double? parseNum(String t) => double.tryParse(t.trim().replaceAll(',', '.'));
        final minBad = min.text.trim().isNotEmpty && parseNum(min.text) == null;
        final costBad = cost.text.trim().isNotEmpty && parseNum(cost.text) == null;
        final packBad = packFactor.text.trim().isNotEmpty && parseNum(packFactor.text) == null;
        final unitBad = unit.text.trim().contains(RegExp(r'[0-9]'));
        final valid = name.text.trim().isNotEmpty &&
            category.text.trim().isNotEmpty &&
            unit.text.trim().isNotEmpty &&
            !unitBad &&
            parseNum(min.text) != null &&
            !costBad &&
            !packBad;
        return AlertDialog(
          title: Text(item == null ? 'Add stock item' : 'Edit ${item['name']}'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(controller: name, onChanged: (_) => set(() {}), decoration: const InputDecoration(labelText: 'Name')),
                const SizedBox(height: 8),
                Autocomplete<String>(
                  initialValue: TextEditingValue(text: category.text),
                  optionsBuilder: (v) => cats.where((c) => c.toLowerCase().contains(v.text.toLowerCase())),
                  onSelected: (v) => set(() => category.text = v),
                  fieldViewBuilder: (ctx, c, f, _) => TextField(
                    controller: c,
                    focusNode: f,
                    onChanged: (v) => set(() => category.text = v),
                    decoration: const InputDecoration(labelText: 'Category (for example Proteins, Breads)'),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(controller: unit, onChanged: (_) => set(() {}),
                    decoration: InputDecoration(
                        labelText: 'Unit (kg, g, pc, l, ml)',
                        errorText: unitBad ? 'Letters only, for example kg or g. Put the amount in the other boxes.' : null)),
                const SizedBox(height: 8),
                TextField(
                    controller: min,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => set(() {}),
                    decoration: InputDecoration(
                        labelText: 'Minimum level (reorder when at or below)',
                        suffixText: unit.text,
                        errorText: minBad || min.text.trim().isEmpty ? 'Type a number only, for example 5 (the unit is set above)' : null)),
                if (item == null) ...[
                  const SizedBox(height: 8),
                  TextField(
                      controller: cost,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) => set(() {}),
                      decoration: InputDecoration(
                          labelText: 'Cost per unit, excl. VAT (optional)',
                          errorText: costBad ? 'Numbers only, for example 0.024' : null)),
                ],
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: vatType,
                  decoration: const InputDecoration(
                      labelText: 'VAT when you buy it',
                      helperText: 'Fresh vegetables and fruit, milk, eggs, rice, flour and cooking oil are zero-rated'),
                  items: const [
                    DropdownMenuItem(value: 'standard', child: Text('Standard rated (15%)')),
                    DropdownMenuItem(value: 'zero', child: Text('Zero-rated (0%)')),
                    DropdownMenuItem(value: 'exempt', child: Text('No VAT (supplier not a VAT vendor)')),
                  ],
                  onChanged: (v) => set(() => vatType = v ?? 'standard'),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String?>(
                  initialValue: supplier,
                  decoration: const InputDecoration(labelText: 'Usual supplier'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('None')),
                    for (final s in _suppliers()) DropdownMenuItem(value: s['id'] as String, child: Text('${s['name']}')),
                  ],
                  onChanged: (v) => set(() => supplier = v),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: TextField(
                        controller: packUnit,
                        decoration: const InputDecoration(labelText: 'Bought as (optional)', hintText: 'case, box, bag')),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                        controller: packFactor,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        onChanged: (_) => set(() {}),
                        decoration: InputDecoration(
                            labelText: 'Units in one',
                            suffixText: unit.text,
                            errorText: packBad ? 'Numbers only' : null)),
                  ),
                ]),
                const Text('For example a case of 24 cans: when receiving stock you can enter cases.',
                    style: TextStyle(color: Brand.muted, fontSize: 12)),
                SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Active'),
                    value: active,
                    onChanged: (v) => set(() => active = v)),
                if (item == null)
                  const Text('Opening stock is added by receiving it (GRV) or by a stock count.',
                      style: TextStyle(color: Brand.muted, fontSize: 12)),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: valid ? () => Navigator.pop(ctx, true) : null, child: const Text('Save')),
          ],
        );
      }),
    );
    if (ok != true || !context.mounted) return;
    final row = <String, dynamic>{
      if (item != null) 'id': item['id'],
      'name': name.text.trim(),
      'category': category.text.trim(),
      'unit': unit.text.trim(),
      'min_level': double.parse(min.text.replaceAll(',', '.')),
      'supplier_id': supplier,
      'vat_type': vatType,
      'active': active,
      'purchase_unit': packUnit.text.trim().isEmpty ? null : packUnit.text.trim(),
      'purchase_factor': (double.tryParse(packFactor.text.replaceAll(',', '.')) ?? 1) > 0
          ? (double.tryParse(packFactor.text.replaceAll(',', '.')) ?? 1)
          : 1,
      if (item == null) 'avg_cost': double.tryParse(cost.text.replaceAll(',', '.')) ?? 0,
    };
    await _online(context, () async {
      if (item == null) {
        await _db.from('stock_items').insert(row);
      } else {
        await _db.from('stock_items').update(row).eq('id', item['id']);
      }
    });
  }
}

// ============================================================================
// Receive stock (GRV)
// ============================================================================

class _GrvTab extends StatelessWidget {
  const _GrvTab();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SyncService.instance,
      builder: (context, _) {
        final list = LocalStore.rows('grvs').toList()
          ..sort((a, b) {
            final ad = a['status'] == 'draft' ? 0 : 1;
            final bd = b['status'] == 'draft' ? 0 : 1;
            if (ad != bd) return ad - bd;
            return '${b['received_on']}${b['grv_no']}'.compareTo('${a['received_on']}${a['grv_no']}');
          });
        return ListView(padding: const EdgeInsets.all(20), children: [
          Row(children: [
            const Expanded(
                child: Text('Goods received vouchers record every delivery. Posting one adds the stock and updates the average cost.',
                    style: TextStyle(color: Brand.muted))),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: () => _open(context, null),
              icon: const Icon(Icons.add),
              label: const Text('Receive stock'),
            ),
          ]),
          const SizedBox(height: 12),
          Card(
            child: list.isEmpty
                ? const Padding(padding: EdgeInsets.all(24), child: Text('No deliveries recorded yet.'))
                : Column(children: [
                    for (final g in list)
                      ListTile(
                        onTap: () => _open(context, g),
                        title: Text('${g['grv_no']} · ${_supplierName(g['supplier_id'])}',
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(
                            '${g['received_on']}${('${g['delivery_note'] ?? ''}').isEmpty ? '' : ' · Delivery note ${g['delivery_note']}'}'),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          if (g['status'] == 'posted') Text(money(n(g['total'])), style: const TextStyle(fontWeight: FontWeight.w700)),
                          const SizedBox(width: 12),
                          Chip(
                            label: Text(const {'posted': 'Posted', 'reversed': 'Reversed'}[g['status']] ?? 'Draft'),
                            backgroundColor: g['status'] == 'posted'
                                ? const Color(0xFFDDF3E6)
                                : const Color(0xFFFFF1CC),
                          ),
                        ]),
                      ),
                  ]),
          ),
        ]);
      },
    );
  }

  Future<void> _open(BuildContext context, Map<String, dynamic>? grv) async {
    await Navigator.of(context).push(MaterialPageRoute(
        fullscreenDialog: true, builder: (_) => GrvEditor(grv: grv)));
  }
}

class _GrvLine {
  _GrvLine({required this.itemId, String ordered = '', String received = '', String cost = '', this.expiry})
      : ordered = TextEditingController(text: ordered),
        received = TextEditingController(text: received),
        cost = TextEditingController(text: cost);
  final String itemId;
  final TextEditingController ordered;
  final TextEditingController received;
  final TextEditingController cost;
  DateTime? expiry;

  final packs = TextEditingController();
  final packCost = TextEditingController();
  double get recQty => double.tryParse(received.text.replaceAll(',', '.')) ?? 0;
  double get unitCost => double.tryParse(cost.text.replaceAll(',', '.')) ?? 0;
  double get total => round2(recQty * unitCost);
}

class GrvEditor extends StatefulWidget {
  const GrvEditor({this.grv});
  final Map<String, dynamic>? grv;

  @override
  State<GrvEditor> createState() => GrvEditorState();
}

class GrvEditorState extends State<GrvEditor> {
  /// Posted and reversed deliveries can no longer be edited.
  late final bool _posted = widget.grv != null && widget.grv!['status'] != 'draft';
  bool get _reversed => widget.grv?['status'] == 'reversed';
  String? _supplier;
  final _note = TextEditingController();
  DateTime _on = DateTime.now();
  final List<_GrvLine> _lines = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final g = widget.grv;
    if (g != null) {
      _supplier = g['supplier_id'] as String?;
      _note.text = '${g['delivery_note'] ?? ''}';
      _on = DateTime.tryParse('${g['received_on']}') ?? DateTime.now();
      for (final l in LocalStore.rows('grv_lines').where((l) => l['grv_id'] == g['id'])) {
        _lines.add(_GrvLine(
          itemId: l['stock_item_id'] as String,
          ordered: l['ordered_qty'] == null ? '' : _qty(l['ordered_qty']),
          received: _qty(l['received_qty']),
          cost: '${n(l['unit_cost'])}',
          expiry: l['expiry_date'] == null ? null : DateTime.tryParse('${l['expiry_date']}'),
        ));
      }
    }
  }

  Map<String, dynamic>? _item(String id) {
    for (final i in LocalStore.rows('stock_items')) {
      if (i['id'] == id) return i;
    }
    return null;
  }

  double get _subtotal => _lines.fold<double>(0, (s, l) => s + l.total);

  String _nextNo() {
    var max = 0;
    for (final g in LocalStore.rows('grvs')) {
      final m = RegExp(r'(\d+)$').firstMatch('${g['grv_no']}');
      if (m != null) {
        final v = int.parse(m.group(1)!);
        if (v > max) max = v;
      }
    }
    return 'GRV-${(max + 1).toString().padLeft(6, '0')}';
  }

  Future<void> _addLine() async {
    final used = _lines.map((l) => l.itemId).toSet();
    final all = _items().where((i) => i['active'] != false && !used.contains(i['id'])).toList();
    // The chosen supplier's items first.
    all.sort((a, b) {
      final am = a['supplier_id'] == _supplier ? 0 : 1;
      final bm = b['supplier_id'] == _supplier ? 0 : 1;
      return am != bm ? am - bm : '${a['name']}'.compareTo('${b['name']}');
    });
    var q = '';
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final shown = all.where((i) => '${i['name']}'.toLowerCase().contains(q.toLowerCase())).toList();
        return AlertDialog(
          title: const Text('Add item to this delivery'),
          content: SizedBox(
            width: 420,
            height: 420,
            child: Column(children: [
              TextField(
                autofocus: true,
                onChanged: (v) => set(() => q = v),
                decoration: const InputDecoration(hintText: 'Search stock items', prefixIcon: Icon(Icons.search)),
              ),
              Expanded(
                child: ListView(children: [
                  for (final i in shown)
                    ListTile(
                      dense: true,
                      title: Text('${i['name']}'),
                      subtitle: Text('${_supplierName(i['supplier_id'])} · on hand ${_qty(i['qty_on_hand'])} ${i['unit']}'),
                      onTap: () => Navigator.pop(ctx, i),
                    ),
                ]),
              ),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
        );
      }),
    );
    if (picked == null) return;
    setState(() => _lines.add(_GrvLine(
        itemId: picked['id'] as String,
        cost: n(picked['avg_cost']) > 0 ? '${n(picked['avg_cost'])}' : '')));
  }

  String? _problem() {
    if (_supplier == null) return 'Choose the supplier.';
    if (_lines.isEmpty) return 'Add at least one item.';
    for (final l in _lines) {
      if (l.received.text.trim().isEmpty || double.tryParse(l.received.text.replaceAll(',', '.')) == null) {
        return 'Enter the received quantity for ${_item(l.itemId)?['name']}.';
      }
      if (l.recQty < 0) return 'Quantities cannot be negative.';
      if (l.recQty > 0 && l.unitCost <= 0) {
        return 'Enter the cost per unit for ${_item(l.itemId)?['name']}.';
      }
    }
    return null;
  }

  /// Saves the delivery as a draft, replacing its lines.
  Future<String> _saveDraft() async {
    final id = widget.grv?['id'] as String? ?? LocalStore.newId();
    final head = {
      'id': id,
      if (widget.grv == null) 'grv_no': _nextNo(),
      'supplier_id': _supplier,
      'delivery_note': _note.text.trim().isEmpty ? null : _note.text.trim(),
      'received_on': _date(_on),
      if (widget.grv == null) 'status': 'draft',
    };
    if (widget.grv == null) {
      await _db.from('grvs').insert(head);
    } else {
      // An upsert would fail here: it checks grv_no before it notices the row already exists.
      await _db.from('grvs').update(head).eq('id', id);
    }
    await _db.from('grv_lines').delete().eq('grv_id', id);
    if (_lines.isNotEmpty) {
      await _db.from('grv_lines').insert([
        for (final l in _lines)
          {
            'grv_id': id,
            'stock_item_id': l.itemId,
            'ordered_qty': double.tryParse(l.ordered.text.replaceAll(',', '.')),
            'received_qty': l.recQty,
            'unit_cost': l.unitCost,
            'expiry_date': l.expiry == null ? null : _date(l.expiry!),
          }
      ]);
    }
    return id;
  }

  Future<void> _save({required bool post}) async {
    final problem = _problem();
    if (problem != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    if (post) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Post this delivery?'),
          content: Text(
              '${_lines.length} items worth ${money(_subtotal)} excl. VAT will be added to stock and the average cost updated. A posted delivery cannot be edited.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not yet')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Post and add to stock')),
          ],
        ),
      );
      if (go != true) return;
    }
    setState(() => _busy = true);
    final ok = await _online(context, () async {
      final id = await _saveDraft();
      if (post) await _db.rpc('post_grv', params: {'p_grv_id': id});
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(post ? 'Delivery posted. Stock updated.' : 'Draft saved.')));
    }
  }

  /// Undo a posted delivery (wrong supplier, returned goods): takes the stock back out.
  Future<void> _reverse() async {
    final c = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Reverse this delivery?'),
          content: SizedBox(
            width: 400,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('The received stock is taken back out and the delivery no longer counts as a purchase. Use it for a delivery captured by mistake or returned to the supplier.'),
              const SizedBox(height: 10),
              TextField(controller: c, autofocus: true, onChanged: (_) => set(() {}), decoration: const InputDecoration(labelText: 'Reason (required)')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Brand.red, foregroundColor: Colors.white),
                onPressed: c.text.trim().isEmpty ? null : () => Navigator.pop(ctx, c.text.trim()),
                child: const Text('Reverse')),
          ],
        ),
      ),
    );
    if (reason == null || !mounted) return;
    final ok = await _online(context, () async {
      await _db.rpc('reverse_grv', params: {'p_grv_id': widget.grv!['id'], 'p_reason': reason});
    });
    if (ok && mounted) Navigator.pop(context);
  }

  Future<void> _delete() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this draft?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Brand.red, foregroundColor: Colors.white),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (go != true) return;
    final ok = await _online(context, () async {
      await _db.from('grvs').delete().eq('id', widget.grv!['id']);
    });
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final rate = vatRate();
    // VAT only on standard-rated items (fresh produce, milk and so on carry none).
    final vat = round2(_lines
            .where((l) => (_item(l.itemId)?['vat_type'] ?? 'standard') == 'standard')
            .fold<double>(0, (s, l) => s + l.total) *
        rate /
        100);
    final isNew = widget.grv == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? 'Receive stock' : '${widget.grv!['grv_no']}${_reversed ? ' (reversed)' : (_posted ? ' (posted)' : ' (draft)')}'),
        actions: [
          if (!isNew && !_posted)
            IconButton(onPressed: _busy ? null : _delete, icon: const Icon(Icons.delete_outline), tooltip: 'Delete draft'),
          if (_posted && !_reversed && const ['admin', 'supervisor'].contains(AuthService.instance.role))
            TextButton(
                onPressed: _busy ? null : _reverse,
                child: const Text('Reverse delivery', style: TextStyle(color: Colors.white))),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Wrap(spacing: 16, runSpacing: 16, children: [
          SizedBox(
            width: 280,
            child: DropdownButtonFormField<String>(
              initialValue: _supplier,
              decoration: const InputDecoration(labelText: 'Supplier'),
              items: [for (final s in _suppliers()) DropdownMenuItem(value: s['id'] as String, child: Text('${s['name']}'))],
              onChanged: _posted ? null : (v) => setState(() => _supplier = v),
            ),
          ),
          SizedBox(
            width: 220,
            child: TextField(
              controller: _note,
              enabled: !_posted,
              decoration: const InputDecoration(labelText: 'Delivery note / invoice no.'),
            ),
          ),
          SizedBox(
            width: 200,
            child: InkWell(
              onTap: _posted
                  ? null
                  : () async {
                      final d = await showDatePicker(
                          context: context,
                          initialDate: _on,
                          firstDate: DateTime.now().subtract(const Duration(days: 365)),
                          lastDate: DateTime.now());
                      if (d != null) setState(() => _on = d);
                    },
              child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Date received'), child: Text(_date(_on))),
            ),
          ),
        ]),
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Expanded(child: Text('Items received', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
                if (!_posted)
                  OutlinedButton.icon(onPressed: _addLine, icon: const Icon(Icons.add), label: const Text('Add item')),
              ]),
              const SizedBox(height: 8),
              if (_lines.isEmpty)
                const Padding(padding: EdgeInsets.all(16), child: Text('No items yet. Press Add item.', style: TextStyle(color: Brand.muted))),
              for (var i = 0; i < _lines.length; i++) _lineRow(i),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('Subtotal ${money(_subtotal)}'),
            Text('VAT ${rate.toStringAsFixed(rate == rate.roundToDouble() ? 0 : 1)}% ${money(vat)}'),
            Text('Total ${money(_subtotal + vat)}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
          ]),
        ),
        const SizedBox(height: 20),
        if (!_posted)
          Wrap(spacing: 12, runSpacing: 12, children: [
            OutlinedButton(onPressed: _busy ? null : () => _save(post: false), child: const Text('Save draft')),
            FilledButton(
                onPressed: _busy ? null : () => _save(post: true),
                child: Text(_busy ? 'Saving...' : 'Post and add to stock')),
          ]),
        if (!_posted)
          const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Saving and posting need an internet connection.', style: TextStyle(color: Brand.muted, fontSize: 12))),
      ]),
    );
  }

  Widget _lineRow(int i) {
    final l = _lines[i];
    final item = _item(l.itemId);
    final unit = '${item?['unit'] ?? ''}';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: Brand.border))),
      child: Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: 200,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${item?['name'] ?? 'Unknown'}', style: const TextStyle(fontWeight: FontWeight.w700)),
            Text('On hand ${_qty(item?['qty_on_hand'])} $unit', style: const TextStyle(color: Brand.muted, fontSize: 12)),
          ]),
        ),
        if (n(item?['purchase_factor']) > 1) ...[
          SizedBox(
              width: 120,
              child: TextField(
                  controller: l.packs,
                  enabled: !_posted,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (v) => setState(() {
                    final p = double.tryParse(v.replaceAll(',', '.'));
                    if (p != null) l.received.text = _qty(p * n(item?['purchase_factor']));
                  }),
                  decoration: InputDecoration(
                      labelText: '${item?['purchase_unit'] ?? 'Packs'} received',
                      helperText: '1 = ${_qty(item?['purchase_factor'])} $unit',
                      isDense: true))),
          SizedBox(
              width: 120,
              child: TextField(
                  controller: l.packCost,
                  enabled: !_posted,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (v) => setState(() {
                    final c = double.tryParse(v.replaceAll(',', '.'));
                    if (c != null) {
                      l.cost.text = (c / n(item?['purchase_factor'])).toStringAsFixed(4);
                    }
                  }),
                  decoration: InputDecoration(
                      labelText: 'Cost per ${item?['purchase_unit'] ?? 'pack'}', prefixText: 'R', isDense: true))),
        ],
        SizedBox(
            width: 100,
            child: TextField(
                controller: l.ordered,
                enabled: !_posted,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: 'Ordered', suffixText: unit, isDense: true))),
        SizedBox(
            width: 110,
            child: TextField(
                controller: l.received,
                enabled: !_posted,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: 'Received', suffixText: unit, isDense: true))),
        SizedBox(
            width: 120,
            child: TextField(
                controller: l.cost,
                enabled: !_posted,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: 'Cost per $unit', prefixText: 'R', isDense: true))),
        SizedBox(
          width: 150,
          child: InkWell(
            onTap: _posted
                ? null
                : () async {
                    final d = await showDatePicker(
                        context: context,
                        initialDate: l.expiry ?? DateTime.now().add(const Duration(days: 7)),
                        firstDate: DateTime.now().subtract(const Duration(days: 30)),
                        lastDate: DateTime.now().add(const Duration(days: 365 * 3)));
                    if (d != null) setState(() => l.expiry = d);
                  },
            child: InputDecorator(
                decoration: const InputDecoration(labelText: 'Expiry (optional)', isDense: true),
                child: Text(l.expiry == null ? '-' : _date(l.expiry!))),
          ),
        ),
        SizedBox(
            width: 90,
            child: Text(money(l.total), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700))),
        if (!_posted)
          IconButton(
              onPressed: () => setState(() => _lines.removeAt(i)),
              icon: const Icon(Icons.close),
              tooltip: 'Remove'),
      ]),
    );
  }
}

// ============================================================================
// Suppliers
// ============================================================================

class _SuppliersTab extends StatelessWidget {
  const _SuppliersTab();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SyncService.instance,
      builder: (context, _) {
        final list = LocalStore.rows('suppliers').toList()
          ..sort((a, b) => '${a['name']}'.toLowerCase().compareTo('${b['name']}'.toLowerCase()));
        return ListView(padding: const EdgeInsets.all(20), children: [
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
                onPressed: () => _edit(context, null),
                icon: const Icon(Icons.add),
                label: const Text('Add supplier')),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(children: [
              for (final s in list)
                ListTile(
                  title: Text('${s['name']}${s['active'] == false ? ' (inactive)' : ''}',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text([
                    if (('${s['contact_person'] ?? ''}').isNotEmpty) '${s['contact_person']}',
                    if (('${s['phone'] ?? ''}').isNotEmpty) '${s['phone']}',
                    if (('${s['email'] ?? ''}').isNotEmpty) '${s['email']}',
                  ].join(' · ')),
                  trailing: TextButton(onPressed: () => _edit(context, s), child: const Text('Edit')),
                ),
            ]),
          ),
        ]);
      },
    );
  }

  Future<void> _edit(BuildContext context, Map<String, dynamic>? s) async {
    final name = TextEditingController(text: '${s?['name'] ?? ''}');
    final contact = TextEditingController(text: '${s?['contact_person'] ?? ''}');
    final phone = TextEditingController(text: '${s?['phone'] ?? ''}');
    final email = TextEditingController(text: '${s?['email'] ?? ''}');
    bool active = s?['active'] != false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(s == null ? 'Add supplier' : 'Edit supplier'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(controller: name, onChanged: (_) => set(() {}), decoration: const InputDecoration(labelText: 'Supplier name')),
                const SizedBox(height: 8),
                TextField(controller: contact, decoration: const InputDecoration(labelText: 'Contact person')),
                const SizedBox(height: 8),
                TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone')),
                const SizedBox(height: 8),
                TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email')),
                SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Active'),
                    value: active,
                    onChanged: (v) => set(() => active = v)),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
                onPressed: name.text.trim().isEmpty ? null : () => Navigator.pop(ctx, true),
                child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    String? clean(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    final row = {
      'name': name.text.trim(),
      'contact_person': clean(contact),
      'phone': clean(phone),
      'email': clean(email),
      'active': active,
    };
    await _online(context, () async {
      if (s == null) {
        await _db.from('suppliers').insert(row);
      } else {
        await _db.from('suppliers').update(row).eq('id', s['id']);
      }
    });
  }
}
