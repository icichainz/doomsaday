import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// One-line feedback for an action that succeeded or failed.
void notify(BuildContext context, String message, {bool danger = false}) {
  final AppTokens t = context.tokens;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: danger ? t.dangerTint : t.surface,
        showCloseIcon: true,
        closeIconColor: t.mutedText,
      ),
    );
}
