import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Reads [length] decrypted bytes at [offset] of the file being served.
typedef RangeReader = Future<Uint8List> Function(int offset, int length);

/// A byte range `[start, end]` (inclusive), as in an HTTP `Range` header.
typedef ByteRange = ({int start, int end});

/// Thrown by [VaultMediaServer.parseRange] for a range outside the file.
class UnsatisfiableRange implements Exception {}

/// Streams one vault file to the platform media player.
///
/// Android's player only takes a file or a URL, and a file would mean a
/// decrypted copy on flash storage, which can't be reliably erased. Instead
/// the player reads from this server, which decrypts just the 64 KiB chunks
/// each request needs, in memory:
///
/// * bound to 127.0.0.1 only, on a random port, so it is unreachable from
///   the network;
/// * the path holds 256 random bits, so other apps on the phone, which can
///   reach loopback, can't guess it;
/// * one file per server, closed as soon as the viewer closes; reads fail
///   once the vault locks.
class VaultMediaServer {
  /// Bytes decrypted and sent per step: enough to keep a player fed, small
  /// enough that a seek doesn't wait on data nobody asked for.
  static const int sendPiece = 256 * 1024;

  final HttpServer _server;
  final String _secretPath;
  final int length;
  final String contentType;
  final RangeReader _read;

  /// Called once if a read fails, e.g. a chunk fails its integrity check.
  final void Function(Object error)? onReadError;
  bool _reportedError = false;

  VaultMediaServer._(
    this._server,
    this._secretPath,
    this.length,
    this.contentType,
    this._read,
    this.onReadError,
  );

  static Future<VaultMediaServer> start({
    required int length,
    required String contentType,
    required RangeReader read,
    String extension = 'bin',
    void Function(Object error)? onReadError,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.autoCompress = false;
    server.idleTimeout = const Duration(seconds: 30);
    final rng = Random.secure();
    final token = base64Url
        .encode(List<int>.generate(32, (_) => rng.nextInt(256)))
        .replaceAll('=', '');
    // The extension only helps the player guess the format.
    final safeExt = RegExp(r'^[a-z0-9]{1,5}$').hasMatch(extension) ? extension : 'bin';
    final media = VaultMediaServer._(
      server,
      '/$token/media.$safeExt',
      length,
      contentType,
      read,
      onReadError,
    );
    server.listen(media._handle, onError: (_) {});
    return media;
  }

  Uri get uri => Uri(scheme: 'http', host: '127.0.0.1', port: _server.port, path: _secretPath);

  Future<void> close() => _server.close(force: true);

  /// Parses a `Range` header for a resource of [length] bytes.
  ///
  /// Returns null when the whole file should be sent: no header, a header
  /// this server doesn't handle (several ranges) or a malformed one, all of
  /// which RFC 9110 lets a server ignore. Throws [UnsatisfiableRange] when
  /// the range starts past the end.
  static ByteRange? parseRange(String? header, int length) {
    if (header == null) return null;
    final m = RegExp(r'^\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*$').firstMatch(header);
    if (m == null) return null;
    final a = m.group(1)!, b = m.group(2)!;
    if (a.isEmpty && b.isEmpty) return null;
    if (a.isEmpty) {
      // Suffix range: the last N bytes.
      final n = int.tryParse(b);
      if (n == null) return null;
      if (n == 0 || length == 0) throw UnsatisfiableRange();
      return (start: max(0, length - n), end: length - 1);
    }
    final start = int.tryParse(a);
    if (start == null) return null;
    final end = b.isEmpty ? null : int.tryParse(b);
    if (b.isNotEmpty && (end == null || end < start)) return null;
    if (start >= length) throw UnsatisfiableRange();
    return (start: start, end: min(end ?? length - 1, length - 1));
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      if (!_samePath(req.uri.path, _secretPath)) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      if (req.method != 'GET' && req.method != 'HEAD') {
        res.statusCode = HttpStatus.methodNotAllowed;
        res.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        await res.close();
        return;
      }
      res.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.cacheControlHeader, 'no-store')
        ..contentType = ContentType.parse(contentType.isEmpty ? 'application/octet-stream' : contentType);

      ByteRange? range;
      try {
        range = parseRange(req.headers.value(HttpHeaders.rangeHeader), length);
      } on UnsatisfiableRange {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        await res.close();
        return;
      }
      final start = range?.start ?? 0;
      final end = range?.end ?? length - 1;
      if (range != null) {
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length');
      }
      res.contentLength = end - start + 1;
      if (req.method == 'HEAD' || length == 0) {
        await res.close();
        return;
      }
      for (var pos = start; pos <= end; pos += sendPiece) {
        final n = min(sendPiece, end + 1 - pos);
        final Uint8List bytes;
        try {
          bytes = await _read(pos, n);
        } catch (e) {
          if (!_reportedError) {
            _reportedError = true;
            onReadError?.call(e);
          }
          if (pos == start) {
            // Nothing sent yet: answer with a plain error.
            res.statusCode = HttpStatus.internalServerError;
            res.headers.removeAll(HttpHeaders.contentRangeHeader);
            res.contentLength = 0;
            await res.close();
            return;
          }
          // Mid-body: closing short of Content-Length drops the connection,
          // which is the only way left to tell the player the data is bad.
          rethrow;
        }
        res.add(bytes);
        await res.flush();
      }
      await res.close();
    } on SocketException {
      // The player hung up, typically to seek. Normal.
    } on HttpException {
      // Same, seen from the HTTP layer.
    } catch (_) {
      try {
        await res.close();
      } catch (_) {}
    }
  }

  /// Compares in time independent of where the strings differ.
  static bool _samePath(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
