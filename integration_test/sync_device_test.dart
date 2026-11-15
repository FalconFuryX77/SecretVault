// Backs up a real vault from the phone to a sync server, using the real
// hardware keystore, native crypto and the phone's network stack.
//
// Run through tool/sync_phone_test.sh, which also restores the backup on the
// PC from the recovery code and compares the files.
//
//   flutter test integration_test/sync_device_test.dart -d <device> \
//     --dart-define=SYNC_SERVER=http://127.0.0.1:8080 --dart-define=SYNC_INVITE=dev-invite
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/models/vault_item.dart';
import 'package:gesture_unlock/services/vault_service.dart';
import 'package:gesture_unlock/sync/vault_sync.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const serverUrl = String.fromEnvironment('SYNC_SERVER');
const invite = String.fromEnvironment('SYNC_INVITE');

Future<String> sha256Hex(List<int> bytes) async =>
    (await Sha256().hash(bytes)).bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('phone vault backs up to the server over the network', (tester) async {
    expect(serverUrl, isNotEmpty, reason: 'pass --dart-define=SYNC_SERVER=...');
    final base = await getTemporaryDirectory();
    final dir = await Directory('${base.path}/sync_it_${DateTime.now().microsecondsSinceEpoch}').create(recursive: true);
    final svc = VaultService(storageDir: () async => dir);
    final session = await svc.create(pin: 'sync-device-test-1', initialChunks: 512);

    VaultItem meta(String id, String title, String mime, VaultCategory c) => VaultItem(
          id: id,
          title: title,
          category: c,
          mimeType: mime,
          fileSizeBytes: 0,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

    // An 8 MB "video", a 1.2 MB "photo" and a note, like a day's field material.
    final rng = Random(2026);
    Uint8List random(int n) {
      final b = Uint8List(n);
      for (var i = 0; i < n; i++) {
        b[i] = rng.nextInt(256);
      }
      return b;
    }

    final files = <String, Uint8List>{
      'interview.mp4': random(8 * 1024 * 1024 + 12345),
      'checkpoint.jpg': random(1200000),
    };
    for (final MapEntry(key: name, value: data) in files.entries) {
      final f = File('${dir.path}/$name')..writeAsBytesSync(data);
      await session.importFile(
        f,
        meta(name, name, name.endsWith('.mp4') ? 'video/mp4' : 'image/jpeg',
            name.endsWith('.mp4') ? VaultCategory.video : VaultCategory.image),
      );
      f.deleteSync(); // the vault now holds the only copy
      // ignore: avoid_print
      print('[sync] sha256 $name ${await sha256Hex(data)}');
    }
    final note = 'Crossed at 14:10. Two vehicles, no plates. ' * 300;
    await session.upsertItem(
      meta('note-1', 'Field notes', 'text/plain', VaultCategory.note).copyWith(content: note),
    );
    // ignore: avoid_print
    print('[sync] sha256 Field notes ${await sha256Hex(utf8.encode(note))}');

    final sync = VaultSync();
    late final String secret;
    try {
      secret = await sync.connect(session, server: serverUrl, invite: invite);
    } on SyncSetupException catch (e) {
      // ignore: avoid_print
      print('[sync] connect failed: ${e.message} | cause: ${e.cause}');
      rethrow;
    }
    final status = sync.status(session);
    // ignore: avoid_print
    print('[sync] account=${status.account}');
    // A throwaway test account: printing its recovery code lets the PC side restore.
    // ignore: avoid_print
    print('[sync] secret=${secret.replaceAll(' ', '')}');

    final first = await sync.backupAll(session);
    // ignore: avoid_print
    print('[sync] first backup: ${first.uploaded}/${first.total} items, '
        '${first.wireBytes} bytes sent for ${first.payloadBytes} bytes of files, '
        '${first.elapsed.inMilliseconds} ms, ${first.retries} retries');
    expect(first.uploaded, 3);

    final second = await sync.backupAll(session);
    // ignore: avoid_print
    print('[sync] second backup (nothing changed): ${second.uploaded} sent, '
        '${second.unchanged} up to date, ${second.wireBytes} bytes sent, ${second.elapsed.inMilliseconds} ms');
    expect(second.uploaded, 0);
    expect(second.unchanged, 3);

    // The account survives a lock: it lives inside the encrypted vault.
    await svc.lock();
    final again = (await svc.unlockWithPin('sync-device-test-1'))!;
    expect(sync.status(again).account, status.account);
    await svc.lock();
    await dir.delete(recursive: true);
  });
}
