// lib/src/scoring_io.dart
//
// Scoring file I/O — port of ScoringHero-0.2.4 scoring/ module.
// Supports read/write for: ScoringHero JSON, YASA .txt, Sleeptrip .csv, Zurich .vis

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'models.dart';

import 'eeg_backend.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Auto-save (ScoringHero JSON) – called after every stage change
// ─────────────────────────────────────────────────────────────────────────────

/// Write stages to the ScoringHero JSON file next to the source EDF/MAT.
/// If [activePath] is null (demo mode), no file is written.
Future<void> autoSaveScoring(
  String? activePath,
  List<SleepStage> stages,
  int epochSeconds, {
  List<ScoredEvent> events = const [],
  List<bool>? stagesUncertain,
  List<double?>? stagesConfidence,
  List<Map<SleepStage, double>>? stageProbabilities,
}) async {
  if (activePath == null) return;
  final jsonPath = _jsonPathForEdf(activePath);
  try {
    await _writeJsonScoring(
      jsonPath,
      stages,
      epochSeconds,
      activePath,
      events: events,
      stagesUncertain: stagesUncertain,
      stagesConfidence: stagesConfidence,
      stageProbabilities: stageProbabilities,
    );
  } catch (_) {
    // Auto-save failure is non-fatal
  }
}

Future<void> writeMappedScoringJson(
  String path,
  List<SleepStage> stages, {
  int epochSeconds = 30,
  String? sourcePath,
  List<ScoredEvent> events = const [],
  List<bool>? stagesUncertain,
  List<double?>? stagesConfidence,
  List<Map<SleepStage, double>>? stageProbabilities,
}) {
  return _writeJsonScoring(
    path,
    stages,
    epochSeconds,
    sourcePath ?? path,
    events: events,
    stagesUncertain: stagesUncertain,
    stagesConfidence: stagesConfidence,
    stageProbabilities: stageProbabilities,
  );
}

/// Load scoring from the JSON file that lives next to the EDF or in [extraDirectories].
Future<ScoringLoadResult?> tryLoadAutoScoring(
  String activePath,
  int epochCount, {
  List<String> extraDirectories = const [],
  String? explicitScoringPath,
}) async {
  final paths = <String>[
    if (explicitScoringPath != null &&
        explicitScoringPath.isNotEmpty &&
        File(explicitScoringPath).existsSync())
      explicitScoringPath,
    ..._autoScoringCandidatePaths(activePath, extraDirectories: extraDirectories),
  ];
  ScoringLoadResult? primary;
  for (final path in paths) {
    try {
      primary = await loadScoringFile(path, epochCount: epochCount);
      if (primary != null && primary.stages.any((s) => s.isScored)) {
        break;
      }
    } catch (_) {
      // Keep looking for another sidecar.
    }
  }
  if (primary == null) return null;

  if (_hasStageProbabilities(primary) && _hasConfidence(primary)) {
    return primary;
  }

  for (final path in paths.skip(1)) {
    try {
      final supplemental = await loadScoringFile(path, epochCount: epochCount);
      if (supplemental != null &&
          (_hasStageProbabilities(supplemental) || _hasConfidence(supplemental))) {
        return _mergeScoringMetadata(primary, supplemental);
      }
    } catch (_) {
      // Probability sidecars are optional.
    }
  }

  return primary;
}

List<String> _autoScoringCandidatePaths(
  String activePath, {
  List<String> extraDirectories = const [],
}) {
  final file = File(activePath);
  final filename = file.uri.pathSegments.isNotEmpty
      ? file.uri.pathSegments.last
      : activePath.split(Platform.pathSeparator).last;
  final dotIdx = filename.lastIndexOf('.');
  final rawStem = dotIdx >= 0 ? filename.substring(0, dotIdx) : filename;
  final cleanRegex = RegExp(
    r'(_clean|_stimclean|_cleaned|_preprocessed)$',
    caseSensitive: false,
  );
  final baseStem = rawStem.replaceAll(cleanRegex, '');
  final stems = <String>[
    rawStem,
    if (baseStem != rawStem && baseStem.isNotEmpty) baseStem,
  ];

  final dirs = <Directory>[
    file.parent,
    for (final d in extraDirectories)
      if (d.isNotEmpty) Directory(d),
    if (file.parent.parent.path != file.parent.path) file.parent.parent,
  ];

  final candidates = <String>[];
  void add(String path) {
    if (File(path).existsSync() && !candidates.contains(path)) {
      candidates.add(path);
    }
  }

  for (final directory in dirs) {
    if (!directory.existsSync()) continue;
    for (final stem in stems) {
      final basePath = '${directory.path}${Platform.pathSeparator}$stem';
      add('${basePath}_scoring.json');
      add('$basePath.json');
    }

    final extraFiles = directory.listSync(followLinks: false).whereType<File>().toList();
    for (final fileEntry in extraFiles) {
      final p = fileEntry.path.toLowerCase();
      if (p.endsWith('.esrc') || p.endsWith('.esedb')) {
        add(fileEntry.path);
      }
    }

    for (final stem in stems) {
      final modelSidecars = extraFiles
          .where((entry) => _isAutoscoreSidecarForStem(entry.path, stem))
          .toList()
        ..sort((a, b) {
          final bModified = b.statSync().modified;
          final aModified = a.statSync().modified;
          return bModified.compareTo(aModified);
        });
      for (final sidecar in modelSidecars) {
        add(sidecar.path);
      }
    }
  }

  return candidates;
}

bool _isAutoscoreSidecarForStem(String path, String stem) {
  final name = path.split(Platform.pathSeparator).last;
  if (!name.startsWith('${stem}_') || !name.toLowerCase().endsWith('.json')) {
    return false;
  }
  final suffix = name.substring(stem.length).toLowerCase();
  return RegExp(
    r'^_(yasa|gssc|tinysleepnet|seqsleepnet|sleeptransformer|usleep|luna|dreamento|sleepeegpy)(?:_sleepgpt)?(?:_scoring)?\.json$',
  ).hasMatch(suffix);
}

