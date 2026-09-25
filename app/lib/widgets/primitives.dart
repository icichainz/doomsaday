import 'package:flutter/material.dart';

import '../data/format.dart';
import '../layout/layout.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'stroke_icons.dart';

/// Surface card: radius 20, 1px border, the design's card fill.
class DoomCard extends StatelessWidget {
  const DoomCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderColor,
    this.radius = AppShape.card,
    this.onTap,
    this.fill,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? borderColor;
  final double radius;
  final VoidCallback? onTap;
  final Color? fill;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final BorderRadius shape = BorderRadius.circular(radius);
    final Widget content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: fill ?? t.surface,
        borderRadius: shape,
        border: Border.all(color: borderColor ?? t.border),
      ),
      child: child,
    );
    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(borderRadius: shape, onTap: onTap, child: content),
    );
  }
}

enum PillTone { accent, warning, danger, neutral }

/// The 999-radius status pill used on almost every screen.
class StatusPill extends StatelessWidget {
  const StatusPill(
    this.label, {
    super.key,
    this.tone = PillTone.accent,
    this.dot = false,
  });

  final String label;
  final PillTone tone;

  /// The Live pill on the logs screen carries a leading dot.
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final (Color bg, Color fg) = switch (tone) {
      PillTone.accent => (t.accentTint, t.accent),
      PillTone.warning => (t.warningTint, t.warning),
      PillTone.danger => (t.dangerTint, t.danger),
      PillTone.neutral => (t.faintDivider, t.text),
    };
    return Container(
      padding: EdgeInsets.fromLTRB(dot ? 11 : 10, 4, 10, 4),
      decoration: BoxDecoration(color: bg, borderRadius: AppShape.pill),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (dot) ...<Widget>[
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.pill.copyWith(color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

/// Rounded track plus fill, used for CPU, memory and disk.
class MeterBar extends StatelessWidget {
  const MeterBar(this.value, {super.key, this.height = 6, this.color});

  final double value;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: Stack(
        children: <Widget>[
          Container(height: height, color: t.border),
          FractionallySizedBox(
            widthFactor: value.clamp(0.0, 1.0),
            child: Container(height: height, color: color ?? t.accent),
          ),
        ],
      ),
    );
  }
}

/// Segment strip for a stack's services or a service's replicas.
class SegmentMeter extends StatelessWidget {
  const SegmentMeter(this.colors, {super.key});

  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        for (int i = 0; i < colors.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 4),
          Expanded(
            child: Container(
              height: 6,
              decoration: BoxDecoration(
                color: colors[i],
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Uppercase small caption above a group, with an optional trailing link.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            title.toUpperCase(),
            style: AppText.sectionHeader.copyWith(color: t.mutedText),
          ),
        ),
        if (action != null) action!,
      ],
    );
  }
}

/// Shaded note with a leading icon, used on Pair and Registries.
class InfoNote extends StatelessWidget {
  const InfoNote({super.key, this.icon, this.glyph, required this.text})
    : assert(icon != null || glyph != null, 'a note has an icon');

