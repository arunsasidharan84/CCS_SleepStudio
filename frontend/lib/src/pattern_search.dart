// lib/src/pattern_search.dart

import 'dart:math' as math;
import 'package:flutter/material.dart';

import 'models.dart';

/// Represents a template snippet selected from a channel.
class PatternTemplate {
  const PatternTemplate({
    required this.channel,
    required this.startSec,
    required this.endSec,
    required this.samples,
    required this.sampleRateHz,
  });

  final String channel;
  final double startSec;
  final double endSec;
  final List<double> samples;
  final double sampleRateHz;

  double get durationSec => (endSec - startSec).abs();
  int get length => samples.length;
}

/// Represents a match found by normalized cross-correlation.
class PatternMatch {
  const PatternMatch({
    required this.startSec,
    required this.endSec,
    required this.similarity,
    required this.peakAmplitudeUv,
    required this.epochIndex,
    this.stage,
    this.isInverted = false,
  });

  final double startSec;
  final double endSec;
  final double similarity;
  final double peakAmplitudeUv;
  final int epochIndex;
  final String? stage;
  final bool isInverted;
}

/// Parameters for template pattern matching.
class PatternSearchOptions {
  const PatternSearchOptions({
    this.similarityThreshold = 0.75,
    this.allowInverted = false,
    this.filterStages,
    this.minSeparationSec,
  });

  final double similarityThreshold;
  final bool allowInverted;
  final List<String>? filterStages;
  final double? minSeparationSec;
}

/// High-performance sliding Normalized Cross-Correlation (NCC) pattern matcher.
class PatternMatcher {
  /// Searches for [template] occurrences in [signal].
  static List<PatternMatch> search({
    required List<double> signal,
    required PatternTemplate template,
    required double sampleRateHz,
    List<SleepStage> stages = const [],
    double epochSeconds = 30.0,
    PatternSearchOptions options = const PatternSearchOptions(),
  }) {
    final tSamples = template.samples;
    final m = tSamples.length;
    final n = signal.length;
    if (m < 4 || n < m) return const [];

    // 1. Normalize template: mean-center and unit-norm
    var sumT = 0.0;
    for (var i = 0; i < m; i++) {
      sumT += tSamples[i];
    }
    final meanT = sumT / m;

    var varT = 0.0;
    for (var i = 0; i < m; i++) {
      final diff = tSamples[i] - meanT;
      varT += diff * diff;
    }
    if (varT < 1e-12) return const []; // Flat template cannot be matched

    final normT = List<double>.filled(m, 0.0);
    final invStdT = 1.0 / math.sqrt(varT);
    for (var i = 0; i < m; i++) {
      normT[i] = (tSamples[i] - meanT) * invStdT;
    }

    final threshold = options.similarityThreshold.clamp(0.1, 1.0);
    final allowInverted = options.allowInverted;
    final minSepSamples = (options.minSeparationSec != null
            ? (options.minSeparationSec! * sampleRateHz).round()
            : (m / 2).round())
        .clamp(1, n);

    final stageSet = options.filterStages?.toSet();

    // 2. Sliding window boxcar sums for fast variance calculation
    var s1 = 0.0;
    var s2 = 0.0;
    for (var i = 0; i < m; i++) {
      final v = signal[i];
      s1 += v;
      s2 += v * v;
    }

    // Step across the signal
    final rawScores = List<double>.filled(n - m + 1, 0.0);
    final invM = 1.0 / m;

    for (var i = 0; i <= n - m; i++) {
      if (i > 0) {
        final leaving = signal[i - 1];
        final entering = signal[i + m - 1];
        s1 += entering - leaving;
        s2 += entering * entering - leaving * leaving;
      }

      final varX = s2 - (s1 * s1 * invM);
      if (varX > 1e-9) {
        final invStdX = 1.0 / math.sqrt(varX);
        var dot = 0.0;
        for (var j = 0; j < m; j++) {
          dot += signal[i + j] * normT[j];
        }
        rawScores[i] = dot * invStdX;
      } else {
        rawScores[i] = 0.0;
      }
    }

    // 3. Peak detection & non-maximum suppression
    final candidates = <(int, double, bool)>[];
    for (var i = 0; i <= n - m; i++) {
      final score = rawScores[i];
      final absScore = score.abs();
      final isInverted = score < 0;

      final passes = allowInverted ? (absScore >= threshold) : (score >= threshold);
      if (!passes) continue;

      // Check local maximum within +/- 2 samples
      final leftCheck = (i > 0) ? rawScores[i - 1].abs() : 0.0;
      final rightCheck = (i < n - m) ? rawScores[i + 1].abs() : 0.0;
      if (absScore >= leftCheck && absScore >= rightCheck) {
        candidates.add((i, absScore, isInverted));
      }
    }

    // Sort by correlation score descending for greedy non-maximum suppression
    candidates.sort((a, b) => b.$2.compareTo(a.$2));

    final selectedIndices = <(int, double, bool)>[];
    for (final cand in candidates) {
      final idx = cand.$1;
      var tooClose = false;
      for (final sel in selectedIndices) {
        if ((idx - sel.$1).abs() < minSepSamples) {
          tooClose = true;
          break;
        }
      }
      if (!tooClose) {
        selectedIndices.add(cand);
      }
    }

    // Sort temporally
    selectedIndices.sort((a, b) => a.$1.compareTo(b.$1));

    // 4. Construct matches and calculate peak amplitude and sleep stage
    final matches = <PatternMatch>[];
    for (final (idx, score, isInverted) in selectedIndices) {
      final startSec = idx / sampleRateHz;
      final endSec = (idx + m) / sampleRateHz;
      final midSec = (startSec + endSec) / 2.0;
      final epochIdx = (midSec / epochSeconds).floor();

      String? stageLabel;
      if (epochIdx >= 0 && epochIdx < stages.length) {
        stageLabel = stages[epochIdx].label;
        if (stageSet != null && stageSet.isNotEmpty && !stageSet.contains(stageLabel)) {
          continue; // Filtered by sleep stage
        }
      } else if (stageSet != null && stageSet.isNotEmpty) {
        continue;
      }

      var minV = signal[idx];
      var maxV = signal[idx];
      for (var j = 1; j < m; j++) {
        final val = signal[idx + j];
        if (val < minV) minV = val;
        if (val > maxV) maxV = val;
      }
      final peakToPeak = maxV - minV;

      matches.add(
        PatternMatch(
          startSec: startSec,
          endSec: endSec,
          similarity: score,
          peakAmplitudeUv: peakToPeak,
          epochIndex: epochIdx + 1,
          stage: stageLabel,
          isInverted: isInverted,
        ),
      );
    }

    return matches;
  }
}

