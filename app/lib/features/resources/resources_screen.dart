import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../../layout/layout.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/actions.dart';
import '../../widgets/buttons.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/desktop.dart';
import '../../widgets/notify.dart';
import '../../widgets/page.dart';
import '../../widgets/primitives.dart';
import '../../widgets/sheets.dart';
import '../../widgets/state_views.dart';
import '../../widgets/stroke_icons.dart';
import '../../widgets/surfaces.dart';
import '../../widgets/table.dart';
import 'resource_table.dart';

/// Screens 11, 12 and 13 — Images, Volumes and Networks behind one segmented
/// control, reached from the Resources tab.
class ResourcesScreen extends ConsumerStatefulWidget {
  const ResourcesScreen({super.key, required this.serverId});

  final String serverId;

  @override
  ConsumerState<ResourcesScreen> createState() => _ResourcesScreenState();
}

class _ResourcesScreenState extends ConsumerState<ResourcesScreen> {
  int _segment = 0;

  @override
  Widget build(BuildContext context) {
    final String serverId = widget.serverId;
    final String title = const <String>[
      'Images',
      'Volumes',
      'Networks',
    ][_segment];
    final Widget segment = SegmentedControl(
      semanticLabel: 'Resource type',
      labels: const <String>['Images', 'Volumes', 'Networks'],
      index: _segment,
      onChanged: (int i) => setState(() => _segment = i),
    );
    final Widget body = switch (_segment) {
      0 => _Images(serverId: serverId),
      1 => _Volumes(serverId: serverId),
      _ => _Networks(serverId: serverId),
    };

    if (WindowClass.of(context).usesDesktopExtras) {
      return DesktopPage(
        children: <Widget>[
          DesktopHeader(
            title: title,
            subtitle: _subtitle(),
            actions: <Widget>[SizedBox(width: 330, child: segment)],
          ),
          body,
        ],
      );
    }
    return ShellPage(
      gap: 14,
      children: <Widget>[
        ScreenHeader(title: title, subtitle: _subtitle()),
        segment,
        body,
      ],
    );
  }

  String _subtitle() {
    final String serverId = widget.serverId;
    switch (_segment) {
      case 0:
        final ImageList? list = ref.watch(imagesProvider(serverId)).valueOrNull;
        if (list == null) return 'Reading images…';
        return '${list.totalCount} images · ${formatBytes(list.totalBytes)} · '
            '${formatBytes(list.reclaimableBytes)} unused';
      case 1:
        final VolumeList? list = ref
            .watch(volumesProvider(serverId))
            .valueOrNull;
        if (list == null) return 'Reading volumes…';
        return '${list.count} volumes · ${formatBytes(list.totalBytes)} · '
            '${list.unmounted} not mounted';
      default:
        final NetworkList? list = ref
            .watch(networksProvider(serverId))
            .valueOrNull;
        if (list == null) return 'Reading networks…';
        // The desktop table calls a default network "Default", not unused,
        // so its count is the networks that could actually be pruned.
        final int unused = WindowClass.of(context).usesDesktopExtras
            ? list.networks.where((NetworkInfo n) => n.removable).length
            : list.unused;
        return '${list.count} networks · $unused unused';
    }
  }
}

/// Primary create/pull button plus Prune unused, as on all three screens.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.label,
    required this.onCreate,
    required this.onPrune,
    required this.canCreate,
    required this.canPrune,
  });

  final String label;
  final VoidCallback onCreate;
  final VoidCallback onPrune;

  /// Creating and pruning are admin only in Revision 1.1's role map, so the
  /// buttons are not drawn for anyone else.
  final bool canCreate;
  final bool canPrune;

  @override
  Widget build(BuildContext context) {
    if (!canCreate && !canPrune) return const SizedBox.shrink();
    return Row(
      children: <Widget>[
        if (canCreate)
          Expanded(
            child: DoomButton(
              label,
              glyph: StrokeGlyph.plus,
              tone: ButtonTone.primary,
              height: 48,
              radius: 14,
              expand: true,
              onPressed: onCreate,
            ),
          ),
        if (canCreate && canPrune) const SizedBox(width: 8),
        if (canPrune)
          Expanded(
            flex: canCreate ? 0 : 1,
            child: DoomButton(
              'Prune unused',
              height: 48,
              radius: 14,
              expand: !canCreate,
              onPressed: onPrune,
            ),
          ),
      ],
    );
  }
}

