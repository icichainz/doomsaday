/// The phone's own list of paired agents, plus one [AgentApi] per server.
///
/// Built two ways. With a [ServerStore] it is the real thing: servers come out
/// of `shared_preferences`, device keys out of `flutter_secure_storage`, and
/// every call goes through [HttpAgentApi] against the pinned certificate.
/// Without one it is **demo mode**: the three seeded [MockAgentApi] worlds,
/// which is what the widget and unit tests run on and what the Servers screen
/// offers behind "Explore with demo data".
library;

import 'package:flutter/foundation.dart';

import 'agent_api.dart';
import 'http_agent_api.dart';
import 'mock_agent_api.dart';
import 'mock_seed.dart';
import 'models.dart';
import 'pinning.dart';
import 'server_store.dart';
import 'this_device.dart';

/// What the pairing screen shows before the fingerprint is pinned: trust on
/// first use, confirmed by a person.
class PairPreview {
  const PairPreview({
    required this.fingerprint,
    required this.deviceKey,
    required this.deviceId,
    required this.role,
    required this.agentVersion,
    required this.server,
  });

  /// The SHA-256 of the certificate the agent actually presented, which must
  /// equal `cert_fingerprint` in the pairing response.
  final String fingerprint;
  final String deviceKey;
  final String deviceId;
  final ServerRole role;
  final String agentVersion;
  final Server server;
}

class ServersRepository {
  ServersRepository({
    ServerStore? store,
    List<MockWorld>? worlds,
    this.maxServers,
  }) : _store = store {
    if (store == null) {
      _enterDemo(
        worlds ?? <MockWorld>[seedProduction(), seedStaging(), seedOffline()],
      );
      _loaded = true;
    }
  }

  /// Servers that are paired, not sampled, answering from [worlds] instead of
  /// a socket. The one seam the widget tests need to exercise an edition's
  /// limit, which demo mode is exempt from.
  @visibleForTesting
  ServersRepository.pairedMocks(List<MockWorld> worlds, {this.maxServers})
    : _store = null {
    for (final MockWorld world in worlds) {
      _servers[world.server.id] = world.server;
      _apis[world.server.id] = MockAgentApi(world);
      _order.add(world.server.id);
    }
    _loaded = true;
  }

  final ServerStore? _store;

  /// How many servers this edition pairs, or null for as many as you like.
  ///
  /// The limit lives here as well as in the UI so a deep link to the pair
  /// route cannot get past it. Servers that are already paired are never
  /// removed or hidden by it: a phone that arrives with more than the limit
  /// keeps every one of them and simply cannot add another.
  final int? maxServers;

  final Map<String, AgentApi> _apis = <String, AgentApi>{};
  final Map<String, Server> _servers = <String, Server>{};
  final List<String> _order = <String>[];

  bool _loaded = false;
  bool _demo = false;

  /// Set by the app so a `428` from the agent can be answered with a real
  /// biometric prompt without the call site knowing about it.
  ConfirmationHandler? confirmationHandler;

  /// True while the three sample servers stand in for real ones.
  bool get isDemo => _demo;

  /// Whether another server may be paired. Demo mode is never limited.
  bool get canPairAnother =>
      _demo || maxServers == null || servers.length < maxServers!;

  /// True once storage has been read, so the Servers screen knows whether an
  /// empty list means "nothing paired" or "not looked yet".
  bool get isLoaded => _loaded;

  List<Server> get servers => <Server>[
    for (final String id in _order)
      if (_servers[id] != null) _servers[id]!,
  ];

  /// Reads the paired servers out of storage. Safe to call repeatedly.
  Future<void> ensureLoaded() async {
    if (_loaded || _store == null) return;
    final List<Server> stored = await _store.load();
    for (final Server server in stored) {
      await _adopt(server);
    }
    _loaded = true;
  }

