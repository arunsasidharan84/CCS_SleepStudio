import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/group_statistics_engine.dart';

void main() {
  test('GroupStatsEngine inspects CSV and computes statistical models in pure Dart', () async {
    const csvPath = '/Users/arunsasidharan/Downloads/Channel_wise_AnalyseNidra_master_sheet_2026-10-13T130705.csv';
    if (!File(csvPath).existsSync()) return;

    final insp = await GroupStatsEngine.inspectDataset(csvPath: csvPath);
    expect(insp['total_rows'], greaterThan(0));
    expect(insp['group_col'], isNotNull);
    expect(insp['channel_col'], 'Chan');

    final results = await GroupStatsEngine.runAnalysis(
      csvPath: csvPath,
      groupCol: 'ageID',
      subgroupCol: 'Status',
      channelCol: 'Chan',
      subjectIdCol: insp['subject_id'],
      targetMetrics: ['CAP_rate', 'N3_Gamma_Irasa'],
    );

    expect(results['output_dir'], isNotNull);
    final resList = results['results'] as List<dynamic>;
    expect(resList.length, 2);

    final capRes = resList.firstWhere((r) => r['metric'] == 'CAP_rate');
    expect(capRes['is_macroarchitecture'], isTrue);
    final capEffects = capRes['model_effects'] as List<dynamic>;
    expect(capEffects.any((e) => e['term'] == 'ageID'), isTrue);
    expect(capEffects.any((e) => e['term'] == 'Status'), isTrue);

    final gammaRes = resList.firstWhere((r) => r['metric'] == 'N3_Gamma_Irasa');
    expect(gammaRes['is_macroarchitecture'], isFalse);
    expect(gammaRes['etfce_channels'], isNotEmpty);
  });
}
