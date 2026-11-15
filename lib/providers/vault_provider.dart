import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../models/vault_state.dart';
import '../models/vault_item.dart';
import '../recorder/vault_recorder.dart';
import '../services/vault_service.dart';
import '../vault/vault_container.dart';
import '../viewers/file_kind.dart';
import '../viewers/vault_media_server.dart';

/// Thrown when a file is too large to decrypt into memory for preview.
class PreviewTooLargeException implements Exception {
  final int bytes;
  PreviewTooLargeException(this.bytes);
}

/// Reactive view over the unlocked vault session.
class VaultProvider extends ChangeNotifier {
  final VaultService _vault;
  final Uuid _uuid;
  StreamSubscription<void>? _lockedSub;
  bool _disposed = false;

  /// Files above this are exported rather than decrypted into RAM.
  static const int maxPreviewBytes = 64 * 1024 * 1024;

  VaultType _activeVaultType = VaultType.primary;
  VaultType get activeVaultType => _activeVaultType;

  List<VaultItem> _allItems = [];
  List<VaultItem> get allItems => _allItems;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  /// Progress of the current import (0..1), or null when idle.
  double? _importProgress;
  double? get importProgress => _importProgress;

  String _searchQuery = '';
  String get searchQuery => _searchQuery;

  VaultCategory? _selectedCategory;
  VaultCategory? get selectedCategory => _selectedCategory;

  VaultProvider({required VaultService vaultService, Uuid? uuid})
    : _vault = vaultService,
      _uuid = uuid ?? const Uuid() {
    _lockedSub = _vault.onLocked.listen((_) => clearVaultSession());
  }

  VaultSession get _session {
    final s = _vault.session;
    if (s == null) throw StateError('vault is locked');
    return s;
  }

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

  List<VaultItem> get media => _allItems
      .where(
        (i) =>
            i.category == VaultCategory.image ||
            i.category == VaultCategory.video,
      )
      .toList();

  List<VaultItem> get notes =>
      _allItems.where((i) => i.category == VaultCategory.note).toList();

  List<VaultItem> get keySecrets =>
      _allItems.where((i) => i.category == VaultCategory.keySecret).toList();

  // ─── Session ────────────────────────────────────────────

  Future<void> loadVault(VaultType vaultType) async {
    _activeVaultType = vaultType;
    _refreshFromSession();
    // Recordings made while the vault was locked move in now.
    unawaited(importRecordings().catchError((Object _) => 0));
  }

  Future<int>? _importing;

  /// Moves finished recordings that belong to the open vault into it: each
  /// is decrypted in memory with the vault's private key, stored as a vault
  /// file, and its encrypted staging copy is shredded. Recordings belonging
  /// to the other vault are left alone. Returns how many moved in.
  Future<int> importRecordings() {
    return _importing ??= _importRecordings().whenComplete(() => _importing = null);
  }

  Future<int> _importRecordings() async {
    final session = _vault.session;
    if (session == null || !VaultRecorder.isAvailable) return 0;
    final privateKey = RecordingKeys.privateKey(session);
    if (privateKey == null) return 0; // this vault has never recorded
    var moved = 0;
    try {
      for (final p in await VaultRecorder.pending()) {
        final r = await VaultRecorder.open(p.id, Uint8List.fromList(privateKey));
        if (r == null) continue;
        final title = 'Recording ${_stamp(r.startedAt)}${r.complete ? '' : ' (cut short)'}.${r.ext}';
        await _vault.whileBusy(
          () => session.importBytes(
            r.data,
            VaultItem(
              id: _uuid.v4(),
              title: title,
              category: VaultCategory.document,
              mimeType: mimeForName(title),
              fileSizeBytes: r.data.length,
              createdAt: r.startedAt,
              updatedAt: DateTime.now(),
              tags: const ['recording'],
            ),
          ),
        );
        await VaultRecorder.discard(p.id);
        moved++;
      }
    } finally {
      privateKey.fillRange(0, privateKey.length, 0);
    }
    if (moved > 0) _refreshFromSession();
    return moved;
  }

