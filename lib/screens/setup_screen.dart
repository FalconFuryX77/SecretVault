import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../main.dart' show rootNavigatorKey;
import '../config/features.dart';
import '../models/gesture.dart';
import '../services/gesture_detector.dart';
import '../services/vault_service.dart';
import '../providers/gesture_unlock_provider.dart';
import '../vault/vault_container.dart';
import 'normal_files_screen.dart';
import 'vault_home_screen.dart';

/// What the wizard is for.
enum SetupMode {
  /// First run: create the vault container (gesture, then PIN).
  create,

  /// Re-record the unlocked vault's gesture (prompts for a biometric).
  reenrollGesture,

  /// Record a gesture for the decoy vault (prompts for a biometric).
  decoyGesture,
}

/// Setup wizard.
/// Step 0: record a 4–8 move motion gesture (needs biometrics on the device)
/// Step 1: confirm it
/// Step 2: set the PIN (create mode only)
/// Then the vault container is created and the gesture is bound to a
/// biometric-protected key.
class SetupScreen extends StatefulWidget {
  final SetupMode mode;
  const SetupScreen({super.key, this.mode = SetupMode.create});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  static const int _minLen = GestureUnlockProvider.minPatternLength;
  static const int _maxLen = GestureUnlockProvider.maxPatternLength;
  static const int _minPinLen = 6;

  int _currentStep = 0; // 0: Pattern, 1: Confirm Pattern, 2: PIN
  final GestureDetectorService _detector = GestureDetectorService();
  StreamSubscription<Gesture>? _gestureSub;

  final List<Gesture> _recordedPattern = [];
  final List<Gesture> _confirmPattern = [];
  final TextEditingController _pinController = TextEditingController();
  final TextEditingController _pinConfirmController = TextEditingController();

  String? _errorMessage;
  bool? _biometricsAvailable;
  bool _busy = false;
  double? _progress;

  bool get _isCreate => widget.mode == SetupMode.create;
  int get _stepCount => _isCreate ? 3 : 2;

  @override
  void initState() {
    super.initState();
    if (Features.gestures) {
      _detector.start();
      _gestureSub = _detector.gestures.listen((gesture) {
        if (!mounted) return;
        _addGesture(gesture);
      });
    }
    final bio = Features.gestures ? context.read<VaultService>().biometricsAvailable() : Future.value(false);
    bio.then((ok) {
      if (!mounted) return;
      setState(() {
        _biometricsAvailable = ok;
        // Without biometrics a gesture can't unlock anything, so skip
        // straight to the PIN.
        if (!ok && _isCreate) _currentStep = 2;
      });
    });
  }

  @override
  void dispose() {
    _gestureSub?.cancel();
    _detector.dispose();
    _pinController.dispose();
    _pinConfirmController.dispose();
    super.dispose();
  }

  void _addGesture(Gesture g) {
    if (_busy) return;
    final list = _currentStep == 0
        ? _recordedPattern
        : (_currentStep == 1 ? _confirmPattern : null);
    if (list == null || list.length >= _maxLen) return;
    setState(() {
      _errorMessage = null;
      list.add(g);
    });
  }

  void _addManualGesture(Gesture g) => _addGesture(g);

  void _nextStep() {
    if (_busy) return;
    setState(() => _errorMessage = null);
    if (_currentStep == 0) {
      if (_recordedPattern.length < _minLen) {
        setState(
          () => _errorMessage =
              'Record at least $_minLen moves (up to $_maxLen).',
        );
        return;
      }
      setState(() => _currentStep = 1);
    } else if (_currentStep == 1) {
      if (!listEquals(_recordedPattern, _confirmPattern)) {
        setState(() {
          _errorMessage = 'Gestures did not match. Please try again.';
          _confirmPattern.clear();
        });
        return;
      }
      if (_isCreate) {
        setState(() => _currentStep = 2);
      } else {
        _enrollOnExistingVault();
      }
    } else if (_currentStep == 2) {
      final pin = _pinController.text;
      final confirmPin = _pinConfirmController.text;
      if (pin.length < _minPinLen) {
        setState(
          () => _errorMessage =
              'Use at least $_minPinLen characters. Longer is much stronger.',
        );
        return;
      }
      if (pin != confirmPin) {
        setState(
          () => _errorMessage = 'PINs do not match. Please check and retry.',
        );
        return;
      }
      _finalizeSetup();
    }
  }

