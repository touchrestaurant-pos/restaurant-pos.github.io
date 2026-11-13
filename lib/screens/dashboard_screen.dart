import 'package:flutter/material.dart';

import '../auth/auth_service.dart';
import '../data/local_store.dart';
import '../data/repo.dart';
import '../data/sync_service.dart';
import '../theme.dart';

/// Quick numbers from the data saved on this device.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;
    return ListenableBuilder(
      listenable: SyncService.instance,
      builder: (context, _) {
        final products = LocalStore.rows('products').length;
        final stock = LocalStore.rows('stock_items');
        final low =
            stock.where((s) => n(s['qty_on_hand']) < n(s['min_level'])).length;
        final orders = LocalStore.rows('orders');
        final open = orders
            .where((o) => const ['new', 'in_progress', 'ready'].contains(o['status']))
            .length;
        final today = DateTime.now();
        final todaySales = orders.where((o) {
          final t = parseTime(o['created_at']);
          return o['status'] != 'void' &&
              o['paid'] == true &&
              t != null &&
              t.year == today.year &&
              t.month == today.month &&
              t.day == today.day;
        }).fold<num>(0, (s, o) => s + n(o['total']));

        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('Good day, ${auth.fullName}',
                style: const TextStyle(
                    fontSize: 26, fontWeight: FontWeight.w800, color: Brand.navy)),
            const SizedBox(height: 4),
            const Text('Saved on this device, so it still works without internet. Tap a box for the details.',
                style: TextStyle(color: Brand.muted)),
            const SizedBox(height: 20),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                if (const ['admin', 'supervisor'].contains(auth.role))
                  _Stat(value: money(todaySales), label: 'SALES TODAY', colour: Brand.gold, onTap: () => _details(context, 'sales')),
                _Stat(value: '$open', label: 'OPEN ORDERS', colour: Brand.red, onTap: () => _details(context, 'open')),
                _Stat(value: '$low', label: 'LOW STOCK', colour: Brand.amber, onTap: () => _details(context, 'low')),
                _Stat(value: '$products', label: 'MENU ITEMS', colour: Brand.green, onTap: () => _details(context, 'menu')),
                _Stat(value: '${stock.length}', label: 'STOCK ITEMS', colour: Brand.navyLight, onTap: () => _details(context, 'stock')),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, required this.colour, this.onTap});
  final VoidCallback? onTap;
  final String value;
  final String label;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
       onTap: onTap,
       child: Container(
        width: 200,
        color: Colors.white,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(height: 4, color: colour),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value,
                      style: const TextStyle(
                          fontSize: 30, fontWeight: FontWeight.w800, color: Brand.navy)),
                  const SizedBox(height: 2),
                  Text(label,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: Brand.muted)),
                ],
              ),
            ),
          ],
        ),
       ),
      ),
    );
  }
}


bool _isToday(DateTime? t) {
  final d = DateTime.now();
  return t != null && t.year == d.year && t.month == d.month && t.day == d.day;
}

String _hm(dynamic v) {
  final t = parseTime(v);
  return t == null ? '' : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

Widget _kv(String k, String v, {bool bold = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Expanded(child: Text(k, style: const TextStyle(color: Brand.muted))),
        Text(v, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w600)),
      ]),
    );

Widget _head(String t) => Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 4),
      child: Text(t, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Brand.navy)),
    );

Widget _row(String title, String sub, String trailing, {Color? color}) => ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: sub.isEmpty ? null : Text(sub),
      trailing: Text(trailing, style: TextStyle(fontWeight: FontWeight.w800, color: color)),
    );

