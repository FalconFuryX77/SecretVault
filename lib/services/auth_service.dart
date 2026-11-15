import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'security_channel_service.dart';

/// Persists unlock throttling and lock preferences.
///
/// Credentials are NOT stored here: a PIN is never stored at all. It derives
/// the key that opens the vault container, so the only way to check one is
/// to try to decrypt with it.
class AuthService {
  static const _lockoutEndKey = 'lockout_end_time';
  static const _failedAttemptsKey = 'failed_attempts';
  static const _lockoutCountKey = 'lockout_count';
  static const _lastFailureKey = 'last_failure';
  static const _lockoutAnchorKey = 'lockout_anchor';

  /// Failed attempts and the lockout escalation are forgotten this long
  /// after the last failure, never by a successful unlock: otherwise anyone
  /// holding the decoy PIN could make four guesses at the real PIN, open the
  /// decoy to reset the count, and repeat forever.
  static const Duration failureMemory = Duration(hours: 24);
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
    // Also anchored to time since boot, so moving the phone's clock forward
    // doesn't end a lockout early.
    final clock = await SecurityChannelService.monotonicClock();
    if (clock != null) {
      final dur = endTime.difference(DateTime.now()).inMilliseconds;
      await _storage.write(
        key: _lockoutAnchorKey,
        value: jsonEncode({'boot': clock.boot, 'end': clock.elapsed + dur, 'dur': dur}),
      );
    }
  }

  Future<DateTime?> getLockoutEndTime() async {
    final anchorRaw = await _storage.read(key: _lockoutAnchorKey);
    final clock = anchorRaw == null ? null : await SecurityChannelService.monotonicClock();
    if (anchorRaw != null && clock != null) {
      final a = jsonDecode(anchorRaw) as Map<String, dynamic>;
      var remaining = (a['end'] as int) - clock.elapsed;
      if (a['boot'] != clock.boot) {
        // After a restart the clock since boot starts again from zero, so
        // the lockout starts again too, in full.
        remaining = a['dur'] as int;
        await _storage.write(
          key: _lockoutAnchorKey,
          value: jsonEncode({'boot': clock.boot, 'end': clock.elapsed + remaining, 'dur': remaining}),
        );
      }
      if (remaining <= 0) {
        await _storage.delete(key: _lockoutAnchorKey);
        await _storage.delete(key: _lockoutEndKey);
        return null;
      }
      return DateTime.now().add(Duration(milliseconds: remaining));
    }
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
    await _storage.delete(key: _lockoutAnchorKey);
    await _storage.write(key: _failedAttemptsKey, value: '0');
  }

  /// Called after a successful unlock. Deliberately leaves the failure
  /// count and escalation alone (see [failureMemory]).
  Future<void> recordSuccess() async {}

  /// Forgets failures older than [failureMemory].
  Future<void> _expireOldFailures() async {
    final last = DateTime.tryParse(await _storage.read(key: _lastFailureKey) ?? '');
    if (last != null && DateTime.now().difference(last) > failureMemory) {
      await _storage.write(key: _failedAttemptsKey, value: '0');
      await _storage.write(key: _lockoutCountKey, value: '0');
      await _storage.delete(key: _lastFailureKey);
    }
  }

  /// Counts one failed attempt (a wrong PIN, or a refused PIN change) and
  /// returns the running count.
  Future<int> recordFailure() async {
    final n = await getFailedAttempts() + 1;
    await setFailedAttempts(n);
    return n;
  }

  /// Starts the next lockout. Durations double each time (30 s, 1 min,
  /// 2 min, … capped at 1 h) until a successful unlock.
  Future<int> beginLockout() async {
    await _expireOldFailures();
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
    await _expireOldFailures();
    final val = await _storage.read(key: _failedAttemptsKey);
    return int.tryParse(val ?? '') ?? 0;
  }

  Future<void> setFailedAttempts(int attempts) async {
    await _storage.write(key: _failedAttemptsKey, value: attempts.toString());
    if (attempts > 0) {
      await _storage.write(key: _lastFailureKey, value: DateTime.now().toIso8601String());
    }
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
