// lib/src/cardiac_analysis.dart
//
// Automated AASM-based Cardiac Event Analysis for ECG.
// Rules implemented from AASM Scoring Manual (Section VIII: Cardiac Rules):
//   1. Asystole: Cardiac pause (R-R interval) >= 3.0 seconds in adults.
//   2. Sinus Bradycardia: Sustained heart rate < 40 bpm for >= 30 seconds during sleep.
//   3. Sinus Tachycardia: Sustained heart rate > 90 bpm (configurable to 100) for >= 30 seconds during sleep.
//
// Also computes stage-specific heart rate distributions (Wake, N1, N2, N3, REM).

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'models.dart';

class CardiacEventResult {
  const CardiacEventResult({
    required this.totalBeats,
    required this.overallMeanHr,
    required this.minHr,
    required this.maxHr,
    required this.stageMeanHr,
    required this.asystoleEvents,
    required this.bradycardiaEvents,
    required this.tachycardiaEvents,
    this.pvcEvents = const [],
    this.pacEvents = const [],
    this.arrhythmiaEvents = const [],
    required this.longestPauseSec,
  });

  final int totalBeats;
  final double overallMeanHr;
  final double minHr;
  final double maxHr;
  final Map<SleepStage, double> stageMeanHr;
  final List<ScoredEvent> asystoleEvents;
  final List<ScoredEvent> bradycardiaEvents;
  final List<ScoredEvent> tachycardiaEvents;
  final List<ScoredEvent> pvcEvents;
  final List<ScoredEvent> pacEvents;
  final List<ScoredEvent> arrhythmiaEvents;
  final double longestPauseSec;

  int get totalCardiacEvents =>
      asystoleEvents.length +
      bradycardiaEvents.length +
      tachycardiaEvents.length +
      pvcEvents.length +
      pacEvents.length +
      arrhythmiaEvents.length;

  List<ScoredEvent> get allEvents => [
        ...asystoleEvents,
        ...bradycardiaEvents,
        ...tachycardiaEvents,
        ...pvcEvents,
        ...pacEvents,
        ...arrhythmiaEvents,
      ];
}

class AasmCardiacAnalyzer {
  /// Detects R-peaks on an ECG signal using a Pan-Tompkins QRS energy detector.
  static List<int> detectRPeaks(List<double> signal, double sampleRate) {
    if (signal.length < 100 || sampleRate <= 0) return const [];

    // 1. Bandpass filter 5–30 Hz via 2nd-order difference
    final filtered = List<double>.filled(signal.length, 0.0);
    final dt = 1.0 / sampleRate;
    final rcLo = 1.0 / (2 * math.pi * 30.0);
    final alphaLo = dt / (rcLo + dt);
    final rcHi = 1.0 / (2 * math.pi * 5.0);
    final alphaHi = rcHi / (rcHi + dt);

    var low = 0.0;
    var high = 0.0;
    for (var i = 0; i < signal.length; i++) {
      low += alphaLo * (signal[i] - low);
      high = alphaHi * (high + low - (i > 0 ? signal[i - 1] : signal[0]));
      filtered[i] = high;
    }

    // 2. Derivative & Squaring
    final energy = List<double>.filled(signal.length, 0.0);
    for (var i = 2; i < signal.length - 2; i++) {
      final d = (-filtered[i - 2] - 2 * filtered[i - 1] + 2 * filtered[i + 1] + filtered[i + 2]) / 8.0;
      energy[i] = d * d;
    }

    // 3. Moving-window integration (~150 ms)
    final winLen = math.max(1, (0.15 * sampleRate).round());
    final integrated = List<double>.filled(signal.length, 0.0);
    var sum = 0.0;
    for (var i = 0; i < winLen && i < energy.length; i++) {
      sum += energy[i];
    }
    for (var i = 0; i < signal.length; i++) {
      if (i >= winLen) {
        sum += energy[i] - energy[i - winLen];
      }
      integrated[i] = sum / winLen;
    }

    // 4. Adaptive thresholding & refractory peak lockout (min 300 ms = max 200 bpm)
    var meanVal = 0.0;
    for (var i = 0; i < integrated.length; i += 16) {
      meanVal += integrated[i];
    }
    meanVal /= (integrated.length / 16).ceil();

    final thresh = meanVal * 1.5;
    final refractorySamples = (0.30 * sampleRate).round();
    final peaks = <int>[];
    var lastPeak = -refractorySamples;

    for (var i = 2; i < integrated.length - 2; i++) {
      if (integrated[i] > thresh &&
          integrated[i] >= integrated[i - 1] &&
          integrated[i] >= integrated[i - 2] &&
          integrated[i] >= integrated[i + 1] &&
          integrated[i] >= integrated[i + 2]) {
        if (i - lastPeak >= refractorySamples) {
          // Snap to actual raw ECG peak within +/- 50 ms
          final searchRadius = (0.05 * sampleRate).round();
          final s1 = math.max(0, i - searchRadius);
          final s2 = math.min(signal.length - 1, i + searchRadius);
          var bestIdx = i;
          var bestAmp = signal[i].abs();
          for (var j = s1; j <= s2; j++) {
            if (signal[j].abs() > bestAmp) {
              bestAmp = signal[j].abs();
              bestIdx = j;
            }
          }
          peaks.add(bestIdx);
          lastPeak = i;
        }
      }
    }

    return peaks;
  }

