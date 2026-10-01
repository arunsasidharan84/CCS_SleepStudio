import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'models.dart';

class EdfLoader {
  LoadedEeg load(String path, {bool scaleVoltsToMicrovolts = false}) {
    final bytes = File(path).readAsBytesSync();
    if (bytes.length < 256) {
      throw const FormatException('EDF header is shorter than 256 bytes.');
    }

    final base = _AsciiHeader(bytes);
    final recordingStartTime = _parseEdfStartTime(
      base.textAt(168, 8),
      base.textAt(176, 8),
    );
    final headerBytes = base.intAt(184, 8);
    final dataRecordCount = base.optionalIntAt(236, 8) ?? -1;
    final dataRecordSeconds = base.doubleAt(244, 8);
    final signalCount = base.intAt(252, 4);
    if (signalCount <= 0 || headerBytes < 256 + signalCount * 256) {
      throw const FormatException('EDF signal header is invalid.');
    }

    var offset = 256;
    final labels = _readSignalStrings(bytes, offset, signalCount, 16);
    offset += signalCount * 16;
    offset += signalCount * 80; // transducer
    final physicalDimensions = _readSignalStrings(
      bytes,
      offset,
      signalCount,
      8,
    );
    offset += signalCount * 8;
    final physicalMin = _readSignalDoubles(bytes, offset, signalCount, 8);
    offset += signalCount * 8;
    final physicalMax = _readSignalDoubles(bytes, offset, signalCount, 8);
    offset += signalCount * 8;
    final digitalMin = _readSignalDoubles(bytes, offset, signalCount, 8);
    offset += signalCount * 8;
    final digitalMax = _readSignalDoubles(bytes, offset, signalCount, 8);
    offset += signalCount * 8;
    offset += signalCount * 80; // prefiltering
    final samplesPerRecord = _readSignalInts(bytes, offset, signalCount, 8);

    final totalSamplesPerRecord = samplesPerRecord.fold<int>(
      0,
      (a, b) => a + b,
    );
    final records = dataRecordCount > 0
        ? dataRecordCount
        : ((bytes.length - headerBytes) / (totalSamplesPerRecord * 2)).floor();
    if (records <= 0) {
      throw const FormatException('EDF contains no complete data records.');
    }

    final keptSignalIndexes = <int>[];
    for (var index = 0; index < signalCount; index++) {
      if (_isDisplaySignal(labels[index]) &&
          samplesPerRecord[index] > 0 &&
          digitalMax[index] != digitalMin[index]) {
        keptSignalIndexes.add(index);
      }
    }
    if (keptSignalIndexes.isEmpty) {
      throw const FormatException(
        'EDF contains no displayable signal channels.',
      );
    }

    final keptBySignalIndex = {
      for (
        var displayIndex = 0;
        displayIndex < keptSignalIndexes.length;
        displayIndex++
      )
        keptSignalIndexes[displayIndex]: displayIndex,
    };
    final channelSamples = [
      for (final signalIndex in keptSignalIndexes)
        List<double>.filled(records * samplesPerRecord[signalIndex], 0),
    ];

    final data = ByteData.sublistView(bytes);
    var cursor = headerBytes;
    for (var record = 0; record < records; record++) {
      for (var channel = 0; channel < signalCount; channel++) {
        final samplesInRecord = samplesPerRecord[channel];
        final gain =
            (physicalMax[channel] - physicalMin[channel]) /
            (digitalMax[channel] - digitalMin[channel]);
        final intercept = physicalMin[channel] - gain * digitalMin[channel];
        final displayIndex = keptBySignalIndex[channel];
        for (var sample = 0; sample < samplesInRecord; sample++) {
          if (cursor + 2 > bytes.length) {
            throw const FormatException('EDF data ended mid-record.');
          }
          final digital = data.getInt16(cursor, Endian.little);
          cursor += 2;
          if (displayIndex == null) {
            continue;
          }
          var physical = digital * gain + intercept;
          if (scaleVoltsToMicrovolts ||
              physicalDimensions[channel].toLowerCase() == 'v') {
            physical *= 1e6;
          }
          channelSamples[displayIndex][record * samplesInRecord + sample] =
              physical;
        }
      }
    }

    // Channels can have different rates (EEG 200 Hz, flow/effort 100 Hz,
    // SpO2 1 Hz…); the viewer uses one rate for every channel, so resample
    // the others to the rate most channels share.
    final targetSpr = edfCommonSamplesPerRecord([
      for (final index in keptSignalIndexes) samplesPerRecord[index],
    ]);
    for (var i = 0; i < keptSignalIndexes.length; i++) {
      final spr = samplesPerRecord[keptSignalIndexes[i]];
      if (spr != targetSpr) {
        channelSamples[i] = edfResampleLinear(
          channelSamples[i],
          spr,
          targetSpr,
          records,
        );
      }
    }
    final sampleRate = targetSpr / math.max(dataRecordSeconds, 1e-9);
    final displayLabels = [
      for (final index in keptSignalIndexes) labels[index],
    ];
    return LoadedEeg(
      sampleRateHz: sampleRate,
      channelLabels: displayLabels,
      channelSamples: channelSamples,
      recordingStartTime: recordingStartTime,
      sourceDescription:
          '${displayLabels.length} channels, ${sampleRate.toStringAsFixed(1)} Hz, ${(records * dataRecordSeconds / 60).toStringAsFixed(1)} min',
    );
  }

