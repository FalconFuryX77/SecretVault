import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'crypto_primitives.dart';
import 'platform_keys.dart';

/// Notices when the container file has been replaced by an older copy of
/// itself (a "rollback"): someone restoring a copy they took earlier, to
/// undo a deletion, a PIN change or a removed decoy, or to watch what
/// changed.
///
/// Each vault records its latest commit number in a small state file next
/// to the container. On unlock, a vault whose commit number is lower than
/// the recorded one was rolled back.
///
/// The state file says nothing on its own: it is sealed under a key derived
/// through this phone's hardware keystore (so a copy of it taken off the
/// phone can't be read), it is rewritten whole with a fresh nonce each time,
/// and it always holds four slots, one per container record, unused ones
/// random. Each slot is readable only with its vault's key.
///
/// It can't tell anything apart that happened on another phone or after the
/// app was reinstalled (the state file is gone), and someone who controls
/// the running phone can roll both files back together.
class RollbackGuard {
  final File file;
  final DeviceBinding binding;
  RollbackGuard(this.file, this.binding);

  static const int slots = 4;
  static const int slotLen = 32; // u64 generation + 24-byte tag
  static final List<int> _aad = utf8.encode('sv/rollback-state');

  Future<Uint8List> _key() => binding.bind(Uint8List.fromList(utf8.encode('sv/rollback-state-key')));

  Future<List<Uint8List>> _read(Uint8List key) async {
    Uint8List? plain;
    try {
      if (await file.exists()) plain = await CryptoPrimitives.tryOpen(key, await file.readAsBytes(), _aad);
    } catch (_) {
      plain = null;
    }
    if (plain == null || plain.length != slots * slotLen) {
      return [for (var i = 0; i < slots; i++) CryptoPrimitives.randomBytes(slotLen)];
    }
    return [for (var i = 0; i < slots; i++) Uint8List.fromList(plain.sublist(i * slotLen, (i + 1) * slotLen))];
  }

  Future<void> _write(Uint8List key, List<Uint8List> s) async {
    final plain = Uint8List(slots * slotLen);
    for (var i = 0; i < slots; i++) {
      plain.setRange(i * slotLen, (i + 1) * slotLen, s[i]);
    }
    final sealed = await CryptoPrimitives.seal(key, plain, _aad);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(sealed, flush: true);
    await tmp.rename(file.path);
  }

  static Future<Uint8List> _tag(Uint8List vaultKey, int gen) async {
    final g = ByteData(8)..setUint64(0, gen);
    final mac = await CryptoPrimitives.hmacSha256(vaultKey, [...utf8.encode('rb'), ...g.buffer.asUint8List()]);
    return Uint8List.sublistView(mac, 0, slotLen - 8);
  }

  /// The commit number last recorded for the vault in [record] with
  /// [vaultKey] (its rollback key), or null if there's none.
  Future<int?> recorded(int record, Uint8List vaultKey) async {
    final key = await _key();
    try {
      final slot = (await _read(key))[record];
      final gen = ByteData.sublistView(slot, 0, 8).getUint64(0);
      final tag = await _tag(vaultKey, gen);
      for (var i = 0; i < tag.length; i++) {
        if (tag[i] != slot[8 + i]) return null;
      }
      return gen;
    } finally {
      CryptoPrimitives.wipe(key);
    }
  }

  /// Records [gen] as the vault's latest commit number.
  Future<void> record(int record, Uint8List vaultKey, int gen) async {
    final key = await _key();
    try {
      final s = await _read(key);
      final slot = Uint8List(slotLen);
      ByteData.sublistView(slot, 0, 8).setUint64(0, gen);
      slot.setRange(8, slotLen, await _tag(vaultKey, gen));
      s[record] = slot;
      await _write(key, s);
    } finally {
      CryptoPrimitives.wipe(key);
    }
  }
}