/// One list row: monospaced name, meta line, pill and an actions button.
class _ResourceRow extends StatelessWidget {
  const _ResourceRow({
    required this.name,
    required this.meta,
    required this.pill,
    required this.tone,
    required this.actionsLabel,
    required this.onActions,
  });

  final String name;
  final String meta;
  final String pill;
  final PillTone tone;
  final String actionsLabel;
  final VoidCallback onActions;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 64),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.mono.copyWith(color: t.text),
                ),
                const SizedBox(height: 3),
                Text(meta, style: AppText.tiny.copyWith(color: t.mutedText)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          StatusPill(pill, tone: tone),
          const SizedBox(width: 4),
          DoomIconButton(
            glyph: StrokeGlyph.more,
            semanticLabel: actionsLabel,
            size: 44,
            radius: 12,
            filled: false,
            foreground: t.mutedText,
            onPressed: onActions,
          ),
        ],
      ),
    );
  }
}

/// Small sheet behind the three-dot button.
Future<void> _showRowActions(
  BuildContext context, {
  required String title,
  required String subtitle,
  required bool canRemove,
  required VoidCallback onRemove,
}) {
  return showAdaptiveModal<void>(
    context,
    builder: (BuildContext context, bool sheet) {
      final AppTokens t = context.tokens;
      return ModalBody(
        handle: sheet,
        children: <Widget>[
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(title, style: AppText.rowTitle.copyWith(color: t.text)),
              const SizedBox(height: 4),
              Text(subtitle, style: AppText.small.copyWith(color: t.mutedText)),
              const SizedBox(height: 16),
              if (canRemove)
                DoomButton(
                  'Remove',
                  glyph: StrokeGlyph.trash,
                  tone: ButtonTone.danger,
                  height: 48,
                  radius: 14,
                  expand: true,
                  onPressed: () {
                    Navigator.of(context).pop();
                    onRemove();
                  },
                )
              else
                Text(
                  'Removing this needs the admin role on this server.',
                  style: AppText.small.copyWith(color: t.mutedText),
                ),
            ],
          ),
        ],
      );
    },
  );
}

class _Images extends ConsumerWidget {
  const _Images({required this.serverId});

