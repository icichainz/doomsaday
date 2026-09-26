/// The container actions the list row, the fleet table, the split-view header
/// and every right-click menu share.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/agent_api.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../widgets/actions.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/notify.dart';
import '../../widgets/sheets.dart';
import '../../widgets/stroke_icons.dart';

/// What stopping this container costs, in the board's words:
/// `Port 8080 stops answering, and 2 containers in web-platform depend on it.`
///
/// It degrades a clause at a time: no published port, no dependents, or
/// neither, and finally no impact call at all.
String stopImpactSentence(ContainerImpact? impact, String stack) {
  if (impact == null) return 'Anything talking to it stops getting answers.';
  final List<String> ports = impact.publishedPortLabels;
  final int dependents = impact.affected.length;
  final String where = stack.isEmpty ? '' : ' in $stack';
  final String portClause = ports.isEmpty
      ? ''
      : 'Port ${ports.join(', ')} stops answering';
  final String dependentClause = dependents == 0
      ? ''
      : '$dependents container${dependents == 1 ? '' : 's'}$where '
            'depend${dependents == 1 ? 's' : ''} on it';
  if (portClause.isEmpty && dependentClause.isEmpty) {
    return 'Nothing is published from it, and nothing else depends on it.';
  }
  if (portClause.isEmpty) {
    return '${_capitalize(dependentClause)}.';
  }
  if (dependentClause.isEmpty) return '$portClause.';
  return '$portClause, and $dependentClause.';
}

String _capitalize(String value) =>
    value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

/// Start a stopped container, or stop a running one through the confirm
/// dialog. Nothing is sent when the confirmation is cancelled.
Future<void> startOrStopContainer(
  BuildContext context,
  WidgetRef ref,
  String serverId,
  ContainerSummary container,
) async {
  final bool running = container.state.isRunning;
  final AgentApi api = ref.read(agentApiProvider(serverId));
  if (!running) {
    await runAction(
      context,
      ref,
      () => api.startContainer(container.id),
      success: '${container.name} started',
    );
    return;
  }
  // The sheet names the ports and the dependents, so the impact call comes
  // first. An agent that cannot answer it still gets a confirm sheet.
  ContainerImpact? impact;
  try {
    impact = await api.containerImpact(container.id);
  } on AgentException {
    impact = null;
  }
  if (!context.mounted) return;
  final RiskyOutcome outcome = await confirmRisky(
    context,
    ref,
    RiskyAction(
      title: 'Stop ${container.name}?',
      subtitle:
          '$serverId · ${container.stack.isEmpty ? 'no stack' : container.stack}',
      explanation:
          'The container gets SIGTERM, then SIGKILL after 10 s. '
          '${stopImpactSentence(impact, container.stack)}',
      requestLine: 'POST /v1/containers/${container.id}/stop?timeout=10',
      confirmLabel: 'Stop container',
      glyph: StrokeGlyph.stop,
      requireFingerprint: riskyNeedsFingerprint(ref, serverId),
      target: container.name,
    ),
  );
  if (!outcome.confirmed || !context.mounted) return;
  await runAction(
    context,
    ref,
    () => api.stopContainer(container.id, confirmed: outcome.confirmation),
    success: '${container.name} stopped',
  );
}

Future<void> restartContainer(
  BuildContext context,
  WidgetRef ref,
  String serverId,
  ContainerSummary container,
) => runAction(
  context,
  ref,
  () => ref.read(agentApiProvider(serverId)).restartContainer(container.id),
  success: '${container.name} restarted',
);

/// The same actions the row's more button offers, for a right-click menu.
List<MenuAction> containerMenuActions(
  BuildContext context,
  WidgetRef ref,
  String serverId,
  ContainerSummary container, {
  VoidCallback? onLogs,
  VoidCallback? onLogWall,
}) {
  final ServerRole role = ref.read(roleProvider(serverId));
  final bool running = container.state.isRunning;
  return <MenuAction>[
    if (onLogs != null)
      MenuAction(label: 'Logs', glyph: StrokeGlyph.logWall, onSelected: onLogs),
    if (onLogWall != null)
      MenuAction(
        label: 'Open in log wall',
        glyph: StrokeGlyph.fleet,
        onSelected: onLogWall,
      ),
    MenuAction(
      label: running ? 'Stop' : 'Start',
      glyph: running ? StrokeGlyph.stop : StrokeGlyph.play,
      enabled: role.canOperate,
      danger: running,
      onSelected: () => startOrStopContainer(context, ref, serverId, container),
    ),
    MenuAction(
      label: 'Restart',
      glyph: StrokeGlyph.restart,
      enabled: role.canOperate && running,
      onSelected: () => restartContainer(context, ref, serverId, container),
    ),
    MenuAction(
      label: 'Copy container id',
      glyph: StrokeGlyph.copy,
      onSelected: () {
        Clipboard.setData(ClipboardData(text: container.id));
        notify(context, 'Container id copied');
      },
    ),
  ];
}
