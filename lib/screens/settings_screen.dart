import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../models/gesture.dart';
import '../providers/gesture_unlock_provider.dart';
import '../services/gesture_detector.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final unlockProvider = context.watch<GestureUnlockProvider>();
    if (unlockProvider.state != UnlockState.unlocked) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      });
    }

    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0F0C29), Color(0xFF1A1744), Color(0xFF24243E)],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // App bar
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Settings',
                        style: GoogleFonts.outfit(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),
                _sectionLabel('SECURITY'),
                const SizedBox(height: 12),
                _actionTile(
                  icon: Icons.gesture,
                  title: 'Change Gesture Pattern',
                  subtitle: 'Record a new 4-gesture unlock pattern',
                  color: const Color(0xFFFBBF24),
                  onTap: () => _showChangeGestureSheet(),
                ),
                _actionTile(
                  icon: Icons.pin_rounded,
                  title: 'Change Fallback PIN',
                  subtitle: 'Update your backup PIN code',
                  color: const Color(0xFF34D399),
                  onTap: () => _showChangePinDialog(),
                ),

                const SizedBox(height: 24),
                _sectionLabel('BEHAVIOR'),
                const SizedBox(height: 12),
                _buildSwitchTile(),
                _buildTimeoutTile(),

                const SizedBox(height: 24),
                _sectionLabel('ABOUT'),
                const SizedBox(height: 12),
                _actionTile(
                  icon: Icons.info_outline_rounded,
                  title: 'SecretVault',
                  subtitle: 'v1.0.0 — Motion-based secure notes',
                  color: const Color(0xFFA78BFA),
                  onTap: () {},
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── Section label ─────────────────────────────────────

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Colors.white.withValues(alpha: 0.25),
          letterSpacing: 2,
        ),
      ),
    );
  }

  // ─── Generic action tile ───────────────────────────────

  Widget _actionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: GoogleFonts.outfit(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white.withValues(alpha: 0.9))),
                    const SizedBox(height: 4),
                    Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.35))),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: Colors.white.withValues(alpha: 0.2)),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Lock on App Switch toggle ─────────────────────────

  Widget _buildSwitchTile() {
    final provider = context.watch<GestureUnlockProvider>();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF60A5FA).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.swap_horiz_rounded, color: Color(0xFF60A5FA), size: 22),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Lock on App Switch', style: GoogleFonts.outfit(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white.withValues(alpha: 0.9))),
                  const SizedBox(height: 4),
                  Text(
                    provider.autoLockOnSwitch
                        ? 'App locks when you switch away'
                        : 'App stays unlocked when switching',
                    style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.35)),
                  ),
                ],
              ),
            ),
            Switch(
              value: provider.autoLockOnSwitch,
              activeThumbColor: const Color(0xFF60A5FA),
              onChanged: (val) => provider.setAutoLockOnSwitch(val),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Inactivity Timeout selector ───────────────────────

  Widget _buildTimeoutTile() {
    final provider = context.watch<GestureUnlockProvider>();
    final options = [30, 60, 120, 300, 600];
    final labels = ['30 sec', '1 min', '2 min', '5 min', '10 min'];
    final idx = options.indexOf(provider.inactivityTimeoutSeconds);
    final currentLabel = idx >= 0 ? labels[idx] : '${provider.inactivityTimeoutSeconds}s';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          showModalBottomSheet(
            context: context,
            backgroundColor: const Color(0xFF1A1744),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            builder: (ctx) => Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(2))),
                  const SizedBox(height: 20),
                  Text('Auto-Lock After Inactivity', style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
                  const SizedBox(height: 16),
                  ...List.generate(options.length, (i) {
                    final selected = provider.inactivityTimeoutSeconds == options[i];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: GestureDetector(
                        onTap: () {
                          provider.setInactivityTimeout(options[i]);
                          Navigator.pop(ctx);
                        },
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
                          decoration: BoxDecoration(
                            color: selected ? const Color(0xFFC084FC).withValues(alpha: 0.15) : Colors.white.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: selected ? const Color(0xFFC084FC).withValues(alpha: 0.4) : Colors.white.withValues(alpha: 0.06)),
                          ),
                          child: Row(
                            children: [
                              Text(labels[i], style: TextStyle(color: selected ? const Color(0xFFC084FC) : Colors.white.withValues(alpha: 0.6), fontSize: 15, fontWeight: FontWeight.w600)),
                              const Spacer(),
                              if (selected) const Icon(Icons.check_rounded, color: Color(0xFFC084FC), size: 20),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          );
        },
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFFC084FC).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.timer_outlined, color: Color(0xFFC084FC), size: 22),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Inactivity Timeout', style: GoogleFonts.outfit(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white.withValues(alpha: 0.9))),
                    const SizedBox(height: 4),
                    Text('Lock after $currentLabel of inactivity', style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.35))),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFC084FC).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(currentLabel, style: const TextStyle(color: Color(0xFFC084FC), fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Change Gesture Pattern ────────────────────────────

  void _showChangeGestureSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const _ChangeGestureSheet(),
    );
  }

  // ─── Change PIN ────────────────────────────────────────

  void _showChangePinDialog() {
    final currentPinCtrl = TextEditingController();
    final newPinCtrl = TextEditingController();
    final confirmPinCtrl = TextEditingController();
    String? error;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1A1744),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
          ),
          title: Text('Change PIN', style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.w700)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _pinField(currentPinCtrl, 'Current PIN'),
              const SizedBox(height: 12),
              _pinField(newPinCtrl, 'New PIN'),
              const SizedBox(height: 12),
              _pinField(confirmPinCtrl, 'Confirm New PIN'),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(error!, style: const TextStyle(color: Color(0xFFF87171), fontSize: 13)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: Colors.white.withValues(alpha: 0.5))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF34D399),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () async {
                final provider = context.read<GestureUnlockProvider>();
                final verified = await provider.verifyPin(currentPinCtrl.text);
                if (!verified) {
                  setDialogState(() => error = 'Current PIN is incorrect');
                  return;
                }
                if (newPinCtrl.text.length < 4) {
                  setDialogState(() => error = 'New PIN must be at least 4 digits');
                  return;
                }
                if (newPinCtrl.text != confirmPinCtrl.text) {
                  setDialogState(() => error = 'New PINs do not match');
                  return;
                }
                await provider.updatePin(newPinCtrl.text);
                if (ctx.mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(
                      content: const Text('PIN updated successfully'),
                      backgroundColor: const Color(0xFF34D399),
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  );
                }
              },
              child: const Text('Update', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pinField(TextEditingController controller, String hint) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: TextField(
        controller: controller,
        obscureText: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: const TextStyle(color: Colors.white, fontSize: 16, letterSpacing: 6),
        textAlign: TextAlign.center,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.2), fontSize: 13, letterSpacing: 1),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.all(14),
        ),
      ),
    );
  }
}

