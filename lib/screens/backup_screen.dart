import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/unlock_provider.dart';
import '../util/format.dart';
import '../services/vault_service.dart';
import '../sync/auto_backup.dart';
import '../sync/outbox.dart';
import '../sync/vault_sync.dart';
import '../theme/app_fonts.dart';
import '../vault/vault_container.dart';
import 'backup_history_screen.dart';
import '../theme/ui.dart';

/// Backup for the vault that is currently open: connect it to a server,
/// then back it up. Files are encrypted on the phone; the server never
/// receives a key, a file name or anything readable.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final VaultSync _sync = VaultSync();
  final TextEditingController _server = TextEditingController();
  final TextEditingController _invite = TextEditingController();

  bool _busy = false;
  bool _tor = false;
  String? _error;
  String? _progress;
  double? _progressValue;
  BackupSummary? _lastRun;

  @override
  void dispose() {
    _server.dispose();
    _invite.dispose();
    super.dispose();
  }

  /// A code the user has confirmed but whose account couldn't be created
  /// yet (no signal). Kept in memory only, so trying again doesn't need a
  /// new code; gone when this screen closes or the vault locks.
  Uint8List? _confirmedSecret;

  Future<void> _connect() async {
    final session = context.read<VaultService>().session;
    if (session == null || _busy) return;
    FocusScope.of(context).unfocus();
    setState(() => _error = null);
    try {
      VaultSync.normalizeServer(_server.text);
    } on SyncSetupException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    // The code comes first: shown, written down and confirmed before the
    // account exists. Nothing is created if the user backs out, and the
    // code is never stored on the phone.
    final vault = context.read<VaultService>();
    if (_tor && !await VaultSync.torAvailable()) {
      if (mounted) setState(() => _error = "Orbot isn't running. Start Orbot (the Tor app), then connect again.");
      return;
    }
    if (!mounted) return;
    var secret = _confirmedSecret;
    if (secret == null) {
      final fresh = VaultSync.newRecoverySecret();
      if (!await _confirmRecoverySecret(VaultSync.formatRecoverySecret(fresh)) || !mounted) return;
      secret = fresh;
      _confirmedSecret = fresh;
    }
    setState(() => _busy = true);
    try {
      // Busy: the inactivity lock waits for the account to be created.
      await vault.whileBusy(
            () => _sync.connect(session, server: _server.text, invite: _invite.text, recoverySecret: secret!, tor: _tor),
          );
      _confirmedSecret = null;
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  /// Shows the code and asks for its last group back. True once confirmed.
  Future<bool> _confirmRecoverySecret(String code) async {
    // Copying 64 characters onto paper takes longer than the inactivity
    // timeout, and writing produces no touches: hold that lock meanwhile.
    final ok = await context.read<UnlockProvider>().holdingInactivityLock(
          () => showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (_) => _RecoveryCodeDialog(code: code),
          ),
        );
    return ok == true;
  }

  Future<void> _backupNow() async {
    final vault = context.read<VaultService>();
    final unlock = context.read<UnlockProvider>();
    final session = vault.session;
    if (session == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _progress = 'Starting…';
      _progressValue = null;
    });
    try {
      // Keep the vault from auto-locking while files are going up.
      final summary = await vault.whileBusy(
        () => _sync.backupAll(
          session,
          onProgress: (done, total, title) {
            unlock.onUserActivity();
            if (!mounted) return;
            setState(() {
              _progressValue = total == 0 ? 1 : done / total;
              _progress = done >= total
                  ? 'Finishing…'
                  : 'Backing up ${done + 1} of $total: $title';
            });
          },
        ),
      );
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
          _lastRun = summary;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
          _error = e is SyncSetupException
              ? e.message
              : 'The backup stopped before it finished. What already went up is kept; '
                    'run it again to continue. ($e)';
        });
      }
    }
  }

  Future<void> _disconnect() async {
    final session = context.read<VaultService>().session;
    if (session == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Disconnect backup?',
          style: AppFonts.ui(color: Ui.ink),
        ),
        content: Text(
          'This phone forgets the backup account. Nothing already on the server is deleted, '
          'and you can still restore it with your recovery code.',
          style: AppFonts.ui(color: Ui.ink2, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Disconnect',
              style: TextStyle(color: Ui.alert),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _sync.disconnect(session);
    if (mounted) {
      setState(() {
        _lastRun = null;
        _error = null;
      });
    }
  }

  /// Runs a long backup operation with the progress bar, keeping the vault
  /// from auto-locking meanwhile.
  Future<T?> _withProgress<T>(String start, Future<T> Function(void Function(int, int, String)) op) async {
    final vault = context.read<VaultService>();
    final unlock = context.read<UnlockProvider>();
    setState(() {
      _busy = true;
      _error = null;
      _progress = start;
      _progressValue = null;
    });
    try {
      return await vault.whileBusy(() => op((done, total, title) {
            unlock.onUserActivity();
            if (!mounted) return;
            setState(() {
              _progressValue = total == 0 ? 1 : done / total;
              _progress = done >= total ? 'Finishing…' : '${done + 1} of $total: $title';
            });
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

  /// Asks for the recovery code (for revoking, starting over). Never kept.
  Future<Uint8List?> _askRecoveryCode(String why) async {
    final c = TextEditingController();
    String? problem;
    final result = await context.read<UnlockProvider>().holdingInactivityLock(
          () => showDialog<Uint8List>(
            context: context,
            builder: (ctx) => StatefulBuilder(
              builder: (ctx, setLocal) => AlertDialog(
                title: Text('Recovery code'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(why, style: AppFonts.ui(fontSize: 13, color: Ui.ink2)),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('recovery-input'),
                      controller: c,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      maxLines: 3,
                      minLines: 2,
                      style: AppFonts.firaCode(fontSize: 13, color: Ui.ink),
                      decoration: InputDecoration(
                        hintText: 'xxxx xxxx xxxx …',
                        hintStyle: AppFonts.firaCode(fontSize: 13, color: Ui.ink3),
                        errorText: problem,
                        filled: true,
                        fillColor: Ui.canvas,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                      ),
                    ),
                  ],
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                  TextButton(
                    key: const Key('recovery-ok'),
                    onPressed: () {
                      final secret = VaultSync.parseRecoverySecret(c.text);
                      if (secret == null) {
                        setLocal(() => problem = 'That is not a recovery code (16 groups of 4).');
                        return;
                      }
                      Navigator.pop(ctx, secret);
                    },
                    child: const Text('Continue'),
                  ),
                ],
              ),
            ),
          ),
        );
    c.dispose();
    return result;
  }

  Future<void> _restoreMissing() async {
    final session = context.read<VaultService>().session;
    if (session == null || _busy) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: Ui.surface,
        title: Text('Restore from the backup'),
        children: [
          SimpleDialogOption(
            key: const Key('restore-latest'),
            onPressed: () => Navigator.pop(ctx, 'latest'),
            child: Text('Files that are missing here, as backed up now',
                style: AppFonts.ui(color: Ui.ink2)),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'asof'),
            child: Text('…as the backup was on a date I choose (undoes later changes and deletions)',
                style: AppFonts.ui(color: Ui.ink2)),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    DateTime? asOf;
    if (choice == 'asof') {
      final day = await showDatePicker(
        context: context,
        firstDate: DateTime(2024),
        lastDate: DateTime.now(),
        initialDate: DateTime.now(),
      );
      if (day == null || !mounted) return;
      asOf = DateTime(day.year, day.month, day.day, 23, 59, 59);
    }
    final r = await _withProgress('Reading the backup…', (p) => _sync.restoreMissing(session, asOf: asOf, onProgress: p));
    if (r != null && mounted) {
      setState(() => _note = r.restored == 0
          ? 'Nothing to restore: every backed-up file is already here.'
          : 'Restored ${r.restored} ${r.restored == 1 ? 'file' : 'files'}'
              '${r.failed.isEmpty ? '' : '; ${r.failed.length} could not be restored'}.');
    }
  }

  /// Removes from the server what only old versions needed, after asking
  /// how long to keep them and for the recovery code.
  Future<void> _freeUpSpace() async {
    final session = context.read<VaultService>().session;
    if (session == null || _busy) return;
    var days = VaultSync.retentionDays(session);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('Free up server space'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Removes versions of files that were replaced or deleted longer ago than this. '
                'Current files are never touched. Removed versions are gone for good.',
                style: AppFonts.ui(fontSize: 13, color: Ui.ink2),
              ),
              const SizedBox(height: 12),
              DropdownButton<int>(
                key: const Key('retention-days'),
                value: days,
                dropdownColor: Ui.surface,
                items: [
                  for (final d in const [7, 30, 90, 365])
                    DropdownMenuItem(
                      value: d,
                      child: Text(d == 365 ? 'Keep for a year' : 'Keep for $d days',
                          style: AppFonts.ui(color: Ui.ink)),
                    ),
                ],
                onChanged: (v) => setLocal(() => days = v ?? days),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(
              key: const Key('free-space-go'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
    if (go != true || !mounted) return;
    await _sync.setRetentionDays(session, days);
    final secret = await _askRecoveryCode(
      'Removing anything from the backup needs the recovery code, so a phone in the wrong '
      'hands can never erase what already reached the server.',
    );
    if (secret == null || !mounted) return;
    final r = await _withProgress('Freeing up space…', (_) => _sync.freeUpSpace(session, secret));
    if (r != null && mounted) {
      setState(() => _note = r.piecesDeleted == 0
          ? 'Nothing to remove: no version is older than that.'
          : 'Freed ${formatBytes(r.bytesFreed)} from ${r.versionsDropped} old '
              '${r.versionsDropped == 1 ? 'version' : 'versions'}.');
    }
  }

  List<BackupDevice>? _devices;

  Future<void> _loadDevices() async {
    final session = context.read<VaultService>().session;
    if (session == null || _busy) return;
    final list = await _withProgress('Asking the server…', (_) => _sync.devices(session));
    if (list != null && mounted) setState(() => _devices = list);
  }

  Future<void> _revoke(BackupDevice d) async {
    final session = context.read<VaultService>().session;
    if (session == null || _busy) return;
    final secret = await _askRecoveryCode(
      'Revoking needs the recovery code. The server refuses that phone from then on; '
      'anything it already uploaded stays in the backup.',
    );
    if (secret == null || !mounted) return;
    final ok = await _withProgress('Revoking…', (_) async {
      await _sync.revoke(session, secret, [d.id]);
      return true;
    });
    if (ok == true) await _loadDevices();
  }

  Future<void> _startOver() async {
    final session = context.read<VaultService>().session;
    if (session == null || _busy) return;
    final pending = _sync.startOverPending(session);
    final secret = await _askRecoveryCode(pending
        ? 'Finish starting over: the rest of the vault is uploaded to the new account, then the old one is closed.'
        : 'If a phone with access to this backup was taken: this vault moves to a new backup account with '
            'new keys, everything is uploaded again, and the old account (which that phone could reach) is '
            'closed and emptied on the server. Needs the recovery code.');
    if (secret == null || !mounted) return;
    final r = await _withProgress('Starting over…', (p) => _sync.startOver(session, secret, onProgress: p));
    if (r != null && mounted) {
      setState(() {
        _lastRun = r;
        _devices = null;
        _note = 'Moved to a new backup account; the old one is closed.';
      });
    }
  }

  String? _note;

  Widget _torSwitch(bool value, ValueChanged<bool> onChanged) => UiSwitchRow(
        switchKey: const Key('backup-tor'),
        icon: Icons.vpn_lock_outlined,
        title: 'Connect through Tor',
        detail: "Through Orbot: the server and the network never see this phone's address. Slower.",
        value: value,
        onChanged: _busy ? null : onChanged,
      );

  bool get _startOverPending {
    final s = context.read<VaultService>().session;
    return s != null && _sync.startOverPending(s);
  }

  Widget _autoCard(VaultSession session) {
    final auto = context.read<AutoBackup>();
    final on = AutoBackup.isEnabled(session);
    return ValueListenableBuilder<AutoBackupState>(
      valueListenable: auto.state,
      builder: (context, st, _) {
        String line;
        if (!on) {
          line = 'Off: back up with the button.';
        } else if (st.running) {
          line = st.total == 0 ? 'Backing up…' : 'Backing up ${st.done + 1} of ${st.total}…';
        } else if (st.waitingForNetwork) {
          line = 'Waiting for a connection.';
        } else if (st.lastError != null) {
          line = '${st.lastError} Trying again${st.nextAttempt == null ? ' soon' : ' at ${TimeOfDay.fromDateTime(st.nextAttempt!).format(context)}'}.';
        } else {
          line = 'When something changes, and as soon as there is a connection.';
        }
        return UiSwitchRow(
          switchKey: const Key('auto-backup'),
          detailKey: const Key('auto-backup-state'),
          icon: Icons.autorenew_rounded,
          title: 'Back up automatically',
          detail: line,
          value: on,
          onChanged: _busy
              ? null
              : (v) async {
                  await auto.setEnabled(session, v);
                  if (mounted) setState(() {});
                },
        );
      },
    );
  }

  /// The phones that can reach this backup, or the row that loads them.
  List<Widget> _deviceRows() {
    final list = _devices;
    if (list == null) {
      return [
        UiRow(
          key: const Key('devices-load'),
          icon: Icons.devices_outlined,
          title: 'Phones with access',
          onTap: _busy ? null : _loadDevices,
        ),
      ];
    }
    String day(DateTime t) => '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    return [
      for (final d in list)
        UiRow(
          icon: d.revoked != null
              ? Icons.block_rounded
              : (d.isThisPhone ? Icons.smartphone_outlined : Icons.phone_android_outlined),
          title: d.isThisPhone ? 'This phone' : 'Another phone',
          detail: d.revoked != null ? 'Added ${day(d.added)} · revoked ${day(d.revoked!)}' : 'Added ${day(d.added)}',
          chevron: false,
          trailing: d.isThisPhone || d.revoked != null
              ? null
              : TextButton(
                  key: Key('revoke-${d.id}'),
                  onPressed: _busy ? null : () => _revoke(d),
                  child: const Text('Revoke', style: TextStyle(color: Ui.alert)),
                ),
        ),
    ];
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<VaultService>().session;
    final status = session == null ? const SyncStatus() : _sync.status(session);

    // No leaving while the account is being created.
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded, size: 22),
            tooltip: 'Back',
            onPressed: _busy ? null : () => Navigator.pop(context),
          ),
          title: const Text('Backup'),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 24),
            children: [
              if (!status.isConnected) ..._buildConnectForm() else ..._buildConnected(status),
            ],
          ),
        ),
      ),
    );
  }

  /// Progress, the last result, a note or an error, right under the button.
  List<Widget> _feedback() => [
        if (_progress != null) ...[
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(value: _progressValue, minHeight: 3),
          ),
          const SizedBox(height: 8),
          Text(_progress!, maxLines: 2, overflow: TextOverflow.ellipsis, style: Ui.data()),
        ],
        if (_lastRun != null) ...[
          const SizedBox(height: 14),
          _resultCard(_lastRun!),
        ],
        if (_note != null) ...[
          const SizedBox(height: 12),
          _okCard(_note!, key: const Key('backup-note')),
        ],
        if (_error != null) ...[
          const SizedBox(height: 14),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Padding(
              padding: EdgeInsets.only(top: 1),
              child: Icon(Icons.error_outline_rounded, color: Ui.alert, size: 18),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(_error!, style: Ui.detail(color: Ui.alert))),
          ]),
        ],
      ];

  List<Widget> _buildConnectForm() => [
        Padding(
          padding: const EdgeInsets.fromLTRB(Ui.gutter, 8, Ui.gutter, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Back up to a server you trust', style: Ui.title()),
            const SizedBox(height: 10),
            Text(
              'Files are encrypted on this phone before they leave it. The server stores scrambled pieces '
              'and never receives a key, a file name or anything readable.',
              style: Ui.body(color: Ui.ink2, size: 15),
            ),
            const SizedBox(height: 28),
            _field(_server, 'Server address', 'https://backup.example.org', TextInputType.url),
            const SizedBox(height: 12),
            _field(_invite, 'Invite code (if the server needs one)', '', TextInputType.text),
            const SizedBox(height: 8),
          ]),
        ),
        UiGroup(margin: const EdgeInsets.fromLTRB(Ui.gutter, 8, Ui.gutter, 16), children: [
          _torSwitch(_tor, (v) => setState(() => _tor = v)),
        ]),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Ui.gutter),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _primaryButton('Connect', _busy ? null : _connect),
            ..._feedback(),
            const SizedBox(height: 16),
            Text(
              'Use a server run by someone you trust, such as your newsroom or organisation.',
              style: Ui.detail(color: Ui.ink3),
            ),
          ]),
        ),
      ];

  List<Widget> _buildConnected(SyncStatus status) {
    final s = context.read<VaultService>().session;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(Ui.gutter, 4, Ui.gutter, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(status.server ?? '', style: Ui.data(), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          Text(
            status.lastBackup == null
                ? 'Not backed up yet'
                : 'Last backup ${_ago(status.lastBackup!)} · ${status.lastItemCount} '
                    '${status.lastItemCount == 1 ? 'item' : 'items'}',
            style: Ui.heading(),
          ),
          const SizedBox(height: 18),
          _primaryButton('Back up now', _busy ? null : _backupNow),
          ..._feedback(),
        ]),
      ),
      if (s != null)
        UiGroup(label: 'Automatic', children: [
          _autoCard(s),
          UiSwitchRow(
            switchKey: const Key('previews-first'),
            icon: Icons.photo_size_select_small_outlined,
            title: 'Small previews first',
            detail: 'New photos, videos and recordings go up small first, then in full.',
            value: VaultSync.previewsFirst(s),
            onChanged: _busy
                ? null
                : (v) async {
                    await _sync.setPreviewsFirst(s, v);
                    if (mounted) setState(() {});
                  },
          ),
          UiSwitchRow(
            switchKey: const Key('originals-wifi'),
            icon: Icons.wifi_rounded,
            title: 'Full size only on Wi-Fi',
            detail: 'Large originals wait for Wi-Fi.',
            value: VaultSync.originalsOnWifiOnly(s),
            onChanged: _busy
                ? null
                : (v) async {
                    await _sync.setOriginalsOnWifiOnly(s, v);
                    if (mounted) setState(() {});
                  },
          ),
          _lockedCard(s),
          _torSwitch(VaultSync.usesTor(s), (v) async {
            if (v && !await VaultSync.torAvailable()) {
              if (mounted) setState(() => _error = "Orbot isn't running. Start Orbot (the Tor app) first.");
              return;
            }
            await _sync.setTor(s, v);
            if (mounted) setState(() => _error = null);
          }),
        ]),
      UiGroup(label: 'Restore', children: [
        UiRow(
          key: const Key('restore-missing'),
          icon: Icons.download_for_offline_outlined,
          title: 'Restore files from the backup',
          onTap: _busy ? null : _restoreMissing,
        ),
        UiRow(
          key: const Key('history-open'),
          icon: Icons.history_rounded,
          title: 'Version history',
          onTap: _busy
              ? null
              : () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BackupHistoryScreen())),
        ),
        UiRow(
          key: const Key('free-space'),
          icon: Icons.cleaning_services_outlined,
          title: 'Free up server space',
          onTap: _busy ? null : _freeUpSpace,
        ),
      ]),
      UiGroup(label: 'Phones', children: _deviceRows()),
      UiGroup(label: 'If a phone is taken', children: [
        UiRow(
          key: const Key('start-over'),
          icon: Icons.gpp_maybe_outlined,
          title: _startOverPending ? 'Finish starting over' : 'Start over on a new account',
          detail: 'New keys; the old account is closed. Needs the recovery code.',
          onTap: _busy ? null : _startOver,
        ),
        UiRow(
          icon: Icons.link_off_rounded,
          title: 'Disconnect',
          detail: 'This phone forgets the account. Nothing on the server is deleted.',
          onTap: _busy ? null : _disconnect,
        ),
      ]),
    ];
  }

  Widget _resultCard(BackupSummary s) {
    if (s.queued > 0 && s.uploaded == 0) {
      return _okCard('No connection: ${s.queued} ${s.queued == 1 ? 'item is' : 'items are'} queued, and go up '
          'as soon as there is a signal, even with the vault locked.');
    }
    final parts = <String>[
      '${s.uploaded} sent',
      if (s.previews > 0) '${s.previews} ${s.previews == 1 ? 'preview' : 'previews'} sent first',
      if (s.unchanged > 0) '${s.unchanged} already up to date',
      if (s.removed > 0) '${s.removed} removed',
      if (s.waitingForWifi > 0) '${s.waitingForWifi} full-size ${s.waitingForWifi == 1 ? 'original waits' : 'originals wait'} for Wi-Fi',
    ];
    return _okCard(
      'Backup finished: ${parts.join(', ')}. '
      '${formatBytes(s.wireBytes)} sent in ${s.elapsed.inSeconds} s.',
    );
  }

  Widget _okCard(String text, {Key? key}) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(
          padding: EdgeInsets.only(top: 1),
          child: Icon(Icons.check_rounded, color: Ui.ink2, size: 18),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text, key: key, style: Ui.detail(color: Ui.ink))),
      ]);

  /// Locked upload: the switch, what the queue holds, and the stop code.
  Widget _lockedCard(VaultSession s) {
    return FutureBuilder<OutboxStatus?>(
      // A stop while the vault was locked is noted first, even offline.
      future: _sync.noticeStop(s).then((_) => _sync.queueStatus(s)),
      builder: (context, snap) {
        final on = VaultSync.lockedUpload(s);
        final stopped = VaultSync.lockedUploadStopped(s);
        final q = snap.data;
        final String line;
        if (stopped) {
          line = 'Stopped: the cache was cleared, or the stop code was typed. The queue and its login are gone. '
              'Turn it on again when it\'s safe.';
        } else if (!on) {
          line = 'Off: backup runs only while the vault is open.';
        } else if (q != null && q.count > 0) {
          line = 'On: ${formatBytes(q.bytes)} waiting for a signal.';
        } else {
          line = 'On. With no signal, new things wait in a sealed queue and go up as soon as there is one, even locked.';
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UiSwitchRow(
              switchKey: const Key('locked-upload'),
              detailKey: const Key('locked-upload-state'),
              icon: Icons.lock_clock_outlined,
              title: 'Keep uploading while locked',
              detail: line,
              value: on,
              onChanged: _busy
                  ? null
                  : (v) async {
                      await _sync.setLockedUpload(s, v);
                      if (mounted) setState(() {});
                    },
            ),
            if (on) ...[
              const Divider(height: 0.6, thickness: 0.6, indent: 52),
              UiRow(
                key: const Key('stop-code'),
                icon: Icons.front_hand_outlined,
                title: VaultSync.hasStopCode(s) ? 'Change the stop code' : 'Set a stop code',
                onTap: _busy ? null : () => _setStopCode(s),
              ),
            ],
          ],
        );
      },
    );
  }

  /// The stop code: typed on the lock screen, it looks like a wrong PIN
  /// and wipes the queue and its login.
  Future<void> _setStopCode(VaultSession s) async {
    final a = TextEditingController(), b = TextEditingController();
    final had = VaultSync.hasStopCode(s);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Stop code'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'If you type this code on the lock screen, it looks like a wrong PIN, and the upload queue and its '
              'login are wiped. Your vault and your backup stay as they are. "Clear cache" in Video Trimmer\'s menu '
              'does the same. Uploading while locked then stays off until you turn it on here.',
              style: AppFonts.ui(fontSize: 13, color: Ui.ink2),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('stop-code-1'),
              controller: a,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              style: AppFonts.ui(color: Ui.ink),
              decoration: const InputDecoration(labelText: 'New stop code'),
            ),
            TextField(
              key: const Key('stop-code-2'),
              controller: b,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              style: AppFonts.ui(color: Ui.ink),
              decoration: const InputDecoration(labelText: 'Confirm'),
            ),
          ],
        ),
        actions: [
          if (had) TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Remove')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            key: const Key('stop-code-save'),
            onPressed: () {
              if (a.text.length < 6 || a.text != b.text) return;
              Navigator.pop(ctx, a.text);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    a.dispose();
    b.dispose();
    if (result == null || !mounted) return;
    try {
      await _sync.setStopCode(s, result.isEmpty ? null : result);
      if (mounted) setState(() => _note = result.isEmpty ? 'Stop code removed.' : 'Stop code set.');
    } on CredentialInUseException {
      // Saying why would tell whoever tried that the code opens something.
      if (!mounted) return;
      await context.read<UnlockProvider>().registerRefusedPin();
      if (mounted) setState(() => _error = "That code can't be used. Choose a different one.");
    }
  }

  Widget _field(
    TextEditingController c,
    String label,
    String hint,
    TextInputType type,
  ) => TextField(
    enableIMEPersonalizedLearning:
        false, // keep vault text out of keyboard learning
    controller: c,
    enabled: !_busy,
    keyboardType: type,
    autocorrect: false,
    enableSuggestions: false,
    inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
    style: Ui.body(size: 15),
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
    ),
  );

  Widget _primaryButton(String label, VoidCallback? onPressed) => SizedBox(
        width: double.infinity,
        child: ElevatedButton(onPressed: onPressed, child: Text(label)),
      );
}

