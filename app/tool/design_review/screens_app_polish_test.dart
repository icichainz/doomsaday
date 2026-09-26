/// Screenshots for the `app-polish` round: the desktop Devices and Activity
/// pages (new boards), and the Light twins of the boards whose copy or data
/// changed — Server settings (the read-only subtitle, the Unpair border) and
/// Images (the seed's own figures).
///
/// Not part of the suite (it lives under `tool/`); run it by path, once per
/// edition:
///
///     flutter test --dart-define=EDITION=pro \
///       --dart-define=REVIEW_OUT=../review/app/pro \
///       tool/design_review/screens_app_polish_test.dart
library;

import 'dart:io';

import 'package:doomsaday/edition/edition.dart';
import 'package:flutter/material.dart';

import 'harness.dart';

void main() {
  setUpAll(() async {
    await loadFonts();
    stdout.writeln('edition ${currentEdition.displayName} -> $reviewOut');
  });

  for (final ThemeMode mode in const <ThemeMode>[
    ThemeMode.dark,
    ThemeMode.light,
  ]) {
    final String light = mode == ThemeMode.light ? 'Light' : '';
    group('app polish ${mode.name}', () {
      desktopBoard('DesktopDevices$light', (WidgetTester t) async {
        await go(t, '/s/$kServer/settings/devices');
      }, themeMode: mode);
      desktopBoard('DesktopActivity$light', (WidgetTester t) async {
        seedBoardActivity(t);
        await go(t, '/s/$kServer/settings/activity');
      }, themeMode: mode);
      // The dark ones are in screens_test.dart.
      if (mode == ThemeMode.light) {
        board('ServerSettingsLight', kPhone, (WidgetTester t) async {
          await go(t, '/s/$kServer/settings');
        }, themeMode: mode);
        board('ImagesLight', kPhone, (WidgetTester t) async {
          await go(t, '/s/$kServer/resources');
        }, themeMode: mode);
        desktopBoard('DesktopResourcesLight', (WidgetTester t) async {
          await go(t, '/s/$kServer/resources');
        }, themeMode: mode);
      }
    });
  }
}
