// Linked batch pipeline: runs the selected EEG analysis steps (autoscore →
// preprocess → extract features → compile) for a set of recordings, feeding
// the output of each step into the next one.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'batch_helpers.dart';

enum PipelineStatus { pending, running, done, reused, skipped, failed, blocked }

/// One recording travelling through the pipeline.
class PipelineRecording {
  PipelineRecording({required this.source, this.scoring = '', this.cleaned, this.regional});

  final String source;

  /// Scoring (hypnogram) used by the feature step.
  String scoring;

  /// Cleaned EDF written by the preprocessing step (or found from an earlier run).
  String? cleaned;

  /// Regional CSV written by the feature step.
  String? regional;

  final Map<String, PipelineStatus> status = {};
  final Map<String, String> notes = {};

  String get name => source.split(RegExp(r'[\\/]')).last;
}

/// Thrown by a step builder to leave a recording out of that step.
class PipelineSkip implements Exception {
  PipelineSkip(this.reason, {this.reused = false});

  final String reason;

  /// The step's output already exists and is reused.
  final bool reused;

  @override
  String toString() => reason;
}

class PipelineStep {
  const PipelineStep({
    required this.key,
    required this.title,
    required this.build,
    this.onSuccess,
  });

  final String key;
  final String title;

  /// Engine arguments for one recording; throw [PipelineSkip] to skip it.
  final List<String> Function(PipelineRecording recording) build;

  /// Called with the step's log after a successful run.
  final void Function(PipelineRecording recording, List<String> log)? onSuccess;
}

/// Path printed by the engine after `OUTPUT_<kind>` (quotes optional).
String? pipelineOutputFromLog(List<String> log, String kind) {
  final re = RegExp('OUTPUT_$kind\\s+["\']?([^"\'\\r\\n]+)["\']?');
  for (final line in log.reversed) {
    final m = re.firstMatch(line);
    if (m != null) return m.group(1)!.trim();
  }
  return null;
}

class PipelineRunDialog extends StatefulWidget {
  const PipelineRunDialog({
    super.key,
    required this.title,
    required this.executable,
    required this.recordings,
    required this.steps,
    required this.logFolder,
    this.finalize,
    this.onFinished,
  });

  final String title;
  final String executable;
  final List<PipelineRecording> recordings;
  final List<PipelineStep> steps;
  final String logFolder;

  /// Runs after all steps (e.g. compiling the master sheet); returns a
  /// message for the log.
  final Future<String?> Function(List<PipelineRecording> recordings)? finalize;
  final void Function(List<PipelineRecording> recordings, int failed)? onFinished;

  @override
  State<PipelineRunDialog> createState() => _PipelineRunDialogState();
}

class _PipelineRunDialogState extends State<PipelineRunDialog> {
  final List<String> _log = [];
  final ScrollController _scroll = ScrollController();
  Process? _process;
  bool _cancelled = false;
  bool _finished = false;
  double _fileProgress = 0;
  String _current = 'Starting…';
  int _done = 0;
  late final int _total = widget.recordings.length * widget.steps.length;

  @override
  void initState() {
    super.initState();
    for (final r in widget.recordings) {
      for (final s in widget.steps) {
        r.status[s.key] = PipelineStatus.pending;
      }
    }
    unawaited(_run());
  }

  @override
  void dispose() {
    _cancelled = true;
    _process?.kill();
    _scroll.dispose();
    super.dispose();
  }

