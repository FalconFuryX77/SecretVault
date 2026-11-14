import 'dart:typed_data';

import 'package:gesture_unlock/vault/crypto_primitives.dart';
import 'package:gesture_unlock/vault/platform_keys.dart';

/// Simulates the hardware biometric keystore: one secret key per slot,
/// and a switch to make the "fingerprint" fail.
class FakeBiometrics implements BiometricKeystore {
  final Map<int, Uint8List> keys = {};
  bool succeed = true;
  int prompts = 0;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> ensureSlots(int count) async {
    for (var i = 0; i < count; i++) {
      keys.putIfAbsent(i, () => CryptoPrimitives.randomBytes(32));
    }
  }

  @override
  Future<Uint8List?> wrap(
    int slot,
    Uint8List secret, {
    required String reason,
  }) async {
    prompts++;
    if (!succeed) return null;
    return CryptoPrimitives.seal(keys[slot]!, secret, const []);
  }

  @override
  Future<Uint8List?> unwrap(
    int slot,
    Uint8List blob, {
    required String reason,
  }) async {
    prompts++;
    if (!succeed) return null;
    return CryptoPrimitives.tryOpen(keys[slot]!, blob, const []);
  }
}

