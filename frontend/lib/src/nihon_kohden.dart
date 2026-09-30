// Nihon Kohden (EEG-1100 / EEG-1200 / Neurofax) companion-file readers.
//
// A Nihon Kohden recording is a folder of files that share a base name:
//   FA7312Q6.EEG   signal data (read natively by the Rust bridge)
//   FA7312Q6.21E   electrode-code → channel-name table
//   FA7312Q6.PNT   patient / start-time information
//   FA7312Q6.LOG   operator log (binary): "REC START", "Stim On", comments…
//   FA7312Q6.EVT   trigger events (tab-separated, microseconds)
//   FA7312Q6.VF2   digital-video index (XML): cameras, files, start/end times
//   Video/FA7312Q6.VOR/7312Q600.m2t, Video/FA7312Q6.VO2/…   camera files
//
// Everything here is pure Dart so it works with the existing native library.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'models.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

String nkBasePath(String path) {
  final sep = path.lastIndexOf(Platform.pathSeparator);
  final slash = path.lastIndexOf('/');
  final lastSep = sep > slash ? sep : slash;
  final dot = path.lastIndexOf('.');
  return dot > lastSep ? path.substring(0, dot) : path;
}

String _dirOf(String path) {
  final sep = path.lastIndexOf(Platform.pathSeparator);
  final slash = path.lastIndexOf('/');
  final i = sep > slash ? sep : slash;
  return i >= 0 ? path.substring(0, i) : '.';
}

String _baseName(String path) {
  final parts = path.split(RegExp(r'[\\/]'));
  return parts.isEmpty ? path : parts.last;
}

/// Finds `<base>.<ext>` ignoring the case of the extension.
File? nkCompanionFile(String anyPath, String ext) {
  final base = nkBasePath(anyPath);
  for (final e in [ext.toUpperCase(), ext.toLowerCase(), ext]) {
    final f = File('$base.$e');
    if (f.existsSync()) return f;
  }
  // Fall back to a case-insensitive scan of the folder (e.g. "fa7312q6.log").
  try {
    final dir = Directory(_dirOf(anyPath));
    final want = '${_baseName(base)}.$ext'.toLowerCase();
    for (final ent in dir.listSync(followLinks: false)) {
      if (ent is File && _baseName(ent.path).toLowerCase() == want) return ent;
    }
  } catch (_) {}
  return null;
}

String _decodeText(List<int> bytes) {
  final trimmed = <int>[];
  for (final b in bytes) {
    if (b == 0) break;
    trimmed.add(b);
  }
  if (trimmed.every((b) => b < 0x80)) return ascii.decode(trimmed).trim();
  try {
    return utf8.decode(trimmed).trim();
  } catch (_) {
    return latin1.decode(trimmed).trim();
  }
}

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int _u32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

Uint8List _readAt(RandomAccessFile raf, int offset, int length) {
  raf.setPositionSync(offset);
  return raf.readSync(length);
}

// ─────────────────────────────────────────────────────────────────────────────
// Channel names (.EEG channel codes + .21E table)
// ─────────────────────────────────────────────────────────────────────────────

/// Default Nihon Kohden electrode-code labels (0-based code → name), used
/// when the recording has no .21E file. Same table as MNE-Python.
String nkDefaultChannelName(int code) {
  const first = [
    'FP1', 'FP2', 'F3', 'F4', 'C3', 'C4', 'P3', 'P4', 'O1', 'O2', 'F7', 'F8',
    'T3', 'T4', 'T5', 'T6', 'FZ', 'CZ', 'PZ', 'E', 'PG1', 'PG2', 'A1', 'A2',
    'T1', 'T2',
  ];
  if (code < first.length) return first[code];
  if (code < 37) return 'X${code - 25}';
  if (code < 42) return 'NA${code - 36}';
  if (code < 74) return 'DC${(code - 41).toString().padLeft(2, '0')}';
  switch (code) {
    case 74:
      return 'BN1';
    case 75:
      return 'BN2';
    case 76:
      return 'Mark1';
    case 77:
      return 'Mark2';
    case 100:
      return 'X12/BP1';
    case 101:
      return 'X13/BP2';
    case 102:
      return 'X14/BP3';
    case 103:
      return 'X15/BP4';
  }
  if (code < 100) return 'NA${code - 72}';
  return 'X${code - 88}';
}