Future<List<ScoredEvent>> tryLoadAutoEvents(
  String activePath, {
  List<String> extraDirectories = const [],
  String? explicitScoringPath,
}) async {
  final candidates = <String>[
    if (explicitScoringPath != null && explicitScoringPath.trim().isNotEmpty)
      explicitScoringPath.trim(),
    ..._autoScoringCandidatePaths(
      activePath,
      extraDirectories: extraDirectories,
    ),
  ];
  for (final jsonPath in candidates) {
    final file = File(jsonPath);
    if (!file.existsSync()) continue;
    try {
      final content = await file.readAsString();
      final dynamic json = jsonDecode(content);
      if (json is List && json.length >= 2 && json[1] is List) {
        final events = _parseEvents(json[1] as List<dynamic>);
        if (events.isNotEmpty) return events;
      }
    } catch (_) {}
  }
  return const [];
}

/// Load config from the JSON file that lives next to the EDF (auto-loaded on open).
Future<AppConfig?> tryLoadAutoConfig(String activePath) async {
  final dotIdx = activePath.lastIndexOf('.');
  final base = dotIdx >= 0 ? activePath.substring(0, dotIdx) : activePath;
  final configPath = '$base.config.json';
  var file = File(configPath);

  // Also try an alternative naming convention: base_config.json
  if (!file.existsSync()) {
    final altPath = '${base}_config.json';
    final altFile = File(altPath);
    if (altFile.existsSync()) {
      file = altFile;
    } else {
      // Filesystem might not have synced yet — retry once after a brief delay
      await Future.delayed(const Duration(milliseconds: 50));
      if (file.existsSync()) {
        // Found after brief delay
      } else if (altFile.existsSync()) {
        file = altFile;
      } else {
        return null;
      }
    }
  }

  try {
    final content = await file.readAsString();
    if (content.trim().isEmpty) {
      // ignore: avoid_print
      print('[CCS Sleep Studio] Config file exists but is empty: ${file.path}');
      return null;
    }
    final json = jsonDecode(content);
    if (json is Map<String, dynamic>) {
      // ignore: avoid_print
      print('[CCS Sleep Studio] Loaded config (Map format) from: ${file.path}');
      return AppConfig.fromJson(json);
    }
    // ignore: avoid_print
    print('[CCS Sleep Studio] Loaded config (Python format) from: ${file.path}');
    return AppConfig.fromPythonJson(json, const []);
  } catch (e, stack) {
    // Config load error is non-fatal — log in debug so issues are visible
    // ignore: avoid_print
    print('[CCS Sleep Studio] Config load error (${file.path}): $e');
    // ignore: avoid_print
    print('[CCS Sleep Studio] Stack: $stack');
  }
  return null;
}

/// Save config next to the EDF file (e.g. base.config.json).
Future<void> saveAutoConfig(String activePath, AppConfig config) async {
  final dotIdx = activePath.lastIndexOf('.');
  final base = dotIdx >= 0 ? activePath.substring(0, dotIdx) : activePath;
  final configPath = '$base.config.json';
  try {
    final file = File(configPath);
    final json = jsonEncode(config.toPythonJson());
    await file.writeAsString(json);
  } catch (e) {
    // Non-fatal
  }
}

String _jsonPathForEdf(String edfPath) {
  final dotIdx = edfPath.lastIndexOf('.');
  final base = dotIdx >= 0 ? edfPath.substring(0, dotIdx) : edfPath;
  return '${base}_scoring.json';
}

// ─────────────────────────────────────────────────────────────────────────────
// ScoringHero JSON format
// ─────────────────────────────────────────────────────────────────────────────

/// JSON format (array of stage dicts, matching Python write_scoring.py):
/// [
///   {"epoch": 1, "start": 0.0, "end": 30.0, "stage": "N2", "digit": -2,
///    "confidence": null, "channels": [], "clean": 1, "source": "human"},
///   ...
/// ]
Future<void> _writeJsonScoring(
  String path,
  List<SleepStage> stages,
  int epochSeconds,
  String edfPath, {
  List<ScoredEvent> events = const [],
  List<bool>? stagesUncertain,
  List<double?>? stagesConfidence,
  List<Map<SleepStage, double>>? stageProbabilities,
}) async {
  final entries = <Map<String, dynamic>>[];
  for (var i = 0; i < stages.length; i++) {
    final stage = stages[i];
    final isUncertain =
        stagesUncertain != null &&
        i < stagesUncertain.length &&
        stagesUncertain[i];
    final confVal = stagesConfidence != null && i < stagesConfidence.length
        ? stagesConfidence[i]
        : null;
    final probabilities =
        stageProbabilities != null && i < stageProbabilities.length
        ? _probabilityJson(stageProbabilities[i])
        : null;
    entries.add({
      'epoch': i + 1,
      'start': i * epochSeconds.toDouble(),
      'end': (i + 1) * epochSeconds.toDouble(),
      'stage': stage.isScored ? stage.label : null,
      'digit': stage.isScored ? stage.code : null,
      'confidence': confVal ?? (isUncertain ? 0.0 : null),
      if (probabilities != null && probabilities.isNotEmpty)
        'probabilities': probabilities,
      'channels': <String>[],
      'clean': 1,
      'source': stage.isScored ? 'human' : null,
    });
  }
  final annotations = <Map<String, dynamic>>[];
  for (var i = 0; i < events.length; i++) {
    final event = events[i];
    annotations.add({
      'key': event.key,
      'event': event.label,
      'digit': event.digit,
      'counter': i,
      'epoch': event.epochs(epochSeconds, stages.length),
      'start': event.startSec,
      'end': event.endSec,
    });
  }
  final json = [entries, annotations]; // [stages_list, annotations_list]
  await File(
    path,
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(json));
}

