import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'chunker.dart';
import 'crypto.dart';
import 'keys.dart';
import 'log.dart';
import 'piece.dart';
import 'source.dart';

/// One version of one file. Sealed under K_manifest and stored as a piece.
class Manifest {
  final String file;
  final String version;
  final String? parent;
  final Map<String, dynamic> meta;
  final int size;
  final String mac;
  final List<(String, int)> pieces;

  /// For very large files: the piece list is stored in separate manifest
  /// pieces (id, number of pieces in it) instead of [pieces], so no single
  /// manifest goes over the server's piece size limit.
  final List<(String, int)> parts;

  Manifest({
    required this.file,
    required this.version,
    this.parent,
    required this.meta,
    required this.size,
    required this.mac,
    required this.pieces,
    this.parts = const [],
  });

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({
        'file': file,
        'version': version,
        'parent': parent,
        'meta': meta,
        'size': size,
        'mac': mac,
        if (parts.isEmpty) 'pieces': [for (final (id, len) in pieces) [id, len]],
        if (parts.isNotEmpty) 'parts': [for (final (id, n) in parts) [id, n]],
      })));

  static List<(String, int)> _pairs(Object? list) =>
      [for (final p in (list as List?) ?? const []) ((p as List)[0] as String, p[1] as int)];

  static Manifest decode(Uint8List b) {
    final j = jsonDecode(utf8.decode(b)) as Map<String, dynamic>;
    return Manifest(
      file: j['file'] as String,
      version: j['version'] as String,
      parent: j['parent'] as String?,
      meta: Map<String, dynamic>.from(j['meta'] as Map),
      size: j['size'] as int,
      mac: j['mac'] as String,
      pieces: _pairs(j['pieces']),
      parts: _pairs(j['parts']),
    );
  }

  Manifest withPieces(List<(String, int)> all) =>
      Manifest(file: file, version: version, parent: parent, meta: meta, size: size, mac: mac, pieces: all);
}

/// A live file in the backup, as the log says.
class RestoreEntry {
  final String fileId;
  final String version;
  final String manifestId;

  /// The device that wrote the version, and when it says it did.
  final String device;
  final DateTime time;
  const RestoreEntry(this.fileId, this.version, this.manifestId, this.device, this.time);
}

/// One version of a file, as the log tells it.
class BackupVersion {
  final String fileId;
  final String version;
  final String manifestId;

  /// The device that wrote it, and when it says it did.
  final String device;
  final DateTime time;

  /// When it stopped being the file's current version (a newer one was
  /// written, or it was deleted). Null while it's current.
  DateTime? retired;

  /// Retired by a delete rather than by a newer version.
  bool deleted = false;

  BackupVersion(this.fileId, this.version, this.manifestId, this.device, this.time);
}

/// What [SyncEngine.prune] did.
class PruneReport {
  /// Versions retired before the cut-off: their pieces could go, unless a
  /// version still kept shares them.
  final int versionsDropped;
  final int piecesDeleted;
  final int bytesFreed;
  final int piecesKept;
  const PruneReport(this.versionsDropped, this.piecesDeleted, this.bytesFreed, this.piecesKept);

  @override
  String toString() => 'PruneReport(dropped $versionsDropped versions, deleted $piecesDeleted pieces / $bytesFreed B, kept $piecesKept)';
}

/// Where the engine keeps its progress. In the app this lives inside the
/// vault; the CLI uses a JSON file. It's an optimisation: the server is the
/// source of truth for which pieces exist.
abstract class JournalStore {
  Future<Map<String, dynamic>> load();
  Future<void> save(Map<String, dynamic> journal);
}

class FileJournalStore implements JournalStore {
  final File file;
  FileJournalStore(this.file);
  @override
  Future<Map<String, dynamic>> load() async =>
      await file.exists() ? jsonDecode(await file.readAsString()) as Map<String, dynamic> : {};
  @override
  Future<void> save(Map<String, dynamic> journal) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(journal), flush: true);
    await tmp.rename(file.path);
  }
}

