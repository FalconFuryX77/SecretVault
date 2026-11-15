import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/app_fonts.dart';
import 'pdf_sandbox.dart';

const _accent = Color(0xFFA78BFA);

/// Shows a PDF page by page. Pages are drawn by the isolated renderer
/// ([PdfSandbox]); this side only ever handles pixels.
class PdfView extends StatefulWidget {
  final Uint8List bytes;
  const PdfView({super.key, required this.bytes});

  @override
  State<PdfView> createState() => _PdfViewState();
}

class _PdfViewState extends State<PdfView> {
  static const double _gap = 12;
  static const int _keepRendered = 8;

  List<ui.Size>? _pages;
  String? _error;
  final Map<int, ui.Image> _rendered = {};
  final Set<int> _pending = {};
  final ScrollController _scroll = ScrollController();
  Future<void> _queue = Future.value();
  int _current = 0;
  int _pixelWidth = 0;
  double _pageWidth = 0;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_updateCurrent);
    _open();
  }

  Future<void> _open() async {
    try {
      final pages = await PdfSandbox.open(widget.bytes);
      if (_disposed) return;
      if (pages.isEmpty) {
        setState(() => _error = 'This PDF has no pages.');
        return;
      }
      setState(() => _pages = pages);
    } on PdfSandboxException catch (e) {
      if (_disposed) return;
      setState(() => _error = _describe(e.problem));
    }
  }

  static String _describe(PdfProblem p) => switch (p) {
        PdfProblem.unsupported => Platform.isAndroid
            ? 'PDF viewing needs Android 11 or newer.'
            : 'PDF viewing is available on Android.',
        PdfProblem.password => "This PDF is password-protected. Protected PDFs can't be opened yet.",
        PdfProblem.broken => 'This PDF could not be read. It may be damaged.',
        PdfProblem.crashed => 'This PDF crashed the isolated renderer. It may be damaged or deliberately '
            'malformed. It was kept away from your vault.',
        PdfProblem.failed => 'This PDF could not be opened.',
      };

  @override
  void dispose() {
    _disposed = true;
    _scroll.dispose();
    for (final img in _rendered.values) {
      img.dispose();
    }
    _rendered.clear();
    PdfSandbox.close();
    super.dispose();
  }

  // ─── Geometry ─────────────────────────────────────────────────────

  double _heightOf(int i) {
    final s = _pages![i];
    return _pageWidth * s.height / max(1.0, s.width);
  }

  void _updateCurrent() {
    final pages = _pages;
    if (pages == null || _pageWidth <= 0) return;
    // The page whose top is closest above the middle of the screen.
    final probe = _scroll.offset + (_scroll.position.viewportDimension / 3);
    var y = 0.0;
    var page = 0;
    for (var i = 0; i < pages.length; i++) {
      final h = _heightOf(i) + _gap;
      if (y + h > probe) {
        page = i;
        break;
      }
      y += h;
      page = i;
    }
    if (page != _current) setState(() => _current = page);
  }

  // ─── Rendering ────────────────────────────────────────────────────

  void _request(int i) {
    if (_rendered.containsKey(i) || _pending.contains(i)) return;
    _pending.add(i);
    final width = _pixelWidth;
    _queue = _queue.then((_) async {
      try {
        // Skip pages that were scrolled past while waiting.
        if (_disposed || (i - _current).abs() > 4 || width != _pixelWidth) return;
        final s = _pages![i];
        var w = width;
        var h = (w * s.height / max(1.0, s.width)).round();
        // Very tall pages: stay inside the renderer's limits.
        if (h > 4096) {
          w = (w * 4096 / h).floor();
          h = 4096;
        }
        final image = await PdfSandbox.render(i, max(1, w), max(1, h));
        if (_disposed || width != _pixelWidth) {
          image.dispose();
          return;
        }
        _rendered[i] = image;
        _evict();
        setState(() {});
      } on PdfSandboxException catch (e) {
        if (!_disposed && (e.problem == PdfProblem.crashed || e.problem == PdfProblem.broken)) {
          setState(() => _error = _describe(e.problem));
        }
      } catch (_) {
        // One page failing to draw shouldn't take the viewer down; it stays
        // a placeholder and is retried when scrolled back into view.
      } finally {
        _pending.remove(i);
      }
    });
  }

  void _evict() {
    while (_rendered.length > _keepRendered) {
      final far = _rendered.keys.reduce((a, b) => (a - _current).abs() >= (b - _current).abs() ? a : b);
      _rendered.remove(far)?.dispose();
    }
  }

  void _setWidth(double width, double dpr) {
    final px = (width * dpr).round().clamp(200, 2048);
    if (px == _pixelWidth && width == _pageWidth) return;
    _pageWidth = width;
    if (px != _pixelWidth) {
      _pixelWidth = px;
      for (final img in _rendered.values) {
        img.dispose();
      }
      _rendered.clear();
    }
  }

  // ─── Layout ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            key: const Key('pdf-error'),
            textAlign: TextAlign.center,
            style: AppFonts.outfit(color: const Color(0xFFFB7185), fontSize: 14),
          ),
        ),
      );
    }
    final pages = _pages;
    if (pages == null) return const Center(child: CircularProgressIndicator(color: _accent));
    final dpr = MediaQuery.of(context).devicePixelRatio;
    return Column(
      children: [
        Container(
          width: double.infinity,
          color: const Color(0xFF161B22),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.picture_as_pdf_rounded, color: Color(0xFFFB7185), size: 18),
              const SizedBox(width: 8),
              Text(
                'Page ${_current + 1} of ${pages.length}',
                key: const Key('pdf-page-label'),
                style: AppFonts.outfit(fontSize: 13, color: Colors.white, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              Text('Double-tap to zoom', style: AppFonts.outfit(fontSize: 11, color: Colors.white38)),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              _setWidth(box.maxWidth - 2 * _gap, dpr);
              return ListView.builder(
                key: const Key('pdf-pages'),
                controller: _scroll,
                padding: const EdgeInsets.all(_gap),
                itemCount: pages.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.only(bottom: _gap),
                  child: _page(i),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _page(int i) {
    final image = _rendered[i];
    if (image == null) _request(i);
    return GestureDetector(
      onDoubleTap: () => _zoom(i),
      child: Container(
        key: Key('pdf-page-$i'),
        width: _pageWidth,
        height: _heightOf(i),
        color: Colors.white,
        alignment: Alignment.center,
        child: image == null
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black26),
              )
            : RawImage(key: Key('pdf-image-$i'), image: image, fit: BoxFit.fill, width: _pageWidth, height: _heightOf(i)),
      ),
    );
  }

  void _zoom(int i) {
    final s = _pages![i];
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => _ZoomedPage(page: i, size: s, total: _pages!.length)),
    );
  }
}

