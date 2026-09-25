import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../../layout/layout.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/actions.dart';
import '../../widgets/buttons.dart';
import '../../widgets/desktop.dart';
import '../../widgets/page.dart';
import '../../widgets/primitives.dart';
import '../../widgets/state_views.dart';

/// Screen 4 — Alerts and the rules the agent checks.
class AlertsScreen extends ConsumerWidget {
  const AlertsScreen({super.key, required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final AsyncValue<List<AlertInfo>> alerts = ref.watch(
      alertsProvider(serverId),
    );
    final int active = alerts.maybeWhen(
      data: (List<AlertInfo> list) =>
          list.where((AlertInfo a) => a.state == AlertState.active).length,
      orElse: () => 0,
    );

    final String subtitle =
        '$active active on $serverId · sent as push notifications';
    final Widget list = AsyncSection<List<AlertInfo>>(
      value: alerts,
      onRetry: () => ref.invalidate(alertsProvider(serverId)),
      loadingRows: 2,
      loadingRowHeight: 118,
      isEmpty: (List<AlertInfo> list) => list.isEmpty,
      empty: const EmptyView(
        icon: Icons.notifications_off_outlined,
        title: 'No alerts',
        message:
            'Nothing has fired on this server. Rules still run on the agent.',
      ),
      builder: (List<AlertInfo> list) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CardGrid(
            gap: 12,
            cards: <Widget>[
              // Critical first, then warning, then the most recent.
              for (final AlertInfo alert
                  in list
                      .where((AlertInfo a) => a.state == AlertState.active)
                      .toList()
                    ..sort(compareAlertsByUrgency))
                _AlertCard(serverId: serverId, alert: alert),
            ],
          ),
          for (final AlertInfo alert in list.where(
            (AlertInfo a) => a.state != AlertState.active,
          ))
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  borderRadius: AppShape.smallCardRadius,
                  border: Border.all(color: t.border),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      alert.state == AlertState.muted
                          ? Icons.notifications_off_outlined
                          : Icons.check,
                      size: 20,
                      color: alert.state == AlertState.muted
                          ? t.mutedText
                          : t.accent,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      // `alert.note` is title plus meta, built once, so a
                      // resolved alert cannot repeat its own sentence.
                      child: Text(
                        alert.note,
                        style: AppText.small.copyWith(color: t.mutedText),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );

    if (WindowClass.of(context).usesDesktopExtras) {
      return DesktopPage(
        children: <Widget>[
          DesktopHeader(title: 'Alerts', subtitle: subtitle),
          list,
          _Rules(serverId: serverId),
        ],
      );
    }
    return PushedPage(
      gap: 12,
      children: <Widget>[
        const BackLink('Overview'),
        ScreenHeader(title: 'Alerts', subtitle: subtitle),
        list,
        _Rules(serverId: serverId),
      ],
    );
  }
}

class _AlertCard extends ConsumerWidget {
  const _AlertCard({required this.serverId, required this.alert});

  final String serverId;
  final AlertInfo alert;

  Future<void> _mute(BuildContext context, WidgetRef ref) async {
    final bool ok = await runAction(
      context,
      ref,
      () =>
          ref.read(agentApiProvider(serverId)).muteAlert(alert.id, minutes: 60),
      success: '${alert.title} muted for 1 h',
    );
    if (ok) ref.invalidate(alertsProvider(serverId));
  }

  Future<void> _restart(BuildContext context, WidgetRef ref) async {
    final bool ok = await runAction(context, ref, () async {
      final api = ref.read(agentApiProvider(serverId));
      await api.restartContainer(alert.targetId);
      await api.resolveAlert(alert.id);
    }, success: 'Container restarted, alert resolved');
    if (ok) ref.invalidate(alertsProvider(serverId));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final bool critical = alert.severity == AlertSeverity.critical;
    final bool canOperate = ref.watch(roleProvider(serverId)).canOperate;
    final bool hasContainer = alert.targetKind == 'container';
    return DoomCard(
      radius: 18,
      padding: const EdgeInsets.all(14),
      borderColor: critical ? t.dangerBorder : t.warningBorder,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // Start-aligned, so the severity pill sits on the title's first
          // line rather than centring itself against a wrapped block.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: critical ? t.dangerTint : t.warningTint,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.warning_amber_rounded,
                  size: 22,
                  color: critical ? t.danger : t.warning,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      alert.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.rowTitle.copyWith(color: t.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      alert.detail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.tiny.copyWith(color: t.mutedText),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: StatusPill(
                  critical ? 'Critical' : 'Warning',
                  tone: critical ? PillTone.danger : PillTone.warning,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              if (critical && hasContainer) ...<Widget>[
                Expanded(
                  child: DoomButton(
                    'View logs',
                    expand: true,
                    onPressed: () => context.push(
                      '/s/$serverId/containers/${alert.targetId}/logs',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DoomButton(
                    'Restart',
                    expand: true,
                    onPressed: canOperate ? () => _restart(context, ref) : null,
                  ),
                ),
              ] else if (hasContainer)
                Expanded(
                  child: DoomButton(
                    'Open container',
                    expand: true,
                    onPressed: () => context.push(
                      '/s/$serverId/containers/${alert.targetId}',
                    ),
                  ),
                )
              else
                Expanded(
                  child: Text(
                    'Host-level alert, no container to open.',
                    style: AppText.small.copyWith(color: t.mutedText),
                  ),
                ),
              const SizedBox(width: 8),
              DoomButton(
                'Mute 1 h',
                onPressed: canOperate ? () => _mute(context, ref) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One switch per row of the design. CPU and memory are two rules on the agent
/// (API_NOTES §22) but one row here, so the toggle patches both.
class AlertRuleRow {
  const AlertRuleRow({
    required this.label,
    required this.ids,
    required this.enabled,
  });

  final String label;
  final List<String> ids;
  final bool enabled;
}

List<AlertRuleRow> mergeAlertRules(List<AlertRule> rules) {
  AlertRule? byId(String id) {
    for (final AlertRule rule in rules) {
      if (rule.id == id) return rule;
    }
    return null;
  }

  final AlertRule? cpu = byId(AlertRuleId.cpuHigh);
  final AlertRule? memory = byId(AlertRuleId.memoryHigh);
  final List<AlertRuleRow> rows = <AlertRuleRow>[];

  for (final AlertRule rule in rules) {
    if (rule.id == AlertRuleId.memoryHigh) continue;
    if (rule.id == AlertRuleId.cpuHigh) {
      rows.add(
        AlertRuleRow(
          label:
              'CPU or memory above ${rule.threshold.round()}% for '
              '${rule.windowMinutes} min',
          ids: <String>[rule.id, if (memory != null) memory.id],
          enabled: rule.enabled || (memory?.enabled ?? false),
        ),
      );
      continue;
    }
    rows.add(
      AlertRuleRow(
        label: rule.label,
        ids: <String>[rule.id],
        enabled: rule.enabled,
      ),
    );
  }
  // A rule set that carries memory_high but not cpu_high still gets a row.
  if (cpu == null && memory != null) {
    rows.add(
      AlertRuleRow(
        label: memory.label,
        ids: <String>[memory.id],
        enabled: memory.enabled,
      ),
    );
  }
  return rows;
}

class _Rules extends ConsumerWidget {
  const _Rules({required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<AlertRule>> rules = ref.watch(
      alertRulesProvider(serverId),
    );
    final bool canEdit = ref.watch(roleProvider(serverId)).canEditAlertRules;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const SizedBox(height: 6),
        const SectionHeader('Rules checked by the agent'),
        const SizedBox(height: 8),
        AsyncSection<List<AlertRule>>(
          value: rules,
          onRetry: () => ref.invalidate(alertRulesProvider(serverId)),
          loadingRows: 4,
          loadingRowHeight: 46,
          isEmpty: (List<AlertRule> list) => list.isEmpty,
          empty: const EmptyView(
            icon: Icons.rule,
            title: 'No rules',
            message: 'This agent reports no built-in alert rules.',
          ),
          builder: (List<AlertRule> list) => RowGroup(
            children: <Widget>[
              for (final AlertRuleRow row in mergeAlertRules(list))
                SwitchRow(
                  label: row.label,
                  description: row.ids.contains(AlertRuleId.agentUnreachable)
                      ? 'Needs the push relay; the agent never fires it itself'
                      : null,
                  value: row.enabled,
                  onChanged: canEdit
                      ? (bool value) async {
                          final bool ok = await runAction(
                            context,
                            ref,
                            () async {
                              for (final String id in row.ids) {
                                await ref
                                    .read(agentApiProvider(serverId))
                                    .updateAlertRule(id, enabled: value);
                              }
                            },
                          );
                          if (ok) {
                            ref.invalidate(alertRulesProvider(serverId));
                          }
                        }
                      : null,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
