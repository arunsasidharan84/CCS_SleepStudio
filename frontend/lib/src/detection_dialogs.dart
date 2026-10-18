// lib/src/detection_dialogs.dart

import 'dart:convert';
import 'package:flutter/material.dart';

import 'analyse_options.dart';
import 'autoscore_command.dart';
import 'models.dart';
import 'rem_detection.dart';

class MtKcdDialog extends StatefulWidget {
  const MtKcdDialog({
    super.key,
    required this.channelLabels,
    required this.hasStages,
    required this.onRun,
  });

  final List<String> channelLabels;
  final bool hasStages;
  final void Function(Map<String, dynamic> settings) onRun;

  @override
  State<MtKcdDialog> createState() => _MtKcdDialogState();
}

class _MtKcdDialogState extends State<MtKcdDialog> {
  late String _selectedChannel;
  String _selectedMarker = 'F1';

  // Detection parameters
  double _amin = 125.0;
  double _dmax = 2.0;
  int _q = 90;
  double _fmax = 3.0;

  // Stage filtering
  bool _useStageFilter = false;
  final Map<String, bool> _stages = {
    'Wake': false,
    'N1': false,
    'N2': true,
    'N3': true,
    'REM': false,
    'Inconclusive': false,
  };

  @override
  void initState() {
    super.initState();
    _selectedChannel = widget.channelLabels.isNotEmpty
        ? widget.channelLabels.first
        : '';
    _useStageFilter = widget.hasStages;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.analytics, color: Colors.blue),
          const SizedBox(width: 8),
          const Text('K-Complex Detection (MT-KCD)'),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // EEG channel selector
              const Text(
                'EEG Channel',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                value: _selectedChannel,
                isExpanded: true,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                items: widget.channelLabels.map((ch) {
                  return DropdownMenuItem(
                    value: ch,
                    child: Text(ch, style: const TextStyle(fontSize: 13)),
                  );
                }).toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _selectedChannel = v);
                },
              ),
              const SizedBox(height: 14),

              // Target event marker dropdown
              const Text(
                'Save detections to event marker',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                value: _selectedMarker,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                items: [
                  const DropdownMenuItem(
                    value: 'Artifact',
                    child: Text('Artifact (A)', style: TextStyle(fontSize: 13)),
                  ),
                  for (var i = 1; i <= 12; i++)
                    DropdownMenuItem(
                      value: 'F$i',
                      child: Text(
                        'Event $i (F$i)',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _selectedMarker = v);
                },
              ),
              const SizedBox(height: 14),

              // Threshold group
              Card(
                margin: EdgeInsets.zero,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  side: BorderSide(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Detection Thresholds',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _doubleInputRow(
                        label: 'Min. amplitude (Amin):',
                        value: _amin,
                        suffix: ' µV',
                        tooltip:
                            'Minimum peak-to-peak amplitude (AASM standard requires ≥ 75 µV).',
                        onChanged: (v) => setState(() => _amin = v),
                      ),
                      const SizedBox(height: 10),
                      _doubleInputRow(
                        label: 'Max. duration (Dmax):',
                        value: _dmax,
                        suffix: ' s',
                        tooltip:
                            'Maximum allowed duration of a K-complex (default 2 s).',
                        onChanged: (v) => setState(() => _dmax = v),
                      ),
                      const SizedBox(height: 10),
                      _intInputRow(
                        label: 'Region percentile (q):',
                        value: _q,
                        suffix: ' %',
                        tooltip:
                            'Percentile threshold for candidate-region identification (default 90%).',
                        onChanged: (v) => setState(() => _q = v),
                      ),
                      const SizedBox(height: 10),
                      _doubleInputRow(
                        label: 'Max. KC frequency (fmax):',
                        value: _fmax,
                        suffix: ' Hz',
                        tooltip:
                            'Upper frequency limit for K-Complex spectral delta power (default 3.0 Hz).',
                        onChanged: (v) => setState(() => _fmax = v),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // Stage filter
              CheckboxListTile(
                title: const Text(
                  'Keep detections in sleep stages only',
                  style: TextStyle(fontSize: 13),
                ),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _useStageFilter,
                onChanged: widget.hasStages
                    ? (v) => setState(() => _useStageFilter = v ?? false)
                    : null,
                subtitle: widget.hasStages
                    ? null
                    : const Text(
                        'No stages scored yet.',
                        style: TextStyle(color: Colors.grey, fontSize: 11),
                      ),
              ),
              if (_useStageFilter)
                Container(
                  padding: const EdgeInsets.only(left: 16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: _stages.keys.map((stage) {
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Checkbox(
                            value: _stages[stage],
                            onChanged: (v) {
                              setState(() => _stages[stage] = v ?? false);
                            },
                          ),
                          Text(stage, style: const TextStyle(fontSize: 12)),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              const SizedBox(height: 12),

              // Explanation
              Text(
                'MT-KCD detects KCs via multitaper spectral analysis. '
                'Based on: Oliveira et al. (2020), Expert Syst. Appl. 151, 113331.',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
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
        ElevatedButton(
          onPressed: () {
            if (_selectedChannel.isEmpty) return;

            // Collect selected stages
            List<String>? filteredStages;
            if (_useStageFilter) {
              filteredStages = _stages.entries
                  .where((e) => e.value)
                  .map((e) => e.key)
                  .toList();
              if (filteredStages.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Select at least one stage for filtering.'),
                  ),
                );
                return;
              }
            }

            widget.onRun({
              'channel': _selectedChannel,
              'marker': _selectedMarker,
              'amin': _amin,
              'dmax_s': _dmax,
              'q': _q.toDouble(),
              'fmax': _fmax,
              'filter_stages': filteredStages,
            });
            Navigator.of(context).pop();
          },
          child: const Text('OK'),
        ),
      ],
    );
  }

  Widget _doubleInputRow({
    required String label,
    required double value,
    required String suffix,
    required String tooltip,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Row(
            children: [
              Text(label, style: const TextStyle(fontSize: 12)),
              const SizedBox(width: 4),
              Tooltip(
                message: tooltip,
                child: const Icon(
                  Icons.info_outline,
                  size: 14,
                  color: Colors.blue,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 90,
          height: 32,
          child: TextFormField(
            initialValue: value.toString(),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(fontSize: 12),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.all(8),
              border: const OutlineInputBorder(),
              suffixText: suffix,
            ),
            onChanged: (text) {
              final d = double.tryParse(text);
              if (d != null) onChanged(d);
            },
          ),
        ),
      ],
    );
  }

  Widget _intInputRow({
    required String label,
    required int value,
    required String suffix,
    required String tooltip,
    required ValueChanged<int> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Row(
            children: [
              Text(label, style: const TextStyle(fontSize: 12)),
              const SizedBox(width: 4),
              Tooltip(
                message: tooltip,
                child: const Icon(
                  Icons.info_outline,
                  size: 14,
                  color: Colors.blue,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 90,
          height: 32,
          child: TextFormField(
            initialValue: value.toString(),
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 12),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.all(8),
              border: const OutlineInputBorder(),
              suffixText: suffix,
            ),
            onChanged: (text) {
              final val = int.tryParse(text);
              if (val != null) onChanged(val);
            },
          ),
        ),
      ],
    );
  }
}

class MtSpindleDialog extends StatefulWidget {
  const MtSpindleDialog({
    super.key,
    required this.channelLabels,
    required this.hasStages,
    required this.onRun,
  });

  final List<String> channelLabels;
  final bool hasStages;
  final void Function(Map<String, dynamic> settings) onRun;

  @override
  State<MtSpindleDialog> createState() => _MtSpindleDialogState();
}

class _MtSpindleDialogState extends State<MtSpindleDialog> {
  late String _selectedChannel;
  String _selectedMarker = 'F3';

  // Detection parameters
  double _fmin = 11.0;
  double _fmax = 16.0;
  double _amin = 6.0;
  double _dmin = 0.5;
  double _dmax = 2.0;
  int _q = 90;

  // Stage filtering
  bool _useStageFilter = false;
  final Map<String, bool> _stages = {
    'Wake': false,
    'N1': false,
    'N2': true,
    'N3': true,
    'REM': false,
    'Inconclusive': false,
  };

  @override
  void initState() {
    super.initState();
    _selectedChannel = widget.channelLabels.isNotEmpty
        ? widget.channelLabels.first
        : '';
    _useStageFilter = widget.hasStages;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.waves, color: Colors.blue),
          const SizedBox(width: 8),
          const Text('Spindle Detection (MT-Spindle)'),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // EEG channel selector
              const Text(
                'EEG Channel',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                value: _selectedChannel,
                isExpanded: true,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                items: widget.channelLabels.map((ch) {
                  return DropdownMenuItem(
                    value: ch,
                    child: Text(ch, style: const TextStyle(fontSize: 13)),
                  );
                }).toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _selectedChannel = v);
                },
              ),
              const SizedBox(height: 14),

              // Target event marker dropdown
              const Text(
                'Save detections to event marker',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                value: _selectedMarker,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                items: [
                  const DropdownMenuItem(
                    value: 'Artifact',
                    child: Text('Artifact (A)', style: TextStyle(fontSize: 13)),
                  ),
                  for (var i = 1; i <= 12; i++)
                    DropdownMenuItem(
                      value: 'F$i',
                      child: Text(
                        'Event $i (F$i)',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _selectedMarker = v);
                },
              ),
              const SizedBox(height: 14),

              // Threshold group
              Card(
                margin: EdgeInsets.zero,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  side: BorderSide(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Detection Thresholds',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _doubleInputRow(
                        label: 'Min. frequency (fmin):',
                        value: _fmin,
                        suffix: ' Hz',
                        tooltip:
                            'Lower bound of the spindle sigma frequency band (default 11.0 Hz).',
                        onChanged: (v) => setState(() => _fmin = v),
                      ),
                      const SizedBox(height: 10),
                      _doubleInputRow(
                        label: 'Max. frequency (fmax):',
                        value: _fmax,
                        suffix: ' Hz',
                        tooltip:
                            'Upper bound of the spindle sigma frequency band (default 16.0 Hz).',
                        onChanged: (v) => setState(() => _fmax = v),
                      ),
                      const SizedBox(height: 10),
                      _doubleInputRow(
                        label: 'Min. amplitude (Amin):',
                        value: _amin,
                        suffix: ' µV',
                        tooltip:
                            'Minimum peak amplitude of the filtered sigma-band signal (default 6 µV).',
                        onChanged: (v) => setState(() => _amin = v),
                      ),
                      const SizedBox(height: 10),
                      _doubleInputRow(
                        label: 'Min. duration (Dmin):',
                        value: _dmin,
                        suffix: ' s',
                        tooltip:
                            'Minimum allowed duration of a spindle (default 0.5 s).',
                        onChanged: (v) => setState(() => _dmin = v),
                      ),
                      const SizedBox(height: 10),
                      _doubleInputRow(
                        label: 'Max. duration (Dmax):',
                        value: _dmax,
                        suffix: ' s',
                        tooltip:
                            'Maximum allowed duration of a spindle (default 2.0 s).',
                        onChanged: (v) => setState(() => _dmax = v),
                      ),
                      const SizedBox(height: 10),
                      _intInputRow(
                        label: 'Region percentile (q):',
                        value: _q,
                        suffix: ' %',
                        tooltip:
                            'Percentile threshold for candidate-region identification (default 90%).',
                        onChanged: (v) => setState(() => _q = v),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // Stage filter
              CheckboxListTile(
                title: const Text(
                  'Keep detections in sleep stages only',
                  style: TextStyle(fontSize: 13),
                ),
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _useStageFilter,
                onChanged: widget.hasStages
                    ? (v) => setState(() => _useStageFilter = v ?? false)
                    : null,
                subtitle: widget.hasStages
                    ? null
                    : const Text(
                        'No stages scored yet.',
                        style: TextStyle(color: Colors.grey, fontSize: 11),
                      ),
              ),
              if (_useStageFilter)
                Container(
                  padding: const EdgeInsets.only(left: 16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: _stages.keys.map((stage) {
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Checkbox(
                            value: _stages[stage],
                            onChanged: (v) {
                              setState(() => _stages[stage] = v ?? false);
                            },
                          ),
                          Text(stage, style: const TextStyle(fontSize: 12)),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              const SizedBox(height: 12),

              // Explanation
              Text(
                'MT-Spindle detects spindles using median-normalized multitaper sigma power '
                'and Hilbert envelope boundary detection.',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
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
        ElevatedButton(
          onPressed: () {
            if (_selectedChannel.isEmpty) return;
            if (_fmin >= _fmax) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('fmin must be less than fmax.')),
              );
              return;
            }
            if (_dmin >= _dmax) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Dmin must be less than Dmax.')),
              );
              return;
            }

            // Collect selected stages
            List<String>? filteredStages;
            if (_useStageFilter) {
              filteredStages = _stages.entries
                  .where((e) => e.value)
                  .map((e) => e.key)
                  .toList();
              if (filteredStages.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Select at least one stage for filtering.'),
                  ),
                );
                return;
              }
            }

            widget.onRun({
              'channel': _selectedChannel,
              'marker': _selectedMarker,
              'fmin': _fmin,
              'fmax': _fmax,
              'amin': _amin,
              'dmin_s': _dmin,
              'dmax_s': _dmax,
              'q': _q.toDouble(),
              'filter_stages': filteredStages,
            });
            Navigator.of(context).pop();
          },
          child: const Text('OK'),
        ),
      ],
    );
  }

  Widget _doubleInputRow({
    required String label,
    required double value,
    required String suffix,
    required String tooltip,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Row(
            children: [
              Text(label, style: const TextStyle(fontSize: 12)),
              const SizedBox(width: 4),
              Tooltip(
                message: tooltip,
                child: const Icon(
                  Icons.info_outline,
                  size: 14,
                  color: Colors.blue,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 90,
          height: 32,
          child: TextFormField(
            initialValue: value.toString(),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(fontSize: 12),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.all(8),
              border: const OutlineInputBorder(),
              suffixText: suffix,
            ),
            onChanged: (text) {
              final d = double.tryParse(text);
              if (d != null) onChanged(d);
            },
          ),
        ),
      ],
    );
  }

  Widget _intInputRow({
    required String label,
    required int value,
    required String suffix,
    required String tooltip,
    required ValueChanged<int> onChanged,
  }) {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Row(
            children: [
              Text(label, style: const TextStyle(fontSize: 12)),
              const SizedBox(width: 4),
              Tooltip(
                message: tooltip,
                child: const Icon(
                  Icons.info_outline,
                  size: 14,
                  color: Colors.blue,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 90,
          height: 32,
          child: TextFormField(
            initialValue: value.toString(),
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 12),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.all(8),
              border: const OutlineInputBorder(),
              suffixText: suffix,
            ),
            onChanged: (text) {
              final val = int.tryParse(text);
              if (val != null) onChanged(val);
            },
          ),
        ),
      ],
    );
  }
}

