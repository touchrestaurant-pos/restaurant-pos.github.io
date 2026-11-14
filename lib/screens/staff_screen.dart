import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_service.dart';
import '../data/app_db.dart';
import '../data/db_profiles.dart';
import '../data/local_store.dart';
import '../data/sync_service.dart';
import '../auth/permissions.dart';
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
  if (DbProfiles.isPostgres) return _callStaffFunctionLocal(body);
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

/// The local-database equivalent of the create-staff edge function — the
/// same checks, done with plain SQL over the local connection instead of
/// a call to Supabase's servers.
Future<String?> _callStaffFunctionLocal(Map<String, dynamic> body) async {
  final pg = AuthService.instance.pgClient;
  if (pg == null) return 'Database not connected.';
  final password = '${body['password'] ?? ''}';
  if (password.length < 6) return 'Password must be at least 6 characters';
  final action = '${body['action'] ?? 'create'}';
  try {
    if (action == 'reset') {
      final userId = '${body['user_id'] ?? ''}';
      final target = await pg.query(
        'SELECT id FROM public.staff_profiles WHERE id = @id', {'id': userId});
      if (target.isEmpty) return 'Staff member not found';
      await pg.execute(
        "UPDATE auth.users SET encrypted_password = crypt(@pw, gen_salt('bf')) WHERE id = @id",
        {'pw': password, 'id': userId},
      );
      return null;
    }
    if (action != 'create') return 'Unknown action';
    final fullName = '${body['full_name'] ?? ''}'.trim();
    final username = '${body['username'] ?? ''}'.trim().toLowerCase();
    final role = '${body['role'] ?? 'cashier'}';
    if (fullName.isEmpty) return "Enter the staff member's name";
    if (!RegExp(r'^[a-z0-9._-]{3,30}$').hasMatch(username)) {
      return 'Username must be 3 to 30 letters, numbers, dots, dashes or underscores';
    }
    if (!roleLabels.containsKey(role)) return 'Unknown role';
    final taken = await pg.query(
      'SELECT id FROM public.staff_profiles WHERE username ILIKE @u', {'u': username});
    if (taken.isNotEmpty) return 'That username is already taken';
    final email = '$username@store.local';
    final inserted = await pg.query(
      "INSERT INTO auth.users (email, encrypted_password, raw_user_meta_data) "
      "VALUES (@email, crypt(@pw, gen_salt('bf')), jsonb_build_object('full_name', @name::text, 'username', @user::text)) "
      "RETURNING id",
      {'email': email, 'pw': password, 'name': fullName, 'user': username},
    );
    final newId = '${inserted.first['id']}';
    // The handle_new_user trigger just created the profile as "cashier";
    // set the chosen role and the details actually typed in.
    await pg.execute(
      'UPDATE public.staff_profiles SET role = @role::public.app_role, full_name = @name, username = @user WHERE id = @id',
      {'role': role, 'name': fullName, 'user': username, 'id': newId},
    );
    return null;
  } catch (e) {
    return '$e';
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

  Future<void> _permissions(BuildContext context, Map<String, dynamic> s) async {
    final result = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => _PermissionsDialog(staff: s));
    if (result != null) {
      await _save({...s, 'perms': result});
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Permissions saved for ${s['full_name']}. They apply the next time that person signs in or the app syncs.')));
      }
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
                            if (s['role'] == 'cashier')
                              TextButton.icon(
                                onPressed: () => _permissions(context, s),
                                icon: const Icon(Icons.shield_outlined, size: 20),
                                label: const Text('Permissions'),
                              ),
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
                value: _role,
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


/// What one cashier may do. A blank number means "use the default".
class _PermissionsDialog extends StatefulWidget {
  const _PermissionsDialog({required this.staff});
  final Map<String, dynamic> staff;

  @override
  State<_PermissionsDialog> createState() => _PermissionsDialogState();
}

class _PermissionsDialogState extends State<_PermissionsDialog> {
  late final Map<String, dynamic> _p;
  final _nums = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    final cur = widget.staff['perms'];
    _p = cur is Map ? Map<String, dynamic>.from(cur) : {};
    for (final d in permDefs.where((d) => d.number)) {
      final v = _p[d.key];
      _nums[d.key] = TextEditingController(text: v is num ? (v % 1 == 0 ? '${v.toInt()}' : '$v') : '');
    }
  }

  @override
  void dispose() {
    for (final c in _nums.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Permissions for ${widget.staff['full_name']}'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('These limits apply to this cashier only. Supervisors and admins are not limited by them.',
                style: TextStyle(color: Brand.muted)),
            const SizedBox(height: 8),
            for (final d in permDefs)
              if (d.number)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: TextField(
                    controller: _nums[d.key],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: d.title,
                      helperText: '${d.help}${d.serverChecked ? ' Checked by the server too.' : ''}',
                      helperMaxLines: 3,
                      hintText: d.defaultValue == null ? 'blank = company limit' : 'blank = ${d.defaultValue}${d.unit}',
                      suffixText: d.unit == '%' ? '%' : null,
                      prefixText: d.unit == 'R' ? 'R ' : null,
                    ),
                  ),
                )
              else
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(d.title),
                  subtitle: Text('${d.help}${d.serverChecked ? ' Checked by the server too.' : ''}'),
                  value: (_p[d.key] is bool ? _p[d.key] : d.defaultValue) == true,
                  onChanged: (v) => setState(() => _p[d.key] = v),
                ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, <String, dynamic>{}), child: const Text('Reset to defaults')),
        FilledButton(
          onPressed: () {
            final out = <String, dynamic>{};
            for (final d in permDefs) {
              if (d.number) {
                final t = _nums[d.key]!.text.trim().replaceAll(',', '.');
                final v = double.tryParse(t);
                if (v != null && v >= 0) out[d.key] = v;
              } else if (_p[d.key] is bool) {
                out[d.key] = _p[d.key];
              }
            }
            Navigator.pop(context, out);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
