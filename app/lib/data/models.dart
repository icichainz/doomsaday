/// Data model layer.
///
/// Field names follow `docs/agent-api.md` and, where that document is silent,
/// `agent_zero/API_NOTES.md`, so the JSON the real agent returns maps onto
/// these classes one for one. Revision 1.1 settles that the agent sends raw
/// values only; every display string is derived here or in `format.dart`.
library;

import 'format.dart';

export 'format.dart';

// --------------------------------------------------------------- json helpers

String _str(Object? value, [String fallback = '']) =>
    value is String ? value : fallback;

int _int(Object? value, [int fallback = 0]) => switch (value) {
  final int v => v,
  final double v => v.round(),
  final String v => int.tryParse(v) ?? fallback,
  _ => fallback,
};

double _double(Object? value, [double fallback = 0]) => switch (value) {
  final double v => v,
  final int v => v.toDouble(),
  final String v => double.tryParse(v) ?? fallback,
  _ => fallback,
};

bool _bool(Object? value, [bool fallback = false]) =>
    value is bool ? value : fallback;

DateTime? _timeOrNull(Object? value) {
  if (value is! String || value.isEmpty) return null;
  final DateTime? parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  // Go marshals a zero time.Time as year 1; treat that as absent.
  return parsed.year < 1970 ? null : parsed.toLocal();
}

DateTime _time(Object? value) => _timeOrNull(value) ?? DateTime.now();

List<String> _strings(Object? value) => value is List
    ? value.whereType<String>().toList(growable: false)
    : const <String>[];

List<Map<String, Object?>> _objects(Object? value) => value is List
    ? value.whereType<Map<String, Object?>>().toList(growable: false)
    : const <Map<String, Object?>>[];

// ------------------------------------------------------------------- errors

/// `{"error": {"code": ..., "message": ..., "details": {}}}` from the agent.
class AgentException implements Exception {
  const AgentException(
    this.code,
    this.message, {
    this.status,
    this.details,
    this.retryAfter,
  });

  final String code;
  final String message;
  final int? status;
  final Map<String, Object?>? details;

  /// `429 rate_limited` carries `Retry-After`, which the screens surface.
  final Duration? retryAfter;

  factory AgentException.fromJson(
    Map<String, Object?> json, {
    int? status,
    Duration? retryAfter,
  }) {
    final Object? error = json['error'];
    if (error is Map<String, Object?>) {
      return AgentException(
        _str(error['code'], 'internal_error'),
        _str(error['message'], 'The agent returned an error.'),
        status: status,
        details: error['details'] is Map<String, Object?>
            ? error['details'] as Map<String, Object?>
            : null,
        retryAfter: retryAfter,
      );
    }
    return AgentException(
      'internal_error',
      'The agent returned an unexpected response.',
      status: status,
      retryAfter: retryAfter,
    );
  }

  /// The agent could not be reached at all, so the screen shows a retry.
  bool get isUnreachable =>
      code == 'agent_unreachable' ||
      code == 'docker_unavailable' ||
      status == 502;

  /// The agent asked for `X-Confirmed: biometric` before it will act.
  bool get needsConfirmation =>
      status == 428 || code == 'confirmation_required';

  /// This host is not a Swarm manager, which is an empty state, not a failure.
  bool get isNotAManager => code == 'not_a_manager';

  @override
  String toString() => retryAfter == null
      ? message
      : '$message Try again in ${formatShortDuration(retryAfter!)}.';
}

// ------------------------------------------------------------- confirmation

/// How the person confirmed a risky action, which is exactly what the
/// `X-Confirmed` header carries.
///
/// [none] sends no header at all, so the agent's `428` rule still protects the
/// action after a cancelled or failed prompt. [biometric] is only ever reached
/// after a real `local_auth` prompt passed on this device; [typed] is the
/// desktop fallback where the person typed the target's name exactly.
enum Confirmed {
  none,
  biometric,
  typed;

  /// The header value, or `null` when nothing may be sent.
  String? get header => switch (this) {
    Confirmed.none => null,
    Confirmed.biometric => 'biometric',
    Confirmed.typed => 'typed',
  };

  bool get isConfirmed => this != Confirmed.none;
}

// -------------------------------------------------------------------- roles

/// Device role. The agent enforces this; the app only hides buttons.
///
/// The map is "Revision 1.1 › Roles" in `docs/agent-api.md`.
enum ServerRole {
  admin,
  operator,
  viewer;

  static ServerRole parse(String value) => ServerRole.values.firstWhere(
    (ServerRole r) => r.name == value,
    orElse: () => ServerRole.viewer,
  );

  String get label => switch (this) {
    ServerRole.admin => 'Admin',
    ServerRole.operator => 'Operator',
    ServerRole.viewer => 'Viewer',
  };

  bool get isAdmin => this == ServerRole.admin;

  /// Operator and admin: container start, stop, restart, pause and unpause,
  /// stack up, redeploy and restart, image pull, service scale, update and
  /// rollback, alert mute and resolve.
  bool get canOperate => this != ServerRole.viewer;

  /// Admin only: remove, exec, environment values, stack down, every prune,
  /// image, volume and network create and remove, devices, registries,
  /// settings, alert rules, agent update.
  bool get canRemove => isAdmin;
  bool get canPrune => isAdmin;
  bool get canCreateResources => isAdmin;
  bool get canExec => isAdmin;
  bool get canReadEnvironment => isAdmin;
  bool get canStackDown => isAdmin;
  bool get canManageDevices => isAdmin;
  bool get canManageRegistries => isAdmin;
  bool get canEditSettings => isAdmin;
  bool get canEditAlertRules => isAdmin;
  bool get canUpdateAgent => isAdmin;
}

// ------------------------------------------------------------------ servers

/// One paired agent as the phone knows it.
///
/// Stored in `shared_preferences` (the device key lives in secure storage), so
/// this is the only model without an endpoint behind it.
class Server {
  const Server({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.certFingerprint,
    required this.deviceId,
    required this.role,
  });

  final String id;
  final String name;

  /// `https://agent.example.com:8443` — no `/v1`, that is added per request.
  final String baseUrl;
  final String certFingerprint;

  /// This phone's device id on that agent, needed by `PATCH`/`DELETE /devices`.
  final String deviceId;
  final ServerRole role;

  /// `agent.example.com:8443`, as shown under the server name.
  String get host => Uri.tryParse(baseUrl)?.authority ?? baseUrl;

  Server copyWith({String? name, String? deviceId, ServerRole? role}) => Server(
    id: id,
    name: name ?? this.name,
    baseUrl: baseUrl,
    certFingerprint: certFingerprint,
    deviceId: deviceId ?? this.deviceId,
    role: role ?? this.role,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'fingerprint': certFingerprint,
    'deviceId': deviceId,
    'role': role.name,
  };

  factory Server.fromJson(Map<String, Object?> json) => Server(
    id: _str(json['id']),
    name: _str(json['name']),
    baseUrl: _str(json['baseUrl']),
    certFingerprint: _str(json['fingerprint']),
    deviceId: _str(json['deviceId']),
    role: ServerRole.parse(_str(json['role'], 'viewer')),
  );
}

/// The card figures on the Servers screen, plus the offline reason.
class ServerCard {
  const ServerCard({
    required this.server,
    required this.online,
    this.info,
    this.stats,
    this.offlineReason,
  });

  final Server server;
  final bool online;
  final SystemInfo? info;
  final SystemStats? stats;
  final String? offlineReason;
}

/// `GET /me` — added by Revision 1.1 "Still open" item 1. Optional at runtime:
/// an agent that answers `404` leaves the app on its cached pairing data.
class MeInfo {
  const MeInfo({
    required this.deviceId,
    required this.deviceName,
    required this.role,
    required this.certFingerprint,
    required this.pairedDevices,
    required this.agentVersion,
  });

  final String deviceId;
  final String deviceName;
  final ServerRole role;
  final String certFingerprint;
  final int pairedDevices;
  final String agentVersion;

  factory MeInfo.fromJson(Map<String, Object?> json) => MeInfo(
    deviceId: _str(json['device_id']),
    deviceName: _str(json['device_name']),
    role: ServerRole.parse(_str(json['role'], 'viewer')),
    certFingerprint: _str(json['cert_fingerprint']),
    pairedDevices: _int(json['paired_devices']),
    agentVersion: _str(json['agent_version']),
  );
}

