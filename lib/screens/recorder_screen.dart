import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../providers/unlock_provider.dart';
import '../providers/vault_provider.dart';
import '../recorder/vault_recorder.dart';
import '../services/vault_service.dart';
import '../theme/app_fonts.dart';
import 'hidden_recorder_screen.dart';
import '../theme/ui.dart';

const _accent = Ui.signal;
const _red = Ui.alert;

/// Asks for the microphone, without the vault locking while the system
/// dialog is up. Returns whether it was granted.
Future<bool> ensureMicrophone(BuildContext context) async {
  final unlock = context.read<UnlockProvider>();
  final status = await unlock.withoutAutoLock(() => Permission.microphone.request());
  return status.isGranted;
}

/// Records straight into the open vault. The audio is encrypted as it is
/// captured; leaving the app or locking the phone doesn't stop it, and the
/// recording moves into the vault the next time it's unlocked.
class RecorderScreen extends StatefulWidget {
  const RecorderScreen({super.key});

  @override
  State<RecorderScreen> createState() => _RecorderScreenState();
}

class _RecorderScreenState extends State<RecorderScreen> {
  RecorderStatus _status = const RecorderStatus();
  String? _myKey;
  Timer? _poll;
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  bool get _recordingHere => _status.recording && _status.recordingKey != null && _status.recordingKey == _myKey;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) => _refresh());
    _init();
  }

  Future<void> _init() async {
    final session = context.read<VaultService>().session;
    if (session != null) _myKey = await RecordingKeys.id(session);
    await _refresh();
  }

  Future<void> _refresh() async {
    final s = await VaultRecorder.status();
    if (!mounted) return;
    // Only this vault's own recording keeps it from auto-locking.
    if (s.recording && s.recordingKey == _myKey) context.read<UnlockProvider>().onUserActivity();
    setState(() => _status = s);
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (!await ensureMicrophone(context)) {
        _say('The microphone permission is needed to record.', error: true);
        return;
      }
      if (!mounted) return;
      final session = context.read<VaultService>().session;
      if (session == null) return;
      final pub = await RecordingKeys.publicKey(session);
      _myKey = await VaultRecorder.keyId(pub);
      await VaultRecorder.record(pub);
      await _waitFor((s) => (s.recording && s.recordingKey == _myKey) || s.error != null);
      if (!_recordingHere) {
        // One message for every failure: which failure it was (e.g. the
        // other vault recording) must not show here.
        _say("Couldn't start recording. The microphone may be in use; try again.", error: true);
      }
    } catch (e) {
      _say('Could not start recording: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await VaultRecorder.stop();
      await _waitFor((s) => !s.recording);
      if (!mounted) return;
      final vault = context.read<VaultProvider>();
      final moved = await vault.importRecordings();
      _say(moved > 0 ? 'Saved to the vault.' : 'Stopped. The recording will appear in the vault shortly.');
    } catch (e) {
      _say('Could not save the recording: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _waitFor(bool Function(RecorderStatus) ok) async {
    final end = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(end)) {
      await _refresh();
      if (ok(_status)) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  void _say(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = text;
      _messageIsError = error;
    });
  }

  static String _clock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final started = _status.startedAt;
    final elapsed = _recordingHere && started != null ? DateTime.now().difference(started) : Duration.zero;
    return Scaffold(
      backgroundColor: Ui.canvas,
      appBar: AppBar(
        backgroundColor: Ui.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Ui.ink2, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Record audio', style: AppFonts.ui(fontSize: 18, fontWeight: FontWeight.bold, color: Ui.ink)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 28),
          children: [
            Center(
              child: Text(
                _clock(elapsed),
                key: const Key('rec-clock'),
                style: AppFonts.firaCode(fontSize: 44, color: _recordingHere ? Ui.ink : Ui.ink3),
              ),
            ),
            const SizedBox(height: 28),
            Center(
              child: GestureDetector(
                key: const Key('rec-button'),
                onTap: _busy ? null : (_recordingHere ? _stop : _start),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 112,
                  height: 112,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _recordingHere ? _red : _accent,
                    boxShadow: [
                      BoxShadow(
                        color: (_recordingHere ? _red : _accent).withValues(alpha: 0.35),
                        blurRadius: 30,
                        spreadRadius: _recordingHere ? 6 : 1,
                      ),
                    ],
                  ),
                  child: _busy
                      ? const Padding(
                          padding: EdgeInsets.all(40),
                          child: CircularProgressIndicator(strokeWidth: 3, color: Ui.canvas),
                        )
                      : Icon(
                          _recordingHere ? Icons.stop_rounded : Icons.mic_rounded,
                          size: 52,
                          color: Ui.canvas,
                        ),
                ),
              ),
            ),
            const SizedBox(height: 22),
            Text(
              _recordingHere
                      ? 'Recording. Leaving the app or locking the phone doesn\'t stop it.'
                      : 'Tap to record. The audio is encrypted as it\'s captured and goes straight into the vault.',
              key: const Key('rec-state'),
              textAlign: TextAlign.center,
              style: AppFonts.ui(fontSize: 14, color: Ui.ink2, height: 1.4),
            ),
            if (_message != null) ...[
              const SizedBox(height: 16),
              Text(
                _message!,
                key: const Key('rec-message'),
                textAlign: TextAlign.center,
                style: AppFonts.ui(
                  fontSize: 13,
                  color: _messageIsError ? Ui.alert : Ui.ink,
                ),
              ),
            ],
            const SizedBox(height: 40),
            Container(
              decoration: BoxDecoration(
                color: Ui.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Ui.ink.withValues(alpha: 0.08)),
              ),
              child: ListTile(
                leading: const Icon(Icons.screen_lock_portrait_rounded, color: _accent),
                title: Text(
                  'Record with the screen off',
                  style: AppFonts.ui(fontSize: 14, fontWeight: FontWeight.w600, color: Ui.ink),
                ),
                subtitle: Text(
                  'Press a volume button a few times, or the assistant button, to start or stop without unlocking.',
                  style: AppFonts.ui(fontSize: 12, color: Ui.ink2),
                ),
                trailing: const Icon(Icons.chevron_right_rounded, color: Ui.ink3),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const HiddenRecorderScreen()),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
