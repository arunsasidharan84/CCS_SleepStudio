import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

import 'batch_helpers.dart';

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
  final TextEditingController _csvPathController = TextEditingController();
  final TextEditingController _metadataPathController = TextEditingController();
  final TextEditingController _metadataKeyController = TextEditingController();

  bool _isInspecting = false;
  bool _isAnalyzing = false;
  String _statusMessage = '';
  final List<String> _consoleLogs = [];

  // Inspected Metadata
  Map<String, dynamic>? _inspectionData;
  String? _selectedGroupCol;
  String? _selectedSubgroupCol;
  String? _selectedSubjectIdCol;
  final Set<String> _selectedCovariates = {};
  final Set<String> _selectedMetrics = {};

  // Modelling preferences
  String _preferredModel = 'auto'; // 'auto', 'lmm', 'glm'
  String _posthocMethod = 'fdr'; // 'fdr', 'tukey', 'bonferroni'
  String _reportFormat = 'both'; // 'both', 'docx', 'pdf'

  // Analysis Results
  Map<String, dynamic>? _analysisResults;
  String? _selectedResultMetric;
  int _activeResultTabIndex = 0; // 0: Plot, 1: Model Effects, 2: Post-Hoc, 3: Descriptives

  @override
  void initState() {
    super.initState();
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
    super.dispose();
  }

  static Future<String?> _findPythonExecutable() async {
    final candidates = [
      if (Platform.isWindows) 'python.exe',
      if (Platform.isWindows) r'C:\Python312\python.exe',
      if (Platform.isWindows) r'C:\Python311\python.exe',
      if (Platform.isMacOS) '/Users/arunsasidharan/miniconda3/bin/python3',
      if (Platform.isMacOS) '/opt/homebrew/bin/python3',
      if (Platform.isMacOS) '/usr/local/bin/python3',
      if (Platform.isLinux) '/usr/bin/python3',
      'python3',
      'python',
    ];
    for (final cand in candidates) {
      try {
        final res = await Process.run(cand, ['--version']);
        if (res.exitCode == 0) return cand;
      } catch (_) {}
    }
    return null;
  }

  static String _findGroupStatsScript() {
    final currentDir = Directory.current.path;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      '$currentDir/backend/group_stats.py',
      '$currentDir/../backend/group_stats.py',
      '$exeDir/backend/group_stats.py',
      '$exeDir/../Resources/backend/group_stats.py',
      '$exeDir/../lib/ccs-sleep-studio/backend/group_stats.py',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return '$currentDir/backend/group_stats.py';
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
      final python = await _findPythonExecutable();
      if (python == null) {
        throw StateError('Python 3 environment not found. Please install Python with pandas and statsmodels.');
      }
      final script = _findGroupStatsScript();

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
        _selectedCovariates.clear();
        final detectedCovs = (jsonMap['covariates'] as List<dynamic>? ?? []).cast<String>();
        _selectedCovariates.addAll(detectedCovs.take(2)); // default to age, gender

        _selectedMetrics.clear();
        // Default selection: priority metrics
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

    setState(() {
      _isAnalyzing = true;
      _statusMessage = 'Running group statistical analysis…';
      _consoleLogs.clear();
    });

    try {
      final python = await _findPythonExecutable();
      if (python == null) {
        throw StateError('Python 3 environment not found.');
      }
      final script = _findGroupStatsScript();

      final args = [
        script,
        '--csv', csvPath,
        '--group', _selectedGroupCol!,
        if (_selectedSubgroupCol != null && _selectedSubgroupCol != 'None') ...[
          '--subgroup', _selectedSubgroupCol!,
        ],
        if (_selectedSubjectIdCol != null) ...[
          '--subject-id', _selectedSubjectIdCol!,
        ],
        if (_selectedCovariates.isNotEmpty) ...[
          '--covariates', _selectedCovariates.join(','),
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
        _statusMessage = 'Analysis completed successfully! Generated ${_selectedMetrics.length} metric models, publication plots, and reports.';
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
                    'Perform state-of-the-art Linear Mixed-Effects Models (LMM) for multi-channel repeated measures and GLM for sleep architecture. Generates publication plots with post-hoc significance markers, datastamped CSV tables, and Word (DOCX) / PDF reports.',
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
    final candidateSubj = (_inspectionData?['categorical_columns'] as List<dynamic>? ?? []).cast<String>();

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
                // Primary Grouping Factor
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedGroupCol,
                    decoration: const InputDecoration(
                      labelText: 'Primary Grouping Factor (Cohort)',
                      border: OutlineInputBorder(),
                      isDense: true,
                      helperText: 'e.g. Group, groupID, Status, Condition',
                    ),
                    items: [
                      for (final col in allCols)
                        DropdownMenuItem(value: col, child: Text(col, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (val) => setState(() => _selectedGroupCol = val),
                  ),
                ),
                const SizedBox(width: 14),
                // Subgroup / Within-Subject Factor
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedSubgroupCol ?? 'None',
                    decoration: const InputDecoration(
                      labelText: 'Secondary / Within-Subject Factor',
                      border: OutlineInputBorder(),
                      isDense: true,
                      helperText: 'e.g. Chan (Electrode), ageID, Session',
                    ),
                    items: [
                      for (final col in subgrpOptions)
                        DropdownMenuItem(value: col, child: Text(col, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (val) => setState(() => _selectedSubgroupCol = val),
                  ),
                ),
                const SizedBox(width: 14),
                // Subject ID Column
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _selectedSubjectIdCol,
                    decoration: const InputDecoration(
                      labelText: 'Subject Identifier (Random Effect)',
                      border: OutlineInputBorder(),
                      isDense: true,
                      helperText: 'Clustering group for repeated measures',
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
              ],
            ),
            const SizedBox(height: 14),
            // Covariates selection
            const Text('Covariates to Adjust For:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
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
            // Model Approach & Report Preferences
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
            // Top action bar
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
            // Metric selector pills
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
            // Tabs: Plot, Model Effects, Post-Hoc, Descriptives
            Row(
              children: [
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, icon: Icon(Icons.image_outlined, size: 16), label: Text('Publication Plot')),
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
            // Active Tab Content
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
    final file = File(plotPath);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                '${res['metric']} · Model: ${res['model_type']} · N=${res['n_obs']}',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF1F4E79)),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: file.existsSync() ? () => _openPath(plotPath) : null,
                icon: const Icon(Icons.zoom_in, size: 16),
                label: const Text('View Full Image'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (file.existsSync())
            InkWell(
              onTap: () => _openPath(plotPath),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.file(
                  file,
                  height: 400,
                  fit: BoxFit.contain,
                ),
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text('Plot image not found.'),
            ),
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

    return DataTable(
      columns: const [
        DataColumn(label: Text('Factor / Term', style: TextStyle(fontWeight: FontWeight.bold))),
        DataColumn(label: Text('Statistic Type', style: TextStyle(fontWeight: FontWeight.bold))),
        DataColumn(label: Text('Value', style: TextStyle(fontWeight: FontWeight.bold))),
        DataColumn(label: Text('df', style: TextStyle(fontWeight: FontWeight.bold))),
        DataColumn(label: Text('p-value', style: TextStyle(fontWeight: FontWeight.bold))),
        DataColumn(label: Text('Significance', style: TextStyle(fontWeight: FontWeight.bold))),
      ],
      rows: [
        for (final eff in effects)
          DataRow(
            cells: [
              DataCell(Text(eff['term'] as String? ?? '')),
              DataCell(Text(eff['stat_type'] as String? ?? '')),
              DataCell(Text((eff['statistic'] as num?)?.toStringAsFixed(3) ?? '-')),
              DataCell(Text('${eff['df'] ?? 1}${eff['df_resid'] != null ? ', ${eff['df_resid']}' : ''}')),
              DataCell(Text(_formatP(eff['p_value'] as num?))),
              DataCell(_buildSigBadge(eff['significance'] as String? ?? 'ns')),
            ],
          ),
      ],
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
          DataColumn(label: Text('Mean Diff', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('t-stat', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('p (raw)', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('p (adjusted)', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Cohen’s d', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Sig.', style: TextStyle(fontWeight: FontWeight.bold))),
        ],
        rows: [
          for (final c in contrasts)
            DataRow(
              cells: [
                DataCell(Text(c['level'] as String? ?? 'Overall')),
                DataCell(Text('${c['group1']} vs ${c['group2']}')),
                DataCell(Text((c['diff'] as num?)?.toStringAsFixed(3) ?? '-')),
                DataCell(Text((c['t_stat'] as num?)?.toStringAsFixed(3) ?? '-')),
                DataCell(Text(_formatP(c['p_raw'] as num?))),
                DataCell(Text(_formatP(c['p_adj'] as num?))),
                DataCell(Text((c['cohen_d'] as num?)?.toStringAsFixed(2) ?? '-')),
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
          DataColumn(label: Text('N', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Mean ± SD', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Median (IQR)', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Min', style: TextStyle(fontWeight: FontWeight.bold))),
          DataColumn(label: Text('Max', style: TextStyle(fontWeight: FontWeight.bold))),
        ],
        rows: [
          for (final s in stats)
            DataRow(
              cells: [
                DataCell(Text(s['group'] as String? ?? '-')),
                DataCell(Text(s['subgroup'] as String? ?? '-')),
                DataCell(Text('${s['n'] ?? 0}')),
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
