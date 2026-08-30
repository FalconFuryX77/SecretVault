import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/gesture.dart';
import '../models/gesture_template.dart';

/// Handles secure storage and verification of 3D Wand gesture templates,
/// dual-vault credentials (Primary vs Decoy), fallback PINs, and lockout timers.
/// Uses cryptographically salted HMAC-SHA256 with constant-time verification.
class AuthService {
  static const _patternKey = 'gesture_pattern';
  static const _pinKey = 'fallback_pin';
  static const _decoyPinKey = 'fallback_decoy_pin';
  static const _masterTemplateKey = 'master_wand_template';
  static const _decoyTemplateKey = 'decoy_wand_template';
  static const _setupCompleteKey = 'setup_complete';
  static const _lockoutEndKey = 'lockout_end_time';
  static const _failedAttemptsKey = 'failed_attempts';
  static const _autoLockOnSwitchKey = 'auto_lock_on_switch';
  static const _inactivityTimeoutKey = 'inactivity_timeout_seconds';

  final FlutterSecureStorage _storage;

  AuthService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  // ─── Setup & Status ─────────────────────────────────────

  Future<bool> isSetupComplete() async {
    final val = await _storage.read(key: _setupCompleteKey);
    return val == 'true';
  }

  Future<void> saveCredentials({
    required List<Gesture> pattern,
    required String pin,
    GestureTemplate? masterTemplate,
    GestureTemplate? decoyTemplate,
    String? decoyPin,
  }) async {
    final patternHash = _hashPattern(pattern);
    final pinHash = _hashInput(pin);
    await _storage.write(key: _patternKey, value: patternHash);
    await _storage.write(key: _pinKey, value: pinHash);

    if (masterTemplate != null) {
      await _storage.write(key: _masterTemplateKey, value: masterTemplate.toJson());
    }
    if (decoyTemplate != null) {
      await _storage.write(key: _decoyTemplateKey, value: decoyTemplate.toJson());
    }
    if (decoyPin != null && decoyPin.isNotEmpty) {
      final decoyPinHash = _hashInput(decoyPin);
      await _storage.write(key: _decoyPinKey, value: decoyPinHash);
    }

    await _storage.write(key: _setupCompleteKey, value: 'true');
  }

  // ─── 3D Wand Templates ──────────────────────────────────

  Future<void> saveMasterTemplate(GestureTemplate template) async {
    await _storage.write(key: _masterTemplateKey, value: template.toJson());
    await _storage.write(key: _setupCompleteKey, value: 'true');
  }

  Future<GestureTemplate?> getMasterTemplate() async {
    final jsonStr = await _storage.read(key: _masterTemplateKey);
    if (jsonStr == null || jsonStr.isEmpty) return null;
    try {
      return GestureTemplate.fromJson(jsonStr);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveDecoyTemplate(GestureTemplate template) async {
    await _storage.write(key: _decoyTemplateKey, value: template.toJson());
  }

  Future<GestureTemplate?> getDecoyTemplate() async {
    final jsonStr = await _storage.read(key: _decoyTemplateKey);
    if (jsonStr == null || jsonStr.isEmpty) return null;
    try {
      return GestureTemplate.fromJson(jsonStr);
    } catch (_) {
      return null;
    }
  }

  Future<bool> hasDecoyTemplate() async {
    final template = await getDecoyTemplate();
    return template != null;
  }

  // ─── PIN & Legacy Pattern Verification ──────────────────

  Future<void> updatePattern(List<Gesture> pattern) async {
    final patternHash = _hashPattern(pattern);
    await _storage.write(key: _patternKey, value: patternHash);
  }

  Future<void> updatePin(String pin) async {
    final pinHash = _hashInput(pin);
    await _storage.write(key: _pinKey, value: pinHash);
  }

  Future<void> updateDecoyPin(String pin) async {
    final pinHash = _hashInput(pin);
    await _storage.write(key: _decoyPinKey, value: pinHash);
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

  Future<VaultType?> verifyPinWithType(String pin) async {
    // Check Master PIN
    final storedMaster = await _storage.read(key: _pinKey);
    if (storedMaster != null) {
      final isMaster = _verifySaltedHash(
        input: pin,
        storedHash: storedMaster,
        onUpgrade: (newHash) => _storage.write(key: _pinKey, value: newHash),
      );
      if (isMaster) return VaultType.primary;
    }

    // Check Decoy PIN
    final storedDecoy = await _storage.read(key: _decoyPinKey);
    if (storedDecoy != null) {
      final isDecoy = _verifySaltedHash(
        input: pin,
        storedHash: storedDecoy,
        onUpgrade: (newHash) => _storage.write(key: _decoyPinKey, value: newHash),
      );
      if (isDecoy) return VaultType.decoy;
    }

    return null;
  }

  Future<bool> verifyPin(String pin) async {
    final type = await verifyPinWithType(pin);
    return type != null;
  }

  // ─── Lockout Persistence ────────────────────────────────

  Future<void> setLockoutEndTime(DateTime endTime) async {
    await _storage.write(
      key: _lockoutEndKey,
      value: endTime.toIso8601String(),
    );
  }

  Future<DateTime?> getLockoutEndTime() async {
    final val = await _storage.read(key: _lockoutEndKey);
    if (val == null) return null;
    final dt = DateTime.tryParse(val);
    if (dt == null || dt.isBefore(DateTime.now())) {
      await clearLockout();
      return null;
    }
    return dt;
  }

  Future<void> clearLockout() async {
    await _storage.delete(key: _lockoutEndKey);
    await _storage.write(key: _failedAttemptsKey, value: '0');
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

  // ─── Cryptographic Hash & Verification Helpers ──────────

  String _hashPattern(List<Gesture> pattern) {
    final patternStr = pattern.map((g) => g.name).join('-');
    return _createSaltedHash(patternStr);
  }

  String _hashInput(String input) {
    return _createSaltedHash(input);
  }

  String _createSaltedHash(String input) {
    final saltBytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final saltHex = saltBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

    final hmac = Hmac(sha256, saltBytes);
    final digest = hmac.convert(utf8.encode(input));

    return '$saltHex:${digest.toString()}';
  }

  bool _verifySaltedHash({
    required String input,
    required String storedHash,
    void Function(String newHash)? onUpgrade,
  }) {
    final parts = storedHash.split(':');
    if (parts.length != 2) {
      final legacyDigest = sha256.convert(utf8.encode(input)).toString();
      final matches = _constantTimeCompare(legacyDigest, storedHash);
      if (matches && onUpgrade != null) {
        onUpgrade(_createSaltedHash(input));
      }
      return matches;
    }

    final saltHex = parts[0];
    final hashHex = parts[1];

    final saltBytes = <int>[];
    for (int i = 0; i < saltHex.length; i += 2) {
      saltBytes.add(int.parse(saltHex.substring(i, i + 2), radix: 16));
    }

    final hmac = Hmac(sha256, saltBytes);
    final computedDigest = hmac.convert(utf8.encode(input)).toString();

    return _constantTimeCompare(computedDigest, hashHex);
  }

  bool _constantTimeCompare(String a, String b) {
    if (a.length != b.length) return false;
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
  }
}
