import 'package:doomsaday/features/containers/containers_screen.dart';
import 'package:doomsaday/features/preferences/preferences_screen.dart';
import 'package:doomsaday/features/servers/servers_screen.dart';
import 'package:doomsaday/features/settings/server_settings_screen.dart';
import 'package:doomsaday/theme/app_theme.dart';
import 'package:doomsaday/theme/theme_controller.dart';
import 'package:doomsaday/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';

/// Wraps a screen in the real theme so colours and the theme switch are live.
///
/// Tab screens get a Scaffold because the server shell supplies one in the app.
Widget harness(Widget child, {bool shell = false}) {
  return ProviderScope(
    child: Consumer(
      builder: (BuildContext context, WidgetRef ref, Widget? _) {
        return MaterialApp(
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: ref.watch(themeModeProvider),
          home: shell ? Scaffold(body: child) : child,
        );
      },
    ),
  );
}

/// The mock answers after a few hundred milliseconds; two pumps let the future
/// complete and the rebuilt frame land.
Future<void> settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 600));
}

/// The list row a container's name sits in, so one row's own state label can
/// be asserted without depending on what the rows around it read.
Finder rowOf(String name) =>
    find.ancestor(of: find.text(name), matching: find.byType(Row)).first;

Color groundOf(WidgetTester tester) {
  final BuildContext context = tester.element(find.byType(Scaffold).first);
  return context.tokens.ground;
}

void main() {
  // Real metrics: the square placeholder glyph the test binding uses
  // otherwise makes every 'does this fit?' assertion meaningless.
  setUpAll(loadAppFonts);

  // The design is drawn for a 390x844 phone; the default 800x600 test window
  // would reflow every screen.
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1.0;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first
      ..resetPhysicalSize()
      ..resetDevicePixelRatio();
  });

  testWidgets('the servers list renders the three seeded servers', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness(const ServersScreen()));
    await settle(tester);

    expect(find.text('prod-eu-1'), findsOneWidget);
    expect(find.text('staging-1'), findsOneWidget);
    expect(find.text('backup-nas'), findsOneWidget);
    // The bare repository is demo mode, which the header says out loud.
    expect(find.text('Demo data · 3 sample agents · 2 online'), findsOneWidget);
    expect(find.text('Leave demo'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Agent unreachable. Last seen 2 h ago.'), findsOneWidget);
  });

  testWidgets('retrying the offline server shows the failure again', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness(const ServersScreen()));
    await settle(tester);

    await tester.tap(find.text('Retry'));
    await settle(tester);
    await settle(tester);

    expect(find.text('Agent unreachable. Last seen 2 h ago.'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
  });

  testWidgets('the filter chips filter the container list', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      harness(const ContainersScreen(serverId: 'prod-eu-1'), shell: true),
    );
    await settle(tester);

    expect(find.text('All 16'), findsOneWidget);
    expect(find.text('Running 14'), findsOneWidget);
    expect(find.text('Stopped 2'), findsOneWidget);
    expect(find.text('nginx-proxy'), findsOneWidget);
    expect(find.text('postgres-backup'), findsOneWidget);

    await tester.ensureVisible(find.text('Stopped 2'));
    await tester.tap(find.text('Stopped 2'));
    await settle(tester);

    expect(find.text('nginx-proxy'), findsNothing);
    expect(find.text('postgres-backup'), findsOneWidget);
    expect(find.text('legacy-import'), findsOneWidget);

    await tester.tap(find.text('Running 14'));
    await settle(tester);

    expect(find.text('nginx-proxy'), findsOneWidget);
    expect(find.text('postgres-backup'), findsNothing);
  });

  testWidgets(
    'stopping a container through the confirm sheet changes its state',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        harness(const ContainersScreen(serverId: 'prod-eu-1'), shell: true),
      );
      await settle(tester);

      // api-gateway passes its health check, so its row reads the health
      // rather than the uptime.
      expect(
        find.descendant(
          of: rowOf('api-gateway'),
          matching: find.text('Healthy'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.bySemanticsLabel('Stop api-gateway'));
      await tester.pumpAndSettle();

      expect(find.text('Stop api-gateway?'), findsOneWidget);
      expect(
        find.text('POST /v1/containers/4f2a9c1e7b3d/stop?timeout=10'),
        findsOneWidget,
      );

      await tester.tap(find.text('Stop container'));
      await tester.pumpAndSettle();
      await settle(tester);
      await settle(tester);

      expect(
        find.descendant(
          of: rowOf('api-gateway'),
          matching: find.text('Healthy'),
        ),
        findsNothing,
      );
      expect(find.text('All 16'), findsOneWidget);
      expect(find.text('Running 13'), findsOneWidget);
      expect(find.text('Stopped 3'), findsOneWidget);

      // Let the confirmation snack bar time out so no timer is left pending.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('Server settings no longer carries the theme switch', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      harness(const ServerSettingsScreen(serverId: 'prod-eu-1')),
    );
    await settle(tester);

    // Appearance moved to Preferences, where it belongs: it is about the app,
    // not about this agent.
    expect(find.text('Appearance'), findsNothing);
    expect(find.text('System'), findsNothing);
    expect(find.text('Unpair this server'), findsOneWidget);
  });

  testWidgets('the theme switch changes the ground colour', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness(const PreferencesScreen()));
    await settle(tester);

    expect(groundOf(tester), AppTokens.light.ground);

    await tester.ensureVisible(find.text('Dark'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();

    expect(groundOf(tester), AppTokens.dark.ground);

    await tester.ensureVisible(find.text('Light'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();

    expect(groundOf(tester), AppTokens.light.ground);
  });
}
