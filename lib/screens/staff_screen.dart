import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_service.dart';
import '../data/local_store.dart';
import '../data/sync_service.dart';
import '../theme.dart';

const roleLabels = {
  'cashier': 'Cashier',
  'kitchen': 'Kitchen',
  'stock': 'Stock',
  'supervisor': 'Supervisor',
  'admin': 'Admin',
};

/// Calls the create-staff function (add staff, reset a password).
/// Returns null on success, otherwise a message to show.
Future<String?> _callStaffFunction(Map<String, dynamic> body) async {
  try {
    final res =
        await Supabase.instance.client.functions.invoke('create-staff', body: body);
    final data = res.data;
    if (data is Map && data['error'] != null) return '${data['error']}';
    return null;
  } on FunctionException catch (e) {
    final d = e.details;
    return d is Map && d['error'] != null
        ? '${d['error']}'
        : 'Could not complete this (${e.status}).';
  } catch (_) {
    return 'Cannot reach the server. This needs internet.';
  }
}

/// Admin: add staff, set a new password, change roles, switch accounts off.
class StaffScreen extends StatelessWidget {
  const StaffScreen({super.key});

  Future<void> _add(BuildContext context) async {
    final created = await showDialog<bool>(
        context: context, builder: (_) => const _AddStaffDialog());
    if (created == true) {
      await SyncService.instance.syncNow();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Staff member added')));
      }
    }
  }

  Future<void> _reset(BuildContext context, Map<String, dynamic> s) async {
    final done = await showDialog<bool>(
        context: context, builder: (_) => _ResetPasswordDialog(staff: s));
    if (done == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('New password set for ${s['full_name']}')));
    }
  }

  Future<void> _save(Map<String, dynamic> row) async {
    await LocalStore.upsert('staff_profiles', row);
    SyncService.instance.syncNow();
  }

  @override
  Widget build(BuildContext context) {
    final me = (AuthService.instance.profile?['id'] ?? '') as String;
    return ListenableBuilder(
      listenable: SyncService.instance,
      builder: (context, _) {
        final staff = LocalStore.rows('staff_profiles')
          ..sort((a, b) => '${a['full_name']}'
              .toLowerCase()
              .compareTo('${b['full_name']}'.toLowerCase()));
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('Staff and logins',
                        style: TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w800, color: Brand.navy)),
                  ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
                    onPressed: () => _add(context),
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('Add staff'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                  'Staff sign in with a username and password. If someone forgets their password, set a new one here. Adding staff and resetting passwords need internet.',
                  style: TextStyle(color: Brand.muted)),
              const SizedBox(height: 16),
              Expanded(
                child: Card(
                  clipBehavior: Clip.antiAlias,
                  child: ListView.separated(
                    itemCount: staff.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final s = staff[i];
                      final isMe = s['id'] == me;
                      final active = s['active'] != false;
                      final username = ('${s['username'] ?? ''}').trim();
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('${s['full_name']}${isMe ? ' (you)' : ''}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700, fontSize: 16)),
                                  Text(
                                      username.isEmpty
                                          ? 'Signs in with email'
                                          : 'Username: $username',
                                      style: const TextStyle(
                                          color: Brand.muted, fontSize: 12)),
                                  if (!active)
                                    const Text('Switched off',
                                        style: TextStyle(color: Brand.red, fontSize: 12)),
                                ],
                              ),
                            ),
                            DropdownButton<String>(
                              value: roleLabels.containsKey(s['role'])
                                  ? s['role'] as String
                                  : null,
                              underline: const SizedBox.shrink(),
                              items: [
                                for (final e in roleLabels.entries)
                                  DropdownMenuItem(value: e.key, child: Text(e.value)),
                              ],
                              onChanged: isMe
                                  ? null
                                  : (v) {
                                      if (v != null) _save({...s, 'role': v});
                                    },
                            ),
                            const SizedBox(width: 4),
                            TextButton.icon(
                              onPressed: () => _reset(context, s),
                              icon: const Icon(Icons.lock_reset, size: 20),
                              label: const Text('New password'),
                            ),
                            Tooltip(
                              message: active ? 'Switch account off' : 'Switch account on',
                              child: Switch(
                                value: active,
                                onChanged: isMe ? null : (v) => _save({...s, 'active': v}),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AddStaffDialog extends StatefulWidget {
  const _AddStaffDialog();

  @override
  State<_AddStaffDialog> createState() => _AddStaffDialogState();
}

class _AddStaffDialogState extends State<_AddStaffDialog> {
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  String _role = 'cashier';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final user = _username.text.trim().toLowerCase();
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Enter the staff member\'s name.');
      return;
    }
    if (!RegExp(r'^[a-z0-9._-]{3,30}$').hasMatch(user)) {
      setState(() => _error =
          'Username: 3 to 30 letters, numbers, dots, dashes or underscores (no spaces).');
      return;
    }
    if (_password.text.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await _callStaffFunction({
      'action': 'create',
      'full_name': _name.text.trim(),
      'username': user,
      'password': _password.text,
      'role': _role,
    });
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add staff'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Full name')),
              const SizedBox(height: 12),
              TextField(
                  controller: _username,
                  autocorrect: false,
                  decoration: const InputDecoration(
                      labelText: 'Username', helperText: 'For example: thandi')),
              const SizedBox(height: 12),
              TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'Password (at least 6 characters)')),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _role,
                decoration: const InputDecoration(labelText: 'Role'),
                items: [
                  for (final e in roleLabels.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => _role = v ?? 'cashier'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Brand.red)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy ? null : _create,
          child: Text(_busy ? 'Adding...' : 'Add staff'),
        ),
      ],
    );
  }
}

class _ResetPasswordDialog extends StatefulWidget {
  const _ResetPasswordDialog({required this.staff});
  final Map<String, dynamic> staff;

  @override
  State<_ResetPasswordDialog> createState() => _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends State<_ResetPasswordDialog> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_password.text.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await _callStaffFunction({
      'action': 'reset',
      'user_id': widget.staff['id'],
      'password': _password.text,
    });
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('New password for ${widget.staff['full_name']}'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'Tell them the new password. They can change it themselves after signing in (account icon, top right).',
                style: TextStyle(color: Brand.muted)),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'New password (at least 6 characters)'),
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
          child: Text(_busy ? 'Saving...' : 'Set password'),
        ),
      ],
    );
  }
}
