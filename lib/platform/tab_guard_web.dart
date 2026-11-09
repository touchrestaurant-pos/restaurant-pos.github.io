import 'dart:js_interop';
import 'dart:math';

import 'package:web/web.dart' as web;

final String _me = '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 30)}';
web.BroadcastChannel? _channel;

void startTabGuard(void Function() onOtherTab) {
  try {
    final ch = web.BroadcastChannel('restopos-tab');
    ch.onmessage = ((web.MessageEvent e) {
      final data = e.data.dartify();
      if (data is String && data.startsWith('claim:') && data != 'claim:$_me') {
        onOtherTab();
      }
    }).toJS;
    _channel = ch;
    claimTab();
  } catch (_) {
    // Very old browsers have no BroadcastChannel: run without the guard.
  }
}

void claimTab() {
  try {
    _channel?.postMessage('claim:$_me'.toJS);
  } catch (_) {}
}