Future<ScoringLoadResult> _loadJsonScoring(String path, int epochCount) async {
  final content = await File(path).readAsString();
  final dynamic json = jsonDecode(content);

  List<dynamic> entries;
  if (json is List && json.isNotEmpty && json[0] is List) {
    // [stages_list, annotations_list] format
    entries = json[0] as List<dynamic>;
  } else if (json is List) {
    entries = json;
  } else {
    return ScoringLoadResult(
      List.filled(epochCount, SleepStage.unknown),
      List.filled(epochCount, false),
    );
  }

  if (epochCount <= 0) {
    int maxEp = entries.length;
    for (final entry in entries) {
      if (entry is Map<String, dynamic>) {
        final ep = (entry['epoch'] as num?)?.toInt();
        if (ep != null && ep > maxEp) maxEp = ep;
      }
    }
    epochCount = math.max(1, maxEp);
  }

  final stages = List.filled(epochCount, SleepStage.unknown);
  final stagesUncertain = List.filled(epochCount, false);
  final stagesConfidence = List<double?>.filled(epochCount, null);
  final stageProbabilities = List<Map<SleepStage, double>>.filled(
    epochCount,
    const <SleepStage, double>{},
  );
  for (final entry in entries) {
    if (entry is Map<String, dynamic>) {
      final epochOneBased = (entry['epoch'] as num?)?.toInt();
      if (epochOneBased == null) continue;
      final idx = epochOneBased - 1;
      if (idx < 0 || idx >= epochCount) continue;
      final stageStr = entry['stage'] as String?;
      stages[idx] = SleepStage.fromLabel(stageStr);
      final confidence = entry['confidence'] as num?;
      stagesConfidence[idx] = confidence?.toDouble();
      if (confidence != null && confidence.toDouble() == 0.0) {
        stagesUncertain[idx] = true;
      }
      final probabilities = _parseProbabilityMap(entry['probabilities']);
      if (probabilities.isNotEmpty) {
        stageProbabilities[idx] = probabilities;
      }
    }
  }
  return ScoringLoadResult(
    stages,
    stagesUncertain,
    stagesConfidence: stagesConfidence,
    stageProbabilities: stageProbabilities,
  );
}

bool _hasConfidence(ScoringLoadResult result) {
  return result.stagesConfidence.any((value) => value != null);
}

bool _hasStageProbabilities(ScoringLoadResult result) {
  return result.stageProbabilities.any((entry) => entry.isNotEmpty);
}

ScoringLoadResult _mergeScoringMetadata(
  ScoringLoadResult primary,
  ScoringLoadResult supplemental,
) {
  final confidence = _hasConfidence(primary)
      ? primary.stagesConfidence
      : supplemental.stagesConfidence;
  final probabilities = _hasStageProbabilities(primary)
      ? primary.stageProbabilities
      : supplemental.stageProbabilities;

  return ScoringLoadResult(
    primary.stages,
    primary.stagesUncertain,
    stagesConfidence: confidence,
    stageProbabilities: probabilities,
    sourceFormat: primary.sourceFormat,
  );
}

Map<String, double> _probabilityJson(Map<SleepStage, double> probabilities) {
  final output = <String, double>{};
  for (final entry in probabilities.entries) {
    if (entry.key == SleepStage.unknown ||
        entry.key == SleepStage.inconclusive) {
      continue;
    }
    output[entry.key.shortLabel == 'REM' ? 'R' : entry.key.shortLabel] =
        entry.value;
  }
  return output;
}

Map<SleepStage, double> _parseProbabilityMap(dynamic value) {
  if (value is! Map) return const {};
  final output = <SleepStage, double>{};
  for (final entry in value.entries) {
    final stage = _stageFromYasaLabel(entry.key.toString());
    final probability = entry.value is num
        ? (entry.value as num).toDouble()
        : double.tryParse(entry.value.toString());
    if (stage != SleepStage.unknown && probability != null) {
      output[stage] = probability.clamp(0.0, 1.0);
    }
  }
  return output;
}

List<ScoredEvent> _parseEvents(List<dynamic> annotations) {
  final events = <ScoredEvent>[];
  for (final item in annotations) {
    if (item is! Map<String, dynamic>) continue;
    final digit = (item['digit'] as num?)?.toInt() ?? 0;
    final start = (item['start'] as num?)?.toDouble();
    final end = (item['end'] as num?)?.toDouble();
    if (start == null || end == null || end <= start) continue;
    events.add(
      ScoredEvent(
        digit: digit,
        key: item['key'] as String? ?? (digit == 0 ? 'A' : 'F$digit'),
        label:
            item['event'] as String? ??
            (digit == 0 ? 'Artifact' : 'Event $digit'),
        startSec: start,
        endSec: end,
      ),
    );
  }
  return events;
}

// ─────────────────────────────────────────────────────────────────────────────
// Import dialog — pick file and parse
// ─────────────────────────────────────────────────────────────────────────────

/// Show a file picker and import a scoring file. Returns the parsed stages list,
/// or null if cancelled or failed. [onStatus] is called with status messages.
Future<ScoringLoadResult?> importScoringDialog(
  int epochCount,
  String filetype, {
  required void Function(String) onStatus,
}) async {
  String dialogTitle;
  List<String> extensions;
  switch (filetype) {
    case 'scoringhero':
      dialogTitle = 'Load ScoringHero scoring (.json)';
      extensions = ['json'];
    case 'yasa':
      dialogTitle = 'Load YASA scoring (.txt)';
      extensions = ['txt'];
    case 'sleeptrip':
      dialogTitle = 'Load Sleeptrip scoring (.csv)';
      extensions = ['csv'];
    case 'vis':
      dialogTitle = 'Load Zurich scoring (.vis)';
      extensions = ['vis'];
    case 'sleepyland':
      dialogTitle = 'Load Sleepyland scoring (.annot)';
      extensions = ['annot'];
    case 'gssc':
      dialogTitle = 'Load GSSC scoring (.csv)';
      extensions = ['csv'];
    case 'edf_anno':
      dialogTitle = 'Load EDF+ Annotations (.edf)';
      extensions = ['edf'];
    case 'esrc':
      dialogTitle = 'Load REMlogic / EMBLA scoring (.esrc, .esedb)';
      extensions = ['esrc', 'esedb'];
    default:
      dialogTitle = 'Load scoring file';
      extensions = ['json', 'txt', 'csv', 'vis', 'annot', 'edf', 'esrc', 'esedb'];
  }

  final result = await FilePicker.pickFiles(
    dialogTitle: dialogTitle,
    type: FileType.custom,
    allowedExtensions: extensions,
  );
  final path = result?.files.single.path;
  if (path == null) {
    onStatus('Import cancelled');
    return null;
  }

  try {
    final detection = filetype == 'any'
        ? await detectScoringFormat(path)
        : ScoringFormatDetection(
            parserType: filetype,
            displayName: _displayNameForScoringType(filetype),
          );
    final parsed = await _parseScoringFile(
      path,
      detection.parserType,
      epochCount,
    );
    final loadResult = ScoringLoadResult(
      parsed.stages,
      parsed.stagesUncertain,
      stagesConfidence: parsed.stagesConfidence,
      stageProbabilities: parsed.stageProbabilities,
      sourceFormat: detection.displayName,
    );
    onStatus(
      'Detected ${detection.displayName}; loaded ${_basename(path)} — '
      '${loadResult.stages.where((s) => s.isScored).length}/'
      '${loadResult.stages.length} epochs scored',
    );
    return loadResult;
  } catch (e) {
    onStatus('Failed to load scoring: $e');
    return null;
  }
}

