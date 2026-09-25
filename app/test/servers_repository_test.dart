import 'dart:convert';
import 'dart:io';

import 'package:doomsaday/data/models.dart';
import 'package:doomsaday/data/server_store.dart';
import 'package:doomsaday/data/servers_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_agent.dart';

void main() {
  group('storage', () {
    test(
      'a server round-trips through the store, the key stays apart',
      () async {
        final MemoryServerStore store = MemoryServerStore();
        const Server server = Server(
          id: 'prod-eu-1',
          name: 'prod-eu-1',
          baseUrl: 'https://agent.example.com:8443',
          certFingerprint: 'AA:BB:CC',
          deviceId: 'dev-1',
          role: ServerRole.admin,
        );

        await store.save(<Server>[server]);
        await store.writeDeviceKey(server.id, 'dk_secret');

        final List<Server> loaded = await store.load();
        expect(loaded.single.id, 'prod-eu-1');
        expect(loaded.single.certFingerprint, 'AA:BB:CC');
        expect(loaded.single.role, ServerRole.admin);
        expect(loaded.single.host, 'agent.example.com:8443');
        // The record itself never carries the key.
        expect(
          jsonEncode(loaded.single.toJson()),
          isNot(contains('dk_secret')),
        );
        expect(await store.deviceKey('prod-eu-1'), 'dk_secret');
      },
    );
  });

  group('a repository backed by a store', () {
    late FakeAgent agent;
    late MemoryServerStore store;
    late ServersRepository repo;

    setUp(() async {
      agent = await FakeAgent.start();
      store = MemoryServerStore();
      repo = ServersRepository(store: store);

      agent.on('POST /v1/pair', (HttpRequest request) async {
        final Object? body = jsonDecode(await utf8.decodeStream(request));
        if (body is Map && body['token'] != 'pair-4821-9de2') {
          request.response.statusCode = 401;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(
              errorBody('pairing_failed', 'the pairing token is not valid'),
            ),
          );
          return;
        }
        request.response.statusCode = 201;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{
            'device_key': 'dk_live',
            'device_id': 'dev-7',
            'role': 'admin',
            // Plain HTTP presents no certificate, so there is nothing to pin.
            'cert_fingerprint': '',
            'agent_version': '1.4.2',
          }),
        );
      });
      agent.json('GET /v1/health', <String, Object?>{'ok': true});
      agent.json('GET /v1/system', <String, Object?>{
        'hostname': 'paired-host',
        'docker_version': '27.1',
        'agent_version': '1.4.2',
        'cpu_cores': 2,
        'memory_total': 100,
        'disk_total': 100,
        'disk_used': 10,
        'swarm_role': 'inactive',
        'agent_uptime_seconds': 5,
        'host_uptime_seconds': 5,
      });
      agent.json('GET /v1/system/stats', <String, Object?>{
        'cpu_percent': 5.0,
        'memory_used': 10,
        'memory_total': 100,
        'disk_used': 10,
        'disk_total': 100,
        'containers': <String, Object?>{'running': 1, 'total': 1},
      });
      agent.json('DELETE /v1/devices/dev-7', null, status: 204);
    });

    tearDown(() => agent.close());

    test('starts empty and is not in demo mode', () async {
      await repo.ensureLoaded();
      expect(repo.servers, isEmpty);
      expect(repo.isDemo, isFalse);
      expect(await repo.cards(), isEmpty);
    });

    test('pairing stores the server and its key, and lists a card', () async {
      final PairPreview preview = await repo.beginPairing(
        name: 'Edge 1',
        agentUrl: agent.baseUrl,
        token: 'pair-4821-9de2',
      );
      expect(preview.deviceKey, 'dk_live');
      expect(preview.role, ServerRole.admin);
      // Nothing is stored until the fingerprint is confirmed.
      expect(repo.servers, isEmpty);
      expect(await store.deviceKey('edge-1'), isNull);

      final PairResult result = await repo.completePairing(preview);
      expect(result.server.id, 'edge-1');
      expect(repo.servers.single.name, 'Edge 1');
      expect(await store.deviceKey('edge-1'), 'dk_live');
      expect((await store.load()).single.deviceId, 'dev-7');

      final List<ServerCard> cards = await repo.cards();
      expect(cards.single.online, isTrue);
      expect(cards.single.info!.hostname, 'paired-host');
      expect(cards.single.stats!.containers.total, 1);
    });

    test('a rejected token leaves nothing behind', () async {
      await expectLater(
        repo.beginPairing(
          name: 'edge-2',
          agentUrl: agent.baseUrl,
          token: 'wrong',
        ),
        throwsA(
          isA<AgentException>().having(
            (AgentException e) => e.code,
            'code',
            'pairing_failed',
          ),
        ),
      );
      expect(repo.servers, isEmpty);
      expect(await store.load(), isEmpty);
    });

    test('unpairing revokes this device and forgets it locally', () async {
      final PairPreview preview = await repo.beginPairing(
        name: 'edge-1',
        agentUrl: agent.baseUrl,
        token: 'pair-4821-9de2',
      );
      await repo.completePairing(preview);

      await repo.unpair('edge-1', confirmed: Confirmed.biometric);
      expect(agent.requests, contains('DELETE /v1/devices/dev-7'));
      expect(agent.confirmations.last, 'biometric');
      expect(repo.servers, isEmpty);
      expect(await store.load(), isEmpty);
      expect(await store.deviceKey('edge-1'), isNull);
    });

    test('a 409 on the last admin keeps the server on the phone', () async {
      final PairPreview preview = await repo.beginPairing(
        name: 'edge-1',
        agentUrl: agent.baseUrl,
        token: 'pair-4821-9de2',
      );
      await repo.completePairing(preview);

      agent.json(
        'DELETE /v1/devices/dev-7',
        errorBody('conflict', 'the last admin device cannot be revoked'),
        status: 409,
      );
      await expectLater(
        repo.unpair('edge-1', confirmed: Confirmed.biometric),
        throwsA(
          isA<AgentException>().having(
            (AgentException e) => e.status,
            'status',
            409,
          ),
        ),
      );
      expect(repo.servers, hasLength(1));
    });

    test('GET /me keeps the cached role in step', () async {
      final PairPreview preview = await repo.beginPairing(
        name: 'edge-1',
        agentUrl: agent.baseUrl,
        token: 'pair-4821-9de2',
      );
      await repo.completePairing(preview);
      expect(repo.server('edge-1').role, ServerRole.admin);

      agent.json('GET /v1/me', <String, Object?>{
        'device_id': 'dev-7',
        'device_name': 'This phone',
        'role': 'viewer',
        'cert_fingerprint': '',
        'paired_devices': 2,
        'agent_version': '1.4.2',
      });
      await repo.refreshIdentity('edge-1');
      expect(repo.server('edge-1').role, ServerRole.viewer);
      expect((await store.load()).single.role, ServerRole.viewer);
    });

    test('an agent with no /me leaves the cached role alone', () async {
      final PairPreview preview = await repo.beginPairing(
        name: 'edge-1',
        agentUrl: agent.baseUrl,
        token: 'pair-4821-9de2',
      );
      await repo.completePairing(preview);
      await repo.refreshIdentity('edge-1');
      expect(repo.server('edge-1').role, ServerRole.admin);
    });

    test('demo mode can be entered and left again', () async {
      await repo.ensureLoaded();
      expect(repo.isDemo, isFalse);

      await repo.enterDemoMode();
      expect(repo.isDemo, isTrue);
      expect(repo.servers.map((Server s) => s.id), <String>[
        'prod-eu-1',
        'staging-1',
        'backup-nas',
      ]);

      await repo.leaveDemoMode();
      expect(repo.isDemo, isFalse);
      expect(repo.servers, isEmpty);
    });

    test('a 428 is answered by the confirmation handler', () async {
      int prompts = 0;
      repo.confirmationHandler = () async {
        prompts++;
        return Confirmed.biometric;
      };
      final PairPreview preview = await repo.beginPairing(
        name: 'edge-1',
        agentUrl: agent.baseUrl,
        token: 'pair-4821-9de2',
      );
      await repo.completePairing(preview);

      agent.on('POST /v1/containers/c1/stop', (HttpRequest request) {
        if (request.headers.value('X-Confirmed') == null) {
          request.response.statusCode = 428;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(
              errorBody('confirmation_required', 'needs a confirmation'),
            ),
          );
          return;
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, Object?>{'ok': true}));
      });

      await repo.api('edge-1').stopContainer('c1');
      expect(prompts, 1);
    });
  });

  group('the demo repository', () {
    test('has no store and keeps everything in memory', () async {
      final ServersRepository repo = ServersRepository();
      expect(repo.isDemo, isTrue);
      expect(repo.servers, hasLength(3));
      // Leaving demo mode is meaningless without a store, so it is a no-op.
      await repo.leaveDemoMode();
      expect(repo.servers, hasLength(3));
    });
  });
}