  Future<void> _adopt(Server server) async {
    String? key;
    try {
      key = await _store!.deviceKey(server.id);
    } on SecureStorageUnavailable {
      // Nothing can be done with a server whose key cannot be read; the
      // Servers screen shows it as not paired rather than crashing at start.
      return;
    }
    if (key == null || key.isEmpty) return; // key gone: treat as not paired
    _servers[server.id] = server;
    if (!_order.contains(server.id)) _order.add(server.id);
    _apis[server.id] = _buildApi(server, key);
  }

  HttpAgentApi _buildApi(Server server, String deviceKey) => HttpAgentApi(
    baseUrl: server.baseUrl,
    deviceKey: deviceKey,
    pinnedFingerprint: server.certFingerprint,
    onConfirmationRequired: () async =>
        await confirmationHandler?.call() ?? Confirmed.none,
  );

  AgentApi api(String serverId) =>
      _apis[serverId] ??
      (throw AgentException(
        'server_not_found',
        'No server $serverId.',
        status: 404,
      ));

  Server server(String serverId) =>
      _servers[serverId] ??
      (throw AgentException(
        'server_not_found',
        'No server $serverId.',
        status: 404,
      ));

  /// Keeps the cached role and device id in step with `GET /me`.
  Future<void> refreshIdentity(String serverId) async {
    if (_demo || _store == null) return;
    final Server? current = _servers[serverId];
    if (current == null) return;
    final MeInfo? me = await api(serverId).me();
    if (me == null) return;
    if (me.role == current.role && me.deviceId == current.deviceId) return;
    _servers[serverId] = current.copyWith(
      role: me.role,
      deviceId: me.deviceId.isEmpty ? current.deviceId : me.deviceId,
    );
    await _persist();
  }

  Future<void> _persist() async => _store?.save(servers);

  // ------------------------------------------------------------ demo mode

  void _enterDemo(List<MockWorld> worlds) {
    _demo = true;
    for (final MockWorld world in worlds) {
      _servers[world.server.id] = world.server;
      _apis[world.server.id] = MockAgentApi(world);
      if (!_order.contains(world.server.id)) _order.add(world.server.id);
    }
  }

  /// "Explore with demo data" on the Servers empty state.
  Future<void> enterDemoMode() async {
    if (_demo) return;
    await ensureLoaded();
    _enterDemo(<MockWorld>[seedProduction(), seedStaging(), seedOffline()]);
  }

  /// Leaves demo mode and goes back to whatever is really paired.
  Future<void> leaveDemoMode() async {
    if (!_demo || _store == null) return;
    for (final String id in _order.toList()) {
      if (_apis[id] is! MockAgentApi) continue;
      _apis.remove(id)?.dispose();
      _servers.remove(id);
      _order.remove(id);
    }
    _demo = false;
  }

  /// The Servers screen: one card per agent, with its figures when it answers.
  Future<List<ServerCard>> cards() async {
    await ensureLoaded();
    return Future.wait(
      servers.map((Server server) async {
        final AgentApi client = api(server.id);
        try {
          if (!await client.health()) {
            return ServerCard(
              server: server,
              online: false,
              offlineReason: _offlineReason(client),
            );
          }
          final List<Object> both = await Future.wait(<Future<Object>>[
            client.system(),
            client.systemStats(),
          ]);
          return ServerCard(
            server: server,
            online: true,
            info: both[0] as SystemInfo,
            stats: both[1] as SystemStats,
          );
        } on AgentException catch (error) {
          return ServerCard(
            server: server,
            online: false,
            offlineReason: error.toString(),
          );
        }
      }),
    );
  }

  String? _offlineReason(AgentApi client) =>
      client is MockAgentApi ? client.world.offlineReason : null;

  /// Why [serverId] is not answering, when the client knows more than "no".
  String? offlineReasonFor(String serverId) => _offlineReason(api(serverId));

  /// Retry on an offline card. Throws when the agent is still unreachable so
  /// the row can show the failure.
  Future<void> retry(String serverId) async {
    final AgentApi client = api(serverId);
    final bool ok = client is MockAgentApi
        ? await client.retry()
        : await client.health();
    if (!ok) {
      throw AgentException(
        'agent_unreachable',
        _offlineReason(client) ?? 'The agent could not be reached.',
        status: 502,
      );
    }
  }

