import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'crypto.dart';
import 'crypto.dart' as c;
import 'keys.dart';

/// Padmé padding (Nikitin et al., 2019): pads length L so the result leaks
/// O(log log L) bits about L, with at most ~12% overhead.
int padme(int length) {
  if (length < 2) return length;
  final e = length.bitLength - 1; // floor(log2 L)
  final s = e.bitLength; // floor(log2 e) + 1
  final lastBits = e - s;
  final mask = (1 << lastBits) - 1;
  return (length + mask) & ~mask;
}

/// Encodes pieces: name, optional compression, padding, encryption.
/// See docs/SYNC_DESIGN.md §4.
class PieceCodec {
  static const int codecNone = 0;
  static const int codecDeflate = 1;
  static const int _header = 5; // codec(1) ‖ length(4)

  final SyncKeys keys;
  PieceCodec(this.keys);

  /// `HMAC-SHA256(K_id, plaintext)` as hex: the server can't compute names
  /// for content it wants to look for.
  Future<String> idFor(List<int> plain) async => hex(await hmacSha256(keys.id, plain));

  Future<Uint8List> seal(String id, Uint8List plain, {bool compress = false, bool manifest = false}) async {
    var codec = codecNone;
    var body = plain;
    if (compress && plain.isNotEmpty) {
      final z = Uint8List.fromList(ZLibCodec(raw: true, level: 6).encode(plain));
      // Keep it only if it saves at least 10%.
      if (z.length <= plain.length * 0.9) {
        codec = codecDeflate;
        body = z;
      }
    }
    final inner = Uint8List(padme(_header + body.length));
    inner[0] = codec;
    ByteData.sublistView(inner).setUint32(1, body.length);
    inner.setRange(_header, _header + body.length, body);
    // Deterministic, SIV-style nonce: a keyed hash of the AAD *and the exact
    // bytes being encrypted* (after compression and padding). Sealing the same
    // input again gives identical ciphertext, so an interrupted upload resumes
    // byte-for-byte even after a restart. Any difference in the input (other
    // content, or the same content with another compression choice) gives a
    // different nonce, so a nonce is never reused for different plaintext.
    final aad = _aad(id, manifest);
    final nonce = (await hmacSha256(keys.nonce, [...aad, ...await sha256(inner)])).sublist(0, 12);
    return c.seal(manifest ? keys.manifest : keys.piece, inner, _aad(id, manifest), nonce: nonce);
  }

  Future<Uint8List> open(String id, Uint8List sealed, {bool manifest = false}) async {
    final inner = await c.open(manifest ? keys.manifest : keys.piece, sealed, _aad(id, manifest));
    if (inner.length < _header) throw IntegrityException('piece too short');
    final codec = inner[0];
    final len = ByteData.sublistView(inner).getUint32(1);
    if (_header + len > inner.length) throw IntegrityException('bad piece length');
    final body = Uint8List.sublistView(inner, _header, _header + len);
    final plain = switch (codec) {
      codecNone => Uint8List.fromList(body),
      codecDeflate => Uint8List.fromList(ZLibCodec(raw: true).decode(body)),
      _ => throw IntegrityException('unknown codec $codec'),
    };
    // The name commits to the content: check it, so a valid ciphertext of
    // *other* content stored under this name is still caught.
    if (await idFor(plain) != id) throw IntegrityException('piece content does not match its name');
    return plain;
  }

  static List<int> _aad(String id, bool manifest) => utf8.encode('${manifest ? 'manifest' : 'piece'}:$id');
}
