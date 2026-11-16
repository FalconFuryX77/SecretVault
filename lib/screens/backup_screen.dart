import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/unlock_provider.dart';
import '../util/format.dart';
import '../services/vault_service.dart';
import '../sync/auto_backup.dart';
import '../sync/vault_sync.dart';
import '../theme/app_fonts.dart';
import '../vault/vault_container.dart';
import 'backup_history_screen.dart';

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
        backgroundColor: const Color(0xFF161B22),
        title: Text(
          'Disconnect backup?',
          style: AppFonts.outfit(color: Colors.white),
        ),
        content: Text(
          'This phone forgets the backup account. Nothing already on the server is deleted, '
          'and you can still restore it with your recovery code.',
          style: AppFonts.outfit(color: Colors.white70, fontSize: 13),
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
              style: TextStyle(color: Color(0xFFFB7185)),
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
                backgroundColor: const Color(0xFF161B22),
                title: Text('Recovery code', style: AppFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold)),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(why, style: AppFonts.outfit(fontSize: 13, color: Colors.white70)),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('recovery-input'),
                      controller: c,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      maxLines: 3,
                      minLines: 2,
                      style: AppFonts.firaCode(fontSize: 13, color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'xxxx xxxx xxxx …',
                        hintStyle: AppFonts.firaCode(fontSize: 13, color: Colors.white24),
                        errorText: problem,
                        filled: true,
                        fillColor: const Color(0xFF0D1117),
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
        backgroundColor: const Color(0xFF161B22),
        title: Text('Restore from the backup', style: AppFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold)),
        children: [
          SimpleDialogOption(
            key: const Key('restore-latest'),
            onPressed: () => Navigator.pop(ctx, 'latest'),
            child: Text('Files that are missing here, as backed up now',
                style: AppFonts.outfit(color: Colors.white70)),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'asof'),
            child: Text('…as the backup was on a date I choose (undoes later changes and deletions)',
                style: AppFonts.outfit(color: Colors.white70)),
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
          backgroundColor: const Color(0xFF161B22),
          title: Text('Free up server space', style: AppFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Removes versions of files that were replaced or deleted longer ago than this. '
                'Current files are never touched. Removed versions are gone for good.',
                style: AppFonts.outfit(fontSize: 13, color: Colors.white70),
              ),
              const SizedBox(height: 12),
              DropdownButton<int>(
                key: const Key('retention-days'),
                value: days,
                dropdownColor: const Color(0xFF161B22),
                items: [
                  for (final d in const [7, 30, 90, 365])
                    DropdownMenuItem(
                      value: d,
                      child: Text(d == 365 ? 'Keep for a year' : 'Keep for $d days',
                          style: AppFonts.outfit(color: Colors.white)),
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

  Widget _torSwitch(bool value, ValueChanged<bool> onChanged) => SwitchListTile(
        key: const Key('backup-tor'),
        contentPadding: EdgeInsets.zero,
        value: value,
        onChanged: _busy ? null : onChanged,
        activeThumbColor: const Color(0xFFA78BFA),
        title: Text('Connect through Tor', style: AppFonts.outfit(fontSize: 14, color: Colors.white)),
        subtitle: Text(
          'Through Orbot, so the server and the network in between never see this phone\'s address. '
          'Slower. Needs Orbot running; works with .onion servers.',
          style: AppFonts.outfit(fontSize: 12, color: Colors.white54),
        ),
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
          line = 'While this vault is open: when it changes, and as soon as there is a connection.';
        }
        return SwitchListTile(
          key: const Key('auto-backup'),
          contentPadding: EdgeInsets.zero,
          value: on,
          onChanged: _busy
              ? null
              : (v) async {
                  await auto.setEnabled(session, v);
                  if (mounted) setState(() {});
                },
          activeThumbColor: const Color(0xFFA78BFA),
          title: Text('Back up automatically', style: AppFonts.outfit(fontSize: 14, color: Colors.white)),
          subtitle: Text(line, key: const Key('auto-backup-state'), style: AppFonts.outfit(fontSize: 12, color: Colors.white54)),
        );
      },
    );
  }

  Widget _devicesCard() {
    final list = _devices;
    if (list == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const Key('devices-load'),
          onPressed: _busy ? null : _loadDevices,
          icon: const Icon(Icons.devices_rounded, size: 18, color: Colors.white54),
          label: Text('Phones with access to this backup', style: AppFonts.outfit(color: Colors.white70, fontSize: 13)),
        ),
      );
    }
    String day(DateTime t) => '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Phones with access', style: AppFonts.outfit(fontSize: 12, color: Colors.white54)),
        for (final d in list)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(
              d.revoked != null ? Icons.block_rounded : (d.isThisPhone ? Icons.smartphone_rounded : Icons.phone_android_rounded),
              color: d.revoked != null ? Colors.white24 : Colors.white70,
            ),
            title: Text(
              d.isThisPhone ? 'This phone' : 'Another phone',
              style: AppFonts.outfit(fontSize: 13, color: d.revoked != null ? Colors.white38 : Colors.white),
            ),
            subtitle: Text(
              d.revoked != null ? 'Added ${day(d.added)} · revoked ${day(d.revoked!)}' : 'Added ${day(d.added)}',
              style: AppFonts.outfit(fontSize: 11, color: Colors.white38),
            ),
            trailing: d.isThisPhone || d.revoked != null
                ? null
                : TextButton(
                    key: Key('revoke-${d.id}'),
                    onPressed: _busy ? null : () => _revoke(d),
                    child: const Text('Revoke', style: TextStyle(color: Color(0xFFFB7185))),
                  ),
          ),
      ],
    );
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
        backgroundColor: const Color(0xFF090D16),
        appBar: AppBar(
          backgroundColor: const Color(0xFF161B22),
          elevation: 0,
          leading: IconButton(
            icon: const Icon(
              Icons.arrow_back_ios_new_rounded,
              color: Colors.white70,
              size: 18,
            ),
            onPressed: _busy ? null : () => Navigator.pop(context),
          ),
          title: Text(
            'Backup',
            style: AppFonts.outfit(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            children: [
              Text(
                'Files are encrypted on this phone before they leave it. The server stores '
                'scrambled pieces and never receives a key, a file name or anything readable.',
                style: AppFonts.outfit(fontSize: 13, color: Colors.white60),
              ),
              const SizedBox(height: 20),
              if (!status.isConnected)
                ..._buildConnectForm()
              else
                ..._buildConnected(status),
              if (_progress != null) ...[
                const SizedBox(height: 20),
                LinearProgressIndicator(
                  value: _progressValue,
                  color: const Color(0xFFA78BFA),
                ),
                const SizedBox(height: 8),
                Text(
                  _progress!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.outfit(fontSize: 12, color: Colors.white54),
                ),
              ],
              if (_lastRun != null) ...[
                const SizedBox(height: 20),
                _resultCard(_lastRun!),
              ],
              if (_note != null) ...[
                const SizedBox(height: 12),
                Text(_note!, key: const Key('backup-note'), style: AppFonts.outfit(fontSize: 13, color: const Color(0xFF6EE7B7))),
              ],
              if (_error != null) ...[
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE11D48).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: const Color(0xFFE11D48).withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    _error!,
                    style: AppFonts.outfit(
                      color: const Color(0xFFFB7185),
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildConnectForm() => [
    _field(
      _server,
      'Server address',
      'https://backup.example.org',
      TextInputType.url,
    ),
    const SizedBox(height: 12),
    _field(
      _invite,
      'Invite code (if the server needs one)',
      '',
      TextInputType.text,
    ),
    _torSwitch(_tor, (v) => setState(() => _tor = v)),
    const SizedBox(height: 8),
    _primaryButton('Connect', _busy ? null : _connect),
    const SizedBox(height: 10),
    Text(
      'Use a server run by someone you trust, such as your newsroom or organisation.',
      style: AppFonts.outfit(fontSize: 12, color: Colors.white38),
    ),
  ];

  List<Widget> _buildConnected(SyncStatus status) => [
    Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Connected to',
            style: AppFonts.outfit(fontSize: 12, color: Colors.white54),
          ),
          const SizedBox(height: 2),
          Text(
            status.server ?? '',
            style: AppFonts.outfit(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            status.lastBackup == null
                ? 'Not backed up yet'
                : 'Last backup ${_ago(status.lastBackup!)} · ${status.lastItemCount} '
                      '${status.lastItemCount == 1 ? 'item' : 'items'}',
            style: AppFonts.outfit(fontSize: 13, color: Colors.white70),
          ),
        ],
      ),
    ),
    const SizedBox(height: 8),
    if (context.read<VaultService>().session case final s?) _autoCard(s),
    if (context.read<VaultService>().session case final s?)
      _torSwitch(VaultSync.usesTor(s), (v) async {
        if (v && !await VaultSync.torAvailable()) {
          if (mounted) setState(() => _error = "Orbot isn't running. Start Orbot (the Tor app) first.");
          return;
        }
        await _sync.setTor(s, v);
        if (mounted) setState(() => _error = null);
      }),
    const SizedBox(height: 8),
    _primaryButton('Back up now', _busy ? null : _backupNow),
    const SizedBox(height: 4),
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const Key('restore-missing'),
        onPressed: _busy ? null : _restoreMissing,
        icon: const Icon(Icons.restore_rounded, size: 18, color: Colors.white54),
        label: Text('Restore files from the backup', style: AppFonts.outfit(color: Colors.white70, fontSize: 13)),
      ),
    ),
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const Key('history-open'),
        onPressed: _busy
            ? null
            : () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BackupHistoryScreen())),
        icon: const Icon(Icons.history_rounded, size: 18, color: Colors.white54),
        label: Text('Version history', style: AppFonts.outfit(color: Colors.white70, fontSize: 13)),
      ),
    ),
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const Key('free-space'),
        onPressed: _busy ? null : _freeUpSpace,
        icon: const Icon(Icons.cleaning_services_rounded, size: 18, color: Colors.white54),
        label: Text('Free up server space', style: AppFonts.outfit(color: Colors.white70, fontSize: 13)),
      ),
    ),
    _devicesCard(),
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const Key('start-over'),
        onPressed: _busy ? null : _startOver,
        icon: const Icon(Icons.gpp_maybe_rounded, size: 18, color: Color(0xFFFBBF24)),
        label: Text(
          _startOverPending ? 'Finish starting over on a new account' : 'A phone was taken? Start over on a new account',
          style: AppFonts.outfit(color: const Color(0xFFFBBF24), fontSize: 13),
        ),
      ),
    ),
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: _busy ? null : _disconnect,
        child: Text(
          'Disconnect',
          style: AppFonts.outfit(color: Colors.white54, fontSize: 13),
        ),
      ),
    ),
  ];

  Widget _resultCard(BackupSummary s) {
    final parts = <String>[
      '${s.uploaded} sent',
      if (s.unchanged > 0) '${s.unchanged} already up to date',
      if (s.removed > 0) '${s.removed} removed',
    ];
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF059669).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFF059669).withValues(alpha: 0.4),
        ),
      ),
      child: Text(
        'Backup finished: ${parts.join(', ')}. '
        '${formatBytes(s.wireBytes)} sent in ${s.elapsed.inSeconds} s.',
        style: AppFonts.outfit(color: const Color(0xFF6EE7B7), fontSize: 13),
      ),
    );
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
    style: AppFonts.outfit(fontSize: 15, color: Colors.white),
    decoration: InputDecoration(
      labelText: label,
      labelStyle: AppFonts.outfit(fontSize: 13, color: Colors.white54),
      hintText: hint,
      hintStyle: AppFonts.outfit(fontSize: 14, color: Colors.white24),
      filled: true,
      fillColor: const Color(0xFF161B22),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    ),
  );

  Widget _primaryButton(String label, VoidCallback? onPressed) => SizedBox(
    width: double.infinity,
    child: ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFFA78BFA),
        foregroundColor: const Color(0xFF090D16),
        disabledBackgroundColor: const Color(0xFF21262D),
        disabledForegroundColor: Colors.white38,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      child: Text(
        label,
        style: AppFonts.outfit(fontSize: 15, fontWeight: FontWeight.bold),
      ),
    ),
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
        backgroundColor: const Color(0xFFA78BFA),
        foregroundColor: const Color(0xFF090D16),
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
          style: AppFonts.firaCode(color: Colors.white),
          decoration: InputDecoration(
            labelText: 'Group ${_asked[i] + 1} of ${_groups.length}',
            labelStyle: AppFonts.outfit(color: Colors.white54),
            filled: true,
            fillColor: const Color(0xFF0D1117),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final showCode = !_checking;
    return AlertDialog(
      backgroundColor: const Color(0xFF161B22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        showCode ? 'Write this down first' : 'Check what you wrote',
        style: AppFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold),
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
                    style: AppFonts.outfit(fontSize: 13, color: Colors.white70),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0D1117),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFA78BFA).withValues(alpha: 0.4)),
                    ),
                    // Not selectable: the clipboard (and keyboard clipboard
                    // history) is the last place this code should end up.
                    child: Text(
                      widget.code,
                      key: const Key('recovery-code'),
                      style: AppFonts.firaCode(fontSize: 15, color: Colors.white, height: 1.7),
                    ),
                  ),
                ]
              : [
                  Text(
                    'Type these two groups from your paper copy. The groups are counted from 1, left to right.',
                    style: AppFonts.outfit(fontSize: 13, color: Colors.white70),
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
                child: Text('Cancel', style: AppFonts.outfit(color: Colors.white54)),
              ),
              ElevatedButton(
                key: const Key('recovery-written'),
                style: _primary,
                onPressed: () => setState(() => _checking = true),
                child: Text('I wrote it down', style: AppFonts.outfit(fontWeight: FontWeight.bold)),
              ),
            ]
          : [
              TextButton(
                onPressed: () => setState(() => _checking = false),
                child: Text('Show the code again', style: AppFonts.outfit(color: Colors.white54)),
              ),
              ElevatedButton(
                key: const Key('recovery-confirm'),
                style: _primary,
                onPressed: _matches ? () => Navigator.pop(context, true) : null,
                child: Text('Confirm', style: AppFonts.outfit(fontWeight: FontWeight.bold)),
              ),
            ],
    );
  }
}
