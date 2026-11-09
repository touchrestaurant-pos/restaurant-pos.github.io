import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_service.dart';
import '../data/local_store.dart';
import '../theme.dart';
import '../widgets/brand_mark.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadBrand();
  }

  /// Company name and logo are public, so the login screen can show them.
  Future<void> _loadBrand() async {
    try {
      final row = await Supabase.instance.client
          .from('company_settings')
          .select()
          .maybeSingle();
      if (row != null) {
        await LocalStore.setMeta('brand', row);
        if (mounted) setState(() {});
      }
    } catch (_) {
      // Offline: use the saved copy.
    }
  }

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await AuthService.instance.signIn(_email.text, _password.text);
    if (mounted) {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Brand.navy,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: BrandMark(size: 72)),
                const SizedBox(height: 16),
                Text(
                  companyDisplayName(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Sign in to start your shift',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFFB8C3DE)),
                ),
                const SizedBox(height: 28),
                TextField(
                  controller: _email,
                  autocorrect: false,
                  autofillHints: const [AutofillHints.username],
                  decoration: const InputDecoration(labelText: 'Username'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  onSubmitted: (_) => _signIn(),
                  decoration: const InputDecoration(labelText: 'Password'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!,
                      style: const TextStyle(color: Color(0xFFFFB4BC))),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _signIn,
                  child: Text(_busy ? 'Signing in...' : 'Sign in'),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Forgot your password? Ask your admin to set a new one.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFFB8C3DE), fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
