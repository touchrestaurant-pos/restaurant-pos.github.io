/// Conditional export: uses the real postgres package on native platforms,
/// and a stub that throws on web (where direct Postgres is impossible).
export 'pg_client_stub.dart' if (dart.library.io) 'pg_client_io.dart';
