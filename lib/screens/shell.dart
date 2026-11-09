import 'package:flutter/material.dart';

import '../auth/auth_service.dart';
import '../data/repo.dart';
import '../theme.dart';
import '../widgets/brand_mark.dart';
import '../widgets/sync_chip.dart';
import 'cashier_screen.dart';
import 'dashboard_screen.dart';
import 'kitchen_screen.dart';
import 'staff_screen.dart';

class _Tab {
  const _Tab(this.label, this.icon, this.build);
  final String label;
  final IconData icon;
  final Widget Function() build;
}

const _roleNames = {
  'cashier': 'Cashier',
  'kitchen': 'Kitchen',
  'stock': 'Stock',
  'admin': 'Admin',
  'supervisor': 'Supervisor',
};

/// Top bar plus the screens each role may use.
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;

  List<_Tab> _tabsFor(String role) {
    const order = _Tab('Order', Icons.point_of_sale, _cashier);
    const kitchen = _Tab('Kitchen', Icons.soup_kitchen, _kitchen);
    const dash = _Tab('Dashboard', Icons.dashboard_outlined, _dashboard);
    const staff = _Tab('Staff', Icons.badge_outlined, _staff);
    switch (role) {
      case 'cashier':
        return const [order, dash];
      case 'kitchen':
        return const [kitchen];
      case 'stock':
        return const [dash];
      case 'supervisor':
        return const [order, kitchen, dash];
      case 'admin':
        return const [dash, order, kitchen, staff];
      default:
        return const [dash];
    }
  }

  static Widget _cashier() => const CashierScreen();
  static Widget _kitchen() => const KitchenScreen();
  static Widget _dashboard() => const DashboardScreen();
  static Widget _staff() => const StaffScreen();

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;
    final tabs = _tabsFor(auth.role);
    if (_index >= tabs.length) _index = 0;
    final wide = MediaQuery.of(context).size.width >= 760;
    final showNav = tabs.length > 1;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            const BrandMark(size: 34),
            const SizedBox(width: 12),
            Flexible(
              child: Text(companyDisplayName(),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
          ],
        ),
        actions: [
          const SyncChip(),
          if (wide)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Center(
                child: Text('${auth.fullName} · ${_roleNames[auth.role] ?? auth.role}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          IconButton(
            tooltip: 'Log out',
            icon: const Icon(Icons.logout, color: Brand.gold),
            onPressed: auth.signOut,
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(3),
          child: ColoredBox(
              color: Brand.gold, child: SizedBox(height: 3, width: double.infinity)),
        ),
      ),
      body: Row(
        children: [
          if (showNav && wide)
            NavigationRail(
              backgroundColor: Brand.navy,
              indicatorColor: Brand.navyLight,
              selectedIndex: _index,
              labelType: NavigationRailLabelType.all,
              selectedIconTheme: const IconThemeData(color: Brand.gold),
              unselectedIconTheme: const IconThemeData(color: Color(0xFFB8C3DE)),
              selectedLabelTextStyle: const TextStyle(
                  color: Brand.gold, fontWeight: FontWeight.w700, fontSize: 12),
              unselectedLabelTextStyle:
                  const TextStyle(color: Color(0xFFB8C3DE), fontSize: 12),
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: [
                for (final t in tabs)
                  NavigationRailDestination(icon: Icon(t.icon), label: Text(t.label)),
              ],
            ),
          Expanded(child: tabs[_index].build()),
        ],
      ),
      bottomNavigationBar: showNav && !wide
          ? NavigationBarTheme(
              data: const NavigationBarThemeData(
                labelTextStyle: WidgetStatePropertyAll(
                    TextStyle(color: Colors.white, fontSize: 12)),
              ),
              child: NavigationBar(
                backgroundColor: Brand.navy,
                indicatorColor: Brand.navyLight,
                selectedIndex: _index,
                onDestinationSelected: (i) => setState(() => _index = i),
                destinations: [
                  for (final t in tabs)
                    NavigationDestination(
                      icon: Icon(t.icon, color: const Color(0xFFB8C3DE)),
                      selectedIcon: Icon(t.icon, color: Brand.gold),
                      label: t.label,
                    ),
                ],
              ),
            )
          : null,
    );
  }
}
