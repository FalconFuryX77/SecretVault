import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gesture_unlock/viewers/docx_text.dart';

const _ns = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"';

Uint8List docx(String body, {String? raw}) {
  final xml = raw ?? '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document $_ns><w:body>$body</w:body></w:document>';
  final a = Archive()..addFile(ArchiveFile.bytes('word/document.xml', utf8.encode(xml)));
  return Uint8List.fromList(ZipEncoder().encodeBytes(a));
}

void main() {
  test('headings, formatting, lists, breaks and pictures', () {
    final blocks = DocxReader.read(docx('''
      <w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Field report</w:t></w:r></w:p>
      <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Day one</w:t></w:r></w:p>
      <w:p><w:r><w:rPr><w:b/></w:rPr><w:t xml:space="preserve">Bold </w:t></w:r><w:r><w:rPr><w:i/><w:b w:val="0"/></w:rPr><w:t>italic</w:t></w:r><w:r><w:tab/><w:t>after tab</w:t><w:br/><w:t>next line</w:t></w:r></w:p>
      <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>first point</w:t></w:r></w:p>
      <w:p><w:r><w:t>kept </w:t></w:r><w:del><w:r><w:delText>removed</w:delText></w:r></w:del><w:hyperlink><w:r><w:t>link text</w:t></w:r></w:hyperlink></w:p>
      <w:p><w:r><w:drawing/></w:r></w:p>
    '''));
    final ps = blocks.cast<DocxParagraph>();
    expect(ps[0].heading, 1);
    expect(ps[0].text, 'Field report');
    expect(ps[1].heading, 2);
    expect(ps[2].runs[0].bold, isTrue);
    expect(ps[2].runs[1].bold, isFalse, reason: 'w:val="0" turns bold off');
    expect(ps[2].runs[1].italic, isTrue);
    expect(ps[2].text, 'Bold italic\tafter tab\nnext line');
    expect(ps[3].listItem, isTrue);
    expect(ps[4].text, 'kept link text', reason: 'tracked deletions are not shown');
    expect(ps[5].text, '[picture]');
  });

  test('tables come out as rows of cells', () {
    final blocks = DocxReader.read(docx('''
      <w:tbl>
        <w:tr><w:tc><w:p><w:r><w:t>Name</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Place</w:t></w:r></w:p></w:tc></w:tr>
        <w:tr><w:tc><w:p><w:r><w:t>A.</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>North</w:t></w:r></w:p><w:p><w:r><w:t>gate</w:t></w:r></w:p></w:tc></w:tr>
      </w:tbl>
      <w:sdt><w:sdtContent><w:p><w:r><w:t>inside a content control</w:t></w:r></w:p></w:sdtContent></w:sdt>
    '''));
    final t = blocks[0] as DocxTable;
    expect(t.rows, [
      ['Name', 'Place'],
      ['A.', 'North\ngate'],
    ]);
    expect((blocks[1] as DocxParagraph).text, 'inside a content control');
  });

  test('refuses things that are not plain Word documents', () {
    expect(() => DocxReader.read(Uint8List.fromList(utf8.encode('just text'))), throwsA(isA<DocxException>()));
    final noDoc = Archive()..addFile(ArchiveFile.bytes('other.xml', utf8.encode('<a/>')));
    expect(() => DocxReader.read(Uint8List.fromList(ZipEncoder().encodeBytes(noDoc))), throwsA(isA<DocxException>()));
    expect(
      () => DocxReader.read(docx('', raw: '<?xml version="1.0"?><!DOCTYPE x [<!ENTITY a "aaaa">]><w:document $_ns><w:body/></w:document>')),
      throwsA(isA<DocxException>()),
      reason: 'no DTDs, so no entity expansion tricks',
    );
    expect(() => DocxReader.read(docx('', raw: '<w:document $_ns><w:body><w:p>')), throwsA(isA<DocxException>()));
  });

  test('a zip bomb is refused before it is inflated', () {
    final huge = Uint8List(DocxReader.maxXmlBytes + 1);
    final a = Archive()..addFile(ArchiveFile.bytes('word/document.xml', huge));
    final bomb = Uint8List.fromList(ZipEncoder().encodeBytes(a));
    expect(bomb.length, lessThan(200 * 1024), reason: 'tiny on disk');
    expect(() => DocxReader.read(bomb), throwsA(isA<DocxException>()));
  });
}