class MemoryJournalStore implements JournalStore {
  Map<String, dynamic> data = {};
  @override
  Future<Map<String, dynamic>> load() async => jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
  @override
  Future<void> save(Map<String, dynamic> journal) async => data = jsonDecode(jsonEncode(journal)) as Map<String, dynamic>;
}

/// Is this a "the connection dropped" error, as opposed to a real refusal?
bool isTransient(Object e) =>
    e is SocketException ||
    // A handshake cut off by a signal drop, but never a certificate the
    // client refused: retrying that for hours would hide an interception.
    ((e is HandshakeException || e is TlsException) &&
        e is! CertificateException &&
        !e.toString().contains('CERTIFICATE_VERIFY_FAILED')) ||
    e is TimeoutException ||
    e is http.ClientException ||
    e is HttpException ||
    (e is ApiException && (e.status >= 500 || e.status == 408 || e.status == 429));

class RetryPolicy {
  final int maxAttempts;
  final Duration initialBackoff;
  final Duration maxBackoff;
  const RetryPolicy({this.maxAttempts = 1000, this.initialBackoff = const Duration(milliseconds: 200), this.maxBackoff = const Duration(seconds: 15)});
}

class BackupReport {
  final String fileId;
  final int payloadBytes;
  final int wireBytes;
  final int piecesTotal;
  final int piecesUploaded;
  /// Dropped connections recovered from (0 on a perfect link).
  final int retries;
  final Duration elapsed;
  BackupReport(this.fileId, this.payloadBytes, this.wireBytes, this.piecesTotal, this.piecesUploaded, this.retries, this.elapsed);
  double get overhead => payloadBytes == 0 ? 1 : wireBytes / payloadBytes;
  @override
  String toString() =>
      'backup $fileId: $piecesUploaded/$piecesTotal pieces sent, ${wireBytes}B on the wire for ${payloadBytes}B '
      '(${overhead.toStringAsFixed(2)}x), $retries retr${retries == 1 ? 'y' : 'ies'}, ${elapsed.inMilliseconds} ms';
}

/// Uploads files as encrypted pieces + manifest + log record, resuming from
/// whatever the server already has after every dropped connection, and
/// restores them with full verification. See docs/SYNC_DESIGN.md §4–§8.
class SyncEngine {
  final SyncApi api;
  final SyncKeys keys;
  final Chunker chunker;
  final JournalStore journal;
  final RetryPolicy retry;
  final PieceCodec codec;
  final LogSealer sealer;

  SyncEngine._(this.api, this.keys, this.chunker, this.journal, this.retry)
      : codec = PieceCodec(keys),
        sealer = LogSealer(keys);

  static Future<SyncEngine> create({
    required SyncApi api,
    required SyncKeys keys,
    required JournalStore journal,
    RetryPolicy retry = const RetryPolicy(),
    Chunker? chunker,
  }) async =>
      SyncEngine._(api, keys, chunker ?? await Chunker.keyed(keys.cdc), journal, retry);

  String get _device => api.device!;

  // ── Adaptive part size ──
  //
  // A piece bigger than the current part size is sent in parts that the
  // server appends at its reported offset. Every dropped connection halves
  // the part size (down to 16 KiB); a run of successes doubles it (up to
  // 1 MiB). Short, slow pockets of signal still make progress, and good
  // links quickly go back to one request per piece.
  static const int minPart = 16 * 1024;
  static const int maxPart = 1024 * 1024;
  int partSize = 256 * 1024;
  int _streak = 0;

  void _onDrop() {
    partSize = max(minPart, partSize ~/ 2);
    _streak = 0;
  }

  void _onPartOk() {
    if (++_streak >= 4) {
      partSize = min(maxPart, partSize * 2);
      _streak = 0;
    }
  }

