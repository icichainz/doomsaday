/// Pumping the whole app at a chosen window width, which is what the adaptive
/// layout has to be tested through.
library;

import 'dart:io';

import 'package:doomsaday/app/app.dart';
import 'package:doomsaday/data/biometrics.dart';
import 'package:doomsaday/data/mock_agent_api.dart';
import 'package:doomsaday/data/mock_seed.dart';
import 'package:doomsaday/data/preferences.dart';
import 'package:doomsaday/data/providers.dart';
import 'package:doomsaday/data/server_store.dart';
import 'package:doomsaday/data/servers_repository.dart';
import 'package:doomsaday/edition/edition.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const Size phone = Size(390, 844);
const Size tablet = Size(800, 1200);
const Size desktop = Size(1440, 900);

/// Loads the app's real faces, so a test may assert on geometry.
///
/// Without this the test binding measures every glyph as a square of the font
/// size, which is nowhere near IBM Plex and makes "does this fit on one row?"
/// meaningless. Call it from `setUpAll`.
Future<void> loadAppFonts() async {
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
  for (final MapEntry<String, List<String>> family in families.entries) {
    final FontLoader loader = FontLoader(family.key);
    for (final String path in family.value) {
      loader.addFont(File(path).readAsBytes().then(ByteData.sublistView));
    }
    await loader.load();
  }
}

/// Sets the window for the rest of the test, and puts it back afterwards.
void useWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void resizeTo(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
}

/// The whole app, in demo mode, at [size].
///
/// The suite runs as Pro unless a test says otherwise: Pro is the edition that
/// has every screen, so the existing tests exercise all of them. The edition is
/// named here rather than inherited from whatever the test run was compiled
/// with, so it can never be accidental.
Future<ServersRepository> pumpApp(
  WidgetTester tester, {
  Size size = desktop,
  ServersRepository? repository,
  Authenticator authenticator = const AlwaysConfirms(),
  ThemeMode themeMode = ThemeMode.dark,
  Edition edition = Edition.pro,
  Preferences preferences = const Preferences(),
  String startLocation = '/',
}) async {
  useWindow(tester, size);
  final ServersRepository repo =
      repository ??
      ServersRepository(
        worlds: <MockWorld>[seedProduction(), seedStaging(), seedOffline()],
      );
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        editionProvider.overrideWithValue(edition),
        serversRepositoryProvider.overrideWithValue(repo),
        authenticatorProvider.overrideWithValue(authenticator),
        startLocationProvider.overrideWithValue(startLocation),
        preferencesProvider.overrideWith(
          (ref) => PreferencesController.inMemory(
            preferences.copyWith(themeMode: themeMode),
          ),
        ),
      ],
      child: const DoomsadayApp(),
    ),
  );
  await settle(tester);
  return repo;
}

/// The mock answers after a few hundred milliseconds; a few pumps let the
/// futures complete and the rebuilt frames land.
Future<void> settle(WidgetTester tester) async {
  for (int i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 400));
  }
}

/// A repository with a real (in-memory) store and nothing paired: demo mode
/// starts off and can be entered **and left again**, which a store-less
/// repository cannot do.
ServersRepository emptyRepository() =>
    ServersRepository(store: MemoryServerStore());

/// Two servers that are paired rather than sampled, so demo mode starts off
/// and an edition's limit counts.
// ignore: invalid_use_of_visible_for_testing_member
ServersRepository pairedRepository({int? maxServers = 2}) =>
    ServersRepository.pairedMocks(<MockWorld>[
      seedProduction(),
      seedStaging(),
    ], maxServers: maxServers);

MockAgentApi agentOf(ServersRepository repo, String serverId) =>
    repo.api(serverId) as MockAgentApi;

ProviderContainer containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(DoomsadayApp)));

/// Navigates the app's one router, the way the chrome does.
void goTo(WidgetTester tester, String path) =>
    containerOf(tester).read(routerProvider).go(path);

/// The path the router is on right now.
String locationOf(WidgetTester tester) => containerOf(
  tester,
).read(routerProvider).routerDelegate.currentConfiguration.uri.path;

/// Tears the app down and lets the demo agent's periodic timers expire, so the
/// test framework does not report them as pending.
Future<void> disposeApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 6));
}
