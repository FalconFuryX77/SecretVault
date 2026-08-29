import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gesture_unlock/models/note.dart';
import 'package:gesture_unlock/services/encryption_service.dart';
import 'package:gesture_unlock/services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('DatabaseService with AES-256 Encryption Tests', () {
    late EncryptionService encryptionService;
    late DatabaseService databaseService;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      encryptionService = EncryptionService();
      databaseService = DatabaseService(encryption: encryptionService);
    });

    test('Notes are saved and retrieved decrypted', () async {
      final now = DateTime.now();
      final note = Note(
        id: 'test-note-1',
        title: 'Confidential Client List',
        content: 'Account numbers: 12345678, 87654321',
        createdAt: now,
        updatedAt: now,
        isPinned: true,
      );

      await databaseService.insertNote(note);

      final retrieved = await databaseService.getNote('test-note-1');
      expect(retrieved, isNotNull);
      expect(retrieved!.title, equals('Confidential Client List'));
      expect(retrieved.content, equals('Account numbers: 12345678, 87654321'));
      expect(retrieved.isPinned, isTrue);

      // Verify raw database row has encrypted content
      final db = await databaseService.database;
      final rawRows = await db.query('notes', where: 'id = ?', whereArgs: ['test-note-1']);
      expect(rawRows.isNotEmpty, isTrue);
      final rawTitle = rawRows.first['title'] as String;
      final rawContent = rawRows.first['content'] as String;

      expect(rawTitle, isNot(equals('Confidential Client List')));
      expect(rawContent, isNot(equals('Account numbers: 12345678, 87654321')));
      expect(rawTitle.contains(':'), isTrue); // 'iv:ciphertext' format
      expect(rawContent.contains(':'), isTrue); // 'iv:ciphertext' format
    });

    test('searchNotes searches within decrypted content', () async {
      final now = DateTime.now();
      final note1 = Note(
        id: 'note-1',
        title: 'Banana Pancake Recipe',
        content: 'Flour, eggs, milk, bananas.',
        createdAt: now,
        updatedAt: now,
      );
      final note2 = Note(
        id: 'note-2',
        title: 'Server Passwords',
        content: 'Production db root password is ultra-secret.',
        createdAt: now,
        updatedAt: now,
      );

      await databaseService.insertNote(note1);
      await databaseService.insertNote(note2);

      final searchResults = await databaseService.searchNotes('ultra-secret');
      expect(searchResults.length, equals(1));
      expect(searchResults.first.title, equals('Server Passwords'));

      final searchResults2 = await databaseService.searchNotes('Pancake');
      expect(searchResults2.length, equals(1));
      expect(searchResults2.first.id, equals('note-1'));
    });
  });
}
