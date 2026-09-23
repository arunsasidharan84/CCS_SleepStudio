// Respiratory (OSA) and periodic limb movement (PLM) analysis front-end.
//
// The heavy lifting is done by the native `analyse-nidra` engine:
//   analyse-nidra --list-signals <edf>
//   analyse-nidra --respiratory <edf> [--scoring s.json] [--pressure ch] ...
//   analyse-nidra --plm <edf> [--scoring s.json] [--left ch] [--right ch] ...
// Both write a JSON sidecar (`<base>_respiratory.json`, `<base>_plm.json`) that
// this module turns into ScoredEvent markers, summary tables and PDF pages.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'eeg_backend.dart';

export 'psg_report_data.dart';

// ─── Signal listing ──────────────────────────────────────────────────────────

class PsgSignal {
  const PsgSignal({
    required this.label,
    required this.sfreq,
    this.unit = '',
    this.role,
  });

  final String label;
  final double sfreq;
  final String unit;
  final String? role;

  String get description {
    final rate = sfreq >= 10
        ? sfreq.toStringAsFixed(0)
        : sfreq.toStringAsFixed(sfreq >= 1 ? 1 : 2);
    final u = unit.trim().isEmpty ? '' : ', $unit';
    return '$label  ($rate Hz$u)';
  }
}

/// Lists the signals of [edfPath] with their guessed PSG role.
Future<List<PsgSignal>> listPsgSignals(String executable, String edfPath) async {
  final result = await Process.run(
    executable,
    ['--list-signals', edfPath],
    stdoutEncoding: const Utf8Codec(allowMalformed: true),
    stderrEncoding: const Utf8Codec(allowMalformed: true),
  );
  if (result.exitCode != 0) {
    throw Exception(
      'Could not read the signal list (exit ${result.exitCode}): ${result.stderr}',
    );
  }
  final text = result.stdout.toString();
  final start = text.indexOf('{');
  if (start < 0) throw Exception('Unexpected --list-signals output');
  final json = jsonDecode(text.substring(start)) as Map<String, dynamic>;
  final signals = <PsgSignal>[];
  for (final item in (json['signals'] as List? ?? const [])) {
    if (item is! Map) continue;
    signals.add(
      PsgSignal(
        label: item['label']?.toString() ?? '',
        sfreq: (item['sfreq'] as num?)?.toDouble() ?? 0,
        unit: item['unit']?.toString() ?? '',
        role: item['role']?.toString(),
      ),
    );
  }
  return signals;
}

String? _firstWithRole(List<PsgSignal> signals, String role, {int nth = 0}) {
  final matches = signals.where((s) => s.role == role).toList();
  return matches.length > nth ? matches[nth].label : null;
}

// ─── Shared widgets ──────────────────────────────────────────────────────────

class _ChannelDropdown extends StatelessWidget {
  const _ChannelDropdown({
    required this.label,
    required this.signals,
    required this.value,
    required this.onChanged,
    this.helper,
  });

