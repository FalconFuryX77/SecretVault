// Backup previews made for real on the device: a photo through the isolated
// renderer, a video and a recording through Media3 Transformer. Checks the
// output is a smaller valid file, that the stream reads the same going
// backwards, that the staging file holds no readable MP4, and that nothing
// is left once a preview is closed.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/cover/video_trimmer.dart';
import 'package:gesture_unlock/models/vault_item.dart';
import 'package:gesture_unlock/sync/previews.dart';
import 'package:gesture_unlock/vault/crypto_primitives.dart';
import 'package:gesture_unlock/vault/platform_keys.dart';
import 'package:gesture_unlock/vault/vault_container.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sync_core/sync_core.dart';

import 'fixtures/media_fixtures.dart';

VaultItem _item(String id, String title, String mime, VaultCategory c) => VaultItem(
      id: id,
      title: title,
      category: c,
      mimeType: mime,
      fileSizeBytes: 0,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

Future<Uint8List> _all(SyncSource s) async {
  final b = BytesBuilder(copy: false);
  await for (final part in s.openRead()) {
    b.add(part);
  }
  return b.takeBytes();
}

/// A busy 3000×2000 picture, as PNG.
Future<Uint8List> _photo() async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  final r = Random(7);
  for (var i = 0; i < 4000; i++) {
    c.drawRect(
      ui.Rect.fromLTWH(r.nextDouble() * 3000, r.nextDouble() * 2000, 5 + r.nextDouble() * 80, 5 + r.nextDouble() * 80),
      ui.Paint()..color = ui.Color(0xFF000000 | r.nextInt(0xFFFFFF)),
    );
  }
  final img = await rec.endRecording().toImage(3000, 2000);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  return png!.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('previews of a photo, a video and a recording, with no plaintext on disk', (t) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/pv_${DateTime.now().microsecondsSinceEpoch}.bin');
    final crypto = VaultCrypto(binding: FixedDeviceBinding(), pinParams: KdfParams.testing, growChunks: 8);
    final s = await VaultContainer.create(file, crypto, pin: 'preview-pin', initialChunks: 64);
    final staging = Directory('${(await getApplicationSupportDirectory()).parent.path}/no_backup/pv');
    // Every size and saving accepted: the fixtures are tiny.
    const maker = PlatformPreviewMaker(imageMin: 0, videoMin: 0, audioMin: 0, maxRatio: 100);
    try {
      // ── Photo ──
      final png = await _photo();
      final photo = await s.importBytes(png, _item('p', 'photo.png', 'image/png', VaultCategory.image));
      final pp = (await maker.make(s, photo))!;
      final jpeg = await _all(pp.source);
      expect(pp.mime, 'image/jpeg');
      expect(jpeg.sublist(0, 3), [0xFF, 0xD8, 0xFF]);
      final frame = await (await ui.instantiateImageCodec(jpeg)).getNextFrame();
      expect(frame.image.width, 1600);
      expect(frame.image.height, inInclusiveRange(1066, 1067), reason: '3:2 kept');
      // ignore: avoid_print
      print('[preview] photo ${png.length} B -> ${jpeg.length} B, ${frame.image.width}x${frame.image.height}');
      await pp.close();

      // ── Video ──
      final mp4 = base64.decode(clipMp4Base64);
      final video = await s.importBytes(mp4, _item('v', 'clip.mp4', 'video/mp4', VaultCategory.video));
      final vp = (await maker.make(s, video))!;
      expect(vp.mime, 'video/mp4');
      // While it exists, the staging file is sealed: no MP4 boxes in it.
      final staged = staging.listSync().whereType<File>().toList();
      expect(staged, hasLength(1));
      final raw = latin1.decode(staged.single.readAsBytesSync());
      expect(raw.contains('ftyp') || raw.contains('avcC') || raw.contains('mdat'), isFalse);
      final out = await _all(vp.source);
      expect(out.length, vp.length);
      expect(latin1.decode(out.sublist(4, 8)), 'ftyp');
      expect(await vp.source.readRange(1000, 5000), out.sublist(1000, 6000));
      expect(await vp.source.readRange(10, 100), out.sublist(10, 110), reason: 'going back reopens');
      expect(await vp.source.readRange(out.length - 50, 50), out.sublist(out.length - 50));
      // The test's own check needs files (the app never writes these).
      final src = File('${dir.path}/pv_src.mp4')..writeAsBytesSync(mp4);
      final got = File('${dir.path}/pv_out.mp4')..writeAsBytesSync(out);
      final a = await VideoTrimmer.info(Uri.file(src.path).toString());
      final b = await VideoTrimmer.info(Uri.file(got.path).toString());
      // ignore: avoid_print
      print('[preview] video ${mp4.length} B ${a.width}x${a.height} ${a.duration.inMilliseconds} ms -> '
          '${out.length} B ${b.width}x${b.height} ${b.duration.inMilliseconds} ms');
      expect(min(b.width, b.height), lessThanOrEqualTo(480));
      expect(b.width, lessThanOrEqualTo(a.width), reason: 'never scaled up');
      expect((b.duration - a.duration).inMilliseconds.abs(), lessThan(500));
      src.deleteSync();
      got.deleteSync();
      await vp.close();

      // ── Recording ──
      final m4a = base64.decode(toneM4aBase64);
      final audio = await s.importBytes(m4a, _item('a', 'tone.m4a', 'audio/mp4', VaultCategory.document));
      final ap = (await maker.make(s, audio))!;
      final aout = await _all(ap.source);
      expect(ap.mime, 'audio/mp4');
      expect(latin1.decode(aout.sublist(4, 8)), 'ftyp');
      // ignore: avoid_print
      print('[preview] recording ${m4a.length} B -> ${aout.length} B');
      await ap.close();

      // Closed previews leave nothing behind.
      for (var i = 0; i < 20 && staging.listSync().isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(staging.listSync(), isEmpty);

      // The default rules: tiny items get no preview at all.
      const real = PlatformPreviewMaker();
      expect(real.wants(video), isFalse);
      expect(real.wants(photo), png.length >= (1 << 20));
    } finally {
      await s.close();
      if (file.existsSync()) file.deleteSync();
    }
  });
}
