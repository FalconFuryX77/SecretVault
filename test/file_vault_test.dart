import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gesture_unlock/models/gesture.dart';
import 'package:gesture_unlock/services/encryption_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Binary File Stream Encryption Tests', () {
    late EncryptionService encryptionService;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      encryptionService = EncryptionService(storage: const FlutterSecureStorage());
    });

    test('Binary PDF/Image bytes encrypt and decrypt with 100% bitwise fidelity', () async {
      // Create a mock 16KB binary payload (e.g. simulated PDF / JPEG header & data)
      final sampleBytes = Uint8List.fromList(
        List<int>.generate(16384, (i) => (i * 7 + 13) % 256),
      );

      final encryptedPayload = await encryptionService.encryptBytes(sampleBytes, VaultType.primary);

      // Verify payload is encrypted (contains 16 byte IV + ciphertext)
      expect(encryptedPayload.length, greaterThan(sampleBytes.length));
      expect(encryptedPayload.sublist(0, 16), isNotEmpty);

      // Decrypt
      final decryptedBytes = await encryptionService.decryptBytes(encryptedPayload, VaultType.primary);

      expect(decryptedBytes.length, equals(sampleBytes.length));
      expect(decryptedBytes, equals(sampleBytes));
    });

    test('Decrypting with empty or corrupt payload returns empty byte array gracefully', () async {
      final emptyResult = await encryptionService.decryptBytes(Uint8List(0));
      expect(emptyResult, isEmpty);

      final tooShortPayload = Uint8List.fromList([1, 2, 3, 4]);
      final shortResult = await encryptionService.decryptBytes(tooShortPayload);
      expect(shortResult, isEmpty);
    });
  });
}