  final String label;
  final List<PsgSignal> signals;
  final String? value;
  final ValueChanged<String?> onChanged;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    final labels = signals.map((s) => s.label).toSet();
    final current = value != null && labels.contains(value) ? value : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: DropdownButtonFormField<String?>(
        isExpanded: true,
        value: current,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        items: [
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('— not used —', style: TextStyle(color: Colors.black54)),
          ),
          for (final s in signals)
            DropdownMenuItem<String?>(
              value: s.label,
              child: Text(s.description, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

Widget _sectionTitle(String text) => Padding(
  padding: const EdgeInsets.only(top: 12, bottom: 4),
  child: Text(
    text,
    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
  ),
);

// ─── Respiratory dialog ─────────────────────────────────────────────────────

class RespiratoryAnalysisDialog extends StatefulWidget {
  const RespiratoryAnalysisDialog({
    super.key,
    required this.signals,
    required this.hasHypnogram,
    required this.hasManualArousals,
  });

  final List<PsgSignal> signals;
  final bool hasHypnogram;
  final bool hasManualArousals;

  @override
  State<RespiratoryAnalysisDialog> createState() =>
      _RespiratoryAnalysisDialogState();
}

class _RespiratoryAnalysisDialogState extends State<RespiratoryAnalysisDialog> {
  late final Map<String, String?> _channels;
  int _hypopneaRule = 3;
  String _arousalMode = 'prefer-manual';
  final _supineController = TextEditingController();

  static const _fields = <(String, String, String?)>[
    ('thermal', 'Oronasal thermal sensor (apnea)', null),
    ('pressure', 'Nasal pressure (hypopnea)', null),
    ('flow', 'Other airflow signal', 'Used only when neither sensor above exists'),
    ('thorax', 'Thoracic effort (RIP)', null),
    ('abdomen', 'Abdominal effort (RIP)', null),
    ('effort-sum', 'RIPsum / summed effort', null),
    ('spo2', 'SpO₂', null),
    ('pulse', 'Pulse rate', null),
    ('ecg', 'ECG (for heart-rate response)', null),
    ('snore', 'Snore', null),
    ('position', 'Body position', null),
  ];

  @override
  void initState() {
    super.initState();
    final s = widget.signals;
    _channels = {
      'thermal': _firstWithRole(s, 'thermal'),
      'pressure': _firstWithRole(s, 'pressure'),
      'flow': _firstWithRole(s, 'flow'),
      'thorax': _firstWithRole(s, 'thorax'),
      'abdomen': _firstWithRole(s, 'abdomen'),
      'effort-sum': _firstWithRole(s, 'effort_sum'),
      'spo2': _firstWithRole(s, 'spo2'),
      'pulse': _firstWithRole(s, 'pulse'),
      'ecg': _firstWithRole(s, 'ecg'),
      'snore': _firstWithRole(s, 'snore'),
      'position': _firstWithRole(s, 'position'),
    };
    if (_channels['thermal'] != null || _channels['pressure'] != null) {
      _channels['flow'] = null;
    }
    if (!widget.hasManualArousals) _arousalMode = 'prefer-manual';
  }

  @override
  void dispose() {
    _supineController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasAirflow = _channels['thermal'] != null ||
        _channels['pressure'] != null ||
        _channels['flow'] != null ||
        _channels['effort-sum'] != null ||
        _channels['thorax'] != null ||
        _channels['abdomen'] != null;
    return AlertDialog(
      title: const Text('Respiratory / OSA Analysis (AASM v3)'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.hasHypnogram
                    ? 'Events are scored during sleep using the current hypnogram; '
                        'indices use total sleep time.'
                    : 'No hypnogram: indices use monitoring time (REI-style) and '
                        'events in wake cannot be excluded. Score or autoscore '
                        'the recording first for AHI.',
                style: TextStyle(
                  fontSize: 12,
                  color: widget.hasHypnogram ? Colors.black54 : Colors.deepOrange,
                ),
              ),
              _sectionTitle('Channels (pre-selected from the recording)'),
              for (final f in _fields)
                _ChannelDropdown(
                  label: f.$2,
                  helper: f.$3,
                  signals: widget.signals,
                  value: _channels[f.$1],
                  onChanged: (v) => setState(() => _channels[f.$1] = v),
                ),
              _sectionTitle('Scoring rules'),
              DropdownButtonFormField<int>(
                value: _hypopneaRule,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Hypopnea rule',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 3,
                    child: Text('AASM 1A (recommended): ≥30% drop with ≥3% desaturation or arousal'),
                  ),
                  DropdownMenuItem(
                    value: 4,
                    child: Text('AASM 1B (CMS): ≥30% drop with ≥4% desaturation'),
                  ),
                ],
                onChanged: (v) => setState(() => _hypopneaRule = v ?? 3),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _arousalMode,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Arousals (for hypopnea 3%/arousal rule and RERAs)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'prefer-manual',
                    child: Text('Use scored arousal markers / EDF annotations'),
                  ),
                  DropdownMenuItem(
                    value: 'auto',
                    child: Text('Automatic EEG arousal detection (experimental)'),
                  ),
                  DropdownMenuItem(
                    value: 'none',
                    child: Text('Ignore arousals (desaturation criteria only)'),
                  ),
                ],
                onChanged: (v) => setState(() => _arousalMode = v ?? 'prefer-manual'),
              ),
              if (!widget.hasManualArousals && _arousalMode == 'prefer-manual')
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'No arousal markers found yet — hypopneas will be scored on '
                    'desaturation only unless arousals are present in the EDF annotations.',
                    style: TextStyle(fontSize: 11, color: Colors.black54),
                  ),
                ),
              if (_channels['position'] != null) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _supineController,
                  decoration: const InputDecoration(
                    labelText: 'Supine position code(s) (optional, comma-separated)',
                    hintText: 'Leave empty to auto-detect from the position channel',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              if (!hasAirflow)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Select at least one airflow or effort channel.',
                    style: TextStyle(color: Colors.red),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.air),
          label: const Text('Analyse'),
          onPressed: hasAirflow
              ? () => Navigator.of(context).pop(<String, dynamic>{
                  'channels': Map<String, String?>.from(_channels),
                  'hypopneaRule': _hypopneaRule,
                  'arousalMode': _arousalMode,
                  'supineCodes': _supineController.text.trim(),
                })
              : null,
        ),
      ],
    );
  }
}

