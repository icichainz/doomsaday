/// The geometry the design review asked for: rows of actions and chips that
/// stay rows, a logs toolbar on one line, a brand row that never truncates,
/// and no overflow anywhere at any of the four widths.
library;

import 'package:doomsaday/app/sidebar.dart';
import 'package:doomsaday/edition/edition.dart';
import 'package:doomsaday/features/logs/logs_screen.dart';
import 'package:doomsaday/widgets/buttons.dart';
import 'package:doomsaday/widgets/desktop.dart';
import 'package:doomsaday/widgets/primitives.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';

const Size medium = Size(800, 1200);
const Size narrowDesktop = Size(1100, 900);

/// Every finder's vertical centre, so "one row" is a fact rather than a hope.
void expectOneRow(WidgetTester tester, List<Finder> parts, {String? reason}) {
  expect(parts.length, greaterThan(1));
  final List<double> centres = <double>[
    for (final Finder part in parts) tester.getCenter(part).dy,
  ];
  for (final double dy in centres) {
    expect(
      dy,
      closeTo(centres.first, 4),
      reason: reason ?? 'expected one row, got centres $centres',
    );
  }
  // And left to right, in the order given.
  final List<double> lefts = <double>[
    for (final Finder part in parts) tester.getTopLeft(part).dx,
  ];
  for (int i = 1; i < lefts.length; i++) {
    expect(lefts[i], greaterThan(lefts[i - 1]), reason: 'left to right');
  }
}

/// True when a [Text] had to cut itself short to fit.
void expectNotTruncated(WidgetTester tester, Finder finder) {
  final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
    finder,
  );
  final TextPainter painter = TextPainter(
    text: paragraph.text,
    textDirection: TextDirection.ltr,
    textScaler: paragraph.textScaler,
    maxLines: 1,
  )..layout();
  expect(
    paragraph.size.width,
    greaterThanOrEqualTo(painter.width - 0.5),
    reason: 'the label was cut to ${paragraph.size.width} of ${painter.width}',
  );
  painter.dispose();
}

