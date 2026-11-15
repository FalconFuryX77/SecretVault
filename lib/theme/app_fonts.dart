import 'package:flutter/material.dart';

/// The app's two typefaces, bundled under `assets/fonts` (SIL Open Font
/// License; see the OFL files there).
///
/// Nothing is fetched at runtime. A vault app must not make network calls,
/// and release builds don't have the internet permission anyway.
///
/// Both are variable fonts, so each style sets the `wght` axis explicitly to
/// match its [FontWeight].
class AppFonts {
  AppFonts._();

  static const String outfitFamily = 'Outfit';
  static const String firaCodeFamily = 'FiraCode';

  static TextStyle outfit({
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
    double? letterSpacing,
    double? height,
  }) =>
      _style(outfitFamily, color, fontSize, fontWeight, letterSpacing, height);

  static TextStyle firaCode({
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
    double? letterSpacing,
    double? height,
  }) =>
      _style(firaCodeFamily, color, fontSize, fontWeight, letterSpacing, height);

  /// Applies Outfit to every style of [base], keeping each style's weight.
  static TextTheme outfitTextTheme(TextTheme base) {
    TextStyle? f(TextStyle? s) => s == null ? null : _withWeight(s.copyWith(fontFamily: outfitFamily));
    return base.copyWith(
      displayLarge: f(base.displayLarge),
      displayMedium: f(base.displayMedium),
      displaySmall: f(base.displaySmall),
      headlineLarge: f(base.headlineLarge),
      headlineMedium: f(base.headlineMedium),
      headlineSmall: f(base.headlineSmall),
      titleLarge: f(base.titleLarge),
      titleMedium: f(base.titleMedium),
      titleSmall: f(base.titleSmall),
      bodyLarge: f(base.bodyLarge),
      bodyMedium: f(base.bodyMedium),
      bodySmall: f(base.bodySmall),
      labelLarge: f(base.labelLarge),
      labelMedium: f(base.labelMedium),
      labelSmall: f(base.labelSmall),
    );
  }

  static TextStyle _style(
    String family,
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
    double? letterSpacing,
    double? height,
  ) =>
      _withWeight(TextStyle(
        fontFamily: family,
        color: color,
        fontSize: fontSize,
        fontWeight: fontWeight ?? FontWeight.w400,
        letterSpacing: letterSpacing,
        height: height,
      ));

  static TextStyle _withWeight(TextStyle s) {
    final w = (s.fontWeight ?? FontWeight.w400).value.toDouble();
    return s.copyWith(fontVariations: [FontVariation('wght', w)]);
  }
}
