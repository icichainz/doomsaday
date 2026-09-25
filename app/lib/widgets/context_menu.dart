/// Right-click menus on list and table rows, with the same actions as the
/// row's more button.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';

class MenuAction {
  const MenuAction({
    required this.label,
    required this.onSelected,
    this.icon,
    this.danger = false,
    this.enabled = true,
  });

  final String label;
  final VoidCallback onSelected;
  final IconData? icon;
  final bool danger;
  final bool enabled;
}

/// Opens [actions] at [position] in the global coordinate space.
Future<void> showActionMenu(
  BuildContext context,
  Offset position,
  List<MenuAction> actions,
) async {
  if (actions.isEmpty) return;
  final AppTokens t = context.tokens;
  final RenderBox overlay =
      Overlay.of(context).context.findRenderObject()! as RenderBox;
  final MenuAction? chosen = await showMenu<MenuAction>(
    context: context,
    color: t.surface,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(color: t.strongBorder),
    ),
    position: RelativeRect.fromRect(
      position & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    items: <PopupMenuEntry<MenuAction>>[
      for (final MenuAction action in actions)
        PopupMenuItem<MenuAction>(
          value: action,
          enabled: action.enabled,
          height: 38,
          child: Row(
            children: <Widget>[
              if (action.icon != null) ...<Widget>[
                Icon(
                  action.icon,
                  size: 16,
                  color: action.danger ? t.danger : t.mutedText,
                ),
                const SizedBox(width: 10),
              ],
              Text(
                action.label,
                style: AppText.small.copyWith(
                  color: action.danger ? t.danger : t.text,
                ),
              ),
            ],
          ),
        ),
    ],
  );
  chosen?.onSelected();
}

/// Adds a right-click (or long-press on a touch screen) menu to any row.
class ContextMenuRegion extends StatelessWidget {
  const ContextMenuRegion({
    super.key,
    required this.actions,
    required this.child,
  });

  final List<MenuAction> Function() actions;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp: (TapUpDetails details) =>
          showActionMenu(context, details.globalPosition, actions()),
      onLongPressStart: (LongPressStartDetails details) =>
          showActionMenu(context, details.globalPosition, actions()),
      child: child,
    );
  }
}
