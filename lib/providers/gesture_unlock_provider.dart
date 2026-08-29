import 'dart:async';
import 'package:flutter/material.dart';
import 'package:vibration/vibration.dart';
import 'package:local_auth/local_auth.dart';
import '../models/gesture.dart';
import '../services/gesture_detector.dart';
import '../services/auth_service.dart';
import '../services/encryption_service.dart';

class GestureUnlockProvider extends ChangeNotifier {
  final GestureDetectorService _detector;
  final AuthService _authService;
  final EncryptionService _encryptionService;
  final LocalAuthentication _localAuth;

  UnlockState state = UnlockState.locked;
  List<Gesture> inputTrail = [];
  bool _isSetupComplete = false;
  bool get isSetupComplete => _isSetupComplete;

  bool _isBiometricVerified = false;
  bool get isBiometricVerified => _isBiometricVerified;

  bool _isAuthenticatingBiometrics = false;
  bool get isAuthenticatingBiometrics => _isAuthenticatingBiometrics;

  StreamSubscription? _gestureSub;
  Timer? _trailResetTimer;

  /// Number of gestures required for a pattern.
  static const int patternLength = 4;

  // ─── Lockout state ────────────────────────────────────
  static const int maxFailedAttempts = 5;
  static const int lockoutDurationSeconds = 30;

  int _failedAttempts = 0;
  int get failedAttempts => _failedAttempts;

  int _lockoutRemaining = 0;
  int get lockoutRemaining => _lockoutRemaining;
  Timer? _lockoutTimer;

  // ─── Inactivity state ─────────────────────────────────
  bool _autoLockOnSwitch = true;
  bool get autoLockOnSwitch => _autoLockOnSwitch;

  int _inactivityTimeoutSeconds = 30;
  int get inactivityTimeoutSeconds => _inactivityTimeoutSeconds;
  Timer? _inactivityTimer;

  GestureUnlockProvider({
    GestureDetectorService? detector,
    AuthService? authService,
    EncryptionService? encryptionService,
    LocalAuthentication? localAuth,
  })  : _detector = detector ?? GestureDetectorService(),
        _authService = authService ?? AuthService(),
        _encryptionService = encryptionService ?? EncryptionService(),
        _localAuth = localAuth ?? LocalAuthentication() {
    _init();
  }

  Future<void> _init() async {
    _isSetupComplete = await _authService.isSetupComplete();

    // Load settings
    _autoLockOnSwitch = await _authService.getAutoLockOnSwitch();
    _inactivityTimeoutSeconds = await _authService.getInactivityTimeout();

    // Check for persisted lockout
    _failedAttempts = await _authService.getFailedAttempts();
    final lockoutEnd = await _authService.getLockoutEndTime();
    if (lockoutEnd != null) {
      final remaining = lockoutEnd.difference(DateTime.now()).inSeconds;
      if (remaining > 0) {
        _startLockoutCountdown(remaining);
      } else {
        await _authService.clearLockout();
        _failedAttempts = 0;
      }
    }

    notifyListeners();

    if (_isSetupComplete && state != UnlockState.lockout) {
      _startListening();
    }
  }

  // ─── Setup ────────────────────────────────────────────

  void onSetupComplete() {
    _isSetupComplete = true;
    _startListening();
    notifyListeners();
  }

  // ─── Biometrics ─────────────────────────────────────────

  Future<bool> authenticateBiometrics() async {
    if (_isAuthenticatingBiometrics) return false;
    _isAuthenticatingBiometrics = true;

    try {
      final isAvailable =
          await _localAuth.canCheckBiometrics || await _localAuth.isDeviceSupported();
      if (!isAvailable) {
        _isBiometricVerified = true; // Fallback if device lacks hardware
        notifyListeners();
        return true;
      }

      final didAuthenticate = await _localAuth.authenticate(
        localizedReason: 'Please authenticate to unlock SV Notes',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );

      if (didAuthenticate) {
        _isBiometricVerified = true;
        notifyListeners();
      }
      return didAuthenticate;
    } catch (_) {
      return false;
    } finally {
      _isAuthenticatingBiometrics = false;
    }
  }

  // ─── Gesture Listening ────────────────────────────────

  void _startListening() {
    _gestureSub?.cancel();
    _detector.start();

    _gestureSub = _detector.gestures.listen((g) {
      if (state == UnlockState.unlocked) return;
      if (state == UnlockState.lockout) return;
      if (!_isBiometricVerified) return; // Block input until fingerprint scanned

      _trailResetTimer?.cancel();
      inputTrail.add(g);
      notifyListeners();

      if (inputTrail.length >= patternLength) {
        _verifyPattern();
      } else {
        // Auto-reset partial gesture trail after 5 seconds of inactivity
        _trailResetTimer = Timer(const Duration(seconds: 5), () {
          if (state == UnlockState.locked && inputTrail.isNotEmpty) {
            inputTrail.clear();
            notifyListeners();
          }
        });
      }
    });
  }

  // ─── Pattern Verification ─────────────────────────────

