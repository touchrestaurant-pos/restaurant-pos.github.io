import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/data/local_store.dart';
import 'package:restaurant_pos/data/outbox_pusher.dart';
import 'package:restaurant_pos/data/repo.dart';
import 'package:restaurant_pos/data/sync_service.dart';

/// A pretend server: keeps rows in memory, can be "offline", can refuse a table.
class FakeServer implements SyncBackend {
  bool online = true;
  final rows = <String, Map<dynamic, Map<String, dynamic>>>{};
  final refuse = <String>{};
  final updates = <Map<String, dynamic>>[];

  void _check(String table) {
    if (!online) throw const SocketException('no connection');
    if (refuse.contains(table)) throw RefusedException('not allowed');
  }

  @override
  Future<void> insert(String table, Map<String, dynamic> row) async {
    _check(table);
    rows.putIfAbsent(table, () => {}).putIfAbsent(row['id'], () => Map.of(row));
  }

  @override
  Future<bool> update(String table, dynamic id, Map<String, dynamic> fields) async {
    _check(table);
    final t = rows[table];
    if (t == null || !t.containsKey(id)) return false;
    updates.add(Map.of(fields));
    t[id]!.addAll(fields);
    return true;
  }

  @override
  Future<void> delete(String table, dynamic id) async {
    _check(table);
    rows[table]?.remove(id);
  }
}

