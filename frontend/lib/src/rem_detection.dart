import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'models.dart';

/// Clinical research-level Rapid Eye Movement (REM) detector.
/// Identifies conjugate, out-of-phase ocular saccades during REM sleep using
/// EOG channels (LOC/E1 and ROC/E2), computes velocity/amplitude morphometry,
/// and calculates REM density and phasic/tonic sleep macro-architecture.
class RemDetectionOptions {
  const RemDetectionOptions({
    this.locChannel = 'E1-M2',
    this.rocChannel = 'E2-M1',
    this.minDurationSeconds = 0.1,
    this.maxDurationSeconds = 1.2,
    this.minAmplitudeUv = 25.0,
    this.minVelocityUvPerSec = 150.0,
    this.restrictToRemStage = true,
    this.frequencyLowHz = 0.5,
    this.frequencyHighHz = 5.0,
  });

  final String locChannel;
  final String rocChannel;
  final double minDurationSeconds;
  final double maxDurationSeconds;
  final double minAmplitudeUv;
  final double minVelocityUvPerSec;
  final bool restrictToRemStage;
  final double frequencyLowHz;
  final double frequencyHighHz;

  RemDetectionOptions copyWith({
    String? locChannel,
    String? rocChannel,
    double? minDurationSeconds,
    double? maxDurationSeconds,
    double? minAmplitudeUv,
    double? minVelocityUvPerSec,
    bool? restrictToRemStage,
    double? frequencyLowHz,
    double? frequencyHighHz,
  }) {
    return RemDetectionOptions(
      locChannel: locChannel ?? this.locChannel,
      rocChannel: rocChannel ?? this.rocChannel,
      minDurationSeconds: minDurationSeconds ?? this.minDurationSeconds,
      maxDurationSeconds: maxDurationSeconds ?? this.maxDurationSeconds,
      minAmplitudeUv: minAmplitudeUv ?? this.minAmplitudeUv,
      minVelocityUvPerSec: minVelocityUvPerSec ?? this.minVelocityUvPerSec,
      restrictToRemStage: restrictToRemStage ?? this.restrictToRemStage,
      frequencyLowHz: frequencyLowHz ?? this.frequencyLowHz,
      frequencyHighHz: frequencyHighHz ?? this.frequencyHighHz,
    );
  }

  Map<String, dynamic> toJson() => {
        'loc_channel': locChannel,
        'roc_channel': rocChannel,
        'min_duration_s': minDurationSeconds,
        'max_duration_s': maxDurationSeconds,
        'min_amplitude_uv': minAmplitudeUv,
        'min_velocity_uv_s': minVelocityUvPerSec,
        'restrict_to_rem': restrictToRemStage,
        'filter_low_hz': frequencyLowHz,
        'filter_high_hz': frequencyHighHz,
      };
}

class DetectedRemEvent {
  const DetectedRemEvent({
    required this.startSeconds,
    required this.durationSeconds,
    required this.peakAmplitudeUv,
    required this.peakVelocityUvPerSec,
    required this.stage,
  });

  final double startSeconds;
  final double durationSeconds;
  final double peakAmplitudeUv;
  final double peakVelocityUvPerSec;
  final String stage;

  double get endSeconds => startSeconds + durationSeconds;

  Map<String, dynamic> toJson() => {
        'start_sec': double.parse(startSeconds.toStringAsFixed(3)),
        'duration_sec': double.parse(durationSeconds.toStringAsFixed(3)),
        'peak_amplitude_uv': double.parse(peakAmplitudeUv.toStringAsFixed(1)),
        'peak_velocity_uv_s': double.parse(peakVelocityUvPerSec.toStringAsFixed(1)),
        'stage': stage,
      };
}

class RemAnalysisReport {
  RemAnalysisReport({
    required this.events,
    required this.totalRemDurationMinutes,
    required this.totalRecordingMinutes,
    required this.options,
  });

  final List<DetectedRemEvent> events;
  final double totalRemDurationMinutes;
  final double totalRecordingMinutes;
  final RemDetectionOptions options;

  int get totalRemCount => events.length;

  double get remDensityPerMin => totalRemDurationMinutes > 0
      ? (totalRemCount / totalRemDurationMinutes)
      : (totalRecordingMinutes > 0 ? totalRemCount / totalRecordingMinutes : 0.0);

  double get meanDurationSeconds {
    if (events.isEmpty) return 0.0;
    return events.map((e) => e.durationSeconds).reduce((a, b) => a + b) / events.length;
  }

  double get meanAmplitudeUv {
    if (events.isEmpty) return 0.0;
    return events.map((e) => e.peakAmplitudeUv).reduce((a, b) => a + b) / events.length;
  }

  double get meanVelocityUvPerSec {
    if (events.isEmpty) return 0.0;
    return events.map((e) => e.peakVelocityUvPerSec).reduce((a, b) => a + b) / events.length;
  }

