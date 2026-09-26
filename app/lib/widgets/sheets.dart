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
import 'stroke_icons.dart';
import 'surfaces.dart';

class _Heading extends StatelessWidget {
  const _Heading({
    required this.glyph,
    required this.title,
    required this.subtitle,
    this.danger = true,
    this.compact = false,
  });

  final StrokeGlyph glyph;
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
          child: StrokeIcon(
            glyph,
            size: 22,
            color: danger ? t.danger : t.accent,
          ),
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
    required this.glyph,
    required this.requireFingerprint,
    required this.target,
  });

  final String title;
  final String subtitle;
  final String explanation;

  /// For example `POST /v1/containers/4f2a9c1e7b3d/stop?timeout=10`.
  final String requestLine;
  final String confirmLabel;
  final StrokeGlyph glyph;

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
            glyph: widget.action.glyph,
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
  required StrokeGlyph glyph,
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
      glyph: glyph,
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
    required this.glyph,
    required this.mono,
    required this.obscure,
    required this.sheet,
  });

  final String title;
  final String subtitle;
  final String label;
  final String hint;
  final String confirmLabel;
  final StrokeGlyph glyph;
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
            glyph: widget.glyph,
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

/// How the job sheet was left.
enum JobSheetExit {
  /// The job finished (or failed) and the person pressed "Done".
  finished,

  /// "Run in background": the job goes on without the sheet.
  background,

  /// "Cancel": the agent was asked to stop it.
  canceled,
}

/// Progress modal for the long operations that come back as jobs.
///
/// Boards `JobSheet` (phone), `DesktopJob` (the 500 px dialog from 600 up)
/// and `JobDone`: a heading with the job and the server, a progress bar with
/// the percentage and the elapsed time, the agent's progress lines in mono,
/// and "Cancel" (when the agent can) beside "Run in background". Finished, it
/// says so and offers "Done"; failed, it shows the error code and "Show
/// details" opens every progress line.
Future<JobSheetExit> showJobSheet(
  BuildContext context, {
  required Job job,
  required Stream<Job> events,
  String? serverName,
  Future<void> Function()? onCancel,
}) async {
  final JobSheetExit? exit = await showAdaptiveModal<JobSheetExit>(
    context,
    dismissible: false,
    builder: (BuildContext context, bool sheet) => JobProgressBody(
      initial: job,
      events: events,
      sheet: sheet,
      serverName: serverName,
      onCancel: onCancel,
    ),
  );
  return exit ?? JobSheetExit.background;
}

/// The body of [showJobSheet], public so the design harness and the tests can
/// pump it with a job of their own.
class JobProgressBody extends StatefulWidget {
  const JobProgressBody({
    super.key,
    required this.initial,
    required this.events,
    required this.sheet,
    this.serverName,
    this.onCancel,
    this.clock,
  });

  final Job initial;
  final Stream<Job> events;
  final bool sheet;
  final String? serverName;
  final Future<void> Function()? onCancel;

  /// Now, for the elapsed time. Tests pass a fixed one.
  final DateTime Function()? clock;

  @override
  State<JobProgressBody> createState() => _JobProgressBodyState();
}

