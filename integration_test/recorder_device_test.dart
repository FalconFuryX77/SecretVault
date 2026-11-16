// The recorder on a real phone: recording from the vault screen, the
// volume-down ×3 trigger (screen on, then with the screen really off), a
// volume-up ×4 trigger that ignores mixed presses, the assistant button
// (and a forged assist intent, which must be ignored), recording while the
// vault is locked, refusal by another vault's key, and the move into the
// vault on unlock. Run through tool/recorder_phone_test.sh, which presses
// the keys over adb when this test prints "[rec] press" / "[rec] assist".
//
// Uses a throwaway vault in the app's temp folder.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

/// Whether the script may make this app the assistant app and press the
/// assistant key (emulators only: it changes a phone setting).
const assistKeyPhase = bool.fromEnvironment('ASSIST_KEY_PHASE', defaultValue: false);

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

    // ── 1c. Staged files look random; v2.1.0 files still move in; keys rotate ──
    Future<Uint8List> recordShort({bool legacyV1 = false, Uint8List? key}) async {
      await VaultRecorder.record(key ?? pub, legacyV1: legacyV1);
      await until((s) => s.recording, 'a short recording to start');
      await hold(2);
      await VaultRecorder.stop();
      await until((s) => !s.recording, 'the short recording to stop');
      final p = await VaultRecorder.pending();
      expect(p, hasLength(1));
      return File('${staging.path}/${p.single.id}').readAsBytes();
    }

    final v1 = await recordShort(legacyV1: true);
    expect(v1[2], 0x30, reason: 'the old format starts with a plain X.509 key');
    expect(await vault.importRecordings(), 1, reason: 'a v2.1.0 recording still moves in');

    final v2 = await recordShort();
    final head = v2.sublist(0, 4096);
    expect(head.toSet().length, greaterThan(200), reason: 'no structure in the first 4 KiB');
    expect(v2[2] == 0x30 && v2[3] == 0x59, isFalse, reason: 'no plain X.509 key');
    var zeros = 0;
    for (final b in head) {
      if (b == 0) zeros++;
    }
    expect(zeros, lessThan(64), reason: 'no runs of zeros (e.g. small plain lengths)');

    // Rotation a day later: the staged file (old pair) still moves in.
    final firstPub = base64.encode(pub);
    var rearmed = 0;
    expect(
      await RecordingKeys.rotateIfDue(svc.session!,
          status: await VaultRecorder.status(),
          rearm: (_) async => rearmed++,
          now: DateTime.now().add(const Duration(hours: 25))),
      isTrue,
    );
    expect(RecordingKeys.all(svc.session!), hasLength(2));
    expect(base64.encode(RecordingKeys.all(svc.session!).first.pub), isNot(firstPub));
    expect(rearmed, 0, reason: 'not armed, so nothing to re-arm');
    expect(await vault.importRecordings(), 1, reason: 'a retired pair still opens its recordings');
    expect(recordings(), hasLength(5));
    // Nine days on, the first pair is forgotten.
    await RecordingKeys.rotateIfDue(svc.session!,
        status: await VaultRecorder.status(),
        rearm: (_) async {},
        now: DateTime.now().add(const Duration(days: 9)));
    expect(RecordingKeys.all(svc.session!).map((k) => base64.encode(k.pub)), isNot(contains(firstPub)));
    final pubNow = await RecordingKeys.publicKey(svc.session!);
    final idNow = await VaultRecorder.keyId(pubNow);

    // ── 2. Volume-down ×3, and recording on after the vault locks ──
    await VaultRecorder.arm(pubNow, vibrate: false, alwaysListen: true);
    await until((s) => s.armed && s.armedKey == idNow, 'arming');
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
    expect(await VaultRecorder.open(pending.single.id, RecordingKeyPair(other.pub, other.priv)), isNull,
        reason: "another vault's key can't open it");
    expect(await VaultRecorder.pending(), hasLength(1), reason: 'and leaves it in place');

    session = (await svc.unlockWithPin(pin))!;
    expect(await vault.importRecordings(), 1);
    expect(await VaultRecorder.pending(), isEmpty);
    expect(recordings(), hasLength(6));

    // The locked recording plays in the vault's own player.
    final locked = recordings().firstWhere((i) => i.createdAt.isAfter(started.startedAt!.add(const Duration(seconds: 2))));
    await t.pumpWidget(app(FileViewerScreen(item: locked)));
    await waitWidget(find.byKey(const Key('media-duration')), 'the recording to load');
    final duration = (t.widget<Text>(find.byKey(const Key('media-duration')))).data!;
    // ignore: avoid_print
    print('[rec] locked recording: ${locked.title}, duration $duration');
    expect(duration, isNot('00:00'));
    await t.pumpWidget(const SizedBox());

    // ── 2b. Volume-up ×4 and the assistant button ──
    const upFour = TriggerSettings(button: 1, presses: 4, assist: true);
    await VaultRecorder.setAssistEnabled(true);
    expect((await VaultRecorder.assistState()).enabled, isTrue);
    await VaultRecorder.arm(pubNow, vibrate: false, alwaysListen: true, trigger: upFour);
    await until((s) => s.armed && s.armedKey == idNow, 'arming with volume-up ×4');
    final before2b = recordings().length;

    // up, up, down, up, up: the down press starts the count again.
    // ignore: avoid_print
    print('[rec] press mixed');
    await hold(4);
    expect((await VaultRecorder.status()).recording, isFalse, reason: 'mixed presses must not trigger');
    // ignore: avoid_print
    print('[rec] press down3');
    await hold(4);
    expect((await VaultRecorder.status()).recording, isFalse, reason: 'volume-down does nothing when up is chosen');

    // ignore: avoid_print
    print('[rec] press up4 (start)');
    await until((s) => s.recording, 'volume-up ×4 to start recording');
    await hold(2);
    // ignore: avoid_print
    print('[rec] press up4 (stop)');
    await until((s) => !s.recording, 'volume-up ×4 to stop recording');

    // An app forging an assist intent (with its own referrer) is ignored.
    // ignore: avoid_print
    print('[rec] assist-forged');
    await hold(4);
    expect((await VaultRecorder.status()).recording, isFalse, reason: 'a forged assist intent must not trigger');

    // ignore: avoid_print
    print('[rec] assist (start)');
    await until((s) => s.recording, 'the assist intent to start recording');
    await hold(2);
    // ignore: avoid_print
    print('[rec] assist (stop)');
    await until((s) => !s.recording, 'the assist intent to stop recording');
    var expected2b = 2;

    if (assistKeyPhase) {
      // ignore: avoid_print
      print('[rec] assist-key (start)');
      await until((s) => s.recording, 'the assistant key to start recording');
      expect((await VaultRecorder.assistState()).holder, isTrue);
      await hold(2);
      // ignore: avoid_print
      print('[rec] assist-key (stop)');
      await until((s) => !s.recording, 'the assistant key to stop recording');
      expected2b++;
    }

    // Not armed for the assistant button: the same intent does nothing.
    await VaultRecorder.arm(pubNow, vibrate: false, alwaysListen: true, trigger: upFour.copyWith(assist: false));
    await hold(1);
    // ignore: avoid_print
    print('[rec] assist (ignored)');
    await hold(4);
    expect((await VaultRecorder.status()).recording, isFalse, reason: 'assist must be allowed by the vault');

    expect(await vault.importRecordings(), expected2b);
    expect(recordings().length, before2b + expected2b);
    // ignore: avoid_print
    print('[rec] assist-done');
    await VaultRecorder.setAssistEnabled(false);
    expect((await VaultRecorder.assistState()).enabled, isFalse);

    // ── 3. With the screen really off ──
    if (screenOffPhase) {
      await VaultRecorder.arm(pubNow, vibrate: false, alwaysListen: false);
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
      final beforeOff = recordings().length;
      expect(await vault.importRecordings(), 1);
      expect(recordings(), hasLength(beforeOff + 1));
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
