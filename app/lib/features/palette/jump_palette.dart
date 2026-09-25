/// Cmd+K — "Jump to a container, stack or server" (DesktopPalette).
///
/// The index is built once per opening from every online agent, concurrently,
/// and one unreachable server never stops the others. Results are grouped —
/// Servers, Containers, Stacks — with the server named on every row, the
/// window's own server first in each group.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/agent_api.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../data/servers_repository.dart';
import '../../edition/edition.dart';
import '../../edition/locked_feature.dart';
import '../../edition/pro_badge.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/state_views.dart';
import '../../widgets/stroke_icons.dart';

enum JumpKind { server, container, stack }

class JumpTarget {
  const JumpTarget({
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.path,
    this.serverId = '',
    this.serverName = '',
    this.status = '',
    this.monoSubtitle = false,
    this.offline = false,
  });

  final JumpKind kind;
  final String title;

  /// The second, muted text on the row: a host, an image, "4 of 5 up".
  final String subtitle;
  final String path;

  /// The server the row belongs to, named at the right of container and
  /// stack rows.
  final String serverId;
  final String serverName;

  /// A server row's right-hand text: "9 running", "offline".
  final String status;
  final bool monoSubtitle;

  /// A server that did not answer: listed, dimmed.
  final bool offline;

  StrokeGlyph get glyph => switch (kind) {
    JumpKind.server => StrokeGlyph.servers,
    JumpKind.container => StrokeGlyph.containers,
    JumpKind.stack => StrokeGlyph.stacks,
  };

  bool matches(String query) =>
      title.toLowerCase().contains(query) ||
      subtitle.toLowerCase().contains(query) ||
      serverName.toLowerCase().contains(query);
}

/// Every server, plus the containers and stacks of the ones that answer.
///
/// The argument is the one server to look in, or null for every one of them:
/// an edition without cross-server search asks the current server only, so the
/// others are never even contacted.
final jumpTargetsProvider = FutureProvider.autoDispose
    .family<List<JumpTarget>, String?>((ref, scopeServerId) async {
      final ServersRepository repo = ref.watch(serversRepositoryProvider);
      await repo.ensureLoaded();
      final List<Server> servers = scopeServerId == null
          ? repo.servers
          : repo.servers
                .where((Server s) => s.id == scopeServerId)
                .toList(growable: false);
      final List<List<JumpTarget>> found = await Future.wait(
        servers.map((Server server) => _forServer(repo, server)),
      );
      return <JumpTarget>[for (final List<JumpTarget> list in found) ...list];
    });

Future<List<JumpTarget>> _forServer(
  ServersRepository repo,
  Server server,
) async {
  JumpTarget serverRow({String status = '', bool offline = false}) =>
      JumpTarget(
        kind: JumpKind.server,
        title: server.name,
        subtitle: server.host,
        path: '/s/${server.id}/overview',
        serverId: server.id,
        serverName: server.name,
        status: status,
        monoSubtitle: true,
        offline: offline,
      );
  final AgentApi api = repo.api(server.id);
  try {
    if (!await api.health()) {
      return <JumpTarget>[serverRow(status: 'offline', offline: true)];
    }
    final List<Object> both = await Future.wait(<Future<Object>>[
      api.containers(),
      api.stacks(),
    ]);
    final List<ContainerSummary> containers = both[0] as List<ContainerSummary>;
    final int running = containers
        .where((ContainerSummary c) => c.state.isRunning)
        .length;
    return <JumpTarget>[
      serverRow(status: '$running running'),
      for (final ContainerSummary c in containers)
        JumpTarget(
          kind: JumpKind.container,
          title: c.name,
          subtitle: c.image,
          path: '/s/${server.id}/containers/${c.id}',
          serverId: server.id,
          serverName: server.name,
          monoSubtitle: true,
        ),
      for (final ComposeStack st in both[1] as List<ComposeStack>)
        JumpTarget(
          kind: JumpKind.stack,
          title: st.name,
          subtitle: '${st.servicesUp} of ${st.servicesTotal} up',
          path: '/s/${server.id}/stacks',
          serverId: server.id,
          serverName: server.name,
        ),
    ];
  } on AgentException {
    // An unreachable or refusing agent simply contributes its own row.
    return <JumpTarget>[serverRow(status: 'offline', offline: true)];
  }
}

