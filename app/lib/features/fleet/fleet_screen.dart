/// D5 — "All servers": fleet stat cards and one container table across every
/// paired online server.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../../theme/state_colors.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/desktop.dart';
import '../../widgets/filter_field.dart';
import '../../widgets/state_views.dart';
import '../../widgets/stroke_icons.dart';
import '../../widgets/table.dart';
import '../containers/container_actions.dart';
import '../logwall/log_wall_controller.dart';
import '../logwall/log_wall_screen.dart';
import '../pair/pair_agent_screen.dart';
import 'fleet_providers.dart';

class FleetScreen extends ConsumerStatefulWidget {
  const FleetScreen({super.key});

  @override
  ConsumerState<FleetScreen> createState() => _FleetScreenState();
}

class _FleetScreenState extends ConsumerState<FleetScreen> {
  final TextEditingController _filter = TextEditingController();
  String? _serverFilter;
  bool _needsAttentionOnly = false;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  bool _keep(FleetContainer row) {
    if (_serverFilter != null && row.server.id != _serverFilter) return false;
    if (_needsAttentionOnly && row.container.state.isRunning) return false;
    final String query = _filter.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    return row.container.name.toLowerCase().contains(query) ||
        row.container.image.toLowerCase().contains(query) ||
        row.server.name.toLowerCase().contains(query);
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<FleetSnapshot> snapshot = ref.watch(fleetProvider);
    return DesktopPage(
      gap: 16,
      children: <Widget>[
        DesktopHeader(
          title: 'All servers',
          subtitle: snapshot.maybeWhen(
            data: (FleetSnapshot s) =>
                '${s.online} of ${s.total} agents online · figures refresh live',
            orElse: () => 'Asking every agent…',
          ),
        ),
        AsyncSection<FleetSnapshot>(
          value: snapshot,
          onRetry: () => ref.invalidate(fleetProvider),
          loadingRows: 2,
          loadingRowHeight: 104,
          builder: _body,
        ),
      ],
    );
  }

