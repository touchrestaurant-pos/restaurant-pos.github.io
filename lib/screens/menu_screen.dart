import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/local_store.dart';
import '../data/repo.dart';
import '../data/sync_service.dart';
import '../theme.dart';

SupabaseClient get _db => Supabase.instance.client;

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
          content: Text('Menu changes need an internet connection. Connect and try again.')));
    }
  }
  return false;
}

String _qty(dynamic v) {
  final x = n(v);
  return x == x.roundToDouble() ? x.toInt().toString() : x.toString();
}

Map<String, dynamic>? _stockItem(dynamic id) {
  for (final i in LocalStore.rows('stock_items')) {
    if (i['id'] == id) return i;
  }
  return null;
}

/// Ingredient cost of one portion, from the recipe and current average costs.
double _portionCost(String productId) {
  var total = 0.0;
  for (final l in LocalStore.rows('recipe_lines').where((l) => l['product_id'] == productId)) {
    total += n(l['qty']) * n(_stockItem(l['stock_item_id'])?['avg_cost']);
  }
  return total;
}

/// Admin: menu items, prices, categories and the recipe (ingredients) behind each product.
class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key});

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  String _cat = 'all';
  String _search = '';
  bool _showInactive = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SyncService.instance,
      builder: (context, _) {
        final cats = LocalStore.rows('categories').toList()
          ..sort((a, b) => n(a['sort_order']).compareTo(n(b['sort_order'])));
        final catName = {for (final c in cats) c['id']: '${c['name']}'};
        final canMake = Catalog.canMakeAll();
        final rate = vatRate();
        final products = LocalStore.rows('products').where((p) {
          if (!_showInactive && p['active'] == false) return false;
          if (_cat != 'all' && p['category_id'] != _cat) return false;
          if (_search.isNotEmpty && !'${p['name']}'.toLowerCase().contains(_search.toLowerCase())) {
            return false;
          }
          return true;
        }).toList()
          ..sort((a, b) {
            final c = '${catName[a['category_id']]}'.compareTo('${catName[b['category_id']]}');
            return c != 0 ? c : n(a['sort_order']).compareTo(n(b['sort_order']));
          });

        return ListView(padding: const EdgeInsets.all(20), children: [
          const Text('Menu and recipes',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Brand.navy)),
          const SizedBox(height: 4),
          const Text(
              'Prices include VAT. A recipe says how much of each ingredient one portion uses, so stock drops correctly when an item is sold.',
              style: TextStyle(color: Brand.muted)),
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            ChoiceChip(label: const Text('All'), selected: _cat == 'all', onSelected: (_) => setState(() => _cat = 'all')),
            for (final c in cats)
              GestureDetector(
                onLongPress: () => _editCategory(context, c),
                child: ChoiceChip(
                    label: Text('${c['name']}${c['active'] == false ? ' (off)' : ''}'),
                    selected: _cat == c['id'],
                    onSelected: (_) => setState(() => _cat = c['id'] as String)),
              ),
            ActionChip(
                avatar: const Icon(Icons.add, size: 16),
                label: const Text('Category'),
                onPressed: () => _editCategory(context, null)),
            if (_cat != 'all')
              TextButton(
                  onPressed: () => _editCategory(context, cats.firstWhere((c) => c['id'] == _cat)),
                  child: const Text('Rename / hide this category')),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: 240,
              child: TextField(
                onChanged: (v) => setState(() => _search = v),
                decoration: const InputDecoration(hintText: 'Search menu', prefixIcon: Icon(Icons.search), isDense: true),
              ),
            ),
            FilterChip(
                label: const Text('Show switched-off items'),
                selected: _showInactive,
                onSelected: (v) => setState(() => _showInactive = v)),
            FilledButton.icon(
                onPressed: cats.isEmpty ? null : () => _editProduct(context, null, cats),
                icon: const Icon(Icons.add),
                label: const Text('Add menu item')),
          ]),
          const SizedBox(height: 12),
          Card(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: 24,
                columns: const [
                  DataColumn(label: Text('Item')),
                  DataColumn(label: Text('Category')),
                  DataColumn(label: Text('Price'), numeric: true),
                  DataColumn(label: Text('Ingredient cost'), numeric: true),
                  DataColumn(label: Text('Margin'), numeric: true),
                  DataColumn(label: Text('Can make'), numeric: true),
                  DataColumn(label: Text('')),
                ],
                rows: [
                  for (final p in products)
                    () {
                      final id = p['id'] as String;
                      final price = n(p['price']).toDouble();
                      final net = price * 100 / (100 + rate);
                      final cost = _portionCost(id);
                      final hasRecipe = LocalStore.rows('recipe_lines').any((l) => l['product_id'] == id);
                      final margin = net <= 0 ? 0.0 : (net - cost) / net * 100;
                      final can = canMake[id];
                      return DataRow(cells: [
                        DataCell(Text('${p['name']}${p['active'] == false ? ' (off)' : ''}',
                            style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: p['active'] == false ? Brand.muted : null))),
                        DataCell(Text(catName[p['category_id']] ?? '')),
                        DataCell(Text(money(price))),
                        DataCell(Text(hasRecipe ? money(cost) : 'No recipe',
                            style: TextStyle(color: hasRecipe ? null : Brand.amber))),
                        DataCell(Text(hasRecipe ? '${margin.toStringAsFixed(1)}%' : '-',
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: !hasRecipe
                                    ? null
                                    : (margin < 55 ? Brand.red : (margin < 65 ? Brand.amber : Brand.green))))),
                        DataCell(Text(can == null ? '-' : '$can',
                            style: TextStyle(color: can != null && can <= 0 ? Brand.red : null))),
                        DataCell(Row(children: [
                          TextButton(onPressed: () => _editRecipe(context, p), child: const Text('Recipe')),
                          TextButton(onPressed: () => _editProduct(context, p, cats), child: const Text('Edit')),
                        ])),
                      ]);
                    }(),
                ],
              ),
            ),
          ),
          const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                  'Margin = (price excl. VAT minus ingredient cost) / price excl. VAT. Red is under 55%, amber under 65%. Long-press a category chip to rename it.',
                  style: TextStyle(color: Brand.muted, fontSize: 12))),
        ]);
      },
    );
  }

  // ---- categories ----------------------------------------------------------

  Future<void> _editCategory(BuildContext context, Map<String, dynamic>? c) async {
    final name = TextEditingController(text: '${c?['name'] ?? ''}');
    bool active = c?['active'] != false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(c == null ? 'Add category' : 'Edit category'),
          content: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: name,
                  autofocus: true,
                  onChanged: (_) => set(() {}),
                  decoration: const InputDecoration(labelText: 'Category name')),
              SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Show on the till'),
                  value: active,
                  onChanged: (v) => set(() => active = v)),
            ]),
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
    await _online(context, () async {
      if (c == null) {
        final max = LocalStore.rows('categories').fold<num>(0, (m, e) => n(e['sort_order']) > m ? n(e['sort_order']) : m);
        await _db.from('categories').insert({'name': name.text.trim(), 'active': active, 'sort_order': max + 1});
      } else {
        await _db.from('categories').update({'name': name.text.trim(), 'active': active}).eq('id', c['id']);
      }
    });
  }

  // ---- products ------------------------------------------------------------

  Future<void> _editProduct(
      BuildContext context, Map<String, dynamic>? p, List<Map<String, dynamic>> cats) async {
    final name = TextEditingController(text: '${p?['name'] ?? ''}');
    final desc = TextEditingController(text: '${p?['description'] ?? ''}');
    final price = TextEditingController(text: p == null ? '' : '${n(p['price'])}');
    String? cat = p?['category_id'] as String? ?? (_cat != 'all' ? _cat : cats.first['id'] as String);
    bool active = p?['active'] != false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final valid = name.text.trim().isNotEmpty &&
            cat != null &&
            (double.tryParse(price.text.replaceAll(',', '.')) ?? -1) >= 0;
        return AlertDialog(
          title: Text(p == null ? 'Add menu item' : 'Edit ${p['name']}'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(controller: name, autofocus: true, onChanged: (_) => set(() {}), decoration: const InputDecoration(labelText: 'Name')),
                const SizedBox(height: 8),
                TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description (optional)')),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: cat,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: [for (final c in cats) DropdownMenuItem(value: c['id'] as String, child: Text('${c['name']}'))],
                  onChanged: (v) => set(() => cat = v),
                ),
                const SizedBox(height: 8),
                TextField(
                    controller: price,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (_) => set(() {}),
                    decoration: const InputDecoration(labelText: 'Price including VAT', prefixText: 'R')),
                SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Available on the till'),
                    subtitle: const Text('Switch off for items that are not sold right now'),
                    value: active,
                    onChanged: (v) => set(() => active = v)),
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
    final row = {
      'name': name.text.trim(),
      'description': desc.text.trim().isEmpty ? null : desc.text.trim(),
      'category_id': cat,
      'price': double.parse(price.text.replaceAll(',', '.')),
      'active': active,
    };
    await _online(context, () async {
      if (p == null) {
        final max = LocalStore.rows('products').fold<num>(0, (m, e) => n(e['sort_order']) > m ? n(e['sort_order']) : m);
        await _db.from('products').insert({...row, 'sort_order': max + 1});
      } else {
        await _db.from('products').update(row).eq('id', p['id']);
      }
    });
  }

  Future<void> _editRecipe(BuildContext context, Map<String, dynamic> p) async {
    await showDialog<void>(context: context, builder: (_) => _RecipeDialog(product: p));
  }
}

