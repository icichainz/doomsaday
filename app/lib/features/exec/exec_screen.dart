import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/exec_session.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../layout/layout.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/primitives.dart';
import '../../widgets/state_views.dart';
import '../containers/containers_pane.dart';

/// Screen with the interactive shell. At 1100 and up the same route is the
/// containers split view with the Shell tab open, which reuses [ExecView].
class ExecScreen extends ConsumerWidget {
  const ExecScreen({
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
        initialTab: ContainerTab.shell,
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
          child: ExecView(
            serverId: serverId,
            containerId: containerId,
            header: (BuildContext context, String status, PillTone tone) =>
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    BackLink(name),
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        Text(
                          'Shell',
                          style: AppText.screenTitle.copyWith(color: t.text),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: StatusPill(status, dot: true, tone: tone),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$containerId · $serverId',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.monoSmall.copyWith(color: t.mutedText),
                    ),
                  ],
                ),
          ),
        ),
      ),
    );
  }
}

/// The keys an on-screen keyboard lacks, as the bytes a terminal sends.
enum TerminalKey {
  tab('Tab', '\t'),
  interrupt('Ctrl+C', '\x03'),
  up('Previous command', '\x1B[A'),
  down('Next command', '\x1B[B'),
  escape('Esc', '\x1B');

  const TerminalKey(this.label, this.bytes);

  final String label;
  final String bytes;
}

/// What the status pill says: `Connecting`, `Connected`, `Exited 0`.
(String, PillTone) execStatus({
  required bool connecting,
  required bool failed,
  required int? exitCode,
}) {
  if (connecting) return ('Connecting', PillTone.warning);
  if (failed) return ('Failed', PillTone.danger);
  if (exitCode == null) return ('Connected', PillTone.accent);
  if (exitCode < 0) return ('Disconnected', PillTone.neutral);
  return ('Exited $exitCode', PillTone.neutral);
}

/// The terminal itself: the WebSocket session, its output, the input line and
/// the exit code. Deliberately small, admin only, and every session is
/// audited on the agent (API_NOTES §15).
class ExecView extends ConsumerStatefulWidget {
  const ExecView({
    super.key,
    required this.serverId,
    required this.containerId,
    this.header,
  });

  final String serverId;
  final String containerId;

  /// Drawn above the terminal; the phone screen puts its back link there.
  final Widget Function(BuildContext context, String status, PillTone tone)?
  header;

  @override
  ConsumerState<ExecView> createState() => _ExecViewState();
}

class _ExecViewState extends ConsumerState<ExecView> {
  static const int _maxChars = 200000;

  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();
  final StringBuffer _buffer = StringBuffer();

