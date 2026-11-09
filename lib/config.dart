/// Supabase connection details.
///
/// The URL and publishable key are safe to ship inside the app: what each
/// signed-in user can see or change is controlled by the row level security
/// rules in supabase/migrations. NEVER put the service-role key or the database
/// password in this app.
///
/// Override at build time if needed:
///   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_KEY=...
class AppConfig {
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://kemnuculvkkyfzjnwvrp.supabase.co',
  );

  /// Staff sign in with a username. Supabase needs an email, so the app turns
  /// "thandi" into "thandi@<this domain>". Nobody ever receives mail there.
  /// Must match STAFF_LOGIN_DOMAIN in supabase/functions/create-staff.
  static const staffLoginDomain = 'touchrestaurant-pos.github.io';

  static const supabaseKey = String.fromEnvironment(
    'SUPABASE_KEY',
    defaultValue: 'sb_publishable_OAld3pVVrbDnWVWMJRXJtg_5y8oAUO6',
  );

  /// Shown under Settings. Raise it with every release.
  static const appVersion = '1.2.0';
}
