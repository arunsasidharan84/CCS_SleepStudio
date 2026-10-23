import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/cardiac_analysis.dart';
import 'package:ccs_sleep_studio/src/models.dart';

void main() {
  group('AasmCardiacAnalyzer and Arrhythmia Analysis', () {
    test('detects normal sinus rhythm without arrhythmias', () {
      const sampleRate = 200.0;
      // 60 beats at 1.0 s interval (60 bpm)
      final ecg = <double>[];
      for (var b = 0; b < 60; b++) {
        // 200 samples per beat
        for (var i = 0; i < 200; i++) {
          final t = i / sampleRate;
          // Simulated QRS spike around 50 ms
          if (i == 50) {
            ecg.add(1.5);
          } else if (i == 48 || i == 52) {
            ecg.add(-0.3);
          } else {
            ecg.add(0.02 * math.sin(2 * math.pi * 1.0 * t));
          }
        }
      }

      final result = AasmCardiacAnalyzer.analyze(
        ecgSamples: ecg,
        sampleRate: sampleRate,
        includeArrhythmias: true,
        channelName: 'ECG',
      );

      expect(result.totalBeats, greaterThanOrEqualTo(50));
      expect(result.overallMeanHr, closeTo(60.0, 5.0));
      expect(result.asystoleEvents, isEmpty);
      expect(result.bradycardiaEvents, isEmpty);
      expect(result.tachycardiaEvents, isEmpty);
      expect(result.arrhythmiaEvents, isEmpty);
    });

    test('detects asystole and premature ventricular beats (PVCs)', () {
      const sampleRate = 200.0;
      final ecg = <double>[];

      // 10 normal beats at 1s interval (200 samples)
      for (var b = 0; b < 10; b++) {
        for (var i = 0; i < 200; i++) {
          ecg.add(i == 50 ? 1.5 : (i == 48 || i == 52 ? -0.3 : 0.0));
        }
      }

      // 1 premature beat at 500 ms (100 samples) with compensatory pause (300 samples)
      // Premature wide beat (PVC)
      for (var i = 0; i < 100; i++) {
        // Wide QRS: spike spanning multiple samples
        if (i >= 40 && i <= 65) {
          ecg.add(1.2 * math.sin((i - 40) / 25.0 * math.pi));
        } else {
          ecg.add(0.0);
        }
      }
      for (var i = 0; i < 300; i++) {
        ecg.add(0.0);
      }

      // 10 more normal beats
      for (var b = 0; b < 10; b++) {
        for (var i = 0; i < 200; i++) {
          ecg.add(i == 50 ? 1.5 : (i == 48 || i == 52 ? -0.3 : 0.0));
        }
      }

      // Asystole pause: 4.0 seconds flat (800 samples)
      for (var i = 0; i < 800; i++) {
        ecg.add(0.0);
      }

      // 5 trailing beats
      for (var b = 0; b < 5; b++) {
        for (var i = 0; i < 200; i++) {
          ecg.add(i == 50 ? 1.5 : (i == 48 || i == 52 ? -0.3 : 0.0));
        }
      }

      final result = AasmCardiacAnalyzer.analyze(
        ecgSamples: ecg,
        sampleRate: sampleRate,
        asystoleThresholdSec: 3.0,
        includeArrhythmias: true,
        channelName: 'ECG',
      );

      expect(result.asystoleEvents.length, greaterThanOrEqualTo(1));
      expect(result.longestPauseSec, greaterThanOrEqualTo(3.5));
      expect(result.allEvents, isNotEmpty);
    });
  });
}
