import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../navigation/vault_routes.dart';
import '../providers/unlock_provider.dart';
import '../services/vault_service.dart';
import '../sync/vault_sync.dart';
import '../theme/app_fonts.dart';
import '../vault/vault_container.dart';
import 'move_in_screen.dart';
import '../cover/trimmer_home_screen.dart';
import 'vault_home_screen.dart';
import '../theme/ui.dart';

/// First-run setup: choose the PIN that encrypts the vault, or restore a
/// backed-up vault onto this phone (server address and recovery code; the
/// files come straight into the new vault, never onto storage).
///
/// The PIN is the key. It is never stored, so there is no reset. A decoy
/// vault with its own PIN can be added later from Settings.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  static const int _minPinLen = 6;

  final TextEditingController _pinController = TextEditingController();
  final TextEditingController _pinConfirmController = TextEditingController();

  final TextEditingController _server = TextEditingController();
  final TextEditingController _code = TextEditingController();

  String? _errorMessage;
  bool _busy = false;
  bool _showPin = false;
  double? _progress;
  String _progressText = 'Preparing secure storage…';

  /// Restoring from a backup instead of starting empty.
  bool _restore = false;
  bool _tor = false;

  /// The vault created for a restore that didn't finish (no signal): trying
  /// again carries on into it.
  VaultSession? _restoreInto;

  @override
  void dispose() {
    _pinController.dispose();
    _pinConfirmController.dispose();
    _server.dispose();
    _code.dispose();
    super.dispose();
  }

  void _submit() {
    if (_busy) return;
    if (_restore) {
      try {
        VaultSync.normalizeServer(_server.text);
      } on SyncSetupException catch (e) {
        setState(() => _errorMessage = e.message);
        return;
      }
      if (VaultSync.parseRecoverySecret(_code.text) == null) {
        setState(() => _errorMessage = 'Enter the recovery code: 16 groups of 4 characters.');
        return;
      }
      if (_restoreInto != null) {
        _runRestore(_restoreInto!);
        return;
      }
    }
    final pin = _pinController.text;
    if (pin.length < _minPinLen) {
      setState(() => _errorMessage = 'Use at least $_minPinLen characters. Longer is much stronger.');
      return;
    }
    if (pin != _pinConfirmController.text) {
      setState(() => _errorMessage = 'The two entries do not match.');
      return;
    }
    _createVault(pin);
  }

  Future<void> _createVault(String pin) async {
    final vault = context.read<VaultService>();
    final unlock = context.read<UnlockProvider>();
    FocusScope.of(context).unfocus();
    setState(() {
      _errorMessage = null;
      _busy = true;
      _progress = 0;
    });
    try {
      final session = await vault.create(
        pin: pin,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      _pinController.clear();
      _pinConfirmController.clear();

      await unlock.onSetupComplete();
      if (!mounted) return;
      if (_restore) {
        _restoreInto = session;
        await _runRestore(session);
        return;
      }
      _open(session);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
          _errorMessage = 'Setup failed: $e';
        });
      }
    }
  }

  /// Brings the backed-up files into [session]. Can be repeated after a
  /// failure; files already restored aren't fetched again.
  Future<void> _runRestore(VaultSession session) async {
    final vault = context.read<VaultService>();
    final unlock = context.read<UnlockProvider>();
    final sync = VaultSync();
    final secret = VaultSync.parseRecoverySecret(_code.text)!;
    setState(() {
      _busy = true;
      _errorMessage = null;
      _progress = null;
      _progressText = 'Finding your backup…';
    });
    void progress(int done, int total, String title) {
      unlock.onUserActivity();
      if (!mounted) return;
      setState(() {
        _progress = total == 0 ? 1 : done / total;
        _progressText = done >= total ? 'Finishing…' : 'Restoring ${done + 1} of $total: $title';
      });
    }

    try {
      final RestoreSummary r = await vault.whileBusy(() => sync.status(session).isConnected
          ? sync.restoreMissing(session, onProgress: progress)
          : sync.recoverInto(session, server: _server.text, recoverySecret: secret, tor: _tor, onProgress: progress));
      _code.clear();
      if (!mounted) return;
      if (r.failed.isNotEmpty) {
        setState(() {
          _busy = false;
          _errorMessage = '${r.failed.length} files could not be restored. Try again, or open the vault and '
              'restore them later from Backup.';
        });
        return;
      }
      _open(session);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
          _errorMessage = e is SyncSetupException ? e.message : 'The restore stopped: $e. Try again to carry on.';
        });
      }
    }
  }

  void _open(VaultSession session) {
    if (!mounted) return;
    try {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const TrimmerHomeScreen()),
        (_) => false,
      );
      rootNavigatorKey.currentState?.push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '${vaultRoutePrefix}home'),
          builder: (_) => const VaultHomeScreen(),
        ),
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final title = _restore ? 'Restore from a backup' : 'Set your vault PIN';
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Ui.gutter, 8, Ui.gutter, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(_restore ? Icons.cloud_download_outlined : Icons.lock_outline_rounded, size: 20, color: Ui.ink2),
                const SizedBox(width: 8),
                Text(_restore ? 'Restore' : 'New vault', style: Ui.label()),
              ]),
              const SizedBox(height: 14),
              Text(title, style: Ui.title()),
              const SizedBox(height: 10),
              Text(
                _restore
                    ? 'Enter the backup server and your recovery code, then a PIN for the vault on this phone '
                        '(it can differ from the old one).'
                    : 'This PIN encrypts your files, so there is no reset if you forget it. '
                        'Use $_minPinLen or more characters. A passphrase is best.',
                style: Ui.body(color: Ui.ink2, size: 15),
              ),
              const SizedBox(height: 28),
              if (_restore) ...[
                _plainField(_server, 'Server address (https://…)', 'restore-server', TextInputType.url),
                const SizedBox(height: 12),
                _plainField(_code, 'Recovery code', 'restore-code', TextInputType.visiblePassword, lines: 2),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _tor,
                  onChanged: _busy ? null : (v) => setState(() => _tor = v),
                  title: Text('Connect through Tor (Orbot)', style: Ui.body(size: 15)),
                ),
                const SizedBox(height: 8),
              ],
              if (_restoreInto == null) ...[
                _pinField(_pinController, '$_minPinLen+ digits or a passphrase', TextInputAction.next),
                const SizedBox(height: 12),
                _pinField(_pinConfirmController, 'Confirm PIN', TextInputAction.done, onSubmitted: (_) => _submit()),
              ],
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _busy ? null : () => setState(() => _showPin = !_showPin),
                  style: TextButton.styleFrom(foregroundColor: Ui.ink2),
                  icon: Icon(_showPin ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18),
                  label: Text(_showPin ? 'Hide' : 'Show', style: Ui.detail()),
                ),
              ),
              if (_busy) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(value: _progress, minHeight: 3),
                ),
                const SizedBox(height: 8),
                Text(
                  _progressText,
                  key: const Key('setup-progress'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Ui.data(),
                ),
              ],
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(Icons.error_outline_rounded, color: Ui.alert, size: 18),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_errorMessage!, style: Ui.detail(color: Ui.alert))),
                ]),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _busy ? null : _submit,
                  child: Text(
                    _restoreInto != null ? 'Try again' : (_restore ? 'Restore vault' : 'Create vault'),
                    key: const Key('setup-submit'),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              if (_restoreInto != null)
                _link(Icons.lock_open_outlined, 'Open the vault and restore later', () => _open(_restoreInto!))
              else
                _link(
                  _restore ? Icons.add_rounded : Icons.cloud_download_outlined,
                  _restore ? 'Start an empty vault instead' : 'Restore from a backup instead',
                  () => setState(() {
                    _restore = !_restore;
                    _errorMessage = null;
                  }),
                  key: const Key('setup-restore-toggle'),
                ),
              if (_restoreInto == null && !_restore)
                _link(
                  Icons.drive_file_move_outline,
                  'Move a vault here from another phone or app',
                  () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MoveInScreen())),
                  key: const Key('setup-move-in'),
                ),
              const SizedBox(height: 18),
              Text('You can add a decoy vault with its own PIN later, in Settings.', style: Ui.detail(color: Ui.ink3)),
            ],
          ),
        ),
      ),
    );
  }

  /// A secondary way through setup: plain text, not another button.
  Widget _link(IconData icon, String label, VoidCallback onTap, {Key? key}) => InkWell(
        key: key,
        borderRadius: BorderRadius.circular(8),
        onTap: _busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(children: [
            Icon(icon, size: 19, color: Ui.ink2),
            const SizedBox(width: 12),
            Expanded(child: Text(label, style: Ui.body(size: 15))),
            const Icon(Icons.chevron_right_rounded, size: 20, color: Ui.ink3),
          ]),
        ),
      );

  Widget _plainField(TextEditingController c, String hint, String key, TextInputType type, {int lines = 1}) {
    return TextField(
      key: Key(key),
      controller: c,
      enabled: !_busy,
      keyboardType: type,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      minLines: lines,
      maxLines: lines,
      style: AppFonts.firaCode(fontSize: 14, color: Ui.ink),
      decoration: InputDecoration(
        hintText: hint,
      ),
    );
  }

  Widget _pinField(
    TextEditingController controller,
    String hint,
    TextInputAction action, {
    ValueChanged<String>? onSubmitted,
  }) {
    return TextField(
      enableIMEPersonalizedLearning: false, // keep vault text out of keyboard learning
      controller: controller,
      enabled: !_busy,
      keyboardType: TextInputType.visiblePassword,
      obscureText: !_showPin,
      autocorrect: false,
      enableSuggestions: false,
      maxLength: 64,
      textInputAction: action,
      onSubmitted: onSubmitted,
      style: Ui.body(size: 20).copyWith(letterSpacing: _showPin ? 0.5 : 4),
      decoration: InputDecoration(
        counterText: '',
        hintText: hint,
        hintStyle: Ui.body(color: Ui.ink3, size: 15).copyWith(letterSpacing: 0),
      ),
    );
  }
}
