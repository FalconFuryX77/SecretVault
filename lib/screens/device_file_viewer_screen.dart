import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../theme/app_fonts.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import '../services/device_file_service.dart';

/// Viewer for ordinary device files (the cover file manager).
class DeviceFileViewerScreen extends StatefulWidget {
  final File file;

  const DeviceFileViewerScreen({super.key, required this.file});

  @override
  State<DeviceFileViewerScreen> createState() => _DeviceFileViewerScreenState();
}

class _DeviceFileViewerScreenState extends State<DeviceFileViewerScreen> {
  late File _currentFile;
  String? _textContent;
  bool _isLoading = true;
  int _fileSize = 0;
  DateTime? _modifiedDate;

  @override
  void initState() {
    super.initState();
    _currentFile = widget.file;
    _loadFile();
  }

  Future<void> _loadFile() async {
    try {
      final stat = await _currentFile.stat();
      _fileSize = stat.size;
      _modifiedDate = stat.modified;

      final ext = p
          .extension(_currentFile.path)
          .replaceAll('.', '')
          .toLowerCase();
      final isText = {
        'txt',
        'csv',
        'json',
        'md',
        'xml',
        'dart',
        'html',
        'js',
        'log',
        'yaml',
        'yml',
      }.contains(ext);

      if (isText && _fileSize < 1024 * 1024) {
        // Read text if under 1MB
        final bytes = await _currentFile.readAsBytes();
        _textContent = utf8.decode(bytes, allowMalformed: true);
      }
    } catch (_) {}

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _openWithSystem() async {
    try {
      await OpenFilex.open(_currentFile.path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not open file: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final fileName = p.basename(_currentFile.path);
    final ext = p
        .extension(_currentFile.path)
        .replaceAll('.', '')
        .toLowerCase();
    final isImage = DeviceFileService.imageExtensions.contains(ext);

    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        elevation: 0,
        title: Text(
          fileName,
          style: AppFonts.outfit(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_new_rounded, color: Colors.white70),
            tooltip: 'Open in System App',
            onPressed: _openWithSystem,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF58A6FF)),
            )
          : isImage
          ? Center(
              child: InteractiveViewer(
                panEnabled: true,
                minScale: 0.5,
                maxScale: 4.0,
                child: Image.file(
                  _currentFile,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) => Center(
                    child: Text(
                      'Could not render image.',
                      style: AppFonts.outfit(color: Colors.white54),
                    ),
                  ),
                ),
              ),
            )
          : _textContent != null
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: SingleChildScrollView(
                child: SelectableText(
                  _textContent!,
                  style: AppFonts.firaCode(
                    fontSize: 13,
                    color: Colors.white70,
                    height: 1.5,
                  ),
                ),
              ),
            )
          : _buildGenericFileView(fileName),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: const BoxDecoration(
          color: Color(0xFF161B22),
          border: Border(top: BorderSide(color: Colors.white10)),
        ),
        child: SafeArea(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    DeviceFileService.formatBytes(_fileSize),
                    style: AppFonts.outfit(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  if (_modifiedDate != null)
                    Text(
                      'Modified: ${_modifiedDate!.day}/${_modifiedDate!.month}/${_modifiedDate!.year}',
                      style: AppFonts.outfit(
                        fontSize: 11,
                        color: Colors.white54,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGenericFileView(String fileName) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF21262D),
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Icon(
              Icons.insert_drive_file_rounded,
              size: 64,
              color: Color(0xFF58A6FF),
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              fileName,
              textAlign: TextAlign.center,
              style: AppFonts.outfit(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            DeviceFileService.formatBytes(_fileSize),
            style: AppFonts.outfit(fontSize: 13, color: Colors.white54),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF21262D),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: _openWithSystem,
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: Text(
              'Open with External App',
              style: AppFonts.outfit(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
