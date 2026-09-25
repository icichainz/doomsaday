import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../layout/layout.dart';
import '../theme/tokens.dart';
import '../widgets/stroke_icons.dart';
import 'nav.dart';

const List<Destination> _destinations = <Destination>[
  ...serverTabs,
  serversDestination,
];

/// The five-tab bar inside a server. The last tab leaves the shell and goes
/// back to the Servers list, exactly as the design links it.
///
/// From 600 up the rail or the sidebar is the navigation, so the bar is not
/// drawn at all and the branch content fills the pane.
class ServerShell extends StatelessWidget {
  const ServerShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    if (!WindowClass.of(context).usesBottomBar) {
      return Scaffold(backgroundColor: t.ground, body: navigationShell);
    }
    final String serverId =
        serverIdOf(GoRouterState.of(context).uri.path) ?? '';
    return Scaffold(
      backgroundColor: t.ground,
      body: navigationShell,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: t.tabBar,
          border: Border(top: BorderSide(color: t.border)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 76,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 8, 6, 12),
              child: Row(
                children: <Widget>[
                  for (int i = 0; i < _destinations.length; i++)
                    Expanded(
                      child: _TabItem(
                        destination: _destinations[i],
                        selected: i == navigationShell.currentIndex,
                        // Going to the full path rather than `goBranch`
                        // keeps the server id; the branch still keeps its own
                        // navigator and scroll position.
                        onTap: () => context.go(
                          i == _destinations.length - 1
                              ? '/'
                              : pathFor(serverId, _destinations[i]),
                        ),
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

class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final Destination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Color color = selected ? t.accent : t.mutedText;
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            StrokeIcon(destination.glyph, size: 22, color: color),
            const SizedBox(height: 4),
            Text(
              destination.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
