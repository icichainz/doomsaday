/// D6 — the log wall: live log panes from any containers on any servers.
///
/// Each pane owns exactly one subscription to `GET
/// /containers/{id}/logs/stream`, and drops it the moment the pane is closed,
/// paused or the wall stops being built, so an idle window holds nothing open.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models.dart';
import '../../data/preferences.dart';
import '../../data/providers.dart';
import '../../data/servers_repository.dart';
import '../../edition/edition.dart';
import '../../edition/locked_feature.dart';
import '../../layout/layout.dart';
import '../../theme/app_theme.dart';
import '../../theme/state_colors.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/desktop.dart';
import '../../widgets/filter_field.dart';
import '../../widgets/primitives.dart';
import '../../widgets/state_views.dart';
import '../../widgets/surfaces.dart';
import 'log_wall_controller.dart';

/// "Open in log wall", from a row, a context menu or the logs tab.
///
/// On an edition without the wall the pane is not remembered: the locked page
/// explains the feature rather than collecting state for it.
void openLogWall(BuildContext context, WidgetRef ref, LogPaneRef pane) {
  if (ref.read(editionProvider).logWall) {
    ref.read(logWallProvider.notifier).add(pane);
  }
  GoRouter.of(context).go('/all/logwall');
}

class LogWallScreen extends ConsumerStatefulWidget {
  const LogWallScreen({super.key});

  @override
  ConsumerState<LogWallScreen> createState() => _LogWallScreenState();
}

class _LogWallScreenState extends ConsumerState<LogWallScreen> {
  final TextEditingController _filter = TextEditingController();
  bool _pausedAll = false;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _addPane() async {
    final LogPaneRef? pane = await showAdaptiveModal<LogPaneRef>(
      context,
      builder: (BuildContext context, bool sheet) => const _PanePicker(),
    );
    if (pane != null) ref.read(logWallProvider.notifier).add(pane);
  }

  @override
  Widget build(BuildContext context) {
    if (!WindowClass.of(context).usesDesktopExtras) {
      return const NeedsAWiderWindow(title: 'Log wall');
    }
    // Before a single pane is built: a locked wall opens no stream.
    if (!ref.watch(editionProvider).logWall) {
      return const LockedFeature(feature: ProFeature.logWall);
    }
    final AppTokens t = context.tokens;
    final List<LogPaneRef> panes = ref.watch(logWallProvider);
    final int servers = panes.map((LogPaneRef p) => p.serverId).toSet().length;
    return DesktopPage(
      gap: 16,
      fill: true,
      children: <Widget>[
        DesktopHeader(
          title: 'Log wall',
          subtitle:
              '${panes.length} live stream${panes.length == 1 ? '' : 's'} '
              'across $servers server${servers == 1 ? '' : 's'}',
          actions: <Widget>[
            FilterField(
              controller: _filter,
              hint: 'Filter every pane',
              width: 260,
              onChanged: (_) => setState(() {}),
            ),
            DoomButton(
              _pausedAll ? 'Resume all' : 'Pause all',
              icon: _pausedAll ? Icons.play_arrow : Icons.pause,
              height: 36,
              radius: 10,
              onPressed: () => setState(() => _pausedAll = !_pausedAll),
            ),
            DoomButton(
              'Add pane',
              icon: Icons.add,
              height: 36,
              radius: 10,
              tone: ButtonTone.primary,
              onPressed: ref.read(logWallProvider.notifier).isFull
                  ? null
                  : _addPane,
            ),
          ],
        ),
        if (panes.isEmpty)
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: EmptyView(
                  icon: Icons.grid_view_outlined,
                  title: 'No panes yet',
                  message:
                      'Add up to ${LogWallController.maxPanes} containers from '
                      'any paired server and watch their logs side by side.',
                  action: DoomButton(
                    'Add pane',
                    icon: Icons.add,
                    tone: ButtonTone.primary,
                    onPressed: _addPane,
                  ),
                ),
              ),
            ),
          )
        else
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final int columns = panes.length == 1 ? 1 : 2;
                return GridView.count(
                  crossAxisCount: columns,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: _ratio(constraints, panes.length, columns),
                  children: <Widget>[
                    for (final LogPaneRef pane in panes)
                      LogPane(
                        key: ValueKey<String>(pane.key),
                        pane: pane,
                        query: _filter.text.trim().toLowerCase(),
                        pausedAll: _pausedAll,
                        onClose: () =>
                            ref.read(logWallProvider.notifier).remove(pane),
                      ),
                  ],
                );
              },
            ),
          ),
        if (panes.isNotEmpty)
          Text(
            'Every pane holds one stream open. Closing a pane, or leaving the '
            'log wall, closes it.',
            style: AppText.tiny.copyWith(color: t.mutedText),
          ),
      ],
    );
  }

  static double _ratio(BoxConstraints box, int count, int columns) {
    final int rows = (count / columns).ceil();
    final double width = (box.maxWidth - (columns - 1) * 12) / columns;
    final double height = (box.maxHeight - (rows - 1) * 12) / rows;
    if (!height.isFinite || height <= 0) return 1.6;
    return width / height;
  }
}

