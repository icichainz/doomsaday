/// The Environment and Volumes rows of Container detail, opened
/// (`design/ContainerDetailEnv.dc.html`).
///
/// One sheet with both lists: the variable names with their values hidden,
/// and the mounts. Names are part of `GET /containers/{id}` and every role
/// sees them; the values come from `GET /containers/{id}/env`, which is admin
/// only and audited, so they are fetched on the first Reveal or Copy and
/// never before.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/notify.dart';
import '../../widgets/primitives.dart';
import '../../widgets/stroke_icons.dart';
import '../../widgets/surfaces.dart';

/// Opens the sheet (a dialog from 600 up). [mounts] scrolls it to the
/// Volumes section, which is where the Volumes row means to go.
Future<void> showContainerConfig(
  BuildContext context, {
  required String serverId,
  required ContainerDetail detail,
  bool mounts = false,
}) => showAdaptiveModal<void>(
  context,
  builder: (BuildContext context, bool sheet) => ContainerConfigBody(
    serverId: serverId,
    detail: detail,
    sheet: sheet,
    scrollToMounts: mounts,
  ),
);

/// `api_config → /etc/api`, the way a mount reads in the list.
String mountLine(MountInfo mount) => '${mount.label} → ${mount.destination}';

/// `Named volume`, `Bind mount`, `tmpfs`.
String mountKind(MountInfo mount) => switch (mount.type) {
  'volume' => 'Named volume',
  'bind' => 'Bind mount',
  'tmpfs' => 'tmpfs',
  '' => 'Mount',
  _ => mount.type,
};

class ContainerConfigBody extends ConsumerStatefulWidget {
  const ContainerConfigBody({
    super.key,
    required this.serverId,
    required this.detail,
    required this.sheet,
    this.scrollToMounts = false,
  });

  final String serverId;
  final ContainerDetail detail;
  final bool sheet;
  final bool scrollToMounts;

  @override
  ConsumerState<ContainerConfigBody> createState() =>
      _ContainerConfigBodyState();
}

class _ContainerConfigBodyState extends ConsumerState<ContainerConfigBody> {
  final GlobalKey _mountsKey = GlobalKey();

  /// Every value, once the one audited call has been made.
  Map<String, String>? _values;
  final Set<String> _shown = <String>{};
  String? _busy;

  @override
  void initState() {
    super.initState();
    if (widget.scrollToMounts) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final BuildContext? target = _mountsKey.currentContext;
        if (target != null) Scrollable.ensureVisible(target);
      });
    }
  }

  Future<Map<String, String>?> _load(String name) async {
    if (_values != null) return _values;
    setState(() => _busy = name);
    try {
      final Map<String, String> values = await ref
          .read(agentApiProvider(widget.serverId))
          .containerEnv(widget.detail.id);
      if (!mounted) return null;
      setState(() => _values = values);
      // The read is on the Activity log now.
      ref.invalidate(activityProvider(widget.serverId));
      return values;
    } on AgentException catch (error) {
      if (mounted) notify(context, error.toString(), danger: true);
      return null;
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _toggle(String name) async {
    if (_shown.contains(name)) {
      setState(() => _shown.remove(name));
      return;
    }
    if (await _load(name) == null || !mounted) return;
    setState(() => _shown.add(name));
  }

  Future<void> _copy(String name) async {
    final Map<String, String>? values = await _load(name);
    if (values == null || !mounted) return;
    await Clipboard.setData(ClipboardData(text: values[name] ?? ''));
    if (mounted) notify(context, 'Value of $name copied');
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final ContainerDetail d = widget.detail;
    final bool admin = ref
        .watch(roleProvider(widget.serverId))
        .canReadEnvironment;
    final int n = d.envNames.length;
    final int m = d.mounts.length;

    final Widget body = ModalBody(
      handle: widget.sheet,
      children: <Widget>[
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Environment',
              style: AppText.sheetTitle.copyWith(color: t.text),
            ),
            const SizedBox(height: 2),
            Text(
              admin
                  ? '${d.name} · Reveal and Copy are audited'
                  : '${d.name} · values are admin only',
              style: AppText.small.copyWith(color: t.mutedText),
            ),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SectionHeader('$n variable${n == 1 ? '' : 's'} · values hidden'),
            const SizedBox(height: 8),
            if (n == 0)
              Text(
                'This container sets no variables of its own.',
                style: AppText.small.copyWith(color: t.mutedText),
              )
            else
              _Group(
                right: admin ? 4 : 14,
                children: <Widget>[
                  for (final String name in d.envNames)
                    _EnvRow(
                      name: name,
                      value: _shown.contains(name) ? (_values?[name]) : null,
                      busy: _busy == name,
                      onToggle: admin ? () => _toggle(name) : null,
                      onCopy: admin ? () => _copy(name) : null,
                    ),
                ],
              ),
          ],
        ),
        Column(
          key: _mountsKey,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SectionHeader('Volumes · $m mount${m == 1 ? '' : 's'}'),
            const SizedBox(height: 8),
            if (m == 0)
              Text(
                'Nothing is mounted into this container.',
                style: AppText.small.copyWith(color: t.mutedText),
              )
            else
              _Group(
                right: 14,
                children: <Widget>[
                  for (final MountInfo mount in d.mounts)
                    _MountRow(mount: mount),
                ],
              ),
          ],
        ),
      ],
    );
    if (!widget.sheet) return body;
    // Twelve variables and the mounts are taller than a sheet likes to be,
    // so the sheet scrolls rather than overflowing.
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.96,
      ),
      child: SingleChildScrollView(child: body),
    );
  }
}

