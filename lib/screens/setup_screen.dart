import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../models/gesture.dart';
import '../models/motion_point.dart';
import '../models/gesture_template.dart';
import '../services/auth_service.dart';
import '../services/gesture_detector.dart';
import '../services/dtw_matcher.dart';
import '../providers/gesture_unlock_provider.dart';
import 'normal_files_screen.dart';

/// Interactive 3D Wand Air-Drawing Calibration & Dual-Vault Setup Wizard.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  int _currentStep = 0; // 0: Master Gesture, 1: Decoy Gesture, 2: Fallback PINs
  final GestureDetectorService _detector = GestureDetectorService();
  final AuthService _authService = AuthService();

  // Calibration repetitions
  final List<List<MotionPoint>> _masterSamples = [];
  final List<List<MotionPoint>> _decoySamples = [];
  List<MotionPoint> _activeDrawing = [];
  bool _isRecording = false;

  final TextEditingController _masterPinController = TextEditingController();
  final TextEditingController _decoyPinController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _detector.start();
    _detector.motionPoints.listen((point) {
      if (_isRecording) {
        setState(() {
          _activeDrawing.add(point);
        });
      }
    });
  }

  @override
  void dispose() {
    _detector.dispose();
    _masterPinController.dispose();
    _decoyPinController.dispose();
    super.dispose();
  }

  void _startDrawing() {
    setState(() {
      _isRecording = true;
      _activeDrawing.clear();
    });
    _detector.startRecording();
  }

  void _stopDrawing() {
    setState(() => _isRecording = false);
    final recorded = _detector.stopRecording();
    final points = recorded.isNotEmpty ? recorded : List<MotionPoint>.from(_activeDrawing);

    if (points.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFFE11D48),
          content: Text(
            'Motion too short. Hold and move fluidly in the air.',
            style: GoogleFonts.outfit(color: Colors.white),
          ),
        ),
      );
      return;
    }

    setState(() {
      if (_currentStep == 0) {
        _masterSamples.add(points);
      } else if (_currentStep == 1) {
        _decoySamples.add(points);
      }
    });
  }

  GestureTemplate _createTemplate(String name, List<List<MotionPoint>> samples) {
    final fusedPoints = DtwMatcher.fuseTemplates(samples);
    final avgDuration = samples.isNotEmpty
        ? (samples.map((s) => s.isNotEmpty ? s.last.timestampMs - s.first.timestampMs : 1200).reduce((a, b) => a + b) ~/ samples.length)
        : 1200;

    return GestureTemplate(
      id: const Uuid().v4(),
      name: name,
      points: fusedPoints,
      durationMs: avgDuration,
      createdAt: DateTime.now(),
    );
  }

  Future<void> _completeSetup() async {
    final masterPin = _masterPinController.text.trim();
    if (masterPin.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFFE11D48),
          content: Text(
            'Please enter at least a 4-digit Master PIN.',
            style: GoogleFonts.outfit(color: Colors.white),
          ),
        ),
      );
      return;
    }

    final masterTemplate = _masterSamples.isNotEmpty
        ? _createTemplate('Master 3D Wand', _masterSamples)
        : null;

    final decoyTemplate = _decoySamples.isNotEmpty
        ? _createTemplate('Decoy 3D Wand', _decoySamples)
        : null;

    final decoyPin = _decoyPinController.text.trim();

    await _authService.saveCredentials(
      pattern: [Gesture.up, Gesture.down, Gesture.left, Gesture.right], // Fallback default
      pin: masterPin,
      masterTemplate: masterTemplate,
      decoyTemplate: decoyTemplate,
      decoyPin: decoyPin.isNotEmpty ? decoyPin : null,
    );

    if (mounted) {
      await context.read<GestureUnlockProvider>().onSetupComplete();
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const NormalFilesScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF090D16),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Vault Calibration',
          style: GoogleFonts.outfit(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),

              // Step Indicator
              Row(
                children: [
                  _buildStepBubble(0, 'Master Wand'),
                  _buildStepDivider(0),
                  _buildStepBubble(1, 'Decoy Wand'),
                  _buildStepDivider(1),
                  _buildStepBubble(2, 'PIN Fallback'),
                ],
              ),

              const SizedBox(height: 24),

              // Step Header
              Text(
                _currentStep == 0
                    ? '1. Record Master 3D Gesture'
                    : _currentStep == 1
                        ? '2. Record Decoy 3D Gesture'
                        : '3. Fallback PIN Codes',
                style: GoogleFonts.outfit(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _currentStep == 0
                    ? 'Hold the canvas and wave your phone in a unique 3D shape (e.g. circle, triangle, or wave).'
                    : _currentStep == 1
                        ? 'Record an alternate gesture that opens a believable Decoy Vault under duress.'
                        : 'Set emergency fallback PINs in case motion sensors are unavailable.',
                style: GoogleFonts.outfit(
                  fontSize: 13,
                  color: Colors.white60,
                ),
              ),

              const SizedBox(height: 20),

              // Step Content
              if (_currentStep < 2) ...[
                Expanded(
                  child: GestureDetector(
                    onPanStart: (_) => _startDrawing(),
                    onPanEnd: (_) => _stopDrawing(),
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          colors: [
                            const Color(0xFF1E1B4B).withOpacity(0.5),
                            const Color(0xFF0F172A).withOpacity(0.7),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: _isRecording ? const Color(0xFFA78BFA) : Colors.white12,
                          width: 1.5,
                        ),
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          CustomPaint(
                            size: Size.infinite,
                            painter: _CalibrationPainter(points: _activeDrawing),
                          ),
                          Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                _isRecording ? Icons.auto_awesome_rounded : Icons.touch_app_rounded,
                                color: const Color(0xFFA78BFA),
                                size: 40,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _isRecording ? 'Recording 6-DOF Motion...' : 'Press & Hold to Draw in Air',
                                style: GoogleFonts.outfit(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white70,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _currentStep == 0
                                    ? 'Samples recorded: ${_masterSamples.length}/2'
                                    : 'Samples recorded: ${_decoySamples.length}/2',
                                style: GoogleFonts.outfit(
                                  fontSize: 12,
                                  color: const Color(0xFF38BDF8),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ] else ...[
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Master PIN (Unlocks Real Vault)',
                          style: GoogleFonts.outfit(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFFA78BFA),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _masterPinController,
                          keyboardType: TextInputType.number,
                          obscureText: true,
                          maxLength: 6,
                          style: GoogleFonts.outfit(fontSize: 18, color: Colors.white),
                          decoration: InputDecoration(
                            hintText: 'Enter 4–6 digit PIN',
                            hintStyle: GoogleFonts.outfit(color: Colors.white30),
                            filled: true,
                            fillColor: const Color(0xFF161B22),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Decoy PIN (Optional Duress PIN)',
                          style: GoogleFonts.outfit(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF38BDF8),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _decoyPinController,
                          keyboardType: TextInputType.number,
                          obscureText: true,
                          maxLength: 6,
                          style: GoogleFonts.outfit(fontSize: 18, color: Colors.white),
                          decoration: InputDecoration(
                            hintText: 'Enter 4–6 digit Decoy PIN',
                            hintStyle: GoogleFonts.outfit(color: Colors.white30),
                            filled: true,
                            fillColor: const Color(0xFF161B22),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 20),

              // Action Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (_currentStep > 0)
                    TextButton(
                      onPressed: () => setState(() => _currentStep--),
                      child: Text('Back', style: GoogleFonts.outfit(color: Colors.white60)),
                    )
                  else
                    const SizedBox(),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFA78BFA),
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: () {
                      if (_currentStep == 0) {
                        if (_masterSamples.isEmpty) {
                          // Provide fallback standard gesture if testing in simulator
                          _masterSamples.add([
                            const MotionPoint(timestampMs: 0, gx: 0, gy: 0, gz: 0, ax: 0, ay: 0, az: 9.8),
                            const MotionPoint(timestampMs: 500, gx: 2, gy: 1, gz: 0, ax: 1, ay: 2, az: 9.8),
                          ]);
                        }
                        setState(() => _currentStep = 1);
                      } else if (_currentStep == 1) {
                        setState(() => _currentStep = 2);
                      } else {
                        _completeSetup();
                      }
                    },
                    child: Text(
                      _currentStep == 2 ? 'Complete Setup' : 'Next Step',
                      style: GoogleFonts.outfit(
                        fontWeight: FontWeight.bold,
                        color: Colors.black,
                      ),
                    ),
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

  Widget _buildStepBubble(int stepIndex, String title) {
    final isActive = _currentStep == stepIndex;
    final isDone = _currentStep > stepIndex;

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isDone
                ? const Color(0xFF34D399)
                : isActive
                    ? const Color(0xFFA78BFA)
                    : const Color(0xFF21262D),
          ),
          child: Icon(
            isDone ? Icons.check_rounded : Icons.circle,
            size: 10,
            color: isActive || isDone ? Colors.black : Colors.white38,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          title,
          style: GoogleFonts.outfit(
            fontSize: 11,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            color: isActive ? Colors.white : Colors.white54,
          ),
        ),
      ],
    );
  }

  Widget _buildStepDivider(int stepIndex) {
    return Expanded(
      child: Container(
        height: 1,
        color: _currentStep > stepIndex ? const Color(0xFF34D399) : Colors.white12,
        margin: const EdgeInsets.symmetric(horizontal: 6),
      ),
    );
  }
}

class _CalibrationPainter extends CustomPainter {
  final List<MotionPoint> points;
  _CalibrationPainter({required this.points});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    final centerX = size.width / 2;
    final centerY = size.height / 2;
    final path = Path();
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFFA78BFA);

    for (int i = 0; i < points.length; i++) {
      final p = points[i];
      final x = centerX + (p.gx * 45) + (p.ax * 8);
      final y = centerY + (p.gy * 45) - (p.ay * 8);

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CalibrationPainter oldDelegate) => true;
}
