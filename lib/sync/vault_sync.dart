import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:sync_core/sync_core.dart';

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
    if (uri.scheme == 'http' && !allowHttp && !_isLoopback(uri.host)) {
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
  }) async {
    final uri = normalizeServer(server);
    final api = SyncApi(uri, timeout: const Duration(seconds: 20));
    try {
      final (identity, secret) = await createAccount(
        api,
        invite: (invite ?? '').trim().isEmpty ? null : invite!.trim(),
        recoverySecret: recoverySecret,
      );
      await session.putExtra(_configKey, {'server': uri.toString(), 'identity': identity.toJson()});
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
  }) async {
    final cfg = session.extras[_configKey] as Map?;
    if (cfg == null) throw SyncSetupException('Backup is not set up for this vault.');
    final identity = SyncIdentity.fromJson(Map<String, dynamic>.from(cfg['identity'] as Map));
    final api = SyncApi(Uri.parse(cfg['server'] as String), timeout: const Duration(seconds: 30));
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

      // Items that were backed up before but are gone from the vault now.
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
            : [job['version'] as String?, job['parent'] as String?].whereType<String>().toList();
        if (versions.isNotEmpty) {
          await engine.deleteVersions(id, versions);
          removed++;
        }
        final fresh = await journal.load();
        ((fresh['jobs'] as Map?) ?? {}).remove(id);
        await journal.save(fresh);
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
