import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models.dart';
import '../../data/providers.dart';
import '../../data/servers_repository.dart';
import '../../data/this_device.dart';
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
import '../../widgets/stroke_icons.dart';
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
  PairFailure? _error;

  /// In the desktop dialog the certificate check is the dialog's second
  /// step (DesktopPair) rather than a second dialog stacked on the first.
  PairPreview? _preview;

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

      if (widget.dialog) {
        setState(() => _preview = preview);
        return;
      }

      final bool? trusted = await showAdaptiveModal<bool>(
        context,
        builder: (BuildContext context, bool sheet) =>
            _FingerprintBody(preview: preview, sheet: sheet),
      );
      if (trusted != true) {
        setState(() => _busy = false);
        return;
      }

      await _complete(preview);
    } on AgentException catch (error) {
      if (mounted) {
        setState(() => _error = PairFailure.from(error, agentUrl: _url.text));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Pins the certificate and stores the device key.
  Future<void> _complete(PairPreview preview) async {
    final ServersRepository repo = ref.read(serversRepositoryProvider);
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
  }

  /// "Pin and pair" in the dialog's second step.
  Future<void> _pin() async {
    final PairPreview? preview = _preview;
    if (preview == null || _busy) return;
    setState(() => _busy = true);
    try {
      await _complete(preview);
    } on AgentException catch (error) {
      if (mounted) {
        setState(() {
          _preview = null;
          _error = PairFailure.from(error, agentUrl: _url.text);
        });
      }
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
    final PairPreview? preview = _preview;
    if (widget.dialog && preview != null) {
      return _ConfirmStep(
        preview: preview,
        busy: _busy,
        onBack: () => setState(() => _preview = null),
        onPin: _pin,
      );
    }
    final List<Widget> body = _body(context);
    if (!widget.dialog) {
      return PushedPage(gap: 18, fillLast: true, children: body);
    }
    return ModalBody(
      handle: false,
      children: <Widget>[const _DialogStep(step: 1), ...body],
    );
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
        PairErrorCard(failure: _error!)
      else
        const InfoNote(
          icon: Icons.shield_outlined,
          text:
              'HTTPS only. The token is exchanged for a device key stored in '
              "this device's secure storage, and the agent's certificate is "
              'pinned on first connect — the app refuses the connection if it '
              'ever changes.',
        ),
      DoomButton(
        _error == null ? 'Test connection and pair' : 'Try again',
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

/// A SHA-256 fingerprint as eight groups of eight hex characters, the unit a
/// person can compare at a glance. The agent prints the same bytes as
/// `A4:E9:7C:10:…`; every group here is four of those pairs without colons.
List<String> fingerprintGroups(String fingerprint) {
  final String hex = fingerprint
      .replaceAll(RegExp('[^0-9a-fA-F]'), '')
      .toUpperCase();
  return <String>[
    for (int i = 0; i < hex.length; i += 8)
      hex.substring(i, i + 8 > hex.length ? hex.length : i + 8),
  ];
}

/// Why pairing stopped, in the words the Pair screen's red card uses
/// (`design/PairError.dc.html`).
class PairFailure {
  const PairFailure(this.title, this.message);

  final String title;
  final String message;

  factory PairFailure.from(AgentException error, {String agentUrl = ''}) {
    final String device = thisDeviceLabel(capitalized: false);
    final String where =
        agentUrl.trim().isEmpty || agentUrl.trim() == 'https://'
        ? 'that address'
        : agentUrl.trim();
    return switch (error.code) {
      'certificate_mismatch' => PairFailure(
        "Certificate doesn't match",
        'The certificate the agent presented is not the one it reported, so '
            'nothing was pinned or saved. Something may sit between $device '
            'and the host.',
      ),
      'pairing_failed' when error.status == 401 => const PairFailure(
        'Token not accepted',
        'The agent says the pairing token is not valid or has expired. Run '
            'agent_zero pair-token on the host for a fresh one.',
      ),
      'agent_unreachable' => PairFailure(
        'Agent not reachable',
        'Nothing answered at $where. Check the address and port, and that '
            'the agent is running on the host.',
      ),
      'secure_storage_unavailable' => PairFailure(
        'Secure storage unavailable',
        "The device key can't be stored in $device's secure storage, so "
            'nothing was saved. On a Mac this happens in an unsigned build; '
            'use a signed one.',
      ),
      'insecure_transport' => PairFailure('HTTPS required', error.message),
      'validation_failed' => PairFailure('Check the details', error.message),
      'conflict' => PairFailure('Already paired', error.message),
      _ => PairFailure('Pairing failed', error.message),
    };
  }
}

/// The red note card that replaces the HTTPS note when pairing fails.
class PairErrorCard extends StatelessWidget {
  const PairErrorCard({super.key, required this.failure});

  final PairFailure failure;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: t.dangerTint,
          borderRadius: AppShape.smallCardRadius,
          border: Border.all(color: t.dangerBorder),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(Icons.gpp_bad_outlined, size: 20, color: t.danger),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    failure.title,
                    style: AppText.label.copyWith(
                      color: t.danger,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    failure.message,
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
      ),
    );
  }
}

/// Shown once, before the fingerprint is pinned (`design/PairConfirm.dc.html`).
class _FingerprintBody extends StatelessWidget {
  const _FingerprintBody({required this.preview, required this.sheet});

  final PairPreview preview;
  final bool sheet;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final List<String> groups = fingerprintGroups(preview.fingerprint);
    final TextStyle groupStyle = TextStyle(
      fontFamily: AppFonts.mono,
      fontSize: 14,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.4,
      color: t.text,
    );
    return ModalBody(
      handle: sheet,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: t.accentTint,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                Icons.verified_user_outlined,
                size: 22,
                color: t.accent,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    'Check the certificate',
                    style: AppText.sheetTitle.copyWith(color: t.text),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    preview.server.host,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.monoSmall.copyWith(color: t.mutedText),
                  ),
                ],
              ),
            ),
          ],
        ),
        Text(
          'Compare with the fingerprint the agent printed on the host. If '
          'every group matches, pin it: from then on the app refuses this '
          'server if the certificate changes.',
          style: AppText.label.copyWith(color: t.codeText, height: 1.5),
        ),
        Semantics(
          label: 'SHA-256 fingerprint ${groups.join(' ')}',
          container: true,
          excludeSemantics: true,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            decoration: BoxDecoration(
              color: t.codeBlock,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: t.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  'SHA-256 FINGERPRINT',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                    color: t.mutedText,
                  ),
                ),
                for (int row = 0; row < groups.length; row += 4) ...<Widget>[
                  SizedBox(height: row == 0 ? 10 : 6),
                  Row(
                    children: <Widget>[
                      for (int i = row; i < row + 4; i++) ...<Widget>[
                        if (i > row) const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            i < groups.length ? groups[i] : '',
                            maxLines: 1,
                            softWrap: false,
                            style: groupStyle,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: AppShape.smallCardRadius,
            border: Border.all(color: t.border),
          ),
          child: Column(
            children: <Widget>[
              _PreviewRow('Agent version', preview.agentVersion, mono: true),
              _PreviewRow(
                'Role for ${thisDeviceLabel(capitalized: false)}',
                preview.role.label,
              ),
              _PreviewRow(
                'Device id',
                preview.deviceId,
                mono: true,
                last: true,
              ),
            ],
          ),
        ),
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
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow(
    this.label,
    this.value, {
    this.mono = false,
    this.last = false,
  });

  final String label;
  final String value;
  final bool mono;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: AppText.label.copyWith(color: t.mutedText),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            value,
            style: mono
                ? AppText.mono.copyWith(
                    color: t.text,
                    fontWeight: FontWeight.w400,
                  )
                : AppText.label.copyWith(color: t.text),
          ),
        ],
      ),
    );
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

