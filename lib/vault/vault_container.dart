import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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
  // format. Bytes 64–123 now hold the duress slot; the rest stay filler.

  /// The duress slot: this vault's own key sealed under the duress PIN's
  /// key. Random bytes unless a duress PIN is set.
  static const int duressSlotOffset = 64;
  static const int duressSlotLen = pinSlotLen;

  static const int superPlainLen = 2048;
  static const int superSlotLen = superPlainLen + sealOverhead; // 2076
  static const List<int> superOffsets = [256, 256 + superSlotLen];

  static int recordOffset(int r) => recordsOffset + r * recordSize;
  static int chunkOffset(int c) => c * chunkSize;

  /// Where a copy made to move the container to another install carries its
  /// transfer slot: inside header chunk 0's random tail, so the copy looks
  /// like any container. Never written in the container itself.
  static const int transferSlotOffset = 0x9000;
  static const int transferSlotPlain = 2048;
  static const int transferSlotLen = transferSlotPlain + sealOverhead;

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

  /// Unicode NFC normalisation of PINs and passphrases (identity if null).
  final Future<String> Function(String)? normalize;

  VaultCrypto({
    required this.binding,
    BulkCrypto? bulk,
    this.pinParams = KdfParams.pin,
    this.growChunks = ContainerLayout.defaultGrowChunks,
    this.normalize,
  }) : bulk = bulk ?? defaultBulkCrypto();

  Future<String> normalizePin(String pin) async => normalize == null ? pin : await normalize!(pin);

  /// The key-encryption key for [pin], NFC-normalised first, so the same
  /// passphrase typed on different keyboards gives the same key.
  Future<Uint8List> pinKek(String pin, Uint8List salt) async =>
      _kek(utf8.encode('p:${await normalizePin(pin)}'), salt, pinParams, 'sv/pin-kek');

  /// The key for [pin] exactly as typed: how PINs were used before v2.2.
  Future<Uint8List> legacyPinKek(String pin, Uint8List salt) =>
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

/// Every record but [record], in random order.
List<int> _otherRecords(int record) => [
      for (var r = 0; r < ContainerLayout.recordCount; r++)
        if (r != record) r,
    ]..shuffle(Random.secure());

