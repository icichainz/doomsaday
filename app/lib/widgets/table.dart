/// The bordered table the desktop boards use for busiest containers (D1), the
/// fleet (D5) and images, volumes and networks (D4).
///
/// Columns are fixed width or flexible, optionally sortable from the header,
/// rows hover, take keyboard focus and carry a right-click menu.
library;

import 'package:flutter/material.dart';

import '../layout/layout.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'buttons.dart';
import 'context_menu.dart';

class TableColumn<T> {
  const TableColumn({
    required this.label,
    required this.cell,
    this.width,
    this.numeric = false,
    this.compare,
    this.optional = false,
  });

  final String label;

  /// `null` width means the column takes the remaining space.
  final double? width;
  final bool numeric;
  final Widget Function(BuildContext context, T row) cell;

  /// Present makes the header clickable.
  final int Function(T a, T b)? compare;

  /// Dropped first when the pane is too narrow for every column.
  final bool optional;

  bool get sortable => compare != null;
}

class DataTableView<T> extends StatefulWidget {
  const DataTableView({
    super.key,
    required this.columns,
    required this.rows,
    this.rowHeight,
    this.onTap,
    this.selected,
    this.actions,
    this.initialSort,
    this.initialAscending = true,
    this.footer,
    this.rowMenuButton = true,
  });

  final List<TableColumn<T>> columns;
  final List<T> rows;

  /// Defaults to the window's row height (46 with a pointer).
  final double? rowHeight;
  final void Function(T row)? onTap;
  final bool Function(T row)? selected;
  final List<MenuAction> Function(T row)? actions;

  /// Index of the column the table opens sorted by.
  final int? initialSort;
  final bool initialAscending;
  final Widget? footer;

  /// Every row gets a ⋮ button at the far right opening the same menu the
  /// right-click does, as D4 and D5 draw it. A table that puts its own
  /// buttons in a trailing column turns this off.
  final bool rowMenuButton;

  @override
  State<DataTableView<T>> createState() => DataTableViewState<T>();
}

class DataTableViewState<T> extends State<DataTableView<T>> {
  late int? _sort = widget.initialSort;
  late bool _ascending = widget.initialAscending;

  /// The rows in the order they are drawn, which is what a sort test reads.
  List<T> get visibleRows {
    final List<T> rows = List<T>.of(widget.rows);
    final int? index = _sort;
    if (index == null) return rows;
    final int Function(T, T)? compare = widget.columns[index].compare;
    if (compare == null) return rows;
    rows.sort((T a, T b) => _ascending ? compare(a, b) : compare(b, a));
    return rows;
  }

  void _toggle(int index) {
    setState(() {
      if (_sort == index) {
        _ascending = !_ascending;
      } else {
        _sort = index;
        _ascending = true;
      }
    });
  }

  /// Drops optional columns from the right until the fixed widths fit.
  static List<TableColumn<T>> fit<T>(
    List<TableColumn<T>> columns,
    double available,
  ) {
    const double padding = 36;
    const double gap = 16;
    const double minimumFlex = 100;
    List<TableColumn<T>> kept = columns;
    while (true) {
      double need = padding + gap * (kept.length - 1);
      for (final TableColumn<T> column in kept) {
        need += column.width ?? minimumFlex;
      }
      if (need <= available) return kept;
      final int drop = kept.lastIndexWhere((TableColumn<T> c) => c.optional);
      if (drop < 0) return kept;
      kept = <TableColumn<T>>[...kept]..removeAt(drop);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final List<T> rows = visibleRows;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final List<TableColumn<T>> columns = <TableColumn<T>>[
          ...fit<T>(widget.columns, box.maxWidth),
          if (widget.actions != null && widget.rowMenuButton) _menuColumn(),
        ];
        return _table(context, t, rows, columns);
      },
    );
  }

  /// The trailing ⋮ column. It is built here rather than by every caller, so
  /// no table can forget it.
  TableColumn<T> _menuColumn() => TableColumn<T>(
    label: '',
    width: 36,
    cell: (BuildContext context, T row) => Builder(
      builder: (BuildContext anchor) => DoomIconButton(
        icon: Icons.more_vert,
        semanticLabel: 'Row actions',
        size: 30,
        radius: 8,
        filled: false,
        foreground: anchor.tokens.mutedText,
        onPressed: () {
          final RenderBox box = anchor.findRenderObject()! as RenderBox;
          showActionMenu(
            anchor,
            box.localToGlobal(box.size.bottomLeft(Offset.zero)),
            widget.actions!(row),
          );
        },
      ),
    ),
  );

  Widget _table(
    BuildContext context,
    AppTokens t,
    List<T> rows,
    List<TableColumn<T>> columns,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: AppShape.smallCardRadius,
            border: Border.all(color: t.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _Header<T>(
                columns: columns,
                sort: _sort,
                ascending: _ascending,
                onSort: _toggle,
              ),
              for (int i = 0; i < rows.length; i++)
                _Row<T>(
                  columns: columns,
                  row: rows[i],
                  height: widget.rowHeight ?? context.density.row,
                  last: i == rows.length - 1,
                  selected: widget.selected?.call(rows[i]) ?? false,
                  onTap: widget.onTap == null
                      ? null
                      : () => widget.onTap!(rows[i]),
                  actions: widget.actions == null
                      ? null
                      : () => widget.actions!(rows[i]),
                ),
            ],
          ),
        ),
        if (widget.footer != null) ...<Widget>[
          const SizedBox(height: 10),
          widget.footer!,
        ],
      ],
    );
  }
}

