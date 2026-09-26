import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../../data/this_device.dart';
import '../../layout/layout.dart';
import '../../theme/app_theme.dart';
import '../../theme/state_colors.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/desktop.dart';
import '../../widgets/filter_field.dart';
import '../../widgets/page.dart';
import '../../widgets/primitives.dart';
import '../../widgets/state_views.dart';
import '../../widgets/stroke_icons.dart';
import '../../widgets/table.dart';
import '../palette/jump_palette.dart';

/// Screen 3 / D1 — Server overview.
class OverviewScreen extends ConsumerWidget {
  const OverviewScreen({super.key, required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final Server server = ref.watch(serverProvider(serverId));
    final AsyncValue<SystemInfo> info = ref.watch(systemProvider(serverId));
    final AsyncValue<SystemStats> stats = ref.watch(
      systemStatsProvider(serverId),
    );
    final AsyncValue<List<AlertInfo>> alerts = ref.watch(
      alertsProvider(serverId),
    );

    final int activeAlerts = alerts.maybeWhen(
      data: (List<AlertInfo> list) =>
          list.where((AlertInfo a) => a.state == AlertState.active).length,
      orElse: () => 0,
    );
    // `Docker 27.1 · up 41 days`. The agent's own version belongs to Server
    // settings, which is where it can be acted on; here it only pushed the
    // uptime out of the line.
    final String subtitle = info.maybeWhen(
      data: (SystemInfo i) =>
          'Docker ${i.dockerVersion} · '
          '${i.uptimeIsAgentOnly ? 'agent up' : 'up'} '
          '${formatDuration(i.uptime)}',
      orElse: () => 'Reading system info…',
    );

    final bool desktop = WindowClass.of(context).usesDesktopExtras;
    final Widget statCards = AsyncSection<SystemStats>(
      value: stats,
      onRetry: () => ref.invalidate(systemStatsProvider(serverId)),
      // Board `LoadingError`: the four stat cards as dimmed bars, laid out
      // the way the figures will be.
      loading: LoadingView.statCards(columns: desktop ? 4 : 2),
      builder: (SystemStats s) => _StatCards(
        serverId: serverId,
        stats: s,
        cores: info.valueOrNull?.cpuCores,
      ),
    );
    final Widget attention = _NeedsAttention(
      serverId: serverId,
      alerts: alerts,
      onRetry: () => ref.invalidate(alertsProvider(serverId)),
    );
    final Widget activity = _RecentActivity(serverId: serverId);

    // Board `LoadingError`: an agent that cannot be reached is one error card
    // with its reason, "Retry" and "Server settings", not one per section.
    final Object? failure = stats.error ?? info.error;
    final bool offline =
        failure is AgentException && failure.isUnreachable && !stats.hasValue;
    if (offline) {
      final Widget pill = const StatusPill('Offline', tone: PillTone.danger);
      final String host = Uri.tryParse(server.baseUrl)?.authority ?? '';
      final Widget card = ErrorView(
        error: failure,
        onRetry: () async {
          try {
            await ref.read(serversRepositoryProvider).retry(serverId);
          } on AgentException {
            // Still down: the providers below fail again and say so.
          }
          ref
            ..invalidate(systemProvider(serverId))
            ..invalidate(alertsProvider(serverId));
          refreshServer(ref);
        },
        onSettings: () => context.push('/s/$serverId/settings'),
      );
      if (desktop) {
        return DesktopPage(
          children: <Widget>[
            DesktopHeader(
              title: server.name,
              pill: pill,
              subtitle: host,
              actions: <Widget>[_JumpBox(serverId: serverId)],
            ),
            Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: card,
              ),
            ),
          ],
        );
      }
      return ShellPage(
        gap: 18,
        children: <Widget>[
          ScreenHeader(
            title: server.name,
            subtitleWidget: Row(
              children: <Widget>[
                pill,
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    host,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.monoSmall.copyWith(color: t.mutedText),
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              DoomIconButton(
                glyph: StrokeGlyph.settings,
                semanticLabel: 'Server settings',
                size: context.density.iconButton,
                onPressed: () => context.push('/s/$serverId/settings'),
              ),
              DoomIconButton(
                glyph: StrokeGlyph.alerts,
                semanticLabel: 'Alerts',
                size: context.density.iconButton,
                onPressed: () => context.push('/s/$serverId/alerts'),
              ),
            ],
          ),
          card,
        ],
      );
    }

    if (desktop) {
      return DesktopPage(
        children: <Widget>[
          DesktopHeader(
            title: server.name,
            pill: _connectionPill(stats),
            subtitle: subtitle,
            actions: <Widget>[_JumpBox(serverId: serverId)],
          ),
          statCards,
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) {
              final Widget side = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  attention,
                  const SizedBox(height: 20),
                  activity,
                ],
              );
              // Under about 1080 of content the table has no room left for a
              // 380 px column beside it, so the two stack instead.
              if (box.maxWidth < 1080) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _BusiestContainers(serverId: serverId),
                    const SizedBox(height: 20),
                    side,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(child: _BusiestContainers(serverId: serverId)),
                  const SizedBox(width: 20),
                  SizedBox(width: 380, child: side),
                ],
              );
            },
          ),
        ],
      );
    }

    final bool twoColumn = WindowClass.of(context).isMedium;
    final Widget pill = _connectionPill(stats);
    return ShellPage(
      gap: 18,
      children: <Widget>[
        ScreenHeader(
          title: server.name,
          // T1 draws the pill beside the title with the meta beneath; the
          // narrower phone board keeps both on the second line.
          pill: twoColumn ? pill : null,
          subtitleWidget: twoColumn
              ? Text(
                  subtitle,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.small.copyWith(color: t.mutedText),
                )
              : Row(
                  children: <Widget>[
                    pill,
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        subtitle,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.small.copyWith(color: t.mutedText),
                      ),
                    ),
                  ],
                ),
          actions: <Widget>[
            DoomIconButton(
              glyph: StrokeGlyph.settings,
              semanticLabel: 'Server settings',
              size: context.density.iconButton,
              onPressed: () => context.push('/s/$serverId/settings'),
            ),
            DoomIconButton(
              glyph: StrokeGlyph.alerts,
              semanticLabel: activeAlerts == 0
                  ? 'Alerts'
                  : 'Alerts, $activeAlerts active',
              badge: activeAlerts == 0 ? null : '$activeAlerts',
              size: context.density.iconButton,
              onPressed: () => context.push('/s/$serverId/alerts'),
            ),
          ],
        ),
        statCards,
        if (twoColumn) ...<Widget>[
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(child: attention),
                const SizedBox(width: 20),
                Expanded(child: activity),
              ],
            ),
          ),
          // T1 ends with the compact busiest-containers table.
          _BusiestContainers(serverId: serverId),
        ] else ...<Widget>[attention, activity],
      ],
    );
  }
}

