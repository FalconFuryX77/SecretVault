import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import 'crypto_primitives.dart';

/// The container's hot paths: sealing and opening many chunks, and filling
/// file regions with random data.
///
/// Per-call overhead matters far more than cipher speed here, so a platform
/// implementation handles a whole batch (typically 16 × 64 KiB) in one native
/// call. Every implementation must produce byte-identical formats:
///
/// * sealed chunk = `nonce(12) ‖ AES-256-GCM ciphertext ‖ tag(16)`, followed
///   by random padding up to `chunkSize`.
abstract class BulkCrypto {
  /// Seals each plaintext under [key] with its AAD and pads the result with
  /// random bytes to exactly [chunkSize] bytes.
  Future<List<Uint8List>> sealChunks(
    Uint8List key,
    List<Uint8List> plains,
    List<List<int>> aads,
    int chunkSize,
  );

  /// Opens sealed chunks (each exactly `nonce ‖ ciphertext ‖ tag`, no
  /// padding). Throws [TamperedDataException] if any chunk fails.
  Future<List<Uint8List>> openChunks(
    Uint8List key,
    List<Uint8List> sealed,
    List<List<int>> aads,
  );

  /// Overwrites `length` bytes at `offset` of [file] with data that can't be
  /// told apart from ciphertext. Extends the file if needed. [raf] is the
  /// caller's open handle to the same file.
  Future<void> fillRandom(
    RandomAccessFile raf,
    File file,
    int offset,
    int length, {
    void Function(double progress)? onProgress,
  });
}

/// Pure-Dart implementation (desktop, tests, iOS for now).
class DartBulkCrypto implements BulkCrypto {
  const DartBulkCrypto();

  @override
  Future<List<Uint8List>> sealChunks(
    Uint8List key,
    List<Uint8List> plains,
    List<List<int>> aads,
    int chunkSize,
  ) async {
    final out = <Uint8List>[];
    for (var i = 0; i < plains.length; i++) {
      final sealed = await CryptoPrimitives.seal(key, plains[i], aads[i]);
      if (sealed.length > chunkSize) throw ArgumentError('chunk overflow');
      final full = Uint8List(chunkSize)..setRange(0, sealed.length, sealed);
      if (sealed.length < chunkSize) {
        full.setRange(
          sealed.length,
          chunkSize,
          await CryptoPrimitives.randomFill(chunkSize - sealed.length),
        );
      }
      out.add(full);
    }
    return out;
  }

  @override
  Future<List<Uint8List>> openChunks(
    Uint8List key,
    List<Uint8List> sealed,
    List<List<int>> aads,
  ) async {
    final out = <Uint8List>[];
    for (var i = 0; i < sealed.length; i++) {
      out.add(await CryptoPrimitives.open(key, sealed[i], aads[i]));
    }
    return out;
  }

  @override
  Future<void> fillRandom(
    RandomAccessFile raf,
    File file,
    int offset,
    int length, {
    void Function(double progress)? onProgress,
  }) async {
    const step = 1024 * 1024;
    var done = 0;
    while (done < length) {
      final n = min(step, length - done);
      final data = await CryptoPrimitives.randomFill(n);
      raf.setPositionSync(offset + done);
      raf.writeFromSync(data);
      done += n;
      onProgress?.call(done / length);
    }
  }
}

/// Android implementation: one platform call per batch, using the system
/// AES-GCM (hardware-accelerated on ARMv8) on a background thread.
class AndroidBulkCrypto implements BulkCrypto {
  static const _channel = MethodChannel('app.vault/keys');

  /// Random fill is done in steps so callers still get progress.
  static const int _fillStep = 8 * 1024 * 1024;

  const AndroidBulkCrypto();

  @override
  Future<List<Uint8List>> sealChunks(
    Uint8List key,
    List<Uint8List> plains,
    List<List<int>> aads,
    int chunkSize,
  ) async {
    final out = await _channel.invokeListMethod<Uint8List>('gcmSealChunks', {
      'key': key,
      'plains': plains,
      'aads': aads.map(Uint8List.fromList).toList(),
      'chunkSize': chunkSize,
    });
    if (out == null || out.length != plains.length) {
      throw StateError('gcmSealChunks failed');
    }
    return out;
  }

  @override
  Future<List<Uint8List>> openChunks(
    Uint8List key,
    List<Uint8List> sealed,
    List<List<int>> aads,
  ) async {
    try {
      final out = await _channel.invokeListMethod<Uint8List>('gcmOpenChunks', {
        'key': key,
        'sealed': sealed,
        'aads': aads.map(Uint8List.fromList).toList(),
      });
      if (out == null || out.length != sealed.length) {
        throw StateError('gcmOpenChunks failed');
      }
      // Channel results are read-only views; callers may wipe what we return.
      return [for (final p in out) Uint8List.fromList(p)];
    } on PlatformException catch (e) {
      if (e.code == 'auth') {
        throw TamperedDataException(
          'authentication failed (chunk ${e.message})',
        );
      }
      rethrow;
    }
  }

  @override
  Future<void> fillRandom(
    RandomAccessFile raf,
    File file,
    int offset,
    int length, {
    void Function(double progress)? onProgress,
  }) async {
    var done = 0;
    while (done < length) {
      final n = min(_fillStep, length - done);
      await _channel.invokeMethod('fillRandom', {
        'path': file.path,
        'offset': offset + done,
        'length': n,
      });
      done += n;
      onProgress?.call(done / length);
    }
  }
}

BulkCrypto defaultBulkCrypto() =>
    Platform.isAndroid ? const AndroidBulkCrypto() : const DartBulkCrypto();
