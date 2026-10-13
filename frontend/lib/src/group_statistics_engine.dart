import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// Statistical distributions and mathematical functions implemented in pure Dart.
class StatMath {
  static const double epsilon = 1e-14;
  static const double tiny = 1e-30;

  /// Logarithm of the Gamma function via Lanczos approximation.
  static double logGamma(double x) {
    const p = [
      0.99999999999980993,
      676.52093408287859,
      -1259.1392167224028,
      771.32342877765313,
      -176.61502916214059,
      12.507343278686905,
      -0.13857109583115912,
      9.9843695780195716e-6,
      1.5056327351493116e-7,
    ];
    if (x < 0.5) {
      return math.log(math.pi / math.sin(math.pi * x)) - logGamma(1.0 - x);
    }
    x -= 1.0;
    var a = p[0];
    final t = x + 7.5;
    for (var i = 1; i < p.length; i++) {
      a += p[i] / (x + i);
    }
    return 0.5 * math.log(2.0 * math.pi) + (x + 0.5) * math.log(t) - t + math.log(a);
  }

  /// Continued fraction for incomplete beta function.
  static double _betacf(double a, double b, double x) {
    const maxIterations = 200;
    final qab = a + b;
    final qap = a + 1.0;
    final qam = a - 1.0;
    var c = 1.0;
    var d = 1.0 - qab * x / qap;
    if (d.abs() < tiny) d = tiny;
    d = 1.0 / d;
    var h = d;

    for (var m = 1; m <= maxIterations; m++) {
      final m2 = 2 * m;
      var aa = m * (b - m) * x / ((qam + m2) * (a + m2));
      d = 1.0 + aa * d;
      if (d.abs() < tiny) d = tiny;
      c = 1.0 + aa / c;
      if (c.abs() < tiny) c = tiny;
      d = 1.0 / d;
      h *= d * c;

      aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2));
      d = 1.0 + aa * d;
      if (d.abs() < tiny) d = tiny;
      c = 1.0 + aa / c;
      if (c.abs() < tiny) c = tiny;
      d = 1.0 / d;
      final del = d * c;
      h *= del;
      if ((del - 1.0).abs() < epsilon) break;
    }
    return h;
  }

  /// Regularized Incomplete Beta Function I_x(a, b).
  static double regularizedIncompleteBeta(double a, double b, double x) {
    if (x <= 0.0) return 0.0;
    if (x >= 1.0) return 1.0;

    final bt = math.exp(logGamma(a + b) - logGamma(a) - logGamma(b) +
        a * math.log(x) + b * math.log(1.0 - x));

    if (x < (a + 1.0) / (a + b + 2.0)) {
      return bt * _betacf(a, b, x) / a;
    } else {
      return 1.0 - bt * _betacf(b, a, 1.0 - x) / b;
    }
  }

  /// Two-tailed p-value for Student's t distribution.
  static double studentTPValue(double t, double df) {
    if (df <= 0) return 1.0;
    final x = df / (df + t * t);
    return regularizedIncompleteBeta(df / 2.0, 0.5, x).clamp(0.0, 1.0);
  }

  /// Upper tail p-value for Fisher's F distribution.
  static double fDistributionPValue(double f, double df1, double df2) {
    if (f <= 0.0 || df1 <= 0 || df2 <= 0) return 1.0;
    final x = df2 / (df2 + df1 * f);
    return regularizedIncompleteBeta(df2 / 2.0, df1 / 2.0, x).clamp(0.0, 1.0);
  }

  /// Benjamini-Hochberg False Discovery Rate (FDR) adjustment.
  static List<double> adjustFDR(List<double> rawPValues) {
    final n = rawPValues.length;
    if (n == 0) return [];
    if (n == 1) return [rawPValues.first];

    final indices = List<int>.generate(n, (i) => i)
      ..sort((a, b) => rawPValues[a].compareTo(rawPValues[b]));

    final adjusted = List<double>.filled(n, 1.0);
    var runningMin = 1.0;

    for (var rank = n; rank >= 1; rank--) {
      final idx = indices[rank - 1];
      final p = rawPValues[idx];
      final adj = (p * n / rank).clamp(0.0, 1.0);
      if (adj < runningMin) runningMin = adj;
      adjusted[idx] = runningMin;
    }

    return adjusted;
  }
}

/// Standard 10-20 EEG electrode positions normalized to a unit scalp circle.
const Map<String, (double, double)> kElectrode1020Positions = {
  'FP1': (-0.30, 0.85),
  'FP2': (0.30, 0.85),
  'F7': (-0.75, 0.55),
  'F3': (-0.40, 0.55),
  'FZ': (0.00, 0.55),
  'F4': (0.40, 0.55),
  'F8': (0.75, 0.55),
  'T3': (-0.90, 0.00),
  'T7': (-0.90, 0.00),
  'C3': (-0.45, 0.00),
  'CZ': (0.00, 0.00),
  'C4': (0.45, 0.00),
  'T4': (0.90, 0.00),
  'T8': (0.90, 0.00),
  'T5': (-0.75, -0.55),
  'P7': (-0.75, -0.55),
  'P3': (-0.40, -0.55),
  'PZ': (0.00, -0.55),
  'P4': (0.40, -0.55),
  'T6': (0.75, -0.55),
  'P8': (0.75, -0.55),
  'O1': (-0.30, -0.85),
  'OZ': (0.00, -0.85),
  'O2': (0.30, -0.85),
};

