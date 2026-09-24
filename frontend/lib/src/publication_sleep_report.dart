import 'dart:math' as math;

import 'models.dart';
import 'psg_report_data.dart';

class ReportMetadata {
  const ReportMetadata({
    this.title = 'CCS Sleep Studio Sleep EEG Report',
    this.studySite = '',
    this.investigatorName = '',
    this.subjectId = '',
    this.subjectDetails = '',
    this.recordingDate = '',
  });

  final String title;
  final String studySite;
  final String investigatorName;
  final String subjectId;
  final String subjectDetails;
  final String recordingDate;
}

List<int> buildPublicationSleepReport({
  required EegViewport viewport,
  required String recordingName,
  required List<Map<String, String>> regionalRows,
  List<bool> includePages = const [true, true, true, true, true],
  ReportMetadata metadata = const ReportMetadata(),
  Map<String, dynamic>? respiratoryReport,
  Map<String, dynamic>? plmReport,
  Map<String, dynamic>? capReport,
}) {
  final report = _PdfDocument();
  final architecture = regionalRows.isEmpty
      ? <String, String>{}
      : regionalRows.first;
  final regions = regionalRows.isEmpty ? <Map<String, String>>[] : regionalRows;

  final totalPages = includePages.where((b) => b).length +
      (respiratoryReport != null ? 1 : 0) +
      (plmReport != null ? 1 : 0) +
      (capReport != null ? 1 : 0);
  var pageNum = 1;

  if (includePages[0]) {
    report.addPage(
      _buildMacrostructurePage(
        viewport,
        recordingName,
        architecture,
        metadata,
        pageNum++,
        totalPages,
      ),
    );
  }
  if (respiratoryReport != null) {
    report.addPage(
      _buildRespiratoryPage(viewport, respiratoryReport, pageNum++, totalPages),
    );
  }
  if (plmReport != null) {
    report.addPage(_buildPlmPage(viewport, plmReport, pageNum++, totalPages));
  }
  if (capReport != null) {
    report.addPage(_buildCapPage(viewport, capReport, pageNum++, totalPages));
  }
  if (includePages[1]) {
    report.addPage(_buildMicrostructurePage(regions, pageNum++, totalPages));
  }
  if (includePages[2]) {
    report.addPage(_buildAperiodicPage(regions, pageNum++, totalPages));
  }
  if (includePages[3]) {
    report.addPage(_buildComplexityPage(regions, pageNum++, totalPages));
  }
  if (includePages[4]) {
    report.addPage(
      _buildInterpretationPage(
        viewport,
        architecture,
        regions,
        metadata,
        includePages,
        pageNum++,
        totalPages,
      ),
    );
  }
  return report.build();
}

String _buildMacrostructurePage(
  EegViewport viewport,
  String recordingName,
  Map<String, String> row,
  ReportMetadata metadata,
  int pageNum,
  int totalPages,
) {
  final p = _PdfPage();
  final reportTitle = metadata.title.trim().isEmpty
      ? 'CCS Sleep Studio Sleep EEG Report'
      : metadata.title.trim();
  _header(p, reportTitle.toUpperCase(), 'Page $pageNum of $totalPages');

  // Very small filename
  p.text('File: $recordingName', 50, 712, size: 6.5, color: _slate);

  // Subject ID and Recording Date
  final subjectIdText = metadata.subjectId.trim().isNotEmpty
      ? 'Subject Identifier: ${metadata.subjectId.trim()}'
      : 'Subject Identifier: N/A';
  p.text(subjectIdText, 50, 698, bold: true, size: 9, color: _navy);

  final recDateText = metadata.recordingDate.trim().isNotEmpty
      ? 'Recording Date: ${metadata.recordingDate.trim()}'
      : (viewport.recordingStartTime != null
            ? 'Recording Date: ${viewport.recordingStartTime!.toIso8601String().split("T").first}'
            : 'Recording Date: N/A');
  p.text(recDateText, 350, 698, bold: true, size: 9, color: _navy);

  // Subject details
  final detailsText = metadata.subjectDetails.trim().isNotEmpty
      ? 'Subject Details: ${metadata.subjectDetails.trim()}'
      : 'Subject Details: N/A';
  p.text(detailsText, 50, 684, bold: true, size: 9, color: _navy);

  // Study line
  final studyLine = [
    if (metadata.studySite.trim().isNotEmpty)
      'Study site: ${metadata.studySite.trim()}',
    if (metadata.investigatorName.trim().isNotEmpty)
      'Investigator: ${metadata.investigatorName.trim()}',
    '${viewport.epochCount} epochs | ${viewport.epochSeconds}s epoch length',
  ].join('  |  ');
  p.text(studyLine, 50, 672, size: 7.5, color: _slate);

  final cards = <(String, String)>[
    (
      'TRT',
      _metricWithUnit(row, 'TRT', 'min', fallback: _trtMinutes(viewport)),
    ),
    (
      'TST',
      _metricWithUnit(row, 'TST', 'min', fallback: _sleepMinutes(viewport)),
    ),
    (
      'WASO',
      _metricWithUnit(row, 'WASO', 'min', fallback: _wasoMinutes(viewport)),
    ),
    (
      'SOL',
      _metricWithUnit(
        row,
        'SOL',
        'min',
        fallback: _sleepOnsetLatencyMinutes(viewport),
      ),
    ),
    (
      'Sleep efficiency',
      '${_metric(row, 'Sleep_efficiency', fallback: _sleepEfficiency(viewport))}%',
    ),
    (
      'Maintenance efficiency',
      '${_metric(row, 'Sleep_Maintenance_Efficiency', fallback: _maintenanceEfficiency(viewport))}%',
    ),
  ];
  for (var i = 0; i < cards.length; i++) {
    final x = 50.0 + (i % 3) * 172;
    final y = 625.0 - (i ~/ 3) * 53;
    p.rect(x, y, 158, 42, fill: _paleBlue);
    p.text(cards[i].$1, x + 9, y + 27, size: 7.5, color: _slate);
    p.text(cards[i].$2, x + 9, y + 9, bold: true, size: 12, color: _navy);
  }

  p.section('Sleep architecture', 50, 552);
  final stageRows = <(SleepStage, String, String)>[
    (SleepStage.wake, 'Wake', 'W_duration'),
    (SleepStage.n1, 'N1', 'N1_duration'),
    (SleepStage.n2, 'N2', 'N2_duration'),
    (SleepStage.n3, 'N3', 'N3_duration'),
    (SleepStage.rem, 'REM', 'R_duration'),
  ];
  final stageDurations = <SleepStage, double>{
    for (final stageRow in stageRows)
      stageRow.$1:
          _number(row, stageRow.$3) ??
          viewport.stages.where((stage) => stage == stageRow.$1).length *
              viewport.epochSeconds /
              60,
  };
  final totalStageMinutes = stageDurations.values.fold<double>(
    0,
    (sum, duration) => sum + duration,
  );
  final maxDuration = math.max(
    1.0,
    stageDurations.values.fold<double>(0, math.max),
  );
  var y = 520.0;
  for (final stageRow in stageRows) {
    final color = _stageColor(stageRow.$1);
    final duration = stageDurations[stageRow.$1] ?? 0;
    final proportion = totalStageMinutes <= 0
        ? 0.0
        : 100 * duration / totalStageMinutes;
    p.text(stageRow.$2, 52, y + 3, bold: true, size: 8);
    p.rect(88, y, 250 * duration / maxDuration, 12, fill: color);
    p.text(
      '${duration.toStringAsFixed(1)} min (${proportion.toStringAsFixed(1)}%)',
      345,
      y + 2,
      size: 8,
    );
    y -= 20;
  }

  p.section('Full-night hypnogram', 50, 414);
  _hypnogram(p, viewport, 80, 286, 480, 102);

  p.section('Stage latency dashboard (minutes from recording start)', 50, 254);
  final latencyKeys = <(String, String, SleepStage)>[
    ('Wake onset', 'W_onset', SleepStage.wake),
    ('N1 latency', 'N1_onset', SleepStage.n1),
    ('N2 latency', 'N2_onset', SleepStage.n2),
    ('Deep sleep latency', 'N3_onset', SleepStage.n3),
    ('REM latency', 'R_onset', SleepStage.rem),
  ];
  for (var i = 0; i < latencyKeys.length; i++) {
    final x = 50.0 + i * 102;
    p.rect(x, 207, 94, 32, fill: i.isEven ? _paleBlue : _paleGreen);
    p.text(latencyKeys[i].$1, x + 5, 226, size: 6.5, color: _slate);
    final fallbackVal = _stageLatencyMinutes(viewport, latencyKeys[i].$3);
    p.text(
      _metricWithUnit(row, latencyKeys[i].$2, 'min', fallback: fallbackVal),
      x + 5,
      211,
      bold: true,
      size: 10,
    );
  }

  p.section('Stage resilience and fragmentation', 50, 178);
  p.text('Stage', 52, 157, bold: true, size: 7);
  p.text('Longest', 126, 157, bold: true, size: 7);
  p.text('Mean streak', 205, 157, bold: true, size: 7);
  p.text('Median streak', 293, 157, bold: true, size: 7);
  p.text('Continuity profile', 392, 157, bold: true, size: 7);
  var tableY = 139.0;
  for (final stage in ['W', 'N1', 'N2', 'N3', 'R']) {
    final sleepStage = switch (stage) {
      'W' => SleepStage.wake,
      'N1' => SleepStage.n1,
      'N2' => SleepStage.n2,
      'N3' => SleepStage.n3,
      'R' => SleepStage.rem,
      _ => SleepStage.unknown,
    };
    final streaks = _stageStreaks(viewport, sleepStage);
    final fallbackLongest = streaks.isEmpty ? null : streaks.reduce(math.max);
    final fallbackMean = streaks.isEmpty
        ? null
        : streaks.reduce((a, b) => a + b) / streaks.length;
    final fallbackMedian = _median(streaks);

    final longest = _number(row, '${stage}_longest_streak') ?? fallbackLongest;
    final mean = _number(row, '${stage}_mean_length_of_streak') ?? fallbackMean;
    final median =
        _number(row, '${stage}_median_length_of_streak') ?? fallbackMedian;

    p.text(stage == 'R' ? 'REM' : stage, 52, tableY, bold: true, size: 7.5);
    p.text(_format(longest), 126, tableY, size: 7.5);
    p.text(_format(mean), 205, tableY, size: 7.5);
    p.text(_format(median), 293, tableY, size: 7.5);
    final continuity = longest == null ? 0.0 : math.min(longest / 120, 1.0);
    p.rect(392, tableY - 2, 145, 8, fill: _lightGray);
    p.rect(392, tableY - 2, 145 * continuity, 8, fill: _teal);
    tableY -= 18;
  }
  _footer(
    p,
    'Macrostructure values are reported in minutes unless otherwise specified.',
  );
  return p.build();
}

