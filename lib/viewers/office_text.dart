import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Text out of office documents, for the in-vault viewer: spreadsheets
/// (.xlsx, .ods), slides (.pptx, .odp), old Word (.doc) and OpenDocument
/// text (.odt). Plain Dart, so a malformed or hostile file can at worst fail
/// to open, and every size is capped so a "zip bomb" can't exhaust memory.
/// Formatting, pictures and formulas are not shown; values and text are.
class OfficeException implements Exception {
  final String message;
  OfficeException(this.message);
  @override
  String toString() => 'OfficeException: $message';
}

class Sheet {
  final String name;
  final List<List<String>> rows;

  /// True if the sheet had more cells than are shown.
  final bool truncated;
  const Sheet(this.name, this.rows, {this.truncated = false});
}

class Slide {
  final int number;
  final List<String> paragraphs;
  const Slide(this.number, this.paragraphs);
}

/// Limits shared by every reader.
class OfficeLimits {
  static const int maxXmlBytes = 32 * 1024 * 1024;
  static const int maxEntries = 4000;
  static const int maxSheets = 64;
  static const int maxRows = 5000;
  static const int maxCols = 200;
  static const int maxCells = 200000;
  static const int maxSlides = 1000;
  static const int maxChars = 4 * 1024 * 1024;
}

class _Zip {
  final Archive archive;
  _Zip(this.archive);

  static _Zip open(Uint8List bytes) {
    try {
      final a = ZipDecoder().decodeBytes(bytes);
      if (a.files.length > OfficeLimits.maxEntries) throw OfficeException('too many parts');
      return _Zip(a);
    } on OfficeException {
      rethrow;
    } catch (_) {
      throw OfficeException('not an office document, or damaged');
    }
  }

  XmlDocument? xml(String name) {
    final f = archive.findFile(name);
    if (f == null) return null;
    // A zip64 entry can declare an "unknown" size (-1): no inflate limit.
    if (f.size < 0 || f.size > OfficeLimits.maxXmlBytes) throw OfficeException('document too large');
    final bytes = f.readBytes();
    if (bytes == null || bytes.length > OfficeLimits.maxXmlBytes) throw OfficeException('document too large');
    final text = utf8.decode(bytes, allowMalformed: true);
    // These formats never use a DTD; refusing one rules out entity tricks.
    if (text.contains('<!DOCTYPE')) throw OfficeException('unexpected document type');
    try {
      return XmlDocument.parse(text);
    } catch (_) {
      throw OfficeException('damaged document');
    }
  }

  Iterable<String> get names => archive.files.map((f) => f.name);
}

Iterable<XmlElement> _all(XmlNode n, String local) =>
    n.descendants.whereType<XmlElement>().where((e) => e.localName == local);

String? _attr(XmlElement e, String local) {
  for (final a in e.attributes) {
    if (a.name.local == local) return a.value;
  }
  return null;
}

// ─── Excel (.xlsx) ─────────────────────────────────────────────────────

class XlsxReader {
  static List<Sheet> read(Uint8List bytes) {
    final z = _Zip.open(bytes);
    final wb = z.xml('xl/workbook.xml') ?? (throw OfficeException('not an Excel workbook'));
    final shared = <String>[];
    final sst = z.xml('xl/sharedStrings.xml');
    if (sst != null) {
      for (final si in _all(sst, 'si')) {
        // Rich text has several runs; phonetic hints (rPh) are not text.
        shared.add(_all(si, 't').where((t) => t.parentElement?.localName != 'rPh').map((t) => t.innerText).join());
        if (shared.length > OfficeLimits.maxCells) break;
      }
    }
    // Sheet name → part, through the workbook's relationships.
    final rels = <String, String>{};
    final relXml = z.xml('xl/_rels/workbook.xml.rels');
    if (relXml != null) {
      for (final r in _all(relXml, 'Relationship')) {
        final id = _attr(r, 'Id'), target = _attr(r, 'Target');
        if (id != null && target != null) {
          rels[id] = target.startsWith('/') ? target.substring(1) : 'xl/${target.replaceFirst(RegExp(r'^\./'), '')}';
        }
      }
    }
    final sheets = <Sheet>[];
    var index = 0;
    for (final s in _all(wb, 'sheet')) {
      if (sheets.length >= OfficeLimits.maxSheets) break;
      index++;
      final name = _attr(s, 'name') ?? 'Sheet $index';
      final part = rels[_attr(s, 'id') ?? ''] ?? 'xl/worksheets/sheet$index.xml';
      final doc = z.xml(part);
      if (doc == null) continue;
      sheets.add(_sheet(name, doc, shared));
    }
    if (sheets.isEmpty) throw OfficeException('no sheets');
    return sheets;
  }

