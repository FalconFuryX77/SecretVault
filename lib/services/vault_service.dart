import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../vault/crypto_primitives.dart';
import '../vault/platform_keys.dart';
import '../sync/outbox.dart';
import '../vault/rollback_guard.dart';
import 'security_channel_service.dart';
import '../vault/vault_container.dart';

/// App-wide owner of the vault container and the currently unlocked session.
///
/// Nothing outside this class holds vault keys. Locking closes the session,
/// which wipes every key from memory.
class VaultService {
  /// Neutral filename: a cache-style blob in the cover app's private
  /// storage (a video trimmer keeps thumbnails) is unremarkable.
  static const containerName = 'thumbnails.cache';

  /// The rollback guard's state (see RollbackGuard): sealed, meaningless
  /// without this phone's keystore.
  static const rollbackStateName = 'thumbnails.idx';

  final VaultCrypto crypto;
  final Future<Directory> Function() _dirProvider;
  VaultSession? _session;

  final _lockEvents = StreamController<void>.broadcast();

  VaultService({VaultCrypto? crypto, Future<Directory> Function()? storageDir})
    : crypto =
          crypto ??
          VaultCrypto(binding: defaultDeviceBinding(), normalize: platformNormalize),
      _dirProvider = storageDir ?? getApplicationSupportDirectory;

  VaultSession? get session => (_session?.isOpen ?? false) ? _session : null;

  int _busy = 0;

  /// True while a long operation (an import) is running; auto-lock waits.
  bool get isBusy => _busy > 0;

  Future<T> whileBusy<T>(Future<T> Function() op) async {
    _busy++;
    try {
      return await op();
    } finally {
      _busy--;
    }
  }

  bool get isUnlocked => session != null;

  /// Fires whenever the vault is locked (manually, by timeout or panic).
  Stream<void> get onLocked => _lockEvents.stream;

  final _unlockEvents = StreamController<VaultSession>.broadcast();
  final _commitEvents = StreamController<int>.broadcast();

  /// Fires with the session whenever a vault is unlocked (or created).
  Stream<VaultSession> get onUnlocked => _unlockEvents.stream;

  /// Fires after every commit of the open vault (its new commit number).
  Stream<int> get commits => _commitEvents.stream;

  void Function(int)? _rollbackHook;

  void _opened(VaultSession s) {
    s.onCommitted = (gen) {
      _rollbackHook?.call(gen);
      if (!_commitEvents.isClosed) _commitEvents.add(gen);
    };
    if (!_unlockEvents.isClosed) _unlockEvents.add(s);
  }

  Future<File> containerFile() async =>
      File(p.join((await _dirProvider()).path, containerName));

  Future<bool> isSetUp() async => (await containerFile()).exists();

  Future<VaultContainer> _container() async =>
      VaultContainer(await containerFile(), crypto);


  Future<VaultSession> create({
    required String pin,
    int initialChunks = ContainerLayout.defaultInitialChunks,
    void Function(double progress)? onProgress,
  }) async {
    await lock();
    final s = await VaultContainer.create(
      await containerFile(),
      crypto,
      pin: pin,
      initialChunks: initialChunks,
      onProgress: onProgress,
    );
    _session = s;
    await SecurityChannelService.setVaultOpen(true);
    await _watchRollback(s);
    _opened(s);
    return s;
  }

  /// A PIN that opened nothing may be the locked-upload stop code: the
  /// upload queue checks (and if so wipes itself). Replaced in tests.
  Future<void> Function(Uint8List stopTag) onWrongPin = (tag) => const PlatformOutbox().stopIfMatches(tag);

  Future<VaultSession?> unlockWithPin(String pin) async {
    await lock();
    final s = await (await _container()).unlockWithPin(pin, onNoMatch: onWrongPin);
    _session = s;
    if (s != null) {
      await SecurityChannelService.setVaultOpen(true);
      await _watchRollback(s);
      _opened(s);
    }
    return s;
  }

  Uint8List? _rollbackKey;
  Future<void> _rollbackWrites = Future.value();

  /// Compares the vault with the last commit recorded for it, then records
  /// every commit from now on. Best effort: never stops an unlock.
  Future<void> _watchRollback(VaultSession s) async {
    try {
      final guard = RollbackGuard(
        File(p.join((await _dirProvider()).path, rollbackStateName)),
        crypto.binding,
      );
      final key = await s.rollbackKey();
      _rollbackKey = key;
      final record = s.recordIndex;
      final stored = await guard.recorded(record, key);
      // Warned once; the vault as it is now becomes the reference.
      s.rolledBack = stored != null && s.generation < stored;
      await guard.record(record, key, s.generation);
      _rollbackHook = (gen) {
        _rollbackWrites = _rollbackWrites.then((_) => guard.record(record, key, gen)).catchError((Object _) {});
      };
    } catch (_) {
      // A broken state file mustn't lock anyone out.
    }
  }

  Future<void> lock() async {
    final s = _session;
    _session = null;
    await SecurityChannelService.setVaultOpen(false);
    if (s != null) {
      final closing = s.close();
      _closing = closing;
      if (!_lockEvents.isClosed) _lockEvents.add(null);
      await closing;
      s.onCommitted = null;
      _rollbackHook = null;
      await _rollbackWrites;
      final k = _rollbackKey;
      _rollbackKey = null;
      if (k != null) CryptoPrimitives.wipe(k);
    }
    // A second lock (or an unlock) must still wait for an earlier session to
    // finish its last write before the file is opened again.
    await _closing;
  }

  Future<void> _closing = Future.value();
}
