import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../data/db_profiles.dart';
import '../data/local_store.dart';
import '../data/pg_client.dart';

/// Signed-in staff member and their role (cashier, kitchen, stock, admin,
/// supervisor). The staff profile is saved on the device, so someone who has
/// signed in before can open the app again while offline.
class AuthService extends ChangeNotifier {
  AuthService._();
  static final instance = AuthService._();

  /// Postgres connection for local auth — set from main.dart when in postgres mode.
  PgClient? pgClient;

  /// The id of the locally-authenticated user (postgres mode only).
  String? _localUserId;
  String? get localUserId => _localUserId;

  Map<String, dynamic>? profile;

  bool get signedIn {
    if (DbProfiles.isPostgres) return _localUserId != null && profile != null;
    return _supabaseClient.auth.currentSession != null && profile != null;
  }

  String? get currentUserId {
    if (DbProfiles.isPostgres) return _localUserId;
    return _supabaseClient.auth.currentUser?.id;
  }

  String get role => (profile?['role'] ?? '') as String;
  String get fullName => (profile?['full_name'] ?? '') as String;

  SupabaseClient get _supabaseClient => Supabase.instance.client;

  /// Called once at start-up.
  Future<void> restore() async {
    if (DbProfiles.isPostgres) {
      // Restore from cached profile.
      final cached = LocalStore.getMeta('profile');
      if (cached is Map) {
        profile = Map<String, dynamic>.from(cached);
        _localUserId = profile?['id']?.toString();
      }
      return;
    }
    if (_supabaseClient.auth.currentSession == null) return;
    final cached = LocalStore.getMeta('profile');
    if (cached is Map) profile = Map<String, dynamic>.from(cached);
    try {
      await _loadProfile();
    } catch (_) {
      // Offline: keep the cached profile.
    }
  }

  /// Returns null on success, otherwise a message to show the user.
  Future<String?> signIn(String login, String password) async {
    if (DbProfiles.isPostgres) return _signInPostgres(login, password);
    return _signInSupabase(login, password);
  }

  // ── Supabase (cloud) sign-in ──────────────────────────────────────────

  Future<String?> _signInSupabase(String login, String password) async {
    final typed = login.trim();
    if (typed.isEmpty) return 'Enter your username.';
    final email = typed.contains('@')
        ? typed
        : '${typed.toLowerCase()}@${AppConfig.staffLoginDomain}';
    try {
      await _supabaseClient.auth.signInWithPassword(email: email, password: password);
      await _loadProfile();
      if (profile == null) return 'No staff profile was found for this user.';
      if (profile!['active'] == false) {
        await signOut();
        return 'This staff account has been switched off.';
      }
      return null;
    } on AuthException catch (e) {
      return e.message;
    } catch (_) {
      return 'Cannot reach the server. The first sign-in needs internet.';
    }
  }

  Future<void> _loadProfile() async {
    final uid = _supabaseClient.auth.currentUser?.id;
    if (uid == null) return;
    final row =
        await _supabaseClient.from('staff_profiles').select().eq('id', uid).maybeSingle();
    if (row != null) {
      profile = row;
      await LocalStore.setMeta('profile', row);
      notifyListeners();
    }
  }

  // ── Postgres (local) sign-in ──────────────────────────────────────────

  Future<String?> _signInPostgres(String login, String password) async {
    final typed = login.trim();
    if (typed.isEmpty) return 'Enter your username.';
    if (pgClient == null) return 'Database not connected.';

    final email = typed.contains('@')
        ? typed
        : '${typed.toLowerCase()}@store.local';

    try {
      // Look up the user in auth.users (created by local_create_admin.sql or the admin screen).
      final users = await pgClient!.query(
        "SELECT id, encrypted_password FROM auth.users WHERE email = @email",
        {'email': email},
      );
      if (users.isEmpty) return 'No account found for that username.';
      final row = users.first;
      final hash = row['encrypted_password'] as String? ?? '';

      // Verify the password against the bcrypt hash using pgcrypto in PostgreSQL.
      final check = await pgClient!.query(
        "SELECT (encrypted_password = crypt(@password, encrypted_password)) AS ok "
        "FROM auth.users WHERE email = @email",
        {'email': email, 'password': password},
      );
      if (check.isEmpty || check.first['ok'] != true) return 'Wrong password.';

      final uid = row['id'].toString();
      _localUserId = uid;

      // Set the current user for auth.uid() in SQL triggers/functions.
      await pgClient!.setCurrentUser(uid);

      // Load staff profile.
      final profiles = await pgClient!.query(
        "SELECT * FROM public.staff_profiles WHERE id = @id",
        {'id': uid},
      );
      if (profiles.isEmpty) return 'No staff profile was found for this user.';

      profile = profiles.first;
      if (profile!['active'] == false) {
        await signOut();
        return 'This staff account has been switched off.';
      }
      await LocalStore.setMeta('profile', profile);
      notifyListeners();
      return null;
    } catch (e) {
      return 'Database error: $e';
    }
  }

  Future<void> signOut() async {
    if (DbProfiles.isPostgres) {
      _localUserId = null;
      try {
        await pgClient?.setCurrentUser(null);
      } catch (_) {}
    } else {
      try {
        await _supabaseClient.auth.signOut(scope: SignOutScope.local);
      } catch (_) {}
    }
    profile = null;
    await LocalStore.removeMeta('profile');
    notifyListeners();
  }
}