/// More detail behind each dashboard box, from the data already saved on this device.
void _details(BuildContext context, String kind) {
  final orders = LocalStore.rows('orders');
  final items = LocalStore.rows('order_items');
  final stock = LocalStore.rows('stock_items');
  final products = LocalStore.rows('products');
  final children = <Widget>[];
  String title = '';

  switch (kind) {
    case 'sales':
      title = 'Sales today';
      final paid = orders.where((o) => o['status'] != 'void' && o['paid'] == true && _isToday(parseTime(o['created_at']))).toList()
        ..sort((a, b) => '${b['created_at']}'.compareTo('${a['created_at']}'));
      final ids = paid.map((o) => o['id']).toSet();
      final total = paid.fold<num>(0, (s, o) => s + n(o['total']));
      final vat = paid.fold<num>(0, (s, o) => s + n(o['vat']));
      final disc = paid.fold<num>(0, (s, o) => s + n(o['discount']));
      final voided = orders.where((o) => o['status'] == 'void' && _isToday(parseTime(o['created_at']))).length;
      final unpaid = orders.where((o) => o['status'] != 'void' && o['paid'] != true && _isToday(parseTime(o['created_at'])));
      children.addAll([
        _kv('Paid orders', '${paid.length}'),
        _kv('Sales incl. VAT', money(total), bold: true),
        _kv('VAT in those sales', money(vat)),
        _kv('Sales excl. VAT', money(total - vat)),
        _kv('Average per order', paid.isEmpty ? '-' : money(total / paid.length)),
        _kv('Discounts given', money(disc)),
        _kv('Not paid yet', '${unpaid.length} (${money(unpaid.fold<num>(0, (s, o) => s + n(o['total'])))})'),
        _kv('Cancelled', '$voided'),
      ]);
      final byMethod = <String, num>{};
      for (final p in LocalStore.rows('payments').where((p) => ids.contains(p['order_id']))) {
        final m = const {'cash': 'Cash', 'card_manual': 'Card', 'eft': 'EFT', 'account': 'On account'}['${p['method']}'] ?? '${p['method']}';
        byMethod[m] = (byMethod[m] ?? 0) + n(p['amount']);
      }
      if (byMethod.isNotEmpty) {
        children.add(_head('How customers paid'));
        for (final e in byMethod.entries) {
          children.add(_kv(e.key, money(e.value)));
        }
      }
      final sold = <String, num>{};
      for (final i in items.where((i) => ids.contains(i['order_id']) && i['voided'] != true)) {
        sold['${i['name']}'] = (sold['${i['name']}'] ?? 0) + n(i['qty']);
      }
      if (sold.isNotEmpty) {
        final top = sold.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
        children.add(_head('Best sellers today'));
        for (final e in top.take(8)) {
          children.add(_kv(e.key, '${e.value.toInt()} sold'));
        }
      }
      if (paid.isNotEmpty) {
        children.add(_head('Today\'s paid orders'));
        for (final o in paid.take(40)) {
          children.add(_row('#${o['order_ref']}${o['invoice_no'] != null ? ' · INV-${'${o['invoice_no']}'.padLeft(6, '0')}' : ''}',
              '${_hm(o['created_at'])}${o['table_no'] != null ? ' · table ${o['table_no']}' : ''}', money(n(o['total']))));
        }
      }
    case 'open':
      title = 'Open orders';
      final open = orders.where((o) => const ['new', 'in_progress', 'ready'].contains(o['status'])).toList()
        ..sort((a, b) => '${a['created_at']}'.compareTo('${b['created_at']}'));
      if (open.isEmpty) children.add(const Padding(padding: EdgeInsets.all(12), child: Text('No open orders right now.')));
      const names = {'new': 'New', 'in_progress': 'Being made', 'ready': 'Ready'};
      for (final o in open) {
        final t = parseTime(o['created_at']);
        final mins = t == null ? 0 : DateTime.now().difference(t).inMinutes;
        final its = items.where((i) => i['order_id'] == o['id'] && i['voided'] != true).map((i) => '${i['qty']}x ${i['name']}').join(', ');
        children.add(_row('#${o['order_ref']} · ${names[o['status']] ?? o['status']}${o['table_no'] != null ? ' · table ${o['table_no']}' : ''}',
            '$mins min ago · ${o['paid'] == true ? 'paid' : 'not paid'}\n$its', money(n(o['total'])),
            color: mins > 30 ? Brand.red : null));
      }
    case 'low':
      title = 'Low stock';
      final lowItems = stock.where((s) => n(s['qty_on_hand']) < n(s['min_level'])).toList()
        ..sort((a, b) => (n(a['qty_on_hand']) - n(a['min_level'])).compareTo(n(b['qty_on_hand']) - n(b['min_level'])));
      if (lowItems.isEmpty) children.add(const Padding(padding: EdgeInsets.all(12), child: Text('Nothing is running low.')));
      for (final s in lowItems) {
        final u = '${s['unit'] ?? ''}';
        children.add(_row('${s['name']}', 'Minimum ${n(s['min_level'])} $u · short by ${(n(s['min_level']) - n(s['qty_on_hand'])).toStringAsFixed(1)} $u',
            '${n(s['qty_on_hand'])} $u', color: n(s['qty_on_hand']) <= 0 ? Brand.red : Brand.amber));
      }
    case 'menu':
      title = 'Menu items';
      final cats = {for (final c in LocalStore.rows('categories')) c['id']: '${c['name']}'};
      final active = products.where((p) => p['active'] != false).toList();
      final withRecipe = LocalStore.rows('recipe_lines').map((l) => l['product_id']).toSet();
      final noRecipe = active.where((p) => !withRecipe.contains(p['id'])).toList();
      final prices = active.map((p) => n(p['price']).toDouble()).toList()..sort();
      children.addAll([
        _kv('On the menu', '${active.length}'),
        _kv('Switched off', '${products.length - active.length}'),
        _kv('Lowest price', prices.isEmpty ? '-' : money(prices.first)),
        _kv('Highest price', prices.isEmpty ? '-' : money(prices.last)),
        _kv('Without a recipe', '${noRecipe.length}'),
      ]);
      final byCat = <String, int>{};
      for (final p in active) {
        final c = cats[p['category_id']] ?? 'No category';
        byCat[c] = (byCat[c] ?? 0) + 1;
      }
      children.add(_head('Items per category'));
      for (final e in byCat.entries) {
        children.add(_kv(e.key, '${e.value}'));
      }
      if (noRecipe.isNotEmpty) {
        children.add(_head('No recipe (stock is not reduced when sold)'));
        for (final p in noRecipe.take(30)) {
          children.add(_kv('${p['name']}', money(n(p['price']))));
        }
      }
    case 'stock':
      title = 'Stock items';
      final value = stock.fold<num>(0, (s, i) => s + n(i['qty_on_hand']) * n(i['avg_cost']));
      final neg = stock.where((s) => n(s['qty_on_hand']) < 0).toList();
      final zero = stock.where((s) => n(s['qty_on_hand']) == 0).length;
      final low = stock.where((s) => n(s['qty_on_hand']) < n(s['min_level'])).length;
      children.addAll([
        _kv('Items', '${stock.length}'),
        _kv('Stock value at cost', money(value), bold: true),
        _kv('Running low', '$low'),
        _kv('Out of stock', '$zero'),
        _kv('Below zero (check these)', '${neg.length}'),
      ]);
      final top = stock.toList()
        ..sort((a, b) => (n(b['qty_on_hand']) * n(b['avg_cost'])).compareTo(n(a['qty_on_hand']) * n(a['avg_cost'])));
      children.add(_head('Most money tied up in stock'));
      for (final s in top.take(10)) {
        children.add(_row('${s['name']}', '${n(s['qty_on_hand'])} ${s['unit'] ?? ''}', money(n(s['qty_on_hand']) * n(s['avg_cost']))));
      }
      if (neg.isNotEmpty) {
        children.add(_head('Below zero'));
        for (final s in neg) {
          children.add(_row('${s['name']}', '', '${n(s['qty_on_hand'])} ${s['unit'] ?? ''}', color: Brand.red));
        }
      }
  }

  showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            Row(children: [
              Expanded(child: Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
              IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
            ]),
            Expanded(child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children))),
          ]),
        ),
      ),
    ),
  );
}
