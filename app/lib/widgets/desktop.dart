/// The pieces the desktop boards repeat: the page frame, the big header, the
/// stat-card row and the pill filter chips.
library;

import 'package:flutter/material.dart';

import '../layout/layout.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'primitives.dart';
import 'state_views.dart';

/// D1, D4, D5 and D6's `<main>`: 26 px top, 32 px sides, a fixed gap between
/// blocks and a last child that may fill the rest of the window.
class DesktopPage extends StatelessWidget {
  const DesktopPage({
    super.key,
    required this.children,
    this.gap = 20,
    this.fillLast = false,
    this.fill = false,
  });

  final List<Widget> children;
  final double gap;

  /// Wraps the last child in an [Expanded] so it takes the rest of the window.
  final bool fillLast;

  /// Fills the window without wrapping anything: the caller puts its own
  /// [Expanded] wherever the growing child is.
  final bool fill;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final List<Widget> spaced = <Widget>[
      for (int i = 0; i < children.length; i++) ...<Widget>[
        if (i > 0) SizedBox(height: gap),
        if (fillLast && i == children.length - 1)
          Expanded(child: children[i])
        else
          children[i],
      ],
    ];
    final bool tall = fillLast || fill;
    final Widget column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: tall ? MainAxisSize.max : MainAxisSize.min,
      children: spaced,
    );
    const EdgeInsets inset = EdgeInsets.fromLTRB(32, 26, 32, 24);
    return Material(
      color: t.ground,
      child: SafeArea(
        child: tall
            ? Padding(padding: inset, child: column)
            // The gutter belongs inside the scroll view, so the scrollbar
            // rides in it instead of over the right edge of the content.
            : SingleChildScrollView(padding: inset, child: column),
      ),
    );
  }
}

/// The 28 px title, its status pill and subtitle, with trailing controls.
class DesktopHeader extends StatelessWidget {
  const DesktopHeader({
    super.key,
    required this.title,
    this.pill,
    this.subtitle,
    this.actions = const <Widget>[],
  });

  final String title;
  final Widget? pill;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
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
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: AppFonts.display,
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                        height: 1.1,
                        color: t.text,
                      ),
                    ),
                  ),
                  if (pill != null) ...<Widget>[
                    const SizedBox(width: 10),
                    pill!,
                  ],
                ],
              ),
              if (subtitle != null) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.small.copyWith(color: t.mutedText),
                ),
              ],
            ],
          ),
        ),
        for (final Widget action in actions) ...<Widget>[
          const SizedBox(width: 10),
          action,
        ],
      ],
    );
  }
}

/// One figure card: label, big number with an optional suffix, and a footer
/// that is either a line of text or a meter.
class StatCard extends StatelessWidget {
  const StatCard({
    super.key,
    required this.label,
    required this.figure,
    this.suffix,
    this.note,
    this.noteColor,
    this.meter,
    this.onTap,
  });

  final String label;
  final String figure;
  final String? suffix;
  final String? note;
  final Color? noteColor;
  final double? meter;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    // The phone board draws a slightly tighter, rounder card with a bigger
    // suffix than the desktop one; at 390 those 4 px of padding are what
    // "2 stopped · 1 restarting" needs to fit on its line.
    final bool pointer = context.density.compact;
    return DoomCard(
      radius: pointer ? 16 : 18,
      padding: EdgeInsets.symmetric(
        horizontal: pointer ? 18 : 16,
        vertical: pointer ? 16 : 14,
      ),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.small.copyWith(color: t.mutedText),
          ),
          const SizedBox(height: 8),
          Text.rich(
            TextSpan(
              children: <InlineSpan>[
                TextSpan(text: figure),
                if (suffix != null)
                  TextSpan(
                    text: ' $suffix',
                    style: TextStyle(
                      fontFamily: AppFonts.sans,
                      fontSize: pointer ? 14 : 15,
                      fontWeight: FontWeight.w500,
                      color: t.mutedText,
                    ),
                  ),
              ],
            ),
            maxLines: 1,
            style: AppText.figure.copyWith(color: t.text),
          ),
          const SizedBox(height: 8),
          if (meter != null)
            MeterBar(meter!)
          else
            Text(
              note ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.tiny.copyWith(color: noteColor ?? t.mutedText),
            ),
        ],
      ),
    );
  }
}

/// Four across at 1100 and up, 2×2 on a tablet, one column on a phone.
class StatCardGrid extends StatelessWidget {
  const StatCardGrid({super.key, required this.cards});

  final List<Widget> cards;

