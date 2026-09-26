/// The demo world: the sample data from `design/`, in the shapes Revision 1.1
/// settles. Every figure is raw — timestamps, byte counts, percentages — so the
/// mock exercises exactly the formatting the real client does.
library;

import 'models.dart';
import 'this_device.dart';

const int _mb = 1024 * 1024;
const int _gb = 1024 * _mb;

/// Everything one mocked agent knows, mutable so that actions visibly work.
class MockWorld {
  MockWorld({
    required this.server,
    required this.reachable,
    required this.info,
    required this.stats,
    required this.containers,
    required this.containerDetails,
    required this.stacks,
    required this.swarm,
    required this.services,
    required this.images,
    required this.imageSummary,
    required this.volumes,
    required this.networks,
    required this.alerts,
    required this.rules,
    required this.registries,
    required this.settings,
    required this.devices,
    required this.update,
    required this.activity,
    required this.logSeed,
    this.offlineReason,
  });

  Server server;
  bool reachable;
  final String? offlineReason;

  SystemInfo info;
  SystemStats stats;
  final List<ContainerSummary> containers;

  /// Container id to its networks, mounts, restart policy and env names.
  final Map<String, ContainerDetail> containerDetails;
  final List<ComposeStack> stacks;
  SwarmInfo swarm;
  final List<SwarmService> services;
  final List<DockerImage> images;
  ImageList imageSummary;
  final List<VolumeInfo> volumes;
  final List<NetworkInfo> networks;
  final List<AlertInfo> alerts;
  final List<AlertRule> rules;
  final List<RegistryInfo> registries;
  AgentSettings settings;
  final List<DeviceInfo> devices;
  AgentUpdate update;
  final List<ActivityEntry> activity;
  final List<LogLine> logSeed;

  /// Counts are derived so start/stop/restart move the figures on every screen.
  void recountContainers() {
    int count(ContainerState state) =>
        containers.where((ContainerSummary c) => c.state == state).length;
    stats = stats.copyWith(
      containers: ContainerCounts(
        running: count(ContainerState.running),
        restarting: count(ContainerState.restarting),
        paused: count(ContainerState.paused),
        created: count(ContainerState.created),
        exited: count(ContainerState.exited) + count(ContainerState.dead),
        total: containers.length,
      ),
    );
  }

  /// What this device is called on the agent: the seed pairs it under the
  /// hardware's own name ([thisDeviceLabel]), as the real app does.
  String get selfDeviceName {
    for (final DeviceInfo device in devices) {
      if (device.isSelf) return device.name;
    }
    return thisDeviceLabel();
  }

  int _activityId = 0;

  void addActivity(String action, String target) => activity.insert(
    0,
    ActivityEntry(
      id: 'act-${++_activityId}',
      time: DateTime.now(),
      action: action,
      target: target,
      result: 'ok',
      deviceId: 'dev-1',
      deviceName: thisDeviceLabel(),
      role: server.role.name,
      status: 200,
    ),
  );
}

DateTime _ago(Duration d) => DateTime.now().subtract(d);

ContainerSummary _c(
  String id,
  String name,
  String image, {
  required ContainerState state,
  String health = '',
  Duration uptime = Duration.zero,
  Duration? exitedAgo,
  int exitCode = 0,
  double cpu = 0,
  int memory = 0,
  int memoryLimit = 2 * _gb,
  int restarts = 0,
  String stack = '',
  String service = '',
  List<PortMapping> ports = const <PortMapping>[],
}) {
  final bool up = state == ContainerState.running;
  return ContainerSummary(
    id: id,
    name: name,
    image: image,
    state: state,
    health: health,
    createdAt: _ago(uptime + const Duration(days: 1)),
    startedAt: up ? _ago(uptime) : null,
    finishedAt: exitedAgo == null ? null : _ago(exitedAgo),
    uptimeSeconds: up ? uptime.inSeconds : 0,
    restartCount: restarts,
    exitCode: exitCode,
    cpuPercent: cpu,
    memoryBytes: memory,
    memoryLimitBytes: memoryLimit,
    memoryPercent: memoryLimit == 0 ? 0 : memory / memoryLimit * 100,
    stack: stack,
    service: service.isEmpty ? name : service,
    ports: ports,
  );
}

List<AlertRule> _defaultRules({bool saturationOn = true}) => <AlertRule>[
  AlertRule(
    id: AlertRuleId.unexpectedExit,
    name: 'Container exits unexpectedly',
    description:
        'A container stopped with a non-zero exit code without being asked to.',
    enabled: true,
    threshold: 0,
    windowSeconds: 0,
    thresholdUnit: 'exit_code',
    severity: 'critical',
  ),
  const AlertRule(
    id: AlertRuleId.restartLoop,
    name: 'Restart loop',
    description: 'A container restarted 3 or more times within the window.',
    enabled: true,
    threshold: 3,
    windowSeconds: 600,
    thresholdUnit: 'restarts',
    severity: 'critical',
  ),
  AlertRule(
    id: AlertRuleId.cpuHigh,
    name: 'CPU above threshold',
    description: 'A container held CPU above the threshold for the window.',
    enabled: saturationOn,
    threshold: 90,
    windowSeconds: 300,
    thresholdUnit: 'percent',
  ),
  AlertRule(
    id: AlertRuleId.memoryHigh,
    name: 'Memory above threshold',
    description: 'A container held memory above the threshold for the window.',
    enabled: saturationOn,
    threshold: 90,
    windowSeconds: 300,
    thresholdUnit: 'percent',
  ),
  const AlertRule(
    id: AlertRuleId.agentUnreachable,
    name: 'Agent unreachable',
    description:
        'The agent stopped answering. This cannot be detected by the agent '
        'itself; it needs the push relay to watch a heartbeat.',
    enabled: false,
    threshold: 0,
    windowSeconds: 120,
    thresholdUnit: 'seconds',
    severity: 'critical',
    evaluatedLocally: false,
  ),
];