/// The groups the palette draws, in order, each capped: three rows apiece
/// before anything is typed, eight once there is a query. The window's own
/// server comes first in every group.
List<(JumpKind, List<JumpTarget>)> groupJumpTargets(
  List<JumpTarget> all, {
  required String query,
  String? currentServerId,
}) {
  final String q = query.trim().toLowerCase();
  final int cap = q.isEmpty ? 3 : 8;
  final List<(JumpKind, List<JumpTarget>)> groups =
      <(JumpKind, List<JumpTarget>)>[];
  for (final JumpKind kind in JumpKind.values) {
    final List<JumpTarget> rows = <JumpTarget>[
      for (final JumpTarget t in all)
        if (t.kind == kind && (q.isEmpty || t.matches(q))) t,
    ];
    // A stable sort: the current server's rows first, the agent's order kept.
    final List<JumpTarget> ordered = <JumpTarget>[
      ...rows.where((JumpTarget t) => t.serverId == currentServerId),
      ...rows.where((JumpTarget t) => t.serverId != currentServerId),
    ];
    if (ordered.isEmpty) continue;
    groups.add((kind, ordered.take(cap).toList(growable: false)));
  }
  return groups;
}

/// Cmd+K. [currentServerId] is the server the window is on, which is all an
/// edition without cross-server search may look in.
///
/// Not the centred D3 dialog: the palette hangs from the top of the window,
/// as DesktopPalette draws it, so the list grows down without the field
/// moving.
Future<void> showJumpPalette(BuildContext context, {String? currentServerId}) =>
    showDialog<void>(
      context: context,
      barrierColor: context.tokens.scrim,
      builder: (BuildContext context) {
        final Size window = MediaQuery.sizeOf(context);
        final double top = (window.height * 0.12).clamp(24.0, 110.0);
        return Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: EdgeInsets.only(top: top, left: 24, right: 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 560,
                maxHeight: window.height - top - 24,
              ),
              child: _Palette(currentServerId: currentServerId),
            ),
          ),
        );
      },
    );

class _Palette extends ConsumerStatefulWidget {
  const _Palette({required this.currentServerId});

  final String? currentServerId;

  @override
  ConsumerState<_Palette> createState() => _PaletteState();
}

class _PaletteState extends ConsumerState<_Palette> {
  final TextEditingController _query = TextEditingController();
  int _highlighted = 0;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _open(JumpTarget target) {
    Navigator.of(context).pop();
    context.go(target.path);
  }

  /// Every server in Pro; in Free the one the window is on, or the first
  /// paired server when it is on none.
  String? _scope(Edition edition) {
    if (edition.crossServerPalette) return null;
    if (widget.currentServerId != null) return widget.currentServerId;
    final List<Server> servers = ref.read(serversRepositoryProvider).servers;
    return servers.isEmpty ? null : servers.first.id;
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Edition edition = ref.watch(editionProvider);
    final String? scope = _scope(edition);
    final AsyncValue<List<JumpTarget>> targets = ref.watch(
      jumpTargetsProvider(scope),
    );
    final List<(JumpKind, List<JumpTarget>)> groups = groupJumpTargets(
      targets.valueOrNull ?? const <JumpTarget>[],
      query: _query.text,
      currentServerId: widget.currentServerId ?? scope,
    );
    final List<JumpTarget> flat = <JumpTarget>[
      for (final (JumpKind, List<JumpTarget>) g in groups) ...g.$2,
    ];
    final int highlighted = flat.isEmpty
        ? 0
        : _highlighted.clamp(0, flat.length - 1);
    final String scopeName = edition.crossServerPalette
        ? 'Every server'
        : '${ref.read(serversRepositoryProvider).servers.where((Server s) => s.id == scope).map((Server s) => s.name).firstOrNull ?? 'This server'} only';

    final List<Widget> rows = <Widget>[];
    int index = 0;
    for (final (JumpKind kind, List<JumpTarget> list) in groups) {
      rows.add(_GroupHeader(kind));
      for (final JumpTarget target in list) {
        final int i = index++;
        rows.add(
          _Row(
            target: target,
            current:
                target.kind == JumpKind.server &&
                target.serverId == (widget.currentServerId ?? ''),
            highlighted: i == highlighted,
            onTap: () => _open(target),
          ),
        );
      }
    }

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        // From the stored index, not this build's: two presses before the
        // next frame still move two rows.
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => setState(
          () => _highlighted = flat.isEmpty
              ? 0
              : (_highlighted + 1).clamp(0, flat.length - 1),
        ),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => setState(
          () => _highlighted = _highlighted - 1 < 0 ? 0 : _highlighted - 1,
        ),
        const SingleActivator(LogicalKeyboardKey.enter): () {
          if (flat.isNotEmpty) _open(flat[highlighted]);
        },
      },
      child: Material(
        color: t.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: t.strongBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _SearchRow(
              controller: _query,
              onChanged: (_) => setState(() => _highlighted = 0),
            ),
            Flexible(
              child: targets.isLoading
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: LoadingView(rows: 3, height: 40),
                    )
                  : rows.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(18),
                      child: Text(
                        'Nothing matches that.',
                        style: AppText.small.copyWith(color: t.mutedText),
                      ),
                    )
                  : ListView(
                      shrinkWrap: true,
                      primary: false,
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                      children: rows,
                    ),
            ),
            if (!edition.crossServerPalette) const _EveryServerRow(),
            _Hints(scope: scopeName),
          ],
        ),
      ),
    );
  }
}

