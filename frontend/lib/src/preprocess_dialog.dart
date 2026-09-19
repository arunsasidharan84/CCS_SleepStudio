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
    this.onCompleted,
  });

  final String inputFilePath;
  final List<String> initialChannels;
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
    _suffixController = TextEditingController(text: '_clean');
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

    AutoscoreInvocation invocation;
    try {
      invocation = resolveAutoscoreInvocation();
    } catch (e) {
      _addLog('ERROR: Failed to resolve backend runtime: $e');
      setState(() => _isProcessing = false);
      return;
    }

    // Resolve script path or backend executable
    String executable = invocation.executable;
    List<String> commandArgs = [];

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

    if (_stepDownsample) {
      final ds = int.tryParse(_downsampleController.text.trim());
      if (ds != null && ds > 0) {
        rawArgs.addAll(['--downsample-hz', ds.toString()]);
      }
    }

    if (_stepFilter) {
      final lo = double.tryParse(_bpLoController.text.trim());
      final hi = double.tryParse(_bpHiController.text.trim());
      final notch = double.tryParse(_notchController.text.trim());
      if (lo != null) rawArgs.addAll(['--bandpass-lo', lo.toString()]);
      if (hi != null) rawArgs.addAll(['--bandpass-hi', hi.toString()]);
      if (notch != null) rawArgs.addAll(['--notch-hz', notch.toString()]);
    }

    // Check if running from source python script or standalone compiled binary
    if (invocation.argumentPrefix.isNotEmpty) {
      // In development mode, find preprocess.py in the same folder as cli.py
      final scriptDir = File(invocation.argumentPrefix.last).parent;
      final preprocessScript = File('${scriptDir.path}${Platform.pathSeparator}preprocess.py');
      if (preprocessScript.existsSync()) {
        commandArgs = [preprocessScript.path, ...rawArgs];
      } else {
        commandArgs = invocation.argumentsFor(['--preprocess', ...rawArgs]);
      }
    } else {
      commandArgs = invocation.argumentsFor(['--preprocess', ...rawArgs]);
    }

    _addLog('Starting EEG preprocessing pipeline...');
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

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.auto_fix_high, color: Colors.purple),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'EEG Preprocessing — $fileName',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 760,
        height: 560,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Left column: settings
            SizedBox(
              width: 340,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
          label: Text(_isProcessing ? 'Processing...' : 'Run Preprocessing'),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.purple,
            foregroundColor: Colors.white,
          ),
          onPressed: _isProcessing ? null : _runPreprocessing,
        ),
      ],
    );
  }
}