List<LogLine> _logSeed(List<(int, String, String)> rows) => <LogLine>[
  for (final (int secondsAgo, String stream, String line) in rows)
    LogLine(
      at: _ago(Duration(seconds: secondsAgo)),
      stream: stream,
      line: line,
    ),
];

/// prod-eu-1 — the server every design screen is drawn against.
MockWorld seedProduction() {
  final List<ContainerSummary> containers = <ContainerSummary>[
    _c(
      'a91c3f70b214',
      'nginx-proxy',
      'nginx:1.27',
      state: ContainerState.running,
      uptime: const Duration(days: 12),
      cpu: 0.4,
      memory: 38 * _mb,
      stack: 'web-platform',
      ports: const <PortMapping>[
        PortMapping(privatePort: 80, publicPort: 80),
        PortMapping(privatePort: 443, publicPort: 443),
      ],
    ),
    _c(
      '4f2a9c1e7b3d',
      'api-gateway',
      'registry.example.com/api:2.8.1',
      state: ContainerState.running,
      health: 'healthy',
      uptime: const Duration(days: 3),
      cpu: 18,
      memory: 412 * _mb,
      stack: 'web-platform',
      service: 'api',
      ports: const <PortMapping>[
        PortMapping(privatePort: 8080, publicPort: 8080),
      ],
    ),
    _c(
      '7d1b5e0c88af',
      'worker-queue',
      'registry.example.com/worker:2.8.1',
      state: ContainerState.restarting,
      restarts: 4,
      cpu: 2,
      memory: 128 * _mb,
      stack: 'web-platform',
      service: 'worker',
    ),
    _c(
      '2c6e4a9f1d30',
      'postgres-main',
      'postgres:16',
      state: ContainerState.running,
      health: 'healthy',
      uptime: const Duration(days: 12),
      cpu: 6,
      memory: (1.9 * _gb).round(),
      memoryLimit: 4 * _gb,
      stack: 'web-platform',
      service: 'db',
    ),
    _c(
      'e50f82a7c419',
      'redis-cache',
      'redis:7.2',
      state: ContainerState.running,
      uptime: const Duration(days: 12),
      cpu: 1,
      memory: 96 * _mb,
      stack: 'web-platform',
      service: 'cache',
    ),
    _c(
      'b3a7d21e9c65',
      'grafana',
      'grafana/grafana:11.1',
      state: ContainerState.running,
      uptime: const Duration(days: 8),
      cpu: 2,
      memory: 210 * _mb,
      stack: 'monitoring',
    ),
    _c(
      '91f6c0b4d2a8',
      'postgres-backup',
      'registry.example.com/pg-backup:1.3',
      state: ContainerState.exited,
      exitCode: 1,
      exitedAgo: const Duration(minutes: 12),
      stack: 'backups',
    ),
    // The remaining rows of the same list; the design shows the first seven.
    _c(
      '5ac98d31b706',
      'prometheus',
      'prom/prometheus:2.54',
      state: ContainerState.running,
      uptime: const Duration(days: 8),
      cpu: 3,
      memory: 512 * _mb,
      stack: 'monitoring',
    ),
    _c(
      'c47b20e6f915',
      'loki',
      'grafana/loki:3.1',
      state: ContainerState.running,
      uptime: const Duration(days: 8),
      cpu: 2,
      memory: 180 * _mb,
      stack: 'monitoring',
    ),
    _c(
      '0be93a7c5d12',
      'traefik',
      'traefik:3.1',
      state: ContainerState.running,
      uptime: const Duration(days: 21),
      cpu: 1,
      memory: 74 * _mb,
      stack: 'web-platform',
    ),
    _c(
      '6f2de84b039c',
      'minio',
      'minio/minio:2024.8',
      state: ContainerState.running,
      uptime: const Duration(days: 14),
      cpu: 2,
      memory: 260 * _mb,
      stack: 'storage',
    ),
    _c(
      'd18c4f9a2e57',
      'mailer',
      'registry.example.com/mailer:1.9',
      state: ContainerState.running,
      uptime: const Duration(days: 6),
      cpu: 0.6,
      memory: 84 * _mb,
      stack: 'web-platform',
    ),
    _c(
      '39a7e15cb840',
      'search-index',
      'opensearchproject/opensearch:2.16',
      state: ContainerState.running,
      uptime: const Duration(days: 9),
      cpu: 9,
      memory: (1.4 * _gb).round(),
      memoryLimit: 4 * _gb,
      stack: 'web-platform',
    ),
    _c(
      '8e05b6c3a71f',
      'cron-runner',
      'registry.example.com/cron:1.2',
      state: ContainerState.running,
      uptime: const Duration(days: 4),
      cpu: 0.2,
      memory: 42 * _mb,
      stack: 'web-platform',
    ),
    _c(
      'f62a903d1c48',
      'docs-site',
      'registry.example.com/docs:1.0',
      state: ContainerState.running,
      uptime: const Duration(days: 30),
      cpu: 0.1,
      memory: 24 * _mb,
      stack: 'web-platform',
    ),
    _c(
      '47bd1e8f05a2',
      'legacy-import',
      'registry.example.com/importer:0.9',
      state: ContainerState.exited,
      exitedAgo: const Duration(days: 3),
      stack: 'backups',
    ),
  ];

  final List<DockerImage> images = <DockerImage>[
    DockerImage(
      id: 'sha256:1a2b3c4d5e6f7a8b',
      tags: const <String>['registry.example.com/api:2.8.1'],
      sizeBytes: 412 * _mb,
      createdAt: _ago(const Duration(days: 3)),
      inUseBy: const <String>['api-gateway'],
    ),
    DockerImage(
      id: 'sha256:4d5e6f7a8b9c0d1e',
      tags: const <String>['registry.example.com/api:2.7.4'],
      sizeBytes: 409 * _mb,
      createdAt: _ago(const Duration(days: 21)),
      inUseBy: const <String>[],
    ),
    DockerImage(
      id: 'sha256:7a8b9c0d1e2f3a4b',
      tags: const <String>['registry.example.com/worker:2.8.1'],
      sizeBytes: 388 * _mb,
      createdAt: _ago(const Duration(days: 3)),
      inUseBy: const <String>['worker-queue'],
    ),
    DockerImage(
      id: 'sha256:0d1e2f3a4b5c6d7e',
      tags: const <String>['postgres:16'],
      sizeBytes: 431 * _mb,
      createdAt: _ago(const Duration(days: 62)),
      inUseBy: const <String>['postgres-main'],
    ),
    DockerImage(
      id: 'sha256:3a4b5c6d7e8f9a0b',
      tags: const <String>['redis:7.2'],
      sizeBytes: 117 * _mb,
      createdAt: _ago(const Duration(hours: 5)),
      inUseBy: const <String>['redis-cache'],
    ),
    DockerImage(
      id: 'sha256:6d7e8f9a0b1c2d3e',
      tags: const <String>['nginx:1.25'],
      sizeBytes: 188 * _mb,
      createdAt: _ago(const Duration(days: 150)),
      inUseBy: const <String>[],
    ),
  ];

  return MockWorld(
    server: const Server(
      id: 'prod-eu-1',
      name: 'prod-eu-1',
      baseUrl: 'https://agent.example.com:8443',
      certFingerprint:
          '9F:2C:1B:44:A0:5E:7D:31:6C:82:9A:F0:11:3D:5B:7E:'
          '20:C4:66:8A:D9:12:4F:31:0E:A7:58:B3:6D:2C:A1:7E',
      deviceId: 'dev-1',
      role: ServerRole.admin,
    ),
    reachable: true,
    info: SystemInfo(
      hostname: 'prod-eu-1',
      dockerVersion: '27.1',
      agentVersion: '1.4.2',
      cpuCores: 8,
      memoryTotalBytes: 16 * _gb,
      diskTotalBytes: 400 * _gb,
      diskUsedBytes: 212 * _gb,
      swarmRole: 'manager',
      agentUptimeSeconds: const Duration(days: 41).inSeconds,
      hostUptimeSeconds: const Duration(days: 41).inSeconds,
      os: 'Debian GNU/Linux 12',
      arch: 'amd64',
    ),
    stats: SystemStats(
      cpuPercent: 34,
      memoryUsedBytes: (9.8 * _gb).round(),
      memoryTotalBytes: 16 * _gb,
      diskUsedBytes: 212 * _gb,
      diskTotalBytes: 400 * _gb,
      containers: const ContainerCounts(
        running: 13,
        restarting: 1,
        exited: 2,
        total: 16,
      ),
      activeAlerts: 2,
    ),
    containers: containers,
    containerDetails: <String, ContainerDetail>{
      '4f2a9c1e7b3d': ContainerDetail(
        summary: containers[1],
        networks: const <NetworkAttachment>[
          NetworkAttachment(
            name: 'web-platform_backend',
            ipAddress: '172.20.0.5',
          ),
        ],
        mounts: const <MountInfo>[
          MountInfo(
            type: 'volume',
            name: 'api_config',
            destination: '/etc/api',
          ),
          MountInfo(
            type: 'volume',
            name: 'api_cache',
            destination: '/var/cache',
          ),
        ],
        restartPolicy: 'unless-stopped',
        envNames: const <String>[
          'DATABASE_URL',
          'FEATURE_FLAGS',
          'JWT_SECRET',
          'LOG_LEVEL',
          'NODE_ENV',
          'OTEL_ENDPOINT',
          'PORT',
          'RATE_LIMIT',
          'REDIS_URL',
          'REGION',
          'SENTRY_DSN',
          'STRIPE_KEY',
        ],
      ),
    },
    stacks: <ComposeStack>[
      const ComposeStack(
        name: 'web-platform',
        workingDir: '/opt/stacks/web-platform',
        servicesUp: 4,
        servicesTotal: 5,
        source: 'directory',
        configOnDisk: true,
        services: <StackService>[
          StackService(name: 'proxy', running: 1, total: 1),
          StackService(name: 'api', running: 1, total: 1),
          // worker-queue is flapping, not stopped: its segment is amber.
          StackService(name: 'worker', running: 0, total: 1, restarting: 1),
          StackService(name: 'db', running: 1, total: 1),
          StackService(name: 'cache', running: 1, total: 1),
        ],
      ),
      const ComposeStack(
        name: 'monitoring',
        workingDir: '/opt/stacks/monitoring',
        servicesUp: 3,
        servicesTotal: 3,
        source: 'directory',
        configOnDisk: true,
        services: <StackService>[
          StackService(name: 'grafana', running: 1, total: 1),
          StackService(name: 'prometheus', running: 1, total: 1),
          StackService(name: 'loki', running: 1, total: 1),
        ],
      ),
      const ComposeStack(
        name: 'backups',
        workingDir: '/opt/stacks/backups',
        servicesUp: 0,
        servicesTotal: 1,
        source: 'directory',
        configOnDisk: true,
        services: <StackService>[
          StackService(name: 'postgres-backup', running: 0, total: 1),
        ],
      ),
    ],
    swarm: const SwarmInfo(
      active: true,
      nodeRole: 'manager',
      isManager: true,
      nodes: <SwarmNode>[
        SwarmNode(
          id: 'node-1',
          hostname: 'prod-eu-1',
          role: 'manager',
          status: 'ready',
          leader: true,
        ),
        SwarmNode(
          id: 'node-2',
          hostname: 'prod-eu-2',
          role: 'worker',
          status: 'ready',
        ),
        SwarmNode(
          id: 'node-3',
          hostname: 'prod-eu-3',
          role: 'worker',
          status: 'ready',
        ),
      ],
    ),
    services: <SwarmService>[
      const SwarmService(
        id: 'svc-api',
        name: 'api',
        image: 'registry.example.com/api:2.8.1',
        mode: ServiceMode.replicated,
        running: 3,
        desired: 3,
        updateState: 'completed',
      ),
      const SwarmService(
        id: 'svc-worker',
        name: 'worker',
        image: 'registry.example.com/worker:2.8.1',
        mode: ServiceMode.replicated,
        running: 2,
        desired: 4,
        updateState: 'updating',
      ),
      const SwarmService(
        id: 'svc-ingress',
        name: 'ingress',
        image: 'traefik:3.1',
        mode: ServiceMode.global,
        running: 3,
        desired: 3,
        updateState: 'completed',
      ),
    ],
    images: images,
    // Computed from the rows above, so the subtitle ("6 images · 1.9 GB ·
    // 597 MB unused") always agrees with the table under it.
    imageSummary: ImageList.derived(images),
    volumes: <VolumeInfo>[
      VolumeInfo(
        name: 'web-platform_pgdata',
        driver: 'local',
        sizeBytes: 31 * _gb,
        mountedBy: const <String>['postgres-main'],
        lastUsed: _ago(const Duration(days: 12)),
      ),
      VolumeInfo(
        name: 'web-platform_redis',
        driver: 'local',
        sizeBytes: (1.2 * _gb).round(),
        mountedBy: const <String>['redis-cache'],
        lastUsed: _ago(const Duration(days: 12)),
      ),
      VolumeInfo(
        name: 'monitoring_prometheus',
        driver: 'local',
        sizeBytes: (9.8 * _gb).round(),
        mountedBy: const <String>['prometheus'],
        lastUsed: _ago(const Duration(days: 8)),
      ),
      VolumeInfo(
        name: 'monitoring_grafana',
        driver: 'local',
        sizeBytes: 640 * _mb,
        mountedBy: const <String>['grafana'],
        lastUsed: _ago(const Duration(days: 8)),
      ),
      VolumeInfo(
        name: 'backups_dumps',
        driver: 'local',
        sizeBytes: (3.1 * _gb).round(),
        mountedBy: const <String>[],
        lastUsed: _ago(const Duration(minutes: 12)),
      ),
      VolumeInfo(
        name: 'old_uploads',
        driver: 'local',
        sizeBytes: 210 * _mb,
        mountedBy: const <String>[],
        lastUsed: _ago(const Duration(days: 190)),
      ),
      VolumeInfo(
        name: 'web-platform_uploads',
        driver: 'local',
        sizeBytes: 120 * _mb,
        mountedBy: const <String>['api-gateway'],
        lastUsed: _ago(const Duration(days: 3)),
      ),
      VolumeInfo(
        name: 'monitoring_alertmanager',
        driver: 'local',
        sizeBytes: 48 * _mb,
        mountedBy: const <String>['prometheus'],
        lastUsed: _ago(const Duration(days: 8)),
      ),
      VolumeInfo(
        name: 'storage_minio',
        driver: 'local',
        sizeBytes: 40 * _mb,
        mountedBy: const <String>['minio'],
        lastUsed: _ago(const Duration(days: 14)),
      ),
    ],
    networks: <NetworkInfo>[
      const NetworkInfo(
        id: 'net-backend',
        name: 'web-platform_backend',
        driver: 'bridge',
        subnets: <String>['172.20.0.0/16'],
        scope: 'local',
        attached: 5,
        isDefault: false,
      ),
      const NetworkInfo(
        id: 'net-frontend',
        name: 'web-platform_frontend',
        driver: 'bridge',
        subnets: <String>['172.21.0.0/16'],
        scope: 'local',
        attached: 2,
        isDefault: false,
      ),
      const NetworkInfo(
        id: 'net-monitoring',
        name: 'monitoring_default',
        driver: 'bridge',
        subnets: <String>['172.22.0.0/16'],
        scope: 'local',
        attached: 3,
        isDefault: false,
      ),
      const NetworkInfo(
        id: 'net-ingress',
        name: 'ingress',
        driver: 'overlay',
        subnets: <String>['10.0.0.0/24'],
        scope: 'swarm',
        attached: 3,
        isDefault: false,
      ),
      const NetworkInfo(
        id: 'net-bridge',
        name: 'bridge',
        driver: 'bridge',
        subnets: <String>['172.17.0.0/16'],
        scope: 'local',
        attached: 0,
        isDefault: true,
      ),
      const NetworkInfo(
        id: 'net-old-test',
        name: 'old_test_net',
        driver: 'bridge',
        subnets: <String>['172.29.0.0/16'],
        scope: 'local',
        attached: 0,
        isDefault: false,
      ),
      const NetworkInfo(
        id: 'net-storage',
        name: 'storage_default',
        driver: 'bridge',
        subnets: <String>['172.23.0.0/16'],
        scope: 'local',
        attached: 1,
        isDefault: false,
      ),
    ],
    alerts: <AlertInfo>[
      AlertInfo(
        id: '${AlertRuleId.unexpectedExit}|91f6c0b4d2a8',
        ruleId: AlertRuleId.unexpectedExit,
        severity: AlertSeverity.critical,
        state: AlertState.active,
        target: 'postgres-backup',
        targetId: '91f6c0b4d2a8',
        message: 'postgres-backup exited with code 1',
        firstSeen: _ago(const Duration(minutes: 12)),
        lastSeen: _ago(const Duration(minutes: 12)),
        exitCode: 1,
        stack: 'backups',
      ),
      AlertInfo(
        id: '${AlertRuleId.restartLoop}|7d1b5e0c88af',
        ruleId: AlertRuleId.restartLoop,
        severity: AlertSeverity.warning,
        state: AlertState.active,
        target: 'worker-queue',
        targetId: '7d1b5e0c88af',
        message: 'worker-queue restarted 4 times in 10m0s',
        firstSeen: _ago(const Duration(minutes: 22)),
        lastSeen: _ago(const Duration(minutes: 2)),
        count: 4,
        stack: 'web-platform',
        windowSeconds: 600,
      ),
      AlertInfo(
        id: '${AlertRuleId.memoryHigh}|host',
        ruleId: AlertRuleId.memoryHigh,
        severity: AlertSeverity.warning,
        state: AlertState.resolved,
        target: 'Disk above 80% on staging-1',
        message: 'Disk above 80% on staging-1',
        firstSeen: _ago(const Duration(days: 2)),
        lastSeen: _ago(const Duration(days: 2)),
        resolvedAt: _ago(const Duration(days: 2)),
      ),
    ],
    rules: _defaultRules(),
    registries: <RegistryInfo>[
      RegistryInfo(
        id: 'reg-private',
        host: 'registry.example.com',
        username: 'deploy-bot',
        rawStatus: 'ok',
        statusAt: _ago(const Duration(hours: 2)),
      ),
      RegistryInfo(
        id: 'reg-ghcr',
        host: 'ghcr.io',
        username: '[YOUR-ORG]-ci',
        rawStatus: 'ok',
        statusAt: _ago(const Duration(days: 4)),
        tokenExpiry: DateTime.now().add(const Duration(days: 6)),
      ),
      const RegistryInfo(
        id: 'reg-hub',
        host: 'docker.io',
        username: '',
        rawStatus: 'unknown',
      ),
    ],
    settings: const AgentSettings(
      requireBiometricForRisky: true,
      stacksDirectory: '/opt/stacks',
      pushRelayStatus: 'not_configured',
    ),
    devices: <DeviceInfo>[
      DeviceInfo(
        id: 'dev-1',
        name: thisDeviceLabel(),
        role: ServerRole.admin,
        lastSeenAt: DateTime.now(),
        isSelf: true,
      ),
      DeviceInfo(
        id: 'dev-2',
        name: 'Ops iPad',
        role: ServerRole.operator,
        lastSeenAt: _ago(const Duration(days: 1)),
        isSelf: false,
        hasPushToken: true,
      ),
      DeviceInfo(
        id: 'dev-3',
        name: 'On-call pixel',
        role: ServerRole.viewer,
        lastSeenAt: _ago(const Duration(days: 3)),
        isSelf: false,
      ),
    ],
    update: const AgentUpdate(
      current: '1.4.2',
      latest: '1.5.0',
      available: true,
      releaseNotesUrl: 'https://example.com/agent/releases/1.5.0',
      selfUpdateStatus: 'ready',
    ),
    activity: <ActivityEntry>[
      ActivityEntry(
        id: 'act-seed-1',
        time: _ago(const Duration(minutes: 6)),
        action: 'POST /v1/containers/{id}/restart',
        target: 'nginx-proxy',
        result: 'ok',
        deviceId: 'dev-1',
        deviceName: thisDeviceLabel(),
        role: 'admin',
        status: 200,
      ),
      ActivityEntry(
        id: 'act-seed-2',
        time: _ago(const Duration(hours: 1)),
        action: 'POST /v1/images/pull',
        target: 'redis:7.2',
        result: 'ok',
        deviceId: 'dev-2',
        deviceName: 'Ops iPad',
        role: 'operator',
        status: 202,
      ),
      ActivityEntry(
        id: 'act-seed-3',
        time: _ago(const Duration(days: 2)),
        action: 'POST /v1/stacks/{name}/redeploy',
        target: 'monitoring',
        result: 'ok',
        deviceId: 'dev-1',
        deviceName: thisDeviceLabel(),
        role: 'admin',
        status: 202,
      ),
    ],
    logSeed: _logSeed(const <(int, String, String)>[
      (26, 'stdout', 'GET /v1/orders 200 18ms'),
      (25, 'stdout', 'GET /v1/orders/8812 200 11ms'),
      (23, 'stdout', 'POST /v1/checkout 201 142ms'),
      (20, 'stderr', 'upstream worker-queue slow: 2140ms'),
      (17, 'stdout', 'GET /healthz 200 1ms'),
      (15, 'stderr', 'dial tcp worker-queue:7000: connection refused'),
      (15, 'stderr', 'retrying job enqueue (attempt 2 of 5)'),
      (13, 'stdout', 'job enqueue ok after retry'),
      (11, 'stdout', 'GET /v1/products?page=2 200 23ms'),
      (9, 'stdout', 'GET /v1/cart 200 9ms'),
      (7, 'stdout', 'GET /healthz 200 1ms'),
      (4, 'stderr', 'rate limit near threshold for key pk_live_…4e1'),
      (2, 'stdout', 'PUT /v1/cart/items/3 200 31ms'),
      (1, 'stdout', 'GET /v1/orders 200 16ms'),
    ]),
  );
}

