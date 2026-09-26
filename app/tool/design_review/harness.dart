/// The capture helpers shared by every design-review screenshot file:
/// `screens_test.dart` and the per-branch `screens_<branch>_test.dart`.
///
/// The whole app in demo mode at a board's exact size, device pixel ratio 1,
/// the real fonts, a `RepaintBoundary` around it, one PNG per board into
/// `--dart-define=REVIEW_OUT=` ([reviewOut]). [pumpApp] also takes
/// [Preferences] (for the app lock), extra provider overrides (for a loading
/// state that has to hold still) and can stop before the first settle. See `screens_test.dart` for how these files are run.
/// Nothing here is a test on its own.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:doomsaday/app/app.dart';
import 'package:doomsaday/data/biometrics.dart';
import 'package:doomsaday/data/mock_agent_api.dart';
import 'package:doomsaday/data/mock_seed.dart';
import 'package:doomsaday/data/models.dart';
import 'package:doomsaday/data/providers.dart';
import 'package:doomsaday/data/servers_repository.dart';
import 'package:doomsaday/edition/edition.dart';
import 'package:doomsaday/data/preferences.dart';
import 'package:doomsaday/data/this_device.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

export 'package:flutter_test/flutter_test.dart';

// ------------------------------------------------------------------- sizes

const Size kPhone = Size(390, 844);

/// The `AppSettings` board is a tall phone screen: it scrolls in the app and
/// the board draws all of it at once.
const Size kAppSettings = Size(390, 1320);
const Size kTablet = Size(834, 1194);
const Size kDesktop = Size(1440, 900);

const String kServer = 'prod-eu-1';
const String kApiGateway = '4f2a9c1e7b3d';

const String reviewOut = String.fromEnvironment(
  'REVIEW_OUT',
  defaultValue: '../review/app/unknown',
);
const String _materialFontsDefine = String.fromEnvironment('MATERIAL_FONTS');

final GlobalKey reviewRootKey = GlobalKey();

// -------------------------------------------------------------------- fonts

/// The app's bundled TTFs under the family names the theme asks for, plus the
/// icon font, so nothing renders as a box.
Future<void> loadFonts() async {
  const Map<String, List<String>> families = <String, List<String>>{
    'Bricolage Grotesque': <String>[
      'assets/fonts/BricolageGrotesque-500.ttf',
      'assets/fonts/BricolageGrotesque-700.ttf',
    ],
    'IBM Plex Sans': <String>[
      'assets/fonts/IBMPlexSans-400.ttf',
      'assets/fonts/IBMPlexSans-500.ttf',
      'assets/fonts/IBMPlexSans-600.ttf',
    ],
    'IBM Plex Mono': <String>[
      'assets/fonts/IBMPlexMono-400.ttf',
      'assets/fonts/IBMPlexMono-500.ttf',
    ],
  };
  for (final MapEntry<String, List<String>> entry in families.entries) {
    final FontLoader loader = FontLoader(entry.key);
    for (final String path in entry.value) {
      loader.addFont(_bytes(File(path)));
    }
    await loader.load();
  }

  final File icons = File(_materialIconsPath());
  if (icons.existsSync()) {
    final FontLoader loader = FontLoader('MaterialIcons');
    loader.addFont(_bytes(icons));
    await loader.load();
  } else {
    stdout.writeln('! MaterialIcons not found at ${icons.path}');
  }
}

Future<ByteData> _bytes(File file) async =>
    ByteData.sublistView(await file.readAsBytes());

/// `--dart-define=MATERIAL_FONTS=` when the runner passed one, otherwise the
/// SDK cache next to the `flutter_tester` this test is running in.
String _materialIconsPath() {
  if (_materialFontsDefine.isNotEmpty) {
    return '$_materialFontsDefine/MaterialIcons-Regular.otf';
  }
  final List<String> parts = Platform.resolvedExecutable.split('/');
  final int cache = parts.lastIndexOf('cache');
  if (cache > 0) {
    return <String>[
      ...parts.sublist(0, cache + 1),
      'artifacts',
      'material_fonts',
      'MaterialIcons-Regular.otf',
    ].join('/');
  }
  return '';
}

// ------------------------------------------------------------------ pumping

ServersRepository demoRepository() => ServersRepository(
  worlds: <MockWorld>[seedProduction(), seedStaging(), seedOffline()],
);

/// Two servers that are paired rather than sampled, so the edition's limit
/// counts — what the P1 and P2 boards are drawn against.
// The analyzer only counts `test/` as a test, and this file is deliberately
// outside it so the suite does not pick it up.
// ignore: invalid_use_of_visible_for_testing_member
ServersRepository pairedRepository() => ServersRepository.pairedMocks(
  <MockWorld>[seedProduction(), seedStaging()],
  maxServers: currentEdition.maxServers,
);

/// The whole app, with the edition left to the compile-time constant.
Future<void> pumpApp(
  WidgetTester tester, {
  required Size size,
  ThemeMode themeMode = ThemeMode.dark,
  ServersRepository? repository,
  Authenticator authenticator = const AlwaysConfirms(),
  Preferences? preferences,
  bool settleFirst = true,
  List<Override> overrides = const <Override>[],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  // The boards are drawn dark unless the name says Light, so a screen left on
  // "System" has to find a dark system under it.
  tester.platformDispatcher.platformBrightnessTestValue =
      themeMode == ThemeMode.light ? Brightness.light : Brightness.dark;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearPlatformBrightnessTestValue();
  });
  await tester.pumpWidget(
    RepaintBoundary(
      key: reviewRootKey,
      child: ProviderScope(
        overrides: <Override>[
          serversRepositoryProvider.overrideWithValue(
            repository ?? demoRepository(),
          ),
          authenticatorProvider.overrideWithValue(authenticator),
          preferencesProvider.overrideWith(
            (ref) => PreferencesController.inMemory(
              (preferences ?? const Preferences()).copyWith(
                themeMode: themeMode,
              ),
            ),
          ),
          ...overrides,
        ],
        child: const DoomsadayApp(),
      ),
    ),
  );
  if (settleFirst) await settle(tester);
}

