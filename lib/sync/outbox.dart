import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:sync_core/sync_core.dart';

/// What the upload queue holds (see Outbox.kt).
class OutboxStatus {
  /// False where there's no queue at all (not an Android phone).
  final bool supported;
  final bool armed;

  /// Which vault armed it: a random id only that vault knows.
  final String? armId;
  final DateTime? expires;
  final int count, bytes, cap;
  final bool hasStopCode;
  const OutboxStatus({
    this.supported = true,
    this.armed = false,
    this.armId,
    this.expires,
    this.count = 0,
    this.bytes = 0,
    this.cap = 0,
    this.hasStopCode = false,
  });
}

class OutboxEntry {
  final String name;
  final bool log;
  final String id;
  final int counter;
  final int size;
  const OutboxEntry(this.name, this.log, this.id, this.counter, this.size);
}

/// The queue that uploads while the vault is locked. The app's is
/// [PlatformOutbox]; tests use [MemoryOutbox].
abstract class Outbox {
  Future<OutboxStatus> status();
  Future<void> arm({
    required String server,
    required bool tor,
    required String token,
    required DateTime expires,
    required String armId,
    Uint8List? stopTag,
  });

  /// False when the queue is full: the rest waits for the next unlock.
  Future<bool> enqueue({required bool log, String? id, int counter = 0, required Uint8List data});
  Future<List<OutboxEntry>> entries();
  Future<Uint8List> read(String name);
  Future<void> remove(String name);
  Future<void> setStopTag(Uint8List? tag);

  /// The lock screen's check of a PIN that opened nothing: if it's the stop
  /// code, everything is wiped ([stop]). True if it was.
  Future<bool> stopIfMatches(Uint8List tag);

  /// The emergency stop: the queue and the upload login, gone.
  Future<void> stop();

  /// Upload what's queued as soon as there's a network.
  Future<void> kick();
}

class PlatformOutbox implements Outbox {
  static const MethodChannel _ch = MethodChannel('app.vault/outbox');
  const PlatformOutbox();

  @override
  Future<OutboxStatus> status() async {
    final Map<Object?, Object?> m;
    try {
      m = (await _ch.invokeMethod<Map<Object?, Object?>>('status')) ?? const {};
    } catch (_) {
      // No queue here: not an Android phone (or no app around it, in tests).
      return const OutboxStatus(supported: false);
    }
    if (m['armed'] != true) return const OutboxStatus();
    return OutboxStatus(
      armed: true,
      armId: m['arm'] as String?,
      expires: DateTime.fromMillisecondsSinceEpoch((m['expires'] as num).toInt()),
      count: (m['count'] as num).toInt(),
      bytes: (m['bytes'] as num).toInt(),
      cap: (m['cap'] as num).toInt(),
      hasStopCode: m['stop'] == true,
    );
  }

  @override
  Future<void> arm({
    required String server,
    required bool tor,
    required String token,
    required DateTime expires,
    required String armId,
    Uint8List? stopTag,
  }) =>
      _ch.invokeMethod<void>('arm', {
        'server': server,
        'tor': tor,
        'token': token,
        'expires': expires.millisecondsSinceEpoch,
        'arm': armId,
        'stop': stopTag,
      });

  @override
  Future<bool> enqueue({required bool log, String? id, int counter = 0, required Uint8List data}) async =>
      await _ch.invokeMethod<bool>('enqueue', {'log': log, 'id': id, 'counter': counter, 'data': data}) ?? false;

  @override
  Future<List<OutboxEntry>> entries() async => [
        for (final e in (await _ch.invokeListMethod<Map<Object?, Object?>>('entries')) ?? const <Map<Object?, Object?>>[])
          OutboxEntry(e['name'] as String, e['log'] == true, e['id'] as String, (e['counter'] as num).toInt(), (e['size'] as num).toInt()),
      ];

  @override
  Future<Uint8List> read(String name) async => (await _ch.invokeMethod<Uint8List>('read', {'name': name}))!;

  @override
  Future<void> remove(String name) => _ch.invokeMethod<void>('remove', {'name': name});

  @override
  Future<void> setStopTag(Uint8List? tag) => _ch.invokeMethod<void>('setStop', {'tag': tag});

  @override
  Future<bool> stopIfMatches(Uint8List tag) async {
    try {
      return await _ch.invokeMethod<bool>('stopIfMatches', {'tag': tag}) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _ch.invokeMethod<void>('stop');
    } catch (_) {
      // Not on a phone: nothing queued.
    }
  }

  @override
  Future<void> kick() async {
    try {
      await _ch.invokeMethod<void>('kick');
    } catch (_) {
      // Not on a phone.
    }
  }
}

