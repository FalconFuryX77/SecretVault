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
  VaultSession? _importingFor;

  /// Moves finished recordings that belong to the open vault into it: each
  /// is decrypted in memory with the vault's private key, stored as a vault
  /// file, and its encrypted staging copy is shredded. Recordings belonging
  /// to the other vault are left alone. Returns how many moved in.
  Future<int> importRecordings() {
    final session = _vault.session;
    // A run for another (now locked) vault doesn't count for this one.
    if (_importing != null && identical(_importingFor, session)) return _importing!;
    _importingFor = session;
    final run = _importRecordings(session);
    _importing = run;
    return run.whenComplete(() {
      if (identical(_importing, run)) {
        _importing = null;
        _importingFor = null;
      }
    });
  }

  Future<int> _importRecordings(VaultSession? session) async {
    if (session == null || !VaultRecorder.isAvailable) return 0;
    final keys = RecordingKeys.all(session);
    if (keys.isEmpty) return 0; // this vault has never recorded
    var moved = 0;
    try {
      for (final p in await VaultRecorder.pending()) {
        if (!session.isOpen) break;
        // One bad file must not hold up the rest.
        try {
          final tag = 'src:${p.id}';
          if (session.entries.any((e) => e.item.tags.contains(tag))) {
            // Moved in before, but the app stopped before the staging copy
            // was removed: don't import it twice.
            await VaultRecorder.discard(p.id);
            continue;
          }
          OpenedRecording? found;
          for (final k in keys) {
            found = await VaultRecorder.open(p.id, k);
            if (found != null) break;
          }
          if (found == null) continue; // another vault's
          final r = found;
          if (r.video) {
            if (await _importVideo(session, p.id, keys, tag)) moved++;
            continue;
          }
          if (r.empty) {
            await VaultRecorder.discard(p.id);
            continue;
          }
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
                tags: ['recording', tag],
              ),
            ),
          );
          await VaultRecorder.discard(p.id);
          moved++;
        } catch (e) {
          debugPrint('recording ${p.id} not imported: $e');
        }
      }
    } finally {
      for (final k in keys) {
        k.wipe();
      }
    }
    if (moved > 0 && identical(_vault.session, session)) _refreshFromSession();
    if (session.isOpen) {
      try {
        await RecordingKeys.rotateIfDue(
          session,
          status: await VaultRecorder.status(),
          rearm: (pub) => VaultRecorder.arm(
            pub,
            vibrate: RecordingKeys.vibrate(session),
            trigger: TriggerSettings.of(session),
          ),
        );
      } catch (e) {
        debugPrint('recording key not rotated: $e');
      }
    }
    return moved;
  }

  /// Progress of a video moving into the vault (0..1), null when none is.
  final ValueNotifier<double?> videoProgress = ValueNotifier(null);

  /// Streams one staged camera video into the vault as an MP4: decrypted
  /// and packed on the fly, never whole in memory or on disk.
  Future<bool> _importVideo(VaultSession session, String id, List<RecordingKeyPair> keys, String tag) async {
    StagedVideo? v;
    for (final k in keys) {
      v = await VaultRecorder.openVideo(id, k);
      if (v != null) break;
    }
    final video = v;
    if (video == null) return false;
    if (video.isEmpty) {
      await VaultRecorder.discard(id);
      return false;
    }
    try {
      final title = 'Video ${_stamp(video.startedAt)}${video.complete ? '' : ' (cut short)'}.mp4';
      videoProgress.value = 0;
      await _vault.whileBusy(
        () => session.importStream(
          video.length,
          VaultItem(
            id: _uuid.v4(),
            title: title,
            category: VaultCategory.video,
            mimeType: 'video/mp4',
            fileSizeBytes: video.length,
            createdAt: video.startedAt,
            updatedAt: DateTime.now(),
            tags: ['camera', tag],
          ),
          video.read,
          onProgress: (f) => videoProgress.value = f,
        ),
      );
    } finally {
      videoProgress.value = null;
      await video.close();
    }
    await VaultRecorder.discard(id);
    return true;
  }

  /// Stores a photo from the in-vault camera (already stripped of metadata).
  Future<VaultItem?> importPhoto(Uint8List jpeg) async {
    final session = _vault.session;
    if (session == null) return null;
    final now = DateTime.now();
    final item = VaultItem(
      id: _uuid.v4(),
      title: 'Photo ${_stamp(now)}.jpg',
      category: VaultCategory.image,
      mimeType: 'image/jpeg',
      fileSizeBytes: jpeg.length,
      createdAt: now,
      updatedAt: now,
      tags: const ['camera'],
    );
    await _vault.whileBusy(() => session.importBytes(jpeg, item));
    if (identical(_vault.session, session)) _refreshFromSession();
    return item;
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
    final session = _session;
    final entry = session.entryById(item.id);
    if (entry == null || entry.fileKey == null) return null;
    // Never overwrite an earlier export with the same name.
    final base = p.basenameWithoutExtension(item.title);
    final ext = p.extension(item.title);
    var out = File(p.join(destinationDir.path, '$base$ext'));
    for (var n = 1; await out.exists(); n++) {
      out = File(p.join(destinationDir.path, '$base ($n)$ext'));
    }
    try {
      await _vault.whileBusy(() => session.exportTo(entry, out));
    } catch (_) {
      // Don't leave half a plaintext file behind.
      try {
        if (await out.exists()) await out.delete();
      } catch (_) {}
      rethrow;
    }
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
