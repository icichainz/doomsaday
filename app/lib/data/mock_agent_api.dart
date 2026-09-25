import 'dart:async';
import 'dart:math';

import 'agent_api.dart';
import 'exec_session.dart';
import 'mock_seed.dart';
import 'models.dart';

/// In-memory agent seeded with the sample data from `design/`.
///
/// This is demo mode. State is mutable, so starting a container moves the
/// counts on every screen, scaling a service changes its replicas and pruning
/// really removes the rows. Every shape matches what [HttpAgentApi] parses out
/// of the real agent, so the screens cannot tell the two apart.
class MockAgentApi implements AgentApi {
  MockAgentApi(this.world);

  final MockWorld world;

  final Random _random = Random(7);
  final Map<String, Job> _jobs = <String, Job>{};
  final Map<String, StreamController<Job>> _jobStreams =
      <String, StreamController<Job>>{};
  int _jobCounter = 0;
  int _logCounter = 0;

  /// How many log streams this agent is currently serving. The log wall must
  /// bring this back to zero when a pane closes or the wall goes away.
  int openLogStreams = 0;

  /// Every `X-Confirmed` value this agent was given for a risky call, in
  /// order, so a test can see biometric and typed apart.
  final List<Confirmed> confirmations = <Confirmed>[];

  Server get server => world.server;

  /// The Retry button on the Servers screen. The offline agent stays offline so
  /// the failure path is always visible.
  Future<bool> retry() async {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    return world.reachable;
  }

  @override
  void dispose() {
    for (final StreamController<Job> controller in _jobStreams.values) {
      if (!controller.isClosed) controller.close();
    }
    _jobStreams.clear();
  }

  Future<T> _call<T>(T Function() body, {int ms = 220}) async {
    await Future<void>.delayed(
      Duration(milliseconds: ms + _random.nextInt(120)),
    );
    if (!world.reachable) throw _unreachable();
    return body();
  }

  AgentException _unreachable() => AgentException(
    'agent_unreachable',
    world.offlineReason ?? 'The agent could not be reached.',
    status: 502,
  );

  void _requireRole(ServerRole minimum) {
    final ServerRole role = world.server.role;
    final bool ok = switch (minimum) {
      ServerRole.viewer => true,
      ServerRole.operator => role.canOperate,
      ServerRole.admin => role.isAdmin,
    };
    if (ok) return;
    throw AgentException(
      'forbidden',
      "This device's role does not allow that action.",
      status: 403,
      details: <String, Object?>{
        'role': role.name,
        'required_role': minimum.name,
      },
    );
  }

  /// Mirrors the agent's `428` rule for the risky calls in API_NOTES §26.
  /// `typed` is accepted alongside `biometric`, which is what the agent takes
  /// from a Mac with no Touch ID.
  void _requireConfirmation(Confirmed confirmed) {
    confirmations.add(confirmed);
    if (!world.settings.requireBiometricForRisky || confirmed.isConfirmed) {
      return;
    }
    throw const AgentException(
      'confirmation_required',
      'This action needs a confirmation.',
      status: 428,
      details: <String, Object?>{
        'header': 'X-Confirmed',
        'accepted': <String>['biometric', 'typed'],
      },
    );
  }

  ContainerSummary _find(String id) => world.containers.firstWhere(
    (ContainerSummary c) => c.id == id,
    orElse: () => throw AgentException(
      'container_not_found',
      'No container with id $id.',
      status: 404,
    ),
  );

  void _replace(ContainerSummary next) {
    final int index = world.containers.indexWhere(
      (ContainerSummary c) => c.id == next.id,
    );
    world.containers[index] = next;
    world.recountContainers();
  }

  // --- system ------------------------------------------------------------

  @override
  Future<bool> health() async {
    await Future<void>.delayed(const Duration(milliseconds: 180));
    return world.reachable;
  }

  @override
  Future<MeInfo?> me() => _call(
    () => MeInfo(
      deviceId: world.server.deviceId,
      deviceName: 'This phone',
      role: world.server.role,
      certFingerprint: world.server.certFingerprint,
      pairedDevices: world.devices.length,
      agentVersion: world.info.agentVersion,
    ),
    ms: 120,
  );

  @override
  Future<SystemInfo> system() => _call(() => world.info);

  @override
  Future<SystemStats> systemStats() => _call(_drift);

  SystemStats _drift() {
    final SystemStats s = world.stats;
    double cpu = s.cpuPercent + (_random.nextDouble() - 0.5) * 4;
    cpu = cpu.clamp(1, 99);
    int memory =
        s.memoryUsedBytes +
        ((_random.nextDouble() - 0.5) * 220 * 1024 * 1024).round();
    memory = memory.clamp(
      (s.memoryTotalBytes * 0.05).round(),
      s.memoryTotalBytes,
    );
    world.stats = s.copyWith(cpuPercent: cpu, memoryUsedBytes: memory);
    return world.stats;
  }

  @override
  Stream<SystemStats> systemStatsStream({
    Duration interval = kDefaultStatsInterval,
  }) async* {
    if (!world.reachable) throw _unreachable();
    yield world.stats;
    while (true) {
      await Future<void>.delayed(interval);
      yield _drift();
    }
  }

