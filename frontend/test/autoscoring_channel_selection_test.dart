import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/detection_dialogs.dart';

void main() {
  group('AASM Derivation Recognizers', () {
    test('isAasmEegDerivation correctly identifies AASM EEG derivations', () {
      // Contralateral Mastoid (M1/M2) and Ear (A1/A2)
      expect(isAasmEegDerivation('C4-M1'), isTrue);
      expect(isAasmEegDerivation('C3-M2'), isTrue);
      expect(isAasmEegDerivation('F4-M1'), isTrue);
      expect(isAasmEegDerivation('F3-M2'), isTrue);
      expect(isAasmEegDerivation('O2-M1'), isTrue);
      expect(isAasmEegDerivation('O1-M2'), isTrue);
      expect(isAasmEegDerivation('EEG C4-A1'), isTrue);
      expect(isAasmEegDerivation('EEG C3-A2'), isTrue);
      expect(isAasmEegDerivation('POL F4-A1'), isTrue);
      expect(isAasmEegDerivation('POL O2-A1'), isTrue);
      expect(isAasmEegDerivation('CZ-M1'), isTrue);

      // Non-AASM EEG derivations or raw channels
      expect(isAasmEegDerivation('C4'), isFalse);
      expect(isAasmEegDerivation('Fp1-F3'), isFalse);
      expect(isAasmEegDerivation('T3-T5'), isFalse);
      expect(isAasmEegDerivation('P3-O1'), isFalse);
      expect(isAasmEegDerivation('ECG'), isFalse);
    });

    test('isAasmEogDerivation correctly identifies AASM EOG derivations and channels', () {
      expect(isAasmEogDerivation('E1-M2'), isTrue);
      expect(isAasmEogDerivation('E2-M1'), isTrue);
      expect(isAasmEogDerivation('LOC-A2'), isTrue);
      expect(isAasmEogDerivation('ROC-A1'), isTrue);
      expect(isAasmEogDerivation('LOC'), isTrue);
      expect(isAasmEogDerivation('ROC'), isTrue);
      expect(isAasmEogDerivation('E1'), isTrue);
      expect(isAasmEogDerivation('E2'), isTrue);
      expect(isAasmEogDerivation('EOG1'), isTrue);
      expect(isAasmEogDerivation('EOG2'), isTrue);
      expect(isAasmEogDerivation('EOG LOC1'), isTrue);

      expect(isAasmEogDerivation('C4-M1'), isFalse);
      expect(isAasmEogDerivation('CHIN1'), isFalse);
    });

    test('isAasmEmgDerivation correctly identifies AASM submental/chin EMG derivations', () {
      expect(isAasmEmgDerivation('CHIN1-CHIN2'), isTrue);
      expect(isAasmEmgDerivation('CHIN1-CHIN3'), isTrue);
      expect(isAasmEmgDerivation('EMG Chin'), isTrue);
      expect(isAasmEmgDerivation('Submental'), isTrue);
      expect(isAasmEmgDerivation('CHIN'), isTrue);

      expect(isAasmEmgDerivation('C4-M1'), isFalse);
      expect(isAasmEmgDerivation('E1-M2'), isFalse);
      expect(isAasmEmgDerivation('ECG'), isFalse);
    });
  });

  group('populateScoringChannelDefaults', () {
    test('selects only active AASM derivations when AASM montage is applied', () {
      final allChannels = [
        'Fp1', 'Fp2', 'F3', 'F4', 'C3', 'C4', 'P3', 'P4', 'O1', 'O2',
        'T3', 'T4', 'T5', 'T6', 'A1', 'A2',
        'C4-A1', 'F4-A1', 'O2-A1', 'C3-A2', 'F3-A2', 'O1-A2',
        'LOC-A2', 'ROC-A1',
        'CHIN1-CHIN2',
        'ECG', 'Flow'
      ];
      final visiblePool = [
        'C4-A1', 'F4-A1', 'O2-A1', 'LOC-A2', 'ROC-A1', 'CHIN1-CHIN2', 'ECG', 'Flow'
      ];

      final eegMap = <String, bool>{};
      final refMap = <String, bool>{};
      final eogMap = <String, bool>{};
      final emgMap = <String, bool>{};

      populateScoringChannelDefaults(
        channelLabels: allChannels,
        visibleChannelLabels: visiblePool,
        eegMap: eegMap,
        refMap: refMap,
        eogMap: eogMap,
        emgMap: emgMap,
      );

      // Only the visible AASM EEG derivations should be checked
      expect(eegMap['C4-A1'], isTrue);
      expect(eegMap['F4-A1'], isTrue);
      expect(eegMap['O2-A1'], isTrue);
      expect(eegMap['C3-A2'], isFalse); // not in visible pool
      expect(eegMap['Fp1'], isFalse);
      expect(eegMap['C4'], isFalse);
      expect(eegMap['T3'], isFalse);

      // References: raw mastoids/ears in file are still classified as potential reference
      expect(refMap['A1'], isTrue);
      expect(refMap['A2'], isTrue);
      expect(refMap['C4-A1'], isFalse);
      expect(refMap['C4'], isFalse);

      // EOG: only LOC-A2 and ROC-A1 checked
      expect(eogMap['LOC-A2'], isTrue);
      expect(eogMap['ROC-A1'], isTrue);
      expect(eogMap['C4-A1'], isFalse);

      // EMG: only CHIN1-CHIN2 checked
      expect(emgMap['CHIN1-CHIN2'], isTrue);
      expect(emgMap['ECG'], isFalse);
    });

    test('selects standard AASM central/frontal/occipital and refs when only raw channels exist', () {
      final rawChannels = [
        'Fp1', 'Fp2', 'F3', 'F4', 'C3', 'C4', 'P3', 'P4', 'O1', 'O2',
        'T3', 'T4', 'M1', 'M2', 'E1', 'E2', 'CHIN1', 'CHIN2', 'ECG'
      ];

      final eegMap = <String, bool>{};
      final refMap = <String, bool>{};
      final eogMap = <String, bool>{};
      final emgMap = <String, bool>{};

      populateScoringChannelDefaults(
        channelLabels: rawChannels,
        eegMap: eegMap,
        refMap: refMap,
        eogMap: eogMap,
        emgMap: emgMap,
      );

      // Standard AASM channels should be true
      expect(eegMap['C4'], isTrue);
      expect(eegMap['C3'], isTrue);
      expect(eegMap['F4'], isTrue);
      expect(eegMap['F3'], isTrue);
      expect(eegMap['O2'], isTrue);
      expect(eegMap['O1'], isTrue);

      // Extraneous channels should NOT be selected for auto-scoring
      expect(eegMap['Fp1'], isFalse);
      expect(eegMap['Fp2'], isFalse);
      expect(eegMap['P3'], isFalse);
      expect(eegMap['P4'], isFalse);
      expect(eegMap['T3'], isFalse);
      expect(eegMap['T4'], isFalse);

      // References should be selected
      expect(refMap['M1'], isTrue);
      expect(refMap['M2'], isTrue);
      expect(refMap['C4'], isFalse);

      // EOG & EMG
      expect(eogMap['E1'], isTrue);
      expect(eogMap['E2'], isTrue);
      expect(emgMap['CHIN1'], isTrue);
      expect(emgMap['CHIN2'], isTrue);
    });
  });
}
