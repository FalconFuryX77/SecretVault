import 'dart:async';
import 'package:flutter/material.dart';
import 'package:vibration/vibration.dart';
import 'package:local_auth/local_auth.dart';
import '../models/gesture.dart';
import '../models/motion_point.dart';
import '../models/gesture_template.dart';
import '../services/gesture_detector.dart';
import '../services/auth_service.dart';
import '../services/encryption_service.dart';
import '../services/dtw_matcher.dart';

class GestureUnlockProvider extends ChangeNotifier {
  final GestureDetectorService _detector;
  final AuthService _authService;
  final EncryptionService _encryptionService;
  final LocalAuthentication _localAuth;

  UnlockState state = UnlockState.locked;
  VaultType activeVaultType = VaultType.primary;

  // 3D Wand & Air Drawing State
  bool _isSetupComplete = false;
  bool get isSetupComplete => _isSetupComplete;

  GestureTemplate? _masterTemplate;
  GestureTemplate? _decoyTemplate;

  final List<MotionPoint> _currentTrail = [];
  List<MotionPoint> get currentTrail => List.unmodifiable(_currentTrail);

  bool _isBiometricVerified = false;
  bool get isBiometricVerified => _isBiometricVerified;

  bool _isAuthenticatingBiometrics = false;
  bool get isAuthenticatingBiometrics => _isAuthenticatingBiometrics;

  StreamSubscription? _motionSub;
  StreamSubscription? _trajectorySub;
  StreamSubscription? _panicSub;
  StreamSubscription? _discreteSub;

  // Legacy trail for discrete mode
  List<Gesture> inputTrail = [];
  Timer? _trailResetTimer;
  static const int patternLength = 4;

  // Lockout State
  static const int maxFailedAttempts = 5;
  static const int lockoutDurationSeconds = 30;
  int _failedAttempts = 0;
  int get failedAttempts => _failedAttempts;
  int _lockoutRemaining = 0;
  int get lockoutRemaining => _lockoutRemaining;
  Timer? _lockoutTimer;

  // Inactivity & Auto-Lock State
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
    _masterTemplate = await _authService.getMasterTemplate();
    _decoyTemplate = await _authService.getDecoyTemplate();

    _autoLockOnSwitch = await _authService.getAutoLockOnSwitch();
    _inactivityTimeoutSeconds = await _authService.getInactivityTimeout();

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

  void _startListening() {
    _stopListening();
    _detector.start();

    // 1. Live motion trail for particle effects
    _motionSub = _detector.motionPoints.listen((point) {
      _currentTrail.add(point);
      if (_currentTrail.length > 50) {
        _currentTrail.removeAt(0);
      }
      notifyListeners();
    });

    // 2. Trajectory completion (Auto or Manual 3D Wand stroke)
    _trajectorySub = _detector.trajectoryStream.listen((trajectory) {
      if (state == UnlockState.locked || state == UnlockState.recording) {
        _evaluateTrajectory(trajectory);
      }
    });

    // 3. Instant Panic Drop / Double Chop trigger
    _panicSub = _detector.onPanicTriggered.listen((_) {
      triggerPanicLock();
    });

    // 4. Legacy discrete tilts
    _discreteSub = _detector.gestures.listen((gesture) {
      if (state == UnlockState.locked || state == UnlockState.recording) {
        _onDiscreteGesture(gesture);
      }
    });
  }

  void _stopListening() {
    _motionSub?.cancel();
    _motionSub = null;
    _trajectorySub?.cancel();
    _trajectorySub = null;
    _panicSub?.cancel();
    _panicSub = null;
    _discreteSub?.cancel();
    _discreteSub = null;
    _detector.stop();
  }

  // ─── Trajectory & 3D Wand Evaluation ─────────────────────

