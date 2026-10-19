import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/models.dart';
import 'package:ccs_sleep_studio/src/pattern_search.dart';

void main() {
  group('PatternMatcher (Normalized Cross-Correlation)', () {
    test('matches identical and similar waveform patterns across signal', () {
      const sampleRate = 100.0;
      const totalSeconds = 60.0;
      final totalSamples = (totalSeconds * sampleRate).toInt();
      final signal = List<double>.filled(totalSamples, 0.0);

      // Create a template: 1.0 second damped spindle-like burst
      const templateSec = 1.0;
      final templateSamplesCount = (templateSec * sampleRate).toInt();
      final templateSamples = List<double>.generate(templateSamplesCount, (i) {
        final t = i / sampleRate;
        return 30.0 * math.sin(2 * math.pi * 12 * t) * math.exp(-2.0 * t) + 10.0 * math.cos(2 * math.pi * 3 * t);
      });

      // Embed pattern at t = 10.0 s
      final t1 = (10.0 * sampleRate).toInt();
      for (var i = 0; i < templateSamplesCount; i++) {
        signal[t1 + i] = templateSamples[i];
      }

      // Embed pattern at t = 35.0 s with slight scaling (e.g. 1.2x) and offset (+5 uV)
      final t2 = (35.0 * sampleRate).toInt();
      for (var i = 0; i < templateSamplesCount; i++) {
        signal[t2 + i] = 1.2 * templateSamples[i] + 5.0;
      }

      // Embed inverted pattern at t = 50.0 s (-1.0x)
      final t3 = (50.0 * sampleRate).toInt();
      for (var i = 0; i < templateSamplesCount; i++) {
        signal[t3 + i] = -1.0 * templateSamples[i];
      }

      final template = PatternTemplate(
        channel: 'C3-A2',
        startSec: 10.0,
        endSec: 11.0,
        samples: templateSamples,
        sampleRateHz: sampleRate,
      );

      // Standard search (positive polarity only)
      final matchesPos = PatternMatcher.search(
        signal: signal,
        template: template,
        sampleRateHz: sampleRate,
        options: const PatternSearchOptions(
          similarityThreshold: 0.90,
          allowInverted: false,
        ),
      );

      expect(matchesPos.length, 2);
      expect((matchesPos[0].startSec - 10.0).abs() < 0.05, isTrue);
      expect(matchesPos[0].similarity > 0.99, isTrue);
      expect((matchesPos[1].startSec - 35.0).abs() < 0.05, isTrue);
      expect(matchesPos[1].similarity > 0.99, isTrue);

      // Search allowing inverted patterns
      final matchesWithInv = PatternMatcher.search(
        signal: signal,
        template: template,
        sampleRateHz: sampleRate,
        options: const PatternSearchOptions(
          similarityThreshold: 0.90,
          allowInverted: true,
        ),
      );

      expect(matchesWithInv.length, 3);
      expect((matchesWithInv[2].startSec - 50.0).abs() < 0.05, isTrue);
      expect(matchesWithInv[2].isInverted, isTrue);
    });

    test('respects sleep stage filtering', () {
      const sampleRate = 100.0;
      final signal = List<double>.filled(6000, 0.0); // 60s (2 epochs of 30s)
      final templateSamples = List<double>.generate(100, (i) => math.sin(i * 0.1));

      // Embed at t = 10s (Epoch 1, 0-30s)
      for (var i = 0; i < 100; i++) {
        signal[1000 + i] = templateSamples[i];
      }
      // Embed at t = 40s (Epoch 2, 30-60s)
      for (var i = 0; i < 100; i++) {
        signal[4000 + i] = templateSamples[i];
      }

      final template = PatternTemplate(
        channel: 'C4-A1',
        startSec: 10.0,
        endSec: 11.0,
        samples: templateSamples,
        sampleRateHz: sampleRate,
      );

      final stages = [SleepStage.wake, SleepStage.n2];

      final matchesN2Only = PatternMatcher.search(
        signal: signal,
        template: template,
        sampleRateHz: sampleRate,
        stages: stages,
        epochSeconds: 30.0,
        options: const PatternSearchOptions(
          similarityThreshold: 0.80,
          filterStages: ['N2'],
        ),
      );

      expect(matchesN2Only.length, 1);
      expect((matchesN2Only[0].startSec - 40.0).abs() < 0.05, isTrue);
      expect(matchesN2Only[0].stage, 'N2');
    });
  });
}
