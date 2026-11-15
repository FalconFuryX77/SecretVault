import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../models/vault_state.dart';
import '../models/vault_item.dart';
import 'bulk_crypto.dart';
import 'crypto_primitives.dart';
import 'platform_keys.dart';
import 'vault_index.dart';

/// On-disk layout of the vault container.
///
/// The whole vault — every vault, real and decoy — lives in ONE fixed-format
/// file made of 64 KiB chunks. Every byte of it is either AES-GCM ciphertext
/// or random filler, and there are no plaintext markers, so:
///   * the file size says nothing about how much is stored (space is
///     pre-allocated and grows only in large random-filled steps);
///   * there is no way to tell how many of the 4 key-slot records are in use,
///     so a decoy vault cannot be shown to have a hidden sibling.
///
/// Chunk 0 is the header: a 32-byte KDF salt, then [recordCount] records of
/// [recordSize] bytes. Each record holds:
///   * a PIN slot      – vault key sealed under the PIN-derived key
///   * superblocks A/B – where the vault's encrypted index lives (two copies
///                       with a generation counter, so a crash mid-write
///                       never loses the index)
/// Unused records, slots and chunks are random bytes.
class ContainerLayout {
  ContainerLayout._();

  static const int chunkSize = 64 * 1024;
  static const int sealOverhead =
      CryptoPrimitives.nonceLen + CryptoPrimitives.tagLen;
  static const int chunkPayload = chunkSize - sealOverhead;

  static const int saltLen = 32;
  static const int recordCount = 4;
  static const int recordsOffset = 64;
  static const int recordSize = 8192;

  static const int pinSlotOffset = 0;
  static const int pinSlotLen = CryptoPrimitives.keyLen + sealOverhead; // 60

  // Bytes 64–219 of each record held a gesture/biometric slot in an earlier
  // format. They are unused now and stay random filler.

  static const int superPlainLen = 2048;
  static const int superSlotLen = superPlainLen + sealOverhead; // 2076
  static const List<int> superOffsets = [256, 256 + superSlotLen];

  static int recordOffset(int r) => recordsOffset + r * recordSize;
  static int chunkOffset(int c) => c * chunkSize;

  /// Default pre-allocation: 256 MiB, and grow in 256 MiB steps.
  static const int defaultInitialChunks = 4096;
  static const int defaultGrowChunks = 4096;
}

class CredentialInUseException implements Exception {
  @override
  String toString() => 'That PIN is already used by another vault.';
}

class NoFreeRecordException implements Exception {}

class VaultCorruptedException implements Exception {
  final String message;
  VaultCorruptedException(this.message);
  @override
  String toString() => 'VaultCorruptedException: $message';
}

/// Dependencies shared by the container and its sessions.
class VaultCrypto {
  final DeviceBinding binding;
  final KdfParams pinParams;
  final int growChunks;

  /// Batched chunk sealing/opening and random fill (native on Android).
  final BulkCrypto bulk;

  VaultCrypto({
    required this.binding,
    BulkCrypto? bulk,
    this.pinParams = KdfParams.pin,
    this.growChunks = ContainerLayout.defaultGrowChunks,
  }) : bulk = bulk ?? defaultBulkCrypto();

  Future<Uint8List> pinKek(String pin, Uint8List salt) =>
      _kek(utf8.encode('p:$pin'), salt, pinParams, 'sv/pin-kek');

  Future<Uint8List> _kek(
    List<int> secret,
    Uint8List salt,
    KdfParams params,
    String info,
  ) async {
    final stretched = await CryptoPrimitives.argon2id(secret, salt, params);
    final bound = await binding.bind(stretched);
    final kek = await CryptoPrimitives.hkdf(bound, salt: salt, info: info);
    CryptoPrimitives.wipe(stretched);
    CryptoPrimitives.wipe(bound);
    return kek;
  }
}

List<int> _aadPin(int r) => [1, r];
List<int> _aadSuper(int r, int slot) => [3, r, slot];
List<int> _aadIndex(int gen, int seq, bool last) {
  final b = ByteData(14)
    ..setUint8(0, 4)
    ..setUint64(1, gen)
    ..setUint32(9, seq)
    ..setUint8(13, last ? 1 : 0);
  return b.buffer.asUint8List();
}

List<int> _aadFile(String id, int seq, bool last) {
  final b = ByteData(5)
    ..setUint32(0, seq)
    ..setUint8(4, last ? 1 : 0);
  return [5, ...utf8.encode(id), 0, ...b.buffer.asUint8List()];
}

/// Entry point: create a container, or unlock one with a PIN.
class VaultContainer {
  final File file;
  final VaultCrypto crypto;

  VaultContainer(this.file, this.crypto);

  Future<bool> exists() => file.exists();

