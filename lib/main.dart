import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth/auth_service.dart';
import 'config.dart';
import 'data/db_profiles.dart';
import 'data/local_store.dart';
import 'data/pg_client.dart';
import 'data/sync_service.dart';
import 'platform/error_log.dart';
import 'platform/tab_guard.dart';
import 'screens/login_screen.dart';
import 'screens/shell.dart';
import 'theme.dart';

/// Global PgClient for the app — null when using Supabase.
PgClient? globalPgClient;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocalStore.init();

  if (DbProfiles.isPostgres) {
    await _initPostgres();
  } else {
    await _initSupabase();
  }

  await AuthService.instance.restore();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    ErrorLog.record(details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    ErrorLog.record(error, stack);
    return true;
  };
  TabGuard.instance.start();

  if (!DbProfiles.isPostgres) {
    Supabase.instance.client.auth.onAuthStateChange.listen((state) {
      if (state.session != null) SyncService.instance.syncNow();
    });
  }
  SyncService.instance.start();

  runApp(const PosApp());
}

Future<void> _initSupabase() async {
  LocalStore.currentUser = () => Supabase.instance.client.auth.currentUser?.id;
  await Supabase.initialize(
    url: DbProfiles.url,
    anonKey: DbProfiles.key,
  );
  SyncService.instance.useSupabase();
}

Future<void> _initPostgres() async {
  // currentUser reads from AuthService in postgres mode.
  LocalStore.currentUser = () => AuthService.instance.localUserId;
  try {
    globalPgClient = await PgClient.connect(
      host: DbProfiles.pgHost,
      port: DbProfiles.pgPort,
      database: DbProfiles.pgDatabase,
      username: DbProfiles.pgUsername,
      password: DbProfiles.pgPassword,
    );
    AuthService.instance.pgClient = globalPgClient;
    SyncService.instance.usePostgres(globalPgClient!);
  } catch (e) {
    // Connection may fail if the database is not ready yet.
    // The app will show an error at sign-in time.
    ErrorLog.record(e, StackTrace.current);
  }

  // Supabase still needs to be initialized (many widgets reference it), but
  // we use a dummy url/key so it never actually connects.
  await Supabase.initialize(
    url: 'http://127.0.0.1:0',
    anonKey: 'eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiIiLCJpYXQiOjAsImV4cCI6MjAwMDAwMDAwMCwicm9sZSI6ImFub24ifQ.placeholder-key-for-offline-mode-not-used',
  );
}

class PosApp extends StatelessWidget {
  const PosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RestoPOS',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: ValueListenableBuilder<bool>(
        valueListenable: TabGuard.instance.blocked,
        builder: (context, blocked, _) => blocked
            ? const _OtherTabScreen()
            : ListenableBuilder(
                listenable: AuthService.instance,
                builder: (context, _) =>
                    AuthService.instance.signedIn ? const Shell() : const LoginScreen(),
              ),
      ),
    );
  }
}

/// Shown in an older browser tab when the app was opened in a newer one.
class _OtherTabScreen extends StatelessWidget {
  const _OtherTabScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Brand.navy,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.tab, color: Brand.gold, size: 56),
            const SizedBox(height: 16),
            const Text('RestoPOS is open in another tab',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            const Text(
                'Use one tab per device so orders and offline changes are not mixed up. Close this tab, or use it here instead.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFFB8C3DE))),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () {
                TabGuard.instance.takeOver();
                SyncService.instance.syncNow();
              },
              child: const Text('Use it here instead'),
            ),
          ]),
        ),
      ),
    );
  }
}
