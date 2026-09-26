/// The design's own 24×24 stroke icons, painted rather than borrowed.
///
/// The boards draw every navigation icon as inline SVG on a 24×24 viewBox with
/// a 2 px stroke, round caps and round joins. Material's nearest glyphs read
/// wrong — the database cylinder became three bars, the cube became a
/// crosshair — so the paths are transcribed here and painted with a
/// [CustomPainter]. Colour comes from the ambient [IconTheme] unless one is
/// given, and the stroke scales with the icon exactly as the SVG does.
///
/// The same painter also supplies the two text glyphs none of the bundled
/// (subsetted) TTFs carry: `→` and `⌘`. Rendering them as text is what put
/// empty boxes in the port mappings and the Cmd+K hint, so they are drawn
/// instead — in the harness and in the shipped app alike.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The icons the boards draw, by the name the board gives them.
enum StrokeGlyph {
  /// Four outlined rectangles of different sizes.
  overview,

  /// An isometric cube.
  containers,

  /// Stacked plates.
  stacks,

  /// A database cylinder.
  resources,

  /// Two racked units with a status dot each.
  servers,

  /// A bell.
  alerts,

  /// Three sliders.
  settings,

  /// Three log lines, the fleet's Log wall.
  logWall,

  /// The gear that opens Preferences, everywhere it is offered.
  cog,

  /// A sun: the Appearance section.
  sun,

  /// A padlock: the Security section, and the app lock screen.
  lock,

  /// A heartbeat line: the Live data section.
  pulse,

  /// An `i` in a circle: the About section.
  info,

  /// The `→` in a port mapping.
  arrowRight,

  /// The `⌘` in the Cmd+K hint.
  command,

  /// A magnifier: search fields, the jump palette, "nothing matches".
  search,

  /// A tick in a circle: "Nothing needs attention".
  checkCircle,

  /// A tick: a finished job, a resolved alert.
  check,

  /// Three linked nodes: Swarm.
  nodes,

  /// An arrow into a tray: pulling an image, any running job.
  download,

  /// A warning triangle: errors, failed jobs, alert cards.
  warning,

  /// Four equal squares: "All servers".
  fleet,

  /// An arrow out of a door: "Leave demo".
  leave,

  /// A shield: the pair dialog's certificate step.
  shield,

  /// A shield with a tick: the phone's certificate sheet (PairConfirm).
  shieldCheck,

  /// A shield with a cross: the pair error card (PairError).
  shieldX,

  /// An `×`: closing a dialog.
  close,

  /// `‹`: a back link.
  chevronLeft,

  /// `+`: the create buttons.
  plus,

  /// Two overlapping sheets: copy a value or a command.
  copy,

  /// `↑` `↓` `↵` on the jump palette's keycaps (no bundled face has them).
  arrowUp,
  arrowDown,
  returnKey,

  /// Three dots in a column: a row's more button (drawn at stroke 3).
  more,

  /// A right-pointing triangle: start, resume, unpause.
  play,

  /// Two bars: pause a container or a log stream.
  pause,

  /// A rounded square: stop.
  stop,

  /// A bin with a lid: remove.
  trash,

  /// A circular arrow: restart, and "Try again".
  restart,

  /// The restart arrow round a clock's hands: the activity log.
  history,

  /// A clock face: a time range.
  clock,

  /// A prompt and a cursor: the container shell.
  terminal,

  /// A handset: a paired device.
  phone,

  /// A key: this device's key on the agent (the sidebar footer, logins).
  key,

  /// Two chain links: a pairing.
  link,

  /// The chain broken: unpair, revoke.
  unlink,

  /// A stack of three cylinder slices: volumes.
  volumes,

  /// Three nodes hung from one bus: networks.
  networks,

  /// `›`: a row that opens something.
  chevronRight,

  /// `−`: one fewer (a replica stepper).
  minus,

  /// Scissors: prune what is unused.
  prune,

  /// A head and shoulders: a registry username.
  person,

  /// A monitor: "needs a wider window".
  monitor,

  /// A struck-through signal: an agent that cannot be reached.
  offline,

  /// A struck-through bell: a muted alert.
  bellOff,
}

/// One design icon at [size] points, coloured from [IconTheme] by default.
class StrokeIcon extends StatelessWidget {
  const StrokeIcon(
    this.glyph, {
    super.key,
    this.size = 24,
    this.color,
    this.semanticLabel,
  });

