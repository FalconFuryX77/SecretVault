import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../models/vault_item.dart';
import '../providers/unlock_provider.dart';
import '../providers/vault_provider.dart';
import '../services/security_channel_service.dart';
import '../theme/app_fonts.dart';
import '../vault/crypto_primitives.dart';
import 'vault_media_server.dart';
import '../theme/ui.dart';

const _accent = Ui.signal;

/// Plays a vault video or audio file with the phone's own media engine,
/// fed from a private in-memory stream ([VaultMediaServer]): nothing
/// decrypted is written to storage, and no other app is involved.
class MediaPlayerView extends StatefulWidget {
  final VaultItem item;
  final bool isVideo;

  const MediaPlayerView({super.key, required this.item, required this.isVideo});

  @override
  State<MediaPlayerView> createState() => _MediaPlayerViewState();
}

class _MediaPlayerViewState extends State<MediaPlayerView> {
  VaultMediaServer? _server;
  VideoPlayerController? _controller;
  late final UnlockProvider _unlock;
  String? _error;
  bool _integrityFailed = false;
  bool _screenKeptOn = false;
  double? _dragMs;
  double _speed = 1.0;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _unlock = context.read<UnlockProvider>();
    _start();
  }

  Future<void> _start() async {
    final provider = context.read<VaultProvider>();
    try {
      final server = await provider.openMediaStream(
        widget.item,
        onReadError: (e) {
          if (e is TamperedDataException && !_disposed) {
            setState(() => _integrityFailed = true);
          }
        },
      );
      if (_disposed) {
        await server?.close();
        return;
      }
      if (server == null) {
        setState(() => _error = 'This item has no file data.');
        return;
      }
      _server = server;
      final c = VideoPlayerController.networkUrl(
        server.uri,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      );
      _controller = c;
      c.addListener(_onPlayerChanged);
      await c.initialize();
      if (_disposed) return;
      setState(() {});
      await c.play();
    } catch (e) {
      if (_disposed) return;
      setState(() => _error ??= _describe(e));
    }
  }

  String _describe(Object e) {
    final text = e.toString();
    if (text.contains('Source error') || text.contains('UnrecognizedInputFormat') || text.contains('format')) {
      return "This phone can't play this file's format.";
    }
    return 'This file could not be played.';
  }

  void _onPlayerChanged() {
    final c = _controller;
    if (c == null || _disposed) return;
    final v = c.value;
    if (v.isPlaying && !v.isLooping) {
      // Watching or listening is activity: don't auto-lock mid-playback.
      // A loop would keep the vault open forever, so it doesn't count.
      _unlock.onUserActivity();
    }
    final wantScreenOn = widget.isVideo && v.isPlaying && !v.isLooping;
    if (wantScreenOn != _screenKeptOn) {
      _screenKeptOn = wantScreenOn;
      SecurityChannelService.setKeepScreenOn(wantScreenOn);
    }
    if (v.hasError && _error == null) {
      _error = _describe(v.errorDescription ?? '');
    }
    setState(() {});
  }

  @override
  void dispose() {
    _disposed = true;
    final c = _controller;
    c?.removeListener(_onPlayerChanged);
    c?.dispose();
    _server?.close();
    if (_screenKeptOn) SecurityChannelService.setKeepScreenOn(false);
    super.dispose();
  }

  // ─── Controls ─────────────────────────────────────────────────────

  Future<void> _togglePlay() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      if (c.value.position >= c.value.duration) await c.seekTo(Duration.zero);
      await c.play();
    }
  }

  Future<void> _skip(int seconds) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    var target = c.value.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (target > c.value.duration) target = c.value.duration;
    await c.seekTo(target);
  }

  Future<void> _cycleSpeed() async {
    final c = _controller;
    if (c == null) return;
    const speeds = [1.0, 1.25, 1.5, 2.0, 0.75];
    final next = speeds[(speeds.indexOf(_speed) + 1) % speeds.length];
    await c.setPlaybackSpeed(next);
    setState(() => _speed = next);
  }

  Future<void> _toggleLoop() async {
    final c = _controller;
    if (c == null) return;
    await c.setLooping(!c.value.isLooping);
  }

  static String _clock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  /// The same player, filling the screen: turned to landscape for a
  /// landscape video, system bars hidden. Back (or the button) returns.
  Future<void> _fullScreen(VideoPlayerController c) async {
    final landscape = c.value.aspectRatio > 1.0;
    await SystemChrome.setPreferredOrientations(landscape
        ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
        : const [DeviceOrientation.portraitUp]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (!mounted) return;
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        settings: const RouteSettings(name: 'vault/video-full'),
        pageBuilder: (_, _, _) => _FullScreenVideo(controller: c, onToggle: _togglePlay),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(const []);
    if (mounted) setState(() {});
  }

  // ─── Layout ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_integrityFailed) {
      return _message(
        'This file failed its integrity check: it was modified or damaged on '
        'disk, so it will not be played.',
      );
    }
    if (_error != null) return _message(_error!);
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(color: _accent));
    }
    return widget.isVideo ? _video(c) : _audio(c);
  }

  Widget _message(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            text,
            key: const Key('media-error'),
            textAlign: TextAlign.center,
            style: AppFonts.ui(color: Ui.alert, fontSize: 14),
          ),
        ),
      );

  Widget _video(VideoPlayerController c) {
    return Column(
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _togglePlay,
            onDoubleTapDown: (d) {
              final width = context.size?.width ?? 0;
              _skip(d.localPosition.dx < width / 2 ? -10 : 10);
            },
            child: Container(
              color: Colors.black,
              alignment: Alignment.center,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AspectRatio(
                    aspectRatio: c.value.aspectRatio <= 0 ? 16 / 9 : c.value.aspectRatio,
                    child: VideoPlayer(c),
                  ),
                  if (c.value.isBuffering) const CircularProgressIndicator(color: _accent),
                  if (!c.value.isPlaying && !c.value.isBuffering)
                    Container(
                      decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                      padding: const EdgeInsets.all(12),
                      child: const Icon(Icons.play_arrow_rounded, size: 48, color: Colors.white),
                    ),
                ],
              ),
            ),
          ),
        ),
        _controls(c),
      ],
    );
  }

  Widget _audio(VideoPlayerController c) {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 156,
                    height: 156,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const RadialGradient(colors: [Ui.raised, Color(0xFF0F172A)]),
                      border: Border.all(color: _accent.withValues(alpha: 0.4), width: 2),
                    ),
                    child: Icon(
                      Icons.graphic_eq_rounded,
                      size: 64,
                      color: c.value.isPlaying ? _accent : Colors.white38,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    widget.item.title,
                    textAlign: TextAlign.center,
                    style: AppFonts.ui(fontSize: 18, fontWeight: FontWeight.w500, color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ),
        _controls(c),
      ],
    );
  }

  Widget _controls(VideoPlayerController c) {
    final v = c.value;
    final totalMs = v.duration.inMilliseconds.toDouble();
    final posMs = (_dragMs ?? v.position.inMilliseconds.toDouble()).clamp(0.0, totalMs <= 0 ? 0.0 : totalMs);
    return Container(
      color: Ui.surface,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: _accent,
                inactiveTrackColor: Colors.white12,
                thumbColor: _accent,
                trackHeight: 3,
              ),
              child: Slider(
                key: const Key('media-seek'),
                value: totalMs <= 0 ? 0 : posMs,
                max: totalMs <= 0 ? 1 : totalMs,
                onChanged: totalMs <= 0 ? null : (x) => setState(() => _dragMs = x),
                onChangeEnd: totalMs <= 0
                    ? null
                    : (x) async {
                        await c.seekTo(Duration(milliseconds: x.round()));
                        if (mounted) setState(() => _dragMs = null);
                      },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _clock(Duration(milliseconds: posMs.round())),
                    key: const Key('media-position'),
                    style: AppFonts.firaCode(fontSize: 11, color: Colors.white60),
                  ),
                  Text(
                    _clock(v.duration),
                    key: const Key('media-duration'),
                    style: AppFonts.firaCode(fontSize: 11, color: Colors.white60),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  tooltip: 'Repeat',
                  icon: Icon(Icons.repeat_rounded, color: v.isLooping ? _accent : Colors.white38),
                  onPressed: _toggleLoop,
                ),
                IconButton(
                  tooltip: 'Back 10 seconds',
                  icon: const Icon(Icons.replay_10_rounded, color: Colors.white70, size: 28),
                  onPressed: () => _skip(-10),
                ),
                InkWell(
                  key: const Key('media-play'),
                  onTap: _togglePlay,
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 58,
                    height: 58,
                    decoration: const BoxDecoration(shape: BoxShape.circle, color: _accent),
                    child: Icon(
                      v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      size: 32,
                      color: Ui.canvas,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Forward 10 seconds',
                  icon: const Icon(Icons.forward_10_rounded, color: Colors.white70, size: 28),
                  onPressed: () => _skip(10),
                ),
                TextButton(
                  onPressed: _cycleSpeed,
                  child: Text(
                    '${_speed}x'.replaceAll('.0x', 'x'),
                    style: AppFonts.firaCode(color: _accent, fontWeight: FontWeight.w500, fontSize: 13),
                  ),
                ),
                if (widget.isVideo)
                  IconButton(
                    key: const Key('media-fullscreen'),
                    tooltip: 'Full screen',
                    icon: const Icon(Icons.fullscreen_rounded, color: Colors.white70, size: 28),
                    onPressed: () => _fullScreen(c),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FullScreenVideo extends StatefulWidget {
  final VideoPlayerController controller;
  final VoidCallback onToggle;
  const _FullScreenVideo({required this.controller, required this.onToggle});

  @override
  State<_FullScreenVideo> createState() => _FullScreenVideoState();
}

class _FullScreenVideoState extends State<_FullScreenVideo> {
  bool _controls = true;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _scheduleHide();
  }

  @override
  void dispose() {
    _hide?.cancel();
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _scheduleHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted && widget.controller.value.isPlaying) setState(() => _controls = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final v = c.value;
    return Scaffold(
      key: const Key('media-fullscreen-view'),
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() => _controls = !_controls);
          if (_controls) _scheduleHide();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: v.aspectRatio <= 0 ? 16 / 9 : v.aspectRatio,
                child: VideoPlayer(c),
              ),
            ),
            if (_controls) ...[
              Positioned(
                top: 8,
                left: 8,
                child: SafeArea(
                  child: IconButton(
                    key: const Key('media-fullscreen-exit'),
                    tooltip: 'Exit full screen',
                    icon: const Icon(Icons.fullscreen_exit_rounded, color: Colors.white, size: 30),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
              Center(
                child: InkWell(
                  onTap: () {
                    widget.onToggle();
                    _scheduleHide();
                  },
                  customBorder: const CircleBorder(),
                  child: Container(
                    decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                    padding: const EdgeInsets.all(14),
                    child: Icon(v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 52, color: Colors.white),
                  ),
                ),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 8,
                child: SafeArea(
                  top: false,
                  child: VideoProgressIndicator(
                    c,
                    allowScrubbing: true,
                    colors: const VideoProgressColors(playedColor: _accent, bufferedColor: Colors.white24),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