// ------------------------------------------------------------------- system

/// `GET /system`
class SystemInfo {
  const SystemInfo({
    required this.hostname,
    required this.dockerVersion,
    required this.agentVersion,
    required this.cpuCores,
    required this.memoryTotalBytes,
    required this.diskTotalBytes,
    required this.diskUsedBytes,
    required this.swarmRole,
    required this.agentUptimeSeconds,
    required this.hostUptimeSeconds,
    this.os = '',
    this.arch = '',
    this.certFingerprint = '',
  });

  final String hostname;
  final String dockerVersion;
  final String agentVersion;
  final int cpuCores;
  final int memoryTotalBytes;
  final int diskTotalBytes;
  final int diskUsedBytes;

  /// `manager`, `worker` or `inactive`.
  final String swarmRole;

  /// API_NOTES §8: "uptime" is two numbers, and the host one is 0 off Linux.
  final int agentUptimeSeconds;
  final int hostUptimeSeconds;

  final String os;
  final String arch;
  final String certFingerprint;

  /// Host uptime when the agent could read it, otherwise the agent's own.
  Duration get uptime => Duration(
    seconds: hostUptimeSeconds > 0 ? hostUptimeSeconds : agentUptimeSeconds,
  );

  /// True when only the agent's own uptime is known, which the UI says out loud.
  bool get uptimeIsAgentOnly => hostUptimeSeconds <= 0;

  factory SystemInfo.fromJson(Map<String, Object?> json) => SystemInfo(
    hostname: _str(json['hostname']),
    dockerVersion: _str(json['docker_version']),
    agentVersion: _str(json['agent_version']),
    cpuCores: _int(json['cpu_cores']),
    memoryTotalBytes: _int(json['memory_total']),
    diskTotalBytes: _int(json['disk_total']),
    diskUsedBytes: _int(json['disk_used']),
    swarmRole: _str(json['swarm_role'], 'inactive'),
    agentUptimeSeconds: _int(json['agent_uptime_seconds']),
    hostUptimeSeconds: _int(json['host_uptime_seconds']),
    os: _str(json['os']),
    arch: _str(json['arch']),
    certFingerprint: _str(json['cert_fingerprint']),
  );
}

/// The `containers` block of `GET /system/stats`, as separate numbers.
class ContainerCounts {
  const ContainerCounts({
    this.running = 0,
    this.exited = 0,
    this.paused = 0,
    this.restarting = 0,
    this.created = 0,
    this.total = 0,
  });

  final int running;
  final int exited;
  final int paused;
  final int restarting;
  final int created;
  final int total;

  /// The Servers card and the Running chip show running + restarting.
  int get up => running + restarting;

  /// Everything the design calls "stopped".
  int get stopped => exited + paused + created;

  ContainerCounts copyWith({
    int? running,
    int? exited,
    int? paused,
    int? restarting,
    int? created,
    int? total,
  }) => ContainerCounts(
    running: running ?? this.running,
    exited: exited ?? this.exited,
    paused: paused ?? this.paused,
    restarting: restarting ?? this.restarting,
    created: created ?? this.created,
    total: total ?? this.total,
  );

  factory ContainerCounts.fromJson(Map<String, Object?> json) =>
      ContainerCounts(
        running: _int(json['running']),
        exited: _int(json['exited']),
        paused: _int(json['paused']),
        restarting: _int(json['restarting']),
        created: _int(json['created']),
        total: _int(json['total']),
      );
}

/// `GET /system/stats` and the SSE stream behind it.
class SystemStats {
  const SystemStats({
    required this.cpuPercent,
    required this.memoryUsedBytes,
    required this.memoryTotalBytes,
    required this.diskUsedBytes,
    required this.diskTotalBytes,
    required this.containers,
    this.cpuSource = 'host',
    this.memorySource = 'host',
    this.activeAlerts = 0,
  });

  final double cpuPercent;
  final int memoryUsedBytes;
  final int memoryTotalBytes;
  final int diskUsedBytes;
  final int diskTotalBytes;
  final ContainerCounts containers;

  /// API_NOTES §9: `host` or `containers`, so an approximation says so.
  final String cpuSource;
  final String memorySource;
  final int activeAlerts;

  bool get figuresAreApproximate =>
      cpuSource != 'host' || memorySource != 'host';

  int get running => containers.running;
  int get restarting => containers.restarting;
  int get stopped => containers.stopped;
  int get total => containers.total;

  double get memoryFraction =>
      memoryTotalBytes <= 0 ? 0 : memoryUsedBytes / memoryTotalBytes;
  double get diskFraction =>
      diskTotalBytes <= 0 ? 0 : diskUsedBytes / diskTotalBytes;

  SystemStats copyWith({
    double? cpuPercent,
    int? memoryUsedBytes,
    int? diskUsedBytes,
    ContainerCounts? containers,
  }) => SystemStats(
    cpuPercent: cpuPercent ?? this.cpuPercent,
    memoryUsedBytes: memoryUsedBytes ?? this.memoryUsedBytes,
    memoryTotalBytes: memoryTotalBytes,
    diskUsedBytes: diskUsedBytes ?? this.diskUsedBytes,
    diskTotalBytes: diskTotalBytes,
    containers: containers ?? this.containers,
    cpuSource: cpuSource,
    memorySource: memorySource,
    activeAlerts: activeAlerts,
  );

  factory SystemStats.fromJson(Map<String, Object?> json) => SystemStats(
    cpuPercent: _double(json['cpu_percent']),
    memoryUsedBytes: _int(json['memory_used']),
    memoryTotalBytes: _int(json['memory_total']),
    diskUsedBytes: _int(json['disk_used']),
    diskTotalBytes: _int(json['disk_total']),
    containers: json['containers'] is Map<String, Object?>
        ? ContainerCounts.fromJson(json['containers']! as Map<String, Object?>)
        : const ContainerCounts(),
    cpuSource: _str(json['cpu_source'], 'host'),
    memorySource: _str(json['memory_source'], 'host'),
    activeAlerts: _int(json['active_alerts']),
  );
}

/// `GET /activity` — one audit record (API_NOTES §32).
class ActivityEntry {
  const ActivityEntry({
    required this.id,
    required this.time,
    required this.action,
    required this.target,
    required this.result,
    this.deviceId = '',
    this.deviceName = '',
    this.role = '',
    this.status = 0,
    this.remoteIp = '',
  });

  final String id;
  final DateTime time;

  /// The matched route pattern, `POST /v1/containers/{id}/stop`.
  final String action;
  final String target;

  /// `ok`, `started`, `denied` or `error`.
  final String result;
  final String deviceId;
  final String deviceName;
  final String role;
  final int status;
  final String remoteIp;

  /// `09:42` today, `Tue` this week, `12 Mar` before that.
  String get at => formatActivityTime(time);

  bool get failed => result == 'denied' || result == 'error';

  /// The sentence the design writes: subject first, verb last, and the acting
  /// device only when there is one to name.
  ///
  /// `nginx-proxy restarted from this phone`, `Image redis:7.2 pulled`,
  /// `Stack monitoring redeployed`.
  ///
  /// [selfDeviceId] is this device's id on the agent; when the record carries
  /// it the sentence says "this Mac" or "this phone" rather than whatever the
  /// device was paired under.
  ///
  /// [withResult] adds ` · denied` or ` · error` to a refused call; a screen
  /// that draws the result as a pill turns it off.
  String sentence({
    String? selfDeviceId,
    String selfLabel = 'this device',
    bool withResult = true,
  }) {
    final StringBuffer out = StringBuffer(_phrase);
    final String who = _actor(selfDeviceId, selfLabel);
    if (who.isNotEmpty) out.write(' from $who');
    if (failed && withResult) out.write(' · $result');
    return out.toString();
  }

  /// The plain sentence, for screens that know nothing about this device.
  String get text => sentence();

  /// True when the record carries this device's id.
  bool isFrom(String? selfDeviceId) =>
      selfDeviceId != null &&
      selfDeviceId.isNotEmpty &&
      deviceId == selfDeviceId;

