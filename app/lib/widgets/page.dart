import 'package:flutter/material.dart';

import '../layout/layout.dart';
import '../theme/tokens.dart';

/// Scrolling column with the design's side padding and a fixed gap.
///
/// Below 600 it fills the width, exactly as the phone design draws it. From
/// 600 up it is capped at about 720 px and centred, which is what every screen
/// without its own desktop board does.
class _Column extends StatelessWidget {
  const _Column({
    required this.children,
    required this.gap,
    required this.padding,
    this.fillLast = false,
  });

  final List<Widget> children;
  final double gap;
  final EdgeInsets padding;

  /// Screens that push their last element to the bottom of the viewport.
  final bool fillLast;

  Widget _cap(BuildContext context, Widget child) {
    if (WindowClass.of(context).isCompact) return child;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: ShellMetrics.readableWidth),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> spaced = <Widget>[
      for (int i = 0; i < children.length; i++) ...<Widget>[
        if (i > 0) SizedBox(height: gap),
        children[i],
      ],
    ];
    if (!fillLast) {
      return SingleChildScrollView(
        padding: padding,
        child: _cap(
          context,
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: spaced,
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return SingleChildScrollView(
          padding: padding,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: constraints.maxHeight - padding.vertical,
            ),
            child: IntrinsicHeight(
              child: _cap(
                context,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    ...spaced.take(spaced.length - 1),
                    const Spacer(),
                    SizedBox(height: gap),
                    spaced.last,
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A tab screen inside the server shell; the shell owns the Scaffold.
class ShellPage extends StatelessWidget {
  const ShellPage({
    super.key,
    required this.children,
    this.gap = 16,
    this.top = 24,
  });

  final List<Widget> children;
  final double gap;
  final double top;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final double side = context.density.gutter;
    return Material(
      color: t.ground,
      child: SafeArea(
        bottom: false,
        child: _Column(
          gap: gap,
          padding: EdgeInsets.fromLTRB(side, top, side, 20),
          children: children,
        ),
      ),
    );
  }
}

/// A pushed screen with its own Scaffold and ground colour.
class PushedPage extends StatelessWidget {
  const PushedPage({
    super.key,
    required this.children,
    this.gap = 14,
    this.top = 20,
    this.fillLast = false,
  });

  final List<Widget> children;
  final double gap;
  final double top;
  final bool fillLast;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final double side = context.density.gutter;
    return Scaffold(
      backgroundColor: t.ground,
      body: SafeArea(
        child: _Column(
          gap: gap,
          fillLast: fillLast,
          padding: EdgeInsets.fromLTRB(side, top, side, 24),
          children: children,
        ),
      ),
    );
  }
}
