// The cover app, a video trimmer, really trims: a clip cut from a short
// video lands in Movies/Video Trimmer with the chosen length (with and
// without sound), shows in the home list, and can be deleted. Android's
// photo picker is skipped: a file:// address stands in for the picked video.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/cover/trim_editor_screen.dart';
import 'package:gesture_unlock/cover/trimmer_home_screen.dart';
import 'package:gesture_unlock/cover/video_trimmer.dart';
import 'package:gesture_unlock/providers/unlock_provider.dart';
import 'package:gesture_unlock/services/vault_service.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'fixtures/media_fixtures.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the cover trims videos for real', (t) async {
    final dir = await getTemporaryDirectory();
    final src = File('${dir.path}/street_${DateTime.now().microsecondsSinceEpoch}.mp4');
    await src.writeAsBytes(base64.decode(clipMp4Base64));
    final uri = Uri.file(src.path).toString();

    final info = await VideoTrimmer.info(uri);
    expect(info.duration.inMilliseconds, inInclusiveRange(2800, 3300));
    for (final c in await VideoTrimmer.recent()) {
      if (c.name.startsWith('Trim_')) await VideoTrimmer.delete(c.uri);
    }

    // Natively: 1.0 s to 2.5 s, without sound.
    final out = await VideoTrimmer.trim(uri, const Duration(milliseconds: 1000), const Duration(milliseconds: 2500), mute: true);
    final cut = await VideoTrimmer.info(out);
    // ignore: avoid_print
    print('[cover] trimmed clip ${cut.duration.inMilliseconds} ms, ${cut.width}x${cut.height}');
    // Cut at the key frame before the start, so a little longer is fine.
    expect(cut.duration.inMilliseconds, inInclusiveRange(1300, 2600));
    expect(await VideoTrimmer.frame(out, const Duration(milliseconds: 300)), isNotNull);

    // Through the screens: the editor saves, the home lists it.
    final svc = VaultService(storageDir: () async => dir);
    final unlock = UnlockProvider(vaultService: svc);
    Widget app(Widget home) => MultiProvider(
          providers: [
            Provider<VaultService>.value(value: svc),
            ChangeNotifierProvider.value(value: unlock),
          ],
          child: MaterialApp(key: UniqueKey(), home: home),
        );
    Future<void> until(bool Function() ok, String what) async {
      final end = DateTime.now().add(const Duration(seconds: 30));
      while (!ok()) {
        if (DateTime.now().isAfter(end)) fail('Timed out waiting for $what');
        await t.pump(const Duration(milliseconds: 200));
      }
    }

    await t.pumpWidget(app(TrimEditorScreen(uri: uri)));
    await until(() => find.byKey(const Key('trim-length')).evaluate().isNotEmpty, 'the editor');
    await t.tap(find.byKey(const Key('trim-save')));
    await until(() => find.byKey(const Key('trim-save')).evaluate().isEmpty, 'the save');
    final clips = await VideoTrimmer.recent();
    expect(clips.where((c) => c.name.startsWith('Trim_')), hasLength(2));

    await t.pumpWidget(app(const TrimmerHomeScreen()));
    await until(() => find.textContaining('Trim_').evaluate().length >= 2, 'the clips in the list');
    expect(find.text('Video Trimmer'), findsOneWidget);
    // ignore: avoid_print
    print('[cover] home lists ${find.textContaining('Trim_').evaluate().length} clips');

    for (final c in clips) {
      if (c.name.startsWith('Trim_')) expect(await VideoTrimmer.delete(c.uri), isTrue);
    }
    expect((await VideoTrimmer.recent()).where((c) => c.name.startsWith('Trim_')), isEmpty);
    await src.delete();
  });
}
