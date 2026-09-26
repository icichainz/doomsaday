import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../../data/this_device.dart';
import '../../layout/layout.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/actions.dart';
import '../../widgets/buttons.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/desktop.dart';
import '../../widgets/page.dart';
import '../../widgets/primitives.dart';
import '../../widgets/sheets.dart';
import '../../widgets/state_views.dart';
import '../../widgets/surfaces.dart';
import '../../widgets/stroke_icons.dart';
import '../../widgets/table.dart';

/// What each role may do, in the words the role sheet uses.
String roleSummary(ServerRole role) => switch (role) {
  ServerRole.admin =>
    'Everything, including shell, environment values and devices',
  ServerRole.operator => 'Start, stop, restart, pull and redeploy',
  ServerRole.viewer => 'Read only',
};

/// True when [device] is the only admin in [devices]: the agent refuses to
/// demote or revoke it with `409`, so the app does not offer either.
bool isLastAdmin(DeviceInfo device, List<DeviceInfo> devices) =>
    device.role.isAdmin &&
    devices.where((DeviceInfo d) => d.role.isAdmin).length == 1;

/// What a device is called on screen: this device by the hardware's own name
/// ([thisDeviceLabel], the same words the sidebar footer and the activity
/// sentences use), every other one by the name it was paired under.
String deviceLabel(DeviceInfo device) =>
    device.isSelf ? thisDeviceLabel() : device.name;

/// `Last seen 1 day ago · push on`, or `last seen just now` after the
/// "This device" marker.
String deviceMeta(DeviceInfo device) {
  final String seen =
      '${device.isSelf ? 'last' : 'Last'} seen '
      '${device.lastSeen}';
  return device.hasPushToken ? '$seen · push on' : seen;
}

