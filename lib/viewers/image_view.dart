import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_fonts.dart';
import 'pdf_sandbox.dart';
import '../theme/ui.dart';

/// Decodes vault images in the isolated renderer process (the one that
/// draws PDFs, see PdfRenderService.kt) rather than in the app, which holds
/// the vault's keys: a booby-trapped image that exploits a decoder gets a
/// process with no permissions, no files and no keys.
class ImageSandbox {
  static const MethodChannel _channel = MethodChannel('app.vault/pdf');

  /// Largest decoded image: big enough to zoom into a 12-megapixel photo,
  /// small enough not to exhaust memory. Larger images are scaled down.
  static const int maxSide = 4096;
  static const int maxPixels = 12000000;

  /// Decodes [data] (the caller wipes its copy) into an image. Throws
  /// [PdfSandboxException] (`unsupported` before Android 11).
  static Future<ui.Image> decode(Uint8List data) async {
    if (!PdfSandbox.isAvailable) throw PdfSandboxException(PdfProblem.unsupported);
    final Map<String, Object?> m;
    try {
      m = (await _channel.invokeMapMethod<String, Object?>(
        'image',
        {'data': data, 'maxSide': maxSide, 'maxPixels': maxPixels},
      ))!;
    } on PlatformException catch (e) {
      throw PdfSandboxException(
        PdfProblem.values.firstWhere((p) => p.name == e.code, orElse: () => PdfProblem.failed),
        e.message,
      );
    }
    final w = (m['width'] as num).toInt();
    final h = (m['height'] as num).toInt();
    final rgba = m['data'] as Uint8List;
    if (rgba.length < w * h * 4) throw PdfSandboxException(PdfProblem.broken, 'short pixel data');
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, done.complete);
    return done.future;
  }
}

/// A zoomable vault image, decoded in the sandbox. On phones older than
/// Android 11 (no in-memory files for the sandbox) it falls back to
/// Flutter's own decoder in the app process.
class VaultImageView extends StatefulWidget {
  final Uint8List bytes;
  const VaultImageView({super.key, required this.bytes});

  @override
  State<VaultImageView> createState() => _VaultImageViewState();
}

class _VaultImageViewState extends State<VaultImageView> {
  ui.Image? _image;
  bool _inProcess = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    try {
      final img = await ImageSandbox.decode(widget.bytes);
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() => _image = img);
    } on PdfSandboxException catch (e) {
      if (!mounted) return;
      setState(() {
        switch (e.problem) {
          case PdfProblem.unsupported:
            _inProcess = true;
          case PdfProblem.crashed:
            _error = 'The image decoder stopped while reading this file. It may be damaged, or made to attack '
                'image viewers; it was opened in an isolated process, so nothing else was exposed.';
          default:
            _error = "This image couldn't be decoded.";
        }
      });
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, key: const Key('image-error'), textAlign: TextAlign.center,
              style: AppFonts.ui(color: Colors.white54)),
        ),
      );
    }
    final Widget picture;
    if (_inProcess) {
      picture = Image.memory(
        widget.bytes,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) => Center(
          child: Text('Failed to render image format.', style: AppFonts.ui(color: Colors.white54)),
        ),
      );
    } else if (_image != null) {
      picture = RawImage(key: const Key('image-sandboxed'), image: _image, fit: BoxFit.contain);
    } else {
      return const Center(child: CircularProgressIndicator(color: Ui.signal));
    }
    return Center(
      child: InteractiveViewer(panEnabled: true, minScale: 0.5, maxScale: 6.0, child: picture),
    );
  }
}
