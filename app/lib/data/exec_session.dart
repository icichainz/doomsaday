/// The interactive shell, the one WebSocket in the contract.
///
/// API_NOTES §15: binary frames carry raw terminal bytes in both directions;
/// text frames carry JSON control messages from the app (`stdin`, `resize`,
/// `ping`) and one `{"type":"exit","code":N}` from the agent before it closes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

/// A live exec session: terminal output as a stream, input through [send].
abstract class ExecSession {
  /// Decoded terminal output.
  Stream<String> get output;

  /// The exit status of the shell, once the agent reports it.
  Future<int?> get exitCode;

  /// Sends terminal input.
  void send(String data);

  /// Tells the agent the terminal changed size.
  void resize({required int cols, required int rows});

  /// Closes the session from this side.
  Future<void> close();
}

/// [ExecSession] over a real `dart:io` [WebSocket], opened through the pinned
/// [HttpClient] so the shell is held to the same certificate as every call.
class WebSocketExecSession implements ExecSession {
  WebSocketExecSession(this._socket) {
    _subscription = _socket.listen(
      _onFrame,
      onError: (Object error, StackTrace stack) {
        if (!_output.isClosed) _output.addError(error, stack);
      },
      onDone: _finish,
      cancelOnError: false,
    );
  }

  /// Opens `GET /v1/containers/{id}/exec` as a WebSocket.
  static Future<WebSocketExecSession> connect({
    required HttpClient client,
    required Uri url,
    required String authorization,
  }) async {
    try {
      final WebSocket socket = await WebSocket.connect(
        url.replace(scheme: url.scheme == 'https' ? 'wss' : 'ws').toString(),
        headers: <String, Object>{
          HttpHeaders.authorizationHeader: authorization,
        },
        customClient: client,
      );
      return WebSocketExecSession(socket);
    } on WebSocketException catch (error) {
      throw AgentException('exec_failed', error.message, status: 502);
    } on SocketException catch (error) {
      throw AgentException('agent_unreachable', error.message, status: 502);
    }
  }

  final WebSocket _socket;
  late final StreamSubscription<dynamic> _subscription;
  final StreamController<String> _output = StreamController<String>.broadcast();
  final Completer<int?> _exit = Completer<int?>();

  @override
  Stream<String> get output => _output.stream;

  @override
  Future<int?> get exitCode => _exit.future;

  void _onFrame(dynamic frame) {
    if (frame is List<int>) {
      _output.add(utf8.decode(frame, allowMalformed: true));
      return;
    }
    if (frame is! String) return;
    // A text frame is a control message; anything else is shown as output so
    // nothing the shell prints is silently swallowed.
    Object? decoded;
    try {
      decoded = jsonDecode(frame);
    } on FormatException {
      _output.add(frame);
      return;
    }
    if (decoded is Map<String, Object?> && decoded['type'] == 'exit') {
      final Object? code = decoded['code'];
      if (!_exit.isCompleted) _exit.complete(code is int ? code : null);
      return;
    }
    _output.add(frame);
  }

  void _finish() {
    if (!_exit.isCompleted) _exit.complete(null);
    if (!_output.isClosed) _output.close();
  }

  @override
  void send(String data) {
    if (_socket.readyState != WebSocket.open) return;
    _socket.add(jsonEncode(<String, Object?>{'type': 'stdin', 'data': data}));
  }

  @override
  void resize({required int cols, required int rows}) {
    if (_socket.readyState != WebSocket.open) return;
    _socket.add(
      jsonEncode(<String, Object?>{
        'type': 'resize',
        'cols': cols.clamp(10, 500),
        'rows': rows.clamp(5, 200),
      }),
    );
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close(WebSocketStatus.normalClosure);
    _finish();
  }
}

/// Strips the ANSI control sequences a real shell emits, so a plain text
/// widget can render the session. Carriage returns rewrite the current line,
/// which is what progress output expects.
String stripAnsi(String input) {
  final String withoutCsi = input
      .replaceAll(RegExp(r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)'), '')
      .replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '')
      .replaceAll(RegExp(r'\x1B[()][A-Za-z0-9]'), '')
      .replaceAll(RegExp(r'\x1B[=>PX^_]'), '');
  return withoutCsi.replaceAll('\r\n', '\n').replaceAll('', '');
}