  static int _col(String ref) {
    var n = 0;
    for (final c in ref.codeUnits) {
      if (c < 65 || c > 90) break;
      n = n * 26 + (c - 64);
    }
    return n - 1;
  }

  static Sheet _sheet(String name, XmlDocument doc, List<String> shared) {
    final rows = <List<String>>[];
    var cells = 0;
    var truncated = false;
    for (final row in _all(doc, 'row')) {
      final r = (int.tryParse(_attr(row, 'r') ?? '') ?? rows.length + 1) - 1;
      if (r >= OfficeLimits.maxRows || cells >= OfficeLimits.maxCells) {
        truncated = true;
        break;
      }
      while (rows.length <= r) {
        rows.add(<String>[]);
      }
      final out = rows[r];
      for (final c in row.childElements.where((e) => e.localName == 'c')) {
        final ref = _attr(c, 'r') ?? '';
        final col = ref.isEmpty ? out.length : _col(ref);
        if (col < 0 || col >= OfficeLimits.maxCols) {
          truncated = true;
          continue;
        }
        final type = _attr(c, 't');
        final v = c.childElements.where((e) => e.localName == 'v').firstOrNull?.innerText;
        String text;
        if (type == 's') {
          final i = int.tryParse(v ?? '');
          text = i != null && i >= 0 && i < shared.length ? shared[i] : '';
        } else if (type == 'inlineStr') {
          text = _all(c, 't').map((t) => t.innerText).join();
        } else if (type == 'b') {
          text = v == '1' ? 'TRUE' : (v == '0' ? 'FALSE' : v ?? '');
        } else {
          text = _number(v ?? '');
        }
        while (out.length <= col) {
          out.add('');
        }
        out[col] = text;
        cells++;
      }
    }
    // Trailing empty rows add nothing.
    while (rows.isNotEmpty && rows.last.every((c) => c.isEmpty)) {
      rows.removeLast();
    }
    return Sheet(name, rows, truncated: truncated);
  }

  /// "3.0000000000000004" → "3", keeps integers and short decimals readable.
  static String _number(String v) {
    final d = double.tryParse(v);
    if (d == null) return v;
    if (d == d.roundToDouble() && d.abs() < 1e15) return d.toInt().toString();
    final s = d.toStringAsPrecision(12);
    return s.contains('e') ? s : s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
}

// ─── PowerPoint (.pptx) ────────────────────────────────────────────────

class PptxReader {
  static List<Slide> read(Uint8List bytes) {
    final z = _Zip.open(bytes);
    final numbers = <int>[];
    final pattern = RegExp(r'^ppt/slides/slide(\d+)\.xml$');
    for (final n in z.names) {
      final m = pattern.firstMatch(n);
      if (m != null) numbers.add(int.parse(m.group(1)!));
    }
    if (numbers.isEmpty) throw OfficeException('not a PowerPoint presentation');
    numbers.sort();
    final slides = <Slide>[];
    var chars = 0;
    for (final n in numbers.take(OfficeLimits.maxSlides)) {
      final doc = z.xml('ppt/slides/slide$n.xml');
      if (doc == null) continue;
      final paras = <String>[];
      for (final p in _all(doc, 'p')) {
        if (p.name.prefix != 'a' && p.name.namespaceUri?.contains('drawingml') != true) continue;
        final text = _all(p, 't').map((t) => t.innerText).join();
        if (text.trim().isEmpty) continue;
        paras.add(text);
        chars += text.length;
        if (chars > OfficeLimits.maxChars) break;
      }
      slides.add(Slide(slides.length + 1, paras));
      if (chars > OfficeLimits.maxChars) break;
    }
    return slides;
  }
}

// ─── OpenDocument (.odt, .ods, .odp) ───────────────────────────────────

class OdfReader {
  static XmlDocument _content(Uint8List bytes) =>
      _Zip.open(bytes).xml('content.xml') ?? (throw OfficeException('not an OpenDocument file'));

