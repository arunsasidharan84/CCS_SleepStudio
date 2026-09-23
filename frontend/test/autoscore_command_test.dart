import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/autoscore_command.dart';

void main() {
  test('uses packaged macOS AutoscoreNidra backend', () {
    final invocation = resolveAutoscoreInvocation(
      resolvedExecutable:
          '/Applications/CCS Sleep Studio.app/Contents/MacOS/CCS Sleep Studio',
      currentDirectory: '/tmp',
      isWindows: false,
      isMacOS: true,
      fileExists: (path) =>
          path ==
          '/Applications/CCS Sleep Studio.app/Contents/MacOS/../Resources/autoscore-backend/autoscore-backend',
    );

    expect(
      invocation.executable,
      contains('Resources/autoscore-backend/autoscore-backend'),
    );
    expect(invocation.argumentPrefix, isEmpty);
  });

  test('pairs development Python with backend_entry.py', () {
    final invocation = resolveAutoscoreInvocation(
      resolvedExecutable: '/tmp/CCSSleepStudio',
      currentDirectory: '/workspace/CCSSleepStudio',
      isWindows: false,
      isMacOS: true,
      fileExists: (path) =>
          path == '/workspace/CCSSleepStudio/backend_entry.py' ||
          path == '/opt/homebrew/bin/python3',
    );

    expect(invocation.executable, '/opt/homebrew/bin/python3');
    expect(invocation.argumentPrefix, [
      '/workspace/CCSSleepStudio/backend_entry.py',
    ]);
  });

  test('finds the backend from an installed Linux launcher path', () {
    final invocation = resolveAutoscoreInvocation(
      resolvedExecutable: '/usr/bin/ccs-sleep-studio',
      currentDirectory: '/home/researcher',
      isWindows: false,
      isMacOS: false,
      fileExists: (path) =>
          path ==
          '/usr/bin/../lib/ccs-sleep-studio/autoscore-backend/autoscore-backend',
    );

    expect(
      invocation.executable,
      '/usr/bin/../lib/ccs-sleep-studio/autoscore-backend/autoscore-backend',
    );
  });

  test('prefers a validated development standalone backend', () {
    final invocation = resolveAutoscoreInvocation(
      resolvedExecutable: '/tmp/CCSSleepStudio',
      currentDirectory: '/workspace/CCSSleepStudio',
      isWindows: false,
      isMacOS: true,
      fileExists: (path) =>
          path == '/workspace/CCSSleepStudio/dist/autoscore-backend' ||
          path == '/workspace/CCSSleepStudio/backend_entry.py' ||
          path == '/opt/homebrew/bin/python3',
    );

    expect(
      invocation.executable,
      '/workspace/CCSSleepStudio/dist/autoscore-backend',
    );
    expect(invocation.argumentPrefix, isEmpty);
  });

  test('never falls back to Python without a backend script', () {
    expect(
      () => resolveAutoscoreInvocation(
        resolvedExecutable: '/tmp/CCSSleepStudio',
        currentDirectory: '/tmp',
        isWindows: false,
        isMacOS: true,
        fileExists: (_) => false,
      ),
      throwsStateError,
    );
  });

  test('maps legacy algorithm ids onto native engine keys', () {
    expect(canonicalAutoscoreAlgorithm('tinysleepnet_rust'), 'tinysleepnet');
    expect(canonicalAutoscoreAlgorithm('sleeptansformer'), 'sleeptransformer');
    expect(canonicalAutoscoreAlgorithm('LUNA'), 'luna');
    expect(canonicalAutoscoreAlgorithm('sleepeegpy'), 'sleepeegpy');
  });

  test('builds native stage arguments with all channel groups', () {
    final args = buildNativeStageArgs(
      inputPath: '/data/s1.edf',
      algorithm: 'yasa',
      sequenceCorrection: 'sleepgpt',
      sleepgptAlpha: 0.1,
      sleepgptNgram: 30,
      eeg: const ['C3', 'C4'],
      ref: const ['A2', 'A1'],
      eog: const ['LOC'],
      emg: const ['Chin'],
    );
    expect(args.take(4), ['--stage', '/data/s1.edf', '--algorithm', 'yasa']);
    expect(args, containsAllInOrder(['--eeg', 'C3,C4', '--ref', 'A2,A1']));
    expect(args, containsAllInOrder(['--eog', 'LOC', '--emg', 'Chin']));
    expect(args, containsAllInOrder(['--sequence-correction', 'sleepgpt']));
  });

  test('every offered algorithm is a canonical native key', () {
    for (final option in autoscoreAlgorithmOptions) {
      expect(canonicalAutoscoreAlgorithm(option.$1), option.$1);
    }
  });
}