/// Interactive dialog for template pattern detection across channels.
class PatternSearchDialog extends StatefulWidget {
  const PatternSearchDialog({
    super.key,
    required this.template,
    required this.channelLabels,
    required this.hasStages,
    required this.sampleRateHz,
    required this.onJumpToTime,
    required this.onAddEvents,
    required this.getChannelSignal,
    this.stages = const [],
    this.epochSeconds = 30.0,
  });

  final PatternTemplate template;
  final List<String> channelLabels;
  final bool hasStages;
  final double sampleRateHz;
  final void Function(double seconds) onJumpToTime;
  final void Function(List<ScoredEvent> events) onAddEvents;
  final List<double>? Function(String channelName) getChannelSignal;
  final List<SleepStage> stages;
  final double epochSeconds;

  @override
  State<PatternSearchDialog> createState() => _PatternSearchDialogState();
}

class _PatternSearchDialogState extends State<PatternSearchDialog> {
  late String _targetChannel;
  double _similarityThreshold = 0.75;
  bool _allowInverted = false;
  String _selectedMarker = 'F10'; // default Spindle / Pattern
  bool _isSearching = false;
  List<PatternMatch> _matches = const [];
  String? _statusMessage;

  // Stage filters
  final Map<String, bool> _stages = {
    'Wake': false,
    'N1': false,
    'N2': true,
    'N3': true,
    'REM': false,
  };
  bool _useStageFilter = false;

  @override
  void initState() {
    super.initState();
    _targetChannel = widget.template.channel;
    _useStageFilter = widget.hasStages;
  }

  void _runSearch() {
    setState(() {
      _isSearching = true;
      _statusMessage = null;
    });

    final sig = widget.getChannelSignal(_targetChannel);
    if (sig == null || sig.isEmpty) {
      setState(() {
        _isSearching = false;
        _statusMessage = 'Channel "$_targetChannel" signal not found.';
      });
      return;
    }

    final activeStages = _useStageFilter
        ? _stages.entries.where((e) => e.value).map((e) => e.key).toList()
        : null;

    final results = PatternMatcher.search(
      signal: sig,
      template: widget.template,
      sampleRateHz: widget.sampleRateHz,
      stages: widget.stages,
      epochSeconds: widget.epochSeconds,
      options: PatternSearchOptions(
        similarityThreshold: _similarityThreshold,
        allowInverted: _allowInverted,
        filterStages: activeStages,
      ),
    );

    setState(() {
      _matches = results;
      _isSearching = false;
      _statusMessage = results.isEmpty
          ? 'No matching patterns found with similarity >= ${(_similarityThreshold * 100).toInt()}%.'
          : 'Found ${results.length} matching patterns.';
    });
  }