  Widget _body(FleetSnapshot s) {
    final AppTokens t = context.tokens;
    if (s.servers.isEmpty) {
      // Nothing is paired: the sidebar has no servers either, so this is where
      // the first one is added or demo mode is entered.
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: EmptyView(
            glyph: StrokeGlyph.servers,
            title: 'No servers yet',
            message: 'Pair an agent, or look around with sample data.',
            primary: EmptyAction(
              'Pair a new server',
              icon: Icons.add,
              onPressed: () => showPairAgent(context, ref),
            ),
            secondary: EmptyAction(
              'Explore with demo data',
              onPressed: () async {
                await ref.read(demoModeProvider.notifier).set(true);
                ref.invalidate(fleetProvider);
              },
            ),
          ),
        ),
      );
    }
    final List<FleetContainer> rows = s.containers
        .where(_keep)
        .toList(growable: false);
    final int attention = s.containers
        .where((FleetContainer c) => !c.container.state.isRunning)
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        StatCardGrid(
          cards: <Widget>[
            StatCard(
              label: 'Servers',
              figure: '${s.online}',
              suffix: '/ ${s.total} online',
              // D5 names how long it has been gone, not just that it is.
              note: s.offline.isEmpty
                  ? 'Every agent answered'
                  : _unreachableNote(s.offline.first),
              noteColor: s.offline.isEmpty ? null : t.danger,
            ),
            StatCard(
              label: 'Containers',
              figure: '${s.running + s.restarting}',
              suffix: 'running',
              note: '${s.stopped} stopped · ${s.restarting} restarting',
            ),
            StatCard(
              label: 'Active alerts',
              figure: '${s.alerts.length}',
              note:
                  '${s.criticalAlerts} critical · '
                  '${s.alerts.length - s.criticalAlerts} warning',
              onTap: () => context.go('/all/alerts'),
            ),
            StatCard(
              label: 'Unused images',
              figure: formatBytes(s.reclaimableBytes).split(' ').first,
              suffix: formatBytes(s.reclaimableBytes).split(' ').last,
              note: s.reclaimableOn == null
                  ? 'Nothing to reclaim'
                  : 'Reclaimable on ${s.reclaimableOn}',
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            FilterField(
              controller: _filter,
              hint: 'Filter by name, image or server',
              width: 320,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: PillChipRow(
                chips: <Widget>[
                  PillChip(
                    label: 'All servers',
                    selected: _serverFilter == null,
                    onPressed: () => setState(() => _serverFilter = null),
                  ),
                  for (final FleetServer server in s.servers)
                    if (server.online)
                      PillChip(
                        label: server.server.name,
                        selected: _serverFilter == server.server.id,
                        onPressed: () =>
                            setState(() => _serverFilter = server.server.id),
                      ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            PillChip(
              label: 'Any state',
              selected: !_needsAttentionOnly,
              onPressed: () => setState(() => _needsAttentionOnly = false),
            ),
            const SizedBox(width: 6),
            PillChip(
              label: 'Needs attention $attention',
              selected: _needsAttentionOnly,
              onPressed: () => setState(() => _needsAttentionOnly = true),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (rows.isEmpty)
          const EmptyView(
            glyph: StrokeGlyph.search,
            title: 'No containers',
            message: 'Nothing on the online agents matches this filter.',
          )
        else
          DataTableView<FleetContainer>(
            rows: rows,
            // D5 pairs the ⋮ with a logs button, so this table draws both
            // itself in its own trailing column.
            rowMenuButton: false,
            actions: (FleetContainer row) => _menu(row),
            onTap: (FleetContainer row) => context.go(
              '/s/${row.server.id}/containers/${row.container.id}',
            ),
            columns: <TableColumn<FleetContainer>>[
              TableColumn<FleetContainer>(
                label: 'Container',
                compare: (FleetContainer a, FleetContainer b) =>
                    a.container.name.compareTo(b.container.name),
                cell: (BuildContext c, FleetContainer row) =>
                    CellText(row.container.name, bold: true),
              ),
              TableColumn<FleetContainer>(
                label: 'Server',
                width: 130,
                compare: (FleetContainer a, FleetContainer b) =>
                    a.server.name.compareTo(b.server.name),
                cell: (BuildContext c, FleetContainer row) =>
                    CellText(row.server.name, muted: true),
              ),
              TableColumn<FleetContainer>(
                label: 'Image',
                width: 260,
                optional: true,
                cell: (BuildContext c, FleetContainer row) => CellText(
                  row.container.image,
                  mono: true,
                  muted: true,
                  selectable: true,
                ),
              ),
              TableColumn<FleetContainer>(
                label: 'State',
                width: 130,
                compare: (FleetContainer a, FleetContainer b) =>
                    a.container.stateLabel.compareTo(b.container.stateLabel),
                cell: (BuildContext c, FleetContainer row) => StateCell(
                  label: row.container.stateLabel,
                  color: containerStateColor(c.tokens, row.container.state),
                ),
              ),
              TableColumn<FleetContainer>(
                label: 'CPU',
                width: 60,
                numeric: true,
                optional: true,
                compare: (FleetContainer a, FleetContainer b) =>
                    a.container.cpuPercent.compareTo(b.container.cpuPercent),
                cell: (BuildContext c, FleetContainer row) => CellText(
                  row.container.state.isRunning
                      ? formatPercent(row.container.cpuPercent)
                      : '–',
                ),
              ),
              TableColumn<FleetContainer>(
                label: 'Memory',
                width: 80,
                numeric: true,
                optional: true,
                compare: (FleetContainer a, FleetContainer b) =>
                    a.container.memoryBytes.compareTo(b.container.memoryBytes),
                cell: (BuildContext c, FleetContainer row) => CellText(
                  row.container.state.isRunning
                      ? formatBytes(row.container.memoryBytes)
                      : '–',
                ),
              ),
              TableColumn<FleetContainer>(
                label: '',
                width: 76,
                numeric: true,
                cell: (BuildContext c, FleetContainer row) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    DoomIconButton(
                      icon: Icons.notes,
                      semanticLabel: 'Logs for ${row.container.name}',
                      size: 32,
                      radius: 8,
                      filled: false,
                      foreground: c.tokens.mutedText,
                      onPressed: () => context.go(
                        '/s/${row.server.id}/containers/'
                        '${row.container.id}/logs',
                      ),
                    ),
                    Builder(
                      builder: (BuildContext buttonContext) => DoomIconButton(
                        icon: Icons.more_vert,
                        semanticLabel: 'Actions for ${row.container.name}',
                        size: 32,
                        radius: 8,
                        filled: false,
                        foreground: c.tokens.mutedText,
                        onPressed: () => showActionMenu(
                          buttonContext,
                          _anchor(buttonContext),
                          _menu(row),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        for (final FleetServer server in s.offline) ...<Widget>[
          const SizedBox(height: 12),
          OfflineNotice(
            message:
                '${server.server.name} is offline, so its containers are not '
                'listed. ${server.reason ?? ''}',
            onRetry: () => ref.invalidate(fleetProvider),
          ),
        ],
      ],
    );
  }

  /// `backup-nas unreachable for 2 h`, when the agent's reason says how long
  /// ago it was last seen; `backup-nas unreachable` when it does not.
  static final RegExp _lastSeen = RegExp(r'[Ll]ast seen ([^.]+?)\s*ago');

  static String _unreachableNote(FleetServer offline) {
    final String name = offline.server.name;
    final Match? seen = _lastSeen.firstMatch(offline.reason ?? '');
    return seen == null
        ? '$name unreachable'
        : '$name unreachable for ${seen[1]}';
  }

  static Offset _anchor(BuildContext context) {
    final RenderBox box = context.findRenderObject()! as RenderBox;
    return box.localToGlobal(box.size.bottomLeft(Offset.zero));
  }

  List<MenuAction> _menu(FleetContainer row) => <MenuAction>[
    ...containerMenuActions(
      context,
      ref,
      row.server.id,
      row.container,
      onLogs: () =>
          context.go('/s/${row.server.id}/containers/${row.container.id}/logs'),
      onLogWall: () => openLogWall(
        context,
        ref,
        LogPaneRef(
          serverId: row.server.id,
          containerId: row.container.id,
          name: row.container.name,
        ),
      ),
    ),
  ];
}
