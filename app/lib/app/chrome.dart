/// The navigation chrome that lives outside the router.
///
/// Wrapping the router rather than sitting inside it is what lets the sidebar
/// stay put while a pushed screen changes, and keeps the phone's route tree
/// exactly as it was. A single [Navigator] above the chrome is the app's root
/// navigator, so a dialog covers the whole window — sidebar included — the way
/// D3 draws it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/preferences.dart';
import '../features/palette/jump_palette.dart';
import '../features/preferences/preferences_screen.dart';
import '../layout/layout.dart';
import '../theme/tokens.dart';
import '../widgets/filter_field.dart';
import 'mac_menu.dart';
import 'nav.dart';
import 'rail.dart';
import 'sidebar.dart';

/// Wraps the router's output with the rail or the sidebar, by window width.
class AppChrome extends StatelessWidget {
  const AppChrome({super.key, required this.router, required this.child});

  final GoRouter router;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Publishing the router above the root navigator is what lets a dialog —
    // the pair form, the jump palette — navigate with `context.go`, even
    // though it is pushed over the Router rather than inside it.
    return InheritedGoRouter(
      goRouter: router,
      child: _RootNavigatorHost(
        child: _LocationBuilder(
          router: router,
          builder: (BuildContext context, String location) =>
              _Frame(router: router, location: location, child: child),
        ),
      ),
    );
  }
}

/// Rebuilds the chrome when the route changes.
///
/// The chrome sits above the [Router], so the delegate's notification arrives
/// while the router below is still building. Applying it on the next frame
/// keeps the framework happy and costs the sidebar one frame of highlight.
class _LocationBuilder extends StatefulWidget {
  const _LocationBuilder({required this.router, required this.builder});

  final GoRouter router;
  final Widget Function(BuildContext context, String location) builder;

  @override
  State<_LocationBuilder> createState() => _LocationBuilderState();
}

class _LocationBuilderState extends State<_LocationBuilder> {
  late String _location = _read();

  @override
  void initState() {
    super.initState();
    widget.router.routerDelegate.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.router.routerDelegate.removeListener(_onChange);
    super.dispose();
  }

  String _read() {
    try {
      return widget.router.routerDelegate.currentConfiguration.uri.path;
    } on Object {
      return '/';
    }
  }

  void _onChange() {
    if (_read() == _location) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final String next = _read();
      if (mounted && next != _location) {
        setState(() => _location = next);
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _location);
}

/// One page, rebuilt whenever the chrome does, under a Navigator that owns the
/// whole window. Dialogs pushed with `useRootNavigator` land here.
class _RootNavigatorHost extends StatelessWidget {
  const _RootNavigatorHost({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Navigator(
      pages: <Page<void>>[
        MaterialPage<void>(
          key: const ValueKey<String>('chrome'),
          child: _MacMenuListener(child: child),
        ),
      ],
      onDidRemovePage: (Page<Object?> page) {},
    );
  }
}

/// Answers the Mac app menu's "Settings…" with the same dialog as the cog.
///
/// It sits just under the root navigator, so the dialog it opens covers the
/// whole window — sidebar included — exactly as D7 draws it.
class _MacMenuListener extends StatefulWidget {
  const _MacMenuListener({required this.child});

  final Widget child;

  @override
  State<_MacMenuListener> createState() => _MacMenuListenerState();
}

class _MacMenuListenerState extends State<_MacMenuListener> {
  @override
  void initState() {
    super.initState();
    MacMenu.listen(_open);
  }

  @override
  void dispose() {
    MacMenu.stop();
    super.dispose();
  }

  void _open() {
    if (mounted) openPreferences(context);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _Frame extends ConsumerWidget {
  const _Frame({
    required this.router,
    required this.location,
    required this.child,
  });

  final GoRouter router;
  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final WindowClass windowClass = WindowClass.of(context);

    // "Open the app on · Last server" needs to know which server that was.
    final String? current = serverIdOf(location);
    if (current != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => ref.read(preferencesProvider.notifier).noteServer(current),
      );
    }

    Widget body = child;
    if (windowClass.usesSidebar) {
      body = Row(
        children: <Widget>[
          Sidebar(router: router, location: location),
          Expanded(child: body),
        ],
      );
    } else if (windowClass.usesRail) {
      body = Row(
        children: <Widget>[
          NavRail(router: router, location: location),
          Expanded(child: body),
        ],
      );
    }
    body = ColoredBox(color: t.ground, child: body);

    // Cmd+, / Ctrl+, opens Preferences at every width, not only where the
    // desktop extras live: a keyboard is a keyboard.
    final Map<ShortcutActivator, VoidCallback>
    bindings = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.comma, meta: true): () =>
          openPreferences(context),
      const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
          openPreferences(context),
      if (windowClass.usesDesktopExtras) ...<ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            showJumpPalette(context, currentServerId: serverIdOf(location)),
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            showJumpPalette(context, currentServerId: serverIdOf(location)),
        const SingleActivator(LogicalKeyboardKey.slash): () =>
            ref.read(screenFilterProvider).focus(),
      },
    };
    return CallbackShortcuts(
      bindings: bindings,
      child: Focus(autofocus: true, skipTraversal: true, child: body),
    );
  }
}

/// Mouse, trackpad and stylus drag on every scrollable, with the scrollbar
/// visible wherever a pointer is the main input.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (!WindowClass.of(context).usesDesktopExtras) {
      return super.buildScrollbar(context, child, details);
    }
    switch (axisDirectionToAxis(details.direction)) {
      case Axis.vertical:
        return Scrollbar(
          controller: details.controller,
          thumbVisibility: true,
          child: child,
        );
      case Axis.horizontal:
        return child;
    }
  }
}
