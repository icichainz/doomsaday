/// D2 — the containers split view: a 400 px list pane and a detail pane whose
/// Logs, Details, Environment and Shell are tabs rather than pushed screens.
///
/// Selecting a row changes the URL, so back, forward and restoration all work
/// and narrowing the window under 1100 lands on the pushed detail screen for
/// the same container.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../../widgets/context_menu.dart';
import '../../widgets/desktop.dart';
import '../../widgets/filter_field.dart';
import '../../widgets/notify.dart';
import '../../widgets/primitives.dart';
import '../../widgets/sheets.dart';
import '../../widgets/state_views.dart';
import '../../widgets/stroke_icons.dart';
import '../exec/exec_screen.dart';
import '../logs/logs_screen.dart';
import '../logwall/log_wall_controller.dart';
import '../logwall/log_wall_screen.dart';
import 'container_actions.dart';

enum ContainerTab {
  logs('Logs'),
  details('Details'),
  environment('Environment'),
  shell('Shell');

  const ContainerTab(this.label);

  final String label;
}

class ContainersPane extends ConsumerStatefulWidget {
  const ContainersPane({
    super.key,
    required this.serverId,
    this.selectedId,
    this.initialTab = ContainerTab.logs,
  });

  final String serverId;
  final String? selectedId;
  final ContainerTab initialTab;

  @override
  ConsumerState<ContainersPane> createState() => _ContainersPaneState();
}

class _ContainersPaneState extends ConsumerState<ContainersPane> {
  final TextEditingController _filter = TextEditingController();
  late ContainerTab _tab = widget.initialTab;
  ContainerFilter _state = ContainerFilter.all;

  @override
  void didUpdateWidget(ContainersPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTab != widget.initialTab) _tab = widget.initialTab;
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  void _select(String containerId) =>
      context.go('/s/${widget.serverId}/containers/$containerId');

