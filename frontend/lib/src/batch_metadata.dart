// Recording metadata for batch processing, read from a CSV / TSV / XLSX
// table and matched to recordings by file name (or folder name).
//
// Example table:
//   Recording   | Subject | Group   | Age | Sex
//   FA7312Q6    | LD_Pi_03| Placebo | 34  | F
//
// The key column is compared with each recording's file name without its
// extension, then with the names of its parent folders (so a table keyed by
// subject folder, e.g. "LD_Pi_03", also works), and finally by containment.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import 'regional_csv.dart' show parseCsvLine;

class BatchMetadataTable {
  BatchMetadataTable({
    required this.sourcePath,
    required this.headers,
    required this.rows,
    required this.keyColumn,
    this.sheetName,
  });

  final String sourcePath;
  final List<String> headers;
  final List<Map<String, String>> rows;
  String keyColumn;
  final String? sheetName;

  /// Columns written to outputs (all except the key column).
  List<String> get valueColumns => [for (final h in headers) if (h != keyColumn) h];

  /// Finds the metadata row for [recordingPath], or null.
  Map<String, String>? lookup(String recordingPath) {
    final m = matchRecording(recordingPath);
    return m?.row;
  }

  BatchMetadataMatch? matchRecording(String recordingPath) {
    final segments = recordingPath.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return null;
    final stem = normalizeRecordingKey(segments.last);
    final folders = [
      for (var i = segments.length - 2; i >= 0 && i >= segments.length - 4; i--)
        normalizeRecordingKey(segments[i]),
    ];

    Map<String, String>? best;
    var bestScore = 0;
    var how = '';
    for (final row in rows) {
      final key = normalizeRecordingKey(row[keyColumn] ?? '');
      if (key.isEmpty) continue;
      var score = 0;
      var h = '';
      if (key == stem) {
        score = 1000;
        h = 'file name';
      } else if (folders.contains(key)) {
        score = 900 - folders.indexOf(key);
        h = 'folder name';
      } else {
        final isStemToken = RegExp('(^|[^a-zA-Z0-9])${RegExp.escape(key)}([^a-zA-Z0-9]|\$)').hasMatch(stem);
        if (key.length >= 3 && isStemToken) {
          score = 700 + key.length * 2;
          h = 'part of file name';
        } else if (key.length >= 3 && !RegExp(r'^\d+$').hasMatch(key) && stem.contains(key)) {
          score = 400 + key.length;
          h = 'part of file name';
        } else if (key.length >= 3 &&
            folders.any((f) => RegExp('(^|[^a-zA-Z0-9])${RegExp.escape(key)}([^a-zA-Z0-9]|\$)').hasMatch(f))) {
          score = 500 + key.length;
          h = 'part of folder name';
        } else if (key.length >= 3 && !RegExp(r'^\d+$').hasMatch(key) && folders.any((f) => f.contains(key))) {
          score = 300 + key.length;
          h = 'part of folder name';
        }
      }
      if (score > bestScore) {
        bestScore = score;
        best = row;
        how = h;
      }
    }
    return best == null ? null : BatchMetadataMatch(best, how);
  }
}

class BatchMetadataMatch {
  const BatchMetadataMatch(this.row, this.matchedBy);
  final Map<String, String> row;
  final String matchedBy;
}

/// Lower-case name without extension and without the suffixes this app adds
/// to derived files (cleaned EDF, scoring, feature CSVs).
String normalizeRecordingKey(String name) {
  var s = name.trim().toLowerCase();
  final dot = s.lastIndexOf('.');
  if (dot > 0 && s.length - dot <= 6) s = s.substring(0, dot);
  for (final suffix in const [
    '_analyse_regional',
    '_analyse_channel',
    '_scoring',
    '_autoscore',
    '_clean',
    '_cleaned',
  ]) {
    if (s.endsWith(suffix)) s = s.substring(0, s.length - suffix.length);
  }
  return s.trim();
}

