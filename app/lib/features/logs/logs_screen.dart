import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/preferences.dart';
import '../../data/providers.dart';
import '../../layout/layout.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/filter_field.dart';
import '../../widgets/notify.dart';
import '../../widgets/primitives.dart';
import '../../widgets/state_views.dart';
import '../containers/containers_pane.dart';
import '../../widgets/stroke_icons.dart';

/// Screen 8 — Live logs, with Pause and a line filter.
///
/// At 1100 and up the same route is the containers split view with the Logs
/// tab open, which reuses [LogsView] rather than a second implementation.
class LogsScreen extends ConsumerWidget {
  const LogsScreen({
    super.key,
    required this.serverId,
    required this.containerId,
  });

  final String serverId;
  final String containerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    if (WindowClass.of(context).usesDesktopExtras) {
      return ContainersPane(
        serverId: serverId,
        selectedId: containerId,
        initialTab: ContainerTab.logs,
      );
    }
    final String name =
        ref
            .watch(
              containerDetailProvider((
                serverId: serverId,
                containerId: containerId,
              )),
            )
            .valueOrNull
            ?.name ??
        containerId;

    return Scaffold(
      backgroundColor: t.ground,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
          child: LogsView(
            serverId: serverId,
            containerId: containerId,
            header: (BuildContext context, bool paused) => Row(
              children: <Widget>[
                DoomIconButton(
                  glyph: StrokeGlyph.chevronLeft,
                  semanticLabel: 'Back to $name',
                  size: 44,
                  radius: 12,
                  filled: false,
                  foreground: t.mutedText,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        'Logs',
                        style: TextStyle(
                          fontFamily: AppFonts.display,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                          color: t.text,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        name,
                        style: AppText.monoSmall.copyWith(color: t.mutedText),
                      ),
                    ],
                  ),
                ),
                StatusPill(
                  paused ? 'Paused' : 'Live',
                  dot: true,
                  tone: paused ? PillTone.warning : PillTone.accent,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The live log body: the seed request, the SSE follow, the filter, Pause and
/// the line list. Used by the phone screen and by the desktop pane.
class LogsView extends ConsumerStatefulWidget {
  const LogsView({
    super.key,
    required this.serverId,
    required this.containerId,
    this.header,
    this.toolbarLeading,
    this.toolbarTrailing,
  });

  final String serverId;
  final String containerId;

  /// Drawn above everything; the phone screen puts its back link there.
  final Widget Function(BuildContext context, bool paused)? header;

  /// The pane's tab switcher, which shares the toolbar line in D2.
  final Widget? toolbarLeading;

  /// Extra controls at the end of the toolbar. `tight` is true when the pane
  /// has no room for their labels, so the caller can hand back icon buttons
  /// instead — the toolbar is one line at every width (D2).
  final List<Widget> Function(bool tight)? toolbarTrailing;

  @override
  ConsumerState<LogsView> createState() => _LogsViewState();
}

/// Below this the toolbar's trailing buttons lose their labels. A 1440 px
/// window leaves the detail pane about 720 px, which is already too little for
/// four tabs, a filter, a range and three buttons written out.
const double _roomyToolbar = 900;

/// Below this even the range button and the tab labels give way. A 1100 px
/// window leaves the pane under 400 px.
const double _crampedToolbar = 500;

class _LogsViewState extends ConsumerState<LogsView> {
  final List<LogLine> _lines = <LogLine>[];
  final TextEditingController _filter = TextEditingController();
  final ScrollController _scroll = ScrollController();

  StreamSubscription<LogLine>? _subscription;
  bool _paused = false;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(LogsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.containerId != widget.containerId ||
        oldWidget.serverId != widget.serverId) {
      _subscription?.cancel();
      _subscription = null;
      _lines.clear();
      _load();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _filter.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<LogLine> seed = await ref
          .read(agentApiProvider(widget.serverId))
          .logs(widget.containerId);
      if (!mounted) return;
      setState(() {
        _lines
          ..clear()
          ..addAll(seed);
        _trim();
        _loading = false;
      });
      _follow();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _loading = false;
        });
      }
    }
  }

  void _follow() {
    _subscription?.cancel();
    _subscription = ref
        .read(agentApiProvider(widget.serverId))
        .logStream(widget.containerId)
        .listen((LogLine line) {
          if (_paused || !mounted) return;
          setState(() {
            _lines.add(line);
            _trim();
          });
          _scrollToEnd();
        });
  }

  /// "Log lines kept per stream": the oldest go first, and the footer counts
  /// what is actually held rather than everything that ever arrived.
  void _trim() =>
      capLogBuffer(_lines, ref.read(preferencesProvider).logBuffer.lines);

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool desktop = WindowClass.of(context).usesDesktopExtras;
    final String query = _filter.text.trim().toLowerCase();
    final List<LogLine> shown = query.isEmpty
        ? _lines
        : _lines
              .where((LogLine l) => l.line.toLowerCase().contains(query))
              .toList(growable: false);

