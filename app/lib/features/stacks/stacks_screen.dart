import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../../layout/layout.dart';
import '../../theme/app_theme.dart';
import '../../theme/state_colors.dart';
import '../../theme/tokens.dart';
import '../../widgets/actions.dart';
import '../../widgets/buttons.dart';
import '../../widgets/desktop.dart';
import '../../widgets/notify.dart';
import '../../widgets/page.dart';
import '../../widgets/primitives.dart';
import '../../widgets/sheets.dart';
import '../../widgets/state_views.dart';

/// Screens 9 and 10 — Compose stacks and Swarm services behind one segmented
/// control, as the design links them.
class StacksScreen extends ConsumerStatefulWidget {
  const StacksScreen({super.key, required this.serverId});

  final String serverId;

  @override
  ConsumerState<StacksScreen> createState() => _StacksScreenState();
}

class _StacksScreenState extends ConsumerState<StacksScreen> {
  int _segment = 0;

  @override
  Widget build(BuildContext context) {
    final String serverId = widget.serverId;
    final AsyncValue<SwarmInfo> swarm = ref.watch(swarmProvider(serverId));
    final String title = _segment == 0 ? 'Stacks' : 'Services';
    final String subtitle = _segment == 0
        ? 'Compose projects on $serverId'
        : swarm.maybeWhen(
            data: (SwarmInfo s) => s.active
                ? 'Swarm · ${s.nodeCount} nodes · this server is a ${s.nodeRole}'
                : 'This host is not in a swarm',
            orElse: () => 'Swarm services on $serverId',
          );
    final Widget segment = SegmentedControl(
      semanticLabel: 'Deployment type',
      labels: const <String>['Compose stacks', 'Swarm services'],
      index: _segment,
      onChanged: (int i) => setState(() => _segment = i),
    );
    final Widget body = _segment == 0
        ? _ComposeStacks(serverId: serverId)
        : _SwarmServices(serverId: serverId);

    if (WindowClass.of(context).usesDesktopExtras) {
      return DesktopPage(
        children: <Widget>[
          DesktopHeader(
            title: title,
            subtitle: subtitle,
            actions: <Widget>[SizedBox(width: 330, child: segment)],
          ),
          body,
        ],
      );
    }
    return ShellPage(
      gap: 14,
      children: <Widget>[
        ScreenHeader(title: title, subtitle: subtitle),
        segment,
        body,
      ],
    );
  }
}

class _ComposeStacks extends ConsumerWidget {
  const _ComposeStacks({required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<ComposeStack>> stacks = ref.watch(
      stacksProvider(serverId),
    );
    return AsyncSection<List<ComposeStack>>(
      value: stacks,
      onRetry: () => ref.invalidate(stacksProvider(serverId)),
      loadingRows: 3,
      loadingRowHeight: 140,
      isEmpty: (List<ComposeStack> list) => list.isEmpty,
      empty: const EmptyView(
        icon: Icons.layers_outlined,
        title: 'No Compose stacks',
        message: "Nothing was found under the agent's stacks directory.",
      ),
      builder: (List<ComposeStack> list) => CardGrid(
        cards: <Widget>[
          for (final ComposeStack stack in list)
            _StackCard(serverId: serverId, stack: stack),
        ],
      ),
    );
  }
}

/// The stack and service cards: the phone board's card below 600, the
/// tighter desktop card (radius 16, 16 by 18 padding, 16 px title) from 600
/// up, and the density's card buttons (36 px with a pointer, 44 on touch).
class _CardChrome {
  _CardChrome(BuildContext context)
    : phone = WindowClass.of(context).isCompact,
      button = context.density.cardButton,
      radius = context.density.cardButtonRadius;

  final bool phone;
  final double button;
  final double radius;

  EdgeInsets get padding => phone
      ? const EdgeInsets.all(16)
      : const EdgeInsets.symmetric(horizontal: 18, vertical: 16);

  double get cardRadius => phone ? AppShape.card : 16;

  TextStyle get title =>
      phone ? AppText.cardTitle : AppText.cardTitle.copyWith(fontSize: 16);

  DoomButton button_(
    String label, {
    required VoidCallback? onPressed,
    ButtonTone tone = ButtonTone.outline,
    bool expand = false,
  }) => DoomButton(
    label,
    height: button,
    radius: radius,
    tone: tone,
    expand: expand,
    onPressed: onPressed,
  );
}

/// A card's primary action, then the others: one row, except on a tablet.
/// There the grid's two columns sit in the 720 px reading column, so a card
/// is never more than about 320 px inside at any width from 600 to 1099: the
/// primary gets its own row and the rest share the row below (TabletStacks).
///
/// Decided from the window class rather than measured, because the cards sit
/// in an `IntrinsicHeight` row that a `LayoutBuilder` cannot answer.
class _CardActions extends StatelessWidget {
  const _CardActions({required this.primary, required this.others});