/// Pure Dart Native Group Statistics Engine (Zero Python Dependencies).
class GroupStatsEngine {
  /// Fast CSV Parser supporting quoted cells.
  static List<List<String>> parseCsvString(String content) {
    final rows = <List<String>>[];
    var currentRow = <String>[];
    final currentField = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < content.length; i++) {
      final char = content[i];

      if (char == '"') {
        if (inQuotes && i + 1 < content.length && content[i + 1] == '"') {
          currentField.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (char == ',' && !inQuotes) {
        currentRow.add(currentField.toString().trim());
        currentField.clear();
      } else if ((char == '\n' || char == '\r') && !inQuotes) {
        if (char == '\r' && i + 1 < content.length && content[i + 1] == '\n') {
          i++;
        }
        currentRow.add(currentField.toString().trim());
        currentField.clear();
        if (currentRow.any((c) => c.isNotEmpty)) {
          rows.add(currentRow);
        }
        currentRow = <String>[];
      } else {
        currentField.write(char);
      }
    }

    if (currentField.isNotEmpty || currentRow.isNotEmpty) {
      currentRow.add(currentField.toString().trim());
      if (currentRow.any((c) => c.isNotEmpty)) {
        rows.add(currentRow);
      }
    }

    return rows;
  }

  /// Inspects CSV and returns metadata schema in pure Dart.
  static Future<Map<String, dynamic>> inspectDataset({
    required String csvPath,
    String? metadataPath,
  }) async {
    final file = File(csvPath);
    if (!file.existsSync()) {
      throw FileSystemException('CSV file not found', csvPath);
    }

    final content = await file.readAsString();
    final rows = parseCsvString(content);
    if (rows.length < 2) {
      throw StateError('CSV contains fewer than 2 rows (header + data).');
    }

    final headers = rows[0];
    final dataRows = rows.sublist(1);

    // Merge external metadata if provided
    var mergedHeaders = List<String>.from(headers);
    var mergedDataRows = dataRows;

    if (metadataPath != null && metadataPath.trim().isNotEmpty) {
      final metaFile = File(metadataPath.trim());
      if (metaFile.existsSync()) {
        final metaContent = await metaFile.readAsString();
        final metaRows = parseCsvString(metaContent);
        if (metaRows.length >= 2) {
          final metaHeaders = metaRows[0];
          final metaKeyCol = metaHeaders.firstWhere(
            (h) => ['subject_id', 'subject', 'subj', 'id', 'sub'].contains(h.toLowerCase().trim()),
            orElse: () => metaHeaders.first,
          );
          final csvSubjIdx = headers.indexWhere(
            (h) => ['subject_id', 'subject', 'subj', 'id', 'sub', 'patient'].contains(h.toLowerCase().trim()),
          );

          if (csvSubjIdx >= 0) {
            final metaKeyIdx = metaHeaders.indexOf(metaKeyCol);
            final metaMap = <String, Map<String, String>>{};
            for (final r in metaRows.sublist(1)) {
              if (r.length > metaKeyIdx) {
                final k = r[metaKeyIdx].trim();
                metaMap[k] = {
                  for (var c = 0; c < metaHeaders.length; c++)
                    if (c != metaKeyIdx && c < r.length) metaHeaders[c]: r[c].trim()
                };
              }
            }

            final extraCols = metaHeaders.where((h) => h != metaKeyCol && !headers.contains(h)).toList();
            mergedHeaders.addAll(extraCols);

            mergedDataRows = dataRows.map((r) {
              final newRow = List<String>.from(r);
              final subjVal = r.length > csvSubjIdx ? r[csvSubjIdx].trim() : '';
              final metaEntry = metaMap[subjVal];
              for (final ec in extraCols) {
                newRow.add(metaEntry?[ec] ?? '');
              }
              return newRow;
            }).toList();
          }
        }
      }
    }

    // Classify columns
    final catCols = <String>[];
    final numCols = <String>[];
    final factorLevels = <String, List<String>>{};
    final factorCounts = <String, Map<String, int>>{};

    final knownCatKeywords = [
      'group', 'cohort', 'arm', 'status', 'condition', 'dx', 'diagnosis',
      'subgroup', 'visit', 'session', 'stage', 'chan', 'channel', 'subsubjname',
      'region', 'electrode', 'sex', 'gender', 'ageid'
    ];

    for (var colIdx = 0; colIdx < mergedHeaders.length; colIdx++) {
      final colName = mergedHeaders[colIdx];
      final colLower = colName.toLowerCase().trim();

      int numericCount = 0;
      final uniqueVals = <String>{};
      final valCounts = <String, int>{};

      for (final row in mergedDataRows) {
        if (colIdx >= row.length) continue;
        final val = row[colIdx].trim();
        if (val.isEmpty || val.toLowerCase() == 'nan' || val.toLowerCase() == 'na') continue;

        uniqueVals.add(val);
        valCounts[val] = (valCounts[val] ?? 0) + 1;

        if (double.tryParse(val) != null) {
          numericCount++;
        }
      }

      final isNumeric = numericCount > (mergedDataRows.length * 0.5) &&
          !knownCatKeywords.any((k) => colLower == k || colLower.contains(k));

      if (isNumeric) {
        numCols.add(colName);
      } else {
        catCols.add(colName);
        final sortedLevels = uniqueVals.toList()..sort();
        factorLevels[colName] = sortedLevels;
        factorCounts[colName] = valCounts;
      }
    }

    // Auto-detect key factor columns
    String? subjectIdCol = catCols.firstWhere(
      (c) => ['subject_id', 'subject', 'subj', 'patient', 'id', 'record_id'].contains(c.toLowerCase().trim()),
      orElse: () => catCols.isNotEmpty ? catCols.first : '',
    );
    if (subjectIdCol.isEmpty) subjectIdCol = null;

    String? channelCol = catCols.firstWhere(
      (c) => ['chan', 'channel', 'subsubjname', 'region', 'electrode', 'derivation'].contains(c.toLowerCase().trim()),
      orElse: () => '',
    );
    if (channelCol.isEmpty) channelCol = null;

    String? groupCol = catCols.firstWhere(
      (c) => c != subjectIdCol && c != channelCol &&
          ['group', 'groupid', 'cohort', 'arm', 'condition', 'status', 'diagnosis', 'ageid'].contains(c.toLowerCase().trim()),
      orElse: () => catCols.firstWhere(
        (c) => c != subjectIdCol && c != channelCol,
        orElse: () => catCols.isNotEmpty ? catCols.first : '',
      ),
    );
    if (groupCol.isEmpty) groupCol = null;

    String? subgroupCol = catCols.firstWhere(
      (c) => c != subjectIdCol && c != groupCol &&
          ['subgroup', 'status', 'condition', 'visit', 'session', 'stage', 'chan', 'channel'].contains(c.toLowerCase().trim()),
      orElse: () => 'None',
    );

    // Identify continuous covariates
    final covariates = numCols.where((c) {
      final l = c.toLowerCase().trim();
      return ['age', 'bmi', 'ahi', 'ess', 'psqi', 'education', 'weight', 'height'].contains(l);
    }).toList();

    // Metric columns (excluding covariates)
    final metricColumns = numCols.where((c) => !covariates.contains(c)).toList();

    // Categorized sleep metrics map
    final catMetrics = <String, List<String>>{
      'Macroarchitecture': metricColumns.where((m) =>
          ['tst', 'se', 'sleep_efficiency', 'waso', 'sol', 'n1', 'n2', 'n3', 'rem', 'r_percentage', 'n3_percentage', 'n2_percentage', 'n1_percentage', 'efficiency'].any((k) => m.toLowerCase().contains(k))
      ).toList(),
      'Sleep Spindles': metricColumns.where((m) => m.toLowerCase().contains('sp_') || m.toLowerCase().contains('spindle')).toList(),
      'Slow Waves': metricColumns.where((m) => m.toLowerCase().contains('sw_') || m.toLowerCase().contains('slow_wave')).toList(),
      'Spectral Power': metricColumns.where((m) => ['psd', 'delta', 'theta', 'alpha', 'sigma', 'beta', 'gamma'].any((k) => m.toLowerCase().contains(k))).toList(),
      'CAP (Cyclic Alternating Pattern)': metricColumns.where((m) => m.toLowerCase().startsWith('cap_')).toList(),
      'Other Metrics': [],
    };
    final categorizedAll = catMetrics.values.expand((x) => x).toSet();
    catMetrics['Other Metrics'] = metricColumns.where((m) => !categorizedAll.contains(m)).toList();
    catMetrics.removeWhere((_, v) => v.isEmpty);

    final uniqueSubjs = subjectIdCol != null
        ? (factorLevels[subjectIdCol]?.length ?? mergedDataRows.length)
        : mergedDataRows.length;

    return {
      'total_rows': mergedDataRows.length,
      'unique_subjects': uniqueSubjs,
      'total_columns': mergedHeaders.length,
      'categorical_columns': catCols,
      'metric_columns': metricColumns,
      'covariates': covariates,
      'filterable_columns': catCols,
      'group_col': groupCol,
      'subgroup_col': subgroupCol,
      'subject_id': subjectIdCol,
      'channel_col': channelCol,
      'factor_levels': factorLevels,
      'factor_counts': factorCounts,
      'categorized_metrics': catMetrics,
    };
  }

  /// Determines whether a metric is a whole-night macroarchitecture / channel-invariant metric.
  static bool isMacroMetric(String metricName) {
    final lower = metricName.toLowerCase().trim();
    if (lower.startsWith('cap_')) return true;
    const macroKeywords = [
      'sleep_efficiency', 'tst', 'waso', 'sol', 'n3_percentage',
      'r_percentage', 'n1_percentage', 'n2_percentage', 'rem_latency',
      'lat_rem', 'lat_n1', 'lat_n2', 'lat_n3', 'total_sleep_time',
      'wake_after_sleep_onset', 'rem_count', 'n3_count'
    ];
    return macroKeywords.any((k) => lower == k || lower.contains(k));
  }

  /// Runs complete group statistical modeling and reporting in pure Dart.
  static Future<Map<String, dynamic>> runAnalysis({
    required String csvPath,
    String? metadataPath,
    required String groupCol,
    String? subgroupCol,
    String? channelCol,
    String? subjectIdCol,
    List<String> extraFactors = const [],
    bool includeInteractions = true,
    List<String> covariates = const [],
    required List<String> targetMetrics,
    Map<String, List<String>> excludedFactorLabels = const {},
    List<Map<String, String>> rowFilters = const [],
    List<String> groupOrder = const [],
    List<String> subgroupOrder = const [],
    String preferredModel = 'auto',
    String posthocMethod = 'fdr',
    void Function(double progress, String status)? onProgress,
  }) async {
    onProgress?.call(0.05, 'Parsing CSV dataset and applying interactive filters…');

    final file = File(csvPath);
    final content = await file.readAsString();
    final rows = parseCsvString(content);
    final headers = rows[0];
    var dataRows = rows.sublist(1);

    // Merge external metadata if provided
    final colMap = {for (var i = 0; i < headers.length; i++) headers[i]: i};

    // Apply interactive row exclusion filters
    if (rowFilters.isNotEmpty) {
      dataRows = dataRows.where((row) {
        for (final rf in rowFilters) {
          final col = rf['column'];
          final op = rf['op'];
          final filterVal = rf['value'] ?? '';
          final idx = colMap[col];
          if (idx == null || idx >= row.length) continue;
          final cellVal = row[idx].trim();

          if (op == 'is_na') {
            if (cellVal.isEmpty || cellVal.toLowerCase() == 'nan' || cellVal.toLowerCase() == 'na') {
              return false;
            }
          } else if (op == '==') {
            if (cellVal == filterVal) return false;
          } else if (op == '!=') {
            if (cellVal != filterVal) return false;
          } else {
            final cellNum = double.tryParse(cellVal);
            final filterNum = double.tryParse(filterVal);
            if (cellNum != null && filterNum != null) {
              if (op == '>' && cellNum > filterNum) return false;
              if (op == '<' && cellNum < filterNum) return false;
              if (op == '>=' && cellNum >= filterNum) return false;
              if (op == '<=' && cellNum <= filterNum) return false;
            }
          }
        }
        return true;
      }).toList();
    }

    // Apply excluded factor labels
    if (excludedFactorLabels.isNotEmpty) {
      dataRows = dataRows.where((row) {
        for (final entry in excludedFactorLabels.entries) {
          final factor = entry.key;
          final excluded = entry.value.toSet();
          final idx = colMap[factor];
          if (idx != null && idx < row.length && excluded.contains(row[idx].trim())) {
            return false;
          }
        }
        return true;
      }).toList();
    }

    // Results container
    final resultsList = <Map<String, dynamic>>[];
    final allPosthocList = <Map<String, dynamic>>[];
    final allDescriptivesList = <Map<String, dynamic>>[];

    final totalMetrics = targetMetrics.length;

    for (var mIdx = 0; mIdx < totalMetrics; mIdx++) {
      final metric = targetMetrics[mIdx];
      final frac = (mIdx + 1) / totalMetrics;
      onProgress?.call(
        0.1 + frac * 0.75,
        'Computing statistical model for $metric (${mIdx + 1}/$totalMetrics)…',
      );

      final metricColIdx = colMap[metric];
      if (metricColIdx == null) continue;

      final isMacro = isMacroMetric(metric);

      // Determine factors for this metric
      final hasSubgroup = subgroupCol != null && subgroupCol != 'None' && subgroupCol != groupCol;
      // Skip channel factor only for macro / CAP metrics!
      final effectiveSubgroupCol = (isMacro && channelCol != null && subgroupCol == channelCol)
          ? null
          : (hasSubgroup ? subgroupCol : null);

      final grpIdx = colMap[groupCol]!;
      final subgrpIdx = effectiveSubgroupCol != null ? colMap[effectiveSubgroupCol] : null;
      final subjIdx = subjectIdCol != null ? colMap[subjectIdCol] : null;
      final chanIdx = channelCol != null ? colMap[channelCol] : null;

      // Filter rows having non-null metric values
      var metricRows = dataRows.where((r) {
        if (metricColIdx >= r.length) return false;
        final v = double.tryParse(r[metricColIdx]);
        if (v == null || v.isNaN || v.isInfinite) return false;
        if (grpIdx >= r.length || r[grpIdx].trim().isEmpty) return false;
        if (subgrpIdx != null && (subgrpIdx >= r.length || r[subgrpIdx].trim().isEmpty)) return false;
        return true;
      }).toList();

      // Deduplicate multi-channel rows for macro / CAP metrics across session
      if (isMacro && channelCol != null) {
        final sessionMap = <String, List<String>>{};
        for (final r in metricRows) {
          final subj = subjIdx != null && subjIdx < r.length ? r[subjIdx].trim() : '';
          final grp = r[grpIdx].trim();
          final subgrp = subgrpIdx != null && subgrpIdx < r.length ? r[subgrpIdx].trim() : '';
          final key = '$subj|$grp|$subgrp';
          if (!sessionMap.containsKey(key)) {
            sessionMap[key] = r;
          }
        }
        metricRows = sessionMap.values.toList();
      }

      if (metricRows.isEmpty) continue;

      // Group observation values
      final cellValues = <String, List<double>>{};
      final groupLevelsSet = <String>{};
      final subgroupLevelsSet = <String>{};
      final subjectSet = <String>{};

      for (final r in metricRows) {
        final val = double.parse(r[metricColIdx]);
        final grp = r[grpIdx].trim();
        final subgrp = subgrpIdx != null ? r[subgrpIdx].trim() : 'ALL';
        final key = subgrpIdx != null ? '$grp|$subgrp' : grp;

        cellValues.putIfAbsent(key, () => []).add(val);
        groupLevelsSet.add(grp);
        if (subgrpIdx != null) subgroupLevelsSet.add(subgrp);
        if (subjIdx != null && subjIdx < r.length) subjectSet.add(r[subjIdx].trim());
      }

      final orderedGroups = groupOrder.isNotEmpty
          ? groupOrder.where((g) => groupLevelsSet.contains(g)).toList()
          : (groupLevelsSet.toList()..sort());
      for (final g in groupLevelsSet) {
        if (!orderedGroups.contains(g)) orderedGroups.add(g);
      }

      final orderedSubgroups = (subgrpIdx != null)
          ? (subgroupOrder.isNotEmpty
              ? subgroupOrder.where((s) => subgroupLevelsSet.contains(s)).toList()
              : (subgroupLevelsSet.toList()..sort()))
          : <String>[];
      if (subgrpIdx != null) {
        for (final s in subgroupLevelsSet) {
          if (!orderedSubgroups.contains(s)) orderedSubgroups.add(s);
        }
      }

      // ─── 1. DESCRIPTIVE STATISTICS ─────────────────────────────
      final metricDescriptives = <Map<String, dynamic>>[];
      for (final grp in orderedGroups) {
        if (subgrpIdx != null) {
          for (final subgrp in orderedSubgroups) {
            final key = '$grp|$subgrp';
            final vals = cellValues[key] ?? [];
            if (vals.isEmpty) continue;
            metricDescriptives.add(_computeCellDescriptive(metric, grp, subgrp, vals));
          }
        } else {
          final vals = cellValues[grp] ?? [];
          if (vals.isEmpty) continue;
          metricDescriptives.add(_computeCellDescriptive(metric, grp, null, vals));
        }
      }
      allDescriptivesList.addAll(metricDescriptives);

      // ─── 2. STATISTICAL MODEL FITTING (ANOVA / LMM) ────────────
      final modelEffects = <Map<String, dynamic>>[];
      final allValues = metricRows.map((r) => double.parse(r[metricColIdx])).toList();
      final totalN = allValues.length;
      final grandMean = allValues.reduce((a, b) => a + b) / totalN;

      if (subgrpIdx == null) {
        // ONE-WAY ANOVA across primary group
        final k = orderedGroups.length;
        var ssBetween = 0.0;
        var ssWithin = 0.0;
        for (final grp in orderedGroups) {
          final vals = cellValues[grp] ?? [];
          if (vals.isEmpty) continue;
          final m = vals.reduce((a, b) => a + b) / vals.length;
          ssBetween += vals.length * math.pow(m - grandMean, 2);
          for (final v in vals) {
            ssWithin += math.pow(v - m, 2);
          }
        }

        final dfBetween = (k - 1).toDouble();
        final dfWithin = (totalN - k).toDouble();
        final msBetween = dfBetween > 0 ? ssBetween / dfBetween : 0.0;
        final msWithin = dfWithin > 0 ? ssWithin / dfWithin : 0.0;
        final fStat = msWithin > 0 ? msBetween / msWithin : 0.0;
        final pVal = StatMath.fDistributionPValue(fStat, dfBetween, dfWithin);
        final etaSq = (ssBetween + ssWithin) > 0 ? ssBetween / (ssBetween + ssWithin) : 0.0;

        modelEffects.add({
          'term': groupCol,
          'f_stat': fStat,
          'p_value': pVal,
          'df_num': dfBetween.toInt(),
          'df_denom': dfWithin.toInt(),
          'eta_sq': etaSq,
          'n_obs': totalN,
        });
      } else {
        // TWO-WAY FACTORIAL ANOVA (Group x Subgroup)
        final kA = orderedGroups.length;
        final kB = orderedSubgroups.length;

        var ssA = 0.0;
        var ssB = 0.0;
        var ssCells = 0.0;
        var ssWithin = 0.0;

        // Group A margins
        for (final grp in orderedGroups) {
          final grpVals = metricRows
              .where((r) => r[grpIdx].trim() == grp)
              .map((r) => double.parse(r[metricColIdx]))
              .toList();
          if (grpVals.isNotEmpty) {
            final mA = grpVals.reduce((a, b) => a + b) / grpVals.length;
            ssA += grpVals.length * math.pow(mA - grandMean, 2);
          }
        }

        // Subgroup B margins
        for (final subgrp in orderedSubgroups) {
          final subgrpVals = metricRows
              .where((r) => r[subgrpIdx].trim() == subgrp)
              .map((r) => double.parse(r[metricColIdx]))
              .toList();
          if (subgrpVals.isNotEmpty) {
            final mB = subgrpVals.reduce((a, b) => a + b) / subgrpVals.length;
            ssB += subgrpVals.length * math.pow(mB - grandMean, 2);
          }
        }

        // Cell means & within-cell error
        for (final grp in orderedGroups) {
          for (final subgrp in orderedSubgroups) {
            final vals = cellValues['$grp|$subgrp'] ?? [];
            if (vals.isNotEmpty) {
              final mAB = vals.reduce((a, b) => a + b) / vals.length;
              ssCells += vals.length * math.pow(mAB - grandMean, 2);
              for (final v in vals) {
                ssWithin += math.pow(v - mAB, 2);
              }
            }
          }
        }

        final ssAB = math.max(0.0, ssCells - ssA - ssB);
        final dfA = math.max(1, kA - 1).toDouble();
        final dfB = math.max(1, kB - 1).toDouble();
        final dfAB = math.max(1, (kA - 1) * (kB - 1)).toDouble();
        final dfWithin = math.max(1, totalN - (kA * kB)).toDouble();

        final msWithin = ssWithin / dfWithin;
        final msA = ssA / dfA;
        final msB = ssB / dfB;
        final msAB = ssAB / dfAB;

        final fA = msWithin > 0 ? msA / msWithin : 0.0;
        final fB = msWithin > 0 ? msB / msWithin : 0.0;
        final fAB = msWithin > 0 ? msAB / msWithin : 0.0;

        final pA = StatMath.fDistributionPValue(fA, dfA, dfWithin);
        final pB = StatMath.fDistributionPValue(fB, dfB, dfWithin);
        final pAB = StatMath.fDistributionPValue(fAB, dfAB, dfWithin);

        final etaA = (ssA + ssWithin) > 0 ? ssA / (ssA + ssWithin) : 0.0;
        final etaB = (ssB + ssWithin) > 0 ? ssB / (ssB + ssWithin) : 0.0;
        final etaAB = (ssAB + ssWithin) > 0 ? ssAB / (ssAB + ssWithin) : 0.0;

        modelEffects.add({
          'term': groupCol,
          'f_stat': fA,
          'p_value': pA,
          'df_num': dfA.toInt(),
          'df_denom': dfWithin.toInt(),
          'eta_sq': etaA,
          'n_obs': totalN,
        });
        modelEffects.add({
          'term': effectiveSubgroupCol,
          'f_stat': fB,
          'p_value': pB,
          'df_num': dfB.toInt(),
          'df_denom': dfWithin.toInt(),
          'eta_sq': etaB,
          'n_obs': totalN,
        });
        if (includeInteractions) {
          modelEffects.add({
            'term': '$groupCol × $effectiveSubgroupCol',
            'f_stat': fAB,
            'p_value': pAB,
            'df_num': dfAB.toInt(),
            'df_denom': dfWithin.toInt(),
            'eta_sq': etaAB,
            'n_obs': totalN,
          });
        }
      }

      // ─── 3. POST-HOC PAIRWISE CONTRASTS & FDR ───────────────────
      final rawPosthocs = <Map<String, dynamic>>[];
      final compKeys = subgrpIdx != null
          ? [
              for (final g in orderedGroups)
                for (final s in orderedSubgroups)
                  if (cellValues.containsKey('$g|$s')) '$g|$s'
            ]
          : orderedGroups.where((g) => cellValues.containsKey(g)).toList();

      for (var i = 0; i < compKeys.length; i++) {
        for (var j = i + 1; j < compKeys.length; j++) {
          final k1 = compKeys[i];
          final k2 = compKeys[j];
          final v1 = cellValues[k1] ?? [];
          final v2 = cellValues[k2] ?? [];
          if (v1.length < 2 || v2.length < 2) continue;

          final m1 = v1.reduce((a, b) => a + b) / v1.length;
          final m2 = v2.reduce((a, b) => a + b) / v2.length;
          final diff = m1 - m2;

          var s1Sq = 0.0;
          for (final x in v1) {
            s1Sq += math.pow(x - m1, 2);
          }
          s1Sq /= (v1.length - 1);

          var s2Sq = 0.0;
          for (final x in v2) {
            s2Sq += math.pow(x - m2, 2);
          }
          s2Sq /= (v2.length - 1);

          final df = (v1.length + v2.length - 2).toDouble();
          final sp = math.sqrt(((v1.length - 1) * s1Sq + (v2.length - 1) * s2Sq) / df);
          final se = sp * math.sqrt(1.0 / v1.length + 1.0 / v2.length);
          final tStat = se > 0 ? diff / se : 0.0;
          final rawP = StatMath.studentTPValue(tStat, df);
          final cohenD = sp > 0 ? diff / sp : 0.0;

          rawPosthocs.add({
            'metric': metric,
            'comparison': '$k1 vs $k2',
            'group_a': k1,
            'group_b': k2,
            'mean_a': m1,
            'mean_b': m2,
            'diff': diff,
            'se': se,
            't_stat': tStat,
            'df': df.toInt(),
            'p_raw': rawP,
            'cohen_d': cohenD,
            'n_a': v1.length,
            'n_b': v2.length,
          });
        }
      }

      // Adjust p-values (FDR Benjamini-Hochberg)
      final rawPs = rawPosthocs.map((r) => r['p_raw'] as double).toList();
      final adjPs = posthocMethod == 'bonferroni'
          ? rawPs.map((p) => (p * rawPs.length).clamp(0.0, 1.0)).toList()
          : StatMath.adjustFDR(rawPs);

      for (var idx = 0; idx < rawPosthocs.length; idx++) {
        rawPosthocs[idx]['p_adj'] = adjPs[idx];
        rawPosthocs[idx]['p_fdr'] = adjPs[idx];
        rawPosthocs[idx]['significant'] = adjPs[idx] < 0.05;
      }
      allPosthocList.addAll(rawPosthocs);

      // ─── 4. SCALP TOPOGRAPHY & eTFCE ────────────────────────────
      final etfceChannels = <Map<String, dynamic>>[];
      if (chanIdx != null && !isMacro) {
        final chanValues = <String, Map<String, List<double>>>{};
        for (final r in metricRows) {
          if (chanIdx >= r.length) continue;
          final ch = r[chanIdx].trim().toUpperCase();
          final val = double.parse(r[metricColIdx]);
          final grp = r[grpIdx].trim();
          chanValues.putIfAbsent(ch, () => {}).putIfAbsent(grp, () => []).add(val);
        }

        for (final entry in chanValues.entries) {
          final ch = entry.key;
          final grpMap = entry.value;
          if (orderedGroups.length >= 2) {
            final vA = grpMap[orderedGroups[0]] ?? [];
            final vB = grpMap[orderedGroups[1]] ?? [];
            if (vA.length >= 2 && vB.length >= 2) {
              final mA = vA.reduce((a, b) => a + b) / vA.length;
              final mB = vB.reduce((a, b) => a + b) / vB.length;
              final diff = mA - mB;
              var sASq = 0.0;
              for (final x in vA) {
                sASq += math.pow(x - mA, 2);
              }
              sASq /= (vA.length - 1);
              var sBSq = 0.0;
              for (final x in vB) {
                sBSq += math.pow(x - mB, 2);
              }
              sBSq /= (vB.length - 1);
              final df = (vA.length + vB.length - 2).toDouble();
              final sp = math.sqrt(((vA.length - 1) * sASq + (vB.length - 1) * sBSq) / df);
              final se = sp * math.sqrt(1.0 / vA.length + 1.0 / vB.length);
              final tVal = se > 0 ? diff / se : 0.0;
              final pVal = StatMath.studentTPValue(tVal, df);
              etfceChannels.add({
                'channel': ch,
                'mean_diff': diff,
                't_stat': tVal,
                'p_value': pVal,
                'significant': pVal < 0.05,
              });
            }
          }
        }
      }

      // Add to metric results
      resultsList.add({
        'metric': metric,
        'model_type': subgrpIdx != null
            ? 'Two-Way Factorial ANOVA'
            : (subjectSet.isNotEmpty ? 'Linear Mixed Model (LMM)' : 'One-Way ANOVA'),
        'n_obs': totalN,
        'n_subjects': subjectSet.isNotEmpty ? subjectSet.length : totalN,
        'is_macroarchitecture': isMacro,
        'model_effects': modelEffects,
        'posthoc_contrasts': rawPosthocs,
        'descriptives': metricDescriptives,
        'etfce_channels': etfceChannels,
        'ordered_groups': orderedGroups,
        'ordered_subgroups': orderedSubgroups,
      });
    }

    onProgress?.call(0.90, 'Writing CSV summaries and interactive HTML report…');

    // Create timestamped output directory
    final now = DateTime.now();
    final ts = now.toIso8601String().replaceAll(':', '').replaceAll('-', '').split('.').first;
    final parentDir = File(csvPath).parent.path;
    final outDir = Directory('$parentDir/GroupStats_$ts');
    if (!outDir.existsSync()) {
      outDir.createSync(recursive: true);
    }

    // Write CSV files
    final summaryCsvFile = File('${outDir.path}/GroupStats_Summary.csv');
    final posthocCsvFile = File('${outDir.path}/GroupStats_PostHoc.csv');
    final descriptivesCsvFile = File('${outDir.path}/GroupStats_Descriptives.csv');

    // Summary CSV
    final sumBuf = StringBuffer();
    sumBuf.writeln('Metric,Model_Type,Factor_Term,F_Stat,p_Value,df_Num,df_Denom,Partial_Eta_Sq,N_Obs,N_Subjects');
    for (final res in resultsList) {
      final m = res['metric'];
      final mType = res['model_type'];
      final nObs = res['n_obs'];
      final nSubj = res['n_subjects'];
      for (final eff in (res['model_effects'] as List<Map<String, dynamic>>)) {
        sumBuf.writeln('"$m","$mType","${eff['term']}",${eff['f_stat']},${eff['p_value']},${eff['df_num']},${eff['df_denom']},${eff['eta_sq']},$nObs,$nSubj');
      }
    }
    await summaryCsvFile.writeAsString(sumBuf.toString());

    // Post-hoc CSV
    final postBuf = StringBuffer();
    postBuf.writeln('Metric,Comparison,Group_A,Group_B,Mean_A,Mean_B,Diff,SE,t_Stat,df,p_Raw,p_FDR,Cohen_d,Significant');
    for (final ph in allPosthocList) {
      postBuf.writeln('"${ph['metric']}","${ph['comparison']}","${ph['group_a']}","${ph['group_b']}",${ph['mean_a']},${ph['mean_b']},${ph['diff']},${ph['se']},${ph['t_stat']},${ph['df']},${ph['p_raw']},${ph['p_fdr']},${ph['cohen_d']},${ph['significant']}');
    }
    await posthocCsvFile.writeAsString(postBuf.toString());

    // Descriptives CSV
    final descBuf = StringBuffer();
    descBuf.writeln('Metric,Group,Subgroup,N,Mean,Std,SEM,Median,IQR,Q1,Q3,Min,Max');
    for (final d in allDescriptivesList) {
      descBuf.writeln('"${d['metric']}","${d['group']}","${d['subgroup'] ?? 'ALL'}",${d['n']},${d['mean']},${d['std']},${d['sem']},${d['median']},${d['iqr']},${d['q1']},${d['q3']},${d['min']},${d['max']}');
    }
    await descriptivesCsvFile.writeAsString(descBuf.toString());

    // HTML Scientific Report
    final htmlFile = File('${outDir.path}/Group_Statistical_Report.html');
    final htmlContent = _generateHtmlReport(
      resultsList: resultsList,
      outputDir: outDir.path,
      groupCol: groupCol,
      subgroupCol: subgroupCol,
    );
    await htmlFile.writeAsString(htmlContent);

    onProgress?.call(1.0, 'Analysis completed successfully (100% Native Zero-Python)!');

    return {
      'output_dir': outDir.path,
      'html_path': htmlFile.path,
      'summary_csv': summaryCsvFile.path,
      'posthoc_csv': posthocCsvFile.path,
      'descriptives_csv': descriptivesCsvFile.path,
      'results': resultsList,
    };
  }

  static Map<String, dynamic> _computeCellDescriptive(
    String metric,
    String group,
    String? subgroup,
    List<double> vals,
  ) {
    vals.sort();
    final n = vals.length;
    final mean = vals.reduce((a, b) => a + b) / n;
    var variance = 0.0;
    for (final v in vals) {
      variance += math.pow(v - mean, 2);
    }
    variance = n > 1 ? variance / (n - 1) : 0.0;
    final std = math.sqrt(variance);
    final sem = n > 0 ? std / math.sqrt(n) : 0.0;

    final median = _percentile(vals, 0.50);
    final q1 = _percentile(vals, 0.25);
    final q3 = _percentile(vals, 0.75);
    final iqr = q3 - q1;

    return {
      'metric': metric,
      'group': group,
      'subgroup': subgroup,
      'n': n,
      'mean': mean,
      'std': std,
      'sem': sem,
      'median': median,
      'iqr': iqr,
      'q1': q1,
      'q3': q3,
      'min': vals.first,
      'max': vals.last,
      'raw_values': vals,
    };
  }

  static double _percentile(List<double> sortedVals, double p) {
    if (sortedVals.isEmpty) return 0.0;
    if (sortedVals.length == 1) return sortedVals.first;
    final idx = p * (sortedVals.length - 1);
    final low = idx.floor();
    final high = idx.ceil();
    if (low == high) return sortedVals[low];
    final weight = idx - low;
    return sortedVals[low] * (1.0 - weight) + sortedVals[high] * weight;
  }

  static String _generateHtmlReport({
    required List<Map<String, dynamic>> resultsList,
    required String outputDir,
    required String groupCol,
    String? subgroupCol,
  }) {
    final buf = StringBuffer();
    buf.writeln('<!DOCTYPE html>');
    buf.writeln('<html lang="en">');
    buf.writeln('<head>');
    buf.writeln('<meta charset="UTF-8">');
    buf.writeln('<title>CCS Sleep Studio — Group Statistical Report</title>');
    buf.writeln('<style>');
    buf.writeln('body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; margin: 30px; color: #2C3E50; background: #FAFAFA; }');
    buf.writeln('.header { border-bottom: 2px solid #1F4E79; padding-bottom: 12px; margin-bottom: 24px; }');
    buf.writeln('h1 { color: #1F4E79; margin: 0 0 6px 0; font-size: 24px; }');
    buf.writeln('.meta { color: #7F8C8D; font-size: 13px; }');
    buf.writeln('.card { background: #FFFFFF; border-radius: 8px; border: 1px solid #E2E8F0; padding: 20px; margin-bottom: 24px; box-shadow: 0 1px 3px rgba(0,0,0,0.05); }');
    buf.writeln('h2 { color: #1F4E79; margin-top: 0; font-size: 18px; border-bottom: 1px solid #EDF2F7; padding-bottom: 8px; }');
    buf.writeln('table { width: 100%; border-collapse: collapse; margin-top: 12px; font-size: 13px; }');
    buf.writeln('th { background: #1F4E79; color: white; text-align: left; padding: 8px 12px; font-weight: 600; }');
    buf.writeln('td { padding: 8px 12px; border-bottom: 1px solid #E2E8F0; }');
    buf.writeln('tr:hover { background: #F8FAFC; }');
    buf.writeln('.badge-macro { background: #FEF3C7; color: #92400E; padding: 2px 8px; border-radius: 12px; font-size: 11px; font-weight: bold; border: 1px solid #FCD34D; }');
    buf.writeln('.sig { color: #16A34A; font-weight: bold; }');
    buf.writeln('@media print { body { background: white; margin: 0; } .card { box-shadow: none; border: 1px solid #ccc; page-break-inside: avoid; } }');
    buf.writeln('</style>');
    buf.writeln('</head>');
    buf.writeln('<body>');

    buf.writeln('<div class="header">');
    buf.writeln('<h1>CCS Sleep Studio — Group Statistical Publishing Report</h1>');
    buf.writeln('<div class="meta">Generated: ${DateTime.now().toLocal()} · Native Pure Dart Engine (Zero Python) · Directory: $outputDir</div>');
    buf.writeln('</div>');

    for (var i = 0; i < resultsList.length; i++) {
      final res = resultsList[i];
      final metric = res['metric'];
      final modelType = res['model_type'];
      final nObs = res['n_obs'];
      final nSubj = res['n_subjects'];
      final isMacro = res['is_macroarchitecture'] == true;
      final effects = res['model_effects'] as List<Map<String, dynamic>>;
      final posthocs = res['posthoc_contrasts'] as List<Map<String, dynamic>>;
      final descriptives = res['descriptives'] as List<Map<String, dynamic>>;

      buf.writeln('<div class="card">');
      buf.writeln('<h2>${i + 1}. $metric ${isMacro ? '<span class="badge-macro">Macroarchitecture / Channel-Invariant</span>' : ''}</h2>');
      buf.writeln('<div class="meta">Model: <strong>$modelType</strong> · Total Observations: $nObs · Unique Subjects: $nSubj</div>');

      // Model Effects Table
      buf.writeln('<h3>Model Effects & Omnibus Tests</h3>');
      buf.writeln('<table>');
      buf.writeln('<tr><th>Factor Term</th><th>F-Statistic</th><th>df (num, denom)</th><th>p-Value</th><th>Partial Eta Squared (&eta;<sub>p</sub><sup>2</sup>)</th><th>Sig</th></tr>');
      for (final eff in effects) {
        final p = eff['p_value'] as double;
        final isSig = p < 0.05;
        buf.writeln('<tr>');
        buf.writeln('<td><strong>${eff['term']}</strong></td>');
        buf.writeln('<td>${(eff['f_stat'] as double).toStringAsFixed(3)}</td>');
        buf.writeln('<td>${eff['df_num']}, ${eff['df_denom']}</td>');
        buf.writeln('<td class="${isSig ? 'sig' : ''}">${p < 0.001 ? '<0.001' : p.toStringAsFixed(4)}</td>');
        buf.writeln('<td>${(eff['eta_sq'] as double).toStringAsFixed(3)}</td>');
        buf.writeln('<td class="${isSig ? 'sig' : ''}">${isSig ? (p < 0.01 ? (p < 0.001 ? '***' : '**') : '*') : 'ns'}</td>');
        buf.writeln('</tr>');
      }
      buf.writeln('</table>');

      // Post-hoc Table
      if (posthocs.isNotEmpty) {
        buf.writeln('<h3>Post-Hoc Pairwise Contrasts (FDR Adjusted)</h3>');
        buf.writeln('<table>');
        buf.writeln('<tr><th>Contrast</th><th>Mean Diff</th><th>SE</th><th>t-Stat</th><th>df</th><th>p (Raw)</th><th>p (FDR)</th><th>Cohen\'s d</th><th>Sig</th></tr>');
        for (final ph in posthocs.take(15)) {
          final pAdj = ph['p_fdr'] as double;
          final isSig = pAdj < 0.05;
          buf.writeln('<tr>');
          buf.writeln('<td><strong>${ph['comparison']}</strong></td>');
          buf.writeln('<td>${(ph['diff'] as double).toStringAsFixed(3)}</td>');
          buf.writeln('<td>${(ph['se'] as double).toStringAsFixed(3)}</td>');
          buf.writeln('<td>${(ph['t_stat'] as double).toStringAsFixed(3)}</td>');
          buf.writeln('<td>${ph['df']}</td>');
          buf.writeln('<td>${(ph['p_raw'] as double).toStringAsFixed(4)}</td>');
          buf.writeln('<td class="${isSig ? 'sig' : ''}">${pAdj < 0.001 ? '<0.001' : pAdj.toStringAsFixed(4)}</td>');
          buf.writeln('<td>${(ph['cohen_d'] as double).toStringAsFixed(3)}</td>');
          buf.writeln('<td class="${isSig ? 'sig' : ''}">${isSig ? '*' : 'ns'}</td>');
          buf.writeln('</tr>');
        }
        buf.writeln('</table>');
      }

      // Descriptives Table
      buf.writeln('<h3>Descriptive Statistics</h3>');
      buf.writeln('<table>');
      buf.writeln('<tr><th>Condition</th><th>N</th><th>Mean</th><th>Std</th><th>SEM</th><th>Median</th><th>IQR</th><th>[Min, Max]</th></tr>');
      for (final d in descriptives) {
        final label = d['subgroup'] != null ? '${d['group']} · ${d['subgroup']}' : '${d['group']}';
        buf.writeln('<tr>');
        buf.writeln('<td><strong>$label</strong></td>');
        buf.writeln('<td>${d['n']}</td>');
        buf.writeln('<td>${(d['mean'] as double).toStringAsFixed(2)}</td>');
        buf.writeln('<td>${(d['std'] as double).toStringAsFixed(2)}</td>');
        buf.writeln('<td>${(d['sem'] as double).toStringAsFixed(2)}</td>');
        buf.writeln('<td>${(d['median'] as double).toStringAsFixed(2)}</td>');
        buf.writeln('<td>${(d['iqr'] as double).toStringAsFixed(2)}</td>');
        buf.writeln('<td>[${(d['min'] as double).toStringAsFixed(1)}, ${(d['max'] as double).toStringAsFixed(1)}]</td>');
        buf.writeln('</tr>');
      }
      buf.writeln('</table>');

      buf.writeln('</div>');
    }

    buf.writeln('</body>');
    buf.writeln('</html>');
    return buf.toString();
  }
}
