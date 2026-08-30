import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import '../models/vault_item.dart';
import '../providers/vault_provider.dart';

/// Secure In-Memory File Viewer.
/// Renders decrypted images, text documents, and binary metadata directly
/// from volatile RAM memory buffers without leaving cleartext artifacts on disk.
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

  @override
  void initState() {
    super.initState();
    _loadBytes();
  }

  Future<void> _loadBytes() async {
    try {
      final bytes = await context.read<VaultProvider>().readDecryptedBytes(widget.item);
      if (mounted) {
        setState(() {
          _decryptedBytes = bytes;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Decryption error: $e';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isImage = widget.item.mimeType.startsWith('image/') ||
        widget.item.title.endsWith('.png') ||
        widget.item.title.endsWith('.jpg') ||
        widget.item.title.endsWith('.jpeg');

    return Scaffold(
      backgroundColor: const Color(0xFF090D16),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        title: Text(
          widget.item.title,
          style: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFFB7185)),
            onPressed: () async {
              await context.read<VaultProvider>().deleteItem(widget.item);
              if (mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFA78BFA)))
          : _errorMessage != null
              ? Center(
                  child: Text(
                    _errorMessage!,
                    style: GoogleFonts.outfit(color: const Color(0xFFFB7185)),
                  ),
                )
              : _decryptedBytes == null || _decryptedBytes!.isEmpty
                  ? Center(
                      child: Text(
                        'Empty or missing encrypted file data.',
                        style: GoogleFonts.outfit(color: Colors.white54),
                      ),
                    )
                  : isImage
                      ? Center(
                          child: InteractiveViewer(
                            panEnabled: true,
                            minScale: 0.5,
                            maxScale: 4.0,
                            child: Image.memory(
                              _decryptedBytes!,
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => Center(
                                child: Text('Failed to render image format.', style: GoogleFonts.outfit(color: Colors.white54)),
                              ),
                            ),
                          ),
                        )
                      : _buildDocumentPreview(),
    );
  }

  Widget _buildDocumentPreview() {
    String? textPreview;
    try {
      textPreview = utf8.decode(_decryptedBytes!);
    } catch (_) {
      textPreview = null;
    }

    if (textPreview != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: SelectableText(
            textPreview,
            style: GoogleFonts.firaCode(fontSize: 13, color: Colors.white70, height: 1.5),
          ),
        ),
      );
    }

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.picture_as_pdf_rounded, size: 64, color: const Color(0xFFFB7185).withOpacity(0.8)),
          const SizedBox(height: 16),
          Text(
            widget.item.title,
            style: GoogleFonts.outfit(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(height: 6),
          Text(
            '${(widget.item.fileSizeBytes / 1024).toStringAsFixed(1)} KB • In-Memory Decrypted Binary',
            style: GoogleFonts.outfit(fontSize: 12, color: Colors.white54),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1B4B),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFA78BFA).withOpacity(0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.shield_outlined, color: Color(0xFF34D399), size: 16),
                const SizedBox(width: 8),
                Text(
                  'Zero-Disk-Leak RAM Sandbox',
                  style: GoogleFonts.outfit(fontSize: 12, color: const Color(0xFF34D399), fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