  final Widget primary;
  final List<Widget> others;

  @override
  Widget build(BuildContext context) {
    if (!WindowClass.of(context).isMedium || others.length < 2) {
      return ActionRow(primary: primary, children: others);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        primary,
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            for (int i = 0; i < others.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(width: 8),
              Expanded(child: others[i]),
            ],
          ],
        ),
      ],
    );
  }
}

class _StackCard extends ConsumerWidget {
  const _StackCard({required this.serverId, required this.stack});

  final String serverId;
  final ComposeStack stack;

  Future<void> _down(BuildContext context, WidgetRef ref) async {
    final RiskyOutcome outcome = await confirmRisky(
      context,
      ref,
      RiskyAction(
        title: 'Bring ${stack.name} down?',
        subtitle: '$serverId · ${stack.path}',
        explanation:
            'Every container in the stack is stopped and removed, and the '
            "stack's own network goes with it. Named volumes are kept.",
        requestLine: 'POST /v1/stacks/${stack.name}/down',
        confirmLabel: 'Bring it down',
        icon: Icons.power_settings_new,
        requireFingerprint: riskyNeedsFingerprint(ref, serverId),
        target: stack.name,
      ),
    );
    if (!outcome.confirmed || !context.mounted) return;
    await runJob(
      context,
      ref,
      serverId,
      (api) => api.stackDown(stack.name, confirmed: outcome.confirmation),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final ServerRole role = ref.watch(roleProvider(serverId));
    final bool allUp = stack.servicesUp == stack.servicesTotal;
    final bool allDown = stack.servicesUp == 0;
    // The explanation line names the container that stopped the stack, with
    // its own exit code and finish time, so it needs the container list. Only
    // a down stack shows the line, and only a down stack pays for the call.
    final String? note = allDown
        ? stack.noteFor(
            ref.watch(containersProvider(serverId)).valueOrNull ??
                const <ContainerSummary>[],
          )
        : null;
    // A stack discovered only through container labels has no compose file,
    // so every action on it answers 409 (API_NOTES §16).
    final bool drivable = stack.configOnDisk;
    final _CardChrome c = _CardChrome(context);
    return DoomCard(
      padding: c.padding,
      radius: c.cardRadius,
      borderColor: allDown ? t.dangerBorder : t.border,
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
                    Text(stack.name, style: c.title.copyWith(color: t.text)),
                    const SizedBox(height: 3),
                    Text(
                      stack.path,
                      style: AppText.monoSmall.copyWith(color: t.mutedText),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              StatusPill(
                '${stack.servicesUp} of ${stack.servicesTotal} up',
                tone: allUp
                    ? PillTone.accent
                    : (allDown ? PillTone.danger : PillTone.warning),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (note != null)
            Text(
              note,
              style: AppText.small.copyWith(color: t.mutedText, height: 1.4),
            )
          else
            SegmentMeter(<Color>[
              for (final ContainerState state in stack.serviceStates)
                segmentColor(t, state),
            ]),
          const SizedBox(height: 12),
          // One row, as the board draws it: the primary action flexes and the
          // rest hug their labels. Two rows on a tablet's narrow card.
          if (allDown)
            ActionRow(
              primary: c.button_(
                'Start stack',
                expand: true,
                onPressed: role.canOperate && drivable
                    ? () => runJob(
                        context,
                        ref,
                        serverId,
                        (api) => api.stackUp(stack.name),
                      )
                    : null,
              ),
              children: <Widget>[
                c.button_(
                  'View logs',
                  onPressed: () => notify(
                    context,
                    'Open a container in the stack to follow its logs',
                  ),
                ),
              ],
            )
          else
            _CardActions(
              primary: c.button_(
                'Pull and redeploy',
                expand: true,
                tone: allUp ? ButtonTone.outline : ButtonTone.primary,
                onPressed: role.canOperate && drivable
                    ? () => runJob(
                        context,
                        ref,
                        serverId,
                        (api) => api.stackRedeploy(stack.name),
                      )
                    : null,
              ),
              others: <Widget>[
                c.button_(
                  'Restart',
                  expand: WindowClass.of(context).isMedium,
                  onPressed: role.canOperate && drivable
                      ? () => runJob(
                          context,
                          ref,
                          serverId,
                          (api) => api.stackRestart(stack.name),
                        )
                      : null,
                ),
                if (role.canStackDown)
                  c.button_(
                    'Down',
                    tone: ButtonTone.danger,
                    expand: WindowClass.of(context).isMedium,
                    onPressed: drivable ? () => _down(context, ref) : null,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _SwarmServices extends ConsumerWidget {
  const _SwarmServices({required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<SwarmInfo> swarm = ref.watch(swarmProvider(serverId));
    // GET /swarm always answers 200, so "not in a swarm" is an empty state
    // rather than an error, and /services is never called in that case.
    return AsyncSection<SwarmInfo>(
      value: swarm,
      onRetry: () => ref.invalidate(swarmProvider(serverId)),
      loadingRows: 3,
      loadingRowHeight: 140,
      isEmpty: (SwarmInfo s) => !s.active,
      empty: const EmptyView(
        icon: Icons.hub_outlined,
        title: 'This host is not in a swarm',
        message:
            'Run docker swarm init on the host, or join it to an existing '
            'cluster, and its services show up here.',
      ),
      builder: (SwarmInfo info) => info.isManager
          ? _ServiceList(serverId: serverId)
          : const EmptyView(
              icon: Icons.hub_outlined,
              title: 'This node is a worker',
              message:
                  'Only a Swarm manager can list or change services. Open the '
                  'manager node to work with them.',
            ),
    );
  }
}

class _ServiceList extends ConsumerWidget {
  const _ServiceList({required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<SwarmService>> services = ref.watch(
      servicesProvider(serverId),
    );
    return AsyncSection<List<SwarmService>>(
      value: services,
      onRetry: () => ref.invalidate(servicesProvider(serverId)),
      loadingRows: 3,
      loadingRowHeight: 140,
      isEmpty: (List<SwarmService> list) => list.isEmpty,
      empty: const EmptyView(
        icon: Icons.hub_outlined,
        title: 'No Swarm services',
        message: 'This manager runs no services yet.',
      ),
      builder: (List<SwarmService> list) => CardGrid(
        cards: <Widget>[
          for (final SwarmService service in list)
            _ServiceCard(serverId: serverId, service: service),
        ],
      ),
    );
  }
}

class _ServiceCard extends ConsumerWidget {
  const _ServiceCard({required this.serverId, required this.service});

  final String serverId;
  final SwarmService service;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final bool canOperate = ref.watch(roleProvider(serverId)).canOperate;
    final bool global = service.mode == ServiceMode.global;
    final bool converging = service.isConverging;
    final _CardChrome c = _CardChrome(context);
    return DoomCard(
      padding: c.padding,
      radius: c.cardRadius,
      borderColor: converging ? t.warningBorder : t.border,
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
                    Text(service.name, style: c.title.copyWith(color: t.text)),
                    const SizedBox(height: 3),
                    Text(
                      service.image,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.monoSmall.copyWith(color: t.mutedText),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              StatusPill(
                global
                    ? 'Global · ${service.running} nodes'
                    : converging
                    ? '${service.running} of ${service.desired} · converging'
                    : '${service.running} of ${service.desired} replicas',
                tone: converging ? PillTone.warning : PillTone.accent,
              ),
            ],
          ),
          const SizedBox(height: 12),
          SegmentMeter(<Color>[
            for (
              int i = 0;
              i < (global ? service.running : service.desired);
              i++
            )
              i < service.running ? t.accent : t.warning,
          ]),
          const SizedBox(height: 12),
          ActionRow(
            leading: global
                ? Flexible(
                    child: Text(
                      'One task on every node',
                      maxLines: 3,
                      style: AppText.small.copyWith(
                        color: t.mutedText,
                        height: 1.3,
                      ),
                    ),
                  )
                : (canOperate
                      ? ReplicaStepper(
                          name: service.name,
                          value: service.desired,
                          onChanged: (int value) async {
                            final bool ok = await runAction(
                              context,
                              ref,
                              () => ref
                                  .read(agentApiProvider(serverId))
                                  .scaleService(service.id, value),
                            );
                            if (ok) ref.invalidate(servicesProvider(serverId));
                          },
                        )
                      : null),
            children: <Widget>[
              c.button_(
                'Update',
                tone: converging ? ButtonTone.primary : ButtonTone.outline,
                onPressed: canOperate
                    ? () => runJob(
                        context,
                        ref,
                        serverId,
                        (api) => api.updateService(service.id, force: true),
                      )
                    : null,
              ),
              c.button_(
                'Roll back',
                onPressed: canOperate
                    ? () => runJob(
                        context,
                        ref,
                        serverId,
                        (api) => api.rollbackService(service.id),
                      )
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
