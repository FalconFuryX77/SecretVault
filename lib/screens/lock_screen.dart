import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../models/gesture.dart';
import '../providers/gesture_unlock_provider.dart';
import '../services/security_channel_service.dart';

/// Clean, discrete 4-step motion gesture & biometric unlock portal.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  final TextEditingController _pinController = TextEditingController();

  @override
  void initState() {
    super.initState();
    SecurityChannelService.setSecureFlag(true);
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.96, end: 1.04).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _pinController.dispose();
    SecurityChannelService.setSecureFlag(false);
    super.dispose();
  }

  void _showPinDialog() {
    _pinController.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.pin_rounded, color: Color(0xFFA78BFA), size: 22),
            const SizedBox(width: 8),
            Text(
              'Security PIN',
              style: GoogleFonts.outfit(
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Enter your PIN.',
              style: GoogleFonts.outfit(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _pinController,
              keyboardType: TextInputType.visiblePassword,
              obscureText: true,
              maxLength: 64,
              autofocus: true,
              style: GoogleFonts.outfit(
                fontSize: 22,
                letterSpacing: 8,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                counterText: '',
                filled: true,
                fillColor: const Color(0xFF21262D),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) {
                Navigator.pop(ctx);
                _verifyEnteredPin();
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: GoogleFonts.outfit(color: Colors.white54),
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
            onPressed: () {
              Navigator.pop(ctx);
              _verifyEnteredPin();
            },
            child: Text(
              'Unlock',
              style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  void _verifyEnteredPin() async {
    final pin = _pinController.text.trim();
    if (pin.isEmpty) return;
    final success = await context.read<GestureUnlockProvider>().verifyPin(pin);
    if (!mounted) return;
    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFFE11D48),
          content: Text(
            'Not recognised.',
            style: GoogleFonts.outfit(color: Colors.white),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<GestureUnlockProvider>();

    // Navigation into the vault is handled by NormalFilesScreen, which
    // listens for unlock events.
    final isLockout = provider.state == UnlockState.lockout;
    final isFailed = provider.state == UnlockState.failed;
    final isPanic = provider.state == UnlockState.panicLocked;
    final inputTrail = provider.inputTrail;

    return Scaffold(
      backgroundColor: const Color(0xFF090D16),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: Colors.white70,
            size: 20,
          ),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Top Safe Shield Badge
              Column(
                children: [
                  ScaleTransition(
                    scale: _pulseAnimation,
                    child: Container(
                      width: 88,
                      height: 88,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isPanic
                            ? const Color(0xFFE11D48).withValues(alpha: 0.2)
                            : isFailed
                            ? const Color(0xFFFB7185).withValues(alpha: 0.15)
                            : const Color(0xFFA78BFA).withValues(alpha: 0.12),
                        border: Border.all(
                          color: isPanic
                              ? const Color(0xFFE11D48)
                              : isFailed
                              ? const Color(0xFFFB7185)
                              : const Color(0xFFA78BFA),
                          width: 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: isPanic
                                ? const Color(0xFFE11D48).withValues(alpha: 0.3)
                                : const Color(
                                    0xFFA78BFA,
                                  ).withValues(alpha: 0.15),
                            blurRadius: 24,
                            spreadRadius: 4,
                          ),
                        ],
                      ),
                      child: Icon(
                        isPanic
                            ? Icons.lock_clock_rounded
                            : isLockout
                            ? Icons.lock_outline_rounded
                            : Icons.lock_outline_rounded,
                        size: 38,
                        color: isPanic
                            ? const Color(0xFFFB7185)
                            : isFailed
                            ? const Color(0xFFFB7185)
                            : const Color(0xFFA78BFA),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    isPanic
                        ? 'Locked'
                        : isLockout
                        ? 'Temporarily Locked'
                        : 'Locked',
                    style: GoogleFonts.outfit(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: isPanic ? const Color(0xFFFB7185) : Colors.white,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    isPanic
                        ? 'Keys cleared from memory.'
                        : isLockout
                        ? 'Too many failed attempts. Try again in ${_formatSeconds(provider.lockoutRemaining)}'
                        : isFailed
                        ? 'Not recognised.'
                        : provider.state == UnlockState.authenticating
                        ? 'Checking…'
                        : 'Perform your gesture, then confirm with your fingerprint.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.outfit(
                      fontSize: 13,
                      color: isFailed || isPanic
                          ? const Color(0xFFFB7185)
                          : Colors.white60,
                    ),
                  ),
                ],
              ),

              // 4 Gesture Slot Indicator Nodes
              Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(
                      GestureUnlockProvider.maxPatternLength,
                      (index) {
                        final hasItem = index < inputTrail.length;
                        return Container(
                          width: 14,
                          height: 14,
                          margin: const EdgeInsets.symmetric(horizontal: 5),
                          decoration: BoxDecoration(
                            color: isFailed
                                ? const Color(0xFFE11D48).withValues(alpha: 0.2)
                                : hasItem
                                ? const Color(0xFFA78BFA)
                                : const Color(0xFF161B22),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isFailed
                                  ? const Color(0xFFFB7185)
                                  : hasItem
                                  ? const Color(0xFFA78BFA)
                                  : Colors.white12,
                              width: hasItem || isFailed ? 2 : 1,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (inputTrail.isNotEmpty)
                    TextButton.icon(
                      onPressed: () => provider.clearInputTrail(),
                      icon: const Icon(
                        Icons.refresh_rounded,
                        size: 16,
                        color: Colors.white38,
                      ),
                      label: Text(
                        'Reset',
                        style: GoogleFonts.outfit(
                          color: Colors.white38,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),

              // Bottom Actions: Tap gestures + Biometrics
              Column(
                children: [
                  // Quick Tilt Buttons (Accessibility / Fallback)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      _buildQuickAction(
                        Gesture.left,
                        'Left',
                        Icons.arrow_back_rounded,
                        provider,
                      ),
                      _buildQuickAction(
                        Gesture.up,
                        'Up',
                        Icons.arrow_upward_rounded,
                        provider,
                      ),
                      _buildQuickAction(
                        Gesture.down,
                        'Down',
                        Icons.arrow_downward_rounded,
                        provider,
                      ),
                      _buildQuickAction(
                        Gesture.right,
                        'Right',
                        Icons.arrow_forward_rounded,
                        provider,
                      ),
                      _buildQuickAction(
                        Gesture.shake,
                        'Shake',
                        Icons.vibration_rounded,
                        provider,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Biometrics & PIN Buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF161B22),
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white12),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 14,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: isLockout ? null : _showPinDialog,
                        icon: const Icon(
                          Icons.pin_rounded,
                          color: Color(0xFFA78BFA),
                          size: 18,
                        ),
                        label: Text(
                          'PIN Code',
                          style: GoogleFonts.outfit(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickAction(
    Gesture gesture,
    String label,
    IconData icon,
    GestureUnlockProvider provider,
  ) {
    return ActionChip(
      backgroundColor: const Color(0xFF161B22),
      side: const BorderSide(color: Colors.white12),
      avatar: Icon(icon, size: 15, color: const Color(0xFFA78BFA)),
      label: Text(
        label,
        style: GoogleFonts.outfit(color: Colors.white70, fontSize: 12),
      ),
      onPressed: provider.state == UnlockState.lockout
          ? null
          : () => provider.addManualGesture(gesture),
    );
  }

  String _formatSeconds(int s) {
    if (s < 60) return '${s}s';
    final m = s ~/ 60;
    final r = s % 60;
    return r == 0 ? '${m}m' : '${m}m ${r}s';
  }
}
