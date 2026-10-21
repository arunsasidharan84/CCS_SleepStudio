import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/edf_loader.dart';
import 'package:ccs_sleep_studio/src/edf_utilities_dialog.dart';

void main() {
  test('loads a minimal EDF file', () {
    final file = File('${Directory.systemTemp.path}/minimal_sleep_eeg.edf');
    file.writeAsBytesSync(_minimalEdf());

    final loaded = EdfLoader().load(file.path);

    expect(loaded.channelLabels, ['C3-M2']);
    expect(loaded.sampleRateHz, 2);
    expect(loaded.channelSamples.single, hasLength(2));
    expect(loaded.channelSamples.single.first, closeTo(-100, 0.1));
    expect(loaded.channelSamples.single.last, closeTo(100, 0.1));
  });

  test('skips EDF annotation channels', () {
    final file = File('${Directory.systemTemp.path}/minimal_sleep_eeg_ann.edf');
    file.writeAsBytesSync(_minimalEdfWithAnnotation());

    final loaded = EdfLoader().load(file.path);

    expect(loaded.channelLabels, ['C3-M2']);
    expect(loaded.channelSamples, hasLength(1));
  });

  test('processEdfFile anonymizes patient header and streams data with progress', () async {
    final tempDir = Directory.systemTemp.createTempSync('edf_anonymize_test_');
    final inPath = '${tempDir.path}/original.edf';
    final outPath = '${tempDir.path}/anonymized.edf';
    File(inPath).writeAsBytesSync(_minimalEdf());

    final progressReports = <double>[];
    final statusMessages = <String>[];
    final options = EdfTransformOptions()
      ..anonymizeHeader = true
      ..patientId = 'ANON_ID_123'
      ..patientName = 'Subject_123';

    await processEdfFile(
      inPath,
      outPath,
      options,
      onProgress: (p, msg) {
        progressReports.add(p);
        statusMessages.add(msg);
      },
    );

    expect(File(outPath).existsSync(), isTrue);
    expect(progressReports, isNotEmpty);
    expect(progressReports.last, 1.0);

    // Verify output EDF header anonymized
    final outBytes = File(outPath).readAsBytesSync();
    final patientIdInHeader = utf8.decode(outBytes.sublist(8, 88)).trim();
    final patientNameInHeader = utf8.decode(outBytes.sublist(88, 168)).trim();
    expect(patientIdInHeader, 'ANON_ID_123');
    expect(patientNameInHeader, 'Subject_123');

    // Verify readable by EdfLoader
    final loaded = EdfLoader().load(outPath);
    expect(loaded.channelLabels, ['C3-M2']);
    expect(loaded.channelSamples.single, hasLength(2));

    tempDir.deleteSync(recursive: true);
  });

  test('loads original ScoringHero night EDF example when available', () {
    final file = File(
      '/Users/arunsasidharan/Code/ActiveProjects/CCS_SleepScoring/ScoringHero-0.2.4/example_data/night_recording.edf',
    );
    if (!file.existsSync()) {
      return;
    }

    final loaded = EdfLoader().load(file.path);

    expect(loaded.channelLabels, isNotEmpty);
    expect(loaded.channelSamples, hasLength(loaded.channelLabels.length));
    expect(loaded.sampleRateHz, greaterThan(0));
    expect(loaded.durationSeconds, greaterThan(30));
    expect(loaded.channelSamples.first, isNotEmpty);
  });
}

Uint8List _minimalEdf() {
  final header = StringBuffer()
    ..write(_field('0', 8))
    ..write(_field('Test patient', 80))
    ..write(_field('Test recording', 80))
    ..write(_field('25.05.26', 8))
    ..write(_field('12.00.00', 8))
    ..write(_field('512', 8))
    ..write(_field('', 44))
    ..write(_field('1', 8))
    ..write(_field('1', 8))
    ..write(_field('1', 4))
    ..write(_field('C3-M2', 16))
    ..write(_field('', 80))
    ..write(_field('uV', 8))
    ..write(_field('-100', 8))
    ..write(_field('100', 8))
    ..write(_field('-32768', 8))
    ..write(_field('32767', 8))
    ..write(_field('', 80))
    ..write(_field('2', 8))
    ..write(_field('', 32));

  final data = ByteData(4)
    ..setInt16(0, -32768, Endian.little)
    ..setInt16(2, 32767, Endian.little);
  return Uint8List.fromList([
    ...ascii.encode(header.toString()),
    ...data.buffer.asUint8List(),
  ]);
}

String _field(String value, int width) {
  return value.padRight(width).substring(0, width);
}

Uint8List _minimalEdfWithAnnotation() {
  final header = StringBuffer()
    ..write(_field('0', 8))
    ..write(_field('Test patient', 80))
    ..write(_field('Test recording', 80))
    ..write(_field('25.05.26', 8))
    ..write(_field('12.00.00', 8))
    ..write(_field('768', 8))
    ..write(_field('', 44))
    ..write(_field('1', 8))
    ..write(_field('1', 8))
    ..write(_field('2', 4))
    ..write(_field('C3-M2', 16))
    ..write(_field('EDF Annotations', 16))
    ..write(_field('', 80))
    ..write(_field('', 80))
    ..write(_field('uV', 8))
    ..write(_field('', 8))
    ..write(_field('-100', 8))
    ..write(_field('-1', 8))
    ..write(_field('100', 8))
    ..write(_field('1', 8))
    ..write(_field('-32768', 8))
    ..write(_field('-32768', 8))
    ..write(_field('32767', 8))
    ..write(_field('32767', 8))
    ..write(_field('', 80))
    ..write(_field('', 80))
    ..write(_field('2', 8))
    ..write(_field('2', 8))
    ..write(_field('', 32))
    ..write(_field('', 32));

  final data = ByteData(8)
    ..setInt16(0, -32768, Endian.little)
    ..setInt16(2, 32767, Endian.little)
    ..setInt16(4, 0, Endian.little)
    ..setInt16(6, 0, Endian.little);
  return Uint8List.fromList([
    ...ascii.encode(header.toString()),
    ...data.buffer.asUint8List(),
  ]);
}