  String _actor(String? selfDeviceId, String selfLabel) {
    final bool isSelf =
        selfDeviceId != null &&
        selfDeviceId.isNotEmpty &&
        deviceId == selfDeviceId;
    if (isSelf) return selfLabel;
    return deviceName;
  }

  String get _phrase {
    final String name = target.isEmpty ? 'a container' : target;
    return switch (action) {
      'POST /v1/containers/{id}/start' => '$name started',
      'POST /v1/containers/{id}/stop' => '$name stopped',
      'POST /v1/containers/{id}/restart' => '$name restarted',
      'POST /v1/containers/{id}/pause' => '$name paused',
      'POST /v1/containers/{id}/unpause' => '$name unpaused',
      'DELETE /v1/containers/{id}' => 'Container $name removed',
      'GET /v1/containers/{id}/env' => 'Environment of $name read',
      'WS /v1/containers/{id}/exec' => 'Shell opened on $name',
      'WS /v1/containers/{id}/exec closed' => 'Shell on $name closed',
      'POST /v1/images/pull' => 'Image $name pulled',
      'DELETE /v1/images/{id}' => 'Image $name removed',
      'POST /v1/images/prune' => 'Images pruned',
      'POST /v1/volumes' => 'Volume $name created',
      'DELETE /v1/volumes/{name}' => 'Volume $name removed',
      'POST /v1/volumes/prune' => 'Volumes pruned',
      'POST /v1/networks' => 'Network $name created',
      'DELETE /v1/networks/{id}' => 'Network $name removed',
      'POST /v1/networks/prune' => 'Networks pruned',
      'POST /v1/stacks/{name}/up' => 'Stack $name started',
      'POST /v1/stacks/{name}/redeploy' => 'Stack $name redeployed',
      'POST /v1/stacks/{name}/restart' => 'Stack $name restarted',
      'POST /v1/stacks/{name}/down' => 'Stack $name brought down',
      'POST /v1/services/{id}/scale' => 'Service $name scaled',
      'POST /v1/services/{id}/update' => 'Service $name updated',
      'POST /v1/services/{id}/rollback' => 'Service $name rolled back',
      'POST /v1/alerts/{id}/mute' => 'Alert $name muted',
      'POST /v1/alerts/{id}/resolve' => 'Alert $name resolved',
      'PATCH /v1/alert-rules/{id}' => 'Alert rule $name changed',
      'POST /v1/registries' => 'Registry added',
      'PATCH /v1/registries/{id}' => 'Registry changed',
      'POST /v1/registries/{id}/test' => 'Registry login tested',
      'DELETE /v1/registries/{id}' => 'Registry removed',
      'PATCH /v1/settings' => 'Agent settings changed',
      'POST /v1/pair' => 'Device paired',
      'PATCH /v1/devices/{id}' => 'Device $name changed',
      'DELETE /v1/devices/{id}' => 'Device $name revoked',
      'POST /v1/agent/update' => 'Agent update started',
      _ => target.isEmpty ? action : '$action $target',
    };
  }

  factory ActivityEntry.fromJson(Map<String, Object?> json) => ActivityEntry(
    id: _str(json['id']),
    time: _time(json['time']),
    action: _str(json['action']),
    target: _str(json['target']),
    result: _str(json['result'], 'ok'),
    deviceId: _str(json['device_id']),
    deviceName: _str(json['device_name']),
    role: _str(json['role']),
    status: _int(json['status']),
    remoteIp: _str(json['remote_ip']),
  );
}

/// `GET /events/stream` — a Docker event, so lists refresh without polling.
class DockerEvent {
  const DockerEvent({
    required this.time,
    required this.type,
    required this.action,
    this.actorId = '',
    this.actorName = '',
  });

  final DateTime time;
  final String type;
  final String action;
  final String actorId;
  final String actorName;

  factory DockerEvent.fromJson(Map<String, Object?> json) => DockerEvent(
    time: _time(json['ts']),
    type: _str(json['type']),
    action: _str(json['action']),
    actorId: _str(json['actor_id']),
    actorName: _str(json['actor_name']),
  );
}

// --------------------------------------------------------------- containers

enum ContainerState {
  running,
  restarting,
  paused,
  created,
  exited,
  dead;

  static ContainerState parse(String value) => ContainerState.values.firstWhere(
    (ContainerState s) => s.name == value,
    orElse: () => ContainerState.exited,
  );

  bool get isRunning =>
      this == ContainerState.running || this == ContainerState.restarting;
}

/// One published or exposed port.
class PortMapping {
  const PortMapping({
    required this.privatePort,
    this.publicPort = 0,
    this.type = 'tcp',
    this.ip = '',
  });

  final int privatePort;
  final int publicPort;
  final String type;
  final String ip;

  bool get published => publicPort != 0;

  /// `8080 → 8080/tcp`, the way the detail screen writes it.
  String get label =>
      published ? '$publicPort → $privatePort/$type' : '$privatePort/$type';

  factory PortMapping.fromJson(Map<String, Object?> json) => PortMapping(
    privatePort: _int(json['private_port']),
    publicPort: _int(json['public_port']),
    type: _str(json['type'], 'tcp'),
    ip: _str(json['ip']),
  );
}

/// One mount point on a container.
class MountInfo {
  const MountInfo({
    required this.type,
    required this.destination,
    this.name = '',
    this.source = '',
    this.rw = true,
  });

  final String type;
  final String destination;
  final String name;
  final String source;
  final bool rw;

  String get label =>
      name.isNotEmpty ? name : (source.isNotEmpty ? source : destination);

  factory MountInfo.fromJson(Map<String, Object?> json) => MountInfo(
    type: _str(json['type']),
    destination: _str(json['destination']),
    name: _str(json['name']),
    source: _str(json['source']),
    rw: _bool(json['rw'], true),
  );
}

/// One network a container is joined to.
class NetworkAttachment {
  const NetworkAttachment({required this.name, this.ipAddress = ''});

  final String name;
  final String ipAddress;

  factory NetworkAttachment.fromJson(Map<String, Object?> json) =>
      NetworkAttachment(
        name: _str(json['name']),
        ipAddress: _str(json['ip_address']),
      );
}

/// `GET /containers` — raw values only; the row text is derived below.
class ContainerSummary {
  const ContainerSummary({
    required this.id,
    required this.name,
    required this.image,
    required this.state,
    required this.health,
    required this.createdAt,
    required this.uptimeSeconds,
    required this.restartCount,
    required this.exitCode,
    required this.cpuPercent,
    required this.memoryBytes,
    required this.stack,
    this.startedAt,
    this.finishedAt,
    this.memoryLimitBytes = 0,
    this.memoryPercent = 0,
    this.service = '',
    this.ports = const <PortMapping>[],
  });

  final String id;
  final String name;
  final String image;
  final ContainerState state;

  /// `healthy`, `unhealthy`, `starting` or empty when there is no health check.
  final String health;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final int uptimeSeconds;
  final int restartCount;
  final int exitCode;
  final double cpuPercent;
  final int memoryBytes;
  final int memoryLimitBytes;
  final double memoryPercent;
  final String stack;
  final String service;
  final List<PortMapping> ports;

  Duration get uptime => Duration(seconds: uptimeSeconds);

  /// `Up 12 days`, `Healthy`, `Restarting`, `Exited (1)` — what the row shows.
  String get stateLabel => switch (state) {
    ContainerState.running =>
      health == 'healthy' ? 'Healthy' : formatUptime(uptime),
    ContainerState.restarting => 'Restarting',
    ContainerState.paused => 'Paused',
    ContainerState.created => 'Created',
    ContainerState.exited || ContainerState.dead => 'Exited ($exitCode)',
  };

  /// The status pill on the detail screen and the desktop pane header:
  /// `Running · healthy` when the health check has spoken, otherwise the bare
  /// state. The uptime belongs in the list row, never in the pill.
  String get pillLabel => switch (state) {
    ContainerState.running => health.isEmpty ? 'Running' : 'Running · $health',
    ContainerState.restarting => 'Restarting',
    ContainerState.paused => 'Paused',
    ContainerState.created => 'Created',
    ContainerState.exited || ContainerState.dead => 'Exited ($exitCode)',
  };