String _buildMicrostructurePage(
  List<Map<String, String>> rows,
  int pageNum,
  int totalPages,
) {
  final p = _PdfPage();
  _header(p, 'THALAMOCORTICAL MICROSTRUCTURE', 'Page $pageNum of $totalPages');
  p.text(
    'Spindle and slow-wave morphometry with phase-amplitude coupling',
    50,
    704,
    size: 9,
    color: _slate,
  );

  p.section('Regional spindle and slow-wave morphometry', 50, 675);
  const columns = [
    ('Region', 52.0),
    ('Spindles', 122.0),
    ('Density/min', 182.0),
    ('Spindle Hz', 252.0),
    ('Slow waves', 322.0),
    ('SW PTP uV', 390.0),
    ('SW slope', 462.0),
  ];
  for (final column in columns) {
    p.text(column.$1, column.$2, 650, bold: true, size: 7);
  }
  var y = 629.0;
  for (final row in rows.take(8)) {
    p.rect(
      50,
      y - 5,
      512,
      18,
      fill: ((629 - y) ~/ 18).isEven ? _white : _offWhite,
    );
    p.text(row['Chan'] ?? '-', 52, y, bold: true, size: 7.5);
    p.text(_metric(row, 'sp_Count', decimals: 0), 122, y, size: 7.5);
    p.text(_metric(row, 'sp_density'), 182, y, size: 7.5);
    p.text(_metric(row, 'sp_Frequency'), 252, y, size: 7.5);
    p.text(_metric(row, 'sw_all_Count', decimals: 0), 322, y, size: 7.5);
    p.text(_metric(row, 'sw_all_PTP'), 390, y, size: 7.5);
    p.text(_metric(row, 'sw_all_Slope'), 462, y, size: 7.5);
    y -= 18;
  }

  p.section('Phasic spindle-slow wave coupling', 50, 480);
  p.text('Region', 52, 457, bold: true, size: 7);
  p.text('PAC MI', 106, 457, bold: true, size: 7);
  p.text('gcPAC', 156, 457, bold: true, size: 7);
  p.text('ndPAC', 204, 457, bold: true, size: 7);
  p.text('MVL', 252, 457, bold: true, size: 7);
  p.text('PLV', 296, 457, bold: true, size: 7);
  p.text('Phase R', 340, 457, bold: true, size: 7);
  p.text('Sp / SW Hz', 388, 457, bold: true, size: 7);
  p.text('Sigma-peak phase', 470, 457, bold: true, size: 7);
  y = 435;
  for (final row in rows.take(6)) {
    p.text(row['Chan'] ?? '-', 52, y, bold: true, size: 7.5);
    p.text(_metric(row, 'pac_all_max_MI', decimals: 4), 106, y, size: 7.2);
    p.text(_metric(row, 'pac_all_max_gcPAC', decimals: 4), 156, y, size: 7.2);
    p.text(_metric(row, 'sw_all_ndPAC', decimals: 4), 204, y, size: 7.2);
    p.text(_metric(row, 'sw_all_MVL', decimals: 3), 252, y, size: 7.2);
    p.text(_metric(row, 'sw_all_PLV', decimals: 3), 296, y, size: 7.2);
    p.text(_metric(row, 'sw_all_PhaseConsistency', decimals: 3), 340, y, size: 7.2);
    p.text(
      '${_metric(row, 'pac_all_max_sp')} / ${_metric(row, 'pac_all_max_sw')}',
      388,
      y,
      size: 7.2,
    );
    p.text(_metric(row, 'sw_all_PhaseAtSigmaPeak'), 470, y, size: 7.2);
    y -= 18;
  }
  p.text(
    'MVL: amplitude-normalised mean vector length (Canolty 2006); PLV: SO phase vs sigma-envelope phase locking (Penny 2008); '
    'Phase R: consistency of the spindle-peak phase across slow oscillations.',
    50,
    y + 6,
    size: 6,
    color: _slate,
  );

  p.section('Spatial coupling comparison', 50, 315);
  final selected = rows.take(3).toList();
  for (var i = 0; i < selected.length; i++) {
    final row = selected[i];
    final cx = 130.0 + i * 175;
    final cy = 205.0;
    final phase = _number(row, 'sw_all_PhaseAtSigmaPeak') ?? 0;
    final mi = _number(row, 'pac_all_max_MI') ?? 0;
    final ndPac = _number(row, 'sw_all_ndPAC') ?? 0;
    p.circle(cx, cy, 48, stroke: _lightGray);
    p.line(cx - 48, cy, cx + 48, cy, color: _lightGray);
    p.line(cx, cy - 48, cx, cy + 48, color: _lightGray);
    p.line(
      cx,
      cy,
      cx + math.cos(phase) * 43,
      cy + math.sin(phase) * 43,
      color: _purple,
      width: 2,
    );
    p.circle(
      cx,
      cy,
      math.min(38, 8 + mi.abs() * 1000),
      fill: _purple.withAlpha(36),
    );
    p.text(row['Chan'] ?? 'Region', cx - 26, 266, bold: true, size: 9);
    p.text('MI ${mi.toStringAsFixed(4)}', cx - 32, 141, size: 7.5);
    p.text('ndPAC ${ndPac.toStringAsFixed(4)}', cx - 38, 129, size: 7.5);
    final mvl = _number(row, 'sw_all_MVL');
    final plv = _number(row, 'sw_all_PLV');
    if (mvl != null || plv != null) {
      p.text(
        'MVL ${mvl?.toStringAsFixed(3) ?? '-'} | PLV ${plv?.toStringAsFixed(3) ?? '-'}',
        cx - 44,
        117,
        size: 7.5,
      );
    }
  }
  p.text(
    'Polar vectors indicate sigma peak phase on the slow-wave cycle. Rightward = 0 rad; upward = pi/2 rad.',
    50,
    92,
    size: 7.5,
    color: _slate,
  );
  _footer(
    p,
    'PAC metrics characterize timing and strength of thalamocortical coordination.',
  );
  return p.build();
}

String _buildAperiodicPage(
  List<Map<String, String>> rows,
  int pageNum,
  int totalPages,
) {
  final p = _PdfPage();
  _header(
    p,
    'NEURAL EXCITABILITY & APERIODIC TRENDS',
    'Page $pageNum of $totalPages',
  );
  p.text(
    'FOOOF and IRASA parameterization separates periodic peaks from the 1/f background',
    50,
    704,
    size: 9,
    color: _slate,
  );

  p.section('Stage-wise aperiodic trajectory (regional mean)', 50, 675);
  final stages = ['W', 'N1', 'N2', 'N3', 'REM'];
  final fooofExponent = [
    for (final stage in stages) _regionalMean(rows, '${stage}_exponent_FOOOF'),
  ];
  final irasaSlope = [
    for (final stage in stages) _regionalMean(rows, '${stage}_slope_Irasa'),
  ];
  _lineChart(
    p,
    x: 70,
    y: 505,
    width: 460,
    height: 130,
    labels: stages,
    series: [
      ('FOOOF exponent', fooofExponent, _blue),
      ('IRASA slope', irasaSlope, _orange),
    ],
  );

  p.section('Aperiodic parameterization and model validation', 50, 470);
  p.text('Stage', 52, 447, bold: true, size: 6.5);
  p.text('FOOOF offset', 92, 447, bold: true, size: 6.5);
  p.text('FOOOF exponent', 165, 447, bold: true, size: 6.5);
  p.text('FOOOF error', 245, 447, bold: true, size: 6.5);
  p.text('IRASA intercept', 310, 447, bold: true, size: 6.5);
  p.text('IRASA slope', 385, 447, bold: true, size: 6.5);
  p.text('IRASA R2', 452, 447, bold: true, size: 6.5);
  p.text('IRASA AUC', 510, 447, bold: true, size: 6.5);
  var y = 426.0;
  for (final stage in stages) {
    p.text(stage, 52, y, bold: true, size: 7.5);
    p.text(
      _format(_regionalMean(rows, '${stage}_offset_FOOOF')),
      92,
      y,
      size: 7.5,
    );
    p.text(
      _format(_regionalMean(rows, '${stage}_exponent_FOOOF')),
      165,
      y,
      size: 7.5,
    );
    p.text(
      _format(_regionalMean(rows, '${stage}_error_FOOOF')),
      245,
      y,
      size: 7.5,
    );
    p.text(
      _format(_regionalMean(rows, '${stage}_intercept_Irasa')),
      310,
      y,
      size: 7.5,
    );
    p.text(
      _format(_regionalMean(rows, '${stage}_slope_Irasa')),
      385,
      y,
      size: 7.5,
    );
    p.text(
      _format(_regionalMean(rows, '${stage}_rsquared_Irasa')),
      452,
      y,
      size: 7.2,
    );
    p.text(
      _format(_regionalMean(rows, '${stage}_auc_Irasa')),
      510,
      y,
      size: 7.2,
    );
    y -= 20;
  }

  p.section(
    'True oscillatory peaks after 1/f removal (regional mean)',
    50,
    330,
  );
  p.text('Stage', 52, 307, bold: true, size: 7);
  p.text('Peak 1 CF', 105, 307, bold: true, size: 7);
  p.text('Peak 1 power', 175, 307, bold: true, size: 7);
  p.text('Peak 1 BW', 255, 307, bold: true, size: 7);
  p.text('Peak 2 CF', 325, 307, bold: true, size: 7);
  p.text('Peak 2 power', 395, 307, bold: true, size: 7);
  p.text('Peak 2 BW', 480, 307, bold: true, size: 7);
  y = 285;
  for (final stage in stages) {
    p.text(stage, 52, y, bold: true, size: 7.5);
    for (var peak = 0; peak < 2; peak++) {
      final x = peak == 0 ? 105.0 : 325.0;
      p.text(
        _format(_regionalMean(rows, '${stage}_cf_${peak}_FOOOF')),
        x,
        y,
        size: 7.5,
      );
      p.text(
        _format(_regionalMean(rows, '${stage}_pw_${peak}_FOOOF')),
        x + 70,
        y,
        size: 7.5,
      );
      p.text(
        _format(_regionalMean(rows, '${stage}_bw_${peak}_FOOOF')),
        x + 150,
        y,
        size: 7.5,
      );
    }
    y -= 20;
  }

  p.section('Frequency-band relative PSD (regional mean)', 50, 185);
  const bands = [
    ('Delta', ['Delta']),
    ('Theta', ['Theta']),
    ('Sigma', ['Sigma', 'ThetaAlpha']),
    ('Alpha', ['Alpha']),
    ('Beta1', ['Beta1']),
    ('Beta2', ['Beta2']),
    ('Gamma1', ['Gamma1']),
  ];
  p.text('Stage', 52, 162, bold: true, size: 6.5);
  for (var i = 0; i < bands.length; i++) {
    p.text(bands[i].$1, 98 + i * 64, 162, bold: true, size: 6.5);
  }
  y = 143;
  for (final stage in stages.where((stage) => stage != 'W')) {
    p.text(stage, 52, y, bold: true, size: 7.2);
    for (var i = 0; i < bands.length; i++) {
      final value = _regionalMeanAny(rows, [
        for (final band in bands[i].$2) '${stage}_${band}_PSD',
      ]);
      p.text(_format(value), 98 + i * 64, y, size: 7.2);
    }
    y -= 18;
  }
  _footer(
    p,
    'PSD values are relative band powers; aperiodic parameters should be interpreted alongside fit quality.',
  );
  return p.build();
}

