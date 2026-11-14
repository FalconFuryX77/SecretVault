import 'dart:async';
import 'package:flutter/material.dart';
import 'package:vibration/vibration.dart';
import '../models/gesture.dart';
import '../services/gesture_detector.dart';
import '../services/auth_service.dart';
import '../services/vault_service.dart';
import '../vault/platform_keys.dart';

/// Drives the lock screen: collects motion gestures, unlocks the vault with
/// gesture + biometric or with the PIN, and handles lockout, auto-lock and
/// the panic shake.
///
/// The gesture is never compared against a stored value. It derives a key
/// that can open a vault's gesture slot; that slot then needs the biometric
/// before it releases the vault key. So the gesture alone unlocks nothing.
class GestureUnlockProvider extends ChangeNotifier {
  final GestureDetectorService _detector;
  final AuthService _authService;
  final VaultService _vault;

  UnlockState state = UnlockState.locked;
  VaultType activeVaultType = VaultType.primary;

  bool _isSetupComplete = false;
  bool get isSetupComplete => _isSetupComplete;

  bool _isAuthenticatingBiometrics = false;
  bool get isAuthenticatingBiometrics => _isAuthenticatingBiometrics;

  final _unlockEventController = StreamController<VaultType>.broadcast();
  Stream<VaultType> get onVaultUnlocked => _unlockEventController.stream;

  StreamSubscription? _panicSub;
  StreamSubscription? _lockedSub;
  bool _disposed = false;
  StreamSubscription? _discreteSub;

  /// Gesture sequences are 4–8 moves long. The sequence is submitted after a
  /// short pause, or as soon as it reaches the maximum length.
  static const int minPatternLength = 4;
  static const int maxPatternLength = 8;
  static const Duration submitPause = Duration(milliseconds: 1500);
  List<Gesture> inputTrail = [];
  Timer? _trailTimer;

  static const String biometricReason = 'Confirm it\'s you';

