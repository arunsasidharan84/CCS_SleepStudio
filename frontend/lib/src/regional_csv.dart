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
    String? edfPath;
    if (path.toLowerCase().endsWith('_analyse_regional.csv')) {
      edfPath =
          '${path.substring(0, path.length - '_analyse_regional.csv'.length)}.edf';
    } else {
      final lastDot = path.lastIndexOf('.');
      if (lastDot >= 0) {
        edfPath = '${path.substring(0, lastDot)}.edf';
      }
    }
    if (edfPath != null && File(edfPath).existsSync()) {
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

    for (final row in parsed) {
      for (final key in row.keys) {
        if (!headers.contains(key)) headers.add(key);
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

String resolveRegionalCsvEdfPath(
  String sourcePath, {
  String? masterDirectory,
  String? sourceFile,
}) {
  final candidates = <String>[];
  void addCandidate(String path) {
    if (path.isNotEmpty && !candidates.contains(path)) {
      candidates.add(path);
    }
  }

  addCandidate(_regionalCsvPathToEdfPath(sourcePath));

  if (masterDirectory != null && sourceFile != null && sourceFile.isNotEmpty) {
    addCandidate(
      _regionalCsvPathToEdfPath(
        '$masterDirectory${Platform.pathSeparator}$sourceFile',
      ),
    );
  }

  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
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
