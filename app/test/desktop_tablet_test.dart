/// The desktop and tablet boards of the desktop-tablet round: the grouped
/// jump palette, the pair dialog's certificate step, the alert rules table,
/// the volume and network status columns, and the tablet containers list.
library;

import 'package:doomsaday/data/models.dart';
import 'package:doomsaday/features/alerts/alerts_screen.dart';
import 'package:doomsaday/features/palette/jump_palette.dart';
import 'package:doomsaday/layout/layout.dart';
import 'package:doomsaday/widgets/filter_field.dart';
import 'package:doomsaday/widgets/table.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';

JumpTarget _t(JumpKind kind, String title, String server) => JumpTarget(
  kind: kind,
  title: title,
  subtitle: '',
  path: '/',
  serverId: server,
  serverName: server,
);

void main() {
  setUpAll(loadAppFonts);

  group('groupJumpTargets', () {
    final List<JumpTarget> all = <JumpTarget>[
      _t(JumpKind.server, 'staging-1', 'staging-1'),
      _t(JumpKind.server, 'prod-eu-1', 'prod-eu-1'),
      for (int i = 0; i < 5; i++)
        _t(JumpKind.container, 'staging-c$i', 'staging-1'),
      for (int i = 0; i < 5; i++)
        _t(JumpKind.container, 'prod-c$i', 'prod-eu-1'),
      _t(JumpKind.stack, 'web-platform', 'prod-eu-1'),
    ];

    test('groups in order, current server first, three apiece empty', () {
      final List<(JumpKind, List<JumpTarget>)> groups = groupJumpTargets(
        all,
        query: '',
        currentServerId: 'prod-eu-1',
      );
      expect(groups.map((g) => g.$1), <JumpKind>[
        JumpKind.server,
        JumpKind.container,
        JumpKind.stack,
      ]);
      expect(groups[0].$2.first.title, 'prod-eu-1');
      expect(groups[1].$2.map((JumpTarget t) => t.title), <String>[
        'prod-c0',
        'prod-c1',
        'prod-c2',
      ]);
    });

    test('a query filters, drops empty groups and allows more rows', () {
      final List<(JumpKind, List<JumpTarget>)> groups = groupJumpTargets(
        all,
        query: 'C',
        currentServerId: 'prod-eu-1',
      );
      expect(groups.single.$1, JumpKind.container);
      expect(groups.single.$2, hasLength(8));
    });
  });

  test('network status and volume last-used labels', () {
    const NetworkInfo bridge = NetworkInfo(
      id: '1',
      name: 'bridge',
      driver: 'bridge',
      subnets: <String>[],
      scope: 'local',
      attached: 0,
      isDefault: true,
    );
    const NetworkInfo old = NetworkInfo(
      id: '2',
      name: 'old',
      driver: 'bridge',
      subnets: <String>[],
      scope: 'local',
      attached: 0,
      isDefault: false,
    );
    expect(bridge.statusLabel, 'Default');
    expect(old.statusLabel, 'Unused');

    const VolumeInfo mounted = VolumeInfo(
      name: 'a',
      driver: 'local',
      sizeBytes: 1,
      mountedBy: <String>['x'],
    );
    final VolumeInfo idle = VolumeInfo(
      name: 'b',
      driver: 'local',
      sizeBytes: 1,
      mountedBy: const <String>[],
      lastUsed: DateTime.now().subtract(const Duration(minutes: 12)),
    );
    expect(mounted.lastUsedShort, 'now');
    expect(idle.lastUsedShort, '12 min ago');
  });

  test('the rules table splits each rule into name, threshold, window', () {
    final List<AlertRuleRow> rows = mergeAlertRules(const <AlertRule>[
      AlertRule(
        id: AlertRuleId.restartLoop,
        name: 'Restart loop',
        enabled: true,
        threshold: 3,
        windowSeconds: 600,
      ),
      AlertRule(
        id: AlertRuleId.cpuHigh,
        name: 'CPU',
        enabled: true,
        threshold: 90,
        windowSeconds: 300,
      ),
      AlertRule(
        id: AlertRuleId.memoryHigh,
        name: 'Memory',
        enabled: true,
        threshold: 90,
        windowSeconds: 300,
      ),
    ]);
    expect(rows.map((AlertRuleRow r) => r.name), <String>[
      'Restart loop',
      'CPU or memory high',
    ]);
    expect(rows[0].threshold, '3 restarts');
    expect(rows[0].window, '10 min');
    expect(rows[1].threshold, '90%');
  });

  testWidgets('the alerts page draws its rules as a table on the desktop', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);
    goTo(tester, '/s/prod-eu-1/alerts');
    await settle(tester);
    expect(find.byType(DataTableView<AlertRuleRow>), findsOneWidget);
    expect(find.text('Non-zero exit code'), findsOneWidget);
    await disposeApp(tester);
  });

  testWidgets('the pair dialog confirms the certificate as its second step', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.text('Pair a server').first);
    await settle(tester);
    expect(find.text('PAIR A SERVER · STEP 1 OF 2'), findsOneWidget);

    final Finder fields = find.byType(EditableText);
    final int n = fields.evaluate().length;
    await tester.enterText(fields.at(n - 3), 'edge-1');
    await tester.enterText(fields.at(n - 2), 'https://edge-1.example.com:8443');
    await tester.enterText(fields.at(n - 1), 'pt_token');
    await tester.tap(find.text('Test connection and pair'));
    await settle(tester);

    // The same dialog, now on its second step: one dialog, not two.
    expect(find.text('PAIR A SERVER · STEP 2 OF 2'), findsOneWidget);
    expect(find.text('Test connection and pair'), findsNothing);
    expect(find.text('A4:E9:7C:10'), findsOneWidget);

    await tester.tap(find.text('Back'));
    await settle(tester);
    expect(find.text('Test connection and pair'), findsOneWidget);

    // Cancel closes the whole dialog: there is no second one underneath.
    await tester.tap(find.text('Test connection and pair'));
    await settle(tester);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(find.text('Trust this certificate?'), findsNothing);
    expect(find.text('Test connection and pair'), findsNothing);
    await disposeApp(tester);
  });

  testWidgets('the palette groups its results and walks them with arrows', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.text('prod-eu-1').first);
    await settle(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await settle(tester);

    expect(find.text('SERVERS'), findsWidgets);
    expect(find.text('CONTAINERS'), findsOneWidget);
    expect(find.text('STACKS'), findsOneWidget);
    expect(find.text('current'), findsOneWidget);

    // Three servers, then nginx-proxy, then api-gateway.
    for (int i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    }
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(locationOf(tester), startsWith('/s/prod-eu-1/containers/'));
    await disposeApp(tester);
  });

  testWidgets('the tablet containers list: filter beside the chips, 52 rows', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, size: const Size(834, 1194));
    goTo(tester, '/s/prod-eu-1/containers');
    await settle(tester);

    expect(find.byType(FilterField), findsOneWidget);
    expect(find.text('16 on prod-eu-1'), findsOneWidget);
    final double field = tester.getCenter(find.byType(FilterField)).dy;
    final double chip = tester.getCenter(find.text('All 16')).dy;
    expect((field - chip).abs(), lessThan(1));

    final Rect a = tester.getRect(find.text('nginx-proxy'));
    final Rect b = tester.getRect(find.text('api-gateway'));
    expect(b.top - a.top, closeTo(ShellMetrics.tabletRow + 1, 1.5));

    await tester.enterText(find.byType(EditableText).first, 'redis');
    await settle(tester);
    expect(find.text('api-gateway'), findsNothing);
    expect(find.text('redis-cache'), findsOneWidget);
    await disposeApp(tester);
  });

  testWidgets('tablet stack cards put the primary action on its own row', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, size: const Size(834, 1194));
    goTo(tester, '/s/prod-eu-1/stacks');
    await settle(tester);
    final double pull = tester
        .getCenter(find.text('Pull and redeploy').first)
        .dy;
    final double restart = tester.getCenter(find.text('Restart').first).dy;
    expect(restart, greaterThan(pull + 30));
    await disposeApp(tester);
  });
}