  /// Estimates QRS complex duration in milliseconds around an R-peak index.
  static double estimateQrsDurationMs(
    List<double> signal,
    int peakIdx,
    double sampleRate,
  ) {
    if (peakIdx < 0 || peakIdx >= signal.length) return 80.0;
    final peakVal = signal[peakIdx];
    final threshold = peakVal.abs() * 0.25;

    // Search left for Q onset
    final maxLookback = (0.12 * sampleRate).round();
    var leftIdx = peakIdx;
    for (var j = 1; j <= maxLookback && (peakIdx - j) >= 0; j++) {
      if (signal[peakIdx - j].abs() <= threshold) {
        leftIdx = peakIdx - j;
        break;
      }
      leftIdx = peakIdx - j;
    }

    // Search right for S offset
    final maxLookahead = (0.15 * sampleRate).round();
    var rightIdx = peakIdx;
    for (var j = 1; j <= maxLookahead && (peakIdx + j) < signal.length; j++) {
      if (signal[peakIdx + j].abs() <= threshold) {
        rightIdx = peakIdx + j;
        break;
      }
      rightIdx = peakIdx + j;
    }

    final durationSec = (rightIdx - leftIdx) / sampleRate;
    return durationSec * 1000.0;
  }

  /// Analyzes ECG according to AASM Cardiac and Arrhythmia Rules.
  static CardiacEventResult analyze({
    required List<double> ecgSamples,
    required double sampleRate,
    List<SleepStage>? stages,
    int epochSeconds = 30,
    double asystoleThresholdSec = 3.0,
    double bradycardiaThresholdBpm = 40.0,
    double tachycardiaThresholdBpm = 90.0,
    bool includeArrhythmias = true,
    String? channelName,
  }) {
    final rPeaks = detectRPeaks(ecgSamples, sampleRate);
    if (rPeaks.length < 2) {
      return const CardiacEventResult(
        totalBeats: 0,
        overallMeanHr: 0.0,
        minHr: 0.0,
        maxHr: 0.0,
        stageMeanHr: {},
        asystoleEvents: [],
        bradycardiaEvents: [],
        tachycardiaEvents: [],
        pvcEvents: [],
        pacEvents: [],
        arrhythmiaEvents: [],
        longestPauseSec: 0.0,
      );
    }

    // 1. Calculate R-R intervals and HR series
    final rrSec = <double>[];
    final rrTimes = <double>[];
    var longestPause = 0.0;

    for (var i = 1; i < rPeaks.length; i++) {
      final t1 = rPeaks[i - 1] / sampleRate;
      final t2 = rPeaks[i] / sampleRate;
      final dt = t2 - t1;
      rrSec.add(dt);
      rrTimes.add((t1 + t2) / 2.0);
      if (dt > longestPause) longestPause = dt;
    }

    // 2. Identify Asystole (R-R interval >= 3.0 s)
    final asystoles = <ScoredEvent>[];
    for (var i = 0; i < rrSec.length; i++) {
      if (rrSec[i] >= asystoleThresholdSec) {
        final start = rPeaks[i] / sampleRate;
        final dur = rrSec[i];
        asystoles.add(
          ScoredEvent(
            digit: 0,
            key: 'A',
            label: 'Asystole (${dur.toStringAsFixed(1)}s)',
            startSec: start,
            endSec: start + dur,
            channel: channelName,
          ),
        );
      }
    }

    // 3. Smooth HR into 30-second windows for Sinus Bradycardia & Tachycardia
    final bradycardias = <ScoredEvent>[];
    final tachycardias = <ScoredEvent>[];
    const sustainedWinSec = 30.0;
    final totalDuration = ecgSamples.length / sampleRate;

    var curBradyStart = -1.0;
    var curTachyStart = -1.0;

    for (var t = 0.0; t <= totalDuration - sustainedWinSec; t += 5.0) {
      final tEnd = t + sustainedWinSec;
      final beatsInWin = <double>[];
      for (var i = 0; i < rrTimes.length; i++) {
        if (rrTimes[i] >= t && rrTimes[i] <= tEnd) {
          final hr = 60.0 / rrSec[i];
          if (hr >= 20.0 && hr <= 220.0) beatsInWin.add(hr);
        }
      }

      if (beatsInWin.isNotEmpty) {
        final avgHr = beatsInWin.reduce((a, b) => a + b) / beatsInWin.length;

        // Bradycardia check (< 40 bpm)
        if (avgHr < bradycardiaThresholdBpm) {
          if (curBradyStart < 0) curBradyStart = t;
        } else {
          if (curBradyStart >= 0) {
            final dur = t - curBradyStart + sustainedWinSec;
            if (dur >= 30.0) {
              bradycardias.add(
                ScoredEvent(
                  digit: 0,
                  key: 'A',
                  label: 'Bradycardia (<${bradycardiaThresholdBpm.round()} bpm)',
                  startSec: curBradyStart,
                  endSec: curBradyStart + dur,
                  channel: channelName,
                ),
              );
            }
            curBradyStart = -1.0;
          }
        }

        // Tachycardia check (> 90 bpm)
        if (avgHr > tachycardiaThresholdBpm) {
          if (curTachyStart < 0) curTachyStart = t;
        } else {
          if (curTachyStart >= 0) {
            final dur = t - curTachyStart + sustainedWinSec;
            if (dur >= 30.0) {
              tachycardias.add(
                ScoredEvent(
                  digit: 0,
                  key: 'A',
                  label: 'Tachycardia (>${tachycardiaThresholdBpm.round()} bpm)',
                  startSec: curTachyStart,
                  endSec: curTachyStart + dur,
                  channel: channelName,
                ),
              );
            }
            curTachyStart = -1.0;
          }
        }
      }
    }

    // Close any trailing sustained episode
    if (curBradyStart >= 0 && totalDuration - curBradyStart >= 30.0) {
      bradycardias.add(
        ScoredEvent(
          digit: 0,
          key: 'A',
          label: 'Bradycardia (<${bradycardiaThresholdBpm.round()} bpm)',
          startSec: curBradyStart,
          endSec: totalDuration,
          channel: channelName,
        ),
      );
    }
    if (curTachyStart >= 0 && totalDuration - curTachyStart >= 30.0) {
      tachycardias.add(
        ScoredEvent(
          digit: 0,
          key: 'A',
          label: 'Tachycardia (>${tachycardiaThresholdBpm.round()} bpm)',
          startSec: curTachyStart,
          endSec: totalDuration,
          channel: channelName,
        ),
      );
    }

    // 4. Arrhythmia & Ectopic Beat Detection (PVC, PAC, Couplets, Bigeminy, Trigeminy, VT/SVT, AFib)
    final pvcs = <ScoredEvent>[];
    final pacs = <ScoredEvent>[];
    final arrhythmias = <ScoredEvent>[];

    if (includeArrhythmias && rPeaks.length >= 4) {
      // Beat classification: 0 = Normal, 1 = PVC (Ventricular ectopic), 2 = PAC (Supraventricular ectopic)
      final beatTypes = List<int>.filled(rPeaks.length, 0);

      for (var i = 1; i < rPeaks.length - 1; i++) {
        final rrPrev = (rPeaks[i] - rPeaks[i - 1]) / sampleRate;
        final rrNext = (rPeaks[i + 1] - rPeaks[i]) / sampleRate;

        // Local median RR from up to +/- 5 neighboring beats
        final localRrs = <double>[];
        for (var j = math.max(0, i - 5); j <= math.min(rrSec.length - 1, i + 5); j++) {
          if (rrSec[j] >= 0.25 && rrSec[j] <= 2.5) {
            localRrs.add(rrSec[j]);
          }
        }
        if (localRrs.length < 3) continue;
        localRrs.sort();
        final localMedian = localRrs[localRrs.length ~/ 2];
        if (localMedian <= 0.2) continue;

        final isPremature = rrPrev < (0.82 * localMedian);
        final isCompensatory = (rrPrev + rrNext) >= (1.85 * localMedian);
        final qrsDurationMs = estimateQrsDurationMs(ecgSamples, rPeaks[i], sampleRate);
        final isWide = qrsDurationMs >= 110.0;

        if (isPremature) {
          if (isWide || isCompensatory) {
            beatTypes[i] = 1; // PVC
          } else {
            beatTypes[i] = 2; // PAC
          }
        }
      }

      final isPartOfGroup = List<bool>.filled(rPeaks.length, false);

      // Runs of PVCs (Couplets & Ventricular Tachycardia / NSVT)
      var pRunStart = -1;
      for (var i = 0; i <= rPeaks.length; i++) {
        if (i < rPeaks.length && beatTypes[i] == 1) {
          if (pRunStart < 0) pRunStart = i;
        } else {
          if (pRunStart >= 0) {
            final runLen = i - pRunStart;
            if (runLen >= 3) {
              final tStart = (rPeaks[pRunStart] / sampleRate) - 0.1;
              final tEnd = (rPeaks[i - 1] / sampleRate) + 0.3;
              arrhythmias.add(
                ScoredEvent(
                  digit: 0,
                  key: 'A',
                  label: 'Ventricular Tachycardia (NSVT, $runLen beats)',
                  startSec: tStart,
                  endSec: tEnd,
                  channel: channelName,
                ),
              );
              for (var k = pRunStart; k < i; k++) isPartOfGroup[k] = true;
            } else if (runLen == 2) {
              final tStart = (rPeaks[pRunStart] / sampleRate) - 0.1;
              final tEnd = (rPeaks[i - 1] / sampleRate) + 0.3;
              arrhythmias.add(
                ScoredEvent(
                  digit: 0,
                  key: 'A',
                  label: 'Ventricular Couplet',
                  startSec: tStart,
                  endSec: tEnd,
                  channel: channelName,
                ),
              );
              for (var k = pRunStart; k < i; k++) isPartOfGroup[k] = true;
            }
            pRunStart = -1;
          }
        }
      }

      // Runs of PACs (Supraventricular Tachycardia / SVT)
      var pacRunStart = -1;
      for (var i = 0; i <= rPeaks.length; i++) {
        if (i < rPeaks.length && beatTypes[i] == 2) {
          if (pacRunStart < 0) pacRunStart = i;
        } else {
          if (pacRunStart >= 0) {
            final runLen = i - pacRunStart;
            if (runLen >= 3) {
              final tStart = (rPeaks[pacRunStart] / sampleRate) - 0.1;
              final tEnd = (rPeaks[i - 1] / sampleRate) + 0.25;
              arrhythmias.add(
                ScoredEvent(
                  digit: 0,
                  key: 'A',
                  label: 'Supraventricular Tachycardia (SVT, $runLen beats)',
                  startSec: tStart,
                  endSec: tEnd,
                  channel: channelName,
                ),
              );
              for (var k = pacRunStart; k < i; k++) isPartOfGroup[k] = true;
            }
            pacRunStart = -1;
          }
        }
      }

      // Bigeminy (alternating Normal-PVC-Normal-PVC for >= 3 cycles, i.e. 6 beats)
      for (var i = 0; i <= rPeaks.length - 6; i++) {
        var isBigeminy = true;
        for (var k = 0; k < 6; k += 2) {
          if (beatTypes[i + k] != 0 || beatTypes[i + k + 1] != 1) {
            isBigeminy = false;
            break;
          }
        }
        if (isBigeminy) {
          var endIdx = i + 6;
          while (endIdx + 1 < rPeaks.length &&
              beatTypes[endIdx] == 0 &&
              beatTypes[endIdx + 1] == 1) {
            endIdx += 2;
          }
          final tStart = (rPeaks[i] / sampleRate) - 0.1;
          final tEnd = (rPeaks[endIdx - 1] / sampleRate) + 0.3;
          arrhythmias.add(
            ScoredEvent(
              digit: 0,
              key: 'A',
              label: 'Ventricular Bigeminy',
              startSec: tStart,
              endSec: tEnd,
              channel: channelName,
            ),
          );
          for (var k = i; k < endIdx; k++) isPartOfGroup[k] = true;
          i = endIdx - 1;
        }
      }

      // Trigeminy (N-N-V-N-N-V for >= 2 cycles, i.e. 6 beats)
      for (var i = 0; i <= rPeaks.length - 6; i++) {
        var isTrigeminy = true;
        for (var k = 0; k < 6; k += 3) {
          if (beatTypes[i + k] != 0 ||
              beatTypes[i + k + 1] != 0 ||
              beatTypes[i + k + 2] != 1) {
            isTrigeminy = false;
            break;
          }
        }
        if (isTrigeminy) {
          var endIdx = i + 6;
          while (endIdx + 2 < rPeaks.length &&
              beatTypes[endIdx] == 0 &&
              beatTypes[endIdx + 1] == 0 &&
              beatTypes[endIdx + 2] == 1) {
            endIdx += 3;
          }
          final tStart = (rPeaks[i] / sampleRate) - 0.1;
          final tEnd = (rPeaks[endIdx - 1] / sampleRate) + 0.3;
          arrhythmias.add(
            ScoredEvent(
              digit: 0,
              key: 'A',
              label: 'Ventricular Trigeminy',
              startSec: tStart,
              endSec: tEnd,
              channel: channelName,
            ),
          );
          for (var k = i; k < endIdx; k++) isPartOfGroup[k] = true;
          i = endIdx - 1;
        }
      }

      // Isolated PVCs and PACs
      for (var i = 0; i < rPeaks.length; i++) {
        final t = rPeaks[i] / sampleRate;
        if (beatTypes[i] == 1) {
          pvcs.add(
            ScoredEvent(
              digit: 0,
              key: 'A',
              label: isPartOfGroup[i] ? 'PVC (Complex)' : 'PVC (Isolated)',
              startSec: t - 0.1,
              endSec: t + 0.2,
              channel: channelName,
            ),
          );
        } else if (beatTypes[i] == 2) {
          pacs.add(
            ScoredEvent(
              digit: 0,
              key: 'A',
              label: isPartOfGroup[i] ? 'PAC (Complex)' : 'PAC (Isolated)',
              startSec: t - 0.1,
              endSec: t + 0.2,
              channel: channelName,
            ),
          );
        }
      }

      // Atrial Fibrillation (AFib) Detection in 30-second windows
      var afibStart = -1.0;
      for (var t = 0.0; t <= totalDuration - sustainedWinSec; t += 15.0) {
        final tEnd = t + sustainedWinSec;
        final windowRrs = <double>[];
        for (var i = 0; i < rrTimes.length; i++) {
          if (rrTimes[i] >= t && rrTimes[i] <= tEnd) {
            if (rrSec[i] >= 0.25 && rrSec[i] <= 2.2) {
              windowRrs.add(rrSec[i]);
            }
          }
        }

        var isAfibWindow = false;
        if (windowRrs.length >= 14) {
          final mean = windowRrs.reduce((a, b) => a + b) / windowRrs.length;
          var varSum = 0.0;
          for (final r in windowRrs) {
            varSum += (r - mean) * (r - mean);
          }
          final sd = math.sqrt(varSum / windowRrs.length);
          final cv = sd / mean;

          var diffSum = 0.0;
          for (var k = 0; k < windowRrs.length - 1; k++) {
            final diff = windowRrs[k + 1] - windowRrs[k];
            diffSum += diff * diff;
          }
          final rmssd = math.sqrt(diffSum / (windowRrs.length - 1));
          final nRmssd = rmssd / mean;

          if (cv >= 0.19 && nRmssd >= 0.16) {
            isAfibWindow = true;
          }
        }

        if (isAfibWindow) {
          if (afibStart < 0) afibStart = t;
        } else {
          if (afibStart >= 0) {
            final dur = t - afibStart + sustainedWinSec;
            if (dur >= 30.0) {
              arrhythmias.add(
                ScoredEvent(
                  digit: 0,
                  key: 'A',
                  label: 'Atrial Fibrillation (AFib)',
                  startSec: afibStart,
                  endSec: afibStart + dur,
                  channel: channelName,
                ),
              );
            }
            afibStart = -1.0;
          }
        }
      }
      if (afibStart >= 0 && totalDuration - afibStart >= 30.0) {
        arrhythmias.add(
          ScoredEvent(
            digit: 0,
            key: 'A',
            label: 'Atrial Fibrillation (AFib)',
            startSec: afibStart,
            endSec: totalDuration,
            channel: channelName,
          ),
        );
      }
    }

    // 5. Compute overall and stage-specific heart rate
    final validHrs = <double>[];
    final stageHrLists = <SleepStage, List<double>>{
      SleepStage.wake: [],
      SleepStage.n1: [],
      SleepStage.n2: [],
      SleepStage.n3: [],
      SleepStage.rem: [],
    };

    for (var i = 0; i < rrSec.length; i++) {
      final dt = rrSec[i];
      if (dt > 0.25 && dt < 3.0) {
        final hr = 60.0 / dt;
        validHrs.add(hr);

        if (stages != null && stages.isNotEmpty) {
          final epIdx = (rrTimes[i] / epochSeconds).floor();
          if (epIdx >= 0 && epIdx < stages.length) {
            final stage = stages[epIdx];
            stageHrLists[stage]?.add(hr);
          }
        }
      }
    }

    final overallMean = validHrs.isNotEmpty
        ? validHrs.reduce((a, b) => a + b) / validHrs.length
        : 0.0;
    final minHr = validHrs.isNotEmpty ? validHrs.reduce(math.min) : 0.0;
    final maxHr = validHrs.isNotEmpty ? validHrs.reduce(math.max) : 0.0;

    final stageMeanHr = <SleepStage, double>{};
    stageHrLists.forEach((st, hrs) {
      if (hrs.isNotEmpty) {
        stageMeanHr[st] = hrs.reduce((a, b) => a + b) / hrs.length;
      }
    });

    return CardiacEventResult(
      totalBeats: rPeaks.length,
      overallMeanHr: overallMean,
      minHr: minHr,
      maxHr: maxHr,
      stageMeanHr: stageMeanHr,
      asystoleEvents: asystoles,
      bradycardiaEvents: bradycardias,
      tachycardiaEvents: tachycardias,
      pvcEvents: pvcs,
      pacEvents: pacs,
      arrhythmiaEvents: arrhythmias,
      longestPauseSec: longestPause,
    );
  }
}

