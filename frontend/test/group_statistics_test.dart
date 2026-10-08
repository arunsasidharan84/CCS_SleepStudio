import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/group_statistics.dart';

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

  test('backend group_stats.py CLI runs inspection on master sheet', () async {
    const csv1 = '/Users/arunsasidharan/Downloads/MED_AnalyseNidra_master_sheet_07102026.csv';
    if (!File(csv1).existsSync()) return;

    final script = File('backend/group_stats.py').existsSync()
        ? 'backend/group_stats.py'
        : '../backend/group_stats.py';
    final python = Platform.environment['PYTHON'] ?? 'python3';
    final result = await Process.run(python, [
      script,
      '--csv',
      csv1,
      '--inspect-only',
    ]);

    expect(result.exitCode, 0);
    expect(result.stdout, contains('group_col'));
    expect(result.stdout, contains('unique_subjects'));
    expect(result.stdout, contains('metric_columns'));
  });
}