/// `GET /devices` — the phones and Macs paired with this agent.
///
/// One row per device with its role and a more button; the actions (change
/// role, revoke) open as a sheet, a dialog from 600 up. Boards:
/// `design/Devices.dc.html` and `design/DeviceActions.dc.html`.
class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key, required this.serverId});

  final String serverId;

  Future<void> _setRole(
    BuildContext context,
    WidgetRef ref,
    DeviceInfo device,
    ServerRole role,
  ) async {
    if (role == device.role) return;
    final bool ok = await runAction(
      context,
      ref,
      () => ref
          .read(agentApiProvider(serverId))
          .updateDevice(device.id, role: role),
      success: '${deviceLabel(device)} is now ${role.label.toLowerCase()}',
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
        title: 'Revoke ${deviceLabel(device)}?',
        subtitle: '$serverId · ${device.role.label}',
        explanation:
            'That device\'s key stops working immediately. It has to be '
            'paired again with a fresh token to come back.',
        requestLine: 'DELETE /v1/devices/${device.id}',
        confirmLabel: 'Revoke device',
        glyph: StrokeGlyph.unlink,
        requireFingerprint: riskyNeedsFingerprint(ref, serverId),
        target: deviceLabel(device),
      ),
    );
    if (!outcome.confirmed || !context.mounted) return;
    final bool ok = await runAction(
      context,
      ref,
      () => ref
          .read(agentApiProvider(serverId))
          .removeDevice(device.id, confirmed: outcome.confirmation),
      success: '${deviceLabel(device)} revoked',
    );
    if (ok) ref.invalidate(devicesProvider(serverId));
  }

  /// The more button and the right-click menu both land here.
  Future<void> _openActions(
    BuildContext context,
    WidgetRef ref,
    DeviceInfo device,
    List<DeviceInfo> all,
  ) async {
    final DeviceChoice? choice = await showAdaptiveModal<DeviceChoice>(
      context,
      builder: (BuildContext context, bool sheet) => DeviceActionsBody(
        serverId: serverId,
        device: device,
        lastAdmin: isLastAdmin(device, all),
        sheet: sheet,
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice.revoke) {
      await _revoke(context, ref, device);
    } else if (choice.role != null) {
      await _setRole(context, ref, device, choice.role!);
    }
  }

  /// Change role and Revoke, for the right-click menu on a row.
  List<MenuAction> _menu(
    BuildContext context,
    WidgetRef ref,
    DeviceInfo device,
    List<DeviceInfo> all,
    bool isAdmin,
  ) => <MenuAction>[
    for (final ServerRole role in ServerRole.values)
      MenuAction(
        label: 'Make ${role.label.toLowerCase()}',
        enabled: isAdmin && role != device.role && !isLastAdmin(device, all),
        onSelected: () => _setRole(context, ref, device, role),
      ),
    MenuAction(
      label: 'Revoke',
      glyph: StrokeGlyph.unlink,
      danger: true,
      enabled: isAdmin && !isLastAdmin(device, all),
      onSelected: () => _revoke(context, ref, device),
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<DeviceInfo>> devices = ref.watch(
      devicesProvider(serverId),
    );
    final bool isAdmin = ref.watch(roleProvider(serverId)).canManageDevices;
    final int? count = devices.valueOrNull?.length;
    final String subtitle = count == null
        ? 'Devices that hold a key for $serverId'
        : '$count device${count == 1 ? '' : 's'} hold'
              '${count == 1 ? 's' : ''} a key for $serverId';
    const EmptyView empty = EmptyView(
      glyph: StrokeGlyph.phone,
      title: 'No devices',
      message: 'The agent reports no paired devices.',
    );
    const Widget note = InfoNote(
      glyph: StrokeGlyph.shield,
      text:
          'The first device to pair is admin and every later one is an '
          "operator. The last admin can't be demoted or revoked, so the "
          'host is never locked out of its own agent.',
    );

    // DesktopDevices: left-aligned under the page header with the way back
    // to Server settings, and the devices as a table.
    if (WindowClass.of(context).usesDesktopExtras) {
      return DesktopPage(
        children: <Widget>[
          DesktopHeader(
            eyebrow: DesktopBackLink(
              label: 'Server settings',
              onTap: () => context.go('/s/$serverId/settings'),
            ),
            title: 'Paired devices',
            subtitle: subtitle,
          ),
          AsyncSection<List<DeviceInfo>>(
            value: devices,
            onRetry: () => ref.invalidate(devicesProvider(serverId)),
            loadingRows: 3,
            loadingRowHeight: 46,
            isEmpty: (List<DeviceInfo> list) => list.isEmpty,
            empty: empty,
            builder: (List<DeviceInfo> list) => DeviceTable(
              devices: list,
              onActions: isAdmin
                  ? (DeviceInfo device) =>
                        _openActions(context, ref, device, list)
                  : null,
              menu: (DeviceInfo device) =>
                  _menu(context, ref, device, list, isAdmin),
            ),
          ),
          note,
        ],
      );
    }

    return PushedPage(
      gap: 14,
      children: <Widget>[
        const BackLink('Settings'),
        ScreenHeader(title: 'Paired devices', subtitle: subtitle),
        AsyncSection<List<DeviceInfo>>(
          value: devices,
          onRetry: () => ref.invalidate(devicesProvider(serverId)),
          loadingRows: 3,
          loadingRowHeight: 66,
          isEmpty: (List<DeviceInfo> list) => list.isEmpty,
          empty: empty,
          builder: (List<DeviceInfo> list) => RowGroup(
            trailingPadding: isAdmin ? 6 : 16,
            children: <Widget>[
              for (final DeviceInfo device in list)
                _DeviceRow(
                  device: device,
                  onActions: isAdmin
                      ? () => _openActions(context, ref, device, list)
                      : null,
                  menu: () => _menu(context, ref, device, list, isAdmin),
                ),
            ],
          ),
        ),
        note,
      ],
    );
  }
}

/// DesktopDevices' table: Device, Role, Last seen, Push and the more button
/// that opens the same actions dialog as the phone's sheet. A right-click on
/// a row offers the role changes and Revoke as a menu.
class DeviceTable extends StatelessWidget {
  const DeviceTable({
    super.key,
    required this.devices,
    required this.onActions,
    required this.menu,
  });

  final List<DeviceInfo> devices;

  /// Null for a device that may not manage devices: no more button and no
  /// menu, as on the phone.
  final void Function(DeviceInfo device)? onActions;
  final List<MenuAction> Function(DeviceInfo device) menu;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return DataTableView<DeviceInfo>(
      rows: devices,
      rowMenuButton: false,
      actions: onActions == null ? null : menu,
      footer: onActions == null
          ? null
          : Text(
              'Right-click a row to change its role or revoke it',
              style: TextStyle(fontSize: 12.5, color: t.mutedText),
            ),
      columns: <TableColumn<DeviceInfo>>[
        TableColumn<DeviceInfo>(
          label: 'Device',
          cell: (BuildContext c, DeviceInfo d) => Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Flexible(child: CellText(deviceLabel(d), bold: true)),
              if (d.isSelf) ...<Widget>[
                const SizedBox(width: 10),
                Text(
                  'This device',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: t.accent,
                  ),
                ),
              ],
            ],
          ),
        ),
        TableColumn<DeviceInfo>(
          label: 'Role',
          width: 130,
          cell: (BuildContext c, DeviceInfo d) => StatusPill(
            d.role.label,
            tone: d.role.isAdmin ? PillTone.accent : PillTone.neutral,
          ),
        ),
        TableColumn<DeviceInfo>(
          label: 'Last seen',
          width: 150,
          cell: (BuildContext c, DeviceInfo d) =>
              CellText(d.lastSeen, muted: true),
        ),
        TableColumn<DeviceInfo>(
          label: 'Push',
          width: 90,
          cell: (BuildContext c, DeviceInfo d) =>
              CellText(d.hasPushToken ? 'On' : 'Off', muted: !d.hasPushToken),
        ),
        if (onActions != null)
          TableColumn<DeviceInfo>(
            label: '',
            width: 36,
            numeric: true,
            cell: (BuildContext c, DeviceInfo d) => DoomIconButton(
              glyph: StrokeGlyph.more,
              semanticLabel: 'Actions for ${deviceLabel(d)}',
              size: 32,
              radius: 8,
              filled: false,
              foreground: t.mutedText,
              onPressed: () => onActions!(d),
            ),
          ),
      ],
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.device,
    required this.onActions,
    required this.menu,
  });

  final DeviceInfo device;
  final VoidCallback? onActions;
  final List<MenuAction> Function() menu;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return ContextMenuRegion(
      actions: onActions == null ? () => const <MenuAction>[] : menu,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 66),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    deviceLabel(device),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.rowTitle.copyWith(color: t.text),
                  ),
                  const SizedBox(height: 3),
                  Text.rich(
                    TextSpan(
                      children: <InlineSpan>[
                        if (device.isSelf)
                          TextSpan(
                            text: 'This device · ',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: t.accent,
                            ),
                          ),
                        TextSpan(text: deviceMeta(device)),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.small.copyWith(color: t.mutedText),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            StatusPill(
              device.role.label,
              tone: device.role.isAdmin ? PillTone.accent : PillTone.neutral,
            ),
            if (onActions != null) ...<Widget>[
              const SizedBox(width: 8),
              DoomIconButton(
                glyph: StrokeGlyph.more,
                semanticLabel: 'Actions for ${deviceLabel(device)}',
                size: 44,
                radius: 12,
                filled: false,
                foreground: t.mutedText,
                onPressed: onActions,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// What the actions sheet was closed with.
class DeviceChoice {
  const DeviceChoice.role(ServerRole this.role) : revoke = false;
  const DeviceChoice.revoke() : role = null, revoke = true;

  final ServerRole? role;
  final bool revoke;
}

/// The sheet behind a device's more button: its role as three choices, the
/// last-admin rule when it applies, and Revoke.
class DeviceActionsBody extends StatelessWidget {
  const DeviceActionsBody({
    super.key,
    required this.serverId,
    required this.device,
    required this.lastAdmin,
    required this.sheet,
  });

  final String serverId;
  final DeviceInfo device;
  final bool lastAdmin;
  final bool sheet;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return ModalBody(
      handle: sheet,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: t.iconButtonFill,
                borderRadius: BorderRadius.circular(16),
              ),
              child: StrokeIcon(StrokeGlyph.phone, size: 22, color: t.text),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    deviceLabel(device),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.sheetTitle.copyWith(color: t.text),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    device.isSelf
                        ? 'This device · ${deviceMeta(device)}'
                        : deviceMeta(device),
                    style: AppText.small.copyWith(color: t.mutedText),
                  ),
                ],
              ),
            ),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SectionHeader('Role'),
            const SizedBox(height: 8),
            Semantics(
              label: 'Role for ${deviceLabel(device)}',
              container: true,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  borderRadius: AppShape.smallCardRadius,
                  border: Border.all(color: t.border),
                ),
                child: Column(
                  children: <Widget>[
                    for (final ServerRole role in ServerRole.values)
                      _RoleOption(
                        role: role,
                        selected: role == device.role,
                        divider: role != ServerRole.values.last,
                        onTap: lastAdmin && role != device.role
                            ? null
                            : () => Navigator.of(
                                context,
                              ).pop(DeviceChoice.role(role)),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (lastAdmin) LastAdminNote(serverId: serverId),
        Row(
          children: <Widget>[
            Expanded(
              child: DoomButton(
                'Close',
                expand: true,
                height: 54,
                radius: 16,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DoomButton(
                'Revoke device',
                expand: true,
                height: 54,
                radius: 16,
                tone: ButtonTone.danger,
                onPressed: lastAdmin
                    ? null
                    : () => Navigator.of(
                        context,
                      ).pop(const DeviceChoice.revoke()),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _RoleOption extends StatelessWidget {
  const _RoleOption({
    required this.role,
    required this.selected,
    required this.divider,
    required this.onTap,
  });

  final ServerRole role;
  final bool selected;
  final bool divider;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      enabled: onTap != null,
      button: true,
      child: Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 58),
            decoration: BoxDecoration(
              border: divider
                  ? Border(bottom: BorderSide(color: t.border))
                  : null,
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 20,
                  height: 20,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? t.accent : t.outlineBorder,
                      width: 2,
                    ),
                  ),
                  child: selected
                      ? Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: t.accent,
                            shape: BoxShape.circle,
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          role.label,
                          style: AppText.rowTitle.copyWith(color: t.text),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          roleSummary(role),
                          style: AppText.tiny.copyWith(color: t.mutedText),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The warning card that explains the `409` before anyone runs into it.
class LastAdminNote extends StatelessWidget {
  const LastAdminNote({super.key, required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.warningTint,
        borderRadius: AppShape.smallCardRadius,
        border: Border.all(color: t.warningBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          StrokeIcon(StrokeGlyph.warning, size: 20, color: t.warning),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  'The only admin on $serverId',
                  style: AppText.label.copyWith(
                    color: t.warning,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'The agent refuses to demote or revoke the last admin '
                  '(409). Make another device admin first.',
                  style: AppText.small.copyWith(
                    color: t.codeText,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
