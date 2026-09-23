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

/// Extracts channel labels quickly from the header of [filePath] without loading full signals into memory.
Future<List<String>> extractRecordingChannels(String filePath) async {
  final file = File(filePath);
  if (!file.existsSync()) return [];

  final lower = filePath.toLowerCase();

  // 1. EDF / BDF (Standard 256-byte header + 16 bytes per signal)
  if (lower.endsWith('.edf') || lower.endsWith('.bdf')) {
    RandomAccessFile? raf;
    try {
      raf = await file.open(mode: FileMode.read);
      final len = await raf.length();
      if (len < 256) return [];
      final header = await raf.read(256);
      final countStr = latin1.decode(header.sublist(252, 256)).trim();
      final count = int.tryParse(countStr) ?? 0;
      if (count <= 0) return [];
      final labelBytes = await raf.read(count * 16);
      final labels = <String>[];
      for (var i = 0; i < count; i++) {
        final raw = latin1.decode(labelBytes.sublist(i * 16, (i + 1) * 16)).trim();
        if (raw.isNotEmpty &&
            !raw.toLowerCase().contains('status') &&
            !raw.toLowerCase().contains('annotation')) {
          labels.add(raw);
        }
      }
      return labels;
    } catch (_) {
      return [];
    } finally {
      await raf?.close();
    }
  }

  // 2. BrainVision .vhdr text file
  if (lower.endsWith('.vhdr')) {
    try {
      final lines = await file.readAsLines();
      final labels = <String>[];
      bool inChannelInfos = false;
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
          inChannelInfos = trimmed.toLowerCase() == '[channel infos]';
          continue;
        }
        if (inChannelInfos && trimmed.startsWith('Ch') && trimmed.contains('=')) {
          final parts = trimmed.split('=')[1].split(',');
          if (parts.isNotEmpty && parts[0].trim().isNotEmpty) {
            labels.add(parts[0].trim());
          }
        }
      }
      return labels;
    } catch (_) {
      return [];
    }
  }

  // 3. Orbit / Signal JSON files
  if (lower.endsWith('.orb') || lower.endsWith('.signal')) {
    try {
      final lines = await file.openRead().transform(utf8.decoder).transform(const LineSplitter()).take(30).toList();
      bool has4Channels = false;
      for (final line in lines) {
        try {
          final decoded = json.decode(line);
          if (decoded is Map && decoded['C'] is List && (decoded['C'] as List).length > 1) {
            has4Channels = true;
            break;
          }
        } catch (_) {}
      }
      return has4Channels ? ['AF7', 'AF8', 'Ch3', 'Ch4', 'PPG'] : ['AF7', 'AF8', 'PPG'];
    } catch (_) {
      return ['AF7', 'AF8', 'PPG'];
    }
  }

  return [];
}

/// Identifies whether [rawLabel] is likely an EEG electrode channel according to the 10-20/10-10 system.
bool isLikelyEegChannel(String rawLabel) {
  final label = rawLabel
      .replaceAll(RegExp(r'^(EEG\s*|POL\s*)', caseSensitive: false), '')
      .replaceAll(RegExp(r'(-Ref|-REF|\s*Ref)$', caseSensitive: false), '')
      .trim();
  final lower = label.toLowerCase();

  // Non-EEG physiological or auxiliary channels
  if (lower.startsWith('ecg') ||
      lower.startsWith('ekg') ||
      lower.startsWith('emg') ||
      lower.startsWith('eog') ||
      lower.startsWith('ppg') ||
      lower.startsWith('pleth') ||
      lower.startsWith('pulse') ||
      lower.startsWith('spo2') ||
      lower.startsWith('sao2') ||
      lower.startsWith('resp') ||
      lower.startsWith('chest') ||
      lower.startsWith('abd') ||
      lower.startsWith('airflow') ||
      lower.startsWith('nasal') ||
      lower.startsWith('therm') ||
      lower.startsWith('body') ||
      lower.startsWith('pos') ||
      lower.startsWith('sound') ||
      lower.startsWith('mic') ||
      lower.startsWith('light') ||
      lower.startsWith('temp') ||
      lower.startsWith('event') ||
      lower.startsWith('status') ||
      lower.startsWith('annot') ||
      lower == 'a1' ||
      lower == 'a2' ||
      lower == 'm1' ||
      lower == 'm2') {
    return false;
  }

  // 10-20, 10-10, 10-5 standard EEG electrode labels
  final eegPattern = RegExp(
    r'^(Fp[12z]|AF[1-9z]|F[1-9z]|FC[1-6z]|FT[7-9]|FT10|C[1-6z]|T[3-8]|TP[7-9]|TP10|CP[1-6z]|P[1-9z]|PO[1-9z]|O[12z]|Oz|Cz|Fz|Pz|Iz)$',
    caseSensitive: false,
  );
  return eegPattern.hasMatch(label) || rawLabel.toLowerCase().contains('eeg');
}