  static String _text(XmlElement e) {
    final b = StringBuffer();
    void walk(XmlNode n) {
      if (n is XmlText) {
        b.write(n.value);
      } else if (n is XmlElement) {
        switch (n.localName) {
          case 's':
            b.write(' ' * (int.tryParse(_attr(n, 'c') ?? '1') ?? 1).clamp(1, 100));
          case 'tab':
            b.write('\t');
          case 'line-break':
            b.write('\n');
          default:
            n.children.forEach(walk);
        }
      }
    }

    walk(e);
    return b.toString();
  }

  /// Paragraphs and headings of a text document.
  static List<String> text(Uint8List bytes) {
    final out = <String>[];
    var chars = 0;
    for (final p in _content(bytes).descendants.whereType<XmlElement>()) {
      if (p.localName != 'p' && p.localName != 'h') continue;
      final t = _text(p);
      out.add(t);
      chars += t.length;
      if (chars > OfficeLimits.maxChars) break;
    }
    return out;
  }

  static List<Sheet> sheets(Uint8List bytes) {
    final sheets = <Sheet>[];
    for (final table in _all(_content(bytes), 'table')) {
      if (sheets.length >= OfficeLimits.maxSheets) break;
      final rows = <List<String>>[];
      var truncated = false;
      var cells = 0;
      for (final row in table.descendants.whereType<XmlElement>().where((e) => e.localName == 'table-row')) {
        final repeatRows = (int.tryParse(_attr(row, 'number-rows-repeated') ?? '1') ?? 1).clamp(1, 1000);
        final out = <String>[];
        for (final cell in row.childElements.where((e) => e.localName == 'table-cell' || e.localName == 'covered-table-cell')) {
          final repeat = (int.tryParse(_attr(cell, 'number-columns-repeated') ?? '1') ?? 1).clamp(1, OfficeLimits.maxCols);
          final value = cell.childElements.where((e) => e.localName == 'p').map(_text).join('\n');
          for (var i = 0; i < repeat && out.length < OfficeLimits.maxCols; i++) {
            out.add(value);
          }
        }
        while (out.isNotEmpty && out.last.isEmpty) {
          out.removeLast();
        }
        for (var i = 0; i < repeatRows; i++) {
          if (rows.length >= OfficeLimits.maxRows || cells >= OfficeLimits.maxCells) {
            truncated = true;
            break;
          }
          rows.add(out);
          cells += out.length;
        }
        if (truncated) break;
      }
      while (rows.isNotEmpty && rows.last.isEmpty) {
        rows.removeLast();
      }
      sheets.add(Sheet(_attr(table, 'name') ?? 'Sheet ${sheets.length + 1}', rows, truncated: truncated));
    }
    if (sheets.isEmpty) throw OfficeException('no sheets');
    return sheets;
  }

  static List<Slide> slides(Uint8List bytes) {
    final slides = <Slide>[];
    for (final page in _all(_content(bytes), 'page')) {
      if (slides.length >= OfficeLimits.maxSlides) break;
      final paras = [
        for (final p in page.descendants.whereType<XmlElement>().where((e) => e.localName == 'p'))
          if (_text(p).trim().isNotEmpty) _text(p),
      ];
      slides.add(Slide(slides.length + 1, paras));
    }
    if (slides.isEmpty) throw OfficeException('no slides');
    return slides;
  }
}

// ─── Old Word (.doc, Word 97–2003) ─────────────────────────────────────

/// Microsoft's Compound File Binary format (the container of .doc, .xls,
/// .ppt): a little file system of fixed-size sectors.
class _Cfb {
  final Uint8List b;
  late final int _sectorSize;
  late final int _miniSize;
  late final int _miniCutoff;
  late final List<int> _fat;
  late final List<int> _miniFat;
  late final List<({String name, int type, int start, int size})> _dir;
  late final Uint8List _miniStream;

  static const int _end = -2; // ENDOFCHAIN
  static const List<int> _magic = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];

