import 'dart:io';

class AutoscoreInvocation {
  const AutoscoreInvocation({
    required this.executable,
    this.argumentPrefix = const [],
  });

  final String executable;
  final List<String> argumentPrefix;

  List<String> argumentsFor(List<String> arguments) => [
    ...argumentPrefix,
    ...arguments,
  ];
}

AutoscoreInvocation resolveAutoscoreInvocation({
  String? resolvedExecutable,
  String? currentDirectory,
  bool? isWindows,
  bool? isMacOS,
  bool Function(String path)? fileExists,
}) {
  final executablePath = resolvedExecutable ?? Platform.resolvedExecutable;
  final currentDir = currentDirectory ?? Directory.current.path;
  final windows = isWindows ?? Platform.isWindows;
  final macOS = isMacOS ?? Platform.isMacOS;
  final exists = fileExists ?? (String path) => File(path).existsSync();
  final separator = windows ? r'\' : '/';
  final executableDir = File(executablePath).parent.path;
  String join(List<String> parts) => parts.join(separator);

  final packagedCandidates = <String>[
    if (windows)
      join([executableDir, 'autoscore-backend', 'autoscore-backend.exe']),
    if (!windows)
      join([executableDir, 'autoscore-backend', 'autoscore-backend']),
    if (macOS)
      join([
        executableDir,
        '..',
        'Resources',
        'autoscore-backend',
        'autoscore-backend',
      ]),
    if (!windows && !macOS)
      join([
        executableDir,
        '..',
        'lib',
        'ccs-sleep-studio',
        'autoscore-backend',
        'autoscore-backend',
      ]),
    if (!windows)
      join([currentDir, 'dist', 'autoscore-backend', 'autoscore-backend']),
    if (windows)
      join([currentDir, 'dist', 'autoscore-backend', 'autoscore-backend.exe']),
    if (windows) join([executableDir, 'autoscore-backend.exe']),
    if (!windows) join([executableDir, 'autoscore-backend']),
    if (macOS) join([executableDir, '..', 'Resources', 'autoscore-backend']),
    if (!windows && !macOS)
      join([executableDir, '..', 'lib', 'ccs-sleep-studio', 'autoscore-backend']),
    if (!windows) join([currentDir, 'dist', 'autoscore-backend']),
    if (windows) join([currentDir, 'dist', 'autoscore-backend.exe']),
  ];
  for (final candidate in packagedCandidates) {
    if (exists(candidate)) {
      return AutoscoreInvocation(executable: candidate);
    }
  }

  final roots = <String>{
    currentDir,
    File(currentDir).parent.path,
    File(executableDir).parent.path,
  };
  final scriptCandidates = <String>[
    for (final root in roots) ...[
      join([root, 'backend_entry.py']),
      join([root, 'backend', 'backend_entry.py']),
      join([root, '..', 'backend_entry.py']),
    ],
  ];
  String? script;
  for (final candidate in scriptCandidates) {
    if (exists(candidate)) {
      script = candidate;
      break;
    }
  }

  if (script != null) {
    final pythonCandidates = windows
        ? <String>[
            join([currentDir, 'backend', 'sleep_env', 'Scripts', 'python.exe']),
            join([
              currentDir,
              '..',
              'backend',
              'sleep_env',
              'Scripts',
              'python.exe',
            ]),
            'python.exe',
          ]
        : <String>[
            join([currentDir, 'backend', 'sleep_env', 'bin', 'python']),
            join([currentDir, '..', 'backend', 'sleep_env', 'bin', 'python']),
            if (macOS) '/opt/homebrew/bin/python3',
            if (macOS) '/usr/local/bin/python3',
            'python3',
          ];
    for (final candidate in pythonCandidates) {
      if (!candidate.contains(separator) || exists(candidate)) {
        return AutoscoreInvocation(
          executable: candidate,
          argumentPrefix: [script],
        );
      }
    }
  }

  throw StateError(
    'AutoscoreNidra backend is not installed. Install the Full build or '
    'place autoscore-backend beside the application executable.',
  );
}

