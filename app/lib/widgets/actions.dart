import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/agent_api.dart';
import '../data/models.dart';
import '../data/providers.dart';
import 'notify.dart';
import 'sheets.dart';

/// Whether the agent's cached `require_biometric_for_risky` says this call
/// will be refused with `428` unless it carries `X-Confirmed: biometric`.
/// Defaults to on, which is the agent's own default (API_NOTES §25).
bool riskyNeedsFingerprint(WidgetRef ref, String serverId) =>
    ref
        .read(agentSettingsProvider(serverId))
        .valueOrNull
        ?.requireBiometricForRisky ??
    true;

/// Shows the confirm sheet with the real biometric prompt behind it.
Future<RiskyOutcome> confirmRisky(
  BuildContext context,
  WidgetRef ref,
  RiskyAction action,
) => showRiskyConfirm(
  context,
  action,
  authenticator: ref.read(authenticatorProvider),
);

/// Runs a mutating call, reports the failure the agent gave and refreshes the
/// screens the change could have touched.
Future<bool> runAction(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function() call, {
  String? success,
}) async {
  try {
    await call();
    refreshServer(ref);
    if (context.mounted && success != null) notify(context, success);
    return true;
  } on AgentException catch (error) {
    if (context.mounted) notify(context, error.toString(), danger: true);
    return false;
  }
}

/// Starts a long operation, shows its progress sheet and refreshes the screens
/// it could have changed.
///
/// "Run in background" leaves the job running on the agent: this keeps
/// following it, and refreshes and says how it ended once it does.
Future<void> runJob(
  BuildContext context,
  WidgetRef ref,
  String serverId,
  Future<Job> Function(AgentApi api) start,
) async {
  try {
    final AgentApi api = ref.read(agentApiProvider(serverId));
    final Job job = await start(api);
    if (!context.mounted) return;
    final JobSheetExit exit = await showJobSheet(
      context,
      job: job,
      events: api.jobEvents(job.id),
      serverName: ref.read(serverProvider(serverId)).name,
      onCancel: api.canCancelJobs ? () => api.cancelJob(job.id) : null,
    );
    refreshServer(ref);
    if (exit == JobSheetExit.background && context.mounted) {
      unawaited(
        _followInBackground(ScaffoldMessenger.maybeOf(context), ref, api, job),
      );
    }
  } on AgentException catch (error) {
    if (context.mounted) notify(context, error.toString(), danger: true);
  }
}

Future<void> _followInBackground(
  ScaffoldMessengerState? messenger,
  WidgetRef ref,
  AgentApi api,
  Job job,
) async {
  Job last = job;
  try {
    await for (final Job update in api.jobEvents(job.id)) {
      last = update;
      if (update.status.isFinished) break;
    }
    if (!last.status.isFinished) last = await api.job(job.id);
  } on AgentException {
    return;
  }
  if (!last.status.isFinished) return;
  try {
    refreshServer(ref);
  } on Object {
    // The screen that started it is gone; the next visit reloads anyway.
  }
  final bool ok = last.status == JobStatus.succeeded;
  if (messenger == null || !messenger.mounted) return;
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        ok ? '${last.title}: done' : '${last.title}: ${last.error ?? 'failed'}',
      ),
    ),
  );
}