  static String _stamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}.${two(t.minute)}.${two(t.second)}';
  }

  void _refreshFromSession() {
    final s = _vault.session;
    _allItems = s == null ? [] : s.entries.map((e) => e.item).toList();
    _allItems.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    notifyListeners();
  }

  void clearVaultSession() {
    _allItems = [];
    _searchQuery = '';
    _selectedCategory = null;
    _isLoading = false;
    _importProgress = null;
    notifyListeners();
  }

  // ─── Files ──────────────────────────────────────────────

  /// Streams the file into the vault. If [deleteOriginal] is set, the
  /// plaintext original is removed only after the vault has committed it.
  Future<VaultItem> importFile({
    required File sourceFile,
    required String title,
    required VaultCategory category,
    required String mimeType,
    bool deleteOriginal = false,
    List<String> tags = const [],
  }) async {
    final now = DateTime.now();
    final meta = VaultItem(
      id: _uuid.v4(),
      title: title,
      category: category,
      mimeType: mimeType,
      fileSizeBytes: 0,
      createdAt: now,
      updatedAt: now,
      tags: tags,
    );
    _importProgress = 0;
    notifyListeners();
    try {
      final session = _session;
      final entry = await _vault.whileBusy(
        () => session.importFile(
          sourceFile,
          meta,
          onProgress: (p) {
            _importProgress = p;
            notifyListeners();
          },
        ),
      );
      if (deleteOriginal) {
        try {
          await sourceFile.delete();
        } catch (_) {}
      }
      _refreshFromSession();
      return entry.item;
    } finally {
      _importProgress = null;
      notifyListeners();
    }
  }

  /// Decrypts a file into memory for in-app viewing. Throws
  /// [PreviewTooLargeException] for big files (export those instead), and
  /// `TamperedDataException` if the ciphertext was modified.
  Future<Uint8List?> readDecryptedBytes(VaultItem item) async {
    final entry = _session.entryById(item.id);
    if (entry == null || entry.fileKey == null) return null;
    if (entry.byteLength > maxPreviewBytes) {
      throw PreviewTooLargeException(entry.byteLength);
    }
    return _session.readAll(entry);
  }

  /// Starts a private loopback stream of [item] for the media player (see
  /// [VaultMediaServer]). Unlike [readDecryptedBytes] there is no size limit:
  /// only the chunks the player asks for are decrypted, as it asks.
  Future<VaultMediaServer?> openMediaStream(
    VaultItem item, {
    void Function(Object error)? onReadError,
  }) async {
    final session = _session;
    final entry = session.entryById(item.id);
    if (entry == null || entry.fileKey == null) return null;
    final dot = item.title.lastIndexOf('.');
    // Items imported by older versions were often stored as octet-stream.
    final mime = item.mimeType.startsWith('audio/') || item.mimeType.startsWith('video/')
        ? item.mimeType
        : mimeForName(item.title);
    return VaultMediaServer.start(
      length: entry.byteLength,
      contentType: mime,
      extension: dot < 0 ? 'bin' : item.title.substring(dot + 1).toLowerCase(),
      read: (offset, length) => session.readRange(entry, offset, length),
      onReadError: onReadError,
    );
  }

  /// Saves new content for a file item (an edited text file). The old copy
  /// is shredded once the new one is committed.
  Future<VaultItem> saveFileContent(VaultItem item, Uint8List content) async {
    final entry = await _vault.whileBusy(
      () => _session.replaceContent(item.id, content, item.copyWith(updatedAt: DateTime.now())),
    );
    _refreshFromSession();
    return entry.item;
  }

  /// Writes a decrypted copy to [destinationDir]. This deliberately leaves
  /// plaintext outside the vault, so only call it on explicit user request.
  Future<File?> exportFile(VaultItem item, Directory destinationDir) async {
    final entry = _session.entryById(item.id);
    if (entry == null || entry.fileKey == null) return null;
    final out = File(p.join(destinationDir.path, p.basename(item.title)));
    await _session.exportTo(entry, out);
    return out;
  }

  Future<void> deleteItem(VaultItem item) async {
    await _session.delete(item.id);
    _refreshFromSession();
  }

  Future<void> toggleFavorite(VaultItem item) async {
    await _session.upsertItem(item.copyWith(isFavorite: !item.isFavorite));
    _refreshFromSession();
  }

  Future<void> renameItem(VaultItem item, String newTitle) async {
    await _session.upsertItem(
      item.copyWith(title: newTitle, updatedAt: DateTime.now()),
    );
    _refreshFromSession();
  }

  // ─── Notes ──────────────────────────────────────────────

  Future<void> saveNote({
    String? id,
    required String title,
    required String content,
    VaultCategory category = VaultCategory.note,
    List<String> tags = const [],
  }) async {
    final now = DateTime.now();
    final existing = id == null ? null : _session.entryById(id)?.item;
    final item = VaultItem(
      id: id ?? _uuid.v4(),
      title: title.trim().isEmpty ? 'Untitled Note' : title.trim(),
      category: category,
      content: content,
      mimeType: 'text/plain',
      fileSizeBytes: content.length,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      tags: tags,
      isFavorite: existing?.isFavorite ?? false,
    );
    await _session.upsertItem(item);
    _refreshFromSession();
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

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _lockedSub?.cancel();
    super.dispose();
  }
}
