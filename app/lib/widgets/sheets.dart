import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/biometrics.dart';
import '../data/models.dart';
import '../data/this_device.dart';
import '../layout/layout.dart';
import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import 'buttons.dart';
import 'primitives.dart';
import 'surfaces.dart';

class _Heading extends StatelessWidget {
  const _Heading({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.danger = true,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool danger;

  /// D3 draws a 44 px tile and a 22 px title; the sheet keeps 48 and 24.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final double tile = compact ? 44 : 48;
    return Row(
      children: <Widget>[
        Container(
          width: tile,
          height: tile,
          decoration: BoxDecoration(
            color: danger ? t.dangerTint : t.accentTint,
            borderRadius: BorderRadius.circular(compact ? 14 : 16),
          ),
          child: Icon(icon, size: 22, color: danger ? t.danger : t.accent),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title,
                style:
                    (compact
                            ? AppText.sheetTitle.copyWith(fontSize: 22)
                            : AppText.sheetTitle)
                        .copyWith(color: t.text),
              ),
              const SizedBox(height: 2),
              Text(subtitle, style: AppText.small.copyWith(color: t.mutedText)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Every risky action goes through this, which shows the exact request line
/// the agent will receive.
class RiskyAction {
  const RiskyAction({
    required this.title,
    required this.subtitle,
    required this.explanation,
    required this.requestLine,
    required this.confirmLabel,
    required this.icon,
    required this.requireFingerprint,
    required this.target,
  });

  final String title;
  final String subtitle;
  final String explanation;

  /// For example `POST /v1/containers/4f2a9c1e7b3d/stop?timeout=10`.
  final String requestLine;
  final String confirmLabel;
  final IconData icon;

  /// Mirrors the agent's `require_biometric_for_risky` setting.
  final bool requireFingerprint;

  /// What the person types when this device cannot do biometrics, exactly as
  /// D3 shows it: the container, image, volume, network, stack or server name.
  final String target;
}

/// What the person decided, and how they confirmed it.
///
/// [confirmation] is what becomes the `X-Confirmed` header. It is only ever
/// [Confirmed.biometric] after [Authenticator.confirm] returned true on this
/// device, and only [Confirmed.typed] after an exact name match.
class RiskyOutcome {
  const RiskyOutcome({required this.confirmed, required this.confirmation});

  final bool confirmed;
  final Confirmed confirmation;

  static const RiskyOutcome cancelled = RiskyOutcome(
    confirmed: false,
    confirmation: Confirmed.none,
  );
}

Future<RiskyOutcome> showRiskyConfirm(
  BuildContext context,
  RiskyAction action, {
  required Authenticator authenticator,
}) async {
  final RiskyOutcome? result = await showAdaptiveModal<RiskyOutcome>(
    context,
    builder: (BuildContext context, bool sheet) => _ConfirmBody(
      action: action,
      authenticator: authenticator,
      sheet: sheet,
    ),
  );
  return result ?? RiskyOutcome.cancelled;
}

class _ConfirmBody extends StatefulWidget {
  const _ConfirmBody({
    required this.action,
    required this.authenticator,
    required this.sheet,
  });

  final RiskyAction action;
  final Authenticator authenticator;
  final bool sheet;

  @override
  State<_ConfirmBody> createState() => _ConfirmBodyState();
}

class _ConfirmBodyState extends State<_ConfirmBody> {
  late bool _needsConfirmation = widget.action.requireFingerprint;
  final TextEditingController _typed = TextEditingController();
  final FocusNode _typedFocus = FocusNode();

  /// `null` until `local_auth` has answered; the button waits rather than
  /// guessing which confirmation this device can give.
  bool? _biometrics;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.authenticator.isAvailable().then((bool value) {
      if (mounted) setState(() => _biometrics = value);
    });
  }

  @override
  void dispose() {
    _typed.dispose();
    _typedFocus.dispose();
    super.dispose();
  }

  bool get _typing => _needsConfirmation && _biometrics == false;

  bool get _nameMatches => _typed.text.trim() == widget.action.target;

  bool get _unlocked =>
      !_needsConfirmation || _biometrics == true || _nameMatches;

  Confirmed get _method => !_needsConfirmation
      ? Confirmed.none
      : (_biometrics == true ? Confirmed.biometric : Confirmed.typed);

  Future<void> _confirm() async {
    if (!_unlocked || _busy) return;
    if (!_needsConfirmation) {
      Navigator.of(
        context,
      ).pop(const RiskyOutcome(confirmed: true, confirmation: Confirmed.none));
      return;
    }
    if (_typing) {
      Navigator.of(
        context,
      ).pop(const RiskyOutcome(confirmed: true, confirmation: Confirmed.typed));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final bool passed = await widget.authenticator.confirm(
      widget.action.title.replaceAll('?', ''),
    );
    if (!mounted) return;
    if (!passed) {
      // A cancelled or failed prompt sends nothing at all, so the agent's
      // 428 rule still protects the action.
      setState(() {
        _busy = false;
        _error =
            'Not confirmed. Nothing was sent to the agent. Unlock with your '
            'fingerprint, face or device passcode to go ahead.';
      });
      return;
    }
    Navigator.of(context).pop(
      const RiskyOutcome(confirmed: true, confirmation: Confirmed.biometric),
    );
  }

  void _cancel() => Navigator.of(context).pop(RiskyOutcome.cancelled);

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final String? header = _method.header;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.enter): _confirm,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _confirm,
      },
      child: ModalBody(
        handle: widget.sheet,
        children: <Widget>[
          _Heading(
            icon: widget.action.icon,
            title: widget.action.title,
            subtitle: widget.action.subtitle,
            compact: !widget.sheet,
          ),
          Text(
            widget.action.explanation,
            style: AppText.body.copyWith(color: t.codeText, height: 1.5),
          ),
          CodeBlock(
            caption: 'Request sent to the agent',
            // D3 spells the header out; the phone sheet shows the line alone.
            code: widget.sheet || header == null
                ? widget.action.requestLine
                : '${widget.action.requestLine}\nX-Confirmed: $header',
          ),
          if (_typing)
            _TypedConfirmField(
              controller: _typed,
              focusNode: _typedFocus,
              target: widget.action.target,
              matches: _nameMatches,
              onChanged: () => setState(() {}),
              onSubmitted: _confirm,
            )
          else
            SwitchRow(
              label: 'Confirm with fingerprint',
              description: widget.action.requireFingerprint
                  ? 'This agent requires it for risky actions'
                  : 'This agent does not require it here',
              value: _needsConfirmation,
              onChanged: widget.action.requireFingerprint
                  ? null
                  : (bool value) => setState(() => _needsConfirmation = value),
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
          if (widget.sheet)
            Row(
              children: <Widget>[
                Expanded(
                  child: DoomButton(
                    'Cancel',
                    expand: true,
                    height: 54,
                    radius: 16,
                    onPressed: _cancel,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DoomButton(
                    widget.action.confirmLabel,
                    expand: true,
                    height: 54,
                    radius: 16,
                    busy: _busy,
                    tone: ButtonTone.dangerFilled,
                    onPressed: _unlocked ? _confirm : null,
                  ),
                ),
              ],
            )
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                DoomButton(
                  'Cancel',
                  height: 40,
                  radius: 10,
                  onPressed: _cancel,
                ),
                const SizedBox(width: 10),
                DoomButton(
                  widget.action.confirmLabel,
                  height: 40,
                  radius: 10,
                  busy: _busy,
                  tone: ButtonTone.dangerFilled,
                  onPressed: _unlocked ? _confirm : null,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// D3: "This Mac has no Touch ID. Type api-gateway to confirm."
class _TypedConfirmField extends StatelessWidget {
  const _TypedConfirmField({
    required this.controller,
    required this.focusNode,
    required this.target,
    required this.matches,
    required this.onChanged,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String target;
  final bool matches;
  final VoidCallback onChanged;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final OutlineInputBorder border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: matches ? t.accent : t.outlineBorder),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text.rich(
          TextSpan(
            children: <InlineSpan>[
              // D3 names the biometric this machine is missing. The wording
              // follows the platform; the layout never does.
              TextSpan(text: '${noBiometricLine()} Type '),
              TextSpan(
                text: target,
                style: TextStyle(
                  fontFamily: AppFonts.mono,
                  fontWeight: FontWeight.w500,
                  color: t.text,
                ),
              ),
              const TextSpan(text: ' to confirm.'),
            ],
          ),
          style: AppText.small.copyWith(color: t.codeText),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 40,
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            onChanged: (_) => onChanged(),
            onSubmitted: (_) => onSubmitted(),
            style: TextStyle(
              color: t.text,
              fontSize: 14,
              fontFamily: AppFonts.mono,
            ),
            decoration: InputDecoration(
              hintText: target,
              hintStyle: TextStyle(
                color: t.mutedText,
                fontSize: 14,
                fontFamily: AppFonts.mono,
              ),
              filled: true,
              fillColor: t.ground,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              border: border,
              enabledBorder: border,
              focusedBorder: border,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          matches
              ? 'Name matches. Press Return to go ahead.'
              : 'The button unlocks when the name matches exactly.',
          style: AppText.tiny.copyWith(color: t.mutedText),
        ),
      ],
    );
  }
}

/// Single-field modal for pull image, create volume, create network and the
/// registry forms.
Future<String?> showPromptSheet(
  BuildContext context, {
  required String title,
  required String subtitle,
  required String label,
  required String hint,
  required String confirmLabel,
  required IconData icon,
  bool mono = true,
  bool obscure = false,
}) {
  return showAdaptiveModal<String>(
    context,
    builder: (BuildContext context, bool sheet) => _PromptBody(
      title: title,
      subtitle: subtitle,
      label: label,
      hint: hint,
      confirmLabel: confirmLabel,
      icon: icon,
      mono: mono,
      obscure: obscure,
      sheet: sheet,
    ),
  );
}

class _PromptBody extends StatefulWidget {
  const _PromptBody({
    required this.title,
    required this.subtitle,
    required this.label,
    required this.hint,
    required this.confirmLabel,
    required this.icon,
    required this.mono,
    required this.obscure,
    required this.sheet,
  });

  final String title;
  final String subtitle;
  final String label;
  final String hint;
  final String confirmLabel;
  final IconData icon;
  final bool mono;
  final bool obscure;
  final bool sheet;

  @override
  State<_PromptBody> createState() => _PromptBodyState();
}

class _PromptBodyState extends State<_PromptBody> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String value = _controller.text.trim();
    if (value.isEmpty) return;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final double height = widget.sheet ? 54 : 40;
    final double radius = widget.sheet ? 16 : 10;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.enter): _submit,
      },
      child: ModalBody(
        handle: widget.sheet,
        children: <Widget>[
          _Heading(
            icon: widget.icon,
            title: widget.title,
            subtitle: widget.subtitle,
            danger: false,
            compact: !widget.sheet,
          ),
          LabelledField(
            label: widget.label,
            hint: widget.hint,
            controller: _controller,
            mono: widget.mono,
            obscure: widget.obscure,
            autofocus: true,
            onSubmitted: (_) => _submit(),
          ),
          Row(
            mainAxisAlignment: widget.sheet
                ? MainAxisAlignment.start
                : MainAxisAlignment.end,
            children: <Widget>[
              if (widget.sheet) ...<Widget>[
                Expanded(
                  child: DoomButton(
                    'Cancel',
                    expand: true,
                    height: height,
                    radius: radius,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DoomButton(
                    widget.confirmLabel,
                    expand: true,
                    height: height,
                    radius: radius,
                    tone: ButtonTone.primary,
                    onPressed: _submit,
                  ),
                ),
              ] else ...<Widget>[
                DoomButton(
                  'Cancel',
                  height: height,
                  radius: radius,
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(width: 10),
                DoomButton(
                  widget.confirmLabel,
                  height: height,
                  radius: radius,
                  tone: ButtonTone.primary,
                  onPressed: _submit,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Labelled text field matching the Pair an agent inputs.
class LabelledField extends StatelessWidget {
  const LabelledField({
    super.key,
    required this.label,
    required this.hint,
    required this.controller,
    this.mono = false,
    this.obscure = false,
    this.autofocus = false,
    this.trailing,
    this.onSubmitted,
  });

  final String label;
  final String hint;
  final TextEditingController controller;
  final bool mono;
  final bool obscure;
  final bool autofocus;
  final Widget? trailing;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final Widget field = SizedBox(
      height: context.density.compact ? 44 : 50,
      child: TextField(
        controller: controller,
        obscureText: obscure,
        autofocus: autofocus,
        onSubmitted: onSubmitted,
        style: TextStyle(
          color: t.text,
          fontSize: mono ? 14 : 15,
          fontFamily: mono ? AppFonts.mono : AppFonts.sans,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: t.mutedText, fontSize: mono ? 14 : 15),
          filled: true,
          fillColor: t.surface,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 14,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: t.strongBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: t.strongBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: t.accent),
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label, style: AppText.small.copyWith(color: t.mutedText)),
        const SizedBox(height: 6),
        if (trailing == null)
          field
        else
          Row(
            children: <Widget>[
              Expanded(child: field),
              const SizedBox(width: 8),
              trailing!,
            ],
          ),
      ],
    );
  }
}

/// Progress modal for the long operations that come back as jobs.
Future<void> showJobSheet(
  BuildContext context, {
  required Job job,
  required Stream<Job> events,
}) {
  return showAdaptiveModal<void>(
    context,
    dismissible: false,
    builder: (BuildContext context, bool sheet) =>
        _JobBody(initial: job, events: events, sheet: sheet),
  );
}

class _JobBody extends StatefulWidget {
  const _JobBody({
    required this.initial,
    required this.events,
    required this.sheet,
  });

  final Job initial;
  final Stream<Job> events;
  final bool sheet;

  @override
  State<_JobBody> createState() => _JobBodyState();
}

class _JobBodyState extends State<_JobBody> {
  late Job _job = widget.initial;
  StreamSubscription<Job>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.events.listen(
      (Job job) => setState(() => _job = job),
      onError: (Object error) => setState(() {
        _job = _job.copyWith(status: JobStatus.failed, error: '$error');
      }),
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool done = _job.status.isFinished;
    final bool failed =
        _job.status == JobStatus.failed || _job.status == JobStatus.canceled;
    return ModalBody(
      handle: widget.sheet,
      children: <Widget>[
        _Heading(
          icon: failed ? Icons.error_outline : Icons.play_circle_outline,
          title: _job.title,
          subtitle: switch (_job.status) {
            JobStatus.queued => 'Queued on the agent',
            JobStatus.running => 'Running on the agent',
            JobStatus.succeeded => 'Finished',
            JobStatus.canceled => 'Canceled',
            JobStatus.failed => _job.error ?? 'Failed',
          },
          danger: failed,
          compact: !widget.sheet,
        ),
        MeterBar(_job.progress, color: failed ? t.danger : t.accent),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 96),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: t.codeBlock,
            borderRadius: AppShape.smallCardRadius,
            border: Border.all(color: t.faintDivider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final String line in _job.lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: SelectableText(
                    line,
                    style: AppText.logLine.copyWith(color: t.codeText),
                  ),
                ),
              if (_job.lines.isEmpty)
                Text(
                  'Waiting for the first progress line…',
                  style: AppText.logLine.copyWith(color: t.mutedText),
                ),
            ],
          ),
        ),
        Align(
          alignment: widget.sheet
              ? Alignment.center
              : AlignmentDirectional.centerEnd,
          child: DoomButton(
            done ? 'Done' : 'Run in the background',
            expand: widget.sheet,
            height: widget.sheet ? 54 : 40,
            radius: widget.sheet ? 16 : 10,
            tone: done ? ButtonTone.primary : ButtonTone.outline,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
      ],
    );
  }
}
