import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../services/vault_service.dart';
import '../vault/vault_container.dart';
import 'vault_sync.dart';

/// What automatic backup is doing, for the Backup screen.
class AutoBackupState {
  final bool running;
  final int done;
  final int total;
  final String? lastError;
  final DateTime? nextAttempt;
  final bool waitingForNetwork;
  const AutoBackupState({
    this.running = false,
    this.done = 0,
    this.total = 0,
    this.lastError,
    this.nextAttempt,
    this.waitingForNetwork = false,
  });
}

/// Backs the open vault up without being asked (milestone M2, mode A of
/// docs/SYNC_DESIGN.md §9): when the vault is unlocked, half a minute after
/// anything in it changes, and as soon as a network appears after a
/// failure, with waits that grow after repeated failures. Only while the
/// vault is open: nothing is uploaded, and no key is kept, once it locks.
///
/// Each vault has its own switch (its encrypted settings), on by default
/// once backup is set up.
class AutoBackup {
  static const String enabledKey = 'sync.auto';
  /// How long after a change, and after unlocking, a backup starts.
  final Duration afterChange;
  final Duration afterUnlock;
  static const List<Duration> backoff = [
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 15),
  ];

  static const EventChannel _network = EventChannel('app.vault/network');

  final VaultService vaults;
  final VaultSync sync;
  final ValueNotifier<AutoBackupState> state = ValueNotifier(const AutoBackupState());

  Timer? _timer;
  StreamSubscription<void>? _commits;
  StreamSubscription<Object?>? _net;
  VaultSession? _session;
  bool _running = false;
  bool _online = true;
  int _failures = 0;

  StreamSubscription<VaultSession>? _unlocks;
  StreamSubscription<void>? _locks;

  AutoBackup({
    required this.vaults,
    VaultSync? sync,
    this.afterChange = const Duration(seconds: 30),
    this.afterUnlock = const Duration(seconds: 5),
  }) : sync = sync ?? VaultSync() {
    _unlocks = vaults.onUnlocked.listen(attach);
    _locks = vaults.onLocked.listen((_) => detach());
  }

  void dispose() {
    detach();
    _unlocks?.cancel();
    _locks?.cancel();
  }

  static bool isEnabled(VaultSession s) => s.extras[enabledKey] as bool? ?? true;

  /// Starts watching [s] (call on unlock).
  void attach(VaultSession s) {
    detach();
    _session = s;
    _failures = 0;
    _commits = vaults.commits.listen((_) => _changed());
    if (Platform.isAndroid) {
      _net = _network.receiveBroadcastStream().listen((e) {
        final online = e is Map && e['online'] == true;
        final wasOffline = !_online;
        _online = online;
        if (online && (wasOffline || state.value.lastError != null)) _schedule(const Duration(seconds: 2));
      }, onError: (Object _) {});
    }
    _schedule(afterUnlock);
  }

  /// Stops (call on lock). A backup in progress fails at its next read.
  void detach() {
    _timer?.cancel();
    _timer = null;
    _commits?.cancel();
    _commits = null;
    _net?.cancel();
    _net = null;
    _session = null;
    state.value = const AutoBackupState();
  }

  bool get _active {
    final s = _session;
    return s != null && s.isOpen && identical(vaults.session, s) && sync.status(s).isConnected && isEnabled(s);
  }

  void _changed() {
    final s = _session;
    if (s == null || _running || !s.isOpen) return;
    // Commits that only save backup progress (the journal) change nothing
    // a backup would send, and a manual run may have caught up already.
    if (VaultSync.isBackedUp(s)) return;
    _schedule(afterChange);
  }

  void _schedule(Duration after) {
    if (!_active) return;
    _timer?.cancel();
    _timer = Timer(after, _run);
    state.value = AutoBackupState(lastError: state.value.lastError, nextAttempt: DateTime.now().add(after));
  }

  /// Runs now (also used by the Backup screen's switch).
  Future<void> runNow() async => _run();

  Future<void> _run() async {
    if (_running || !_active) return;
    final s = _session!;
    if (!_online) {
      state.value = AutoBackupState(lastError: state.value.lastError, waitingForNetwork: true);
      return;
    }
    _running = true;
    state.value = const AutoBackupState(running: true);
    try {
      await sync.backupAll(s, onProgress: (done, total, _) {
        state.value = AutoBackupState(running: true, done: done, total: total);
      });
      _failures = 0;
      state.value = const AutoBackupState();
      // Something changed while it ran: go again.
      if (s.isOpen && !VaultSync.isBackedUp(s)) _schedule(afterChange);
    } catch (e) {
      if (!s.isOpen) return; // locked mid-run: nothing to report
      final wait = backoff[_failures.clamp(0, backoff.length - 1)];
      _failures++;
      final network = e is SocketException || e is TimeoutException || e is HandshakeException || e is http.ClientException;
      state.value = AutoBackupState(
        lastError: network ? "Couldn't reach the server." : 'Backup failed: $e',
        nextAttempt: DateTime.now().add(wait),
        waitingForNetwork: network && !_online,
      );
      _timer?.cancel();
      _timer = Timer(wait, _run);
    } finally {
      _running = false;
    }
  }

  /// Turns automatic backup on or off for this vault.
  Future<void> setEnabled(VaultSession s, bool on) async {
    await s.putExtra(enabledKey, on);
    if (on) {
      _schedule(const Duration(seconds: 1));
    } else {
      _timer?.cancel();
      state.value = const AutoBackupState();
    }
  }
}
