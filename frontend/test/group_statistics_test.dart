import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/group_statistics.dart';
import 'package:ccs_sleep_studio/src/group_statistics_engine.dart';

void main() {
  testWidgets('renders GroupStatisticsWorkbench shell properly', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: GroupStatisticsWorkbench(),
          ),
        ),
      ),
    );

    expect(find.text('Group-Level Statistical Analysis & Publishing Workbench'), findsOneWidget);
    expect(find.text('Data Source'), findsOneWidget);
    expect(find.text('Batch Analysis Master Sheet (CSV)'), findsOneWidget);
    expect(find.text('Inspect Data'), findsOneWidget);
  });

  test('GroupStatsEngine inspects master sheet in pure Dart without Python', () async {
    const csv1 = '/Users/arunsasidharan/Downloads/MED_AnalyseNidra_master_sheet_07102026.csv';
    final file = File(csv1);
    final String testPath;
    if (file.existsSync()) {
      testPath = csv1;
    } else {
      final tmp = File('${Directory.systemTemp.path}/test_group_stats.csv');
      tmp.writeAsStringSync('''subject,group,channel,alpha_power
s1,Ctrl,C3,10.5
s2,Ctrl,C3,11.2
s3,Stim,C3,15.8
s4,Stim,C3,16.2
''');
      testPath = tmp.path;
    }

    final inspection = await GroupStatsEngine.inspectDataset(csvPath: testPath);
    expect(inspection['total_rows'], greaterThan(0));
    expect(inspection['unique_subjects'], greaterThan(0));
    expect(inspection['metric_columns'], isNotEmpty);
  });
}
