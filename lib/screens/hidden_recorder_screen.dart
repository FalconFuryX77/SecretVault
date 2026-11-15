import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../recorder/vault_recorder.dart';
import '../services/vault_service.dart';
import '../theme/app_fonts.dart';
import 'recorder_screen.dart';

const _accent = Color(0xFFA78BFA);

/// Arms the screen-off trigger for the open vault: volume-down three times
/// quickly starts recording, three more stop it. Recordings are encrypted
/// to this vault and move into it the next time it's unlocked.
class HiddenRecorderScreen extends StatefulWidget {
  const HiddenRecorderScreen({super.key});

  @override
  State<HiddenRecorderScreen> createState() => _HiddenRecorderScreenState();
}

class _HiddenRecorderScreenState extends State<HiddenRecorderScreen> {
  RecorderStatus _status = const RecorderStatus();
  String? _myKey;
  bool _vibrate = true;
  bool _busy = false;
  String? _error;
  Timer? _poll;

  bool get _armedHere => _status.armed && _status.armedKey != null && _status.armedKey == _myKey;
  bool get _recordingHere => _status.recording && _status.recordingKey != null && _status.recordingKey == _myKey;

  @override
  void initState() {
    super.initState();
    final session = context.read<VaultService>().session;
    if (session != null) _vibrate = RecordingKeys.vibrate(session);
    _init();
  }

  Future<void> _init() async {
    final session = context.read<VaultService>().session;
    if (session != null) _myKey = await RecordingKeys.id(session);
    await _refresh();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final s = await VaultRecorder.status();
    if (mounted) setState(() => _status = s);
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _setArmed(bool on) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (on) {
        if (!await ensureMicrophone(context)) {
          setState(() => _error = 'The microphone permission is needed.');
          return;
        }
        if (!mounted) return;
        final session = context.read<VaultService>().session;
        if (session == null) return;
        final pub = await RecordingKeys.publicKey(session);
        _myKey = await VaultRecorder.keyId(pub);
        await VaultRecorder.arm(pub, vibrate: _vibrate);
      } else {
        await VaultRecorder.disarm();
      }
      for (var i = 0; i < 20; i++) {
        await _refresh();
        if (_armedHere == on) break;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      if (on && !_armedHere) setState(() => _error = 'Could not arm: ${_status.error ?? 'unknown error'}');
    } catch (e) {
      setState(() => _error = 'Could not change it: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setVibrate(bool on) async {
    final session = context.read<VaultService>().session;
    if (session == null) return;
    setState(() => _vibrate = on);
    await session.putExtra(RecordingKeys.vibrateKey, on);
    if (_armedHere) await VaultRecorder.arm(await RecordingKeys.publicKey(session), vibrate: on);
  }

  Widget _card(List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Column(children: children),
      );

  Widget _point(String bold, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: '$bold ', style: AppFonts.outfit(fontWeight: FontWeight.w700, color: Colors.white)),
            TextSpan(text: text),
          ]),
          style: AppFonts.outfit(fontSize: 13, color: Colors.white70, height: 1.4),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF090D16),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white70, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Hidden recorder', style: AppFonts.outfit(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          children: [
            _card([
              SwitchListTile(
                key: const Key('hidden-armed'),
                value: _armedHere,
                onChanged: _busy ? null : _setArmed,
                activeThumbColor: _accent,
                title: Text(
                  'Volume-down ×3 records',
                  style: AppFonts.outfit(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                ),
                subtitle: Text(
                  _recordingHere
                      ? 'Recording now. Volume-down ×3 to stop.'
                      : _armedHere
                          ? 'Armed. Works with the screen off.'
                          : 'Off',
                  key: const Key('hidden-state'),
                  style: AppFonts.outfit(fontSize: 12, color: _recordingHere ? const Color(0xFFF43F5E) : Colors.white54),
                ),
              ),
              SwitchListTile(
                value: _vibrate,
                onChanged: _busy ? null : _setVibrate,
                activeThumbColor: _accent,
                title: Text('Buzz to confirm', style: AppFonts.outfit(fontSize: 14, color: Colors.white)),
                subtitle: Text(
                  'One short buzz when recording starts, two when it stops.',
                  style: AppFonts.outfit(fontSize: 12, color: Colors.white54),
                ),
              ),
            ]),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text(_error!, style: AppFonts.outfit(fontSize: 13, color: const Color(0xFFFB7185))),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _point('How:', 'with the screen off, press volume-down three times within a second and a half. '
                      'Do it again to stop. No need to unlock or look at the phone.'),
                  _point('Where it goes:', 'the audio is encrypted to this vault as it\'s recorded. The phone can\'t '
                      'play it back; it moves into this vault the next time you unlock it. The other vault never sees it.'),
                  _point('Stays armed', 'until you turn it off, the phone restarts, or Android stops the app. On '
                      'Samsung phones, set the app\'s battery use to Unrestricted so it isn\'t stopped.'),
                  _point('Android shows it:', 'the green microphone dot appears while recording, and the system '
                      'lists the app as running. If music or a video is playing, the volume keys control that instead.'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