Future<ScoringLoadResult?> loadScoringFile(
  String path, {
  int epochCount = 0,
  void Function(String msg)? onStatus,
}) async {
  try {
    final detection = await detectScoringFormat(path);
    final parsed = await _parseScoringFile(
      path,
      detection.parserType,
      epochCount,
    );
    return ScoringLoadResult(
      parsed.stages,
      parsed.stagesUncertain,
      stagesConfidence: parsed.stagesConfidence,
      stageProbabilities: parsed.stageProbabilities,
      sourceFormat: detection.displayName,
    );
  } catch (e) {
    onStatus?.call('Failed to load scoring: $e');
    return null;
  }
}

class ScoringFormatDetection {
  const ScoringFormatDetection({
    required this.parserType,
    required this.displayName,
  });

  final String parserType;
  final String displayName;
}

Future<ScoringFormatDetection> detectScoringFormat(String path) async {
  final lower = path.toLowerCase();
  if (lower.endsWith('.edf')) {
    return const ScoringFormatDetection(
      parserType: 'edf_anno',
      displayName: 'EDF+ annotations',
    );
  }
  if (lower.endsWith('.esrc')) {
    return const ScoringFormatDetection(
      parserType: 'esrc',
      displayName: 'REMlogic / EMBLA ESRC XML',
    );
  }
  if (lower.endsWith('.esedb')) {
    return const ScoringFormatDetection(
      parserType: 'esrc',
      displayName: 'REMlogic / EMBLA ESEDB',
    );
  }
  if (lower.endsWith('.vis')) {
    return const ScoringFormatDetection(
      parserType: 'vis',
      displayName: 'Zurich VIS',
    );
  }
  if (lower.endsWith('.annot')) {
    return const ScoringFormatDetection(
      parserType: 'sleepyland',
      displayName: 'Sleepyland annotation',
    );
  }
  if (lower.endsWith('.json')) {
    return const ScoringFormatDetection(
      parserType: 'scoringhero',
      displayName: 'ScoringHero JSON',
    );
  }

  final preview = await _readTextPreview(path);
  final previewLower = preview.toLowerCase();
  if (lower.endsWith('.txt')) {
    if (previewLower.contains('signal id: schlafprofil') ||
        previewLower.contains('events list:')) {
      return const ScoringFormatDetection(
        parserType: 'yasa',
        displayName: 'Somnomedics text',
      );
    }
    if (RegExp(r'sleep stage\s+', caseSensitive: false).hasMatch(preview) &&
        preview.contains(',')) {
      return const ScoringFormatDetection(
        parserType: 'yasa',
        displayName: 'Polyman text',
      );
    }
    return const ScoringFormatDetection(
      parserType: 'yasa',
      displayName: 'YASA stage list',
    );
  }
  if (lower.endsWith('.csv')) {
    final firstLine = preview
        .split(RegExp(r'\r?\n'))
        .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '')
        .toLowerCase();
    final headers = firstLine.split(',').map((value) => value.trim()).toList();
    if (headers.isNotEmpty &&
        headers.first == 'epoch' &&
        headers.indexOf('stage') == 2) {
      return const ScoringFormatDetection(
        parserType: 'gssc',
        displayName: 'GSSC CSV',
      );
    }
    return const ScoringFormatDetection(
      parserType: 'sleeptrip',
      displayName: 'Sleeptrip CSV',
    );
  }

  throw FormatException(
    'Could not detect scoring format for ${_basename(path)}.',
  );
}

Future<String> _readTextPreview(String path) async {
  final file = File(path);
  final length = await file.length();
  final end = length.clamp(0, 65536).toInt();
  final bytes = await file
      .openRead(0, end)
      .fold<List<int>>(<int>[], (buffer, chunk) => buffer..addAll(chunk));
  return utf8.decode(bytes, allowMalformed: true);
}

String _displayNameForScoringType(String filetype) {
  return switch (filetype) {
    'scoringhero' => 'ScoringHero JSON',
    'edf_anno' => 'EDF+ annotations',
    'yasa' => 'YASA-compatible text',
    'sleeptrip' => 'Sleeptrip CSV',
    'vis' => 'Zurich VIS',
    'sleepyland' => 'Sleepyland annotation',
    'gssc' => 'GSSC CSV',
    _ => filetype,
  };
}

