import 'dart:math';
import 'dart:typed_data';

import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

Uint8List noise(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  late SyncKeys keys;
  setUpAll(() async => keys = await SyncKeys.derive(Uint8List(32)));

  group('Padmé', () {
    test('known values and bounds', () {
      expect(padme(0), 0);
      expect(padme(1), 1);
      expect(padme(9), 10);
      expect(padme(1000), 1024);
      for (final l in [100, 5000, 65541, 262149, 1048581, 3000000]) {
        final p = padme(l);
        expect(p, greaterThanOrEqualTo(l));
        expect((p - l) / l, lessThan(0.12), reason: 'overhead for $l');
      }
    });

    test('collapses many lengths onto few sizes', () {
      final sizes = {for (var l = 262144; l < 262144 + 20000; l++) padme(l)};
      expect(sizes.length, lessThan(5));
    });
  });

  group('keyed content-defined chunking', () {
    test('respects min/max and covers the input exactly', () async {
      final c = await Chunker.keyed(keys.cdc);
      final data = noise(5 * 1024 * 1024, 1);
      final refs = c.chunkBytes(data);
      var pos = 0;
      for (final (i, r) in refs.indexed) {
        expect(r.offset, pos);
        if (i < refs.length - 1) {
          expect(r.length, inInclusiveRange(c.minSize, c.maxSize));
        }
        pos += r.length;
      }
      expect(pos, data.length);
      final avg = data.length / refs.length;
      expect(avg, inInclusiveRange(150 * 1024, 450 * 1024), reason: 'average near 256 KiB');
    });

    test('an insertion near the start leaves later pieces identical (dedup)', () async {
      final c = await Chunker.keyed(keys.cdc);
      final data = noise(4 * 1024 * 1024, 2);
      final edited = Uint8List.fromList([...data.sublist(0, 1000), ...noise(777, 3), ...data.sublist(1000)]);
      List<String> cuts(Uint8List d) => [for (final r in c.chunkBytes(d)) '${d.length - r.offset}:${r.length}'];
      final a = cuts(data).toSet();
      final b = cuts(edited);
      final shared = b.where(a.contains).length;
      expect(shared, greaterThanOrEqualTo(b.length - 2), reason: 'only the edited piece(s) change');
    });

    test('different keys give different boundaries for the same content', () async {
      final other = await SyncKeys.derive(Uint8List(32)..[0] = 1);
      final c1 = await Chunker.keyed(keys.cdc);
      final c2 = await Chunker.keyed(other.cdc);
      final data = noise(3 * 1024 * 1024, 4);
      expect(c1.chunkBytes(data).map((r) => r.length).toList(), isNot(c2.chunkBytes(data).map((r) => r.length).toList()));
    });
  });

  group('pieces', () {
    test('round trip, with and without compression', () async {
      final codec = PieceCodec(keys);
      final text = Uint8List.fromList(List.filled(100000, 65));
      final id = await codec.idFor(text);
      final small = await codec.seal(id, text, compress: true);
      final big = await codec.seal(id, text, compress: false);
      expect(small.length, lessThan(big.length ~/ 10));
      expect(await codec.open(id, small), text);
      expect(await codec.open(id, big), text);
    });

    test('incompressible data is sent as-is', () async {
      final codec = PieceCodec(keys);
      final data = noise(50000, 5);
      final sealed = await codec.seal(await codec.idFor(data), data, compress: true);
      expect(sealed.length, padme(5 + data.length) + 28);
    });

    test('tampering, wrong name and swapped pieces are refused', () async {
      final codec = PieceCodec(keys);
      final a = noise(1000, 6), b = noise(1000, 7);
      final ida = await codec.idFor(a), idb = await codec.idFor(b);
      final sa = await codec.seal(ida, a);
      final sb = await codec.seal(idb, b);
      final flipped = Uint8List.fromList(sa)..[40] ^= 1;
      await expectLater(codec.open(ida, flipped), throwsA(isA<IntegrityException>()));
      await expectLater(codec.open(ida, sb), throwsA(isA<IntegrityException>()), reason: 'server serves B under A\'s name');
      await expectLater(codec.open(ida, sa, manifest: true), throwsA(isA<IntegrityException>()));
    });

    test('sealing is deterministic for identical input (resumable), distinct otherwise', () async {
      final codec = PieceCodec(keys);
      final text = Uint8List.fromList(List.filled(20000, 66));
      final id = await codec.idFor(text);
      expect(await codec.seal(id, text), await codec.seal(id, text));
      final plain = await codec.seal(id, text, compress: false);
      final packed = await codec.seal(id, text, compress: true);
      // Same content, different encoding → must not share a nonce.
      expect(plain.sublist(0, 12), isNot(packed.sublist(0, 12)));
    });

    test('names are keyed: another account cannot compute them', () async {
      final other = PieceCodec(await SyncKeys.derive(Uint8List(32)..[5] = 9));
      final data = noise(100, 8);
      expect(await PieceCodec(keys).idFor(data), isNot(await other.idFor(data)));
    });
  });

  group('log chains', () {
    Future<List<({int seq, String device, int counter, Uint8List record})>> chain(int n) async {
      final sealer = LogSealer(keys);
      final st = ChainState();
      final out = <({int seq, String device, int counter, Uint8List record})>[];
      for (var i = 0; i < n; i++) {
        final (c, rec) = await sealer.next('devA', st, [LogOp.put(file: 'f$i', version: 'v$i', manifestId: 'm$i')]);
        out.add((seq: i + 1, device: 'devA', counter: c, record: rec));
      }
      return out;
    }

    test('a complete chain verifies', () async {
      expect((await verifyLog(LogSealer(keys), await chain(5))).length, 5);
    });

    test('a dropped record is detected', () async {
      final c = await chain(5)..removeAt(2);
      await expectLater(verifyLog(LogSealer(keys), c), throwsA(isA<IntegrityException>()));
    });

    test('reordered records are detected', () async {
      final c = await chain(4);
      final swapped = [c[0], c[2], c[1], c[3]];
      await expectLater(verifyLog(LogSealer(keys), swapped), throwsA(isA<IntegrityException>()));
    });

    test('a record moved to another device or counter is refused', () async {
      final c = await chain(2);
      final moved = [(seq: 1, device: 'devB', counter: 1, record: c[0].record)];
      await expectLater(verifyLog(LogSealer(keys), moved), throwsA(isA<IntegrityException>()));
    });
  });

  group('recovery', () {
    test('escrow slot unwraps only with the right secret', () async {
      final rs = randomBytes(32);
      final rk = await RecoveryKeys.fromSecret(rs);
      final srk = randomBytes(32);
      final slot = await rk.wrapSrk(srk, 3);
      expect(slot.length, 128);
      final back = await rk.unwrapSrk(slot);
      expect(back!.$1, srk);
      expect(back.$2, 3);
      expect(await (await RecoveryKeys.fromSecret(randomBytes(32))).unwrapSrk(slot), isNull);
      expect(await rk.unwrapSrk(randomBytes(128)), isNull);
    });

    test('recovery keys are deterministic from the secret', () async {
      final rs = randomBytes(32);
      expect((await RecoveryKeys.fromSecret(rs)).publicKey, (await RecoveryKeys.fromSecret(rs)).publicKey);
    });
  });
}
