/// The real client against `docs/agent-api.md` v1.1.
///
/// HTTPS with the agent's certificate pinned, `Authorization: Bearer <device
/// key>`, the `{items, next_cursor, total}` envelope with cursor paging, the
/// error envelope mapped onto [AgentException], SSE for every stream, a job
/// follower for `202 {job_id}` and `X-Confirmed` on risky calls.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'dart:io';

import 'agent_api.dart';
import 'exec_session.dart';
import 'models.dart';
import 'pinning.dart';
import 'sse.dart';

/// Asks the person to confirm a risky action, and reports how they did it.
/// Anything but [Confirmed.none] lets the app retry with `X-Confirmed`.
typedef ConfirmationHandler = Future<Confirmed> Function();

class HttpAgentApi implements AgentApi {
  HttpAgentApi({
    required String baseUrl,
    required this.deviceKey,
    required this.pinnedFingerprint,
    this.onConfirmationRequired,
    HttpClient? client,
    this.timeout = const Duration(seconds: 20),
  }) : base = _normalise(baseUrl) {
    assertTransportIsAllowed(base);
    _client = client ?? pinnedHttpClient(pinnedFingerprint);
  }

  /// `https://<host>:8443/v1`
  final Uri base;
  final String deviceKey;
  final String pinnedFingerprint;
  final Duration timeout;

  /// Set by the repository so a `428` can be answered without a round trip
  /// back through every screen.
  ConfirmationHandler? onConfirmationRequired;

  late final HttpClient _client;
  bool _closed = false;

