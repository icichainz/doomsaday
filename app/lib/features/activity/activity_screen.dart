import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../../data/this_device.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/filter_field.dart';
import '../../widgets/page.dart';
import '../../widgets/primitives.dart';
import '../../widgets/state_views.dart';
import '../../widgets/stroke_icons.dart';

/// The chips above the log.
enum ActivityFilter {
  all('All'),
  denied('Denied'),
  errors('Errors'),
  mine('Mine');

  const ActivityFilter(this.label);

  final String label;
}

/// One day of the log, newest first, under its heading.
typedef ActivityDay = ({String heading, List<ActivityEntry> entries});

/// Filters [entries] by chip and text, then groups them by calendar day.
///
/// The text matches the sentence, the device, the action and the target, so
/// "nginx", "iPad" and "prune" all find what they should.
List<ActivityDay> groupActivity(
  List<ActivityEntry> entries, {
  ActivityFilter filter = ActivityFilter.all,
  String query = '',
  String? selfDeviceId,
  DateTime? now,
}) {
  final String q = query.trim().toLowerCase();
  final List<ActivityEntry> kept =
      entries
          .where(
            (ActivityEntry e) => switch (filter) {
              ActivityFilter.all => true,
              ActivityFilter.denied => e.result == 'denied',
              ActivityFilter.errors => e.result == 'error',
              ActivityFilter.mine => e.isFrom(selfDeviceId),
            },
          )
          .where(
            (ActivityEntry e) =>
                q.isEmpty ||
                <String>[
                  e.sentence(selfDeviceId: selfDeviceId),
                  e.deviceName,
                  e.action,
                  e.target,
                ].any((String field) => field.toLowerCase().contains(q)),
          )
          .toList()
        ..sort((ActivityEntry a, ActivityEntry b) => b.time.compareTo(a.time));

  final List<ActivityDay> days = <ActivityDay>[];
  for (final ActivityEntry entry in kept) {
    final String heading = formatDayHeading(entry.time, now: now);
    if (days.isEmpty || days.last.heading != heading) {
      days.add((heading: heading, entries: <ActivityEntry>[]));
    }
    days.last.entries.add(entry);
  }
  return days;
}

/// `GET /activity` — the full audit log, reached from Server settings.
///
/// Every mutating call is written here with device, role, action, target and
/// result, including the ones the agent refused (API_NOTES §32). The board is
/// `design/Activity.dc.html`.
class ActivityScreen extends ConsumerStatefulWidget {
  const ActivityScreen({super.key, required this.serverId});

  final String serverId;

  @override
  ConsumerState<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends ConsumerState<ActivityScreen> {
  final TextEditingController _query = TextEditingController();
  ActivityFilter _filter = ActivityFilter.all;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String serverId = widget.serverId;
    final AsyncValue<List<ActivityEntry>> activity = ref.watch(
      activityProvider(serverId),
    );
    // "…from this phone" rather than whatever this device was paired under.
    final String selfId =
        ref.watch(meProvider(serverId)).valueOrNull?.deviceId ??
        ref.watch(serverProvider(serverId)).deviceId;

    return PushedPage(
      gap: 14,
      children: <Widget>[
        const BackLink('Settings'),
        ScreenHeader(
          title: 'Activity log',
          subtitle: 'Who did what on $serverId, and when',
        ),
        FilterField(
          controller: _query,
          hint: 'Filter by container, device or action',
          onChanged: (_) => setState(() {}),
        ),
        Semantics(
          label: 'Filter by result',
          container: true,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                for (final ActivityFilter f
                    in ActivityFilter.values) ...<Widget>[
                  if (f.index > 0) const SizedBox(width: 8),
                  FilterChipButton(
                    label: f.label,
                    selected: f == _filter,
                    onPressed: () => setState(() => _filter = f),
                  ),
                ],
              ],
            ),
          ),
        ),
        AsyncSection<List<ActivityEntry>>(
          value: activity,
          onRetry: () => ref.invalidate(activityProvider(serverId)),
          loadingRows: 6,
          loadingRowHeight: 64,
          isEmpty: (List<ActivityEntry> list) => list.isEmpty,
          empty: const EmptyView(
            icon: Icons.history,
            title: 'Nothing recorded yet',
            message: 'Actions taken from any paired device show up here.',
          ),
          builder: (List<ActivityEntry> list) {
            final List<ActivityDay> days = groupActivity(
              list,
              filter: _filter,
              query: _query.text,
              selfDeviceId: selfId,
            );
            if (days.isEmpty) {
              return EmptyView(
                glyph: StrokeGlyph.search,
                title: 'No matching activity',
                message: 'Nothing here matches that search.',
                secondary: EmptyAction(
                  'Clear filter',
                  onPressed: () => setState(() {
                    _query.clear();
                    _filter = ActivityFilter.all;
                  }),
                ),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final ActivityDay day in days) ...<Widget>[
                  if (day != days.first) const SizedBox(height: 16),
                  SectionHeader(day.heading),
                  const SizedBox(height: 8),
                  RowGroup(
                    children: <Widget>[
                      for (final ActivityEntry entry in day.entries)
                        _ActivityRow(entry: entry, selfDeviceId: selfId),
                    ],
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.entry, required this.selfDeviceId});

  final ActivityEntry entry;
  final String selfDeviceId;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool self = entry.isFrom(selfDeviceId);
    final String device = self
        ? thisDeviceLabel()
        : (entry.deviceName.isEmpty ? 'Unknown device' : entry.deviceName);
    final String who = entry.role.isEmpty
        ? device
        : '$device · ${entry.role.toLowerCase()}';
    final PillTone tone = switch (entry.result) {
      'denied' => PillTone.warning,
      'error' => PillTone.danger,
      _ => PillTone.neutral,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 44,
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                formatHourMinute(entry.time),
                style: AppText.monoSmall.copyWith(color: t.mutedText),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  entry.sentence(
                    selfDeviceId: selfDeviceId,
                    selfLabel: thisDeviceLabel(capitalized: false),
                    withResult: false,
                  ),
                  style: AppText.label.copyWith(color: t.text, height: 1.35),
                ),
                const SizedBox(height: 4),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        who,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.tiny.copyWith(color: t.mutedText),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _ResultPill(
                      entry.result.isEmpty ? 'ok' : entry.result,
                      tone,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The board's small result pill: 2 px taller than text, not the 4 px of a
/// status pill, so it sits on the device line without growing it.
class _ResultPill extends StatelessWidget {
  const _ResultPill(this.label, this.tone);

  final String label;
  final PillTone tone;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final (Color bg, Color fg) = switch (tone) {
      PillTone.warning => (t.warningTint, t.warning),
      PillTone.danger => (t.dangerTint, t.danger),
      PillTone.accent => (t.accentTint, t.accent),
      PillTone.neutral => (t.faintDivider, t.text),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: AppShape.pill),
      child: Text(label, style: AppText.pill.copyWith(color: fg)),
    );
  }
}
