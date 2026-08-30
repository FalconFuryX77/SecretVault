import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../models/gesture.dart';
import '../models/vault_item.dart';
import '../models/note.dart';
import '../services/database_service.dart';
import '../services/file_vault_service.dart';

/// Reactive provider managing files, documents, media, and notes for the active vault session.
class VaultProvider extends ChangeNotifier {
  final DatabaseService _dbService;
  final FileVaultService _fileVaultService;
  final Uuid _uuid;

  VaultType _activeVaultType = VaultType.primary;
  VaultType get activeVaultType => _activeVaultType;

  List<VaultItem> _allItems = [];
  List<VaultItem> get allItems => _allItems;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String _searchQuery = '';
  String get searchQuery => _searchQuery;

  VaultCategory? _selectedCategory;
  VaultCategory? get selectedCategory => _selectedCategory;

  VaultProvider({
    DatabaseService? dbService,
    FileVaultService? fileVaultService,
    Uuid? uuid,
  })  : _dbService = dbService ?? DatabaseService(),
        _fileVaultService = fileVaultService ?? FileVaultService(),
        _uuid = uuid ?? const Uuid();

  // ─── Filtered Getters ───────────────────────────────────

  List<VaultItem> get filteredItems {
    var list = _allItems;
    if (_selectedCategory != null) {
      list = list.where((item) => item.category == _selectedCategory).toList();
    }
    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      list = list.where((item) {
        final matchTitle = item.title.toLowerCase().contains(q);
        final matchContent = item.content?.toLowerCase().contains(q) ?? false;
        final matchTags = item.tags.any((t) => t.toLowerCase().contains(q));
        return matchTitle || matchContent || matchTags;
      }).toList();
    }
    return list;
  }

  List<VaultItem> get documents =>
      _allItems.where((i) => i.category == VaultCategory.document).toList();

  List<VaultItem> get media =>
      _allItems.where((i) => i.category == VaultCategory.image || i.category == VaultCategory.video).toList();

  List<VaultItem> get notes =>
      _allItems.where((i) => i.category == VaultCategory.note).toList();

  List<VaultItem> get keySecrets =>
      _allItems.where((i) => i.category == VaultCategory.keySecret).toList();

  // ─── Vault Session Loading ──────────────────────────────

  Future<void> loadVault(VaultType vaultType) async {
    _activeVaultType = vaultType;
    _isLoading = true;
    notifyListeners();

    _allItems = await _dbService.getVaultItems(vaultType: vaultType);

    // If decoy vault is empty, seed realistic plausible sample items
    if (vaultType == VaultType.decoy && _allItems.isEmpty) {
      await _seedDecoyData();
      _allItems = await _dbService.getVaultItems(vaultType: vaultType);
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> _seedDecoyData() async {
    final now = DateTime.now();
    final sampleNotes = [
      VaultItem(
        id: _uuid.v4(),
        title: 'Weekly Grocery List',
        category: VaultCategory.note,
        content: '• Almond milk\n• Whole grain oats\n• Greek yogurt\n• Avocados\n• Olive oil',
        mimeType: 'text/plain',
        fileSizeBytes: 65,
        createdAt: now.subtract(const Duration(days: 2)),
        updatedAt: now.subtract(const Duration(days: 2)),
        isDecoy: true,
      ),
      VaultItem(
        id: _uuid.v4(),
        title: 'Apartment Maintenance Contact',
        category: VaultCategory.note,
        content: 'Plumber: (555) 019-2834\nElectrician: (555) 012-9841\nLeasing Office: 9am - 5pm Mon-Fri',
        mimeType: 'text/plain',
        fileSizeBytes: 85,
        createdAt: now.subtract(const Duration(days: 5)),
        updatedAt: now.subtract(const Duration(days: 5)),
        isDecoy: true,
      ),
      VaultItem(
        id: _uuid.v4(),
        title: 'Book Recommendations',
        category: VaultCategory.note,
        content: '1. Designing Data-Intensive Applications\n2. Clean Architecture\n3. The Pragmatic Programmer',
        mimeType: 'text/plain',
        fileSizeBytes: 95,
        createdAt: now.subtract(const Duration(days: 8)),
        updatedAt: now.subtract(const Duration(days: 8)),
        isDecoy: true,
      ),
    ];

    for (final item in sampleNotes) {
      await _dbService.insertVaultItem(item, VaultType.decoy);
    }
  }

  // ─── File Ingestion & Management ─────────────────────────

  Future<VaultItem> importFile({
    required File sourceFile,
    required String title,
    required VaultCategory category,
    required String mimeType,
    bool deleteOriginal = false,
    List<String> tags = const [],
  }) async {
    final item = await _fileVaultService.importFile(
      sourceFile: sourceFile,
      title: title,
      category: category,
      mimeType: mimeType,
      vaultType: _activeVaultType,
      deleteOriginal: deleteOriginal,
      tags: tags,
    );

    await _dbService.insertVaultItem(item, _activeVaultType);
    _allItems.insert(0, item);
    notifyListeners();
    return item;
  }

  Future<Uint8List?> readDecryptedBytes(VaultItem item) async {
    return await _fileVaultService.readDecryptedFileBytes(item, _activeVaultType);
  }

  Future<File?> exportFile(VaultItem item, Directory destinationDir) async {
    return await _fileVaultService.exportFile(
      item: item,
      destinationDir: destinationDir,
      vaultType: _activeVaultType,
    );
  }

  Future<void> deleteItem(VaultItem item) async {
    if (item.encryptedFilePath != null) {
      await _fileVaultService.deleteEncryptedFile(item, _activeVaultType);
    }
    await _dbService.deleteVaultItem(item.id, _activeVaultType);
    _allItems.removeWhere((i) => i.id == item.id);
    notifyListeners();
  }

  // ─── Notes Operations ───────────────────────────────────

  Future<void> saveNote({
    String? id,
    required String title,
    required String content,
    VaultCategory category = VaultCategory.note,
    List<String> tags = const [],
  }) async {
    final now = DateTime.now();
    final noteId = id ?? _uuid.v4();

    final item = VaultItem(
      id: noteId,
      title: title.trim().isEmpty ? 'Untitled Note' : title.trim(),
      category: category,
      content: content,
      mimeType: 'text/plain',
      fileSizeBytes: content.length,
      createdAt: now,
      updatedAt: now,
      isDecoy: _activeVaultType == VaultType.decoy,
      tags: tags,
    );

    await _dbService.insertVaultItem(item, _activeVaultType);

    final existingIndex = _allItems.indexWhere((i) => i.id == noteId);
    if (existingIndex >= 0) {
      _allItems[existingIndex] = item;
    } else {
      _allItems.insert(0, item);
    }
    notifyListeners();
  }

  // ─── Search & Category Filter ───────────────────────────

  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  void setCategoryFilter(VaultCategory? category) {
    _selectedCategory = category;
    notifyListeners();
  }

  void clearFilters() {
    _searchQuery = '';
    _selectedCategory = null;
    notifyListeners();
  }
}
