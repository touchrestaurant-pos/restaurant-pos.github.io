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

  static const supabaseKey = String.fromEnvironment(
    'SUPABASE_KEY',
    defaultValue: 'sb_publishable_OAld3pVVrbDnWVWMJRXJtg_5y8oAUO6',
  );
}