  Future<void> _enrollOnExistingVault() async {
    final session = context.read<VaultService>().session;
    if (session == null) {
      setState(
        () => _errorMessage = 'The vault locked. Unlock it and try again.',
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final ok = widget.mode == SetupMode.decoyGesture
          ? await session.enrollDecoyGesture(
              _recordedPattern,
              reason: GestureUnlockProvider.biometricReason,
            )
          : await session.enrollGesture(
              _recordedPattern,
              reason: GestureUnlockProvider.biometricReason,
            );
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop(true);
        return;
      }
      setState(() => _errorMessage = 'Biometric confirmation was cancelled.');
    } on CredentialInUseException {
      setState(() {
        _errorMessage =
            'That gesture is already used by another vault. Pick a different one.';
        _recordedPattern.clear();
        _confirmPattern.clear();
        _currentStep = 0;
      });
    } catch (e) {
      setState(() => _errorMessage = 'Could not save the gesture: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finalizeSetup() async {
    final vault = context.read<VaultService>();
    final unlock = context.read<GestureUnlockProvider>();
    final pin = _pinController.text;
    setState(() {
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
      String? warning;
      if (_biometricsAvailable == true && _recordedPattern.length >= _minLen) {
        setState(() => _progress = null);
        final ok = await session.enrollGesture(
          _recordedPattern,
          reason: GestureUnlockProvider.biometricReason,
        );
        if (!ok) {
          warning =
              'Gesture not saved (biometric cancelled). You can add it later in Settings.';
        }
      }
      _pinController.clear();
      _pinConfirmController.clear();

      await unlock.onSetupComplete();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const NormalFilesScreen()),
        (_) => false,
      );
      rootNavigatorKey.currentState?.push(
        MaterialPageRoute(
          builder: (_) => VaultHomeScreen(vaultType: session.type),
        ),
      );
      final ctx = rootNavigatorKey.currentContext;
      if (warning != null && ctx != null && ctx.mounted) {
        ScaffoldMessenger.of(
          ctx,
        ).showSnackBar(SnackBar(content: Text(warning)));
      }
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

  IconData _getGestureIcon(Gesture g) {
    switch (g) {
      case Gesture.left:
        return Icons.arrow_back_rounded;
      case Gesture.right:
        return Icons.arrow_forward_rounded;
      case Gesture.up:
        return Icons.arrow_upward_rounded;
      case Gesture.down:
        return Icons.arrow_downward_rounded;
      case Gesture.shake:
        return Icons.vibration_rounded;
    }
  }

  String _getGestureLabel(Gesture g) {
    switch (g) {
      case Gesture.left:
        return 'Tilt Left';
      case Gesture.right:
        return 'Tilt Right';
      case Gesture.up:
        return 'Tilt Up';
      case Gesture.down:
        return 'Tilt Down';
      case Gesture.shake:
        return 'Shake';
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
              child: const Icon(
                Icons.shield_rounded,
                color: Color(0xFFA78BFA),
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'Vault Setup',
              style: GoogleFonts.outfit(
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              // Progress Indicator
              Row(
                children: List.generate(_stepCount, (index) {
                  final isActive = index <= _currentStep;
                  return Expanded(
                    child: Container(
                      height: 4,
                      margin: EdgeInsets.only(
                        right: index < _stepCount - 1 ? 8 : 0,
                      ),
                      decoration: BoxDecoration(
                        color: isActive
                            ? const Color(0xFFA78BFA)
                            : Colors.white12,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 28),

              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      if (_currentStep == 0)
                        _buildPatternStep(isConfirm: false),
                      if (_currentStep == 1) _buildPatternStep(isConfirm: true),
                      if (_currentStep == 2) _buildPinStep(),
                      if (_busy) ...[
                        const SizedBox(height: 24),
                        LinearProgressIndicator(
                          value: _progress,
                          color: const Color(0xFFA78BFA),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _progress != null
                              ? 'Preparing secure storage…'
                              : 'Confirm with your fingerprint…',
                          style: GoogleFonts.outfit(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE11D48).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: const Color(0xFFE11D48).withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.error_outline_rounded,
                        color: Color(0xFFFB7185),
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: GoogleFonts.outfit(
                            color: const Color(0xFFFB7185),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Action Buttons
              Row(
                children: [
                  if (_currentStep > 0 &&
                      !(_currentStep == 2 &&
                          _biometricsAvailable == false)) ...[
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () {
                              setState(() {
                                _errorMessage = null;
                                _currentStep--;
                              });
                            },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: Colors.white24),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 14,
                        ),
                      ),
                      child: Text(
                        'Back',
                        style: GoogleFonts.outfit(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _busy ? null : _nextStep,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFA78BFA),
                        foregroundColor: const Color(0xFF090D16),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: Text(
                        _currentStep == 2
                            ? 'Create Vault'
                            : (!_isCreate && _currentStep == 1
                                  ? 'Save Gesture'
                                  : 'Continue'),
                        style: GoogleFonts.outfit(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPatternStep({required bool isConfirm}) {
    final list = isConfirm ? _confirmPattern : _recordedPattern;
    return Column(
      children: [
        Icon(
          isConfirm ? Icons.lock_reset_rounded : Icons.screen_rotation_rounded,
          color: const Color(0xFFA78BFA),
          size: 48,
        ),
        const SizedBox(height: 16),
        Text(
          isConfirm ? 'Confirm Your Gesture' : 'Set Secret Motion Gesture',
          textAlign: TextAlign.center,
          style: GoogleFonts.outfit(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          isConfirm
              ? 'Repeat the exact same sequence.'
              : 'Tilt or shake your phone $_minLen–$_maxLen times (Left, Right, Up, Down, Shake). '
                    'Longer is harder to guess. Your fingerprint is required with it, so the gesture alone never opens the vault.',
          textAlign: TextAlign.center,
          style: GoogleFonts.outfit(fontSize: 14, color: Colors.white60),
        ),
        const SizedBox(height: 32),

        // 4 Slots
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(_maxLen, (index) {
            final hasItem = index < list.length;
            final item = hasItem ? list[index] : null;
            return Container(
              width: 30,
              height: 44,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(
                color: hasItem
                    ? const Color(0xFFA78BFA).withValues(alpha: 0.2)
                    : const Color(0xFF161B22),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: hasItem ? const Color(0xFFA78BFA) : Colors.white12,
                  width: hasItem ? 2 : 1,
                ),
              ),
              child: hasItem
                  ? Icon(
                      _getGestureIcon(item!),
                      color: const Color(0xFFA78BFA),
                      size: 20,
                    )
                  : Center(
                      child: Text(
                        '${index + 1}',
                        style: GoogleFonts.outfit(
                          color: Colors.white24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
            );
          }),
        ),
        const SizedBox(height: 16),

        if (list.isNotEmpty)
          TextButton.icon(
            onPressed: () => setState(() => list.clear()),
            icon: const Icon(
              Icons.refresh_rounded,
              size: 16,
              color: Colors.white54,
            ),
            label: Text(
              'Clear Sequence',
              style: GoogleFonts.outfit(color: Colors.white54, fontSize: 13),
            ),
          ),

        const SizedBox(height: 24),
        Text(
          'Quick Tap Input (or physically tilt device):',
          style: GoogleFonts.outfit(color: Colors.white38, fontSize: 12),
        ),
        const SizedBox(height: 12),

        // Interactive Tap Pad for accessibility/testing
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            _buildGestureChip(Gesture.left),
            _buildGestureChip(Gesture.right),
            _buildGestureChip(Gesture.up),
            _buildGestureChip(Gesture.down),
            _buildGestureChip(Gesture.shake),
          ],
        ),
      ],
    );
  }

  Widget _buildGestureChip(Gesture g) {
    return ActionChip(
      backgroundColor: const Color(0xFF1F242C),
      side: const BorderSide(color: Colors.white12),
      avatar: Icon(
        _getGestureIcon(g),
        size: 16,
        color: const Color(0xFFA78BFA),
      ),
      label: Text(
        _getGestureLabel(g),
        style: GoogleFonts.outfit(color: Colors.white, fontSize: 13),
      ),
      onPressed: () => _addManualGesture(g),
    );
  }

  Widget _buildPinStep() {
    return Column(
      children: [
        const Icon(Icons.pin_rounded, color: Color(0xFFA78BFA), size: 48),
        const SizedBox(height: 16),
        Text(
          'Set Your Vault PIN',
          textAlign: TextAlign.center,
          style: GoogleFonts.outfit(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          !Features.gestures
              ? 'The vault opens with this PIN. It encrypts your files: there is no reset. '
                    'Use 6+ characters; a passphrase is best.'
              : _biometricsAvailable == false
              ? 'This device has no fingerprint unlock set up, so the vault opens with this PIN only. '
                    'It encrypts your files: there is no reset. Use 6+ characters; a passphrase is best.'
              : 'Your PIN works when the gesture or fingerprint cannot. It encrypts your files: '
                    'there is no reset. Use 6+ characters; a passphrase is best.',
          textAlign: TextAlign.center,
          style: GoogleFonts.outfit(fontSize: 14, color: Colors.white60),
        ),
        const SizedBox(height: 28),

        TextField(
          controller: _pinController,
          keyboardType: TextInputType.visiblePassword,
          obscureText: true,
          maxLength: 64,
          style: GoogleFonts.outfit(
            fontSize: 20,
            letterSpacing: 6,
            color: Colors.white,
          ),
          textAlign: TextAlign.center,
          decoration: InputDecoration(
            counterText: '',
            hintText: '6+ digits or a passphrase',
            hintStyle: GoogleFonts.outfit(
              fontSize: 14,
              letterSpacing: 0,
              color: Colors.white24,
            ),
            filled: true,
            fillColor: const Color(0xFF161B22),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 16),

        TextField(
          controller: _pinConfirmController,
          keyboardType: TextInputType.visiblePassword,
          obscureText: true,
          maxLength: 64,
          style: GoogleFonts.outfit(
            fontSize: 20,
            letterSpacing: 6,
            color: Colors.white,
          ),
          textAlign: TextAlign.center,
          decoration: InputDecoration(
            counterText: '',
            hintText: 'Confirm PIN',
            hintStyle: GoogleFonts.outfit(
              fontSize: 14,
              letterSpacing: 0,
              color: Colors.white24,
            ),
            filled: true,
            fillColor: const Color(0xFF161B22),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ],
    );
  }
}
