/// What the app calls the device it is running on.
///
/// The agent stores whatever name a device was paired under, but the phrases
/// the design writes about *this* device — the sidebar footer, the activity
/// sentences, the typed-confirmation hint — name the hardware in front of the
/// person. A Mac says "This Mac", a phone says "This phone".
library;

import 'package:flutter/foundation.dart';

/// True where Touch ID, the command key and Apple's own wording apply.
bool get isApplePlatform =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// `This Mac`, `This phone`, `This PC` — or the lower-case form for the middle
/// of a sentence ("restarted from this Mac").
String thisDeviceLabel({bool capitalized = true}) {
  final String label = switch (defaultTargetPlatform) {
    TargetPlatform.macOS => 'Mac',
    TargetPlatform.iOS || TargetPlatform.android => 'phone',
    TargetPlatform.windows => 'PC',
    _ => 'device',
  };
  return '${capitalized ? 'This' : 'this'} $label';
}

/// D3's hint line, which names the biometric this device does not have.
String noBiometricLine() => defaultTargetPlatform == TargetPlatform.macOS
    ? 'This Mac has no Touch ID.'
    : '${thisDeviceLabel()} has no biometric unlock.';