class _JobProgressBodyState extends State<JobProgressBody> {
  late Job _job = widget.initial;
  StreamSubscription<Job>? _subscription;
  Timer? _ticker;
  late final DateTime _opened = _now();
  DateTime? _finishedSeen;
  bool _details = false;
  bool _canceling = false;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _subscription = widget.events.listen(
      (Job job) => setState(() => _job = job),
      onError: (Object error) => setState(() {
        _job = _job.copyWith(
          status: JobStatus.failed,
          error: error is AgentException ? error.message : '$error',
          errorCode: error is AgentException ? error.code : null,
        );
      }),
    );
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_job.status.isFinished) {
        _ticker?.cancel();
        return;
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  Duration get _elapsed {
    final DateTime start = _job.startedAt ?? _opened;
    DateTime end = _now();
    if (_job.status.isFinished) {
      _finishedSeen ??= _job.finishedAt ?? end;
      end = _finishedSeen!;
    }
    final Duration d = end.difference(start);
    return d.isNegative ? Duration.zero : d;
  }

  static String _clock(Duration d) {
    final int minutes = d.inMinutes;
    final int seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _cancel() async {
    final Future<void> Function()? cancel = widget.onCancel;
    if (cancel == null || _canceling) return;
    setState(() => _canceling = true);
    try {
      await cancel();
      if (mounted) Navigator.of(context).pop(JobSheetExit.canceled);
    } on AgentException catch (error) {
      if (!mounted) return;
      setState(() {
        _canceling = false;
        _job = _job.copyWith(error: error.message, errorCode: error.code);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppTokens t = context.tokens;
    final bool sheet = widget.sheet;
    final JobStatus status = _job.status;
    final bool done = status.isFinished;
    final bool ok = status == JobStatus.succeeded;
    final bool failed = done && !ok;
    final String where = widget.serverName == null
        ? ''
        : '${widget.serverName} · ';
    final String subtitle =
        where +
        switch (status) {
          JobStatus.queued => 'Queued on the agent',
          JobStatus.running => 'Running on the agent',
          JobStatus.succeeded => 'Finished',
          JobStatus.canceled => 'Canceled',
          JobStatus.failed => 'Failed',
        };
    final StrokeGlyph glyph = ok
        ? StrokeGlyph.check
        : failed
        ? StrokeGlyph.warning
        : StrokeGlyph.download;
    final double tile = sheet ? 48 : 44;

    final List<String> lines = _job.lines;
    final List<String> shown = _details || lines.length <= 5
        ? lines
        : lines.sublist(lines.length - 5);

    final Widget statusLine = switch ((ok, failed)) {
      (true, _) => Text(
        'Finished without errors',
        style: AppText.tiny.copyWith(
          color: t.accent,
          fontWeight: FontWeight.w600,
        ),
      ),
      (_, true) => Text(
        _job.errorCode ??
            (status == JobStatus.canceled ? 'job_cancelled' : 'failed'),
        style: AppText.monoSmall.copyWith(color: t.danger),
      ),
      _ => Text(
        _job.hasPercent
            ? '${(_job.progress * 100).round()}%'
            : (status == JobStatus.queued ? 'Waiting' : 'Working'),
        style: AppText.tiny.copyWith(color: t.mutedText),
      ),
    };

    final double buttonHeight = sheet ? 54 : 40;
    final double buttonRadius = sheet ? 16 : 10;
    Widget button(
      String label,
      VoidCallback? onPressed, {
      bool primary = false,
      bool busy = false,
    }) => DoomButton(
      label,
      tone: primary ? ButtonTone.primary : ButtonTone.outline,
      expand: sheet,
      busy: busy,
      height: buttonHeight,
      radius: buttonRadius,
      onPressed: onPressed,
    );
    final List<Widget> buttons = <Widget>[
      if (!done) ...<Widget>[
        if (widget.onCancel != null)
          button('Cancel', _cancel, busy: _canceling),
        button(
          'Run in background',
          () => Navigator.of(context).pop(JobSheetExit.background),
          primary: true,
        ),
      ] else ...<Widget>[
        if (failed && !_details && lines.isNotEmpty)
          button('Show details', () => setState(() => _details = true)),
        button(
          'Done',
          () => Navigator.of(context).pop(JobSheetExit.finished),
          primary: true,
        ),
      ],
    ];

    return ModalBody(
      handle: sheet,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              width: tile,
              height: tile,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: failed ? t.dangerTint : t.accentTint,
                borderRadius: BorderRadius.circular(sheet ? 16 : 14),
              ),
              child: StrokeIcon(
                glyph,
                size: sheet ? 22 : 20,
                color: failed ? t.danger : t.accent,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    _job.title,
                    style:
                        (sheet
                                ? AppText.sheetTitle
                                : AppText.sheetTitle.copyWith(fontSize: 22))
                            .copyWith(color: t.text),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
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
            Semantics(
              label: 'Progress',
              value: '${(_job.progress * 100).round()}%',
              child: MeterBar(
                _job.progress,
                color: failed ? t.danger : t.accent,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(child: statusLine),
                Text(
                  '${_clock(_elapsed)} elapsed',
                  style: AppText.monoSmall.copyWith(color: t.mutedText),
                ),
              ],
            ),
          ],
        ),
        if (failed && _job.error != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: t.dangerTint,
              borderRadius: BorderRadius.circular(sheet ? 14 : 12),
              border: Border.all(color: t.dangerBorder),
            ),
            child: Text(
              _job.error!,
              style: AppText.body.copyWith(color: t.text, height: 1.5),
            ),
          ),
        if (!failed || _details)
          Container(
            constraints: BoxConstraints(
              minHeight: 96,
              maxHeight: _details ? 260 : double.infinity,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: t.codeBlock,
              borderRadius: BorderRadius.circular(sheet ? 16 : 12),
              border: Border.all(color: t.faintDivider),
            ),
            child: SingleChildScrollView(
              reverse: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (int i = 0; i < shown.length; i++) ...<Widget>[
                    if (i > 0) const SizedBox(height: 4),
                    SelectableText(
                      shown[i],
                      style: AppText.monoSmall.copyWith(
                        color: t.codeText,
                        height: 1.5,
                      ),
                    ),
                  ],
                  if (shown.isEmpty)
                    Text(
                      'Waiting for the first progress line…',
                      style: AppText.monoSmall.copyWith(
                        color: t.mutedText,
                        height: 1.5,
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (sheet)
          Row(
            children: <Widget>[
              for (int i = 0; i < buttons.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: 10),
                Expanded(child: buttons[i]),
              ],
            ],
          )
        else
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              for (int i = 0; i < buttons.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: 10),
                buttons[i],
              ],
            ],
          ),
      ],
    );
  }
}
