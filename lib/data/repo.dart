import 'dart:math';

import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

const vatTypeNames = {'standard': 'Standard rated', 'zero': 'Zero-rated', 'exempt': 'Exempt'};

double vatRate() {
  final r = companyRow()?['vat_rate'];
  return r == null ? 15 : n(r).toDouble();
}

/// Menu and "how many can we still make" from the recipes and stock on hand.
class Catalog {
  static List<Map<String, dynamic>> categories() {
    final list = LocalStore.rows('categories').where((c) => c['active'] != false).toList();
    list.sort((a, b) => n(a['sort_order']).compareTo(n(b['sort_order'])));
    return list;
  }

  static List<Map<String, dynamic>> products(String? categoryId) {
    final list = LocalStore.rows('products')
        .where((p) => p['active'] != false && (categoryId == null || p['category_id'] == categoryId))
        .toList();
    list.sort((a, b) => n(a['sort_order']).compareTo(n(b['sort_order'])));
    return list;
  }

  /// stockItemId -> quantity one portion takes, including recipe waste and extras.
  static Map<String, double> usage(String productId, List<String> modifierIds, num qty) {
    final out = <String, double>{};
    for (final l in LocalStore.rows('recipe_lines')) {
      if (l['product_id'] != productId) continue;
      final q = n(l['qty']) * (1 + n(l['waste_pct']) / 100) * qty;
      out.update(l['stock_item_id'] as String, (v) => v + q, ifAbsent: () => q.toDouble());
    }
    if (modifierIds.isNotEmpty) {
      for (final m in LocalStore.rows('modifiers')) {
        if (!modifierIds.contains(m['id']) || m['stock_item_id'] == null) continue;
        final q = n(m['stock_qty']) * qty;
        out.update(m['stock_item_id'] as String, (v) => v + q, ifAbsent: () => q.toDouble());
      }
    }
    return out;
  }

  /// Stock still to be taken off by sales made on this device that have not
  /// reached the server yet (the server takes it off when they arrive).
  static Map<String, double> pendingUsage() {
    final out = <String, double>{};
    for (final e in LocalStore.pending()) {
      final item = e.value;
      if (item['table'] != 'order_items' || item['op'] != 'insert') continue;
      final row = Map<String, dynamic>.from(item['row'] as Map);
      if (row['voided'] == true || row['product_id'] == null) continue;
      final mods = ((row['modifier_ids'] as List?) ?? const []).map((x) => '$x').toList();
      usage(row['product_id'] as String, mods, n(row['qty'])).forEach((k, v) {
        out.update(k, (o) => o + v, ifAbsent: () => v);
      });
    }
    return out;
  }

  /// productId -> portions that stock still allows (9999 = no recipe).
  static Map<String, int> canMakeAll() {
    final pending = pendingUsage();
    final stock = {
      for (final s in LocalStore.rows('stock_items'))
        s['id']: n(s['qty_on_hand']).toDouble() - (pending[s['id']] ?? 0)
    };
    final result = <String, int>{};
    for (final line in LocalStore.rows('recipe_lines')) {
      final pid = line['product_id'] as String;
      final qty = n(line['qty']) * (1 + n(line['waste_pct']) / 100);
      if (qty <= 0) continue;
      final have = stock[line['stock_item_id']] ?? 0;
      final portions = have <= 0 ? 0 : (have / qty).floor();
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
    this.extra = 0,
    this.vatType = 'standard',
    List<String>? modifierIds,
  }) : modifierIds = modifierIds ?? [];

  /// standard (15%), zero (zero-rated, 0%) or exempt (no VAT).
  final String vatType;
  final String productId;
  final String name;
  final double price;
  int qty;
  String notes;

  /// Special requests picked from the list (they can carry a price and use stock).
  List<String> modifierIds;

  /// Extra charge per item from special requests such as "Extra cheese".
  double extra;
  double get unitPrice => round2(price + extra);
  double get total => round2(unitPrice * qty);
}

/// Money maths kept in one place so the till, receipts and tests agree.
class Totals {
  Totals(this.itemsTotal, this.discount, this.vatRate, {this.standardTotal});
  final double itemsTotal;
  final double discount;
  final double vatRate;

  /// Value of the items charged at the standard rate. Zero-rated and exempt
  /// items carry no VAT. Leave empty when every item is standard.
  final double? standardTotal;

  double get total => round2(max(0, itemsTotal - discount));

  /// Share of the order that is standard-rated (a discount is shared evenly).
  double get standardShare =>
      itemsTotal <= 0 ? 1 : ((standardTotal ?? itemsTotal) / itemsTotal).clamp(0, 1).toDouble();

  /// Prices include VAT, so the VAT is the part of the standard-rated total above its net price.
  double get vat => round2(total * standardShare * vatRate / (100 + vatRate));
  double get subtotal => round2(total - vat);
}