  final StrokeGlyph glyph;
  final double size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final Color paint =
        color ?? IconTheme.of(context).color ?? const Color(0xFFE8EEF0);
    // Laid out like [Icon]: a [size] box that, when a parent forces it
    // bigger (a fixed tile without alignment), keeps the glyph centred at
    // [size] rather than stretching it.
    final Widget icon = SizedBox.square(
      dimension: size,
      child: Center(
        child: CustomPaint(
          size: Size.square(size),
          painter: _StrokePainter(glyph: glyph, color: paint),
          isComplex: false,
        ),
      ),
    );
    if (semanticLabel == null) return icon;
    return Semantics(label: semanticLabel, child: icon);
  }
}

/// `→` sized to sit inside a line of [style] text, for a [WidgetSpan].
class ArrowGlyph extends StatelessWidget {
  const ArrowGlyph({super.key, required this.fontSize, this.color});

  final double fontSize;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 1),
    child: StrokeIcon(
      StrokeGlyph.arrowRight,
      size: fontSize * 1.05,
      color: color,
      semanticLabel: 'to',
    ),
  );
}

/// Text that may contain `→`, drawn with the glyph painted rather than typed.
///
/// The bundled faces have no U+2192, so a plain [Text] would show a box in the
/// harness and rely on a system fallback everywhere else.
class GlyphText extends StatelessWidget {
  const GlyphText(
    this.text, {
    super.key,
    required this.style,
    this.textAlign,
    this.maxLines = 1,
    this.overflow = TextOverflow.ellipsis,
  });

  final String text;
  final TextStyle style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow overflow;

  static const String arrow = '→';

  /// True when [text] needs the painter at all.
  static bool needsGlyphs(String text) => text.contains(arrow);

  @override
  Widget build(BuildContext context) {
    if (!needsGlyphs(text)) {
      return Text(
        text,
        style: style,
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow,
      );
    }
    final double fontSize = style.fontSize ?? 14;
    final List<InlineSpan> spans = <InlineSpan>[];
    for (final String part in _split(text)) {
      if (part == arrow) {
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: ArrowGlyph(fontSize: fontSize, color: style.color),
          ),
        );
      } else if (part.isNotEmpty) {
        spans.add(TextSpan(text: part));
      }
    }
    return Text.rich(
      TextSpan(children: spans),
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
    );
  }

  static List<String> _split(String text) {
    final List<String> out = <String>[];
    int start = 0;
    for (int i = 0; i < text.length; i++) {
      if (text[i] == arrow) {
        out.add(text.substring(start, i));
        out.add(arrow);
        start = i + 1;
      }
    }
    out.add(text.substring(start));
    return out;
  }
}

/// True where the operating system's own fonts are certain to carry `⌘`.
bool get platformHasCommandGlyph =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// `⌘K` on a Mac, `Ctrl K` elsewhere — and the command symbol is painted, not
/// typed, because no bundled face has U+2318.
class CommandKeyLabel extends StatelessWidget {
  const CommandKeyLabel({super.key, required this.letter, required this.style});

  /// The letter beside the modifier, `K` for the palette.
  final String letter;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final double fontSize = style.fontSize ?? 11;
    // Off Apple there is no command key to name, and no bundled face carries
    // the symbol, so the shortcut is spelled out instead.
    if (!platformHasCommandGlyph) return Text('Ctrl $letter', style: style);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        StrokeIcon(
          StrokeGlyph.command,
          size: fontSize * 1.15,
          color: style.color,
          semanticLabel: 'Command',
        ),
        const SizedBox(width: 1),
        Text(letter, style: style),
      ],
    );
  }
}

class _StrokePainter extends CustomPainter {
  const _StrokePainter({required this.glyph, required this.color});

  final StrokeGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double scale = size.shortestSide / 24;
    canvas.save();
    canvas.scale(scale);
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      // The more button's dots are drawn at 3, as every board draws them.
      ..strokeWidth = glyph == StrokeGlyph.more ? 3 : 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color
      ..isAntiAlias = true;
    canvas.drawPath(_path(glyph), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StrokePainter old) =>
      old.glyph != glyph || old.color != color;

