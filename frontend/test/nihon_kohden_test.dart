import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ccs_sleep_studio/src/marker_io.dart';
import 'package:ccs_sleep_studio/src/nihon_kohden.dart';
import 'package:flutter_test/flutter_test.dart';

/// Writes [value] as little-endian u32 at [offset].
void _u32(Uint8List b, int offset, int value) {
  ByteData.sublistView(b).setUint32(offset, value, Endian.little);
}

void _ascii(Uint8List b, int offset, String s) {
  b.setAll(offset, ascii.encode(s));
}

int _bcd(int v) => ((v ~/ 10) << 4) | (v % 10);

void main() {
  late Directory dir;
  late String eegPath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('nk_test_');
    eegPath = '${dir.path}/FA0001.EEG';
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('channel names come from the .21E file for every code', () {
    // Minimal EEG-1100-style file: control block → data block with 4 codes.
    final b = Uint8List(0x2000);
    _ascii(b, 0, 'EEG-1100A V01.00');
    b[0x91] = 1;
    _u32(b, 0x92, 0x400); // control block
    _u32(b, 0x400 + 18, 0x800); // data block
    b[0x800 + 0x1A] = 0xE8; // 1000 Hz
    b[0x800 + 0x1B] = 0x03;
    for (final (i, v) in [26, 8, 17, 23, 30, 27].indexed) {
      b[0x800 + 0x14 + i] = _bcd(v);
    }
    b[0x800 + 0x26] = 4;
    for (final (i, code) in [16, 34, 76, 102 - 26].indexed) {
      b[0x800 + 0x27 + i * 10] = code;
    }
    File(eegPath).writeAsBytesSync(b);
    File('${dir.path}/FA0001.21E').writeAsStringSync(
      '[ELECTRODE]\r\n0016=FZ\r\n0034=M1\r\n0076=IGNORED\r\n'
      '[REFERENCE]\r\n0076=\$F3\r\n0077=\$F1\r\n[SD_DEF]\r\n0076=X\r\n',
    );

    final info = readNkHeader(eegPath)!;
    expect(info.channelCodes, [16, 34, 76, 76]);
    // [REFERENCE] overrides [ELECTRODE]; [SD_DEF] is not a name table.
    expect(info.channelLabels, ['FZ', 'M1', r'$F3', r'$F3']);
    expect(uniqueChannelLabels(info.channelLabels), ['FZ', 'M1', r'$F3', r'$F3 (2)']);
    expect(info.startTime, DateTime(2026, 8, 17, 23, 30, 27));
    expect(info.sampleRateHz, 1000);
  });

  test('default names without a .21E file', () {
    expect(nkDefaultChannelName(0), 'FP1');
    expect(nkDefaultChannelName(16), 'FZ');
    expect(nkDefaultChannelName(42), 'DC01');
    expect(nkDefaultChannelName(76), 'Mark1');
  });

  test('reads the binary .LOG with sub-second times and the .EVT triggers', () async {
    File(eegPath).writeAsStringSync('dummy');
    final log = Uint8List(0x2000);
    _ascii(log, 0, 'EEG-1200A V01.00');
    log[0x91] = 1;
    _u32(log, 0x92, 0x400);
    _u32(log, 0x92 + 22 * 20, 0x1000); // sub-log block
    log[0x400 + 0x12] = 2;
    log[0x1000 + 0x12] = 2;
    _ascii(log, 0x400 + 0x14, 'REC START');
    _ascii(log, 0x400 + 0x14 + 20, '000000(260817233027)');
    _ascii(log, 0x400 + 0x14 + 45, 'Stim On');
    _ascii(log, 0x400 + 0x14 + 45 + 20, '014411(260818011438)');
    _ascii(log, 0x1000 + 0x14 + 20, '0000000000');
    _ascii(log, 0x1000 + 0x14 + 45 + 20, '0000016600');
    File('${dir.path}/FA0001.LOG').writeAsBytesSync(log);
    File('${dir.path}/FA0001.EVT').writeAsStringSync(
      'Tmu\tCode\tTriNo\r\n6251675000\t1\t259\r\n',
    );

    final logEvents = readNkLogEvents(eegPath);
    expect(logEvents.map((e) => e.label), ['REC START', 'Stim On']);
    expect(logEvents[1].startSec, closeTo(6251.0166, 1e-6));

    final trig = readNkEvtEvents(eegPath);
    expect(trig.single.label, 'Trigger 259');
    expect(trig.single.startSec, closeTo(6251.675, 1e-9));

    final all = await tryLoadAllMarkers(eegPath);
    expect(all.map((e) => e.label), containsAll(['REC START', 'Stim On', 'Trigger 259']));
  });

  test('video index: cameras, files, times and missing files', () {
    File(eegPath).writeAsStringSync('dummy');
    Directory('${dir.path}/Video/FA0001.VOR').createSync(recursive: true);
    Directory('${dir.path}/Video/FA0001.VO2').createSync(recursive: true);
    File('${dir.path}/Video/FA0001.VOR/0001Q600.m2t').writeAsStringSync('x');
    File('${dir.path}/Video/FA0001.VO2/0001Q600.m2t').writeAsStringSync('x');
    File('${dir.path}/Video/FA0001.VO2/0001Q601.m2t').writeAsStringSync('x');
    File('${dir.path}/FA0001.VF2').writeAsStringSync(
      '﻿<?xml version="1.0" encoding="utf-8"?><DigitalVideo><VideoInformation>'
      '<Original01>'
      r'<VideoElement><VideoFile>FA0001.VOR\0001Q600.m2t</VideoFile>'
      '<StartTime>202608172330279500</StartTime><EndTime>202608180030281200</EndTime></VideoElement>'
      r'<VideoElement><VideoFile>FA0001.VOR\0001Q601.m2t</VideoFile>'
      '<StartTime>202608180030302700</StartTime><EndTime>202608180130308800</EndTime></VideoElement>'
      '</Original01><Original02>'
      r'<VideoElement><VideoFile>FA0001.VO2\0001Q600.m2t</VideoFile>'
      '<StartTime>202608172330345100</StartTime><EndTime>202608180030355500</EndTime></VideoElement>'
      r'<VideoElement><VideoFile>FA0001.VO2\0001Q601.m2t</VideoFile>'
      '<StartTime>202608180030375100</StartTime><EndTime>202608180130380800</EndTime></VideoElement>'
      '</Original02></VideoInformation></DigitalVideo>',
    );

    final index = readNkVideoIndex(eegPath, DateTime(2026, 8, 17, 23, 30, 27))!;
    expect(index.cameras.length, 2);
    final cam1 = index.cameras[0];
    expect(cam1.name, 'Camera 1 (VOR)');
    expect(cam1.segments[0].startSec, closeTo(0.95, 1e-6));
    expect(cam1.segments[0].endSec, closeTo(3601.12, 1e-6));
    expect(cam1.segments[0].available, isTrue);
    expect(cam1.segments[1].available, isFalse, reason: 'VOR/0001Q601 is missing');
    expect(cam1.segmentIndexAt(0.5), -1);
    expect(cam1.segmentIndexAt(10), 0);
    expect(cam1.segmentIndexAt(3602), -1, reason: 'gap between files');
    expect(cam1.segmentIndexAt(3700), 1);
    final cam2 = index.cameras[1];
    expect(cam2.segments[1].path, endsWith('FA0001.VO2/0001Q601.m2t'));
    cam2.offsetSec = -10;
    expect(cam2.segmentIndexAt(10), -1);
  });
}
