import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'models.dart';
import 'nihon_kohden.dart';

/// Loads markers and annotations across all compatible formats:
/// - Embedded EDF+ TAL (Time-stamped Annotation Lists) from .edf files
/// - Brain Products / BrainVision .vmrk marker files
/// - Nihon Kohden .LOG / .log event files
/// - Compumedics Profusion / Alice XML (.xml) files
/// - Tabular CSV/TSV/TXT annotation files
/// - Existing JSON scoring & event files
Future<List<ScoredEvent>> tryLoadAllMarkers(
  String activePath, {
  double sampleRateHz = 200.0,
  DateTime? recordingStartTime,
  List<String> channelLabels = const [],
}) async {
  final allEvents = <ScoredEvent>[];
  final seen = <String>{};

  void addEvent(ScoredEvent ev) {
    // Deduplicate by startSec rounded to 1ms + label
    final key = '${(ev.startSec * 1000).round()}_${ev.label.trim().toLowerCase()}';
    if (!seen.contains(key)) {
      seen.add(key);
      allEvents.add(ev);
    }
  }

  // 1. Try existing JSON scoring / event files
  try {
    final jsonEvents = await _loadJsonEvents(activePath);
    for (final ev in jsonEvents) {
      addEvent(ev);
    }
  } catch (_) {}

  // 2. If .edf, parse embedded EDF+ TAL annotations
  final lowerPath = activePath.toLowerCase();
  if (lowerPath.endsWith('.edf')) {
    try {
      final talEvents = await _loadEdfTalAnnotations(activePath);
      for (final ev in talEvents) {
        addEvent(ev);
      }
    } catch (_) {}
  }

  // 3. Companion BrainVision .vmrk file
  try {
    final vmrkEvents = await _loadBrainVisionVmrk(activePath, sampleRateHz, channelLabels);
    for (final ev in vmrkEvents) {
      addEvent(ev);
    }
  } catch (_) {}

  // 4. Companion Nihon Kohden .LOG (binary operator log) and .EVT (triggers).
  //    An NK EDF export may already carry the same log entries as EDF+
  //    annotations with slightly different sub-second times, so skip an entry
  //    when the same label already exists within one second.
  void addNkEvent(ScoredEvent ev) {
    final label = ev.label.trim().toLowerCase();
    final dup = allEvents.any((e) =>
        e.label.trim().toLowerCase() == label &&
        (e.startSec - ev.startSec).abs() < 1.0);
    if (!dup) addEvent(ev);
  }

  try {
    var nkEvents = readNkLogEvents(activePath);
    if (nkEvents.isEmpty) {
      nkEvents = await _loadNihonKohdenLog(activePath, recordingStartTime);
    }
    for (final ev in nkEvents) {
      addNkEvent(ev);
    }
  } catch (_) {}
  try {
    for (final ev in readNkEvtEvents(activePath)) {
      addNkEvent(ev);
    }
  } catch (_) {}

  // 5. Companion XML (Profusion / Alice / Compumedics)
  try {
    final xmlEvents = await _loadXmlEvents(activePath);
    for (final ev in xmlEvents) {
      addEvent(ev);
    }
  } catch (_) {}

  // 6. Companion CSV / TSV / TXT
  try {
    final csvEvents = await _loadTabularEvents(activePath, recordingStartTime);
    for (final ev in csvEvents) {
      addEvent(ev);
    }
  } catch (_) {}

  // 7. Companion AnalyseNidra Spindles
  try {
    final anSpindles = await loadAnalyseNidraSpindles(activePath);
    for (final ev in anSpindles) {
      addEvent(ev);
    }
  } catch (_) {}

  // 8. Companion AnalyseNidra Slow-Waves
  try {
    final anSlowWaves = await loadAnalyseNidraSlowWaves(activePath);
    for (final ev in anSlowWaves) {
      addEvent(ev);
    }
  } catch (_) {}

  // Assign coherent digits (color indexing 0-9) to event labels
  return _assignEventDigits(allEvents);
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. JSON Events
// ─────────────────────────────────────────────────────────────────────────────

Future<List<ScoredEvent>> _loadJsonEvents(String activePath) async {
  final dotIdx = activePath.lastIndexOf('.');
  final base = dotIdx >= 0 ? activePath.substring(0, dotIdx) : activePath;

  final candidates = [
    '${base}_scoring.json',
    '$base.json',
    '${base}_events.json',
    '$base.events.json',
  ];

  for (final candidate in candidates) {
    final file = File(candidate);
    if (!file.existsSync()) continue;
    try {
      final content = await file.readAsString();
      final dynamic json = jsonDecode(content);
      if (json is List && json.length >= 2 && json[1] is List) {
        return _parseEventsList(json[1] as List<dynamic>);
      } else if (json is List) {
        return _parseEventsList(json);
      } else if (json is Map && json['events'] is List) {
        return _parseEventsList(json['events'] as List<dynamic>);
      }
    } catch (_) {}
  }
  return const [];
}

List<ScoredEvent> _parseEventsList(List<dynamic> list) {
  final result = <ScoredEvent>[];
  for (final item in list) {
    if (item is Map<String, dynamic>) {
      result.add(ScoredEvent.fromJson(item));
    } else if (item is List && item.length >= 5) {
      result.add(ScoredEvent(
        digit: (item[0] as num?)?.toInt() ?? 0,
        key: item[1]?.toString() ?? '',
        label: item[2]?.toString() ?? 'Event',
        startSec: (item[3] as num?)?.toDouble() ?? 0.0,
        endSec: (item[4] as num?)?.toDouble() ?? 0.0,
      ));
    }
  }
  return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. EDF+ TAL (Time-stamped Annotation Lists)
// ─────────────────────────────────────────────────────────────────────────────

Future<List<ScoredEvent>> _loadEdfTalAnnotations(String edfPath) async {
  final file = File(edfPath);
  if (!file.existsSync()) return const [];

  final raf = await file.open(mode: FileMode.read);
  try {
    final headerBuf = Uint8List(256);
    final readHdr = await raf.readInto(headerBuf);
    if (readHdr < 256) return const [];

    final headerBytesStr = ascii.decode(headerBuf.sublist(184, 192)).trim();
    final headerBytes = int.tryParse(headerBytesStr) ?? 0;
    final recordCountStr = ascii.decode(headerBuf.sublist(236, 244)).trim();
    final dataRecordCount = int.tryParse(recordCountStr) ?? 0;
    final signalCountStr = ascii.decode(headerBuf.sublist(252, 256)).trim();
    final signalCount = int.tryParse(signalCountStr) ?? 0;

    if (signalCount <= 0 || headerBytes < 256 + signalCount * 256) {
      return const [];
    }

    final signalHdrLen = headerBytes - 256;
    final signalHdrBuf = Uint8List(signalHdrLen);
    final readSig = await raf.readInto(signalHdrBuf);
    if (readSig < signalHdrLen) return const [];

    // Parse channel labels (16 bytes each)
    final labels = <String>[];
    for (var i = 0; i < signalCount; i++) {
      final start = i * 16;
      labels.add(ascii.decode(signalHdrBuf.sublist(start, start + 16)).trim());
    }

    // Samples per record (8 bytes each, at offset 216 * signalCount)
    final samplesPerRecordOffset = signalCount * (16 + 80 + 8 + 8 + 8 + 8 + 80);
    final samplesPerRecord = <int>[];
    for (var i = 0; i < signalCount; i++) {
      final start = samplesPerRecordOffset + i * 8;
      final sStr = ascii.decode(signalHdrBuf.sublist(start, start + 8)).trim();
      samplesPerRecord.add(int.tryParse(sStr) ?? 0);
    }

    // Find annotation channel index
    int annotChanIdx = -1;
    for (var i = 0; i < signalCount; i++) {
      final lower = labels[i].toLowerCase();
      if (lower.contains('annotation') || lower.contains('tal')) {
        annotChanIdx = i;
        break;
      }
    }
    if (annotChanIdx < 0 || samplesPerRecord[annotChanIdx] <= 0) {
      return const [];
    }

    final totalRecordBytes = samplesPerRecord.fold<int>(0, (sum, s) => sum + s * 2);
    if (totalRecordBytes <= 0) return const [];

    int annotOffsetInRecord = 0;
    for (var i = 0; i < annotChanIdx; i++) {
      annotOffsetInRecord += samplesPerRecord[i] * 2;
    }
    final annotBytesPerRecord = samplesPerRecord[annotChanIdx] * 2;

    final fileLen = await file.length();
    final totalRecords = dataRecordCount > 0
        ? dataRecordCount
        : (fileLen - headerBytes) ~/ totalRecordBytes;

    final events = <ScoredEvent>[];

    for (var r = 0; r < totalRecords; r++) {
      final pos = headerBytes + r * totalRecordBytes + annotOffsetInRecord;
      if (pos + annotBytesPerRecord > fileLen) break;
      await raf.setPosition(pos);
      final talBuf = Uint8List(annotBytesPerRecord);
      final bytesRead = await raf.readInto(talBuf);
      if (bytesRead < annotBytesPerRecord) break;

      _parseTalRecord(talBuf, events);
    }

    return events;
  } finally {
    await raf.close();
  }
}

void _parseTalRecord(Uint8List bytes, List<ScoredEvent> outEvents) {
  var i = 0;
  final len = bytes.length;

  while (i < len) {
    if (bytes[i] == 0) {
      // Null padding until end of record
      i++;
      continue;
    }
    if (bytes[i] != 43 && bytes[i] != 45) {
      // Must start with '+' (43) or '-' (45)
      i++;
      continue;
    }

    // Find onset
    final startOnset = i;
    while (i < len && bytes[i] != 21 && bytes[i] != 20 && bytes[i] != 0) {
      i++;
    }
    if (i >= len || bytes[i] == 0) break;

    final onsetStr = ascii.decode(bytes.sublist(startOnset, i)).replaceAll(',', '.');
    final onset = double.tryParse(onsetStr) ?? 0.0;

    double duration = 0.0;
    if (bytes[i] == 21) {
      // ASCII 21: NAK separates onset and duration
      i++;
      final startDur = i;
      while (i < len && bytes[i] != 20 && bytes[i] != 0) {
        i++;
      }
      if (i >= len || bytes[i] == 0) break;
      final durStr = ascii.decode(bytes.sublist(startDur, i)).replaceAll(',', '.');
      duration = double.tryParse(durStr) ?? 0.0;
    }

    // Now at byte 20 (DC4). Parse one or more annotations terminated by 20.
    while (i < len && bytes[i] == 20) {
      i++; // skip 20
      final startText = i;
      while (i < len && bytes[i] != 20 && bytes[i] != 0) {
        i++;
      }
      if (i > startText) {
        final text = utf8.decode(bytes.sublist(startText, i), allowMalformed: true).trim();
        if (text.isNotEmpty) {
          outEvents.add(ScoredEvent(
            digit: 0,
            key: '',
            label: text,
            startSec: onset > 0 ? onset : 0.0,
            endSec: onset + duration,
            type: 'EDF+ TAL',
          ));
        }
      }
      if (i < len && bytes[i] == 20) {
        // Look ahead: next character might be another annotation or next TAL
        if (i + 1 < len && (bytes[i + 1] == 43 || bytes[i + 1] == 45 || bytes[i + 1] == 0)) {
          i++;
          break;
        }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Brain Products / BrainVision .vmrk Marker Files
// ─────────────────────────────────────────────────────────────────────────────

Future<List<ScoredEvent>> _loadBrainVisionVmrk(
  String activePath,
  double sampleRateHz,
  List<String> channelLabels,
) async {
  final dotIdx = activePath.lastIndexOf('.');
  final base = dotIdx >= 0 ? activePath.substring(0, dotIdx) : activePath;

  final candidates = [
    '$base.vmrk',
    '$base.VMRK',
    '${base}_markers.vmrk',
  ];

  File? vmrkFile;
  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync()) {
      vmrkFile = f;
      break;
    }
  }
  if (vmrkFile == null) return const [];

  final lines = await vmrkFile.readAsLines();
  final events = <ScoredEvent>[];
  String section = '';

  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith(';')) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      section = line.substring(1, line.length - 1).trim();
      continue;
    }

    if (section.toLowerCase() == 'marker infos' && line.toLowerCase().startsWith('mk')) {
      final eqIdx = line.indexOf('=');
      if (eqIdx < 0) continue;
      final val = line.substring(eqIdx + 1).trim();
      final parts = val.split(',');
      if (parts.length >= 3) {
        final type = parts[0].trim();
        final desc = parts[1].trim();
        final posSamples = int.tryParse(parts[2].trim()) ?? 1;
        final sizeSamples = parts.length >= 4 ? (int.tryParse(parts[3].trim()) ?? 0) : 0;
        final chNum = parts.length >= 5 ? (int.tryParse(parts[4].trim()) ?? 0) : 0;

        final effectiveRate = sampleRateHz > 0 ? sampleRateHz : 200.0;
        final startSec = (posSamples - 1) / effectiveRate;
        final durSec = sizeSamples / effectiveRate;

        final label = desc.isNotEmpty ? desc : type;
        final channel = (chNum > 0 && chNum <= channelLabels.length)
            ? channelLabels[chNum - 1]
            : (chNum > 0 ? 'Ch $chNum' : null);

        events.add(ScoredEvent(
          digit: 0,
          key: '',
          label: label,
          startSec: math.max(0.0, startSec),
          endSec: math.max(0.0, startSec + durSec),
          channel: channel,
          type: type.isNotEmpty ? type : 'BrainVision Marker',
        ));
      }
    }
  }

  return events;
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Nihon Kohden .LOG / .log Event Files
// ─────────────────────────────────────────────────────────────────────────────

Future<List<ScoredEvent>> _loadNihonKohdenLog(
  String activePath,
  DateTime? recordingStartTime,
) async {
  final dotIdx = activePath.lastIndexOf('.');
  final base = dotIdx >= 0 ? activePath.substring(0, dotIdx) : activePath;

  final candidates = [
    '$base.LOG',
    '$base.log',
    '${base}_event.log',
  ];

  File? logFile;
  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync()) {
      logFile = f;
      break;
    }
  }
  if (logFile == null) return const [];

  final lines = await logFile.readAsLines();
  final events = <ScoredEvent>[];

  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;

    // Pattern: HH:MM:SS(.mmm)? <text>
    final match = RegExp(r'^(\d{1,2}):(\d{2}):(\d{2})(?:\.(\d+))?\s+(.*)$').firstMatch(line);
    if (match != null) {
      final h = int.parse(match.group(1)!);
      final m = int.parse(match.group(2)!);
      final s = int.parse(match.group(3)!);
      final ms = match.group(4) != null ? double.parse('0.${match.group(4)}') : 0.0;
      final text = match.group(5)?.trim() ?? 'NK Event';

      double startSec = h * 3600.0 + m * 60.0 + s + ms;
      if (recordingStartTime != null) {
        final eventTimeOfDay = h * 3600.0 + m * 60.0 + s + ms;
        final startSecondsInDay =
            recordingStartTime.hour * 3600.0 +
            recordingStartTime.minute * 60.0 +
            recordingStartTime.second;
        var diff = eventTimeOfDay - startSecondsInDay;
        if (diff < 0) diff += 86400.0;
        startSec = diff;
      }

      events.add(ScoredEvent(
        digit: 0,
        key: '',
        label: text,
        startSec: math.max(0.0, startSec),
        endSec: math.max(0.0, startSec),
        type: 'Nihon Kohden Log',
      ));
    } else {
      // Pattern: <seconds> <text>
      final secMatch = RegExp(r'^(\d+(?:\.\d+)?)\s+(.*)$').firstMatch(line);
      if (secMatch != null) {
        final sec = double.tryParse(secMatch.group(1)!) ?? 0.0;
        final text = secMatch.group(2)?.trim() ?? 'NK Event';
        events.add(ScoredEvent(
          digit: 0,
          key: '',
          label: text,
          startSec: sec,
          endSec: sec,
          type: 'Nihon Kohden Log',
        ));
      }
    }
  }

  return events;
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. XML Events (Compumedics Profusion / Alice / Somte)
// ─────────────────────────────────────────────────────────────────────────────

