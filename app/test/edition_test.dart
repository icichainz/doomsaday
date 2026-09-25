/// The edition itself: how it is resolved, and the one rule the repository
/// enforces for it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:doomsaday/data/mock_seed.dart';
import 'package:doomsaday/data/models.dart';
import 'package:doomsaday/data/server_store.dart';
import 'package:doomsaday/data/servers_repository.dart';
import 'package:doomsaday/edition/edition.dart';
import 'package:flutter/services.dart' show appFlavor;
import 'package:flutter_test/flutter_test.dart';

import 'fake_agent.dart';

void main() {
  group('resolving the edition', () {
    test('the flavor decides, and the define stands in when there is none', () {
      expect(editionFrom(), Edition.free);
      expect(editionFrom(define: 'pro'), Edition.pro);
      expect(editionFrom(define: 'free'), Edition.free);
      expect(editionFrom(define: 'anything else'), Edition.free);
      expect(editionFrom(flavor: 'pro'), Edition.pro);
      expect(editionFrom(flavor: 'free'), Edition.free);
      // A flavor is what was actually built, so it beats a stray define.
      expect(editionFrom(flavor: 'free', define: 'pro'), Edition.free);
    });

    test('the constant this build folded agrees with the rule', () {
      expect(
        currentEdition,
        editionFrom(
          flavor: appFlavor,
          define: const String.fromEnvironment('EDITION'),
        ),
      );
      expect(currentEdition.isPro, buildIsPro);
    });

    test('each edition names what it may do', () {
      expect(Edition.free.displayName, 'Doomsaday');
      expect(Edition.free.maxServers, 2);
      expect(Edition.free.fleetView, isFalse);
      expect(Edition.free.logWall, isFalse);
      expect(Edition.free.crossServerPalette, isFalse);
      expect(Edition.free.allowsAnotherServer(1), isTrue);
      expect(Edition.free.allowsAnotherServer(2), isFalse);
      expect(Edition.free.allowsAnotherServer(5), isFalse);

      expect(Edition.pro.displayName, 'Doomsaday Pro');
      expect(Edition.pro.maxServers, isNull);
      expect(Edition.pro.fleetView, isTrue);
      expect(Edition.pro.logWall, isTrue);
      expect(Edition.pro.crossServerPalette, isTrue);
      expect(Edition.pro.allowsAnotherServer(99), isTrue);
    });
  });

  group('the repository holds the limit', () {
    late FakeAgent agent;
    late MemoryServerStore store;

    setUp(() async {
      agent = await FakeAgent.start();
      store = MemoryServerStore();
      agent.on('POST /v1/pair', (HttpRequest request) async {
        await utf8.decodeStream(request);
        request.response.statusCode = 201;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{
            'device_key': 'dk_live',
            'device_id': 'dev-7',
            'role': 'admin',
            'cert_fingerprint': '',
            'agent_version': '1.4.2',
          }),
        );
      });
      agent.json('GET /v1/health', <String, Object?>{'ok': true});
    });

    tearDown(() => agent.close());

    Future<void> pairOne(ServersRepository repo, String name) async {
      await repo.completePairing(
        await repo.beginPairing(
          name: name,
          agentUrl: agent.baseUrl,
          token: 'pair-4821-9de2',
        ),
      );
    }

    test('two pair on Free and the third is refused', () async {
      final ServersRepository repo = ServersRepository(
        store: store,
        maxServers: 2,
      );
      await pairOne(repo, 'edge-1');
      await pairOne(repo, 'edge-2');
      expect(repo.servers.length, 2);
      expect(repo.canPairAnother, isFalse);

      await expectLater(
        pairOne(repo, 'edge-3'),
        throwsA(
          isA<AgentException>()
              .having((AgentException e) => e.code, 'code', 'edition_limit')
              .having((AgentException e) => e.status, 'status', 402),
        ),
      );
      // Nothing was half-stored by the refusal.
      expect(repo.servers.length, 2);
      expect(await store.deviceKey('edge-3'), isNull);
    });

    test('the third pairs when the edition has no limit', () async {
      final ServersRepository repo = ServersRepository(store: store);
      await pairOne(repo, 'edge-1');
      await pairOne(repo, 'edge-2');
      await pairOne(repo, 'edge-3');
      expect(repo.servers.length, 3);
      expect(repo.canPairAnother, isTrue);
    });

    test('a phone that arrives with three keeps all three usable', () async {
      for (int i = 1; i <= 3; i++) {
        await store.writeDeviceKey('edge-$i', 'dk_$i');
      }
      await store.save(<Server>[
        for (int i = 1; i <= 3; i++)
          Server(
            id: 'edge-$i',
            name: 'edge-$i',
            baseUrl: agent.baseUrl,
            certFingerprint: '',
            deviceId: 'dev-$i',
            role: ServerRole.admin,
          ),
      ]);

      final ServersRepository repo = ServersRepository(
        store: store,
        maxServers: 2,
      );
      await repo.ensureLoaded();
      // Over the limit, but nothing is deleted or hidden.
      expect(repo.servers.map((Server s) => s.id), <String>[
        'edge-1',
        'edge-2',
        'edge-3',
      ]);
      for (final Server server in repo.servers) {
        expect(repo.api(server.id), isNotNull);
        expect(await repo.api(server.id).health(), isTrue);
      }
      // It simply cannot add a fourth.
      expect(repo.canPairAnother, isFalse);
      await expectLater(
        pairOne(repo, 'edge-4'),
        throwsA(isA<AgentException>()),
      );
      expect(repo.servers.length, 3);
    });

    test('demo mode is not limited', () async {
      final ServersRepository repo = ServersRepository(
        worlds: <MockWorld>[seedProduction(), seedStaging(), seedOffline()],
        maxServers: 2,
      );
      expect(repo.isDemo, isTrue);
      expect(repo.servers.length, 3);
      expect(repo.canPairAnother, isTrue);

      await repo.pair(
        name: 'sample-4',
        agentUrl: 'https://sample:8443',
        token: 'pair-4821-9de2',
      );
      expect(repo.servers.length, 4);
    });
  });
}