  ExecSession? _session;
  StreamSubscription<String>? _output;
  Object? _error;
  bool _connecting = true;
  int? _exitCode;
  (int, int)? _size;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _output?.cancel();
    unawaited(_session?.close());
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
      _exitCode = null;
      _buffer.clear();
    });
    try {
      final ExecSession session = await ref
          .read(agentApiProvider(widget.serverId))
          .exec(
            widget.containerId,
            cols: _size?.$1 ?? 80,
            rows: _size?.$2 ?? 24,
          );
      if (!mounted) {
        await session.close();
        return;
      }
      _session = session;
      _output = session.output.listen(
        _append,
        onError: (Object error) {
          if (mounted) setState(() => _error = error);
        },
      );
      unawaited(
        session.exitCode.then((int? code) {
          if (mounted) setState(() => _exitCode = code ?? -1);
        }),
      );
      setState(() => _connecting = false);
      _focus.requestFocus();
    } on AgentException catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
          _connecting = false;
        });
      }
    }
  }

  void _append(String chunk) {
    if (!mounted) return;
    setState(() {
      _buffer.write(stripAnsi(chunk));
      if (_buffer.length > _maxChars) {
        final String kept = _buffer.toString();
        _buffer
          ..clear()
          ..write(kept.substring(kept.length - _maxChars));
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _submit() {
    final ExecSession? session = _session;
    if (session == null || _exitCode != null) return;
    session.send('${_input.text}\n');
    _input.clear();
    _focus.requestFocus();
  }

  /// Tab completes what is typed so far, so the line goes with it; the other
  /// keys are sent on their own.
  void _sendKey(TerminalKey key) {
    final ExecSession? session = _session;
    if (session == null || _exitCode != null) return;
    if (key == TerminalKey.tab) {
      session.send('${_input.text}${key.bytes}');
      _input.clear();
    } else {
      session.send(key.bytes);
    }
    _focus.requestFocus();
  }

  /// The terminal is sized from the box the output actually occupies, so the
  /// shell wraps where the screen does.
  void _reportSize(Size box) {
    const double charWidth = 7.2; // IBM Plex Mono at 12pt
    const double lineHeight = 17;
    final int cols = (box.width / charWidth).floor().clamp(10, 500);
    final int rows = (box.height / lineHeight).floor().clamp(5, 200);
    if (_size?.$1 == cols && _size?.$2 == rows) return;
    _size = (cols, rows);
    _session?.resize(cols: cols, rows: rows);
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool live = _session != null && _exitCode == null && _error == null;
    final bool touch = !WindowClass.of(context).usesDesktopExtras;
    final double rowHeight = touch ? 44 : context.density.button;
    final (String status, PillTone tone) = execStatus(
      connecting: _connecting,
      failed: _error != null,
      exitCode: _exitCode,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.header != null) ...<Widget>[
          widget.header!(context, status, tone),
          const SizedBox(height: 12),
        ],
        Expanded(child: _body(t)),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Icon(Icons.shield_outlined, size: 14, color: t.mutedText),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Admin only. Opening and closing it is in the Activity log.',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.tiny.copyWith(color: t.mutedText),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_exitCode != null)
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _exitCode! < 0
                      ? 'The session ended.'
                      : 'The shell exited with code $_exitCode.',
                  style: AppText.small.copyWith(color: t.mutedText),
                ),
              ),
              DoomButton(
                'Open again',
                icon: Icons.refresh,
                height: rowHeight,
                radius: 12,
                onPressed: _connect,
              ),
            ],
          )
        else ...<Widget>[
          if (touch) ...<Widget>[
            _KeyRow(enabled: live, onKey: _sendKey),
            const SizedBox(height: 12),
          ],
          Row(
            children: <Widget>[
              Expanded(
                child: _InputLine(
                  controller: _input,
                  focusNode: _focus,
                  enabled: live,
                  height: rowHeight,
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(width: 8),
              DoomButton(
                'Send',
                icon: Icons.keyboard_return,
                tone: ButtonTone.primary,
                height: rowHeight,
                radius: 12,
                onPressed: live ? _submit : null,
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _body(AppTokens t) {
    if (_error != null) {
      return ErrorView(error: _error!, onRetry: _connect);
    }
    if (_connecting) return const LoadingView(rows: 3, height: 22);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _reportSize(constraints.biggest),
        );
        return Semantics(
          label: 'Terminal output',
          container: true,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: t.codeBlock,
              borderRadius: AppShape.smallCardRadius,
              border: Border.all(color: t.faintDivider),
            ),
            child: SingleChildScrollView(
              controller: _scroll,
              child: SelectableText(
                _buffer.toString(),
                style: terminalTextStyle.copyWith(color: t.codeText),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// IBM Plex Mono 12.5 on 1.5 lines, the terminal surface on every board.
const TextStyle terminalTextStyle = TextStyle(
  fontFamily: AppFonts.mono,
  fontSize: 12.5,
  height: 1.5,
);

/// Tab, Ctrl+C, the two arrows and Esc, one row of equal keys.
class _KeyRow extends StatelessWidget {
  const _KeyRow({required this.enabled, required this.onKey});

  final bool enabled;
  final ValueChanged<TerminalKey> onKey;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Row(
      children: <Widget>[
        for (final TerminalKey key in TerminalKey.values) ...<Widget>[
          if (key.index > 0) const SizedBox(width: 6),
          Expanded(
            child: Semantics(
              button: true,
              label: key.label,
              excludeSemantics: true,
              child: Opacity(
                opacity: enabled ? 1 : 0.5,
                child: Material(
                  color: t.surface,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: enabled ? () => onKey(key) : null,
                    child: Container(
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: t.border),
                      ),
                      child: switch (key) {
                        TerminalKey.up => Icon(
                          Icons.arrow_upward,
                          size: 18,
                          color: t.text,
                        ),
                        TerminalKey.down => Icon(
                          Icons.arrow_downward,
                          size: 18,
                          color: t.text,
                        ),
                        _ => Text(
                          key.label,
                          style: TextStyle(
                            fontFamily: AppFonts.mono,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: t.text,
                          ),
                        ),
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _InputLine extends StatelessWidget {
  const _InputLine({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.onSubmitted,
    this.height = 44,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final ValueChanged<String> onSubmitted;
  final double height;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.strongBorder),
      ),
      child: Row(
        children: <Widget>[
          Text(
            r'$',
            style: AppText.mono.copyWith(color: t.accent, fontSize: 14),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              enabled: enabled,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.send,
              onSubmitted: onSubmitted,
              style: TextStyle(
                color: t.text,
                fontSize: 14,
                fontFamily: AppFonts.mono,
              ),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Type a command',
                hintStyle: TextStyle(
                  color: t.mutedText,
                  fontSize: 14,
                  fontFamily: AppFonts.mono,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