String detectAnalyseNidraExecutable() {
  final executableDir = File(Platform.resolvedExecutable).parent.path;
  final currentDir = Directory.current.path;
  final candidates = [
    if (Platform.isWindows) '$executableDir\\analyse-nidra.exe',
    if (Platform.isWindows)
      '$executableDir\\data\\flutter_assets\\analyse-nidra.exe',
    if (!Platform.isWindows) '$executableDir/analyse-nidra',
    if (Platform.isMacOS) '$executableDir/../Resources/analyse-nidra',
    if (Platform.isLinux) '$executableDir/lib/analyse-nidra',
    '$currentDir/../analyseNidra/target/release/analyse-nidra',
    '$currentDir/analyseNidra/target/release/analyse-nidra',
    if (Platform.isWindows)
      '$currentDir/analyseNidra/target/release/analyse-nidra.exe',
    if (Platform.isWindows)
      '$currentDir/../analyseNidra/target/release/analyse-nidra.exe',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return Platform.isWindows ? 'analyse-nidra.exe' : 'analyse-nidra';
}

bool isAnalyseNidraAvailable() {
  final exe = detectAnalyseNidraExecutable();
  return File(exe).existsSync();
}


/// Maps UI / legacy algorithm identifiers onto the keys understood by the
/// native `analyse-nidra --stage` engine.
String canonicalAutoscoreAlgorithm(String algorithm) {
  final key = algorithm.trim().toLowerCase().replaceAll('-', '_');
  switch (key) {
    case '':
    case 'tinysleepnet_rust':
    case 'tinysleepnet_physioex':
      return 'tinysleepnet';
    case 'sleeptansformer':
      return 'sleeptransformer';
    case 'pops':
    case 'luna_pops':
      return 'luna';
    default:
      return key;
  }
}

/// Human readable name for an autoscoring algorithm key.
String autoscoreAlgorithmLabel(String algorithm) {
  switch (canonicalAutoscoreAlgorithm(algorithm)) {
    case 'tinysleepnet':
      return 'TinySleepNet';
    case 'yasa':
      return 'YASA';
    case 'usleep':
      return 'U-Sleep';
    case 'luna':
      return 'Luna POPS';
    case 'gssc':
      return 'GSSC';
    case 'seqsleepnet':
      return 'SeqSleepNet';
    case 'sleeptransformer':
      return 'SleepTransformer';
    case 'dreamento':
      return 'Dreamento';
    case 'sleepeegpy':
      return 'SleepEEGpy';
    default:
      return algorithm;
  }
}

/// File extensions the native engine can read directly.
bool analyseNidraReadsNatively(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.edf') || lower.endsWith('.rec');
}

/// Builds the `analyse-nidra --stage` argument list.
List<String> buildNativeStageArgs({
  required String inputPath,
  required String algorithm,
  String? sequenceCorrection,
  Object? sleepgptAlpha,
  Object? sleepgptNgram,
  List<String> eeg = const [],
  List<String> ref = const [],
  List<String> eog = const [],
  List<String> emg = const [],
  String? outJson,
  String? outDir,
}) {
  List<String> clean(List<String> values) =>
      values.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  final args = <String>[
    '--stage',
    inputPath,
    '--algorithm',
    canonicalAutoscoreAlgorithm(algorithm),
  ];
  final correction = sequenceCorrection?.trim() ?? '';
  if (correction.isNotEmpty && correction != 'none') {
    args.addAll(['--sequence-correction', correction]);
    if (correction == 'sleepgpt') {
      if (sleepgptAlpha != null) {
        args.addAll(['--sleepgpt-alpha', sleepgptAlpha.toString()]);
      }
      if (sleepgptNgram != null) {
        args.addAll(['--sleepgpt-ngram', sleepgptNgram.toString()]);
      }
    }
  }
  final eegList = clean(eeg);
  final refList = clean(ref);
  final eogList = clean(eog);
  final emgList = clean(emg);
  if (eegList.isNotEmpty) args.addAll(['--eeg', eegList.join(',')]);
  if (refList.isNotEmpty) args.addAll(['--ref', refList.join(',')]);
  if (eogList.isNotEmpty) args.addAll(['--eog', eogList.join(',')]);
  if (emgList.isNotEmpty) args.addAll(['--emg', emgList.join(',')]);
  if (outJson != null && outJson.isNotEmpty) args.addAll(['--out', outJson]);
  if (outDir != null && outDir.isNotEmpty) args.addAll(['--out-dir', outDir]);
  return args;
}

/// Default output path for a native autoscoring run on [inputPath]; this
/// mirrors the naming used by `analyse-nidra --stage` so that non-EDF inputs
/// (converted to a temporary EDF first) land beside the original recording.
String nativeStageOutputPath(
  String inputPath,
  String algorithm, {
  String? sequenceCorrection,
  String? outDir,
}) {
  final sep = Platform.pathSeparator;
  final normalized = inputPath.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  final dir = outDir ??
      (slash >= 0 ? inputPath.substring(0, slash) : Directory.current.path);
  var name = slash >= 0 ? normalized.substring(slash + 1) : normalized;
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  var postfix = canonicalAutoscoreAlgorithm(algorithm);
  if (sequenceCorrection == 'sleepgpt') postfix = '${postfix}_sleepgpt';
  return '$dir$sep${name}_${postfix}_scoring.json';
}

/// Autoscoring algorithms offered in every AutoscoreNidra dialog, all run by
/// the native `analyse-nidra` engine: (key, label).
const List<(String, String)> autoscoreAlgorithmOptions = [
  ('tinysleepnet', 'TinySleepNet'),
  ('yasa', 'YASA LightGBM'),
  ('usleep', 'U-Sleep'),
  ('luna', 'Luna POPS'),
  ('gssc', 'Greifswald Sleep Stage Classifier (GSSC)'),
  ('seqsleepnet', 'SeqSleepNet (PhysioEx)'),
  ('sleeptransformer', 'SleepTransformer (PhysioEx)'),
  ('dreamento', 'Dreamento (YASA-based)'),
  ('sleepeegpy', 'SleepEEGpy (YASA-based)'),
];
