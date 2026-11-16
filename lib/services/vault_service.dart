import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../vault/platform_keys.dart';
import 'security_channel_service.dart';
import '../vault/vault_container.dart';

/// App-wide owner of the vault container and the currently unlocked session.
///
/// Nothing outside this class holds vault keys. Locking closes the session,
/// which wipes every key from memory.
class VaultService {
  /// Neutral filename: the cover app is a file manager, so a cache-style
  /// blob in its private storage is unremarkable.
  static const containerName = 'thumbnails.cache';

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
    return s;
  }

  Future<VaultSession?> unlockWithPin(String pin) async {
    await lock();
    final s = await (await _container()).unlockWithPin(pin);
    _session = s;
    if (s != null) await SecurityChannelService.setVaultOpen(true);
    return s;
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
    }
    // A second lock (or an unlock) must still wait for an earlier session to
    // finish its last write before the file is opened again.
    await _closing;
  }

  Future<void> _closing = Future.value();
}
