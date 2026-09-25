/// What the two editions look like: the badges, the locked pages, the server
/// limit and the scoped palette.
library;

import 'package:doomsaday/app/app.dart';
import 'package:doomsaday/data/mock_seed.dart';
import 'package:doomsaday/data/providers.dart';
import 'package:doomsaday/data/servers_repository.dart';
import 'package:doomsaday/edition/edition.dart';
import 'package:doomsaday/edition/locked_feature.dart';
import 'package:doomsaday/edition/pro_badge.dart';
import 'package:doomsaday/edition/server_limit.dart';
import 'package:doomsaday/features/fleet/fleet_providers.dart';
import 'package:doomsaday/features/fleet/fleet_screen.dart';
import 'package:doomsaday/features/logwall/log_wall_controller.dart';
import 'package:doomsaday/features/logwall/log_wall_screen.dart';
import 'package:doomsaday/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';

/// Servers that are paired rather than sampled, so the edition's limit counts.
/// [maxServers] is what `main()` would have given the repository for the
/// edition under test.
ServersRepository paired({int servers = 2, int? maxServers = 2}) =>
    ServersRepository.pairedMocks(
      <MockWorld>[
        seedProduction(),
        seedStaging(),
        seedOffline(),
      ].take(servers).toList(growable: false),
      maxServers: maxServers,
    );

void goTo(WidgetTester tester, String path) =>
    containerOf(tester).read(routerProvider).go(path);

