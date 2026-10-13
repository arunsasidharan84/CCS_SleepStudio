import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:file_picker/file_picker.dart';

class GroupStatisticsWorkbench extends StatefulWidget {
  const GroupStatisticsWorkbench({
    super.key,
    this.initialCsvPath,
    this.initialMetadataPath,
  });

  final String? initialCsvPath;
  final String? initialMetadataPath;

  @override
  State<GroupStatisticsWorkbench> createState() => _GroupStatisticsWorkbenchState();
}

class _GroupStatisticsWorkbenchState extends State<GroupStatisticsWorkbench> {
  static String? _cachedPythonExecutable;

  final TextEditingController _csvPathController = TextEditingController();
  final TextEditingController _metadataPathController = TextEditingController();
  final TextEditingController _metadataKeyController = TextEditingController();
  final TextEditingController _rowFilterValueController = TextEditingController();
  final TextEditingController _pythonPathController = TextEditingController();

  bool _isInspecting = false;
  bool _isAnalyzing = false;
  double _analysisProgress = 0.0;
  String _progressStatus = '';
  String _statusMessage = '';
  final List<String> _consoleLogs = [];

  // Inspected Metadata
  Map<String, dynamic>? _inspectionData;
  String? _selectedGroupCol;
  String? _selectedSubgroupCol;
  String? _selectedSubjectIdCol;
  String? _selectedChannelCol;
  final Set<String> _selectedExtraFactors = {};
  bool _includeInteractions = true;
  final Set<String> _selectedCovariates = {};
  final Set<String> _selectedMetrics = {};

  // Interactive Factor Label Filtering & Plot Ordering
  final Map<String, Set<String>> _excludedFactorLabels = {};
  final Map<String, List<String>> _customFactorOrder = {};

  // Interactive Row Value Filters: list of {'column': col, 'op': op, 'value': val}
  final List<Map<String, String>> _rowFilters = [];
  String? _draftFilterColumn;
  String _draftFilterOp = '==';

  // Modelling preferences
  String _preferredModel = 'auto'; // 'auto', 'lmm', 'glm'
  String _posthocMethod = 'fdr'; // 'fdr', 'tukey', 'bonferroni'
  String _reportFormat = 'both'; // 'both', 'docx', 'pdf'

  // Analysis Results
  Map<String, dynamic>? _analysisResults;
  String? _selectedResultMetric;
  int _activeResultTabIndex = 0; // 0: Plot, 1: Model Effects, 2: Post-Hoc, 3: Descriptives
  int _activePlotView = 0; // 0: Box & Post-Hoc Plot, 1: Scalp Topoplot + eTFCE

