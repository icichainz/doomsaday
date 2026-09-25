/// Preferences in the running app: the cog in all three chromes, every
/// setting doing something real, the app lock, and nothing overflowing.
library;

import 'package:doomsaday/app/chrome.dart';
import 'package:doomsaday/app/rail.dart';
import 'package:doomsaday/app/sidebar.dart';
import 'package:doomsaday/data/biometrics.dart';
import 'package:doomsaday/data/preferences.dart';
import 'package:doomsaday/data/providers.dart';
import 'package:doomsaday/data/servers_repository.dart';
import 'package:doomsaday/edition/edition.dart';
import 'package:doomsaday/features/preferences/app_lock.dart';
import 'package:doomsaday/features/preferences/preferences_screen.dart';
import 'package:doomsaday/features/servers/servers_screen.dart';
import 'package:doomsaday/features/settings/server_settings_screen.dart';
import 'package:doomsaday/layout/layout.dart';
import 'package:doomsaday/theme/tokens.dart';
import 'package:doomsaday/widgets/buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';

/// A device that can run the prompt but where the person says no — a cancel,
/// a wrong finger, a timeout.
class RefusingAuthenticator implements Authenticator {
  const RefusingAuthenticator();

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> confirm(String reason) async => false;
}

/// The cog, wherever the chrome puts it: always a [DoomIconButton] labelled
/// "Preferences".
Finder get cog => find.byWidgetPredicate(
  (Widget w) => w is DoomIconButton && w.semanticLabel == 'Preferences',
);

Future<void> tapCog(WidgetTester tester) async {
  await tester.tap(cog.first, warnIfMissed: false);
  await settle(tester);
}

/// Scrolls [finder] into view on the phone's one scrolling screen.
Future<void> scrollTo(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
}

/// The ground colour the app is actually painting.
Color groundOf(WidgetTester tester) =>
    tester.element(find.byType(Scaffold).first).tokens.ground;

/// `Density.of` as every widget under the chrome sees it.
Density densityOf(WidgetTester tester) =>
    Density.of(tester.element(find.byType(AppChrome)));