/// Builds the `--respiratory` argument list from the dialog result.
List<String> buildRespiratoryArgs({
  required String edfPath,
  required Map<String, dynamic> settings,
  String? scoringPath,
  double? lightsOffSeconds,
  double? lightsOnSeconds,
  String? outPath,
}) {
  final args = <String>['--respiratory', edfPath];
  if (scoringPath != null) args.addAll(['--scoring', scoringPath]);
  final channels = (settings['channels'] as Map?) ?? const {};
  for (final entry in channels.entries) {
    final v = entry.value?.toString() ?? '';
    // An explicit empty value keeps the engine from auto-picking a channel
    // the user switched off.
    args.addAll(['--${entry.key}', v.isEmpty ? 'none' : v]);
  }
  args.addAll(['--hypopnea-rule', '${settings['hypopneaRule'] ?? 3}']);
  final mode = settings['arousalMode']?.toString() ?? 'prefer-manual';
  args.addAll(['--arousals', mode]);
  if (mode == 'auto') args.addAll(['--auto-arousals', 'true']);
  final supine = settings['supineCodes']?.toString() ?? '';
  if (supine.isNotEmpty) args.addAll(['--supine-codes', supine]);
  if (lightsOffSeconds != null) {
    args.addAll(['--lights-off-sec', lightsOffSeconds.toString()]);
  }
  if (lightsOnSeconds != null) {
    args.addAll(['--lights-on-sec', lightsOnSeconds.toString()]);
  }
  if (outPath != null) args.addAll(['--out', outPath]);
  return args;
}

// ─── PLM dialog ─────────────────────────────────────────────────────────────

class PlmAnalysisDialog extends StatefulWidget {
  const PlmAnalysisDialog({
    super.key,
    required this.signals,
    required this.hasHypnogram,
    required this.hasRespiratoryReport,
  });

  final List<PsgSignal> signals;
  final bool hasHypnogram;
  final bool hasRespiratoryReport;

  @override
  State<PlmAnalysisDialog> createState() => _PlmAnalysisDialogState();
}

class _PlmAnalysisDialogState extends State<PlmAnalysisDialog> {
  String? _left;
  String? _right;
  String _standard = 'aasm';
  late bool _useRespiratory = widget.hasRespiratoryReport;
  final _onsetController = TextEditingController(text: '8');
  final _offsetController = TextEditingController(text: '2');