Future<List<ScoredEvent>> _loadXmlEvents(String activePath) async {
  final dotIdx = activePath.lastIndexOf('.');
  final base = dotIdx >= 0 ? activePath.substring(0, dotIdx) : activePath;

  final candidates = [
    '$base.xml',
    '$base.XML',
    '${base}_events.xml',
    '${base}_scoring.xml',
  ];

  File? xmlFile;
  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync()) {
      xmlFile = f;
      break;
    }
  }
  if (xmlFile == null) return const [];

  final content = await xmlFile.readAsString();
  final events = <ScoredEvent>[];

  // Regex parser for <ScoredEvent>...</ScoredEvent>
  final eventBlockRegex = RegExp(r'<ScoredEvent\b[^>]*>(.*?)</ScoredEvent>', dotAll: true, caseSensitive: false);
  final matches = eventBlockRegex.allMatches(content);

  for (final m in matches) {
    final block = m.group(1) ?? '';
    final nameMatch = RegExp(r'<Name\b[^>]*>(.*?)</Name>', caseSensitive: false).firstMatch(block);
    final startMatch = RegExp(r'<Start\b[^>]*>(.*?)</Start>', caseSensitive: false).firstMatch(block);
    final durMatch = RegExp(r'<Duration\b[^>]*>(.*?)</Duration>', caseSensitive: false).firstMatch(block);
    final inputMatch = RegExp(r'<Input\b[^>]*>(.*?)</Input>', caseSensitive: false).firstMatch(block);

    if (nameMatch != null && startMatch != null) {
      final name = nameMatch.group(1)?.trim() ?? 'Event';
      final start = double.tryParse(startMatch.group(1)?.trim() ?? '0') ?? 0.0;
      final dur = durMatch != null ? (double.tryParse(durMatch.group(1)?.trim() ?? '0') ?? 0.0) : 0.0;
      final channel = inputMatch?.group(1)?.trim();

      events.add(ScoredEvent(
        digit: 0,
        key: '',
        label: name,
        startSec: math.max(0.0, start),
        endSec: math.max(0.0, start + dur),
        channel: channel,
        type: 'Profusion XML',
      ));
    }
  }

  return events;
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. Generic Tabular CSV / TSV / TXT Events
// ─────────────────────────────────────────────────────────────────────────────