/// The queue in memory, with a size cap: for tests.
class MemoryOutbox implements Outbox {
  Map<String, Object?>? state;
  final List<(OutboxEntry, Uint8List)> queue = [];
  int cap;
  int _n = 0;
  MemoryOutbox({this.cap = 1 << 30});

  @override
  Future<OutboxStatus> status() async {
    final s = state;
    if (s == null) return const OutboxStatus();
    return OutboxStatus(
      armed: true,
      armId: s['arm'] as String,
      expires: s['expires'] as DateTime,
      count: queue.length,
      bytes: queue.fold(0, (a, e) => a + e.$1.size),
      cap: cap,
      hasStopCode: s['stop'] != null,
    );
  }

  @override
  Future<void> arm({
    required String server,
    required bool tor,
    required String token,
    required DateTime expires,
    required String armId,
    Uint8List? stopTag,
  }) async {
    state = {...?state, 'server': server, 'tor': tor, 'token': token, 'expires': expires, 'arm': armId};
    if (stopTag != null) state!['stop'] = stopTag;
  }

  @override
  Future<bool> enqueue({required bool log, String? id, int counter = 0, required Uint8List data}) async {
    if (state == null) throw StateError('not armed');
    if (queue.fold<int>(0, (a, e) => a + e.$1.size) + data.length > cap) return false;
    queue.add((OutboxEntry('e${_n++}', log, id ?? '', counter, data.length), Uint8List.fromList(data)));
    return true;
  }

  @override
  Future<List<OutboxEntry>> entries() async => [for (final e in queue) e.$1];

  @override
  Future<Uint8List> read(String name) async => queue.firstWhere((e) => e.$1.name == name).$2;

  @override
  Future<void> remove(String name) async => queue.removeWhere((e) => e.$1.name == name);

  @override
  Future<void> setStopTag(Uint8List? tag) async {
    if (state == null) throw StateError('not armed');
    if (tag == null) {
      state!.remove('stop');
    } else {
      state!['stop'] = tag;
    }
  }

  @override
  Future<bool> stopIfMatches(Uint8List tag) async {
    final stop = state?['stop'] as Uint8List?;
    if (stop == null || !_same(stop, tag)) return false;
    await this.stop();
    return true;
  }

  @override
  Future<void> stop() async {
    state = null;
    queue.clear();
  }

  @override
  Future<void> kick() async {}

  /// What the phone's background job does: sends the queue in order with
  /// the upload token. Returns how many entries went.
  Future<int> deliver(SyncApi api) async {
    var sent = 0;
    while (queue.isNotEmpty) {
      final (e, data) = queue.first;
      if (e.log) {
        try {
          await api.appendLog(e.counter, data);
        } on ApiException catch (x) {
          if (x.status != 409) rethrow;
        }
      } else {
        await api.putPiece(e.id, data);
      }
      queue.removeAt(0);
      sent++;
    }
    return sent;
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a[i] ^ b[i];
    }
    return d == 0;
  }
}

/// Thrown when the queue is full.
class OutboxFull implements Exception {}

/// The sync engine's view of the queue: "uploading" a piece or a log record
/// puts it in the queue instead. Nothing here reaches the network.
class QueueSyncApi extends SyncApi {
  final Outbox outbox;
  final Set<String> _queued;
  final Map<String, BytesBuilder> _parts = {};

  QueueSyncApi(this.outbox, {Set<String> queued = const {}})
      : _queued = {...queued},
        super(Uri.parse('http://queue.invalid/'));

  @override
  Future<List<String>> missing(List<String> ids) async => [for (final id in ids) if (!_queued.contains(id)) id];

  @override
  Future<({String sha256, bool created})> putPiece(String id, Uint8List data) async {
    if (!_queued.contains(id)) {
      if (!await outbox.enqueue(log: false, id: id, data: data)) throw OutboxFull();
      _queued.add(id);
    }
    // The engine doesn't use the digest the server would report.
    return (sha256: '', created: true);
  }

  @override
  Future<({int offset, bool done})> uploadOffset(String id) async =>
      (offset: _parts[id]?.length ?? 0, done: _queued.contains(id));

  @override
  Future<({int offset, bool done})> uploadPart(String id, int offset, int total, Uint8List digest, Uint8List part) async {
    final b = _parts.putIfAbsent(id, BytesBuilder.new);
    if (offset != b.length) throw ApiException(409, jsonEncode({'offset': b.length}));
    b.add(part);
    if (b.length < total) return (offset: b.length, done: false);
    await putPiece(id, _parts.remove(id)!.takeBytes());
    return (offset: total, done: true);
  }

  @override
  Future<int> appendLog(int counter, Uint8List record) async {
    if (!await outbox.enqueue(log: true, counter: counter, data: record)) throw OutboxFull();
    return 0;
  }
}
