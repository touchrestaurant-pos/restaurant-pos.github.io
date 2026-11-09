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

/// Admin: add staff, change roles, switch accounts off.
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
          ..sort((a, b) => '${a['full_name']}'.toLowerCase().compareTo('${b['full_name']}'.toLowerCase()));
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
              const Text('Staff sign in with their email and password. Adding needs internet.',
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
                                  if (!active)
                                    const Text('Switched off',
                                        style: TextStyle(color: Brand.red, fontSize: 12)),
                                ],
                              ),
                            ),
                            DropdownButton<String>(
                              value: roleLabels.containsKey(s['role']) ? s['role'] as String : null,
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
                            const SizedBox(width: 12),
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
  final _email = TextEditingController();
  final _password = TextEditingController();
  String _role = 'cashier';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_name.text.trim().isEmpty || !_email.text.contains('@') || _password.text.length < 6) {
      setState(() => _error = 'Enter a name, a valid email and a password of 6 or more characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client.functions.invoke('create-staff', body: {
        'full_name': _name.text.trim(),
        'email': _email.text.trim(),
        'password': _password.text,
        'role': _role,
      });
      final data = res.data;
      if (data is Map && data['error'] != null) {
        setState(() => _error = '${data['error']}');
      } else if (mounted) {
        Navigator.pop(context, true);
        return;
      }
    } on FunctionException catch (e) {
      final d = e.details;
      setState(() => _error = d is Map && d['error'] != null ? '${d['error']}' : 'Could not add staff (${e.status}).');
    } catch (_) {
      setState(() => _error = 'Cannot reach the server. Adding staff needs internet.');
    }
    if (mounted) setState(() => _busy = false);
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
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email (their login)')),
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
