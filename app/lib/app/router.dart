import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/activity/activity_screen.dart';
import '../features/alerts/alerts_screen.dart';
import '../features/container_detail/container_detail_screen.dart';
import '../features/containers/containers_screen.dart';
import '../features/devices/devices_screen.dart';
import '../features/exec/exec_screen.dart';
import '../features/fleet/fleet_alerts_screen.dart';
import '../features/logs/logs_screen.dart';
import '../features/logwall/log_wall_screen.dart';
import '../features/overview/overview_screen.dart';
import '../features/pair/pair_agent_screen.dart';
import '../features/preferences/preferences_screen.dart';
import '../features/registries/registries_screen.dart';
import '../features/resources/resources_screen.dart';
import '../features/servers/servers_screen.dart';
import '../features/settings/server_settings_screen.dart';
import '../features/stacks/stacks_screen.dart';
import 'shell.dart';

final GlobalKey<NavigatorState> _rootKey = GlobalKey<NavigatorState>();

/// [initialLocation] is what "Open the app on" resolved to — the last server's
/// Overview, or `/`.
GoRouter createRouter({String initialLocation = '/'}) => GoRouter(
  navigatorKey: _rootKey,
  initialLocation: initialLocation,
  routes: <RouteBase>[
    GoRoute(
      // The Servers start screen below 1100; the fleet table above it, where
      // the sidebar already lists every server.
      path: '/',
      builder: (BuildContext context, GoRouterState state) =>
          const ServersScreen(),
    ),
    GoRoute(
      // Linkable, so `/preferences` opens them wherever the app is. Below 600
      // that is a pushed screen; from 600 it is the dialog over the default
      // page, which is what [PreferencesRoute] draws.
      path: '/preferences',
      parentNavigatorKey: _rootKey,
      builder: (BuildContext context, GoRouterState state) =>
          const PreferencesRoute(),
    ),
    GoRoute(
      path: '/pair',
      parentNavigatorKey: _rootKey,
      builder: (BuildContext context, GoRouterState state) =>
          const PairAgentScreen(),
    ),
    GoRoute(
      path: '/all/logwall',
      parentNavigatorKey: _rootKey,
      builder: (BuildContext context, GoRouterState state) =>
          const LogWallScreen(),
    ),
    GoRoute(
      path: '/all/alerts',
      parentNavigatorKey: _rootKey,
      builder: (BuildContext context, GoRouterState state) =>
          const FleetAlertsScreen(),
    ),
    // Every branch declares an `initialLocation`: go_router asserts that a
    // branch's default location is not parameterised, and all four of these
    // are. Nothing ever navigates to it — the bottom bar, the rail and the
    // sidebar all go to the full path of the selected server — but it has to
    // be a location the router can match, so the server id is a placeholder.
    StatefulShellRoute.indexedStack(
      builder:
          (
            BuildContext context,
            GoRouterState state,
            StatefulNavigationShell shell,
          ) => ServerShell(navigationShell: shell),
      branches: <StatefulShellBranch>[
        StatefulShellBranch(
          initialLocation: '/s/_/overview',
          routes: <RouteBase>[
            GoRoute(
              path: '/s/:serverId/overview',
              builder: (BuildContext context, GoRouterState state) =>
                  OverviewScreen(serverId: state.pathParameters['serverId']!),
            ),
          ],
        ),
        StatefulShellBranch(
          initialLocation: '/s/_/containers',
          routes: <RouteBase>[
            GoRoute(
              path: '/s/:serverId/containers',
              builder: (BuildContext context, GoRouterState state) =>
                  ContainersScreen(serverId: state.pathParameters['serverId']!),
              routes: <RouteBase>[
                // A child of the branch, but pushed onto the root navigator,
                // so it still covers the bottom bar on a phone while `go` to
                // it keeps the list underneath for back and for a resize.
                GoRoute(
                  path: ':containerId',
                  parentNavigatorKey: _rootKey,
                  builder: (BuildContext context, GoRouterState state) =>
                      ContainerDetailScreen(
                        serverId: state.pathParameters['serverId']!,
                        containerId: state.pathParameters['containerId']!,
                      ),
                  routes: <RouteBase>[
                    GoRoute(
                      path: 'logs',
                      parentNavigatorKey: _rootKey,
                      builder: (BuildContext context, GoRouterState state) =>
                          LogsScreen(
                            serverId: state.pathParameters['serverId']!,
                            containerId: state.pathParameters['containerId']!,
                          ),
                    ),
                    GoRoute(
                      path: 'shell',
                      parentNavigatorKey: _rootKey,
                      builder: (BuildContext context, GoRouterState state) =>
                          ExecScreen(
                            serverId: state.pathParameters['serverId']!,
                            containerId: state.pathParameters['containerId']!,
                          ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          initialLocation: '/s/_/stacks',
          routes: <RouteBase>[
            GoRoute(
              path: '/s/:serverId/stacks',
              builder: (BuildContext context, GoRouterState state) =>
                  StacksScreen(serverId: state.pathParameters['serverId']!),
            ),
          ],
        ),
        StatefulShellBranch(
          initialLocation: '/s/_/resources',
          routes: <RouteBase>[
            GoRoute(
              path: '/s/:serverId/resources',
              builder: (BuildContext context, GoRouterState state) =>
                  ResourcesScreen(serverId: state.pathParameters['serverId']!),
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/s/:serverId/alerts',
      parentNavigatorKey: _rootKey,
      builder: (BuildContext context, GoRouterState state) =>
          AlertsScreen(serverId: state.pathParameters['serverId']!),
    ),
    GoRoute(
      path: '/s/:serverId/settings',
      parentNavigatorKey: _rootKey,
      builder: (BuildContext context, GoRouterState state) =>
          ServerSettingsScreen(serverId: state.pathParameters['serverId']!),
      routes: <RouteBase>[
        GoRoute(
          path: 'registries',
          parentNavigatorKey: _rootKey,
          builder: (BuildContext context, GoRouterState state) =>
              RegistriesScreen(serverId: state.pathParameters['serverId']!),
        ),
        GoRoute(
          path: 'devices',
          parentNavigatorKey: _rootKey,
          builder: (BuildContext context, GoRouterState state) =>
              DevicesScreen(serverId: state.pathParameters['serverId']!),
        ),
        GoRoute(
          path: 'activity',
          parentNavigatorKey: _rootKey,
          builder: (BuildContext context, GoRouterState state) =>
              ActivityScreen(serverId: state.pathParameters['serverId']!),
        ),
      ],
    ),
  ],
);