class AnalyseNidraDetectionDialog extends StatefulWidget {
  const AnalyseNidraDetectionDialog({
    super.key,
    required this.channelLabels,
    required this.hasStages,
    required this.onRun,
  });

  final List<String> channelLabels;
  final bool hasStages;
  final ValueChanged<Map<String, dynamic>> onRun;

  @override
  State<AnalyseNidraDetectionDialog> createState() =>
      _AnalyseNidraDetectionDialogState();
}

class _AnalyseNidraDetectionDialogState
    extends State<AnalyseNidraDetectionDialog> {
  late final Set<String> _selectedChannels;
  String _selectedReference = 'None';
  List<String> _linkedMastoidPair = const [];
  bool _detectSpindles = true;
  bool _detectSlowWaves = true;

  @override
  void initState() {
    super.initState();
    _selectedChannels = <String>{};
    String? m1Label;
    String? m2Label;
    for (final label in widget.channelLabels) {
      final u = label.trim().toUpperCase();
      final root = u.replaceFirst(RegExp(r'^EEG\s+'), '').split(RegExp(r'[:\-_\s]')).first;
      if (root == 'M1' || root == 'A1') {
        m1Label ??= label;
        continue;
      }
      if (root == 'M2' || root == 'A2') {
        m2Label ??= label;
        continue;
      }
      if (u.contains('C3') ||
          u.contains('C4') ||
          u.contains('F3') ||
          u.contains('F4') ||
          u.contains('CZ') ||
          u.contains('FZ') ||
          u.contains('O1') ||
          u.contains('O2')) {
        _selectedChannels.add(label);
      }
    }
    if (_selectedChannels.isEmpty && widget.channelLabels.isNotEmpty) {
      _selectedChannels.addAll(widget.channelLabels.take(4));
    }
    final alreadyBipolar = _selectedChannels.isNotEmpty &&
        _selectedChannels.every((c) =>
            c.contains('-') ||
            c.contains(':') ||
            c.toUpperCase().contains('A1') ||
            c.toUpperCase().contains('A2') ||
            c.toUpperCase().contains('M1') ||
            c.toUpperCase().contains('M2'));
    if (!alreadyBipolar && m1Label != null && m2Label != null) {
      _linkedMastoidPair = [m1Label, m2Label];
      _selectedReference = '$m1Label, $m2Label (Linked Mastoids)';
    } else if (!alreadyBipolar && (m1Label != null || m2Label != null)) {
      _selectedReference = m1Label ?? m2Label!;
    } else {
      _selectedReference = 'None';
    }
  }

  @override
  Widget build(BuildContext context) {
    final linkedLabel = _linkedMastoidPair.length == 2
        ? '${_linkedMastoidPair[0]}, ${_linkedMastoidPair[1]} (Linked Mastoids)'
        : null;
    final refOptions = [
      'None',
      ?linkedLabel,
      ...widget.channelLabels,
    ];
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.analytics_outlined, color: Colors.indigo),
          SizedBox(width: 8),
          Text('AnalyseNidra Spindle & Slow-Wave Detection'),
        ],
      ),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Select Channels for Detection',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  ActionChip(
                    label: const Text('Select All', style: TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      setState(() {
                        _selectedChannels.addAll(widget.channelLabels);
                      });
                    },
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    label: const Text('Clear All', style: TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      setState(() {
                        _selectedChannels.clear();
                      });
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(6),
                ),
                constraints: const BoxConstraints(maxHeight: 150),
                child: ListView(
                  shrinkWrap: true,
                  children: widget.channelLabels.map((ch) {
                    final selected = _selectedChannels.contains(ch);
                    return CheckboxListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      title: Text(ch, style: const TextStyle(fontSize: 12)),
                      value: selected,
                      onChanged: (val) {
                        setState(() {
                          if (val == true) {
                            _selectedChannels.add(ch);
                          } else {
                            _selectedChannels.remove(ch);
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Reference Channel (Optional)',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                value: refOptions.contains(_selectedReference)
                    ? _selectedReference
                    : 'None',
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
                items: refOptions.map((ch) {
                  return DropdownMenuItem(
                    value: ch,
                    child: Text(ch, style: const TextStyle(fontSize: 13)),
                  );
                }).toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _selectedReference = v);
                },
              ),
              const SizedBox(height: 14),
              const Text(
                'Event Types to Detect',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 4),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Detect Spindles (AnalyseNidra)', style: TextStyle(fontSize: 13)),
                subtitle: const Text(
                  'MNE relative sigma power & duration filters (marked as Indigo [8])',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
                value: _detectSpindles,
                onChanged: (v) => setState(() => _detectSpindles = v ?? false),
              ),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Detect Slow Waves (AnalyseNidra)', style: TextStyle(fontSize: 13)),
                subtitle: const Text(
                  'Zero-crossing negative/positive peak detection & PTP (marked as Pink [7])',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
                value: _detectSlowWaves,
                onChanged: (v) => setState(() => _detectSlowWaves = v ?? false),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.indigo.shade50,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline, size: 16, color: Colors.indigo),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.hasStages
                            ? 'Detections will be computed on NREM sleep epochs and saved to both JSON sidecars and your active markers.'
                            : 'Notice: AnalyseNidra runs optimal spindle and slow-wave detection on scored N2/N3 epochs.',
                        style: TextStyle(fontSize: 11, color: Colors.indigo.shade900),
                      ),
                    ),
                  ],
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
        ElevatedButton(
          onPressed: () {
            if (_selectedChannels.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Please select at least one EEG channel.')),
              );
              return;
            }
            if (!_detectSpindles && !_detectSlowWaves) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Please select at least one event type to detect.')),
              );
              return;
            }
            final List<String> refs;
            if (_selectedReference == 'None') {
              refs = <String>[];
            } else if (_linkedMastoidPair.length == 2 &&
                _selectedReference.endsWith('(Linked Mastoids)')) {
              refs = List<String>.from(_linkedMastoidPair);
            } else {
              refs = [_selectedReference];
            }
            widget.onRun({
              'channels': _selectedChannels.toList(),
              'references': refs,
              'detectSpindles': _detectSpindles,
              'detectSlowWaves': _detectSlowWaves,
            });
            Navigator.of(context).pop();
          },
          child: const Text('Run Detection'),
        ),
      ],
    );
  }
}

