import 'package:flutter/services.dart';

/// One video the trimmer saved (in Movies/Video Trimmer).
class TrimmedClip {
  final String uri;
  final String name;
  final Duration duration;
  final int size;
  final DateTime added;
  const TrimmedClip(this.uri, this.name, this.duration, this.size, this.added);
}

/// The cover app's video work (VideoTrimmer.kt).
class VideoTrimmer {
  static const MethodChannel _ch = MethodChannel('app.trim/video');

  /// A video from the phone's photo picker; null if cancelled.
  static Future<String?> pick() => _ch.invokeMethod<String>('pick');

  static Future<({Duration duration, int width, int height, int rotation})> info(String uri) async {
    final m = (await _ch.invokeMapMethod<String, Object?>('info', {'uri': uri}))!;
    return (
      duration: Duration(milliseconds: (m['durationMs'] as num).toInt()),
      width: (m['width'] as num).toInt(),
      height: (m['height'] as num).toInt(),
      rotation: (m['rotation'] as num).toInt(),
    );
  }

  /// A small JPEG of the frame near [at]; null if none.
  static Future<Uint8List?> frame(String uri, Duration at, {int maxSide = 320}) =>
      _ch.invokeMethod<Uint8List>('frame', {'uri': uri, 'timeMs': at.inMilliseconds, 'maxSide': maxSide});

  /// Cuts [start]..[end] into a new video; returns its address.
  static Future<String> trim(String uri, Duration start, Duration end, {bool mute = false}) async =>
      (await _ch.invokeMethod<String>('trim', {
        'uri': uri,
        'startMs': start.inMilliseconds,
        'endMs': end.inMilliseconds,
        'mute': mute,
      }))!;

  static Future<List<TrimmedClip>> recent() async {
    final list = (await _ch.invokeListMethod<Object?>('recent')) ?? const [];
    return [
      for (final m in list.cast<Map<Object?, Object?>>())
        TrimmedClip(
          m['uri'] as String,
          m['name'] as String? ?? 'Trim.mp4',
          Duration(milliseconds: (m['durationMs'] as num?)?.toInt() ?? 0),
          (m['size'] as num?)?.toInt() ?? 0,
          DateTime.fromMillisecondsSinceEpoch((m['added'] as num?)?.toInt() ?? 0),
        ),
    ];
  }

  static Future<bool> delete(String uri) async => await _ch.invokeMethod<bool>('delete', {'uri': uri}) ?? false;

  /// Plays it in the phone's own video app.
  static Future<bool> view(String uri) async => await _ch.invokeMethod<bool>('view', {'uri': uri}) ?? false;
}

String formatClock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}