// ─── Change Gesture Bottom Sheet ─────────────────────────

class _ChangeGestureSheet extends StatefulWidget {
  const _ChangeGestureSheet();

  @override
  State<_ChangeGestureSheet> createState() => _ChangeGestureSheetState();
}

class _ChangeGestureSheetState extends State<_ChangeGestureSheet> {
  final _detector = GestureDetectorService();
  final List<Gesture> _newPattern = [];
  final List<Gesture> _confirmPattern = [];
  int _step = 0;
  bool _isRecording = false;
  StreamSubscription? _gestureSub;

  static const int _len = GestureUnlockProvider.patternLength;

  @override
  void dispose() {
    _gestureSub?.cancel();
    _detector.dispose();
    super.dispose();
  }

  void _startRecording() {
    setState(() {
      _isRecording = true;
      if (_step == 0) {
        _newPattern.clear();
      } else {
        _confirmPattern.clear();
      }
    });

    _gestureSub?.cancel();
    _detector.stop();
    _detector.start();

    _gestureSub = _detector.gestures.listen((g) {
      if (!_isRecording) return;
      setState(() {
        final target = _step == 0 ? _newPattern : _confirmPattern;
        target.add(g);
        if (target.length >= _len) {
          _isRecording = false;
          _detector.stop();
          _gestureSub?.cancel();
        }
      });
    });
  }

