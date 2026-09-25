/// The three states every screen shares, as the `EmptyStates` and
/// `LoadingError` boards draw them: an empty card with a 56 px icon tile, a
/// skeleton of dimmed bars while loading (no spinner), and one error card with
/// the agent's reason, "Retry" and, where it helps, "Server settings".
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'buttons.dart';
import 'stroke_icons.dart';

// ------------------------------------------------------------------ loading

/// Loading placeholder: the shapes a list is about to fill, drawn as dimmed
/// bars in the cards they will become. Never a spinner.
///
/// [height] picks the shape: a stat card from 90 up, a list row from 36 up,
/// and a single line (a log line, a table cell) below that.
class LoadingView extends StatelessWidget {
  const LoadingView({super.key, this.rows = 4, this.height = 66}) : columns = 1;

  /// The overview's stat cards: [count] skeleton cards, [columns] to a row.
  const LoadingView.statCards({super.key, int count = 4, this.columns = 2})
    : rows = count,
      height = 104;

  final int rows;
  final double height;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final Widget Function(int i) item = height >= 90
        ? (int i) => _SkeletonStatCard(height: height, seed: i)
        : height >= 36
        ? (int i) => _SkeletonRow(height: height, seed: i)
        : (int i) => _SkeletonLine(height: height, seed: i);
    final List<Widget> children = <Widget>[
      for (int i = 0; i < rows; i++) item(i),
    ];
    final double gap = height >= 36 ? 12 : 6;
    return Semantics(
      label: 'Loading',
      container: true,
      child: ExcludeSemantics(
        child: columns <= 1
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (int i = 0; i < children.length; i++) ...<Widget>[
                    if (i > 0) SizedBox(height: gap),
                    children[i],
                  ],
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (int r = 0; r < (rows / columns).ceil(); r++) ...<Widget>[
                    if (r > 0) SizedBox(height: gap),
                    Row(
                      children: <Widget>[
                        for (int c = 0; c < columns; c++) ...<Widget>[
                          if (c > 0) SizedBox(width: gap),
                          Expanded(
                            child: r * columns + c < rows
                                ? children[r * columns + c]
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

/// One dimmed bar.
class _Bar extends StatelessWidget {
  const _Bar({this.width, required this.height, this.faint = false});

  final double? width;
  final double height;
  final bool faint;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: faint ? t.faintDivider : t.border,
        borderRadius: BorderRadius.circular(height >= 20 ? 8 : height / 2),
      ),
    );
  }
}

/// Label, figure and meter of a stat card, as bars.
class _SkeletonStatCard extends StatelessWidget {
  const _SkeletonStatCard({required this.height, required this.seed});

  final double height;
  final int seed;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      height: height,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _Bar(width: seed.isEven ? 64 : 48, height: 10),
          const SizedBox(height: 12),
          _Bar(width: seed.isEven ? 88 : 70, height: 24),
          const Spacer(),
          const _Bar(height: 6, faint: true),
        ],
      ),
    );
  }
}

/// Icon tile and two lines of a list row, as bars.
class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow({required this.height, required this.seed});