/// Parses `[ELECTRODE]` and `[REFERENCE]` of a .21E file (all codes).
Map<int, String> readNk21eNames(String anyPath) {
  final names = <int, String>{};
  final f = nkCompanionFile(anyPath, '21E');
  if (f == null) return names;
  try {
    final text = latin1.decode(f.readAsBytesSync());
    var inSection = false;
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) continue;
      if (line.startsWith('[')) {
        final u = line.toUpperCase();
        inSection = u == '[ELECTRODE]' || u == '[REFERENCE]';
        continue;
      }
      if (!inSection) continue;
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      final idx = int.tryParse(line.substring(0, eq).trim());
      final name = line.substring(eq + 1).trim();
      if (idx != null && name.isNotEmpty) names[idx] = name;
    }
  } catch (_) {}
  return names;
}

/// Labels produced by versions <= 1.23 (which ignored .21E names for codes
/// >= 74 and used a shifted fallback table). Only used to migrate configs.
List<String> legacyNkChannelLabels(String anyPath, List<int> codes) {
  final e21 = <int, String>{};
  final f = nkCompanionFile(anyPath, '21E');
  if (f != null) {
    try {
      var inElectrode = false;
      for (final raw in const LineSplitter().convert(latin1.decode(f.readAsBytesSync()))) {
        final line = raw.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        if (line.toUpperCase() == '[ELECTRODE]') {
          inElectrode = true;
          continue;
        }
        if (line.startsWith('[')) {
          inElectrode = false;
          continue;
        }
        final parts = line.split('=');
        if (!inElectrode || parts.length != 2) continue;
        final idx = int.tryParse(parts[0].trim());
        final name = parts[1].trim();
        if (idx == null || name.isEmpty || idx >= 74) continue;
        final template = (name.length == 3 &&
                RegExp(r'^[C-P][0-9][0-9]$').hasMatch(name)) ||
            name.startsWith('RFU') ||
            name.startsWith('COM') ||
            name.startsWith('BP');
        if (!template) e21[idx] = name;
      }
    } catch (_) {}
  }
  String old(int code) {
    final n = code + 1;
    const first = [
      'FP1', 'FP2', 'F3', 'F4', 'C3', 'C4', 'P3', 'P4', 'O1', 'O2', 'F7', 'F8',
      'T3', 'T4', 'T5', 'T6', 'FZ', 'CZ', 'PZ', 'E', 'PG1', 'PG2', 'A1', 'A2',
      'T1', 'T2',
    ];
    if (n >= 1 && n <= 26) return first[n - 1];
    if (n >= 27 && n <= 37) return 'X${n - 26}';
    const named = {
      38: 'BN', 39: 'AV', 40: 'SD', 41: 'Aav', 42: '0V', 71: 'SpO2',
      72: 'EtCO2', 73: 'Pulse', 74: 'CO2Wave', 75: 'BN1', 76: 'BN2',
      77: 'Mark1', 78: 'Mark2', 101: 'BP1', 102: 'BP2', 103: 'BP3', 104: 'BP4',
    };
    if (named.containsKey(n)) return named[n]!;
    if (n >= 43 && n <= 70) return 'DC${(n - 42).toString().padLeft(2, '0')}';
    return 'EEG$n';
  }

  return [for (final c in codes) e21[c] ?? old(c)];
}

class NkHeaderInfo {
  const NkHeaderInfo({
    required this.channelCodes,
    required this.channelLabels,
    this.startTime,
    this.sampleRateHz,
  });

  /// Electrode codes of the stored channels, in storage order.
  final List<int> channelCodes;
  final List<String> channelLabels;

  /// Wall-clock time of the first sample (local time, as recorded).
  final DateTime? startTime;
  final double? sampleRateHz;
}

DateTime? _parseCompactDateTime(String s) {
  // yyyyMMddHHmmss[fraction…]
  final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d*)$').firstMatch(s.trim());
  if (m == null) return null;
  final frac = m.group(7) ?? '';
  final micro = frac.isEmpty
      ? 0
      : (double.parse("0.$frac") * 1e6).round().clamp(0, 999999).toInt();
  final dt = DateTime(
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6)!),
  );
  return dt.add(Duration(microseconds: micro));
}

