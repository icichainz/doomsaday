/// P2 — "Free covers 2 servers": the sheet the pair action opens once the
/// edition's server limit is reached.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/buttons.dart';
import '../widgets/surfaces.dart';
import 'pro_badge.dart';

/// The sheet below 600, a centred dialog from 600 up.
Future<void> showServerLimit(
  BuildContext context, {
  required int limit,
  required List<String> paired,
}) => showAdaptiveModal<void>(
  context,
  width: 460,
  builder: (BuildContext context, bool sheet) =>
      ServerLimitBody(limit: limit, paired: paired, sheet: sheet),
);

/// The body of P2. Public because the `/pair` route shows the same words when
/// it is opened directly with no room left.
class ServerLimitBody extends StatelessWidget {
  const ServerLimitBody({
    super.key,
    required this.limit,
    required this.paired,
    this.sheet = false,
  });

  final int limit;

  /// The names of the servers already paired, which the sheet names.
  final List<String> paired;
  final bool sheet;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return ModalBody(
      handle: sheet,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: t.proRed,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(Icons.lock_outline, size: 22, color: t.proInk),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          'Free covers $limit servers',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: AppFonts.display,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                            color: t.text,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const ProBadge(),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'You have paired ${_names(paired)}.',
                    style: AppText.small.copyWith(color: t.mutedText),
                  ),
                ],
              ),
            ),
          ],
        ),
        Text(
          'Doomsaday Pro pairs as many servers as you like. Or unpair one of '
          '${paired.length == 2 ? 'these two' : 'them'} to make room.',
          style: AppText.body.copyWith(color: t.codeText, height: 1.5),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            DoomButton(
              'Get Doomsaday Pro',
              tone: ButtonTone.primary,
              height: 54,
              radius: 16,
              expand: true,
              onPressed: () => openProUpgrade(context),
            ),
            const SizedBox(height: 10),
            DoomButton(
              'Not now',
              height: 48,
              radius: 16,
              expand: true,
              onPressed: () => _notNow(context),
            ),
          ],
        ),
      ],
    );
  }

  /// Closes the sheet, or leaves the `/pair` route when this is the page a
  /// deep link landed on.
  static void _notNow(BuildContext context) {
    final NavigatorState navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }
    GoRouter.of(context).go('/');
  }

  /// "prod-eu-1 and staging-1", or a comma list for a phone that arrived with
  /// more servers than this edition would pair today.
  static String _names(List<String> names) {
    if (names.isEmpty) return 'every server this edition covers';
    if (names.length == 1) return names.single;
    return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  }
}