  /// `0.4% · 38 MB`, `4 restarts`, `12 min ago`.
  String get meta => switch (state) {
    ContainerState.running =>
      '${formatPercent(cpuPercent)} · ${formatBytes(memoryBytes)}',
    ContainerState.restarting =>
      '$restartCount restart${restartCount == 1 ? '' : 's'}',
    _ => formatRelative(finishedAt ?? startedAt ?? createdAt),
  };

  ContainerSummary copyWith({
    ContainerState? state,
    String? health,
    DateTime? startedAt,
    DateTime? finishedAt,
    int? uptimeSeconds,
    int? restartCount,
    int? exitCode,
    double? cpuPercent,
    int? memoryBytes,
  }) => ContainerSummary(
    id: id,
    name: name,
    image: image,
    state: state ?? this.state,
    health: health ?? this.health,
    createdAt: createdAt,
    startedAt: startedAt ?? this.startedAt,
    finishedAt: finishedAt ?? this.finishedAt,
    uptimeSeconds: uptimeSeconds ?? this.uptimeSeconds,
    restartCount: restartCount ?? this.restartCount,
    exitCode: exitCode ?? this.exitCode,
    cpuPercent: cpuPercent ?? this.cpuPercent,
    memoryBytes: memoryBytes ?? this.memoryBytes,
    memoryLimitBytes: memoryLimitBytes,
    memoryPercent: memoryPercent,
    stack: stack,
    service: service,
    ports: ports,
  );

  factory ContainerSummary.fromJson(Map<String, Object?> json) =>
      ContainerSummary(
        id: _str(json['id']),
        name: _str(json['name']),
        image: _str(json['image']),
        state: ContainerState.parse(_str(json['state'], 'exited')),
        health: _str(json['health']),
        createdAt: _time(json['created_at']),
        startedAt: _timeOrNull(json['started_at']),
        finishedAt: _timeOrNull(json['finished_at']),
        uptimeSeconds: _int(json['uptime_seconds']),
        restartCount: _int(json['restart_count']),
        exitCode: _int(json['exit_code']),
        cpuPercent: _double(json['cpu_percent']),
        memoryBytes: _int(json['memory_usage']),
        memoryLimitBytes: _int(json['memory_limit']),
        memoryPercent: _double(json['memory_percent']),
        stack: _str(json['stack']),
        service: _str(json['service']),
        ports: _objects(
          json['ports'],
        ).map(PortMapping.fromJson).toList(growable: false),
      );
}

/// `GET /containers/{id}` — environment carries variable names only.
class ContainerDetail {
  const ContainerDetail({
    required this.summary,
    required this.networks,
    required this.mounts,
    required this.restartPolicy,
    required this.envNames,
    this.command = '',
    this.labels = const <String, String>{},
  });

  final ContainerSummary summary;
  final List<NetworkAttachment> networks;
  final List<MountInfo> mounts;
  final String restartPolicy;
  final List<String> envNames;
  final String command;
  final Map<String, String> labels;

  String get id => summary.id;
  String get name => summary.name;

  /// `8080 → 8080/tcp`
  List<String> get portLines =>
      summary.ports.map((PortMapping p) => p.label).toList(growable: false);

  String get networkNames => networks.isEmpty
      ? 'none'
      : networks.map((NetworkAttachment n) => n.name).join(', ');

  List<String> get mountNames =>
      mounts.map((MountInfo m) => m.label).toList(growable: false);

  factory ContainerDetail.fromJson(Map<String, Object?> json) {
    final Object? policy = json['restart_policy'];
    return ContainerDetail(
      summary: ContainerSummary.fromJson(json),
      networks: _objects(
        json['networks'],
      ).map(NetworkAttachment.fromJson).toList(growable: false),
      mounts: _objects(
        json['mounts'],
      ).map(MountInfo.fromJson).toList(growable: false),
      restartPolicy: policy is Map<String, Object?>
          ? _str(policy['name'], 'no')
          : 'no',
      envNames: _strings(json['env_names']),
      command: _str(json['command']),
      labels: json['labels'] is Map<String, Object?>
          ? <String, String>{
              for (final MapEntry<String, Object?> e
                  in (json['labels']! as Map<String, Object?>).entries)
                e.key: _str(e.value),
            }
          : const <String, String>{},
    );
  }
}

/// `GET /containers/{id}/stats/stream`
class ContainerStats {
  const ContainerStats({
    required this.cpuPercent,
    required this.memoryBytes,
    required this.memoryPercent,
    required this.netInBytesPerSecond,
    required this.netOutBytesPerSecond,
    this.memoryLimitBytes = 0,
  });

  final double cpuPercent;
  final int memoryBytes;
  final double memoryPercent;
  final int netInBytesPerSecond;
  final int netOutBytesPerSecond;
  final int memoryLimitBytes;

  double get memoryFraction => (memoryPercent / 100).clamp(0.0, 1.0);

  factory ContainerStats.fromJson(Map<String, Object?> json) => ContainerStats(
    cpuPercent: _double(json['cpu_percent']),
    memoryBytes: _int(json['memory_usage']),
    memoryPercent: _double(json['memory_percent']),
    netInBytesPerSecond: _double(json['net_rx_bytes_per_second']).round(),
    netOutBytesPerSecond: _double(json['net_tx_bytes_per_second']).round(),
    memoryLimitBytes: _int(json['memory_limit']),
  );
}

/// One container named by `GET /containers/{id}/impact`.
class ImpactRef {
  const ImpactRef({
    required this.id,
    required this.name,
    required this.state,
    this.reason = '',
  });

  final String id;
  final String name;
  final String state;
  final String reason;

  factory ImpactRef.fromJson(Map<String, Object?> json) => ImpactRef(
    id: _str(json['id']),
    name: _str(json['name']),
    state: _str(json['state']),
    reason: _str(json['reason']),
  );
}

/// `GET /containers/{id}/impact` — what the confirm sheet needs.
class ContainerImpact {
  const ContainerImpact({
    required this.publishedPorts,
    required this.dependents,
    required this.sameStack,
  });

  final List<PortMapping> publishedPorts;
  final List<ImpactRef> dependents;
  final List<ImpactRef> sameStack;

  List<String> get publishedPortLabels => publishedPorts
      .map((PortMapping p) => '${p.publicPort}')
      .toList(growable: false);

  /// `dependents` when the agent found any, otherwise the rest of the stack,
  /// which is what API_NOTES §13 says is the useful fallback.
  List<ImpactRef> get affected =>
      dependents.isNotEmpty ? dependents : sameStack;

  factory ContainerImpact.fromJson(Map<String, Object?> json) =>
      ContainerImpact(
        publishedPorts: _objects(
          json['published_ports'],
        ).map(PortMapping.fromJson).toList(growable: false),
        dependents: _objects(
          json['dependents'],
        ).map(ImpactRef.fromJson).toList(growable: false),
        sameStack: _objects(
          json['same_stack'],
        ).map(ImpactRef.fromJson).toList(growable: false),
      );
}

enum LogLevel { info, warn, error }

/// One line from `GET /containers/{id}/logs` or its SSE stream; both shapes
/// are `{ts, stream, line}` (API_NOTES §14).
class LogLine {
  const LogLine({required this.at, required this.stream, required this.line});

  final DateTime at;

  /// `stdout` or `stderr`.
  final String stream;
  final String line;

  /// Docker carries no level, so it is read off the stream and the text.
  LogLevel get level {
    if (stream != 'stderr') return LogLevel.info;
    final String lower = line.toLowerCase();
    const List<String> errors = <String>[
      'error',
      'err ',
      'fatal',
      'panic',
      'refused',
      'failed',
      'cannot',
      'exception',
    ];
    return errors.any(lower.contains) ? LogLevel.error : LogLevel.warn;
  }

  String get clock => formatClock(at);

  String get levelLabel => switch (level) {
    LogLevel.info => 'INFO',
    LogLevel.warn => 'WARN',
    LogLevel.error => 'ERR',
  };

  factory LogLine.fromJson(Map<String, Object?> json) => LogLine(
    at: _time(json['ts']),
    stream: _str(json['stream'], 'stdout'),
    line: _str(json['line']),
  );
}