({bool eeg, bool ref, bool eog, bool emg}) _classifyScoringChannel(
  String label,
) {
  final upper = label.trim().toUpperCase();
  var root = upper.replaceFirst(RegExp(r'^EEG\s+'), '');
  root = root.split(':').first;
  root = root.split(RegExp(r'[-_\s]')).first;
  final isEog =
      upper.contains('EOG') ||
      upper.contains('LOC') ||
      upper.contains('ROC') ||
      root == 'E1' ||
      root == 'E2';
  final isEmg =
      upper.contains('EMG') || upper.contains('CHIN') || upper.contains('MYO');
  final isRef =
      upper == 'M1' ||
      upper == 'M2' ||
      upper == 'A1' ||
      upper == 'A2' ||
      upper == 'REF' ||
      upper.startsWith('REF ');
  final isEegRoot = RegExp(
    r'^(?:(?:FP|AF|F|FT|FC|T|C|TP|CP|P|PO|O)(?:Z|\d{1,2})|EEG\d*)$',
  ).hasMatch(root);
  return (
    eeg: isEegRoot && !isEog && !isEmg && !isRef,
    ref: isRef,
    eog: isEog,
    emg: isEmg,
  );
}

class AutoScoringDialog extends StatefulWidget {
  const AutoScoringDialog({
    super.key,
    required this.channelLabels,
    required this.onRun,
  });

