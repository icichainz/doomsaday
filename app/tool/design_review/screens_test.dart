/// Screenshots of the real app, one PNG per design board.
///
/// This is **not** part of the test suite: it lives under `tool/`, which
/// `flutter test` does not scan, and it is run by path:
///
///     flutter test --dart-define=EDITION=free \
///       --dart-define=REVIEW_OUT=../review/app/free \
///       tool/design_review/screens_test.dart
///
/// It pumps the whole widget tree in demo mode at each board's exact logical
/// size with a device pixel ratio of 1, loads the app's real fonts (plus
/// Flutter's MaterialIcons) so text is text rather than boxes, and captures a
/// `RepaintBoundary` wrapped around the app.
///
/// The edition is deliberately **not** overridden: it comes from the same
/// compile-time path the shipped app uses, so `--dart-define=EDITION=` picks
/// the flavor under review.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:doomsaday/app/app.dart';
import 'package:doomsaday/data/biometrics.dart';
import 'package:doomsaday/data/mock_seed.dart';
import 'package:doomsaday/data/providers.dart';
import 'package:doomsaday/data/servers_repository.dart';
import 'package:doomsaday/edition/edition.dart';
import 'package:doomsaday/data/preferences.dart';
import 'package:doomsaday/features/logwall/log_wall_controller.dart';
import 'package:doomsaday/widgets/buttons.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// ------------------------------------------------------------------- sizes

const Size kPhone = Size(390, 844);

/// The `AppSettings` board is a tall phone screen: it scrolls in the app and
/// the board draws all of it at once.
const Size kAppSettings = Size(390, 1320);
const Size kTablet = Size(834, 1194);
const Size kDesktop = Size(1440, 900);

const String kServer = 'prod-eu-1';
const String kApiGateway = '4f2a9c1e7b3d';

const String _outDefine = String.fromEnvironment(
  'REVIEW_OUT',
  defaultValue: '../review/app/unknown',
);
const String _materialFontsDefine = String.fromEnvironment('MATERIAL_FONTS');

final GlobalKey _rootKey = GlobalKey();

// -------------------------------------------------------------------- fonts

/// The app's bundled TTFs under the family names the theme asks for, plus the
/// icon font, so nothing renders as a box.
Future<void> _loadFonts() async {
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

ServersRepository _demo() => ServersRepository(
  worlds: <MockWorld>[seedProduction(), seedStaging(), seedOffline()],
);

/// Two servers that are paired rather than sampled, so the edition's limit
/// counts — what the P1 and P2 boards are drawn against.
// The analyzer only counts `test/` as a test, and this file is deliberately
// outside it so the suite does not pick it up.
// ignore: invalid_use_of_visible_for_testing_member
ServersRepository _paired() => ServersRepository.pairedMocks(<MockWorld>[
  seedProduction(),
  seedStaging(),
], maxServers: currentEdition.maxServers);

/// The whole app, with the edition left to the compile-time constant.
Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  ThemeMode themeMode = ThemeMode.dark,
  ServersRepository? repository,
  Authenticator authenticator = const AlwaysConfirms(),
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
      key: _rootKey,
      child: ProviderScope(
        overrides: <Override>[
          serversRepositoryProvider.overrideWithValue(repository ?? _demo()),
          authenticatorProvider.overrideWithValue(authenticator),
          preferencesProvider.overrideWith(
            (ref) => PreferencesController.inMemory(
              Preferences(themeMode: themeMode),
            ),
          ),
        ],
        child: const DoomsadayApp(),
      ),
    ),
  );
  await _settle(tester);
}

/// The mock answers after a few hundred milliseconds and its log and stats
/// streams never go quiet, so this is fixed pumping rather than pumpAndSettle.
Future<void> _settle(WidgetTester tester, {int frames = 8}) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(DoomsadayApp)));

Future<void> _go(WidgetTester tester, String path) async {
  _container(tester).read(routerProvider).go(path);
  await _settle(tester);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder, warnIfMissed: false);
  await _settle(tester);
}

Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 6));
}

// ------------------------------------------------------------------ capture

