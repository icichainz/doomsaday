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

import 'package:doomsaday/data/mock_seed.dart';
import 'package:doomsaday/data/models.dart';
import 'package:doomsaday/data/servers_repository.dart';
import 'package:doomsaday/widgets/buttons.dart';
import 'package:flutter/material.dart';

import 'harness.dart';

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
    String? deviceName,
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
  seedBoardActivity(tester);
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
