/// D6: which containers the log wall is following, remembered between
/// launches.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../theme/theme_controller.dart';

/// One pane: a container on a server, with the name for the header before the
/// agent has answered.
class LogPaneRef {
  const LogPaneRef({
    required this.serverId,
    required this.containerId,
    required this.name,
  });

  final String serverId;
  final String containerId;
  final String name;

  String get key => '$serverId/$containerId';

  Map<String, Object?> toJson() => <String, Object?>{
    'server': serverId,
    'container': containerId,
    'name': name,
  };

  static LogPaneRef? fromJson(Object? value) {
    if (value is! Map<String, Object?>) return null;
    final String server = value['server'] as String? ?? '';
    final String container = value['container'] as String? ?? '';
    if (server.isEmpty || container.isEmpty) return null;
    return LogPaneRef(
      serverId: server,
      containerId: container,
      name: value['name'] as String? ?? container,
    );
  }
}

class LogWallController extends StateNotifier<List<LogPaneRef>> {
  LogWallController(this._prefs) : super(_read(_prefs));

  static const String _key = 'log_wall_panes';

  /// D6 is a 2×2 grid; six is where the panes stop being readable.
  static const int maxPanes = 6;

  final SharedPreferences? _prefs;

  static List<LogPaneRef> _read(SharedPreferences? prefs) {
    final String? raw = prefs?.getString(_key);
    if (raw == null || raw.isEmpty) return const <LogPaneRef>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return const <LogPaneRef>[];
      return decoded
          .map(LogPaneRef.fromJson)
          .whereType<LogPaneRef>()
          .take(maxPanes)
          .toList(growable: false);
    } on FormatException {
      return const <LogPaneRef>[];
    }
  }

  Future<void> _write() async {
    await _prefs?.setString(
      _key,
      jsonEncode(state.map((LogPaneRef p) => p.toJson()).toList()),
    );
  }

  bool get isFull => state.length >= maxPanes;

  void add(LogPaneRef pane) {
    if (isFull || state.any((LogPaneRef p) => p.key == pane.key)) return;
    state = <LogPaneRef>[...state, pane];
    _write();
  }

  void remove(LogPaneRef pane) {
    state = state
        .where((LogPaneRef p) => p.key != pane.key)
        .toList(growable: false);
    _write();
  }

  void clear() {
    state = const <LogPaneRef>[];
    _write();
  }
}

final logWallProvider =
    StateNotifierProvider<LogWallController, List<LogPaneRef>>(
      (ref) => LogWallController(ref.watch(sharedPreferencesProvider)),
    );