  @override
  Widget build(BuildContext context) {
    final WindowClass windowClass = WindowClass.of(context);
    final int columns = switch (windowClass) {
      WindowClass.expanded => 4,
      WindowClass.medium => 2,
      WindowClass.compact => 2,
    };
    final double gap = windowClass.isExpanded ? 16 : 12;
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < cards.length; i += columns) {
      final List<Widget> slice = cards.sublist(
        i,
        i + columns > cards.length ? cards.length : i + columns,
      );
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (int j = 0; j < columns; j++) ...<Widget>[
                if (j > 0) SizedBox(width: gap),
                Expanded(
                  child: j < slice.length ? slice[j] : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < rows.length; i++) ...<Widget>[
          if (i > 0) SizedBox(height: gap),
          rows[i],
        ],
      ],
    );
  }
}

/// Cards in two columns from 600 up **where they fit**, one column below
/// that. Used by the screens that have no desktop board of their own: stacks,
/// services and alerts.
class CardGrid extends StatelessWidget {
  const CardGrid({
    super.key,
    required this.cards,
    this.gap = 14,
    this.minColumnWidth = 320,
  });

  final List<Widget> cards;
  final double gap;

  /// A card narrower than this cannot hold its own row of actions, so the
  /// grid drops to one column rather than squeezing them.
  final double minColumnWidth;

  @override
  Widget build(BuildContext context) {
    if (WindowClass.of(context).isCompact || cards.length < 2) {
      return _column(cards);
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        if ((box.maxWidth - gap) / 2 < minColumnWidth) return _column(cards);
        return _grid();
      },
    );
  }

  Widget _column(List<Widget> cards) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      for (int i = 0; i < cards.length; i++) ...<Widget>[
        if (i > 0) SizedBox(height: gap),
        cards[i],
      ],
    ],
  );

  Widget _grid() {
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < cards.length; i += 2) {
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(child: cards[i]),
              SizedBox(width: gap),
              Expanded(
                child: i + 1 < cards.length
                    ? cards[i + 1]
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < rows.length; i++) ...<Widget>[
          if (i > 0) SizedBox(height: gap),
          rows[i],
        ],
      ],
    );
  }
}

/// The 32 px pill filter chips D2, D4 and D5 put above a list.
class PillChip extends StatefulWidget {
  const PillChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  State<PillChip> createState() => _PillChipState();
}

class _PillChipState extends State<PillChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Density d = context.density;
    return Semantics(
      button: true,
      selected: widget.selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Material(
          color: widget.selected
              ? t.accent
              : (_hover ? t.iconButtonFill : t.surface),
          borderRadius: AppShape.pill,
          child: InkWell(
            borderRadius: AppShape.pill,
            onTap: widget.onPressed,
            child: Container(
              height: d.chip,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: AppShape.pill,
                border: Border.all(
                  color: widget.selected ? t.accent : t.strongBorder,
                ),
              ),
              // Hugs its label. An `alignment:` here would take the whole
              // bounded width a `Wrap` hands every child, which is what put
              // one chip per line on the fleet, list and table filters.
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Flexible(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.small.copyWith(
                        fontWeight: FontWeight.w600,
                        color: widget.selected ? t.onAccent : t.text,
                      ),
                    ),
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

/// A row of chips with the design's 6 px gap.
class PillChipRow extends StatelessWidget {
  const PillChipRow({super.key, required this.chips});

  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 6, runSpacing: 6, children: chips);
  }
}

/// D5's offline notice under the fleet table.
class OfflineNotice extends StatelessWidget {
  const OfflineNotice({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.dangerBorder),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.wifi_off, size: 18, color: t.danger),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: AppText.small.copyWith(color: t.codeText),
            ),
          ),
          const SizedBox(width: 12),
          Semantics(
            button: true,
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onRetry,
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: t.outlineBorder),
                ),
                child: Text(
                  'Retry',
                  style: AppText.small.copyWith(
                    color: t.text,
                    fontWeight: FontWeight.w600,
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

/// The two desktop-only screens say so rather than drawing half a grid when
/// the window is narrowed under 1100.
class NeedsAWiderWindow extends StatelessWidget {
  const NeedsAWiderWindow({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Scaffold(
      backgroundColor: t.ground,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: EmptyView(
                icon: Icons.desktop_windows_outlined,
                title: '$title needs a wider window',
                message:
                    'Make the window at least 1100 points wide to use it, or '
                    'open a container and follow its logs on its own.',
              ),
            ),
          ),
        ),
      ),
    );
  }
}
