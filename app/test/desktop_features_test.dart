/// The desktop-only behaviour: the split view, typed and biometric
/// confirmation, the fleet, the log wall, sorting and the jump palette.
library;

import 'package:doomsaday/app/app.dart';
import 'package:doomsaday/data/biometrics.dart';
import 'package:doomsaday/data/mock_seed.dart';
import 'package:doomsaday/data/models.dart';
import 'package:doomsaday/data/servers_repository.dart';
import 'package:doomsaday/features/logwall/log_wall_controller.dart';
import 'package:doomsaday/features/logwall/log_wall_screen.dart';
import 'package:doomsaday/widgets/table.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';

Future<void> openContainers(WidgetTester tester) async {
  await tester.tap(find.text('prod-eu-1').first);
  await settle(tester);
  await tester.tap(find.text('Containers').last);
  await settle(tester);
}

void main() {
  // Real metrics: the square placeholder glyph the test binding uses
  // otherwise makes every 'does this fit?' assertion meaningless.
  setUpAll(loadAppFonts);

  testWidgets('selecting a row in the split view updates the URL', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);
    await openContainers(tester);
    expect(locationOf(tester), '/s/prod-eu-1/containers');

    await tester.tap(find.text('api-gateway').first);
    await settle(tester);

    expect(locationOf(tester), '/s/prod-eu-1/containers/4f2a9c1e7b3d');
    // The detail pane, not a pushed screen: the list is still there.
    expect(find.text('nginx-proxy'), findsWidgets);
    expect(find.text('Logs'), findsWidgets);
    expect(find.text('Environment'), findsWidgets);

    await tester.tap(find.text('nginx-proxy').first);
    await settle(tester);
    expect(locationOf(tester), startsWith('/s/prod-eu-1/containers/'));
    expect(locationOf(tester), isNot('/s/prod-eu-1/containers/4f2a9c1e7b3d'));
    await disposeApp(tester);
  });

  testWidgets(
    'with no biometrics the confirm button unlocks only on an exact name and '
    'sends typed',
    (WidgetTester tester) async {
      final ServersRepository repo = await pumpApp(
        tester,
        authenticator: const NoBiometrics(),
      );
      await openContainers(tester);
      await tester.tap(find.text('api-gateway').first);
      await settle(tester);

      await tester.tap(find.text('Stop').first);
      await settle(tester);
      expect(find.text('Stop api-gateway?'), findsOneWidget);
      expect(find.textContaining('X-Confirmed: typed'), findsOneWidget);

      // Locked: the wrong name changes nothing.
      await tester.enterText(find.byType(TextField).last, 'api-gatewa');
      await tester.pump();
      await tester.tap(find.text('Stop container'));
      await settle(tester);
      expect(find.text('Stop api-gateway?'), findsOneWidget);
      expect(agentOf(repo, 'prod-eu-1').confirmations, isEmpty);

      await tester.enterText(find.byType(TextField).last, 'api-gateway');
      await tester.pump();
      await tester.tap(find.text('Stop container'));
      await settle(tester);
      await settle(tester);

      expect(agentOf(repo, 'prod-eu-1').confirmations, <Confirmed>[
        Confirmed.typed,
      ]);
      await disposeApp(tester);
    },
  );

  testWidgets('a device that can do biometrics still sends biometric', (
    WidgetTester tester,
  ) async {
    final ServersRepository repo = await pumpApp(tester);
    await openContainers(tester);
    await tester.tap(find.text('api-gateway').first);
    await settle(tester);

    await tester.tap(find.text('Stop').first);
    await settle(tester);
    expect(find.textContaining('X-Confirmed: biometric'), findsOneWidget);

    await tester.tap(find.text('Stop container'));
    await settle(tester);
    await settle(tester);

    expect(agentOf(repo, 'prod-eu-1').confirmations, <Confirmed>[
      Confirmed.biometric,
    ]);
    await disposeApp(tester);
  });

  testWidgets('the fleet table aggregates two servers and survives one down', (
    WidgetTester tester,
  ) async {
    await pumpApp(
      tester,
      repository: ServersRepository(
        worlds: <MockWorld>[seedProduction(), seedStaging(), seedOffline()],
      ),
    );
    await settle(tester);

    expect(find.text('All servers'), findsWidgets);
    // Containers from both online servers in one table.
    expect(find.text('api-gateway'), findsOneWidget);
    expect(find.text('staging-web'), findsOneWidget);
    // The offline one is named rather than silently dropped.
    expect(find.textContaining('backup-nas is offline'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('2 of 3 agents online · figures refresh live'), findsOne);
    await disposeApp(tester);
  });

  testWidgets('a table sorts when its header is clicked', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.text('prod-eu-1').first);
    await settle(tester);
    await tester.tap(find.text('Resources').last);
    await settle(tester);

    final Finder table = find.byType(DataTableView<DockerImage>);
    expect(table, findsOneWidget);

    DataTableViewState<DockerImage> state() =>
        tester.state<DataTableViewState<DockerImage>>(table);

    // Opens biggest first, as D4 shows.
    final List<DockerImage> biggestFirst = state().visibleRows;
    expect(biggestFirst.first.sizeBytes >= biggestFirst.last.sizeBytes, isTrue);

    await tester.tap(find.text('SIZE'));
    await tester.pump();

    final List<DockerImage> smallestFirst = state().visibleRows;
    expect(smallestFirst.first.sizeBytes <= smallestFirst.last.sizeBytes, true);
    expect(smallestFirst.first.ref, isNot(biggestFirst.first.ref));
    await disposeApp(tester);
  });

  testWidgets(
    'a log wall pane closes its stream when it is closed and when the wall is '
    'left',
    (WidgetTester tester) async {
      final ServersRepository repo = await pumpApp(tester);
      containerOf(tester)
          .read(logWallProvider.notifier)
          .add(
            const LogPaneRef(
              serverId: 'prod-eu-1',
              containerId: '4f2a9c1e7b3d',
              name: 'api-gateway',
            ),
          );
      containerOf(tester).read(routerProvider).go('/all/logwall');
      await settle(tester);

      expect(find.byType(LogPane), findsOneWidget);
      expect(agentOf(repo, 'prod-eu-1').openLogStreams, 1);

      // A second pane opens a second stream.
      containerOf(tester)
          .read(logWallProvider.notifier)
          .add(
            const LogPaneRef(
              serverId: 'prod-eu-1',
              containerId: '2c6e4a9f1d30',
              name: 'postgres-main',
            ),
          );
      await settle(tester);
      expect(agentOf(repo, 'prod-eu-1').openLogStreams, 2);

      await tester.tap(find.bySemanticsLabel('Close api-gateway'));
      await settle(tester);
      expect(find.byType(LogPane), findsOneWidget);
      expect(agentOf(repo, 'prod-eu-1').openLogStreams, 1);

      // Leaving the wall drops the rest.
      containerOf(tester).read(routerProvider).go('/');
      await settle(tester);
      expect(find.byType(LogPane), findsNothing);
      expect(agentOf(repo, 'prod-eu-1').openLogStreams, 0);
      await disposeApp(tester);
    },
  );

  testWidgets('Cmd+K finds a container and opens it', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.text('prod-eu-1').first);
    await settle(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await settle(tester);

    expect(find.text('Jump to a container, stack or server'), findsWidgets);

    await tester.enterText(find.byType(TextField).last, 'redis-cache');
    await settle(tester);
    expect(find.text('redis-cache'), findsWidgets);

    await tester.tap(find.text('redis-cache').last);
    await settle(tester);

    expect(locationOf(tester), startsWith('/s/prod-eu-1/containers/'));
    await disposeApp(tester);
  });
}