  _Cfb(this.b) {
    if (b.length < 512) throw OfficeException('not a Word document');
    for (var i = 0; i < 8; i++) {
      if (b[i] != _magic[i]) throw OfficeException('not a Word document');
    }
    final h = ByteData.sublistView(b);
    final shift = h.getUint16(0x1E, Endian.little);
    if (shift != 9 && shift != 12) throw OfficeException('damaged document');
    _sectorSize = 1 << shift;
    _miniSize = 1 << h.getUint16(0x20, Endian.little);
    _miniCutoff = h.getUint32(0x38, Endian.little);
    // FAT sectors: 109 in the header, the rest in the DIFAT chain.
    final fatSectors = <int>[];
    for (var i = 0; i < 109; i++) {
      final s = h.getInt32(0x4C + i * 4, Endian.little);
      if (s >= 0) fatSectors.add(s);
    }
    var difat = h.getInt32(0x44, Endian.little);
    var guard = 0;
    while (difat >= 0 && guard++ < 10000) {
      final off = _offset(difat);
      final per = _sectorSize ~/ 4 - 1;
      for (var i = 0; i < per; i++) {
        final s = h.getInt32(off + i * 4, Endian.little);
        if (s >= 0) fatSectors.add(s);
      }
      difat = h.getInt32(off + per * 4, Endian.little);
    }
    _fat = [];
    for (final s in fatSectors) {
      final off = _offset(s);
      for (var i = 0; i < _sectorSize ~/ 4; i++) {
        _fat.add(h.getInt32(off + i * 4, Endian.little));
      }
    }
    final dirBytes = _chain(h.getInt32(0x30, Endian.little), _fat, _sectorSize, (s) => _offset(s), 64 * 1024 * 1024);
    _dir = [];
    final d = ByteData.sublistView(dirBytes);
    for (var o = 0; o + 128 <= dirBytes.length; o += 128) {
      final nameLen = d.getUint16(o + 0x40, Endian.little).clamp(0, 64);
      final name = String.fromCharCodes([
        for (var i = 0; i + 1 < nameLen - 1; i += 2) d.getUint16(o + i, Endian.little),
      ]);
      _dir.add((
        name: name,
        type: dirBytes[o + 0x42],
        start: d.getInt32(o + 0x74, Endian.little),
        size: d.getUint32(o + 0x78, Endian.little),
      ));
    }
    final root = _dir.firstWhere((e) => e.type == 5, orElse: () => throw OfficeException('damaged document'));
    _miniStream = _chain(root.start, _fat, _sectorSize, (s) => _offset(s), root.size);
    final miniFatBytes = _chain(h.getInt32(0x3C, Endian.little), _fat, _sectorSize, (s) => _offset(s), 64 * 1024 * 1024);
    final mf = ByteData.sublistView(miniFatBytes);
    _miniFat = [for (var i = 0; i + 4 <= miniFatBytes.length; i += 4) mf.getInt32(i, Endian.little)];
  }

  int _offset(int sector) {
    final o = (sector + 1) * _sectorSize;
    if (sector < 0 || o + _sectorSize > b.length) throw OfficeException('damaged document');
    return o;
  }

  /// Follows a sector chain, at most [limit] bytes, never looping.
  Uint8List _chain(int start, List<int> table, int size, int Function(int) offset, int limit) {
    final out = BytesBuilder(copy: false);
    var s = start;
    var steps = 0;
    while (s >= 0 && out.length < limit) {
      if (s >= table.length || steps++ > table.length) throw OfficeException('damaged document');
      final o = offset(s);
      out.add(Uint8List.sublistView(size == _sectorSize ? b : _miniStream, o, o + size));
      s = table[s];
    }
    if (s != _end && s >= 0) throw OfficeException('damaged document');
    final all = out.takeBytes();
    return all.length > limit ? Uint8List.sublistView(all, 0, limit) : all;
  }

  Uint8List? stream(String name) {
    final e = _dir.where((d) => d.type == 2 && d.name == name).firstOrNull;
    if (e == null) return null;
    if (e.size < _miniCutoff) {
      return _chain(e.start, _miniFat, _miniSize, (s) {
        final o = s * _miniSize;
        if (o + _miniSize > _miniStream.length) throw OfficeException('damaged document');
        return o;
      }, e.size);
    }
    return _chain(e.start, _fat, _sectorSize, _offset, e.size);
  }
}

