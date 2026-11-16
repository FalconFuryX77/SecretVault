// The in-vault camera on a phone or emulator: a photo (stored with its
// metadata removed), a video (encrypted while recorded, streamed into the
// vault as an MP4 that Android's own parser and the vault's player both
// read), the front camera, and a video cut off by a lock that moves in at
// the next unlock. Run through tool/camera_test.sh, which screenshots the
// preview when this test prints "[cam] shot <name>".
//
// Uses a throwaway vault in the app's temp folder.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/camera/vault_camera.dart';
import 'package:gesture_unlock/models/vault_item.dart';
import 'package:gesture_unlock/providers/unlock_provider.dart';
import 'package:gesture_unlock/providers/vault_provider.dart';
import 'package:gesture_unlock/recorder/vault_recorder.dart';
import 'package:gesture_unlock/screens/camera_screen.dart';
import 'package:gesture_unlock/screens/file_viewer_screen.dart';
import 'package:gesture_unlock/services/vault_service.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('camera: photo, video, front camera, video cut off by a lock', (t) async {
    expect(await Permission.camera.isGranted, isTrue, reason: 'the script grants the camera');
    final base = await getTemporaryDirectory();
    final dir = await Directory('${base.path}/camera_it_${DateTime.now().microsecondsSinceEpoch}').create();
    final staging = Directory(await VaultRecorder.stagingPath());
    final stagedBefore = staging.listSync().map((e) => e.path).toSet();

    const pin = 'camera-test-1';
    final svc = VaultService(storageDir: () async => dir);
    await svc.create(pin: pin, initialChunks: 512);
    final vault = VaultProvider(vaultService: svc);
    final unlock = UnlockProvider(vaultService: svc);

    Widget app(Widget home) => MultiProvider(
          providers: [
            Provider<VaultService>.value(value: svc),
            ChangeNotifierProvider.value(value: vault),
            ChangeNotifierProvider.value(value: unlock),
          ],
          child: MaterialApp(key: UniqueKey(), home: home),
        );

    Future<void> waitFor(bool Function() ok, String what, {int seconds = 30}) async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (!ok()) {
        if (DateTime.now().isAfter(end)) fail('Timed out waiting for $what');
        await t.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }

    Future<void> hold(int seconds) async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (DateTime.now().isBefore(end)) {
        await t.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }

    String status() {
      final f = find.byKey(const Key('camera-status'));
      return f.evaluate().isEmpty ? '' : (t.widget<Text>(f).data ?? '');
    }

    List<VaultItem> items(VaultCategory c) => svc.session!.entries.map((e) => e.item).where((i) => i.category == c).toList();

    Future<void> shot(String name) async {
      await hold(2);
      // ignore: avoid_print
      print('[cam] shot $name');
      await hold(2);
    }

    // ── 1. A photo ──
    await t.pumpWidget(app(const CameraScreen()));
    await waitFor(() => find.byType(Texture).evaluate().isNotEmpty, 'the preview');
    await shot('back-photo');
    await t.tap(find.byKey(const Key('camera-shutter')));
    await waitFor(() => status().contains('Photo saved') || status().contains("wasn't"), 'the photo');
    expect(status(), contains('Photo saved'));
    final photo = items(VaultCategory.image).single;
    final jpeg = await svc.session!.readAll(svc.session!.entryById(photo.id)!);
    expect(jpeg.sublist(0, 2), [0xFF, 0xD8]);
    // The only EXIF left, if any, is the tiny orientation-only block.
    for (var i = 2; i + 4 < jpeg.length;) {
      if (jpeg[i] != 0xFF) break;
      final marker = jpeg[i + 1];
      if (marker == 0xDA) break;
      final len = (jpeg[i + 2] << 8) | jpeg[i + 3];
      expect(marker == 0xE1 && len > 40, isFalse, reason: 'no full EXIF/XMP segment');
      expect(marker == 0xFE, isFalse, reason: 'no comment segment');
      expect(marker >= 0xE3 && marker <= 0xEF, isFalse, reason: 'no other metadata segments');
      i += 2 + len;
    }
    final codec = await ui.instantiateImageCodec(jpeg);
    final frame = await codec.getNextFrame();
    // ignore: avoid_print
    print('[cam] photo ${frame.image.width}x${frame.image.height}, ${jpeg.length} bytes');
    expect(frame.image.width, greaterThan(100));
    frame.image.dispose();

    // ── 2. A video ──
    await t.tap(find.byKey(const Key('camera-mode-video')));
    await hold(2);
    await waitFor(() => find.byType(Texture).evaluate().isNotEmpty, 'the video preview');
    await shot('back-video');
    await t.tap(find.byKey(const Key('camera-shutter')));
    await waitFor(() => find.byKey(const Key('camera-timer')).evaluate().isNotEmpty, 'recording to start');
    expect(staging.listSync().map((e) => e.path).toSet().difference(stagedBefore), hasLength(1),
        reason: 'the video is staged (encrypted) while it records');
    expect(await VaultRecorder.pending(), isEmpty, reason: 'a video being written is never offered for import');
    await hold(5);
    await t.tap(find.byKey(const Key('camera-shutter')));
    await waitFor(() => status().contains('Video saved') || status().contains("wasn't"), 'the video to move in', seconds: 90);
    expect(status(), contains('Video saved'));
    final video = items(VaultCategory.video).single;
    expect(video.title, endsWith('.mp4'));
    final mp4 = await svc.session!.readAll(svc.session!.entryById(video.id)!);
    final probe = await VaultRecorder.probeMedia(mp4);
    // ignore: avoid_print
    print('[cam] video ${mp4.length} bytes: $probe');
    final tracks = (probe['tracks'] as List).cast<Map<Object?, Object?>>();
    expect(tracks.map((m) => m['mime']), contains('video/avc'));
    expect(tracks.map((m) => m['mime']), contains('audio/mp4a-latm'));
    final ms = int.parse(probe['durationMs'] as String);
    expect(ms, inInclusiveRange(3000, 9000));
    expect(probe['syncs'] as int, greaterThanOrEqualTo(3), reason: 'a key frame every second');
    expect(probe['frame'], isNotNull, reason: 'a frame decodes');

    // It plays in the vault's own player.
    await t.pumpWidget(app(FileViewerScreen(item: video)));
    await waitFor(() => find.byKey(const Key('media-duration')).evaluate().isNotEmpty, 'the video to load');
    await hold(2);
    final shown = t.widget<Text>(find.byKey(const Key('media-duration'))).data!;
    // ignore: avoid_print
    print('[cam] player shows $shown');
    expect(shown, isNot('00:00'));
    await shot('player');
    await t.pumpWidget(const SizedBox());

    // ── 3. The front camera ──
    await t.pumpWidget(app(const CameraScreen()));
    await waitFor(() => find.byType(Texture).evaluate().isNotEmpty, 'the preview again');
    if (find.byKey(const Key('camera-switch')).evaluate().isNotEmpty) {
      await t.tap(find.byKey(const Key('camera-switch')));
      await hold(2);
      await waitFor(() => find.byType(Texture).evaluate().isNotEmpty, 'the front preview');
      await shot('front-photo');
      await t.tap(find.byKey(const Key('camera-shutter')));
      await waitFor(() => status().contains('Photo saved') || status().contains("wasn't"), 'the front photo');
      expect(items(VaultCategory.image), hasLength(2));
    }

    // ── 4. A video cut off by a lock moves in at the next unlock ──
    await t.tap(find.byKey(const Key('camera-mode-video')));
    await hold(2);
    await waitFor(() => find.byType(Texture).evaluate().isNotEmpty, 'the video preview again');
    await t.tap(find.byKey(const Key('camera-shutter')));
    await waitFor(() => find.byKey(const Key('camera-timer')).evaluate().isNotEmpty, 'the second recording');
    await hold(3);
    // What a lock does: the vault closes and the camera screen goes away.
    await svc.lock();
    await t.pumpWidget(const SizedBox());
    await hold(3);
    expect(await VaultRecorder.pending(), hasLength(1), reason: 'the cut-off video waits, encrypted');
    await svc.unlockWithPin(pin);
    expect(await vault.importRecordings(), 1);
    expect(items(VaultCategory.video), hasLength(2));
    final second = items(VaultCategory.video).firstWhere((i) => i.id != video.id);
    final probe2 = await VaultRecorder.probeMedia(await svc.session!.readAll(svc.session!.entryById(second.id)!));
    // ignore: avoid_print
    print('[cam] cut-off video: ${second.title}: $probe2');
    expect(probe2['frame'], isNotNull);

    // Nothing left behind in staging.
    expect(staging.listSync().map((e) => e.path).toSet().difference(stagedBefore), isEmpty);
    await VaultCamera.close();
    await svc.lock();
    await dir.delete(recursive: true);
  });
}