Future<ScoringLoadResult> _parseScoringFile(
  String path,
  String filetype,
  int epochCount,
) async {
  switch (filetype) {
    case 'scoringhero':
      return _loadJsonScoring(path, epochCount);
    case 'edf_anno':
      return _loadEdfAnnotationsScoring(path, epochCount);
    case 'yasa':
      final stages = await _loadYasaScoring(path, epochCount);
      return ScoringLoadResult(stages, List.filled(stages.length, false));
    case 'sleeptrip':
      final stages = await _loadSleetripScoring(path, epochCount);
      return ScoringLoadResult(stages, List.filled(stages.length, false));
    case 'vis':
      final stages = await _loadVisScoring(path, epochCount);
      return ScoringLoadResult(stages, List.filled(stages.length, false));
    case 'sleepyland':
      final stages = await _loadSleepylandScoring(path, epochCount);
      return ScoringLoadResult(stages, List.filled(stages.length, false));
    case 'gssc':
      final stages = await _loadGsscScoring(path, epochCount);
      return ScoringLoadResult(stages, List.filled(stages.length, false));
    case 'esrc':
      final stages = await _loadEmblaEsrcScoring(path, epochCount);
      return ScoringLoadResult(stages, List.filled(stages.length, false));
    default:
      throw UnsupportedError('Unknown scoring format: $filetype');
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// YASA format  (.txt — one stage per line: W, N1, N2, N3, R)
// ─────────────────────────────────────────────────────────────────────────────

Future<List<SleepStage>> _loadYasaScoring(String path, int epochCount) async {
  final content = await File(path).readAsString();
  final lines = content.split(RegExp(r'\r?\n'));
  final nonSpaceLines = lines.map((l) => l.trim()).toList();

  final firstDataLine = nonSpaceLines.firstWhere(
    (line) => line.isNotEmpty,
    orElse: () => '',
  );
  if (firstDataLine.startsWith('Signal ID:') ||
      nonSpaceLines.any((line) => line.startsWith('Events list:'))) {
    return _loadSomnomedicsTxtScoring(nonSpaceLines, epochCount);
  }

  if (nonSpaceLines.any(
    (line) => RegExp(r'Sleep stage\s+', caseSensitive: false).hasMatch(line),
  )) {
    return _loadPolymanTxtScoring(nonSpaceLines, epochCount);
  }

  // Preserve empty lines as unscored rather than skipping them, keeping alignment intact.
  var firstLine = 0;
  while (firstLine < nonSpaceLines.length && nonSpaceLines[firstLine].isEmpty) {
    firstLine++;
  }
  var lastLine = nonSpaceLines.length;
  while (lastLine > firstLine && nonSpaceLines[lastLine - 1].isEmpty) {
    lastLine--;
  }
  final stageLines = nonSpaceLines.sublist(firstLine, lastLine);
  if (epochCount <= 0) {
    epochCount = math.max(1, stageLines.length);
  }
  final stages = List.filled(epochCount, SleepStage.unknown);
  for (var i = 0; i < stageLines.length && i < epochCount; i++) {
    stages[i] = _stageFromYasaLabel(stageLines[i]);
  }
  return stages;
}

List<SleepStage> _loadSomnomedicsTxtScoring(
  List<String> lines,
  int epochCount,
) {
  if (epochCount <= 0) {
    epochCount = math.max(1, lines.length);
  }
  final stages = List.filled(epochCount, SleepStage.unknown);
  var epoch = 0;
  for (final line in lines) {
    if (epochCount > 0 && epoch >= epochCount) break;
    final separator = line.lastIndexOf(';');
    if (separator < 0) continue;
    final timeText = line.substring(0, separator).trim();
    if (!RegExp(r'^\d{1,2}:\d{2}:\d{2}').hasMatch(timeText)) continue;
    stages[epoch++] = _stageFromYasaLabel(line.substring(separator + 1));
  }
  return (epoch > 0 && epoch < epochCount) ? stages.sublist(0, epoch) : stages;
}

List<SleepStage> _loadPolymanTxtScoring(
  List<String> nonSpaceLines,
  int epochCount,
) {
  if (epochCount <= 0) {
    int maxEp = 0;
    for (final line in nonSpaceLines) {
      final parts = line.split(',');
      if (parts.length >= 4) {
        final onsetSec = double.tryParse(parts[2].trim());
        final durationSec = double.tryParse(parts[3].trim());
        if (onsetSec != null && durationSec != null) {
          final endEpoch = ((onsetSec + durationSec) / 30.0).ceil();
          if (endEpoch > maxEp) maxEp = endEpoch;
        }
      }
    }
    epochCount = math.max(1, maxEp > 0 ? maxEp : nonSpaceLines.length);
  }
  final stages = List.filled(epochCount, SleepStage.unknown);
  for (final line in nonSpaceLines) {
    if (line.isEmpty) continue;
    // Skip header line
    if (line.toLowerCase().startsWith('date,') ||
        line.toLowerCase().startsWith('time,') ||
        line.toLowerCase().startsWith('recording')) {
      continue;
    }

    final parts = line.split(',');
    if (parts.length < 5) continue;

    final onsetSec = double.tryParse(parts[2].trim());
    final durationSec = double.tryParse(parts[3].trim());
    final anno = parts[4].trim();

    if (onsetSec == null || durationSec == null) continue;

    if (anno.toLowerCase().startsWith('sleep stage ')) {
      final stageChar = anno.substring('sleep stage '.length).trim();
      final stage = _stageFromYasaLabel(stageChar);
      if (stage != SleepStage.unknown) {
        final startEpoch = (onsetSec / 30.0).floor();
        final endEpoch = ((onsetSec + durationSec) / 30.0).ceil();
        for (var e = startEpoch; e < endEpoch && e < epochCount; e++) {
          if (e >= 0 && e < epochCount) {
            stages[e] = stage;
          }
        }
      }
    }
  }
  return stages;
}

Future<ScoringLoadResult> _loadEdfAnnotationsScoring(
  String path,
  int epochCount,
) async {
  final bytes = await File(path).readAsBytes();
  if (bytes.length < 256) {
    throw const FormatException('EDF header is shorter than 256 bytes.');
  }

  int intAt(int offset, int width) =>
      int.parse(ascii.decode(bytes.sublist(offset, offset + width)).trim());
  double doubleAt(int offset, int width) => double.parse(
    ascii
        .decode(bytes.sublist(offset, offset + width))
        .trim()
        .replaceAll(',', '.'),
  );

  final headerBytes = intAt(184, 8);
  final dataRecordCount = intAt(236, 8);
  final signalCount = intAt(252, 4);

  var offset = 256;
  final labels = [
    for (var index = 0; index < signalCount; index++)
      ascii
          .decode(bytes.sublist(offset + index * 16, offset + (index + 1) * 16))
          .trim()
          .toLowerCase(),
  ];
  offset += signalCount * 16;
  offset += signalCount * 80; // transducer
  offset += signalCount * 8; // physical dimension
  offset += signalCount * 8; // physical min
  offset += signalCount * 8; // physical max
  offset += signalCount * 8; // digital min
  offset += signalCount * 8; // digital max
  offset += signalCount * 80; // prefiltering

  final samplesPerRecord = [
    for (var index = 0; index < signalCount; index++)
      int.parse(
        ascii
            .decode(bytes.sublist(offset + index * 8, offset + (index + 1) * 8))
            .trim(),
      ),
  ];

  final annoChannels = <int>[];
  for (var i = 0; i < signalCount; i++) {
    if (labels[i].contains('annotation') ||
        labels[i].contains('status') ||
        labels[i].contains('marker')) {
      annoChannels.add(i);
    }
  }
  if (annoChannels.isEmpty) {
    throw const FormatException('No annotation channel found in EDF file.');
  }

  final annotationBytes = BytesBuilder();
  final data = ByteData.sublistView(bytes);
  var cursor = headerBytes;

  for (var record = 0; record < dataRecordCount; record++) {
    for (var channel = 0; channel < signalCount; channel++) {
      final samplesInRecord = samplesPerRecord[channel];
      if (cursor + samplesInRecord * 2 > bytes.length) {
        break;
      }
      if (annoChannels.contains(channel)) {
        for (var sample = 0; sample < samplesInRecord; sample++) {
          final intVal = data.getInt16(cursor, Endian.little);
          annotationBytes.addByte(intVal & 0xFF);
          annotationBytes.addByte((intVal >> 8) & 0xFF);
          cursor += 2;
        }
      } else {
        cursor += samplesInRecord * 2;
      }
    }
  }

  final decoded = ascii.decode(annotationBytes.toBytes(), allowInvalid: true);
  final tals = decoded.split('\x00');

  if (epochCount <= 0) {
    int maxEp = 0;
    for (final tal in tals) {
      if (tal.trim().isEmpty || !tal.contains('\x14')) continue;
      final parts = tal.split('\x14');
      if (parts.isEmpty) continue;
      final timePart = parts[0];
      double onset = 0.0;
      double duration = 0.0;
      if (timePart.contains('\x15')) {
        final subParts = timePart.split('\x15');
        onset = double.tryParse(subParts[0]) ?? 0.0;
        duration = double.tryParse(subParts[1]) ?? 0.0;
      } else {
        onset = double.tryParse(timePart) ?? 0.0;
      }
      final dur = duration > 0 ? duration : 30.0;
      final endEpoch = ((onset + dur) / 30.0).ceil();
      if (endEpoch > maxEp) maxEp = endEpoch;
    }
    epochCount = math.max(1, maxEp);
  }

  final stages = List.filled(epochCount, SleepStage.unknown);
  final stagesUncertain = List.filled(epochCount, false);
  final stagesConfidence = List<double?>.filled(epochCount, null);

  for (final tal in tals) {
    if (tal.trim().isEmpty) continue;
    if (!tal.contains('\x14')) continue;

    final parts = tal.split('\x14');
    if (parts.isEmpty) continue;

    final timePart = parts[0];
    double onset = 0.0;
    double duration = 0.0;
    if (timePart.contains('\x15')) {
      final subParts = timePart.split('\x15');
      onset = double.tryParse(subParts[0]) ?? 0.0;
      duration = double.tryParse(subParts[1]) ?? 0.0;
    } else {
      onset = double.tryParse(timePart) ?? 0.0;
    }

    for (var i = 1; i < parts.length; i++) {
      final anno = parts[i].trim();
      if (anno.isEmpty) continue;

      if (anno.toLowerCase().startsWith('sleep stage ')) {
        final stageChar = anno.substring('sleep stage '.length).trim();
        final stage = _stageFromYasaLabel(stageChar);
        if (stage != SleepStage.unknown) {
          final dur = duration > 0 ? duration : 30.0;
          final startEpoch = (onset / 30.0).floor();
          final endEpoch = ((onset + dur) / 30.0).ceil();
          for (var e = startEpoch; e < endEpoch && e < epochCount; e++) {
            if (e >= 0 && e < epochCount) {
              stages[e] = stage;
            }
          }
        }
      }
    }
  }

  return ScoringLoadResult(
    stages,
    stagesUncertain,
    stagesConfidence: stagesConfidence,
  );
}

SleepStage _stageFromYasaLabel(String label) {
  switch (label.trim().toUpperCase()) {
    case 'W':
    case 'WAKE':
    case '0':
      return SleepStage.wake;
    case 'N1':
    case 'S1':
    case '1':
      return SleepStage.n1;
    case 'N2':
    case 'S2':
    case '2':
      return SleepStage.n2;
    case 'N3':
    case 'S3':
    case '3':
      return SleepStage.n3;
    case 'N4':
    case 'S4':
    case '4':
      return SleepStage.n3; // treat N4 as N3
    case 'R':
    case 'REM':
    case '5':
      return SleepStage.rem;
    default:
      return SleepStage.unknown;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sleeptrip CSV format (.csv — has "stage" column)
// ─────────────────────────────────────────────────────────────────────────────

Future<List<SleepStage>> _loadSleetripScoring(
  String path,
  int epochCount,
) async {
  final lines = (await File(path).readAsString()).split('\n');
  if (lines.isEmpty) return epochCount > 0 ? List.filled(epochCount, SleepStage.unknown) : <SleepStage>[];

  // Find header row
  final header = lines[0]
      .split(',')
      .map((h) => h.trim().toLowerCase())
      .toList();
  final stageCol = header.indexOf('stage');
  if (stageCol < 0) throw FormatException('No "stage" column in Sleeptrip CSV');

  if (epochCount <= 0) {
    final validLines = lines.skip(1).where((l) => l.trim().isNotEmpty && l.split(',').length > stageCol).length;
    epochCount = math.max(1, validLines);
  }

  final stages = List.filled(epochCount, SleepStage.unknown);
  var row = 0;
  for (var i = 1; i < lines.length && row < epochCount; i++) {
    final parts = lines[i].split(',');
    if (parts.length <= stageCol) continue;
    stages[row] = _stageFromYasaLabel(parts[stageCol].trim());
    row++;
  }
  return stages;
}

// ─────────────────────────────────────────────────────────────────────────────
// Zurich VIS format (.vis)
// ─────────────────────────────────────────────────────────────────────────────

/// Zurich .vis format: lines beginning with digits are stage codes.
/// Stage mapping (from load_vis.py):
///   0 → Wake, 1 → N1, 2 → N2, 3 → N3, 4 → N3, 5 → REM, 8 → unknown
Future<List<SleepStage>> _loadVisScoring(String path, int epochCount) async {
  final lines = (await File(path).readAsString()).split('\n');
  if (epochCount <= 0) {
    int valid = 0;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty && _isDigitStr(trimmed[0])) valid++;
    }
    epochCount = math.max(1, valid);
  }
  final stages = List.filled(epochCount, SleepStage.unknown);
  var row = 0;
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || !_isDigitStr(trimmed[0])) continue;
    // Stage code is typically a single digit, possibly with suffix
    final code = int.tryParse(trimmed.split(RegExp(r'\s+'))[0]);
    if (code == null || row >= epochCount) break;
    stages[row] = _stageFromVisCode(code);
    row++;
  }
  return stages;
}