  static Path _path(StrokeGlyph glyph) => switch (glyph) {
    StrokeGlyph.overview => _overview(),
    StrokeGlyph.containers => _containers(),
    StrokeGlyph.stacks => _stacks(),
    StrokeGlyph.resources => _resources(),
    StrokeGlyph.servers => _servers(),
    StrokeGlyph.alerts => _alerts(),
    StrokeGlyph.settings => _settings(),
    StrokeGlyph.logWall => _logWall(),
    StrokeGlyph.cog => _cog(),
    StrokeGlyph.sun => _sun(),
    StrokeGlyph.lock => _lock(),
    StrokeGlyph.pulse => _pulse(),
    StrokeGlyph.info => _info(),
    StrokeGlyph.arrowRight => _arrowRight(),
    StrokeGlyph.command => _command(),
    StrokeGlyph.search => _search(),
    StrokeGlyph.checkCircle => _checkCircle(),
    StrokeGlyph.check => _check(),
    StrokeGlyph.nodes => _nodes(),
    StrokeGlyph.download => _download(),
    StrokeGlyph.warning => _warning(),
    StrokeGlyph.fleet => _fleet(),
    StrokeGlyph.leave => _leave(),
    StrokeGlyph.shield => _shield(),
    StrokeGlyph.shieldCheck =>
      _shield()
        ..moveTo(9, 12)
        ..lineTo(11, 14)
        ..lineTo(15, 10),
    StrokeGlyph.shieldX =>
      _shield()
        ..moveTo(9.5, 9.5)
        ..lineTo(14.5, 14.5)
        ..moveTo(14.5, 9.5)
        ..lineTo(9.5, 14.5),
    StrokeGlyph.close => _close(),
    StrokeGlyph.chevronLeft => _chevronLeft(),
    StrokeGlyph.plus => _plus(),
    StrokeGlyph.copy => _copy(),
    StrokeGlyph.arrowUp => _arrowUp(),
    StrokeGlyph.arrowDown => _arrowDown(),
    StrokeGlyph.returnKey => _returnKey(),
    StrokeGlyph.more => _more(),
    StrokeGlyph.play => _play(),
    StrokeGlyph.pause => _pause(),
    StrokeGlyph.stop => Path()..addRRect(_r(5, 5, 14, 14, 2)),
    StrokeGlyph.trash => _trash(),
    StrokeGlyph.restart => _restart(),
    StrokeGlyph.history =>
      _restart()
        ..moveTo(12, 8)
        ..lineTo(12, 12)
        ..lineTo(15, 14),
    StrokeGlyph.clock =>
      Path()
        ..addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 9))
        ..moveTo(12, 7)
        ..lineTo(12, 12)
        ..lineTo(15, 14),
    StrokeGlyph.terminal => _terminal(),
    StrokeGlyph.phone => _phone(),
    StrokeGlyph.key => _key(),
    StrokeGlyph.link => _link(),
    StrokeGlyph.unlink => _unlink(),
    StrokeGlyph.volumes => _volumes(),
    StrokeGlyph.networks => _networks(),
    StrokeGlyph.chevronRight => _chevronRight(),
    StrokeGlyph.minus =>
      Path()
        ..moveTo(5, 12)
        ..lineTo(19, 12),
    StrokeGlyph.prune => _prune(),
    StrokeGlyph.person => _person(),
    StrokeGlyph.monitor => _monitor(),
    StrokeGlyph.offline => _offline(),
    StrokeGlyph.bellOff =>
      _alerts()
        ..moveTo(3, 3)
        ..lineTo(21, 21),
  };

  // M12 5h.01M12 12h.01M12 19h.01 (stroke-width 3)
  static Path _more() => Path()
    ..moveTo(12, 5)
    ..lineTo(12.01, 5)
    ..moveTo(12, 12)
    ..lineTo(12.01, 12)
    ..moveTo(12, 19)
    ..lineTo(12.01, 19);

  // M6 4l14 8-14 8z
  static Path _play() => Path()
    ..moveTo(6, 4)
    ..lineTo(20, 12)
    ..lineTo(6, 20)
    ..close();

  // M8 5v14M16 5v14
  static Path _pause() => Path()
    ..moveTo(8, 5)
    ..lineTo(8, 19)
    ..moveTo(16, 5)
    ..lineTo(16, 19);

  // M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14
  static Path _trash() => Path()
    ..moveTo(3, 6)
    ..lineTo(21, 6)
    ..moveTo(8, 6)
    ..lineTo(8, 4)
    ..lineTo(16, 4)
    ..lineTo(16, 6)
    ..moveTo(6, 6)
    ..lineTo(7, 20)
    ..lineTo(17, 20)
    ..lineTo(18, 6);

  // M3 12a9 9 0 1 0 3-6.7 M3 4v5h5
  static Path _restart() => Path()
    ..moveTo(3, 12)
    ..arcToPoint(
      const Offset(6, 5.3),
      radius: const Radius.circular(9),
      largeArc: true,
      clockwise: false,
    )
    ..moveTo(3, 4)
    ..lineTo(3, 9)
    ..lineTo(8, 9);

  // M4 17l6-5-6-5M12 19h8
  static Path _terminal() => Path()
    ..moveTo(4, 17)
    ..lineTo(10, 12)
    ..lineTo(4, 7)
    ..moveTo(12, 19)
    ..lineTo(20, 19);

  // <rect 7 3 10 18 rx2> M11 18h2
  static Path _phone() => Path()
    ..addRRect(_r(7, 3, 10, 18, 2))
    ..moveTo(11, 18)
    ..lineTo(13, 18);

  // <circle 8 15 r4> M11 12l9-9M16 7l3 3
  static Path _key() => Path()
    ..addOval(Rect.fromCircle(center: const Offset(8, 15), radius: 4))
    ..moveTo(11, 12)
    ..lineTo(20, 3)
    ..moveTo(16, 7)
    ..lineTo(19, 10);

  // M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71
  // M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71
  static Path _link() {
    final _Pen a = _Pen(10, 13)
      ..arc(7.54, 0.54, clockwise: false, radius: 5)
      ..line(3, -3)
      ..arc(-7.07, -7.07, clockwise: false, radius: 5)
      ..line(-1.72, 1.71);
    final _Pen b = _Pen(14, 11)
      ..arc(-7.54, -0.54, clockwise: false, radius: 5)
      ..line(-3, 3)
      ..arc(7.07, 7.07, clockwise: false, radius: 5)
      ..line(1.71, -1.71);
    return a.path..addPath(b.path, Offset.zero);
  }

  // The two outer halves of [_link] with a gap between them, and four
  // short strokes where the links parted.
  static Path _unlink() {
    final _Pen a = _Pen(18.84, 12.25)
      ..line(1.72, -1.71)
      ..arc(-0.12, -7.07, clockwise: false, radius: 5)
      ..arc(-6.95, 0, clockwise: false, radius: 5)
      ..line(-1.72, 1.71);
    final _Pen b = _Pen(5.17, 11.75)
      ..line(-1.71, 1.71)
      ..arc(0.12, 7.07, clockwise: false, radius: 5)
      ..arc(6.95, 0, clockwise: false, radius: 5)
      ..line(1.71, -1.71);
    return a.path
      ..addPath(b.path, Offset.zero)
      ..moveTo(8, 2)
      ..lineTo(8, 5)
      ..moveTo(2, 8)
      ..lineTo(5, 8)
      ..moveTo(16, 22)
      ..lineTo(16, 19)
      ..moveTo(22, 16)
      ..lineTo(19, 16);
  }

  // <ellipse 12 5 rx8 ry2.5>, walls to y 19 and two bands between: the
  // Resources cylinder cut into three slices.
  static Path _volumes() {
    final Path path = Path()
      ..addOval(
        Rect.fromCenter(center: const Offset(12, 5), width: 16, height: 5),
      )
      ..moveTo(4, 5)
      ..lineTo(4, 19)
      ..moveTo(20, 5)
      ..lineTo(20, 19);
    for (final double y in <double>[9.7, 14.3, 19]) {
      path
        ..moveTo(4, y)
        ..cubicTo(4, y + 1.4, 7.6, y + 2.5, 12, y + 2.5)
        ..cubicTo(16.4, y + 2.5, 20, y + 1.4, 20, y);
    }
    return path;
  }

  // <rect 9 3 6 5 rx1.5> <rect 2 16 6 5> <rect 16 16 6 5>
  // M12 8v4 M5 16v-4h14v4
  static Path _networks() => Path()
    ..addRRect(_r(9, 3, 6, 5, 1.5))
    ..addRRect(_r(2, 16, 6, 5, 1.5))
    ..addRRect(_r(16, 16, 6, 5, 1.5))
    ..moveTo(12, 8)
    ..lineTo(12, 12)
    ..moveTo(5, 16)
    ..lineTo(5, 12)
    ..lineTo(19, 12)
    ..lineTo(19, 16);

  // M9 18l6-6-6-6
  static Path _chevronRight() => Path()
    ..moveTo(9, 18)
    ..lineTo(15, 12)
    ..lineTo(9, 6);

  // <circle 6 6 r3> <circle 6 18 r3> M20 4L8.12 15.88 M14.47 14.48L20 20
  // M8.12 8.12L12 12
  static Path _prune() => Path()
    ..addOval(Rect.fromCircle(center: const Offset(6, 6), radius: 3))
    ..addOval(Rect.fromCircle(center: const Offset(6, 18), radius: 3))
    ..moveTo(20, 4)
    ..lineTo(8.12, 15.88)
    ..moveTo(14.47, 14.48)
    ..lineTo(20, 20)
    ..moveTo(8.12, 8.12)
    ..lineTo(12, 12);

  // <circle 12 8 r4> M4 21a8 8 0 0 1 16 0
  static Path _person() => Path()
    ..addOval(Rect.fromCircle(center: const Offset(12, 8), radius: 4))
    ..moveTo(4, 21)
    ..arcToPoint(
      const Offset(20, 21),
      radius: const Radius.circular(8),
      clockwise: true,
    );

  // <rect 3 4 18 12 rx2> M8 20h8 M12 16v4
  static Path _monitor() => Path()
    ..addRRect(_r(3, 4, 18, 12, 2))
    ..moveTo(8, 20)
    ..lineTo(16, 20)
    ..moveTo(12, 16)
    ..lineTo(12, 20);

  // M12 20h.01 M8.5 16.5a5 5 0 0 1 7 0 M5 13a10 10 0 0 1 14 0 M3 3l18 18
  static Path _offline() => Path()
    ..moveTo(12, 20)
    ..lineTo(12.01, 20)
    ..moveTo(8.5, 16.5)
    ..arcToPoint(
      const Offset(15.5, 16.5),
      radius: const Radius.circular(5),
      clockwise: true,
    )
    ..moveTo(5, 13)
    ..arcToPoint(
      const Offset(19, 13),
      radius: const Radius.circular(10),
      clockwise: true,
    )
    ..moveTo(3, 3)
    ..lineTo(21, 21);

  // <circle 11 11 r7> M21 21l-4.3-4.3
  static Path _search() => Path()
    ..addOval(Rect.fromCircle(center: const Offset(11, 11), radius: 7))
    ..moveTo(21, 21)
    ..lineTo(16.7, 16.7);

  // <circle 12 12 r9> M8 12.5l2.5 2.5L16 9.5
  static Path _checkCircle() => Path()
    ..addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 9))
    ..moveTo(8, 12.5)
    ..lineTo(10.5, 15)
    ..lineTo(16, 9.5);

  // three r2.5 circles, M10.8 7.2L6.2 15.8 M13.2 7.2l4.6 8.6 M7.5 18h9
  static Path _nodes() => Path()
    ..addOval(Rect.fromCircle(center: const Offset(12, 5), radius: 2.5))
    ..addOval(Rect.fromCircle(center: const Offset(5, 18), radius: 2.5))
    ..addOval(Rect.fromCircle(center: const Offset(19, 18), radius: 2.5))
    ..moveTo(10.8, 7.2)
    ..lineTo(6.2, 15.8)
    ..moveTo(13.2, 7.2)
    ..lineTo(17.8, 15.8)
    ..moveTo(7.5, 18)
    ..lineTo(16.5, 18);

  // M12 4v11 M7 10l5 5 5-5 M5 20h14
  static Path _download() => Path()
    ..moveTo(12, 4)
    ..lineTo(12, 15)
    ..moveTo(7, 10)
    ..lineTo(12, 15)
    ..lineTo(17, 10)
    ..moveTo(5, 20)
    ..lineTo(19, 20);

  // M12 19V5 M6 11l6-6 6 6
  static Path _arrowUp() => Path()
    ..moveTo(12, 19)
    ..lineTo(12, 5)
    ..moveTo(6, 11)
    ..lineTo(12, 5)
    ..lineTo(18, 11);

  // M12 5v14 M6 13l6 6 6-6
  static Path _arrowDown() => Path()
    ..moveTo(12, 5)
    ..lineTo(12, 19)
    ..moveTo(6, 13)
    ..lineTo(12, 19)
    ..lineTo(18, 13);

  // M9 10l-4 4 4 4 M5 14h11a3 3 0 0 0 3-3V5
  static Path _returnKey() => Path()
    ..moveTo(9, 10)
    ..lineTo(5, 14)
    ..lineTo(9, 18)
    ..moveTo(5, 14)
    ..lineTo(16, 14)
    ..arcToPoint(
      const Offset(19, 11),
      radius: const Radius.circular(3),
      clockwise: false,
    )
    ..lineTo(19, 5);

  // M12 4l9 16H3z M12 10v4 M12 17.5h.01
  static Path _warning() => Path()
    ..moveTo(12, 4)
    ..lineTo(21, 20)
    ..lineTo(3, 20)
    ..close()
    ..moveTo(12, 10)
    ..lineTo(12, 14)
    ..moveTo(12, 17.5)
    ..lineTo(12.01, 17.5);

  // four <rect w8 h8 rx1.5>
  static Path _fleet() => Path()
    ..addRRect(_r(3, 3, 8, 8, 1.5))
    ..addRRect(_r(13, 3, 8, 8, 1.5))
    ..addRRect(_r(3, 13, 8, 8, 1.5))
    ..addRRect(_r(13, 13, 8, 8, 1.5));

  // M15 4h3a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-3 M10 16l-4-4 4-4 M6 12h10
  static Path _leave() => Path()
    ..moveTo(15, 4)
    ..lineTo(18, 4)
    ..arcToPoint(const Offset(20, 6), radius: const Radius.circular(2))
    ..lineTo(20, 18)
    ..arcToPoint(const Offset(18, 20), radius: const Radius.circular(2))
    ..lineTo(15, 20)
    ..moveTo(10, 16)
    ..lineTo(6, 12)
    ..lineTo(10, 8)
    ..moveTo(6, 12)
    ..lineTo(16, 12);

  // M5 12l5 5 9-10
  static Path _check() => Path()
    ..moveTo(5, 12)
    ..lineTo(10, 17)
    ..lineTo(19, 7);

  // M12 3l8 3v6c0 4.5-3.2 8-8 9-4.8-1-8-4.5-8-9V6z
  static Path _shield() => Path()
    ..moveTo(12, 3)
    ..lineTo(20, 6)
    ..lineTo(20, 12)
    ..cubicTo(20, 16.5, 16.8, 20, 12, 21)
    ..cubicTo(7.2, 20, 4, 16.5, 4, 12)
    ..lineTo(4, 6)
    ..close();

  // M6 6l12 12 M18 6L6 18
  static Path _close() => Path()
    ..moveTo(6, 6)
    ..lineTo(18, 18)
    ..moveTo(18, 6)
    ..lineTo(6, 18);

  // M15 18l-6-6 6-6
  static Path _chevronLeft() => Path()
    ..moveTo(15, 18)
    ..lineTo(9, 12)
    ..lineTo(15, 6);

  // <rect x9 y9 w11 h11 rx2> M5 15V6a2 2 0 0 1 2-2h9
  static Path _copy() => Path()
    ..addRRect(_r(9, 9, 11, 11, 2))
    ..moveTo(5, 15)
    ..lineTo(5, 6)
    ..arcToPoint(const Offset(7, 4), radius: const Radius.circular(2))
    ..lineTo(16, 4);

  // M12 5v14 M5 12h14
  static Path _plus() => Path()
    ..moveTo(12, 5)
    ..lineTo(12, 19)
    ..moveTo(5, 12)
    ..lineTo(19, 12);

  // <rect x y w h rx=1.5> ×4
  static Path _overview() => Path()
    ..addRRect(_r(3, 3, 7, 9, 1.5))
    ..addRRect(_r(14, 3, 7, 5, 1.5))
    ..addRRect(_r(14, 12, 7, 9, 1.5))
    ..addRRect(_r(3, 16, 7, 5, 1.5));

  // M21 8l-9-5-9 5v8l9 5 9-5z  M3 8l9 5 9-5  M12 13v8
  static Path _containers() => Path()
    ..moveTo(21, 8)
    ..lineTo(12, 3)
    ..lineTo(3, 8)
    ..lineTo(3, 16)
    ..lineTo(12, 21)
    ..lineTo(21, 16)
    ..close()
    ..moveTo(3, 8)
    ..lineTo(12, 13)
    ..lineTo(21, 8)
    ..moveTo(12, 13)
    ..lineTo(12, 21);

  // M12 3l9 5-9 5-9-5z  M3 13l9 5 9-5
  static Path _stacks() => Path()
    ..moveTo(12, 3)
    ..lineTo(21, 8)
    ..lineTo(12, 13)
    ..lineTo(3, 8)
    ..close()
    ..moveTo(3, 13)
    ..lineTo(12, 18)
    ..lineTo(21, 13);

  // <ellipse cx=12 cy=6 rx=8 ry=3>
  // M4 6v12c0 1.7 3.6 3 8 3s8-1.3 8-3V6
  // M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3
  static Path _resources() => Path()
    ..addOval(
      Rect.fromCenter(center: const Offset(12, 6), width: 16, height: 6),
    )
    ..moveTo(4, 6)
    ..lineTo(4, 18)
    ..cubicTo(4, 19.7, 7.6, 21, 12, 21)
    ..cubicTo(16.4, 21, 20, 19.7, 20, 18)
    ..lineTo(20, 6)
    ..moveTo(4, 12)
    ..cubicTo(4, 13.7, 7.6, 15, 12, 15)
    ..cubicTo(16.4, 15, 20, 13.7, 20, 12);

  // <rect 3 4 18 7 rx2> <rect 3 13 18 7 rx2> M7 7.5h.01 M7 16.5h.01
  static Path _servers() => Path()
    ..addRRect(_r(3, 4, 18, 7, 2))
    ..addRRect(_r(3, 13, 18, 7, 2))
    ..moveTo(7, 7.5)
    ..lineTo(7.01, 7.5)
    ..moveTo(7, 16.5)
    ..lineTo(7.01, 16.5);

  // M6 9a6 6 0 0 1 12 0c0 6 2 7 2 7H4s2-1 2-7  M10 20a2 2 0 0 0 4 0
  static Path _alerts() => Path()
    ..moveTo(6, 9)
    ..arcToPoint(
      const Offset(18, 9),
      radius: const Radius.circular(6),
      clockwise: true,
    )
    ..cubicTo(18, 15, 20, 16, 20, 16)
    ..lineTo(4, 16)
    ..cubicTo(4, 16, 6, 15, 6, 9)
    ..moveTo(10, 20)
    ..arcToPoint(
      const Offset(14, 20),
      radius: const Radius.circular(2),
      clockwise: false,
    );

  // M4 6h10 M18 6h2 M4 12h4 M12 12h8 M4 18h12 + three knobs
  static Path _settings() => Path()
    ..moveTo(4, 6)
    ..lineTo(14, 6)
    ..moveTo(18, 6)
    ..lineTo(20, 6)
    ..moveTo(4, 12)
    ..lineTo(8, 12)
    ..moveTo(12, 12)
    ..lineTo(20, 12)
    ..moveTo(4, 18)
    ..lineTo(16, 18)
    ..addOval(Rect.fromCircle(center: const Offset(16, 6), radius: 2))
    ..addOval(Rect.fromCircle(center: const Offset(10, 12), radius: 2))
    ..addOval(Rect.fromCircle(center: const Offset(18, 18), radius: 2));

  // M5 6h14 M5 12h14 M5 18h9
  static Path _logWall() => Path()
    ..moveTo(5, 6)
    ..lineTo(19, 6)
    ..moveTo(5, 12)
    ..lineTo(19, 12)
    ..moveTo(5, 18)
    ..lineTo(14, 18);

  /// The Preferences gear, transcribed from the `d` attribute the Main,
  /// DesktopOverview and DesktopTablet boards all draw it with: twelve
  /// rounded teeth built from `a2 2 0 0 …` arcs, and a circle in the middle.
  static Path _cog() {
    final _Pen p = _Pen(12.22, 2)
      ..h(-0.44)
      ..arc(-2, 2, clockwise: false)
      ..dy(0.18)
      ..arc(-1, 1.73, clockwise: true)
      ..line(-0.43, 0.25)
      ..arc(-2, 0, clockwise: true)
      ..line(-0.15, -0.08)
      ..arc(-2.73, 0.73, clockwise: false)
      ..line(-0.22, 0.38)
      ..arc(0.73, 2.73, clockwise: false)
      ..line(0.15, 0.1)
      ..arc(1, 1.72, clockwise: true)
      ..dy(0.51)
      ..arc(-1, 1.74, clockwise: true)
      ..line(-0.15, 0.09)
      ..arc(-0.73, 2.73, clockwise: false)
      ..line(0.22, 0.38)
      ..arc(2.73, 0.73, clockwise: false)
      ..line(0.15, -0.08)
      ..arc(2, 0, clockwise: true)
      ..line(0.43, 0.25)
      ..arc(1, 1.73, clockwise: true)
      ..toY(20)
      ..arc(2, 2, clockwise: false)
      ..h(0.44)
      ..arc(2, -2, clockwise: false)
      ..dy(-0.18)
      ..arc(1, -1.73, clockwise: true)
      ..line(0.43, -0.25)
      ..arc(2, 0, clockwise: true)
      ..line(0.15, 0.08)
      ..arc(2.73, -0.73, clockwise: false)
      ..line(0.22, -0.39)
      ..arc(-0.73, -2.73, clockwise: false)
      ..line(-0.15, -0.08)
      ..arc(-1, -1.74, clockwise: true)
      ..dy(-0.5)
      ..arc(1, -1.74, clockwise: true)
      ..line(0.15, -0.09)
      ..arc(0.73, -2.73, clockwise: false)
      ..line(-0.22, -0.38)
      ..arc(-2.73, -0.73, clockwise: false)
      ..line(-0.15, 0.08)
      ..arc(-2, 0, clockwise: true)
      ..line(-0.43, -0.25)
      ..arc(-1, -1.73, clockwise: true)
      ..toY(4)
      ..arc(-2, -2, clockwise: false)
      ..shut();
    return p.path
      ..addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 3));
  }

  // <circle 12 12 r4> + eight rays
  static Path _sun() {
    final Path path = Path()
      ..addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 4));
    const List<(double, double, double, double)> rays =
        <(double, double, double, double)>[
          (12, 3, 12, 5),
          (12, 19, 12, 21),
          (3, 12, 5, 12),
          (19, 12, 21, 12),
          (5.6, 5.6, 7, 7),
          (17, 17, 18.4, 18.4),
          (18.4, 5.6, 17, 7),
          (7, 17, 5.6, 18.4),
        ];
    for (final (double x1, double y1, double x2, double y2) in rays) {
      path
        ..moveTo(x1, y1)
        ..lineTo(x2, y2);
    }
    return path;
  }

  // <rect 5 11 14 9 rx2> M8 11V8a4 4 0 0 1 8 0v3
  static Path _lock() => Path()
    ..addRRect(_r(5, 11, 14, 9, 2))
    ..moveTo(8, 11)
    ..lineTo(8, 8)
    ..arcToPoint(
      const Offset(16, 8),
      radius: const Radius.circular(4),
      clockwise: true,
    )
    ..lineTo(16, 11);

  // M3 12h4l3-8 4 16 3-8h4
  static Path _pulse() => Path()
    ..moveTo(3, 12)
    ..lineTo(7, 12)
    ..lineTo(10, 4)
    ..lineTo(14, 20)
    ..lineTo(17, 12)
    ..lineTo(21, 12);

  // <circle 12 12 r9> M12 11v5 M12 8h.01
  static Path _info() => Path()
    ..addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 9))
    ..moveTo(12, 11)
    ..lineTo(12, 16)
    ..moveTo(12, 8)
    ..lineTo(12.01, 8);

  /// A plain right arrow on the same 24×24 grid as the rest.
  static Path _arrowRight() => Path()
    ..moveTo(3, 12)
    ..lineTo(21, 12)
    ..moveTo(14, 5)
    ..lineTo(21, 12)
    ..lineTo(14, 19);

  /// The looped square of U+2318: an 8×8 centre with a loop through each of
  /// its corners.
  static Path _command() {
    final Path path = Path()..addRect(const Rect.fromLTWH(8, 8, 8, 8));
    const double r = 3.54; // reaches the square's corner from 2.5 px outside
    for (final (double x, double y) in <(double, double)>[
      (5.5, 5.5),
      (18.5, 5.5),
      (5.5, 18.5),
      (18.5, 18.5),
    ]) {
      path.addOval(Rect.fromCircle(center: Offset(x, y), radius: r));
    }
    return path;
  }

  static RRect _r(double x, double y, double w, double h, double r) =>
      RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(r));
}

