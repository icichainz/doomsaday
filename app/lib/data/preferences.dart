/// App preferences: one store for everything that is about **this app on this
/// device**, across every server.
///
/// `design/README.md`, "App preferences (app-wide, not per server)": theme,
/// density, the app lock, the live-data rates, what the app opens on and the
/// demo switch. Server settings stays about one agent.
///
/// Nothing secret lives here, so `shared_preferences` is the right store: the
/// device keys keep going to the platform keystore through
/// `flutter_secure_storage`.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Overridden in `main()` once SharedPreferences has loaded; tests leave it
/// null, which makes every preference an in-memory default.
final sharedPreferencesProvider = Provider<SharedPreferences?>((ref) => null);

/// How tightly the app draws, whatever the window is.
enum DensityMode {
  /// Today's rule: the pointer layout at 1100 and up, touch below it.
  automatic('Automatic'),

  /// The touch layout at every width.
  comfortable('Comfortable'),

  /// The pointer layout at every width — with the 44 px floor kept below 600,
  /// because a phone has no pointer to make small targets safe.
  compact('Compact');

  const DensityMode(this.label);

  final String label;

  static DensityMode parse(String? value) => values.firstWhere(
    (DensityMode m) => m.name == value,
    orElse: () => DensityMode.automatic,
  );
}

/// How often the stat streams push a new figure.
enum StatsInterval {
  twoSeconds(2, '2 s'),
  fiveSeconds(5, '5 s'),
  tenSeconds(10, '10 s');

  const StatsInterval(this.seconds, this.label);

  final int seconds;
  final String label;

  Duration get duration => Duration(seconds: seconds);

  /// The board's order, which puts the default in the middle.
  static const List<StatsInterval> ordered = <StatsInterval>[
    twoSeconds,
    fiveSeconds,
    tenSeconds,
  ];

  static StatsInterval parse(int? seconds) => values.firstWhere(
    (StatsInterval i) => i.seconds == seconds,
    orElse: () => StatsInterval.fiveSeconds,
  );
}

/// How many lines each live log buffer keeps in memory.
enum LogBuffer {
  small(500, '500'),
  medium(2000, '2,000'),
  large(10000, '10,000');

  const LogBuffer(this.lines, this.label);

  final int lines;
  final String label;

  static const List<LogBuffer> ordered = <LogBuffer>[small, medium, large];

  static LogBuffer parse(int? lines) => values.firstWhere(
    (LogBuffer b) => b.lines == lines,
    orElse: () => LogBuffer.medium,
  );
}

/// What the app shows when it opens.
enum StartScreen {
  lastServer('Last server'),
  serversList('Servers list');

  const StartScreen(this.label);

  final String label;

  static StartScreen parse(String? value) => values.firstWhere(
    (StartScreen s) => s.name == value,
    orElse: () => StartScreen.lastServer,
  );
}

/// Every app-wide preference, with the defaults the README's table names.
@immutable
class Preferences {
  const Preferences({
    this.themeMode = ThemeMode.system,
    this.density = DensityMode.automatic,
    this.appLock = false,
    this.statsInterval = StatsInterval.fiveSeconds,
    this.logBuffer = LogBuffer.medium,
    this.startScreen = StartScreen.lastServer,
    this.lastServerId,
  });

  /// System, Light, Dark.
  final ThemeMode themeMode;
  final DensityMode density;

  /// "Unlock with fingerprint or face", off by default.
  final bool appLock;
  final StatsInterval statsInterval;
  final LogBuffer logBuffer;
  final StartScreen startScreen;

  /// The server whose Overview was open last, for [StartScreen.lastServer].
  final String? lastServerId;

  Preferences copyWith({
    ThemeMode? themeMode,
    DensityMode? density,
    bool? appLock,
    StatsInterval? statsInterval,
    LogBuffer? logBuffer,
    StartScreen? startScreen,
    String? lastServerId,
  }) => Preferences(
    themeMode: themeMode ?? this.themeMode,
    density: density ?? this.density,
    appLock: appLock ?? this.appLock,
    statsInterval: statsInterval ?? this.statsInterval,
    logBuffer: logBuffer ?? this.logBuffer,
    startScreen: startScreen ?? this.startScreen,
    lastServerId: lastServerId ?? this.lastServerId,
  );

  @override
  bool operator ==(Object other) =>
      other is Preferences &&
      other.themeMode == themeMode &&
      other.density == density &&
      other.appLock == appLock &&
      other.statsInterval == statsInterval &&
      other.logBuffer == logBuffer &&
      other.startScreen == startScreen &&
      other.lastServerId == lastServerId;

  @override
  int get hashCode => Object.hash(
    themeMode,
    density,
    appLock,
    statsInterval,
    logBuffer,
    startScreen,
    lastServerId,
  );

  // ------------------------------------------------------------- storage

