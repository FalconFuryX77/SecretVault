import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../models/gesture.dart';
import '../providers/gesture_unlock_provider.dart';
import '../providers/notes_provider.dart';
import 'notes_list_screen.dart';

class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _shakeController;
  late AnimationController _unlockController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _shakeAnimation;
  late Animation<double> _unlockAnimation;

  UnlockState? _prevState;
  bool _navigated = false;
  bool _hasPromptedBiometrics = false;

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _shakeAnimation = Tween<double>(begin: 0, end: 24).animate(
      CurvedAnimation(parent: _shakeController, curve: Curves.elasticIn),
    );

    _unlockController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _unlockAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _unlockController, curve: Curves.easeOutBack),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _shakeController.dispose();
    _unlockController.dispose();
    super.dispose();
  }

  void _onStateChange(GestureUnlockProvider provider) {
    if (provider.state == UnlockState.locked && !provider.isBiometricVerified && !_hasPromptedBiometrics) {
      _hasPromptedBiometrics = true;
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) provider.authenticateBiometrics();
      });
    }

    final state = provider.state;
    if (state == _prevState) return;
    _prevState = state;

    if (state == UnlockState.failed) {
      _shakeController.forward(from: 0);
    } else if (state == UnlockState.unlocked) {
      _hasPromptedBiometrics = false; // Reset for next time app locks
      _pulseController.stop();
      _unlockController.forward(from: 0);
      if (!_navigated) {
        _navigated = true;
        Future.delayed(const Duration(milliseconds: 600), () {
          if (mounted) _navigateToNotes();
        });
      }
    } else if (state == UnlockState.locked) {
      _navigated = false;
      _unlockController.reset();
      if (!_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
    } else if (state == UnlockState.lockout) {
      _pulseController.stop();
    }
  }

  void _navigateToNotes() {
    context.read<NotesProvider>().loadNotes();
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const NotesListScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.05),
                end: Offset.zero,
              ).animate(CurvedAnimation(
                parent: animation,
                curve: Curves.easeOut,
              )),
              child: child,
            ),
          );
        },
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  void _showPinDialog() {
    final pinController = TextEditingController();
    String? error;

    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1A1744),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
                side: BorderSide(
                  color: Colors.white.withValues(alpha: 0.1),
                ),
              ),
              title: Text(
                'Enter Fallback PIN',
                style: GoogleFonts.outfit(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: TextField(
                      controller: pinController,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      autofocus: true,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        letterSpacing: 8,
                      ),
                      textAlign: TextAlign.center,
                      decoration: InputDecoration(
                        hintText: '••••',
                        hintStyle: TextStyle(
                          color: Colors.white.withValues(alpha: 0.2),
                          letterSpacing: 8,
                        ),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.all(16),
                      ),
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      error!,
                      style: const TextStyle(
                        color: Color(0xFFF87171),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(
                    'Cancel',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFA78BFA),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () async {
                    final provider = context.read<GestureUnlockProvider>();
                    final verified =
                        await provider.verifyPin(pinController.text);
                    if (verified) {
                      if (ctx.mounted) Navigator.pop(ctx);
                    } else {
                      setDialogState(() => error = 'Incorrect PIN');
                    }
                  },
                  child: const Text(
                    'Unlock',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<GestureUnlockProvider>();
    _onStateChange(provider);

    final isLockout = provider.state == UnlockState.lockout;

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: _backgroundGradient(provider.state),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 1),
              // App branding
              Text(
                'SecretVault',
                style: GoogleFonts.outfit(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.3),
                  letterSpacing: 4,
                ),
              ),
              const Spacer(flex: 1),
              // Lock icon
              _buildLockIcon(provider.state),
              const SizedBox(height: 32),
              // Status text
              _buildStatusText(provider),
              const SizedBox(height: 12),
              // Subtitle
              _buildSubtitle(provider),
              const Spacer(flex: 1),
              // Biometric or Gesture block (hidden during lockout)
              if (!isLockout && !provider.isBiometricVerified) _buildBiometricPrompt(provider),
              if (!isLockout && provider.isBiometricVerified) _buildGestureTrail(provider),
              if (isLockout) _buildLockoutCountdown(provider),
              const Spacer(flex: 1),
              // Bottom controls
              _buildBottomControls(provider),
              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
  }

  LinearGradient _backgroundGradient(UnlockState state) {
    switch (state) {
      case UnlockState.unlocked:
        return const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0D4D2B), Color(0xFF0A3D22), Color(0xFF072E19)],
        );
      case UnlockState.failed:
        return const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF4D0D0D), Color(0xFF3D0A0A), Color(0xFF2E0707)],
        );
      case UnlockState.lockout:
        return const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3D1A0A), Color(0xFF2E1007), Color(0xFF1A0C04)],
        );
      default:
        return const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0F0C29), Color(0xFF302B63), Color(0xFF24243E)],
        );
    }
  }

  Widget _buildLockIcon(UnlockState state) {
    final IconData icon;
    final Color color;
    const double size = 80;

    switch (state) {
      case UnlockState.unlocked:
        icon = Icons.lock_open_rounded;
        color = const Color(0xFF4ADE80);
        break;
      case UnlockState.failed:
        icon = Icons.lock_rounded;
        color = const Color(0xFFF87171);
        break;
      case UnlockState.lockout:
        icon = Icons.timer_rounded;
        color = const Color(0xFFFB923C);
        break;
      default:
        icon = Icons.lock_outline_rounded;
        color = const Color(0xFFA78BFA);
    }

    return AnimatedBuilder(
      animation: Listenable.merge([
        _pulseAnimation,
        _shakeAnimation,
        _unlockAnimation,
      ]),
      builder: (context, child) {
        double dx = 0;
        if (state == UnlockState.failed) {
          dx = _shakeAnimation.value *
              ((_shakeController.value * 10).toInt().isEven ? 1 : -1);
        }
        double scale = 1.0;
        if (state == UnlockState.locked || state == UnlockState.recording) {
          scale = _pulseAnimation.value;
        } else if (state == UnlockState.unlocked) {
          scale = 0.8 + (_unlockAnimation.value * 0.4);
        }
        return Transform.translate(
          offset: Offset(dx, 0),
          child: Transform.scale(
            scale: scale,
            child: child,
          ),
        );
      },
      child: Container(
        width: size + 40,
        height: size + 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.1),
          border: Border.all(color: color.withValues(alpha: 0.3), width: 2),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.2),
              blurRadius: 40,
              spreadRadius: 10,
            ),
          ],
        ),
        child: Icon(icon, size: size, color: color),
      ),
    );
  }

  Widget _buildStatusText(GestureUnlockProvider provider) {
    final String text;
    final Color color;

    switch (provider.state) {
      case UnlockState.unlocked:
        text = 'UNLOCKED';
        color = const Color(0xFF4ADE80);
        break;
      case UnlockState.failed:
        text = 'WRONG PATTERN';
        color = const Color(0xFFF87171);
        break;
      case UnlockState.lockout:
        text = 'TOO MANY ATTEMPTS';
        color = const Color(0xFFFB923C);
        break;
      case UnlockState.recording:
        text = 'RECORDING...';
        color = const Color(0xFFFBBF24);
        break;
      default:
        text = 'LOCKED';
        color = const Color(0xFFA78BFA);
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: Text(
        text,
        key: ValueKey(text),
        style: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w800,
          color: color,
          letterSpacing: 4,
        ),
      ),
    );
  }

  Widget _buildSubtitle(GestureUnlockProvider provider) {
    final String text;
    switch (provider.state) {
      case UnlockState.unlocked:
        text = 'Access granted — welcome back!';
        break;
      case UnlockState.failed:
        text = 'Attempt ${provider.failedAttempts}/5 — ${5 - provider.failedAttempts} remaining';
        break;
      case UnlockState.lockout:
        text = 'Gesture input disabled. Use PIN to bypass.';
        break;
      default:
        text = !provider.isBiometricVerified 
            ? 'Step 1: Authenticate with Fingerprint'
            : 'Step 2: Perform 4-gesture pattern';
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: Text(
        text,
        key: ValueKey(text),
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 13,
          color: Colors.white.withValues(alpha: 0.5),
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  // ─── Biometrics UI ────────────────────────────────────
  
  Widget _buildBiometricPrompt(GestureUnlockProvider provider) {
    return GestureDetector(
      onTap: () => provider.authenticateBiometrics(),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 24),
        padding: const EdgeInsets.symmetric(vertical: 32),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: Center(
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF60A5FA).withValues(alpha: 0.15),
                  border: Border.all(color: const Color(0xFF60A5FA).withValues(alpha: 0.3)),
                ),
                child: const Icon(
                  Icons.fingerprint_rounded,
                  size: 48,
                  color: Color(0xFF60A5FA),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'TAP TO SCAN FINGERPRINT',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.white.withValues(alpha: 0.4),
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Fixed Gesture Trail (Row-based, no overflow) ─────

  Widget _buildGestureTrail(GestureUnlockProvider provider) {
    final trail = provider.inputTrail;
    const total = GestureUnlockProvider.patternLength;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'GESTURE TRAIL',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.3),
                  letterSpacing: 3,
                ),
              ),
              if (trail.isNotEmpty) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => provider.retryManual(),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.refresh_rounded,
                          size: 12,
                          color: Colors.white.withValues(alpha: 0.4),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'RETRY',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: Colors.white.withValues(alpha: 0.4),
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          // Fixed-size Row — no ListView, no overflow
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(total, (i) {
              if (i < trail.length) {
                return _buildFilledSlot(trail[i], i);
              }
              return _buildEmptySlot(i);
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildFilledSlot(Gesture gesture, int index) {
    final data = _gestureVisual(gesture);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: Duration(milliseconds: 300 + index * 80),
        curve: Curves.easeOut,
        builder: (context, value, child) {
          return Transform.scale(
            scale: 0.5 + (value * 0.5),
            child: Opacity(opacity: value, child: child),
          );
        },
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: data.color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: data.color.withValues(alpha: 0.4)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(data.icon, color: data.color, size: 20),
              const SizedBox(height: 2),
              Text(
                data.label,
                style: TextStyle(
                  color: data.color,
                  fontSize: 8,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptySlot(int index) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Center(
          child: Text(
            '${index + 1}',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.1),
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  // ─── Lockout countdown ───────────────────────────────

  Widget _buildLockoutCountdown(GestureUnlockProvider provider) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      decoration: BoxDecoration(
        color: const Color(0xFFFB923C).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFFFB923C).withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        children: [
          Icon(
            Icons.hourglass_top_rounded,
            size: 32,
            color: const Color(0xFFFB923C).withValues(alpha: 0.6),
          ),
          const SizedBox(height: 12),
          Text(
            'Try again in',
            style: TextStyle(
              fontSize: 13,
              color: Colors.white.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${provider.lockoutRemaining}s',
            style: GoogleFonts.outfit(
              fontSize: 40,
              fontWeight: FontWeight.w800,
              color: const Color(0xFFFB923C),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'You can still use your PIN to unlock',
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withValues(alpha: 0.3),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Bottom controls ─────────────────────────────────

  Widget _buildBottomControls(GestureUnlockProvider provider) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Manual retry (only when trail has items and not in lockout)
        if (provider.inputTrail.isNotEmpty &&
            provider.state != UnlockState.lockout) ...[
          GestureDetector(
            onTap: () => provider.retryManual(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.refresh_rounded,
                    size: 16,
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Retry',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.white.withValues(alpha: 0.4),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
        // PIN fallback (always visible)
        GestureDetector(
          onTap: _showPinDialog,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.08),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.pin_rounded,
                  size: 16,
                  color: Colors.white.withValues(alpha: 0.4),
                ),
                const SizedBox(width: 8),
                Text(
                  'Use PIN Instead',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.4),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  _GestureVisual _gestureVisual(Gesture g) {
    switch (g) {
      case Gesture.shake:
        return _GestureVisual(
            Icons.vibration, 'SHAKE', const Color(0xFFFBBF24));
      case Gesture.left:
        return _GestureVisual(
            Icons.arrow_back_rounded, 'LEFT', const Color(0xFF60A5FA));
      case Gesture.right:
        return _GestureVisual(
            Icons.arrow_forward_rounded, 'RIGHT', const Color(0xFF34D399));
      case Gesture.up:
        return _GestureVisual(
            Icons.arrow_upward_rounded, 'UP', const Color(0xFFC084FC));
      case Gesture.down:
        return _GestureVisual(
            Icons.arrow_downward_rounded, 'DOWN', const Color(0xFFFB923C));
    }
  }
}

class _GestureVisual {
  final IconData icon;
  final String label;
  final Color color;
  _GestureVisual(this.icon, this.label, this.color);
}
