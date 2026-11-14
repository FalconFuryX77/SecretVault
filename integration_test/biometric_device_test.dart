// Exercises the native biometric path end to end: Android Keystore keys that
// are only usable after BiometricPrompt, wrapping and unwrapping the vault key.
//
// Needs a device with an enrolled fingerprint. On an emulator, a host-side
// loop must keep "touching" the sensor while this runs:
//   while true; do adb emu finger touch 1; sleep 1; adb emu finger remove 1; sleep 1; done
//
// Run:  flutter test integration_test/biometric_device_test.dart -d <device>
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/models/gesture.dart';
import 'package:gesture_unlock/services/vault_service.dart';
import 'package:gesture_unlock/vault/crypto_primitives.dart';
import 'package:gesture_unlock/vault/platform_keys.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const gesture = [Gesture.left, Gesture.up, Gesture.right, Gesture.down, Gesture.shake];
  late Directory dir;

  setUp(() async {
    final base = await getTemporaryDirectory();
    dir = await Directory('${base.path}/bio_it_${DateTime.now().microsecondsSinceEpoch}').create(recursive: true);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  testWidgets('keystore wrap/unwrap behind BiometricPrompt round-trips a key', (tester) async {
    final bio = AndroidBiometricKeystore();
    expect(await bio.isAvailable(), isTrue, reason: 'enrol a fingerprint first');
    await bio.ensureSlots(4);
    final secret = CryptoPrimitives.randomBytes(32);
    final blob = await bio.wrap(2, secret, reason: 'Confirm it\'s you');
    expect(blob, isNotNull, reason: 'prompt was cancelled or timed out');
    expect(blob!.length, 12 + 32 + 16);
    final back = await bio.unwrap(2, blob, reason: 'Confirm it\'s you');
    expect(back, secret);
    // A blob from one slot can't be opened by another slot's key.
    final wrongSlot = await bio.unwrap(1, blob, reason: 'Confirm it\'s you');
    expect(wrongSlot, isNull);
  });

  testWidgets('vault: enrol gesture, then gesture + fingerprint unlocks the right vault', (tester) async {
    final svc = VaultService(storageDir: () async => dir);
    final s = await svc.create(pin: 'bio-test-pin-1', initialChunks: 16);
    expect(await s.enrollGesture(gesture, reason: 'Confirm it\'s you'), isTrue);
    await s.createDecoy(pin: 'bio-decoy-pin');
    const decoyGesture = [Gesture.down, Gesture.down, Gesture.shake, Gesture.left];
    expect(await s.enrollDecoyGesture(decoyGesture, reason: 'Confirm it\'s you'), isTrue);
    await svc.lock();

    final fresh = VaultService(storageDir: () async => dir);
    expect(await fresh.unlockWithGesture([Gesture.right, Gesture.right, Gesture.right, Gesture.right], reason: 'x'),
        isNull, reason: 'unknown gesture must not even prompt');
    final real = await fresh.unlockWithGesture(gesture, reason: 'Confirm it\'s you');
    expect(real?.type, VaultType.primary);
    await fresh.lock();
    final decoy = await fresh.unlockWithGesture(decoyGesture, reason: 'Confirm it\'s you');
    expect(decoy?.type, VaultType.decoy);
    await fresh.lock();
  });

  testWidgets('wrapped blob is bound to this keystore key, not to the bytes alone', (tester) async {
    final bio = AndroidBiometricKeystore();
    final blob = await bio.wrap(3, Uint8List.fromList(List.filled(32, 7)), reason: 'Confirm it\'s you');
    expect(blob, isNotNull);
    final tampered = Uint8List.fromList(blob!)..[20] ^= 1;
    expect(await bio.unwrap(3, tampered, reason: 'Confirm it\'s you'), isNull);
  });
}