List<int> _aadPin(int r) => [1, r];
List<int> _aadDuress(int r) => [2, r];
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

  // ─── Moving to another install ──────────────────────────────────

  static const String _transferInfo = 'sv/transfer';

  static Future<Uint8List> _transferKey(Uint8List code, Uint8List salt) =>
      CryptoPrimitives.hkdf(code, salt: salt, info: _transferInfo);

  /// Reads the vaults (record, key) from the transfer slot of a copy made
  /// by [VaultSession.exportForTransfer]. Throws if [code] doesn't fit.
  static Future<List<(int, Uint8List)>> _readTransfer(RandomAccessFile raf, Uint8List code) async {
    final salt = _readAt(raf, 0, ContainerLayout.saltLen);
    final key = await _transferKey(code, salt);
    try {
      final sealed = _readAt(raf, ContainerLayout.transferSlotOffset, ContainerLayout.transferSlotLen);
      final plain = await CryptoPrimitives.tryOpen(key, sealed, utf8.encode(_transferInfo));
      if (plain == null) throw const FormatException('that transfer code does not open this file');
      final len = (plain[0] << 8) | plain[1];
      final j = jsonDecode(utf8.decode(plain.sublist(2, 2 + len))) as Map<String, dynamic>;
      CryptoPrimitives.wipe(plain);
      return [
        for (final v in (j['vaults'] as List).cast<Map<String, dynamic>>())
          (v['r'] as int, Uint8List.fromList(base64Decode(v['k'] as String))),
      ];
    } finally {
      CryptoPrimitives.wipe(key);
    }
  }

  /// How many vaults a moved copy holds (the first is the one it was moved
  /// from, the rest its decoy), or throws if [code] doesn't fit.
  static Future<int> transferVaultCount(File copy, Uint8List code) async {
    final raf = await copy.open();
    try {
      final vaults = await _readTransfer(raf, code);
      for (final (_, vk) in vaults) {
        CryptoPrimitives.wipe(vk);
      }
      return vaults.length;
    } finally {
      await raf.close();
    }
  }

  /// Finishes moving a copy onto this install: each vault's PIN slot is
  /// written again under [pins] (in the order [transferVaultCount] counts
  /// them) and this phone's hardware binding, the transfer slot is erased,
  /// and the copy becomes [destination]. The contents are untouched.
  static Future<void> completeTransfer(
    File copy,
    File destination,
    VaultCrypto crypto,
    Uint8List code,
    List<String> pins,
  ) async {
    final session = await VaultContainer(copy, crypto)._openSession();
    try {
      final vaults = await _readTransfer(session._raf, code);
      if (pins.length != vaults.length) throw ArgumentError('one PIN per vault');
      if (pins.toSet().length != pins.length) throw CredentialInUseException();
      for (var i = 0; i < vaults.length; i++) {
        final (record, vk) = vaults[i];
        // The keys must really open their vaults before anything is written.
        await session._loadVault(record, vk, depth: 0);
      }
      for (var i = 0; i < vaults.length; i++) {
        final (record, vk) = vaults[i];
        final kek = await crypto.pinKek(pins[i], session._salt);
        await session._writePinSlot(record, kek, vk);
        CryptoPrimitives.wipe(kek);
        CryptoPrimitives.wipe(vk);
      }
      await session._fillRandom(ContainerLayout.transferSlotOffset, ContainerLayout.transferSlotLen);
      await session._raf.flush();
      // A duress PIN was bound to the old phone like the PINs: it can't work
      // here, so it goes (and can be set again).
      final kek = await crypto.pinKek(pins.first, session._salt);
      final hit = await session._findPinRecord(kek);
      CryptoPrimitives.wipe(kek);
      if (hit != null) {
        await session._loadRoot(hit.$1, hit.$2);
        await session._locked(() async {
          for (final v in session._live.selfAndDescendants.toList()) {
            if (v.index.extras[VaultSession.duressKey] != true) continue;
            await session._clearDuressSlot(v);
            if (identical(v, session._root)) {
              await session._commit(v);
            } else {
              await session._writeIndex(v);
            }
          }
        });
      }
    } finally {
      await session.close();
    }
    await destination.parent.create(recursive: true);
    await copy.rename(destination.path);
  }

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
    // Built under a temporary name and moved into place only when complete:
    // the app treats an existing container as "set up", and one cut off
    // half-way (before its PIN slot or first index) could never be opened.
    final tmp = File('${file.path}.tmp');
    final raf = await tmp.open(mode: FileMode.write);
    try {
      await crypto.bulk.fillRandom(
        raf,
        tmp,
        0,
        initialChunks * ContainerLayout.chunkSize,
        onProgress: onProgress,
      );
      await raf.flush();
    } finally {
      await raf.close();
    }

    final record = Random.secure().nextInt(ContainerLayout.recordCount);
    final vk = CryptoPrimitives.randomBytes(CryptoPrimitives.keyLen);
    final building = await VaultContainer(tmp, crypto)._openSession();
    try {
      final kek = await crypto.pinKek(pin, building._salt);
      await building._writePinSlot(record, kek, vk);
      CryptoPrimitives.wipe(kek);
      // Set up alone: every other record is its own to give to decoys.
      final root = await _OpenVault.fresh(
        record,
        Uint8List.fromList(vk),
        VaultIndex(ceiling: initialChunks, spares: _otherRecords(record)),
      );
      building._root = root;
      await building._writeIndex(root);
    } catch (_) {
      await building.close();
      try {
        await tmp.delete();
      } catch (_) {}
      CryptoPrimitives.wipe(vk);
      rethrow;
    }
    await building.close();
    await tmp.rename(file.path);

    // Reopen the finished file with the keys we already have (no second
    // PIN derivation).
    final session = await VaultContainer(file, crypto)._openSession();
    try {
      await session._loadRoot(record, vk);
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
      var hit = await session._findPinRecord(kek);
      if (hit == null && await crypto.normalizePin(pin) != pin) {
        // Set up before PINs were normalised, with characters that
        // normalise differently: open it with the PIN as typed, then store
        // it under the normalised form, which every keyboard now gives.
        final legacy = await crypto.legacyPinKek(pin, session._salt);
        try {
          hit = await session._findPinRecord(legacy);
          if (hit != null) await session._writePinSlot(hit.$1, kek, hit.$2);
        } finally {
          CryptoPrimitives.wipe(legacy);
        }
      }
      if (hit == null) {
        // A duress PIN: destroys the vault that set it, opens its decoy.
        final duress = await session._findDuressSlot(kek);
        CryptoPrimitives.wipe(kek);
        if (duress == null || !await session._executeDuress(duress.$1, duress.$2)) {
          await session.close();
          return null;
        }
        return session;
      }
      CryptoPrimitives.wipe(kek);
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

  /// Links to vaults that couldn't be loaded (damaged index or superblocks).
  /// Their chunks are unknown, so while there are any, this vault writes
  /// only into [safe] chunks or space beyond [safeFrom].
  final List<LinkedVault> damaged = [];

  /// Chunks this vault owned at load or allocated since; null when every
  /// linked vault loaded (no restriction).
  Set<int>? safe;
  int safeFrom = 0;

  /// Loaded from a format 1 index: rewritten in format 2 at the next commit.
  bool migrated = false;

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

  /// A lock has been requested: work already queued still runs (a save on
  /// lock must land), but a long import stops at its next batch.
  bool _closing = false;
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

  /// Called with the new commit number after each commit of this vault
  /// (the rollback guard records it).
  void Function(int generation)? onCommitted;

  /// Set at unlock when the container is older than the last commit this
  /// phone recorded for this vault (see RollbackGuard).
  bool rolledBack = false;

  /// This vault's commit number. Internal: not for display.
  int get generation => _r.gen;

  /// Which of the four records this vault is. Internal: not for display.
  int get recordIndex => _r.record;

  /// A key for the rollback guard's slot, derived from this vault's key.
  Future<Uint8List> rollbackKey() =>
      CryptoPrimitives.hkdf(_r.vk, salt: utf8.encode('sv/vault'), info: 'rollback');

  List<IndexEntry> get entries => List.unmodifiable(_r.index.entries);

  bool get hasDecoy => _r.children.isNotEmpty || _r.damaged.isNotEmpty;

  /// The decoy exists but couldn't be read (its index is damaged). The real
  /// vault works normally; the decoy can only be removed and set up again.
  bool get decoyDamaged => _r.damaged.isNotEmpty;

  /// Whether this vault can host a decoy: it has records to give one (a
  /// vault set up alone always has; a decoy has, unless it's three deep).
  bool get canManageDecoy => _r.index.spares.isNotEmpty || hasDecoy;

  /// Whether a duress PIN is set (it opens this vault's decoy and destroys
  /// this vault).
  bool get hasDuressPin => _r.index.extras[duressKey] == true;
  static const String duressKey = 'duress';

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
          abortOnLock: true,
        );
        return _addEntry(meta, chunks, fileKey, length);
      } finally {
        await src.close();
      }
    });
  }

  /// Streams [length] bytes produced by [read] into the vault (a video
  /// decrypted and packed on the fly). [read] is asked for at most the
  /// number of bytes given and returns at least one, in order. Nothing is
  /// written outside the container; a lock stops it like [importFile].
  Future<IndexEntry> importStream(
    int length,
    VaultItem meta,
    Future<Uint8List> Function(int max) read, {
    void Function(double)? onProgress,
  }) {
    return _locked(() async {
      final buf = BytesBuilder(copy: false);
      var produced = 0;
      Future<Uint8List> next(int seq) async {
        final want = min(ContainerLayout.chunkPayload, length - seq * ContainerLayout.chunkPayload);
        while (buf.length < want) {
          final got = await read(max(want - buf.length, 1 << 20));
          if (got.isEmpty) break; // short: _writeChunks refuses it
          produced += got.length;
          if (produced > length) throw StateError('the stream is longer than announced');
          buf.add(got);
        }
        final all = buf.takeBytes();
        if (all.length > want) buf.add(Uint8List.sublistView(all, want));
        return all.length > want ? Uint8List.sublistView(all, 0, want) : all;
      }

      final (chunks, fileKey) = await _writeChunks(meta.id, length, next, onProgress, abortOnLock: true);
      return _addEntry(meta, chunks, fileKey, length);
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
      await _shredAfterCommit(old.extents);
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
    FutureOr<Uint8List> Function(int seq) next,
    void Function(double)? onProgress, {
    bool abortOnLock = false,
  }) async {
    final root = _live;
    final n = max(1, (length / ContainerLayout.chunkPayload).ceil());
    final chunks = await _allocate(root, n);
    final fileKey = CryptoPrimitives.randomBytes(CryptoPrimitives.keyLen);
    for (var start = 0; start < n; start += _batch) {
      // A lock during a long import stops it here rather than keeping every
      // key in memory for minutes; nothing was committed, and the key goes.
      // (Saves and recordings, which are small, are allowed to finish.)
      if (abortOnLock && _closing) {
        CryptoPrimitives.wipe(fileKey);
        throw StateError('vault locked during import');
      }
      final end = min(n, start + _batch);
      final plains = <Uint8List>[];
      final aads = <List<int>>[];
      for (var seq = start; seq < end; seq++) {
        final plain = await next(seq);
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
  Future<void> putExtra(String key, Object? value) => putExtras({key: value});

  /// Sets several settings entries (null removes one) in a single commit:
  /// either all of them are saved or none.
  Future<void> putExtras(Map<String, Object?> values) {
    return _locked(() async {
      final root = _r;
      final before = <String, (bool, Object?)>{
        for (final k in values.keys) k: (root.index.extras.containsKey(k), root.index.extras[k]),
      };
      values.forEach((key, value) {
        if (value == null) {
          root.index.extras.remove(key);
        } else {
          root.index.extras[key] = jsonDecode(jsonEncode(value));
        }
      });
      try {
        await _commit(root);
      } catch (_) {
        before.forEach((key, was) {
          if (was.$1) {
            root.index.extras[key] = was.$2;
          } else {
            root.index.extras.remove(key);
          }
        });
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
      await _shredAfterCommit(entry.extents);
      CryptoPrimitives.wipe(entry.fileKey);
    });
  }

  // ─── Credentials ────────────────────────────────────────────────

  Future<void> changePin(String newPin) => _locked(() => _setPin(_r, newPin));

  // ─── Decoy vault ────────────────────────────────────────────────

  /// Creates a decoy vault, opened with [pin], in a record this vault has
  /// to give (see [VaultIndex.spares]); the decoy gets the rest, so it can
  /// host one of its own. Any vault can host a decoy, a decoy too. The host
  /// keeps the decoy's key so it never overwrites the decoy's data; the
  /// decoy knows nothing about its host.
  ///
  /// The host's files move to the top of its space first, leaving the
  /// bottom to the decoy ([onProgress] follows that move).
  Future<void> createDecoy({required String pin, void Function(double)? onProgress}) {
    return _locked(() async {
      final root = _r;
      if (root.children.isNotEmpty || root.damaged.isNotEmpty) throw StateError('decoy already exists');
      if (root.index.spares.isEmpty) throw NoFreeRecordException();
      final kek = await _crypto.pinKek(pin, _salt);
      try {
        if (await _pinInUse(kek)) throw CredentialInUseException();
        final record = root.index.spares.first;
        final vk = CryptoPrimitives.randomBytes(CryptoPrimitives.keyLen);
        final moved = await _moveToTop(root, onProgress);
        final decoy = await _OpenVault.fresh(
          record,
          vk,
          VaultIndex(
            ceiling: _childCeiling(root, await _lowestChunkOf(root)),
            spares: root.index.spares.sublist(1),
          ),
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
          moved.undo();
          rethrow;
        }
        // The old copies of the moved files are free now: overwrite them.
        await _shredAfterCommit(extentsFromChunks(moved.from));
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
      if (hasDecoy) throw StateError('this vault has a real decoy');
      if (shown) {
        final kek = await _crypto.pinKek(pin, _salt);
        try {
          final hit = await _findPinRecord(kek);
          if (hit != null) CryptoPrimitives.wipe(hit.$2);
          if (hit != null && hit.$1 == root.record) throw CredentialInUseException();
        } finally {
          CryptoPrimitives.wipe(kek);
        }
      }
      root.index.extras[standInDecoyKey] = shown;
      if (!shown) {
        root.index.extras.remove(standInDecoyKey);
        root.index.extras.remove(duressKey);
      }
      await _commit(root);
    });
  }

  static const String standInDecoyKey = 'decoy.shown';

  /// Whether this vault shows a decoy in Settings: a real one it hosts, or
  /// the stand-in of a vault with no record left to give one.
  bool get showsDecoy => hasDecoy || _r.index.extras[standInDecoyKey] == true;

  Future<void> changeDecoyPin(String pin) =>
      _locked(() => _setPin(_decoy, pin));

  /// Deletes the decoy vault and shreds everything it stored.
  /// Removes this vault's decoy, with any decoy inside it.
  Future<void> removeDecoy() {
    return _locked(() async {
      final root = _r;
      if (root.children.isEmpty && root.damaged.isNotEmpty) return _removeDamagedDecoy(root);
      final decoy = _decoy;
      final chunks =
          decoy.selfAndDescendants.expand((v) => v.usedChunks).toList()..sort();
      // The duress PIN opens this decoy: it goes with it.
      if (hasDuressPin) await _clearDuressSlot(root);
      // First make every PIN below this vault stop working, so a crash at
      // any later point can't leave an openable vault this one no longer
      // protects. Superblocks stay until the unlink is committed (this vault
      // still needs them to load the decoy until then).
      await _disableSpareRecords(root);
      root.children.remove(decoy);
      root.index.links.removeWhere((l) => l.record == decoy.record);
      _holdUntilShredded(extentsFromChunks(chunks));
      await _commit(root);
      await _wipeSpareRecords(root);
      await _shredAfterCommit(extentsFromChunks(chunks));
      decoy.wipe();
    });
  }

  /// Every record this vault gave away (to its decoy and the decoy's own):
  /// the PIN and duress slots, so none of them opens any more.
  Future<void> _disableSpareRecords(_OpenVault v) async {
    for (final r in v.index.spares) {
      await _fillRandom(ContainerLayout.recordOffset(r) + ContainerLayout.pinSlotOffset, ContainerLayout.pinSlotLen);
      await _fillRandom(ContainerLayout.recordOffset(r) + ContainerLayout.duressSlotOffset, ContainerLayout.duressSlotLen);
    }
    await _raf.flush();
  }

  /// ... and then the whole records, once nothing needs their superblocks.
  Future<void> _wipeSpareRecords(_OpenVault v) async {
    for (final r in v.index.spares) {
      try {
        await _fillRandom(ContainerLayout.recordOffset(r), ContainerLayout.recordSize);
      } catch (_) {}
    }
  }

  // ─── Duress PIN ─────────────────────────────────────────────────

  /// Sets (or replaces) the duress PIN. Entered on the lock screen it opens
  /// this vault's decoy, and this vault is destroyed first: its PIN slot,
  /// superblocks and index (with every file key) are overwritten, so
  /// nothing in it can be opened again, with any PIN or code. The decoy
  /// then takes over this vault's space. Needs a decoy.
  Future<void> setDuressPin(String pin) {
    return _locked(() async {
      final root = _r;
      // A vault showing the stand-in decoy shows a duress PIN too (so the
      // two can't be told apart), but its slot stays random: there's no
      // decoy for it to open.
      final standIn = !hasDecoy && root.index.extras[standInDecoyKey] == true;
      if (!standIn) _decoy; // throws if there's none
      final kek = await _crypto.pinKek(pin, _salt);
      try {
        if (await _pinInUse(kek, ownDuress: root.record)) throw CredentialInUseException();
        if (!standIn) {
          final sealed = await CryptoPrimitives.seal(kek, root.vk, _aadDuress(root.record));
          _writeAt(ContainerLayout.recordOffset(root.record) + ContainerLayout.duressSlotOffset, sealed);
          await _raf.flush();
        }
      } finally {
        CryptoPrimitives.wipe(kek);
      }
      root.index.extras[duressKey] = true;
      await _commit(root);
    });
  }

  Future<void> removeDuressPin() {
    return _locked(() async {
      await _clearDuressSlot(_r);
      await _commit(_r);
    });
  }

  Future<void> _clearDuressSlot(_OpenVault v) async {
    await _fillRandom(ContainerLayout.recordOffset(v.record) + ContainerLayout.duressSlotOffset, ContainerLayout.duressSlotLen);
    await _raf.flush();
    v.index.extras.remove(duressKey);
  }

  /// The record whose duress slot opens with [kek], and that vault's key.
  /// Tries every record, like [_findPinRecord].
  Future<(int, Uint8List)?> _findDuressSlot(Uint8List kek) async {
    (int, Uint8List)? hit;
    for (var r = 0; r < ContainerLayout.recordCount; r++) {
      final raw = _readAt(
        _raf,
        ContainerLayout.recordOffset(r) + ContainerLayout.duressSlotOffset,
        ContainerLayout.duressSlotLen,
      );
      final vk = await CryptoPrimitives.tryOpen(kek, raw, _aadDuress(r));
      if (vk != null && hit == null) hit = (r, vk);
    }
    return hit;
  }

  /// The duress PIN of [victim] was entered: destroy it and open its decoy
  /// in its place, with all of its space. False (nothing changed) if it has
  /// no decoy that loads.
  Future<bool> _executeDuress(int victim, Uint8List vk) {
    return _locked(() async {
      final h = await _loadVault(victim, vk, depth: 0);
      CryptoPrimitives.wipe(vk);
      if (h.children.isEmpty) {
        h.wipe();
        return false;
      }
      final d = h.children.first;
      final total = await _raf.length() ~/ ContainerLayout.chunkSize;
      // The space the victim could use: below its ceiling, or the whole
      // file if it grew the file right from its ceiling.
      final g = h.index.grownFrom;
      final region = g != null && g <= h.index.ceiling ? total : h.index.ceiling;
      // Destroy first: the record (PIN, duress, superblocks), then the index
      // (every file key). The files' chunks are now noise, free for reuse.
      await _fillRandom(ContainerLayout.recordOffset(victim), ContainerLayout.recordSize);
      await _raf.flush();
      await _shredAfterCommit(h.indexExtents);
      h.children.clear();
      h.wipe();
      _root = d;
      d.index.ceiling = max(d.index.ceiling, region);
      d.index.grownFrom = null;
      // The victim's record is free now too.
      d.index.spares = [...d.index.spares, victim]..shuffle(Random.secure());
      await _commit(d);
      return true;
    });
  }

  /// Whether [kek] opens a PIN slot, or a duress slot other than
  /// [ownDuress]'s (a new PIN must open nothing else).
  Future<bool> _pinInUse(Uint8List kek, {int? ownDuress}) async {
    final hit = await _findPinRecord(kek);
    if (hit != null) {
      CryptoPrimitives.wipe(hit.$2);
      return true;
    }
    final d = await _findDuressSlot(kek);
    if (d != null) {
      CryptoPrimitives.wipe(d.$2);
      if (d.$1 != ownDuress) return true;
    }
    return false;
  }

  /// Moves [v]'s files to the highest chunks of its space (free ones, or
  /// its own already there), so the decoy it's about to host gets the
  /// bottom. Writes only free chunks, and keeps the old copies reserved:
  /// until [v]'s next commit its index on disk still points at them, so a
  /// crash loses nothing. [undo] restores the in-memory index if that
  /// commit fails.
  Future<({List<int> from, void Function() undo})> _moveToTop(_OpenVault v, void Function(double)? onProgress) async {
    final own = <int>[
      for (final e in v.index.entries)
        for (final x in e.extents) ...x.chunks,
    ];
    if (own.isEmpty) return (from: const <int>[], undo: () {});
    final ownSet = own.toSet();
    while (true) {
      final total = await _raf.length() ~/ ContainerLayout.chunkSize;
      final busy = <int>{0, ..._reserved};
      for (final w in v.selfAndDescendants.skip(1)) {
        busy.addAll(w.usedChunks);
      }
      for (final x in v.indexExtents) {
        busy.addAll(x.chunks);
      }
      final ceiling = v.index.ceiling;
      final g = v.index.grownFrom;
      final safe = v.safe;
      bool mayUse(int c) =>
          !busy.contains(c) &&
          (c < ceiling || (g != null && c >= g)) &&
          (safe == null || c >= v.safeFrom || safe.contains(c));
      final desired = <int>[];
      for (var c = total - 1; c >= 1 && desired.length < own.length; c--) {
        if (mayUse(c)) desired.add(c);
      }
      if (desired.length < own.length) {
        final step = _crypto.growChunks;
        final grow = max(1, ((own.length - desired.length) + step - 1) ~/ step) * step;
        await _fillRandom(total * ContainerLayout.chunkSize, grow * ContainerLayout.chunkSize);
        await _raf.flush();
        v.index.grownFrom ??= total;
        continue;
      }
      final desiredSet = desired.toSet();
      final targets = desired.where((c) => !ownSet.contains(c)).toList()..sort();
      final movers = own.where((c) => !desiredSet.contains(c)).toList()..sort();
      final map = <int, int>{
        for (var i = 0; i < movers.length; i++) movers[i]: targets[i],
      };
      for (var i = 0; i < movers.length; i++) {
        final bytes = _readAt(_raf, ContainerLayout.chunkOffset(movers[i]), ContainerLayout.chunkSize);
        _writeAt(ContainerLayout.chunkOffset(map[movers[i]]!), bytes);
        if (i % 64 == 63) {
          await _raf.flush();
          onProgress?.call(i / movers.length);
        }
      }
      await _raf.flush();
      onProgress?.call(1);
      _reserved.addAll(targets);
      _rootReserved.addAll(targets);
      _holdUntilShredded(extentsFromChunks(movers));
      final before = List.of(v.index.entries);
      for (var k = 0; k < v.index.entries.length; k++) {
        final e = v.index.entries[k];
        if (e.extents.isEmpty) continue;
        final chunks = [for (final x in e.extents) ...x.chunks].map((c) => map[c] ?? c).toList();
        v.index.entries[k] = IndexEntry(
          item: e.item,
          fileKey: e.fileKey,
          extents: extentsFromChunks(chunks),
          byteLength: e.byteLength,
        );
      }
      return (
        from: movers,
        undo: () => v.index.entries
          ..clear()
          ..addAll(before),
      );
    }
  }

  /// A decoy whose index can't be read: its PIN stops working and the link
  /// goes. Its chunks can't be told apart, so they aren't shredded; they're
  /// encrypted under a key that's forgotten, and get reused over time.
  Future<void> _removeDamagedDecoy(_OpenVault root) async {
    final link = root.damaged.first;
    if (hasDuressPin) await _clearDuressSlot(root);
    // Any decoy inside it can't be seen either: all the records this vault
    // gave away go.
    if (!root.index.spares.contains(link.record)) root.index.spares.add(link.record);
    await _disableSpareRecords(root);
    root.index.links.removeWhere((l) => l.record == link.record);
    root.damaged.remove(link);
    await _commit(root);
    await _wipeSpareRecords(root);
    CryptoPrimitives.wipe(link.vaultKey);
  }

  _OpenVault get _decoy {
    final root = _live;
    if (root.children.isEmpty) {
      if (root.damaged.isNotEmpty) throw VaultCorruptedException('the decoy is damaged; remove it and set it up again');
      throw StateError('no decoy');
    }
    return root.children.first;
  }

  /// Writes a copy of the whole container for moving it to another phone or
  /// app: [writeCopy] copies the container file, putting [slot] at
  /// [slotOffset] in the copy. The slot holds this vault's key and its
  /// decoy's, sealed under the returned transfer code; another install can't
  /// use the PIN slots (they're bound to this phone's hardware), so it opens
  /// them with the code instead and sets PINs of its own. Nothing in this
  /// container changes, and no other write happens during the copy.
  ///
  /// Anyone with the copy and the code can open these vaults without a PIN:
  /// the code is shown once and never stored.
  Future<Uint8List> exportForTransfer(Future<void> Function(int slotOffset, Uint8List slot) writeCopy) {
    return _locked(() async {
      final root = _r;
      final code = CryptoPrimitives.randomBytes(16);
      final vaults = [
        {'r': root.record, 'k': base64Encode(root.vk)},
        for (final c in root.selfAndDescendants.skip(1)) {'r': c.record, 'k': base64Encode(c.vk)},
      ];
      final json = utf8.encode(jsonEncode({'v': 1, 'vaults': vaults}));
      final plain = Uint8List(ContainerLayout.transferSlotPlain);
      plain[0] = json.length >> 8;
      plain[1] = json.length & 0xff;
      plain.setRange(2, 2 + json.length, json);
      final key = await VaultContainer._transferKey(code, _salt);
      final sealed = await CryptoPrimitives.seal(key, plain, utf8.encode(VaultContainer._transferInfo));
      CryptoPrimitives.wipe(key);
      CryptoPrimitives.wipe(plain);
      await _raf.flush();
      await writeCopy(ContainerLayout.transferSlotOffset, sealed);
      return code;
    });
  }

  /// Tests: each loaded vault's record, index chunks and all chunks.
  Map<int, ({List<int> index, List<int> all})> get debugChunks => {
        for (final v in _r.selfAndDescendants)
          v.record: (index: v.indexExtents.expand((e) => e.chunks).toList(), all: v.usedChunks.toList()),
      };

  /// Tests: the vault's allocation restriction while a decoy is damaged.
  ({Set<int>? safe, int safeFrom}) get debugSafeArea => (safe: _r.safe, safeFrom: _r.safeFrom);

  /// Locks the vault: wipes keys from memory and closes the file.
  Future<void> close() async {
    if (_closing || _closed) return;
    _closing = true;
    // Everything queued so far finishes first (saves included). The vault
    // service already handed out its last reference to this session, so
    // nothing new arrives except reads from a viewer that is closing, and
    // those are refused once [_closed] is set below.
    try {
      await _tail;
    } catch (_) {}
    _closed = true;
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
      final duress = await _findDuressSlot(kek);
      if (duress != null) {
        CryptoPrimitives.wipe(duress.$2);
        throw CredentialInUseException();
      }
      await _writePinSlot(v.record, kek, v.vk);
    } finally {
      CryptoPrimitives.wipe(kek);
    }
  }

  // ─── Internals: index load / commit ─────────────────────────────

  Future<void> _loadRoot(int record, Uint8List vk) async {
    final root = await _loadVault(record, vk, depth: 0);
    _root = root;
    // Keep the decoys' ceilings in step (e.g. after this vault freed space,
    // or a decoy grew the container on its own), and rewrite indexes still
    // in format 1.
    await _locked(() async {
      if (_takeOverGrownSpace(root) || root.migrated) {
        await _commit(root);
      } else {
        await _syncDescendants(root);
      }
    });
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
      VaultIndex(ceiling: 0),
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
    if (v.index.version == 1) {
      // Format 1 marked the real vault ("t"). It was set up alone and used
      // the whole file: it keeps all of it, and every other record is its
      // own to give. A format 1 decoy keeps its ceiling and has none.
      if (v.index.legacyRealVault == true) {
        v.index.ceiling = await _raf.length() ~/ ContainerLayout.chunkSize;
        v.index.grownFrom = null;
        v.index.spares = _otherRecords(record);
      }
      v.index.version = 2;
      v.migrated = true;
    }
    for (final link in v.index.links) {
      try {
        v.children.add(
          await _loadVault(
            link.record,
            Uint8List.fromList(link.vaultKey),
            depth: depth + 1,
          ),
        );
      } catch (_) {
        // A damaged decoy must not lock its owner out of its own data.
        v.damaged.add(link);
      }
    }
    if (v.damaged.isNotEmpty) {
      v.safe = v.usedChunks.toSet();
      v.safeFrom = await _raf.length() ~/ ContainerLayout.chunkSize;
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
    if (identical(v, _root)) {
      try {
        onCommitted?.call(v.gen);
      } catch (_) {}
    }
    v.migrated = false;
    if (identical(v, _root)) {
      try {
        await _syncDescendants(v);
      } catch (_) {
        // Lowering a ceiling happens before any data is written (in
        // _allocate); here they only go up, so leaving them is safe.
      }
    }
  }

  /// The ceiling for [v]'s decoy: below [v]'s lowest chunk [low], and inside
  /// [v]'s own space, which may have a gap belonging to vaults above [v].
  int _childCeiling(_OpenVault v, int low) {
    final g = v.index.grownFrom;
    if (g != null && g <= v.index.ceiling) return low; // no gap
    return min(low, v.index.ceiling);
  }

  /// Down the chain of decoys below [root]: each one's ceiling becomes the
  /// lowest chunk of any vault above it (inside their space), and the space
  /// it grew on its own is no longer its alone.
  Future<void> _syncDescendants(_OpenVault root) async {
    var limit = _childCeiling(root, await _lowestChunkOf(root));
    var parent = root;
    while (parent.children.isNotEmpty) {
      final child = parent.children.first;
      if (child.index.ceiling != limit || child.index.grownFrom != null || child.migrated) {
        child.index.ceiling = limit;
        child.index.grownFrom = null;
        await _writeIndex(child);
        child.migrated = false;
      }
      limit = min(limit, await _lowestChunkOf(child));
      parent = child;
    }
  }

  /// A decoy below [root] grew the file on its own: from there to the end
  /// there are only its chunks (known here) and free ones, since any vault
  /// above it that used some would have taken that space back first (see
  /// [_allocate]). So [root] may use that space too. True if [root]'s index
  /// changed.
  bool _takeOverGrownSpace(_OpenVault root) {
    int? grown;
    for (final v in root.selfAndDescendants.skip(1)) {
      final g = v.index.grownFrom;
      if (g != null && (grown == null || g < grown)) grown = g;
    }
    final mine = root.index.grownFrom;
    if (grown == null || (mine != null && mine <= grown)) return false;
    root.index.grownFrom = grown;
    return true;
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
    // Every vault keeps to its own space: below its ceiling, or in space it
    // grew itself. Any vault may be another's decoy without knowing it.
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

      final safe = root.safe;
      bool allowed(int c) {
        if (used[c] == 1) return false;
        // A linked vault that couldn't be read may own any chunk this vault
        // didn't own already: only those, or fresh space, are safe.
        if (safe != null && c < root.safeFrom && !safe.contains(c)) return false;
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
        safe?.addAll(picked);
        _reserved.addAll(picked);
        if (identical(target, root)) _rootReserved.addAll(picked);
        // About to write inside the space of a decoy below [target]: lower
        // its ceiling *first*, so a crash can never leave the decoy free to
        // overwrite these chunks.
        for (final child in target.selfAndDescendants.skip(1).toList()) {
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
      // The new space is this vault's own (see VaultIndex.grownFrom).
      root.index.grownFrom ??= total;
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

  /// [_shred] for chunks freed by a change that is already committed: a
  /// failure here mustn't make a finished change look failed.
  Future<void> _shredAfterCommit(List<Extent> extents) async {
    try {
      await _shred(extents);
    } catch (_) {}
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