  /// `POST /v1/pair` — the one unauthenticated write, so it does not go
  /// through the bearer-token path above. [client] is the trust-on-first-use
  /// client, which records the certificate the agent presents.
  ///
  /// Returns the `201` body: `device_key`, `device_id`, `role`,
  /// `cert_fingerprint` and `agent_version`.
  static Future<Map<String, Object?>> pair({
    required HttpClient client,
    required Uri baseUrl,
    required String token,
    required String deviceName,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final Uri url = Uri.parse('${_normalise(baseUrl.toString())}/pair');
    try {
      final HttpClientRequest request = await client
          .openUrl('POST', url)
          .timeout(timeout);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.write(
        jsonEncode(<String, Object?>{
          'token': token,
          'device_name': deviceName,
        }),
      );
      final HttpClientResponse response = await request.close().timeout(
        timeout,
      );
      final String text = await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(timeout);
      final _RawResponse raw = _RawResponse(
        response.statusCode,
        text,
        _retryAfter(response.headers.value(HttpHeaders.retryAfterHeader)),
      );
      if (raw.status >= 400) throw raw.toException();
      final Object? decoded = text.isEmpty ? null : jsonDecode(text);
      if (decoded is! Map<String, Object?>) {
        throw const AgentException(
          'pairing_failed',
          'The agent did not answer the pairing request with JSON.',
          status: 502,
        );
      }
      return decoded;
    } on TimeoutException {
      throw AgentException(
        'agent_unreachable',
        'The agent did not answer within ${timeout.inSeconds} s.',
        status: 502,
      );
    } on HandshakeException catch (error) {
      throw _pinFailure(error.message);
    } on SocketException catch (error) {
      throw AgentException(
        'agent_unreachable',
        'The agent could not be reached: ${error.osError?.message ?? error.message}.',
        status: 502,
      );
    } on FormatException {
      throw const AgentException(
        'pairing_failed',
        'The agent did not answer the pairing request with JSON.',
        status: 502,
      );
    }
  }

  /// Accepts `https://host:8443` as readily as `https://host:8443/v1`.
  static Uri _normalise(String baseUrl) {
    final String trimmed = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final Uri parsed = Uri.parse(
      trimmed.contains('://') ? trimmed : 'https://$trimmed',
    );
    if (parsed.path.endsWith('/v1')) return parsed;
    return parsed.replace(path: '${parsed.path}/v1');
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    // Not force: aborting a pooled keep-alive connection makes dart:io report
    // "Reading from a closed socket" to whichever call opened it, long after
    // that call has finished. A graceful close drops idle sockets quietly.
    _client.close();
  }

  // ------------------------------------------------------------- transport

  Uri _url(String path, [Map<String, String?>? query]) {
    final Uri url = Uri.parse('$base$path');
    if (query == null || query.isEmpty) return url;
    final Map<String, String> params = <String, String>{
      for (final MapEntry<String, String?> e in query.entries)
        if (e.value != null && e.value!.isNotEmpty) e.key: e.value!,
    };
    return params.isEmpty ? url : url.replace(queryParameters: params);
  }

  static String _seg(String value) => Uri.encodeComponent(value);

  /// Opens a request and keeps a late connection error from escaping.
  ///
  /// `dart:io` reports a pooled keep-alive connection that the peer closes
  /// later to the zone of whichever call opened it, long after that call has
  /// been answered. Unhandled, that takes the whole app down, so the connect
  /// runs in its own zone and anything that arrives after the request is
  /// settled is dropped.
  Future<HttpClientRequest> _open(String method, Uri url) {
    final Completer<HttpClientRequest> opened = Completer<HttpClientRequest>();
    runZonedGuarded(
      () {
        _client
            .openUrl(method, url)
            .then(
              (HttpClientRequest request) {
                if (!opened.isCompleted) opened.complete(request);
              },
              onError: (Object error, StackTrace stack) {
                if (!opened.isCompleted) opened.completeError(error, stack);
              },
            );
      },
      (Object error, StackTrace stack) {
        if (!opened.isCompleted) opened.completeError(error, stack);
      },
    );
    return opened.future;
  }

  /// One request, with the error envelope turned into an [AgentException] and
  /// a `428` answered through [onConfirmationRequired] exactly once.
  Future<Object?> _send(
    String method,
    String path, {
    Map<String, String?>? query,
    Object? body,
    Confirmed confirmed = Confirmed.none,
    bool notFoundIsNull = false,
  }) async {
    final _RawResponse response = await _raw(
      method,
      path,
      query: query,
      body: body,
      confirmed: confirmed,
    );

    if (response.status == 428 &&
        !confirmed.isConfirmed &&
        onConfirmationRequired != null) {
      final Confirmed answer = await onConfirmationRequired!();
      if (answer.isConfirmed) {
        return _send(
          method,
          path,
          query: query,
          body: body,
          confirmed: answer,
          notFoundIsNull: notFoundIsNull,
        );
      }
    }
    if (response.status == 404 && notFoundIsNull) return null;
    if (response.status >= 400) throw response.toException();
    if (response.body.isEmpty) return null;
    try {
      return jsonDecode(response.body);
    } on FormatException {
      throw AgentException(
        'bad_response',
        'The agent sent a response that is not JSON.',
        status: response.status,
      );
    }
  }

  Future<_RawResponse> _raw(
    String method,
    String path, {
    Map<String, String?>? query,
    Object? body,
    Confirmed confirmed = Confirmed.none,
  }) async {
    final Uri url = _url(path, query);
    try {
      final HttpClientRequest request = await _open(
        method,
        url,
      ).timeout(timeout);
      request.headers.set(HttpHeaders.authorizationHeader, bearer(deviceKey));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final String? confirmation = confirmed.header;
      if (confirmation != null) {
        request.headers.set('X-Confirmed', confirmation);
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final HttpClientResponse response = await request.close().timeout(
        timeout,
      );
      final String text = await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(timeout);
      return _RawResponse(
        response.statusCode,
        text,
        _retryAfter(response.headers.value(HttpHeaders.retryAfterHeader)),
      );
    } on TimeoutException {
      throw AgentException(
        'agent_unreachable',
        'The agent did not answer within ${timeout.inSeconds} s.',
        status: 502,
      );
    } on HandshakeException catch (error) {
      throw _pinFailure(error.message);
    } on TlsException catch (error) {
      throw _pinFailure(error.message);
    } on SocketException catch (error) {
      throw AgentException(
        'agent_unreachable',
        'The agent could not be reached: ${error.osError?.message ?? error.message}.',
        status: 502,
      );
    } on HttpException catch (error) {
      throw AgentException(
        'agent_unreachable',
        'The agent could not be reached: ${error.message}',
        status: 502,
      );
    }
  }

  static AgentException _pinFailure(String detail) => AgentException(
    'certificate_mismatch',
    'The agent presented a certificate that does not match the pinned '
        'fingerprint, so the connection was refused. ($detail)',
    status: 495,
  );

  static Duration? _retryAfter(String? header) {
    if (header == null) return null;
    final int? seconds = int.tryParse(header.trim());
    return seconds == null ? null : Duration(seconds: seconds);
  }

  Map<String, Object?> _object(Object? value) => value is Map<String, Object?>
      ? value
      : throw const AgentException(
          'bad_response',
          'The agent sent a response the app could not read.',
          status: 500,
        );

  // ----------------------------------------------------------- list paging

  /// Follows `next_cursor` until the agent stops sending one.
  Future<List<T>> _listAll<T>(
    String path,
    T Function(Map<String, Object?> json) parse, {
    Map<String, String?>? query,
    int maxPages = 20,
  }) async {
    final List<T> out = <T>[];
    String? cursor;
    for (int page = 0; page < maxPages; page++) {
      final Map<String, Object?> body = _object(
        await _send(
          'GET',
          path,
          query: <String, String?>{...?query, 'cursor': cursor},
        ),
      );
      out.addAll(_items(body).map(parse));
      cursor = body['next_cursor'] as String?;
      if (cursor == null || cursor.isEmpty) break;
    }
    return List<T>.unmodifiable(out);
  }

  static List<Map<String, Object?>> _items(Map<String, Object?> body) {
    final Object? items = body['items'];
    if (items is! List) return const <Map<String, Object?>>[];
    return items.whereType<Map<String, Object?>>().toList(growable: false);
  }

  // ------------------------------------------------------------------- SSE

  /// Opens an SSE endpoint. Cancelling the returned stream closes the socket.
  Stream<SseEvent> _events(String path, {Map<String, String?>? query}) async* {
    final Uri url = _url(path, query);
    HttpClientRequest request;
    HttpClientResponse response;
    try {
      request = await _open('GET', url).timeout(timeout);
      request.headers.set(HttpHeaders.authorizationHeader, bearer(deviceKey));
      request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      response = await request.close().timeout(timeout);
    } on TimeoutException {
      throw AgentException(
        'agent_unreachable',
        'The agent did not open the stream within ${timeout.inSeconds} s.',
        status: 502,
      );
    } on HandshakeException catch (error) {
      throw _pinFailure(error.message);
    } on SocketException catch (error) {
      throw AgentException(
        'agent_unreachable',
        'The agent could not be reached: ${error.osError?.message ?? error.message}.',
        status: 502,
      );
    }

    if (response.statusCode >= 400) {
      final String text = await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      throw _RawResponse(response.statusCode, text, null).toException();
    }
    yield* decodeSse(response);
  }

  /// Long-lived streams reconnect with backoff, but only once they have
  /// delivered something: a stream that fails on the first try is a real
  /// error and the screen should show it.
  Stream<T> _resilient<T>(Stream<T> Function() open) async* {
    Duration delay = const Duration(seconds: 1);
    const Duration maxDelay = Duration(seconds: 30);
    bool delivered = false;
    while (true) {
      try {
        await for (final T value in open()) {
          delivered = true;
          delay = const Duration(seconds: 1);
          yield value;
        }
      } on AgentException catch (error) {
        final bool fatal =
            error.status == 401 ||
            error.status == 403 ||
            error.status == 404 ||
            error.status == 495;
        if (!delivered || fatal) rethrow;
      } catch (_) {
        if (!delivered) rethrow;
      }
      await Future<void>.delayed(delay);
      final int next = delay.inMilliseconds * 2;
      delay = Duration(
        milliseconds: next > maxDelay.inMilliseconds
            ? maxDelay.inMilliseconds
            : next,
      );
    }
  }

  /// Keeps at most one value per [interval], so "Refresh stats every" means
  /// something even though `GET /…/stats/stream` has no rate to ask for.
  ///
  /// The first value is always let through — a screen must not wait a whole
  /// interval for its first figure — and after that the newest value inside a
  /// window wins, which is what a stat gauge wants.
  @visibleForTesting
  static Stream<T> throttle<T>(Stream<T> source, Duration interval) async* {
    if (interval <= Duration.zero) {
      yield* source;
      return;
    }
    DateTime? last;
    await for (final T value in source) {
      final DateTime now = DateTime.now();
      if (last != null && now.difference(last) < interval) continue;
      last = now;
      yield value;
    }
  }

  static Map<String, Object?>? _payload(SseEvent event) {
    if (event.data.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(event.data);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  // ------------------------------------------------------------------ jobs

  /// A job as the agent sends it. The agent spells the stopped state
  /// `cancelled` and sets `result.cancelled`; [JobStatus] calls it `canceled`,
  /// and an unknown status would otherwise read as still running.
  static Job _jobFromJson(Map<String, Object?> json) {
    final Object? status = json['status'];
    final Object? result = json['result'];
    final bool known = JobStatus.values.any((JobStatus s) => s.name == status);
    final bool cancelled =
        status == 'cancelled' ||
        (!known &&
            result is Map<String, Object?> &&
            result['cancelled'] == true);
    if (!cancelled) return Job.fromJson(json);
    return Job.fromJson(<String, Object?>{
      ...json,
      'status': JobStatus.canceled.name,
    });
  }

  /// `202 {"job_id": ..., "job": {...}}`.
  Future<Job> _job(
    String path, {
    Object? body,
    Confirmed confirmed = Confirmed.none,
    Map<String, String?>? query,
  }) async {
    final Map<String, Object?> answer = _object(
      await _send('POST', path, body: body, confirmed: confirmed, query: query),
    );
    final Object? inline = answer['job'];
    if (inline is Map<String, Object?>) return _jobFromJson(inline);
    final String id = answer['job_id'] as String? ?? '';
    if (id.isEmpty) {
      throw const AgentException(
        'bad_response',
        'The agent accepted the operation but returned no job id.',
        status: 502,
      );
    }
    return job(id);
  }

  // --------------------------------------------------------------- system

  @override
  Future<bool> health() async {
    try {
      final _RawResponse response = await _raw('GET', '/health');
      if (response.status != 200) return false;
      final Object? body = jsonDecode(response.body);
      return body is Map<String, Object?> && body['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<MeInfo?> me() async {
    final Object? body = await _send('GET', '/me', notFoundIsNull: true);
    return body == null ? null : MeInfo.fromJson(_object(body));
  }

  @override
  Future<SystemInfo> system() async =>
      SystemInfo.fromJson(_object(await _send('GET', '/system')));

  @override
  Future<SystemStats> systemStats() async =>
      SystemStats.fromJson(_object(await _send('GET', '/system/stats')));

  @override
  Stream<SystemStats> systemStatsStream({
    Duration interval = kDefaultStatsInterval,
  }) => throttle(
    _resilient(() async* {
      yield await systemStats();
      await for (final SseEvent event in _events('/system/stats/stream')) {
        if (event.event != 'stats') continue;
        final Map<String, Object?>? data = _payload(event);
        if (data != null) yield SystemStats.fromJson(data);
      }
    }),
    interval,
  );

  @override
  Stream<DockerEvent> dockerEvents() => _resilient(() async* {
    await for (final SseEvent event in _events('/events/stream')) {
      if (event.event != 'docker_event') continue;
      final Map<String, Object?>? data = _payload(event);
      if (data != null) yield DockerEvent.fromJson(data);
    }
  });

  @override
  Future<List<ActivityEntry>> activity({String? actor, DateTime? since}) =>
      _listAll<ActivityEntry>(
        '/activity',
        ActivityEntry.fromJson,
        query: <String, String?>{
          'actor': actor,
          'since': since?.toUtc().toIso8601String(),
        },
        maxPages: 4,
      );

  // ------------------------------------------------------------ containers

  @override
  Future<List<ContainerSummary>> containers({
    ContainerState? state,
    String? stack,
    String? query,
  }) => _listAll<ContainerSummary>(
    '/containers',
    ContainerSummary.fromJson,
    query: <String, String?>{
      'state': state?.name,
      'stack': stack,
      'q': query,
      'limit': '50',
    },
  );

  @override
  Future<ContainerDetail> container(String id) async =>
      ContainerDetail.fromJson(
        _object(await _send('GET', '/containers/${_seg(id)}')),
      );

  @override
  Future<Map<String, String>> containerEnv(String id) async {
    final Map<String, Object?> body = _object(
      await _send('GET', '/containers/${_seg(id)}/env'),
    );
    final Object? vars = body['env'];
    if (vars is! List) return const <String, String>{};
    return <String, String>{
      for (final Object? entry in vars)
        if (entry is Map<String, Object?> && entry['name'] is String)
          entry['name']! as String: entry['value'] is String
              ? entry['value']! as String
              : '',
    };
  }

  @override
  Stream<ContainerStats> containerStatsStream(
    String id, {
    Duration interval = kDefaultStatsInterval,
  }) => throttle(
    _resilient(() async* {
      await for (final SseEvent event in _events(
        '/containers/${_seg(id)}/stats/stream',
      )) {
        if (event.event != 'stats') continue;
        final Map<String, Object?>? data = _payload(event);
        if (data != null) yield ContainerStats.fromJson(data);
      }
    }),
    interval,
  );

  @override
  Future<void> startContainer(String id) async {
    await _send('POST', '/containers/${_seg(id)}/start');
  }

  @override
  Future<void> stopContainer(
    String id, {
    int timeout = 10,
    Confirmed confirmed = Confirmed.none,
  }) async {
    await _send(
      'POST',
      '/containers/${_seg(id)}/stop',
      query: <String, String?>{'timeout': '$timeout'},
      confirmed: confirmed,
    );
  }

  @override
  Future<void> restartContainer(String id, {int timeout = 10}) async {
    await _send(
      'POST',
      '/containers/${_seg(id)}/restart',
      query: <String, String?>{'timeout': '$timeout'},
    );
  }

  @override
  Future<void> pauseContainer(String id, {required bool paused}) async {
    await _send(
      'POST',
      '/containers/${_seg(id)}/${paused ? 'pause' : 'unpause'}',
    );
  }

  @override
  Future<void> removeContainer(
    String id, {
    bool force = false,
    bool volumes = false,
    Confirmed confirmed = Confirmed.none,
  }) async {
    await _send(
      'DELETE',
      '/containers/${_seg(id)}',
      query: <String, String?>{'force': '$force', 'volumes': '$volumes'},
      confirmed: confirmed,
    );
  }

  @override
  Future<ContainerImpact> containerImpact(String id) async =>
      ContainerImpact.fromJson(
        _object(await _send('GET', '/containers/${_seg(id)}/impact')),
      );

  @override
  Future<List<LogLine>> logs(String id, {int tail = 200, String? query}) async {
    final Map<String, Object?> body = _object(
      await _send(
        'GET',
        '/containers/${_seg(id)}/logs',
        query: <String, String?>{'tail': '$tail', 'q': query},
      ),
    );
    final Object? lines = body['lines'];
    if (lines is! List) return const <LogLine>[];
    return lines
        .whereType<Map<String, Object?>>()
        .map(LogLine.fromJson)
        .toList(growable: false);
  }

  @override
  Stream<LogLine> logStream(String id) => _resilient(() async* {
    await for (final SseEvent event in _events(
      '/containers/${_seg(id)}/logs/stream',
    )) {
      if (event.event == 'end') return;
      if (event.event != 'log') continue;
      final Map<String, Object?>? data = _payload(event);
      if (data != null) yield LogLine.fromJson(data);
    }
  });

  @override
  Future<ExecSession> exec(
    String id, {
    String? shell,
    int cols = 80,
    int rows = 24,
  }) => WebSocketExecSession.connect(
    client: _client,
    url: _url('/containers/${_seg(id)}/exec', <String, String?>{
      'shell': shell,
      'cols': '${cols.clamp(10, 500)}',
      'rows': '${rows.clamp(5, 200)}',
    }),
    authorization: bearer(deviceKey),
  );

  // ---------------------------------------------------------------- stacks

  @override
  Future<List<ComposeStack>> stacks() =>
      _listAll<ComposeStack>('/stacks', ComposeStack.fromJson);

  @override
  Future<Job> stackUp(String name) => _job('/stacks/${_seg(name)}/up');

  @override
  Future<Job> stackRedeploy(String name) =>
      _job('/stacks/${_seg(name)}/redeploy');

  @override
  Future<Job> stackRestart(String name) =>
      _job('/stacks/${_seg(name)}/restart');

  @override
  Future<Job> stackDown(String name, {Confirmed confirmed = Confirmed.none}) =>
      _job('/stacks/${_seg(name)}/down', confirmed: confirmed);

  // ----------------------------------------------------------------- swarm

  @override
  Future<SwarmInfo> swarm() async =>
      SwarmInfo.fromJson(_object(await _send('GET', '/swarm')));

  @override
  Future<List<SwarmService>> services() =>
      _listAll<SwarmService>('/services', SwarmService.fromJson);

  @override
  Future<void> scaleService(String id, int replicas) async {
    await _send(
      'POST',
      '/services/${_seg(id)}/scale',
      body: <String, Object?>{'replicas': replicas},
    );
  }

  @override
  Future<Job> updateService(String id, {String? image, bool force = false}) =>
      _job(
        '/services/${_seg(id)}/update',
        body: <String, Object?>{'image': image ?? '', 'force': force},
      );

  @override
  Future<Job> rollbackService(String id) =>
      _job('/services/${_seg(id)}/rollback');

  // ------------------------------------------- images, volumes and networks

  @override
  Future<ImageList> images() async {
    final List<DockerImage> rows = <DockerImage>[];
    Map<String, Object?>? summary;
    String? cursor;
    for (int page = 0; page < 20; page++) {
      final Map<String, Object?> body = _object(
        await _send(
          'GET',
          '/images',
          query: <String, String?>{'cursor': cursor},
        ),
      );
      rows.addAll(_items(body).map(DockerImage.fromJson));
      summary ??= body['summary'] as Map<String, Object?>?;
      cursor = body['next_cursor'] as String?;
      if (cursor == null || cursor.isEmpty) break;
    }
    if (summary == null) return ImageList.derived(rows);
    return ImageList(
      images: rows,
      totalCount: (summary['count'] as num?)?.toInt() ?? rows.length,
      totalBytes: (summary['total_bytes'] as num?)?.toInt() ?? 0,
      reclaimableBytes: (summary['reclaimable_bytes'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<Job> pullImage(String ref) =>
      _job('/images/pull', body: <String, Object?>{'ref': ref});

  @override
  Future<void> removeImage(
    String id, {
    bool force = false,
    Confirmed confirmed = Confirmed.none,
  }) async {
    await _send(
      'DELETE',
      '/images/${_seg(id)}',
      query: <String, String?>{'force': '$force'},
      confirmed: confirmed,
    );
  }

  @override
  Future<Job> pruneImages({
    bool danglingOnly = true,
    Confirmed confirmed = Confirmed.none,
  }) => _job(
    '/images/prune',
    body: <String, Object?>{'dangling_only': danglingOnly},
    confirmed: confirmed,
  );

  @override
  Future<VolumeList> volumes() async {
    final List<VolumeInfo> rows = <VolumeInfo>[];
    Map<String, Object?>? summary;
    String? cursor;
    for (int page = 0; page < 20; page++) {
      final Map<String, Object?> body = _object(
        await _send(
          'GET',
          '/volumes',
          query: <String, String?>{'cursor': cursor},
        ),
      );
      rows.addAll(_items(body).map(VolumeInfo.fromJson));
      summary ??= body['summary'] as Map<String, Object?>?;
      cursor = body['next_cursor'] as String?;
      if (cursor == null || cursor.isEmpty) break;
    }
    // The summary is optional: an agent without it still gets real figures.
    if (summary == null) return VolumeList.derived(rows);
    return VolumeList(
      volumes: rows,
      count: (summary['count'] as num?)?.toInt() ?? rows.length,
      totalBytes: (summary['total_bytes'] as num?)?.toInt() ?? 0,
      unmounted: (summary['unmounted'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> createVolume(String name, {String driver = 'local'}) async {
    await _send(
      'POST',
      '/volumes',
      body: <String, Object?>{'name': name, 'driver': driver},
    );
  }

  @override
  Future<void> removeVolume(
    String name, {
    Confirmed confirmed = Confirmed.none,
  }) async {
    await _send('DELETE', '/volumes/${_seg(name)}', confirmed: confirmed);
  }

  @override
  Future<Job> pruneVolumes({Confirmed confirmed = Confirmed.none}) =>
      _job('/volumes/prune', confirmed: confirmed);

  @override
  Future<NetworkList> networks() async {
    final List<NetworkInfo> rows = <NetworkInfo>[];
    Map<String, Object?>? summary;
    String? cursor;
    for (int page = 0; page < 20; page++) {
      final Map<String, Object?> body = _object(
        await _send(
          'GET',
          '/networks',
          query: <String, String?>{'cursor': cursor},
        ),
      );
      rows.addAll(_items(body).map(NetworkInfo.fromJson));
      summary ??= body['summary'] as Map<String, Object?>?;
      cursor = body['next_cursor'] as String?;
      if (cursor == null || cursor.isEmpty) break;
    }
    if (summary == null) return NetworkList.derived(rows);
    return NetworkList(
      networks: rows,
      count: (summary['count'] as num?)?.toInt() ?? rows.length,
      unused: (summary['unused'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> createNetwork(
    String name, {
    String driver = 'bridge',
    String? subnet,
  }) async {
    await _send(
      'POST',
      '/networks',
      body: <String, Object?>{
        'name': name,
        'driver': driver,
        'subnet': subnet ?? '',
        'attachable': false,
      },
    );
  }

  @override
  Future<void> removeNetwork(
    String id, {
    Confirmed confirmed = Confirmed.none,
  }) async {
    await _send('DELETE', '/networks/${_seg(id)}', confirmed: confirmed);
  }

  @override
  Future<Job> pruneNetworks({Confirmed confirmed = Confirmed.none}) =>
      _job('/networks/prune', confirmed: confirmed);

  // ---------------------------------------------------------------- alerts

  @override
  Future<List<AlertInfo>> alerts({AlertState? state}) => _listAll<AlertInfo>(
    '/alerts',
    AlertInfo.fromJson,
    query: <String, String?>{'state': state?.name},
  );

  @override
  Future<void> muteAlert(String id, {int minutes = 60}) async {
    await _send(
      'POST',
      '/alerts/${_seg(id)}/mute',
      body: <String, Object?>{'minutes': minutes},
    );
  }

  @override
  Future<void> resolveAlert(String id) async {
    await _send('POST', '/alerts/${_seg(id)}/resolve');
  }

  @override
  Future<List<AlertRule>> alertRules() =>
      _listAll<AlertRule>('/alert-rules', AlertRule.fromJson, maxPages: 2);

  @override
  Future<void> updateAlertRule(
    String id, {
    bool? enabled,
    double? threshold,
    int? windowSeconds,
  }) async {
    await _send(
      'PATCH',
      '/alert-rules/${_seg(id)}',
      body: <String, Object?>{
        if (enabled != null) 'enabled': enabled,
        if (threshold != null) 'threshold': threshold,
        if (windowSeconds != null) 'window_seconds': windowSeconds,
      },
    );
  }

  // ------------------------------------------------------------ registries

  @override
  Future<List<RegistryInfo>> registries() =>
      _listAll<RegistryInfo>('/registries', RegistryInfo.fromJson, maxPages: 4);

  @override
  Future<void> addRegistry({
    required String host,
    required String username,
    required String secret,
  }) async {
    await _send(
      'POST',
      '/registries',
      body: <String, Object?>{
        'host': host,
        'username': username,
        'secret': secret,
      },
    );
  }

  @override
  Future<void> updateRegistry(
    String id, {
    String? username,
    String? secret,
  }) async {
    await _send(
      'PATCH',
      '/registries/${_seg(id)}',
      body: <String, Object?>{
        if (username != null) 'username': username,
        if (secret != null) 'secret': secret,
      },
    );
  }

  @override
  Future<bool> testRegistry(String id) async {
    final Map<String, Object?> body = _object(
      await _send('POST', '/registries/${_seg(id)}/test'),
    );
    return body['ok'] == true;
  }

  @override
  Future<void> removeRegistry(String id) async {
    await _send('DELETE', '/registries/${_seg(id)}');
  }

  // ----------------------------------------------- settings, devices, update

  @override
  Future<AgentSettings> settings() async =>
      AgentSettings.fromJson(_object(await _send('GET', '/settings')));

  @override
  Future<AgentSettings> updateSettings({
    bool? requireBiometricForRisky,
  }) async => AgentSettings.fromJson(
    _object(
      await _send(
        'PATCH',
        '/settings',
        body: <String, Object?>{
          if (requireBiometricForRisky != null)
            'require_biometric_for_risky': requireBiometricForRisky,
        },
      ),
    ),
  );

  @override
  Future<List<DeviceInfo>> devices() =>
      _listAll<DeviceInfo>('/devices', DeviceInfo.fromJson, maxPages: 4);

  @override
  Future<DeviceInfo> updateDevice(
    String id, {
    ServerRole? role,
    String? pushToken,
  }) async => DeviceInfo.fromJson(
    _object(
      await _send(
        'PATCH',
        '/devices/${_seg(id)}',
        body: <String, Object?>{
          if (role != null) 'role': role.name,
          if (pushToken != null) 'push_token': pushToken,
        },
      ),
    ),
  );

  @override
  Future<void> removeDevice(
    String id, {
    Confirmed confirmed = Confirmed.none,
  }) async {
    await _send('DELETE', '/devices/${_seg(id)}', confirmed: confirmed);
  }

  @override
  Future<AgentUpdate> agentUpdate() async =>
      AgentUpdate.fromJson(_object(await _send('GET', '/agent/update')));

  @override
  Future<Job> startAgentUpdate() => _job('/agent/update');

  @override
  Future<Job> job(String id) async =>
      _jobFromJson(_object(await _send('GET', '/jobs/${_seg(id)}')));

  @override
  bool get canCancelJobs => true;

  /// `200` with the cancelled job, or `202` while the work is still winding
  /// down; either way the end arrives on [jobEvents]. `409 conflict` (already
  /// finished) and `404 job_not_found` surface as [AgentException].
  @override
  Future<void> cancelJob(String id) async {
    await _send('POST', '/jobs/${_seg(id)}/cancel');
  }

  @override
  Stream<Job> jobEvents(String id) async* {
    Job? current;
    try {
      await for (final SseEvent event in _events('/jobs/${_seg(id)}/events')) {
        final Map<String, Object?>? data = _payload(event);
        if (data == null) continue;
        switch (event.event) {
          case 'progress':
            final JobLine line = JobLine.fromJson(data);
            current = (current ?? await job(id)).copyWith(
              progressLines: <JobLine>[
                ...current?.progressLines ?? <JobLine>[],
                line,
              ],
              progress: line.percent >= 0
                  ? (line.percent / 100).clamp(0.0, 1.0)
                  : null,
            );
            yield current;
          case 'status':
          case 'done':
            current = _jobFromJson(data);
            yield current;
            if (event.event == 'done') return;
          default:
            break;
        }
      }
    } on AgentException {
      // The events endpoint is gone or was never reachable: poll instead, so a
      // long operation still finishes visibly.
      yield* _pollJob(id);
      return;
    }
    // The stream ended without a `done` frame; make sure the sheet settles.
    if (current == null || !current.status.isFinished) yield* _pollJob(id);
  }

  Stream<Job> _pollJob(String id) async* {
    for (int i = 0; i < 1200; i++) {
      final Job snapshot = await job(id);
      yield snapshot;
      if (snapshot.status.isFinished) return;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
  }
}

/// A raw HTTP answer, before the JSON is looked at.
class _RawResponse {
  const _RawResponse(this.status, this.body, this.retryAfter);

  final int status;
  final String body;
  final Duration? retryAfter;

  AgentException toException() {
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map<String, Object?>) {
        return AgentException.fromJson(
          decoded,
          status: status,
          retryAfter: retryAfter,
        );
      }
    } on FormatException {
      // Fall through to the generic message below.
    }
    return AgentException(
      _codeForStatus(status),
      _messageForStatus(status),
      status: status,
      retryAfter: retryAfter,
    );
  }

  static String _codeForStatus(int status) => switch (status) {
    401 => 'unauthorized',
    403 => 'forbidden',
    404 => 'not_found',
    409 => 'conflict',
    428 => 'confirmation_required',
    429 => 'rate_limited',
    502 => 'docker_unavailable',
    _ => 'internal_error',
  };

  static String _messageForStatus(int status) => switch (status) {
    401 => 'This phone is no longer paired with the agent.',
    403 => 'This device\'s role does not allow that action.',
    404 => 'The agent has no such endpoint or object.',
    409 => 'The agent refused because of the current state.',
    428 => 'This action needs a biometric confirmation.',
    429 => 'The agent is rate limiting this phone.',
    502 => 'The agent could not reach the Docker daemon.',
    _ => 'The agent answered $status.',
  };
}
