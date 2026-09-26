/// What the app calls the device it is running on.
///
/// The agent stores whatever name a device was paired under, but the phrases
/// the design writes about *this* device — the sidebar footer, the activity
/// sentences, the Devices list, Server settings, the typed-confirmation hint,
/// and the demo seed's own device — name the hardware in front of the person:
/// "This Mac", "This iPad", "This phone". [thisDeviceLabel] is the one place
/// that decides, so no two of them can disagree.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// True where Touch ID, the command key and Apple's own wording apply.
bool get isApplePlatform =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// An iOS screen whose short side is at least this many points is an iPad.
const double kTabletShortestSide = 600;

/// The hardware word: `Mac`, `iPad`, `phone`, `PC` or `device`.
///
/// [platform] and [screen] (the screen's logical size) default to the running
/// app's; tests pass them to pin one answer.
String thisDeviceNoun({TargetPlatform? platform, ui.Size? screen}) =>
    switch (platform ?? defaultTargetPlatform) {
      TargetPlatform.macOS => 'Mac',
      TargetPlatform.iOS =>
        (screen ?? _screenSize()).shortestSide >= kTabletShortestSide
            ? 'iPad'
            : 'phone',
      TargetPlatform.android => 'phone',
      TargetPlatform.windows => 'PC',
      _ => 'device',
    };

/// `This Mac`, `This iPad`, `This phone` — or the lower-case form for the
/// middle of a sentence ("restarted from this Mac").
String thisDeviceLabel({
  bool capitalized = true,
  TargetPlatform? platform,
  ui.Size? screen,
}) =>
    '${capitalized ? 'This' : 'this'} '
    '${thisDeviceNoun(platform: platform, screen: screen)}';

/// D3's hint line, which names the biometric this device does not have.
String noBiometricLine() => defaultTargetPlatform == TargetPlatform.macOS
    ? 'This Mac has no Touch ID.'
    : '${thisDeviceLabel()} has no biometric unlock.';

/// The whole screen in logical points — the display, not the window, so an
/// iPad in Split View is still an iPad. Before a view exists (or where the
/// embedder reports no display) this falls back to the window, then to zero.
ui.Size _screenSize() {
  final ui.FlutterView? view =
      ui.PlatformDispatcher.instance.implicitView ??
      (ui.PlatformDispatcher.instance.views.isEmpty
          ? null
          : ui.PlatformDispatcher.instance.views.first);
  if (view == null) return ui.Size.zero;
  try {
    final ui.Display display = view.display;
    if (!display.size.isEmpty && display.devicePixelRatio > 0) {
      return display.size / display.devicePixelRatio;
    }
  } catch (_) {
    // No display on this embedder: use the window below.
  }
  return view.physicalSize / view.devicePixelRatio;
}