/// The 54 px field across the top, with the `esc` chip.
class _SearchRow extends StatelessWidget {
  const _SearchRow({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: <Widget>[
          StrokeIcon(StrokeGlyph.search, size: 17, color: t.mutedText),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: true,
              onChanged: onChanged,
              style: TextStyle(fontSize: 15, color: t.text),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Jump to a container, stack or server',
                hintStyle: TextStyle(fontSize: 15, color: t.mutedText),
              ),
            ),
          ),
          const SizedBox(width: 10),
          const _Key('esc'),
        ],
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader(this.kind);

  final JumpKind kind;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
      child: Text(
        switch (kind) {
          JumpKind.server => 'SERVERS',
          JumpKind.container => 'CONTAINERS',
          JumpKind.stack => 'STACKS',
        },
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
          color: t.mutedText,
        ),
      ),
    );
  }
}

/// The keycap the palette's hints and the selected row draw.
class _Key extends StatelessWidget {
  const _Key(this.label);

  /// `↑`, `↓` and `↵` are painted: no bundled face carries the arrows.
  final String label;

  static const Map<String, StrokeGlyph> _glyphs = <String, StrokeGlyph>{
    '↑': StrokeGlyph.arrowUp,
    '↓': StrokeGlyph.arrowDown,
    '↵': StrokeGlyph.returnKey,
  };

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.iconButtonFill,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: t.strongBorder),
      ),
      child: _glyphs[label] != null
          ? StrokeIcon(
              _glyphs[label]!,
              size: 11,
              color: t.codeText,
              semanticLabel: label,
            )
          : Text(
              label,
              style: TextStyle(
                fontFamily: AppFonts.mono,
                fontSize: 11,
                height: 1,
                color: t.codeText,
              ),
            ),
    );
  }
}

/// `↑ ↓ move · return open · esc close`, and what is being searched.
class _Hints extends StatelessWidget {
  const _Hints({required this.scope});

  final String scope;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final TextStyle style = TextStyle(fontSize: 12, color: t.mutedText);
    Widget hint(List<String> keys, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final String k in keys) ...<Widget>[
          _Key(k),
          const SizedBox(width: 6),
        ],
        Text(label, style: style),
      ],
    );
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.border)),
      ),
      child: Row(
        children: <Widget>[
          hint(const <String>['↑', '↓'], 'move'),
          const SizedBox(width: 14),
          hint(const <String>['return'], 'open'),
          const SizedBox(width: 14),
          hint(const <String>['esc'], 'close'),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              scope,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

/// The last row on Free: what searching every server would do.
class _EveryServerRow extends StatelessWidget {
  const _EveryServerRow();

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => showProFeature(context, ProFeature.crossServerSearch),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: t.faintDivider),
          ),
          child: Row(
            children: <Widget>[
              _Tile(glyph: StrokeGlyph.search, color: t.codeText),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Search every server',
                  overflow: TextOverflow.ellipsis,
                  style: AppText.label.copyWith(
                    color: t.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const ProBadge(),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.glyph, required this.color, this.fill});

  final StrokeGlyph glyph;
  final Color color;
  final Color? fill;

  @override
  Widget build(BuildContext context) => Container(
    width: 28,
    height: 28,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: fill ?? context.tokens.iconButtonFill,
      borderRadius: BorderRadius.circular(8),
    ),
    child: StrokeIcon(glyph, size: 15, color: color),
  );
}

class _Row extends StatefulWidget {
  const _Row({
    required this.target,
    required this.current,
    required this.highlighted,
    required this.onTap,
  });

  final JumpTarget target;

  /// The server the window is on: "current" instead of its running count.
  final bool current;
  final bool highlighted;
  final VoidCallback onTap;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final JumpTarget target = widget.target;
    final bool on = widget.highlighted;
    final String right = target.kind == JumpKind.server
        ? (widget.current ? 'current' : target.status)
        : target.serverName;
    final Widget row = Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: on
            ? t.iconButtonFill
            : (_hover ? t.iconButtonFill.withValues(alpha: 0.5) : null),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: <Widget>[
          _Tile(
            glyph: target.glyph,
            color: on ? t.accent : t.codeText,
            fill: on ? t.border : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: <Widget>[
                Text(
                  target.title,
                  maxLines: 1,
                  style: AppText.label.copyWith(
                    color: t.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    target.subtitle,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: target.monoSubtitle
                          ? AppFonts.mono
                          : AppFonts.sans,
                      fontSize: target.monoSubtitle ? 12 : 12.5,
                      color: t.mutedText,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(right, style: TextStyle(fontSize: 12.5, color: t.mutedText)),
          if (on) ...<Widget>[const SizedBox(width: 8), const _Key('↵')],
        ],
      ),
    );
    return Semantics(
      button: true,
      selected: on,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Opacity(opacity: target.offline ? 0.6 : 1, child: row),
        ),
      ),
    );
  }
}
