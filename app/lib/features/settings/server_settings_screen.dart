import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/actions.dart';
import '../../widgets/buttons.dart';
import '../../widgets/notify.dart';
import '../../widgets/page.dart';
import '../../widgets/primitives.dart';
import '../../widgets/sheets.dart';
import '../../widgets/state_views.dart';
import '../../widgets/surfaces.dart';

/// Screen 14 — Server settings: everything about **one agent**.
///
/// The theme switch used to live here as an "Appearance" section. It is about
/// the app rather than the server, so it moved to Preferences with the rest of
/// the app-wide settings, and this screen ends on "Unpair this server" — which
/// now fits at 390x844 without scrolling.
class ServerSettingsScreen extends ConsumerWidget {
  const ServerSettingsScreen({super.key, required this.serverId});

  final String serverId;

  Future<void> _unpair(BuildContext context, WidgetRef ref) async {
    final Server server = ref.read(serverProvider(serverId));
    final RiskyOutcome outcome = await confirmRisky(
      context,
      ref,
      RiskyAction(
        title: 'Unpair ${server.name}?',
        subtitle: 'Revokes this device key',
        explanation:
            "This phone's device key is revoked on the agent and the server "
            'disappears from your list. Other paired phones keep working. If '
            'this is the last admin phone the agent refuses, so promote '
            'another one first.',
        requestLine: 'DELETE /v1/devices/${server.deviceId}',
        confirmLabel: 'Unpair server',
        icon: Icons.link_off,
        requireFingerprint: riskyNeedsFingerprint(ref, serverId),
        target: server.name,
      ),
    );
    if (!outcome.confirmed || !context.mounted) return;
    try {
      await ref
          .read(serversRepositoryProvider)
          .unpair(serverId, confirmed: outcome.confirmation);
      ref.invalidate(serverCardsProvider);
      if (context.mounted) {
        notify(context, '${server.name} unpaired');
        context.go('/');
      }
    } on AgentException catch (error) {
      if (context.mounted) notify(context, error.toString(), danger: true);
    }
  }

  /// "Read-only on this phone" is the `viewer` role now, not a client switch
  /// (Revision 1.1 closes open decision 3). Only an admin can set it, and only
  /// another admin can undo it.
  Future<void> _setReadOnly(
    BuildContext context,
    WidgetRef ref,
    Server server,
  ) async {
    final bool? go = await showAdaptiveModal<bool>(
      context,
      builder: (BuildContext context, bool sheet) =>
          _ReadOnlyExplainer(sheet: sheet),
    );
    if (go != true || !context.mounted) return;
    final bool ok = await runAction(
      context,
      ref,
      () => ref
          .read(agentApiProvider(serverId))
          .updateDevice(server.deviceId, role: ServerRole.viewer),
      success: 'This phone is read-only on ${server.name}',
    );
    if (!ok) return;
    ref.invalidate(meProvider(serverId));
    ref.invalidate(devicesProvider(serverId));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final Server server = ref.watch(serverProvider(serverId));
    final AsyncValue<MeInfo?> me = ref.watch(meProvider(serverId));
    final ServerRole role = ref.watch(roleProvider(serverId));
    final AsyncValue<AgentUpdate> update = ref.watch(
      agentUpdateProvider(serverId),
    );
    final AsyncValue<AgentSettings> settings = ref.watch(
      agentSettingsProvider(serverId),
    );
    final AsyncValue<List<RegistryInfo>> registries = ref.watch(
      registriesProvider(serverId),
    );
    final AsyncValue<List<AlertRule>> rules = ref.watch(
      alertRulesProvider(serverId),
    );
    final AsyncValue<List<DeviceInfo>> devices = ref.watch(
      devicesProvider(serverId),
    );
    final MeInfo? identity = me.valueOrNull;
    final String fingerprint = identity?.certFingerprint.isNotEmpty == true
        ? identity!.certFingerprint
        : server.certFingerprint;
    final int? phones = identity?.pairedDevices ?? devices.valueOrNull?.length;

    return PushedPage(
      gap: 14,
      fillLast: true,
      children: <Widget>[
        const BackLink('Overview'),
        ScreenHeader(title: 'Server settings', subtitle: server.name),
        AsyncSection<AgentUpdate>(
          value: update,
          onRetry: () => ref.invalidate(agentUpdateProvider(serverId)),
          loadingRows: 1,
          loadingRowHeight: 74,
          builder: (AgentUpdate u) => DoomCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            borderColor: u.available ? t.warningBorder : t.border,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        'Agent ${u.current}',
                        style: AppText.rowTitle.copyWith(color: t.text),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        u.available
                            ? 'Version ${u.latest} is available'
                            : (u.configured
                                  ? 'Up to date'
                                  : 'No update channel is configured'),
                        style: AppText.small.copyWith(
                          color: u.available ? t.warning : t.mutedText,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (u.available && role.canUpdateAgent)
                  DoomButton(
                    'Update agent',
                    tone: ButtonTone.primary,
                    onPressed: () => runJob(
                      context,
                      ref,
                      serverId,
                      (api) => api.startAgentUpdate(),
                    ),
                  ),
              ],
            ),
          ),
        ),
        RowGroup(
          children: <Widget>[
            // Long hosts and fingerprints lose their middle rather than
            // wrapping onto a second line.
            DetailRow(
              'Agent URL',
              server.host,
              mono: true,
              middleEllipsis: true,
            ),
            _FingerprintRow(fingerprint: fingerprint),
            DetailRow('Your role', role.label),
          ],
        ),
        RowGroup(
          children: <Widget>[
            NavRow(
              label: 'Registry credentials',
              value: registries.maybeWhen(
                data: (List<RegistryInfo> list) =>
                    '${list.where((RegistryInfo r) => r.hasCredential).length} signed in',
                orElse: () => '…',
              ),
              onTap: () => context.push('/s/$serverId/settings/registries'),
            ),
            NavRow(
              label: 'Alert rules',
              value: rules.maybeWhen(
                data: (List<AlertRule> list) =>
                    '${list.where((AlertRule r) => r.enabled).length} active',
                orElse: () => '…',
              ),
              onTap: () => context.push('/s/$serverId/alerts'),
            ),
            NavRow(
              label: 'Paired devices',
              value: phones == null
                  ? '…'
                  : '$phones phone${phones == 1 ? '' : 's'}',
              onTap: () => context.push('/s/$serverId/settings/devices'),
            ),
            NavRow(
              label: 'Activity log',
              value: 'Who did what, and when',
              onTap: () => context.push('/s/$serverId/settings/activity'),
            ),
          ],
        ),
        AsyncSection<AgentSettings>(
          value: settings,
          onRetry: () => ref.invalidate(agentSettingsProvider(serverId)),
          loadingRows: 2,
          loadingRowHeight: 60,
          builder: (AgentSettings s) => RowGroup(
            children: <Widget>[
              SwitchRow(
                label: 'Fingerprint before risky actions',
                description: 'Stop, remove, prune and stack down',
                value: s.requireBiometricForRisky,
                onChanged: role.canEditSettings
                    ? (bool value) async {
                        final bool ok = await runAction(
                          context,
                          ref,
                          () => ref
                              .read(agentApiProvider(serverId))
                              .updateSettings(requireBiometricForRisky: value),
                        );
                        if (ok) {
                          ref.invalidate(agentSettingsProvider(serverId));
                        }
                      }
                    : null,
              ),
              SwitchRow(
                label: 'Read-only on this phone',
                description: role == ServerRole.viewer
                    ? 'On. Another admin has to change it back.'
                    : 'Sets this device to the viewer role on the agent',
                value: role == ServerRole.viewer,
                // Turning it off is the agent's business, not this phone's.
                onChanged: role.canManageDevices
                    ? (bool value) =>
                          value ? _setReadOnly(context, ref, server) : null
                    : null,
              ),
            ],
          ),
        ),
        DoomButton(
          'Unpair this server',
          tone: ButtonTone.danger,
          height: 48,
          radius: 16,
          expand: true,
          onPressed: () => _unpair(context, ref),
        ),
      ],
    );
  }
}

