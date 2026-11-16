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
import 'package:gesture_unlock/services/vault_service.dart';
import 'package:gesture_unlock/sync/auto_backup.dart';
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
      final secretText = await sync.connect(
        session,
        server: serverUrl.toString(),
        recoverySecret: VaultSync.newRecoverySecret(),
      );
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

    test('through Tor (Orbot\'s proxy): every request goes through it; switched off, none do', () async {
      if (server == null) {
        markTestSkipped('python sync server not available');
        return;
      }
      // A stand-in for Orbot's HTTP proxy.
      final seen = <String>[];
      final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final upstream = HttpClient();
      const hop = {'host', 'connection', 'proxy-connection', 'keep-alive', 'content-length', 'transfer-encoding'};
      proxy.listen((req) async {
        seen.add('${req.method} ${req.uri}');
        final out = await upstream.openUrl(req.method, req.uri);
        req.headers.forEach((k, v) {
          if (!hop.contains(k)) v.forEach((x) => out.headers.add(k, x));
        });
        out.contentLength = req.contentLength;
        await out.addStream(req);
        final resp = await out.close();
        req.response.statusCode = resp.statusCode;
        resp.headers.forEach((k, v) {
          if (!hop.contains(k)) v.forEach((x) => req.response.headers.add(k, x));
        });
        req.response.contentLength = resp.contentLength;
        await req.response.addStream(resp);
        await req.response.close();
      });
      final defaultPort = VaultSync.torProxyPort;
      VaultSync.torProxyPort = proxy.port;
      try {
        expect(await VaultSync.torAvailable(), isTrue);
        final s = await VaultContainer.create(File('${tmp.path}/c3.bin'), crypto, pin: '333444', initialChunks: 64);
        final sync = VaultSync();
        await sync.connect(s, server: serverUrl.toString(), recoverySecret: VaultSync.newRecoverySecret(), tor: true);
        expect(VaultSync.usesTor(s), isTrue);
        await s.upsertItem(fileItem('t1', 'One', 'text/plain', VaultCategory.note).copyWith(content: 'via tor'));
        final r = await sync.backupAll(s);
        expect(r.uploaded, 1);
        expect(seen.where((l) => l.contains('/v1/accounts')), isNotEmpty, reason: 'account created through the proxy');
        expect(seen.where((l) => l.contains('/v1/log')), isNotEmpty, reason: 'backup went through the proxy');
        final before = seen.length;
        await sync.setTor(s, false);
        await s.upsertItem(fileItem('t2', 'Two', 'text/plain', VaultCategory.note).copyWith(content: 'direct'));
        await sync.backupAll(s);
        expect(seen.length, before, reason: 'switched off: straight to the server');
        await s.close();
      } finally {
        VaultSync.torProxyPort = defaultPort;
        await proxy.close(force: true);
        upstream.close(force: true);
      }
      await proxy.close(force: true);
      expect(await VaultSync.torAvailable(), isFalse, reason: 'nothing listening on Orbot\'s port here');
    });

    test('automatic backup: on unlock, after a change, not for its own journal saves, off when switched off', () async {
      if (server == null) {
        markTestSkipped('python sync server not available');
        return;
      }
      final vaults = VaultService(crypto: crypto, storageDir: () async => Directory('${tmp.path}/auto'));
      final sync = VaultSync();
      final auto = AutoBackup(
        vaults: vaults,
        sync: sync,
        afterChange: const Duration(milliseconds: 300),
        afterUnlock: const Duration(milliseconds: 300),
      );
      var s = await vaults.create(pin: '482913', initialChunks: 64);
      await s.upsertItem(fileItem('n1', 'One', 'text/plain', VaultCategory.note).copyWith(content: 'one'));
      await sync.connect(s, server: serverUrl.toString(), recoverySecret: VaultSync.newRecoverySecret());
      await vaults.lock();

      Future<int> backedUp() async {
        final j = (vaults.session!.extras['sync.journal'] as Map?) ?? const {};
        return ((j['jobs'] as Map?) ?? const {}).values.where((v) => (v as Map)['state'] == 'committed').length;
      }

      Future<void> until(Future<bool> Function() ok, String what) async {
        for (var i = 0; i < 100; i++) {
          if (await ok()) return;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        fail('timed out waiting for $what');
      }

      s = (await vaults.unlockWithPin('482913'))!;
      await until(() async => await backedUp() == 1, 'the backup after unlocking');
      await until(() async => !auto.state.value.running, 'the run to finish');
      await s.upsertItem(fileItem('n2', 'Two', 'text/plain', VaultCategory.note).copyWith(content: 'two'));
      await until(() async => await backedUp() == 2, 'the backup after a change');
      // Its own journal saves are commits too, but they don't start runs.
      await until(() async => !auto.state.value.running, 'the run to finish');
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(auto.state.value.running, isFalse);
      expect(auto.state.value.nextAttempt, isNull);
      // Switched off: changes stay local.
      await auto.setEnabled(s, false);
      await s.upsertItem(fileItem('n3', 'Three', 'text/plain', VaultCategory.note).copyWith(content: '3'));
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(await backedUp(), 2);
      await vaults.lock();
      expect(auto.state.value.running, isFalse);
      auto.dispose();
    });

    test('a new phone restores from the recovery code alone; missing files come back; a taken phone is cut off', () async {
      if (server == null) {
        markTestSkipped('python sync server not available');
        return;
      }
      final a = await newVault();
      final video = noise(1500000, 21);
      await a.importBytes(video, fileItem('vid', 'clip.mp4', 'video/mp4', VaultCategory.video));
      await a.upsertItem(fileItem('note', 'Notes', 'text/plain', VaultCategory.note).copyWith(content: 'meet at 6'));
      final sync = VaultSync();
      final rs = VaultSync.newRecoverySecret();
      final code = await sync.connect(a, server: serverUrl.toString(), recoverySecret: rs);
      await sync.backupAll(a);
      expect(VaultSync.parseRecoverySecret(code), rs);
      expect(VaultSync.parseRecoverySecret(code.toUpperCase().replaceAll(' ', '-')), rs);
      expect(VaultSync.parseRecoverySecret('not a code'), isNull);

      // New phone: a fresh vault, the server address and the code. No
      // account id, nothing else.
      final b = await VaultContainer.create(File('${tmp.path}/c2.bin'), crypto, pin: '111222', initialChunks: 64);
      final summary = await sync.recoverInto(b, server: serverUrl.toString(), recoverySecret: rs);
      expect(summary.restored, 2);
      expect(summary.failed, isEmpty);
      expect(await b.readAll(b.entryById('vid')!), video);
      expect(b.entryById('note')!.item.content, 'meet at 6');
      // It's backed up already: nothing goes up again.
      final again = await sync.backupAll(b);
      expect(again.uploaded, 0);
      expect(again.unchanged, 2);

      // A file deleted by mistake comes back.
      await b.delete('vid');
      final missing = await sync.restoreMissing(b);
      expect(missing.restored, 1);
      expect(await b.readAll(b.entryById('vid')!), video);

      // Phone A was taken: B sees it, revokes it, and A is cut off.
      final devices = await sync.devices(b);
      expect(devices, hasLength(2));
      final aDevice = devices.firstWhere((d) => !d.isThisPhone);
      await expectLater(sync.revoke(b, VaultSync.newRecoverySecret(), [aDevice.id]), throwsA(isA<SyncSetupException>()));
      await sync.revoke(b, rs, [aDevice.id]);
      expect((await sync.devices(b)).firstWhere((d) => d.id == aDevice.id).revoked, isNotNull);
      await a.upsertItem(fileItem('n2', 'More', 'text/plain', VaultCategory.note).copyWith(content: 'x'));
      await expectLater(sync.backupAll(a), throwsA(isA<ApiException>()), reason: 'the taken phone can no longer back up');

      // Start over: a new account, everything uploaded again, the old one closed.
      final oldAccount = sync.status(b).account;
      final fresh = await sync.startOver(b, rs);
      expect(fresh.uploaded, 2);
      expect(sync.status(b).account, isNot(oldAccount));
      expect(sync.startOverPending(b), isFalse);
      final api = SyncApi(serverUrl);
      expect(await findAccounts(api, rs), [sync.status(b).account]);
      api.close();
      await a.close();
      await b.close();
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
