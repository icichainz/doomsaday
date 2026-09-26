/// The `app-polish` round: one name for this device, `/pair` as a dialog from
/// 600 up, the stroke glyphs everywhere, the Images seed, the phone Server
/// settings, and the desktop Devices and Activity pages.
library;

import 'dart:io';

import 'package:doomsaday/data/mock_seed.dart';
import 'package:doomsaday/data/models.dart';
import 'package:doomsaday/data/this_device.dart';
import 'package:doomsaday/edition/edition.dart';
import 'package:doomsaday/edition/server_limit.dart';
import 'package:doomsaday/features/devices/devices_screen.dart';
import 'package:doomsaday/features/servers/servers_screen.dart';
import 'package:doomsaday/widgets/buttons.dart';
import 'package:doomsaday/widgets/desktop.dart';
import 'package:doomsaday/widgets/stroke_icons.dart';
import 'package:doomsaday/widgets/surfaces.dart';
import 'package:doomsaday/widgets/table.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';

/// Material icons `lib/` may still name, each with the reason the stroke set
/// cannot stand in. Empty: every icon the app draws is a design glyph now.
const Map<String, String> materialIconAllowList = <String, String>{};

void main() {
  setUpAll(loadAppFonts);

  group('this device has one name', () {
    test('it follows the platform and, on iOS, the screen', () {
      expect(thisDeviceLabel(platform: TargetPlatform.macOS), 'This Mac');
      expect(
        thisDeviceLabel(
          platform: TargetPlatform.iOS,
          screen: const Size(1024, 1366),
        ),
        'This iPad',
      );
      expect(
        thisDeviceLabel(
          platform: TargetPlatform.iOS,
          screen: const Size(390, 844),
        ),
        'This phone',
      );
      expect(thisDeviceLabel(platform: TargetPlatform.android), 'This phone');
      expect(
        thisDeviceLabel(platform: TargetPlatform.macOS, capitalized: false),
        'this Mac',
      );
    });

    test('the demo seed pairs this device under that name', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final MockWorld world = seedProduction();
        final DeviceInfo self = world.devices.firstWhere(
          (DeviceInfo d) => d.isSelf,
        );
        expect(self.name, 'This Mac');
        expect(world.selfDeviceName, 'This Mac');
        for (final MockWorld w in <MockWorld>[
          seedProduction(),
          seedStaging(),
        ]) {
          for (final ActivityEntry e in w.activity) {
            if (e.deviceId == 'dev-1') expect(e.deviceName, 'This Mac');
          }
        }
        expect(
          world.devices.where((DeviceInfo d) => d.name == 'This phone'),
          isEmpty,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('sidebar, Devices, Activity and Server settings agree', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await pumpApp(tester);

      goTo(tester, '/s/prod-eu-1/settings/devices');
      await settle(tester);
      expect(find.text('This Mac · Admin'), findsOneWidget);
      expect(find.text('This Mac'), findsOneWidget);
      expect(find.textContaining('This phone'), findsNothing);

      goTo(tester, '/s/prod-eu-1/settings/activity');
      await settle(tester);
      expect(find.text('nginx-proxy restarted from this Mac'), findsOneWidget);
      expect(find.text('This Mac · admin'), findsWidgets);

      goTo(tester, '/s/prod-eu-1/settings');
      await settle(tester);
      expect(find.text('Read-only on this Mac'), findsOneWidget);
      expect(find.textContaining('This phone'), findsNothing);

      await disposeApp(tester);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('/pair opened as a route', () {
    for (final Size size in <Size>[tablet, desktop]) {
      testWidgets('at ${size.width.round()} it is the dialog over the '
          'default page', (WidgetTester tester) async {
        await pumpApp(tester, size: size);
        goTo(tester, '/pair');
        await settle(tester);

        expect(find.byType(ServersScreen), findsOneWidget);
        expect(find.byType(AppDialogShell), findsOneWidget);
        expect(find.text('PAIR A SERVER · STEP 1 OF 2'), findsOneWidget);
        expect(find.text('Pair a server agent'), findsOneWidget);
        expect(locationOf(tester), '/pair');

        // Dismissing it leaves the route.
        await tester.tapAt(const Offset(4, 4));
        await settle(tester);
        expect(find.byType(AppDialogShell), findsNothing);
        expect(locationOf(tester), '/');
        await disposeApp(tester);
      });
    }

    testWidgets('pairing from it lands on the new server, not back on /', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      goTo(tester, '/pair');
      await settle(tester);
      final Finder fields = find.byType(TextField);
      final int n = fields.evaluate().length;
      await tester.enterText(fields.at(n - 3), 'edge-3');
      await tester.enterText(
        fields.at(n - 2),
        'https://edge-3.example.com:8443',
      );
      await tester.enterText(fields.at(n - 1), 'pt_demo');
      await tester.tap(find.text('Test connection and pair'));
      await settle(tester);
      await tester.tap(find.text('Pin and pair'));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(locationOf(tester), '/s/edge-3/overview');
      await disposeApp(tester);
    });

    testWidgets('at the Free limit it is P2 over the page, not a bare page', (
      WidgetTester tester,
    ) async {
      await pumpApp(
        tester,
        size: desktop,
        edition: Edition.free,
        repository: pairedRepository(),
      );
      goTo(tester, '/pair');
      await settle(tester);
      expect(find.byType(ServersScreen), findsOneWidget);
      expect(find.byType(ServerLimitBody), findsOneWidget);
      expect(find.text('Test connection and pair'), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('below 600 it is still the pushed screen', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: phone);
      goTo(tester, '/pair');
      await settle(tester);
      expect(find.byType(AppDialogShell), findsNothing);
      expect(find.text('Pair a server agent'), findsOneWidget);
      expect(find.text('Servers'), findsWidgets); // the back link
      await disposeApp(tester);
    });
  });

  group('stroke glyphs', () {
    test('no Material icon is left in lib/ outside the allow-list', () {
      final RegExp icon = RegExp(r'\bIcons\.(\w+)');
      final List<String> found = <String>[];
      for (final FileSystemEntity f in Directory(
        'lib',
      ).listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final List<String> lines = f.readAsLinesSync();
        for (int i = 0; i < lines.length; i++) {
          if (lines[i].trimLeft().startsWith('//')) continue;
          for (final RegExpMatch m in icon.allMatches(lines[i])) {
            if (!materialIconAllowList.containsKey(m.group(1))) {
              found.add('${f.path}:${i + 1} Icons.${m.group(1)}');
            }
          }
        }
      }
      expect(found, isEmpty);
    });

    testWidgets('every glyph paints', (WidgetTester tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Wrap(
            children: <Widget>[
              for (final StrokeGlyph g in StrokeGlyph.values)
                StrokeIcon(g, key: ValueKey<StrokeGlyph>(g), size: 24),
            ],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      for (final StrokeGlyph g in <StrokeGlyph>[
        StrokeGlyph.play,
        StrokeGlyph.stop,
        StrokeGlyph.pause,
        StrokeGlyph.trash,
        StrokeGlyph.more,
        StrokeGlyph.history,
        StrokeGlyph.volumes,
        StrokeGlyph.networks,
        StrokeGlyph.link,
        StrokeGlyph.key,
      ]) {
        expect(find.byKey(ValueKey<StrokeGlyph>(g)), findsOneWidget);
      }
    });

    testWidgets('the sidebar footer draws the key', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      goTo(tester, '/s/prod-eu-1/overview');
      await settle(tester);
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is StrokeIcon && w.glyph == StrokeGlyph.key,
        ),
        findsOneWidget,
      );
      await disposeApp(tester);
    });
  });

  group('Images demo data', () {
    test('the summary is computed from the six seeded images', () {
      final MockWorld world = seedProduction();
      expect(world.images, hasLength(6));
      expect(world.imageSummary.totalCount, 6);
      expect(
        world.imageSummary.totalBytes,
        world.images.fold<int>(0, (int a, DockerImage i) => a + i.sizeBytes),
      );
      expect(
        world.imageSummary.reclaimableBytes,
        world.images
            .where((DockerImage i) => !i.inUse)
            .fold<int>(0, (int a, DockerImage i) => a + i.sizeBytes),
      );
    });

    testWidgets('the subtitle says what the boards say', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: phone);
      goTo(tester, '/s/prod-eu-1/resources');
      await settle(tester);
      expect(find.text('6 images · 1.9 GB · 597 MB unused'), findsOneWidget);
      await disposeApp(tester);
    });
  });

  group('phone Server settings', () {
    testWidgets('the read-only subtitle is one line at 390', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: phone);
      goTo(tester, '/s/prod-eu-1/settings');
      await settle(tester);
      final Finder line = find.text('Viewer role on the agent');
      expect(line, findsOneWidget);
      final RenderParagraph paragraph = tester.renderObject(line);
      final double lineHeight = paragraph.getFullHeightForCaret(
        const TextPosition(offset: 0),
      );
      expect(paragraph.size.height, lessThan(lineHeight * 1.5));
      await disposeApp(tester);
    });

    testWidgets('Unpair uses the danger border', (WidgetTester tester) async {
      await pumpApp(tester, size: phone);
      goTo(tester, '/s/prod-eu-1/settings');
      await settle(tester);
      final DoomButton unpair = tester.widget<DoomButton>(
        find.widgetWithText(DoomButton, 'Unpair this server'),
      );
      expect(unpair.tone, ButtonTone.dangerOutline);
      final Finder box = find.descendant(
        of: find.widgetWithText(DoomButton, 'Unpair this server'),
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).border != null,
        ),
      );
      final Border border =
          (tester.widget<Container>(box.first).decoration! as BoxDecoration)
                  .border!
              as Border;
      expect(border.top.color, const Color(0xFF4A2521));
      await disposeApp(tester);
    });
  });

  group('desktop Devices and Activity', () {
    testWidgets('Devices is a left-aligned table with the way back', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      goTo(tester, '/s/prod-eu-1/settings/devices');
      await settle(tester);
      expect(find.byType(DesktopHeader), findsOneWidget);
      expect(find.byType(DesktopBackLink), findsOneWidget);
      expect(find.text('Server settings'), findsOneWidget);
      expect(find.byType(DeviceTable), findsOneWidget);
      for (final String header in <String>['DEVICE', 'ROLE', 'LAST SEEN']) {
        expect(find.text(header), findsOneWidget);
      }
      expect(find.text('PUSH'), findsOneWidget);
      // Left-aligned: the title starts at the page's 32 px gutter after the
      // 264 px sidebar, not in a centred 720 column.
      expect(tester.getTopLeft(find.text('Paired devices')).dx, 264 + 32);

      await tester.tap(find.byType(DesktopBackLink));
      await settle(tester);
      expect(locationOf(tester), '/s/prod-eu-1/settings');
      await disposeApp(tester);
    });

    testWidgets('the more button opens the device actions', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      goTo(tester, '/s/prod-eu-1/settings/devices');
      await settle(tester);
      await tester.tap(
        find.byWidgetPredicate(
          (Widget w) =>
              w is DoomIconButton && w.semanticLabel == 'Actions for Ops iPad',
        ),
      );
      await settle(tester);
      expect(find.byType(DeviceActionsBody), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('Activity puts the filter and the chips on one row', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester);
      goTo(tester, '/s/prod-eu-1/settings/activity');
      await settle(tester);
      expect(find.byType(DesktopBackLink), findsOneWidget);
      expect(tester.getTopLeft(find.text('Activity log')).dx, 264 + 32);
      final double field = tester.getCenter(find.byType(TextField).first).dy;
      for (final String chip in <String>['All', 'Denied', 'Errors', 'Mine']) {
        final Finder f = find.widgetWithText(PillChip, chip);
        expect(f, findsOneWidget);
        expect((tester.getCenter(f).dy - field).abs(), lessThan(1));
      }
      expect(find.byType(DataTableView<DeviceInfo>), findsNothing);
      await disposeApp(tester);
    });
  });
}
