import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/note.dart';
import 'encryption_service.dart';

/// SQLite database service with AES-256 encryption for notes CRUD operations.
class DatabaseService {
  static Database? _database;
  final EncryptionService _encryption;

  DatabaseService({EncryptionService? encryption})
      : _encryption = encryption ?? EncryptionService();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'secret_vault.db');

    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE notes (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            content TEXT NOT NULL,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            isPinned INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
    );
  }

  /// Helper to convert and decrypt a raw database map to a Note model.
  Future<Note> _decryptNoteMap(Map<String, dynamic> map) async {
    final decryptedTitle = await _encryption.decryptText(map['title'] as String);
    final decryptedContent = await _encryption.decryptText(map['content'] as String);
    return Note(
      id: map['id'] as String,
      title: decryptedTitle,
      content: decryptedContent,
      createdAt: DateTime.parse(map['createdAt'] as String),
      updatedAt: DateTime.parse(map['updatedAt'] as String),
      isPinned: (map['isPinned'] as int) == 1,
    );
  }

  /// Insert a new note with AES-256 encrypted title and content.
  Future<void> insertNote(Note note) async {
    final db = await database;
    final encryptedTitle = await _encryption.encryptText(note.title);
    final encryptedContent = await _encryption.encryptText(note.content);

    final map = note.toMap();
    map['title'] = encryptedTitle;
    map['content'] = encryptedContent;

    await db.insert(
      'notes',
      map,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Update an existing note with AES-256 encrypted title and content.
  Future<void> updateNote(Note note) async {
    final db = await database;
    final encryptedTitle = await _encryption.encryptText(note.title);
    final encryptedContent = await _encryption.encryptText(note.content);

    final map = note.toMap();
    map['title'] = encryptedTitle;
    map['content'] = encryptedContent;

    await db.update(
      'notes',
      map,
      where: 'id = ?',
      whereArgs: [note.id],
    );
  }

  /// Delete a note by ID.
  Future<void> deleteNote(String id) async {
    final db = await database;
    await db.delete(
      'notes',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Get all notes, decrypted and sorted by pinned first, then by updatedAt descending.
  Future<List<Note>> getAllNotes() async {
    final db = await database;
    final maps = await db.query(
      'notes',
      orderBy: 'isPinned DESC, updatedAt DESC',
    );
    return Future.wait(maps.map((map) => _decryptNoteMap(map)));
  }

  /// Get all notes sorted by createdAt ascending or descending.
  Future<List<Note>> getNotesByCreationDate({bool ascending = true}) async {
    final db = await database;
    final order = ascending ? 'ASC' : 'DESC';
    final maps = await db.query(
      'notes',
      orderBy: 'isPinned DESC, createdAt $order',
    );
    return Future.wait(maps.map((map) => _decryptNoteMap(map)));
  }

  /// Search notes by query over decrypted titles and contents.
  Future<List<Note>> searchNotes(String query) async {
    final allNotes = await getAllNotes();
    if (query.isEmpty) return allNotes;
    final lowerQuery = query.toLowerCase();
    return allNotes
        .where((n) =>
            n.title.toLowerCase().contains(lowerQuery) ||
            n.content.toLowerCase().contains(lowerQuery))
        .toList();
  }

  /// Toggle the pinned state of a note.
  Future<void> togglePin(String id, bool isPinned) async {
    final db = await database;
    await db.update(
      'notes',
      {'isPinned': isPinned ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Get a single decrypted note by ID.
  Future<Note?> getNote(String id) async {
    final db = await database;
    final maps = await db.query(
      'notes',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return await _decryptNoteMap(maps.first);
  }

  /// Get total note count.
  Future<int> getNoteCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM notes');
    return Sqflite.firstIntValue(result) ?? 0;
  }
}
