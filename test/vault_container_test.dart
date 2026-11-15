import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/models/vault_state.dart';
import 'package:gesture_unlock/models/vault_item.dart';
import 'package:gesture_unlock/vault/crypto_primitives.dart';
import 'package:gesture_unlock/vault/platform_keys.dart';
import 'package:gesture_unlock/vault/vault_container.dart';

VaultItem _meta(String id, String title) => VaultItem(
  id: id,
  title: title,
  category: VaultCategory.document,
  mimeType: 'application/octet-stream',
  fileSizeBytes: 0,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  late Directory tmp;
  late File containerFile;
  late VaultCrypto crypto;

  Future<File> sourceFile(String name, int size, {int seed = 1}) async {
    final r = Random(seed);
    final f = File('${tmp.path}/$name');
    await f.writeAsBytes(List.generate(size, (_) => r.nextInt(256)));
    return f;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vault_test');
    containerFile = File('${tmp.path}/c.bin');
    crypto = VaultCrypto(
      binding: FixedDeviceBinding(),
      pinParams: KdfParams.testing,
      growChunks: 8,
    );
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<VaultSession> createVault({String pin = '482913', int chunks = 16}) =>
      VaultContainer.create(
        containerFile,
        crypto,
        pin: pin,
        initialChunks: chunks,
      );

  group('PIN protects the data', () {
    test('right PIN unlocks, wrong PIN does not', () async {
      final s = await createVault();
      await s.upsertItem(_meta('n1', 'hello').copyWith(content: 'secret note'));
      await s.close();

      final c = VaultContainer(containerFile, crypto);
      expect(await c.unlockWithPin('000000'), isNull);
      final s2 = await c.unlockWithPin('482913');
      expect(s2, isNotNull);
      expect(s2!.entries.single.item.content, 'secret note');
      expect(s2.type, VaultType.primary);
      await s2.close();
    });

    test('the container holds no plaintext and no fixed markers', () async {
      final s = await createVault();
      await s.upsertItem(
        _meta('n1', 'TOPSECRETTITLE').copyWith(content: 'TOPSECRETBODY'),
      );
      await s.close();
      final raw = String.fromCharCodes(await containerFile.readAsBytes());
      expect(raw.contains('TOPSECRET'), isFalse);
      expect(raw.contains('"v"'), isFalse);
    });

    test('a different device cannot unlock even with the right PIN', () async {
      final s = await createVault();
      await s.close();
      final otherDevice = VaultCrypto(
        binding: FixedDeviceBinding(Uint8List.fromList(List.filled(32, 9))),
        pinParams: KdfParams.testing,
      );
      expect(
        await VaultContainer(
          containerFile,
          otherDevice,
        ).unlockWithPin('482913'),
        isNull,
      );
    });

    test('changing the PIN retires the old one', () async {
      final s = await createVault();
      await s.changePin('99887766');
      await s.close();
      final c = VaultContainer(containerFile, crypto);
      expect(await c.unlockWithPin('482913'), isNull);
      final s2 = await c.unlockWithPin('99887766');
      expect(s2, isNotNull);
      await s2!.close();
    });
  });

  group('files: streaming, integrity, deletion', () {
    test('multi-chunk file round-trips byte for byte', () async {
      final s = await createVault();
      final src = await sourceFile('big.bin', 3 * 65508 + 1234);
      final entry = await s.importFile(src, _meta('f1', 'big.bin'));
      expect(entry.chunkCount, 4);
      expect(await s.readAll(entry), await src.readAsBytes());

      final out = File('${tmp.path}/out.bin');
      await s.exportTo(entry, out);
      expect(await out.readAsBytes(), await src.readAsBytes());
      await s.close();
    });

    test('empty file and exact-chunk-boundary file round-trip', () async {
      final s = await createVault();
      final empty = await sourceFile('e', 0);
      final exact = await sourceFile('x', 65508 * 2);
      final e1 = await s.importFile(empty, _meta('e', 'e'));
      final e2 = await s.importFile(exact, _meta('x', 'x'));
      expect(await s.readAll(e1), isEmpty);
      expect(await s.readAll(e2), await exact.readAsBytes());
      await s.close();
    });

    test('a flipped bit is detected, not silently returned', () async {
      final s = await createVault();
      final entry = await s.importFile(
        await sourceFile('a', 5000),
        _meta('a', 'a'),
      );
      final chunk = entry.extents.first.start;
      await s.close();

      final raf = await containerFile.open(mode: FileMode.append);
      await raf.setPosition(chunk * ContainerLayout.chunkSize + 100);
      final b = (await raf.read(1))[0];
      await raf.setPosition(chunk * ContainerLayout.chunkSize + 100);
      await raf.writeByte(b ^ 0x01);
      await raf.close();

      final s2 = (await VaultContainer(
        containerFile,
        crypto,
      ).unlockWithPin('482913'))!;
      await expectLater(
        s2.readAll(s2.entryById('a')!),
        throwsA(isA<TamperedDataException>()),
      );
      await s2.close();
    });

    test('swapping chunks between files is detected', () async {
      final s = await createVault();
      final a = await s.importFile(
        await sourceFile('a', 1000, seed: 1),
        _meta('a', 'a'),
      );
      final b = await s.importFile(
        await sourceFile('b', 1000, seed: 2),
        _meta('b', 'b'),
      );
      await s.close();
      final bytes = await containerFile.readAsBytes();
      final ca = a.extents.first.start * ContainerLayout.chunkSize;
      final cb = b.extents.first.start * ContainerLayout.chunkSize;
      final chunkA = bytes.sublist(ca, ca + ContainerLayout.chunkSize);
      bytes.setRange(
        ca,
        ca + ContainerLayout.chunkSize,
        bytes.sublist(cb, cb + ContainerLayout.chunkSize),
      );
      bytes.setRange(cb, cb + ContainerLayout.chunkSize, chunkA);
      await containerFile.writeAsBytes(bytes);

      final s2 = (await VaultContainer(
        containerFile,
        crypto,
      ).unlockWithPin('482913'))!;
      await expectLater(
        s2.readAll(s2.entryById('a')!),
        throwsA(isA<TamperedDataException>()),
      );
      await s2.close();
    });

    test('deleting shreds the ciphertext and the file key', () async {
      final s = await createVault();
      final entry = await s.importFile(
        await sourceFile('a', 5000),
        _meta('a', 'a'),
      );
      final chunk = entry.extents.first.start;
      final off = chunk * ContainerLayout.chunkSize;
      final before = (await containerFile.readAsBytes()).sublist(off, off + 64);
      await s.delete('a');
      final after = (await containerFile.readAsBytes()).sublist(off, off + 64);
      expect(after, isNot(equals(before)));
      expect(s.entryById('a'), isNull);
      await s.close();
    });

    test('the vault still opens after deleting the most recent file', () async {
      // Deleting frees the file's chunks before the index is rewritten, so
      // the new index can land in them. Shredding must not then wipe it.
      for (final size in [5000, 65508 * 3 + 7]) {
        final s = await createVault();
        await s.importFile(await sourceFile('keep', 70000, seed: 2), _meta('keep', 'keep'));
        await s.importFile(await sourceFile('gone', size, seed: 3), _meta('gone', 'gone'));
        await s.delete('gone');
        await s.upsertItem(s.entryById('keep')!.item.copyWith(title: 'renamed after delete'));
        await s.close();
        final s2 = (await VaultContainer(containerFile, crypto).unlockWithPin('482913'))!;
        expect(s2.entries.map((e) => e.item.id), ['keep']);
        expect(await s2.readAll(s2.entryById('keep')!), await File('${tmp.path}/keep').readAsBytes());
        await s2.close();
        await containerFile.delete();
      }
    });

    test("replacing a file's content keeps the item and survives a reopen", () async {
      final s = await createVault();
      final original = Uint8List.fromList(List.generate(200000, (i) => i % 251));
      await s.importBytes(original, _meta('t', 'notes.txt'));
      await s.importFile(await sourceFile('other', 9000), _meta('other', 'other'));
      final oldExtents = s.entryById('t')!.extents.expand((e) => e.chunks).toList();
      final position = s.entries.indexWhere((e) => e.item.id == 't');
      final edited = Uint8List.fromList('edited text, much shorter'.codeUnits);
      final renamed = s.entryById('t')!.item.copyWith(title: 'notes v2.txt');
      final fresh = await s.replaceContent('t', edited, renamed);
      expect(fresh.byteLength, edited.length);
      expect(fresh.item.fileSizeBytes, edited.length);
      expect(s.entries.indexWhere((e) => e.item.id == 't'), position, reason: 'keeps its place in the list');
      expect(await s.readAll(s.entryById('t')!), edited);
      // The old ciphertext is gone from the chunks the new copy didn't reuse.
      final newChunks = fresh.extents.expand((e) => e.chunks).toSet();
      expect(oldExtents.where(newChunks.contains), isEmpty, reason: 'written to fresh chunks');
      await s.close();
      final s2 = (await VaultContainer(containerFile, crypto).unlockWithPin('482913'))!;
      expect(await s2.readAll(s2.entryById('t')!), edited);
      expect(s2.entryById('t')!.item.title, 'notes v2.txt');
      expect(await s2.readAll(s2.entryById('other')!), await File('${tmp.path}/other').readAsBytes());
      await s2.close();
    });

    test('importBytes stores data without a source file', () async {
      final s = await createVault();
      final data = Uint8List.fromList(List.generate(65508 * 2 + 3, (i) => (i * 7) % 256));
      final e = await s.importBytes(data, _meta('m', 'memo.m4a'));
      expect(e.byteLength, data.length);
      expect(await s.readRange(e, 65500, 20), data.sublist(65500, 65520));
      await s.close();
      final s2 = (await VaultContainer(containerFile, crypto).unlockWithPin('482913'))!;
      expect(await s2.readAll(s2.entryById('m')!), data);
      await s2.close();
    });

    test('container grows in random-filled steps when full', () async {
      final s = await createVault(chunks: 4);
      final size0 = await containerFile.length();
      await s.importFile(await sourceFile('a', 65508 * 6), _meta('a', 'a'));
      final size1 = await containerFile.length();
      expect(size1, greaterThan(size0));
      expect(size1 % ContainerLayout.chunkSize, 0);
      await s.close();
      final s2 = (await VaultContainer(
        containerFile,
        crypto,
      ).unlockWithPin('482913'))!;
      expect((await s2.readAll(s2.entryById('a')!)).length, 65508 * 6);
      await s2.close();
    });

    test('index survives many commits and reopen', () async {
      final s = await createVault();
      for (var i = 0; i < 30; i++) {
        await s.upsertItem(
          _meta('n$i', 'note $i').copyWith(content: 'body $i'),
        );
      }
      await s.close();
      final s2 = (await VaultContainer(
        containerFile,
        crypto,
      ).unlockWithPin('482913'))!;
      expect(s2.entries.length, 30);
      await s2.close();
    });
  });

  group('decoy vault', () {
    test('decoy PIN opens a vault that cannot see the real one', () async {
      final s = await createVault();
      await s.importFile(
        await sourceFile('real', 70000),
        _meta('real', 'real-file'),
      );
      await s.createDecoy(pin: '111222');
      expect(s.hasDecoy, isTrue);
      await s.close();

      final c = VaultContainer(containerFile, crypto);
      final d = (await c.unlockWithPin('111222'))!;
      expect(d.entries, isEmpty);
      expect(d.hasDecoy, isFalse);
      expect(d.type, VaultType.decoy);
      await d.close();
    });

    test('decoy cannot reuse the real PIN', () async {
      final s = await createVault();
      await expectLater(
        s.createDecoy(pin: '482913'),
        throwsA(isA<CredentialInUseException>()),
      );
      await s.close();
    });

    test('decoy writing on its own never corrupts the real vault', () async {
      final s = await createVault(chunks: 12);
      final realSrc = await sourceFile('real', 65508 * 3, seed: 5);
      await s.importFile(realSrc, _meta('real', 'real'));
      await s.createDecoy(pin: '111222');
      await s.close();

      // Fill the decoy past its ceiling so it has to grow the container.
      final d = (await VaultContainer(
        containerFile,
        crypto,
      ).unlockWithPin('111222'))!;
      for (var i = 0; i < 4; i++) {
        await d.importFile(
          await sourceFile('d$i', 65508 * 3, seed: 10 + i),
          _meta('d$i', 'd$i'),
        );
      }
      await d.close();

      final r = (await VaultContainer(
        containerFile,
        crypto,
      ).unlockWithPin('482913'))!;
      expect(
        await r.readAll(r.entryById('real')!),
        await realSrc.readAsBytes(),
      );
      // And the real vault, which knows the decoy, doesn't clobber it either.
      await r.importFile(
        await sourceFile('real2', 65508 * 5, seed: 20),
        _meta('real2', 'real2'),
      );
      await r.close();

      final d2 = (await VaultContainer(
        containerFile,
        crypto,
      ).unlockWithPin('111222'))!;
      for (var i = 0; i < 4; i++) {
        expect((await d2.readAll(d2.entryById('d$i')!)).length, 65508 * 3);
      }
      await d2.close();
    });

    test('removing the decoy retires its PIN', () async {
      final s = await createVault();
      await s.createDecoy(pin: '111222');
      await s.removeDecoy();
      await s.close();
      expect(
        await VaultContainer(containerFile, crypto).unlockWithPin('111222'),
        isNull,
      );
    });

    test('with or without a decoy, the file has the same shape', () async {
      final s = await createVault();
      final sizeNoDecoy = await containerFile.length();
      await s.createDecoy(pin: '111222');
      expect(await containerFile.length(), sizeNoDecoy);
      await s.close();
    });
  });
}