int _bcd(int b) => ((b >> 4) & 0xF) * 10 + (b & 0xF);

/// Reads the channel table and start time of a Nihon Kohden .EEG file.
/// Returns null when the file is not a recognisable NK file.
NkHeaderInfo? readNkHeader(String eegPath) {
  RandomAccessFile? raf;
  try {
    final file = File(eegPath);
    final len = file.lengthSync();
    raf = file.openSync();
    final head = _readAt(raf, 0, len < 0x2000 ? len : 0x2000);
    if (head.length < 0x100) return null;
    final version = ascii.decode(head.sublist(0, 16), allowInvalid: true);
    if (!version.startsWith('EEG-') && !version.startsWith('QI-') && !version.startsWith('DAE')) {
      // Still try; some systems use other signatures.
    }

    final e21 = readNk21eNames(eegPath);
    String nameFor(int code) => e21[code] ?? nkDefaultChannelName(code);

    final codes = <int>[];
    DateTime? start;
    double? sfreq;

    // Datablock of control block 0 (present in every version).
    final ctlAddr = _u32(head, 0x92);
    if (ctlAddr + 22 <= len) {
      final dataAddr = _u32(_readAt(raf, ctlAddr + 18, 4), 0);
      if (dataAddr + 0x30 <= len) {
        final db = _readAt(raf, dataAddr, 0x30);
        sfreq = (_u16(db, 0x1A) & 0x3FFF).toDouble();
        // BCD yy mm dd hh mm ss at 0x14.
        final yy = _bcd(db[0x14]);
        final mo = _bcd(db[0x15]);
        final dd = _bcd(db[0x16]);
        final hh = _bcd(db[0x17]);
        final mi = _bcd(db[0x18]);
        final ss = _bcd(db[0x19]);
        if (mo >= 1 && mo <= 12 && dd >= 1 && dd <= 31 && hh < 24 && mi < 60 && ss < 61) {
          start = DateTime(yy < 80 ? 2000 + yy : 1900 + yy, mo, dd, hh, mi, ss);
        }
        final n = db[0x26];
        final chBytes = _readAt(raf, dataAddr + 0x27, n * 10);
        for (var i = 0; i < n && i * 10 < chBytes.length; i++) {
          codes.add(chBytes[i * 10]);
        }
      }
    }

    // EEG-1200A extended header: 16-bit channel codes and a precise start time.
    if (version.startsWith('EEG-1200A') && head.length >= 0x3F2) {
      final ext = _u32(head, 0x03EE);
      if (ext > 0 && ext + 22 <= len) {
        final e2 = _u32(_readAt(raf, ext + 18, 4), 0);
        if (e2 > 0 && e2 + 24 <= len) {
          final e3 = _u32(_readAt(raf, e2 + 20, 4), 0);
          if (e3 > 0 && e3 + 72 <= len) {
            final b3 = _readAt(raf, e3, 72);
            final n = _u16(b3, 68);
            if (n > 0 && n < 1024 && e3 + 72 + n * 10 <= len) {
              final chBytes = _readAt(raf, e3 + 72, n * 10);
              codes
                ..clear()
                ..addAll([for (var i = 0; i < n; i++) _u16(chBytes, i * 10)]);
            }
            final text = latin1.decode(b3.sublist(0, 68));
            final m = RegExp(r'(\d{20})').firstMatch(text);
            if (m != null) start = _parseCompactDateTime(m.group(1)!) ?? start;
          }
        }
      }
    }

    // .PNT holds the start time as text at 0x40 (yyyyMMddHHmmss).
    if (start == null) {
      final pnt = nkCompanionFile(eegPath, 'PNT');
      if (pnt != null) {
        try {
          final b = pnt.readAsBytesSync();
          if (b.length >= 0x4E) {
            start = _parseCompactDateTime(ascii.decode(b.sublist(0x40, 0x4E), allowInvalid: true));
          }
        } catch (_) {}
      }
    }

    if (codes.isEmpty) return null;
    return NkHeaderInfo(
      channelCodes: codes,
      channelLabels: [for (final c in codes) nameFor(c)],
      startTime: start,
      sampleRateHz: sfreq,
    );
  } catch (_) {
    return null;
  } finally {
    raf?.closeSync();
  }
}

