import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/gesture.dart';

/// Handles storage and verification of gesture pattern and fallback PIN.
/// Also persists lockout state and user settings.
class AuthService {
  static const _patternKey = 'gesture_pattern';
  static const _pinKey = 'fallback_pin';
  static const _setupCompleteKey = 'setup_complete';
  static const _lockoutEndKey = 'lockout_end_time';
  static const _failedAttemptsKey = 'failed_attempts';
  static const _autoLockOnSwitchKey = 'auto_lock_on_switch';
  static const _inactivityTimeoutKey = 'inactivity_timeout_seconds';

  final _storage = const FlutterSecureStorage();

  // ─── Setup ──────────────────────────────────────────────

  Future<bool> isSetupComplete() async {
    final val = await _storage.read(key: _setupCompleteKey);
    return val == 'true';
  }

  Future<void> saveCredentials({
    required List<Gesture> pattern,
    required String pin,
  }) async {
    final patternHash = _hashPattern(pattern);
    final pinHash = _hashString(pin);
    await _storage.write(key: _patternKey, value: patternHash);
    await _storage.write(key: _pinKey, value: pinHash);
    await _storage.write(key: _setupCompleteKey, value: 'true');
  }

  // ─── Pattern & PIN ──────────────────────────────────────

  Future<void> updatePattern(List<Gesture> pattern) async {
    final patternHash = _hashPattern(pattern);
    await _storage.write(key: _patternKey, value: patternHash);
  }

  Future<void> updatePin(String pin) async {
    final pinHash = _hashString(pin);
    await _storage.write(key: _pinKey, value: pinHash);
  }

  Future<bool> verifyPattern(List<Gesture> pattern) async {
    final stored = await _storage.read(key: _patternKey);
    if (stored == null) return false;
    return stored == _hashPattern(pattern);
  }

  Future<bool> verifyPin(String pin) async {
    final stored = await _storage.read(key: _pinKey);
    if (stored == null) return false;
    return stored == _hashString(pin);
  }

  // ─── Lockout persistence ────────────────────────────────

  /// Save the lockout end timestamp (ISO 8601) to survive app restarts.
  Future<void> setLockoutEndTime(DateTime endTime) async {
    await _storage.write(
      key: _lockoutEndKey,
      value: endTime.toIso8601String(),
    );
  }

  /// Get the lockout end time. Returns null if no lockout is active.
  Future<DateTime?> getLockoutEndTime() async {
    final val = await _storage.read(key: _lockoutEndKey);
    if (val == null) return null;
    final dt = DateTime.tryParse(val);
    if (dt == null || dt.isBefore(DateTime.now())) {
      // Expired — clear it
      await clearLockout();
      return null;
    }
    return dt;
  }

  /// Clear lockout state after it expires or on successful unlock.
  Future<void> clearLockout() async {
    await _storage.delete(key: _lockoutEndKey);
    await _storage.write(key: _failedAttemptsKey, value: '0');
  }

  /// Persist failed attempt count so it survives app restarts.
  Future<void> setFailedAttempts(int count) async {
    await _storage.write(key: _failedAttemptsKey, value: count.toString());
  }

  Future<int> getFailedAttempts() async {
    final val = await _storage.read(key: _failedAttemptsKey);
    return int.tryParse(val ?? '0') ?? 0;
  }

  // ─── Auto-lock settings ─────────────────────────────────

  /// Whether to lock the app immediately on app switch (default: true).
  Future<bool> getAutoLockOnSwitch() async {
    final val = await _storage.read(key: _autoLockOnSwitchKey);
    return val != 'false'; // Default true
  }

  Future<void> setAutoLockOnSwitch(bool value) async {
    await _storage.write(key: _autoLockOnSwitchKey, value: value.toString());
  }

  /// Inactivity timeout in seconds (default: 30).
  Future<int> getInactivityTimeout() async {
    final val = await _storage.read(key: _inactivityTimeoutKey);
    return int.tryParse(val ?? '30') ?? 30;
  }

  Future<void> setInactivityTimeout(int seconds) async {
    await _storage.write(key: _inactivityTimeoutKey, value: seconds.toString());
  }

  // ─── Hashing ────────────────────────────────────────────

  String _hashPattern(List<Gesture> pattern) {
    final patternStr = pattern.map((g) => g.name).join('-');
    return _hashString(patternStr);
  }

  String _hashString(String input) {
    final bytes = utf8.encode(input);
    return sha256.convert(bytes).toString();
  }
}
