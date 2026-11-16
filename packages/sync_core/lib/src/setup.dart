import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'api.dart';
import 'crypto.dart';
import 'keys.dart';

/// Everything a device needs to sync. In the app, [srk] and the device seed
/// live inside the vault's encrypted index; [recoverySecret] is shown to the
/// user once (as the phrase) and then forgotten by the device.
class SyncIdentity {
  final String account;
  final String device;
  final Uint8List deviceSeed;
  final Uint8List srk;
  final int epoch;
  SyncIdentity({required this.account, required this.device, required this.deviceSeed, required this.srk, this.epoch = 0});

  Future<SimpleKeyPair> deviceKey() => Ed25519().newKeyPairFromSeed(deviceSeed);
  Future<SyncKeys> keys() => SyncKeys.derive(srk, epoch: epoch);

  Map<String, dynamic> toJson() => {
        'account': account,
        'device': device,
        'device_seed': hex(deviceSeed),
        'srk': hex(srk),
        'epoch': epoch,
      };
  static SyncIdentity fromJson(Map<String, dynamic> j) => SyncIdentity(
        account: j['account'] as String,
        device: j['device'] as String,
        deviceSeed: unhex(j['device_seed'] as String),
        srk: unhex(j['srk'] as String),
        epoch: j['epoch'] as int,
      );
}

Future<(String, Uint8List)> _newDevice(SyncApi api, String account, RecoveryKeys rk, int keyIndex) async {
  final seed = randomBytes(32);
  final kp = await Ed25519().newKeyPairFromSeed(seed);
  final pub = Uint8List.fromList((await kp.extractPublicKey()).bytes);
  final device = await api.addDevice(account, rk.signing, pub, keyIndex: keyIndex);
  return (device, seed);
}

/// Creates an account for one vault. Returns the identity and the recovery
/// secret (to show as the phrase). Mirrors the container's "4 slots, can't
/// tell how many are used": the recovery key and escrow go into random slots,
/// the other slots get real-looking filler.
///
/// Pass [recoverySecret] to use one the user has already written down and
/// confirmed (so an account never exists without its recovery secret).
Future<(SyncIdentity, Uint8List recoverySecret)> createAccount(
  SyncApi api, {
  String? invite,
  Uint8List? recoverySecret,
}) async {
  if (recoverySecret != null && recoverySecret.length != 32) {
    throw ArgumentError('recovery secret must be 32 bytes');
  }
  final rs = recoverySecret ?? randomBytes(32);
  final rk = await RecoveryKeys.fromSecret(rs);
  final srk = randomBytes(32);
  final rng = Random.secure();
  final keySlot = rng.nextInt(4);
  final escrowSlot = rng.nextInt(4);
  final pubs = [for (var i = 0; i < 4; i++) i == keySlot ? rk.publicKey : await decoyPublicKey()];
  final escrow = [for (var i = 0; i < 4; i++) i == escrowSlot ? await rk.wrapSrk(srk, 0) : randomBytes(128)];
  final account = await api.createAccount(recoveryKeys: pubs, escrow: escrow, invite: invite);
  final (device, seed) = await _newDevice(api, account, rk, keySlot);
  return (SyncIdentity(account: account, device: device, deviceSeed: seed, srk: srk), rs);
}

/// Old phone gone: from the recovery secret alone, register this device and
/// recover SRK from the escrow.
Future<SyncIdentity> recoverAccess(SyncApi api, String account, Uint8List recoverySecret) async {
  final rk = await RecoveryKeys.fromSecret(recoverySecret);
  // We don't store which of the 4 recovery slots is ours; find it.
  for (var idx = 0; idx < 4; idx++) {
    List<Uint8List> slots;
    try {
      slots = await api.escrowWithRecovery(account, rk.signing, keyIndex: idx);
    } on ApiException catch (e) {
      if (e.status == 401) continue;
      rethrow;
    }
    for (final slot in slots) {
      final hit = await rk.unwrapSrk(slot);
      if (hit != null) {
        final (device, seed) = await _newDevice(api, account, rk, idx);
        return SyncIdentity(account: account, device: device, deviceSeed: seed, srk: hit.$1, epoch: hit.$2);
      }
    }
    throw IntegrityException('recovery key accepted but no escrow slot opens');
  }
  throw IntegrityException('recovery secret does not match this account');
}

/// Points [api] at this identity's device credentials.
Future<void> useIdentity(SyncApi api, SyncIdentity id) async => api.useDevice(id.account, id.device, await id.deviceKey());
