/// Which edition this build is — the only file that knows a flavor exists.
///
/// No screen ever asks "is this the pro build?": screens ask the edition for a
/// capability. If Pro is later sold as an in-app unlock instead of a second
/// app, this file changes and nothing else does.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appFlavor;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What this build may do, and what it calls itself.
@immutable
class Edition {
  const Edition({
    required this.displayName,
    required this.shortName,
    required this.isPro,
    required this.maxServers,
    required this.fleetView,
    required this.logWall,
    required this.crossServerPalette,
  });

  /// The name under the icon and in the app.
  final String displayName;

  /// The one word the chrome adds to a label: "Free", "Pro".
  final String shortName;

  /// Only for showing the edition itself — the brand row, the footer, the
  /// badges. Never for deciding what a screen may do.
  final bool isPro;

  /// How many servers may be paired, or null for as many as you like.
  final int? maxServers;

  /// "All servers": the fleet container table and the fleet alerts.
  final bool fleetView;
  final bool logWall;

  /// Cmd+K across every server rather than the current one.
  final bool crossServerPalette;

  static const Edition free = Edition(
    displayName: 'Doomsaday',
    shortName: 'Free',
    isPro: false,
    maxServers: 2,
    fleetView: false,
    logWall: false,
    crossServerPalette: false,
  );

  static const Edition pro = Edition(
    displayName: 'Doomsaday Pro',
    shortName: 'Pro',
    isPro: true,
    maxServers: null,
    fleetView: true,
    logWall: true,
    crossServerPalette: true,
  );

  /// The name with the edition spelled out, as the Preferences card shows
  /// it: "Doomsaday Free", "Doomsaday Pro". [displayName] is the name under
  /// the icon, which on Free is just "Doomsaday".
  String get editionName => isPro ? displayName : '$displayName $shortName';

  /// Whether one more may be paired when [paired] are paired already.
  bool allowsAnotherServer(int paired) =>
      maxServers == null || paired < maxServers!;
}

const String _define = String.fromEnvironment('EDITION');

/// True in the `pro` flavor. A compile-time constant, so the Pro-only branches
/// guarded by it fold away in the free build.
const bool buildIsPro =
    appFlavor == 'pro' || (appFlavor == null && _define == 'pro');

/// This build's edition, resolved at compile time from the flavor.
const Edition currentEdition = buildIsPro ? Edition.pro : Edition.free;

/// The same rule as [buildIsPro], written once more as a function so a test can
/// exercise flavors and defines this build does not have. The test also asserts
/// the two agree, so they cannot drift.
Edition editionFrom({String? flavor, String define = ''}) =>
    flavor == 'pro' || (flavor == null && define == 'pro')
    ? Edition.pro
    : Edition.free;

/// Every screen reads the edition through this, so a test can override it.
final editionProvider = Provider<Edition>((ref) => currentEdition);