/// Makes labels unique ("C3", "C3 (2)") so channel bindings stay unambiguous.
List<String> uniqueChannelLabels(List<String> labels) {
  final seen = <String, int>{};
  return [
    for (final l in labels)
      () {
        final n = (seen[l] ?? 0) + 1;
        seen[l] = n;
        return n == 1 ? l : '$l ($n)';
      }(),
  ];
}

// ─────────────────────────────────────────────────────────────────────────────
// Markers: .LOG (binary operator log) and .EVT (trigger events)
// ─────────────────────────────────────────────────────────────────────────────

/// Reads the binary .LOG file. Onsets are seconds from recording start.
List<ScoredEvent> readNkLogEvents(String anyPath) {
  final f = nkCompanionFile(anyPath, 'LOG');
  if (f == null) return const [];
  final Uint8List d;
  try {
    d = f.readAsBytesSync();
  } catch (_) {
    return const [];
  }
  if (d.length < 0x92 + 4) return const [];

  // Text log (some exports): fall back to the line-based format.
  final sig = ascii.decode(d.sublist(0, 4), allowInvalid: true);
  if (!sig.startsWith('EEG-') && !sig.startsWith('QI-') && !sig.startsWith('DAE')) {
    return const [];
  }

  final events = <ScoredEvent>[];
  final nBlocks = d[0x91];
  for (var b = 0; b < nBlocks; b++) {
    final ptr = 0x92 + b * 20;
    if (ptr + 4 > d.length) break;
    final blk = _u32(d, ptr);
    if (blk + 0x14 > d.length) continue;
    final nLogs = d[blk + 0x12];

    // Sub-second part lives in a parallel "sub-log" block (EEG-1100 and later).
    int? subBlk;
    final subPtr = 0x92 + (b + 22) * 20;
    if (subPtr + 4 <= d.length) {
      final a = _u32(d, subPtr);
      if (a > 0 && a + 0x14 + nLogs * 45 <= d.length) subBlk = a;
    }

    for (var i = 0; i < nLogs; i++) {
      final o = blk + 0x14 + i * 45;
      if (o + 45 > d.length) break;
      final rec = d.sublist(o, o + 45);
      final desc = _decodeText(rec.sublist(0, 20));
      final hms = ascii.decode(rec.sublist(20, 26), allowInvalid: true);
      final m = RegExp(r'^(\d{2})(\d{2})(\d{2})$').firstMatch(hms);
      if (m == null) continue;
      var onset = int.parse(m.group(1)!) * 3600.0 +
          int.parse(m.group(2)!) * 60.0 +
          int.parse(m.group(3)!);
      if (subBlk != null) {
        final so = subBlk + 0x14 + i * 45;
        final frac = ascii.decode(d.sublist(so + 24, so + 30), allowInvalid: true);
        final us = int.tryParse(frac);
        if (us != null && us >= 0 && us < 1000000) onset += us / 1e6;
      }
      events.add(ScoredEvent(
        digit: 0,
        key: '',
        label: desc.isEmpty ? 'NK Event' : desc,
        startSec: onset,
        endSec: onset,
        type: 'Nihon Kohden Log',
      ));
    }
  }
  return events;
}

/// Reads the .EVT trigger file ("Tmu\tCode\tTriNo", Tmu in microseconds from
/// the start of the recording).
List<ScoredEvent> readNkEvtEvents(String anyPath) {
  final f = nkCompanionFile(anyPath, 'EVT');
  if (f == null) return const [];
  final List<String> lines;
  try {
    lines = const LineSplitter().convert(latin1.decode(f.readAsBytesSync()));
  } catch (_) {
    return const [];
  }
  if (lines.isEmpty) return const [];
  final header = lines.first.split('\t').map((s) => s.trim().toLowerCase()).toList();
  final tCol = header.indexWhere((h) => h.startsWith('tmu') || h == 'time');
  final codeCol = header.indexOf('code');
  final trigCol = header.indexWhere((h) => h.startsWith('trino') || h.startsWith('trig'));
  final hasHeader = tCol >= 0;
  final events = <ScoredEvent>[];
  for (final raw in lines.skip(hasHeader ? 1 : 0)) {
    final cols = raw.split('\t');
    if (cols.isEmpty || cols.first.trim().isEmpty) continue;
    final t = int.tryParse(cols[hasHeader ? tCol : 0].trim());
    if (t == null) continue;
    final sec = t / 1e6;
    final trig = trigCol >= 0 && trigCol < cols.length ? cols[trigCol].trim() : '';
    final code = codeCol >= 0 && codeCol < cols.length ? cols[codeCol].trim() : '';
    final label = trig.isNotEmpty
        ? 'Trigger $trig'
        : (code.isNotEmpty ? 'Trigger code $code' : 'Trigger');
    events.add(ScoredEvent(
      digit: 0,
      key: '',
      label: label,
      startSec: sec,
      endSec: sec,
      type: 'Nihon Kohden Trigger',
    ));
  }
  return events;
}