/// One live pane. The stream is opened in [initState] and cancelled in
/// [dispose] and whenever the pane is paused.
class LogPane extends ConsumerStatefulWidget {
  const LogPane({
    super.key,
    required this.pane,
    required this.query,
    required this.pausedAll,
    required this.onClose,
  });

  final LogPaneRef pane;
  final String query;
  final bool pausedAll;
  final VoidCallback onClose;

  @override
  ConsumerState<LogPane> createState() => _LogPaneState();
}

class _LogPaneState extends ConsumerState<LogPane> {
  final List<LogLine> _lines = <LogLine>[];
  StreamSubscription<LogLine>? _subscription;
  bool _paused = false;
  Object? _error;

  bool get _stopped => _paused || widget.pausedAll;

  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void didUpdateWidget(LogPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_stopped) {
      _cancel();
    } else if (_subscription == null && _error == null) {
      _follow();
    }
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  void _cancel() {
    _subscription?.cancel();
    _subscription = null;
  }

  void _follow() {
    _cancel();
    try {
      _subscription = ref
          .read(agentApiProvider(widget.pane.serverId))
          .logStream(widget.pane.containerId)
          .listen(
            (LogLine line) {
              if (!mounted) return;
              setState(() {
                _lines.add(line);
                // "Log lines kept per stream" applies to every pane of the
                // wall too, so six panes cannot quietly hold six buffers of
                // whatever size they like.
                capLogBuffer(
                  _lines,
                  ref.read(preferencesProvider).logBuffer.lines,
                );
              });
            },
            onError: (Object error) {
              if (mounted) setState(() => _error = error);
            },
          );
    } on AgentException catch (error) {
      _error = error;
    }
  }