/// The dialog's top line: which step, and the close button.
class _DialogStep extends StatelessWidget {
  const _DialogStep({required this.step});

  final int step;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            'PAIR A SERVER · STEP $step OF 2',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
              color: t.mutedText,
            ),
          ),
        ),
        DoomIconButton(
          glyph: StrokeGlyph.close,
          semanticLabel: 'Close',
          size: 32,
          radius: 8,
          filled: false,
          foreground: t.codeText,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }
}

/// DesktopPair: the certificate check as the pair dialog's second step —
/// the fingerprint in the groups the agent prints on the host, what pairing
/// grants, and Back, Cancel, "Pin and pair". Return pins.
class _ConfirmStep extends StatelessWidget {
  const _ConfirmStep({
    required this.preview,
    required this.busy,
    required this.onBack,
    required this.onPin,
  });

  final PairPreview preview;
  final bool busy;
  final VoidCallback onBack;
  final VoidCallback onPin;

  /// Four lines of eight bytes, each line split into two groups of four.
  static List<List<String>> groups(String fingerprint) {
    final List<String> bytes = fingerprint.split(':');
    final List<List<String>> lines = <List<String>>[];
    for (int i = 0; i < bytes.length; i += 8) {
      final List<String> line = bytes.skip(i).take(8).toList();
      lines.add(<String>[
        line.take(4).join(':'),
        if (line.length > 4) line.skip(4).join(':'),
      ]);
    }
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final TextStyle mono = TextStyle(
      fontFamily: AppFonts.mono,
      fontSize: 14,
      fontWeight: FontWeight.w500,
      height: 1.6,
      color: t.text,
    );
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.enter): onPin,
      },
      child: Focus(
        autofocus: true,
        child: ModalBody(
          handle: false,
          children: <Widget>[
            const _DialogStep(step: 2),
            Row(
              children: <Widget>[
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: t.accentTint,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: StrokeIcon(
                    StrokeGlyph.shield,
                    size: 20,
                    color: t.accent,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        'Trust this certificate?',
                        style: AppText.sheetTitle.copyWith(
                          color: t.text,
                          fontSize: 22,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text.rich(
                        TextSpan(
                          children: <InlineSpan>[
                            TextSpan(text: '${preview.server.name} · '),
                            TextSpan(
                              text: preview.server.host,
                              style: const TextStyle(fontFamily: AppFonts.mono),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.small.copyWith(color: t.mutedText),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Text(
              'The agent answered, and the fingerprint it reported matches '
              'the certificate it presented. Compare it with what the agent '
              'printed on the host, then pin it. The app refuses the '
              'connection if it ever changes.',
              style: AppText.body.copyWith(color: t.codeText, height: 1.5),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: t.codeBlock,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: t.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    'SHA-256 FINGERPRINT',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                      color: t.mutedText,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectionArea(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        for (final List<String> line in groups(
                          preview.fingerprint,
                        ))
                          Row(
                            children: <Widget>[
                              for (int i = 0; i < line.length; i++) ...<Widget>[
                                if (i > 0) const SizedBox(width: 22),
                                Text(line[i], style: mono),
                              ],
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            RowGroup(
              radius: 12,
              horizontalPadding: 14,
              dividerColor: t.faintDivider,
              children: <Widget>[
                DetailRow('Agent version', preview.agentVersion, minHeight: 44),
                DetailRow('Your role', preview.role.label, minHeight: 44),
                DetailRow(
                  'Device id',
                  preview.deviceId,
                  mono: true,
                  minHeight: 44,
                ),
              ],
            ),
            Row(
              children: <Widget>[
                Semantics(
                  button: true,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: onBack,
                    child: SizedBox(
                      height: 40,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const SizedBox(width: 4),
                          StrokeIcon(
                            StrokeGlyph.chevronLeft,
                            size: 16,
                            color: t.mutedText,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Back',
                            style: AppText.label.copyWith(
                              color: t.mutedText,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(width: 4),
                        ],
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                DoomButton(
                  'Cancel',
                  height: 40,
                  radius: 10,
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 10),
                DoomButton(
                  'Pin and pair',
                  height: 40,
                  radius: 10,
                  tone: ButtonTone.primary,
                  busy: busy,
                  onPressed: onPin,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
