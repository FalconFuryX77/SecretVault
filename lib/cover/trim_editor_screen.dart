import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../theme/app_fonts.dart';
import 'video_trimmer.dart';

const _accent = Color(0xFF22D3EE);

/// Trims one video: a preview, a range to keep, sound on or off, Save.
class TrimEditorScreen extends StatefulWidget {
  final String uri;
  const TrimEditorScreen({super.key, required this.uri});

  @override
  State<TrimEditorScreen> createState() => _TrimEditorScreenState();
}

class _TrimEditorScreenState extends State<TrimEditorScreen> {
  VideoPlayerController? _c;
  Duration _length = Duration.zero;
  RangeValues _range = const RangeValues(0, 1);
  bool _mute = false;
  bool _saving = false;
  String? _error;
  final List<Uint8List?> _strip = [];

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final info = await VideoTrimmer.info(widget.uri);
      final c = VideoPlayerController.contentUri(Uri.parse(widget.uri));
      await c.initialize();
      c.addListener(_tick);
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _c = c;
        _length = info.duration > Duration.zero ? info.duration : c.value.duration;
        _range = RangeValues(0, _length.inMilliseconds.toDouble().clamp(1, double.infinity));
      });
      // A strip of frames along the bottom, like any trimmer.
      for (var i = 0; i < 8; i++) {
        final at = Duration(milliseconds: (_length.inMilliseconds * (i + 0.5) / 8).round());
        final f = await VideoTrimmer.frame(widget.uri, at, maxSide: 160).catchError((Object _) => null);
        if (!mounted) return;
        setState(() => _strip.add(f));
      }
    } catch (e) {
      if (mounted) setState(() => _error = "This video can't be opened.");
    }
  }

  /// Keeps the preview inside the chosen range.
  void _tick() {
    final c = _c;
    if (c == null || !c.value.isPlaying) {
      if (mounted) setState(() {});
      return;
    }
    if (c.value.position.inMilliseconds >= _range.end) {
      c.pause();
      c.seekTo(Duration(milliseconds: _range.start.round()));
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c?.removeListener(_tick);
    _c?.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    final c = _c;
    if (c == null) return;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      final pos = c.value.position.inMilliseconds;
      if (pos < _range.start || pos >= _range.end - 100) await c.seekTo(Duration(milliseconds: _range.start.round()));
      await c.play();
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    await _c?.pause();
    try {
      await VideoTrimmer.trim(
        widget.uri,
        Duration(milliseconds: _range.start.round()),
        Duration(milliseconds: _range.end.round()),
        mute: _mute,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved to Movies/Video Trimmer', style: AppFonts.ui())),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = "The clip couldn't be saved.";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final total = _length.inMilliseconds.toDouble().clamp(1, double.infinity).toDouble();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('Trim', style: AppFonts.ui(fontWeight: FontWeight.bold)),
        actions: [
          TextButton(
            key: const Key('trim-save'),
            onPressed: c == null || _saving ? null : _save,
            child: Text('Save', style: AppFonts.ui(color: _accent, fontWeight: FontWeight.bold, fontSize: 15)),
          ),
        ],
      ),
      body: _error != null && c == null
          ? Center(child: Text(_error!, style: AppFonts.ui(color: Colors.white60)))
          : c == null
              ? const Center(child: CircularProgressIndicator(color: _accent))
              : Column(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: _togglePlay,
                        child: Center(
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              AspectRatio(
                                aspectRatio: c.value.aspectRatio <= 0 ? 16 / 9 : c.value.aspectRatio,
                                child: VideoPlayer(c),
                              ),
                              if (!c.value.isPlaying)
                                const Icon(Icons.play_circle_fill_rounded, color: Colors.white70, size: 64),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Container(
                      color: const Color(0xFF0B0F17),
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                      child: SafeArea(
                        top: false,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              height: 44,
                              child: Row(
                                children: [
                                  for (var i = 0; i < 8; i++)
                                    Expanded(
                                      child: Container(
                                        margin: const EdgeInsets.symmetric(horizontal: 1),
                                        color: Colors.white10,
                                        child: i < _strip.length && _strip[i] != null
                                            ? Image.memory(_strip[i]!, fit: BoxFit.cover, gaplessPlayback: true)
                                            : null,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            RangeSlider(
                              key: const Key('trim-range'),
                              values: _range,
                              min: 0,
                              max: total,
                              activeColor: _accent,
                              onChanged: _saving
                                  ? null
                                  : (v) {
                                      if (v.end - v.start < 500) return;
                                      setState(() => _range = v);
                                      c.seekTo(Duration(milliseconds: (v.start != _range.start ? v.start : v.end).round()));
                                    },
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(formatClock(Duration(milliseconds: _range.start.round())),
                                    style: AppFonts.firaCode(fontSize: 12, color: Colors.white70)),
                                Text('Clip ${formatClock(Duration(milliseconds: (_range.end - _range.start).round()))}',
                                    key: const Key('trim-length'),
                                    style: AppFonts.ui(fontSize: 12, color: _accent)),
                                Text(formatClock(Duration(milliseconds: _range.end.round())),
                                    style: AppFonts.firaCode(fontSize: 12, color: Colors.white70)),
                              ],
                            ),
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              value: _mute,
                              onChanged: _saving ? null : (v) => setState(() => _mute = v),
                              activeThumbColor: _accent,
                              title: Text('Remove sound', style: AppFonts.ui(fontSize: 14, color: Colors.white)),
                            ),
                            if (_saving) const LinearProgressIndicator(color: _accent),
                            if (_error != null)
                              Text(_error!, style: AppFonts.ui(fontSize: 12, color: const Color(0xFFFB7185))),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