    final Widget filter = FilterField(
      controller: _filter,
      hint: 'Filter lines',
      width: desktop ? 220 : null,
      onChanged: (_) => setState(() {}),
    );
    final Widget range = DoomButton(
      'Last 15 min',
      height: desktop ? 36 : 44,
      radius: desktop ? 10 : 12,
      onPressed: () =>
          notify(context, 'Range picking arrives with the real agent build'),
    );
    final Widget rangeIcon = DoomIconButton(
      icon: Icons.schedule,
      semanticLabel: 'Last 15 min',
      tooltip: 'Last 15 min',
      size: 36,
      radius: 10,
      filled: false,
      foreground: t.text,
      onPressed: () =>
          notify(context, 'Range picking arrives with the real agent build'),
    );
    final Widget pause = desktop
        ? DoomIconButton(
            icon: _paused ? Icons.play_arrow : Icons.pause,
            semanticLabel: _paused ? 'Resume live logs' : 'Pause live logs',
            size: 36,
            radius: 10,
            filled: false,
            foreground: t.text,
            onPressed: () => setState(() => _paused = !_paused),
          )
        : DoomButton(
            _paused ? 'Resume' : 'Pause',
            icon: _paused ? Icons.play_arrow : Icons.pause,
            height: 48,
            radius: 14,
            onPressed: () => setState(() => _paused = !_paused),
          );
    final Widget download = DoomIconButton(
      glyph: StrokeGlyph.download,
      semanticLabel: 'Download logs',
      size: desktop ? 36 : 48,
      radius: desktop ? 10 : 14,
      filled: false,
      fill: desktop ? null : t.accent,
      foreground: desktop ? t.text : t.onAccent,
      onPressed: () => notify(
        context,
        'GET /v1/containers/${widget.containerId}/logs queued',
      ),
    );
    final Widget body = Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.codeBlock,
        borderRadius: AppShape.smallCardRadius,
        border: Border.all(color: t.faintDivider),
      ),
      child: _body(shown, query),
    );

    if (desktop) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.header != null) ...<Widget>[
            widget.header!(context, _paused),
            const SizedBox(height: 14),
          ],
          // D2 keeps the tabs, the filter, the range, pause, download and
          // "Open in log wall" on ONE line. The filter is what gives way when
          // the pane narrows — it slides right against the range button and
          // then shrinks — and the trailing buttons drop their labels rather
          // than wrapping onto a second row.
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) {
              // Three tiers, and never a second row: first the trailing
              // buttons drop their labels, then the range does, then the tab
              // labels themselves give way. The filter shrinks throughout.
              final bool tight = box.maxWidth < _roomyToolbar;
              final bool cramped = box.maxWidth < _crampedToolbar;
              final List<Widget> controls = <Widget>[
                cramped ? rangeIcon : range,
                pause,
                download,
                ...?widget.toolbarTrailing?.call(tight),
              ];
              final Widget? leading = widget.toolbarLeading;
              return Row(
                children: <Widget>[
                  if (leading != null)
                    if (cramped) Flexible(child: leading) else leading,
                  Expanded(
                    child: Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 220),
                        child: Padding(
                          padding: const EdgeInsets.only(left: 10),
                          child: filter,
                        ),
                      ),
                    ),
                  ),
                  for (final Widget control in controls) ...<Widget>[
                    const SizedBox(width: 8),
                    control,
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          Expanded(child: body),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _paused ? t.warning : t.accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${_paused ? 'Paused' : 'Live · following'} · '
                '${formatCount(_lines.length)} lines',
                style: AppText.small.copyWith(color: t.mutedText),
              ),
            ],
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.header != null) ...<Widget>[
          widget.header!(context, _paused),
          const SizedBox(height: 14),
        ],
        Row(
          children: <Widget>[
            Expanded(child: filter),
            const SizedBox(width: 8),
            range,
          ],
        ),
        const SizedBox(height: 14),
        Expanded(child: body),
        const SizedBox(height: 14),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '${_paused ? 'Paused' : 'Following'} · '
                '${formatCount(_lines.length)} lines',
                style: AppText.small.copyWith(color: t.mutedText),
              ),
            ),
            pause,
            const SizedBox(width: 8),
            download,
          ],
        ),
      ],
    );
  }

  Widget _body(List<LogLine> shown, String query) {
    if (_loading) return const LoadingView(rows: 3, height: 22);
    if (_error != null) return ErrorView(error: _error!, onRetry: _load);
    if (shown.isEmpty) {
      return EmptyView(
        glyph: StrokeGlyph.search,
        title: query.isEmpty ? 'No log lines yet' : 'No matching lines',
        message: query.isEmpty
            ? 'This container has not written anything since the agent started following it.'
            : 'Nothing in the buffered lines contains "$query".',
      );
    }
    return SelectionArea(
      child: ListView.separated(
        controller: _scroll,
        padding: EdgeInsets.zero,
        itemCount: shown.length,
        separatorBuilder: (_, __) => const SizedBox(height: 7),
        itemBuilder: (BuildContext context, int i) => _LogRow(line: shown[i]),
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.line});

  final LogLine line;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Color level = switch (line.level) {
      LogLevel.info => t.info,
      LogLevel.warn => t.warning,
      LogLevel.error => t.danger,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(line.clock, style: AppText.logLine.copyWith(color: t.mutedText)),
        const SizedBox(width: 8),
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
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            line.line,
            style: AppText.logLine.copyWith(color: t.codeText),
          ),
        ),
      ],
    );
  }
}
