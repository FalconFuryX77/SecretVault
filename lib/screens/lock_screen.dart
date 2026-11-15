import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/vault_state.dart';
import '../providers/unlock_provider.dart';
import '../services/security_channel_service.dart';
import '../theme/app_fonts.dart';

/// The hidden lock screen: type the PIN, press Unlock.
///
/// The same field takes either PIN. The real one opens the real vault, the
/// decoy one opens the decoy, and nothing on screen says which happened.
/// Navigation into the vault is handled by NormalFilesScreen, which listens
/// for unlock events.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final TextEditingController _pinController = TextEditingController();
  final FocusNode _pinFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    SecurityChannelService.setSecureFlag(true);
  }

  @override
  void dispose() {
    _pinController.dispose();
    _pinFocus.dispose();
    SecurityChannelService.setSecureFlag(false);
    super.dispose();
  }

  Future<void> _submit() async {
    // No trimming: setup stores exactly what was typed, so a passphrase with
    // a leading or trailing space must be accepted exactly as typed.
    final pin = _pinController.text;
    if (pin.isEmpty) return;
    _pinController.clear();
    final ok = await context.read<UnlockProvider>().verifyPin(pin);
    if (!ok && mounted) _pinFocus.requestFocus();
  }

  String _formatSeconds(int s) {
    if (s < 60) return '${s}s';
    final m = s ~/ 60;
    final r = s % 60;
    return r == 0 ? '${m}m' : '${m}m ${r}s';
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<UnlockProvider>();
    final isLockout = provider.state == UnlockState.lockout;
    final isFailed = provider.state == UnlockState.failed;
    final isChecking = provider.state == UnlockState.authenticating;
    final accent = isFailed ? const Color(0xFFFB7185) : const Color(0xFFA78BFA);

    final status = isLockout
        ? 'Too many failed attempts. Try again in ${_formatSeconds(provider.lockoutRemaining)}'
        : isFailed
        ? 'Not recognised.'
        : isChecking
        ? 'Checking…'
        : 'Enter your PIN.';

    return Scaffold(
      backgroundColor: const Color(0xFF090D16),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white70, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Column(
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accent.withValues(alpha: 0.12),
                  border: Border.all(color: accent, width: 2),
                ),
                child: Icon(Icons.lock_outline_rounded, size: 32, color: accent),
              ),
              const SizedBox(height: 14),
              Text(
                isLockout ? 'Temporarily Locked' : 'Locked',
                style: AppFonts.outfit(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 6),
              Text(
                status,
                textAlign: TextAlign.center,
                style: AppFonts.outfit(fontSize: 13, color: isFailed ? const Color(0xFFFB7185) : Colors.white60),
              ),
              const SizedBox(height: 24),
              TextField(
                enableIMEPersonalizedLearning: false, // keep vault text out of keyboard learning
                controller: _pinController,
                focusNode: _pinFocus,
                autofocus: true,
                enabled: !isLockout && !isChecking,
                keyboardType: TextInputType.visiblePassword,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                maxLength: 64,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                style: AppFonts.outfit(
                  fontSize: 22,
                  letterSpacing: 8,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  counterText: '',
                  filled: true,
                  fillColor: const Color(0xFF161B22),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: isLockout || isChecking ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFA78BFA),
                    foregroundColor: const Color(0xFF090D16),
                    disabledBackgroundColor: const Color(0xFF21262D),
                    disabledForegroundColor: Colors.white38,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text('Unlock', style: AppFonts.outfit(fontSize: 15, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
