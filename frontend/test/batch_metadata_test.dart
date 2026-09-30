import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:ccs_sleep_studio/src/batch_metadata.dart';
import 'package:ccs_sleep_studio/src/regional_csv.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('meta_test_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('CSV metadata matches by file name, folder name and containment', () async {
    final csv = File('${dir.path}/meta.csv')
      ..writeAsStringSync('Recording,Group,Age\nsub01,Placebo,34\nLD_Pi_03,Drug,41\nnight2,Drug,50\n');
    final t = await readBatchMetadataFile(csv.path);
    expect(t.headers, ['Recording', 'Group', 'Age']);
    expect(t.keyColumn, 'Recording');

    expect(t.lookup('/data/sub01.edf')?['Group'], 'Placebo');
    expect(t.lookup('/data/sub01_clean.edf')?['Group'], 'Placebo');
    expect(t.lookup('/data/SiyamPSGData/LD_Pi_03/FA7312Q6.EEG')?['Age'], '41');
    expect(t.matchRecording('/x/study_night2_final.edf')?.matchedBy, 'part of file name');
    expect(t.lookup('/x/other.edf'), isNull);
  });

  test('guessKeyColumn picks the column that matches recordings', () async {
    final csv = File('${dir.path}/meta.tsv')
      ..writeAsStringSync('Group\tFile\nA\trec1\nB\trec2\n');
    final t = await readBatchMetadataFile(csv.path);
    final key = guessKeyColumn(t.headers, t.rows, ['/d/rec1.edf', '/d/rec2.edf']);
    expect(key, 'File');
  });

  test('XLSX metadata (shared and inline strings, numbers)', () async {
    final archive = Archive();
    void add(String name, String text) {
      final bytes = utf8.encode(text);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add('xl/workbook.xml',
        '<workbook xmlns:r="r"><sheets><sheet name="Subjects" sheetId="1" r:id="rId1"/></sheets></workbook>');
    add('xl/_rels/workbook.xml.rels',
        '<Relationships><Relationship Id="rId1" Type="t" Target="worksheets/sheet1.xml"/></Relationships>');
    add('xl/sharedStrings.xml', '<sst><si><t>File</t></si><si><t>Sex</t></si><si><t>rec1</t></si></sst>');
    add('xl/worksheets/sheet1.xml',
        '<worksheet><sheetData>'
        '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="inlineStr"><is><t>Age</t></is></c></row>'
        '<row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2" t="inlineStr"><is><t>F</t></is></c><c r="C2"><v>34.0</v></c></row>'
        '</sheetData></worksheet>');
    final bytes = ZipEncoder().encodeBytes(archive);
    final path = '${dir.path}/meta.xlsx';
    File(path).writeAsBytesSync(bytes);

    final t = await readBatchMetadataFile(path);
    expect(t.sheetName, 'Subjects');
    expect(t.headers, ['File', 'Sex', 'Age']);
    expect(t.lookup('/d/rec1.edf'), {'File': 'rec1', 'Sex': 'F', 'Age': '34'});
  });

  test('master sheet gets metadata columns', () async {
    final csv = File('${dir.path}/rec1_analyse_regional.csv')
      ..writeAsStringSync('Region,Power\nfrontal,1.5\n');
    final metaFile = File('${dir.path}/m.csv')..writeAsStringSync('Subject ID,Group\nrec1,Placebo\n');
    final meta = await readBatchMetadataFile(metaFile.path);
    final out = await compileRegionalCsvFiles([csv.path], metadata: meta);
    final lines = const LineSplitter().convert(out);
    expect(lines.first, contains('Group'));
    final header = parseCsvLine(lines.first);
    final row = parseCsvLine(lines[1]);
    expect(row[header.indexOf('Subject Identifier')], 'rec1');
    expect(row[header.indexOf('Group')], 'Placebo');
    expect(row[header.indexOf('Power')], '1.5');
  });
}
