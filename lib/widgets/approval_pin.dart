import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/app_db.dart';

import '../theme.dart';

/// A manager or supervisor sets the PIN they use to approve things at the till.
Future<void> showSetApprovalPinDialog(BuildContext context) async {
  final one = TextEditingController();
  final two = TextEditingController();
  String? error;
  bool busy = false;
  bool has = false;
  try {
    has = (await AppDb.rpc('has_approval_pin')) == true;
  } catch (_) {}
  if (!context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: Text(has ? 'Change my approval PIN' : 'Set my approval PIN'),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('A cashier who needs your approval (for example a discount over 10%) types this PIN. '
                'Keep it private and different from your password.',
                style: TextStyle(color: Brand.muted)),
            const SizedBox(height: 10),
            TextField(
                controller: one,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(labelText: 'New PIN (4 to 6 digits)', counterText: '')),
            TextField(
                controller: two,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(labelText: 'Type it again', counterText: '')),
            if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: const TextStyle(color: Brand.red))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    if (!RegExp(r'^[0-9]{4,6}$').hasMatch(one.text)) {
                      set(() => error = 'Use 4 to 6 digits only.');
                      return;
                    }
                    if (one.text != two.text) {
                      set(() => error = 'The two PINs do not match.');
                      return;
                    }
                    set(() {
                      busy = true;
                      error = null;
                    });
                    try {
                      await AppDb.rpc('set_approval_pin', params: {'p_pin': one.text});
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    } on PostgrestException catch (e) {
                      set(() {
                        busy = false;
                        error = e.message;
                      });
                    } catch (_) {
                      set(() {
                        busy = false;
                        error = 'This needs an internet connection.';
                      });
                    }
                  },
            child: const Text('Save PIN'),
          ),
        ],
      ),
    ),
  );
  if (ok == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Approval PIN saved')));
  }
}