  void _markAllAsEvents() {
    if (_matches.isEmpty) return;

    final digit = int.tryParse(_selectedMarker.replaceAll(RegExp(r'[^0-9]'), '')) ?? 10;
    final markerName = kDefaultAasmEventNames[digit] ?? 'Pattern';

    final events = _matches.map((m) {
      final simStr = '${(m.similarity * 100).toStringAsFixed(0)}%';
      return ScoredEvent(
        digit: digit,
        key: _selectedMarker,
        label: '$markerName ($simStr${m.isInverted ? ", inv" : ""})',
        type: 'Pattern',
        channel: _targetChannel,
        startSec: m.startSec,
        endSec: m.endSec,
      );
    }).toList();

    widget.onAddEvents(events);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Container(
        width: 660,
        height: 640,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title Bar
            Row(
              children: [
                const Icon(Icons.saved_search, size: 26, color: Color(0xFF0284C7)),
                const SizedBox(width: 10),
                const Text(
                  'Pattern Template Search (NCC)',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: 'Close',
                ),
              ],
            ),
            const Divider(height: 18),

            // Template Preview & Settings
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Waveform Preview Box
                Expanded(
                  flex: 5,
                  child: Container(
                    height: 130,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.blueGrey.shade700),
                    ),
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Template: ${widget.template.channel}',
                              style: const TextStyle(
                                color: Colors.cyanAccent,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              '${widget.template.durationSec.toStringAsFixed(2)} s (${widget.template.length} pts)',
                              style: const TextStyle(color: Colors.white70, fontSize: 11),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Expanded(
                          child: CustomPaint(
                            painter: _TemplateWaveformPainter(widget.template.samples),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                // Search Parameters
                Expanded(
                  flex: 6,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const SizedBox(
                            width: 100,
                            child: Text(
                              'Scan Channel:',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              value: _targetChannel,
                              isDense: true,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              ),
                              items: widget.channelLabels.map((c) {
                                return DropdownMenuItem(value: c, child: Text(c, style: const TextStyle(fontSize: 12)));
                              }).toList(),
                              onChanged: (v) {
                                if (v != null) setState(() => _targetChannel = v);
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          SizedBox(
                            width: 100,
                            child: Text(
                              'Similarity: ${(_similarityThreshold * 100).toInt()}%',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              value: _similarityThreshold,
                              min: 0.50,
                              max: 0.98,
                              divisions: 48,
                              label: '${(_similarityThreshold * 100).toInt()}%',
                              onChanged: (val) => setState(() => _similarityThreshold = val),
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          Checkbox(
                            value: _allowInverted,
                            visualDensity: VisualDensity.compact,
                            onChanged: (val) => setState(() => _allowInverted = val ?? false),
                          ),
                          const Text('Allow inverted (+ / -) pattern', style: TextStyle(fontSize: 12)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),

            // Stage filters if available
            if (widget.hasStages) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Checkbox(
                    value: _useStageFilter,
                    visualDensity: VisualDensity.compact,
                    onChanged: (v) => setState(() => _useStageFilter = v ?? false),
                  ),
                  const Text('Restrict to Sleep Stages:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  for (final st in _stages.keys) ...[
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: _stages[st],
                          visualDensity: VisualDensity.compact,
                          onChanged: _useStageFilter
                              ? (v) => setState(() => _stages[st] = v ?? false)
                              : null,
                        ),
                        Text(st, style: TextStyle(fontSize: 11, color: _useStageFilter ? Colors.black87 : Colors.grey)),
                        const SizedBox(width: 6),
                      ],
                    ),
                  ],
                ],
              ),
            ],

            const SizedBox(height: 8),
            // Search Button & Status Row
            Row(
              children: [
                FilledButton.icon(
                  icon: _isSearching
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.search, size: 18),
                  label: Text(_isSearching ? 'Searching...' : 'Find Matches'),
                  onPressed: _isSearching ? null : _runSearch,
                ),
                const SizedBox(width: 14),
                if (_statusMessage != null)
                  Expanded(
                    child: Text(
                      _statusMessage!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _matches.isNotEmpty ? Colors.green.shade700 : Colors.blueGrey,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),

            // Results Table
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: _matches.isEmpty
                    ? Center(
                        child: Text(
                          _statusMessage ?? 'Click "Find Matches" to scan the recording for this pattern.',
                          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                        ),
                      )
                    : Column(
                        children: [
                          Container(
                            color: Colors.blueGrey.shade50,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            child: const Row(
                              children: [
                                SizedBox(width: 40, child: Text('#', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))),
                                SizedBox(width: 80, child: Text('Time', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))),
                                SizedBox(width: 60, child: Text('Epoch', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))),
                                SizedBox(width: 70, child: Text('Stage', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))),
                                SizedBox(width: 90, child: Text('Similarity', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))),
                                SizedBox(width: 90, child: Text('Peak-Peak', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))),
                                Spacer(),
                                SizedBox(width: 80, child: Text('Action', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11))),
                              ],
                            ),
                          ),
                          Expanded(
                            child: ListView.separated(
                              itemCount: _matches.length,
                              separatorBuilder: (context, index) => const Divider(height: 1),
                              itemBuilder: (ctx, i) {
                                final m = _matches[i];
                                final timeStr = _formatSec(m.startSec);
                                return Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                  child: Row(
                                    children: [
                                      SizedBox(width: 40, child: Text('${i + 1}', style: const TextStyle(fontSize: 11))),
                                      SizedBox(width: 80, child: Text(timeStr, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
                                      SizedBox(width: 60, child: Text('${m.epochIndex}', style: const TextStyle(fontSize: 11))),
                                      SizedBox(width: 70, child: Text(m.stage ?? '—', style: const TextStyle(fontSize: 11))),
                                      SizedBox(
                                        width: 90,
                                        child: Text(
                                          '${(m.similarity * 100).toStringAsFixed(1)}%${m.isInverted ? " (inv)" : ""}',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: m.similarity >= 0.85 ? Colors.green.shade800 : Colors.indigo.shade800,
                                          ),
                                        ),
                                      ),
                                      SizedBox(width: 90, child: Text('${m.peakAmplitudeUv.toStringAsFixed(1)} µV', style: const TextStyle(fontSize: 11))),
                                      const Spacer(),
                                      SizedBox(
                                        width: 80,
                                        child: OutlinedButton(
                                          style: OutlinedButton.styleFrom(
                                            visualDensity: VisualDensity.compact,
                                            padding: const EdgeInsets.symmetric(horizontal: 8),
                                          ),
                                          onPressed: () => widget.onJumpToTime(m.startSec),
                                          child: const Text('Jump', style: TextStyle(fontSize: 11)),
                                        ),
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
            ),
            const SizedBox(height: 12),

            // Footer Actions
            Row(
              children: [
                const Text('Marker to Assign:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: _selectedMarker,
                  isDense: true,
                  items: kDefaultAasmShortcuts.entries.map((e) {
                    final name = kDefaultAasmEventNames[e.key] ?? 'Event ${e.key}';
                    return DropdownMenuItem(
                      value: e.value,
                      child: Text('${e.value}: $name', style: const TextStyle(fontSize: 12)),
                    );
                  }).toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => _selectedMarker = v);
                  },
                ),
                const Spacer(),
                FilledButton.icon(
                  icon: const Icon(Icons.bookmark_add, size: 16),
                  label: Text('Mark All as Events (${_matches.length})'),
                  onPressed: _matches.isEmpty ? null : _markAllAsEvents,
                ),
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatSec(double s) {
    final h = (s / 3600).floor();
    final m = ((s % 3600) / 60).floor();
    final sec = (s % 60).floor();
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }
}

/// Paints the waveform snippet inside the template card.
class _TemplateWaveformPainter extends CustomPainter {
  const _TemplateWaveformPainter(this.samples);

  final List<double> samples;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) return;

    var minV = samples.first;
    var maxV = samples.first;
    for (final s in samples) {
      if (s < minV) minV = s;
      if (s > maxV) maxV = s;
    }
    final range = (maxV - minV).abs();
    final pad = range < 1e-6 ? 1.0 : range * 0.15;
    final top = maxV + pad;
    final bottom = minV - pad;
    final span = (top - bottom).abs();

    // Baseline grid line
    final zeroY = size.height * (1.0 - (0.0 - bottom) / span).clamp(0.0, 1.0);
    canvas.drawLine(
      Offset(0, zeroY),
      Offset(size.width, zeroY),
      Paint()
        ..color = Colors.white24
        ..strokeWidth = 1.0,
    );

    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = (i / (samples.length - 1)) * size.width;
      final y = size.height * (1.0 - (samples[i] - bottom) / span).clamp(0.0, 1.0);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF38BDF8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8,
    );
  }

  @override
  bool shouldRepaint(covariant _TemplateWaveformPainter oldDelegate) =>
      oldDelegate.samples != samples;
}