Future<List<SleepStage>> _loadSleepylandScoring(
  String path,
  int epochCount,
) async {
  final lines = (await File(path).readAsString()).split('\n');
  if (epochCount <= 0) {
    final valid = lines.skip(1).where((l) => l.trim().isNotEmpty).length;
    epochCount = math.max(1, valid);
  }
  final stages = List.filled(epochCount, SleepStage.unknown);
  var row = 0;
  for (final line in lines.skip(1)) {
    if (row >= epochCount) break;
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final parts = trimmed.split('\t');
    if (parts.length < 2) continue;
    stages[row] = _stageFromYasaLabel(parts[1].trim());
    row++;
  }
  return stages;
}

Future<List<SleepStage>> _loadGsscScoring(String path, int epochCount) async {
  final lines = (await File(path).readAsString()).split('\n');
  if (epochCount <= 0) {
    final valid = lines.skip(1).where((l) => l.trim().isNotEmpty && !l.startsWith('Epoch')).length;
    epochCount = math.max(1, valid);
  }
  final stages = List.filled(epochCount, SleepStage.unknown);
  var row = 0;
  SleepStage? lastScored;
  for (final line in lines.skip(1)) {
    if (row >= epochCount) break;
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final parts = trimmed.split(',');
    if (parts.length < 3 || parts[0] == 'Epoch') continue;
    final code = int.tryParse(parts[2].trim());
    if (code == null) continue;
    final stage = switch (code) {
      0 => SleepStage.wake,
      1 => SleepStage.n1,
      2 => SleepStage.n2,
      3 => SleepStage.n3,
      4 => SleepStage.rem,
      _ => SleepStage.unknown,
    };
    stages[row] = stage;
    if (stage != SleepStage.unknown) lastScored = stage;
    row++;
  }
  if (lastScored != null) {
    for (var i = row; i < epochCount; i++) {
      stages[i] = lastScored;
    }
  }
  return stages;
}

