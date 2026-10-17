import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/models.dart';
import 'package:ccs_sleep_studio/src/montage_dialog.dart';
import 'package:ccs_sleep_studio/src/eeg_backend.dart';

void main() {
  group('detectChannelModality', () {
    test('identifies EEG channels correctly', () {
      expect(detectChannelModality('F3'), equals(ChannelModality.eeg));
      expect(detectChannelModality('C4'), equals(ChannelModality.eeg));
      expect(detectChannelModality('Cz'), equals(ChannelModality.eeg));
      expect(detectChannelModality('O1'), equals(ChannelModality.eeg));
      expect(detectChannelModality('EEG F3-A2'), equals(ChannelModality.eeg));
      expect(detectChannelModality('T3-T5'), equals(ChannelModality.eeg));
    });

    test('identifies EOG channels correctly', () {
      expect(detectChannelModality('EOG1'), equals(ChannelModality.eog));
      expect(detectChannelModality('EOG2'), equals(ChannelModality.eog));
      expect(detectChannelModality('LOC'), equals(ChannelModality.eog));
      expect(detectChannelModality('ROC'), equals(ChannelModality.eog));
      expect(detectChannelModality('E1-M2'), equals(ChannelModality.eog));
      expect(detectChannelModality('E2-M1'), equals(ChannelModality.eog));
      expect(detectChannelModality('LEOG'), equals(ChannelModality.eog));
    });

    test('identifies EMG channels correctly', () {
      expect(detectChannelModality('CHIN1'), equals(ChannelModality.emg));
      expect(detectChannelModality('CHIN2'), equals(ChannelModality.emg));
      expect(detectChannelModality('EMG1'), equals(ChannelModality.emg));
      expect(detectChannelModality('EMG2'), equals(ChannelModality.emg));
      expect(detectChannelModality('CHIN'), equals(ChannelModality.emg));
      expect(detectChannelModality('Submental'), equals(ChannelModality.emg));
      expect(detectChannelModality('EMG Chin'), equals(ChannelModality.emg));
    });

    test('identifies ECG channels correctly', () {
      expect(detectChannelModality('ECG'), equals(ChannelModality.ecg));
      expect(detectChannelModality('EKG'), equals(ChannelModality.ecg));
      expect(detectChannelModality('ECG1'), equals(ChannelModality.ecg));
      expect(detectChannelModality('ECG2'), equals(ChannelModality.ecg));
    });

    test('identifies Respiratory channels correctly', () {
      expect(detectChannelModality('Thorax'), equals(ChannelModality.respiratory));
      expect(detectChannelModality('Abdomen'), equals(ChannelModality.respiratory));
      expect(detectChannelModality('Flow'), equals(ChannelModality.respiratory));
      expect(detectChannelModality('Airflow'), equals(ChannelModality.respiratory));
      expect(detectChannelModality('SpO2'), equals(ChannelModality.respiratory));
      expect(detectChannelModality('Snore'), equals(ChannelModality.respiratory));
    });

    test('identifies other channels correctly', () {
      expect(detectChannelModality('Pulse'), equals(ChannelModality.other));
      expect(detectChannelModality('AUX1'), equals(ChannelModality.other));
      expect(detectChannelModality('Trigger'), equals(ChannelModality.other));
    });
  });

  group('AASM and Bipolar montage presets', () {
    final rawPsgChannels = [
      'F3', 'F4', 'C3', 'C4', 'O1', 'O2',
      'A1', 'A2',
      'EOG1', 'EOG2',
      'EMG1', 'EMG2',
      'ECG',
    ];

    test('AASM Sleep Standard preset includes EEG, EOG, and EMG derivations with A1/A2 mastoids', () {
      final aasmPreset = builtInMontagePresets.firstWhere((p) => p.name.contains('AASM'));
      final channels = generateMontagePresetChannels(
        preset: aasmPreset,
        availableChannels: rawPsgChannels,
      );

      // Verify visible channels on screen
      final visible = channels.where((c) => c.displayOnScreen).toList();
      final visibleNames = visible.map((c) => c.name).toList();

      // EEG derivations
      expect(visibleNames, contains('F3-A2'));
      expect(visibleNames, contains('C3-A2'));
      expect(visibleNames, contains('O1-A2'));
      expect(visibleNames, contains('F4-A1'));
      expect(visibleNames, contains('C4-A1'));
      expect(visibleNames, contains('O2-A1'));

      // EOG derivations
      final eog1 = visible.firstWhere((c) => c.name.startsWith('E1') || c.name.startsWith('EOG1'));
      final eog2 = visible.firstWhere((c) => c.name.startsWith('E2') || c.name.startsWith('EOG2'));
      expect(eog1.reReference, equals('A2'));
      expect(eog2.reReference, equals('A1'));

      // EMG derivations
      final emg = visible.firstWhere((c) => c.name.contains('CHIN') || c.name.contains('EMG'));
      expect(emg.reReference, isNotNull);

      // ECG is preserved
      expect(visibleNames, contains('ECG'));

      // Raw mastoid reference channels are not displayed as active signals on screen
      expect(channels.firstWhere((c) => c.name == 'A1').displayOnScreen, isFalse);
      expect(channels.firstWhere((c) => c.name == 'A2').displayOnScreen, isFalse);
    });

    test('Bipolar Longitudinal preset strictly excludes orphaned single channels', () {
      final longPreset = builtInMontagePresets.firstWhere((p) => p.name.contains('Longitudinal'));
      // Channel set with F7/F8 but missing 10-10 or 10-20 temporal chains
      final rawLimited = ['Fp1', 'F3', 'C3', 'P3', 'O1', 'F7', 'F8'];
      final channels = generateMontagePresetChannels(
        preset: longPreset,
        availableChannels: rawLimited,
      );

      final visible = channels.where((c) => c.displayOnScreen).toList();

      // Every visible channel MUST be a strict bipolar pair (reReference is not null and not empty)
      for (final ch in visible) {
        expect(ch.reReference, isNotNull, reason: '${ch.name} must have a reference electrode');
        expect(ch.reReference.trim().isNotEmpty, isTrue);
        expect(ch.reReference, isNot(equals('None')));
        expect(ch.name, isNot(equals(ch.reReference)));
      }

      // F7 and F8 should not appear as single monopolar channels
      final names = visible.map((c) => c.name).toList();
      expect(names, isNot(contains('F7')));
      expect(names, isNot(contains('F8')));
    });

    test('Bipolar Transverse preset strictly excludes orphaned single channels', () {
      final transPreset = builtInMontagePresets.firstWhere((p) => p.name.contains('Transverse'));
      final raw1020 = [
        'Fp1', 'Fp2', 'F7', 'F3', 'Fz', 'F4', 'F8',
        'T3', 'C3', 'Cz', 'C4', 'T4',
        'T5', 'P3', 'Pz', 'P4', 'T6',
        'O1', 'O2',
      ];
      final channels = generateMontagePresetChannels(
        preset: transPreset,
        availableChannels: raw1020,
      );

      final visible = channels.where((c) => c.displayOnScreen).toList();
      expect(visible.isNotEmpty, isTrue);

      for (final ch in visible) {
        expect(ch.reReference, isNotNull, reason: '${ch.name} must have a reference electrode');
        expect(ch.reReference.trim().isNotEmpty, isTrue);
        expect(ch.reReference, isNot(equals('None')));
      }
    });
  });

  group('AASM Auto-applied Display Filters', () {
    test('applyAasmFiltersToChannel applies 0.3-35Hz to EEG, EOG, and ECG, and 10-100Hz to EMG', () {
      final eeg = ChannelConfig(name: 'C3-A2');
      final eog = ChannelConfig(name: 'E1-M2');
      final ecg = ChannelConfig(name: 'ECG');
      final emg = ChannelConfig(name: 'CHIN1-CHIN2');
      final resp = ChannelConfig(name: 'Flow');

      applyAasmFiltersToChannel(eeg);
      applyAasmFiltersToChannel(eog);
      applyAasmFiltersToChannel(ecg);
      applyAasmFiltersToChannel(emg);
      applyAasmFiltersToChannel(resp);

      // EEG: 0.3 - 35 Hz
      expect(eeg.filterHpEnabled, isTrue);
      expect(eeg.filterHpCutoff, equals(0.3));
      expect(eeg.filterLpEnabled, isTrue);
      expect(eeg.filterLpCutoff, equals(35.0));

      // EOG: 0.3 - 35 Hz
      expect(eog.filterHpEnabled, isTrue);
      expect(eog.filterHpCutoff, equals(0.3));
      expect(eog.filterLpEnabled, isTrue);
      expect(eog.filterLpCutoff, equals(35.0));

      // ECG: 0.3 - 35 Hz
      expect(ecg.filterHpEnabled, isTrue);
      expect(ecg.filterHpCutoff, equals(0.3));
      expect(ecg.filterLpEnabled, isTrue);
      expect(ecg.filterLpCutoff, equals(35.0));

      // EMG: 10 - 100 Hz
      expect(emg.filterHpEnabled, isTrue);
      expect(emg.filterHpCutoff, equals(10.0));
      expect(emg.filterLpEnabled, isTrue);
      expect(emg.filterLpCutoff, equals(100.0));

      // Respiratory: left disabled
      expect(resp.filterHpEnabled, isFalse);
      expect(resp.filterLpEnabled, isFalse);
    });

    test('defaultChannelConfig automatically initializes channels with AASM filters', () {
      final eeg = AppConfig.defaultChannelConfig('F4', 0, 10);
      final eog = AppConfig.defaultChannelConfig('EOG1', 1, 10);
      final emg = AppConfig.defaultChannelConfig('EMG1', 2, 10);
      final ecg = AppConfig.defaultChannelConfig('ECG', 3, 10);

      expect(eeg.filterHpEnabled, isTrue);
      expect(eeg.filterHpCutoff, equals(0.3));
      expect(eeg.filterLpEnabled, isTrue);
      expect(eeg.filterLpCutoff, equals(35.0));

      expect(eog.filterHpEnabled, isTrue);
      expect(eog.filterHpCutoff, equals(0.3));
      expect(eog.filterLpEnabled, isTrue);
      expect(eog.filterLpCutoff, equals(35.0));

      expect(emg.filterHpEnabled, isTrue);
      expect(emg.filterHpCutoff, equals(10.0));
      expect(emg.filterLpEnabled, isTrue);
      expect(emg.filterLpCutoff, equals(100.0));

      expect(ecg.filterHpEnabled, isTrue);
      expect(ecg.filterHpCutoff, equals(0.3));
      expect(ecg.filterLpEnabled, isTrue);
      expect(ecg.filterLpCutoff, equals(35.0));
    });

    test('generateMontagePresetChannels automatically equips all derived montage channels with AASM filters', () {
      final aasmPreset = builtInMontagePresets.firstWhere((p) => p.name.contains('AASM'));
      final channels = generateMontagePresetChannels(
        preset: aasmPreset,
        availableChannels: const [
          'F3', 'F4', 'C3', 'C4', 'O1', 'O2',
          'A1', 'A2',
          'EOG1', 'EOG2',
          'EMG1', 'EMG2',
          'ECG',
        ],
      );

      final f3a2 = channels.firstWhere((c) => c.name == 'F3-A2');
      expect(f3a2.filterHpEnabled, isTrue);
      expect(f3a2.filterHpCutoff, equals(0.3));
      expect(f3a2.filterLpEnabled, isTrue);
      expect(f3a2.filterLpCutoff, equals(35.0));

      final eog = channels.firstWhere((c) => c.name.startsWith('E1') || c.name.startsWith('EOG1'));
      expect(eog.filterHpEnabled, isTrue);
      expect(eog.filterHpCutoff, equals(0.3));
      expect(eog.filterLpEnabled, isTrue);
      expect(eog.filterLpCutoff, equals(35.0));

      final emg = channels.firstWhere((c) => c.name.contains('CHIN') || c.name.contains('EMG'));
      expect(emg.filterHpEnabled, isTrue);
      expect(emg.filterHpCutoff, equals(10.0));
      expect(emg.filterLpEnabled, isTrue);
      expect(emg.filterLpCutoff, equals(100.0));
    });

    test('generateMontagePresetChannels correctly binds sourceIndex to raw GoaSleep EDF channels', () {
      final goaRawChannels = [
        'EEG F3-Ref', // 0
        'EEG F4-Ref', // 1
        'EEG CZ-Ref', // 2
        'EEG O1-Ref', // 3
        'EEG O2-Ref', // 4
        'EEG A1-Ref', // 5
        'EEG A2-Ref', // 6
        'POL EOG1',   // 7
        'POL EOG2',   // 8
        'POL EMG1',   // 9
        'POL EMG2',   // 10
        'POL EMG3',   // 11
      ];

      final aasmPreset = builtInMontagePresets.firstWhere((p) => p.name.contains('AASM'));
      final channels = generateMontagePresetChannels(
        preset: aasmPreset,
        availableChannels: goaRawChannels,
      );

      final visible = channels.where((c) => c.displayOnScreen).toList();

      final eog1 = visible.firstWhere((c) => c.name.contains('EOG1'));
      final eog2 = visible.firstWhere((c) => c.name.contains('EOG2'));
      final f4 = visible.firstWhere((c) => c.name.contains('F4'));
      final o2 = visible.firstWhere((c) => c.name.contains('O2'));

      // Crucial: sourceIndex MUST match the actual index of the active electrode in raw channels, NOT 0!
      expect(eog1.sourceIndex, equals(7), reason: 'POL EOG1 must bind to raw index 7');
      expect(eog2.sourceIndex, equals(8), reason: 'POL EOG2 must bind to raw index 8');
      expect(f4.sourceIndex, equals(1), reason: 'EEG F4-Ref must bind to raw index 1');
      expect(o2.sourceIndex, equals(4), reason: 'EEG O2-Ref must bind to raw index 4');

      expect(eog1.reReference, equals('EEG A2-Ref'));
      expect(eog2.reReference, equals('EEG A1-Ref'));
    });

    test('findPreReferencedChannel finds pre-referenced channels with colon, hyphen, or space', () {
      final available = ['E1:M2', 'E2:M2', 'EEG F3-A2', 'EMG1-EMG2', 'M1', 'M2'];
      expect(findPreReferencedChannel('E1', 'M2', available), equals('E1:M2'));
      expect(findPreReferencedChannel('E2', 'M2', available), equals('E2:M2'));
      expect(findPreReferencedChannel('F3', 'A2', available), equals('EEG F3-A2'));
      expect(findPreReferencedChannel('E1', 'M1', available), isNull);
    });

    test('AASM Sleep Standard places EOG at top and preserves pre-referenced EOG channels', () {
      final preRefChannels = [
        'E1:M2', // 0
        'E2:M2', // 1
        'F3',    // 2
        'F4',    // 3
        'C3',    // 4
        'C4',    // 5
        'O1',    // 6
        'O2',    // 7
        'M1',    // 8
        'M2',    // 9
        'CHIN1', // 10
        'CHIN2', // 11
        'ECG',   // 12
      ];

      final aasmPreset = builtInMontagePresets.firstWhere((p) => p.name.contains('AASM'));
      final channels = generateMontagePresetChannels(
        preset: aasmPreset,
        availableChannels: preRefChannels,
      );

      final visible = channels.where((c) => c.displayOnScreen).toList();
      // EOG channels should be at the top of the visible derivations (indices 0 and 1)
      expect(visible[0].name, anyOf(contains('E1'), contains('EOG1')));
      expect(visible[1].name, anyOf(contains('E2'), contains('EOG2')));

      // Pre-referenced E1:M2 and E2:M2 should bind directly to source index 0 and 1 without re-subtraction
      final e1 = visible[0];
      final e2 = visible[1];
      expect(e1.name, equals('E1:M2'));
      expect(e1.sourceIndex, equals(0));
      expect(e1.reReference, anyOf(isEmpty, equals('None')));
      expect(e1.color, equals('Blue'));

      expect(e2.name, equals('E2:M2'));
      expect(e2.sourceIndex, equals(1));
      expect(e2.reReference, anyOf(isEmpty, equals('None')));
      expect(e2.color, equals('Blue'));
    });
  });
}

