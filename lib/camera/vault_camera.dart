import 'dart:io';

import 'package:flutter/services.dart';

/// What the opened camera offers (from VaultCamera.kt).
class CameraInfo {
  final int textureId;

  /// Preview buffer size, in the sensor's orientation (usually landscape).
  final int width;
  final int height;
  final int sensorOrientation;

  /// Whether Flutter applies the buffer's rotation itself; if not, the
  /// preview is turned by [sensorOrientation] (and mirrored for the front
  /// camera) in Dart.
  final bool handlesRotation;
  final bool front;
  final bool canSwitch;
  final bool hasFlash;
  final bool video;

  const CameraInfo({
    required this.textureId,
    required this.width,
    required this.height,
    required this.sensorOrientation,
    required this.handlesRotation,
    required this.front,
    required this.canSwitch,
    required this.hasFlash,
    required this.video,
  });

  factory CameraInfo.fromMap(Map<String, Object?> m) => CameraInfo(
        textureId: (m['textureId'] as num).toInt(),
        width: (m['width'] as num).toInt(),
        height: (m['height'] as num).toInt(),
        sensorOrientation: (m['sensorOrientation'] as num?)?.toInt() ?? 90,
        handlesRotation: m['handlesRotation'] == true,
        front: m['front'] == true,
        canSwitch: m['canSwitch'] == true,
        hasFlash: m['hasFlash'] == true,
        video: m['video'] == true,
      );
}

/// The in-vault camera. Photos come back as JPEG bytes stripped of
/// metadata; videos are encrypted to the vault's recording key as they're
/// recorded and staged like hidden recordings, then moved in by
/// [VaultProvider.importRecordings].
class VaultCamera {
  static const MethodChannel _channel = MethodChannel('app.vault/camera');

  static bool get isAvailable => Platform.isAndroid;

  static Future<CameraInfo> open({bool front = false, bool video = false}) async {
    final m = await _channel.invokeMapMethod<String, Object?>('open', {'front': front, 'video': video});
    return CameraInfo.fromMap(m!);
  }

  /// Takes a photo. The JPEG keeps only its orientation tag.
  static Future<({Uint8List data, int width, int height})> photo() async {
    final m = (await _channel.invokeMapMethod<String, Object?>('photo'))!;
    return (
      data: m['data'] as Uint8List,
      width: (m['width'] as num).toInt(),
      height: (m['height'] as num).toInt(),
    );
  }

  /// Starts recording video, encrypted to [publicKey] (the vault's
  /// recording key). Returns the staged file's id and whether there's sound.
  static Future<({String id, bool audio})> startVideo(Uint8List publicKey, {bool audio = true}) async {
    final m = (await _channel.invokeMapMethod<String, Object?>('startVideo', {'key': publicKey, 'audio': audio}))!;
    return (id: m['id'] as String, audio: m['audio'] == true);
  }

  /// Stops and finishes the staged file. [error] says why it ended early.
  static Future<({String id, Duration duration, String? error})?> stopVideo() async {
    final m = await _channel.invokeMapMethod<String, Object?>('stopVideo');
    if (m == null) return null;
    return (
      id: m['id'] as String,
      duration: Duration(milliseconds: (m['durationMs'] as num?)?.toInt() ?? 0),
      error: m['error'] as String?,
    );
  }

  static Future<bool> torch(bool on) async => await _channel.invokeMethod<bool>('torch', {'on': on}) ?? false;

  /// Stops any video (it's kept) and releases the camera.
  static Future<void> close() => _channel.invokeMethod('close');
}