/// The mock answers after a few hundred milliseconds and its log and stats
/// streams never go quiet, so this is fixed pumping rather than pumpAndSettle.
Future<void> settle(WidgetTester tester, {int frames = 8}) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

ProviderContainer appContainer(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(DoomsadayApp)));

Future<void> go(WidgetTester tester, String path) async {
  appContainer(tester).read(routerProvider).go(path);
  await settle(tester);
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder, warnIfMissed: false);
  await settle(tester);
}

Future<void> teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 6));
}

// -------------------------------------------------------------------- scene

/// prod-eu-1's mock world, so a board can set the scene before it opens.
MockWorld production(WidgetTester tester) =>
    (appContainer(tester).read(serversRepositoryProvider).api(kServer)
            as MockAgentApi)
        .world;

/// The six records the Activity boards draw (the phone's `Activity` and
/// `DesktopActivity`): four today, two yesterday, one refused and one
/// failed, from three devices. This device is named by [thisDeviceLabel],
/// so the phone boards say "This phone" and the 1440 ones "This Mac".
void seedBoardActivity(WidgetTester tester) {
  final DateTime now = DateTime.now();
  int n = 0;
  DateTime at(int daysAgo, int hour, int minute) {
    final DateTime t = DateTime(
      now.year,
      now.month,
      now.day - daysAgo,
      hour,
      minute,
    );
    // Early in the morning "today at 09:41" has not happened yet.
    return t.isAfter(now) ? now.subtract(Duration(minutes: 6 + 20 * n)) : t;
  }

  ActivityEntry entry(
    DateTime time,
    String action,
    String target,
    String device, {
    String result = 'ok',
  }) {
    n++;
    final (String id, String name, String role) = switch (device) {
      'ipad' => ('dev-2', 'Ops iPad', 'operator'),
      'pixel' => ('dev-3', 'On-call pixel', 'viewer'),
      _ => ('dev-1', thisDeviceLabel(), 'admin'),
    };
    return ActivityEntry(
      id: 'board-$n',
      time: time,
      action: action,
      target: target,
      result: result,
      deviceId: id,
      deviceName: name,
      role: role,
      status: result == 'ok' ? 200 : (result == 'denied' ? 403 : 500),
    );
  }

  production(tester).activity
    ..clear()
    ..addAll(<ActivityEntry>[
      entry(
        at(0, 9, 41),
        'POST /v1/containers/{id}/restart',
        'nginx-proxy',
        '',
      ),
      entry(at(0, 9, 12), 'WS /v1/containers/{id}/exec', 'api-gateway', ''),
      entry(
        at(0, 8, 55),
        'POST /v1/stacks/{name}/down',
        'monitoring',
        'pixel',
        result: 'denied',
      ),
      entry(at(0, 8, 30), 'POST /v1/images/pull', 'redis:7.2', 'ipad'),
      entry(
        at(1, 18, 4),
        'POST /v1/services/{id}/scale',
        'api',
        'ipad',
        result: 'error',
      ),
      entry(at(1, 16, 20), 'GET /v1/containers/{id}/env', 'api-gateway', ''),
    ]);
}

// ------------------------------------------------------------------ capture

Future<void> shoot(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final RenderRepaintBoundary boundary =
        reviewRootKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage();
    final ByteData? png = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    image.dispose();
    final File file = File('$reviewOut/$name.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(png!.buffer.asUint8List());
    stdout.writeln('  shot $name (${png.lengthInBytes} B)');
  });
}

/// One board: pump, drive, shoot, tear down.
///
/// [platform] is what the boards are drawn on: the phone screens are a phone,
/// and every 1440 board is the Mac that D1-D6 show. It only changes copy the
/// design makes platform-specific — "This Mac", the command glyph, Touch ID.
void board(
  String name,
  Size size,
  Future<void> Function(WidgetTester tester) drive, {
  ThemeMode themeMode = ThemeMode.dark,
  ServersRepository Function()? repository,
  Authenticator authenticator = const AlwaysConfirms(),
  TargetPlatform platform = TargetPlatform.android,
  Preferences? preferences,
  bool settleFirst = true,
  List<Override> overrides = const <Override>[],
}) {
  testWidgets(name, (WidgetTester tester) async {
    // Reset inside the body: the binding asserts the override is unset again
    // before any tearDown runs.
    if (platform != TargetPlatform.android) {
      debugDefaultTargetPlatformOverride = platform;
    }
    await pumpApp(
      tester,
      size: size,
      themeMode: themeMode,
      repository: repository?.call(),
      authenticator: authenticator,
      preferences: preferences,
      settleFirst: settleFirst,
      overrides: overrides,
    );
    await drive(tester);
    await shoot(tester, name);
    await teardown(tester);
    debugDefaultTargetPlatformOverride = null;
  });
}

/// The 1440 boards are drawn on a Mac.
void desktopBoard(
  String name,
  Future<void> Function(WidgetTester tester) drive, {
  ThemeMode themeMode = ThemeMode.dark,
  ServersRepository Function()? repository,
  Authenticator authenticator = const AlwaysConfirms(),
  Preferences? preferences,
}) => board(
  name,
  kDesktop,
  drive,
  themeMode: themeMode,
  repository: repository,
  authenticator: authenticator,
  platform: TargetPlatform.macOS,
  preferences: preferences,
);
