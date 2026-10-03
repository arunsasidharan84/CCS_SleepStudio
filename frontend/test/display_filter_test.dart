import 'dart:math' as math;

import 'package:ccs_sleep_studio/src/eeg_backend.dart';
import 'package:ccs_sleep_studio/src/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sampleRate = 250.0;
  final rng = math.Random(7);
  var drift = 0.0;
  final samples = List<double>.generate((sampleRate * 180).round(), (i) {
    final t = i / sampleRate;
    drift += (rng.nextDouble() - 0.5) * 0.4;
    return drift + 25.0 * math.sin(2 * math.pi * 10 * t) + 10.0 * math.sin(2 * math.pi * 50 * t);
  });
  final raw = LoadedEeg(
    sampleRateHz: sampleRate,
    channelLabels: const ['C3-M2'],
    channelSamples: [samples],
    sourceDescription: 'synthetic',
  );

  AppConfig filtered() {
    final cfg = AppConfig.defaultsForChannels(const ['C3-M2'], sampleRateHz: sampleRate);
    cfg.channels.first
      ..filterHpEnabled = true
      ..filterHpCutoff = 0.5
      ..filterLpEnabled = true
      ..filterLpCutoff = 35
      ..filterNotchEnabled = true
      ..filterNotchCutoff = 50;
    return cfg;
  }

  test('a filtered window matches the same span of the whole filtered night', () {
    final backend = EegBackend();
    final cfg = filtered();
    final whole = backend.getDisplaySegmentForChannel(
      eeg: raw,
      channelIndex: 0,
      start: 0,
      end: samples.length,
      config: cfg,
      applyFilters: true,
    );
    final start = (60 * sampleRate).round();
    final end = (90 * sampleRate).round();
    final window = backend.getDisplaySegmentForChannel(
      eeg: raw,
      channelIndex: 0,
      start: start,
      end: end,
      config: cfg,
      applyFilters: true,
    );
    expect(window.length, end - start);
    var maxErr = 0.0;
    var ss = 0.0;
    for (var i = 0; i < window.length; i++) {
      maxErr = math.max(maxErr, (window[i] - whole[start + i]).abs());
      ss += whole[start + i] * whole[start + i];
    }
    final rms = math.sqrt(ss / window.length);
    // No edge transient at the window borders: within 1 % of the signal RMS.
    expect(maxErr, lessThan(0.01 * rms));
  });

  test('filters change the window, not the input', () {
    final backend = EegBackend();
    final copy = List<double>.from(samples.take(2500));
    final out = backend.getDisplaySegmentForChannel(
      eeg: raw,
      channelIndex: 0,
      start: 0,
      end: 2500,
      config: filtered(),
      applyFilters: true,
    );
    expect(samples.take(2500).toList(), copy);
    expect(out.every((v) => v.isFinite), isTrue);
  });

  test('spectrogram is off by default and skips the night products', () async {
    final backend = EegBackend();
    final cfg = AppConfig.defaultsForChannels(const ['C3-M2'], sampleRateHz: sampleRate);
    expect(cfg.spectrogramEnabled, isFalse);
    final eeg = await backend.computeNightProducts(raw, cfg);
    expect(eeg.spectrogramPower, isEmpty);
    expect(eeg.swaPerEpoch, isEmpty);
    final viewport = await backend.viewportFromEeg(
      eeg,
      currentEpoch: 1,
      config: cfg,
      includeTimeFrequency: false,
    );
    // The current epoch's spectrum is still computed on demand.
    expect(viewport.currentEpochPeriodogram, isNotEmpty);

    final restored = AppConfig.fromJson(cfg.toJson()..['spectrogramEnabled'] = true);
    expect(restored.spectrogramEnabled, isTrue);
  });
}