/// Shows the recovery code, then hides it and asks for two of its groups,
/// chosen at random, so confirming proves the code was written down.
/// Owns its text controllers, so they live exactly as long as the dialog
/// (including its closing animation).
class _RecoveryCodeDialog extends StatefulWidget {
  final String code;
  const _RecoveryCodeDialog({required this.code});

  @override
  State<_RecoveryCodeDialog> createState() => _RecoveryCodeDialogState();
}

class _RecoveryCodeDialogState extends State<_RecoveryCodeDialog> {
  late final List<String> _groups = widget.code.split(' ');
  late final List<int> _asked = () {
    final r = Random.secure();
    final a = r.nextInt(_groups.length);
    var b = r.nextInt(_groups.length - 1);
    if (b >= a) b++;
    return a < b ? [a, b] : [b, a];
  }();
  final List<TextEditingController> _typed = [TextEditingController(), TextEditingController()];
  bool _checking = false;

  @override
  void dispose() {
    for (final c in _typed) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _matches => [
        for (var i = 0; i < 2; i++) _typed[i].text.trim().toLowerCase() == _groups[_asked[i]],
      ].every((ok) => ok);

  ButtonStyle get _primary => ElevatedButton.styleFrom(
        backgroundColor: Ui.signal,
        foregroundColor: Ui.canvas,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      );

  Widget _field(int i) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          key: Key('recovery-group-$i'),
          controller: _typed[i],
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          onChanged: (_) => setState(() {}),
          style: AppFonts.firaCode(color: Ui.ink),
          decoration: InputDecoration(
            labelText: 'Group ${_asked[i] + 1} of ${_groups.length}',
            labelStyle: AppFonts.ui(color: Ui.ink2),
            filled: true,
            fillColor: Ui.canvas,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final showCode = !_checking;
    return AlertDialog(
      title: Text(
        showCode ? 'Write this down first' : 'Check what you wrote',
        style: AppFonts.ui(color: Ui.ink, fontWeight: FontWeight.w500),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: showCode
              ? [
                  Text(
                    'This recovery code is the only way to get your backup onto a new phone, '
                    'or to cut off a phone that was taken. It is never stored on this phone. '
                    'Write it on paper and keep it away from the phone.',
                    style: AppFonts.ui(fontSize: 13, color: Ui.ink2),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Ui.canvas,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Ui.signal.withValues(alpha: 0.4)),
                    ),
                    // Not selectable: the clipboard (and keyboard clipboard
                    // history) is the last place this code should end up.
                    child: Text(
                      widget.code,
                      key: const Key('recovery-code'),
                      style: AppFonts.firaCode(fontSize: 15, color: Ui.ink, height: 1.7),
                    ),
                  ),
                ]
              : [
                  Text(
                    'Type these two groups from your paper copy. The groups are counted from 1, left to right.',
                    style: AppFonts.ui(fontSize: 13, color: Ui.ink2),
                  ),
                  const SizedBox(height: 14),
                  _field(0),
                  _field(1),
                ],
        ),
      ),
      actions: showCode
          ? [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Cancel', style: AppFonts.ui(color: Ui.ink2)),
              ),
              ElevatedButton(
                key: const Key('recovery-written'),
                style: _primary,
                onPressed: () => setState(() => _checking = true),
                child: Text('I wrote it down', style: AppFonts.ui(fontWeight: FontWeight.w500)),
              ),
            ]
          : [
              TextButton(
                onPressed: () => setState(() => _checking = false),
                child: Text('Show the code again', style: AppFonts.ui(color: Ui.ink2)),
              ),
              ElevatedButton(
                key: const Key('recovery-confirm'),
                style: _primary,
                onPressed: _matches ? () => Navigator.pop(context, true) : null,
                child: Text('Confirm', style: AppFonts.ui(fontWeight: FontWeight.w500)),
              ),
            ],
    );
  }
}
