import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/models.dart';
import 'package:ccs_sleep_studio/src/rem_detection.dart';

void main() {
  group('Rapid Eye Movement (REM) Detector', () {
    test('detects conjugate, out-of-phase EOG deflections during REM sleep', () async {
      const sampleRate = 100.0;
      const durationSeconds = 120.0;
      final numSamples = (sampleRate * durationSeconds).toInt();

      final locSignal = List<double>.filled(numSamples, 0.0);
      final rocSignal = List<double>.filled(numSamples, 0.0);

      // Create synthetic saccades
      // Saccade 1: at t = 20s (duration 0.4s) -> conjugate out-of-phase (LOC positive, ROC negative)
      final saccade1Start = (20.0 * sampleRate).toInt();
      final saccade1Len = (0.4 * sampleRate).toInt();
      for (var i = 0; i < saccade1Len; i++) {
        final sinVal = math.sin((i / saccade1Len) * math.pi);
        locSignal[saccade1Start + i] = 50.0 * sinVal; // +50 uV
        rocSignal[saccade1Start + i] = -50.0 * sinVal; // -50 uV
      }

      // Saccade 2: at t = 80s (duration 0.5s) -> in-phase blink (LOC positive, ROC positive) - SHOULD BE REJECTED
      final saccade2Start = (80.0 * sampleRate).toInt();
      final saccade2Len = (0.5 * sampleRate).toInt();
      for (var i = 0; i < saccade2Len; i++) {
        final sinVal = math.sin((i / saccade2Len) * math.pi);
        locSignal[saccade2Start + i] = 60.0 * sinVal;
        rocSignal[saccade2Start + i] = 60.0 * sinVal;
      }

      // Saccade 3: at t = 100s (duration 0.35s) -> conjugate out-of-phase (LOC negative, ROC positive)
      final saccade3Start = (100.0 * sampleRate).toInt();
      final saccade3Len = (0.35 * sampleRate).toInt();
      for (var i = 0; i < saccade3Len; i++) {
        final sinVal = math.sin((i / saccade3Len) * math.pi);
        locSignal[saccade3Start + i] = -45.0 * sinVal;
        rocSignal[saccade3Start + i] = 45.0 * sinVal;
      }

      // 4 epochs of 30s:
      // Epoch 0: Wake
      // Epoch 1: REM (contains Saccade 1 at 20s) -> Wait, 20s is in epoch 0 (0-30s)!
      // Let's set epoch 0 to REM, epoch 1 to N2, epoch 2 to N2, epoch 3 to REM (contains Saccade 3 at 100s)
      final stages = [
        SleepStage.rem, // 0 - 30s (Saccade 1 at 20s)
        SleepStage.n2,  // 30 - 60s
        SleepStage.n2,  // 60 - 90s (Saccade 2 at 80s, in-phase blink)
        SleepStage.rem, // 90 - 120s (Saccade 3 at 100s)
      ];

      final report = RemDetector.detect(
        locSignal: locSignal,
        rocSignal: rocSignal,
        sampleRateHz: sampleRate,
        stages: stages,
        epochSeconds: 30,
        options: const RemDetectionOptions(
          minDurationSeconds: 0.1,
          maxDurationSeconds: 1.2,
          minAmplitudeUv: 25.0,
          minVelocityUvPerSec: 100.0,
          restrictToRemStage: true,
        ),
      );

      // Should detect Saccade 1 and Saccade 3, but reject in-phase Saccade 2
      expect(report.totalEvents, equals(2));
      expect(report.totalRemDurationMinutes, equals(1.0)); // 2 epochs of 30s = 60s = 1 min
      expect(report.remDensityPerMinute, closeTo(2.0, 0.1));

      // Test saving and reloading
      final tempDir = await Directory.systemTemp.createTemp('ccs_rem_test');
      try {
        final edfPath = '${tempDir.path}${Platform.pathSeparator}test_rec.edf';
        final savedPath = await saveRemReport(edfPath, report);
        expect(File(savedPath).existsSync(), isTrue);

        final reloaded = await loadRemEvents(edfPath);
        expect(reloaded.length, equals(2));
        expect(reloaded.first.type, equals('REM'));
        expect(reloaded.first.digit, equals(6));
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}