  // Lockout State
  static const int maxFailedAttempts = 5;
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
    required VaultService vaultService,
    GestureDetectorService? detector,
    AuthService? authService,
  }) : _vault = vaultService,
       _detector = detector ?? GestureDetectorService(),
       _authService = authService ?? AuthService() {
    _lockedSub = _vault.onLocked.listen((_) {
      if (state == UnlockState.unlocked) {
        state = UnlockState.locked;
        notifyListeners();
      }
    });
    _init();
  }

  Future<void> _init() async {
    _isSetupComplete = await _vault.isSetUp();
    await reloadSettings();

    _failedAttempts = await _authService.getFailedAttempts();
    final lockoutEnd = await _authService.getLockoutEndTime();
    if (lockoutEnd != null) {
      final remaining = lockoutEnd.difference(DateTime.now()).inSeconds;
      if (remaining > 0) {
        _startLockoutCountdown(remaining);
      }
    }

    notifyListeners();

    if (_isSetupComplete && state != UnlockState.lockout) {
      _startListening();
    }
  }

  Future<void> reloadSettings() async {
    _autoLockOnSwitch = await _authService.getAutoLockOnSwitch();
    _inactivityTimeoutSeconds = await _authService.getInactivityTimeout();
    notifyListeners();
  }

  int _suppressAutoLock = 0;

  void onAppPaused() {
    if (_autoLockOnSwitch && _suppressAutoLock == 0) {
      lockVault();
    }
  }

  /// Runs [op] (e.g. the system file picker, which backgrounds the app)
  /// without the vault auto-locking because of it.
  Future<T> withoutAutoLock<T>(Future<T> Function() op) async {
    _suppressAutoLock++;
    try {
      return await op();
    } finally {
      _suppressAutoLock--;
    }
  }

  void onAppResumed() {
    // Never prompt biometrics on resume: an unprompted fingerprint dialog
    // gives away that this is not a regular Files app.
  }

  void _startListening() {
    _stopListening();
    _detector.start();

    _panicSub = _detector.onPanicTriggered.listen((_) {
      triggerPanicLock();
    });

    _discreteSub = _detector.gestures.listen((gesture) {
      if (state == UnlockState.locked || state == UnlockState.recording) {
        _onDiscreteGesture(gesture);
      }
    });
  }

  void _stopListening() {
    _panicSub?.cancel();
    _panicSub = null;
    _discreteSub?.cancel();
    _discreteSub = null;
    _detector.stop();
  }

  // ─── Gesture entry ───────────────────────────────────────

  void _onDiscreteGesture(Gesture gesture) {
    if (state == UnlockState.lockout || state == UnlockState.authenticating) {
      return;
    }

    _trailTimer?.cancel();
    inputTrail.add(gesture);
    _vibrateShort();

    if (inputTrail.length >= maxPatternLength) {
      _submitGesture();
      return;
    }
    state = UnlockState.recording;
    notifyListeners();
    _trailTimer = Timer(submitPause, () {
      if (inputTrail.length >= minPatternLength) {
        _submitGesture();
      } else {
        inputTrail.clear();
        state = UnlockState.locked;
        notifyListeners();
      }
    });
  }

  Future<void> _submitGesture() async {
    _trailTimer?.cancel();
    final attempt = List<Gesture>.from(inputTrail);
    state = UnlockState.authenticating;
    _isAuthenticatingBiometrics = true;
    notifyListeners();

    bool ok = false;
    try {
      final session = await _vault.unlockWithGesture(
        attempt,
        reason: biometricReason,
      );
      if (session != null) {
        ok = true;
        await _onSuccessfulUnlock(session.type);
      }
    } on BiometricInvalidatedException {
      // A new fingerprint was enrolled on the device; the vault's biometric
      // key is gone by design. The PIN still works, then re-enroll.
    } catch (_) {}

    _isAuthenticatingBiometrics = false;
    inputTrail.clear();
    if (!ok) await _onFailedAttempt();
  }

  void addManualGesture(Gesture gesture) {
    _onDiscreteGesture(gesture);
  }

  void clearInputTrail() {
    _trailTimer?.cancel();
    inputTrail.clear();
    state = UnlockState.locked;
    notifyListeners();
  }

  // ─── PIN ─────────────────────────────────────────────────

  Future<bool> verifyPin(String pin) async {
    if (state == UnlockState.lockout || state == UnlockState.authenticating) {
      return false;
    }
    state = UnlockState.authenticating;
    notifyListeners();

    try {
      final session = await _vault.unlockWithPin(pin);
      if (session != null) {
        await _onSuccessfulUnlock(session.type);
        return true;
      }
    } catch (_) {}
    await _onFailedAttempt();
    return false;
  }

  // ─── Unlock Success / Failure ────────────────────────────

  Future<void> _onSuccessfulUnlock(
    VaultType vaultType, {
    bool announce = true,
  }) async {
    _failedAttempts = 0;
    await _authService.resetAfterSuccess();
    activeVaultType = vaultType;
    state = UnlockState.unlocked;
    _vibrateSuccess();
    _resetInactivityTimer();
    notifyListeners();
    if (announce && !_unlockEventController.isClosed) {
      _unlockEventController.add(vaultType);
    }
  }

  Future<void> _onFailedAttempt() async {
    _failedAttempts++;
    await _authService.setFailedAttempts(_failedAttempts);
    _vibrateError();

    if (_failedAttempts >= maxFailedAttempts) {
      final seconds = await _authService.beginLockout();
      _startLockoutCountdown(seconds);
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

  // ─── Locking ─────────────────────────────────────────────

  /// Instant lock from the hard-shake gesture: keys wiped from memory.
  void triggerPanicLock() {
    _resetLockState();
    state = UnlockState.panicLocked;
    _vibratePanic();
    notifyListeners();

    Future.delayed(const Duration(milliseconds: 600), () {
      if (state == UnlockState.panicLocked) {
        state = UnlockState.locked;
        notifyListeners();
      }
    });
  }

  void lockVault() {
    _resetLockState();
    state = UnlockState.locked;
    notifyListeners();
  }

  void _resetLockState() {
    _inactivityTimer?.cancel();
    _trailTimer?.cancel();
    inputTrail.clear();
    _vault.lock();
  }

  // ─── Lockout Handling ────────────────────────────────────

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
        if (_isSetupComplete) _startListening();
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
      if (state != UnlockState.unlocked) return;
      if (_vault.isBusy) {
        _resetInactivityTimer(); // don't cut off an import in progress
      } else {
        lockVault();
      }
    });
  }

  // ─── Setup Callback ──────────────────────────────────────

  /// Called when the setup wizard has created the vault. The new vault is
  /// left unlocked; the wizard navigates into it itself.
  Future<void> onSetupComplete() async {
    _isSetupComplete = true;
    _startListening();
    if (_vault.isUnlocked) {
      await _onSuccessfulUnlock(_vault.session!.type, announce: false);
    } else {
      notifyListeners();
    }
  }

  // ─── Haptics ─────────────────────────────────────────────

  void _vibrateShort() async {
    try {
      if (await Vibration.hasVibrator()) {
        Vibration.vibrate(duration: 40);
      }
    } catch (_) {}
  }

  void _vibrateSuccess() async {
    try {
      if (await Vibration.hasVibrator()) {
        Vibration.vibrate(pattern: [0, 60, 40, 80]);
      }
    } catch (_) {}
  }

  void _vibrateError() async {
    try {
      if (await Vibration.hasVibrator()) {
        Vibration.vibrate(pattern: [0, 80, 50, 80, 50, 80]);
      }
    } catch (_) {}
  }

  void _vibratePanic() async {
    try {
      if (await Vibration.hasVibrator()) {
        Vibration.vibrate(pattern: [0, 150, 80, 200]);
      }
    } catch (_) {}
  }

  @override
  void notifyListeners() {
    // Timers and lock events can land after dispose (e.g. app teardown).
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _lockedSub?.cancel();
    _stopListening();
    _detector.dispose();
    _lockoutTimer?.cancel();
    _inactivityTimer?.cancel();
    _trailTimer?.cancel();
    _unlockEventController.close();
    super.dispose();
  }
}
