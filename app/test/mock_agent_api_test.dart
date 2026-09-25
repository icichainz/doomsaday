import 'package:doomsaday/data/mock_agent_api.dart';
import 'package:doomsaday/data/mock_seed.dart';
import 'package:doomsaday/data/models.dart';
import 'package:doomsaday/data/servers_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MockAgentApi mutations', () {
    late MockAgentApi api;

    setUp(() => api = MockAgentApi(seedProduction()));

    test('seeds the containers and counts the design shows', () async {
      final List<ContainerSummary> all = await api.containers();
      expect(all.length, 16);
      expect(all.first.name, 'nginx-proxy');
      expect(all[1].id, '4f2a9c1e7b3d');

      final SystemStats stats = await api.systemStats();
      expect(stats.running + stats.restarting, 14);
      expect(stats.stopped, 2);
      expect(stats.total, 16);
    });

    test('stopping a container changes its state and the counts', () async {
      await api.stopContainer('4f2a9c1e7b3d', confirmed: Confirmed.biometric);

      final List<ContainerSummary> all = await api.containers();
      final ContainerSummary stopped = all.firstWhere(
        (ContainerSummary c) => c.id == '4f2a9c1e7b3d',
      );
      expect(stopped.state, ContainerState.exited);
      expect(api.world.stats.stopped, 3);

      final List<ContainerSummary> running = await api.containers(
        state: ContainerState.running,
      );
      expect(
        running.any((ContainerSummary c) => c.id == '4f2a9c1e7b3d'),
        isFalse,
      );
    });

    test(
      'starting a stopped container puts it back in the running filter',
      () async {
        await api.startContainer('91f6c0b4d2a8');
        final List<ContainerSummary> running = await api.containers(
          state: ContainerState.running,
        );
        expect(
          running.any((ContainerSummary c) => c.id == '91f6c0b4d2a8'),
          isTrue,
        );
      },
    );

    test('filters narrow the list', () async {
      expect((await api.containers(state: ContainerState.running)).length, 14);
      expect((await api.containers(state: ContainerState.exited)).length, 2);
      expect((await api.containers(query: 'postgres')).length, 2);
      expect((await api.containers(stack: 'monitoring')).length, 3);
    });

    test('scaling a service changes the replica count', () async {
      await api.scaleService('svc-api', 5);
      final List<SwarmService> services = await api.services();
      final SwarmService api5 = services.firstWhere(
        (SwarmService s) => s.id == 'svc-api',
      );
      expect(api5.desired, 5);
      expect(api5.updateState, 'updating');
    });

    test('the five rule ids of Revision 1.1 are all there', () async {
      final List<AlertRule> rules = await api.alertRules();
      expect(rules.map((AlertRule r) => r.id), <String>[
        AlertRuleId.unexpectedExit,
        AlertRuleId.restartLoop,
        AlertRuleId.cpuHigh,
        AlertRuleId.memoryHigh,
        AlertRuleId.agentUnreachable,
      ]);
    });

    test('toggling an alert rule sticks for the session', () async {
      await api.updateAlertRule(AlertRuleId.unexpectedExit, enabled: false);
      final List<AlertRule> rules = await api.alertRules();
      expect(
        rules
            .firstWhere((AlertRule r) => r.id == AlertRuleId.unexpectedExit)
            .enabled,
        isFalse,
      );
    });

    test('muting an alert drops it from the active list', () async {
      expect((await api.alerts(state: AlertState.active)).length, 2);
      await api.muteAlert('${AlertRuleId.restartLoop}|7d1b5e0c88af');
      expect((await api.alerts(state: AlertState.active)).length, 1);
      expect((await api.alerts(state: AlertState.muted)).length, 1);
    });

    test('resolving an alert moves it to the resolved set', () async {
      await api.resolveAlert('${AlertRuleId.unexpectedExit}|91f6c0b4d2a8');
      expect((await api.alerts(state: AlertState.active)).length, 1);
      expect((await api.alerts(state: AlertState.resolved)).length, 2);
    });

    test(
      'image prune removes the unused rows and clears the reclaimable size',
      () async {
        final ImageList before = await api.images();
        expect(before.images.where((DockerImage i) => !i.inUse).length, 2);

        await api.pruneImages(
          danglingOnly: false,
          confirmed: Confirmed.biometric,
        );
        await Future<void>.delayed(const Duration(seconds: 3));

        final ImageList after = await api.images();
        expect(after.images.where((DockerImage i) => !i.inUse), isEmpty);
        expect(after.reclaimableBytes, 0);
        expect(after.totalCount, before.totalCount - 2);
      },
    );

    test('volume prune keeps the mounted volumes', () async {
      final VolumeList before = await api.volumes();
      expect(before.count, 9);
      expect(before.unmounted, 2);

      await api.pruneVolumes(confirmed: Confirmed.biometric);
      await Future<void>.delayed(const Duration(seconds: 3));

      final VolumeList after = await api.volumes();
      expect(after.count, 7);
      expect(after.unmounted, 0);
      expect(after.volumes.every((VolumeInfo v) => v.mounted), isTrue);
    });

    test('network prune keeps default networks', () async {
      await api.pruneNetworks(confirmed: Confirmed.biometric);
      await Future<void>.delayed(const Duration(seconds: 3));
      final NetworkList after = await api.networks();
      expect(
        after.networks.any((NetworkInfo n) => n.name == 'old_test_net'),
        isFalse,
      );
      expect(after.networks.any((NetworkInfo n) => n.isDefault), isTrue);
    });

    test('bringing a stack down stops its containers', () async {
      await api.stackDown('monitoring', confirmed: Confirmed.biometric);
      await Future<void>.delayed(const Duration(seconds: 3));

      final List<ComposeStack> stacks = await api.stacks();
      expect(
        stacks
            .firstWhere((ComposeStack s) => s.name == 'monitoring')
            .servicesUp,
        0,
      );
      final List<ContainerSummary> monitoring = await api.containers(
        stack: 'monitoring',
      );
      expect(
        monitoring.every((ContainerSummary c) => !c.state.isRunning),
        isTrue,
      );
    });

    test('settings persist for the session', () async {
      await api.updateSettings(requireBiometricForRisky: false);
      expect((await api.settings()).requireBiometricForRisky, isFalse);
      // With the rule off the agent no longer asks for the header.
      await api.stopContainer('4f2a9c1e7b3d');
    });

    test('a stop without the confirmation header is refused with 428', () {
      expect(
        () => api.stopContainer('4f2a9c1e7b3d'),
        throwsA(
          isA<AgentException>()
              .having(
                (AgentException e) => e.code,
                'code',
                'confirmation_required',
              )
              .having((AgentException e) => e.status, 'status', 428),
        ),
      );
    });

    test('the viewer role refuses every mutating call', () async {
      final MockAgentApi viewer = MockAgentApi(seedProduction());
      viewer.world.server = viewer.world.server.copyWith(
        role: ServerRole.viewer,
      );
      expect(
        () => viewer.startContainer('91f6c0b4d2a8'),
        throwsA(
          isA<AgentException>()
              .having((AgentException e) => e.code, 'code', 'forbidden')
              .having((AgentException e) => e.status, 'status', 403),
        ),
      );
      // Reads stay open to a viewer.
      expect((await viewer.containers()).length, 16);
    });

    test('an operator may stop but not remove', () async {
      final MockAgentApi operator = MockAgentApi(seedProduction());
      operator.world.server = operator.world.server.copyWith(
        role: ServerRole.operator,
      );
      await operator.stopContainer(
        '4f2a9c1e7b3d',
        confirmed: Confirmed.biometric,
      );
      expect(
        () => operator.removeContainer(
          '4f2a9c1e7b3d',
          confirmed: Confirmed.biometric,
        ),
        throwsA(
          isA<AgentException>().having(
            (AgentException e) => e.status,
            'status',
            403,
          ),
        ),
      );
    });

    test('the agent update job moves the reported version', () async {
      await api.startAgentUpdate();
      await Future<void>.delayed(const Duration(seconds: 4));
      expect((await api.system()).agentVersion, '1.5.0');
      expect((await api.agentUpdate()).available, isFalse);
    });
  });

  group('offline agent', () {
    late MockAgentApi api;

    setUp(() => api = MockAgentApi(seedOffline()));

    test('health is false and every read throws', () async {
      expect(await api.health(), isFalse);
      expect(
        () => api.containers(),
        throwsA(
          isA<AgentException>().having(
            (AgentException e) => e.isUnreachable,
            'isUnreachable',
            true,
          ),
        ),
      );
    });
  });

  group('staging agent', () {
    late MockAgentApi api;

    setUp(() => api = MockAgentApi(seedStaging()));

    test('has no stacks and answers /swarm with active false', () async {
      expect(await api.stacks(), isEmpty);
      final SwarmInfo swarm = await api.swarm();
      expect(swarm.active, isFalse);
      expect(swarm.isManager, isFalse);
      expect(
        () => api.services(),
        throwsA(
          isA<AgentException>().having(
            (AgentException e) => e.code,
            'code',
            'not_a_manager',
          ),
        ),
      );
    });
  });

  group('ServersRepository', () {
    test(
      'lists the three seeded servers with the offline one flagged',
      () async {
        final ServersRepository repo = ServersRepository();
        final List<ServerCard> cards = await repo.cards();
        expect(cards.map((ServerCard c) => c.server.name), <String>[
          'prod-eu-1',
          'staging-1',
          'backup-nas',
        ]);
        expect(cards.last.online, isFalse);
        expect(
          cards.last.offlineReason,
          'Agent unreachable. Last seen 2 h ago.',
        );
      },
    );

    test('retry on the offline server keeps failing', () async {
      final ServersRepository repo = ServersRepository();
      expect(() => repo.retry('backup-nas'), throwsA(isA<AgentException>()));
    });

    test('pairing adds a server, unpairing removes it', () async {
      final ServersRepository repo = ServersRepository();
      final PairResult result = await repo.pair(
        name: 'edge-1',
        agentUrl: 'https://edge.example.com:8443',
        token: 'pair-0001',
      );
      expect(result.server.id, 'edge-1');
      expect(repo.servers.length, 4);

      await repo.unpair('edge-1');
      expect(repo.servers.length, 3);
    });

    test('pairing without a token is rejected', () async {
      final ServersRepository repo = ServersRepository();
      expect(
        () => repo.pair(
          name: 'edge-2',
          agentUrl: 'https://edge2.example.com:8443',
          token: '  ',
        ),
        throwsA(
          isA<AgentException>().having(
            (AgentException e) => e.code,
            'code',
            'pairing_failed',
          ),
        ),
      );
    });
  });
}
