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

/// A staged camera video, opened for streaming as an MP4 of [length] bytes.
class StagedVideo {
  final int handle;
  final int length;
  final DateTime startedAt;
  final Duration duration;
  final bool complete;
  const StagedVideo(this.handle, this.length, this.startedAt, this.duration, this.complete);

  /// This vault's, but nothing was recorded: discard it.
  static final StagedVideo empty = StagedVideo(-1, 0, DateTime.fromMillisecondsSinceEpoch(0), Duration.zero, false);
  bool get isEmpty => handle < 0;

  static const MethodChannel _channel = MethodChannel('app.vault/recorder');

  /// The next bytes of the MP4 (at most [max]); empty at the end.
  Future<Uint8List> read(int max) async =>
      (await _channel.invokeMethod<Uint8List>('videoRead', {'handle': handle, 'max': max})) ?? Uint8List(0);

  Future<void> close() async {
    if (!isEmpty) await _channel.invokeMethod('videoClose', {'handle': handle});
  }
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

  /// This vault's, but a video from the camera: it is too big for memory
  /// and moves in through [VaultRecorder.openVideo] instead.
  final bool video;
  const OpenedRecording(this.data, this.ext, this.startedAt, this.duration, this.complete)
      : empty = false,
        video = false;
  OpenedRecording.empty({this.video = false})
      : data = Uint8List(0),
        ext = '',
        startedAt = DateTime.fromMillisecondsSinceEpoch(0),
        duration = Duration.zero,
        complete = false,
        empty = !video;
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

  /// Starts listening for [trigger] (volume-down ×3 by default) while the
  /// screen is off. [alwaysListen] also listens with the screen on (tests
  /// only).
  static Future<void> arm(
    Uint8List publicKey, {
    bool vibrate = true,
    bool alwaysListen = false,
    TriggerSettings trigger = TriggerSettings.standard,
  }) =>
      _channel.invokeMethod('arm', {
        'key': publicKey,
        'vibrate': vibrate,
        'alwaysListen': alwaysListen,
        'button': trigger.button,
        'presses': trigger.presses,
        'assist': trigger.assist,
      });

  /// Whether the assistant-button entry point is switched on, and whether
  /// this app is the phone's digital assistant app.
  static Future<({bool enabled, bool holder})> assistState() async {
    if (!isAvailable) return (enabled: false, holder: false);
    final m = (await _channel.invokeMapMethod<String, Object?>('assistState')) ?? const {};
    return (enabled: m['enabled'] == true, holder: m['holder'] == true);
  }

  /// Offers (or stops offering) this app as a digital assistant app.
  static Future<void> setAssistEnabled(bool on) => _channel.invokeMethod('setAssistEnabled', {'on': on});

  /// Opens the system screen where the digital assistant app is chosen.
  static Future<bool> openAssistSettings() async =>
      await _channel.invokeMethod<bool>('openAssistSettings') ?? false;

  static Future<void> disarm() => _channel.invokeMethod('disarm');

  /// [rotateFrames] is for tests: start a new file after that many frames
  /// instead of every 30 minutes. [legacyV1] (tests, debug builds) writes
  /// the v2.1.0 file format.
  static Future<void> record(Uint8List publicKey, {int? rotateFrames, bool legacyV1 = false}) =>
      _channel.invokeMethod('record', {'key': publicKey, 'rotateFrames': ?rotateFrames, 'legacyV1': legacyV1});

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

  /// Decrypts a pending recording with one of a vault's key pairs; null if
  /// it isn't encrypted to that pair (another vault's, or an older pair's).
  static Future<OpenedRecording?> open(String id, RecordingKeyPair keys) async {
    final m = await _channel.invokeMapMethod<String, Object?>('open', {'id': id, 'key': keys.priv, 'pub': keys.pub});
    if (m == null) return null;
    if (m['video'] == true) return OpenedRecording.empty(video: true);
    if (m['empty'] == true) return OpenedRecording.empty();
    return OpenedRecording(
      m['data'] as Uint8List,
      m['ext'] as String,
      DateTime.fromMillisecondsSinceEpoch((m['startedAt'] as num).toInt()),
      Duration(milliseconds: (m['durationMs'] as num).toInt()),
      m['complete'] == true,
    );
  }

