/// Certificate pinning.
///
/// `docs/agent-api.md`: "The app pins the agent's certificate fingerprint at
/// pairing time and refuses the connection if it changes." API_NOTES §30: the
/// agent generates a self-signed ECDSA P-256 certificate and prints its
/// SHA-256 fingerprint as `AA:BB:...`, which is also what `POST /pair` returns.
///
/// The client is built on a [SecurityContext] with no trusted roots, so *every*
/// certificate fails the normal check and lands in `badCertificateCallback`.
/// That is deliberate: a certificate signed by a real CA must still match the
/// pin, and without this it would be accepted before the callback ever ran.
library;

import 'dart:io';

import 'package:crypto/crypto.dart';

import 'models.dart';

/// `AA:BB:CC:…`, upper case, colon separated.
String formatFingerprint(List<int> der) {
  final Digest digest = sha256.convert(der);
  return digest.bytes
      .map((int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');
}

/// Compares two fingerprints ignoring case, separators and whitespace.
bool fingerprintsMatch(String a, String b) => _normalise(a) == _normalise(b);

String _normalise(String value) =>
    value.replaceAll(RegExp('[^0-9a-fA-F]'), '').toLowerCase();

/// True when the string looks like a full SHA-256 fingerprint.
bool isCompleteFingerprint(String value) => _normalise(value).length == 64;

/// An [HttpClient] that accepts exactly one certificate.
HttpClient pinnedHttpClient(String fingerprint) {
  final HttpClient client = HttpClient(
    context: SecurityContext(withTrustedRoots: false),
  );
  client.connectionTimeout = const Duration(seconds: 10);
  client.idleTimeout = const Duration(seconds: 30);
  client.badCertificateCallback =
      (X509Certificate cert, String host, int port) {
        return fingerprintsMatch(formatFingerprint(cert.der), fingerprint);
      };
  client.userAgent = 'Doomsaday';
  return client;
}

/// Trust on first use, for the single `POST /pair` call.
///
/// Accepts whatever the agent presents and records its fingerprint, which the
/// caller then checks against `cert_fingerprint` in the pairing response and
/// shows to the person before it is pinned.
class TofuHttpClient {
  TofuHttpClient() {
    client = HttpClient(context: SecurityContext(withTrustedRoots: false));
    client.connectionTimeout = const Duration(seconds: 10);
    client.userAgent = 'Doomsaday';
    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) {
          _seen = formatFingerprint(cert.der);
          return true;
        };
  }

  late final HttpClient client;
  String? _seen;

  /// The fingerprint of the certificate the agent presented, if it used TLS.
  String? get presentedFingerprint => _seen;

  void close() => client.close(force: true);
}

/// Refuses a plain-HTTP base URL outside a debug build.
///
/// The agent's `--insecure-http` mode exists for local development only
/// (API_NOTES §30): device keys travel in clear text.
void assertTransportIsAllowed(Uri base) {
  if (base.scheme == 'https') return;
  bool debug = false;
  assert(() {
    debug = true;
    return true;
  }());
  if (base.scheme == 'http' && debug) return;
  throw AgentException(
    'insecure_transport',
    'The agent URL must use HTTPS. Plain HTTP is only allowed in a debug '
        'build, against the agent\'s --insecure-http development mode.',
    status: 400,
  );
}

/// The `Authorization` value, kept in one place so it is never logged.
String bearer(String deviceKey) => 'Bearer $deviceKey';
