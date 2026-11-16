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
import '../theme/ui.dart';

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
            ? Ui.alert
            : Ui.raised,
        content: Text(msg),
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
            content: ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (_, v, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Making room for the decoy…', style: AppFonts.ui(color: Ui.ink)),
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
        title: Text('Duress PIN'),
        content: Text(
          'If this PIN is ever entered on the lock screen, this vault and everything in it '
          'is erased for good, and your decoy vault opens instead, as if it were the only one.\n\n'
          'There is no undo, and no warning when it happens. Use it only if you could be '
          'forced to unlock in front of someone.\n\n'
          'If this vault is backed up, its recovery code can still restore it from your server later.',
          style: AppFonts.ui(color: Ui.ink2, fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            key: const Key('duress-understood'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('I understand', style: TextStyle(color: Ui.alert)),
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
        title: Text('Move to another phone or app'),
        content: Text(
          'This copies the vault file, still encrypted, to a place you choose (a memory card, a USB drive, '
          'your computer). You then get a one-time transfer code.\n\n'
          'On the other phone (or after reinstalling the app), choose "Move a vault here" when setting up, '
          'pick the file and enter the code. You set new PINs there.\n\n'
          'Anyone with both the file and the code can open what\'s in it without a PIN: keep them apart, and '
          'delete the file once the move is done. This vault stays as it is.',
          style: AppFonts.ui(color: Ui.ink2, fontSize: 13),
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
          content: ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (_, v, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Copying the vault…', style: AppFonts.ui(color: Ui.ink2)),
                const SizedBox(height: 14),
                LinearProgressIndicator(value: v, color: Ui.ink),
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
            title: Text('Transfer code'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Write this down. It is shown only now, and the copy can\'t be moved in without it.',
                    style: AppFonts.ui(fontSize: 13, color: Ui.ink2)),
                const SizedBox(height: 14),
                Text(text, key: const Key('move-code'), style: AppFonts.firaCode(fontSize: 16, color: Ui.ink, height: 1.6)),
              ],
            ),
            actions: [
              TextButton(key: const Key('move-code-done'), onPressed: () => Navigator.pop(ctx), child: const Text('I wrote it down')),
            ],
          ),
        ));
  }

  Future<void> _removeDecoy() async {
    final ok = await confirmByHolding(
      context,
      title: 'Remove the decoy vault?',
      message: 'Everything in it is erased, along with any vault it holds. This cannot be undone.',
      action: 'Hold to remove',
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
    // Every vault shows the same decoy section, so it can't tell them apart.
    final hasDecoy = session?.showsDecoy ?? false;
    void open(Widget screen) => Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, size: 22),
          tooltip: 'Back',
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          UiGroup(label: 'Access', children: [
            UiRow(
              icon: Icons.pin_outlined,
              title: 'Change PIN',
              detail: 'The PIN that opens this vault',
              onTap: () => _runPinChange(decoy: false),
            ),
          ]),
          UiGroup(label: 'Decoy vault', children: [
            if (!hasDecoy)
              UiRow(
                icon: Icons.theater_comedy_outlined,
                title: 'Set up a decoy vault',
                detail: 'A second PIN that opens a harmless vault',
                onTap: _createDecoy,
              )
            else if (session?.canManageDecoy == true && session!.decoyDamaged)
              UiRow(
                icon: Icons.report_problem_outlined,
                title: 'The decoy vault is damaged',
                detail: "It can't be opened. Remove it and set it up again; this vault is unaffected.",
                destructive: true,
                onTap: _removeDecoy,
              )
            else ...[
              UiRow(
                icon: Icons.pin_outlined,
                title: 'Change decoy PIN',
                detail: 'The PIN you can give up under pressure',
                onTap: () => _runPinChange(decoy: true),
              ),
              if (session?.hasDuressPin == true) ...[
                UiRow(
                  icon: Icons.local_fire_department_outlined,
                  title: 'Change duress PIN',
                  detail: 'Opens the decoy and erases this vault',
                  onTap: _setDuressPin,
                ),
                UiRow(
                  icon: Icons.remove_circle_outline_rounded,
                  title: 'Remove duress PIN',
                  onTap: _removeDuressPin,
                ),
              ] else
                UiRow(
                  icon: Icons.local_fire_department_outlined,
                  title: 'Set up a duress PIN',
                  detail: 'Opens the decoy and erases this vault',
                  onTap: _setDuressPin,
                ),
              UiRow(
                icon: Icons.delete_outline_rounded,
                title: 'Remove decoy vault',
                detail: 'Erases the decoy and everything in it',
                destructive: true,
                onTap: _removeDecoy,
              ),
            ],
          ]),
          UiGroup(label: 'Recording', children: [
            UiRow(
              icon: Icons.mic_none_rounded,
              title: 'Record audio',
              onTap: () => open(const RecorderScreen()),
            ),
            UiRow(
              icon: Icons.screen_lock_portrait_outlined,
              title: 'Hidden recorder',
              detail: 'Record with the screen off',
              onTap: () => open(const HiddenRecorderScreen()),
            ),
          ]),
          UiGroup(label: 'Backup', children: [
            UiRow(
              icon: Icons.cloud_upload_outlined,
              title: 'Backup',
              detail: 'Encrypted copies on a server you trust',
              onTap: () => open(const BackupScreen()),
            ),
            UiRow(
              icon: Icons.drive_file_move_outline,
              title: 'Move to another phone or app',
              onTap: _moveOut,
            ),
          ]),
          UiGroup(label: 'Locking', children: [
            UiSwitchRow(
              icon: Icons.swap_horiz_rounded,
              title: 'Lock when I leave the app',
              value: _autoLockOnSwitch,
              onChanged: (val) async {
                setState(() => _autoLockOnSwitch = val);
                await _authService.setAutoLockOnSwitch(val);
                if (context.mounted) await context.read<UnlockProvider>().reloadSettings();
              },
            ),
            UiRow(
              icon: Icons.timer_outlined,
              title: 'Lock when idle',
              chevron: false,
              trailing: DropdownButton<int>(
                key: const Key('idle-timeout'),
                value: _inactivityTimeout,
                dropdownColor: Ui.raised,
                underline: const SizedBox(),
                borderRadius: BorderRadius.circular(12),
                icon: const Icon(Icons.unfold_more_rounded, size: 16, color: Ui.ink3),
                style: Ui.data(size: 14, color: Ui.ink),
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
                  if (context.mounted) await context.read<UnlockProvider>().reloadSettings();
                },
              ),
            ),
          ]),
          const UiGroup(label: "How it's protected", dividerIndent: 16, children: [
            UiRow(title: 'Files', detail: 'AES-256-GCM in 64 KB pieces; any change to them is detected', chevron: false),
            UiRow(title: 'Keys', detail: "Your PIN, stretched with Argon2id and bound to this phone's secure hardware", chevron: false),
            UiRow(title: 'Panic', detail: 'Shake hard, or tap the power icon, to lock at once and clear the keys', chevron: false),
            UiRow(title: 'Cover', detail: 'A working video trimmer; three taps on its title open this lock screen', chevron: false),
          ]),
        ],
      ),
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
    style: AppFonts.ui(
      fontSize: 18,
      color: Ui.ink,
      letterSpacing: 4,
    ),
    textAlign: TextAlign.center,
    decoration: InputDecoration(
      counterText: '',
      hintText: hint,
      hintStyle: AppFonts.ui(
        fontSize: 13,
        letterSpacing: 0,
        color: Ui.ink3,
      ),
      filled: true,
      fillColor: Ui.raised,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.title,
        style: AppFonts.ui(
          color: Ui.ink,
          fontWeight: FontWeight.w500,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.hint,
              style: AppFonts.ui(fontSize: 13, color: Ui.ink2),
            ),
            const SizedBox(height: 16),
            _field(_a, 'New PIN'),
            const SizedBox(height: 10),
            _field(_b, 'Confirm'),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: AppFonts.ui(
                  fontSize: 12,
                  color: Ui.alert,
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
            style: AppFonts.ui(color: Ui.ink2),
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Ui.signal,
            foregroundColor: Ui.canvas,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          onPressed: _submit,
          child: Text(
            'Save',
            style: AppFonts.ui(fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }
}
