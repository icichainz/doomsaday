// The states and dialogs of the `EmptyStates`, `LoadingError`, `JobSheet`,
// `JobDone`, `DesktopJob`, `LockScreen` and `ProUpgrade` boards.
import 'dart:async';

import 'package:doomsaday/data/mock_agent_api.dart';
import 'package:doomsaday/data/mock_seed.dart';
import 'package:doomsaday/data/models.dart';
import 'package:doomsaday/edition/edition.dart';
import 'package:doomsaday/edition/pro_badge.dart';
import 'package:doomsaday/features/settings/server_settings_screen.dart';
import 'package:doomsaday/theme/app_theme.dart';
import 'package:doomsaday/widgets/sheets.dart';
import 'package:doomsaday/widgets/state_views.dart';
import 'package:doomsaday/widgets/stroke_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_harness.dart';

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.dark(),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

Job _job(JobStatus status, {String? error, String? code}) => Job(
  id: 'j1',
  type: 'image_pull',
  target: 'redis:7.2',
  status: status,
  progress: status.isFinished ? 1 : 0.46,
  startedAt: DateTime(2026, 1, 1, 12),
  finishedAt: status.isFinished ? DateTime(2026, 1, 1, 12, 0, 21) : null,
  error: error,
  errorCode: code,
  progressLines: const <JobLine>[
    JobLine(text: 'a2318d6c47ec: Pull complete'),
    JobLine(text: 'c3f1b7e9d2a4: Downloading', percent: 46),
  ],
);