  final double height;
  final int seed;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool tall = height >= 56;
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.border),
      ),
      child: Row(
        children: <Widget>[
          if (tall) ...<Widget>[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: t.border,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints box) => Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _Bar(
                    width: box.maxWidth * (seed.isEven ? 0.55 : 0.42),
                    height: 12,
                  ),
                  if (tall) ...<Widget>[
                    const SizedBox(height: 8),
                    _Bar(
                      width: box.maxWidth * (seed.isEven ? 0.8 : 0.66),
                      height: 10,
                      faint: true,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A single bar for a log line or a cell.
class _SkeletonLine extends StatelessWidget {
  const _SkeletonLine({required this.height, required this.seed});

  final double height;
  final int seed;

  @override
  Widget build(BuildContext context) {
    const List<double> widths = <double>[0.72, 0.9, 0.56, 0.8];
    return SizedBox(
      height: height,
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: widths[seed % widths.length],
          child: _Bar(height: (height * 0.5).clamp(8, 12)),
        ),
      ),
    );
  }
}

// -------------------------------------------------------------------- empty

/// A button on an empty state. At most two per state.
class EmptyAction {
  const EmptyAction(
    this.label, {
    required this.onPressed,
    this.icon,
    this.glyph,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final StrokeGlyph? glyph;
}

/// Neutral for "there is nothing", healthy for "there is nothing wrong".
enum EmptyTone { neutral, healthy }

/// Nothing to show, with the reason spelled out: a 56 px stroke-icon tile, a
/// title, one line, an optional mono hint and at most two buttons.
class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    this.glyph,
    this.icon,
    required this.title,
    required this.message,
    this.detail,
    this.tone = EmptyTone.neutral,
    this.primary,
    this.secondary,
  }) : assert(glyph != null || icon != null, 'an empty state has an icon');

  /// The design's own stroke icon; [icon] is the fallback for the few states
  /// the stroke set has no glyph for.
  final StrokeGlyph? glyph;
  final IconData? icon;
  final String title;
  final String message;

  /// A path or a command, set in mono under the line: `/opt/stacks`.
  final String? detail;
  final EmptyTone tone;

  /// The accent button. With it, both buttons fill the card's width.
  final EmptyAction? primary;

  /// The outline button; alone, it hugs its label in the middle.
  final EmptyAction? secondary;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool healthy = tone == EmptyTone.healthy;
    final Color iconColor = healthy ? t.accent : t.mutedText;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: AppShape.cardRadius,
        border: Border.all(color: t.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 56,
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: healthy ? t.accentTint : t.iconButtonFill,
              borderRadius: BorderRadius.circular(18),
              border: healthy ? null : Border.all(color: t.strongBorder),
            ),
            child: glyph != null
                ? StrokeIcon(glyph!, size: 24, color: iconColor)
                : Icon(icon, size: 24, color: iconColor),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: AppText.cardTitle.copyWith(color: t.text),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(color: t.mutedText, height: 1.5),
          ),
          if (detail != null) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: t.codeBlock,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: t.border),
              ),
              child: SelectableText(
                detail!,
                style: AppText.monoSmall.copyWith(color: t.codeText),
              ),
            ),
          ],
          if (primary != null) ...<Widget>[
            const SizedBox(height: 20),
            DoomButton(
              primary!.label,
              icon: primary!.icon,
              glyph: primary!.glyph,
              tone: ButtonTone.primary,
              expand: true,
              height: 52,
              radius: 16,
              onPressed: primary!.onPressed,
            ),
            if (secondary != null) ...<Widget>[
              const SizedBox(height: 10),
              DoomButton(
                secondary!.label,
                icon: secondary!.icon,
                glyph: secondary!.glyph,
                expand: true,
                height: 48,
                radius: 16,
                onPressed: secondary!.onPressed,
              ),
            ],
          ] else if (secondary != null) ...<Widget>[
            const SizedBox(height: 20),
            DoomButton(
              secondary!.label,
              icon: secondary!.icon,
              glyph: secondary!.glyph,
              onPressed: secondary!.onPressed,
            ),
          ],
        ],
      ),
    );
  }
}

// -------------------------------------------------------------------- error

/// The path an unreachable agent, or any failed call, takes on every screen:
/// a danger-bordered card with the headline, the agent's error code, the
/// reason in a sentence, "Retry" and optionally "Server settings".
class ErrorView extends StatelessWidget {
  const ErrorView({
    super.key,
    required this.error,
    this.onRetry,
    this.onSettings,
  });

  final Object error;
  final VoidCallback? onRetry;

  /// "Server settings", for the screens where the fix may be there (the
  /// address, the certificate, unpairing a host that is gone for good).
  final VoidCallback? onSettings;

