/// D1: the 264 px sidebar shown at 1100 and up.
///
/// It replaces the phone's separate Servers start screen: the brand, every
/// paired server, "Pair a server", the sections of whatever scope is selected,
/// and a footer naming this device and its role.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/models.dart';
import '../data/providers.dart';
import '../data/this_device.dart';
import '../edition/edition.dart';
import '../edition/pro_badge.dart';
import '../features/pair/pair_agent_screen.dart';
import '../features/preferences/preferences_screen.dart';
import '../layout/layout.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/buttons.dart';
import '../widgets/stroke_icons.dart';
import 'nav.dart';

class Sidebar extends ConsumerWidget {
  const Sidebar({super.key, required this.router, required this.location});

  /// The chrome sits above the Router, so `context.go` cannot find it here.
  final GoRouter router;
  final String location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final Edition edition = ref.watch(editionProvider);
    final AsyncValue<List<ServerCard>> cards = ref.watch(serverCardsProvider);
    final List<ServerCard> list = cards.valueOrNull ?? const <ServerCard>[];
    final String? serverId = serverIdOf(location);
    final bool fleet = isFleet(location);
    final int online = list.where((ServerCard c) => c.online).length;
    final bool demo = ref.watch(serversRepositoryProvider).isDemo;
    // "Servers · 2 of 2 on Free". Demo mode is not limited, so it keeps the
    // plain caption.
    final String serversCaption = edition.maxServers == null || demo
        ? 'Servers'
        : 'Servers · ${list.length} of ${edition.maxServers} on '
              '${edition.shortName}';
    final bool canPair = demo || edition.allowsAnotherServer(list.length);

    return Material(
      color: t.tabBar,
      child: Container(
        width: ShellMetrics.sidebarWidth,
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: t.border)),
        ),
        child: SafeArea(
          right: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.fromLTRB(22, 18, 22, 8),
                child: _Brand(),
              ),
              Expanded(
                child: ListView(
                  primary: false,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  children: <Widget>[
                    // The demo pill rides here rather than in the brand row,
                    // which has to fit "Doomsaday" and the PRO badge in 264 px
                    // whatever else is going on.
                    _Caption(
                      serversCaption,
                      trailing: demo ? const _DemoPill() : null,
                    ),
                    SidebarRow(
                      glyph: StrokeGlyph.overview,
                      label: 'All servers',
                      pro: !edition.fleetView,
                      trailing: cards.hasValue
                          ? '$online of ${list.length}'
                          : null,
                      selected: fleet,
                      onTap: () => router.go('/'),
                    ),
                    for (final ServerCard card in list)
                      SidebarRow(
                        dotColor: card.online ? t.accent : t.danger,
                        label: card.server.name,
                        trailing: card.online ? null : 'offline',
                        badge: card.online && card.stats != null
                            ? '${card.stats!.running + card.stats!.restarting}'
                            : null,
                        selected: !fleet && serverId == card.server.id,
                        onTap: () => router.go('/s/${card.server.id}/overview'),
                      ),
                    const SizedBox(height: 6),
                    _PairButton(
                      pro: !canPair,
                      onTap: () => showPairAgent(context, ref),
                    ),
                    if (fleet) ...<Widget>[
                      // `design/README.md`: the fleet scope's heading.
                      const _Caption('Across all servers'),
                      for (final Destination d in fleetSections)
                        SidebarRow(
                          glyph: d.glyph,
                          label: d.label,
                          pro: d.path == '/all/logwall'
                              ? !edition.logWall
                              : !edition.fleetView,
                          selected: d.path == '/'
                              ? location == '/'
                              : location.startsWith(d.path),
                          onTap: () => router.go(d.path),
                        ),
                    ] else if (serverId != null) ...<Widget>[
                      _Caption(serverId),
                      for (final Destination d in serverTabs)
                        SidebarRow(
                          glyph: d.glyph,
                          label: d.label,
                          selected: isCurrent(location, serverId, d),
                          onTap: () => router.go(pathFor(serverId, d)),
                        ),
                      for (final Destination d in serverExtras)
                        SidebarRow(
                          glyph: d.glyph,
                          label: d.label,
                          badge: d.label == 'Alerts'
                              ? _activeAlerts(ref, serverId)
                              : null,
                          selected: isCurrent(location, serverId, d),
                          onTap: () => router.go(pathFor(serverId, d)),
                        ),
                    ],
                  ],
                ),
              ),
              _Footer(serverId: serverId ?? _firstId(list)),
            ],
          ),
        ),
      ),
    );
  }

  static String? _firstId(List<ServerCard> list) =>
      list.isEmpty ? null : list.first.server.id;

  static String? _activeAlerts(WidgetRef ref, String serverId) {
    final List<AlertInfo>? alerts = ref
        .watch(alertsProvider(serverId))
        .valueOrNull;
    if (alerts == null) return null;
    final int active = alerts
        .where((AlertInfo a) => a.state == AlertState.active)
        .length;
    return active == 0 ? null : '$active';
  }
}

