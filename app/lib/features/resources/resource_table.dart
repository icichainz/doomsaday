/// D4 — Images, Volumes and Networks as real tables.
///
/// One generic frame: a filter field, state chips, the screen's own buttons,
/// a sortable table and the footer line. The three resource kinds differ only
/// in their columns, chips and row menu.
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/desktop.dart';
import '../../widgets/filter_field.dart';
import '../../widgets/state_views.dart';
import '../../widgets/stroke_icons.dart';
import '../../widgets/table.dart';

class ResourceChip<T> {
  const ResourceChip({required this.label, required this.keep});

  final String label;

  /// `null` keeps everything, which is the first chip on every board.
  final bool Function(T row)? keep;
}

class ResourceTable<T> extends StatefulWidget {
  const ResourceTable({
    super.key,
    required this.rows,
    required this.columns,
    required this.chips,
    required this.filterHint,
    required this.matches,
    required this.menu,
    required this.emptyTitle,
    this.actions = const <Widget>[],
    this.initialSort,
    this.initialAscending = true,
    this.footer,
  });

  final List<T> rows;
  final List<TableColumn<T>> columns;
  final List<ResourceChip<T>> chips;
  final String filterHint;
  final bool Function(T row, String query) matches;
  final List<MenuAction> Function(T row) menu;
  final String emptyTitle;
  final List<Widget> actions;
  final int? initialSort;
  final bool initialAscending;
  final String? footer;

  @override
  State<ResourceTable<T>> createState() => _ResourceTableState<T>();
}

class _ResourceTableState<T> extends State<ResourceTable<T>> {
  final TextEditingController _filter = TextEditingController();
  int _chip = 0;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String query = _filter.text.trim().toLowerCase();
    final int chip = _chip.clamp(0, widget.chips.length - 1);
    final bool Function(T)? keep = widget.chips[chip].keep;
    final List<T> rows = widget.rows
        .where((T row) => keep == null || keep(row))
        .where((T row) => query.isEmpty || widget.matches(row, query))
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            FilterField(
              controller: _filter,
              hint: widget.filterHint,
              width: 320,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: PillChipRow(
                chips: <Widget>[
                  for (int i = 0; i < widget.chips.length; i++)
                    PillChip(
                      label: widget.chips[i].label,
                      selected: i == chip,
                      onPressed: () => setState(() => _chip = i),
                    ),
                ],
              ),
            ),
            for (final Widget action in widget.actions) ...<Widget>[
              const SizedBox(width: 10),
              action,
            ],
          ],
        ),
        const SizedBox(height: 16),
        if (rows.isEmpty)
          EmptyView(
            glyph: StrokeGlyph.search,
            title: widget.emptyTitle,
            message: 'Nothing here matches that search.',
          )
        else
          DataTableView<T>(
            rows: rows,
            columns: widget.columns,
            actions: widget.menu,
            initialSort: widget.initialSort,
            initialAscending: widget.initialAscending,
            footer: widget.footer == null
                ? null
                : Text(
                    'Showing ${rows.length} of ${widget.rows.length} · '
                    '${widget.footer}',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: context.tokens.mutedText,
                    ),
                  ),
          ),
      ],
    );
  }
}