/// staging-1 — online but with nothing deployed through Compose or Swarm, so
/// the empty states get exercised.
MockWorld seedStaging() {
  final List<ContainerSummary> containers = <ContainerSummary>[
    _c(
      '11aa22bb33cc',
      'staging-web',
      'registry.example.com/api:2.8.1',
      state: ContainerState.running,
      uptime: const Duration(days: 2),
      cpu: 4,
      memory: 190 * _mb,
    ),
    _c(
      '44dd55ee66ff',
      'staging-worker',
      'registry.example.com/worker:2.8.1',
      state: ContainerState.running,
      uptime: const Duration(days: 2),
      cpu: 3,
      memory: 140 * _mb,
    ),
    _c(
      '77aa88bb99cc',
      'staging-db',
      'postgres:16',
      state: ContainerState.running,
      health: 'healthy',
      uptime: const Duration(days: 2),
      cpu: 5,
      memory: 820 * _mb,
    ),
    _c(
      'aa11bb22cc33',
      'staging-redis',
      'redis:7.2',
      state: ContainerState.running,
      uptime: const Duration(days: 2),
      cpu: 1,
      memory: 60 * _mb,
    ),
    _c(
      'dd44ee55ff66',
      'staging-mailhog',
      'mailhog/mailhog:1.0',
      state: ContainerState.running,
      uptime: const Duration(days: 9),
      cpu: 0.1,
      memory: 18 * _mb,
    ),
    _c(
      'ee77ff88aa99',
      'staging-proxy',
      'nginx:1.27',
      state: ContainerState.running,
      uptime: const Duration(days: 9),
      cpu: 0.3,
      memory: 30 * _mb,
    ),
    _c(
      'bb00cc11dd22',
      'staging-docs',
      'registry.example.com/docs:1.0',
      state: ContainerState.running,
      uptime: const Duration(days: 9),
      cpu: 0.1,
      memory: 22 * _mb,
    ),
    _c(
      'cc33dd44ee55',
      'staging-cron',
      'registry.example.com/cron:1.2',
      state: ContainerState.running,
      uptime: const Duration(days: 5),
      cpu: 0.2,
      memory: 26 * _mb,
    ),
    _c(
      'ff66aa77bb88',
      'staging-search',
      'opensearchproject/opensearch:2.16',
      state: ContainerState.running,
      uptime: const Duration(days: 5),
      cpu: 7,
      memory: 900 * _mb,
    ),
  ];

  return MockWorld(
    server: const Server(
      id: 'staging-1',
      name: 'staging-1',
      baseUrl: 'https://10.0.4.12:8443',
      certFingerprint:
          '3B:71:0C:2D:59:8E:4A:16:B7:03:FD:22:6E:91:A8:54:'
          '3F:C0:1D:7B:88:E5:2A:69:04:B1:73:DE:5C:82:C4:09',
      deviceId: 'dev-1',
      role: ServerRole.operator,
    ),
    reachable: true,
    info: SystemInfo(
      hostname: 'staging-1',
      dockerVersion: '26.1',
      agentVersion: '1.4.2',
      cpuCores: 4,
      memoryTotalBytes: 8 * _gb,
      diskTotalBytes: 200 * _gb,
      diskUsedBytes: 84 * _gb,
      swarmRole: 'inactive',
      agentUptimeSeconds: const Duration(days: 12).inSeconds,
      hostUptimeSeconds: const Duration(days: 12).inSeconds,
    ),
    stats: SystemStats(
      cpuPercent: 12,
      memoryUsedBytes: (3.04 * _gb).round(),
      memoryTotalBytes: 8 * _gb,
      diskUsedBytes: 84 * _gb,
      diskTotalBytes: 200 * _gb,
      containers: const ContainerCounts(running: 9, total: 9),
    ),
    containers: containers,
    containerDetails: <String, ContainerDetail>{},
    stacks: <ComposeStack>[],
    swarm: const SwarmInfo(
      active: false,
      nodeRole: 'inactive',
      isManager: false,
    ),
    services: <SwarmService>[],
    images: <DockerImage>[
      DockerImage(
        id: 'sha256:aa0100000000',
        tags: const <String>['registry.example.com/api:2.8.1'],
        sizeBytes: 412 * _mb,
        createdAt: _ago(const Duration(days: 2)),
        inUseBy: const <String>['staging-web'],
      ),
      DockerImage(
        id: 'sha256:aa0200000000',
        tags: const <String>['postgres:16'],
        sizeBytes: 431 * _mb,
        createdAt: _ago(const Duration(days: 62)),
        inUseBy: const <String>['staging-db'],
      ),
      DockerImage(
        id: 'sha256:aa0300000000',
        tags: const <String>['redis:7.2'],
        sizeBytes: 117 * _mb,
        createdAt: _ago(const Duration(days: 62)),
        inUseBy: const <String>['staging-redis'],
      ),
      DockerImage(
        id: 'sha256:aa0400000000',
        tags: const <String>['nginx:1.27'],
        sizeBytes: 108 * _mb,
        createdAt: _ago(const Duration(days: 9)),
        inUseBy: const <String>['staging-proxy'],
      ),
    ],
    imageSummary: const ImageList(
      images: <DockerImage>[],
      totalCount: 4,
      totalBytes: 1119879168,
      reclaimableBytes: 0,
    ),
    volumes: <VolumeInfo>[
      VolumeInfo(
        name: 'staging_pgdata',
        driver: 'local',
        sizeBytes: 6 * _gb,
        mountedBy: const <String>['staging-db'],
        lastUsed: _ago(const Duration(days: 2)),
      ),
      VolumeInfo(
        name: 'staging_redis',
        driver: 'local',
        sizeBytes: 220 * _mb,
        mountedBy: const <String>['staging-redis'],
        lastUsed: _ago(const Duration(days: 2)),
      ),
    ],
    networks: <NetworkInfo>[
      const NetworkInfo(
        id: 'net-staging',
        name: 'staging_default',
        driver: 'bridge',
        subnets: <String>['172.24.0.0/16'],
        scope: 'local',
        attached: 9,
        isDefault: false,
      ),
      const NetworkInfo(
        id: 'net-staging-bridge',
        name: 'bridge',
        driver: 'bridge',
        subnets: <String>['172.17.0.0/16'],
        scope: 'local',
        attached: 0,
        isDefault: true,
      ),
    ],
    alerts: <AlertInfo>[],
    rules: _defaultRules(saturationOn: false),
    registries: <RegistryInfo>[],
    settings: const AgentSettings(
      requireBiometricForRisky: false,
      stacksDirectory: '/srv/stacks',
      pushRelayStatus: 'not_configured',
    ),
    devices: <DeviceInfo>[
      DeviceInfo(
        id: 'dev-1',
        name: thisDeviceLabel(),
        role: ServerRole.operator,
        lastSeenAt: DateTime.now(),
        isSelf: true,
      ),
    ],
    update: const AgentUpdate(
      current: '1.4.2',
      latest: 'unknown',
      available: false,
    ),
    activity: <ActivityEntry>[
      ActivityEntry(
        id: 'act-staging-1',
        time: _ago(const Duration(hours: 3)),
        action: 'POST /v1/containers/{id}/restart',
        target: 'staging-web',
        result: 'ok',
        deviceId: 'dev-1',
        deviceName: thisDeviceLabel(),
        role: 'operator',
        status: 200,
      ),
    ],
    logSeed: _logSeed(const <(int, String, String)>[
      (12, 'stdout', 'listening on :8080'),
      (9, 'stdout', 'GET /healthz 200 1ms'),
    ]),
  );
}