  void _clearSelection() => context.go('/s/${widget.serverId}/containers');

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _clearSelection,
      },
      child: Material(
        color: t.ground,
        child: SafeArea(
          child: Row(
            children: <Widget>[
              Container(
                width: ShellMetrics.listPaneWidth,
                decoration: BoxDecoration(
                  border: Border(right: BorderSide(color: t.border)),
                ),
                child: _ListPane(
                  serverId: widget.serverId,
                  selectedId: widget.selectedId,
                  filter: _filter,
                  state: _state,
                  onState: (ContainerFilter f) => setState(() => _state = f),
                  onQuery: () => setState(() {}),
                  onSelect: _select,
                ),
              ),
              Expanded(
                child: widget.selectedId == null
                    ? const _NothingSelected()
                    : _DetailPane(
                        key: ValueKey<String>(widget.selectedId!),
                        serverId: widget.serverId,
                        containerId: widget.selectedId!,
                        tab: _tab,
                        onTab: (ContainerTab tab) => setState(() => _tab = tab),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ListPane extends ConsumerWidget {
  const _ListPane({
    required this.serverId,
    required this.selectedId,
    required this.filter,
    required this.state,
    required this.onState,
    required this.onQuery,
    required this.onSelect,
  });

  final String serverId;
  final String? selectedId;
  final TextEditingController filter;
  final ContainerFilter state;
  final ValueChanged<ContainerFilter> onState;
  final VoidCallback onQuery;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final AsyncValue<List<ContainerSummary>> all = ref.watch(
      containersProvider(serverId),
    );
    final String query = filter.text.trim().toLowerCase();
    final List<ContainerSummary> list = all.valueOrNull ?? <ContainerSummary>[];

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 24, 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: <Widget>[
                Text(
                  'Containers',
                  style: TextStyle(
                    fontFamily: AppFonts.display,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                    color: t.text,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${list.length} on $serverId',
                    overflow: TextOverflow.ellipsis,
                    style: AppText.small.copyWith(color: t.mutedText),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: FilterField(
              controller: filter,
              hint: 'Filter by name or image',
              onChanged: (_) => onQuery(),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: PillChipRow(
              chips: <Widget>[
                for (final ContainerFilter f in ContainerFilter.values)
                  PillChip(
                    label: '${f.label} ${_count(list, f)}',
                    selected: state == f,
                    onPressed: () => onState(f),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: AsyncSection<List<ContainerSummary>>(
              value: all,
              onRetry: () => ref.invalidate(containersProvider(serverId)),
              loadingRows: 6,
              loadingRowHeight: 52,
              builder: (List<ContainerSummary> data) {
                final List<ContainerSummary> shown = data
                    .where(state.matches)
                    .where(
                      (ContainerSummary c) =>
                          query.isEmpty ||
                          c.name.toLowerCase().contains(query) ||
                          c.image.toLowerCase().contains(query),
                    )
                    .toList(growable: false);
                if (shown.isEmpty) {
                  return SingleChildScrollView(
                    child: EmptyView(
                      glyph: StrokeGlyph.search,
                      title: 'No matching containers',
                      message: 'Nothing here matches that search.',
                      secondary: EmptyAction(
                        'Clear filter',
                        onPressed: () {
                          filter.clear();
                          onQuery();
                          onState(ContainerFilter.all);
                        },
                      ),
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 20),
                  itemCount: shown.length,
                  itemBuilder: (BuildContext context, int i) => _ListRow(
                    serverId: serverId,
                    container: shown[i],
                    selected: shown[i].id == selectedId,
                    onTap: () => onSelect(shown[i].id),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static int _count(List<ContainerSummary> list, ContainerFilter filter) =>
      list.where(filter.matches).length;
}

class _ListRow extends ConsumerStatefulWidget {
  const _ListRow({
    required this.serverId,
    required this.container,
    required this.selected,
    required this.onTap,
  });

  final String serverId;
  final ContainerSummary container;
  final bool selected;
  final VoidCallback onTap;

  @override
  ConsumerState<_ListRow> createState() => _ListRowState();
}

class _ListRowState extends ConsumerState<_ListRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Color color = containerStateColor(t, widget.container.state);
    return ContextMenuRegion(
      actions: () => containerMenuActions(
        context,
        ref,
        widget.serverId,
        widget.container,
        onLogs: widget.onTap,
        onLogWall: () => openLogWall(
          context,
          ref,
          LogPaneRef(
            serverId: widget.serverId,
            containerId: widget.container.id,
            name: widget.container.name,
          ),
        ),
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: widget.onTap,
            child: Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: widget.selected
                    ? t.iconButtonFill
                    : (_hover ? t.surface : null),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          widget.container.name,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.small.copyWith(
                            color: t.text,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.container.image,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: AppFonts.mono,
                            fontSize: 11.5,
                            color: t.mutedText,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    widget.container.stateLabel,
                    style: AppText.pill.copyWith(color: color),
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

class _NothingSelected extends StatelessWidget {
  const _NothingSelected();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: const EmptyView(
          glyph: StrokeGlyph.containers,
          title: 'Pick a container',
          message:
              'Its logs, details, environment and shell open here, next to '
              'the list.',
        ),
      ),
    );
  }
}

class _DetailPane extends ConsumerWidget {
  const _DetailPane({
    super.key,
    required this.serverId,
    required this.containerId,
    required this.tab,
    required this.onTab,
  });

  final String serverId;
  final String containerId;
  final ContainerTab tab;
  final ValueChanged<ContainerTab> onTab;

  ContainerKey get _key => (serverId: serverId, containerId: containerId);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<ContainerDetail> detail = ref.watch(
      containerDetailProvider(_key),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
      child: AsyncSection<ContainerDetail>(
        value: detail,
        onRetry: () => ref.invalidate(containerDetailProvider(_key)),
        loadingRows: 4,
        loadingRowHeight: 64,
        builder: (ContainerDetail d) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _DetailHeader(serverId: serverId, detail: d),
            const SizedBox(height: 16),
            _MiniStats(serverId: serverId, detail: d),
            const SizedBox(height: 16),
            Expanded(child: _tabBody(context, ref, d)),
          ],
        ),
      ),
    );
  }

  Widget _tabBody(BuildContext context, WidgetRef ref, ContainerDetail d) {
    final Widget switcher = _TabSwitcher(
      selected: tab,
      onChanged: onTab,
      available: ref.watch(roleProvider(serverId)),
      running: d.summary.state.isRunning,
    );
    switch (tab) {
      case ContainerTab.logs:
        return LogsView(
          serverId: serverId,
          containerId: containerId,
          toolbarLeading: switcher,
          toolbarTrailing: (bool tight) {
            void open() => openLogWall(
              context,
              ref,
              LogPaneRef(
                serverId: serverId,
                containerId: containerId,
                name: d.name,
              ),
            );
            return <Widget>[
              if (tight)
                DoomIconButton(
                  icon: Icons.grid_view_outlined,
                  semanticLabel: 'Open in log wall',
                  tooltip: 'Open in log wall',
                  size: 36,
                  radius: 10,
                  filled: false,
                  onPressed: open,
                )
              else
                DoomButton(
                  'Open in log wall',
                  icon: Icons.grid_view_outlined,
                  height: 36,
                  radius: 10,
                  onPressed: open,
                ),
            ];
          },
        );
      case ContainerTab.shell:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(children: <Widget>[switcher]),
            const SizedBox(height: 14),
            Expanded(
              child: ExecView(serverId: serverId, containerId: containerId),
            ),
          ],
        );
      case ContainerTab.details:
      case ContainerTab.environment:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(children: <Widget>[switcher]),
            const SizedBox(height: 14),
            Expanded(
              child: SingleChildScrollView(
                child: tab == ContainerTab.details
                    ? _DetailsTab(detail: d)
                    : _EnvironmentTab(serverId: serverId, detail: d),
              ),
            ),
          ],
        );
    }
  }
}

class _TabSwitcher extends StatelessWidget {
  const _TabSwitcher({
    required this.selected,
    required this.onChanged,
    required this.available,
    required this.running,
  });

  final ContainerTab selected;
  final ValueChanged<ContainerTab> onChanged;
  final ServerRole available;
  final bool running;

  bool _enabled(ContainerTab tab) => switch (tab) {
    ContainerTab.environment => available.canReadEnvironment,
    ContainerTab.shell => available.canExec && running,
    _ => true,
  };

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final ContainerTab tab in ContainerTab.values)
            // Flexible so a narrow pane shortens the labels rather than
            // pushing the toolbar onto a second line.
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Semantics(
                  button: true,
                  selected: tab == selected,
                  child: Opacity(
                    opacity: _enabled(tab) ? 1 : 0.4,
                    child: Material(
                      color: tab == selected
                          ? t.strongBorder
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: _enabled(tab) ? () => onChanged(tab) : null,
                        child: Container(
                          height: 30,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Align(
                            widthFactor: 1,
                            child: Text(
                              tab.label,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.small.copyWith(
                                fontWeight: FontWeight.w600,
                                color: tab == selected ? t.text : t.mutedText,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DetailHeader extends ConsumerWidget {
  const _DetailHeader({required this.serverId, required this.detail});

  final String serverId;
  final ContainerDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final ServerRole role = ref.watch(roleProvider(serverId));
    final bool running = detail.summary.state.isRunning;
    final String ports = detail.portLines.isEmpty
        ? 'no published ports'
        : detail.portLines.join(', ');
    // With both action labels spelled out the row needs about 250 px, which
    // leaves a narrow pane nothing for the name and the state pill. Below the
    // threshold the two actions drop to icons, the way the logs toolbar does.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) => _header(
        context,
        ref,
        t,
        role,
        running,
        ports,
        tight: c.maxWidth < 560,
      ),
    );
  }

  Widget _header(
    BuildContext context,
    WidgetRef ref,
    AppTokens t,
    ServerRole role,
    bool running,
    String ports, {
    required bool tight,
  }) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Flexible(
                    child: Text(
                      detail.name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: AppFonts.display,
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                        color: t.text,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  StatusPill(
                    detail.summary.pillLabel,
                    tone: containerStateTone(detail.summary.state),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // The port arrow is a painted glyph — no bundled face has
              // U+2192 — and a placeholder span cannot live inside a
              // selection region, so this line trades selection for a
              // readable arrow. The id stays selectable on the Details tab.
              GlyphText(
                '${detail.summary.image} · ${detail.id} · $ports',
                style: TextStyle(
                  fontFamily: AppFonts.mono,
                  fontSize: 12,
                  color: t.mutedText,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        if (tight)
          DoomIconButton(
            icon: Icons.refresh,
            semanticLabel: 'Restart ${detail.name}',
            tooltip: 'Restart',
            size: 36,
            radius: 10,
            filled: false,
            onPressed: role.canOperate && running
                ? () => restartContainer(context, ref, serverId, detail.summary)
                : null,
          )
        else
          DoomButton(
            'Restart',
            icon: Icons.refresh,
            height: 36,
            radius: 10,
            onPressed: role.canOperate && running
                ? () => restartContainer(context, ref, serverId, detail.summary)
                : null,
          ),
        const SizedBox(width: 8),
        if (tight)
          DoomIconButton(
            icon: running ? Icons.stop_outlined : Icons.play_arrow,
            semanticLabel: '${running ? 'Stop' : 'Start'} ${detail.name}',
            tooltip: running ? 'Stop' : 'Start',
            size: 36,
            radius: 10,
            filled: false,
            foreground: running ? t.danger : t.text,
            onPressed: role.canOperate
                ? () => startOrStopContainer(
                    context,
                    ref,
                    serverId,
                    detail.summary,
                  )
                : null,
          )
        else
          DoomButton(
            running ? 'Stop' : 'Start',
            icon: running ? Icons.stop : Icons.play_arrow,
            height: 36,
            radius: 10,
            tone: running ? ButtonTone.danger : ButtonTone.outline,
            onPressed: role.canOperate
                ? () => startOrStopContainer(
                    context,
                    ref,
                    serverId,
                    detail.summary,
                  )
                : null,
          ),
        const SizedBox(width: 4),
        if (role.canRemove)
          DoomIconButton(
            icon: Icons.delete_outline,
            semanticLabel: 'Remove container',
            size: 36,
            radius: 10,
            filled: false,
            foreground: t.mutedText,
            onPressed: () => _remove(context, ref),
          ),
      ],
    );
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
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
            'DELETE /v1/containers/${detail.id}?force=true&volumes=false',
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
            detail.id,
            force: true,
            confirmed: outcome.confirmation,
          ),
      success: '${detail.name} removed',
    );
    if (removed && context.mounted) {
      context.go('/s/$serverId/containers');
    }
  }
}

class _MiniStats extends ConsumerWidget {
  const _MiniStats({required this.serverId, required this.detail});

  final String serverId;
  final ContainerDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final ContainerStats s =
        ref
            .watch(
              containerStatsProvider((
                serverId: serverId,
                containerId: detail.id,
              )),
            )
            .valueOrNull ??
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
            child: _Mini(label: 'CPU', value: formatPercent(s.cpuPercent)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _Mini(
              label: 'Memory',
              value: formatBytes(s.memoryBytes).split(' ').first,
              suffix:
                  '${formatBytes(s.memoryBytes).split(' ').last} of '
                  '${formatBytes(s.memoryLimitBytes)}',
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _Mini(
              label: 'Network in',
              value: (s.netInBytesPerSecond / (1024 * 1024)).toStringAsFixed(1),
              suffix: 'MB/s',
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _Mini(
              label: 'Restarts',
              value: '${detail.summary.restartCount}',
              color: detail.summary.restartCount > 0 ? t.warning : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _Mini extends StatelessWidget {
  const _Mini({
    required this.label,
    required this.value,
    this.suffix,
    this.color,
  });

  final String label;
  final String value;
  final String? suffix;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return DoomCard(
      radius: 14,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label, style: AppText.tiny.copyWith(color: t.mutedText)),
          const SizedBox(height: 6),
          Text.rich(
            TextSpan(
              children: <InlineSpan>[
                TextSpan(text: value),
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
            style: AppText.figureSmall.copyWith(color: color ?? t.text),
          ),
        ],
      ),
    );
  }
}

class _DetailsTab extends StatelessWidget {
  const _DetailsTab({required this.detail});

  final ContainerDetail detail;

  @override
  Widget build(BuildContext context) {
    return RowGroup(
      children: <Widget>[
        DetailRow(
          'Ports',
          detail.portLines.isEmpty
              ? 'none published'
              : detail.portLines.join(', '),
          mono: detail.portLines.isNotEmpty,
        ),
        DetailRow(
          'Stack',
          detail.summary.stack.isEmpty ? 'none' : detail.summary.stack,
        ),
        DetailRow('Network', detail.networkNames, mono: true),
        DetailRow('Restart policy', detail.restartPolicy, mono: true),
        DetailRow('Command', detail.command, mono: true),
        DetailRow('Container ID', detail.id, mono: true),
        DetailRow(
          'Volumes',
          detail.mountNames.isEmpty ? 'none' : detail.mountNames.join(' · '),
          mono: detail.mountNames.isNotEmpty,
        ),
      ],
    );
  }
}

class _EnvironmentTab extends ConsumerStatefulWidget {
  const _EnvironmentTab({required this.serverId, required this.detail});

  final String serverId;
  final ContainerDetail detail;

  @override
  ConsumerState<_EnvironmentTab> createState() => _EnvironmentTabState();
}

class _EnvironmentTabState extends ConsumerState<_EnvironmentTab> {
  Map<String, String>? _values;
  bool _busy = false;

  Future<void> _reveal() async {
    setState(() => _busy = true);
    try {
      final Map<String, String> env = await ref
          .read(agentApiProvider(widget.serverId))
          .containerEnv(widget.detail.id);
      if (mounted) setState(() => _values = env);
    } on AgentException catch (error) {
      if (mounted) notify(context, error.toString(), danger: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Map<String, String>? values = _values;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                values == null
                    ? '${widget.detail.envNames.length} variables, values '
                          'hidden until you ask for them'
                    : '${values.length} variables · this call is audited on '
                          'the agent',
                style: AppText.small.copyWith(color: t.mutedText),
              ),
            ),
            if (values == null)
              DoomButton(
                'Show values',
                height: 36,
                radius: 10,
                busy: _busy,
                onPressed: _reveal,
              ),
          ],
        ),
        const SizedBox(height: 12),
        RowGroup(
          children: <Widget>[
            for (final String name in widget.detail.envNames)
              DetailRow(name, values?[name] ?? '••••••', mono: true),
          ],
        ),
      ],
    );
  }
}
