import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';

/// Helper utilities for batch file discovery, sub-selection, and logging.

/// Checks whether [filePath] matches a glob-like wildcard pattern [pattern].
/// Supports '*' (any characters except delimiter or across all) and '?' (single char).
bool matchesWildcard(String filePath, String pattern) {
  final normalizedPath = filePath.replaceAll(r'\', '/');
  final normalizedPattern = pattern.trim().replaceAll(r'\', '/');

  if (normalizedPattern.isEmpty || normalizedPattern == '*' || normalizedPattern == '*.*') {
    return true;
  }

  // Convert glob wildcards to regex pattern
  final regexBuffer = StringBuffer('^');
  int i = 0;
  while (i < normalizedPattern.length) {
    final char = normalizedPattern[i];
    if (char == '*') {
      if (i + 1 < normalizedPattern.length && normalizedPattern[i + 1] == '*') {
        // '**' matches anything including slashes
        regexBuffer.write('.*');
        i += 2;
        if (i < normalizedPattern.length && normalizedPattern[i] == '/') {
          i++; // skip trailing slash after **
        }
        continue;
      } else {
        // single '*' matches anything within directory or segment
        regexBuffer.write(r'[^/]*');
      }
    } else if (char == '?') {
      regexBuffer.write(r'[^/]');
    } else if (r'.+^$()[]{}|'.contains(char)) {
      regexBuffer.write('\\$char');
    } else {
      regexBuffer.write(char);
    }
    i++;
  }
  regexBuffer.write(r'$');

  final regExp = RegExp(regexBuffer.toString(), caseSensitive: false);
  final fileName = normalizedPath.split('/').last;

  // Match either against the full relative path or just the filename
  return regExp.hasMatch(normalizedPath) || regExp.hasMatch(fileName);
}

/// Recursively scans [directoryPath] for files matching [pattern] and allowed extensions.
Future<List<String>> scanDirectoryWithPattern({
  required String directoryPath,
  required String pattern,
  required List<String> allowedExtensions,
}) async {
  final dir = Directory(directoryPath);
  if (!dir.existsSync()) return [];

  final results = <String>[];
  final lowerExts = allowedExtensions.map((e) => e.toLowerCase().replaceAll('.', '')).toSet();

  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      final ext = entity.path.split('.').last.toLowerCase();
      if (lowerExts.isEmpty || lowerExts.contains(ext)) {
        if (matchesWildcard(entity.path, pattern)) {
          results.add(entity.path);
        }
      }
    }
  }

  results.sort();
  return results;
}

/// Shows a dialog allowing the user to view matched files, search, and manually select/deselect files.
Future<List<String>?> showBatchFileSubSelectionDialog({
  required BuildContext context,
  required String title,
  required List<String> files,
}) async {
  final selected = Set<String>.from(files);
  String filterQuery = '';

  return showDialog<List<String>>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          final displayedFiles = filterQuery.isEmpty
              ? files
              : files.where((f) => f.toLowerCase().contains(filterQuery.toLowerCase())).toList();

          return AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 700,
              height: 520,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: InputDecoration(
                            hintText: 'Filter displayed files by keyword...',
                            prefixIcon: const Icon(Icons.search, size: 20),
                            isDense: true,
                            border: const OutlineInputBorder(),
                            suffixIcon: filterQuery.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear, size: 16),
                                    onPressed: () => setState(() => filterQuery = ''),
                                  )
                                : null,
                          ),
                          onChanged: (val) => setState(() => filterQuery = val.trim()),
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton(
                        onPressed: () {
                          setState(() {
                            selected.addAll(displayedFiles);
                          });
                        },
                        child: const Text('Select All'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: () {
                          setState(() {
                            selected.removeAll(displayedFiles);
                          });
                        },
                        child: const Text('Deselect All'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Selected ${selected.length} of ${files.length} file(s)',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: displayedFiles.isEmpty
                          ? const Center(child: Text('No files match the filter query.'))
                          : ListView.separated(
                              itemCount: displayedFiles.length,
                              separatorBuilder: (ctx, idx) => const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final path = displayedFiles[index];
                                final isChecked = selected.contains(path);
                                final fileName = path.split(Platform.isWindows ? r'\' : '/').last;
                                final dirName = File(path).parent.path;

                                return CheckboxListTile(
                                  dense: true,
                                  value: isChecked,
                                  title: Text(
                                    fileName,
                                    style: const TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                  subtitle: Text(
                                    dirName,
                                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onChanged: (val) {
                                    setState(() {
                                      if (val == true) {
                                        selected.add(path);
                                      } else {
                                        selected.remove(path);
                                      }
                                    });
                                  },
                                );
                              },
                            ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(null),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(dialogContext).pop(selected.toList()),
                child: Text('Confirm Selection (${selected.length})'),
              ),
            ],
          );
        },
      );
    },
  );
}

