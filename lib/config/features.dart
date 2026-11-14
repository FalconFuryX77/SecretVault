/// Compile-time feature switches.
///
/// Build or test with `--dart-define=GESTURES=false` to switch off the motion
/// module entirely: no gesture unlock, no gesture enrolment, no biometric
/// prompts and no hard-shake panic (the sensors aren't read at all). The vault
/// then opens with the PIN only. Used for automated testing on emulators,
/// where motion and fingerprints can't be driven.
class Features {
  Features._();

  static const bool gestures = bool.fromEnvironment('GESTURES', defaultValue: true);

  /// `--dart-define=SECURE_WINDOW=false` lets automated test runs take
  /// screenshots of vault screens. Never ship a build with this off.
  static const bool secureWindow = bool.fromEnvironment('SECURE_WINDOW', defaultValue: true);
}
