import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:sync_core/sync_core.dart';
import 'package:uuid/uuid.dart';

import '../models/vault_item.dart';
import '../vault/vault_container.dart';
import '../vault/vault_index.dart';

/// Reads one vault item for the sync engine, decrypting only in memory.
/// Nothing is written to disk in the clear in order to be backed up.
class VaultEntrySource implements SyncSource {
  final VaultSession session;
  final IndexEntry entry;
  VaultEntrySource(this.session, this.entry);

  @override
  Stream<Uint8List> openRead() => session.read(entry);

  @override
  Future<Uint8List> readRange(int offset, int length) => session.readRange(entry, offset, length);
}

/// The engine's progress journal, kept inside the vault's encrypted index.
class VaultJournalStore implements JournalStore {
  static const String key = 'sync.journal';
  final VaultSession session;
  VaultJournalStore(this.session);

  @override
  Future<Map<String, dynamic>> load() async =>
      Map<String, dynamic>.from((session.extras[key] as Map?) ?? const {});

  @override
  Future<void> save(Map<String, dynamic> journal) => session.putExtra(key, journal);
}

class SyncStatus {
  final String? server;
  final String? account;
  final DateTime? lastBackup;
  final int lastItemCount;
  const SyncStatus({this.server, this.account, this.lastBackup, this.lastItemCount = 0});
  bool get isConnected => server != null && account != null;
}

class BackupSummary {
  final int total;
  final int uploaded;
  final int unchanged;
  final int removed;
  final int payloadBytes;
  final int wireBytes;
  final int retries;
  final Duration elapsed;
  const BackupSummary({
    required this.total,
    required this.uploaded,
    required this.unchanged,
    required this.removed,
    required this.payloadBytes,
    required this.wireBytes,
    required this.retries,
    required this.elapsed,
  });
}

class RestoreSummary {
  final int restored;
  final int alreadyHere;
  final List<String> failed;
  const RestoreSummary(this.restored, this.alreadyHere, this.failed);
}

/// A device of the backup account, for the Backup screen.
class BackupDevice {
  final String id;
  final DateTime added;
  final DateTime? revoked;
  final bool isThisPhone;
  const BackupDevice(this.id, this.added, this.revoked, this.isThisPhone);
}

/// One version of a backed-up file (see [VaultSync.history]).
class BackupVersionInfo {
  final String version;
  final String manifestId;

  /// When it was backed up, and when it stopped being current (replaced by
  /// a newer version, or deleted). The phone's clock wrote both.
  final DateTime time;
  final DateTime? retired;
  final bool deleted;

  /// Still on the server: not removed when space was freed.
  final bool available;

  const BackupVersionInfo(this.version, this.manifestId, this.time, this.retired, this.deleted, this.available);

  bool get current => retired == null;
}

/// A file the backup has seen, with its versions newest first.
class BackupFileHistory {
  final String fileId;
  final String title;

  /// The vault still holds this file.
  final bool inVault;
  final List<BackupVersionInfo> versions;
  const BackupFileHistory(this.fileId, this.title, this.inVault, this.versions);

  bool get deleted => versions.first.deleted;
  DateTime get lastChange => versions.first.retired ?? versions.first.time;
}

class SyncSetupException implements Exception {
  final String message;

  /// The underlying error, for logs and tests. Not shown to the user.
  final Object? cause;
  SyncSetupException(this.message, [this.cause]);
  @override
  String toString() => message;
}

/// True for "the network isn't working" errors, as opposed to bugs.
bool _isNetworkError(Object e) =>
    e is SocketException || e is TimeoutException || e is HandshakeException || e is HttpException || e is http.ClientException;

/// Backs a vault up to a sync server the user chooses.
///
/// Everything is encrypted on the phone with keys the server never sees.
/// The account, device key and progress journal live inside the vault's
/// encrypted index, so they exist only while that vault is unlocked, and a
/// decoy vault knows nothing about the real vault's backup.
class VaultSync {
  static const String _configKey = 'sync.config';
  static const String _lastKey = 'sync.last';