/// Suggests the key column: the one with distinct subject identifiers that match the most recordings.
String guessKeyColumn(List<String> headers, List<Map<String, String>> rows, List<String> recordings) {
  if (headers.isEmpty) return '';
  if (rows.isEmpty) return headers.first;

  // Regex patterns for identifier names vs. categorical/grouping names
  final isCategoricalName = RegExp(
    r'\b(group|cohort|arm|treatment|condition|gender|sex|status|stage|age|date|time|site|center|device|note|remark|comment|visit|education|slept)\b',
    caseSensitive: false,
  );
  final isCategoricalId = RegExp(
    r'^(group|cohort|arm|gender|sex|status|stage|age|date|site)[_\s-]?id$',
    caseSensitive: false,
  );
  final isStrongKeyName = RegExp(
    r'^(file|filename|filepath|record|recording|edf|eeg|subject|participant|patient|subject[_\s-]?id|participant[_\s-]?id|patient[_\s-]?id|record[_\s-]?id|file[_\s-]?id|nap[_\s-]?id)$',
    caseSensitive: false,
  );
  final isWeakKeyName = RegExp(
    r'(file|record|recording|edf|eeg|subject|participant|patient|nap)',
    caseSensitive: false,
  );

  var best = headers.first;
  var bestScore = -1000.0;

  for (final h in headers) {
    final trimmed = h.trim();
    if (trimmed.isEmpty) continue;

    // 1. Uniqueness / Cardinality check
    final nonBlankValues = rows.map((r) => (r[h] ?? '').trim()).where((s) => s.isNotEmpty).toList();
    if (nonBlankValues.isEmpty) continue;

    final uniqueValues = nonBlankValues.map(normalizeRecordingKey).where((s) => s.isNotEmpty).toSet();
    final uniquenessRatio = uniqueValues.length / nonBlankValues.length;

    // Categorical columns with very low cardinality (e.g. groupID with 2 values across 100 rows)
    // must never be chosen as primary keys.
    final isLowCardinality = nonBlankValues.length >= 4 && (uniqueValues.length <= 3 || uniquenessRatio < 0.20);
    final isCategorical = isCategoricalName.hasMatch(trimmed) || isCategoricalId.hasMatch(trimmed);

    // 2. Name bonus / penalty
    double nameScore = 0.0;
    if (isStrongKeyName.hasMatch(trimmed)) {
      nameScore += 10.0;
    } else if (isWeakKeyName.hasMatch(trimmed) && !isCategorical) {
      nameScore += 5.0;
    }
    if (isCategorical) {
      nameScore -= 15.0;
    }
    if (trimmed.toLowerCase() == 'sl.no.' || trimmed.toLowerCase() == 'sl no' || trimmed.toLowerCase() == 'sno') {
      nameScore -= 5.0; // Row numbers are not file keys
    }

    // 3. Matching recordings
    int matchCount = 0;
    final matchedRows = <int>{};
    if (recordings.isNotEmpty) {
      final t = BatchMetadataTable(sourcePath: '', headers: headers, rows: rows, keyColumn: h);
      for (final r in recordings) {
        final match = t.matchRecording(r);
        if (match != null) {
          matchCount++;
          final idx = rows.indexOf(match.row);
          if (idx >= 0) matchedRows.add(idx);
        }
      }
    }

    // 4. Combined scoring:
    // Distinct matched rows is the single most important metric: each recording should map to
    // a unique subject, not 100 recordings collapsing onto 1 or 2 rows.
    final distinctMatches = matchedRows.length;
    double score;

    if (recordings.isNotEmpty) {
      if (isLowCardinality && distinctMatches <= 3) {
        // Severe penalty for low-cardinality collapsing columns
        score = -500.0 + distinctMatches;
      } else {
        score = (distinctMatches * 20.0) + (matchCount * 2.0) + (uniquenessRatio * 15.0) + nameScore;
      }
    } else {
      // No recordings loaded yet: rely on column name and uniqueness
      if (isLowCardinality) {
        score = -500.0;
      } else {
        score = (uniquenessRatio * 20.0) + nameScore;
      }
    }

    if (score > bestScore) {
      bestScore = score;
      best = h;
    }
  }

  return best;
}

