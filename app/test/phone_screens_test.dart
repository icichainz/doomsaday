import 'package:doomsaday/data/models.dart';
import 'package:doomsaday/features/activity/activity_screen.dart';
import 'package:doomsaday/features/container_detail/container_config_sheet.dart';
import 'package:doomsaday/features/devices/devices_screen.dart';
import 'package:doomsaday/features/exec/exec_screen.dart';
import 'package:doomsaday/features/pair/pair_agent_screen.dart';
import 'package:doomsaday/widgets/buttons.dart';
import 'package:doomsaday/widgets/primitives.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';

ActivityEntry _entry(
  String id,
  DateTime time, {
  String action = 'POST /v1/containers/{id}/restart',
  String target = 'nginx-proxy',
  String result = 'ok',
  String device = 'dev-1',
}) => ActivityEntry(
  id: id,
  time: time,
  action: action,
  target: target,
  result: result,
  deviceId: device,
  deviceName: device == 'dev-1' ? 'This phone' : 'Ops iPad',
  role: 'admin',
);

DeviceInfo _device(String id, ServerRole role) => DeviceInfo(
  id: id,
  name: id,
  role: role,
  lastSeenAt: DateTime.now(),
  isSelf: id == 'a',
);

void main() {
  group('Shell', () {
    test('the pill says Connecting, Connected, then Exited n', () {
      expect(execStatus(connecting: true, failed: false, exitCode: null), (
        'Connecting',
        PillTone.warning,
      ));
      expect(execStatus(connecting: false, failed: false, exitCode: null), (
        'Connected',
        PillTone.accent,
      ));
      expect(execStatus(connecting: false, failed: false, exitCode: 0), (
        'Exited 0',
        PillTone.neutral,
      ));
      expect(
        execStatus(connecting: false, failed: false, exitCode: -1).$1,
        'Disconnected',
      );
      expect(
        execStatus(connecting: false, failed: true, exitCode: null).$2,
        PillTone.danger,
      );
    });

    test('the extra keys send terminal bytes', () {
      expect(TerminalKey.tab.bytes, '\t');
      expect(TerminalKey.interrupt.bytes, '\x03');
      expect(TerminalKey.up.bytes, '\x1B[A');
      expect(TerminalKey.escape.bytes, '\x1B');
    });
  });

  group('Pairing', () {
    test('a fingerprint reads as the agent prints it, four lines of two', () {
      final List<List<String>> lines = fingerprintLines(
        'a4e97c103b65d28f410a96be572dc834'
        '1F:70:AB:59:E3:06:8D:C1:75:42:9B:E0:13:6A:2F:5C',
      );
      expect(lines, hasLength(4));
      expect(lines.first, <String>['A4:E9:7C:10', '3B:65:D2:8F']);
      expect(lines.last, <String>['75:42:9B:E0', '13:6A:2F:5C']);
    });

    test('each failure gets its own title', () {
      String title(AgentException e) => PairFailure.from(e).title;
      expect(
        title(const AgentException('certificate_mismatch', 'x', status: 495)),
        "Certificate doesn't match",
      );
      expect(
        title(const AgentException('pairing_failed', 'x', status: 401)),
        'Token not accepted',
      );
      expect(
        title(const AgentException('agent_unreachable', 'x', status: 502)),
        'Agent not reachable',
      );
      expect(
        title(
          const AgentException('secure_storage_unavailable', 'x', status: 500),
        ),
        'Secure storage unavailable',
      );
      expect(
        PairFailure.from(
          const AgentException('agent_unreachable', 'x'),
          agentUrl: 'https://host:8443',
        ).message,
        contains('https://host:8443'),
      );
    });
  });

  group('Activity', () {
    final DateTime now = DateTime(2026, 9, 25, 12);
    final List<ActivityEntry> log = <ActivityEntry>[
      _entry('1', DateTime(2026, 9, 25, 9, 41)),
      _entry('2', DateTime(2026, 9, 25, 8, 55), result: 'denied', device: 'x'),
      _entry('3', DateTime(2026, 9, 24, 18, 4), result: 'error', device: 'x'),
      _entry('4', DateTime(2026, 9, 22, 10), target: 'redis:7.2'),
    ];

    test('records group by day under Today, Yesterday and a weekday', () {
      final List<ActivityDay> days = groupActivity(log, now: now);
      expect(days.map((ActivityDay d) => d.heading), <String>[
        'Today',
        'Yesterday',
        'Tuesday',
      ]);
      expect(days.first.entries, hasLength(2));
    });

    test('the chips and the text filter', () {
      int count(ActivityFilter f, [String q = '']) => groupActivity(
        log,
        filter: f,
        query: q,
        selfDeviceId: 'dev-1',
        now: now,
      ).fold(0, (int n, ActivityDay d) => n + d.entries.length);
      expect(count(ActivityFilter.all), 4);
      expect(count(ActivityFilter.denied), 1);
      expect(count(ActivityFilter.errors), 1);
      expect(count(ActivityFilter.mine), 2);
      expect(count(ActivityFilter.all, 'redis'), 1);
      expect(count(ActivityFilter.all, 'ipad'), 2);
    });

    test('the sentence can leave the result to the pill', () {
      expect(
        log[1].sentence(withResult: false),
        'nginx-proxy restarted from Ops iPad',
      );
      expect(log[1].sentence(), endsWith(' · denied'));
    });

    test('day headings', () {
      expect(formatDayHeading(DateTime(2026, 9, 25, 1), now: now), 'Today');
      expect(formatDayHeading(DateTime(2026, 9, 1), now: now), '1 Sep');
      expect(formatDayHeading(DateTime(2025, 9, 1), now: now), '1 Sep 2025');
      expect(formatHourMinute(DateTime(2026, 9, 25, 9, 5)), '09:05');
    });
  });

  test('only the single admin is the last admin', () {
    final List<DeviceInfo> one = <DeviceInfo>[
      _device('a', ServerRole.admin),
      _device('b', ServerRole.operator),
    ];
    expect(isLastAdmin(one.first, one), isTrue);
    expect(isLastAdmin(one.last, one), isFalse);
    final List<DeviceInfo> two = <DeviceInfo>[
      ...one,
      _device('c', ServerRole.admin),
    ];
    expect(isLastAdmin(two.first, two), isFalse);
  });

  test('a mount reads source, arrow, target', () {
    const MountInfo mount = MountInfo(
      type: 'volume',
      name: 'api_config',
      destination: '/etc/api',
      rw: false,
    );
    expect(mountLine(mount), 'api_config → /etc/api');
    expect(mountKind(mount), 'Named volume');
  });

  group('on the phone', () {
    setUpAll(loadAppFonts);

    testWidgets('the last admin cannot be demoted or revoked', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: phone);
      goTo(tester, '/s/prod-eu-1/settings/devices');
      await settle(tester);
      await tester.tap(
        find.byWidgetPredicate(
          (Widget w) =>
              w is DoomIconButton &&
              w.semanticLabel == 'Actions for This phone',
        ),
      );
      await settle(tester);
      expect(find.text('The only admin on prod-eu-1'), findsOneWidget);
      final DoomButton revoke = tester.widget<DoomButton>(
        find.widgetWithText(DoomButton, 'Revoke device'),
      );
      expect(revoke.onPressed, isNull);
      await disposeApp(tester);
    });

    testWidgets('Reveal reads the values once and shows one row', (
      WidgetTester tester,
    ) async {
      final repo = await pumpApp(tester, size: phone);
      goTo(tester, '/s/prod-eu-1/containers/4f2a9c1e7b3d');
      await settle(tester);
      await tester.tap(find.text('Environment'));
      await settle(tester);
      expect(find.text('info'), findsNothing);
      final int before = agentOf(repo, 'prod-eu-1').world.activity.length;
      await tester.tap(find.byKey(const ValueKey<String>('reveal-LOG_LEVEL')));
      await settle(tester);
      expect(find.text('info'), findsOneWidget);
      expect(find.text('Hide'), findsOneWidget);
      // One audited read, and a second reveal does not ask again.
      await tester.tap(find.byKey(const ValueKey<String>('reveal-PORT')));
      await settle(tester);
      expect(agentOf(repo, 'prod-eu-1').world.activity.length, before + 1);
      expect(find.text('api_config'), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('the shell answers and the key row is there', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: phone);
      goTo(tester, '/s/prod-eu-1/containers/4f2a9c1e7b3d/shell');
      await settle(tester);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Ctrl+C'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'pwd');
      await tester.tap(find.text('Send'));
      await settle(tester);
      expect(find.textContaining('/app # pwd'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'exit');
      await tester.tap(find.text('Send'));
      await settle(tester);
      expect(find.text('Exited 0'), findsOneWidget);
      expect(find.text('Open again'), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('demo mode: "Pin and pair" adds the server and opens it', (
      WidgetTester tester,
    ) async {
      final repo = await pumpApp(tester, size: phone);
      goTo(tester, '/pair');
      await settle(tester);
      final Finder fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'edge-1');
      await tester.enterText(fields.at(1), 'https://edge-1.example.com:8443');
      await tester.enterText(fields.at(2), 'pt_demo');
      await tester.tap(find.text('Test connection and pair'));
      await settle(tester);
      expect(find.text('Trust this certificate?'), findsOneWidget);
      expect(find.text('SHA-256 FINGERPRINT'), findsOneWidget);
      await tester.tap(find.text('Pin and pair'));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(repo.servers.map((Server s) => s.id), contains('edge-1'));
      expect(locationOf(tester), '/s/edge-1/overview');
      await disposeApp(tester);
    });

    testWidgets('demo mode: the desktop dialog pins on its second step', (
      WidgetTester tester,
    ) async {
      final repo = await pumpApp(tester, size: desktop);
      goTo(tester, '/s/prod-eu-1/overview');
      await settle(tester);
      await tester.tap(find.text('Pair a server'));
      await settle(tester);
      final Finder fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'edge-2');
      await tester.enterText(fields.at(1), 'https://edge-2.example.com:8443');
      await tester.enterText(fields.at(2), 'pt_demo');
      await tester.tap(find.text('Test connection and pair'));
      await settle(tester);
      expect(find.text('PAIR A SERVER · STEP 2 OF 2'), findsOneWidget);
      await tester.tap(find.text('Pin and pair'));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(repo.servers.map((Server s) => s.id), contains('edge-2'));
      await disposeApp(tester);
    });
  });
}