  @override
  Stream<DockerEvent> dockerEvents() async* {
    if (!world.reachable) throw _unreachable();
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 12));
      yield DockerEvent(
        time: DateTime.now(),
        type: 'container',
        action: 'health_status: healthy',
        actorId: world.containers.isEmpty ? '' : world.containers.first.id,
        actorName: world.containers.isEmpty ? '' : world.containers.first.name,
      );
    }
  }

  @override
  Future<List<ActivityEntry>> activity({String? actor, DateTime? since}) =>
      _call(() {
        Iterable<ActivityEntry> rows = world.activity;
        if (actor != null && actor.isNotEmpty) {
          rows = rows.where((ActivityEntry a) => a.deviceId == actor);
        }
        if (since != null) {
          rows = rows.where((ActivityEntry a) => a.time.isAfter(since));
        }
        return rows.toList(growable: false);
      });

  // --- containers --------------------------------------------------------

  @override
  Future<List<ContainerSummary>> containers({
    ContainerState? state,
    String? stack,
    String? query,
  }) => _call(() {
    Iterable<ContainerSummary> rows = world.containers;
    if (state != null) {
      rows = rows.where(
        (ContainerSummary c) =>
            state.isRunning ? c.state.isRunning : !c.state.isRunning,
      );
    }
    if (stack != null && stack.isNotEmpty) {
      rows = rows.where((ContainerSummary c) => c.stack == stack);
    }
    if (query != null && query.isNotEmpty) {
      final String q = query.toLowerCase();
      rows = rows.where(
        (ContainerSummary c) =>
            c.name.toLowerCase().contains(q) ||
            c.image.toLowerCase().contains(q),
      );
    }
    return rows.toList(growable: false);
  });

  @override
  Future<ContainerDetail> container(String id) => _call(() {
    final ContainerSummary summary = _find(id);
    final ContainerDetail? known = world.containerDetails[id];
    if (known != null) {
      return ContainerDetail(
        summary: summary,
        networks: known.networks,
        mounts: known.mounts,
        restartPolicy: known.restartPolicy,
        envNames: known.envNames,
      );
    }
    return ContainerDetail(
      summary: summary,
      networks: <NetworkAttachment>[
        NetworkAttachment(
          name: summary.stack.isEmpty ? 'bridge' : '${summary.stack}_default',
        ),
      ],
      mounts: const <MountInfo>[],
      restartPolicy: 'unless-stopped',
      envNames: const <String>['LOG_LEVEL', 'TZ'],
    );
  });

  @override
  Future<Map<String, String>> containerEnv(String id) => _call(() {
    _requireRole(ServerRole.admin);
    final ContainerDetail? known = world.containerDetails[id];
    final List<String> names =
        known?.envNames ?? const <String>['LOG_LEVEL', 'TZ'];
    return <String, String>{for (final String n in names) n: '••••••••'};
  });

  @override
  Stream<ContainerStats> containerStatsStream(
    String id, {
    Duration interval = kDefaultStatsInterval,
  }) async* {
    final ContainerSummary base = _find(id);
    double cpu = base.cpuPercent;
    int memory = base.memoryBytes;
    final int limit = base.memoryLimitBytes == 0
        ? 2 * 1024 * 1024 * 1024
        : base.memoryLimitBytes;
    while (true) {
      cpu = (cpu + (_random.nextDouble() - 0.5) * 3).clamp(0.1, 99);
      memory =
          (memory + ((_random.nextDouble() - 0.5) * 24 * 1024 * 1024).round())
              .clamp(8 * 1024 * 1024, limit);
      yield ContainerStats(
        cpuPercent: cpu,
        memoryBytes: memory,
        memoryPercent: memory / limit * 100,
        memoryLimitBytes: limit,
        netInBytesPerSecond: (1.2 * 1024 * 1024 + _random.nextInt(400 * 1024))
            .round(),
        netOutBytesPerSecond: 340 * 1024 + _random.nextInt(120 * 1024),
      );
      await Future<void>.delayed(interval);
    }
  }

  @override
  Future<void> startContainer(String id) => _call(() {
    _requireRole(ServerRole.operator);
    final ContainerSummary c = _find(id);
    _replace(
      c.copyWith(
        state: ContainerState.running,
        startedAt: DateTime.now(),
        uptimeSeconds: 0,
        cpuPercent: 0.2,
        memoryBytes: max(c.memoryBytes, 24 * 1024 * 1024),
      ),
    );
    world.addActivity('POST /v1/containers/{id}/start', c.name);
  }, ms: 500);

  @override
  Future<void> stopContainer(
    String id, {
    int timeout = 10,
    Confirmed confirmed = Confirmed.none,
  }) => _call(() {
    _requireRole(ServerRole.operator);
    _requireConfirmation(confirmed);
    final ContainerSummary c = _find(id);
    _replace(
      c.copyWith(
        state: ContainerState.exited,
        exitCode: 0,
        finishedAt: DateTime.now(),
        uptimeSeconds: 0,
        cpuPercent: 0,
      ),
    );
    world.addActivity('POST /v1/containers/{id}/stop', c.name);
  }, ms: 500);

  @override
  Future<void> restartContainer(String id, {int timeout = 10}) => _call(() {
    _requireRole(ServerRole.operator);
    final ContainerSummary c = _find(id);
    _replace(
      c.copyWith(
        state: ContainerState.running,
        startedAt: DateTime.now(),
        uptimeSeconds: 0,
        restartCount: 0,
        cpuPercent: 0.5,
        memoryBytes: max(c.memoryBytes, 24 * 1024 * 1024),
      ),
    );
    world.addActivity('POST /v1/containers/{id}/restart', c.name);
  }, ms: 700);

  @override
  Future<void> pauseContainer(String id, {required bool paused}) => _call(() {
    _requireRole(ServerRole.operator);
    final ContainerSummary c = _find(id);
    _replace(
      c.copyWith(
        state: paused ? ContainerState.paused : ContainerState.running,
        startedAt: paused ? c.startedAt : DateTime.now(),
      ),
    );
  });

  @override
  Future<void> removeContainer(
    String id, {
    bool force = false,
    bool volumes = false,
    Confirmed confirmed = Confirmed.none,
  }) => _call(() {
    _requireRole(ServerRole.admin);
    _requireConfirmation(confirmed);
    final ContainerSummary c = _find(id);
    if (c.state.isRunning && !force) {
      throw const AgentException(
        'conflict',
        'Stop the container first.',
        status: 409,
      );
    }
    world.containers.removeWhere((ContainerSummary x) => x.id == id);
    world.recountContainers();
    world.addActivity('DELETE /v1/containers/{id}', c.name);
  }, ms: 500);

  @override
  Future<ContainerImpact> containerImpact(String id) => _call(() {
    final ContainerSummary c = _find(id);
    final List<ImpactRef> sameStack = world.containers
        .where(
          (ContainerSummary x) =>
              x.stack.isNotEmpty && x.stack == c.stack && x.id != c.id,
        )
        .map(
          (ContainerSummary x) => ImpactRef(
            id: x.id,
            name: x.name,
            state: x.state.name,
            reason: 'same_stack',
          ),
        )
        .toList(growable: false);
    return ContainerImpact(
      publishedPorts: c.ports
          .where((PortMapping p) => p.published)
          .toList(growable: false),
      dependents: sameStack.take(2).toList(growable: false),
      sameStack: sameStack,
    );
  }, ms: 140);

  @override
  Future<List<LogLine>> logs(String id, {int tail = 200, String? query}) =>
      _call(() {
        if (query == null || query.isEmpty) return world.logSeed;
        final String q = query.toLowerCase();
        return world.logSeed
            .where((LogLine l) => l.line.toLowerCase().contains(q))
            .toList(growable: false);
      });

  static const List<String> _logTemplates = <String>[
    'GET /v1/orders 200 %dms',
    'GET /v1/cart 200 %dms',
    'POST /v1/checkout 201 %dms',
    'GET /healthz 200 1ms',
    'PUT /v1/cart/items/2 200 %dms',
    'GET /v1/products?page=4 200 %dms',
  ];

  @override
  Stream<LogLine> logStream(String id) async* {
    openLogStreams++;
    try {
      yield* _logLines();
    } finally {
      openLogStreams--;
    }
  }

  Stream<LogLine> _logLines() async* {
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      _logCounter++;
      final DateTime now = DateTime.now();
      if (_logCounter % 9 == 0) {
        yield LogLine(
          at: now,
          stream: 'stderr',
          line: 'dial tcp worker-queue:7000: connection refused',
        );
      } else if (_logCounter % 5 == 0) {
        yield LogLine(
          at: now,
          stream: 'stderr',
          line: 'upstream worker-queue slow: ${1400 + _random.nextInt(900)}ms',
        );
      } else {
        final String template =
            _logTemplates[_logCounter % _logTemplates.length];
        yield LogLine(
          at: now,
          stream: 'stdout',
          line: template.replaceFirst('%d', '${4 + _random.nextInt(140)}'),
        );
      }
    }
  }

  @override
  Future<ExecSession> exec(
    String id, {
    String? shell,
    int cols = 80,
    int rows = 24,
  }) async {
    _requireRole(ServerRole.admin);
    final ContainerSummary c = _find(id);
    if (!c.state.isRunning) {
      throw const AgentException(
        'conflict',
        'An interactive shell needs a running container.',
        status: 409,
      );
    }
    world.addActivity('WS /v1/containers/{id}/exec', c.name);
    return _MockExecSession(c.name);
  }

  // --- stacks ------------------------------------------------------------

  @override
  Future<List<ComposeStack>> stacks() =>
      _call(() => List<ComposeStack>.unmodifiable(world.stacks));

  ComposeStack _stack(String name) => world.stacks.firstWhere(
    (ComposeStack s) => s.name == name,
    orElse: () => throw AgentException(
      'stack_not_found',
      'No stack called $name.',
      status: 404,
    ),
  );

  void _setStack(ComposeStack next) {
    final int i = world.stacks.indexWhere(
      (ComposeStack s) => s.name == next.name,
    );
    world.stacks[i] = next;
  }

  List<StackService> _allUp(ComposeStack stack) => stack.services
      .map(
        (StackService s) =>
            StackService(name: s.name, running: s.total, total: s.total),
      )
      .toList(growable: false);

  Future<Job> _stackAction(
    String name,
    String type,
    List<String> steps, {
    required void Function(ComposeStack stack) onDone,
    ServerRole role = ServerRole.operator,
  }) async {
    _requireRole(role);
    final ComposeStack stack = _stack(name);
    if (!stack.configOnDisk) {
      throw AgentException(
        'conflict',
        'No compose file was found for $name, so it cannot be driven from here.',
        status: 409,
      );
    }
    return _startJob(type, name, steps, onDone: () => onDone(stack));
  }

  @override
  Future<Job> stackUp(String name) => _stackAction(
    name,
    'stack_up',
    <String>[
      'Creating network ${name}_default',
      'Creating containers',
      'Waiting for health checks',
    ],
    onDone: (ComposeStack stack) {
      _setStack(
        stack.copyWith(
          servicesUp: stack.servicesTotal,
          services: _allUp(stack),
        ),
      );
      world.addActivity('POST /v1/stacks/{name}/up', name);
    },
  );

  @override
  Future<Job> stackRedeploy(String name) => _stackAction(
    name,
    'stack_redeploy',
    <String>[
      'Pulling images',
      'Recreating services',
      'Waiting for health checks',
      'Removing old containers',
    ],
    onDone: (ComposeStack stack) {
      _setStack(
        stack.copyWith(
          servicesUp: stack.servicesTotal,
          services: _allUp(stack),
        ),
      );
      world.addActivity('POST /v1/stacks/{name}/redeploy', name);
    },
  );

  @override
  Future<Job> stackRestart(String name) => _stackAction(
    name,
    'stack_restart',
    <String>['Stopping services', 'Starting services'],
    onDone: (ComposeStack stack) {
      _setStack(
        stack.copyWith(
          servicesUp: stack.servicesTotal,
          services: _allUp(stack),
        ),
      );
      world.addActivity('POST /v1/stacks/{name}/restart', name);
    },
  );

  @override
  Future<Job> stackDown(String name, {Confirmed confirmed = Confirmed.none}) {
    _requireRole(ServerRole.admin);
    _requireConfirmation(confirmed);
    return _stackAction(
      name,
      'stack_down',
      <String>[
        'Stopping containers',
        'Removing containers',
        'Removing network ${name}_default',
      ],
      role: ServerRole.admin,
      onDone: (ComposeStack stack) {
        _setStack(
          stack.copyWith(
            servicesUp: 0,
            services: stack.services
                .map(
                  (StackService s) =>
                      StackService(name: s.name, running: 0, total: s.total),
                )
                .toList(growable: false),
          ),
        );
        for (int i = 0; i < world.containers.length; i++) {
          if (world.containers[i].stack == name) {
            world.containers[i] = world.containers[i].copyWith(
              state: ContainerState.exited,
              exitCode: 0,
              finishedAt: DateTime.now(),
              uptimeSeconds: 0,
              cpuPercent: 0,
            );
          }
        }
        world.recountContainers();
        world.addActivity('POST /v1/stacks/{name}/down', name);
      },
    );
  }

  // --- swarm -------------------------------------------------------------

  @override
  Future<SwarmInfo> swarm() => _call(() => world.swarm);

  @override
  Future<List<SwarmService>> services() => _call(() {
    if (!world.swarm.isManager) {
      throw const AgentException(
        'not_a_manager',
        'This host is not a Swarm manager.',
        status: 409,
      );
    }
    return List<SwarmService>.unmodifiable(world.services);
  });

  int _serviceIndex(String id) {
    final int i = world.services.indexWhere((SwarmService s) => s.id == id);
    if (i < 0) {
      throw AgentException(
        'service_not_found',
        'No service with id $id.',
        status: 404,
      );
    }
    return i;
  }

  @override
  Future<void> scaleService(String id, int replicas) => _call(() {
    _requireRole(ServerRole.operator);
    final int i = _serviceIndex(id);
    final SwarmService s = world.services[i];
    final int desired = replicas.clamp(0, 20);
    world.services[i] = s.copyWith(
      desired: desired,
      running: min(s.running, desired),
      updateState: s.running == desired ? 'completed' : 'updating',
    );
    world.addActivity('POST /v1/services/{id}/scale', s.name);
  }, ms: 320);

  @override
  Future<Job> updateService(
    String id, {
    String? image,
    bool force = false,
  }) async {
    _requireRole(ServerRole.operator);
    final int i = _serviceIndex(id);
    final SwarmService s = world.services[i];
    return _startJob(
      'service_update',
      s.name,
      <String>[
        'Pulling ${image ?? s.image}',
        'Rolling out task 1',
        'Rolling out task 2',
        'Update completed',
      ],
      onDone: () {
        world.services[i] = world.services[i].copyWith(
          running: world.services[i].desired,
          updateState: 'completed',
        );
        world.addActivity('POST /v1/services/{id}/update', s.name);
      },
    );
  }

  @override
  Future<Job> rollbackService(String id) async {
    _requireRole(ServerRole.operator);
    final int i = _serviceIndex(id);
    final SwarmService s = world.services[i];
    return _startJob(
      'service_rollback',
      s.name,
      <String>['Reverting to the previous spec', 'Rolling out tasks'],
      onDone: () {
        world.services[i] = world.services[i].copyWith(
          running: world.services[i].desired,
          updateState: 'completed',
        );
        world.addActivity('POST /v1/services/{id}/rollback', s.name);
      },
    );
  }

  // --- images, volumes, networks -----------------------------------------

  @override
  Future<ImageList> images() => _call(
    () => ImageList(
      images: List<DockerImage>.unmodifiable(world.images),
      totalCount: world.imageSummary.totalCount,
      totalBytes: world.imageSummary.totalBytes,
      reclaimableBytes: world.imageSummary.reclaimableBytes,
    ),
  );

  void _setImageSummary({int count = 0, int bytes = 0, int? reclaimable}) {
    world.imageSummary = ImageList(
      images: const <DockerImage>[],
      totalCount: max(0, world.imageSummary.totalCount + count),
      totalBytes: max(0, world.imageSummary.totalBytes + bytes),
      reclaimableBytes:
          reclaimable ?? max(0, world.imageSummary.reclaimableBytes + bytes),
    );
  }

  @override
  Future<Job> pullImage(String ref) async {
    _requireRole(ServerRole.operator);
    return _startJob(
      'image_pull',
      ref,
      <String>[
        'Resolving manifest',
        'Downloading layer 1 of 4',
        'Downloading layer 2 of 4',
        'Downloading layer 3 of 4',
        'Downloading layer 4 of 4',
        'Extracting',
      ],
      onDone: () {
        world.images.insert(
          0,
          DockerImage(
            id: 'sha256:${ref.hashCode.toRadixString(16).padLeft(12, '0')}',
            tags: <String>[ref],
            sizeBytes: 180 * 1024 * 1024,
            createdAt: DateTime.now(),
            inUseBy: const <String>[],
          ),
        );
        _setImageSummary(count: 1, bytes: 180 * 1024 * 1024);
        world.addActivity('POST /v1/images/pull', ref);
      },
    );
  }

  @override
  Future<void> removeImage(
    String id, {
    bool force = false,
    Confirmed confirmed = Confirmed.none,
  }) => _call(() {
    _requireRole(ServerRole.admin);
    _requireConfirmation(confirmed);
    final DockerImage image = world.images.firstWhere(
      (DockerImage i) => i.id == id,
      orElse: () => throw AgentException(
        'image_not_found',
        'No image with id $id.',
        status: 404,
      ),
    );
    if (image.inUse && !force) {
      throw const AgentException(
        'conflict',
        'A container is using this image.',
        status: 409,
      );
    }
    world.images.removeWhere((DockerImage i) => i.id == id);
    _setImageSummary(count: -1, bytes: -image.sizeBytes);
    world.addActivity('DELETE /v1/images/{id}', image.ref);
  }, ms: 400);

  @override
  Future<Job> pruneImages({
    bool danglingOnly = true,
    Confirmed confirmed = Confirmed.none,
  }) async {
    _requireRole(ServerRole.admin);
    _requireConfirmation(confirmed);
    final List<DockerImage> unused = world.images
        .where((DockerImage i) => !i.inUse)
        .toList(growable: false);
    final int freed = unused.fold(0, (int a, DockerImage i) => a + i.sizeBytes);
    return _startJob(
      'image_prune',
      'images',
      <String>[
        'Listing unused images',
        'Removing ${unused.length} images',
        'Reclaimed ${formatBytes(freed)}',
      ],
      onDone: () {
        world.images.removeWhere((DockerImage i) => !i.inUse);
        _setImageSummary(count: -unused.length, bytes: -freed, reclaimable: 0);
        world.addActivity('POST /v1/images/prune', 'images');
      },
    );
  }

  @override
  Future<VolumeList> volumes() =>
      _call(() => VolumeList.derived(List<VolumeInfo>.of(world.volumes)));

  @override
  Future<void> createVolume(String name, {String driver = 'local'}) =>
      _call(() {
        _requireRole(ServerRole.admin);
        if (world.volumes.any((VolumeInfo v) => v.name == name)) {
          throw const AgentException(
            'conflict',
            'A volume with that name already exists.',
            status: 409,
          );
        }
        world.volumes.add(
          VolumeInfo(
            name: name,
            driver: driver,
            sizeBytes: 0,
            mountedBy: const <String>[],
          ),
        );
        world.addActivity('POST /v1/volumes', name);
      }, ms: 320);

  @override
  Future<void> removeVolume(
    String name, {
    Confirmed confirmed = Confirmed.none,
  }) => _call(() {
    _requireRole(ServerRole.admin);
    _requireConfirmation(confirmed);
    final VolumeInfo v = world.volumes.firstWhere(
      (VolumeInfo x) => x.name == name,
      orElse: () => throw AgentException(
        'volume_not_found',
        'No volume called $name.',
        status: 404,
      ),
    );
    if (v.mounted) {
      throw const AgentException(
        'conflict',
        'The volume is mounted by a container.',
        status: 409,
      );
    }
    world.volumes.remove(v);
    world.addActivity('DELETE /v1/volumes/{name}', name);
  }, ms: 380);

  @override
  Future<Job> pruneVolumes({Confirmed confirmed = Confirmed.none}) async {
    _requireRole(ServerRole.admin);
    _requireConfirmation(confirmed);
    final List<VolumeInfo> unused = world.volumes
        .where((VolumeInfo v) => !v.mounted)
        .toList(growable: false);
    final int freed = unused.fold(0, (int a, VolumeInfo v) => a + v.sizeBytes);
    return _startJob(
      'volume_prune',
      'volumes',
      <String>[
        'Listing unmounted volumes',
        'Removing ${unused.length} volumes',
        'Reclaimed ${formatBytes(freed)}',
      ],
      onDone: () {
        world.volumes.removeWhere((VolumeInfo v) => !v.mounted);
        world.addActivity('POST /v1/volumes/prune', 'volumes');
      },
    );
  }

  @override
  Future<NetworkList> networks() =>
      _call(() => NetworkList.derived(List<NetworkInfo>.of(world.networks)));

  @override
  Future<void> createNetwork(
    String name, {
    String driver = 'bridge',
    String? subnet,
  }) => _call(() {
    _requireRole(ServerRole.admin);
    world.networks.add(
      NetworkInfo(
        id: 'net-${name.hashCode.toRadixString(16)}',
        name: name,
        driver: driver,
        subnets: <String>[subnet ?? '172.30.0.0/16'],
        scope: driver == 'overlay' ? 'swarm' : 'local',
        attached: 0,
        isDefault: false,
      ),
    );
    world.addActivity('POST /v1/networks', name);
  }, ms: 320);

  @override
  Future<void> removeNetwork(
    String id, {
    Confirmed confirmed = Confirmed.none,
  }) => _call(() {
    _requireRole(ServerRole.admin);
    _requireConfirmation(confirmed);
    final NetworkInfo n = world.networks.firstWhere(
      (NetworkInfo x) => x.id == id,
      orElse: () => throw AgentException(
        'network_not_found',
        'No network with id $id.',
        status: 404,
      ),
    );
    if (n.attached > 0 || n.isDefault) {
      throw const AgentException(
        'conflict',
        'Containers are attached, or this is a default network.',
        status: 409,
      );
    }
    world.networks.remove(n);
    world.addActivity('DELETE /v1/networks/{id}', n.name);
  }, ms: 380);

  @override
  Future<Job> pruneNetworks({Confirmed confirmed = Confirmed.none}) async {
    _requireRole(ServerRole.admin);
    _requireConfirmation(confirmed);
    final List<NetworkInfo> unused = world.networks
        .where((NetworkInfo n) => n.removable)
        .toList(growable: false);
    return _startJob(
      'network_prune',
      'networks',
      <String>['Listing unused networks', 'Removing ${unused.length} networks'],
      onDone: () {
        world.networks.removeWhere((NetworkInfo n) => n.removable);
        world.addActivity('POST /v1/networks/prune', 'networks');
      },
    );
  }

  // --- alerts ------------------------------------------------------------

  @override
  Future<List<AlertInfo>> alerts({AlertState? state}) => _call(() {
    if (state == null) return List<AlertInfo>.unmodifiable(world.alerts);
    return world.alerts
        .where((AlertInfo a) => a.state == state)
        .toList(growable: false);
  });

  int _alertIndex(String id) {
    final int i = world.alerts.indexWhere((AlertInfo a) => a.id == id);
    if (i < 0) {
      throw AgentException(
        'alert_not_found',
        'No alert with id $id.',
        status: 404,
      );
    }
    return i;
  }

  @override
  Future<void> muteAlert(String id, {int minutes = 60}) => _call(() {
    _requireRole(ServerRole.operator);
    final int i = _alertIndex(id);
    final AlertInfo a = world.alerts[i];
    world.alerts[i] = AlertInfo(
      id: a.id,
      ruleId: a.ruleId,
      severity: a.severity,
      state: AlertState.muted,
      target: a.target,
      targetId: a.targetId,
      message: a.message,
      firstSeen: a.firstSeen,
      lastSeen: a.lastSeen,
      mutedUntil: DateTime.now().add(Duration(minutes: minutes)),
      count: a.count,
    );
    world.addActivity('POST /v1/alerts/{id}/mute', a.target);
  }, ms: 300);

  @override
  Future<void> resolveAlert(String id) => _call(() {
    _requireRole(ServerRole.operator);
    final int i = _alertIndex(id);
    final AlertInfo a = world.alerts[i];
    world.alerts[i] = AlertInfo(
      id: a.id,
      ruleId: a.ruleId,
      severity: a.severity,
      state: AlertState.resolved,
      target: a.target,
      targetId: a.targetId,
      message: a.message,
      firstSeen: a.firstSeen,
      lastSeen: a.lastSeen,
      resolvedAt: DateTime.now(),
      count: a.count,
    );
    world.addActivity('POST /v1/alerts/{id}/resolve', a.target);
  }, ms: 300);

  @override
  Future<List<AlertRule>> alertRules() =>
      _call(() => List<AlertRule>.unmodifiable(world.rules));

  @override
  Future<void> updateAlertRule(
    String id, {
    bool? enabled,
    double? threshold,
    int? windowSeconds,
  }) => _call(() {
    _requireRole(ServerRole.admin);
    final int i = world.rules.indexWhere((AlertRule r) => r.id == id);
    if (i < 0) {
      throw AgentException(
        'alert_rule_not_found',
        'No alert rule called $id.',
        status: 404,
      );
    }
    world.rules[i] = world.rules[i].copyWith(
      enabled: enabled,
      threshold: threshold,
      windowSeconds: windowSeconds,
    );
  }, ms: 200);

  // --- registries --------------------------------------------------------

  @override
  Future<List<RegistryInfo>> registries() =>
      _call(() => List<RegistryInfo>.unmodifiable(world.registries));

  @override
  Future<void> addRegistry({
    required String host,
    required String username,
    required String secret,
  }) => _call(() {
    _requireRole(ServerRole.admin);
    world.registries.add(
      RegistryInfo(
        id: 'reg-${host.hashCode.toRadixString(16)}',
        host: host,
        username: username,
        rawStatus: 'ok',
        statusAt: DateTime.now(),
      ),
    );
    world.addActivity('POST /v1/registries', host);
  }, ms: 520);

  int _registryIndex(String id) {
    final int i = world.registries.indexWhere((RegistryInfo r) => r.id == id);
    if (i < 0) {
      throw AgentException(
        'registry_not_found',
        'No registry with id $id.',
        status: 404,
      );
    }
    return i;
  }

  @override
  Future<void> updateRegistry(String id, {String? username, String? secret}) =>
      _call(() {
        _requireRole(ServerRole.admin);
        final int i = _registryIndex(id);
        final RegistryInfo r = world.registries[i];
        world.registries[i] = RegistryInfo(
          id: r.id,
          host: r.host,
          username: username ?? r.username,
          rawStatus: 'ok',
          statusAt: DateTime.now(),
        );
        world.addActivity('PATCH /v1/registries/{id}', r.host);
      }, ms: 520);

  @override
  Future<bool> testRegistry(String id) => _call(() {
    _requireRole(ServerRole.admin);
    final int i = _registryIndex(id);
    final RegistryInfo r = world.registries[i];
    final bool ok = r.hasCredential;
    world.registries[i] = RegistryInfo(
      id: r.id,
      host: r.host,
      username: r.username,
      rawStatus: ok ? 'ok' : 'unknown',
      statusAt: DateTime.now(),
      tokenExpiry: r.tokenExpiry,
    );
    world.addActivity('POST /v1/registries/{id}/test', r.host);
    return ok;
  }, ms: 700);

  @override
  Future<void> removeRegistry(String id) => _call(() {
    _requireRole(ServerRole.admin);
    final int i = _registryIndex(id);
    final RegistryInfo r = world.registries.removeAt(i);
    world.addActivity('DELETE /v1/registries/{id}', r.host);
  }, ms: 380);

  // --- settings, devices, update -----------------------------------------

  @override
  Future<AgentSettings> settings() => _call(() => world.settings);

  @override
  Future<AgentSettings> updateSettings({bool? requireBiometricForRisky}) =>
      _call(() {
        _requireRole(ServerRole.admin);
        world.settings = world.settings.copyWith(
          requireBiometricForRisky: requireBiometricForRisky,
        );
        world.addActivity('PATCH /v1/settings', 'settings');
        return world.settings;
      }, ms: 220);

  @override
  Future<List<DeviceInfo>> devices() =>
      _call(() => List<DeviceInfo>.unmodifiable(world.devices));

  int _deviceIndex(String id) {
    final int i = world.devices.indexWhere((DeviceInfo d) => d.id == id);
    if (i < 0) {
      throw AgentException(
        'device_not_found',
        'No device with id $id.',
        status: 404,
      );
    }
    return i;
  }

  void _refuseLastAdmin(DeviceInfo target, {required bool demoting}) {
    if (target.role != ServerRole.admin) return;
    final int admins = world.devices
        .where((DeviceInfo d) => d.role == ServerRole.admin)
        .length;
    if (admins > 1) return;
    throw AgentException(
      'conflict',
      demoting
          ? 'The last admin device cannot be demoted.'
          : 'The last admin device cannot be revoked.',
      status: 409,
    );
  }

  @override
  Future<DeviceInfo> updateDevice(
    String id, {
    ServerRole? role,
    String? pushToken,
  }) => _call(() {
    _requireRole(ServerRole.admin);
    final int i = _deviceIndex(id);
    final DeviceInfo d = world.devices[i];
    if (role != null && role != ServerRole.admin) {
      _refuseLastAdmin(d, demoting: true);
    }
    final DeviceInfo next = DeviceInfo(
      id: d.id,
      name: d.name,
      role: role ?? d.role,
      lastSeenAt: d.lastSeenAt,
      isSelf: d.isSelf,
      createdAt: d.createdAt,
      hasPushToken: pushToken != null || d.hasPushToken,
    );
    world.devices[i] = next;
    if (next.isSelf && role != null) {
      world.server = world.server.copyWith(role: role);
    }
    world.addActivity('PATCH /v1/devices/{id}', d.name);
    return next;
  }, ms: 220);

  @override
  Future<void> removeDevice(
    String id, {
    Confirmed confirmed = Confirmed.none,
  }) => _call(() {
    _requireRole(ServerRole.admin);
    _requireConfirmation(confirmed);
    final int i = _deviceIndex(id);
    final DeviceInfo d = world.devices[i];
    if (!d.isSelf) _refuseLastAdmin(d, demoting: false);
    world.devices.removeAt(i);
    world.addActivity('DELETE /v1/devices/{id}', d.name);
  }, ms: 320);

  @override
  Future<AgentUpdate> agentUpdate() => _call(() => world.update);

  @override
  Future<Job> startAgentUpdate() async {
    _requireRole(ServerRole.admin);
    return _startJob(
      'agent_update',
      world.update.latest,
      <String>[
        'Downloading ${world.update.latest}',
        'Verifying signature',
        'Restarting the agent',
        'Waiting for /health',
      ],
      onDone: () {
        world.info = SystemInfo(
          hostname: world.info.hostname,
          dockerVersion: world.info.dockerVersion,
          agentVersion: world.update.latest,
          cpuCores: world.info.cpuCores,
          memoryTotalBytes: world.info.memoryTotalBytes,
          diskTotalBytes: world.info.diskTotalBytes,
          diskUsedBytes: world.info.diskUsedBytes,
          swarmRole: world.info.swarmRole,
          agentUptimeSeconds: 0,
          hostUptimeSeconds: world.info.hostUptimeSeconds,
        );
        world.update = AgentUpdate(
          current: world.update.latest,
          latest: world.update.latest,
          available: false,
          releaseNotesUrl: world.update.releaseNotesUrl,
          selfUpdateStatus: world.update.selfUpdateStatus,
        );
        world.addActivity('POST /v1/agent/update', world.update.latest);
      },
    );
  }

  // --- jobs --------------------------------------------------------------

  @override
  Future<Job> job(String id) async =>
      _jobs[id] ??
      (throw AgentException(
        'job_not_found',
        'No job with id $id.',
        status: 404,
      ));

  @override
  Stream<Job> jobEvents(String id) =>
      _jobStreams[id]?.stream ?? const Stream<Job>.empty();

  Future<Job> _startJob(
    String type,
    String target,
    List<String> steps, {
    required void Function() onDone,
  }) async {
    if (!world.reachable) throw _unreachable();
    final String id = 'job-${++_jobCounter}';
    Job current = Job(
      id: id,
      type: type,
      target: target,
      status: JobStatus.running,
      progress: 0,
      progressLines: const <JobLine>[],
    );
    _jobs[id] = current;
    final StreamController<Job> controller = StreamController<Job>.broadcast();
    _jobStreams[id] = controller;

    int step = 0;
    Timer.periodic(const Duration(milliseconds: 520), (Timer timer) {
      if (step >= steps.length) {
        timer.cancel();
        onDone();
        current = current.copyWith(status: JobStatus.succeeded, progress: 1);
        _jobs[id] = current;
        controller.add(current);
        controller.close();
        return;
      }
      current = current.copyWith(
        progress: (step + 1) / (steps.length + 1),
        progressLines: <JobLine>[
          ...current.progressLines,
          JobLine(text: steps[step]),
        ],
      );
      _jobs[id] = current;
      controller.add(current);
      step++;
    });
    return current;
  }
}

/// A shell that behaves enough like one to exercise the terminal screen.
class _MockExecSession implements ExecSession {
  _MockExecSession(this.containerName) {
    _output.add('Demo shell on $containerName. Type "exit" to leave.\r\n');
    _output.add(r'/ # ');
  }

  final String containerName;
  final StreamController<String> _output = StreamController<String>.broadcast();
  final Completer<int?> _exit = Completer<int?>();

  @override
  Stream<String> get output => _output.stream;

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  void send(String data) {
    final String command = data.trim();
    if (command == 'exit') {
      if (!_exit.isCompleted) _exit.complete(0);
      if (!_output.isClosed) _output.close();
      return;
    }
    if (command.isNotEmpty) {
      _output.add(
        'demo mode: "$command" is not run against a real container\r\n',
      );
    }
    _output.add(r'/ # ');
  }

  @override
  void resize({required int cols, required int rows}) {}

  @override
  Future<void> close() async {
    if (!_exit.isCompleted) _exit.complete(null);
    if (!_output.isClosed) await _output.close();
  }
}