  static DateTime? readStartDateTime(String path) {
    try {
      final file = File(path).openSync();
      try {
        final fixed = Uint8List(256);
        file.readIntoSync(fixed);
        final header = _AsciiHeader(fixed);
        return _parseEdfStartTime(header.textAt(168, 8), header.textAt(176, 8));
      } finally {
        file.closeSync();
      }
    } catch (_) {
      return null;
    }
  }

  static List<String> _readSignalStrings(
    Uint8List bytes,
    int offset,
    int count,
    int width,
  ) {
    return [
      for (var index = 0; index < count; index++)
        ascii
            .decode(
              bytes.sublist(
                offset + index * width,
                offset + (index + 1) * width,
              ),
            )
            .trim(),
    ];
  }

  static List<int> _readSignalInts(
    Uint8List bytes,
    int offset,
    int count,
    int width,
  ) {
    return [
      for (var index = 0; index < count; index++)
        int.parse(
          ascii
              .decode(
                bytes.sublist(
                  offset + index * width,
                  offset + (index + 1) * width,
                ),
              )
              .trim(),
        ),
    ];
  }

  static List<double> _readSignalDoubles(
    Uint8List bytes,
    int offset,
    int count,
    int width,
  ) {
    return [
      for (var index = 0; index < count; index++)
        double.parse(
          ascii
              .decode(
                bytes.sublist(
                  offset + index * width,
                  offset + (index + 1) * width,
                ),
              )
              .trim()
              .replaceAll(',', '.'),
        ),
    ];
  }
}

DateTime? _parseEdfStartTime(String dateText, String timeText) {
  final dateParts = dateText.split(RegExp(r'[./:-]'));
  final timeParts = timeText.split(RegExp(r'[./:-]'));
  if (dateParts.length < 3 || timeParts.length < 2) return null;
  final day = int.tryParse(dateParts[0]);
  final month = int.tryParse(dateParts[1]);
  final yearRaw = int.tryParse(dateParts[2]);
  final hour = int.tryParse(timeParts[0]);
  final minute = int.tryParse(timeParts[1]);
  final second = timeParts.length >= 3 ? int.tryParse(timeParts[2]) ?? 0 : 0;
  if (day == null ||
      month == null ||
      yearRaw == null ||
      hour == null ||
      minute == null) {
    return null;
  }
  final year = yearRaw < 100
      ? (yearRaw >= 85 ? 1900 + yearRaw : 2000 + yearRaw)
      : yearRaw;
  try {
    return DateTime(year, month, day, hour, minute, second);
  } catch (_) {
    return null;
  }
}

bool _isDisplaySignal(String label) {
  final normalized = label.toLowerCase();
  return !normalized.contains('annotation') &&
      !normalized.contains('status') &&
      !normalized.contains('marker');
}

class _AsciiHeader {
  const _AsciiHeader(this.bytes);

  final Uint8List bytes;

  int intAt(int offset, int width) => int.parse(_textAt(offset, width));
  int? optionalIntAt(int offset, int width) {
    final text = _textAt(offset, width);
    return text.isEmpty ? null : int.parse(text);
  }

  double doubleAt(int offset, int width) =>
      double.parse(_textAt(offset, width).replaceAll(',', '.'));

  String textAt(int offset, int width) => _textAt(offset, width);

  String _textAt(int offset, int width) {
    return ascii.decode(bytes.sublist(offset, offset + width)).trim();
  }
}

/// Samples per record shared by most channels (ties: the higher rate).
int edfCommonSamplesPerRecord(List<int> rates) {
  var best = 0;
  var bestCount = 0;
  for (final r in rates) {
    final count = rates.where((x) => x == r).length;
    if (count > bestCount || (count == bestCount && r > best)) {
      best = r;
      bestCount = count;
    }
  }
  return best;
}

/// Linear-interpolation resampling from [fromSpr] to [toSpr] samples per
/// data record, keeping the time axis (sample i at i / rate).
List<double> edfResampleLinear(
  List<double> src,
  int fromSpr,
  int toSpr,
  int records,
) {
  final nOut = records * toSpr;
  if (src.isEmpty || fromSpr <= 0 || toSpr <= 0) {
    return List<double>.filled(nOut, 0);
  }
  final ratio = fromSpr / toSpr;
  final last = src.length - 1;
  return List<double>.generate(nOut, (i) {
    final pos = i * ratio;
    final i0 = math.min(pos.floor(), last);
    final i1 = math.min(i0 + 1, last);
    final frac = (pos - i0).clamp(0.0, 1.0).toDouble();
    return src[i0] + (src[i1] - src[i0]) * frac;
  }, growable: false);
}
