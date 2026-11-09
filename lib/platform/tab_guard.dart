import 'package:flutter/foundation.dart';

import 'tab_guard_io.dart' if (dart.library.js_interop) 'tab_guard_web.dart' as impl;

/// Only one browser tab may run the till on a device: two tabs would each keep
/// their own copy of the waiting changes and order numbers. The newest tab wins;
/// older tabs show a notice with a button to take over again.
class TabGuard {
  TabGuard._();
  static final instance = TabGuard._();

  final blocked = ValueNotifier<bool>(false);

  void start() => impl.startTabGuard(() => blocked.value = true);

  void takeOver() {
    blocked.value = false;
    impl.claimTab();
  }
}
