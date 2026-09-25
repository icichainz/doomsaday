/// A tiny stand-in for `agent_zero`, on 127.0.0.1, for the client tests.
///
/// It speaks just enough of the contract to exercise the transport: the list
/// envelope with cursors, the error envelope, `202` jobs with an SSE event
/// stream, the `428` confirmation rule and TLS with a known certificate.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef Handler = FutureOr<void> Function(HttpRequest request);

class FakeAgent {
  FakeAgent._(this._server);

  final HttpServer _server;

  /// Every request the agent saw, in order: `METHOD /path?query`.
  final List<String> requests = <String>[];

  /// The `X-Confirmed` header of each request, or `null`.
  final List<String?> confirmations = <String?>[];

  final Map<String, Handler> _routes = <String, Handler>{};

  static Future<FakeAgent> start({SecurityContext? tls}) async {
    final HttpServer server = tls == null
        ? await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
        : await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, tls);
    final FakeAgent agent = FakeAgent._(server);
    server.listen(agent._dispatch);
    return agent;
  }

  /// A `SecurityContext` from a PEM pair under `test/fixtures`.
  static SecurityContext contextFor(String certPath, String keyPath) =>
      SecurityContext()
        ..useCertificateChain(certPath)
        ..usePrivateKey(keyPath);

  String get baseUrl =>
      '${_isTls ? 'https' : 'http'}://127.0.0.1:${_server.port}';

  bool _isTls = false;

  /// Marks the agent as TLS so [baseUrl] uses `https`.
  FakeAgent asTls() {
    _isTls = true;
    return this;
  }

  void on(String methodAndPath, Handler handler) =>
      _routes[methodAndPath] = handler;

  /// Answers one path with a fixed JSON body and status.
  void json(String methodAndPath, Object? body, {int status = 200}) {
    on(methodAndPath, (HttpRequest request) {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      if (body != null) request.response.write(jsonEncode(body));
    });
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _dispatch(HttpRequest request) async {
    requests.add(
      '${request.method} ${request.uri.path}'
      '${request.uri.hasQuery ? '?${request.uri.query}' : ''}',
    );
    confirmations.add(request.headers.value('X-Confirmed'));

    final Handler? handler = _routes['${request.method} ${request.uri.path}'];
    if (handler == null) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode(<String, Object?>{
          'error': <String, Object?>{
            'code': 'not_found',
            'message': 'no such endpoint',
            'details': <String, Object?>{},
          },
        }),
      );
      await request.response.close();
      return;
    }
    try {
      await handler(request);
    } finally {
      await request.response.close();
    }
  }
}

/// Writes one SSE frame the way `internal/sse` does.
void sseFrame(HttpResponse response, String event, Object payload) {
  response.write('event: $event\n');
  for (final String line in jsonEncode(payload).split('\n')) {
    response.write('data: $line\n');
  }
  response.write('\n');
}

/// Sets the SSE headers and flushes the head.
Future<void> sseHead(HttpResponse response) async {
  response.statusCode = 200;
  response.headers.set('Content-Type', 'text/event-stream');
  response.headers.set('Cache-Control', 'no-cache');
  response.bufferOutput = false;
  await response.flush();
}

/// The contract's error envelope.
Map<String, Object?> errorBody(
  String code,
  String message, [
  Map<String, Object?> details = const <String, Object?>{},
]) => <String, Object?>{
  'error': <String, Object?>{
    'code': code,
    'message': message,
    'details': details,
  },
};
