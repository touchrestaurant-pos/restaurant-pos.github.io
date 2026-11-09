import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'local_store.dart';

/// Keeps the device copy and Supabase in step.
///
/// 1. Sends everything waiting in the outbox (oldest first).
/// 2. Downloads fresh copies of the tables this staff member may see.
/// 3. Listens for live changes (kitchen queue, stock levels).
///
/// If the internet is down nothing breaks: the app keeps using the device copy
/// and tries again every 30 seconds and whenever the connection returns.
class SyncService extends ChangeNotifier {
  SyncService._();
  static final instance = SyncService._();

  SupabaseClient get _db => Supabase.instance.client;

  /// Order matters: parents before children.
  static const pullTables = [
    'company_settings',
    'staff_profiles',
    'categories',
    'products',
    'modifiers',
    'suppliers',
    'stock_items',
    'recipe_lines',
    'grvs',
    'grv_lines',
    'orders',
    'order_items',
    'payments',
  ];

  bool online = true;
  bool syncing = false;
  DateTime? lastSync;
  String? lastError;

  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  RealtimeChannel? _channel;

  int get pendingCount => LocalStore.pendingCount;

  void start() {
    LocalStore.resetAttempts();
    _connSub ??= Connectivity().onConnectivityChanged.listen((results) {
      final nowOnline = !results.contains(ConnectivityResult.none);
      if (nowOnline != online) {
        online = nowOnline;
        notifyListeners();
      }
      if (nowOnline) syncNow();
    });
    _timer ??= Timer.periodic(const Duration(seconds: 30), (_) => syncNow());
    syncNow();
  }

  Future<void> syncNow() async {
    if (syncing || _db.auth.currentSession == null) return;
    syncing = true;
    notifyListeners();
    try {
      await _push();
      for (final t in pullTables) {
        await _pull(t);
      }
      _subscribe();
      lastSync = DateTime.now();
      lastError = null;
      online = true;
    } on PostgrestException catch (e) {
      lastError = e.message;
    } catch (_) {
      online = false;
      lastError = 'Offline';
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  Future<void> _push() async {
    for (final entry in LocalStore.pending()) {
      final item = entry.value;
      if (((item['attempts'] ?? 0) as int) >= 5) continue; // needs a supervisor
      final table = item['table'] as String;
      final row = Map<String, dynamic>.from(item['row'] as Map);
      try {
        if (item['op'] == 'delete') {
          await _db.from(table).delete().eq('id', row['id']);
        } else {
          await _db.from(table).upsert(row);
        }
        await LocalStore.removePending(entry.key);
      } on PostgrestException catch (e) {
        // The server understood but refused (for example a security rule).
        // Keep it, count the attempt, and carry on with the rest.
        await LocalStore.markFailed(entry.key, e.message);
        lastError = e.message;
      }
      // Network errors are not caught here: they stop the whole sync.
    }
  }

  Future<void> _pull(String table) async {
    List<dynamic> data;
    if (table == 'orders') {
      final since = DateTime.now()
          .subtract(const Duration(days: 2))
          .toUtc()
          .toIso8601String();
      data = await _db
          .from('orders')
          .select()
          .gte('created_at', since)
          .order('created_at');
    } else if (table == 'order_items' || table == 'payments') {
      final ids = LocalStore.rows('orders').map((o) => o['id']).toList();
      data = [];
      for (var i = 0; i < ids.length; i += 80) {
        final chunk = ids.sublist(i, i + 80 > ids.length ? ids.length : i + 80);
        data.addAll(await _db.from(table).select().inFilter('order_id', chunk));
      }
    } else {
      data = await _db.from(table).select();
    }
    final server = data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    await LocalStore.setRows(table, _withPending(table, server));
    notifyListeners();
  }

  /// Puts changes that have not been uploaded yet back on top of the fresh
  /// server copy, so they do not disappear from the screen.
  List<Map<String, dynamic>> _withPending(
      String table, List<Map<String, dynamic>> server) {
    if (table == 'recipe_lines') return server; // no single id column
    final byId = {for (final r in server) r['id']: r};
    for (final entry in LocalStore.pending()) {
      final item = entry.value;
      if (item['table'] != table) continue;
      final row = Map<String, dynamic>.from(item['row'] as Map);
      if (item['op'] == 'delete') {
        byId.remove(row['id']);
      } else {
        byId[row['id']] = {...?byId[row['id']], ...row};
      }
    }
    return byId.values.toList();
  }

  void _subscribe() {
    if (_channel != null) return;
    final ch = _db.channel('live-changes');
    for (final t in ['orders', 'order_items', 'stock_items']) {
      ch.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: t,
        callback: (_) {
          _pull(t).then((_) {}, onError: (_) {});
        },
      );
    }
    ch.subscribe();
    _channel = ch;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _connSub?.cancel();
    super.dispose();
  }
}
