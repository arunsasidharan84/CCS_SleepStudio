import 'dart:convert';
import 'dart:io';
import 'batch_metadata.dart';
import 'edf_loader.dart';

List<String> parseCsvLine(String line) {
  final fields = <String>[];
  final current = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final char = line[i];
    if (char == '"') {
      if (quoted && i + 1 < line.length && line[i + 1] == '"') {
        current.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (char == ',' && !quoted) {
      fields.add(current.toString());
      current.clear();
    } else {
      current.write(char);
    }
  }
  fields.add(current.toString());
  return fields;
}

List<Map<String, String>> parseCsvTable(String source) {
  final lines = const LineSplitter()
      .convert(source)
      .where((line) => line.trim().isNotEmpty)
      .toList();
  if (lines.length < 2) return const [];
  final headers = parseCsvLine(lines.first);
  final rows = <Map<String, String>>[];
  for (final line in lines.skip(1)) {
    final values = parseCsvLine(line);
    rows.add({
      for (var i = 0; i < headers.length; i++)
        headers[i]: i < values.length ? values[i] : '',
    });
  }
  return rows;
}

/// Regional CSVs that hold no data rows (e.g. a run interrupted after the
/// header was written). They are left out of master sheets.
Future<List<String>> regionalCsvFilesWithoutData(List<String> paths) async {
  final empty = <String>[];
  for (final path in paths) {
    try {
      if (parseCsvTable(await File(path).readAsString()).isEmpty) {
        empty.add(path);
      }
    } catch (_) {
      empty.add(path);
    }
  }
  return empty;
}

/// Compiles regional CSVs into one master sheet.
///
/// With [metadata], each row gets the matching metadata columns (matched on
/// the recording in [recordingPaths] when known, else on the CSV's name).
Future<String> compileRegionalCsvFiles(
  List<String> paths, {
  BatchMetadataTable? metadata,
  Map<String, String> recordingPaths = const {},
}) async {
  if (paths.isEmpty) {
    throw ArgumentError('Select at least one AnalyseNidra regional CSV file.');
  }
  const fixed = [
    'source_file',
    'source_path',
    'Subject Identifier',
    'Subject Details',
    'Recording Date',
  ];
  final headers = <String>[...fixed];
  final metaHeader = <String, String>{};
  if (metadata != null) {
    for (final h in metadata.headers) {
      final out = fixed.contains(h) ? 'Metadata: $h' : h;
      metaHeader[h] = out;
      headers.add(out);
    }
  }
  final rows = <Map<String, String>>[];

  for (final path in paths) {
    final file = File(path);
    final parsed = parseCsvTable(await file.readAsString());

    String recordingDate = '';
    String? edfPath = recordingPaths[path];
    if (edfPath == null || !File(edfPath).existsSync()) {
      edfPath = resolveRegionalCsvEdfPath(path);
    }
    if (File(edfPath).existsSync()) {
      final dt = EdfLoader.readStartDateTime(edfPath);
      if (dt != null) {
        recordingDate =
            '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
      }
    }

    final md = metadata;
    final meta = md?.lookup(recordingPaths[path] ?? path);
    var subjectId = '';
    if (md != null && meta != null) {
      final idPattern = RegExp(
        r'^(subject|participant|patient)?[ _]?(id|identifier|code)$|^subject$',
        caseSensitive: false,
      );
      final idCol = md.headers.firstWhere(
        (h) => idPattern.hasMatch(h.trim()),
        orElse: () => md.keyColumn,
      );
      subjectId = meta[idCol] ?? '';
    }

    // Look for companion CAP report (_cap.json) beside the regional CSV or the source recording
    final capSummary = <String, String>{};
    final candidates = <String>[];
    var regionalStem = file.uri.pathSegments.last;
    if (regionalStem.toLowerCase().endsWith('_analyse_regional.csv')) {
      regionalStem = regionalStem.substring(0, regionalStem.length - '_analyse_regional.csv'.length);
    }
    candidates.add('${file.parent.path}${Platform.pathSeparator}${regionalStem}_cap.json');
    final parentOfParent = file.parent.parent.path;
    if (parentOfParent != file.parent.path) {
      candidates.add('$parentOfParent${Platform.pathSeparator}${regionalStem}_cap.json');
    }
    final cleanPattern = RegExp(r'(_clean|_stimclean|_cleaned|_preprocessed)$', caseSensitive: false);
    if (regionalStem.contains(cleanPattern)) {
      final baseStem = regionalStem.replaceAll(cleanPattern, '');
      candidates.add('${file.parent.path}${Platform.pathSeparator}${baseStem}_cap.json');
      if (parentOfParent != file.parent.path) {
        candidates.add('$parentOfParent${Platform.pathSeparator}${baseStem}_cap.json');
      }
    }
    final srcPath = recordingPaths[path];
    if (srcPath != null && srcPath.isNotEmpty) {
      final srcFile = File(srcPath);
      var srcStem = srcFile.uri.pathSegments.last;
      final dot = srcStem.lastIndexOf('.');
      if (dot > 0) srcStem = srcStem.substring(0, dot);
      candidates.add('${srcFile.parent.path}${Platform.pathSeparator}${srcStem}_cap.json');
      if (srcStem.contains(cleanPattern)) {
        final baseStem = srcStem.replaceAll(cleanPattern, '');
        candidates.add('${srcFile.parent.path}${Platform.pathSeparator}${baseStem}_cap.json');
      }
    }
    for (final cPath in candidates) {
      final cFile = File(cPath);
      if (cFile.existsSync()) {
        try {
          final decoded = jsonDecode(await cFile.readAsString());
          if (decoded is Map && decoded['summary'] is Map) {
            final sum = decoded['summary'] as Map;
            for (final e in sum.entries) {
              final k = e.key.toString();
              final v = e.value;
              final col = k.toUpperCase().startsWith('CAP_') ? k : 'CAP_$k';
              final val = v is num ? (v.isFinite ? v.toStringAsFixed(3) : '') : (v?.toString() ?? '');
              capSummary[col] = val;
            }
            break;
          }
        } catch (_) {}
      }
    }

    // Also persist CAP metrics directly into the individual regional CSV
    // so standalone inspections of *_analyse_regional.csv contain CAP data.
    if (capSummary.isNotEmpty) {
      await updateRegionalCsvWithCapMetrics(file, capSummary);
    }

    for (final row in parsed) {
      for (final key in row.keys) {
        if (!headers.contains(key)) headers.add(key);
      }
      for (final capKey in capSummary.keys) {
        if (!headers.contains(capKey)) headers.add(capKey);
      }
      rows.add({
        'source_file': file.uri.pathSegments.last,
        'source_path': file.absolute.path,
        'Subject Identifier': subjectId,
        'Subject Details': '',
        'Recording Date': recordingDate,
        if (meta != null)
          for (final e in meta.entries) metaHeader[e.key] ?? e.key: e.value,
        ...row,
        ...capSummary,
      });
    }
  }

  final buffer = StringBuffer()..writeln(headers.map(_escapeCsv).join(','));
  for (final row in rows) {
    buffer.writeln(
      headers.map((header) => _escapeCsv(row[header] ?? '')).join(','),
    );
  }
  return buffer.toString();
}

/// Injects or updates companion CAP metrics directly into a regional CSV file.
Future<void> updateRegionalCsvWithCapMetrics(
  File file,
  Map<String, String> capSummary,
) async {
  updateRegionalCsvWithCapMetricsSync(file, capSummary);
}

/// Synchronously injects or updates companion CAP metrics directly into a regional CSV file.
void updateRegionalCsvWithCapMetricsSync(
  File file,
  Map<String, String> capSummary,
) {
  if (capSummary.isEmpty || !file.existsSync()) return;
  try {
    final raw = file.readAsStringSync();
    final parsed = parseCsvTable(raw);
    if (parsed.isEmpty) return;

    final existingHeaders = parsed.first.keys.toList();
    final newHeaders = <String>[...existingHeaders];
    for (final k in capSummary.keys) {
      if (!newHeaders.contains(k)) newHeaders.add(k);
    }

    final buf = StringBuffer()..writeln(newHeaders.map(_escapeCsv).join(','));
    for (final row in parsed) {
      final combined = {...row, ...capSummary};
      buf.writeln(newHeaders.map((h) => _escapeCsv(combined[h] ?? '')).join(','));
    }
    file.writeAsStringSync(buf.toString());
  } catch (e) {
    stderr.writeln('Could not update regional CSV with CAP metrics: $e');
  }
}

String resolveRegionalCsvEdfPath(
  String sourcePath, {
  String? masterDirectory,
  String? sourceFile,
  List<String> extraSearchDirectories = const [],
}) {
  final candidates = <String>[];
  void addCandidate(String path) {
    if (path.isNotEmpty && !candidates.contains(path)) {
      candidates.add(path);
    }
  }

  // Primary direct mapping
  addCandidate(_regionalCsvPathToEdfPath(sourcePath));

  if (masterDirectory != null && sourceFile != null && sourceFile.isNotEmpty) {
    addCandidate(
      _regionalCsvPathToEdfPath(
        '$masterDirectory${Platform.pathSeparator}$sourceFile',
      ),
    );
  }

  // Extract stems (raw stem and base stem without _clean / _stimclean)
  final rawEdf = _regionalCsvPathToEdfPath(
    sourceFile != null && sourceFile.isNotEmpty ? sourceFile : sourcePath,
  );
  final rawName = rawEdf.split(Platform.pathSeparator).last;
  final dotIdx = rawName.lastIndexOf('.');
  final rawStem = dotIdx > 0 ? rawName.substring(0, dotIdx) : rawName;
  final cleanRegex = RegExp(
    r'(_clean|_stimclean|_cleaned|_preprocessed)$',
    caseSensitive: false,
  );
  final baseStem = rawStem.replaceAll(cleanRegex, '');

  final stemVariants = <String>[
    rawStem,
    if (baseStem != rawStem && baseStem.isNotEmpty) baseStem,
    '${baseStem}_clean',
    '${baseStem}_stimclean',
  ];

  // Candidate directories to search
  final searchDirs = <String>[];
  void addDir(String? dir) {
    if (dir != null && dir.isNotEmpty && !searchDirs.contains(dir)) {
      searchDirs.add(dir);
    }
  }

  final srcParent = File(sourcePath).parent;
  addDir(srcParent.path);
  addDir(masterDirectory);
  for (final d in extraSearchDirectories) {
    addDir(d);
  }
  if (srcParent.parent.path != srcParent.path) {
    addDir(srcParent.parent.path);
  }
  if (masterDirectory != null && masterDirectory.isNotEmpty) {
    final mParent = Directory(masterDirectory).parent;
    if (mParent.path != masterDirectory) {
      addDir(mParent.path);
    }
  }

  for (final dir in searchDirs) {
    for (final stem in stemVariants) {
      addCandidate('$dir${Platform.pathSeparator}$stem.edf');
      addCandidate('$dir${Platform.pathSeparator}$stem.EDF');
    }
  }

  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }

  // Also check 1-level subdirectories of searchDirs if still not found
  for (final dir in searchDirs) {
    final dObj = Directory(dir);
    if (!dObj.existsSync()) continue;
    try {
      for (final entity in dObj.listSync(followLinks: false)) {
        if (entity is Directory) {
          for (final stem in stemVariants) {
            final p1 = '${entity.path}${Platform.pathSeparator}$stem.edf';
            if (File(p1).existsSync()) return p1;
            final p2 = '${entity.path}${Platform.pathSeparator}$stem.EDF';
            if (File(p2).existsSync()) return p2;
          }
        }
      }
    } catch (_) {}
  }

  return candidates.isNotEmpty ? candidates.first : sourcePath;
}

String _regionalCsvPathToEdfPath(String path) {
  final lower = path.toLowerCase();
  const suffix = '_analyse_regional.csv';
  if (lower.endsWith(suffix)) {
    return '${path.substring(0, path.length - suffix.length)}.edf';
  }
  if (lower.endsWith('.csv')) {
    return '${path.substring(0, path.length - '.csv'.length)}.edf';
  }
  return path;
}

String _escapeCsv(String value) {
  if (!value.contains(RegExp(r'[",\r\n]'))) return value;
  return '"${value.replaceAll('"', '""')}"';
}