/// One page, drawn sharper, with pinch zoom.
class _ZoomedPage extends StatefulWidget {
  final int page;
  final ui.Size size;
  final int total;
  const _ZoomedPage({required this.page, required this.size, required this.total});

  @override
  State<_ZoomedPage> createState() => _ZoomedPageState();
}

class _ZoomedPageState extends State<_ZoomedPage> {
  ui.Image? _image;
  bool _failed = false;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final mq = MediaQuery.of(context);
    // Twice the screen's pixel width, within the renderer's 16 MP limit.
    var w = min(4096, (mq.size.width * mq.devicePixelRatio * 2).round());
    var h = (w * widget.size.height / max(1.0, widget.size.width)).round();
    final scale = min(1.0, min(4096 / max(1, h), sqrt(16 * 1024 * 1024 / max(1, w * h))));
    w = max(1, (w * scale).floor());
    h = max(1, (h * scale).floor());
    PdfSandbox.render(widget.page, w, h).then((img) {
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() => _image = img);
    }, onError: (_) {
      if (mounted) setState(() => _failed = true);
    });
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    return Scaffold(
      backgroundColor: const Color(0xFF090D16),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B22),
        title: Text(
          'Page ${widget.page + 1} of ${widget.total}',
          style: AppFonts.outfit(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
        ),
      ),
      body: _failed
          ? Center(child: Text('This page could not be drawn.', style: AppFonts.outfit(color: Colors.white54)))
          : img == null
              ? const Center(child: CircularProgressIndicator(color: _accent))
              : InteractiveViewer(
                  minScale: 1,
                  maxScale: 6,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: widget.size.width / max(1.0, widget.size.height),
                      child: RawImage(image: img, fit: BoxFit.contain),
                    ),
                  ),
                ),
    );
  }
}
