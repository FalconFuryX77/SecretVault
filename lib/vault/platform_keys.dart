import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'crypto_primitives.dart';

/// Binds key derivation to this physical device.
///
/// On Android the input is HMAC'd with a non-exportable key in the hardware
/// keystore (TEE / StrongBox). An attacker who copies the container off the
/// phone therefore cannot brute-force PINs or gestures offline — every guess
/// has to go through this device's secure hardware.
abstract class DeviceBinding {
  Future<Uint8List> bind(Uint8List input);
}

/// Unlocks a vault key with a biometric, using a keystore key that the
/// hardware only releases after a successful strong-biometric prompt.
abstract class BiometricKeystore {
  Future<bool> isAvailable();

  /// Makes sure every slot alias exists, so the number of keys in the
  /// keystore never reveals how many vaults are set up.
  Future<void> ensureSlots(int count);

  /// Encrypts [secret] under slot [slot]'s biometric key. Shows a prompt.
  /// Returns null if the user cancels or biometrics fail.
  Future<Uint8List?> wrap(int slot, Uint8List secret, {required String reason});

  /// Reverses [wrap]. Shows a prompt. Returns null on cancel / failure.
  /// Throws [BiometricInvalidatedException] if the key was invalidated
  /// (for example because a new fingerprint was enrolled).
  Future<Uint8List?> unwrap(int slot, Uint8List blob, {required String reason});
}

class BiometricInvalidatedException implements Exception {}

const _channel = MethodChannel('app.vault/keys');

class AndroidDeviceBinding implements DeviceBinding {
  @override
  Future<Uint8List> bind(Uint8List input) async {
    final out = await _channel.invokeMethod<Uint8List>('deviceHmac', {
      'data': input,
    });
    if (out == null || out.length != 32) {
      throw StateError('device binding unavailable');
    }
    return out;
  }
}

/// Fallback for platforms without a native implementation (iOS for now,
/// desktop, tests). The secret lives in the platform secure storage, which is
/// weaker than a hardware-bound key but still not inside the container.
class SoftwareDeviceBinding implements DeviceBinding {
  static const _storageKey = 'db_k';
  final FlutterSecureStorage _storage;
  Uint8List? _secret;
  SoftwareDeviceBinding({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<Uint8List> bind(Uint8List input) async {
    if (_secret == null) {
      final stored = await _storage.read(key: _storageKey);
      if (stored != null) {
        _secret = base64Decode(stored);
      } else {
        _secret = CryptoPrimitives.randomBytes(32);
        await _storage.write(key: _storageKey, value: base64Encode(_secret!));
      }
    }
    return CryptoPrimitives.hmacSha256(_secret!, input);
  }
}

/// Deterministic in-memory binding for tests.
class FixedDeviceBinding implements DeviceBinding {
  final Uint8List secret;
  FixedDeviceBinding([Uint8List? secret]) : secret = secret ?? Uint8List(32);
  @override
  Future<Uint8List> bind(Uint8List input) =>
      CryptoPrimitives.hmacSha256(secret, input);
}

class AndroidBiometricKeystore implements BiometricKeystore {
  @override
  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('bioAvailable') ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> ensureSlots(int count) async {
    try {
      await _channel.invokeMethod('bioEnsureSlots', {'count': count});
    } on PlatformException {
      // Biometrics not enrolled / no secure lock screen. Gesture unlock is
      // simply unavailable; PIN still works.
    }
  }

  @override
  Future<Uint8List?> wrap(
    int slot,
    Uint8List secret, {
    required String reason,
  }) async {
    try {
      return await _channel.invokeMethod<Uint8List>('bioWrap', {
        'slot': slot,
        'data': secret,
        'reason': reason,
      });
    } on PlatformException catch (e) {
      if (e.code == 'invalidated') throw BiometricInvalidatedException();
      return null;
    }
  }

  @override
  Future<Uint8List?> unwrap(
    int slot,
    Uint8List blob, {
    required String reason,
  }) async {
    try {
      return await _channel.invokeMethod<Uint8List>('bioUnwrap', {
        'slot': slot,
        'data': blob,
        'reason': reason,
      });
    } on PlatformException catch (e) {
      if (e.code == 'invalidated') throw BiometricInvalidatedException();
      return null;
    }
  }
}

class UnavailableBiometricKeystore implements BiometricKeystore {
  @override
  Future<bool> isAvailable() async => false;
  @override
  Future<void> ensureSlots(int count) async {}
  @override
  Future<Uint8List?> wrap(
    int slot,
    Uint8List secret, {
    required String reason,
  }) async => null;
  @override
  Future<Uint8List?> unwrap(
    int slot,
    Uint8List blob, {
    required String reason,
  }) async => null;
}

DeviceBinding defaultDeviceBinding() =>
    Platform.isAndroid ? AndroidDeviceBinding() : SoftwareDeviceBinding();

BiometricKeystore defaultBiometricKeystore() => Platform.isAndroid
    ? AndroidBiometricKeystore()
    : UnavailableBiometricKeystore();
