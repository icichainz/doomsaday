import 'package:flutter/material.dart';

import '../layout/layout.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'stroke_icons.dart';

enum ButtonTone { primary, outline, danger, dangerFilled }

/// The one button in the app. Tone picks the fill, border and label colour.
class DoomButton extends StatelessWidget {
  const DoomButton(
    this.label, {
    super.key,
    required this.onPressed,
    this.tone = ButtonTone.outline,
    this.icon,
    this.glyph,
    this.height = 44,
    this.radius = 12,
    this.expand = false,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final ButtonTone tone;
  final IconData? icon;

  /// One of the design's stroke icons, drawn instead of [icon].
  final StrokeGlyph? glyph;
  final double height;
  final double radius;

  /// Fill the row it sits in rather than hugging its label.
  final bool expand;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final (Color? fill, Color? border, Color fg) = switch (tone) {
      ButtonTone.primary => (t.accent, null, t.onAccent),
      ButtonTone.outline => (null, t.outlineBorder, t.text),
      ButtonTone.danger => (null, t.outlineBorder, t.danger),
      ButtonTone.dangerFilled => (t.danger, null, t.onDanger),
    };
    final bool enabled = onPressed != null && !busy;
    // MainAxisSize.min is what keeps the button hugging its label. It has to
    // be the outermost box too: an `Align`/`Center` here would fill whatever
    // bounded width the parent offers, which is what a `Wrap` always offers —
    // and that is what stacked every row of buttons and chips at full width.
    final Widget child = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        if (busy)
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: fg),
          )
        else if (glyph != null)
          StrokeIcon(glyph!, size: 18, color: fg)
        else if (icon != null)
          Icon(icon, size: 18, color: fg),
        if (busy || icon != null || glyph != null) const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: AppText.buttonLabel.copyWith(
              color: fg,
              // 13 on the 36 px pointer buttons, as every desktop board
              // draws them; 15 on the phone's tall ones.
              fontSize: height >= 48 ? 15 : (height <= 36 ? 13 : 14),
            ),
          ),
        ),
      ],
    );

    final Widget button = Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: fill ?? Colors.transparent,
        borderRadius: BorderRadius.circular(radius),
        child: InkWell(
          borderRadius: BorderRadius.circular(radius),
          onTap: enabled ? onPressed : null,
          child: Container(
            height: height,
            padding: EdgeInsets.symmetric(horizontal: expand ? 12 : 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: border == null ? null : Border.all(color: border),
            ),
            child: child,
          ),
        ),
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// 48x48 square icon button with a fill and a border, as in the headers.
class DoomIconButton extends StatelessWidget {
  const DoomIconButton({
    super.key,
    this.icon,
    this.glyph,
    required this.semanticLabel,
    required this.onPressed,
    this.size = 48,
    this.radius = 16,
    this.badge,
    this.filled = true,
    this.foreground,
    this.fill,
    this.tooltip,
  }) : assert(
         icon != null || glyph != null,
         'a DoomIconButton draws either a Material icon or a design glyph',
       );

  final IconData? icon;

  /// One of the design's own stroke icons, drawn instead of [icon].
  final StrokeGlyph? glyph;
  final String semanticLabel;

  /// Shown on hover, for a button whose label had to be dropped.
  final String? tooltip;
  final VoidCallback? onPressed;
  final double size;
  final double radius;

  /// The alert count on the overview header.
  final String? badge;
  final bool filled;
  final Color? foreground;

  /// Overrides the default fill, for example the accent download button.
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Color fg = foreground ?? t.text;
    Widget button = Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: fill ?? (filled ? t.iconButtonFill : Colors.transparent),
        borderRadius: BorderRadius.circular(radius),
        child: InkWell(
          borderRadius: BorderRadius.circular(radius),
          onTap: onPressed,
          child: Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: filled ? Border.all(color: t.strongBorder) : null,
            ),
            child: glyph == null
                ? Icon(icon, size: 20, color: fg)
                : StrokeIcon(glyph!, size: 20, color: fg),
          ),
        ),
      ),
    );
    if (tooltip != null) {
      button = Tooltip(message: tooltip!, child: button);
    }
    if (badge == null) return button;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        button,
        Positioned(
          top: -6,
          right: -6,
          child: Container(
            constraints: const BoxConstraints(minWidth: 20),
            height: 20,
            padding: const EdgeInsets.symmetric(horizontal: 5),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: t.danger,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              badge!,
              style: AppText.pill.copyWith(color: t.onDanger),
            ),
          ),
        ),
      ],
    );
  }
}