// ------------------------------------------------------------------- stacks

/// One service inside a Compose project.
class StackService {
  const StackService({
    required this.name,
    required this.running,
    required this.total,
    this.restarting = 0,
  });

  final String name;
  final int running;
  final int total;

  /// Containers of this service that Docker reports as restarting. They are
  /// neither up nor down, and the health bar draws them amber rather than
  /// coral.
  final int restarting;

  ContainerState get state {
    if (total > 0 && running == total) return ContainerState.running;
    if (restarting > 0 || running > 0) return ContainerState.restarting;
    return ContainerState.exited;
  }

  factory StackService.fromJson(Map<String, Object?> json) => StackService(
    name: _str(json['name']),
    running: _int(json['running']),
    total: _int(json['total']),
    restarting: _int(json['restarting']),
  );
}

/// Why a stack is down, in the board's words:
/// `postgres-backup exited with code 1, 12 min ago.`
///
/// The sentence is built from the container's own fields. An exit code and a
/// finish time are only on record once Docker has reaped the container, so
/// anything else — a service that never started, a paused or restarting
/// member — degrades to `postgres-backup is not running.`. [others] is how
/// many more of the stack's containers are down; they are counted rather than
/// listed, so the line stays one line.
String stackDownSentence(
  ContainerSummary container, {
  int others = 0,
  DateTime? now,
}) {
  final bool reaped =
      container.state == ContainerState.exited ||
      container.state == ContainerState.dead;
  final DateTime? finished = container.finishedAt;
  final String body = reaped && finished != null
      ? '${container.name} exited with code ${container.exitCode}, '
            '${formatRelative(finished, now: now)}'
      : '${container.name} is not running';
  return others > 0 ? '$body, and $others more.' : '$body.';
}

/// `GET /stacks`
class ComposeStack {
  const ComposeStack({
    required this.name,
    required this.workingDir,
    required this.servicesUp,
    required this.servicesTotal,
    required this.source,
    required this.configOnDisk,
    this.services = const <StackService>[],
  });

  final String name;
  final String workingDir;
  final int servicesUp;
  final int servicesTotal;

  /// `directory` or `labels` (API_NOTES §16).
  final String source;

  /// Actions on a stack without a compose file answer `409`.
  final bool configOnDisk;
  final List<StackService> services;

  String get path =>
      workingDir.isNotEmpty ? workingDir : 'discovered from container labels';

  /// One entry per service, in the order the bar segments are drawn. The list
  /// endpoint only carries counts, so it falls back to up-then-down segments.
  List<ContainerState> get serviceStates {
    if (services.isNotEmpty) {
      return services.map((StackService s) => s.state).toList(growable: false);
    }
    return <ContainerState>[
      for (int i = 0; i < servicesTotal; i++)
        i < servicesUp ? ContainerState.running : ContainerState.exited,
    ];
  }

  /// The containers behind the services this stack reports as down, in the
  /// order the bar segments are drawn. A container belongs to a service when
  /// it carries both the stack and the service name; when the stack only
  /// carries counts, every stopped container of the stack qualifies.
  List<ContainerSummary> downContainers(List<ContainerSummary> containers) {
    final List<ContainerSummary> mine = containers
        .where((ContainerSummary c) => c.stack == name && !c.state.isRunning)
        .toList(growable: false);
    if (services.isEmpty) return mine;
    return <ContainerSummary>[
      for (final StackService s in services)
        if (s.state != ContainerState.running)
          ...mine.where((ContainerSummary c) => c.service == s.name),
    ];
  }

  /// Extra line shown when a stack is down.
  ///
  /// [containers] is the server's container list. When it carries the
  /// containers behind this stack's services, the line names the one that
  /// stopped it, with its own exit code and finish time
  /// (`postgres-backup exited with code 1, 12 min ago.`). Without them it
  /// falls back to the service names the list endpoint does carry.
  String? noteFor(List<ContainerSummary> containers, {DateTime? now}) {
    if (servicesUp != 0) return null;
    if (!configOnDisk) {
      return 'No compose file was found for this stack, so it cannot be driven '
          'from here.';
    }
    final List<ContainerSummary> down = downContainers(containers);
    if (down.isNotEmpty) {
      return stackDownSentence(down.first, others: down.length - 1, now: now);
    }
    if (services.isEmpty) return 'Every service in this stack is stopped.';
    return '${services.map((StackService s) => s.name).join(', ')} '
        '${services.length == 1 ? 'is' : 'are'} not running.';
  }

  /// [noteFor] with nothing but the stack itself to go on.
  String? get note => noteFor(const <ContainerSummary>[]);

  ComposeStack copyWith({int? servicesUp, List<StackService>? services}) =>
      ComposeStack(
        name: name,
        workingDir: workingDir,
        servicesUp: servicesUp ?? this.servicesUp,
        servicesTotal: servicesTotal,
        source: source,
        configOnDisk: configOnDisk,
        services: services ?? this.services,
      );

  factory ComposeStack.fromJson(Map<String, Object?> json) => ComposeStack(
    name: _str(json['name']),
    workingDir: _str(json['working_dir']),
    servicesUp: _int(json['services_running']),
    servicesTotal: _int(json['services_total']),
    source: _str(json['source'], 'directory'),
    configOnDisk: _bool(json['config_on_disk'], true),
    services: _objects(
      json['services'],
    ).map(StackService.fromJson).toList(growable: false),
  );
}

// -------------------------------------------------------------------- swarm

class SwarmNode {
  const SwarmNode({
    required this.id,
    required this.hostname,
    required this.role,
    required this.status,
    this.leader = false,
  });

  final String id;
  final String hostname;
  final String role;
  final String status;
  final bool leader;

  factory SwarmNode.fromJson(Map<String, Object?> json) => SwarmNode(
    id: _str(json['id']),
    hostname: _str(json['hostname']),
    role: _str(json['role']),
    status: _str(json['status']),
    leader: _bool(json['leader']),
  );
}

/// `GET /swarm` — always `200`, with `active: false` off a Swarm (API_NOTES §17).
class SwarmInfo {
  const SwarmInfo({
    required this.active,
    required this.nodeRole,
    required this.isManager,
    this.nodes = const <SwarmNode>[],
  });

  final bool active;

  /// `manager`, `worker` or `inactive`.
  final String nodeRole;
  final bool isManager;
  final List<SwarmNode> nodes;

  int get nodeCount => nodes.length;

  factory SwarmInfo.fromJson(Map<String, Object?> json) => SwarmInfo(
    active: _bool(json['active']),
    nodeRole: _str(json['node_role'], 'inactive'),
    isManager: _bool(json['is_manager']),
    nodes: _objects(
      json['nodes'],
    ).map(SwarmNode.fromJson).toList(growable: false),
  );
}

enum ServiceMode { replicated, global }

/// `GET /services`
class SwarmService {
  const SwarmService({
    required this.id,
    required this.name,
    required this.image,
    required this.mode,
    required this.running,
    required this.desired,
    required this.updateState,
  });

  final String id;
  final String name;
  final String image;
  final ServiceMode mode;
  final int running;
  final int desired;

  /// `completed`, `updating`, `paused`, `rollback_started` or empty.
  final String updateState;

  bool get isConverging => running != desired || updateState == 'updating';

  SwarmService copyWith({int? running, int? desired, String? updateState}) =>
      SwarmService(
        id: id,
        name: name,
        image: image,
        mode: mode,
        running: running ?? this.running,
        desired: desired ?? this.desired,
        updateState: updateState ?? this.updateState,
      );

  factory SwarmService.fromJson(Map<String, Object?> json) => SwarmService(
    id: _str(json['id']),
    name: _str(json['name']),
    image: _str(json['image']),
    mode: _str(json['mode']) == 'global'
        ? ServiceMode.global
        : ServiceMode.replicated,
    running: _int(json['running_tasks']),
    desired: _int(json['desired_tasks']),
    updateState: _str(json['update_state']),
  );
}

// -------------------------------------------------- images, volumes, networks

class DockerImage {
  const DockerImage({
    required this.id,
    required this.tags,
    required this.sizeBytes,
    required this.createdAt,
    required this.inUseBy,
    this.dangling = false,
  });

