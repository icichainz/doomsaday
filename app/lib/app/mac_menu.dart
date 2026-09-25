/// The macOS app menu talking to Flutter.
///
/// "Settings…" with **Cmd+,** is a standard Mac menu item, and a Flutter
/// window cannot own it: it lives in `MainMenu.xib`. The item is wired there to
/// `showSettings:` on the app delegate, which sends `openPreferences` down this
/// channel — so the menu item is enabled, and it opens exactly what the cog in
/// the sidebar footer opens.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Named on both sides; `AppDelegate.swift` builds the same channel.
const MethodChannel macMenuChannel = MethodChannel('doomsaday/menu');

/// Listens for the app menu while [onOpenPreferences] is the thing to do.
///
/// Off macOS there is no such menu, and the channel is simply never set up.
class MacMenu {
  MacMenu._();

  static bool get isMac =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static void listen(VoidCallback onOpenPreferences) {
    if (!isMac) return;
    macMenuChannel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'openPreferences') onOpenPreferences();
      return null;
    });
  }

  static void stop() {
    if (!isMac) return;
    macMenuChannel.setMethodCallHandler(null);
  }
}
