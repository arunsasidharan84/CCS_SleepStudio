// Multi-scoring comparison (Compare menu): agreement of any number of
// scorings of the same recording against a chosen reference, with hypnogram
// strips, Cohen's kappa, confusion matrices and per-stage F1.

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'autoscore_command.dart';
import 'models.dart';
import 'scoring_io.dart';

/// The five scored stages in the order used by the confusion matrix.
const kCompareStages = [
  SleepStage.wake,
  SleepStage.n1,
  SleepStage.n2,
  SleepStage.n3,
  SleepStage.rem,
];

const _stageColors = {
  SleepStage.wake: Color(0xFFD9A441),
  SleepStage.n1: Color(0xFF8FB8DE),
  SleepStage.n2: Color(0xFF4F7CAC),
  SleepStage.n3: Color(0xFF1F3B63),
  SleepStage.rem: Color(0xFFC2566B),
};

/// Hypnogram strip rows from top: Wake, REM, N1, N2, N3.
const _stripLevel = {
  SleepStage.wake: 0,
  SleepStage.rem: 1,
  SleepStage.n1: 2,
  SleepStage.n2: 3,
  SleepStage.n3: 4,
};

/// Agreement of one scoring with the reference.
class ScoringAgreement {
  ScoringAgreement({
    required this.comparedEpochs,
    required this.accuracy,
    required this.kappa,
    required this.macroF1,
    required this.f1,
    required this.confusion,
    required this.referenceCounts,
    required this.otherCounts,
    required this.tstMinutes,
  });

  final int comparedEpochs;
  final double accuracy;
  final double kappa;
  final double macroF1;
  final Map<SleepStage, double> f1;

  /// confusion[i][j] = epochs with reference stage i scored as stage j
  /// (indices follow [kCompareStages]).
  final List<List<int>> confusion;
  final Map<SleepStage, int> referenceCounts;
  final Map<SleepStage, int> otherCounts;
  final double tstMinutes;

  static int _idx(SleepStage s) => kCompareStages.indexOf(s);

  factory ScoringAgreement.compute(
    List<SleepStage> reference,
    List<SleepStage> other, {
    int epochSeconds = 30,
  }) {
    final cm = List.generate(5, (_) => List.filled(5, 0));
    final n = math.min(reference.length, other.length);
    var total = 0;
    for (var i = 0; i < n; i++) {
      final a = _idx(reference[i]);
      final b = _idx(other[i]);
      if (a < 0 || b < 0) continue;
      cm[a][b]++;
      total++;
    }
    var agree = 0;
    for (var k = 0; k < 5; k++) {
      agree += cm[k][k];
    }
    final rowSum = [for (var i = 0; i < 5; i++) cm[i].fold<int>(0, (s, v) => s + v)];
    final colSum = [
      for (var j = 0; j < 5; j++) [for (var i = 0; i < 5; i++) cm[i][j]].fold<int>(0, (s, v) => s + v),
    ];
    final po = total == 0 ? 0.0 : agree / total;
    var pe = 0.0;
    if (total > 0) {
      for (var k = 0; k < 5; k++) {
        pe += (rowSum[k] / total) * (colSum[k] / total);
      }
    }
    final kappa = (total == 0 || pe >= 1) ? 0.0 : (po - pe) / (1 - pe);
    final f1 = <SleepStage, double>{};
    var f1Sum = 0.0;
    var f1Count = 0;
    for (var k = 0; k < 5; k++) {
      final tp = cm[k][k];
      final denom = rowSum[k] + colSum[k];
      final v = denom == 0 ? double.nan : 2 * tp / denom;
      f1[kCompareStages[k]] = v;
      if (rowSum[k] > 0 || colSum[k] > 0) {
        f1Sum += v.isNaN ? 0 : v;
        f1Count++;
      }
    }
    final otherCounts = <SleepStage, int>{
      for (final s in kCompareStages) s: other.where((x) => x == s).length,
    };
    final sleepEpochs = other
        .where((s) => s == SleepStage.n1 || s == SleepStage.n2 || s == SleepStage.n3 || s == SleepStage.rem)
        .length;
    return ScoringAgreement(
      comparedEpochs: total,
      accuracy: po,
      kappa: kappa,
      macroF1: f1Count == 0 ? 0 : f1Sum / f1Count,
      f1: f1,
      confusion: cm,
      referenceCounts: {
        for (final s in kCompareStages) s: reference.where((x) => x == s).length,
      },
      otherCounts: otherCounts,
      tstMinutes: sleepEpochs * epochSeconds / 60.0,
    );
  }

