import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_service.dart';
import '../data/db_profiles.dart';
import '../theme.dart';

/// Lets the signed-in person choose their own new password.
Future<void> showChangePasswordDialog(BuildContext context) async {
  final done = await showDialog<bool>(
    context: context,
    builder: (_) => const _ChangePasswordDialog(),
  );
  if (done == true && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Password changed')));
  }
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _one = TextEditingController();
  final _two = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _one.dispose();
    _two.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_one.text.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters.');
      return;
    }
    if (_one.text != _two.text) {
      setState(() => _error = 'The two passwords do not match.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (DbProfiles.isPostgres) {
        final pg = AuthService.instance.pgClient;
        final uid = AuthService.instance.localUserId;
        if (pg == null || uid == null) throw Exception('Database not connected.');
        await pg.execute(
          "UPDATE auth.users SET encrypted_password = crypt(@pw, gen_salt('bf')) WHERE id = @id",
          {'pw': _one.text, 'id': uid},
        );
      } else {
        await Supabase.instance.client.auth
            .updateUser(UserAttributes(password: _one.text));
      }
      if (mounted) Navigator.pop(context, true);
    } on AuthException catch (e) {
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (_) {
      setState(() {
        _busy = false;
        _error = 'Cannot reach the server. Changing your password needs internet.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Change my password'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _one,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New password'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _two,
              obscureText: true,
              onSubmitted: (_) => _save(),
              decoration: const InputDecoration(labelText: 'New password again'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Brand.red)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_busy ? 'Saving...' : 'Change password'),
        ),
      ],
    );
  }
}
