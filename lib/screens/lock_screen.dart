import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/vault_state.dart';
import '../providers/unlock_provider.dart';
import '../services/security_channel_service.dart';
import '../theme/ui.dart';

/// The hidden lock screen: type the PIN, press Unlock.
///
/// The same field takes either PIN. The real one opens the real vault, the
/// decoy one opens the decoy, and nothing on screen says which happened.
/// Navigation into the vault is handled by TrimmerHomeScreen, which listens
/// for unlock events.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> with SingleTickerProviderStateMixin {
  final TextEditingController _pinController = TextEditingController();
  final FocusNode _pinFocus = FocusNode();
  late final AnimationController _shake =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  bool _wasFailed = false;

  @override
  void initState() {
    super.initState();
    SecurityChannelService.setSecureFlag(true);
  }

  @override
  void dispose() {
    _pinController.dispose();
    _pinFocus.dispose();
    _shake.dispose();
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
    if (isFailed && !_wasFailed) {
      // A wrong PIN: the field gives a short shake and the phone a light tick.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _shake.forward(from: 0);
        HapticFeedback.lightImpact();
      });
    }
    _wasFailed = isFailed;

    final status = isLockout
        ? 'Too many failed attempts. Try again in ${_formatSeconds(provider.lockoutRemaining)}'
        : isFailed
            ? 'Not recognised.'
            : isChecking
                ? 'Checking…'
                : 'Enter your PIN.';

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, size: 22),
          tooltip: 'Back',
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Ui.gutter, 24, Ui.gutter, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(isLockout ? Icons.lock_clock_outlined : Icons.lock_outline_rounded,
                    size: 20, color: isFailed ? Ui.alert : Ui.ink2),
                const SizedBox(width: 8),
                Text(isLockout ? 'Temporarily locked' : 'Locked', style: Ui.label()),
              ]),
              const SizedBox(height: 14),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: Text(
                  status,
                  key: ValueKey(status),
                  style: Ui.title(color: isFailed ? Ui.alert : Ui.ink),
                ),
              ),
              const SizedBox(height: 32),
              AnimatedBuilder(
                animation: _shake,
                builder: (_, child) {
                  final t = _shake.value;
                  final dx = math.sin(t * math.pi * 6) * 9 * (1 - t);
                  return Transform.translate(offset: Offset(dx, 0), child: child);
                },
                child: TextField(
                  enableIMEPersonalizedLearning: false, // keep vault text out of keyboard learning
                  controller: _pinController,
                  focusNode: _pinFocus,
                  autofocus: true,
                  enabled: !isLockout && !isChecking,
                  keyboardType: TextInputType.visiblePassword,
                  obscureText: true,
                  obscuringCharacter: '•',
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 64,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  style: Ui.body(size: 22).copyWith(letterSpacing: 4),
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: 'PIN or passphrase',
                    hintStyle: Ui.body(color: Ui.ink3).copyWith(letterSpacing: 0),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(Ui.control),
                      borderSide: BorderSide(color: isFailed ? Ui.alert : Colors.transparent, width: 1.2),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              UiPrimaryButton(
                label: 'Unlock',
                busy: isChecking,
                onPressed: isLockout ? null : _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
