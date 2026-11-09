import 'dart:math';

import 'package:intl/intl.dart';

import 'local_store.dart';

num n(dynamic v) => num.tryParse('$v') ?? 0;

double round2(num v) => (v * 100).round() / 100;

final _fmt = NumberFormat('#,##0.00', 'en_US');
String money(num v) => 'R${_fmt.format(v)}';

DateTime? parseTime(dynamic v) =>
    v == null ? null : DateTime.tryParse('$v')?.toLocal();

String mmss(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  final m = (s ~/ 60).toString().padLeft(2, '0');
  final r = (s % 60).toString().padLeft(2, '0');
  return '$m:$r';
}

Map<String, dynamic>? companyRow() {
  final rows = LocalStore.rows('company_settings');
  if (rows.isNotEmpty) return rows.first;
  final saved = LocalStore.getMeta('brand');
  return saved is Map ? Map<String, dynamic>.from(saved) : null;
}

double vatRate() {
  final r = companyRow()?['vat_rate'];
  return r == null ? 15 : n(r).toDouble();
}

/// Menu and "how many can we still make" from the recipes and stock on hand.
class Catalog {
  static List<Map<String, dynamic>> categories() {
    final list = LocalStore.rows('categories')
        .where((c) => c['active'] != false)
        .toList();
    list.sort((a, b) => n(a['sort_order']).compareTo(n(b['sort_order'])));
    return list;
  }

  static List<Map<String, dynamic>> products(String? categoryId) {
    final list = LocalStore.rows('products')
        .where((p) =>
            p['active'] != false &&
            (categoryId == null || p['category_id'] == categoryId))
        .toList();
    list.sort((a, b) => n(a['sort_order']).compareTo(n(b['sort_order'])));
    return list;
  }

  /// productId -> portions that stock still allows (9999 = no recipe).
  static Map<String, int> canMakeAll() {
    final stock = {
      for (final s in LocalStore.rows('stock_items')) s['id']: n(s['qty_on_hand'])
    };
    final result = <String, int>{};
    for (final line in LocalStore.rows('recipe_lines')) {
      final pid = line['product_id'] as String;
      final qty = n(line['qty']);
      if (qty <= 0) continue;
      final have = stock[line['stock_item_id']] ?? 0;
      final portions = (have / qty).floor();
      final current = result[pid] ?? 9999;
      result[pid] = portions < current ? portions : current;
    }
    return result;
  }

  static List<Map<String, dynamic>> modifiers() =>
      LocalStore.rows('modifiers').where((m) => m['active'] != false).toList();
}

class CartLine {
  CartLine({
    required this.productId,
    required this.name,
    required this.price,
    this.qty = 1,
    this.notes = '',
  });
  final String productId;
  final String name;
  final double price;
  int qty;
  String notes;
  double get total => round2(price * qty);
}

/// Creating and moving orders. Everything is written to the device first and
/// uploaded later, so it works without internet.
class OrderRepo {
  static String _nowIso() => DateTime.now().toUtc().toIso8601String();

  static Future<String> _deviceCode() async {
    var code = LocalStore.getMeta('device_code') as String?;
    if (code == null) {
      const letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
      final r = Random();
      code = List.generate(3, (_) => letters[r.nextInt(letters.length)]).join();
      await LocalStore.setMeta('device_code', code);
    }
    return code;
  }

  static Future<String> _nextRef() async {
    final code = await _deviceCode();
    final next = ((LocalStore.getMeta('order_counter') ?? 0) as int) + 1;
    await LocalStore.setMeta('order_counter', next);
    return '$code${next.toString().padLeft(4, '0')}';
  }

  /// Returns the order reference (for example "KQM0007").
  static Future<String> create({
    required List<CartLine> lines,
    required String type,
    String? table,
    Map<String, dynamic>? payment,
  }) async {
    final id = LocalStore.newId();
    final ref = await _nextRef();
    final now = _nowIso();
    final total = round2(lines.fold<double>(0, (s, l) => s + l.total));
    final vat = round2(total * vatRate() / (100 + vatRate()));

    await LocalStore.upsert('orders', {
      'id': id,
      'order_ref': ref,
      'device_name': await _deviceCode(),
      'status': 'new',
      'order_type': type,
      'table_no': (table == null || table.trim().isEmpty) ? null : table.trim(),
      'subtotal': round2(total - vat),
      'vat': vat,
      'total': total,
      'paid': payment != null,
      'created_at': now,
      'sent_at': now,
    });
    for (final l in lines) {
      await LocalStore.upsert('order_items', {
        'id': LocalStore.newId(),
        'order_id': id,
        'product_id': l.productId,
        'name': l.name,
        'qty': l.qty,
        'unit_price': l.price,
        'notes': l.notes.trim().isEmpty ? null : l.notes.trim(),
        'done': false,
        'created_at': now,
      });
    }
    if (payment != null) await _savePayment(id, payment);
    return ref;
  }

  static Future<void> _savePayment(String orderId, Map<String, dynamic> p) =>
      LocalStore.upsert('payments', {
        'id': LocalStore.newId(),
        'order_id': orderId,
        ...p,
        'created_at': _nowIso(),
      });

  /// Takes payment for an order that was sent to the kitchen unpaid.
  static Future<void> pay(String orderId, Map<String, dynamic> payment) async {
    await _savePayment(orderId, payment);
    await LocalStore.upsert('orders', {'id': orderId, 'paid': true});
  }

  static Future<void> setStatus(String orderId, String status,
      {String? voidReason}) async {
    final now = _nowIso();
    final patch = <String, dynamic>{'id': orderId, 'status': status};
    if (status == 'in_progress') patch['started_at'] = now;
    if (status == 'ready') patch['ready_at'] = now;
    if (status == 'collected') patch['collected_at'] = now;
    if (voidReason != null) patch['void_reason'] = voidReason;
    await LocalStore.upsert('orders', patch);
  }

  static Future<void> setItemDone(String itemId, bool done) =>
      LocalStore.upsert('order_items', {
        'id': itemId,
        'done': done,
        'done_at': done ? _nowIso() : null,
      });

  static List<Map<String, dynamic>> itemsFor(String orderId) {
    final list =
        LocalStore.rows('order_items').where((i) => i['order_id'] == orderId).toList();
    list.sort((a, b) => '${a['created_at']}'.compareTo('${b['created_at']}'));
    return list;
  }
}