Future<List<SleepStage>> _loadEmblaEsrcScoring(
  String path,
  int epochCount,
) async {
  if (path.toLowerCase().endsWith('.esedb')) {
    final nativeRecords = EegBackend.loadEsedbNative(path);
    if (nativeRecords != null && nativeRecords.isNotEmpty) {
      if (epochCount <= 0) {
        final maxStart = nativeRecords.map((e) => e.startSec).fold(0, math.max);
        epochCount = math.max(1, (maxStart / 30).ceil() + 1);
      }
      final stages = List.filled(epochCount, SleepStage.unknown);
      for (var i = 0; i < nativeRecords.length; i++) {
        final cur = nativeRecords[i];
        final stage = _stageFromYasaLabel(cur.stage);
        final epStart = cur.startSec ~/ 30;
        final epEnd = i + 1 < nativeRecords.length
            ? (nativeRecords[i + 1].startSec ~/ 30)
            : epochCount;
        for (var ep = epStart; ep < epEnd && ep < epochCount; ep++) {
          if (ep >= 0) stages[ep] = stage;
        }
      }
      return stages;
    }
  }

  final bytes = await File(path).readAsBytes();
  String text;
  try {
    text = utf8.decode(bytes);
  } catch (_) {
    text = String.fromCharCodes(bytes);
  }

  final parsedStages = <({int startSec, SleepStage stage})>[];

  final stageMatches = RegExp(
    r'<Stage[^>]*Type="([^"]+)"[^>]*Start="([^"]+)"',
    caseSensitive: false,
  ).allMatches(text);

  for (final m in stageMatches) {
    final typeStr = m.group(1) ?? '';
    final startStr = m.group(2) ?? '0';
    final startSec = (double.tryParse(startStr) ?? 0.0).toInt();
    final stage = _stageFromYasaLabel(typeStr);
    parsedStages.add((startSec: startSec, stage: stage));
  }

  if (parsedStages.isEmpty) {
    final sleepTagMatches = RegExp(
      r'SLEEP-(S0|S1|S2|S3|S4|REM|WAK|WAKE)',
      caseSensitive: false,
    ).allMatches(text);
    var curSec = 0;
    for (final m in sleepTagMatches) {
      final tag = m.group(0) ?? '';
      final stage = _stageFromYasaLabel(tag.replaceAll('SLEEP-', ''));
      parsedStages.add((startSec: curSec, stage: stage));
      curSec += 30;
    }
  }

  if (epochCount <= 0) {
    if (parsedStages.isNotEmpty) {
      final maxStart = parsedStages.map((e) => e.startSec).fold(0, math.max);
      epochCount = math.max(1, (maxStart / 30).ceil() + 1);
    } else {
      epochCount = 1;
    }
  }

  final stages = List.filled(epochCount, SleepStage.unknown);
  for (var i = 0; i < parsedStages.length; i++) {
    final cur = parsedStages[i];
    final epStart = cur.startSec ~/ 30;
    final epEnd = i + 1 < parsedStages.length
        ? (parsedStages[i + 1].startSec ~/ 30)
        : epochCount;

    for (var ep = epStart; ep < epEnd && ep < epochCount; ep++) {
      if (ep >= 0) stages[ep] = cur.stage;
    }
  }

  return stages;
}

