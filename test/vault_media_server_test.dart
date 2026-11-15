import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/viewers/vault_media_server.dart';

void main() {
  group('Range header parsing', () {
    const len = 1000;
    ByteRange? parse(String? h) => VaultMediaServer.parseRange(h, len);

    test('whole file when there is no usable header', () {
      expect(parse(null), isNull);
      expect(parse('bytes=-'), isNull);
      expect(parse('items=0-5'), isNull);
      expect(parse('bytes=5-2'), isNull, reason: 'malformed ranges are ignored');
      expect(parse('bytes=0-1,5-9'), isNull, reason: 'multiple ranges: send everything');
    });

    test('closed, open-ended and suffix ranges', () {
      expect(parse('bytes=0-99'), (start: 0, end: 99));
      expect(parse('bytes=900-'), (start: 900, end: 999));
      expect(parse('bytes=990-5000'), (start: 990, end: 999), reason: 'end is clamped');
      expect(parse('bytes=-100'), (start: 900, end: 999));
      expect(parse('bytes=-5000'), (start: 0, end: 999));
    });

    test('ranges past the end are unsatisfiable', () {
      expect(() => parse('bytes=1000-'), throwsA(isA<UnsatisfiableRange>()));
      expect(() => parse('bytes=-0'), throwsA(isA<UnsatisfiableRange>()));
    });
  });

  group('serving', () {
    late Uint8List data;
    late VaultMediaServer server;
    late HttpClient client;
    final reads = <(int, int)>[];
    Object? reportedError;
    var failAt = -1;

    setUp(() async {
      final r = Random(7);
      data = Uint8List.fromList(List.generate(700 * 1024 + 13, (_) => r.nextInt(256)));
      reads.clear();
      reportedError = null;
      failAt = -1;
      server = await VaultMediaServer.start(
        length: data.length,
        contentType: 'video/mp4',
        extension: 'mp4',
        read: (o, l) async {
          reads.add((o, l));
          if (failAt >= 0 && o + l > failAt) throw StateError('chunk failed its check');
          return Uint8List.fromList(data.sublist(o, o + l));
        },
        onReadError: (e) => reportedError = e,
      );
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.close();
    });

    Future<(HttpClientResponse, Uint8List)> get(Uri uri, {String? range, String method = 'GET'}) async {
      final req = await client.openUrl(method, uri);
      if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
      final res = await req.close();
      final body = BytesBuilder(copy: false);
      await for (final part in res) {
        body.add(part);
      }
      return (res, body.takeBytes());
    }

    test('listens on loopback only, under an unguessable path', () async {
      expect(server.uri.host, '127.0.0.1');
      final token = server.uri.pathSegments.first;
      expect(token.length, greaterThanOrEqualTo(43), reason: '256 bits, base64');
      expect(server.uri.path, endsWith('/media.mp4'));
    });

    test('the whole file, byte for byte', () async {
      final (res, body) = await get(server.uri);
      expect(res.statusCode, 200);
      expect(res.headers.value('accept-ranges'), 'bytes');
      expect(res.headers.value('cache-control'), 'no-store');
      expect(res.headers.contentType?.mimeType, 'video/mp4');
      expect(body, data);
      expect(reads.every((r) => r.$2 <= VaultMediaServer.sendPiece), isTrue);
    });

    test('a range in the middle reads only what it needs', () async {
      final (res, body) = await get(server.uri, range: 'bytes=300000-300099');
      expect(res.statusCode, 206);
      expect(res.headers.value('content-range'), 'bytes 300000-300099/${data.length}');
      expect(body, data.sublist(300000, 300100));
      expect(reads, [(300000, 100)]);
    });

    test('open-ended range from a seek point', () async {
      final from = data.length - 5000;
      final (res, body) = await get(server.uri, range: 'bytes=$from-');
      expect(res.statusCode, 206);
      expect(body, data.sublist(from));
    });

    test('HEAD sends headers only', () async {
      final (res, body) = await get(server.uri, method: 'HEAD');
      expect(res.statusCode, 200);
      expect(res.contentLength, data.length);
      expect(body, isEmpty);
      expect(reads, isEmpty);
    });

    test('unsatisfiable range gets 416', () async {
      final (res, _) = await get(server.uri, range: 'bytes=${data.length}-');
      expect(res.statusCode, 416);
      expect(res.headers.value('content-range'), 'bytes */${data.length}');
    });

    test('a wrong path or method is refused and decrypts nothing', () async {
      final wrong = server.uri.replace(path: '/guess/media.mp4');
      expect((await get(wrong)).$1.statusCode, 404);
      final p = server.uri.path;
      final shortened = server.uri.replace(path: p.substring(0, p.length - 1));
      expect((await get(shortened)).$1.statusCode, 404);
      expect((await get(server.uri, method: 'POST')).$1.statusCode, 405);
      expect(reads, isEmpty);
    });

    test('a failed read is reported and the transfer is cut, not padded', () async {
      failAt = 0;
      final (first, _) = await get(server.uri);
      expect(first.statusCode, 500);
      expect(reportedError, isA<StateError>());

      failAt = 400 * 1024;
      reportedError = null;
      Object? clientError;
      var received = 0;
      try {
        final req = await client.getUrl(server.uri);
        final res = await req.close();
        await for (final part in res) {
          received += part.length;
        }
      } catch (e) {
        clientError = e;
      }
      expect(received, lessThan(data.length));
      expect(clientError, isNotNull, reason: 'the player must see a broken transfer');
    });

    test('closed server refuses connections', () async {
      final uri = server.uri;
      await server.close();
      await expectLater(get(uri), throwsA(isA<SocketException>()));
    });
  });
}