  Future<void> _sendPiece(String id, Uint8List sealed) async {
    if (sealed.length <= partSize) {
      await api.putPiece(id, sealed);
      _onPartOk();
      return;
    }
    final digest = await sha256(sealed);
    var state = await api.uploadOffset(id);
    if (state.done) return;
    var off = state.offset;
    if (off >= sealed.length) {
      // A leftover upload of different bytes under this name (or one the
      // server never completed): resuming can't finish it. Send it whole.
      await api.putPiece(id, sealed);
      return;
    }
    while (off < sealed.length) {
      final end = min(sealed.length, off + partSize);
      try {
        final r = await api.uploadPart(id, off, sealed.length, digest, Uint8List.sublistView(sealed, off, end));
        _onPartOk();
        if (r.done) return;
        off = r.offset;
      } on ApiException catch (e) {
        if (e.status == 409 || e.status == 422) {
          // 409: our idea of the offset was stale. 422: the assembled piece
          // didn't verify and the server discarded it. Ask where to go on.
          state = await api.uploadOffset(id);
          if (state.done) return;
          off = state.offset;
          continue;
        }
        rethrow;
      }
    }
  }

  Future<T> _withRetry<T>(Future<T> Function() op, void Function() onAttempt) async {
    var backoff = retry.initialBackoff;
    for (var attempt = 1;; attempt++) {
      onAttempt();
      try {
        return await op();
      } catch (e) {
        if (!isTransient(e) || attempt >= retry.maxAttempts) rethrow;
        _onDrop();
        await Future<void>.delayed(backoff);
        backoff = backoff * 2 > retry.maxBackoff ? retry.maxBackoff : backoff * 2;
      }
    }
  }

  static bool _compressible(String mime) =>
      mime.startsWith('text/') || mime == 'application/json' || mime == 'application/pdf' || mime.contains('xml');

  /// Backs up a file on disk. See [backupSource].
  Future<BackupReport> backupFile(File file, {required String fileId, Map<String, dynamic> meta = const {}}) =>
      backupSource(FileSyncSource(file), fileId: fileId, meta: meta);

  /// One pass over the content: finds the piece boundaries, names every
  /// piece and computes the whole-file MAC, holding at most one piece
  /// (about 1 MiB) in memory.
  Future<({List<List<dynamic>> plan, String mac, int size})> _plan(SyncSource src) async {
    final state = ChunkerState();
    final cuts = <ChunkRef>[];
    final plan = <List<dynamic>>[];
    final macSink = await Hmac.sha256().newMacSink(secretKey: SecretKeyData(keys.id));
    final pending = BytesBuilder(copy: false); // bytes not yet part of a finished piece
    var pendingStart = 0;
    var size = 0;

    Future<void> emit(Uint8List bytes, ChunkRef r) async {
      final piece = Uint8List.sublistView(bytes, r.offset - pendingStart, r.end - pendingStart);
      plan.add([r.offset, r.length, await codec.idFor(piece)]);
    }

    await for (final block in src.openRead()) {
      if (block.isEmpty) continue;
      macSink.add(block);
      size += block.length;
      final before = cuts.length;
      chunker.feed(state, block, cuts);
      pending.add(block);
      if (cuts.length > before) {
        final bytes = pending.takeBytes();
        for (var i = before; i < cuts.length; i++) {
          await emit(bytes, cuts[i]);
        }
        final consumed = cuts.last.end - pendingStart;
        if (consumed < bytes.length) pending.add(Uint8List.sublistView(bytes, consumed));
        pendingStart = cuts.last.end;
      }
    }
    final tail = chunker.finish(state);
    if (tail != null) await emit(pending.takeBytes(), tail);
    macSink.close();
    return (plan: plan, mac: hex((await macSink.mac()).bytes), size: size);
  }

