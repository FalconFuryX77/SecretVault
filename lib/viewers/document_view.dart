import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_fonts.dart';
import 'docx_text.dart';
import '../theme/ui.dart';

/// Shows the text of a Word document (see [DocxReader]): headings,
/// paragraphs, lists and tables. Layout, fonts and pictures are not shown.
class DocumentView extends StatefulWidget {
  final Uint8List bytes;
  const DocumentView({super.key, required this.bytes});

  @override
  State<DocumentView> createState() => _DocumentViewState();
}

class _DocumentViewState extends State<DocumentView> {
  List<DocxBlock>? _blocks;
  String? _error;
  double _scale = 1.0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // Parsing a long document takes a moment; keep the UI responsive. A
      // static function is passed, not a closure, so nothing from this
      // screen has to be sent to the background isolate.
      final blocks = await compute(DocxReader.read, widget.bytes);
      if (mounted) setState(() => _blocks = blocks);
    } on DocxException catch (e) {
      if (mounted) {
        setState(() => _error = e.message == 'not a Word document'
            ? 'This is not a Word (.docx) document, or it is damaged.'
            : 'This document could not be read (${e.message}).');
      }
    } catch (e) {
      debugPrint('DocumentView: $e');
      if (mounted) setState(() => _error = 'This document could not be read.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            key: const Key('doc-error'),
            textAlign: TextAlign.center,
            style: AppFonts.ui(color: Ui.alert, fontSize: 14),
          ),
        ),
      );
    }
    final blocks = _blocks;
    if (blocks == null) return const Center(child: CircularProgressIndicator(color: Ui.signal));
    final words = blocks.whereType<DocxParagraph>().fold<int>(
          0,
          (n, p) => n + p.text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length,
        );
    return Column(
      children: [
        Container(
          color: Ui.surface,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Text(
                'Word document · $words words',
                key: const Key('doc-summary'),
                style: AppFonts.ui(fontSize: 12, color: Colors.white54),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Smaller text',
                icon: const Icon(Icons.text_decrease_rounded, color: Colors.white70, size: 18),
                onPressed: () => setState(() => _scale = (_scale - 0.1).clamp(0.7, 2.0)),
              ),
              IconButton(
                tooltip: 'Larger text',
                icon: const Icon(Icons.text_increase_rounded, color: Colors.white70, size: 18),
                onPressed: () => setState(() => _scale = (_scale + 0.1).clamp(0.7, 2.0)),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: const Color(0xFFF8F7F4),
            child: ListView.builder(
              key: const Key('doc-blocks'),
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
              itemCount: blocks.length,
              itemBuilder: (context, i) => _block(blocks[i]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _block(DocxBlock b) => switch (b) {
        DocxParagraph p => _paragraph(p),
        DocxTable t => _table(t),
      };

  Widget _paragraph(DocxParagraph p) {
    const ink = Ui.raised;
    final size = switch (p.heading) {
          1 => 24.0,
          2 => 20.0,
          3 => 17.0,
          0 => 15.0,
          _ => 15.5,
        } *
        _scale;
    final base = AppFonts.ui(
      fontSize: size,
      color: ink,
      height: 1.45,
      fontWeight: p.heading > 0 ? FontWeight.w500 : FontWeight.w400,
    );
    final text = Text.rich(
      TextSpan(
        children: [
          for (final r in p.runs)
            TextSpan(
              text: r.text,
              style: base.copyWith(
                fontWeight: r.bold || p.heading > 0 ? FontWeight.w500 : FontWeight.w400,
                fontStyle: r.italic ? FontStyle.italic : FontStyle.normal,
                decoration: r.underline ? TextDecoration.underline : TextDecoration.none,
                color: r.text == '[picture]' ? Colors.black38 : ink,
              ),
            ),
        ],
      ),
    );
    return Padding(
      padding: EdgeInsets.only(top: p.heading > 0 ? 14 : 0, bottom: 8),
      child: p.listItem
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('•  ', style: base),
                Expanded(child: text),
              ],
            )
          : SelectionArea(child: text),
    );
  }

  Widget _table(DocxTable t) {
    if (t.rows.isEmpty) return const SizedBox.shrink();
    final columns = t.rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder.all(color: Colors.black26),
          children: [
            for (final row in t.rows)
              TableRow(children: [
                for (var c = 0; c < columns; c++)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 260),
                      child: Text(
                        c < row.length ? row[c] : '',
                        style: AppFonts.ui(fontSize: 13.5 * _scale, color: Ui.raised),
                      ),
                    ),
                  ),
              ]),
          ],
        ),
      ),
    );
  }
}
