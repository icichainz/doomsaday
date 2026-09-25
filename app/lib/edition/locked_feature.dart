/// P1 — what a Pro feature looks like on Free: the real header with a PRO
/// badge, a dimmed skeleton of the feature behind, and one panel explaining it.
///
/// One widget for all three locked features. Nothing here starts a request: the
/// locked page never builds the feature it stands in for.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/models.dart';
import '../data/providers.dart';
import '../layout/layout.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/buttons.dart';
import 'pro_badge.dart';

/// The shape of the dimmed placeholder drawn behind the panel.
enum ProSkeleton { panes, table }

/// The features Free locks, with the words the design gives each one.
enum ProFeature {
  fleet(
    header: 'All servers',
    name: 'All servers',
    subtitle: 'Every container on every paired server, in one table',
    skeleton: ProSkeleton.table,
    bullets: <String>[
      'Every container on every paired server in one sortable table',
      'Fleet figures, filters and actions without switching server',
      'Also in Pro: unlimited servers, the log wall and cross-server search',
    ],
  ),
  fleetAlerts(
    header: 'Alerts',
    name: 'Fleet alerts',
    subtitle: 'Every alert on every paired server, by severity',
    skeleton: ProSkeleton.table,
    bullets: <String>[
      'Every firing alert across the fleet, worst first',
      'The server that raised it, one click from the container',
      'Also in Pro: unlimited servers, the log wall and cross-server search',
    ],
  ),
  logWall(
    header: 'Log wall',
    name: 'Log wall',
    subtitle: 'Several live log streams side by side, across servers',
    skeleton: ProSkeleton.panes,
    bullets: <String>[
      'Up to 6 live log panes from any container on any server',
      'One filter across every pane, pause all at once',
      'Also in Pro: unlimited servers, the All servers view and cross-server '
          'search',
    ],
  ),
  crossServerSearch(
    header: 'Search every server',
    name: 'Cross-server search',
    subtitle: 'One Cmd+K across every paired server',
    skeleton: ProSkeleton.table,
    bullets: <String>[
      'Containers and stacks from every paired server in one list',
      'Jump straight to one without switching server first',
      'Also in Pro: unlimited servers, the All servers view and the log wall',
    ],
  );

  const ProFeature({
    required this.header,
    required this.name,
    required this.subtitle,
    required this.skeleton,
    required this.bullets,
  });

  /// The page title, which is the same as the Pro build's.
  final String header;

  /// How the panel names the feature: `<name> is part of Doomsaday Pro`.
  final String name;
  final String subtitle;
  final ProSkeleton skeleton;
  final List<String> bullets;
}

/// The whole page a locked feature shows on Free.
class LockedFeature extends ConsumerWidget {
  const LockedFeature({super.key, required this.feature});

  final ProFeature feature;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final double gutter = context.density.gutter;
    return Material(
      color: t.ground,
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(gutter, 26, gutter, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _Header(feature: feature),
              const SizedBox(height: 16),
              Expanded(
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: ExcludeSemantics(
                        child: IgnorePointer(
                          child: Opacity(
                            opacity: 0.55,
                            child: _SkeletonView(kind: feature.skeleton),
                          ),
                        ),
                      ),
                    ),
                    Center(
                      child: SingleChildScrollView(
                        child: ProPanel(
                          feature: feature,
                          onNotNow: () => _notNow(context, ref),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// "Not now" leaves the feature the way the window arrived at it: back if
  /// there is anything to go back to, otherwise the first paired server.
  static void _notNow(BuildContext context, WidgetRef ref) {
    final NavigatorState navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }
    final List<Server> servers = ref.read(serversRepositoryProvider).servers;
    GoRouter.of(
      context,
    ).go(servers.isEmpty ? '/' : '/s/${servers.first.id}/overview');
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.feature});

  final ProFeature feature;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                feature.header,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: AppFonts.display,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                  height: 1.1,
                  color: t.text,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                feature.subtitle,
                overflow: TextOverflow.ellipsis,
                style: AppText.small.copyWith(color: t.mutedText),
              ),
            ],
          ),
        ),
        const SizedBox(width: 14),
        const ProBadge(),
      ],
    );
  }
}

/// The same explanation on its own, for an entry point that has no page of its
/// own — the jump palette's "Search every server" row.
Future<void> showProFeature(BuildContext context, ProFeature feature) =>
    showDialog<void>(
      context: context,
      barrierColor: const Color(0xB8040709),
      builder: (BuildContext context) => Center(
        child: Material(
          color: Colors.transparent,
          child: ProPanel(
            feature: feature,
            onNotNow: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );

/// The 460 px explanation. Also shown on its own, as a dialog, from the jump
/// palette's "Search every server" row.
class ProPanel extends StatelessWidget {
  const ProPanel({super.key, required this.feature, required this.onNotNow});

  final ProFeature feature;
  final VoidCallback onNotNow;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Container(
        padding: const EdgeInsets.all(26),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: t.strongBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: t.proRed,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.lock_outline, size: 20, color: t.proInk),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        '${feature.name} is part of Doomsaday Pro',
                        style: TextStyle(
                          fontFamily: AppFonts.display,
                          fontSize: 21,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                          color: t.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Your servers and containers stay fully usable on '
                        'Free.',
                        style: AppText.small.copyWith(color: t.mutedText),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            for (final String bullet in feature.bullets)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(Icons.check, size: 16, color: t.accent),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        bullet,
                        style: AppText.body.copyWith(color: t.codeText),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: DoomButton(
                    'Get Doomsaday Pro',
                    tone: ButtonTone.primary,
                    height: 40,
                    radius: 10,
                    expand: true,
                    onPressed: () => openProUpgrade(context),
                  ),
                ),
                const SizedBox(width: 10),
                DoomButton(
                  'Not now',
                  height: 40,
                  radius: 10,
                  onPressed: onNotNow,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The dimmed shape of the feature, so the page still reads as that feature.
class _SkeletonView extends StatelessWidget {
  const _SkeletonView({required this.kind});

  final ProSkeleton kind;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final int columns = box.maxWidth >= 700 ? 2 : 1;
        return switch (kind) {
          ProSkeleton.panes => _grid(columns),
          ProSkeleton.table => const _SkeletonCard(lines: 8),
        };
      },
    );
  }

  static Widget _grid(int columns) => Column(
    children: <Widget>[
      for (int row = 0; row < 2; row++) ...<Widget>[
        if (row > 0) const SizedBox(height: 12),
        Expanded(
          child: Row(
            children: <Widget>[
              for (int column = 0; column < columns; column++) ...<Widget>[
                if (column > 0) const SizedBox(width: 12),
                const Expanded(child: _SkeletonCard(lines: 5)),
              ],
            ],
          ),
        ),
      ],
    ],
  );
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard({required this.lines});

  final int lines;

  /// The widths the design's placeholder rows use, so the block never looks
  /// like a real list.
  static const List<double> _widths = <double>[
    0.72,
    0.54,
    0.88,
    0.40,
    0.66,
    0.58,
    0.80,
    0.46,
  ];

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.codeBlock,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.faintDivider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            height: 42,
            decoration: BoxDecoration(
              color: t.infoNote,
              border: Border(bottom: BorderSide(color: t.faintDivider)),
            ),
          ),
          // A list rather than a column: a short window clips the placeholder
          // rows instead of overflowing.
          Expanded(
            child: ListView(
              primary: false,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                for (int i = 0; i < lines; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: _widths[i % _widths.length],
                      child: Container(
                        height: 8,
                        decoration: BoxDecoration(
                          color: t.faintDivider,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