  /// Opens a staged camera video for streaming into the vault as an MP4.
  /// Null if it isn't encrypted to [keys].
  static Future<StagedVideo?> openVideo(String id, RecordingKeyPair keys) async {
    final m = await _channel.invokeMapMethod<String, Object?>('videoOpen', {'id': id, 'key': keys.priv, 'pub': keys.pub});
    if (m == null) return null;
    if (m['empty'] == true) return StagedVideo.empty;
    return StagedVideo(
      (m['handle'] as num).toInt(),
      (m['length'] as num).toInt(),
      DateTime.fromMillisecondsSinceEpoch((m['startedAt'] as num).toInt()),
      Duration(milliseconds: (m['durationMs'] as num).toInt()),
      m['complete'] == true,
    );
  }

  /// Debug builds: Android's own reading of an MP4 (tests).
  static Future<Map<String, Object?>> probeMedia(Uint8List mp4) async =>
      (await _channel.invokeMapMethod<String, Object?>('probeMedia', {'data': mp4}))!;

  /// Overwrites a pending recording and deletes it.
  static Future<void> discard(String id) => _channel.invokeMethod('discard', {'id': id});

  static Future<String> stagingPath() async => (await _channel.invokeMethod<String>('stagingPath'))!;

  /// The short hash the native side reports for a public key.
  static Future<String> keyId(Uint8List publicKey) async {
    final h = await Sha256().hash(publicKey);
    return h.bytes.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// One recording key pair (public X.509, private PKCS#8).
class RecordingKeyPair {
  final Uint8List pub;
  final Uint8List priv;
  const RecordingKeyPair(this.pub, this.priv);

  static RecordingKeyPair? fromJson(Object? m) {
    if (m is! Map) return null;
    final pub = m['pub'], priv = m['priv'];
    if (pub is! String || priv is! String) return null;
    return RecordingKeyPair(base64.decode(pub), base64.decode(priv));
  }

  void wipe() => priv.fillRange(0, priv.length, 0);
}

/// A vault's recording key pairs, kept in its encrypted settings. Each vault
/// (real or decoy) has its own, so neither can open the other's recordings.
///
/// The pair is replaced about once a day, at unlock, and a replaced pair is
/// forgotten a week later: flash storage can keep old copies of a staged
/// recording's blocks after it was shredded, and once its key is gone even
/// the vault can't read them.
class RecordingKeys {
  static const String extraKey = 'rec.key';
  static const String oldKey = 'rec.old';
  static const Duration rotateAfter = Duration(hours: 24);
  static const Duration keepRetired = Duration(days: 7);

  static Map<String, dynamic>? _stored(VaultSession s) => s.extras[extraKey] as Map<String, dynamic>?;

  /// The public key, creating the pair the first time.
  static Future<Uint8List> publicKey(VaultSession s) async {
    final stored = _stored(s);
    if (stored != null) return base64.decode(stored['pub'] as String);
    final kp = await _newPair();
    await s.putExtra(extraKey, kp);
    return base64.decode(kp['pub'] as String);
  }

  static Future<Map<String, Object?>> _newPair() async {
    final kp = await VaultRecorder.newKeyPair();
    // The private key arrives read-only from the platform channel, so it
    // can't be wiped here; from now on it lives only in the vault index.
    return {
      'pub': base64.encode(kp.pub),
      'priv': base64.encode(kp.priv),
      'at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  /// Every pair a staged recording of this vault may be encrypted to: the
  /// current one first, then retired ones. The caller wipes them.
  static List<RecordingKeyPair> all(VaultSession s) {
    final x = s.extras;
    return [
      ?RecordingKeyPair.fromJson(x[extraKey]),
      for (final o in (x[oldKey] as List?) ?? const []) ?RecordingKeyPair.fromJson(o),
    ];
  }

  static bool hasKeys(VaultSession s) => _stored(s) != null;

  /// Replaces the current pair if it's a day old and not in use for a
  /// recording right now, and forgets retired pairs after a week. If the
  /// hidden recorder is armed with the old pair, [rearm] is called with the
  /// new public key. Returns whether it rotated.
  static Future<bool> rotateIfDue(
    VaultSession s, {
    required RecorderStatus status,
    required Future<void> Function(Uint8List newPublicKey) rearm,
    DateTime? now,
  }) async {
    final stored = _stored(s);
    if (stored == null) return false;
    final t = (now ?? DateTime.now()).toUtc();
    final at = DateTime.tryParse(stored['at'] as String? ?? '');
    final currentId = await VaultRecorder.keyId(base64.decode(stored['pub'] as String));
    final old = [
      for (final o in (s.extras[oldKey] as List?) ?? const [])
        if (o is Map && t.difference(DateTime.tryParse(o['retired'] as String? ?? '') ?? t) < keepRetired) o,
    ];
    final due = at == null || t.difference(at) >= rotateAfter;
    if (!due || status.recordingKey == currentId) {
      // Only the pruning, if anything was pruned.
      final before = (s.extras[oldKey] as List?)?.length ?? 0;
      if (old.length != before) await s.putExtra(oldKey, old.isEmpty ? null : old);
      return false;
    }
    final fresh = await _newPair();
    await s.putExtras({
      extraKey: fresh,
      oldKey: [
        {'pub': stored['pub'], 'priv': stored['priv'], 'retired': t.toIso8601String()},
        ...old,
      ],
    });
    if (status.armed && status.armedKey == currentId) {
      await rearm(base64.decode(fresh['pub'] as String));
    }
    return true;
  }

  /// Hash of this vault's public key, to match against [RecorderStatus].
  static Future<String?> id(VaultSession s) async {
    final stored = _stored(s);
    return stored == null ? null : VaultRecorder.keyId(base64.decode(stored['pub'] as String));
  }

  static const String vibrateKey = 'rec.vibrate';
  static bool vibrate(VaultSession s) => s.extras[vibrateKey] as bool? ?? true;
}

/// What starts and stops a hidden recording. Each vault keeps its own, in
/// its encrypted settings.
class TriggerSettings {
  /// -1: volume-down, 1: volume-up, 0: no volume trigger.
  final int button;

  /// Presses of [button] needed, quickly one after another.
  final int presses;

  /// Whether the assistant button also starts and stops recording (needs
  /// this app chosen as the phone's digital assistant app).
  final bool assist;

  const TriggerSettings({this.button = -1, this.presses = 3, this.assist = false});

  static const TriggerSettings standard = TriggerSettings();
  static const int minPresses = 2;
  static const int maxPresses = 6;
  static const String extraKey = 'rec.trigger';

  bool get usesVolume => button != 0;

  /// At least one way to trigger it.
  bool get isUsable => usesVolume || assist;

  static TriggerSettings of(VaultSession s) {
    final m = s.extras[extraKey];
    if (m is! Map) return standard;
    final button = (m['button'] as num?)?.toInt() ?? -1;
    final presses = (m['presses'] as num?)?.toInt() ?? 3;
    return TriggerSettings(
      button: button.clamp(-1, 1),
      presses: presses.clamp(minPresses, maxPresses),
      assist: m['assist'] == true,
    );
  }

  Future<void> save(VaultSession s) =>
      s.putExtra(extraKey, {'button': button, 'presses': presses, 'assist': assist});

  TriggerSettings copyWith({int? button, int? presses, bool? assist}) => TriggerSettings(
        button: button ?? this.button,
        presses: presses ?? this.presses,
        assist: assist ?? this.assist,
      );

  String get volumeLabel => button > 0 ? 'Volume-up' : 'Volume-down';

  /// e.g. "volume-down ×3", "the assistant button", "volume-up ×4 or the
  /// assistant button".
  String describe() {
    final parts = [
      if (usesVolume) '${volumeLabel.toLowerCase()} ×$presses',
      if (assist) 'the assistant button',
    ];
    return parts.isEmpty ? 'nothing' : parts.join(' or ');
  }

  @override
  bool operator ==(Object other) =>
      other is TriggerSettings && other.button == button && other.presses == presses && other.assist == assist;

  @override
  int get hashCode => Object.hash(button, presses, assist);
}
