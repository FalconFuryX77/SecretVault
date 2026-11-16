// A new phone restoring a backed-up vault, through the real first-run UI:
// "Restore from a backup instead", the server address, the recovery code
// and a new PIN; the files come straight into the new vault.
//
// Needs a sync server the phone can reach, e.g. the Docker stack and
//   adb reverse tcp:8080 tcp:8080
// then --dart-define=SYNC_SERVER=http://127.0.0.1:8080 (tool/device_test.sh).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/main.dart' as app;
import 'package:gesture_unlock/models/vault_item.dart';
import 'package:gesture_unlock/services/vault_service.dart';
import 'package:gesture_unlock/sync/vault_sync.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const syncServer = String.fromEnvironment('SYNC_SERVER');
const syncInvite = String.fromEnvironment('SYNC_INVITE', defaultValue: 'dev-invite');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('restore a backed-up vault at first run', (t) async {
    if (syncServer.isEmpty) {
      markTestSkipped('set SYNC_SERVER');
      return;
    }
    // The "old phone": a vault in a temp folder, backed up.
    final tmp = await Directory('${(await getTemporaryDirectory()).path}/oldphone_${DateTime.now().microsecondsSinceEpoch}')
        .create();
    final old = VaultService(storageDir: () async => tmp);
    final s = await old.create(pin: 'old-phone-pin', initialChunks: 256);
    final photo = Uint8List.fromList(List.generate(400000, (i) => (i * 31) & 0xff));
    final now = DateTime.now();
    await s.importBytes(
      photo,
      VaultItem(
        id: 'photo-1',
        title: 'Checkpoint.jpg',
        category: VaultCategory.image,
        mimeType: 'image/jpeg',
        fileSizeBytes: photo.length,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await s.upsertItem(VaultItem(
      id: 'note-1',
      title: 'Contacts',
      category: VaultCategory.note,
      mimeType: 'text/plain',
      fileSizeBytes: 0,
      createdAt: now,
      updatedAt: now,
      content: 'Driver: ask for Sami',
    ));
    final sync = VaultSync();
    final rs = VaultSync.newRecoverySecret();
    final code = await sync.connect(s, server: syncServer, invite: syncInvite, recoverySecret: rs);
    await sync.backupAll(s);
    await old.lock();
    await tmp.delete(recursive: true);

    // The "new phone": the app, from scratch.
    app.main();
    Future<void> waitFor(Finder f, {int seconds = 60}) async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (f.evaluate().isEmpty) {
        if (DateTime.now().isAfter(end)) fail('Timed out waiting for $f');
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await t.pump();
      }
    }

    Future<void> tap(Finder f) async {
      await waitFor(f);
      await t.ensureVisible(f);
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(f);
      await t.pump();
    }

    await tap(find.byKey(const Key('setup-restore-toggle')));
    await waitFor(find.byKey(const Key('restore-server')));
    await t.enterText(find.byKey(const Key('restore-server')), syncServer);
    // As written on paper: spaces, any case.
    await t.enterText(find.byKey(const Key('restore-code')), code.toUpperCase());
    final pins = find.byWidgetPredicate((w) => w is TextField && w.obscureText);
    await t.enterText(pins.at(0), 'new-phone-pin');
    await t.enterText(pins.at(1), 'new-phone-pin');
    await t.pump();
    await tap(find.byKey(const Key('setup-submit')));
    // The vault opens with the restored items.
    await waitFor(find.text('Contacts'), seconds: 120);
    await waitFor(find.text('Checkpoint.jpg'));
    final svc = VaultService();
    expect(await svc.isSetUp(), isTrue);
    // ignore: avoid_print
    print('[restore] new phone has the restored vault');
  });
}
