import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Thrown when authenticated decryption fails or a structure doesn't verify.
class IntegrityException implements Exception {
  final String message;
  IntegrityException(this.message);
  @override
  String toString() => 'IntegrityException: $message';
}

final Random _rng = Random.secure();
final AesGcm _aead = AesGcm.with256bits();
final Hmac _hmac = Hmac.sha256();

Uint8List randomBytes(int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = _rng.nextInt(256);
  }
  return out;
}

/// `nonce(12) ‖ ciphertext ‖ tag(16)`
Future<Uint8List> seal(List<int> key, List<int> plain, List<int> aad, {List<int>? nonce}) async {
  nonce ??= randomBytes(12);
  if (nonce.length != 12) throw ArgumentError('nonce must be 12 bytes');
  final box = await _aead.encrypt(plain, secretKey: SecretKeyData(key), nonce: nonce, aad: aad);
  return Uint8List.fromList([...nonce, ...box.cipherText, ...box.mac.bytes]);
}

Future<Uint8List> open(List<int> key, Uint8List sealed, List<int> aad) async {
  if (sealed.length < 28) throw IntegrityException('ciphertext too short');
  try {
    final plain = await _aead.decrypt(
      SecretBox(
        sealed.sublist(12, sealed.length - 16),
        nonce: sealed.sublist(0, 12),
        mac: Mac(sealed.sublist(sealed.length - 16)),
      ),
      secretKey: SecretKeyData(key),
      aad: aad,
    );
    return Uint8List.fromList(plain);
  } on SecretBoxAuthenticationError {
    throw IntegrityException('authentication failed');
  }
}

Future<Uint8List> hmacSha256(List<int> key, List<int> data) async =>
    Uint8List.fromList((await _hmac.calculateMac(data, secretKey: SecretKeyData(key))).bytes);

Future<Uint8List> sha256(List<int> data) async => Uint8List.fromList((await Sha256().hash(data)).bytes);

Future<Uint8List> hkdf(List<int> ikm, String info, {List<int> salt = const []}) async {
  // RFC 5869 defines "no salt" as HashLen zero bytes, and HMAC zero-pads
  // short keys, so passing 32 zeros gives exactly the same output as an
  // empty salt. It has to be explicit: Android's native HMAC (used through
  // cryptography_flutter) throws "Empty key" on a zero-length key.
  final effectiveSalt = salt.isEmpty ? Uint8List(32) : salt;
  final k = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
      .deriveKey(secretKey: SecretKeyData(ikm), nonce: effectiveSalt, info: utf8.encode(info));
  return Uint8List.fromList(await k.extractBytes());
}

String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String s) {
  if (s.length.isOdd) throw FormatException('odd hex length');
  return Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
}
