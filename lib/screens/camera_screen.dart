import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../camera/vault_camera.dart';
import '../providers/unlock_provider.dart';
import '../providers/vault_provider.dart';
import '../recorder/vault_recorder.dart';
import '../services/vault_service.dart';
import '../theme/app_fonts.dart';
import '../theme/ui.dart';

const _accent = Ui.ink2;

/// Asks for a permission without the vault locking while Android's prompt
/// is up.
Future<bool> ensurePermission(BuildContext context, Permission permission) async {
  final unlock = context.read<UnlockProvider>();
  final status = await unlock.withoutAutoLock(() => permission.request());
  return status.isGranted;
}

/// The in-vault camera: photos and videos go straight into the vault and
/// never into the phone's gallery. Photos are kept in memory until they're
/// stored, with their metadata (phone model, settings, time) removed.
/// Videos are encrypted as they're recorded; leaving the screen or locking
/// stops a video, and it's kept.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraInfo? _camera;
  bool _front = false;
  bool _video = false;
  bool _torch = false;
  bool _busy = false;
  bool _recording = false;
  bool _flash = false;
  DateTime? _recordingSince;
  Timer? _tick;
  Completer<void>? _holdLock;
  String? _message;
  bool _messageIsError = false;
  int _saved = 0;
  late final VaultProvider _vault;

  @override
  void initState() {
    super.initState();
    _vault = context.read<VaultProvider>();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _tick?.cancel();
    final wasRecording = _recording;
    // Stops a video in progress (it's kept, encrypted) and frees the camera.
    VaultCamera.close().then((_) {
      if (wasRecording) unawaited(_vault.importRecordings().catchError((Object _) => 0));
    }).catchError((Object _) {});
    _releaseLock();
    SystemChrome.setPreferredOrientations(const []);
    super.dispose();
  }

  void _say(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = text;
      _messageIsError = error;
    });
  }

  Future<void> _start() async {
    if (!await ensurePermission(context, Permission.camera)) {
      _say('The camera permission is needed.', error: true);
      return;
    }
    await _open();
  }

  Future<void> _open() async {
    setState(() => _busy = true);
    try {
      final c = await VaultCamera.open(front: _front, video: _video);
      if (!mounted) return;
      setState(() {
        _camera = c;
        _front = c.front;
        _torch = false;
        _message = null;
      });
    } on PlatformException catch (e) {
      _say("The camera couldn't start: ${e.message}", error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setMode(bool video) async {
    if (_busy || _recording || video == _video) return;
    setState(() => _video = video);
    await _open();
  }

  Future<void> _switchCamera() async {
    if (_busy || _recording) return;
    setState(() => _front = !_front);
    await _open();
  }

  Future<void> _toggleTorch() async {
    if (_busy) return;
    final on = await VaultCamera.torch(!_torch);
    if (mounted) setState(() => _torch = on);
  }

  Future<void> _shutter() async {
    if (_busy || _camera == null) return;
    if (!_video) return _takePhoto();
    if (_recording) return _stopVideo();
    return _startVideo();
  }

  Future<void> _takePhoto() async {
    setState(() {
      _busy = true;
      _flash = true;
    });
    Timer(const Duration(milliseconds: 120), () {
      if (mounted) setState(() => _flash = false);
    });
    try {
      final p = await VaultCamera.photo();
      // (The bytes arrive read-only from the platform channel, so they
      // can't be wiped here; the vault copy is encrypted at once.)
      await _vault.importPhoto(p.data);
      _saved++;
      _say('Photo saved to the vault.');
    } catch (e) {
      _say("The photo wasn't saved: $e", error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startVideo() async {
    final session = context.read<VaultService>().session;
    if (session == null) return;
    setState(() => _busy = true);
    try {
      final mic = await ensurePermission(context, Permission.microphone);
      final pub = await RecordingKeys.publicKey(session);
      final started = await VaultCamera.startVideo(pub, audio: mic);
      _holdInactivityLock();
      if (!mounted) return;
      setState(() {
        _recording = true;
        _recordingSince = DateTime.now();
      });
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      _say(started.audio ? 'Recording. Encrypted as it goes.' : 'Recording without sound (the microphone is busy or not allowed).');
    } catch (e) {
      _say("The video couldn't start: $e", error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopVideo() async {
    setState(() => _busy = true);
    _tick?.cancel();
    try {
      final r = await VaultCamera.stopVideo();
      if (mounted) setState(() => _recording = false);
      _say('Saving the video to the vault…');
      final moved = await _vault.importRecordings();
      if (moved == 0) {
        _say("The video wasn't moved in yet; it's kept, encrypted, and moves in at the next unlock.", error: true);
        return;
      }
      _saved++;
      _say(r?.error == null ? 'Video saved to the vault.' : 'Video saved (it stopped early: ${r!.error}).',
          error: r?.error != null);
    } catch (e) {
      _say("The video wasn't moved in yet; it's kept, encrypted, and moves in at the next unlock.", error: true);
    } finally {
      _releaseLock();
      if (mounted) {
        setState(() {
          _busy = false;
          _recording = false;
        });
      }
    }
  }

  /// Keeps the vault from locking for inactivity while a video records.
  void _holdInactivityLock() {
    if (_holdLock != null) return;
    final c = Completer<void>();
    _holdLock = c;
    unawaited(context.read<UnlockProvider>().holdingInactivityLock(() => c.future));
  }

  void _releaseLock() {
    final c = _holdLock;
    _holdLock = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  String get _elapsed {
    final since = _recordingSince;
    if (since == null) return '00:00';
    final d = DateTime.now().difference(since);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
  }

  Widget _preview(CameraInfo c) {
    Widget tex = Texture(textureId: c.textureId);
    final sideways = c.sensorOrientation % 180 != 0;
    final aspect = sideways ? c.height / c.width : c.width / c.height;
    if (!c.handlesRotation) {
      tex = RotatedBox(quarterTurns: c.sensorOrientation ~/ 90, child: tex);
      if (c.front) {
        tex = Transform(alignment: Alignment.center, transform: Matrix4.diagonal3Values(-1, 1, 1), child: tex);
      }
    }
    return AspectRatio(aspectRatio: aspect, child: tex);
  }

  Widget _modeButton(String label, bool video) {
    final selected = _video == video;
    return TextButton(
      key: Key('camera-mode-${label.toLowerCase()}'),
      onPressed: _recording ? null : () => _setMode(video),
      child: Text(
        label,
        style: AppFonts.ui(
          fontSize: 13,
          fontWeight: selected ? FontWeight.w500 : FontWeight.w500,
          color: selected ? _accent : Ui.ink2,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _camera;
    return ValueListenableBuilder<double?>(
      valueListenable: _vault.videoProgress,
      builder: (context, progress, _) => Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Ui.ink),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Spacer(),
                    if (_recording)
                      Container(
                        key: const Key('camera-timer'),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: Ui.alert, borderRadius: BorderRadius.circular(8)),
                        child: Text(_elapsed, style: AppFonts.firaCode(fontSize: 13, color: Ui.ink)),
                      ),
                    const Spacer(),
                    if (c?.hasFlash == true)
                      IconButton(
                        key: const Key('camera-torch'),
                        icon: Icon(_torch ? Icons.flash_on_rounded : Icons.flash_off_rounded, color: Ui.ink),
                        onPressed: _toggleTorch,
                      )
                    else
                      const SizedBox(width: 48),
                  ],
                ),
              ),
              Expanded(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (c != null) Center(child: _preview(c)),
                    if (c == null && _message == null) const CircularProgressIndicator(color: _accent),
                    if (_flash) Positioned.fill(child: Container(color: Ui.ink)),
                    if (progress != null)
                      Positioned.fill(
                        child: Container(
                          color: Colors.black87,
                          alignment: Alignment.center,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 200,
                                child: LinearProgressIndicator(value: progress, color: _accent),
                              ),
                              const SizedBox(height: 12),
                              Text('Moving the video into the vault…',
                                  style: AppFonts.ui(fontSize: 13, color: Ui.ink2)),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    _message!,
                    key: const Key('camera-status'),
                    textAlign: TextAlign.center,
                    style: AppFonts.ui(fontSize: 12, color: _messageIsError ? Ui.alert : Ui.ink2),
                  ),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [_modeButton('PHOTO', false), const SizedBox(width: 12), _modeButton('VIDEO', true)],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    SizedBox(
                      width: 56,
                      child: Text(
                        _saved == 0 ? '' : '$_saved saved',
                        key: const Key('camera-saved'),
                        style: AppFonts.ui(fontSize: 11, color: Ui.ink2),
                      ),
                    ),
                    GestureDetector(
                      key: const Key('camera-shutter'),
                      onTap: _shutter,
                      child: Container(
                        width: 74,
                        height: 74,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Ui.ink, width: 4),
                        ),
                        alignment: Alignment.center,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: _recording ? 28 : 58,
                          height: _recording ? 28 : 58,
                          decoration: BoxDecoration(
                            color: _video ? Ui.alert : Ui.ink,
                            borderRadius: BorderRadius.circular(_recording ? 6 : 29),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 56,
                      child: c?.canSwitch == true
                          ? IconButton(
                              key: const Key('camera-switch'),
                              icon: const Icon(Icons.cameraswitch_rounded, color: Ui.ink, size: 30),
                              onPressed: _recording ? null : _switchCamera,
                            )
                          : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