/// Result of paying a bill with cash, card or both.
class TenderResult {
  TenderResult({required this.payments, required this.change, required this.remaining, this.error});
  final List<Map<String, dynamic>> payments;
  final double change;

  /// What is still owed after these payments.
  final double remaining;

  /// Set when the amounts are not allowed (for example cash + card above the bill).
  final String? error;
}

/// Works out the payments for a bill of [due] from the cash handed over, the
/// amount put on card and an optional tip.
///
/// - Cash only: more than the bill gives change.
/// - Card (alone or with cash): the two together may never exceed the bill,
///   so no change is ever owed on a card or mixed payment.
/// - Less than the bill is a part payment; the rest stays owed.
/// - The tip goes on the card when a card is used, otherwise it comes out of the cash.
TenderResult splitTender({required double due, double cash = 0, double card = 0, double tip = 0}) {
  due = round2(due);
  cash = round2(max(0, cash));
  card = round2(max(0, card));
  tip = round2(max(0, tip));
  TenderResult bad(String m) => TenderResult(payments: const [], change: 0, remaining: due, error: m);
  final tipOnCard = card > 0;
  final cashForBill = round2(max(0, cash - (tipOnCard ? 0 : tip)));
  if (card > due + 0.005) return bad('The card amount is more than the ${money(due)} owed.');
  if (card > 0 && cashForBill + card > due + 0.005) {
    return bad('Cash and card together are more than the ${money(due)} owed. '
        'Put ${money(max(0, due - cashForBill))} on the card.');
  }
  if (cashForBill <= 0 && card <= 0) {
    return TenderResult(payments: const [], change: 0, remaining: due);
  }
  final cashApplied = round2(min(due, cashForBill));
  final change = card > 0 ? 0.0 : round2(max(0, cashForBill - due));
  return TenderResult(
    payments: [
      if (cashApplied > 0)
        {
          'method': 'cash',
          'amount': cashApplied,
          'tip': tipOnCard ? 0.0 : tip,
          'tendered': cash,
          'change_given': change,
        },
      if (card > 0) {'method': 'card_manual', 'amount': card, 'tip': tip},
    ],
    change: change,
    remaining: round2(max(0, due - cashApplied - card)),
  );
}

/// Creating and changing orders. Everything is written to the device first and
/// uploaded later, so it works without internet.
class OrderRepo {
  static String _nowIso() => DateTime.now().toUtc().toIso8601String();
  static String? get _me => Supabase.instance.client.auth.currentUser?.id;

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

  static Map<String, dynamic> _itemRow(String orderId, CartLine l, String now, {bool added = false}) => {
        'id': LocalStore.newId(),
        'order_id': orderId,
        'product_id': l.productId,
        'name': l.name,
        'qty': l.qty,
        'unit_price': l.unitPrice,
        'notes': l.notes.trim().isEmpty ? null : l.notes.trim(),
        'modifier_ids': l.modifierIds,
        'vat_type': l.vatType,
        'done': false,
        'voided': false,
        'added_later': added,
        'created_at': now,
      };

  /// Returns the order id. [payments] may be empty (pay later) or several (split bill).
  static Future<String> create({
    required List<CartLine> lines,
    required String type,
    String? table,
    String? customerName,
    String? customerPhone,
    String? deliveryAddress,
    double discount = 0,
    String? discountReason,
    List<Map<String, dynamic>> payments = const [],
  }) async {
    final id = LocalStore.newId();
    final ref = await _nextRef();
    final now = _nowIso();
    final t = Totals(lines.fold<double>(0, (s, l) => s + l.total), discount, vatRate(),
        standardTotal: lines.where((l) => l.vatType == 'standard').fold<double>(0, (s, l) => s + l.total));
    final paidSoFar = payments.fold<double>(0, (s, p) => s + n(p['amount']).toDouble());

    await LocalStore.insert('orders', {
      'id': id,
      'order_ref': ref,
      'device_name': await _deviceCode(),
      'status': 'new',
      'order_type': type,
      'table_no': (table == null || table.trim().isEmpty) ? null : table.trim(),
      'customer_name': (customerName ?? '').trim().isEmpty ? null : customerName!.trim(),
      'customer_phone': (customerPhone ?? '').trim().isEmpty ? null : customerPhone!.trim(),
      'delivery_address': (deliveryAddress ?? '').trim().isEmpty ? null : deliveryAddress!.trim(),
      'subtotal': t.subtotal,
      'vat': t.vat,
      'total': t.total,
      'discount': round2(min(discount, t.itemsTotal)),
      'discount_reason': discount > 0 ? discountReason : null,
      'paid': paidSoFar + 0.005 >= t.total,
      'created_by': _me,
      'created_at': now,
      'sent_at': now,
    });
    for (final l in lines) {
      await LocalStore.insert('order_items', _itemRow(id, l, now));
    }
    for (final p in payments) {
      await _savePayment(id, p);
    }
    return id;
  }

