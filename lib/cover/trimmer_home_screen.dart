import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../navigation/vault_routes.dart';
import '../providers/unlock_provider.dart';
import '../screens/lock_screen.dart';
import '../screens/setup_screen.dart';
import '../screens/vault_home_screen.dart';
import '../services/security_channel_service.dart';
import '../sync/outbox.dart';
import '../theme/app_fonts.dart';
import '../util/format.dart';
import 'trim_editor_screen.dart';
import 'video_trimmer.dart';

const coverName = 'Video Trimmer';
const _accent = Color(0xFF22D3EE);

/// The cover app: a working video trimmer. Picking a video (Android's photo
/// picker, no storage permission), trimming it without re-encoding, and
/// the clips it saved (Movies/Video Trimmer).
///
/// The way in: three quick taps on the title open the vault's PIN screen.
/// Nothing else on this screen hints at it.
class TrimmerHomeScreen extends StatefulWidget {
  const TrimmerHomeScreen({super.key});

  @override
  State<TrimmerHomeScreen> createState() => _TrimmerHomeScreenState();
}

class _TrimmerHomeScreenState extends State<TrimmerHomeScreen> {
  List<TrimmedClip>? _clips;
  final Map<String, Uint8List?> _thumbs = {};
  int _taps = 0;
  DateTime _lastTap = DateTime(0);
  StreamSubscription<Object?>? _unlockSub;

  @override
  void initState() {
    super.initState();
    SecurityChannelService.clearAll();
    _load();
    _unlockSub = context.read<UnlockProvider>().onVaultUnlocked.listen((_) {
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.popUntil((route) => route.isFirst);
      nav.push(
        MaterialPageRoute(
          settings: const RouteSettings(name: '${vaultRoutePrefix}home'),
          builder: (_) => const VaultHomeScreen(),
        ),
      );
    });
  }

  @override
  void dispose() {
    _unlockSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final clips = await VideoTrimmer.recent();
      if (mounted) setState(() => _clips = clips);
      for (final c in clips.take(30)) {
        if (_thumbs.containsKey(c.uri)) continue;
        final t = await VideoTrimmer.frame(c.uri, const Duration(milliseconds: 500), maxSide: 240).catchError((Object _) => null);
        if (!mounted) return;
        setState(() => _thumbs[c.uri] = t);
      }
    } catch (_) {
      if (mounted) setState(() => _clips = const []);
    }
  }

  /// An ordinary "Clear cache": the thumbnails, decoded images, and (the
  /// quiet part) the queue that uploads while the vault is locked, with
  /// its login. Nothing in the vault or on the server is touched; locked
  /// upload stays off until it's turned on again inside the vault.
  Future<void> _clearCache() async {
    setState(_thumbs.clear);
    PaintingBinding.instance.imageCache.clear();
    await const PlatformOutbox().stop();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cache cleared')));
    unawaited(_load());
  }

  void _onTitleTap() {
    final now = DateTime.now();
    _taps = now.difference(_lastTap).inMilliseconds > 800 ? 1 : _taps + 1;
    _lastTap = now;
    if (_taps < 3) return;
    _taps = 0;
    final setUp = context.read<UnlockProvider>().isSetupComplete;
    Navigator.push(
      context,
      MaterialPageRoute(
        settings: RouteSettings(name: '$vaultRoutePrefix${setUp ? 'lock' : 'setup'}'),
        builder: (_) => setUp ? const LockScreen() : const SetupScreen(),
      ),
    );
  }

  Future<void> _newTrim() async {
    final uri = await VideoTrimmer.pick();
    if (uri == null || !mounted) return;
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => TrimEditorScreen(uri: uri)));
    if (saved == true) await _load();
  }

  Future<void> _clipMenu(TrimmedClip c) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF161B22),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_circle_outline_rounded, color: Colors.white70),
              title: Text('Play', style: AppFonts.ui(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, 'play'),
            ),
            ListTile(
              leading: const Icon(Icons.content_cut_rounded, color: Colors.white70),
              title: Text('Trim again', style: AppFonts.ui(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, 'trim'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, color: Color(0xFFFB7185)),
              title: Text('Delete', style: AppFonts.ui(color: const Color(0xFFFB7185))),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'play':
        await VideoTrimmer.view(c.uri);
      case 'trim':
        final saved = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => TrimEditorScreen(uri: c.uri)));
        if (saved == true) await _load();
      case 'delete':
        if (await VideoTrimmer.delete(c.uri)) await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final clips = _clips;
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F17),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B0F17),
        elevation: 0,
        title: GestureDetector(
          key: const Key('cover-title'),
          behavior: HitTestBehavior.opaque,
          onTap: _onTitleTap,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.content_cut_rounded, color: _accent, size: 22),
              const SizedBox(width: 10),
              Text(coverName, style: AppFonts.ui(fontSize: 19, fontWeight: FontWeight.bold, color: Colors.white)),
            ],
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            key: const Key('cover-menu'),
            icon: const Icon(Icons.more_vert_rounded, color: Colors.white70),
            color: const Color(0xFF161B22),
            onSelected: (v) {
              if (v == 'cache') _clearCache();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                key: const Key('cover-clear-cache'),
                value: 'cache',
                child: Text('Clear cache', style: AppFonts.ui(color: Colors.white)),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('cover-new'),
        backgroundColor: _accent,
        foregroundColor: const Color(0xFF0B0F17),
        onPressed: _newTrim,
        icon: const Icon(Icons.add_rounded),
        label: Text('New trim', style: AppFonts.ui(fontWeight: FontWeight.bold)),
      ),
      body: clips == null
          ? const Center(child: CircularProgressIndicator(color: _accent))
          : clips.isEmpty
              ? _empty()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                    itemCount: clips.length + 1,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      if (i == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text('Your clips · Movies/Video Trimmer',
                              style: AppFonts.ui(fontSize: 12, color: Colors.white54)),
                        );
                      }
                      return _clipTile(clips[i - 1]);
                    },
                  ),
                ),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(color: _accent.withValues(alpha: 0.12), shape: BoxShape.circle),
                child: const Icon(Icons.movie_filter_rounded, color: _accent, size: 48),
              ),
              const SizedBox(height: 18),
              Text('Trim a video', style: AppFonts.ui(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 8),
              Text(
                'Pick a video, cut its start and end, and save the clip. The original stays as it is. '
                'Clips are saved to Movies/Video Trimmer, at full quality.',
                textAlign: TextAlign.center,
                style: AppFonts.ui(fontSize: 13, color: Colors.white60),
              ),
            ],
          ),
        ),
      );

  Widget _clipTile(TrimmedClip c) {
    final thumb = _thumbs[c.uri];
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _clipMenu(c),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF161B22),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: 96,
                height: 60,
                color: Colors.black,
                child: thumb == null
                    ? const Icon(Icons.movie_rounded, color: Colors.white24)
                    : Image.memory(thumb, fit: BoxFit.cover, gaplessPlayback: true),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: AppFonts.ui(fontSize: 14, color: Colors.white, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('${formatClock(c.duration)} · ${formatBytes(c.size)}',
                      style: AppFonts.ui(fontSize: 12, color: Colors.white54)),
                ],
              ),
            ),
            const Icon(Icons.more_vert_rounded, color: Colors.white38),
          ],
        ),
      ),
    );
  }
}
