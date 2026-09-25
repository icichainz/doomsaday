/// Cmd+K — "Jump to a container, stack or server".
///
/// The index is built once per opening from every online agent, concurrently,
/// and one unreachable server never stops the others.
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
import '../../widgets/filter_field.dart';
import '../../widgets/state_views.dart';
import '../../widgets/surfaces.dart';

enum JumpKind { server, container, stack }

class JumpTarget {
  const JumpTarget({
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.path,
  });

  final JumpKind kind;
  final String title;
  final String subtitle;
  final String path;

  IconData get icon => switch (kind) {
    JumpKind.server => Icons.dns_outlined,
    JumpKind.container => Icons.view_in_ar_outlined,
    JumpKind.stack => Icons.layers_outlined,
  };

  bool matches(String query) =>
      title.toLowerCase().contains(query) ||
      subtitle.toLowerCase().contains(query);
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
  final List<JumpTarget> targets = <JumpTarget>[
    JumpTarget(
      kind: JumpKind.server,
      title: server.name,
      subtitle: server.host,
      path: '/s/${server.id}/overview',
    ),
  ];
  final AgentApi api = repo.api(server.id);
  try {
    if (!await api.health()) return targets;
    final List<Object> both = await Future.wait(<Future<Object>>[
      api.containers(),
      api.stacks(),
    ]);
    for (final ContainerSummary c in both[0] as List<ContainerSummary>) {
      targets.add(
        JumpTarget(
          kind: JumpKind.container,
          title: c.name,
          subtitle: '${server.name} · ${c.image}',
          path: '/s/${server.id}/containers/${c.id}',
        ),
      );
    }
    for (final ComposeStack s in both[1] as List<ComposeStack>) {
      targets.add(
        JumpTarget(
          kind: JumpKind.stack,
          title: s.name,
          subtitle: '${server.name} · stack',
          path: '/s/${server.id}/stacks',
        ),
      );
    }
  } on AgentException {
    // An unreachable or refusing agent simply contributes its own row.
  }
  return targets;
}

/// Cmd+K. [currentServerId] is the server the window is on, which is all an
/// edition without cross-server search may look in.
Future<void> showJumpPalette(BuildContext context, {String? currentServerId}) =>
    showAdaptiveModal<void>(
      context,
      width: 560,
      builder: (BuildContext context, bool sheet) =>
          _Palette(currentServerId: currentServerId),
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

  List<JumpTarget> _filter(List<JumpTarget> all) {
    final String query = _query.text.trim().toLowerCase();
    final List<JumpTarget> shown = query.isEmpty
        ? all
        : all.where((JumpTarget t) => t.matches(query)).toList(growable: false);
    return shown.length > 40 ? shown.sublist(0, 40) : shown;
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
    final AsyncValue<List<JumpTarget>> targets = ref.watch(
      jumpTargetsProvider(_scope(edition)),
    );
    final List<JumpTarget> shown = _filter(
      targets.valueOrNull ?? const <JumpTarget>[],
    );
    final int highlighted = shown.isEmpty
        ? 0
        : _highlighted.clamp(0, shown.length - 1);

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            setState(() => _highlighted = highlighted + 1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => setState(
          () => _highlighted = highlighted - 1 < 0 ? 0 : highlighted - 1,
        ),
        const SingleActivator(LogicalKeyboardKey.enter): () {
          if (shown.isNotEmpty) _open(shown[highlighted]);
        },
      },
      child: ModalBody(
        handle: false,
        children: <Widget>[
          FilterField(
            controller: _query,
            hint: 'Jump to a container, stack or server',
            autofocus: true,
            showHintKey: false,
            onChanged: (_) => setState(() => _highlighted = 0),
          ),
          if (targets.isLoading)
            const LoadingView(rows: 3, height: 40)
          else if (shown.isEmpty)
            Text(
              'Nothing matches that.',
              style: AppText.small.copyWith(color: t.mutedText),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView.builder(
                shrinkWrap: true,
                primary: false,
                itemCount: shown.length,
                itemBuilder: (BuildContext context, int i) => _Row(
                  target: shown[i],
                  highlighted: i == highlighted,
                  onTap: () => _open(shown[i]),
                ),
              ),
            ),
          if (!edition.crossServerPalette) const _EveryServerRow(),
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
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => showProFeature(context, ProFeature.crossServerSearch),
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: t.faintDivider)),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.travel_explore_outlined, size: 17, color: t.mutedText),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Search every server',
                overflow: TextOverflow.ellipsis,
                style: AppText.small.copyWith(
                  color: t.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const ProBadge(),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.target,
    required this.highlighted,
    required this.onTap,
  });

  final JumpTarget target;
  final bool highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: highlighted ? t.iconButtonFill : null,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: <Widget>[
            Icon(target.icon, size: 17, color: t.mutedText),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    target.title,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.small.copyWith(
                      color: t.text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    target.subtitle,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.tiny.copyWith(color: t.mutedText),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