/// Writes an execution log for a batch job.
Future<void> writeBatchFileLog({
  required String outputFolder,
  required String originalFilePath,
  required String jobType, // e.g. 'autoscore' or 'analyse'
  required int exitCode,
  required List<String> logLines,
}) async {
  try {
    final baseName = originalFilePath
        .split(Platform.isWindows ? r'\' : '/')
        .last
        .replaceAll(RegExp(r'\.[^.]+$'), '');
    final outDir = Directory(outputFolder);
    if (!outDir.existsSync()) {
      outDir.createSync(recursive: true);
    }

    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final logPath = '${outDir.path}${Platform.pathSeparator}${baseName}_${jobType}_log_$timestamp.txt';

    final buffer = StringBuffer();
    buffer.writeln('=== CCS Sleep Studio Batch Job Log ===');
    buffer.writeln('Job Type: $jobType');
    buffer.writeln('Source File: $originalFilePath');
    buffer.writeln('Timestamp: ${DateTime.now().toIso8601String()}');
    buffer.writeln('Status: ${exitCode == 0 ? "SUCCESS" : "FAILED (Exit Code: $exitCode)"}');
    buffer.writeln('----------------------------------------');
    buffer.writeln('Output Logs:');
    for (final line in logLines) {
      buffer.writeln(line);
    }
    buffer.writeln('----------------------------------------');
    buffer.writeln('=== End of Log ===');

    final file = File(logPath);
    await file.writeAsString(buffer.toString());
  } catch (e) {
    // Logging failure shouldn't crash the batch run
    stderr.writeln('Failed to write batch log file: $e');
  }
}

/// Record of an individual file's result within a batch run.
class BatchFileResult {
  const BatchFileResult({
    required this.filePath,
    required this.exitCode,
    required this.logs,
  });

  final String filePath;
  final int exitCode;
  final List<String> logs;
}

/// Writes a comprehensive single master log file containing the entire batch run history across all files.
Future<void> writeBatchRunSummaryLog({
  required String outputFolder,
  required String jobType, // 'autoscore' or 'analyse'
  required DateTime startTime,
  required DateTime endTime,
  required List<BatchFileResult> results,
}) async {
  try {
    final outDir = Directory(outputFolder);
    if (!outDir.existsSync()) {
      outDir.createSync(recursive: true);
    }

    final timestamp = startTime.toIso8601String().replaceAll(':', '-');
    final logPath = '${outDir.path}${Platform.pathSeparator}batch_${jobType}_master_run_log_$timestamp.txt';

    final total = results.length;
    final successful = results.where((r) => r.exitCode == 0).length;
    final failed = total - successful;
    final durationSec = endTime.difference(startTime).inSeconds;

    final buffer = StringBuffer();
    buffer.writeln('================================================================');
    buffer.writeln('CCS SLEEP STUDIO — BATCH RUN MASTER LOG');
    buffer.writeln('================================================================');
    buffer.writeln('Job Type:          $jobType');
    buffer.writeln('Run Started:       ${startTime.toIso8601String()}');
    buffer.writeln('Run Finished:      ${endTime.toIso8601String()}');
    buffer.writeln('Total Duration:    ${durationSec}s');
    buffer.writeln('Total Files:       $total');
    buffer.writeln('Successful:        $successful');
    buffer.writeln('Failed:            $failed');
    buffer.writeln('================================================================');
    buffer.writeln('');
    buffer.writeln('--- SUMMARY TABLE ---');
    for (int i = 0; i < results.length; i++) {
      final res = results[i];
      final fileName = res.filePath.split(Platform.isWindows ? r'\' : '/').last;
      final status = res.exitCode == 0 ? 'SUCCESS' : 'FAILED (code ${res.exitCode})';
      buffer.writeln('[${i + 1}/$total] $status — $fileName');
    }
    buffer.writeln('');
    buffer.writeln('================================================================');
    buffer.writeln('DETAILED LOGS PER FILE');
    buffer.writeln('================================================================');

    for (int i = 0; i < results.length; i++) {
      final res = results[i];
      buffer.writeln('');
      buffer.writeln('----------------------------------------------------------------');
      buffer.writeln('FILE [${i + 1}/$total]: ${res.filePath}');
      buffer.writeln('STATUS: ${res.exitCode == 0 ? "SUCCESS" : "FAILED (code ${res.exitCode})" }');
      buffer.writeln('----------------------------------------------------------------');
      for (final line in res.logs) {
        buffer.writeln(line);
      }
    }

    buffer.writeln('');
    buffer.writeln('================================================================');
    buffer.writeln('END OF MASTER BATCH RUN LOG');
    buffer.writeln('================================================================');

    final file = File(logPath);
    await file.writeAsString(buffer.toString());
  } catch (e) {
    stderr.writeln('Failed to write master batch log: $e');
  }
}

