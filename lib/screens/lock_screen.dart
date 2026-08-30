import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../models/gesture.dart';
import '../models/motion_point.dart';
import '../providers/gesture_unlock_provider.dart';
import '../providers/vault_provider.dart';
import '../services/gesture_detector.dart';
import 'vault_home_screen.dart';

/// 3D Wand Spatial Unlock Screen.
/// Features a real-time motion particle trail canvas, biometric scan trigger,
/// PIN fallback, and automatic routing to Primary or Decoy vault.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  final TextEditingController _pinController = TextEditingController();
  bool _isDrawingManual = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  void _showPinDialog() {
    _pinController.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Security PIN Fallback',
          style: GoogleFonts.outfit(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Enter your authorization PIN to unlock the vault.',
              style: GoogleFonts.outfit(fontSize: 13, color: Colors.white70),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _pinController,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 8,
              autofocus: true,
              style: GoogleFonts.outfit(
                fontSize: 24,
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
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: GoogleFonts.outfit(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFA78BFA),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              final pin = _pinController.text.trim();
              if (pin.isEmpty) return;
              Navigator.pop(ctx);

              final provider = context.read<GestureUnlockProvider>();
              final success = await provider.verifyPin(pin);
              if (success && mounted) {
                _navigateToVault(provider.activeVaultType);
              }
            },
            child: Text('Unlock', style: GoogleFonts.outfit(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _navigateToVault(VaultType type) {
    context.read<VaultProvider>().loadVault(type);
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => VaultHomeScreen(vaultType: type)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final unlockProvider = context.watch<GestureUnlockProvider>();

    // Listen for unlock state transition
    if (unlockProvider.state == UnlockState.unlocked) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _navigateToVault(unlockProvider.activeVaultType);
        }
      });
    }

    return Scaffold(
      backgroundColor: const Color(0xFF090D16),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white70, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.pin_rounded, color: Colors.white70),
            tooltip: 'Enter PIN',
            onPressed: _showPinDialog,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 12),
              // Header
              Text(
                'Spatial Wand Portal',
                style: GoogleFonts.outfit(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                unlockProvider.state == UnlockState.lockout
                    ? 'Security lockout active • ${unlockProvider.lockoutRemaining}s remaining'
                    : 'Draw your 3D secret motion glyph in the air',
                style: GoogleFonts.outfit(
                  fontSize: 13,
                  color: unlockProvider.state == UnlockState.lockout
                      ? const Color(0xFFF87171)
                      : Colors.white60,
                ),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 28),

              // Interactive 3D Wand Particle Canvas
              Expanded(
                child: GestureDetector(
                  onPanStart: (_) {
                    setState(() => _isDrawingManual = true);
                    unlockProvider.startAirDrawing();
                  },
                  onPanEnd: (_) {
                    setState(() => _isDrawingManual = false);
                    unlockProvider.stopAirDrawingAndEvaluate();
                  },
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        colors: [
                          const Color(0xFF1E1B4B).withOpacity(0.6),
                          const Color(0xFF0F172A).withOpacity(0.8),
                        ],
                        radius: 0.85,
                      ),
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(
                        color: unlockProvider.state == UnlockState.recording || _isDrawingManual
                            ? const Color(0xFFA78BFA)
                            : Colors.white.withOpacity(0.08),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFA78BFA).withOpacity(0.08),
                          blurRadius: 24,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(28),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // Live Motion Trail
                          CustomPaint(
                            size: Size.infinite,
                            painter: _MotionTrailPainter(
                              trail: unlockProvider.currentTrail,
                              isRecording: unlockProvider.state == UnlockState.recording || _isDrawingManual,
                            ),
                          ),

                          // Center Pulsing Portal Glyph
                          ScaleTransition(
                            scale: _pulseAnimation,
                            child: Container(
                              padding: const EdgeInsets.all(24),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: const Color(0xFF1E293B).withOpacity(0.7),
                                border: Border.all(
                                  color: const Color(0xFFA78BFA).withOpacity(0.3),
                                  width: 2,
                                ),
                              ),
                              child: Icon(
                                unlockProvider.state == UnlockState.recording || _isDrawingManual
                                    ? Icons.auto_awesome_rounded
                                    : Icons.lock_outline_rounded,
                                color: const Color(0xFFA78BFA),
                                size: 38,
                              ),
                            ),
                          ),

                          // Bottom Touch Indicator
                          Positioned(
                            bottom: 20,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.4),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: Colors.white10),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _isDrawingManual ? Icons.touch_app_rounded : Icons.sensors_rounded,
                                    color: const Color(0xFF38BDF8),
                                    size: 14,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    _isDrawingManual ? 'Drawing active...' : 'Move phone or hold to draw',
                                    style: GoogleFonts.outfit(
                                      fontSize: 12,
                                      color: Colors.white70,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // Biometric & Rapid Scan Actions
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: BorderSide(color: Colors.white.withOpacity(0.12)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      onPressed: () async {
                        final authenticated = await unlockProvider.authenticateBiometrics();
                        if (authenticated && mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              backgroundColor: const Color(0xFF1E1B4B),
                              content: Text(
                                'Fingerprint verified • Now perform 3D Wand Gesture',
                                style: GoogleFonts.outfit(color: Colors.white),
                              ),
                            ),
                          );
                        }
                      },
                      icon: Icon(
                        unlockProvider.isBiometricVerified ? Icons.check_circle_rounded : Icons.fingerprint_rounded,
                        color: unlockProvider.isBiometricVerified ? const Color(0xFF34D399) : const Color(0xFFA78BFA),
                      ),
                      label: Text(
                        unlockProvider.isBiometricVerified ? 'Fingerprint Ready' : 'Scan Fingerprint',
                        style: GoogleFonts.outfit(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  IconButton.filled(
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xFF1F2937),
                      padding: const EdgeInsets.all(14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    icon: const Icon(Icons.keyboard_alt_outlined, color: Colors.white70),
                    tooltip: 'PIN Code',
                    onPressed: _showPinDialog,
                  ),
                ],
              ),

              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}

/// Custom painter rendering dynamic 3D spatial motion particle ribbons
class _MotionTrailPainter extends CustomPainter {
  final List<MotionPoint> trail;
  final bool isRecording;

  _MotionTrailPainter({required this.trail, required this.isRecording});

  @override
  void paint(Canvas canvas, Size size) {
    if (trail.isEmpty) return;

    final centerX = size.width / 2;
    final centerY = size.height / 2;

    final offsets = GestureDetectorService.compute2DPath(trail, scale: 1.2);
    if (offsets.isEmpty) return;

    final path = Path();
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (int i = 0; i < offsets.length; i++) {
      final off = offsets[i];
      final x = (centerX + off.dx).clamp(20.0, size.width - 20.0);
      final y = (centerY + off.dy).clamp(20.0, size.height - 20.0);

      final progress = (i + 1) / offsets.length;
      paint
        ..strokeWidth = 3.0 + (progress * 4.5)
        ..color = isRecording
            ? Color.lerp(const Color(0xFF38BDF8), const Color(0xFFA78BFA), progress)!.withOpacity(progress)
            : Colors.white.withOpacity(progress * 0.4);

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }

      // Draw particle dot at head
      if (i == offsets.length - 1) {
        final glowPaint = Paint()
          ..color = const Color(0xFFA78BFA).withOpacity(0.9)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
        canvas.drawCircle(Offset(x, y), 8, glowPaint);
        canvas.drawCircle(Offset(x, y), 4.5, Paint()..color = Colors.white);
      }
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _MotionTrailPainter oldDelegate) => true;
}