  final String id;
  final List<String> tags;
  final int sizeBytes;
  final DateTime createdAt;
  final List<String> inUseBy;
  final bool dangling;

  /// `registry.example.com/api:2.8.1`, or the short id for a dangling layer.
  String get ref => tags.isNotEmpty
      ? tags.first
      : '<none> ${id.replaceFirst('sha256:', '').substring(0, id.length >= 19 ? 12 : id.length)}';

  /// The agent only knows the image's creation time, never when it was pulled.
  String get created => 'created ${formatRelative(createdAt)}';

  bool get inUse => inUseBy.isNotEmpty;

  factory DockerImage.fromJson(Map<String, Object?> json) => DockerImage(
    id: _str(json['id']),
    tags: _strings(json['tags']),
    sizeBytes: _int(json['size']),
    createdAt: _time(json['created_at']),
    inUseBy: _strings(json['in_use_by']),
    dangling: _bool(json['dangling']),
  );
}

/// `GET /images` — items plus the summary block.
class ImageList {
  const ImageList({
    required this.images,
    required this.totalCount,
    required this.totalBytes,
    required this.reclaimableBytes,
  });

  final List<DockerImage> images;
  final int totalCount;
  final int totalBytes;
  final int reclaimableBytes;

  /// Built from the rows when an older agent sends no `summary`.
  factory ImageList.derived(List<DockerImage> images) => ImageList(
    images: images,
    totalCount: images.length,
    totalBytes: images.fold(0, (int a, DockerImage i) => a + i.sizeBytes),
    reclaimableBytes: images
        .where((DockerImage i) => !i.inUse)
        .fold(0, (int a, DockerImage i) => a + i.sizeBytes),
  );
}

/// `GET /volumes`
class VolumeInfo {
  const VolumeInfo({
    required this.name,
    required this.driver,
    required this.sizeBytes,
    required this.mountedBy,
    this.lastUsed,
  });

  final String name;
  final String driver;
  final int sizeBytes;
  final List<String> mountedBy;

  /// API_NOTES §21: the latest start time of a container that mounts it, and
  /// absent when none does.
  final DateTime? lastUsed;

  bool get mounted => mountedBy.isNotEmpty;

  /// Past this, "4 months ago" says less than the month's name does.
  static const Duration _staleAfter = Duration(days: 60);

  /// `in use`, `last used 12 min ago`, `last used in March`, `never used`.
  String get lastUsedLabel {
    if (mounted) return 'in use';
    final DateTime? when = lastUsed;
    if (when == null) return 'never used';
    if (DateTime.now().difference(when) > _staleAfter) {
      return 'last used in ${formatMonthName(when)}';
    }
    return 'last used ${formatRelative(when)}';
  }

  factory VolumeInfo.fromJson(Map<String, Object?> json) => VolumeInfo(
    name: _str(json['name']),
    driver: _str(json['driver'], 'local'),
    sizeBytes: _int(json['size']),
    mountedBy: _strings(json['mounted_by']),
    lastUsed: _timeOrNull(json['last_used']),
  );
}

/// `GET /volumes` — items plus the `summary` Revision 1.1 asks for.
class VolumeList {
  const VolumeList({
    required this.volumes,
    required this.count,
    required this.totalBytes,
    required this.unmounted,
  });

  final List<VolumeInfo> volumes;
  final int count;
  final int totalBytes;
  final int unmounted;

  factory VolumeList.derived(List<VolumeInfo> volumes) => VolumeList(
    volumes: volumes,
    count: volumes.length,
    totalBytes: volumes.fold(0, (int a, VolumeInfo v) => a + v.sizeBytes),
    unmounted: volumes.where((VolumeInfo v) => !v.mounted).length,
  );
}

/// `GET /networks`
class NetworkInfo {
  const NetworkInfo({
    required this.id,
    required this.name,
    required this.driver,
    required this.subnets,
    required this.scope,
    required this.attached,
    required this.isDefault,
  });

  final String id;
  final String name;
  final String driver;
  final List<String> subnets;

  /// `local` or `swarm`.
  final String scope;
  final int attached;
  final bool isDefault;

  String get subnet => subnets.isEmpty ? 'no subnet' : subnets.first;

  /// Nothing is attached. API_NOTES §34 counts default networks here too, and
  /// so does the "7 networks · 2 unused" line in the design.
  bool get unused => attached == 0;

  /// A default network is never removed or pruned, whatever is attached.
  bool get removable => attached == 0 && !isDefault;

  factory NetworkInfo.fromJson(Map<String, Object?> json) => NetworkInfo(
    id: _str(json['id']),
    name: _str(json['name']),
    driver: _str(json['driver']),
    subnets: _strings(json['subnets']),
    scope: _str(json['scope'], 'local'),
    attached: _int(json['attached_containers']),
    isDefault: _bool(json['is_default']),
  );
}

/// `GET /networks` — items plus the `summary` Revision 1.1 asks for.
class NetworkList {
  const NetworkList({
    required this.networks,
    required this.count,
    required this.unused,
  });

  final List<NetworkInfo> networks;
  final int count;
  final int unused;

  factory NetworkList.derived(List<NetworkInfo> networks) => NetworkList(
    networks: networks,
    count: networks.length,
    unused: networks.where((NetworkInfo n) => n.unused).length,
  );
}

// ------------------------------------------------------------------- alerts

enum AlertSeverity {
  critical,
  warning;

  static AlertSeverity parse(String value) =>
      value == 'critical' ? AlertSeverity.critical : AlertSeverity.warning;
}

enum AlertState {
  active,
  resolved,
  muted;

  static AlertState parse(String value) => AlertState.values.firstWhere(
    (AlertState s) => s.name == value,
    orElse: () => AlertState.active,
  );
}

/// `GET /alerts` — the id is `<rule_id>|<target_id>` (API_NOTES §22).
class AlertInfo {
  const AlertInfo({
    required this.id,
    required this.ruleId,
    required this.severity,
    required this.state,
    required this.target,
    required this.message,
    required this.firstSeen,
    required this.lastSeen,
    this.targetId = '',
    this.resolvedAt,
    this.mutedUntil,
    this.count = 1,
    this.exitCode,
    this.stack = '',
    this.windowSeconds = 0,
  });

  final String id;
  final String ruleId;
  final AlertSeverity severity;
  final AlertState state;

  /// A display name, usually the container name.
  final String target;

  /// The container id the actions act on; empty for host-level alerts.
  final String targetId;
  final String message;
  final DateTime firstSeen;
  final DateTime lastSeen;
  final DateTime? resolvedAt;
  final DateTime? mutedUntil;
  final int count;

  /// `unexpected_exit` carries the code the container died with. Older agents
  /// only put it in the message, which is where the fallback reads it.
  final int? exitCode;

  /// The Compose stack the target belongs to, when the agent knows it.
  final String stack;

  /// The rule's window, so "4 restarts in 10 min" can be written out.
  final int windowSeconds;

  Duration get window => Duration(seconds: windowSeconds);

  /// The card title the design writes: `postgres-backup exited`,
  /// `worker-queue restart loop`. A host-level alert keeps the agent's own
  /// sentence, with any raw Go duration in it rewritten.
  String get title {
    if (targetKind != 'container' || target.isEmpty) {
      return humanizeDurations(message);
    }
    return switch (ruleId) {
      AlertRuleId.unexpectedExit => '$target exited',
      AlertRuleId.restartLoop => '$target restart loop',
      AlertRuleId.cpuHigh => '$target CPU high',
      AlertRuleId.memoryHigh => '$target memory high',
      _ => humanizeDurations(message),
    };
  }

