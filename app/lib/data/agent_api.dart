import 'exec_session.dart';
import 'models.dart';

/// One instance per paired server. Mirrors `docs/agent-api.md` v1.1.
///
/// Every method maps onto exactly one endpoint; the doc comment names it.
/// Methods that the agent can refuse with `428 confirmation_required` take
/// `confirmed`, which becomes the `X-Confirmed` header: `biometric` after a
/// real biometric prompt, `typed` after the person typed the target's name on
/// a device with no biometrics. [Confirmed.none] sends no header at all.
/// The "Refresh stats every" default, so every implementation and every test
/// agrees on it without importing the preferences.
const Duration kDefaultStatsInterval = Duration(seconds: 5);

abstract class AgentApi {
  /// `GET /health` — unauthenticated.
  Future<bool> health();

  /// `GET /me` — added by Revision 1.1. `null` when the agent answers `404`,
  /// so an older build falls back to the cached pairing data.
  Future<MeInfo?> me();

  /// `GET /system`
  Future<SystemInfo> system();

  /// `GET /system/stats`
  Future<SystemStats> systemStats();

  /// `GET /system/stats/stream`
  ///
  /// [interval] is the "Refresh stats every" preference. The agent's SSE
  /// stream has no rate of its own to ask for, so a client that cannot set it
  /// throttles what it forwards instead; the mock simply emits at that rate.
  Stream<SystemStats> systemStatsStream({
    Duration interval = kDefaultStatsInterval,
  });

  /// `GET /events/stream`
  Stream<DockerEvent> dockerEvents();

  /// `GET /activity`
  Future<List<ActivityEntry>> activity({String? actor, DateTime? since});

  /// `GET /containers?state=&stack=&q=`
  Future<List<ContainerSummary>> containers({
    ContainerState? state,
    String? stack,
    String? query,
  });

  /// `GET /containers/{id}`
  Future<ContainerDetail> container(String id);

  /// `GET /containers/{id}/env` — admin only, always audited.
  Future<Map<String, String>> containerEnv(String id);

  /// `GET /containers/{id}/stats/stream` — [interval] as in
  /// [systemStatsStream].
  Stream<ContainerStats> containerStatsStream(
    String id, {
    Duration interval = kDefaultStatsInterval,
  });

  /// `POST /containers/{id}/start`
  Future<void> startContainer(String id);

  /// `POST /containers/{id}/stop?timeout=` — risky.
  Future<void> stopContainer(
    String id, {
    int timeout = 10,
    Confirmed confirmed = Confirmed.none,
  });

  /// `POST /containers/{id}/restart?timeout=`
  Future<void> restartContainer(String id, {int timeout = 10});

  /// `POST /containers/{id}/pause` and `/unpause`
  Future<void> pauseContainer(String id, {required bool paused});

  /// `DELETE /containers/{id}?force=&volumes=` — risky, admin only.
  Future<void> removeContainer(
    String id, {
    bool force = false,
    bool volumes = false,
    Confirmed confirmed = Confirmed.none,
  });

  /// `GET /containers/{id}/impact`
  Future<ContainerImpact> containerImpact(String id);

  /// `GET /containers/{id}/logs?tail=&q=`
  Future<List<LogLine>> logs(String id, {int tail = 200, String? query});

  /// `GET /containers/{id}/logs/stream`
  Stream<LogLine> logStream(String id);

  /// `WS /containers/{id}/exec?shell=&cols=&rows=` — admin only, audited.
  Future<ExecSession> exec(
    String id, {
    String? shell,
    int cols = 80,
    int rows = 24,
  });

  /// `GET /stacks`
  Future<List<ComposeStack>> stacks();

  /// `POST /stacks/{name}/up` — job.
  Future<Job> stackUp(String name);

  /// `POST /stacks/{name}/redeploy` — job.
  Future<Job> stackRedeploy(String name);

  /// `POST /stacks/{name}/restart` — job.
  Future<Job> stackRestart(String name);

  /// `POST /stacks/{name}/down` — risky, admin only, job.
  Future<Job> stackDown(String name, {Confirmed confirmed = Confirmed.none});

  /// `GET /swarm` — always `200`, with `active: false` off a Swarm.
  Future<SwarmInfo> swarm();

