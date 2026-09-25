import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/page.dart';
import '../../widgets/primitives.dart';
import '../../widgets/state_views.dart';

/// `GET /activity` — the full audit log, reached from Server settings.
///
/// Every mutating call is written here with device, role, action, target and
/// result, including the ones the agent refused (API_NOTES §32).
class ActivityScreen extends ConsumerWidget {
  const ActivityScreen({super.key, required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final AsyncValue<List<ActivityEntry>> activity = ref.watch(
      activityProvider(serverId),
    );

    return PushedPage(
      gap: 14,
      children: <Widget>[
        const BackLink('Settings'),
        ScreenHeader(
          title: 'Activity log',
          subtitle: 'Who did what on $serverId, and when',
        ),
        AsyncSection<List<ActivityEntry>>(
          value: activity,
          onRetry: () => ref.invalidate(activityProvider(serverId)),
          loadingRows: 6,
          loadingRowHeight: 54,
          isEmpty: (List<ActivityEntry> list) => list.isEmpty,
          empty: const EmptyView(
            icon: Icons.history,
            title: 'Nothing recorded yet',
            message: 'Actions taken from any paired phone show up here.',
          ),
          builder: (List<ActivityEntry> list) => RowGroup(
            children: <Widget>[
              for (final ActivityEntry entry in list)
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 58),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      SizedBox(
                        width: 52,
                        child: Text(
                          entry.at,
                          style: AppText.monoSmall.copyWith(color: t.mutedText),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              entry.text,
                              style: AppText.label.copyWith(color: t.text),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              entry.action,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.tiny.copyWith(
                                color: t.mutedText,
                                fontFamily: AppFonts.mono,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (entry.failed) ...<Widget>[
                        const SizedBox(width: 8),
                        StatusPill(
                          entry.result,
                          tone: entry.result == 'denied'
                              ? PillTone.warning
                              : PillTone.danger,
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
