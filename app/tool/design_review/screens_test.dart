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

import 'package:doomsaday/data/biometrics.dart';
import 'package:doomsaday/edition/edition.dart';
import 'package:doomsaday/features/logwall/log_wall_controller.dart';
import 'package:doomsaday/widgets/buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

// --------------------------------------------------------------------- main

void main() {
  setUpAll(() async {
    await loadFonts();
    stdout.writeln('edition ${currentEdition.displayName} -> $reviewOut');
  });

  group('phone, dark', () {
    board('Main', kPhone, (WidgetTester t) async {});
    board('PairAgent', kPhone, (WidgetTester t) async {
      await go(t, '/pair');
    });
    board('Dashboard', kPhone, (WidgetTester t) async {
      await go(t, '/s/$kServer/overview');
    });
    board('Alerts', kPhone, (WidgetTester t) async {
      await go(t, '/s/$kServer/alerts');
    });
    board('Containers', kPhone, (WidgetTester t) async {
      await go(t, '/s/$kServer/containers');
    });
    board('ContainerDetail', kPhone, (WidgetTester t) async {
      await go(t, '/s/$kServer/containers/$kApiGateway');
    });
    board('ConfirmStop', kPhone, (WidgetTester t) async {
      await go(t, '/s/$kServer/containers/$kApiGateway');
      await tap(t, find.text('Stop').first);
    });
    board('Logs', kPhone, (WidgetTester t) async {
      await go(t, '/s/$kServer/containers/$kApiGateway/logs');
    });
    board('Stacks', kPhone, (WidgetTester t) async {
      await go(t, '/s/$kServer/stacks');
    });
    board('Services', kPhone, (WidgetTester t) async {
      await go(t, '/s/$kServer/stacks');
      await tap(t, find.text('Swarm services').last);
    });
    board('Images', kPhone, (WidgetTester t) async {
      await go(t, '/s/$kServer/resources');
    });
    board('Volumes', kPhone, (WidgetTester t) async {
      await go(t, '/s/$kServer/resources');
      await tap(t, find.text('Volumes').last);
    });
    board('Networks', kPhone, (WidgetTester t) async {
      await go(t, '/s/$kServer/resources');
      await tap(t, find.text('Networks').last);
    });
    board('ServerSettings', kPhone, (WidgetTester t) async {
      await go(t, '/s/$kServer/settings');
    });
    // The board is drawn against a real Free install: two paired servers, no
    // demo data, and the theme left on System.
    board(
      'AppSettings',
      kAppSettings,
      (WidgetTester t) async {
        await go(t, '/preferences');
      },
      themeMode: ThemeMode.system,
      repository: pairedRepository,
    );
    board('Registries', kPhone, (WidgetTester t) async {
      await go(t, '/s/$kServer/settings/registries');
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
      await go(t, '/s/$kServer/overview');
    }, themeMode: ThemeMode.light);
    board('ContainersLight', kPhone, (WidgetTester t) async {
      await go(t, '/s/$kServer/containers');
    }, themeMode: ThemeMode.light);
  });

  group('tablet', () {
    board('DesktopTablet', kTablet, (WidgetTester t) async {
      await go(t, '/s/$kServer/overview');
    });
  });

  group('desktop', () {
    desktopBoard('DesktopOverview', (WidgetTester t) async {
      await go(t, '/s/$kServer/overview');
    });
    desktopBoard('DesktopOverviewLight', (WidgetTester t) async {
      await go(t, '/s/$kServer/overview');
    }, themeMode: ThemeMode.light);
    desktopBoard('DesktopContainers', (WidgetTester t) async {
      await go(t, '/s/$kServer/containers');
      await tap(t, find.text('api-gateway').first);
      final Finder logs = find.text('Logs');
      if (logs.evaluate().isNotEmpty) await tap(t, logs.last);
    });
    desktopBoard('DesktopConfirm', (WidgetTester t) async {
      await go(t, '/s/$kServer/containers');
      await tap(t, find.text('api-gateway').first);
      await tap(t, find.text('Stop').first);
    }, authenticator: const NoBiometrics());
    desktopBoard('DesktopResources', (WidgetTester t) async {
      await go(t, '/s/$kServer/resources');
    });
    desktopBoard('DesktopFleet', (WidgetTester t) async {
      await go(t, '/');
    });
    desktopBoard('DesktopPreferences', (WidgetTester t) async {
      // D7 is the dialog over the server overview, so the page underneath is
      // the one DesktopOverview shows.
      await go(t, '/s/$kServer/overview');
      await tap(
        t,
        find.byWidgetPredicate(
          (Widget w) => w is DoomIconButton && w.semanticLabel == 'Preferences',
        ),
      );
    }, themeMode: ThemeMode.system);
    desktopBoard('DesktopLogWall', (WidgetTester t) async {
      final LogWallController wall = appContainer(
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
      await go(t, '/all/logwall');
      await settle(t, frames: 12);
    });
  });

  group('editions', () {
    desktopBoard('ProLocked', (WidgetTester t) async {
      await go(t, '/all/logwall');
    }, repository: pairedRepository);
    // P2 is the sheet the pair action opens, not the `/pair` page a deep link
    // lands on, so this taps the button on the Servers screen.
    board('ProLimit', kPhone, (WidgetTester t) async {
      await tap(t, find.text('Pair a new server').last);
    }, repository: pairedRepository);
    desktopBoard('ProBrand', (WidgetTester t) async {
      await go(t, '/s/$kServer/overview');
    }, repository: pairedRepository);
  });
}