String _buildComplexityPage(
  List<Map<String, String>> rows,
  int pageNum,
  int totalPages,
) {
  final p = _PdfPage();
  _header(p, 'CORTICAL COMPLEXITY LANDSCAPE', 'Page $pageNum of $totalPages');
  p.text(
    'Information theory, fractal dynamics, long-range correlations, compression, and temporal memory',
    50,
    704,
    size: 9,
    color: _slate,
  );

  final selectedRows = rows.take(3).toList();
  final stages = ['W', 'N1', 'N2', 'N3', 'REM'];
  _heatmap(
    p,
    title: 'Signal entropy profile',
    x: 50,
    y: 650,
    width: 245,
    height: 120,
    rows: selectedRows,
    stages: stages,
    metrics: const [
      'perm_entropy_nonlinear',
      'svd_entropy_nonlinear',
      'sample_entropy_nonlinear',
    ],
  );
  _heatmap(
    p,
    title: 'Fractal dimension and LRTC',
    x: 317,
    y: 650,
    width: 245,
    height: 120,
    rows: selectedRows,
    stages: stages,
    metrics: const [
      'dfa_nonlinear',
      'petrosian_nonlinear',
      'katz_nonlinear',
      'higuchi_nonlinear',
    ],
  );

  p.section(
    'Information compression: global LZc versus stage-wise Lempel-Ziv',
    50,
    480,
  );
  p.text('Region', 52, 457, bold: true, size: 7);
  p.text('Global LZc', 125, 457, bold: true, size: 7);
  for (var i = 0; i < stages.length; i++) {
    p.text(stages[i], 220 + i * 72, 457, bold: true, size: 7);
  }
  var y = 435.0;
  for (final row in selectedRows) {
    p.text(row['Chan'] ?? '-', 52, y, bold: true, size: 7.5);
    p.text(_metric(row, 'LZc', decimals: 3), 125, y, size: 7.5);
    for (var i = 0; i < stages.length; i++) {
      p.text(
        _metric(row, '${stages[i]}_lziv_nonlinear', decimals: 3),
        220 + i * 72,
        y,
        size: 7.5,
      );
    }
    y -= 21;
  }

  p.section('Autocorrelation window: temporal processing memory', 50, 315);
  final acwSeries = <(String, List<double?>, _PdfColor)>[];
  for (var i = 0; i < selectedRows.length; i++) {
    final row = selectedRows[i];
    acwSeries.add((
      row['Chan'] ?? 'Region ${i + 1}',
      [for (final stage in stages) _number(row, '${stage}_ACW')],
      [_blue, _orange, _green][i % 3],
    ));
  }
  _lineChart(
    p,
    x: 70,
    y: 125,
    width: 460,
    height: 145,
    labels: stages,
    series: acwSeries,
  );

  p.text(
    'Higher entropy and fractal metrics indicate less predictable dynamics. DFA summarizes long-range temporal correlations;',
    50,
    94,
    size: 7.5,
    color: _slate,
  );
  p.text(
    'ACW estimates temporal integration persistence.',
    50,
    84,
    size: 7.5,
    color: _slate,
  );
  _footer(
    p,
    'Complexity metrics are descriptive qEEG measures and are not standalone diagnostic biomarkers.',
  );
  return p.build();
}

String _buildInterpretationPage(
  EegViewport viewport,
  Map<String, String> architecture,
  List<Map<String, String>> rows,
  ReportMetadata metadata,
  List<bool> includePages,
  int pageNum,
  int totalPages,
) {
  final p = _PdfPage();
  _header(p, 'UNDERSTANDING YOUR RESULTS', 'Page $pageNum of $totalPages');
  p.text(
    'A plain-language guide to the measurements in this report',
    50,
    704,
    size: 9,
    color: _slate,
  );

  var y = 670.0;
  if (includePages[0]) {
    y = _interpretationBlock(
      p,
      'Sleep amount and continuity',
      _architectureInterpretation(viewport, architecture),
      y,
    );
    y = _interpretationBlock(
      p,
      'Sleep stages',
      _stageInterpretation(viewport, architecture),
      y,
    );
  }
  if (includePages[1] && _hasMicrostructure(rows)) {
    y = _interpretationBlock(
      p,
      'Spindles, slow waves, and their timing',
      _microstructureInterpretation(rows, architecture),
      y,
    );
  }
  if (includePages[2] && _hasAperiodic(rows)) {
    y = _interpretationBlock(
      p,
      'Background spectrum and oscillatory peaks',
      _aperiodicInterpretation(rows),
      y,
    );
  }
  if (includePages[3] && _hasComplexity(rows)) {
    y = _interpretationBlock(
      p,
      'Complexity and temporal memory',
      _complexityInterpretation(rows),
      y,
    );
  }
  if (y == 670.0) {
    y = _interpretationBlock(
      p,
      'Selected report content',
      'The selected PDF pages do not include quantitative sections with enough available analysis data for a detailed clinical summary.',
      y,
    );
  }

  final availableRegions = rows
      .map((row) => row['Chan']?.trim())
      .whereType<String>()
      .where((value) => value.isNotEmpty)
      .join(', ');
  _interpretationBlock(
    p,
    'Important limitations',
    'This automated report summarizes ${availableRegions.isEmpty ? 'the available EEG channels' : availableRegions}. '
        'Automated staging and qEEG measurements can be affected by artifacts, '
        'electrode quality, montage selection, and missing data. Results should '
        'be reviewed with the original recording by a qualified sleep or EEG '
        'professional and should not be used alone for diagnosis or treatment.',
    y,
  );

  final identity = [
    if (metadata.studySite.trim().isNotEmpty) metadata.studySite.trim(),
    if (metadata.investigatorName.trim().isNotEmpty)
      metadata.investigatorName.trim(),
    if (metadata.subjectId.trim().isNotEmpty) metadata.subjectId.trim(),
  ].join(' | ');
  _footer(
    p,
    identity.isEmpty
        ? 'Review this report together with the full polysomnographic record and clinical history.'
        : identity,
  );
  return p.build();
}

String _architectureInterpretation(
  EegViewport viewport,
  Map<String, String> architecture,
) {
  final tst = _number(architecture, 'TST') ?? _sleepMinutes(viewport);
  final trt =
      _number(architecture, 'TRT') ?? viewport.totalDurationSeconds / 60;
  final efficiency =
      _number(architecture, 'Sleep_efficiency') ??
      (trt > 0 ? 100 * tst / trt : null);
  if (efficiency == null) {
    return 'The architecture page shows how recording time was divided among '
        'wake and sleep stages. Longer uninterrupted stage streaks suggest more '
        'continuous sleep; short repeated streaks suggest more transitions.';
  }
  final continuity = efficiency >= 85
      ? 'Most of the recorded period was spent asleep.'
      : 'A meaningful part of the recorded period was spent awake or transitioning between stages.';
  final sol = _number(architecture, 'SOL');
  final waso = _number(architecture, 'WASO');
  final streaks = <(String, double)>[];
  for (final stage in const ['N1', 'N2', 'N3', 'R']) {
    final value = _number(architecture, '${stage}_longest_streak');
    if (value != null) streaks.add((stage == 'R' ? 'REM' : stage, value));
  }
  streaks.sort((a, b) => b.$2.compareTo(a.$2));
  final continuityValues = <String>[
    if (sol != null) 'sleep-onset latency ${sol.toStringAsFixed(1)} min',
    if (waso != null) 'wake after sleep onset ${waso.toStringAsFixed(1)} min',
    if (streaks.isNotEmpty)
      'longest sleep-stage streak ${streaks.first.$1} '
          '${streaks.first.$2.toStringAsFixed(1)} min',
  ].join(', ');
  return 'Estimated total sleep time was ${tst.toStringAsFixed(1)} minutes, '
      'with sleep efficiency of ${efficiency.toStringAsFixed(1)}%. '
      '${continuityValues.isEmpty ? '' : '$continuityValues. '}$continuity '
      'Sleep efficiency alone does not identify the reason for wakefulness or '
      'fragmentation.';
}

String _stageInterpretation(
  EegViewport viewport,
  Map<String, String> architecture,
) {
  final tst = _number(architecture, 'TST') ?? _sleepMinutes(viewport);
  final stages = <(String, double)>[];
  for (final stage in const ['N1', 'N2', 'N3', 'R']) {
    final duration = _number(architecture, '${stage}_duration');
    if (duration != null) stages.add((stage == 'R' ? 'REM' : stage, duration));
  }
  if (stages.isEmpty || tst <= 0) {
    return 'Stage-specific durations were not available for this recording. '
        'Review the hypnogram for the observed sequence of N1, N2, N3, REM, and wake.';
  }
  stages.sort((a, b) => b.$2.compareTo(a.$2));
  final dominant = stages.first;
  final shares = stages
      .map(
        (item) =>
            '${item.$1} ${item.$2.toStringAsFixed(1)} min '
            '(${(100 * item.$2 / tst).toStringAsFixed(1)}%)',
      )
      .join(', ');
  final remLatency = _number(architecture, 'R_onset');
  final n3Latency = _number(architecture, 'N3_onset');
  final latencies = <String>[
    if (n3Latency != null) 'N3 onset ${n3Latency.toStringAsFixed(1)} min',
    if (remLatency != null) 'REM onset ${remLatency.toStringAsFixed(1)} min',
  ].join('; ');
  return '$shares. ${dominant.$1} was the largest sleep-stage component in this recording. '
      '${latencies.isEmpty ? '' : '$latencies. '}'
      'These are within-recording observations, not age-adjusted reference classifications.';
}

