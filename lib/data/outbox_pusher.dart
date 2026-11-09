import 'local_store.dart';

/// The server understood the change and refused it (a rule, a missing record).
/// Anything else thrown by a backend means "cannot reach the server" and stops
/// the upload until next time.
class RefusedException implements Exception {
  RefusedException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Where changes are sent. The real one talks to Supabase; the tests use a fake.
abstract class SyncBackend {
  /// Adds a new row. Must do nothing if the row is already there (a retry).
  Future<void> insert(String table, Map<String, dynamic> row);

  /// Changes some fields. Returns false when no row was changed.
  Future<bool> update(String table, dynamic id, Map<String, dynamic> fields);

  Future<void> delete(String table, dynamic id);
}

class PushResult {
  int sent = 0;
  int refused = 0;
  String? lastError;
}

/// Sends waiting changes oldest first.
///
/// - A row whose earlier change could not be saved is held back, so its later
///   changes are never applied out of order.
/// - A refused change is retried on later syncs and listed as "not saved" after
///   [LocalStore.maxAttempts] refusals.
/// - A connection error stops the upload; everything stays queued.
Future<PushResult> pushOutbox(SyncBackend backend) async {
  final result = PushResult();
  final heldBack = <String>{};
  for (final entry in LocalStore.pending()) {
    final item = entry.value;
    final key = LocalStore.rowKey(item);
    if (LocalStore.isFailed(item)) {
      heldBack.add(key);
      continue;
    }
    if (heldBack.contains(key)) continue;
    final table = item['table'] as String;
    try {
      switch (item['op']) {
        case 'insert':
          await backend.insert(table, Map<String, dynamic>.from(item['row'] as Map));
          break;
        case 'update':
          final ok = await backend.update(
              table, item['id'], Map<String, dynamic>.from(item['fields'] as Map));
          if (!ok) {
            throw RefusedException(
                'Not saved: the record is not on the server yet, or this login may not change it.');
          }
          break;
        case 'delete':
          await backend.delete(table, item['id']);
          break;
        // Entries written by the previous version of the app.
        case 'upsert':
          final row = Map<String, dynamic>.from(item['row'] as Map);
          final fields = Map<String, dynamic>.from(row)..remove('id');
          final updated = fields.isNotEmpty && await backend.update(table, row['id'], fields);
          if (!updated) await backend.insert(table, row);
          break;
      }
      await LocalStore.removePending(entry.key);
      result.sent++;
    } on RefusedException catch (e) {
      await LocalStore.markFailed(entry.key, e.message);
      heldBack.add(key);
      result.refused++;
      result.lastError = e.message;
    }
  }
  return result;
}