void main() {
  group('ErrorView copy', () {
    const AgentException down = AgentException(
      'agent_unreachable',
      'Agent unreachable. Last seen 2 h ago.',
      status: 502,
    );

    test('does not repeat the title and says what to try', () {
      expect(ErrorView.titleFor(down), 'Agent unreachable');
      expect(
        ErrorView.reasonFor(down),
        'Last seen 2 h ago. Check that the agent is running and this device '
        'can reach the host.',
      );
      expect(ErrorView.codeFor(down), 'agent_unreachable · 502');
    });

    test('names Docker when the agent is up but Docker is not', () {
      const AgentException docker = AgentException(
        'docker_unavailable',
        'The Docker socket is not answering.',
        status: 503,
      );
      expect(ErrorView.titleFor(docker), 'Docker unavailable');
      expect(
        ErrorView.reasonFor(docker),
        'The Docker socket is not answering.',
      );
    });
  });

  testWidgets('an empty state with one secondary action calls it', (
    WidgetTester tester,
  ) async {
    int cleared = 0;
    await tester.pumpWidget(
      _host(
        EmptyView(
          glyph: StrokeGlyph.search,
          title: 'No matching containers',
          message: 'Nothing here matches that search.',
          secondary: EmptyAction('Clear filter', onPressed: () => cleared++),
        ),
      ),
    );
    await tester.tap(find.text('Clear filter'));
    expect(cleared, 1);
  });

  testWidgets('the skeleton has no spinner', (WidgetTester tester) async {
    await tester.pumpWidget(_host(const LoadingView.statCards()));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.bySemanticsLabel('Loading'), findsOneWidget);
  });

  group('job sheet', () {
    Future<void> pumpJob(
      WidgetTester tester,
      Job job, {
      Future<void> Function()? onCancel,
    }) async {
      await tester.pumpWidget(
        _host(
          JobProgressBody(
            initial: job,
            events: const Stream<Job>.empty(),
            sheet: true,
            serverName: 'prod-eu-1',
            onCancel: onCancel,
            clock: () => DateTime(2026, 1, 1, 12, 0, 14),
          ),
        ),
      );
    }

    testWidgets('running: percent, elapsed, Cancel and Run in background', (
      WidgetTester tester,
    ) async {
      await pumpJob(tester, _job(JobStatus.running), onCancel: () async {});
      expect(find.text('Pulling redis:7.2'), findsOneWidget);
      expect(find.text('prod-eu-1 · Running on the agent'), findsOneWidget);
      expect(find.text('46%'), findsOneWidget);
      expect(find.text('0:14 elapsed'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Run in background'), findsOneWidget);
    });

    testWidgets('no Cancel when the agent cannot cancel', (
      WidgetTester tester,
    ) async {
      await pumpJob(tester, _job(JobStatus.running));
      expect(find.text('Cancel'), findsNothing);
      expect(find.text('Run in background'), findsOneWidget);
    });

    testWidgets('finished: the success line and Done', (
      WidgetTester tester,
    ) async {
      await pumpJob(tester, _job(JobStatus.succeeded));
      expect(find.text('Finished without errors'), findsOneWidget);
      expect(find.text('0:21 elapsed'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('failed: the error code, and Show details opens the log', (
      WidgetTester tester,
    ) async {
      await pumpJob(
        tester,
        _job(
          JobStatus.failed,
          error: 'pull access denied for redis',
          code: 'registry_auth_failed',
        ),
      );
      expect(find.text('registry_auth_failed'), findsOneWidget);
      expect(find.text('pull access denied for redis'), findsOneWidget);
      expect(find.text('a2318d6c47ec: Pull complete'), findsNothing);
      await tester.tap(find.text('Show details'));
      await tester.pump();
      expect(find.text('a2318d6c47ec: Pull complete'), findsOneWidget);
      expect(find.text('Show details'), findsNothing);
    });
  });

  test('the demo agent cancels a running job', () async {
    final MockAgentApi api = MockAgentApi(seedProduction());
    final Job job = await api.pullImage('redis:7.2');
    expect(api.canCancelJobs, isTrue);
    final Future<Job> last = api.jobEvents(job.id).last;
    await api.cancelJob(job.id);
    final Job done = await last;
    expect(done.status, JobStatus.canceled);
    expect(done.errorCode, 'job_canceled');
    api.dispose();
  });

  testWidgets('an offline server is one error card with Server settings', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, size: phone, startLocation: '/s/backup-nas/overview');
    expect(find.text('Agent unreachable'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Server settings'), findsOneWidget);
    expect(find.text('192.168.1.40:8443'), findsOneWidget);
    await tester.tap(find.text('Server settings'));
    await settle(tester);
    expect(find.byType(ServerSettingsScreen), findsOneWidget);
    await disposeApp(tester);
  });

  testWidgets('nothing paired: no search field, both ways in', (
    WidgetTester tester,
  ) async {
    await pumpApp(
      tester,
      size: phone,
      repository: emptyRepository(),
      startLocation: '/',
    );
    expect(find.text('No servers yet'), findsOneWidget);
    expect(find.text('No paired agents yet'), findsOneWidget);
    expect(find.text('Search servers'), findsNothing);
    expect(find.text('Explore with demo data'), findsOneWidget);
    await tester.tap(find.text('Explore with demo data'));
    await settle(tester);
    expect(find.text('Demo data · 3 sample agents · 2 online'), findsOneWidget);
    expect(find.text('Leave demo'), findsOneWidget);
    await disposeApp(tester);
  });

  testWidgets('Get Pro lists what Pro adds and has only Got it', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, size: phone, edition: Edition.free);
    unawaited(openProUpgrade(tester.element(find.byType(Scaffold).first)));
    await settle(tester);
    expect(find.text('Doomsaday Pro is not on sale yet'), findsOneWidget);
    for (final String feature in <String>[
      'Unlimited servers',
      'All servers',
      'Log wall',
      'Cross-server search',
    ]) {
      expect(find.text(feature), findsWidgets);
    }
    expect(find.text('Got it'), findsOneWidget);
    await tester.tap(find.text('Got it'));
    await settle(tester);
    expect(find.text('Doomsaday Pro is not on sale yet'), findsNothing);
    await disposeApp(tester);
  });
}
