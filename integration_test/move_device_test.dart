// Moving a vault through the native copy (Android's document picker is
// skipped: a file:// address stands in for the place the user picks).
// The different-phone case (other hardware key) is covered on the PC in
// test/vault_container_test.dart.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/models/vault_item.dart';
import 'package:gesture_unlock/services/vault_mover.dart';
import 'package:gesture_unlock/services/vault_service.dart';
import 'package:gesture_unlock/vault/vault_container.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('move a vault and its decoy out and in through the native copy', (t) async {
    final base = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final dirA = await Directory('${base.path}/move_a_$stamp').create();
    final dirB = await Directory('${base.path}/move_b_$stamp').create();
    final a = VaultService(storageDir: () async => dirA);
    final s = await a.create(pin: 'old-real-pin', initialChunks: 256);
    final now = DateTime.now();
    final data = Uint8List.fromList(List.generate(3 * 1024 * 1024 + 17, (i) => (i * 13) & 0xff));
    await s.importBytes(
      data,
      VaultItem(id: 'f1', title: 'big.bin', category: VaultCategory.document, mimeType: 'application/octet-stream',
          fileSizeBytes: data.length, createdAt: now, updatedAt: now),
    );
    await s.createDecoy(pin: 'old-decoy-pin');

    final out = File('${base.path}/move_$stamp.bin');
    final code = await VaultMover.moveOut(a, Uri.file(out.path).toString());
    expect(await out.length(), await (await a.containerFile()).length());
    final p = await VaultMover.progress();
    expect(p.done, p.total);
    await a.lock();

    final b = VaultService(storageDir: () async => dirB);
    final copy = await VaultMover.copyIn(b, Uri.file(out.path).toString());
    expect(await VaultContainer.transferVaultCount(copy, code), 2);
    await VaultContainer.completeTransfer(copy, await b.containerFile(), b.crypto, code, ['new-real-pin', 'new-decoy-pin']);
    final moved = (await b.unlockWithPin('new-real-pin'))!;
    expect(await moved.readAll(moved.entryById('f1')!), data);
    expect(moved.hasDecoy, isTrue);
    await b.lock();
    expect((await b.unlockWithPin('new-decoy-pin'))!.entries, isEmpty);
    await b.lock();
    // ignore: avoid_print
    print('[move] ${await out.length()} bytes moved out and in; new PINs open both vaults');
    await out.delete();
    await dirA.delete(recursive: true);
    await dirB.delete(recursive: true);
  });
}