  // -------------------------------------------------------------- pairing

  /// `POST /v1/pair` with trust on first use.
  ///
  /// The certificate the agent presents during this one call is captured, then
  /// checked against `cert_fingerprint` in the response. Nothing is stored yet:
  /// the caller shows the fingerprint and calls [completePairing] on a yes.
  Future<PairPreview> beginPairing({
    required String name,
    required String agentUrl,
    required String token,
    String? deviceName,
  }) async {
    _refuseWhenFull();
    if (_store == null) {
      return _demoPairing(name: name, agentUrl: agentUrl, token: token);
    }

    final String trimmedUrl = agentUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmedUrl.isEmpty) {
      throw const AgentException(
        'validation_failed',
        'Enter the agent URL, for example https://host:8443.',
        status: 422,
      );
    }
    final Uri base = Uri.parse(
      trimmedUrl.contains('://') ? trimmedUrl : 'https://$trimmedUrl',
    );
    assertTransportIsAllowed(base);
    if (token.trim().isEmpty) {
      throw const AgentException(
        'validation_failed',
        'Enter the pairing token the agent printed.',
        status: 422,
      );
    }

    final String id = _idFor(name.isEmpty ? base.host : name, base);
    if (_servers.containsKey(id)) {
      throw const AgentException(
        'conflict',
        'A server with that name is already paired.',
        status: 409,
      );
    }

