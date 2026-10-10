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
  });
}