  /// `GET /services` — `409 not_a_manager` when this host is not a manager.
  Future<List<SwarmService>> services();

  /// `POST /services/{id}/scale` — synchronous.
  Future<void> scaleService(String id, int replicas);

  /// `POST /services/{id}/update` — job.
  Future<Job> updateService(String id, {String? image, bool force = false});

  /// `POST /services/{id}/rollback` — job.
  Future<Job> rollbackService(String id);

  /// `GET /images`
  Future<ImageList> images();

  /// `POST /images/pull` — job with layer progress.
  Future<Job> pullImage(String ref);

  /// `DELETE /images/{id}?force=` — risky, admin only.
  Future<void> removeImage(
    String id, {
    bool force = false,
    Confirmed confirmed = Confirmed.none,
  });

  /// `POST /images/prune` — risky, admin only, job.
  Future<Job> pruneImages({
    bool danglingOnly = true,
    Confirmed confirmed = Confirmed.none,
  });

  /// `GET /volumes`
  Future<VolumeList> volumes();

  /// `POST /volumes` — admin only.
  Future<void> createVolume(String name, {String driver = 'local'});

  /// `DELETE /volumes/{name}` — risky, admin only.
  Future<void> removeVolume(
    String name, {
    Confirmed confirmed = Confirmed.none,
  });

  /// `POST /volumes/prune` — risky, admin only, job.
  Future<Job> pruneVolumes({Confirmed confirmed = Confirmed.none});

  /// `GET /networks`
  Future<NetworkList> networks();

  /// `POST /networks` — admin only.
  Future<void> createNetwork(
    String name, {
    String driver = 'bridge',
    String? subnet,
  });

  /// `DELETE /networks/{id}` — risky, admin only.
  Future<void> removeNetwork(String id, {Confirmed confirmed = Confirmed.none});

  /// `POST /networks/prune` — risky, admin only, job.
  Future<Job> pruneNetworks({Confirmed confirmed = Confirmed.none});

  /// `GET /alerts?state=`
  Future<List<AlertInfo>> alerts({AlertState? state});

  /// `POST /alerts/{id}/mute`
  Future<void> muteAlert(String id, {int minutes = 60});

  /// `POST /alerts/{id}/resolve`
  Future<void> resolveAlert(String id);

  /// `GET /alert-rules`
  Future<List<AlertRule>> alertRules();

  /// `PATCH /alert-rules/{id}` — admin only.
  Future<void> updateAlertRule(
    String id, {
    bool? enabled,
    double? threshold,
    int? windowSeconds,
  });

  /// `GET /registries`
  Future<List<RegistryInfo>> registries();

  /// `POST /registries` — admin only.
  Future<void> addRegistry({
    required String host,
    required String username,
    required String secret,
  });

  /// `PATCH /registries/{id}` — admin only.
  Future<void> updateRegistry(String id, {String? username, String? secret});

  /// `POST /registries/{id}/test` — admin only.
  Future<bool> testRegistry(String id);

  /// `DELETE /registries/{id}` — admin only.
  Future<void> removeRegistry(String id);

  /// `GET /settings`
  Future<AgentSettings> settings();

  /// `PATCH /settings` — admin only.
  Future<AgentSettings> updateSettings({bool? requireBiometricForRisky});

  /// `GET /devices`
  Future<List<DeviceInfo>> devices();

  /// `PATCH /devices/{id}` — admin only. `409` on the last admin.
  Future<DeviceInfo> updateDevice(
    String id, {
    ServerRole? role,
    String? pushToken,
  });

  /// `DELETE /devices/{id}` — risky, admin only. Your own device unpairs.
  Future<void> removeDevice(String id, {Confirmed confirmed = Confirmed.none});

  /// `GET /agent/update`
  Future<AgentUpdate> agentUpdate();

  /// `POST /agent/update` — job; the connection is expected to drop.
  Future<Job> startAgentUpdate();

  /// `GET /jobs/{id}`
  Future<Job> job(String id);

  /// `GET /jobs/{id}/events`, falling back to polling `GET /jobs/{id}`.
  Stream<Job> jobEvents(String id);

  /// Releases sockets held by this client. Called when a server is unpaired.
  void dispose();
}
