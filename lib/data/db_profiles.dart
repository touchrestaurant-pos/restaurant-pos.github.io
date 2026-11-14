import '../config.dart';
import 'local_store.dart';

/// Which database this device talks to. "Online" is the built-in cloud database;
/// the admin can add others (for example the store's own local server) on the sign-in screen.
/// The choice is saved on this device and used the next time the app starts.
class DbProfiles {
  static const onlineName = 'Online (cloud)';

  static List<Map<String, String>> get saved => [
        for (final p in (LocalStore.getMeta('db_profiles') as List? ?? const []))
          {for (final e in (p as Map).entries) '${e.key}': '${e.value}'}
      ];

  static List<Map<String, String>> get all => [
        {'name': onlineName, 'url': AppConfig.supabaseUrl, 'key': AppConfig.supabaseKey},
        ...saved,
      ];

  static String get activeName {
    final n = LocalStore.getMeta('db_active') as String?;
    return all.any((p) => p['name'] == n) ? n! : onlineName;
  }

  static Map<String, String> get active => all.firstWhere((p) => p['name'] == activeName);
  static String get url => active['url']!;
  static String get key => active['key']!;

  /// Null when fine, otherwise what is wrong.
  static String? check(String name, String url, String key) {
    if (name.trim().isEmpty) return 'Give it a name, for example "Main store".';
    if (name.trim() == onlineName) return 'That name is taken.';
    final u = Uri.tryParse(url.trim());
    if (u == null || !(u.isScheme('http') || u.isScheme('https')) || u.host.isEmpty) {
      return 'The address must start with http:// or https://, for example http://192.168.1.10:54321';
    }
    if (key.trim().length < 20) return 'Paste the key from connection.txt in the Store Kit folder.';
    return null;
  }

  static Future<void> save(String name, String url, String key) async {
    final list = saved..removeWhere((p) => p['name'] == name.trim());
    list.add({'name': name.trim(), 'url': url.trim().replaceAll(RegExp(r'/+$'), ''), 'key': key.trim()});
    await LocalStore.setMeta('db_profiles', list);
  }

  static Future<void> remove(String name) async {
    await LocalStore.setMeta('db_profiles', saved..removeWhere((p) => p['name'] == name));
    if (LocalStore.getMeta('db_active') == name) await LocalStore.setMeta('db_active', onlineName);
  }

  /// Switches database. The copy of the old database on this device is removed so the two never mix.
  /// Refused while changes are still waiting to be sent.
  static Future<String?> use(String name) async {
    if (name == activeName) return null;
    if (LocalStore.pendingCount > 0) {
      return '${LocalStore.pendingCount} changes have not been sent to the current database yet. '
          'Sign in and let them sync first, otherwise they would be lost.';
    }
    await LocalStore.clearData();
    await LocalStore.setMeta('db_active', name);
    return null;
  }
}