  /// Plain http:// is refused in release builds, except to this phone's
  /// own loopback address (a server reached through a USB tunnel such as
  /// `adb reverse`), where nothing crosses a network. Debug builds allow it
  /// anywhere for testing. Android's network policy matches this.
  static const bool _allowHttp = !bool.fromEnvironment('dart.vm.product');

  static bool _isLoopback(String host) =>
      host == '127.0.0.1' || host == 'localhost' || host == '::1' || host == '[::1]';

  // ── Tor ──

  /// Orbot's HTTP proxy (CONNECT for https, absolute URLs for http). With
  /// it the server never sees the phone's address, and `.onion` servers work.
  static String torProxyHost = '127.0.0.1';
  static int torProxyPort = 8118;
  static const String _torKey = 'sync.tor';

  static bool usesTor(VaultSession s) => s.extras[_torKey] == true;

  Future<void> setTor(VaultSession s, bool on) => s.putExtra(_torKey, on ? true : null);

  /// Whether Orbot's proxy is up.
  static Future<bool> torAvailable() async {
    try {
      final socket = await Socket.connect(torProxyHost, torProxyPort, timeout: const Duration(seconds: 2));
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// An API client, through Tor if [tor]; Tor is slower, so it waits longer.
  static SyncApi _api(Uri server, {required bool tor, Duration timeout = const Duration(seconds: 30)}) {
    if (!tor) return SyncApi(server, timeout: timeout);
    final client = HttpClient()..findProxy = (_) => 'PROXY $torProxyHost:$torProxyPort';
    return SyncApi(server, client: IOClient(client), timeout: timeout * 3);
  }

  /// One backup operation at a time per vault (automatic and manual runs,
  /// restores, starting over): they share the vault's progress journal.
  static final Expando<Future<void>> _queue = Expando();

  /// The vault's [fingerprint] at its last complete backup.
  static final Expando<String> _clean = Expando();

  static Future<T> _exclusive<T>(VaultSession s, Future<T> Function() op) {
    final previous = _queue[s] ?? Future<void>.value();
    final done = Completer<void>();
    _queue[s] = done.future;
    return previous.then((_) => op()).whenComplete(done.complete);
  }

  /// Items, sizes, titles and edit times: what a backup has to catch up on.
  /// (Saving backup progress doesn't change it.)
  static String fingerprint(VaultSession s) => [
        for (final e in s.entries)
          '${e.item.id}:${e.item.updatedAt.millisecondsSinceEpoch}:${e.byteLength}:${e.item.title}',
      ].join('|');

  /// Whether nothing changed since the last complete backup of [s].
  static bool isBackedUp(VaultSession s) => _clean[s] == fingerprint(s);

  SyncStatus status(VaultSession session) {
    final extras = session.extras;
    final cfg = extras[_configKey] as Map?;
    if (cfg == null) return const SyncStatus();
    final last = extras[_lastKey] as Map?;
    return SyncStatus(
      server: cfg['server'] as String?,
      account: (cfg['identity'] as Map?)?['account'] as String?,
      lastBackup: last == null ? null : DateTime.tryParse(last['at'] as String? ?? ''),
      lastItemCount: (last?['items'] as int?) ?? 0,
    );
  }

  static Uri normalizeServer(String input, {bool allowHttp = _allowHttp}) {
    var text = input.trim();
    if (text.isEmpty) throw SyncSetupException('Enter the server address.');
    if (!text.contains('://')) text = 'https://$text';
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) throw SyncSetupException('That address is not valid.');
    // An onion service is end-to-end encrypted by Tor itself.
    if (uri.scheme == 'http' && !allowHttp && !_isLoopback(uri.host) && !uri.host.endsWith('.onion')) {
      throw SyncSetupException('Use an https:// address. Plain http:// would expose who you are talking to.');
    }
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw SyncSetupException('The address must start with https://');
    }
    return uri.replace(path: uri.path.isEmpty ? '/' : uri.path);
  }

  /// Shows a 32-byte recovery secret as 16 groups of four characters.
  static String formatRecoverySecret(Uint8List secret) {
    final h = hex(secret);
    return [for (var i = 0; i < h.length; i += 4) h.substring(i, i + 4)].join(' ');
  }

