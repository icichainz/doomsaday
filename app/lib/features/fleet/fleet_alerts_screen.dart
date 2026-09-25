/// Fleet-wide alerts: the same aggregation as D5, listed by severity with the
/// server that raised each one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models.dart';
import '../../edition/edition.dart';
import '../../edition/locked_feature.dart';
import '../../layout/layout.dart';
import '../../theme/tokens.dart';
import '../../widgets/desktop.dart';
import '../../widgets/primitives.dart';
import '../../widgets/state_views.dart';
import '../../widgets/stroke_icons.dart';
import '../../widgets/table.dart';
import 'fleet_providers.dart';

class FleetAlertsScreen extends ConsumerWidget {
  const FleetAlertsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!WindowClass.of(context).usesDesktopExtras) {
      return const NeedsAWiderWindow(title: 'Fleet alerts');
    }
    // Before the snapshot is watched: a locked page asks no agent anything.
    if (!ref.watch(editionProvider).fleetView) {
      return const LockedFeature(feature: ProFeature.fleetAlerts);
    }
    final AppTokens t = context.tokens;
    final AsyncValue<FleetSnapshot> snapshot = ref.watch(fleetProvider);
    return DesktopPage(
      gap: 16,
      children: <Widget>[
        DesktopHeader(
          title: 'Alerts',
          subtitle: snapshot.maybeWhen(
            data: (FleetSnapshot s) =>
                '${s.alerts.length} active across ${s.online} online '
                'server${s.online == 1 ? '' : 's'}',
            orElse: () => 'Asking every agent…',
          ),
        ),
        AsyncSection<FleetSnapshot>(
          value: snapshot,
          onRetry: () => ref.invalidate(fleetProvider),
          loadingRows: 3,
          loadingRowHeight: 56,
          isEmpty: (FleetSnapshot s) => s.alerts.isEmpty && s.offline.isEmpty,
          empty: const EmptyView(
            glyph: StrokeGlyph.checkCircle,
            tone: EmptyTone.healthy,
            title: 'Nothing needs attention',
            message: 'No alert rule has fired on any paired server.',
          ),
          builder: (FleetSnapshot s) {
            final List<FleetAlert> alerts = <FleetAlert>[...s.alerts]
              ..sort(
                (FleetAlert a, FleetAlert b) =>
                    a.alert.severity.index.compareTo(b.alert.severity.index),
              );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (alerts.isEmpty)
                  const EmptyView(
                    glyph: StrokeGlyph.checkCircle,
                    tone: EmptyTone.healthy,
                    title: 'Nothing needs attention',
                    message: 'No alert rule has fired on a reachable server.',
                  )
                else
                  DataTableView<FleetAlert>(
                    rows: alerts,
                    onTap: (FleetAlert row) => context.go(
                      row.alert.targetId.isEmpty
                          ? '/s/${row.server.id}/alerts'
                          : '/s/${row.server.id}/containers/'
                                '${row.alert.targetId}',
                    ),
                    columns: <TableColumn<FleetAlert>>[
                      TableColumn<FleetAlert>(
                        label: 'Alert',
                        cell: (BuildContext c, FleetAlert row) =>
                            CellText(row.alert.title, bold: true),
                      ),
                      TableColumn<FleetAlert>(
                        label: 'Server',
                        width: 130,
                        compare: (FleetAlert a, FleetAlert b) =>
                            a.server.name.compareTo(b.server.name),
                        cell: (BuildContext c, FleetAlert row) =>
                            CellText(row.server.name, muted: true),
                      ),
                      TableColumn<FleetAlert>(
                        label: 'Detail',
                        width: 320,
                        optional: true,
                        cell: (BuildContext c, FleetAlert row) =>
                            CellText(row.alert.detail, muted: true),
                      ),
                      TableColumn<FleetAlert>(
                        label: 'Severity',
                        width: 120,
                        compare: (FleetAlert a, FleetAlert b) => a
                            .alert
                            .severity
                            .index
                            .compareTo(b.alert.severity.index),
                        cell: (BuildContext c, FleetAlert row) => StatusPill(
                          row.alert.severity == AlertSeverity.critical
                              ? 'Critical'
                              : 'Warning',
                          tone: row.alert.severity == AlertSeverity.critical
                              ? PillTone.danger
                              : PillTone.warning,
                        ),
                      ),
                    ],
                  ),
                for (final FleetServer server in s.offline) ...<Widget>[
                  const SizedBox(height: 12),
                  OfflineNotice(
                    message:
                        '${server.server.name} is offline, so its alerts are '
                        'not listed. ${server.reason ?? ''}',
                    onRetry: () => ref.invalidate(fleetProvider),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  'Muting and resolving stay on the server that raised the '
                  'alert; open it to act on one.',
                  style: TextStyle(fontSize: 12, color: t.mutedText),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