  static const String keyTheme = 'pref_theme';
  static const String keyDensity = 'pref_density';
  static const String keyAppLock = 'pref_app_lock';
  static const String keyStatsInterval = 'pref_stats_interval_seconds';
  static const String keyLogBuffer = 'pref_log_lines';
  static const String keyStartScreen = 'pref_start_screen';
  static const String keyLastServer = 'pref_last_server';

  /// Where the theme choice lived before Preferences existed: it was a
  /// section on Server settings and wrote this one key.
  static const String legacyThemeKey = 'theme_mode';

  static ThemeMode _theme(String? value) => switch (value) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    'system' => ThemeMode.system,
    _ => ThemeMode.system,
  };

  /// Reads everything, adopting the pre-Preferences theme key when the new
  /// one has never been written. Nobody loses the theme they chose.
  static Preferences read(SharedPreferences? prefs) {
    if (prefs == null) return const Preferences();
    final String? theme =
        prefs.getString(keyTheme) ?? prefs.getString(legacyThemeKey);
    return Preferences(
      themeMode: _theme(theme),
      density: DensityMode.parse(prefs.getString(keyDensity)),
      appLock: prefs.getBool(keyAppLock) ?? false,
      statsInterval: StatsInterval.parse(prefs.getInt(keyStatsInterval)),
      logBuffer: LogBuffer.parse(prefs.getInt(keyLogBuffer)),
      startScreen: StartScreen.parse(prefs.getString(keyStartScreen)),
      lastServerId: prefs.getString(keyLastServer),
    );
  }

  /// True when the old key is the only record of a theme choice, so the read
  /// above adopted it and it now has to be written under the new key.
  static bool needsThemeMigration(SharedPreferences? prefs) =>
      prefs != null &&
      !prefs.containsKey(keyTheme) &&
      prefs.containsKey(legacyThemeKey);
}

/// The one preferences store. Every setting writes straight through.
class PreferencesController extends StateNotifier<Preferences> {
  PreferencesController(this._prefs) : super(Preferences.read(_prefs)) {
    if (Preferences.needsThemeMigration(_prefs)) _migrateTheme();
  }

  /// A store with nothing behind it, for tests and the screenshot harness:
  /// the values are exactly what is passed and nothing is written anywhere.
  PreferencesController.inMemory(super.initial) : _prefs = null;

  final SharedPreferences? _prefs;

  /// Moves the old `theme_mode` value onto the new key and drops the old one,
  /// so the migration runs exactly once.
  Future<void> _migrateTheme() async {
    await _prefs?.setString(Preferences.keyTheme, state.themeMode.name);
    await _prefs?.remove(Preferences.legacyThemeKey);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    await _prefs?.setString(Preferences.keyTheme, mode.name);
  }

  Future<void> setDensity(DensityMode mode) async {
    state = state.copyWith(density: mode);
    await _prefs?.setString(Preferences.keyDensity, mode.name);
  }

  Future<void> setAppLock(bool value) async {
    state = state.copyWith(appLock: value);
    await _prefs?.setBool(Preferences.keyAppLock, value);
  }

  Future<void> setStatsInterval(StatsInterval interval) async {
    state = state.copyWith(statsInterval: interval);
    await _prefs?.setInt(Preferences.keyStatsInterval, interval.seconds);
  }

  Future<void> setLogBuffer(LogBuffer buffer) async {
    state = state.copyWith(logBuffer: buffer);
    await _prefs?.setInt(Preferences.keyLogBuffer, buffer.lines);
  }

  Future<void> setStartScreen(StartScreen screen) async {
    state = state.copyWith(startScreen: screen);
    await _prefs?.setString(Preferences.keyStartScreen, screen.name);
  }

  /// Remembered as the window moves between servers, for "Open the app on".
  Future<void> noteServer(String serverId) async {
    if (state.lastServerId == serverId) return;
    state = state.copyWith(lastServerId: serverId);
    await _prefs?.setString(Preferences.keyLastServer, serverId);
  }
}

final preferencesProvider =
    StateNotifierProvider<PreferencesController, Preferences>(
      (ref) => PreferencesController(ref.watch(sharedPreferencesProvider)),
    );

/// Drops the oldest entries so at most [keep] are held.
///
/// Every live log buffer in the app goes through this, so "Log lines kept per
/// stream" means the same thing on the phone's Logs screen, in the pane's Logs
/// tab and in each pane of the log wall.
void capLogBuffer<T>(List<T> lines, int keep) {
  if (keep <= 0 || lines.length <= keep) return;
  lines.removeRange(0, lines.length - keep);
}

/// Where the app opens, from the preference and what is actually paired.
///
/// "Last server" only wins while that server is still paired; a server that
/// was unpaired, or a first launch with nothing remembered, falls back to `/`,
/// which is the Servers list below 1100 and the fleet above it, as today.
String startLocation(Preferences prefs, List<Server> servers) {
  if (prefs.startScreen == StartScreen.serversList) return '/';
  final String? id = prefs.lastServerId;
  if (id == null || id.isEmpty) return '/';
  final bool paired = servers.any((Server s) => s.id == id);
  return paired ? '/s/$id/overview' : '/';
}