// ─────────────────────────────────────────────────────────────────────────────
// Video index (.VF2 / .VFT)
// ─────────────────────────────────────────────────────────────────────────────

class VideoSegment {
  const VideoSegment({
    required this.fileName,
    required this.path,
    required this.startSec,
    this.endSec,
  });

  /// Name as listed in the index (e.g. `FA7312Q6.VOR\7312Q600.m2t`).
  final String fileName;

  /// Resolved local path, or null when the file is missing.
  final String? path;

  /// Start/end in seconds from the start of the EEG. [endSec] is null when
  /// unknown (the file's own duration then applies).
  final double startSec;
  final double? endSec;

  bool get available => path != null;
}

class VideoCamera {
  VideoCamera({required this.name, required this.segments, this.offsetSec = 0});

  final String name;
  final List<VideoSegment> segments;

  /// Manual sync correction added to the video time (seconds).
  double offsetSec;

  int get availableCount => segments.where((s) => s.available).length;

  /// Index of the segment that covers [eegSec] (after the offset), or -1.
  int segmentIndexAt(double eegSec) {
    final t = eegSec + offsetSec;
    for (var i = 0; i < segments.length; i++) {
      final s = segments[i];
      final end = s.endSec ?? double.infinity;
      if (t >= s.startSec && t < end) return i;
    }
    return -1;
  }
}

class NkVideoIndex {
  const NkVideoIndex({required this.cameras, required this.indexFile});
  final List<VideoCamera> cameras;
  final String indexFile;
}

const videoExtensions = {'m2t', 'ts', 'mts', 'm2ts', 'mp4', 'mov', 'mkv', 'avi', 'webm', 'mpg', 'mpeg', 'wmv'};

