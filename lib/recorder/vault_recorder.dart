import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';

import '../vault/vault_container.dart';

class RecorderStatus {
  final bool armed;
  final bool recording;
  final DateTime? startedAt;
  final String? error;
  final int triggers;

  /// Short hashes of the public keys the recorder is armed with / recording
  /// to, so a vault only shows the recorder state that belongs to it.
  final String? armedKey;
  final String? recordingKey;

  const RecorderStatus({
    this.armed = false,
    this.recording = false,
    this.startedAt,
    this.error,
    this.triggers = 0,
    this.armedKey,
    this.recordingKey,
  });
}

class PendingRecording {
  final String id;
  final int size;
  final DateTime modified;
  const PendingRecording(this.id, this.size, this.modified);
}

class OpenedRecording {
  final Uint8List data;
  final String ext;
  final DateTime startedAt;
  final Duration duration;

  /// False if the recording was cut short (the phone died or the app was
  /// killed mid-recording); everything up to the last second is kept.
  final bool complete;

  /// This vault's recording, but with no audio in it (the recorder failed
  /// before it captured anything): discard it.
  final bool empty;
  const OpenedRecording(this.data, this.ext, this.startedAt, this.duration, this.complete) : empty = false;
  OpenedRecording.empty()
      : data = Uint8List(0),
        ext = '',
        startedAt = DateTime.fromMillisecondsSinceEpoch(0),
        duration = Duration.zero,
        complete = false,
        empty = true;
}

/// The native recorder (RecorderService.kt): records into files encrypted
/// to the vault's public key, so recording works with the vault locked and
/// the phone can't read the recordings back without the vault.
class VaultRecorder {
  static const MethodChannel _channel = MethodChannel('app.vault/recorder');

  static bool get isAvailable => Platform.isAndroid;

  static Future<RecorderStatus> status() async {
    if (!isAvailable) return const RecorderStatus();
    final m = (await _channel.invokeMapMethod<String, Object?>('status')) ?? const {};
    final started = (m['startedAt'] as num?)?.toInt() ?? 0;
    return RecorderStatus(
      armed: m['armed'] == true,
      recording: m['recording'] == true,
      startedAt: started > 0 ? DateTime.fromMillisecondsSinceEpoch(started) : null,
      error: m['error'] as String?,
      triggers: (m['triggers'] as num?)?.toInt() ?? 0,
      armedKey: m['armedKey'] as String?,
      recordingKey: m['recordingKey'] as String?,
    );
  }

  static Future<({Uint8List pub, Uint8List priv})> newKeyPair() async {
    final m = (await _channel.invokeMapMethod<String, Object?>('keyPair'))!;
    return (pub: m['pub'] as Uint8List, priv: m['priv'] as Uint8List);
  }

  /// Starts listening for volume-down ×3 while the screen is off.
  /// [alwaysListen] also listens with the screen on (tests only).
  static Future<void> arm(Uint8List publicKey, {bool vibrate = true, bool alwaysListen = false}) =>
      _channel.invokeMethod('arm', {'key': publicKey, 'vibrate': vibrate, 'alwaysListen': alwaysListen});

  static Future<void> disarm() => _channel.invokeMethod('disarm');

  /// [rotateFrames] is for tests: start a new file after that many frames
  /// instead of every 30 minutes.
  static Future<void> record(Uint8List publicKey, {int? rotateFrames}) =>
      _channel.invokeMethod('record', {'key': publicKey, 'rotateFrames': ?rotateFrames});

  static Future<void> stop() => _channel.invokeMethod('stop');

  /// Finished recordings waiting to be moved into a vault (any vault's).
  static Future<List<PendingRecording>> pending() async {
    if (!isAvailable) return const [];
    final list = (await _channel.invokeListMethod<Object?>('pending')) ?? const [];
    return [
      for (final e in list.cast<Map<Object?, Object?>>())
        PendingRecording(
          e['id'] as String,
          (e['size'] as num).toInt(),
          DateTime.fromMillisecondsSinceEpoch((e['modified'] as num).toInt()),
        ),
    ];
  }

  /// Decrypts a pending recording with a vault's private key; null if it
  /// belongs to another vault.
  static Future<OpenedRecording?> open(String id, Uint8List privateKey) async {
    final m = await _channel.invokeMapMethod<String, Object?>('open', {'id': id, 'key': privateKey});
    if (m == null) return null;
    if (m['empty'] == true) return OpenedRecording.empty();
    return OpenedRecording(
      m['data'] as Uint8List,
      m['ext'] as String,
      DateTime.fromMillisecondsSinceEpoch((m['startedAt'] as num).toInt()),
      Duration(milliseconds: (m['durationMs'] as num).toInt()),
      m['complete'] == true,
    );
  }

  /// Overwrites a pending recording and deletes it.
  static Future<void> discard(String id) => _channel.invokeMethod('discard', {'id': id});

  static Future<String> stagingPath() async => (await _channel.invokeMethod<String>('stagingPath'))!;

  /// The short hash the native side reports for a public key.
  static Future<String> keyId(Uint8List publicKey) async {
    final h = await Sha256().hash(publicKey);
    return h.bytes.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// A vault's recording key pair, kept in its encrypted settings. Each vault
/// (real or decoy) has its own, so neither can open the other's recordings.
class RecordingKeys {
  static const String extraKey = 'rec.key';

  static Map<String, dynamic>? _stored(VaultSession s) => s.extras[extraKey] as Map<String, dynamic>?;

  /// The public key, creating the pair the first time.
  static Future<Uint8List> publicKey(VaultSession s) async {
    final stored = _stored(s);
    if (stored != null) return base64.decode(stored['pub'] as String);
    final kp = await VaultRecorder.newKeyPair();
    // The private key arrives read-only from the platform channel, so it
    // can't be wiped here; from now on it lives only in the vault index.
    await s.putExtra(extraKey, {'pub': base64.encode(kp.pub), 'priv': base64.encode(kp.priv)});
    return kp.pub;
  }

  static Uint8List? privateKey(VaultSession s) {
    final stored = _stored(s);
    return stored == null ? null : base64.decode(stored['priv'] as String);
  }

  static bool hasKeys(VaultSession s) => _stored(s) != null;

  /// Hash of this vault's public key, to match against [RecorderStatus].
  static Future<String?> id(VaultSession s) async {
    final stored = _stored(s);
    return stored == null ? null : VaultRecorder.keyId(base64.decode(stored['pub'] as String));
  }

  static const String vibrateKey = 'rec.vibrate';
  static bool vibrate(VaultSession s) => s.extras[vibrateKey] as bool? ?? true;
}
