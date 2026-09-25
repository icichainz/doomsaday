/// The app-wide preferences store: defaults, the round trip through
/// `shared_preferences`, the theme migration, density resolution, the log
/// buffer cap and where the app opens.
library;

import 'package:doomsaday/data/models.dart';
import 'package:doomsaday/data/preferences.dart';
import 'package:doomsaday/layout/layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Server _server(String id) => Server(
  id: id,
  name: id,
  baseUrl: 'https://$id:8443',
  certFingerprint: 'AA:BB',
  deviceId: 'dev-1',
  role: ServerRole.admin,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('defaults', () {
    test('are the ones the README table names', () {
      const Preferences prefs = Preferences();
      expect(prefs.themeMode, ThemeMode.system);
      expect(prefs.density, DensityMode.automatic);
      expect(prefs.appLock, isFalse);
      expect(prefs.statsInterval, StatsInterval.fiveSeconds);
      expect(prefs.statsInterval.duration, const Duration(seconds: 5));
      expect(prefs.logBuffer, LogBuffer.medium);
      expect(prefs.logBuffer.lines, 2000);
      expect(prefs.startScreen, StartScreen.lastServer);
      expect(prefs.lastServerId, isNull);
    });

    test('an empty store reads the same defaults', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SharedPreferences store = await SharedPreferences.getInstance();
      expect(Preferences.read(store), const Preferences());
    });

    test('a value the app no longer offers falls back', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        Preferences.keyDensity: 'roomy',
        Preferences.keyStatsInterval: 7,
        Preferences.keyLogBuffer: 42,
        Preferences.keyStartScreen: 'nowhere',
      });
      final SharedPreferences store = await SharedPreferences.getInstance();
      final Preferences prefs = Preferences.read(store);
      expect(prefs.density, DensityMode.automatic);
      expect(prefs.statsInterval, StatsInterval.fiveSeconds);
      expect(prefs.logBuffer, LogBuffer.medium);
      expect(prefs.startScreen, StartScreen.lastServer);
    });
  });

  group('the round trip', () {
    test('every setting comes back as it was written', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SharedPreferences store = await SharedPreferences.getInstance();
      final PreferencesController controller = PreferencesController(store);

      await controller.setThemeMode(ThemeMode.dark);
      await controller.setDensity(DensityMode.compact);
      await controller.setAppLock(true);
      await controller.setStatsInterval(StatsInterval.tenSeconds);
      await controller.setLogBuffer(LogBuffer.large);
      await controller.setStartScreen(StartScreen.serversList);
      await controller.noteServer('prod-eu-1');

      // In memory first…
      expect(controller.state.themeMode, ThemeMode.dark);
      expect(controller.state.density, DensityMode.compact);
      expect(controller.state.appLock, isTrue);
      expect(controller.state.statsInterval, StatsInterval.tenSeconds);
      expect(controller.state.logBuffer, LogBuffer.large);
      expect(controller.state.startScreen, StartScreen.serversList);
      expect(controller.state.lastServerId, 'prod-eu-1');

      // …and the same out of a store read fresh, as after a relaunch.
      final SharedPreferences again = await SharedPreferences.getInstance();
      await again.reload();
      expect(Preferences.read(again), controller.state);
    });

    test('a controller with no store keeps its values in memory', () async {
      final PreferencesController controller = PreferencesController(null);
      await controller.setLogBuffer(LogBuffer.small);
      expect(controller.state.logBuffer, LogBuffer.small);
    });
  });

  group('the theme migration', () {
    test('the old theme_mode key is adopted and then moved', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        Preferences.legacyThemeKey: 'dark',
      });
      final SharedPreferences store = await SharedPreferences.getInstance();

      // Read straight away: nobody loses the theme they chose on the old
      // Server settings screen.
      expect(Preferences.read(store).themeMode, ThemeMode.dark);
      expect(Preferences.needsThemeMigration(store), isTrue);

      final PreferencesController controller = PreferencesController(store);
      expect(controller.state.themeMode, ThemeMode.dark);
      // The migration is a write, so let it land.
      await Future<void>.delayed(Duration.zero);
      expect(store.getString(Preferences.keyTheme), 'dark');
      expect(store.containsKey(Preferences.legacyThemeKey), isFalse);
      expect(Preferences.needsThemeMigration(store), isFalse);
    });

    test('the new key wins when both are present', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        Preferences.legacyThemeKey: 'dark',
        Preferences.keyTheme: 'light',
      });
      final SharedPreferences store = await SharedPreferences.getInstance();
      expect(Preferences.read(store).themeMode, ThemeMode.light);
      expect(Preferences.needsThemeMigration(store), isFalse);
    });

    test('a store that never had a theme stays on System', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SharedPreferences store = await SharedPreferences.getInstance();
      expect(Preferences.read(store).themeMode, ThemeMode.system);
      expect(Preferences.needsThemeMigration(store), isFalse);
    });
  });

  group('density resolution', () {
    test('Automatic is exactly what the app did before', () {
      expect(Density.resolve(DensityMode.automatic, 390), Density.touch);
      expect(Density.resolve(DensityMode.automatic, 800), Density.touch);
      expect(Density.resolve(DensityMode.automatic, 1440), Density.pointer);
      // The breakpoint itself.
      expect(Density.resolve(DensityMode.automatic, 1099), Density.touch);
      expect(Density.resolve(DensityMode.automatic, 1100), Density.pointer);
    });

    test('Comfortable is the touch layout at every width', () {
      for (final double width in <double>[390, 800, 1440]) {
        expect(
          Density.resolve(DensityMode.comfortable, width),
          Density.touch,
          reason: 'at $width',
        );
      }
    });

    test('Compact is the pointer layout from 600 up', () {
      expect(Density.resolve(DensityMode.compact, 800), Density.pointer);
      expect(Density.resolve(DensityMode.compact, 1440), Density.pointer);
    });

    test('Compact below 600 tightens rows but keeps 44 px targets', () {
      final Density d = Density.resolve(DensityMode.compact, 390);
      expect(d.compact, isTrue);
      // Tighter than touch…
      expect(d.row, 46);
      expect(d.row, lessThan(Density.touch.row));
      // …but nothing you tap is under the design's minimum.
      for (final double target in <double>[
        d.button,
        d.iconButton,
        d.chip,
        d.field,
        d.segment,
        d.inlineLink,
      ]) {
        expect(target, greaterThanOrEqualTo(44));
      }
      // And the phone keeps its 20 px side padding.
      expect(d.gutter, 20);
    });

    test('nothing below 600 drops under 44 in any mode', () {
      for (final DensityMode mode in DensityMode.values) {
        for (final double width in <double>[320, 390, 599]) {
          final Density d = Density.resolve(mode, width);
          expect(
            <double>[d.button, d.iconButton, d.chip, d.field, d.segment],
            everyElement(greaterThanOrEqualTo(44)),
            reason: '${mode.name} at $width',
          );
        }
      }
    });
  });

  group('the log buffer cap', () {
    test('keeps the newest lines and drops the oldest', () {
      final List<int> lines = List<int>.generate(2500, (int i) => i);
      capLogBuffer(lines, LogBuffer.medium.lines);
      expect(lines.length, 2000);
      expect(lines.first, 500);
      expect(lines.last, 2499);
    });

    test('a shorter buffer than the cap is left alone', () {
      final List<int> lines = <int>[1, 2, 3];
      capLogBuffer(lines, 500);
      expect(lines, <int>[1, 2, 3]);
    });

    test('each size caps at its own figure', () {
      for (final LogBuffer buffer in LogBuffer.values) {
        final List<int> lines = List<int>.generate(
          buffer.lines + 10,
          (int i) => i,
        );
        capLogBuffer(lines, buffer.lines);
        expect(lines.length, buffer.lines, reason: buffer.label);
        expect(lines.last, buffer.lines + 9);
      }
    });
  });

  group('where the app opens', () {
    final List<Server> paired = <Server>[
      _server('prod-eu-1'),
      _server('staging-1'),
    ];

    test('the last server, when it is still paired', () {
      expect(
        startLocation(const Preferences(lastServerId: 'staging-1'), paired),
        '/s/staging-1/overview',
      );
    });

    test('the Servers list when that server was unpaired', () {
      expect(
        startLocation(const Preferences(lastServerId: 'gone-1'), paired),
        '/',
      );
    });

    test('the Servers list when nothing was ever opened', () {
      expect(startLocation(const Preferences(), paired), '/');
    });

    test('the Servers list when nothing is paired at all', () {
      expect(
        startLocation(
          const Preferences(lastServerId: 'prod-eu-1'),
          const <Server>[],
        ),
        '/',
      );
    });

    test('"Servers list" wins over a remembered server', () {
      expect(
        startLocation(
          const Preferences(
            startScreen: StartScreen.serversList,
            lastServerId: 'prod-eu-1',
          ),
          paired,
        ),
        '/',
      );
    });
  });
}