Future<List<ScoredEvent>> _loadTabularEvents(
  String activePath,
  DateTime? recordingStartTime,
) async {
  final dotIdx = activePath.lastIndexOf('.');
  final base = dotIdx >= 0 ? activePath.substring(0, dotIdx) : activePath;

  final candidates = [
    '${base}_events.csv',
    '${base}_annotations.csv',
    '${base}_markers.csv',
    '$base.csv',
    '${base}_events.tsv',
    '$base.tsv',
    '${base}_annotations.txt',
    '$base.txt',
  ];

  File? tabFile;
  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync()) {
      tabFile = f;
      break;
    }
  }
  if (tabFile == null) return const [];

  final lines = await tabFile.readAsLines();
  if (lines.isEmpty) return const [];

  final firstLine = lines.first.trim();
  final delimiter = firstLine.contains('\t') ? '\t' : (firstLine.contains(';') ? ';' : ',');

  final headers = firstLine.split(delimiter).map((h) => h.trim().toLowerCase()).toList();
  int onsetCol = -1;
  int durCol = -1;
  int labelCol = -1;
  int chanCol = -1;
  int typeCol = -1;

  for (var i = 0; i < headers.length; i++) {
    final h = headers[i];
    if (h == 'onset' || h == 'start' || h == 'time' || h == 'latency' || h == 'startsec') {
      onsetCol = i;
    } else if (h == 'duration' || h == 'dur' || h == 'length' || h == 'durationsec') {
      durCol = i;
    } else if (h == 'label' || h == 'name' || h == 'description' || h == 'event' || h == 'annotation' || h == 'marker') {
      labelCol = i;
    } else if (h == 'channel' || h == 'lead' || h == 'input') {
      chanCol = i;
    } else if (h == 'type' || h == 'category') {
      typeCol = i;
    }
  }

  // Fallback defaults if header was not explicit
  if (onsetCol < 0 && headers.isNotEmpty) onsetCol = 0;
  if (labelCol < 0 && headers.length >= 2) labelCol = headers.length > 2 ? 2 : 1;
  if (durCol < 0 && headers.length >= 3 && labelCol != 1) durCol = 1;

  final events = <ScoredEvent>[];
  final dataLines = lines.skip(1);

  for (final raw in dataLines) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final parts = line.split(delimiter);
    if (parts.length <= math.max(onsetCol, labelCol)) continue;

    final onsetStr = parts[onsetCol].trim();
    double startSec = 0.0;

    // Check if onset is in HH:MM:SS format
    final clockMatch = RegExp(r'^(\d{1,2}):(\d{2}):(\d{2})(?:\.(\d+))?$').firstMatch(onsetStr);
    if (clockMatch != null) {
      final h = int.parse(clockMatch.group(1)!);
      final m = int.parse(clockMatch.group(2)!);
      final s = int.parse(clockMatch.group(3)!);
      final ms = clockMatch.group(4) != null ? double.parse('0.${clockMatch.group(4)}') : 0.0;
      startSec = h * 3600.0 + m * 60.0 + s + ms;
      if (recordingStartTime != null) {
        final startSecondsInDay =
            recordingStartTime.hour * 3600.0 +
            recordingStartTime.minute * 60.0 +
            recordingStartTime.second;
        var diff = startSec - startSecondsInDay;
        if (diff < 0) diff += 86400.0;
        startSec = diff;
      }
    } else {
      startSec = double.tryParse(onsetStr) ?? 0.0;
    }

    final dur = (durCol >= 0 && durCol < parts.length)
        ? (double.tryParse(parts[durCol].trim()) ?? 0.0)
        : 0.0;
    final label = parts[labelCol].trim();
    final channel = (chanCol >= 0 && chanCol < parts.length) ? parts[chanCol].trim() : null;
    final type = (typeCol >= 0 && typeCol < parts.length) ? parts[typeCol].trim() : 'Tabular Event';

    if (label.isNotEmpty) {
      events.add(ScoredEvent(
        digit: 0,
        key: '',
        label: label,
        startSec: math.max(0.0, startSec),
        endSec: math.max(0.0, startSec + dur),
        channel: channel?.isNotEmpty == true ? channel : null,
        type: type,
      ));
    }
  }

  return events;
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. AnalyseNidra Spindles & Slow-Waves
// ─────────────────────────────────────────────────────────────────────────────

