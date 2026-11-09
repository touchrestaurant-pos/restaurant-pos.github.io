import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/local_store.dart';

/// Signed-in staff member and their role (cashier, kitchen, stock, admin,
/// supervisor). The staff profile is saved on the device, so someone who has
/// signed in before can open the app again while offline.
///
/// First version: email and password. Staff PIN login is added after the
/// screens are in place.
class AuthService extends ChangeNotifier {
  AuthService._();
  static final instance = AuthService._();

  SupabaseClient get _db => Supabase.instance.client;

  Map<String, dynamic>? profile;

  bool get signedIn => _db.auth.currentSession != null && profile != null;
  String get role => (profile?['role'] ?? '') as String;
  String get fullName => (profile?['full_name'] ?? '') as String;

  /// Called once at start-up.
  Future<void> restore() async {
    if (_db.auth.currentSession == null) return;
    final cached = LocalStore.getMeta('profile');
    if (cached is Map) profile = Map<String, dynamic>.from(cached);
    try {
      await _loadProfile();
    } catch (_) {
      // Offline: keep the cached profile.
    }
  }

  /// Returns null on success, otherwise a message to show the user.
  Future<String?> signIn(String email, String password) async {
    try {
      await _db.auth.signInWithPassword(email: email.trim(), password: password);
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
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    final row =
        await _db.from('staff_profiles').select().eq('id', uid).maybeSingle();
    if (row != null) {
      profile = row;
      await LocalStore.setMeta('profile', row);
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    try {
      await _db.auth.signOut(scope: SignOutScope.local);
    } catch (_) {}
    profile = null;
    await LocalStore.removeMeta('profile');
    notifyListeners();
  }
}
