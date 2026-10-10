import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/regional_csv.dart';

void main() {
  test('parses quoted regional CSV values', () {
    final rows = parseCsvTable('Chan,Subjname\nCentral,"Subject, 01"\n');
    expect(rows.single['Chan'], 'Central');
    expect(rows.single['Subjname'], 'Subject, 01');
  });

  test('compiles multiple regional outputs with source provenance', () async {
    final directory = await Directory.systemTemp.createTemp('analyse_master_');
    final first = await File(
      '${directory.path}/first.csv',
    ).writeAsString('Chan,N2_ACW\nCentral,0.12\n');
    final second = await File(
      '${directory.path}/second.csv',
    ).writeAsString('Chan,N2_ACW\nFrontal,0.18\n');

    final compiled = await compileRegionalCsvFiles([first.path, second.path]);

    expect(
      compiled,
      contains(
        'source_file,source_path,Subject Identifier,Subject Details,Recording Date,Chan,N2_ACW',
      ),
    );
    expect(compiled, contains('first.csv'));
    expect(
      compiled,
      contains('second.csv,${second.absolute.path},,,,Frontal,0.18'),
    );
  });

  test('resolves regional CSV source path to matching EDF path', () async {
    final directory = await Directory.systemTemp.createTemp('analyse_edf_');
    final edf = await File(
      '${directory.path}/AS_CNT_10_Night1.edf',
    ).writeAsString('edf placeholder');
    final regional = await File(
      '${directory.path}/AS_CNT_10_Night1_analyse_regional.csv',
    ).writeAsString('Chan,N2_ACW\nCentral,0.12\n');

    expect(resolveRegionalCsvEdfPath(regional.path), edf.path);
  });

  test('merges companion _cap.json summary metrics into compiled master sheet', () async {
    final directory = await Directory.systemTemp.createTemp('analyse_cap_');
    final regional = await File(
      '${directory.path}/rec01_analyse_regional.csv',
    ).writeAsString('Chan,N2_ACW\nCentral,0.12\n');
    await File(
      '${directory.path}/rec01_cap.json',
    ).writeAsString('{"summary": {"CAP_rate": 45.2, "A_index": 12.3}}');

    final compiled = await compileRegionalCsvFiles([regional.path]);

    expect(compiled, contains('CAP_rate'));
    expect(compiled, contains('CAP_A_index'));
    expect(compiled, contains('45.200'));
    expect(compiled, contains('12.300'));
  });

  test('updateRegionalCsvWithCapMetrics injects CAP metrics into individual regional CSV', () async {
    final directory = await Directory.systemTemp.createTemp('regional_cap_');
    final regional = await File(
      '${directory.path}/rec02_analyse_regional.csv',
    ).writeAsString('Chan,N2_ACW\nCentral,0.12\nFrontal,0.18\n');

    await updateRegionalCsvWithCapMetrics(regional, {
      'CAP_rate': '48.5',
      'CAP_A1_index': '14.2',
    });

    final updated = await regional.readAsString();
    expect(updated, contains('Chan,N2_ACW,CAP_rate,CAP_A1_index'));
    expect(updated, contains('Central,0.12,48.5,14.2'));
    expect(updated, contains('Frontal,0.18,48.5,14.2'));
  });
}