  static Future<void> _savePayment(String orderId, Map<String, dynamic> p) =>
      LocalStore.insert('payments', {
        'id': LocalStore.newId(),
        'order_id': orderId,
        'method': p['method'],
        'amount': p['amount'],
        'tip': p['tip'] ?? 0,
        if (p['tendered'] != null) 'tendered': p['tendered'],
        if (p['change_given'] != null) 'change_given': p['change_given'],
        if (p['card_brand'] != null) 'card_brand': p['card_brand'],
        if (p['card_last4'] != null) 'card_last4': p['card_last4'],
        if (p['slip_no'] != null) 'slip_no': p['slip_no'],
        if (p['account_id'] != null) ...{
          'account_id': p['account_id'],
          'account_no': p['account_no'],
          'account_name': p['account_name'],
          'account_vat_no': p['account_vat_no'],
          'account_address': p['account_address'],
        },
        'created_by': _me,
        'created_at': _nowIso(),
      });

  static List<Map<String, dynamic>> paymentsFor(String orderId) =>
      LocalStore.rows('payments').where((p) => p['order_id'] == orderId).toList();

  static double paidAmount(String orderId) =>
      round2(paymentsFor(orderId).fold<double>(0, (s, p) => s + n(p['amount']).toDouble()));

  static double balance(String orderId) {
    final o = LocalStore.row('orders', orderId);
    if (o == null) return 0;
    return round2(max(0, n(o['total']).toDouble() - paidAmount(orderId)));
  }

  /// Takes (part of) the payment for an order. Marks it paid once fully paid.
  static Future<void> pay(String orderId, Map<String, dynamic> payment) async {
    await _savePayment(orderId, payment);
    if (balance(orderId) <= 0.005) {
      await LocalStore.patch('orders', orderId, {'paid': true});
    }
  }

  /// Adds items to an unpaid order (the kitchen sees them marked as added).
  static Future<void> addItems(String orderId, List<CartLine> lines) async {
    final now = _nowIso();
    for (final l in lines) {
      await LocalStore.insert('order_items', _itemRow(orderId, l, now, added: true));
    }
    await recalc(orderId);
    final o = LocalStore.row('orders', orderId);
    if (o != null && (o['status'] == 'ready' || o['status'] == 'collected')) {
      await LocalStore.patch('orders', orderId, {'status': 'in_progress'});
    }
  }

  /// Takes an item off an unpaid order. The server returns its stock.
  static Future<void> removeItem(String itemId) async {
    final item = LocalStore.row('order_items', itemId);
    if (item == null) return;
    await LocalStore.patch('order_items', itemId, {'voided': true, 'voided_at': _nowIso()});
    await recalc(item['order_id'] as String);
  }

  /// Works out the order total again from its items and discount.
  static Future<void> recalc(String orderId) async {
    final o = LocalStore.row('orders', orderId);
    if (o == null) return;
    final items = itemsFor(orderId).where((i) => i['voided'] != true);
    final itemsTotal = items.fold<double>(0, (s, i) => s + n(i['qty']) * n(i['unit_price']).toDouble());
    final standard = items
        .where((i) => (i['vat_type'] ?? 'standard') == 'standard')
        .fold<double>(0, (s, i) => s + n(i['qty']) * n(i['unit_price']).toDouble());
    final t = Totals(itemsTotal, n(o['discount']).toDouble(), vatRate(), standardTotal: standard);
    await LocalStore.patch('orders', orderId, {
      'subtotal': t.subtotal,
      'vat': t.vat,
      'total': t.total,
      if (n(o['discount']) > itemsTotal) 'discount': round2(itemsTotal),
    });
  }

  static Future<void> setStatus(String orderId, String status, {String? voidReason}) async {
    final now = _nowIso();
    final patch = <String, dynamic>{'status': status};
    if (status == 'in_progress') patch['started_at'] = now;
    if (status == 'ready') patch['ready_at'] = now;
    if (status == 'collected') patch['collected_at'] = now;
    if (status == 'void') {
      patch['voided_at'] = now;
      patch['voided_by'] = _me;
    }
    if (voidReason != null) patch['void_reason'] = voidReason;
    await LocalStore.patch('orders', orderId, patch);
  }

  static Future<void> setItemDone(String itemId, bool done) =>
      LocalStore.patch('order_items', itemId, {'done': done, 'done_at': done ? _nowIso() : null});

  static List<Map<String, dynamic>> itemsFor(String orderId) {
    final list = LocalStore.rows('order_items').where((i) => i['order_id'] == orderId).toList();
    list.sort((a, b) => '${a['created_at']}'.compareTo('${b['created_at']}'));
    return list;
  }

  static List<Map<String, dynamic>> liveItemsFor(String orderId) =>
      itemsFor(orderId).where((i) => i['voided'] != true).toList();
}