/// A pen that follows SVG path data, so a long `d` attribute can be copied
/// across command by command.
///
/// [Path] has relative moves but never tells you where the pen is, which the
/// cog's absolute `V20` and `V4` need. This keeps the current point, so both
/// the relative commands and the absolute ones read like the markup.
class _Pen {
  _Pen(this.x, this.y) {
    path.moveTo(x, y);
  }

  final Path path = Path();
  double x;
  double y;

  /// `h dx`
  void h(double dx) {
    x += dx;
    path.lineTo(x, y);
  }

  /// `v dy`
  void dy(double value) {
    y += value;
    path.lineTo(x, y);
  }

  /// `V y`
  void toY(double value) {
    y = value;
    path.lineTo(x, y);
  }

  /// `l dx dy`
  void line(double dx, double dyValue) {
    x += dx;
    y += dyValue;
    path.lineTo(x, y);
  }

  /// `a r r 0 0 sweep dx dy` — [clockwise] is the SVG sweep flag, which means
  /// the same thing in Flutter's y-down space.
  void arc(
    double dx,
    double dyValue, {
    required bool clockwise,
    double radius = 2,
  }) {
    x += dx;
    y += dyValue;
    path.arcToPoint(
      Offset(x, y),
      radius: Radius.circular(radius),
      clockwise: clockwise,
    );
  }

  /// `z`
  void shut() => path.close();
}