/// Collects video files in [root] up to [depth] folders deep.
List<File> _collectVideos(Directory root, int depth) {
  final out = <File>[];
  void walk(Directory d, int level) {
    List<FileSystemEntity> ents;
    try {
      ents = d.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    for (final e in ents) {
      if (e is File) {
        final n = _baseName(e.path).toLowerCase();
        final dot = n.lastIndexOf('.');
        if (dot > 0 && videoExtensions.contains(n.substring(dot + 1))) out.add(e);
      } else if (e is Directory && level < depth) {
        walk(e, level + 1);
      }
    }
  }

  walk(root, 0);
  return out;
}

/// Reads the NK digital-video index next to [eegPath] and resolves every
/// listed file against the recording folder (including `Video/` sub-folders).
/// Times are converted to seconds from [eegStart].
NkVideoIndex? readNkVideoIndex(String eegPath, DateTime? eegStart) {
  final f = nkCompanionFile(eegPath, 'VF2') ?? nkCompanionFile(eegPath, 'VFT');
  if (f == null) return null;
  String xml;
  try {
    xml = utf8.decode(f.readAsBytesSync(), allowMalformed: true);
  } catch (_) {
    return null;
  }

  // Index local video files once: "parentdir/file" and "file" (lower case).
  final folder = Directory(_dirOf(eegPath));
  final videos = _collectVideos(folder, 3);
  final byDirAndName = <String, String>{};
  final byName = <String, List<String>>{};
  for (final v in videos) {
    final name = _baseName(v.path).toLowerCase();
    final parent = _baseName(_dirOf(v.path)).toLowerCase();
    byDirAndName['$parent/$name'] = v.path;
    byName.putIfAbsent(name, () => []).add(v.path);
  }

  String? resolve(String listed) {
    final parts = listed.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    final name = parts.last.toLowerCase();
    if (parts.length >= 2) {
      final hit = byDirAndName['${parts[parts.length - 2].toLowerCase()}/$name'];
      if (hit != null) return hit;
      // A listed folder exists but the file is not in it: treat as missing
      // rather than picking the same-named file from another camera.
      return null;
    }
    final list = byName[name];
    return list != null && list.length == 1 ? list.first : null;
  }

  // Without an EEG start time, fall back to the earliest video start.
  DateTime? earliest;
  for (final m in RegExp(r'<StartTime>\s*(\d+)\s*</StartTime>').allMatches(xml)) {
    final t = _parseVideoTime(m.group(1)!);
    if (t != null && (earliest == null || t.isBefore(earliest))) earliest = t;
  }

  final cameras = <VideoCamera>[];
  final groupRe = RegExp(r'<((?:Original|Clip|Camera|Video)\d+)>(.*?)</\1>', dotAll: true);
  final elemRe = RegExp(r'<VideoElement>(.*?)</VideoElement>', dotAll: true);
  String? tag(String s, String t) =>
      RegExp('<$t>\\s*(.*?)\\s*</$t>', dotAll: true).firstMatch(s)?.group(1);

  final base = eegStart;
  for (final g in groupRe.allMatches(xml)) {
    final segs = <VideoSegment>[];
    for (final e in elemRe.allMatches(g.group(2)!)) {
      final body = e.group(1)!;
      final file = tag(body, 'VideoFile');
      final st = _parseVideoTime(tag(body, 'StartTime') ?? '');
      final en = _parseVideoTime(tag(body, 'EndTime') ?? '');
      if (file == null || st == null) continue;
      final ref = base ?? earliest ?? st;
      segs.add(VideoSegment(
        fileName: file,
        path: resolve(file),
        startSec: st.difference(ref).inMicroseconds / 1e6,
        endSec: en == null ? null : en.difference(ref).inMicroseconds / 1e6,
      ));
    }
    if (segs.isEmpty) continue;
    segs.sort((a, b) => a.startSec.compareTo(b.startSec));
    // Name the camera after its folder (VOR, VO2…) when possible.
    final firstDir = segs.first.fileName.split(RegExp(r'[\\/]'));
    final dirName = firstDir.length >= 2 ? firstDir[firstDir.length - 2] : '';
    final ext = dirName.contains('.') ? dirName.substring(dirName.lastIndexOf('.') + 1) : '';
    final label = 'Camera ${cameras.length + 1}${ext.isNotEmpty ? ' ($ext)' : ''}';
    cameras.add(VideoCamera(name: label, segments: segs));
  }
  if (cameras.isEmpty) return null;
  return NkVideoIndex(cameras: cameras, indexFile: f.path);
}

/// Parses "yyyyMMddHHmmss" followed by a fraction of a second
/// (e.g. 202608172330279500 → 23:30:27.95).
DateTime? _parseVideoTime(String s) => _parseCompactDateTime(s.trim());

/// Groups loose video files found in the recording folder (no index file):
/// each sub-folder becomes a camera and files play back to back in name
/// order, the first starting at the EEG start. Only used as a fallback; the
/// user can correct the timing with the sync offset.
List<VideoCamera> guessVideoCamerasFromFolder(String eegPath) {
  final folder = Directory(_dirOf(eegPath));
  final videos = _collectVideos(folder, 3)
    ..sort((a, b) => a.path.compareTo(b.path));
  if (videos.isEmpty) return const [];
  final byDir = <String, List<File>>{};
  for (final v in videos) {
    byDir.putIfAbsent(_dirOf(v.path), () => []).add(v);
  }
  final cams = <VideoCamera>[];
  for (final entry in byDir.entries) {
    final files = entry.value;
    if (files.length != 1) continue; // unknown timing across several files
    cams.add(VideoCamera(
      name: _baseName(files.first.path),
      segments: [
        VideoSegment(
          fileName: _baseName(files.first.path),
          path: files.first.path,
          startSec: 0,
        ),
      ],
    ));
  }
  return cams;
}
