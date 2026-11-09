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
///
/// Outbox entries are one of:
///   insert  - a whole new row            {table, op, row}
///   update  - only the fields that changed {table, op, id, fields}
///   delete  - {table, op, id}
/// Sending only changed fields means an out-of-date copy on one device can never
/// overwrite newer values written by another device.
class LocalStore {
  LocalStore._();

  static late Box _cache;
  static late Box _outbox;
  static late Box _meta;
  static const _uuid = Uuid();

  /// After this many refusals a change stops retrying by itself and is listed
  /// as "not saved" so a person can decide.
  static const maxAttempts = 5;

  static Future<void> init() async {
    await Hive.initFlutter();
    await _open();
  }

  /// Used by the automated tests, which have no app folders.
  static Future<void> initAt(String path) async {
    Hive.init(path);
    await _open();
  }

  static Future<void> _open() async {
    _cache = await Hive.openBox('cache');
    _outbox = await Hive.openBox('outbox');
    _meta = await Hive.openBox('meta');
  }

  /// Used by the automated tests.
  static Future<void> clearAll() async {
    await _cache.clear();
    await _outbox.clear();
    await _meta.clear();
  }

  static String newId() => _uuid.v4();

  // ---- cached tables ----------------------------------------------------

  static List<Map<String, dynamic>> rows(String table) {
    final raw = _cache.get(table);
    if (raw is! List) return [];
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  static Map<String, dynamic>? row(String table, dynamic id) {
    for (final r in rows(table)) {
      if (r['id'] == id) return r;
    }
    return null;
  }

  static Future<void> setRows(String table, List<Map<String, dynamic>> rows) =>
      _cache.put(table, rows);

  /// A brand-new row: saved on this device now, sent to the server later.
  static Future<void> insert(String table, Map<String, dynamic> row) async {
    final list = rows(table)..removeWhere((r) => r['id'] == row['id']);
    list.add(Map<String, dynamic>.from(row));
    await _cache.put(table, list);
    await _put({'table': table, 'op': 'insert', 'row': row, 'attempts': 0});
  }

  /// Changes some fields of an existing row. Only these fields are sent.
  static Future<void> patch(String table, dynamic id, Map<String, dynamic> fields) async {
    final changes = Map<String, dynamic>.from(fields)..remove('id');
    if (changes.isEmpty) return;
    final list = rows(table);
    final i = list.indexWhere((r) => r['id'] == id);
    if (i >= 0) {
      list[i] = {...list[i], ...changes};
      await _cache.put(table, list);
    }
    // Fold into a waiting change for the same row if that change has never been
    // tried yet, so one row does not create dozens of uploads.
    final waiting = pending().reversed.where((e) => _rowKey(e.value) == '$table:$id').toList();
    if (waiting.isNotEmpty) {
      final last = waiting.first;
      final item = last.value;
      final untried = ((item['attempts'] ?? 0) as int) == 0;
      if (untried && item['op'] == 'insert') {
        item['row'] = {...Map<String, dynamic>.from(item['row'] as Map), ...changes};
        await _outbox.put(last.key, item);
        return;
      }
      if (untried && item['op'] == 'update') {
        item['fields'] = {...Map<String, dynamic>.from(item['fields'] as Map), ...changes};
        await _outbox.put(last.key, item);
        return;
      }
    }
    await _put({'table': table, 'op': 'update', 'id': id, 'fields': changes, 'attempts': 0});
  }

  /// Kept for older screens: a row already on this device is patched with the
  /// given fields, otherwise it is inserted.
  static Future<void> upsert(String table, Map<String, dynamic> data) async {
    final id = data['id'];
    if (LocalStore.row(table, id) != null) {
      await patch(table, id, data);
    } else {
      await insert(table, data);
    }
  }

  static Future<void> delete(String table, dynamic id) async {
    final list = rows(table)..removeWhere((r) => r['id'] == id);
    await _cache.put(table, list);
    await _put({'table': table, 'op': 'delete', 'id': id, 'attempts': 0});
  }

  // ---- outbox -------------------------------------------------------------

  static Future<void> _put(Map<String, dynamic> item) async {
    final key = '${DateTime.now().microsecondsSinceEpoch.toString().padLeft(17, '0')}-${_uuid.v4()}';
    await _outbox.put(key, item);
  }

  /// "table:id" for an outbox entry.
  static String rowKey(Map<String, dynamic> item) => _rowKey(item);
  static String _rowKey(Map<String, dynamic> item) {
    final id = item['op'] == 'insert' ? (item['row'] as Map)['id'] : item['id'];
    return '${item['table']}:$id';
  }

  static bool isFailed(Map<String, dynamic> item) =>
      ((item['attempts'] ?? 0) as int) >= maxAttempts;

  static int get pendingCount => _outbox.length;

  static int get failedCount =>
      _outbox.values.where((v) => isFailed(Map<String, dynamic>.from(v as Map))).length;

  /// Waiting changes, oldest first.
  static List<MapEntry<String, Map<String, dynamic>>> pending() {
    final keys = _outbox.keys.cast<String>().toList()..sort();
    return keys
        .map((k) => MapEntry(k, Map<String, dynamic>.from(_outbox.get(k) as Map)))
        .toList();
  }

  static List<MapEntry<String, Map<String, dynamic>>> failed() =>
      pending().where((e) => isFailed(e.value)).toList();

  /// Give refused changes another chance (for example after a server fix).
  static Future<void> resetAttempts() async {
    for (final k in _outbox.keys.cast<String>().toList()) {
      final item = Map<String, dynamic>.from(_outbox.get(k) as Map);
      if ((item['attempts'] ?? 0) != 0) {
        item['attempts'] = 0;
        await _outbox.put(k, item);
      }
    }
  }

  static Future<void> removePending(String key) => _outbox.delete(key);

  static Future<void> markFailed(String key, String error) async {
    final raw = _outbox.get(key);
    if (raw == null) return;
    final item = Map<String, dynamic>.from(raw as Map);
    item['attempts'] = ((item['attempts'] ?? 0) as int) + 1;
    item['error'] = error;
    await _outbox.put(key, item);
  }

  // ---- meta ---------------------------------------------------------------

  static dynamic getMeta(String key) => _meta.get(key);
  static Future<void> setMeta(String key, dynamic value) => _meta.put(key, value);
  static Future<void> removeMeta(String key) => _meta.delete(key);
}