void main() {
  // Real metrics: the square placeholder glyph the test binding uses
  // otherwise makes every 'does this fit?' assertion meaningless.
  setUpAll(loadAppFonts);

  group('the sidebar names the edition', () {
    testWidgets('Free badges what it locks and counts the servers it covers', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, edition: Edition.free, repository: paired());

      // The caption is drawn in capitals.
      expect(find.text('SERVERS · 2 OF 2 ON FREE'), findsOneWidget);
      // All servers, Pair a server, the three fleet sections, and the locked
      // page's own header badge.
      expect(find.byType(ProBadge), findsNWidgets(6));
      expect(find.textContaining('· Free'), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('Pro brands itself and locks nothing', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, repository: paired(maxServers: null));

      expect(find.text('SERVERS'), findsOneWidget);
      // Only the brand row's badge, as in P3.
      expect(find.byType(ProBadge), findsOneWidget);
      expect(find.textContaining('· Free'), findsNothing);
      expect(find.byType(FleetScreen), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('demo mode is not counted against the limit', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, edition: Edition.free);

      expect(find.text('SERVERS'), findsOneWidget);
      expect(find.textContaining('ON FREE'), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('more than two already paired stay listed and usable', (
      WidgetTester tester,
    ) async {
      final ServersRepository repo = paired(servers: 3);
      await pumpApp(tester, edition: Edition.free, repository: repo);

      expect(repo.canPairAnother, isFalse);
      for (final String name in <String>['prod-eu-1', 'staging-1']) {
        expect(find.text(name), findsWidgets);
      }
      await tester.tap(find.text('prod-eu-1').first);
      await settle(tester);
      expect(locationOf(tester), '/s/prod-eu-1/overview');
      await disposeApp(tester);
    });
  });

  group('locked features', () {
    testWidgets('Free shows the panel where Pro shows the feature', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, edition: Edition.free, repository: paired());
      expect(find.byType(FleetScreen), findsNothing);
      expect(find.byType(LockedFeature), findsOneWidget);
      expect(find.text('All servers is part of Doomsaday Pro'), findsOneWidget);
      expect(
        find.text('Your servers and containers stay fully usable on Free.'),
        findsOneWidget,
      );
      expect(find.text('Get Doomsaday Pro'), findsOneWidget);
      expect(find.text('Not now'), findsOneWidget);

      goTo(tester, '/all/alerts');
      await settle(tester);
      expect(
        find.text('Fleet alerts is part of Doomsaday Pro'),
        findsOneWidget,
      );

      goTo(tester, '/all/logwall');
      await settle(tester);
      expect(find.text('Log wall is part of Doomsaday Pro'), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('the locked All servers page runs no aggregation', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, edition: Edition.free, repository: paired());
      expect(find.byType(LockedFeature), findsOneWidget);
      expect(
        containerOf(tester)
            .getAllProviderElements()
            .where(
              (ProviderElementBase<Object?> e) => e.origin == fleetProvider,
            )
            .isEmpty,
        isTrue,
        reason: 'the fleet was aggregated behind a locked page',
      );

      goTo(tester, '/all/alerts');
      await settle(tester);
      expect(
        containerOf(tester)
            .getAllProviderElements()
            .where(
              (ProviderElementBase<Object?> e) => e.origin == fleetProvider,
            )
            .isEmpty,
        isTrue,
      );
      await disposeApp(tester);
    });

    testWidgets('the locked log wall opens no stream, where Pro opens one', (
      WidgetTester tester,
    ) async {
      const LogPaneRef pane = LogPaneRef(
        serverId: 'prod-eu-1',
        containerId: 'c1',
        name: 'api-gateway',
      );

      ServersRepository repo = paired();
      await pumpApp(tester, edition: Edition.free, repository: repo);
      containerOf(tester).read(logWallProvider.notifier).add(pane);
      goTo(tester, '/all/logwall');
      await settle(tester);
      expect(find.byType(LogPane), findsNothing);
      expect(agentOf(repo, 'prod-eu-1').openLogStreams, 0);
      await disposeApp(tester);

      // The same wall in Pro, so the test above can only pass for the right
      // reason.
      repo = paired(maxServers: null);
      await pumpApp(tester, repository: repo);
      containerOf(tester).read(logWallProvider.notifier).add(pane);
      goTo(tester, '/all/logwall');
      await settle(tester);
      expect(find.byType(LogPane), findsOneWidget);
      expect(agentOf(repo, 'prod-eu-1').openLogStreams, 1);
      await disposeApp(tester);
    });
  });

  group('the server limit', () {
    testWidgets('a third server opens P2 on Free', (WidgetTester tester) async {
      await pumpApp(tester, edition: Edition.free, repository: paired());

      await tester.tap(find.text('Pair a server'));
      await settle(tester);

      expect(find.byType(ServerLimitBody), findsOneWidget);
      expect(find.text('Free covers 2 servers'), findsOneWidget);
      expect(
        find.text('You have paired prod-eu-1 and staging-1.'),
        findsOneWidget,
      );
      expect(find.textContaining('unpair one of these two'), findsOneWidget);

      // The locked page behind the sheet has a "Not now" of its own.
      await tester.tap(find.text('Not now').last);
      await settle(tester);
      expect(find.byType(ServerLimitBody), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('Pro opens the pairing form instead', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, repository: paired(maxServers: null));

      await tester.tap(find.text('Pair a server'));
      await settle(tester);

      expect(find.byType(ServerLimitBody), findsNothing);
      expect(find.text('Pair a server agent'), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('a deep link to /pair gets the same words on Free', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, edition: Edition.free, repository: paired());

      goTo(tester, '/pair');
      await settle(tester);
      expect(find.byType(ServerLimitBody), findsOneWidget);
      expect(find.text('Test connection and pair'), findsNothing);
      await disposeApp(tester);
    });
  });

  group('the jump palette', () {
    Future<void> openPalette(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
      await settle(tester);
    }

    testWidgets('Free searches the current server and offers the rest', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, edition: Edition.free, repository: paired());
      await tester.tap(find.text('prod-eu-1').first);
      await settle(tester);
      await openPalette(tester);

      expect(find.text('Search every server'), findsOneWidget);
      // A container of this server is listed, one from the other is not.
      expect(find.text('api-gateway'), findsWidgets);
      expect(find.text('staging-web'), findsNothing);

      await tester.tap(find.text('Search every server'));
      await settle(tester);
      expect(
        find.text('Cross-server search is part of Doomsaday Pro'),
        findsOneWidget,
      );
      await disposeApp(tester);
    });

    testWidgets('Pro searches every server and offers nothing more', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, repository: paired(maxServers: null));
      await tester.tap(find.text('prod-eu-1').first);
      await settle(tester);
      await openPalette(tester);

      expect(find.text('Search every server'), findsNothing);
      await tester.enterText(find.byType(TextField).last, 'staging-web');
      await settle(tester);
      expect(find.text('staging-web'), findsWidgets);
      await disposeApp(tester);
    });
  });

  testWidgets('the locked page and the limit sheet never overflow', (
    WidgetTester tester,
  ) async {
    const List<Size> sizes = <Size>[
      Size(390, 844),
      Size(800, 1200),
      Size(1440, 900),
    ];
    for (final ThemeMode mode in <ThemeMode>[ThemeMode.dark, ThemeMode.light]) {
      for (final Size size in sizes) {
        for (final ProFeature feature in ProFeature.values) {
          await _pumpBare(
            tester,
            LockedFeature(feature: feature),
            size: size,
            mode: mode,
          );
          expect(
            tester.takeException(),
            isNull,
            reason: '${feature.name} at $size in $mode',
          );
        }
        await _pumpBare(
          tester,
          const ServerLimitBody(
            limit: 2,
            paired: <String>['prod-eu-1', 'staging-1'],
          ),
          size: size,
          mode: mode,
        );
        expect(
          tester.takeException(),
          isNull,
          reason: 'the limit sheet at $size in $mode',
        );
      }
    }
  });
}

/// One edition widget on its own, at a window and a theme.
Future<void> _pumpBare(
  WidgetTester tester,
  Widget child, {
  required Size size,
  required ThemeMode mode,
}) async {
  useWindow(tester, size);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        editionProvider.overrideWithValue(Edition.free),
        serversRepositoryProvider.overrideWithValue(paired()),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: mode,
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
}