Future<void> _shoot(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final RenderRepaintBoundary boundary =
        _rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage();
    final ByteData? png = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    image.dispose();
    final File file = File('$_outDefine/$name.png');
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
}) {
  testWidgets(name, (WidgetTester tester) async {
    // Reset inside the body: the binding asserts the override is unset again
    // before any tearDown runs.
    if (platform != TargetPlatform.android) {
      debugDefaultTargetPlatformOverride = platform;
    }
    await _pump(
      tester,
      size: size,
      themeMode: themeMode,
      repository: repository?.call(),
      authenticator: authenticator,
    );
    await drive(tester);
    await _shoot(tester, name);
    await _teardown(tester);
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
}) => board(
  name,
  kDesktop,
  drive,
  themeMode: themeMode,
  repository: repository,
  authenticator: authenticator,
  platform: TargetPlatform.macOS,
);

// --------------------------------------------------------------------- main

void main() {
  setUpAll(() async {
    await _loadFonts();
    stdout.writeln('edition ${currentEdition.displayName} -> $_outDefine');
  });

  group('phone, dark', () {
    board('Main', kPhone, (WidgetTester t) async {});
    board('PairAgent', kPhone, (WidgetTester t) async {
      await _go(t, '/pair');
    });
    board('Dashboard', kPhone, (WidgetTester t) async {
      await _go(t, '/s/$kServer/overview');
    });
    board('Alerts', kPhone, (WidgetTester t) async {
      await _go(t, '/s/$kServer/alerts');
    });
    board('Containers', kPhone, (WidgetTester t) async {
      await _go(t, '/s/$kServer/containers');
    });
    board('ContainerDetail', kPhone, (WidgetTester t) async {
      await _go(t, '/s/$kServer/containers/$kApiGateway');
    });
    board('ConfirmStop', kPhone, (WidgetTester t) async {
      await _go(t, '/s/$kServer/containers/$kApiGateway');
      await _tap(t, find.text('Stop').first);
    });
    board('Logs', kPhone, (WidgetTester t) async {
      await _go(t, '/s/$kServer/containers/$kApiGateway/logs');
    });
    board('Stacks', kPhone, (WidgetTester t) async {
      await _go(t, '/s/$kServer/stacks');
    });
    board('Services', kPhone, (WidgetTester t) async {
      await _go(t, '/s/$kServer/stacks');
      await _tap(t, find.text('Swarm services').last);
    });
    board('Images', kPhone, (WidgetTester t) async {
      await _go(t, '/s/$kServer/resources');
    });
    board('Volumes', kPhone, (WidgetTester t) async {
      await _go(t, '/s/$kServer/resources');
      await _tap(t, find.text('Volumes').last);
    });
    board('Networks', kPhone, (WidgetTester t) async {
      await _go(t, '/s/$kServer/resources');
      await _tap(t, find.text('Networks').last);
    });
    board('ServerSettings', kPhone, (WidgetTester t) async {
      await _go(t, '/s/$kServer/settings');
    });
    // The board is drawn against a real Free install: two paired servers, no
    // demo data, and the theme left on System.
    board(
      'AppSettings',
      kAppSettings,
      (WidgetTester t) async {
        await _go(t, '/preferences');
      },
      themeMode: ThemeMode.system,
      repository: _paired,
    );
    board('Registries', kPhone, (WidgetTester t) async {
      await _go(t, '/s/$kServer/settings/registries');
    });
  });

  group('phone, light', () {
    board(
      'MainLight',
      kPhone,
      (WidgetTester t) async {},
      themeMode: ThemeMode.light,
    );
    board('DashboardLight', kPhone, (WidgetTester t) async {
      await _go(t, '/s/$kServer/overview');
    }, themeMode: ThemeMode.light);
    board('ContainersLight', kPhone, (WidgetTester t) async {
      await _go(t, '/s/$kServer/containers');
    }, themeMode: ThemeMode.light);
  });

  group('tablet', () {
    board('DesktopTablet', kTablet, (WidgetTester t) async {
      await _go(t, '/s/$kServer/overview');
    });
  });

  group('desktop', () {
    desktopBoard('DesktopOverview', (WidgetTester t) async {
      await _go(t, '/s/$kServer/overview');
    });
    desktopBoard('DesktopOverviewLight', (WidgetTester t) async {
      await _go(t, '/s/$kServer/overview');
    }, themeMode: ThemeMode.light);
    desktopBoard('DesktopContainers', (WidgetTester t) async {
      await _go(t, '/s/$kServer/containers');
      await _tap(t, find.text('api-gateway').first);
      final Finder logs = find.text('Logs');
      if (logs.evaluate().isNotEmpty) await _tap(t, logs.last);
    });
    desktopBoard('DesktopConfirm', (WidgetTester t) async {
      await _go(t, '/s/$kServer/containers');
      await _tap(t, find.text('api-gateway').first);
      await _tap(t, find.text('Stop').first);
    }, authenticator: const NoBiometrics());
    desktopBoard('DesktopResources', (WidgetTester t) async {
      await _go(t, '/s/$kServer/resources');
    });
    desktopBoard('DesktopFleet', (WidgetTester t) async {
      await _go(t, '/');
    });
    desktopBoard('DesktopPreferences', (WidgetTester t) async {
      // D7 is the dialog over the server overview, so the page underneath is
      // the one DesktopOverview shows.
      await _go(t, '/s/$kServer/overview');
      await _tap(
        t,
        find.byWidgetPredicate(
          (Widget w) => w is DoomIconButton && w.semanticLabel == 'Preferences',
        ),
      );
    }, themeMode: ThemeMode.system);
    desktopBoard('DesktopLogWall', (WidgetTester t) async {
      final LogWallController wall = _container(
        t,
      ).read(logWallProvider.notifier);
      for (final LogPaneRef pane in const <LogPaneRef>[
        LogPaneRef(
          serverId: kServer,
          containerId: kApiGateway,
          name: 'api-gateway',
        ),
        LogPaneRef(
          serverId: kServer,
          containerId: '7d1b5e0c88af',
          name: 'worker-queue',
        ),
        LogPaneRef(
          serverId: kServer,
          containerId: 'a91c3f70b214',
          name: 'nginx-proxy',
        ),
        LogPaneRef(
          serverId: 'staging-1',
          containerId: '11aa22bb33cc',
          name: 'staging-web',
        ),
      ]) {
        wall.add(pane);
      }
      await _go(t, '/all/logwall');
      await _settle(t, frames: 12);
    });
  });

  group('editions', () {
    desktopBoard('ProLocked', (WidgetTester t) async {
      await _go(t, '/all/logwall');
    }, repository: _paired);
    // P2 is the sheet the pair action opens, not the `/pair` page a deep link
    // lands on, so this taps the button on the Servers screen.
    board('ProLimit', kPhone, (WidgetTester t) async {
      await _tap(t, find.text('Pair a new server').last);
    }, repository: _paired);
    desktopBoard('ProBrand', (WidgetTester t) async {
      await _go(t, '/s/$kServer/overview');
    }, repository: _paired);
  });
}
