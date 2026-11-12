import '../data/local_store.dart';
import 'auth_service.dart';

/// One setting an admin can change per cashier. [key] is stored in staff_profiles.perms.
class PermDef {
  const PermDef(this.key, this.title, this.help, {this.number = false, this.unit = '', this.defaultValue, this.serverChecked = false});
  final String key;
  final String title;
  final String help;
  final bool number;
  final String unit;
  final Object? defaultValue;

  /// True when the database enforces it too; false means the till screen enforces it.
  final bool serverChecked;
}

const permDefs = <PermDef>[
  PermDef('max_discount_pct', 'Biggest discount without a manager PIN',
      'Above this a supervisor or admin must type their PIN. 0 means every discount needs a PIN. 100 means no limit.',
      number: true, unit: '%', defaultValue: 10),
  PermDef('can_cancel_unpaid', 'Can cancel an order that is not paid yet', 'Switch off to make cancelling a job for a supervisor.',
      defaultValue: true),
  PermDef('can_remove_sent', 'Can remove items the kitchen has already made',
      'Off: a supervisor must remove them.',
      defaultValue: false),
  PermDef('can_reprint_kitchen', 'Can reprint the kitchen slip', 'Every reprint is recorded in the Change history.', defaultValue: true),
  PermDef('can_account_sale', 'Can sell on account', 'Switch off to stop this person putting sales on a customer account.',
      defaultValue: true, serverChecked: true),
  PermDef('can_payout', 'Can take money out of the till', 'Petty cash, supplier payments and so on (the Till money tab).',
      defaultValue: true, serverChecked: true),
  PermDef('payout_limit', 'Most they can take out in one go',
      'Leave blank to use the company limit. 0 means no limit.',
      number: true, unit: 'R', defaultValue: null, serverChecked: true),
];

/// What the signed-in person may do. Admins and supervisors are never limited by these.
class Perms {
  static bool get isManager => const ['admin', 'supervisor'].contains(AuthService.instance.role);

  static Object? _v(String key) {
    final uid = AuthService.instance.profile?['id'];
    // The copy synced to this device is the freshest; the one saved at sign-in is the fallback.
    final row = (uid == null ? null : LocalStore.row('staff_profiles', uid)) ?? AuthService.instance.profile;
    final p = row?['perms'];
    return p is Map && p.containsKey(key) ? p[key] : null;
  }

  static bool _bool(String key, bool def) {
    if (isManager) return true;
    final v = _v(key);
    return v is bool ? v : def;
  }

  static double get maxDiscountPct {
    if (isManager) return 100;
    final v = _v('max_discount_pct');
    return v is num ? v.toDouble() : 10;
  }

  static bool get canCancelUnpaid => _bool('can_cancel_unpaid', true);
  static bool get canRemoveSent => _bool('can_remove_sent', false);
  static bool get canReprintKitchen => _bool('can_reprint_kitchen', true);
  static bool get canAccountSale => _bool('can_account_sale', true);
  static bool get canPayout => _bool('can_payout', true);
}
