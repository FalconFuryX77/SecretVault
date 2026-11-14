import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../models/gesture.dart';
import '../models/vault_item.dart';
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
///   * a gesture slot  – a biometric-keystore blob sealed under the
///                       gesture-derived key
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

  static const int bioSlotOffset = 64;
  static const int bioPlainLen = 128;
  static const int bioSlotLen = bioPlainLen + sealOverhead; // 156

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
  String toString() => 'That PIN or gesture is already used by another vault.';
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
  final BiometricKeystore biometrics;
  final KdfParams pinParams;
  final KdfParams gestureParams;
  final int growChunks;

  VaultCrypto({
    required this.binding,
    required this.biometrics,
    this.pinParams = KdfParams.pin,
    this.gestureParams = KdfParams.gesture,
    this.growChunks = ContainerLayout.defaultGrowChunks,
  });

  Future<Uint8List> pinKek(String pin, Uint8List salt) =>
      _kek(utf8.encode('p:$pin'), salt, pinParams, 'sv/pin-kek');

  Future<Uint8List> gestureKek(List<Gesture> gestures, Uint8List salt) => _kek(
    utf8.encode('g:${gestures.map((g) => g.name).join(',')}'),
    salt,
    gestureParams,
    'sv/gesture-kek',
  );

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
List<int> _aadBio(int r) => [2, r];
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

