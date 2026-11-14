import 'package:flutter/material.dart';

import '../data/local_store.dart';
import '../data/sync_service.dart';
import '../theme.dart';

const _tableNames = {
  'orders': 'Order',
  'order_items': 'Order item',
  'payments': 'Payment',
  'company_settings': 'Company settings',
  'staff_profiles': 'Staff',
  'modifiers': 'Special request',
  'products': 'Menu item',
  'stock_items': 'Stock item',
};

/// Small status pill: online / offline, how many changes are waiting, and a
/// red warning when something could not be saved. Tap it for details.
class SyncChip extends StatelessWidget {
  const SyncChip({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SyncService.instance,
      builder: (context, _) {
        final s = SyncService.instance;
        final waiting = s.pendingCount;
        final failed = s.failedCount;
        final colour = failed > 0 ? Brand.red : (s.online ? Brand.green : Brand.amber);
        final label = failed > 0
            ? '$failed not saved'
            : s.online
                ? (s.waitingForOthers > 0 && s.waitingForOthers == waiting
                    ? 'Online · $waiting for another login'
                    : (waiting > 0 ? 'Online · $waiting waiting' : 'Online · synced'))
                : 'Offline · $waiting waiting';
        return InkWell(
          onTap: () => showDialog<void>(context: context, builder: (_) => const _SyncDialog()),
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(failed > 0 ? Icons.error : Icons.circle, size: failed > 0 ? 16 : 10, color: colour),
                const SizedBox(width: 8),
                Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SyncDialog extends StatelessWidget {
  const _SyncDialog();

  String _describe(Map<String, dynamic> item) {
    final name = _tableNames[item['table']] ?? '${item['table']}';
    final data = item['op'] == 'insert' || item['op'] == 'upsert'
        ? Map<String, dynamic>.from(item['row'] as Map)
        : Map<String, dynamic>.from((item['fields'] as Map?) ?? const {});
    final id = item['op'] == 'insert' || item['op'] == 'upsert' ? data['id'] : item['id'];
    String? ref = data['order_ref'] as String?;
    if (ref == null && item['table'] == 'orders') ref = LocalStore.row('orders', id)?['order_ref'] as String?;
    if (ref == null && (item['table'] == 'order_items' || item['table'] == 'payments')) {
      final orderId = data['order_id'] ?? LocalStore.row(item['table'] as String, id)?['order_id'];
      ref = LocalStore.row('orders', orderId)?['order_ref'] as String?;
    }
    final what = switch (item['op']) {
      'insert' || 'upsert' => 'new',
      'delete' => 'delete',
      _ => 'change',
    };
    return '$name ($what)${ref != null ? ' · order #$ref' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SyncService.instance,
      builder: (context, _) {
        final s = SyncService.instance;
        final failed = LocalStore.failed();
        final last = s.lastSync;
        return AlertDialog(
          title: const Text('Saving to the server'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.online ? 'Connected.' : 'No connection. Everything keeps working and is saved when the connection returns.'),
                const SizedBox(height: 4),
                Text('Waiting to send: ${s.pendingCount}'),
                if (last != null)
                  Text('Last synced: ${last.hour.toString().padLeft(2, '0')}:${last.minute.toString().padLeft(2, '0')}:${last.second.toString().padLeft(2, '0')}',
                      style: const TextStyle(color: Brand.muted)),
                if (failed.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('Not saved', style: TextStyle(fontWeight: FontWeight.w800, color: Brand.red)),
                  const Text(
                      'The server refused these changes several times. Retry once the problem is fixed, or discard a change you no longer need.',
                      style: TextStyle(color: Brand.muted, fontSize: 12)),
                  const SizedBox(height: 8),
                  for (final e in failed)
                    Card(
                      color: const Color(0xFFFFF4F5),
                      child: ListTile(
                        dense: true,
                        title: Text(_describe(e.value), style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text('${e.value['error'] ?? ''}'),
                        trailing: TextButton(
                          style: TextButton.styleFrom(foregroundColor: Brand.red),
                          onPressed: () async {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Discard this change?'),
                                content: const Text('It will not be sent to the server. This cannot be undone.'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
                                  FilledButton(
                                      style: FilledButton.styleFrom(backgroundColor: Brand.red, foregroundColor: Colors.white),
                                      onPressed: () => Navigator.pop(ctx, true),
                                      child: const Text('Discard')),
                                ],
                              ),
                            );
                            if (ok == true) await SyncService.instance.discard(e.key);
                          },
                          child: const Text('Discard'),
                        ),
                      ),
                    ),
                ],
              ]),
            ),
          ),
          actions: [
            if (failed.isNotEmpty)
              FilledButton(onPressed: s.retryFailed, child: const Text('Retry all')),
            OutlinedButton(onPressed: s.syncing ? null : s.syncNow, child: Text(s.syncing ? 'Syncing...' : 'Sync now')),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
        );
      },
    );
  }
}
