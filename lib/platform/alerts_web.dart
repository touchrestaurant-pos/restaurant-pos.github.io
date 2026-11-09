import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

web.AudioContext? _ctx;
JSObject? _lock;

/// Two short beeps. Browsers only allow sound after someone has tapped the
/// page once, which the kitchen's "Sound on" button does.
Future<void> playAlert() async {
  try {
    final ctx = _ctx ??= web.AudioContext();
    if (ctx.state == 'suspended') await ctx.resume().toDart;
    for (final start in [0.0, 0.32]) {
      final osc = ctx.createOscillator();
      final gain = ctx.createGain();
      osc.type = 'square';
      osc.frequency.value = 880;
      gain.gain.value = 0.15;
      osc.connect(gain);
      gain.connect(ctx.destination);
      osc.start(ctx.currentTime + start);
      osc.stop(ctx.currentTime + start + 0.22);
    }
  } catch (_) {
    // No sound available: the screen still shows the order.
  }
}

/// Stops the screen from going to sleep while the kitchen screen is open.
/// Browsers drop the lock when the tab is hidden, so this is called again
/// regularly and only asks when there is no active lock.
Future<void> keepScreenOn(bool on) async {
  try {
    if (!on) {
      _lock?.callMethod('release'.toJS);
      _lock = null;
      return;
    }
    final released = _lock?.getProperty<JSBoolean?>('released'.toJS)?.toDart ?? true;
    if (!released) return;
    if (web.document.visibilityState != 'visible') return;
    final nav = web.window.navigator as JSObject;
    final wakeLock = nav.getProperty<JSObject?>('wakeLock'.toJS);
    if (wakeLock == null) return;
    final promise = wakeLock.callMethod<JSPromise<JSObject>>('request'.toJS, 'screen'.toJS);
    _lock = await promise.toDart;
  } catch (_) {
    // Not supported: nothing else to do.
  }
}
