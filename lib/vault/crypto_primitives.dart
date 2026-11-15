import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

/// Thrown when authenticated decryption fails: wrong key, or the ciphertext
/// was modified, truncated, reordered or swapped with another chunk.
class TamperedDataException implements Exception {
  final String message;
  TamperedDataException(this.message);
  @override
  String toString() => 'TamperedDataException: $message';
}

/// Argon2id cost parameters. Production values are tuned so a PIN attempt
/// costs roughly 1–3 s on a mid-range phone; tests use cheap values.
class KdfParams {
  final int memoryKiB;
  final int iterations;
  const KdfParams({required this.memoryKiB, required this.iterations});

  /// For the PIN / passphrase.
  static const pin = KdfParams(memoryKiB: 64 * 1024, iterations: 3);

  /// Cheap parameters for unit tests only.
  static const testing = KdfParams(memoryKiB: 64, iterations: 1);
}

/// Thin wrapper over AES-256-GCM, HKDF-SHA256 and Argon2id.
///
/// AES-GCM goes through `Cryptography.instance`, so on Android it runs
/// natively once `FlutterCryptography.enable()` has been called.
class CryptoPrimitives {
  CryptoPrimitives._();

  static const int keyLen = 32;
  static const int nonceLen = 12;
  static const int tagLen = 16;

  static final Random _rng = Random.secure();
  static final AesGcm _aead = AesGcm.with256bits();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: keyLen);

  static Uint8List randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _rng.nextInt(256);
    }
    return out;
  }

  /// Produces [length] bytes indistinguishable from ciphertext, used to fill
  /// unused container space. Encrypting zeros under a throwaway key is much
  /// faster than `Random.secure()` byte-by-byte, and runs natively on Android.
  static Future<Uint8List> randomFill(int length) async {
    final key = SecretKeyData(randomBytes(keyLen));
    final box = await _aead.encrypt(
      Uint8List(length),
      secretKey: key,
      nonce: randomBytes(nonceLen),
    );
    return Uint8List.fromList(box.cipherText);
  }

  /// Seals [plain] and returns `nonce || ciphertext || tag`.
  static Future<Uint8List> seal(
    Uint8List key,
    List<int> plain,
    List<int> aad,
  ) async {
    final nonce = randomBytes(nonceLen);
    final box = await _aead.encrypt(
      plain,
      secretKey: SecretKeyData(key),
      nonce: nonce,
      aad: aad,
    );
    final out = Uint8List(nonceLen + plain.length + tagLen);
    out.setRange(0, nonceLen, nonce);
    out.setRange(nonceLen, nonceLen + plain.length, box.cipherText);
    out.setRange(nonceLen + plain.length, out.length, box.mac.bytes);
    return out;
  }

  /// Opens `nonce || ciphertext || tag`. Throws [TamperedDataException].
  static Future<Uint8List> open(
    Uint8List key,
    Uint8List sealed,
    List<int> aad,
  ) async {
    if (sealed.length < nonceLen + tagLen) {
      throw TamperedDataException('ciphertext too short');
    }
    final box = SecretBox(
      Uint8List.sublistView(sealed, nonceLen, sealed.length - tagLen),
      nonce: Uint8List.sublistView(sealed, 0, nonceLen),
      mac: Mac(Uint8List.sublistView(sealed, sealed.length - tagLen)),
    );
    try {
      final plain = await _aead.decrypt(
        box,
        secretKey: SecretKeyData(key),
        aad: aad,
      );
      return Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      throw TamperedDataException('authentication failed');
    }
  }

  /// Like [open] but returns null on failure, for trial-decrypting key slots.
  static Future<Uint8List?> tryOpen(
    Uint8List key,
    Uint8List sealed,
    List<int> aad,
  ) async {
    try {
      return await open(key, sealed, aad);
    } on TamperedDataException {
      return null;
    }
  }

  static Future<Uint8List> hkdf(
    Uint8List ikm, {
    required List<int> salt,
    required String info,
  }) async {
    final out = await _hkdf.deriveKey(
      secretKey: SecretKeyData(ikm),
      nonce: salt,
      info: utf8.encode(info),
    );
    return Uint8List.fromList(await out.extractBytes());
  }

  /// Argon2id, run on a background isolate so the UI stays responsive.
  static Future<Uint8List> argon2id(
    List<int> password,
    List<int> salt,
    KdfParams params,
  ) {
    final pw = Uint8List.fromList(password);
    final s = Uint8List.fromList(salt);
    final mem = params.memoryKiB;
    final it = params.iterations;
    return Isolate.run(() async {
      final algo = DartArgon2id(
        parallelism: 1,
        memory: mem,
        iterations: it,
        hashLength: keyLen,
      );
      final key = await algo.deriveKey(secretKey: SecretKeyData(pw), nonce: s);
      final bytes = Uint8List.fromList(await key.extractBytes());
      pw.fillRange(0, pw.length, 0);
      return bytes;
    });
  }

  static Future<Uint8List> hmacSha256(Uint8List key, List<int> data) async {
    final mac = await Hmac.sha256().calculateMac(
      data,
      secretKey: SecretKeyData(key),
    );
    return Uint8List.fromList(mac.bytes);
  }

  /// Best-effort zeroization. Dart can't guarantee no other copies exist,
  /// but this removes the long-lived ones we own.
  static void wipe(Uint8List? bytes) {
    if (bytes == null) return;
    try {
      bytes.fillRange(0, bytes.length, 0);
    } on UnsupportedError {
      // Read-only view (e.g. bytes handed back by a platform channel).
      // Nothing we own to clear; never let cleanup crash the caller.
    }
  }
}
