// The app's backup path end to end on the desktop: a real vault container,
// the real sync server (python + uvicorn, started here), and an independent
// restore with the recovery secret through the sync engine.
//
// Needs `pip install -r server/requirements.txt`. Skipped if the server
// can't be started.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/models/vault_item.dart';
import 'package:gesture_unlock/sync/vault_sync.dart';
import 'package:gesture_unlock/vault/crypto_primitives.dart';
import 'package:gesture_unlock/vault/platform_keys.dart';
import 'package:gesture_unlock/vault/vault_container.dart';
import 'package:sync_core/sync_core.dart';

Uint8List noise(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

VaultItem fileItem(String id, String title, String mime, VaultCategory category) => VaultItem(
      id: id,
      title: title,
      category: category,
      mimeType: mime,
      fileSizeBytes: 0,
      createdAt: DateTime(2026, 11, 1),
      updatedAt: DateTime(2026, 11, 1),
    );

void main() {
  late Directory tmp;
  late VaultCrypto crypto;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vault_sync');
    crypto = VaultCrypto(binding: FixedDeviceBinding(), pinParams: KdfParams.testing, growChunks: 16);
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<VaultSession> newVault() =>
      VaultContainer.create(File('${tmp.path}/c.bin'), crypto, pin: '482913', initialChunks: 64);

  group('vault building blocks for backup', () {
    test('readRange returns exactly the requested bytes across chunk boundaries', () async {
      final s = await newVault();
      final data = noise(3 * 65508 + 4321, 3);
      final src = File('${tmp.path}/a.bin')..writeAsBytesSync(data);
      final entry = await s.importFile(src, fileItem('a', 'a.bin', 'application/octet-stream', VaultCategory.document));
      for (final (off, len) in [
        (0, 1),
        (0, 65508),
        (65500, 20),
        (65508, 65508),
        (100, 150000),
        (data.length - 10, 10),
        (0, data.length),
        (data.length, 0),
      ]) {
        expect(await s.readRange(entry, off, len), data.sublist(off, off + len), reason: '$off+$len');
      }
      expect(() => s.readRange(entry, data.length - 5, 10), throwsRangeError);
      await s.close();
    });

    test('per-vault settings are encrypted with the vault and survive a lock', () async {
      final s = await newVault();
      await s.putExtra('sync.config', {'server': 'https://SERVERMARKER.example', 'n': 3});
      await s.createDecoy(pin: '111222');
      await s.close();

      final raw = latin1.decode(await File('${tmp.path}/c.bin').readAsBytes());
      expect(raw.contains('SERVERMARKER'), isFalse);

      final c = VaultContainer(File('${tmp.path}/c.bin'), crypto);
      final real = (await c.unlockWithPin('482913'))!;
      expect(real.extras['sync.config'], {'server': 'https://SERVERMARKER.example', 'n': 3});
      await real.putExtra('sync.config', null);
      expect(real.extras.containsKey('sync.config'), isFalse);
      await real.close();

      // The decoy sees none of the real vault's settings.
      final decoy = (await c.unlockWithPin('111222'))!;
      expect(decoy.extras, isEmpty);
      await decoy.close();
    });
  });

  group('backup to a real server', () {
    Process? server;
    late Uri serverUrl;
    late Directory serverData;

    setUpAll(() async {
      serverData = await Directory.systemTemp.createTemp('vault_sync_server');
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      try {
        server = await Process.start(
          'python',
          ['-m', 'uvicorn', 'app.main:create_app', '--factory', '--port', '$port', '--log-level', 'warning'],
          workingDirectory: '${Directory.current.path}/server',
          environment: {
            'SYNC_DB_URL': 'sqlite:///${serverData.path.replaceAll('\\', '/')}/sync.db',
            'SYNC_BLOB_DIR': '${serverData.path}/blobs',
            'SYNC_STAGING_DIR': '${serverData.path}/staging',
          },
        );
        server!.stderr.drain<void>();
        server!.stdout.drain<void>();
      } catch (_) {
        server = null;
        return;
      }
      serverUrl = Uri.parse('http://127.0.0.1:$port');
      final client = HttpClient();
      var up = false;
      for (var i = 0; i < 80 && !up; i++) {
        try {
          final r = await (await client.getUrl(serverUrl.resolve('/health'))).close();
          up = r.statusCode == 200;
          await r.drain<void>();
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
      client.close(force: true);
      if (!up) {
        server!.kill();
        server = null;
      }
    });

    tearDownAll(() async {
      server?.kill();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      try {
        await serverData.delete(recursive: true);
      } catch (_) {}
    });

    test('vault items go up encrypted, come back identical, and re-runs send almost nothing', () async {
      if (server == null) {
        markTestSkipped('python sync server not available');
        return;
      }
      final session = await newVault();
      final video = noise(2 * 1024 * 1024 + 777, 11);
      final photo = noise(300000, 12);
      await session.importFile(
        File('${tmp.path}/v.mp4')..writeAsBytesSync(video),
        fileItem('vid', 'clip.mp4', 'video/mp4', VaultCategory.video),
      );
      await session.importFile(
        File('${tmp.path}/p.jpg')..writeAsBytesSync(photo),
        fileItem('pic', 'photo.jpg', 'image/jpeg', VaultCategory.image),
      );
      const noteText = 'Met the source at the bridge. PLAINTEXTMARKER. ';
      await session.upsertItem(
        fileItem('note', 'Checkpoint notes', 'text/plain', VaultCategory.note).copyWith(content: noteText * 200),
      );
      // The plaintext imports are gone; the vault is the only copy.
      File('${tmp.path}/v.mp4').deleteSync();
      File('${tmp.path}/p.jpg').deleteSync();

      final sync = VaultSync();
      expect(sync.status(session).isConnected, isFalse);
      final secretText = await sync.connect(session, server: serverUrl.toString());
      expect(secretText.split(' ').length, 16);
      final status = sync.status(session);
      expect(status.isConnected, isTrue);

      final first = await sync.backupAll(session);
      expect(first.total, 3);
      expect(first.uploaded, 3);
      expect(sync.status(session).lastItemCount, 3);

      // Nothing readable on the server.
      final stored = Directory('${serverData.path}/blobs').listSync(recursive: true).whereType<File>().toList();
      expect(stored, isNotEmpty);
      for (final f in stored) {
        expect(latin1.decode(f.readAsBytesSync()).contains('PLAINTEXTMARKER'), isFalse);
      }

      // Second run: nothing changed, nothing re-sent.
      final second = await sync.backupAll(session);
      expect(second.uploaded, 0);
      expect(second.unchanged, 3);
      expect(second.wireBytes, lessThan(4096));

      // Rename one item, delete another: only metadata and a delete marker go up.
      await session.upsertItem(session.entryById('pic')!.item.copyWith(title: 'renamed.jpg'));
      await session.delete('note');
      final third = await sync.backupAll(session);
      expect(third.uploaded, 1);
      expect(third.removed, 1);
      expect(third.wireBytes, lessThan(16 * 1024), reason: 'a rename must not re-upload the photo');
      await session.close();

      // "New phone": only the server address, account id and recovery secret.
      final api = SyncApi(serverUrl);
      final identity = await recoverAccess(api, status.account!, unhex(secretText.replaceAll(' ', '')));
      await useIdentity(api, identity);
      final engine = await SyncEngine.create(api: api, keys: await identity.keys(), journal: MemoryJournalStore());
      final out = await engine.restoreAll(Directory('${tmp.path}/restored'));
      final byName = {for (final f in out) f.uri.pathSegments.last: f};
      expect(byName.keys.toSet(), {'clip.mp4', 'renamed.jpg'});
      expect(await byName['clip.mp4']!.readAsBytes(), video);
      expect(await byName['renamed.jpg']!.readAsBytes(), photo);
      api.close();
    });
  });

  test('release builds take https, or http only to this phone itself', () {
    Uri n(String s) => VaultSync.normalizeServer(s, allowHttp: false);
    expect(n('backup.example.org').toString(), 'https://backup.example.org/');
    expect(n('http://127.0.0.1:8080').toString(), 'http://127.0.0.1:8080/');
    expect(n('http://localhost:8080').scheme, 'http');
    expect(() => n('http://192.168.1.41:8080'), throwsA(isA<SyncSetupException>()));
    expect(() => n('http://backup.example.org'), throwsA(isA<SyncSetupException>()));
    expect(() => n('ftp://backup.example.org'), throwsA(isA<SyncSetupException>()));
  });
}
