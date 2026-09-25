/// D5: one picture of every paired server.
///
/// Each agent is asked concurrently and independently, so a server that is
/// down or refusing contributes an offline row and never stops the others.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/agent_api.dart';
import '../../data/models.dart';
import '../../data/providers.dart';
import '../../data/servers_repository.dart';

/// One container, and the server it runs on.
class FleetContainer {
  const FleetContainer({required this.server, required this.container});

  final Server server;
  final ContainerSummary container;
}

/// One alert, and the server that raised it.
class FleetAlert {
  const FleetAlert({required this.server, required this.alert});

  final Server server;
  final AlertInfo alert;
}

/// What one agent answered, or why it did not.
class FleetServer {
  const FleetServer({
    required this.server,
    required this.online,
    this.reason,
    this.containers = const <ContainerSummary>[],
    this.alerts = const <AlertInfo>[],
    this.reclaimableBytes = 0,
  });

  final Server server;
  final bool online;
  final String? reason;
  final List<ContainerSummary> containers;
  final List<AlertInfo> alerts;
  final int reclaimableBytes;
}

class FleetSnapshot {
  const FleetSnapshot(this.servers);

  final List<FleetServer> servers;

  int get total => servers.length;
  int get online => servers.where((FleetServer s) => s.online).length;

  List<FleetServer> get offline =>
      servers.where((FleetServer s) => !s.online).toList(growable: false);

  List<FleetContainer> get containers => <FleetContainer>[
    for (final FleetServer s in servers)
      for (final ContainerSummary c in s.containers)
        FleetContainer(server: s.server, container: c),
  ];

  List<FleetAlert> get alerts => <FleetAlert>[
    for (final FleetServer s in servers)
      for (final AlertInfo a in s.alerts)
        if (a.state == AlertState.active)
          FleetAlert(server: s.server, alert: a),
  ];

  int get running => containers
      .where((FleetContainer c) => c.container.state == ContainerState.running)
      .length;

  int get restarting => containers
      .where(
        (FleetContainer c) => c.container.state == ContainerState.restarting,
      )
      .length;

  int get stopped => containers
      .where((FleetContainer c) => !c.container.state.isRunning)
      .length;

  int get criticalAlerts => alerts
      .where((FleetAlert a) => a.alert.severity == AlertSeverity.critical)
      .length;

  int get reclaimableBytes =>
      servers.fold(0, (int a, FleetServer s) => a + s.reclaimableBytes);

  /// The server with the most reclaimable image bytes, for the D5 card.
  String? get reclaimableOn {
    FleetServer? best;
    for (final FleetServer s in servers) {
      if (s.reclaimableBytes > (best?.reclaimableBytes ?? 0)) best = s;
    }
    return best?.server.name;
  }
}

/// Ticks at the "Refresh stats every" rate.
///
/// The fleet is the one live view built from plain requests rather than an SSE
/// stream — every agent is asked at once — so this is what gives it the same
/// refresh rate as the Overview's stream.
///
/// The timer is owned outright and cancelled the moment nothing is watching
/// the fleet: a `Stream.periodic` keeps re-arming itself past the end of
/// whatever was listening, which leaves a timer running after the screen is
/// gone.
final _fleetTickProvider = StreamProvider.autoDispose<int>((ref) {
  final Duration every = ref.watch(statsIntervalProvider);
  final StreamController<int> ticks = StreamController<int>();
  int tick = 0;
  final Timer timer = Timer.periodic(every, (_) => ticks.add(++tick));
  ref.onDispose(() {
    timer.cancel();
    ticks.close();
  });
  return ticks.stream;
});

final fleetProvider = FutureProvider.autoDispose<FleetSnapshot>((ref) async {
  // Recomputes on every tick. `AsyncValue.when` skips loading on a refresh, so
  // the cards keep their figures instead of flashing a skeleton.
  ref.watch(_fleetTickProvider);
  // Entering or leaving demo data changes what "every server" means.
  ref.watch(demoModeProvider);
  final ServersRepository repo = ref.watch(serversRepositoryProvider);
  await repo.ensureLoaded();
  final List<FleetServer> results = await Future.wait(
    repo.servers.map((Server server) => _read(repo, server)),
  );
  return FleetSnapshot(results);
});

Future<FleetServer> _read(ServersRepository repo, Server server) async {
  final AgentApi api = repo.api(server.id);
  try {
    if (!await api.health()) {
      return FleetServer(
        server: server,
        online: false,
        reason: repo.offlineReasonFor(server.id) ?? 'The agent did not answer.',
      );
    }
    final List<Object> answers = await Future.wait(<Future<Object>>[
      api.containers(),
      api.alerts(),
      api.images(),
    ]);
    return FleetServer(
      server: server,
      online: true,
      containers: answers[0] as List<ContainerSummary>,
      alerts: answers[1] as List<AlertInfo>,
      reclaimableBytes: (answers[2] as ImageList).reclaimableBytes,
    );
  } on AgentException catch (error) {
    return FleetServer(server: server, online: false, reason: error.message);
  }
}
