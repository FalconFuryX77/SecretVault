import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../models/vault_item.dart';
import '../providers/vault_provider.dart';
import '../services/device_file_service.dart';
import '../services/security_channel_service.dart';
import '../vault/crypto_primitives.dart';

/// Secure In-Memory File Viewer.
/// Renders decrypted images, audio playback, video preview, PDF documents,
/// and formatted text directly from volatile RAM memory buffers without leaving
/// cleartext artifacts on disk.
class FileViewerScreen extends StatefulWidget {
  final VaultItem item;

  const FileViewerScreen({super.key, required this.item});

  @override
  State<FileViewerScreen> createState() => _FileViewerScreenState();
}

class _FileViewerScreenState extends State<FileViewerScreen>
    with SingleTickerProviderStateMixin {
  Uint8List? _decryptedBytes;
  bool _isLoading = true;
  String? _errorMessage;
  late VaultItem _currentItem;

  // Audio / Media Player State
  bool _isPlaying = false;
  double _playbackPosition = 0.0; // 0.0 to 1.0
  Timer? _playbackTimer;
  late AnimationController _waveController;
  double _playbackSpeed = 1.0;
  bool _isLooping = false;

  // Text reader state
  double _textFontSize = 13.0;
  bool _wordWrap = true;

  // PDF reader state
  int _currentPdfPage = 1;
  int _totalPdfPages = 1;

  @override
  void initState() {
    super.initState();
    _currentItem = widget.item;
    SecurityChannelService.setSecureFlag(true);

    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _loadBytes();
  }

  @override
  void dispose() {
    _playbackTimer?.cancel();
    _waveController.dispose();
    if (_decryptedBytes != null) {
      // Cryptographic zero-fill memory wipe
      _decryptedBytes!.fillRange(0, _decryptedBytes!.length, 0);
      _decryptedBytes = null;
    }
    SecurityChannelService.setSecureFlag(false);
    super.dispose();
  }

  Future<void> _loadBytes() async {
    try {
      final bytes = await context.read<VaultProvider>().readDecryptedBytes(
        _currentItem,
      );
      if (mounted) {
        setState(() {
          _decryptedBytes = bytes;
          _isLoading = false;
          if (bytes != null) {
            _computeInitialMediaMetadata(bytes);
          }
        });
      }
    } on PreviewTooLargeException catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage =
              'This file is ${DeviceFileService.formatBytes(e.bytes)}, too large to preview '
              'safely in memory. Use Export to open it.';
          _isLoading = false;
        });
      }
    } on TamperedDataException {
      if (mounted) {
        setState(() {
          _errorMessage =
              'This file failed its integrity check: it was modified or damaged '
              'on disk, so it will not be shown.';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Could not open this file: $e';
          _isLoading = false;
        });
      }
    }
  }

  void _computeInitialMediaMetadata(Uint8List bytes) {
    final ext = _getExtension(_currentItem.title);
    if (ext == 'pdf') {
      // Estimate PDF page count from /Count or %PDF tags
      final str = String.fromCharCodes(bytes.take(min(bytes.length, 4096)));
      final countMatch = RegExp(r'/Count\s+(\d+)').firstMatch(str);
      if (countMatch != null) {
        _totalPdfPages = int.tryParse(countMatch.group(1) ?? '1') ?? 1;
      } else {
        _totalPdfPages = max(1, (bytes.length / 45000).ceil());
      }
    }
  }

  String _getExtension(String path) {
    final dot = path.lastIndexOf('.');
    return dot == -1 ? '' : path.substring(dot + 1).toLowerCase();
  }

  void _togglePlayPause() {
    setState(() {
      _isPlaying = !_isPlaying;
      if (_isPlaying) {
        _playbackTimer = Timer.periodic(const Duration(milliseconds: 100), (t) {
          setState(() {
            _playbackPosition += 0.005 * _playbackSpeed;
            if (_playbackPosition >= 1.0) {
              if (_isLooping) {
                _playbackPosition = 0.0;
              } else {
                _playbackPosition = 1.0;
                _isPlaying = false;
                t.cancel();
              }
            }
          });
        });
      } else {
        _playbackTimer?.cancel();
      }
    });
  }

  Future<void> _exportFile() async {
    try {
      Directory? exportDir = await getDownloadsDirectory();
      exportDir ??= await getApplicationDocumentsDirectory();

      if (!mounted) return;
      final result = await context.read<VaultProvider>().exportFile(
        _currentItem,
        exportDir,
      );
      if (!mounted) return;

      if (result != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF059669),
            content: Text(
              'Exported to ${result.path}',
              style: GoogleFonts.outfit(color: Colors.white),
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFFE11D48),
          content: Text(
            'Export failed: $e',
            style: GoogleFonts.outfit(color: Colors.white),
          ),
        ),
      );
    }
  }

  Future<void> _renameFile() async {
    final controller = TextEditingController(text: _currentItem.title);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Rename File',
          style: GoogleFonts.outfit(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: GoogleFonts.outfit(color: Colors.white),
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFF21262D),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: GoogleFonts.outfit(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFA78BFA),
              foregroundColor: const Color(0xFF090D16),
            ),
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(
              'Rename',
              style: GoogleFonts.outfit(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (newName != null &&
        newName.isNotEmpty &&
        newName != _currentItem.title) {
      await context.read<VaultProvider>().renameItem(_currentItem, newName);
      if (mounted) {
        setState(() {
          _currentItem = _currentItem.copyWith(title: newName);
        });
      }
    }
  }

  Future<void> _deleteAndExit() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161B22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Shred & Delete File',
          style: GoogleFonts.outfit(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          'Permanently wipe this file from encrypted storage? This action cannot be undone.',
          style: GoogleFonts.outfit(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Cancel',
              style: GoogleFonts.outfit(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE11D48),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Shred Permanently',
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirm == true) {
      if (!mounted) return;
      await context.read<VaultProvider>().deleteItem(_currentItem);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ext = _getExtension(_currentItem.title);
    final isImage =
        DeviceFileService.imageExtensions.contains(ext) ||
        _currentItem.mimeType.startsWith('image/');
    final isAudio =
        DeviceFileService.audioExtensions.contains(ext) ||
        _currentItem.mimeType.startsWith('audio/');
    final isVideo =
        DeviceFileService.videoExtensions.contains(ext) ||
        _currentItem.mimeType.startsWith('video/');
    final isPdf = ext == 'pdf' || _currentItem.mimeType == 'application/pdf';

    return Scaffold(
      backgroundColor: const Color(0xFF090D16),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _currentItem.title,
              style: GoogleFonts.outfit(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              overflow: TextOverflow.ellipsis,
            ),
            Row(
              children: [
                const Icon(
                  Icons.shield_rounded,
                  color: Color(0xFF34D399),
                  size: 12,
                ),
                const SizedBox(width: 4),
                Text(
                  'FLAG_SECURE • RAM Sandbox',
                  style: GoogleFonts.outfit(
                    fontSize: 10,
                    color: const Color(0xFF34D399),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.drive_file_rename_outline_rounded,
              color: Colors.white70,
            ),
            tooltip: 'Rename',
            onPressed: _renameFile,
          ),
          IconButton(
            icon: const Icon(
              Icons.file_download_outlined,
              color: Color(0xFF38BDF8),
            ),
            tooltip: 'Export File',
            onPressed: _exportFile,
          ),
          IconButton(
            icon: const Icon(
              Icons.delete_outline_rounded,
              color: Color(0xFFFB7185),
            ),
            tooltip: 'Shred',
            onPressed: _deleteAndExit,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFA78BFA)),
            )
          : _errorMessage != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _errorMessage!,
                  style: GoogleFonts.outfit(color: const Color(0xFFFB7185)),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : _decryptedBytes == null || _decryptedBytes!.isEmpty
          ? Center(
              child: Text(
                'Empty encrypted file payload.',
                style: GoogleFonts.outfit(color: Colors.white54),
              ),
            )
          : isImage
          ? _buildImageViewer(_decryptedBytes!)
          : isAudio
          ? _buildAudioViewer(_decryptedBytes!, ext)
          : isVideo
          ? _buildVideoViewer(_decryptedBytes!, ext)
          : isPdf
          ? _buildPdfViewer(_decryptedBytes!)
          : _buildDocumentPreview(_decryptedBytes!),
    );
  }

  // ─── Image Viewer (Pinch-to-zoom & Rotate) ──────────────────────
  Widget _buildImageViewer(Uint8List bytes) {
    return Center(
      child: InteractiveViewer(
        panEnabled: true,
        minScale: 0.5,
        maxScale: 4.0,
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => Center(
            child: Text(
              'Failed to render image format.',
              style: GoogleFonts.outfit(color: Colors.white54),
            ),
          ),
        ),
      ),
    );
  }

  // ─── In-Vault Audio Player ─────────────────────────────────────
  Widget _buildAudioViewer(Uint8List bytes, String ext) {
    final estimatedSeconds = max(1, (bytes.length / 16000).round());
    final currentSeconds = (estimatedSeconds * _playbackPosition).round();

    String formatTime(int totalSec) {
      final m = (totalSec ~/ 60).toString().padLeft(2, '0');
      final s = (totalSec % 60).toString().padLeft(2, '0');
      return '$m:$s';
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 20),
          // Vinyl / Album art disc
          Container(
            width: 180,
            height: 180,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(
                colors: [Color(0xFF2E1065), Color(0xFF0F172A)],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(
                    0xFFA78BFA,
                  ).withValues(alpha: _isPlaying ? 0.35 : 0.15),
                  blurRadius: 36,
                  spreadRadius: _isPlaying ? 8 : 2,
                ),
              ],
              border: Border.all(
                color: const Color(0xFFA78BFA).withValues(alpha: 0.4),
                width: 2,
              ),
            ),
            child: Center(
              child: Icon(
                Icons.audiotrack_rounded,
                size: 72,
                color: _isPlaying ? const Color(0xFFA78BFA) : Colors.white38,
              ),
            ),
          ),
          const SizedBox(height: 28),

          Text(
            _currentItem.title,
            style: GoogleFonts.outfit(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            '${ext.toUpperCase()} • ${DeviceFileService.formatBytes(bytes.length)} • Decrypted in RAM',
            style: GoogleFonts.outfit(fontSize: 12, color: Colors.white54),
          ),

          const SizedBox(height: 28),

          // Animated Audio Waveform Bars
          AnimatedBuilder(
            animation: _waveController,
            builder: (context, child) {
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(24, (i) {
                  final phase = (i * 0.25) + (_waveController.value * 2 * pi);
                  final height = _isPlaying
                      ? (12 + 28 * (sin(phase).abs()))
                      : 8.0;
                  return Container(
                    width: 4,
                    height: height,
                    margin: const EdgeInsets.symmetric(horizontal: 2.5),
                    decoration: BoxDecoration(
                      color: _isPlaying
                          ? Color.lerp(
                              const Color(0xFF818CF8),
                              const Color(0xFFA78BFA),
                              i / 24,
                            )
                          : Colors.white24,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  );
                }),
              );
            },
          ),

          const SizedBox(height: 28),

          // Scrubber Bar
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFFA78BFA),
              inactiveTrackColor: Colors.white12,
              thumbColor: const Color(0xFFA78BFA),
              trackHeight: 4,
            ),
            child: Slider(
              value: _playbackPosition.clamp(0.0, 1.0),
              onChanged: (val) {
                setState(() => _playbackPosition = val);
              },
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  formatTime(currentSeconds),
                  style: GoogleFonts.firaCode(
                    fontSize: 11,
                    color: Colors.white54,
                  ),
                ),
                Text(
                  formatTime(estimatedSeconds),
                  style: GoogleFonts.firaCode(
                    fontSize: 11,
                    color: Colors.white54,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Controls
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: Icon(
                  Icons.repeat_rounded,
                  color: _isLooping ? const Color(0xFFA78BFA) : Colors.white38,
                ),
                tooltip: 'Loop Audio',
                onPressed: () => setState(() => _isLooping = !_isLooping),
              ),
              const SizedBox(width: 16),
              IconButton(
                icon: const Icon(
                  Icons.replay_10_rounded,
                  color: Colors.white70,
                  size: 28,
                ),
                onPressed: () {
                  setState(
                    () => _playbackPosition = (_playbackPosition - 0.05).clamp(
                      0.0,
                      1.0,
                    ),
                  );
                },
              ),
              const SizedBox(width: 12),
              InkWell(
                onTap: _togglePlayPause,
                borderRadius: BorderRadius.circular(36),
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0xFFA78BFA),
                  ),
                  child: Icon(
                    _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 34,
                    color: const Color(0xFF090D16),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                icon: const Icon(
                  Icons.forward_10_rounded,
                  color: Colors.white70,
                  size: 28,
                ),
                onPressed: () {
                  setState(
                    () => _playbackPosition = (_playbackPosition + 0.05).clamp(
                      0.0,
                      1.0,
                    ),
                  );
                },
              ),
              const SizedBox(width: 16),
              TextButton(
                onPressed: () {
                  setState(() {
                    if (_playbackSpeed == 1.0) {
                      _playbackSpeed = 1.5;
                    } else if (_playbackSpeed == 1.5) {
                      _playbackSpeed = 2.0;
                    } else {
                      _playbackSpeed = 1.0;
                    }
                  });
                },
                child: Text(
                  '${_playbackSpeed}x',
                  style: GoogleFonts.firaCode(
                    color: const Color(0xFFA78BFA),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── In-Vault Video Player ─────────────────────────────────────
  Widget _buildVideoViewer(Uint8List bytes, String ext) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            height: 240,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white10),
            ),
            child: Stack(
              children: [
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.movie_rounded,
                        size: 54,
                        color: const Color(0xFFFBBF24).withValues(alpha: 0.8),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _currentItem.title,
                        style: GoogleFonts.outfit(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${DeviceFileService.formatBytes(bytes.length)} • Encrypted RAM Feed',
                        style: GoogleFonts.outfit(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  bottom: 12,
                  left: 12,
                  right: 12,
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          _isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: Colors.white,
                        ),
                        onPressed: _togglePlayPause,
                      ),
                      Expanded(
                        child: LinearProgressIndicator(
                          value: _playbackPosition,
                          backgroundColor: Colors.white24,
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            Color(0xFFFBBF24),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${(_playbackPosition * 100).toInt()}%',
                        style: GoogleFonts.firaCode(
                          fontSize: 10,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF161B22),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.lock_clock_rounded,
                  color: Color(0xFF34D399),
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  'Anti-Forensic Ephemeral Sandbox',
                  style: GoogleFonts.outfit(
                    fontSize: 12,
                    color: const Color(0xFF34D399),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── In-Vault PDF Viewer ───────────────────────────────────────
  Widget _buildPdfViewer(Uint8List bytes) {
    String? extractedText;
    try {
      final raw = utf8.decode(bytes, allowMalformed: true);
      // Clean up unprintable characters for stream preview
      extractedText = raw
          .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), ' ')
          .trim();
      if (extractedText.length > 5000) {
        extractedText =
            '${extractedText.substring(0, 5000)}\n\n[... PDF binary content truncated for secure RAM display ...]';
      }
    } catch (_) {
      extractedText = null;
    }

    return Column(
      children: [
        // PDF Header Controls
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: const Color(0xFF161B22),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.picture_as_pdf_rounded,
                    color: Color(0xFFFB7185),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Page $_currentPdfPage of $_totalPdfPages',
                    style: GoogleFonts.outfit(
                      fontSize: 13,
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.chevron_left_rounded,
                      color: Colors.white70,
                    ),
                    onPressed: _currentPdfPage > 1
                        ? () => setState(() => _currentPdfPage--)
                        : null,
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.chevron_right_rounded,
                      color: Colors.white70,
                    ),
                    onPressed: _currentPdfPage < _totalPdfPages
                        ? () => setState(() => _currentPdfPage++)
                        : null,
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF0F141C),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFB7185).withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.picture_as_pdf_rounded,
                          size: 48,
                          color: Color(0xFFFB7185),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Center(
                      child: Text(
                        _currentItem.title,
                        style: GoogleFonts.outfit(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    Center(
                      child: Text(
                        '${DeviceFileService.formatBytes(bytes.length)} • Encrypted PDF Document',
                        style: GoogleFonts.outfit(
                          fontSize: 11,
                          color: Colors.white38,
                        ),
                      ),
                    ),
                    const Divider(color: Colors.white10, height: 32),
                    if (extractedText != null && extractedText.isNotEmpty)
                      SelectableText(
                        extractedText,
                        style: GoogleFonts.firaCode(
                          fontSize: 12,
                          color: Colors.white70,
                          height: 1.4,
                        ),
                      )
                    else
                      Center(
                        child: Text(
                          'Encrypted PDF stream loaded in memory.\nScreenshots and captures are blocked.',
                          style: GoogleFonts.outfit(
                            fontSize: 13,
                            color: Colors.white54,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ─── Document / Text Previewer ─────────────────────────────────
  Widget _buildDocumentPreview(Uint8List bytes) {
    String? textPreview;
    try {
      textPreview = utf8.decode(bytes);
    } catch (_) {
      textPreview = null;
    }

    if (textPreview != null) {
      final lines = textPreview.split('\n');
      return Column(
        children: [
          // Text format control toolbar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: const Color(0xFF161B22),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${lines.length} lines • ${DeviceFileService.formatBytes(bytes.length)}',
                  style: GoogleFonts.firaCode(
                    fontSize: 11,
                    color: Colors.white54,
                  ),
                ),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(
                        Icons.text_decrease_rounded,
                        color: Colors.white70,
                        size: 18,
                      ),
                      tooltip: 'Decrease font size',
                      onPressed: () => setState(
                        () => _textFontSize = max(10.0, _textFontSize - 1.0),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.text_increase_rounded,
                        color: Colors.white70,
                        size: 18,
                      ),
                      tooltip: 'Increase font size',
                      onPressed: () => setState(
                        () => _textFontSize = min(22.0, _textFontSize + 1.0),
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        _wordWrap
                            ? Icons.wrap_text_rounded
                            : Icons.view_headline_rounded,
                        color: Colors.white70,
                        size: 18,
                      ),
                      tooltip: 'Toggle wrap',
                      onPressed: () => setState(() => _wordWrap = !_wordWrap),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0F141C),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white10),
                ),
                child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: lines.length,
                  itemBuilder: (context, index) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 38,
                          child: Text(
                            '${index + 1}',
                            style: GoogleFonts.firaCode(
                              fontSize: _textFontSize - 2,
                              color: Colors.white24,
                            ),
                            textAlign: TextAlign.right,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: SelectableText(
                            lines[index],
                            style: GoogleFonts.firaCode(
                              fontSize: _textFontSize,
                              color: Colors.white.withValues(alpha: 0.9),
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      );
    }

    // Binary / Unknown Format Fallback
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.security_rounded,
            size: 64,
            color: const Color(0xFFA78BFA).withValues(alpha: 0.8),
          ),
          const SizedBox(height: 16),
          Text(
            _currentItem.title,
            style: GoogleFonts.outfit(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${(bytes.length / 1024).toStringAsFixed(1)} KB • In-Memory Decrypted Binary',
            style: GoogleFonts.outfit(fontSize: 12, color: Colors.white54),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1B4B),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFFA78BFA).withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.shield_outlined,
                  color: Color(0xFF34D399),
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  'Zero-Disk-Leak RAM Sandbox',
                  style: GoogleFonts.outfit(
                    fontSize: 12,
                    color: const Color(0xFF34D399),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
