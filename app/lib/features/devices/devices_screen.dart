import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/actions.dart';
import '../../widgets/buttons.dart';
import '../../widgets/page.dart';
import '../../widgets/primitives.dart';
import '../../widgets/sheets.dart';
import '../../widgets/state_views.dart';

/// `GET /devices` — the phones paired with this agent.
///
/// Reachable from the "Paired devices" row on Server settings, which used to
/// be a dead row. Role changes and revocation are admin only and the agent
/// refuses both on the last admin with `409`.
class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key, required this.serverId});

  final String serverId;

  Future<void> _setRole(
    BuildContext context,
    WidgetRef ref,
    DeviceInfo device,
    ServerRole role,
  ) async {
    final bool ok = await runAction(
      context,
      ref,
      () => ref
          .read(agentApiProvider(serverId))
          .updateDevice(device.id, role: role),
      success: '${device.name} is now ${role.label.toLowerCase()}',
    );
    if (!ok) return;
    ref.invalidate(devicesProvider(serverId));
    ref.invalidate(meProvider(serverId));
  }

  Future<void> _revoke(
    BuildContext context,
    WidgetRef ref,
    DeviceInfo device,
  ) async {
    final RiskyOutcome outcome = await confirmRisky(
      context,
      ref,
      RiskyAction(
        title: 'Revoke ${device.name}?',
        subtitle: '$serverId · ${device.role.label}',
        explanation:
            'That phone\'s device key stops working immediately. It has to be '
            'paired again with a fresh token to come back.',
        requestLine: 'DELETE /v1/devices/${device.id}',
        confirmLabel: 'Revoke device',
        icon: Icons.link_off,
        requireFingerprint: riskyNeedsFingerprint(ref, serverId),
        target: device.name,
      ),
    );
    if (!outcome.confirmed || !context.mounted) return;
    final bool ok = await runAction(
      context,
      ref,
      () => ref
          .read(agentApiProvider(serverId))
          .removeDevice(device.id, confirmed: outcome.confirmation),
      success: '${device.name} revoked',
    );
    if (ok) ref.invalidate(devicesProvider(serverId));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final AsyncValue<List<DeviceInfo>> devices = ref.watch(
      devicesProvider(serverId),
    );
    final bool isAdmin = ref.watch(roleProvider(serverId)).canManageDevices;

    return PushedPage(
      gap: 14,
      children: <Widget>[
        const BackLink('Settings'),
        ScreenHeader(
          title: 'Paired devices',
          subtitle: 'Phones that hold a device key for $serverId',
        ),
        AsyncSection<List<DeviceInfo>>(
          value: devices,
          onRetry: () => ref.invalidate(devicesProvider(serverId)),
          loadingRows: 3,
          loadingRowHeight: 84,
          isEmpty: (List<DeviceInfo> list) => list.isEmpty,
          empty: const EmptyView(
            icon: Icons.phone_iphone,
            title: 'No devices',
            message: 'The agent reports no paired phones.',
          ),
          builder: (List<DeviceInfo> list) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final DeviceInfo device in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: DoomCard(
                    borderColor: device.isSelf ? t.accent : t.border,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Text(
                                    device.isSelf
                                        ? '${device.name} · this phone'
                                        : device.name,
                                    style: AppText.rowTitle.copyWith(
                                      color: t.text,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    'Last seen ${device.lastSeen}'
                                    '${device.hasPushToken ? ' · push on' : ''}',
                                    style: AppText.tiny.copyWith(
                                      color: t.mutedText,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            StatusPill(
                              device.role.label,
                              tone: device.role.isAdmin
                                  ? PillTone.accent
                                  : PillTone.neutral,
                            ),
                          ],
                        ),
                        if (isAdmin) ...<Widget>[
                          const SizedBox(height: 12),
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: SegmentedControl(
                                  semanticLabel: 'Role for ${device.name}',
                                  labels: const <String>[
                                    'Admin',
                                    'Operator',
                                    'Viewer',
                                  ],
                                  index: ServerRole.values.indexOf(device.role),
                                  onChanged: (int i) => _setRole(
                                    context,
                                    ref,
                                    device,
                                    ServerRole.values[i],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              DoomButton(
                                'Revoke',
                                tone: ButtonTone.danger,
                                onPressed: () => _revoke(context, ref, device),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const InfoNote(
          icon: Icons.shield_outlined,
          text:
              'The first phone to pair is admin and every later one is an '
              'operator. The last admin cannot be demoted or revoked, so the '
              'host can never be locked out of its own agent.',
        ),
      ],
    );
  }
}
