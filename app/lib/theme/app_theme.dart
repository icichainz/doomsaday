import 'package:flutter/material.dart';

import 'tokens.dart';

/// Font families bundled in `assets/fonts`.
abstract final class AppFonts {
  static const String display = 'Bricolage Grotesque';
  static const String sans = 'IBM Plex Sans';
  static const String mono = 'IBM Plex Mono';
}

/// Radii and spacing constants the design repeats.
abstract final class AppShape {
  static const double screenPadding = 20;
  static const double card = 20;
  static const double smallCard = 16;
  static const double button = 14;
  static const double touchTarget = 44;

  static const BorderRadius cardRadius = BorderRadius.all(
    Radius.circular(card),
  );
  static const BorderRadius smallCardRadius = BorderRadius.all(
    Radius.circular(smallCard),
  );
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));
}

/// Text styles used across screens. Sizes match the design markup.
abstract final class AppText {
  static const TextStyle screenTitle = TextStyle(
    fontFamily: AppFonts.display,
    fontSize: 30,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    height: 1.1,
  );
  static const TextStyle screenTitleLarge = TextStyle(
    fontFamily: AppFonts.display,
    fontSize: 32,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    height: 1.1,
  );
  static const TextStyle sheetTitle = TextStyle(
    fontFamily: AppFonts.display,
    fontSize: 24,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
  );
  static const TextStyle figure = TextStyle(
    fontFamily: AppFonts.display,
    fontSize: 28,
    fontWeight: FontWeight.w700,
    height: 1,
  );
  static const TextStyle figureSmall = TextStyle(
    fontFamily: AppFonts.display,
    fontSize: 22,
    fontWeight: FontWeight.w700,
    height: 1,
  );
  static const TextStyle cardTitle = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle rowTitle = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle body = TextStyle(fontSize: 14, height: 1.45);
  static const TextStyle label = TextStyle(fontSize: 14);
  static const TextStyle small = TextStyle(fontSize: 13);
  static const TextStyle tiny = TextStyle(fontSize: 12);
  static const TextStyle pill = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle buttonLabel = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle sectionHeader = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.6,
  );
  static const TextStyle mono = TextStyle(
    fontFamily: AppFonts.mono,
    fontSize: 13,
    fontWeight: FontWeight.w500,
  );
  static const TextStyle monoSmall = TextStyle(
    fontFamily: AppFonts.mono,
    fontSize: 12,
  );
  static const TextStyle logLine = TextStyle(
    fontFamily: AppFonts.mono,
    fontSize: 11.5,
    height: 1.45,
  );
}

abstract final class AppTheme {
  static ThemeData dark() => _build(AppTokens.dark, Brightness.dark);

  static ThemeData light() => _build(AppTokens.light, Brightness.light);

  static ThemeData _build(AppTokens t, Brightness brightness) {
    final base = ThemeData(brightness: brightness, useMaterial3: true);
    return base.copyWith(
      extensions: <ThemeExtension<dynamic>>[t],
      scaffoldBackgroundColor: t.ground,
      canvasColor: t.ground,
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: t.accent,
            brightness: brightness,
          ).copyWith(
            surface: t.surface,
            primary: t.accent,
            onPrimary: t.onAccent,
            error: t.danger,
            onError: t.onDanger,
          ),
      dividerColor: t.border,
      splashFactory: InkSparkle.splashFactory,
      textTheme: base.textTheme.apply(
        fontFamily: AppFonts.sans,
        bodyColor: t.text,
        displayColor: t.text,
      ),
      iconTheme: IconThemeData(color: t.text, size: 20),
      textSelectionTheme: TextSelectionThemeData(cursorColor: t.accent),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: t.surface,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: const Color(0xB8040709),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: t.surface,
        contentTextStyle: TextStyle(color: t.text, fontFamily: AppFonts.sans),
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(
          borderRadius: AppShape.smallCardRadius,
        ),
      ),
    );
  }
}