  /// A Material icon, only where the stroke set has no [glyph] for it.
  final IconData? icon;
  final StrokeGlyph? glyph;
  final String text;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.infoNote,
        borderRadius: AppShape.smallCardRadius,
        border: Border.all(color: t.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (glyph != null)
            StrokeIcon(glyph!, size: 20, color: t.accent)
          else
            Icon(icon, size: 20, color: t.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: AppText.small.copyWith(color: t.mutedText, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

/// Monospaced code block, as on Pair an agent and the confirm sheet.
class CodeBlock extends StatelessWidget {
  const CodeBlock({super.key, this.caption, required this.code, this.trailing});

  final String? caption;
  final String code;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      padding: EdgeInsets.fromLTRB(
        14,
        caption == null ? 6 : 12,
        trailing == null ? 14 : 6,
        caption == null ? 6 : 12,
      ),
      decoration: BoxDecoration(
        color: t.codeBlock,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.border),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (caption != null) ...<Widget>[
                  Text(
                    caption!.toUpperCase(),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                      color: t.mutedText,
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
                Text(
                  code,
                  style: TextStyle(
                    fontFamily: AppFonts.mono,
                    fontSize: 12,
                    height: 1.5,
                    color: t.codeText,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Rows inside a bordered group; the group draws the dividers.
class RowGroup extends StatelessWidget {
  const RowGroup({
    super.key,
    required this.children,
    this.horizontalPadding = 16,
    this.trailingPadding,
    this.radius,
    this.dividerColor,
  });

  final List<Widget> children;
  final double horizontalPadding;

  /// Lists whose last cell is a 44px icon button inset the right edge.
  final double? trailingPadding;

  /// The card's corner, 20 unless a board draws it tighter (the desktop
  /// settings column and the tablet list use 16 and 18).
  final double? radius;

  /// The line between rows; the desktop boards draw it fainter.
  final Color? dividerColor;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      padding: EdgeInsets.only(
        left: horizontalPadding,
        right: trailingPadding ?? horizontalPadding,
      ),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: radius == null
            ? AppShape.cardRadius
            : BorderRadius.circular(radius!),
        border: Border.all(color: t.border),
      ),
      child: Column(
        children: <Widget>[
          for (int i = 0; i < children.length; i++)
            DecoratedBox(
              decoration: BoxDecoration(
                border: i == children.length - 1
                    ? null
                    : Border(
                        bottom: BorderSide(color: dividerColor ?? t.border),
                      ),
              ),
              child: children[i],
            ),
        ],
      ),
    );
  }
}

/// One line of text that loses its middle rather than its end, so both ends
/// of a host, a URL or a fingerprint stay readable.
///
/// A render object rather than a `LayoutBuilder`, because these rows sit
/// inside `IntrinsicHeight` (every card grid does) and a `LayoutBuilder`
/// cannot answer an intrinsic query.
class MiddleEllipsisText extends LeafRenderObjectWidget {
  const MiddleEllipsisText(
    this.text, {
    super.key,
    required this.style,
    this.textAlign = TextAlign.end,
  });

  final String text;
  final TextStyle style;
  final TextAlign textAlign;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMiddleEllipsis(
        text: text,
        style: style,
        textAlign: textAlign,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      );

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderMiddleEllipsis)
      ..text = text
      ..style = style
      ..textAlign = textAlign
      ..textDirection = Directionality.of(context)
      ..textScaler = MediaQuery.textScalerOf(context);
  }
}

class _RenderMiddleEllipsis extends RenderBox {
  _RenderMiddleEllipsis({
    required String text,
    required TextStyle style,
    required TextAlign textAlign,
    required TextDirection textDirection,
    required TextScaler textScaler,
  }) : _text = text,
       _style = style,
       _textAlign = textAlign,
       _textDirection = textDirection,
       _textScaler = textScaler;

  String _text;
  TextStyle _style;
  TextAlign _textAlign;
  TextDirection _textDirection;
  TextScaler _textScaler;

  final TextPainter _painter = TextPainter();

  set text(String value) {
    if (_text == value) return;
    _text = value;
    markNeedsLayout();
  }

  set style(TextStyle value) {
    if (_style == value) return;
    _style = value;
    markNeedsLayout();
  }

  set textAlign(TextAlign value) {
    if (_textAlign == value) return;
    _textAlign = value;
    markNeedsLayout();
  }

  set textDirection(TextDirection value) {
    if (_textDirection == value) return;
    _textDirection = value;
    markNeedsLayout();
  }

  set textScaler(TextScaler value) {
    if (_textScaler == value) return;
    _textScaler = value;
    markNeedsLayout();
  }

  @override
  void dispose() {
    _painter.dispose();
    super.dispose();
  }

  void _lay(String value) {
    _painter
      ..text = TextSpan(text: value, style: _style)
      ..textDirection = _textDirection
      ..textScaler = _textScaler
      ..maxLines = 1
      ..layout();
  }

  double _widthOf(String value) {
    _lay(value);
    return _painter.width;
  }

  /// The longest middle-elided form that still fits in [maxWidth].
  String _fit(double maxWidth) {
    if (!maxWidth.isFinite || _widthOf(_text) <= maxWidth) return _text;
    int low = 3;
    int high = _text.length;
    String best = ellipsizeMiddle(_text, low);
    while (low <= high) {
      final int mid = (low + high) ~/ 2;
      final String candidate = ellipsizeMiddle(_text, mid);
      if (_widthOf(candidate) <= maxWidth) {
        best = candidate;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return best;
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _widthOf(ellipsizeMiddle(_text, 8));

  @override
  double computeMaxIntrinsicWidth(double height) => _widthOf(_text);

  @override
  double computeMinIntrinsicHeight(double width) {
    _lay(_text);
    return _painter.height;
  }

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    _lay(_fit(constraints.maxWidth));
    return _painter.computeDistanceToActualBaseline(baseline);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    _lay(_fit(constraints.maxWidth));
    return constraints.constrain(Size(_painter.width, _painter.height));
  }

  @override
  void performLayout() {
    _lay(_fit(constraints.maxWidth));
    size = constraints.constrain(Size(_painter.width, _painter.height));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _lay(_fit(constraints.maxWidth));
    final double free = size.width - _painter.width;
    final double dx = switch (_textAlign) {
      TextAlign.end || TextAlign.right => free,
      TextAlign.center => free / 2,
      _ => 0,
    };
    _painter.paint(context.canvas, offset + Offset(dx, 0));
  }
}

/// How much of a row's width a piece of text may claim, as a flex factor.
/// Character count stands in for width: it is close enough to keep a long
/// value and a short label from starving each other.
int _share(String text) => text.length.clamp(1, 80);

/// `dt`/`dd` pair inside a [RowGroup].
///
/// The label hugs and the value takes the rest of the row, right-aligned on
/// one line: that is what keeps every value and every chevron in a group on
/// the same x, as the design draws them.
class DetailRow extends StatelessWidget {
  const DetailRow(
    this.label,
    this.value, {
    super.key,
    this.mono = false,
    this.middleEllipsis = false,
    this.minHeight = 46,
  });

  final String label;
  final String value;
  final bool mono;

  /// 46 on the phone, 44 in the desktop settings column.
  final double minHeight;

  /// Long hosts and fingerprints lose their middle, not their tail.
  final bool middleEllipsis;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final TextStyle valueStyle = mono
        ? AppText.mono.copyWith(color: t.text)
        : AppText.label.copyWith(color: t.text);
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      // `spaceBetween` with exactly two children is what pins the label to
      // the left and the value to the right edge whatever either is worth,
      // while both stay flexible so neither can overflow the row. The flex
      // is the text length, so the share each may claim is roughly the width
      // each needs and neither is clipped while the other has room to spare.
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Flexible(
            flex: _share(label),
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: AppText.label.copyWith(color: t.mutedText),
              ),
            ),
          ),
          Flexible(
            flex: _share(value),
            child: middleEllipsis
                ? MiddleEllipsisText(value, style: valueStyle)
                : GlyphText(value, textAlign: TextAlign.end, style: valueStyle),
          ),
        ],
      ),
    );
  }
}

