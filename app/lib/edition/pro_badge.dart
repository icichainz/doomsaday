/// The PRO badge, and the one door to buying Pro.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../widgets/buttons.dart';
import '../widgets/stroke_icons.dart';
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
/// change. Board `ProUpgrade`: a sheet below 600 and a 460 px dialog from
/// there, with the PRO tile, what Pro adds and a single "Got it". The store
/// buttons are absent rather than disabled: a greyed-out "Buy" would promise
/// something that cannot be done yet. They go above "Got it" once the
/// listings exist.
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

/// What Pro adds, in the order the upgrade dialog lists it.
const List<(StrokeGlyph, String, String)> kProFeatures =
    <(StrokeGlyph, String, String)>[
      (StrokeGlyph.servers, 'Unlimited servers', 'Free pairs two.'),
      (
        StrokeGlyph.fleet,
        'All servers',
        'Every container and alert in one view.',
      ),
      (
        StrokeGlyph.logWall,
        'Log wall',
        'Live logs from several containers at once.',
      ),
      (
        StrokeGlyph.search,
        'Cross-server search',
        'Jump to anything on every server.',
      ),
    ];

class _NotOnSaleBody extends StatelessWidget {
  const _NotOnSaleBody({required this.sheet});

  final bool sheet;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final double tile = sheet ? 48 : 44;
    return ModalBody(
      handle: sheet,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              width: tile,
              height: tile,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: t.proRed,
                borderRadius: BorderRadius.circular(sheet ? 16 : 14),
              ),
              child: Text(
                'PRO',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                  color: t.proInk,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                'Doomsaday Pro is not on sale yet',
                style: AppText.sheetTitle.copyWith(
                  fontSize: 22,
                  height: 1.2,
                  color: t.text,
                ),
              ),
            ),
          ],
        ),
        Text(
          'There is no store listing to send you to. When Pro arrives it adds '
          'these, and nothing you have paired changes.',
          style: AppText.body.copyWith(color: t.codeText, height: 1.5),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < kProFeatures.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(height: 12),
              _FeatureRow(
                glyph: kProFeatures[i].$1,
                title: kProFeatures[i].$2,
                line: kProFeatures[i].$3,
              ),
            ],
          ],
        ),
        Align(
          alignment: sheet ? Alignment.center : AlignmentDirectional.centerEnd,
          child: DoomButton(
            'Got it',
            tone: ButtonTone.primary,
            expand: sheet,
            height: sheet ? 54 : 40,
            radius: sheet ? 16 : 10,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
      ],
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.glyph,
    required this.title,
    required this.line,
  });

  final StrokeGlyph glyph;
  final String title;
  final String line;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Row(
      children: <Widget>[
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: t.iconButtonFill,
            borderRadius: BorderRadius.circular(12),
          ),
          child: StrokeIcon(glyph, size: 18, color: t.text),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(title, style: AppText.rowTitle.copyWith(color: t.text)),
              const SizedBox(height: 1),
              Text(line, style: AppText.small.copyWith(color: t.mutedText)),
            ],
          ),
        ),
      ],
    );
  }
}