/// A card's actions on one row: the primary flexes, the rest hug their label.
///
/// This is the shape every board draws — `Pull and redeploy` `Restart` `Down`,
/// or a replica stepper followed by `Update` and `Roll back` — and it is a
/// [Row], never a [Wrap], because a card's actions never reflow.
class ActionRow extends StatelessWidget {
  const ActionRow({
    super.key,
    this.primary,
    this.leading,
    required this.children,
    this.gap = 8,
  });

  /// The one control that takes the space the others leave.
  final Widget? primary;

  /// A control drawn before [primary] at its natural width, such as the
  /// Swarm replica stepper.
  final Widget? leading;
  final List<Widget> children;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        if (leading != null) leading!,
        if (primary != null) ...<Widget>[
          if (leading != null) SizedBox(width: gap),
          Expanded(child: primary!),
        ] else
          const Spacer(),
        for (final Widget child in children) ...<Widget>[
          SizedBox(width: gap),
          child,
        ],
      ],
    );
  }
}

/// Filter chip on the Containers screen.
class FilterChipButton extends StatelessWidget {
  const FilterChipButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? t.accent : t.surface,
        borderRadius: AppShape.pill,
        child: InkWell(
          borderRadius: AppShape.pill,
          onTap: onPressed,
          child: Container(
            height: context.density.chip,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              borderRadius: AppShape.pill,
              border: Border.all(color: selected ? t.accent : t.strongBorder),
            ),
            // A `Row` that hugs, not `alignment:`: an alignment fills the
            // parent's bounded width, which turns any row of chips into a
            // column of full-width bars.
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.buttonLabel.copyWith(
                      color: selected ? t.onAccent : t.text,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Two- or three-way segmented control used on Stacks and Resources.
class SegmentedControl extends StatelessWidget {
  const SegmentedControl({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
    this.semanticLabel,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Semantics(
      label: semanticLabel,
      container: true,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: AppShape.smallCardRadius,
          border: Border.all(color: t.border),
        ),
        child: Row(
          children: <Widget>[
            for (int i = 0; i < labels.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(width: 4),
              Expanded(
                child: Semantics(
                  button: true,
                  selected: i == index,
                  child: Material(
                    color: i == index ? t.strongBorder : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => onChanged(i),
                      child: SizedBox(
                        height: context.density.segment,
                        child: Center(
                          child: Text(
                            labels[i],
                            style: AppText.buttonLabel.copyWith(
                              color: i == index ? t.text : t.mutedText,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Minus / count / plus stepper for Swarm replicas.
class ReplicaStepper extends StatelessWidget {
  const ReplicaStepper({
    super.key,
    required this.name,
    required this.value,
    required this.onChanged,
  });

  final String name;
  final int value;
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Semantics(
      label: 'Scale $name',
      container: true,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: t.outlineBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _StepButton(
              icon: Icons.remove,
              label: 'Remove a replica from $name',
              onPressed: onChanged == null || value <= 0
                  ? null
                  : () => onChanged!(value - 1),
            ),
            SizedBox(
              width: 24,
              child: Text(
                '$value',
                textAlign: TextAlign.center,
                style: AppText.rowTitle.copyWith(color: t.text),
              ),
            ),
            _StepButton(
              icon: Icons.add,
              label: 'Add a replica to $name',
              onPressed: onChanged == null ? null : () => onChanged!(value + 1),
            ),
          ],
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.label, this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          width: 44,
          height: 42,
          child: Icon(
            icon,
            size: 18,
            color: onPressed == null ? t.mutedText : t.text,
          ),
        ),
      ),
    );
  }
}
