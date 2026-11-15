import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/models/vault_state.dart';
import 'package:gesture_unlock/models/vault_item.dart';
import 'package:gesture_unlock/providers/unlock_provider.dart';
import 'package:gesture_unlock/providers/vault_provider.dart';
import 'package:gesture_unlock/services/auth_service.dart';
import 'package:gesture_unlock/services/shake_detector.dart';
import 'package:gesture_unlock/services/vault_service.dart';
import 'package:gesture_unlock/vault/crypto_primitives.dart';
import 'package:gesture_unlock/vault/platform_keys.dart';
import 'package:gesture_unlock/vault/vault_container.dart';
import 'package:sensors_plus/sensors_plus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pin = 'correct horse';

  late Directory tmp;
  late VaultService vault;
  late AuthService auth;

  UnlockProvider newUnlock({Stream<AccelerometerEvent>? accel}) => UnlockProvider(
        vaultService: vault,
        authService: auth,
        shakeDetector: ShakeDetector(accelStream: accel ?? const Stream.empty()),
      );

  Future<void> settle() => Future.delayed(const Duration(milliseconds: 50));

  /// Waits until [cond] holds (polling), instead of sleeping a fixed time
  /// and hoping the work finished: key derivation can be slow on a busy
  /// machine, which made fixed sleeps flaky.
  Future<void> eventually(bool Function() cond, String what, {Duration timeout = const Duration(seconds: 15)}) async {
    final end = DateTime.now().add(timeout);
    while (!cond()) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for: $what');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('unlock_flow');
    auth = AuthService();
    vault = VaultService(
      crypto: VaultCrypto(
        binding: FixedDeviceBinding(),
        pinParams: KdfParams.testing,
        growChunks: 8,
      ),
      storageDir: () async => tmp,
    );
    await vault.create(pin: pin, initialChunks: 16);
    await vault.lock();
  });

  tearDown(() async {
    await vault.lock();
    await tmp.delete(recursive: true);
  });

  test('right PIN unlocks the real vault; keys exist only while unlocked', () async {
    final unlock = newUnlock();
    await settle();
    expect(vault.isUnlocked, isFalse);
    expect(await unlock.verifyPin(pin), isTrue);
    expect(unlock.state, UnlockState.unlocked);
    expect(unlock.activeVaultType, VaultType.primary);
    expect(vault.isUnlocked, isTrue);

    unlock.lockVault();
    await settle();
    expect(vault.isUnlocked, isFalse);
    unlock.dispose();
  });

  test('a hard shake locks an open vault; while locked it does nothing', () async {
    final accel = StreamController<AccelerometerEvent>.broadcast();
    final unlock = newUnlock(accel: accel.stream);
    await settle();
    var notifications = 0;
    unlock.addListener(() => notifications++);

    // Locked: the sensor isn't even listened to, so nothing can react.
    expect(accel.hasListener, isFalse);
    accel.add(AccelerometerEvent(32.0, 18.0, 9.8));
    await settle();
    expect(unlock.state, UnlockState.locked);
    expect(notifications, 0);

    expect(await unlock.verifyPin(pin), isTrue);
    expect(accel.hasListener, isTrue);
    accel.add(AccelerometerEvent(32.0, 18.0, 9.8));
    await eventually(() => !vault.isUnlocked, 'the shake to lock the vault');
    expect(accel.hasListener, isFalse, reason: 'sensor released again once locked');
    unlock.dispose();
    await accel.close();
  });

  test('sending the app to the background does not cancel a lockout', () async {
    final unlock = newUnlock();
    await settle();
    for (var i = 0; i < UnlockProvider.maxFailedAttempts; i++) {
      await unlock.verifyPin('wrong$i');
      if (i < UnlockProvider.maxFailedAttempts - 1) {
        await eventually(() => unlock.state == UnlockState.locked, 'the failure message to clear');
      }
    }
    expect(unlock.state, UnlockState.lockout);
    unlock.onAppPaused();
    unlock.onAppResumed();
    expect(unlock.state, UnlockState.lockout);
    expect(await unlock.verifyPin(pin), isFalse);
    unlock.dispose();
  });

  test('an unlock that finishes after the app left the foreground is not left open', () async {
    final unlock = newUnlock();
    await settle();
    final pending = unlock.verifyPin(pin);
    unlock.onAppPaused();
    expect(await pending, isFalse);
    expect(vault.isUnlocked, isFalse);
    unlock.onAppResumed();
    expect(await unlock.verifyPin(pin), isTrue);
    unlock.dispose();
  });

  test('five wrong PINs start a lockout, and repeat lockouts get longer', () async {
    final unlock = newUnlock();
    await settle();
    for (var i = 0; i < UnlockProvider.maxFailedAttempts; i++) {
      expect(await unlock.verifyPin('wrong$i'), isFalse);
      if (i < UnlockProvider.maxFailedAttempts - 1) {
        await eventually(() => unlock.state == UnlockState.locked, 'the failure message to clear');
      }
    }
    expect(unlock.state, UnlockState.lockout);
    expect(unlock.lockoutRemaining, inInclusiveRange(AuthService.baseLockoutSeconds - 3, AuthService.baseLockoutSeconds));
    // Even the right PIN is refused during lockout.
    expect(await unlock.verifyPin(pin), isFalse);
    unlock.dispose();

    expect(await auth.beginLockout(), AuthService.baseLockoutSeconds * 2);
    expect(await auth.beginLockout(), AuthService.baseLockoutSeconds * 4);
    await auth.resetAfterSuccess();
    expect(await auth.beginLockout(), AuthService.baseLockoutSeconds);
  });

  test('panic lock wipes the session', () async {
    final unlock = newUnlock();
    await settle();
    await unlock.verifyPin(pin);
    final session = vault.session!;
    unlock.triggerPanicLock();
    await settle();
    expect(unlock.state, UnlockState.panicLocked);
    expect(vault.isUnlocked, isFalse);
    expect(session.isOpen, isFalse);
    expect(() => session.entries, throwsStateError);
    unlock.dispose();
  });

  group('VaultProvider over the container', () {
    test('notes, rename, favourite, search and delete', () async {
      final unlock = newUnlock();
      await settle();
      await unlock.verifyPin(pin);
      final vp = VaultProvider(vaultService: vault);
      await vp.loadVault(VaultType.primary);

      await vp.saveNote(title: 'Café ☕ notes', content: "line1\nline2 '; DROP TABLE x; -- 🚀");
      await vp.saveNote(title: 'Seeds', content: 'abandon ability able', category: VaultCategory.keySecret);
      expect(vp.allItems.length, 2);
      final note = vp.notes.single;
      await vp.renameItem(note, 'Renamed');
      await vp.toggleFavorite(vp.notes.single);
      expect(vp.notes.single.title, 'Renamed');
      expect(vp.notes.single.isFavorite, isTrue);

      vp.setSearchQuery('DROP TABLE');
      expect(vp.filteredItems.single.title, 'Renamed');
      vp.clearFilters();

      // Survives lock / unlock.
      unlock.lockVault();
      await settle();
      expect(vp.allItems, isEmpty);
      await unlock.verifyPin(pin);
      await vp.loadVault(VaultType.primary);
      expect(vp.notes.single.content, contains('🚀'));

      await vp.deleteItem(vp.keySecrets.single);
      expect(vp.allItems.length, 1);
      unlock.dispose();
    });

    test('import streams a file in and exports it back out', () async {
      final unlock = newUnlock();
      await settle();
      await unlock.verifyPin(pin);
      final vp = VaultProvider(vaultService: vault);
      await vp.loadVault(VaultType.primary);

      final src = File('${tmp.path}/doc.pdf');
      await src.writeAsBytes(List.generate(200000, (i) => i % 251));
      final progress = <double>[];
      vp.addListener(() {
        if (vp.importProgress != null) progress.add(vp.importProgress!);
      });
      final item = await vp.importFile(
        sourceFile: src,
        title: 'doc.pdf',
        category: VaultCategory.document,
        mimeType: 'application/pdf',
      );
      expect(progress.last, 1.0);
      expect(await vp.readDecryptedBytes(item), await src.readAsBytes());

      final outDir = await Directory('${tmp.path}/out').create();
      final out = await vp.exportFile(item, outDir);
      expect(await out!.readAsBytes(), await src.readAsBytes());
      unlock.dispose();
    });

    test('decoy PIN shows only decoy content, through the same UI type path', () async {
      final unlock = newUnlock();
      await settle();
      await unlock.verifyPin(pin);
      final vp = VaultProvider(vaultService: vault);
      await vp.saveNote(title: 'real secret', content: 'evidence');
      await vault.session!.createDecoy(pin: 'groceries1');
      unlock.lockVault();
      await settle();

      await Future.delayed(const Duration(milliseconds: 100));
      expect(await unlock.verifyPin('groceries1'), isTrue);
      expect(unlock.activeVaultType, VaultType.decoy);
      await vp.loadVault(unlock.activeVaultType);
      expect(vp.allItems, isEmpty);
      expect(vault.session!.canManageDecoy, isFalse);
      unlock.dispose();
    });
  });

  test('a fresh install with no container reports not set up', () async {
    final empty = await Directory.systemTemp.createTemp('empty');
    final v = VaultService(
      crypto: VaultCrypto(binding: FixedDeviceBinding()),
      storageDir: () async => empty,
    );
    expect(await v.isSetUp(), isFalse);
    await empty.delete(recursive: true);
  });

  test('auto-lock waits while an import is running', () async {
    await auth.setInactivityTimeout(1);
    final unlock = newUnlock();
    await settle();
    await unlock.verifyPin(pin);
    final release = vault.whileBusy(() => Future.delayed(const Duration(milliseconds: 1600)));
    await Future.delayed(const Duration(milliseconds: 1300));
    expect(vault.isUnlocked, isTrue, reason: 'busy: must not lock');
    await release;
    await Future.delayed(const Duration(milliseconds: 1300));
    expect(vault.isUnlocked, isFalse, reason: 'idle again: locks');
    unlock.dispose();
  });

  test('wrong-device binding means even the right PIN fails', () async {
    final other = VaultService(
      crypto: VaultCrypto(
        binding: FixedDeviceBinding(CryptoPrimitives.randomBytes(32)),
        pinParams: KdfParams.testing,
      ),
      storageDir: () async => tmp,
    );
    expect(await other.unlockWithPin(pin), isNull);
  });
}