/// P3: the wordmark, and the PRO badge right beside it.
///
/// Nothing else shares this row. The demo pill used to, and between them the
/// 264 px sidebar could not fit "Doomsaday" — it truncated to "Dooms…" in
/// every Pro window.
class _Brand extends ConsumerWidget {
  const _Brand();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final Edition edition = ref.watch(editionProvider);
    return Row(
      children: <Widget>[
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: edition.isPro ? t.proRed : t.accent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            'D',
            style: TextStyle(
              fontFamily: AppFonts.display,
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: edition.isPro ? t.proInk : t.onAccent,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            'Doomsaday',
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: AppFonts.display,
              fontSize: 19,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
              color: t.text,
            ),
          ),
        ),
        if (edition.isPro) ...<Widget>[
          const SizedBox(width: 10),
          const ProBadge(),
        ],
      ],
    );
  }
}

/// The amber "Demo" pill, which sits on the Servers heading.
class _DemoPill extends StatelessWidget {
  const _DemoPill();

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: t.warningTint,
        borderRadius: AppShape.pill,
      ),
      child: Text(
        'Demo',
        style: AppText.tiny.copyWith(
          color: t.warning,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption(this.text, {this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 16, 10, 4),
      child: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              text.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
                color: t.mutedText,
              ),
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// One 38 px sidebar row, with hover, a visible focus ring and an optional
/// status dot, count badge or right-hand label.
class SidebarRow extends StatefulWidget {
  const SidebarRow({
    super.key,
    this.glyph,
    this.dotColor,
    required this.label,
    this.trailing,
    this.badge,
    this.pro = false,
    required this.selected,
    required this.onTap,
  });

  final StrokeGlyph? glyph;
  final Color? dotColor;
  final String label;
  final String? trailing;
  final String? badge;

  /// Marks a row this edition does not unlock: the PRO badge replaces whatever
  /// figure the row would otherwise carry.
  final bool pro;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<SidebarRow> createState() => _SidebarRowState();
}

class _SidebarRowState extends State<SidebarRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Color foreground = widget.selected ? t.accent : t.codeText;
    // D1 draws the current destination in the accent on the icon-button
    // fill, and the current server (a dot, not a glyph) in plain text on the
    // surface colour.
    final bool server = widget.dotColor != null;
    final Color? fill = widget.selected
        ? (server ? t.surface : t.iconButtonFill)
        : (_hover ? t.surface : null);
    final Color label = widget.selected
        ? (server ? t.text : t.accent)
        : t.codeText;
    return Semantics(
      button: true,
      selected: widget.selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            focusColor: t.surface,
            onTap: widget.onTap,
            child: Container(
              height: ShellMetrics.sidebarRowHeight,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: <Widget>[
                  if (widget.dotColor != null)
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: widget.dotColor,
                        shape: BoxShape.circle,
                      ),
                    )
                  else if (widget.glyph != null)
                    StrokeIcon(widget.glyph!, size: 17, color: foreground),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: widget.selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: label,
                      ),
                    ),
                  ),
                  if (widget.pro)
                    const ProBadge()
                  else if (widget.trailing != null)
                    Text(
                      widget.trailing!,
                      style: AppText.tiny.copyWith(color: t.mutedText),
                    ),
                  if (!widget.pro && widget.badge != null)
                    Container(
                      constraints: const BoxConstraints(minWidth: 20),
                      height: 20,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(
                        color: t.danger,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        widget.badge!,
                        style: AppText.pill.copyWith(color: t.onDanger),
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

class _PairButton extends StatelessWidget {
  const _PairButton({required this.pro, required this.onTap});

  /// True once the edition's servers are all paired, as in P1.
  final bool pro;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Semantics(
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: t.outlineBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              StrokeIcon(StrokeGlyph.plus, size: 16, color: t.text),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  'Pair a server',
                  overflow: TextOverflow.ellipsis,
                  style: AppText.small.copyWith(
                    color: t.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (pro) ...<Widget>[const SizedBox(width: 8), const ProBadge()],
            ],
          ),
        ),
      ),
    );
  }
}

class _Footer extends ConsumerWidget {
  const _Footer({required this.serverId});

  final String? serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    // The footer is about the machine in front of the person, so it names the
    // hardware rather than whatever the agent has this device stored as.
    String label = thisDeviceLabel();
    if (serverId != null) {
      final ServerRole role = ref.watch(roleProvider(serverId!));
      label = '$label · ${role.label}';
    }
    // P1: the Free build names itself in the footer.
    final Edition edition = ref.watch(editionProvider);
    if (!edition.isPro) label = '$label · ${edition.shortName}';
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 6, 18, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.border)),
      ),
      child: Row(
        children: <Widget>[
          StrokeIcon(StrokeGlyph.key, size: 15, color: t.mutedText),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: AppText.tiny.copyWith(color: t.mutedText),
            ),
          ),
          const SizedBox(width: 6),
          // D1's footer cog: in every scope, in both editions, because
          // Preferences is never something an edition unlocks.
          DoomIconButton(
            glyph: StrokeGlyph.cog,
            semanticLabel: 'Preferences',
            tooltip: 'Preferences',
            size: 32,
            radius: 8,
            filled: false,
            foreground: t.codeText,
            onPressed: () => openPreferences(context),
          ),
        ],
      ),
    );
  }
}