/// Reads a CSV, TSV/TXT or XLSX file (first worksheet with data).
Future<BatchMetadataTable> readBatchMetadataFile(String path) async {
  final lower = path.toLowerCase();
  List<List<String>> grid;
  String? sheet;
  if (lower.endsWith('.xlsx') || lower.endsWith('.xlsm')) {
    final r = _readXlsx(await File(path).readAsBytes());
    grid = r.$1;
    sheet = r.$2;
  } else if (lower.endsWith('.xls')) {
    throw const FormatException(
      'Old .xls workbooks are not supported. Save the sheet as .xlsx or .csv.',
    );
  } else {
    final bytes = await File(path).readAsBytes();
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('﻿')) text = text.substring(1);
    final lines = const LineSplitter().convert(text).where((l) => l.trim().isNotEmpty).toList();
    final tab = lower.endsWith('.tsv') ||
        lower.endsWith('.txt') ||
        (lines.isNotEmpty && lines.first.contains('\t') && !lines.first.contains(','));
    final semicolon = !tab &&
        lines.isNotEmpty &&
        lines.first.contains(';') &&
        !lines.first.contains(',');
    grid = [
      for (final l in lines)
        tab
            ? l.split('\t')
            : semicolon
                ? l.split(';')
                : parseCsvLine(l),
    ];
  }

  // Drop leading empty rows; first non-empty row is the header.
  grid = grid.where((r) => r.any((c) => c.trim().isNotEmpty)).toList();
  if (grid.length < 2) {
    throw const FormatException('The table needs a header row and at least one data row.');
  }
  final rawHeaders = grid.first.map((h) => h.trim()).toList();
  final headers = <String>[];
  for (var i = 0; i < rawHeaders.length; i++) {
    var h = rawHeaders[i].isEmpty ? 'Column ${i + 1}' : rawHeaders[i];
    var n = 2;
    final base = h;
    while (headers.contains(h)) {
      h = '$base ($n)';
      n++;
    }
    headers.add(h);
  }
  // Remove trailing empty columns without a header.
  final rows = <Map<String, String>>[
    for (final r in grid.skip(1))
      {for (var i = 0; i < headers.length; i++) headers[i]: i < r.length ? r[i].trim() : ''},
  ];
  final used = [
    for (var i = 0; i < headers.length; i++)
      if (rawHeaders[i].isNotEmpty || rows.any((r) => (r[headers[i]] ?? '').isNotEmpty)) headers[i],
  ];
  return BatchMetadataTable(
    sourcePath: path,
    headers: used,
    rows: [for (final r in rows) {for (final h in used) h: r[h] ?? ''}],
    keyColumn: used.first,
    sheetName: sheet,
  );
}

// ── Minimal XLSX reader (shared strings, inline strings, numbers) ──────────

