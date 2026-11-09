import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

/// Everything the app needs to keep working without internet.
///
/// - cache:  last copy of each Supabase table (menu, stock, orders ...)
/// - outbox: changes made on this device that still have to be sent
/// - meta:   small values such as the signed-in staff profile
///
/// Rows get their id (a uuid) on the device, so an order created offline can be
/// uploaded later without clashing with orders from other tills.
class LocalStore {
  LocalStore._();

  static late Box _cache;
  static late Box _outbox;
  static late Box _meta;
  static const _uuid = Uuid();

  static Future<void> init() async {
    await Hive.initFlutter();
    _cache = await Hive.openBox('cache');
    _outbox = await Hive.openBox('outbox');
    _meta = await Hive.openBox('meta');
  }

  static String newId() => _uuid.v4();

  // ---- cached tables ----------------------------------------------------

  static List<Map<String, dynamic>> rows(String table) {
    final raw = _cache.get(table);
    if (raw is! List) return [];
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  static Future<void> setRows(String table, List<Map<String, dynamic>> rows) =>
      _cache.put(table, rows);

  /// Saves a row on this device straight away and queues it for upload.
  static Future<void> upsert(String table, Map<String, dynamic> row) async {
    final list = rows(table);
    final i = list.indexWhere((r) => r['id'] == row['id']);
    if (i >= 0) {
      list[i] = {...list[i], ...row};
    } else {
      list.add(row);
    }
    await _cache.put(table, list);
    await _queue(table, 'upsert', row);
  }

  static Future<void> delete(String table, String id) async {
    final list = rows(table)..removeWhere((r) => r['id'] == id);
    await _cache.put(table, list);
    await _queue(table, 'delete', {'id': id});
  }

  // ---- outbox -------------------------------------------------------------

  static Future<void> _queue(
      String table, String op, Map<String, dynamic> row) async {
    final key = '${DateTime.now().microsecondsSinceEpoch}-${_uuid.v4()}';
    await _outbox.put(key, {'table': table, 'op': op, 'row': row, 'attempts': 0});
  }

  static int get pendingCount => _outbox.length;

  /// Waiting changes, oldest first.
  static List<MapEntry<String, Map<String, dynamic>>> pending() {
    final keys = _outbox.keys.cast<String>().toList()..sort();
    return keys
        .map((k) => MapEntry(k, Map<String, dynamic>.from(_outbox.get(k) as Map)))
        .toList();
  }

  static Future<void> removePending(String key) => _outbox.delete(key);

  static Future<void> markFailed(String key, String error) async {
    final item = Map<String, dynamic>.from(_outbox.get(key) as Map);
    item['attempts'] = ((item['attempts'] ?? 0) as int) + 1;
    item['error'] = error;
    await _outbox.put(key, item);
  }

  // ---- meta ---------------------------------------------------------------

  static dynamic getMeta(String key) => _meta.get(key);
  static Future<void> setMeta(String key, dynamic value) =>
      _meta.put(key, value);
  static Future<void> removeMeta(String key) => _meta.delete(key);
}