Future<List<ScoredEvent>> loadAnalyseNidraSpindles(String activePath) async {
  final dotIdx = activePath.lastIndexOf('.');
  final base = dotIdx >= 0 ? activePath.substring(0, dotIdx) : activePath;
  final candidates = [
    '${base}_analyse_spindles.json',
    '$base.spindles.json',
    '${base}_spindles.json',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (!file.existsSync()) continue;
    try {
      final content = await file.readAsString();
      final dynamic json = jsonDecode(content);
      final List<dynamic>? events = json is Map
          ? (json['Events'] as List<dynamic>? ?? json['events'] as List<dynamic>?)
          : (json is List ? json : null);
      if (events == null) continue;
      final result = <ScoredEvent>[];
      for (final item in events) {
        if (item is! Map) continue;
        final start = (item['Start'] as num? ?? item['start'] as num?)?.toDouble() ?? 0.0;
        final end = (item['End'] as num? ?? item['end'] as num?)?.toDouble() ?? 0.0;
        final ch = (item['Channel'] ?? item['channel'])?.toString();
        final freq = (item['Frequency'] as num? ?? item['frequency'] as num?)?.toDouble();
        final freqStr = freq != null ? ' ${freq.toStringAsFixed(1)}Hz' : '';
        final chStr = (ch != null && ch.isNotEmpty) ? ' ($ch$freqStr)' : freqStr;
        result.add(
          ScoredEvent(
            digit: 8,
            key: 'F8',
            label: 'Spindle$chStr',
            type: 'AnalyseNidra Spindle',
            channel: ch,
            startSec: start,
            endSec: end > start ? end : start + 1.0,
          ),
        );
      }
      return result;
    } catch (_) {}
  }
  return const [];
}

