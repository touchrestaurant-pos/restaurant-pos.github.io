import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_service.dart';
import 'db_profiles.dart';

/// Calls a database "stored procedure" by name, the same way the app
/// already calls Supabase's `.rpc(name, params: {...})`.
///
/// In cloud mode this just forwards to Supabase. In local/offline mode it
/// runs the matching Postgres function directly over the local connection
/// (the same functions, created by the same migrations, exist in both
/// databases) — so reports, day-close, refunds, stocktakes, supplier and
/// account actions all keep working without internet.
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
}
