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
    total += n(l['qty']) * (1 + n(l['waste_pct']) / 100) * n(_stockItem(l['stock_item_id'])?['avg_cost']);
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
                  DataColumn(label: Text('VAT')),
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
                      final net = (p['vat_type'] ?? 'standard') == 'standard' ? price * 100 / (100 + rate) : price;
                      final cost = _portionCost(id);
                      final hasRecipe = LocalStore.rows('recipe_lines').any((l) => l['product_id'] == id);
                      final margin = net <= 0 ? 0.0 : (net - cost) / net * 100;
                      final can = canMake[id];
                      return DataRow(cells: [
                        DataCell(
                            Text('${p['name']}${p['active'] == false ? ' (off)' : ''}',
                                style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    decoration: TextDecoration.underline,
                                    color: p['active'] == false ? Brand.muted : Brand.navy)),
                            onTap: () => _viewProduct(context, p, '${catName[p['category_id']] ?? ''}', rate, canMake[id], cats)),
                        DataCell(Text(catName[p['category_id']] ?? ''),
                            onTap: () => _viewProduct(context, p, '${catName[p['category_id']] ?? ''}', rate, canMake[id], cats)),
                        DataCell(Text(money(price)),
                            onTap: () => _viewProduct(context, p, '${catName[p['category_id']] ?? ''}', rate, canMake[id], cats)),
                        DataCell(Text(
                            const {'standard': '15%', 'zero': 'Zero-rated', 'exempt': 'Exempt'}[p['vat_type'] ?? 'standard'] ?? '15%',
                            style: TextStyle(color: (p['vat_type'] ?? 'standard') == 'standard' ? Brand.muted : Brand.amber))),
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
                          TextButton(
                              onPressed: () => _viewProduct(context, p, '${catName[p['category_id']] ?? ''}', rate, canMake[id], cats),
                              child: const Text('View')),
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

  /// What a menu item is: its price and VAT, and everything in one portion with what it costs.
  Future<void> _viewProduct(BuildContext context, Map<String, dynamic> p, String category, num rate, dynamic canMake,
      List<Map<String, dynamic>> cats) async {
    final id = p['id'] as String;
    final oldPrice = n(p['price']).toDouble();
    final priceCtl = TextEditingController(text: oldPrice.toStringAsFixed(2));
    final vatType = '${p['vat_type'] ?? 'standard'}';
    final lines = LocalStore.rows('recipe_lines').where((l) => l['product_id'] == id).toList()
      ..sort((a, b) => '${_stockItem(a['stock_item_id'])?['name']}'.compareTo('${_stockItem(b['stock_item_id'])?['name']}'));
    double lineCost(Map<String, dynamic> l) =>
        n(l['qty']) * (1 + n(l['waste_pct']) / 100) * n(_stockItem(l['stock_item_id'])?['avg_cost']);
    final cost = lines.fold<double>(0, (t, l) => t + lineCost(l));
    String q(num v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
    Widget fact(String l, String v, {Color? color}) => SizedBox(
          width: 170,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l, style: const TextStyle(color: Brand.muted, fontSize: 12)),
              Text(v, style: TextStyle(fontWeight: FontWeight.w700, color: color)),
            ]),
          ),
        );
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final newPrice = double.tryParse(priceCtl.text.replaceAll(',', '.'));
        final price = newPrice ?? oldPrice;
        final net = vatType == 'standard' ? price * 100 / (100 + rate) : price;
        final profit = net - cost;
        final margin = net <= 0 ? 0.0 : profit / net * 100;
        final changed = newPrice != null && newPrice >= 0 && (newPrice - oldPrice).abs() > 0.004;
        return Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('${p['name']}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
                  IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
                ]),
                if ('${p['description'] ?? ''}'.trim().isNotEmpty)
                  Padding(padding: const EdgeInsets.only(bottom: 10), child: Text('${p['description']}', style: const TextStyle(color: Brand.muted))),
                Wrap(children: [
                  fact('Category', category.isEmpty ? '-' : category),
                  SizedBox(
                    width: 250,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8, right: 12),
                      child: TextField(
                        controller: priceCtl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        onChanged: (_) => set(() {}),
                        decoration: const InputDecoration(labelText: 'Selling price (incl. VAT)', prefixText: 'R ', isDense: true),
                      ),
                    ),
                  ),
                  fact('VAT', const {'standard': '15%', 'zero': 'Zero-rated', 'exempt': 'Exempt'}[vatType] ?? '15%'),
                  fact('Price excl. VAT', money(net)),
                  fact('Status', p['active'] == false ? 'Switched off' : 'On the menu'),
                  fact('Can make now', canMake == null ? '-' : '$canMake', color: canMake != null && canMake <= 0 ? Brand.red : null),
                ]),
                const Divider(height: 24),
                const Text("What's in it", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                if (lines.isEmpty)
                  const Text('No ingredients yet. Without a recipe, stock is not reduced when this item is sold.',
                      style: TextStyle(color: Brand.amber, fontWeight: FontWeight.w600))
                else
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      headingRowHeight: 38,
                      dataRowMinHeight: 36,
                      dataRowMaxHeight: 44,
                      columnSpacing: 20,
                      columns: const [
                        DataColumn(label: Text('Ingredient')),
                        DataColumn(label: Text('Per portion'), numeric: true),
                        DataColumn(label: Text('Waste'), numeric: true),
                        DataColumn(label: Text('On hand'), numeric: true),
                        DataColumn(label: Text('Cost'), numeric: true),
                      ],
                      rows: [
                        for (final l in lines)
                          DataRow(cells: [
                            DataCell(Text('${_stockItem(l['stock_item_id'])?['name'] ?? 'Removed item'}')),
                            DataCell(Text('${q(n(l['qty']))} ${_stockItem(l['stock_item_id'])?['unit'] ?? ''}')),
                            DataCell(Text(n(l['waste_pct']) > 0 ? '${q(n(l['waste_pct']))}%' : '-')),
                            DataCell(Text('${q(n(_stockItem(l['stock_item_id'])?['qty_on_hand']))} ${_stockItem(l['stock_item_id'])?['unit'] ?? ''}')),
                            DataCell(Text(money(lineCost(l)))),
                          ]),
                        DataRow(cells: [
                          const DataCell(Text('Ingredient cost', style: TextStyle(fontWeight: FontWeight.w800))),
                          const DataCell(Text('')),
                          const DataCell(Text('')),
                          const DataCell(Text('')),
                          DataCell(Text(money(cost), style: const TextStyle(fontWeight: FontWeight.w800))),
                        ]),
                      ],
                    ),
                  ),
                if (lines.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(children: [
                    fact('Profit per portion (excl. VAT)', money(profit)),
                    fact('Margin', '${margin.toStringAsFixed(1)}%', color: margin < 55 ? Brand.red : (margin < 65 ? Brand.amber : Brand.green)),
                  ]),
                ],
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton(onPressed: changed ? () => Navigator.pop(ctx, 'price') : null, child: const Text('Save price')),
                  FilledButton.tonal(onPressed: () => Navigator.pop(ctx, 'recipe'), child: const Text('Edit recipe')),
                  OutlinedButton(onPressed: () => Navigator.pop(ctx, 'edit'), child: const Text('Edit item')),
                ]),
              ]),
            ),
          ),
        ),
      );
      }),
    );
    if (!context.mounted) return;
    if (action == 'price') {
      final v = double.parse(priceCtl.text.replaceAll(',', '.'));
      await _online(context, () async {
        await _db.from('products').update({'price': v}).eq('id', id);
      });
      return;
    }
    if (action == 'recipe') await _editRecipe(context, p);
    if (action == 'edit') await _editProduct(context, p, cats);
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
    String vatType = '${p?['vat_type'] ?? 'standard'}';
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
                  value: cat,
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
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: vatType,
                  decoration: const InputDecoration(labelText: 'VAT'),
                  items: const [
                    DropdownMenuItem(value: 'standard', child: Text('Standard rated (15%)')),
                    DropdownMenuItem(value: 'zero', child: Text('Zero-rated (0%)')),
                    DropdownMenuItem(value: 'exempt', child: Text('Exempt (no VAT)')),
                  ],
                  onChanged: (v) => set(() => vatType = v ?? 'standard'),
                ),
                if (vatType != 'standard')
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                        'Only basic foods sold as they are (brown bread, maize meal, rice, fresh fruit and vegetables, milk, eggs ...) are zero-rated. '
                        'Anything served as a meal or prepared to eat now is standard rated, even if made from these.',
                        style: TextStyle(color: Brand.amber, fontSize: 12)),
                  ),
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
      'vat_type': vatType,
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
  _RecipeRow(this.itemId, String qty, [String waste = ''])
      : qty = TextEditingController(text: qty),
        waste = TextEditingController(text: waste);
  final String itemId;
  final TextEditingController qty;

  /// Trimming and cooking loss, so stock drops by what is really used.
  final TextEditingController waste;
  double get q => double.tryParse(qty.text.replaceAll(',', '.')) ?? 0;
  double get w => (double.tryParse(waste.text.replaceAll(',', '.')) ?? 0).clamp(0, 100).toDouble();
  double get used => q * (1 + w / 100);
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
      _rows.add(_RecipeRow(l['stock_item_id'] as String, _qty(l['qty']),
          n(l['waste_pct']) > 0 ? _qty(l['waste_pct']) : ''));
    }
  }

  double get _cost => _rows.fold<double>(
      0, (s, r) => s + r.used * n(_stockItem(r.itemId)?['avg_cost']).toDouble());

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
          for (final r in _rows) {'product_id': id, 'stock_item_id': r.itemId, 'qty': r.q, 'waste_pct': r.w}
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
    final net = (widget.product['vat_type'] ?? 'standard') == 'standard' ? price * 100 / (100 + rate) : price;
    final cost = _cost;
    final margin = net <= 0 ? 0.0 : (net - cost) / net * 100;
    return AlertDialog(
      title: Text('Recipe: ${widget.product['name']}'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            const Text('What one portion uses. Waste % adds trimming or cooking loss (for example 10% for chicken on the bone). Selling the item takes these amounts off stock.',
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
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 74,
                    child: TextField(
                      controller: _rows[i].waste,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(isDense: true, suffixText: '%', hintText: 'waste'),
                    ),
                  ),
                  SizedBox(
                    width: 80,
                    child: Text(
                        money(_rows[i].used * n(_stockItem(_rows[i].itemId)?['avg_cost']).toDouble()),
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
