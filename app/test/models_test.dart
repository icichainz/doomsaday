import 'package:doomsaday/data/models.dart';
import 'package:doomsaday/features/alerts/alerts_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatters', () {
    test('bytes read the way the design writes them', () {
      expect(formatBytes(38 * 1024 * 1024), '38 MB');
      expect(formatBytes(412 * 1024 * 1024), '412 MB');
      expect(formatBytes((8.4 * 1024 * 1024 * 1024).round()), '8.4 GB');
      expect(formatBytes(31 * 1024 * 1024 * 1024), '31 GB');
      expect(formatBytes(900), '900 B');
      expect(formatBytes(0), '0 B');
    });

    test('percentages keep one decimal only below ten', () {
      expect(formatPercent(0.4), '0.4%');
      expect(formatPercent(18), '18%');
      expect(formatPercent(6), '6%');
      expect(formatPercent(90.4), '90%');
    });

    test('durations read as the rows do', () {
      expect(formatDuration(const Duration(days: 12)), '12 days');
      expect(formatDuration(const Duration(days: 1)), '1 day');
      expect(formatDuration(const Duration(hours: 2)), '2 h');
      expect(formatDuration(const Duration(minutes: 12)), '12 min');
      expect(formatDuration(const Duration(seconds: 20)), 'less than a minute');
      expect(formatUptime(const Duration(days: 12)), 'Up 12 days');
    });

    test('relative times roll up the way the boards write them', () {
      final DateTime now = DateTime(2026, 3, 12, 9, 42);
      // Minutes inside the hour, the clock for the rest of today, days up to
      // a fortnight, then weeks, months and years.
      const List<(Duration, String)> table = <(Duration, String)>[
        (Duration(seconds: 10), 'just now'),
        (Duration(minutes: 12), '12 min ago'),
        (Duration(minutes: 59), '59 min ago'),
        (Duration(hours: 2), 'today 07:42'),
        (Duration(hours: 5), 'today 04:42'),
        (Duration(days: 1), '1 day ago'),
        (Duration(days: 3), '3 days ago'),
        (Duration(days: 12), '12 days ago'),
        (Duration(days: 13), '13 days ago'),
        (Duration(days: 21), '3 weeks ago'),
        (Duration(days: 59), '8 weeks ago'),
        (Duration(days: 62), '2 months ago'),
        (Duration(days: 150), '5 months ago'),
        (Duration(days: 400), '1 year ago'),
        (Duration(days: 900), '2 years ago'),
      ];
      for (final (Duration ago, String expected) in table) {
        expect(
          formatRelative(now.subtract(ago), now: now),
          expected,
          reason: '$ago ago',
        );
      }
      expect(
        formatRelative(now.add(const Duration(days: 6)), now: now),
        'in 6 days',
      );
    });

    test('no screen ever prints a raw Go duration', () {
      expect(
        humanizeDurations('worker-queue restarted 4 times in 10m0s'),
        'worker-queue restarted 4 times in 10 min',
      );
      expect(humanizeDurations('gave up after 1h30m0s'), 'gave up after 2 h');
      expect(humanizeDurations('waited 90s'), 'waited 2 min');
      expect(humanizeDurations('nothing to rewrite'), 'nothing to rewrite');
    });

    test('a resolved time is a weekday and a clock, not an age', () {
      final DateTime now = DateTime(2026, 3, 12, 9, 42); // a Thursday
      expect(
        formatWeekdayTime(DateTime(2026, 3, 10, 14, 10), now: now),
        'Tue 14:10',
      );
      expect(
        formatWeekdayTime(DateTime(2026, 2, 3, 14, 10), now: now),
        '3 Feb 14:10',
      );
      expect(
        formatWeekdayTime(DateTime(2026, 3, 12, 8, 5), now: now),
        'today 08:05',
      );
    });

    test('a long-idle volume is named by its month', () {
      final DateTime now = DateTime(2026, 3, 12, 9, 42);
      expect(formatMonthName(DateTime(2026, 3, 1), now: now), 'March');
      expect(formatMonthName(DateTime(2025, 11, 1), now: now), 'November 2025');
    });

    test('byte sizes never keep a trailing .0', () {
      expect(formatBytes(2 * 1024 * 1024 * 1024), '2 GB');
      expect(formatBytes((1.5 * 1024 * 1024 * 1024).round()), '1.5 GB');
      expect(formatBytes(31 * 1024 * 1024 * 1024), '31 GB');
      expect(formatBytes(412 * 1024 * 1024), '412 MB');
      expect(formatGigabytes(16 * 1024 * 1024 * 1024), '16');
      expect(formatGigabytes(8 * 1024 * 1024 * 1024), '8');
    });

    test('the activity gutter switches unit with age', () {
      final DateTime now = DateTime(2026, 3, 12, 9, 42);
      expect(formatActivityTime(now, now: now), '09:42');
      expect(
        formatActivityTime(now.subtract(const Duration(days: 2)), now: now),
        'Tue',
      );
      expect(
        formatActivityTime(now.subtract(const Duration(days: 40)), now: now),
        '31 Jan',
      );
    });

    test('short durations suit a Retry-After', () {
      expect(formatShortDuration(const Duration(seconds: 31)), '31 s');
      expect(formatShortDuration(const Duration(minutes: 4)), '4 min');
    });

    test('counts carry thousands separators', () {
      expect(formatCount(1204), '1,204');
      expect(formatCount(42), '42');
    });
  });

  group('container rows are formatted from raw values', () {
    ContainerSummary row({
      required ContainerState state,
      String health = '',
      Duration uptime = Duration.zero,
      int exitCode = 0,
      double cpu = 0,
      int memory = 0,
      int restarts = 0,
      Duration? exitedAgo,
    }) => ContainerSummary(
      id: 'abc',
      name: 'api-gateway',
      image: 'nginx:1.27',
      state: state,
      health: health,
      createdAt: DateTime.now().subtract(const Duration(days: 40)),
      startedAt: DateTime.now().subtract(uptime),
      finishedAt: exitedAgo == null ? null : DateTime.now().subtract(exitedAgo),
      uptimeSeconds: uptime.inSeconds,
      restartCount: restarts,
      exitCode: exitCode,
      cpuPercent: cpu,
      memoryBytes: memory,
      stack: '',
    );

    test('a running row says how long it has been up', () {
      final ContainerSummary c = row(
        state: ContainerState.running,
        uptime: const Duration(days: 12),
        cpu: 0.4,
        memory: 38 * 1024 * 1024,
      );
      expect(c.stateLabel, 'Up 12 days');
      expect(c.meta, '0.4% · 38 MB');
    });

    test('a healthy row says so instead', () {
      expect(
        row(
          state: ContainerState.running,
          health: 'healthy',
          uptime: const Duration(days: 12),
        ).stateLabel,
        'Healthy',
      );
    });

    test('one rule writes the row label for every list and table', () {
      // The rows the boards draw, through the single formatter every screen
      // reads: the phone list, the desktop list pane, "Busiest containers"
      // and the fleet table all print this string and nothing else.
      const List<(String, ContainerState, String, Duration, String)> cases =
          <(String, ContainerState, String, Duration, String)>[
            (
              'healthy',
              ContainerState.running,
              'healthy',
              Duration(days: 3),
              'Healthy',
            ),
            (
              'starting',
              ContainerState.running,
              'starting',
              Duration(days: 3),
              'Up 3 days',
            ),
            (
              'unhealthy',
              ContainerState.running,
              'unhealthy',
              Duration(days: 3),
              'Up 3 days',
            ),
            (
              'no check',
              ContainerState.running,
              '',
              Duration(days: 12),
              'Up 12 days',
            ),
            (
              'restarting',
              ContainerState.restarting,
              '',
              Duration.zero,
              'Restarting',
            ),
            ('paused', ContainerState.paused, '', Duration.zero, 'Paused'),
          ];
      for (final (
            String name,
            ContainerState state,
            String health,
            Duration uptime,
            String label,
          )
          in cases) {
        expect(
          row(state: state, health: health, uptime: uptime).stateLabel,
          label,
          reason: name,
        );
      }
    });

    test('the pill carries the state and the health, never the uptime', () {
      const List<(ContainerState, String, int, String)> cases =
          <(ContainerState, String, int, String)>[
            (ContainerState.running, 'healthy', 0, 'Running · healthy'),
            (ContainerState.running, 'starting', 0, 'Running · starting'),
            (ContainerState.running, '', 0, 'Running'),
            (ContainerState.restarting, '', 0, 'Restarting'),
            (ContainerState.exited, '', 1, 'Exited (1)'),
          ];
      for (final (ContainerState state, String health, int code, String label)
          in cases) {
        expect(
          row(
            state: state,
            health: health,
            exitCode: code,
            uptime: const Duration(days: 3),
          ).pillLabel,
          label,
        );
      }
    });

    test('a restarting row counts the restarts', () {
      final ContainerSummary c = row(
        state: ContainerState.restarting,
        restarts: 4,
      );
      expect(c.stateLabel, 'Restarting');
      expect(c.meta, '4 restarts');
    });

    test('an exited row carries the code and when it stopped', () {
      final ContainerSummary c = row(
        state: ContainerState.exited,
        exitCode: 1,
        exitedAgo: const Duration(minutes: 12),
      );
      expect(c.stateLabel, 'Exited (1)');
      expect(c.meta, '12 min ago');
    });

    test('parses the agent JSON one for one', () {
      final ContainerSummary c = ContainerSummary.fromJson(<String, Object?>{
        'id': '4f2a9c1e7b3d',
        'name': 'api-gateway',
        'image': 'registry.example.com/api:2.8.1',
        'state': 'running',
        'health': 'healthy',
        'stack': 'web-platform',
        'service': 'api',
        'created_at': '2026-01-01T00:00:00Z',
        'started_at': '2026-01-02T00:00:00Z',
        'uptime_seconds': 259200,
        'restart_count': 2,
        'exit_code': 0,
        'cpu_percent': 18.0,
        'memory_usage': 431917056,
        'memory_limit': 4294967296,
        'memory_percent': 10.05,
        'ports': <Object?>[
          <String, Object?>{
            'private_port': 8080,
            'public_port': 8080,
            'type': 'tcp',
          },
        ],
      });
      expect(c.stack, 'web-platform');
      expect(c.uptime, const Duration(days: 3));
      expect(c.stateLabel, 'Healthy');
      expect(c.ports.single.label, '8080 → 8080/tcp');
    });
  });

  group('Revision 1.1 shapes', () {
    test('container counts split running from restarting', () {
      final SystemStats stats = SystemStats.fromJson(<String, Object?>{
        'cpu_percent': 34.0,
        'cpu_source': 'containers',
        'memory_used': 50,
        'memory_total': 100,
        'memory_source': 'host',
        'disk_used': 20,
        'disk_total': 100,
        'containers': <String, Object?>{
          'running': 13,
          'restarting': 1,
          'paused': 0,
          'exited': 2,
          'created': 0,
          'total': 16,
        },
      });
      expect(stats.containers.up, 14);
      expect(stats.containers.stopped, 2);
      expect(stats.total, 16);
      expect(stats.figuresAreApproximate, isTrue);
    });

    test('alert severity, state, target and target_id', () {
      final AlertInfo alert = AlertInfo.fromJson(<String, Object?>{
        'id': 'unexpected_exit|91f6c0b4d2a8',
        'rule_id': 'unexpected_exit',
        'severity': 'critical',
        'state': 'active',
        'target': 'postgres-backup',
        'target_id': '91f6c0b4d2a8',
        'message': 'postgres-backup exited with code 1',
        'first_seen': '2026-03-12T09:30:00Z',
        'last_seen': '2026-03-12T09:30:00Z',
        'count': 1,
      });
      expect(alert.severity, AlertSeverity.critical);
      expect(alert.state, AlertState.active);
      expect(alert.targetKind, 'container');
      expect(alert.title, 'postgres-backup exited');
      expect(alert.exitCode, 1);
      expect(alert.attentionTitle, 'postgres-backup');
      expect(alert.attentionDetail, startsWith('Exited with code 1 · '));

      final AlertInfo host = AlertInfo.fromJson(<String, Object?>{
        'id': 'cpu_high|host',
        'rule_id': 'cpu_high',
        'severity': 'warning',
        'state': 'resolved',
        'target': 'host',
        'message': 'host CPU above 90%',
        'first_seen': '2026-03-12T09:30:00Z',
        'last_seen': '2026-03-12T09:30:00Z',
      });
      expect(host.targetKind, 'host');
    });

    test('alert cards say what the boards say', () {
      final DateTime now = DateTime(2026, 3, 12, 9, 42);
      final AlertInfo exited = AlertInfo(
        id: 'unexpected_exit|91f',
        ruleId: AlertRuleId.unexpectedExit,
        severity: AlertSeverity.critical,
        state: AlertState.active,
        target: 'postgres-backup',
        targetId: '91f',
        message: 'postgres-backup exited with code 1',
        firstSeen: now.subtract(const Duration(minutes: 12)),
        lastSeen: now.subtract(const Duration(minutes: 12)),
        exitCode: 1,
        stack: 'backups',
      );
      expect(exited.title, 'postgres-backup exited');
      expect(exited.detail, contains('Exit code 1'));
      expect(exited.detail, endsWith('stack backups'));

      final AlertInfo loop = AlertInfo(
        id: 'restart_loop|7d1',
        ruleId: AlertRuleId.restartLoop,
        severity: AlertSeverity.warning,
        state: AlertState.active,
        target: 'worker-queue',
        targetId: '7d1',
        message: 'worker-queue restarted 4 times in 10m0s',
        firstSeen: now.subtract(const Duration(minutes: 22)),
        lastSeen: now.subtract(const Duration(minutes: 2)),
        count: 4,
        stack: 'web-platform',
        windowSeconds: 600,
      );
      expect(loop.title, 'worker-queue restart loop');
      expect(loop.detail, '4 restarts in 10 min · stack web-platform');
      expect(loop.attentionTitle, 'worker-queue');
      expect(loop.attentionDetail, 'Restarted 4 times in the last 10 min');

      // A resolved note must not repeat its own title.
      final AlertInfo resolved = AlertInfo(
        id: 'memory_high|host',
        ruleId: AlertRuleId.memoryHigh,
        severity: AlertSeverity.warning,
        state: AlertState.resolved,
        target: 'Disk above 80% on staging-1',
        message: 'Disk above 80% on staging-1',
        firstSeen: DateTime(2026, 3, 10, 14, 10),
        lastSeen: DateTime(2026, 3, 10, 14, 10),
        resolvedAt: DateTime(2026, 3, 10, 14, 10),
      );
      expect(resolved.note.split(' · ').length, 2);
      expect(resolved.note, startsWith('Disk above 80% on staging-1 · '));
      expect(resolved.note, contains('resolved '));
      expect('Disk above 80% on staging-1'.allMatches(resolved.note).length, 1);

      // Critical first, then warning, then most recent.
      final List<AlertInfo> ordered = <AlertInfo>[loop, exited]
        ..sort(compareAlertsByUrgency);
      expect(ordered.first.target, 'postgres-backup');
    });

    test('an exit code and a window are read out of an older message', () {
      final AlertInfo alert = AlertInfo.fromJson(<String, Object?>{
        'id': 'restart_loop|7d1',
        'rule_id': 'restart_loop',
        'severity': 'warning',
        'state': 'active',
        'target': 'worker-queue',
        'target_id': '7d1',
        'message': 'worker-queue restarted 4 times in 10m0s',
        'first_seen': '2026-03-12T09:20:00Z',
        'last_seen': '2026-03-12T09:40:00Z',
        'count': 4,
      });
      expect(alert.windowSeconds, 600);
      expect(alert.detail, startsWith('4 restarts in 10 min'));

      final AlertInfo exited = AlertInfo.fromJson(<String, Object?>{
        'id': 'unexpected_exit|91f',
        'rule_id': 'unexpected_exit',
        'severity': 'critical',
        'state': 'active',
        'target': 'postgres-backup',
        'target_id': '91f',
        'message': 'postgres-backup exited with code 137',
        'first_seen': '2026-03-12T09:30:00Z',
        'last_seen': '2026-03-12T09:30:00Z',
      });
      expect(exited.exitCode, 137);
    });

    test('the five rule ids collapse to the design rows', () {
      final List<AlertRule> rules = <AlertRule>[
        const AlertRule(
          id: AlertRuleId.unexpectedExit,
          name: 'exit',
          enabled: true,
          threshold: 0,
          windowSeconds: 0,
        ),
        const AlertRule(
          id: AlertRuleId.restartLoop,
          name: 'loop',
          enabled: true,
          threshold: 3,
          windowSeconds: 600,
        ),
        const AlertRule(
          id: AlertRuleId.cpuHigh,
          name: 'cpu',
          enabled: true,
          threshold: 90,
          windowSeconds: 300,
        ),
        const AlertRule(
          id: AlertRuleId.memoryHigh,
          name: 'memory',
          enabled: false,
          threshold: 90,
          windowSeconds: 300,
        ),
        const AlertRule(
          id: AlertRuleId.agentUnreachable,
          name: 'unreachable',
          enabled: false,
          threshold: 0,
          windowSeconds: 120,
          evaluatedLocally: false,
        ),
      ];
      final List<AlertRuleRow> rows = mergeAlertRules(rules);
      expect(rows, hasLength(4));
      expect(rows[0].label, 'Container exits unexpectedly');
      expect(rows[1].label, 'Restart loop, 3 or more in 10 min');
      expect(rows[2].label, 'CPU or memory above 90% for 5 min');
      // One row, two rule ids: the toggle patches both.
      expect(rows[2].ids, <String>[
        AlertRuleId.cpuHigh,
        AlertRuleId.memoryHigh,
      ]);
      expect(rows[2].enabled, isTrue);
      expect(rows[3].label, 'Agent unreachable for 2 min');
    });

    test(
      'registry status, status_at and token_expiry give the three looks',
      () {
        final RegistryInfo ok = RegistryInfo(
          id: 'r1',
          host: 'registry.example.com',
          username: 'deploy-bot',
          rawStatus: 'ok',
          statusAt: DateTime.now().subtract(const Duration(hours: 2)),
        );
        expect(ok.status, RegistryStatus.verified);
        expect(ok.statusLabel, startsWith('Verified '));
        expect(ok.subtitle, 'Signed in as deploy-bot');

        final RegistryInfo expiring = RegistryInfo(
          id: 'r2',
          host: 'ghcr.io',
          username: 'ci',
          rawStatus: 'ok',
          statusAt: DateTime.now(),
          tokenExpiry: DateTime.now().add(const Duration(days: 6)),
        );
        expect(expiring.status, RegistryStatus.expiring);
        expect(expiring.statusLabel, 'Token expires in 6 days');

        const RegistryInfo anonymous = RegistryInfo(
          id: 'r3',
          host: 'docker.io',
          username: '',
          rawStatus: 'unknown',
        );
        expect(anonymous.status, RegistryStatus.anonymous);
        expect(anonymous.statusLabel, 'No login');

        final RegistryInfo failed = RegistryInfo(
          id: 'r4',
          host: 'private.example.com',
          username: 'ci',
          rawStatus: 'failed',
          statusAt: DateTime.now(),
        );
        expect(failed.status, RegistryStatus.failed);
      },
    );

    test('a stack with per-service counts draws one segment per service', () {
      final ComposeStack stack = ComposeStack.fromJson(<String, Object?>{
        'name': 'web-platform',
        'source': 'directory',
        'working_dir': '/opt/stacks/web-platform',
        'config_on_disk': true,
        'services_running': 2,
        'services_total': 3,
        'services': <Object?>[
          <String, Object?>{'name': 'api', 'running': 1, 'total': 1},
          <String, Object?>{'name': 'worker', 'running': 0, 'total': 2},
          <String, Object?>{'name': 'db', 'running': 1, 'total': 1},
        ],
      });
      expect(stack.serviceStates, <ContainerState>[
        ContainerState.running,
        ContainerState.exited,
        ContainerState.running,
      ]);
      expect(stack.path, '/opt/stacks/web-platform');
    });

    test('a stack list row without services falls back to the counts', () {
      final ComposeStack stack = ComposeStack.fromJson(<String, Object?>{
        'name': 'labels-only',
        'source': 'labels',
        'config_on_disk': false,
        'services_running': 1,
        'services_total': 3,
      });
      expect(stack.serviceStates, <ContainerState>[
        ContainerState.running,
        ContainerState.exited,
        ContainerState.exited,
      ]);
      expect(stack.path, 'discovered from container labels');
      expect(stack.configOnDisk, isFalse);
    });

    test('a down stack names the container that stopped it', () {
      ContainerSummary member(
        String name, {
        ContainerState state = ContainerState.exited,
        int exitCode = 1,
        Duration? exitedAgo = const Duration(minutes: 12),
        String service = '',
      }) => ContainerSummary(
        id: name,
        name: name,
        image: 'registry.example.com/$name:1.3',
        state: state,
        health: '',
        createdAt: DateTime.now().subtract(const Duration(days: 40)),
        finishedAt: exitedAgo == null
            ? null
            : DateTime.now().subtract(exitedAgo),
        uptimeSeconds: 0,
        restartCount: 0,
        exitCode: exitCode,
        cpuPercent: 0,
        memoryBytes: 0,
        stack: 'backups',
        service: service.isEmpty ? name : service,
      );

      const ComposeStack backups = ComposeStack(
        name: 'backups',
        workingDir: '/opt/stacks/backups',
        servicesUp: 0,
        servicesTotal: 1,
        source: 'directory',
        configOnDisk: true,
        services: <StackService>[
          StackService(name: 'postgres-backup', running: 0, total: 1),
        ],
      );

      final List<(String, ComposeStack, List<ContainerSummary>, String?)>
      cases = <(String, ComposeStack, List<ContainerSummary>, String?)>[
        (
          'the board sentence, from the container itself',
          backups,
          <ContainerSummary>[member('postgres-backup')],
          'postgres-backup exited with code 1, 12 min ago.',
        ),
        (
          'a container that never finished loses the clause',
          backups,
          <ContainerSummary>[member('postgres-backup', exitedAgo: null)],
          'postgres-backup is not running.',
        ),
        (
          'a member that is not reaped at all loses it too',
          backups,
          <ContainerSummary>[
            member('postgres-backup', state: ContainerState.created),
          ],
          'postgres-backup is not running.',
        ),
        (
          'exit code zero is a code like any other',
          backups,
          <ContainerSummary>[member('postgres-backup', exitCode: 0)],
          'postgres-backup exited with code 0, 12 min ago.',
        ),
        (
          'containers of another service are not this stack\'s business',
          backups,
          <ContainerSummary>[
            member('postgres-backup'),
            member('legacy-import', exitedAgo: const Duration(days: 3)),
          ],
          'postgres-backup exited with code 1, 12 min ago.',
        ),
        (
          'no containers to hand: the service names still answer',
          backups,
          const <ContainerSummary>[],
          'postgres-backup is not running.',
        ),
        (
          'a running stack has no line at all',
          ComposeStack(
            name: 'backups',
            workingDir: '/opt/stacks/backups',
            servicesUp: 1,
            servicesTotal: 1,
            source: 'directory',
            configOnDisk: true,
            services: const <StackService>[
              StackService(name: 'postgres-backup', running: 1, total: 1),
            ],
          ),
          <ContainerSummary>[member('postgres-backup')],
          null,
        ),
        (
          'without a compose file the line says so instead',
          ComposeStack(
            name: 'backups',
            workingDir: '',
            servicesUp: 0,
            servicesTotal: 1,
            source: 'labels',
            configOnDisk: false,
            services: const <StackService>[
              StackService(name: 'postgres-backup', running: 0, total: 1),
            ],
          ),
          <ContainerSummary>[member('postgres-backup')],
          'No compose file was found for this stack, so it cannot be driven '
              'from here.',
        ),
      ];

      for (final (
            String name,
            ComposeStack stack,
            List<ContainerSummary> containers,
            String? line,
          )
          in cases) {
        expect(stack.noteFor(containers), line, reason: name);
      }
    });

    test('several down containers are counted, not listed', () {
      ContainerSummary member(String name) => ContainerSummary(
        id: name,
        name: name,
        image: 'x',
        state: ContainerState.exited,
        health: '',
        createdAt: DateTime.now(),
        finishedAt: DateTime.now().subtract(const Duration(minutes: 12)),
        uptimeSeconds: 0,
        restartCount: 0,
        exitCode: 1,
        cpuPercent: 0,
        memoryBytes: 0,
        stack: 'backups',
        service: name,
      );
      const ComposeStack stack = ComposeStack(
        name: 'backups',
        workingDir: '/opt/stacks/backups',
        servicesUp: 0,
        servicesTotal: 3,
        source: 'directory',
        configOnDisk: true,
        services: <StackService>[
          StackService(name: 'dump', running: 0, total: 1),
          StackService(name: 'ship', running: 0, total: 1),
          StackService(name: 'verify', running: 0, total: 1),
        ],
      );
      expect(
        stack.noteFor(<ContainerSummary>[
          member('dump'),
          member('ship'),
          member('verify'),
        ]),
        'dump exited with code 1, 12 min ago, and 2 more.',
      );
      // The same rule with nothing to say about the first one.
      expect(
        stackDownSentence(
          ContainerSummary(
            id: 'dump',
            name: 'dump',
            image: 'x',
            state: ContainerState.created,
            health: '',
            createdAt: DateTime.now(),
            uptimeSeconds: 0,
            restartCount: 0,
            exitCode: 0,
            cpuPercent: 0,
            memoryBytes: 0,
            stack: 'backups',
          ),
          others: 1,
        ),
        'dump is not running, and 1 more.',
      );
    });

    test('volumes carry an optional last_used', () {
      final VolumeInfo mounted = VolumeInfo.fromJson(<String, Object?>{
        'name': 'pgdata',
        'driver': 'local',
        'size': 1024,
        'mounted_by': <String>['db'],
        'last_used': '2026-03-12T09:00:00Z',
      });
      expect(mounted.lastUsedLabel, 'in use');

      final VolumeInfo never = VolumeInfo.fromJson(<String, Object?>{
        'name': 'orphan',
        'driver': 'local',
        'size': 0,
        'mounted_by': <String>[],
      });
      expect(never.lastUsed, isNull);
      expect(never.lastUsedLabel, 'never used');

      final VolumeInfo stale = VolumeInfo(
        name: 'old_uploads',
        driver: 'local',
        sizeBytes: 0,
        mountedBy: const <String>[],
        lastUsed: DateTime.now().subtract(const Duration(days: 190)),
      );
      expect(stale.lastUsedLabel, startsWith('last used in '));
      expect(stale.lastUsedLabel, isNot(contains('days ago')));
    });

    test('a job title and progress come out of type, target and lines', () {
      final Job job = Job.fromJson(<String, Object?>{
        'id': 'job-1',
        'type': 'image_pull',
        'target': 'nginx:1.27',
        'status': 'running',
        'progress': <Object?>[
          <String, Object?>{'text': 'resolving', 'percent': -1},
          <String, Object?>{'text': 'downloading', 'percent': 55},
        ],
      });
      expect(job.title, 'Pulling nginx:1.27');
      expect(job.progress, closeTo(0.55, 0.001));
      expect(job.lines, <String>['resolving', 'downloading']);
      expect(job.status.isFinished, isFalse);
    });

    test('log levels are read off the stream and the text', () {
      LogLine line(String stream, String text) =>
          LogLine(at: DateTime.now(), stream: stream, line: text);
      expect(line('stdout', 'GET /healthz 200').level, LogLevel.info);
      expect(line('stderr', 'upstream slow: 2140ms').level, LogLevel.warn);
      expect(
        line('stderr', 'dial tcp worker-queue:7000: connection refused').level,
        LogLevel.error,
      );
    });

    test('an activity record becomes a sentence', () {
      final ActivityEntry entry = ActivityEntry.fromJson(<String, Object?>{
        'id': 'a1',
        'time': '2026-03-12T09:42:00Z',
        'device_id': 'dev-1',
        'device_name': 'This phone',
        'role': 'admin',
        'action': 'POST /v1/containers/{id}/stop',
        'target': 'nginx-proxy',
        'result': 'ok',
        'status': 200,
      });
      expect(entry.text, 'nginx-proxy stopped from This phone');
      expect(
        entry.sentence(selfDeviceId: 'dev-1', selfLabel: 'this Mac'),
        'nginx-proxy restarted from this Mac'.replaceFirst(
          'restarted',
          'stopped',
        ),
      );
      expect(
        entry.sentence(selfDeviceId: 'dev-9', selfLabel: 'this Mac'),
        'nginx-proxy stopped from This phone',
      );
      expect(entry.failed, isFalse);

      final ActivityEntry denied = ActivityEntry.fromJson(<String, Object?>{
        'id': 'a2',
        'time': '2026-03-12T09:42:00Z',
        'device_name': 'On-call pixel',
        'action': 'DELETE /v1/containers/{id}',
        'target': 'api-gateway',
        'result': 'denied',
        'status': 403,
      });
      expect(
        denied.text,
        'Container api-gateway removed from On-call pixel · denied',
      );
      expect(denied.failed, isTrue);
    });

    test('a Go zero timestamp is treated as absent', () {
      final ContainerSummary c = ContainerSummary.fromJson(<String, Object?>{
        'id': 'x',
        'name': 'x',
        'image': 'x',
        'state': 'exited',
        'created_at': '2026-01-01T00:00:00Z',
        'started_at': '0001-01-01T00:00:00Z',
      });
      expect(c.startedAt, isNull);
    });
  });

  group('the role map from Revision 1.1', () {
    test('a viewer may read and nothing else', () {
      const ServerRole role = ServerRole.viewer;
      expect(role.canOperate, isFalse);
      expect(role.canRemove, isFalse);
      expect(role.canPrune, isFalse);
      expect(role.canExec, isFalse);
      expect(role.canReadEnvironment, isFalse);
      expect(role.canManageDevices, isFalse);
    });

    test('an operator may start, stop and redeploy but not destroy', () {
      const ServerRole role = ServerRole.operator;
      expect(role.canOperate, isTrue);
      expect(role.canRemove, isFalse);
      expect(role.canPrune, isFalse);
      expect(role.canStackDown, isFalse);
      expect(role.canExec, isFalse);
      expect(role.canReadEnvironment, isFalse);
      expect(role.canEditAlertRules, isFalse);
      expect(role.canManageRegistries, isFalse);
    });

    test('an admin may do everything', () {
      const ServerRole role = ServerRole.admin;
      expect(role.canOperate, isTrue);
      expect(role.canRemove, isTrue);
      expect(role.canPrune, isTrue);
      expect(role.canExec, isTrue);
      expect(role.canStackDown, isTrue);
      expect(role.canManageDevices, isTrue);
      expect(role.canEditSettings, isTrue);
      expect(role.canUpdateAgent, isTrue);
    });

    test('an unknown role from the agent is treated as a viewer', () {
      expect(ServerRole.parse('root'), ServerRole.viewer);
      expect(ServerRole.parse('admin'), ServerRole.admin);
    });
  });
}
