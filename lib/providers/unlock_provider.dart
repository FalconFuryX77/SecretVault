import 'dart:async';
import 'dart:math';
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

  bool _isSetupComplete = false;
  bool get isSetupComplete => _isSetupComplete;

  /// A vault was unlocked from the lock screen. Which one is never said:
  /// every vault looks and behaves the same.
  final _unlockEventController = StreamController<void>.broadcast();
  Stream<void> get onVaultUnlocked => _unlockEventController.stream;

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

  Timer? _suppressedPauseTimer;

  void onAppPaused() {
    _backgrounded = true;
    if (_shouldLockInBackground) {
      lockVault();
    } else if (_autoLockOnSwitch && _suppressAutoLock > 0 && state == UnlockState.unlocked) {
      // A system screen (file picker, permission prompt) is up. If the user
      // leaves it with Home instead of coming back, the vault must not stay
      // open in the background indefinitely.
      _suppressedPauseTimer?.cancel();
      _suppressedPauseTimer = Timer(const Duration(minutes: 3), () {
        if (_backgrounded && state == UnlockState.unlocked) lockVault();
      });
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
    // that this is not a regular app.
    _backgrounded = false;
    _suppressedPauseTimer?.cancel();
    if (state == UnlockState.unlocked) _resetInactivityTimer();
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
    // Busy before the first await, so a burst of submissions can't get
    // several guesses in flight at once.
    state = UnlockState.authenticating;
    notifyListeners();
    // A lockout may have started while a vault was open (refused PIN
    // changes count too); honour it before checking anything.
    DateTime? lockoutEnd;
    try {
      lockoutEnd = await _authService.getLockoutEndTime();
    } catch (_) {
      // Unreadable lockout state: fall through to a normal check rather
      // than leaving the screen stuck "authenticating".
    }
    if (lockoutEnd != null) {
      _startLockoutCountdown(max(1, lockoutEnd.difference(DateTime.now()).inSeconds));
      return false;
    }

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
        await _onSuccessfulUnlock();
        return true;
      }
    } catch (_) {}
    try {
      await _onFailedAttempt();
    } finally {
      if (state == UnlockState.authenticating) {
        state = UnlockState.locked;
        notifyListeners();
      }
    }
    return false;
  }

  // ─── Unlock Success / Failure ────────────────────────────

  Future<void> _onSuccessfulUnlock({bool announce = true}) async {
    await _authService.recordSuccess();
    state = UnlockState.unlocked;
    _vibrateSuccess();
    _resetInactivityTimer();
    _startShakeWatch();
    notifyListeners();
    if (announce && !_unlockEventController.isClosed) {
      _unlockEventController.add(null);
    }
  }

  /// A PIN change refused because the PIN is taken (or unusable) tells
  /// whoever tried it something, so it costs the same as a wrong PIN at the
  /// lock screen. The current screen is left alone; a lockout it starts
  /// applies to the next unlock.
  Future<void> registerRefusedPin() async {
    _failedAttempts = await _authService.recordFailure();
    if (_failedAttempts >= maxFailedAttempts) {
      await _authService.beginLockout();
      _failedAttempts = 0;
      await _authService.setFailedAttempts(0);
    }
  }

  Future<void> _onFailedAttempt() async {
    _failedAttempts = await _authService.recordFailure();
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

  final List<VoidCallback> _beforeLock = [];

  /// Editors register here to save unsaved text when the vault locks. A
  /// callback that starts a vault write synchronously gets it in before the
  /// session closes (close waits for queued writes).
  void addBeforeLock(VoidCallback cb) => _beforeLock.add(cb);
  void removeBeforeLock(VoidCallback cb) => _beforeLock.remove(cb);

  void _resetLockState() {
    _inactivityTimer?.cancel();
    _suppressedPauseTimer?.cancel();
    _stopShakeWatch();
    if (_vault.isUnlocked) {
      for (final cb in List.of(_beforeLock)) {
        try {
          cb();
        } catch (_) {}
      }
    }
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

  DateTime? _inactivityHold;

  /// Holds off the inactivity lock (not the app-switch lock) while [op]
  /// runs, for at most 10 minutes: for screens the user reads or copies
  /// from without touching it, like the recovery code.
  Future<T> holdingInactivityLock<T>(Future<T> Function() op) async {
    _inactivityHold = DateTime.now();
    try {
      return await op();
    } finally {
      _inactivityHold = null;
      if (state == UnlockState.unlocked) _resetInactivityTimer();
    }
  }

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
      final held = _inactivityHold != null &&
          DateTime.now().difference(_inactivityHold!) < const Duration(minutes: 10);
      if (_vault.isBusy || _suppressAutoLock > 0 || held) {
        // Don't cut off an import, an export, the user picking files, or
        // the user copying a recovery code onto paper.
        _resetInactivityTimer();
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
      await _onSuccessfulUnlock(announce: false);
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