/// backup-nas — unreachable, so every screen shows its error state.
MockWorld seedOffline() {
  return MockWorld(
    server: const Server(
      id: 'backup-nas',
      name: 'backup-nas',
      baseUrl: 'https://192.168.1.40:8443',
      certFingerprint:
          'C1:04:9E:35:7A:C8:20:6B:D4:18:F2:60:3C:A9:57:11:'
          '8D:22:B6:4E:05:F1:9C:38:6A:D0:47:23:BE:15:7D:B2',
      deviceId: 'dev-1',
      role: ServerRole.admin,
    ),
    reachable: false,
    offlineReason: 'Agent unreachable. Last seen 2 h ago.',
    info: const SystemInfo(
      hostname: 'backup-nas',
      dockerVersion: '25.0',
      agentVersion: '1.3.8',
      cpuCores: 2,
      memoryTotalBytes: 4 * _gb,
      diskTotalBytes: 8000 * _gb,
      diskUsedBytes: 0,
      swarmRole: 'inactive',
      agentUptimeSeconds: 0,
      hostUptimeSeconds: 0,
    ),
    stats: const SystemStats(
      cpuPercent: 0,
      memoryUsedBytes: 0,
      memoryTotalBytes: 4 * _gb,
      diskUsedBytes: 0,
      diskTotalBytes: 8000 * _gb,
      containers: ContainerCounts(),
    ),
    containers: <ContainerSummary>[],
    containerDetails: <String, ContainerDetail>{},
    stacks: <ComposeStack>[],
    swarm: const SwarmInfo(
      active: false,
      nodeRole: 'inactive',
      isManager: false,
    ),
    services: <SwarmService>[],
    images: <DockerImage>[],
    imageSummary: const ImageList(
      images: <DockerImage>[],
      totalCount: 0,
      totalBytes: 0,
      reclaimableBytes: 0,
    ),
    volumes: <VolumeInfo>[],
    networks: <NetworkInfo>[],
    alerts: <AlertInfo>[],
    rules: <AlertRule>[],
    registries: <RegistryInfo>[],
    settings: const AgentSettings(
      requireBiometricForRisky: true,
      stacksDirectory: '/volume1/stacks',
      pushRelayStatus: 'not_configured',
    ),
    devices: <DeviceInfo>[],
    update: const AgentUpdate(
      current: '1.3.8',
      latest: 'unknown',
      available: false,
    ),
    activity: <ActivityEntry>[],
    logSeed: <LogLine>[],
  );
}