void main() {
  setUpAll(loadAppFonts);

  group('rows stay rows', () {
    testWidgets('a stack card keeps its three actions on one row at 390', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: phone);
      goTo(tester, '/s/prod-eu-1/stacks');
      await settle(tester);

      expectOneRow(tester, <Finder>[
        find.text('Pull and redeploy').first,
        find.text('Restart').first,
        find.text('Down').first,
      ]);
      // The primary flexes and the others hug, so the primary is the widest.
      double buttonWidth(String label) => tester
          .getSize(
            find
                .ancestor(
                  of: find.text(label).first,
                  matching: find.byType(DoomButton),
                )
                .first,
          )
          .width;
      expect(
        buttonWidth('Pull and redeploy'),
        greaterThan(buttonWidth('Restart')),
      );
      await disposeApp(tester);
    });

    testWidgets('a swarm service keeps its actions on one row at 390', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: phone);
      goTo(tester, '/s/prod-eu-1/stacks');
      await settle(tester);
      await tester.tap(find.text('Swarm services').last);
      await settle(tester);

      expectOneRow(tester, <Finder>[
        find.text('Update').first,
        find.text('Roll back').first,
      ]);
      await disposeApp(tester);
    });

    testWidgets('the container list chips share one row in the 400 px pane', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: desktop);
      goTo(tester, '/s/prod-eu-1/containers');
      await settle(tester);

      final Finder chips = find.byType(PillChip);
      expect(chips, findsNWidgets(3));
      expectOneRow(tester, <Finder>[chips.at(0), chips.at(1), chips.at(2)]);
      // Hugging, not filling: three chips fit well inside the 400 px pane.
      double total = 0;
      for (int i = 0; i < 3; i++) {
        total += tester.getSize(chips.at(i)).width;
      }
      expect(total, lessThan(360));
      await disposeApp(tester);
    });

    testWidgets('the table chips share one row above the table', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: desktop);
      goTo(tester, '/s/prod-eu-1/resources');
      await settle(tester);

      final Finder chips = find.byType(PillChip);
      expect(chips, findsNWidgets(3));
      expectOneRow(tester, <Finder>[chips.at(0), chips.at(1), chips.at(2)]);
      await disposeApp(tester);
    });

    testWidgets(
      'the fleet chips and both state buttons stay on the filter row',
      (WidgetTester tester) async {
        await pumpApp(tester, size: desktop);
        goTo(tester, '/');
        await settle(tester);

        final Finder chips = find.byType(PillChip);
        expect(chips, findsWidgets);
        final int last = chips.evaluate().length - 1;
        expectOneRow(tester, <Finder>[chips.at(0), chips.at(last)]);
        // "Needs attention" is the last chip, and it is inside the window.
        final Rect attention = tester.getRect(chips.at(last));
        expect(attention.right, lessThanOrEqualTo(1440));
        await disposeApp(tester);
      },
    );

    testWidgets('the desktop logs toolbar is one line at 1440', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: desktop);
      goTo(tester, '/s/prod-eu-1/containers/4f2a9c1e7b3d/logs');
      await settle(tester);

      expect(find.byType(LogsView), findsOneWidget);
      expectOneRow(tester, <Finder>[
        find.text('Logs').last,
        find.text('Filter lines'),
        find.text('Last 15 min'),
        find.bySemanticsLabel('Open in log wall'),
      ]);
      // And the log surface starts right under that single line.
      final double toolbar = tester.getBottomLeft(find.text('Last 15 min')).dy;
      expect(toolbar, lessThan(360));
      await disposeApp(tester);
    });
  });

  group("the boards' own words", () {
    // api-gateway passes its health check on prod-eu-1, so the pill reads the
    // health and every row label reads "Healthy" — never the uptime.
    testWidgets('the phone detail pill reads Running · healthy', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: phone);
      goTo(tester, '/s/prod-eu-1/containers/4f2a9c1e7b3d');
      await settle(tester);

      expect(find.text('Running · healthy'), findsOneWidget);
      expect(find.text('Up 3 days'), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('the desktop pane header says it, and its list row says '
        'Healthy', (WidgetTester tester) async {
      await pumpApp(tester, size: desktop);
      goTo(tester, '/s/prod-eu-1/containers/4f2a9c1e7b3d');
      await settle(tester);

      final Finder pill = find.descendant(
        of: find.byType(StatusPill),
        matching: find.text('Running · healthy'),
      );
      expect(pill, findsOneWidget);
      expectNotTruncated(tester, pill);
      // The list pane on the left shows the row label, not the pill's words.
      expect(find.text('Healthy'), findsWidgets);
      expect(find.text('Up 3 days'), findsNothing);
      await disposeApp(tester);
    });

    for (final Size size in <Size>[medium, desktop]) {
      testWidgets('the busiest-containers row reads Healthy at ${size.width}', (
        WidgetTester tester,
      ) async {
        await pumpApp(tester, size: size);
        goTo(tester, '/s/prod-eu-1/overview');
        await settle(tester);

        expect(find.text('BUSIEST CONTAINERS'), findsOneWidget);
        expect(find.text('api-gateway'), findsWidgets);
        expect(find.text('Healthy'), findsWidgets);
        expect(find.text('Up 3 days'), findsNothing);
        await disposeApp(tester);
      });
    }

    testWidgets('the all-servers table reads Healthy too', (
      WidgetTester tester,
    ) async {
      // "All servers" is the start screen above 1100.
      await pumpApp(tester, size: desktop, edition: Edition.pro);
      goTo(tester, '/');
      await settle(tester);

      expect(find.text('api-gateway'), findsWidgets);
      expect(find.text('Healthy'), findsWidgets);
      expect(find.text('Up 3 days'), findsNothing);
      await disposeApp(tester);
    });

    for (final Size size in <Size>[phone, desktop]) {
      testWidgets('a down stack card names the exit at ${size.width}', (
        WidgetTester tester,
      ) async {
        await pumpApp(tester, size: size);
        goTo(tester, '/s/prod-eu-1/stacks');
        await settle(tester);

        expect(
          find.text('postgres-backup exited with code 1, 12 min ago.'),
          findsOneWidget,
        );
        expect(find.text('postgres-backup is not running.'), findsNothing);
        await disposeApp(tester);
      });
    }
  });

  group('the Pro brand row', () {
    for (final Size size in <Size>[narrowDesktop, desktop]) {
      testWidgets(
        'fits "Doomsaday" and PRO with demo mode on at ${size.width}',
        (WidgetTester tester) async {
          await pumpApp(tester, size: size, edition: Edition.pro);
          expect(find.byType(Sidebar), findsOneWidget);

          final Finder brand = find.descendant(
            of: find.byType(Sidebar),
            matching: find.text('Doomsaday'),
          );
          expect(brand, findsOneWidget);
          expectNotTruncated(tester, brand);
          expect(find.text('PRO'), findsWidgets);
          // The demo pill still exists — it has moved off the brand row.
          expect(find.text('Demo'), findsOneWidget);
          expect(
            tester.getCenter(find.text('Demo')).dy,
            greaterThan(tester.getCenter(brand).dy),
          );
          await disposeApp(tester);
        },
      );
    }
  });

  group('nothing overflows', () {
    const List<String> phoneRoutes = <String>[
      '/',
      '/s/prod-eu-1/overview',
      '/s/prod-eu-1/containers',
      '/s/prod-eu-1/containers/4f2a9c1e7b3d',
      '/s/prod-eu-1/stacks',
      '/s/prod-eu-1/resources',
      '/s/prod-eu-1/alerts',
      '/s/prod-eu-1/settings',
    ];
    const List<String> desktopRoutes = <String>[
      ...phoneRoutes,
      '/s/prod-eu-1/containers/4f2a9c1e7b3d/logs',
      '/all/logwall',
      '/all/alerts',
    ];

    for (final Edition edition in <Edition>[Edition.free, Edition.pro]) {
      for (final ThemeMode mode in <ThemeMode>[
        ThemeMode.dark,
        ThemeMode.light,
      ]) {
        for (final Size size in <Size>[phone, medium, narrowDesktop, desktop]) {
          testWidgets(
            '${edition.shortName} ${mode.name} at ${size.width.round()}',
            (WidgetTester tester) async {
              await pumpApp(
                tester,
                size: size,
                edition: edition,
                themeMode: mode,
              );
              final bool wide = size.width >= 1100;
              for (final String route in wide ? desktopRoutes : phoneRoutes) {
                goTo(tester, route);
                await settle(tester);
                expect(
                  tester.takeException(),
                  isNull,
                  reason:
                      '$route at ${size.width} in ${mode.name} '
                      '(${edition.shortName})',
                );
              }
              await disposeApp(tester);
            },
          );
        }
      }
    }
  });
}
