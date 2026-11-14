import 'dart:convert';
import 'package:postgres/postgres.dart';

/// Wraps the `postgres` package connection with a simpler API that matches
/// what the POS sync and auth layers need.
class PgClient {
  PgClient._(this._conn);

  Connection _conn;
  bool _closed = false;

  static Future<PgClient> connect({
    required String host,
    required int port,
    required String database,
    required String username,
    required String password,
  }) async {
    final conn = await Connection.open(
      Endpoint(host: host, port: port, database: database, username: username, password: password),
      settings: ConnectionSettings(sslMode: SslMode.disable),
    );
    return PgClient._(conn);
  }

  Future<void> close() async {
    if (!_closed) {
      _closed = true;
      await _conn.close();
    }
  }

  bool get isOpen => !_closed;

  /// Sets the current user id for auth.uid() in SQL functions.
  Future<void> setCurrentUser(String? userId) async {
    if (userId != null) {
      await _conn.execute("SET LOCAL app.current_user_id = '$userId'");
    } else {
      await _conn.execute("RESET app.current_user_id");
    }
  }

  /// Runs a SELECT and returns the rows as maps.
  Future<List<Map<String, dynamic>>> query(String sql, [Map<String, dynamic>? params]) async {
    final Result result;
    if (params != null && params.isNotEmpty) {
      result = await _conn.execute(Sql.named(sql), parameters: params);
    } else {
      result = await _conn.execute(sql);
    }
    if (result.schema.columns.isEmpty) return [];
    final columns = result.schema.columns.map((c) => c.columnName ?? '').toList();
    return result.map((row) {
      final map = <String, dynamic>{};
      for (var i = 0; i < columns.length; i++) {
        map[columns[i]] = _dartValue(row[i]);
      }
      return map;
    }).toList();
  }

  /// Runs a non-SELECT statement (INSERT, UPDATE, DELETE, etc.).
  Future<void> execute(String sql, [Map<String, dynamic>? params]) async {
    if (params != null && params.isNotEmpty) {
      await _conn.execute(Sql.named(sql), parameters: params);
    } else {
      await _conn.execute(sql);
    }
  }

  /// Reconnect if the connection was lost.
  Future<void> reconnectIfNeeded({
    required String host,
    required int port,
    required String database,
    required String username,
    required String password,
  }) async {
    if (_closed) {
      _conn = await Connection.open(
        Endpoint(host: host, port: port, database: database, username: username, password: password),
        settings: ConnectionSettings(sslMode: SslMode.disable),
      );
      _closed = false;
    }
  }

  /// Convert Postgres types to Dart-friendly values.
  static dynamic _dartValue(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v.toUtc().toIso8601String();
    if (v is BigInt) return v.toInt();
    if (v is double || v is int || v is bool || v is String) return v;
    if (v is List) return v.map(_dartValue).toList();
    if (v is UndecodedBytes) {
      try {
        return utf8.decode(v.bytes);
      } catch (_) {
        return v.bytes.toString();
      }
    }
    if (v is Map) return v;
    return '$v';
  }
}
