/// Captures for the states-and-dialogs boards: empty states, the offline and
/// loading overview, job progress, the app lock, the Pro upgrade dialog and
/// the demo-mode Servers screen.
///
/// Not part of the test suite (it lives under `tool/`); run it by path:
///
///     flutter test --dart-define=EDITION=free \
///       --dart-define=REVIEW_OUT=../review/app/free \
///       tool/design_review/screens_states_and_dialogs_test.dart
library;

import 'dart:async';
import 'dart:io';

import 'package:doomsaday/data/models.dart';
import 'package:doomsaday/data/mock_seed.dart';
import 'package:doomsaday/data/preferences.dart';
import 'package:doomsaday/data/servers_repository.dart';
import 'package:doomsaday/edition/edition.dart';
import 'package:doomsaday/edition/pro_badge.dart';
import 'package:doomsaday/widgets/sheets.dart';
import 'package:doomsaday/widgets/surfaces.dart';
import 'package:flutter/material.dart';

import 'harness.dart';

/// Nothing paired and not in demo mode: a fresh install.
// ignore: invalid_use_of_visible_for_testing_member
ServersRepository _nothing() => ServersRepository.pairedMocks(
  <MockWorld>[],
  maxServers: currentEdition.maxServers,
);

/// A fixed "now" so the elapsed time reads the same on every run.
final DateTime _now = DateTime(2026, 9, 25, 12);

Job _pulling() => Job(
  id: 'job-review',
  type: 'image_pull',
  target: 'redis:7.2',
  status: JobStatus.running,
  progress: 0.46,
  startedAt: _now.subtract(const Duration(seconds: 14)),
  progressLines: const <JobLine>[
    JobLine(text: '7.2: Pulling from library/redis'),
    JobLine(text: 'a2318d6c47ec: Pull complete'),
    JobLine(text: '5b1e2c5d7a0f: Pull complete'),
    JobLine(text: 'c3f1b7e9d2a4: Downloading 18.2 / 41.6 MB', percent: 46),
    JobLine(text: 'e8d4a1f60b37: Waiting', percent: 46),
  ],
);

Job _pulled() => Job(
  id: 'job-review',
  type: 'image_pull',
  target: 'redis:7.2',
  status: JobStatus.succeeded,
  progress: 1,
  startedAt: _now.subtract(const Duration(seconds: 21)),
  finishedAt: _now,
  progressLines: const <JobLine>[
    JobLine(text: '7.2: Pulling from library/redis'),
    JobLine(text: 'c3f1b7e9d2a4: Pull complete'),
    JobLine(text: 'e8d4a1f60b37: Pull complete'),
    JobLine(text: 'Digest: sha256:5a93f5c2…e41d'),
    JobLine(text: 'Status: Downloaded newer image for redis:7.2'),
  ],
);

/// The job sheet as `runJob` opens it, with a job whose events never arrive,
/// so the capture is the exact moment the board draws.
Future<void> _openJob(WidgetTester t, Job job) async {
  await go(t, '/s/$kServer/resources');
  final BuildContext context = t.element(find.byType(Scaffold).first);
  final StreamController<Job> never = StreamController<Job>();
  addTearDown(never.close);
  unawaited(
    showAdaptiveModal<JobSheetExit>(
      // Looked up after the navigation settled, so it is the live page.
      // ignore: use_build_context_synchronously
      context,
      dismissible: false,
      builder: (BuildContext context, bool sheet) => JobProgressBody(
        initial: job,
        events: never.stream,
        sheet: sheet,
        serverName: kServer,
        onCancel: () async {},
        clock: () => _now,
      ),
    ),
  );
  await settle(t);
}

void main() {
  setUpAll(() async {
    await loadFonts();
    stdout.writeln('edition ${currentEdition.displayName} -> $reviewOut');
  });

  group('empty, error, loading', () {
    for (final ThemeMode mode in <ThemeMode>[ThemeMode.dark, ThemeMode.light]) {
      final String light = mode == ThemeMode.light ? 'Light' : '';
      board(
        'EmptyStates$light',
        kPhone,
        (WidgetTester t) async {},
        themeMode: mode,
        repository: _nothing,
      );
      board('LoadingError$light', kPhone, (WidgetTester t) async {
        await go(t, '/s/backup-nas/overview');
      }, themeMode: mode);
    }
    // The skeleton: the Servers screen two frames after launch, before the
    // mock agents have answered. Paired against the `LoadingError` board.
    board('LoadingErrorLoading', kPhone, (WidgetTester t) async {
      await t.pump(const Duration(milliseconds: 16));
      await t.pump(const Duration(milliseconds: 16));
    }, settleFirst: false);
  });

  group('jobs', () {
    board('JobSheet', kPhone, (WidgetTester t) => _openJob(t, _pulling()));
    board(
      'JobSheetLight',
      kPhone,
      (WidgetTester t) => _openJob(t, _pulling()),
      themeMode: ThemeMode.light,
    );
    board('JobDone', kPhone, (WidgetTester t) => _openJob(t, _pulled()));
    board(
      'JobDoneLight',
      kPhone,
      (WidgetTester t) => _openJob(t, _pulled()),
      themeMode: ThemeMode.light,
    );
    desktopBoard('DesktopJob', (WidgetTester t) => _openJob(t, _pulling()));
    desktopBoard(
      'DesktopJobLight',
      (WidgetTester t) => _openJob(t, _pulling()),
      themeMode: ThemeMode.light,
    );
  });

  group('app lock', () {
    // The brand tile follows the edition: LockScreen/DesktopLock draw Free's
    // mint tile, LockScreenPro/DesktopLockPro the Pro build's deep red.
    final String pro = currentEdition.isPro ? 'Pro' : '';
    for (final ThemeMode mode in <ThemeMode>[ThemeMode.dark, ThemeMode.light]) {
      final String light = mode == ThemeMode.light ? 'Light' : '';
      board(
        'LockScreen$pro$light',
        kPhone,
        (WidgetTester t) async {},
        themeMode: mode,
        preferences: const Preferences(appLock: true),
      );
      desktopBoard(
        'DesktopLock$pro$light',
        (WidgetTester t) async {},
        themeMode: mode,
        preferences: const Preferences(appLock: true),
      );
    }
  });

  group('editions', () {
    // "Get Doomsaday Pro" only exists in the Free build.
    if (!currentEdition.isPro) {
      for (final ThemeMode mode in <ThemeMode>[
        ThemeMode.dark,
        ThemeMode.light,
      ]) {
        final String light = mode == ThemeMode.light ? 'Light' : '';
        board(
          'ProUpgrade$light',
          kPhone,
          (WidgetTester t) async {
            await go(t, '/preferences');
            unawaited(openProUpgrade(t.element(find.byType(Scaffold).first)));
            await settle(t);
          },
          themeMode: mode,
          repository: pairedRepository,
        );
      }
    }
  });

  group('demo mode', () {
    board('MainDemo', kPhone, (WidgetTester t) async {});
    board(
      'MainDemoLight',
      kPhone,
      (WidgetTester t) async {},
      themeMode: ThemeMode.light,
    );
  });
}
