import 'package:supabase_flutter/supabase_flutter.dart';

import 'local_store.dart';
import 'repo.dart';

/// Customer accounts ("sale on account"). The balance and the rules live on the
/// server; this only calls it. An account sale needs the internet, because the
/// credit limit has to be checked against the real balance.
class AccountsRepo {
  static SupabaseClient get _db => Supabase.instance.client;

  /// Accounts switched on in Settings.
  static bool get enabled => companyRow()?['accounts_enabled'] == true;

  static List<Map<String, dynamic>> _list(dynamic v) =>
      ((v as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  /// Accounts the till may use, freshly read. Cashiers only get the ones the admin made visible.
  static Future<List<Map<String, dynamic>>> tillAccounts() async {
    final res = _list(await _db.rpc('till_accounts'));
    await LocalStore.setMeta('till_accounts', res);
    return res;
  }

  static Future<List<Map<String, dynamic>>> ageing() async => _list(await _db.rpc('account_ageing'));

  static Future<String> save(Map<String, dynamic> a) async => '${await _db.rpc('save_account', params: {'p': a})}';

  static Future<void> setStatus(String id, String status, String reason) =>
      _db.rpc('set_account_status', params: {'p_id': id, 'p_status': status, 'p_reason': reason});

  static Future<Map<String, dynamic>> recordPayment({
    required String account,
    required double amount,
    required String method,
    String? reference,
    String? note,
    required String id,
  }) async =>
      Map<String, dynamic>.from(await _db.rpc('record_account_payment', params: {
        'p_account': account,
        'p_amount': amount,
        'p_method': method,
        'p_reference': reference,
        'p_note': note,
        'p_id': id,
      }) as Map);

  static Future<void> writeOff(String account, double amount, String reason) =>
      _db.rpc('account_writeoff', params: {'p_account': account, 'p_amount': amount, 'p_reason': reason});

  static Future<void> reinstate(String account, double amount, String reason) =>
      _db.rpc('account_reinstate', params: {'p_account': account, 'p_amount': amount, 'p_reason': reason});

  static Future<Map<String, dynamic>> statement(String account, DateTime from, DateTime to) async {
    String d(DateTime x) => '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
    return Map<String, dynamic>.from(
        await _db.rpc('account_statement', params: {'p_account': account, 'p_from': d(from), 'p_to': d(to)}) as Map);
  }

  /// Turns a server error into a sentence a person can act on.
  static String message(Object e) {
    if (e is PostgrestException) return e.message;
    final s = '$e';
    if (s.contains('SocketException') || s.contains('Failed host lookup') || s.contains('ClientException')) {
      return 'No internet. Account sales and account payments need a connection.';
    }
    return s;
  }
}
