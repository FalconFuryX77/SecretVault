import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/vault_clipboard.dart';
import '../theme/app_fonts.dart';
import 'file_kind.dart';
import 'office_text.dart';
import '../theme/ui.dart';

const _accent = Ui.signal;

/// What an office file turned into.
sealed class OfficeContent {}

class OfficeLines extends OfficeContent {
  final List<String> lines;
  OfficeLines(this.lines);
}

class OfficeSheets extends OfficeContent {
  final List<Sheet> sheets;
  OfficeSheets(this.sheets);
}

class OfficeSlides extends OfficeContent {
  final List<Slide> slides;
  OfficeSlides(this.slides);
}

/// Parses off the UI thread (big workbooks take a moment).
OfficeContent _parse((String, Uint8List) job) {
  final (ext, bytes) = job;
  return switch (ext) {
    'xlsx' || 'xlsm' => OfficeSheets(XlsxReader.read(bytes)),
    'ods' => OfficeSheets(OdfReader.sheets(bytes)),
    'pptx' || 'ppsx' => OfficeSlides(PptxReader.read(bytes)),
    'odp' => OfficeSlides(OdfReader.slides(bytes)),
    'doc' => OfficeLines(DocReader.read(bytes)),
    'odt' => OfficeLines(OdfReader.text(bytes)),
    _ => throw OfficeException('not an office document'),
  };
}

/// Spreadsheets, slides, old Word and OpenDocument files, read by the
/// plain-Dart readers in [office_text.dart]: values and text, without
/// formatting or pictures. Nothing leaves the vault.
class OfficeView extends StatefulWidget {
  final String title;
  final Uint8List bytes;
  const OfficeView({super.key, required this.title, required this.bytes});

  @override
  State<OfficeView> createState() => _OfficeViewState();
}

class _OfficeViewState extends State<OfficeView> {
  OfficeContent? _content;
  String? _error;
  int _sheet = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await compute(_parse, (extensionOf(widget.title), widget.bytes));
      if (mounted) setState(() => _content = c);
    } on OfficeException catch (e) {
      if (mounted) {
        setState(() => _error = e.message.contains('password')
            ? 'This document is password-protected; it can\'t be shown.'
            : 'This file can\'t be read: it may be damaged, or not what its name says.');
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'This file can\'t be read: it may be damaged, or not what its name says.');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, key: const Key('office-error'), textAlign: TextAlign.center,
              style: AppFonts.ui(color: Colors.white54)),
        ),
      );
    }
    return switch (_content) {
      null => const Center(child: CircularProgressIndicator(color: _accent)),
      OfficeLines(:final lines) => _lines(lines),
      OfficeSheets(:final sheets) => _sheets(sheets),
      OfficeSlides(:final slides) => _slides(slides),
    };
  }

  Widget _lines(List<String> lines) => Container(
        color: Colors.white,
        child: ListView.builder(
          key: const Key('office-lines'),
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
          itemCount: lines.length,
          itemBuilder: (_, i) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SelectableText(
              lines[i].replaceAll('\t', '    '),
              contextMenuBuilder: vaultContextMenu,
              style: AppFonts.ui(fontSize: 14, color: Ui.surface, height: 1.45),
            ),
          ),
        ),
      );

  static String _colName(int i) {
    var n = i + 1;
    var s = '';
    while (n > 0) {
      final r = (n - 1) % 26;
      s = String.fromCharCode(65 + r) + s;
      n = (n - 1) ~/ 26;
    }
    return s;
  }

  Widget _sheets(List<Sheet> sheets) {
    final sheet = sheets[_sheet.clamp(0, sheets.length - 1)];
    final cols = sheet.rows.fold<int>(0, (m, r) => r.length > m ? r.length : m).clamp(1, OfficeLimits.maxCols);
    const cellW = 132.0, rowH = 34.0, headW = 44.0;
    Widget cell(String text, {bool head = false, double width = cellW}) => Container(
          width: width,
          height: rowH,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: head ? Alignment.center : Alignment.centerLeft,
          decoration: BoxDecoration(
            color: head ? Ui.surface : Ui.canvas,
            border: Border.all(color: Colors.white10, width: 0.5),
          ),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.firaCode(fontSize: 12, color: head ? Colors.white54 : Colors.white),
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sheets.length > 1)
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              children: [
                for (var i = 0; i < sheets.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      key: Key('office-sheet-$i'),
                      label: Text(sheets[i].name, style: AppFonts.ui(fontSize: 12)),
                      selected: i == _sheet,
                      selectedColor: _accent.withValues(alpha: 0.35),
                      onSelected: (_) => setState(() => _sheet = i),
                    ),
                  ),
              ],
            ),
          ),
        if (sheet.truncated)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text('A very large sheet: only the first part is shown.',
                style: AppFonts.ui(fontSize: 12, color: Ui.signal)),
          ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: headW + cols * cellW,
              child: ListView.builder(
                key: const Key('office-sheet'),
                itemCount: sheet.rows.length + 1,
                itemBuilder: (_, r) {
                  if (r == 0) {
                    return Row(children: [
                      cell('', head: true, width: headW),
                      for (var c = 0; c < cols; c++) cell(_colName(c), head: true),
                    ]);
                  }
                  final row = sheet.rows[r - 1];
                  return Row(children: [
                    cell('$r', head: true, width: headW),
                    for (var c = 0; c < cols; c++) cell(c < row.length ? row[c] : ''),
                  ]);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _slides(List<Slide> slides) => ListView.builder(
        key: const Key('office-slides'),
        padding: const EdgeInsets.all(14),
        itemCount: slides.length,
        itemBuilder: (_, i) {
          final s = slides[i];
          return Container(
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Ui.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Slide ${s.number}', style: AppFonts.ui(fontSize: 11, color: _accent)),
                const SizedBox(height: 8),
                if (s.paragraphs.isEmpty)
                  Text('(no text)', style: AppFonts.ui(fontSize: 13, color: Colors.white38))
                else ...[
                  SelectableText(
                    s.paragraphs.first,
                    contextMenuBuilder: vaultContextMenu,
                    style: AppFonts.ui(fontSize: 17, fontWeight: FontWeight.w500, color: Colors.white),
                  ),
                  for (final p in s.paragraphs.skip(1))
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: SelectableText(
                        p,
                        contextMenuBuilder: vaultContextMenu,
                        style: AppFonts.ui(fontSize: 14, color: Colors.white70),
                      ),
                    ),
                ],
              ],
            ),
          );
        },
      );
}
