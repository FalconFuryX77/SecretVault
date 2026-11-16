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
import 'package:gesture_unlock/sync/outbox.dart';
import 'package:gesture_unlock/sync/previews.dart';
import 'package:gesture_unlock/sync/vault_sync.dart';
import 'package:gesture_unlock/vault/crypto_primitives.dart';
import 'package:gesture_unlock/vault/platform_keys.dart';
import 'package:gesture_unlock/vault/vault_container.dart';
import 'package:gesture_unlock/vault/vault_index.dart';
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
        afterChangeQueued: const Duration(milliseconds: 300),
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

    test('automatic backup: with locked upload on, a change goes within seconds, before an auto-lock', () async {
      if (server == null) {
        markTestSkipped('python sync server not available');
        return;
      }
      final vaults = VaultService(crypto: crypto, storageDir: () async => Directory('${tmp.path}/quick'));
      final sync = VaultSync(outbox: MemoryOutbox());
      final auto = AutoBackup(
        vaults: vaults,
        sync: sync,
        afterChange: const Duration(minutes: 10),
        afterChangeQueued: const Duration(milliseconds: 300),
        afterUnlock: const Duration(milliseconds: 300),
      );
      final s = await vaults.create(pin: '482913', initialChunks: 64);
      await sync.connect(s, server: serverUrl.toString(), recoverySecret: VaultSync.newRecoverySecret());
      Future<int> backedUp() async {
        final j = (s.extras['sync.journal'] as Map?) ?? const {};
        return ((j['jobs'] as Map?) ?? const {}).values.where((v) => (v as Map)['state'] == 'committed').length;
      }

      auto.attach(s);
      await Future<void>.delayed(const Duration(seconds: 1));
      await s.upsertItem(fileItem('q1', 'Quick', 'text/plain', VaultCategory.note).copyWith(content: 'q'));
      for (var i = 0; i < 50 && await backedUp() < 1; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(await backedUp(), 1, reason: 'sent within seconds, not 10 minutes');
      // With locked upload off, the usual (here: 10 minute) wait applies.
      await sync.setLockedUpload(s, false);
      await s.upsertItem(fileItem('q2', 'Slow', 'text/plain', VaultCategory.note).copyWith(content: 's'));
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(await backedUp(), 1);
      await vaults.lock();
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

    test('version history: an old version and a deleted file come back as copies; freeing up space needs the code', () async {
      if (server == null) {
        markTestSkipped('python sync server not available');
        return;
      }
      final s = await newVault();
      await s.upsertItem(fileItem('note', 'Plan', 'text/plain', VaultCategory.note).copyWith(content: 'first draft'));
      final photo = noise(200000, 31);
      await s.importBytes(photo, fileItem('pic', 'photo.jpg', 'image/jpeg', VaultCategory.image));
      final sync = VaultSync();
      final rs = VaultSync.newRecoverySecret();
      await sync.connect(s, server: serverUrl.toString(), recoverySecret: rs);
      await sync.backupAll(s);
      // As the note editor saves: new text, new time.
      await s.upsertItem(s.entryById('note')!.item.copyWith(content: 'second draft', updatedAt: DateTime(2026, 11, 2)));
      await s.delete('pic');
      await sync.backupAll(s);

      final h = await sync.history(s);
      final note = h.firstWhere((f) => f.fileId == 'note');
      final pic = h.firstWhere((f) => f.fileId == 'pic');
      expect(note.versions, hasLength(2));
      expect(note.versions.first.current, isTrue);
      expect(note.inVault, isTrue);
      expect(pic.deleted, isTrue);
      expect(pic.inVault, isFalse);
      expect(pic.title, 'photo.jpg');

      final t1 = await sync.restoreVersion(s, note, note.versions.last);
      expect(t1, startsWith('Plan ('));
      expect(s.entries.firstWhere((e) => e.item.title == t1).item.content, 'first draft');
      expect(s.entryById('note')!.item.content, 'second draft', reason: 'the current note is untouched');
      final t2 = await sync.restoreVersion(s, pic, pic.versions.first);
      expect(await s.readAll(s.entries.firstWhere((e) => e.item.title == t2)), photo);

      // A wrong code removes nothing; with nothing kept, the old versions go.
      await expectLater(sync.freeUpSpace(s, VaultSync.newRecoverySecret()), throwsA(isA<SyncSetupException>()));
      await sync.setRetentionDays(s, 0);
      final r = await sync.freeUpSpace(s, rs);
      expect(r.versionsDropped, 2);
      expect(r.piecesDeleted, greaterThan(0));
      final after = await sync.history(s);
      final note2 = after.firstWhere((f) => f.fileId == 'note');
      expect(note2.versions.first.available, isTrue);
      expect(note2.versions.last.available, isFalse);
      expect(after.firstWhere((f) => f.fileId == 'pic').versions.single.available, isFalse);
      // The current version still comes back from the backup.
      await s.delete('note');
      expect((await sync.restoreMissing(s)).restored, 1);
      expect(s.entryById('note')!.item.content, 'second draft');
      await s.close();
    });

    test('previews go first; originals can wait for Wi-Fi; a restore uses a preview only while the original is missing', () async {
      if (server == null) {
        markTestSkipped('python sync server not available');
        return;
      }
      final s = await newVault();
      final video = noise(500000, 41);
      await s.importBytes(video, fileItem('vid', 'clip.mp4', 'video/mp4', VaultCategory.video));
      await s.upsertItem(fileItem('note', 'Notes', 'text/plain', VaultCategory.note).copyWith(content: 'hi'));
      final fake = _FakePreviews()..free = false;
      final sync = VaultSync(previews: fake);
      final rs = VaultSync.newRecoverySecret();
      await sync.connect(s, server: serverUrl.toString(), recoverySecret: rs);
      await sync.setOriginalsOnWifiOnly(s, true);

      // On mobile data: the preview and the note go, the video waits.
      final first = await sync.backupAll(s);
      expect(first.previews, 1);
      expect(first.waitingForWifi, 1);
      expect(first.uploaded, 1);
      expect(fake.made, ['vid']);

      // A new phone now: the preview stands in for the original.
      final b = await VaultContainer.create(File('${tmp.path}/c2.bin'), crypto, pin: '111222', initialChunks: 64);
      final syncB = VaultSync(previews: fake);
      expect((await syncB.recoverInto(b, server: serverUrl.toString(), recoverySecret: rs)).restored, 2);
      final pv = b.entryById(VaultSync.previewId('vid'))!;
      expect(pv.item.title, 'clip.mp4 (preview)');
      expect(utf8.decode(await b.readAll(pv)), 'preview of vid');
      expect(b.entryById('vid'), isNull);

      // On Wi-Fi the original follows; no second preview.
      fake.free = true;
      final second = await sync.backupAll(s);
      expect(second.previews, 0);
      expect(second.waitingForWifi, 0);
      expect(second.uploaded, 1);
      expect(fake.made, ['vid']);

      // A restore now brings the original and skips the preview.
      final c = await VaultContainer.create(File('${tmp.path}/c3.bin'), crypto, pin: '333444', initialChunks: 64);
      expect((await VaultSync(previews: fake).recoverInto(c, server: serverUrl.toString(), recoverySecret: rs)).restored, 2);
      expect(await c.readAll(c.entryById('vid')!), video);
      expect(c.entryById(VaultSync.previewId('vid')), isNull);
      expect((await syncB.restoreMissing(b)).restored, 1);
      expect(await b.readAll(b.entryById('vid')!), video);

      // Deleting the video deletes its preview from the backup too.
      await s.delete('vid');
      expect((await sync.backupAll(s)).removed, 2);
      final d = await VaultContainer.create(File('${tmp.path}/c4.bin'), crypto, pin: '555666', initialChunks: 64);
      expect((await VaultSync(previews: fake).recoverInto(d, server: serverUrl.toString(), recoverySecret: rs)).restored, 1);
      expect(d.entries.single.item.id, 'note');
      for (final v in [s, b, c, d]) {
        await v.close();
      }
    });

    test('locked upload: offline backups queue up, the phone sends them with an upload-only login, the next unlock settles', () async {
      if (server == null) {
        markTestSkipped('python sync server not available');
        return;
      }
      const fast = RetryPolicy(maxAttempts: 2, initialBackoff: Duration(milliseconds: 10), maxBackoff: Duration(milliseconds: 20));
      final outbox = MemoryOutbox();
      final sync = VaultSync(outbox: outbox, retry: fast);
      var s = await newVault();
      final rs = VaultSync.newRecoverySecret();
      await sync.connect(s, server: serverUrl.toString(), recoverySecret: rs);
      expect(VaultSync.lockedUpload(s), isTrue, reason: 'on by default');
      await sync.backupAll(s);
      expect(await sync.queueStatus(s), isNotNull, reason: 'armed by the first backup');
      final account = sync.status(s).account!;
      final real = Map<String, dynamic>.from(s.extras['sync.config'] as Map);
      Future<void> offline(VaultSession v) => v.putExtra('sync.config', {...real, 'server': 'http://127.0.0.1:1'});
      Future<void> online(VaultSession v) => v.putExtra('sync.config', real);

      // No connection: the new items go into the queue, sealed.
      final photo = noise(300000, 51);
      await s.importBytes(photo, fileItem('pic', 'photo.jpg', 'image/jpeg', VaultCategory.image));
      await s.upsertItem(fileItem('note', 'Notes', 'text/plain', VaultCategory.note).copyWith(content: 'gate at 6'));
      await offline(s);
      final q = await sync.backupAll(s);
      expect(q.queued, 2);
      expect(q.uploaded, 0);
      expect(outbox.queue, isNotEmpty);
      for (final (_, data) in outbox.queue) {
        expect(latin1.decode(data).contains('gate at 6'), isFalse);
      }

      // The phone, locked, sends them with its upload-only login, which
      // can read nothing back.
      final up = SyncApi(serverUrl)..useUploadToken(account, outbox.state!['token'] as String);
      expect(await outbox.deliver(up), greaterThan(2));
      await expectLater(up.readLog(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 403)));
      up.close();

      // Next unlock, online: everything arrived, nothing goes twice.
      await online(s);
      final settled = await sync.backupAll(s);
      expect(settled.uploaded, 0);
      expect(settled.unchanged, 2);
      final b = await VaultContainer.create(File('${tmp.path}/c2.bin'), crypto, pin: '111222', initialChunks: 64);
      expect((await VaultSync(outbox: MemoryOutbox()).recoverInto(b, server: serverUrl.toString(), recoverySecret: rs)).restored, 2);
      expect(await b.readAll(b.entryById('pic')!), photo);
      await b.close();

      // A stop code, typed on the lock screen, wipes the queue and its login.
      await expectLater(sync.setStopCode(s, '482913'), throwsA(isA<CredentialInUseException>()));
      await sync.setStopCode(s, 'stop-code-77');
      expect(VaultSync.hasStopCode(s), isTrue);
      expect((await outbox.status()).hasStopCode, isTrue);
      final token = outbox.state!['token'] as String;
      await s.upsertItem(fileItem('n2', 'More', 'text/plain', VaultCategory.note).copyWith(content: 'later'));
      await offline(s);
      expect((await sync.backupAll(s)).queued, 1);
      await s.close();
      final c = VaultContainer(File('${tmp.path}/c.bin'), crypto);
      expect(await c.unlockWithPin('not-the-stop-code', onNoMatch: outbox.stopIfMatches), isNull);
      expect((await outbox.status()).armed, isTrue);
      expect(await c.unlockWithPin('stop-code-77', onNoMatch: outbox.stopIfMatches), isNull, reason: 'looks like a wrong PIN');
      expect((await outbox.status()).armed, isFalse);
      expect(outbox.queue, isEmpty);

      // Next unlock, still offline: the stop is noticed and shown at once.
      s = (await c.unlockWithPin('482913'))!;
      expect(await sync.noticeStop(s), isTrue);
      expect(VaultSync.lockedUploadStopped(s), isTrue);
      expect(VaultSync.lockedUpload(s), isFalse);
      expect(await sync.noticeStop(s), isFalse, reason: 'once');
      // Online: what was queued goes directly; it stays off, and the old
      // login no longer works.
      await online(s);
      expect((await sync.backupAll(s)).uploaded, 1);
      expect(VaultSync.lockedUploadStopped(s), isTrue);
      expect(VaultSync.lockedUpload(s), isFalse);
      expect((await outbox.status()).armed, isFalse);
      final old = SyncApi(serverUrl)..useUploadToken(account, token);
      await expectLater(old.missing(['00' * 32]), throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)));
      old.close();

      // Turned on again here: armed again, the stop code with it.
      await sync.setLockedUpload(s, true);
      await sync.backupAll(s);
      expect(await sync.queueStatus(s), isNotNull);
      expect((await outbox.status()).hasStopCode, isTrue);

      // Known offline: straight into the queue, nothing tried on the
      // network; the next online backup sends the queue itself.
      await s.upsertItem(fileItem('n3', 'Third', 'text/plain', VaultCategory.note).copyWith(content: 'q3'));
      expect((await sync.backupAll(s, offline: true)).queued, 1);
      expect(outbox.queue, isNotEmpty);
      final drained = await sync.backupAll(s);
      expect(drained.uploaded, 0);
      expect(outbox.queue, isEmpty);

      // Cleared again ("Clear cache"), noticed offline, and turned on again
      // before any online backup: it stays on, and the old login dies.
      final token2 = outbox.state!['token'] as String;
      await outbox.stop();
      expect(await sync.noticeStop(s), isTrue);
      await sync.setLockedUpload(s, true);
      await sync.backupAll(s);
      expect(VaultSync.lockedUpload(s), isTrue);
      expect(await sync.queueStatus(s), isNotNull);
      final old2 = SyncApi(serverUrl)..useUploadToken(account, token2);
      await expectLater(old2.missing(['00' * 32]), throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)));
      old2.close();
      final fresh = SyncApi(serverUrl)..useUploadToken(account, outbox.state!['token'] as String);
      expect(await fresh.missing([]), isEmpty);
      fresh.close();

      // Another vault on the phone leaves this vault's queue alone, and
      // without a queue of its own an offline backup just fails as before.
      final d = await VaultContainer.create(File('${tmp.path}/c3.bin'), crypto, pin: '333444', initialChunks: 64);
      await sync.connect(d, server: serverUrl.toString(), recoverySecret: VaultSync.newRecoverySecret());
      await sync.backupAll(d);
      expect(await sync.queueStatus(d), isNull);
      expect(await sync.queueStatus(s), isNotNull);
      await d.upsertItem(fileItem('dn', 'Decoy', 'text/plain', VaultCategory.note).copyWith(content: 'x'));
      await offline(d);
      await expectLater(sync.backupAll(d), throwsA(anything));
      await d.close();

      // A full queue: what doesn't fit waits for the next unlock.
      outbox.cap = 2000;
      await s.importBytes(noise(200000, 52), fileItem('big', 'big.bin', 'application/octet-stream', VaultCategory.document));
      await offline(s);
      final full = await sync.backupAll(s);
      expect(full.queued, 0);
      outbox.cap = 1 << 30;
      await online(s);
      expect((await sync.backupAll(s)).uploaded, 1);
      await s.close();
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

/// Previews without the platform: a few bytes, for every video.
class _FakePreviews implements PreviewMaker {
  bool free = true;
  final made = <String>[];

  @override
  bool wants(IndexEntry entry) => entry.item.mimeType.startsWith('video/');

  @override
  Future<bool> unmetered() async => free;

  @override
  Future<Preview?> make(VaultSession session, IndexEntry entry) async {
    made.add(entry.item.id);
    final small = Uint8List.fromList(utf8.encode('preview of ${entry.item.id}'));
    return Preview(MemorySyncSource(small), small.length, 'video/mp4', () async {});
  }
}