  bool _patternsMatch() {
    if (_newPattern.length != _confirmPattern.length) return false;
    for (int i = 0; i < _newPattern.length; i++) {
      if (_newPattern[i] != _confirmPattern[i]) return false;
    }
    return true;
  }

  Future<void> _savePattern() async {
    final provider = context.read<GestureUnlockProvider>();
    await provider.updatePattern(_newPattern);
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Gesture pattern updated!'),
          backgroundColor: const Color(0xFFFBBF24),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final gestures = _step == 0 ? _newPattern : _confirmPattern;
    final matched = _step == 1 && !_isRecording && _confirmPattern.length == _len && _patternsMatch();
    final failed = _step == 1 && !_isRecording && _confirmPattern.length == _len && !_patternsMatch();

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
      decoration: const BoxDecoration(
        color: Color(0xFF1A1744),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 24),
          Text(
            _step == 0 ? 'Record New Pattern' : 'Confirm Pattern',
            style: GoogleFonts.outfit(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white),
          ),
          const SizedBox(height: 8),
          Text(
            _step == 0
                ? 'Perform $_len gestures (return to flat between each)'
                : failed ? 'Patterns don\'t match — try again' : 'Repeat the same $_len gestures',
            style: TextStyle(fontSize: 14, color: failed ? const Color(0xFFF87171) : Colors.white.withValues(alpha: 0.4)),
          ),
          const SizedBox(height: 24),
          _buildChips(gestures),
          const SizedBox(height: 24),
          if (!_isRecording && gestures.isEmpty) _actionBtn('Start Recording', _startRecording),
          if (_isRecording) ...[
            Text('Listening... (${gestures.length}/$_len)', style: TextStyle(color: const Color(0xFFFBBF24).withValues(alpha: 0.8), fontWeight: FontWeight.w600)),
            if (gestures.isNotEmpty) ...[
              const SizedBox(height: 12),
              GestureDetector(
                onTap: _startRecording,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                  ),
                  child: const Text('Reset / Retry', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ],
          if (!_isRecording && gestures.length == _len && _step == 0) ...[
            _actionBtn('Confirm Pattern', () => setState(() => _step = 1)),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => setState(() => _newPattern.clear()),
              child: const Center(
                child: Text('Re-record Pattern', style: TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
          if (matched) _actionBtn('Save Pattern', _savePattern),
          if (failed) _actionBtn('Retry', () => setState(() => _confirmPattern.clear())),
        ],
      ),
    );
  }

  Widget _buildChips(List<Gesture> gestures) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_len, (i) {
        if (i < gestures.length) {
          final d = _gd(gestures[i]);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: Container(
              width: 60, height: 60,
              decoration: BoxDecoration(color: d.color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(16), border: Border.all(color: d.color.withValues(alpha: 0.4))),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(d.icon, color: d.color, size: 22),
                const SizedBox(height: 3),
                Text(d.label, style: TextStyle(color: d.color, fontSize: 8, fontWeight: FontWeight.w700)),
              ]),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Container(
            width: 60, height: 60,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white.withValues(alpha: 0.1))),
            child: Icon(Icons.help_outline_rounded, color: Colors.white.withValues(alpha: 0.15), size: 22),
          ),
        );
      }),
    );
  }

  Widget _actionBtn(String text, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), gradient: const LinearGradient(colors: [Color(0xFFA78BFA), Color(0xFF818CF8)])),
        child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
      ),
    );
  }

  ({IconData icon, String label, Color color}) _gd(Gesture g) => switch (g) {
    Gesture.shake => (icon: Icons.vibration, label: 'SHAKE', color: const Color(0xFFFBBF24)),
    Gesture.left => (icon: Icons.arrow_back_rounded, label: 'LEFT', color: const Color(0xFF60A5FA)),
    Gesture.right => (icon: Icons.arrow_forward_rounded, label: 'RIGHT', color: const Color(0xFF34D399)),
    Gesture.up => (icon: Icons.arrow_upward_rounded, label: 'UP', color: const Color(0xFFC084FC)),
    Gesture.down => (icon: Icons.arrow_downward_rounded, label: 'DOWN', color: const Color(0xFFFB923C)),
  };
}
