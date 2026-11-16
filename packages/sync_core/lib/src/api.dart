import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import 'crypto.dart';

/// HTTP failure with the server's status code.
class ApiException implements Exception {
  final int status;
  final String body;
  ApiException(this.status, this.body);
  @override
  String toString() => 'ApiException($status): $body';
}

/// Signed-message format shared with the server (server/app/security.py).
Future<Uint8List> _signedMessage(String op, String account, String nonce, List<int> body) async {
  final digest = hex(await sha256(body));
  return Uint8List.fromList(utf8.encode('sv-sync-v1|$op|$account|$nonce|$digest'));
}

/// Thin client for the sync server API (docs/SYNC_DESIGN.md §7).
///
/// It does no retrying itself: callers decide what a dropped connection
/// means (usually "wait for the next pocket of signal").
class SyncApi {
  final Uri base;
  final http.Client _http;
  final Duration timeout;

  String? _token;
  DateTime _tokenExpiry = DateTime.fromMillisecondsSinceEpoch(0);

  /// Bytes put on the wire for request bodies (for measurements).
  int bytesSent = 0;
  int requests = 0;

  SyncApi(this.base, {http.Client? client, this.timeout = const Duration(seconds: 30)})
      : _http = client ?? http.Client();

  Uri _u(String path, [Map<String, String>? q]) => base.resolve(path).replace(queryParameters: q);

  Future<http.Response> _send(http.BaseRequest req) async {
    requests++;
    if (req is http.Request) bytesSent += req.bodyBytes.length;
    final streamed = await _http.send(req).timeout(timeout);
    return http.Response.fromStream(streamed).timeout(timeout);
  }

  Future<Map<String, dynamic>> _json(String method, String path, {Object? body, Map<String, String>? headers, List<int>? raw, int expect = 200}) async {
    final req = http.Request(method, _u(path));
    req.headers.addAll(headers ?? {});
    if (raw != null) {
      req.bodyBytes = raw;
      req.headers.putIfAbsent('Content-Type', () => 'application/json');
    } else if (body != null) {
      req.bodyBytes = utf8.encode(jsonEncode(body));
      req.headers['Content-Type'] = 'application/json';
    }
    final r = await _send(req);
    if (r.statusCode != expect && !(expect == 200 && r.statusCode == 201)) throw ApiException(r.statusCode, r.body);
    return r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;
  }

  // ── account bootstrap & recovery-key operations ──

  Future<String> createAccount({required List<Uint8List> recoveryKeys, required List<Uint8List> escrow, String? invite}) async {
    final r = await _json('POST', '/v1/accounts', body: {
      'recovery_keys': recoveryKeys.map(base64Encode).toList(),
      'escrow': escrow.map(base64Encode).toList(),
      if (invite != null) 'invite_code': invite,
    }, expect: 201);
    return r['account_id'] as String;
  }

  Future<String> challenge(String account) async =>
      (await _json('POST', '/v1/challenges', body: {'account_id': account}))['nonce'] as String;

  Future<Map<String, String>> recoveryHeader(String account, SimpleKeyPair key, String op, List<int> body, {int keyIndex = 0}) async {
    final nonce = await challenge(account);
    final sig = await Ed25519().sign(await _signedMessage(op, account, nonce, body), keyPair: key);
    return {'X-Recovery-Auth': '$keyIndex.$nonce.${base64Encode(sig.bytes)}'};
  }

  Future<String> addDevice(String account, SimpleKeyPair recovery, Uint8List devicePublicKey, {int keyIndex = 0}) async {
    final raw = utf8.encode(jsonEncode({'public_key': base64Encode(devicePublicKey)}));
    final hdr = await recoveryHeader(account, recovery, 'add-device', raw, keyIndex: keyIndex);
    final r = await _json('POST', '/v1/accounts/$account/devices', raw: raw, headers: hdr, expect: 201);
    return r['device_id'] as String;
  }

  /// Accounts on this server that list [recovery]'s public key. Signed with
  /// the key over the current time, so only its holder can ask.
  Future<List<String>> lookupAccounts(SimpleKeyPair recovery) async {
    final pub = base64Encode((await recovery.extractPublicKey()).bytes);
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final sig = await Ed25519().sign(await _signedMessage('lookup:$pub', '-', '$ts', const []), keyPair: recovery);
    final r = await _json('POST', '/v1/recovery/lookup',
        body: {'public_key': pub, 'ts': ts, 'signature': base64Encode(sig.bytes)});
    return (r['accounts'] as List).cast<String>();
  }

  Future<void> revokeDevice(String account, SimpleKeyPair recovery, String deviceId, {int keyIndex = 0}) async {
    final hdr = await recoveryHeader(account, recovery, 'revoke-device:$deviceId', const [], keyIndex: keyIndex);
    await _json('DELETE', '/v1/accounts/$account/devices/$deviceId', headers: hdr, expect: 204);
  }

  /// Deletes the account and everything in it (recovery key only).
  Future<void> deleteAccount(String account, SimpleKeyPair recovery, {int keyIndex = 0}) async {
    final hdr = await recoveryHeader(account, recovery, 'delete-account', const [], keyIndex: keyIndex);
    await _json('DELETE', '/v1/accounts/$account', headers: hdr, expect: 204);
  }

  Future<List<Uint8List>> escrowWithRecovery(String account, SimpleKeyPair recovery, {int keyIndex = 0}) async {
    final hdr = await recoveryHeader(account, recovery, 'get-escrow', const [], keyIndex: keyIndex);
    final r = await _json('GET', '/v1/accounts/$account/escrow', headers: hdr);
    return (r['slots'] as List).map((s) => base64Decode(s as String)).toList();
  }

  // ── device session ──

