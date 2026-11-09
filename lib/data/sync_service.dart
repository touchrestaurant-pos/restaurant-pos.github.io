import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'local_store.dart';
import 'outbox_pusher.dart';

/// Sends changes to Supabase. A refusal from the server becomes a
/// [RefusedException]; connection problems are passed on unchanged so the
/// upload stops and is tried again later.
class SupabaseBackend implements SyncBackend {
  SupabaseClient get _db => Supabase.instance.client;

  Never _refuseOrRethrow(PostgrestException e) {
    final expired = e.code == 'PGRST301' || e.message.toLowerCase().contains('jwt');
    if (expired) throw Exception('Session expired: ${e.message}');
    throw RefusedException(e.message);
  }

  @override
  Future<void> insert(String table, Map<String, dynamic> row) async {
    try {
      // On a retry the row may already be there: then nothing happens.
      await _db.from(table).upsert(row, onConflict: 'id', ignoreDuplicates: true);
    } on PostgrestException catch (e) {
      _refuseOrRethrow(e);
    }
  }

  @override
  Future<bool> update(String table, dynamic id, Map<String, dynamic> fields) async {
    try {
      final res = await _db.from(table).update(fields).eq('id', id).select('id');
      return res.isNotEmpty;
    } on PostgrestException catch (e) {
      _refuseOrRethrow(e);
    }
  }

  @override
  Future<void> delete(String table, dynamic id) async {
    try {
      await _db.from(table).delete().eq('id', id);
    } on PostgrestException catch (e) {
      _refuseOrRethrow(e);
    }
  }
}

/// Keeps the device copy and Supabase in step.
///
/// 1. Sends everything waiting in the outbox (oldest first, changed fields only).
/// 2. Downloads fresh copies of the tables this staff member may see.
/// 3. Listens for live changes (kitchen queue, stock levels).
///
/// If the internet is down nothing breaks: the app keeps using the device copy
/// and tries again every 30 seconds and whenever the connection returns.
class SyncService extends ChangeNotifier {
  SyncService._();
  static final instance = SyncService._();

  SupabaseClient get _db => Supabase.instance.client;
  final SyncBackend _backend = SupabaseBackend();

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
  bool _again = false;
  DateTime? lastSync;
  String? lastError;

  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  RealtimeChannel? _channel;

  int get pendingCount => LocalStore.pendingCount;
  int get failedCount => LocalStore.failedCount;

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

  /// Safe to call often: a call made while a sync is running schedules one more.
  Future<void> syncNow() async {
    if (_db.auth.currentSession == null) return;
    if (syncing) {
      _again = true;
      return;
    }
    syncing = true;
    notifyListeners();
    try {
      final pushed = await pushOutbox(_backend);
      for (final t in pullTables) {
        await _pull(t);
      }
      _subscribe();
      lastSync = DateTime.now();
      lastError = pushed.lastError;
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
    if (_again) {
      _again = false;
      await syncNow();
    }
  }

  /// "Retry" on the not-saved list.
  Future<void> retryFailed() async {
    await LocalStore.resetAttempts();
    notifyListeners();
    await syncNow();
  }

  Future<void> discard(String key) async {
    await LocalStore.removePending(key);
    notifyListeners();
    await syncNow();
  }

  Future<void> _pull(String table) async {
    List<dynamic> data;
    if (table == 'orders') {
      final since = DateTime.now().subtract(const Duration(days: 2)).toUtc().toIso8601String();
      data = await _db.from('orders').select().gte('created_at', since).order('created_at');
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
    await LocalStore.setRows(table, withPending(table, server));
    notifyListeners();
  }

  /// Puts changes that have not been uploaded yet back on top of the fresh
  /// server copy, so they do not disappear from the screen.
  static List<Map<String, dynamic>> withPending(String table, List<Map<String, dynamic>> server) {
    if (table == 'recipe_lines') return server; // no single id column
    final byId = <dynamic, Map<String, dynamic>>{for (final r in server) r['id']: r};
    for (final entry in LocalStore.pending()) {
      final item = entry.value;
      if (item['table'] != table) continue;
      switch (item['op']) {
        case 'insert':
        case 'upsert':
          final row = Map<String, dynamic>.from(item['row'] as Map);
          byId[row['id']] = {...?byId[row['id']], ...row};
          break;
        case 'update':
          final id = item['id'];
          final existing = byId[id];
          if (existing != null) {
            byId[id] = {...existing, ...Map<String, dynamic>.from(item['fields'] as Map)};
          }
          break;
        case 'delete':
          byId.remove(item['id']);
          break;
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