    final TofuHttpClient tofu = TofuHttpClient();
    try {
      final Map<String, Object?> body = await HttpAgentApi.pair(
        client: tofu.client,
        baseUrl: base,
        token: token.trim(),
        deviceName: deviceName ?? thisDeviceLabel(),
      );
      final String reported = body['cert_fingerprint'] as String? ?? '';
      final String presented = tofu.presentedFingerprint ?? '';

      if (base.scheme == 'https') {
        if (presented.isEmpty) {
          throw const AgentException(
            'certificate_mismatch',
            'The agent did not present a certificate to pin.',
            status: 495,
          );
        }
        if (reported.isEmpty || !fingerprintsMatch(reported, presented)) {
          throw AgentException(
            'certificate_mismatch',
            'The certificate the agent presented does not match the '
                'fingerprint it reported, so pairing was stopped.',
            status: 495,
            details: <String, Object?>{
              'presented': presented,
              'reported': reported,
            },
          );
        }
      }

      final String fingerprint = presented.isNotEmpty ? presented : reported;
      return PairPreview(
        fingerprint: fingerprint,
        deviceKey: body['device_key'] as String? ?? '',
        deviceId: body['device_id'] as String? ?? '',
        role: ServerRole.parse(body['role'] as String? ?? 'operator'),
        agentVersion: body['agent_version'] as String? ?? '',
        server: Server(
          id: id,
          name: name.trim().isEmpty ? base.host : name.trim(),
          baseUrl: base.toString(),
          certFingerprint: fingerprint,
          deviceId: body['device_id'] as String? ?? '',
          role: ServerRole.parse(body['role'] as String? ?? 'operator'),
        ),
      );
    } finally {
      tofu.close();
    }
  }

  /// The one refusal, thrown before anything is asked of the network and again
  /// before anything is stored.
  void _refuseWhenFull() {
    if (canPairAnother) return;
    throw AgentException(
      'edition_limit',
      'This edition pairs $maxServers servers. Unpair one to make room, or '
          'get Doomsaday Pro.',
      status: 402,
    );
  }

  /// Stores the server and its device key, and pins the fingerprint.
  ///
  /// With no store (demo mode, or the paired mocks the tests use) there is
  /// nothing to write: the server joins the list answered by a
  /// [MockAgentApi], as "Pin and pair" promised.
  Future<PairResult> completePairing(PairPreview preview) async {
    _refuseWhenFull();
    final ServerStore? store = _store;
    if (store == null) return _completeMockPairing(preview);
    if (preview.deviceKey.isEmpty) {
      throw const AgentException(
        'pairing_failed',
        'The agent returned no device key.',
        status: 502,
      );
    }
    try {
      await store.writeDeviceKey(preview.server.id, preview.deviceKey);
    } on SecureStorageUnavailable catch (error) {
      throw AgentException(
        'secure_storage_unavailable',
        error.toString(),
        status: 500,
      );
    }
    _servers[preview.server.id] = preview.server;
    if (!_order.contains(preview.server.id)) _order.add(preview.server.id);
    _apis[preview.server.id] = _buildApi(preview.server, preview.deviceKey);
    await _persist();
    return PairResult(
      deviceKey: preview.deviceKey,
      deviceId: preview.deviceId,
      role: preview.role,
      certFingerprint: preview.fingerprint,
      agentVersion: preview.agentVersion,
      server: preview.server,
    );
  }

  String _idFor(String name, Uri base) {
    final String slug = name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9-]+'), '-')
        .replaceAll(RegExp('^-+|-+\$'), '');
    return slug.isEmpty ? base.host.replaceAll('.', '-') : slug;
  }

  /// Demo mode keeps the old behaviour: pairing adds another sample server.
  Future<PairPreview> _demoPairing({
    required String name,
    required String agentUrl,
    required String token,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (token.trim().isEmpty) {
      throw const AgentException(
        'pairing_failed',
        'The pairing token was rejected by the agent.',
        status: 401,
      );
    }
    final String url = agentUrl.replaceAll(RegExp(r'/+$'), '');
    final String id = name.trim().isEmpty
        ? url.replaceFirst(RegExp(r'^https?://'), '')
        : name.trim();
    if (_servers.containsKey(id)) {
      throw const AgentException(
        'conflict',
        'A server with that name is already paired.',
        status: 409,
      );
    }
    final MockWorld world = seedPaired(id: id, name: id, baseUrl: url);
    return PairPreview(
      fingerprint: world.server.certFingerprint,
      deviceKey: 'dk_demo_${DateTime.now().millisecondsSinceEpoch}',
      deviceId: 'dev-1',
      role: ServerRole.admin,
      agentVersion: world.info.agentVersion,
      server: world.server,
    );
  }

  /// The storeless half of [completePairing]: a sample world under the name
  /// and address that were typed, with the fingerprint that was shown.
  PairResult _completeMockPairing(PairPreview preview) {
    if (_servers.containsKey(preview.server.id)) {
      throw const AgentException(
        'conflict',
        'A server with that name is already paired.',
        status: 409,
      );
    }
    final MockWorld world = seedPaired(
      id: preview.server.id,
      name: preview.server.name,
      baseUrl: preview.server.baseUrl,
    );
    _servers[world.server.id] = world.server;
    _apis[world.server.id] = MockAgentApi(world);
    _order.add(world.server.id);
    return PairResult(
      deviceKey: preview.deviceKey,
      deviceId: preview.deviceId,
      role: preview.role,
      certFingerprint: preview.fingerprint,
      agentVersion: preview.agentVersion,
      server: world.server,
    );
  }

  /// Demo mode: pairing and confirming in one step, which the unit tests use.
  Future<PairResult> pair({
    required String name,
    required String agentUrl,
    required String token,
    String? deviceName,
  }) async {
    final PairPreview preview = await beginPairing(
      name: name,
      agentUrl: agentUrl,
      token: token,
      deviceName: deviceName,
    );
    return completePairing(preview);
  }

  /// "Unpair this server": revoke this device on the agent, then forget it.
  Future<void> unpair(
    String serverId, {
    Confirmed confirmed = Confirmed.none,
  }) async {
    final Server? server = _servers[serverId];
    final AgentApi? client = _apis[serverId];
    if (server != null && client != null && _store != null) {
      try {
        await client.removeDevice(server.deviceId, confirmed: confirmed);
      } on AgentException catch (error) {
        // A `409` means another admin has to do it; anything else (an agent
        // that is already gone) must not trap the server on the phone.
        if (error.status == 409) rethrow;
      }
    }
    client?.dispose();
    _apis.remove(serverId);
    _servers.remove(serverId);
    _order.remove(serverId);
    await _store?.deleteDeviceKey(serverId);
    await _persist();
  }
}
