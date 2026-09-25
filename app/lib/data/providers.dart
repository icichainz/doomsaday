import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'agent_api.dart';
import 'biometrics.dart';
import 'models.dart';
import 'preferences.dart';
import 'servers_repository.dart';

/// Demo mode by default, so tests and the widget harness get the three seeded
/// worlds. `main()` overrides it with a repository backed by real storage.
final serversRepositoryProvider = Provider<ServersRepository>(
  (ref) => ServersRepository(),
);

/// Overridden in `main()` with the real `local_auth` prompt.
final authenticatorProvider = Provider<Authenticator>(
  (ref) => const AlwaysConfirms(),
);

final agentApiProvider = Provider.family<AgentApi, String>(
  (ref, serverId) => ref.watch(serversRepositoryProvider).api(serverId),
);

final serverProvider = Provider.family<Server, String>(
  (ref, serverId) => ref.watch(serversRepositoryProvider).server(serverId),
);

final serverCardsProvider = FutureProvider<List<ServerCard>>(
  (ref) => ref.watch(serversRepositoryProvider).cards(),
);

/// Demo mode, as one piece of state the whole app shares.
///
/// The repository knows whether it is sampling, but it is a plain object and
/// cannot tell anyone when that changes. This is the seam: "Explore with demo
/// data", "Leave demo" and the Preferences switch all go through here, so the
/// Servers screen and Preferences can never show different answers.
class DemoModeController extends StateNotifier<bool> {
  DemoModeController(this._ref)
    : super(_ref.read(serversRepositoryProvider).isDemo);

  final Ref _ref;

  Future<void> set(bool on) async {
    final ServersRepository repo = _ref.read(serversRepositoryProvider);
    if (on) {
      await repo.enterDemoMode();
    } else {
      await repo.leaveDemoMode();
    }
    state = repo.isDemo;
    _ref.invalidate(serverCardsProvider);
  }
}

final demoModeProvider = StateNotifierProvider<DemoModeController, bool>(
  (ref) => DemoModeController(ref),
);

/// `GET /me`, with the cached pairing data as the fallback when the agent is
/// older than Revision 1.1 and answers `404`.
final meProvider = FutureProvider.family<MeInfo?, String>((
  ref,
  serverId,
) async {
  final ServersRepository repo = ref.watch(serversRepositoryProvider);
  final MeInfo? me = await repo.api(serverId).me();
  if (me != null) await repo.refreshIdentity(serverId);
  return me;
});

/// The role this phone should hide buttons for: `/me` when the agent reports
/// it, the pinned role from pairing otherwise.
final roleProvider = Provider.family<ServerRole, String>((ref, serverId) {
  final MeInfo? me = ref.watch(meProvider(serverId)).valueOrNull;
  return me?.role ?? ref.watch(serverProvider(serverId)).role;
});

final systemProvider = FutureProvider.family<SystemInfo, String>(
  (ref, serverId) => ref.watch(agentApiProvider(serverId)).system(),
);

/// "Refresh stats every", as a [Duration], for every live figure in the app.
final statsIntervalProvider = Provider<Duration>(
  (ref) => ref
      .watch(preferencesProvider.select((Preferences p) => p.statsInterval))
      .duration,
);

final systemStatsProvider = StreamProvider.autoDispose
    .family<SystemStats, String>(
      (ref, serverId) => ref
          .watch(agentApiProvider(serverId))
          .systemStatsStream(interval: ref.watch(statsIntervalProvider)),
    );

final activityProvider = FutureProvider.family<List<ActivityEntry>, String>(
  (ref, serverId) => ref.watch(agentApiProvider(serverId)).activity(),
);

/// The three chips on the Containers screen. The list is fetched once and
/// filtered here, because "Running" means running **and** restarting, which no
/// single `?state=` value expresses.
enum ContainerFilter {
  all('All'),
  running('Running'),
  stopped('Stopped');

  const ContainerFilter(this.label);

  final String label;

  bool matches(ContainerSummary c) => switch (this) {
    ContainerFilter.all => true,
    ContainerFilter.running => c.state.isRunning,
    ContainerFilter.stopped => !c.state.isRunning,
  };
}

final containersProvider =
    FutureProvider.family<List<ContainerSummary>, String>(
      (ref, serverId) => ref.watch(agentApiProvider(serverId)).containers(),
    );

typedef ContainerKey = ({String serverId, String containerId});

final containerDetailProvider =
    FutureProvider.family<ContainerDetail, ContainerKey>(
      (ref, key) =>
          ref.watch(agentApiProvider(key.serverId)).container(key.containerId),
    );

final containerStatsProvider = StreamProvider.autoDispose
    .family<ContainerStats, ContainerKey>(
      (ref, key) => ref
          .watch(agentApiProvider(key.serverId))
          .containerStatsStream(
            key.containerId,
            interval: ref.watch(statsIntervalProvider),
          ),
    );

final stacksProvider = FutureProvider.family<List<ComposeStack>, String>(
  (ref, serverId) => ref.watch(agentApiProvider(serverId)).stacks(),
);

final swarmProvider = FutureProvider.family<SwarmInfo, String>(
  (ref, serverId) => ref.watch(agentApiProvider(serverId)).swarm(),
);

final servicesProvider = FutureProvider.family<List<SwarmService>, String>(
  (ref, serverId) => ref.watch(agentApiProvider(serverId)).services(),
);

final imagesProvider = FutureProvider.family<ImageList, String>(
  (ref, serverId) => ref.watch(agentApiProvider(serverId)).images(),
);

final volumesProvider = FutureProvider.family<VolumeList, String>(
  (ref, serverId) => ref.watch(agentApiProvider(serverId)).volumes(),
);

final networksProvider = FutureProvider.family<NetworkList, String>(
  (ref, serverId) => ref.watch(agentApiProvider(serverId)).networks(),
);

final alertsProvider = FutureProvider.family<List<AlertInfo>, String>(
  (ref, serverId) => ref.watch(agentApiProvider(serverId)).alerts(),
);

final alertRulesProvider = FutureProvider.family<List<AlertRule>, String>(
  (ref, serverId) => ref.watch(agentApiProvider(serverId)).alertRules(),
);

final registriesProvider = FutureProvider.family<List<RegistryInfo>, String>(
  (ref, serverId) => ref.watch(agentApiProvider(serverId)).registries(),
);

final agentSettingsProvider = FutureProvider.family<AgentSettings, String>(
  (ref, serverId) => ref.watch(agentApiProvider(serverId)).settings(),
);

final agentUpdateProvider = FutureProvider.family<AgentUpdate, String>(
  (ref, serverId) => ref.watch(agentApiProvider(serverId)).agentUpdate(),
);

final devicesProvider = FutureProvider.family<List<DeviceInfo>, String>(
  (ref, serverId) => ref.watch(agentApiProvider(serverId)).devices(),
);

/// Called after a mutation so every list that could have changed refetches.
void refreshServer(WidgetRef ref) {
  ref.invalidate(serverCardsProvider);
  ref.invalidate(systemStatsProvider);
  ref.invalidate(containersProvider);
  ref.invalidate(containerDetailProvider);
  ref.invalidate(stacksProvider);
  ref.invalidate(servicesProvider);
  ref.invalidate(imagesProvider);
  ref.invalidate(volumesProvider);
  ref.invalidate(networksProvider);
  ref.invalidate(alertsProvider);
  ref.invalidate(activityProvider);
}