  Future<void> _evaluateTrajectory(List<MotionPoint> trajectory) async {
    if (state == UnlockState.lockout) return;

    // A. Check Master Template
    if (_masterTemplate != null) {
      final result = DtwMatcher.match(candidate: trajectory, template: _masterTemplate!);
      if (result.isMatch) {
        await _onSuccessfulUnlock(VaultType.primary);
        return;
      }
    }

    // B. Check Decoy Template
    if (_decoyTemplate != null) {
      final result = DtwMatcher.match(candidate: trajectory, template: _decoyTemplate!);
      if (result.isMatch) {
        await _onSuccessfulUnlock(VaultType.decoy);
        return;
      }
    }

    // If template exists but did not match, handle attempt
    if (_masterTemplate != null) {
      await _onFailedAttempt();
    }
  }

  // ─── Manual Air Drawing Trigger ──────────────────────────

  void startAirDrawing() {
    if (state == UnlockState.lockout) return;
    _detector.startRecording();
    state = UnlockState.recording;
    notifyListeners();
  }

  Future<void> stopAirDrawingAndEvaluate() async {
    if (state == UnlockState.lockout) return;
    final trajectory = _detector.stopRecording();
    if (trajectory.length >= 6) {
      await _evaluateTrajectory(trajectory);
    } else {
      state = UnlockState.locked;
      notifyListeners();
    }
  }

  // ─── Legacy Discrete Handler ─────────────────────────────

  void _onDiscreteGesture(Gesture gesture) {
    if (state == UnlockState.lockout) return;

    _trailResetTimer?.cancel();
    inputTrail.add(gesture);
    _vibrateShort();

    if (inputTrail.length == patternLength) {
      _verifyDiscretePattern();
    } else {
      state = UnlockState.recording;
      notifyListeners();
      _trailResetTimer = Timer(const Duration(seconds: 4), () {
        inputTrail.clear();
        state = UnlockState.locked;
        notifyListeners();
      });
    }
  }

  Future<void> _verifyDiscretePattern() async {
    state = UnlockState.authenticating;
    notifyListeners();

    final isCorrect = await _authService.verifyPattern(inputTrail);
    if (isCorrect) {
      await _onSuccessfulUnlock(VaultType.primary);
    } else {
      await _onFailedAttempt();
    }
    inputTrail.clear();
  }

  // ─── Biometrics ──────────────────────────────────────────

  Future<bool> authenticateBiometrics() async {
    if (_isAuthenticatingBiometrics) return false;
    try {
      final canCheck = await _localAuth.canCheckBiometrics;
      final isSupported = await _localAuth.isDeviceSupported();
      if (!canCheck || !isSupported) return false;

      _isAuthenticatingBiometrics = true;
      notifyListeners();

      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Authenticate with fingerprint for SecretVault',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );

      _isAuthenticatingBiometrics = false;
      if (authenticated) {
        _isBiometricVerified = true;
        _vibrateShort();
        notifyListeners();
      }
      return authenticated;
    } catch (_) {
      _isAuthenticatingBiometrics = false;
      notifyListeners();
      return false;
    }
  }

  void resetBiometrics() {
    _isBiometricVerified = false;
    notifyListeners();
  }

  // ─── PIN Fallback ────────────────────────────────────────

  Future<bool> verifyPin(String pin) async {
    if (state == UnlockState.lockout) return false;

    final vaultType = await _authService.verifyPinWithType(pin);
    if (vaultType != null) {
      await _onSuccessfulUnlock(vaultType);
      return true;
    } else {
      await _onFailedAttempt();
      return false;
    }
  }

  // ─── Unlock Success / Failure ────────────────────────────

  Future<void> _onSuccessfulUnlock(VaultType vaultType) async {
    _failedAttempts = 0;
    await _authService.clearLockout();
    activeVaultType = vaultType;
    state = UnlockState.unlocked;
    _vibrateSuccess();
    _resetInactivityTimer();
    notifyListeners();
  }

