import 'package:flutter/material.dart';

/// The app's typefaces.
///
/// Text uses the system typeface (Roboto on Android), so the app reads as
/// a native Android app rather than a template. Numbers and other data
/// (sizes, dates, codes, timers) use Fira Code, bundled under
/// `assets/fonts` (SIL Open Font License). Nothing is fetched at runtime:
/// a vault app must not make network calls.
class AppFonts {
  AppFonts._();

  static const String firaCodeFamily = 'FiraCode';

  /// The system typeface.
  static TextStyle ui({
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
    double? letterSpacing,
    double? height,
  }) =>
      TextStyle(
        color: color,
        fontSize: fontSize,
        fontWeight: fontWeight ?? FontWeight.w400,
        letterSpacing: letterSpacing,
        height: height,
      );

  static TextStyle firaCode({
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
    double? letterSpacing,
    double? height,
  }) =>
      _withWeight(TextStyle(
        fontFamily: firaCodeFamily,
        color: color,
        fontSize: fontSize,
        fontWeight: fontWeight ?? FontWeight.w400,
        letterSpacing: letterSpacing,
        height: height,
      ));

  /// The system typeface for every style of [base] (Material's default).
  static TextTheme uiTextTheme(TextTheme base) => base;

  /// Fira Code is a variable font: set its weight axis to match.
  static TextStyle _withWeight(TextStyle s) {
    final w = (s.fontWeight ?? FontWeight.w400).value.toDouble();
    return s.copyWith(fontVariations: [FontVariation('wght', w)]);
  }
}
