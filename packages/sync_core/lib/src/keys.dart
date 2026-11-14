import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'crypto.dart';

/// Keys derived from a vault's sync root key (SRK) for one key epoch.
/// See docs/SYNC_DESIGN.md §3.
class SyncKeys {
  final int epoch;

  /// Seeds the chunker so piece boundaries depend on a secret.
  final Uint8List cdc;

  /// Piece names: HMAC-SHA256(id, plaintext).
  final Uint8List id;
  final Uint8List piece;
  final Uint8List manifest;
  final Uint8List log;

  /// Derives each piece's GCM nonce from its name, so re-sealing the same
  /// piece (e.g. resuming an upload after an app restart) gives identical
  /// bytes. Safe: a nonce repeats only for identical plaintext.
  final Uint8List nonce;

  SyncKeys._(this.epoch, this.cdc, this.id, this.piece, this.manifest, this.log, this.nonce);

  static Future<SyncKeys> derive(Uint8List srk, {int epoch = 0}) async {
    Future<Uint8List> k(String what) => hkdf(srk, 'sync/$what/e$epoch');
    return SyncKeys._(
      epoch,
      await k('cdc'),
      await k('id'),
      await k('piece'),
      await k('manifest'),
      await k('log'),
      await k('nonce'),
    );
  }
}

/// What the recovery secret (RS, the 24-word phrase) unlocks: the key that
/// wraps SRK in the server escrow, and the Ed25519 key that registers and
/// revokes devices. Never stored on a device.
class RecoveryKeys {
  final Uint8List wrap;
  final SimpleKeyPair signing;
  final Uint8List publicKey;

  RecoveryKeys._(this.wrap, this.signing, this.publicKey);

  static Future<RecoveryKeys> fromSecret(Uint8List rs) async {
    final wrap = await hkdf(rs, 'sync/srk-wrap');
    final seed = await hkdf(rs, 'sync/recovery-signing');
    final kp = await Ed25519().newKeyPairFromSeed(seed);
    final pub = Uint8List.fromList((await kp.extractPublicKey()).bytes);
    return RecoveryKeys._(wrap, kp, pub);
  }

  /// Escrow slot = seal(wrap, SRK ‖ epoch ‖ zero pad), exactly [slotBytes].
  Future<Uint8List> wrapSrk(Uint8List srk, int epoch, {int slotBytes = 128}) async {
    final plain = Uint8List(slotBytes - 28);
    plain.setRange(0, 32, srk);
    ByteData.sublistView(plain).setUint32(32, epoch);
    return seal(wrap, plain, 'sync/escrow'.codeUnits);
  }

  /// Tries a slot; returns (SRK, epoch) or null if it isn't ours.
  Future<(Uint8List, int)?> unwrapSrk(Uint8List slot) async {
    try {
      final plain = await open(wrap, slot, 'sync/escrow'.codeUnits);
      return (Uint8List.fromList(plain.sublist(0, 32)), ByteData.sublistView(plain).getUint32(32));
    } on IntegrityException {
      return null;
    }
  }
}

/// A real Ed25519 public key whose private half is thrown away. Used to fill
/// the unused recovery-key slots so the server can't count vaults.
Future<Uint8List> decoyPublicKey() async {
  final kp = await Ed25519().newKeyPair();
  return Uint8List.fromList((await kp.extractPublicKey()).bytes);
}
