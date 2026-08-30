import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/gesture.dart';
import '../models/note.dart';
import '../models/vault_item.dart';
import 'encryption_service.dart';

/// SQLite Database Service managing separate Primary and Decoy databases.
/// Encrypts sensitive fields (note contents, titles) with AES-256 before persisting.
class DatabaseService {
  final EncryptionService _encryptionService;
  Database? _primaryDb;
  Database? _decoyDb;

  DatabaseService({EncryptionService? encryptionService})
      : _encryptionService = encryptionService ?? EncryptionService();

  Future<Database> _getDb(VaultType vaultType) async {
    if (vaultType == VaultType.primary) {
      if (_primaryDb != null && _primaryDb!.isOpen) return _primaryDb!;
      _primaryDb = await _initDatabase('secretvault_primary.db');
      return _primaryDb!;
    } else {
      if (_decoyDb != null && _decoyDb!.isOpen) return _decoyDb!;
      _decoyDb = await _initDatabase('secretvault_decoy.db');
      return _decoyDb!;
    }
  }

  Future<Database> _initDatabase(String fileName) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, fileName);

    return await openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await _createTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createTables(db);
        }
      },
    );
  }

  Future<void> _createTables(Database db) async {
    // 1. Legacy Notes Table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS notes (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL
      )
    ''');

    // 2. Multi-File & Media Vault Items Table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS vault_items (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        category TEXT NOT NULL,
        encryptedFilePath TEXT,
        content TEXT,
        mimeType TEXT NOT NULL,
        fileSizeBytes INTEGER NOT NULL,
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL,
        isDecoy INTEGER NOT NULL,
        thumbnailBase64 TEXT,
        tags TEXT,
        isFavorite INTEGER NOT NULL
      )
    ''');
  }

  // ─── Vault Items Operations ─────────────────────────────

  Future<void> insertVaultItem(VaultItem item, [VaultType vaultType = VaultType.primary]) async {
    final db = await _getDb(vaultType);
    final encryptedTitle = await _encryptionService.encryptText(item.title, vaultType);
    final encryptedContent = item.content != null
        ? await _encryptionService.encryptText(item.content!, vaultType)
        : null;

    final itemMap = item.toMap();
    itemMap['title'] = encryptedTitle;
    itemMap['content'] = encryptedContent;

    await db.insert(
      'vault_items',
      itemMap,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<VaultItem>> getVaultItems({
    VaultCategory? category,
    VaultType vaultType = VaultType.primary,
  }) async {
    final db = await _getDb(vaultType);
    List<Map<String, dynamic>> maps;

    if (category != null) {
      maps = await db.query(
        'vault_items',
        where: 'category = ?',
        whereArgs: [category.name],
        orderBy: 'createdAt DESC',
      );
    } else {
      maps = await db.query(
        'vault_items',
        orderBy: 'createdAt DESC',
      );
    }

    final List<VaultItem> items = [];
    for (final map in maps) {
      final mutableMap = Map<String, dynamic>.from(map);
      mutableMap['title'] = await _encryptionService.decryptText(map['title'] as String, vaultType);
      if (map['content'] != null) {
        mutableMap['content'] = await _encryptionService.decryptText(map['content'] as String, vaultType);
      }
      items.add(VaultItem.fromMap(mutableMap));
    }
    return items;
  }

  Future<VaultItem?> getVaultItemById(String id, [VaultType vaultType = VaultType.primary]) async {
    final db = await _getDb(vaultType);
    final maps = await db.query('vault_items', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;

    final map = maps.first;
    final mutableMap = Map<String, dynamic>.from(map);
    mutableMap['title'] = await _encryptionService.decryptText(map['title'] as String, vaultType);
    if (map['content'] != null) {
      mutableMap['content'] = await _encryptionService.decryptText(map['content'] as String, vaultType);
    }
    return VaultItem.fromMap(mutableMap);
  }

  Future<void> updateVaultItem(VaultItem item, [VaultType vaultType = VaultType.primary]) async {
    final db = await _getDb(vaultType);
    final encryptedTitle = await _encryptionService.encryptText(item.title, vaultType);
    final encryptedContent = item.content != null
        ? await _encryptionService.encryptText(item.content!, vaultType)
        : null;

    final itemMap = item.toMap();
    itemMap['title'] = encryptedTitle;
    itemMap['content'] = encryptedContent;
    itemMap['updatedAt'] = DateTime.now().toIso8601String();

    await db.update(
      'vault_items',
      itemMap,
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  Future<void> deleteVaultItem(String id, [VaultType vaultType = VaultType.primary]) async {
    final db = await _getDb(vaultType);
    await db.delete('vault_items', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<VaultItem>> searchVaultItems(String query, [VaultType vaultType = VaultType.primary]) async {
    if (query.trim().isEmpty) return getVaultItems(vaultType: vaultType);

    final allItems = await getVaultItems(vaultType: vaultType);
    final lowerQ = query.toLowerCase();

    return allItems.where((item) {
      final titleMatch = item.title.toLowerCase().contains(lowerQ);
      final contentMatch = item.content?.toLowerCase().contains(lowerQ) ?? false;
      final tagMatch = item.tags.any((t) => t.toLowerCase().contains(lowerQ));
      return titleMatch || contentMatch || tagMatch;
    }).toList();
  }

  // ─── Legacy Notes Operations ─────────────────────────────

  Future<void> insertNote(Note note, [VaultType vaultType = VaultType.primary]) async {
    final db = await _getDb(vaultType);
    final encryptedTitle = await _encryptionService.encryptText(note.title, vaultType);
    final encryptedContent = await _encryptionService.encryptText(note.content, vaultType);

    await db.insert(
      'notes',
      {
        'id': note.id,
        'title': encryptedTitle,
        'content': encryptedContent,
        'createdAt': note.createdAt.toIso8601String(),
        'updatedAt': note.updatedAt.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    // Also mirror to vault_items for unified UI
    await insertVaultItem(
      VaultItem(
        id: note.id,
        title: note.title,
        category: VaultCategory.note,
        content: note.content,
        mimeType: 'text/plain',
        fileSizeBytes: note.content.length,
        createdAt: note.createdAt,
        updatedAt: note.updatedAt,
      ),
      vaultType,
    );
  }

  Future<Note?> getNote(String id, [VaultType vaultType = VaultType.primary]) async {
    final db = await _getDb(vaultType);
    final maps = await db.query('notes', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;

    final decryptedTitle = await _encryptionService.decryptText(maps.first['title'] as String, vaultType);
    final decryptedContent = await _encryptionService.decryptText(maps.first['content'] as String, vaultType);

    return Note(
      id: maps.first['id'] as String,
      title: decryptedTitle,
      content: decryptedContent,
      createdAt: DateTime.parse(maps.first['createdAt'] as String),
      updatedAt: DateTime.parse(maps.first['updatedAt'] as String),
    );
  }

  Future<List<Note>> getNotes([VaultType vaultType = VaultType.primary]) async {
    final db = await _getDb(vaultType);
    final maps = await db.query('notes', orderBy: 'createdAt DESC');

    final List<Note> notes = [];
    for (final map in maps) {
      final decryptedTitle = await _encryptionService.decryptText(map['title'] as String, vaultType);
      final decryptedContent = await _encryptionService.decryptText(map['content'] as String, vaultType);

      notes.add(Note(
        id: map['id'] as String,
        title: decryptedTitle,
        content: decryptedContent,
        createdAt: DateTime.parse(map['createdAt'] as String),
        updatedAt: DateTime.parse(map['updatedAt'] as String),
      ));
    }
    return notes;
  }

  Future<List<Note>> getAllNotes([VaultType vaultType = VaultType.primary]) async {
    return getNotes(vaultType);
  }

  Future<List<Note>> getNotesByCreationDate({
    bool ascending = true,
    VaultType vaultType = VaultType.primary,
  }) async {
    final db = await _getDb(vaultType);
    final order = ascending ? 'createdAt ASC' : 'createdAt DESC';
    final maps = await db.query('notes', orderBy: order);

    final List<Note> notes = [];
    for (final map in maps) {
      final decryptedTitle = await _encryptionService.decryptText(map['title'] as String, vaultType);
      final decryptedContent = await _encryptionService.decryptText(map['content'] as String, vaultType);

      notes.add(Note(
        id: map['id'] as String,
        title: decryptedTitle,
        content: decryptedContent,
        createdAt: DateTime.parse(map['createdAt'] as String),
        updatedAt: DateTime.parse(map['updatedAt'] as String),
      ));
    }
    return notes;
  }

  Future<void> togglePin(String id, bool isPinned, [VaultType vaultType = VaultType.primary]) async {
    // Pin state can be saved or toggled
  }

  Future<void> updateNote(Note note, [VaultType vaultType = VaultType.primary]) async {
    final db = await _getDb(vaultType);
    final encryptedTitle = await _encryptionService.encryptText(note.title, vaultType);
    final encryptedContent = await _encryptionService.encryptText(note.content, vaultType);

    await db.update(
      'notes',
      {
        'title': encryptedTitle,
        'content': encryptedContent,
        'updatedAt': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [note.id],
    );

    await updateVaultItem(
      VaultItem(
        id: note.id,
        title: note.title,
        category: VaultCategory.note,
        content: note.content,
        mimeType: 'text/plain',
        fileSizeBytes: note.content.length,
        createdAt: note.createdAt,
        updatedAt: DateTime.now(),
      ),
      vaultType,
    );
  }

  Future<void> deleteNote(String id, [VaultType vaultType = VaultType.primary]) async {
    final db = await _getDb(vaultType);
    await db.delete('notes', where: 'id = ?', whereArgs: [id]);
    await deleteVaultItem(id, vaultType);
  }

  Future<List<Note>> searchNotes(String query, [VaultType vaultType = VaultType.primary]) async {
    if (query.trim().isEmpty) return getNotes(vaultType);
    final allNotes = await getNotes(vaultType);
    final lowerQ = query.toLowerCase();

    return allNotes.where((note) {
      return note.title.toLowerCase().contains(lowerQ) ||
          note.content.toLowerCase().contains(lowerQ);
    }).toList();
  }

  Future<void> close() async {
    if (_primaryDb != null && _primaryDb!.isOpen) {
      await _primaryDb!.close();
      _primaryDb = null;
    }
    if (_decoyDb != null && _decoyDb!.isOpen) {
      await _decoyDb!.close();
      _decoyDb = null;
    }
  }
}