/// Entry point: create a container, or unlock one with a PIN or gesture.
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
      await _writeRandom(
        raf,
        0,
        initialChunks * ContainerLayout.chunkSize,
        onProgress: onProgress,
      );
      await raf.flush();
    } finally {
      await raf.close();
    }

    await crypto.biometrics.ensureSlots(ContainerLayout.recordCount);

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

  /// Checks the gesture against every record's gesture slot. On a match,
  /// asks for the biometric that unlocks that vault's key.
  /// Returns null if the gesture matches nothing or biometrics fail.
  Future<VaultSession?> unlockWithGesture(
    List<Gesture> gestures, {
    required String reason,
  }) async {
    final session = await _openSession();
    try {
      final kek = await crypto.gestureKek(gestures, session._salt);
      final hit = await session._findBioRecord(kek);
      CryptoPrimitives.wipe(kek);
      if (hit == null) {
        await session.close();
        return null;
      }
      final vk = await crypto.biometrics.unwrap(hit.$1, hit.$2, reason: reason);
      if (vk == null || vk.length != CryptoPrimitives.keyLen) {
        await session.close();
        return null;
      }
      await session._loadRoot(hit.$1, vk);
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  /// Whether a gesture matches any vault, without prompting for biometrics.
  Future<bool> gestureMatchesAnyVault(List<Gesture> gestures) async {
    final session = await _openSession();
    try {
      final kek = await crypto.gestureKek(gestures, session._salt);
      final hit = await session._findBioRecord(kek);
      CryptoPrimitives.wipe(kek);
      return hit != null;
    } finally {
      await session.close();
    }
  }

  Future<VaultSession> _openSession() async {
    final raf = await file.open(mode: FileMode.append);
    final salt = await _readAt(raf, 0, ContainerLayout.saltLen);
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
      final root = _r;
      final length = await source.length();
      final n = max(1, (length / ContainerLayout.chunkPayload).ceil());
      final chunks = await _allocate(root, n);
      final fileKey = CryptoPrimitives.randomBytes(CryptoPrimitives.keyLen);
      final src = await source.open();
      try {
        final buf = Uint8List(ContainerLayout.chunkPayload);
        for (var seq = 0; seq < n; seq++) {
          final read = await src.readInto(buf);
          final last = seq == n - 1;
          final sealed = await CryptoPrimitives.seal(
            fileKey,
            Uint8List.sublistView(buf, 0, read),
            _aadFile(meta.id, seq, last),
          );
          await _writeChunk(chunks[seq], sealed);
          onProgress?.call((seq + 1) / n);
        }
      } finally {
        await src.close();
      }
      await _raf.flush();
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
    });
  }

  /// Decrypts a stored file chunk by chunk. Throws [TamperedDataException]
  /// if any chunk was altered, swapped, reordered or truncated.
  Stream<Uint8List> read(IndexEntry entry) async* {
    final key = entry.fileKey;
    if (key == null) return;
    final chunks = entry.extents.expand((e) => e.chunks).toList();
    for (var seq = 0; seq < chunks.length; seq++) {
      final last = seq == chunks.length - 1;
      final plainLen = last
          ? entry.byteLength - seq * ContainerLayout.chunkPayload
          : ContainerLayout.chunkPayload;
      if (plainLen < 0 || plainLen > ContainerLayout.chunkPayload) {
        throw TamperedDataException('index length mismatch');
      }
      final sealed = await _locked(
        () => _readAt(
          _raf,
          ContainerLayout.chunkOffset(chunks[seq]),
          plainLen + ContainerLayout.sealOverhead,
        ),
      );
      yield await CryptoPrimitives.open(
        key,
        sealed,
        _aadFile(entry.item.id, seq, last),
      );
    }
  }

  Future<Uint8List> readAll(IndexEntry entry) async {
    final out = BytesBuilder(copy: false);
    await for (final part in read(entry)) {
      out.add(part);
    }
    return out.takeBytes();
  }

  Future<void> exportTo(IndexEntry entry, File destination) async {
    final sink = destination.openWrite();
    try {
      await for (final part in read(entry)) {
        sink.add(part);
      }
      await sink.flush();
    } finally {
      await sink.close();
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
      await _commit(root);
      await _shred(entry.extents);
      CryptoPrimitives.wipe(entry.fileKey);
    });
  }

  // ─── Credentials ────────────────────────────────────────────────

  Future<void> changePin(String newPin) => _locked(() => _setPin(_r, newPin));

  /// Enrolls a motion gesture for this vault. Prompts for a biometric.
  /// Returns false if the user cancels the prompt.
  Future<bool> enrollGesture(
    List<Gesture> gestures, {
    required String reason,
  }) => _locked(() => _setGesture(_r, gestures, reason));

  Future<void> removeGesture() => _locked(() async {
    await _writeRandom(
      _raf,
      ContainerLayout.recordOffset(_r.record) + ContainerLayout.bioSlotOffset,
      ContainerLayout.bioSlotLen,
    );
    await _raf.flush();
  });

  // ─── Decoy vault ────────────────────────────────────────────────

  /// Creates a decoy vault in a free record, opened with [pin] (and
  /// optionally a gesture). The real vault keeps the decoy's key so it never
  /// overwrites the decoy's data; the decoy knows nothing about the real one.
  Future<void> createDecoy({required String pin}) {
    return _locked(() async {
      final root = _r;
      if (!root.index.topDown) {
        throw StateError('only the real vault can own a decoy');
      }
      if (root.children.isNotEmpty) throw StateError('decoy already exists');
      final kek = await _crypto.pinKek(pin, _salt);
      try {
        if (await _findPinRecord(kek) != null) throw CredentialInUseException();
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
        await _writeIndex(decoy);
        await _writePinSlot(record, kek, vk);
        root.children.add(decoy);
        root.index.links.add(LinkedVault(record, Uint8List.fromList(vk)));
        await _commit(root);
      } finally {
        CryptoPrimitives.wipe(kek);
      }
    });
  }

  Future<void> changeDecoyPin(String pin) =>
      _locked(() => _setPin(_decoy, pin));

  Future<bool> enrollDecoyGesture(
    List<Gesture> gestures, {
    required String reason,
  }) => _locked(() => _setGesture(_decoy, gestures, reason));

  /// Deletes the decoy vault and shreds everything it stored.
  Future<void> removeDecoy() {
    return _locked(() async {
      final root = _r;
      final decoy = _decoy;
      final chunks =
          decoy.selfAndDescendants.expand((v) => v.usedChunks).toList()..sort();
      root.children.remove(decoy);
      root.index.links.removeWhere((l) => l.record == decoy.record);
      await _commit(root);
      await _writeRandom(
        _raf,
        ContainerLayout.recordOffset(decoy.record),
        ContainerLayout.recordSize,
      );
      await _shred(extentsFromChunks(chunks));
      decoy.wipe();
    });
  }

  _OpenVault get _decoy {
    final root = _r;
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
      final slot = await _readAt(
        _raf,
        ContainerLayout.recordOffset(r) + ContainerLayout.pinSlotOffset,
        ContainerLayout.pinSlotLen,
      );
      final vk = await CryptoPrimitives.tryOpen(kek, slot, _aadPin(r));
      if (vk != null && hit == null) hit = (r, vk);
    }
    return hit;
  }

  Future<(int, Uint8List)?> _findBioRecord(Uint8List kek) async {
    (int, Uint8List)? hit;
    for (var r = 0; r < ContainerLayout.recordCount; r++) {
      final slot = await _readAt(
        _raf,
        ContainerLayout.recordOffset(r) + ContainerLayout.bioSlotOffset,
        ContainerLayout.bioSlotLen,
      );
      final plain = await CryptoPrimitives.tryOpen(kek, slot, _aadBio(r));
      if (plain != null && hit == null) {
        final len = (plain[0] << 8) | plain[1];
        if (len > 0 && len <= ContainerLayout.bioPlainLen - 2) {
          hit = (r, Uint8List.fromList(plain.sublist(2, 2 + len)));
        }
      }
    }
    return hit;
  }

  Future<void> _writePinSlot(int record, Uint8List kek, Uint8List vk) async {
    final sealed = await CryptoPrimitives.seal(kek, vk, _aadPin(record));
    await _writeAt(
      ContainerLayout.recordOffset(record) + ContainerLayout.pinSlotOffset,
      sealed,
    );
    await _raf.flush();
  }

  Future<void> _setPin(_OpenVault v, String pin) async {
    final kek = await _crypto.pinKek(pin, _salt);
    try {
      final hit = await _findPinRecord(kek);
      if (hit != null && hit.$1 != v.record) throw CredentialInUseException();
      await _writePinSlot(v.record, kek, v.vk);
    } finally {
      CryptoPrimitives.wipe(kek);
    }
  }

  Future<bool> _setGesture(
    _OpenVault v,
    List<Gesture> gestures,
    String reason,
  ) async {
    final kek = await _crypto.gestureKek(gestures, _salt);
    try {
      final hit = await _findBioRecord(kek);
      if (hit != null && hit.$1 != v.record) throw CredentialInUseException();
      final blob = await _crypto.biometrics.wrap(
        v.record,
        v.vk,
        reason: reason,
      );
      if (blob == null) return false;
      if (blob.length > ContainerLayout.bioPlainLen - 2) {
        throw StateError('keystore blob too large');
      }
      final plain = CryptoPrimitives.randomBytes(ContainerLayout.bioPlainLen);
      plain[0] = blob.length >> 8;
      plain[1] = blob.length & 0xff;
      plain.setRange(2, 2 + blob.length, blob);
      final sealed = await CryptoPrimitives.seal(kek, plain, _aadBio(v.record));
      await _writeAt(
        ContainerLayout.recordOffset(v.record) + ContainerLayout.bioSlotOffset,
        sealed,
      );
      await _raf.flush();
      return true;
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
      final raw = await _readAt(
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
    for (var seq = 0; seq < chunks.length; seq++) {
      final last = seq == chunks.length - 1;
      final plainLen = last
          ? byteLen - seq * ContainerLayout.chunkPayload
          : ContainerLayout.chunkPayload;
      final sealed = await _readAt(
        _raf,
        ContainerLayout.chunkOffset(chunks[seq]),
        plainLen + ContainerLayout.sealOverhead,
      );
      out.add(
        await CryptoPrimitives.open(
          v.indexKey,
          sealed,
          _aadIndex(v.gen, seq, last),
        ),
      );
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
  Future<void> _commit(_OpenVault v) async {
    await _writeIndex(v);
    if (v.index.topDown) await _syncChildCeilings(v);
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

  /// The lowest chunk [v] uses (or the container end if it uses none).
  Future<int> _lowestChunkOf(_OpenVault v) async {
    var low = await _raf.length() ~/ ContainerLayout.chunkSize;
    for (final c in v.usedChunks) {
      if (c < low) low = c;
    }
    for (final c in _reserved) {
      if (c < low) low = c;
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
    for (var seq = 0; seq < n; seq++) {
      final start = seq * ContainerLayout.chunkPayload;
      final end = min(plain.length, start + ContainerLayout.chunkPayload);
      final sealed = await CryptoPrimitives.seal(
        v.indexKey,
        Uint8List.sublistView(plain, start, end),
        _aadIndex(gen, seq, seq == n - 1),
      );
      await _writeChunk(chunks[seq], sealed);
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
    await _writeAt(
      ContainerLayout.recordOffset(v.record) +
          ContainerLayout.superOffsets[slot],
      sealed,
    );
    await _raf.flush();

    final old = v.indexExtents;
    v.indexExtents = extents;
    v.gen = gen;
    v.slot = slot;
    CryptoPrimitives.wipe(plain);
    await _shred(old);
  }

  // ─── Internals: allocation ──────────────────────────────────────

  /// Picks [n] free chunks for [target], growing the container if needed.
  /// Returned in ascending order; data is written in that order.
  Future<List<int>> _allocate(_OpenVault target, int n) async {
    final root = _r;
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
              child.index.ceiling = min(child.index.ceiling, low);
              child.index.grownFrom = null;
              await _writeIndex(child);
            }
          }
        }
        return picked;
      }

      final grow = max(_crypto.growChunks, n - picked.length);
      await _writeRandom(
        _raf,
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

  Future<void> _writeChunk(int chunk, Uint8List sealed) async {
    final full = Uint8List(ContainerLayout.chunkSize);
    full.setRange(0, sealed.length, sealed);
    if (sealed.length < full.length) {
      final pad = await CryptoPrimitives.randomFill(
        full.length - sealed.length,
      );
      full.setRange(sealed.length, full.length, pad);
    }
    await _writeAt(ContainerLayout.chunkOffset(chunk), full);
  }

  Future<void> _writeAt(int offset, List<int> bytes) async {
    await _raf.setPosition(offset);
    await _raf.writeFrom(bytes);
  }

  /// Overwrites chunks with random data so freed space looks like any other
  /// free space and old ciphertext (and old index copies holding file keys)
  /// is gone. Flash wear-levelling means this is best effort at the physical
  /// level; the file keys are discarded either way.
  Future<void> _shred(List<Extent> extents) async {
    for (final e in extents) {
      await _writeRandom(
        _raf,
        ContainerLayout.chunkOffset(e.start),
        e.length * ContainerLayout.chunkSize,
      );
    }
    if (extents.isNotEmpty) await _raf.flush();
  }
}

Future<Uint8List> _readAt(RandomAccessFile raf, int offset, int length) async {
  await raf.setPosition(offset);
  final data = await raf.read(length);
  if (data.length != length) throw VaultCorruptedException('short read');
  return data;
}

Future<void> _writeRandom(
  RandomAccessFile raf,
  int offset,
  int length, {
  void Function(double)? onProgress,
}) async {
  const step = 1024 * 1024;
  var done = 0;
  await raf.setPosition(offset);
  while (done < length) {
    final n = min(step, length - done);
    await raf.writeFrom(await CryptoPrimitives.randomFill(n));
    done += n;
    onProgress?.call(done / length);
  }
}