  @override
  void initState() {
    super.initState();
    if (_cachedPythonExecutable != null) {
      _pythonPathController.text = _cachedPythonExecutable!;
    }
    if (widget.initialCsvPath != null && widget.initialCsvPath!.isNotEmpty) {
      _csvPathController.text = widget.initialCsvPath!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _inspectCsv());
    }
    if (widget.initialMetadataPath != null) {
      _metadataPathController.text = widget.initialMetadataPath!;
    }
  }

  @override
  void dispose() {
    _csvPathController.dispose();
    _metadataPathController.dispose();
    _metadataKeyController.dispose();
    _rowFilterValueController.dispose();
    _pythonPathController.dispose();
    super.dispose();
  }

  static Future<String?> _findPythonExecutable([String? preferredPath]) async {
    if (preferredPath != null && preferredPath.trim().isNotEmpty) {
      final f = File(preferredPath.trim());
      if (f.existsSync()) {
        try {
          final res = await Process.run(preferredPath.trim(), ['--version']);
          if (res.exitCode == 0) {
            _cachedPythonExecutable = preferredPath.trim();
            return preferredPath.trim();
          }
        } catch (_) {}
      }
    }

    if (_cachedPythonExecutable != null && _cachedPythonExecutable!.isNotEmpty) {
      try {
        final res = await Process.run(_cachedPythonExecutable!, ['--version']);
        if (res.exitCode == 0) return _cachedPythonExecutable;
      } catch (_) {
        _cachedPythonExecutable = null;
      }
    }

    final candidateSet = <String>{};

    if (Platform.isWindows) {
      try {
        final whichRes = await Process.run('where.exe', ['python']);
        if (whichRes.exitCode == 0) {
          final lines = (whichRes.stdout as String).split(RegExp(r'[\r\n]+'));
          for (final l in lines) {
            if (l.trim().isNotEmpty && l.trim().toLowerCase().endsWith('.exe')) {
              candidateSet.add(l.trim());
            }
          }
        }
      } catch (_) {}

      try {
        final whichRes = await Process.run('where.exe', ['py']);
        if (whichRes.exitCode == 0) {
          final lines = (whichRes.stdout as String).split(RegExp(r'[\r\n]+'));
          for (final l in lines) {
            if (l.trim().isNotEmpty && l.trim().toLowerCase().endsWith('.exe')) {
              candidateSet.add(l.trim());
            }
          }
        }
      } catch (_) {}

      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null) {
        final pyProgDir = Directory('$localAppData\\Programs\\Python');
        if (pyProgDir.existsSync()) {
          try {
            for (final ent in pyProgDir.listSync()) {
              if (ent is Directory) {
                final exe = File('${ent.path}\\python.exe');
                if (exe.existsSync()) candidateSet.add(exe.path);
              }
            }
          } catch (_) {}
        }
      }

      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null) {
        for (final sub in ['miniconda3', 'anaconda3', 'Miniconda3', 'Anaconda3', '.conda']) {
          final exe = File('$userProfile\\$sub\\python.exe');
          if (exe.existsSync()) candidateSet.add(exe.path);
        }
      }

      for (final root in [
        r'C:\ProgramData\miniconda3',
        r'C:\ProgramData\anaconda3',
        r'C:\Python313',
        r'C:\Python312',
        r'C:\Python311',
        r'C:\Python310',
      ]) {
        final exe = File('$root\\python.exe');
        if (exe.existsSync()) candidateSet.add(exe.path);
      }

      candidateSet.addAll(['python.exe', 'python3.exe', 'py.exe']);
    } else {
      // Linux & macOS
      for (final cmd in ['python3', 'python']) {
        try {
          final whichRes = await Process.run('which', [cmd]);
          if (whichRes.exitCode == 0) {
            final p = (whichRes.stdout as String).trim();
            if (p.isNotEmpty) candidateSet.add(p);
          }
        } catch (_) {}
      }

      final home = Platform.environment['HOME'];
      if (home != null) {
        for (final sub in [
          'miniconda3/bin/python3',
          'miniconda3/bin/python',
          'anaconda3/bin/python3',
          'anaconda3/bin/python',
          '.local/bin/python3',
          '.local/bin/python',
        ]) {
          final exe = File('$home/$sub');
          if (exe.existsSync()) candidateSet.add(exe.path);
        }

        final condaEnvsDir = Directory('$home/.conda/envs');
        if (condaEnvsDir.existsSync()) {
          try {
            for (final ent in condaEnvsDir.listSync()) {
              if (ent is Directory) {
                final exe = File('${ent.path}/bin/python');
                if (exe.existsSync()) candidateSet.add(exe.path);
              }
            }
          } catch (_) {}
        }
      }

      candidateSet.addAll([
        if (Platform.isMacOS) ...[
          '/opt/homebrew/bin/python3',
          '/usr/local/bin/python3',
          '/usr/bin/python3',
        ],
        if (Platform.isLinux) ...[
          '/usr/bin/python3',
          '/usr/local/bin/python3',
          '/opt/conda/bin/python',
          '/opt/conda/bin/python3',
        ],
        'python3',
        'python',
      ]);
    }

    String? bestCandidate;
    int bestScore = -1;

    for (final cand in candidateSet) {
      try {
        final verRes = await Process.run(cand, ['--version']);
        if (verRes.exitCode != 0) continue;

        int score = 1; // Base python works

        try {
          final pkgRes = await Process.run(cand, [
            '-c',
            'import pandas; import statsmodels; import matplotlib; print("READY")',
          ]);
          if (pkgRes.exitCode == 0 && (pkgRes.stdout as String).contains('READY')) {
            score = 10; // fully equipped
            _cachedPythonExecutable = cand;
            return cand;
          } else {
            final pdRes = await Process.run(cand, ['-c', 'import pandas; print("PD")']);
            if (pdRes.exitCode == 0 && (pdRes.stdout as String).contains('PD')) {
              score = 5;
            }
          }
        } catch (_) {}

        if (score > bestScore) {
          bestScore = score;
          bestCandidate = cand;
        }
      } catch (_) {}
    }

    if (bestCandidate != null) {
      _cachedPythonExecutable = bestCandidate;
    }
    return bestCandidate;
  }

  static Future<String> _resolveGroupStatsScript() async {
    final currentDir = Directory.current.path;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      '$currentDir/backend/group_stats.py',
      '$currentDir/../backend/group_stats.py',
      '$exeDir/backend/group_stats.py',
      '$exeDir/../Resources/backend/group_stats.py',
      '$exeDir/../Resources/group_stats.py',
      '$exeDir/../lib/ccs-sleep-studio/backend/group_stats.py',
      '/Users/arunsasidharan/Code/ActiveProjects/CCS_SleepStudio/backend/group_stats.py',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }

    try {
      final scriptContent = await rootBundle.loadString('assets/group_stats.py');
      final tempFile = File('${Directory.systemTemp.path}${Platform.pathSeparator}ccs_group_stats.py');
      await tempFile.writeAsString(scriptContent);
      return tempFile.path;
    } catch (_) {}

    return '$currentDir/backend/group_stats.py';
  }

  List<String> _levelsForFactor(String? factorCol) {
    if (factorCol == null || factorCol == 'None' || _inspectionData == null) return const [];
    final rawMap = _inspectionData!['factor_levels'] as Map<String, dynamic>? ?? {};
    final rawList = (rawMap[factorCol] as List<dynamic>? ?? const []).map((e) => e.toString()).toList();
    final custom = _customFactorOrder[factorCol];
    if (custom != null && custom.isNotEmpty) {
      final ordered = <String>[
        for (final item in custom)
          if (rawList.contains(item)) item,
        for (final item in rawList)
          if (!custom.contains(item)) item,
      ];
      return ordered;
    }
    return rawList;
  }

  List<String> _activeOrderedLevelsForFactor(String? factorCol) {
    if (factorCol == null || factorCol == 'None') return const [];
    final all = _levelsForFactor(factorCol);
    final excluded = _excludedFactorLabels[factorCol] ?? const <String>{};
    return all.where((l) => !excluded.contains(l)).toList();
  }

  int _countForFactorLevel(String factorCol, String level) {
    final countsMap = _inspectionData?['factor_counts'] as Map<String, dynamic>? ?? {};
    final factorMap = countsMap[factorCol] as Map<String, dynamic>? ?? {};
    return (factorMap[level] as num?)?.toInt() ?? 0;
  }

  void _moveFactorLevel(String factorCol, String level, int delta) {
    final current = List<String>.from(_levelsForFactor(factorCol));
    final idx = current.indexOf(level);
    if (idx < 0) return;
    final target = idx + delta;
    if (target < 0 || target >= current.length) return;
    setState(() {
      final item = current.removeAt(idx);
      current.insert(target, item);
      _customFactorOrder[factorCol] = current;
    });
  }

  Future<void> _pickCsvFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
      dialogTitle: 'Select Master Analysis Sheet CSV',
    );
    if (result != null && result.files.single.path != null) {
      setState(() {
        _csvPathController.text = result.files.single.path!;
      });
      await _inspectCsv();
    }
  }

  Future<void> _pickMetadataFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'xlsx', 'xls', 'tsv'],
      dialogTitle: 'Select Metadata Table (Optional)',
    );
    if (result != null && result.files.single.path != null) {
      setState(() {
        _metadataPathController.text = result.files.single.path!;
      });
      await _inspectCsv();
    }
  }

  Future<void> _pickPythonExecutable() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Select Python 3 Executable / Environment',
      type: Platform.isWindows ? FileType.custom : FileType.any,
      allowedExtensions: Platform.isWindows ? ['exe'] : null,
    );
    if (result != null && result.files.single.path != null) {
      final selected = result.files.single.path!;
      setState(() {
        _pythonPathController.text = selected;
        _cachedPythonExecutable = selected;
      });
      if (_csvPathController.text.trim().isNotEmpty) {
        await _inspectCsv();
      }
    }
  }

  Future<void> _autoDetectPython() async {
    _cachedPythonExecutable = null;
    setState(() {
      _statusMessage = 'Searching system and user directories for Python 3…';
    });
    final detected = await _findPythonExecutable();
    if (detected != null) {
      setState(() {
        _pythonPathController.text = detected;
        _cachedPythonExecutable = detected;
        _statusMessage = 'Found Python: $detected';
      });
      if (_csvPathController.text.trim().isNotEmpty) {
        await _inspectCsv();
      }
    } else {
      _showSnack('No compatible Python 3 environment found automatically. Please browse and select manually.');
    }
  }

  Future<void> _inspectCsv() async {
    final csvPath = _csvPathController.text.trim();
    if (csvPath.isEmpty || !File(csvPath).existsSync()) {
      _showSnack('Please select a valid CSV file first.');
      return;
    }

    setState(() {
      _isInspecting = true;
      _statusMessage = 'Inspecting columns and data structure…';
    });

    try {
      final preferred = _pythonPathController.text.trim();
      final python = await _findPythonExecutable(preferred.isNotEmpty ? preferred : null);
      if (python == null) {
        throw StateError(
          'Python 3 environment not found. Please install Python with pandas and statsmodels, or select your Python executable using the Browse button.',
        );
      }
      if (_pythonPathController.text.trim().isEmpty) {
        _pythonPathController.text = python;
      }
      _cachedPythonExecutable = python;

      final script = await _resolveGroupStatsScript();

      final args = [
        script,
        '--csv', csvPath,
        '--inspect-only',
      ];
      if (_metadataPathController.text.trim().isNotEmpty) {
        args.addAll(['--metadata-csv', _metadataPathController.text.trim()]);
      }

      final res = await Process.run(python, args);
      if (res.exitCode != 0) {
        throw StateError('Inspection failed: ${res.stderr}');
      }

      final jsonMap = jsonDecode(res.stdout as String) as Map<String, dynamic>;
      setState(() {
        _inspectionData = jsonMap;
        _selectedGroupCol = jsonMap['group_col'] as String?;
        _selectedSubgroupCol = jsonMap['subgroup_col'] as String? ?? 'None';
        _selectedSubjectIdCol = jsonMap['subject_id'] as String?;
        _selectedChannelCol = jsonMap['channel_col'] as String? ?? 'None';
        _selectedExtraFactors.clear();
        _excludedFactorLabels.clear();
        _customFactorOrder.clear();
        _rowFilters.clear();

        final filterableCols = (jsonMap['filterable_columns'] as List<dynamic>? ?? []).cast<String>();
        _draftFilterColumn = filterableCols.isNotEmpty ? filterableCols.first : null;

        _selectedCovariates.clear();
        final detectedCovs = (jsonMap['covariates'] as List<dynamic>? ?? []).cast<String>();
        _selectedCovariates.addAll(detectedCovs.take(2));

        _selectedMetrics.clear();
        final prioritized = [
          'Sleep_efficiency', 'TST', 'WASO', 'SOL', 'N3_percentage', 'R_percentage',
          'sp_Count', 'sp_Duration', 'sp_Amplitude', 'sp_Frequency',
          'sw_Count', 'sw_Density', 'sw_Duration', 'sw_Amplitude',
          'N3_Sigma_PSD', 'N3_Delta_PSD', 'N3_Theta_PSD', 'CAP_rate', 'CAP_A_index'
        ];
        final availMetrics = (jsonMap['metric_columns'] as List<dynamic>? ?? []).cast<String>();
        for (final m in prioritized) {
          if (availMetrics.contains(m)) {
            _selectedMetrics.add(m);
          }
        }
        if (_selectedMetrics.isEmpty) {
          _selectedMetrics.addAll(availMetrics.take(8));
        }

        _statusMessage = 'Dataset loaded: ${jsonMap['total_rows']} rows, ${jsonMap['unique_subjects']} subjects detected.';
      });
    } catch (e) {
      _showSnack('Error inspecting file: $e');
      setState(() {
        _statusMessage = 'Error: $e';
      });
    } finally {
      setState(() {
        _isInspecting = false;
      });
    }
  }

  Future<void> _runAnalysis() async {
    final csvPath = _csvPathController.text.trim();
    if (csvPath.isEmpty || !File(csvPath).existsSync()) {
      _showSnack('Please select a valid CSV file.');
      return;
    }
    if (_selectedGroupCol == null || _selectedGroupCol!.isEmpty) {
      _showSnack('Please select a primary grouping factor.');
      return;
    }
    if (_selectedMetrics.isEmpty) {
      _showSnack('Please select at least one sleep metric to analyze.');
      return;
    }

    final activeGroupLevels = _activeOrderedLevelsForFactor(_selectedGroupCol);
    if (activeGroupLevels.length < 2) {
      _showSnack('At least 2 active factor labels are required in $_selectedGroupCol.');
      return;
    }

    setState(() {
      _isAnalyzing = true;
      _analysisProgress = 0.0;
      _progressStatus = 'Initializing statistical models…';
      _statusMessage = 'Running group statistical analysis…';
      _consoleLogs.clear();
    });

    try {
      final preferred = _pythonPathController.text.trim();
      final python = await _findPythonExecutable(preferred.isNotEmpty ? preferred : null);
      if (python == null) {
        throw StateError('Python 3 environment not found. Please select or install Python with pandas and statsmodels.');
      }
      final script = await _resolveGroupStatsScript();

      final excludeMap = <String, List<String>>{};
      for (final entry in _excludedFactorLabels.entries) {
        if (entry.value.isNotEmpty) {
          excludeMap[entry.key] = entry.value.toList();
        }
      }

      final groupOrder = _activeOrderedLevelsForFactor(_selectedGroupCol);
      final subgroupOrder = (_selectedSubgroupCol != null && _selectedSubgroupCol != 'None')
          ? _activeOrderedLevelsForFactor(_selectedSubgroupCol)
          : <String>[];

      final extraFactorsClean = _selectedExtraFactors
          .where((f) => f != _selectedGroupCol && f != _selectedSubgroupCol && f != _selectedSubjectIdCol && f != _selectedChannelCol)
          .toList();

      final args = [
        script,
        '--csv', csvPath,
        '--group', _selectedGroupCol!,
        if (_selectedSubgroupCol != null && _selectedSubgroupCol != 'None') ...[
          '--subgroup', _selectedSubgroupCol!,
        ],
        if (_selectedChannelCol != null && _selectedChannelCol != 'None') ...[
          '--channel-col', _selectedChannelCol!,
        ],
        if (extraFactorsClean.isNotEmpty) ...[
          '--extra-factors', extraFactorsClean.join(','),
        ],
        if (!_includeInteractions) '--no-interactions',
        if (_selectedSubjectIdCol != null) ...[
          '--subject-id', _selectedSubjectIdCol!,
        ],
        if (_selectedCovariates.isNotEmpty) ...[
          '--covariates', _selectedCovariates.join(','),
        ],
        if (excludeMap.isNotEmpty) ...[
          '--exclude-labels', jsonEncode(excludeMap),
        ],
        if (_rowFilters.isNotEmpty) ...[
          '--row-filters', jsonEncode(_rowFilters),
        ],
        if (groupOrder.isNotEmpty) ...[
          '--group-order', jsonEncode(groupOrder),
        ],
        if (subgroupOrder.isNotEmpty) ...[
          '--subgroup-order', jsonEncode(subgroupOrder),
        ],
        '--metrics', _selectedMetrics.join(','),
        '--model', _preferredModel,
        '--posthoc', _posthocMethod,
        '--report-format', _reportFormat,
      ];
      if (_metadataPathController.text.trim().isNotEmpty) {
        args.addAll(['--metadata-csv', _metadataPathController.text.trim()]);
      }

      final process = await Process.start(python, args);

      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();

      process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        stdoutBuffer.writeln(line);
        setState(() {
          _consoleLogs.add(line);
          if (_consoleLogs.length > 50) _consoleLogs.removeAt(0);
        });
      });

      process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        stderrBuffer.writeln(line);
        if (line.startsWith('PROGRESS ')) {
          final rest = line.substring(9).trim();
          final spIdx = rest.indexOf(' ');
          if (spIdx > 0) {
            final frac = double.tryParse(rest.substring(0, spIdx));
            final msg = rest.substring(spIdx + 1).trim();
            if (frac != null) {
              setState(() {
                _analysisProgress = frac.clamp(0.0, 1.0);
                _progressStatus = msg;
              });
            }
          }
        }
        setState(() {
          _consoleLogs.add('[stderr] $line');
          if (_consoleLogs.length > 50) _consoleLogs.removeAt(0);
        });
      });

      final exitCode = await process.exitCode;
      if (exitCode != 0) {
        throw StateError('Analysis returned exit code $exitCode:\n${stderrBuffer.toString()}');
      }

      final outStr = stdoutBuffer.toString();
      final jsonMap = jsonDecode(outStr) as Map<String, dynamic>;

      setState(() {
        _analysisResults = jsonMap;
        final resList = jsonMap['results'] as List<dynamic>? ?? [];
        if (resList.isNotEmpty) {
          _selectedResultMetric = (resList.first as Map<String, dynamic>)['metric'] as String?;
        }
        _statusMessage = 'Analysis completed! Generated ${resList.length} metric models, 400-DPI plots, eTFCE topoplots, and reports.';
      });
    } catch (e) {
      _showSnack('Analysis failed: $e');
      setState(() {
        _statusMessage = 'Analysis failed: $e';
      });
    } finally {
      setState(() {
        _isAnalyzing = false;
      });
    }
  }

  Future<void> _openPath(String path) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer.exe', [path]);
      } else {
        await Process.run('xdg-open', [path]);
      }
    } catch (e) {
      _showSnack('Unable to open path: $e');
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeaderCard(),
        const SizedBox(height: 12),
        _buildDataSourceCard(),
        const SizedBox(height: 12),
        if (_inspectionData != null) ...[
          _buildConfigurationCard(),
          const SizedBox(height: 12),
          _buildFilteringAndOrderCard(),
          const SizedBox(height: 12),
          _buildMetricsSelectionCard(),
          const SizedBox(height: 12),
          _buildActionRunCard(),
          const SizedBox(height: 12),
        ],
        if (_analysisResults != null) ...[
          _buildResultsCard(),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _buildHeaderCard() {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF1F4E79).withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.analytics_outlined, color: Color(0xFF1F4E79), size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Group-Level Statistical Analysis & Publishing Workbench',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF1F4E79)),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Multi-factor Linear Mixed-Effects Models (LMM) & GLM/ANOVA with interactive factor filtering, custom plot ordering, '
                    'outlier-robust 400-DPI plots, spatial eTFCE scalp topoplots, and space-optimized Word (DOCX) / PDF reports.',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDataSourceCard() {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.table_chart_outlined, size: 20, color: Color(0xFF1F4E79)),
                const SizedBox(width: 8),
                const Text('Data Source', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const Spacer(),
                if (_inspectionData != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.green.shade200),
                    ),
                    child: Text(
                      '${_inspectionData!['total_rows']} rows · ${_inspectionData!['unique_subjects']} subjects · ${_inspectionData!['total_columns']} columns',
                      style: TextStyle(fontSize: 12, color: Colors.green.shade800, fontWeight: FontWeight.bold),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _csvPathController,
                    decoration: InputDecoration(
                      labelText: 'Batch Analysis Master Sheet (CSV)',
                      hintText: 'Select master sheet CSV (e.g., AnalyseNidra_master_sheet.csv)',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      prefixIcon: const Icon(Icons.file_present_outlined),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.folder_open),
                        onPressed: _pickCsvFile,
                        tooltip: 'Browse CSV',
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _isInspecting ? null : _inspectCsv,
                  icon: _isInspecting
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.sync, size: 18),
                  label: Text(_isInspecting ? 'Loading…' : 'Inspect Data'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1F4E79),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _metadataPathController,
                    decoration: InputDecoration(
                      labelText: 'External Metadata File (Optional)',
                      hintText: 'Select optional metadata (.csv, .xlsx) to merge demographic/group factors',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      prefixIcon: const Icon(Icons.badge_outlined),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.folder_open),
                        onPressed: _pickMetadataFile,
                        tooltip: 'Browse Metadata',
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _pythonPathController,
                    decoration: InputDecoration(
                      labelText: 'Python 3 Environment / Executable',
                      hintText: 'Auto-detected system or venv Python path',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      prefixIcon: const Icon(Icons.terminal_outlined),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.refresh, size: 20),
                            onPressed: _isInspecting ? null : _autoDetectPython,
                            tooltip: 'Auto-detect Python',
                          ),
                          IconButton(
                            icon: const Icon(Icons.folder_open, size: 20),
                            onPressed: _isInspecting ? null : _pickPythonExecutable,
                            tooltip: 'Browse Python Executable',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (_inspectionData != null && _inspectionData!['environment'] != null) ...[
              Builder(
                builder: (context) {
                  final env = _inspectionData!['environment'] as Map<String, dynamic>;
                  final missing = (env['missing_packages'] as List<dynamic>? ?? []).cast<String>();
                  if (missing.isEmpty) return const SizedBox.shrink();
                  return Container(
                    margin: const EdgeInsets.only(top: 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.amber.shade400),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber_rounded, color: Colors.amber.shade800, size: 22),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Missing Python Packages: ${missing.join(', ')}',
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.amber.shade900),
                              ),
                              const SizedBox(height: 2),
                              SelectableText(
                                'Run in terminal / virtual environment: pip install ${missing.join(' ')}',
                                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
            if (_statusMessage.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(_statusMessage, style: TextStyle(fontSize: 12, color: Colors.grey.shade700, fontStyle: FontStyle.italic)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildConfigurationCard() {
    final catCols = (_inspectionData?['categorical_columns'] as List<dynamic>? ?? []).cast<String>();
    final allCols = [
      ?_selectedGroupCol,
      ...catCols.where((c) => c != _selectedGroupCol),
    ];
    final subgrpOptions = ['None', ...catCols];
    final channelOptions = ['None', ...catCols];
    final candidateSubj = (_inspectionData?['categorical_columns'] as List<dynamic>? ?? []).cast<String>();
    final extraFactorCandidates = catCols
        .where((c) => c != _selectedGroupCol && c != _selectedSubgroupCol && c != _selectedSubjectIdCol && c != _selectedChannelCol)
        .toList();

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.tune, size: 20, color: Color(0xFF1F4E79)),
                SizedBox(width: 8),
                Text('Model Specification & Factors', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedGroupCol,
                    decoration: const InputDecoration(
                      labelText: 'Primary Grouping Factor (Cohort)',
                      border: OutlineInputBorder(),
                      isDense: true,
                      helperText: 'e.g. Group, groupID, ageID, Condition',
                    ),
                    items: [
                      for (final col in allCols)
                        DropdownMenuItem(value: col, child: Text(col, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (val) => setState(() => _selectedGroupCol = val),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedSubgroupCol ?? 'None',
                    decoration: const InputDecoration(
                      labelText: 'Secondary / Within-Subject Factor',
                      border: OutlineInputBorder(),
                      isDense: true,
                      helperText: 'e.g. Status, Session, Condition, Chan',
                    ),
                    items: [
                      for (final col in subgrpOptions)
                        DropdownMenuItem(value: col, child: Text(col, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (val) => setState(() => _selectedSubgroupCol = val),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedSubjectIdCol,
                    decoration: const InputDecoration(
                      labelText: 'Subject Identifier (Random Effect)',
                      border: OutlineInputBorder(),
                      isDense: true,
                      helperText: 'Clustering identifier for repeated measures',
                    ),
                    items: [
                      if (_selectedSubjectIdCol != null && !candidateSubj.contains(_selectedSubjectIdCol))
                        DropdownMenuItem(value: _selectedSubjectIdCol, child: Text(_selectedSubjectIdCol!)),
                      for (final col in candidateSubj)
                        DropdownMenuItem(value: col, child: Text(col, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (val) => setState(() => _selectedSubjectIdCol = val),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: (_selectedChannelCol != null && channelOptions.contains(_selectedChannelCol))
                        ? _selectedChannelCol
                        : 'None',
                    decoration: const InputDecoration(
                      labelText: 'Channel / Spatial Factor (Definable)',
                      border: OutlineInputBorder(),
                      isDense: true,
                      helperText: 'Electrode column for scalp topoplots; skipped for macro/CAP',
                    ),
                    items: [
                      for (final col in channelOptions)
                        DropdownMenuItem(value: col, child: Text(col, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (val) => setState(() => _selectedChannelCol = val),
                  ),
                ),
              ],
            ),
            if (extraFactorCandidates.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text(
                    'Additional Factors (Multi-Factor LMM/GLM):',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 16),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: _includeInteractions,
                        visualDensity: VisualDensity.compact,
                        onChanged: (v) => setState(() => _includeInteractions = v ?? true),
                      ),
                      const Text('Include interaction terms (Group × Factor)', style: TextStyle(fontSize: 12)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final ef in extraFactorCandidates)
                    FilterChip(
                      label: Text(ef),
                      selected: _selectedExtraFactors.contains(ef),
                      onSelected: (sel) {
                        setState(() {
                          if (sel) {
                            _selectedExtraFactors.add(ef);
                          } else {
                            _selectedExtraFactors.remove(ef);
                          }
                        });
                      },
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            const Text('Continuous Covariates to Adjust For:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final cov in (_inspectionData?['covariates'] as List<dynamic>? ?? []).cast<String>())
                  FilterChip(
                    label: Text(cov),
                    selected: _selectedCovariates.contains(cov),
                    onSelected: (sel) {
                      setState(() {
                        if (sel) {
                          _selectedCovariates.add(cov);
                        } else {
                          _selectedCovariates.remove(cov);
                        }
                      });
                    },
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _preferredModel,
                    decoration: const InputDecoration(
                      labelText: 'Statistical Model Approach',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(value: 'auto', child: Text('Auto (SOTA: LMM for repeated, GLM for single)')),
                      DropdownMenuItem(value: 'lmm', child: Text('Linear Mixed Model (LMM - Random Intercepts)')),
                      DropdownMenuItem(value: 'glm', child: Text('General Linear Model (GLM / ANOVA Type II)')),
                    ],
                    onChanged: (v) => setState(() => _preferredModel = v ?? 'auto'),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _posthocMethod,
                    decoration: const InputDecoration(
                      labelText: 'Post-Hoc Multiple Testing Adjustment',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(value: 'fdr', child: Text('Benjamini-Hochberg FDR (Recommended)')),
                      DropdownMenuItem(value: 'tukey', child: Text('Tukey HSD / Pairwise contrasts')),
                      DropdownMenuItem(value: 'bonferroni', child: Text('Bonferroni (Strict)')),
                    ],
                    onChanged: (v) => setState(() => _posthocMethod = v ?? 'fdr'),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _reportFormat,
                    decoration: const InputDecoration(
                      labelText: 'Scientific Report Output Format',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(value: 'both', child: Text('Both Word (.docx) & PDF (.pdf)')),
                      DropdownMenuItem(value: 'docx', child: Text('Microsoft Word Document (.docx)')),
                      DropdownMenuItem(value: 'pdf', child: Text('Portable Document Format (.pdf)')),
                    ],
                    onChanged: (v) => setState(() => _reportFormat = v ?? 'both'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFactorFilterAndOrderSection(String title, String factorCol) {
    final levels = _levelsForFactor(factorCol);
    if (levels.isEmpty) return const SizedBox.shrink();
    final excluded = _excludedFactorLabels.putIfAbsent(factorCol, () => <String>{});

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '$title: $factorCol',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF1F4E79)),
              ),
              const SizedBox(width: 8),
              const Text(
                '(Click checkbox to include/exclude label · Use arrows ◀ ▶ to set plot order)',
                style: TextStyle(fontSize: 11, color: Colors.black54),
              ),
              const Spacer(),
              if (excluded.isNotEmpty || _customFactorOrder.containsKey(factorCol))
                TextButton(
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: () {
                    setState(() {
                      excluded.clear();
                      _customFactorOrder.remove(factorCol);
                    });
                  },
                  child: const Text('Reset', style: TextStyle(fontSize: 11)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var i = 0; i < levels.length; i++)
                Builder(
                  builder: (context) {
                    final lvl = levels[i];
                    final isIncluded = !excluded.contains(lvl);
                    final count = _countForFactorLevel(factorCol, lvl);
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isIncluded ? const Color(0xFFEFF6FF) : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isIncluded ? const Color(0xFF3B82F6) : Colors.grey.shade400,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          InkWell(
                            onTap: i > 0 ? () => _moveFactorLevel(factorCol, lvl, -1) : null,
                            child: Icon(
                              Icons.chevron_left,
                              size: 16,
                              color: i > 0 ? const Color(0xFF1F4E79) : Colors.grey.shade400,
                            ),
                          ),
                          InkWell(
                            onTap: () {
                              setState(() {
                                if (isIncluded) {
                                  excluded.add(lvl);
                                } else {
                                  excluded.remove(lvl);
                                }
                              });
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    isIncluded ? Icons.check_box : Icons.check_box_outline_blank,
                                    size: 15,
                                    color: isIncluded ? const Color(0xFF1F4E79) : Colors.grey.shade600,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '${i + 1}. $lvl ($count)',
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: isIncluded ? FontWeight.w600 : FontWeight.normal,
                                      decoration: isIncluded ? null : TextDecoration.lineThrough,
                                      color: isIncluded ? const Color(0xFF1E293B) : Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: i < levels.length - 1 ? () => _moveFactorLevel(factorCol, lvl, 1) : null,
                            child: Icon(
                              Icons.chevron_right,
                              size: 16,
                              color: i < levels.length - 1 ? const Color(0xFF1F4E79) : Colors.grey.shade400,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilteringAndOrderCard() {
    final filterableCols = (_inspectionData?['filterable_columns'] as List<dynamic>? ?? []).cast<String>();
    final distinctMap = _inspectionData?['column_distinct_values'] as Map<String, dynamic>? ?? {};
    final draftSuggestions = (_draftFilterColumn != null && distinctMap.containsKey(_draftFilterColumn))
        ? (distinctMap[_draftFilterColumn] as List<dynamic>).map((e) => e.toString()).toList()
        : const <String>[];

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.filter_alt_outlined, size: 20, color: Color(0xFF1F4E79)),
                SizedBox(width: 8),
                Text(
                  'Interactive Factor Label Filtering, Plot Ordering & Row Value Exclusion',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_selectedGroupCol != null)
              _buildFactorFilterAndOrderSection('Primary Grouping Factor', _selectedGroupCol!),
            if (_selectedSubgroupCol != null && _selectedSubgroupCol != 'None')
              _buildFactorFilterAndOrderSection('Secondary / Within-Subject Factor', _selectedSubgroupCol!),
            for (final ef in _selectedExtraFactors)
              _buildFactorFilterAndOrderSection('Additional Factor', ef),
            const Divider(height: 18),
            const Text(
              'Filter Out Rows with Particular Values:',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF1F4E79)),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 220,
                  child: DropdownButtonFormField<String>(
                    value: filterableCols.contains(_draftFilterColumn) ? _draftFilterColumn : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Column',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final c in filterableCols)
                        DropdownMenuItem(value: c, child: Text(c, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (v) => setState(() => _draftFilterColumn = v),
                  ),
                ),
                SizedBox(
                  width: 210,
                  child: DropdownButtonFormField<String>(
                    value: _draftFilterOp,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Exclusion Rule',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(value: '==', child: Text('Exclude where == value')),
                      DropdownMenuItem(value: '!=', child: Text('Exclude where != value (Keep only)')),
                      DropdownMenuItem(value: '<', child: Text('Exclude where < value')),
                      DropdownMenuItem(value: '<=', child: Text('Exclude where <= value')),
                      DropdownMenuItem(value: '>', child: Text('Exclude where > value')),
                      DropdownMenuItem(value: '>=', child: Text('Exclude where >= value')),
                      DropdownMenuItem(value: 'contains', child: Text('Exclude where text contains')),
                      DropdownMenuItem(value: 'is_na', child: Text('Exclude missing / empty rows')),
                    ],
                    onChanged: (v) => setState(() => _draftFilterOp = v ?? '=='),
                  ),
                ),
                if (_draftFilterOp != 'is_na')
                  SizedBox(
                    width: 220,
                    child: TextField(
                      controller: _rowFilterValueController,
                      decoration: InputDecoration(
                        labelText: 'Value',
                        hintText: 'Enter value to filter',
                        border: const OutlineInputBorder(),
                        isDense: true,
                        suffixIcon: draftSuggestions.isNotEmpty
                            ? PopupMenuButton<String>(
                                icon: const Icon(Icons.arrow_drop_down, size: 20),
                                tooltip: 'Pick from existing values in column',
                                onSelected: (v) => setState(() => _rowFilterValueController.text = v),
                                itemBuilder: (_) => [
                                  for (final s in draftSuggestions)
                                    PopupMenuItem(value: s, child: Text(s)),
                                ],
                              )
                            : null,
                      ),
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: () {
                    if (_draftFilterColumn == null) return;
                    final val = _rowFilterValueController.text.trim();
                    if (_draftFilterOp != 'is_na' && val.isEmpty) {
                      _showSnack('Enter or pick a value for the row filter.');
                      return;
                    }
                    setState(() {
                      _rowFilters.add({
                        'column': _draftFilterColumn!,
                        'op': _draftFilterOp,
                        'value': _draftFilterOp == 'is_na' ? 'NA' : val,
                      });
                      _rowFilterValueController.clear();
                    });
                  },
                  icon: const Icon(Icons.add_circle_outline, size: 16),
                  label: const Text('Add Row Filter'),
                ),
                if (_rowFilters.isNotEmpty)
                  TextButton(
                    onPressed: () => setState(() => _rowFilters.clear()),
                    child: const Text('Clear Filters'),
                  ),
              ],
            ),
            if (_rowFilters.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < _rowFilters.length; i++)
                    Chip(
                      backgroundColor: Colors.orange.shade50,
                      label: Text(
                        'Exclude ${_rowFilters[i]['column']} ${_rowFilters[i]['op']} ${_rowFilters[i]['value']}',
                        style: TextStyle(fontSize: 11.5, color: Colors.orange.shade900, fontWeight: FontWeight.w600),
                      ),
                      deleteIcon: const Icon(Icons.close, size: 15),
                      onDeleted: () => setState(() => _rowFilters.removeAt(i)),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMetricsSelectionCard() {
    final catMap = (_inspectionData?['categorized_metrics'] as Map<String, dynamic>? ?? {})
        .map((k, v) => MapEntry(k, (v as List<dynamic>).cast<String>()));

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.check_box_outlined, size: 20, color: Color(0xFF1F4E79)),
                const SizedBox(width: 8),
                Text('Dependent Variables / Metrics (${_selectedMetrics.length} selected)',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _selectedMetrics.clear();
                    });
                  },
                  child: const Text('Clear All'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final entry in catMap.entries)
                  ActionChip(
                    avatar: Icon(
                      entry.value.every((m) => _selectedMetrics.contains(m)) ? Icons.check_circle : Icons.add_circle_outline,
                      size: 16,
                      color: const Color(0xFF1F4E79),
                    ),
                    label: Text('${entry.key} (${entry.value.length})'),
                    onPressed: () {
                      setState(() {
                        final allSelected = entry.value.every((m) => _selectedMetrics.contains(m));
                        if (allSelected) {
                          _selectedMetrics.removeAll(entry.value);
                        } else {
                          _selectedMetrics.addAll(entry.value);
                        }
                      });
                    },
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              height: 150,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(8),
                color: Colors.grey.shade50,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final m in (_inspectionData?['metric_columns'] as List<dynamic>? ?? []).cast<String>())
                      FilterChip(
                        label: Text(m, style: const TextStyle(fontSize: 11)),
                        selected: _selectedMetrics.contains(m),
                        onSelected: (sel) {
                          setState(() {
                            if (sel) {
                              _selectedMetrics.add(m);
                            } else {
                              _selectedMetrics.remove(m);
                            }
                          });
                        },
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionRunCard() {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _isAnalyzing ? null : _runAnalysis,
                    icon: _isAnalyzing
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.play_arrow),
                    label: Text(_isAnalyzing ? 'Running Models & Generating Report…' : 'Run Group Statistical Analysis (${_selectedMetrics.length} Metrics)'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1F4E79),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
            if (_isAnalyzing) ...[
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _analysisProgress > 0 ? _analysisProgress : null,
                  minHeight: 8,
                  backgroundColor: Colors.grey.shade200,
                  valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF1F4E79)),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      _progressStatus.isNotEmpty ? _progressStatus : 'Running group analysis models…',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.blueGrey.shade800),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_analysisProgress > 0)
                    Text(
                      '${(_analysisProgress * 100).toInt()}%',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blueGrey.shade800),
                    ),
                ],
              ),
            ],
            if (_isAnalyzing || _consoleLogs.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                height: 110,
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  itemCount: _consoleLogs.length,
                  itemBuilder: (ctx, i) => Text(
                    _consoleLogs[i],
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFF4AF626)),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildResultsCard() {
    final outputDir = _analysisResults!['output_dir'] as String? ?? '';
    final docxPath = _analysisResults!['docx_path'] as String?;
    final pdfPath = _analysisResults!['pdf_path'] as String?;
    final resList = (_analysisResults!['results'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

    final activeResult = resList.firstWhere(
      (r) => r['metric'] == _selectedResultMetric,
      orElse: () => resList.isNotEmpty ? resList.first : {},
    );

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.folder_special_outlined, color: Color(0xFF1F4E79), size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Analysis Results & Publications', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      Text('Saved to: $outputDir', style: TextStyle(fontSize: 11, color: Colors.grey.shade600), overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => _openPath(outputDir),
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('Open Folder'),
                ),
                const SizedBox(width: 8),
                if (docxPath != null)
                  FilledButton.icon(
                    onPressed: () => _openPath(docxPath),
                    icon: const Icon(Icons.description, size: 16),
                    label: const Text('Word (.docx)'),
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1F4E79)),
                  ),
                const SizedBox(width: 8),
                if (pdfPath != null)
                  FilledButton.icon(
                    onPressed: () => _openPath(pdfPath),
                    icon: const Icon(Icons.picture_as_pdf, size: 16),
                    label: const Text('PDF Report'),
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD32F2F)),
                  ),
              ],
            ),
            const Divider(height: 24),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final r in resList)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(r['metric'] as String),
                        selected: _selectedResultMetric == r['metric'],
                        onSelected: (sel) {
                          if (sel) {
                            setState(() => _selectedResultMetric = r['metric'] as String);
                          }
                        },
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, icon: Icon(Icons.image_outlined, size: 16), label: Text('Publication Plot & eTFCE')),
                    ButtonSegment(value: 1, icon: Icon(Icons.table_chart_outlined, size: 16), label: Text('Model Effects')),
                    ButtonSegment(value: 2, icon: Icon(Icons.compare_arrows_outlined, size: 16), label: Text('Post-Hoc Contrasts')),
                    ButtonSegment(value: 3, icon: Icon(Icons.summarize_outlined, size: 16), label: Text('Descriptive Stats')),
                  ],
                  selected: {_activeResultTabIndex},
                  onSelectionChanged: (s) => setState(() => _activeResultTabIndex = s.first),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (activeResult.isNotEmpty) ...[
              if (_activeResultTabIndex == 0) _buildPlotTab(activeResult),
              if (_activeResultTabIndex == 1) _buildModelEffectsTab(activeResult),
              if (_activeResultTabIndex == 2) _buildPostHocTab(activeResult),
              if (_activeResultTabIndex == 3) _buildDescriptivesTab(activeResult),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPlotTab(Map<String, dynamic> res) {
    final plotPath = res['plot_path'] as String? ?? '';
    final topoPath = res['topoplot_path'] as String? ?? '';
    final unit = res['unit'] as String? ?? '';
    final isMacro = res['is_macroarchitecture'] == true;
    final etfceChannels = (res['etfce_channels'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

    final hasTopo = topoPath.isNotEmpty && File(topoPath).existsSync();
    final currentPath = (_activePlotView == 1 && hasTopo) ? topoPath : plotPath;
    final file = File(currentPath);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '${res['metric']}${unit.isNotEmpty ? ' ($unit)' : ''} · ${res['model_type']} · '
                      'N=${res['n_subjects'] ?? res['n_obs']} subj (n=${res['n_obs']} obs)',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF1F4E79)),
                    ),
                    if (isMacro)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade100,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.amber.shade400),
                        ),
                        child: Text(
                          'Macroarchitecture (Subject-Level; Channel-Invariant)',
                          style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.amber.shade900),
                        ),
                      ),
                  ],
                ),
              ),
              if (hasTopo)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, icon: Icon(Icons.bar_chart, size: 14), label: Text('Boxplot & Post-hoc')),
                      ButtonSegment(value: 1, icon: Icon(Icons.blur_circular, size: 14), label: Text('Scalp Topoplot + eTFCE')),
                    ],
                    selected: {_activePlotView},
                    onSelectionChanged: (s) => setState(() => _activePlotView = s.first),
                  ),
                ),
              TextButton.icon(
                onPressed: file.existsSync() ? () => _openPath(currentPath) : null,
                icon: const Icon(Icons.zoom_in, size: 16),
                label: const Text('Open Full 400-DPI Image'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (file.existsSync())
            Center(
              child: Container(
                constraints: const BoxConstraints(maxHeight: 500),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 4.0,
                  child: Image.file(
                    file,
                    key: ValueKey('${file.path}-${file.lastModifiedSync().millisecondsSinceEpoch}'),
                    height: 460,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                  ),
                ),
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('Plot image not found.')),
            ),
          if (_activePlotView == 1 && hasTopo && etfceChannels.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text(
              'Spatial eTFCE (Threshold-Free Cluster Enhancement) Permutation Results:',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: Color(0xFF1F4E79)),
            ),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 32,
                dataRowMinHeight: 28,
                dataRowMaxHeight: 32,
                columns: const [
                  DataColumn(label: Text('Channel / Region', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                  DataColumn(label: Text('Raw Statistic (t / F)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                  DataColumn(label: Text('eTFCE Score', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                  DataColumn(label: Text('p (eTFCE FWER)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                  DataColumn(label: Text('Significance', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                ],
                rows: [
                  for (final ch in etfceChannels)
                    DataRow(
                      cells: [
                        DataCell(Text('${ch['channel'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w600))),
                        DataCell(Text((ch['raw_stat'] as num?)?.toStringAsFixed(3) ?? '-')),
                        DataCell(Text((ch['etfce_score'] as num?)?.toStringAsFixed(3) ?? '-')),
                        DataCell(Text(_formatP(ch['p_etfce'] as num?))),
                        DataCell(_buildSigBadge(ch['significance'] as String? ?? 'ns')),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildModelEffectsTab(Map<String, dynamic> res) {
    final effects = (res['model_effects'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

    if (effects.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('No model effects recorded.')),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(label: Text('Factor / Term', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('N (Subj / Obs)', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Stat Type', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Statistic', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('df', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('p-value', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Effect Size (ηp²)', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Significance', style: TextStyle(fontWeight: FontWeight.bold))),
        ],
        rows: [
          for (final eff in effects)
            DataRow(
              cells: [
                DataCell(Text(eff['term'] as String? ?? '')),
                DataCell(Text('${eff['n_subjects'] ?? res['n_subjects'] ?? '-'} / ${eff['n_obs'] ?? res['n_obs'] ?? '-'}')),
                DataCell(Text(eff['stat_type'] as String? ?? '')),
                DataCell(Text((eff['statistic'] as num?)?.toStringAsFixed(3) ?? '-')),
                DataCell(Text('${eff['df'] ?? 1}${eff['df_resid'] != null ? ', ${eff['df_resid']}' : ''}')),
                DataCell(Text(_formatP(eff['p_value'] as num?))),
                DataCell(Text((eff['effect_size'] as num?)?.toStringAsFixed(3) ?? '-')),
                DataCell(_buildSigBadge(eff['significance'] as String? ?? 'ns')),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildPostHocTab(Map<String, dynamic> res) {
    final contrasts = (res['posthoc_contrasts'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

    if (contrasts.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('No post-hoc contrasts available.')),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(label: Text('Factor Level', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Comparison', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('N (n1 vs n2)', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Mean Diff', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('t-stat', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('p (raw)', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('p (adjusted)', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Cohen’s d', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Hedges’ g', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Sig.', style: TextStyle(fontWeight: FontWeight.bold))),
        ],
        rows: [
          for (final c in contrasts)
            DataRow(
              cells: [
                DataCell(Text(c['level']?.toString() ?? 'Overall')),
                DataCell(Text('${c['group1']} vs ${c['group2']}')),
                DataCell(Text('${c['n1'] ?? '-'} vs ${c['n2'] ?? '-'}')),
                DataCell(Text((c['diff'] as num?)?.toStringAsFixed(3) ?? '-')),
                DataCell(Text((c['t_stat'] as num?)?.toStringAsFixed(3) ?? '-')),
                DataCell(Text(_formatP(c['p_raw'] as num?))),
                DataCell(Text(_formatP(c['p_adj'] as num?))),
                DataCell(Text((c['cohen_d'] as num?)?.toStringAsFixed(2) ?? '-')),
                DataCell(Text((c['hedges_g'] as num?)?.toStringAsFixed(2) ?? '-')),
                DataCell(_buildSigBadge(c['significance'] as String? ?? 'ns')),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildDescriptivesTab(Map<String, dynamic> res) {
    final stats = (res['descriptive_stats'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();

    if (stats.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('No descriptive statistics available.')),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(label: Text('Group', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Subgroup', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('N (Subj / Obs)', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Mean ± SD', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Median (IQR)', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Min', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Max', style: TextStyle(fontWeight: FontWeight.bold))),
        ],
        rows: [
          for (final s in stats)
            DataRow(
              cells: [
                DataCell(Text(s['group']?.toString() ?? '-')),
                DataCell(Text(s['subgroup']?.toString() ?? '-')),
                DataCell(Text('${s['n_subjects'] ?? s['n'] ?? 0} / ${s['n'] ?? 0}')),
                DataCell(Text('${(s['mean'] as num?)?.toStringAsFixed(2)} ± ${(s['std'] as num?)?.toStringAsFixed(2)}')),
                DataCell(Text('${(s['median'] as num?)?.toStringAsFixed(2)} (${(s['iqr'] as num?)?.toStringAsFixed(2)})')),
                DataCell(Text((s['min'] as num?)?.toStringAsFixed(2) ?? '-')),
                DataCell(Text((s['max'] as num?)?.toStringAsFixed(2) ?? '-')),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildSigBadge(String sig) {
    final isSig = sig != 'ns' && sig != 'n/a';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isSig ? Colors.green.shade50 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isSig ? Colors.green.shade400 : Colors.grey.shade300),
      ),
      child: Text(
        sig,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: isSig ? Colors.green.shade800 : Colors.grey.shade600,
        ),
      ),
    );
  }

  String _formatP(num? p) {
    if (p == null) return 'n/a';
    if (p < 0.0001) return '< 0.0001';
    if (p < 0.001) return p.toStringAsFixed(4);
    return p.toStringAsFixed(3);
  }
}