bool _isDigitStr(String c) => c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;

SleepStage _stageFromVisCode(int code) {
  switch (code) {
    case 0:
      return SleepStage.wake;
    case 1:
      return SleepStage.n1;
    case 2:
      return SleepStage.n2;
    case 3:
    case 4:
      return SleepStage.n3;
    case 5:
      return SleepStage.rem;
    default:
      return SleepStage.unknown;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Export dialog — choose format and write file
// ─────────────────────────────────────────────────────────────────────────────

Future<void> exportScoringDialog(
  List<SleepStage> stages,
  int epochSeconds,
  String? activePath, {
  List<ScoredEvent> events = const [],
  List<bool>? stagesUncertain,
  List<double?>? stagesConfidence,
  List<Map<SleepStage, double>>? stageProbabilities,
  required void Function(String) onStatus,
}) async {
  final ext = ['json', 'txt', 'csv', 'vis'];

  String? defaultName;
  if (activePath != null) {
    final base = activePath.split(Platform.pathSeparator).last;
    final dot = base.lastIndexOf('.');
    final name = dot >= 0 ? base.substring(0, dot) : base;
    defaultName = '${name}_scoring.json';
  } else {
    defaultName = 'scoring.json';
  }

  String? savePath = await FilePicker.saveFile(
    dialogTitle: 'Save scoring as',
    fileName: defaultName,
    type: FileType.any,
  );
  if (savePath == null) {
    onStatus('Save cancelled');
    return;
  }

  if (!savePath.contains('.')) {
    savePath = '${savePath}_scoring.json';
  } else if (savePath.toLowerCase().endsWith('.json') &&
      !savePath.toLowerCase().endsWith('_scoring.json')) {
    savePath = '${savePath.substring(0, savePath.length - 5)}_scoring.json';
  }

  // Determine format from extension
  String filetype = 'scoringhero';
  for (var i = 0; i < ext.length; i++) {
    if (savePath.toLowerCase().endsWith('.${ext[i]}')) {
      filetype = ['scoringhero', 'yasa', 'sleeptrip', 'vis'][i];
      break;
    }
  }

  try {
    await _writeScoringFile(
      savePath,
      stages,
      epochSeconds,
      filetype,
      activePath,
      events,
      stagesUncertain: stagesUncertain,
      stagesConfidence: stagesConfidence,
      stageProbabilities: stageProbabilities,
    );
    onStatus('Saved scoring to ${_basename(savePath)}');
  } catch (e) {
    onStatus('Failed to save: $e');
  }
}

Future<void> _writeScoringFile(
  String path,
  List<SleepStage> stages,
  int epochSeconds,
  String filetype,
  String? activePath,
  List<ScoredEvent> events, {
  List<bool>? stagesUncertain,
  List<double?>? stagesConfidence,
  List<Map<SleepStage, double>>? stageProbabilities,
}) async {
  switch (filetype) {
    case 'scoringhero':
      await _writeJsonScoring(
        path,
        stages,
        epochSeconds,
        activePath ?? path,
        events: events,
        stagesUncertain: stagesUncertain,
        stagesConfidence: stagesConfidence,
        stageProbabilities: stageProbabilities,
      );
    case 'yasa':
      await _writeYasa(path, stages);
    case 'sleeptrip':
      await _writeSleeptrip(path, stages, epochSeconds);
    case 'vis':
      await _writeVis(path, stages);
  }
}

Future<void> _writeYasa(String path, List<SleepStage> stages) async {
  final lines = stages.map((s) {
    switch (s) {
      case SleepStage.wake:
        return 'W';
      case SleepStage.n1:
        return 'N1';
      case SleepStage.n2:
        return 'N2';
      case SleepStage.n3:
        return 'N3';
      case SleepStage.rem:
        return 'R';
      default:
        return 'W'; // export unscored as Wake to avoid blank lines
    }
  });
  await File(path).writeAsString(lines.join('\n'));
}

Future<void> _writeSleeptrip(
  String path,
  List<SleepStage> stages,
  int epochSeconds,
) async {
  final buf = StringBuffer('epoch,start,end,stage\n');
  for (var i = 0; i < stages.length; i++) {
    buf.write('${i + 1},${i * epochSeconds},${(i + 1) * epochSeconds},');
    buf.writeln(stages[i].label);
  }
  await File(path).writeAsString(buf.toString());
}

Future<void> _writeVis(String path, List<SleepStage> stages) async {
  final codes = stages.map((s) {
    switch (s) {
      case SleepStage.wake:
        return 0;
      case SleepStage.n1:
        return 1;
      case SleepStage.n2:
        return 2;
      case SleepStage.n3:
        return 3;
      case SleepStage.rem:
        return 5;
      default:
        return 8;
    }
  });
  await File(path).writeAsString(codes.join('\n'));
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

String _basename(String path) {
  final sep = Platform.pathSeparator;
  return path.split(sep).last;
}

class ScoringLoadResult {
  final List<SleepStage> stages;
  final List<bool> stagesUncertain;
  final List<double?> stagesConfidence;
  final List<Map<SleepStage, double>> stageProbabilities;
  final String sourceFormat;
  ScoringLoadResult(
    this.stages,
    this.stagesUncertain, {
    this.stagesConfidence = const [],
    this.stageProbabilities = const [],
    this.sourceFormat = '',
  });
}

Future<ScoringLoadResult> loadScoringFileDirectly(
  String path,
  String filetype,
  int epochCount,
) {
  return _parseScoringFile(path, filetype, epochCount);
}