  Future<void> _onFailedAttempt() async {
    _failedAttempts++;
    await _authService.setFailedAttempts(_failedAttempts);
    _vibrateError();

    if (_failedAttempts >= maxFailedAttempts) {
      _triggerLockout();
    } else {
      state = UnlockState.failed;
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 1200));
      if (state == UnlockState.failed) {
        state = UnlockState.locked;
        notifyListeners();
      }
    }
  }

  // ─── Panic RAM Wipe & Instant Lock ───────────────────────

  void triggerPanicLock() {
    _encryptionService.clearMemoryKey();
    _inactivityTimer?.cancel();
    _trailResetTimer?.cancel();
    inputTrail.clear();
    _currentTrail.clear();
    _isBiometricVerified = false;
    state = UnlockState.locked;
    _vibratePanic();
    notifyListeners();
  }

  void lockVault() {
    _encryptionService.clearMemoryKey();
    _inactivityTimer?.cancel();
    _trailResetTimer?.cancel();
    inputTrail.clear();
    _isBiometricVerified = false;
    state = UnlockState.locked;
    notifyListeners();
  }

  // ─── Lockout Handling ────────────────────────────────────

  void _triggerLockout() {
    final endTime = DateTime.now().add(const Duration(seconds: lockoutDurationSeconds));
    _authService.setLockoutEndTime(endTime);
    _startLockoutCountdown(lockoutDurationSeconds);
  }

  void _startLockoutCountdown(int seconds) {
    state = UnlockState.lockout;
    _lockoutRemaining = seconds;
    _stopListening();
    notifyListeners();

    _lockoutTimer?.cancel();
    _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      _lockoutRemaining--;
      if (_lockoutRemaining <= 0) {
        timer.cancel();
        _lockoutTimer = null;
        _failedAttempts = 0;
        await _authService.clearLockout();
        state = UnlockState.locked;
        _startListening();
        notifyListeners();
      } else {
        notifyListeners();
      }
    });
  }

  // ─── Inactivity Auto-Lock ────────────────────────────────

  void onUserActivity() {
    if (state == UnlockState.unlocked) {
      _resetInactivityTimer();
    }
  }

  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    if (_inactivityTimeoutSeconds <= 0) return;

    _inactivityTimer = Timer(Duration(seconds: _inactivityTimeoutSeconds), () {
      if (state == UnlockState.unlocked) {
        lockVault();
      }
    });
  }

  void onAppLifecycleState(AppLifecycleState appState) {
    if (appState == AppLifecycleState.paused || appState == AppLifecycleState.inactive) {
      if (_autoLockOnSwitch && state == UnlockState.unlocked) {
        lockVault();
      }
    }
  }

  // ─── Setup Callback ──────────────────────────────────────

  Future<void> onSetupComplete() async {
    _isSetupComplete = true;
    _masterTemplate = await _authService.getMasterTemplate();
    _decoyTemplate = await _authService.getDecoyTemplate();
    _startListening();
    notifyListeners();
  }

  // ─── Haptics ─────────────────────────────────────────────

  void _vibrateShort() async {
    try {
      if (await Vibration.hasVibrator() ?? false) {
        Vibration.vibrate(duration: 40);
      }
    } catch (_) {}
  }

  void _vibrateSuccess() async {
    try {
      if (await Vibration.hasVibrator() ?? false) {
        Vibration.vibrate(pattern: [0, 60, 40, 80]);
      }
    } catch (_) {}
  }

  void _vibrateError() async {
    try {
      if (await Vibration.hasVibrator() ?? false) {
        Vibration.vibrate(pattern: [0, 80, 50, 80, 50, 80]);
      }
    } catch (_) {}
  }

  void _vibratePanic() async {
    try {
      if (await Vibration.hasVibrator() ?? false) {
        Vibration.vibrate(pattern: [0, 150, 80, 200]);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _stopListening();
    _detector.dispose();
    _lockoutTimer?.cancel();
    _inactivityTimer?.cancel();
    _trailResetTimer?.cancel();
    super.dispose();
  }
}