String _microstructureInterpretation(
  List<Map<String, String>> rows,
  Map<String, String> architecture,
) {
  final spindleDensity = _rowMean(rows, 'sp_density');
  final nremMinutes = _number(architecture, 'NREM_duration');
  final slowWaveDensity =
      _rowMean(rows, 'sw_all_density_calc') ??
      ((nremMinutes ?? 0) > 0
          ? (_rowMean(rows, 'sw_all_Count') ?? 0) / nremMinutes!
          : null);
  final mi = _rowMean(rows, 'pac_all_max_MI');
  final ndPac = _rowMean(rows, 'sw_all_ndPAC');
  final phase = _rowMean(rows, 'sw_all_PhaseAtSigmaPeak');
  final strongest = _regionalExtreme(rows, 'pac_all_max_MI', highest: true);
  final values = <String>[
    if (spindleDensity != null)
      'mean spindle density ${spindleDensity.toStringAsFixed(2)}/min',
    if (slowWaveDensity != null)
      'slow-wave density ${slowWaveDensity.toStringAsFixed(2)}/NREM min',
    if (mi != null) 'PAC MI ${mi.toStringAsFixed(4)}',
    if (ndPac != null) 'ndPAC ${ndPac.toStringAsFixed(4)}',
    if (_rowMean(rows, 'sw_all_MVL') != null)
      'mean vector length ${_rowMean(rows, 'sw_all_MVL')!.toStringAsFixed(3)}',
    if (_rowMean(rows, 'sw_all_PLV') != null)
      'phase-locking value ${_rowMean(rows, 'sw_all_PLV')!.toStringAsFixed(3)}',
    if (phase != null) 'sigma-peak phase ${phase.toStringAsFixed(2)} rad',
  ];
  if (values.isEmpty) {
    return 'Spindle, slow-wave, and coupling values were not available in the supplied analysis output.';
  }
  final region = strongest == null
      ? ''
      : ' The highest regional PAC MI was in ${strongest.$1} '
            '(${strongest.$2.toStringAsFixed(4)}).';
  return '${values.join(', ')}.$region Phase direction depends on the analysis convention; '
      'regional differences describe this recording and are not diagnostic thresholds.';
}

String _aperiodicInterpretation(List<Map<String, String>> rows) {
  final exponent = _stageMeans(rows, 'exponent_FOOOF');
  final slope = _stageMeans(rows, 'slope_Irasa');
  final fit = _stageMeans(rows, 'rsquared_Irasa');
  if (exponent.isEmpty && slope.isEmpty) {
    return 'No stage-wise FOOOF or IRASA parameters were available in the supplied analysis output.';
  }
  final exponentRange = _metricRange(exponent, 'FOOOF exponent');
  final slopeRange = _metricRange(slope, 'IRASA slope');
  final fitText = fit.isEmpty
      ? ''
      : ' IRASA R2 ranged from ${fit.values.reduce(math.min).toStringAsFixed(3)} '
            'to ${fit.values.reduce(math.max).toStringAsFixed(3)}; lower-fit stages warrant more caution.';
  return '${[exponentRange, slopeRange].where((text) => text.isNotEmpty).join(' ')}$fitText '
      'The direction summarizes stage differences within this subject after regional averaging.';
}

String _complexityInterpretation(List<Map<String, String>> rows) {
  final entropy = _stageMeans(rows, 'perm_entropy_nonlinear');
  final dfa = _stageMeans(rows, 'dfa_nonlinear');
  final acw = _stageMeans(rows, 'ACW');
  final lzc = _rowMean(rows, 'LZc');
  if (entropy.isEmpty && dfa.isEmpty && acw.isEmpty && lzc == null) {
    return 'Complexity and temporal-memory values were not available in the supplied analysis output.';
  }
  final parts = <String>[
    if (entropy.isNotEmpty) _metricRange(entropy, 'permutation entropy'),
    if (dfa.isNotEmpty) _metricRange(dfa, 'DFA'),
    if (acw.isNotEmpty) _metricRange(acw, 'ACW'),
    if (lzc != null) 'Global LZc was ${lzc.toStringAsFixed(3)}.',
  ];
  return '${parts.join(' ')} Higher entropy indicates less predictable signal structure, while ACW '
      'reflects longer or shorter temporal persistence; neither direction is inherently better.';
}

bool _hasMicrostructure(List<Map<String, String>> rows) {
  return _rowMean(rows, 'sp_density') != null ||
      _rowMean(rows, 'sw_all_density_calc') != null ||
      _rowMean(rows, 'sw_all_Count') != null ||
      _rowMean(rows, 'pac_all_max_MI') != null ||
      _rowMean(rows, 'sw_all_ndPAC') != null;
}

bool _hasAperiodic(List<Map<String, String>> rows) {
  return _stageMeans(rows, 'exponent_FOOOF').isNotEmpty ||
      _stageMeans(rows, 'slope_Irasa').isNotEmpty ||
      _stageMeans(rows, 'rsquared_Irasa').isNotEmpty ||
      _regionalMeanAny(rows, const [
            'N1_Delta_PSD',
            'N2_Delta_PSD',
            'N3_Delta_PSD',
            'REM_Delta_PSD',
          ]) !=
          null;
}

bool _hasComplexity(List<Map<String, String>> rows) {
  return _stageMeans(rows, 'perm_entropy_nonlinear').isNotEmpty ||
      _stageMeans(rows, 'dfa_nonlinear').isNotEmpty ||
      _stageMeans(rows, 'ACW').isNotEmpty ||
      _rowMean(rows, 'LZc') != null;
}

double? _rowMean(List<Map<String, String>> rows, String key) {
  final values = rows
      .map((row) => _number(row, key))
      .whereType<double>()
      .toList();
  if (values.isEmpty) return null;
  return values.reduce((a, b) => a + b) / values.length;
}

Map<String, double> _stageMeans(List<Map<String, String>> rows, String suffix) {
  final result = <String, double>{};
  for (final stage in const ['W', 'N1', 'N2', 'N3', 'REM']) {
    final value = _rowMean(rows, '${stage}_$suffix');
    if (value != null) result[stage] = value;
  }
  return result;
}

(String, double)? _regionalExtreme(
  List<Map<String, String>> rows,
  String key, {
  required bool highest,
}) {
  final available = <(String, double)>[];
  for (final row in rows) {
    final value = _number(row, key);
    if (value != null) available.add((row['Chan'] ?? 'Unknown region', value));
  }
  if (available.isEmpty) return null;
  available.sort((a, b) => a.$2.compareTo(b.$2));
  return highest ? available.last : available.first;
}

String _metricRange(Map<String, double> values, String label) {
  if (values.isEmpty) return '';
  final ordered = values.entries.toList()
    ..sort((a, b) => a.value.compareTo(b.value));
  if (ordered.length == 1) {
    return '$label was ${ordered.first.value.toStringAsFixed(3)} in ${ordered.first.key}.';
  }
  return '$label was lowest in ${ordered.first.key} '
      '(${ordered.first.value.toStringAsFixed(3)}) and highest in ${ordered.last.key} '
      '(${ordered.last.value.toStringAsFixed(3)}).';
}

double _interpretationBlock(_PdfPage p, String title, String body, double y) {
  p.rect(50, y - 92, 512, 94, fill: _offWhite);
  p.text(title, 62, y - 18, bold: true, size: 10, color: _navy);
  _wrappedText(p, body, 62, y - 36, maxCharacters: 92);
  return y - 104;
}

void _wrappedText(
  _PdfPage p,
  String text,
  double x,
  double y, {
  int maxCharacters = 90,
  double size = 7.5,
  double lineHeight = 11,
}) {
  final words = text.split(RegExp(r'\s+'));
  var line = '';
  var lineY = y;
  for (final word in words) {
    final candidate = line.isEmpty ? word : '$line $word';
    if (candidate.length > maxCharacters && line.isNotEmpty) {
      p.text(line, x, lineY, size: size, color: _charcoal);
      line = word;
      lineY -= lineHeight;
    } else {
      line = candidate;
    }
  }
  if (line.isNotEmpty) p.text(line, x, lineY, size: size, color: _charcoal);
}

void _header(_PdfPage p, String title, String page) {
  p.rect(36, 724, 540, 48, fill: _navy);
  p.text(title, 52, 749, bold: true, size: 14, color: _white);
  p.text(
    'CCS Sleep Studio | AnalyseNidra quantitative report',
    52,
    733,
    size: 8,
    color: _sky,
  );
  p.text(page, 520, 733, size: 8, color: _sky);
}

void _footer(_PdfPage p, String note) {
  p.line(50, 58, 562, 58, color: _lightGray);
  p.text(note, 50, 42, size: 6.8, color: _slate);
}

void _hypnogram(
  _PdfPage p,
  EegViewport viewport,
  double x,
  double y,
  double width,
  double height,
) {
  const yMin = -4.0;
  const yMax = 2.5;
  const yRange = yMax - yMin;
  double plotY(double value) => y + height * (value - yMin) / yRange;

  p.rect(x, y, width, height, fill: _offWhite, stroke: _lightGray);
  const labels = <(double, String)>[
    (2.0, 'Event'),
    (1.0, 'W'),
    (0.0, 'REM'),
    (-1.0, 'N1'),
    (-2.0, 'N2'),
    (-3.0, 'N3'),
  ];
  for (final (value, label) in labels) {
    if (label != 'Event') {
      p.line(x, plotY(value), x + width, plotY(value), color: _lightGray);
    }
    final labelY = label == 'Event' ? plotY(value) : plotY(value - 0.5);
    p.text(label, x - 31, labelY - 2, size: 6.5);
  }
  if (viewport.stages.isEmpty) return;

  final epochWidth = width / viewport.stages.length;
  for (var i = 0; i < viewport.stages.length; i++) {
    final stage = viewport.stages[i];
    final stageValue = _stagePlotValue(stage);
    if (stageValue == null || stage == SleepStage.unknown) continue;
    final x0 = x + i * epochWidth;
    final x1 = x0 + math.max(epochWidth, 0.35);
    final bottom = plotY(stageValue - 0.95);
    final top = plotY(stageValue);
    p.rect(x0, bottom, x1 - x0, top - bottom, fill: _stageColor(stage));
    if (i < viewport.stagesUncertain.length && viewport.stagesUncertain[i]) {
      p.rect(x0, bottom, x1 - x0, top - bottom, stroke: _orange);
      p.line(x0, bottom, x1, top, color: _orange, width: 0.7);
    }
  }

  final fullNightSeconds = viewport.stages.length * 30.0;
  if (fullNightSeconds > 0) {
    for (final event in viewport.scoredEvents) {
      final start = math
          .min(event.startSec, event.endSec)
          .clamp(0.0, fullNightSeconds)
          .toDouble();
      final end = math
          .max(event.startSec, event.endSec)
          .clamp(0.0, fullNightSeconds)
          .toDouble();
      if (end <= start) continue;
      final x1 = x + width * start / fullNightSeconds;
      final x2 = x + width * end / fullNightSeconds;
      p.rect(
        x1,
        plotY(2.0) - 3,
        math.max(1.2, x2 - x1),
        6,
        fill: _eventColor(event.digit),
      );
    }

    final ticks = _hypnogramTimeTicks(
      fullNightSeconds,
      viewport.eegPanelTimeUnit,
      viewport.recordingStartTime,
    );
    for (final (label, fraction) in ticks) {
      final tx = x + width * fraction;
      p.line(tx, y, tx, y - 3, color: _slate, width: 0.35);
      p.text(label, tx - 8, y - 12, size: 6.2, color: _slate);
    }
  }
}