  /// The card's meta line: `Exit code 1 · 12 min ago · stack backups`,
  /// `4 restarts in 10 min · stack web-platform`.
  String get detail {
    final List<String> parts = <String>[];
    if (state == AlertState.resolved && resolvedAt != null) {
      parts.add('resolved ${formatWeekdayTime(resolvedAt!)}');
    } else {
      switch (ruleId) {
        case AlertRuleId.unexpectedExit:
          if (exitCode != null) parts.add('Exit code $exitCode');
          parts.add(formatRelative(lastSeen));
        case AlertRuleId.restartLoop:
          parts.add(
            windowSeconds > 0
                ? '$count restarts in ${formatDuration(window)}'
                : '$count restarts',
          );
        default:
          parts.add(formatRelative(lastSeen));
      }
    }
    if (stack.isNotEmpty) parts.add('stack $stack');
    if (state == AlertState.muted && mutedUntil != null) {
      parts.add('muted until ${formatClock(mutedUntil!)}');
    }
    return parts.join(' · ');
  }

  /// The overview's "Needs attention" row is the container, not the rule.
  String get attentionTitle => target.isNotEmpty ? target : title;

  /// `Exited with code 1 · 12 min ago`,
  /// `Restarted 4 times in the last 10 min`.
  String get attentionDetail => switch (ruleId) {
    AlertRuleId.unexpectedExit when exitCode != null =>
      'Exited with code $exitCode · ${formatRelative(lastSeen)}',
    AlertRuleId.restartLoop when windowSeconds > 0 =>
      'Restarted $count times in the last ${formatDuration(window)}',
    _ => detail,
  };

  /// The one-line note a resolved or muted alert leaves behind, which must not
  /// repeat its own title: `Disk above 80% on staging-1 · resolved Tue 14:10`.
  String get note => '$title · $detail';

  /// `container` or `host`.
  String get targetKind => targetId.isEmpty ? 'host' : 'container';

  static final RegExp _exitCodeInMessage = RegExp(r'code (\d+)');
  static final RegExp _windowInMessage = RegExp(
    r'\b(?:(\d+)h)?(?:(\d+)m)?(\d+(?:\.\d+)?)s\b',
  );

  static int? _readExitCode(Map<String, Object?> json) {
    final Object? raw = json['exit_code'];
    if (raw != null) return _int(raw);
    final Match? m = _exitCodeInMessage.firstMatch(_str(json['message']));
    return m == null ? null : int.tryParse(m[1]!);
  }

  static int _readWindow(Map<String, Object?> json) {
    final Object? raw = json['window_seconds'];
    if (raw != null) return _int(raw);
    final Match? m = _windowInMessage.firstMatch(_str(json['message']));
    if (m == null) return 0;
    return (int.tryParse(m[1] ?? '') ?? 0) * 3600 +
        (int.tryParse(m[2] ?? '') ?? 0) * 60 +
        (double.tryParse(m[3] ?? '') ?? 0).round();
  }

  factory AlertInfo.fromJson(Map<String, Object?> json) => AlertInfo(
    id: _str(json['id']),
    ruleId: _str(json['rule_id']),
    severity: AlertSeverity.parse(_str(json['severity'], 'warning')),
    state: AlertState.parse(_str(json['state'], 'active')),
    target: _str(json['target']),
    targetId: _str(json['target_id']),
    message: _str(json['message']),
    firstSeen: _time(json['first_seen']),
    lastSeen: _time(json['last_seen']),
    resolvedAt: _timeOrNull(json['resolved_at']),
    mutedUntil: _timeOrNull(json['muted_until']),
    count: _int(json['count'], 1),
    exitCode: _readExitCode(json),
    stack: _str(json['stack']),
    windowSeconds: _readWindow(json),
  );
}

/// Critical first, then warning, then the most recent — the order the design
/// puts the "Needs attention" rows and the alert cards in.
int compareAlertsByUrgency(AlertInfo a, AlertInfo b) {
  if (a.severity != b.severity) {
    return a.severity == AlertSeverity.critical ? -1 : 1;
  }
  return b.lastSeen.compareTo(a.lastSeen);
}

/// The five built-in rule ids from Revision 1.1.
abstract final class AlertRuleId {
  static const String unexpectedExit = 'unexpected_exit';
  static const String restartLoop = 'restart_loop';
  static const String cpuHigh = 'cpu_high';
  static const String memoryHigh = 'memory_high';
  static const String agentUnreachable = 'agent_unreachable';
}

/// `GET /alert-rules`
class AlertRule {
  const AlertRule({
    required this.id,
    required this.name,
    required this.enabled,
    required this.threshold,
    required this.windowSeconds,
    this.description = '',
    this.thresholdUnit = '',
    this.severity = 'warning',
    this.evaluatedLocally = true,
  });

  final String id;
  final String name;
  final bool enabled;
  final double threshold;
  final int windowSeconds;
  final String description;
  final String thresholdUnit;
  final String severity;

  /// `agent_unreachable` ships `false`: an agent that is down cannot say so.
  final bool evaluatedLocally;

  int get windowMinutes => (windowSeconds / 60).round();

  /// The design's wording, rebuilt from the raw threshold and window.
  String get label => switch (id) {
    AlertRuleId.unexpectedExit => 'Container exits unexpectedly',
    AlertRuleId.restartLoop =>
      'Restart loop, ${threshold.round()} or more in $windowMinutes min',
    AlertRuleId.cpuHigh =>
      'CPU above ${threshold.round()}% for $windowMinutes min',
    AlertRuleId.memoryHigh =>
      'Memory above ${threshold.round()}% for $windowMinutes min',
    AlertRuleId.agentUnreachable => 'Agent unreachable for $windowMinutes min',
    _ => name,
  };

  AlertRule copyWith({bool? enabled, double? threshold, int? windowSeconds}) =>
      AlertRule(
        id: id,
        name: name,
        enabled: enabled ?? this.enabled,
        threshold: threshold ?? this.threshold,
        windowSeconds: windowSeconds ?? this.windowSeconds,
        description: description,
        thresholdUnit: thresholdUnit,
        severity: severity,
        evaluatedLocally: evaluatedLocally,
      );

  factory AlertRule.fromJson(Map<String, Object?> json) => AlertRule(
    id: _str(json['id']),
    name: _str(json['name']),
    enabled: _bool(json['enabled']),
    threshold: _double(json['threshold']),
    windowSeconds: _int(json['window_seconds']),
    description: _str(json['description']),
    thresholdUnit: _str(json['threshold_unit']),
    severity: _str(json['severity'], 'warning'),
    evaluatedLocally: _bool(json['evaluated_locally'], true),
  );
}

// --------------------------------------------------------------- registries

/// The three looks the design draws, derived from `status` and `token_expiry`.
enum RegistryStatus { verified, expiring, failed, anonymous }

/// `GET /registries` — never carries the secret.
class RegistryInfo {
  const RegistryInfo({
    required this.id,
    required this.host,
    required this.username,
    required this.rawStatus,
    this.statusAt,
    this.statusError = '',
    this.tokenExpiry,
  });

  final String id;
  final String host;
  final String username;

  /// `unknown`, `ok` or `failed`.
  final String rawStatus;
  final DateTime? statusAt;
  final String statusError;
  final DateTime? tokenExpiry;

  static const Duration _expirySoon = Duration(days: 7);

  bool get hasCredential => username.isNotEmpty;

  bool get expiresSoon {
    final DateTime? expiry = tokenExpiry;
    if (expiry == null) return false;
    return expiry.difference(DateTime.now()) < _expirySoon;
  }

  RegistryStatus get status {
    if (!hasCredential) return RegistryStatus.anonymous;
    if (rawStatus == 'failed') return RegistryStatus.failed;
    if (expiresSoon) return RegistryStatus.expiring;
    if (rawStatus == 'ok') return RegistryStatus.verified;
    return RegistryStatus.anonymous;
  }

  /// `Verified 2 h ago`, `Token expires in 6 days`, `Login failed`, `No login`.
  String get statusLabel => switch (status) {
    RegistryStatus.verified =>
      statusAt == null ? 'Verified' : 'Verified ${formatRelative(statusAt!)}',
    RegistryStatus.expiring => 'Token expires ${formatRelative(tokenExpiry!)}',
    RegistryStatus.failed => 'Login failed',
    RegistryStatus.anonymous => hasCredential ? 'Not tested yet' : 'No login',
  };

  /// `Signed in as deploy-bot`.
  String get subtitle => hasCredential
      ? 'Signed in as $username'
      : 'Anonymous pulls, rate limited by the registry';

