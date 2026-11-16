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

  /// Asking for the PDF's password (kept only while it's open).
  bool _needPassword = false;
  bool _wrongPassword = false;
  final TextEditingController _password = TextEditingController();

  bool _searching = false;
  final TextEditingController _query = TextEditingController();
  List<PdfMatch> _matches = const [];
  int _match = -1;
  String? _searchNote;
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

  Future<void> _open({String? password}) async {
    try {
      final pages = await PdfSandbox.open(widget.bytes, password: password);
      if (_disposed) return;
      if (pages.isEmpty) {
        setState(() => _error = 'This PDF has no pages.');
        return;
      }
      _password.clear();
      setState(() {
        _pages = pages;
        _needPassword = false;
      });
    } on PdfSandboxException catch (e) {
      if (_disposed) return;
      if (e.problem == PdfProblem.password) {
        setState(() {
          _wrongPassword = password != null;
          _needPassword = true;
        });
        return;
      }
      if (e.problem == PdfProblem.unsupported && password != null) {
        setState(() => _error = 'Opening password-protected PDFs needs Android 15 or newer.');
        return;
      }
      setState(() => _error = _describe(e.problem));
    }
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    try {
      final found = await PdfSandbox.search(q);
      if (_disposed) return;
      setState(() {
        _matches = found;
        _match = found.isEmpty ? -1 : 0;
        _searchNote = found.isEmpty ? 'No matches' : null;
      });
      if (found.isNotEmpty) _goTo(0);
    } on PdfSandboxException catch (e) {
      if (_disposed) return;
      setState(() {
        _matches = const [];
        _match = -1;
        _searchNote = e.problem == PdfProblem.unsupported ? 'Search needs Android 15 or newer.' : "Search didn't work.";
      });
    }
  }

  void _goTo(int index) {
    if (_matches.isEmpty) return;
    final i = index % _matches.length;
    setState(() => _match = i < 0 ? i + _matches.length : i);
    final page = _matches[_match].page;
    var y = _gap;
    for (var k = 0; k < page; k++) {
      y += _heightOf(k) + _gap;
    }
    if (_scroll.hasClients) {
      _scroll.animateTo(min(y, _scroll.position.maxScrollExtent),
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  static String _describe(PdfProblem p) => switch (p) {
        PdfProblem.unsupported => Platform.isAndroid
            ? 'PDF viewing needs Android 11 or newer.'
            : 'PDF viewing is available on Android.',
        PdfProblem.password => 'This PDF is password-protected.',
        PdfProblem.broken => 'This PDF could not be read. It may be damaged.',
        PdfProblem.crashed => 'This PDF crashed the isolated renderer. It may be damaged or deliberately '
            'malformed. It was kept away from your vault.',
        PdfProblem.failed => 'This PDF could not be opened.',
      };

  @override
  void dispose() {
    _disposed = true;
    _scroll.dispose();
    _password.dispose();
    _query.dispose();
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
    if (_needPassword) return _passwordPrompt();
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
              if (!_searching)
                Text('Double-tap to zoom', style: AppFonts.outfit(fontSize: 11, color: Colors.white38)),
              IconButton(
                key: const Key('pdf-search-toggle'),
                visualDensity: VisualDensity.compact,
                icon: Icon(_searching ? Icons.close_rounded : Icons.search_rounded, color: Colors.white70, size: 20),
                onPressed: () => setState(() {
                  _searching = !_searching;
                  if (!_searching) {
                    _matches = const [];
                    _match = -1;
                    _searchNote = null;
                  }
                }),
              ),
            ],
          ),
        ),
        if (_searching)
          Container(
            color: const Color(0xFF161B22),
            padding: const EdgeInsets.fromLTRB(12, 0, 4, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('pdf-search-field'),
                    controller: _query,
                    autofocus: true,
                    enableIMEPersonalizedLearning: false,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    style: AppFonts.outfit(fontSize: 14, color: Colors.white),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Find in document',
                      hintStyle: AppFonts.outfit(fontSize: 14, color: Colors.white38),
                      border: InputBorder.none,
                    ),
                  ),
                ),
                Text(
                  _searchNote ?? (_matches.isEmpty ? '' : '${_match + 1} of ${_matches.length}'),
                  key: const Key('pdf-search-count'),
                  style: AppFonts.outfit(fontSize: 12, color: Colors.white54),
                ),
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_up_rounded, color: Colors.white70),
                  onPressed: _matches.isEmpty ? null : () => _goTo(_match - 1),
                ),
                IconButton(
                  key: const Key('pdf-search-next'),
                  icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white70),
                  onPressed: _matches.isEmpty ? null : () => _goTo(_match + 1),
                ),
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
            : Stack(
                children: [
                  RawImage(key: Key('pdf-image-$i'), image: image, fit: BoxFit.fill, width: _pageWidth, height: _heightOf(i)),
                  ..._highlights(i),
                ],
              ),
      ),
    );
  }

  /// Search matches on page [i], scaled from points to the page as drawn.
  List<Widget> _highlights(int i) {
    final size = _pages![i];
    final sx = _pageWidth / max(1.0, size.width);
    final sy = _heightOf(i) / max(1.0, size.height);
    return [
      for (var m = 0; m < _matches.length; m++)
        if (_matches[m].page == i)
          for (final r in _matches[m].rects)
            Positioned(
              key: m == _match ? const Key('pdf-match') : null,
              left: r.left * sx,
              top: r.top * sy,
              width: max(2.0, r.width * sx),
              height: max(2.0, r.height * sy),
              child: Container(
                color: (m == _match ? const Color(0xFFF59E0B) : const Color(0xFFFDE047)).withValues(alpha: 0.45),
              ),
            ),
    ];
  }

  Widget _passwordPrompt() => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_rounded, color: _accent, size: 40),
              const SizedBox(height: 12),
              Text('This PDF is password-protected.',
                  textAlign: TextAlign.center, style: AppFonts.outfit(fontSize: 15, color: Colors.white)),
              const SizedBox(height: 16),
              TextField(
                key: const Key('pdf-password'),
                controller: _password,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                onSubmitted: (_) => _open(password: _password.text),
                style: AppFonts.outfit(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Password',
                  errorText: _wrongPassword ? 'That password is not right.' : null,
                  filled: true,
                  fillColor: const Color(0xFF161B22),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                key: const Key('pdf-password-open'),
                onPressed: () => _open(password: _password.text),
                child: const Text('Open'),
              ),
            ],
          ),
        ),
      );

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