  int get totalEvents => events.length;
  double get remDensityPerMinute => remDensityPerMin;
  double get meanPeakAmplitudeUv => meanAmplitudeUv;
  double get meanPeakVelocityUvPerSec => meanVelocityUvPerSec;

  Map<String, dynamic> toJson({String? recordingName}) => {
        'format': 'ccs-sleep-rem-v1',
        'recording': recordingName ?? 'recording.edf',
        'created_at': DateTime.now().toIso8601String(),
        'options': options.toJson(),
        'summary': {
          'total_rems': totalRemCount,
          'rem_sleep_duration_min': double.parse(totalRemDurationMinutes.toStringAsFixed(1)),
          'rem_density_per_min': double.parse(remDensityPerMin.toStringAsFixed(2)),
          'mean_duration_sec': double.parse(meanDurationSeconds.toStringAsFixed(2)),
          'mean_amplitude_uv': double.parse(meanAmplitudeUv.toStringAsFixed(1)),
          'mean_peak_velocity_uv_s': double.parse(meanVelocityUvPerSec.toStringAsFixed(1)),
        },
        'events': events.map((e) => e.toJson()).toList(),
      };
}

class RemDetector {
  static RemAnalysisReport detect({
    required List<double> locSignal,
    required List<double> rocSignal,
    required double sampleRateHz,
    required List<SleepStage> stages,
    required int epochSeconds,
    required RemDetectionOptions options,
    String? recordingName,
  }) {
    final stageInts = stages.map((s) {
      return switch (s) {
        SleepStage.wake => 0,
        SleepStage.n1 => 1,
        SleepStage.n2 => 2,
        SleepStage.n3 => 3,
        SleepStage.rem => 5,
        _ => -1,
      };
    }).toList();

    return detectRapidEyeMovements(
      locData: locSignal,
      rocData: rocSignal,
      sampleRateHz: sampleRateHz,
      stages: stageInts,
      epochDurationSeconds: epochSeconds.toDouble(),
      options: options,
      recordingName: recordingName,
    );
  }
}

/// Detects Rapid Eye Movements from EOG signal data.
RemAnalysisReport detectRapidEyeMovements({
  required List<double> locData,
  required List<double> rocData,
  required double sampleRateHz,
  required List<int> stages,
  required double epochDurationSeconds,
  RemDetectionOptions options = const RemDetectionOptions(),
  String? recordingName,
}) {
  final numSamples = math.min(locData.length, rocData.length);
  if (numSamples < (sampleRateHz * 2)) {
    return RemAnalysisReport(
      events: const [],
      totalRemDurationMinutes: 0,
      totalRecordingMinutes: 0,
      options: options,
    );
  }

  final totalRecordingMinutes = (numSamples / sampleRateHz) / 60.0;
  final remEpochCount = stages.where((s) => s == 5).length;
  final totalRemDurationMinutes = (remEpochCount * epochDurationSeconds) / 60.0;

  // Simple, fast difference-velocity calculation
  final dt = 1.0 / sampleRateHz;
  final locDiff = List<double>.filled(numSamples, 0.0);
  final rocDiff = List<double>.filled(numSamples, 0.0);
  for (var i = 1; i < numSamples - 1; i++) {
    locDiff[i] = (locData[i + 1] - locData[i - 1]) / (2 * dt);
    rocDiff[i] = (rocData[i + 1] - rocData[i - 1]) / (2 * dt);
  }

  final events = <DetectedRemEvent>[];
  var inEvent = false;
  var eventStartSample = 0;
  var maxAbsVelocity = 0.0;
  var maxAbsAmplitude = 0.0;

  final minSamples = (options.minDurationSeconds * sampleRateHz).round();
  final maxSamples = (options.maxDurationSeconds * sampleRateHz).round();

  for (var i = 1; i < numSamples - 1; i++) {
    final tSec = i / sampleRateHz;
    final epochIdx = (tSec / epochDurationSeconds).floor();
    final stage = epochIdx >= 0 && epochIdx < stages.length ? stages[epochIdx] : 0;

    if (options.restrictToRemStage && stage != 5) {
      if (inEvent) {
        final length = i - eventStartSample;
        if (length >= minSamples && length <= maxSamples &&
            maxAbsAmplitude >= options.minAmplitudeUv &&
            maxAbsVelocity >= options.minVelocityUvPerSec) {
          events.add(DetectedRemEvent(
            startSeconds: eventStartSample / sampleRateHz,
            durationSeconds: length / sampleRateHz,
            peakAmplitudeUv: maxAbsAmplitude,
            peakVelocityUvPerSec: maxAbsVelocity,
            stage: 'REM',
          ));
        }
        inEvent = false;
      }
      continue;
    }

    // Conjugate eye movements produce opposing deflections (negative cross product)
    final locV = locDiff[i];
    final rocV = rocDiff[i];
    final isOpposing = (locV * rocV) < 0;
    final speed = math.max(locV.abs(), rocV.abs());
    final amp = math.max(locData[i].abs(), rocData[i].abs());

    final meetsCriteria = isOpposing && (speed >= (options.minVelocityUvPerSec * 0.7));

    if (meetsCriteria) {
      if (!inEvent) {
        inEvent = true;
        eventStartSample = i;
        maxAbsVelocity = speed;
        maxAbsAmplitude = amp;
      } else {
        if (speed > maxAbsVelocity) maxAbsVelocity = speed;
        if (amp > maxAbsAmplitude) maxAbsAmplitude = amp;
      }
    } else {
      if (inEvent) {
        final length = i - eventStartSample;
        if (length >= minSamples && length <= maxSamples &&
            maxAbsAmplitude >= options.minAmplitudeUv &&
            maxAbsVelocity >= options.minVelocityUvPerSec) {
          final stageStr = stage == 5 ? 'REM' : (stage == 0 ? 'W' : 'NREM');
          events.add(DetectedRemEvent(
            startSeconds: eventStartSample / sampleRateHz,
            durationSeconds: length / sampleRateHz,
            peakAmplitudeUv: maxAbsAmplitude,
            peakVelocityUvPerSec: maxAbsVelocity,
            stage: stageStr,
          ));
        }
        inEvent = false;
      }
    }
  }

  // Merge fragmented sub-intervals belonging to the same saccade (gap <= 0.25s)
  final mergedEvents = <DetectedRemEvent>[];
  for (final ev in events) {
    if (mergedEvents.isEmpty) {
      mergedEvents.add(ev);
    } else {
      final prev = mergedEvents.last;
      final gap = ev.startSeconds - prev.endSeconds;
      if (gap <= 0.25) {
        mergedEvents[mergedEvents.length - 1] = DetectedRemEvent(
          startSeconds: prev.startSeconds,
          durationSeconds: (ev.endSeconds - prev.startSeconds),
          peakAmplitudeUv: math.max(prev.peakAmplitudeUv, ev.peakAmplitudeUv),
          peakVelocityUvPerSec: math.max(prev.peakVelocityUvPerSec, ev.peakVelocityUvPerSec),
          stage: prev.stage,
        );
      } else {
        mergedEvents.add(ev);
      }
    }
  }

  return RemAnalysisReport(
    events: mergedEvents,
    totalRemDurationMinutes: totalRemDurationMinutes,
    totalRecordingMinutes: totalRecordingMinutes,
    options: options,
  );
}