  factory RegistryInfo.fromJson(Map<String, Object?> json) => RegistryInfo(
    id: _str(json['id']),
    host: _str(json['host']),
    username: _str(json['username']),
    rawStatus: _str(json['status'], 'unknown'),
    statusAt: _timeOrNull(json['status_at']),
    statusError: _str(json['status_error']),
    tokenExpiry: _timeOrNull(json['token_expiry']),
  );
}

// ------------------------------------------------------- settings and devices

/// `GET /settings`
class AgentSettings {
  const AgentSettings({
    required this.requireBiometricForRisky,
    required this.stacksDirectory,
    required this.pushRelayStatus,
    this.pushRelayUrl = '',
  });

  final bool requireBiometricForRisky;
  final String stacksDirectory;

  /// API_NOTES §24: always `not_configured` until a relay exists.
  final String pushRelayStatus;
  final String pushRelayUrl;

  bool get pushRelayConnected => pushRelayStatus == 'connected';

  AgentSettings copyWith({bool? requireBiometricForRisky}) => AgentSettings(
    requireBiometricForRisky:
        requireBiometricForRisky ?? this.requireBiometricForRisky,
    stacksDirectory: stacksDirectory,
    pushRelayStatus: pushRelayStatus,
    pushRelayUrl: pushRelayUrl,
  );

  factory AgentSettings.fromJson(Map<String, Object?> json) => AgentSettings(
    requireBiometricForRisky: _bool(json['require_biometric_for_risky'], true),
    stacksDirectory: _str(json['stacks_dir']),
    pushRelayStatus: _str(json['push_relay_status'], 'not_configured'),
    pushRelayUrl: _str(json['push_relay_url']),
  );
}

/// `GET /devices` — never the key, the key hash or the push token value.
class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.name,
    required this.role,
    required this.lastSeenAt,
    required this.isSelf,
    this.createdAt,
    this.hasPushToken = false,
  });

  final String id;
  final String name;
  final ServerRole role;
  final DateTime lastSeenAt;
  final bool isSelf;
  final DateTime? createdAt;
  final bool hasPushToken;

  String get lastSeen => formatRelative(lastSeenAt);

  factory DeviceInfo.fromJson(Map<String, Object?> json) => DeviceInfo(
    id: _str(json['id']),
    name: _str(json['name']),
    role: ServerRole.parse(_str(json['role'], 'viewer')),
    lastSeenAt: _time(json['last_seen_at']),
    isSelf: _bool(json['is_self']),
    createdAt: _timeOrNull(json['created_at']),
    hasPushToken: _bool(json['has_push_token']),
  );
}

/// `GET /agent/update` — API_NOTES §27: nothing is ever downloaded.
class AgentUpdate {
  const AgentUpdate({
    required this.current,
    required this.latest,
    required this.available,
    this.releaseNotesUrl = '',
    this.selfUpdateStatus = 'not_configured',
    this.message = '',
  });

  final String current;
  final String latest;
  final bool available;
  final String releaseNotesUrl;
  final String selfUpdateStatus;
  final String message;

  bool get configured => selfUpdateStatus != 'not_configured';

  factory AgentUpdate.fromJson(Map<String, Object?> json) => AgentUpdate(
    current: _str(json['current_version']),
    latest: _str(json['latest_version'], 'unknown'),
    available: _bool(json['update_available']),
    releaseNotesUrl: _str(json['release_notes_url']),
    selfUpdateStatus: _str(json['self_update_status'], 'not_configured'),
    message: _str(json['message']),
  );
}

/// `POST /pair` — `201` with the device key (API_NOTES §6).
class PairResult {
  const PairResult({
    required this.deviceKey,
    required this.deviceId,
    required this.role,
    required this.certFingerprint,
    required this.agentVersion,
    required this.server,
  });

  final String deviceKey;
  final String deviceId;
  final ServerRole role;
  final String certFingerprint;
  final String agentVersion;
  final Server server;
}

// --------------------------------------------------------------------- jobs

enum JobStatus {
  queued,
  running,
  succeeded,
  failed,
  canceled;

  static JobStatus parse(String value) => JobStatus.values.firstWhere(
    (JobStatus s) => s.name == value,
    orElse: () => JobStatus.running,
  );

  bool get isFinished => this != JobStatus.queued && this != JobStatus.running;
}

/// One progress line of a job.
class JobLine {
  const JobLine({required this.text, this.percent = -1});

  final String text;

  /// -1 when the step has no measurable progress.
  final double percent;

  factory JobLine.fromJson(Map<String, Object?> json) =>
      JobLine(text: _str(json['text']), percent: _double(json['percent'], -1));
}

/// Every long operation returns `202 {"job_id": ...}`; this is `GET /jobs/{id}`.
class Job {
  const Job({
    required this.id,
    required this.type,
    required this.target,
    required this.status,
    required this.progress,
    required this.progressLines,
    this.error,
    this.errorCode,
    this.startedAt,
    this.finishedAt,
  });

  final String id;
  final String type;
  final String target;
  final JobStatus status;

  /// 0..1
  final double progress;
  final List<JobLine> progressLines;
  final String? error;

  /// The agent's error code for a failed job: `registry_auth_failed`.
  final String? errorCode;

  /// `started_at` and `finished_at`, for the elapsed time the sheet shows.
  final DateTime? startedAt;
  final DateTime? finishedAt;

  /// True when the agent reported a real percentage, rather than the creep
  /// [progress] falls back to.
  bool get hasPercent =>
      progressLines.isNotEmpty && progressLines.last.percent >= 0;

  List<String> get lines =>
      progressLines.map((JobLine l) => l.text).toList(growable: false);

  /// `Pulling registry.example.com/api:2.9.0` — the sheet's heading.
  String get title {
    final String what = switch (type) {
      'image_pull' => 'Pulling',
      'image_prune' => 'Pruning images',
      'volume_prune' => 'Pruning volumes',
      'network_prune' => 'Pruning networks',
      'stack_up' => 'Starting',
      'stack_redeploy' => 'Redeploying',
      'stack_restart' => 'Restarting',
      'stack_down' => 'Stopping',
      'service_update' => 'Updating',
      'service_rollback' => 'Rolling back',
      'agent_update' => 'Updating the agent',
      _ => type.replaceAll('_', ' '),
    };
    final bool needsTarget = !what.contains(' ') || what.startsWith('Rolling');
    return needsTarget && target.isNotEmpty ? '$what $target' : what;
  }

  Job copyWith({
    JobStatus? status,
    double? progress,
    List<JobLine>? progressLines,
    String? error,
    String? errorCode,
    DateTime? startedAt,
    DateTime? finishedAt,
  }) => Job(
    id: id,
    type: type,
    target: target,
    status: status ?? this.status,
    progress: progress ?? this.progress,
    progressLines: progressLines ?? this.progressLines,
    error: error ?? this.error,
    errorCode: errorCode ?? this.errorCode,
    startedAt: startedAt ?? this.startedAt,
    finishedAt: finishedAt ?? this.finishedAt,
  );

  factory Job.fromJson(Map<String, Object?> json) {
    final List<JobLine> lines = _objects(
      json['progress'],
    ).map(JobLine.fromJson).toList(growable: false);
    final JobStatus status = JobStatus.parse(_str(json['status'], 'running'));
    final Object? error = json['error'];
    final double last = lines.isEmpty ? -1 : lines.last.percent;
    return Job(
      id: _str(json['id']),
      type: _str(json['type']),
      target: _str(json['target']),
      status: status,
      progress: status.isFinished
          ? 1
          : (last >= 0
                ? (last / 100).clamp(0.0, 1.0)
                : _fallbackProgress(lines)),
      progressLines: lines,
      error: error is Map<String, Object?> ? _str(error['message']) : null,
      errorCode: error is Map<String, Object?> ? _str(error['code']) : null,
      startedAt:
          _timeOrNull(json['started_at']) ?? _timeOrNull(json['created_at']),
      finishedAt: _timeOrNull(json['finished_at']),
    );
  }

  /// No percentage from the agent: creep towards, but never reach, done.
  static double _fallbackProgress(List<JobLine> lines) => lines.isEmpty
      ? 0.05
      : (lines.length / (lines.length + 3)).clamp(0.05, 0.9);
}
