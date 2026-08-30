import 'dart:convert';
import 'dart:typed_data';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/gesture.dart';

/// Provides AES-256 encryption and decryption for sensitive user data,
/// supporting both Primary and Decoy vaults with independent cryptographic keys.
/// Includes memory zeroization for rapid panic lockouts.
class EncryptionService {
  static const String _primaryKeyStorageKey = 'secretvault_db_aes_key';
  static const String _decoyKeyStorageKey = 'secretvault_decoy_aes_key';

  final FlutterSecureStorage _storage;
  enc.Key? _cachedPrimaryKey;
  enc.Key? _cachedDecoyKey;

  EncryptionService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// Retrieve the 256-bit AES master key for the specified vault type.
  Future<enc.Key> _getMasterKey([VaultType vaultType = VaultType.primary]) async {
    if (vaultType == VaultType.primary && _cachedPrimaryKey != null) {
      return _cachedPrimaryKey!;
    }
    if (vaultType == VaultType.decoy && _cachedDecoyKey != null) {
      return _cachedDecoyKey!;
    }

    final storageKey = vaultType == VaultType.primary ? _primaryKeyStorageKey : _decoyKeyStorageKey;
    final storedKeyBase64 = await _storage.read(key: storageKey);

    if (storedKeyBase64 != null && storedKeyBase64.isNotEmpty) {
      final keyBytes = base64Decode(storedKeyBase64);
      final key = enc.Key(keyBytes);
      if (vaultType == VaultType.primary) {
        _cachedPrimaryKey = key;
      } else {
        _cachedDecoyKey = key;
      }
      return key;
    }

    // Generate a fresh cryptographically secure 256-bit key
    final newKey = enc.Key.fromSecureRandom(32);
    await _storage.write(key: storageKey, value: base64Encode(newKey.bytes));

    if (vaultType == VaultType.primary) {
      _cachedPrimaryKey = newKey;
    } else {
      _cachedDecoyKey = newKey;
    }
    return newKey;
  }

  /// Encrypts plaintext string using AES-256-CBC with a fresh random 16-byte IV.
  /// Returns a combined format: 'iv_base64:ciphertext_base64'.
  Future<String> encryptText(String plainText, [VaultType vaultType = VaultType.primary]) async {
    if (plainText.isEmpty) return '';

    final key = await _getMasterKey(vaultType);
    final iv = enc.IV.fromSecureRandom(16);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));

    final encrypted = encrypter.encrypt(plainText, iv: iv);
    return '${iv.base64}:${encrypted.base64}';
  }

  /// Decrypts a string in 'iv_base64:ciphertext_base64' format.
  Future<String> decryptText(String cipherText, [VaultType vaultType = VaultType.primary]) async {
    if (cipherText.isEmpty) return '';

    final parts = cipherText.split(':');
    if (parts.length != 2) {
      return cipherText;
    }

    try {
      final ivBytes = base64Decode(parts[0]);
      if (ivBytes.length != 16) {
        return cipherText;
      }
      final iv = enc.IV(ivBytes);
      final key = await _getMasterKey(vaultType);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));

      final encryptedData = enc.Encrypted.fromBase64(parts[1]);
      return encrypter.decrypt(encryptedData, iv: iv);
    } catch (_) {
      return cipherText;
    }
  }

  /// Encrypts raw binary file bytes (PDFs, Images, Videos) with AES-256.
  /// Returns a payload with 16 bytes IV prefix followed by cipher bytes.
  Future<Uint8List> encryptBytes(List<int> plainBytes, [VaultType vaultType = VaultType.primary]) async {
    if (plainBytes.isEmpty) return Uint8List(0);

    final key = await _getMasterKey(vaultType);
    final iv = enc.IV.fromSecureRandom(16);
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));

    final encrypted = encrypter.encryptBytes(plainBytes, iv: iv);

    final builder = BytesBuilder(copy: false);
    builder.add(iv.bytes);
    builder.add(encrypted.bytes);
    return builder.toBytes();
  }

  /// Decrypts binary payload (16 bytes IV prefix + cipher bytes).
  Future<Uint8List> decryptBytes(List<int> payload, [VaultType vaultType = VaultType.primary]) async {
    if (payload.length < 17) return Uint8List(0);

    try {
      final ivBytes = Uint8List.fromList(payload.sublist(0, 16));
      final cipherBytes = Uint8List.fromList(payload.sublist(16));

      final iv = enc.IV(ivBytes);
      final key = await _getMasterKey(vaultType);
      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));

      final decrypted = encrypter.decryptBytes(enc.Encrypted(cipherBytes), iv: iv);
      return Uint8List.fromList(decrypted);
    } catch (_) {
      // Corrupt padding or tampered data returns empty buffer safely
      return Uint8List(0);
    }
  }

  /// Securely zeroes out cached encryption keys in RAM memory.
  void clearMemoryKey() {
    if (_cachedPrimaryKey != null) {
      try {
        _cachedPrimaryKey!.bytes.fillRange(0, _cachedPrimaryKey!.bytes.length, 0);
      } catch (_) {}
      _cachedPrimaryKey = null;
    }
    if (_cachedDecoyKey != null) {
      try {
        _cachedDecoyKey!.bytes.fillRange(0, _cachedDecoyKey!.bytes.length, 0);
      } catch (_) {}
      _cachedDecoyKey = null;
    }
  }
}
