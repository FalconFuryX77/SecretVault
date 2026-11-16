// The in-vault camera on a phone or emulator: a photo (stored with all its
// metadata, the place too when the phone knows it), a video (with its time,
// place and phone in the MP4; encrypted while recorded, streamed into the
// vault as an MP4 that Android's own parser and the vault's player both
// read), the front camera, and a video cut off by a lock that moves in at
// the next unlock. Run through tool/camera_test.sh, which screenshots the
// preview when this test prints "[cam] shot <name>".
//
// Uses a throwaway vault in the app's temp folder.
import 'dart:convert';
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
import 'package:gesture_unlock/viewers/image_view.dart';
import 'package:gesture_unlock/viewers/pdf_sandbox.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

/// [jpeg] with every APP1 segment replaced by a minimal EXIF block that
/// says [orientation].
Uint8List withOrientation(Uint8List jpeg, int orientation) {
  final out = BytesBuilder()..add([0xFF, 0xD8]);
  final tiff = [0x4D, 0x4D, 0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, orientation, 0, 0, 0, 0, 0, 0];
  final body = [...'Exif'.codeUnits, 0, 0, ...tiff];
  out.add([0xFF, 0xE1, (body.length + 2) >> 8, (body.length + 2) & 0xff, ...body]);
  var i = 2;
  while (i + 4 <= jpeg.length) {
    final marker = jpeg[i + 1];
    if (marker == 0xDA) {
      out.add(jpeg.sublist(i));
      break;
    }
    final len = (jpeg[i + 2] << 8) | jpeg[i + 3];
    if (marker != 0xE1) out.add(jpeg.sublist(i, i + 2 + len));
    i += 2 + len;
  }
  return out.toBytes();
}

Future<Uint8List> bigPng(int w, int h) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFF3366CC));
  c.drawCircle(Offset(w / 2, h / 2), h / 3, Paint()..color = const Color(0xFFFFCC00));
  final img = await rec.endRecording().toImage(w, h);
  final png = (await img.toByteData(format: ui.ImageByteFormat.png))!;
  img.dispose();
  return png.buffer.asUint8List();
}

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
    // The camera's EXIF is kept, and says where when the phone knew it.
    Uint8List? exif;
    for (var i = 2; i + 4 < jpeg.length;) {
      if (jpeg[i] != 0xFF) break;
      final marker = jpeg[i + 1];
      if (marker == 0xDA) break;
      final len = (jpeg[i + 2] << 8) | jpeg[i + 3];
      if (marker == 0xE1 && latin1.decode(jpeg.sublist(i + 4, i + 8)) == 'Exif') exif = jpeg.sublist(i + 4, i + 2 + len);
      i += 2 + len;
    }
    expect(exif, isNotNull, reason: "the camera's EXIF is kept");
    bool hasTag(int tag) =>
        indexOf(exif!, [tag >> 8, tag & 0xff]) >= 0 || indexOf(exif, [tag & 0xff, tag >> 8]) >= 0;
    final located = status().contains('where it was taken');
    // ignore: avoid_print
    print('[cam] photo EXIF ${exif!.length} bytes, located: $located, GPS: ${hasTag(0x8825)}');
    if (located) expect(hasTag(0x8825), isTrue, reason: 'GPSInfo in the EXIF');
    final codec = await ui.instantiateImageCodec(jpeg);
    final frame = await codec.getNextFrame();
    // ignore: avoid_print
    print('[cam] photo ${frame.image.width}x${frame.image.height}, ${jpeg.length} bytes');
    expect(frame.image.width, greaterThan(100));

    // ── 1b. The same photo decoded in the isolated process ──
    final sandboxed = await ImageSandbox.decode(Uint8List.fromList(jpeg));
    expect([sandboxed.width, sandboxed.height], [frame.image.width, frame.image.height],
        reason: 'same size and orientation as Flutter\'s own decoder');
    sandboxed.dispose();
    frame.image.dispose();
    final upright = await ImageSandbox.decode(withOrientation(jpeg, 1));
    final turned = await ImageSandbox.decode(withOrientation(jpeg, 6));
    expect([turned.width, turned.height], [upright.height, upright.width], reason: 'EXIF orientation is applied');
    upright.dispose();
    turned.dispose();
    final big = await ImageSandbox.decode(await bigPng(6000, 2600));
    // ignore: avoid_print
    print('[cam] 6000x2600 PNG decoded as ${big.width}x${big.height}');
    expect(big.width, lessThanOrEqualTo(ImageSandbox.maxSide));
    expect(big.width * big.height, lessThanOrEqualTo(ImageSandbox.maxPixels));
    expect((big.width / big.height - 6000 / 2600).abs(), lessThan(0.01), reason: 'shape kept');
    big.dispose();
    await expectLater(ImageSandbox.decode(Uint8List.fromList(List.filled(5000, 7))),
        throwsA(isA<PdfSandboxException>().having((e) => e.problem, 'problem', PdfProblem.broken)));
    // Truncated JPEG: refused or decoded partially, never a crash of the app.
    try {
      (await ImageSandbox.decode(Uint8List.fromList(jpeg.sublist(0, jpeg.length ~/ 3)))).dispose();
    } on PdfSandboxException catch (e) {
      expect(e.problem, isIn([PdfProblem.broken, PdfProblem.crashed]));
    }
    // The viewer uses it.
    await t.pumpWidget(app(FileViewerScreen(item: photo)));
    await waitFor(() => find.byKey(const Key('image-sandboxed')).evaluate().isNotEmpty, 'the sandboxed image in the viewer');
    await t.pumpWidget(app(const CameraScreen()));
    await waitFor(() => find.byType(Texture).evaluate().isNotEmpty, 'the preview after the viewer');

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
    // Like a phone camera's own videos: when, the phone, and where if known.
    final head = mp4.sublist(0, mp4.length < (1 << 20) ? mp4.length : 1 << 20);
    final mvhd = indexOf(head, latin1.encode('mvhd'));
    expect(mvhd, greaterThan(0));
    final created = ByteData.sublistView(head).getUint32(mvhd + 8) - 2082844800;
    final age = DateTime.now().millisecondsSinceEpoch ~/ 1000 - created;
    expect(age, inInclusiveRange(0, 300), reason: 'the MP4 says when it was recorded');
    expect(indexOf(head, latin1.encode('\u00A9mak')), greaterThan(0), reason: 'the make');
    expect(indexOf(head, latin1.encode('\u00A9mod')), greaterThan(0), reason: 'the model');
    // ignore: avoid_print
    print('[cam] video place: ${indexOf(head, latin1.encode('\u00A9xyz')) > 0}');

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

/// Where [needle] first occurs in [hay], or -1.
int indexOf(List<int> hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