  final List<String> channelLabels;
  final void Function(Map<String, dynamic> settings) onRun;

  @override
  State<AutoScoringDialog> createState() => _AutoScoringDialogState();
}

class _AutoScoringDialogState extends State<AutoScoringDialog> {
  String _algorithm = kDefaultAutoscoreAlgorithm;
  String _correction = kDefaultSequenceCorrection;
  double _sleepgptAlpha = 0.1;
  int _sleepgptNgram = 30;

  final Map<String, bool> _eegChannels = {};
  final Map<String, bool> _refChannels = {};
  final Map<String, bool> _eogChannels = {};
  final Map<String, bool> _emgChannels = {};

  @override
  void initState() {
    super.initState();
    for (final ch in widget.channelLabels) {
      final group = _classifyScoringChannel(ch);
      _eegChannels[ch] = group.eeg;
      _refChannels[ch] = group.ref;
      _eogChannels[ch] = group.eog;
      _emgChannels[ch] = group.emg;
    }
    if (widget.channelLabels.length == 1 &&
        !_eegChannels.values.any((selected) => selected) &&
        !_refChannels.values.any((selected) => selected) &&
        !_eogChannels.values.any((selected) => selected) &&
        !_emgChannels.values.any((selected) => selected)) {
      _eegChannels[widget.channelLabels.single] = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.psychology, color: Colors.purple),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('AutoscoreNidra — Automated Sleep Scoring'),
          ),
        ],
      ),
      content: SizedBox(
        width: 600,
        height: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Alg & Correction
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Base Scorer Algorithm',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 6),
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          value: _algorithm,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                          ),
                          items: [
                            for (final option in autoscoreAlgorithmOptions)
                              DropdownMenuItem(
                                value: option.$1,
                                child: Text(option.$2, style: const TextStyle(fontSize: 13)),
                              ),
                          ],
                          onChanged: (v) {
                            if (v != null) setState(() => _algorithm = v);
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Sequence Correction',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 6),
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          value: _correction,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'none',
                              child: Text(
                                'None (Raw consensus predictions)',
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
                            DropdownMenuItem(
                              value: 'sleepgpt',
                              child: Text(
                                'SleepGPT Language Model',
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
                          ],
                          onChanged: (v) {
                            if (v != null) setState(() => _correction = v);
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              if (_correction == 'sleepgpt') ...[
                // SleepGPT specific settings
                Card(
                  margin: EdgeInsets.zero,
                  elevation: 0,
                  color: Colors.purple.shade50,
                  shape: RoundedRectangleBorder(
                    side: BorderSide(color: Colors.purple.shade100),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'SleepGPT Sequence Parameters',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Colors.purple,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            const Expanded(
                              flex: 3,
                              child: Row(
                                children: [
                                  Text(
                                    'Language model weight (alpha):',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                  SizedBox(width: 4),
                                  Tooltip(
                                    message:
                                        'Interpolation weight for SleepGPT predictions (0.1 = 10% model influence, 90% base stager).',
                                    child: Icon(
                                      Icons.info_outline,
                                      size: 14,
                                      color: Colors.purple,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(
                              width: 90,
                              height: 32,
                              child: TextFormField(
                                initialValue: _sleepgptAlpha.toString(),
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                style: const TextStyle(fontSize: 12),
                                decoration: const InputDecoration(
                                  isDense: true,
                                  contentPadding: EdgeInsets.all(8),
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: (text) {
                                  final d = double.tryParse(text);
                                  if (d != null && d >= 0.0 && d <= 1.0) {
                                    setState(() => _sleepgptAlpha = d);
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            const Expanded(
                              flex: 3,
                              child: Row(
                                children: [
                                  Text(
                                    'Context sequence length (n-gram):',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                  SizedBox(width: 4),
                                  Tooltip(
                                    message:
                                        'Number of past epochs SleepGPT looks at to predict the next stage transition (default 30).',
                                    child: Icon(
                                      Icons.info_outline,
                                      size: 14,
                                      color: Colors.purple,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(
                              width: 90,
                              height: 32,
                              child: TextFormField(
                                initialValue: _sleepgptNgram.toString(),
                                keyboardType: TextInputType.number,
                                style: const TextStyle(fontSize: 12),
                                decoration: const InputDecoration(
                                  isDense: true,
                                  contentPadding: EdgeInsets.all(8),
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: (text) {
                                  final val = int.tryParse(text);
                                  if (val != null && val > 0) {
                                    setState(() => _sleepgptNgram = val);
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Channels selection grid
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _buildChannelSelector(
                      'EEG Signal Channels',
                      _eegChannels,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildChannelSelector(
                      'Reference Signals',
                      _refChannels,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _buildChannelSelector(
                      'EOG Channels (Differential)',
                      _eogChannels,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildChannelSelector(
                      'EMG Channels (Differential)',
                      _emgChannels,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              Text(
                'Note: Multi-channel configuration runs the stager across all selected EEG pairs/montages '
                'and takes the ensemble average (consensus).',
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
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
        ElevatedButton(
          onPressed: () {
            final eeg = _eegChannels.entries
                .where((e) => e.value)
                .map((e) => e.key)
                .toList();
            final ref = _refChannels.entries
                .where((e) => e.value)
                .map((e) => e.key)
                .toList();
            final eog = _eogChannels.entries
                .where((e) => e.value)
                .map((e) => e.key)
                .toList();
            final emg = _emgChannels.entries
                .where((e) => e.value)
                .map((e) => e.key)
                .toList();

            if (eeg.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Select at least one EEG channel.'),
                ),
              );
              return;
            }

            final settings = <String, dynamic>{
              'algorithm': _algorithm,
              'sequence_correction': _correction,
              'eeg': eeg,
              'ref': ref,
              'eog': eog,
              'emg': emg,
              'sleepgpt_alpha': _sleepgptAlpha,
              'sleepgpt_ngram': _sleepgptNgram,
            };
            Navigator.of(context).pop();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              widget.onRun(settings);
            });
          },
          child: const Text('Run Scoring'),
        ),
      ],
    );
  }

  Widget _buildChannelSelector(String label, Map<String, bool> channels) {
    final list = channels.keys.toList();
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            GestureDetector(
              onTap: () {
                setState(() {
                  for (final key in channels.keys) {
                    channels[key] = false;
                  }
                });
              },
              child: const MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Text(
                  'Clear',
                  style: TextStyle(
                    color: Colors.blue,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          height: 110,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Scrollbar(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: list.length,
              itemBuilder: (context, index) {
                final ch = list[index];
                return SizedBox(
                  height: 32,
                  child: CheckboxListTile(
                    title: Text(ch, style: const TextStyle(fontSize: 11)),
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    value: channels[ch],
                    contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                    onChanged: (v) {
                      setState(() {
                        channels[ch] = v ?? false;
                      });
                    },
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class BatchAutoScoringDialog extends StatefulWidget {
  const BatchAutoScoringDialog({
    super.key,
    required this.files,
    required this.channelLabels,
    required this.onRun,
  });

  final List<String> files;
  final List<String> channelLabels;
  final void Function(Map<String, dynamic> settings) onRun;

  @override
  State<BatchAutoScoringDialog> createState() => _BatchAutoScoringDialogState();
}

typedef AnalyseNidraRunCallback = void Function(
  List<String> channels,
  List<String> references, {
  bool perChannel,
  String? regionMapJson,
  AnalyseNidraOptions? options,
});

class AnalyseNidraDialog extends StatefulWidget {
  const AnalyseNidraDialog({
    super.key,
    required this.channelLabels,
    required this.batchCount,
    required this.onRun,
    this.initialOptions,
  });

  final List<String> channelLabels;
  final int batchCount;
  final AnalyseNidraRunCallback onRun;
  final AnalyseNidraOptions? initialOptions;

  @override
  State<AnalyseNidraDialog> createState() => _AnalyseNidraDialogState();
}

class _AnalyseNidraDialogState extends State<AnalyseNidraDialog> {
  late final Map<String, bool> _channels;
  late final Map<String, bool> _references;
  bool _perChannel = false;
  Map<String, String> _customRegionMap = {};
  late AnalyseNidraOptions _options;

  @override
  void initState() {
    super.initState();
    _options = widget.initialOptions?.copyWith() ?? AnalyseNidraOptions();
    _channels = {};
    _references = {};
    for (final channel in widget.channelLabels) {
      final clean = cleanChannelLabel(channel).toUpperCase();
      final isReference = clean == 'A1' ||
          clean == 'A2' ||
          clean == 'M1' ||
          clean == 'M2' ||
          clean == 'TP9' ||
          clean == 'TP10';
      final isDefaultEeg =
          RegExp(r'^(F3|F4|C3|C4|O1|O2|FZ|CZ|OZ)$').hasMatch(clean);
      _channels[channel] = isDefaultEeg;
      _references[channel] = isReference;
    }
  }

  Future<void> _openEditRegionMappingDialog() async {
    final activeChannels = _channels.entries
        .where((e) => e.value)
        .map((e) => e.key)
        .toList();
    final channelsToMap = activeChannels.isNotEmpty ? activeChannels : widget.channelLabels;
    final updated = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => EditRegionMappingDialog(
        channels: channelsToMap,
        initialMapping: _customRegionMap,
      ),
    );
    if (updated != null) {
      setState(() {
        _customRegionMap = updated;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.batchCount == 1
            ? 'Analyse current recording'
            : 'Batch analyse ${widget.batchCount} recordings',
      ),
      content: SizedBox(
        width: 680,
        height: 640,
        child: Column(
          children: [
            AnalyseNidraOptionsPanel(
              options: _options,
              onChanged: (o) => setState(() => _options = o),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Row(
                children: [
                  Expanded(child: _selector('EEG channels', _channels, isEeg: true)),
                  const SizedBox(width: 12),
                  Expanded(child: _selector('Reference channels', _references, isEeg: false)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Row(
                children: [
                  Checkbox(
                    value: _perChannel,
                    onChanged: (val) => setState(() => _perChannel = val ?? false),
                  ),
                  const Expanded(
                    child: Text(
                      'Per-channel output (no regional grouping)',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.edit, size: 15),
                    label: Text(
                      _customRegionMap.isEmpty
                          ? 'Edit Regional Mapping…'
                          : 'Edit Regions (${_customRegionMap.length} mapped)',
                      style: const TextStyle(fontSize: 12),
                    ),
                    onPressed: _perChannel ? null : _openEditRegionMappingDialog,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final channels = _channels.entries
                .where((entry) => entry.value)
                .map((entry) => entry.key)
                .toList();
            final references = _references.entries
                .where((entry) => entry.value)
                .map((entry) => entry.key)
                .toList();
            if (channels.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Select at least one EEG channel.'),
                ),
              );
              return;
            }
            if (_options.analyses.isEmpty ||
                (_options.analyses.length == 1 && _options.analyses.contains('nlg') && _options.nlgBands.isEmpty)) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Select at least one analysis to run.')),
              );
              return;
            }
            Navigator.of(context).pop();
            final regionMapJson = (!_perChannel && _customRegionMap.isNotEmpty)
                ? jsonEncode(_customRegionMap)
                : null;
            widget.onRun(
              channels,
              references,
              perChannel: _perChannel,
              regionMapJson: regionMapJson,
              options: _options,
            );
          },
          child: const Text('Run analysis'),
        ),
      ],
    );
  }

  Widget _selector(String title, Map<String, bool> values, {required bool isEeg}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold))),
            if (isEeg) ...[
              InkWell(
                onTap: () {
                  setState(() {
                    for (final ch in values.keys) {
                      final clean = cleanChannelLabel(ch).toUpperCase();
                      values[ch] = RegExp(r'^(F3|F4|C3|C4|O1|O2|FZ|CZ|OZ)$').hasMatch(clean);
                    }
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text('Select EEG', style: TextStyle(fontSize: 11, color: Colors.indigo.shade700, fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                onTap: () => setState(() => values.updateAll((key, val) => true)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text('All', style: TextStyle(fontSize: 11, color: Colors.blue.shade700)),
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                onTap: () => setState(() => values.updateAll((key, val) => false)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text('Clear', style: TextStyle(fontSize: 11, color: Colors.red.shade700)),
                ),
              ),
            ] else ...[
              InkWell(
                onTap: () {
                  setState(() {
                    for (final ch in values.keys) {
                      final clean = cleanChannelLabel(ch).toUpperCase();
                      values[ch] = clean == 'M1' || clean == 'M2' || clean == 'A1' || clean == 'A2';
                    }
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text('Mastoids (M1/M2)', style: TextStyle(fontSize: 11, color: Colors.indigo.shade700, fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                onTap: () => setState(() => values.updateAll((key, val) => false)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text('Clear', style: TextStyle(fontSize: 11, color: Colors.red.shade700)),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(4),
            ),
            child: ListView(
              children: [
                for (final channel in values.keys)
                  CheckboxListTile(
                    dense: true,
                    title: Text(channel, style: const TextStyle(fontSize: 12)),
                    value: values[channel],
                    onChanged: (value) {
                      setState(() => values[channel] = value ?? false);
                    },
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class EditRegionMappingDialog extends StatefulWidget {
  const EditRegionMappingDialog({
    super.key,
    required this.channels,
    required this.initialMapping,
  });

  final List<String> channels;
  final Map<String, String> initialMapping;

  @override
  State<EditRegionMappingDialog> createState() => _EditRegionMappingDialogState();
}

class _EditRegionMappingDialogState extends State<EditRegionMappingDialog> {
  late final Map<String, TextEditingController> _controllers;

  @override
  void initState() {
    super.initState();
    _controllers = {};
    for (final channel in widget.channels) {
      final initial = widget.initialMapping[channel] ??
          widget.initialMapping[channel.toUpperCase()] ??
          defaultRegionForChannel(channel);
      _controllers[channel] = TextEditingController(text: initial);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  static String defaultRegionForChannel(String channel) {
    final chan = channel.toUpperCase().trim();
    if (chan == 'PPG' || chan == 'ECG' || chan == 'EMG' || chan == 'EOG' || chan == 'REF' || chan == 'GND') {
      return 'NaN';
    }
    if (chan.startsWith('FC') || chan.startsWith('CP') || chan.startsWith('C')) {
      return 'Central';
    } else if (chan.startsWith('FT') || chan.startsWith('TP') || chan.startsWith('T') || chan.startsWith('M') || chan.startsWith('A')) {
      return 'Temporal';
    } else if (chan.startsWith('FP') || chan.startsWith('AF') || chan.startsWith('F')) {
      return 'Frontal';
    } else if (chan.startsWith('PO') || chan.startsWith('O')) {
      return 'Occipital';
    } else if (chan.startsWith('P')) {
      return 'Parietal';
    }
    return 'Central';
  }

  @override
  Widget build(BuildContext context) {
    const commonRegions = ['Frontal', 'Central', 'Temporal', 'Parietal', 'Occipital', 'NaN'];
    return AlertDialog(
      title: const Text('Edit Channel Regional Mapping'),
      content: SizedBox(
        width: 480,
        height: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Assign each channel to an anatomical region (e.g. Frontal, Central, Temporal, Parietal, Occipital). '
              'Use NaN to omit non-EEG channels from regional averaging.',
              style: TextStyle(fontSize: 12, color: Colors.black87),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.separated(
                itemCount: widget.channels.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final channel = widget.channels[index];
                  final controller = _controllers[channel]!;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 90,
                          child: Text(
                            channel,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                        ),
                        Expanded(
                          child: TextField(
                            controller: controller,
                            decoration: const InputDecoration(
                              isDense: true,
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        PopupMenuButton<String>(
                          icon: const Icon(Icons.arrow_drop_down),
                          tooltip: 'Quick select region',
                          onSelected: (val) {
                            setState(() {
                              controller.text = val;
                            });
                          },
                          itemBuilder: (_) => commonRegions
                              .map((r) => PopupMenuItem(value: r, child: Text(r)))
                              .toList(),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            setState(() {
              for (final channel in widget.channels) {
                _controllers[channel]?.text = defaultRegionForChannel(channel);
              }
            });
          },
          child: const Text('Reset to Defaults'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final result = <String, String>{};
            for (final entry in _controllers.entries) {
              final reg = entry.value.text.trim();
              if (reg.isNotEmpty) {
                result[entry.key] = reg;
              }
            }
            Navigator.of(context).pop(result);
          },
          child: const Text('Save Mapping'),
        ),
      ],
    );
  }
}

class _BatchAutoScoringDialogState extends State<BatchAutoScoringDialog> {
  String _algorithm = kDefaultAutoscoreAlgorithm;
  String _correction = kDefaultSequenceCorrection;
  double _sleepgptAlpha = 0.1;
  int _sleepgptNgram = 30;

  late final Map<String, bool> _eegChannels;
  late final Map<String, bool> _refChannels;
  late final Map<String, bool> _eogChannels;
  late final Map<String, bool> _emgChannels;

  @override
  void initState() {
    super.initState();
    _eegChannels = {};
    _refChannels = {};
    _eogChannels = {};
    _emgChannels = {};

    for (final channel in widget.channelLabels) {
      final group = _classifyScoringChannel(channel);
      _eegChannels[channel] = group.eeg;
      _refChannels[channel] = group.ref;
      _eogChannels[channel] = group.eog;
      _emgChannels[channel] = group.emg;
    }
    if (widget.channelLabels.length == 1 &&
        !_eegChannels.values.any((selected) => selected) &&
        !_refChannels.values.any((selected) => selected) &&
        !_eogChannels.values.any((selected) => selected) &&
        !_emgChannels.values.any((selected) => selected)) {
      _eegChannels[widget.channelLabels.single] = true;
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.auto_awesome_motion, color: Colors.purple),
          const SizedBox(width: 8),
          Text('AutoscoreNidra Batch (${widget.files.length} files)'),
        ],
      ),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Scoring will run in the background for each selected file. '
                'The channel choices below are initialized from the first file '
                'and applied to every selected recording.',
                style: TextStyle(color: Colors.grey.shade700, fontSize: 12),
              ),
              const SizedBox(height: 16),
              // Alg Selection
              const Text(
                'Base Scorer Algorithm',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                isExpanded: true,
                value: _algorithm,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                items: [
                  for (final option in autoscoreAlgorithmOptions)
                    DropdownMenuItem(
                      value: option.$1,
                      child: Text(option.$2, style: const TextStyle(fontSize: 13)),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _algorithm = v);
                },
              ),
              const SizedBox(height: 16),
              // Correction Selection
              const Text(
                'Sequence Correction',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                isExpanded: true,
                value: _correction,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'none',
                    child: Text(
                      'None (Raw consensus predictions)',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'sleepgpt',
                    child: Text(
                      'SleepGPT Language Model',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _correction = v);
                },
              ),
              const SizedBox(height: 16),

              if (_correction == 'sleepgpt') ...[
                Card(
                  margin: EdgeInsets.zero,
                  elevation: 0,
                  color: Colors.purple.shade50,
                  shape: RoundedRectangleBorder(
                    side: BorderSide(color: Colors.purple.shade100),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'SleepGPT Sequence Parameters',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Colors.purple,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            const Expanded(
                              flex: 3,
                              child: Text(
                                'Language model weight (alpha):',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                            SizedBox(
                              width: 90,
                              height: 32,
                              child: TextFormField(
                                initialValue: _sleepgptAlpha.toString(),
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                style: const TextStyle(fontSize: 12),
                                decoration: const InputDecoration(
                                  isDense: true,
                                  contentPadding: EdgeInsets.all(8),
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: (text) {
                                  final d = double.tryParse(text);
                                  if (d != null && d >= 0.0 && d <= 1.0) {
                                    setState(() => _sleepgptAlpha = d);
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            const Expanded(
                              flex: 3,
                              child: Text(
                                'Context sequence length (n-gram):',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                            SizedBox(
                              width: 90,
                              height: 32,
                              child: TextFormField(
                                initialValue: _sleepgptNgram.toString(),
                                keyboardType: TextInputType.number,
                                style: const TextStyle(fontSize: 12),
                                decoration: const InputDecoration(
                                  isDense: true,
                                  contentPadding: EdgeInsets.all(8),
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: (text) {
                                  final val = int.tryParse(text);
                                  if (val != null && val > 0) {
                                    setState(() => _sleepgptNgram = val);
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              const Text(
                'Channels applied to every file',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 6),
              Text(
                'Select channels to apply. Files missing a selected channel '
                'will report a clear failure in the batch log.',
                style: TextStyle(color: Colors.grey.shade700, fontSize: 11),
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _buildChannelSelector(
                      'EEG Signal Channels',
                      _eegChannels,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildChannelSelector(
                      'Reference Signals',
                      _refChannels,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _buildChannelSelector(
                      'EOG Channels (Differential)',
                      _eogChannels,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildChannelSelector(
                      'EMG Channels (Differential)',
                      _emgChannels,
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
        ElevatedButton(
          onPressed: () {
            final eeg = _eegChannels.entries
                .where((e) => e.value)
                .map((e) => e.key)
                .toList();
            final ref = _refChannels.entries
                .where((e) => e.value)
                .map((e) => e.key)
                .toList();
            final eog = _eogChannels.entries
                .where((e) => e.value)
                .map((e) => e.key)
                .toList();
            final emg = _emgChannels.entries
                .where((e) => e.value)
                .map((e) => e.key)
                .toList();

            if (eeg.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Select at least one EEG channel.'),
                ),
              );
              return;
            }
            final settings = <String, dynamic>{
              'algorithm': _algorithm,
              'sequence_correction': _correction,
              'sleepgpt_alpha': _sleepgptAlpha,
              'sleepgpt_ngram': _sleepgptNgram,
              'eeg': eeg,
              'ref': ref,
              'eog': eog,
              'emg': emg,
            };
            Navigator.of(context).pop();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              widget.onRun(settings);
            });
          },
          child: const Text('Run AutoscoreNidra Batch'),
        ),
      ],
    );
  }

  Widget _buildChannelSelector(String label, Map<String, bool> channels) {
    final list = channels.keys.toList();
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            GestureDetector(
              onTap: () {
                setState(() {
                  for (final key in channels.keys) {
                    channels[key] = false;
                  }
                });
              },
              child: const MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Text(
                  'Clear',
                  style: TextStyle(
                    color: Colors.blue,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          height: 110,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Scrollbar(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: list.length,
              itemBuilder: (context, index) {
                final ch = list[index];
                return SizedBox(
                  height: 32,
                  child: CheckboxListTile(
                    title: Text(ch, style: const TextStyle(fontSize: 11)),
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    value: channels[ch],
                    contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                    onChanged: (v) {
                      setState(() {
                        channels[ch] = v ?? false;
                      });
                    },
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class RemDetectionDialog extends StatefulWidget {
  const RemDetectionDialog({
    super.key,
    required this.channelLabels,
    required this.hasStages,
    required this.onRun,
  });

  final List<String> channelLabels;
  final bool hasStages;
  final void Function(RemDetectionOptions options) onRun;

  @override
  State<RemDetectionDialog> createState() => _RemDetectionDialogState();
}

class _RemDetectionDialogState extends State<RemDetectionDialog> {
  late String _selectedLoc;
  late String _selectedRoc;
  double _minDuration = 0.1;
  double _maxDuration = 1.2;
  double _minAmplitude = 25.0;
  double _minVelocity = 150.0;
  bool _restrictToRem = true;
  double _filterLow = 0.5;
  double _filterHigh = 5.0;

  @override
  void initState() {
    super.initState();
    _restrictToRem = widget.hasStages;

    final labels = widget.channelLabels;
    // Auto-select LOC / Left EOG
    _selectedLoc = labels.firstWhere(
      (c) {
        final upper = c.toUpperCase();
        return upper.contains('E1') ||
            upper.contains('LOC') ||
            upper.contains('EOG-L') ||
            upper.contains('LEOG') ||
            upper.contains('EOG1');
      },
      orElse: () => labels.isNotEmpty ? labels.first : '',
    );

    // Auto-select ROC / Right EOG
    _selectedRoc = labels.firstWhere(
      (c) {
        final upper = c.toUpperCase();
        return upper.contains('E2') ||
            upper.contains('ROC') ||
            upper.contains('EOG-R') ||
            upper.contains('REOG') ||
            upper.contains('EOG2');
      },
      orElse: () => labels.length > 1 ? labels[1] : (labels.isNotEmpty ? labels.first : ''),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.remove_red_eye_outlined, color: Colors.teal),
          SizedBox(width: 8),
          Text('Rapid Eye Movement (REM) Detection'),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.teal.shade50,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.teal.shade200),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, size: 20, color: Colors.teal),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Detects conjugate, out-of-phase saccadic eye movements during REM sleep. '
                        'Computes ocular velocity, deflection amplitude, and REM density.',
                        style: TextStyle(fontSize: 12, color: Colors.black87),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'EOG Channels',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Left EOG (LOC / E1-M2)', style: TextStyle(fontSize: 12)),
                        const SizedBox(height: 4),
                        DropdownButtonFormField<String>(
                          value: widget.channelLabels.contains(_selectedLoc) ? _selectedLoc : null,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          ),
                          items: widget.channelLabels.map((ch) {
                            return DropdownMenuItem(
                              value: ch,
                              child: Text(ch, style: const TextStyle(fontSize: 12)),
                            );
                          }).toList(),
                          onChanged: (v) {
                            if (v != null) setState(() => _selectedLoc = v);
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Right EOG (ROC / E2-M1)', style: TextStyle(fontSize: 12)),
                        const SizedBox(height: 4),
                        DropdownButtonFormField<String>(
                          value: widget.channelLabels.contains(_selectedRoc) ? _selectedRoc : null,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          ),
                          items: widget.channelLabels.map((ch) {
                            return DropdownMenuItem(
                              value: ch,
                              child: Text(ch, style: const TextStyle(fontSize: 12)),
                            );
                          }).toList(),
                          onChanged: (v) {
                            if (v != null) setState(() => _selectedRoc = v);
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Detection Thresholds',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      initialValue: _minAmplitude.toStringAsFixed(0),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Min Amplitude (µV)',
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                      onChanged: (v) {
                        final val = double.tryParse(v);
                        if (val != null && val > 0) _minAmplitude = val;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      initialValue: _minVelocity.toStringAsFixed(0),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Min Velocity (µV/s)',
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                      onChanged: (v) {
                        final val = double.tryParse(v);
                        if (val != null && val > 0) _minVelocity = val;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      initialValue: _minDuration.toStringAsFixed(2),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Min Duration (s)',
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                      onChanged: (v) {
                        final val = double.tryParse(v);
                        if (val != null && val > 0) _minDuration = val;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      initialValue: _maxDuration.toStringAsFixed(2),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Max Duration (s)',
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                      onChanged: (v) {
                        final val = double.tryParse(v);
                        if (val != null && val > 0) _maxDuration = val;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      initialValue: _filterLow.toStringAsFixed(1),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Bandpass Low (Hz)',
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                      onChanged: (v) {
                        final val = double.tryParse(v);
                        if (val != null && val > 0) _filterLow = val;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      initialValue: _filterHigh.toStringAsFixed(1),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        labelText: 'Bandpass High (Hz)',
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                      onChanged: (v) {
                        final val = double.tryParse(v);
                        if (val != null && val > 0) _filterHigh = val;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              CheckboxListTile(
                title: const Text('Restrict detection to REM sleep stages', style: TextStyle(fontSize: 13)),
                subtitle: Text(
                  widget.hasStages
                      ? 'Ignores awake and NREM blinks/saccades'
                      : 'Hypnogram not yet scored; will detect across entire recording',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _restrictToRem,
                onChanged: (v) => setState(() => _restrictToRem = v ?? false),
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
          icon: const Icon(Icons.play_arrow, size: 18),
          label: const Text('Run REM Detection'),
          onPressed: () {
            if (_selectedLoc.isEmpty || _selectedRoc.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Please select both Left and Right EOG channels.')),
              );
              return;
            }
            Navigator.of(context).pop();
            widget.onRun(
              RemDetectionOptions(
                locChannel: _selectedLoc,
                rocChannel: _selectedRoc,
                minDurationSeconds: _minDuration,
                maxDurationSeconds: _maxDuration,
                minAmplitudeUv: _minAmplitude,
                minVelocityUvPerSec: _minVelocity,
                restrictToRemStage: _restrictToRem,
                frequencyLowHz: _filterLow,
                frequencyHighHz: _filterHigh,
              ),
            );
          },
        ),
      ],
    );
  }
}
