import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'crypto_primitives.dart';

/// Binds key derivation to this physical device.
///
/// On Android the input is HMAC'd with a non-exportable key in the hardware
/// keystore (TEE / StrongBox). An attacker who copies the container off the
/// phone therefore cannot brute-force PINs offline — every guess
/// has to go through this device's secure hardware.
abstract class DeviceBinding {
  Future<Uint8List> bind(Uint8List input);
}

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
    // Channel results are read-only views; copy so callers can wipe them.
    return Uint8List.fromList(out);
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

DeviceBinding defaultDeviceBinding() =>
    Platform.isAndroid ? AndroidDeviceBinding() : SoftwareDeviceBinding();
