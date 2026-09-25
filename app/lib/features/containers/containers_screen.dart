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
import '../../widgets/filter_field.dart';
import '../../widgets/page.dart';
import '../../widgets/primitives.dart';
import '../../widgets/sheets.dart';
import '../../widgets/state_views.dart';
import '../../widgets/stroke_icons.dart';
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

  /// Board `EmptyStates`, last card: a search or a state chip that leaves
  /// nothing, with the one button that undoes both.
  Widget _noMatch() => EmptyView(
    glyph: StrokeGlyph.search,
    title: 'No matching containers',
    message: 'Nothing here matches that search.',
    secondary: EmptyAction(
      'Clear filter',
      onPressed: () => setState(() {
        _filter = ContainerFilter.all;
        _search.clear();
      }),
    ),
  );

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
    // TabletContainers: the filter field is always there, on one row with
    // the chips, instead of behind the phone's search button; rows are 52.
    final bool tablet = WindowClass.of(context).isMedium;
    final Widget chips = Semantics(
      label: 'Filter by state',
      container: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
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
    );

    return ShellPage(
      children: <Widget>[
        ScreenHeader(
          title: 'Containers',
          subtitle: tablet
              ? all.maybeWhen(
                  data: (List<ContainerSummary> list) =>
                      '${list.length} on $serverId',
                  orElse: () => serverId,
                )
              : serverId,
          actions: <Widget>[
            if (!tablet)
              DoomIconButton(
                glyph: _searching ? StrokeGlyph.close : StrokeGlyph.search,
                semanticLabel: _searching
                    ? 'Close search'
                    : 'Search containers',
                onPressed: () => setState(() {
                  _searching = !_searching;
                  if (!_searching) _search.clear();
                }),
              ),
          ],
        ),
        if (tablet)
          Row(
            children: <Widget>[
              Expanded(
                child: FilterField(
                  controller: _search,
                  hint: 'Filter by name or image',
                  showHintKey: false,
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(width: 10),
              chips,
            ],
          )
        else ...<Widget>[
          if (_searching)
            LabelledField(
              label: 'Search containers',
              hint: 'Name or image',
              controller: _search,
              autofocus: true,
            ),
          // Scrolls sideways so long counts never clip the third chip.
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: chips),
        ],
        AsyncSection<List<ContainerSummary>>(
          value: all,
          onRetry: () => ref.invalidate(containersProvider(serverId)),
          loadingRows: 5,
          isEmpty: (List<ContainerSummary> list) =>
              list.where(_filter.matches).isEmpty,
          empty: _filter == ContainerFilter.all
              ? const EmptyView(
                  glyph: StrokeGlyph.containers,
                  title: 'No containers',
                  message: 'Nothing is deployed on this host yet.',
                )
              : _noMatch(),
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
            if (shown.isEmpty) return _noMatch();
            return RowGroup(
              trailingPadding: 6,
              radius: tablet ? 18 : null,
              dividerColor: tablet ? context.tokens.faintDivider : null,
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
    final bool tablet = WindowClass.of(context).isMedium;
    final double height = tablet ? ShellMetrics.tabletRow : 66;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: height),
      child: Row(
        children: <Widget>[
          Expanded(
            child: InkWell(
              onTap: () =>
                  context.push('/s/$serverId/containers/${container.id}'),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: height),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: tablet ? 8 : 10,
                      height: tablet ? 8 : 10,
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
                            style: AppText.rowTitle.copyWith(
                              color: t.text,
                              fontSize: tablet ? 14.5 : null,
                            ),
                          ),
                          SizedBox(height: tablet ? 1 : 3),
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
                        SizedBox(height: tablet ? 1 : 3),
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