  /// A new 32-byte recovery secret. Show it ([formatRecoverySecret]) and
  /// have the user confirm it *before* calling [connect] with it, so an
  /// account never exists without a recovery secret the user has.
  static Uint8List newRecoverySecret() => randomBytes(32);

  /// Creates an account on [server] for this vault, using [recoverySecret],
  /// and stores the device's identity inside the vault. The recovery secret
  /// is never stored on the phone. Returns it formatted.
  Future<String> connect(
    VaultSession session, {
    required String server,
    String? invite,
    required Uint8List recoverySecret,
    bool? tor,
  }) async {
    final uri = normalizeServer(server);
    final viaTor = tor ?? usesTor(session);
    final api = _api(uri, tor: viaTor, timeout: const Duration(seconds: 20));
    try {
      final (identity, secret) = await createAccount(
        api,
        invite: (invite ?? '').trim().isEmpty ? null : invite!.trim(),
        recoverySecret: recoverySecret,
      );
      await session.putExtras({
        _configKey: {'server': uri.toString(), 'identity': identity.toJson()},
        _torKey: viaTor ? true : null,
      });
      return formatRecoverySecret(secret);
    } on ApiException catch (e) {
      if (e.status == 403) throw SyncSetupException('The server refused that invite code.');
      throw SyncSetupException('The server answered with an error (${e.status}).');
    } on SyncSetupException {
      rethrow;
    } catch (e) {
      if (_isNetworkError(e)) {
        throw SyncSetupException('Could not reach the server. Check the address and your connection.', e);
      }
      // Anything else is a fault on our side; don't dress it up as a network problem.
      throw SyncSetupException('Backup could not be set up on this phone (${e.runtimeType}).', e);
    } finally {
      api.close();
    }
  }

