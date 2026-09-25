/// Modal presentation that follows the window class.
///
/// Below 600 every modal is the phone's bottom sheet. From 600 up the same
/// content is a centred dialog (D3), which is also where `Esc` cancels and
/// `Return` confirms.
library;

import 'package:flutter/material.dart';

import '../layout/layout.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';

/// The padded column both presentations share. The sheet draws the grab
/// handle; the dialog does not.
class ModalBody extends StatelessWidget {
  const ModalBody({super.key, required this.children, this.handle = true});

  final List<Widget> children;
  final bool handle;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final List<Widget> spaced = <Widget>[
      for (int i = 0; i < children.length; i++) ...<Widget>[
        if (i > 0) SizedBox(height: handle ? 16 : 16),
        children[i],
      ],
    ];
    if (!handle) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: spaced,
      );
    }
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 12,
          bottom: 28 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: t.outlineBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            ...spaced,
          ],
        ),
      ),
    );
  }
}

/// D3's 500 px card, scrollable so a long body never overflows a short window.
class AppDialogShell extends StatelessWidget {
  const AppDialogShell({
    super.key,
    required this.child,
    this.width = ShellMetrics.dialogWidth,
  });

  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Size window = MediaQuery.sizeOf(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 24,
          bottom: 24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Material(
          color: t.surface,
          borderRadius: BorderRadius.circular(AppShape.card),
          child: Container(
            width: width.clamp(280.0, window.width - 48),
            constraints: BoxConstraints(maxHeight: window.height - 96),
            decoration: BoxDecoration(
              color: t.surface,
              borderRadius: BorderRadius.circular(AppShape.card),
              border: Border.all(color: t.strongBorder),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// A bottom sheet below 600, a centred dialog from 600 up.
///
/// [builder] is given `handle: true` for the sheet so it draws the grab bar,
/// and `false` inside the dialog.
Future<T?> showAdaptiveModal<T>(
  BuildContext context, {
  required Widget Function(BuildContext context, bool sheet) builder,
  bool dismissible = true,
  double width = ShellMetrics.dialogWidth,
}) {
  if (!WindowClass.of(context).usesDialogs) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      isDismissible: dismissible,
      enableDrag: dismissible,
      builder: (BuildContext context) => builder(context, true),
    );
  }
  return showDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierColor: const Color(0xB8040709),
    builder: (BuildContext context) =>
        AppDialogShell(width: width, child: builder(context, false)),
  );
}
