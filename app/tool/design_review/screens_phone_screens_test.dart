/// Screenshots of the phone screens drawn in the "phone-screens" round:
/// Shell, Devices, DeviceActions, Activity, PairConfirm, PairError and
/// ContainerDetailEnv, each in both themes.
///
/// Not part of the suite (it lives under `tool/`); run it by path, once per
/// edition:
///
///     flutter test --dart-define=EDITION=free \
///       --dart-define=REVIEW_OUT=../review/app/free \
///       tool/design_review/screens_phone_screens_test.dart
library;

import 'package:doomsaday/data/mock_agent_api.dart';
import 'package:doomsaday/data/mock_seed.dart';
import 'package:doomsaday/data/models.dart';
import 'package:doomsaday/data/providers.dart';
import 'package:doomsaday/data/servers_repository.dart';
import 'package:doomsaday/widgets/buttons.dart';
import 'package:flutter/material.dart';

import 'harness.dart';

/// prod-eu-1's mock world, so a board can set the scene before it opens.
MockWorld _production(WidgetTester tester) =>
    (appContainer(tester).read(serversRepositoryProvider).api(kServer)
            as MockAgentApi)
        .world;

/// The six records the Activity board draws: four today, two yesterday, one
/// refused and one failed, from three devices.
void _seedActivity(WidgetTester tester) {
  final DateTime now = DateTime.now();
  int n = 0;
  DateTime at(int daysAgo, int hour, int minute) {
    final DateTime t = DateTime(
      now.year,
      now.month,
      now.day - daysAgo,
      hour,
      minute,
    );
    // Early in the morning "today at 09:41" has not happened yet.
    return t.isAfter(now) ? now.subtract(Duration(minutes: 6 + 20 * n)) : t;
  }

  ActivityEntry entry(
    DateTime time,
    String action,
    String target,
    String device, {
    String result = 'ok',
  }) {
    n++;
    final (String id, String name, String role) = switch (device) {
      'ipad' => ('dev-2', 'Ops iPad', 'operator'),
      'pixel' => ('dev-3', 'On-call pixel', 'viewer'),
      _ => ('dev-1', 'This phone', 'admin'),
    };
    return ActivityEntry(
      id: 'board-$n',
      time: time,
      action: action,
      target: target,
      result: result,
      deviceId: id,
      deviceName: name,
      role: role,
      status: result == 'ok' ? 200 : (result == 'denied' ? 403 : 500),
    );
  }

  _production(tester).activity
    ..clear()
    ..addAll(<ActivityEntry>[
      entry(
        at(0, 9, 41),
        'POST /v1/containers/{id}/restart',
        'nginx-proxy',
        '',
      ),
      entry(at(0, 9, 12), 'WS /v1/containers/{id}/exec', 'api-gateway', ''),
      entry(
        at(0, 8, 55),
        'POST /v1/stacks/{name}/down',
        'monitoring',
        'pixel',
        result: 'denied',
      ),
      entry(at(0, 8, 30), 'POST /v1/images/pull', 'redis:7.2', 'ipad'),
      entry(
        at(1, 18, 4),
        'POST /v1/services/{id}/scale',
        'api',
        'ipad',
        result: 'error',
      ),
      entry(at(1, 16, 20), 'GET /v1/containers/{id}/env', 'api-gateway', ''),
    ]);
}

/// Demo mode without prod-eu-1, so the pair form can pair "prod-eu-1" the way
/// the PairAgent board fills it in.
ServersRepository _withoutProduction() =>
    ServersRepository(worlds: <MockWorld>[seedStaging(), seedOffline()]);

/// An agent whose certificate does not match what it reported.
class _MismatchRepository extends ServersRepository {
  _MismatchRepository()
    : super(worlds: <MockWorld>[seedStaging(), seedOffline()]);

  @override
  Future<PairPreview> beginPairing({
    required String name,
    required String agentUrl,
    required String token,
    String deviceName = 'This phone',
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    throw const AgentException(
      'certificate_mismatch',
      'The certificate the agent presented does not match the fingerprint it '
          'reported, so pairing was stopped.',
      status: 495,
    );
  }
}

Future<void> _fillPairForm(WidgetTester tester) async {
  final Finder fields = find.byType(TextField);
  await tester.enterText(fields.at(0), 'prod-eu-1');
  await tester.enterText(fields.at(1), 'https://agent.example.com:8443');
  await tester.enterText(fields.at(2), 'pt_7f3k2q9x');
  await settle(tester, frames: 2);
  await tap(tester, find.text('Test connection and pair'));
  await settle(tester, frames: 4);
}

Future<void> _shell(WidgetTester tester) async {
  await go(tester, '/s/$kServer/containers/$kApiGateway/shell');
  for (final String command in <String>[
    'ls',
    'cat config/app.yaml',
    'ps',
    'wget -qO- localhost:8080/healthz',
  ]) {
    await tester.enterText(find.byType(TextField).last, command);
    await tap(tester, find.text('Send'));
  }
  // The keyboard would cover the board; it is drawn without one.
  FocusManager.instance.primaryFocus?.unfocus();
  await settle(tester, frames: 2);
}

Future<void> _deviceActions(WidgetTester tester) async {
  await go(tester, '/s/$kServer/settings/devices');
  await tap(
    tester,
    find.byWidgetPredicate(
      (Widget w) =>
          w is DoomIconButton && w.semanticLabel == 'Actions for This phone',
    ),
  );
}

Future<void> _activity(WidgetTester tester) async {
  _seedActivity(tester);
  await go(tester, '/s/$kServer/settings/activity');
}

Future<void> _environment(WidgetTester tester) async {
  await go(tester, '/s/$kServer/containers/$kApiGateway');
  await tap(tester, find.text('Environment'));
  await tap(tester, find.byKey(const ValueKey<String>('reveal-LOG_LEVEL')));
}

void _boards(String suffix, ThemeMode mode) {
  board('Shell$suffix', kPhone, _shell, themeMode: mode);
  board('Devices$suffix', kPhone, (WidgetTester t) async {
    await go(t, '/s/$kServer/settings/devices');
  }, themeMode: mode);
  board('DeviceActions$suffix', kPhone, _deviceActions, themeMode: mode);
  board('Activity$suffix', kPhone, _activity, themeMode: mode);
  board(
    'PairConfirm$suffix',
    kPhone,
    (WidgetTester t) async {
      await go(t, '/pair');
      await _fillPairForm(t);
    },
    themeMode: mode,
    repository: _withoutProduction,
  );
  board(
    'PairError$suffix',
    kPhone,
    (WidgetTester t) async {
      await go(t, '/pair');
      await _fillPairForm(t);
      FocusManager.instance.primaryFocus?.unfocus();
      await settle(t, frames: 2);
    },
    themeMode: mode,
    repository: _MismatchRepository.new,
  );
  board('ContainerDetailEnv$suffix', kPhone, _environment, themeMode: mode);
}

void main() {
  setUpAll(loadFonts);

  group('phone screens, dark', () => _boards('', ThemeMode.dark));
  group('phone screens, light', () => _boards('Light', ThemeMode.light));
}