  String? account;
  String? device;
  SimpleKeyPair? _deviceKey;

  void useDevice(String account, String device, SimpleKeyPair key) {
    this.account = account;
    this.device = device;
    _deviceKey = key;
    _token = null;
  }

  Future<Map<String, String>> _auth() async {
    if (_token == null || DateTime.now().isAfter(_tokenExpiry)) {
      final nonce = await challenge(account!);
      final sig = await Ed25519().sign(await _signedMessage('login:$device', account!, nonce, const []), keyPair: _deviceKey!);
      final r = await _json('POST', '/v1/auth/token', body: {
        'account_id': account,
        'device_id': device,
        'nonce': nonce,
        'signature': base64Encode(sig.bytes),
      });
      _token = r['token'] as String;
      // Refresh a minute early.
      _tokenExpiry = DateTime.now().add(Duration(seconds: (r['expires_in'] as int) - 60));
    }
    return {'Authorization': 'Bearer $_token'};
  }

  /// The account's devices (device token).
  Future<List<({String id, DateTime created, DateTime? revoked})>> devices() async {
    final req = http.Request('GET', _u('/v1/accounts/$account/devices'))..headers.addAll(await _auth());
    final r = await _send(req);
    if (r.statusCode != 200) throw ApiException(r.statusCode, r.body);
    return [
      for (final d in (jsonDecode(r.body) as List).cast<Map<String, dynamic>>())
        (
          id: d['device_id'] as String,
          created: DateTime.parse(d['created_at'] as String),
          revoked: d['revoked_at'] == null ? null : DateTime.parse(d['revoked_at'] as String),
        ),
    ];
  }

  Future<List<String>> missing(List<String> ids) async {
    final out = <String>[];
    for (var i = 0; i < ids.length; i += 500) {
      final batch = ids.sublist(i, ids.length < i + 500 ? ids.length : i + 500);
      final r = await _json('POST', '/v1/pieces/missing', body: {'ids': batch}, headers: await _auth());
      out.addAll((r['missing'] as List).cast<String>());
    }
    return out;
  }

  /// Uploads one piece. Returns the SHA-256 the server stored (hex) and
  /// whether this upload created it.
  Future<({String sha256, bool created})> putPiece(String id, Uint8List data) async {
    final req = http.Request('PUT', _u('/v1/pieces/$id'))
      ..headers.addAll(await _auth())
      ..headers['Content-Digest'] = 'sha-256=:${base64Encode(await sha256(data))}:'
      ..headers['Content-Type'] = 'application/octet-stream'
      ..bodyBytes = data;
    final r = await _send(req);
    if (r.statusCode != 200 && r.statusCode != 201) throw ApiException(r.statusCode, r.body);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (sha256: j['sha256'] as String, created: j['created'] as bool);
  }

  /// Bytes of [id] the server already holds from an interrupted upload.
  Future<({int offset, bool done})> uploadOffset(String id) async {
    final r = await _json('GET', '/v1/uploads/$id', headers: await _auth());
    return (offset: r['offset'] as int, done: r['done'] as bool);
  }

  /// Appends [part] at [offset] of a piece of [total] bytes whose whole
  /// SHA-256 is [digest]. Throws [ApiException] 409 (with the server's offset
  /// in the body) if the offset is wrong, 422 if the assembled piece is bad.
  Future<({int offset, bool done})> uploadPart(String id, int offset, int total, Uint8List digest, Uint8List part) async {
    final req = http.Request('PATCH', _u('/v1/uploads/$id'))
      ..headers.addAll(await _auth())
      ..headers['Upload-Offset'] = '$offset'
      ..headers['Upload-Length'] = '$total'
      ..headers['Piece-Digest'] = 'sha-256=:${base64Encode(digest)}:'
      ..headers['Content-Type'] = 'application/octet-stream'
      ..bodyBytes = part;
    final r = await _send(req);
    if (r.statusCode != 200 && r.statusCode != 201) throw ApiException(r.statusCode, r.body);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return (offset: j['offset'] as int, done: j['done'] as bool);
  }

  Future<Uint8List> getPiece(String id, {int from = 0}) async {
    final req = http.Request('GET', _u('/v1/pieces/$id'))..headers.addAll(await _auth());
    if (from > 0) req.headers['Range'] = 'bytes=$from-';
    final r = await _send(req);
    if (r.statusCode != 200 && r.statusCode != 206) throw ApiException(r.statusCode, r.body);
    return r.bodyBytes;
  }

  /// Appends a sealed record. Throws [ApiException] 409 if [counter] isn't
  /// this device's next one.
  Future<int> appendLog(int counter, Uint8List record) async {
    final r = await _json('POST', '/v1/log',
        body: {'counter': counter, 'record': base64Encode(record)}, headers: await _auth(), expect: 201);
    return r['seq'] as int;
  }

  Future<List<({int seq, String device, int counter, Uint8List record})>> readLog({int after = 0}) async {
    final out = <({int seq, String device, int counter, Uint8List record})>[];
    var cursor = after;
    while (true) {
      final req = http.Request('GET', _u('/v1/log', {'after': '$cursor', 'limit': '500'}))..headers.addAll(await _auth());
      final r = await _send(req);
      if (r.statusCode != 200) throw ApiException(r.statusCode, r.body);
      final recs = (jsonDecode(r.body) as Map<String, dynamic>)['records'] as List;
      for (final x in recs.cast<Map<String, dynamic>>()) {
        out.add((
          seq: x['seq'] as int,
          device: x['device_id'] as String,
          counter: x['counter'] as int,
          record: base64Decode(x['record'] as String),
        ));
      }
      if (recs.length < 500) return out;
      cursor = out.last.seq;
    }
  }

  void close() => _http.close();
}
