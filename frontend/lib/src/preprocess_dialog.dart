import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'eeg_backend.dart';
import 'autoscore_command.dart';

class PreprocessDialog extends StatefulWidget {
  const PreprocessDialog({
    super.key,
    required this.inputFilePath,
    this.initialChannels = const [],
    this.initialStimArtifactOnly = false,
    this.initialEcgArtifactOnly = false,
    this.onCompleted,
  });

  final String inputFilePath;
  final List<String> initialChannels;
  final bool initialStimArtifactOnly;
  final bool initialEcgArtifactOnly;
  final void Function(String cleanedFilePath)? onCompleted;

  @override
  State<PreprocessDialog> createState() => _PreprocessDialogState();
}

class _PreprocessDialogState extends State<PreprocessDialog> {
  late TextEditingController _channelsController;
  late TextEditingController _outDirController;
  late TextEditingController _downsampleController;
  late TextEditingController _bpLoController;
  late TextEditingController _bpHiController;
  late TextEditingController _notchController;
  late TextEditingController _suffixController;
  late TextEditingController _stimF0Controller;
  late TextEditingController _stimWinController;
  late TextEditingController _stimMaxCombsController;
  late TextEditingController _badChannelThreshController;
  late TextEditingController _ecgChannelController;

  bool _stepEcgArtifact = false;
  bool _stepStimArtifact = false;
  bool _stepDownsample = false;
  bool _stepFilter = true;
  bool _stepBadChannel = true;
  bool _stepGedai = true;
  bool _stepInterpolate = true;

  bool _isProcessing = false;
  double _progress = 0.0;
  final List<String> _logs = [];
  final ScrollController _scrollController = ScrollController();
  String? _outputEdfPath;

  @override
  void initState() {
    super.initState();
    _channelsController = TextEditingController(text: widget.initialChannels.join(', '));
    _outDirController = TextEditingController(text: File(widget.inputFilePath).parent.path);
    _downsampleController = TextEditingController(text: '250');
    _bpLoController = TextEditingController(text: '0.5');
    _bpHiController = TextEditingController(text: '40.0');
    _notchController = TextEditingController(text: '50.0');
    _stimF0Controller = TextEditingController(text: '');
    _stimWinController = TextEditingController(text: '10.0');
    _stimMaxCombsController = TextEditingController(text: '4');
    _badChannelThreshController = TextEditingController(text: '0.75');
    final ecgCandidate = widget.initialChannels.firstWhere(
      (c) => c.toUpperCase().contains('ECG') || c.toUpperCase().contains('EKG'),
      orElse: () => '',
    );
    _ecgChannelController = TextEditingController(text: ecgCandidate);

    if (widget.initialEcgArtifactOnly) {
      _stepEcgArtifact = true;
      _stepStimArtifact = false;
      _stepDownsample = false;
      _stepFilter = false;
      _stepBadChannel = false;
      _stepGedai = false;
      _stepInterpolate = false;
      _suffixController = TextEditingController(text: '_noecg');
    } else if (widget.initialStimArtifactOnly) {
      _stepEcgArtifact = false;
      _stepStimArtifact = true;
      _stepDownsample = false;
      _stepFilter = false;
      _stepBadChannel = false;
      _stepGedai = false;
      _stepInterpolate = false;
      _suffixController = TextEditingController(text: '_stimclean');
    } else {
      _stepEcgArtifact = false;
      _stepStimArtifact = false;
      _stepDownsample = false;
      _stepFilter = true;
      _stepBadChannel = true;
      _stepGedai = true;
      _stepInterpolate = true;
      _suffixController = TextEditingController(text: '_clean');
    }
  }