double? _stagePlotValue(SleepStage stage) => switch (stage) {
  SleepStage.wake => 1.0,
  SleepStage.rem => 0.0,
  SleepStage.n1 => -1.0,
  SleepStage.n2 => -2.0,
  SleepStage.n3 => -3.0,
  SleepStage.inconclusive => 2.0,
  SleepStage.unknown => null,
};

List<(String, double)> _hypnogramTimeTicks(
  double totalSeconds,
  String eegPanelTimeUnit,
  DateTime? recordingStartTime,
) {
  const steps = [3600.0, 1800.0, 900.0, 600.0, 300.0, 180.0, 120.0, 60.0];
  var step = 3600.0;
  for (final candidate in steps) {
    if (totalSeconds / candidate >= 2) {
      step = candidate;
      break;
    }
  }

  final isClockTime =
      eegPanelTimeUnit == 'Clock time' && recordingStartTime != null;

  return [
    for (var seconds = step; seconds < totalSeconds; seconds += step)
      (
        () {
          if (isClockTime) {
            final tickTime = recordingStartTime.add(
              Duration(seconds: seconds.round()),
            );
            final h = tickTime.hour.toString().padLeft(2, '0');
            final m = tickTime.minute.toString().padLeft(2, '0');
            return '$h:$m';
          } else {
            final hours = (seconds / 3600).floor();
            final minutes = ((seconds % 3600) / 60).round();
            return minutes == 0
                ? '${hours}h'
                : '${hours}h${minutes.toString().padLeft(2, '0')}';
          }
        }(),
        seconds / totalSeconds,
      ),
  ];
}

void _lineChart(
  _PdfPage p, {
  required double x,
  required double y,
  required double width,
  required double height,
  required List<String> labels,
  required List<(String, List<double?>, _PdfColor)> series,
}) {
  final values = series
      .expand((item) => item.$2)
      .whereType<double>()
      .where((value) => value.isFinite)
      .toList();
  final minValue = values.isEmpty ? 0.0 : values.reduce(math.min);
  final maxValue = values.isEmpty ? 1.0 : values.reduce(math.max);
  final range = math.max(maxValue - minValue, 1e-6);
  p.rect(x, y, width, height, stroke: _lightGray);
  for (var i = 0; i < labels.length; i++) {
    final px = labels.length == 1 ? x : x + width * i / (labels.length - 1);
    p.line(px, y, px, y + height, color: _lightGray, width: 0.25);
    p.text(labels[i], px - 8, y - 13, size: 7);
  }
  for (var s = 0; s < series.length; s++) {
    final points = <(double, double)>[];
    for (var i = 0; i < series[s].$2.length; i++) {
      final value = series[s].$2[i];
      if (value == null || !value.isFinite) continue;
      final px = x + width * i / math.max(1, labels.length - 1);
      final py = y + (value - minValue) / range * height;
      points.add((px, py));
      p.circle(px, py, 2.6, fill: series[s].$3);
    }
    p.polyline(points, color: series[s].$3, width: 1.5);
    final legendX = x + s * 145;
    p.line(
      legendX,
      y + height + 14,
      legendX + 18,
      y + height + 14,
      color: series[s].$3,
      width: 2,
    );
    p.text(series[s].$1, legendX + 23, y + height + 11, size: 7);
  }
  p.text(maxValue.toStringAsFixed(2), x - 34, y + height - 3, size: 6.5);
  p.text(minValue.toStringAsFixed(2), x - 34, y - 2, size: 6.5);
}

void _heatmap(
  _PdfPage p, {
  required String title,
  required double x,
  required double y,
  required double width,
  required double height,
  required List<Map<String, String>> rows,
  required List<String> stages,
  required List<String> metrics,
}) {
  p.text(title, x, y, bold: true, size: 9, color: _navy);
  p.text('Stage mean across metrics', x, y - 11, size: 6, color: _slate);
  final cells = <(String, double?)>[];
  for (final row in rows) {
    for (final stage in stages) {
      final values = [
        for (final metric in metrics) _number(row, '${stage}_$metric'),
      ].whereType<double>().toList();
      cells.add((
        '${row['Chan'] ?? '-'} $stage',
        values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length,
      ));
    }
  }
  final numeric = cells.map((cell) => cell.$2).whereType<double>().toList();
  final hasNumeric = numeric.isNotEmpty;
  final minValue = numeric.isEmpty ? 0.0 : numeric.reduce(math.min);
  final maxValue = numeric.isEmpty ? 1.0 : numeric.reduce(math.max);
  final range = math.max(maxValue - minValue, 1e-9);
  const labelWidth = 42.0;
  final gridX = x + labelWidth;
  final gridWidth = width - labelWidth;
  final cellWidth = gridWidth / math.max(1, stages.length);
  final rowSlots = math.max(3, rows.length);
  final cellHeight = (height - 60) / rowSlots;
  for (var c = 0; c < stages.length; c++) {
    p.text(
      stages[c],
      gridX + c * cellWidth + cellWidth / 2 - 5,
      y - 24,
      bold: true,
      size: 6.5,
    );
  }
  for (var r = 0; r < rows.length; r++) {
    final rowY = y - 60 - r * cellHeight;
    p.text(rows[r]['Chan'] ?? '-', x, rowY + cellHeight / 2, size: 6.3);
    for (var c = 0; c < stages.length; c++) {
      final value = cells[r * stages.length + c].$2;
      final t = value == null ? 0.0 : (value - minValue) / range;
      final color = value == null ? _lightGray : _heatColor(t);
      p.rect(
        gridX + c * cellWidth,
        rowY,
        cellWidth - 2,
        cellHeight - 2,
        fill: color,
      );
      final valueText = value == null ? '-' : value.toStringAsFixed(2);
      p.text(
        valueText,
        gridX + c * cellWidth + cellWidth / 2 - valueText.length * 1.55,
        rowY + cellHeight / 2 - 2,
        size: 5.8,
        color: value != null && t > 0.6 ? _white : _charcoal,
      );
    }
  }
  const colorSteps = 24;
  final colorBarX = gridX;
  final colorBarY = y - 60 - rows.length * cellHeight - 18;
  final colorBarWidth = gridWidth;
  final colorStepWidth = colorBarWidth / colorSteps;
  if (!hasNumeric) {
    p.text('No available data', colorBarX, colorBarY, size: 6, color: _slate);
  } else {
    for (var i = 0; i < colorSteps; i++) {
      p.rect(
        colorBarX + i * colorStepWidth,
        colorBarY,
        colorStepWidth + 0.2,
        6,
        fill: _heatColor(i / (colorSteps - 1)),
      );
    }
    p.text(
      minValue.toStringAsFixed(2),
      colorBarX,
      colorBarY - 10,
      size: 5.5,
      color: _slate,
    );
    p.text('Low', colorBarX + 30, colorBarY - 10, size: 5.5, color: _slate);
    p.text(
      'High',
      colorBarX + colorBarWidth - 48,
      colorBarY - 10,
      size: 5.5,
      color: _slate,
    );
    p.text(
      maxValue.toStringAsFixed(2),
      colorBarX + colorBarWidth - 24,
      colorBarY - 10,
      size: 5.5,
      color: _slate,
    );
  }
}

double _sleepMinutes(EegViewport viewport) {
  return viewport.stages
          .where(
            (stage) =>
                stage == SleepStage.n1 ||
                stage == SleepStage.n2 ||
                stage == SleepStage.n3 ||
                stage == SleepStage.rem,
          )
          .length *
      viewport.epochSeconds /
      60;
}

double _trtMinutes(EegViewport viewport) {
  final lightsOffSec = viewport.lightsOffSeconds ?? 0.0;
  final lightsOnSec = viewport.lightsOnSeconds ?? viewport.totalDurationSeconds;
  return (lightsOnSec - lightsOffSec) / 60;
}

double _sleepOnsetLatencyMinutes(EegViewport viewport) {
  final lightsOffSec = viewport.lightsOffSeconds ?? 0.0;
  final startEpoch = (lightsOffSec / viewport.epochSeconds).floor();
  final stages = viewport.stages;
  for (var i = startEpoch; i < stages.length; i++) {
    final stage = stages[i];
    if (stage == SleepStage.n1 ||
        stage == SleepStage.n2 ||
        stage == SleepStage.n3 ||
        stage == SleepStage.rem) {
      return (i * viewport.epochSeconds - lightsOffSec) / 60;
    }
  }
  return 0.0;
}

double _wasoMinutes(EegViewport viewport) {
  final lightsOffSec = viewport.lightsOffSeconds ?? 0.0;
  final lightsOnSec =
      viewport.lightsOnSeconds ?? (viewport.totalDurationSeconds);
  final startEpoch = (lightsOffSec / viewport.epochSeconds).floor();
  final endEpoch = (lightsOnSec / viewport.epochSeconds).floor().clamp(
    0,
    viewport.stages.length,
  );

  // Find sleep onset
  var sleepOnsetIdx = -1;
  for (var i = startEpoch; i < endEpoch; i++) {
    final stage = viewport.stages[i];
    if (stage == SleepStage.n1 ||
        stage == SleepStage.n2 ||
        stage == SleepStage.n3 ||
        stage == SleepStage.rem) {
      sleepOnsetIdx = i;
      break;
    }
  }
  if (sleepOnsetIdx < 0) return 0.0;

  var wakeEpochs = 0;
  for (var i = sleepOnsetIdx; i < endEpoch; i++) {
    if (viewport.stages[i] == SleepStage.wake) {
      wakeEpochs++;
    }
  }
  return wakeEpochs * viewport.epochSeconds / 60;
}

