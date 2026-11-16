import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/unlock_provider.dart';
import '../services/vault_service.dart';
import '../sync/vault_sync.dart';
import '../theme/ui.dart';

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
    return Padding(
      padding: const EdgeInsets.fromLTRB(Ui.gutter + 16, 6, 8, 6),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_when(v.time), style: Ui.data(size: 13, color: v.available ? Ui.ink : Ui.ink3)),
            const SizedBox(height: 2),
            Text(v.available ? state : '$state · removed from the server', style: Ui.detail(color: Ui.ink3)),
          ]),
        ),
        if (v.available && !(v.current && f.inVault))
          TextButton(
            key: Key('restore-version-${f.fileId}-$i'),
            onPressed: _busy ? null : () => _restore(f, v),
            child: const Text('Restore a copy'),
          ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, size: 22),
          tooltip: 'Back',
          onPressed: _busy ? null : () => Navigator.pop(context),
        ),
        title: const Text('Version history'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_progress != null) ...[
            const LinearProgressIndicator(minHeight: 2),
            Padding(
              padding: const EdgeInsets.fromLTRB(Ui.gutter, 10, Ui.gutter, 4),
              child: Text(_progress!, style: Ui.data()),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(Ui.gutter),
              child: Text(_error!, style: Ui.detail(color: Ui.alert)),
            ),
          Expanded(
            child: files == null
                ? const SizedBox.shrink()
                : files.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(Ui.gutter, 32, Ui.gutter, 0),
                        child: Text('Nothing has been backed up yet.', style: Ui.heading()),
                      )
                    : ListView.separated(
                        key: const Key('history-list'),
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: files.length,
                        separatorBuilder: (_, _) => const Divider(indent: Ui.gutter),
                        itemBuilder: (_, k) {
                          final f = files[k];
                          return UiEnter(
                            index: k,
                            child: Theme(
                              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                              child: ExpansionTile(
                                key: Key('history-${f.fileId}'),
                                tilePadding: const EdgeInsets.symmetric(horizontal: Ui.gutter),
                                iconColor: Ui.ink2,
                                collapsedIconColor: Ui.ink3,
                                title: Text(f.title, style: Ui.body()),
                                subtitle: Text(
                                  '${f.versions.length} ${f.versions.length == 1 ? 'version' : 'versions'}'
                                  '${f.deleted ? ' · deleted' : ''}',
                                  style: Ui.data(color: f.deleted ? Ui.signal : Ui.ink3),
                                ),
                                children: [
                                  for (var i = 0; i < f.versions.length; i++) _version(f, f.versions[i], i),
                                  const SizedBox(height: 8),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
