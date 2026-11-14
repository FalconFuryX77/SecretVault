// On-device tests for the vault core with the real native pieces:
// Android Keystore device binding, platform AES-GCM (cryptography_flutter),
// production Argon2id parameters, and real app storage.
//
// Run:  flutter test integration_test/vault_device_test.dart -d <device> --dart-define=GESTURES=false
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/models/vault_item.dart';
import 'package:gesture_unlock/services/vault_service.dart';
import 'package:gesture_unlock/vault/bulk_crypto.dart';
import 'package:gesture_unlock/vault/crypto_primitives.dart';
import 'package:gesture_unlock/vault/platform_keys.dart';
import 'package:gesture_unlock/vault/vault_container.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const pin = 'device-test-pin-1';
  late Directory dir;

  VaultService newService() => VaultService(storageDir: () async => dir);

  Future<T> timed<T>(String label, Future<T> Function() op) async {
    final sw = Stopwatch()..start();
    final r = await op();
    // ignore: avoid_print
    print('[timing] $label: ${sw.elapsedMilliseconds} ms');
    return r;
  }

  VaultItem meta(String id, String title) => VaultItem(
        id: id,
        title: title,
        category: VaultCategory.document,
        mimeType: 'application/octet-stream',
        fileSizeBytes: 0,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

  setUp(() async {
    final base = await getTemporaryDirectory();
    dir = await Directory('${base.path}/vault_it_${DateTime.now().microsecondsSinceEpoch}').create(recursive: true);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  testWidgets('native crypto backend and hardware device binding are active', (tester) async {
    // ignore: avoid_print
    print('[info] Cryptography.instance = ${Cryptography.instance.runtimeType}');
    final binding = AndroidDeviceBinding();
    final a = await binding.bind(Uint8List.fromList([1, 2, 3]));
    final b = await binding.bind(Uint8List.fromList([1, 2, 3]));
    final c = await binding.bind(Uint8List.fromList([1, 2, 4]));
    expect(a.length, 32);
    expect(a, b, reason: 'same input, same hardware key');
    expect(a, isNot(c));
    // ignore: avoid_print
    print('[info] biometrics available: ${await AndroidBiometricKeystore().isAvailable()}');
  });

  testWidgets('native batch crypto is byte-compatible with the Dart implementation', (tester) async {
    const native = AndroidBulkCrypto();
    const dart = DartBulkCrypto();
    final key = CryptoPrimitives.randomBytes(32);
    final plains = [
      Uint8List.fromList(List.generate(65508, (i) => i % 256)),
      Uint8List.fromList(List.generate(100, (i) => 255 - i)),
      Uint8List(0),
    ];
    final aads = [
      [5, 1, 2],
      [5, 3],
      [5],
    ];
    List<Uint8List> trim(List<Uint8List> fulls) => [
          for (var i = 0; i < fulls.length; i++) Uint8List.sublistView(fulls[i], 0, plains[i].length + 28),
        ];

    final sealedNative = await native.sealChunks(key, plains, aads, 65536);
    expect(sealedNative.every((c) => c.length == 65536), isTrue);
    expect(await dart.openChunks(key, trim(sealedNative), aads), plains);

    final sealedDart = await dart.sealChunks(key, plains, aads, 65536);
    expect(await native.openChunks(key, trim(sealedDart), aads), plains);

    final bad = trim(sealedNative).map(Uint8List.fromList).toList();
    bad[1][20] ^= 1;
    await expectLater(native.openChunks(key, bad, aads), throwsA(isA<TamperedDataException>()));
    // Wrong AAD (e.g. chunk moved to another position) is also refused.
    await expectLater(native.openChunks(key, trim(sealedNative), [aads[1], aads[0], aads[2]]),
        throwsA(isA<TamperedDataException>()));
  });

  testWidgets('default-size container: create, lock, unlock with production KDF', (tester) async {
    final svc = newService();
    await timed('create 256 MiB container + first index', () => svc.create(pin: pin));
    expect(await (await svc.containerFile()).length(), ContainerLayout.defaultInitialChunks * ContainerLayout.chunkSize);
    await svc.lock();

    // A brand-new service instance = an app restart. The hardware key must persist.
    final svc2 = newService();
    expect(await timed('wrong PIN attempt', () => svc2.unlockWithPin('nope-nope')), isNull);
    final s = await timed('right PIN unlock', () => svc2.unlockWithPin(pin));
    expect(s, isNotNull);
    expect(s!.type.name, 'primary');
    await svc2.lock();
  });

  testWidgets('20 MB file streams in and out intact; throughput measured', (tester) async {
    final svc = newService();
    // Big enough that the import measures encryption + IO, not container growth.
    final session = await svc.create(pin: pin, initialChunks: 400);
    final rng = Random(7);
    final src = File('${dir.path}/big.bin');
    final bytes = Uint8List(20 * 1024 * 1024);
    for (var i = 0; i < bytes.length; i += 4096) {
      bytes[i] = rng.nextInt(256);
    }
    await src.writeAsBytes(bytes);

    final entry = await timed('import 20 MB', () => session.importFile(src, meta('big', 'big.bin')));
    final back = await timed('read 20 MB', () => session.readAll(entry));
    expect(back.length, bytes.length);
    expect(back, bytes);

    final out = File('${dir.path}/out.bin');
    await timed('export 20 MB', () => session.exportTo(entry, out));
    expect(await out.length(), bytes.length);
    await svc.lock();
  });

  testWidgets('tampering is detected on device', (tester) async {
    final svc = newService();
    final session = await svc.create(pin: pin, initialChunks: 16);
    final src = File('${dir.path}/a.bin')..writeAsBytesSync(List.generate(10000, (i) => i % 256));
    final entry = await session.importFile(src, meta('a', 'a'));
    final chunk = entry.extents.first.start;
    await svc.lock();

    final raf = await (await svc.containerFile()).open(mode: FileMode.append);
    await raf.setPosition(chunk * ContainerLayout.chunkSize + 50);
    final b = (await raf.read(1))[0];
    await raf.setPosition(chunk * ContainerLayout.chunkSize + 50);
    await raf.writeByte(b ^ 0x80);
    await raf.close();

    final s2 = (await newService().unlockWithPin(pin))!;
    await expectLater(s2.readAll(s2.entryById('a')!), throwsA(isA<TamperedDataException>()));
    await s2.close();
  });

  testWidgets('decoy vault on device: isolation and no collateral damage', (tester) async {
    final svc = newService();
    final session = await svc.create(pin: pin, initialChunks: 16);
    final realSrc = File('${dir.path}/real.bin')..writeAsBytesSync(List.generate(300000, (i) => (i * 7) % 256));
    await session.importFile(realSrc, meta('real', 'real.bin'));
    await session.upsertItem(meta('note', 'real note').copyWith(category: VaultCategory.note, content: 'evidence'));
    await timed('create decoy (one Argon2id + index)', () => session.createDecoy(pin: 'decoy-pin-22'));
    await svc.lock();

    final d = (await newService().unlockWithPin('decoy-pin-22'))!;
    expect(d.type.name, 'decoy');
    expect(d.entries, isEmpty);
    // Fill the decoy past its ceiling so it must grow the container on its own.
    final dSrc = File('${dir.path}/d.bin')..writeAsBytesSync(List.generate(65508 * 20, (i) => i % 251));
    await timed('decoy import that grows the container', () => d.importFile(dSrc, meta('d', 'd.bin')));
    await d.close();

    final r = (await newService().unlockWithPin(pin))!;
    expect(await r.readAll(r.entryById('real')!), await realSrc.readAsBytes());
    expect(r.entryById('note')!.item.content, 'evidence');
    expect(r.hasDecoy, isTrue);
    await r.close();
  });

  testWidgets('delete overwrites the ciphertext on device', (tester) async {
    final svc = newService();
    final session = await svc.create(pin: pin, initialChunks: 16);
    final src = File('${dir.path}/x.bin')..writeAsBytesSync(List.filled(5000, 42));
    final entry = await session.importFile(src, meta('x', 'x'));
    final off = entry.extents.first.start * ContainerLayout.chunkSize;
    final file = await svc.containerFile();
    final before = (await file.readAsBytes()).sublist(off, off + 256);
    await session.delete('x');
    final after = (await file.readAsBytes()).sublist(off, off + 256);
    expect(after, isNot(before));
    await svc.lock();
  });
}