  void _togglePause() {
    setState(() => _paused = !_paused);
    if (_paused) {
      _cancel();
    } else if (!widget.pausedAll) {
      _follow();
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final ContainerSummary? summary = _summary();
    final Color dot = summary == null
        ? t.mutedText
        : containerStateColor(t, summary.state);
    final List<LogLine> shown = widget.query.isEmpty
        ? _lines
        : _lines
              .where((LogLine l) => l.line.toLowerCase().contains(widget.query))
              .toList(growable: false);
    return Container(
      decoration: BoxDecoration(
        color: t.codeBlock,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          Container(
            height: 42,
            padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
            decoration: BoxDecoration(
              color: t.surface,
              border: Border(bottom: BorderSide(color: t.border)),
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Text(
                  summary?.name ?? widget.pane.name,
                  style: AppText.small.copyWith(
                    color: t.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.pane.serverId,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.tiny.copyWith(color: t.mutedText),
                  ),
                ),
                // The badge reports the container, not the stream: a pane on
                // something that is restarting says so (D6).
                StatusPill(
                  _stopped
                      ? 'Paused'
                      : (summary == null ||
                                summary.state == ContainerState.running
                            ? 'Live'
                            : summary.stateLabel),
                  tone: _stopped
                      ? PillTone.warning
                      : (summary == null ||
                                summary.state == ContainerState.running
                            ? PillTone.accent
                            : containerStateTone(summary.state)),
                ),
                const SizedBox(width: 4),
                DoomIconButton(
                  icon: _paused ? Icons.play_arrow : Icons.pause,
                  semanticLabel:
                      '${_paused ? 'Resume' : 'Pause'} ${widget.pane.name}',
                  size: 30,
                  radius: 10,
                  filled: false,
                  foreground: t.mutedText,
                  onPressed: _togglePause,
                ),
                DoomIconButton(
                  icon: Icons.close,
                  semanticLabel: 'Close ${widget.pane.name}',
                  size: 30,
                  radius: 10,
                  filled: false,
                  foreground: t.mutedText,
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          Expanded(
            child: _error != null
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: ErrorView(error: _error!, onRetry: _follow),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    itemCount: shown.length,
                    itemBuilder: (BuildContext context, int i) =>
                        _PaneLine(line: shown[i]),
                  ),
          ),
        ],
      ),
    );
  }

  ContainerSummary? _summary() {
    final List<ContainerSummary>? all = ref
        .watch(containersProvider(widget.pane.serverId))
        .valueOrNull;
    if (all == null) return null;
    for (final ContainerSummary c in all) {
      if (c.id == widget.pane.containerId) return c;
    }
    return null;
  }
}

class _PaneLine extends StatelessWidget {
  const _PaneLine({required this.line});

  final LogLine line;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Color level = switch (line.level) {
      LogLevel.info => t.info,
      LogLevel.warn => t.warning,
      LogLevel.error => t.danger,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: SelectionArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              line.clock,
              style: AppText.logLine.copyWith(color: t.mutedText),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 34,
              child: Text(
                line.levelLabel,
                style: AppText.logLine.copyWith(
                  color: level,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                line.line,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.logLine.copyWith(color: t.codeText),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Add pane": pick a server, then one of its containers.
class _PanePicker extends ConsumerStatefulWidget {
  const _PanePicker();

  @override
  ConsumerState<_PanePicker> createState() => _PanePickerState();
}

class _PanePickerState extends ConsumerState<_PanePicker> {
  String? _serverId;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final ServersRepository repo = ref.watch(serversRepositoryProvider);
    final String? serverId = _serverId;
    return ModalBody(
      handle: false,
      children: <Widget>[
        Text(
          serverId == null ? 'Pick a server' : 'Pick a container',
          style: AppText.sheetTitle.copyWith(color: t.text, fontSize: 22),
        ),
        if (serverId == null)
          RowGroup(
            children: <Widget>[
              for (final Server server in repo.servers)
                NavRow(
                  label: server.name,
                  value: server.host,
                  onTap: () => setState(() => _serverId = server.id),
                ),
            ],
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: SingleChildScrollView(
              child: ref
                  .watch(containersProvider(serverId))
                  .when(
                    loading: () => const LoadingView(rows: 4, height: 44),
                    error: (Object e, StackTrace _) => ErrorView(
                      error: e,
                      onRetry: () =>
                          ref.invalidate(containersProvider(serverId)),
                    ),
                    data: (List<ContainerSummary> list) => RowGroup(
                      children: <Widget>[
                        for (final ContainerSummary c in list)
                          NavRow(
                            label: c.name,
                            value: c.stateLabel,
                            onTap: () => Navigator.of(context).pop(
                              LogPaneRef(
                                serverId: serverId,
                                containerId: c.id,
                                name: c.name,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
            ),
          ),
      ],
    );
  }
}
