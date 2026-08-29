import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/gesture.dart';

/// Handles secure storage and verification of gesture patterns and fallback PINs.
/// Uses cryptographically salted HMAC-SHA256 with constant-time verification.
/// Also persists lockout state and user settings.
class AuthService {
  static const _patternKey = 'gesture_pattern';
  static const _pinKey = 'fallback_pin';
  static const _setupCompleteKey = 'setup_complete';
  static const _lockoutEndKey = 'lockout_end_time';
  static const _failedAttemptsKey = 'failed_attempts';
  static const _autoLockOnSwitchKey = 'auto_lock_on_switch';
  static const _inactivityTimeoutKey = 'inactivity_timeout_seconds';

  final FlutterSecureStorage _storage;

  AuthService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

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
    final pinHash = _hashInput(pin);
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
    final pinHash = _hashInput(pin);
    await _storage.write(key: _pinKey, value: pinHash);
  }

  Future<bool> verifyPattern(List<Gesture> pattern) async {
    final stored = await _storage.read(key: _patternKey);
    if (stored == null) return false;

    final patternStr = pattern.map((g) => g.name).join('-');
    return _verifySaltedHash(
      input: patternStr,
      storedHash: stored,
      onUpgrade: (newHash) => _storage.write(key: _patternKey, value: newHash),
    );
  }

  Future<bool> verifyPin(String pin) async {
    final stored = await _storage.read(key: _pinKey);
    if (stored == null) return false;

    return _verifySaltedHash(
      input: pin,
      storedHash: stored,
      onUpgrade: (newHash) => _storage.write(key: _pinKey, value: newHash),
    );
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

  // ─── Cryptographic Hashing & Salt ───────────────────────

  String _hashPattern(List<Gesture> pattern) {
    final patternStr = pattern.map((g) => g.name).join('-');
    return _hashInput(patternStr);
  }

  /// Hashes input with a cryptographically secure random 16-byte salt using HMAC-SHA256.
  /// Formatted as 'saltHex:hashHex'.
  String _hashInput(String input) {
    final saltBytes = _generateSecureSalt(16);
    final saltHex = saltBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    final hmac = Hmac(sha256, saltBytes);
    final digest = hmac.convert(utf8.encode(input));
    final hashHex = digest.toString();

    return '$saltHex:$hashHex';
  }

  /// Verifies input against stored hash using constant-time string comparison.
  /// Handles both salted ('salt:hash') and legacy unsalted formats with transparent upgrade.
  Future<bool> _verifySaltedHash({
    required String input,
    required String storedHash,
    required Future<void> Function(String newHash) onUpgrade,
  }) async {
    if (storedHash.contains(':')) {
      final parts = storedHash.split(':');
      if (parts.length != 2) return false;

      final saltHex = parts[0];
      final expectedHashHex = parts[1];

      final saltBytes = _hexToBytes(saltHex);
      final hmac = Hmac(sha256, saltBytes);
      final computedDigest = hmac.convert(utf8.encode(input));
      final computedHashHex = computedDigest.toString();

      return _constantTimeEquals(computedHashHex, expectedHashHex);
    } else {
      // Legacy unsalted SHA-256 fallback
      final legacyDigest = sha256.convert(utf8.encode(input)).toString();
      final isMatch = _constantTimeEquals(legacyDigest, storedHash);
      if (isMatch) {
        // Upgrade legacy hash to modern salted format
        final upgradedHash = _hashInput(input);
        await onUpgrade(upgradedHash);
      }
      return isMatch;
    }
  }

  /// Generates cryptographically secure random bytes for salting.
  List<int> _generateSecureSalt(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  List<int> _hexToBytes(String hex) {
    final bytes = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  /// Constant-time comparison to prevent side-channel timing attacks.
  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) {
      return false;
    }
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
  }
}
