// Opens every in-vault viewer on a real phone: video and audio through the
// private loopback stream and the phone's media engine, PDFs through the
// isolated renderer process, Word documents and text (with an edit + save).
//
// Uses a throwaway vault in the app's temp folder; the app's own vault and
// everything outside the app are untouched.
//
//   tool/device_test.sh integration_test/viewers_device_test.dart <device-id>
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/models/vault_item.dart';
import 'package:gesture_unlock/providers/unlock_provider.dart';
import 'package:gesture_unlock/providers/vault_provider.dart';
import 'package:gesture_unlock/screens/file_viewer_screen.dart';
import 'package:gesture_unlock/services/vault_service.dart';
import 'package:gesture_unlock/vault/vault_container.dart';
import 'package:gesture_unlock/viewers/file_kind.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'fixtures/media_fixtures.dart';

/// A 16 kHz mono 16-bit WAV: [seconds] of a tone, about 32 KB per second,
/// so a 20 s file spans ten vault chunks.
Uint8List makeWav(int seconds) {
  const rate = 16000;
  final samples = rate * seconds;
  final b = ByteData(44 + samples * 2);
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  b.setUint32(4, 36 + samples * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  str(36, 'data');
  b.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    b.setInt16(44 + i * 2, (sin(2 * pi * 440 * i / rate) * 8000).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}

/// A real PDF: page 1 and 3 portrait, page 2 landscape, each with text and
/// a black box (so a drawn page has dark pixels).
Uint8List makePdf() {
  final sizes = [(612, 792), (792, 612), (612, 792)];
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${[for (var i = 0; i < 3; i++) '${4 + 2 * i} 0 R'].join(' ')}] /Count 3 >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  for (var i = 0; i < 3; i++) {
    final (w, h) = sizes[i];
    final content = 'BT /F1 48 Tf 72 ${h - 120} Td (Page ${i + 1}) Tj ET 0 0 0 rg 72 72 300 200 re f';
    objects.add('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $w $h] '
        '/Resources << /Font << /F1 3 0 R >> >> /Contents ${5 + 2 * i} 0 R >>');
    objects.add('<< /Length ${content.length} >>\nstream\n$content\nendstream');
  }
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    out.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return Uint8List.fromList(latin1.encode(out.toString()));
}

Uint8List makeDocx() {
  const ns = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"';
  const xml = '<?xml version="1.0" encoding="UTF-8"?><w:document $ns><w:body>'
      '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Source meeting</w:t></w:r></w:p>'
      '<w:p><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">Where: </w:t></w:r><w:r><w:t>the old market, north gate</w:t></w:r></w:p>'
      '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Time</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>14:10</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
      '</w:body></w:document>';
  final a = Archive()..addFile(ArchiveFile.bytes('word/document.xml', utf8.encode(xml)));
  return Uint8List.fromList(ZipEncoder().encodeBytes(a));
}

/// Files under the app's own storage, to show the viewers leave nothing behind.
Future<Set<String>> appFiles(List<Directory> roots, Directory exclude) async {
  final out = <String>{};
  for (final r in roots) {
    if (!await r.exists()) continue;
    await for (final e in r.list(recursive: true, followLinks: false)) {
      // profileInstalled: a 24-byte marker androidx.profileinstaller writes
      // after an install, unrelated to vault data.
      if (e is File && !e.path.startsWith(exclude.path) && !e.path.endsWith('/profileInstalled')) {
        out.add(e.path);
      }
    }
  }
  return out;
}

/// --dart-define=SHOWCASE=true holds each viewer on screen for screenshots.
const showcase = bool.fromEnvironment('SHOWCASE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every in-vault viewer works on the phone', (t) async {
    final base = await getTemporaryDirectory();
    final dir = await Directory('${base.path}/viewers_it_${DateTime.now().microsecondsSinceEpoch}').create();
    final roots = [
      base,
      await getApplicationSupportDirectory(),
      await getApplicationDocumentsDirectory(),
      Directory('${(await getApplicationSupportDirectory()).parent.path}/cache'),
    ];
    final before = await appFiles(roots, dir);

    final svc = VaultService(storageDir: () async => dir);
    final session = await svc.create(pin: 'viewers-test-1', initialChunks: 256);
    VaultItem meta(String title) => VaultItem(
          id: title,
          title: title,
          category: VaultCategory.document,
          mimeType: mimeForName(title),
          fileSizeBytes: 0,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
    final files = {
      'street.mp4': base64.decode(clipMp4Base64),
      'voice memo.m4a': base64.decode(toneM4aBase64),
      'interview.wav': makeWav(20),
      'report.pdf': makePdf(),
      'meeting.docx': makeDocx(),
      'contacts.txt': Uint8List.fromList(utf8.encode('Line one\nLine two')),
    };
    for (final MapEntry(key: name, value: data) in files.entries) {
      await session.importBytes(Uint8List.fromList(data), meta(name));
    }

    final vault = VaultProvider(vaultService: svc);
    final unlock = UnlockProvider(vaultService: svc);
    Future<void> open(String title) async {
      await t.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: vault),
          ChangeNotifierProvider.value(value: unlock),
        ],
        child: MaterialApp(
          key: UniqueKey(),
          home: FileViewerScreen(item: session.entryById(title)!.item),
        ),
      ));
    }

    Future<void> until(bool Function() ok, String what, {int seconds = 20}) async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (!ok()) {
        if (DateTime.now().isAfter(end)) {
          final shown = find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>().join(' | ');
          fail('Timed out waiting for $what. On screen: $shown');
        }
        await t.pump(const Duration(milliseconds: 200));
      }
    }

    Future<void> hold(String what) async {
      if (!showcase) return;
      // ignore: avoid_print
      print('[showcase] $what');
      final end = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(end)) {
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    String text(String key) => (t.widget<Text>(find.byKey(Key(key)))).data ?? '';
    int seconds(String clock) {
      final parts = clock.split(':').map(int.parse).toList();
      return parts.fold(0, (a, b) => a * 60 + b);
    }

    Future<void> checkPlays(String title, {required int duration}) async {
      final clock = Stopwatch()..start();
      await open(title);
      await until(() => find.byKey(const Key('media-duration')).evaluate().isNotEmpty || find.byKey(const Key('media-error')).evaluate().isNotEmpty, '$title to load');
      expect(find.byKey(const Key('media-error')), findsNothing, reason: title);
      expect(seconds(text('media-duration')), duration, reason: '$title duration');
      await until(() => seconds(text('media-position')) >= 1, '$title to play');
      // ignore: avoid_print
      print('[viewer] $title: playing after ${clock.elapsedMilliseconds} ms, duration ${text('media-duration')}');
    }

    // ── Video and audio through the loopback stream ──
    await checkPlays('street.mp4', duration: 3);
    expect(find.byType(AspectRatio), findsOneWidget, reason: 'a video surface is shown');
    await t.tap(find.byKey(const Key('media-play'))); // pause on a frame
    await hold('video');
    await checkPlays('voice memo.m4a', duration: 3);
    await checkPlays('interview.wav', duration: 20);
    // Skip forward: a range read from the middle of a ten-chunk file.
    await t.tap(find.byTooltip('Forward 10 seconds'));
    await until(() => seconds(text('media-position')) >= 10, 'the seek to land');
    // ignore: avoid_print
    print('[viewer] seek +10 s landed at ${text('media-position')}');

    // ── PDF through the isolated renderer ──
    final pdfClock = Stopwatch()..start();
    await open('report.pdf');
    await until(() => find.byKey(const Key('pdf-image-0')).evaluate().isNotEmpty || find.byKey(const Key('pdf-error')).evaluate().isNotEmpty, 'the first page');
    expect(find.byKey(const Key('pdf-error')), findsNothing);
    expect(text('pdf-page-label'), 'Page 1 of 3');
    final first = t.widget<RawImage>(find.byKey(const Key('pdf-image-0'))).image!;
    final px = (await first.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    var dark = 0;
    for (var i = 0; i < px.lengthInBytes; i += 4) {
      if (px.getUint8(i) < 64 && px.getUint8(i + 1) < 64 && px.getUint8(i + 2) < 64) dark++;
    }
    // ignore: avoid_print
    print('[viewer] PDF page 1 drawn ${first.width}x${first.height} in ${pdfClock.elapsedMilliseconds} ms, $dark dark pixels');
    expect(first.height / first.width, closeTo(792 / 612, 0.02));
    expect(dark, greaterThan(first.width * first.height ~/ 50), reason: 'the text and box were drawn');
    await hold('pdf');
    // Page 2 is landscape.
    await t.drag(find.byKey(const Key('pdf-pages')), const Offset(0, -900));
    await until(() => find.byKey(const Key('pdf-image-1')).evaluate().isNotEmpty, 'page 2');
    final second = t.widget<RawImage>(find.byKey(const Key('pdf-image-1'))).image!;
    expect(second.width / second.height, closeTo(792 / 612, 0.02));
    // Zoomed view draws the page sharper.
    await t.ensureVisible(find.byKey(const Key('pdf-page-1')));
    await t.pump(const Duration(milliseconds: 500));
    await t.tap(find.byKey(const Key('pdf-page-1')));
    await t.pump(const Duration(milliseconds: 50));
    await t.tap(find.byKey(const Key('pdf-page-1')));
    await until(() => find.text('Page 2 of 3').evaluate().isNotEmpty && find.byType(InteractiveViewer).evaluate().isNotEmpty, 'the zoomed page');
    await until(() => find.descendant(of: find.byType(InteractiveViewer), matching: find.byType(RawImage)).evaluate().isNotEmpty, 'the sharp render');
    final zoomed = t.widget<RawImage>(find.descendant(of: find.byType(InteractiveViewer), matching: find.byType(RawImage))).image!;
    expect(zoomed.width, greaterThan(second.width));
    // ignore: avoid_print
    print('[viewer] PDF zoom drawn ${zoomed.width}x${zoomed.height}');
    await hold('pdf zoom');

    // ── Word document ──
    await open('meeting.docx');
    await until(() => find.byKey(const Key('doc-summary')).evaluate().isNotEmpty || find.byKey(const Key('doc-error')).evaluate().isNotEmpty, 'the document');
    expect(find.byKey(const Key('doc-error')), findsNothing);
    expect(find.textContaining('Source meeting', findRichText: true), findsOneWidget);
    expect(find.text('14:10'), findsOneWidget);
    await hold('docx');

    // ── Text file: edit and save ──
    await open('contacts.txt');
    await until(() => find.byKey(const Key('text-edit')).evaluate().isNotEmpty, 'the text file');
    await t.tap(find.byKey(const Key('text-edit')));
    await t.pump(const Duration(milliseconds: 300));
    final field = t.widget<TextField>(find.byKey(const Key('text-editor')));
    expect(field.enableIMEPersonalizedLearning, isFalse, reason: 'the keyboard must not learn vault text');
    await t.enterText(find.byKey(const Key('text-editor')), 'Line one\nLine two\nNew contact: 0700 000 000');
    await t.pump();
    await t.tap(find.byKey(const Key('text-save')));
    await until(() => find.text('Saved').evaluate().isNotEmpty, 'the save');
    await hold('text saved');
    final saved = utf8.decode(await session.readAll(session.entryById('contacts.txt')!));
    expect(saved, endsWith('New contact: 0700 000 000'));

    // ── A tampered media file is refused, not played ──
    final wav = session.entryById('interview.wav')!;
    final chunk = wav.extents.expand((e) => e.chunks).elementAt(4);
    final raf = await (await svc.containerFile()).open(mode: FileMode.append);
    final at = ContainerLayout.chunkOffset(chunk) + 100;
    await raf.setPosition(at);
    final orig = (await raf.read(1))[0];
    await raf.setPosition(at);
    await raf.writeByte(orig ^ 0xff);
    await raf.close();
    await open('interview.wav');
    await until(() => find.byKey(const Key('media-error')).evaluate().isNotEmpty, 'the integrity failure', seconds: 30);
    expect(text('media-error'), contains('integrity check'));
    await hold('tampered');

    // Close everything; nothing decrypted may be left in the app's storage.
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    await svc.lock();
    final after = await appFiles(roots, dir);
    final added = after.difference(before);
    // ignore: avoid_print
    print('[viewer] files added to app storage by the viewers: ${added.isEmpty ? 'none' : added.join(', ')}');
    expect(added, isEmpty);
    await dir.delete(recursive: true);
  });
}
