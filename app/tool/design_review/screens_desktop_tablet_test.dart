/// Screenshots for the desktop and tablet boards drawn in the
/// `desktop-tablet` round: stacks, volumes, networks, alerts, server settings,
/// registries, the pair dialog and the jump palette at 1440×900, and the
/// containers and stacks screens at the 834×1194 tablet size.
///
/// Run like `screens_test.dart`, once per edition:
///
///     flutter test --dart-define=EDITION=pro \
///       --dart-define=REVIEW_OUT=../review/app/pro \
///       tool/design_review/screens_desktop_tablet_test.dart
///
/// The boards are drawn against Pro. The free run captures the palette only,
/// which is the one board whose content changes with the edition (the
/// "Search every server" PRO row).
library;

import 'dart:io';

import 'package:doomsaday/edition/edition.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// Every board is captured twice, dark and `Light`.
void _both(
  String name,
  Future<void> Function(WidgetTester tester) drive, {
  Size size = kDesktop,
}) {
  for (final ThemeMode mode in const <ThemeMode>[
    ThemeMode.dark,
    ThemeMode.light,
  ]) {
    final String shot = mode == ThemeMode.light ? '${name}Light' : name;
    if (size == kDesktop) {
      desktopBoard(shot, drive, themeMode: mode);
    } else {
      board(shot, size, drive, themeMode: mode);
    }
  }
}

Future<void> _openPalette(WidgetTester t) async {
  await go(t, '/s/$kServer/overview');
  await t.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await t.sendKeyEvent(LogicalKeyboardKey.keyK);
  await t.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await settle(t);
  // The board shows nothing typed and api-gateway picked: three servers,
  // then nginx-proxy, then api-gateway.
  for (int i = 0; i < 4; i++) {
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
  }
  await settle(t);
}

void main() {
  setUpAll(() async {
    await loadFonts();
    stdout.writeln('edition ${currentEdition.displayName} -> $reviewOut');
  });

  if (!currentEdition.isPro) {
    group('free', () {
      desktopBoard('DesktopPalette', _openPalette);
    });
    return;
  }

  group('desktop', () {
    _both('DesktopStacks', (WidgetTester t) async {
      await go(t, '/s/$kServer/stacks');
    });
    _both('DesktopVolumes', (WidgetTester t) async {
      await go(t, '/s/$kServer/resources');
      await tap(t, find.text('Volumes').last);
    });
    _both('DesktopNetworks', (WidgetTester t) async {
      await go(t, '/s/$kServer/resources');
      await tap(t, find.text('Networks').last);
    });
    _both('DesktopAlerts', (WidgetTester t) async {
      await go(t, '/s/$kServer/alerts');
    });
    _both('DesktopSettings', (WidgetTester t) async {
      await go(t, '/s/$kServer/settings');
    });
    _both('DesktopRegistries', (WidgetTester t) async {
      await go(t, '/s/$kServer/settings/registries');
    });
    _both('DesktopPair', (WidgetTester t) async {
      await go(t, '/');
      await tap(t, find.text('Pair a server').first);
      // The dialog's three fields are the last three on screen; the fleet's
      // filter underneath is the first.
      final Finder fields = find.byType(EditableText);
      final int n = fields.evaluate().length;
      await t.enterText(fields.at(n - 3), 'edge-1');
      await t.enterText(fields.at(n - 2), 'https://edge-1.example.com:8443');
      await t.enterText(fields.at(n - 1), 'pt_7Hq2xWm9');
      await settle(t);
      await tap(t, find.text('Test connection and pair').last);
      await settle(t, frames: 6);
    });
    _both('DesktopPalette', _openPalette);
  });

  group('tablet', () {
    _both('TabletContainers', (WidgetTester t) async {
      await go(t, '/s/$kServer/containers');
    }, size: kTablet);
    _both('TabletStacks', (WidgetTester t) async {
      await go(t, '/s/$kServer/stacks');
    }, size: kTablet);
  });
}