/// The pinned fingerprint, shortened for the row and copyable in full.
class _FingerprintRow extends StatelessWidget {
  const _FingerprintRow({required this.fingerprint});

  final String fingerprint;

  static String shorten(String value) {
    final List<String> parts = value.split(':');
    if (parts.length < 6) return value;
    return '${parts.take(2).join(':')}…${parts.skip(parts.length - 2).join(':')}';
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        Clipboard.setData(ClipboardData(text: fingerprint));
        notify(context, 'Pinned fingerprint copied');
      },
      child: DetailRow(
        'Certificate',
        'Pinned · ${shorten(fingerprint)}',
        mono: true,
        middleEllipsis: true,
      ),
    );
  }
}

class _ReadOnlyExplainer extends StatelessWidget {
  const _ReadOnlyExplainer({required this.sheet});

  final bool sheet;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return ModalBody(
      handle: sheet,
      children: <Widget>[
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Make this phone read-only?',
              style: AppText.sheetTitle.copyWith(color: t.text),
            ),
            const SizedBox(height: 8),
            Text(
              'This sets this device to the viewer role on the agent, so it '
              'can read everything and change nothing. It is enforced by the '
              'agent, not hidden by the app.',
              style: AppText.body.copyWith(color: t.mutedText, height: 1.5),
            ),
            const SizedBox(height: 14),
            const InfoNote(
              icon: Icons.warning_amber_rounded,
              text:
                  'You cannot undo this from this phone. Another admin device '
                  'has to set the role back with PATCH /v1/devices/{id}.',
            ),
            const SizedBox(height: 14),
            const CodeBlock(
              caption: 'Request sent to the agent',
              code: 'PATCH /v1/devices/{id} {"role": "viewer"}',
            ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: DoomButton(
                    'Cancel',
                    expand: true,
                    height: 54,
                    radius: 16,
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DoomButton(
                    'Make read-only',
                    expand: true,
                    height: 54,
                    radius: 16,
                    tone: ButtonTone.dangerFilled,
                    onPressed: () => Navigator.of(context).pop(true),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
