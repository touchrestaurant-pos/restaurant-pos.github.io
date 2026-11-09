import 'package:flutter/services.dart';

/// Phones and computers: the system alert sound.
Future<void> playAlert() => SystemSound.play(SystemSoundType.alert);

/// Keeping the screen awake needs a browser here; on the apps set the device's
/// screen timeout to "never" for the kitchen screen.
Future<void> keepScreenOn(bool on) async {}
