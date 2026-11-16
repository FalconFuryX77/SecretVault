import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/vault_item.dart';
import '../providers/vault_provider.dart';
import '../util/format.dart';
import '../theme/app_fonts.dart';
import '../vault/crypto_primitives.dart';
import '../viewers/document_view.dart';
import '../viewers/file_kind.dart';
import '../viewers/image_view.dart';
import '../viewers/office_view.dart';
import '../viewers/media_player_view.dart';
import '../viewers/pdf_view.dart';
import '../viewers/text_file_view.dart';
import 'export_dialog.dart';
import '../theme/ui.dart';

/// Opens a vault file inside the app: no other app is ever involved, and
/// nothing decrypted is written to storage.
///
/// * images, Word documents and text are decrypted into memory;
/// * video and audio play from a private in-memory stream, so they don't
///   need to fit in memory and start immediately;
/// * PDFs are drawn by an isolated process that can't reach the vault.
class FileViewerScreen extends StatefulWidget {
  final VaultItem item;

  const FileViewerScreen({super.key, required this.item});

  @override
  State<FileViewerScreen> createState() => _FileViewerScreenState();
}

class _FileViewerScreenState extends State<FileViewerScreen> {
  Uint8List? _decryptedBytes;
  bool _isLoading = true;
  String? _errorMessage;
  late VaultItem _currentItem;
  late final ViewerKind _kind;

  bool get _streams => _kind == ViewerKind.video || _kind == ViewerKind.audio;

  @override
  void initState() {
    super.initState();
    _currentItem = widget.item;
    _kind = viewerKindFor(_currentItem.title, _currentItem.mimeType);
    if (_streams) {
      _isLoading = false;
    } else {
      _loadBytes();
    }
  }

  @override
  void dispose() {
    final bytes = _decryptedBytes;
    if (bytes != null) {
      // The decoded picture lives in Flutter's image cache, not in [bytes].
      if (_kind == ViewerKind.image) MemoryImage(bytes).evict();
      // Best effort: Dart may have made copies, but this one is cleared.
      bytes.fillRange(0, bytes.length, 0);
      _decryptedBytes = null;
    }
    super.dispose();
  }

  Future<void> _loadBytes() async {
    try {
      final bytes = await context.read<VaultProvider>().readDecryptedBytes(_currentItem);
      if (mounted) {
        setState(() {
          _decryptedBytes = bytes;
          _isLoading = false;
        });
      }
    } on PreviewTooLargeException catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage =
              'This file is ${formatBytes(e.bytes)}, too large to open '
              'in memory on this phone.';
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

  Future<void> _exportFile() => exportWithConfirmation(context, _currentItem);

  Future<void> _renameFile() async {
    final controller = TextEditingController(text: _currentItem.title);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Ui.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Rename File',
          style: AppFonts.ui(
            color: Ui.ink,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: TextField(
          enableIMEPersonalizedLearning: false, // keep vault text out of keyboard learning
          controller: controller,
          autofocus: true,
          style: AppFonts.ui(color: Ui.ink),
          decoration: InputDecoration(
            filled: true,
            fillColor: Ui.raised,
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
              style: AppFonts.ui(color: Ui.ink2),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Ui.signal,
              foregroundColor: Ui.canvas,
            ),
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(
              'Rename',
              style: AppFonts.ui(fontWeight: FontWeight.bold),
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
    if (!await confirmShred(context, _currentItem.title) || !mounted) return;
    await context.read<VaultProvider>().deleteItem(_currentItem);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ui.canvas,
      appBar: AppBar(
        backgroundColor: Ui.surface,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _currentItem.title,
              style: AppFonts.ui(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Ui.ink,
              ),
              overflow: TextOverflow.ellipsis,
            ),
            Row(
              children: [
                const Icon(
                  Icons.shield_rounded,
                  color: Ui.ink,
                  size: 12,
                ),
                const SizedBox(width: 4),
                // Flexible + ellipsis: the title bar is narrow once the
                // action buttons take their space (overflowed on a 1080p phone).
                Flexible(
                  child: Text(
                    'Protected view · no screenshots',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.ui(
                      fontSize: 10,
                      color: Ui.ink,
                      fontWeight: FontWeight.w600,
                    ),
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
              color: Ui.ink2,
            ),
            tooltip: 'Rename',
            onPressed: _renameFile,
          ),
          IconButton(
            icon: const Icon(
              Icons.file_download_outlined,
              color: Ui.ink2,
            ),
            tooltip: 'Export File',
            onPressed: _exportFile,
          ),
          IconButton(
            icon: const Icon(
              Icons.delete_outline_rounded,
              color: Ui.alert,
            ),
            tooltip: 'Shred',
            onPressed: _deleteAndExit,
          ),
        ],
      ),
      // Keep pages and controls above the system navigation bar (the app
      // draws edge to edge on recent Android versions).
      body: SafeArea(top: false, child: _body()),
    );
  }

  Widget _body() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: Ui.signal));
    }
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _errorMessage!,
            style: AppFonts.ui(color: Ui.alert),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_streams) {
      return MediaPlayerView(item: _currentItem, isVideo: _kind == ViewerKind.video);
    }
    final bytes = _decryptedBytes;
    if (bytes == null || bytes.isEmpty) {
      return Center(
        child: Text('This file is empty.', style: AppFonts.ui(color: Ui.ink2)),
      );
    }
    switch (_kind) {
      case ViewerKind.image:
        return _buildImageViewer(bytes);
      case ViewerKind.pdf:
        return PdfView(bytes: bytes);
      case ViewerKind.word:
        return DocumentView(bytes: bytes);
      case ViewerKind.office:
        return OfficeView(title: _currentItem.title, bytes: bytes);
      case ViewerKind.text:
      case ViewerKind.other:
        // Unknown types that turn out to be text open as text too.
        final text = bytes.length <= 8 * 1024 * 1024 ? TextFileView.decode(bytes) : null;
        if (text != null) {
          return TextFileView(
            item: _currentItem,
            text: text,
            onSaved: (item) => setState(() => _currentItem = item),
          );
        }
        return _noPreview(bytes);
      case ViewerKind.video:
      case ViewerKind.audio:
        return const SizedBox.shrink(); // handled above
    }
  }

  // ─── Image Viewer (Pinch-to-zoom & Rotate) ──────────────────────
  Widget _buildImageViewer(Uint8List bytes) => VaultImageView(bytes: bytes);

  Widget _noPreview(Uint8List bytes) {
    final ext = extensionOf(_currentItem.title);
    final why = switch (ext) {
      'xls' || 'ppt' => "Older Excel and PowerPoint files (.xls, .ppt) can't be shown yet. "
          'Saved as .xlsx or .pptx, they can.',
      _ => 'There is no viewer for this kind of file yet.',
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insert_drive_file_outlined, size: 56, color: Ui.signal.withValues(alpha: 0.8)),
            const SizedBox(height: 16),
            Text(
              _currentItem.title,
              textAlign: TextAlign.center,
              style: AppFonts.ui(fontSize: 16, fontWeight: FontWeight.bold, color: Ui.ink),
            ),
            const SizedBox(height: 6),
            Text(
              '${formatBytes(bytes.length)} · stored encrypted',
              style: AppFonts.ui(fontSize: 12, color: Ui.ink2),
            ),
            const SizedBox(height: 16),
            Text(
              why,
              key: const Key('no-preview'),
              textAlign: TextAlign.center,
              style: AppFonts.ui(fontSize: 13, color: Ui.ink2),
            ),
          ],
        ),
      ),
    );
  }
}