double _sleepEfficiency(EegViewport viewport) {
  final trt = _trtMinutes(viewport);
  if (trt <= 0) return 0.0;
  return (_sleepMinutes(viewport) / trt) * 100;
}

double _maintenanceEfficiency(EegViewport viewport) {
  final tst = _sleepMinutes(viewport);
  final waso = _wasoMinutes(viewport);
  if (tst + waso <= 0) return 0.0;
  return (tst / (tst + waso)) * 100;
}

double? _stageLatencyMinutes(EegViewport viewport, SleepStage target) {
  final lightsOffSec = viewport.lightsOffSeconds ?? 0.0;
  final startEpoch = (lightsOffSec / viewport.epochSeconds).floor();
  final idx = viewport.stages.indexWhere(
    (stage) => stage == target,
    startEpoch,
  );
  if (idx < 0) return null;
  return (idx * viewport.epochSeconds - lightsOffSec) / 60;
}

List<double> _stageStreaks(EegViewport viewport, SleepStage target) {
  final streaks = <double>[];
  var currentStreak = 0;
  for (final stage in viewport.stages) {
    if (stage == target) {
      currentStreak++;
    } else {
      if (currentStreak > 0) {
        streaks.add(currentStreak * viewport.epochSeconds / 60);
        currentStreak = 0;
      }
    }
  }
  if (currentStreak > 0) {
    streaks.add(currentStreak * viewport.epochSeconds / 60);
  }
  return streaks;
}

double? _median(List<double> list) {
  if (list.isEmpty) return null;
  final sorted = List<double>.from(list)..sort();
  final mid = sorted.length ~/ 2;
  if (sorted.length % 2 != 0) {
    return sorted[mid];
  } else {
    return (sorted[mid - 1] + sorted[mid]) / 2;
  }
}

double? _regionalMean(List<Map<String, String>> rows, String key) {
  final values = rows
      .map((row) => _number(row, key))
      .whereType<double>()
      .where((value) => value.isFinite)
      .toList();
  return values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length;
}

double? _regionalMeanAny(List<Map<String, String>> rows, List<String> keys) {
  for (final key in keys) {
    final value = _regionalMean(rows, key);
    if (value != null) return value;
  }
  return null;
}

double? _number(Map<String, String> row, String key) {
  var raw = row[key]?.trim();
  if ((raw == null || raw.isEmpty) && key.startsWith('sp_')) {
    raw = row['sp_all_${key.substring(3)}']?.trim();
  } else if ((raw == null || raw.isEmpty) && key.startsWith('sp_all_')) {
    raw = row['sp_${key.substring(7)}']?.trim();
  }
  if (raw == null || raw.isEmpty || raw.toLowerCase() == 'nan') return null;
  final value = double.tryParse(raw);
  return value != null && value.isFinite ? value : null;
}

String _metric(
  Map<String, String> row,
  String key, {
  int decimals = 1,
  double? fallback,
}) {
  final value = _number(row, key) ?? fallback;
  return value == null ? '-' : value.toStringAsFixed(decimals);
}

String _metricWithUnit(
  Map<String, String> row,
  String key,
  String unit, {
  int decimals = 1,
  double? fallback,
}) {
  final value = _metric(row, key, decimals: decimals, fallback: fallback);
  return value == '-' ? value : '$value $unit';
}

String _format(double? value, {int decimals = 3}) =>
    value == null ? '-' : value.toStringAsFixed(decimals);

_PdfColor _stageColor(SleepStage stage) => switch (stage) {
  SleepStage.wake => const _PdfColor(0.34, 0.75, 0.55),
  SleepStage.rem => const _PdfColor(0.55, 0.75, 0.34),
  SleepStage.n1 => const _PdfColor(0.67, 0.74, 0.81),
  SleepStage.n2 => const _PdfColor(0.25, 0.36, 0.47),
  SleepStage.n3 => const _PdfColor(0.04, 0.11, 0.17),
  SleepStage.inconclusive => _charcoal,
  SleepStage.unknown => _lightGray,
};

_PdfColor _eventColor(int digit) {
  const colors = [
    _PdfColor(1.00, 0.78, 0.78),
    _PdfColor(0.39, 0.58, 0.93),
    _PdfColor(0.60, 0.98, 0.60),
    _PdfColor(1.00, 1.00, 0.40),
    _PdfColor(0.25, 0.88, 0.82),
    _PdfColor(0.58, 0.40, 0.74),
    _PdfColor(0.55, 0.34, 0.29),
    _PdfColor(0.89, 0.47, 0.76),
    _PdfColor(0.50, 0.50, 0.50),
    _PdfColor(0.74, 0.74, 0.13),
    _PdfColor(1.00, 0.65, 0.00),
    _PdfColor(0.29, 0.00, 0.51),
    _PdfColor(1.00, 0.41, 0.71),
    _PdfColor(0.78, 0.16, 0.16), // 13 obstructive apnea
    _PdfColor(0.08, 0.40, 0.75), // 14 central apnea
    _PdfColor(0.42, 0.11, 0.60), // 15 mixed apnea
    _PdfColor(0.94, 0.42, 0.00), // 16 hypopnea
    _PdfColor(0.98, 0.66, 0.15), // 17 RERA
    _PdfColor(0.00, 0.59, 0.65), // 18 desaturation
    _PdfColor(0.49, 0.70, 0.26), // 19 leg movement
    _PdfColor(0.11, 0.37, 0.13), // 20 PLM
    _PdfColor(0.01, 0.66, 0.96), // 21 CAP A1
    _PdfColor(1.00, 0.60, 0.00), // 22 CAP A2
    _PdfColor(0.91, 0.12, 0.39), // 23 CAP A3
    _PdfColor(0.47, 0.33, 0.28), // 24 CAP sequence
  ];
  return colors[digit.clamp(0, colors.length - 1)];
}

_PdfColor _heatColor(double t) {
  final clamped = t.clamp(0.0, 1.0);
  return _PdfColor(
    0.13 + 0.70 * clamped,
    0.32 + 0.35 * (1 - (clamped - 0.5).abs() * 2),
    0.72 - 0.55 * clamped,
  );
}

const _navy = _PdfColor(0.05, 0.18, 0.31);
const _sky = _PdfColor(0.75, 0.86, 0.96);
const _slate = _PdfColor(0.28, 0.36, 0.45);
const _charcoal = _PdfColor(0.08, 0.10, 0.13);
const _white = _PdfColor(1, 1, 1);
const _offWhite = _PdfColor(0.97, 0.98, 0.99);
const _lightGray = _PdfColor(0.82, 0.85, 0.88);
const _paleBlue = _PdfColor(0.94, 0.97, 1);
const _paleGreen = _PdfColor(0.94, 0.98, 0.95);
const _blue = _PdfColor(0.10, 0.35, 0.65);
const _orange = _PdfColor(0.90, 0.48, 0.12);
const _green = _PdfColor(0.12, 0.58, 0.35);
const _red = _PdfColor(0.78, 0.18, 0.20);
const _purple = _PdfColor(0.48, 0.20, 0.67);
const _teal = _PdfColor(0.10, 0.55, 0.56);

class _PdfColor {
  const _PdfColor(this.r, this.g, this.b, [this.alpha = 255]);

  final double r;
  final double g;
  final double b;
  final int alpha;

  _PdfColor withAlpha(int value) => _PdfColor(r, g, b, value);

  String get fill => '${_blend(r)} ${_blend(g)} ${_blend(b)} rg';
  String get stroke => '${_blend(r)} ${_blend(g)} ${_blend(b)} RG';

  double _blend(double channel) {
    final opacity = alpha / 255;
    return channel * opacity + (1 - opacity);
  }
}

class _PdfPage {
  final List<String> _commands = [];

  void text(
    String text,
    double x,
    double y, {
    bool bold = false,
    double size = 10,
    _PdfColor color = _charcoal,
  }) {
    final font = bold ? '/F2' : '/F1';
    final escaped = text
        .replaceAll('\\', '\\\\')
        .replaceAll('(', r'\(')
        .replaceAll(')', r'\)')
        .replaceAll('µ', 'u')
        .replaceAll('κ', 'k')
        .replaceAll('π', 'pi')
        .replaceAll('₂', '2')
        .replaceAll('≥', '>=')
        .replaceAll('≤', '<=')
        .replaceAll('–', '-')
        .replaceAll('—', '-')
        .replaceAll('−', '-')
        .replaceAll('·', '.')
        .replaceAll('Δ', 'delta ')
        .replaceAll('↓', '')
        .replaceAll('’', "'")
        .replaceAll(RegExp(r'[^\x00-\xFF]'), '?');
    _commands.add('BT ${color.fill} $font $size Tf $x $y Td ($escaped) Tj ET');
  }

  void section(String title, double x, double y) {
    text(title, x, y, bold: true, size: 10.5, color: _navy);
    line(x, y - 5, 562, y - 5, color: _lightGray);
  }

  void rect(
    double x,
    double y,
    double width,
    double height, {
    _PdfColor? fill,
    _PdfColor? stroke,
  }) {
    if (fill != null) {
      _commands.add('${fill.fill} $x $y $width $height re f');
    }
    if (stroke != null) {
      _commands.add('${stroke.stroke} 0.5 w $x $y $width $height re S');
    }
  }

  void line(
    double x1,
    double y1,
    double x2,
    double y2, {
    _PdfColor color = _charcoal,
    double width = 0.5,
  }) {
    _commands.add('${color.stroke} $width w $x1 $y1 m $x2 $y2 l S');
  }

  void circle(
    double cx,
    double cy,
    double radius, {
    _PdfColor? fill,
    _PdfColor? stroke,
  }) {
    const k = 0.5522847498;
    final c = radius * k;
    final path =
        '${cx + radius} $cy m '
        '${cx + radius} ${cy + c} ${cx + c} ${cy + radius} $cx ${cy + radius} c '
        '${cx - c} ${cy + radius} ${cx - radius} ${cy + c} ${cx - radius} $cy c '
        '${cx - radius} ${cy - c} ${cx - c} ${cy - radius} $cx ${cy - radius} c '
        '${cx + c} ${cy - radius} ${cx + radius} ${cy - c} ${cx + radius} $cy c';
    if (fill != null) _commands.add('${fill.fill} $path f');
    if (stroke != null) _commands.add('${stroke.stroke} 0.5 w $path S');
  }

