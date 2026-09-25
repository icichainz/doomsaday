import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/preferences.dart';
import '../edition/edition.dart';
import '../features/preferences/app_lock.dart';
import '../layout/layout.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import 'chrome.dart';
import 'router.dart';

/// Where the app opens, resolved once in `main()` from "Open the app on" and
/// what is actually paired. Tests and the harness leave it at `/`.
final startLocationProvider = Provider<String>((ref) => '/');

/// The one router. Public so a test can read the current location.
final routerProvider = Provider<GoRouter>(
  (ref) => createRouter(initialLocation: ref.read(startLocationProvider)),
);

class DoomsadayApp extends ConsumerWidget {
  const DoomsadayApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final GoRouter router = ref.watch(routerProvider);
    final DensityMode density = ref.watch(
      preferencesProvider.select((Preferences p) => p.density),
    );
    return MaterialApp.router(
      title: ref.watch(editionProvider).displayName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ref.watch(themeModeProvider),
      scrollBehavior: const AppScrollBehavior(),
      routerConfig: router,
      // The density scope is above the chrome, so the single `Density.of`
      // lookup every widget already uses picks the preference up without one
      // screen being changed. The lock gate is above everything: while the app
      // is locked the router's output is not built at all, so a deep link has
      // nothing to land on.
      builder: (BuildContext context, Widget? child) => DensityScope(
        mode: density,
        child: AppLockGate(
          child: AppChrome(
            router: router,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
