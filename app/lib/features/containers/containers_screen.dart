import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../../layout/layout.dart';
import '../../theme/app_theme.dart';
import '../../theme/state_colors.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/page.dart';
import '../../widgets/primitives.dart';
import '../../widgets/sheets.dart';
import '../../widgets/state_views.dart';
import 'container_actions.dart';
import 'containers_pane.dart';

/// Screen 5 — Containers.
class ContainersScreen extends ConsumerStatefulWidget {
  const ContainersScreen({super.key, required this.serverId});

  final String serverId;

  @override
  ConsumerState<ContainersScreen> createState() => _ContainersScreenState();
}

class _ContainersScreenState extends ConsumerState<ContainersScreen> {
  ContainerFilter _filter = ContainerFilter.all;
  bool _searching = false;
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String serverId = widget.serverId;
    // At 1100 and up this route is the left pane of the split view with
    // nothing selected yet.
    if (WindowClass.of(context).usesDesktopExtras) {
      return ContainersPane(serverId: serverId);
    }
    final AsyncValue<List<ContainerSummary>> all = ref.watch(
      containersProvider(serverId),
    );
    final String query = _search.text.trim().toLowerCase();

    return ShellPage(
      children: <Widget>[
        ScreenHeader(
          title: 'Containers',
          subtitle: serverId,
          actions: <Widget>[
            DoomIconButton(
              icon: _searching ? Icons.close : Icons.search,
              semanticLabel: _searching ? 'Close search' : 'Search containers',
              onPressed: () => setState(() {
                _searching = !_searching;
                if (!_searching) _search.clear();
              }),
            ),
          ],
        ),
        if (_searching)
          LabelledField(
            label: 'Search containers',
            hint: 'Name or image',
            controller: _search,
            autofocus: true,
          ),
        // Scrolls sideways so long counts never clip the third chip.
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Semantics(
            label: 'Filter by state',
            container: true,
            child: Row(
              children: <Widget>[
                for (final ContainerFilter filter
                    in ContainerFilter.values) ...<Widget>[
                  if (filter != ContainerFilter.all) const SizedBox(width: 8),
                  FilterChipButton(
                    label: '${filter.label} ${_count(all, filter)}',
                    selected: _filter == filter,
                    onPressed: () => setState(() => _filter = filter),
                  ),
                ],
              ],
            ),
          ),
        ),
        AsyncSection<List<ContainerSummary>>(
          value: all,
          onRetry: () => ref.invalidate(containersProvider(serverId)),
          loadingRows: 5,
          isEmpty: (List<ContainerSummary> list) =>
              list.where(_filter.matches).isEmpty,
          empty: EmptyView(
            icon: Icons.view_in_ar_outlined,
            title:
                'No ${_filter == ContainerFilter.all ? '' : '${_filter.label.toLowerCase()} '}containers',
            message: _filter == ContainerFilter.all
                ? 'Nothing is deployed on this host yet.'
                : 'Nothing matches this filter right now.',
          ),
          builder: (List<ContainerSummary> list) {
            final List<ContainerSummary> shown = list
                .where(_filter.matches)
                .where(
                  (ContainerSummary c) =>
                      query.isEmpty ||
                      c.name.toLowerCase().contains(query) ||
                      c.image.toLowerCase().contains(query),
                )
                .toList(growable: false);
            if (shown.isEmpty) {
              return const EmptyView(
                icon: Icons.search_off,
                title: 'No matching containers',
                message: 'Nothing here matches that search.',
              );
            }
            return RowGroup(
              trailingPadding: 6,
              children: <Widget>[
                for (final ContainerSummary c in shown)
                  _ContainerRow(serverId: serverId, container: c),
              ],
            );
          },
        ),
      ],
    );
  }

  static String _count(
    AsyncValue<List<ContainerSummary>> all,
    ContainerFilter filter,
  ) {
    final List<ContainerSummary>? list = all.valueOrNull;
    if (list == null) return '';
    return switch (filter) {
      ContainerFilter.all => '${list.length}',
      ContainerFilter.running =>
        '${list.where((ContainerSummary c) => c.state.isRunning).length}',
      ContainerFilter.stopped =>
        '${list.where((ContainerSummary c) => !c.state.isRunning).length}',
    };
  }
}

class _ContainerRow extends ConsumerWidget {
  const _ContainerRow({required this.serverId, required this.container});

  final String serverId;
  final ContainerSummary container;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final Color color = containerStateColor(t, container.state);
    final bool running = container.state.isRunning;
    final bool canOperate = ref.watch(roleProvider(serverId)).canOperate;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 66),
      child: Row(
        children: <Widget>[
          Expanded(
            child: InkWell(
              onTap: () =>
                  context.push('/s/$serverId/containers/${container.id}'),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 66),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            container.name,
                            style: AppText.rowTitle.copyWith(color: t.text),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            container.image,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.monoSmall.copyWith(
                              color: t.mutedText,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          container.stateLabel,
                          style: AppText.pill.copyWith(color: color),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          container.meta,
                          style: AppText.tiny.copyWith(color: t.mutedText),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          // A viewer may read everything and change nothing, so the button is
          // not drawn at all rather than drawn and refused.
          if (canOperate) ...<Widget>[
            const SizedBox(width: 8),
            DoomIconButton(
              // The board draws an outlined stop square, not a filled one.
              icon: running ? Icons.stop_outlined : Icons.play_arrow_outlined,
              semanticLabel: '${running ? 'Stop' : 'Start'} ${container.name}',
              size: 44,
              radius: 12,
              filled: false,
              foreground: running ? t.mutedText : t.accent,
              onPressed: () =>
                  startOrStopContainer(context, ref, serverId, container),
            ),
          ],
        ],
      ),
    );
  }
}
