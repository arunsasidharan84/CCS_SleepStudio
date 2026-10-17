import 'dart:convert';
import 'dart:io';

/// Legacy file migration tool for CCS Sleep Studio.
/// Converts scattered, ambiguous `.json` sidecars to standardized `.ccs*` formats
/// while strictly preserving data contents and enabling undo tracking via
/// `legacy_names.ccsmigration`.
class LegacyFileMigration {
  /// File pattern definitions: (legacySuffix, newSuffix, optional internalHeaderCheck)
  static const List<(String, String)> standardReplacements = [
    ('.config.json', '.ccsconfig'),
    ('_config.json', '.ccsconfig'),
    ('_scoring.json', '.ccsscoring'),
    ('_analyse_spindles.json', '.ccsspindles'),
    ('_spindles.json', '.ccsspindles'),
    ('.spindles.json', '.ccsspindles'),
    ('_analyse_slow_waves.json', '.ccsslowwaves'),
    ('_slow_waves.json', '.ccsslowwaves'),
    ('.slow_waves.json', '.ccsslowwaves'),
    ('_analyse_pac.json', '.ccspac'),
    ('_analyse_core.json', '.ccscore'),
    ('_analyse_nlg.json', '.ccsnlg'),
    ('_respiratory.json', '.ccsrespiratory'),
    ('_plm.json', '.ccsplm'),
    ('_cap.json', '.ccscap'),
    ('.edf.json', '.edf.ccsmeta'),
  ];

  static Future<Map<String, String>> plan(String folder) async {
    final dir = Directory(folder);
    if (!await dir.exists()) return const {};

    final files = (await dir.list().toList()).whereType<File>().toList();
    final moves = <String, String>{};

    for (final file in files) {
      final path = file.path;
      final fileName = path.split(RegExp(r'[\\/]')).last;
      String? target;

      // Check standard replacements
      for (final pair in standardReplacements) {
        if (fileName.endsWith(pair.$1)) {
          final base = fileName.substring(0, fileName.length - pair.$1.length);
          target = '${file.parent.path}${Platform.pathSeparator}$base${pair.$2}';
          break;
        }
      }

      // Check autoscore naming: e.g. <stem>_<model>_scoring.json -> <stem>_<model>.ccsscoring
      if (target == null && fileName.endsWith('.json')) {
        final lower = fileName.toLowerCase();
        final match = RegExp(
          r'^(.*?)_(yasa|gssc|tinysleepnet|seqsleepnet|sleeptransformer|usleep|luna|dreamento|sleepeegpy)(?:_sleepgpt)?(?:_scoring)?\.json$',
        ).firstMatch(lower);
        if (match != null) {
          final prefixAndModel = fileName.substring(0, fileName.length - 5);
          final clean = prefixAndModel.endsWith('_scoring')
              ? prefixAndModel.substring(0, prefixAndModel.length - 8)
              : prefixAndModel;
          target = '${file.parent.path}${Platform.pathSeparator}$clean.ccsscoring';
        }
      }

      // Check for CCSEEG signal JSON files: "format": "ccseeg-v1"
      if (target == null && fileName.endsWith('.json')) {
        try {
          final handle = await file.open();
          String header;
          try {
            final first = await handle.read(2048);
            header = utf8.decode(first, allowMalformed: true);
          } finally {
            await handle.close();
          }
          if (RegExp(r'"format"\s*:\s*"ccseeg-v1"').hasMatch(header)) {
            final base = fileName.substring(0, fileName.length - 5);
            target = '${file.parent.path}${Platform.pathSeparator}$base.ccseeg';
          }
        } catch (_) {}
      }

      if (target != null && target != path) {
        moves[path] = target;
      }
    }

    if (moves.values.toSet().length != moves.length) {
      throw const FormatException(
        'Duplicate target filenames detected; resolve conflicting files first.',
      );
    }
    for (final target in moves.values) {
      if (await File(target).exists()) {
        throw FormatException(
          'Target file already exists: ${target.split(RegExp(r"[\\/]")).last}. No files were changed.',
        );
      }
    }
    return moves;
  }

  static Future<void> apply(String folder, Map<String, String> moves) async {
    if (moves.isEmpty) return;
    final manifest = File('$folder${Platform.pathSeparator}legacy_names.ccsmigration');
    if (await manifest.exists()) {
      throw const FormatException('A migration manifest already exists in this folder.');
    }

    // Verify all source files still exist and no target exists
    for (final entry in moves.entries) {
      if (!await File(entry.key).exists() || await File(entry.value).exists()) {
        throw const FormatException(
          'Files changed since preview. Review the folder again.',
        );
      }
    }

    await manifest.writeAsString(
      jsonEncode({
        'schema': 'ccs-sleep-migration-v1',
        'renames': moves,
        'timestamp': DateTime.now().toIso8601String(),
      }),
    );

    final done = <MapEntry<String, String>>[];
    try {
      for (final entry in moves.entries) {
        await File(entry.key).rename(entry.value);
        done.add(entry);
      }
    } catch (_) {
      for (final entry in done.reversed) {
        await File(entry.value).rename(entry.key);
      }
      if (await manifest.exists()) await manifest.delete();
      rethrow;
    }

    // Update internal file references if any text/json files point to the old paths
    for (final path in moves.values) {
      if (path.endsWith('.ccsconfig') || path.endsWith('.ccsmeta')) {
        final file = File(path);
        try {
          String normalise(String value) {
            final p = value.replaceAll('\\', '/');
            return Platform.isWindows ? p.toLowerCase() : p;
          }

          final references = {
            for (final e in moves.entries) normalise(e.key): e.value,
          };
          dynamic rewrite(dynamic value) {
            if (value is String) return references[normalise(value)] ?? value;
            if (value is List) return value.map(rewrite).toList();
            if (value is Map) {
              return value.map(
                (key, item) => MapEntry(key.toString(), rewrite(item)),
              );
            }
            return value;
          }

          final content = await file.readAsString();
          final decoded = jsonDecode(content);
          await file.writeAsString(jsonEncode(rewrite(decoded)));
        } catch (_) {
          // If rewrite fails for a specific file, file content remains unchanged
        }
      }
    }
  }
}
