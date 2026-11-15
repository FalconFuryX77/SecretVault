import 'dart:io';
import 'dart:typed_data';

import 'crypto.dart';

/// A piece of a file: [offset, offset + length).
class ChunkRef {
  final int offset;
  final int length;
  const ChunkRef(this.offset, this.length);
  int get end => offset + length;
  @override
  String toString() => 'ChunkRef($offset, $length)';
}

/// Keyed FastCDC content-defined chunking (Xia et al., 2016, with
/// normalised chunking).
///
/// Boundaries depend on the content (so an edit only changes nearby pieces
/// and identical content dedupes) *and* on a secret key (so piece sizes
/// can't be used to fingerprint known files, see THREAT_MODEL A5).
class Chunker {
  final int minSize;
  final int avgSize;
  final int maxSize;
  final List<int> _gear;
  final int _maskS;
  final int _maskL;

  Chunker._(this._gear, this.minSize, this.avgSize, this.maxSize)
      : _maskS = _highBits(_log2(avgSize) + 2),
        _maskL = _highBits(_log2(avgSize) - 2);

  /// Gear table: 256 64-bit values from HMAC-SHA256(kCdc, [i]).
  static Future<Chunker> keyed(
    Uint8List kCdc, {
    int minSize = 64 * 1024,
    int avgSize = 256 * 1024,
    int maxSize = 1024 * 1024,
  }) async {
    if (!(minSize < avgSize && avgSize < maxSize)) throw ArgumentError('need min < avg < max');
    if (avgSize & (avgSize - 1) != 0) throw ArgumentError('avgSize must be a power of two');
    final gear = <int>[];
    for (var i = 0; i < 256; i++) {
      final m = await hmacSha256(kCdc, [i]);
      gear.add(ByteData.sublistView(m).getUint64(0));
    }
    return Chunker._(gear, minSize, avgSize, maxSize);
  }

  static int _log2(int v) => v.bitLength - 1;

  /// A mask of the top [n] bits of a 64-bit word. Gear-hash high bits
  /// depend on the most recent ~64 bytes.
  static int _highBits(int n) => ((1 << n) - 1) << (64 - n);

  /// Cut points for a whole in-memory buffer.
  List<ChunkRef> chunkBytes(Uint8List data) {
    final out = <ChunkRef>[];
    final s = ChunkerState();
    feed(s, data, out);
    final tail = finish(s);
    if (tail != null) out.add(tail);
    return out;
  }

  /// Incremental chunking: call [feed] with each block in order (completed
  /// pieces are appended to [out]), then [finish] for the last piece.
  void feed(ChunkerState s, Uint8List data, List<ChunkRef> out) => _feed(s, data, 0, out);

  ChunkRef? finish(ChunkerState s) => s.len > 0 ? ChunkRef(s.start, s.len) : null;

  /// Cut points for a file, read in 1 MiB blocks (constant memory).
  Future<List<ChunkRef>> chunkFile(File file) async {
    final out = <ChunkRef>[];
    final s = ChunkerState();
    final raf = await file.open();
    try {
      final buf = Uint8List(1024 * 1024);
      var pos = 0;
      while (true) {
        final n = raf.readIntoSync(buf);
        if (n == 0) break;
        _feed(s, Uint8List.sublistView(buf, 0, n), pos, out);
        pos += n;
      }
    } finally {
      await raf.close();
    }
    if (s.len > 0) out.add(ChunkRef(s.start, s.len));
    return out;
  }

  void _feed(ChunkerState s, Uint8List data, int base, List<ChunkRef> out) {
    var fp = s.fp;
    var len = s.len;
    var start = s.start;
    for (var i = 0; i < data.length; i++) {
      fp = (fp << 1) + _gear[data[i]]; // wraps mod 2^64 on the Dart VM
      len++;
      if (len < minSize) continue;
      final mask = len < avgSize ? _maskS : _maskL;
      if ((fp & mask) == 0 || len >= maxSize) {
        out.add(ChunkRef(start, len));
        start += len;
        len = 0;
        fp = 0;
      }
    }
    s
      ..fp = fp
      ..len = len
      ..start = start;
    // `base` is implied by `start` accumulating across calls.
    assert(base >= 0);
  }
}

/// Progress of one incremental chunking run.
class ChunkerState {
  int fp = 0;
  int len = 0;
  int start = 0;
}
