import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/models.dart';
import 'package:ccs_sleep_studio/src/eeg_backend.dart';

void main() {
  test('report metadata survives native configuration serialization', () {
    final config = AppConfig(
      reportTitle: 'Custom Sleep Study',
      studySite: 'Study Centre',
      investigatorName: 'Dr Example',
      subjectId: 'SUB-42',
      subjectDetails: 'Control participant',
    );

    final restored = AppConfig.fromJson(config.toJson());

    expect(restored.reportTitle, 'Custom Sleep Study');
    expect(restored.studySite, 'Study Centre');
    expect(restored.investigatorName, 'Dr Example');
    expect(restored.subjectId, 'SUB-42');
    expect(restored.subjectDetails, 'Control participant');
  });

  test(
    'report metadata survives legacy Python configuration serialization',
    () {
      final config = AppConfig(
        reportTitle: 'Custom Sleep Study',
        studySite: 'Study Centre',
        investigatorName: 'Dr Example',
        subjectId: 'SUB-42',
        subjectDetails: 'Control participant',
      );

      final restored = AppConfig.fromPythonJson(
        config.toPythonJson(),
        const [],
      );

      expect(restored.reportTitle, 'Custom Sleep Study');
      expect(restored.studySite, 'Study Centre');
      expect(restored.investigatorName, 'Dr Example');
      expect(restored.subjectId, 'SUB-42');
      expect(restored.subjectDetails, 'Control participant');
    },
  );

  test('feature extraction parameters survive native configuration serialization', () {
    final config = AppConfig(
      epochLengthSeconds: 20.0,
      featureWindowSeconds: 10.0,
      spindleFreqMin: 12.0,
      spindleFreqMax: 15.0,
      spindleDurationMin: 0.6,
      spindleDurationMax: 2.5,
      spindleRelPowerThresh: 0.25,
      spindleCorrThresh: 0.70,
      spindleRmsMultiplier: 1.8,
      slowWaveFreqMin: 0.4,
      slowWaveFreqMax: 1.8,
      slowWaveMinAmpUv: 80.0,
      slowWaveMinPtpUv: 80.0,
      slowWaveMaxPtpUv: 300.0,
      slowWaveMinNegAmpUv: 45.0,
      slowWaveMaxNegAmpUv: 180.0,
      slowWaveMinPosAmpUv: 15.0,
      slowWaveMaxPosAmpUv: 120.0,
      slowWaveDurationMin: 0.5,
      slowWaveDurationMax: 2.2,
      slowWaveNegDurationMin: 0.35,
      slowWaveNegDurationMax: 1.4,
      slowWavePosDurationMin: 0.15,
      slowWavePosDurationMax: 0.9,
      bandDeltaLo: 0.5,
      bandDeltaHi: 4.0,
      bandSigmaLo: 11.0,
      bandSigmaHi: 15.0,
    );

    final json = config.toJson();
    final restored = AppConfig.fromJson(json);

    expect(restored.epochLengthSeconds, 20.0);
    expect(restored.featureWindowSeconds, 10.0);
    expect(restored.spindleFreqMin, 12.0);
    expect(restored.spindleFreqMax, 15.0);
    expect(restored.spindleDurationMin, 0.6);
    expect(restored.spindleDurationMax, 2.5);
    expect(restored.spindleRelPowerThresh, 0.25);
    expect(restored.spindleCorrThresh, 0.70);
    expect(restored.spindleRmsMultiplier, 1.8);
    expect(restored.slowWaveFreqMin, 0.4);
    expect(restored.slowWaveFreqMax, 1.8);
    expect(restored.slowWaveMinAmpUv, 80.0);
    expect(restored.slowWaveMinPtpUv, 80.0);
    expect(restored.slowWaveMaxPtpUv, 300.0);
    expect(restored.slowWaveMinNegAmpUv, 45.0);
    expect(restored.slowWaveMaxNegAmpUv, 180.0);
    expect(restored.slowWaveMinPosAmpUv, 15.0);
    expect(restored.slowWaveMaxPosAmpUv, 120.0);
    expect(restored.slowWaveDurationMin, 0.5);
    expect(restored.slowWaveDurationMax, 2.2);
    expect(restored.slowWaveNegDurationMin, 0.35);
    expect(restored.slowWaveNegDurationMax, 1.4);
    expect(restored.slowWavePosDurationMin, 0.15);
    expect(restored.slowWavePosDurationMax, 0.9);
    expect(restored.bandSigmaLo, 11.0);
    expect(restored.bandSigmaHi, 15.0);
  });

  test('custom bands including ThetaAlpha serialize and restore accurately', () {
    final config = AppConfig(
      bands: [
        BandConfig(label: 'Delta', low: 0.5, high: 4.0),
        BandConfig(label: 'Theta', low: 4.0, high: 8.0),
        BandConfig(label: 'ThetaAlpha', low: 4.0, high: 12.0),
        BandConfig(label: 'Alpha', low: 8.0, high: 12.0),
        BandConfig(label: 'Sigma', low: 10.0, high: 16.0),
        BandConfig(label: 'Beta', low: 12.0, high: 30.0),
        BandConfig(label: 'Gamma', low: 30.0, high: 40.0),
      ],
    );

    final json = config.toJson();
    final restored = AppConfig.fromJson(json);

    expect(restored.bands.length, 7);
    expect(restored.bands[2].label, 'ThetaAlpha');
    expect(restored.bands[2].low, 4.0);
    expect(restored.bands[2].high, 12.0);
    // Legacy fields should sync to matching bands
    expect(restored.bandThetaLo, 4.0);
    expect(restored.bandAlphaHi, 12.0);
  });
}


