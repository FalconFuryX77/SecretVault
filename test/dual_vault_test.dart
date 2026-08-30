import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:gesture_unlock/models/gesture.dart';
import 'package:gesture_unlock/models/vault_item.dart';
import 'package:gesture_unlock/services/encryption_service.dart';
import 'package:gesture_unlock/services/database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('Dual-Vault Cryptographic Isolation & Security Tests', () {
    late EncryptionService encryptionService;
    late DatabaseService dbService;

    setUp(() async {
      FlutterSecureStorage.setMockInitialValues({});
      encryptionService = EncryptionService(storage: const FlutterSecureStorage());
      dbService = DatabaseService(encryptionService: encryptionService);

      final dbPath = await getDatabasesPath();
      await deleteDatabase(p.join(dbPath, 'secretvault_primary.db'));
      await deleteDatabase(p.join(dbPath, 'secretvault_decoy.db'));
    });

    tearDown(() async {
      await dbService.close();
    });

    test('Primary and Decoy keys produce different ciphertexts for identical plaintext', () async {
      const sensitiveData = 'Bitcoin Private Seed: abandon abandon...';

      final primaryEncrypted = await encryptionService.encryptText(sensitiveData, VaultType.primary);
      final decoyEncrypted = await encryptionService.encryptText(sensitiveData, VaultType.decoy);

      expect(primaryEncrypted, isNot(equals(decoyEncrypted)));

      // Decrypting with correct vault key succeeds
      final primaryDecrypted = await encryptionService.decryptText(primaryEncrypted, VaultType.primary);
      expect(primaryDecrypted, equals(sensitiveData));
    });

    test('Primary Vault items are strictly isolated from Decoy Vault database', () async {
      final primaryDoc = VaultItem(
        id: 'primary-doc-1',
        title: 'Secret Tax Document.pdf',
        category: VaultCategory.document,
        mimeType: 'application/pdf',
        fileSizeBytes: 2048,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final decoyNote = VaultItem(
        id: 'decoy-note-1',
        title: 'Grocery List',
        content: 'Milk, Bread, Butter',
        category: VaultCategory.note,
        mimeType: 'text/plain',
        fileSizeBytes: 18,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        isDecoy: true,
      );

      // Insert into respective vaults
      await dbService.insertVaultItem(primaryDoc, VaultType.primary);
      await dbService.insertVaultItem(decoyNote, VaultType.decoy);

      // Verify Primary Vault only contains primaryDoc
      final primaryItems = await dbService.getVaultItems(vaultType: VaultType.primary);
      expect(primaryItems.length, equals(1));
      expect(primaryItems.first.title, equals('Secret Tax Document.pdf'));

      // Verify Decoy Vault only contains decoyNote
      final decoyItems = await dbService.getVaultItems(vaultType: VaultType.decoy);
      expect(decoyItems.length, equals(1));
      expect(decoyItems.first.title, equals('Grocery List'));
    });

    test('RAM Key Zeroization clears memory buffer without losing persisted data', () async {
      const plainText = 'Confidential memory test';
      final encrypted = await encryptionService.encryptText(plainText, VaultType.primary);

      // Trigger RAM wipe
      encryptionService.clearMemoryKey();

      // Transparent re-authentication reads from secure storage
      final recovered = await encryptionService.decryptText(encrypted, VaultType.primary);
      expect(recovered, equals(plainText));
    });
  });
}