  String get verdict => kappa >= 0.75
      ? 'expert level'
      : kappa >= 0.6
      ? 'review needed'
      : 'unreliable';

  Color get verdictColor => kappa >= 0.75
      ? const Color(0xFF2F7D4F)
      : kappa >= 0.6
      ? const Color(0xFFB7791F)
      : const Color(0xFFB83B4B);
}

/// One scoring taking part in the comparison.
class CompareEntry {
  CompareEntry({
    required this.label,
    required this.stages,
    this.path,
    this.included = true,
  });

  final String label;
  final List<SleepStage> stages;
  final String? path;
  bool included;
}

/// Readable name for a scoring sidecar of `stem`.
String compareLabelForPath(String path, String stem) {
  final name = path.split(RegExp(r'[\\/]')).last;
  final lower = name.toLowerCase();
  var suffix = lower.startsWith(stem.toLowerCase()) ? lower.substring(stem.length) : lower;
  suffix = suffix.replaceFirst(RegExp(r'^[_\-. ]+'), '');
  final ext = suffix.contains('.') ? suffix.substring(suffix.lastIndexOf('.') + 1) : '';
  var core = suffix.contains('.') ? suffix.substring(0, suffix.lastIndexOf('.')) : suffix;
  if (core.contains('manual')) return 'Manual scoring${ext == 'edf' ? ' (EDF)' : ''}';
  core = core.replaceAll(RegExp(r'_?scoring$'), '');
  if (core.isEmpty) return ext == 'json' ? 'Saved scoring' : name;
  final sleepgpt = core.endsWith('_sleepgpt');
  final algo = sleepgpt ? core.substring(0, core.length - '_sleepgpt'.length) : core;
  final label = autoscoreAlgorithmLabel(algo);
  if (label != algo) return sleepgpt ? '$label + SleepGPT' : label;
  return name;
}

/// Scoring files that belong to `recordingPath` (same folder and stem).
List<String> findScoringSidecars(String recordingPath) {
  final file = File(recordingPath);
  final dir = file.parent;
  final name = file.uri.pathSegments.isEmpty ? recordingPath : file.uri.pathSegments.last;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  if (!dir.existsSync()) return const [];
  final out = <String>[];
  for (final f in dir.listSync(followLinks: false).whereType<File>()) {
    final n = f.uri.pathSegments.last;
    final lower = n.toLowerCase();
    if (f.path == file.path || !n.startsWith(stem)) continue;
    if (lower.contains('_analyse_') ||
        lower.endsWith('.config.json') ||
        lower.endsWith('_config.json') ||
        lower.endsWith('_respiratory.json') ||
        lower.endsWith('_plm.json') ||
        lower.endsWith('_cap.json') ||
        lower.endsWith('_events.json') ||
        lower.endsWith('_markers.json')) {
      continue;
    }
    final isScoring = lower.endsWith('.json') ||
        lower.endsWith('.vis') ||
        lower.endsWith('.annot') ||
        lower.endsWith('.esrc') ||
        lower.endsWith('.esedb') ||
        (lower.endsWith('.edf') && (lower.contains('scor') || lower.contains('hypno') || lower.contains('annot'))) ||
        ((lower.endsWith('.txt') || lower.endsWith('.csv')) && (lower.contains('scor') || lower.contains('hypno')));
    if (isScoring) out.add(f.path);
  }
  out.sort();
  return out;
}

bool _sameStages(List<SleepStage> a, List<SleepStage> b) {
  final n = math.min(a.length, b.length);
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return false;
  }
  for (var i = n; i < a.length; i++) {
    if (a[i].isScored) return false;
  }
  for (var i = n; i < b.length; i++) {
    if (b[i].isScored) return false;
  }
  return true;
}

