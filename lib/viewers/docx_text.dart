import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// A run of text with simple formatting.
class DocxRun {
  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  const DocxRun(this.text, {this.bold = false, this.italic = false, this.underline = false});
}

sealed class DocxBlock {}

class DocxParagraph extends DocxBlock {
  final List<DocxRun> runs;

  /// 0 for body text, 1..6 for headings (Title counts as 1).
  final int heading;
  final bool listItem;
  DocxParagraph(this.runs, {this.heading = 0, this.listItem = false});
  String get text => runs.map((r) => r.text).join();
}

class DocxTable extends DocxBlock {
  final List<List<String>> rows;
  DocxTable(this.rows);
}

class DocxException implements Exception {
  final String message;
  DocxException(this.message);
  @override
  String toString() => 'DocxException: $message';
}

/// Reads the text of a Word (.docx) document: paragraphs, headings, lists
/// and tables, with bold/italic/underline. Pictures are noted, not shown.
///
/// Written in plain Dart, which is memory-safe, so a malformed document can
/// at worst fail to open; it can't run code the way a native parser bug
/// can. Sizes are capped so a "zip bomb" can't exhaust memory.
class DocxReader {
  /// Largest document.xml we will inflate.
  static const int maxXmlBytes = 32 * 1024 * 1024;

  static List<DocxBlock> read(Uint8List bytes) {
    final Archive zip;
    try {
      zip = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw DocxException('not a Word document');
    }
    final doc = zip.findFile('word/document.xml');
    if (doc == null) throw DocxException('not a Word document');
    if (doc.size > maxXmlBytes) throw DocxException('document too large');
    final xmlBytes = doc.readBytes();
    if (xmlBytes == null || xmlBytes.length > maxXmlBytes) throw DocxException('document too large');
    final text = _utf8(xmlBytes);
    // Word never writes a DTD; refusing one rules out entity tricks.
    if (text.contains('<!DOCTYPE')) throw DocxException('unexpected document type');
    final XmlDocument xml;
    try {
      xml = XmlDocument.parse(text);
    } catch (_) {
      throw DocxException('damaged document');
    }
    final body = xml.rootElement.findElements('body', namespace: '*').firstOrNull ??
        xml.rootElement.childElements.firstWhere((e) => e.localName == 'body',
            orElse: () => throw DocxException('damaged document'));
    final out = <DocxBlock>[];
    _blocks(body, out);
    return out;
  }

  static String _utf8(Uint8List b) {
    // Strip a byte-order mark if present.
    final start = b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF ? 3 : 0;
    return const Utf8Decoder(allowMalformed: true).convert(b, start);
  }

  static void _blocks(XmlElement parent, List<DocxBlock> out) {
    for (final e in parent.childElements) {
      switch (e.localName) {
        case 'p':
          out.add(_paragraph(e));
        case 'tbl':
          out.add(_table(e));
        case 'sdt':
          final content = _child(e, 'sdtContent');
          if (content != null) _blocks(content, out);
        default:
          break;
      }
    }
  }

  static XmlElement? _child(XmlElement e, String local) =>
      e.childElements.where((c) => c.localName == local).firstOrNull;

  static String? _val(XmlElement? e) {
    if (e == null) return null;
    for (final a in e.attributes) {
      if (a.name.local == 'val') return a.value;
    }
    return null;
  }

  static bool _on(XmlElement? props, String local) {
    final e = props == null ? null : _child(props, local);
    if (e == null) return false;
    final v = _val(e);
    return v == null || !(v == '0' || v == 'false' || v == 'none');
  }

  static DocxParagraph _paragraph(XmlElement p) {
    final props = _child(p, 'pPr');
    final style = _val(props == null ? null : _child(props, 'pStyle'))?.toLowerCase() ?? '';
    var heading = 0;
    if (style == 'title') {
      heading = 1;
    } else {
      final m = RegExp(r'^heading\s*([1-6])$').firstMatch(style);
      if (m != null) heading = int.parse(m.group(1)!);
    }
    final listItem = props != null && _child(props, 'numPr') != null;
    final runs = <DocxRun>[];
    for (final r in p.descendants.whereType<XmlElement>().where((e) => e.localName == 'r')) {
      // Text deleted under track changes is kept in w:delText, which we skip.
      final rp = _child(r, 'rPr');
      final b = _on(rp, 'b'), i = _on(rp, 'i'), u = _on(rp, 'u');
      final sb = StringBuffer();
      for (final c in r.childElements) {
        switch (c.localName) {
          case 't':
            sb.write(c.innerText);
          case 'tab':
            sb.write('\t');
          case 'br' || 'cr':
            sb.write('\n');
          case 'drawing' || 'pict' || 'object':
            sb.write('[picture]');
          default:
            break;
        }
      }
      if (sb.isNotEmpty) runs.add(DocxRun(sb.toString(), bold: b, italic: i, underline: u));
    }
    return DocxParagraph(runs, heading: heading, listItem: listItem);
  }

  static DocxTable _table(XmlElement t) {
    final rows = <List<String>>[];
    for (final tr in t.childElements.where((e) => e.localName == 'tr')) {
      final cells = <String>[];
      for (final tc in tr.childElements.where((e) => e.localName == 'tc')) {
        final inner = <DocxBlock>[];
        _blocks(tc, inner);
        cells.add(inner
            .map((b) => switch (b) {
                  DocxParagraph p => p.text,
                  DocxTable t => t.rows.map((r) => r.join(' | ')).join('\n'),
                })
            .join('\n'));
      }
      rows.add(cells);
    }
    return DocxTable(rows);
  }
}