/// D1's search box, which is the palette by another name.
class _JumpBox extends StatelessWidget {
  const _JumpBox({required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return SizedBox(
      width: 320,
      child: Semantics(
        button: true,
        label: 'Jump to a container, stack or server',
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => showJumpPalette(context),
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: t.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: t.border),
            ),
            child: Row(
              children: <Widget>[
                StrokeIcon(StrokeGlyph.search, size: 15, color: t.mutedText),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Jump to a container, stack or server',
                    overflow: TextOverflow.ellipsis,
                    style: AppText.small.copyWith(color: t.mutedText),
                  ),
                ),
                const KeyHint.command(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatCards extends StatelessWidget {
  const _StatCards({required this.serverId, required this.stats, this.cores});

  final String serverId;
  final SystemStats stats;
  final int? cores;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return StatCardGrid(
      cards: <Widget>[
        StatCard(
          label: 'Containers',
          figure: '${stats.running + stats.restarting}',
          suffix: 'running',
          note: '${stats.stopped} stopped · ${stats.restarting} restarting',
          noteColor: t.danger,
          onTap: () => context.go('/s/$serverId/containers'),
        ),
        StatCard(
          // The agent says whether it read the host or summed the containers,
          // so an approximation is labelled as one.
          label: stats.figuresAreApproximate
              ? 'CPU · from containers'
              : 'CPU${cores == null ? '' : ' · $cores cores'}',
          figure: formatPercent(stats.cpuPercent),
          meter: stats.cpuPercent / 100,
        ),
        StatCard(
          label: 'Memory',
          figure: formatGigabytes(stats.memoryUsedBytes),
          suffix: '/ ${formatGigabytes(stats.memoryTotalBytes)} GB',
          meter: stats.memoryFraction,
        ),
        StatCard(
          label: 'Disk',
          figure: formatGigabytes(stats.diskUsedBytes),
          suffix: '/ ${formatGigabytes(stats.diskTotalBytes)} GB',
          meter: stats.diskFraction,
        ),
      ],
    );
  }
}

/// D1's "Busiest containers" table, the six hungriest first.
class _BusiestContainers extends ConsumerWidget {
  const _BusiestContainers({required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<ContainerSummary>> all = ref.watch(
      containersProvider(serverId),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const SectionHeader('Busiest containers'),
        const SizedBox(height: 10),
        AsyncSection<List<ContainerSummary>>(
          value: all,
          onRetry: () => ref.invalidate(containersProvider(serverId)),
          loadingRows: 5,
          loadingRowHeight: 44,
          isEmpty: (List<ContainerSummary> list) => list.isEmpty,
          empty: const EmptyView(
            glyph: StrokeGlyph.containers,
            title: 'No containers',
            message: 'Nothing is deployed on this host yet.',
          ),
          builder: (List<ContainerSummary> list) {
            final List<ContainerSummary> busiest = <ContainerSummary>[...list]
              ..sort(
                (ContainerSummary a, ContainerSummary b) =>
                    b.cpuPercent.compareTo(a.cpuPercent),
              );
            return DataTableView<ContainerSummary>(
              rows: busiest.take(6).toList(growable: false),
              onTap: (ContainerSummary c) =>
                  context.go('/s/$serverId/containers/${c.id}'),
              columns: <TableColumn<ContainerSummary>>[
                TableColumn<ContainerSummary>(
                  label: 'Container',
                  cell: (BuildContext c, ContainerSummary row) =>
                      CellText(row.name, bold: true),
                ),
                TableColumn<ContainerSummary>(
                  label: 'Image',
                  width: 220,
                  optional: true,
                  cell: (BuildContext c, ContainerSummary row) =>
                      CellText(row.image, mono: true, muted: true),
                ),
                TableColumn<ContainerSummary>(
                  label: 'CPU',
                  width: 70,
                  numeric: true,
                  compare: (ContainerSummary a, ContainerSummary b) =>
                      a.cpuPercent.compareTo(b.cpuPercent),
                  cell: (BuildContext c, ContainerSummary row) => CellText(
                    row.state.isRunning ? formatPercent(row.cpuPercent) : '–',
                  ),
                ),
                TableColumn<ContainerSummary>(
                  label: 'Memory',
                  width: 90,
                  numeric: true,
                  optional: true,
                  compare: (ContainerSummary a, ContainerSummary b) =>
                      a.memoryBytes.compareTo(b.memoryBytes),
                  cell: (BuildContext c, ContainerSummary row) => CellText(
                    row.state.isRunning ? formatBytes(row.memoryBytes) : '–',
                  ),
                ),
                TableColumn<ContainerSummary>(
                  label: 'State',
                  width: 120,
                  cell: (BuildContext c, ContainerSummary row) => StateCell(
                    label: row.stateLabel,
                    color: containerStateColor(c.tokens, row.state),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _NeedsAttention extends StatelessWidget {
  const _NeedsAttention({
    required this.serverId,
    required this.alerts,
    required this.onRetry,
  });

  final String serverId;
  final AsyncValue<List<AlertInfo>> alerts;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return AsyncSection<List<AlertInfo>>(
      value: alerts,
      onRetry: onRetry,
      loadingRows: 2,
      loadingRowHeight: 60,
      builder: (List<AlertInfo> list) {
        // Critical first, then warning, then the most recent.
        final List<AlertInfo> active =
            list.where((AlertInfo a) => a.state == AlertState.active).toList()
              ..sort(compareAlertsByUrgency);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SectionHeader(
              'Needs attention',
              action: InkWell(
                onTap: () => context.push('/s/$serverId/alerts'),
                child: SizedBox(
                  height: context.density.inlineLink,
                  child: Align(
                    child: Text(
                      'All alerts',
                      style: AppText.buttonLabel.copyWith(color: t.accent),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            if (active.isEmpty)
              const EmptyView(
                glyph: StrokeGlyph.checkCircle,
                tone: EmptyTone.healthy,
                title: 'Nothing needs attention',
                message: 'No alert rule has fired on this server.',
              )
            else
              for (final AlertInfo alert in active)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _AttentionRow(serverId: serverId, alert: alert),
                ),
          ],
        );
      },
    );
  }
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({required this.serverId, required this.alert});

  final String serverId;
  final AlertInfo alert;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool critical = alert.severity == AlertSeverity.critical;
    return DoomCard(
      radius: 14,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      borderColor: critical ? t.dangerBorder : t.warningBorder,
      onTap: alert.targetKind == 'container'
          ? () => context.go('/s/$serverId/containers/${alert.targetId}')
          : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Row(
          children: <Widget>[
            StrokeIcon(
              StrokeGlyph.warning,
              size: 20,
              color: critical ? t.danger : t.warning,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  // The container is the headline; the rule is the sentence
                  // under it, one line each wherever it fits.
                  Text(
                    alert.attentionTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.rowTitle.copyWith(
                      color: t.text,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    alert.attentionDetail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.small.copyWith(color: t.mutedText),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            StrokeIcon(StrokeGlyph.chevronRight, size: 18, color: t.mutedText),
          ],
        ),
      ),
    );
  }
}

class _RecentActivity extends ConsumerWidget {
  const _RecentActivity({required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final AsyncValue<List<ActivityEntry>> activity = ref.watch(
      activityProvider(serverId),
    );
    // "…from this Mac" rather than whatever this device was paired under.
    final String selfId =
        ref.watch(meProvider(serverId)).valueOrNull?.deviceId ??
        ref.watch(serverProvider(serverId)).deviceId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const SectionHeader('Recent activity'),
        const SizedBox(height: 6),
        AsyncSection<List<ActivityEntry>>(
          value: activity,
          onRetry: () => ref.invalidate(activityProvider(serverId)),
          loadingRows: 3,
          loadingRowHeight: 36,
          isEmpty: (List<ActivityEntry> list) => list.isEmpty,
          empty: const EmptyView(
            glyph: StrokeGlyph.history,
            title: 'No activity yet',
            message: 'Actions taken from any paired device show up here.',
          ),
          builder: (List<ActivityEntry> list) {
            final List<ActivityEntry> shown = list.take(4).toList();
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (int i = 0; i < shown.length; i++)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      border: i == shown.length - 1
                          ? null
                          : Border(bottom: BorderSide(color: t.faintDivider)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: <Widget>[
                        SizedBox(
                          width: 44,
                          child: Text(
                            shown[i].at,
                            style: AppText.monoSmall.copyWith(
                              color: t.mutedText,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            shown[i].sentence(
                              selfDeviceId: selfId,
                              selfLabel: thisDeviceLabel(capitalized: false),
                            ),
                            style: AppText.label.copyWith(color: t.text),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// The header pill: Online and Offline once the agent has answered, and a
/// neutral "Connecting" until then, so a slow agent is never called online
/// before it has said anything (LoadingError's loading state).
Widget _connectionPill(AsyncValue<SystemStats> stats) {
  if (stats.hasError) {
    return const StatusPill('Offline', tone: PillTone.danger);
  }
  if (stats.hasValue) return const StatusPill('Online');
  return const StatusPill('Connecting', tone: PillTone.neutral);
}