/// A bordered list inside the sheet: radius 16, no fill of its own.
class _Group extends StatelessWidget {
  const _Group({required this.children, required this.right});

  final List<Widget> children;
  final double right;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      padding: EdgeInsets.only(left: 14, right: right),
      decoration: BoxDecoration(
        borderRadius: AppShape.smallCardRadius,
        border: Border.all(color: t.border),
      ),
      child: Column(
        children: <Widget>[
          for (int i = 0; i < children.length; i++)
            DecoratedBox(
              decoration: BoxDecoration(
                border: i == children.length - 1
                    ? null
                    : Border(bottom: BorderSide(color: t.border)),
              ),
              child: children[i],
            ),
        ],
      ),
    );
  }
}

class _EnvRow extends StatelessWidget {
  const _EnvRow({
    required this.name,
    required this.value,
    required this.busy,
    required this.onToggle,
    required this.onCopy,
  });

  final String name;

  /// Null while hidden.
  final String? value;
  final bool busy;
  final VoidCallback? onToggle;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool shown = value != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.mono.copyWith(color: t.text),
                ),
              ),
              if (!shown) ...<Widget>[
                const SizedBox(width: 6),
                Semantics(
                  label: 'Value hidden',
                  child: ExcludeSemantics(
                    child: Text(
                      '••••••',
                      style: AppText.mono.copyWith(
                        color: t.mutedText,
                        fontWeight: FontWeight.w400,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ),
              ],
              if (onToggle != null) ...<Widget>[
                const SizedBox(width: 6),
                Semantics(
                  button: true,
                  label: '${shown ? 'Hide' : 'Reveal'} $name',
                  excludeSemantics: true,
                  child: InkWell(
                    key: ValueKey<String>('reveal-$name'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: busy ? null : onToggle,
                    child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      alignment: Alignment.center,
                      child: busy
                          ? SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: t.accent,
                              ),
                            )
                          : Text(
                              shown ? 'Hide' : 'Reveal',
                              style: AppText.buttonLabel.copyWith(
                                fontSize: 13,
                                color: t.accent,
                              ),
                            ),
                    ),
                  ),
                ),
              ],
              if (onCopy != null)
                Semantics(
                  button: true,
                  label: 'Copy the value of $name',
                  excludeSemantics: true,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: onCopy,
                    child: SizedBox(
                      width: 32,
                      height: 32,
                      child: StrokeIcon(
                        StrokeGlyph.copy,
                        size: 16,
                        color: t.mutedText,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (shown)
          Padding(
            padding: const EdgeInsets.only(right: 10, bottom: 10),
            child: SelectableText(
              value!,
              style: TextStyle(
                fontFamily: AppFonts.mono,
                fontSize: 12.5,
                color: t.codeText,
              ),
            ),
          ),
      ],
    );
  }
}

class _MountRow extends StatelessWidget {
  const _MountRow({required this.mount});

  final MountInfo mount;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                GlyphText(
                  mountLine(mount),
                  style: AppText.mono.copyWith(color: t.text),
                ),
                const SizedBox(height: 2),
                Text(
                  mountKind(mount),
                  style: AppText.tiny.copyWith(color: t.mutedText),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
            decoration: BoxDecoration(
              color: t.faintDivider,
              borderRadius: AppShape.pill,
            ),
            child: Text(
              mount.rw ? 'read-write' : 'read-only',
              style: AppText.pill.copyWith(color: t.text),
            ),
          ),
        ],
      ),
    );
  }
}
