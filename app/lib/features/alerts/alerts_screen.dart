import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../../data/this_device.dart';
import '../../layout/layout.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/actions.dart';
import '../../widgets/buttons.dart';
import '../../widgets/desktop.dart';
import '../../widgets/page.dart';
import '../../widgets/primitives.dart';
import '../../widgets/state_views.dart';
import '../../widgets/stroke_icons.dart';
import '../../widgets/table.dart';

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
    final bool desktop = WindowClass.of(context).usesDesktopExtras;
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
            gap: desktop ? 16 : 12,
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
              padding: EdgeInsets.only(top: desktop ? 16 : 12),
              child: Container(
                constraints: BoxConstraints(minHeight: desktop ? 44 : 48),
                padding: EdgeInsets.symmetric(
                  horizontal: desktop ? 16 : 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  borderRadius: desktop
                      ? BorderRadius.circular(14)
                      : AppShape.smallCardRadius,
                  border: Border.all(color: t.border),
                ),
                child: Row(
                  children: <Widget>[
                    if (alert.state == AlertState.muted)
                      Icon(
                        Icons.notifications_off_outlined,
                        size: 20,
                        color: t.mutedText,
                      )
                    else
                      StrokeIcon(
                        StrokeGlyph.check,
                        size: desktop ? 18 : 20,
                        color: t.accent,
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

    if (desktop) {
      return DesktopPage(
        gap: 16,
        children: <Widget>[
          DesktopHeader(title: 'Alerts', subtitle: subtitle),
          list,
          _RulesTable(serverId: serverId),
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
    // DesktopAlerts draws the card tighter: radius 16, a 36 px icon tile and
    // the pointer's 36 px buttons.
    final bool desktop = WindowClass.of(context).usesDesktopExtras;
    final double button = context.density.cardButton;
    final double buttonRadius = context.density.cardButtonRadius;
    return DoomCard(
      radius: desktop ? 16 : 18,
      padding: EdgeInsets.all(desktop ? 16 : 14),
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
                width: desktop ? 36 : 40,
                height: desktop ? 36 : 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: critical ? t.dangerTint : t.warningTint,
                  borderRadius: BorderRadius.circular(desktop ? 10 : 12),
                ),
                child: StrokeIcon(
                  StrokeGlyph.warning,
                  size: desktop ? 18 : 22,
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
                      style: AppText.tiny.copyWith(
                        color: t.mutedText,
                        fontSize: desktop ? 12.5 : null,
                      ),
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
          SizedBox(height: desktop ? 12 : 10),
          Row(
            children: <Widget>[
              if (critical && hasContainer) ...<Widget>[
                Expanded(
                  child: DoomButton(
                    'View logs',
                    height: button,
                    radius: buttonRadius,
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
                    height: button,
                    radius: buttonRadius,
                    expand: true,
                    onPressed: canOperate ? () => _restart(context, ref) : null,
                  ),
                ),
              ] else if (hasContainer)
                Expanded(
                  child: DoomButton(
                    'Open container',
                    height: button,
                    radius: buttonRadius,
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
                height: button,
                radius: buttonRadius,
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
    this.name = '',
    this.threshold = '',
    this.window = '',
  });

  /// The phone's one-line sentence, threshold and window included.
  final String label;
  final List<String> ids;
  final bool enabled;

  /// DesktopAlerts' table splits the sentence into its columns.
  final String name;
  final String threshold;
  final String window;

  bool get needsRelay => ids.contains(AlertRuleId.agentUnreachable);
}

/// `Non-zero exit code`, `3 restarts`, `90%`, `No heartbeat`.
String _thresholdOf(AlertRule rule) => switch (rule.id) {
  AlertRuleId.unexpectedExit => 'Non-zero exit code',
  AlertRuleId.restartLoop => '${rule.threshold.round()} restarts',
  AlertRuleId.cpuHigh || AlertRuleId.memoryHigh => '${rule.threshold.round()}%',
  AlertRuleId.agentUnreachable => 'No heartbeat',
  _ =>
    rule.thresholdUnit == 'percent'
        ? '${rule.threshold.round()}%'
        : '${rule.threshold.round()} ${rule.thresholdUnit}'.trim(),
};

String _windowOf(AlertRule rule) =>
    rule.windowSeconds == 0 ? 'Immediately' : '${rule.windowMinutes} min';

String _nameOf(AlertRule rule) => switch (rule.id) {
  AlertRuleId.unexpectedExit => 'Container exits unexpectedly',
  AlertRuleId.restartLoop => 'Restart loop',
  AlertRuleId.cpuHigh => 'CPU high',
  AlertRuleId.memoryHigh => 'Memory high',
  AlertRuleId.agentUnreachable => 'Agent unreachable',
  _ => rule.name,
};

AlertRuleRow _rowFor(AlertRule rule) => AlertRuleRow(
  label: rule.label,
  ids: <String>[rule.id],
  enabled: rule.enabled,
  name: _nameOf(rule),
  threshold: _thresholdOf(rule),
  window: _windowOf(rule),
);

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
          name: memory == null ? 'CPU high' : 'CPU or memory high',
          threshold: _thresholdOf(rule),
          window: _windowOf(rule),
        ),
      );
      continue;
    }
    rows.add(_rowFor(rule));
  }
  // A rule set that carries memory_high but not cpu_high still gets a row.
  if (cpu == null && memory != null) {
    rows.add(_rowFor(memory));
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
                  description: row.needsRelay ? _relayNote : null,
                  value: row.enabled,
                  onChanged: canEdit
                      ? (bool value) =>
                            _toggleRule(context, ref, serverId, row, value)
                      : null,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

const String _relayNote =
    'Needs the push relay; the agent never fires it itself';

Future<void> _toggleRule(
  BuildContext context,
  WidgetRef ref,
  String serverId,
  AlertRuleRow row,
  bool value,
) async {
  final bool ok = await runAction(context, ref, () async {
    for (final String id in row.ids) {
      await ref
          .read(agentApiProvider(serverId))
          .updateAlertRule(id, enabled: value);
    }
  });
  if (ok) ref.invalidate(alertRulesProvider(serverId));
}

/// DesktopAlerts: the rules as a table — rule, threshold, window, switch —
/// under the alert cards, and the line about where they run.
class _RulesTable extends ConsumerWidget {
  const _RulesTable({required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
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
        const SizedBox(height: 10),
        AsyncSection<List<AlertRule>>(
          value: rules,
          onRetry: () => ref.invalidate(alertRulesProvider(serverId)),
          loadingRows: 4,
          loadingRowHeight: 54,
          isEmpty: (List<AlertRule> list) => list.isEmpty,
          empty: const EmptyView(
            icon: Icons.rule,
            title: 'No rules',
            message: 'This agent reports no built-in alert rules.',
          ),
          builder: (List<AlertRule> list) => DataTableView<AlertRuleRow>(
            rows: mergeAlertRules(list),
            rowHeight: 54,
            columns: <TableColumn<AlertRuleRow>>[
              TableColumn<AlertRuleRow>(
                label: 'Rule',
                cell: (BuildContext c, AlertRuleRow row) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      row.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: t.text,
                      ),
                    ),
                    if (row.needsRelay)
                      Text(
                        _relayNote,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.tiny.copyWith(color: t.mutedText),
                      ),
                  ],
                ),
              ),
              TableColumn<AlertRuleRow>(
                label: 'Threshold',
                width: 170,
                cell: (BuildContext c, AlertRuleRow row) =>
                    CellText(row.threshold),
              ),
              TableColumn<AlertRuleRow>(
                label: 'Window',
                width: 130,
                cell: (BuildContext c, AlertRuleRow row) =>
                    CellText(row.window, muted: row.window == 'Immediately'),
              ),
              TableColumn<AlertRuleRow>(
                label: 'On',
                width: 60,
                numeric: true,
                cell: (BuildContext c, AlertRuleRow row) => DoomSwitch(
                  value: row.enabled,
                  label: row.name,
                  onChanged: canEdit
                      ? (bool value) =>
                            _toggleRule(context, ref, serverId, row, value)
                      : null,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Rules run on the agent, so they keep firing while '
          '${thisDeviceLabel(capitalized: false)} is closed. A change applies '
          'to every device paired with $serverId.',
          style: TextStyle(fontSize: 12.5, color: t.mutedText),
        ),
      ],
    );
  }
}
