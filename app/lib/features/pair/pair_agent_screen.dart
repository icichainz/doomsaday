import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../../data/servers_repository.dart';
import '../../edition/server_limit.dart';
import '../../layout/layout.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/buttons.dart';
import '../../widgets/notify.dart';
import '../../widgets/page.dart';
import '../../widgets/primitives.dart';
import '../../widgets/sheets.dart';
import '../../widgets/surfaces.dart';
import '../servers/servers_screen.dart';

const String _installCommand =
    'curl -fsSL https://[YOUR-DOMAIN]/install.sh | sh';

/// Opens pairing the way the window asks for it: the pushed screen below 600,
/// a centred dialog from 600 up, where there is no screen to push onto.
///
/// With no room left in this edition it opens P2 instead, wherever pairing is
/// offered from.
Future<void> showPairAgent(BuildContext context, WidgetRef ref) async {
  final ServersRepository repo = ref.read(serversRepositoryProvider);
  if (!repo.canPairAnother) {
    await showServerLimit(
      context,
      limit: repo.maxServers!,
      paired: <String>[for (final Server server in repo.servers) server.name],
    );
    return;
  }
  if (!WindowClass.of(context).usesDialogs) {
    context.push('/pair');
    return;
  }
  await showAdaptiveModal<void>(
    context,
    width: 560,
    builder: (BuildContext context, bool sheet) =>
        const PairAgentScreen(dialog: true),
  );
}

/// Screen 2 — Pair an agent.
///
/// Trust on first use: the certificate the agent presents during the one
/// `POST /v1/pair` call is captured and checked against the `cert_fingerprint`
/// in the response, shown once for confirmation, and only then pinned.
class PairAgentScreen extends ConsumerStatefulWidget {
  const PairAgentScreen({super.key, this.dialog = false});

  /// True when the form is the body of a desktop dialog rather than a screen.
  final bool dialog;

  @override
  ConsumerState<PairAgentScreen> createState() => _PairAgentScreenState();
}

class _PairAgentScreenState extends ConsumerState<PairAgentScreen> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _url = TextEditingController(text: 'https://');
  final TextEditingController _token = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ServersRepository repo = ref.read(serversRepositoryProvider);
      final PairPreview preview = await repo.beginPairing(
        name: _name.text,
        agentUrl: _url.text,
        token: _token.text,
      );
      if (!mounted) return;

      final bool? trusted = await showAdaptiveModal<bool>(
        context,
        builder: (BuildContext context, bool sheet) =>
            _FingerprintBody(preview: preview, sheet: sheet),
      );
      if (trusted != true) {
        setState(() => _busy = false);
        return;
      }

      final PairResult result = await repo.completePairing(preview);
      ref.invalidate(serverCardsProvider);
      if (!mounted) return;
      if (widget.dialog) Navigator.of(context).pop();
      notify(
        context,
        '${result.server.name} paired as ${result.role.label.toLowerCase()} · '
        'certificate pinned',
      );
      context.go('/s/${result.server.id}/overview');
    } on AgentException catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ServersRepository repo = ref.watch(serversRepositoryProvider);
    if (!repo.canPairAnother) {
      // P2 is a sheet over the Servers list, whether the button opened it or
      // a deep link landed here, so a link never gets a bare pushed page.
      return widget.dialog
          ? ServerLimitBody(
              limit: repo.maxServers!,
              paired: <String>[
                for (final Server server in repo.servers) server.name,
              ],
            )
          : const _ServerLimitOverServers();
    }
    final List<Widget> body = _body(context);
    if (!widget.dialog) {
      return PushedPage(gap: 18, fillLast: true, children: body);
    }
    return ModalBody(handle: false, children: body);
  }

  List<Widget> _body(BuildContext context) {
    final AppTokens t = context.tokens;
    return <Widget>[
      if (!widget.dialog) const BackLink('Servers'),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            'Pair a server agent',
            style: AppText.screenTitle.copyWith(color: t.text),
          ),
          const SizedBox(height: 6),
          Text(
            'The agent runs on your server, talks to the Docker socket, and '
            'exposes a REST API to this app.',
            style: AppText.body.copyWith(color: t.mutedText),
          ),
        ],
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const _Step(number: '1', title: 'Install the agent on the server'),
          const SizedBox(height: 10),
          CodeBlock(
            code: _installCommand,
            trailing: DoomIconButton(
              icon: Icons.copy_all_outlined,
              semanticLabel: 'Copy install command',
              size: 44,
              radius: 10,
              onPressed: () {
                Clipboard.setData(const ClipboardData(text: _installCommand));
                notify(context, 'Install command copied');
              },
            ),
          ),
        ],
      ),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const _Step(number: '2', title: 'Enter the connection details'),
          const SizedBox(height: 12),
          LabelledField(
            label: 'Server name',
            hint: 'e.g. prod-eu-1',
            controller: _name,
          ),
          const SizedBox(height: 12),
          LabelledField(
            label: 'Agent URL',
            hint: 'https://host:8443',
            controller: _url,
            mono: true,
          ),
          const SizedBox(height: 12),
          LabelledField(
            label: 'Pairing token',
            hint: 'Run agent_zero pair-token on the host',
            controller: _token,
            obscure: true,
          ),
        ],
      ),
      if (_error != null)
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: t.dangerTint,
            borderRadius: AppShape.smallCardRadius,
            border: Border.all(color: t.dangerBorder),
          ),
          child: Text(
            _error!,
            style: AppText.small.copyWith(color: t.danger, height: 1.4),
          ),
        ),
      const InfoNote(
        icon: Icons.shield_outlined,
        text:
            'HTTPS only. The token is exchanged for a device key stored in '
            "this device's secure storage, and the agent's certificate is "
            'pinned on first connect — the app refuses the connection if it '
            'ever changes.',
      ),
      DoomButton(
        'Test connection and pair',
        tone: ButtonTone.primary,
        height: widget.dialog ? 44 : 56,
        radius: widget.dialog ? 12 : 18,
        expand: true,
        busy: _busy,
        onPressed: _pair,
      ),
    ];
  }
}