void main() {
  setUpAll(loadAppFonts);

  group('the cog opens Preferences', () {
    testWidgets('at 390, in the Servers header', (WidgetTester tester) async {
      await pumpApp(tester, size: phone);
      expect(cog, findsOneWidget);
      // Board `Main`: 48 px, and left of the add button.
      expect(tester.getSize(cog).width, 48);
      final Finder add = find.byWidgetPredicate(
        (Widget w) => w is DoomIconButton && w.semanticLabel == 'Add server',
      );
      expect(tester.getCenter(cog).dx, lessThan(tester.getCenter(add).dx));

      await tapCog(tester);
      expect(find.byType(PreferencesScreen), findsOneWidget);
      expect(
        find.text('For this app on this phone, across every server'),
        findsOneWidget,
      );
      await disposeApp(tester);
    });

    testWidgets('at 800, from the rail item under Servers', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: tablet);
      await tester.tap(find.text('prod-eu-1').first);
      await settle(tester);
      expect(find.byType(NavRail), findsOneWidget);

      // T1 puts it under "Servers", so it is the lowest rail item.
      expect(
        tester.getCenter(find.text('Preferences')).dy,
        greaterThan(tester.getCenter(find.text('Servers')).dy),
      );
      await tester.tap(find.text('Preferences'));
      await settle(tester);
      expect(find.byType(PreferencesDialog), findsOneWidget);
      await disposeApp(tester);
    });

    for (final Edition edition in <Edition>[Edition.free, Edition.pro]) {
      testWidgets(
        'at 1440 in the sidebar footer, server scope, ${edition.shortName}',
        (WidgetTester tester) async {
          await pumpApp(tester, size: desktop, edition: edition);
          await tester.tap(find.text('prod-eu-1').first);
          await settle(tester);
          expect(find.byType(Sidebar), findsOneWidget);

          final Finder footerCog = find.descendant(
            of: find.byType(Sidebar),
            matching: cog,
          );
          expect(footerCog, findsOneWidget);
          // D1 draws it at 32 px, with a tooltip because it has no label.
          expect(tester.getSize(footerCog).width, 32);
          expect(
            tester.widget<DoomIconButton>(footerCog).tooltip,
            'Preferences',
          );

          await tester.tap(footerCog, warnIfMissed: false);
          await settle(tester);
          expect(find.byType(PreferencesDialog), findsOneWidget);
          await disposeApp(tester);
        },
      );

      testWidgets(
        'at 1440 in the sidebar footer, fleet scope, ${edition.shortName}',
        (WidgetTester tester) async {
          await pumpApp(tester, size: desktop, edition: edition);
          // `/` at 1440 is the "All servers" scope, locked on Free and not on
          // Pro — the cog is there either way, because Preferences is never
          // something an edition unlocks.
          expect(locationOf(tester), '/');
          final Finder footerCog = find.descendant(
            of: find.byType(Sidebar),
            matching: cog,
          );
          expect(footerCog, findsOneWidget);

          await tester.tap(footerCog, warnIfMissed: false);
          await settle(tester);
          expect(find.byType(PreferencesDialog), findsOneWidget);
          await disposeApp(tester);
        },
      );
    }

    testWidgets('the close button dismisses the dialog', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: desktop);
      await tapCog(tester);
      expect(find.byType(PreferencesDialog), findsOneWidget);

      final Finder close = find.byWidgetPredicate(
        (Widget w) =>
            w is DoomIconButton && w.semanticLabel == 'Close preferences',
      );
      await tester.tap(close, warnIfMissed: false);
      await settle(tester);
      expect(find.byType(PreferencesDialog), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('/preferences shows the dialog over the default page', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: desktop, startLocation: '/preferences');
      expect(find.byType(PreferencesDialog), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('/preferences below 600 is the pushed screen', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: phone, startLocation: '/preferences');
      expect(find.byType(PreferencesScreen), findsOneWidget);
      expect(find.byType(PreferencesDialog), findsNothing);
      await disposeApp(tester);
    });
  });

  group('every setting does something', () {
    testWidgets('Theme flips the ground colour', (WidgetTester tester) async {
      await pumpApp(tester, size: phone, themeMode: ThemeMode.light);
      expect(groundOf(tester), AppTokens.light.ground);

      await tapCog(tester);
      await tester.tap(find.text('Dark'));
      await settle(tester);
      expect(groundOf(tester), AppTokens.dark.ground);

      await tester.tap(find.text('Light'));
      await settle(tester);
      expect(groundOf(tester), AppTokens.light.ground);
      await disposeApp(tester);
    });

    testWidgets('Compact tightens a known row height', (
      WidgetTester tester,
    ) async {
      // 800 is where Automatic and Compact really differ: the touch layout
      // today, the pointer layout once Compact is chosen.
      await pumpApp(tester, size: tablet);
      expect(densityOf(tester).row, Density.touch.row);

      await tester.tap(find.text('prod-eu-1').first);
      await settle(tester);
      await tester.tap(find.text('Preferences'));
      await settle(tester);
      await tester.tap(find.text('Compact'));
      await settle(tester);

      expect(densityOf(tester).row, Density.pointer.row);
      expect(densityOf(tester).row, lessThan(Density.touch.row));
      await disposeApp(tester);
    });

    testWidgets('Compact never shrinks a target below 44 at 390', (
      WidgetTester tester,
    ) async {
      await pumpApp(
        tester,
        size: phone,
        preferences: const Preferences(density: DensityMode.compact),
      );
      await tapCog(tester);
      // Rows tighten…
      expect(densityOf(tester).row, lessThan(Density.touch.row));
      // …and nothing you tap goes under the design's 44 px minimum.
      expect(densityOf(tester).segment, 44);
      expect(densityOf(tester).iconButton, greaterThanOrEqualTo(44));
      await disposeApp(tester);
    });

    testWidgets('Refresh stats every reaches the stat streams', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: phone);
      expect(
        containerOf(tester).read(statsIntervalProvider),
        const Duration(seconds: 5),
      );

      await tapCog(tester);
      await scrollTo(tester, find.text('2 s'));
      await tester.tap(find.text('2 s'));
      await settle(tester);
      expect(
        containerOf(tester).read(statsIntervalProvider),
        const Duration(seconds: 2),
      );
      await disposeApp(tester);
    });

    testWidgets('Log lines kept per stream reaches the buffers', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: phone);
      await tapCog(tester);
      await scrollTo(tester, find.text('500'));
      await tester.tap(find.text('500'));
      await settle(tester);
      expect(
        containerOf(tester).read(preferencesProvider).logBuffer.lines,
        500,
      );
      await disposeApp(tester);
    });

    testWidgets('the Demo switch stays in step with the Servers buttons', (
      WidgetTester tester,
    ) async {
      // A repository with a real store and nothing paired: demo is off, and
      // it can be entered and left again the way the shipped app does it.
      final ServersRepository repo = await pumpApp(
        tester,
        size: phone,
        repository: emptyRepository(),
      );
      expect(repo.isDemo, isFalse);
      expect(find.text('Leave demo'), findsNothing);
      expect(find.text('Explore with demo data'), findsOneWidget);

      await tapCog(tester);
      await scrollTo(tester, find.text('Demo data'));
      await tester.tap(find.byType(Switch).last);
      await settle(tester);
      expect(repo.isDemo, isTrue);
      expect(repo.servers, hasLength(3));

      // Back on the Servers screen the demo buttons agree. The back link is
      // at the top of a screen we have scrolled down, so bring it back first.
      await scrollTo(tester, find.text('Servers'));
      await tester.tap(find.text('Servers'));
      await settle(tester);
      expect(find.text('Leave demo'), findsOneWidget);
      expect(find.text('prod-eu-1'), findsOneWidget);

      // And leaving demo there turns the switch back off.
      await tester.tap(find.text('Leave demo'));
      await settle(tester);
      expect(repo.isDemo, isFalse);
      expect(repo.servers, isEmpty);

      await tapCog(tester);
      await scrollTo(tester, find.text('Demo data'));
      expect(tester.widget<Switch>(find.byType(Switch).last).value, isFalse);
      await disposeApp(tester);
    });
  });

  group('the app lock', () {
    testWidgets('turning it on needs the prompt to pass', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: phone);
      await tapCog(tester);
      expect(find.text(lockSettingLabel), findsOneWidget);

      await tester.tap(find.byType(Switch).first);
      await settle(tester);
      expect(containerOf(tester).read(preferencesProvider).appLock, isTrue);
      // Turning it on does not lock the person out of the screen they are on.
      expect(find.text('Unlock Doomsaday'), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('a refused prompt leaves it off', (WidgetTester tester) async {
      await pumpApp(
        tester,
        size: phone,
        authenticator: const RefusingAuthenticator(),
      );
      await tapCog(tester);
      await tester.tap(find.byType(Switch).first);
      await settle(tester);
      expect(containerOf(tester).read(preferencesProvider).appLock, isFalse);
      await disposeApp(tester);
    });

    testWidgets('the lock screen covers a deep link', (
      WidgetTester tester,
    ) async {
      await pumpApp(
        tester,
        size: phone,
        preferences: const Preferences(appLock: true),
        startLocation: '/s/prod-eu-1/overview',
      );

      expect(find.text('Unlock Doomsaday'), findsOneWidget);
      // Nothing of the app is built behind it.
      expect(find.byType(ServersScreen), findsNothing);
      expect(find.text('prod-eu-1'), findsNothing);
      expect(cog, findsNothing);

      await tester.tap(find.text('Unlock with fingerprint or face'));
      await settle(tester);
      expect(find.text('Unlock Doomsaday'), findsNothing);
      expect(locationOf(tester), '/s/prod-eu-1/overview');
      await disposeApp(tester);
    });

    testWidgets('a cancelled unlock keeps it locked', (
      WidgetTester tester,
    ) async {
      await pumpApp(
        tester,
        size: phone,
        preferences: const Preferences(appLock: true),
        authenticator: const RefusingAuthenticator(),
      );
      expect(find.text('Unlock Doomsaday'), findsOneWidget);

      await tester.tap(find.text('Unlock with fingerprint or face'));
      await settle(tester);
      expect(find.text('Unlock Doomsaday'), findsOneWidget);
      // The refusal is said, not swallowed.
      expect(find.text('That did not unlock. Try again.'), findsOneWidget);
      expect(find.byType(ServersScreen), findsNothing);
      await disposeApp(tester);
    });

    test('five minutes in the background locks it again', () {
      final AppLockController lock = AppLockController(enabled: false);
      final DateTime start = DateTime(2026);

      lock.onLifecycle(AppLifecycleState.paused, now: start);
      lock.onLifecycle(
        AppLifecycleState.resumed,
        now: start.add(const Duration(minutes: 1)),
      );
      expect(lock.state, isFalse, reason: 'a minute away is not five');

      lock.onLifecycle(AppLifecycleState.paused, now: start);
      lock.onLifecycle(
        AppLifecycleState.resumed,
        now: start.add(kLockAfterBackground),
      );
      expect(lock.state, isTrue);

      // The biometric prompt itself makes the app inactive; that is not away.
      lock.unlock();
      lock.onLifecycle(AppLifecycleState.inactive, now: start);
      lock.onLifecycle(
        AppLifecycleState.resumed,
        now: start.add(const Duration(hours: 1)),
      );
      expect(lock.state, isFalse);
    });

    testWidgets('Security is hidden without biometrics', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: phone, authenticator: const NoBiometrics());
      await tapCog(tester);
      expect(find.byType(PreferencesScreen), findsOneWidget);
      // The section headers on the phone are upper case, as the board draws
      // them.
      expect(find.text('SECURITY'), findsNothing);
      expect(find.text(lockSettingLabel), findsNothing);
      // The rest of the screen is still there.
      expect(find.text('APPEARANCE'), findsOneWidget);
      expect(find.text('LIVE DATA'), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('and from the dialog too', (WidgetTester tester) async {
      await pumpApp(tester, size: desktop, authenticator: const NoBiometrics());
      await tapCog(tester);
      expect(find.byType(PreferencesDialog), findsOneWidget);
      expect(find.text('Security'), findsNothing);
      expect(find.text('Live data'), findsOneWidget);
      await disposeApp(tester);
    });
  });

  group('the edition card', () {
    testWidgets('Free names itself and offers Pro', (
      WidgetTester tester,
    ) async {
      await pumpApp(
        tester,
        size: phone,
        edition: Edition.free,
        repository: pairedRepository(),
      );
      await tapCog(tester);
      await scrollTo(tester, find.text('Doomsaday Free'));
      expect(find.text('Doomsaday Free'), findsOneWidget);
      expect(find.text('2 of 2 servers paired'), findsOneWidget);
      expect(find.text('PRO'), findsWidgets);

      await tester.tap(find.text('Get Pro'));
      await settle(tester);
      expect(find.text('Doomsaday Pro is not on sale yet'), findsOneWidget);
      await disposeApp(tester);
    });

    testWidgets('Pro names itself and offers nothing', (
      WidgetTester tester,
    ) async {
      await pumpApp(
        tester,
        size: phone,
        edition: Edition.pro,
        repository: pairedRepository(maxServers: null),
      );
      await tapCog(tester);
      await scrollTo(tester, find.text('Doomsaday Pro'));
      expect(find.text('Doomsaday Pro'), findsOneWidget);
      expect(find.text('Get Pro'), findsNothing);
      expect(find.textContaining('servers paired'), findsNothing);
      await disposeApp(tester);
    });

    testWidgets('About names the version and the agent API', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: phone);
      await tapCog(tester);
      final Finder version = find.text(
        '$kFallbackVersion · agent API $kAgentApiVersion',
      );
      await scrollTo(tester, version);
      expect(version, findsOneWidget);
      expect(find.text('Open-source licences'), findsOneWidget);
      await disposeApp(tester);
    });
  });

  group('Server settings gave Appearance back', () {
    testWidgets('no Appearance, and Unpair fits at 390x844', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, size: phone);
      goTo(tester, '/s/prod-eu-1/settings');
      await settle(tester);
      expect(find.byType(ServerSettingsScreen), findsOneWidget);
      expect(find.text('Appearance'), findsNothing);

      // The danger button is the last thing on the screen and no longer needs
      // a scroll to reach, now that the theme section is gone.
      final Finder unpair = find.text('Unpair this server');
      expect(unpair, findsOneWidget);
      final Rect box = tester.getRect(unpair);
      expect(box.bottom, lessThanOrEqualTo(844));
      expect(box.top, greaterThanOrEqualTo(0));
      await disposeApp(tester);
    });
  });

  group('nothing overflows', () {
    for (final Edition edition in <Edition>[Edition.free, Edition.pro]) {
      for (final ThemeMode mode in <ThemeMode>[
        ThemeMode.dark,
        ThemeMode.light,
      ]) {
        for (final Size size in <Size>[
          Size(390, 844),
          Size(800, 1200),
          Size(1100, 900),
          Size(1440, 900),
        ]) {
          testWidgets('Preferences ${edition.shortName} ${mode.name} at '
              '${size.width.round()}', (WidgetTester tester) async {
            await pumpApp(
              tester,
              size: size,
              edition: edition,
              themeMode: mode,
              startLocation: '/preferences',
            );
            expect(tester.takeException(), isNull);

            if (size.width >= 600) {
              // The dialog shows one section at a time, so walk them all.
              for (final PreferenceSection section
                  in PreferenceSection.values) {
                await tester.tap(find.text(section.label).first);
                await settle(tester);
                expect(
                  tester.takeException(),
                  isNull,
                  reason: '${section.label} at ${size.width}',
                );
              }
            } else {
              // The phone screen is one scroll; run it to the bottom.
              await tester.drag(
                find.byType(PreferencesScreen),
                const Offset(0, -900),
              );
              await settle(tester);
              expect(tester.takeException(), isNull);
            }
            await disposeApp(tester);
          });
        }
      }
    }
  });
}