  void _addLog(String line) {
    if (!mounted) return;
    final p = RegExp(r'PROGRESS\s+([01](?:\.\d+)?)\s*(.*)').firstMatch(line);
    setState(() {
      _log.add(line);
      if (_log.length > 4000) _log.removeRange(0, 1000);
      if (p != null) _fileProgress = (double.tryParse(p.group(1)!) ?? 0.0).clamp(0.0, 1.0);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<int> _exec(List<String> args, List<String> fileLog) async {
    final process = await Process.start(widget.executable, args);
    _process = process;
    void handle(String line, {bool err = false}) {
      final text = err ? '[stderr] $line' : line;
      fileLog.add(text);
      _addLog(text);
    }

    final out = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((l) => handle(l));
    final err = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((l) => handle(l, err: true));
    final code = await process.exitCode;
    // Drain the remaining output (the OUTPUT_ lines come last) before closing.
    await Future.wait([out.asFuture<void>(), err.asFuture<void>()])
        .timeout(const Duration(seconds: 5), onTimeout: () => const []);
    await out.cancel();
    await err.cancel();
    _process = null;
    return code;
  }

  Future<void> _run() async {
    final started = DateTime.now();
    final results = <BatchFileResult>[];
    var failed = 0;
    for (final step in widget.steps) {
      if (_cancelled) break;
      _addLog('════ ${step.title} ════');
      for (final r in widget.recordings) {
        if (_cancelled) break;
        if (!mounted) return;
        final blocked = widget.steps
            .takeWhile((s) => s.key != step.key)
            .any((s) => r.status[s.key] == PipelineStatus.failed || r.status[s.key] == PipelineStatus.blocked);
        if (blocked) {
          setState(() {
            r.status[step.key] = PipelineStatus.blocked;
            r.notes[step.key] = 'an earlier step failed';
            _done++;
          });
          continue;
        }
        List<String> args;
        try {
          args = step.build(r);
        } on PipelineSkip catch (s) {
          setState(() {
            r.status[step.key] = s.reused ? PipelineStatus.reused : PipelineStatus.skipped;
            r.notes[step.key] = s.reason;
            _done++;
          });
          _addLog('${r.name}: ${s.reused ? 'reusing' : 'skipped'} — ${s.reason}');
          continue;
        }
        setState(() {
          r.status[step.key] = PipelineStatus.running;
          _current = '${step.title}: ${r.name}';
          _fileProgress = 0;
        });
        _addLog('--- ${step.title}: ${r.name} ---');
        final fileLog = <String>[];
        var code = 1;
        try {
          code = await _exec(args, fileLog);
        } catch (e) {
          fileLog.add('Exception: $e');
          _addLog('Exception: $e');
        }
        if (code == 0) {
          try {
            step.onSuccess?.call(r, fileLog);
          } catch (e) {
            _addLog('Could not read the outputs of ${r.name}: $e');
          }
        } else {
          failed++;
        }
        results.add(BatchFileResult(filePath: '${r.source} [${step.key}]', exitCode: code, logs: fileLog));
        await writeBatchFileLog(
          outputFolder: widget.logFolder,
          originalFilePath: r.source,
          jobType: step.key,
          exitCode: code,
          logLines: fileLog,
        );
        if (!mounted) return;
        setState(() {
          r.status[step.key] = code == 0
              ? PipelineStatus.done
              : (_cancelled ? PipelineStatus.skipped : PipelineStatus.failed);
          if (code != 0) {
            r.notes[step.key] = _cancelled ? 'cancelled' : 'exit code $code (see log)';
          }
          _done++;
        });
      }
    }
    String? finalMessage;
    if (!mounted) return;
    if (!_cancelled && widget.finalize != null) {
      setState(() => _current = 'Compiling…');
      try {
        finalMessage = await widget.finalize!(widget.recordings);
      } catch (e) {
        finalMessage = 'Compilation failed: $e';
      }
      if (finalMessage != null) _addLog(finalMessage);
    }
    await writeBatchRunSummaryLog(
      outputFolder: widget.logFolder,
      jobType: 'pipeline',
      startTime: started,
      endTime: DateTime.now(),
      results: results,
    );
    if (!mounted) return;
    setState(() {
      _finished = true;
      _current = _cancelled
          ? 'Cancelled'
          : failed == 0
          ? 'Finished${finalMessage == null ? '' : ' — $finalMessage'}'
          : 'Finished with $failed failed step(s) — see the log';
    });
    widget.onFinished?.call(widget.recordings, failed);
  }

  Widget _statusIcon(PipelineRecording r, PipelineStep s) {
    final st = r.status[s.key] ?? PipelineStatus.pending;
    final (icon, color, label) = switch (st) {
      PipelineStatus.pending => (Icons.radio_button_unchecked, Colors.grey.shade400, 'waiting'),
      PipelineStatus.running => (Icons.autorenew, Colors.blue, 'running'),
      PipelineStatus.done => (Icons.check_circle, Colors.green.shade600, 'done'),
      PipelineStatus.reused => (Icons.check_circle_outline, Colors.green.shade400, 'reused'),
      PipelineStatus.skipped => (Icons.remove_circle_outline, Colors.grey, 'skipped'),
      PipelineStatus.failed => (Icons.error, Colors.red.shade600, 'failed'),
      PipelineStatus.blocked => (Icons.block, Colors.orange.shade700, 'not run'),
    };
    final note = r.notes[s.key];
    return Tooltip(
      message: note == null ? label : '$label — $note',
      child: Icon(icon, size: 18, color: color),
    );
  }

  @override
  Widget build(BuildContext context) {
    final overall = _total == 0 ? 1.0 : math.min(1.0, (_done + (_finished ? 0 : _fileProgress)) / _total);
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.account_tree_outlined, color: Colors.indigo),
          const SizedBox(width: 8),
          Expanded(child: Text(widget.title)),
        ],
      ),
      content: SizedBox(
        width: 980,
        height: 600,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_current, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: _finished ? 1 : overall),
            const SizedBox(height: 10),
            SizedBox(
              height: 220,
              child: SingleChildScrollView(
                child: Table(
                  columnWidths: const {0: FlexColumnWidth(3)},
                  defaultColumnWidth: const FlexColumnWidth(1),
                  defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                  children: [
                    TableRow(
                      decoration: BoxDecoration(color: Colors.grey.shade100),
                      children: [
                        const Padding(
                          padding: EdgeInsets.all(6),
                          child: Text('Recording', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                        ),
                        for (final s in widget.steps)
                          Padding(
                            padding: const EdgeInsets.all(6),
                            child: Text(s.title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          ),
                      ],
                    ),
                    for (final r in widget.recordings)
                      TableRow(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            child: Text(r.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                          ),
                          for (final s in widget.steps) Center(child: _statusIcon(r, s)),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: ListView.builder(
                  controller: _scroll,
                  itemCount: _log.length,
                  itemBuilder: (_, i) => Text(
                    _log[i],
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: _log[i].startsWith('[stderr]') ? Colors.orange.shade200 : Colors.grey.shade200,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text('Logs: ${widget.logFolder}', style: const TextStyle(fontSize: 11, color: Colors.black54)),
          ],
        ),
      ),
      actions: [
        if (!_finished)
          TextButton(
            onPressed: _cancelled
                ? null
                : () {
                    setState(() {
                      _cancelled = true;
                      _current = 'Cancelling…';
                    });
                    _process?.kill();
                  },
            child: const Text('Cancel'),
          ),
        ElevatedButton(
          onPressed: _finished ? () => Navigator.of(context).pop() : null,
          child: const Text('Close'),
        ),
      ],
    );
  }
}