Future<void> showMultiScoringCompareDialog(
  BuildContext context, {
  required String? recordingPath,
  required int epochCount,
  required List<SleepStage> currentStages,
  int epochSeconds = 30,
}) async {
  final entries = <CompareEntry>[];
  if (currentStages.any((s) => s.isScored)) {
    entries.add(CompareEntry(label: 'Current scoring (viewer)', stages: List.of(currentStages)));
  }
  if (recordingPath != null) {
    final name = recordingPath.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    for (final path in findScoringSidecars(recordingPath)) {
      final result = await loadScoringFile(path, epochCount: epochCount);
      if (result == null || !result.stages.any((s) => s.isScored)) continue;
      // The viewer's scoring is autosaved as <stem>_scoring.json: skip exact copies.
      if (entries.any((e) => _sameStages(e.stages, result.stages))) continue;
      entries.add(CompareEntry(label: compareLabelForPath(path, stem), stages: result.stages, path: path));
    }
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => MultiScoringCompareDialog(
      entries: entries,
      epochCount: epochCount,
      epochSeconds: epochSeconds,
    ),
  );
}

class MultiScoringCompareDialog extends StatefulWidget {
  const MultiScoringCompareDialog({
    super.key,
    required this.entries,
    required this.epochCount,
    this.epochSeconds = 30,
  });

  final List<CompareEntry> entries;
  final int epochCount;
  final int epochSeconds;

  @override
  State<MultiScoringCompareDialog> createState() => _MultiScoringCompareDialogState();
}

