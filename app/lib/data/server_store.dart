/// Where a paired server lives on the phone.
///
/// Revision 1.1: "The Servers screen is phone-local state (name, URL, pinned
/// fingerprint, device key per server). No endpoint lists 'my servers'."
///
/// The record — id, name, base URL, pinned fingerprint, device id and role —
/// goes into `shared_preferences`. The **device key never does**: it is a
/// bearer credential for the Docker socket, so it lives in
/// `flutter_secure_storage` (Keystore on Android, Keychain on iOS) and is
/// never written to a log or a prefs file.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// The platform keystore refused. On macOS an unsigned local build has no
/// keychain access group, and the keychain answers `-34018`; the device key is
/// never written anywhere else, so pairing stops and says why.
class SecureStorageUnavailable implements Exception {
  const SecureStorageUnavailable(this.code);

  /// The platform error code, for example `-34018`.
  final String code;

  static const String _advice =
      'Sign the app with your Apple Development team and give it the '
      'keychain-access-groups entitlement (macos/Runner/*.entitlements). The '
      'device key is never written to preferences instead.';

  @override
  String toString() =>
      "This build cannot use the device's secure storage ($code), so there is "
      'nowhere safe to keep the device key. $_advice';
}

/// The persistence seam, so tests can run without platform channels.
abstract class ServerStore {
  Future<List<Server>> load();
  Future<void> save(List<Server> servers);

  Future<String?> deviceKey(String serverId);
  Future<void> writeDeviceKey(String serverId, String key);
  Future<void> deleteDeviceKey(String serverId);
}

class PrefsServerStore implements ServerStore {
  PrefsServerStore(this._prefs, {FlutterSecureStorage? secure})
    : _secure =
          secure ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  static const String _key = 'paired_servers';
  static const String _keyPrefix = 'device_key.';

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  @override
  Future<List<Server>> load() async {
    final String? raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const <Server>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return const <Server>[];
      return decoded
          .whereType<Map<String, Object?>>()
          .map(Server.fromJson)
          .where((Server s) => s.id.isNotEmpty && s.baseUrl.isNotEmpty)
          .toList(growable: false);
    } on FormatException {
      return const <Server>[];
    }
  }

  @override
  Future<void> save(List<Server> servers) async {
    await _prefs.setString(
      _key,
      jsonEncode(servers.map((Server s) => s.toJson()).toList(growable: false)),
    );
  }

  @override
  Future<String?> deviceKey(String serverId) =>
      _guard(() => _secure.read(key: '$_keyPrefix$serverId'));

  @override
  Future<void> writeDeviceKey(String serverId, String key) =>
      _guard(() => _secure.write(key: '$_keyPrefix$serverId', value: key));

  @override
  Future<void> deleteDeviceKey(String serverId) =>
      _guard(() => _secure.delete(key: '$_keyPrefix$serverId'));

  /// Turns a refusing keystore into [SecureStorageUnavailable] rather than an
  /// opaque platform error halfway through pairing.
  static Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on PlatformException catch (error) {
      throw SecureStorageUnavailable(error.code);
    } on MissingPluginException {
      throw const SecureStorageUnavailable('no plugin');
    }
  }
}

/// In-memory store for tests and for the integration test.
class MemoryServerStore implements ServerStore {
  final List<Server> _servers = <Server>[];
  final Map<String, String> _keys = <String, String>{};

  @override
  Future<List<Server>> load() async => List<Server>.unmodifiable(_servers);

  @override
  Future<void> save(List<Server> servers) async {
    _servers
      ..clear()
      ..addAll(servers);
  }

  @override
  Future<String?> deviceKey(String serverId) async => _keys[serverId];

  @override
  Future<void> writeDeviceKey(String serverId, String key) async =>
      _keys[serverId] = key;

  @override
  Future<void> deleteDeviceKey(String serverId) async => _keys.remove(serverId);
}
