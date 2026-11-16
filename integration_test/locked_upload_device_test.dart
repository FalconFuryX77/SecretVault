// Uploading while locked, on a real phone or emulator: the native queue
// (Outbox.kt) and its WorkManager job. Backups made without a connection go
// into the queue sealed; the background job sends them with an upload-only
// login; the next backup settles. The stop code on the lock screen, and
// "Clear cache" in the cover app, wipe the queue and its login.
//
// Needs a server the device can reach:
//   bash tool/device_test.sh integration_test/locked_upload_device_test.dart <device> --dart-define=SYNC_SERVER=http://127.0.0.1:8077
// (with `adb reverse tcp:8077 tcp:8077` and a server on the PC's port 8077).
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/cover/trimmer_home_screen.dart';
import 'package:gesture_unlock/models/vault_item.dart';
import 'package:gesture_unlock/providers/unlock_provider.dart';
import 'package:gesture_unlock/services/vault_service.dart';
import 'package:gesture_unlock/sync/outbox.dart';
import 'package:gesture_unlock/sync/vault_sync.dart';
import 'package:gesture_unlock/vault/crypto_primitives.dart';
import 'package:gesture_unlock/vault/platform_keys.dart';
import 'package:gesture_unlock/vault/vault_container.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:sync_core/sync_core.dart';

const server = String.fromEnvironment('SYNC_SERVER');

VaultItem _item(String id, String title, String mime, VaultCategory c) => VaultItem(
      id: id,
      title: title,
      category: c,
      mimeType: mime,
      fileSizeBytes: 0,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('locked upload: queue, background job, settle, stop code, Clear cache', (t) async {
    if (server.isEmpty) {
      markTestSkipped('needs --dart-define=SYNC_SERVER');
      return;
    }
    const outbox = PlatformOutbox();
    await outbox.stop(); // nothing left from an earlier run
    final rc = Directory('${(await getApplicationSupportDirectory()).parent.path}/no_backup/rc');
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/lu_${DateTime.now().microsecondsSinceEpoch}.bin');
    final crypto = VaultCrypto(binding: FixedDeviceBinding(), pinParams: KdfParams.testing, growChunks: 8);
    var s = await VaultContainer.create(file, crypto, pin: 'locked-real-1', initialChunks: 64);
    const fast = RetryPolicy(maxAttempts: 2, initialBackoff: Duration(milliseconds: 50), maxBackoff: Duration(milliseconds: 100));
    final sync = VaultSync(retry: fast);
    Future<void> until(Future<bool> Function() ok, String what, {int seconds = 120}) async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (!await ok()) {
        if (DateTime.now().isAfter(end)) fail('Timed out waiting for $what');
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }

    try {
      await sync.connect(s, server: server, recoverySecret: VaultSync.newRecoverySecret(), invite: const String.fromEnvironment('SYNC_INVITE'));
      await sync.backupAll(s);
      expect((await sync.queueStatus(s)), isNotNull, reason: 'armed');
      final real = Map<String, dynamic>.from(s.extras['sync.config'] as Map);
      Future<void> offline(VaultSession v) => v.putExtra('sync.config', {...real, 'server': 'http://127.0.0.1:1'});
      Future<void> online(VaultSession v) => v.putExtra('sync.config', real);

      // ── No connection: into the native queue, sealed ──
      final photo = Uint8List.fromList(List.generate(250000, (i) => Random(7).nextInt(256)));
      await s.importBytes(photo, _item('pic', 'photo.jpg', 'image/jpeg', VaultCategory.image));
      await s.upsertItem(_item('note', 'Notes', 'text/plain', VaultCategory.note).copyWith(content: 'meet at the QUEUEMARKER gate'));
      await offline(s);
      final q = await sync.backupAll(s);
      expect(q.queued, 2);
      final st = (await sync.queueStatus(s))!;
      // ignore: avoid_print
      print('[locked] queued ${st.count} entries, ${st.bytes} B (cap ${st.cap} B)');
      expect(st.count, greaterThan(2));
      for (final f in rc.listSync(recursive: true).whereType<File>()) {
        final raw = latin1.decode(f.readAsBytesSync());
        expect(raw.contains('QUEUEMARKER'), isFalse, reason: f.path);
        expect(raw.contains('127.0.0.1'), isFalse, reason: 'the state file is sealed: ${f.path}');
      }

      // ── The background job sends it (as it would with the vault locked) ──
      await online(s);
      await outbox.kick();
      await until(() async => (await outbox.status()).count == 0, 'the background job to empty the queue');
      final settled = await sync.backupAll(s);
      // ignore: avoid_print
      print('[locked] after the job: ${settled.uploaded} sent directly, ${settled.unchanged} already there');
      expect(settled.uploaded, 0);
      expect(settled.unchanged, 2);

      // ── The stop code, typed on the lock screen ──
      await sync.setStopCode(s, 'stop-code-77');
      await s.upsertItem(_item('n2', 'More', 'text/plain', VaultCategory.note).copyWith(content: 'later'));
      await offline(s);
      expect((await sync.backupAll(s)).queued, 1);
      await s.close();
      final c = VaultContainer(file, crypto);
      expect(await c.unlockWithPin('stop-code-77', onNoMatch: outbox.stopIfMatches), isNull, reason: 'looks like a wrong PIN');
      expect((await outbox.status()).armed, isFalse);
      expect(rc.existsSync(), isFalse, reason: 'queue and state shredded');
      s = (await c.unlockWithPin('locked-real-1'))!;
      await online(s);
      expect((await sync.backupAll(s)).uploaded, 1, reason: 'what the queue lost goes directly');
      expect(VaultSync.lockedUploadStopped(s), isTrue);
      expect((await outbox.status()).armed, isFalse, reason: 'stays off');

      // ── "Clear cache" in the cover app ──
      await sync.setLockedUpload(s, true);
      await sync.backupAll(s);
      expect((await outbox.status()).armed, isTrue);
      final svc = VaultService(storageDir: () async => dir);
      await t.pumpWidget(MultiProvider(
        providers: [
          Provider<VaultService>.value(value: svc),
          ChangeNotifierProvider.value(value: UnlockProvider(vaultService: svc)),
        ],
        child: const MaterialApp(home: TrimmerHomeScreen()),
      ));
      await t.pump(const Duration(seconds: 1));
      await t.tap(find.byKey(const Key('cover-menu')));
      await t.pumpAndSettle();
      await t.tap(find.text('Clear cache'));
      for (var i = 0; i < 20 && find.text('Cache cleared').evaluate().isEmpty; i++) {
        await t.pump(const Duration(milliseconds: 200));
      }
      expect(find.text('Cache cleared'), findsOneWidget);
      expect((await outbox.status()).armed, isFalse);
      expect(rc.existsSync(), isFalse);
      // ignore: avoid_print
      print('[locked] stop code and Clear cache both wiped the queue');
    } finally {
      await outbox.stop();
      await s.close();
      if (file.existsSync()) file.deleteSync();
    }
  });
}