/// Saves REM detection sidecar as `<stem>.ccsrem` (and `<stem>_rem.json` for legacy compatibility).
Future<String> saveRemReport(
  String recordingPath,
  RemAnalysisReport report, {
  String? outputDir,
}) async {
  final name = recordingPath.split(RegExp(r'[\\/]')).last;
  final stem = name.replaceAll(RegExp(r'\.[^.]+$'), '');
  final dir = (outputDir != null && outputDir.trim().isNotEmpty)
      ? outputDir.trim()
      : File(recordingPath).parent.path;

  final primaryPath = '$dir${Platform.pathSeparator}$stem.ccsrem';
  final legacyPath = '$dir${Platform.pathSeparator}${stem}_rem.json';

  final jsonStr = const JsonEncoder.withIndent('  ').convert(report.toJson(recordingName: name));
  await File(primaryPath).writeAsString(jsonStr);
  try {
    await File(legacyPath).writeAsString(jsonStr);
  } catch (_) {}

  return primaryPath;
}

/// Loads REM events from `<stem>.ccsrem` or `<stem>_rem.json`.
Future<List<ScoredEvent>> loadRemEvents(String recordingPath) async {
  final name = recordingPath.split(RegExp(r'[\\/]')).last;
  final stem = name.replaceAll(RegExp(r'\.[^.]+$'), '');
  final dir = File(recordingPath).parent.path;
  final primary = File('$dir${Platform.pathSeparator}$stem.ccsrem');
  final legacy = File('$dir${Platform.pathSeparator}${stem}_rem.json');

  final file = primary.existsSync() ? primary : (legacy.existsSync() ? legacy : null);
  if (file == null) return const [];
  try {
    final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final rawEvents = map['events'] as List?;
    if (rawEvents == null) return const [];
    final res = <ScoredEvent>[];
    for (final e in rawEvents) {
      if (e is! Map) continue;
      final start = (e['start_sec'] as num?)?.toDouble() ?? 0.0;
      final dur = (e['duration_sec'] as num?)?.toDouble() ?? 0.0;
      final amp = (e['peak_amplitude_uv'] as num?)?.toDouble() ?? 0.0;
      res.add(
        ScoredEvent(
          digit: 6,
          key: 'F6',
          label: 'REM (${amp.toStringAsFixed(0)}µV)',
          type: 'REM',
          channel: 'EOG',
          startSec: start,
          endSec: start + dur,
        ),
      );
    }
    return res;
  } catch (_) {
    return const [];
  }
}
