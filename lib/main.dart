import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth/auth_service.dart';
import 'config.dart';
import 'data/local_store.dart';
import 'data/sync_service.dart';
import 'screens/login_screen.dart';
import 'screens/shell.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocalStore.init();
  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.supabaseKey,
  );
  await AuthService.instance.restore();

  Supabase.instance.client.auth.onAuthStateChange.listen((state) {
    if (state.session != null) SyncService.instance.syncNow();
  });
  SyncService.instance.start();

  runApp(const PosApp());
}

class PosApp extends StatelessWidget {
  const PosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RestoPOS',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: ListenableBuilder(
        listenable: AuthService.instance,
        builder: (context, _) =>
            AuthService.instance.signedIn ? const Shell() : const LoginScreen(),
      ),
    );
  }
}
