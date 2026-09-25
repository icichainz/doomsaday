import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../../layout/layout.dart';
import '../../theme/app_theme.dart';
import '../../theme/state_colors.dart';
import '../../theme/tokens.dart';
import '../../widgets/actions.dart';
import '../../widgets/buttons.dart';
import '../../widgets/page.dart';
import '../../widgets/primitives.dart';
import '../../widgets/sheets.dart';
import '../../widgets/state_views.dart';
import '../containers/container_actions.dart';
import '../containers/containers_pane.dart';
import 'container_config_sheet.dart';

/// Screen 6 — Container detail. Stop and Remove go through the confirm sheet.
class ContainerDetailScreen extends ConsumerWidget {
  const ContainerDetailScreen({
    super.key,
    required this.serverId,
    required this.containerId,
  });

  final String serverId;
  final String containerId;

  ContainerKey get _key => (serverId: serverId, containerId: containerId);

  Future<void> _restart(
    BuildContext context,
    WidgetRef ref,
    String name,
  ) async {
    await runAction(
      context,
      ref,
      () => ref.read(agentApiProvider(serverId)).restartContainer(containerId),
      success: '$name restarted',
    );
  }

  /// Both directions go through the one shared implementation, so the phone
  /// sheet and the desktop dialog say exactly the same thing.
  Future<void> _startOrStop(
    BuildContext context,
    WidgetRef ref,
    ContainerDetail detail,
  ) => startOrStopContainer(context, ref, serverId, detail.summary);

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    ContainerDetail detail,
  ) async {
    final RiskyOutcome outcome = await confirmRisky(
      context,
      ref,
      RiskyAction(
        title: 'Remove ${detail.name}?',
        subtitle:
            '$serverId · ${detail.summary.stack.isEmpty ? 'no stack' : detail.summary.stack}',
        explanation:
            'The container and its writable layer are deleted. Named volumes '
            'are kept unless you remove them separately.',
        requestLine:
            'DELETE /v1/containers/$containerId?force=true&volumes=false',
        confirmLabel: 'Remove container',
        icon: Icons.delete_outline,
        requireFingerprint: riskyNeedsFingerprint(ref, serverId),
        target: detail.name,
      ),
    );
    if (!outcome.confirmed || !context.mounted) return;
    final bool removed = await runAction(
      context,
      ref,
      () => ref
          .read(agentApiProvider(serverId))
          .removeContainer(
            containerId,
            force: true,
            confirmed: outcome.confirmation,
          ),
      success: '${detail.name} removed',
    );
    if (removed && context.mounted) context.pop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // At 1100 and up the same URL is the split view with this container
    // selected, so back, forward and a resize all land in the right place.
    if (WindowClass.of(context).usesDesktopExtras) {
      return ContainersPane(serverId: serverId, selectedId: containerId);
    }
    final AppTokens t = context.tokens;
    final AsyncValue<ContainerDetail> detail = ref.watch(
      containerDetailProvider(_key),
    );
    final ServerRole role = ref.watch(roleProvider(serverId));

    return PushedPage(
      gap: 16,
      children: <Widget>[
        const BackLink('Containers'),
        AsyncSection<ContainerDetail>(
          value: detail,
          onRetry: () => ref.invalidate(containerDetailProvider(_key)),
          loadingRows: 5,
          loadingRowHeight: 72,
          builder: (ContainerDetail d) {
            final bool running = d.summary.state.isRunning;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        d.name,
                        style: AppText.screenTitle.copyWith(color: t.text),
                      ),
                    ),
                    const SizedBox(width: 10),
                    StatusPill(
                      d.summary.pillLabel,
                      tone: containerStateTone(d.summary.state),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  d.summary.image,
                  style: AppText.monoSmall.copyWith(color: t.mutedText),
                ),
                const SizedBox(height: 16),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _ActionTile(
                        icon: Icons.refresh,
                        label: 'Restart',
                        onTap: running && role.canOperate
                            ? () => _restart(context, ref, d.name)
                            : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _ActionTile(
                        icon: running ? Icons.stop : Icons.play_arrow,
                        label: running ? 'Stop' : 'Start',
                        foreground: running ? t.danger : t.accent,
                        onTap: role.canOperate
                            ? () => _startOrStop(context, ref, d)
                            : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _ActionTile(
                        icon: Icons.notes,
                        label: 'Logs',
                        onTap: () => context.push(
                          '/s/$serverId/containers/$containerId/logs',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _ActionTile(
                        icon: Icons.terminal,
                        label: 'Shell',
                        // Admin only, and only into a running container.
                        onTap: role.canExec && running
                            ? () => context.push(
                                '/s/$serverId/containers/$containerId/shell',
                              )
                            : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _LiveStats(
                  serverId: serverId,
                  containerId: containerId,
                  detail: d,
                ),
                const SizedBox(height: 16),
                RowGroup(
                  children: <Widget>[
                    DetailRow(
                      'Ports',
                      d.portLines.isEmpty
                          ? 'none published'
                          : d.portLines.join(', '),
                      mono: d.portLines.isNotEmpty,
                    ),
                    DetailRow(
                      'Stack',
                      d.summary.stack.isEmpty ? 'none' : d.summary.stack,
                    ),
                    DetailRow('Network', d.networkNames, mono: true),
                    DetailRow('Restart policy', d.restartPolicy, mono: true),
                    DetailRow('Container ID', d.id, mono: true),
                  ],
                ),
                const SizedBox(height: 16),
                RowGroup(
                  children: <Widget>[
                    NavRow(
                      label: 'Environment',
                      value: '${d.envNames.length} variables, values hidden',
                      onTap: () => showContainerConfig(
                        context,
                        serverId: serverId,
                        detail: d,
                      ),
                    ),
                    NavRow(
                      label: 'Volumes',
                      value:
                          '${d.mounts.length} mount${d.mounts.length == 1 ? '' : 's'}',
                      onTap: () => showContainerConfig(
                        context,
                        serverId: serverId,
                        detail: d,
                        mounts: true,
                      ),
                    ),
                  ],
                ),
                if (role.canRemove) ...<Widget>[
                  const SizedBox(height: 16),
                  DoomButton(
                    'Remove container',
                    icon: Icons.delete_outline,
                    tone: ButtonTone.danger,
                    height: 48,
                    radius: 16,
                    expand: true,
                    onPressed: () => _remove(context, ref, d),
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    this.onTap,
    this.foreground,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Color fg = foreground ?? t.text;
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: DoomCard(
        radius: 16,
        padding: EdgeInsets.zero,
        onTap: onTap,
        child: SizedBox(
          height: 72,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: 20, color: fg),
              const SizedBox(height: 6),
              Text(label, style: AppText.pill.copyWith(color: fg)),
            ],
          ),
        ),
      ),
    );
  }
}

class _LiveStats extends ConsumerWidget {
  const _LiveStats({
    required this.serverId,
    required this.containerId,
    required this.detail,
  });

  final String serverId;
  final String containerId;
  final ContainerDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final AsyncValue<ContainerStats> stats = ref.watch(
      containerStatsProvider((serverId: serverId, containerId: containerId)),
    );
    final ContainerStats s =
        stats.valueOrNull ??
        ContainerStats(
          cpuPercent: detail.summary.cpuPercent,
          memoryBytes: detail.summary.memoryBytes,
          memoryPercent: detail.summary.memoryPercent,
          memoryLimitBytes: detail.summary.memoryLimitBytes,
          netInBytesPerSecond: 0,
          netOutBytesPerSecond: 0,
        );
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: _MiniStat(
              label: 'CPU',
              figure: formatPercent(s.cpuPercent),
              footer: MeterBar(s.cpuPercent / 100, height: 5),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _MiniStat(
              label: 'Memory',
              figure: formatBytes(s.memoryBytes).split(' ').first,
              suffix: formatBytes(s.memoryBytes).split(' ').last,
              footer: MeterBar(s.memoryFraction, height: 5),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _MiniStat(
              label: 'Network',
              figure: (s.netInBytesPerSecond / (1024 * 1024)).toStringAsFixed(
                1,
              ),
              // "in" rides with the figure and "out" owns the footer: a third
              // of a 390 px row has no room for "1.2 MB/s in · 340 KB/s out".
              suffix: 'MB/s in',
              footer: Text(
                '${(s.netOutBytesPerSecond / 1024).round()} KB/s out',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: t.mutedText),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.label,
    required this.figure,
    this.suffix,
    required this.footer,
  });

  final String label;
  final String figure;
  final String? suffix;
  final Widget footer;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return DoomCard(
      radius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label, style: AppText.tiny.copyWith(color: t.mutedText)),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              children: <InlineSpan>[
                TextSpan(text: figure),
                if (suffix != null)
                  TextSpan(
                    text: ' $suffix',
                    style: TextStyle(
                      fontFamily: AppFonts.sans,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: t.mutedText,
                    ),
                  ),
              ],
            ),
            maxLines: 1,
            style: AppText.figureSmall.copyWith(color: t.text),
          ),
          const SizedBox(height: 6),
          footer,
        ],
      ),
    );
  }
}
