import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import '../../widgets/stroke_icons.dart';

/// Screen 15 — Registry credentials.
class RegistriesScreen extends ConsumerWidget {
  const RegistriesScreen({super.key, required this.serverId});

  final String serverId;

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final String? host = await showPromptSheet(
      context,
      title: 'Add a registry',
      subtitle: 'Stored encrypted on the agent',
      label: 'Registry host',
      hint: 'ghcr.io',
      confirmLabel: 'Next',
      icon: Icons.lock_outline,
    );
    if (host == null || !context.mounted) return;
    final String? username = await showPromptSheet(
      context,
      title: 'Sign in to $host',
      subtitle: 'The app never reads the secret back',
      label: 'Username',
      hint: 'deploy-bot',
      confirmLabel: 'Next',
      icon: Icons.person_outline,
      mono: false,
    );
    if (username == null || !context.mounted) return;
    final String? secret = await showPromptSheet(
      context,
      title: 'Token for $host',
      subtitle: 'Sent once over HTTPS',
      label: 'Password or token',
      hint: 'ghp_…',
      confirmLabel: 'Save',
      icon: Icons.key_outlined,
      mono: false,
      obscure: true,
    );
    if (secret == null || !context.mounted) return;
    final bool ok = await runAction(
      context,
      ref,
      () => ref
          .read(agentApiProvider(serverId))
          .addRegistry(host: host, username: username, secret: secret),
      success: '$host added',
    );
    if (ok) ref.invalidate(registriesProvider(serverId));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<RegistryInfo>> registries = ref.watch(
      registriesProvider(serverId),
    );
    final bool canManage = ref
        .watch(roleProvider(serverId))
        .canManageRegistries;

    return PushedPage(
      gap: 14,
      fillLast: true,
      children: <Widget>[
        const BackLink('Settings'),
        ScreenHeader(
          title: 'Registries',
          subtitle: 'Used by $serverId when it pulls images',
        ),
        AsyncSection<List<RegistryInfo>>(
          value: registries,
          onRetry: () => ref.invalidate(registriesProvider(serverId)),
          loadingRows: 3,
          loadingRowHeight: 118,
          isEmpty: (List<RegistryInfo> list) => list.isEmpty,
          empty: const EmptyView(
            glyph: StrokeGlyph.lock,
            title: 'No registries',
            message:
                'This agent pulls anonymously. Add one to use private images.',
          ),
          builder: (List<RegistryInfo> list) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final RegistryInfo registry in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: _RegistryCard(serverId: serverId, registry: registry),
                ),
            ],
          ),
        ),
        const InfoNote(
          icon: Icons.lock_outline,
          text:
              'Passwords and tokens are sent once over HTTPS and stored '
              'encrypted on the agent. The app only ever reads back the '
              'username and status.',
        ),
        if (canManage)
          DoomButton(
            'Add a registry',
            icon: Icons.add,
            tone: ButtonTone.primary,
            height: 56,
            radius: 18,
            expand: true,
            onPressed: () => _add(context, ref),
          ),
      ],
    );
  }
}

class _RegistryCard extends ConsumerWidget {
  const _RegistryCard({required this.serverId, required this.registry});

  final String serverId;
  final RegistryInfo registry;

  Future<void> _test(BuildContext context, WidgetRef ref) async {
    try {
      final bool ok = await ref
          .read(agentApiProvider(serverId))
          .testRegistry(registry.id);
      ref.invalidate(registriesProvider(serverId));
      if (context.mounted) {
        notify(
          context,
          ok
              ? 'Login to ${registry.host} succeeded'
              : 'The agent could not sign in to ${registry.host}',
          danger: !ok,
        );
      }
    } on AgentException catch (error) {
      if (context.mounted) notify(context, error.toString(), danger: true);
    }
  }

