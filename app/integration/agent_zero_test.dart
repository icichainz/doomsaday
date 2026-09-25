/// End-to-end against a real `agent_zero`.
///
/// It is skipped unless both `AGENT_ZERO_URL` and `AGENT_ZERO_TOKEN` are set,
/// so `flutter test` stays hermetic. To run it:
///
/// ```sh
/// cd ../agent_zero && go build -o "$TMPDIR/agent_zero_it" ./cmd/agent_zero
/// "$TMPDIR/agent_zero_it" serve --listen 127.0.0.1:18443 \
///     --data-dir "$TMPDIR/agent_zero_it_data"
/// "$TMPDIR/agent_zero_it" pair-token --data-dir "$TMPDIR/agent_zero_it_data"
/// AGENT_ZERO_URL=https://127.0.0.1:18443 AGENT_ZERO_TOKEN=<token> \
///     flutter test integration/agent_zero_test.dart
/// ```
///
/// **Safety.** Read-only calls are free. The only container it ever touches is
/// one whose name starts with `agentzero-test-`, and it is passed in through
/// `AGENT_ZERO_TEST_CONTAINER`. Nothing else on the host is started, stopped,
/// removed or pruned, and the test refuses to act on a name that does not
/// carry that prefix.
@Tags(<String>['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:doomsaday/data/agent_api.dart';
import 'package:doomsaday/data/exec_session.dart';
import 'package:doomsaday/data/models.dart';
import 'package:doomsaday/data/http_agent_api.dart';
import 'package:doomsaday/data/pinning.dart';
import 'package:doomsaday/data/server_store.dart';
import 'package:doomsaday/data/servers_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// The one prefix this test is allowed to mutate.
const String kTestPrefix = 'agentzero-test-';

String? get _url => Platform.environment['AGENT_ZERO_URL'];
String? get _token => Platform.environment['AGENT_ZERO_TOKEN'];
String? get _testContainer => Platform.environment['AGENT_ZERO_TEST_CONTAINER'];

void main() {
  final String? url = _url;
  final String? token = _token;
  if (url == null || url.isEmpty || token == null || token.isEmpty) {
    test(
      'agent_zero integration',
      () {},
      skip: 'set AGENT_ZERO_URL and AGENT_ZERO_TOKEN',
    );
    return;
  }

  late ServersRepository repo;
  late MemoryServerStore store;
  late String serverId;
  late AgentApi api;
  late ServerRole role;

  setUpAll(() async {
    store = MemoryServerStore();
    repo = ServersRepository(store: store);

    // Trust on first use: the fingerprint the agent presented must equal the
    // one it reported, and only then is it pinned.
    final PairPreview preview = await repo.beginPairing(
      name: 'it-agent',
      agentUrl: url,
      token: token,
      deviceName: 'Integration test',
    );
    expect(
      isCompleteFingerprint(preview.fingerprint),
      isTrue,
      reason: 'the agent must present a full SHA-256 fingerprint over TLS',
    );
    await repo.completePairing(preview);
    serverId = preview.server.id;
    api = repo.api(serverId);
    role = preview.role;
  });

  tearDownAll(() async {
    // Revoking this device is the only write the test leaves behind, and it
    // only ever touches the device it created.
    try {
      await repo.unpair(serverId, confirmed: Confirmed.biometric);
    } on AgentException catch (error) {
      // A 409 means this was the last admin; the temporary data dir goes away
      // with the agent anyway.
      printOnFailure('unpair: $error');
    }
    // Let the pooled sockets finish closing before the runner tears the zone
    // down, so nothing lands after the last test.
    await Future<void>.delayed(const Duration(seconds: 1));
  });

  test('the pinned certificate is what the agent actually presents', () async {
    final Server server = repo.server(serverId);
    expect(isCompleteFingerprint(server.certFingerprint), isTrue);
    expect(await api.health(), isTrue);

    // A client pinned to a different certificate must be refused. Tearing a
    // rejected TLS connection down makes dart:io report the closed socket
    // asynchronously, which is noise rather than a failure, so the whole
    // check runs inside its own zone.
    final String deviceKey = (await store.deviceKey(serverId))!;
    final Completer<Object?> outcome = Completer<Object?>();
    runZonedGuarded(() async {
      final HttpAgentApi probe = HttpAgentApi(
        baseUrl: server.baseUrl,
        deviceKey: deviceKey,
        pinnedFingerprint:
            'FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:'
            'FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF:FF',
      );
      try {
        await probe.system();
        if (!outcome.isCompleted) outcome.complete(null);
      } catch (error) {
        if (!outcome.isCompleted) outcome.complete(error);
      } finally {
        probe.dispose();
      }
    }, (Object error, StackTrace stack) {});

    final Object? error = await outcome.future;
    expect(
      error,
      isA<AgentException>().having(
        (AgentException e) => e.code,
        'code',
        'certificate_mismatch',
      ),
    );
    // Give the rejected socket a moment to finish tearing down inside the
    // guarded zone, so nothing lands after the test.
    await Future<void>.delayed(const Duration(seconds: 1));
  });

  test('GET /me, tolerating an agent that does not have it yet', () async {
    final MeInfo? me = await api.me();
    if (me == null) {
      printOnFailure('this agent build has no GET /v1/me yet');
      return;
    }
    expect(me.deviceId, repo.server(serverId).deviceId);
    expect(me.role, role);
    expect(me.pairedDevices, greaterThanOrEqualTo(1));
    expect(
      fingerprintsMatch(
        me.certFingerprint,
        repo.server(serverId).certFingerprint,
      ),
      isTrue,
    );
  });

  test('system and stats come back as raw figures', () async {
    final SystemInfo info = await api.system();
    expect(info.hostname, isNotEmpty);
    expect(info.dockerVersion, isNotEmpty);
    expect(info.agentVersion, isNotEmpty);
    expect(info.cpuCores, greaterThan(0));
    expect(info.memoryTotalBytes, greaterThan(0));

    final SystemStats stats = await api.systemStats();
    expect(stats.cpuPercent, greaterThanOrEqualTo(0));
    expect(stats.memoryTotalBytes, greaterThan(0));
    expect(stats.containers.total, greaterThanOrEqualTo(stats.containers.up));
    expect(<String>['host', 'containers'], contains(stats.cpuSource));
  });

  test('containers, images, volumes and networks all parse', () async {
    final List<ContainerSummary> containers = await api.containers();
    for (final ContainerSummary c in containers) {
      expect(c.id, isNotEmpty);
      expect(c.name, isNotEmpty);
      // Every display string is derived, so exercising them catches a bad
      // field name the parser silently defaulted.
      expect(c.stateLabel, isNotEmpty);
      expect(c.meta, isNotEmpty);
    }

    final ImageList images = await api.images();
    expect(images.totalCount, greaterThanOrEqualTo(images.images.length));
    for (final DockerImage image in images.images) {
      expect(image.ref, isNotEmpty);
    }

    final VolumeList volumes = await api.volumes();
    expect(volumes.count, greaterThanOrEqualTo(volumes.volumes.length));

    final NetworkList networks = await api.networks();
    expect(networks.count, greaterThanOrEqualTo(networks.networks.length));
    expect(
      networks.networks.any((NetworkInfo n) => n.name == 'bridge'),
      isTrue,
      reason: 'every Docker host has a default bridge network',
    );
  });

  test('swarm answers 200 even off a swarm, services may 409', () async {
    final SwarmInfo swarm = await api.swarm();
    if (!swarm.active) {
      await expectLater(
        api.services(),
        throwsA(
          isA<AgentException>().having(
            (AgentException e) => e.isNotAManager,
            'not_a_manager',
            true,
          ),
        ),
      );
      return;
    }
    expect(await api.services(), isA<List<SwarmService>>());
  });

  test('stacks, alerts, rules, registries and settings all parse', () async {
    expect(await api.stacks(), isA<List<ComposeStack>>());
    expect(await api.alerts(), isA<List<AlertInfo>>());

    final List<AlertRule> rules = await api.alertRules();
    expect(
      rules.map((AlertRule r) => r.id),
      containsAll(<String>[
        AlertRuleId.unexpectedExit,
        AlertRuleId.restartLoop,
        AlertRuleId.cpuHigh,
        AlertRuleId.memoryHigh,
        AlertRuleId.agentUnreachable,
      ]),
    );
    expect(
      rules
          .firstWhere((AlertRule r) => r.id == AlertRuleId.agentUnreachable)
          .evaluatedLocally,
      isFalse,
    );

    expect(await api.registries(), isA<List<RegistryInfo>>());

    final AgentSettings settings = await api.settings();
    expect(settings.stacksDirectory, isNotEmpty);
    expect(settings.pushRelayStatus, isNotEmpty);

    final AgentUpdate update = await api.agentUpdate();
    expect(update.current, isNotEmpty);

    final List<DeviceInfo> devices = await api.devices();
    expect(devices.any((DeviceInfo d) => d.isSelf), isTrue);
  });

  test('the activity log carries this session', () async {
    final List<ActivityEntry> activity = await api.activity();
    expect(activity, isNotEmpty);
    expect(
      activity.any((ActivityEntry a) => a.action.contains('/v1/pair')),
      isTrue,
    );
    for (final ActivityEntry entry in activity) {
      expect(entry.text, isNotEmpty);
      expect(entry.at, isNotEmpty);
    }
  });

  test('an SSE stream delivers a few events and cancels cleanly', () async {
    final List<SystemStats> seen = <SystemStats>[];
    final StreamSubscription<SystemStats> subscription = api
        .systemStatsStream()
        .listen(seen.add);
    await Future<void>.delayed(const Duration(seconds: 8));
    await subscription.cancel();
    expect(
      seen.length,
      greaterThanOrEqualTo(2),
      reason: 'the stats stream emits every few seconds',
    );
    expect(seen.last.memoryTotalBytes, greaterThan(0));
  });

  test('a refused call comes back as a real 403, 404 or 428', () async {
    // Something that does not exist, whatever the role.
    await expectLater(
      api.container('no-such-container-id'),
      throwsA(
        isA<AgentException>().having(
          (AgentException e) => e.status,
          'status',
          anyOf(404, 422),
        ),
      ),
    );

    final AgentSettings settings = await api.settings();
    if (!role.isAdmin) {
      // A non-admin device must be refused the environment values.
      await expectLater(
        api.containerEnv('whatever'),
        throwsA(
          isA<AgentException>().having(
            (AgentException e) => e.status,
            'status',
            403,
          ),
        ),
      );
      return;
    }
    if (!settings.requireBiometricForRisky) {
      printOnFailure('the confirmation rule is off on this agent');
      return;
    }
    // Admin, rule on: a risky call without the header must be 428, and the
    // target does not have to exist for the middleware to refuse it.
    await expectLater(
      api.stopContainer('no-such-container-id'),
      throwsA(
        isA<AgentException>()
            .having((AgentException e) => e.status, 'status', 428)
            .having(
              (AgentException e) => e.needsConfirmation,
              'needsConfirmation',
              true,
            ),
      ),
    );
  });

  group('the one container this test may touch', () {
    final String? name = _testContainer;

    setUpAll(() {
      if (name != null && !name.startsWith(kTestPrefix)) {
        fail(
          'AGENT_ZERO_TEST_CONTAINER must start with "$kTestPrefix"; '
          'refusing to act on "$name"',
        );
      }
    });

    test('stop, start and logs on the test container only', () async {
      if (name == null) {
        printOnFailure('set AGENT_ZERO_TEST_CONTAINER to exercise mutations');
        return;
      }
      if (!role.isAdmin && !role.canOperate) return;

      final List<ContainerSummary> containers = await api.containers();
      final ContainerSummary target = containers.firstWhere(
        (ContainerSummary c) => c.name == name,
        orElse: () => fail('container $name is not on this host'),
      );
      expect(target.name.startsWith(kTestPrefix), isTrue);

      final ContainerDetail detail = await api.container(target.id);
      expect(detail.name, name);
      expect(detail.restartPolicy, isNotEmpty);

      final ContainerImpact impact = await api.containerImpact(target.id);
      expect(impact.publishedPorts, isA<List<PortMapping>>());

      final List<LogLine> logs = await api.logs(target.id, tail: 10);
      expect(logs, isA<List<LogLine>>());

      // The stop carries the confirmation header, which is the whole point.
      await api.stopContainer(target.id, confirmed: Confirmed.biometric);
      final List<ContainerSummary> after = await api.containers();
      expect(
        after
            .firstWhere((ContainerSummary c) => c.id == target.id)
            .state
            .isRunning,
        isFalse,
      );

      await api.startContainer(target.id);
      final List<ContainerSummary> restarted = await api.containers();
      expect(
        restarted
            .firstWhere((ContainerSummary c) => c.id == target.id)
            .state
            .isRunning,
        isTrue,
      );
    });

    test('an exec session opens and closes on the test container', () async {
      if (name == null || !role.canExec) return;
      final List<ContainerSummary> containers = await api.containers();
      final ContainerSummary target = containers.firstWhere(
        (ContainerSummary c) => c.name == name,
        orElse: () => fail('container $name is not on this host'),
      );
      if (!target.state.isRunning) return;

      final ExecSession session = await api.exec(target.id, cols: 80, rows: 24);
      final List<String> output = <String>[];
      final StreamSubscription<String> subscription = session.output.listen(
        output.add,
      );
      session.send('echo doomsaday-exec-ok\n');
      await Future<void>.delayed(const Duration(seconds: 2));
      session.send('exit\n');
      await session.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () => null,
      );
      await subscription.cancel();
      await session.close();
      expect(output.join(), contains('doomsaday-exec-ok'));
    });
  });
}