  void polyline(
    List<(double, double)> points, {
    _PdfColor color = _charcoal,
    double width = 0.5,
  }) {
    if (points.length < 2) return;
    final path = StringBuffer('${points.first.$1} ${points.first.$2} m');
    for (final point in points.skip(1)) {
      path.write(' ${point.$1} ${point.$2} l');
    }
    _commands.add('${color.stroke} $width w $path S');
  }

  String build() => _commands.join('\n');
}

class _PdfDocument {
  final List<String> _pages = [];

  void addPage(String page) => _pages.add(page);

  List<int> build() {
    final numPages = _pages.length;
    final font1 = 2 * numPages + 3;
    final font2 = 2 * numPages + 4;
    final kids = List.generate(numPages, (i) => '${2 * i + 3} 0 R').join(' ');
    final objects = <String>[
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [$kids] /Count $numPages >>',
    ];
    for (var i = 0; i < numPages; i++) {
      final content = _pages[i];
      final contentIndex = 2 * i + 4;
      objects.add(
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
        '/Resources << /Font << /F1 $font1 0 R /F2 $font2 0 R >> >> '
        '/Contents $contentIndex 0 R >>',
      );
      objects.add(
        '<< /Length ${content.length} >>\nstream\n$content\nendstream',
      );
    }
    objects.add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
    objects.add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>');

    final buffer = StringBuffer('%PDF-1.4\n');
    final offsets = <int>[0];
    for (var i = 0; i < objects.length; i++) {
      offsets.add(buffer.length);
      buffer.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
    }
    final xref = buffer.length;
    buffer.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
    for (final offset in offsets.skip(1)) {
      buffer.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
    }
    buffer.write(
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
      'startxref\n$xref\n%%EOF\n',
    );
    return buffer.toString().codeUnits;
  }
}

// ─── Respiratory & PLM pages (from analyse-nidra JSON sidecars) ─────────────

double? _jsonNum(Map? map, String key) {
  final v = map?[key];
  return v is num && v.isFinite ? v.toDouble() : null;
}

String _jsonFmt(Map? map, String key, {int decimals = 1, String unit = ''}) {
  final v = _jsonNum(map, key);
  return v == null ? '-' : '${v.toStringAsFixed(decimals)}$unit';
}

void _psgCards(_PdfPage p, List<(String, String)> cards, double y) {
  for (var i = 0; i < cards.length; i++) {
    final x = 50.0 + i * 86;
    p.rect(x, y, 80, 40, fill: i.isEven ? _paleBlue : _paleGreen);
    p.text(cards[i].$1, x + 6, y + 27, size: 6.5, color: _slate);
    p.text(cards[i].$2, x + 6, y + 9, bold: true, size: 11, color: _navy);
  }
}

double _psgTable(
  _PdfPage p,
  List<(String, List<(String, String)>)> sections,
  double x,
  double y, {
  double width = 250,
}) {
  for (final section in sections) {
    p.text(section.$1, x, y, bold: true, size: 8, color: _navy);
    y -= 4;
    p.line(x, y, x + width, y, color: _lightGray);
    y -= 10;
    for (final row in section.$2) {
      p.text(row.$1, x + 2, y, size: 6.8, color: _charcoal);
      p.text(row.$2, x + width * 0.66, y, bold: true, size: 6.8, color: _charcoal);
      y -= 8.8;
    }
    y -= 6;
  }
  return y;
}

/// Event raster rows aligned with the hypnogram above them.
void _eventRaster(
  _PdfPage p, {
  required double x,
  required double y,
  required double width,
  required double durationSec,
  required List<(String, _PdfColor, List<(double, double)>)> rows,
}) {
  const rowHeight = 9.0;
  for (var r = 0; r < rows.length; r++) {
    final ry = y - r * rowHeight;
    p.text(rows[r].$1, x - 31, ry + 1, size: 6.2, color: _slate);
    p.line(x, ry + 3.5, x + width, ry + 3.5, color: _lightGray, width: 0.25);
    for (final (a, b) in rows[r].$3) {
      final s = a.clamp(0.0, durationSec);
      final e = b.clamp(0.0, durationSec);
      if (e < s) continue;
      final x1 = x + width * s / durationSec;
      final x2 = x + width * e / durationSec;
      p.rect(x1, ry, math.max(0.8, x2 - x1), 7, fill: rows[r].$2);
    }
  }
}

List<(double, double)> _spans(Iterable<dynamic> items, bool Function(Map) keep) => [
  for (final e in items)
    if (e is Map && keep(e))
      (
        (e['start'] as num?)?.toDouble() ?? 0,
        (e['end'] as num?)?.toDouble() ?? 0,
      ),
];

String _buildRespiratoryPage(
  EegViewport viewport,
  Map<String, dynamic> report,
  int pageNum,
  int totalPages,
) {
  final p = _PdfPage();
  _header(p, 'RESPIRATORY EVENTS & OXIMETRY', 'Page $pageNum of $totalPages');
  final summary = report['summary'] as Map?;
  final flags = report['flags'] as Map?;
  final channels = report['channels'] as Map?;
  p.text(
    'AASM Scoring Manual v3 | ${flags?['hypopnea_rule'] ?? ''} | '
    'apnea sensor: ${channels?['apnea_sensor'] ?? '-'} | hypopnea sensor: ${channels?['hypopnea_sensor'] ?? '-'}',
    50,
    704,
    size: 6.8,
    color: _slate,
  );
  _psgCards(p, [
    ('AHI (/h)', _jsonFmt(summary, 'AHI')),
    ('ODI 3% (/h)', _jsonFmt(summary, 'ODI3')),
    ('T90 (% TST)', _jsonFmt(summary, 'T90_pct')),
    ('SpO2 nadir', _jsonFmt(summary, 'SpO2_min_sleep', decimals: 0, unit: '%')),
    ('Hypoxic burden', _jsonFmt(summary, 'hypoxic_burden_pct_min_per_h', decimals: 0)),
    ('Pulse response', _jsonFmt(summary, 'delta_HR_bpm', unit: ' bpm')),
  ], 650);
  p.text(
    'Severity: ${flags?['severity'] ?? '-'}   |   hypoxic burden in %min/h   |   pulse response = mean event-related heart-rate rise',
    50,
    638,
    size: 6.5,
    color: _slate,
  );

  p.section('Overnight respiratory timeline', 50, 622);
  const x = 80.0;
  const width = 480.0;
  _hypnogram(p, viewport, x, 522, width, 88);
  final duration = math.max(1.0, viewport.stages.length * 30.0);
  final events = (report['events'] as List?) ?? const [];
  bool counted(Map e) => e['counted'] == true;
  String kind(Map e) => (e['kind'] ?? '').toString().toLowerCase();
  _eventRaster(
    p,
    x: x,
    y: 500,
    width: width,
    durationSec: duration,
    rows: [
      ('OA', _eventColor(kDigitObstructiveApnea), _spans(events, (e) => counted(e) && kind(e).contains('apnea') && !kind(e).contains('central') && !kind(e).contains('mixed'))),
      ('CA', _eventColor(kDigitCentralApnea), _spans(events, (e) => counted(e) && kind(e).contains('central apnea'))),
      ('MA', _eventColor(kDigitMixedApnea), _spans(events, (e) => counted(e) && kind(e).contains('mixed'))),
      ('Hyp', _eventColor(kDigitHypopnea), _spans(events, (e) => counted(e) && kind(e).contains('hypopnea'))),
      ('RERA', _eventColor(kDigitRera), _spans(events, (e) => counted(e) && kind(e).contains('rera'))),
      ('Desat', _eventColor(kDigitDesaturation), _spans((report['desaturations'] as List?) ?? const [], (e) => e['in_sleep'] != false)),
    ],
  );

  // SpO2 trace (per-epoch minimum) aligned with the hypnogram.
  final epochs = report['epochs'] as Map?;
  final spo2 = [
    for (final v in (epochs?['spo2_min'] as List? ?? const []))
      v is num && v.isFinite && v > 0 ? v.toDouble() : null,
  ];
  const sy = 368.0;
  const sh = 70.0;
  final present = spo2.whereType<double>().toList();
  final lo = present.isEmpty ? 80.0 : math.min(88.0, (present.reduce(math.min) / 5).floor() * 5.0);
  const hi = 100.0;
  double py(double v) => sy + sh * (v.clamp(lo, hi) - lo) / (hi - lo);
  p.rect(x, sy, width, sh, fill: _offWhite, stroke: _lightGray);
  p.line(x, py(90), x + width, py(90), color: _red, width: 0.3);
  p.text('90%', x + width + 3, py(90) - 2, size: 6, color: _red);
  p.text('SpO2', x - 31, sy + sh - 8, size: 6.5);
  p.text('${hi.toStringAsFixed(0)}%', x - 31, sy + sh - 17, size: 5.8, color: _slate);
  p.text('${lo.toStringAsFixed(0)}%', x - 31, sy, size: 5.8, color: _slate);
  if (spo2.isNotEmpty) {
    final epochSec = 30.0;
    var run = <(double, double)>[];
    void flush() {
      p.polyline(run, color: _teal, width: 0.6);
      run = <(double, double)>[];
    }
    for (var i = 0; i < spo2.length; i++) {
      final v = spo2[i];
      if (v == null) {
        flush();
        continue;
      }
      final px = x + width * math.min(1.0, (i + 0.5) * epochSec / duration);
      run.add((px, py(v)));
    }
    flush();
  }

  p.section('Recommended and novel respiratory parameters', 50, 350);
  final sections = respiratorySummarySections(report);
  _psgTable(p, sections.take(2).toList(), 50, 332);
  _psgTable(p, sections.skip(2).toList(), 312, 332);

  p.section('Interpretation', 50, 132);
  _wrappedText(p, respiratoryInterpretation(report), 52, 116, maxCharacters: 118, size: 7.2, lineHeight: 10);
  _footer(
    p,
    'Automated scoring (AASM v3 rules) by AnalyseNidra; review events against the raw signals before clinical use.',
  );
  return p.build();
}

