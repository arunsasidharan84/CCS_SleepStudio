import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/eeg_backend.dart';
import 'package:ccs_sleep_studio/src/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('renders lazy wavelet image for a loaded viewport', () async {
    final backend = EegBackend();
    const sampleRate = 64.0;
    final samples = List<double>.generate((sampleRate * 36).round(), (i) {
      final t = i / sampleRate;
      return 40.0 * math.sin(2.0 * math.pi * 10.0 * t) +
          8.0 * math.sin(2.0 * math.pi * 2.0 * t);
    });
    final config = AppConfig.defaultsForChannels(const [
      'C3-M2',
    ], sampleRateHz: sampleRate)..tfFreqMax = 30.0;
    final raw = LoadedEeg(
      sampleRateHz: sampleRate,
      channelLabels: const ['C3-M2'],
      channelSamples: [samples],
      sourceDescription: 'synthetic',
    );

    config.spectrogramEnabled = true;
    final eeg = await backend.computeNightProducts(raw, config);
    final viewport = await backend.viewportFromEeg(
      eeg,
      currentEpoch: 0,
      config: config,
      includeTimeFrequency: false,
    );
    final refreshed = await backend.refreshTimeFrequencyForEpoch(
      viewport,
      eeg,
      config: config,
    );

    expect(refreshed.tfPower, isNotEmpty);
    expect(refreshed.tfPower.first, isNotEmpty);
    expect(refreshed.tfImage, isNotNull);
  });

  test('uses configured channels and display limits', () async {
    final backend = EegBackend();
    const sampleRate = 512.0;
    final sampleCount = (sampleRate * 36).round();
    final channels = [
      List<double>.generate(sampleCount, (i) {
        final t = i / sampleRate;
        return math.sin(2.0 * math.pi * 2.0 * t);
      }),
      List<double>.generate(sampleCount, (i) {
        final t = i / sampleRate;
        return math.sin(2.0 * math.pi * 18.0 * t);
      }),
    ];
    final config =
        AppConfig.defaultsForChannels(const [
            'C3-M2',
            'O1-M2',
          ], sampleRateHz: sampleRate)
          ..spectrogramChannelIndex = 1
          ..spectrogramFreqMin = 5.0
          ..spectrogramFreqMax = 25.0
          ..spectrogramPowerMin = -2.0
          ..spectrogramPowerMax = 2.0
          ..tfChannelIndex = 1
          ..tfFreqMin = 6.0
          ..tfFreqMax = 30.0;
    final raw = LoadedEeg(
      sampleRateHz: sampleRate,
      channelLabels: const ['C3-M2', 'O1-M2'],
      channelSamples: channels,
      sourceDescription: 'synthetic',
    );

    config.spectrogramEnabled = true;
    final eeg = await backend.computeNightProducts(raw, config);
    final viewport = await backend.viewportFromEeg(
      eeg,
      currentEpoch: 0,
      config: config,
      includeTimeFrequency: false,
    );
    final refreshed = await backend.refreshTimeFrequencyForEpoch(
      viewport,
      eeg,
      config: config,
    );

    expect(eeg.spectrogramChannelIndex, 1);
    expect(viewport.spectrogramChannelIndex, 1);
    expect(viewport.spectrogramFreqMin, 5.0);
    expect(viewport.spectrogramFreqMax, 25.0);
    expect(viewport.spectrogramPowerMin, -2.0);
    expect(viewport.spectrogramPowerMax, 2.0);
    expect(refreshed.tfChannelIndex, 1);
    expect(refreshed.tfFreqs.first, closeTo(6.0, 0.01));
    expect(refreshed.tfFreqs.last, closeTo(30.0, 0.01));
    expect(refreshed.tfPower, isNotEmpty);
  });

  test('computes SWA from its independently configured channel', () async {
    final backend = EegBackend();
    const sampleRate = 64.0;
    final sampleCount = (sampleRate * 66).round();
    final channels = [
      List<double>.generate(sampleCount, (i) {
        final t = i / sampleRate;
        return 20.0 * math.sin(2.0 * math.pi * 2.0 * t);
      }),
      List<double>.generate(sampleCount, (i) {
        final t = i / sampleRate;
        return 20.0 * math.sin(2.0 * math.pi * 12.0 * t);
      }),
    ];
    final config =
        AppConfig.defaultsForChannels(const [
            'F3',
            'O2',
          ], sampleRateHz: sampleRate)
          ..spectrogramChannelIndex = 1
          ..swaChannelIndex = 0;
    final raw = LoadedEeg(
      sampleRateHz: sampleRate,
      channelLabels: const ['F3', 'O2'],
      channelSamples: channels,
      sourceDescription: 'synthetic independent SWA channel',
    );

    config.spectrogramEnabled = true;
    final lowFrequencySwa = await backend.computeNightProducts(raw, config);
    config.swaChannelIndex = 1;
    config.spectrogramEnabled = true;
    final highFrequencySwa = await backend.computeNightProducts(raw, config);

    expect(lowFrequencySwa.swaPerEpoch, isNotEmpty);
    expect(
      lowFrequencySwa.swaPerEpoch.first,
      greaterThan(highFrequencySwa.swaPerEpoch.first * 100),
    );
  });

  test(
    'accepts legacy filtered configs using the loaded sample rate',
    () async {
      final backend = EegBackend();
      const sampleRate = 256.0;
      final samples = List<double>.generate((sampleRate * 36).round(), (i) {
        final t = i / sampleRate;
        return 20.0 * math.sin(2.0 * math.pi * 8.0 * t);
      });
      final config = AppConfig(
        tfFreqMin: 0.25,
        tfFreqMax: 45.0,
        channels: [
          ChannelConfig(
            name: 'F3',
            sourceIndex: 0,
            filterHpEnabled: true,
            filterHpCutoff: 0.3,
            filterLpEnabled: true,
            filterLpCutoff: 35.0,
          ),
        ],
      );
      config.bindLoadedChannels(const ['F3'], sampleRateHz: sampleRate);
      final raw = LoadedEeg(
        sampleRateHz: sampleRate,
        channelLabels: const ['F3'],
        channelSamples: [samples],
        sourceDescription: 'synthetic legacy config',
      );

      config.spectrogramEnabled = true;
      final eeg = await backend.computeNightProducts(raw, config);

      expect(eeg.spectrogramPower, isNotEmpty);
      expect(config.tfFreqMax, 45.0);
    },
  );

  test('keeps configured panel labels after refresh and navigation', () async {
    final backend = EegBackend();
    const sampleRate = 64.0;
    final sampleCount = (sampleRate * 66).round();
    final channels = [
      List<double>.generate(sampleCount, (i) {
        final t = i / sampleRate;
        return math.sin(2.0 * math.pi * 3.0 * t);
      }),
      List<double>.generate(sampleCount, (i) {
        final t = i / sampleRate;
        return math.sin(2.0 * math.pi * 12.0 * t);
      }),
    ];
    final config = AppConfig(
      spectrogramChannelIndex: 2,
      periodogramChannelIndex: 1,
      tfChannelIndex: 2,
      tfFreqMax: 30.0,
      channels: [
        ChannelConfig(name: 'F3', sourceIndex: 0),
        ChannelConfig(name: 'O2', sourceIndex: 1),
        ChannelConfig(
          name: 'F3-O2',
          sourceIndex: 0,
          derived: true,
          sourceChannel: 'F3',
          reReference: 'O2',
        ),
      ],
    );
    config.bindLoadedChannels(const ['F3', 'O2'], sampleRateHz: sampleRate);
    final raw = LoadedEeg(
      sampleRateHz: sampleRate,
      channelLabels: const ['F3', 'O2'],
      channelSamples: channels,
      sourceDescription: 'synthetic configured channels',
    );

    config.spectrogramEnabled = true;
    final eeg = await backend.computeNightProducts(raw, config);
    final viewport = await backend.viewportFromEeg(
      eeg,
      currentEpoch: 0,
      config: config,
      includeTimeFrequency: false,
    );
    final refreshed = await backend.refreshTimeFrequencyForEpoch(
      viewport,
      eeg,
      config: config,
    );
    final navigated = await backend.rebuildViewportForEpoch(
      refreshed,
      eeg,
      1,
      config: config,
    );

    expect(navigated.spectrogramChannelLabel, 'F3-O2');
    expect(navigated.periodogramChannelLabel, 'O2');
    expect(navigated.tfChannelLabel, 'F3-O2');
    expect(navigated.tfPower, isNotEmpty);
  });

  test('autoscale is captured once and remains fixed across epochs', () async {
    final backend = EegBackend();
    const sampleRate = 64.0;
    final samples = List<double>.generate((sampleRate * 66).round(), (i) {
      final t = i / sampleRate;
      final amplitude = t < 33 ? 5.0 : 100.0;
      return amplitude * math.sin(2.0 * math.pi * 8.0 * t);
    });
    final config = AppConfig.defaultsForChannels(const [
      'C3-M2',
    ], sampleRateHz: sampleRate)..tfFreqMax = 30.0;
    final raw = LoadedEeg(
      sampleRateHz: sampleRate,
      channelLabels: const ['C3-M2'],
      channelSamples: [samples],
      sourceDescription: 'varying amplitude',
    );

    config.spectrogramEnabled = true;
    final eeg = await backend.computeNightProducts(raw, config);
    final initial = await backend.viewportFromEeg(
      eeg,
      currentEpoch: 0,
      config: config,
      includeTimeFrequency: true,
    );
    final next = await backend.rebuildViewportForEpoch(
      initial,
      eeg,
      1,
      config: config,
    );

    expect(initial.tfPowerMin, isNot(config.tfPowerMin));
    expect(next.tfPowerMin, initial.tfPowerMin);
    expect(next.tfPowerMax, initial.tfPowerMax);
  });

  test('manual wavelet scale uses configured limits', () async {
    final backend = EegBackend();
    const sampleRate = 64.0;
    final samples = List<double>.generate((sampleRate * 36).round(), (i) {
      final t = i / sampleRate;
      return 20.0 * math.sin(2.0 * math.pi * 8.0 * t);
    });
    final config =
        AppConfig.defaultsForChannels(const ['C3-M2'], sampleRateHz: sampleRate)
          ..tfFreqMax = 30.0
          ..tfAutoScale = false
          ..tfPowerMin = -4.0
          ..tfPowerMax = 7.0;
    final raw = LoadedEeg(
      sampleRateHz: sampleRate,
      channelLabels: const ['C3-M2'],
      channelSamples: [samples],
      sourceDescription: 'manual scale',
    );

    config.spectrogramEnabled = true;
    final eeg = await backend.computeNightProducts(raw, config);
    final viewport = await backend.viewportFromEeg(
      eeg,
      currentEpoch: 0,
      config: config,
      includeTimeFrequency: true,
    );

    expect(viewport.tfPowerMin, -4.0);
    expect(viewport.tfPowerMax, 7.0);
  });
}
