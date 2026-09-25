/// The breakpoints themselves: which chrome each width gets, that a resize
/// keeps the route and the selection, and that nothing overflows.
library;

import 'package:doomsaday/app/rail.dart';
import 'package:doomsaday/app/sidebar.dart';
import 'package:doomsaday/data/servers_repository.dart';
import 'package:doomsaday/layout/layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';

void main() {
  // Real metrics: the square placeholder glyph the test binding uses
  // otherwise makes every 'does this fit?' assertion meaningless.
  setUpAll(loadAppFonts);

  group('window classes', () {
    test('the breakpoints are the ones the design names', () {
      expect(WindowClass.fromWidth(390), WindowClass.compact);
      expect(WindowClass.fromWidth(599), WindowClass.compact);
      expect(WindowClass.fromWidth(600), WindowClass.medium);
      expect(WindowClass.fromWidth(1099), WindowClass.medium);
      expect(WindowClass.fromWidth(1100), WindowClass.expanded);
      expect(WindowClass.fromWidth(1440), WindowClass.expanded);
    });

    test('touch sizes stay below 1100 and compact sizes start at it', () {
      expect(Density.forClass(WindowClass.compact).compact, isFalse);
      expect(Density.forClass(WindowClass.medium).compact, isFalse);
      expect(Density.forClass(WindowClass.medium).iconButton, 48);
      expect(Density.forClass(WindowClass.expanded).compact, isTrue);
      expect(Density.forClass(WindowClass.expanded).button, 36);
    });
  });

  testWidgets('390 keeps the phone bottom bar and no rail or sidebar', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, size: phone);
    expect(find.text('Servers'), findsWidgets);
    expect(find.byType(NavRail), findsNothing);
    expect(find.byType(Sidebar), findsNothing);

    await tester.tap(find.text('prod-eu-1'));
    await settle(tester);
    // Inside a server the five-tab bar is the navigation.
    expect(find.byType(BottomNavigationBar), findsNothing);
    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('Resources'), findsOneWidget);
    await disposeApp(tester);
  });

  testWidgets('800 uses the 92 px rail instead of the bottom bar', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, size: tablet);
    await tester.tap(find.text('prod-eu-1'));
    await settle(tester);

    expect(find.byType(NavRail), findsOneWidget);
    expect(find.byType(Sidebar), findsNothing);
    expect(tester.getSize(find.byType(NavRail)).width, ShellMetrics.railWidth);
    await disposeApp(tester);
  });

  testWidgets('1440 uses the 264 px sidebar and no Servers start screen', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, size: desktop);

    expect(find.byType(Sidebar), findsOneWidget);
    expect(find.byType(NavRail), findsNothing);
    expect(
      tester.getSize(find.byType(Sidebar)).width,
      ShellMetrics.sidebarWidth,
    );
    // The sidebar carries the brand, every server and the pair button.
    expect(find.text('Doomsaday'), findsOneWidget);
    expect(find.text('All servers'), findsWidgets);
    expect(find.text('Pair a server'), findsOneWidget);
    expect(find.text('backup-nas'), findsWidgets);
    // Demo mode stays labelled.
    expect(find.text('Demo'), findsOneWidget);
    await disposeApp(tester);
  });

  testWidgets('the sidebar shows the selected server sections', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, size: desktop);
    await tester.tap(find.text('prod-eu-1').first);
    await settle(tester);

    expect(find.text('Overview'), findsWidgets);
    expect(find.text('Containers'), findsWidgets);
    expect(find.text('Stacks'), findsWidgets);
    expect(find.text('Resources'), findsWidgets);
    expect(find.text('Alerts'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
    await disposeApp(tester);
  });

  testWidgets(
    'resizing 1440 to 390 and back keeps the selected container and throws '
    'nothing',
    (WidgetTester tester) async {
      await pumpApp(tester, size: desktop);
      await tester.tap(find.text('prod-eu-1').first);
      await settle(tester);
      await tester.tap(find.text('Containers').last);
      await settle(tester);

      await tester.tap(find.text('api-gateway').first);
      await settle(tester);
      expect(find.text('Restart'), findsOneWidget);

      resizeTo(tester, phone);
      await settle(tester);
      // The pushed phone detail screen for the same container.
      expect(find.text('api-gateway'), findsWidgets);
      expect(find.text('Containers'), findsWidgets);

      resizeTo(tester, desktop);
      await settle(tester);
      expect(find.byType(Sidebar), findsOneWidget);
      expect(find.text('api-gateway'), findsWidgets);
      expect(tester.takeException(), isNull);
      await disposeApp(tester);
    },
  );

  testWidgets('no overflow on every top-level screen in both themes', (
    WidgetTester tester,
  ) async {
    const List<Size> widths = <Size>[
      Size(600, 900),
      Size(1099, 900),
      Size(1100, 900),
      Size(1440, 900),
    ];
    const List<String> sections = <String>[
      'Overview',
      'Containers',
      'Stacks',
      'Resources',
    ];

    for (final ThemeMode mode in <ThemeMode>[ThemeMode.dark, ThemeMode.light]) {
      for (final Size size in widths) {
        final ServersRepository repo = await pumpApp(
          tester,
          size: size,
          themeMode: mode,
        );
        expect(repo.isDemo, isTrue);
        expect(tester.takeException(), isNull, reason: 'home at $size/$mode');

        await tester.tap(find.text('prod-eu-1').first);
        await settle(tester);

        for (final String section in sections) {
          final Finder tab = find.text(section);
          if (tab.evaluate().isEmpty) continue;
          await tester.tap(tab.last);
          await settle(tester);
          expect(
            tester.takeException(),
            isNull,
            reason: '$section at $size in $mode',
          );
        }
        await disposeApp(tester);
      }
    }
  });
}
