/// The PRO badge, and the one door to buying Pro.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/buttons.dart';
import '../widgets/surfaces.dart';

/// The small deep-red rectangle that marks everything Pro adds.
///
/// Same colours in both themes, as the design asks.
class ProBadge extends StatelessWidget {
  const ProBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: t.proRed,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'PRO',
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
          color: t.proInk,
        ),
      ),
    );
  }
}

/// "Get Doomsaday Pro", from wherever it is offered.
///
/// One function, so the day there is something to buy there is one place to
/// change.
Future<void> openProUpgrade(BuildContext context) async {
  // TODO(store): open the listings once they exist —
  // https://apps.apple.com/app/id<APPLE_ID> on iOS and macOS,
  // https://play.google.com/store/apps/details?id=dev.doomsaday.doomsaday.pro
  // on Android.
  await showAdaptiveModal<void>(
    context,
    width: 460,
    builder: (BuildContext context, bool sheet) => _NotOnSaleBody(sheet: sheet),
  );
}

class _NotOnSaleBody extends StatelessWidget {
  const _NotOnSaleBody({required this.sheet});

  final bool sheet;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return ModalBody(
      handle: sheet,
      children: <Widget>[
        Text(
          'Doomsaday Pro is not on sale yet',
          style: AppText.sheetTitle.copyWith(color: t.text),
        ),
        Text(
          'There is no store listing to send you to. Pro is being finished; '
          'nothing you have paired changes when it arrives.',
          style: AppText.body.copyWith(color: t.mutedText, height: 1.5),
        ),
        DoomButton(
          'Close',
          expand: true,
          height: sheet ? 54 : 44,
          radius: sheet ? 16 : 12,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
