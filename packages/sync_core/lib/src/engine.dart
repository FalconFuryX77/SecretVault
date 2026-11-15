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

  Manifest({
    required this.file,
    required this.version,
    this.parent,
    required this.meta,
    required this.size,
    required this.mac,
    required this.pieces,
  });

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({
        'file': file,
        'version': version,
        'parent': parent,
        'meta': meta,
        'size': size,
        'mac': mac,
        'pieces': [for (final (id, len) in pieces) [id, len]],
      })));

  static Manifest decode(Uint8List b) {
    final j = jsonDecode(utf8.decode(b)) as Map<String, dynamic>;
    return Manifest(
      file: j['file'] as String,
      version: j['version'] as String,
      parent: j['parent'] as String?,
      meta: Map<String, dynamic>.from(j['meta'] as Map),
      size: j['size'] as int,
      mac: j['mac'] as String,
      pieces: [for (final p in j['pieces'] as List) ((p as List)[0] as String, p[1] as int)],
    );
  }
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
  Future<BackupReport> backupSource(
    SyncSource src, {
    required String fileId,
    Map<String, dynamic> meta = const {},
  }) async {
    final clock = Stopwatch()..start();
    final sentBefore = api.bytesSent;
    var attempts = 0;
    var uploaded = 0;
    final j = await journal.load();
    final jobs = (j['jobs'] as Map?)?.cast<String, dynamic>() ?? {};
    var job = (jobs[fileId] as Map?)?.cast<String, dynamic>();

    if (job == null || job['state'] == 'committed') {
      final planned = await _plan(src);
      job = {
        'version': hex(randomBytes(16)),
        'parent': job?['version'],
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
    await _withRetry(() async {
      final todo = (await api.missing(ids)).toSet();
      for (final p in plan) {
        final id = p[2] as String;
        if (!todo.remove(id)) continue;
        final plain = await src.readRange(p[0] as int, p[1] as int);
        final sealed = await codec.seal(id, plain, compress: compress);
        await _sendPiece(id, sealed);
        uploaded++;
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
    final mBytes = manifest.encode();
    final manifestId = await codec.idFor(mBytes);
    await _withRetry(() async {
      if ((await api.missing([manifestId])).isNotEmpty) {
        await _sendPiece(manifestId, await codec.seal(manifestId, mBytes, compress: true, manifest: true));
      }
    }, () => attempts++);

    // Log record: only now does the file count as backed up.
    await _withRetry(() => _commit(fileId, job!, manifestId), () => attempts++);

    // Three phases (pieces, manifest, log) each count one attempt when nothing fails.
    return BackupReport(fileId, job['size'] as int, api.bytesSent - sentBefore, plan.length, uploaded, attempts - 3, clock.elapsed);
  }

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
      final already = await _resyncChain(j, fileId, job['version'] as String);
      if (!already) {
        await _commit(fileId, job, manifestId);
        return;
      }
      _markCommitted(j, fileId);
      await journal.save(j);
      return;
    }
    j['chain'] = chain.toJson();
    _markCommitted(j, fileId);
    await journal.save(j);
  }

  void _markCommitted(Map<String, dynamic> j, String fileId) {
    final jobs = (j['jobs'] as Map).cast<String, dynamic>();
    // The manifest on the server holds the piece list now; keeping it here
    // would bloat the journal (thousands of entries for one long video).
    (jobs[fileId] as Map)
      ..['state'] = 'committed'
      ..remove('plan');
  }

  /// Rebuilds this device's chain position from the server's log. Returns
  /// whether [version] of [fileId] is already in it.
  Future<bool> _resyncChain(Map<String, dynamic> j, String fileId, String version) async {
    final mine = (await api.readLog()).where((r) => r.device == _device).toList();
    var found = false;
    var state = ChainState();
    for (final r in mine) {
      final body = await sealer.open(r.device, r.counter, r.record);
      found = found || body.ops.any((o) => o.type == 'put' && o.file == fileId && o.version == version);
      state = ChainState(counter: r.counter, lastHash: hex(await sha256(r.record)));
    }
    j['chain'] = state.toJson();
    await journal.save(j);
    return found;
  }

  /// Marks a file deleted in the log (pieces stay until pruning).
  Future<void> deleteFile(String fileId, String version) async {
    await _withRetry(() async {
      final j = await journal.load();
      final chain = ChainState.fromJson(((j['chain'] as Map?) ?? {'c': 0, 'h': ''}).cast<String, dynamic>());
      final (counter, sealed) = await sealer.next(_device, chain, [LogOp.del(file: fileId, version: version)]);
      await api.appendLog(counter, sealed);
      j['chain'] = chain.toJson();
      await journal.save(j);
    }, () {});
  }

  /// Restores the latest version of every live file into [out]. Verifies the
  /// log chains, every piece (AEAD + name), and every file's MAC.
  Future<List<File>> restoreAll(Directory out) async {
    final records = await _withRetry(() => api.readLog(), () {});
    final bodies = await verifyLog(sealer, records);
    final live = <String, LogOp>{};
    for (final b in bodies) {
      for (final op in b.ops) {
        if (op.type == 'put') {
          live[op.file] = op;
        } else if (op.type == 'del' && live[op.file]?.version == op.version) {
          live.remove(op.file);
        }
      }
    }
    await out.create(recursive: true);
    final restored = <File>[];
    for (final op in live.values) {
      final mSealed = await _withRetry(() => api.getPiece(op.manifestId!), () {});
      final m = Manifest.decode(await codec.open(op.manifestId!, mSealed, manifest: true));
      final name = _safeName((m.meta['title'] as String?) ?? m.file);
      final target = File('${out.path}${Platform.pathSeparator}$name');
      final sink = await target.open(mode: FileMode.write);
      final macSink = await Hmac.sha256().newMacSink(secretKey: SecretKeyData(keys.id));
      try {
        for (final (id, len) in m.pieces) {
          final plain = await codec.open(id, await _withRetry(() => api.getPiece(id), () {}));
          if (plain.length != len) throw IntegrityException('piece $id has wrong length');
          sink.writeFromSync(plain);
          macSink.add(plain);
        }
      } finally {
        await sink.close();
      }
      macSink.close();
      if (hex((await macSink.mac()).bytes) != m.mac) {
        await target.delete();
        throw IntegrityException('file ${m.file} failed its end-to-end check');
      }
      restored.add(target);
    }
    return restored;
  }

  static String _safeName(String s) {
    final cleaned = s.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    return cleaned.isEmpty || cleaned == '.' || cleaned == '..' ? 'file' : cleaned;
  }
}