  /// Parses a recovery code as shown by [formatRecoverySecret] (spaces and
  /// case don't matter). Null if it isn't one.
  static Uint8List? parseRecoverySecret(String text) {
    final h = text.replaceAll(RegExp(r'[\s-]'), '').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(h)) return null;
    return Uint8List.fromList([for (var i = 0; i < 64; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);
  }

  SyncIdentity _identity(VaultSession session) {
    final cfg = session.extras[_configKey] as Map?;
    if (cfg == null) throw SyncSetupException('Backup is not set up for this vault.');
    return SyncIdentity.fromJson(Map<String, dynamic>.from(cfg['identity'] as Map));
  }

  Uri _server(VaultSession session) => Uri.parse((session.extras[_configKey] as Map)['server'] as String);

  Future<SyncEngine> _engine(SyncApi api, SyncIdentity identity, VaultSession session) async {
    await useIdentity(api, identity);
    return SyncEngine.create(
      api: api,
      keys: await identity.keys(),
      journal: VaultJournalStore(session),
      retry: const RetryPolicy(maxAttempts: 8, initialBackoff: Duration(milliseconds: 500), maxBackoff: Duration(seconds: 8)),
    );
  }

  /// New phone (or a reinstalled app): finds the backup account [recoverySecret]
  /// opens on [server], registers this phone as a device, and restores every
  /// file into [session], streaming each straight into the vault. From
  /// then on this vault backs up to that account.
  Future<RestoreSummary> recoverInto(
    VaultSession session, {
    required String server,
    required Uint8List recoverySecret,
    DateTime? asOf,
    bool tor = false,
    void Function(int done, int total, String title)? onProgress,
  }) async {
    final uri = normalizeServer(server);
    final api = _api(uri, tor: tor);
    try {
      final accounts = await findAccounts(api, recoverySecret);
      if (accounts.isEmpty) {
        throw SyncSetupException('No backup on that server opens with this recovery code.');
      }
      // Normally one; after "start over" the old one is closed. Use the
      // newest (the server lists them oldest first).
      final identity = await recoverAccess(api, accounts.last, recoverySecret);
      await session.putExtras({
        _configKey: {'server': uri.toString(), 'identity': identity.toJson()},
        _torKey: tor ? true : null,
      });
      return await _exclusive(session, () => _restore(api, identity, session, asOf: asOf, onProgress: onProgress));
    } on ApiException catch (e) {
      throw SyncSetupException('The server answered with an error (${e.status}).', e);
    } on SyncSetupException {
      rethrow;
    } catch (e) {
      if (_isNetworkError(e)) throw SyncSetupException('Could not reach the server. Check the address and your connection.', e);
      rethrow;
    } finally {
      api.close();
    }
  }

  /// Restores files from this vault's backup that aren't in the vault (for
  /// example deleted by mistake), optionally as the backup was at [asOf],
  /// or ignoring what [excludeDevices] wrote.
  Future<RestoreSummary> restoreMissing(
    VaultSession session, {
    DateTime? asOf,
    Set<String> excludeDevices = const {},
    void Function(int done, int total, String title)? onProgress,
  }) async {
    final identity = _identity(session);
    final api = _api(_server(session), tor: usesTor(session), timeout: const Duration(seconds: 30));
    try {
      return await _exclusive(
        session,
        () => _restore(api, identity, session, asOf: asOf, excludeDevices: excludeDevices, onProgress: onProgress),
      );
    } finally {
      api.close();
    }
  }

  Future<RestoreSummary> _restore(
    SyncApi api,
    SyncIdentity identity,
    VaultSession session, {
    DateTime? asOf,
    Set<String> excludeDevices = const {},
    void Function(int done, int total, String title)? onProgress,
  }) async {
    final engine = await _engine(api, identity, session);
    final live = await engine.liveFiles(asOf: asOf, excludeDevices: excludeDevices);
    final have = {for (final e in session.entries) e.item.id};
    var restored = 0, already = 0;
    final failed = <String>[];
    for (var i = 0; i < live.length; i++) {
      final f = live[i];
      if (have.contains(f.fileId)) {
        already++;
        continue;
      }
      try {
        final m = await engine.manifestOf(f.manifestId);
        final meta = Map<String, dynamic>.from(m.meta);
        final title = meta['title'] as String? ?? f.fileId;
        onProgress?.call(i, live.length, title);
        final entry = await _import(engine, session, m, VaultItem.fromMap({...meta, 'id': f.fileId, 'content': null}));
        // Mark it as backed up already, so it isn't uploaded again.
        final j = await VaultJournalStore(session).load();
        final jobs = ((j['jobs'] as Map?) ?? {}).cast<String, dynamic>();
        jobs[f.fileId] = {
          'version': f.version,
          'parent': null,
          'size': m.size,
          'mac': m.mac,
          'meta': _metaFor(entry),
          'state': 'committed',
        };
        j['jobs'] = jobs;
        await VaultJournalStore(session).save(j);
        restored++;
      } catch (e) {
        if (!session.isOpen) rethrow;
        failed.add(f.fileId);
      }
    }
    onProgress?.call(live.length, live.length, '');
    return RestoreSummary(restored, already, failed);
  }

  /// Streams [m]'s content into the vault as [base] (a note's text goes in
  /// the item itself), each piece checked on the way.
  Future<IndexEntry> _import(SyncEngine engine, VaultSession session, Manifest m, VaultItem base) async {
    if (m.meta['kind'] == 'note') {
      final bytes = BytesBuilder(copy: false);
      await for (final part in engine.contentOf(m)) {
        bytes.add(part);
      }
      await session.upsertItem(base.copyWith(content: utf8.decode(bytes.takeBytes())));
      return session.entryById(base.id)!;
    }
    final it = StreamIterator(engine.contentOf(m));
    var pending = Uint8List(0);
    Future<Uint8List> read(int max) async {
      if (pending.isEmpty) {
        if (!await it.moveNext()) return Uint8List(0);
        pending = it.current;
      }
      final n = pending.length < max ? pending.length : max;
      final out = Uint8List.sublistView(pending, 0, n);
      pending = Uint8List.sublistView(pending, n);
      return out;
    }

    try {
      return await session.importStream(m.size, base.copyWith(fileSizeBytes: m.size), read);
    } finally {
      await it.cancel();
    }
  }

  /// Every file this vault's backup has seen, with its versions: the
  /// current one, older ones, and deleted files, as long as the server
  /// keeps them (see [freeUpSpace]). Newest change first.
  Future<List<BackupFileHistory>> history(
    VaultSession session, {
    void Function(int done, int total, String title)? onProgress,
  }) async {
    final identity = _identity(session);
    final api = _api(_server(session), tor: usesTor(session), timeout: const Duration(seconds: 30));
    try {
      return await _exclusive(session, () async {
        final engine = await _engine(api, identity, session);
        final all = await engine.history();
        final gone = (await api.missing([
          for (final vs in all.values)
            for (final v in vs) v.manifestId,
        ])).toSet();
        final out = <BackupFileHistory>[];
        var i = 0;
        for (final MapEntry(key: fileId, value: versions) in all.entries) {
          final here = session.entryById(fileId);
          var title = here?.item.title;
          if (title == null) {
            // Gone from the vault: the newest manifest still on the server.
            for (final v in versions.reversed) {
              if (gone.contains(v.manifestId)) continue;
              try {
                title = (await engine.manifestOf(v.manifestId)).meta['title'] as String?;
              } catch (_) {}
              if (title != null) break;
            }
          }
          onProgress?.call(i++, all.length, title ?? '');
          out.add(BackupFileHistory(fileId, title ?? 'Removed from the server', here != null, [
            for (final v in versions.reversed)
              BackupVersionInfo(v.version, v.manifestId, v.time, v.retired, v.deleted, !gone.contains(v.manifestId)),
          ]));
        }
        onProgress?.call(all.length, all.length, '');
        out.sort((a, b) => b.lastChange.compareTo(a.lastChange));
        return out;
      });
    } on ApiException catch (e) {
      throw SyncSetupException('The server answered with an error (${e.status}).', e);
    } finally {
      api.close();
    }
  }

  /// Brings [version] of [file] back into the vault as a new item next to
  /// whatever is there, titled with the version's date. Returns that title.
  Future<String> restoreVersion(VaultSession session, BackupFileHistory file, BackupVersionInfo version) async {
    final identity = _identity(session);
    final api = _api(_server(session), tor: usesTor(session), timeout: const Duration(seconds: 30));
    try {
      return await _exclusive(session, () async {
        final engine = await _engine(api, identity, session);
        final m = await engine.manifestOf(version.manifestId);
        final meta = Map<String, dynamic>.from(m.meta);
        final t = version.time.toLocal();
        String two(int n) => n.toString().padLeft(2, '0');
        final title = '${meta['title'] ?? file.title} '
            '(${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}.${two(t.minute)})';
        final now = DateTime.now().toIso8601String();
        await _import(engine, session, m, VaultItem.fromMap({
          ...meta,
          'id': const Uuid().v4(),
          'title': title,
          'createdAt': now,
          'updatedAt': now,
          'content': null,
        }));
        return title;
      });
    } on ApiException catch (e) {
      if (e.status == 404) throw SyncSetupException('That version is no longer on the server.', e);
      throw SyncSetupException('The server answered with an error (${e.status}).', e);
    } on IntegrityException catch (e) {
      throw SyncSetupException("That version didn't pass its integrity check, so it wasn't restored.", e);
    } finally {
      api.close();
    }
  }

  static const String retentionKey = 'sync.retention';

  /// How long replaced and deleted versions stay on the server before
  /// [freeUpSpace] may remove them (default 30 days).
  static int retentionDays(VaultSession s) => (s.extras[retentionKey] as int?) ?? 30;
  Future<void> setRetentionDays(VaultSession s, int days) => s.putExtra(retentionKey, days == 30 ? null : days);

  /// Deletes from the server what only versions replaced or deleted more
  /// than [retentionDays] ago needed. Needs the recovery code: the server
  /// keeps everything otherwise, so a taken phone can't erase the backup.
  Future<PruneReport> freeUpSpace(VaultSession session, Uint8List recoverySecret) async {
    final identity = _identity(session);
    final api = _api(_server(session), tor: usesTor(session), timeout: const Duration(seconds: 30));
    try {
      return await _exclusive(session, () async {
        final rk = await RecoveryKeys.fromSecret(recoverySecret);
        final slot = await recoverySlot(api, identity.account, rk);
        final engine = await _engine(api, identity, session);
        return engine.prune(retention: Duration(days: retentionDays(session)), recovery: rk.signing, keyIndex: slot);
      });
    } on ApiException catch (e) {
      if (e.status == 401) throw SyncSetupException("That recovery code doesn't match this backup.", e);
      throw SyncSetupException('The server answered with an error (${e.status}).', e);
    } on IntegrityException catch (e) {
      if (e.message.contains('recovery')) throw SyncSetupException("That recovery code doesn't match this backup.", e);
      throw SyncSetupException("The backup's history didn't pass its checks, so nothing was removed.", e);
    } finally {
      api.close();
    }
  }

  /// The backup account's devices, this phone marked.
  Future<List<BackupDevice>> devices(VaultSession session) async {
    final identity = _identity(session);
    final api = _api(_server(session), tor: usesTor(session), timeout: const Duration(seconds: 20));
    try {
      await useIdentity(api, identity);
      return [
        for (final d in await api.devices()) BackupDevice(d.id, d.created, d.revoked, d.id == identity.device),
      ];
    } finally {
      api.close();
    }
  }

  /// Revokes [deviceIds] (never this phone) with the recovery code.
  Future<void> revoke(VaultSession session, Uint8List recoverySecret, Iterable<String> deviceIds) async {
    final identity = _identity(session);
    final others = deviceIds.where((d) => d != identity.device).toList();
    final api = _api(_server(session), tor: usesTor(session), timeout: const Duration(seconds: 20));
    try {
      await revokeDevices(api, identity.account, recoverySecret, others);
    } on ApiException catch (e) {
      if (e.status == 401) throw SyncSetupException("That recovery code doesn't match this backup.", e);
      rethrow;
    } on IntegrityException catch (e) {
      throw SyncSetupException("That recovery code doesn't match this backup.", e);
    } finally {
      api.close();
    }
  }

  /// After a phone was taken: a fresh account (same recovery code, new keys
  /// the taken phone never had), everything uploaded again, and the old
  /// account, which the taken phone could reach, closed and emptied.
  Future<BackupSummary> startOver(
    VaultSession session,
    Uint8List recoverySecret, {
    String? invite,
    void Function(int done, int total, String title)? onProgress,
  }) async {
    final server = _server(session);
    final api = _api(server, tor: usesTor(session), timeout: const Duration(seconds: 20));
    try {
      // An earlier attempt that got as far as the new account: carry on
      // with it rather than making another.
      var retiring = (session.extras[_retireKey] as Map?)?['account'] as String?;
      if (retiring == null) {
        final old = _identity(session);
        try {
          // Check the code against the old account before anything changes.
          await recoverySlot(api, old.account, await RecoveryKeys.fromSecret(recoverySecret));
        } on ApiException catch (e) {
          if (e.status == 401) throw SyncSetupException("That recovery code doesn't match this backup.", e);
          rethrow;
        } on IntegrityException catch (e) {
          throw SyncSetupException("That recovery code doesn't match this backup.", e);
        }
        retiring = old.account;
        await session.putExtra(_retireKey, {'account': retiring});
        await connect(session, server: server.toString(), invite: invite, recoverySecret: recoverySecret);
        await session.putExtra(VaultJournalStore.key, null);
      }
      final summary = await backupAll(session, onProgress: onProgress);
      try {
        await closeAccount(api, retiring, recoverySecret);
      } on ApiException catch (e) {
        if (e.status != 404) rethrow; // 404: already closed
      }
      await session.putExtra(_retireKey, null);
      return summary;
    } finally {
      api.close();
    }
  }

  static const String _retireKey = 'sync.retire';

  /// An interrupted "start over" is waiting to finish (its old account
  /// still open).
  bool startOverPending(VaultSession session) => session.extras[_retireKey] != null;

  /// Forgets the backup account on this phone. Nothing on the server is
  /// deleted.
  Future<void> disconnect(VaultSession session) async {
    await session.putExtra(VaultJournalStore.key, null);
    await session.putExtra(_lastKey, null);
    await session.putExtra(_configKey, null);
  }

  /// What a restore needs to rebuild the item, minus its content.
  static Map<String, dynamic> _metaFor(IndexEntry entry) {
    final VaultItem item = entry.item;
    final map = item.toMap()
      ..remove('content')
      ..remove('thumbnailBase64')
      ..remove('encryptedFilePath')
      ..remove('isDecoy');
    map['kind'] = entry.fileKey != null ? 'file' : 'note';
    map['mime'] = item.mimeType;
    return map;
  }

  /// Backs up every item in the open vault: new and changed items are
  /// uploaded, unchanged ones are skipped, and items deleted from the vault
  /// are marked deleted on the server.
  Future<BackupSummary> backupAll(
    VaultSession session, {
    void Function(int done, int total, String title)? onProgress,
  }) =>
      _exclusive(session, () async {
        final before = fingerprint(session);
        final summary = await _backupAll(session, onProgress: onProgress);
        _clean[session] = before;
        return summary;
      });

  Future<BackupSummary> _backupAll(
    VaultSession session, {
    void Function(int done, int total, String title)? onProgress,
  }) async {
    final cfg = session.extras[_configKey] as Map?;
    if (cfg == null) throw SyncSetupException('Backup is not set up for this vault.');
    final identity = SyncIdentity.fromJson(Map<String, dynamic>.from(cfg['identity'] as Map));
    final api = _api(Uri.parse(cfg['server'] as String), tor: usesTor(session));
    final clock = Stopwatch()..start();
    try {
      await useIdentity(api, identity);
      final journal = VaultJournalStore(session);
      final engine = await SyncEngine.create(
        api: api,
        keys: await identity.keys(),
        journal: journal,
        retry: const RetryPolicy(
          maxAttempts: 8,
          initialBackoff: Duration(milliseconds: 500),
          maxBackoff: Duration(seconds: 8),
        ),
      );

      final entries = session.entries;
      var uploaded = 0, unchanged = 0, removed = 0, payload = 0, retries = 0;

      // Items that were backed up before but are gone from the vault now.
      // Done first: when the account is full, uploads fail, and a deletion
      // should still get through.
      final current = {for (final e in entries) e.item.id};
      final j = await journal.load();
      final jobs = ((j['jobs'] as Map?) ?? {}).cast<String, dynamic>();
      for (final id in jobs.keys.toList()) {
        if (current.contains(id)) continue;
        final job = jobs[id] as Map;
        // Committed: that version. Half-sent: the new version may have
        // reached the server's log even though this phone never heard back,
        // so delete it and the version it replaced (whichever is live).
        final versions = job['state'] == 'committed'
            ? [job['version'] as String]
            : [
                job['version'] as String?,
                job['parent'] as String?,
                ...((job['abandoned'] as List?) ?? const []).cast<String?>(),
              ].whereType<String>().toSet().toList();
        if (versions.isNotEmpty) {
          await engine.deleteVersions(id, versions);
          removed++;
        }
        final fresh = await journal.load();
        ((fresh['jobs'] as Map?) ?? {}).remove(id);
        await journal.save(fresh);
      }

      for (var i = 0; i < entries.length; i++) {
        final entry = entries[i];
        final item = entry.item;
        onProgress?.call(i, entries.length, item.title);
        final meta = _metaFor(entry);
        final jobs = ((await journal.load())['jobs'] as Map?) ?? const {};
        final job = jobs[item.id] as Map?;
        if (job != null && job['state'] == 'committed' && jsonEncode(job['meta']) == jsonEncode(meta)) {
          unchanged++;
          continue;
        }
        final SyncSource source = entry.fileKey != null
            ? VaultEntrySource(session, entry)
            : MemorySyncSource(Uint8List.fromList(utf8.encode(item.content ?? '')));
        final report = await engine.backupSource(source, fileId: item.id, meta: meta);
        uploaded++;
        payload += report.payloadBytes;
        retries += report.retries;
      }

      onProgress?.call(entries.length, entries.length, '');
      await session.putExtra(_lastKey, {'at': DateTime.now().toIso8601String(), 'items': entries.length});
      return BackupSummary(
        total: entries.length,
        uploaded: uploaded,
        unchanged: unchanged,
        removed: removed,
        payloadBytes: payload,
        wireBytes: api.bytesSent,
        retries: retries,
        elapsed: clock.elapsed,
      );
    } finally {
      api.close();
    }
  }
}