class _MultiScoringCompareDialogState extends State<MultiScoringCompareDialog> {
  late final List<CompareEntry> _entries = List.of(widget.entries);
  int _reference = 0;
  int? _selected;
  bool _sortByKappa = true;
  final _stripsKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    final manual = _entries.indexWhere((e) => e.label.toLowerCase().startsWith('manual'));
    _reference = manual >= 0 ? manual : 0;
  }

  List<(int, ScoringAgreement)> get _ranked {
    if (_entries.isEmpty) return const [];
    final ref = _entries[_reference].stages;
    final out = <(int, ScoringAgreement)>[
      for (var i = 0; i < _entries.length; i++)
        if (i != _reference && _entries[i].included)
          (i, ScoringAgreement.compute(ref, _entries[i].stages, epochSeconds: widget.epochSeconds)),
    ];
    if (_sortByKappa) out.sort((a, b) => b.$2.kappa.compareTo(a.$2.kappa));
    return out;
  }

  Future<void> _addFiles() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Add scoring files to compare',
      type: FileType.custom,
      allowMultiple: true,
      allowedExtensions: ['json', 'txt', 'csv', 'vis', 'annot', 'edf', 'esrc', 'esedb'],
    );
    final paths = result?.files.map((f) => f.path).whereType<String>().toList() ?? const [];
    for (final path in paths) {
      if (_entries.any((e) => e.path == path)) continue;
      final r = await loadScoringFile(path, epochCount: widget.epochCount);
      if (r == null) continue;
      _entries.add(CompareEntry(label: path.split(RegExp(r'[\\/]')).last, stages: r.stages, path: path));
    }
    if (mounted) setState(() {});
  }

  Future<void> _exportCsv(List<(int, ScoringAgreement)> ranked) async {
    final out = await FilePicker.saveFile(
      dialogTitle: 'Save scoring comparison (CSV)',
      fileName: 'scoring_comparison.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (out == null) return;
    final ref = _entries[_reference];
    final b = StringBuffer(
      'Reference,Scoring,Compared_epochs,Accuracy_pct,Cohens_kappa,Macro_F1,TST_min,'
      'F1_W,F1_N1,F1_N2,F1_N3,F1_REM,Verdict\n',
    );
    String q(String s) => '"${s.replaceAll('"', '""')}"';
    String f(double v, [int d = 3]) => v.isNaN ? '' : v.toStringAsFixed(d);
    for (final (i, a) in ranked) {
      b.write(
        '${q(ref.label)},${q(_entries[i].label)},${a.comparedEpochs},${f(a.accuracy * 100, 1)},'
        '${f(a.kappa)},${f(a.macroF1)},${f(a.tstMinutes, 1)},'
        '${kCompareStages.map((s) => f(a.f1[s] ?? double.nan)).join(',')},${a.verdict}\n',
      );
    }
    final path = out.toLowerCase().endsWith('.csv') ? out : '$out.csv';
    await File(path).writeAsString(b.toString());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved ${path.split(RegExp(r'[\\/]')).last}')));
    }
  }

  Future<void> _exportPng() async {
    final boundary = _stripsKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return;
    final out = await FilePicker.saveFile(
      dialogTitle: 'Save hypnogram comparison (PNG)',
      fileName: 'scoring_comparison.png',
      type: FileType.custom,
      allowedExtensions: ['png'],
    );
    if (out == null) return;
    final image = await boundary.toImage(pixelRatio: 2.5);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return;
    final path = out.toLowerCase().endsWith('.png') ? out : '$out.png';
    await File(path).writeAsBytes(bytes.buffer.asUint8List());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved ${path.split(RegExp(r'[\\/]')).last}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ranked = _ranked;
    final selected = ranked.isEmpty
        ? null
        : ranked.firstWhere((r) => r.$1 == _selected, orElse: () => ranked.first);
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      title: Row(
        children: [
          const Icon(Icons.compare_arrows, color: Color(0xFF0F6E74)),
          const SizedBox(width: 8),
          const Expanded(child: Text('Compare multiple scorings')),
          TextButton.icon(
            onPressed: _addFiles,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add scoring files…'),
          ),
        ],
      ),
      content: SizedBox(
        width: 1080,
        height: 760,
        child: _entries.length < 2
            ? const Center(
                child: Text(
                  'At least two scorings are needed. Save or autoscore this recording, or add scoring files.',
                ),
              )
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _entryTable(ranked),
                    const SizedBox(height: 14),
                    _sectionTitle('Hypnograms'),
                    RepaintBoundary(key: _stripsKey, child: _strips(ranked)),
                    const SizedBox(height: 14),
                    _sectionTitle('Confusion matrix'),
                    if (selected != null) _confusion(ranked, selected),
                  ],
                ),
              ),
      ),
      actions: [
        if (_entries.length >= 2) ...[
          TextButton.icon(
            onPressed: () => _exportCsv(ranked),
            icon: const Icon(Icons.table_chart_outlined, size: 16),
            label: const Text('Export CSV…'),
          ),
          TextButton.icon(
            onPressed: _exportPng,
            icon: const Icon(Icons.image_outlined, size: 16),
            label: const Text('Save hypnograms as PNG…'),
          ),
        ],
        ElevatedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
  );

  Widget _entryTable(List<(int, ScoringAgreement)> ranked) {
    final byIndex = {for (final r in ranked) r.$1: r.$2};
    const head = TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF5B6A78), letterSpacing: 0.4);
    const cell = TextStyle(fontSize: 12.5, fontFeatures: [ui.FontFeature.tabularFigures()]);
    return Container(
      decoration: BoxDecoration(border: Border.all(color: const Color(0xFFDDE3E9)), borderRadius: BorderRadius.circular(6)),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 70, child: Text('REFERENCE', style: head)),
              const SizedBox(width: 60, child: Text('SHOW', style: head)),
              const Expanded(child: Text('SCORING', style: head)),
              SizedBox(
                width: 90,
                child: InkWell(
                  onTap: () => setState(() => _sortByKappa = !_sortByKappa),
                  child: Text(_sortByKappa ? 'KAPPA ▼' : 'KAPPA', style: head, textAlign: TextAlign.right),
                ),
              ),
              const SizedBox(width: 90, child: Text('ACCURACY', style: head, textAlign: TextAlign.right)),
              const SizedBox(width: 90, child: Text('MACRO-F1', style: head, textAlign: TextAlign.right)),
              const SizedBox(width: 90, child: Text('TST (MIN)', style: head, textAlign: TextAlign.right)),
              const SizedBox(width: 130, child: Text('  STATUS', style: head)),
            ],
          ),
          const Divider(height: 8),
          for (var i = 0; i < _entries.length; i++)
            SizedBox(
              height: 30,
              child: Row(
                children: [
                  SizedBox(
                    width: 70,
                    child: Radio<int>(
                      value: i,
                      groupValue: _reference,
                      visualDensity: VisualDensity.compact,
                      onChanged: (v) => setState(() {
                        _reference = v ?? _reference;
                        _entries[_reference].included = true;
                        if (_selected == _reference) _selected = null;
                      }),
                    ),
                  ),
                  SizedBox(
                    width: 60,
                    child: Checkbox(
                      value: _entries[i].included,
                      visualDensity: VisualDensity.compact,
                      onChanged: i == _reference ? null : (v) => setState(() => _entries[i].included = v ?? true),
                    ),
                  ),
                  Expanded(
                    child: Tooltip(
                      message: _entries[i].path ?? 'Scoring currently shown in the viewer',
                      child: Text(
                        _entries[i].label,
                        overflow: TextOverflow.ellipsis,
                        style: cell.copyWith(fontWeight: i == _reference ? FontWeight.w600 : FontWeight.w400),
                      ),
                    ),
                  ),
                  ..._metricCells(i == _reference ? null : byIndex[i], cell, i == _reference),
                ],
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _metricCells(ScoringAgreement? a, TextStyle cell, bool isRef) {
    final ref = _entries[_reference].stages;
    final refTst = ref.where((s) => s == SleepStage.n1 || s == SleepStage.n2 || s == SleepStage.n3 || s == SleepStage.rem).length *
        widget.epochSeconds / 60.0;
    String f(double? v, [int d = 3]) => v == null || v.isNaN ? '–' : v.toStringAsFixed(d);
    return [
      SizedBox(width: 90, child: Text(isRef ? 'reference' : f(a?.kappa), style: cell, textAlign: TextAlign.right)),
      SizedBox(width: 90, child: Text(a == null ? '–' : '${(a.accuracy * 100).toStringAsFixed(1)} %', style: cell, textAlign: TextAlign.right)),
      SizedBox(width: 90, child: Text(f(a?.macroF1), style: cell, textAlign: TextAlign.right)),
      SizedBox(width: 90, child: Text(isRef ? refTst.toStringAsFixed(1) : f(a?.tstMinutes, 1), style: cell, textAlign: TextAlign.right)),
      SizedBox(
        width: 130,
        child: a == null
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                    decoration: BoxDecoration(
                      border: Border.all(color: a.verdictColor),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: Text(a.verdict, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: a.verdictColor)),
                  ),
                ),
              ),
      ),
    ];
  }

  Widget _strips(List<(int, ScoringAgreement)> ranked) {
    final rows = <(String, List<SleepStage>, String)>[
      (_entries[_reference].label, _entries[_reference].stages, 'ref'),
      for (final (i, a) in ranked) (_entries[i].label, _entries[i].stages, 'κ ${a.kappa.toStringAsFixed(2)}'),
    ];
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 16,
            children: [
              for (final s in [SleepStage.wake, SleepStage.n1, SleepStage.n2, SleepStage.n3, SleepStage.rem])
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 11, height: 11, decoration: BoxDecoration(color: _stageColors[s], borderRadius: BorderRadius.circular(2))),
                    const SizedBox(width: 5),
                    Text(s == SleepStage.wake ? 'Wake' : s.label, style: const TextStyle(fontSize: 12, color: Color(0xFF5B6A78))),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 8),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 190,
                    child: Text(r.$1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                  ),
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: CustomPaint(painter: _StripPainter(r.$2, widget.epochCount)),
                    ),
                  ),
                  SizedBox(
                    width: 70,
                    child: Text(
                      r.$3,
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: Color(0xFF5B6A78)),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Rows from top: Wake, REM, N1, N2, N3. ${widget.epochCount} epochs ≈ '
              '${(widget.epochCount * widget.epochSeconds / 3600).toStringAsFixed(1)} h. '
              'Reference: ${_entries[_reference].label}.',
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF5B6A78)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _confusion(List<(int, ScoringAgreement)> ranked, (int, ScoringAgreement) selected) {
    final a = selected.$2;
    final maxV = a.confusion.expand((r) => r).fold<int>(1, math.max);
    const head = TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF5B6A78));
    const mono = TextStyle(fontSize: 12.5, fontFamily: 'monospace');
    String name(SleepStage s) => s == SleepStage.wake ? 'WAKE' : s.label.toUpperCase();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 380,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Scoring', style: TextStyle(fontSize: 12, color: Color(0xFF5B6A78))),
              DropdownButton<int>(
                value: selected.$1,
                items: [
                  for (final (i, _) in ranked) DropdownMenuItem(value: i, child: Text(_entries[i].label)),
                ],
                onChanged: (v) => setState(() => _selected = v),
              ),
              const SizedBox(height: 8),
              Table(
                border: TableBorder.all(color: const Color(0xFFDDE3E9)),
                defaultColumnWidth: const FixedColumnWidth(58),
                children: [
                  TableRow(
                    children: [
                      const SizedBox(height: 30),
                      for (final s in kCompareStages)
                        SizedBox(height: 30, child: Center(child: Text(name(s), style: head))),
                    ],
                  ),
                  for (var i = 0; i < 5; i++)
                    TableRow(
                      children: [
                        SizedBox(height: 34, child: Center(child: Text(name(kCompareStages[i]), style: head))),
                        for (var j = 0; j < 5; j++)
                          Container(
                            height: 34,
                            color: (i == j ? const Color(0xFF0F6E74) : const Color(0xFFB83B4B))
                                .withOpacity(0.70 * a.confusion[i][j] / maxV),
                            child: Center(
                              child: Text(
                                '${a.confusion[i][j]}',
                                style: mono.copyWith(
                                  color: a.confusion[i][j] / maxV > 0.55 ? Colors.white : Colors.black87,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Rows: ${_entries[_reference].label}; columns: ${_entries[selected.$1].label}.',
                style: const TextStyle(fontSize: 11.5, color: Color(0xFF5B6A78)),
              ),
            ],
          ),
        ),
        const SizedBox(width: 28),
        Expanded(
          child: Table(
            columnWidths: const {0: FlexColumnWidth(1.2)},
            border: const TableBorder(horizontalInside: BorderSide(color: Color(0xFFDDE3E9))),
            children: [
              const TableRow(
                children: [
                  Padding(padding: EdgeInsets.all(6), child: Text('STAGE', style: head)),
                  Padding(padding: EdgeInsets.all(6), child: Text('REFERENCE EPOCHS', style: head, textAlign: TextAlign.right)),
                  Padding(padding: EdgeInsets.all(6), child: Text('SCORING EPOCHS', style: head, textAlign: TextAlign.right)),
                  Padding(padding: EdgeInsets.all(6), child: Text('F1', style: head, textAlign: TextAlign.right)),
                ],
              ),
              for (final s in kCompareStages)
                TableRow(
                  children: [
                    Padding(padding: const EdgeInsets.all(6), child: Text(s == SleepStage.wake ? 'Wake' : s.label)),
                    Padding(padding: const EdgeInsets.all(6), child: Text('${a.referenceCounts[s]}', style: mono, textAlign: TextAlign.right)),
                    Padding(padding: const EdgeInsets.all(6), child: Text('${a.otherCounts[s]}', style: mono, textAlign: TextAlign.right)),
                    Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text(
                        (a.f1[s] ?? double.nan).isNaN ? '–' : a.f1[s]!.toStringAsFixed(3),
                        style: mono,
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StripPainter extends CustomPainter {
  _StripPainter(this.stages, this.epochCount);

  final List<SleepStage> stages;
  final int epochCount;

  @override
  void paint(Canvas canvas, Size size) {
    final n = math.max(1, math.max(epochCount, stages.length));
    const rows = 5;
    final rowH = size.height / rows;
    final grid = Paint()
      ..color = const Color(0xFFE8EDF1)
      ..strokeWidth = 1;
    for (var r = 0; r < rows; r++) {
      final y = r * rowH + rowH / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    var i = 0;
    while (i < stages.length) {
      var j = i;
      while (j < stages.length && stages[j] == stages[i]) {
        j++;
      }
      final s = stages[i];
      final level = _stripLevel[s];
      if (level != null) {
        final x0 = size.width * i / n;
        final w = math.max(size.width * (j - i) / n, 0.8);
        canvas.drawRect(
          Rect.fromLTWH(x0, level * rowH + rowH * 0.18, w, rowH * 0.64),
          Paint()..color = _stageColors[s]!,
        );
      }
      i = j;
    }
  }

  @override
  bool shouldRepaint(_StripPainter old) => !identical(old.stages, stages) || old.epochCount != epochCount;
}
