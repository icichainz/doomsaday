/// What the bottom bar, the rail and the sidebar all navigate to.
///
/// One list, so the three chromes can never drift apart.
library;

import '../widgets/stroke_icons.dart';

class Destination {
  const Destination({
    required this.label,
    required this.glyph,
    required this.path,
  });

  final String label;

  /// The design's own stroke icon, painted by [StrokeIcon].
  final StrokeGlyph glyph;

  /// `/s/<id>/overview`, with `<id>` filled in by [pathFor].
  final String path;
}

/// The four tab branches, in the order the shell route declares them.
const List<Destination> serverTabs = <Destination>[
  Destination(
    label: 'Overview',
    glyph: StrokeGlyph.overview,
    path: '/overview',
  ),
  Destination(
    label: 'Containers',
    glyph: StrokeGlyph.containers,
    path: '/containers',
  ),
  Destination(label: 'Stacks', glyph: StrokeGlyph.stacks, path: '/stacks'),
  Destination(
    label: 'Resources',
    glyph: StrokeGlyph.resources,
    path: '/resources',
  ),
];

/// The fifth tab, and the rail's last item: back out to the server list.
const Destination serversDestination = Destination(
  label: 'Servers',
  glyph: StrokeGlyph.servers,
  path: '/',
);

/// The rail's own last item: the app's preferences, which are not a server
/// destination at all — it opens the dialog rather than navigating.
const Destination preferencesDestination = Destination(
  label: 'Preferences',
  glyph: StrokeGlyph.cog,
  path: '/preferences',
);

/// The sidebar adds the two screens the phone reaches from the overview.
const List<Destination> serverExtras = <Destination>[
  Destination(label: 'Alerts', glyph: StrokeGlyph.alerts, path: '/alerts'),
  Destination(
    label: 'Settings',
    glyph: StrokeGlyph.settings,
    path: '/settings',
  ),
];

/// The "All servers" scope, which only exists at 1100 and up.
const List<Destination> fleetSections = <Destination>[
  Destination(label: 'Containers', glyph: StrokeGlyph.containers, path: '/'),
  Destination(
    label: 'Log wall',
    glyph: StrokeGlyph.logWall,
    path: '/all/logwall',
  ),
  Destination(label: 'Alerts', glyph: StrokeGlyph.alerts, path: '/all/alerts'),
];

/// `/s/prod-eu-1/containers/abc` → `prod-eu-1`, and `null` off a server route.
String? serverIdOf(String location) {
  final RegExpMatch? match = RegExp(r'^/s/([^/]+)').firstMatch(location);
  return match?.group(1);
}

/// The full path of a server destination.
String pathFor(String serverId, Destination destination) =>
    '/s/$serverId${destination.path}';

/// Whether [location] is inside [destination] for the given server.
bool isCurrent(String location, String serverId, Destination destination) {
  final String target = pathFor(serverId, destination);
  return location == target || location.startsWith('$target/');
}

/// Whether the window is showing the fleet rather than one server.
bool isFleet(String location) =>
    location == '/' ||
    location == '/preferences' ||
    location.startsWith('/all/');