  Future<void> _replace(BuildContext context, WidgetRef ref) async {
    final String? secret = await showPromptSheet(
      context,
      title: 'Replace the token',
      subtitle: registry.host,
      label: 'New password or token',
      hint: 'ghp_…',
      confirmLabel: 'Replace',
      icon: Icons.key_outlined,
      mono: false,
      obscure: true,
    );
    if (secret == null || !context.mounted) return;
    final bool ok = await runAction(
      context,
      ref,
      () => ref
          .read(agentApiProvider(serverId))
          .updateRegistry(registry.id, secret: secret),
      success: 'Token replaced',
    );
    if (ok) ref.invalidate(registriesProvider(serverId));
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final String? username = await showPromptSheet(
      context,
      title: 'Edit ${registry.host}',
      subtitle: 'Changes the stored username',
      label: 'Username',
      hint: registry.username.isEmpty ? 'deploy-bot' : registry.username,
      confirmLabel: 'Save',
      icon: Icons.person_outline,
      mono: false,
    );
    if (username == null || !context.mounted) return;
    final bool ok = await runAction(
      context,
      ref,
      () => ref
          .read(agentApiProvider(serverId))
          .updateRegistry(registry.id, username: username),
      success: 'Username updated',
    );
    if (ok) ref.invalidate(registriesProvider(serverId));
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final RiskyOutcome outcome = await confirmRisky(
      context,
      ref,
      RiskyAction(
        title: 'Remove ${registry.host}?',
        subtitle: '$serverId · ${registry.subtitle}',
        explanation:
            'The stored credentials are deleted. Pulls from this registry then '
            'go out anonymously, or fail if it is private.',
        requestLine: 'DELETE /v1/registries/${registry.id}',
        confirmLabel: 'Remove registry',
        icon: Icons.delete_outline,
        // Registry writes are admin only but not in the agent's 428 list.
        requireFingerprint: false,
        target: registry.host,
      ),
    );
    if (!outcome.confirmed || !context.mounted) return;
    final bool ok = await runAction(
      context,
      ref,
      () => ref.read(agentApiProvider(serverId)).removeRegistry(registry.id),
      success: '${registry.host} removed',
    );
    if (ok) ref.invalidate(registriesProvider(serverId));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppTokens t = context.tokens;
    final bool canManage = ref
        .watch(roleProvider(serverId))
        .canManageRegistries;
    final (Color border, PillTone tone) = switch (registry.status) {
      RegistryStatus.verified => (t.border, PillTone.accent),
      RegistryStatus.expiring => (t.warningBorder, PillTone.warning),
      RegistryStatus.failed => (t.dangerBorder, PillTone.danger),
      RegistryStatus.anonymous => (t.border, PillTone.neutral),
    };
    return DoomCard(
      borderColor: border,
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
                      registry.host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: AppFonts.mono,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: t.text,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      registry.subtitle,
                      style: AppText.small.copyWith(color: t.mutedText),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              StatusPill(registry.statusLabel, tone: tone),
            ],
          ),
          if (canManage) ...<Widget>[
            const SizedBox(height: 12),
            if (registry.status == RegistryStatus.anonymous)
              DoomButton(
                'Sign in',
                expand: true,
                onPressed: () => _edit(context, ref),
              )
            else
              Row(
                children: <Widget>[
                  Expanded(
                    child:
                        registry.status == RegistryStatus.expiring ||
                            registry.status == RegistryStatus.failed
                        ? DoomButton(
                            'Replace token',
                            expand: true,
                            tone: ButtonTone.primary,
                            onPressed: () => _replace(context, ref),
                          )
                        : DoomButton(
                            'Test login',
                            expand: true,
                            onPressed: () => _test(context, ref),
                          ),
                  ),
                  const SizedBox(width: 8),
                  DoomButton('Edit', onPressed: () => _edit(context, ref)),
                  const SizedBox(width: 8),
                  DoomButton(
                    'Remove',
                    tone: ButtonTone.danger,
                    onPressed: () => _remove(context, ref),
                  ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}
