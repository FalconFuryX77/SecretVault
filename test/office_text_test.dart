// Office documents made by Microsoft Office (with personal information
// removed), read by the vault's own plain-Dart readers.
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/viewers/office_text.dart';

Uint8List fixture(String name) => File('test/fixtures/office/$name').readAsBytesSync();

void main() {
  test('Excel .xlsx: sheets, strings, numbers, booleans, formula results, sparse cells', () {
    final sheets = XlsxReader.read(fixture('expenses.xlsx'));
    expect(sheets.map((s) => s.name), ['Expenses', 'Contacts']);
    final e = sheets.first.rows;
    expect(e[0].take(3), ['Item', 'Cost', 'Paid']);
    expect(e[1].take(3), ['Taxi to café', '12.5', 'TRUE']);
    expect(e[3].take(2), ['Total', '92.5'], reason: 'the formula\'s stored result');
    expect(e[5][4], 'far cell');
    expect(sheets[1].rows.first, ['Sami', '+380 44 000 0000']);
  });

  test('OpenDocument .ods reads the same', () {
    final sheets = OdfReader.sheets(fixture('expenses.ods'));
    expect(sheets.map((s) => s.name), ['Expenses', 'Contacts']);
    expect(sheets.first.rows[1].take(2), ['Taxi to café', '12.5']);
    expect(sheets.first.rows[5][4], 'far cell');
  });

  test('PowerPoint .pptx and .odp: slide text in order', () {
    for (final slides in [PptxReader.read(fixture('update.pptx')), OdfReader.slides(fixture('update.odp'))]) {
      expect(slides, hasLength(2));
      expect(slides[0].paragraphs, containsAll(['Investigation update', 'Confidential']));
      expect(slides[1].paragraphs, containsAll(['Findings', 'Payments routed via a shell company', 'Three witnesses']));
    }
  });

  test('old Word .doc: 8-bit text, a table, and UTF-16 text', () {
    final western = DocReader.read(fixture('western.doc'));
    expect(western, contains('Interview notes'));
    expect(western, contains('Met the source at the café on Rue de la Paix. They asked for anonymity.'));
    expect(western.any((l) => l.contains('Name') && l.contains('Role')), isTrue, reason: 'table cells on one line');
    final unicode = DocReader.read(fixture('unicode.doc'));
    expect(unicode, contains('Report'));
    expect(unicode.join('\n'), contains('Meeting with سامي in Kyiv Київ'));
  });

  test('OpenDocument .odt text', () {
    final lines = OdfReader.text(fixture('western.odt'));
    expect(lines, contains('Interview notes'));
    expect(lines.join('\n'), contains('café on Rue de la Paix'));
  });

  test('garbage, truncation and zip bombs are refused, never crash', () {
    final junk = Uint8List.fromList(List.generate(5000, (i) => (i * 37) & 0xff));
    for (final read in <void Function(Uint8List)>[
      XlsxReader.read,
      PptxReader.read,
      DocReader.read,
      OdfReader.text,
      OdfReader.sheets,
      OdfReader.slides,
    ]) {
      expect(() => read(junk), throwsA(isA<OfficeException>()));
    }
    final doc = fixture('western.doc');
    expect(() => DocReader.read(Uint8List.sublistView(doc, 0, doc.length ~/ 3)), throwsA(isA<OfficeException>()));
    // A sheet that inflates to far more than the limit.
    final bomb = Archive()
      ..addFile(ArchiveFile('xl/workbook.xml', 60, '<workbook><sheets><sheet name="a"/></sheets></workbook>'.codeUnits))
      ..addFile(ArchiveFile('xl/worksheets/sheet1.xml', OfficeLimits.maxXmlBytes + 10,
          Uint8List(OfficeLimits.maxXmlBytes + 10)));
    expect(() => XlsxReader.read(Uint8List.fromList(ZipEncoder().encode(bomb))), throwsA(isA<OfficeException>()));
  });
}
