/// Web stub — direct Postgres connections are not possible in a browser.
/// Every method throws; the app only reaches these when a postgres profile is
/// active, which cannot happen on web.

class PgClient {
  PgClient._();

  static Future<PgClient> connect({
    required String host,
    required int port,
    required String database,
    required String username,
    required String password,
  }) async {
    throw UnsupportedError('Direct Postgres connections are not available on web.');
  }

  Future<void> close() async =>
      throw UnsupportedError('Direct Postgres connections are not available on web.');

  Future<List<Map<String, dynamic>>> query(String sql, [Map<String, dynamic>? params]) async =>
      throw UnsupportedError('Direct Postgres connections are not available on web.');

  Future<void> execute(String sql, [Map<String, dynamic>? params]) async =>
      throw UnsupportedError('Direct Postgres connections are not available on web.');

  Future<void> setCurrentUser(String? userId) async =>
      throw UnsupportedError('Direct Postgres connections are not available on web.');

  bool get isOpen => false;
}
