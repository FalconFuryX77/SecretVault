import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../main.dart' show rootNavigatorKey;
import '../providers/unlock_provider.dart';
import '../services/vault_service.dart';
import '../theme/app_fonts.dart';
import 'normal_files_screen.dart';
import 'vault_home_screen.dart';

/// First-run setup: choose the PIN that encrypts the vault.
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

  String? _errorMessage;
  bool _busy = false;
  bool _showPin = false;
  double? _progress;

  @override
  void dispose() {
    _pinController.dispose();
    _pinConfirmController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_busy) return;
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
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const NormalFilesScreen()),
        (_) => false,
      );
      rootNavigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => VaultHomeScreen(vaultType: session.type)),
      );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF090D16),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFFA78BFA).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.shield_rounded, color: Color(0xFFA78BFA), size: 20),
            ),
            const SizedBox(width: 10),
            Text('Vault Setup', style: AppFonts.outfit(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              Text(
                'Set Your Vault PIN',
                textAlign: TextAlign.center,
                style: AppFonts.outfit(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 8),
              Text(
                'This PIN encrypts your files, so there is no reset if you forget it. '
                'Use $_minPinLen or more characters. A passphrase is best.',
                textAlign: TextAlign.center,
                style: AppFonts.outfit(fontSize: 14, color: Colors.white60),
              ),
              const SizedBox(height: 20),
              _pinField(_pinController, '$_minPinLen+ digits or a passphrase', TextInputAction.next),
              const SizedBox(height: 12),
              _pinField(_pinConfirmController, 'Confirm PIN', TextInputAction.done, onSubmitted: (_) => _submit()),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _busy ? null : () => setState(() => _showPin = !_showPin),
                  icon: Icon(
                    _showPin ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                    size: 16,
                    color: Colors.white54,
                  ),
                  label: Text(
                    _showPin ? 'Hide' : 'Show',
                    style: AppFonts.outfit(color: Colors.white54, fontSize: 13),
                  ),
                ),
              ),
              if (_busy) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(value: _progress, color: const Color(0xFFA78BFA)),
                const SizedBox(height: 8),
                Text(
                  'Preparing secure storage…',
                  style: AppFonts.outfit(color: Colors.white54, fontSize: 12),
                ),
              ],
              if (_errorMessage != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE11D48).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFE11D48).withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline_rounded, color: Color(0xFFFB7185), size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: AppFonts.outfit(color: const Color(0xFFFB7185), fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _busy ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFA78BFA),
                    foregroundColor: const Color(0xFF090D16),
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(
                    'Create Vault',
                    style: AppFonts.outfit(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'You can add a decoy vault with its own PIN later, in Settings.',
                textAlign: TextAlign.center,
                style: AppFonts.outfit(fontSize: 12, color: Colors.white38),
              ),
            ],
          ),
        ),
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
      controller: controller,
      enabled: !_busy,
      keyboardType: TextInputType.visiblePassword,
      obscureText: !_showPin,
      autocorrect: false,
      enableSuggestions: false,
      maxLength: 64,
      textInputAction: action,
      onSubmitted: onSubmitted,
      style: AppFonts.outfit(fontSize: 20, letterSpacing: _showPin ? 1 : 6, color: Colors.white),
      textAlign: TextAlign.center,
      decoration: InputDecoration(
        counterText: '',
        hintText: hint,
        hintStyle: AppFonts.outfit(fontSize: 14, letterSpacing: 0, color: Colors.white24),
        filled: true,
        fillColor: const Color(0xFF161B22),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      ),
    );
  }
}
