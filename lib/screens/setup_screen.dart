import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../models/gesture.dart';
import '../services/gesture_detector.dart';
import '../providers/gesture_unlock_provider.dart';
import '../services/auth_service.dart';
import 'lock_screen.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen>
    with TickerProviderStateMixin {
  final _authService = AuthService();
  final _gestureDetector = GestureDetectorService();

  static const int _patternLength = GestureUnlockProvider.patternLength;

  int _step = 0; // 0 = welcome, 1 = record, 2 = confirm, 3 = set PIN
  final List<Gesture> _recordedPattern = [];
  final List<Gesture> _confirmPattern = [];
  final _pinController = TextEditingController();
  final _pinConfirmController = TextEditingController();
  String? _pinError;
  bool _isRecording = false;
  StreamSubscription? _gestureSub;

  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    );
    _fadeController.forward();
  }

  @override
  void dispose() {
    _gestureSub?.cancel();
    _gestureDetector.dispose();
    _pinController.dispose();
    _pinConfirmController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  void _nextStep() {
    _fadeController.reverse().then((_) {
      setState(() => _step++);
      _fadeController.forward();
    });
  }

  void _startRecording() {
    setState(() {
      _isRecording = true;
      if (_step == 1) {
        _recordedPattern.clear();
      } else {
        _confirmPattern.clear();
      }
    });

    // Cancel any old subscription first
    _gestureSub?.cancel();
    _gestureDetector.stop();

    _gestureDetector.start();
    _gestureSub = _gestureDetector.gestures.listen((g) {
      if (!_isRecording) return;
      setState(() {
        if (_step == 1) {
          _recordedPattern.add(g);
          if (_recordedPattern.length >= _patternLength) {
            _isRecording = false;
            _gestureDetector.stop();
            _gestureSub?.cancel();
          }
        } else if (_step == 2) {
          _confirmPattern.add(g);
          if (_confirmPattern.length >= _patternLength) {
            _isRecording = false;
            _gestureDetector.stop();
            _gestureSub?.cancel();
          }
        }
      });
    });
  }

  bool _patternsMatch() {
    if (_recordedPattern.length != _confirmPattern.length) return false;
    for (int i = 0; i < _recordedPattern.length; i++) {
      if (_recordedPattern[i] != _confirmPattern[i]) return false;
    }
    return true;
  }

  Future<void> _completeSetup() async {
    final pin = _pinController.text.trim();
    final confirmPin = _pinConfirmController.text.trim();

    if (pin.length < 4) {
      setState(() => _pinError = 'PIN must be at least 4 digits');
      return;
    }
    if (pin != confirmPin) {
      setState(() => _pinError = 'PINs do not match');
      return;
    }

    await _authService.saveCredentials(
      pattern: _recordedPattern,
      pin: pin,
    );

    if (mounted) {
      context.read<GestureUnlockProvider>().onSetupComplete();
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LockScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0F0C29), Color(0xFF302B63), Color(0xFF24243E)],
          ),
        ),
        child: SafeArea(
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: _buildStep(),
          ),
        ),
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case 0:
        return _buildWelcome();
      case 1:
        return _buildRecordGesture();
      case 2:
        return _buildConfirmGesture();
      case 3:
        return _buildSetPin();
      default:
        return const SizedBox();
    }
  }

  Widget _buildWelcome() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFA78BFA).withValues(alpha: 0.15),
              border: Border.all(
                color: const Color(0xFFA78BFA).withValues(alpha: 0.3),
                width: 2,
              ),
            ),
            child: const Icon(
              Icons.shield_rounded,
              size: 50,
              color: Color(0xFFA78BFA),
            ),
          ),
          const SizedBox(height: 32),
          Text(
            'SecretVault',
            style: GoogleFonts.outfit(
              fontSize: 36,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Your private notes, protected by\nmotion-based gesture authentication',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              color: Colors.white.withValues(alpha: 0.5),
              height: 1.5,
            ),
          ),
          const SizedBox(height: 48),
          _buildPrimaryButton('Get Started', _nextStep),
        ],
      ),
    );
  }

  Widget _buildRecordGesture() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.gesture,
            size: 64,
            color: const Color(0xFFFBBF24).withValues(alpha: 0.8),
          ),
          const SizedBox(height: 24),
          Text(
            'Set Your Gesture',
            style: GoogleFonts.outfit(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Perform $_patternLength gestures to create your\nunlock pattern (shake, tilt left/right/up/down)',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: Colors.white.withValues(alpha: 0.5),
              height: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Return phone to flat between each gesture',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              color: const Color(0xFFFBBF24).withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 24),
          _buildGestureChips(_recordedPattern, _patternLength),
          const SizedBox(height: 32),
          if (!_isRecording && _recordedPattern.isEmpty)
            _buildPrimaryButton('Start Recording', _startRecording),
          if (_isRecording)
            Text(
              'Listening for gestures... (${_recordedPattern.length}/$_patternLength)',
              style: TextStyle(
                color: const Color(0xFFFBBF24).withValues(alpha: 0.8),
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          if (!_isRecording && _recordedPattern.length == _patternLength) ...[
            _buildPrimaryButton('Continue', _nextStep),
            const SizedBox(height: 12),
            _buildSecondaryButton('Re-record', () {
              setState(() => _recordedPattern.clear());
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildConfirmGesture() {
    final matched = !_isRecording &&
        _confirmPattern.length == _patternLength &&
        _patternsMatch();
    final failed = !_isRecording &&
        _confirmPattern.length == _patternLength &&
        !_patternsMatch();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            matched
                ? Icons.check_circle_rounded
                : failed
                    ? Icons.error_rounded
                    : Icons.repeat_rounded,
            size: 64,
            color: matched
                ? const Color(0xFF4ADE80)
                : failed
                    ? const Color(0xFFF87171)
                    : const Color(0xFF60A5FA),
          ),
          const SizedBox(height: 24),
          Text(
            'Confirm Gesture',
            style: GoogleFonts.outfit(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            failed
                ? 'Patterns don\'t match. Try again.'
                : 'Repeat the same $_patternLength gestures to confirm',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: failed
                  ? const Color(0xFFF87171)
                  : Colors.white.withValues(alpha: 0.5),
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),
          _buildGestureChips(_confirmPattern, _patternLength),
          const SizedBox(height: 32),
          if (!_isRecording && _confirmPattern.isEmpty)
            _buildPrimaryButton('Start Recording', _startRecording),
          if (_isRecording)
            Text(
              'Listening for gestures... (${_confirmPattern.length}/$_patternLength)',
              style: TextStyle(
                color: const Color(0xFFFBBF24).withValues(alpha: 0.8),
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          if (matched) _buildPrimaryButton('Continue', _nextStep),
          if (failed)
            _buildSecondaryButton('Try Again', () {
              setState(() => _confirmPattern.clear());
            }),
        ],
      ),
    );
  }

  Widget _buildSetPin() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(height: 80),
            Icon(
              Icons.pin_rounded,
              size: 64,
              color: const Color(0xFF34D399).withValues(alpha: 0.8),
            ),
            const SizedBox(height: 24),
            Text(
              'Set Fallback PIN',
              style: GoogleFonts.outfit(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Set a numeric PIN in case you forget\nyour gesture pattern',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Colors.white.withValues(alpha: 0.5),
                height: 1.5,
              ),
            ),
            const SizedBox(height: 32),
            _buildPinField(_pinController, 'Enter PIN'),
            const SizedBox(height: 16),
            _buildPinField(_pinConfirmController, 'Confirm PIN'),
            if (_pinError != null) ...[
              const SizedBox(height: 12),
              Text(
                _pinError!,
                style: const TextStyle(
                  color: Color(0xFFF87171),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 32),
            _buildPrimaryButton('Complete Setup', _completeSetup),
            const SizedBox(height: 80),
          ],
        ),
      ),
    );
  }

  Widget _buildPinField(TextEditingController controller, String hint) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: TextField(
        controller: controller,
        obscureText: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          letterSpacing: 8,
        ),
        textAlign: TextAlign.center,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(
            color: Colors.white.withValues(alpha: 0.25),
            fontSize: 14,
            letterSpacing: 1,
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 16,
          ),
        ),
        onChanged: (_) {
          if (_pinError != null) setState(() => _pinError = null);
        },
      ),
    );
  }

  Widget _buildGestureChips(List<Gesture> gestures, int total) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(total, (i) {
        if (i < gestures.length) {
          final data = _gestureData(gestures[i]);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: data.color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: data.color.withValues(alpha: 0.4)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(data.icon, color: data.color, size: 22),
                  const SizedBox(height: 3),
                  Text(
                    data.label,
                    style: TextStyle(
                      color: data.color,
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.1),
              ),
            ),
            child: Icon(
              Icons.help_outline_rounded,
              color: Colors.white.withValues(alpha: 0.15),
              size: 22,
            ),
          ),
        );
      }),
    );
  }

  Widget _buildPrimaryButton(String text, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: const LinearGradient(
            colors: [Color(0xFFA78BFA), Color(0xFF818CF8)],
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFA78BFA).withValues(alpha: 0.3),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }

  Widget _buildSecondaryButton(String text, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Colors.white.withValues(alpha: 0.05),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  _GestureData _gestureData(Gesture g) {
    switch (g) {
      case Gesture.shake:
        return _GestureData(
            Icons.vibration, 'SHAKE', const Color(0xFFFBBF24));
      case Gesture.left:
        return _GestureData(
            Icons.arrow_back_rounded, 'LEFT', const Color(0xFF60A5FA));
      case Gesture.right:
        return _GestureData(
            Icons.arrow_forward_rounded, 'RIGHT', const Color(0xFF34D399));
      case Gesture.up:
        return _GestureData(
            Icons.arrow_upward_rounded, 'UP', const Color(0xFFC084FC));
      case Gesture.down:
        return _GestureData(
            Icons.arrow_downward_rounded, 'DOWN', const Color(0xFFFB923C));
    }
  }
}

class _GestureData {
  final IconData icon;
  final String label;
  final Color color;
  _GestureData(this.icon, this.label, this.color);
}