class _Header<T> extends StatelessWidget {
  const _Header({
    required this.columns,
    required this.sort,
    required this.ascending,
    required this.onSort,
  });

  final List<TableColumn<T>> columns;
  final int? sort;
  final bool ascending;
  final ValueChanged<int> onSort;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < columns.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 16),
            _Cell(
              width: columns[i].width,
              numeric: columns[i].numeric,
              child: _HeaderLabel(
                column: columns[i],
                sorted: sort == i,
                ascending: ascending,
                onTap: columns[i].sortable ? () => onSort(i) : null,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HeaderLabel<T> extends StatelessWidget {
  const _HeaderLabel({
    required this.column,
    required this.sorted,
    required this.ascending,
    required this.onTap,
  });

  final TableColumn<T> column;
  final bool sorted;
  final bool ascending;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final TextStyle style = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
      color: sorted ? t.text : t.mutedText,
    );
    final Widget label = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Flexible(
          child: Text(
            column.label.toUpperCase(),
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        if (sorted) ...<Widget>[
          const SizedBox(width: 4),
          // Biggest first points down, as the board draws it on SIZE.
          Icon(
            ascending ? Icons.arrow_upward : Icons.arrow_downward,
            size: 12,
            color: t.text,
          ),
        ],
      ],
    );
    if (onTap == null) return label;
    return Semantics(
      button: true,
      label: 'Sort by ${column.label}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: onTap, child: label),
      ),
    );
  }
}

class _Row<T> extends StatefulWidget {
  const _Row({
    required this.columns,
    required this.row,
    required this.height,
    required this.last,
    required this.selected,
    required this.onTap,
    required this.actions,
  });

  final List<TableColumn<T>> columns;
  final T row;
  final double height;
  final bool last;
  final bool selected;
  final VoidCallback? onTap;
  final List<MenuAction> Function()? actions;

  @override
  State<_Row<T>> createState() => _RowState<T>();
}

class _RowState<T> extends State<_Row<T>> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    Widget row = Container(
      height: widget.height,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: widget.selected
            ? t.iconButtonFill
            : (_hover ? t.iconButtonFill.withValues(alpha: 0.6) : null),
        border: widget.last
            ? null
            : Border(bottom: BorderSide(color: t.faintDivider)),
      ),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < widget.columns.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 16),
            _Cell(
              width: widget.columns[i].width,
              numeric: widget.columns[i].numeric,
              child: widget.columns[i].cell(context, widget.row),
            ),
          ],
        ],
      ),
    );
    if (widget.onTap != null) {
      row = InkWell(onTap: widget.onTap, child: row);
    }
    row = MouseRegion(
      cursor: widget.onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: row,
    );
    if (widget.actions == null) return row;
    return ContextMenuRegion(actions: widget.actions!, child: row);
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.width,
    required this.numeric,
    required this.child,
  });

  final double? width;
  final bool numeric;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Widget aligned = Align(
      alignment: numeric
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: child,
    );
    if (width == null) return Expanded(child: aligned);
    return SizedBox(width: width, child: aligned);
  }
}

/// The plain 13 px cell text every table uses.
class CellText extends StatelessWidget {
  const CellText(
    this.text, {
    super.key,
    this.mono = false,
    this.muted = false,
    this.bold = false,
    this.color,
    this.selectable = false,
  });

  final String text;
  final bool mono;
  final bool muted;
  final bool bold;
  final Color? color;

  /// IDs, image names and commands are selectable on a desktop.
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final TextStyle style = TextStyle(
      fontFamily: mono ? AppFonts.mono : AppFonts.sans,
      fontSize: mono ? 12.5 : 13,
      fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
      color: color ?? (muted ? t.mutedText : t.text),
    );
    if (selectable) {
      return SelectableText(text, maxLines: 1, style: style);
    }
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }
}

/// The dot-and-label state cell the boards draw in the State column.
class StateCell extends StatelessWidget {
  const StateCell({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}
