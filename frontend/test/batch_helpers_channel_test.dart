import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/batch_helpers.dart';

void main() {
  test('isLikelyEegChannel correctly identifies EEG vs auxiliary channels', () {
    // EEG channels
    expect(isLikelyEegChannel('F3'), isTrue);
    expect(isLikelyEegChannel('F4'), isTrue);
    expect(isLikelyEegChannel('C3'), isTrue);
    expect(isLikelyEegChannel('C4'), isTrue);
    expect(isLikelyEegChannel('Cz'), isTrue);
    expect(isLikelyEegChannel('O1'), isTrue);
    expect(isLikelyEegChannel('O2'), isTrue);
    expect(isLikelyEegChannel('AF7'), isTrue);
    expect(isLikelyEegChannel('AF8'), isTrue);
    expect(isLikelyEegChannel('EEG C3-Ref'), isTrue);
    expect(isLikelyEegChannel('POL Fp1'), isTrue);

    // Non-EEG channels
    expect(isLikelyEegChannel('ECG'), isFalse);
    expect(isLikelyEegChannel('EKG1'), isFalse);
    expect(isLikelyEegChannel('EMG'), isFalse);
    expect(isLikelyEegChannel('EOG-L'), isFalse);
    expect(isLikelyEegChannel('PPG'), isFalse);
    expect(isLikelyEegChannel('SpO2'), isFalse);
    expect(isLikelyEegChannel('Airflow'), isFalse);
    expect(isLikelyEegChannel('M1'), isFalse);
    expect(isLikelyEegChannel('M2'), isFalse);
    expect(isLikelyEegChannel('Status'), isFalse);
  });

  test('extractRecordingChannels extracts channels quickly from EDF header', () async {
    final tempFile = File('${Directory.systemTemp.path}/test_header_extract.edf');
    tempFile.writeAsBytesSync(_makeTestEdf(['F3', 'F4', 'C3', 'C4', 'PPG', 'EDF Annotations']));

    final channels = await extractRecordingChannels(tempFile.path);
    expect(channels, ['F3', 'F4', 'C3', 'C4', 'PPG']);

    if (tempFile.existsSync()) {
      tempFile.deleteSync();
    }
  });
}

Uint8List _makeTestEdf(List<String> labels) {
  final header = StringBuffer()
    ..write(_field('0', 8))
    ..write(_field('Test patient', 80))
    ..write(_field('Test recording', 80))
    ..write(_field('25.05.26', 8))
    ..write(_field('12.00.00', 8))
    ..write(_field((256 + labels.length * 256).toString(), 8))
    ..write(_field('', 44))
    ..write(_field('1', 8))
    ..write(_field('1', 8))
    ..write(_field(labels.length.toString(), 4));

  for (final l in labels) {
    header.write(_field(l, 16));
  }
  for (var i = 0; i < labels.length; i++) {
    header.write(_field('AgAgCl', 80));
  }
  for (var i = 0; i < labels.length; i++) {
    header.write(_field('uV', 8));
  }
  for (var i = 0; i < labels.length; i++) {
    header.write(_field('-100', 8));
  }
  for (var i = 0; i < labels.length; i++) {
    header.write(_field('100', 8));
  }
  for (var i = 0; i < labels.length; i++) {
    header.write(_field('-32768', 8));
  }
  for (var i = 0; i < labels.length; i++) {
    header.write(_field('32767', 8));
  }
  for (var i = 0; i < labels.length; i++) {
    header.write(_field('None', 80));
  }
  for (var i = 0; i < labels.length; i++) {
    header.write(_field('2', 8));
  }
  for (var i = 0; i < labels.length; i++) {
    header.write(_field('', 32));
  }

  return Uint8List.fromList(ascii.encode(header.toString()));
}

String _field(String value, int width) {
  if (value.length >= width) {
    return value.substring(0, width);
  }
  return value.padRight(width, ' ');
}
