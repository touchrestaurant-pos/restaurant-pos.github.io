import 'package:flutter/material.dart';

import '../auth/auth_service.dart';
import '../theme.dart';
import '../widgets/brand_mark.dart';
import '../widgets/change_password_dialog.dart';
import '../widgets/approval_pin.dart';
import '../auth/permissions.dart';
import '../widgets/sync_chip.dart';
import 'accounts_screen.dart';
import 'till_screen.dart';
import 'cashier_screen.dart';
import 'dashboard_screen.dart';
import 'finance_screen.dart';
import 'kitchen_screen.dart';
import '../data/local_store.dart';
import '../data/sync_service.dart';
import 'reports_screen.dart';
import 'cashup_screen.dart';
import 'menu_screen.dart';
import 'orders_screen.dart';
import 'settings_screen.dart';
import 'special_requests_screen.dart';
import 'staff_screen.dart';
import 'stock_screen.dart';

class _Tab {
  const _Tab(this.label, this.icon, this.build, [this.group = '']);
  final String label;
  final IconData icon;
  final Widget Function() build;

  /// Heading the tab sits under in the side menu.
  final String group;
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
    const order = _Tab('Order', Icons.point_of_sale, _cashier, 'Till');
    const kitchen = _Tab('Kitchen', Icons.soup_kitchen, _kitchen, 'Till');
    const dash = _Tab('Dashboard', Icons.dashboard_outlined, _dashboard, 'Money');
    const staff = _Tab('Staff', Icons.badge_outlined, _staff, 'Admin');
    const requests = _Tab('Requests', Icons.edit_note, _requests, 'Stock & menu');
    const orders = _Tab('Orders', Icons.receipt_long, _orders, 'Till');
    const cashup = _Tab('Cash-up', Icons.account_balance_wallet_outlined, _cashup, 'Money');
    const menu = _Tab('Menu', Icons.restaurant_menu, _menu, 'Stock & menu');
    const stock = _Tab('Stock', Icons.inventory_2_outlined, _stock, 'Stock & menu');
    const reports = _Tab('Reports', Icons.bar_chart, _reports, 'Money');
    const finance = _Tab('Finance', Icons.account_balance_outlined, _finance, 'Money');
    const till = _Tab('Till money', Icons.payments_outlined, _till, 'Till');
    const accounts = _Tab('Accounts', Icons.account_balance_wallet, _accounts, 'Money');
    const settings = _Tab('Settings', Icons.settings_outlined, _settings, 'Admin');
    switch (role) {
      case 'cashier':
        return [order, orders, if (Perms.canPayout) till];
      case 'kitchen':
        return const [kitchen];
      case 'stock':
        return const [stock, dash];
      case 'supervisor':
        return const [order, kitchen, orders, till, cashup, accounts, dash];
      case 'admin':
        return const [order, orders, till, kitchen, dash, reports, cashup, accounts, finance, stock, menu, requests, staff, settings];
      default:
        return const [dash];
    }
  }

  static Widget _cashier() => const CashierScreen();
  static Widget _kitchen() => const KitchenScreen();
  static Widget _dashboard() => const DashboardScreen();
  static Widget _staff() => const StaffScreen();
  static Widget _requests() => const SpecialRequestsScreen();
  static Widget _orders() => const OrdersScreen();
  static Widget _cashup() => const CashUpScreen();
  static Widget _menu() => const MenuScreen();
  static Widget _stock() => const StockScreen();
  static Widget _reports() => const ReportsScreen();
  static Widget _finance() => const FinanceScreen();
  static Widget _till() => const TillScreen();
  static Widget _accounts() => const AccountsScreen();
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
              if (v == 'pin') showSetApprovalPinDialog(context);
              if (v == 'logout') auth.signOut();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                enabled: false,
                child: Text('${auth.fullName} · ${_roleNames[auth.role] ?? auth.role}'),
              ),
              const PopupMenuItem(value: 'password', child: Text('Change my password')),
              if (const ['admin', 'supervisor'].contains(auth.role))
                const PopupMenuItem(value: 'pin', child: Text('Set my approval PIN')),
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
            _SideMenu(tabs: tabs, index: _index, onTap: (i) => setState(() => _index = i)),
          Expanded(
            child: Column(children: [
              // Sales that have waited long are at risk if this device is lost or its browser data is cleared.
              if ((LocalStore.oldestPendingAge ?? Duration.zero) > const Duration(minutes: 10))
                Container(
                  width: double.infinity,
                  color: const Color(0xFFFDE7EA),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Text(
                      '${LocalStore.pendingCount} changes on this device have not reached the server for '
                      '${LocalStore.oldestPendingAge!.inMinutes} minutes. Check the internet. Do not clear the browser data or sign out until this is gone.',
                      style: const TextStyle(color: Brand.red, fontWeight: FontWeight.w700)),
                ),
              Expanded(child: tabs[_index].build()),
            ]),
          ),
        ],
      ),
      drawer: showNav && !wide && tabs.length > 5
          ? Drawer(
              backgroundColor: Brand.navy,
              child: SafeArea(
                child: ListView(children: [
                  for (var i = 0; i < tabs.length; i++) ...[
                    if (i == 0 || tabs[i].group != tabs[i - 1].group)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                        child: Text(tabs[i].group.toUpperCase(),
                            style: const TextStyle(color: Color(0xFF7F8DB5), fontSize: 11, fontWeight: FontWeight.w800)),
                      ),
                    ListTile(
                      leading: Icon(tabs[i].icon,
                          color: i == _index ? Brand.gold : const Color(0xFFB8C3DE)),
                      title: Text(tabs[i].label,
                          style: TextStyle(
                              color: i == _index ? Brand.gold : Colors.white,
                              fontWeight: i == _index ? FontWeight.w700 : FontWeight.w400)),
                      selected: i == _index,
                      onTap: () {
                        setState(() => _index = i);
                        Navigator.pop(context);
                      },
                    ),
                  ],
                ]),
              ),
            )
          : null,
      bottomNavigationBar: showNav && !wide && tabs.length <= 5
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

/// Side menu for wide screens: icons with labels, grouped under small headings,
/// scrolls when the window is short.
class _SideMenu extends StatelessWidget {
  const _SideMenu({required this.tabs, required this.index, required this.onTap});
  final List<_Tab> tabs;
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    const soft = Color(0xFFB8C3DE);
    final grouped = tabs.map((t) => t.group).toSet().length > 1;
    final children = <Widget>[];
    String? lastGroup;
    for (var i = 0; i < tabs.length; i++) {
      final t = tabs[i];
      if (grouped && t.group != lastGroup) {
        lastGroup = t.group;
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(6, 14, 6, 4),
          child: Text(t.group.toUpperCase(),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF7F8DB5), fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
        ));
      }
      final selected = i == index;
      children.add(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Material(
          color: selected ? Brand.navyLight : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => onTap(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(children: [
                Icon(t.icon, color: selected ? Brand.gold : soft),
                const SizedBox(height: 3),
                Text(t.label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: selected ? Brand.gold : soft,
                        fontSize: 12,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w400)),
              ]),
            ),
          ),
        ),
      ));
    }
    return Container(
      width: 92,
      color: Brand.navy,
      child: ListView(padding: const EdgeInsets.only(bottom: 12), children: children),
    );
  }
}
