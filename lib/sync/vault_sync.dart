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
import 'outbox.dart';
import 'previews.dart';

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

  /// Small copies sent ahead of their originals.
  final int previews;

  /// Originals held back until the phone is on Wi-Fi.
  final int waitingForWifi;

  /// Items sealed into the upload queue because there was no connection;
  /// the phone sends them when a network appears, even while locked.
  final int queued;
  const BackupSummary({
    required this.total,
    required this.uploaded,
    required this.unchanged,
    required this.removed,
    required this.payloadBytes,
    required this.wireBytes,
    required this.retries,
    required this.elapsed,
    this.previews = 0,
    this.waitingForWifi = 0,
    this.queued = 0,
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
  static const String _previewsKey = 'sync.previews';
  static const String _wifiKey = 'sync.wifiOriginals';

  /// Makes the small copies sent first (see [previewsFirst]).
  final PreviewMaker previews;

  /// The queue that uploads while the vault is locked (see [lockedUpload]).
  final Outbox outbox;

  /// How hard to retry over a bad connection before giving up for now.
  final RetryPolicy retry;

  static const RetryPolicy defaultRetry =
      RetryPolicy(maxAttempts: 8, initialBackoff: Duration(milliseconds: 500), maxBackoff: Duration(seconds: 8));

  VaultSync({
    this.previews = const PlatformPreviewMaker(),
    this.outbox = const PlatformOutbox(),
    this.retry = defaultRetry,
  });

  // ─── Uploading while locked ───────────────────────────────────

  static const String _lockedKey = 'sync.locked';
  static Map<String, dynamic> _locked(VaultSession s) => Map<String, dynamic>.from((s.extras[_lockedKey] as Map?) ?? const {});

  /// Whether this vault keeps uploading while it's locked (on by default):
  /// when backup can't reach the server, what it would have sent is sealed
  /// into a queue that the phone sends when a network appears. The phone
  /// holds only a login that can add to the backup, never read or delete.
  static bool lockedUpload(VaultSession s) {
    final c = _locked(s);
    return c['on'] != false && c['stopped'] != true;
  }

  /// The queue was wiped by the emergency stop ("Clear cache" in the cover
  /// app, or the stop code on the lock screen). It stays off until it's
  /// turned on again here.
  static bool lockedUploadStopped(VaultSession s) => _locked(s)['stopped'] == true;

  /// Whether a stop code is set for this vault.
  static bool hasStopCode(VaultSession s) => _locked(s)['tag'] != null;

  Future<void> setLockedUpload(VaultSession s, bool on) async {
    final c = _locked(s);
    if (on) {
      c['on'] = true;
      c.remove('stopped');
    } else {
      c['on'] = false;
      // Wiped now; the next backup sends what it held directly, and turns
      // the login it had off on the server.
      if (await _queueIsMine(s)) await outbox.stop();
    }
    await s.putExtra(_lockedKey, c);
  }

  /// Sets ([code]) or removes (null) the stop code: typed on the lock
  /// screen, it looks like a wrong PIN and wipes the upload queue and its
  /// login. It must open nothing (throws CredentialInUseException).
  Future<void> setStopCode(VaultSession s, String? code) async {
    final c = _locked(s);
    final tag = code == null ? null : await s.stopTag(code);
    if (tag == null) {
      c.remove('tag');
    } else {
      c['tag'] = base64Encode(tag);
    }
    if (await _queueIsMine(s)) await outbox.setStopTag(tag);
    await s.putExtra(_lockedKey, c);
  }

  /// What the queue holds for this vault (null if it isn't this vault's).
  Future<OutboxStatus?> queueStatus(VaultSession s) async {
    final st = await outbox.status();
    final arm = _locked(s)['arm'] as String?;
    return st.armed && arm != null && st.armId == arm ? st : null;
  }

  Future<bool> _queueIsMine(VaultSession s) async => await queueStatus(s) != null;

  /// Whether a new photo, video or recording goes up first as a small copy,
  /// then in full (on by default): on a bad connection the copy is what
  /// arrives. See SYNC_DESIGN §5.
  static bool previewsFirst(VaultSession s) => s.extras[_previewsKey] != false;
  Future<void> setPreviewsFirst(VaultSession s, bool on) => s.putExtra(_previewsKey, on ? null : false);

  /// Whether the full-size originals of those wait for Wi-Fi (off by default).
  static bool originalsOnWifiOnly(VaultSession s) => s.extras[_wifiKey] == true;
  Future<void> setOriginalsOnWifiOnly(VaultSession s, bool on) => s.putExtra(_wifiKey, on ? true : null);

  /// The backup's file id for [itemId]'s preview.
  static String previewId(String itemId) => '$itemId~p';
  static String? _previewOf(String fileId) => fileId.endsWith('~p') ? fileId.substring(0, fileId.length - 2) : null;

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
      retry: retry,
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
    final liveIds = {for (final f in live) f.fileId};
    var restored = 0, already = 0;
    final failed = <String>[];
    for (var i = 0; i < live.length; i++) {
      final f = live[i];
      // A preview comes back only when its original can't.
      final of = _previewOf(f.fileId);
      if (have.contains(f.fileId) || (of != null && (liveIds.contains(of) || have.contains(of)))) {
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
  ///
  /// [offline]: the phone knows there's no network. Then nothing is tried;
  /// if this vault uploads while locked, what's left goes into the queue.
  Future<BackupSummary> backupAll(
    VaultSession session, {
    void Function(int done, int total, String title)? onProgress,
    bool offline = false,
  }) =>
      _exclusive(session, () async {
        final before = fingerprint(session);
        final summary = await _backupAll(session, onProgress: onProgress, offline: offline);
        _clean[session] = before;
        return summary;
      });

  Future<BackupSummary> _backupAll(
    VaultSession session, {
    void Function(int done, int total, String title)? onProgress,
    bool offline = false,
  }) async {
    final cfg = session.extras[_configKey] as Map?;
    if (cfg == null) throw SyncSetupException('Backup is not set up for this vault.');
    final identity = SyncIdentity.fromJson(Map<String, dynamic>.from(cfg['identity'] as Map));
    final api = _api(Uri.parse(cfg['server'] as String), tor: usesTor(session));
    final clock = Stopwatch()..start();
    final journal = VaultJournalStore(session);
    final keys = await identity.keys();
    try {
      if (offline) throw const SocketException('no network');
      await useIdentity(api, identity);
      final engine = await SyncEngine.create(api: api, keys: keys, journal: journal, retry: retry);
      // What was queued for the locked phone goes first, and what arrived
      // of it is settled, before anything is sent directly (the server
      // takes each phone's records in order).
      await _settleQueue(session, api, engine, journal);
      await _keepArmed(session, api, cfg['server'] as String);
      return await _run(session, engine, journal, clock, api, onProgress: onProgress);
    } catch (e) {
      if (!session.isOpen || !isTransient(e) || !lockedUpload(session) || !await _queueIsMine(session)) rethrow;
      // No connection: seal what's left into the queue for the phone to
      // send when a network appears, even while locked.
      final q = QueueSyncApi(outbox, queued: {for (final e in await outbox.entries()) if (!e.log) e.id});
      q.useDevice(identity.account, identity.device, await identity.deviceKey());
      final engine = await SyncEngine.create(api: q, keys: keys, journal: journal, retry: const RetryPolicy(maxAttempts: 1));
      final summary = await _run(session, engine, journal, clock, q, onProgress: onProgress, queue: true);
      await outbox.kick();
      return summary;
    } finally {
      api.close();
    }
  }

  /// Backs up every item through [engine]: deletions, then previews, then
  /// originals. With [queue], into the upload queue: every version and
  /// deletion is marked as queued until the server is seen to have it.
  Future<BackupSummary> _run(
    VaultSession session,
    SyncEngine engine,
    VaultJournalStore journal,
    Stopwatch clock,
    SyncApi api, {
    void Function(int done, int total, String title)? onProgress,
    bool queue = false,
  }) async {
    final entries = session.entries;
    var uploaded = 0, unchanged = 0, removed = 0, payload = 0, retries = 0, queued = 0;

    Future<void> markQueued(String fileId) async {
      if (!queue) return;
      final j = await journal.load();
      ((j['jobs'] as Map?)?[fileId] as Map?)?['queued'] = true;
      await journal.save(j);
      queued++;
    }

    // Items that were backed up before but are gone from the vault now.
    // Done first: when the account is full, uploads fail, and a deletion
    // should still get through.
    final current = {
      for (final e in entries) ...[e.item.id, previewId(e.item.id)],
    };
    final j = await journal.load();
    final jobs = ((j['jobs'] as Map?) ?? {}).cast<String, dynamic>();
    try {
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
        if (queue && versions.isNotEmpty) {
          // Until the server is seen to have the deletion, remember it.
          final qdel = ((fresh['qdel'] as Map?) ?? {}).cast<String, dynamic>();
          qdel[id] = versions;
          fresh['qdel'] = qdel;
          queued++;
        }
        await journal.save(fresh);
      }

      // Never backed up yet: no committed version, and not an edit of one.
      bool firstUpload(Map? job) => job == null || (job['state'] != 'committed' && job['parent'] == null);

      // Previews first: small copies of new photos, videos and recordings.
      var previewsSent = 0, waiting = 0;
      if (previewsFirst(session)) {
        for (var i = 0; i < entries.length; i++) {
          final entry = entries[i];
          if (!previews.wants(entry)) continue;
          final jobs = ((await journal.load())['jobs'] as Map?) ?? const {};
          final pid = previewId(entry.item.id);
          if (!firstUpload(jobs[entry.item.id] as Map?) || (jobs[pid] as Map?)?['state'] == 'committed') continue;
          onProgress?.call(i, entries.length, entry.item.title);
          Preview? p;
          try {
            p = await previews.make(session, entry);
          } catch (_) {
            if (!session.isOpen) rethrow;
            p = null; // no preview, the original goes as usual
          }
          if (p == null) continue;
          try {
            final report = await engine.backupSource(p.source, fileId: pid, meta: {
              ..._metaFor(entry),
              'id': pid,
              'title': '${entry.item.title} (preview)',
              'mimeType': p.mime,
              'mime': p.mime,
              'fileSizeBytes': p.length,
              'role': 'preview',
              'previewOf': entry.item.id,
            });
            previewsSent++;
            payload += report.payloadBytes;
            retries += report.retries;
            await markQueued(pid);
          } finally {
            await p.close();
          }
        }
      }
      // The queue can't know what network it'll be sent over: originals
      // that should wait for Wi-Fi aren't queued at all.
      final holdOriginals = originalsOnWifiOnly(session) && (queue || !await previews.unmetered());

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
        if (holdOriginals && previews.wants(entry) && firstUpload(job)) {
          waiting++;
          continue;
        }
        final SyncSource source = entry.fileKey != null
            ? VaultEntrySource(session, entry)
            : MemorySyncSource(Uint8List.fromList(utf8.encode(item.content ?? '')));
        final report = await engine.backupSource(source, fileId: item.id, meta: meta);
        if (!queue) uploaded++;
        payload += report.payloadBytes;
        retries += report.retries;
        await markQueued(item.id);
      }

      onProgress?.call(entries.length, entries.length, '');
      if (!queue) await session.putExtra(_lastKey, {'at': DateTime.now().toIso8601String(), 'items': entries.length});
      return BackupSummary(
        total: entries.length,
        uploaded: uploaded,
        unchanged: unchanged,
        removed: queue ? 0 : removed,
        payloadBytes: payload,
        wireBytes: api.bytesSent,
        retries: retries,
        elapsed: clock.elapsed,
        previews: queue ? 0 : previewsSent,
        waitingForWifi: waiting,
        queued: queued,
      );
    } on OutboxFull {
      // The queue is full: the rest waits for the next unlock.
      return BackupSummary(
        total: entries.length,
        uploaded: 0,
        unchanged: unchanged,
        removed: 0,
        payloadBytes: payload,
        wireBytes: 0,
        retries: retries,
        elapsed: clock.elapsed,
        queued: queued,
      );
    }
  }

  /// Sends what the queue still holds, directly, in order; then checks
  /// what of everything queued reached the server. A version that didn't
  /// (the queue was wiped, or a record got lost) is backed up again; a
  /// deletion that didn't is sent again.
  Future<void> _settleQueue(VaultSession session, SyncApi api, SyncEngine engine, VaultJournalStore journal) async {
    if (await _queueIsMine(session)) {
      for (final e in await outbox.entries()) {
        final data = await outbox.read(e.name);
        try {
          if (e.log) {
            await api.appendLog(e.counter, data);
          } else {
            await api.putPiece(e.id, data);
          }
        } on ApiException catch (x) {
          if (isTransient(x) || x.status == 401) rethrow;
          final expected = int.tryParse(RegExp(r'"expected"\s*:\s*(\d+)').firstMatch(x.body)?.group(1) ?? '');
          if (!(e.log && x.status == 409 && expected != null && expected > e.counter)) {
            // Refused, or a record before this one is missing: the rest
            // can't follow in order. Drop it all; the check below redoes
            // whatever didn't arrive.
            for (final rest in await outbox.entries()) {
              await outbox.remove(rest.name);
            }
            break;
          }
          // Otherwise it was appended already (an earlier reply was lost).
        }
        await outbox.remove(e.name);
      }
    }
    final j = await journal.load();
    final jobs = ((j['jobs'] as Map?) ?? {}).cast<String, dynamic>();
    final qdel = ((j['qdel'] as Map?) ?? {}).cast<String, dynamic>();
    if (!jobs.values.any((v) => v is Map && v['queued'] == true) && qdel.isEmpty) return;
    final arrived = await engine.syncOwnChain();
    final k = await journal.load();
    final kjobs = ((k['jobs'] as Map?) ?? {}).cast<String, dynamic>();
    for (final id in kjobs.keys.toList()) {
      final job = kjobs[id] as Map;
      if (job['queued'] != true) continue;
      job.remove('queued');
      if (!arrived.puts.contains('$id/${job['version']}')) {
        // Never arrived: plan it again (as an edit of whatever came before).
        job['state'] = 'planned';
        job['meta'] = {'_requeue': true};
      }
    }
    final redo = <String, List<String>>{};
    for (final e in ((k['qdel'] as Map?) ?? {}).cast<String, dynamic>().entries) {
      final versions = (e.value as List).cast<String>();
      if (!versions.any((v) => arrived.dels.contains('${e.key}/$v'))) redo[e.key] = versions;
    }
    k.remove('qdel');
    await journal.save(k);
    for (final e in redo.entries) {
      await engine.deleteVersions(e.key, e.value);
    }
  }

  /// Keeps the queue armed with a fresh upload-only login while locked
  /// upload is on; notices when it was stopped; turns the login off on the
  /// server when it's no longer used. Needs the network.
  Future<void> _keepArmed(VaultSession session, SyncApi api, String server) async {
    final c = _locked(session);
    final st = await outbox.status();
    if (!st.supported) return;
    final arm = c['arm'] as String?;
    final mine = arm != null && st.armed && st.armId == arm;
    if (!lockedUpload(session)) {
      if (mine) await outbox.stop();
      if (arm != null) {
        await api.revokeUploadTokens();
        c.remove('arm');
        await session.putExtra(_lockedKey, c);
      }
      return;
    }
    if (st.armed && !mine) return; // another vault's queue: left alone
    if (!st.armed && arm != null) {
      // It was armed and is gone: the emergency stop. Off until turned on
      // again here, and the login it had stops working.
      await api.revokeUploadTokens();
      c
        ..['on'] = false
        ..['stopped'] = true
        ..remove('arm');
      await session.putExtra(_lockedKey, c);
      return;
    }
    final tag = c['tag'] == null ? null : base64Decode(c['tag'] as String);
    if (!mine || st.expires == null || st.expires!.isBefore(DateTime.now().add(const Duration(days: 7)))) {
      final t = await api.uploadToken();
      final id = arm ?? hex(randomBytes(16));
      await outbox.arm(server: server, tor: usesTor(session), token: t.token, expires: t.expires, armId: id, stopTag: tag);
      if (arm == null) {
        c['arm'] = id;
        await session.putExtra(_lockedKey, c);
      }
    } else if (tag != null && !st.hasStopCode) {
      await outbox.setStopTag(tag);
    }
  }
}
