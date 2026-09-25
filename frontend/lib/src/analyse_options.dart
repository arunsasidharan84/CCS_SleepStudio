import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// Analyses the native AnalyseNidra engine can run (`--analyses`).
const List<(String, String, String)> kAnalyseNidraAnalyses = [
  (
    'core',
    'Spectral & complexity features',
    'Band powers, FOOOF / IRASA aperiodic fits, entropy and complexity per stage',
  ),
  ('spindles', 'Sleep spindles', 'Spindle detection and spindle parameters'),
  (
    'slow_waves',
    'Slow waves & SO–spindle coupling',
    'Slow-wave detection with MI / gcPAC / ndPAC / MVL / PLV coupling',
  ),
  ('pac', 'Phase–amplitude coupling map', 'Full PAC comodulogram per channel'),
  (
    'nlg',
    'NeuroLoopGain',
    'Amplitude-independent slow-wave and sigma feedback-loop gain (Kemp 2000)',
  ),
];

/// NeuroLoopGain bands offered in the UI (reference presets).
const List<(String, String)> kNlgBands = [
  ('slow_wave', 'Slow waves (F0 1 Hz, B 1.5 Hz)'),
  ('sigma', 'Sigma / spindles (F0 14 Hz, B 3.5 Hz)'),
  ('alpha', 'Alpha (F0 10 Hz, B 3.5 Hz)'),
];

/// Smoother rates: the NeuroLoopGain default and the rate used by the
/// NIMHANS ACCS batch scripts.
const List<(double, String)> kNlgSmoothRates = [
  (0.01666, '0.01666 /s (NeuroLoopGain default)'),
  (0.01, '0.01 /s (ACCS / Polyman batch scripts)'),
];

class AnalyseNidraOptions {
  AnalyseNidraOptions({
    Set<String>? analyses,
    List<String>? nlgBands,
    this.nlgSmoothRate = 0.01666,
  }) : analyses = analyses ?? kAnalyseNidraAnalyses.map((a) => a.$1).toSet(),
       nlgBands = nlgBands ?? ['slow_wave', 'sigma'];

  final Set<String> analyses;
  final List<String> nlgBands;
  final double nlgSmoothRate;

  bool get runsNlg => analyses.contains('nlg') && nlgBands.isNotEmpty;

  AnalyseNidraOptions copyWith({
    Set<String>? analyses,
    List<String>? nlgBands,
    double? nlgSmoothRate,
  }) => AnalyseNidraOptions(
    analyses: analyses ?? Set.of(this.analyses),
    nlgBands: nlgBands ?? List.of(this.nlgBands),
    nlgSmoothRate: nlgSmoothRate ?? this.nlgSmoothRate,
  );

  /// Command-line arguments for `analyse-nidra`.
  List<String> toArgs({String? nlgOutPath}) {
    final ordered = [
      for (final a in kAnalyseNidraAnalyses)
        if (analyses.contains(a.$1) && (a.$1 != 'nlg' || nlgBands.isNotEmpty))
          a.$1,
    ];
    final args = <String>['--analyses', ordered.isEmpty ? 'core' : ordered.join(',')];
    if (runsNlg) {
      args.addAll(['--nlg-bands', nlgBands.join(',')]);
      args.addAll(['--nlg-smooth-rate', nlgSmoothRate.toString()]);
      if (nlgOutPath != null) args.addAll(['--nlg-out', nlgOutPath]);
    }
    return args;
  }

  Map<String, dynamic> toJson() => {
    'analyses': analyses.toList(),
    'nlg_bands': nlgBands,
    'nlg_smooth_rate': nlgSmoothRate,
  };

  static AnalyseNidraOptions fromJson(Map<String, dynamic> json) {
    final a = (json['analyses'] as List?)?.map((e) => e.toString()).toSet();
    final b = (json['nlg_bands'] as List?)?.map((e) => e.toString()).toList();
    final r = (json['nlg_smooth_rate'] as num?)?.toDouble();
    return AnalyseNidraOptions(
      analyses: a,
      nlgBands: b,
      nlgSmoothRate: r ?? 0.01666,
    );
  }

  String get summary {
    final names = [
      for (final a in kAnalyseNidraAnalyses)
        if (analyses.contains(a.$1)) a.$2,
    ];
    return names.isEmpty ? 'No analyses selected' : names.join(', ');
  }
}

/// Check-box panel used by the interactive AnalyseNidra dialog and the batch
/// panel to choose which analyses to run.
class AnalyseNidraOptionsPanel extends StatelessWidget {
  const AnalyseNidraOptionsPanel({
    super.key,
    required this.options,
    required this.onChanged,
    this.dense = false,
  });

