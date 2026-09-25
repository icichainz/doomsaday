/// T1: the 92 px icon-and-label rail shown from 600 to 1099.
///
/// Same destinations as the phone's bottom bar, including the last one that
/// leaves the server and goes back to the Servers list.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../edition/edition.dart';
import '../features/preferences/preferences_screen.dart';
import '../layout/layout.dart';
import '../theme/tokens.dart';
import '../widgets/stroke_icons.dart';
import 'nav.dart';

class NavRail extends ConsumerWidget {
  const NavRail({super.key, required this.router, required this.location});

  /// The chrome sits above the Router, so `context.go` cannot find it here.
  final GoRouter router;
  final String location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final Edition edition = ref.watch(editionProvider);
    final String? serverId = serverIdOf(location);
    return Material(
      color: t.tabBar,
      child: Container(
        width: ShellMetrics.railWidth,
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: t.border)),
        ),
        child: SafeArea(
          right: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 10),
            child: Column(
              children: <Widget>[
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: edition.isPro ? t.proRed : t.accent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'D',
                    style: TextStyle(
                      fontFamily: 'Bricolage Grotesque',
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                      color: edition.isPro ? t.proInk : t.onAccent,
                    ),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      children: <Widget>[
                        for (final Destination d in serverTabs)
                          _RailItem(
                            destination: d,
                            selected:
                                serverId != null &&
                                isCurrent(location, serverId, d),
                            onTap: serverId == null
                                ? null
                                : () => router.go(pathFor(serverId, d)),
                          ),
                      ],
                    ),
                  ),
                ),
                _RailItem(
                  destination: serversDestination,
                  selected: isFleet(location),
                  onTap: () => router.go('/'),
                ),
                // T1: "Preferences" under "Servers". It opens the dialog
                // rather than navigating, so the rail keeps its selection.
                _RailItem(
                  destination: preferencesDestination,
                  selected: false,
                  onTap: () => openPreferences(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RailItem extends StatefulWidget {
  const _RailItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final Destination destination;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Color color = widget.selected ? t.accent : t.mutedText;
    return Semantics(
      button: true,
      selected: widget.selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: widget.onTap,
            child: Container(
              width: ShellMetrics.railItemWidth,
              height: ShellMetrics.railItemHeight,
              decoration: BoxDecoration(
                color: widget.selected
                    ? t.iconButtonFill
                    : (_hover ? t.surface : null),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  StrokeIcon(widget.destination.glyph, size: 20, color: color),
                  const SizedBox(height: 5),
                  Text(
                    widget.destination.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: widget.selected
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
