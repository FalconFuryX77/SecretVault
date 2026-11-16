import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/unlock_provider.dart';
import '../recorder/vault_recorder.dart';
import '../services/vault_service.dart';
import '../vault/vault_container.dart';
import 'recorder_screen.dart';
import '../theme/ui.dart';


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

  /// One note under "How it works".
  Widget _point(String title, String text) => UiRow(title: title, detail: text, chevron: false);

  /// A labelled control inside a group.
  Widget _setting(String label, Widget control) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Ui.body()),
          const SizedBox(height: 10),
          control,
        ]),
      );

  String _capitalised(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  Widget _volumeChoice() => UiSegmented<int>(
        options: const [(-1, 'Down'), (1, 'Up'), (0, 'Off')],
        selected: _trigger.button,
        keyOf: (v) => 'trigger-button-${v == -1 ? 'down' : v == 1 ? 'up' : 'off'}',
        onChanged: _busy ? null : (v) => _setTrigger(_trigger.copyWith(button: v)),
      );

  Widget _pressesChoice() => UiSegmented<int>(
        options: [
          for (var n = TriggerSettings.minPresses; n <= TriggerSettings.maxPresses; n++) (n, '$n'),
        ],
        selected: _trigger.presses,
        keyOf: (n) => 'trigger-presses-$n',
        onChanged: _busy || !_trigger.usesVolume ? null : (n) => _setTrigger(_trigger.copyWith(presses: n)),
      );

  String get _assistSubtitle {
    if (!_trigger.assist) {
      return _assist.holder
          ? 'Off for this vault. The app is still your assistant app; choose another in Android\'s settings.'
          : 'Uses the phone\'s assistant button (on many phones, a long press on power).';
    }
    return _assist.holder
        ? 'Ready: Video Trimmer is your digital assistant app.'
        : 'Choose Video Trimmer as the digital assistant app in Android\'s settings.';
  }

  @override
  Widget build(BuildContext context) {
    final what = _trigger.describe();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, size: 22),
          tooltip: 'Back',
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Hidden recorder'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          children: [
            UiGroup(children: [
              UiSwitchRow(
                switchKey: const Key('hidden-armed'),
                detailKey: const Key('hidden-state'),
                icon: _recordingHere ? Icons.fiber_manual_record_rounded : Icons.screen_lock_portrait_outlined,
                title: '${_capitalised(what)} records',
                detail: _recordingHere
                    ? 'Recording now. ${_capitalised(what)} to stop.'
                    : _armedHere
                        ? 'Armed. Works with the screen off.'
                        : 'Off',
                value: _armedHere,
                onChanged: _busy ? null : _setArmed,
              ),
              UiSwitchRow(
                icon: Icons.vibration_rounded,
                title: 'Buzz to confirm',
                detail: 'One buzz when it starts, two when it stops.',
                value: _vibrate,
                onChanged: _busy ? null : _setVibrate,
              ),
            ]),
            UiGroup(label: 'Trigger', dividerIndent: 16, children: [
              _setting('Volume button', _volumeChoice()),
              _setting('Presses', _pressesChoice()),
              UiSwitchRow(
                switchKey: const Key('trigger-assist'),
                title: 'Assistant button',
                detail: _assistSubtitle,
                value: _trigger.assist,
                onChanged: _busy ? null : _setAssist,
              ),
              if (_trigger.assist && !_assist.holder || !_trigger.assist && _assist.holder)
                UiRow(
                  key: const Key('trigger-assist-settings'),
                  title: 'Open assistant settings',
                  onTap: _openAssistSettings,
                ),
            ]),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(Ui.gutter, 0, Ui.gutter, 18),
                child: Text(_error!, key: const Key('hidden-error'), style: Ui.detail(color: Ui.alert)),
              ),
            UiGroup(label: 'How it works', dividerIndent: 16, children: [
              if (_trigger.usesVolume)
                _point('Volume', 'With the screen off, press ${_trigger.volumeLabel.toLowerCase()} '
                    '${_trigger.presses} times quickly (about half a second per press). Do it again to stop. '
                    'Pressing the other volume button starts the count again. No need to unlock or look at the phone.'),
              if (_trigger.assist)
                _point('Assistant button', 'Press whatever opens the assistant on this phone (an assistant key, '
                    'or holding power or home on many phones) once to start and once to stop. Android shows '
                    'Video Trimmer as the assistant app in Settings, and the button no longer opens your usual '
                    'assistant. Volume presses are harder to notice.'),
              _point('Where it goes', "The audio is encrypted to this vault as it's recorded. The phone can't "
                  'play it back; it moves into this vault the next time you unlock it. The other vault never sees it.'),
              _point('Stays armed', 'Until you turn it off, the phone restarts, or Android stops the app. On '
                  "Samsung phones, set the app's battery use to Unrestricted so it isn't stopped."),
              _point('Unlock soon after', 'Until you unlock this vault, its recordings wait, encrypted, '
                  "in the app's storage. Nobody can play them, but a forensic examination of the phone could "
                  "show that recordings exist that the vault you opened can't read."),
              _point('Android shows it', 'The green microphone dot appears while recording, and the system '
                  'lists the app as running. If music or a video is playing, the volume keys control that instead.'),
            ]),
          ],
        ),
      ),
    );
  }
}