  final AnalyseNidraOptions options;
  final ValueChanged<AnalyseNidraOptions> onChanged;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final nlgOn = options.analyses.contains('nlg');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Analyses to run',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
              TextButton(
                onPressed: () => onChanged(
                  options.copyWith(
                    analyses: kAnalyseNidraAnalyses.map((a) => a.$1).toSet(),
                  ),
                ),
                child: const Text('All', style: TextStyle(fontSize: 12)),
              ),
              TextButton(
                onPressed: () => onChanged(options.copyWith(analyses: <String>{})),
                child: const Text('None', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          Wrap(
            spacing: 4,
            runSpacing: 0,
            children: [
              for (final a in kAnalyseNidraAnalyses)
                SizedBox(
                  width: dense ? 250 : 290,
                  child: Tooltip(
                    message: a.$3,
                    child: CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      visualDensity: VisualDensity.compact,
                      title: Text(a.$2, style: const TextStyle(fontSize: 12.5)),
                      value: options.analyses.contains(a.$1),
                      onChanged: (v) {
                        final next = Set.of(options.analyses);
                        if (v ?? false) {
                          next.add(a.$1);
                        } else {
                          next.remove(a.$1);
                        }
                        onChanged(options.copyWith(analyses: next));
                      },
                    ),
                  ),
                ),
            ],
          ),
          if (nlgOn) ...[
            const Divider(height: 12),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 4,
              children: [
                const Text('NeuroLoopGain bands:', style: TextStyle(fontSize: 12)),
                for (final b in kNlgBands)
                  FilterChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(b.$1 == 'slow_wave' ? 'Slow wave' : b.$1 == 'sigma' ? 'Sigma' : 'Alpha',
                        style: const TextStyle(fontSize: 11.5)),
                    tooltip: b.$2,
                    selected: options.nlgBands.contains(b.$1),
                    onSelected: (v) {
                      final next = [
                        for (final x in kNlgBands)
                          if (x.$1 == b.$1 ? v : options.nlgBands.contains(x.$1)) x.$1,
                      ];
                      onChanged(options.copyWith(nlgBands: next));
                    },
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Text('Smoother rate:', style: TextStyle(fontSize: 12)),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButton<double>(
                    isExpanded: true,
                    isDense: true,
                    value: kNlgSmoothRates.any((r) => r.$1 == options.nlgSmoothRate)
                        ? options.nlgSmoothRate
                        : kNlgSmoothRates.first.$1,
                    style: const TextStyle(fontSize: 12, color: Colors.black87),
                    items: [
                      for (final r in kNlgSmoothRates)
                        DropdownMenuItem(
                          value: r.$1,
                          child: Text(r.$2, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) {
                      if (v != null) onChanged(options.copyWith(nlgSmoothRate: v));
                    },
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ─── NeuroLoopGain results ───────────────────────────────────────────────

/// Per-epoch NeuroLoopGain curves used for the hypnogram overlay.
class NlgOverlayData {
  NlgOverlayData({
    required this.source,
    required this.channels,
    required this.epochGain,
    required this.report,
  });

  final String source;
  final List<String> channels;

  /// band name -> per-epoch gain (%) averaged over channels (null = rejected).
  final Map<String, List<double?>> epochGain;
  final Map<String, dynamic> report;

  bool get isEmpty => epochGain.values.every((v) => v.every((x) => x == null));

  static NlgOverlayData? fromReport(Map<String, dynamic> report, String source) {
    final channels = report['channels'];
    if (channels is! Map || channels.isEmpty) return null;
    final bands = <String, List<List<double?>>>{};
    for (final ch in channels.values) {
      if (ch is! Map) continue;
      for (final entry in ch.entries) {
        final band = entry.key.toString();
        final r = entry.value;
        if (r is! Map) continue;
        final eg = (r['epoch_gain'] as List?)
                ?.map((v) => v == null ? null : (v as num).toDouble())
                .toList() ??
            const <double?>[];
        bands.putIfAbsent(band, () => []).add(eg);
      }
    }
    final averaged = <String, List<double?>>{};
    bands.forEach((band, series) {
      final n = series.fold<int>(0, (m, s) => s.length > m ? s.length : m);
      averaged[band] = List<double?>.generate(n, (i) {
        var sum = 0.0;
        var k = 0;
        for (final s in series) {
          if (i < s.length && s[i] != null) {
            sum += s[i]!;
            k++;
          }
        }
        return k == 0 ? null : sum / k;
      });
    });
    return NlgOverlayData(
      source: source,
      channels: channels.keys.map((e) => e.toString()).toList(),
      epochGain: averaged,
      report: report,
    );
  }
}

String nlgSidecarPath(String recordingPath, {String? outputDir}) {
  final sep = Platform.pathSeparator;
  final name = recordingPath.split(RegExp(r'[\\/]')).last;
  final stem = name.replaceAll(RegExp(r'\.[^.]+$'), '');
  final dir = (outputDir != null && outputDir.trim().isNotEmpty)
      ? outputDir.trim()
      : File(recordingPath).parent.path;
  return '$dir$sep${stem}_analyse_nlg.json';
}

Future<NlgOverlayData?> loadNlgOverlay(String recordingPath, {String? outputDir}) async {
  final path = nlgSidecarPath(recordingPath, outputDir: outputDir);
  final file = File(path);
  if (!await file.exists()) return null;
  try {
    final json = jsonDecode(await file.readAsString());
    if (json is! Map<String, dynamic>) return null;
    return NlgOverlayData.fromReport(json, path);
  } catch (_) {
    return null;
  }
}

/// Display name of a NeuroLoopGain band.
String nlgBandLabel(String band) => switch (band) {
  'slow_wave' => 'Slow-wave gain',
  'sigma' => 'Sigma gain',
  'alpha' => 'Alpha gain',
  _ => '$band gain',
};

/// Plain colour per band (shared by overlay and PDF).
Color nlgBandColor(String band) => switch (band) {
  'slow_wave' => const Color(0xFF0B6E4F),
  'sigma' => const Color(0xFFD9822B),
  'alpha' => const Color(0xFF7B4FB3),
  _ => const Color(0xFF555555),
};