  /// What went wrong, in two words.
  static String titleFor(Object error) {
    if (error is AgentException) {
      if (error.code == 'docker_unavailable') return 'Docker unavailable';
      if (error.isUnreachable) return 'Agent unreachable';
      return switch (error.status) {
        401 || 403 => 'Not allowed',
        404 => 'Not found',
        429 => 'Too many requests',
        _ => 'Something went wrong',
      };
    }
    return 'Something went wrong';
  }

  /// The reason, without repeating the title, and with what to try next when
  /// the agent cannot be reached.
  static String reasonFor(Object error) {
    final String title = titleFor(error);
    String message = error is AgentException ? error.message : '$error';
    message = message.trim();
    if (message.toLowerCase().startsWith(title.toLowerCase())) {
      message = message
          .substring(title.length)
          .replaceFirst(RegExp(r'^[\s.:,;–-]+'), '');
    }
    if (error is AgentException &&
        error.isUnreachable &&
        error.code != 'docker_unavailable') {
      const String next =
          'Check that the agent is running and this device can reach the '
          'host.';
      return message.isEmpty ? next : '$message $next';
    }
    return message.isEmpty ? 'The agent did not say why.' : message;
  }

  /// `agent_unreachable · 502`, or nothing for an error that is not the
  /// agent's.
  static String? codeFor(Object error) {
    if (error is! AgentException) return null;
    return error.status == null
        ? error.code
        : '${error.code} · ${error.status}';
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final String? code = codeFor(error);
    final List<Widget> buttons = <Widget>[
      if (onRetry != null)
        DoomButton(
          'Retry',
          tone: ButtonTone.primary,
          expand: true,
          height: 48,
          radius: 14,
          onPressed: onRetry,
        ),
      if (onSettings != null)
        DoomButton(
          'Server settings',
          expand: true,
          height: 48,
          radius: 14,
          onPressed: onSettings,
        ),
    ];
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: AppShape.cardRadius,
          border: Border.all(color: t.dangerBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: t.dangerTint,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: StrokeIcon(
                    StrokeGlyph.warning,
                    size: 22,
                    color: t.danger,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        titleFor(error),
                        style: AppText.cardTitle.copyWith(color: t.text),
                      ),
                      if (code != null) ...<Widget>[
                        const SizedBox(height: 2),
                        SelectableText(
                          code,
                          style: AppText.monoSmall.copyWith(color: t.mutedText),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              reasonFor(error),
              style: AppText.body.copyWith(color: t.codeText, height: 1.5),
            ),
            if (buttons.isNotEmpty) ...<Widget>[
              const SizedBox(height: 14),
              Row(
                children: <Widget>[
                  for (int i = 0; i < buttons.length; i++) ...<Widget>[
                    if (i > 0) const SizedBox(width: 10),
                    Expanded(child: buttons[i]),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Loading / error / empty / data in one place so every screen has all four.
class AsyncSection<T> extends StatelessWidget {
  const AsyncSection({
    super.key,
    required this.value,
    required this.builder,
    required this.onRetry,
    this.onSettings,
    this.empty,
    this.isEmpty,
    this.loadingRows = 4,
    this.loadingRowHeight = 66,
    this.loading,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback onRetry;
  final VoidCallback? onSettings;
  final Widget? empty;
  final bool Function(T data)? isEmpty;
  final int loadingRows;
  final double loadingRowHeight;

  /// A skeleton shaped differently from plain rows, such as
  /// [LoadingView.statCards].
  final Widget? loading;

  @override
  Widget build(BuildContext context) {
    return value.when(
      loading: () =>
          loading ?? LoadingView(rows: loadingRows, height: loadingRowHeight),
      error: (Object error, StackTrace _) =>
          ErrorView(error: error, onRetry: onRetry, onSettings: onSettings),
      data: (T data) {
        if (empty != null && (isEmpty?.call(data) ?? false)) return empty!;
        return builder(data);
      },
    );
  }
}