void main() {
  setUpAll(() async {
    await LocalStore.initAt(Directory.systemTemp.createTempSync('pos_test').path);
  });
  setUp(() async => LocalStore.clearAll());

  test('orders made offline wait, then all arrive once online', () async {
    final server = FakeServer()..online = false;
    await LocalStore.insert('orders', {'id': 'o1', 'total': 50});
    await LocalStore.insert('order_items', {'id': 'i1', 'order_id': 'o1', 'qty': 1});
    await expectLater(pushOutbox(server), throwsA(isA<SocketException>()));
    expect(LocalStore.pendingCount, 2);

    server.online = true;
    final r = await pushOutbox(server);
    expect(r.sent, 2);
    expect(LocalStore.pendingCount, 0);
    expect(server.rows['orders']!['o1']!['total'], 50);
    expect(server.rows['order_items']!['i1']!['order_id'], 'o1');
  });

  test('a change made before the row was sent is folded into the new row', () async {
    await LocalStore.insert('orders', {'id': 'o1', 'status': 'new', 'paid': false});
    await LocalStore.patch('orders', 'o1', {'paid': true});
    expect(LocalStore.pendingCount, 1);
    final server = FakeServer();
    await pushOutbox(server);
    expect(server.rows['orders']!['o1']!['paid'], true);
  });

  test('only the changed fields are sent, so another device\'s change is kept', () async {
    final server = FakeServer();
    await LocalStore.insert('orders', {'id': 'o1', 'status': 'new', 'paid': false});
    await pushOutbox(server);
    // Meanwhile the cashier's till marks it paid on the server.
    server.rows['orders']!['o1']!['paid'] = true;
    // This (kitchen) device still has paid=false in its copy and changes the status.
    await LocalStore.patch('orders', 'o1', {'status': 'ready'});
    await LocalStore.patch('orders', 'o1', {'ready_at': 'now'});
    expect(LocalStore.pendingCount, 1, reason: 'two changes to one row fold together');
    await pushOutbox(server);
    expect(server.updates.single.keys.toSet(), {'status', 'ready_at'});
    expect(server.rows['orders']!['o1']!['paid'], true);
    expect(server.rows['orders']!['o1']!['status'], 'ready');
  });

  test('a retry after a lost reply does not create a duplicate', () async {
    final server = FakeServer();
    await LocalStore.insert('payments', {'id': 'p1', 'amount': 20});
    server.rows['payments'] = {
      'p1': {'id': 'p1', 'amount': 20}
    };
    final r = await pushOutbox(server);
    expect(r.sent, 1);
    expect(server.rows['payments']!.length, 1);
  });

  test('a refused row holds back its later changes and is listed after 5 tries', () async {
    final server = FakeServer()..refuse.add('orders');
    await LocalStore.insert('orders', {'id': 'o1', 'status': 'new'});
    await pushOutbox(server); // first try: refused, so the next change is not folded in
    await LocalStore.patch('orders', 'o1', {'status': 'ready'});
    await LocalStore.insert('categories', {'id': 'c1', 'name': 'Burgers'});
    for (var i = 0; i < LocalStore.maxAttempts - 1; i++) {
      await pushOutbox(server);
    }
    expect(server.rows['categories']!['c1'], isNotNull, reason: 'other rows still go through');
    expect(LocalStore.failedCount, 1);
    expect(LocalStore.pendingCount, 2, reason: 'the held-back change is still waiting');

    server.refuse.clear();
    await LocalStore.resetAttempts();
    await pushOutbox(server);
    expect(LocalStore.pendingCount, 0);
    expect(server.rows['orders']!['o1']!['status'], 'ready');
  });

  test('an update for a row the server does not have is refused, not lost', () async {
    final server = FakeServer();
    await LocalStore.setRows('orders', [
      {'id': 'gone', 'status': 'new'}
    ]);
    await LocalStore.patch('orders', 'gone', {'status': 'ready'});
    final r = await pushOutbox(server);
    expect(r.refused, 1);
    expect(LocalStore.pendingCount, 1);
  });

  test('waiting changes stay visible after a download from the server', () async {
    await LocalStore.setRows('orders', [
      {'id': 'o1', 'status': 'new', 'total': 10}
    ]);
    await LocalStore.patch('orders', 'o1', {'status': 'ready'});
    await LocalStore.insert('orders', {'id': 'o2', 'status': 'new', 'total': 5});
    final merged = SyncService.withPending('orders', [
      {'id': 'o1', 'status': 'new', 'total': 10}
    ]);
    final byId = {for (final r in merged) r['id']: r};
    expect(byId['o1']!['status'], 'ready');
    expect(byId['o2'], isNotNull);
  });

  test('VAT and discount maths', () {
    final t = Totals(100, 10, 15);
    expect(t.total, 90);
    expect(t.vat, 11.74);
    expect(t.subtotal, 78.26);
    expect(Totals(50, 80, 15).total, 0, reason: 'a discount can never make the total negative');
    expect(round2(0.1 + 0.2), 0.3);
  });

  test('zero-rated items carry no VAT, and a discount is shared fairly', () {
    // R100 burger (standard) + R20 brown bread (zero-rated), R12 discount (10%).
    final t = Totals(120, 12, 15, standardTotal: 100);
    expect(t.total, 108);
    // Standard share after discount is R90, VAT = 90 x 15/115.
    expect(t.vat, 11.74);
    expect(Totals(50, 0, 15, standardTotal: 0).vat, 0, reason: 'all zero-rated');
  });

  group('paying with cash, card or both', () {
    test('R150 bill: R100 cash and the R50 balance on card', () {
      final r = splitTender(due: 150, cash: 100, card: 50);
      expect(r.error, isNull);
      expect(r.remaining, 0);
      expect(r.change, 0);
      expect(r.payments.map((p) => '${p['method']}:${p['amount']}').toList(), ['cash:100.0', 'card_manual:50.0']);
    });
    test('cash and card together may not be more than the bill', () {
      expect(splitTender(due: 150, cash: 100, card: 60).error, isNotNull);
      expect(splitTender(due: 150, card: 151).error, isNotNull);
      expect(splitTender(due: 150, cash: 200, card: 10).error, isNotNull);
    });
    test('cash only gives change', () {
      final r = splitTender(due: 150, cash: 200);
      expect(r.change, 50);
      expect(r.payments.single['amount'], 150);
      expect(r.payments.single['tendered'], 200);
    });
    test('part payment leaves a balance', () {
      final r = splitTender(due: 150, cash: 100);
      expect(r.remaining, 50);
      expect(r.change, 0);
      expect(splitTender(due: 150, card: 75).remaining, 75);
    });
    test('tip goes on the card when a card is used, otherwise out of the cash', () {
      final mixed = splitTender(due: 150, cash: 100, card: 50, tip: 10);
      expect(mixed.payments[0]['tip'], 0);
      expect(mixed.payments[1]['tip'], 10);
      final cash = splitTender(due: 150, cash: 200, tip: 10);
      expect(cash.change, 40);
      expect(cash.payments.single['tip'], 10);
    });
    test('nothing entered is not a payment', () {
      expect(splitTender(due: 150).payments, isEmpty);
    });
  });
}