  Future<void> _verifyPattern() async {
    _trailResetTimer?.cancel();
    final verified = await _authService.verifyPattern(List.from(inputTrail));
    if (verified) {
      state = UnlockState.unlocked;
      _triggerHaptic(success: true);
      inputTrail.clear();
      _failedAttempts = 0;
      await _authService.clearLockout();
      _startInactivityTimer();
    } else {
      state = UnlockState.failed;
      _triggerHaptic(success: false);
      inputTrail.clear();
      _failedAttempts++;
      await _authService.setFailedAttempts(_failedAttempts);

      if (_failedAttempts >= maxFailedAttempts) {
        // Trigger persistent lockout
        final endTime = DateTime.now().add(
          const Duration(seconds: lockoutDurationSeconds),
        );
        await _authService.setLockoutEndTime(endTime);
        _startLockoutCountdown(lockoutDurationSeconds);
      } else {
        // Auto-reset after 1.5 seconds
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (state == UnlockState.failed) {
            state = UnlockState.locked;
            notifyListeners();
          }
        });
      }
    }
    notifyListeners();
  }

  // ─── Lockout Countdown ────────────────────────────────

  void _startLockoutCountdown(int seconds) {
    state = UnlockState.lockout;
    _lockoutRemaining = seconds;
    _trailResetTimer?.cancel();
    _gestureSub?.cancel();
    _detector.stop();
    notifyListeners();

    _lockoutTimer?.cancel();
    _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _lockoutRemaining--;
      if (_lockoutRemaining <= 0) {
        timer.cancel();
        _endLockout();
      }
      notifyListeners();
    });
  }

  Future<void> _endLockout() async {
    _lockoutTimer?.cancel();
    _failedAttempts = 0;
    _lockoutRemaining = 0;
    state = UnlockState.locked;
    await _authService.clearLockout();
    _startListening();
    notifyListeners();
  }

  // ─── PIN Verification ─────────────────────────────────

  /// Verify fallback PIN with brute-force rate-limiting and lockout protection.
  Future<bool> verifyPin(String pin) async {
    final verified = await _authService.verifyPin(pin);
    if (verified) {
      state = UnlockState.unlocked;
      _isBiometricVerified = true; // PIN bypasses biometrics
      _triggerHaptic(success: true);
      inputTrail.clear();
      _failedAttempts = 0;
      _lockoutTimer?.cancel();
      _lockoutRemaining = 0;
      await _authService.clearLockout();
      _startInactivityTimer();
      notifyListeners();
      return true;
    } else {
      _triggerHaptic(success: false);
      _failedAttempts++;
      await _authService.setFailedAttempts(_failedAttempts);

      if (_failedAttempts >= maxFailedAttempts) {
        final endTime = DateTime.now().add(
          const Duration(seconds: lockoutDurationSeconds),
        );
        await _authService.setLockoutEndTime(endTime);
        _startLockoutCountdown(lockoutDurationSeconds);
      }
      notifyListeners();
      return false;
    }
  }

  // ─── Manual Retry ─────────────────────────────────────

  /// Clear the current gesture input trail manually.
  void retryManual() {
    _trailResetTimer?.cancel();
    inputTrail.clear();
    if (state == UnlockState.failed) {
      state = UnlockState.locked;
    }
    notifyListeners();
  }

  // ─── Inactivity Timer ─────────────────────────────────

  void _startInactivityTimer() {
    _inactivityTimer?.cancel();
    if (_inactivityTimeoutSeconds <= 0) return;
    _inactivityTimer = Timer(
      Duration(seconds: _inactivityTimeoutSeconds),
      () {
        if (state == UnlockState.unlocked) {
          lock();
        }
      },
    );
  }

  /// Call this on any user interaction to reset the inactivity timer.
  void onUserActivity() {
    if (state == UnlockState.unlocked) {
      _startInactivityTimer();
    }
  }

  // ─── App Lifecycle ────────────────────────────────────

  /// Called when app goes to background. Checks user setting.
  void onAppPaused() {
    // Crucial: Do not lock if app paused due to system biometric prompt dialog
    if (_isAuthenticatingBiometrics) return;
    if (state != UnlockState.unlocked) return;
    if (_autoLockOnSwitch) {
      lock();
    }
  }

  /// Called when the app is removed from recents (or force-stopped).
  /// Always locks regardless of settings.
  void onAppDetached() {
    lock();
  }

  // ─── Settings ─────────────────────────────────────────

  Future<void> setAutoLockOnSwitch(bool value) async {
    _autoLockOnSwitch = value;
    await _authService.setAutoLockOnSwitch(value);
    notifyListeners();
  }

  Future<void> setInactivityTimeout(int seconds) async {
    _inactivityTimeoutSeconds = seconds;
    await _authService.setInactivityTimeout(seconds);
    if (state == UnlockState.unlocked) {
      _startInactivityTimer();
    }
    notifyListeners();
  }

  // ─── Pattern/PIN Update ───────────────────────────────

  Future<void> updatePattern(List<Gesture> pattern) async {
    await _authService.updatePattern(pattern);
  }

  Future<void> updatePin(String pin) async {
    await _authService.updatePin(pin);
  }

  AuthService get authService => _authService;

  // ─── Lock / Reset ─────────────────────────────────────

  Future<void> _triggerHaptic({required bool success}) async {
    try {
      final hasVibrator = await Vibration.hasVibrator();
      if (hasVibrator != true) return;
      if (success) {
        Vibration.vibrate(duration: 200);
      } else {
        Vibration.vibrate(pattern: [0, 100, 50, 100]);
      }
    } catch (_) {}
  }

  void lock() {
    state = UnlockState.locked;
    _isBiometricVerified = false; // Reset biometrics
    _trailResetTimer?.cancel();
    inputTrail.clear();
    _inactivityTimer?.cancel();
    _encryptionService.clearMemoryKey();

    // Restart gesture listening
    if (_isSetupComplete) {
      _startListening();
    }
    notifyListeners();
  }

  void reset() {
    _trailResetTimer?.cancel();
    inputTrail.clear();
    _isBiometricVerified = false; // Reset biometrics
    state = UnlockState.locked;
    notifyListeners();
  }

  @override
  void dispose() {
    _gestureSub?.cancel();
    _trailResetTimer?.cancel();
    _lockoutTimer?.cancel();
    _inactivityTimer?.cancel();
    _detector.dispose();
    super.dispose();
  }
}
