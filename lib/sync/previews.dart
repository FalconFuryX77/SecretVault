import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:sync_core/sync_core.dart';

import '../vault/vault_container.dart';
import '../vault/vault_index.dart';
import '../viewers/vault_media_server.dart';

/// A small copy of a vault item, for backup to send before the original
/// (SYNC_DESIGN §5). [close] frees what holds it.
class Preview {
  final SyncSource source;
  final int length;
  final String mime;
  final Future<void> Function() close;
  const Preview(this.source, this.length, this.mime, this.close);
}

/// Makes previews. The app's is [PlatformPreviewMaker]; tests pass their own.
abstract class PreviewMaker {
  /// Whether [entry] is worth a preview (a large enough photo, video or
  /// recording).
  bool wants(IndexEntry entry);

  /// A preview of [entry], or null if one can't be made or wouldn't be much
  /// smaller than the original.
  Future<Preview?> make(VaultSession session, IndexEntry entry);

  /// Whether the current network is free to use (Wi-Fi, Ethernet).
  Future<bool> unmetered();
}

/// Photos re-encoded at 1600 px (decoded in the isolated renderer), videos
/// at 480p and recordings at 32 kbit/s through Media3 Transformer. The
/// plaintext never touches storage: see PreviewMaker.kt.
class PlatformPreviewMaker implements PreviewMaker {
  static const MethodChannel _ch = MethodChannel('app.vault/preview');

  /// Below these the original is small enough to send as it is.
  final int imageMin, videoMin, audioMin;

  /// Photos are decoded in memory: larger ones get no preview.
  static const int imageMax = 64 << 20;

  /// A preview must be at most this share of the original's size to be
  /// worth sending.
  final double maxRatio;

  const PlatformPreviewMaker({
    this.imageMin = 1 << 20,
    this.videoMin = 4 << 20,
    this.audioMin = 2 << 20,
    this.maxRatio = 0.7,
  });

  String? _kind(IndexEntry e) {
    if (e.fileKey == null) return null;
    final mime = e.item.mimeType.toLowerCase();
    final n = e.byteLength;
    if (mime.startsWith('image/') && mime != 'image/gif' && mime != 'image/svg+xml') {
      return n >= imageMin && n <= imageMax ? 'image' : null;
    }
    if (mime.startsWith('video/')) return n >= videoMin ? 'video' : null;
    if (mime.startsWith('audio/')) return n >= audioMin ? 'audio' : null;
    return null;
  }

  @override
  bool wants(IndexEntry entry) => _kind(entry) != null;

  @override
  Future<bool> unmetered() async {
    try {
      return await _ch.invokeMethod<bool>('unmetered') ?? false;
    } on MissingPluginException {
      return true;
    }
  }

  bool _worthIt(int preview, int original) => preview > 0 && preview <= original * maxRatio;

  @override
  Future<Preview?> make(VaultSession session, IndexEntry entry) async {
    final kind = _kind(entry);
    if (kind == null) return null;
    if (kind == 'image') {
      final bytes = await session.readAll(entry);
      final jpeg = await _ch.invokeMethod<Uint8List>('image', {'data': bytes});
      bytes.fillRange(0, bytes.length, 0);
      if (jpeg == null || !_worthIt(jpeg.length, entry.byteLength)) return null;
      // (A buffer from the platform channel may be read-only: not wiped.)
      return Preview(MemorySyncSource(jpeg), jpeg.length, 'image/jpeg', () async {});
    }
    // Transformer reads the item from the same loopback stream the vault's
    // player uses; it's open only while the transcode runs.
    final ext = entry.item.title.contains('.') ? entry.item.title.split('.').last.toLowerCase() : 'bin';
    final server = await VaultMediaServer.start(
      length: entry.byteLength,
      contentType: entry.item.mimeType,
      extension: ext,
      read: (offset, length) => session.readRange(entry, offset, length),
    );
    final Map<Object?, Object?> r;
    try {
      r = (await _ch.invokeMethod<Map<Object?, Object?>>('transcode', {
        'url': server.uri.toString(),
        'audio': kind == 'audio',
      }))!;
    } finally {
      await server.close();
    }
    final id = r['id'] as int;
    final length = (r['length'] as num).toInt();
    Future<void> close() => _ch.invokeMethod<void>('close', {'id': id});
    if (!_worthIt(length, entry.byteLength)) {
      await close();
      return null;
    }
    return Preview(_NativeStream(id, length), length, kind == 'audio' ? 'audio/mp4' : 'video/mp4', close);
  }
}

/// The preview MP4 as the native side streams it: forward only, so going
/// back means opening it again (which re-reads the sealed staging file).
/// Backup reads it once whole, then piece by piece in order.
class _NativeStream implements SyncSource {
  static const MethodChannel _ch = PlatformPreviewMaker._ch;
  static const int _block = 1 << 20;
  final int id;
  final int length;
  int _pos = 0; // the native stream starts open at 0

  _NativeStream(this.id, this.length);

  Future<void> _reopen() async {
    if (await _ch.invokeMethod<bool>('open', {'id': id}) != true) throw StateError('preview is gone');
    _pos = 0;
  }

  Future<Uint8List> _read(int max) async {
    final b = await _ch.invokeMethod<Uint8List>('read', {'id': id, 'max': max}) ?? Uint8List(0);
    _pos += b.length;
    return b;
  }

  @override
  Stream<Uint8List> openRead() async* {
    await _reopen();
    while (true) {
      final b = await _read(_block);
      if (b.isEmpty) return;
      yield b;
    }
  }

  @override
  Future<Uint8List> readRange(int offset, int length) async {
    if (offset < _pos) await _reopen();
    while (_pos < offset) {
      if ((await _read(min(_block, offset - _pos))).isEmpty) throw RangeError.range(offset, 0, _pos);
    }
    final out = BytesBuilder(copy: false);
    while (out.length < length) {
      final b = await _read(min(_block, length - out.length));
      if (b.isEmpty) throw RangeError.range(offset + length, 0, _pos);
      out.add(b);
    }
    return out.takeBytes();
  }
}
