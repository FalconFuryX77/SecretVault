import 'package:flutter/material.dart';
import '../theme/app_fonts.dart';
import 'package:provider/provider.dart';
import '../providers/unlock_provider.dart';
import '../services/auth_service.dart';
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
        if (session.canManageDecoy) {
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
    try {
      if (session.canManageDecoy) {
        await session.createDecoy(pin: pin);
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
    }
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
    if (session.canManageDecoy) {
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