/// The `/pair` route with no room left: the Servers screen, with P2 opened
/// over it the instant it is on screen — the same sheet (or dialog, from 600
/// up) the pair button shows. Dismissing it leaves the route behind.
class _ServerLimitOverServers extends ConsumerStatefulWidget {
  const _ServerLimitOverServers();

  @override
  ConsumerState<_ServerLimitOverServers> createState() =>
      _ServerLimitOverServersState();
}

class _ServerLimitOverServersState
    extends ConsumerState<_ServerLimitOverServers> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    if (_shown || !mounted) return;
    _shown = true;
    final ServersRepository repo = ref.read(serversRepositoryProvider);
    await showServerLimit(
      context,
      limit: repo.maxServers ?? repo.servers.length,
      paired: <String>[for (final Server server in repo.servers) server.name],
    );
    if (mounted) GoRouter.of(context).go('/');
  }

  @override
  Widget build(BuildContext context) => const ServersScreen();
}

/// Shown once, before the fingerprint is pinned.
class _FingerprintBody extends StatelessWidget {
  const _FingerprintBody({required this.preview, required this.sheet});

  final PairPreview preview;
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
              'Trust this certificate?',
              style: AppText.sheetTitle.copyWith(color: t.text),
            ),
            const SizedBox(height: 8),
            Text(
              '${preview.server.host} answered, and the fingerprint it '
              'reported matches the certificate it actually presented. Check '
              'it against what the agent printed on the host, then pin it.',
              style: AppText.body.copyWith(color: t.mutedText, height: 1.5),
            ),
            const SizedBox(height: 14),
            CodeBlock(
              caption: 'SHA-256 fingerprint',
              code: _wrap(preview.fingerprint),
            ),
            const SizedBox(height: 12),
            RowGroup(
              children: <Widget>[
                DetailRow('Agent version', preview.agentVersion),
                DetailRow('Your role', preview.role.label),
                DetailRow('Device id', preview.deviceId, mono: true),
              ],
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
                    'Pin and pair',
                    expand: true,
                    height: 54,
                    radius: 16,
                    tone: ButtonTone.primary,
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

  /// Four groups per line, which is how the agent prints it on the host.
  static String _wrap(String fingerprint) {
    final List<String> parts = fingerprint.split(':');
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < parts.length; i += 8) {
      if (i > 0) out.write('\n');
      out.write(parts.skip(i).take(8).join(':'));
    }
    return out.toString();
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.title});

  final String number;
  final String title;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Row(
      children: <Widget>[
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: t.faintDivider,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            number,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: t.text,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(title, style: AppText.rowTitle.copyWith(color: t.text)),
        ),
      ],
    );
  }
}
