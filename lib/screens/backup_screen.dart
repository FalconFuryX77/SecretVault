import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/unlock_provider.dart';
import '../services/device_file_service.dart';
import '../services/vault_service.dart';
import '../sync/vault_sync.dart';
import '../theme/app_fonts.dart';

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
      await context.read<VaultService>().whileBusy(
            () => _sync.connect(session, server: _server.text, invite: _invite.text, recoverySecret: secret!),
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
    const SizedBox(height: 16),
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
    const SizedBox(height: 16),
    _primaryButton('Back up now', _busy ? null : _backupNow),
    const SizedBox(height: 4),
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
        '${DeviceFileService.formatBytes(s.wireBytes)} sent in ${s.elapsed.inSeconds} s.',
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