/// Tappable row with a value and a chevron, inside a [RowGroup].
class NavRow extends StatelessWidget {
  const NavRow({
    super.key,
    required this.label,
    this.value,
    this.onTap,
    this.minHeight = 50,
  });

  final String label;
  final String? value;
  final VoidCallback? onTap;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: Row(
          children: <Widget>[
            // The label and the value share everything left of the chevron,
            // so the chevron lands at the card's right edge on every row
            // rather than trailing its own text.
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Flexible(
                    flex: _share(label),
                    child: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.label.copyWith(color: t.text),
                      ),
                    ),
                  ),
                  if (value != null)
                    Flexible(
                      flex: _share(value!),
                      child: Text(
                        value!,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: AppText.label.copyWith(color: t.mutedText),
                      ),
                    )
                  else
                    const SizedBox.shrink(),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(Icons.chevron_right, size: 16, color: t.mutedText),
          ],
        ),
      ),
    );
  }
}

/// Row with a label, an optional second line, and a switch on the right.
class SwitchRow extends StatelessWidget {
  const SwitchRow({
    super.key,
    required this.label,
    this.description,
    required this.value,
    required this.onChanged,
    this.minHeight,
  });

  final String label;
  final String? description;
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// Defaults to 46, or 60 with a description.
  final double? minHeight;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: minHeight ?? (description == null ? 46 : 60),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(label, style: AppText.label.copyWith(color: t.text)),
                if (description != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    description!,
                    style: AppText.tiny.copyWith(color: t.mutedText),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          DoomSwitch(value: value, onChanged: onChanged, label: label),
        ],
      ),
    );
  }
}

/// The design's switch, on its own for the cells of a table (the alert
/// rules on the desktop).
class DoomSwitch extends StatelessWidget {
  const DoomSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.label,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  /// What the switch turns on, for a switch with no text beside it.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Semantics(
      label: label,
      child: Switch.adaptive(
        value: value,
        onChanged: onChanged,
        activeTrackColor: t.accent,
        activeThumbColor: t.onAccent,
        inactiveTrackColor: t.iconButtonFill,
        inactiveThumbColor: t.mutedText,
        trackOutlineColor: WidgetStatePropertyAll<Color>(t.outlineBorder),
      ),
    );
  }
}

/// `‹ Containers` style back link at the top of a pushed screen.
class BackLink extends StatelessWidget {
  const BackLink(this.label, {super.key, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    // With the sidebar there is nothing to go back to: it navigated here.
    if (WindowClass.of(context).usesSidebar) return const SizedBox.shrink();
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap ?? () => Navigator.of(context).maybePop(),
        child: SizedBox(
          height: AppShape.touchTarget,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              StrokeIcon(StrokeGlyph.chevronLeft, size: 20, color: t.mutedText),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(fontSize: 15, color: t.mutedText)),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
  }
}

/// Big title with a subtitle underneath and optional trailing buttons.
class ScreenHeader extends StatelessWidget {
  const ScreenHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.subtitleWidget,
    this.pill,
    this.actions = const <Widget>[],
    this.large = false,
  });

  final String title;
  final String? subtitle;
  final Widget? subtitleWidget;

  /// A status pill drawn on the title's own line, as T1 draws it.
  final Widget? pill;
  final List<Widget> actions;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
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
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // T1 draws the tablet titles at the desktop's 28.
                      style:
                          (large
                                  ? AppText.screenTitleLarge
                                  : AppText.screenTitle)
                              .copyWith(
                                color: t.text,
                                fontSize: WindowClass.of(context).isMedium
                                    ? 28
                                    : null,
                              ),
                    ),
                  ),
                  if (pill != null) ...<Widget>[
                    const SizedBox(width: 10),
                    pill!,
                  ],
                ],
              ),
              if (subtitleWidget != null) ...<Widget>[
                const SizedBox(height: 6),
                subtitleWidget!,
              ] else if (subtitle != null) ...<Widget>[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: AppText.small.copyWith(color: t.mutedText),
                ),
              ],
            ],
          ),
        ),
        for (final Widget action in actions) ...<Widget>[
          const SizedBox(width: 8),
          action,
        ],
      ],
    );
  }
}