  /// Backs up [src] under [fileId]. Safe to call again after a crash: the
  /// journal remembers the plan and the server remembers which pieces
  /// arrived. The content is read from [src] only; nothing is written to
  /// disk in the clear.
  ///
  /// If the item changed since an interrupted run planned it, the old plan
  /// is thrown away and the item planned again: sealing new content under
  /// the old piece names would store pieces that can never be restored
  /// (append-only servers keep them for good) or fail on every run.
  Future<BackupReport> backupSource(
    SyncSource src, {
    required String fileId,
    Map<String, dynamic> meta = const {},
  }) async {
    try {
      return await _backupSource(src, fileId: fileId, meta: meta, replan: false);
    } on _StalePlan {
      return _backupSource(src, fileId: fileId, meta: meta, replan: true);
    }
  }

  Future<BackupReport> _backupSource(
    SyncSource src, {
    required String fileId,
    required Map<String, dynamic> meta,
    required bool replan,
  }) async {
    final clock = Stopwatch()..start();
    final sentBefore = api.bytesSent;
    var attempts = 0;
    var uploaded = 0;
    final j = await journal.load();
    final jobs = (j['jobs'] as Map?)?.cast<String, dynamic>() ?? {};
    var job = (jobs[fileId] as Map?)?.cast<String, dynamic>();

    final committed = job != null && job['state'] == 'committed';
    final stale = job != null && !committed && (replan || jsonEncode(job['meta']) != jsonEncode(meta));
    if (job == null || committed || stale) {
      final planned = await _plan(src);
      // A version abandoned here may still have reached the server's log
      // (its reply lost), so remember it until a later version commits:
      // deleting the item must delete it too.
      final abandoned = stale
          ? <String>[...((job['abandoned'] as List?) ?? const []).cast<String>(), job['version'] as String]
          : const <String>[];
      job = {
        'version': hex(randomBytes(16)),
        // After a committed version, that one; after an abandoned plan, the
        // version it was going to replace.
        'parent': committed ? job['version'] : job?['parent'],
        if (abandoned.isNotEmpty) 'abandoned': abandoned,
        'size': planned.size,
        'mac': planned.mac,
        'meta': meta,
        'plan': planned.plan,
        'state': 'planned',
      };
      jobs[fileId] = job;
      j['jobs'] = jobs;
      await journal.save(j);
    }

    final plan = (job['plan'] as List).cast<List<dynamic>>();
    final ids = [for (final p in plan) p[2] as String];
    final compress = _compressible((meta['mime'] as String?) ?? '');

    // Pieces: ask what's missing, send only that. Every drop → ask again.
    // Then ask once more: nothing is committed until the server has them all.
    await _withRetry(() async {
      for (var round = 0;; round++) {
        final todo = (await api.missing(ids)).toSet();
        if (todo.isEmpty) break;
        if (round >= 3) throw IntegrityException('the server is still missing ${todo.length} pieces');
        for (final p in plan) {
          final id = p[2] as String;
          if (!todo.remove(id)) continue;
          final Uint8List plain;
          try {
            plain = await src.readRange(p[0] as int, p[1] as int);
          } on RangeError {
            throw _StalePlan();
          }
          if (await codec.idFor(plain) != id) throw _StalePlan();
          final sealed = await codec.seal(id, plain, compress: compress);
          await _sendPiece(id, sealed);
          uploaded++;
        }
      }
    }, () => attempts++);

    // Manifest.
    final manifest = Manifest(
      file: fileId,
      version: job['version'] as String,
      parent: job['parent'] as String?,
      meta: Map<String, dynamic>.from(job['meta'] as Map),
      size: job['size'] as int,
      mac: job['mac'] as String,
      pieces: [for (final p in plan) (p[2] as String, p[1] as int)],
    );
    final manifestId = await _putManifest(manifest, () => attempts++);

    // Log record: only now does the file count as backed up.
    await _withRetry(() => _commit(fileId, job!, manifestId), () => attempts++);

    // Three phases (pieces, manifest, log) each count one attempt when nothing fails.
    return BackupReport(fileId, job['size'] as int, api.bytesSent - sentBefore, plan.length, uploaded, attempts - 3, clock.elapsed);
  }

