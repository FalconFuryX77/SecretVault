import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists unlock throttling and lock preferences.
///
/// Credentials are NOT stored here any more: the PIN and gesture are never
/// stored at all. They derive the keys that open the vault container, so
/// the only way to check one is to try to decrypt with it.
class AuthService {
  static const _lockoutEndKey = 'lockout_end_time';
  static const _failedAttemptsKey = 'failed_attempts';
  static const _lockoutCountKey = 'lockout_count';
  static const _autoLockOnSwitchKey = 'auto_lock_on_switch';
  static const _inactivityTimeoutKey = 'inactivity_timeout_seconds';

  static const int baseLockoutSeconds = 30;
  static const int maxLockoutSeconds = 3600;

  final FlutterSecureStorage _storage;

  AuthService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  // ─── Lockout Persistence ────────────────────────────────

  Future<void> setLockoutEndTime(DateTime endTime) async {
    await _storage.write(key: _lockoutEndKey, value: endTime.toIso8601String());
  }

  Future<DateTime?> getLockoutEndTime() async {
    final val = await _storage.read(key: _lockoutEndKey);
    if (val == null) return null;
    final dt = DateTime.tryParse(val);
    if (dt == null || dt.isBefore(DateTime.now())) {
      await _storage.delete(key: _lockoutEndKey);
      return null;
    }
    return dt;
  }

  /// Called when a lockout period ends: attempts reset, but the escalation
  /// counter is kept so the next lockout is longer.
  Future<void> clearLockout() async {
    await _storage.delete(key: _lockoutEndKey);
    await _storage.write(key: _failedAttemptsKey, value: '0');
  }

  /// Called after a successful unlock: everything resets.
  Future<void> resetAfterSuccess() async {
    await clearLockout();
    await _storage.write(key: _lockoutCountKey, value: '0');
  }

  /// Starts the next lockout. Durations double each time (30 s, 1 min,
  /// 2 min, … capped at 1 h) until a successful unlock.
  Future<int> beginLockout() async {
    final count =
        int.tryParse(await _storage.read(key: _lockoutCountKey) ?? '') ?? 0;
    final seconds = min(
      maxLockoutSeconds,
      baseLockoutSeconds * (1 << min(count, 12)),
    );
    await _storage.write(key: _lockoutCountKey, value: '${count + 1}');
    await setLockoutEndTime(DateTime.now().add(Duration(seconds: seconds)));
    return seconds;
  }

  Future<int> getFailedAttempts() async {
    final val = await _storage.read(key: _failedAttemptsKey);
    return int.tryParse(val ?? '') ?? 0;
  }

  Future<void> setFailedAttempts(int attempts) async {
    await _storage.write(key: _failedAttemptsKey, value: attempts.toString());
  }

  // ─── Settings Persistence ───────────────────────────────

  Future<bool> getAutoLockOnSwitch() async {
    final val = await _storage.read(key: _autoLockOnSwitchKey);
    return val == null ? true : val == 'true';
  }

  Future<void> setAutoLockOnSwitch(bool value) async {
    await _storage.write(key: _autoLockOnSwitchKey, value: value.toString());
  }

  Future<int> getInactivityTimeout() async {
    final val = await _storage.read(key: _inactivityTimeoutKey);
    return int.tryParse(val ?? '') ?? 30;
  }

  Future<void> setInactivityTimeout(int seconds) async {
    await _storage.write(key: _inactivityTimeoutKey, value: seconds.toString());
  }
}