  @override
  void dispose() {
    _channelsController.dispose();
    _outDirController.dispose();
    _downsampleController.dispose();
    _bpLoController.dispose();
    _bpHiController.dispose();
    _notchController.dispose();
    _suffixController.dispose();
    _stimF0Controller.dispose();
    _stimWinController.dispose();
    _stimMaxCombsController.dispose();
    _badChannelThreshController.dispose();
    _ecgChannelController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _addLog(String line) {
    if (!mounted) return;
    setState(() {
      _logs.add(line);
      if (line.startsWith('PROGRESS ')) {
        final parts = line.split(' ');
        if (parts.length >= 2) {
          final p = double.tryParse(parts[1]);
          if (p != null) _progress = p;
        }
      }
      if (line.startsWith('OUTPUT_EDF ')) {
        _outputEdfPath = line.substring('OUTPUT_EDF '.length).trim();
        // Strip quotes if present
        if (_outputEdfPath!.startsWith('"') && _outputEdfPath!.endsWith('"')) {
          _outputEdfPath = _outputEdfPath!.substring(1, _outputEdfPath!.length - 1);
        }
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _runPreprocessing() async {
    setState(() {
      _isProcessing = true;
      _progress = 0.05;
      _logs.clear();
      _outputEdfPath = null;
    });

    final steps = <String>[];
    // Stimulation artefact removal runs first, on the raw signal, so that filtering and
    // RANSAC bad-channel detection are not driven by the periodic DBS artefact.
    if (_stepStimArtifact) steps.add('stimartifact');
    if (_stepEcgArtifact) steps.add('ecg');
    if (_stepDownsample) steps.add('downsample');
    if (_stepFilter) steps.add('filter');
    if (_stepBadChannel) steps.add('badchannel');
    if (_stepGedai) steps.add('gedai');
    if (_stepInterpolate) steps.add('interpolate');

    if (steps.isEmpty) {
      _addLog('ERROR: Please select at least one preprocessing step.');
      setState(() => _isProcessing = false);
      return;
    }

    final rawArgs = <String>[
      widget.inputFilePath,
      '--steps',
      steps.join(','),
      '--suffix',
      _suffixController.text.trim().isEmpty ? '_clean' : _suffixController.text.trim(),
    ];

    if (_outDirController.text.trim().isNotEmpty) {
      rawArgs.addAll(['--out-dir', _outDirController.text.trim()]);
    }

    final chans = _channelsController.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (chans.isNotEmpty) {
      rawArgs.addAll(['--eeg-channels', chans.join(',')]);
    }

    if (_stepEcgArtifact) {
      final ecg = _ecgChannelController.text.trim();
      if (ecg.isNotEmpty) rawArgs.addAll(['--ecg-channel', ecg]);
    }

    if (_stepDownsample) {
      final ds = int.tryParse(_downsampleController.text.trim());
      if (ds != null && ds > 0) {
        rawArgs.addAll(['--downsample-hz', ds.toString()]);
      }
    }

    if (_stepStimArtifact) {
      final f0 = double.tryParse(_stimF0Controller.text.trim());
      if (f0 != null && f0 > 0) rawArgs.addAll(['--stim-f0', f0.toString()]);
      final win = double.tryParse(_stimWinController.text.trim());
      if (win != null && win > 0) rawArgs.addAll(['--stim-win', win.toString()]);
      final combs = int.tryParse(_stimMaxCombsController.text.trim());
      if (combs != null && combs > 0) rawArgs.addAll(['--stim-max-combs', combs.toString()]);
    }

    if (_stepBadChannel) {
      final thresh = double.tryParse(_badChannelThreshController.text.trim());
      if (thresh != null && thresh > 0) rawArgs.addAll(['--bad-channel-threshold', thresh.toString()]);
    }

    if (_stepFilter) {
      final lo = double.tryParse(_bpLoController.text.trim());
      final hi = double.tryParse(_bpHiController.text.trim());
      final notch = double.tryParse(_notchController.text.trim());
      if (lo != null) rawArgs.addAll(['--bandpass-lo', lo.toString()]);
      if (hi != null) rawArgs.addAll(['--bandpass-hi', hi.toString()]);
      if (notch != null) rawArgs.addAll(['--notch-hz', notch.toString()]);
    }

    final executable = detectAnalyseNidraExecutable();
    final commandArgs = ['--preprocess', ...rawArgs];

    _addLog('Starting EEG preprocessing pipeline (Native Rust / Zero-Python)...');
    _addLog('Source: ${widget.inputFilePath}');
    _addLog('Steps: ${steps.join(" -> ")}');

    try {
      final exitCode = await EegBackend().runCommandStreamAsync(
        executable: executable,
        arguments: commandArgs,
        onLine: _addLog,
      );

      setState(() {
        _isProcessing = false;
        if (exitCode == 0) {
          _progress = 1.0;
          _addLog('Preprocessing finished successfully.');
          if (_outputEdfPath != null) {
            widget.onCompleted?.call(_outputEdfPath!);
          }
        } else {
          _addLog('Process exited with non-zero exit code: $exitCode');
        }
      });
    } catch (e) {
      setState(() {
        _isProcessing = false;
        _addLog('Execution error: $e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final fileName = File(widget.inputFilePath).path.split(Platform.isWindows ? r'\' : '/').last;

    IconData titleIcon = Icons.auto_fix_high;
    Color titleColor = Colors.purple;
    String titleText = 'EEG Preprocessing Pipeline — $fileName';
    String actionBtnText = 'Run Preprocessing';

    if (widget.initialEcgArtifactOnly) {
      titleIcon = Icons.monitor_heart;
      titleColor = Colors.red.shade700;
      titleText = 'Remove ECG Artefacts (Cardiac QRS Subtraction) — $fileName';
      actionBtnText = 'Remove ECG Artefact';
    } else if (widget.initialStimArtifactOnly) {
      titleIcon = Icons.electric_bolt;
      titleColor = Colors.amber.shade800;
      titleText = 'Auto Electric Stim Artefact Removal (DBS) — $fileName';
      actionBtnText = 'Remove Stim Artefact';
    }

    return AlertDialog(
      title: Row(
        children: [
          Icon(titleIcon, color: titleColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              titleText,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 820,
        height: 580,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Left column: settings
            SizedBox(
              width: 390,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.initialEcgArtifactOnly)
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: const Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.info_outline, size: 18, color: Colors.red),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'QRS-synchronous cardiac template subtraction: detects R-peaks on ECG, extracts the cardiac artifact waveform conducted to sleep EEG derivations, and cleanly subtracts it without affecting sleep spindles or slow waves.',
                                style: TextStyle(fontSize: 11.5, color: Colors.black87),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (widget.initialStimArtifactOnly)
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.blue.shade200),
                        ),
                        child: const Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.info_outline, size: 18, color: Colors.blue),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Continuous adaptive harmonic comb filter: removes periodic electrical stimulation / DBS artefacts on continuous recordings prior to epoching, filtering, or downstream analyses.',
                                style: TextStyle(fontSize: 11.5, color: Colors.black87),
                              ),
                            ),
                          ],
                        ),
                      ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.indigo.shade50,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.indigo.shade200),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.bolt, size: 16, color: Colors.indigo),
                          SizedBox(width: 8),
                          Text(
                            'Engine: Native Rust (Zero-Python, Ultra-Fast)',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.indigo),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text('EEG Channels to Clean:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    const SizedBox(height: 4),
                    TextFormField(
                      controller: _channelsController,
                      decoration: const InputDecoration(
                        hintText: 'e.g. Fp1, Fp2, C3, C4, O1, O2 (empty = auto-detect)',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    const Text('Pipeline Steps (ccstools / GEDAI):', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    const SizedBox(height: 4),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('ECG Artefact Removal (Cardiac QRS Subtraction)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      subtitle: const Text(
                        'Pan-Tompkins R-peak detection & QRS template subtraction on EEG',
                        style: TextStyle(fontSize: 10),
                      ),
                      value: _stepEcgArtifact,
                      onChanged: _isProcessing ? null : (v) => setState(() => _stepEcgArtifact = v ?? false),
                    ),
                    if (_stepEcgArtifact)
                      Padding(
                        padding: const EdgeInsets.only(left: 32, bottom: 6),
                        child: TextFormField(
                          controller: _ecgChannelController,
                          enabled: !_isProcessing,
                          decoration: const InputDecoration(
                            labelText: 'ECG Channel (e.g. ECG, ECG I, EKG)',
                            hintText: 'blank = auto-detect',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Auto electric stim artefact removal (DBS / neurostimulator)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      subtitle: const Text(
                        'Continuous adaptive harmonic comb filter; auto-detects fundamental stimulation frequency',
                        style: TextStyle(fontSize: 10),
                      ),
                      value: _stepStimArtifact,
                      onChanged: _isProcessing ? null : (v) => setState(() => _stepStimArtifact = v ?? false),
                    ),
                    if (_stepStimArtifact)
                      Padding(
                        padding: const EdgeInsets.only(left: 32, bottom: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextFormField(
                              controller: _stimF0Controller,
                              enabled: !_isProcessing,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              decoration: const InputDecoration(
                                labelText: 'Artefact fundamental freq (Hz)',
                                hintText: 'blank = auto-detect',
                                isDense: true,
                                border: OutlineInputBorder(),
                              ),
                              style: const TextStyle(fontSize: 12),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Expanded(
                                  child: TextFormField(
                                    controller: _stimWinController,
                                    enabled: !_isProcessing,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    decoration: const InputDecoration(
                                      labelText: 'Window (sec)',
                                      hintText: '10.0',
                                      isDense: true,
                                      border: OutlineInputBorder(),
                                    ),
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextFormField(
                                    controller: _stimMaxCombsController,
                                    enabled: !_isProcessing,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: 'Max combs',
                                      hintText: '4',
                                      isDense: true,
                                      border: OutlineInputBorder(),
                                    ),
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Downsample to 250 Hz', style: TextStyle(fontSize: 12)),
                      value: _stepDownsample,
                      onChanged: _isProcessing ? null : (v) => setState(() => _stepDownsample = v ?? false),
                    ),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Bandpass & Notch Filter (0.5–40 Hz, 50 Hz)', style: TextStyle(fontSize: 12)),
                      value: _stepFilter,
                      onChanged: _isProcessing ? null : (v) => setState(() => _stepFilter = v ?? true),
                    ),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Bad Channel Detection (RANSAC)', style: TextStyle(fontSize: 12)),
                      value: _stepBadChannel,
                      onChanged: _isProcessing ? null : (v) => setState(() => _stepBadChannel = v ?? true),
                    ),
                    if (_stepBadChannel)
                      Padding(
                        padding: const EdgeInsets.only(left: 32, bottom: 6),
                        child: TextFormField(
                          controller: _badChannelThreshController,
                          enabled: !_isProcessing,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: const InputDecoration(
                            labelText: 'RANSAC Correlation Threshold (0.0–1.0)',
                            hintText: '0.75',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),

                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('GEDAI Artifact Denoising (Leadfield GED)', style: TextStyle(fontSize: 12)),
                      value: _stepGedai,
                      onChanged: _isProcessing ? null : (v) => setState(() => _stepGedai = v ?? true),
                    ),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Interpolate Bad Channels (Spherical Spline)', style: TextStyle(fontSize: 12)),
                      value: _stepInterpolate,
                      onChanged: _isProcessing ? null : (v) => setState(() => _stepInterpolate = v ?? true),
                    ),
                    const Divider(),
                    const Text('Output Options:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _outDirController,
                            decoration: const InputDecoration(
                              labelText: 'Output Folder',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.folder_open, size: 20),
                          tooltip: 'Choose Output Folder',
                          onPressed: _isProcessing
                              ? null
                              : () async {
                                  final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Select Output Directory');
                                  if (dir != null) {
                                    setState(() => _outDirController.text = dir);
                                  }
                                },
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _suffixController,
                      decoration: const InputDecoration(
                        labelText: 'Filename Suffix',
                        hintText: '_clean',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            const VerticalDivider(width: 1),
            const SizedBox(width: 16),
            // Right column: console logs and progress
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Processing Logs:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(height: 6),
                  if (_isProcessing || _progress > 0)
                    LinearProgressIndicator(value: _progress > 0 ? _progress : null),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: ListView.builder(
                        controller: _scrollController,
                        itemCount: _logs.length,
                        itemBuilder: (context, index) {
                          final line = _logs[index];
                          Color color = Colors.lightGreenAccent;
                          if (line.startsWith('ERROR') || line.contains('failed') || line.contains('Error')) {
                            color = Colors.redAccent;
                          } else if (line.startsWith('PROGRESS')) {
                            color = Colors.cyanAccent;
                          }
                          return Text(
                            line,
                            style: TextStyle(fontFamily: 'Courier', fontSize: 11, color: color),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isProcessing ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        ElevatedButton.icon(
          icon: const Icon(Icons.play_arrow),
          label: Text(_isProcessing ? 'Processing...' : actionBtnText),
          style: ElevatedButton.styleFrom(
            backgroundColor: widget.initialEcgArtifactOnly ? Colors.red.shade700 : Colors.purple,
            foregroundColor: Colors.white,
          ),
          onPressed: _isProcessing ? null : _runPreprocessing,
        ),
      ],
    );
  }
}
