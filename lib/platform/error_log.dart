import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_service.dart';
import '../config.dart';
import '../data/app_db.dart';
import '../data/db_profiles.dart';
import '../data/local_store.dart';

/// Records app errors on the device and, when online, in the app_errors table
/// so the admin can see problems from every till under Settings.
class ErrorLog {
  static DateTime? _lastSent;

  static Future<void> record(Object error, StackTrace? stack) async {
    final message = error.toString();
    final details = stack?.toString().split('\n').take(12).join('\n');
    try {
      final list = ((LocalStore.getMeta('errors') as List?) ?? const []).toList();
      list.add({'at': DateTime.now().toIso8601String(), 'message': message});
      while (list.length > 50) {
        list.removeAt(0);
      }
      await LocalStore.setMeta('errors', list);
    } catch (_) {}
    // At most one upload every few seconds, so a repeating error cannot flood the server.
    final now = DateTime.now();
    if (_lastSent != null && now.difference(_lastSent!) < const Duration(seconds: 5)) return;
    _lastSent = now;
    try {
      final uid = DbProfiles.isPostgres
          ? AuthService.instance.localUserId
          : Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      await AppDb.from('app_errors').insert({
        'user_id': uid,
        'message': message.length > 2000 ? message.substring(0, 2000) : message,
        'details': details,
        'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
        'app_version': AppConfig.appVersion,
      });
    } catch (_) {
      // Offline/cloud unreachable: it stays in the device list.
    }
  }
}
