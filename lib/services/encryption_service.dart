import 'dart:convert';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Provides AES-256 encryption and decryption for sensitive user data.
/// Uses a securely stored 256-bit master key and unique random IV per encryption.
class EncryptionService {
  static const String _keyStorageKey = 'secretvault_db_aes_key';
  final FlutterSecureStorage _storage;
  enc.Key? _cachedKey;

  EncryptionService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// Retrieve the 256-bit AES master key or generate and persist one if not present.
  Future<enc.Key> _getMasterKey() async {
    if (_cachedKey != null) {
      return _cachedKey!;
    }

    final storedKeyBase64 = await _storage.read(key: _keyStorageKey);
    if (storedKeyBase64 != null && storedKeyBase64.isNotEmpty) {
      final keyBytes = base64Decode(storedKeyBase64);
      _cachedKey = enc.Key(keyBytes);
      return _cachedKey!;
    }

    // Generate a cryptographically secure 256-bit (32-byte) key
    final newKey = enc.Key.fromSecureRandom(32);
    await _storage.write(key: _keyStorageKey, value: base64Encode(newKey.bytes));
    _cachedKey = newKey;
    return _cachedKey!;
  }

  /// Encrypts plaintext string using AES-256-CBC with a fresh random 16-byte IV.
  /// Returns a combined format: 'iv_base64:ciphertext_base64'.
  Future<String> encryptText(String plainText) async {
    if (plainText.isEmpty) return '';

    final key = await _getMasterKey();
    final iv = enc.IV.fromSecureRandom(16);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));

    final encrypted = encrypter.encrypt(plainText, iv: iv);
    return '${iv.base64}:${encrypted.base64}';
  }

  /// Decrypts a previously encrypted string in 'iv_base64:ciphertext_base64' format.
  /// Falls back gracefully if legacy plaintext is encountered.
  Future<String> decryptText(String cipherText) async {
    if (cipherText.isEmpty) return '';

    // Check if the ciphertext is in format 'iv:cipher'
    final parts = cipherText.split(':');
    if (parts.length != 2) {
      // Legacy plaintext fallback
      return cipherText;
    }

    try {
      final ivBytes = base64Decode(parts[0]);
      if (ivBytes.length != 16) {
        return cipherText;
      }
      final iv = enc.IV(ivBytes);
      final key = await _getMasterKey();
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));

      final encryptedData = enc.Encrypted.fromBase64(parts[1]);
      return encrypter.decrypt(encryptedData, iv: iv);
    } catch (_) {
      // If decryption fails (e.g. invalid base64 or plaintext with a colon), return original
      return cipherText;
    }
  }

  /// Clears cached key in memory (e.g., when the vault is locked).
  void clearMemoryKey() {
    _cachedKey = null;
  }
}
