// The recorder on a real phone: recording from the vault screen, the
// volume-down ×3 trigger (screen on, then with the screen really off),
// recording while the vault is locked, refusal by another vault's key, and
// the move into the vault on unlock. Run through tool/recorder_phone_test.sh,
// which presses the volume key over adb when this test prints "[rec] press".
//
// Uses a throwaway vault in the app's temp folder.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/models/vault_item.dart';
import 'package:gesture_unlock/providers/unlock_provider.dart';
import 'package:gesture_unlock/providers/vault_provider.dart';
import 'package:gesture_unlock/recorder/vault_recorder.dart';
import 'package:gesture_unlock/screens/file_viewer_screen.dart';
import 'package:gesture_unlock/screens/recorder_screen.dart';
import 'package:gesture_unlock/services/vault_service.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

/// Whether the script can press a *hardware-level* volume key with the
/// screen off (an emulator, as root). Keys injected with `input keyevent`
/// are delivered to the (dark) screen instead of media sessions, so on a
/// physical phone this phase needs a person: run with HUMAN=1.
const screenOffPhase = bool.fromEnvironment('SCREEN_OFF_PHASE', defaultValue: true);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('recorder: vault screen, hidden trigger, locked recording, import', (t) async {
    expect(await Permission.microphone.isGranted, isTrue, reason: 'the script grants the microphone');
    final base = await getTemporaryDirectory();
    final dir = await Directory('${base.path}/recorder_it_${DateTime.now().microsecondsSinceEpoch}').create();
    final staging = Directory(await VaultRecorder.stagingPath());
    final stagedBefore = staging.listSync().map((e) => e.path).toSet();

    const pin = 'recorder-test-1';
    final svc = VaultService(storageDir: () async => dir);
    var session = await svc.create(pin: pin, initialChunks: 256);
    final vault = VaultProvider(vaultService: svc);
    final unlock = UnlockProvider(vaultService: svc);
    final pub = await RecordingKeys.publicKey(session);
    final myId = await VaultRecorder.keyId(pub);

    Widget app(Widget home) => MultiProvider(
          providers: [
            Provider<VaultService>.value(value: svc),
            ChangeNotifierProvider.value(value: vault),
            ChangeNotifierProvider.value(value: unlock),
          ],
          child: MaterialApp(key: UniqueKey(), home: home),
        );

    // With the screen off no frames are drawn, so waiting on a frame
    // (t.pump) would hang: those waits use plain timers ([pump] false).
    Future<RecorderStatus> until(bool Function(RecorderStatus) ok, String what,
        {int seconds = 30, bool pump = true}) async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (true) {
        final s = await VaultRecorder.status();
        if (ok(s)) return s;
        if (DateTime.now().isAfter(end)) {
          fail('Timed out waiting for $what (status: armed=${s.armed} recording=${s.recording} error=${s.error})');
        }
        if (pump) await t.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    Future<void> waitWidget(Finder f, String what, {int seconds = 30}) async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (f.evaluate().isEmpty) {
        if (DateTime.now().isAfter(end)) fail('Timed out waiting for $what');
        await t.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }

    Future<void> hold(int seconds, {bool pump = true}) async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (DateTime.now().isBefore(end)) {
        if (pump) await t.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }

    List<VaultItem> recordings() =>
        svc.session!.entries.map((e) => e.item).where((i) => i.tags.contains('recording')).toList();

    // ── 1. Record from the vault screen ──
    await t.pumpWidget(app(const RecorderScreen()));
    await t.pump(const Duration(milliseconds: 500));
    await t.tap(find.byKey(const Key('rec-button')));
    final started = await until((s) => s.recording, 'in-app recording to start');
    expect(started.recordingKey, myId);
    await hold(3);
    await t.tap(find.byKey(const Key('rec-button')));
    await waitWidget(find.text('Saved to the vault.'), 'the in-app recording to be saved');
    expect(recordings(), hasLength(1));
    // ignore: avoid_print
    print('[rec] in-app: ${recordings().single.title}, ${recordings().single.fileSizeBytes} bytes');

    // ── 1b. Long recordings are split into parts (here every ~2.8 s) ──
    await VaultRecorder.record(pub, rotateFrames: 120);
    await until((s) => s.recording, 'the split recording to start');
    await hold(5);
    await VaultRecorder.stop();
    await until((s) => !s.recording, 'the split recording to stop');
    expect(await vault.importRecordings(), 2, reason: 'two parts moved in');
    expect(recordings(), hasLength(3));

    // ── 2. Volume-down ×3, and recording on after the vault locks ──
    await VaultRecorder.arm(pub, vibrate: false, alwaysListen: true);
    await until((s) => s.armed && s.armedKey == myId, 'arming');
    await t.pumpWidget(const SizedBox());
    // ignore: avoid_print
    print('[rec] press volume (start)');
    await until((s) => s.recording, 'the volume trigger to start recording');
    await svc.lock(); // the vault locks; the recording must carry on
    await hold(3);
    // ignore: avoid_print
    print('[rec] press volume (stop)');
    await until((s) => !s.recording, 'the volume trigger to stop recording');

    final pending = await VaultRecorder.pending();
    expect(pending, hasLength(1));
    final staged = await File('${staging.path}/${pending.single.id}').readAsBytes();
    expect(latin1.decode(staged, allowInvalid: true).contains('ftyp'), isFalse, reason: 'no plain MP4 on disk');
    expect(staged.length, greaterThan(10000));
    final other = await VaultRecorder.newKeyPair();
    expect(await VaultRecorder.open(pending.single.id, other.priv), isNull, reason: "another vault's key can't open it");
    expect(await VaultRecorder.pending(), hasLength(1), reason: 'and leaves it in place');

    session = (await svc.unlockWithPin(pin))!;
    expect(await vault.importRecordings(), 1);
    expect(await VaultRecorder.pending(), isEmpty);
    expect(recordings(), hasLength(4));

    // The locked recording plays in the vault's own player.
    final locked = recordings().firstWhere((i) => i.createdAt.isAfter(started.startedAt!.add(const Duration(seconds: 2))));
    await t.pumpWidget(app(FileViewerScreen(item: locked)));
    await waitWidget(find.byKey(const Key('media-duration')), 'the recording to load');
    final duration = (t.widget<Text>(find.byKey(const Key('media-duration')))).data!;
    // ignore: avoid_print
    print('[rec] locked recording: ${locked.title}, duration $duration');
    expect(duration, isNot('00:00'));
    await t.pumpWidget(const SizedBox());

    // ── 3. With the screen really off ──
    if (screenOffPhase) {
      await VaultRecorder.arm(pub, vibrate: false, alwaysListen: false);
      await until((s) => s.armed, 're-arming');
      // ignore: avoid_print
      print('[rec] press screen-off (start)');
      await until((s) => s.recording, 'recording to start with the screen off', seconds: 60, pump: false);
      await hold(3, pump: false);
      // ignore: avoid_print
      print('[rec] press screen-off (stop)');
      await until((s) => !s.recording, 'recording to stop with the screen off', seconds: 60, pump: false);
      // ignore: avoid_print
      print('[rec] wake');
      await hold(2, pump: false);
      expect(await vault.importRecordings(), 1);
      expect(recordings(), hasLength(5));
    }

    await VaultRecorder.disarm();
    await until((s) => !s.armed, 'disarming', pump: false);

    // Nothing left in staging from this test.
    final stagedAfter = staging.listSync().map((e) => e.path).toSet();
    expect(stagedAfter.difference(stagedBefore), isEmpty);
    // ignore: avoid_print
    print('[rec] all recordings: ${recordings().map((i) => i.title).join(' | ')}');
    await svc.lock();
    await dir.delete(recursive: true);
  });
}
