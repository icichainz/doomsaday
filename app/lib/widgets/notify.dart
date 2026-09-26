import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// One-line feedback for an action that succeeded or failed.
void notify(BuildContext context, String message, {bool danger = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(_bar(context.tokens, message, danger: danger));
}

/// [notify] for a message that accompanies a navigation, such as "paired"
/// followed by the new server's Overview.
///
/// A snackbar needs a Scaffold to present on, and the page being left may not
/// have one — the fleet at 1100 and up is a plain page under the sidebar — so
/// the message waits for the frame that puts the destination on screen.
void notifyAfterNavigation(BuildContext context, String message) {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final SnackBar bar = _bar(context.tokens, message);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!messenger.mounted) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(bar);
  });
}

SnackBar _bar(AppTokens t, String message, {bool danger = false}) => SnackBar(
  content: Text(message),
  backgroundColor: danger ? t.dangerTint : t.surface,
  showCloseIcon: true,
  closeIconColor: t.mutedText,
);