  /// Creates a fresh container with a single (real) vault protected by [pin].
  /// Every byte is random until something is written.
  static Future<VaultSession> create(
    File file,
    VaultCrypto crypto, {
    required String pin,
    int initialChunks = ContainerLayout.defaultInitialChunks,
    void Function(double progress)? onProgress,
  }) async {
    if (initialChunks < 2) {
      throw ArgumentError('container needs at least 2 chunks');
    }
    await file.parent.create(recursive: true);
    final raf = await file.open(mode: FileMode.write);
    try {
      await crypto.bulk.fillRandom(
        raf,
        file,
        0,
        initialChunks * ContainerLayout.chunkSize,
        onProgress: onProgress,
      );
      await raf.flush();
    } finally {
      await raf.close();
    }

    final container = VaultContainer(file, crypto);
    final session = await container._openSession();
    try {
      final record = Random.secure().nextInt(ContainerLayout.recordCount);
      final vk = CryptoPrimitives.randomBytes(CryptoPrimitives.keyLen);
      final kek = await crypto.pinKek(pin, session._salt);
      await session._writePinSlot(record, kek, vk);
      CryptoPrimitives.wipe(kek);
      final root = await _OpenVault.fresh(
        record,
        vk,
        VaultIndex(topDown: true, ceiling: initialChunks),
      );
      session._root = root;
      await session._writeIndex(root);
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  /// Tries the PIN against every record. Returns null if it matches none.
  Future<VaultSession?> unlockWithPin(String pin) async {
    final session = await _openSession();
    try {
      final kek = await crypto.pinKek(pin, session._salt);
      final hit = await session._findPinRecord(kek);
      CryptoPrimitives.wipe(kek);
      if (hit == null) {
        await session.close();
        return null;
      }
      await session._loadRoot(hit.$1, hit.$2);
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  Future<VaultSession> _openSession() async {
    final raf = await file.open(mode: FileMode.append);
    final salt = _readAt(raf, 0, ContainerLayout.saltLen);
    return VaultSession._(this, raf, salt);
  }
}

class _OpenVault {
  final int record;
  final Uint8List vk;
  final Uint8List superKey;
  final Uint8List indexKey;
  int gen = 0;
  int slot = 1; // slot holding the current superblock; first write goes to 0
  List<Extent> indexExtents = const [];
  VaultIndex index;
  final List<_OpenVault> children = [];

  _OpenVault._(this.record, this.vk, this.superKey, this.indexKey, this.index);

  static Future<_OpenVault> fresh(
    int record,
    Uint8List vk,
    VaultIndex index,
  ) async {
    final salt = utf8.encode('sv/vault');
    return _OpenVault._(
      record,
      vk,
      await CryptoPrimitives.hkdf(vk, salt: salt, info: 'superblock'),
      await CryptoPrimitives.hkdf(vk, salt: salt, info: 'index'),
      index,
    );
  }

  Iterable<_OpenVault> get selfAndDescendants sync* {
    yield this;
    for (final c in children) {
      yield* c.selfAndDescendants;
    }
  }

  Iterable<int> get usedChunks sync* {
    for (final e in indexExtents) {
      yield* e.chunks;
    }
    for (final entry in index.entries) {
      for (final e in entry.extents) {
        yield* e.chunks;
      }
    }
  }

  void wipe() {
    CryptoPrimitives.wipe(vk);
    CryptoPrimitives.wipe(superKey);
    CryptoPrimitives.wipe(indexKey);
    for (final l in index.links) {
      CryptoPrimitives.wipe(l.vaultKey);
    }
    for (final e in index.entries) {
      CryptoPrimitives.wipe(e.fileKey);
    }
    for (final c in children) {
      c.wipe();
    }
  }
}

/// An unlocked vault. Holds the keys in memory until [close] is called.
class VaultSession {
  final VaultContainer _container;
  final RandomAccessFile _raf;
  final Uint8List _salt;
  _OpenVault? _root;
  bool _closed = false;
  Future<void> _tail = Future.value();
  final Set<int> _reserved = {};

  VaultSession._(this._container, this._raf, this._salt);

  VaultCrypto get _crypto => _container.crypto;
  _OpenVault get _r {
    final r = _root;
    if (r == null || _closed) throw StateError('vault is locked');
    return r;
  }

  /// The open vault for code running *inside* an operation. A lock that
  /// arrives mid-operation waits for it ([close] awaits the queue), so the
  /// operation must not fail half-way just because a lock was requested:
  /// that turned a finished save into a rollback that shredded the new copy.
  _OpenVault get _live {
    final r = _root;
    if (r == null) throw StateError('vault is locked');
    return r;
  }

  /// Chunks picked for the root vault during the current operation, not yet
  /// in its index. Unlike [_reserved] this excludes chunks picked for the
  /// decoy, so the decoy's ceiling isn't pulled down to its own index.
  final Set<int> _rootReserved = {};

  bool get isOpen => !_closed && _root != null;

  /// The real vault allocates top-down; a decoy bottom-up. Callers must not
  /// show this anywhere in the UI.
  VaultType get type => _r.index.topDown ? VaultType.primary : VaultType.decoy;

  List<IndexEntry> get entries => List.unmodifiable(_r.index.entries);

  bool get hasDecoy => _r.children.isNotEmpty;

  /// Only a real vault can own a decoy (a decoy can't safely host one).
  bool get canManageDecoy => _r.index.topDown;

  Future<int> get capacityBytes async => await _raf.length();

  int get usedBytes {
    var chunks = 0;
    for (final v in _r.selfAndDescendants) {
      chunks += v.usedChunks.length;
    }
    return chunks * ContainerLayout.chunkSize;
  }

  /// Serialises all container access; RandomAccessFile is not re-entrant.
  Future<T> _locked<T>(Future<T> Function() op) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await op());
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        _reserved.clear();
        _rootReserved.clear();
      }
    });
    return completer.future;
  }

  // ─── Items ──────────────────────────────────────────────────────

  /// Streams [source] into the vault in encrypted chunks, so files of any
  /// size can be imported without loading them into memory.
  Future<IndexEntry> importFile(
    File source,
    VaultItem meta, {
    void Function(double)? onProgress,
  }) {
    return _locked(() async {
      final length = await source.length();
      final src = await source.open();
      try {
        final (chunks, fileKey) = await _writeChunks(
          meta.id,
          length,
          (_) => _readUpTo(src, ContainerLayout.chunkPayload),
          onProgress,
        );
        return _addEntry(meta, chunks, fileKey, length);
      } finally {
        await src.close();
      }
    });
  }

  /// Stores [data], which is already in memory (a recording, an edited
  /// text file), as a new item. Nothing is written outside the container.
  Future<IndexEntry> importBytes(Uint8List data, VaultItem meta) {
    return _locked(() async {
      final (chunks, fileKey) = await _writeChunks(meta.id, data.length, _slicer(data), null);
      return _addEntry(meta, chunks, fileKey, data.length);
    });
  }

  /// Replaces the content of file item [id] with [data] and its metadata
  /// with [item]. The new copy is written and committed before the old
  /// chunks are shredded, so a crash leaves either the old or the new file.
  Future<IndexEntry> replaceContent(String id, Uint8List data, VaultItem item) {
    if (item.id != id) throw ArgumentError('item id must stay the same');
    return _locked(() async {
      final root = _r;
      final idx = root.index.entries.indexWhere((e) => e.item.id == id);
      if (idx < 0) throw StateError('no item $id');
      final old = root.index.entries[idx];
      if (old.fileKey == null) throw StateError('item $id has no file data');
      final (chunks, fileKey) = await _writeChunks(id, data.length, _slicer(data), null);
      final fresh = IndexEntry(
        item: item.copyWith(fileSizeBytes: data.length),
        fileKey: fileKey,
        extents: extentsFromChunks(chunks),
        byteLength: data.length,
      );
      root.index.entries[idx] = fresh;
      _holdUntilShredded(old.extents);
      try {
        await _commit(root);
      } catch (_) {
        root.index.entries[idx] = old;
        await _shred(fresh.extents);
        rethrow;
      }
      await _shred(old.extents);
      CryptoPrimitives.wipe(old.fileKey);
      return fresh;
    });
  }

  static Uint8List Function(int) _slicer(Uint8List data) => (seq) {
        final start = seq * ContainerLayout.chunkPayload;
        final end = min(data.length, start + ContainerLayout.chunkPayload);
        return Uint8List.sublistView(data, min(start, end), end);
      };

  /// Allocates chunks for a [length]-byte file and writes it encrypted under
  /// a fresh key. [next] returns the plaintext of chunk `seq`, in order.
  /// Must run inside [_locked]; the caller commits (or shreds on failure).
  Future<(List<int>, Uint8List)> _writeChunks(
    String id,
    int length,
    Uint8List Function(int seq) next,
    void Function(double)? onProgress,
  ) async {
    final root = _live;
    final n = max(1, (length / ContainerLayout.chunkPayload).ceil());
    final chunks = await _allocate(root, n);
    final fileKey = CryptoPrimitives.randomBytes(CryptoPrimitives.keyLen);
    for (var start = 0; start < n; start += _batch) {
      // A lock during a long import stops it here rather than keeping every
      // key in memory for minutes; nothing was committed, and the key goes.
      if (_closed) {
        CryptoPrimitives.wipe(fileKey);
        throw StateError('vault locked during import');
      }
      final end = min(n, start + _batch);
      final plains = <Uint8List>[];
      final aads = <List<int>>[];
      for (var seq = start; seq < end; seq++) {
        final plain = next(seq);
        // Every chunk but the last is full, and the total is [length]. A
        // source that shrank or grew mid-import would otherwise be stored as
        // an entry that can never be read back.
        final expected = seq == n - 1 ? length - seq * ContainerLayout.chunkPayload : ContainerLayout.chunkPayload;
        if (plain.length != expected) {
          CryptoPrimitives.wipe(fileKey);
          throw StateError('the file changed while it was being imported');
        }
        plains.add(plain);
        aads.add(_aadFile(id, seq, seq == n - 1));
      }
      final fulls = await _crypto.bulk.sealChunks(
        fileKey,
        plains,
        aads,
        ContainerLayout.chunkSize,
      );
      for (var k = 0; k < fulls.length; k++) {
        _writeAt(ContainerLayout.chunkOffset(chunks[start + k]), fulls[k]);
      }
      onProgress?.call(end / n);
    }
    await _raf.flush();
    return (chunks, fileKey);
  }

  Future<IndexEntry> _addEntry(VaultItem meta, List<int> chunks, Uint8List fileKey, int length) async {
    final root = _live;
    final entry = IndexEntry(
      item: meta.copyWith(fileSizeBytes: length),
      fileKey: fileKey,
      extents: extentsFromChunks(chunks),
      byteLength: length,
    );
    root.index.entries.insert(0, entry);
    try {
      await _commit(root);
    } catch (_) {
      root.index.entries.remove(entry);
      rethrow;
    }
    return entry;
  }

  /// Decrypts a stored file chunk by chunk. Throws [TamperedDataException]
  /// if any chunk was altered, swapped, reordered or truncated.
  Stream<Uint8List> read(IndexEntry entry) async* {
    final key = entry.fileKey;
    if (key == null) return;
    final chunks = entry.extents.expand((e) => e.chunks).toList();
    final n = chunks.length;
    for (var start = 0; start < n; start += _batch) {
      final end = min(n, start + _batch);
      for (final part in await _openChunks(entry, key, chunks, start, end)) {
        yield part;
      }
    }
  }

  /// Decrypts container chunks [start, end) of [entry], verified.
  Future<List<Uint8List>> _openChunks(
    IndexEntry entry,
    Uint8List key,
    List<int> chunks,
    int start,
    int end,
  ) async {
    final n = chunks.length;
    final aads = <List<int>>[];
    final sealed = await _locked(() async {
      final out = <Uint8List>[];
      for (var seq = start; seq < end; seq++) {
        final last = seq == n - 1;
        final plainLen = last
            ? entry.byteLength - seq * ContainerLayout.chunkPayload
            : ContainerLayout.chunkPayload;
        if (plainLen < 0 || plainLen > ContainerLayout.chunkPayload) {
          throw TamperedDataException('index length mismatch');
        }
        out.add(
          _readAt(
            _raf,
            ContainerLayout.chunkOffset(chunks[seq]),
            plainLen + ContainerLayout.sealOverhead,
          ),
        );
        aads.add(_aadFile(entry.item.id, seq, last));
      }
      return out;
    });
    return _crypto.bulk.openChunks(key, sealed, aads);
  }

  /// Decrypts [length] bytes of [entry] starting at [offset], touching only
  /// the chunks that hold them. Used to back a file up piece by piece
  /// without ever writing it out in the clear.
  Future<Uint8List> readRange(IndexEntry entry, int offset, int length) async {
    final key = entry.fileKey;
    if (key == null) throw StateError('item has no file data');
    if (offset < 0 || length < 0 || offset + length > entry.byteLength) {
      throw RangeError('range $offset+$length is outside ${entry.byteLength} bytes');
    }
    if (length == 0) return Uint8List(0);
    const payload = ContainerLayout.chunkPayload;
    final chunks = entry.extents.expand((e) => e.chunks).toList();
    final first = offset ~/ payload;
    final last = (offset + length - 1) ~/ payload;
    final out = Uint8List(length);
    var written = 0;
    for (var start = first; start <= last; start += _batch) {
      final end = min(last + 1, start + _batch);
      final parts = await _openChunks(entry, key, chunks, start, end);
      for (var i = 0; i < parts.length; i++) {
        final chunkStart = (start + i) * payload;
        final from = max(offset, chunkStart) - chunkStart;
        final to = min(offset + length, chunkStart + parts[i].length) - chunkStart;
        out.setRange(written, written + (to - from), parts[i], from);
        written += to - from;
      }
    }
    if (written != length) throw TamperedDataException('short read');
    return out;
  }

  // ─── Per-vault settings ─────────────────────────────────────────

  /// A copy of this vault's encrypted settings (see [VaultIndex.extras]).
  Map<String, dynamic> get extras =>
      jsonDecode(jsonEncode(_r.index.extras)) as Map<String, dynamic>;

  /// Sets one settings entry (or removes it with null) and saves the index.
  Future<void> putExtra(String key, Object? value) {
    return _locked(() async {
      final root = _r;
      final had = root.index.extras.containsKey(key);
      final previous = root.index.extras[key];
      if (value == null) {
        root.index.extras.remove(key);
      } else {
        root.index.extras[key] = jsonDecode(jsonEncode(value));
      }
      try {
        await _commit(root);
      } catch (_) {
        if (had) {
          root.index.extras[key] = previous;
        } else {
          root.index.extras.remove(key);
        }
        rethrow;
      }
    });
  }

  Future<Uint8List> readAll(IndexEntry entry) async {
    final out = BytesBuilder(copy: false);
    await for (final part in read(entry)) {
      out.add(part);
    }
    return out.takeBytes();
  }

  Future<void> exportTo(IndexEntry entry, File destination) async {
    // Synchronous writes for the same reason as the container IO: one cheap
    // call per chunk instead of an event-loop round trip per chunk.
    final out = await destination.open(mode: FileMode.write);
    try {
      await for (final part in read(entry)) {
        out.writeFromSync(part);
      }
      await out.flush();
    } finally {
      await out.close();
    }
  }

  IndexEntry? entryById(String id) {
    for (final e in _r.index.entries) {
      if (e.item.id == id) return e;
    }
    return null;
  }

  /// Inserts or replaces item metadata (notes, renames, favourites).
  Future<void> upsertItem(VaultItem item) {
    return _locked(() async {
      final root = _r;
      final idx = root.index.entries.indexWhere((e) => e.item.id == item.id);
      VaultItem? previous;
      if (idx >= 0) {
        previous = root.index.entries[idx].item;
        root.index.entries[idx].item = item;
      } else {
        root.index.entries.insert(0, IndexEntry(item: item));
      }
      try {
        await _commit(root);
      } catch (_) {
        if (previous != null) {
          root.index.entries[idx].item = previous;
        } else {
          root.index.entries.removeWhere((e) => e.item.id == item.id);
        }
        rethrow;
      }
    });
  }

  /// Removes an item and overwrites its chunks with random data.
  Future<void> delete(String id) {
    return _locked(() async {
      final root = _r;
      final idx = root.index.entries.indexWhere((e) => e.item.id == id);
      if (idx < 0) return;
      final entry = root.index.entries.removeAt(idx);
      _holdUntilShredded(entry.extents);
      await _commit(root);
      await _shred(entry.extents);
      CryptoPrimitives.wipe(entry.fileKey);
    });
  }

  // ─── Credentials ────────────────────────────────────────────────

  Future<void> changePin(String newPin) => _locked(() => _setPin(_r, newPin));

  // ─── Decoy vault ────────────────────────────────────────────────

  /// Creates a decoy vault in a free record, opened with [pin]. The real
  /// vault keeps the decoy's key so it never overwrites the decoy's data;
  /// the decoy knows nothing about the real one.
  Future<void> createDecoy({required String pin}) {
    return _locked(() async {
      final root = _r;
      if (!root.index.topDown) {
        throw StateError('only the real vault can own a decoy');
      }
      if (root.children.isNotEmpty) throw StateError('decoy already exists');
      final kek = await _crypto.pinKek(pin, _salt);
      try {
        final hit = await _findPinRecord(kek);
        if (hit != null) {
          CryptoPrimitives.wipe(hit.$2);
          throw CredentialInUseException();
        }
        final taken = root.selfAndDescendants.map((v) => v.record).toSet();
        final free = [
          for (var r = 0; r < ContainerLayout.recordCount; r++)
            if (!taken.contains(r)) r,
        ];
        if (free.isEmpty) throw NoFreeRecordException();
        final record = free[Random.secure().nextInt(free.length)];
        final vk = CryptoPrimitives.randomBytes(CryptoPrimitives.keyLen);
        final decoy = await _OpenVault.fresh(
          record,
          vk,
          VaultIndex(topDown: false, ceiling: await _lowestChunkOf(root)),
        );
        // Order matters for crash safety: the decoy's index, then the real
        // vault's link to it (so the real vault protects the decoy's space
        // from then on), and only then the PIN slot that makes it openable.
        // An openable decoy the real vault didn't know about could later
        // overwrite real data.
        await _writeIndex(decoy);
        root.children.add(decoy);
        final link = LinkedVault(record, Uint8List.fromList(vk));
        root.index.links.add(link);
        try {
          await _commit(root);
        } catch (_) {
          root.children.remove(decoy);
          root.index.links.remove(link);
          rethrow;
        }
        await _writePinSlot(record, kek, vk);
      } finally {
        CryptoPrimitives.wipe(kek);
      }
    });
  }

  /// What a decoy does when its user "sets up a decoy" (or changes or
  /// removes one) in Settings. A decoy must look like a lone real vault,
  /// which offers that, but a decoy can't safely create a vault of its own:
  /// it can't see which records and chunks the real vault uses. So it does
  /// the same work (one key derivation, so it takes as long) and records the
  /// "decoy" in its own settings, without creating anything. The PIN it was
  /// given opens nothing. It refuses only what a lone vault would refuse:
  /// its own PIN. Never reveals whether [pin] opens another vault.
  Future<void> standInDecoySetup(String pin, {required bool shown}) {
    return _locked(() async {
      final root = _r;
      if (root.index.topDown) throw StateError('only a decoy uses the stand-in');
      final kek = await _crypto.pinKek(pin, _salt);
      try {
        final hit = await _findPinRecord(kek);
        if (hit != null) CryptoPrimitives.wipe(hit.$2);
        if (hit != null && hit.$1 == root.record) throw CredentialInUseException();
      } finally {
        CryptoPrimitives.wipe(kek);
      }
      root.index.extras[standInDecoyKey] = shown;
      if (!shown) root.index.extras.remove(standInDecoyKey);
      await _commit(root);
    });
  }

  static const String standInDecoyKey = 'decoy.shown';

  /// Whether this vault shows a decoy in Settings: a real decoy for the
  /// real vault, the stand-in one for a decoy.
  bool get showsDecoy =>
      _r.index.topDown ? _r.children.isNotEmpty : _r.index.extras[standInDecoyKey] == true;

  Future<void> changeDecoyPin(String pin) =>
      _locked(() => _setPin(_decoy, pin));

  /// Deletes the decoy vault and shreds everything it stored.
  Future<void> removeDecoy() {
    return _locked(() async {
      final root = _r;
      final decoy = _decoy;
      final chunks =
          decoy.selfAndDescendants.expand((v) => v.usedChunks).toList()..sort();
      // First make the decoy PIN stop working, so a crash at any later
      // point can't leave an openable decoy the real vault no longer
      // protects. Its superblocks stay until the unlink is committed (the
      // real vault still needs them to load it until then).
      await _fillRandom(
        ContainerLayout.recordOffset(decoy.record) + ContainerLayout.pinSlotOffset,
        ContainerLayout.pinSlotLen,
      );
      await _raf.flush();
      root.children.remove(decoy);
      root.index.links.removeWhere((l) => l.record == decoy.record);
      _holdUntilShredded(extentsFromChunks(chunks));
      await _commit(root);
      await _fillRandom(
        ContainerLayout.recordOffset(decoy.record),
        ContainerLayout.recordSize,
      );
      await _shred(extentsFromChunks(chunks));
      decoy.wipe();
    });
  }

  _OpenVault get _decoy {
    final root = _live;
    if (root.children.isEmpty) throw StateError('no decoy');
    return root.children.first;
  }

  /// Locks the vault: wipes keys from memory and closes the file.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _tail;
    } catch (_) {}
    _root?.wipe();
    _root = null;
    CryptoPrimitives.wipe(_salt);
    await _raf.close();
  }

  // ─── Internals: records ─────────────────────────────────────────

  Future<(int, Uint8List)?> _findPinRecord(Uint8List kek) async {
    (int, Uint8List)? hit;
    // Always try every record so timing doesn't reveal which ones are real.
    for (var r = 0; r < ContainerLayout.recordCount; r++) {
      final slot = _readAt(
        _raf,
        ContainerLayout.recordOffset(r) + ContainerLayout.pinSlotOffset,
        ContainerLayout.pinSlotLen,
      );
      final vk = await CryptoPrimitives.tryOpen(kek, slot, _aadPin(r));
      if (vk != null && hit == null) hit = (r, vk);
    }
    return hit;
  }

  Future<void> _writePinSlot(int record, Uint8List kek, Uint8List vk) async {
    final sealed = await CryptoPrimitives.seal(kek, vk, _aadPin(record));
    _writeAt(
      ContainerLayout.recordOffset(record) + ContainerLayout.pinSlotOffset,
      sealed,
    );
    await _raf.flush();
  }

  Future<void> _setPin(_OpenVault v, String pin) async {
    final kek = await _crypto.pinKek(pin, _salt);
    try {
      final hit = await _findPinRecord(kek);
      if (hit != null) CryptoPrimitives.wipe(hit.$2);
      if (hit != null && hit.$1 != v.record) throw CredentialInUseException();
      await _writePinSlot(v.record, kek, v.vk);
    } finally {
      CryptoPrimitives.wipe(kek);
    }
  }

  // ─── Internals: index load / commit ─────────────────────────────

  Future<void> _loadRoot(int record, Uint8List vk) async {
    final root = await _loadVault(record, vk, depth: 0);
    _root = root;
    // Keep the decoy's ceiling in step with the real vault (e.g. after the
    // real vault freed space, or the decoy grew the container on its own).
    if (root.index.topDown) {
      await _locked(() => _syncChildCeilings(root));
    }
  }

  Future<_OpenVault> _loadVault(
    int record,
    Uint8List vk, {
    required int depth,
  }) async {
    if (depth > ContainerLayout.recordCount) {
      throw VaultCorruptedException('link cycle');
    }
    final v = await _OpenVault.fresh(
      record,
      vk,
      VaultIndex(topDown: true, ceiling: 0),
    );
    int? bestGen;
    Map<String, dynamic>? best;
    var bestSlot = 0;
    for (var s = 0; s < 2; s++) {
      final raw = _readAt(
        _raf,
        ContainerLayout.recordOffset(record) + ContainerLayout.superOffsets[s],
        ContainerLayout.superSlotLen,
      );
      final plain = await CryptoPrimitives.tryOpen(
        v.superKey,
        raw,
        _aadSuper(record, s),
      );
      if (plain == null) continue;
      final len = (plain[0] << 8) | plain[1];
      final sb =
          jsonDecode(utf8.decode(plain.sublist(2, 2 + len)))
              as Map<String, dynamic>;
      final gen = sb['g'] as int;
      if (bestGen == null || gen > bestGen) {
        bestGen = gen;
        best = sb;
        bestSlot = s;
      }
    }
    if (best == null) throw VaultCorruptedException('no valid superblock');
    v.gen = bestGen!;
    v.slot = bestSlot;
    v.indexExtents = (best['e'] as List).map(Extent.fromJson).toList();
    final byteLen = best['l'] as int;

    final chunks = v.indexExtents.expand((e) => e.chunks).toList();
    final out = BytesBuilder(copy: false);
    final sealed = <Uint8List>[];
    final aads = <List<int>>[];
    for (var seq = 0; seq < chunks.length; seq++) {
      final last = seq == chunks.length - 1;
      final plainLen = last
          ? byteLen - seq * ContainerLayout.chunkPayload
          : ContainerLayout.chunkPayload;
      if (plainLen < 0 || plainLen > ContainerLayout.chunkPayload) {
        throw VaultCorruptedException('index length mismatch');
      }
      sealed.add(
        _readAt(
          _raf,
          ContainerLayout.chunkOffset(chunks[seq]),
          plainLen + ContainerLayout.sealOverhead,
        ),
      );
      aads.add(_aadIndex(v.gen, seq, last));
    }
    for (final part in await _crypto.bulk.openChunks(
      v.indexKey,
      sealed,
      aads,
    )) {
      out.add(part);
    }
    v.index = VaultIndex.decode(out.takeBytes());
    for (final link in v.index.links) {
      v.children.add(
        await _loadVault(
          link.record,
          Uint8List.fromList(link.vaultKey),
          depth: depth + 1,
        ),
      );
    }
    return v;
  }

  /// Persists [v]'s index, then (for the real vault) keeps its decoy's
  /// allocation ceiling below every chunk the real vault uses.
  ///
  /// Once the root superblock is written the change is committed: anything
  /// after that (moving the decoy's ceiling up, shredding the old index) is
  /// best effort and never throws, so callers only ever roll back changes
  /// that didn't reach the disk.
  Future<void> _commit(_OpenVault v) async {
    await _writeIndex(v);
    if (v.index.topDown) {
      try {
        await _syncChildCeilings(v);
      } catch (_) {
        // Only ever raises the decoy's ceiling (lowering happens before any
        // real data is written, in _allocate); leaving it lower is safe.
      }
    }
  }

  Future<void> _syncChildCeilings(_OpenVault v) async {
    final ceiling = await _lowestChunkOf(v);
    for (final child in v.children) {
      if (child.index.topDown) continue;
      if (child.index.ceiling != ceiling || child.index.grownFrom != null) {
        child.index.ceiling = ceiling;
        child.index.grownFrom = null;
        await _writeIndex(child);
      }
    }
  }

  /// The lowest chunk [v] uses (or the container end if it uses none),
  /// counting chunks picked for it in this operation but not chunks picked
  /// for its decoy or freed ones waiting to be shredded.
  Future<int> _lowestChunkOf(_OpenVault v) async {
    var low = await _raf.length() ~/ ContainerLayout.chunkSize;
    for (final c in v.usedChunks) {
      if (c < low) low = c;
    }
    if (identical(v, _root)) {
      for (final c in _rootReserved) {
        if (c < low) low = c;
      }
    }
    return low;
  }

  /// Copy-on-write index update: new index chunks first, then the
  /// superblock in the *other* slot, then shred the old index chunks.
  Future<void> _writeIndex(_OpenVault v) async {
    final plain = v.index.encode();
    final n = max(1, (plain.length / ContainerLayout.chunkPayload).ceil());
    final chunks = await _allocate(v, n);
    final gen = v.gen + 1;
    final plains = <Uint8List>[];
    final aads = <List<int>>[];
    for (var seq = 0; seq < n; seq++) {
      final start = seq * ContainerLayout.chunkPayload;
      final end = min(plain.length, start + ContainerLayout.chunkPayload);
      plains.add(Uint8List.sublistView(plain, start, end));
      aads.add(_aadIndex(gen, seq, seq == n - 1));
    }
    final fulls = await _crypto.bulk.sealChunks(
      v.indexKey,
      plains,
      aads,
      ContainerLayout.chunkSize,
    );
    for (var seq = 0; seq < n; seq++) {
      _writeAt(ContainerLayout.chunkOffset(chunks[seq]), fulls[seq]);
    }
    await _raf.flush();

    final extents = extentsFromChunks(chunks);
    final sbJson = utf8.encode(
      jsonEncode({
        'g': gen,
        'l': plain.length,
        'e': extents.map((e) => e.toJson()).toList(),
      }),
    );
    if (sbJson.length > ContainerLayout.superPlainLen - 2) {
      throw VaultCorruptedException('index too fragmented');
    }
    final sbPlain = Uint8List(ContainerLayout.superPlainLen);
    sbPlain[0] = sbJson.length >> 8;
    sbPlain[1] = sbJson.length & 0xff;
    sbPlain.setRange(2, 2 + sbJson.length, sbJson);
    final slot = 1 - v.slot;
    final sealed = await CryptoPrimitives.seal(
      v.superKey,
      sbPlain,
      _aadSuper(v.record, slot),
    );
    _writeAt(
      ContainerLayout.recordOffset(v.record) +
          ContainerLayout.superOffsets[slot],
      sealed,
    );
    await _raf.flush();

    // Committed. From here on nothing may throw.
    final old = v.indexExtents;
    v.indexExtents = extents;
    v.gen = gen;
    v.slot = slot;
    CryptoPrimitives.wipe(plain);
    try {
      await _shred(old);
    } catch (_) {
      // The old index stays unreadable without its superblock; its chunks
      // are free and get overwritten by later use.
    }
  }

  // ─── Internals: allocation ──────────────────────────────────────

  /// Picks [n] free chunks for [target], growing the container if needed.
  /// Returned in ascending order; data is written in that order.
  Future<List<int>> _allocate(_OpenVault target, int n) async {
    final root = _live;
    // A decoy opened on its own can't see the real vault, so it stays below
    // its ceiling (or in space it grew itself).
    final constrained = !root.index.topDown;
    while (true) {
      final total = await _raf.length() ~/ ContainerLayout.chunkSize;
      final used = Uint8List(total);
      used[0] = 1;
      for (final v in root.selfAndDescendants) {
        for (final c in v.usedChunks) {
          if (c < total) used[c] = 1;
        }
      }
      for (final c in _reserved) {
        if (c < total) used[c] = 1;
      }

      bool allowed(int c) {
        if (used[c] == 1) return false;
        if (!constrained) return true;
        final ceiling = root.index.ceiling;
        final grown = root.index.grownFrom;
        return c < ceiling || (grown != null && c >= grown);
      }

      final picked = <int>[];
      if (target.index.topDown) {
        for (var c = total - 1; c >= 1 && picked.length < n; c--) {
          if (allowed(c)) picked.add(c);
        }
      } else {
        for (var c = 1; c < total && picked.length < n; c++) {
          if (allowed(c)) picked.add(c);
        }
      }

      if (picked.length == n) {
        picked.sort();
        _reserved.addAll(picked);
        if (identical(target, root)) _rootReserved.addAll(picked);
        // The real vault is about to write below its decoy's ceiling: lower
        // the ceiling *first*, so a crash can never leave the decoy free to
        // overwrite real data.
        if (target == root && root.index.topDown) {
          for (final child in root.children) {
            if (child.index.topDown) continue;
            final low = picked.first;
            final grown = child.index.grownFrom;
            if (low < child.index.ceiling ||
                (grown != null && picked.last >= grown)) {
              final oldCeiling = child.index.ceiling;
              child.index.ceiling = min(oldCeiling, low);
              child.index.grownFrom = null;
              try {
                await _writeIndex(child);
              } catch (_) {
                // Not lowered on disk, so not in memory either: otherwise a
                // retry would write real data below the decoy's stored
                // ceiling with nothing on disk protecting it.
                child.index.ceiling = oldCeiling;
                child.index.grownFrom = grown;
                rethrow;
              }
            }
          }
        }
        return picked;
      }

      // Always grow by whole steps, so the file size says nothing about the
      // size of the import that triggered it.
      final step = _crypto.growChunks;
      final grow = max(1, ((n - picked.length) + step - 1) ~/ step) * step;
      await _fillRandom(
        total * ContainerLayout.chunkSize,
        grow * ContainerLayout.chunkSize,
      );
      await _raf.flush();
      if (constrained && root.index.grownFrom == null) {
        root.index.grownFrom = total;
      }
    }
  }

  // ─── Internals: raw IO ──────────────────────────────────────────

  /// Chunks sealed or opened per native call (16 × 64 KiB = 1 MiB).
  static const int _batch = 16;

  // Container IO is synchronous on purpose. Each call is a sub-millisecond
  // positioned read/write, and every caller already holds [_locked]. Async
  // file calls cost an event-loop round trip each (measured at 15–30 ms on
  // an emulator), which made 64 KiB-at-a-time IO crawl.
  void _writeAt(int offset, List<int> bytes) {
    _raf.setPositionSync(offset);
    _raf.writeFromSync(bytes);
  }

  Future<void> _fillRandom(int offset, int length) =>
      _crypto.bulk.fillRandom(_raf, _container.file, offset, length);

  /// Keeps chunks that were just freed (and are about to be shredded) out
  /// of allocation for the rest of this operation. Without this the index
  /// written on commit could land in them and then be shredded with them,
  /// leaving a vault that no longer opens.
  void _holdUntilShredded(List<Extent> extents) {
    for (final e in extents) {
      _reserved.addAll(e.chunks);
    }
  }

  /// Overwrites chunks with random data so freed space looks like any other
  /// free space and old ciphertext (and old index copies holding file keys)
  /// is gone. Flash wear-levelling means this is best effort at the physical
  /// level; the file keys are discarded either way.
  Future<void> _shred(List<Extent> extents) async {
    for (final e in extents) {
      await _fillRandom(
        ContainerLayout.chunkOffset(e.start),
        e.length * ContainerLayout.chunkSize,
      );
    }
    if (extents.isNotEmpty) await _raf.flush();
  }
}

Uint8List _readAt(RandomAccessFile raf, int offset, int length) {
  raf.setPositionSync(offset);
  final data = raf.readSync(length);
  if (data.length != length) throw VaultCorruptedException('short read');
  return data;
}

/// Reads up to [max] bytes, looping over short reads; fewer only at EOF.
Uint8List _readUpTo(RandomAccessFile raf, int max) {
  final buf = Uint8List(max);
  var got = 0;
  while (got < max) {
    final n = raf.readIntoSync(buf, got, max);
    if (n == 0) break;
    got += n;
  }
  return got == max ? buf : Uint8List.sublistView(buf, 0, got);
}
