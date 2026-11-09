import 'package:flutter/material.dart';

import '../auth/auth_service.dart';
import '../theme.dart';
import '../widgets/brand_mark.dart';
import '../widgets/change_password_dialog.dart';
import '../widgets/sync_chip.dart';
import 'cashier_screen.dart';
import 'dashboard_screen.dart';
import 'kitchen_screen.dart';
import '../data/sync_service.dart';
import 'reports_screen.dart';
import 'menu_screen.dart';
import 'settings_screen.dart';
import 'special_requests_screen.dart';
import 'staff_screen.dart';
import 'stock_screen.dart';

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
    const requests = _Tab('Requests', Icons.edit_note, _requests);
    const menu = _Tab('Menu', Icons.restaurant_menu, _menu);
    const stock = _Tab('Stock', Icons.inventory_2_outlined, _stock);
    const reports = _Tab('Reports', Icons.bar_chart, _reports);
    const settings = _Tab('Settings', Icons.settings_outlined, _settings);
    switch (role) {
      case 'cashier':
        return const [order, dash];
      case 'kitchen':
        return const [kitchen];
      case 'stock':
        return const [stock, dash];
      case 'supervisor':
        return const [order, kitchen, dash];
      case 'admin':
        return const [dash, order, kitchen, menu, stock, reports, requests, staff, settings];
      default:
        return const [dash];
    }
  }

  static Widget _cashier() => const CashierScreen();
  static Widget _kitchen() => const KitchenScreen();
  static Widget _dashboard() => const DashboardScreen();
  static Widget _staff() => const StaffScreen();
  static Widget _requests() => const SpecialRequestsScreen();
  static Widget _menu() => const MenuScreen();
  static Widget _stock() => const StockScreen();
  static Widget _reports() => const ReportsScreen();
  static Widget _settings() => const SettingsScreen();

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;
    final tabs = _tabsFor(auth.role);
    if (_index >= tabs.length) _index = 0;
    final wide = MediaQuery.of(context).size.width >= 760;
    final showNav = tabs.length > 1;

    // Rebuild when synced data changes, so a new company name or logo shows at once.
    return ListenableBuilder(
      listenable: SyncService.instance,
      builder: (context, _) => Scaffold(
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
              padding: const EdgeInsets.only(left: 8),
              child: Center(
                child: Text('${auth.fullName} · ${_roleNames[auth.role] ?? auth.role}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          PopupMenuButton<String>(
            tooltip: 'Account',
            icon: const Icon(Icons.account_circle, color: Brand.gold),
            onSelected: (v) {
              if (v == 'password') showChangePasswordDialog(context);
              if (v == 'logout') auth.signOut();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                enabled: false,
                child: Text('${auth.fullName} · ${_roleNames[auth.role] ?? auth.role}'),
              ),
              const PopupMenuItem(value: 'password', child: Text('Change my password')),
              const PopupMenuItem(value: 'logout', child: Text('Log out')),
            ],
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
    ));
  }
}