String _buildPlmPage(
  EegViewport viewport,
  Map<String, dynamic> report,
  int pageNum,
  int totalPages,
) {
  final p = _PdfPage();
  _header(p, 'PERIODIC LIMB MOVEMENTS', 'Page $pageNum of $totalPages');
  final summary = report['summary'] as Map?;
  final settings = report['settings'] as Map?;
  final channels = report['channels'] as Map?;
  p.text(
    '${settings?['standard'] ?? 'AASM'} | left: ${channels?['left_leg'] ?? '-'} | right: ${channels?['right_leg'] ?? '-'} | '
    'onset ${settings?['onset_uV'] ?? '8'} uV, offset ${settings?['offset_uV'] ?? '2'} uV above resting EMG',
    50,
    704,
    size: 6.8,
    color: _slate,
  );
  _psgCards(p, [
    ('PLMS index (/h)', _jsonFmt(summary, 'PLMS_index')),
    ('PLMW index (/h)', _jsonFmt(summary, 'PLMW_index')),
    ('PLMS-arousal (/h)', _jsonFmt(summary, 'PLMS_arousal_index')),
    ('Periodicity index', _jsonFmt(summary, 'periodicity_index', decimals: 2)),
    ('LM index (/h)', _jsonFmt(summary, 'LM_index')),
    ('PLM series (sleep)', _jsonFmt(summary, 'n_PLM_series_sleep', decimals: 0)),
  ], 650);

  p.section('Overnight limb-movement timeline', 50, 622);
  const x = 80.0;
  const width = 480.0;
  _hypnogram(p, viewport, x, 522, width, 88);
  final duration = math.max(1.0, viewport.stages.length * 30.0);
  final moves = (report['movements'] as List?) ?? const [];
  _eventRaster(
    p,
    x: x,
    y: 500,
    width: width,
    durationSec: duration,
    rows: [
      ('PLM', _eventColor(kDigitPlm), _spans(moves, (m) => m['clm'] == true && m['periodic'] == true)),
      ('LM', _eventColor(kDigitLegMovement), _spans(moves, (m) => m['clm'] == true && m['periodic'] != true)),
      ('Resp', _eventColor(kDigitHypopnea), _spans(moves, (m) => m['respiratory'] == true)),
    ],
  );

  // Inter-movement interval histogram.
  final hist = [
    for (final h in (report['imi_histogram'] as List? ?? const []))
      if (h is List && h.length >= 2) (h[0].toString(), (h[1] as num?)?.toDouble() ?? 0.0),
  ];
  p.section('Inter-movement intervals (sleep)', 50, 460);
  if (hist.isNotEmpty) {
    const hx = 60.0;
    const hy = 372.0;
    const hw = 220.0;
    const hh = 66.0;
    final maxCount = math.max(1.0, hist.map((h) => h.$2).reduce(math.max));
    final bw = hw / hist.length;
    p.rect(hx, hy, hw, hh, stroke: _lightGray);
    for (var i = 0; i < hist.length; i++) {
      final bh = hh * hist[i].$2 / maxCount;
      p.rect(hx + i * bw + 1, hy, bw - 2, bh, fill: _teal);
      p.text(hist[i].$1.replaceAll(' s', ''), hx + i * bw, hy - 9, size: 5.2, color: _slate);
      p.text(hist[i].$2.toStringAsFixed(0), hx + i * bw + 2, hy + bh + 2, size: 5.2);
    }
    p.text('seconds', hx + hw - 25, hy - 17, size: 5.8, color: _slate);
  }
  // PLMS index by hour of the night.
  final hourly = [
    for (final h in (report['hourly'] as List? ?? const []))
      if (h is Map) (_jsonNum(h, 'hour') ?? 0, _jsonNum(h, 'PLMS_index') ?? 0.0),
  ];
  p.text('PLMS index by hour of sleep', 330, 446, bold: true, size: 7.5, color: _navy);
  if (hourly.isNotEmpty) {
    const hx = 330.0;
    const hy = 372.0;
    const hw = 220.0;
    const hh = 66.0;
    final maxV = math.max(15.0, hourly.map((h) => h.$2).reduce(math.max));
    final bw = hw / hourly.length;
    p.rect(hx, hy, hw, hh, stroke: _lightGray);
    final y15 = hy + hh * 15 / maxV;
    p.line(hx, y15, hx + hw, y15, color: _red, width: 0.3);
    p.text('15/h', hx + hw + 3, y15 - 2, size: 5.8, color: _red);
    for (var i = 0; i < hourly.length; i++) {
      final bh = hh * hourly[i].$2 / maxV;
      p.rect(hx + i * bw + 1, hy, bw - 2, bh, fill: _eventColor(kDigitPlm));
      p.text(hourly[i].$1.toStringAsFixed(0), hx + i * bw + bw / 2 - 2, hy - 9, size: 5.8, color: _slate);
    }
  }

  p.section('Recommended and novel PLM parameters', 50, 342);
  final sections = plmSummarySections(report);
  _psgTable(p, sections.take(2).toList(), 50, 324);
  _psgTable(p, sections.skip(2).toList(), 312, 324);

  p.section('Interpretation', 50, 132);
  _wrappedText(p, plmInterpretation(report), 52, 116, maxCharacters: 118, size: 7.2, lineHeight: 10);
  _footer(
    p,
    'Automated leg-movement scoring by AnalyseNidra; verify tibialis EMG quality and review scored movements before clinical use.',
  );
  return p.build();
}

void _barChart(
  _PdfPage p, {
  required double x,
  required double y,
  required double width,
  required double height,
  required List<(String, double?)> bars,
  required _PdfColor color,
  double? minMax,
  String unit = '',
}) {
  p.rect(x, y, width, height, stroke: _lightGray);
  if (bars.isEmpty) return;
  final values = bars.map((b) => b.$2 ?? 0.0).toList();
  final maxV = math.max(minMax ?? 1.0, values.reduce(math.max));
  final bw = width / bars.length;
  for (var i = 0; i < bars.length; i++) {
    final v = bars[i].$2;
    final bh = v == null ? 0.0 : height * v / maxV;
    p.rect(x + i * bw + 2, y, bw - 4, bh, fill: color);
    p.text(bars[i].$1, x + i * bw + 2, y - 9, size: 5.8, color: _slate);
    p.text(v == null ? '-' : '${v.toStringAsFixed(0)}$unit', x + i * bw + 2, y + bh + 2, size: 5.6);
  }
}

String _buildCapPage(
  EegViewport viewport,
  Map<String, dynamic> report,
  int pageNum,
  int totalPages,
) {
  final p = _PdfPage();
  _header(p, 'CYCLIC ALTERNATING PATTERN (CAP)', 'Page $pageNum of $totalPages');
  final summary = report['summary'] as Map?;
  final settings = report['settings'] as Map?;
  final channels = report['channels'] as Map?;
  final flags = report['flags'] as Map?;
  p.text(
    'Terzano 2001 rules | ${flags?['method'] ?? ''} | EEG: ${channels?['eeg'] ?? '-'}'
    '${settings?['sensitivity'] == null ? '' : ' | sensitivity: ${settings?['sensitivity']}'}',
    50,
    704,
    size: 6.8,
    color: _slate,
  );
  _psgCards(p, [
    ('CAP rate', _jsonFmt(summary, 'CAP_rate', unit: '%')),
    ('A-phase index (/h)', _jsonFmt(summary, 'A_index')),
    ('A1 share', _jsonFmt(summary, 'A1_pct', decimals: 0, unit: '%')),
    ('A2+A3 index (/h)', _jsonFmt(summary, 'A2A3_index')),
    ('CAP sequences', _jsonFmt(summary, 'n_CAP_sequences', decimals: 0)),
    ('Mean cycle (s)', _jsonFmt(summary, 'CAP_cycle_duration_mean_s')),
  ], 650);

  p.section('Overnight CAP timeline', 50, 622);
  const x = 80.0;
  const width = 480.0;
  _hypnogram(p, viewport, x, 522, width, 88);
  final duration = math.max(1.0, viewport.stages.length * 30.0);
  final phases = (report['a_phases'] as List?) ?? const [];
  bool inSeq(Map a) => a['in_sequence'] == true;
  String sub(Map a) => a['subtype']?.toString() ?? '';
  _eventRaster(
    p,
    x: x,
    y: 500,
    width: width,
    durationSec: duration,
    rows: [
      ('CAP', _eventColor(kDigitCapSequence), _spans((report['sequences'] as List?) ?? const [], (_) => true)),
      ('A1', _eventColor(kDigitCapA1), _spans(phases, (a) => inSeq(a) && sub(a) == 'A1')),
      ('A2', _eventColor(kDigitCapA2), _spans(phases, (a) => inSeq(a) && sub(a) == 'A2')),
      ('A3', _eventColor(kDigitCapA3), _spans(phases, (a) => inSeq(a) && sub(a) == 'A3')),
      ('Isol.', _lightGray, _spans(phases, (a) => !inSeq(a))),
    ],
  );

  p.section('CAP rate by NREM stage', 50, 446);
  _barChart(
    p,
    x: 60,
    y: 372,
    width: 220,
    height: 56,
    bars: [
      ('NREM', _jsonNum(summary, 'CAP_rate')),
      ('N1', _jsonNum(summary, 'CAP_rate_N1')),
      ('N2', _jsonNum(summary, 'CAP_rate_N2')),
      ('N3', _jsonNum(summary, 'CAP_rate_N3')),
      ('1st half', _jsonNum(summary, 'CAP_rate_first_half')),
      ('2nd half', _jsonNum(summary, 'CAP_rate_second_half')),
    ],
    color: _eventColor(kDigitCapA1),
    minMax: 60,
    unit: '%',
  );
  p.text('CAP rate by hour of the night', 330, 446, bold: true, size: 7.5, color: _navy);
  final hourly = [
    for (final h in (report['hourly'] as List? ?? const []))
      if (h is Map) ((_jsonNum(h, 'hour') ?? 0).toStringAsFixed(0), _jsonNum(h, 'CAP_rate')),
  ];
  _barChart(
    p,
    x: 330,
    y: 372,
    width: 220,
    height: 56,
    bars: hourly,
    color: _eventColor(kDigitCapSequence),
    minMax: 60,
  );

  p.section('Recommended and novel CAP parameters', 50, 342);
  final sections = capSummarySections(report);
  _psgTable(p, sections.take(2).toList(), 50, 324);
  _psgTable(p, sections.skip(2).toList(), 312, 324);

  p.section('Interpretation', 50, 132);
  _wrappedText(p, capInterpretation(report), 52, 116, maxCharacters: 118, size: 7.2, lineHeight: 10);
  _footer(
    p,
    'CAP rate = CAP time / NREM time; A-phase indices count A-phases within CAP sequences per hour of NREM sleep.',
  );
  return p.build();
}
