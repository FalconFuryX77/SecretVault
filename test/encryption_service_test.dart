import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gesture_unlock/services/encryption_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EncryptionService Tests', () {
    late EncryptionService encryptionService;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      encryptionService = EncryptionService(storage: const FlutterSecureStorage());
    });

    test('encryptText produces formatted IV and ciphertext', () async {
      const plaintext = 'Secret highly confidential note content';
      final encrypted = await encryptionService.encryptText(plaintext);

      expect(encrypted, isNotEmpty);
      expect(encrypted.contains(':'), isTrue);
      final parts = encrypted.split(':');
      expect(parts.length, equals(2));
      expect(parts[0], isNotEmpty);
      expect(parts[1], isNotEmpty);
    });

    test('decryptText successfully recovers original plaintext', () async {
      const originalText = 'Top Secret: Project Apollo 2026';
      final encrypted = await encryptionService.encryptText(originalText);
      final decrypted = await encryptionService.decryptText(encrypted);

      expect(decrypted, equals(originalText));
    });

    test('Identical plaintexts produce different ciphertexts due to random IV', () async {
      const plaintext = 'Same text twice';
      final encrypted1 = await encryptionService.encryptText(plaintext);
      final encrypted2 = await encryptionService.encryptText(plaintext);

      expect(encrypted1, isNot(equals(encrypted2)));

      final decrypted1 = await encryptionService.decryptText(encrypted1);
      final decrypted2 = await encryptionService.decryptText(encrypted2);

      expect(decrypted1, equals(plaintext));
      expect(decrypted2, equals(plaintext));
    });

    test('Empty plaintext returns empty string', () async {
      final encrypted = await encryptionService.encryptText('');
      expect(encrypted, isEmpty);

      final decrypted = await encryptionService.decryptText('');
      expect(decrypted, isEmpty);
    });

    test('decryptText falls back gracefully on plaintext or invalid format', () async {
      const unencryptedText = 'Legacy unencrypted plaintext note';
      final decrypted = await encryptionService.decryptText(unencryptedText);
      expect(decrypted, equals(unencryptedText));
    });

    test('clearMemoryKey resets cached key', () async {
      await encryptionService.encryptText('Test');
      encryptionService.clearMemoryKey();
      // Should transparently re-fetch key from secure storage without error
      final decrypted = await encryptionService.decryptText(await encryptionService.encryptText('Test 2'));
      expect(decrypted, equals('Test 2'));
    });
  });
}
