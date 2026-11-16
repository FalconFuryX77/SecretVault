import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/unlock_provider.dart';
import '../recorder/vault_recorder.dart';
import '../services/vault_service.dart';
import '../theme/app_fonts.dart';
import '../vault/vault_container.dart';
import 'recorder_screen.dart';

const _accent = Color(0xFFA78BFA);

/// Arms the hidden trigger for the open vault: a volume button pressed a few
/// times quickly with the screen off (volume-down three times by default),
/// and/or the phone's assistant button, starts recording; the same again
/// stops it. Recordings are encrypted to this vault and move into it the
/// next time it's unlocked.
class HiddenRecorderScreen extends StatefulWidget {
  const HiddenRecorderScreen({super.key});

  @override
  State<HiddenRecorderScreen> createState() => _HiddenRecorderScreenState();
}

class _HiddenRecorderScreenState extends State<HiddenRecorderScreen> {
  RecorderStatus _status = const RecorderStatus();
  String? _myKey;
  bool _vibrate = true;
  TriggerSettings _trigger = TriggerSettings.standard;
  ({bool enabled, bool holder}) _assist = (enabled: false, holder: false);
  bool _busy = false;
  String? _error;
  Timer? _poll;

  bool get _armedHere => _status.armed && _status.armedKey != null && _status.armedKey == _myKey;
  bool get _recordingHere => _status.recording && _status.recordingKey != null && _status.recordingKey == _myKey;

  @override
  void initState() {
    super.initState();
    final session = context.read<VaultService>().session;
    if (session != null) {
      _vibrate = RecordingKeys.vibrate(session);
      _trigger = TriggerSettings.of(session);
    }
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    _init();
  }

  Future<void> _init() async {
    final session = context.read<VaultService>().session;
    if (session != null) _myKey = await RecordingKeys.id(session);
    await _refresh();
    await _refreshAssist();
  }

  void _setError(String? e) {
    if (mounted) setState(() => _error = e);
  }

  Future<void> _refresh() async {
    final s = await VaultRecorder.status();
    if (mounted) setState(() => _status = s);
  }

