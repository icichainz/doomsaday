import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../../data/servers_repository.dart';
import '../../edition/edition.dart';
import '../../edition/locked_feature.dart';
import '../../layout/layout.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/primitives.dart';
import '../../widgets/state_views.dart';
import '../../widgets/stroke_icons.dart';
import '../fleet/fleet_screen.dart';
import '../pair/pair_agent_screen.dart';
import '../preferences/preferences_screen.dart';

/// Screen 1 — Servers. The app starts here.
class ServersScreen extends ConsumerStatefulWidget {
  const ServersScreen({super.key});

  @override
  ConsumerState<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends ConsumerState<ServersScreen> {
  final TextEditingController _search = TextEditingController();
  final Set<String> _retrying = <String>{};
  final Map<String, String> _retryFailed = <String, String>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// "Explore with demo data" and "Leave demo" are the same switch as the one
  /// in Preferences, so both go through [demoModeProvider].
  Future<void> _enterDemo() => ref.read(demoModeProvider.notifier).set(true);

  Future<void> _leaveDemo() => ref.read(demoModeProvider.notifier).set(false);

  Future<void> _retry(String serverId) async {
    setState(() {
      _retrying.add(serverId);
      _retryFailed.remove(serverId);
    });
    try {
      await ref.read(serversRepositoryProvider).retry(serverId);
      ref.invalidate(serverCardsProvider);
    } on AgentException catch (error) {
      if (mounted) setState(() => _retryFailed[serverId] = error.message);
    } finally {
      if (mounted) setState(() => _retrying.remove(serverId));
    }
  }

  @override
  Widget build(BuildContext context) {
    // At 1100 and up the sidebar already lists every server, so this route
    // shows the fleet instead of a second, redundant list — or, where the
    // edition does not include it, what the fleet would be.
    if (WindowClass.of(context).usesSidebar) {
      // With nothing paired there is no fleet to lock, and this route is the
      // only place a first server is added, so the empty state comes first.
      final bool locked =
          !ref.watch(editionProvider).fleetView &&
          ref.watch(serversRepositoryProvider).servers.isNotEmpty;
      return locked
          ? const LockedFeature(feature: ProFeature.fleet)
          : const FleetScreen();
    }

    final AppTokens t = context.tokens;
    final AsyncValue<List<ServerCard>> cards = ref.watch(serverCardsProvider);
    ref.watch(demoModeProvider);
    final ServersRepository repo = ref.watch(serversRepositoryProvider);
    final String query = _search.text.trim().toLowerCase();
    // With nothing paired the empty state owns the call to action, so the
    // pinned bottom bar steps aside rather than offering it a second time.
    final bool empty = cards.valueOrNull?.isEmpty ?? false;
    final String subtitle = cards.maybeWhen(
      data: (List<ServerCard> list) {
        final int online = list.where((ServerCard c) => c.online).length;
        if (repo.isDemo) {
          return 'Demo data · ${list.length} sample agents · $online online';
        }
        if (list.isEmpty) return 'No paired agents yet';
        return '${list.length} paired agent${list.length == 1 ? '' : 's'} · '
            '$online online';
      },
      orElse: () => 'Checking agents…',
    );

    return Scaffold(
      backgroundColor: t.ground,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ScreenHeader(
                title: 'Servers',
                large: true,
                // Board `MainDemo`: the longer demo line does not fit beside
                // the two buttons, so it runs full width under the row.
                subtitle: repo.isDemo ? null : subtitle,
                actions: <Widget>[
                  // Board `Main`: the cog sits left of the add button, and is
                  // the phone's only way into the app's own settings.
                  DoomIconButton(
                    glyph: StrokeGlyph.cog,
                    semanticLabel: 'Preferences',
                    tooltip: 'Preferences',
                    onPressed: () => openPreferences(context),
                  ),
                  DoomIconButton(
                    icon: Icons.add,
                    semanticLabel: 'Add server',
                    onPressed: () => showPairAgent(context, ref),
                  ),
                ],
              ),
              if (repo.isDemo) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.label.copyWith(color: t.mutedText),
                ),
              ],
              // Board `EmptyStates`: with nothing paired there is nothing to
              // search, so the field steps aside with the pinned button.
              if (!empty) ...<Widget>[
                const SizedBox(height: 16),
                _SearchField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                ),
              ],
              const SizedBox(height: 16),
              Expanded(
                child: AsyncSection<List<ServerCard>>(
                  value: cards,
                  onRetry: () => ref.invalidate(serverCardsProvider),
                  loadingRows: 3,
                  loadingRowHeight: 118,
                  isEmpty: (List<ServerCard> list) => list.isEmpty,
                  empty: SingleChildScrollView(
                    child: EmptyView(
                      glyph: StrokeGlyph.servers,
                      title: 'No servers yet',
                      message:
                          'Pair an agent, or look around with sample data.',
                      primary: EmptyAction(
                        'Pair a new server',
                        icon: Icons.add,
                        onPressed: () => showPairAgent(context, ref),
                      ),
                      secondary: EmptyAction(
                        'Explore with demo data',
                        onPressed: _enterDemo,
                      ),
                    ),
                  ),
                  builder: (List<ServerCard> list) {
                    final List<ServerCard> shown = list
                        .where(
                          (ServerCard c) =>
                              query.isEmpty ||
                              c.server.name.toLowerCase().contains(query) ||
                              c.server.host.toLowerCase().contains(query),
                        )
                        .toList(growable: false);
                    if (shown.isEmpty) {
                      return SingleChildScrollView(
                        child: EmptyView(
                          glyph: StrokeGlyph.search,
                          title: 'No matching servers',
                          message: 'Nothing here matches that search.',
                          secondary: EmptyAction(
                            'Clear search',
                            onPressed: () => setState(_search.clear),
                          ),
                        ),
                      );
                    }
                    return ListView.separated(
                      padding: EdgeInsets.zero,
                      itemCount: shown.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 16),
                      itemBuilder: (BuildContext context, int i) =>
                          _ServerCardView(
                            card: shown[i],
                            retrying: _retrying.contains(shown[i].server.id),
                            retryError: _retryFailed[shown[i].server.id],
                            onRetry: () => _retry(shown[i].server.id),
                          ),
                    );
                  },
                ),
              ),
              if (!empty) ...<Widget>[
                const SizedBox(height: 16),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: DoomButton(
                        'Pair a new server',
                        icon: Icons.add,
                        tone: ButtonTone.primary,
                        height: 56,
                        radius: 18,
                        expand: true,
                        onPressed: () => showPairAgent(context, ref),
                      ),
                    ),
                    // Demo mode is always one tap from being left again.
                    if (repo.isDemo) ...<Widget>[
                      const SizedBox(width: 8),
                      DoomButton(
                        'Leave demo',
                        glyph: StrokeGlyph.leave,
                        height: 56,
                        radius: 18,
                        onPressed: _leaveDemo,
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.border),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.search, size: 18, color: t.mutedText),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: TextStyle(color: t.text, fontSize: 15),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Search servers',
                hintStyle: TextStyle(color: t.mutedText, fontSize: 15),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerCardView extends StatelessWidget {
  const _ServerCardView({
    required this.card,
    required this.retrying,
    required this.retryError,
    required this.onRetry,
  });

  final ServerCard card;
  final bool retrying;
  final String? retryError;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool online = card.online;
    return DoomCard(
      borderColor: online ? t.border : t.dangerBorder,
      onTap: online ? () => context.go('/s/${card.server.id}/overview') : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: online ? t.accentTint : t.dangerTint,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.dns_outlined,
                  size: 22,
                  color: online ? t.accent : t.danger,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      card.server.name,
                      style: AppText.cardTitle.copyWith(color: t.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      card.server.host,
                      style: AppText.monoSmall.copyWith(color: t.mutedText),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StatusPill(
                online ? 'Online' : 'Offline',
                tone: online ? PillTone.accent : PillTone.danger,
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (online && card.stats != null)
            _Figures(stats: card.stats!)
          else
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    retryError ?? card.offlineReason ?? 'Agent unreachable.',
                    style: AppText.small.copyWith(
                      color: t.mutedText,
                      height: 1.4,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                DoomButton(
                  'Retry',
                  busy: retrying,
                  onPressed: onRetry,
                  height: 44,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Figures extends StatelessWidget {
  const _Figures({required this.stats});

  final SystemStats stats;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'Containers',
                style: AppText.tiny.copyWith(color: t.mutedText),
              ),
              const SizedBox(height: 6),
              Text.rich(
                TextSpan(
                  children: <InlineSpan>[
                    TextSpan(text: '${stats.running + stats.restarting} '),
                    TextSpan(
                      text: '/ ${stats.total}',
                      style: TextStyle(
                        fontWeight: FontWeight.w400,
                        color: t.mutedText,
                      ),
                    ),
                  ],
                ),
                style: AppText.rowTitle.copyWith(color: t.text),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _Meter(
            label: 'CPU ${stats.cpuPercent.round()}%',
            value: stats.cpuPercent / 100,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _Meter(
            label: 'Memory ${(stats.memoryFraction * 100).round()}%',
            value: stats.memoryFraction,
          ),
        ),
      ],
    );
  }
}

class _Meter extends StatelessWidget {
  const _Meter({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label, style: AppText.tiny.copyWith(color: t.mutedText)),
        const SizedBox(height: 13),
        MeterBar(value),
      ],
    );
  }
}
