import 'dart:convert';
import 'dart:typed_data';

import 'dart:math';

import 'crypto.dart';
import 'keys.dart';
import 'piece.dart' show padme;

/// One operation in the change log. See docs/SYNC_DESIGN.md §6.
class LogOp {
  final String type; // put | del
  final String file;
  final String version;
  final String? manifestId;
  final String? parent;

  const LogOp.put({required this.file, required this.version, required String this.manifestId, this.parent})
      : type = 'put';
  const LogOp.del({required this.file, required this.version})
      : type = 'del',
        manifestId = null,
        parent = null;
  const LogOp._(this.type, this.file, this.version, this.manifestId, this.parent);

  Map<String, dynamic> toJson() => {
        't': type,
        'f': file,
        'v': version,
        if (manifestId != null) 'm': manifestId,
        if (parent != null) 'p': parent,
      };

  static LogOp fromJson(Map<String, dynamic> j) =>
      LogOp._(j['t'] as String, j['f'] as String, j['v'] as String, j['m'] as String?, j['p'] as String?);
}

class LogBody {
  final String device;
  final int counter;

  /// SHA-256 (hex) of this device's previous *sealed* record, or empty for
  /// the first one. Links each device's records into a chain.
  final String prevHash;
  final DateTime time;
  final List<LogOp> ops;

  LogBody({required this.device, required this.counter, required this.prevHash, required this.time, required this.ops});

  /// Padded: 0x01 ‖ u32 length ‖ JSON ‖ zeros, to a Padmé size of at least
  /// [minPadded] bytes, so a record's size says little about what it holds
  /// (one new file, an edit, a batch of deletions). Records written before
  /// padding are bare JSON, and still read.
  static const int minPadded = 1024;

  Uint8List encode() {
    final json = utf8.encode(jsonEncode({
      'd': device,
      'c': counter,
      'h': prevHash,
      'ts': time.toUtc().toIso8601String(),
      'ops': ops.map((o) => o.toJson()).toList(),
    }));
    final out = Uint8List(max(minPadded, padme(5 + json.length)));
    out[0] = 1;
    ByteData.sublistView(out).setUint32(1, json.length);
    out.setRange(5, 5 + json.length, json);
    return out;
  }

  static LogBody decode(Uint8List b) {
    var json = b;
    if (b.isNotEmpty && b[0] == 1) {
      if (b.length < 5) throw IntegrityException('log record too short');
      final len = ByteData.sublistView(b).getUint32(1);
      if (5 + len > b.length) throw IntegrityException('log record length out of range');
      json = Uint8List.sublistView(b, 5, 5 + len);
    }
    final j = jsonDecode(utf8.decode(json)) as Map<String, dynamic>;
    return LogBody(
      device: j['d'] as String,
      counter: j['c'] as int,
      prevHash: j['h'] as String,
      time: DateTime.parse(j['ts'] as String),
      ops: (j['ops'] as List).map((o) => LogOp.fromJson(Map<String, dynamic>.from(o as Map))).toList(),
    );
  }
}

List<int> _aad(String device, int counter) => utf8.encode('log:$device:$counter');

/// A device's position in its own chain. Persist it; it's needed to append.
class ChainState {
  int counter;
  String lastHash;
  ChainState({this.counter = 0, this.lastHash = ''});

  Map<String, dynamic> toJson() => {'c': counter, 'h': lastHash};
  static ChainState fromJson(Map<String, dynamic> j) => ChainState(counter: j['c'] as int, lastHash: j['h'] as String);
}

class LogSealer {
  final SyncKeys keys;
  LogSealer(this.keys);

  /// Seals the next record of [device]'s chain and advances [state].
  Future<(int counter, Uint8List sealed)> next(String device, ChainState state, List<LogOp> ops) async {
    final body = LogBody(
      device: device,
      counter: state.counter + 1,
      prevHash: state.lastHash,
      time: DateTime.now(),
      ops: ops,
    );
    final sealed = await seal(keys.log, body.encode(), _aad(device, body.counter));
    state
      ..counter = body.counter
      ..lastHash = hex(await sha256(sealed));
    return (body.counter, sealed);
  }

  Future<LogBody> open(String device, int counter, Uint8List sealed) async {
    final body = LogBody.decode(await openSealed(keys.log, sealed, _aad(device, counter)));
    if (body.device != device || body.counter != counter) {
      throw IntegrityException('log record header mismatch');
    }
    return body;
  }
}

/// Verifies every device chain in a log read from the server: counters must
/// be 1, 2, 3… with no gaps, and each record must name the hash of the
/// previous one. A server that drops or reorders records is caught.
///
/// [knownHeads] are chain positions this client saw before (its journal):
/// each must still be in the log with the same hash, or the server dropped
/// (rolled back) or rewrote records it had already accepted. [headsOut]
/// receives every chain's latest position, to remember for next time.
Future<List<LogBody>> verifyLog(
  LogSealer sealer,
  List<({int seq, String device, int counter, Uint8List record})> records, {
  Map<String, ChainState>? knownHeads,
  Map<String, ChainState>? headsOut,
}) async {
  final last = <String, (int, String)>{};
  final out = <LogBody>[];
  for (final r in records) {
    final body = await sealer.open(r.device, r.counter, r.record);
    final (prevCounter, prevHash) = last[r.device] ?? (0, '');
    if (body.counter != prevCounter + 1) {
      throw IntegrityException('device ${r.device}: expected record ${prevCounter + 1}, got ${body.counter}');
    }
    if (body.prevHash != prevHash) {
      throw IntegrityException('device ${r.device}: chain broken at record ${body.counter}');
    }
    final h = hex(await sha256(r.record));
    final known = knownHeads?[r.device];
    if (known != null && known.counter == body.counter && known.lastHash != h) {
      throw IntegrityException('device ${r.device}: record ${body.counter} differs from the one seen before');
    }
    last[r.device] = (body.counter, h);
    out.add(body);
  }
  knownHeads?.forEach((device, known) {
    final seen = last[device]?.$1 ?? 0;
    if (seen < known.counter) {
      throw IntegrityException(
          'device $device: the server no longer has records $seen+1..${known.counter} it accepted before');
    }
  });
  if (headsOut != null) {
    last.forEach((device, v) => headsOut[device] = ChainState(counter: v.$1, lastHash: v.$2));
  }
  return out;
}

Future<Uint8List> openSealed(List<int> key, Uint8List sealed, List<int> aad) => open(key, sealed, aad);