(List<List<String>>, String?) _readXlsx(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  String? readText(String name) {
    for (final f in archive.files) {
      if (f.isFile && f.name.toLowerCase() == name.toLowerCase()) {
        return utf8.decode(f.content, allowMalformed: true);
      }
    }
    return null;
  }

  String unescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAllMapped(RegExp(r'&#(x?)([0-9a-fA-F]+);'), (m) {
        final code = int.tryParse(m.group(2)!, radix: m.group(1)!.isEmpty ? 10 : 16);
        return code == null ? m.group(0)! : String.fromCharCode(code);
      })
      .replaceAll('&amp;', '&');

  String textOf(String xml) => unescape(
        RegExp(r'<(?:\w+:)?t(?:\s[^>]*)?>(.*?)</(?:\w+:)?t>', dotAll: true)
            .allMatches(xml)
            .map((m) => m.group(1)!)
            .join(),
      );

  final shared = <String>[];
  final ss = readText('xl/sharedStrings.xml');
  if (ss != null) {
    for (final m in RegExp(r'<(?:\w+:)?si>(.*?)</(?:\w+:)?si>', dotAll: true).allMatches(ss)) {
      shared.add(textOf(m.group(1)!));
    }
  }

  // Sheets in workbook order → their part names via the relationships file.
  final sheets = <(String, String)>[];
  final wb = readText('xl/workbook.xml') ?? '';
  final rels = readText('xl/_rels/workbook.xml.rels') ?? '';
  final relTarget = <String, String>{};
  for (final m in RegExp(r'<Relationship\b([^>]*)/?>').allMatches(rels)) {
    final attrs = m.group(1)!;
    final id = RegExp(r'Id="([^"]+)"').firstMatch(attrs)?.group(1);
    final target = RegExp(r'Target="([^"]+)"').firstMatch(attrs)?.group(1);
    if (id != null && target != null) relTarget[id] = target;
  }
  for (final m in RegExp(r'<(?:\w+:)?sheet\b([^>]*)/?>').allMatches(wb)) {
    final attrs = m.group(1)!;
    final name = RegExp(r'name="([^"]*)"').firstMatch(attrs)?.group(1) ?? 'Sheet';
    final rid = RegExp(r'r:id="([^"]+)"').firstMatch(attrs)?.group(1);
    var target = rid == null ? null : relTarget[rid];
    if (target == null) continue;
    target = target.startsWith('/') ? target.substring(1) : 'xl/$target';
    sheets.add((unescape(name), target));
  }
  if (sheets.isEmpty) sheets.add(('Sheet1', 'xl/worksheets/sheet1.xml'));

  int colIndex(String ref) {
    var n = 0;
    for (final c in ref.codeUnits) {
      if (c < 65 || c > 90) break;
      n = n * 26 + (c - 64);
    }
    return n - 1;
  }

  for (final (name, part) in sheets) {
    final xml = readText(part);
    if (xml == null) continue;
    final grid = <List<String>>[];
    for (final rm in RegExp(r'<(?:\w+:)?row\b[^>]*>(.*?)</(?:\w+:)?row>', dotAll: true).allMatches(xml)) {
      final row = <String>[];
      for (final cm in RegExp(r'<(?:\w+:)?c\b([^>]*?)(?:/>|>(.*?)</(?:\w+:)?c>)', dotAll: true)
          .allMatches(rm.group(1)!)) {
        final attrs = cm.group(1) ?? '';
        final body = cm.group(2) ?? '';
        final ref = RegExp(r'r="([A-Z]+)\d+"').firstMatch(attrs)?.group(1);
        final type = RegExp(r't="([^"]+)"').firstMatch(attrs)?.group(1) ?? '';
        final v = RegExp(r'<(?:\w+:)?v>(.*?)</(?:\w+:)?v>', dotAll: true).firstMatch(body)?.group(1);
        String value;
        if (type == 's') {
          final i = int.tryParse(v ?? '');
          value = i != null && i >= 0 && i < shared.length ? shared[i] : '';
        } else if (type == 'inlineStr') {
          value = textOf(body);
        } else if (type == 'b') {
          value = v == '1' ? 'TRUE' : 'FALSE';
        } else {
          value = unescape(v ?? '');
          // 12.0 → 12
          final d = double.tryParse(value);
          if (d != null && d == d.roundToDouble() && d.abs() < 1e15 && value.contains('.')) {
            value = d.toInt().toString();
          }
        }
        final col = ref != null ? colIndex(ref) : row.length;
        while (row.length < col) {
          row.add('');
        }
        if (col < row.length) {
          row[col] = value;
        } else {
          row.add(value);
        }
      }
      grid.add(row);
    }
    if (grid.where((r) => r.any((c) => c.trim().isNotEmpty)).length >= 2) {
      return (grid, name);
    }
  }
  throw const FormatException('No worksheet with a header row and data was found.');
}
