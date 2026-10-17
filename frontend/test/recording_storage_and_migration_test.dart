import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/legacy_file_migration.dart';
import 'package:ccs_sleep_studio/src/models.dart';
import 'package:ccs_sleep_studio/src/recording_storage.dart';
import 'package:ccs_sleep_studio/src/scoring_io.dart';
import 'package:ccs_sleep_studio/src/psg_report_data.dart';
import 'package:ccs_sleep_studio/src/marker_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RecordingStorage & Preferences', () {
    test('defaults to edf and persists selection', () async {
      final temp = await Directory.systemTemp.createTemp('ccs_storage_test_');
      final prefFile = '${temp.path}/storage.ccssettings';

      await RecordingStorage.loadPreferences(path: prefFile);
      expect(RecordingStorage.preferredFormat, RecordingFileFormat.edf);

      await RecordingStorage.setPreferredFormat(RecordingFileFormat.ccseeg, path: prefFile);
      expect(RecordingStorage.preferredFormat, RecordingFileFormat.ccseeg);

      await RecordingStorage.loadPreferences(path: prefFile);
      expect(RecordingStorage.preferredFormat, RecordingFileFormat.ccseeg);

      final withExt = RecordingStorage.withExtension('sample.edf');
      expect(withExt, 'sample.ccseeg');

      await temp.delete(recursive: true);
    });

    test('saves LoadedEeg to CCSEEG and EDF+ with .ccsmeta sidecar', () async {
      final temp = await Directory.systemTemp.createTemp('ccs_save_test_');
      final loaded = LoadedEeg(
        sampleRateHz: 100.0,
        channelLabels: ['C3', 'C4'],
        channelSamples: [
          List<double>.generate(1000, (i) => (i % 50).toDouble()),
          List<double>.generate(1000, (i) => -(i % 50).toDouble()),
        ],
        sourceDescription: 'Test recording',
      );

      final ccsPath = '${temp.path}/recording.ccseeg';
      await RecordingStorage.save(
        loaded: loaded,
        path: ccsPath,
        markers: [
          const ScoredEvent(digit: 8, key: 'F8', label: 'Spindle', startSec: 1.0, endSec: 2.0),
        ],
      );
      expect(File(ccsPath).existsSync(), isTrue);

      final edfPath = '${temp.path}/recording.edf';
      await RecordingStorage.save(
        loaded: loaded,
        path: edfPath,
        markers: [
          const ScoredEvent(digit: 8, key: 'F8', label: 'Spindle', startSec: 1.0, endSec: 2.0),
        ],
      );
      expect(File(edfPath).existsSync(), isTrue);
      final metaFile = File('$edfPath.ccsmeta');
      expect(metaFile.existsSync(), isTrue);
      final metaContent = await metaFile.readAsString();
      expect(metaContent, contains('"schema":"ccs-recording-metadata-v1"'));
      expect(metaContent, contains('"data_file":"recording.edf"'));

      await temp.delete(recursive: true);
    });
  });

  group('LegacyFileMigration', () {
    test('plans and applies migration for legacy filenames', () async {
      final temp = await Directory.systemTemp.createTemp('ccs_migration_test_');

      // Create dummy legacy files
      final legacyConfig = File('${temp.path}/night1.config.json');
      await legacyConfig.writeAsString('{"sampleRate": 250}');

      final legacyScoring = File('${temp.path}/night1_scoring.json');
      await legacyScoring.writeAsString('[{"epoch": 1, "stage": "N2"}]');

      final legacySpindles = File('${temp.path}/night1_spindles.json');
      await legacySpindles.writeAsString('{"events": []}');

      final legacySlowWaves = File('${temp.path}/night1_slow_waves.json');
      await legacySlowWaves.writeAsString('{"events": []}');

      final legacyResp = File('${temp.path}/night1_respiratory.json');
      await legacyResp.writeAsString('{"summary": {}}');

      final plan = await LegacyFileMigration.plan(temp.path);
      expect(plan[legacyConfig.path], '${temp.path}/night1.ccsconfig');
      expect(plan[legacyScoring.path], '${temp.path}/night1.ccsscoring');
      expect(plan[legacySpindles.path], '${temp.path}/night1.ccsspindles');
      expect(plan[legacySlowWaves.path], '${temp.path}/night1.ccsslowwaves');
      expect(plan[legacyResp.path], '${temp.path}/night1.ccsrespiratory');

      await LegacyFileMigration.apply(temp.path, plan);

      expect(File('${temp.path}/night1.ccsconfig').existsSync(), isTrue);
      expect(File('${temp.path}/night1.ccsscoring').existsSync(), isTrue);
      expect(File('${temp.path}/night1.ccsspindles').existsSync(), isTrue);
      expect(File('${temp.path}/night1.ccsslowwaves').existsSync(), isTrue);
      expect(File('${temp.path}/night1.ccsrespiratory').existsSync(), isTrue);
      expect(File('${temp.path}/legacy_names.ccsmigration').existsSync(), isTrue);

      // Verify that loaders seamlessly load the newly renamed files
      final loadedCfg = await tryLoadAutoConfig('${temp.path}/night1.edf');
      expect(loadedCfg, isNotNull);

      final loadedScoring = await loadScoringFile('${temp.path}/night1.ccsscoring');
      expect(loadedScoring, isNotNull);
      expect(loadedScoring!.stages.first, SleepStage.n2);

      final loadedSpindles = await loadAnalyseNidraSpindles('${temp.path}/night1.edf');
      expect(loadedSpindles, isEmpty);

      final loadedSlowWaves = await loadAnalyseNidraSlowWaves('${temp.path}/night1.edf');
      expect(loadedSlowWaves, isEmpty);

      final loadedResp = await loadPsgReport('${temp.path}/night1.ccsrespiratory');
      expect(loadedResp, isNotNull);

      await temp.delete(recursive: true);
    });
  });
}
