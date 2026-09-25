import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:doomsaday/data/http_agent_api.dart';
import 'package:doomsaday/data/models.dart';
import 'package:doomsaday/data/pinning.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_agent.dart';

/// The SHA-256 of the DER inside a PEM file, in `AA:BB:…` form.
String fingerprintOfPem(String path) {
  final String pem = File(path).readAsStringSync();
  final String body = pem
      .replaceAll('-----BEGIN CERTIFICATE-----', '')
      .replaceAll('-----END CERTIFICATE-----', '')
      .replaceAll(RegExp(r'\s'), '');
  final List<int> der = base64.decode(body);
  return sha256
      .convert(der)
      .bytes
      .map((int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');
}

void main() {
  const String certPath = 'test/fixtures/agent_cert.pem';
  const String keyPath = 'test/fixtures/agent_key.pem';
  const String otherCertPath = 'test/fixtures/other_cert.pem';

  group('certificate pinning', () {
    late FakeAgent agent;
    late String pinned;

    setUp(() async {
      agent = (await FakeAgent.start(
        tls: FakeAgent.contextFor(certPath, keyPath),
      )).asTls();
      agent.json('GET /v1/system', <String, Object?>{
        'hostname': 'pinned-host',
        'docker_version': '27.1',
        'agent_version': '1.4.2',
        'cpu_cores': 4,
        'memory_total': 100,
        'disk_total': 200,
        'disk_used': 50,
        'swarm_role': 'inactive',
        'agent_uptime_seconds': 10,
        'host_uptime_seconds': 20,
      });
      pinned = fingerprintOfPem(certPath);
    });

    tearDown(() => agent.close());

    test('accepts the certificate whose fingerprint was pinned', () async {
      final HttpAgentApi api = HttpAgentApi(
        baseUrl: agent.baseUrl,
        deviceKey: 'dk',
        pinnedFingerprint: pinned,
      );
      addTearDown(api.dispose);
      expect((await api.system()).hostname, 'pinned-host');
    });

    test('is not case or separator sensitive about the pin', () async {
      final HttpAgentApi api = HttpAgentApi(
        baseUrl: agent.baseUrl,
        deviceKey: 'dk',
        pinnedFingerprint: pinned.toLowerCase().replaceAll(':', ' '),
      );
      addTearDown(api.dispose);
      expect((await api.system()).hostname, 'pinned-host');
    });

    test('refuses a certificate that does not match the pin', () async {
      final HttpAgentApi api = HttpAgentApi(
        baseUrl: agent.baseUrl,
        deviceKey: 'dk',
        pinnedFingerprint: fingerprintOfPem(otherCertPath),
      );
      addTearDown(api.dispose);
      await expectLater(
        api.system(),
        throwsA(
          isA<AgentException>().having(
            (AgentException e) => e.code,
            'code',
            'certificate_mismatch',
          ),
        ),
      );
    });

    test('refuses an empty pin rather than trusting anything', () async {
      final HttpAgentApi api = HttpAgentApi(
        baseUrl: agent.baseUrl,
        deviceKey: 'dk',
        pinnedFingerprint: '',
      );
      addTearDown(api.dispose);
      await expectLater(api.system(), throwsA(isA<AgentException>()));
    });

    test(
      '/health is false rather than throwing when the pin is wrong',
      () async {
        agent.json('GET /v1/health', <String, Object?>{'ok': true});
        final HttpAgentApi api = HttpAgentApi(
          baseUrl: agent.baseUrl,
          deviceKey: 'dk',
          pinnedFingerprint: fingerprintOfPem(otherCertPath),
        );
        addTearDown(api.dispose);
        expect(await api.health(), isFalse);
      },
    );
  });

  group('transport rules', () {
    test('a plain http base URL is allowed in a debug build only', () {
      // Tests run with asserts on, which is what the guard calls debug.
      expect(
        () => HttpAgentApi(
          baseUrl: 'http://127.0.0.1:9',
          deviceKey: 'dk',
          pinnedFingerprint: 'AA',
        ).dispose(),
        returnsNormally,
      );
      expect(
        () => HttpAgentApi(
          baseUrl: 'ftp://127.0.0.1:9',
          deviceKey: 'dk',
          pinnedFingerprint: 'AA',
        ),
        throwsA(
          isA<AgentException>().having(
            (AgentException e) => e.code,
            'code',
            'insecure_transport',
          ),
        ),
      );
    });

    test('the base URL may be given with or without /v1', () {
      for (final String url in <String>[
        'https://host:8443',
        'https://host:8443/',
        'https://host:8443/v1',
      ]) {
        final HttpAgentApi api = HttpAgentApi(
          baseUrl: url,
          deviceKey: 'dk',
          pinnedFingerprint: 'AA',
        );
        expect(api.base.toString(), 'https://host:8443/v1');
        api.dispose();
      }
    });
  });

  group('over plain HTTP', () {
    late FakeAgent agent;
    late HttpAgentApi api;

    setUp(() async {
      agent = await FakeAgent.start();
      api = HttpAgentApi(
        baseUrl: agent.baseUrl,
        deviceKey: 'dk-secret',
        pinnedFingerprint: 'unused-on-http',
      );
    });

    tearDown(() async {
      api.dispose();
      await agent.close();
    });

    test('sends the bearer device key on every call', () async {
      String? seen;
      agent.on('GET /v1/settings', (HttpRequest request) {
        seen = request.headers.value(HttpHeaders.authorizationHeader);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{
            'require_biometric_for_risky': true,
            'stacks_dir': '/opt/stacks',
            'push_relay_status': 'not_configured',
          }),
        );
      });
      final AgentSettings settings = await api.settings();
      expect(seen, 'Bearer dk-secret');
      expect(settings.requireBiometricForRisky, isTrue);
      expect(settings.stacksDirectory, '/opt/stacks');
    });

    test('maps the error envelope onto AgentException', () async {
      agent.json(
        'GET /v1/containers/abc',
        errorBody(
          'container_not_found',
          'container not found',
          <String, Object?>{'id': 'abc'},
        ),
        status: 404,
      );
      await expectLater(
        api.container('abc'),
        throwsA(
          isA<AgentException>()
              .having(
                (AgentException e) => e.code,
                'code',
                'container_not_found',
              )
              .having((AgentException e) => e.status, 'status', 404)
              .having(
                (AgentException e) => e.message,
                'message',
                'container not found',
              )
              .having(
                (AgentException e) => e.details?['id'],
                'details.id',
                'abc',
              ),
        ),
      );
    });

    test('surfaces 429 with its Retry-After', () async {
      agent.on('GET /v1/system', (HttpRequest request) {
        request.response.statusCode = 429;
        request.response.headers.set(HttpHeaders.retryAfterHeader, '31');
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(errorBody('rate_limited', 'too many attempts')),
        );
      });
      await expectLater(
        api.system(),
        throwsA(
          isA<AgentException>()
              .having((AgentException e) => e.code, 'code', 'rate_limited')
              .having(
                (AgentException e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 31),
              )
              .having(
                (AgentException e) => e.toString(),
                'toString',
                'too many attempts Try again in 31 s.',
              ),
        ),
      );
    });

    test('a body that is not JSON still becomes an AgentException', () async {
      agent.on('GET /v1/system', (HttpRequest request) {
        request.response.statusCode = 502;
        request.response.write('<html>bad gateway</html>');
      });
      await expectLater(
        api.system(),
        throwsA(
          isA<AgentException>()
              .having((AgentException e) => e.status, 'status', 502)
              .having(
                (AgentException e) => e.isUnreachable,
                'unreachable',
                true,
              ),
        ),
      );
    });

    test('follows next_cursor until the last page', () async {
      Map<String, Object?> row(String id) => <String, Object?>{
        'id': id,
        'name': 'c-$id',
        'image': 'nginx:1.27',
        'state': 'running',
        'created_at': '2026-01-01T00:00:00Z',
        'uptime_seconds': 60,
        'restart_count': 0,
        'exit_code': 0,
        'cpu_percent': 1.0,
        'memory_usage': 1024,
        'ports': <Object?>[],
      };
      agent.on('GET /v1/containers', (HttpRequest request) {
        final String cursor = request.uri.queryParameters['cursor'] ?? '';
        request.response.headers.contentType = ContentType.json;
        switch (cursor) {
          case '':
            request.response.write(
              jsonEncode(<String, Object?>{
                'items': <Object?>[row('a'), row('b')],
                'next_cursor': 'bzoy',
                'total': 5,
              }),
            );
          case 'bzoy':
            request.response.write(
              jsonEncode(<String, Object?>{
                'items': <Object?>[row('c'), row('d')],
                'next_cursor': 'bzo0',
                'total': 5,
              }),
            );
          default:
            request.response.write(
              jsonEncode(<String, Object?>{
                'items': <Object?>[row('e')],
                'total': 5,
              }),
            );
        }
      });

      final List<ContainerSummary> rows = await api.containers();
      expect(rows.map((ContainerSummary c) => c.id), <String>[
        'a',
        'b',
        'c',
        'd',
        'e',
      ]);
      expect(
        agent.requests.where((String r) => r.contains('cursor=')).length,
        2,
      );
    });

    test(
      'an optional summary is used, and derived when it is absent',
      () async {
        Map<String, Object?> volume(String name, List<String> mounted) =>
            <String, Object?>{
              'name': name,
              'driver': 'local',
              'size': 1024,
              'created_at': '2026-01-01T00:00:00Z',
              'mounted_by': mounted,
            };

        agent.json('GET /v1/volumes', <String, Object?>{
          'items': <Object?>[
            volume('a', <String>['api']),
            volume('b', <String>[]),
          ],
          'total': 2,
        });
        final VolumeList derived = await api.volumes();
        expect(derived.count, 2);
        expect(derived.totalBytes, 2048);
        expect(derived.unmounted, 1);

        agent.json('GET /v1/volumes', <String, Object?>{
          'items': <Object?>[volume('a', <String>[])],
          'total': 9,
          'summary': <String, Object?>{
            'count': 9,
            'total_bytes': 99,
            'unmounted': 3,
          },
        });
        final VolumeList reported = await api.volumes();
        expect(reported.count, 9);
        expect(reported.totalBytes, 99);
        expect(reported.unmounted, 3);
      },
    );

    test('GET /me answering 404 degrades to null', () async {
      expect(await api.me(), isNull);

      agent.json('GET /v1/me', <String, Object?>{
        'device_id': 'dev-9',
        'device_name': 'This phone',
        'role': 'operator',
        'cert_fingerprint': 'AA:BB',
        'paired_devices': 3,
        'agent_version': '1.4.2',
      });
      final MeInfo? me = await api.me();
      expect(me!.role, ServerRole.operator);
      expect(me.pairedDevices, 3);
    });

    test('GET /swarm with active false is data, not an error', () async {
      agent.json('GET /v1/swarm', <String, Object?>{
        'active': false,
        'node_role': 'inactive',
        'is_manager': false,
        'nodes': <Object?>[],
      });
      final SwarmInfo swarm = await api.swarm();
      expect(swarm.active, isFalse);
      expect(swarm.nodeCount, 0);
    });
  });

  group('the 428 confirmation flow', () {
    late FakeAgent agent;

    setUp(() async {
      agent = await FakeAgent.start();
      agent.on('POST /v1/containers/abc/stop', (HttpRequest request) {
        final bool confirmed =
            request.headers.value('X-Confirmed')?.toLowerCase() == 'biometric';
        if (!confirmed) {
          request.response.statusCode = 428;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(
              errorBody(
                'confirmation_required',
                'this action needs a biometric confirmation',
              ),
            ),
          );
          return;
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(<String, Object?>{'ok': true}));
      });
    });

    tearDown(() => agent.close());

    test('a confirmed prompt retries once with the header', () async {
      int prompts = 0;
      final HttpAgentApi api = HttpAgentApi(
        baseUrl: agent.baseUrl,
        deviceKey: 'dk',
        pinnedFingerprint: 'x',
        onConfirmationRequired: () async {
          prompts++;
          return Confirmed.biometric;
        },
      );
      addTearDown(api.dispose);

      await api.stopContainer('abc');
      expect(prompts, 1);
      expect(agent.confirmations, <String?>[null, 'biometric']);
    });

    test('a cancelled prompt sends nothing more and keeps the 428', () async {
      int prompts = 0;
      final HttpAgentApi api = HttpAgentApi(
        baseUrl: agent.baseUrl,
        deviceKey: 'dk',
        pinnedFingerprint: 'x',
        onConfirmationRequired: () async {
          prompts++;
          return Confirmed.none;
        },
      );
      addTearDown(api.dispose);

      await expectLater(
        api.stopContainer('abc'),
        throwsA(
          isA<AgentException>().having(
            (AgentException e) => e.needsConfirmation,
            'needsConfirmation',
            true,
          ),
        ),
      );
      expect(prompts, 1);
      expect(agent.confirmations, <String?>[null]);
    });

    test('a call already confirmed in the sheet never prompts again', () async {
      int prompts = 0;
      final HttpAgentApi api = HttpAgentApi(
        baseUrl: agent.baseUrl,
        deviceKey: 'dk',
        pinnedFingerprint: 'x',
        onConfirmationRequired: () async {
          prompts++;
          return Confirmed.biometric;
        },
      );
      addTearDown(api.dispose);

      await api.stopContainer('abc', confirmed: Confirmed.biometric);
      expect(prompts, 0);
      expect(agent.confirmations, <String?>['biometric']);
    });
  });

  group('streams and jobs', () {
    late FakeAgent agent;
    late HttpAgentApi api;

    setUp(() async {
      agent = await FakeAgent.start();
      api = HttpAgentApi(
        baseUrl: agent.baseUrl,
        deviceKey: 'dk',
        pinnedFingerprint: 'x',
      );
    });

    tearDown(() async {
      api.dispose();
      await agent.close();
    });

    test('reads a log stream and stops when the listener goes away', () async {
      agent.on('GET /v1/containers/abc/logs/stream', (
        HttpRequest request,
      ) async {
        await sseHead(request.response);
        // A comment frame is a keep-alive and must not become an event.
        request.response.write(': keep-alive\n\n');
        for (int i = 0; i < 400; i++) {
          sseFrame(request.response, 'log', <String, Object?>{
            'ts': '2026-01-01T09:41:5${i % 10}Z',
            'stream': i.isEven ? 'stdout' : 'stderr',
            'line': 'line $i',
          });
          try {
            await request.response.flush();
          } catch (_) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });

      final List<LogLine> seen = <LogLine>[];
      final StreamSubscription<LogLine> subscription = api
          .logStream('abc')
          .listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await subscription.cancel();
      final int afterCancel = seen.length;

      expect(seen, isNotEmpty);
      expect(seen.first.line, 'line 0');
      expect(seen.first.level, LogLevel.info);
      expect(seen[1].level, LogLevel.warn);

      // Nothing else arrives once the listener is gone.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(seen.length, afterCancel);
    });

    test('follows a job through its event stream', () async {
      Map<String, Object?> job(String status, List<String> lines) =>
          <String, Object?>{
            'id': 'job-1',
            'type': 'image_pull',
            'target': 'nginx:1.27',
            'status': status,
            'created_at': '2026-01-01T00:00:00Z',
            'progress': <Object?>[
              for (final String line in lines)
                <String, Object?>{
                  'ts': '2026-01-01T00:00:00Z',
                  'text': line,
                  'percent': -1,
                },
            ],
          };

      agent.on('POST /v1/images/pull', (HttpRequest request) {
        request.response.statusCode = 202;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{
            'job_id': 'job-1',
            'job': job('queued', <String>[]),
          }),
        );
      });
      agent.on('GET /v1/jobs/job-1/events', (HttpRequest request) async {
        await sseHead(request.response);
        sseFrame(request.response, 'status', job('running', <String>[]));
        sseFrame(request.response, 'progress', <String, Object?>{
          'ts': '2026-01-01T00:00:01Z',
          'text': 'pulling nginx:1.27',
          'percent': 40,
        });
        sseFrame(
          request.response,
          'done',
          job('succeeded', <String>['pulling nginx:1.27', 'done']),
        );
        await request.response.flush();
      });

      final Job started = await api.pullImage('nginx:1.27');
      expect(started.id, 'job-1');
      expect(started.title, 'Pulling nginx:1.27');

      final List<Job> updates = await api.jobEvents('job-1').toList();
      expect(updates.first.status, JobStatus.running);
      expect(updates[1].lines, contains('pulling nginx:1.27'));
      expect(updates[1].progress, closeTo(0.4, 0.001));
      expect(updates.last.status, JobStatus.succeeded);
      expect(updates.last.progress, 1);
    });

    test('falls back to polling when the event stream is gone', () async {
      int polls = 0;
      agent.on('GET /v1/jobs/job-2', (HttpRequest request) {
        polls++;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{
            'id': 'job-2',
            'type': 'volume_prune',
            'status': polls >= 2 ? 'succeeded' : 'running',
            'created_at': '2026-01-01T00:00:00Z',
            'progress': <Object?>[],
          }),
        );
      });
      // No handler for /v1/jobs/job-2/events, so it answers 404.
      final List<Job> updates = await api.jobEvents('job-2').toList();
      expect(polls, greaterThanOrEqualTo(2));
      expect(updates.last.status, JobStatus.succeeded);
    });

    test(
      'a system stats stream yields the first sample from the plain GET',
      () async {
        Map<String, Object?> stats(double cpu) => <String, Object?>{
          'ts': '2026-01-01T00:00:00Z',
          'cpu_percent': cpu,
          'cpu_source': 'host',
          'memory_used': 50,
          'memory_total': 100,
          'memory_source': 'host',
          'disk_used': 10,
          'disk_total': 100,
          'containers': <String, Object?>{
            'running': 3,
            'restarting': 1,
            'exited': 2,
            'total': 6,
          },
        };
        agent.json('GET /v1/system/stats', stats(11));
        agent.on('GET /v1/system/stats/stream', (HttpRequest request) async {
          await sseHead(request.response);
          sseFrame(request.response, 'stats', stats(22));
          await request.response.flush();
          await Future<void>.delayed(const Duration(seconds: 5));
        });

        final List<SystemStats> seen = <SystemStats>[];
        final StreamSubscription<SystemStats> subscription = api
            // No throttle here: this is about the wiring, and the throttle
            // has a test of its own below.
            .systemStatsStream(interval: Duration.zero)
            .listen(seen.add);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await subscription.cancel();

        expect(seen.map((SystemStats s) => s.cpuPercent), <double>[11, 22]);
        expect(seen.first.containers.up, 4);
        expect(seen.first.containers.stopped, 2);
      },
    );

    test(
      '"Refresh stats every" throttles what a stats stream forwards',
      () async {
        // Six samples inside one window: the first goes straight through so
        // the screen is never left waiting, the rest are dropped.
        final List<int> seen = await HttpAgentApi.throttle(
          Stream<int>.fromIterable(<int>[1, 2, 3, 4, 5, 6]),
          const Duration(seconds: 30),
        ).toList();
        expect(seen, <int>[1]);
      },
    );

    test('a zero interval forwards everything', () async {
      final List<int> seen = await HttpAgentApi.throttle(
        Stream<int>.fromIterable(<int>[1, 2, 3]),
        Duration.zero,
      ).toList();
      expect(seen, <int>[1, 2, 3]);
    });
  });

  group('pairing', () {
    test('POST /v1/pair returns the 201 body', () async {
      final FakeAgent agent = await FakeAgent.start();
      addTearDown(agent.close);
      Object? body;
      agent.on('POST /v1/pair', (HttpRequest request) async {
        body = jsonDecode(await utf8.decodeStream(request));
        request.response.statusCode = 201;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode(<String, Object?>{
            'device_key': 'dk_live',
            'device_id': 'dev-1',
            'role': 'admin',
            'cert_fingerprint': 'AA:BB:CC',
            'agent_version': '1.4.2',
          }),
        );
      });

      final HttpClient client = HttpClient();
      addTearDown(() => client.close(force: true));
      final Map<String, Object?> answer = await HttpAgentApi.pair(
        client: client,
        baseUrl: Uri.parse(agent.baseUrl),
        token: 'pair-0001',
        deviceName: 'This phone',
      );
      expect(answer['device_key'], 'dk_live');
      expect(answer['role'], 'admin');
      expect(body, <String, Object?>{
        'token': 'pair-0001',
        'device_name': 'This phone',
      });
    });

    test('a rejected token becomes pairing_failed', () async {
      final FakeAgent agent = await FakeAgent.start();
      addTearDown(agent.close);
      agent.json(
        'POST /v1/pair',
        errorBody('pairing_failed', 'the pairing token is not valid'),
        status: 401,
      );

      final HttpClient client = HttpClient();
      addTearDown(() => client.close(force: true));
      await expectLater(
        HttpAgentApi.pair(
          client: client,
          baseUrl: Uri.parse(agent.baseUrl),
          token: 'nope',
          deviceName: 'This phone',
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

  group('fingerprint helpers', () {
    test('match ignores case, colons and spaces', () {
      expect(fingerprintsMatch('AA:BB:CC', 'aa bb cc'), isTrue);
      expect(fingerprintsMatch('AA:BB:CC', 'AA:BB:CD'), isFalse);
    });

    test('a complete SHA-256 fingerprint is 32 bytes', () {
      expect(isCompleteFingerprint(fingerprintOfPem(certPath)), isTrue);
      expect(isCompleteFingerprint('AA:BB'), isFalse);
    });
  });
}