  final String serverId;

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    DockerImage image,
  ) async {
    final RiskyOutcome outcome = await confirmRisky(
      context,
      ref,
      RiskyAction(
        title: 'Remove ${image.ref}?',
        subtitle: '$serverId · ${formatBytes(image.sizeBytes)}',
        explanation: image.inUse
            ? 'A container is using this image, so the agent answers 409 unless '
                  'you force it.'
            : 'The image layers are deleted. Anything that needs it again has '
                  'to pull it from the registry.',
        requestLine: 'DELETE /v1/images/${image.id}?force=${image.inUse}',
        confirmLabel: 'Remove image',
        glyph: StrokeGlyph.trash,
        requireFingerprint: riskyNeedsFingerprint(ref, serverId),
        target: image.ref,
      ),
    );
    if (!outcome.confirmed || !context.mounted) return;
    await runAction(
      context,
      ref,
      () => ref
          .read(agentApiProvider(serverId))
          .removeImage(
            image.id,
            force: image.inUse,
            confirmed: outcome.confirmation,
          ),
      success: '${image.ref} removed',
    );
  }

  Future<void> _prune(BuildContext context, WidgetRef ref) async {
    final RiskyOutcome outcome = await confirmRisky(
      context,
      ref,
      RiskyAction(
        title: 'Prune unused images?',
        subtitle: 'Frees whatever nothing references',
        explanation:
            'Every image no container is using is deleted. Pulling them back '
            'later costs bandwidth, nothing else.',
        requestLine: 'POST /v1/images/prune {"dangling_only": false}',
        confirmLabel: 'Prune images',
        glyph: StrokeGlyph.prune,
        requireFingerprint: riskyNeedsFingerprint(ref, serverId),
        target: 'prune images',
      ),
    );
    if (!outcome.confirmed || !context.mounted) return;
    await runJob(
      context,
      ref,
      serverId,
      (api) =>
          api.pruneImages(danglingOnly: false, confirmed: outcome.confirmation),
    );
  }

  /// The same actions as the row's more button, for the right-click menu.
  List<MenuAction> _menu(
    BuildContext context,
    WidgetRef ref,
    DockerImage image,
    ServerRole role,
  ) => <MenuAction>[
    MenuAction(
      label: 'Copy reference',
      glyph: StrokeGlyph.copy,
      onSelected: () {
        Clipboard.setData(ClipboardData(text: image.ref));
        notify(context, 'Image reference copied');
      },
    ),
    MenuAction(
      label: 'Show containers',
      glyph: StrokeGlyph.containers,
      onSelected: () => notify(
        context,
        image.inUse
            ? 'Used by ${image.inUseBy.join(', ')}'
            : 'No container uses ${image.ref}',
      ),
    ),
    MenuAction(
      label: 'Remove',
      glyph: StrokeGlyph.trash,
      danger: true,
      enabled: role.canRemove,
      onSelected: () => _remove(context, ref, image),
    ),
  ];

  Future<void> _pull(BuildContext context, WidgetRef ref) async {
    final String? reference = await showPromptSheet(
      context,
      title: 'Pull an image',
      subtitle: 'Uses the stored registry credentials',
      label: 'Image reference',
      hint: 'registry.example.com/api:2.9.0',
      confirmLabel: 'Pull',
      glyph: StrokeGlyph.download,
    );
    if (reference == null || !context.mounted) return;
    await runJob(context, ref, serverId, (api) => api.pullImage(reference));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<ImageList> images = ref.watch(imagesProvider(serverId));
    final ServerRole role = ref.watch(roleProvider(serverId));
    if (WindowClass.of(context).usesDesktopExtras) {
      return AsyncSection<ImageList>(
        value: images,
        onRetry: () => ref.invalidate(imagesProvider(serverId)),
        loadingRows: 6,
        loadingRowHeight: 46,
        isEmpty: (ImageList list) => list.images.isEmpty,
        empty: const EmptyView(
          glyph: StrokeGlyph.resources,
          title: 'No images',
          message: 'Nothing has been pulled on this host yet.',
        ),
        builder: (ImageList list) => ResourceTable<DockerImage>(
          rows: list.images,
          filterHint: 'Filter images',
          emptyTitle: 'No matching images',
          initialSort: 1,
          initialAscending: false,
          footer:
              'right-click a row for Remove, Copy reference and Show '
              'containers',
          matches: (DockerImage i, String q) =>
              i.ref.toLowerCase().contains(q) ||
              i.inUseBy.any((String c) => c.toLowerCase().contains(q)),
          chips: <ResourceChip<DockerImage>>[
            ResourceChip<DockerImage>(
              label: 'All ${list.images.length}',
              keep: null,
            ),
            ResourceChip<DockerImage>(
              label:
                  'In use '
                  '${list.images.where((DockerImage i) => i.inUse).length}',
              keep: (DockerImage i) => i.inUse,
            ),
            ResourceChip<DockerImage>(
              label:
                  'Unused '
                  '${list.images.where((DockerImage i) => !i.inUse).length}',
              keep: (DockerImage i) => !i.inUse,
            ),
          ],
          actions: <Widget>[
            if (role.canPrune)
              DoomButton(
                'Prune unused',
                height: 36,
                radius: 10,
                onPressed: () => _prune(context, ref),
              ),
            if (role.canOperate)
              DoomButton(
                'Pull image',
                glyph: StrokeGlyph.plus,
                height: 36,
                radius: 10,
                tone: ButtonTone.primary,
                onPressed: () => _pull(context, ref),
              ),
          ],
          menu: (DockerImage image) => _menu(context, ref, image, role),
          columns: <TableColumn<DockerImage>>[
            TableColumn<DockerImage>(
              label: 'Repository and tag',
              compare: (DockerImage a, DockerImage b) => a.ref.compareTo(b.ref),
              cell: (BuildContext c, DockerImage i) =>
                  CellText(i.ref, mono: true, selectable: true),
            ),
            TableColumn<DockerImage>(
              label: 'Size',
              width: 100,
              numeric: true,
              compare: (DockerImage a, DockerImage b) =>
                  a.sizeBytes.compareTo(b.sizeBytes),
              cell: (BuildContext c, DockerImage i) =>
                  CellText(formatBytes(i.sizeBytes)),
            ),
            TableColumn<DockerImage>(
              label: 'Created',
              width: 140,
              optional: true,
              compare: (DockerImage a, DockerImage b) =>
                  a.createdAt.compareTo(b.createdAt),
              cell: (BuildContext c, DockerImage i) =>
                  CellText(formatRelative(i.createdAt), muted: true),
            ),
            TableColumn<DockerImage>(
              label: 'Used by',
              width: 190,
              optional: true,
              cell: (BuildContext c, DockerImage i) => CellText(
                i.inUse ? i.inUseBy.join(', ') : '–',
                muted: !i.inUse,
              ),
            ),
            TableColumn<DockerImage>(
              label: 'Status',
              width: 90,
              cell: (BuildContext c, DockerImage i) => StatusPill(
                i.inUse ? 'In use' : 'Unused',
                tone: i.inUse ? PillTone.accent : PillTone.warning,
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _ActionRow(
          label: 'Pull image',
          canCreate: role.canOperate,
          canPrune: role.canPrune,
          onCreate: () async {
            final String? ref0 = await showPromptSheet(
              context,
              title: 'Pull an image',
              subtitle: 'Uses the stored registry credentials',
              label: 'Image reference',
              hint: 'registry.example.com/api:2.9.0',
              confirmLabel: 'Pull',
              glyph: StrokeGlyph.download,
            );
            if (ref0 == null || !context.mounted) return;
            await runJob(context, ref, serverId, (api) => api.pullImage(ref0));
          },
          onPrune: () => _prune(context, ref),
        ),
        const SizedBox(height: 14),
        AsyncSection<ImageList>(
          value: images,
          onRetry: () => ref.invalidate(imagesProvider(serverId)),
          loadingRows: 5,
          loadingRowHeight: 64,
          isEmpty: (ImageList list) => list.images.isEmpty,
          empty: const EmptyView(
            glyph: StrokeGlyph.resources,
            title: 'No images',
            message: 'Nothing has been pulled on this host yet.',
          ),
          builder: (ImageList list) => RowGroup(
            trailingPadding: 6,
            children: <Widget>[
              for (final DockerImage image in list.images)
                _ResourceRow(
                  name: image.ref,
                  meta: '${formatBytes(image.sizeBytes)} · ${image.created}',
                  pill: image.inUse ? 'In use' : 'Unused',
                  tone: image.inUse ? PillTone.accent : PillTone.warning,
                  actionsLabel: 'Actions for image ${image.ref}',
                  onActions: () => _showRowActions(
                    context,
                    title: image.ref,
                    subtitle: image.inUse
                        ? 'Used by ${image.inUseBy.join(', ')}'
                        : 'Not used by any container',
                    canRemove: role.canRemove,
                    onRemove: () => _remove(context, ref, image),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Mounted volumes are in use now, so they sort as the most recent.
int _lastUsedOrder(VolumeInfo v) =>
    v.mounted ? 1 << 62 : (v.lastUsed?.millisecondsSinceEpoch ?? 0);

class _Volumes extends ConsumerWidget {
  const _Volumes({required this.serverId});

  final String serverId;

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    VolumeInfo volume,
  ) async {
    final RiskyOutcome outcome = await confirmRisky(
      context,
      ref,
      RiskyAction(
        title: 'Remove ${volume.name}?',
        subtitle: '$serverId · ${formatBytes(volume.sizeBytes)}',
        explanation: volume.mounted
            ? 'A container has it mounted, so the agent answers 409.'
            : 'The data in this volume is deleted and cannot be recovered.',
        requestLine: 'DELETE /v1/volumes/${volume.name}',
        confirmLabel: 'Remove volume',
        glyph: StrokeGlyph.trash,
        requireFingerprint: riskyNeedsFingerprint(ref, serverId),
        target: volume.name,
      ),
    );
    if (!outcome.confirmed || !context.mounted) return;
    await runAction(
      context,
      ref,
      () => ref
          .read(agentApiProvider(serverId))
          .removeVolume(volume.name, confirmed: outcome.confirmation),
      success: '${volume.name} removed',
    );
  }

  Future<void> _prune(BuildContext context, WidgetRef ref) async {
    final RiskyOutcome outcome = await confirmRisky(
      context,
      ref,
      RiskyAction(
        title: 'Prune unmounted volumes?',
        subtitle: 'Deletes data nothing has mounted',
        explanation:
            'Every volume that no container mounts is removed with its data. '
            'There is no undo.',
        requestLine: 'POST /v1/volumes/prune',
        confirmLabel: 'Prune volumes',
        glyph: StrokeGlyph.prune,
        requireFingerprint: riskyNeedsFingerprint(ref, serverId),
        target: 'prune volumes',
      ),
    );
    if (!outcome.confirmed || !context.mounted) return;
    await runJob(
      context,
      ref,
      serverId,
      (api) => api.pruneVolumes(confirmed: outcome.confirmation),
    );
  }

  List<MenuAction> _menu(
    BuildContext context,
    WidgetRef ref,
    VolumeInfo volume,
    ServerRole role,
  ) => <MenuAction>[
    MenuAction(
      label: 'Copy name',
      glyph: StrokeGlyph.copy,
      onSelected: () {
        Clipboard.setData(ClipboardData(text: volume.name));
        notify(context, 'Volume name copied');
      },
    ),
    MenuAction(
      label: 'Show containers',
      glyph: StrokeGlyph.containers,
      onSelected: () => notify(
        context,
        volume.mounted
            ? 'Mounted by ${volume.mountedBy.join(', ')}'
            : volume.lastUsedLabel,
      ),
    ),
    MenuAction(
      label: 'Remove',
      glyph: StrokeGlyph.trash,
      danger: true,
      enabled: role.canRemove,
      onSelected: () => _remove(context, ref, volume),
    ),
  ];

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final String? name = await showPromptSheet(
      context,
      title: 'Create a volume',
      subtitle: 'Driver local',
      label: 'Volume name',
      hint: 'web-platform_cache',
      confirmLabel: 'Create',
      glyph: StrokeGlyph.plus,
    );
    if (name == null || !context.mounted) return;
    await runAction(
      context,
      ref,
      () => ref.read(agentApiProvider(serverId)).createVolume(name),
      success: '$name created',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<VolumeList> volumes = ref.watch(volumesProvider(serverId));
    final ServerRole role = ref.watch(roleProvider(serverId));
    if (WindowClass.of(context).usesDesktopExtras) {
      return AsyncSection<VolumeList>(
        value: volumes,
        onRetry: () => ref.invalidate(volumesProvider(serverId)),
        loadingRows: 6,
        loadingRowHeight: 46,
        isEmpty: (VolumeList list) => list.volumes.isEmpty,
        empty: const EmptyView(
          glyph: StrokeGlyph.volumes,
          title: 'No volumes',
          message: 'Nothing on this host stores data in a named volume.',
        ),
        builder: (VolumeList list) => ResourceTable<VolumeInfo>(
          rows: list.volumes,
          filterHint: 'Filter volumes',
          emptyTitle: 'No matching volumes',
          initialSort: 1,
          initialAscending: false,
          footer: 'right-click a row for Remove, Copy name and Show containers',
          matches: (VolumeInfo v, String q) =>
              v.name.toLowerCase().contains(q) ||
              v.mountedBy.any((String c) => c.toLowerCase().contains(q)),
          chips: <ResourceChip<VolumeInfo>>[
            ResourceChip<VolumeInfo>(
              label: 'All ${list.volumes.length}',
              keep: null,
            ),
            ResourceChip<VolumeInfo>(
              label:
                  'Mounted '
                  '${list.volumes.where((VolumeInfo v) => v.mounted).length}',
              keep: (VolumeInfo v) => v.mounted,
            ),
            ResourceChip<VolumeInfo>(
              label: 'Not mounted ${list.unmounted}',
              keep: (VolumeInfo v) => !v.mounted,
            ),
          ],
          actions: <Widget>[
            if (role.canPrune)
              DoomButton(
                'Prune unused',
                height: 36,
                radius: 10,
                onPressed: () => _prune(context, ref),
              ),
            if (role.canCreateResources)
              DoomButton(
                'Create volume',
                glyph: StrokeGlyph.plus,
                height: 36,
                radius: 10,
                tone: ButtonTone.primary,
                onPressed: () => _create(context, ref),
              ),
          ],
          menu: (VolumeInfo v) => _menu(context, ref, v, role),
          columns: <TableColumn<VolumeInfo>>[
            TableColumn<VolumeInfo>(
              label: 'Name',
              compare: (VolumeInfo a, VolumeInfo b) => a.name.compareTo(b.name),
              cell: (BuildContext c, VolumeInfo v) =>
                  CellText(v.name, mono: true, selectable: true),
            ),
            TableColumn<VolumeInfo>(
              label: 'Size',
              width: 100,
              numeric: true,
              compare: (VolumeInfo a, VolumeInfo b) =>
                  a.sizeBytes.compareTo(b.sizeBytes),
              cell: (BuildContext c, VolumeInfo v) =>
                  CellText(formatBytes(v.sizeBytes)),
            ),
            TableColumn<VolumeInfo>(
              label: 'Driver',
              width: 90,
              optional: true,
              cell: (BuildContext c, VolumeInfo v) =>
                  CellText(v.driver, muted: true),
            ),
            TableColumn<VolumeInfo>(
              label: 'Mounted by',
              width: 170,
              optional: true,
              cell: (BuildContext c, VolumeInfo v) => CellText(
                v.mounted ? v.mountedBy.join(', ') : '–',
                muted: !v.mounted,
              ),
            ),
            TableColumn<VolumeInfo>(
              label: 'Last used',
              width: 120,
              optional: true,
              compare: (VolumeInfo a, VolumeInfo b) =>
                  _lastUsedOrder(a).compareTo(_lastUsedOrder(b)),
              cell: (BuildContext c, VolumeInfo v) =>
                  CellText(v.lastUsedShort, muted: true),
            ),
            TableColumn<VolumeInfo>(
              label: 'Status',
              width: 110,
              cell: (BuildContext c, VolumeInfo v) => StatusPill(
                v.mounted ? 'Mounted' : 'Not mounted',
                tone: v.mounted ? PillTone.accent : PillTone.warning,
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _ActionRow(
          label: 'Create volume',
          canCreate: role.canCreateResources,
          canPrune: role.canPrune,
          onCreate: () async {
            final String? name = await showPromptSheet(
              context,
              title: 'Create a volume',
              subtitle: 'Driver local',
              label: 'Volume name',
              hint: 'web-platform_cache',
              confirmLabel: 'Create',
              glyph: StrokeGlyph.plus,
            );
            if (name == null || !context.mounted) return;
            await runAction(
              context,
              ref,
              () => ref.read(agentApiProvider(serverId)).createVolume(name),
              success: '$name created',
            );
          },
          onPrune: () => _prune(context, ref),
        ),
        const SizedBox(height: 14),
        AsyncSection<VolumeList>(
          value: volumes,
          onRetry: () => ref.invalidate(volumesProvider(serverId)),
          loadingRows: 5,
          loadingRowHeight: 64,
          isEmpty: (VolumeList list) => list.volumes.isEmpty,
          empty: const EmptyView(
            glyph: StrokeGlyph.volumes,
            title: 'No volumes',
            message: 'Nothing on this host stores data in a named volume.',
          ),
          builder: (VolumeList list) => RowGroup(
            trailingPadding: 6,
            children: <Widget>[
              for (final VolumeInfo volume in list.volumes)
                _ResourceRow(
                  name: volume.name,
                  meta:
                      '${formatBytes(volume.sizeBytes)} · ${volume.driver} · '
                      '${volume.mounted ? volume.mountedBy.join(', ') : volume.lastUsedLabel}',
                  pill: volume.mounted ? 'Mounted' : 'Not mounted',
                  tone: volume.mounted ? PillTone.accent : PillTone.warning,
                  actionsLabel: 'Actions for volume ${volume.name}',
                  onActions: () => _showRowActions(
                    context,
                    title: volume.name,
                    subtitle: volume.mounted
                        ? 'Mounted by ${volume.mountedBy.join(', ')}'
                        : volume.lastUsedLabel,
                    canRemove: role.canRemove,
                    onRemove: () => _remove(context, ref, volume),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Networks extends ConsumerWidget {
  const _Networks({required this.serverId});

  final String serverId;

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    NetworkInfo network,
  ) async {
    final RiskyOutcome outcome = await confirmRisky(
      context,
      ref,
      RiskyAction(
        title: 'Remove ${network.name}?',
        subtitle: '$serverId · ${network.driver} · ${network.subnet}',
        explanation: network.attached > 0 || network.isDefault
            ? 'Containers are attached, or this is a default network, so the '
                  'agent answers 409.'
            : 'The network is deleted. Containers that ask for it later fail to '
                  'start until it is recreated.',
        requestLine: 'DELETE /v1/networks/${network.id}',
        confirmLabel: 'Remove network',
        glyph: StrokeGlyph.trash,
        requireFingerprint: riskyNeedsFingerprint(ref, serverId),
        target: network.name,
      ),
    );
    if (!outcome.confirmed || !context.mounted) return;
    await runAction(
      context,
      ref,
      () => ref
          .read(agentApiProvider(serverId))
          .removeNetwork(network.id, confirmed: outcome.confirmation),
      success: '${network.name} removed',
    );
  }

  Future<void> _prune(BuildContext context, WidgetRef ref) async {
    final RiskyOutcome outcome = await confirmRisky(
      context,
      ref,
      RiskyAction(
        title: 'Prune unused networks?',
        subtitle: 'Removes networks with nothing attached',
        explanation:
            'Default networks are kept. Anything else with no attached '
            'container is removed.',
        requestLine: 'POST /v1/networks/prune',
        confirmLabel: 'Prune networks',
        glyph: StrokeGlyph.prune,
        requireFingerprint: riskyNeedsFingerprint(ref, serverId),
        target: 'prune networks',
      ),
    );
    if (!outcome.confirmed || !context.mounted) return;
    await runJob(
      context,
      ref,
      serverId,
      (api) => api.pruneNetworks(confirmed: outcome.confirmation),
    );
  }

  List<MenuAction> _menu(
    BuildContext context,
    WidgetRef ref,
    NetworkInfo network,
    ServerRole role,
  ) => <MenuAction>[
    MenuAction(
      label: 'Copy name',
      glyph: StrokeGlyph.copy,
      onSelected: () {
        Clipboard.setData(ClipboardData(text: network.name));
        notify(context, 'Network name copied');
      },
    ),
    MenuAction(
      label: 'Show containers',
      glyph: StrokeGlyph.containers,
      onSelected: () => notify(
        context,
        network.attached == 0
            ? 'Nothing is attached to ${network.name}'
            : '${network.attached} containers attached',
      ),
    ),
    MenuAction(
      label: 'Remove',
      glyph: StrokeGlyph.trash,
      danger: true,
      enabled: role.canRemove && network.removable,
      onSelected: () => _remove(context, ref, network),
    ),
  ];

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final String? name = await showPromptSheet(
      context,
      title: 'Create a network',
      subtitle: 'Driver bridge',
      label: 'Network name',
      hint: 'web-platform_edge',
      confirmLabel: 'Create',
      glyph: StrokeGlyph.plus,
    );
    if (name == null || !context.mounted) return;
    await runAction(
      context,
      ref,
      () => ref.read(agentApiProvider(serverId)).createNetwork(name),
      success: '$name created',
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<NetworkList> networks = ref.watch(
      networksProvider(serverId),
    );
    final ServerRole role = ref.watch(roleProvider(serverId));
    if (WindowClass.of(context).usesDesktopExtras) {
      return AsyncSection<NetworkList>(
        value: networks,
        onRetry: () => ref.invalidate(networksProvider(serverId)),
        loadingRows: 6,
        loadingRowHeight: 46,
        isEmpty: (NetworkList list) => list.networks.isEmpty,
        empty: const EmptyView(
          glyph: StrokeGlyph.networks,
          title: 'No networks',
          message: 'This host reports no Docker networks.',
        ),
        builder: (NetworkList list) => ResourceTable<NetworkInfo>(
          rows: list.networks,
          filterHint: 'Filter networks',
          emptyTitle: 'No matching networks',
          initialSort: 0,
          footer:
              'right-click a row for Remove, Copy name and Show containers · '
              'default networks cannot be removed',
          matches: (NetworkInfo n, String q) =>
              n.name.toLowerCase().contains(q) ||
              n.driver.toLowerCase().contains(q) ||
              n.subnet.toLowerCase().contains(q),
          chips: <ResourceChip<NetworkInfo>>[
            ResourceChip<NetworkInfo>(
              label: 'All ${list.networks.length}',
              keep: null,
            ),
            for (final String status in const <String>[
              'In use',
              'Unused',
              'Default',
            ])
              ResourceChip<NetworkInfo>(
                label:
                    '$status '
                    '${list.networks.where((NetworkInfo n) => n.statusLabel == status).length}',
                keep: (NetworkInfo n) => n.statusLabel == status,
              ),
          ],
          actions: <Widget>[
            if (role.canPrune)
              DoomButton(
                'Prune unused',
                height: 36,
                radius: 10,
                onPressed: () => _prune(context, ref),
              ),
            if (role.canCreateResources)
              DoomButton(
                'Create network',
                glyph: StrokeGlyph.plus,
                height: 36,
                radius: 10,
                tone: ButtonTone.primary,
                onPressed: () => _create(context, ref),
              ),
          ],
          menu: (NetworkInfo n) => _menu(context, ref, n, role),
          columns: <TableColumn<NetworkInfo>>[
            TableColumn<NetworkInfo>(
              label: 'Name',
              compare: (NetworkInfo a, NetworkInfo b) =>
                  a.name.compareTo(b.name),
              cell: (BuildContext c, NetworkInfo n) =>
                  CellText(n.name, mono: true, selectable: true),
            ),
            TableColumn<NetworkInfo>(
              label: 'Driver',
              width: 100,
              optional: true,
              cell: (BuildContext c, NetworkInfo n) =>
                  CellText(n.driver, muted: true),
            ),
            TableColumn<NetworkInfo>(
              label: 'Subnet',
              width: 170,
              optional: true,
              cell: (BuildContext c, NetworkInfo n) =>
                  CellText(n.subnet, mono: true, muted: true),
            ),
            TableColumn<NetworkInfo>(
              label: 'Scope',
              width: 90,
              optional: true,
              cell: (BuildContext c, NetworkInfo n) =>
                  CellText(n.scope, muted: true),
            ),
            TableColumn<NetworkInfo>(
              label: 'Attached',
              width: 90,
              numeric: true,
              compare: (NetworkInfo a, NetworkInfo b) =>
                  a.attached.compareTo(b.attached),
              cell: (BuildContext c, NetworkInfo n) =>
                  CellText('${n.attached}'),
            ),
            TableColumn<NetworkInfo>(
              label: 'Status',
              width: 100,
              cell: (BuildContext c, NetworkInfo n) => StatusPill(
                n.statusLabel,
                tone: n.isDefault
                    ? PillTone.neutral
                    : (n.unused ? PillTone.warning : PillTone.accent),
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _ActionRow(
          label: 'Create network',
          canCreate: role.canCreateResources,
          canPrune: role.canPrune,
          onCreate: () async {
            final String? name = await showPromptSheet(
              context,
              title: 'Create a network',
              subtitle: 'Driver bridge',
              label: 'Network name',
              hint: 'web-platform_edge',
              confirmLabel: 'Create',
              glyph: StrokeGlyph.plus,
            );
            if (name == null || !context.mounted) return;
            await runAction(
              context,
              ref,
              () => ref.read(agentApiProvider(serverId)).createNetwork(name),
              success: '$name created',
            );
          },
          onPrune: () => _prune(context, ref),
        ),
        const SizedBox(height: 14),
        AsyncSection<NetworkList>(
          value: networks,
          onRetry: () => ref.invalidate(networksProvider(serverId)),
          loadingRows: 5,
          loadingRowHeight: 64,
          isEmpty: (NetworkList list) => list.networks.isEmpty,
          empty: const EmptyView(
            glyph: StrokeGlyph.networks,
            title: 'No networks',
            message: 'This host reports no Docker networks.',
          ),
          builder: (NetworkList list) => RowGroup(
            trailingPadding: 6,
            children: <Widget>[
              for (final NetworkInfo network in list.networks)
                _ResourceRow(
                  name: network.name,
                  meta: <String>[
                    network.driver,
                    network.subnet,
                    if (network.scope == 'swarm') 'swarm',
                    if (network.isDefault) 'default',
                  ].join(' · '),
                  pill: network.attached > 0
                      ? '${network.attached} attached'
                      : 'Unused',
                  tone: network.attached > 0
                      ? PillTone.accent
                      : PillTone.warning,
                  actionsLabel: 'Actions for network ${network.name}',
                  onActions: () => _showRowActions(
                    context,
                    title: network.name,
                    subtitle: '${network.driver} · ${network.subnet}',
                    canRemove: role.canRemove,
                    onRemove: () => _remove(context, ref, network),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
