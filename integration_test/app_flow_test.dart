// End-to-end UI flow on a real device or emulator, PIN-only build.
//
// Before running, grant the cover app's storage permissions so no system
// dialog interrupts the test (see tool/device_test.sh).
//
// Run:  flutter test integration_test/app_flow_test.dart -d <device> --dart-define=GESTURES=false
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';

import 'package:gesture_unlock/main.dart' as app;
import 'package:gesture_unlock/models/gesture.dart';
import 'package:gesture_unlock/models/vault_item.dart';
import 'package:gesture_unlock/providers/vault_provider.dart';
import 'package:gesture_unlock/services/security_channel_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:gesture_unlock/services/vault_service.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const realPin = 'flow-real-pin';
  const decoyPin = 'flow-decoy-pin';
  const noteTitle = 'Checkpoint notes';

  Future<void> waitFor(
    WidgetTester t,
    Finder f, {
    Duration timeout = const Duration(seconds: 45),
    bool gone = false,
  }) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await t.pump();
      if (f.evaluate().isEmpty == gone) return;
    }
    final onScreen = find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText())
        .whereType<String>()
        .where((s) => s.trim().isNotEmpty)
        .toSet()
        .join(' | ');
    final what = gone ? 'absence of $f' : '$f';
    throw TestFailure('Timed out waiting for $what. On screen: $onScreen');
  }

  Future<void> settle(WidgetTester t, [int ms = 600]) async {
    for (var i = 0; i < ms ~/ 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await t.pump();
    }
  }

  /// Waits for [f], lets any route transition finish (routes ignore input
  /// while animating), then taps it.
  Future<void> tapWhenReady(WidgetTester t, Finder f) async {
    await waitFor(t, f);
    await settle(t, 700);
    await t.tap(f);
    await t.pump();
  }

  /// The covert entrance: three quick taps on the cover app's title.
  Future<void> openLockScreen(WidgetTester t) async {
    final title = find.text('Files').first;
    await waitFor(t, title);
    await settle(t, 700);
    for (var i = 0; i < 3; i++) {
      await t.tap(title, warnIfMissed: false);
      await t.pump(const Duration(milliseconds: 120));
    }
    await waitFor(t, find.text('PIN Code'));
  }

  Future<void> enterPin(WidgetTester t, String pin) async {
    await tapWhenReady(t, find.text('PIN Code'));
    await waitFor(t, find.text('Unlock'));
    await settle(t, 500);
    await t.enterText(find.byType(TextField).last, pin);
    await tapWhenReady(t, find.text('Unlock'));
  }

  Future<void> lock(WidgetTester t) async {
    await tapWhenReady(t, find.byTooltip('Lock Safe'));
    await waitFor(t, find.text('Add File'), gone: true);
    await waitFor(t, find.text('Files'));
  }

  testWidgets('first run → vault → note → lock → covert reopen → decoy', (t) async {
    // Fresh install state.
    final container = await VaultService().containerFile();
    if (await container.exists()) await container.delete();
    await const FlutterSecureStorage().deleteAll();

    app.main();

    // ── Setup (PIN only in this build) ──
    await waitFor(t, find.text('Set Your Vault PIN'));
    final fields = find.byType(TextField);
    await t.enterText(fields.at(0), realPin);
    await t.enterText(fields.at(1), realPin);
    final setupClock = Stopwatch()..start();
    await tapWhenReady(t, find.text('Create Vault'));
    await waitFor(t, find.text('Add File'), timeout: const Duration(seconds: 90));
    // ignore: avoid_print
    print('[timing] setup → inside vault: ${setupClock.elapsedMilliseconds} ms');
    expect(await container.exists(), isTrue);

    // ── Add a note ──
    await tapWhenReady(t, find.text('Add File'));
    await waitFor(t, find.text('Create Encrypted Secret Note'));
    await tapWhenReady(t, find.text('Create Encrypted Secret Note'));
    await waitFor(t, find.text('Encrypted Note'));
    // Let the editor finish sliding in: until then the vault list (with its
    // own search field) is still on screen underneath.
    await settle(t, 800);
    await t.enterText(find.widgetWithText(TextField, 'Note Title...'), noteTitle);
    await t.enterText(
      find.widgetWithText(TextField, 'Type confidential note here...'),
      'Met source at 14:00. Do not record names.',
    );
    await tapWhenReady(t, find.byIcon(Icons.check_rounded));
    await waitFor(t, find.text(noteTitle));
    expect(find.text('1 protected item (41 B)'), findsOneWidget);

    // ── Lock: back to the cover app, vault UI gone ──
    await lock(t);
    expect(find.text(noteTitle), findsNothing);

    // ── Wrong PIN is refused ──
    await openLockScreen(t);
    await enterPin(t, 'not-the-pin');
    await waitFor(t, find.text('Not recognised.'), timeout: const Duration(seconds: 20));
    expect(find.text('Add File'), findsNothing);
    await settle(t, 1500);

    // ── Right PIN reopens the vault with the note ──
    final unlockClock = Stopwatch()..start();
    await enterPin(t, realPin);
    await waitFor(t, find.text(noteTitle));
    // ignore: avoid_print
    print('[timing] PIN entry → note visible: ${unlockClock.elapsedMilliseconds} ms');

    // ── Create a decoy from Settings ──
    await tapWhenReady(t, find.byTooltip('Settings'));
    await waitFor(t, find.text('Set Up Decoy Vault'));
    await tapWhenReady(t, find.text('Set Up Decoy Vault'));
    await waitFor(t, find.text('Save'));
    await t.enterText(find.widgetWithText(TextField, 'New PIN'), decoyPin);
    await t.enterText(find.widgetWithText(TextField, 'Confirm'), decoyPin);
    await tapWhenReady(t, find.text('Save'));
    await waitFor(t, find.text('Change Decoy PIN'), timeout: const Duration(seconds: 30));
    await tapWhenReady(t, find.byIcon(Icons.arrow_back_ios_new_rounded));
    await waitFor(t, find.text('Add File'));
    await lock(t);

    // ── Decoy PIN opens an empty vault with no trace of the real one ──
    await openLockScreen(t);
    await enterPin(t, decoyPin);
    await waitFor(t, find.text('Add File'));
    expect(find.text(noteTitle), findsNothing);
    await tapWhenReady(t, find.byTooltip('Settings'));
    await waitFor(t, find.text('Change PIN'));
    expect(find.text('DECOY VAULT'), findsNothing);
    expect(find.text('Set Up Decoy Vault'), findsNothing);
    await tapWhenReady(t, find.byIcon(Icons.arrow_back_ios_new_rounded));
    await waitFor(t, find.text('Add File'));
    await lock(t);

    // ── And the real vault still has its note ──
    await openLockScreen(t);
    await enterPin(t, realPin);
    await waitFor(t, find.text(noteTitle));

    // ── An encrypted image opens in the viewer, and closing the viewer
    //    must NOT drop screenshot protection for the vault underneath ──
    final ctx = t.element(find.text('Add File'));
    final vaultService = Provider.of<VaultService>(ctx, listen: false);
    final tmp = await getTemporaryDirectory();
    final png = File('${tmp.path}/pic.png')
      ..writeAsBytesSync(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
      ));
    await vaultService.session!.importFile(
      png,
      VaultItem(
        id: 'img-1',
        title: 'evidence.png',
        category: VaultCategory.image,
        mimeType: 'image/png',
        fileSizeBytes: 0,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
    await Provider.of<VaultProvider>(ctx, listen: false).loadVault(VaultType.primary);
    expect(SecurityChannelService.isSecure, isTrue, reason: 'vault open → protected');
    await tapWhenReady(t, find.text('evidence.png'));
    await waitFor(t, find.byType(Image));
    expect(find.textContaining('integrity check'), findsNothing);
    expect(SecurityChannelService.isSecure, isTrue);
    await settle(t, 500);
    await t.pageBack();
    await waitFor(t, find.text('Add File'));
    await settle(t, 600);
    expect(SecurityChannelService.isSecure, isTrue, reason: 'closing the viewer must keep the vault protected');

    await lock(t);
    // Back on the cover app: protection off once the lock screen is gone.
    await settle(t, 1500);
    expect(SecurityChannelService.isSecure, isFalse, reason: 'cover app must behave like a normal app');

    // ignore: avoid_print
    print('[info] container size: ${(await container.length()) ~/ (1024 * 1024)} MiB on ${Platform.operatingSystem}');
  });
}