  @override
  void initState() {
    super.initState();
    final legs = widget.signals.where((s) => s.role == 'leg').toList();
    bool isLeft(String l) {
      final x = l.toLowerCase();
      return x.contains('left') ||
          x.endsWith('l') ||
          x.contains('lat l') ||
          x.contains('_l') ||
          x.contains(' l ') ||
          x.contains('-l');
    }

    for (final s in legs) {
      if (_left == null && isLeft(s.label)) {
        _left = s.label;
      } else if (_right == null && s.label != _left) {
        _right = s.label;
      }
    }
    if (_left == null && legs.length > 1) _left = legs.first.label;
    if (_right == _left) _right = legs.length > 1 ? legs[1].label : null;
  }

  @override
  void dispose() {
    _onsetController.dispose();
    _offsetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ok = _left != null || _right != null;
    return AlertDialog(
      title: const Text('Periodic Limb Movement (PLMS) Analysis'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!widget.hasHypnogram)
                const Text(
                  'No hypnogram: PLMS and PLMW cannot be separated. Score or '
                  'autoscore the recording first.',
                  style: TextStyle(fontSize: 12, color: Colors.deepOrange),
                ),
              _sectionTitle('Tibialis anterior EMG'),
              _ChannelDropdown(
                label: 'Left leg',
                signals: widget.signals,
                value: _left,
                onChanged: (v) => setState(() => _left = v),
              ),
              _ChannelDropdown(
                label: 'Right leg',
                signals: widget.signals,
                value: _right,
                onChanged: (v) => setState(() => _right = v),
              ),
              _sectionTitle('Scoring standard'),
              RadioListTile<String>(
                dense: true,
                value: 'aasm',
                groupValue: _standard,
                title: const Text('AASM Scoring Manual v3 (default)'),
                subtitle: const Text(
                  'PLM series: ≥4 LMs, 5–90 s apart; bilateral onsets <5 s = one LM; '
                  'LMs within 0.5 s of respiratory events excluded.',
                ),
                onChanged: (v) => setState(() => _standard = v ?? 'aasm'),
              ),
              RadioListTile<String>(
                dense: true,
                value: 'wasm',
                groupValue: _standard,
                title: const Text('WASM / IRLSSG 2016 (research)'),
                subtitle: const Text(
                  'Candidate LMs, IMI 10–90 s, respiratory window −2/+10.25 s.',
                ),
                onChanged: (v) => setState(() => _standard = v ?? 'wasm'),
              ),
              CheckboxListTile(
                dense: true,
                value: _useRespiratory,
                onChanged: widget.hasRespiratoryReport
                    ? (v) => setState(() => _useRespiratory = v ?? false)
                    : null,
                title: const Text('Exclude respiratory-related leg movements'),
                subtitle: Text(
                  widget.hasRespiratoryReport
                      ? 'Uses the saved respiratory analysis of this recording.'
                      : 'Run Respiratory / OSA analysis first to enable.',
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _onsetController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Onset (µV above resting EMG)',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _offsetController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Offset (µV above resting EMG)',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.directions_walk),
          label: const Text('Analyse'),
          onPressed: ok
              ? () => Navigator.of(context).pop(<String, dynamic>{
                  'left': _left,
                  'right': _right,
                  'standard': _standard,
                  'useRespiratory': _useRespiratory,
                  'onset': double.tryParse(_onsetController.text.trim()) ?? 8.0,
                  'offset': double.tryParse(_offsetController.text.trim()) ?? 2.0,
                })
              : null,
        ),
      ],
    );
  }
}