Future<List<ScoredEvent>> loadAnalyseNidraSlowWaves(String activePath) async {
  final dotIdx = activePath.lastIndexOf('.');
  final base = dotIdx >= 0 ? activePath.substring(0, dotIdx) : activePath;
  final candidates = [
    '${base}_analyse_slow_waves.json',
    '$base.slow_waves.json',
    '${base}_slow_waves.json',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (!file.existsSync()) continue;
    try {
      final content = await file.readAsString();
      final dynamic json = jsonDecode(content);
      final List<dynamic>? events = json is Map
          ? (json['Events'] as List<dynamic>? ?? json['events'] as List<dynamic>?)
          : (json is List ? json : null);
      if (events == null) continue;
      final result = <ScoredEvent>[];
      for (final item in events) {
        if (item is! Map) continue;
        final start = (item['Start'] as num? ?? item['start'] as num?)?.toDouble() ?? 0.0;
        final end = (item['End'] as num? ?? item['end'] as num?)?.toDouble() ?? 0.0;
        final ch = (item['Channel'] ?? item['channel'])?.toString();
        final ptp = (item['PTP'] as num? ?? item['ptp'] as num?)?.toDouble();
        final ptpStr = ptp != null ? ' ${ptp.toStringAsFixed(0)}µV' : '';
        final chStr = (ch != null && ch.isNotEmpty) ? ' ($ch$ptpStr)' : ptpStr;
        result.add(
          ScoredEvent(
            digit: 7,
            key: 'F7',
            label: 'SlowWave$chStr',
            type: 'AnalyseNidra SlowWave',
            channel: ch,
            startSec: start,
            endSec: end > start ? end : start + 1.0,
          ),
        );
      }
      return result;
    } catch (_) {}
  }
  return const [];
}

// ─────────────────────────────────────────────────────────────────────────────
// Color Digit Assignment & Sort
// ─────────────────────────────────────────────────────────────────────────────

List<ScoredEvent> _assignEventDigits(List<ScoredEvent> events) {
  events.sort((a, b) => a.startSec.compareTo(b.startSec));

  final labelToDigit = <String, int>{};
  var nextDigit = 1;

  return [
    for (final ev in events)
      ScoredEvent(
        digit: (ev.type.startsWith('AnalyseNidra') || ev.type == 'MT-Spindle' || ev.type == 'MT-KCD')
            ? ev.digit
            : labelToDigit.putIfAbsent(ev.label.toLowerCase(), () {
                final d = nextDigit;
                nextDigit = (nextDigit % 9) + 1;
                return d;
              }),
        key: ev.key,
        label: ev.label,
        startSec: ev.startSec,
        endSec: ev.endSec,
        channel: ev.channel,
        type: ev.type,
      ),
  ];
}
