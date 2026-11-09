import 'package:flutter/material.dart';

import '../auth/auth_service.dart';
import '../data/local_store.dart';
import '../data/sync_service.dart';
import '../theme.dart';
import '../widgets/brand_mark.dart';
import '../widgets/sync_chip.dart';

const _roleNames = {
  'cashier': 'Cashier',
  'kitchen': 'Kitchen',
  'stock': 'Stock',
  'admin': 'Admin',
  'supervisor': 'Supervisor',
};

const _roleScreens = {
  'cashier': ['Take orders', 'Payments: cash and manual credit card', 'Hold orders'],
  'kitchen': ['Order queue', 'Special requests', 'Mark items done and orders ready'],
  'stock': ['Stock master', 'Receive stock (GRV)', 'Adjustments and stock take'],
  'admin': ['Menu and prices', 'Recipes', 'Staff and logins', 'Company settings', 'Reports'],
  'supervisor': ['Cashier screens', 'Voids, refunds and discounts', 'Cash-up', 'Approve stock adjustments'],
};

num _n(dynamic v) => num.tryParse('$v') ?? 0;

/// Home screen after sign-in. For now it shows what this device has saved
/// locally (proving offline storage works) and the screens coming for this role.
class RoleHome extends StatelessWidget {
  const RoleHome({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;
    final roleName = _roleNames[auth.role] ?? auth.role;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            const BrandMark(size: 34),
            const SizedBox(width: 12),
            Text(companyDisplayName(),
                style: const TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
        actions: [
          const SyncChip(),
          const SizedBox(width: 8),
          Center(
            child: Text('${auth.fullName} · $roleName',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: auth.signOut,
            child: const Text('Log out', style: TextStyle(color: Brand.gold)),
          ),
          const SizedBox(width: 8),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(3),
          child: ColoredBox(color: Brand.gold, child: SizedBox(height: 3, width: double.infinity)),
        ),
      ),
      body: ListenableBuilder(
        listenable: SyncService.instance,
        builder: (context, _) {
          final products = LocalStore.rows('products').length;
          final stock = LocalStore.rows('stock_items');
          final low = stock.where((s) => _n(s['qty_on_hand']) < _n(s['min_level'])).length;
          final open = LocalStore.rows('orders')
              .where((o) => const ['new', 'in_progress', 'ready'].contains(o['status']))
              .length;

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
                  _Stat(value: '$products', label: 'MENU ITEMS', colour: Brand.gold),
                  _Stat(value: '${stock.length}', label: 'STOCK ITEMS', colour: Brand.green),
                  _Stat(value: '$low', label: 'LOW STOCK', colour: Brand.amber),
                  _Stat(value: '$open', label: 'OPEN ORDERS', colour: Brand.red),
                ],
              ),
              const SizedBox(height: 28),
              Text('Screens for $roleName (being built)',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700, color: Brand.navy)),
              const SizedBox(height: 10),
              for (final s in _roleScreens[auth.role] ?? const <String>[])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    const Icon(Icons.chevron_right, color: Brand.gold),
                    const SizedBox(width: 6),
                    Text(s, style: const TextStyle(color: Brand.navy)),
                  ]),
                ),
            ],
          );
        },
      ),
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
                          fontSize: 32, fontWeight: FontWeight.w800, color: Brand.navy)),
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
