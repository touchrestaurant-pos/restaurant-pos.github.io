import 'package:flutter/material.dart';

import '../auth/auth_service.dart';
import '../data/local_store.dart';
import '../data/repo.dart';
import '../data/sync_service.dart';
import '../theme.dart';

/// Quick numbers from the data saved on this device.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;
    return ListenableBuilder(
      listenable: SyncService.instance,
      builder: (context, _) {
        final products = LocalStore.rows('products').length;
        final stock = LocalStore.rows('stock_items');
        final low =
            stock.where((s) => n(s['qty_on_hand']) < n(s['min_level'])).length;
        final orders = LocalStore.rows('orders');
        final open = orders
            .where((o) => const ['new', 'in_progress', 'ready'].contains(o['status']))
            .length;
        final today = DateTime.now();
        final todaySales = orders.where((o) {
          final t = parseTime(o['created_at']);
          return o['status'] != 'void' &&
              o['paid'] == true &&
              t != null &&
              t.year == today.year &&
              t.month == today.month &&
              t.day == today.day;
        }).fold<num>(0, (s, o) => s + n(o['total']));

        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('Good day, ${auth.fullName}',
                style: const TextStyle(
                    fontSize: 26, fontWeight: FontWeight.w800, color: Brand.navy)),
            const SizedBox(height: 4),
            const Text('Saved on this device, so it still works without internet.',
                style: TextStyle(color: Brand.muted)),
            const SizedBox(height: 20),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                _Stat(value: money(todaySales), label: 'SALES TODAY', colour: Brand.gold),
                _Stat(value: '$open', label: 'OPEN ORDERS', colour: Brand.red),
                _Stat(value: '$low', label: 'LOW STOCK', colour: Brand.amber),
                _Stat(value: '$products', label: 'MENU ITEMS', colour: Brand.green),
                _Stat(value: '${stock.length}', label: 'STOCK ITEMS', colour: Brand.navyLight),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, required this.colour});
  final String value;
  final String label;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 200,
        color: Colors.white,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(height: 4, color: colour),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value,
                      style: const TextStyle(
                          fontSize: 30, fontWeight: FontWeight.w800, color: Brand.navy)),
                  const SizedBox(height: 2),
                  Text(label,
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: Brand.muted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
