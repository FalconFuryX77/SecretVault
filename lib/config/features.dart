/// Compile-time switches.
class Features {
  Features._();

  /// `--dart-define=SECURE_WINDOW=false` lets automated test runs take
  /// screenshots of vault screens. Never ship a build with this off.
  static const bool secureWindow = bool.fromEnvironment('SECURE_WINDOW', defaultValue: true);
}
