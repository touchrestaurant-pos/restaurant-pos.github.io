import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_service.dart';
import 'db_profiles.dart';
import 'pg_client.dart';

/// A single place that routes the small set of database calls several
/// screens make straight against Supabase, so they also work against the
/// local Postgres connection in offline mode.
///
/// In cloud mode everything forwards to the real Supabase client, exactly
/// as before. In local/offline mode:
///  - [rpc] runs the matching Postgres function (same migrations create it
///    in both databases) over the local connection.
///  - [from] returns a [PgQuery] that understands the small subset of the
///    Supabase query-builder API this app actually uses (select / insert /
///    update / delete with eq / gte / order / limit / range / single) and
///    turns it into plain parameterised SQL.
class AppDb {
  static Future<dynamic> rpc(String name, {Map<String, dynamic>? params}) async {
    if (!DbProfiles.isPostgres) {
      return Supabase.instance.client.rpc(name, params: params);
    }
    final pg = AuthService.instance.pgClient;
    if (pg == null) throw Exception('Database not connected.');
    final args = params ?? const <String, dynamic>{};
    final callArgs = args.keys.map((k) => '$k := @$k').join(', ');
    final rows = await pg.query('SELECT public.$name($callArgs) AS result', args);
    if (rows.isEmpty) return null;
    return rows.first['result'];
  }

  /// Returns a query builder for [table]. In cloud mode this is the real
  /// Supabase `PostgrestQueryBuilder`; in local mode it's a [PgQuery].
  /// Deliberately `dynamic` so callers written against the Supabase builder
  /// keep working unchanged against either backend.
  static dynamic from(String table) {
    if (!DbProfiles.isPostgres) {
      return Supabase.instance.client.from(table);
    }
    final pg = AuthService.instance.pgClient;
    if (pg == null) throw Exception('Database not connected.');
    return PgQuery._(pg, table);
  }
}

class _Cond {
  _Cond(this.col, this.op, this.val);
  final String col;
  final String op;
  final dynamic val;
}

/// A deferred, chainable table query against the local Postgres connection,
/// mirroring just the parts of Supabase's query builder this app calls:
/// `.select()/.insert()/.update()/.delete()` combined with
/// `.eq()/.gte()/.order()/.limit()/.range()/.single()`.
///
/// Implements [Future] (like Supabase's own builder) so `await` works after
/// any chain of filter calls, without callers needing to change.
class PgQuery implements Future<dynamic> {
  PgQuery._(this._pg, this._table);

  final PgClient _pg;
  final String _table;
  String _select = '*';
  final List<_Cond> _conds = [];
  String? _orderCol;
  bool _orderAsc = true;
  int? _limit;
  int? _rangeFrom;
  int? _rangeTo;
  bool _single = false;

  bool _isInsert = false;
  bool _isUpdate = false;
  bool _isDelete = false;
  dynamic _insertRows;
  Map<String, dynamic>? _updateRow;

  PgQuery select([String columns = '*']) {
    _select = columns;
    return this;
  }

  PgQuery insert(dynamic rows) {
    _isInsert = true;
    _insertRows = rows;
    return this;
  }

  PgQuery update(Map<String, dynamic> row) {
    _isUpdate = true;
    _updateRow = row;
    return this;
  }

  PgQuery delete() {
    _isDelete = true;
    return this;
  }

  PgQuery eq(String col, dynamic val) {
    _conds.add(_Cond(col, '=', val));
    return this;
  }

  PgQuery gte(String col, dynamic val) {
    _conds.add(_Cond(col, '>=', val));
    return this;
  }

  PgQuery order(String col, {bool ascending = true}) {
    _orderCol = col;
    _orderAsc = ascending;
    return this;
  }

  PgQuery limit(int n) {
    _limit = n;
    return this;
  }

  PgQuery range(int from, int to) {
    _rangeFrom = from;
    _rangeTo = to;
    return this;
  }

  PgQuery single() {
    _single = true;
    return this;
  }

  (String, Map<String, dynamic>) _whereClause() {
    final parts = <String>[];
    final params = <String, dynamic>{};
    for (var i = 0; i < _conds.length; i++) {
      final c = _conds[i];
      final key = 'w${i}_${c.col}';
      parts.add('${c.col} ${c.op} @$key');
      params[key] = c.val;
    }
    return (parts.isEmpty ? '' : ' WHERE ${parts.join(' AND ')}', params);
  }

  Future<dynamic> _run() async {
    if (_isInsert) return _runInsert();
    if (_isUpdate) return _runUpdate();
    if (_isDelete) return _runDelete();
    return _runSelect();
  }

  Future<dynamic> _runInsert() async {
    final rows = _insertRows is List ? (_insertRows as List) : [_insertRows];
    if (rows.isEmpty) return _single ? null : <Map<String, dynamic>>[];
    final results = <Map<String, dynamic>>[];
    for (final r in rows) {
      final m = Map<String, dynamic>.from(r as Map);
      final cols = m.keys.toList();
      final params = <String, dynamic>{};
      final placeholders = <String>[];
      for (final c in cols) {
        params['v_$c'] = m[c];
        placeholders.add('@v_$c');
      }
      final sql = 'INSERT INTO public.$_table (${cols.join(', ')}) VALUES (${placeholders.join(', ')}) '
          'RETURNING $_select';
      final res = await _pg.query(sql, params);
      results.addAll(res);
    }
    if (_single) return results.isEmpty ? null : results.first;
    return results;
  }

  Future<dynamic> _runUpdate() async {
    final (whereSql, whereParams) = _whereClause();
    final sets = <String>[];
    final params = Map<String, dynamic>.from(whereParams);
    _updateRow!.forEach((k, v) {
      sets.add('$k = @u_$k');
      params['u_$k'] = v;
    });
    final sql = 'UPDATE public.$_table SET ${sets.join(', ')}$whereSql RETURNING $_select';
    final res = await _pg.query(sql, params);
    if (_single) return res.isEmpty ? null : res.first;
    return res;
  }

  Future<dynamic> _runDelete() async {
    final (whereSql, whereParams) = _whereClause();
    await _pg.execute('DELETE FROM public.$_table$whereSql', whereParams);
    return null;
  }

  Future<dynamic> _runSelect() async {
    final (whereSql, whereParams) = _whereClause();
    var sql = 'SELECT $_select FROM public.$_table$whereSql';
    if (_orderCol != null) sql += ' ORDER BY $_orderCol ${_orderAsc ? 'ASC' : 'DESC'}';
    if (_rangeFrom != null) {
      final take = _rangeTo! - _rangeFrom! + 1;
      sql += ' LIMIT $take OFFSET $_rangeFrom';
    } else if (_limit != null) {
      sql += ' LIMIT $_limit';
    }
    final res = await _pg.query(sql, whereParams);
    if (_single) {
      if (res.isEmpty) throw Exception('No rows found in $_table for this query.');
      return res.first;
    }
    return res;
  }

  @override
  Stream<dynamic> asStream() => _run().asStream();

  @override
  Future<dynamic> catchError(Function onError, {bool Function(Object error)? test}) =>
      _run().catchError(onError, test: test);

  @override
  Future<R> then<R>(FutureOr<R> Function(dynamic value) onValue, {Function? onError}) =>
      _run().then(onValue, onError: onError);

  @override
  Future<dynamic> timeout(Duration timeLimit, {FutureOr<dynamic> Function()? onTimeout}) =>
      _run().timeout(timeLimit, onTimeout: onTimeout);

  @override
  Future<dynamic> whenComplete(FutureOr<void> Function() action) => _run().whenComplete(action);
}
