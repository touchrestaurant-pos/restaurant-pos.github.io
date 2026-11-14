import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_service.dart';
import '../data/db_profiles.dart';
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

  bool _restart = false;

  /// Pick which database this device uses, or add another one (for example the store's local server).
  Future<void> _chooseDatabase() async {
    final started = DbProfiles.activeName;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        Future<void> add() async {
          final name = TextEditingController(), url = TextEditingController(), key = TextEditingController();
          String? err;
          final ok = await showDialog<bool>(
            context: ctx,
            builder: (d) => StatefulBuilder(
              builder: (d, set2) => AlertDialog(
                title: const Text('Add a database'),
                content: SizedBox(
                  width: 420,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(controller: name, decoration: const InputDecoration(labelText: 'Name (for example Main store)')),
                    const SizedBox(height: 8),
                    TextField(
                        controller: url,
                        decoration: const InputDecoration(labelText: 'Address', hintText: 'http://127.0.0.1:54321')),
                    const SizedBox(height: 8),
                    TextField(controller: key, maxLines: 3, minLines: 1, decoration: const InputDecoration(labelText: 'Key')),
                    const SizedBox(height: 6),
                    const Text('Both are in connection.txt in the Store Kit folder on the store computer.',
                        style: TextStyle(color: Brand.muted, fontSize: 12)),
                    if (err != null)
                      Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Brand.red))),
                  ]),
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () {
                        final e = DbProfiles.check(name.text, url.text, key.text);
                        if (e != null) {
                          set2(() => err = e);
                        } else {
                          Navigator.pop(d, true);
                        }
                      },
                      child: const Text('Save')),
                ],
              ),
            ),
          );
          if (ok == true) {
            await DbProfiles.save(name.text, url.text, key.text);
            set(() {});
          }
        }

        return AlertDialog(
          title: const Text('Which database?'),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final p in DbProfiles.all)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(p['name'] == DbProfiles.activeName ? Icons.radio_button_checked : Icons.radio_button_off,
                      color: Brand.navy),
                  title: Text(p['name']!, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(p['url']!, style: const TextStyle(fontSize: 12)),
                  trailing: p['name'] == DbProfiles.onlineName
                      ? null
                      : IconButton(
                          tooltip: 'Remove from this device',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: p['name'] == DbProfiles.activeName
                              ? null
                              : () async {
                                  await DbProfiles.remove(p['name']!);
                                  set(() {});
                                }),
                  onTap: () async {
                    final err = await DbProfiles.use(p['name']!);
                    if (err != null && ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(err)));
                    }
                    set(() {});
                  },
                ),
              const SizedBox(height: 6),
              OutlinedButton.icon(onPressed: add, icon: const Icon(Icons.add), label: const Text('Add a database')),
              const SizedBox(height: 8),
              const Text(
                  'Each database has its own staff, menu, stock and sales. Switching removes this device\'s copy of the old one (nothing is deleted on the server).',
                  style: TextStyle(color: Brand.muted, fontSize: 12)),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
        );
      }),
    );
    if (mounted) setState(() => _restart = _restart || DbProfiles.activeName != started);
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
                if (_restart)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text('Database changed. Close the app completely and open it again to sign in.',
                        textAlign: TextAlign.center, style: TextStyle(color: Brand.gold, fontWeight: FontWeight.w700)),
                  ),
                FilledButton(
                  onPressed: _busy || _restart ? null : _signIn,
                  child: Text(_busy ? 'Signing in...' : 'Sign in'),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Forgot your password? Ask your admin to set a new one.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFFB8C3DE), fontSize: 13),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _chooseDatabase,
                  icon: const Icon(Icons.storage, size: 16, color: Color(0xFFB8C3DE)),
                  label: Text('Database: ${DbProfiles.activeName}',
                      style: const TextStyle(color: Color(0xFFB8C3DE), fontSize: 13)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
