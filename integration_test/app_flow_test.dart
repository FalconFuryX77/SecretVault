// End-to-end UI flow on a real device or emulator.
//
// Before running, grant the cover app's storage permissions so no system
// dialog interrupts the test (see tool/device_test.sh).
//
// Run:  flutter test integration_test/app_flow_test.dart -d <device>
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';

import 'package:gesture_unlock/main.dart' as app;
import 'package:gesture_unlock/models/vault_item.dart';
import 'package:gesture_unlock/providers/vault_provider.dart';
import 'package:gesture_unlock/services/security_channel_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:gesture_unlock/services/vault_service.dart';
import 'package:integration_test/integration_test.dart';

/// Optional: --dart-define=SYNC_SERVER=http://127.0.0.1:8080 also drives the
/// Backup screen against a running sync server.
const syncServer = String.fromEnvironment('SYNC_SERVER');
const syncInvite = String.fromEnvironment('SYNC_INVITE', defaultValue: 'dev-invite');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const realPin = 'flow-real-pin';
  const decoyPin = 'flow-decoy-pin';
  const duressPin = 'flow-duress-pin';
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
    // On a real phone the keyboard can cover a button; scroll it into view.
    await t.ensureVisible(f);
    await settle(t, 300);
    await t.tap(f);
    await t.pump();
  }

  /// The covert entrance: three quick taps on the cover app's title.
  Future<void> openLockScreen(WidgetTester t) async {
    final title = find.byKey(const Key('cover-title'));
    await waitFor(t, title);
    await settle(t, 700);
    for (var i = 0; i < 3; i++) {
      await t.tap(title, warnIfMissed: false);
      await t.pump(const Duration(milliseconds: 120));
    }
    await waitFor(t, find.text('Unlock'));
  }

  Future<void> enterPin(WidgetTester t, String pin) async {
    await waitFor(t, find.text('Unlock'));
    await settle(t, 500);
    await t.enterText(find.byType(TextField).last, pin);
    await tapWhenReady(t, find.text('Unlock'));
  }

  Future<void> lock(WidgetTester t) async {
    await tapWhenReady(t, find.byTooltip('Lock Safe'));
    await waitFor(t, find.text('Add File'), gone: true);
    await waitFor(t, find.text('Video Trimmer'));
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
    await waitFor(t, find.text('1 protected item (41 B)'), timeout: const Duration(seconds: 10));

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
    // The decoy's Settings look like a lone real vault's: the same decoy
    // section, offering to set one up (it can't be told apart at a glance).
    expect(find.text('DECOY VAULT'), findsOneWidget);
    expect(find.text('Set Up Decoy Vault'), findsOneWidget);
    expect(find.text('Change Decoy PIN'), findsNothing);
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
    await Provider.of<VaultProvider>(ctx, listen: false).loadVault();
    expect(SecurityChannelService.isSecure, isTrue, reason: 'vault open → protected');
    await tapWhenReady(t, find.text('evidence.png'));
    await waitFor(t, find.byKey(const Key('image-sandboxed')));
    expect(find.textContaining('integrity check'), findsNothing);
    expect(SecurityChannelService.isSecure, isTrue);
    await settle(t, 500);
    await t.pageBack();
    await waitFor(t, find.text('Add File'));
    await settle(t, 600);
    expect(SecurityChannelService.isSecure, isTrue, reason: 'closing the viewer must keep the vault protected');

    // ── Backup screen: connect to a server and back the vault up ──
    if (syncServer.isNotEmpty) {
      await tapWhenReady(t, find.byTooltip('Settings'));
      await tapWhenReady(t, find.text('Backup'));
      await waitFor(t, find.text('Connect'));
      await settle(t, 500);
      await t.enterText(find.widgetWithText(TextField, 'Server address'), syncServer);
      await t.enterText(find.widgetWithText(TextField, 'Invite code (if the server needs one)'), syncInvite);
      await tapWhenReady(t, find.text('Connect'));
      // The code is shown and confirmed before the account is created.
      await waitFor(t, find.byKey(const Key('recovery-code')));
      final code = t.widget<Text>(find.byKey(const Key('recovery-code'))).data!;
      expect(RegExp(r'^([0-9a-f]{4} ){15}[0-9a-f]{4}$').hasMatch(code), isTrue);
      await tapWhenReady(t, find.byKey(const Key('recovery-written')));
      // The code is hidden now; two of its groups are asked for.
      await waitFor(t, find.byKey(const Key('recovery-group-0')));
      expect(find.byKey(const Key('recovery-code')), findsNothing);
      final groups = code.split(' ');
      for (var i = 0; i < 2; i++) {
        final label = t.widget<TextField>(find.byKey(Key('recovery-group-$i'))).decoration!.labelText!;
        final n = int.parse(RegExp(r'Group (\d+)').firstMatch(label)!.group(1)!);
        await t.enterText(find.byKey(Key('recovery-group-$i')), groups[n - 1]);
      }
      await t.pump();
      await tapWhenReady(t, find.byKey(const Key('recovery-confirm')));
      await waitFor(t, find.text('Not backed up yet'));
      final backupClock = Stopwatch()..start();
      await tapWhenReady(t, find.text('Back up now'));
      await waitFor(t, find.textContaining('Backup finished: 2 sent'), timeout: const Duration(seconds: 90));
      // ignore: avoid_print
      print('[timing] Back up now → finished: ${backupClock.elapsedMilliseconds} ms');
      // A second tap has nothing new to send.
      await tapWhenReady(t, find.text('Back up now'));
      await waitFor(t, find.textContaining('Backup finished: 0 sent, 2 already up to date'),
          timeout: const Duration(seconds: 60));
      // Automatic backup is on by default once connected.
      expect(t.widget<SwitchListTile>(find.byKey(const Key('auto-backup'))).value, isTrue);
      // Restoring finds nothing missing.
      await tapWhenReady(t, find.byKey(const Key('restore-missing')));
      await tapWhenReady(t, find.byKey(const Key('restore-latest')));
      await waitFor(t, find.textContaining('Nothing to restore'), timeout: const Duration(seconds: 60));
      // The account's phones: just this one.
      await tapWhenReady(t, find.byKey(const Key('devices-load')));
      await waitFor(t, find.text('This phone'));
      expect(find.text('Another phone'), findsNothing);
      await tapWhenReady(t, find.byIcon(Icons.arrow_back_ios_new_rounded));
      // Settings is still scrolled down to Backup, so look for its title.
      await waitFor(t, find.text('Security & Settings'));
      await waitFor(t, find.text('Back up now'), gone: true);
      await tapWhenReady(t, find.byIcon(Icons.arrow_back_ios_new_rounded));
      await waitFor(t, find.text('Add File'));
    }

    // ── A duress PIN, set from Settings: it opens the decoy and erases this
    //    vault for good ──
    await tapWhenReady(t, find.byTooltip('Settings'));
    await tapWhenReady(t, find.text('Set Up Duress PIN'));
    await tapWhenReady(t, find.byKey(const Key('duress-understood')));
    await waitFor(t, find.text('Save'));
    await t.enterText(find.widgetWithText(TextField, 'New PIN'), duressPin);
    await t.enterText(find.widgetWithText(TextField, 'Confirm'), duressPin);
    await tapWhenReady(t, find.text('Save'));
    await waitFor(t, find.text('Change Duress PIN'), timeout: const Duration(seconds: 30));
    await tapWhenReady(t, find.byIcon(Icons.arrow_back_ios_new_rounded));
    await waitFor(t, find.text('Add File'));
    await lock(t);
    await openLockScreen(t);
    await enterPin(t, duressPin);
    await waitFor(t, find.text('Add File'), timeout: const Duration(seconds: 30));
    expect(find.text(noteTitle), findsNothing);
    expect(find.text('evidence.png'), findsNothing);
    await lock(t);
    await openLockScreen(t);
    await enterPin(t, realPin);
    await waitFor(t, find.text('Not recognised.'), timeout: const Duration(seconds: 20));
    await settle(t, 1500);
    await enterPin(t, decoyPin);
    await waitFor(t, find.text('Add File'));
    expect(find.text(noteTitle), findsNothing);

    await lock(t);
    // Back on the cover app: protection off once the lock screen is gone.
    await settle(t, 1500);
    expect(SecurityChannelService.isSecure, isFalse, reason: 'cover app must behave like a normal app');

    // ignore: avoid_print
    print('[info] container size: ${(await container.length()) ~/ (1024 * 1024)} MiB on ${Platform.operatingSystem}');
  });
}