class _RecipeRow {
  _RecipeRow(this.itemId, String qty) : qty = TextEditingController(text: qty);
  final String itemId;
  final TextEditingController qty;
  double get q => double.tryParse(qty.text.replaceAll(',', '.')) ?? 0;
}

/// Ingredients used by one portion of a product, with live cost and margin.
class _RecipeDialog extends StatefulWidget {
  const _RecipeDialog({required this.product});
  final Map<String, dynamic> product;

  @override
  State<_RecipeDialog> createState() => _RecipeDialogState();
}

class _RecipeDialogState extends State<_RecipeDialog> {
  final List<_RecipeRow> _rows = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    for (final l in LocalStore.rows('recipe_lines').where((l) => l['product_id'] == widget.product['id'])) {
      _rows.add(_RecipeRow(l['stock_item_id'] as String, _qty(l['qty'])));
    }
  }

  double get _cost => _rows.fold<double>(
      0, (s, r) => s + r.q * n(_stockItem(r.itemId)?['avg_cost']).toDouble());

  Future<void> _add() async {
    final used = _rows.map((r) => r.itemId).toSet();
    final all = LocalStore.rows('stock_items')
        .where((i) => i['active'] != false && !used.contains(i['id']))
        .toList()
      ..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    var q = '';
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final shown = all.where((i) => '${i['name']}'.toLowerCase().contains(q.toLowerCase())).toList();
        return AlertDialog(
          title: const Text('Add ingredient'),
          content: SizedBox(
            width: 400,
            height: 400,
            child: Column(children: [
              TextField(
                  autofocus: true,
                  onChanged: (v) => set(() => q = v),
                  decoration: const InputDecoration(hintText: 'Search ingredients', prefixIcon: Icon(Icons.search))),
              Expanded(
                child: ListView(children: [
                  for (final i in shown)
                    ListTile(
                        dense: true,
                        title: Text('${i['name']}'),
                        subtitle: Text('${i['category'] ?? ''} · ${money(n(i['avg_cost']))} per ${i['unit']}'),
                        onTap: () => Navigator.pop(ctx, i)),
                ]),
              ),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
        );
      }),
    );
    if (picked != null) setState(() => _rows.add(_RecipeRow(picked['id'] as String, '')));
  }

  Future<void> _save() async {
    for (final r in _rows) {
      if (r.q <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Enter a quantity above zero for ${_stockItem(r.itemId)?['name']}.')));
        return;
      }
    }
    setState(() => _busy = true);
    final id = widget.product['id'];
    final ok = await _online(context, () async {
      await _db.from('recipe_lines').delete().eq('product_id', id);
      if (_rows.isNotEmpty) {
        await _db.from('recipe_lines').insert([
          for (final r in _rows) {'product_id': id, 'stock_item_id': r.itemId, 'qty': r.q}
        ]);
      }
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final price = n(widget.product['price']).toDouble();
    final rate = vatRate();
    final net = price * 100 / (100 + rate);
    final cost = _cost;
    final margin = net <= 0 ? 0.0 : (net - cost) / net * 100;
    return AlertDialog(
      title: Text('Recipe: ${widget.product['name']}'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            const Text('What one portion uses. Selling the item takes these amounts off stock.',
                style: TextStyle(color: Brand.muted)),
            const SizedBox(height: 12),
            if (_rows.isEmpty)
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('No ingredients yet. Without a recipe, stock is not reduced when this item is sold.',
                      style: TextStyle(color: Brand.amber))),
            for (var i = 0; i < _rows.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  Expanded(
                    child: Text('${_stockItem(_rows[i].itemId)?['name'] ?? 'Unknown'}',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: _rows[i].qty,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                          isDense: true,
                          suffixText: '${_stockItem(_rows[i].itemId)?['unit'] ?? ''}'),
                    ),
                  ),
                  SizedBox(
                    width: 80,
                    child: Text(
                        money(_rows[i].q * n(_stockItem(_rows[i].itemId)?['avg_cost']).toDouble()),
                        textAlign: TextAlign.right,
                        style: const TextStyle(color: Brand.muted)),
                  ),
                  IconButton(onPressed: () => setState(() => _rows.removeAt(i)), icon: const Icon(Icons.close, size: 18)),
                ]),
              ),
            OutlinedButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add ingredient')),
            const Divider(height: 28),
            Text('Selling price ${money(price)} (${money(net)} excl. VAT)'),
            Text('Ingredient cost ${money(cost)}'),
            Text(
                'Margin ${margin.toStringAsFixed(1)}%  ·  Food cost ${net <= 0 ? '-' : (cost / net * 100).toStringAsFixed(1)}%',
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: _rows.isEmpty
                        ? null
                        : (margin < 55 ? Brand.red : (margin < 65 ? Brand.amber : Brand.green)))),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving...' : 'Save recipe')),
      ],
    );
  }
}