List<String> buildPlmArgs({
  required String edfPath,
  required Map<String, dynamic> settings,
  String? scoringPath,
  String? respiratoryJson,
  double? lightsOffSeconds,
  double? lightsOnSeconds,
  String? outPath,
}) {
  final args = <String>['--plm', edfPath];
  if (scoringPath != null) args.addAll(['--scoring', scoringPath]);
  final left = settings['left']?.toString() ?? '';
  final right = settings['right']?.toString() ?? '';
  args.addAll(['--left', left.isEmpty ? 'none' : left]);
  args.addAll(['--right', right.isEmpty ? 'none' : right]);
  args.addAll(['--standard', settings['standard']?.toString() ?? 'aasm']);
  args.addAll(['--onset-uv', '${settings['onset'] ?? 8.0}']);
  args.addAll(['--offset-uv', '${settings['offset'] ?? 2.0}']);
  if (settings['useRespiratory'] == true && respiratoryJson != null) {
    args.addAll(['--respiratory-json', respiratoryJson]);
  } else {
    args.addAll(['--respiratory-json', 'none']);
  }
  if (lightsOffSeconds != null) {
    args.addAll(['--lights-off-sec', lightsOffSeconds.toString()]);
  }
  if (lightsOnSeconds != null) {
    args.addAll(['--lights-on-sec', lightsOnSeconds.toString()]);
  }
  if (outPath != null) args.addAll(['--out', outPath]);
  return args;
}

// ─── Running with a progress dialog ─────────────────────────────────────────

/// Runs analyse-nidra with a modal progress dialog. Returns the exit code and
/// the collected log lines.
Future<(int, List<String>)> runAnalyseNidraWithProgress({
  required BuildContext context,
  required String title,
  required String executable,
  required List<String> arguments,
}) async {
  final logs = <String>[];
  var progress = 0.0;
  var label = 'Starting…';
  StateSetter? refresh;
  var open = true;
  final navigator = Navigator.of(context);
  final done = Completer<void>();

  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          refresh = setState;
          return AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 520,
              height: 220,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  LinearProgressIndicator(value: progress > 0 ? progress : null),
                  const SizedBox(height: 10),
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      color: Colors.black87,
                      padding: const EdgeInsets.all(6),
                      child: SingleChildScrollView(
                        reverse: true,
                        child: Text(
                          logs.length > 200
                              ? logs.sublist(logs.length - 200).join('\n')
                              : logs.join('\n'),
                          style: const TextStyle(
                            color: Colors.lightGreenAccent,
                            fontFamily: 'Courier',
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).whenComplete(() {
      open = false;
      refresh = null;
      if (!done.isCompleted) done.complete();
    }),
  );

  final exitCode = await EegBackend().runCommandStreamAsync(
    executable: executable,
    arguments: arguments,
    onLine: (line) {
      logs.add(line);
      final m = RegExp(r'PROGRESS\s+([01](?:\.\d+)?)\s+(.+)').firstMatch(line);
      if (m != null) {
        progress = double.tryParse(m.group(1)!) ?? progress;
        label = m.group(2)!.trim();
      }
      if (open) refresh?.call(() {});
    },
  );
  if (open) navigator.pop();
  await done.future;
  return (exitCode, logs);
}

String? outputPathFromLogs(List<String> logs, String tag) {
  for (final line in logs.reversed) {
    final idx = line.indexOf('$tag ');
    if (idx >= 0) return line.substring(idx + tag.length + 1).trim();
  }
  return null;
}

Future<void> showPsgSummaryDialog(
  BuildContext context, {
  required String title,
  required List<(String, List<(String, String)>)> sections,
  List<String> warnings = const [],
  String? reportPath,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final section in sections) ...[
                _sectionTitle(section.$1),
                Table(
                  columnWidths: const {0: FlexColumnWidth(3), 1: FlexColumnWidth(2)},
                  children: [
                    for (final row in section.$2)
                      TableRow(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(row.$1, style: const TextStyle(fontSize: 12)),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              row.$2,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ],
              if (warnings.isNotEmpty) ...[
                _sectionTitle('Notes'),
                for (final w in warnings)
                  Text('• $w', style: const TextStyle(fontSize: 11, color: Colors.black54)),
              ],
              if (reportPath != null) ...[
                const SizedBox(height: 10),
                SelectableText(
                  'Full results: $reportPath\nThe metrics are added to the PDF sleep report automatically.',
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