/// Shows a dialog allowing the user to view all channels from the recording and select whichever channels they want.
Future<List<String>?> showChannelSelectionDialog({
  required BuildContext context,
  required String title,
  required String recordingPath,
  required List<String> availableChannels,
  required List<String> initialSelectedChannels,
}) async {
  final fileName = recordingPath.split(Platform.isWindows ? r'\' : '/').last;
  final selected = <String>{};

  // Normalize initial selections to match available channels
  for (final sel in initialSelectedChannels) {
    for (final avail in availableChannels) {
      if (avail.toLowerCase() == sel.toLowerCase() ||
          avail.toLowerCase().replaceAll(' ', '') == sel.toLowerCase().replaceAll(' ', '')) {
        selected.add(avail);
      }
    }
  }

  String filterQuery = '';

  return showDialog<List<String>>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          final displayedChannels = filterQuery.isEmpty
              ? availableChannels
              : availableChannels
                  .where((c) => c.toLowerCase().contains(filterQuery.toLowerCase()))
                  .toList();

          return AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.tune, color: Colors.blue),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text(
                        'Extracted from 1st file: $fileName (${availableChannels.length} channels)',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade700, fontWeight: FontWeight.normal),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 620,
              height: 480,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: InputDecoration(
                            hintText: 'Filter channels (e.g. C3, Fz)...',
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
                      const SizedBox(width: 8),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue.shade50,
                          foregroundColor: Colors.blue.shade900,
                          elevation: 0,
                        ),
                        onPressed: () {
                          setState(() {
                            for (final ch in availableChannels) {
                              if (isLikelyEegChannel(ch)) {
                                selected.add(ch);
                              }
                            }
                          });
                        },
                        child: const Text('Select EEG Only'),
                      ),
                      const SizedBox(width: 6),
                      OutlinedButton(
                        onPressed: () {
                          setState(() {
                            selected.addAll(displayedChannels);
                          });
                        },
                        child: const Text('All'),
                      ),
                      const SizedBox(width: 6),
                      OutlinedButton(
                        onPressed: () {
                          setState(() {
                            selected.removeAll(displayedChannels);
                          });
                        },
                        child: const Text('Clear'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Selected ${selected.length} of ${availableChannels.length} channel(s):',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      if (selected.isNotEmpty)
                        Flexible(
                          child: Text(
                            selected.join(', '),
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade700, fontStyle: FontStyle.italic),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(6),
                        color: Colors.grey.shade50,
                      ),
                      padding: const EdgeInsets.all(8),
                      child: displayedChannels.isEmpty
                          ? const Center(child: Text('No channels match your filter.'))
                          : SingleChildScrollView(
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: displayedChannels.map((channel) {
                                  final isSel = selected.contains(channel);
                                  final isEeg = isLikelyEegChannel(channel);
                                  return FilterChip(
                                    label: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          channel,
                                          style: TextStyle(
                                            fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                                            color: isSel ? Colors.blue.shade900 : Colors.black87,
                                          ),
                                        ),
                                        if (isEeg) ...[
                                          const SizedBox(width: 4),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                            decoration: BoxDecoration(
                                              color: isSel ? Colors.blue.shade200 : Colors.grey.shade300,
                                              borderRadius: BorderRadius.circular(3),
                                            ),
                                            child: const Text(
                                              'EEG',
                                              style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    selected: isSel,
                                    selectedColor: Colors.blue.shade100,
                                    checkmarkColor: Colors.blue.shade900,
                                    onSelected: (val) {
                                      setState(() {
                                        if (val) {
                                          selected.add(channel);
                                        } else {
                                          selected.remove(channel);
                                        }
                                      });
                                    },
                                  );
                                }).toList(),
                              ),
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
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                ),
                onPressed: () {
                  // Maintain channel ordering from availableChannels
                  final ordered = availableChannels.where((c) => selected.contains(c)).toList();
                  Navigator.of(dialogContext).pop(ordered);
                },
                child: Text('Apply (${selected.length} channels)'),
              ),
            ],
          );
        },
      );
    },
  );
}