/// A freshly paired agent starts empty, which is another empty state to show.
MockWorld seedPaired({
  required String id,
  required String name,
  required String baseUrl,
}) {
  return MockWorld(
    server: Server(
      id: id,
      name: name,
      baseUrl: baseUrl,
      certFingerprint:
          'A4:E9:7C:10:3B:65:D2:8F:41:0A:96:BE:57:2D:C8:34:'
          '1F:70:AB:59:E3:06:8D:C1:75:42:9B:E0:13:6A:2F:5C',
      deviceId: 'dev-1',
      role: ServerRole.admin,
    ),
    reachable: true,
    info: SystemInfo(
      hostname: name,
      dockerVersion: '27.1',
      agentVersion: '1.5.0',
      cpuCores: 2,
      memoryTotalBytes: 4 * _gb,
      diskTotalBytes: 100 * _gb,
      diskUsedBytes: 6 * _gb,
      swarmRole: 'inactive',
      agentUptimeSeconds: const Duration(minutes: 2).inSeconds,
      hostUptimeSeconds: const Duration(days: 3).inSeconds,
    ),
    stats: SystemStats(
      cpuPercent: 2,
      memoryUsedBytes: (0.4 * _gb).round(),
      memoryTotalBytes: 4 * _gb,
      diskUsedBytes: 6 * _gb,
      diskTotalBytes: 100 * _gb,
      containers: const ContainerCounts(),
    ),
    containers: <ContainerSummary>[],
    containerDetails: <String, ContainerDetail>{},
    stacks: <ComposeStack>[],
    swarm: const SwarmInfo(
      active: false,
      nodeRole: 'inactive',
      isManager: false,
    ),
    services: <SwarmService>[],
    images: <DockerImage>[],
    imageSummary: const ImageList(
      images: <DockerImage>[],
      totalCount: 0,
      totalBytes: 0,
      reclaimableBytes: 0,
    ),
    volumes: <VolumeInfo>[],
    networks: <NetworkInfo>[],
    alerts: <AlertInfo>[],
    rules: _defaultRules(),
    registries: <RegistryInfo>[],
    settings: const AgentSettings(
      requireBiometricForRisky: true,
      stacksDirectory: '/opt/stacks',
      pushRelayStatus: 'not_configured',
    ),
    devices: <DeviceInfo>[
      DeviceInfo(
        id: 'dev-1',
        name: thisDeviceLabel(),
        role: ServerRole.admin,
        lastSeenAt: DateTime.now(),
        isSelf: true,
      ),
    ],
    update: const AgentUpdate(
      current: '1.5.0',
      latest: 'unknown',
      available: false,
    ),
    activity: <ActivityEntry>[
      ActivityEntry(
        id: 'act-pair-1',
        time: DateTime.now(),
        action: 'POST /v1/pair',
        target: thisDeviceLabel(),
        result: 'ok',
        deviceId: 'dev-1',
        deviceName: thisDeviceLabel(),
        role: 'admin',
        status: 201,
      ),
    ],
    logSeed: <LogLine>[],
  );
}