  Future<void> _refreshAssist() async {
    final a = await VaultRecorder.assistState();
    if (mounted) setState(() => _assist = a);
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _arm(VaultSession session) async {
    final pub = await RecordingKeys.publicKey(session);
    _myKey = await VaultRecorder.keyId(pub);
    if (_trigger.assist) await VaultRecorder.setAssistEnabled(true);
    await VaultRecorder.arm(pub, vibrate: _vibrate, trigger: _trigger);
  }

  Future<void> _setArmed(bool on) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (on) {
        if (!_trigger.isUsable) {
          _setError('Choose a volume button or the assistant button first.');
          return;
        }
        if (!await ensureMicrophone(context)) {
          _setError('The microphone permission is needed.');
          return;
        }
        if (!mounted) return;
        final session = context.read<VaultService>().session;
        if (session == null) return;
        await _arm(session);
      } else {
        await VaultRecorder.disarm();
      }
      for (var i = 0; i < 20; i++) {
        await _refresh();
        if (_armedHere == on) break;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      if (on && !_armedHere) _setError('Could not arm: ${_status.error ?? 'unknown error'}');
    } catch (e) {
      _setError('Could not change it: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setVibrate(bool on) async {
    final session = context.read<VaultService>().session;
    if (session == null) return;
    setState(() => _vibrate = on);
    await session.putExtra(RecordingKeys.vibrateKey, on);
    if (_armedHere) await _arm(session);
  }

  /// Saves a new trigger and, if armed, re-arms with it at once.
  Future<void> _setTrigger(TriggerSettings t) async {
    final session = context.read<VaultService>().session;
    if (session == null || _busy || t == _trigger) return;
    if (!t.isUsable && _armedHere) {
      _setError('Turn the recorder off first, or keep one way to trigger it.');
      return;
    }
    setState(() {
      _trigger = t;
      _error = null;
    });
    await t.save(session);
    if (_armedHere) await _arm(session);
  }

  Future<void> _setAssist(bool on) async {
    await _setTrigger(_trigger.copyWith(assist: on));
    if (!on) return;
    await VaultRecorder.setAssistEnabled(true);
    await _refreshAssist();
    if (!_assist.holder) await _openAssistSettings();
  }

  /// Opens Android's "digital assistant app" screen without the vault
  /// locking because the app went to the background, and waits for the
  /// user to come back (or three minutes, after which it locks anyway).
  Future<void> _openAssistSettings() async {
    final unlock = context.read<UnlockProvider>();
    await unlock.withoutAutoLock(() async {
      var left = false;
      final back = Completer<void>();
      final listener = AppLifecycleListener(
        onHide: () => left = true,
        onResume: () {
          if (left && !back.isCompleted) back.complete();
        },
      );
      try {
        if (!await VaultRecorder.openAssistSettings()) {
          _setError("This phone has no screen for choosing the assistant app.");
          return;
        }
        await back.future.timeout(const Duration(minutes: 3), onTimeout: () {});
      } finally {
        listener.dispose();
      }
    });
    await _refreshAssist();
  }

  Widget _card(List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
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

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
        child: Text(text, style: AppFonts.outfit(fontSize: 14, color: Colors.white)),
      );

  String _capitalised(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  Widget _volumeChoice() {
    const options = [(-1, 'Down'), (1, 'Up'), (0, 'Off')];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 8,
        children: [
          for (final (value, label) in options)
            ChoiceChip(
              key: Key('trigger-button-$label'.toLowerCase()),
              label: Text(label, style: AppFonts.outfit(fontSize: 13)),
              selected: _trigger.button == value,
              selectedColor: _accent.withValues(alpha: 0.35),
              onSelected: _busy ? null : (_) => _setTrigger(_trigger.copyWith(button: value)),
            ),
        ],
      ),
    );
  }

  Widget _pressesChoice() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 8,
        children: [
          for (var n = TriggerSettings.minPresses; n <= TriggerSettings.maxPresses; n++)
            ChoiceChip(
              key: Key('trigger-presses-$n'),
              label: Text('$n', style: AppFonts.outfit(fontSize: 13)),
              selected: _trigger.presses == n,
              selectedColor: _accent.withValues(alpha: 0.35),
              onSelected: _busy || !_trigger.usesVolume ? null : (_) => _setTrigger(_trigger.copyWith(presses: n)),
            ),
        ],
      ),
    );
  }

  String get _assistSubtitle {
    if (!_trigger.assist) {
      return _assist.holder
          ? 'Off for this vault. The app is still your assistant app; choose another in Android\'s settings.'
          : 'Uses the phone\'s assistant button (on many phones, a long press on power).';
    }
    return _assist.holder
        ? 'Ready: Files is your digital assistant app.'
        : 'Choose Files as the digital assistant app in Android\'s settings.';
  }

  @override
  Widget build(BuildContext context) {
    final what = _trigger.describe();
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
                  '${_capitalised(what)} records',
                  style: AppFonts.outfit(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                ),
                subtitle: Text(
                  _recordingHere
                      ? 'Recording now. ${_capitalised(what)} to stop.'
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
            _card([
              _label('Volume button'),
              _volumeChoice(),
              _label('Presses'),
              _pressesChoice(),
              const SizedBox(height: 4),
              SwitchListTile(
                key: const Key('trigger-assist'),
                value: _trigger.assist,
                onChanged: _busy ? null : _setAssist,
                activeThumbColor: _accent,
                title: Text('Assistant button', style: AppFonts.outfit(fontSize: 14, color: Colors.white)),
                subtitle: Text(_assistSubtitle, style: AppFonts.outfit(fontSize: 12, color: Colors.white54)),
              ),
              if (_trigger.assist && !_assist.holder || !_trigger.assist && _assist.holder)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                  child: TextButton(
                    key: const Key('trigger-assist-settings'),
                    onPressed: _openAssistSettings,
                    child: Text('Open assistant settings', style: AppFonts.outfit(color: _accent)),
                  ),
                ),
            ]),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text(_error!, key: const Key('hidden-error'), style: AppFonts.outfit(fontSize: 13, color: const Color(0xFFFB7185))),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_trigger.usesVolume)
                    _point('Volume:', 'with the screen off, press ${_trigger.volumeLabel.toLowerCase()} '
                        '${_trigger.presses} times quickly (about half a second per press). Do it again to stop. '
                        'Pressing the other volume button starts the count again. No need to unlock or look at the phone.'),
                  if (_trigger.assist)
                    _point('Assistant button:', 'press whatever opens the assistant on this phone (an assistant key, '
                        'or holding power or home on many phones) once to start and once to stop. Android shows '
                        'Files as the assistant app in Settings, and the button no longer opens your usual assistant. '
                        'Volume presses are harder to notice.'),
                  _point('Where it goes:', 'the audio is encrypted to this vault as it\'s recorded. The phone can\'t '
                      'play it back; it moves into this vault the next time you unlock it. The other vault never sees it.'),
                  _point('Stays armed', 'until you turn it off, the phone restarts, or Android stops the app. On '
                      'Samsung phones, set the app\'s battery use to Unrestricted so it isn\'t stopped.'),
                  _point('Unlock soon after:', 'until you unlock this vault, its recordings wait, encrypted, '
                      'in the app\'s storage. Nobody can play them, but a forensic examination of the phone could '
                      'show that recordings exist that the vault you opened can\'t read.'),
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
