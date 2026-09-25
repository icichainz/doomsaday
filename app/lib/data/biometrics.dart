/// The biometric prompt behind `X-Confirmed: biometric`.
///
/// `docs/agent-api.md`: risky actions accept the header, and with the agent
/// setting on they are refused with `428` without it. The header is only sent
/// after the person actually passed the prompt on this device.
///
/// A device with no biometrics at all — most Macs, a phone with nothing
/// enrolled — falls back to typing the target's name, which is sent as
/// `X-Confirmed: typed` instead.
library;

import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// What the confirm dialog asks before a risky call.
abstract class Authenticator {
  /// Whether this device can run a biometric or device-credential prompt at
  /// all. `false` sends the confirm dialog down the typed path.
  Future<bool> isAvailable();

  /// Returns true only when the person authenticated. A cancel is `false`,
  /// and then nothing is sent to the agent.
  Future<bool> confirm(String reason);
}

/// The real prompt. Falls back to the device passcode when the device has no
/// enrolled biometrics, which is what `local_auth` calls a device credential.
class LocalAuthAuthenticator implements Authenticator {
  LocalAuthAuthenticator([LocalAuthentication? auth])
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  bool? _available;

  @override
  Future<bool> isAvailable() async {
    if (_available != null) return _available!;
    try {
      _available = await _auth.isDeviceSupported();
    } on PlatformException {
      _available = false;
    } on MissingPluginException {
      _available = false;
    }
    return _available!;
  }

  @override
  Future<bool> confirm(String reason) async {
    try {
      if (!await isAvailable()) return false;
      final bool hasBiometrics = await _auth.canCheckBiometrics;
      return await _auth.authenticate(
        localizedReason: reason,
        options: AuthenticationOptions(
          biometricOnly: hasBiometrics && await _hasEnrolled(),
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
    } on PlatformException {
      // No hardware, nothing enrolled, or the platform refused: treat it the
      // same as a cancel so the app never claims a confirmation it lacks.
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> _hasEnrolled() async {
    final List<BiometricType> available = await _auth.getAvailableBiometrics();
    return available.isNotEmpty;
  }
}

/// Used by tests and by demo mode, where there is nothing to protect.
class AlwaysConfirms implements Authenticator {
  const AlwaysConfirms();

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> confirm(String reason) async => true;
}

/// A device with no Touch ID, Face ID or passcode prompt: the confirm dialog
/// asks the person to type the target's name instead.
class NoBiometrics implements Authenticator {
  const NoBiometrics();

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<bool> confirm(String reason) async => false;
}