class AasmCardiacDialog extends StatefulWidget {
  const AasmCardiacDialog({
    super.key,
    required this.channelLabels,
    required this.onRunAnalysis,
  });

  final List<String> channelLabels;
  final Future<CardiacEventResult?> Function(
    String ecgChannel,
    double asystoleSec,
    double bradycardiaBpm,
    double tachycardiaBpm, {
    bool includeArrhythmias,
  }) onRunAnalysis;

  @override
  State<AasmCardiacDialog> createState() => _AasmCardiacDialogState();
}

class _AasmCardiacDialogState extends State<AasmCardiacDialog> {
  late String _selectedEcg;
  double _asystoleSec = 3.0;
  double _bradycardiaBpm = 40.0;
  double _tachycardiaBpm = 90.0;
  bool _includeArrhythmias = true;
  bool _isAnalyzing = false;
  CardiacEventResult? _result;

  @override
  void initState() {
    super.initState();
    _selectedEcg = widget.channelLabels.firstWhere(
      (c) =>
          c.toUpperCase().contains('ECG') ||
          c.toUpperCase().contains('EKG') ||
          c.toUpperCase().contains('HEART'),
      orElse: () => widget.channelLabels.isNotEmpty ? widget.channelLabels.first : '',
    );
  }

  Future<void> _run() async {
    setState(() => _isAnalyzing = true);
    try {
      final res = await widget.onRunAnalysis(
        _selectedEcg,
        _asystoleSec,
        _bradycardiaBpm,
        _tachycardiaBpm,
        includeArrhythmias: _includeArrhythmias,
      );
      if (mounted) {
        setState(() {
          _isAnalyzing = false;
          _result = res;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.monitor_heart, color: Colors.redAccent),
          SizedBox(width: 8),
          Text('Automated AASM Cardiac & Arrhythmia Analysis (ECG)'),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
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
                        'AASM Scoring Rules (Section VIII): Identifies Asystole (pause ≥ 3.0s), Sinus Bradycardia (< 40 bpm sustained ≥ 30s), Sinus Tachycardia (> 90 bpm sustained ≥ 30s), and Arrhythmias (PVCs, PACs, Bigeminy, Trigeminy, Couplets, VT/SVT, AFib).',
                        style: TextStyle(fontSize: 11.5, color: Colors.black87),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const Text('ECG Signal Channel:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                value: _selectedEcg.isNotEmpty && widget.channelLabels.contains(_selectedEcg)
                    ? _selectedEcg
                    : null,
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                items: [
                  for (final ch in widget.channelLabels)
                    DropdownMenuItem(value: ch, child: Text(ch)),
                ],
                onChanged: _isAnalyzing ? null : (v) => setState(() => _selectedEcg = v ?? ''),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      initialValue: _asystoleSec.toString(),
                      decoration: const InputDecoration(
                        labelText: 'Asystole Pause (sec)',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (v) {
                        final val = double.tryParse(v);
                        if (val != null && val > 0) _asystoleSec = val;
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      initialValue: _bradycardiaBpm.toStringAsFixed(0),
                      decoration: const InputDecoration(
                        labelText: 'Bradycardia Threshold (bpm)',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                      onChanged: (v) {
                        final val = double.tryParse(v);
                        if (val != null && val > 0) _bradycardiaBpm = val;
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      initialValue: _tachycardiaBpm.toStringAsFixed(0),
                      decoration: const InputDecoration(
                        labelText: 'Tachycardia Threshold (bpm)',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                      onChanged: (v) {
                        final val = double.tryParse(v);
                        if (val != null && val > 0) _tachycardiaBpm = val;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: _includeArrhythmias,
                title: const Text('Include Arrhythmia Analysis (PVC, PAC, Couplets, Bigeminy/Trigeminy, VT/SVT, AFib)', style: TextStyle(fontSize: 12.5)),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                onChanged: _isAnalyzing ? null : (v) => setState(() => _includeArrhythmias = v ?? true),
              ),
              if (_isAnalyzing) ...[
                const SizedBox(height: 20),
                const Center(
                  child: Column(
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 8),
                      Text('Running Pan-Tompkins QRS detection and AASM cardiac analysis…'),
                    ],
                  ),
                ),
              ],
              if (_result != null) ...[
                const SizedBox(height: 16),
                const Divider(),
                const Text('Cardiac Analysis Summary:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 8),
                Table(
                  border: TableBorder.all(color: Colors.grey.shade300),
                  children: [
                    TableRow(children: [
                      const Padding(padding: EdgeInsets.all(6), child: Text('Total Detected Heartbeats', style: TextStyle(fontWeight: FontWeight.bold))),
                      Padding(padding: const EdgeInsets.all(6), child: Text('${_result!.totalBeats}')),
                    ]),
                    TableRow(children: [
                      const Padding(padding: EdgeInsets.all(6), child: Text('Mean Heart Rate (Sleep)', style: TextStyle(fontWeight: FontWeight.bold))),
                      Padding(padding: const EdgeInsets.all(6), child: Text('${_result!.overallMeanHr.toStringAsFixed(1)} bpm (Min: ${_result!.minHr.toStringAsFixed(0)}, Max: ${_result!.maxHr.toStringAsFixed(0)})')),
                    ]),
                    TableRow(children: [
                      const Padding(padding: EdgeInsets.all(6), child: Text('Longest Cardiac Pause', style: TextStyle(fontWeight: FontWeight.bold))),
                      Padding(padding: const EdgeInsets.all(6), child: Text('${_result!.longestPauseSec.toStringAsFixed(2)} s')),
                    ]),
                    TableRow(children: [
                      const Padding(padding: EdgeInsets.all(6), child: Text('Asystole Events (≥ 3.0s)', style: TextStyle(fontWeight: FontWeight.bold))),
                      Padding(padding: const EdgeInsets.all(6), child: Text('${_result!.asystoleEvents.length}')),
                    ]),
                    TableRow(children: [
                      const Padding(padding: EdgeInsets.all(6), child: Text('Bradycardia Episodes (< 40 bpm)', style: TextStyle(fontWeight: FontWeight.bold))),
                      Padding(padding: const EdgeInsets.all(6), child: Text('${_result!.bradycardiaEvents.length}')),
                    ]),
                    TableRow(children: [
                      const Padding(padding: EdgeInsets.all(6), child: Text('Tachycardia Episodes (> 90 bpm)', style: TextStyle(fontWeight: FontWeight.bold))),
                      Padding(padding: const EdgeInsets.all(6), child: Text('${_result!.tachycardiaEvents.length}')),
                    ]),
                    TableRow(children: [
                      const Padding(padding: EdgeInsets.all(6), child: Text('Premature Ventricular (PVC / VPB)', style: TextStyle(fontWeight: FontWeight.bold))),
                      Padding(padding: const EdgeInsets.all(6), child: Text('${_result!.pvcEvents.length}')),
                    ]),
                    TableRow(children: [
                      const Padding(padding: EdgeInsets.all(6), child: Text('Premature Atrial (PAC / APB)', style: TextStyle(fontWeight: FontWeight.bold))),
                      Padding(padding: const EdgeInsets.all(6), child: Text('${_result!.pacEvents.length}')),
                    ]),
                    TableRow(children: [
                      const Padding(padding: EdgeInsets.all(6), child: Text('Arrhythmia Episodes (Couplet/Bigeminy/Trigeminy/VT/SVT/AFib)', style: TextStyle(fontWeight: FontWeight.bold))),
                      Padding(padding: const EdgeInsets.all(6), child: Text('${_result!.arrhythmiaEvents.length}')),
                    ]),
                  ],
                ),
                if (_result!.stageMeanHr.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final entry in _result!.stageMeanHr.entries)
                        Chip(
                          label: Text('${entry.key.name.toUpperCase()}: ${entry.value.toStringAsFixed(1)} bpm'),
                          backgroundColor: Colors.blue.shade50,
                          padding: EdgeInsets.zero,
                          labelStyle: const TextStyle(fontSize: 11),
                        ),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isAnalyzing ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (_result == null)
          ElevatedButton.icon(
            icon: const Icon(Icons.analytics),
            label: const Text('Run Cardiac Analysis'),
            onPressed: _isAnalyzing || _selectedEcg.isEmpty ? null : _run,
          )
        else
          ElevatedButton.icon(
            icon: const Icon(Icons.check),
            label: Text('Add ${_result!.totalCardiacEvents} Events to Recording'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            onPressed: () => Navigator.of(context).pop(_result),
          ),
      ],
    );
  }
}
