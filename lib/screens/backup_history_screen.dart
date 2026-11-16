import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/unlock_provider.dart';
import '../services/vault_service.dart';
import '../sync/vault_sync.dart';
import '../theme/app_fonts.dart';

/// Every file this vault's backup has seen, with its versions: a deleted
/// file or an older version can be brought back as a copy.
class BackupHistoryScreen extends StatefulWidget {
  const BackupHistoryScreen({super.key});

  @override
  State<BackupHistoryScreen> createState() => _BackupHistoryScreenState();
}

class _BackupHistoryScreenState extends State<BackupHistoryScreen> {
  final VaultSync _sync = VaultSync();
  List<BackupFileHistory>? _files;
  String? _error;
  String? _progress;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// Runs [op] with the vault kept from auto-locking, showing progress.
  Future<T?> _run<T>(String start, Future<T> Function(void Function(int, int, String)) op) async {
    final vault = context.read<VaultService>();
    final unlock = context.read<UnlockProvider>();
    setState(() {
      _busy = true;
      _error = null;
      _progress = start;
    });
    try {
      return await vault.whileBusy(() => op((done, total, _) {
            unlock.onUserActivity();
            if (mounted && total > 0) setState(() => _progress = '$start ${(done * 100 / total).round()}%');
          }));
    } catch (e) {
      if (mounted) setState(() => _error = e is SyncSetupException ? e.message : 'It stopped before it finished. ($e)');
      return null;
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _load() async {
    final session = context.read<VaultService>().session;
    if (session == null) return;
    final files = await _run('Reading the backup…', (p) => _sync.history(session, onProgress: p));
    if (files != null && mounted) setState(() => _files = files);
  }

  Future<void> _restore(BackupFileHistory f, BackupVersionInfo v) async {
    final session = context.read<VaultService>().session;
    if (session == null || _busy) return;
    final title = await _run('Restoring…', (_) => _sync.restoreVersion(session, f, v));
    if (title != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Restored as “$title”.')));
      await _load();
    }
  }

  static String _when(DateTime t) {
    final l = t.toLocal();
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.day} ${months[l.month - 1]} ${l.year}, ${two(l.hour)}:${two(l.minute)}';
  }

  Widget _version(BackupFileHistory f, BackupVersionInfo v, int i) {
    final state = v.current
        ? 'current'
        : v.deleted
            ? 'deleted ${_when(v.retired!)}'
            : 'replaced ${_when(v.retired!)}';
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      title: Text(_when(v.time), style: AppFonts.outfit(fontSize: 13, color: v.available ? Colors.white : Colors.white38)),
      subtitle: Text(
        v.available ? state : '$state · removed from the server',
        style: AppFonts.outfit(fontSize: 11, color: Colors.white38),
      ),
      trailing: v.available && !(v.current && f.inVault)
          ? TextButton(
              key: Key('restore-version-${f.fileId}-$i'),
              onPressed: _busy ? null : () => _restore(f, v),
              child: const Text('Restore a copy'),
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    return Scaffold(
      backgroundColor: const Color(0xFF090D16),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white70, size: 18),
          onPressed: _busy ? null : () => Navigator.pop(context),
        ),
        title: Text('Version history', style: AppFonts.outfit(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
      ),
      body: Column(
        children: [
          if (_progress != null) ...[
            const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_progress!, style: AppFonts.outfit(fontSize: 12, color: Colors.white54)),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!, style: AppFonts.outfit(fontSize: 13, color: const Color(0xFFFB7185))),
            ),
          Expanded(
            child: files == null
                ? const SizedBox.shrink()
                : files.isEmpty
                    ? Center(
                        child: Text('Nothing has been backed up yet.',
                            style: AppFonts.outfit(fontSize: 14, color: Colors.white54)),
                      )
                    : ListView(
                        key: const Key('history-list'),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        children: [
                          for (final f in files)
                            ExpansionTile(
                              key: Key('history-${f.fileId}'),
                              iconColor: Colors.white54,
                              collapsedIconColor: Colors.white38,
                              title: Text(f.title, style: AppFonts.outfit(fontSize: 14, color: Colors.white)),
                              subtitle: Text(
                                '${f.versions.length} ${f.versions.length == 1 ? 'version' : 'versions'}'
                                '${f.deleted ? ' · deleted' : ''}',
                                style: AppFonts.outfit(fontSize: 12, color: f.deleted ? const Color(0xFFFBBF24) : Colors.white38),
                              ),
                              children: [
                                for (var i = 0; i < f.versions.length; i++) _version(f, f.versions[i], i),
                              ],
                            ),
                        ],
                      ),
          ),
        ],
      ),
    );
  }
}
