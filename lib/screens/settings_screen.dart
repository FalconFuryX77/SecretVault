import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme/app_fonts.dart';
import 'package:provider/provider.dart';
import '../providers/unlock_provider.dart';
import '../services/auth_service.dart';
import '../services/vault_mover.dart';
import '../services/vault_service.dart';
import '../vault/vault_container.dart';
import 'backup_screen.dart';
import 'hidden_recorder_screen.dart';
import 'recorder_screen.dart';

/// Security & Preferences Settings Screen.
///
/// Everything here acts on the vault that is currently open. A decoy vault
/// sees the same screen minus decoy management (a decoy can't host one).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final AuthService _authService = AuthService();
  bool _autoLockOnSwitch = true;
  int _inactivityTimeout = 30;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final autoLock = await _authService.getAutoLockOnSwitch();
    final timeout = await _authService.getInactivityTimeout();
    if (mounted) {
      setState(() {
        _autoLockOnSwitch = autoLock;
        _inactivityTimeout = timeout;
      });
    }
  }

  VaultSession? get _session => context.read<VaultService>().session;

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: error
            ? const Color(0xFFE11D48)
            : const Color(0xFF059669),
        content: Text(msg, style: AppFonts.outfit(color: Colors.white)),
      ),
    );
  }

  /// A PIN that is taken can't be used, and saying so tells whoever tried
  /// it that it opens something. The message is the same as for any other
  /// refused PIN, and the refusal counts as a failed unlock attempt.
  Future<void> _refused() async {
    await context.read<UnlockProvider>().registerRefusedPin();
    _toast("That PIN can't be used. Choose a different one.", error: true);
  }

  /// Asks for a new PIN twice. Returns null if cancelled.
  Future<String?> _askNewPin(String title, String hint) => showDialog<String>(
    context: context,
    builder: (_) => _NewPinDialog(title: title, hint: hint),
  );

  Future<void> _runPinChange({required bool decoy}) async {
    final pin = await _askNewPin(
      decoy ? 'Decoy Vault PIN' : 'Change PIN',
      decoy
          ? 'The PIN you can hand over if forced. It opens only the decoy vault.'
          : 'Your files are re-protected under the new PIN immediately.',
    );
    final session = _session;
    if (pin == null || session == null) return;
    try {
      if (decoy) {
        if (session.hasDecoy) {
          await session.changeDecoyPin(pin);
        } else {
          await session.standInDecoySetup(pin, shown: true);
        }
      } else {
        await session.changePin(pin);
      }
      _toast('PIN updated.');
    } on CredentialInUseException {
      await _refused();
    } catch (e) {
      _toast('Could not change PIN: $e', error: true);
    }
  }

  Future<void> _createDecoy() async {
    final pin = await _askNewPin(
      'Set Up Decoy Vault',
      'If someone forces you to unlock, give them this PIN instead. It opens a separate, '
          'ordinary-looking vault; nothing on the phone shows a second one exists. '
          'Fill it with believable files after creating it.',
    );
    final session = _session;
    if (pin == null || session == null) return;
    // This vault's files move up to leave the decoy the bottom of the
    // container; on a full vault that takes a while.
    final progress = ValueNotifier<double>(0);
    var shown = false;
    final timer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      shown = true;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: AlertDialog(
            backgroundColor: const Color(0xFF161B22),
            content: ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (_, v, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Making room for the decoy…', style: AppFonts.outfit(color: Colors.white)),
                  const SizedBox(height: 16),
                  LinearProgressIndicator(key: const Key('decoy-progress'), value: v > 0 ? v : null),
                ],
              ),
            ),
          ),
        ),
      );
    });
    try {
      if (session.canManageDecoy) {
        await session.createDecoy(pin: pin, onProgress: (v) => progress.value = v);
      } else {
        await session.standInDecoySetup(pin, shown: true);
      }
      if (mounted) setState(() {});
      _toast(
        'Decoy vault created. Lock and open it with its PIN to add content.',
      );
    } on CredentialInUseException {
      await _refused();
    } catch (e) {
      _toast('Could not create decoy: $e', error: true);
    } finally {
      timer.cancel();
      if (shown && mounted) Navigator.of(context).pop();
      progress.dispose();
    }
  }

  /// The duress PIN: opens the decoy, and erases this vault for good.
  Future<void> _setDuressPin() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: Text('Duress PIN', style: AppFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Text(
          'If this PIN is ever entered on the lock screen, this vault and everything in it '
          'is erased for good, and your decoy vault opens instead, as if it were the only one.\n\n'
          'There is no undo, and no warning when it happens. Use it only if you could be '
          'forced to unlock in front of someone.\n\n'
          'If this vault is backed up, its recovery code can still restore it from your server later.',
          style: AppFonts.outfit(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            key: const Key('duress-understood'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('I understand', style: TextStyle(color: Color(0xFFFB7185))),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final pin = await _askNewPin(
      'Set Duress PIN',
      'Different from your PIN and your decoy PIN. Entering it erases this vault.',
    );
    final session = _session;
    if (pin == null || session == null) return;
    try {
      await session.setDuressPin(pin);
      if (mounted) setState(() {});
      _toast('Duress PIN set.');
    } on CredentialInUseException {
      await _refused();
    } catch (e) {
      _toast('Could not set the duress PIN: $e', error: true);
    }
  }

  Future<void> _removeDuressPin() async {
    final session = _session;
    if (session == null) return;
    await session.removeDuressPin();
    if (mounted) setState(() {});
    _toast('Duress PIN removed.');
  }

  /// Copies this vault (and its decoy) to a file the user picks, with a
  /// one-time transfer code. See VaultMover.
  Future<void> _moveOut() async {
    final vaults = context.read<VaultService>();
    final unlock = context.read<UnlockProvider>();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: Text('Move to another phone or app', style: AppFonts.outfit(color: Colors.white)),
        content: Text(
          'This copies the vault file, still encrypted, to a place you choose (a memory card, a USB drive, '
          'your computer). You then get a one-time transfer code.\n\n'
          'On the other phone (or after reinstalling the app), choose "Move a vault here" when setting up, '
          'pick the file and enter the code. You set new PINs there.\n\n'
          'Anyone with both the file and the code can open what\'s in it without a PIN: keep them apart, and '
          'delete the file once the move is done. This vault stays as it is.',
          style: AppFonts.outfit(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(key: const Key('move-out-go'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Choose where')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final uri = await unlock.withoutAutoLock(() => VaultMover.pickDestination('trim-projects.bak'));
    if (uri == null || !mounted) return;
    final progress = ValueNotifier<double?>(null);
    var copying = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          backgroundColor: const Color(0xFF161B22),
          content: ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (_, v, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Copying the vault…', style: AppFonts.outfit(color: Colors.white70)),
                const SizedBox(height: 14),
                LinearProgressIndicator(value: v, color: const Color(0xFF34D399)),
              ],
            ),
          ),
        ),
      ),
    );
    Future<void> poll() async {
      while (copying) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        try {
          final p = await VaultMover.progress();
          if (p.total > 0) progress.value = p.done / p.total;
        } catch (_) {}
      }
    }

    poll();
    Uint8List? code;
    Object? failure;
    try {
      code = await vaults.whileBusy(() => VaultMover.moveOut(vaults, uri));
    } catch (e) {
      failure = e;
      try {
        await VaultMover.deleteCopy(uri);
      } catch (_) {}
    } finally {
      copying = false;
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    if (!mounted) return;
    if (failure != null || code == null) {
      _toast('The vault could not be copied: $failure', error: true);
      return;
    }
    final text = VaultMover.formatCode(code);
    code.fillRange(0, code.length, 0);
    await unlock.holdingInactivityLock(() => showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF161B22),
            title: Text('Transfer code', style: AppFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Write this down. It is shown only now, and the copy can\'t be moved in without it.',
                    style: AppFonts.outfit(fontSize: 13, color: Colors.white70)),
                const SizedBox(height: 14),
                Text(text, key: const Key('move-code'), style: AppFonts.firaCode(fontSize: 16, color: Colors.white, height: 1.6)),
              ],
            ),
            actions: [
              TextButton(key: const Key('move-code-done'), onPressed: () => Navigator.pop(ctx), child: const Text('I wrote it down')),
            ],
          ),
        ));
  }

  Future<void> _removeDecoy() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        title: Text(
          'Remove decoy vault?',
          style: AppFonts.outfit(color: Colors.white),
        ),
        content: Text(
          'Everything in the decoy vault is erased. This cannot be undone.',
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
              'Remove',
              style: TextStyle(color: Color(0xFFFB7185)),
            ),
          ),
        ],
      ),
    );
    final session = _session;
    if (ok != true || session == null) return;
    if (session.hasDecoy) {
      await session.removeDecoy();
    } else {
      await session.standInDecoySetup('', shown: false);
    }
    if (mounted) setState(() {});
    _toast('Decoy vault removed.');
  }

  @override
  Widget build(BuildContext context) {
    final session = context.read<VaultService>().session;
    // Both vaults show the same decoy section, so it can't tell them apart.
    const canDecoy = true;
    final hasDecoy = session?.showsDecoy ?? false;
    return Scaffold(
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
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Security & Settings',
          style: AppFonts.outfit(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        children: [
          _buildSectionHeader('ACCESS & CREDENTIALS'),
          _buildSettingCard(
            icon: Icons.pin_rounded,
            color: const Color(0xFF34D399),
            title: 'Change PIN',
            subtitle: 'The PIN that opens this vault',
            onTap: () => _runPinChange(decoy: false),
          ),

          if (canDecoy) ...[
            const SizedBox(height: 24),
            _buildSectionHeader('DECOY VAULT'),
            if (!hasDecoy)
              _buildSettingCard(
                icon: Icons.theater_comedy_rounded,
                color: const Color(0xFFF59E0B),
                title: 'Set Up Decoy Vault',
                subtitle: 'A second PIN that opens a harmless vault',
                onTap: _createDecoy,
              )
            else if (session?.canManageDecoy == true && session!.decoyDamaged)
              _buildSettingCard(
                icon: Icons.report_problem_rounded,
                color: const Color(0xFFFB7185),
                title: 'Decoy Vault Is Damaged',
                subtitle: "It can't be opened. Remove it and set it up again; this vault is unaffected.",
                onTap: _removeDecoy,
              )
            else ...[
              _buildSettingCard(
                icon: Icons.pin_outlined,
                color: const Color(0xFFF59E0B),
                title: 'Change Decoy PIN',
                subtitle: 'The PIN you can give up under pressure',
                onTap: () => _runPinChange(decoy: true),
              ),
              const SizedBox(height: 8),
              _buildSettingCard(
                icon: Icons.delete_forever_rounded,
                color: const Color(0xFFFB7185),
                title: 'Remove Decoy Vault',
                subtitle: 'Erases the decoy and its contents',
                onTap: _removeDecoy,
              ),
              const SizedBox(height: 8),
              if (session?.hasDuressPin == true) ...[
                _buildSettingCard(
                  icon: Icons.local_fire_department_rounded,
                  color: const Color(0xFFFB7185),
                  title: 'Change Duress PIN',
                  subtitle: 'Opens the decoy and erases this vault',
                  onTap: _setDuressPin,
                ),
                const SizedBox(height: 8),
                _buildSettingCard(
                  icon: Icons.remove_circle_outline_rounded,
                  color: Colors.white54,
                  title: 'Remove Duress PIN',
                  subtitle: 'Only your PIN and the decoy PIN will open anything',
                  onTap: _removeDuressPin,
                ),
              ] else
                _buildSettingCard(
                  icon: Icons.local_fire_department_rounded,
                  color: const Color(0xFFFB7185),
                  title: 'Set Up Duress PIN',
                  subtitle: 'A PIN that opens the decoy and erases this vault',
                  onTap: _setDuressPin,
                ),
            ],
          ],

          const SizedBox(height: 24),
          _buildSectionHeader('RECORDING'),
          _buildSettingCard(
            icon: Icons.mic_rounded,
            color: const Color(0xFFF43F5E),
            title: 'Record audio',
            subtitle: 'Straight into the vault, encrypted as it goes',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const RecorderScreen()),
            ),
          ),
          _buildSettingCard(
            icon: Icons.screen_lock_portrait_rounded,
            color: const Color(0xFFA78BFA),
            title: 'Hidden recorder',
            subtitle: 'Volume or assistant button records with the screen off',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const HiddenRecorderScreen()),
            ),
          ),

          const SizedBox(height: 24),
          _buildSectionHeader('BACKUP'),
          _buildSettingCard(
            icon: Icons.cloud_upload_rounded,
            color: const Color(0xFF38BDF8),
            title: 'Backup',
            subtitle: 'Send encrypted copies to a server you trust',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BackupScreen()),
            ),
          ),
          const SizedBox(height: 8),
          _buildSettingCard(
            icon: Icons.drive_file_move_rounded,
            color: const Color(0xFF34D399),
            title: 'Move to Another Phone or App',
            subtitle: 'Copy this vault, encrypted, to a file the other side opens',
            onTap: _moveOut,
          ),

          const SizedBox(height: 24),
          _buildSectionHeader('LOCKDOWN & TIMEOUTS'),

          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF161B22),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    'Auto-Lock on App Switch',
                    style: AppFonts.outfit(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  subtitle: Text(
                    'Lock and clear keys from memory when you leave the app',
                    style: AppFonts.outfit(
                      fontSize: 12,
                      color: Colors.white54,
                    ),
                  ),
                  value: _autoLockOnSwitch,
                  activeThumbColor: const Color(0xFFA78BFA),
                  onChanged: (val) async {
                    setState(() => _autoLockOnSwitch = val);
                    await _authService.setAutoLockOnSwitch(val);
                    if (context.mounted) {
                      await context
                          .read<UnlockProvider>()
                          .reloadSettings();
                    }
                  },
                ),
                const Divider(color: Colors.white10),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    'Inactivity Auto-Lock Timeout',
                    style: AppFonts.outfit(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  subtitle: Text(
                    '$_inactivityTimeout seconds of idle touch',
                    style: AppFonts.outfit(
                      fontSize: 12,
                      color: Colors.white54,
                    ),
                  ),
                  trailing: DropdownButton<int>(
                    value: _inactivityTimeout,
                    dropdownColor: const Color(0xFF1F2937),
                    underline: const SizedBox(),
                    style: AppFonts.outfit(
                      color: const Color(0xFFA78BFA),
                      fontWeight: FontWeight.bold,
                    ),
                    items: const [
                      DropdownMenuItem(value: 15, child: Text('15s')),
                      DropdownMenuItem(value: 30, child: Text('30s')),
                      DropdownMenuItem(value: 60, child: Text('60s')),
                      DropdownMenuItem(value: 120, child: Text('2m')),
                    ],
                    onChanged: (val) async {
                      if (val == null) return;
                      setState(() => _inactivityTimeout = val);
                      await _authService.setInactivityTimeout(val);
                      if (context.mounted) {
                        await context
                            .read<UnlockProvider>()
                            .reloadSettings();
                      }
                    },
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),
          _buildSectionHeader('SECURITY & THREAT MODEL'),

          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF161B22),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSecurityBadge(
                  'File Encryption',
                  'AES-256-GCM per 64 KB chunk; any tampering is detected',
                ),
                const SizedBox(height: 10),
                _buildSecurityBadge(
                  'Key Protection',
                  'PIN stretched with Argon2id and bound to this phone\'s secure hardware',
                ),
                const SizedBox(height: 10),
                _buildSecurityBadge(
                  'Hard Shake Panic',
                  'Shake hard to lock instantly and clear keys from memory',
                ),
                const SizedBox(height: 10),
                _buildSecurityBadge(
                  'Plausible Cover',
                  'Native-styled Files Explorer disguise with covert entry',
                ),
                const SizedBox(height: 10),
                _buildSecurityBadge(
                  'Memory Protection',
                  'Keys cleared on lock; open files cleared when closed',
                ),
              ],
            ),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 4),
      child: Text(
        title,
        style: AppFonts.outfit(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: Colors.white38,
        ),
      ),
    );
  }

  Widget _buildSettingCard({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF161B22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: ListTile(
        onTap: onTap,
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        title: Text(
          title,
          style: AppFonts.outfit(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: AppFonts.outfit(fontSize: 12, color: Colors.white54),
        ),
        trailing: const Icon(
          Icons.arrow_forward_ios_rounded,
          color: Colors.white24,
          size: 14,
        ),
      ),
    );
  }

  Widget _buildSecurityBadge(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.check_circle_outline_rounded,
          color: Color(0xFF34D399),
          size: 16,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: AppFonts.outfit(fontSize: 12, color: Colors.white70),
              children: [
                TextSpan(
                  text: '$label: ',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                TextSpan(
                  text: value,
                  style: const TextStyle(color: Colors.white60),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// "Enter a new PIN twice" dialog. It owns its text controllers so they are
/// disposed only when the dialog itself is gone. Disposing them as soon as
/// `showDialog` returns breaks the fields during the closing animation.
class _NewPinDialog extends StatefulWidget {
  final String title;
  final String hint;
  const _NewPinDialog({required this.title, required this.hint});

  @override
  State<_NewPinDialog> createState() => _NewPinDialogState();
}

class _NewPinDialogState extends State<_NewPinDialog> {
  final _a = TextEditingController();
  final _b = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  void _submit() {
    if (_a.text.length < 6) {
      setState(() => _error = 'Use at least 6 characters.');
    } else if (_a.text != _b.text) {
      setState(() => _error = 'PINs do not match.');
    } else {
      Navigator.pop(context, _a.text);
    }
  }

  Widget _field(TextEditingController c, String hint) => TextField(
    enableIMEPersonalizedLearning: false, // keep vault text out of keyboard learning
    controller: c,
    keyboardType: TextInputType.visiblePassword,
    obscureText: true,
    maxLength: 64,
    style: AppFonts.outfit(
      fontSize: 18,
      color: Colors.white,
      letterSpacing: 4,
    ),
    textAlign: TextAlign.center,
    decoration: InputDecoration(
      counterText: '',
      hintText: hint,
      hintStyle: AppFonts.outfit(
        fontSize: 13,
        letterSpacing: 0,
        color: Colors.white24,
      ),
      filled: true,
      fillColor: const Color(0xFF21262D),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF161B22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        widget.title,
        style: AppFonts.outfit(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.hint,
              style: AppFonts.outfit(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 16),
            _field(_a, 'New PIN'),
            const SizedBox(height: 10),
            _field(_b, 'Confirm'),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: AppFonts.outfit(
                  fontSize: 12,
                  color: const Color(0xFFFB7185),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            'Cancel',
            style: AppFonts.outfit(color: Colors.white54),
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFA78BFA),
            foregroundColor: const Color(0xFF090D16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          onPressed: _submit,
          child: Text(
            'Save',
            style: AppFonts.outfit(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