class DocReader {
  /// The main text of a Word 97–2003 document, as paragraphs.
  static List<String> read(Uint8List bytes) {
    final cfb = _Cfb(bytes);
    final word = cfb.stream('WordDocument') ?? (throw OfficeException('not a Word document'));
    if (word.length < 0x200) throw OfficeException('damaged document');
    final fib = ByteData.sublistView(word);
    if (fib.getUint16(0, Endian.little) != 0xA5EC) throw OfficeException('not a Word document');
    final flags = fib.getUint16(0x0A, Endian.little);
    if (flags & 0x0100 != 0) throw OfficeException('this document is password-protected');
    final table = cfb.stream(flags & 0x0200 != 0 ? '1Table' : '0Table') ?? (throw OfficeException('damaged document'));
    // FIB: base (32) | csw | fibRgW | cslw | fibRgLw | cbRgFcLcb | fibRgFcLcb
    final csw = fib.getUint16(32, Endian.little);
    final lw = 32 + 2 + csw * 2;
    final cslw = fib.getUint16(lw, Endian.little);
    final ccpText = fib.getInt32(lw + 2 + 12, Endian.little);
    final fcLcb = lw + 2 + cslw * 4 + 2;
    if (fcLcb + 34 * 8 > word.length) throw OfficeException('damaged document');
    final fcClx = fib.getUint32(fcLcb + 33 * 8, Endian.little);
    final lcbClx = fib.getUint32(fcLcb + 33 * 8 + 4, Endian.little);
    if (fcClx + lcbClx > table.length || lcbClx == 0) throw OfficeException('damaged document');
    final clx = ByteData.sublistView(table, fcClx, fcClx + lcbClx);
    var o = 0;
    // Skip property modifiers (Prc), then the piece table (Pcdt).
    while (o < lcbClx && clx.getUint8(o) == 1) {
      o += 3 + clx.getUint16(o + 1, Endian.little);
    }
    if (o + 5 > lcbClx || clx.getUint8(o) != 2) throw OfficeException('damaged document');
    final lcb = clx.getUint32(o + 1, Endian.little);
    final plc = o + 5;
    if (plc + lcb > lcbClx) throw OfficeException('damaged document');
    final n = (lcb - 4) ~/ 12;
    final text = StringBuffer();
    for (var i = 0; i < n && text.length < OfficeLimits.maxChars; i++) {
      final cpStart = clx.getUint32(plc + i * 4, Endian.little);
      final cpEnd = clx.getUint32(plc + (i + 1) * 4, Endian.little);
      if (cpEnd < cpStart) throw OfficeException('damaged document');
      final pcd = plc + (n + 1) * 4 + i * 8;
      final fcRaw = clx.getUint32(pcd + 2, Endian.little);
      final count = cpEnd - cpStart;
      if (fcRaw & 0x40000000 != 0) {
        // 8-bit text (Windows-1252), at half the stored offset.
        final at = (fcRaw & 0x3FFFFFFF) ~/ 2;
        if (at + count > word.length) throw OfficeException('damaged document');
        for (var k = 0; k < count; k++) {
          text.writeCharCode(_cp1252(word[at + k]));
        }
      } else {
        if (fcRaw + count * 2 > word.length) throw OfficeException('damaged document');
        final u = ByteData.sublistView(word, fcRaw, fcRaw + count * 2);
        for (var k = 0; k < count; k++) {
          text.writeCharCode(u.getUint16(k * 2, Endian.little));
        }
      }
    }
    var all = text.toString();
    if (ccpText > 0 && ccpText < all.length) all = all.substring(0, ccpText);
    return _clean(all);
  }

  static const _win1252 = {
    0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021, //
    0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018, //
    0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC, //
    0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178,
  };
  static int _cp1252(int b) => _win1252[b] ?? b;

  /// Paragraph marks to lines; field codes dropped (their results kept);
  /// table cell marks to tabs; other control characters removed.
  static List<String> _clean(String s) {
    final out = StringBuffer();
    var depth = 0;
    final hidden = <bool>[];
    for (final c in s.runes) {
      if (c == 0x13) {
        depth++;
        hidden.add(true);
        continue;
      }
      if (c == 0x14) {
        if (hidden.isNotEmpty) hidden[hidden.length - 1] = false;
        continue;
      }
      if (c == 0x15) {
        if (depth > 0) depth--;
        if (hidden.isNotEmpty) hidden.removeLast();
        continue;
      }
      if (hidden.contains(true)) continue;
      if (c == 0x0D || c == 0x0B || c == 0x0C) {
        out.write('\n');
      } else if (c == 0x07) {
        out.write('\t');
      } else if (c == 0x09 || c >= 0x20) {
        out.writeCharCode(c);
      }
    }
    final lines = out.toString().split('\n');
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    return lines;
  }
}
