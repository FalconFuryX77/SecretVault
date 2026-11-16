import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/models/vault_item.dart';
import 'package:gesture_unlock/services/vault_service.dart';
import 'package:gesture_unlock/vault/crypto_primitives.dart';
import 'package:gesture_unlock/vault/platform_keys.dart';
import 'package:gesture_unlock/vault/vault_container.dart';

VaultItem _note(String id) => VaultItem(
      id: id,
      title: id,
      category: VaultCategory.note,
      mimeType: 'text/plain',
      fileSizeBytes: 0,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      content: 'x',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late VaultService vault;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('rollback_test');
    vault = VaultService(
      crypto: VaultCrypto(binding: FixedDeviceBinding(), pinParams: KdfParams.testing, growChunks: 8),
      storageDir: () async => tmp,
    );
  });

  tearDown(() async {
    await vault.lock();
    await tmp.delete(recursive: true);
  });

  test('putting back an older copy of the vault file is noticed once', () async {
    final s = await vault.create(pin: '482913', initialChunks: 32);
    await s.upsertItem(_note('a'));
    await s.createDecoy(pin: '111222');
    await vault.lock();
    final container = await vault.containerFile();
    final older = await container.readAsBytes();

    var s2 = (await vault.unlockWithPin('482913'))!;
    expect(s2.rolledBack, isFalse);
    await s2.upsertItem(_note('b'));
    await s2.delete('a');
    await vault.lock();
    // The decoy, opened on its own, is not rolled back by the real vault's commits.
    final d = (await vault.unlockWithPin('111222'))!;
    expect(d.rolledBack, isFalse);
    await vault.lock();

    // Someone puts the earlier copy back.
    await container.writeAsBytes(older, flush: true);
    s2 = (await vault.unlockWithPin('482913'))!;
    expect(s2.rolledBack, isTrue);
    expect(s2.entries.map((e) => e.item.id), ['a'], reason: 'the deletion was undone');
    await vault.lock();
    // Warned once; the vault as it is becomes the reference.
    s2 = (await vault.unlockWithPin('482913'))!;
    expect(s2.rolledBack, isFalse);
    await vault.lock();
  });

  test('the state file is sealed, changes completely each time, and a damaged one is harmless', () async {
    final s = await vault.create(pin: '482913', initialChunks: 32);
    final state = File('${tmp.path}/${VaultService.rollbackStateName}');
    final first = await state.readAsBytes();
    await s.upsertItem(_note('a'));
    await vault.lock();
    final second = await state.readAsBytes();
    expect(first.length, second.length);
    var same = 0;
    for (var i = 0; i < first.length; i++) {
      if (first[i] == second[i]) same++;
    }
    expect(same, lessThan(first.length ~/ 8), reason: 'rewritten whole, under a fresh nonce');
    await state.writeAsBytes(Uint8List(first.length), flush: true);
    final s2 = await vault.unlockWithPin('482913');
    expect(s2, isNotNull);
    expect(s2!.rolledBack, isFalse);
  });
}
