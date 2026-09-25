import 'package:flutter/material.dart';

/// Every colour the design uses, in one place, for both themes.
///
/// Values come straight from the token table in `design/README.md`.
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.ground,
    required this.surface,
    required this.tabBar,
    required this.iconButtonFill,
    required this.codeBlock,
    required this.infoNote,
    required this.text,
    required this.mutedText,
    required this.codeText,
    required this.faintDivider,
    required this.border,
    required this.strongBorder,
    required this.outlineBorder,
    required this.accent,
    required this.onAccent,
    required this.accentTint,
    required this.warning,
    required this.warningTint,
    required this.warningBorder,
    required this.danger,
    required this.dangerTint,
    required this.dangerBorder,
    required this.onDanger,
    required this.info,
    required this.proRed,
    required this.proInk,
    required this.scrim,
  });

  final Color ground;
  final Color surface;
  final Color tabBar;
  final Color iconButtonFill;
  final Color codeBlock;
  final Color infoNote;
  final Color text;
  final Color mutedText;
  final Color codeText;
  final Color faintDivider;
  final Color border;
  final Color strongBorder;
  final Color outlineBorder;
  final Color accent;
  final Color onAccent;
  final Color accentTint;
  final Color warning;
  final Color warningTint;
  final Color warningBorder;
  final Color danger;
  final Color dangerTint;
  final Color dangerBorder;
  final Color onDanger;
  final Color info;

  /// The Pro red and its ink, for the icon, the PRO badge and the lock tile
  /// only. Identical in both themes, and never the danger colours: "Pro" must
  /// not read as "error".
  final Color proRed;
  final Color proInk;

  /// What dims the page under a sheet, a dialog or the palette.
  final Color scrim;

  static const AppTokens dark = AppTokens(
    ground: Color(0xFF0E1417),
    surface: Color(0xFF161E22),
    tabBar: Color(0xFF121A1E),
    iconButtonFill: Color(0xFF1A2429),
    codeBlock: Color(0xFF0A0F11),
    infoNote: Color(0xFF131B1F),
    text: Color(0xFFE8EEF0),
    mutedText: Color(0xFF9AAAB1),
    codeText: Color(0xFFC9D6DB),
    faintDivider: Color(0xFF1E282D),
    border: Color(0xFF243036),
    strongBorder: Color(0xFF2A363C),
    outlineBorder: Color(0xFF3A4A52),
    accent: Color(0xFF5BE3B0),
    onAccent: Color(0xFF0E1417),
    accentTint: Color(0xFF15302A),
    warning: Color(0xFFF2B45A),
    warningTint: Color(0xFF33290F),
    warningBorder: Color(0xFF4A3B17),
    danger: Color(0xFFFF8A7D),
    dangerTint: Color(0xFF3A1C19),
    dangerBorder: Color(0xFF4A2521),
    onDanger: Color(0xFF1A0B09),
    info: Color(0xFF6CB8FF),
    proRed: Color(0xFF9E1B1B),
    proInk: Color(0xFFFAF3E8),
    scrim: Color(0xB8040709),
  );

  static const AppTokens light = AppTokens(
    ground: Color(0xFFF3F5F4),
    surface: Color(0xFFFFFFFF),
    tabBar: Color(0xFFFFFFFF),
    iconButtonFill: Color(0xFFE9EEEC),
    codeBlock: Color(0xFFE9EEEC),
    infoNote: Color(0xFFEAF0EE),
    text: Color(0xFF15201E),
    mutedText: Color(0xFF55656B),
    codeText: Color(0xFF2B3A3F),
    faintDivider: Color(0xFFE4E9E8),
    border: Color(0xFFDCE3E1),
    strongBorder: Color(0xFFCFD8D6),
    outlineBorder: Color(0xFFB5C2BF),
    accent: Color(0xFF0B7A5C),
    onAccent: Color(0xFFFFFFFF),
    accentTint: Color(0xFFD9F2E8),
    warning: Color(0xFF8A5200),
    warningTint: Color(0xFFFBEBC8),
    warningBorder: Color(0xFFE8CF94),
    danger: Color(0xFFB3261E),
    dangerTint: Color(0xFFFCE1DD),
    dangerBorder: Color(0xFFEBB5AE),
    onDanger: Color(0xFFFFFFFF),
    info: Color(0xFF1F5FBF),
    proRed: Color(0xFF9E1B1B),
    proInk: Color(0xFFFAF3E8),
    scrim: Color(0x7315201E),
  );

  @override
  AppTokens copyWith() => this;

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) {
    if (other is! AppTokens) return this;
    return t < 0.5 ? this : other;
  }
}

/// `context.tokens` everywhere instead of a long Theme.of lookup.
extension AppTokensContext on BuildContext {
  AppTokens get tokens => Theme.of(this).extension<AppTokens>()!;
}
