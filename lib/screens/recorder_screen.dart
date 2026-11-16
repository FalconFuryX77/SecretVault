import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../providers/unlock_provider.dart';
import '../providers/vault_provider.dart';
import '../recorder/vault_recorder.dart';
import '../services/vault_service.dart';
import 'hidden_recorder_screen.dart';
import '../theme/ui.dart';


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
    final rec = _recordingHere;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, size: 22),
          tooltip: 'Back',
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Record audio'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(top: 24, bottom: 24),
          children: [
            Center(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                _RecLight(on: rec),
                const SizedBox(width: 8),
                Text(rec ? 'REC' : 'READY', style: Ui.data(size: 12, color: rec ? Ui.alert : Ui.ink3)),
              ]),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                _clock(elapsed),
                key: const Key('rec-clock'),
                style: Ui.figure(size: 56, color: rec ? Ui.ink : Ui.ink3),
              ),
            ),
            const SizedBox(height: 36),
            Center(
              child: Semantics(
                button: true,
                label: rec ? 'Stop recording' : 'Start recording',
                child: GestureDetector(
                  key: const Key('rec-button'),
                  onTap: _busy
                      ? null
                      : () {
                          Ui.tick();
                          rec ? _stop() : _start();
                        },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: rec ? Ui.alert : Ui.raised,
                      border: Border.all(color: rec ? Ui.alert : Ui.hairline, width: 1.5),
                    ),
                    child: Center(
                      child: _busy
                          ? const SizedBox(
                              width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.5, color: Ui.ink2))
                          : AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              width: rec ? 28 : 34,
                              height: rec ? 28 : 34,
                              decoration: BoxDecoration(
                                color: rec ? Ui.canvas : Ui.alert,
                                borderRadius: BorderRadius.circular(rec ? 6 : 17),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 36),
              child: Text(
                rec
                    ? "Recording. Leaving the app or locking the phone doesn't stop it."
                    : "Tap to record. The audio is encrypted as it's captured and goes straight into the vault.",
                key: const Key('rec-state'),
                textAlign: TextAlign.center,
                style: Ui.body(color: Ui.ink2, size: 15),
              ),
            ),
            if (_message != null) ...[
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 36),
                child: Text(
                  _message!,
                  key: const Key('rec-message'),
                  textAlign: TextAlign.center,
                  style: Ui.detail(color: _messageIsError ? Ui.alert : Ui.ink),
                ),
              ),
            ],
            const SizedBox(height: 44),
            UiGroup(children: [
              UiRow(
                icon: Icons.screen_lock_portrait_outlined,
                title: 'Record with the screen off',
                detail: 'A volume button or the assistant button starts and stops it, without unlocking.',
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HiddenRecorderScreen())),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

/// The recording light: red and slowly blinking while recording.
class _RecLight extends StatefulWidget {
  final bool on;
  const _RecLight({required this.on});

  @override
  State<_RecLight> createState() => _RecLightState();
}

class _RecLightState extends State<_RecLight> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    if (widget.on) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_RecLight old) {
    super.didUpdateWidget(old);
    if (widget.on && !_c.isAnimating) _c.repeat(reverse: true);
    if (!widget.on) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.on ? Ui.alert.withValues(alpha: 0.35 + 0.65 * (1 - _c.value)) : Ui.ink3,
          ),
        ),
      );
}
