// Micro-benchmarks for the per-chunk costs on a real device.
// Run:  flutter test integration_test/bench_test.dart -d <device>
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/vault/crypto_primitives.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> bench(String label, int n, int bytesEach, Future<void> Function(int i) op) async {
    await op(0); // warm-up
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      await op(i);
    }
    final ms = sw.elapsedMilliseconds;
    final mbps = (n * bytesEach / 1048576) / (ms / 1000);
    // ignore: avoid_print
    print('[bench] $label: $n × ${bytesEach ~/ 1024} KiB in $ms ms → ${mbps.toStringAsFixed(1)} MB/s, ${(ms / n).toStringAsFixed(1)} ms/op');
  }

  testWidgets('per-chunk cost breakdown', (tester) async {
    final key = CryptoPrimitives.randomBytes(32);
    final chunk = Uint8List(65508);
    final big = Uint8List(1024 * 1024);

    await bench('seal 64K (platform AES-GCM via channel)', 64, 65536, (_) => CryptoPrimitives.seal(key, chunk, const [1]));
    final dart = DartAesGcm.with256bits();
    await bench('seal 64K (pure Dart AES-GCM)', 16, 65536,
        (_) => dart.encrypt(chunk, secretKey: SecretKeyData(key), nonce: dart.newNonce()));
    await bench('seal 1M (platform AES-GCM via channel)', 16, 1048576, (_) => CryptoPrimitives.seal(key, big, const [1]));
    await bench('randomFill 64K', 64, 65536, (_) => CryptoPrimitives.randomFill(65536));
    await bench('randomBytes(12) (nonce)', 64, 12, (_) async => CryptoPrimitives.randomBytes(12));

    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/bench.bin');
    final raf = await f.open(mode: FileMode.write);
    final buf = Uint8List(65536);
    await bench('random-access write 64K', 64, 65536, (i) async {
      await raf.setPosition(i * 65536);
      await raf.writeFrom(buf);
    });
    await raf.flush();
    await bench('random-access read 64K', 64, 65536, (i) async {
      await raf.setPosition(i * 65536);
      await raf.read(65536);
    });
    final mb = Uint8List(1024 * 1024);
    await bench('random-access write 1M', 16, 1048576, (i) async {
      await raf.setPosition(i * 1048576);
      await raf.writeFrom(mb);
    });
    await bench('random-access read 1M', 16, 1048576, (i) async {
      await raf.setPosition(i * 1048576);
      await raf.read(1048576);
    });
    await bench('sync write 64K', 64, 65536, (i) async {
      raf.setPositionSync(i * 65536);
      raf.writeFromSync(buf);
    });
    await bench('sync read 64K', 64, 65536, (i) async {
      raf.setPositionSync(i * 65536);
      raf.readSync(65536);
    });
    await bench('sync write 1M', 16, 1048576, (i) async {
      raf.setPositionSync(i * 1048576);
      raf.writeFromSync(mb);
    });
    await raf.close();
    await f.delete();
    // ignore: avoid_print
    print('[info] backend: ${Cryptography.instance.runtimeType}');
  });
}