  /// Pieces per manifest part: about 80 bytes each in JSON, so a part stays
  /// well under the server's 2 MiB piece limit (files over ~2 GB).
  int piecesPerPart = 8000;

  Future<String> _putManifest(Manifest m, void Function() onAttempt) async {
    Future<String> put(Uint8List bytes) async {
      final id = await codec.idFor(bytes);
      await _withRetry(() async {
        if ((await api.missing([id])).isNotEmpty) {
          await _sendPiece(id, await codec.seal(id, bytes, compress: true, manifest: true));
        }
      }, onAttempt);
      return id;
    }

    if (m.pieces.length <= piecesPerPart) return put(m.encode());
    final parts = <(String, int)>[];
    for (var i = 0; i < m.pieces.length; i += piecesPerPart) {
      final slice = m.pieces.sublist(i, min(m.pieces.length, i + piecesPerPart));
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode([for (final (id, len) in slice) [id, len]])));
      parts.add((await put(bytes), slice.length));
    }
    return put(Manifest(
      file: m.file,
      version: m.version,
      parent: m.parent,
      meta: m.meta,
      size: m.size,
      mac: m.mac,
      pieces: const [],
      parts: parts,
    ).encode());
  }

  /// Fetches and opens a manifest, with its parts if it has them.
  Future<Manifest> manifestOf(String manifestId) async {
    final m = Manifest.decode(await codec.open(manifestId, await _withRetry(() => api.getPiece(manifestId), () {}), manifest: true));
    if (m.parts.isEmpty) return m;
    final all = <(String, int)>[];
    for (final (id, n) in m.parts) {
      final list = jsonDecode(utf8.decode(await codec.open(id, await _withRetry(() => api.getPiece(id), () {}), manifest: true)));
      final slice = Manifest._pairs(list);
      if (slice.length != n) throw IntegrityException('manifest part $id has the wrong number of pieces');
      all.addAll(slice);
    }
    return m.withPieces(all);
  }

  /// Remembers [state] as the latest known position of [device]'s chain.
  static void _noteHead(Map<String, dynamic> j, String device, ChainState state) {
    final heads = ((j['heads'] as Map?) ?? {}).cast<String, dynamic>();
    heads[device] = state.toJson();
    j['heads'] = heads;
  }

  static Map<String, ChainState> _knownHeads(Map<String, dynamic> j) => {
        for (final e in ((j['heads'] as Map?) ?? const {}).entries)
          e.key as String: ChainState.fromJson(Map<String, dynamic>.from(e.value as Map)),
      };

  Future<void> _commit(String fileId, Map<String, dynamic> job, String manifestId) async {
    final j = await journal.load();
    final chain = ChainState.fromJson(((j['chain'] as Map?) ?? {'c': 0, 'h': ''}).cast<String, dynamic>());
    final op = LogOp.put(file: fileId, version: job['version'] as String, manifestId: manifestId, parent: job['parent'] as String?);
    final (counter, sealed) = await sealer.next(_device, chain, [op]);
    try {
      await api.appendLog(counter, sealed);
    } on ApiException catch (e) {
      if (e.status != 409) rethrow;
      // Our journal is behind the server: an earlier append went through but
      // its reply was lost. Re-sync the chain from the server and check
      // whether this exact version is already committed.
      final version = job['version'] as String;
      final already = await _resyncChain(j, (o) => o.type == 'put' && o.file == fileId && o.version == version);
      if (!already) {
        await _commit(fileId, job, manifestId);
        return;
      }
      _markCommitted(j, fileId);
      await journal.save(j);
      return;
    }
    j['chain'] = chain.toJson();
    _noteHead(j, _device, chain);
    _markCommitted(j, fileId);
    await journal.save(j);
  }

  void _markCommitted(Map<String, dynamic> j, String fileId) {
    final jobs = (j['jobs'] as Map).cast<String, dynamic>();
    // The manifest on the server holds the piece list now; keeping it here
    // would bloat the journal (thousands of entries for one long video).
    (jobs[fileId] as Map)
      ..['state'] = 'committed'
      ..remove('plan')
      ..remove('abandoned');
  }

  /// Rebuilds this device's chain position from the server's log. Returns
  /// whether an op matching [wanted] is already in it.
  Future<bool> _resyncChain(Map<String, dynamic> j, bool Function(LogOp) wanted) async {
    final mine = (await api.readLog()).where((r) => r.device == _device).toList();
    var found = false;
    var state = ChainState();
    for (final r in mine) {
      final body = await sealer.open(r.device, r.counter, r.record);
      found = found || body.ops.any(wanted);
      state = ChainState(counter: r.counter, lastHash: hex(await sha256(r.record)));
    }
    j['chain'] = state.toJson();
    _noteHead(j, _device, state);
    await journal.save(j);
    return found;
  }

  /// Marks a file deleted in the log (pieces stay until pruning).
  Future<void> deleteFile(String fileId, String version) => deleteVersions(fileId, [version]);

  /// Marks [versions] of a file deleted, in one log record. A delete for a
  /// version that isn't the live one changes nothing, so when it isn't known
  /// which of several is live on the server, delete them all.
  Future<void> deleteVersions(String fileId, List<String> versions) async {
    if (versions.isEmpty) return;
    final version = versions.first;
    await _withRetry(() async {
      for (var tries = 0;; tries++) {
        final j = await journal.load();
        final chain = ChainState.fromJson(((j['chain'] as Map?) ?? {'c': 0, 'h': ''}).cast<String, dynamic>());
        final (counter, sealed) =
            await sealer.next(_device, chain, [for (final v in versions) LogOp.del(file: fileId, version: v)]);
        try {
          await api.appendLog(counter, sealed);
        } on ApiException catch (e) {
          // 409: an earlier append went through but its reply was lost.
          if (e.status != 409 || tries >= 3) rethrow;
          final done = await _resyncChain(j, (o) => o.type == 'del' && o.file == fileId && o.version == version);
          if (done) return;
          continue;
        }
        j['chain'] = chain.toJson();
        _noteHead(j, _device, chain);
        await journal.save(j);
        return;
      }
    }, () {});
  }

  /// The files that are live in the backup: the log replayed in the
  /// server's order, every chain verified (and checked against the chain
  /// positions this client saw before).
  ///
  /// [asOf] ignores everything written after that time (as the writing
  /// device's clock says), to undo later changes. [excludeDevices] ignores
  /// everything those devices wrote, e.g. a phone that was taken.
  Future<List<RestoreEntry>> liveFiles({DateTime? asOf, Set<String> excludeDevices = const {}}) async {
    final bodies = await _verifiedLog();
    final live = <String, RestoreEntry>{};
    for (final b in bodies) {
      if (excludeDevices.contains(b.device)) continue;
      if (asOf != null && b.time.isAfter(asOf)) continue;
      for (final op in b.ops) {
        if (op.type == 'put') {
          live[op.file] = RestoreEntry(op.file, op.version, op.manifestId!, b.device, b.time);
        } else if (op.type == 'del' && live[op.file]?.version == op.version) {
          live.remove(op.file);
        }
      }
    }
    return live.values.toList();
  }

  /// The whole log, every chain verified and checked against the chain
  /// positions this client saw before (which it then remembers).
  Future<List<LogBody>> _verifiedLog() async {
    final records = await _withRetry(() => api.readLog(), () {});
    final j = await journal.load();
    final heads = <String, ChainState>{};
    final bodies = await verifyLog(sealer, records, knownHeads: _knownHeads(j), headsOut: heads);
    j['heads'] = {for (final e in heads.entries) e.key: e.value.toJson()};
    await journal.save(j);
    return bodies;
  }

  /// After records were queued for someone else to upload (see the app's
  /// locked upload), which may or may not have reached the server: takes
  /// this device's chain as the server has it, and says which of this
  /// device's versions (`file/version`) and deletions arrived.
  ///
  /// The chain position this device noted for itself is dropped first: it
  /// counted records that were only queued, so the server being behind it
  /// is expected here, not a rollback.
  Future<({Set<String> puts, Set<String> dels})> syncOwnChain() async {
    final j0 = await journal.load();
    ((j0['heads'] as Map?) ?? {}).remove(_device);
    await journal.save(j0);
    final bodies = await _verifiedLog();
    final j = await journal.load();
    final head = ((j['heads'] as Map?) ?? const {})[_device];
    j['chain'] = head ?? {'c': 0, 'h': ''};
    await journal.save(j);
    final puts = <String>{}, dels = <String>{};
    for (final b in bodies) {
      if (b.device != _device) continue;
      for (final op in b.ops) {
        (op.type == 'put' ? puts : dels).add('${op.file}/${op.version}');
      }
    }
    return (puts: puts, dels: dels);
  }

  /// Every file the log has seen, each with its versions oldest first:
  /// current, replaced by a newer one, or deleted (see [BackupVersion]).
  /// Versions that [prune] removed are still listed (the log keeps them);
  /// their manifests are gone from the server.
  Future<Map<String, List<BackupVersion>>> history() async {
    final out = <String, List<BackupVersion>>{};
    final current = <String, BackupVersion>{};
    for (final b in await _verifiedLog()) {
      for (final op in b.ops) {
        if (op.type == 'put') {
          final v = BackupVersion(op.file, op.version, op.manifestId!, b.device, b.time);
          current[op.file]?.retired ??= b.time;
          current[op.file] = v;
          (out[op.file] ??= []).add(v);
        } else if (op.type == 'del' && current[op.file]?.version == op.version) {
          final v = current.remove(op.file)!;
          v.retired = b.time;
          v.deleted = true;
        }
      }
    }
    return out;
  }

  /// Frees server space: deletes every piece no kept version needs. A
  /// version is kept while it's current, and for [retention] after it was
  /// replaced or deleted; older ones go, except for pieces they share with
  /// a kept version. Pieces the log doesn't mention at all (an upload that
  /// never finished) go too, once they're older than [retention].
  ///
  /// Nothing younger than [retention] (by the server's clock) is ever
  /// deleted, so another phone's upload in progress keeps its pieces. The
  /// log is verified first and every kept manifest read: if anything can't
  /// be, nothing is deleted.
  ///
  /// Append-only accounts need [recovery] (the recovery key) to delete.
  Future<PruneReport> prune({
    required Duration retention,
    SimpleKeyPair? recovery,
    int keyIndex = 0,
    DateTime? now,
  }) async {
    final cutoff = (now ?? DateTime.now()).toUtc().subtract(retention);
    final keep = <String>{};
    var dropped = 0;
    for (final versions in (await history()).values) {
      for (final v in versions) {
        final retired = v.retired;
        if (retired != null && retired.isBefore(cutoff)) {
          dropped++;
          continue;
        }
        keep.add(v.manifestId);
        final top = Manifest.decode(
          await codec.open(v.manifestId, await _withRetry(() => api.getPiece(v.manifestId), () {}), manifest: true),
        );
        keep.addAll(top.parts.map((p) => p.$1));
        final m = top.parts.isEmpty ? top : await manifestOf(v.manifestId);
        keep.addAll(m.pieces.map((p) => p.$1));
      }
    }
    final doomed = <String>[];
    var bytes = 0, kept = 0;
    var after = '';
    while (true) {
      final page = await _withRetry(() => api.listPieces(after: after), () {});
      for (final p in page.pieces) {
        if (keep.contains(p.id) || !p.created.isBefore(cutoff)) {
          kept++;
        } else {
          doomed.add(p.id);
          bytes += p.size;
        }
      }
      final next = page.next;
      if (next == null) break;
      after = next;
    }
    var deleted = 0;
    for (var i = 0; i < doomed.length; i += 500) {
      final batch = doomed.sublist(i, min(doomed.length, i + 500));
      deleted += await _withRetry(() => api.deletePieces(batch, recovery: recovery, keyIndex: keyIndex), () {});
    }
    return PruneReport(dropped, deleted, bytes, kept);
  }

  /// A file's content, piece by piece, each verified (AEAD and name), and
  /// the whole-file MAC checked *before* the last piece is handed out, so a
  /// consumer that stops at the file's size never accepts a bad file.
  Stream<Uint8List> contentOf(Manifest m) async* {
    final macSink = await Hmac.sha256().newMacSink(secretKey: SecretKeyData(keys.id));
    var total = 0;
    for (var i = 0; i < m.pieces.length; i++) {
      final (id, len) = m.pieces[i];
      final plain = await codec.open(id, await _withRetry(() => api.getPiece(id), () {}));
      if (plain.length != len) throw IntegrityException('piece $id has wrong length');
      macSink.add(plain);
      total += plain.length;
      if (i == m.pieces.length - 1) {
        macSink.close();
        if (total != m.size || hex((await macSink.mac()).bytes) != m.mac) {
          throw IntegrityException('file ${m.file} failed its end-to-end check');
        }
      }
      yield plain;
    }
    if (m.pieces.isEmpty) {
      macSink.close();
      if (m.size != 0 || hex((await macSink.mac()).bytes) != m.mac) {
        throw IntegrityException('file ${m.file} failed its end-to-end check');
      }
    }
  }

  /// Restores the latest version of every live file into [out]. Verifies the
  /// log chains, every piece (AEAD + name), and every file's MAC.
  ///
  /// With [onError], a file that can't be restored (a missing piece, a
  /// failed check) is reported and skipped and the rest still come back;
  /// without it the first failure throws. Same-named files get " (2)" etc.
  /// A file that fails is never left half-written.
  Future<List<File>> restoreAll(
    Directory out, {
    void Function(String fileId, Object error)? onError,
    DateTime? asOf,
    Set<String> excludeDevices = const {},
  }) async {
    final live = await liveFiles(asOf: asOf, excludeDevices: excludeDevices);
    await out.create(recursive: true);
    final restored = <File>[];
    final used = <String>{};
    for (final op in live) {
      File? target;
      try {
        final m = await manifestOf(op.manifestId);
        final name = _uniqueName(_safeName((m.meta['title'] as String?) ?? m.file), used, out);
        final finalFile = File('${out.path}${Platform.pathSeparator}$name');
        // Written beside its final name and renamed when verified, so a
        // failure (or a killed process) never truncates or removes a file
        // that was already there, e.g. from an earlier restore.
        final t = File('${finalFile.path}.part');
        target = t;
        final sink = await t.open(mode: FileMode.write);
        try {
          await for (final plain in contentOf(m)) {
            sink.writeFromSync(plain);
          }
        } finally {
          await sink.close();
        }
        restored.add(await t.rename(finalFile.path));
      } catch (e) {
        final t = target;
        if (t != null && await t.exists()) await t.delete();
        if (onError == null) rethrow;
        onError(op.fileId, e);
      }
    }
    return restored;
  }

  static String _uniqueName(String name, Set<String> used, Directory dir) {
    var candidate = name;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    bool taken(String c) =>
        used.contains(c.toLowerCase()) ||
        File('${dir.path}${Platform.pathSeparator}$c').existsSync() ||
        File('${dir.path}${Platform.pathSeparator}$c.part').existsSync();
    for (var n = 2; taken(candidate); n++) {
      candidate = '$stem ($n)$ext';
    }
    used.add(candidate.toLowerCase());
    return candidate;
  }

  static String _safeName(String s) {
    final cleaned = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    return cleaned.isEmpty || cleaned == '.' || cleaned == '..' ? 'file' : cleaned;
  }
}

/// The plan in the journal no longer matches the item's content.
class _StalePlan implements Exception {}
