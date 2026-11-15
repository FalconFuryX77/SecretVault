import 'dart:async';
import 'package:flutter/material.dart';
import 'package:vibration/vibration.dart';
import '../models/vault_state.dart';
import '../services/auth_service.dart';
import '../services/shake_detector.dart';
import '../services/vault_service.dart';

/// Drives unlocking and locking: PIN entry, lockout after failed attempts,
/// auto-lock, and the hard-shake lock.
///
/// The PIN is never compared against a stored value. It derives the key that
/// opens a vault, so the only way to check a PIN is to try to decrypt with
/// it. The real PIN opens the real vault; the decoy PIN opens the decoy.
class UnlockProvider extends ChangeNotifier {
  final ShakeDetector _shake;
  final AuthService _authService;
  final VaultService _vault;

  UnlockState state = UnlockState.locked;
  VaultType activeVaultType = VaultType.primary;

  bool _isSetupComplete = false;
  bool get isSetupComplete => _isSetupComplete;

  final _unlockEventController = StreamController<VaultType>.broadcast();
  Stream<VaultType> get onVaultUnlocked => _unlockEventController.stream;

  StreamSubscription? _shakeSub;
  StreamSubscription? _lockedSub;
  bool _disposed = false;

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

  UnlockProvider({
    required VaultService vaultService,
    ShakeDetector? shakeDetector,
    AuthService? authService,
  }) : _vault = vaultService,
       _shake = shakeDetector ?? ShakeDetector(),
       _authService = authService ?? AuthService() {
    _lockedSub = _vault.onLocked.listen((_) {
      _stopShakeWatch();
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
  }

  Future<void> reloadSettings() async {
    _autoLockOnSwitch = await _authService.getAutoLockOnSwitch();
    _inactivityTimeoutSeconds = await _authService.getInactivityTimeout();
    notifyListeners();
  }

  int _suppressAutoLock = 0;
  bool _backgrounded = false;

  bool get _shouldLockInBackground => _autoLockOnSwitch && _suppressAutoLock == 0;

  void onAppPaused() {
    _backgrounded = true;
    if (_shouldLockInBackground) {
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
    // The app never prompts on resume: an unprompted dialog would give away
    // that this is not a regular Files app.
    _backgrounded = false;
  }

  // ─── Shake-to-lock ───────────────────────────────────────
  //
  // The motion sensor is read only while a vault is open. The cover app
  // never touches it, and a shake while locked does nothing at all (no
  // vibration, no state change) so it can't give the app away.

  void _startShakeWatch() {
    _stopShakeWatch();
    _shake.start();
    _shakeSub = _shake.onShake.listen((_) => triggerPanicLock());
  }

  void _stopShakeWatch() {
    _shakeSub?.cancel();
    _shakeSub = null;
    _shake.stop();
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
        if (_backgrounded && _shouldLockInBackground) {
          // The app was sent to the background while the PIN was being
          // checked. Don't leave a vault open behind the user's back.
          await _vault.lock();
          state = UnlockState.locked;
          notifyListeners();
          return false;
        }
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
    _startShakeWatch();
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
      await Future.delayed(const Duration(milliseconds: 2000));
      if (state == UnlockState.failed) {
        state = UnlockState.locked;
        notifyListeners();
      }
    }
  }

  // ─── Locking ─────────────────────────────────────────────

  /// Instant lock (hard shake, or the panic button): keys wiped from memory.
  /// Does nothing unless a vault is open.
  void triggerPanicLock() {
    if (state != UnlockState.unlocked) return;
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
    if (state == UnlockState.unlocked || state == UnlockState.panicLocked) {
      state = UnlockState.locked;
    }
    notifyListeners();
  }

  void _resetLockState() {
    _inactivityTimer?.cancel();
    _stopShakeWatch();
    _vault.lock();
  }

  // ─── Lockout Handling ────────────────────────────────────

  void _startLockoutCountdown(int seconds) {
    state = UnlockState.lockout;
    _lockoutRemaining = seconds;
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

  /// Called when setup has created the vault. The new vault is left
  /// unlocked; the setup screen navigates into it itself.
  Future<void> onSetupComplete() async {
    _isSetupComplete = true;
    if (_vault.isUnlocked) {
      await _onSuccessfulUnlock(_vault.session!.type, announce: false);
    } else {
      notifyListeners();
    }
  }

  // ─── Haptics ─────────────────────────────────────────────

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
    _stopShakeWatch();
    _shake.dispose();
    _lockoutTimer?.cancel();
    _inactivityTimer?.cancel();
    _unlockEventController.close();
    super.dispose();
  }
}
