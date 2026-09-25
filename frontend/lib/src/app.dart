// lib/src/app.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'analyse_options.dart';
import 'autoscore_command.dart';
import 'batch_helpers.dart';
import 'config_dialog.dart';
import 'feature_config_dialog.dart';
import 'detection_dialogs.dart';
import 'edf_utilities_dialog.dart';
import 'eeg_backend.dart';
import 'models.dart';
import 'multi_scoring_compare.dart';
import 'marker_io.dart';
import 'markers_dialog.dart';
import 'preprocess_dialog.dart';
import 'psg_analysis.dart';
import 'publication_sleep_report.dart';
import 'regional_csv.dart';
import 'scoring_io.dart';
import 'update_checker.dart';
import 'signal_processing.dart' as sp;
import 'synced_video_panel.dart';
import 'timeline_painter.dart';
import 'package:video_player/video_player.dart';

const double _plotLeftPadding = 90.0;
const bool buildLite = bool.fromEnvironment('LITE_BUILD', defaultValue: false);

class CCSSleepStudioApp extends StatelessWidget {
  const CCSSleepStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'CCS Sleep Studio',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B6EA5),
          brightness: Brightness.light,
        ),
        useMaterial3: false,
        fontFamily: Platform.isMacOS ? '.AppleSystemUIFont' : null,
      ),
      home: const CCSSleepStudioHome(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class CCSSleepStudioHome extends StatefulWidget {
  const CCSSleepStudioHome({super.key});

  @override
  State<CCSSleepStudioHome> createState() => _CCSSleepStudioHomeState();
}

class _CCSSleepStudioHomeState extends State<CCSSleepStudioHome>
    with SingleTickerProviderStateMixin {
  final EegBackend _backend = EegBackend();
  final FocusNode _viewerFocusNode = FocusNode();
  AppConfig _config = AppConfig(tfEnabled: false);

  EegViewport? _viewport;
  LoadedEeg? _loadedEeg;
  List<SleepStage>? _comparisonStages;
  NlgOverlayData? _nlgOverlay;
  AnalyseNidraOptions _analyseOptions = AnalyseNidraOptions();
  AnalyseNidraOptions _batchAnalyseOptions = AnalyseNidraOptions();
  String? _activePath;
  String _status = 'Ready — load an EDF file to begin scoring';
  String _appVersion = '';
  int _navigationSerial = 0;
  Timer? _tfRefreshTimer;
  Timer? _lightsMarkerSaveTimer;
  late final TabController _tabController;
  bool _textInputFocused = false;

  // SWA slider value (0–100). 100 = no smoothing, 0 = maximum smoothing.
  int _swaSlider = 100;

  // Batch Staging State
  final List<String> _batchStagingFiles = [];
  String _batchStagingAlgorithm = kDefaultAutoscoreAlgorithm;
  String _batchStagingCorrection = kDefaultSequenceCorrection;
  final TextEditingController _batchStagingEegController =
      TextEditingController();
  final TextEditingController _batchStagingRefController =
      TextEditingController();
  final TextEditingController _batchStagingEogController =
      TextEditingController();
  final TextEditingController _batchStagingEmgController =
      TextEditingController();
  final TextEditingController _batchStagingOutDirController =
      TextEditingController();
  bool _batchStagingRecursive = true;
  bool _batchStagingUseWildcard = false;
  final TextEditingController _batchStagingWildcardController =
      TextEditingController(text: '*.edf');

  // Batch AnalyseNidra State
  final List<Map<String, String>> _batchAnalysePairs = [];
  final List<Map<String, String>> _batchComparisonPairs = [];
  final TextEditingController _batchAnalyseEegController =
      TextEditingController(text: '');
  final TextEditingController _batchAnalyseRefController =
      TextEditingController(text: '');
  final TextEditingController _batchScoringPostfixController =
      TextEditingController(text: '_scoring');
  final TextEditingController _batchAnalyseOutDirController =
      TextEditingController();
  List<String> _lastAnalyseRegionalFiles = const [];
  List<String> _batchAnalyseAvailableChannels = const [];
  bool _batchAnalysePerChannel = false;
  bool _batchAnalyseRecursive = true;
  bool _batchAnalyseUseWildcard = false;
  bool _batchAnalyseAutoLoadScorings = true;
  bool _batchAnalyseSkipExisting = true;
  bool _batchAnalyseAutoCollate = true;
  final TextEditingController _batchAnalyseWildcardController =
      TextEditingController(text: '*.edf');

  // Batch PSG (OSA / PLM / CAP) State
  final List<Map<String, String>> _batchPsgPairs = [];
  bool _batchPsgRecursive = true;
  bool _batchPsgUseWildcard = false;
  bool _batchPsgAutoLoadScorings = true;
  bool _batchPsgRespiratory = true;
  bool _batchPsgPlm = true;
  bool _batchPsgCap = true;
  int _batchPsgHypopneaRule = 3;
  String _batchPsgPlmStandard = 'aasm';
  String _batchPsgCapSensitivity = 'standard';
  final TextEditingController _batchPsgWildcardController =
      TextEditingController(text: '*.edf');
  final TextEditingController _batchPsgPostfixController =
      TextEditingController(text: '_scoring');
  final TextEditingController _batchPsgPressureController = TextEditingController();
  final TextEditingController _batchPsgThermalController = TextEditingController();
  final TextEditingController _batchPsgSpo2Controller = TextEditingController();
  final TextEditingController _batchPsgLeftLegController = TextEditingController();
  final TextEditingController _batchPsgRightLegController = TextEditingController();
  final TextEditingController _batchPsgCapEegController = TextEditingController();
  final TextEditingController _batchPsgOutDirController = TextEditingController();
  Map<String, String> _batchAnalyseCustomRegionMap = {};

  // Batch Preprocessing State
  final List<String> _batchPreprocessFiles = [];
  bool _batchPreprocessStimArtifact = true;
  bool _batchPreprocessDownsample = false;
  bool _batchPreprocessFilter = true;
  bool _batchPreprocessBadChannel = true;
  bool _batchPreprocessGedai = true;
  bool _batchPreprocessInterpolate = true;
  bool _batchPreprocessRecursive = true;
  bool _batchPreprocessUseWildcard = false;
  final TextEditingController _batchPreprocessWildcardController =
      TextEditingController(text: '*.edf');
  final TextEditingController _batchPreprocessStimF0Controller =
      TextEditingController();
  final TextEditingController _batchPreprocessSuffixController =
      TextEditingController(text: '_clean');
  final TextEditingController _batchPreprocessOutDirController =
      TextEditingController();

  // Video Sync State
  String? _videoPath;
  VideoPlayerController? _videoController;
  bool _videoPanelVisible = false;
  bool _waveformMaximized = false;
  double _videoOffsetSeconds = 0.0;
  bool _isVideoPlaying = false;
  Timer? _videoSyncTimer;

  // ─── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_handleTabChange);
    FocusManager.instance.addListener(_handlePrimaryFocusChange);
    _viewport = _backend.loadDemoViewport();
    unawaited(_loadAppVersion());
  }

  Future<void> _loadAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _appVersion =
            'v${info.version}'
            '${info.buildNumber.isEmpty ? '' : ' (build ${info.buildNumber})'}';
      });
    } on MissingPluginException {
      // Package metadata is unavailable in widget tests without a host runner.
    }
  }

  @override
  void dispose() {
    _videoSyncTimer?.cancel();
    _videoController?.dispose();
    FocusManager.instance.removeListener(_handlePrimaryFocusChange);
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    _tfRefreshTimer?.cancel();
    _lightsMarkerSaveTimer?.cancel();
    _viewerFocusNode.dispose();
    _batchStagingEegController.dispose();
    _batchStagingRefController.dispose();
    _batchStagingEogController.dispose();
    _batchStagingEmgController.dispose();
    _batchAnalyseEegController.dispose();
    _batchAnalyseRefController.dispose();
    _batchScoringPostfixController.dispose();
    _batchStagingWildcardController.dispose();
    _batchAnalyseWildcardController.dispose();
    for (final c in [
      _batchPsgWildcardController,
      _batchPsgPostfixController,
      _batchPsgPressureController,
      _batchPsgThermalController,
      _batchPsgSpo2Controller,
      _batchPsgLeftLegController,
      _batchPsgRightLegController,
      _batchPsgCapEegController,
      _batchPsgOutDirController,
      _batchPreprocessWildcardController,
      _batchPreprocessStimF0Controller,
      _batchPreprocessSuffixController,
      _batchPreprocessOutDirController,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _handlePrimaryFocusChange() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    final editingText =
        focusContext?.widget is EditableText ||
        focusContext?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (!mounted || editingText == _textInputFocused) return;
    setState(() => _textInputFocused = editingText);
  }

  void _handleTabChange() {
    if (mounted) setState(() {});
  }

  // ─── Status bar helpers ───────────────────────────────────────────────────

  void _setStatus(String s) => setState(() => _status = s);

  void _showPending(String feature) =>
      _setStatus('$feature — not yet implemented in this version.');

  // ─── File loading ─────────────────────────────────────────────────────────

  Future<void> _openRecording({required String kind}) async {
    _setStatus(
      kind == 'mat'
          ? 'Opening MAT file picker…'
          : (kind == 'orbit'
                ? 'Opening Orbit file picker…'
                : 'Opening EDF file picker…'),
    );
    final result = await FilePicker.pickFiles(
      dialogTitle: kind == 'mat'
          ? 'Load EEGLAB structure (.mat)'
          : (kind == 'r09'
                ? 'Load Zurich file (.r09)'
                : (kind == 'nk'
                      ? 'Load Nihon Kohden recording (.eeg, .EEG)'
                      : (kind == 'orbit'
                            ? 'Load Orbit file (.orb, .signal)'
                            : (kind == 'ebm'
                                  ? 'Load EMBLA / REMlogic recording (.ebm)'
                                  : 'Load EEG recording (.edf, .eeg, .vhdr, .orb, .mat, .r09, .ebm)')))),
      type: FileType.custom,
      allowedExtensions: kind == 'mat'
          ? ['mat']
          : (kind == 'r09'
                ? ['r09']
                : (kind == 'nk'
                      ? ['eeg', 'EEG']
                      : (kind == 'orbit'
                            ? ['orb', 'signal']
                            : (kind == 'ebm'
                                  ? ['ebm', 'EBM']
                                  : ['edf', 'EDF', 'eeg', 'EEG', 'vhdr', 'VHDR', 'orb', 'signal', 'mat', 'r09', 'ebm', 'EBM'])))),
    );
    final path = result?.files.single.path;
    if (path == null) {
      _setStatus('Open cancelled');
      return;
    }
    await _openRecordingPath(path, kind: kind);
  }

  Future<void> _openRecordingPath(String path, {required String kind}) async {
    _setStatus('Loading ${_basename(path)} — computing spectrogram…');
    await Future.microtask(() {}); // let the UI update

    try {
      // Try to auto-load config JSON next to the EDF
      final autoCfg = await tryLoadAutoConfig(path);

      final LoadedEeg rawEeg;
      final lowerPath = path.toLowerCase();
      if (kind == 'edf' ||
          kind == 'nk' ||
          kind == 'orbit' ||
          kind == 'ebm' ||
          lowerPath.endsWith('.eeg') ||
          lowerPath.endsWith('.vhdr') ||
          lowerPath.endsWith('.ebm') ||
          lowerPath.endsWith('.orb') ||
          lowerPath.endsWith('.signal')) {
        rawEeg = _backend.loadEdf(path);
      } else if (kind == 'edfvolt') {
        rawEeg = _backend.loadEdf(path, scaleVoltsToMicrovolts: true);
      } else if (kind == 'r09' || lowerPath.endsWith('.r09')) {
        rawEeg = _backend.loadR09(path);
      } else {
        rawEeg = _backend.loadMat(path);
      }

      final activeConfig =
          autoCfg ??
          AppConfig.defaultsForChannels(
            rawEeg.channelLabels,
            sampleRateHz: rawEeg.sampleRateHz,
          );
      // ignore: avoid_print
      print(
        '[CCS Sleep Studio] Config ${autoCfg != null ? "LOADED" : "GENERATED"} '
        'for ${_basename(path)}: ${activeConfig.channels.length} channels',
      );
      if (autoCfg == null) {
        // Copy user preferences
        activeConfig.amplitudeRangeUv = _config.amplitudeRangeUv;
        activeConfig.tfFreqMin = _config.tfFreqMin;
        activeConfig.tfFreqMax = _config.tfFreqMax;
        activeConfig.spectrogramFreqMin = _config.spectrogramFreqMin;
        activeConfig.spectrogramFreqMax = _config.spectrogramFreqMax;
        activeConfig.swaChannelIndex = _config.swaChannelIndex;
        activeConfig.periodogramFreqMin = _config.periodogramFreqMin;
        activeConfig.periodogramFreqMax = _config.periodogramFreqMax;
        activeConfig.spectrogramPowerMin = _config.spectrogramPowerMin;
        activeConfig.spectrogramPowerMax = _config.spectrogramPowerMax;
        activeConfig.tfEnabled = _config.tfEnabled;
        activeConfig.tfDisplayMode = _config.tfDisplayMode;
        activeConfig.tfFrequencyScale = _config.tfFrequencyScale;
        activeConfig.tfShowRidge = _config.tfShowRidge;
        activeConfig.tfAutoScale = _config.tfAutoScale;
        activeConfig.tfPowerMin = _config.tfPowerMin;
        activeConfig.tfPowerMax = _config.tfPowerMax;
        activeConfig.stackChannels = _config.stackChannels;
        activeConfig.robustZStandardize = _config.robustZStandardize;
        activeConfig.periodogramDisplayMode = _config.periodogramDisplayMode;
        activeConfig.eegPanelTimeUnit = _config.eegPanelTimeUnit;
        activeConfig.hypnogramOverlayMode = _config.hypnogramOverlayMode;
        activeConfig.hypnogramProbabilityStage =
            _config.hypnogramProbabilityStage;
        activeConfig.showSwaPlot = _config.showSwaPlot;
        activeConfig.lightsOffSeconds = _config.lightsOffSeconds;
        activeConfig.lightsOnSeconds = _config.lightsOnSeconds;
        activeConfig.distanceBetweenChannelsUv =
            _config.distanceBetweenChannelsUv;
        activeConfig.referenceAmplitudeLineUv =
            _config.referenceAmplitudeLineUv;
        activeConfig.reportTitle = _config.reportTitle;
        activeConfig.studySite = _config.studySite;
        activeConfig.investigatorName = _config.investigatorName;
        activeConfig.subjectId = _config.subjectId;
        activeConfig.subjectDetails = _config.subjectDetails;
        activeConfig.recordingDate = _config.recordingDate;
      }
      activeConfig.bindLoadedChannels(
        rawEeg.channelLabels,
        sampleRateHz: rawEeg.sampleRateHz,
      );
      // Always save after binding — persists channel index corrections
      await saveAutoConfig(path, activeConfig);

      // Pre-compute night products. Per-epoch wavelets are computed lazily.
      _setStatus('Computing spectrogram and power summaries…');
      final eeg = await _backend.computeNightProducts(rawEeg, activeConfig);

      // Try to auto-load existing scoring and universal markers across all formats
      final epochCount = (eeg.durationSeconds / 30).ceil();
      final loadResult = await tryLoadAutoScoring(path, epochCount);
      final existingStages = loadResult?.stages;
      final existingStagesUncertain = loadResult?.stagesUncertain;
      final existingEvents = await tryLoadAllMarkers(
        path,
        sampleRateHz: rawEeg.sampleRateHz,
        recordingStartTime: rawEeg.recordingStartTime,
        channelLabels: rawEeg.channelLabels,
      );
      final nlgOverlay = await loadNlgOverlay(path);

      final viewport = await _backend.viewportFromEeg(
        eeg,
        currentEpoch: 0,
        config: activeConfig,
        existingStages: existingStages,
        existingStagesUncertain: existingStagesUncertain,
        existingConfidence: loadResult?.stagesConfidence,
        existingStageProbabilities: loadResult?.stageProbabilities,
        includeTimeFrequency: false,
      );

      setState(() {
        _activePath = path;
        _loadedEeg = eeg;
        _config = activeConfig;
        _nlgOverlay = nlgOverlay;
        _viewport = viewport.copyWith(scoredEvents: existingEvents);
        final markerText = existingEvents.isNotEmpty ? '  |  ${existingEvents.length} markers' : '';
        _status =
            'Loaded ${_basename(path)} — '
            '${existingStages != null ? '${existingStages.where((s) => s.isScored).length}/${existingStages.length} epochs scored' : 'scoring started'}$markerText';
      });
      _viewerFocusNode.requestFocus();
      if (_config.tfEnabled) {
        _scheduleTimeFrequencyRefresh(++_navigationSerial);
      }

      // Check for companion video file in the same directory
      unawaited(_tryAutoDetectCompanionVideo(path));
    } on UnsupportedError catch (e) {
      _setStatus(e.message ?? e.toString());
    } on Object catch (e) {
      _setStatus('Could not load ${_basename(path)}: $e');
    }
  }

  // ─── Video Playback & Sync ──────────────────────────────────────────────────

  Future<void> _openVideoFile() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Select Synchronized Video File',
      type: FileType.custom,
      allowedExtensions: [
        'mp4', 'mkv', 'avi', 'mov', 'webm', 'm2t', 'ts', 'mts', 'm2ts',
        'MP4', 'MKV', 'AVI', 'MOV', 'WEBM', 'M2T', 'TS', 'MTS', 'M2TS',
      ],
    );
    final p = result?.files.single.path;
    if (p != null) {
      await _loadVideo(p);
    }
  }

  Future<void> _loadVideo(String videoPath) async {
    try {
      _videoSyncTimer?.cancel();
      await _videoController?.dispose();
      _videoController = null;

      final controller = VideoPlayerController.file(File(videoPath));
      await controller.initialize();
      controller.addListener(_handleVideoPlayerUpdate);

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _videoPath = videoPath;
        _videoController = controller;
        _videoPanelVisible = true;
        _isVideoPlaying = false;
      });

      final currentEpoch = _viewport?.currentEpoch ?? 0;
      await _seekVideoToEpoch(currentEpoch);
      _setStatus('Loaded synchronized video: ${_basename(videoPath)}');
    } catch (e) {
      _setStatus('Could not load video: $e');
    }
  }

  void _handleVideoPlayerUpdate() {
    if (!mounted || _videoController == null) return;
    final playing = _videoController!.value.isPlaying;
    if (playing != _isVideoPlaying) {
      setState(() => _isVideoPlaying = playing);
      if (playing) {
        _startVideoPlaybackSync();
      } else {
        _videoSyncTimer?.cancel();
      }
    }
  }

  void _startVideoPlaybackSync() {
    _videoSyncTimer?.cancel();
    _videoSyncTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted || _videoController == null || !_videoController!.value.isPlaying) return;
      final posSec = _videoController!.value.position.inMilliseconds / 1000.0;
      final eegSec = posSec - _videoOffsetSeconds;
      if (eegSec < 0) return;

      final epochSec = _viewport?.epochSeconds ?? 30;
      final targetEpoch = (eegSec / epochSec).floor() + 1;
      final currentEpoch = _viewport?.currentEpoch ?? 0;
      if (targetEpoch != currentEpoch + 1 &&
          targetEpoch >= 1 &&
          targetEpoch <= (_viewport?.epochCount ?? 1)) {
        _jumpToEpoch(targetEpoch, false);
      }
    });
  }

  Future<void> _seekVideoToEpoch(int epoch) async {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    final epochSec = _viewport?.epochSeconds ?? 30;
    final eegSec = epoch * epochSec.toDouble();
    final targetVideoSec = math.max(0.0, eegSec + _videoOffsetSeconds);
    await controller.seekTo(Duration(milliseconds: (targetVideoSec * 1000).round()));
  }

  Future<void> _toggleVideoPlayPause() async {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
  }

  Future<void> _tryAutoDetectCompanionVideo(String eegPath) async {
    final dotIdx = eegPath.lastIndexOf('.');
    final base = dotIdx >= 0 ? eegPath.substring(0, dotIdx) : eegPath;
    final exts = [
      'mp4', 'MP4', 'mkv', 'MKV', 'avi', 'AVI', 'mov', 'MOV', 'webm', 'WEBM',
      'm2t', 'M2T', 'ts', 'TS', 'mts', 'MTS', 'm2ts', 'M2TS',
    ];
    for (final ext in exts) {
      final cand = '$base.$ext';
      if (File(cand).existsSync()) {
        await _loadVideo(cand);
        return;
      }
    }
  }

  // ─── Markers & Annotations Dialog ──────────────────────────────────────────

  void _openMarkersDialog() {
    final vp = _viewport;
    if (vp == null) return;
    showDialog(
      context: context,
      builder: (ctx) => MarkersDialog(
        events: vp.scoredEvents,
        disabledLabels: vp.disabledMarkerLabels,
        epochSeconds: vp.epochSeconds,
        epochCount: vp.epochCount,
        recordingStartTime: vp.recordingStartTime,
        customEventNames: _config.customEventNames,
        onUpdateEventNames: _updateCustomEventNames,
        onToggleLabel: (label, visible) {
          setState(() {
            final newSet = Set<String>.from(_viewport!.disabledMarkerLabels);
            if (visible) {
              newSet.remove(label);
            } else {
              newSet.add(label);
            }
            _viewport = _viewport!.copyWith(disabledMarkerLabels: newSet);
          });
        },
        onSetAllLabels: (selectAll) {
          setState(() {
            final newSet = selectAll
                ? <String>{}
                : {for (final ev in _viewport!.scoredEvents) ev.label};
            _viewport = _viewport!.copyWith(disabledMarkerLabels: newSet);
          });
        },
        onJumpToEvent: (ev) {
          final epoch = (ev.startSec / vp.epochSeconds).floor() + 1;
          _jumpToEpoch(epoch);
        },
      ),
    );
  }

  void _updateCustomEventNames(Map<int, String> newNames) {
    setState(() {
      _config.customEventNames = Map<int, String>.from(newNames);
    });
    if (_activePath != null) {
      unawaited(saveAutoConfig(_activePath!, _config));
    }
  }

  void _showEditEventNamesDialog() {
    final controllers = <int, TextEditingController>{};
    for (var i = 0; i <= 8; i++) {
      controllers[i] = TextEditingController(
        text: _config.customEventNames[i] ?? '',
      );
    }

    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.edit_note, size: 22, color: Colors.indigo),
            SizedBox(width: 8),
            Text('Customize Event Names'),
          ],
        ),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Define custom labels for event shortcut keys (0–8).\nLeave empty to use the default name.',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 12),
                for (var i = 0; i <= 8; i++) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 80,
                          child: Text(
                            i == 0 ? 'Artefact [A]:' : 'Event $i [F$i]:',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SizedBox(
                            height: 32,
                            child: TextField(
                              controller: controllers[i],
                              style: const TextStyle(fontSize: 12),
                              decoration: InputDecoration(
                                hintText: i == 0
                                    ? 'Artifact'
                                    : 'Event $i (e.g. Spindle)',
                                hintStyle: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.black38,
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                                border: const OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final newMap = <int, String>{};
              for (var i = 0; i <= 8; i++) {
                final txt = controllers[i]!.text.trim();
                if (txt.isNotEmpty) {
                  newMap[i] = txt;
                }
              }
              _updateCustomEventNames(newMap);
              Navigator.of(dialogCtx).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // ─── Close file ────────────────────────────────────────────────────────────

  void _closeCurrentFile() {
    _tfRefreshTimer?.cancel();
    _tfRefreshTimer = null;
    _videoSyncTimer?.cancel();
    _videoSyncTimer = null;
    _videoController?.dispose();
    _videoController = null;
    _videoPath = null;
    _videoPanelVisible = false;
    setState(() {
      _activePath = null;
      _loadedEeg = null;
      _comparisonStages = null;
      _nlgOverlay = null;
      _viewport = _backend.loadDemoViewport();
      _config = AppConfig(tfEnabled: false);
      _status = 'File closed — load an EDF file to begin scoring';
    });
  }

  // ─── Scoring ──────────────────────────────────────────────────────────────

  void _scoreCurrentEpoch(SleepStage stage) {
    final viewport = _viewport;
    if (viewport == null) return;

    final newStages = [
      for (var i = 0; i < viewport.epochCount; i++)
        i == viewport.currentEpoch ? stage : viewport.stages[i],
    ];
    setState(() {
      _viewport = viewport.copyWith(stages: newStages);
      _status = 'Epoch ${viewport.currentEpoch + 1} scored';
    });

    // Auto-save on every score change
    autoSaveScoring(
      _activePath,
      newStages,
      viewport.epochSeconds,
      events: viewport.scoredEvents,
      stagesUncertain: viewport.stagesUncertain,
      stagesConfidence: viewport.stagesConfidence,
      stageProbabilities: viewport.stageProbabilities,
    );

    // Auto-advance to next epoch (matching Python score_stage.py)
    _nextEpoch();
  }

  void _toggleUncertainty() {
    final v = _viewport;
    if (v == null) return;
    final epoch = v.currentEpoch;
    final newUncertain = List<bool>.from(v.stagesUncertain);
    newUncertain[epoch] = !newUncertain[epoch];
    final updated = v.copyWith(stagesUncertain: newUncertain);
    setState(() {
      _viewport = updated;
      _status =
          'Epoch ${epoch + 1} uncertainty toggled to ${newUncertain[epoch]}';
    });
    autoSaveScoring(
      _activePath,
      updated.stages,
      updated.epochSeconds,
      events: updated.scoredEvents,
      stagesUncertain: updated.stagesUncertain,
      stagesConfidence: updated.stagesConfidence,
      stageProbabilities: updated.stageProbabilities,
    );
  }

  void _toggleWavelet() async {
    final eeg = _loadedEeg;
    final v = _viewport;
    if (eeg == null || v == null) return;

    final newTfEnabled = !_config.tfEnabled;
    setState(() {
      _config.tfEnabled = newTfEnabled;
    });

    if (_activePath != null) {
      await saveAutoConfig(_activePath!, _config);
    }

    _setStatus(newTfEnabled ? 'Computing wavelet TF…' : 'Wavelet panel hidden');

    if (newTfEnabled) {
      _scheduleTimeFrequencyRefresh(++_navigationSerial);
    } else {
      final newViewport = await _backend.viewportFromEeg(
        eeg,
        currentEpoch: v.currentEpoch,
        config: _config,
        existingStages: v.stages,
        existingStagesUncertain: v.stagesUncertain,
        existingConfidence: v.stagesConfidence,
        existingStageProbabilities: v.stageProbabilities,
        includeTimeFrequency: false,
      );
      setState(() {
        _viewport = newViewport;
      });
    }
  }

  // ─── Navigation ───────────────────────────────────────────────────────────

  void _nextEpoch() => _jumpRelative(1);
  void _previousEpoch() => _jumpRelative(-1);

  void _jumpRelative(int delta) {
    final v = _viewport;
    if (v == null) return;
    _jumpToEpoch(v.currentEpoch + 1 + delta);
  }

  int? _pendingJumpEpoch;

  /// Coalesces bursts of navigation requests (e.g. dragging across the
  /// hypnogram or spectrogram, which fires on every pointer event — up to
  /// 1000 Hz with high-polling-rate mice on Windows) into one viewport
  /// rebuild per frame.
  void _jumpToEpochCoalesced(int epochOneBased) {
    final alreadyScheduled = _pendingJumpEpoch != null;
    _pendingJumpEpoch = epochOneBased;
    if (alreadyScheduled) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _pendingJumpEpoch;
      _pendingJumpEpoch = null;
      if (target != null && mounted) _jumpToEpoch(target);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _jumpToEpoch(int epochOneBased, [bool claimFocus = true]) {
    final v = _viewport;
    if (v == null) return;
    final epoch = (epochOneBased - 1).clamp(0, v.epochCount - 1);
    if (epoch == v.currentEpoch) {
      // Already there: skip the (expensive, synchronous) viewport rebuild.
      if (claimFocus && mounted) _viewerFocusNode.requestFocus();
      return;
    }
    final eeg = _loadedEeg;
    final serial = ++_navigationSerial;
    _tfRefreshTimer?.cancel();

    EegViewport newViewport;
    if (eeg == null) {
      newViewport = v.copyWith(currentEpoch: epoch);
    } else {
      newViewport = _backend
          .rebuildViewportForEpochSync(v, eeg, epoch, config: _config)
          .copyWith(stages: v.stages, stagesUncertain: v.stagesUncertain);
    }

    if (mounted) {
      setState(() {
        _viewport = newViewport;
      });
      if (claimFocus) {
        _viewerFocusNode.requestFocus();
      }
    }
    if (_videoController != null && !_isVideoPlaying) {
      unawaited(_seekVideoToEpoch(epoch));
    }
    if (eeg != null && _config.tfEnabled) {
      _scheduleTimeFrequencyRefresh(serial);
    }
  }

  void _scheduleTimeFrequencyRefresh(int serial) {
    _tfRefreshTimer?.cancel();
    _tfRefreshTimer = Timer(const Duration(milliseconds: 550), () {
      unawaited(_refreshTimeFrequency(serial));
    });
  }

  Future<void> _refreshTimeFrequency(int serial) async {
    final v = _viewport;
    final eeg = _loadedEeg;
    if (v == null || eeg == null || serial != _navigationSerial) return;

    try {
      final refreshed = await _backend.refreshTimeFrequencyForEpoch(
        v,
        eeg,
        config: _config,
        isCancelled: () => serial != _navigationSerial,
      );
      if (!mounted || serial != _navigationSerial) return;
      setState(() {
        _viewport = refreshed.copyWith(
          stages: v.stages,
          stagesUncertain: v.stagesUncertain,
        );
      });
    } catch (e) {
      if (!mounted || serial != _navigationSerial) return;
      _setStatus('Wavelet rendering failed: $e');
    }
  }

  // ─── Toolbar navigation jumps ─────────────────────────────────────────────

  /// Jump to the next epoch satisfying [test], starting from currentEpoch+1.
  void _jumpToNext(bool Function(SleepStage s) test, String label) {
    final v = _viewport;
    if (v == null) return;
    for (var i = v.currentEpoch + 1; i < v.epochCount; i++) {
      if (test(v.stages[i])) {
        _jumpToEpoch(i + 1);
        return;
      }
    }
    _setStatus('No more $label epochs found');
  }

  void _jumpNextUnscored() => _jumpToNext((s) => !s.isScored, 'unscored');

  void _jumpNextUncertain() {
    final v = _viewport;
    if (v == null) return;
    for (var i = v.currentEpoch + 1; i < v.epochCount; i++) {
      if (v.stagesUncertain[i]) {
        _jumpToEpoch(i + 1);
        return;
      }
    }
    _setStatus('No more uncertain epochs found');
  }

  void _jumpNextTransition() {
    final v = _viewport;
    if (v == null) return;
    for (var i = v.currentEpoch + 1; i < v.epochCount; i++) {
      if (i > 0 && v.stages[i] != v.stages[i - 1]) {
        _jumpToEpoch(i + 1);
        return;
      }
    }
    _setStatus('No more stage transitions found');
  }

  void _jumpNextHuman() => _jumpToNext(
    (s) => s.isScored && s != SleepStage.inconclusive,
    'human-scored',
  );

  void _jumpNextEvent() {
    final v = _viewport;
    if (v == null) return;
    final currentEpoch = v.currentEpoch;
    final eventEpochs = <int>{};
    for (final event in v.scoredEvents) {
      eventEpochs.addAll(event.epochs(v.epochSeconds, v.epochCount));
    }
    final sorted = eventEpochs.toList()..sort();
    for (final epoch in sorted) {
      if (epoch > currentEpoch) {
        _jumpToEpoch(epoch + 1);
        return;
      }
    }
    _setStatus('No more event epochs found');
  }

  void _jumpNextDisagreement() {
    final v = _viewport;
    final comparison = _comparisonStages;
    if (v == null || comparison == null) {
      _setStatus('No comparison scoring loaded');
      return;
    }
    for (
      var i = v.currentEpoch + 1;
      i < v.epochCount && i < comparison.length;
      i++
    ) {
      if (v.stages[i] != comparison[i]) {
        _jumpToEpoch(i + 1);
        return;
      }
    }
    _setStatus('No more disagreement epochs found');
  }

  void _updateFlexValues(
    int spectrogramFlex,
    int hypnogramFlex,
    int periodogramFlex,
  ) async {
    setState(() {
      _config.spectrogramFlex = spectrogramFlex;
      _config.hypnogramFlex = hypnogramFlex;
      _config.periodogramFlex = periodogramFlex;
    });

    final v = _viewport;
    if (v != null) {
      setState(() {
        _viewport = v.copyWith(
          spectrogramFlex: spectrogramFlex,
          hypnogramFlex: hypnogramFlex,
          periodogramFlex: periodogramFlex,
        );
      });
    }

    if (_activePath != null) {
      await saveAutoConfig(_activePath!, _config);
    }
  }

  // ─── Selection ────────────────────────────────────────────────────────────

  Future<void> _updateSelection(
    double? startSec,
    double? endSec,
    int? channel,
    double? startUv,
    double? endUv,
  ) async {
    final v = _viewport;
    final eeg = _loadedEeg;
    if (v == null || eeg == null) return;

    final newViewport = await _backend.updateSelection(
      v,
      eeg,
      startSec,
      endSec,
      channel: channel,
      startUv: startUv,
      endUv: endUv,
      config: _config,
    );
    if (mounted) {
      setState(() {
        _viewport = newViewport;
      });
      if (newViewport.scoredEvents.length != v.scoredEvents.length) {
        autoSaveScoring(
          _activePath,
          newViewport.stages,
          newViewport.epochSeconds,
          events: newViewport.scoredEvents,
          stagesUncertain: newViewport.stagesUncertain,
        );
      }
    }
  }

  void _markEvent(int digit) {
    final v = _viewport;
    if (v == null) return;
    final label = _eventLabel(digit);
    final key = digit == 0 ? 'A' : 'F$digit';
    final newEvents = <ScoredEvent>[...v.scoredEvents];
    if (v.eventSelections.isEmpty) {
      final start = v.currentEpoch * v.epochSeconds.toDouble();
      newEvents.add(
        ScoredEvent(
          digit: digit,
          key: key,
          label: label,
          startSec: start,
          endSec: start + v.epochSeconds,
        ),
      );
    } else {
      for (final selection in v.eventSelections) {
        final start = selection.startSec < selection.endSec
            ? selection.startSec
            : selection.endSec;
        final end = selection.startSec < selection.endSec
            ? selection.endSec
            : selection.startSec;
        if (end > start) {
          newEvents.add(
            ScoredEvent(
              digit: digit,
              key: key,
              label: label,
              startSec: start,
              endSec: end,
            ),
          );
        }
      }
    }
    setState(() {
      _viewport = v.copyWith(
        scoredEvents: _mergeScoredEvents(newEvents),
        clearSelection: true,
        clearEventSelections: true,
      );
      _status = 'Marked ${_eventLabel(digit)}';
    });
    final updated = _viewport;
    if (updated != null) {
      autoSaveScoring(
        _activePath,
        updated.stages,
        updated.epochSeconds,
        events: updated.scoredEvents,
        stagesUncertain: updated.stagesUncertain,
        stagesConfidence: updated.stagesConfidence,
        stageProbabilities: updated.stageProbabilities,
      );
    }
  }

  void _eraseEventsInSelections() {
    final v = _viewport;
    if (v == null || v.eventSelections.isEmpty) return;
    final eraseRanges = [
      for (final selection in v.eventSelections)
        (
          selection.startSec < selection.endSec
              ? selection.startSec
              : selection.endSec,
          selection.startSec < selection.endSec
              ? selection.endSec
              : selection.startSec,
        ),
    ];
    final kept = <ScoredEvent>[];
    for (final event in v.scoredEvents) {
      var fragments = <(double, double)>[(event.startSec, event.endSec)];
      for (final erase in eraseRanges) {
        final next = <(double, double)>[];
        for (final fragment in fragments) {
          final start = fragment.$1;
          final end = fragment.$2;
          final eraseStart = erase.$1;
          final eraseEnd = erase.$2;
          if (eraseEnd <= start || eraseStart >= end) {
            next.add(fragment);
          } else {
            if (eraseStart > start) next.add((start, eraseStart));
            if (eraseEnd < end) next.add((eraseEnd, end));
          }
        }
        fragments = next;
      }
      for (final fragment in fragments) {
        if (fragment.$2 > fragment.$1) {
          kept.add(
            ScoredEvent(
              digit: event.digit,
              key: event.key,
              label: event.label,
              startSec: fragment.$1,
              endSec: fragment.$2,
            ),
          );
        }
      }
    }
    setState(() {
      _viewport = v.copyWith(
        scoredEvents: kept,
        clearSelection: true,
        clearEventSelections: true,
      );
      _status = 'Erased events in drawn selection';
    });
    final updated = _viewport;
    if (updated != null) {
      autoSaveScoring(
        _activePath,
        updated.stages,
        updated.epochSeconds,
        events: updated.scoredEvents,
        stagesUncertain: updated.stagesUncertain,
        stagesConfidence: updated.stagesConfidence,
        stageProbabilities: updated.stageProbabilities,
      );
    }
  }

  void _deleteAllEvents() {
    final v = _viewport;
    if (v == null) return;
    setState(() {
      _viewport = v.copyWith(
        scoredEvents: const [],
        clearEventSelections: true,
      );
      _status = 'Deleted all events';
    });
    autoSaveScoring(
      _activePath,
      v.stages,
      v.epochSeconds,
      stagesUncertain: v.stagesUncertain,
      stagesConfidence: v.stagesConfidence,
      stageProbabilities: v.stageProbabilities,
    );
  }

  List<ScoredEvent> _mergeScoredEvents(List<ScoredEvent> events) {
    events.sort((a, b) {
      final labelCompare = a.digit.compareTo(b.digit);
      if (labelCompare != 0) return labelCompare;
      return a.startSec.compareTo(b.startSec);
    });
    final merged = <ScoredEvent>[];
    for (final event in events) {
      if (merged.isEmpty ||
          merged.last.digit != event.digit ||
          event.startSec > merged.last.endSec) {
        merged.add(event);
      } else {
        final last = merged.removeLast();
        merged.add(
          ScoredEvent(
            digit: last.digit,
            key: last.key,
            label: last.label,
            startSec: last.startSec,
            endSec: event.endSec > last.endSec ? event.endSec : last.endSec,
          ),
        );
      }
    }
    return merged;
  }

  String _eventLabel(int digit) {
    final custom = _config.customEventNames[digit]?.trim();
    if (custom != null && custom.isNotEmpty) return custom;
    final psgName = kPsgEventNames[digit];
    if (psgName != null) return psgName;
    return digit == 0 ? 'Artifact' : 'Event $digit';
  }

  // ─── Scoring I/O ──────────────────────────────────────────────────────────

  Future<void> _loadScoring() async {
    final v = _viewport;
    if (v == null) {
      _setStatus('Load an EDF first');
      return;
    }
    final result = await importScoringDialog(
      v.epochCount,
      'any',
      onStatus: _setStatus,
    );
    if (result != null) {
      setState(() {
        _viewport = v.copyWith(
          stages: result.stages,
          stagesUncertain: result.stagesUncertain,
          stagesConfidence: result.stagesConfidence,
          stageProbabilities: result.stageProbabilities,
        );
      });
    }
  }

  Future<void> _runAutoScoring() async {
    final v = _viewport;
    final eeg = _loadedEeg;
    final path = _activePath;
    if (v == null || eeg == null || path == null) {
      _setStatus('Load an EDF first');
      return;
    }

    showDialog(
      context: context,
      builder: (_) => AutoScoringDialog(
        channelLabels: _config.channels.isNotEmpty
            ? _config.channels.map((c) => c.name).toList()
            : eeg.channelLabels,
        onRun: (settings) async {
          List<String> mapBack(List<String> list) {
            return list.map((selName) {
              final matchingConfig = _config.channels.firstWhere(
                (c) => c.name == selName,
                orElse: () => ChannelConfig(name: selName),
              );
              return (matchingConfig.sourceIndex != null &&
                      matchingConfig.sourceIndex! < eeg.channelLabels.length)
                  ? eeg.channelLabels[matchingConfig.sourceIndex!]
                  : selName;
            }).toList();
          }

          final mappedSettings = {
            ...settings,
            'eeg': mapBack(List<String>.from(settings['eeg'] as List? ?? const [])),
            'ref': mapBack(List<String>.from(settings['ref'] as List? ?? const [])),
            'eog': mapBack(List<String>.from(settings['eog'] as List? ?? const [])),
            'emg': mapBack(List<String>.from(settings['emg'] as List? ?? const [])),
          };
          _executeAutoScoring(mappedSettings);
        },
      ),
    );
  }

  Future<void> _executeAutoScoring(Map<String, dynamic> settings) async {
    final v = _viewport;
    final eeg = _loadedEeg;
    final path = _activePath;
    if (v == null || eeg == null || path == null) return;

    final navigator = Navigator.of(context);
    final algorithm = canonicalAutoscoreAlgorithm(
      settings['algorithm'] as String? ?? 'tinysleepnet',
    );
    final algoLabel = autoscoreAlgorithmLabel(algorithm);
    if (!isAnalyseNidraAvailable()) {
      const message =
          'The native analyse-nidra engine was not found beside the '
          'application. Reinstall CCS Sleep Studio to restore autoscoring.';
      _setStatus(message);
      if (mounted) _showTextDialog('AutoscoreNidra unavailable', message);
      return;
    }
    final executable = detectAnalyseNidraExecutable();
    final correction = settings['sequence_correction'] as String?;
    List<String> settingList(String key) =>
        (settings[key] as List?)?.map((e) => e.toString()).toList() ??
        const <String>[];

    final logsController = StreamController<String>();
    final logLines = <String>[];
    final scrollController = ScrollController();
    var isDone = false;
    var progress = 0.0;
    var progressLabel = 'Starting $algoLabel…';
    String? outputJsonPath;
    StateSetter? setStateDialogRef;
    var dialogActive = true;
    final startupStopwatch = Stopwatch()..start();
    Timer? startupTimer;

    final dialogFuture = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            setStateDialogRef = setStateDialog;
            return AlertDialog(
              title: const Text('AutoscoreNidra Progress'),
              content: SizedBox(
                width: 600,
                height: 400,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      progressLabel,
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 10),
                    LinearProgressIndicator(
                      value: progress > 0 ? progress : null,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${(progress * 100).round()}%',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.black54,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        color: Colors.black87,
                        width: double.infinity,
                        child: StreamBuilder<String>(
                          stream: logsController.stream,
                          builder: (context, snapshot) {
                            return Scrollbar(
                              child: ListView.builder(
                                controller: scrollController,
                                shrinkWrap: true,
                                itemCount: logLines.length,
                                itemBuilder: (context, index) {
                                  return Text(
                                    logLines[index],
                                    style: const TextStyle(
                                      color: Colors.lightGreenAccent,
                                      fontFamily: 'Courier',
                                      fontSize: 12,
                                    ),
                                  );
                                },
                              ),
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
                  onPressed: isDone
                      ? () {
                          navigator.pop();
                        }
                      : null,
                  child: Text(isDone ? 'Close' : 'Scoring…'),
                ),
              ],
            );
          },
        );
      },
    );
    unawaited(
      dialogFuture.whenComplete(() {
        dialogActive = false;
        setStateDialogRef = null;
        startupTimer?.cancel();
        scrollController.dispose();
      }),
    );
    startupTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!dialogActive || progress > 0) {
        startupTimer?.cancel();
        return;
      }
      progressLabel =
          'Scoring with $algoLabel (${startupStopwatch.elapsed.inSeconds}s elapsed)';
      setStateDialogRef?.call(() {});
    });

    Future.microtask(() async {
      _setStatus('Starting $algoLabel autoscoring…');
      Directory? tempDir;
      try {
        void onLine(String line) {
          final update = _scoringProgressFromLine(line);
          if (update != null) {
            progress = math.max(progress, update.$1);
            progressLabel = update.$2;
            if (progress > 0) startupTimer?.cancel();
          }
          if (logsController.isClosed) return;
          logsController.add(line);
          logLines.add(line);
          if (dialogActive) setStateDialogRef?.call(() {});
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (scrollController.hasClients) {
              scrollController.jumpTo(
                scrollController.position.maxScrollExtent,
              );
            }
          });
        }

        var stageInput = path;
        String? explicitOut;
        if (!analyseNidraReadsNatively(path)) {
          onLine('Converting ${_basename(path)} to a temporary EDF for the native engine…');
          tempDir = await Directory.systemTemp.createTemp('ccs_autoscore_');
          var stem = _basename(path);
          final dot = stem.lastIndexOf('.');
          if (dot > 0) stem = stem.substring(0, dot);
          stageInput = '${tempDir.path}${Platform.pathSeparator}$stem.edf';
          await processEdfFile(path, stageInput, EdfTransformOptions());
          explicitOut = nativeStageOutputPath(
            path,
            algorithm,
            sequenceCorrection: correction,
          );
        }
        final commandArgs = buildNativeStageArgs(
          inputPath: stageInput,
          algorithm: algorithm,
          sequenceCorrection: correction,
          sleepgptAlpha: settings['sleepgpt_alpha'],
          sleepgptNgram: settings['sleepgpt_ngram'],
          eeg: settingList('eeg'),
          ref: settingList('ref'),
          eog: settingList('eog'),
          emg: settingList('emg'),
          outJson: explicitOut,
        );
        onLine('Native $algoLabel engine launched (analyse-nidra).');
        final exitCode = await _backend.runCommandStreamAsync(
          executable: executable,
          arguments: commandArgs,
          onLine: onLine,
        );
        isDone = true;
        if (dialogActive) setStateDialogRef?.call(() {});
        outputJsonPath = _outputPathFromLogs(logLines);

        if (exitCode == 0 &&
            outputJsonPath != null &&
            outputJsonPath!.isNotEmpty) {
          logsController.add(
            '\nScoring finished successfully! Loading predictions...',
          );
          logLines.add(
            '\nScoring finished successfully! Loading predictions...',
          );
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (scrollController.hasClients) {
              scrollController.jumpTo(
                scrollController.position.maxScrollExtent,
              );
            }
          });

          final scoringData = await loadScoringFileDirectly(
            outputJsonPath!,
            'scoringhero',
            v.epochCount,
          );
          setState(() {
            _viewport = v.copyWith(
              stages: scoringData.stages,
              stagesUncertain: scoringData.stagesUncertain,
              stagesConfidence: scoringData.stagesConfidence,
              stageProbabilities: scoringData.stageProbabilities,
            );
            _status = 'AutoscoreNidra completed with $algoLabel';
          });
          if (dialogActive) navigator.pop();
        } else {
          logsController.add('\nScoring failed with exit code $exitCode');
          logLines.add('\nScoring failed with exit code $exitCode');
          _setStatus('AutoscoreNidra failed. Exit code: $exitCode');

          if (dialogActive) navigator.pop();
          if (mounted) {
            showDialog(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('AutoscoreNidra Failed'),
                content: SizedBox(
                  width: 600,
                  height: 400,
                  child: SingleChildScrollView(
                    child: Text(
                      'AutoscoreNidra returned exit code $exitCode.\n\nLogs:\n${logLines.join('\n')}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'Courier',
                      ),
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ],
              ),
            );
          }
        }
      } catch (e) {
        logsController.add('\nException occurred: $e');
        logLines.add('\nException occurred: $e');
        _setStatus('AutoscoreNidra failed: $e');
        isDone = true;
        if (dialogActive) navigator.pop();
        if (mounted) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('AutoscoreNidra Exception'),
              content: SizedBox(
                width: 600,
                height: 400,
                child: SingleChildScrollView(
                  child: Text(
                    'AutoscoreNidra encountered an exception: $e\n\nLogs:\n${logLines.join('\n')}',
                    style: const TextStyle(fontSize: 12, fontFamily: 'Courier'),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            ),
          );
        }
      } finally {
        startupTimer?.cancel();
        logsController.close();
        if (tempDir != null) {
          try {
            await tempDir.delete(recursive: true);
          } catch (_) {}
        }
      }
    });
  }

  Future<void> _applySleepGptToCurrentHypnogram() async {
    final v = _viewport;
    final path = _activePath;
    if (v == null || path == null) {
      _setStatus('Load and score a recording first');
      return;
    }
    if (!v.stages.any((stage) => stage.isScored)) {
      _setStatus('No existing hypnogram is available for SleepGPT correction');
      return;
    }
    final unsupportedEpoch = v.stages.indexWhere(
      (stage) =>
          stage == SleepStage.unknown || stage == SleepStage.inconclusive,
    );
    if (unsupportedEpoch >= 0) {
      _setStatus(
        'SleepGPT needs a fully scored W/N1/N2/N3/REM hypnogram; '
        'epoch ${unsupportedEpoch + 1} is ${v.stages[unsupportedEpoch].label}',
      );
      return;
    }

    if (!isAnalyseNidraAvailable()) {
      const message =
          'The native analyse-nidra engine was not found beside the '
          'application. Reinstall CCS Sleep Studio to use SleepGPT.';
      _setStatus(message);
      if (mounted) _showTextDialog('AutoscoreNidra unavailable', message);
      return;
    }
    final sleepGptExecutable = detectAnalyseNidraExecutable();

    final tempDir = await Directory.systemTemp.createTemp(
      'ccs_sleep_studio_sleepgpt_',
    );
    final inputPath =
        '${tempDir.path}/${_basename(path)}_current_hypnogram.json';
    final outputPath =
        '${tempDir.path}/${_basename(path)}_sleepgpt_corrected.json';
    await writeMappedScoringJson(
      inputPath,
      v.stages,
      epochSeconds: v.epochSeconds,
      events: v.scoredEvents,
      stagesUncertain: v.stagesUncertain,
      stagesConfidence: v.stagesConfidence,
      stageProbabilities: v.stageProbabilities,
    );

    final logs = <String>[];
    var progress = 0.0;
    var progressLabel = 'Applying SleepGPT to current hypnogram...';
    StateSetter? dialogSetState;
    var dialogActive = true;
    if (!mounted) return;
    final navigator = Navigator.of(context);
    final dialogFuture = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) {
          dialogSetState = setStateDialog;
          return AlertDialog(
            title: const Text('SleepGPT Sequence Correction'),
            content: SizedBox(
              width: 560,
              height: 340,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    progressLabel,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    value: progress > 0 ? progress : null,
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      color: Colors.black87,
                      child: SingleChildScrollView(
                        child: Text(
                          logs.join('\n'),
                          style: const TextStyle(
                            color: Colors.lightGreenAccent,
                            fontFamily: 'Courier',
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    unawaited(
      dialogFuture.whenComplete(() {
        dialogActive = false;
        dialogSetState = null;
      }),
    );

    void onLine(String line) {
      logs.add(line);
      if (line.startsWith('SleepGPT progress:')) {
        final match = RegExp(r'\((\d+)%\)').firstMatch(line);
        if (match != null) {
          progress = (int.tryParse(match.group(1) ?? '') ?? 0) / 100.0;
        }
        progressLabel = line;
      } else if (line.contains('SleepGPT correction complete')) {
        progress = 1.0;
        progressLabel = line;
      }
      if (dialogActive) dialogSetState?.call(() {});
    }

    _setStatus('Applying SleepGPT sequence correction…');
    try {
      final args = <String>[
        '--apply-sleepgpt',
        inputPath,
        '--out',
        outputPath,
      ];
      final exitCode = await _backend.runCommandStreamAsync(
        executable: sleepGptExecutable,
        arguments: args,
        onLine: onLine,
      );
      if (dialogActive) navigator.pop();
      if (exitCode != 0) {
        _showTextDialog(
          'SleepGPT correction failed',
          'Backend returned exit code $exitCode.\n\n${logs.join('\n')}',
        );
        _setStatus('SleepGPT correction failed');
        return;
      }
      final corrected = await loadScoringFileDirectly(
        outputPath,
        'scoringhero',
        v.epochCount,
      );
      setState(() {
        _viewport = v.copyWith(
          stages: corrected.stages,
          stagesUncertain: corrected.stagesUncertain,
          stagesConfidence: corrected.stagesConfidence,
          stageProbabilities: corrected.stageProbabilities,
        );
        _status = 'SleepGPT correction applied to current hypnogram';
      });
      final updated = _viewport;
      if (updated != null) {
        await autoSaveScoring(
          path,
          updated.stages,
          updated.epochSeconds,
          events: updated.scoredEvents,
          stagesUncertain: updated.stagesUncertain,
          stagesConfidence: updated.stagesConfidence,
          stageProbabilities: updated.stageProbabilities,
        );
      }
    } catch (e) {
      if (dialogActive) navigator.pop();
      _setStatus('SleepGPT correction failed: $e');
      if (mounted) {
        _showTextDialog(
          'SleepGPT correction failed',
          '$e\n\n${logs.join('\n')}',
        );
      }
    } finally {
      unawaited(tempDir.delete(recursive: true).catchError((_) => tempDir));
    }
  }

  Future<void> _showSimilarEpochDialog() async {
    final v = _viewport;
    final eeg = _loadedEeg;
    if (v == null || eeg == null) {
      _setStatus('Load a recording first');
      return;
    }
    final visibleLabels = v.signalChannelLabels;
    final visibleSourceIndices = v.signalChannelSourceIndices;
    final channelOptions = <_SimilarChannelOption>[
      for (var i = 0; i < visibleLabels.length; i++)
        _SimilarChannelOption(
          label: visibleLabels[i],
          sourceIndex: visibleSourceIndices.length > i
              ? visibleSourceIndices[i]
              : i,
        ),
    ];
    final settings = await showDialog<_SimilarEpochSettings>(
      context: context,
      builder: (_) => _SimilarEpochDialog(
        channelOptions: channelOptions.isNotEmpty
            ? channelOptions
            : [
                for (var i = 0; i < eeg.channelLabels.length; i++)
                  _SimilarChannelOption(
                    label: eeg.channelLabels[i],
                    sourceIndex: i,
                  ),
              ],
        initialStage: v.currentStage == SleepStage.unknown
            ? SleepStage.inconclusive
            : v.currentStage,
      ),
    );
    if (settings == null) return;

    _setStatus('Searching for epochs similar to epoch ${v.currentEpoch + 1}…');
    await Future<void>.delayed(Duration.zero);
    try {
      final matches = _findSimilarEpochs(eeg, v, settings);
      if (matches.isEmpty) {
        _setStatus('No similar epochs matched the selected criteria');
        return;
      }
      if (!mounted) return;
      final selected = await showDialog<List<_SimilarEpochMatch>>(
        context: context,
        builder: (_) => _SimilarEpochResultsDialog(
          matches: matches,
          viewport: v,
          actionLabel: settings.actionLabel,
          onJumpToEpoch: (epoch) => _jumpToEpoch(epoch + 1),
        ),
      );
      if (selected == null || selected.isEmpty) {
        _setStatus('Similar epoch search cancelled');
        return;
      }
      _applySimilarEpochMatches(v, selected, settings);
    } catch (e) {
      _setStatus('Similar epoch search failed: $e');
      if (mounted) _showTextDialog('Similar epoch search failed', e.toString());
    }
  }

  List<_SimilarEpochMatch> _findSimilarEpochs(
    LoadedEeg eeg,
    EegViewport viewport,
    _SimilarEpochSettings settings,
  ) {
    final selectedChannels = [
      for (var i = 0; i < eeg.channelLabels.length; i++)
        if (settings.channelIndices.contains(i)) i,
    ];
    if (selectedChannels.isEmpty) {
      throw StateError('Select at least one channel.');
    }
    final features = _computeEpochPatternFeatures(
      eeg,
      viewport.epochSeconds,
      selectedChannels,
    );
    if (viewport.currentEpoch >= features.length) return const [];
    final normalized = _zNormalizeFeatureMatrix(features);
    final seed = normalized[viewport.currentEpoch];
    final matches = <_SimilarEpochMatch>[];
    for (var epoch = 0; epoch < normalized.length; epoch++) {
      if (settings.skipCurrentEpoch && epoch == viewport.currentEpoch) {
        continue;
      }
      final distance = _euclideanDistance(seed, normalized[epoch]);
      final similarity = 1.0 / (1.0 + distance);
      matches.add(_SimilarEpochMatch(epoch: epoch, similarity: similarity));
    }
    matches.sort((a, b) => b.similarity.compareTo(a.similarity));
    return matches
        .where((match) => match.similarity >= settings.minSimilarity)
        .take(settings.maxMatches)
        .toList();
  }

  void _applySimilarEpochMatches(
    EegViewport viewport,
    List<_SimilarEpochMatch> matches,
    _SimilarEpochSettings settings,
  ) {
    final matchedEpochs = matches.map((match) => match.epoch).toSet();
    var updatedEvents = viewport.scoredEvents;
    var updatedStages = viewport.stages;
    if (settings.action == _SimilarEpochAction.stage) {
      updatedStages = [
        for (var i = 0; i < viewport.epochCount; i++)
          matchedEpochs.contains(i) ? settings.stage : viewport.stages[i],
      ];
    } else {
      final newEvents = <ScoredEvent>[...viewport.scoredEvents];
      for (final epoch in matchedEpochs) {
        final start = epoch * viewport.epochSeconds.toDouble();
        newEvents.add(
          ScoredEvent(
            digit: settings.eventDigit,
            key: settings.eventDigit == 0 ? 'A' : 'F${settings.eventDigit}',
            label: _eventLabel(settings.eventDigit),
            startSec: start,
            endSec: start + viewport.epochSeconds,
          ),
        );
      }
      updatedEvents = _mergeScoredEvents(newEvents);
    }

    setState(() {
      _viewport = viewport.copyWith(
        stages: updatedStages,
        scoredEvents: updatedEvents,
      );
      _status =
          'Applied ${settings.actionLabel} to ${matches.length} similar epochs '
          '(best ${(matches.first.similarity * 100).toStringAsFixed(1)}%)';
    });
    final updated = _viewport;
    if (updated != null) {
      autoSaveScoring(
        _activePath,
        updated.stages,
        updated.epochSeconds,
        events: updated.scoredEvents,
        stagesUncertain: updated.stagesUncertain,
        stagesConfidence: updated.stagesConfidence,
        stageProbabilities: updated.stageProbabilities,
      );
    }
  }

  Future<void> _runBatchAutoScoring() async {
    _tabController.animateTo(1);
  }

  Future<void> _runAnalyseNidraCurrent() async {
    final path = _activePath;
    final eeg = _loadedEeg;
    final viewport = _viewport;
    if (path == null || eeg == null || viewport == null) {
      _setStatus('Load an EDF first');
      return;
    }
    if (!path.toLowerCase().endsWith('.edf')) {
      _setStatus('AnalyseNidra currently requires an EDF recording');
      return;
    }
    await autoSaveScoring(
      path,
      viewport.stages,
      viewport.epochSeconds,
      stagesUncertain: viewport.stagesUncertain,
      stagesConfidence: viewport.stagesConfidence,
      stageProbabilities: viewport.stageProbabilities,
    );
    final scoringPath = _analyseNidraScoringPath(path);
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AnalyseNidraDialog(
        channelLabels: _config.channels.isNotEmpty
            ? _config.channels.map((c) => c.name).toList()
            : eeg.channelLabels,
        batchCount: 1,
        initialOptions: _analyseOptions,
        onRun: (
          channels,
          references, {
          bool perChannel = false,
          String? regionMapJson,
          AnalyseNidraOptions? options,
        }) {
          if (options != null) _analyseOptions = options;
          _runAnalyseNidraJobs(
            [
              _AnalyseNidraJob(
                edfPath: path,
                scoringPath: scoringPath,
                mappedScoringPath: scoringPath,
              ),
            ],
            channels,
            references,
            perChannel: perChannel,
            regionMapJson: regionMapJson,
            options: options ?? _analyseOptions,
          );
        },
      ),
    );
  }

  Future<void> _runAnalyseNidraBatch() async {
    _tabController.animateTo(1);
  }

  Future<void> _autoInspectBatchAnalyseChannels() async {
    final validEeg = _batchAnalysePairs
        .map((p) => p['eegPath'] ?? '')
        .firstWhere((p) => p.isNotEmpty, orElse: () => '');
    if (validEeg.isEmpty) return;

    final channels = await extractRecordingChannels(validEeg);
    if (channels.isEmpty || !mounted) return;

    setState(() {
      _batchAnalyseAvailableChannels = channels;
      // If EEG channel field is empty, populate with detected EEG channels from 1st file
      final currentEeg = _batchAnalyseEegController.text.trim();
      if (currentEeg.isEmpty || currentEeg == 'AF7,AF8') {
        final eegs = channels.where(isLikelyEegChannel).toList();
        if (eegs.isNotEmpty) {
          _batchAnalyseEegController.text = eegs.join(',');
        } else {
          _batchAnalyseEegController.text = channels.take(6).join(',');
        }
      }
      // If Reference channel field is empty or old default 'PPG', check if PPG or M1/M2 or A1/A2 is in channels
      final currentRef = _batchAnalyseRefController.text.trim();
      if (currentRef.isEmpty || currentRef == 'PPG') {
        final lowerChans = channels.map((c) => c.toLowerCase()).toList();
        if (lowerChans.contains('ppg')) {
          _batchAnalyseRefController.text = channels[lowerChans.indexOf('ppg')];
        } else if (lowerChans.contains('m1') && lowerChans.contains('m2')) {
          _batchAnalyseRefController.text = 'M1,M2';
        } else if (lowerChans.contains('a1') && lowerChans.contains('a2')) {
          _batchAnalyseRefController.text = 'A1,A2';
        } else if (currentRef == 'PPG') {
          _batchAnalyseRefController.text = '';
        }
      }
    });
  }

  Future<void> _openBatchAnalyseChannelSelector() async {
    final validEeg = _batchAnalysePairs
        .map((p) => p['eegPath'] ?? '')
        .firstWhere((p) => p.isNotEmpty, orElse: () => '');
    if (validEeg.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please add EEG files first to extract available channels from the 1st recording.'),
        ),
      );
      return;
    }

    List<String> available = _batchAnalyseAvailableChannels;
    if (available.isEmpty) {
      available = await extractRecordingChannels(validEeg);
      if (mounted && available.isNotEmpty) {
        setState(() => _batchAnalyseAvailableChannels = available);
      }
    }

    if (available.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not read channel labels from ${_basename(validEeg)}. You can type channels manually.'),
          ),
        );
      }
      return;
    }

    final currentSelected = _batchAnalyseEegController.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    if (!mounted) return;
    final selected = await showChannelSelectionDialog(
      context: context,
      title: 'Select EEG Channels for AnalyseNidra',
      recordingPath: validEeg,
      availableChannels: available,
      initialSelectedChannels: currentSelected,
    );

    if (selected != null && mounted) {
      setState(() {
        _batchAnalyseEegController.text = selected.join(',');
      });
    }
  }

  Future<void> _openBatchAnalyseRefSelector() async {
    final validEeg = _batchAnalysePairs
        .map((p) => p['eegPath'] ?? '')
        .firstWhere((p) => p.isNotEmpty, orElse: () => '');
    if (validEeg.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please add EEG files first to extract available channels.'),
        ),
      );
      return;
    }

    List<String> available = _batchAnalyseAvailableChannels;
    if (available.isEmpty) {
      available = await extractRecordingChannels(validEeg);
      if (mounted && available.isNotEmpty) {
        setState(() => _batchAnalyseAvailableChannels = available);
      }
    }

    if (available.isEmpty) return;

    final currentSelected = _batchAnalyseRefController.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    if (!mounted) return;
    final selected = await showChannelSelectionDialog(
      context: context,
      title: 'Select Reference Channel(s) for AnalyseNidra',
      recordingPath: validEeg,
      availableChannels: available,
      initialSelectedChannels: currentSelected,
    );

    if (selected != null && mounted) {
      setState(() {
        _batchAnalyseRefController.text = selected.join(',');
      });
    }
  }

  // ─── Shared batch file-selection helpers ──────────────────────────────────

  static const List<String> _batchAutoscoreExtensions = [
    'edf', 'eeg', 'vhdr', 'orb', 'signal', 'ebm', 'mat', 'r09',
  ];
  static const List<String> _batchAnalyseExtensions = ['edf', 'orb', 'signal'];

  void _batchSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// "Add Single Files…" / "Add from Folder…" for both batch panels. The
  /// subfolder and wildcard options apply to folder scans; the wildcard also
  /// filters individually picked files.
  Future<List<String>> _collectBatchRecordings({
    required bool fromFolder,
    required List<String> extensions,
    required bool recursive,
    required bool useWildcard,
    required String pattern,
    required String title,
  }) async {
    final exts = extensions.map((e) => e.toLowerCase()).toSet();
    bool extOk(String path) => exts.contains(path.split('.').last.toLowerCase());
    final pat = pattern.trim().isEmpty ? '*' : pattern.trim();
    if (!fromFolder) {
      final result = await FilePicker.pickFiles(
        dialogTitle: title,
        type: FileType.custom,
        allowedExtensions: [for (final e in exts) ...[e, e.toUpperCase()]],
        allowMultiple: true,
      );
      final paths = result?.files.map((f) => f.path).whereType<String>().toList() ??
          const <String>[];
      final kept = useWildcard ? paths.where((p) => matchesWildcard(p, pat)).toList() : paths;
      if (useWildcard && kept.length < paths.length) {
        _batchSnack('${paths.length - kept.length} file(s) skipped: they do not match "$pat".');
      }
      return kept;
    }
    final dir = await FilePicker.getDirectoryPath(dialogTitle: title);
    if (dir == null) return const [];
    final directory = Directory(dir);
    if (!directory.existsSync()) return const [];
    final found = <String>[];
    try {
      await for (final entity in directory.list(recursive: recursive, followLinks: false)) {
        if (entity is File &&
            extOk(entity.path) &&
            (!useWildcard || matchesWildcard(entity.path, pat))) {
          found.add(entity.path);
        }
      }
    } catch (e) {
      _batchSnack('Could not scan folder: $e');
    }
    found.sort();
    if (found.isEmpty) {
      _batchSnack(
        useWildcard
            ? 'No recordings matching "$pat" were found${recursive ? ' (including subfolders)' : ''}.'
            : 'No recordings were found${recursive ? ' (including subfolders)' : ''}.',
      );
      return const [];
    }
    if (found.length == 1 || !mounted) return found;
    final selected = await showBatchFileSubSelectionDialog(
      context: context,
      title: 'Recordings found in ${_basename(dir)} (${found.length})',
      files: found,
    );
    return selected ?? const [];
  }

  /// Finds a scoring file for [eegPath]: `<stem><postfix>.json`,
  /// `<stem>_scoring.json`, `<stem>.json`, else the newest autoscoring output
  /// (`<stem>_<algorithm>_scoring.json`) beside the recording.
  String _findScoringForRecording(String eegPath, String postfix) {
    final file = File(eegPath);
    final dir = file.parent;
    var stem = _basename(eegPath);
    final dot = stem.lastIndexOf('.');
    if (dot > 0) stem = stem.substring(0, dot);
    final sep = Platform.pathSeparator;
    for (final name in [
      if (postfix.isNotEmpty) '$stem$postfix.json',
      '${stem}_scoring.json',
      '$stem.json',
    ]) {
      final candidate = '${dir.path}$sep$name';
      if (File(candidate).existsSync()) return candidate;
    }
    try {
      final autos = dir
          .listSync(followLinks: false)
          .whereType<File>()
          .where((f) {
            final name = _basename(f.path);
            return name.startsWith('${stem}_') && name.endsWith('_scoring.json');
          })
          .toList()
        ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      if (autos.isNotEmpty) return autos.first.path;
    } catch (_) {}
    return '';
  }

  void _addBatchAnalyseRecordings(List<String> files) {
    if (files.isEmpty) return;
    final postfix = _batchScoringPostfixController.text.trim();
    setState(() {
      for (final f in files) {
        if (_batchAnalysePairs.any((p) => p['eegPath'] == f)) continue;
        _batchAnalysePairs.add({
          'eegPath': f,
          'scoringPath': _batchAnalyseAutoLoadScorings
              ? _findScoringForRecording(f, postfix)
              : '',
        });
      }
    });
    _autoInspectBatchAnalyseChannels();
  }

  void _rematchBatchScorings() {
    final postfix = _batchScoringPostfixController.text.trim();
    setState(() {
      for (final pair in _batchAnalysePairs) {
        if ((pair['scoringPath'] ?? '').isEmpty) {
          pair['scoringPath'] = _findScoringForRecording(pair['eegPath'] ?? '', postfix);
        }
      }
    });
  }

  Widget _batchOptionCheckbox(String label, bool value, ValueChanged<bool> onChanged) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: value,
            visualDensity: VisualDensity.compact,
            onChanged: (v) => onChanged(v ?? false),
          ),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  /// Consistent file-selection controls for the AutoscoreNidra and
  /// AnalyseNidra batch panels.
  Widget _batchSourceControls({
    required VoidCallback onAddFiles,
    required VoidCallback onAddFolder,
    required bool hasItems,
    required VoidCallback onSelectDeselect,
    required VoidCallback onClear,
    required bool recursive,
    required ValueChanged<bool> onRecursive,
    required bool useWildcard,
    required ValueChanged<bool> onWildcard,
    required TextEditingController wildcardController,
    List<Widget> extraOptions = const [],
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.note_add, size: 16),
              label: const Text('Add Single Files…'),
              onPressed: onAddFiles,
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.create_new_folder, size: 16),
              label: const Text('Add from Folder…'),
              onPressed: onAddFolder,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.checklist, size: 16),
              label: const Text('Select / Deselect…'),
              onPressed: hasItems ? onSelectDeselect : null,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.clear_all, size: 16),
              label: const Text('Clear All'),
              onPressed: hasItems ? onClear : null,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 4,
          children: [
            _batchOptionCheckbox('Include subfolders', recursive, onRecursive),
            _batchOptionCheckbox('Use wildcard pattern', useWildcard, onWildcard),
            if (useWildcard)
              SizedBox(
                width: 210,
                child: TextField(
                  controller: wildcardController,
                  decoration: const InputDecoration(
                    labelText: 'Pattern',
                    hintText: 'e.g. *.edf, sub-*_eeg.edf, **/night1/*.edf',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
            ...extraOptions,
          ],
        ),
      ],
    );
  }

  /// Opens the channel list of the first batch recording and writes the
  /// selection into [controller].
  Future<void> _pickBatchChannelsInto({
    required TextEditingController controller,
    required String? firstFile,
    required String title,
  }) async {
    if (firstFile == null || firstFile.isEmpty) {
      _batchSnack('Add recordings first: channels are listed from the first file in the batch.');
      return;
    }
    final available = await extractRecordingChannels(firstFile);
    if (available.isEmpty) {
      _batchSnack('Could not read channel labels from ${_basename(firstFile)}. You can type channels manually.');
      return;
    }
    if (!mounted) return;
    final selected = await showChannelSelectionDialog(
      context: context,
      title: title,
      recordingPath: firstFile,
      availableChannels: available,
      initialSelectedChannels: _parseChannelList(controller.text),
    );
    if (selected != null && mounted) {
      setState(() => controller.text = selected.join(','));
    }
  }

  Widget _batchChannelPickerButton(
    TextEditingController controller,
    String? firstFile,
    String title,
  ) {
    return IconButton(
      icon: const Icon(Icons.playlist_add_check),
      tooltip: 'Choose from the channel list of the first recording…',
      onPressed: () => _pickBatchChannelsInto(
        controller: controller,
        firstFile: firstFile,
        title: title,
      ),
    );
  }

  Future<void> _openBatchAutoscoreChannelSelector() async {
    if (_batchStagingFiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please add recording files first to extract channels from the 1st recording.'),
        ),
      );
      return;
    }
    final firstFile = _batchStagingFiles.first;
    final available = await extractRecordingChannels(firstFile);
    if (available.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not extract channels from ${_basename(firstFile)}. You can type channels manually.'),
          ),
        );
      }
      return;
    }
    final currentSelected = _batchStagingEegController.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (!mounted) return;
    final selected = await showChannelSelectionDialog(
      context: context,
      title: 'Select EEG Channels for AutoscoreNidra',
      recordingPath: firstFile,
      availableChannels: available,
      initialSelectedChannels: currentSelected,
    );
    if (selected != null && mounted) {
      setState(() {
        _batchStagingEegController.text = selected.join(',');
      });
    }
  }

  void _runAnalyseNidraJobs(
    List<_AnalyseNidraJob> jobs,
    List<String> channels,
    List<String> references, {
    String? outputDir,
    bool perChannel = false,
    String? regionMapJson,
    AnalyseNidraOptions? options,
    bool skipExisting = false,
    bool autoCollate = false,
  }) {
    final analyseOptions = options ?? AnalyseNidraOptions();
    // Validate that all scoring files exist before starting
    for (final job in jobs) {
      final scFile = File(job.mappedScoringPath);
      if (!scFile.existsSync()) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.error_outline, color: Colors.red),
                SizedBox(width: 8),
                Text('Scoring File Missing'),
              ],
            ),
            content: Text(
              'Cannot run AnalyseNidra on ${_basename(job.edfPath)}:\n\n'
              'Scoring file not found:\n${job.mappedScoringPath}\n\n'
              'Please perform scoring first or ensure the correct scoring JSON is paired.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        return;
      }
    }

    final executable = detectAnalyseNidraExecutable();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CommandBatchProgressDialog(
        title: 'AnalyseNidra',
        jobs: [
          for (final job in jobs)
            _CommandJob(
              label: _basename(job.edfPath),
              executable: executable,
              sourcePath: job.edfPath,
              outputDir: outputDir,
              arguments: _analyseNidraArguments(
                job,
                channels,
                references,
                lightsOffSeconds: jobs.length == 1 && job.edfPath == _activePath
                    ? _config.lightsOffSeconds
                    : null,
                lightsOnSeconds: jobs.length == 1 && job.edfPath == _activePath
                    ? _config.lightsOnSeconds
                    : null,
                outputDir: outputDir,
                perChannel: perChannel,
                regionMapJson: regionMapJson,
                options: analyseOptions,
                skipExisting: skipExisting,
              ),
            ),
        ],
        onFinished: (failed) {
          final active = _activePath;
          if (analyseOptions.runsNlg &&
              active != null &&
              jobs.any((job) => job.edfPath == active)) {
            unawaited(
              loadNlgOverlay(active, outputDir: outputDir).then((data) {
                if (!mounted || data == null || _activePath != active) return;
                setState(() => _nlgOverlay = data);
                _setHypnogramOverlayMode('NeuroLoopGain');
              }),
            );
          }
          final existingRegionalFiles = <String>[];
          for (final job in jobs) {
            final csvPath = (outputDir != null && outputDir.trim().isNotEmpty)
                ? '${outputDir.trim()}${Platform.pathSeparator}${_basename(job.edfPath).replaceAll(RegExp(r'\.[^.]+$'), '')}_analyse_regional.csv'
                : '${_sidecarPath(job.edfPath, '')}_analyse_regional.csv';
            if (File(csvPath).existsSync()) {
              existingRegionalFiles.add(csvPath);
            }
          }
          setState(() {
            _lastAnalyseRegionalFiles = existingRegionalFiles;
          });
          _setStatus(
            failed == 0
                ? 'AnalyseNidra completed for ${jobs.length} recording(s)'
                : 'AnalyseNidra finished: ${jobs.length - failed} completed, $failed failed (${existingRegionalFiles.length} output CSVs available)',
          );
          if (autoCollate && existingRegionalFiles.isNotEmpty) {
            final targetDir = (outputDir != null && outputDir.trim().isNotEmpty)
                ? outputDir.trim()
                : File(jobs.first.edfPath).parent.path;
            final masterCsvPath = '$targetDir${Platform.pathSeparator}AnalyseNidra_master_sheet.csv';
            unawaited(() async {
              try {
                final compiled = await compileRegionalCsvFiles(existingRegionalFiles);
                await File(masterCsvPath).writeAsString(compiled);
                if (mounted) {
                  _setStatus(
                    'Auto-compiled ${existingRegionalFiles.length} regional CSV(s) into ${_basename(masterCsvPath)}',
                  );
                }
              } catch (e) {
                if (mounted) {
                  _setStatus('Auto-collation failed: $e');
                }
              }
            }());
          }
        },
      ),
    );
  }

  void _showTextDialog(String title, String text) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SelectableText(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _compileAnalyseNidraMasterSheet([
    List<String>? knownPaths,
  ]) async {
    var paths =
        knownPaths?.where((path) => File(path).existsSync()).toList() ?? [];
    if (paths.isEmpty) {
      final result = await FilePicker.pickFiles(
        dialogTitle: 'Select AnalyseNidra regional CSV files',
        type: FileType.custom,
        allowedExtensions: ['csv'],
        allowMultiple: true,
      );
      paths =
          result?.files.map((file) => file.path).whereType<String>().toList() ??
          [];
    }
    if (paths.isEmpty) return;

    final output = await FilePicker.saveFile(
      dialogTitle: 'Save AnalyseNidra master sheet',
      fileName: 'AnalyseNidra_master_sheet.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (output == null) return;
    final outputPath = output.toLowerCase().endsWith('.csv')
        ? output
        : '$output.csv';
    try {
      final compiled = await compileRegionalCsvFiles(paths);
      await File(outputPath).writeAsString(compiled);
      _setStatus(
        'Compiled ${paths.length} AnalyseNidra CSV files into ${_basename(outputPath)}',
      );
      await _openFile(outputPath);
    } catch (error) {
      _showTextDialog('Master sheet compilation failed', error.toString());
    }
  }

  Future<void> _generateBatchPdfReports() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Select AnalyseNidra Master Chart CSV',
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    final masterCsvPath = result?.files.single.path;
    if (masterCsvPath == null) return;

    final csvContent = await File(masterCsvPath).readAsString();
    final rows = parseCsvTable(csvContent);
    if (rows.isEmpty) {
      _showTextDialog('Error', 'The selected CSV file is empty or invalid.');
      return;
    }

    // Validate headers
    final firstRow = rows.first;
    if (!firstRow.containsKey('source_path') ||
        !firstRow.containsKey('source_file')) {
      _showTextDialog(
        'Error',
        'CSV must contain "source_path" and "source_file" columns.',
      );
      return;
    }

    final includePages = await _showPageSelectionDialog();
    if (includePages == null) return;

    // Group rows by unique source_path
    final Map<String, List<Map<String, String>>> groupedRows = {};
    for (final row in rows) {
      final path = row['source_path'] ?? '';
      if (path.isEmpty) continue;
      groupedRows.putIfAbsent(path, () => []).add(row);
    }

    final masterDir = Directory(masterCsvPath).parent.path;
    final List<_PdfBatchJob> jobs = [];

    for (final entry in groupedRows.entries) {
      final origPath = entry.key;
      final group = entry.value;
      final first = group.first;

      final filename = first['source_file'] ?? _basename(origPath);
      var edfPath = resolveRegionalCsvEdfPath(
        origPath,
        masterDirectory: masterDir,
        sourceFile: filename,
      );
      if (!File(edfPath).existsSync()) {
        final fallbackPath = '$masterDir${Platform.pathSeparator}$filename';
        if (File(fallbackPath).existsSync()) {
          edfPath = fallbackPath;
        }
      }

      jobs.add(
        _PdfBatchJob(
          sourcePath: edfPath,
          sourceFile: filename,
          subjectId: first['Subject Identifier'] ?? '',
          subjectDetails: first['Subject Details'] ?? '',
          recordingDate: first['Recording Date'] ?? '',
          regionalRows: group,
        ),
      );
    }

    if (jobs.isEmpty) {
      _showTextDialog('Error', 'No valid jobs found in the master chart.');
      return;
    }

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return _BatchPdfProgressDialog(
          jobs: jobs,
          includePages: includePages,
          onFinished: (completed, failed) {
            _setStatus(
              'Batch PDF generation complete: $completed success, $failed fail',
            );
          },
        );
      },
    );
  }

  void _executeBatchAutoScoring(
    List<String> files,
    Map<String, dynamic> settings,
  ) {
    final algorithm = settings['algorithm'] as String;
    final correction = settings['sequence_correction'] as String;
    final alpha = (settings['sleepgpt_alpha'] as num?)?.toDouble() ?? 0.1;
    final ngram = (settings['sleepgpt_ngram'] as num?)?.toInt() ?? 30;
    final outputDir = settings['output_dir'] as String?;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return BatchProgressDialog(
          files: files,
          algorithm: algorithm,
          correction: correction,
          sleepgptAlpha: alpha,
          sleepgptNgram: ngram,
          eegChannels: List<String>.from(settings['eeg'] as List? ?? const []),
          refChannels: List<String>.from(settings['ref'] as List? ?? const []),
          eogChannels: List<String>.from(settings['eog'] as List? ?? const []),
          emgChannels: List<String>.from(settings['emg'] as List? ?? const []),
          outputDir: outputDir,
          onFinished: () {
            _setStatus('Batch AutoscoreNidra finished');
            // If the active file was one of the scored files, reload it
            final active = _activePath;
            if (active != null && files.contains(active)) {
              _openRecordingPath(
                active,
                kind: active.split('.').last.toLowerCase(),
              );
            }
          },
        );
      },
    );
  }

  Future<void> _openPreprocessDialog({bool stimArtifactOnly = false}) async {
    String? targetPath = _activePath;
    List<String> chans = [];
    if (targetPath == null || !File(targetPath).existsSync()) {
      final res = await FilePicker.pickFiles(
        dialogTitle: stimArtifactOnly
            ? 'Select EEG File for Auto Electric Stim Artefact Removal (DBS)'
            : 'Select EEG File for Preprocessing',
        type: FileType.custom,
        allowedExtensions: ['edf', 'EDF', 'bdf', 'fif', 'set'],
      );
      if (res != null && res.files.single.path != null) {
        targetPath = res.files.single.path;
      } else {
        return;
      }
    } else {
      final eeg = _loadedEeg;
      if (eeg != null) {
        chans = eeg.channelLabels;
      }
    }

    if (!mounted || targetPath == null) return;

    showDialog(
      context: context,
      builder: (ctx) => PreprocessDialog(
        inputFilePath: targetPath!,
        initialChannels: chans,
        initialStimArtifactOnly: stimArtifactOnly,
        onCompleted: (cleanedPath) {
          _setStatus(
            stimArtifactOnly
                ? 'DBS stim artefact removal completed: ${_basename(cleanedPath)}'
                : 'Preprocessing completed: ${_basename(cleanedPath)}',
          );
          // Offer to open the cleaned file
          showDialog(
            context: context,
            builder: (ctx2) => AlertDialog(
              title: const Text('Preprocessing Complete'),
              content: Text(
                'Cleaned EEG saved to:\n$cleanedPath\n\n'
                'Would you like to open this cleaned recording now?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx2).pop(),
                  child: const Text('No'),
                ),
                ElevatedButton(
                  onPressed: () {
                    Navigator.of(ctx2).pop();
                    _openRecordingPath(
                      cleanedPath,
                      kind: cleanedPath.split('.').last.toLowerCase(),
                    );
                  },
                  child: const Text('Open Cleaned Recording'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _openStimArtifactRemovalDialog() => _openPreprocessDialog(stimArtifactOnly: true);

  void _openFeatureSelectionAndConfigDialog() {
    _openConfigDialog(initialTabIndex: 8);
  }

  Future<void> _checkForUpdates() async {
    _setStatus('Checking for updates…');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 16),
                Text('Checking for latest updates…'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final info = await UpdateChecker.checkForUpdates();
      if (!mounted) return;
      Navigator.of(context).pop(); // dismiss loading dialog

      showDialog(
        context: context,
        builder: (ctx) => AppUpdateDialog(info: info),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(); // dismiss loading dialog
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.warning, color: Colors.orange),
              SizedBox(width: 8),
              Text('Update Check Failed'),
            ],
          ),
          content: Text(
            'Could not check for updates:\n$e\n\n'
            'Please check your internet connection or check the GitHub releases page directly.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _saveScoring() async {
    final v = _viewport;
    if (v == null) {
      _setStatus('Nothing to save');
      return;
    }
    await exportScoringDialog(
      v.stages,
      v.epochSeconds,
      _activePath,
      events: v.scoredEvents,
      stagesUncertain: v.stagesUncertain,
      stagesConfidence: v.stagesConfidence,
      stageProbabilities: v.stageProbabilities,
      onStatus: _setStatus,
    );
  }

  Future<void> _loadComparisonScoring() async {
    final v = _viewport;
    if (v == null) {
      _setStatus('Load an EDF first');
      return;
    }
    final result = await importScoringDialog(
      v.epochCount,
      'any',
      onStatus: _setStatus,
    );
    if (result != null) {
      setState(() {
        _comparisonStages = result.stages;
        _status =
            'Loaded ${result.sourceFormat} comparison — '
            '${_disagreementCount(v.stages, result.stages)} disagreements';
      });
    }
  }

  void _removeComparisonScoring() {
    setState(() {
      _comparisonStages = null;
      _status = 'Comparison scoring removed';
    });
  }

  void _showComparisonStats() {
    final v = _viewport;
    final comparison = _comparisonStages;
    if (v == null || comparison == null) {
      _setStatus('No comparison scoring loaded');
      return;
    }
    final metrics = _StageComparisonMetrics.compute(v.stages, comparison);
    showDialog(
      context: context,
      builder: (context) => _ComparisonReportCardDialog(metrics: metrics),
    );
  }

  Future<void> _showMultiScoringComparison() async {
    final v = _viewport;
    if (v == null || _activePath == null) {
      _setStatus('Load a recording first');
      return;
    }
    _setStatus('Collecting scorings for ${_basename(_activePath!)}…');
    await showMultiScoringCompareDialog(
      context,
      recordingPath: _activePath,
      epochCount: v.epochCount,
      currentStages: v.stages,
      epochSeconds: v.epochSeconds,
    );
  }

  Future<void> _addComparisonPairManually() async {
    final resultA = await FilePicker.pickFiles(
      dialogTitle: 'Select Reference Scoring File (File 1)',
    );
    if (resultA == null || resultA.files.single.path == null) return;

    final resultB = await FilePicker.pickFiles(
      dialogTitle: 'Select Comparison Scoring File (File 2)',
    );
    if (resultB == null || resultB.files.single.path == null) return;

    setState(() {
      _batchComparisonPairs.add({
        'fileA': resultA.files.single.path!,
        'fileB': resultB.files.single.path!,
      });
    });
  }

  Future<void> _autoPairComparisonFolders() async {
    final dirA = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select Folder 1 (Reference Scoring files)',
    );
    if (dirA == null) return;

    final dirB = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select Folder 2 (Comparison Scoring files)',
    );
    if (dirB == null) return;

    bool isScoringFile(File f) {
      final name = f.uri.pathSegments.last.toLowerCase();
      if (name.startsWith('.') || name.contains('_config.json')) return false;
      return name.endsWith('.json') ||
          name.endsWith('.txt') ||
          name.endsWith('.csv') ||
          name.endsWith('.vis') ||
          name.endsWith('.annot') ||
          name.endsWith('.edf');
    }

    final filesA = Directory(dirA).listSync().whereType<File>().where(isScoringFile).toList();
    final filesB = Directory(dirB).listSync().whereType<File>().toList().where(isScoringFile).toList();

    String cleanStem(String path) {
      String stem = File(path).uri.pathSegments.last.replaceAll(RegExp(r'\.[^.]+$'), '');
      stem = stem.replaceAll(RegExp(r'(_scoring|_manual|_auto|_yasa|_sleeptrip|_vis|_hypnogram)$', caseSensitive: false), '');
      return stem.trim().toLowerCase();
    }

    int added = 0;
    for (final fa in filesA) {
      final stemA = cleanStem(fa.path);
      for (final fb in filesB) {
        final stemB = cleanStem(fb.path);
        if (stemA == stemB || stemA.contains(stemB) || stemB.contains(stemA)) {
          _batchComparisonPairs.add({
            'fileA': fa.path,
            'fileB': fb.path,
          });
          added++;
          break;
        }
      }
    }

    setState(() {});
    _setStatus('Auto-paired $added file(s) between Folder 1 and Folder 2');
  }

  Future<void> _executeBatchScoringComparison() async {
    if (_batchComparisonPairs.isEmpty) {
      _setStatus('No comparison pairs added');
      return;
    }

    final savePath = await FilePicker.saveFile(
      dialogTitle: 'Save Batch Scoring Comparison Master CSV',
      fileName: 'Batch_Scoring_Comparison_Master.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (savePath == null) return;

    _setStatus('Running batch scoring comparison for ${_batchComparisonPairs.length} pair(s)…');

    final csvRows = <String>[];
    csvRows.add(
      'Reference_File,Comparison_File,Total_Epochs,Matched_Epochs,'
      'Overall_Agreement_Pct,Cohens_Kappa,Kappa_Strength,'
      'Wake_F1,N1_F1,N2_F1,N3_F1,REM_F1,'
      'Wake_Sensitivity,N1_Sensitivity,N2_Sensitivity,N3_Sensitivity,REM_Sensitivity',
    );

    int count = 0;
    for (final pair in _batchComparisonPairs) {
      final fileA = pair['fileA'];
      final fileB = pair['fileB'];
      if (fileA == null || fileB == null || fileA.isEmpty || fileB.isEmpty) continue;

      try {
        final resA = await loadScoringFile(fileA);
        final resB = await loadScoringFile(fileB);
        if (resA == null || resB == null || resA.stages.isEmpty || resB.stages.isEmpty) {
          debugPrint('Could not load stages for $fileA vs $fileB (resA: ${resA?.stages.length}, resB: ${resB?.stages.length})');
          continue;
        }

        final metrics = _StageComparisonMetrics.compute(resA.stages, resB.stages);
        final f1 = metrics.f1Score;
        final sens = metrics.recall;

        final baseA = File(fileA).uri.pathSegments.last;
        final baseB = File(fileB).uri.pathSegments.last;

        csvRows.add(
          '$baseA,$baseB,${metrics.totalEpochs},${metrics.comparedEpochs},'
          '${metrics.overallAgreement.toStringAsFixed(2)},${metrics.cohensKappa.toStringAsFixed(4)},${metrics.kappaStrength},'
          '${(f1[SleepStage.wake] ?? 0).toStringAsFixed(3)},${(f1[SleepStage.n1] ?? 0).toStringAsFixed(3)},'
          '${(f1[SleepStage.n2] ?? 0).toStringAsFixed(3)},${(f1[SleepStage.n3] ?? 0).toStringAsFixed(3)},'
          '${(f1[SleepStage.rem] ?? 0).toStringAsFixed(3)},'
          '${(sens[SleepStage.wake] ?? 0).toStringAsFixed(3)},${(sens[SleepStage.n1] ?? 0).toStringAsFixed(3)},'
          '${(sens[SleepStage.n2] ?? 0).toStringAsFixed(3)},${(sens[SleepStage.n3] ?? 0).toStringAsFixed(3)},'
          '${(sens[SleepStage.rem] ?? 0).toStringAsFixed(3)}',
        );
        count++;
      } catch (e) {
        debugPrint('Error comparing $fileA vs $fileB: $e');
      }
    }

    final csvFile = File(savePath);
    await csvFile.writeAsString(csvRows.join('\n'));

    _setStatus('Batch comparison complete: $count pair(s) processed. Master CSV saved to ${csvFile.uri.pathSegments.last}');
  }

  void _showSelectionHelp() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Signal selection box'),
        content: const Text(
          'Drag on the signal panel to draw one or more selection boxes. '
          'The total duration is shown in the upper right of the signal view. '
          'Press A for Artifact or F1-F12 for Event 1-12 to convert the drawn boxes into events. '
          'Press Backspace to erase existing events inside drawn boxes. '
          'Press Q to toggle uncertainty for the current epoch.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showDownloadStats() {
    showDialog(
      context: context,
      builder: (context) => const _DownloadStatsDialog(),
    );
  }

  Future<void> _loadSleeptripEvents() async {
    final v = _viewport;
    if (v == null) {
      _setStatus('Load an EDF first');
      return;
    }
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Load Sleeptrip Events (_events.csv)',
      type: FileType.custom,
      allowedExtensions: ['csv', 'tsv', 'txt'],
    );
    final path = result?.files.single.path;
    if (path == null) {
      _setStatus('Event import cancelled');
      return;
    }
    try {
      final lines = await File(path).readAsLines();
      if (lines.isEmpty) throw const FormatException('Empty events file');
      final delimiter = lines.first.contains('\t') ? '\t' : ',';
      final header = lines.first
          .split(delimiter)
          .map((h) => h.trim().toLowerCase())
          .toList();
      final eventCol = header.indexOf('event');
      final startCol = header.indexOf('start');
      final stopCol = header.contains('stop')
          ? header.indexOf('stop')
          : header.indexOf('end');
      if (eventCol < 0 || startCol < 0 || stopCol < 0) {
        throw const FormatException(
          'Expected event, start, and stop/end columns',
        );
      }
      final labelToDigit = <String, int>{};
      final imported = <ScoredEvent>[];
      for (final line in lines.skip(1)) {
        if (line.trim().isEmpty) continue;
        final cols = line.split(delimiter);
        if (cols.length <= stopCol ||
            cols.length <= eventCol ||
            cols.length <= startCol) {
          continue;
        }
        final label = cols[eventCol].trim();
        final start = double.tryParse(cols[startCol].trim());
        final stop = double.tryParse(cols[stopCol].trim());
        if (label.isEmpty || start == null || stop == null || stop <= start) {
          continue;
        }
        final digit = labelToDigit.putIfAbsent(
          label,
          () => (labelToDigit.length + 1).clamp(1, 12).toInt(),
        );
        imported.add(
          ScoredEvent(
            digit: digit,
            key: 'F$digit',
            label: label,
            startSec: start,
            endSec: stop,
          ),
        );
      }
      setState(() {
        _viewport = v.copyWith(
          scoredEvents: _mergeScoredEvents([...v.scoredEvents, ...imported]),
        );
        _status = 'Imported ${imported.length} Sleeptrip events';
      });
    } catch (e) {
      _setStatus('Failed to import Sleeptrip events: $e');
    }
  }

  Future<void> _runKComplexDetection() async {
    final eeg = _loadedEeg;
    final v = _viewport;
    if (eeg == null || v == null) {
      _setStatus('Load an EDF first');
      return;
    }

    final hasStages = v.stages.any((s) => s.isScored);

    showDialog(
      context: context,
      builder: (_) => MtKcdDialog(
        channelLabels: eeg.channelLabels,
        hasStages: hasStages,
        onRun: (settings) async {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => const AlertDialog(
              content: Row(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 20),
                  Text('Running MT-KCD K-Complex detection…'),
                ],
              ),
            ),
          );

          try {
            final chIdx = eeg.channelLabels.indexOf(settings['channel']);
            if (chIdx < 0) throw Exception('Channel not found');
            final signal = eeg.channelSamples[chIdx];
            final sfreq = eeg.sampleRateHz;

            final amin = settings['amin'] as double;
            final dmax_s = settings['dmax_s'] as double;
            final q = settings['q'] as double;
            final fmax = settings['fmax'] as double;

            final events = await _runKComplexIsolate(
              signal,
              sfreq,
              amin,
              dmax_s,
              q,
              fmax,
            );

            if (mounted) Navigator.of(context).pop();

            final filterStages = settings['filter_stages'] as List<String>?;
            var finalEvents = events;
            if (filterStages != null && filterStages.isNotEmpty) {
              final stageSet = filterStages.toSet();
              finalEvents = events.where((event) {
                final mid = (event.$1 + event.$2) / 2.0;
                final epochIdx = (mid / v.epochSeconds).floor();
                if (epochIdx >= 0 && epochIdx < v.stages.length) {
                  return stageSet.contains(v.stages[epochIdx].label);
                }
                return false;
              }).toList();
            }

            final markerLabel = settings['marker'] as String;
            final digit = markerLabel == 'Artifact'
                ? 0
                : int.parse(markerLabel.substring(1));
            final label = digit == 0 ? 'Artifact' : 'MT-KCD';
            final key = digit == 0 ? 'A' : 'F$digit';

            final scoredEvents = <ScoredEvent>[...v.scoredEvents];
            for (final ev in finalEvents) {
              scoredEvents.add(
                ScoredEvent(
                  digit: digit,
                  key: key,
                  label: label,
                  type: 'MT-KCD',
                  channel: settings['channel'] as String?,
                  startSec: ev.$1,
                  endSec: ev.$2,
                ),
              );
            }

            final merged = _mergeScoredEvents(scoredEvents);

            if (mounted) {
              setState(() {
                _viewport = v.copyWith(
                  scoredEvents: merged,
                  clearEventSelections: true,
                );
                _status =
                    'MT-KCD completed: detected ${finalEvents.length} K-complex(s)';
              });

              autoSaveScoring(
                _activePath,
                _viewport!.stages,
                _viewport!.epochSeconds,
                events: _viewport!.scoredEvents,
                stagesUncertain: _viewport!.stagesUncertain,
                stagesConfidence: _viewport!.stagesConfidence,
                stageProbabilities: _viewport!.stageProbabilities,
              );
            }
          } catch (e) {
            if (mounted) {
              Navigator.of(context).pop();
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('MT-KCD Error'),
                  content: Text(
                    'An error occurred during K-complex detection:\n\n$e',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              );
            }
          }
        },
      ),
    );
  }

  void _openEdfUtilitiesDialog() {
    showDialog(
      context: context,
      builder: (_) => EdfUtilitiesDialog(
        initialEdfPath: _activePath,
        availableChannels: _viewport?.channelLabels ?? const [],
      ),
    );
  }

  Future<void> _runSpindleDetection() async {
    final eeg = _loadedEeg;
    final v = _viewport;
    if (eeg == null || v == null) {
      _setStatus('Load an EDF first');
      return;
    }

    final hasStages = v.stages.any((s) => s.isScored);

    showDialog(
      context: context,
      builder: (_) => MtSpindleDialog(
        channelLabels: eeg.channelLabels,
        hasStages: hasStages,
        onRun: (settings) async {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => const AlertDialog(
              content: Row(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 20),
                  Text('Running MT-Spindle spindle detection…'),
                ],
              ),
            ),
          );

          try {
            final chIdx = eeg.channelLabels.indexOf(settings['channel']);
            if (chIdx < 0) throw Exception('Channel not found');
            final signal = eeg.channelSamples[chIdx];
            final sfreq = eeg.sampleRateHz;

            final fmin = settings['fmin'] as double;
            final fmax = settings['fmax'] as double;
            final amin = settings['amin'] as double;
            final dmin_s = settings['dmin_s'] as double;
            final dmax_s = settings['dmax_s'] as double;
            final q = settings['q'] as double;

            final events = await _runSpindleIsolate(
              signal,
              sfreq,
              fmin,
              fmax,
              amin,
              dmin_s,
              dmax_s,
              q,
            );

            if (mounted) Navigator.of(context).pop();

            final filterStages = settings['filter_stages'] as List<String>?;
            var finalEvents = events;
            if (filterStages != null && filterStages.isNotEmpty) {
              final stageSet = filterStages.toSet();
              finalEvents = events.where((event) {
                final mid = (event.$1 + event.$2) / 2.0;
                final epochIdx = (mid / v.epochSeconds).floor();
                if (epochIdx >= 0 && epochIdx < v.stages.length) {
                  return stageSet.contains(v.stages[epochIdx].label);
                }
                return false;
              }).toList();
            }

            final markerLabel = settings['marker'] as String;
            final digit = markerLabel == 'Artifact'
                ? 0
                : int.parse(markerLabel.substring(1));
            final label = digit == 0 ? 'Artifact' : 'MT-Spindle';
            final key = digit == 0 ? 'A' : 'F$digit';

            final scoredEvents = <ScoredEvent>[...v.scoredEvents];
            for (final ev in finalEvents) {
              scoredEvents.add(
                ScoredEvent(
                  digit: digit,
                  key: key,
                  label: label,
                  type: 'MT-Spindle',
                  channel: settings['channel'] as String?,
                  startSec: ev.$1,
                  endSec: ev.$2,
                ),
              );
            }

            final merged = _mergeScoredEvents(scoredEvents);

            if (mounted) {
              setState(() {
                _viewport = v.copyWith(
                  scoredEvents: merged,
                  clearEventSelections: true,
                );
                _status =
                    'MT-Spindle completed: detected ${finalEvents.length} spindle(s)';
              });

              autoSaveScoring(
                _activePath,
                _viewport!.stages,
                _viewport!.epochSeconds,
                events: _viewport!.scoredEvents,
                stagesUncertain: _viewport!.stagesUncertain,
                stagesConfidence: _viewport!.stagesConfidence,
                stageProbabilities: _viewport!.stageProbabilities,
              );
            }
          } catch (e) {
            if (mounted) {
              Navigator.of(context).pop();
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('MT-Spindle Error'),
                  content: Text(
                    'An error occurred during spindle detection:\n\n$e',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              );
            }
          }
        },
      ),
    );
  }

  void _runAnalyseNidraDetection() {
    final eeg = _loadedEeg;
    final v = _viewport;
    final path = _activePath;
    if (eeg == null || v == null || path == null) {
      _setStatus('Load an EEG recording first');
      return;
    }

    final hasStages = v.stages.any((s) => s.isScored);

    showDialog(
      context: context,
      builder: (_) => AnalyseNidraDetectionDialog(
        channelLabels: _config.channels.isNotEmpty
            ? _config.channels.map((c) => c.name).toList()
            : eeg.channelLabels,
        hasStages: hasStages,
        onRun: (settings) async {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => const AlertDialog(
              content: Row(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(width: 20),
                  Text('Running AnalyseNidra Spindle & Slow-Wave detection…'),
                ],
              ),
            ),
          );

          try {
            await autoSaveScoring(
              path,
              v.stages,
              v.epochSeconds,
              events: v.scoredEvents,
              stagesUncertain: v.stagesUncertain,
              stagesConfidence: v.stagesConfidence,
              stageProbabilities: v.stageProbabilities,
            );
            final scoringPath = _analyseNidraScoringPath(path);

            final executable = detectAnalyseNidraExecutable();
            final channels = List<String>.from(settings['channels'] as List);
            final references = List<String>.from(settings['references'] as List);
            final detectSpindles = settings['detectSpindles'] as bool;
            final detectSlowWaves = settings['detectSlowWaves'] as bool;

            final job = _AnalyseNidraJob(
              edfPath: path,
              scoringPath: scoringPath,
              mappedScoringPath: scoringPath,
            );
            final args = _analyseNidraArguments(
              job,
              channels,
              references,
              lightsOffSeconds: _config.lightsOffSeconds,
              lightsOnSeconds: _config.lightsOnSeconds,
              // Only the requested detectors; keep the regional CSV intact.
              options: AnalyseNidraOptions(
                analyses: {
                  if (detectSpindles) 'spindles',
                  if (detectSlowWaves) 'slow_waves',
                },
              ),
              writeRegional: false,
            );

            final result = await Process.run(executable, args);

            if (mounted) Navigator.of(context).pop();

            if (result.exitCode != 0) {
              final err = result.stderr.toString();
              throw Exception(
                err.isNotEmpty
                    ? err
                    : 'AnalyseNidra exited with code ${result.exitCode}',
              );
            }

            final newEvents = <ScoredEvent>[];
            if (detectSpindles) {
              final spindles = await loadAnalyseNidraSpindles(path);
              newEvents.addAll(spindles);
            }
            if (detectSlowWaves) {
              final slowWaves = await loadAnalyseNidraSlowWaves(path);
              newEvents.addAll(slowWaves);
            }

            final merged = _mergeScoredEvents([...v.scoredEvents, ...newEvents]);

            if (mounted) {
              setState(() {
                _viewport = v.copyWith(
                  scoredEvents: merged,
                  clearEventSelections: true,
                );
                _status =
                    'AnalyseNidra detection completed: found ${newEvents.length} event(s)';
              });

              autoSaveScoring(
                path,
                _viewport!.stages,
                _viewport!.epochSeconds,
                events: _viewport!.scoredEvents,
                stagesUncertain: _viewport!.stagesUncertain,
                stagesConfidence: _viewport!.stagesConfidence,
                stageProbabilities: _viewport!.stageProbabilities,
              );
            }
          } catch (e) {
            if (mounted) {
              Navigator.of(context).pop();
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('AnalyseNidra Detection Error'),
                  content: Text(
                    'An error occurred during AnalyseNidra detection:\n\n$e',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              );
            }
          }
        },
      ),
    );
  }

  // ─── Respiratory (OSA) & PLM analysis ────────────────────────────────────

  /// Returns an EDF the native engine can read for [path] (converting other
  /// formats to a temporary EDF) plus the temp folder to delete afterwards.
  Future<(String, Directory?)> _nativeEdfFor(String path) async {
    if (analyseNidraReadsNatively(path)) return (path, null);
    final tempDir = await Directory.systemTemp.createTemp('ccs_psg_');
    var stem = _basename(path);
    final dot = stem.lastIndexOf('.');
    if (dot > 0) stem = stem.substring(0, dot);
    final edf = '${tempDir.path}${Platform.pathSeparator}$stem.edf';
    await processEdfFile(path, edf, EdfTransformOptions());
    return (edf, tempDir);
  }

  Future<String?> _saveScoringForPsg(String path, EegViewport v) async {
    await autoSaveScoring(
      path,
      v.stages,
      v.epochSeconds,
      events: v.scoredEvents,
      stagesUncertain: v.stagesUncertain,
      stagesConfidence: v.stagesConfidence,
      stageProbabilities: v.stageProbabilities,
    );
    final scoringPath = _analyseNidraScoringPath(path);
    return File(scoringPath).existsSync() ? scoringPath : null;
  }

  void _replacePsgEvents(
    bool Function(int digit) isOld,
    List<ScoredEvent> fresh,
    String status,
  ) {
    final v = _viewport;
    if (v == null) return;
    final kept = v.scoredEvents.where((e) => !isOld(e.digit)).toList();
    final merged = [...kept, ...fresh]
      ..sort((a, b) => a.startSec.compareTo(b.startSec));
    setState(() {
      _viewport = v.copyWith(scoredEvents: merged, clearEventSelections: true);
      _status = status;
    });
    autoSaveScoring(
      _activePath,
      _viewport!.stages,
      _viewport!.epochSeconds,
      events: _viewport!.scoredEvents,
      stagesUncertain: _viewport!.stagesUncertain,
      stagesConfidence: _viewport!.stagesConfidence,
      stageProbabilities: _viewport!.stageProbabilities,
    );
  }

  Future<void> _runRespiratoryAnalysis() async {
    final v = _viewport;
    final path = _activePath;
    if (v == null || path == null) {
      _setStatus('Load a PSG recording first');
      return;
    }
    if (!isAnalyseNidraAvailable()) {
      _showTextDialog(
        'Respiratory analysis unavailable',
        'The native analyse-nidra engine was not found beside the application.',
      );
      return;
    }
    final executable = detectAnalyseNidraExecutable();
    Directory? tempDir;
    try {
      _setStatus('Reading PSG channels…');
      final (edf, tmp) = await _nativeEdfFor(path);
      tempDir = tmp;
      final signals = await listPsgSignals(executable, edf);
      if (!mounted) return;
      final hasManualArousals = v.scoredEvents.any(
        (e) => e.label.toLowerCase().contains('arous'),
      );
      final settings = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => RespiratoryAnalysisDialog(
          signals: signals,
          hasHypnogram: v.stages.any((s) => s.isScored),
          hasManualArousals: hasManualArousals,
        ),
      );
      if (settings == null || !mounted) {
        _setStatus('Respiratory analysis cancelled');
        return;
      }
      final scoringPath = await _saveScoringForPsg(path, v);
      final outPath = respiratoryReportPath(path);
      final args = buildRespiratoryArgs(
        edfPath: edf,
        settings: settings,
        scoringPath: scoringPath,
        lightsOffSeconds: _config.lightsOffSeconds,
        lightsOnSeconds: _config.lightsOnSeconds,
        outPath: outPath,
      );
      if (!mounted) return;
      final (exitCode, logs) = await runAnalyseNidraWithProgress(
        context: context,
        title: 'Respiratory / OSA Analysis',
        executable: executable,
        arguments: args,
      );
      final report = exitCode == 0 ? await loadPsgReport(outPath) : null;
      if (report == null) {
        _setStatus('Respiratory analysis failed');
        _showTextDialog(
          'Respiratory analysis failed',
          'analyse-nidra returned exit code $exitCode.\n\n${logs.join('\n')}',
        );
        return;
      }
      final events = respiratoryEventsFromReport(report);
      final ahi = (report['summary'] as Map?)?['AHI'];
      _replacePsgEvents(
        isRespiratoryEventDigit,
        events,
        'Respiratory analysis: AHI ${ahi is num ? ahi.toStringAsFixed(1) : '—'}/h, '
        '${events.length} markers added',
      );
      if (!mounted) return;
      await showPsgSummaryDialog(
        context,
        title: 'Respiratory Analysis — ${_basename(path)}',
        sections: respiratorySummarySections(report),
        warnings: [
          for (final w in (report['warnings'] as List? ?? const [])) w.toString(),
        ],
        reportPath: outPath,
      );
    } catch (e) {
      _setStatus('Respiratory analysis failed: $e');
      if (mounted) _showTextDialog('Respiratory analysis failed', '$e');
    } finally {
      if (tempDir != null) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<void> _runPlmAnalysis() async {
    final v = _viewport;
    final path = _activePath;
    if (v == null || path == null) {
      _setStatus('Load a PSG recording first');
      return;
    }
    if (!isAnalyseNidraAvailable()) {
      _showTextDialog(
        'PLM analysis unavailable',
        'The native analyse-nidra engine was not found beside the application.',
      );
      return;
    }
    final executable = detectAnalyseNidraExecutable();
    Directory? tempDir;
    try {
      _setStatus('Reading PSG channels…');
      final (edf, tmp) = await _nativeEdfFor(path);
      tempDir = tmp;
      final signals = await listPsgSignals(executable, edf);
      if (!mounted) return;
      final respPath = respiratoryReportPath(path);
      final hasResp = File(respPath).existsSync();
      final settings = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => PlmAnalysisDialog(
          signals: signals,
          hasHypnogram: v.stages.any((s) => s.isScored),
          hasRespiratoryReport: hasResp,
        ),
      );
      if (settings == null || !mounted) {
        _setStatus('PLM analysis cancelled');
        return;
      }
      final scoringPath = await _saveScoringForPsg(path, v);
      final outPath = plmReportPath(path);
      final args = buildPlmArgs(
        edfPath: edf,
        settings: settings,
        scoringPath: scoringPath,
        respiratoryJson: hasResp ? respPath : null,
        lightsOffSeconds: _config.lightsOffSeconds,
        lightsOnSeconds: _config.lightsOnSeconds,
        outPath: outPath,
      );
      if (!mounted) return;
      final (exitCode, logs) = await runAnalyseNidraWithProgress(
        context: context,
        title: 'Periodic Limb Movement Analysis',
        executable: executable,
        arguments: args,
      );
      final report = exitCode == 0 ? await loadPsgReport(outPath) : null;
      if (report == null) {
        _setStatus('PLM analysis failed');
        _showTextDialog(
          'PLM analysis failed',
          'analyse-nidra returned exit code $exitCode.\n\n${logs.join('\n')}',
        );
        return;
      }
      final events = plmEventsFromReport(report);
      final plmsi = (report['summary'] as Map?)?['PLMS_index'];
      _replacePsgEvents(
        isLimbMovementDigit,
        events,
        'PLM analysis: PLMS index ${plmsi is num ? plmsi.toStringAsFixed(1) : '—'}/h, '
        '${events.length} leg-movement markers added',
      );
      if (!mounted) return;
      await showPsgSummaryDialog(
        context,
        title: 'PLM Analysis — ${_basename(path)}',
        sections: plmSummarySections(report),
        warnings: [
          for (final w in (report['warnings'] as List? ?? const [])) w.toString(),
        ],
        reportPath: outPath,
      );
    } catch (e) {
      _setStatus('PLM analysis failed: $e');
      if (mounted) _showTextDialog('PLM analysis failed', '$e');
    } finally {
      if (tempDir != null) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  static final RegExp _manualAPhaseLabel = RegExp(
    r'^(m?cap[\s_-]*)?a[123]\b',
    caseSensitive: false,
  );

  Future<void> _runCapAnalysis() async {
    final v = _viewport;
    final path = _activePath;
    if (v == null || path == null) {
      _setStatus('Load a PSG recording first');
      return;
    }
    if (!isAnalyseNidraAvailable()) {
      _showTextDialog(
        'CAP analysis unavailable',
        'The native analyse-nidra engine was not found beside the application.',
      );
      return;
    }
    final executable = detectAnalyseNidraExecutable();
    Directory? tempDir;
    try {
      _setStatus('Reading PSG channels…');
      final (edf, tmp) = await _nativeEdfFor(path);
      tempDir = tmp;
      final signals = await listPsgSignals(executable, edf);
      if (!mounted) return;
      final respPath = respiratoryReportPath(path);
      final plmPath = plmReportPath(path);
      final hasResp = File(respPath).existsSync();
      final hasPlm = File(plmPath).existsSync();
      final manualCount = v.scoredEvents
          .where(
            (e) =>
                !isCapDigit(e.digit) &&
                !e.label.toUpperCase().startsWith('CAP A') &&
                _manualAPhaseLabel.hasMatch(e.label.trim()),
          )
          .length;
      final settings = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => CapAnalysisDialog(
          signals: signals,
          hasHypnogram: v.stages.any((s) => s.isScored),
          hasManualAPhases: manualCount >= 10,
          hasRespiratoryReport: hasResp,
          hasPlmReport: hasPlm,
        ),
      );
      if (settings == null || !mounted) {
        _setStatus('CAP analysis cancelled');
        return;
      }
      final scoringPath = await _saveScoringForPsg(path, v);
      final outPath = capReportPath(path);
      final args = buildCapArgs(
        edfPath: edf,
        settings: settings,
        scoringPath: scoringPath,
        respiratoryJson: hasResp ? respPath : null,
        plmJson: hasPlm ? plmPath : null,
        lightsOffSeconds: _config.lightsOffSeconds,
        lightsOnSeconds: _config.lightsOnSeconds,
        outPath: outPath,
      );
      if (!mounted) return;
      final (exitCode, logs) = await runAnalyseNidraWithProgress(
        context: context,
        title: 'Cyclic Alternating Pattern Analysis',
        executable: executable,
        arguments: args,
      );
      final report = exitCode == 0 ? await loadPsgReport(outPath) : null;
      if (report == null) {
        _setStatus('CAP analysis failed');
        _showTextDialog(
          'CAP analysis failed',
          'analyse-nidra returned exit code $exitCode.\n\n${logs.join('\n')}',
        );
        return;
      }
      final events = capEventsFromReport(
        report,
        aPhases: settings['showAPhases'] != false,
        sequences: settings['showSequences'] != false,
        includeIsolated: settings['showIsolated'] == true,
      );
      final rate = (report['summary'] as Map?)?['CAP_rate'];
      _replacePsgEvents(
        isCapDigit,
        events,
        'CAP analysis: CAP rate ${rate is num ? rate.toStringAsFixed(1) : '—'}%, '
        '${events.length} markers added',
      );
      if (!mounted) return;
      await showPsgSummaryDialog(
        context,
        title: 'CAP Analysis — ${_basename(path)}',
        sections: capSummarySections(report),
        warnings: [
          for (final w in (report['warnings'] as List? ?? const [])) w.toString(),
        ],
        reportPath: outPath,
      );
    } catch (e) {
      _setStatus('CAP analysis failed: $e');
      if (mounted) _showTextDialog('CAP analysis failed', '$e');
    } finally {
      if (tempDir != null) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// Show or remove respiratory, limb-movement and CAP markers on the
  /// waveform and hypnogram; removed groups can be restored from the saved
  /// analysis results (also those produced by batch analysis).
  Future<void> _managePsgMarkers() async {
    final v = _viewport;
    final path = _activePath;
    if (v == null || path == null) {
      _setStatus('Load a PSG recording first');
      return;
    }
    final resp = await loadPsgReport(respiratoryReportPath(path));
    final plm = await loadPsgReport(plmReportPath(path));
    final cap = await loadPsgReport(capReportPath(path));
    final shown = {
      for (final g in PsgMarkerGroup.values)
        if (v.scoredEvents.any((e) => g.matches(e.digit))) g,
    };
    final available = {
      if (resp != null) ...[PsgMarkerGroup.respiratory, PsgMarkerGroup.desaturations],
      if (plm != null) PsgMarkerGroup.limbMovements,
      if (cap != null) ...[PsgMarkerGroup.capAPhases, PsgMarkerGroup.capSequences],
    };
    if (!mounted) return;
    final selected = await showDialog<Set<PsgMarkerGroup>>(
      context: context,
      builder: (_) => PsgMarkerManagerDialog(shown: shown, available: available),
    );
    if (selected == null) return;
    final fresh = <ScoredEvent>[];
    final replace = <PsgMarkerGroup>{};
    for (final g in PsgMarkerGroup.values) {
      final want = selected.contains(g);
      final has = shown.contains(g);
      if (want == has) continue;
      replace.add(g);
      if (!want) continue;
      final List<ScoredEvent> source = switch (g) {
        PsgMarkerGroup.respiratory || PsgMarkerGroup.desaturations =>
          resp == null ? const <ScoredEvent>[] : respiratoryEventsFromReport(resp),
        PsgMarkerGroup.limbMovements =>
          plm == null ? const <ScoredEvent>[] : plmEventsFromReport(plm),
        PsgMarkerGroup.capAPhases =>
          cap == null ? const <ScoredEvent>[] : capEventsFromReport(cap, sequences: false),
        PsgMarkerGroup.capSequences =>
          cap == null ? const <ScoredEvent>[] : capEventsFromReport(cap, aPhases: false),
      };
      fresh.addAll(source.where((e) => g.matches(e.digit)));
    }
    if (replace.isEmpty) return;
    _replacePsgEvents(
      (digit) => replace.any((g) => g.matches(digit)),
      fresh,
      'Analysis markers updated',
    );
  }

  String _getStageLatency(EegViewport v, SleepStage target) {
    for (var i = 0; i < v.stages.length; i++) {
      if (v.stages[i] == target) {
        return ((i * v.epochSeconds) / 60.0).toStringAsFixed(1);
      }
    }
    return 'N/A';
  }

  Future<void> _openFile(String path) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isWindows) {
        await Process.run('cmd.exe', [
          '/c',
          'start',
          '""',
          path,
        ], runInShell: true);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path]);
      }
    } catch (e) {
      print('Error auto-opening sleep report: $e');
    }
  }

  /// Returns 7 flags: the five EEG pages, then Respiratory and PLM pages
  /// (added only when the corresponding analysis results exist).
  Future<List<bool>?> _showPageSelectionDialog({
    bool? hasRespiratory,
    bool? hasPlm,
    bool? hasCap,
    bool? hasNlg,
  }) async {
    final List<String> pageNames = [
      'Page 1: Macrostructure & Sleep Architecture',
      'Page 2: Thalamocortical Microstructure',
      'Page 3: Aperiodic & Fractal Activity',
      'Page 4: Spectral & Complexity Profile',
      'Page 5: Clinical Summary & Interpretation',
      hasRespiratory == null
          ? 'Respiratory Events & Oximetry (when analysed)'
          : 'Respiratory Events & Oximetry',
      hasPlm == null
          ? 'Periodic Limb Movements (when analysed)'
          : 'Periodic Limb Movements',
      hasCap == null
          ? 'Cyclic Alternating Pattern (when analysed)'
          : 'Cyclic Alternating Pattern',
      hasNlg == null
          ? 'NeuroLoopGain (when analysed)'
          : 'NeuroLoopGain (slow-wave & sigma gain)',
    ];
    final List<bool> selected = [
      true,
      true,
      true,
      true,
      true,
      hasRespiratory ?? true,
      hasPlm ?? true,
      hasCap ?? true,
      hasNlg ?? true,
    ];
    final List<bool> enabled = [
      true,
      true,
      true,
      true,
      true,
      hasRespiratory ?? true,
      hasPlm ?? true,
      hasCap ?? true,
      hasNlg ?? true,
    ];

    return showDialog<List<bool>>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Select Report Pages to Generate'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < pageNames.length; i++)
                    CheckboxListTile(
                      dense: true,
                      title: Text(pageNames[i]),
                      subtitle: enabled[i]
                          ? null
                          : const Text('Run the analysis from the Utilities menu first'),
                      value: selected[i] && enabled[i],
                      onChanged: enabled[i]
                          ? (v) {
                              setState(() {
                                selected[i] = v ?? false;
                              });
                            }
                          : null,
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: selected.any((b) => b)
                      ? () => Navigator.of(context).pop(selected)
                      : null,
                  child: const Text('Export'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _exportSleepReport() async {
    final viewport = _viewport;
    if (viewport == null) {
      _setStatus('Load an EDF first');
      return;
    }

    final activeForReport = _activePath;
    final respiratoryPath = activeForReport == null
        ? null
        : respiratoryReportPath(activeForReport);
    final plmPath = activeForReport == null ? null : plmReportPath(activeForReport);
    final capPath = activeForReport == null ? null : capReportPath(activeForReport);
    final nlgPath = activeForReport == null ? null : nlgSidecarPath(activeForReport);
    final selectedPages = await _showPageSelectionDialog(
      hasRespiratory: respiratoryPath != null && File(respiratoryPath).existsSync(),
      hasPlm: plmPath != null && File(plmPath).existsSync(),
      hasCap: capPath != null && File(capPath).existsSync(),
      hasNlg: nlgPath != null && File(nlgPath).existsSync(),
    );
    if (selectedPages == null) {
      _setStatus('Report export cancelled');
      return;
    }

    final output = await FilePicker.saveFile(
      dialogTitle: 'Export Publication-Grade Sleep Report (PDF)',
      fileName: '${_basename(_activePath ?? 'sleep_report')}.report.pdf',
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (output == null) {
      _setStatus('Report export cancelled');
      return;
    }
    final outputPath = output.toLowerCase().endsWith('.pdf')
        ? output
        : '$output.pdf';

    List<Map<String, String>> regionalRows = const [];
    if (_activePath != null) {
      final regionalPath =
          '${_sidecarPath(_activePath!, '')}_analyse_regional.csv';
      final regionalFile = File(regionalPath);
      if (await regionalFile.exists()) {
        regionalRows = parseCsvTable(await regionalFile.readAsString());
      }
    }

    final respiratoryReport = selectedPages[5] && respiratoryPath != null
        ? await loadPsgReport(respiratoryPath)
        : null;
    final plmReport = selectedPages[6] && plmPath != null
        ? await loadPsgReport(plmPath)
        : null;
    final capReport = selectedPages.length > 7 && selectedPages[7] && capPath != null
        ? await loadPsgReport(capPath)
        : null;
    final nlgReport = selectedPages.length > 8 && selectedPages[8] && nlgPath != null
        ? await loadPsgReport(nlgPath)
        : null;
    final bytes = buildPublicationSleepReport(
      viewport: viewport,
      recordingName: _basename(_activePath ?? viewport.sourceDescription),
      regionalRows: regionalRows,
      includePages: selectedPages.sublist(0, 5),
      respiratoryReport: respiratoryReport,
      plmReport: plmReport,
      capReport: capReport,
      nlgReport: nlgReport,
      metadata: ReportMetadata(
        title: _config.reportTitle,
        studySite: _config.studySite,
        investigatorName: _config.investigatorName,
        subjectId: _config.subjectId,
        subjectDetails: _config.subjectDetails,
        recordingDate: _config.recordingDate,
      ),
    );
    await File(outputPath).writeAsBytes(bytes);
    _setStatus(
      regionalRows.isEmpty
          ? 'Exported report without AnalyseNidra regional metrics'
          : 'Exported selected pages of AnalyseNidra report to ${_basename(outputPath)}',
    );
    await _openFile(outputPath);
  }

  Future<void> _exportSleepReportLegacy() async {
    final v = _viewport;
    if (v == null) {
      _setStatus('Load an EDF first');
      return;
    }
    final output = await FilePicker.saveFile(
      dialogTitle: 'Export Sleep Report (PDF)',
      fileName: '${_basename(_activePath ?? 'sleep_report')}.report.pdf',
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (output == null) {
      _setStatus('Report export cancelled');
      return;
    }
    final path = output.toLowerCase().endsWith('.pdf') ? output : '$output.pdf';

    // Attempt to load analyseNidra sidecar results if present
    Map<String, dynamic>? coreData;
    Map<String, dynamic>? spindleData;
    Map<String, dynamic>? slowWaveData;
    Map<String, dynamic>? pacData;
    List<Map<String, String>> regionalRows = const [];

    if (_activePath != null) {
      final base = _sidecarPath(_activePath!, '');
      final coreFile = File('${base}_analyse_core.json');
      final spindleFile = File('${base}_analyse_spindles.json');
      final slowWaveFile = File('${base}_analyse_slow_waves.json');
      final pacFile = File('${base}_analyse_pac.json');
      final regionalFile = File('${base}_analyse_regional.csv');

      try {
        if (await coreFile.exists()) {
          coreData =
              jsonDecode(await coreFile.readAsString()) as Map<String, dynamic>;
        }
      } catch (e) {
        print('Error parsing core features sidecar: $e');
      }
      try {
        if (await spindleFile.exists()) {
          spindleData =
              jsonDecode(await spindleFile.readAsString())
                  as Map<String, dynamic>;
        }
      } catch (e) {
        print('Error parsing spindle features sidecar: $e');
      }
      try {
        if (await slowWaveFile.exists()) {
          slowWaveData =
              jsonDecode(await slowWaveFile.readAsString())
                  as Map<String, dynamic>;
        }
      } catch (e) {
        print('Error parsing slow-wave features sidecar: $e');
      }
      try {
        if (await pacFile.exists()) {
          pacData =
              jsonDecode(await pacFile.readAsString()) as Map<String, dynamic>;
        }
      } catch (e) {
        print('Error parsing PAC features sidecar: $e');
      }
      try {
        if (await regionalFile.exists()) {
          regionalRows = _parseCsvTable(await regionalFile.readAsString());
        }
      } catch (e) {
        print('Error parsing regional features sidecar: $e');
      }
    }

    final scored = v.stages.where((s) => s.isScored).length;
    final sleepEpochs = v.stages
        .where(
          (s) =>
              s == SleepStage.n1 ||
              s == SleepStage.n2 ||
              s == SleepStage.n3 ||
              s == SleepStage.rem,
        )
        .length;
    final totalMinutes = v.epochCount * v.epochSeconds / 60.0;
    final sleepMinutes = sleepEpochs * v.epochSeconds / 60.0;
    final efficiency = totalMinutes <= 0
        ? 0.0
        : sleepMinutes / totalMinutes * 100.0;

    final n2Count = v.stages.where((s) => s == SleepStage.n2).length;
    final n3Count = v.stages.where((s) => s == SleepStage.n3).length;
    final nremMinutes = (n2Count + n3Count) * v.epochSeconds / 60.0;

    final doc = SimplePdfDoc();

    // ----------------- PAGE 1: SLEEP ARCHITECTURE -----------------
    final p1 = PdfPageBuilder();

    p1.drawRgbRect(36, 724, 540, 48, 0.05, 0.18, 0.31);
    p1.drawText(
      'CCS SLEEP STUDIO QUANTITATIVE SLEEP REPORT',
      52,
      750,
      bold: true,
      size: 15,
      r: 1,
      g: 1,
      b: 1,
    );
    p1.drawText(
      'Sleep architecture and AnalyseNidra quantitative EEG summary',
      52,
      734,
      size: 8.5,
      r: 0.75,
      g: 0.86,
      b: 0.96,
    );

    // Metadata Block
    p1.drawRgbRect(50, 610, 512, 85, 0.96, 0.98, 1.0);
    p1.drawText('Recording Details', 60, 680, bold: true, size: 10);
    p1.drawLine(60, 676, 170, 676, width: 0.5, gray: 0.5);

    p1.drawText(
      'File Name: ${_basename(_activePath ?? v.sourceDescription)}',
      60,
      660,
      size: 9,
    );
    p1.drawText(
      'Total Epochs: ${v.epochCount} (${v.epochSeconds} seconds each)',
      60,
      645,
      size: 9,
    );
    p1.drawText(
      'Total Duration: ${totalMinutes.toStringAsFixed(1)} minutes',
      60,
      630,
      size: 9,
    );
    p1.drawText(
      'Scored Epochs: $scored / ${v.epochCount} (${(scored / v.epochCount * 100).toStringAsFixed(1)}%)',
      60,
      615,
      size: 9,
    );

    // Sleep Architecture Section
    p1.drawText('Sleep Architecture Summary', 50, 580, bold: true, size: 11);
    p1.drawLine(50, 575, 562, 575, width: 0.75, gray: 0.4);

    // Table Header
    p1.drawRect(50, 550, 512, 18, gray: 0.85);
    p1.drawText('Sleep Stage', 60, 555, bold: true, size: 9);
    p1.drawText('Epochs', 200, 555, bold: true, size: 9);
    p1.drawText('Duration (min)', 320, 555, bold: true, size: 9);
    p1.drawText('% of Sleep Time', 440, 555, bold: true, size: 9);

    double y = 530;
    final stagesList = [
      (SleepStage.wake, 'Wake (W)'),
      (SleepStage.n1, 'NREM 1 (N1)'),
      (SleepStage.n2, 'NREM 2 (N2)'),
      (SleepStage.n3, 'NREM 3 (N3)'),
      (SleepStage.rem, 'REM (R)'),
    ];

    for (final entry in stagesList) {
      final count = v.stages.where((s) => s == entry.$1).length;
      final minutes = count * v.epochSeconds / 60.0;
      final pct = sleepMinutes <= 0
          ? 0.0
          : (entry.$1 == SleepStage.wake
                ? 0.0
                : (minutes / sleepMinutes * 100.0));
      final pctStr = entry.$1 == SleepStage.wake
          ? 'N/A'
          : '${pct.toStringAsFixed(1)} %';

      final color = _pdfStageColor(entry.$1);
      p1.drawRgbRect(51, y + 1, 5, 16, color.$1, color.$2, color.$3);
      p1.drawText(entry.$2, 60, y + 4, size: 9);
      p1.drawText('$count', 200, y + 4, size: 9);
      p1.drawText(minutes.toStringAsFixed(1), 320, y + 4, size: 9);
      p1.drawText(pctStr, 440, y + 4, size: 9);
      p1.drawLine(50, y, 562, y, width: 0.25, gray: 0.8);
      y -= 18;
    }

    // Total Sleep Time Row
    p1.drawRect(50, y, 512, 18, gray: 0.95);
    p1.drawText('Total Sleep Time (TST)', 60, y + 4, bold: true, size: 9);
    p1.drawText('$sleepEpochs', 200, y + 4, bold: true, size: 9);
    p1.drawText(
      sleepMinutes.toStringAsFixed(1),
      320,
      y + 4,
      bold: true,
      size: 9,
    );
    p1.drawText('100.0 %', 440, y + 4, bold: true, size: 9);
    p1.drawLine(50, y, 562, y, width: 0.5, gray: 0.5);

    y -= 25;

    // Metrics Box
    p1.drawRect(50, y - 50, 512, 60, fill: false, gray: 0.6);
    p1.drawText(
      'Sleep Efficiency: ${efficiency.toStringAsFixed(1)} %  (Total Sleep Time / Recording Time)',
      65,
      y - 15,
      bold: true,
      size: 9,
    );
    p1.drawText(
      'Latency to N1: ${_getStageLatency(v, SleepStage.n1)} min',
      65,
      y - 30,
      size: 9,
    );
    p1.drawText(
      'Latency to REM: ${_getStageLatency(v, SleepStage.rem)} min',
      65,
      y - 45,
      size: 9,
    );

    y -= 60;

    // Draw Vector Hypnogram step chart
    p1.drawText(
      'Hypnogram (Sleep Stage Timeline)',
      50,
      y,
      bold: true,
      size: 10,
    );
    p1.drawLine(50, y - 5, 562, y - 5, width: 0.5, gray: 0.4);
    y -= 140;

    final stagesY = {
      SleepStage.wake: y + 110.0,
      SleepStage.rem: y + 85.0,
      SleepStage.n1: y + 60.0,
      SleepStage.n2: y + 35.0,
      SleepStage.n3: y + 10.0,
    };

    stagesY.forEach((stage, yVal) {
      String label = '';
      if (stage == SleepStage.wake) label = 'W';
      if (stage == SleepStage.rem) label = 'REM';
      if (stage == SleepStage.n1) label = 'N1';
      if (stage == SleepStage.n2) label = 'N2';
      if (stage == SleepStage.n3) label = 'N3';

      p1.drawText(label, 50, yVal - 3, size: 8, bold: stage == SleepStage.rem);
      p1.drawLine(80, yVal, 562, yVal, width: 0.25, gray: 0.8);
    });

    // Draw frame bounding box
    p1.drawRect(80, y, 482, 120, fill: false, gray: 0.5);

    // Draw uncertain background stripes.
    for (var i = 0; i < v.epochCount; i++) {
      final isUncertain = i < v.stagesUncertain.length && v.stagesUncertain[i];
      if (isUncertain) {
        final xStart = 80 + (i / v.epochCount) * 482;
        final xEnd = 80 + ((i + 1) / v.epochCount) * 482;
        p1.drawRect(
          xStart,
          y,
          (xEnd - xStart).clamp(0.5, 482.0),
          120,
          gray: 0.95,
          fill: true,
        );
      }
    }

    // Draw stage-coloured blocks and a high-contrast step line.
    double? lastHypY;
    for (var i = 0; i < v.epochCount; i++) {
      final stage = v.stages[i];
      final yVal = stagesY[stage] ?? (y + 110.0); // default to Wake
      final xStart = 80 + (i / v.epochCount) * 482;
      final xEnd = 80 + ((i + 1) / v.epochCount) * 482;
      final color = _pdfStageColor(stage);
      p1.drawRgbRect(
        xStart,
        yVal - 9,
        math.max(0.5, xEnd - xStart),
        18,
        color.$1,
        color.$2,
        color.$3,
      );

      p1.drawRgbLine(xStart, yVal, xEnd, yVal, 0.05, 0.08, 0.12, width: 0.7);
      if (lastHypY != null && lastHypY != yVal) {
        p1.drawRgbLine(
          xStart,
          lastHypY,
          xStart,
          yVal,
          0.05,
          0.08,
          0.12,
          width: 0.7,
        );
      }
      lastHypY = yVal;
    }

    // Draw X-Axis Ticks & Labels
    final totalHours = (v.epochCount * v.epochSeconds) / 3600.0;
    p1.drawText('0.0h', 80, y - 12, size: 8);
    p1.drawText(
      '${(totalHours / 2).toStringAsFixed(1)}h',
      310,
      y - 12,
      size: 8,
    );
    p1.drawText('${totalHours.toStringAsFixed(1)}h', 545, y - 12, size: 8);
    p1.drawText('Time (Hours)', 300, y - 25, size: 8, bold: true);

    final totalPages =
        1 + (coreData != null ? 2 : 0) + (regionalRows.isNotEmpty ? 1 : 0);
    p1.drawText(
      'Research-use quantitative summary; clinical interpretation remains the responsibility of a qualified reviewer.',
      50,
      40,
      size: 7,
    );
    p1.drawText('Page 1 of $totalPages', 520, 40, size: 8, bold: false);
    doc.addPage(p1.build());

    // ----------------- QUANTITATIVE DATA PAGES (analyseNidra) -----------------
    if (coreData != null) {
      // PAGE 2: Spindles and Slow Waves Summaries
      final p2 = PdfPageBuilder();
      p2.drawText(
        'QUANTITATIVE EEG ANALYSIS: SPINDLES & SLOW WAVES',
        50,
        745,
        bold: true,
        size: 13,
      );
      p2.drawLine(50, 735, 562, 735, width: 1.5, gray: 0.1);
      p2.drawText(
        'Events detected during NREM sleep (N2 + N3) epochs.',
        50,
        715,
        size: 9,
        gray: 0.4,
      );

      // Spindles Table
      p2.drawText(
        'Sleep Spindles (YASA algorithm)',
        50,
        685,
        bold: true,
        size: 11,
      );
      p2.drawLine(50, 680, 562, 680, width: 0.5, gray: 0.4);

      p2.drawRect(50, 655, 512, 18, gray: 0.85);
      p2.drawText('Channel', 60, 659, bold: true, size: 9);
      p2.drawText('Count', 140, 659, bold: true, size: 9);
      p2.drawText('Density (/min)', 220, 659, bold: true, size: 9);
      p2.drawText('Avg Duration (s)', 310, 659, bold: true, size: 9);
      p2.drawText('Avg Amp (uV)', 400, 659, bold: true, size: 9);
      p2.drawText('Avg Freq (Hz)', 490, 659, bold: true, size: 9);

      double y2 = 635;
      final List<dynamic> spindleSummaries =
          (spindleData != null && spindleData['summary'] != null)
          ? spindleData['summary'] as List<dynamic>
          : [];

      for (final item in spindleSummaries) {
        if (item is! Map<String, dynamic>) continue;
        final chan = item['Channel'] ?? '';
        final count = item['Count'] ?? 0;
        final dur = item['Duration'] ?? 0.0;
        final amp = item['Amplitude'] ?? 0.0;
        final freq = item['Frequency'] ?? 0.0;
        final density = nremMinutes > 0 ? (count / nremMinutes) : 0.0;

        p2.drawText(chan.toString(), 60, y2 + 3, size: 9);
        p2.drawText(count.toString(), 140, y2 + 3, size: 9);
        p2.drawText(density.toStringAsFixed(2), 220, y2 + 3, size: 9);
        p2.drawText(dur.toStringAsFixed(2), 310, y2 + 3, size: 9);
        p2.drawText(amp.toStringAsFixed(1), 400, y2 + 3, size: 9);
        p2.drawText(freq.toStringAsFixed(2), 490, y2 + 3, size: 9);

        p2.drawLine(50, y2, 562, y2, width: 0.25, gray: 0.8);
        y2 -= 18;
      }

      y2 -= 15;

      // Slow Waves Table
      p2.drawText('Slow Waves (YASA algorithm)', 50, y2, bold: true, size: 11);
      p2.drawLine(50, y2 - 5, 562, y2 - 5, width: 0.5, gray: 0.4);
      y2 -= 30;

      p2.drawRect(50, y2, 512, 18, gray: 0.85);
      p2.drawText('Channel', 60, y2 + 4, bold: true, size: 9);
      p2.drawText('Count', 130, y2 + 4, bold: true, size: 9);
      p2.drawText('Density (/min)', 200, y2 + 4, bold: true, size: 9);
      p2.drawText('Avg PTP (uV)', 280, y2 + 4, bold: true, size: 9);
      p2.drawText('Slope (uV/s)', 370, y2 + 4, bold: true, size: 9);
      p2.drawText('Coupling (ndPAC)', 460, y2 + 4, bold: true, size: 9);

      y2 -= 20;
      final List<dynamic> slowWaveSummaries =
          (slowWaveData != null && slowWaveData['summary'] != null)
          ? slowWaveData['summary'] as List<dynamic>
          : [];

      for (final item in slowWaveSummaries) {
        if (item is! Map<String, dynamic>) continue;
        final chan = item['Channel'] ?? '';
        final count = item['Count'] ?? 0;
        final ptp = item['PTP'] ?? 0.0;
        final slope = item['Slope'] ?? 0.0;
        final pacVal = item['ndPAC'] ?? 0.0;
        final density = nremMinutes > 0 ? (count / nremMinutes) : 0.0;

        p2.drawText(chan.toString(), 60, y2 + 3, size: 9);
        p2.drawText(count.toString(), 130, y2 + 3, size: 9);
        p2.drawText(density.toStringAsFixed(2), 200, y2 + 3, size: 9);
        p2.drawText(ptp.toStringAsFixed(1), 280, y2 + 3, size: 9);
        p2.drawText(slope.toStringAsFixed(1), 370, y2 + 3, size: 9);
        p2.drawText(pacVal.toStringAsFixed(3), 460, y2 + 3, size: 9);

        p2.drawLine(50, y2, 562, y2, width: 0.25, gray: 0.8);
        y2 -= 18;
      }

      p2.drawText(
        'Report generated by CCS Sleep Studio.',
        50,
        40,
        size: 8,
        bold: false,
      );
      p2.drawText('Page 2 of $totalPages', 520, 40, size: 8, bold: false);
      doc.addPage(p2.build());

      // PAGE 3: Spectral features and Phase-Amplitude Coupling details
      final p3 = PdfPageBuilder();
      p3.drawText(
        'QUANTITATIVE EEG: SPECTRAL POWER & PAC ANALYSIS',
        50,
        745,
        bold: true,
        size: 13,
      );
      p3.drawLine(50, 735, 562, 735, width: 1.5, gray: 0.1);
      p3.drawText(
        'Spectral power and coupling calculated using FOOOF/IRASA/TensorPAC.',
        50,
        715,
        size: 9,
        gray: 0.4,
      );

      // Spectral Power Table
      p3.drawText(
        'EEG Spectral Band Power & ACW (averaged over 15s windows)',
        50,
        685,
        bold: true,
        size: 11,
      );
      p3.drawLine(50, 680, 562, 680, width: 0.5, gray: 0.4);

      p3.drawRect(50, 655, 512, 18, gray: 0.85);
      p3.drawText('Chan', 60, 659, bold: true, size: 9);
      p3.drawText('Stage', 110, 659, bold: true, size: 9);
      p3.drawText('Delta (1-4Hz)', 170, 659, bold: true, size: 9);
      p3.drawText('Theta (4-8Hz)', 255, 659, bold: true, size: 9);
      p3.drawText('Alpha (8-12Hz)', 340, 659, bold: true, size: 9);
      p3.drawText('Sigma (10-16Hz)', 425, 659, bold: true, size: 9);
      p3.drawText('ACW (s)', 510, 659, bold: true, size: 9);

      double y3 = 635;
      final Map<String, dynamic> channelsData = (coreData['channels'] != null)
          ? coreData['channels'] as Map<String, dynamic>
          : {};

      for (final chan in channelsData.keys) {
        final Map<String, dynamic> feats =
            channelsData[chan] is Map<String, dynamic>
            ? channelsData[chan] as Map<String, dynamic>
            : {};

        for (final stage in ['N2', 'N3']) {
          final delta = feats['${stage}_Delta_PSD'] ?? 0.0;
          final theta = feats['${stage}_Theta_PSD'] ?? 0.0;
          final alpha = feats['${stage}_Alpha_PSD'] ?? 0.0;
          final sigma = feats['${stage}_Sigma_PSD'] ?? 0.0;
          final acw = feats['${stage}_ACW'] ?? 0.0;

          p3.drawText(chan, 60, y3 + 3, size: 9);
          p3.drawText(stage, 110, y3 + 3, size: 9);
          p3.drawText(
            '${(delta * 100).toStringAsFixed(1)} %',
            170,
            y3 + 3,
            size: 9,
          );
          p3.drawText(
            '${(theta * 100).toStringAsFixed(1)} %',
            255,
            y3 + 3,
            size: 9,
          );
          p3.drawText(
            '${(alpha * 100).toStringAsFixed(1)} %',
            340,
            y3 + 3,
            size: 9,
          );
          p3.drawText(
            '${(sigma * 100).toStringAsFixed(1)} %',
            425,
            y3 + 3,
            size: 9,
          );
          p3.drawText(acw.toStringAsFixed(2), 510, y3 + 3, size: 9);

          p3.drawLine(50, y3, 562, y3, width: 0.25, gray: 0.8);
          y3 -= 18;
        }
      }

      y3 -= 15;

      // Phase Amplitude Coupling (PAC) Section
      p3.drawText(
        'Phase-Amplitude Coupling (PAC) Modulation Index (MI)',
        50,
        y3,
        bold: true,
        size: 11,
      );
      p3.drawLine(50, y3 - 5, 562, y3 - 5, width: 0.5, gray: 0.4);
      y3 -= 30;

      final Map<String, dynamic> pacMap = pacData ?? {};
      p3.drawRect(50, y3, 512, 18, gray: 0.85);
      p3.drawText('Channel', 60, y3 + 4, bold: true, size: 9);
      p3.drawText('Max Coupling Index (MI)', 180, y3 + 4, bold: true, size: 9);
      p3.drawText('Phase Frequency (Hz)', 320, y3 + 4, bold: true, size: 9);
      p3.drawText('Amplitude Frequency (Hz)', 440, y3 + 4, bold: true, size: 9);

      y3 -= 20;
      if (pacMap.isEmpty) {
        p3.drawText('No PAC data available.', 60, y3, size: 9);
        p3.drawLine(50, y3 - 5, 562, y3 - 5, width: 0.25, gray: 0.8);
        y3 -= 18;
      } else {
        for (final chan in pacMap.keys) {
          final item = pacMap[chan];
          if (item is! Map<String, dynamic>) continue;
          final maxMi = item['maximum'] ?? 0.0;
          final ampFreq = item['amplitude_frequency'] ?? 0.0;
          final phaseFreq = item['phase_frequency'] ?? 0.0;

          p3.drawText(chan, 60, y3 + 3, size: 9);
          p3.drawText(maxMi.toStringAsExponential(3), 180, y3 + 3, size: 9);
          p3.drawText(phaseFreq.toStringAsFixed(1), 320, y3 + 3, size: 9);
          p3.drawText(ampFreq.toStringAsFixed(1), 440, y3 + 3, size: 9);

          p3.drawLine(50, y3, 562, y3, width: 0.25, gray: 0.8);
          y3 -= 18;
        }
      }

      p3.drawText(
        'Report generated by CCS Sleep Studio.',
        50,
        40,
        size: 8,
        bold: false,
      );
      p3.drawText('Page 3 of $totalPages', 520, 40, size: 8, bold: false);
      doc.addPage(p3.build());
    }

    if (regionalRows.isNotEmpty) {
      final p = PdfPageBuilder();
      p.drawRgbRect(36, 724, 540, 48, 0.05, 0.18, 0.31);
      p.drawText(
        'REGIONAL QUANTITATIVE EEG PROFILE',
        52,
        748,
        bold: true,
        size: 15,
        r: 1,
        g: 1,
        b: 1,
      );
      p.drawText(
        'AnalyseNidra regional aggregation across selected scalp channels',
        52,
        733,
        size: 8.5,
        r: 0.75,
        g: 0.86,
        b: 0.96,
      );

      final architecture = regionalRows.first;
      final metricCards = <(String, String, String)>[
        ('TST', _csvMetric(architecture, 'TST', decimals: 1), 'min'),
        (
          'Sleep efficiency',
          _csvMetric(architecture, 'Sleep_efficiency', decimals: 1),
          '%',
        ),
        ('WASO', _csvMetric(architecture, 'WASO', decimals: 1), 'min'),
        ('Sleep onset', _csvMetric(architecture, 'SOL', decimals: 1), 'min'),
        ('NREM', _csvMetric(architecture, 'NREM_duration', decimals: 1), 'min'),
        ('Lempel-Ziv', _csvMetric(architecture, 'LZc', decimals: 3), ''),
      ];
      for (var i = 0; i < metricCards.length; i++) {
        final col = i % 3;
        final row = i ~/ 3;
        final x = 50.0 + col * 172;
        final top = 688.0 - row * 58;
        p.drawRgbRect(x, top - 42, 158, 46, 0.95, 0.97, 0.99);
        p.drawText(
          metricCards[i].$1,
          x + 9,
          top - 10,
          size: 7.5,
          r: 0.28,
          g: 0.36,
          b: 0.45,
        );
        p.drawText(
          '${metricCards[i].$2} ${metricCards[i].$3}',
          x + 9,
          top - 29,
          bold: true,
          size: 13,
          r: 0.05,
          g: 0.18,
          b: 0.31,
        );
      }

      p.drawText(
        'Regional sleep microstructure',
        50,
        555,
        bold: true,
        size: 11,
      );
      p.drawText('Region', 58, 532, bold: true, size: 8);
      p.drawText('Spindles', 145, 532, bold: true, size: 8);
      p.drawText('Density/min', 215, 532, bold: true, size: 8);
      p.drawText('Slow waves', 300, 532, bold: true, size: 8);
      p.drawText('SW PTP uV', 380, 532, bold: true, size: 8);
      p.drawText('ndPAC', 475, 532, bold: true, size: 8);
      p.drawRgbRect(50, 525, 512, 20, 0.86, 0.91, 0.96);
      var ry = 505.0;
      for (final row in regionalRows.take(8)) {
        final alternate = ((505 - ry) / 22).round().isOdd;
        if (alternate) p.drawRgbRect(50, ry - 5, 512, 21, 0.97, 0.98, 0.99);
        p.drawText(row['Chan'] ?? '-', 58, ry, bold: true, size: 8.5);
        p.drawText(
          _csvMetric(row, 'sp_Count', decimals: 0),
          145,
          ry,
          size: 8.5,
        );
        p.drawText(
          _csvMetric(row, 'sp_density', decimals: 2),
          215,
          ry,
          size: 8.5,
        );
        p.drawText(
          _csvMetric(row, 'sw_all_Count', decimals: 0),
          300,
          ry,
          size: 8.5,
        );
        p.drawText(
          _csvMetric(row, 'sw_all_PTP', decimals: 1),
          380,
          ry,
          size: 8.5,
        );
        p.drawText(
          _csvMetric(row, 'sw_all_ndPAC', decimals: 3),
          475,
          ry,
          size: 8.5,
        );
        ry -= 22;
      }

      p.drawText(
        'Relative spectral composition by sleep stage',
        50,
        305,
        bold: true,
        size: 11,
      );
      final bands = <(String, double, double, double)>[
        ('Delta', 0.10, 0.35, 0.65),
        ('Theta', 0.18, 0.58, 0.78),
        ('Alpha', 0.31, 0.69, 0.55),
        ('Sigma', 0.89, 0.55, 0.18),
        ('Beta', 0.78, 0.30, 0.26),
      ];
      var sy = 272.0;
      for (final stage in ['N1', 'N2', 'N3', 'REM']) {
        p.drawText(stage, 52, sy + 3, bold: true, size: 8);
        var x = 82.0;
        final means = <double>[];
        for (final band in ['Delta', 'Theta', 'Alpha', 'Sigma', 'Beta1']) {
          final values = regionalRows
              .map((row) => double.tryParse(row['${stage}_${band}_PSD'] ?? ''))
              .whereType<double>()
              .where((value) => value.isFinite)
              .toList();
          means.add(
            values.isEmpty ? 0 : values.reduce((a, b) => a + b) / values.length,
          );
        }
        final sum = means.fold<double>(0, (a, b) => a + b);
        for (var i = 0; i < means.length; i++) {
          final width = sum <= 0 ? 0.0 : 450 * means[i] / sum;
          p.drawRgbRect(
            x,
            sy - 3,
            width,
            15,
            bands[i].$2,
            bands[i].$3,
            bands[i].$4,
          );
          x += width;
        }
        sy -= 30;
      }
      var lx = 90.0;
      for (final band in bands) {
        p.drawRgbRect(lx, 135, 9, 9, band.$2, band.$3, band.$4);
        p.drawText(band.$1, lx + 13, 136, size: 7.5);
        lx += 88;
      }
      p.drawText(
        'PSD segments are normalized within each displayed stage to emphasize spectral composition.',
        50,
        112,
        size: 7.5,
        r: 0.35,
        g: 0.4,
        b: 0.45,
      );
      p.drawText('Page $totalPages of $totalPages', 520, 40, size: 8);
      doc.addPage(p.build());
    }

    final pdfBytes = doc.build();
    await File(path).writeAsBytes(pdfBytes);
    _setStatus('Exported sleep report to ${_basename(path)}');

    // Auto-open PDF file
    await _openFile(path);
  }

  void _zoomOnSelectedEeg() {
    final v = _viewport;
    final eeg = _loadedEeg;
    if (v == null || eeg == null || v.eventSelections.isEmpty) {
      _setStatus('Draw a signal selection first');
      return;
    }
    final selection = v.eventSelections.last;
    final rawIdx =
        selection.channel >= 0 &&
            selection.channel < v.signalChannelSourceIndices.length
        ? v.signalChannelSourceIndices[selection.channel]
        : selection.channel;
    if (rawIdx < 0 || rawIdx >= eeg.channelSamples.length) return;
    final srate = eeg.sampleRateHz;
    final start = (math.min(selection.startSec, selection.endSec) * srate)
        .round()
        .clamp(0, eeg.channelSamples[rawIdx].length);
    final end = (math.max(selection.startSec, selection.endSec) * srate)
        .round()
        .clamp(0, eeg.channelSamples[rawIdx].length);
    if (end <= start) return;
    final samples = _backend.getDisplaySegmentForChannel(
      eeg: eeg,
      channelIndex: selection.channel,
      start: start,
      end: end,
      config: _config,
      applyFilters: true,
    );
    if (samples.isEmpty) return;
    final label = rawIdx < v.channelLabels.length
        ? v.channelLabels[rawIdx]
        : 'Channel';
    showDialog(
      context: context,
      builder: (context) => Dialog(
        child: SizedBox(
          width: 760,
          height: 420,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  'Selected EEG: $label',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              Expanded(
                child: CustomPaint(
                  painter: _ZoomSignalPainter(samples, srate),
                  child: const SizedBox.expand(),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  int _disagreementCount(List<SleepStage> a, List<SleepStage> b) {
    final total = a.length < b.length ? a.length : b.length;
    var count = 0;
    for (var i = 0; i < total; i++) {
      if (a[i] != b[i]) count++;
    }
    return count;
  }

  // ─── Configuration I/O ────────────────────────────────────────────────────

  Future<void> _loadConfig() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result != null && result.files.single.path != null) {
      final file = File(result.files.single.path!);
      try {
        final content = await file.readAsString();
        final dynamic decoded = jsonDecode(content);
        final newCfg = decoded is Map<String, dynamic>
            ? AppConfig.fromJson(decoded)
            : AppConfig.fromPythonJson(
                decoded,
                _viewport?.channelLabels ?? const [],
              );
        final eegForBinding = _loadedEeg;
        if (eegForBinding != null) {
          newCfg.bindLoadedChannels(
            eegForBinding.channelLabels,
            sampleRateHz: eegForBinding.sampleRateHz,
          );
        }

        setState(() {
          _config = newCfg;
        });
        if (_activePath != null) {
          await saveAutoConfig(_activePath!, newCfg);
        }

        final eeg = _loadedEeg;
        final v = _viewport;
        if (eeg != null && v != null) {
          _backend.clearDisplayCache();
          _setStatus('Applying loaded configuration…');
          final newEeg = await _backend.computeNightProducts(eeg, newCfg);
          final newViewport = await _backend.viewportFromEeg(
            newEeg,
            currentEpoch: v.currentEpoch,
            config: newCfg,
            existingStages: v.stages,
            existingStagesUncertain: v.stagesUncertain,
            existingConfidence: v.stagesConfidence,
            existingStageProbabilities: v.stageProbabilities,
            includeTimeFrequency: false,
          );
          if (mounted) {
            setState(() {
              _loadedEeg = newEeg;
              _viewport = newViewport;
              _status = 'Configuration loaded successfully';
            });
            if (_config.tfEnabled) {
              _scheduleTimeFrequencyRefresh(++_navigationSerial);
            }
          }
        } else {
          _setStatus('Configuration loaded');
        }
      } catch (e) {
        _setStatus('Error loading configuration: $e');
      }
    }
  }

  Future<void> _saveConfig() async {
    final String? outputFile = await FilePicker.saveFile(
      dialogTitle: 'Save Configuration',
      fileName: 'config.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );

    if (outputFile != null) {
      try {
        final json = jsonEncode(_config.toPythonJson());
        await File(outputFile).writeAsString(json);
        _setStatus('Configuration saved to $outputFile');
      } catch (e) {
        _setStatus('Error saving configuration: $e');
      }
    }
  }

  // ─── Configuration ────────────────────────────────────────────────────────

  void _openConfigDialog({int initialTabIndex = 0}) {
    final v = _viewport;
    final eeg = _loadedEeg;
    final channelLabels = eeg?.channelLabels ??
        (_config.channels.isNotEmpty
            ? _config.channels.map((c) => c.name).toList()
            : const <String>[]);
    showDialog(
      context: context,
      builder: (_) => ConfigDialog(
        config: _config,
        channelLabels: channelLabels,
        initialTabIndex: initialTabIndex,
        onPreview: eeg != null ? _previewDisplayConfig : null,
        onApply: (newCfg) {
          final oldCfg = _config;
          setState(() {
            _config = newCfg;
          });
          if (_activePath != null) {
            unawaited(saveAutoConfig(_activePath!, newCfg));
          }
          final eeg = _loadedEeg;
          if (eeg != null && v != null) {
            if (!_configRequiresDisplayRecompute(oldCfg, newCfg)) {
              setState(() {
                _viewport = v.copyWith(
                  amplitudeRangeUv: newCfg.amplitudeRangeUv,
                  spectrogramFlex: newCfg.spectrogramFlex,
                  hypnogramFlex: newCfg.hypnogramFlex,
                  periodogramFlex: newCfg.periodogramFlex,
                  showSwaPlot: newCfg.showSwaPlot,
                  hypnogramOverlayMode: newCfg.hypnogramOverlayMode,
                  hypnogramProbabilityStage: newCfg.hypnogramProbabilityStage,
                  eegPanelTimeUnit: newCfg.eegPanelTimeUnit,
                  lightsOffSeconds: newCfg.lightsOffSeconds,
                  lightsOnSeconds: newCfg.lightsOnSeconds,
                  referenceLineThickness: newCfg.referenceLineThickness,
                  referenceLineColor: newCfg.referenceLineColor,
                  hypnogramZoom: newCfg.hypnogramZoom,
                );
                _status = 'Config applied';
              });
              return;
            }
            _backend.clearDisplayCache();
            // Recompute with new channel config
            _setStatus('Recomputing spectrogram for new channel…');
            Future.microtask(() async {
              final newEeg = await _backend.computeNightProducts(eeg, newCfg);
              final newViewport = await _backend.viewportFromEeg(
                newEeg,
                currentEpoch: v.currentEpoch,
                config: newCfg,
                existingStages: v.stages,
                existingStagesUncertain: v.stagesUncertain,
                existingConfidence: v.stagesConfidence,
                existingStageProbabilities: v.stageProbabilities,
                includeTimeFrequency: false,
              );
              setState(() {
                _loadedEeg = newEeg;
                _viewport = newViewport;
                _status = 'Config applied — spectrogram channel updated';
              });
              if (_config.tfEnabled) {
                _scheduleTimeFrequencyRefresh(++_navigationSerial);
              }
            });
          } else {
            _setStatus('Configuration updated');
          }
        },
      ),
    );
  }

  bool _configRequiresDisplayRecompute(AppConfig oldCfg, AppConfig newCfg) {
    if (!_sameChannelConfig(oldCfg.channels, newCfg.channels)) return true;
    return oldCfg.spectrogramChannelIndex != newCfg.spectrogramChannelIndex ||
        oldCfg.swaChannelIndex != newCfg.swaChannelIndex ||
        oldCfg.periodogramChannelIndex != newCfg.periodogramChannelIndex ||
        oldCfg.tfChannelIndex != newCfg.tfChannelIndex ||
        oldCfg.tfEnabled != newCfg.tfEnabled ||
        oldCfg.tfDisplayMode != newCfg.tfDisplayMode ||
        oldCfg.tfFrequencyScale != newCfg.tfFrequencyScale ||
        oldCfg.tfShowRidge != newCfg.tfShowRidge ||
        oldCfg.tfAutoScale != newCfg.tfAutoScale ||
        oldCfg.tfFreqMin != newCfg.tfFreqMin ||
        oldCfg.tfFreqMax != newCfg.tfFreqMax ||
        oldCfg.tfPowerMin != newCfg.tfPowerMin ||
        oldCfg.tfPowerMax != newCfg.tfPowerMax ||
        oldCfg.spectrogramFreqMin != newCfg.spectrogramFreqMin ||
        oldCfg.spectrogramFreqMax != newCfg.spectrogramFreqMax ||
        oldCfg.spectrogramPowerMin != newCfg.spectrogramPowerMin ||
        oldCfg.spectrogramPowerMax != newCfg.spectrogramPowerMax ||
        oldCfg.periodogramFreqMin != newCfg.periodogramFreqMin ||
        oldCfg.periodogramFreqMax != newCfg.periodogramFreqMax ||
        oldCfg.periodogramDisplayMode != newCfg.periodogramDisplayMode ||
        oldCfg.stackChannels != newCfg.stackChannels ||
        oldCfg.robustZStandardize != newCfg.robustZStandardize ||
        oldCfg.distanceBetweenChannelsUv != newCfg.distanceBetweenChannelsUv ||
        oldCfg.referenceAmplitudeLineUv != newCfg.referenceAmplitudeLineUv;
  }

  bool _sameChannelConfig(List<ChannelConfig> a, List<ChannelConfig> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final left = a[i];
      final right = b[i];
      if (left.name != right.name ||
          left.sourceIndex != right.sourceIndex ||
          left.derived != right.derived ||
          left.sourceChannel != right.sourceChannel ||
          left.color != right.color ||
          left.displayOnScreen != right.displayOnScreen ||
          left.scalingFactor != right.scalingFactor ||
          left.verticalShift != right.verticalShift ||
          left.reReference != right.reReference ||
          left.flipPolarity != right.flipPolarity ||
          left.filterHpEnabled != right.filterHpEnabled ||
          left.filterHpCutoff != right.filterHpCutoff ||
          left.filterHpOrder != right.filterHpOrder ||
          left.filterLpEnabled != right.filterLpEnabled ||
          left.filterLpCutoff != right.filterLpCutoff ||
          left.filterLpOrder != right.filterLpOrder ||
          left.filterNotchEnabled != right.filterNotchEnabled ||
          left.filterNotchCutoff != right.filterNotchCutoff ||
          left.filterNotchOrder != right.filterNotchOrder) {
        return false;
      }
    }
    return true;
  }

  void _openFilterDialog() {
    final v = _viewport;
    final eeg = _loadedEeg;
    if (v == null || eeg == null || eeg.channelLabels.isEmpty) {
      _setStatus('Load an EDF first to configure filters');
      _showTextDialog(
        'Filter settings unavailable',
        'Load a recording before opening filter settings.',
      );
      return;
    }
    showDialog(
      context: context,
      builder: (_) => FilterDialog(
        config: _config,
        channelLabels: eeg.channelLabels,
        onApply: (newCfg) {
          setState(() {
            _config = newCfg;
          });
          if (_activePath != null) {
            saveAutoConfig(_activePath!, newCfg);
          }
          final eeg = _loadedEeg;
          if (eeg != null) {
            _backend.clearDisplayCache();
            _setStatus('Applying filters and updating spectrogram…');
            Future.microtask(() async {
              final newEeg = await _backend.computeNightProducts(eeg, newCfg);
              final newViewport = await _backend.viewportFromEeg(
                newEeg,
                currentEpoch: v.currentEpoch,
                config: newCfg,
                existingStages: v.stages,
                existingStagesUncertain: v.stagesUncertain,
                existingConfidence: v.stagesConfidence,
                existingStageProbabilities: v.stageProbabilities,
                includeTimeFrequency: false,
              );
              setState(() {
                _loadedEeg = newEeg;
                _viewport = newViewport;
                _status = 'Filters applied and spectrogram updated';
              });
              if (_config.tfEnabled) {
                _scheduleTimeFrequencyRefresh(++_navigationSerial);
              }
            });
          } else {
            _previewDisplayConfig(newCfg);
            _setStatus('Filters applied');
          }
        },
      ),
    );
  }

  void _previewDisplayConfig(AppConfig newCfg) {
    final eeg = _loadedEeg;
    final v = _viewport;
    if (eeg == null || v == null) {
      setState(() => _config = newCfg);
      return;
    }
    // Clear waveform cache so filter/display changes take immediate effect.
    _backend.clearDisplayCache();
    final rebuilt = _backend
        .rebuildViewportForEpochSync(v, eeg, v.currentEpoch, config: newCfg)
        .copyWith(stages: v.stages, stagesUncertain: v.stagesUncertain);
    setState(() {
      _config = newCfg;
      _viewport = rebuilt;
      _status = 'Configuration preview applied';
    });
    if (_activePath != null) {
      saveAutoConfig(_activePath!, newCfg);
    }
    if (_config.tfEnabled) {
      _scheduleTimeFrequencyRefresh(++_navigationSerial);
    }
  }

  void _adjustChannelScale(int visibleIndex, double multiplier) {
    final v = _viewport;
    final eeg = _loadedEeg;
    if (v == null || eeg == null) return;
    final labels = v.signalChannelLabels;
    if (visibleIndex < 0 || visibleIndex >= labels.length) return;
    final label = labels[visibleIndex];

    if (_config.channels.isEmpty) {
      _config.channels = [
        for (var i = 0; i < eeg.channelSamples.length; i++)
          AppConfig.defaultChannelConfig(
            eeg.channelLabels[i],
            i,
            eeg.channelSamples.length,
          ),
      ];
    }

    final chIdx = _config.channels.indexWhere((c) => c.name == label);
    if (chIdx >= 0) {
      final ch = _config.channels[chIdx];
      final newScale = (ch.scalingFactor * multiplier).clamp(10.0, 1000.0);
      ch.scalingFactor = newScale;
      _previewDisplayConfig(_config);
      _setStatus('${ch.name} scale: ${newScale.toStringAsFixed(0)}%');
    }
  }

  void _setChannelScale(int visibleIndex, double newScale) {
    final v = _viewport;
    final eeg = _loadedEeg;
    if (v == null || eeg == null) return;
    final labels = v.signalChannelLabels;
    if (visibleIndex < 0 || visibleIndex >= labels.length) return;
    final label = labels[visibleIndex];

    if (_config.channels.isEmpty) {
      _config.channels = [
        for (var i = 0; i < eeg.channelSamples.length; i++)
          AppConfig.defaultChannelConfig(
            eeg.channelLabels[i],
            i,
            eeg.channelSamples.length,
          ),
      ];
    }

    final chIdx = _config.channels.indexWhere((c) => c.name == label);
    if (chIdx >= 0) {
      final ch = _config.channels[chIdx];
      ch.scalingFactor = newScale.clamp(10.0, 1000.0);
      _previewDisplayConfig(_config);
      _setStatus('${ch.name} scale: ${ch.scalingFactor.toStringAsFixed(0)}%');
    }
  }

  void _applyScaleToAllChannels(double newScale) {
    final eeg = _loadedEeg;
    if (eeg == null) return;
    if (_config.channels.isEmpty) {
      _config.channels = [
        for (var i = 0; i < eeg.channelSamples.length; i++)
          AppConfig.defaultChannelConfig(
            eeg.channelLabels[i],
            i,
            eeg.channelSamples.length,
          ),
      ];
    }
    for (final ch in _config.channels) {
      ch.scalingFactor = newScale.clamp(10.0, 1000.0);
    }
    _previewDisplayConfig(_config);
    _setStatus('All channels scale set to ${newScale.toStringAsFixed(0)}%');
  }

  // ─── Platform menus ───────────────────────────────────────────────────────

  List<PlatformMenuItem> _platformMenus() {
    final appMenuItems = <PlatformMenuItem>[
      if (PlatformProvidedMenuItem.hasMenu(PlatformProvidedMenuItemType.about))
        const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about)
      else
        const PlatformMenuItem(label: 'About CCS Sleep Studio'),
      PlatformMenuItem(
        label: 'Check for Updates…',
        onSelected: _checkForUpdates,
      ),
      if (PlatformProvidedMenuItem.hasMenu(PlatformProvidedMenuItemType.quit))
        const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
    ];

    return [
      PlatformMenu(label: 'CCS Sleep Studio', menus: appMenuItems),
      // ─── Data ─────────────────────────────────────────────────────────
      PlatformMenu(
        label: 'Data',
        menus: [
          PlatformMenuItem(
            label: 'Load EEG Recording (.edf, .eeg, .vhdr, .orb, .mat, .r09, .ebm)…',
            onSelected: () => _openRecording(kind: 'edf'),
          ),
          PlatformMenuItem(
            label: 'Load EDF file (.edf)',
            onSelected: () => _openRecording(kind: 'edf'),
          ),
          PlatformMenuItem(
            label: 'Load Nihon Kohden recording (.eeg, .EEG)',
            onSelected: () => _openRecording(kind: 'nk'),
          ),
          PlatformMenuItem(
            label: 'Load EMBLA / REMlogic recording (.ebm)',
            onSelected: () => _openRecording(kind: 'ebm'),
          ),
          PlatformMenuItem(
            label: 'Load EDF file (.edf) – scaled from V to µV',
            onSelected: () => _openRecording(kind: 'edfvolt'),
          ),
          PlatformMenuItem(
            label: 'Load Orbit file (.orb / .signal)',
            onSelected: () => _openRecording(kind: 'orbit'),
          ),
          PlatformMenuItem(
            label: 'Load EEGLAB structure (.mat)',
            onSelected: () => _openRecording(kind: 'mat'),
          ),
          PlatformMenuItem(
            label: 'Load Zurich data file (.r09)',
            onSelected: () => _openRecording(kind: 'r09'),
          ),
          PlatformMenuItem(
            label: 'Open Synchronized Video…',
            onSelected: _openVideoFile,
          ),
          PlatformMenuItem(
            label: 'Close Current File',
            onSelected: _closeCurrentFile,
          ),
        ],
      ),
      // ─── Scoring ──────────────────────────────────────────────────────
      PlatformMenu(
        label: 'Scoring',
        menus: [
          PlatformMenuItem(
            label: 'Markers & Annotations… [M]',
            onSelected: _openMarkersDialog,
          ),
          PlatformMenuItem(
            label: 'Import scoring… (auto-detect format)',
            onSelected: _loadScoring,
          ),
          PlatformMenuItem(
            label: 'Load Sleeptrip Events (_events.csv)',
            onSelected: _loadSleeptripEvents,
          ),
          if (!buildLite) ...[
            PlatformMenuItem(
              label: 'Run AutoscoreNidra…',
              onSelected: _runAutoScoring,
            ),
            PlatformMenuItem(
              label: 'Apply SleepGPT correction to current hypnogram…',
              onSelected: _applySleepGptToCurrentHypnogram,
            ),
          ],
          PlatformMenuItem(label: 'Save to…', onSelected: _saveScoring),
        ],
      ),
      // ─── Stages ───────────────────────────────────────────────────────
      PlatformMenu(
        label: 'Stages',
        menus: [
          PlatformMenuItem(
            label: 'None  [Delete]',
            onSelected: () => _scoreCurrentEpoch(SleepStage.unknown),
          ),
          PlatformMenuItem(
            label: 'Wake  [W]',
            onSelected: () => _scoreCurrentEpoch(SleepStage.wake),
          ),
          PlatformMenuItem(
            label: 'N1  [1]',
            onSelected: () => _scoreCurrentEpoch(SleepStage.n1),
          ),
          PlatformMenuItem(
            label: 'N2  [2]',
            onSelected: () => _scoreCurrentEpoch(SleepStage.n2),
          ),
          PlatformMenuItem(
            label: 'N3  [3]',
            onSelected: () => _scoreCurrentEpoch(SleepStage.n3),
          ),
          PlatformMenuItem(
            label: 'REM  [R]',
            onSelected: () => _scoreCurrentEpoch(SleepStage.rem),
          ),
          PlatformMenuItem(
            label: 'Inconclusive  [I]',
            onSelected: () => _scoreCurrentEpoch(SleepStage.inconclusive),
          ),
          PlatformMenuItem(
            label: 'Toggle Uncertainty [Q]',
            onSelected: _toggleUncertainty,
          ),
        ],
      ),
      // ─── Events ───────────────────────────────────────────────────────
      PlatformMenu(
        label: 'Events',
        menus: [
          PlatformMenuItem(
            label: '${_eventLabel(0)}  [A]',
            onSelected: () => _markEvent(0),
          ),
          for (var i = 1; i <= 12; i++)
            PlatformMenuItem(
              label: '${_eventLabel(i)}  [F$i / Func $i]',
              onSelected: () => _markEvent(i),
            ),
          PlatformMenuItem(
            label: 'Configure Event Names…',
            onSelected: _showEditEventNamesDialog,
          ),
          PlatformMenuItem(
            label: 'Erase events in drawn selection [Backspace]',
            onSelected: _eraseEventsInSelections,
          ),
          PlatformMenuItem(
            label: 'Delete all events',
            onSelected: _deleteAllEvents,
          ),
        ],
      ),
      // ─── Jump ─────────────────────────────────────────────────────────
      PlatformMenu(
        label: 'Jump',
        menus: [
          PlatformMenuItem(label: 'Next Unscored [U]', onSelected: _jumpNextUnscored),
          PlatformMenuItem(label: 'Next Uncertain [Q]', onSelected: _jumpNextUncertain),
          PlatformMenuItem(label: 'Next Transition [T]', onSelected: _jumpNextTransition),
          PlatformMenuItem(label: 'Next Human [H]', onSelected: _jumpNextHuman),
          PlatformMenuItem(label: 'Next Event [E]', onSelected: _jumpNextEvent),
          PlatformMenuItem(label: 'Next Disagreement [D]', onSelected: _jumpNextDisagreement),
        ],
      ),
      // ─── Utilities ────────────────────────────────────────────────────
      PlatformMenu(
        label: 'Utilities',
        menus: [
          if (!buildLite) ...[
            PlatformMenuItem(
              label: 'AnalyseNidra — Advanced Sleep EEG Analysis…',
              onSelected: _runAnalyseNidraCurrent,
            ),
          ],
          PlatformMenuItem(
            label: 'K-Complex Detection (MT-KCD)  [Ctrl+K]',
            onSelected: _runKComplexDetection,
          ),
          PlatformMenuItem(
            label: 'Spindle Detection (MT-Spindle)  [Ctrl+Shift+S]',
            onSelected: _runSpindleDetection,
          ),
          PlatformMenuItem(
            label: 'AnalyseNidra Detection (Spindles & Slow-Waves)…',
            onSelected: _runAnalyseNidraDetection,
          ),
          PlatformMenuItem(
            label: 'Respiratory / OSA Analysis (AASM)…',
            onSelected: _runRespiratoryAnalysis,
          ),
          PlatformMenuItem(
            label: 'Periodic Limb Movement (PLMS) Analysis…',
            onSelected: _runPlmAnalysis,
          ),
          PlatformMenuItem(
            label: 'Cyclic Alternating Pattern (CAP) Analysis…',
            onSelected: _runCapAnalysis,
          ),
          PlatformMenuItem(
            label: 'Show / Remove OSA, PLM & CAP Markers…',
            onSelected: _managePsgMarkers,
          ),
          PlatformMenuItem(
            label: 'Find similar epochs from current epoch…',
            onSelected: _showSimilarEpochDialog,
          ),
          PlatformMenuItem(
            label: 'Zoom on selected EEG  [Z]',
            onSelected: _zoomOnSelectedEeg,
          ),
          PlatformMenuItem(
            label: 'EEG Utilities Module (Reduce, Crop, Rename, Anonymize & Batch)…',
            onSelected: _openEdfUtilitiesDialog,
          ),
          PlatformMenuItem(
            label: 'Auto electric stim artefact removal (DBS)…',
            onSelected: _openStimArtifactRemovalDialog,
          ),
          PlatformMenuItem(
            label: 'Preprocessing Pipeline (Filters, RANSAC, GEDAI)…',
            onSelected: _openPreprocessDialog,
          ),
          PlatformMenuItem(
            label: 'Feature Selection & Extraction Parameters…',
            onSelected: _openFeatureSelectionAndConfigDialog,
          ),
          PlatformMenuItem(
            label: 'Export Sleep Report (PDF)',
            onSelected: _exportSleepReport,
          ),
        ],
      ),
      // ─── Compare ──────────────────────────────────────────────────────
      PlatformMenu(
        label: 'Compare',
        menus: [
          PlatformMenuItem(
            label: 'Import comparison scoring… (auto-detect format)',
            onSelected: _loadComparisonScoring,
          ),
          PlatformMenuItem(
            label: 'Remove comparison scoring',
            onSelected: _removeComparisonScoring,
          ),
          PlatformMenuItem(
            label: 'Show summary statistics',
            onSelected: _showComparisonStats,
          ),
          PlatformMenuItem(
            label: 'Compare multiple scorings (choose reference)…',
            onSelected: _showMultiScoringComparison,
          ),
        ],
      ),
      // ─── Configuration ────────────────────────────────────────────────
      PlatformMenu(
        label: 'Configuration',
        menus: [
          PlatformMenuItem(
            label: 'Open configuration window  [Ctrl+C]',
            onSelected: _openConfigDialog,
          ),
          PlatformMenuItem(
            label: 'Feature Selection & Parameter Configuration…',
            onSelected: _openFeatureSelectionAndConfigDialog,
          ),
          PlatformMenuItem(
            label: 'Save configuration as .json',
            onSelected: _saveConfig,
          ),
          PlatformMenuItem(
            label: 'Load configuration from .json',
            onSelected: _loadConfig,
          ),
          PlatformMenuItem(
            label: 'Restore default configuration',
            onSelected: () {
              final eeg = _loadedEeg;
              final v = _viewport;
              if (eeg != null && v != null) {
                _backend.clearDisplayCache();
                final defaultConfig = AppConfig.defaultsForChannels(
                  eeg.channelLabels,
                  sampleRateHz: eeg.sampleRateHz,
                );
                setState(() {
                  _config = defaultConfig;
                });
                _setStatus('Restoring default configuration…');
                Future.microtask(() async {
                  final newEeg = await _backend.computeNightProducts(
                    eeg,
                    defaultConfig,
                  );
                  final newViewport = await _backend.viewportFromEeg(
                    newEeg,
                    currentEpoch: v.currentEpoch,
                    config: defaultConfig,
                    existingStages: v.stages,
                    existingStagesUncertain: v.stagesUncertain,
                    existingConfidence: v.stagesConfidence,
                    existingStageProbabilities: v.stageProbabilities,
                    includeTimeFrequency: false,
                  );
                  if (mounted) {
                    setState(() {
                      _loadedEeg = newEeg;
                      _viewport = newViewport;
                      _status = 'Default configuration restored';
                    });
                    if (_config.tfEnabled) {
                      _scheduleTimeFrequencyRefresh(++_navigationSerial);
                    }
                  }
                });
              }
            },
          ),
        ],
      ),
      // ─── View ─────────────────────────────────────────────────────────
      PlatformMenu(
        label: 'View',
        menus: [
          PlatformMenuItem(
            label: 'Markers & Annotations… [M]',
            onSelected: _openMarkersDialog,
          ),
          PlatformMenuItem(
            label: _waveformMaximized
                ? 'Restore View Panels  [F]'
                : 'Maximize Waveform Plot  [F]',
            onSelected: () {
              setState(() => _waveformMaximized = !_waveformMaximized);
            },
          ),
          PlatformMenuItem(
            label: 'Toggle Synchronized Video [V]',
            onSelected: () {
              if (_videoController == null) {
                _openVideoFile();
              } else {
                setState(() => _videoPanelVisible = !_videoPanelVisible);
              }
            },
          ),
        ],
      ),
      // ─── Help ─────────────────────────────────────────────────────────
      PlatformMenu(
        label: 'Help',
        menus: [
          PlatformMenuItem(
            label: 'Check for Updates…',
            onSelected: _checkForUpdates,
          ),
          PlatformMenuItem(
            label: 'Signal selection box  [Ctrl+H]',
            onSelected: _showSelectionHelp,
          ),
          PlatformMenuItem(
            label: 'Release Download Statistics',
            onSelected: _showDownloadStats,
          ),
        ],
      ),
    ];
  }

  Widget _buildInAppMenuBar() {
    return Container(
      color: Colors.white,
      width: double.infinity,
      child: MenuBar(
        style: MenuStyle(
          elevation: MaterialStateProperty.all(0),
          backgroundColor: MaterialStateProperty.all(Colors.white),
        ),
        children: [
          SubmenuButton(
            menuChildren: [
              MenuItemButton(
                onPressed: () => _openRecording(kind: 'edf'),
                child: const Text('Load EEG Recording (.edf, .eeg, .vhdr, .orb, .mat, .r09, .ebm)…'),
              ),
              MenuItemButton(
                onPressed: () => _openRecording(kind: 'edf'),
                child: const Text('Load EDF file (.edf)'),
              ),
              MenuItemButton(
                onPressed: () => _openRecording(kind: 'nk'),
                child: const Text('Load Nihon Kohden recording (.eeg, .EEG)'),
              ),
              MenuItemButton(
                onPressed: () => _openRecording(kind: 'ebm'),
                child: const Text('Load EMBLA / REMlogic recording (.ebm)'),
              ),
              MenuItemButton(
                onPressed: () => _openRecording(kind: 'edfvolt'),
                child: const Text('Load EDF file (.edf) – scaled V to µV'),
              ),
              MenuItemButton(
                onPressed: () => _openRecording(kind: 'orbit'),
                child: const Text('Load Orbit file (.orb / .signal)'),
              ),
              MenuItemButton(
                onPressed: () => _openRecording(kind: 'mat'),
                child: const Text('Load EEGLAB structure (.mat)'),
              ),
              MenuItemButton(
                onPressed: () => _openRecording(kind: 'r09'),
                child: const Text('Load Zurich data file (.r09)'),
              ),
              MenuItemButton(
                onPressed: _openVideoFile,
                child: const Text('Open Synchronized Video…'),
              ),
              const Divider(height: 1),
              MenuItemButton(
                onPressed: _closeCurrentFile,
                child: const Text('Close Current File'),
              ),
            ],
            child: const Text('Data'),
          ),
          SubmenuButton(
            menuChildren: [
              MenuItemButton(
                onPressed: _openMarkersDialog,
                child: const Text('Markers & Annotations… [M]'),
              ),
              MenuItemButton(
                onPressed: _loadScoring,
                child: const Text('Import scoring… (auto-detect format)'),
              ),
              MenuItemButton(
                onPressed: _loadSleeptripEvents,
                child: const Text('Load Sleeptrip Events (_events.csv)'),
              ),
              if (!buildLite) ...[
                MenuItemButton(
                  onPressed: _runAutoScoring,
                  child: const Text('Run AutoscoreNidra…'),
                ),
                MenuItemButton(
                  onPressed: _applySleepGptToCurrentHypnogram,
                  child: const Text(
                    'Apply SleepGPT correction to current hypnogram…',
                  ),
                ),
              ],
              const Divider(height: 1),
              MenuItemButton(
                onPressed: _saveScoring,
                child: const Text('Save to…'),
              ),
            ],
            child: const Text('Scoring'),
          ),
          SubmenuButton(
            menuChildren: [
              MenuItemButton(
                onPressed: () => _scoreCurrentEpoch(SleepStage.unknown),
                child: const Text('None  [Delete]'),
              ),
              MenuItemButton(
                onPressed: () => _scoreCurrentEpoch(SleepStage.wake),
                child: const Text('Wake  [W]'),
              ),
              MenuItemButton(
                onPressed: () => _scoreCurrentEpoch(SleepStage.n1),
                child: const Text('N1  [1]'),
              ),
              MenuItemButton(
                onPressed: () => _scoreCurrentEpoch(SleepStage.n2),
                child: const Text('N2  [2]'),
              ),
              MenuItemButton(
                onPressed: () => _scoreCurrentEpoch(SleepStage.n3),
                child: const Text('N3  [3]'),
              ),
              MenuItemButton(
                onPressed: () => _scoreCurrentEpoch(SleepStage.rem),
                child: const Text('REM  [R]'),
              ),
              MenuItemButton(
                onPressed: () => _scoreCurrentEpoch(SleepStage.inconclusive),
                child: const Text('Inconclusive  [I]'),
              ),
              const Divider(height: 1),
              MenuItemButton(
                onPressed: _toggleUncertainty,
                child: const Text('Toggle Uncertainty [Q]'),
              ),
            ],
            child: const Text('Stages'),
          ),
          SubmenuButton(
            menuChildren: [
              MenuItemButton(
                onPressed: () => _markEvent(0),
                child: Text('${_eventLabel(0)}  [A]'),
              ),
              for (var i = 1; i <= 12; i++)
                MenuItemButton(
                  onPressed: () => _markEvent(i),
                  child: Text('${_eventLabel(i)}  [F$i / Func $i]'),
                ),
              const Divider(height: 1),
              MenuItemButton(
                onPressed: _showEditEventNamesDialog,
                child: const Text('Configure Event Names…'),
              ),
              const Divider(height: 1),
              MenuItemButton(
                onPressed: _eraseEventsInSelections,
                child: const Text(
                  'Erase events in drawn selection [Backspace]',
                ),
              ),
              MenuItemButton(
                onPressed: _deleteAllEvents,
                child: const Text('Delete all events'),
              ),
            ],
            child: const Text('Events'),
          ),
          SubmenuButton(
            menuChildren: [
              if (!buildLite) ...[
                MenuItemButton(
                  onPressed: _runAnalyseNidraCurrent,
                  child: const Text(
                    'AnalyseNidra — Advanced Sleep EEG Analysis…',
                  ),
                ),
                const Divider(height: 1),
              ],
              MenuItemButton(
                onPressed: _runKComplexDetection,
                child: const Text('K-Complex Detection (MT-KCD) [Ctrl+K]'),
              ),
              MenuItemButton(
                onPressed: _runSpindleDetection,
                child: const Text(
                  'Spindle Detection (MT-Spindle) [Ctrl+Shift+S]',
                ),
              ),
              MenuItemButton(
                onPressed: _runAnalyseNidraDetection,
                child: const Text(
                  'AnalyseNidra Detection (Spindles & Slow-Waves)…',
                ),
              ),
              MenuItemButton(
                onPressed: _runRespiratoryAnalysis,
                child: const Text('Respiratory / OSA Analysis (AASM)…'),
              ),
              MenuItemButton(
                onPressed: _runPlmAnalysis,
                child: const Text('Periodic Limb Movement (PLMS) Analysis…'),
              ),
              MenuItemButton(
                onPressed: _runCapAnalysis,
                child: const Text('Cyclic Alternating Pattern (CAP) Analysis…'),
              ),
              MenuItemButton(
                onPressed: _managePsgMarkers,
                child: const Text('Show / Remove OSA, PLM & CAP Markers…'),
              ),
              MenuItemButton(
                onPressed: _showSimilarEpochDialog,
                child: const Text('Find similar epochs from current epoch…'),
              ),
              MenuItemButton(
                onPressed: _zoomOnSelectedEeg,
                child: const Text('Zoom on selected EEG [Z]'),
              ),
              MenuItemButton(
                onPressed: _openEdfUtilitiesDialog,
                child: const Text('EEG Utilities Module (Crop, Downsample, Rename, Anonymize & Batch)…'),
              ),
              MenuItemButton(
                onPressed: _openStimArtifactRemovalDialog,
                child: const Text('Auto electric stim artefact removal (DBS)…'),
              ),
              MenuItemButton(
                onPressed: _openPreprocessDialog,
                child: const Text('Preprocessing Pipeline (Filters, RANSAC, GEDAI)…'),
              ),
              MenuItemButton(
                onPressed: _openFeatureSelectionAndConfigDialog,
                child: const Text('Feature Selection & Extraction Parameters…'),
              ),
              MenuItemButton(
                onPressed: _exportSleepReport,
                child: const Text('Export Sleep Report (PDF)'),
              ),
            ],
            child: const Text('Utilities'),
          ),
          SubmenuButton(
            menuChildren: [
              MenuItemButton(
                onPressed: _loadComparisonScoring,
                child: const Text(
                  'Import comparison scoring… (auto-detect format)',
                ),
              ),
              MenuItemButton(
                onPressed: _removeComparisonScoring,
                child: const Text('Remove comparison scoring'),
              ),
              MenuItemButton(
                onPressed: _showComparisonStats,
                child: const Text('Show summary statistics'),
              ),
              MenuItemButton(
                onPressed: _showMultiScoringComparison,
                child: const Text('Compare multiple scorings (choose reference)…'),
              ),
            ],
            child: const Text('Compare'),
          ),
          SubmenuButton(
            menuChildren: [
              MenuItemButton(
                onPressed: _openConfigDialog,
                child: const Text('Open Settings Dialog [Ctrl+,]'),
              ),
              MenuItemButton(
                onPressed: _openFeatureSelectionAndConfigDialog,
                child: const Text('Feature Selection & Parameter Configuration…'),
              ),
              MenuItemButton(
                onPressed: _saveConfig,
                child: const Text('Save configuration as .json'),
              ),
              MenuItemButton(
                onPressed: _loadConfig,
                child: const Text('Load configuration from .json'),
              ),
              MenuItemButton(
                onPressed: () {
                  final eeg = _loadedEeg;
                  final v = _viewport;
                  if (eeg != null && v != null) {
                    _backend.clearDisplayCache();
                    final defaultConfig = AppConfig.defaultsForChannels(
                      eeg.channelLabels,
                      sampleRateHz: eeg.sampleRateHz,
                    );
                    setState(() {
                      _config = defaultConfig;
                    });
                    _setStatus('Restoring default configuration…');
                    Future.microtask(() async {
                      final newEeg = await _backend.computeNightProducts(
                        eeg,
                        defaultConfig,
                      );
                      final newViewport = await _backend.viewportFromEeg(
                        newEeg,
                        currentEpoch: v.currentEpoch,
                        config: defaultConfig,
                        existingStages: v.stages,
                        existingStagesUncertain: v.stagesUncertain,
                        existingConfidence: v.stagesConfidence,
                        existingStageProbabilities: v.stageProbabilities,
                        includeTimeFrequency: false,
                      );
                      if (mounted) {
                        setState(() {
                          _loadedEeg = newEeg;
                          _viewport = newViewport;
                          _status = 'Default configuration restored';
                        });
                        if (_config.tfEnabled) {
                          _scheduleTimeFrequencyRefresh(++_navigationSerial);
                        }
                      }
                    });
                  }
                },
                child: const Text('Restore default configuration'),
              ),
            ],
            child: const Text('Configuration'),
          ),
          SubmenuButton(
            menuChildren: [
              MenuItemButton(
                onPressed: _checkForUpdates,
                child: const Text('Check for Updates…'),
              ),
              const Divider(height: 1),
              MenuItemButton(
                onPressed: _showSelectionHelp,
                child: const Text('Signal selection box  [Ctrl+H]'),
              ),
              MenuItemButton(
                onPressed: _showDownloadStats,
                child: const Text('Release Download Statistics'),
              ),
            ],
            child: const Text('Help'),
          ),
        ],
      ),
    );
  }

  Widget _batchPsgField(TextEditingController c, String label, String title) {
    final first = _batchPsgPairs.isEmpty ? null : _batchPsgPairs.first['eegPath'];
    return SizedBox(
      width: 250,
      child: TextField(
        controller: c,
        decoration: InputDecoration(
          labelText: label,
          hintText: 'blank = auto-detect',
          isDense: true,
          border: const OutlineInputBorder(),
          suffixIcon: _batchChannelPickerButton(c, first, title),
        ),
      ),
    );
  }

  void _addBatchPsgRecordings(List<String> files) {
    if (files.isEmpty) return;
    final postfix = _batchPsgPostfixController.text.trim();
    setState(() {
      for (final f in files) {
        if (_batchPsgPairs.any((p) => p['eegPath'] == f)) continue;
        _batchPsgPairs.add({
          'eegPath': f,
          'scoringPath': _batchPsgAutoLoadScorings ? _findScoringForRecording(f, postfix) : '',
        });
      }
    });
  }

  void _executeBatchPreprocessing() {
    if (_batchPreprocessFiles.isEmpty) {
      _setStatus('Please select at least one recording for batch preprocessing.');
      return;
    }
    final steps = <String>[];
    if (_batchPreprocessStimArtifact) steps.add('stimartifact');
    if (_batchPreprocessDownsample) steps.add('downsample');
    if (_batchPreprocessFilter) steps.add('filter');
    if (_batchPreprocessBadChannel) steps.add('badchannel');
    if (_batchPreprocessGedai) steps.add('gedai');
    if (_batchPreprocessInterpolate) steps.add('interpolate');

    if (steps.isEmpty) {
      _setStatus('Please select at least one preprocessing step.');
      return;
    }

    final executable = detectAnalyseNidraExecutable();
    final suffix = _batchPreprocessSuffixController.text.trim().isEmpty
        ? (_batchPreprocessStimArtifact && steps.length == 1 ? '_stimclean' : '_clean')
        : _batchPreprocessSuffixController.text.trim();
    final outDir = _batchPreprocessOutDirController.text.trim().isEmpty
        ? null
        : _batchPreprocessOutDirController.text.trim();
    final f0 = double.tryParse(_batchPreprocessStimF0Controller.text.trim());

    final jobs = _batchPreprocessFiles.map((file) {
      final args = <String>[
        '--preprocess',
        file,
        '--steps',
        steps.join(','),
        '--suffix',
        suffix,
      ];
      if (outDir != null) args.addAll(['--out-dir', outDir]);
      if (_batchPreprocessStimArtifact && f0 != null && f0 > 0) {
        args.addAll(['--stim-f0', f0.toString()]);
      }
      return _CommandJob(
        label: _basename(file),
        executable: executable,
        sourcePath: file,
        outputDir: outDir,
        arguments: args,
      );
    }).toList();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CommandBatchProgressDialog(
        title: 'Batch Preprocessing',
        jobs: jobs,
        onFinished: (failed) {
          _setStatus(
            failed == 0
                ? 'Batch preprocessing finished for ${jobs.length} recording(s)'
                : 'Batch preprocessing finished: ${jobs.length - failed} succeeded, $failed failed',
          );
        },
      ),
    );
  }

  Widget _buildBatchPreprocessingCard() {
    final anyStep = _batchPreprocessStimArtifact ||
        _batchPreprocessDownsample ||
        _batchPreprocessFilter ||
        _batchPreprocessBadChannel ||
        _batchPreprocessGedai ||
        _batchPreprocessInterpolate;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFFD0D0D0)),
      ),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.cleaning_services, color: Colors.purple),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Batch Preprocessing & Artefact Removal (DBS / ccstools / GEDAI)',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            const Text(
              'Selected Recordings to Preprocess:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Container(
              height: 140,
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFD0D0D0)),
                borderRadius: BorderRadius.circular(4),
                color: const Color(0xFFF9F9F9),
              ),
              child: _batchPreprocessFiles.isEmpty
                  ? const Center(child: Text('No recordings selected'))
                  : ListView.builder(
                      itemCount: _batchPreprocessFiles.length,
                      itemBuilder: (context, index) {
                        final file = _batchPreprocessFiles[index];
                        return ListTile(
                          dense: true,
                          title: Text(_basename(file)),
                          subtitle: Text(file),
                          trailing: IconButton(
                            icon: const Icon(Icons.close, size: 16, color: Colors.red),
                            tooltip: 'Remove',
                            onPressed: () => setState(() => _batchPreprocessFiles.removeAt(index)),
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
            _batchSourceControls(
              onAddFiles: () async {
                final files = await _collectBatchRecordings(
                  fromFolder: false,
                  extensions: _batchAutoscoreExtensions,
                  recursive: _batchPreprocessRecursive,
                  useWildcard: _batchPreprocessUseWildcard,
                  pattern: _batchPreprocessWildcardController.text,
                  title: 'Select recordings for batch preprocessing',
                );
                if (mounted) {
                  setState(() {
                    for (final f in files) {
                      if (!_batchPreprocessFiles.contains(f)) _batchPreprocessFiles.add(f);
                    }
                  });
                }
              },
              onAddFolder: () async {
                final files = await _collectBatchRecordings(
                  fromFolder: true,
                  extensions: _batchAutoscoreExtensions,
                  recursive: _batchPreprocessRecursive,
                  useWildcard: _batchPreprocessUseWildcard,
                  pattern: _batchPreprocessWildcardController.text,
                  title: 'Select a folder of recordings for batch preprocessing',
                );
                if (mounted) {
                  setState(() {
                    for (final f in files) {
                      if (!_batchPreprocessFiles.contains(f)) _batchPreprocessFiles.add(f);
                    }
                  });
                }
              },
              hasItems: _batchPreprocessFiles.isNotEmpty,
              onSelectDeselect: () async {
                final selected = await showBatchFileSubSelectionDialog(
                  context: context,
                  title: 'Batch Preprocessing File Selection',
                  files: List<String>.from(_batchPreprocessFiles),
                );
                if (selected != null && mounted) {
                  setState(() {
                    _batchPreprocessFiles
                      ..clear()
                      ..addAll(selected);
                  });
                }
              },
              onClear: () => setState(_batchPreprocessFiles.clear),
              recursive: _batchPreprocessRecursive,
              onRecursive: (v) => setState(() => _batchPreprocessRecursive = v),
              useWildcard: _batchPreprocessUseWildcard,
              onWildcard: (v) => setState(() => _batchPreprocessUseWildcard = v),
              wildcardController: _batchPreprocessWildcardController,
            ),
            const SizedBox(height: 16),
            const Text(
              'Pipeline Steps to Apply:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            // Stimulation Artefact Removal
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.amber.shade50.withOpacity(0.6),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.amber.shade300),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Checkbox(
                        value: _batchPreprocessStimArtifact,
                        onChanged: (v) => setState(() {
                          _batchPreprocessStimArtifact = v ?? false;
                          if (_batchPreprocessStimArtifact && !_batchPreprocessGedai) {
                            if (_batchPreprocessSuffixController.text == '_clean') {
                              _batchPreprocessSuffixController.text = '_stimclean';
                            }
                          }
                        }),
                      ),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Auto electric stim artefact removal (DBS / neurostimulator)',
                              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
                            ),
                            Text(
                              'Continuous file — adaptive harmonic comb filter (performed on the continuous signal, NOT on epochs as in GEDAI)',
                              style: TextStyle(fontSize: 11, color: Colors.black87),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: 170,
                        child: TextFormField(
                          controller: _batchPreprocessStimF0Controller,
                          decoration: const InputDecoration(
                            labelText: 'Artefact Freq (Hz)',
                            hintText: 'blank = auto-detect',
                            isDense: true,
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          ),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _batchOptionCheckbox('Downsample to 250 Hz', _batchPreprocessDownsample, (v) => setState(() => _batchPreprocessDownsample = v)),
                _batchOptionCheckbox('Bandpass & Notch Filter (0.5–40 Hz, 50 Hz)', _batchPreprocessFilter, (v) => setState(() => _batchPreprocessFilter = v)),
                _batchOptionCheckbox('Bad Channel Detection (RANSAC)', _batchPreprocessBadChannel, (v) => setState(() => _batchPreprocessBadChannel = v)),
                _batchOptionCheckbox('GEDAI Artifact Denoising (Epoch Leadfield GED)', _batchPreprocessGedai, (v) => setState(() => _batchPreprocessGedai = v)),
                _batchOptionCheckbox('Interpolate Bad Channels (Spherical Spline)', _batchPreprocessInterpolate, (v) => setState(() => _batchPreprocessInterpolate = v)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 220,
                  child: TextFormField(
                    controller: _batchPreprocessSuffixController,
                    decoration: const InputDecoration(
                      labelText: 'Output Filename Suffix',
                      hintText: '_clean or _stimclean',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _batchPreprocessOutDirController,
                    decoration: const InputDecoration(
                      labelText: 'Output Folder (optional — default: same as source)',
                      hintText: 'Leave blank to save next to source recording',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.folder_open),
                  tooltip: 'Select Output Directory',
                  onPressed: () async {
                    final dir = await FilePicker.getDirectoryPath(
                      dialogTitle: 'Select Output Folder for Cleaned Recordings',
                    );
                    if (dir != null) {
                      setState(() => _batchPreprocessOutDirController.text = dir);
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 40,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('Run Batch Preprocessing', style: TextStyle(fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.purple.shade700,
                  foregroundColor: Colors.white,
                ),
                onPressed: _batchPreprocessFiles.isEmpty || !anyStep ? null : _executeBatchPreprocessing,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBatchPsgCard() {
    final anyAnalysis = _batchPsgRespiratory || _batchPsgPlm || _batchPsgCap;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFFD0D0D0)),
      ),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.monitor_heart, color: Colors.teal),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'PSG Batch Analysis — Respiratory (OSA), PLM and CAP',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            const Text(
              'Recordings and their scoring files (a hypnogram is needed for AHI/PLMS indices and for CAP):',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Container(
              height: 140,
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFD0D0D0)),
                borderRadius: BorderRadius.circular(4),
                color: const Color(0xFFF9F9F9),
              ),
              child: _batchPsgPairs.isEmpty
                  ? const Center(child: Text('No recordings selected'))
                  : ListView.builder(
                      itemCount: _batchPsgPairs.length,
                      itemBuilder: (context, index) {
                        final pair = _batchPsgPairs[index];
                        final scoring = pair['scoringPath'] ?? '';
                        return ListTile(
                          dense: true,
                          title: Text(_basename(pair['eegPath'] ?? '')),
                          subtitle: Text(
                            scoring.isEmpty
                                ? 'Scoring: not found — click the pencil to choose'
                                : 'Scoring: ${_basename(scoring)}',
                            style: scoring.isEmpty ? const TextStyle(color: Colors.deepOrange) : null,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit, size: 16, color: Colors.grey),
                                tooltip: 'Select scoring file',
                                onPressed: () async {
                                  final result = await FilePicker.pickFiles(
                                    dialogTitle: 'Select scoring JSON file',
                                    type: FileType.custom,
                                    allowedExtensions: ['json'],
                                  );
                                  final picked = result?.files.single.path;
                                  if (picked != null) {
                                    setState(() => pair['scoringPath'] = picked);
                                  }
                                },
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete, size: 16, color: Colors.red),
                                onPressed: () => setState(() => _batchPsgPairs.removeAt(index)),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
            _batchSourceControls(
              onAddFiles: () async {
                final files = await _collectBatchRecordings(
                  fromFolder: false,
                  extensions: _batchAutoscoreExtensions,
                  recursive: _batchPsgRecursive,
                  useWildcard: _batchPsgUseWildcard,
                  pattern: _batchPsgWildcardController.text,
                  title: 'Select PSG recordings',
                );
                if (mounted) _addBatchPsgRecordings(files);
              },
              onAddFolder: () async {
                final files = await _collectBatchRecordings(
                  fromFolder: true,
                  extensions: _batchAutoscoreExtensions,
                  recursive: _batchPsgRecursive,
                  useWildcard: _batchPsgUseWildcard,
                  pattern: _batchPsgWildcardController.text,
                  title: 'Select a folder of PSG recordings',
                );
                if (mounted) _addBatchPsgRecordings(files);
              },
              hasItems: _batchPsgPairs.isNotEmpty,
              onSelectDeselect: () async {
                final selected = await showBatchFileSubSelectionDialog(
                  context: context,
                  title: 'PSG Batch File Selection',
                  files: [for (final p in _batchPsgPairs) p['eegPath'] ?? ''],
                );
                if (selected != null && mounted) {
                  final keep = selected.toSet();
                  setState(() => _batchPsgPairs.removeWhere((p) => !keep.contains(p['eegPath'])));
                }
              },
              onClear: () => setState(_batchPsgPairs.clear),
              recursive: _batchPsgRecursive,
              onRecursive: (v) => setState(() => _batchPsgRecursive = v),
              useWildcard: _batchPsgUseWildcard,
              onWildcard: (v) => setState(() => _batchPsgUseWildcard = v),
              wildcardController: _batchPsgWildcardController,
              extraOptions: [
                _batchOptionCheckbox('Auto-load scorings', _batchPsgAutoLoadScorings, (v) {
                  setState(() => _batchPsgAutoLoadScorings = v);
                  if (v) {
                    final postfix = _batchPsgPostfixController.text.trim();
                    setState(() {
                      for (final pair in _batchPsgPairs) {
                        if ((pair['scoringPath'] ?? '').isEmpty) {
                          pair['scoringPath'] = _findScoringForRecording(pair['eegPath'] ?? '', postfix);
                        }
                      }
                    });
                  }
                }),
                if (_batchPsgAutoLoadScorings)
                  SizedBox(
                    width: 170,
                    child: TextField(
                      controller: _batchPsgPostfixController,
                      decoration: const InputDecoration(
                        labelText: 'Scoring postfix',
                        hintText: 'e.g. _scoring',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('Analyses', style: TextStyle(fontWeight: FontWeight.bold)),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 16,
              runSpacing: 8,
              children: [
                _batchOptionCheckbox('Respiratory / OSA (AASM)', _batchPsgRespiratory,
                    (v) => setState(() => _batchPsgRespiratory = v)),
                SizedBox(
                  width: 190,
                  child: DropdownButtonFormField<int>(
                    value: _batchPsgHypopneaRule,
                    isExpanded: true,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: 'Hypopnea rule',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 3, child: Text('1A (3%/arousal)')),
                      DropdownMenuItem(value: 4, child: Text('1B (4%)')),
                    ],
                    onChanged: (v) => setState(() => _batchPsgHypopneaRule = v ?? 3),
                  ),
                ),
                _batchOptionCheckbox('Periodic limb movements', _batchPsgPlm,
                    (v) => setState(() => _batchPsgPlm = v)),
                SizedBox(
                  width: 170,
                  child: DropdownButtonFormField<String>(
                    value: _batchPsgPlmStandard,
                    isExpanded: true,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: 'PLM standard',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'aasm', child: Text('AASM v3')),
                      DropdownMenuItem(value: 'wasm', child: Text('WASM 2016')),
                    ],
                    onChanged: (v) => setState(() => _batchPsgPlmStandard = v ?? 'aasm'),
                  ),
                ),
                _batchOptionCheckbox('Cyclic alternating pattern', _batchPsgCap,
                    (v) => setState(() => _batchPsgCap = v)),
                SizedBox(
                  width: 190,
                  child: DropdownButtonFormField<String>(
                    value: _batchPsgCapSensitivity,
                    isExpanded: true,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: 'CAP detector',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'conservative', child: Text('Conservative')),
                      DropdownMenuItem(value: 'standard', child: Text('Standard')),
                      DropdownMenuItem(value: 'sensitive', child: Text('Sensitive')),
                    ],
                    onChanged: (v) => setState(() => _batchPsgCapSensitivity = v ?? 'standard'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              _batchPsgPairs.isEmpty
                  ? 'Channels (optional — detected automatically in each recording)'
                  : 'Channels (optional — lists come from the first recording: ${_basename(_batchPsgPairs.first['eegPath'] ?? '')})',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _batchPsgField(_batchPsgPressureController, 'Nasal pressure', 'Select nasal pressure channel'),
                _batchPsgField(_batchPsgThermalController, 'Oronasal thermal', 'Select thermal airflow channel'),
                _batchPsgField(_batchPsgSpo2Controller, 'SpO₂', 'Select SpO2 channel'),
                _batchPsgField(_batchPsgLeftLegController, 'Left leg EMG', 'Select left tibialis channel'),
                _batchPsgField(_batchPsgRightLegController, 'Right leg EMG', 'Select right tibialis channel'),
                _batchPsgField(_batchPsgCapEegController, 'CAP EEG', 'Select EEG channel for CAP'),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _batchPsgOutDirController,
                    decoration: const InputDecoration(
                      labelText: 'Folder for the batch summary CSV and logs (optional — default: first recording\'s folder)',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.folder_open),
                  tooltip: 'Select folder',
                  onPressed: () async {
                    final dir = await FilePicker.getDirectoryPath(dialogTitle: 'Folder for the PSG batch summary');
                    if (dir != null) setState(() => _batchPsgOutDirController.text = dir);
                  },
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Per-recording results are saved beside each recording (…_respiratory.json, …_plm.json, …_cap.json) so they appear as markers '
              '(Utilities → Show / Remove OSA, PLM & CAP Markers) and in the PDF report.',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 40,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                ),
                onPressed: _batchPsgPairs.isEmpty || !anyAnalysis ? null : _runBatchPsg,
                child: const Text('Run PSG Batch Analysis', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _runBatchPsg() {
    if (!isAnalyseNidraAvailable()) {
      _showTextDialog(
        'PSG batch analysis unavailable',
        'The native analyse-nidra engine was not found beside the application.',
      );
      return;
    }
    String? opt(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    final settings = _BatchPsgSettings(
      respiratory: _batchPsgRespiratory,
      plm: _batchPsgPlm,
      cap: _batchPsgCap,
      hypopneaRule: _batchPsgHypopneaRule,
      plmStandard: _batchPsgPlmStandard,
      capSensitivity: _batchPsgCapSensitivity,
      pressure: opt(_batchPsgPressureController),
      thermal: opt(_batchPsgThermalController),
      spo2: opt(_batchPsgSpo2Controller),
      leftLeg: opt(_batchPsgLeftLegController),
      rightLeg: opt(_batchPsgRightLegController),
      capEeg: opt(_batchPsgCapEegController),
      outputDir: opt(_batchPsgOutDirController),
    );
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _BatchPsgDialog(
        jobs: [for (final p in _batchPsgPairs) Map<String, String>.from(p)],
        settings: settings,
      ),
    );
  }

  Widget _buildBatchProcessingTab() {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: math.max(1080, constraints.maxWidth - 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                // Left Column: Batch Auto-Scoring
                if (!buildLite) ...[
                  Expanded(
                    child: Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: const BorderSide(color: Color(0xFFD0D0D0)),
                      ),
                      color: Colors.white,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.psychology, color: Colors.purple),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'AutoscoreNidra — Batch Automated Sleep Scoring',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const Divider(height: 24),
                            const Text(
                              'Selected Recording Files (EDF/EEG/VHDR/ORB/EBM/MAT/R09):',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              height: 150,
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: const Color(0xFFD0D0D0),
                                ),
                                borderRadius: BorderRadius.circular(4),
                                color: const Color(0xFFF9F9F9),
                              ),
                              child: _batchStagingFiles.isEmpty
                                  ? const Center(
                                      child: Text('No files selected'),
                                    )
                                  : ListView.builder(
                                      itemCount: _batchStagingFiles.length,
                                      itemBuilder: (context, index) {
                                        final f = _batchStagingFiles[index];
                                        return ListTile(
                                          dense: true,
                                          title: Text(_basename(f)),
                                          subtitle: Text(f),
                                          trailing: IconButton(
                                            icon: const Icon(
                                              Icons.delete,
                                              size: 16,
                                              color: Colors.red,
                                            ),
                                            onPressed: () {
                                              setState(() {
                                                _batchStagingFiles.removeAt(
                                                  index,
                                                );
                                              });
                                            },
                                          ),
                                        );
                                      },
                                    ),
                            ),
                            const SizedBox(height: 8),
                            _batchSourceControls(
                              onAddFiles: () async {
                                final files = await _collectBatchRecordings(
                                  fromFolder: false,
                                  extensions: _batchAutoscoreExtensions,
                                  recursive: _batchStagingRecursive,
                                  useWildcard: _batchStagingUseWildcard,
                                  pattern: _batchStagingWildcardController.text,
                                  title: 'Select recordings for batch AutoscoreNidra',
                                );
                                if (files.isEmpty || !mounted) return;
                                setState(() {
                                  for (final f in files) {
                                    if (!_batchStagingFiles.contains(f)) _batchStagingFiles.add(f);
                                  }
                                });
                              },
                              onAddFolder: () async {
                                final files = await _collectBatchRecordings(
                                  fromFolder: true,
                                  extensions: _batchAutoscoreExtensions,
                                  recursive: _batchStagingRecursive,
                                  useWildcard: _batchStagingUseWildcard,
                                  pattern: _batchStagingWildcardController.text,
                                  title: 'Select a folder of recordings for batch AutoscoreNidra',
                                );
                                if (files.isEmpty || !mounted) return;
                                setState(() {
                                  for (final f in files) {
                                    if (!_batchStagingFiles.contains(f)) _batchStagingFiles.add(f);
                                  }
                                });
                              },
                              hasItems: _batchStagingFiles.isNotEmpty,
                              onSelectDeselect: () async {
                                final selected = await showBatchFileSubSelectionDialog(
                                  context: context,
                                  title: 'Batch Autoscore File Selection',
                                  files: List<String>.from(_batchStagingFiles),
                                );
                                if (selected != null && mounted) {
                                  setState(() {
                                    _batchStagingFiles
                                      ..clear()
                                      ..addAll(selected);
                                  });
                                }
                              },
                              onClear: () => setState(_batchStagingFiles.clear),
                              recursive: _batchStagingRecursive,
                              onRecursive: (v) => setState(() => _batchStagingRecursive = v),
                              useWildcard: _batchStagingUseWildcard,
                              onWildcard: (v) => setState(() => _batchStagingUseWildcard = v),
                              wildcardController: _batchStagingWildcardController,
                            ),
                            const SizedBox(height: 16),
                            DropdownButtonFormField<String>(
                              isExpanded: true,
                              value: _batchStagingAlgorithm,
                              decoration: const InputDecoration(
                                labelText: 'Base Scorer Algorithm',
                                isDense: true,
                                border: OutlineInputBorder(),
                              ),
                              items: [
                                for (final option in autoscoreAlgorithmOptions)
                                  DropdownMenuItem(
                                    value: option.$1,
                                    child: Text(option.$2),
                                  ),
                              ],
                              onChanged: (v) {
                                if (v != null) {
                                  setState(() => _batchStagingAlgorithm = v);
                                }
                              },
                            ),
                            const SizedBox(height: 16),
                            DropdownButtonFormField<String>(
                              isExpanded: true,
                              value: _batchStagingCorrection,
                              decoration: const InputDecoration(
                                labelText: 'Sequence Correction',
                                isDense: true,
                                border: OutlineInputBorder(),
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'none',
                                  child: Text(
                                    'None (Raw consensus predictions)',
                                  ),
                                ),
                                DropdownMenuItem(
                                  value: 'sleepgpt',
                                  child: Text('SleepGPT Language Model'),
                                ),
                              ],
                              onChanged: (v) {
                                if (v != null) {
                                  setState(() => _batchStagingCorrection = v);
                                }
                              },
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'Channel Mapping Configuration:',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            if (_batchStagingFiles.isNotEmpty) ...[
                              Text(
                                'Channel lists come from the first recording: ${_basename(_batchStagingFiles.first)}',
                                style: TextStyle(fontSize: 11, color: Colors.grey.shade600, fontStyle: FontStyle.italic),
                              ),
                              const SizedBox(height: 6),
                            ],
                            TextFormField(
                              key: const Key('batch-autoscore-eeg-channels'),
                              controller: _batchStagingEegController,
                              decoration: InputDecoration(
                                labelText: 'EEG Channels (comma-separated)',
                                hintText: 'e.g. C3,C4 or F3,F4 (blank = auto)',
                                isDense: true,
                                border: const OutlineInputBorder(),
                                suffixIcon: _batchChannelPickerButton(
                                  _batchStagingEegController,
                                  _batchStagingFiles.isEmpty ? null : _batchStagingFiles.first,
                                  'Select EEG Channels for AutoscoreNidra',
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextFormField(
                              key: const Key(
                                'batch-autoscore-reference-channels',
                              ),
                              controller: _batchStagingRefController,
                              decoration: InputDecoration(
                                labelText:
                                    'Reference Channels (comma-separated)',
                                hintText: 'e.g. M2,M1 (blank = contralateral auto)',
                                isDense: true,
                                border: const OutlineInputBorder(),
                                suffixIcon: _batchChannelPickerButton(
                                  _batchStagingRefController,
                                  _batchStagingFiles.isEmpty ? null : _batchStagingFiles.first,
                                  'Select Reference Channel(s) for AutoscoreNidra',
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextFormField(
                              controller: _batchStagingEogController,
                              decoration: InputDecoration(
                                labelText: 'EOG Channels (optional)',
                                hintText: 'e.g. LOC,ROC (blank = auto-detect)',
                                isDense: true,
                                border: const OutlineInputBorder(),
                                suffixIcon: _batchChannelPickerButton(
                                  _batchStagingEogController,
                                  _batchStagingFiles.isEmpty ? null : _batchStagingFiles.first,
                                  'Select EOG Channel(s) for AutoscoreNidra',
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextFormField(
                              controller: _batchStagingEmgController,
                              decoration: InputDecoration(
                                labelText: 'EMG Channels (optional)',
                                hintText: 'e.g. Chin1-Chin2 (blank = auto-detect)',
                                isDense: true,
                                border: const OutlineInputBorder(),
                                suffixIcon: _batchChannelPickerButton(
                                  _batchStagingEmgController,
                                  _batchStagingFiles.isEmpty ? null : _batchStagingFiles.first,
                                  'Select EMG Channel(s) for AutoscoreNidra',
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: TextFormField(
                                    controller: _batchStagingOutDirController,
                                    decoration: const InputDecoration(
                                      labelText: 'Output Folder (optional — default: same as source)',
                                      hintText: 'Leave blank to save next to source recording',
                                      isDense: true,
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                IconButton(
                                  icon: const Icon(Icons.folder_open),
                                  tooltip: 'Select Output Directory',
                                  onPressed: () async {
                                    final dir = await FilePicker.getDirectoryPath(
                                      dialogTitle: 'Select Output Folder for Scoring JSON and Logs',
                                    );
                                    if (dir != null) {
                                      setState(() {
                                        _batchStagingOutDirController.text = dir;
                                      });
                                    }
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 24),
                            SizedBox(
                              width: double.infinity,
                              height: 40,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.purple,
                                  foregroundColor: Colors.white,
                                ),
                                onPressed: _batchStagingFiles.isEmpty
                                    ? null
                                    : () {
                                        final settings = {
                                          'algorithm': _batchStagingAlgorithm,
                                          'sequence_correction':
                                              _batchStagingCorrection,
                                          'sleepgpt_alpha': 0.1,
                                          'sleepgpt_ngram': 30,
                                          'output_dir': _batchStagingOutDirController.text.trim().isEmpty
                                              ? null
                                              : _batchStagingOutDirController.text.trim(),
                                          'eeg': _parseChannelList(
                                            _batchStagingEegController.text,
                                          ),
                                          'ref': _parseChannelList(
                                            _batchStagingRefController.text,
                                          ),
                                          'eog': _parseChannelList(
                                            _batchStagingEogController.text,
                                          ),
                                          'emg': _parseChannelList(
                                            _batchStagingEmgController.text,
                                          ),
                                        };
                                        _executeBatchAutoScoring(
                                          _batchStagingFiles,
                                          settings,
                                        );
                                      },
                                child: const Text(
                                  'Run Batch AutoscoreNidra',
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                ],
                // Right Column: Batch AnalyseNidra
                Expanded(
                  child: Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: const BorderSide(color: Color(0xFFD0D0D0)),
                    ),
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.analytics, color: Colors.blue),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'AnalyseNidra — Batch Advanced Sleep EEG Analysis',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const Divider(height: 24),
                          const Text(
                            'Recordings and their scoring files:',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          Container(
                            height: 150,
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: const Color(0xFFD0D0D0),
                              ),
                              borderRadius: BorderRadius.circular(4),
                              color: const Color(0xFFF9F9F9),
                            ),
                            child: _batchAnalysePairs.isEmpty
                                ? const Center(
                                    child: Text('No file pairs mapped'),
                                  )
                                : ListView.builder(
                                    itemCount: _batchAnalysePairs.length,
                                    itemBuilder: (context, index) {
                                      final pair = _batchAnalysePairs[index];
                                      final eeg = pair['eegPath'] ?? '';
                                      final scoring = pair['scoringPath'] ?? '';
                                      return ListTile(
                                        dense: true,
                                        title: Text('EEG: ${_basename(eeg)}'),
                                        subtitle: Text(
                                          scoring.isEmpty
                                              ? 'Scoring: not found — click the pencil to choose'
                                              : 'Scoring: ${_basename(scoring)}',
                                          style: scoring.isEmpty
                                              ? const TextStyle(color: Colors.deepOrange)
                                              : null,
                                        ),
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton(
                                              icon: const Icon(
                                                Icons.edit,
                                                size: 16,
                                                color: Colors.grey,
                                              ),
                                              tooltip: 'Select scoring file',
                                              onPressed: () async {
                                                final result =
                                                    await FilePicker.pickFiles(
                                                      dialogTitle:
                                                          'Select scoring JSON file',
                                                      type: FileType.custom,
                                                      allowedExtensions: [
                                                        'json',
                                                      ],
                                                    );
                                                if (result != null &&
                                                    result.files.single.path !=
                                                        null) {
                                                  setState(() {
                                                    pair['scoringPath'] = result
                                                        .files
                                                        .single
                                                        .path!;
                                                  });
                                                }
                                              },
                                            ),
                                            IconButton(
                                              icon: const Icon(
                                                Icons.delete,
                                                size: 16,
                                                color: Colors.red,
                                              ),
                                              onPressed: () {
                                                setState(() {
                                                  _batchAnalysePairs.removeAt(
                                                    index,
                                                  );
                                                });
                                              },
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                          ),
                          const SizedBox(height: 8),
                          _batchSourceControls(
                            onAddFiles: () async {
                              final files = await _collectBatchRecordings(
                                fromFolder: false,
                                extensions: _batchAnalyseExtensions,
                                recursive: _batchAnalyseRecursive,
                                useWildcard: _batchAnalyseUseWildcard,
                                pattern: _batchAnalyseWildcardController.text,
                                title: 'Select recordings for batch AnalyseNidra',
                              );
                              if (mounted) _addBatchAnalyseRecordings(files);
                            },
                            onAddFolder: () async {
                              final files = await _collectBatchRecordings(
                                fromFolder: true,
                                extensions: _batchAnalyseExtensions,
                                recursive: _batchAnalyseRecursive,
                                useWildcard: _batchAnalyseUseWildcard,
                                pattern: _batchAnalyseWildcardController.text,
                                title: 'Select a folder of recordings for batch AnalyseNidra',
                              );
                              if (mounted) _addBatchAnalyseRecordings(files);
                            },
                            hasItems: _batchAnalysePairs.isNotEmpty,
                            onSelectDeselect: () async {
                              final eegFiles = _batchAnalysePairs
                                  .map((p) => p['eegPath'] ?? '')
                                  .where((e) => e.isNotEmpty)
                                  .toList();
                              final selected = await showBatchFileSubSelectionDialog(
                                context: context,
                                title: 'Batch AnalyseNidra File Selection',
                                files: eegFiles,
                              );
                              if (selected != null && mounted) {
                                final selectedSet = selected.toSet();
                                setState(() {
                                  _batchAnalysePairs.removeWhere(
                                    (p) => !selectedSet.contains(p['eegPath']),
                                  );
                                });
                              }
                            },
                            onClear: () => setState(() {
                              _batchAnalysePairs.clear();
                              _batchAnalyseAvailableChannels = const [];
                            }),
                            recursive: _batchAnalyseRecursive,
                            onRecursive: (v) => setState(() => _batchAnalyseRecursive = v),
                            useWildcard: _batchAnalyseUseWildcard,
                            onWildcard: (v) => setState(() => _batchAnalyseUseWildcard = v),
                            wildcardController: _batchAnalyseWildcardController,
                            extraOptions: [
                              _batchOptionCheckbox(
                                'Auto-load scorings',
                                _batchAnalyseAutoLoadScorings,
                                (v) {
                                  setState(() => _batchAnalyseAutoLoadScorings = v);
                                  if (v) _rematchBatchScorings();
                                },
                              ),
                              if (_batchAnalyseAutoLoadScorings)
                                SizedBox(
                                  width: 170,
                                  child: TextField(
                                    controller: _batchScoringPostfixController,
                                    decoration: const InputDecoration(
                                      labelText: 'Scoring postfix',
                                      hintText: 'e.g. _scoring',
                                      isDense: true,
                                      border: OutlineInputBorder(),
                                    ),
                                    onSubmitted: (_) => _rematchBatchScorings(),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          // EEG Channels
                          TextFormField(
                            controller: _batchAnalyseEegController,
                            decoration: InputDecoration(
                              labelText: 'EEG Channels for analysis (comma-separated)',
                              hintText: 'e.g. F3,F4,C3,C4',
                              isDense: true,
                              border: const OutlineInputBorder(),
                              suffixIcon: IconButton(
                                icon: const Icon(Icons.playlist_add_check),
                                tooltip: 'Choose from the channel list of the first recording…',
                                onPressed: _openBatchAnalyseChannelSelector,
                              ),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                          if (_batchAnalysePairs.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Channel lists come from the first recording: ${_basename(_batchAnalysePairs.first['eegPath'] ?? '')}',
                              style: TextStyle(fontSize: 11, color: Colors.grey.shade600, fontStyle: FontStyle.italic),
                            ),
                          ],
                          if (_batchAnalyseEegController.text.trim().isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: _batchAnalyseEegController.text
                                  .split(',')
                                  .map((s) => s.trim())
                                  .where((s) => s.isNotEmpty)
                                  .map((ch) => Chip(
                                        label: Text(ch, style: const TextStyle(fontSize: 12)),
                                        visualDensity: VisualDensity.compact,
                                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        padding: const EdgeInsets.symmetric(horizontal: 4),
                                        deleteIconColor: Colors.red.shade400,
                                        onDeleted: () {
                                          setState(() {
                                            final updated = _batchAnalyseEegController.text
                                                .split(',')
                                                .map((s) => s.trim())
                                                .where((s) => s.isNotEmpty && s != ch)
                                                .toList();
                                            _batchAnalyseEegController.text = updated.join(',');
                                          });
                                        },
                                      ))
                                  .toList(),
                            ),
                          ],
                          const SizedBox(height: 16),
                          // Reference Channels
                          TextFormField(
                            controller: _batchAnalyseRefController,
                            decoration: InputDecoration(
                              labelText: 'Reference Channels for analysis (comma-separated, optional)',
                              hintText: 'e.g. PPG or M1,M2 (leave blank if none)',
                              isDense: true,
                              border: const OutlineInputBorder(),
                              suffixIcon: IconButton(
                                icon: const Icon(Icons.playlist_add_check),
                                tooltip: 'Choose from the channel list of the first recording…',
                                onPressed: _openBatchAnalyseRefSelector,
                              ),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                          if (_batchAnalyseRefController.text.trim().isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: _batchAnalyseRefController.text
                                  .split(',')
                                  .map((s) => s.trim())
                                  .where((s) => s.isNotEmpty)
                                  .map((ch) => Chip(
                                        label: Text(ch, style: const TextStyle(fontSize: 12)),
                                        visualDensity: VisualDensity.compact,
                                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                        padding: const EdgeInsets.symmetric(horizontal: 4),
                                        deleteIconColor: Colors.red.shade400,
                                        onDeleted: () {
                                          setState(() {
                                            final updated = _batchAnalyseRefController.text
                                                .split(',')
                                                .map((s) => s.trim())
                                                .where((s) => s.isNotEmpty && s != ch)
                                                .toList();
                                            _batchAnalyseRefController.text = updated.join(',');
                                          });
                                        },
                                      ))
                                  .toList(),
                            ),
                          ],
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: TextFormField(
                                  controller: _batchAnalyseOutDirController,
                                  decoration: const InputDecoration(
                                    labelText: 'Output Folder (optional — default: same as source)',
                                    hintText: 'Leave blank to save next to source recording',
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                icon: const Icon(Icons.folder_open),
                                tooltip: 'Select Output Directory',
                                onPressed: () async {
                                  final dir = await FilePicker.getDirectoryPath(
                                    dialogTitle: 'Select Output Folder for Analyse Outputs and Logs',
                                  );
                                  if (dir != null) {
                                    setState(() {
                                      _batchAnalyseOutDirController.text = dir;
                                    });
                                  }
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          AnalyseNidraOptionsPanel(
                            options: _batchAnalyseOptions,
                            dense: true,
                            onChanged: (o) => setState(() => _batchAnalyseOptions = o),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade50,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: Row(
                              children: [
                                Checkbox(
                                  value: _batchAnalysePerChannel,
                                  onChanged: (val) => setState(() => _batchAnalysePerChannel = val ?? false),
                                ),
                                const Expanded(
                                  child: Text(
                                    'Per-channel output (no regional grouping)',
                                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                                  ),
                                ),
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.edit, size: 15),
                                  label: Text(
                                    _batchAnalyseCustomRegionMap.isEmpty
                                        ? 'Edit Regional Mapping…'
                                        : 'Edit Regions (${_batchAnalyseCustomRegionMap.length} mapped)',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  onPressed: _batchAnalysePerChannel
                                      ? null
                                      : () async {
                                          final chans = _batchAnalyseEegController.text
                                              .split(',')
                                              .map((e) => e.trim())
                                              .where((e) => e.isNotEmpty)
                                              .toList();
                                          final channelsToMap = chans.isNotEmpty
                                              ? chans
                                              : _batchAnalyseAvailableChannels;
                                          if (channelsToMap.isEmpty) {
                                            _setStatus('No channels detected yet. Please select or add recordings first.');
                                            return;
                                          }
                                          final updated = await showDialog<Map<String, String>>(
                                            context: context,
                                            builder: (ctx) => EditRegionMappingDialog(
                                              channels: channelsToMap,
                                              initialMapping: _batchAnalyseCustomRegionMap,
                                            ),
                                          );
                                          if (updated != null) {
                                            setState(() {
                                              _batchAnalyseCustomRegionMap = updated;
                                            });
                                          }
                                        },
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Skip completed steps / recordings (resume)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                            subtitle: const Text(
                              'Reuses existing output JSON/CSV files without recomputing, only completing missing analyses',
                              style: TextStyle(fontSize: 10),
                            ),
                            value: _batchAnalyseSkipExisting,
                            onChanged: (v) => setState(() => _batchAnalyseSkipExisting = v ?? true),
                          ),
                          CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Auto-collate master sheet upon completion', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                            subtitle: const Text(
                              'Automatically compiles all regional CSVs into AnalyseNidra_master_sheet.csv',
                              style: TextStyle(fontSize: 10),
                            ),
                            value: _batchAnalyseAutoCollate,
                            onChanged: (v) => setState(() => _batchAnalyseAutoCollate = v ?? true),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: double.infinity,
                            height: 40,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blue,
                                foregroundColor: Colors.white,
                              ),
                              onPressed: _batchAnalysePairs.isEmpty
                                  ? null
                                  : () {
                                      final validPairs = _batchAnalysePairs
                                          .where(
                                            (p) =>
                                                (p['eegPath'] ?? '')
                                                    .isNotEmpty &&
                                                (p['scoringPath'] ?? '')
                                                    .isNotEmpty,
                                          )
                                          .toList();
                                      if (validPairs.isEmpty) {
                                        _setStatus(
                                          'Error: Mapped pairs must have both EEG and Scoring files.',
                                        );
                                        return;
                                      }

                                      final jobs = validPairs.map((pair) {
                                        return _AnalyseNidraJob(
                                          edfPath: pair['eegPath']!,
                                          scoringPath: pair['scoringPath']!,
                                          mappedScoringPath:
                                              pair['scoringPath']!,
                                        );
                                      }).toList();

                                       final chans = _batchAnalyseEegController
                                           .text
                                           .split(',')
                                           .map((e) => e.trim())
                                           .where((e) => e.isNotEmpty)
                                           .toList();
                                       if (chans.isEmpty) {
                                         _setStatus(
                                           'Please select or specify at least one EEG channel for analysis.',
                                         );
                                         _openBatchAnalyseChannelSelector();
                                         return;
                                       }
                                       final refs = _batchAnalyseRefController
                                           .text
                                           .split(',')
                                           .map((e) => e.trim())
                                           .where((e) => e.isNotEmpty)
                                           .toList();
                                       final outDir = _batchAnalyseOutDirController.text.trim().isEmpty
                                           ? null
                                           : _batchAnalyseOutDirController.text.trim();

                                      if (_batchAnalyseOptions.analyses.isEmpty) {
                                        _setStatus('Select at least one analysis to run.');
                                        return;
                                      }
                                      final regionMapJson = (!_batchAnalysePerChannel && _batchAnalyseCustomRegionMap.isNotEmpty)
                                          ? jsonEncode(_batchAnalyseCustomRegionMap)
                                          : null;
                                      _runAnalyseNidraJobs(
                                        jobs,
                                        chans,
                                        refs,
                                        outputDir: outDir,
                                        perChannel: _batchAnalysePerChannel,
                                        regionMapJson: regionMapJson,
                                        options: _batchAnalyseOptions,
                                        skipExisting: _batchAnalyseSkipExisting,
                                        autoCollate: _batchAnalyseAutoCollate,
                                      );
                                    },
                              child: const Text(
                                'Run Batch AnalyseNidra',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Divider(),
                          const Text(
                            'Compile AnalyseNidra Regional Outputs',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              ElevatedButton.icon(
                                onPressed: _lastAnalyseRegionalFiles.isEmpty
                                    ? null
                                    : () => _compileAnalyseNidraMasterSheet(
                                        _lastAnalyseRegionalFiles,
                                      ),
                                icon: const Icon(Icons.table_view, size: 16),
                                label: const Text('Compile Last Batch'),
                              ),
                              OutlinedButton.icon(
                                onPressed: _compileAnalyseNidraMasterSheet,
                                icon: const Icon(Icons.library_add, size: 16),
                                label: const Text('Combine Existing CSVs…'),
                              ),
                              ElevatedButton.icon(
                                onPressed: _generateBatchPdfReports,
                                icon: const Icon(Icons.picture_as_pdf, size: 16),
                                label: const Text('Batch PDFs from Master Chart…'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildBatchPreprocessingCard(),
            const SizedBox(height: 16),
            _buildBatchPsgCard(),
            const SizedBox(height: 16),
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: const BorderSide(color: Color(0xFFD0D0D0)),
              ),
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.compare_arrows, color: Colors.orange),
                        const Expanded(
                          child: Text(
                            'Batch Scoring Comparison (Inter-rater & Model Agreement)',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          onPressed: _autoPairComparisonFolders,
                          icon: const Icon(Icons.folder_copy, size: 16),
                          label: const Text('Auto-Pair 2 Folders…'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: _addComparisonPairManually,
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Add Pair'),
                        ),
                      ],
                    ),
                    const Divider(height: 24),
                    const Text(
                      'Paired Scoring Files (Reference vs Comparison):',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 160,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade300),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: _batchComparisonPairs.isEmpty
                          ? const Center(
                              child: Text('No scoring file pairs added yet. Click "Auto-Pair 2 Folders…" or "Add Pair".', style: TextStyle(color: Colors.grey)),
                            )
                          : ListView.builder(
                              itemCount: _batchComparisonPairs.length,
                              itemBuilder: (context, index) {
                                final pair = _batchComparisonPairs[index];
                                final fileA = pair['fileA'] ?? '';
                                final fileB = pair['fileB'] ?? '';
                                return Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  child: Row(
                                    children: [
                                      Text('#${index + 1}', style: const TextStyle(fontWeight: FontWeight.bold)),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Container(
                                          padding: const EdgeInsets.all(6),
                                          decoration: BoxDecoration(color: Colors.blue.shade50, borderRadius: BorderRadius.circular(4)),
                                          child: Text('Ref: ${_basename(fileA)}', overflow: TextOverflow.ellipsis),
                                        ),
                                      ),
                                      const Padding(
                                        padding: EdgeInsets.symmetric(horizontal: 8),
                                        child: Icon(Icons.compare_arrows, size: 18, color: Colors.grey),
                                      ),
                                      Expanded(
                                        child: Container(
                                          padding: const EdgeInsets.all(6),
                                          decoration: BoxDecoration(color: Colors.orange.shade50, borderRadius: BorderRadius.circular(4)),
                                          child: Text('Cmp: ${_basename(fileB)}', overflow: TextOverflow.ellipsis),
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                                        onPressed: () {
                                          setState(() {
                                            _batchComparisonPairs.removeAt(index);
                                          });
                                        },
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 40,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.deepOrange, foregroundColor: Colors.white),
                        onPressed: _batchComparisonPairs.isEmpty ? null : _executeBatchScoringComparison,
                        icon: const Icon(Icons.analytics),
                        label: const Text('Run Batch Comparison & Generate Master CSV', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  ),
);
}

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final viewport = _viewport;

    return PlatformMenuBar(
      menus: _platformMenus(),
      child: Shortcuts(
        key: const Key('viewer-shortcuts'),
        shortcuts: _tabController.index == 1 || _textInputFocused
            ? const <ShortcutActivator, Intent>{}
            : _shortcuts,
        child: Actions(
          actions: {
            _ScoreIntent: CallbackAction<_ScoreIntent>(
              onInvoke: (i) => _scoreCurrentEpoch(i.stage),
            ),
            _NextEpochIntent: CallbackAction<_NextEpochIntent>(
              onInvoke: (_) => _nextEpoch(),
            ),
            _PreviousEpochIntent: CallbackAction<_PreviousEpochIntent>(
              onInvoke: (_) => _previousEpoch(),
            ),
            _EventIntent: CallbackAction<_EventIntent>(
              onInvoke: (i) => _markEvent(i.digit),
            ),
            _EraseEventsIntent: CallbackAction<_EraseEventsIntent>(
              onInvoke: (_) => _eraseEventsInSelections(),
            ),
            _ZoomSelectionIntent: CallbackAction<_ZoomSelectionIntent>(
              onInvoke: (_) => _zoomOnSelectedEeg(),
            ),
            _ToggleUncertaintyIntent: CallbackAction<_ToggleUncertaintyIntent>(
              onInvoke: (_) => _toggleUncertainty(),
            ),
            _KComplexDetectionIntent: CallbackAction<_KComplexDetectionIntent>(
              onInvoke: (_) => _runKComplexDetection(),
            ),
            _SpindleDetectionIntent: CallbackAction<_SpindleDetectionIntent>(
              onInvoke: (_) => _runSpindleDetection(),
            ),
            _ConfigIntent: CallbackAction<_ConfigIntent>(
              onInvoke: (_) => _openConfigDialog(),
            ),
            _FilterIntent: CallbackAction<_FilterIntent>(
              onInvoke: (_) => _openFilterDialog(),
            ),
            _MarkersIntent: CallbackAction<_MarkersIntent>(
              onInvoke: (_) {
                _openMarkersDialog();
                return null;
              },
            ),
            _ToggleVideoIntent: CallbackAction<_ToggleVideoIntent>(
              onInvoke: (_) {
                if (_videoController == null) {
                  _openVideoFile();
                } else {
                  setState(() => _videoPanelVisible = !_videoPanelVisible);
                }
                return null;
              },
            ),
            _ToggleWaveformMaximizeIntent:
                CallbackAction<_ToggleWaveformMaximizeIntent>(
              onInvoke: (_) {
                setState(() => _waveformMaximized = !_waveformMaximized);
                return null;
              },
            ),
          },
          child: Focus(
            focusNode: _viewerFocusNode,
            autofocus: true,
            child: Scaffold(
              backgroundColor: const Color(0xFFEDEDED),
              appBar: PreferredSize(
                preferredSize: const Size.fromHeight(36),
                child: Container(
                  height: 36,
                  decoration: const BoxDecoration(
                    color: Color(0xFFF7F7F7),
                    border: Border(
                      bottom: BorderSide(color: Color(0xFFD0D0D0)),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TabBar(
                          controller: _tabController,
                          isScrollable: true,
                          tabAlignment: TabAlignment.start,
                          indicatorSize: TabBarIndicatorSize.tab,
                          labelColor: Colors.black87,
                          unselectedLabelColor: Colors.black54,
                          labelStyle: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                          unselectedLabelStyle: const TextStyle(fontSize: 13),
                          tabs: const [
                            Tab(text: 'Interactive Scoring'),
                            Tab(text: 'Batch'),
                          ],
                        ),
                      ),
                      if (_appVersion.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            'CCS Sleep Studio $_appVersion',
                            style: const TextStyle(
                              color: Color(0xFF555555),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              body: TabBarView(
                controller: _tabController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  Column(
                    children: [
                      if (!Platform.isMacOS) _buildInAppMenuBar(),
                      _Toolbar(
                        viewport: viewport,
                        onJump: _jumpToEpoch,
                        onTimeUnitChanged: _setEegPanelTimeUnit,
                        onFocusChanged: (focused) =>
                            setState(() => _textInputFocused = focused),
                        onPrevious: _previousEpoch,
                        onNext: _nextEpoch,
                        onUnscored: _jumpNextUnscored,
                        onUncertain: _jumpNextUncertain,
                        onTransition: _jumpNextTransition,
                        onHuman: _jumpNextHuman,
                        onEvent: _jumpNextEvent,
                        onDisagreement: _jumpNextDisagreement,
                        hasComparison: _comparisonStages != null,
                        onConfig: _openConfigDialog,
                        swaSlider: _swaSlider,
                        onSwaSlider: (v) => setState(() => _swaSlider = v),
                        onToggleUncertainty: _toggleUncertainty,
                        tfEnabled: _config.tfEnabled,
                        onToggleWavelet: _toggleWavelet,
                        onOverlayChanged: _setHypnogramOverlayMode,
                        onOpenMarkers: _openMarkersDialog,
                        onPreprocess: _openPreprocessDialog,
                        onFeatureConfig: _openFeatureSelectionAndConfigDialog,
                        onToggleVideo: () {
                          if (_videoController == null) {
                            _openVideoFile();
                          } else {
                            setState(
                              () => _videoPanelVisible = !_videoPanelVisible,
                            );
                          }
                        },
                        videoLoaded: _videoController != null,
                        videoVisible: _videoPanelVisible,
                      ),
                      Expanded(
                        child: viewport == null
                            ? const Center(child: CircularProgressIndicator())
                            : Stack(
                                children: [
                                  _ScoringHeroSurface(
                                    viewport: viewport,
                                    onJump: _jumpToEpochCoalesced,
                                    swaSlider: _swaSlider,
                                    onSwaSlider: (v) =>
                                        setState(() => _swaSlider = v),
                                    onSelectionEnd: _updateSelection,
                                    comparisonStages: _comparisonStages,
                                    nlgOverlay: _nlgOverlay,
                                    tfEnabled: _config.tfEnabled,
                                    onResizeFlex: _updateFlexValues,
                                    onLightsMarkersChanged:
                                        _updateLightsMarkers,
                                    onOverlayChanged: _setHypnogramOverlayMode,
                                    onChannelScaleAdjust: _adjustChannelScale,
                                    onChannelScaleSet: _setChannelScale,
                                    onChannelScaleApplyAll:
                                        _applyScaleToAllChannels,
                                    onTimeUnitChanged: _setEegPanelTimeUnit,
                                    waveformMaximized: _waveformMaximized,
                                    onToggleMaximize: () => setState(
                                      () => _waveformMaximized =
                                          !_waveformMaximized,
                                    ),
                                  ),
                                  if (_videoPanelVisible &&
                                      _videoController != null)
                                    Positioned(
                                      right: 16,
                                      bottom: 16,
                                      child: SyncedVideoPanel(
                                        videoPath: _videoPath ?? '',
                                        controller: _videoController!,
                                        currentEegSeconds:
                                            viewport.currentEpoch *
                                            viewport.epochSeconds.toDouble(),
                                        offsetSeconds: _videoOffsetSeconds,
                                        onOffsetChanged: (newOffset) {
                                          setState(
                                            () =>
                                                _videoOffsetSeconds = newOffset,
                                          );
                                          _seekVideoToEpoch(
                                            viewport.currentEpoch,
                                          );
                                        },
                                        onClose: () => setState(
                                          () => _videoPanelVisible = false,
                                        ),
                                        onTogglePlayPause: _toggleVideoPlayPause,
                                        isPlaying: _isVideoPlaying,
                                      ),
                                    ),
                                ],
                              ),
                      ),
                      _StatusBar(
                        status: _status,
                        activePath: _activePath,
                        viewport: viewport,
                        comparisonStages: _comparisonStages,
                        onTimeUnitChanged: _setEegPanelTimeUnit,
                      ),
                    ],
                  ),
                  _buildBatchProcessingTab(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _updateLightsMarkers(double lightsOff, double lightsOn) {
    final v = _viewport;
    if (v == null) return;
    final total = v.totalDurationSeconds;
    final off = lightsOff.clamp(0.0, total);
    final on = lightsOn.clamp(off, total);
    setState(() {
      _config.lightsOffSeconds = off;
      _config.lightsOnSeconds = on;
      _viewport = v.copyWith(lightsOffSeconds: off, lightsOnSeconds: on);
      _status =
          'Lights off ${_formatDurationCompact(off)}; lights on ${_formatDurationCompact(on)}';
    });
    final activePath = _activePath;
    _lightsMarkerSaveTimer?.cancel();
    if (activePath != null) {
      _lightsMarkerSaveTimer = Timer(const Duration(milliseconds: 450), () {
        unawaited(saveAutoConfig(activePath, _config));
      });
    }
  }

  void _setHypnogramOverlayMode(String overlayMode, [String? probabilityStage]) {
    setState(() {
      _config.hypnogramOverlayMode = overlayMode;
      if (probabilityStage != null) {
        _config.hypnogramProbabilityStage = probabilityStage;
      }
      if (_viewport != null) {
        _viewport = _viewport!.copyWith(
          hypnogramOverlayMode: overlayMode,
          hypnogramProbabilityStage:
              probabilityStage ?? _config.hypnogramProbabilityStage,
        );
      }
    });
    if (_activePath != null) {
      unawaited(saveAutoConfig(_activePath!, _config));
    }
  }

  void _setEegPanelTimeUnit(String newUnit) {
    if (_config.eegPanelTimeUnit == newUnit &&
        _viewport?.eegPanelTimeUnit == newUnit) {
      return;
    }
    setState(() {
      _config.eegPanelTimeUnit = newUnit;
      if (_viewport != null) {
        _viewport = _viewport!.copyWith(eegPanelTimeUnit: newUnit);
      }
      _status = 'Hypnogram & status bar time unit set to $newUnit';
    });
    if (_activePath != null) {
      unawaited(saveAutoConfig(_activePath!, _config));
    }
  }
}

int? _parseJumpInputToEpoch(
  String input,
  String mode,
  int epochCount, {
  DateTime? recordingStartTime,
  double epochSeconds = 30.0,
}) {
  if (input.trim().isEmpty || epochCount <= 0) return null;
  final str = input.trim();

  if (mode == 'Epoch') {
    final val = int.tryParse(str);
    return val?.clamp(1, epochCount);
  }

  if (mode == 'Elapsed') {
    final timeMatch = RegExp(r'^(\d+):(\d+)(?::(\d+))?$').firstMatch(str);
    if (timeMatch != null) {
      final p1 = int.parse(timeMatch.group(1)!);
      final p2 = int.parse(timeMatch.group(2)!);
      final p3 = timeMatch.group(3) != null ? int.parse(timeMatch.group(3)!) : 0;
      final totalSec = timeMatch.group(3) != null ? (p1 * 3600 + p2 * 60 + p3) : (p1 * 60 + p2);
      final epoch = (totalSec / epochSeconds).round() + 1;
      return epoch.clamp(1, epochCount);
    }
    double sec = 0.0;
    var matched = false;
    final hMatch = RegExp(r'(\d+)\s*h', caseSensitive: false).firstMatch(str);
    if (hMatch != null) {
      sec += int.parse(hMatch.group(1)!) * 3600;
      matched = true;
    }
    final mMatch = RegExp(r'(\d+)\s*m', caseSensitive: false).firstMatch(str);
    if (mMatch != null) {
      sec += int.parse(mMatch.group(1)!) * 60;
      matched = true;
    }
    final sMatch = RegExp(r'(\d+)\s*s', caseSensitive: false).firstMatch(str);
    if (sMatch != null) {
      sec += int.parse(sMatch.group(1)!);
      matched = true;
    }
    if (!matched) {
      final val = double.tryParse(str);
      if (val != null) {
        sec = val;
        matched = true;
      }
    }
    if (matched) {
      final epoch = (sec / epochSeconds).round() + 1;
      return epoch.clamp(1, epochCount);
    }
  }

  if (mode == 'Clock') {
    final clockMatch = RegExp(
      r'^(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(AM|PM)?$',
      caseSensitive: false,
    ).firstMatch(str);

    if (clockMatch != null) {
      var h = int.parse(clockMatch.group(1)!);
      final m = int.parse(clockMatch.group(2)!);
      final s = clockMatch.group(3) != null ? int.parse(clockMatch.group(3)!) : 0;
      final ampm = clockMatch.group(4)?.toUpperCase();

      if (ampm == 'PM' && h < 12) h += 12;
      if (ampm == 'AM' && h == 12) h = 0;

      final targetSecondsInDay = h * 3600 + m * 60 + s;
      final startSecondsInDay = recordingStartTime != null
          ? recordingStartTime.hour * 3600 +
            recordingStartTime.minute * 60 +
            recordingStartTime.second
          : 0;

      var diff = targetSecondsInDay - startSecondsInDay;
      if (diff < 0) {
        diff += 86400;
      }
      final epoch = (diff / epochSeconds).round() + 1;
      return epoch.clamp(1, epochCount);
    }
  }

  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Toolbar
// ─────────────────────────────────────────────────────────────────────────────

class _Toolbar extends StatefulWidget {
  const _Toolbar({
    required this.viewport,
    required this.onJump,
    this.onFocusChanged,
    required this.onPrevious,
    required this.onNext,
    required this.onUnscored,
    required this.onUncertain,
    required this.onTransition,
    required this.onHuman,
    required this.onEvent,
    required this.onDisagreement,
    required this.hasComparison,
    required this.onConfig,
    required this.swaSlider,
    required this.onSwaSlider,
    required this.onToggleUncertainty,
    required this.tfEnabled,
    required this.onToggleWavelet,
    this.onOverlayChanged,
    this.onOpenMarkers,
    this.onPreprocess,
    this.onFeatureConfig,
    this.onToggleVideo,
    this.onTimeUnitChanged,
    this.videoLoaded = false,
    this.videoVisible = false,
  });

  final EegViewport? viewport;
  final VoidCallback? onPreprocess;
  final VoidCallback? onFeatureConfig;
  final void Function(int, [bool]) onJump;
  final ValueChanged<bool>? onFocusChanged;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onUnscored;
  final VoidCallback onUncertain;
  final VoidCallback onTransition;
  final VoidCallback onHuman;
  final VoidCallback onEvent;
  final VoidCallback onDisagreement;
  final bool hasComparison;
  final VoidCallback onConfig;
  final int swaSlider;
  final ValueChanged<int> onSwaSlider;
  final VoidCallback onToggleUncertainty;
  final bool tfEnabled;
  final VoidCallback onToggleWavelet;
  final void Function(String overlayMode, [String? probabilityStage])?
  onOverlayChanged;
  final VoidCallback? onOpenMarkers;
  final VoidCallback? onToggleVideo;
  final ValueChanged<String>? onTimeUnitChanged;
  final bool videoLoaded;
  final bool videoVisible;

  @override
  State<_Toolbar> createState() => _ToolbarState();
}

class _ToolbarState extends State<_Toolbar> {
  late final TextEditingController _ctrl;
  final FocusNode _focusNode = FocusNode();
  String _jumpMode = 'Epoch'; // 'Epoch', 'Elapsed', 'Clock'

  @override
  void initState() {
    super.initState();
    final epoch = widget.viewport?.currentEpoch ?? 0;
    if (widget.viewport?.eegPanelTimeUnit == 'Clock time') {
      _jumpMode = 'Clock';
    }
    _ctrl = TextEditingController(text: '${epoch + 1}');
    _focusNode.addListener(_handleFocusChange);
  }

  void _handleFocusChange() {
    widget.onFocusChanged?.call(_focusNode.hasFocus);
    if (!_focusNode.hasFocus) {
      _applyJumpInput(true);
    }
  }

  void _applyJumpInput(bool commit) {
    final text = _ctrl.text.trim();
    if (text.isEmpty || widget.viewport == null) return;
    final vp = widget.viewport!;
    final targetEpoch = _parseJumpInputToEpoch(
      text,
      _jumpMode,
      vp.epochCount,
      recordingStartTime: vp.recordingStartTime,
      epochSeconds: vp.epochSeconds.toDouble(),
    );
    if (targetEpoch != null) {
      widget.onJump(targetEpoch, commit);
      if (commit && _jumpMode == 'Epoch') {
        _ctrl.text = '$targetEpoch';
      }
    }
  }

  String _formatOutOfText(EegViewport vp) {
    final epochCount = vp.epochCount;
    final epochSec = vp.epochSeconds;
    final totalSec = epochCount * epochSec;

    if (_jumpMode == 'Epoch') {
      return '/ $epochCount';
    } else if (_jumpMode == 'Elapsed') {
      final h = totalSec ~/ 3600;
      final m = (totalSec % 3600) ~/ 60;
      final s = totalSec % 60;
      return '/ ${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    } else {
      final start = vp.recordingStartTime;
      if (start != null) {
        final end = start.add(Duration(seconds: totalSec));
        return '/ ${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}:${end.second.toString().padLeft(2, '0')}';
      } else {
        final h = totalSec ~/ 3600;
        final m = (totalSec % 3600) ~/ 60;
        final s = totalSec % 60;
        return '/ ${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
      }
    }
  }

  String _currentOverlaySelection(EegViewport? vp) {
    if (vp == null || vp.hypnogramOverlayMode == 'Off') return 'Off';
    if (vp.hypnogramOverlayMode == 'SWA') return 'SWA';
    if (vp.hypnogramOverlayMode == 'NeuroLoopGain') return 'NLG';
    final st = vp.hypnogramProbabilityStage.toUpperCase();
    if (st == 'WAKE' || st == 'W') return 'P(Wake)';
    if (st == 'N1') return 'P(N1)';
    if (st == 'N2') return 'P(N2)';
    if (st == 'N3') return 'P(N3)';
    if (st == 'REM' || st == 'R') return 'P(REM)';
    return 'P(N2)';
  }

  @override
  void didUpdateWidget(covariant _Toolbar old) {
    super.didUpdateWidget(old);
    final epoch = widget.viewport?.currentEpoch ?? 0;
    final oldUnit = old.viewport?.eegPanelTimeUnit;
    final newUnit = widget.viewport?.eegPanelTimeUnit;
    if (oldUnit != newUnit) {
      if (newUnit == 'Clock time') {
        _jumpMode = 'Clock';
      } else if (_jumpMode == 'Clock') {
        _jumpMode = 'Elapsed';
      }
    }
    if (!_focusNode.hasFocus) {
      if (_jumpMode == 'Epoch') {
        _ctrl.text = '${epoch + 1}';
      } else if (_jumpMode == 'Elapsed') {
        final sec = epoch * (widget.viewport?.epochSeconds ?? 30);
        final h = sec ~/ 3600;
        final m = (sec % 3600) ~/ 60;
        final s = sec % 60;
        _ctrl.text =
            '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
      } else if (_jumpMode == 'Clock') {
        final start = widget.viewport?.recordingStartTime ?? DateTime.now();
        final time = start.add(
          Duration(seconds: epoch * (widget.viewport?.epochSeconds ?? 30)),
        );
        _ctrl.text =
            '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
      }
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _ctrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.viewport != null;
    return Material(
      color: const Color(0xFFF4F4F4),
      elevation: 1,
      child: SizedBox(
        height: 36,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              const SizedBox(width: 8),
              DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _jumpMode,
                  isDense: true,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Colors.black87,
                    fontWeight: FontWeight.w600,
                  ),
                  items: const [
                    DropdownMenuItem(value: 'Epoch', child: Text('Jump to epoch:')),
                    DropdownMenuItem(
                      value: 'Elapsed',
                      child: Text('Jump to elapsed:'),
                    ),
                    DropdownMenuItem(
                      value: 'Clock',
                      child: Text('Jump to clock:'),
                    ),
                  ],
                  onChanged: enabled
                      ? (val) {
                          if (val == null) return;
                          setState(() {
                            _jumpMode = val;
                            final epoch = widget.viewport?.currentEpoch ?? 0;
                            if (val == 'Epoch') {
                              _ctrl.text = '${epoch + 1}';
                            } else if (val == 'Elapsed') {
                              final sec =
                                  epoch * (widget.viewport?.epochSeconds ?? 30);
                              final h = sec ~/ 3600;
                              final m = (sec % 3600) ~/ 60;
                              final s = sec % 60;
                              _ctrl.text =
                                  '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
                            } else if (val == 'Clock') {
                              final start =
                                  widget.viewport?.recordingStartTime ??
                                  DateTime.now();
                              final time = start.add(
                                Duration(
                                  seconds:
                                      epoch * (widget.viewport?.epochSeconds ?? 30),
                                ),
                              );
                              _ctrl.text =
                                  '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
                            }
                          });
                          if (val == 'Clock') {
                            widget.onTimeUnitChanged?.call('Clock time');
                          } else if (val == 'Elapsed' &&
                              widget.viewport?.eegPanelTimeUnit == 'Clock time') {
                            widget.onTimeUnitChanged?.call('Minutes');
                          }
                        }
                      : null,
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: _jumpMode == 'Epoch' ? 56 : 88,
                height: 24,
                child: TextField(
                  controller: _ctrl,
                  focusNode: _focusNode,
                  enabled: enabled,
                  keyboardType: _jumpMode == 'Epoch'
                      ? TextInputType.number
                      : TextInputType.text,
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    isDense: true,
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 4,
                    ),
                    hintText: _jumpMode == 'Epoch'
                        ? '1'
                        : (_jumpMode == 'Elapsed' ? '01:30:00' : '23:15:00'),
                  ),
                  style: const TextStyle(fontSize: 12),
                  onTapOutside: (_) => _focusNode.unfocus(),
                  onSubmitted: (_) {
                    _applyJumpInput(true);
                    _focusNode.unfocus();
                  },
                  onChanged: (_) => _applyJumpInput(false),
                ),
              ),
              if (widget.viewport != null)
                Padding(
                  padding: const EdgeInsets.only(left: 4, right: 4),
                  child: Text(
                    _formatOutOfText(widget.viewport!),
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.black54,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              _ToolButton(
                label: '◀',
                enabled: enabled,
                onPressed: widget.onPrevious,
              ),
              _ToolButton(
                label: '▶',
                enabled: enabled,
                onPressed: widget.onNext,
              ),
              const SizedBox(width: 8),
              const _Divider(),
              _ToolButton(
                label: 'unscored',
                tooltip: 'Jump to next unscored epoch',
                enabled: enabled,
                onPressed: widget.onUnscored,
              ),
              _ToolButton(
                label: 'uncertain',
                tooltip: 'Jump to next inconclusive epoch',
                enabled: enabled,
                onPressed: widget.onUncertain,
              ),
              _ToolButton(
                label: 'transition',
                tooltip: 'Jump to next stage transition',
                enabled: enabled,
                onPressed: widget.onTransition,
              ),
              _ToolButton(
                label: 'event',
                tooltip: 'Jump to next epoch with events',
                enabled: enabled,
                onPressed: widget.onEvent,
              ),
              _ToolButton(
                label: 'human',
                tooltip: 'Jump to next human-scored epoch',
                enabled: enabled,
                onPressed: widget.onHuman,
              ),
              _ToolButton(
                label: 'disagreement',
                tooltip: widget.hasComparison
                    ? 'Jump to next scoring disagreement'
                    : 'Compare scoring not loaded',
                enabled: enabled && widget.hasComparison,
                onPressed: widget.onDisagreement,
              ),
              const SizedBox(width: 8),
              const _Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _currentOverlaySelection(widget.viewport),
                    isDense: true,
                    style: const TextStyle(fontSize: 12, color: Colors.black87),
                    items: const [
                      DropdownMenuItem(
                        value: 'SWA',
                        child: Text('Overlay: SWA'),
                      ),
                      DropdownMenuItem(
                        value: 'NLG',
                        child: Text('Overlay: NeuroLoopGain'),
                      ),
                      DropdownMenuItem(
                        value: 'P(Wake)',
                        child: Text('Overlay: P(Wake)'),
                      ),
                      DropdownMenuItem(
                        value: 'P(N1)',
                        child: Text('Overlay: P(N1)'),
                      ),
                      DropdownMenuItem(
                        value: 'P(N2)',
                        child: Text('Overlay: P(N2)'),
                      ),
                      DropdownMenuItem(
                        value: 'P(N3)',
                        child: Text('Overlay: P(N3)'),
                      ),
                      DropdownMenuItem(
                        value: 'P(REM)',
                        child: Text('Overlay: P(REM)'),
                      ),
                      DropdownMenuItem(
                        value: 'Off',
                        child: Text('Overlay: Off'),
                      ),
                    ],
                    onChanged: enabled
                        ? (val) {
                            if (val == null) return;
                            if (val == 'SWA') {
                              widget.onOverlayChanged?.call('SWA');
                            } else if (val == 'NLG') {
                              widget.onOverlayChanged?.call('NeuroLoopGain');
                            } else if (val == 'Off') {
                              widget.onOverlayChanged?.call('Off');
                            } else if (val == 'P(Wake)') {
                              widget.onOverlayChanged?.call(
                                'Sleep-stage probability',
                                'Wake',
                              );
                            } else if (val == 'P(N1)') {
                              widget.onOverlayChanged?.call(
                                'Sleep-stage probability',
                                'N1',
                              );
                            } else if (val == 'P(N2)') {
                              widget.onOverlayChanged?.call(
                                'Sleep-stage probability',
                                'N2',
                              );
                            } else if (val == 'P(N3)') {
                              widget.onOverlayChanged?.call(
                                'Sleep-stage probability',
                                'N3',
                              );
                            } else if (val == 'P(REM)') {
                              widget.onOverlayChanged?.call(
                                'Sleep-stage probability',
                                'REM',
                              );
                            }
                          }
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const _Divider(),
              _ToolButton(
                label: 'Toggle uncertain [Q]',
                tooltip: 'Toggle uncertainty for current epoch',
                enabled: enabled,
                onPressed: widget.onToggleUncertainty,
              ),
              _ToolButton(
                label: 'config',
                tooltip: 'Open channel and display configuration',
                enabled: enabled,
                onPressed: widget.onConfig,
              ),
              _ToolButton(
                label: widget.tfEnabled ? 'wavelet [ON]' : 'wavelet [OFF]',
                tooltip: 'Toggle wavelet time-frequency panel visibility',
                enabled: enabled,
                onPressed: widget.onToggleWavelet,
              ),
              const SizedBox(width: 8),
              const _Divider(),
              _ToolButton(
                label: 'markers (${widget.viewport?.scoredEvents.length ?? 0})',
                tooltip: 'Open Markers & Annotations Manager [M]',
                enabled: enabled,
                onPressed: widget.onOpenMarkers ?? () {},
              ),
              _ToolButton(
                label: 'preprocess',
                tooltip: 'Auto electric stim artefact removal & Preprocessing Pipeline…',
                enabled: true,
                onPressed: widget.onPreprocess ?? () {},
              ),
              _ToolButton(
                label: 'features',
                tooltip: 'Feature Selection & Parameter Configuration…',
                enabled: true,
                onPressed: widget.onFeatureConfig ?? () {},
              ),
              _ToolButton(
                label: widget.videoLoaded
                    ? (widget.videoVisible ? 'video [ON]' : 'video [OFF]')
                    : 'video',
                tooltip: 'Toggle Synchronized Video [V]',
                enabled: enabled,
                onPressed: widget.onToggleVideo ?? () {},
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Main scoring surface
// ─────────────────────────────────────────────────────────────────────────────

class _ScoringHeroSurface extends StatefulWidget {
  const _ScoringHeroSurface({
    required this.viewport,
    required this.onJump,
    required this.swaSlider,
    required this.onSwaSlider,
    required this.onSelectionEnd,
    required this.tfEnabled,
    required this.onResizeFlex,
    required this.onLightsMarkersChanged,
    this.comparisonStages,
    this.nlgOverlay,
    this.onOverlayChanged,
    this.onChannelScaleAdjust,
    this.onChannelScaleSet,
    this.onChannelScaleApplyAll,
    this.onTimeUnitChanged,
    this.waveformMaximized = false,
    this.onToggleMaximize,
  });

  final EegViewport viewport;
  final ValueChanged<int> onJump;
  final int swaSlider;
  final ValueChanged<int> onSwaSlider;
  final void Function(
    double? startSec,
    double? endSec,
    int? channel,
    double? startUv,
    double? endUv,
  )
  onSelectionEnd;
  final List<SleepStage>? comparisonStages;
  final NlgOverlayData? nlgOverlay;
  final bool tfEnabled;
  final void Function(
    int spectrogramFlex,
    int hypnogramFlex,
    int periodogramFlex,
  )
  onResizeFlex;
  final void Function(double lightsOffSeconds, double lightsOnSeconds)
  onLightsMarkersChanged;
  final void Function(String overlayMode, [String? probabilityStage])?
  onOverlayChanged;
  final void Function(int channelIndex, double multiplier)? onChannelScaleAdjust;
  final void Function(int channelIndex, double newScale)? onChannelScaleSet;
  final void Function(double newScale)? onChannelScaleApplyAll;
  final ValueChanged<String>? onTimeUnitChanged;
  final bool waveformMaximized;
  final VoidCallback? onToggleMaximize;

  @override
  State<_ScoringHeroSurface> createState() => _ScoringHeroSurfaceState();
}

class _ScoringHeroSurfaceState extends State<_ScoringHeroSurface> {
  double? _dragStartSec;
  double? _dragEndSec;
  int? _dragChannel;
  double? _dragStartUv;
  double? _dragEndUv;

  double _cumulativeDx = 0.0;
  int _dragSpecStartFlex = 0;
  int _dragHypStartFlex = 0;
  int _dragPerStartFlex = 0;
  double _topPanelHeight = 158.0;
  double _channelSidebarWidth = 100.0;

  double get _waveformPlotLeftPad => _channelSidebarWidth + 16.0;

  void _handlePanStart(DragStartDetails details, BoxConstraints constraints) {
    final n = widget.viewport.channelCount;
    if (n == 0) return;
    final drawWidth = (constraints.maxWidth - _waveformPlotLeftPad).clamp(
      1.0,
      double.infinity,
    );
    final fx = ((details.localPosition.dx - _waveformPlotLeftPad) / drawWidth)
        .clamp(0.0, 1.0);
    final sec =
        widget.viewport.visibleStartSeconds +
        fx * widget.viewport.visibleDurationSeconds;

    final ch = (details.localPosition.dy / constraints.maxHeight * n)
        .floor()
        .clamp(0, n - 1);
    final baselineFraction = (ch + 0.5) / n;
    final yFrac = details.localPosition.dy / constraints.maxHeight;
    final normalizedVal = (baselineFraction - yFrac) * n / 0.42;
    final uv = normalizedVal * widget.viewport.amplitudeRangeUv;

    setState(() {
      _dragStartSec = sec;
      _dragEndSec = sec;
      _dragChannel = ch;
      _dragStartUv = uv;
      _dragEndUv = uv;
    });
  }

  void _handlePanUpdate(DragUpdateDetails details, BoxConstraints constraints) {
    if (_dragStartSec == null || _dragChannel == null) return;
    final drawWidth = (constraints.maxWidth - _waveformPlotLeftPad).clamp(
      1.0,
      double.infinity,
    );
    final fx = ((details.localPosition.dx - _waveformPlotLeftPad) / drawWidth)
        .clamp(0.0, 1.0);
    final sec =
        widget.viewport.visibleStartSeconds +
        fx * widget.viewport.visibleDurationSeconds;

    final n = widget.viewport.channelCount;
    final baselineFraction = (_dragChannel! + 0.5) / n;
    final yFrac = details.localPosition.dy / constraints.maxHeight;
    final normalizedVal = (baselineFraction - yFrac) * n / 0.42;
    final uv = normalizedVal * widget.viewport.amplitudeRangeUv;

    setState(() {
      _dragEndSec = sec;
      _dragEndUv = uv;
    });
  }

  void _handlePanEnd(DragEndDetails details) {
    widget.onSelectionEnd(
      _dragStartSec,
      _dragEndSec,
      _dragChannel,
      _dragStartUv,
      _dragEndUv,
    );
    setState(() {
      _dragStartSec = null;
      _dragEndSec = null;
      _dragChannel = null;
      _dragStartUv = null;
      _dragEndUv = null;
    });
  }

  void _handlePanCancel() {
    widget.onSelectionEnd(null, null, null, null, null);
    setState(() {
      _dragStartSec = null;
      _dragEndSec = null;
      _dragChannel = null;
      _dragStartUv = null;
      _dragEndUv = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final zoomOption = widget.viewport.hypnogramZoom;
    final epochCount = widget.viewport.epochCount;
    final currentEpoch = widget.viewport.currentEpoch;

    int startEpoch = 0;
    int endEpoch = epochCount;

    if (zoomOption != 'Full Night') {
      int visibleEpochs = 100;
      if (zoomOption.contains('200')) {
        visibleEpochs = 200;
      } else if (zoomOption.contains('400')) {
        visibleEpochs = 400;
      }

      if (epochCount > visibleEpochs) {
        startEpoch = currentEpoch - (visibleEpochs ~/ 2);
        if (startEpoch < 0) {
          startEpoch = 0;
        }
        endEpoch = startEpoch + visibleEpochs;
        if (endEpoch > epochCount) {
          endEpoch = epochCount;
          startEpoch = (endEpoch - visibleEpochs).clamp(0, epochCount);
        }
      }
    }

    return ColoredBox(
      color: Colors.white,
      child: Column(
        children: [
          if (!widget.waveformMaximized) ...[
            // Top strip: spectrogram | hypnogram | optional SWA slider | power spectrum
            LayoutBuilder(
              builder: (context, constraints) {
                final totalWidth = constraints.maxWidth;
                final showSwaSlider =
                    widget.viewport.hypnogramOverlayMode == 'SWA';
                final swaWidth = showSwaSlider ? 42.0 : 0.0;
                final dividerWidth = 8.0;
                final netWidth = totalWidth - swaWidth - (dividerWidth * 2);

                final specFlex = widget.viewport.spectrogramFlex;
                final hypFlex = widget.viewport.hypnogramFlex;
                final perFlex = widget.viewport.periodogramFlex;
                final totalFlex = specFlex + hypFlex + perFlex;

                final flexPerPixel = totalFlex / netWidth;

                return SizedBox(
                  height: _topPanelHeight,
                  child: Row(
                    children: [
                      Expanded(
                        flex: specFlex,
                        child: _ClickablePainterPanel(
                          painter: SpectrogramPainter(widget.viewport),
                          rightPadding: 38.0,
                          onTapFraction: (fx) {
                            final epoch = (fx * widget.viewport.epochCount)
                                .floor()
                                .clamp(0, widget.viewport.epochCount - 1);
                            widget.onJump(epoch + 1);
                          },
                        ),
                      ),
                      GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onHorizontalDragStart: (_) {
                          _cumulativeDx = 0.0;
                          _dragSpecStartFlex = widget.viewport.spectrogramFlex;
                          _dragHypStartFlex = widget.viewport.hypnogramFlex;
                        },
                        onHorizontalDragUpdate: (dragDetails) {
                          _cumulativeDx += dragDetails.delta.dx;
                          final deltaFlex = (_cumulativeDx * flexPerPixel)
                              .round();
                          final newSpec = (_dragSpecStartFlex + deltaFlex).clamp(
                            5,
                            totalFlex - perFlex - 5,
                          );
                          final newHyp = totalFlex - newSpec - perFlex;
                          widget.onResizeFlex(newSpec, newHyp, perFlex);
                        },
                        child: MouseRegion(
                          cursor: SystemMouseCursors.resizeLeftRight,
                          child: SizedBox(
                            width: dividerWidth,
                            child: const Center(
                              child: VerticalDivider(
                                width: 1,
                                thickness: 1,
                                color: Color(0xFFD0D0D0),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        flex: hypFlex,
                        child: _HypnogramPainterPanel(
                          viewport: widget.viewport,
                          swaKernelSize: 101 - widget.swaSlider,
                          comparisonStages: widget.comparisonStages,
                          nlgOverlay: widget.nlgOverlay,
                          startEpoch: startEpoch,
                          endEpoch: endEpoch,
                          onLightsMarkersChanged: widget.onLightsMarkersChanged,
                          onOverlayChanged: widget.onOverlayChanged,
                          onTimeUnitChanged: widget.onTimeUnitChanged,
                          onTapFraction: (fx) {
                            final visibleCount = endEpoch - startEpoch;
                            final epoch =
                                (startEpoch + (fx * visibleCount).floor())
                                    .clamp(startEpoch, endEpoch - 1);
                            widget.onJump(epoch + 1);
                          },
                        ),
                      ),
                      if (showSwaSlider) ...[
                        SizedBox(
                          width: 42,
                          child: _HypnogramSlider(
                            value: widget.swaSlider,
                            onChanged: widget.onSwaSlider,
                          ),
                        ),
                      ],
                      GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onHorizontalDragStart: (_) {
                          _cumulativeDx = 0.0;
                          _dragHypStartFlex = widget.viewport.hypnogramFlex;
                          _dragPerStartFlex = widget.viewport.periodogramFlex;
                        },
                        onHorizontalDragUpdate: (dragDetails) {
                          _cumulativeDx += dragDetails.delta.dx;
                          final deltaFlex = (_cumulativeDx * flexPerPixel)
                              .round();
                          final newHyp = (_dragHypStartFlex + deltaFlex).clamp(
                            5,
                            totalFlex - specFlex - 5,
                          );
                          final newPer = totalFlex - specFlex - newHyp;
                          widget.onResizeFlex(specFlex, newHyp, newPer);
                        },
                        child: MouseRegion(
                          cursor: SystemMouseCursors.resizeLeftRight,
                          child: SizedBox(
                            width: dividerWidth,
                            child: const Center(
                              child: VerticalDivider(
                                width: 1,
                                thickness: 1,
                                color: Color(0xFFD0D0D0),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        flex: perFlex,
                        child: _Panel(
                          painter: RectanglePowerPainter(widget.viewport),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            // Draggable horizontal splitter between top strip and waveform plot
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragUpdate: (details) {
                setState(() {
                  _topPanelHeight =
                      (_topPanelHeight + details.delta.dy).clamp(60.0, 450.0);
                });
              },
              onDoubleTap: widget.onToggleMaximize,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeUpDown,
                child: Container(
                  height: 6,
                  color: const Color(0xFFE4E4E4),
                  child: Center(
                    child: Container(
                      width: 38,
                      height: 3,
                      decoration: BoxDecoration(
                        color: const Color(0xFFAAAAAA),
                        borderRadius: BorderRadius.circular(1.5),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
          // Middle: EEG signal (largest panel, fills full height when maximized)
          Expanded(
            flex: 74,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final channelCount = widget.viewport.channelCount;
                final channelHeight = channelCount > 0
                    ? constraints.maxHeight / channelCount
                    : 0.0;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    GestureDetector(
                      onPanStart: (d) {
                        if (d.localPosition.dx >= _waveformPlotLeftPad) {
                          _handlePanStart(d, constraints);
                        }
                      },
                      onPanUpdate: (d) {
                        if (d.localPosition.dx >= _waveformPlotLeftPad ||
                            _dragStartSec != null) {
                          _handlePanUpdate(d, constraints);
                        }
                      },
                      onPanEnd: _handlePanEnd,
                      onPanCancel: _handlePanCancel,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _Panel(
                            painter: TimelinePainter(
                              widget.viewport,
                              drawChannelLabels: false,
                              leftPad: _waveformPlotLeftPad,
                            ),
                            padding: EdgeInsets.zero,
                          ),
                          IgnorePointer(
                            child: CustomPaint(
                              painter: SelectionOverlayPainter(
                                widget.viewport,
                                activeDragStartSec: _dragStartSec,
                                activeDragEndSec: _dragEndSec,
                                activeDragChannel: _dragChannel,
                                activeDragStartUv: _dragStartUv,
                                activeDragEndUv: _dragEndUv,
                                leftPad: _waveformPlotLeftPad,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Maximize / Restore floating pill in top right corner
                    Positioned(
                      top: 4,
                      right: 8,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.9),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.black26, width: 0.8),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x18000000),
                              blurRadius: 2,
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                        child: Tooltip(
                          message: widget.waveformMaximized
                              ? 'Restore top panels (Press F or double-click splitter)'
                              : 'Maximize waveform plot to fill screen (Press F)',
                          child: InkWell(
                            onTap: widget.onToggleMaximize,
                            borderRadius: BorderRadius.circular(4),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2.5,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    widget.waveformMaximized
                                        ? Icons.fullscreen_exit
                                        : Icons.fullscreen,
                                    size: 15,
                                    color: Colors.blueGrey.shade800,
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    widget.waveformMaximized
                                        ? 'Restore'
                                        : 'Maximize',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.blueGrey.shade900,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (channelCount > 0 && channelHeight > 0) ...[
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: _channelSidebarWidth,
                        child: _ElectrodeScaleColumn(
                          viewport: widget.viewport,
                          channelHeight: channelHeight,
                          onAdjustScale: widget.onChannelScaleAdjust,
                          onSetScale: widget.onChannelScaleSet,
                          onApplyAll: widget.onChannelScaleApplyAll,
                        ),
                      ),
                      // Draggable vertical splitter for channel sidebar width
                      Positioned(
                        left: _channelSidebarWidth - 3,
                        top: 0,
                        bottom: 0,
                        width: 8,
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onHorizontalDragUpdate: (details) {
                            setState(() {
                              _channelSidebarWidth = (_channelSidebarWidth +
                                      details.delta.dx)
                                  .clamp(70.0, 240.0);
                            });
                          },
                          child: MouseRegion(
                            cursor: SystemMouseCursors.resizeColumn,
                            child: Center(
                              child: Container(
                                width: 2,
                                color: const Color(0xFFDCDCDC),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
          // Bottom: Time-Frequency panel
          if (widget.tfEnabled && !widget.waveformMaximized) ...[
            Expanded(
              flex: 16,
              child: _Panel(painter: TimeFrequencyPainter(widget.viewport)),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Status bar
// ─────────────────────────────────────────────────────────────────────────────

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.status,
    required this.activePath,
    required this.viewport,
    this.comparisonStages,
    this.onTimeUnitChanged,
  });

  final String status;
  final String? activePath;
  final EegViewport? viewport;
  final List<SleepStage>? comparisonStages;
  final ValueChanged<String>? onTimeUnitChanged;

  @override
  Widget build(BuildContext context) {
    final vp = viewport;
    Widget? rightWidget;
    if (vp != null && activePath != null) {
      final currentIdx = vp.currentEpoch;
      final currentStage = vp.currentStage;
      final isUncertain =
          currentIdx < vp.stagesUncertain.length &&
          vp.stagesUncertain[currentIdx];
      final uncertainStr = isUncertain ? ' (Uncertain)' : '';

      String comparisonStr = '';
      bool isInconsistent = false;
      final cmpStages = comparisonStages;
      if (cmpStages != null && currentIdx < cmpStages.length) {
        final cmpStage = cmpStages[currentIdx];
        comparisonStr = '  |  Comparison: ${cmpStage.label}';
        if (currentStage != SleepStage.unknown &&
            cmpStage != SleepStage.unknown &&
            currentStage != cmpStage) {
          isInconsistent = true;
        }
      }

      double totalSelectionLength = 0.0;
      for (final sel in vp.eventSelections) {
        totalSelectionLength += sel.durationSeconds;
      }
      if (vp.selectionStartSec != null && vp.selectionEndSec != null) {
        totalSelectionLength += (vp.selectionEndSec! - vp.selectionStartSec!)
            .abs();
      }
      final selectionStr = totalSelectionLength > 0
          ? '  |  Total Length: ${totalSelectionLength.toStringAsFixed(2)} s'
          : '';

      // Model confidence & stage probabilities display
      String confidenceStr = '';
      if (currentIdx < vp.stagesConfidence.length) {
        final conf = vp.stagesConfidence[currentIdx];
        if (conf != null) {
          confidenceStr =
              '  |  Confidence: ${(conf * 100).toStringAsFixed(1)}%';
        }
      }

      String probsStr = '';
      if (currentIdx < vp.stageProbabilities.length) {
        final probs = vp.stageProbabilities[currentIdx];
        if (probs.isNotEmpty) {
          final w = (((probs[SleepStage.wake] ?? 0.0) * 100)).toStringAsFixed(0);
          final n1 = (((probs[SleepStage.n1] ?? 0.0) * 100)).toStringAsFixed(0);
          final n2 = (((probs[SleepStage.n2] ?? 0.0) * 100)).toStringAsFixed(0);
          final n3 = (((probs[SleepStage.n3] ?? 0.0) * 100)).toStringAsFixed(0);
          final r = (((probs[SleepStage.rem] ?? 0.0) * 100)).toStringAsFixed(0);
          probsStr = '  |  P: W $w% · N1 $n1% · N2 $n2% · N3 $n3% · R $r%';
        }
      }

      final elapsedSec = (currentIdx * vp.epochSeconds).round();
      final eh = (elapsedSec ~/ 3600).toString().padLeft(2, '0');
      final em = ((elapsedSec % 3600) ~/ 60).toString().padLeft(2, '0');
      final es = (elapsedSec % 60).toString().padLeft(2, '0');
      final elapsedHms = '$eh:$em:$es';

      final unit = vp.eegPanelTimeUnit;
      String timeStr;
      if (unit == 'Clock time') {
        if (vp.recordingStartTime != null) {
          final clockDt =
              vp.recordingStartTime!.add(Duration(seconds: elapsedSec));
          final ch = clockDt.hour.toString().padLeft(2, '0');
          final cm = clockDt.minute.toString().padLeft(2, '0');
          final cs = clockDt.second.toString().padLeft(2, '0');
          timeStr = 'Clock: $ch:$cm:$cs';
        } else {
          timeStr = 'Elapsed: $elapsedHms';
        }
      } else if (unit == 'Seconds') {
        timeStr = 'Elapsed: ${elapsedSec}s';
      } else if (unit == 'Minutes') {
        timeStr = 'Elapsed: ${(elapsedSec / 60.0).toStringAsFixed(1)} min';
      } else if (unit == 'Hours') {
        final h = elapsedSec ~/ 3600;
        final m = ((elapsedSec % 3600) / 60).round();
        timeStr = m == 0 ? 'Elapsed: ${h}h' : 'Elapsed: ${h}h ${m}m';
      } else {
        timeStr = 'Elapsed: $elapsedHms';
      }

      final timeWidget = onTimeUnitChanged != null
          ? PopupMenuButton<String>(
              tooltip: 'Time format: $unit (Click to switch time format)',
              padding: EdgeInsets.zero,
              onSelected: onTimeUnitChanged,
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'Clock time',
                  child: Row(
                    children: [
                      Icon(Icons.access_time, size: 16, color: Colors.indigo),
                      SizedBox(width: 8),
                      Text('Clock time (HH:MM:SS)'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'Seconds',
                  child: Row(
                    children: [
                      Icon(Icons.timer_outlined, size: 16, color: Colors.teal),
                      SizedBox(width: 8),
                      Text('Seconds (s)'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'Minutes',
                  child: Row(
                    children: [
                      Icon(
                        Icons.timelapse_outlined,
                        size: 16,
                        color: Colors.blue,
                      ),
                      SizedBox(width: 8),
                      Text('Minutes (min)'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'Hours',
                  child: Row(
                    children: [
                      Icon(
                        Icons.schedule_outlined,
                        size: 16,
                        color: Colors.deepPurple,
                      ),
                      SizedBox(width: 8),
                      Text('Hours (hr)'),
                    ],
                  ),
                ),
              ],
              child: Text(
                timeStr,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.black87,
                  decoration: TextDecoration.underline,
                  decorationStyle: TextDecorationStyle.dotted,
                ),
              ),
            )
          : Text(
              timeStr,
              style: const TextStyle(fontSize: 12, color: Colors.black87),
            );

      rightWidget = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isInconsistent)
            const Text(
              '[INCONSISTENT]  ',
              style: TextStyle(
                fontSize: 12,
                color: Colors.red,
                fontWeight: FontWeight.bold,
              ),
            ),
          timeWidget,
          Text(
            '  |  Epoch ${currentIdx + 1}/${vp.epochCount} (${currentStage.label}$uncertainStr)$comparisonStr$confidenceStr$probsStr$selectionStr  |  ${vp.sampleRateHz.toStringAsFixed(0)} Hz',
            style: const TextStyle(fontSize: 12, color: Colors.black87),
          ),
        ],
      );
    }
    final cleanStatus = (status.startsWith('Epoch ') && status.contains(' / '))
        ? 'Ready'
        : status;
    return Container(
      height: 24,
      decoration: const BoxDecoration(
        color: Color(0xFFF2F2F2),
        border: Border(top: BorderSide(color: Color(0xFFCFCFCF))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              cleanStatus,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          if (rightWidget != null) ...[
            const SizedBox(width: 12),
            rightWidget,
          ],
          if (activePath != null) ...[
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                _basename(activePath!),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widget helpers
// ─────────────────────────────────────────────────────────────────────────────

class _Panel extends StatelessWidget {
  const _Panel({required this.painter, this.padding = const EdgeInsets.all(1)});

  final CustomPainter painter;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: RepaintBoundary(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: const Color(0xFFD0D0D0)),
          ),
          child: ClipRect(
            child: CustomPaint(
              painter: painter,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

class _ClickablePainterPanel extends StatelessWidget {
  const _ClickablePainterPanel({
    required this.painter,
    required this.onTapFraction,
    this.leftPadding = _plotLeftPadding,
    this.rightPadding = 0.0,
  });

  final CustomPainter painter;
  final void Function(double fx) onTapFraction;
  final double leftPadding;
  final double rightPadding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(1),
      child: RepaintBoundary(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: const Color(0xFFD0D0D0)),
          ),
          child: GestureDetector(
            onTapDown: (details) {
              final rb = context.findRenderObject()! as RenderBox;
              final plotWidth =
                  (rb.size.width - leftPadding - rightPadding).clamp(
                1.0,
                double.infinity,
              );
              final fx =
                  ((details.localPosition.dx - leftPadding) / plotWidth)
                      .clamp(0.0, 1.0);
              onTapFraction(fx);
            },
            onPanUpdate: (details) {
              final rb = context.findRenderObject()! as RenderBox;
              final plotWidth =
                  (rb.size.width - leftPadding - rightPadding).clamp(
                1.0,
                double.infinity,
              );
              final fx =
                  ((details.localPosition.dx - leftPadding) / plotWidth)
                      .clamp(0.0, 1.0);
              onTapFraction(fx);
            },
            onPanDown: (details) {
              final rb = context.findRenderObject()! as RenderBox;
              final plotWidth =
                  (rb.size.width - leftPadding - rightPadding).clamp(
                1.0,
                double.infinity,
              );
              final fx =
                  ((details.localPosition.dx - leftPadding) / plotWidth)
                      .clamp(0.0, 1.0);
              onTapFraction(fx);
            },
            child: ClipRect(
              child: CustomPaint(
                painter: painter,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HypnogramPainterPanel extends StatefulWidget {
  const _HypnogramPainterPanel({
    required this.viewport,
    required this.swaKernelSize,
    required this.comparisonStages,
    required this.onTapFraction,
    required this.startEpoch,
    required this.endEpoch,
    required this.onLightsMarkersChanged,
    this.nlgOverlay,
    this.onOverlayChanged,
    this.onTimeUnitChanged,
  });

  final EegViewport viewport;
  final int swaKernelSize;
  final List<SleepStage>? comparisonStages;
  final NlgOverlayData? nlgOverlay;
  final void Function(double fx) onTapFraction;
  final int startEpoch;
  final int endEpoch;
  final void Function(double lightsOffSeconds, double lightsOnSeconds)
  onLightsMarkersChanged;
  final void Function(String overlayMode, [String? probabilityStage])?
  onOverlayChanged;
  final ValueChanged<String>? onTimeUnitChanged;

  @override
  State<_HypnogramPainterPanel> createState() => _HypnogramPainterPanelState();
}

class _HypnogramPainterPanelState extends State<_HypnogramPainterPanel> {
  String? _draggingMarker;
  double? _dragLightsOff;
  double? _dragLightsOn;

  static const double _hypLeftPadding = 48.0;

  double get _effectiveLightsOff =>
      _dragLightsOff ?? widget.viewport.lightsOffSeconds ?? 0.0;

  double get _effectiveLightsOn =>
      _dragLightsOn ??
      widget.viewport.lightsOnSeconds ??
      widget.viewport.totalDurationSeconds;

  EegViewport get _effectiveViewport => widget.viewport.copyWith(
    lightsOffSeconds: _effectiveLightsOff,
    lightsOnSeconds: _effectiveLightsOn,
  );

  double _fractionFromPosition(Offset position, Size size) {
    final plotWidth = (size.width - _hypLeftPadding).clamp(
      1.0,
      double.infinity,
    );
    return ((position.dx - _hypLeftPadding) / plotWidth).clamp(0.0, 1.0);
  }

  double _secondsFromPosition(Offset position, Size size) {
    final visibleEpochs = math.max(1, widget.endEpoch - widget.startEpoch);
    final start = widget.startEpoch * widget.viewport.epochSeconds.toDouble();
    final duration = visibleEpochs * widget.viewport.epochSeconds.toDouble();
    return start + _fractionFromPosition(position, size) * duration;
  }

  String? _hitMarker(Offset position, Size size) {
    final total = widget.viewport.totalDurationSeconds;
    if (total <= 0) return null;
    final plotH = size.height - 18.0;
    if (position.dy >= 25.0 && position.dy <= plotH - 20.0) {
      return null;
    }
    final plotWidth = (size.width - _hypLeftPadding).clamp(
      1.0,
      double.infinity,
    );
    final visibleEpochs = math.max(1, widget.endEpoch - widget.startEpoch);
    final start = widget.startEpoch * widget.viewport.epochSeconds.toDouble();
    final duration = visibleEpochs * widget.viewport.epochSeconds.toDouble();
    double markerX(double seconds) =>
        _hypLeftPadding + ((seconds - start) / duration) * plotWidth;
    final lightsOff = _effectiveLightsOff.clamp(0.0, total);
    final lightsOn = _effectiveLightsOn.clamp(0.0, total);
    final offDistance = (position.dx - markerX(lightsOff)).abs();
    final onDistance = (position.dx - markerX(lightsOn)).abs();
    const hitWidth = 18.0;
    if (offDistance <= hitWidth && offDistance <= onDistance) {
      return 'off';
    }
    if (onDistance <= hitWidth) return 'on';
    return null;
  }

  void _moveMarker(Offset position, Size size) {
    final marker = _draggingMarker;
    if (marker == null) return;
    final total = widget.viewport.totalDurationSeconds;
    final seconds = _secondsFromPosition(position, size).clamp(0.0, total);
    final lightsOff = _effectiveLightsOff;
    final lightsOn = _effectiveLightsOn;
    setState(() {
      if (marker == 'off') {
        _dragLightsOff = seconds;
        _dragLightsOn = math.max(seconds, lightsOn);
      } else {
        _dragLightsOff = math.min(lightsOff, seconds);
        _dragLightsOn = seconds;
      }
    });
  }

  void _commitMarkerDrag() {
    final off = _dragLightsOff;
    final on = _dragLightsOn;
    setState(() {
      _draggingMarker = null;
      _dragLightsOff = null;
      _dragLightsOn = null;
    });
    if (off != null && on != null) {
      widget.onLightsMarkersChanged(off, on);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(1),
      child: RepaintBoundary(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: const Color(0xFFD0D0D0)),
          ),
          child: GestureDetector(
            onTapDown: (details) {
              final rb = context.findRenderObject()! as RenderBox;
              final marker = _hitMarker(details.localPosition, rb.size);
              if (marker != null) return;
              widget.onTapFraction(
                _fractionFromPosition(details.localPosition, rb.size),
              );
            },
            onPanDown: (details) {
              final rb = context.findRenderObject()! as RenderBox;
              _draggingMarker = _hitMarker(details.localPosition, rb.size);
              if (_draggingMarker != null) {
                _dragLightsOff = widget.viewport.lightsOffSeconds ?? 0.0;
                _dragLightsOn =
                    widget.viewport.lightsOnSeconds ??
                    widget.viewport.totalDurationSeconds;
              }
              if (_draggingMarker == null) {
                widget.onTapFraction(
                  _fractionFromPosition(details.localPosition, rb.size),
                );
              }
            },
            onPanUpdate: (details) {
              final rb = context.findRenderObject()! as RenderBox;
              if (_draggingMarker != null) {
                _moveMarker(details.localPosition, rb.size);
              } else {
                widget.onTapFraction(
                  _fractionFromPosition(details.localPosition, rb.size),
                );
              }
            },
            onPanEnd: (_) => _commitMarkerDrag(),
            onPanCancel: () {
              setState(() {
                _draggingMarker = null;
                _dragLightsOff = null;
                _dragLightsOn = null;
              });
            },
            child: GestureDetector(
              onSecondaryTapUp: (details) =>
                  _showOverlayContextMenu(context, details.globalPosition),
              child: MouseRegion(
                cursor: _draggingMarker == null
                    ? SystemMouseCursors.click
                    : SystemMouseCursors.resizeLeftRight,
                child: ClipRect(
                  child: CustomPaint(
                    painter: HypnogramPainter(
                      _effectiveViewport,
                      swaKernelSize: widget.swaKernelSize,
                      comparisonStages: widget.comparisonStages,
                      nlgOverlay: widget.nlgOverlay,
                      startEpoch: widget.startEpoch,
                      endEpoch: widget.endEpoch,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showOverlayContextMenu(BuildContext context, Offset globalPos) {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPos.dx, globalPos.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(
          value: 'SWA',
          child: Row(
            children: [
              Icon(Icons.show_chart, size: 16, color: Colors.teal),
              SizedBox(width: 8),
              Text(
                'SWA Trend (Slow-Wave Activity)',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'NLG',
          child: Row(
            children: [
              Icon(Icons.stacked_line_chart, size: 16, color: Color(0xFF0B6E4F)),
              SizedBox(width: 8),
              Text(
                'NeuroLoopGain (slow-wave & sigma gain)',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'P_Wake',
          child: Row(
            children: [
              Icon(Icons.brightness_5, size: 16, color: Colors.amber),
              SizedBox(width: 8),
              Text('Probability: Wake', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'P_N1',
          child: Row(
            children: [
              Icon(Icons.bedtime_outlined, size: 16, color: Colors.lightBlue),
              SizedBox(width: 8),
              Text('Probability: N1', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'P_N2',
          child: Row(
            children: [
              Icon(Icons.bedtime_outlined, size: 16, color: Colors.blue),
              SizedBox(width: 8),
              Text('Probability: N2', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'P_N3',
          child: Row(
            children: [
              Icon(Icons.bedtime_outlined, size: 16, color: Colors.indigo),
              SizedBox(width: 8),
              Text(
                'Probability: N3 (Deep Sleep)',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'P_REM',
          child: Row(
            children: [
              Icon(Icons.remove_red_eye_outlined, size: 16, color: Colors.pink),
              SizedBox(width: 8),
              Text('Probability: REM', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'Off',
          child: Row(
            children: [
              Icon(Icons.visibility_off_outlined, size: 16, color: Colors.grey),
              SizedBox(width: 8),
              Text('None / Off', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'U_Clock time',
          child: Row(
            children: [
              Icon(Icons.access_time, size: 16, color: Colors.indigo),
              SizedBox(width: 8),
              Text('Time Unit: Clock time', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'U_Seconds',
          child: Row(
            children: [
              Icon(Icons.timer_outlined, size: 16, color: Colors.teal),
              SizedBox(width: 8),
              Text('Time Unit: Seconds', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'U_Minutes',
          child: Row(
            children: [
              Icon(Icons.timelapse_outlined, size: 16, color: Colors.blue),
              SizedBox(width: 8),
              Text('Time Unit: Minutes', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'U_Hours',
          child: Row(
            children: [
              Icon(Icons.schedule_outlined, size: 16, color: Colors.deepPurple),
              SizedBox(width: 8),
              Text('Time Unit: Hours', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ],
    ).then((val) {
      if (val == null) return;
      if (val == 'SWA') {
        widget.onOverlayChanged?.call('SWA');
      } else if (val == 'NLG') {
        widget.onOverlayChanged?.call('NeuroLoopGain');
      } else if (val == 'Off') {
        widget.onOverlayChanged?.call('Off');
      } else if (val.startsWith('P_')) {
        widget.onOverlayChanged?.call('Sleep-stage probability', val.substring(2));
      } else if (val.startsWith('U_')) {
        widget.onTimeUnitChanged?.call(val.substring(2));
      }
    });
  }
}

class _HypnogramSlider extends StatelessWidget {
  const _HypnogramSlider({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 4.0),
          child: Text(
            'SWA',
            style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold),
          ),
        ),
        Expanded(
          child: RotatedBox(
            quarterTurns: 3,
            child: Slider(
              value: value.toDouble(),
              min: 0,
              max: 100,
              onChanged: (v) => onChanged(v.round()),
            ),
          ),
        ),
      ],
    );
  }
}

class _ElectrodeScaleColumn extends StatelessWidget {
  const _ElectrodeScaleColumn({
    required this.viewport,
    required this.channelHeight,
    required this.onAdjustScale,
    required this.onSetScale,
    required this.onApplyAll,
  });

  final EegViewport viewport;
  final double channelHeight;
  final void Function(int channelIndex, double multiplier)? onAdjustScale;
  final void Function(int channelIndex, double newScale)? onSetScale;
  final void Function(double newScale)? onApplyAll;

  @override
  Widget build(BuildContext context) {
    final labels = viewport.signalChannelLabels;
    final scales = viewport.signalChannelScales;
    final count = labels.length;
    if (count == 0 || channelHeight <= 0) return const SizedBox.shrink();

    return Column(
      children: [
        for (var i = 0; i < count; i++)
          SizedBox(
            height: channelHeight,
            child: _ChannelScaleTile(
              channelIndex: i,
              channelName: labels[i],
              scalePercent: scales[i],
              channelHeight: channelHeight,
              onAdjustScale: onAdjustScale,
              onSetScale: onSetScale,
              onApplyAll: onApplyAll,
            ),
          ),
      ],
    );
  }
}

class _ChannelScaleTile extends StatefulWidget {
  const _ChannelScaleTile({
    required this.channelIndex,
    required this.channelName,
    required this.scalePercent,
    required this.channelHeight,
    required this.onAdjustScale,
    required this.onSetScale,
    required this.onApplyAll,
  });

  final int channelIndex;
  final String channelName;
  final double scalePercent;
  final double channelHeight;
  final void Function(int channelIndex, double multiplier)? onAdjustScale;
  final void Function(int channelIndex, double newScale)? onSetScale;
  final void Function(double newScale)? onApplyAll;

  @override
  State<_ChannelScaleTile> createState() => _ChannelScaleTileState();
}

class _ChannelScaleTileState extends State<_ChannelScaleTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scaleStr = '${widget.scalePercent.toStringAsFixed(0)}%';
    final isCompact = widget.channelHeight < 28;

    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          if (event.scrollDelta.dy < 0) {
            widget.onAdjustScale?.call(widget.channelIndex, 1.2);
          } else if (event.scrollDelta.dy > 0) {
            widget.onAdjustScale?.call(widget.channelIndex, 0.8);
          }
        }
      },
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Container(
          padding: const EdgeInsets.only(left: 4, right: 2),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: _hovered ? Colors.blue.withOpacity(0.08) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Expanded(
                child: PopupMenuButton<double>(
                  tooltip:
                      '${widget.channelName} (Scale: $scaleStr) — Click for presets, scroll to zoom',
                  padding: EdgeInsets.zero,
                  onSelected: (val) {
                    if (val == -1.0) {
                      widget.onApplyAll?.call(widget.scalePercent);
                    } else if (val == -2.0) {
                      widget.onApplyAll?.call(100.0);
                    } else {
                      widget.onSetScale?.call(widget.channelIndex, val);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 50.0,
                      child: Text('50% (Zoom Out)'),
                    ),
                    const PopupMenuItem(value: 75.0, child: Text('75%')),
                    const PopupMenuItem(
                      value: 100.0,
                      child: Text('100% (Reset Default)'),
                    ),
                    const PopupMenuItem(value: 125.0, child: Text('125%')),
                    const PopupMenuItem(
                      value: 150.0,
                      child: Text('150% (Zoom In)'),
                    ),
                    const PopupMenuItem(value: 200.0, child: Text('200%')),
                    const PopupMenuItem(value: 300.0, child: Text('300%')),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: -1.0,
                      child: Text('Apply $scaleStr to All Channels'),
                    ),
                    const PopupMenuItem(
                      value: -2.0,
                      child: Text('Reset All Channels to 100%'),
                    ),
                  ],
                  child: !isCompact
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.channelName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.bold,
                                color: Colors.black87,
                              ),
                            ),
                            if (widget.scalePercent != 100.0)
                              Text(
                                '${widget.scalePercent.round()}%',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.indigo.shade800,
                                ),
                              ),
                          ],
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              fit: FlexFit.loose,
                              child: Text(
                                widget.channelName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black87,
                                ),
                              ),
                            ),
                            if (widget.scalePercent != 100.0) ...[
                              const SizedBox(width: 2),
                              Text(
                                '${widget.scalePercent.round()}%',
                                style: TextStyle(
                                  fontSize: 8,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.indigo.shade800,
                                ),
                              ),
                            ],
                          ],
                        ),
                ),
              ),
              _buildSubtleSign(
                icon: Icons.remove,
                onTap: () =>
                    widget.onAdjustScale?.call(widget.channelIndex, 0.8),
                tooltip: 'Scale down (zoom out)',
                isCompact: isCompact,
              ),
              _buildSubtleSign(
                icon: Icons.add,
                onTap: () =>
                    widget.onAdjustScale?.call(widget.channelIndex, 1.25),
                tooltip: 'Scale up (zoom in)',
                isCompact: isCompact,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSubtleSign({
    required IconData icon,
    required VoidCallback onTap,
    required String tooltip,
    required bool isCompact,
  }) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(2),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1.5, vertical: 2),
          child: Icon(
            icon,
            size: isCompact ? 10 : 11,
            color: _hovered ? Colors.black87 : Colors.black45,
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.label,
    required this.enabled,
    required this.onPressed,
    this.tooltip,
  });

  final String label;
  final bool enabled;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final btn = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: SizedBox(
        height: 24,
        child: OutlinedButton(
          onPressed: enabled ? onPressed : null,
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: Size.zero,
          ),
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
      ),
    );
    if (tooltip != null) {
      return Tooltip(message: tooltip!, child: btn);
    }
    return btn;
  }
}

class _ZoomSignalPainter extends CustomPainter {
  const _ZoomSignalPainter(this.samples, this.sampleRate);

  final List<double> samples;
  final double sampleRate;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    if (samples.length < 2) return;
    final minV = samples.reduce(math.min);
    final maxV = samples.reduce(math.max);
    final range = math.max(maxV - minV, 1e-6);
    const pad = EdgeInsets.fromLTRB(44, 12, 12, 28);
    final plotW = size.width - pad.left - pad.right;
    final plotH = size.height - pad.top - pad.bottom;
    final axisPaint = Paint()
      ..color = Colors.black38
      ..strokeWidth = 0.8;
    canvas.drawRect(
      Rect.fromLTWH(pad.left, pad.top, plotW, plotH),
      Paint()
        ..color = Colors.black12
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6,
    );
    final zeroY = pad.top + (1.0 - (0.0 - minV) / range) * plotH;
    if (zeroY >= pad.top && zeroY <= pad.top + plotH) {
      canvas.drawLine(
        Offset(pad.left, zeroY),
        Offset(pad.left + plotW, zeroY),
        axisPaint,
      );
    }
    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = pad.left + (i / (samples.length - 1)) * plotW;
      final y = pad.top + (1.0 - (samples[i] - minV) / range) * plotH;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke,
    );
    final duration = samples.length / sampleRate;
    _paintText(
      canvas,
      '0 s',
      Offset(pad.left, size.height - 12),
      TextAlign.left,
    );
    _paintText(
      canvas,
      '${duration.toStringAsFixed(2)} s',
      Offset(pad.left + plotW, size.height - 12),
      TextAlign.right,
    );
    _paintText(
      canvas,
      '${maxV.toStringAsFixed(1)} µV',
      Offset(4, pad.top + 6),
      TextAlign.left,
    );
    _paintText(
      canvas,
      '${minV.toStringAsFixed(1)} µV',
      Offset(4, pad.top + plotH - 6),
      TextAlign.left,
    );
  }

  void _paintText(Canvas canvas, String text, Offset offset, TextAlign align) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(fontSize: 11, color: Colors.black87),
      ),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout(maxWidth: 140);
    var dx = offset.dx;
    if (align == TextAlign.right) dx -= painter.width;
    painter.paint(canvas, Offset(dx, offset.dy - painter.height / 2));
  }

  @override
  bool shouldRepaint(_ZoomSignalPainter oldDelegate) =>
      oldDelegate.samples != samples || oldDelegate.sampleRate != sampleRate;
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 20,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: const Color(0xFFCCCCCC),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Intents + Shortcuts
// ─────────────────────────────────────────────────────────────────────────────

class _ScoreIntent extends Intent {
  const _ScoreIntent(this.stage);
  final SleepStage stage;
}

class _NextEpochIntent extends Intent {
  const _NextEpochIntent();
}

class _PreviousEpochIntent extends Intent {
  const _PreviousEpochIntent();
}

class _ToggleUncertaintyIntent extends Intent {
  const _ToggleUncertaintyIntent();
}

class _EventIntent extends Intent {
  const _EventIntent(this.digit);
  final int digit;
}

class _EraseEventsIntent extends Intent {
  const _EraseEventsIntent();
}

class _ZoomSelectionIntent extends Intent {
  const _ZoomSelectionIntent();
}

class _KComplexDetectionIntent extends Intent {
  const _KComplexDetectionIntent();
}

class _SpindleDetectionIntent extends Intent {
  const _SpindleDetectionIntent();
}

class _ConfigIntent extends Intent {
  const _ConfigIntent();
}

class _FilterIntent extends Intent {
  const _FilterIntent();
}

class _MarkersIntent extends Intent {
  const _MarkersIntent();
}

class _ToggleVideoIntent extends Intent {
  const _ToggleVideoIntent();
}

class _ToggleWaveformMaximizeIntent extends Intent {
  const _ToggleWaveformMaximizeIntent();
}

final _shortcuts = <ShortcutActivator, Intent>{
  // Waveform maximize toggle
  const SingleActivator(LogicalKeyboardKey.keyF):
      const _ToggleWaveformMaximizeIntent(),
  // Stage scoring
  const SingleActivator(LogicalKeyboardKey.keyW): const _ScoreIntent(
    SleepStage.wake,
  ),
  const SingleActivator(LogicalKeyboardKey.digit1): const _ScoreIntent(
    SleepStage.n1,
  ),
  const SingleActivator(LogicalKeyboardKey.digit2): const _ScoreIntent(
    SleepStage.n2,
  ),
  const SingleActivator(LogicalKeyboardKey.digit3): const _ScoreIntent(
    SleepStage.n3,
  ),
  const SingleActivator(LogicalKeyboardKey.keyR): const _ScoreIntent(
    SleepStage.rem,
  ),
  const SingleActivator(LogicalKeyboardKey.keyI): const _ScoreIntent(
    SleepStage.inconclusive,
  ),
  const SingleActivator(LogicalKeyboardKey.keyN): const _ScoreIntent(
    SleepStage.unknown,
  ),
  const SingleActivator(LogicalKeyboardKey.digit0): const _ScoreIntent(
    SleepStage.unknown,
  ),
  const SingleActivator(LogicalKeyboardKey.numpad0): const _ScoreIntent(
    SleepStage.unknown,
  ),
  const SingleActivator(LogicalKeyboardKey.delete): const _ScoreIntent(
    SleepStage.unknown,
  ),
  const SingleActivator(LogicalKeyboardKey.keyA): const _EventIntent(0),
  const SingleActivator(LogicalKeyboardKey.f1): const _EventIntent(1),
  const SingleActivator(LogicalKeyboardKey.f2): const _EventIntent(2),
  const SingleActivator(LogicalKeyboardKey.f3): const _EventIntent(3),
  const SingleActivator(LogicalKeyboardKey.f4): const _EventIntent(4),
  const SingleActivator(LogicalKeyboardKey.f5): const _EventIntent(5),
  const SingleActivator(LogicalKeyboardKey.f6): const _EventIntent(6),
  const SingleActivator(LogicalKeyboardKey.f7): const _EventIntent(7),
  const SingleActivator(LogicalKeyboardKey.f8): const _EventIntent(8),
  const SingleActivator(LogicalKeyboardKey.f9): const _EventIntent(9),
  const SingleActivator(LogicalKeyboardKey.f10): const _EventIntent(10),
  const SingleActivator(LogicalKeyboardKey.f11): const _EventIntent(11),
  const SingleActivator(LogicalKeyboardKey.f12): const _EventIntent(12),
  const SingleActivator(LogicalKeyboardKey.backspace):
      const _EraseEventsIntent(),
  const SingleActivator(LogicalKeyboardKey.keyZ): const _ZoomSelectionIntent(),
  // Markers & Video Shortcuts
  const SingleActivator(LogicalKeyboardKey.keyM): const _MarkersIntent(),
  const SingleActivator(LogicalKeyboardKey.keyV): const _ToggleVideoIntent(),
  // Detections
  const SingleActivator(LogicalKeyboardKey.keyK, control: true):
      const _KComplexDetectionIntent(),
  const SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true):
      const _SpindleDetectionIntent(),
  // Configuration & Filters
  const SingleActivator(LogicalKeyboardKey.keyC, control: true):
      const _ConfigIntent(),
  const SingleActivator(LogicalKeyboardKey.keyF, control: true):
      const _FilterIntent(),
  // Navigation
  const SingleActivator(LogicalKeyboardKey.arrowRight):
      const _NextEpochIntent(),
  const SingleActivator(LogicalKeyboardKey.arrowLeft):
      const _PreviousEpochIntent(),
  // Confidence uncertainty toggle
  const SingleActivator(LogicalKeyboardKey.keyQ):
      const _ToggleUncertaintyIntent(),
  const SingleActivator(LogicalKeyboardKey.keyU):
      const _ToggleUncertaintyIntent(),
};

// ─────────────────────────────────────────────────────────────────────────────

String _sidecarPath(String path, String suffix) {
  final dot = path.lastIndexOf('.');
  final base = dot >= 0 ? path.substring(0, dot) : path;
  return '$base$suffix';
}

String _analyseNidraScoringPath(String edfPath) {
  final scoringPath = '${_sidecarPath(edfPath, '')}_scoring.json';
  if (File(scoringPath).existsSync()) return scoringPath;
  final legacyPath = _sidecarPath(edfPath, '.json');
  return File(legacyPath).existsSync() ? legacyPath : scoringPath;
}

(double, double, double) _pdfStageColor(SleepStage stage) {
  return switch (stage) {
    SleepStage.wake => (0.34, 0.75, 0.55),
    SleepStage.rem => (0.55, 0.75, 0.34),
    SleepStage.n1 => (0.67, 0.74, 0.81),
    SleepStage.n2 => (0.25, 0.36, 0.47),
    SleepStage.n3 => (0.04, 0.11, 0.17),
    SleepStage.inconclusive => (0.12, 0.12, 0.12),
    SleepStage.unknown => (0.53, 0.53, 0.53),
  };
}

List<Map<String, String>> _parseCsvTable(String source) {
  final lines = const LineSplitter()
      .convert(source)
      .where((line) => line.trim().isNotEmpty)
      .toList();
  if (lines.length < 2) return const [];
  final headers = _parseCsvLine(lines.first);
  final rows = <Map<String, String>>[];
  for (final line in lines.skip(1)) {
    final values = _parseCsvLine(line);
    rows.add({
      for (var i = 0; i < headers.length; i++)
        headers[i]: i < values.length ? values[i] : '',
    });
  }
  return rows;
}

List<String> _parseCsvLine(String line) {
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

String _csvMetric(Map<String, String> row, String key, {int decimals = 2}) {
  var raw = row[key];
  if ((raw == null || raw.isEmpty) && key.startsWith('sp_')) {
    raw = row['sp_all_${key.substring(3)}'];
  } else if ((raw == null || raw.isEmpty) && key.startsWith('sp_all_')) {
    raw = row['sp_${key.substring(7)}'];
  }
  final value = double.tryParse(raw ?? '');
  if (value == null || !value.isFinite) return '-';
  return value.toStringAsFixed(decimals);
}

String _formatDurationCompact(double seconds) {
  if (seconds < 3600) return '${(seconds / 60).toStringAsFixed(1)} min';
  final hours = (seconds / 3600).floor();
  final minutes = ((seconds % 3600) / 60).round();
  return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
}

String? _detectMatchingEdf(String scoringPath) {
  final scoringFile = File(scoringPath);
  final directory = scoringFile.parent;
  if (!directory.existsSync()) return null;
  final scoringStem = _basename(_sidecarPath(scoringPath, ''));
  final normalizedStem = scoringStem.replaceFirst(
    RegExp(
      r'_(yasa|gssc|tinysleepnet|seqsleepnet|sleeptransformer|usleep|luna|dreamento|sleepeegpy)(?:_sleepgpt)?(?:_scoring)?$',
      caseSensitive: false,
    ),
    '',
  );
  final candidates = directory
      .listSync()
      .whereType<File>()
      .where(
        (file) =>
            file.path != scoringPath &&
            file.path.toLowerCase().endsWith('.edf'),
      )
      .toList();
  File? best;
  var bestLength = -1;
  for (final candidate in candidates) {
    final stem = _basename(_sidecarPath(candidate.path, ''));
    if (stem == normalizedStem ||
        scoringStem.startsWith(stem) ||
        stem.startsWith(normalizedStem)) {
      if (stem.length > bestLength) {
        best = candidate;
        bestLength = stem.length;
      }
    }
  }
  return best?.path;
}

List<String> _analyseNidraArguments(
  _AnalyseNidraJob job,
  List<String> channels,
  List<String> references, {
  double? lightsOffSeconds,
  double? lightsOnSeconds,
  String? outputDir,
  bool perChannel = false,
  String? regionMapJson,
  AnalyseNidraOptions? options,
  bool writeRegional = true,
  bool skipExisting = false,
}) {
  final baseDir = (outputDir != null && outputDir.trim().isNotEmpty)
      ? outputDir.trim()
      : File(job.edfPath).parent.path;
  final fileName = File(job.edfPath).path.split(Platform.isWindows ? r'\' : '/').last;
  final stem = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');
  final base = '$baseDir${Platform.pathSeparator}$stem';

  final args = [
    job.edfPath,
    job.mappedScoringPath,
    '${base}_analyse_core.json',
    '${base}_analyse_pac.json',
    '${base}_analyse_slow_waves.json',
    '${base}_analyse_spindles.json',
    writeRegional ? '${base}_analyse_regional.csv' : '-',
    '--channels',
    channels.join(','),
    '--references',
    references.join(','),
  ];
  if (outputDir != null && outputDir.trim().isNotEmpty) {
    args.addAll(['--out-dir', outputDir.trim()]);
  }
  if (lightsOffSeconds != null) {
    args.addAll(['--lights-off-sec', lightsOffSeconds.toStringAsFixed(3)]);
  }
  if (lightsOnSeconds != null) {
    args.addAll(['--lights-on-sec', lightsOnSeconds.toStringAsFixed(3)]);
  }
  if (perChannel) {
    args.add('--per-channel');
  }
  if (skipExisting) {
    args.add('--skip-existing');
  }
  if (regionMapJson != null && regionMapJson.trim().isNotEmpty) {
    args.addAll(['--region-map', regionMapJson.trim()]);
  }
  args.addAll(
    (options ?? AnalyseNidraOptions()).toArgs(nlgOutPath: '${base}_analyse_nlg.json'),
  );
  return args;
}

class _AnalyseNidraJob {
  const _AnalyseNidraJob({
    required this.edfPath,
    required this.scoringPath,
    required this.mappedScoringPath,
  });

  final String edfPath;
  final String scoringPath;
  final String mappedScoringPath;
}

class _CommandJob {
  const _CommandJob({
    required this.label,
    required this.executable,
    required this.arguments,
    this.sourcePath,
    this.outputDir,
  });

  final String label;
  final String executable;
  final List<String> arguments;
  final String? sourcePath;
  final String? outputDir;
}

class _CommandBatchProgressDialog extends StatefulWidget {
  const _CommandBatchProgressDialog({
    super.key,
    required this.title,
    required this.jobs,
    required this.onFinished,
  });

  final String title;
  final List<_CommandJob> jobs;
  final void Function(int failed) onFinished;

  @override
  State<_CommandBatchProgressDialog> createState() =>
      _CommandBatchProgressDialogState();
}

class _CommandBatchProgressDialogState
    extends State<_CommandBatchProgressDialog> {
  final List<String> _logs = [];
  final ScrollController _scrollController = ScrollController();
  int _completed = 0;
  int _failed = 0;
  bool _finished = false;
  String _current = '';

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _addLog(String line) {
    if (!mounted) return;
    setState(() {
      _logs.add(line);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _run() async {
    final backend = EegBackend();
    final startTime = DateTime.now();
    final batchResults = <BatchFileResult>[];
    String? masterLogFolder;

    for (final job in widget.jobs) {
      if (!mounted) return;
      setState(() {
        _current = job.label;
      });
      _addLog('--- ${job.label} ---');
      final currentJobLogs = <String>[];
      final exitCode = await backend.runCommandStreamAsync(
        executable: job.executable,
        arguments: job.arguments,
        onLine: (line) {
          currentJobLogs.add(line);
          _addLog(line);
        },
      );

      final logDir = (job.outputDir != null && job.outputDir!.trim().isNotEmpty)
          ? job.outputDir!.trim()
          : (job.sourcePath != null ? File(job.sourcePath!).parent.path : Directory.current.path);
      masterLogFolder ??= logDir;

      // Write per-file log file
      await writeBatchFileLog(
        outputFolder: logDir,
        originalFilePath: job.sourcePath ?? job.label,
        jobType: 'analyse',
        exitCode: exitCode,
        logLines: currentJobLogs,
      );

      batchResults.add(
        BatchFileResult(
          filePath: job.sourcePath ?? job.label,
          exitCode: exitCode,
          logs: currentJobLogs,
        ),
      );

      if (!mounted) return;
      setState(() {
        _completed++;
        if (exitCode != 0) _failed++;
      });
      _addLog(
        exitCode == 0
            ? 'Completed ${job.label}'
            : 'Failed ${job.label} with exit code $exitCode',
      );
    }

    // Write comprehensive single master run log
    if (masterLogFolder != null && batchResults.isNotEmpty) {
      final endTime = DateTime.now();
      await writeBatchRunSummaryLog(
        outputFolder: masterLogFolder,
        jobType: 'analyse',
        startTime: startTime,
        endTime: endTime,
        results: batchResults,
      );
      _addLog('\nMaster batch run log written to: $masterLogFolder');
    }

    if (mounted) setState(() => _finished = true);
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.jobs.isEmpty
        ? 0.0
        : _completed / widget.jobs.length;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 760,
        height: 500,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _finished
                  ? 'Finished ${widget.jobs.length} job(s)'
                  : 'Processing $_current (${_completed + 1}/${widget.jobs.length})',
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _finished ? 1 : progress),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                color: Colors.black87,
                padding: const EdgeInsets.all(8),
                child: ListView.builder(
                  controller: _scrollController,
                  itemCount: _logs.length,
                  itemBuilder: (_, index) => Text(
                    _logs[index],
                    style: const TextStyle(
                      color: Colors.lightGreenAccent,
                      fontFamily: 'Courier',
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _finished
              ? () {
                  Navigator.of(context).pop();
                  widget.onFinished(_failed);
                }
              : null,
          child: Text(_finished ? 'Close' : 'Processing…'),
        ),
      ],
    );
  }
}

class _PdfBatchJob {
  const _PdfBatchJob({
    required this.sourcePath,
    required this.sourceFile,
    required this.subjectId,
    required this.subjectDetails,
    required this.recordingDate,
    required this.regionalRows,
  });

  final String sourcePath;
  final String sourceFile;
  final String subjectId;
  final String subjectDetails;
  final String recordingDate;
  final List<Map<String, String>> regionalRows;
}

class _BatchPdfProgressDialog extends StatefulWidget {
  const _BatchPdfProgressDialog({
    super.key,
    required this.jobs,
    required this.includePages,
    required this.onFinished,
  });

  final List<_PdfBatchJob> jobs;
  final List<bool> includePages;
  final void Function(int completed, int failed) onFinished;

  @override
  State<_BatchPdfProgressDialog> createState() => _BatchPdfProgressDialogState();
}

class _BatchPdfProgressDialogState extends State<_BatchPdfProgressDialog> {
  final List<String> _logs = [];
  final ScrollController _scrollController = ScrollController();
  int _completed = 0;
  int _failed = 0;
  bool _finished = false;
  String _current = '';

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _addLog(String line) {
    if (!mounted) return;
    setState(() {
      _logs.add(line);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _run() async {
    final backend = EegBackend();
    for (final job in widget.jobs) {
      if (!mounted) return;
      setState(() {
        _current = job.sourceFile;
      });
      _addLog('Processing ${job.sourceFile}...');

      try {
        final edfPath = job.sourcePath;
        if (!File(edfPath).existsSync()) {
          throw FileSystemException('EDF file not found', edfPath);
        }

        final rawEeg = backend.loadEdf(edfPath);
        final autoCfg = await tryLoadAutoConfig(edfPath);
        final activeConfig = autoCfg ?? AppConfig.defaultsForChannels(
          rawEeg.channelLabels,
          sampleRateHz: rawEeg.sampleRateHz,
        );
        activeConfig.bindLoadedChannels(
          rawEeg.channelLabels,
          sampleRateHz: rawEeg.sampleRateHz,
        );

        final eeg = await backend.computeNightProducts(rawEeg, activeConfig);
        final epochCount = (eeg.durationSeconds / 30).ceil();
        final loadResult = await tryLoadAutoScoring(edfPath, epochCount);
        final existingStages = loadResult?.stages;
        final existingStagesUncertain = loadResult?.stagesUncertain;
        final existingEvents = await tryLoadAutoEvents(edfPath);

        final viewport = await backend.viewportFromEeg(
          eeg,
          currentEpoch: 0,
          config: activeConfig,
          existingStages: existingStages,
          existingStagesUncertain: existingStagesUncertain,
          existingConfidence: loadResult?.stagesConfidence,
          existingStageProbabilities: loadResult?.stageProbabilities,
          includeTimeFrequency: false,
        );
        final fullViewport = viewport.copyWith(scoredEvents: existingEvents);

        final pages = widget.includePages;
        final respiratoryReport = pages.length > 5 && pages[5]
            ? await loadPsgReport(respiratoryReportPath(edfPath))
            : null;
        final plmReport = pages.length > 6 && pages[6]
            ? await loadPsgReport(plmReportPath(edfPath))
            : null;
        final capReport = pages.length > 7 && pages[7]
            ? await loadPsgReport(capReportPath(edfPath))
            : null;
        final nlgReport = pages.length > 8 && pages[8]
            ? await loadPsgReport(nlgSidecarPath(edfPath))
            : null;
        final bytes = buildPublicationSleepReport(
          viewport: fullViewport,
          recordingName: _basename(edfPath),
          regionalRows: job.regionalRows,
          includePages: pages.length > 5 ? pages.sublist(0, 5) : pages,
          respiratoryReport: respiratoryReport,
          plmReport: plmReport,
          capReport: capReport,
          nlgReport: nlgReport,
          metadata: ReportMetadata(
            title: activeConfig.reportTitle,
            studySite: activeConfig.studySite,
            investigatorName: activeConfig.investigatorName,
            subjectId: job.subjectId,
            subjectDetails: job.subjectDetails,
            recordingDate: job.recordingDate,
          ),
        );

        final dotIdx = edfPath.lastIndexOf('.');
        final reportPath = '${dotIdx >= 0 ? edfPath.substring(0, dotIdx) : edfPath}.report.pdf';
        await File(reportPath).writeAsBytes(bytes);

        setState(() {
          _completed++;
        });
        _addLog('Successfully generated report: ${_basename(reportPath)}');
      } catch (e) {
        setState(() {
          _failed++;
        });
        _addLog('ERROR processing ${job.sourceFile}: $e');
      }
    }

    setState(() {
      _finished = true;
    });
    _addLog('--- Completed: $_completed succeeded, $_failed failed ---');
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.jobs.isEmpty
        ? 1.0
        : (_completed + _failed) / widget.jobs.length;

    return AlertDialog(
      title: const Text('Batch PDF Report Generation'),
      content: SizedBox(
        width: 500,
        height: 350,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _finished
                  ? 'Batch PDF generation complete!'
                  : 'Generating report for: $_current',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F5F5),
                  border: Border.all(color: const Color(0xFFD0D0D0)),
                ),
                padding: const EdgeInsets.all(8),
                child: ListView.builder(
                  controller: _scrollController,
                  itemCount: _logs.length,
                  itemBuilder: (context, index) {
                    return Text(
                      _logs[index],
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        ElevatedButton(
          onPressed: _finished ? () {
            Navigator.of(context).pop();
            widget.onFinished(_completed, _failed);
          } : null,
          child: const Text('Close'),
        ),
      ],
    );
  }
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

List<String> _parseChannelList(String value) {
  final seen = <String>{};
  return value
      .split(',')
      .map((channel) => channel.trim())
      .where((channel) => channel.isNotEmpty && seen.add(channel))
      .toList();
}

Future<List<(double, double)>> _runKComplexIsolate(
  List<double> signal,
  double sfreq,
  double amin,
  double dmax_s,
  double q,
  double fmax,
) {
  return Isolate.run(() {
    return sp.detectKComplex(
      signal,
      sfreq,
      amin: amin,
      dmax_s: dmax_s,
      q: q,
      fmax: fmax,
    );
  });
}

Future<List<(double, double)>> _runSpindleIsolate(
  List<double> signal,
  double sfreq,
  double fmin,
  double fmax,
  double amin,
  double dmin_s,
  double dmax_s,
  double q,
) {
  return Isolate.run(() {
    return sp.detectSpindles(
      signal,
      sfreq,
      fmin: fmin,
      fmax: fmax,
      amin: amin,
      dmin_s: dmin_s,
      dmax_s: dmax_s,
      q: q,
    );
  });
}

enum _SimilarEpochAction { stage, event }

class _SimilarEpochSettings {
  const _SimilarEpochSettings({
    required this.channelIndices,
    required this.minSimilarity,
    required this.maxMatches,
    required this.action,
    required this.stage,
    required this.eventDigit,
    required this.skipCurrentEpoch,
  });

  final Set<int> channelIndices;
  final double minSimilarity;
  final int maxMatches;
  final _SimilarEpochAction action;
  final SleepStage stage;
  final int eventDigit;
  final bool skipCurrentEpoch;

  String get actionLabel => action == _SimilarEpochAction.stage
      ? stage.label
      : (eventDigit == 0 ? 'Artifact' : 'Event $eventDigit');
}

class _SimilarEpochMatch {
  const _SimilarEpochMatch({required this.epoch, required this.similarity});

  final int epoch;
  final double similarity;
}

class _SimilarChannelOption {
  const _SimilarChannelOption({required this.label, required this.sourceIndex});

  final String label;
  final int sourceIndex;
}

class _SimilarEpochDialog extends StatefulWidget {
  const _SimilarEpochDialog({
    required this.channelOptions,
    required this.initialStage,
  });

  final List<_SimilarChannelOption> channelOptions;
  final SleepStage initialStage;

  @override
  State<_SimilarEpochDialog> createState() => _SimilarEpochDialogState();
}

class _SimilarEpochDialogState extends State<_SimilarEpochDialog> {
  late final Set<int> _channels = {
    for (final option in widget.channelOptions) option.sourceIndex,
  };
  double _minSimilarity = 0.82;
  int _maxMatches = 50;
  _SimilarEpochAction _action = _SimilarEpochAction.stage;
  late SleepStage _stage = widget.initialStage;
  int _eventDigit = 0;
  bool _skipCurrentEpoch = true;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Find Similar Epochs'),
      content: SizedBox(
        width: 620,
        height: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Learns the current epoch as a lightweight pattern template and '
              'searches the loaded recording using per-channel time-domain and '
              'band-power features.',
              style: TextStyle(fontSize: 12, color: Colors.black87),
            ),
            const SizedBox(height: 14),
            const Text(
              'Channels used for matching',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    _channels
                      ..clear()
                      ..addAll(
                        widget.channelOptions.map(
                          (option) => option.sourceIndex,
                        ),
                      );
                  }),
                  child: const Text('Select all channels'),
                ),
                TextButton(
                  onPressed: () => setState(() => _channels.clear()),
                  child: const Text('Deselect all'),
                ),
              ],
            ),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFFD0D0D0)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: ListView.builder(
                  itemCount: widget.channelOptions.length,
                  itemBuilder: (context, index) {
                    final option = widget.channelOptions[index];
                    return CheckboxListTile(
                      dense: true,
                      value: _channels.contains(option.sourceIndex),
                      title: Text(option.label),
                      onChanged: (value) {
                        setState(() {
                          if (value ?? false) {
                            _channels.add(option.sourceIndex);
                          } else {
                            _channels.remove(option.sourceIndex);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _minSimilarity,
                    min: 0.5,
                    max: 0.98,
                    divisions: 48,
                    label: '${(_minSimilarity * 100).round()}%',
                    onChanged: (value) => setState(() {
                      _minSimilarity = value;
                    }),
                  ),
                ),
                SizedBox(
                  width: 170,
                  child: Text(
                    'Minimum similarity: ${(_minSimilarity * 100).round()}%',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                const Expanded(child: Text('Maximum epochs to apply')),
                SizedBox(
                  width: 90,
                  child: TextFormField(
                    initialValue: _maxMatches.toString(),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      final parsed = int.tryParse(value);
                      if (parsed != null && parsed > 0) {
                        setState(() => _maxMatches = parsed);
                      }
                    },
                  ),
                ),
              ],
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: _skipCurrentEpoch,
              title: const Text('Do not relabel the current template epoch'),
              onChanged: (value) => setState(() {
                _skipCurrentEpoch = value ?? true;
              }),
            ),
            const Divider(height: 18),
            Row(
              children: [
                Expanded(
                  child: RadioListTile<_SimilarEpochAction>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: _SimilarEpochAction.stage,
                    groupValue: _action,
                    title: const Text('Apply sleep stage'),
                    onChanged: (value) => setState(() => _action = value!),
                  ),
                ),
                Expanded(
                  child: DropdownButtonFormField<SleepStage>(
                    value: _stage,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: SleepStage.wake,
                        child: Text('Wake'),
                      ),
                      DropdownMenuItem(value: SleepStage.n1, child: Text('N1')),
                      DropdownMenuItem(value: SleepStage.n2, child: Text('N2')),
                      DropdownMenuItem(value: SleepStage.n3, child: Text('N3')),
                      DropdownMenuItem(
                        value: SleepStage.rem,
                        child: Text('REM'),
                      ),
                      DropdownMenuItem(
                        value: SleepStage.inconclusive,
                        child: Text('Inconclusive'),
                      ),
                    ],
                    onChanged: _action == _SimilarEpochAction.stage
                        ? (value) => setState(() => _stage = value ?? _stage)
                        : null,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: RadioListTile<_SimilarEpochAction>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: _SimilarEpochAction.event,
                    groupValue: _action,
                    title: const Text('Apply artifact/event marker'),
                    onChanged: (value) => setState(() => _action = value!),
                  ),
                ),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    value: _eventDigit,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem(value: 0, child: Text('Artifact')),
                      for (var i = 1; i <= 12; i++)
                        DropdownMenuItem(value: i, child: Text('Event $i')),
                    ],
                    onChanged: _action == _SimilarEpochAction.event
                        ? (value) =>
                              setState(() => _eventDigit = value ?? _eventDigit)
                        : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _channels.isEmpty
              ? null
              : () {
                  Navigator.of(context).pop(
                    _SimilarEpochSettings(
                      channelIndices: Set<int>.from(_channels),
                      minSimilarity: _minSimilarity,
                      maxMatches: _maxMatches,
                      action: _action,
                      stage: _stage,
                      eventDigit: _eventDigit,
                      skipCurrentEpoch: _skipCurrentEpoch,
                    ),
                  );
                },
          child: const Text('Find and Apply'),
        ),
      ],
    );
  }
}

class _SimilarEpochResultsDialog extends StatefulWidget {
  const _SimilarEpochResultsDialog({
    required this.matches,
    required this.viewport,
    required this.actionLabel,
    required this.onJumpToEpoch,
  });

  final List<_SimilarEpochMatch> matches;
  final EegViewport viewport;
  final String actionLabel;
  final void Function(int epoch) onJumpToEpoch;

  @override
  State<_SimilarEpochResultsDialog> createState() =>
      _SimilarEpochResultsDialogState();
}

class _SimilarEpochResultsDialogState
    extends State<_SimilarEpochResultsDialog> {
  late final Set<int> _selectedEpochs = {
    for (final match in widget.matches) match.epoch,
  };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Similar Epoch Matches'),
      content: SizedBox(
        width: 680,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.matches.length} candidate epochs found. Review, jump, '
              'and select epochs before applying ${widget.actionLabel}.',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFFD0D0D0)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: ListView.separated(
                  itemCount: widget.matches.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final match = widget.matches[index];
                    final stage = match.epoch < widget.viewport.stages.length
                        ? widget.viewport.stages[match.epoch]
                        : SleepStage.unknown;
                    final start =
                        match.epoch * widget.viewport.epochSeconds.toDouble();
                    return CheckboxListTile(
                      dense: true,
                      value: _selectedEpochs.contains(match.epoch),
                      onChanged: (value) => setState(() {
                        if (value ?? false) {
                          _selectedEpochs.add(match.epoch);
                        } else {
                          _selectedEpochs.remove(match.epoch);
                        }
                      }),
                      title: Text(
                        'Epoch ${match.epoch + 1}  |  '
                        '${_formatSecondsForSimilarDialog(start)}  |  '
                        'Current: ${stage.label}',
                      ),
                      subtitle: Text(
                        'Similarity ${(match.similarity * 100).toStringAsFixed(1)}%',
                      ),
                      secondary: TextButton(
                        onPressed: () => widget.onJumpToEpoch(match.epoch),
                        child: const Text('Go'),
                      ),
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
          onPressed: () => setState(() => _selectedEpochs.clear()),
          child: const Text('Clear'),
        ),
        TextButton(
          onPressed: () => setState(() {
            _selectedEpochs
              ..clear()
              ..addAll(widget.matches.map((match) => match.epoch));
          }),
          child: const Text('Select All'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _selectedEpochs.isEmpty
              ? null
              : () => Navigator.of(context).pop(
                  widget.matches
                      .where((match) => _selectedEpochs.contains(match.epoch))
                      .toList(),
                ),
          child: const Text('Apply Selected'),
        ),
      ],
    );
  }
}

String _formatSecondsForSimilarDialog(double seconds) {
  final total = seconds.round();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  if (h > 0) {
    return '${h}h ${m.toString().padLeft(2, '0')}m';
  }
  return '${m}m ${s.toString().padLeft(2, '0')}s';
}

List<List<double>> _computeEpochPatternFeatures(
  LoadedEeg eeg,
  int epochSeconds,
  List<int> channelIndices,
) {
  final epochSamples = (epochSeconds * eeg.sampleRateHz).round();
  if (epochSamples <= 0 || eeg.channelSamples.isEmpty) return const [];
  final epochCount = (eeg.durationSeconds / epochSeconds).ceil();
  final rows = List.generate(epochCount, (_) => <double>[]);
  for (final channelIndex in channelIndices) {
    if (channelIndex < 0 || channelIndex >= eeg.channelSamples.length) {
      continue;
    }
    final signal = eeg.channelSamples[channelIndex];
    for (var epoch = 0; epoch < epochCount; epoch++) {
      final start = epoch * epochSamples;
      if (start >= signal.length) break;
      final end = math.min(signal.length, start + epochSamples);
      final slice = signal.sublist(start, end);
      rows[epoch].addAll(_epochPatternFeatures(slice, eeg.sampleRateHz));
    }
  }
  return rows;
}

List<double> _epochPatternFeatures(List<double> signal, double sampleRate) {
  if (signal.isEmpty) return List.filled(11, 0.0);
  var sum = 0.0;
  var sumSq = 0.0;
  var minValue = signal.first;
  var maxValue = signal.first;
  var lineLength = 0.0;
  var zeroCrossings = 0;
  for (var i = 0; i < signal.length; i++) {
    final value = signal[i];
    sum += value;
    sumSq += value * value;
    minValue = math.min(minValue, value);
    maxValue = math.max(maxValue, value);
    if (i > 0) {
      lineLength += (value - signal[i - 1]).abs();
      if ((value >= 0 && signal[i - 1] < 0) ||
          (value < 0 && signal[i - 1] >= 0)) {
        zeroCrossings++;
      }
    }
  }
  final n = signal.length.toDouble();
  final mean = sum / n;
  final variance = math.max(0.0, sumSq / n - mean * mean);
  final std = math.sqrt(variance);
  final centered = [for (final value in signal) value - mean];
  final (psd, freqs) = sp.welchPsd(centered, sampleRate);
  final totalPower = _bandPower(psd, freqs, 0.5, 35.0);
  double relBand(double low, double high) {
    if (totalPower <= 1e-12) return 0.0;
    return _bandPower(psd, freqs, low, high) / totalPower;
  }

  return [
    mean,
    std,
    maxValue - minValue,
    math.sqrt(sumSq / n),
    lineLength / n,
    zeroCrossings / n,
    relBand(0.5, 4.0),
    relBand(4.0, 8.0),
    relBand(8.0, 12.0),
    relBand(12.0, 16.0),
    relBand(16.0, 30.0),
  ];
}

double _bandPower(
  List<double> psd,
  List<double> freqs,
  double low,
  double high,
) {
  var total = 0.0;
  for (var i = 0; i < psd.length && i < freqs.length; i++) {
    if (freqs[i] >= low && freqs[i] < high) total += psd[i];
  }
  return total;
}

List<List<double>> _zNormalizeFeatureMatrix(List<List<double>> matrix) {
  if (matrix.isEmpty) return const [];
  final width = matrix.map((row) => row.length).fold<int>(0, math.max);
  if (width == 0) return matrix;
  final means = List<double>.filled(width, 0.0);
  final counts = List<int>.filled(width, 0);
  for (final row in matrix) {
    for (var i = 0; i < row.length; i++) {
      if (row[i].isFinite) {
        means[i] += row[i];
        counts[i]++;
      }
    }
  }
  for (var i = 0; i < width; i++) {
    if (counts[i] > 0) means[i] /= counts[i];
  }
  final variances = List<double>.filled(width, 0.0);
  for (final row in matrix) {
    for (var i = 0; i < row.length; i++) {
      if (row[i].isFinite) {
        final delta = row[i] - means[i];
        variances[i] += delta * delta;
      }
    }
  }
  final scales = [
    for (var i = 0; i < width; i++)
      counts[i] > 1 ? math.sqrt(variances[i] / (counts[i] - 1)) : 1.0,
  ];
  return [
    for (final row in matrix)
      [
        for (var i = 0; i < width; i++)
          i < row.length && row[i].isFinite
              ? (row[i] - means[i]) / math.max(scales[i], 1e-9)
              : 0.0,
      ],
  ];
}

double _euclideanDistance(List<double> a, List<double> b) {
  final n = math.min(a.length, b.length);
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    final delta = a[i] - b[i];
    sum += delta * delta;
  }
  return math.sqrt(sum / math.max(1, n));
}

// ─────────────────────────────────────────────────────────────────────────────
// Scoring Comparison Metrics & Report Card Dialog
// ─────────────────────────────────────────────────────────────────────────────

class _StageComparisonMetrics {
  _StageComparisonMetrics({
    required this.totalEpochs,
    required this.comparedEpochs,
    required this.overallAgreement,
    required this.cohensKappa,
    required this.confusionMatrix,
    required this.precision,
    required this.recall,
    required this.f1Score,
  });

  final int totalEpochs;
  final int comparedEpochs;
  final double overallAgreement;
  final double cohensKappa;
  final Map<SleepStage, Map<SleepStage, int>> confusionMatrix;
  final Map<SleepStage, double> precision;
  final Map<SleepStage, double> recall;
  final Map<SleepStage, double> f1Score;

  String get kappaStrength {
    if (cohensKappa < 0.20) return 'Slight';
    if (cohensKappa < 0.40) return 'Fair';
    if (cohensKappa < 0.60) return 'Moderate';
    if (cohensKappa < 0.80) return 'Substantial';
    return 'Almost Perfect';
  }

  factory _StageComparisonMetrics.compute(
    List<SleepStage> current,
    List<SleepStage> comparison,
  ) {
    final stages = [
      SleepStage.wake,
      SleepStage.rem,
      SleepStage.n1,
      SleepStage.n2,
      SleepStage.n3,
    ];

    final total = current.length < comparison.length
        ? current.length
        : comparison.length;

    var validCount = 0;
    var matches = 0;

    final matrix = <SleepStage, Map<SleepStage, int>>{};
    for (final s1 in stages) {
      matrix[s1] = {};
      for (final s2 in stages) {
        matrix[s1]![s2] = 0;
      }
    }

    for (var i = 0; i < total; i++) {
      final sCurr = current[i];
      final sComp = comparison[i];

      if (!stages.contains(sCurr) || !stages.contains(sComp)) {
        continue;
      }

      validCount++;
      if (sCurr == sComp) {
        matches++;
      }
      matrix[sCurr]![sComp] = (matrix[sCurr]![sComp] ?? 0) + 1;
    }

    final agreement = validCount == 0 ? 0.0 : (matches / validCount) * 100.0;

    double kappa = 0.0;
    if (validCount > 0) {
      final po = matches / validCount;
      double pe = 0.0;
      for (final s in stages) {
        var rowSum = 0;
        for (final sComp in stages) {
          rowSum += matrix[s]![sComp] ?? 0;
        }
        var colSum = 0;
        for (final sCurr in stages) {
          colSum += matrix[sCurr]![s] ?? 0;
        }
        pe += (rowSum / validCount) * (colSum / validCount);
      }
      if (pe < 1.0) {
        kappa = (po - pe) / (1.0 - pe);
      } else {
        kappa = 1.0;
      }
    }

    final prec = <SleepStage, double>{};
    final rec = <SleepStage, double>{};
    final f1 = <SleepStage, double>{};

    for (final s in stages) {
      final tp = matrix[s]![s] ?? 0;

      var fp = 0;
      for (final sComp in stages) {
        if (sComp != s) {
          fp += matrix[s]![sComp] ?? 0;
        }
      }

      var fn = 0;
      for (final sCurr in stages) {
        if (sCurr != s) {
          fn += matrix[sCurr]![s] ?? 0;
        }
      }

      final p = (tp + fp) == 0 ? 0.0 : tp / (tp + fp);
      final r = (tp + fn) == 0 ? 0.0 : tp / (tp + fn);
      final f = (p + r) == 0 ? 0.0 : (2.0 * p * r) / (p + r);

      prec[s] = p * 100.0;
      rec[s] = r * 100.0;
      f1[s] = f * 100.0;
    }

    return _StageComparisonMetrics(
      totalEpochs: total,
      comparedEpochs: validCount,
      overallAgreement: agreement,
      cohensKappa: kappa,
      confusionMatrix: matrix,
      precision: prec,
      recall: rec,
      f1Score: f1,
    );
  }
}

class _ComparisonReportCardDialog extends StatelessWidget {
  const _ComparisonReportCardDialog({required this.metrics});

  final _StageComparisonMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;

    Color getKappaColor(double kappa) {
      if (kappa >= 0.8) return Colors.green.shade700;
      if (kappa >= 0.6) return Colors.blue.shade700;
      if (kappa >= 0.4) return Colors.orange.shade700;
      return Colors.red.shade700;
    }

    String getKappaStrength(double kappa) {
      if (kappa >= 0.8) return 'Almost Perfect';
      if (kappa >= 0.6) return 'Substantial';
      if (kappa >= 0.4) return 'Moderate';
      if (kappa >= 0.2) return 'Fair';
      if (kappa > 0) return 'Slight';
      return 'Poor/None';
    }

    final kappaColor = getKappaColor(metrics.cohensKappa);
    final kappaStrength = getKappaStrength(metrics.cohensKappa);

    final stages = [
      SleepStage.wake,
      SleepStage.rem,
      SleepStage.n1,
      SleepStage.n2,
      SleepStage.n3,
    ];

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 800,
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.assessment,
                        color: Colors.indigo,
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Scoring Comparison Report Card',
                        style: textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: Colors.indigo.shade900,
                        ),
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const Divider(height: 24, thickness: 1),

              GridView.count(
                crossAxisCount: 3,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 2.2,
                children: [
                  _buildStatCard(
                    title: 'Compared Epochs',
                    value: '${metrics.comparedEpochs} / ${metrics.totalEpochs}',
                    subtitle: 'Valid matched epochs',
                    icon: Icons.list_alt,
                    iconColor: Colors.grey.shade700,
                  ),
                  _buildStatCard(
                    title: 'Overall Agreement',
                    value: '${metrics.overallAgreement.toStringAsFixed(1)}%',
                    subtitle: 'Total matching epochs',
                    icon: Icons.check_circle_outline,
                    iconColor: Colors.green.shade600,
                  ),
                  _buildStatCard(
                    title: "Cohen's Kappa (κ)",
                    value: metrics.cohensKappa.toStringAsFixed(3),
                    subtitle: '$kappaStrength agreement',
                    icon: Icons.psychology,
                    iconColor: kappaColor,
                  ),
                ],
              ),
              const SizedBox(height: 24),

              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 11,
                    child: Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        side: BorderSide(color: Colors.grey.shade200),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Confusion Matrix',
                              style: textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: Colors.blueGrey.shade800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Current Scorer (Rows) vs. Comparison (Columns)',
                              style: textTheme.bodySmall?.copyWith(
                                color: Colors.grey.shade600,
                              ),
                            ),
                            const SizedBox(height: 16),
                            _buildConfusionMatrixTable(stages),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 13,
                    child: Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        side: BorderSide(color: Colors.grey.shade200),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Stage-Specific Metrics',
                              style: textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: Colors.blueGrey.shade800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Precision, Recall (Sensitivity), and F1-Score',
                              style: textTheme.bodySmall?.copyWith(
                                color: Colors.grey.shade600,
                              ),
                            ),
                            const SizedBox(height: 16),
                            _buildStageMetricsTable(stages),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.indigo,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color iconColor,
  }) {
    return Card(
      elevation: 0,
      color: Colors.grey.shade50,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Colors.grey.shade200),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfusionMatrixTable(List<SleepStage> stages) {
    final headerStyle = TextStyle(
      fontWeight: FontWeight.bold,
      fontSize: 12,
      color: Colors.blueGrey.shade700,
    );

    return Table(
      border: TableBorder.all(
        color: Colors.grey.shade200,
        width: 1,
        borderRadius: BorderRadius.circular(4),
      ),
      columnWidths: const {
        0: FlexColumnWidth(1.2),
        1: FlexColumnWidth(1),
        2: FlexColumnWidth(1),
        3: FlexColumnWidth(1),
        4: FlexColumnWidth(1),
        5: FlexColumnWidth(1),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          decoration: BoxDecoration(color: Colors.grey.shade100),
          children: [
            const TableCell(
              child: SizedBox(
                height: 32,
                child: Center(
                  child: Text(
                    'Cur \\ Cmp',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
            for (final s in stages)
              TableCell(
                child: Center(child: Text(s.shortLabel, style: headerStyle)),
              ),
          ],
        ),
        for (final sCurr in stages)
          TableRow(
            children: [
              TableCell(
                child: Container(
                  height: 36,
                  color: Colors.grey.shade50,
                  alignment: Alignment.center,
                  child: Text(sCurr.label, style: headerStyle),
                ),
              ),
              for (final sComp in stages) _buildConfusionCell(sCurr, sComp),
            ],
          ),
      ],
    );
  }

  Widget _buildConfusionCell(SleepStage sCurr, SleepStage sComp) {
    final count = metrics.confusionMatrix[sCurr]?[sComp] ?? 0;
    final isDiag = sCurr == sComp;

    double opacity = 0.0;
    Color cellColor = Colors.transparent;

    if (count > 0) {
      var maxInRow = 1;
      metrics.confusionMatrix[sCurr]?.forEach((_, val) {
        if (val > maxInRow) maxInRow = val;
      });

      opacity = count / maxInRow;
      opacity = 0.05 + opacity * 0.75;
      cellColor = isDiag
          ? Colors.green.shade500.withOpacity(opacity)
          : Colors.red.shade400.withOpacity(opacity);
    }

    return TableCell(
      child: Container(
        height: 36,
        color: cellColor,
        alignment: Alignment.center,
        child: Text(
          '$count',
          style: TextStyle(
            fontWeight: isDiag ? FontWeight.bold : FontWeight.normal,
            color: count == 0
                ? Colors.grey.shade400
                : (opacity > 0.5 ? Colors.white : Colors.black87),
            fontSize: 12,
          ),
        ),
      ),
    );
  }

  Widget _buildStageMetricsTable(List<SleepStage> stages) {
    final headerStyle = TextStyle(
      fontWeight: FontWeight.bold,
      fontSize: 12,
      color: Colors.blueGrey.shade700,
    );

    return Table(
      columnWidths: const {
        0: FlexColumnWidth(1.2),
        1: FlexColumnWidth(1),
        2: FlexColumnWidth(1),
        3: FlexColumnWidth(1),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        TableRow(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: Colors.grey.shade300, width: 1.5),
            ),
          ),
          children: [
            const TableCell(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Stage',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ),
            TableCell(
              child: Center(child: Text('Precision', style: headerStyle)),
            ),
            TableCell(
              child: Center(child: Text('Recall', style: headerStyle)),
            ),
            TableCell(
              child: Center(child: Text('F1-Score', style: headerStyle)),
            ),
          ],
        ),
        for (final s in stages)
          TableRow(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: Colors.grey.shade100)),
            ),
            children: [
              TableCell(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: _colorForStage(s),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        s.label,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              TableCell(
                child: Center(
                  child: Text(
                    '${metrics.precision[s]?.toStringAsFixed(1)}%',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              TableCell(
                child: Center(
                  child: Text(
                    '${metrics.recall[s]?.toStringAsFixed(1)}%',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              TableCell(
                child: Center(
                  child: Text(
                    '${metrics.f1Score[s]?.toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: _colorForF1(metrics.f1Score[s] ?? 0),
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Color _colorForStage(SleepStage stage) {
    switch (stage) {
      case SleepStage.wake:
        return const Color(0xFF56bf8b);
      case SleepStage.rem:
        return const Color(0xFF8bbf56);
      case SleepStage.n1:
        return const Color(0xFFaabcce);
      case SleepStage.n2:
        return const Color(0xFF405c79);
      case SleepStage.n3:
        return const Color(0xFF0b1c2c);
      default:
        return Colors.grey;
    }
  }

  Color _colorForF1(double score) {
    if (score >= 80.0) return Colors.green.shade700;
    if (score >= 60.0) return Colors.blue.shade700;
    if (score >= 40.0) return Colors.orange.shade700;
    return Colors.red.shade700;
  }
}

class _AutoScoringTask {
  final String executable;
  final List<String> arguments;
  final SendPort sendPort;

  _AutoScoringTask({
    required this.executable,
    required this.arguments,
    required this.sendPort,
  });

  (int, String) run() {
    final backend = EegBackend();
    var outPath = '';
    final exitCode = backend.runCommandStream(
      executable: executable,
      arguments: arguments,
      onLine: (line) {
        sendPort.send(line);
        if (line.contains('Saved ScoringHero JSON:')) {
          final match = RegExp(
            r'Saved ScoringHero JSON:\s*(.*)',
          ).firstMatch(line);
          if (match != null) {
            outPath = match.group(1)!.trim();
          }
        }
      },
    );
    return (exitCode, outPath);
  }
}

String _outputPathFromLogs(List<String> lines) {
  for (final line in lines.reversed) {
    final match = RegExp(r'Saved ScoringHero JSON:\s*(.*)').firstMatch(line);
    if (match != null) return match.group(1)!.trim();
    final rustMatch = RegExp(r"""OUTPUT_SCORING\s+["']?([^"'\r\n]+)["']?""").firstMatch(line);
    if (rustMatch != null) return rustMatch.group(1)!.trim();
  }
  return '';
}

(double, String)? _scoringProgressFromLine(String line) {
  final protocol = RegExp(
    r'PROGRESS\s+([01](?:\.\d+)?)\s+(.+)',
  ).firstMatch(line);
  if (protocol != null) {
    return (
      (double.tryParse(protocol.group(1)!) ?? 0).clamp(0.0, 1.0),
      protocol.group(2)!.trim(),
    );
  }

  final epochs = RegExp(
    r'progress:\s*(\d+)/(\d+)\s+epochs',
    caseSensitive: false,
  ).firstMatch(line);
  if (epochs != null) {
    final done = int.tryParse(epochs.group(1)!) ?? 0;
    final total = int.tryParse(epochs.group(2)!) ?? 0;
    if (total > 0) {
      return (
        0.22 + 0.63 * (done / total).clamp(0.0, 1.0),
        'Scoring epochs: $done of $total',
      );
    }
  }
  return null;
}

class BatchProgressDialog extends StatefulWidget {
  const BatchProgressDialog({
    super.key,
    required this.files,
    required this.algorithm,
    required this.correction,
    required this.sleepgptAlpha,
    required this.sleepgptNgram,
    required this.eegChannels,
    required this.refChannels,
    required this.eogChannels,
    required this.emgChannels,
    this.outputDir,
    required this.onFinished,
  });

  final List<String> files;
  final String algorithm;
  final String correction;
  final double sleepgptAlpha;
  final int sleepgptNgram;
  final List<String> eegChannels;
  final List<String> refChannels;
  final List<String> eogChannels;
  final List<String> emgChannels;
  final String? outputDir;
  final void Function() onFinished;

  @override
  State<BatchProgressDialog> createState() => _BatchProgressDialogState();
}

class _BatchProgressDialogState extends State<BatchProgressDialog> {
  final Map<String, String> _statuses = {};
  final List<String> _logLines = [];
  final StreamController<String> _logsStream = StreamController<String>();
  final ScrollController _scrollController = ScrollController();
  String _currentFile = '';
  int _currentIndex = 0;
  bool _isFinished = false;
  bool _isCancelled = false;
  double _fileProgress = 0.0;
  String _progressLabel = 'Preparing next recording...';

  @override
  void initState() {
    super.initState();
    for (final file in widget.files) {
      _statuses[file] = 'Pending';
    }
    _startBatch();
  }

  @override
  void dispose() {
    _logsStream.close();
    _scrollController.dispose();
    super.dispose();
  }

  void _addLog(String line) {
    if (!mounted) return;
    final update = _scoringProgressFromLine(line);
    setState(() {
      _logLines.add(line);
      if (update != null) {
        _fileProgress = math.max(_fileProgress, update.$1);
        _progressLabel = update.$2;
      }
    });
    _logsStream.add(line);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Future<void> _startBatch() async {
    if (!isAnalyseNidraAvailable()) {
      for (final file in widget.files) {
        _statuses[file] = 'Failed';
      }
      _addLog(
        'The native analyse-nidra engine was not found beside the application. '
        'Reinstall CCS Sleep Studio to restore autoscoring.',
      );
      if (mounted) setState(() => _isFinished = true);
      return;
    }
    final rustExecutable = detectAnalyseNidraExecutable();
    final algorithm = canonicalAutoscoreAlgorithm(widget.algorithm);
    final outDir = (widget.outputDir != null && widget.outputDir!.trim().isNotEmpty)
        ? widget.outputDir!.trim()
        : null;

    final startTime = DateTime.now();
    final batchResults = <BatchFileResult>[];
    String? masterLogFolder;

    for (int i = 0; i < widget.files.length; i++) {
      if (_isCancelled) break;

      final file = widget.files[i];
      if (!mounted) break;
      setState(() {
        _currentIndex = i;
        _currentFile = file;
        _statuses[file] = 'Scoring…';
        _logLines.clear();
        _fileProgress = 0.0;
        _progressLabel = 'Starting ${_basename(file)}...';
      });
      _addLog('--- Starting AutoscoreNidra for ${_basename(file)} ---');

      int fileExitCode = 1;
      final fileLogs = <String>[];
      Directory? tempDir;

      try {
        var stageInput = file;
        String? explicitOut;
        if (!analyseNidraReadsNatively(file)) {
          _addLog('Converting ${_basename(file)} to a temporary EDF for the native engine…');
          tempDir = await Directory.systemTemp.createTemp('ccs_autoscore_');
          var stem = _basename(file);
          final dot = stem.lastIndexOf('.');
          if (dot > 0) stem = stem.substring(0, dot);
          stageInput = '${tempDir.path}${Platform.pathSeparator}$stem.edf';
          await processEdfFile(file, stageInput, EdfTransformOptions());
          explicitOut = nativeStageOutputPath(
            file,
            algorithm,
            sequenceCorrection: widget.correction,
            outDir: outDir,
          );
        }
        final fileArgs = buildNativeStageArgs(
          inputPath: stageInput,
          algorithm: algorithm,
          sequenceCorrection: widget.correction,
          sleepgptAlpha: widget.sleepgptAlpha,
          sleepgptNgram: widget.sleepgptNgram,
          eeg: widget.eegChannels,
          ref: widget.refChannels,
          eog: widget.eogChannels,
          emg: widget.emgChannels,
          outJson: explicitOut,
          outDir: explicitOut == null ? outDir : null,
        );
        final exitCode = await EegBackend().runCommandStreamAsync(
          executable: rustExecutable,
          arguments: fileArgs,
          onLine: (line) {
            fileLogs.add(line);
            _addLog(line);
          },
        );
        fileExitCode = exitCode;
        final outputJsonPath = _outputPathFromLogs(_logLines);

        final logFolder = (widget.outputDir != null && widget.outputDir!.trim().isNotEmpty)
            ? widget.outputDir!.trim()
            : File(file).parent.path;
        masterLogFolder ??= logFolder;

        // Write per-file log
        await writeBatchFileLog(
          outputFolder: logFolder,
          originalFilePath: file,
          jobType: 'autoscore',
          exitCode: exitCode,
          logLines: fileLogs,
        );

        if (exitCode == 0 && outputJsonPath.isNotEmpty) {
          if (mounted) {
            setState(() {
              _statuses[file] = 'Completed';
            });
            _addLog(
              '\nScoring finished successfully! Output saved to: $outputJsonPath',
            );
          }
        } else {
          if (mounted) {
            setState(() {
              _statuses[file] = 'Failed';
            });
            _addLog('\nScoring failed with exit code $exitCode');
          }
        }
      } catch (e) {
        fileLogs.add('Exception: $e');
        if (mounted) {
          setState(() {
            _statuses[file] = 'Failed';
          });
          _addLog('\nException occurred: $e');
        }
      }

      if (tempDir != null) {
        try {
          await tempDir.delete(recursive: true);
        } catch (_) {}
      }

      batchResults.add(
        BatchFileResult(
          filePath: file,
          exitCode: fileExitCode,
          logs: fileLogs,
        ),
      );
    }

    // Write comprehensive single master run log across all files
    if (masterLogFolder != null && batchResults.isNotEmpty) {
      final endTime = DateTime.now();
      await writeBatchRunSummaryLog(
        outputFolder: masterLogFolder,
        jobType: 'autoscore',
        startTime: startTime,
        endTime: endTime,
        results: batchResults,
      );
      _addLog('\nMaster batch run log written to: $masterLogFolder');
    }

    if (mounted) {
      setState(() {
        _isFinished = true;
      });
    }
  }

  String _basename(String path) {
    return path.split(Platform.pathSeparator).last;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.auto_awesome_motion, color: Colors.purple),
          const SizedBox(width: 8),
          Text(
            _isFinished
                ? 'AutoscoreNidra Batch Finished'
                : 'Running Batch AutoscoreNidra…',
          ),
        ],
      ),
      content: SizedBox(
        width: 800,
        height: 500,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left column: list of files
            Expanded(
              flex: 2,
              child: Container(
                decoration: BoxDecoration(
                  border: Border(
                    right: BorderSide(color: Colors.grey.shade300),
                  ),
                ),
                padding: const EdgeInsets.only(right: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Files Queue (${_currentIndex + 1}/${widget.files.length})',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: widget.files.length,
                        itemBuilder: (context, index) {
                          final file = widget.files[index];
                          final status = _statuses[file] ?? 'Pending';
                          IconData icon = Icons.hourglass_empty;
                          Color color = Colors.grey;

                          if (status == 'Scoring…') {
                            icon = Icons.sync;
                            color = Colors.blue;
                          } else if (status == 'Completed') {
                            icon = Icons.check_circle;
                            color = Colors.green;
                          } else if (status == 'Failed') {
                            icon = Icons.error;
                            color = Colors.red;
                          }

                          final isCurrent = file == _currentFile;
                          return Container(
                            color: isCurrent ? Colors.purple.shade50 : null,
                            padding: const EdgeInsets.symmetric(
                              vertical: 6,
                              horizontal: 4,
                            ),
                            child: Row(
                              children: [
                                Icon(icon, size: 16, color: color),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _basename(file),
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: isCurrent
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        status,
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: color,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Right column: terminal logs
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: widget.files.isEmpty
                        ? 0
                        : _isFinished
                        ? 1
                        : _fileProgress <= 0
                        ? null
                        : (_currentIndex + _fileProgress) / widget.files.length,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _progressLabel,
                    style: const TextStyle(fontSize: 11, color: Colors.black54),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Active Logs',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      color: Colors.black87,
                      width: double.infinity,
                      child: StreamBuilder<String>(
                        stream: _logsStream.stream,
                        builder: (context, snapshot) {
                          return Scrollbar(
                            thumbVisibility: true,
                            child: ListView.builder(
                              controller: _scrollController,
                              shrinkWrap: true,
                              itemCount: _logLines.length,
                              itemBuilder: (context, index) {
                                return Text(
                                  _logLines[index],
                                  style: const TextStyle(
                                    color: Colors.lightGreenAccent,
                                    fontFamily: 'Courier',
                                    fontSize: 11,
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (!_isFinished)
          TextButton(
            onPressed: () {
              setState(() {
                _isCancelled = true;
              });
              Navigator.of(context).pop();
            },
            child: const Text(
              'Cancel Batch',
              style: TextStyle(color: Colors.red),
            ),
          ),
        TextButton(
          onPressed: _isFinished
              ? () {
                  Navigator.of(context).pop();
                  widget.onFinished();
                }
              : null,
          child: Text(_isFinished ? 'Close' : 'Processing…'),
        ),
      ],
    );
  }
}

class _DownloadStatsDialog extends StatefulWidget {
  const _DownloadStatsDialog({super.key});

  @override
  State<_DownloadStatsDialog> createState() => _DownloadStatsDialogState();
}

class _DownloadStatsDialogState extends State<_DownloadStatsDialog> {
  bool _isLoading = true;
  String? _errorMessage;
  List<Map<String, dynamic>> _assets = [];
  int _totalDownloads = 0;

  @override
  void initState() {
    super.initState();
    _fetchStats();
  }

  Future<void> _fetchStats() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(
        Uri.parse(
          'https://api.github.com/repos/arunsasidharan84/CCS-Sleep-Studio/releases/tags/latest',
        ),
      );
      request.headers.set(HttpHeaders.userAgentHeader, 'CCS-Sleep-Studio-App');
      final response = await request.close();

      if (response.statusCode == 200) {
        final responseBody = await response.transform(utf8.decoder).join();
        final json = jsonDecode(responseBody);
        final assetsList = json['assets'] as List<dynamic>?;
        if (assetsList != null) {
          final List<Map<String, dynamic>> loadedAssets = [];
          int total = 0;
          final expectedAssetNames = {
            'CCSSleepStudio-macos.zip': 'macOS (Full Edition)',
            'CCSSleepStudio-lite-macos.zip': 'macOS (Lite Edition)',
            'CCSSleepStudio-Installer.exe': 'Windows (Full Edition)',
            'CCSSleepStudio-lite-Installer.exe': 'Windows (Lite Edition)',
            'CCSSleepStudio-linux-amd64.deb': 'Linux DEB (Full Edition)',
            'CCSSleepStudio-lite-linux-amd64.deb': 'Linux DEB (Lite Edition)',
            'CCSSleepStudio-linux-x86_64.rpm': 'Linux RPM (Full Edition)',
            'CCSSleepStudio-lite-linux-x86_64.rpm': 'Linux RPM (Lite Edition)',
          };

          for (final asset in assetsList) {
            final name = asset['name'] as String?;
            final count = asset['download_count'] as int? ?? 0;
            if (name != null && expectedAssetNames.containsKey(name)) {
              loadedAssets.add({
                'filename': name,
                'displayName': expectedAssetNames[name],
                'count': count,
              });
              total += count;
            }
          }
          final order = expectedAssetNames.keys.toList();
          loadedAssets.sort((a, b) {
            final idxA = order.indexOf(a['filename'] as String);
            final idxB = order.indexOf(b['filename'] as String);
            return idxA.compareTo(idxB);
          });

          if (mounted) {
            setState(() {
              _assets = loadedAssets;
              _totalDownloads = total;
              _isLoading = false;
            });
          }
        } else {
          throw Exception('Invalid response structure: assets field missing');
        }
      } else {
        throw Exception('Server returned status code: ${response.statusCode}');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceAll('Exception: ', '');
          _isLoading = false;
        });
      }
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
      backgroundColor: Colors.white,
      child: Container(
        width: 500,
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.cloud_download_outlined,
                  color: Color(0xFF3B6EA5),
                  size: 28,
                ),
                const SizedBox(width: 12),
                Text(
                  'Release Download Statistics',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
            const Divider(height: 32, thickness: 1),
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48.0),
                child: Center(
                  child: Column(
                    children: [
                      CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Color(0xFF3B6EA5),
                        ),
                      ),
                      SizedBox(height: 16),
                      Text(
                        'Fetching statistics from GitHub...',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              )
            else if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24.0),
                child: Column(
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Colors.redAccent,
                      size: 48,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Failed to load download statistics.',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _errorMessage!,
                      style: TextStyle(color: Colors.grey[600], fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF3B6EA5),
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _fetchStats,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              )
            else ...[
              Container(
                color: Colors.grey[100],
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 8.0,
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Platform / Variant',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      'Downloads',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (_assets.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16.0),
                  child: Center(
                    child: Text(
                      'No assets found in the latest release.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                )
              else
                ..._assets.map((asset) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16.0,
                      vertical: 10.0,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              asset['displayName'] as String,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              asset['filename'] as String,
                              style: TextStyle(
                                color: Colors.grey[500],
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          '${asset['count']}',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF3B6EA5),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
              const Divider(height: 24, thickness: 1),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Total Downloads',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      '$_totalDownloads',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.black87,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const Divider(height: 32, thickness: 1),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    'Close',
                    style: TextStyle(color: Color(0xFF3B6EA5)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PDF Generation Utilities (custom implementation to avoid external dependencies)

class PdfPageBuilder {
  final List<String> commands = [];

  void drawText(
    String text,
    double x,
    double y, {
    bool bold = false,
    double size = 10,
    double gray = 0.0,
    double? r,
    double? g,
    double? b,
  }) {
    final font = bold ? '/F2' : '/F1';
    final escaped = text
        .replaceAll('\\', '\\\\')
        .replaceAll('(', r'\(')
        .replaceAll(')', r'\)');
    final color = r == null ? '$gray g' : '$r ${g ?? 0} ${b ?? 0} rg';
    commands.add('BT $color $font $size Tf $x $y Td ($escaped) Tj ET');
  }

  void drawRect(
    double x,
    double y,
    double width,
    double height, {
    double gray = 0.9,
    bool fill = true,
  }) {
    if (fill) {
      commands.add('$gray g $x $y $width $height re f 0 g');
    } else {
      commands.add('$gray G 0.5 w $x $y $width $height re S 0 G');
    }
  }

  void drawLine(
    double x1,
    double y1,
    double x2,
    double y2, {
    double width = 0.5,
    double gray = 0.3,
  }) {
    commands.add('$width w $gray G $x1 $y1 m $x2 $y2 l S 0 G');
  }

  void drawRgbRect(
    double x,
    double y,
    double width,
    double height,
    double r,
    double g,
    double b,
  ) {
    commands.add('$r $g $b rg $x $y $width $height re f 0 g');
  }

  void drawRgbLine(
    double x1,
    double y1,
    double x2,
    double y2,
    double r,
    double g,
    double b, {
    double width = 0.5,
  }) {
    commands.add('$width w $r $g $b RG $x1 $y1 m $x2 $y2 l S 0 G');
  }

  String build() {
    return commands.join('\n');
  }
}

class SimplePdfDoc {
  final List<String> pages = [];

  void addPage(String pageContent) {
    pages.add(pageContent);
  }

  List<int> build() {
    final numPages = pages.length;
    final font1Idx = 2 * numPages + 3;
    final font2Idx = 2 * numPages + 4;

    final kids = List.generate(numPages, (i) => '${2 * i + 3} 0 R').join(' ');

    final objects = <String>[
      '<< /Type /Catalog /Pages 2 0 R >>', // Object 1
      '<< /Type /Pages /Kids [$kids] /Count $numPages >>', // Object 2
    ];

    for (var i = 0; i < numPages; i++) {
      final pageContent = pages[i];
      final contentIdx = 2 * i + 4;
      objects.add(
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 $font1Idx 0 R /F2 $font2Idx 0 R >> >> /Contents $contentIdx 0 R >>',
      );
      objects.add(
        '<< /Length ${pageContent.length} >>\nstream\n$pageContent\nendstream',
      );
    }

    // Add Helvetica and Helvetica-Bold fonts
    objects.add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
    objects.add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>');

    final buffer = StringBuffer('%PDF-1.4\n');
    final offsets = <int>[0];
    for (var i = 0; i < objects.length; i++) {
      offsets.add(buffer.length);
      buffer.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
    }
    final xrefOffset = buffer.length;
    buffer.write('xref\n0 ${objects.length + 1}\n');
    buffer.write('0000000000 65535 f \n');
    for (final offset in offsets.skip(1)) {
      buffer.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
    }
    buffer.write(
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xrefOffset\n%%EOF\n',
    );
    return buffer.toString().codeUnits;
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// PSG batch analysis (respiratory / PLM / CAP)
// ─────────────────────────────────────────────────────────────────────────────

class _BatchPsgSettings {
  const _BatchPsgSettings({
    required this.respiratory,
    required this.plm,
    required this.cap,
    required this.hypopneaRule,
    required this.plmStandard,
    required this.capSensitivity,
    this.pressure,
    this.thermal,
    this.spo2,
    this.leftLeg,
    this.rightLeg,
    this.capEeg,
    this.outputDir,
  });

  final bool respiratory;
  final bool plm;
  final bool cap;
  final int hypopneaRule;
  final String plmStandard;
  final String capSensitivity;
  final String? pressure;
  final String? thermal;
  final String? spo2;
  final String? leftLeg;
  final String? rightLeg;
  final String? capEeg;
  final String? outputDir;
}

/// Summary columns written to the batch CSV: (analysis, JSON section, key).
const List<(String, String, String)> _kBatchPsgColumns = [
  ('respiratory', 'summary', 'TST_min'),
  ('respiratory', 'summary', 'AHI'),
  ('respiratory', 'flags', 'severity'),
  ('respiratory', 'summary', 'AHI_3a'),
  ('respiratory', 'summary', 'AHI_4'),
  ('respiratory', 'summary', 'OAI'),
  ('respiratory', 'summary', 'CAI'),
  ('respiratory', 'summary', 'MAI'),
  ('respiratory', 'summary', 'HI'),
  ('respiratory', 'summary', 'RDI'),
  ('respiratory', 'summary', 'AHI_REM'),
  ('respiratory', 'summary', 'AHI_NREM'),
  ('respiratory', 'summary', 'AHI_supine'),
  ('respiratory', 'summary', 'AHI_nonsupine'),
  ('respiratory', 'summary', 'ODI3'),
  ('respiratory', 'summary', 'ODI4'),
  ('respiratory', 'summary', 'T90_pct'),
  ('respiratory', 'summary', 'SpO2_min_sleep'),
  ('respiratory', 'summary', 'hypoxic_burden_pct_min_per_h'),
  ('respiratory', 'summary', 'delta_HR_bpm'),
  ('respiratory', 'summary', 'ventilatory_burden_pct_min_per_h'),
  ('respiratory', 'summary', 'CSB_pct_TST'),
  ('respiratory', 'flags', 'REM_related_OSA'),
  ('respiratory', 'flags', 'positional_OSA'),
  ('plm', 'summary', 'PLMS_index'),
  ('plm', 'flags', 'PLMS_severity'),
  ('plm', 'summary', 'PLMW_index'),
  ('plm', 'summary', 'PLMS_arousal_index'),
  ('plm', 'summary', 'LM_index'),
  ('plm', 'summary', 'respiratory_LM_index'),
  ('plm', 'summary', 'periodicity_index'),
  ('plm', 'summary', 'n_PLMS'),
  ('plm', 'summary', 'IMI_median_s'),
  ('cap', 'summary', 'CAP_rate'),
  ('cap', 'summary', 'CAP_rate_N1'),
  ('cap', 'summary', 'CAP_rate_N2'),
  ('cap', 'summary', 'CAP_rate_N3'),
  ('cap', 'summary', 'A_index'),
  ('cap', 'summary', 'A1_index'),
  ('cap', 'summary', 'A2_index'),
  ('cap', 'summary', 'A3_index'),
  ('cap', 'summary', 'A1_pct'),
  ('cap', 'summary', 'n_CAP_sequences'),
  ('cap', 'summary', 'CAP_cycle_duration_mean_s'),
  ('cap', 'summary', 'B_phase_duration_mean_s'),
  ('cap', 'summary', 'isolated_A_index'),
  ('cap', 'summary', 'A_phases_respiratory_pct'),
  ('cap', 'summary', 'A_phases_with_LM_pct'),
];

class _BatchPsgDialog extends StatefulWidget {
  const _BatchPsgDialog({required this.jobs, required this.settings});

  final List<Map<String, String>> jobs;
  final _BatchPsgSettings settings;

  @override
  State<_BatchPsgDialog> createState() => _BatchPsgDialogState();
}

class _BatchPsgDialogState extends State<_BatchPsgDialog> {
  final List<String> _log = [];
  final Map<String, String> _status = {};
  final ScrollController _scroll = ScrollController();
  int _current = 0;
  double _progress = 0;
  String _label = 'Starting…';
  bool _finished = false;
  bool _cancelled = false;
  String? _summaryPath;

  @override
  void initState() {
    super.initState();
    for (final j in widget.jobs) {
      _status[j['eegPath'] ?? ''] = 'Waiting';
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _add(String line) {
    if (!mounted) return;
    final m = RegExp(r'PROGRESS\s+([01](?:\.\d+)?)\s+(.+)').firstMatch(line);
    setState(() {
      _log.add(line);
      if (_log.length > 2000) _log.removeRange(0, _log.length - 2000);
      if (m != null) {
        _progress = double.tryParse(m.group(1)!) ?? _progress;
        _label = m.group(2)!.trim();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _run() async {
    final exe = detectAnalyseNidraExecutable();
    final cfg = widget.settings;
    final started = DateTime.now();
    final results = <BatchFileResult>[];
    final rows = <List<String>>[];
    final firstDir = widget.jobs.isEmpty ? Directory.current.path : File(widget.jobs.first['eegPath']!).parent.path;
    final outDir = cfg.outputDir ?? firstDir;

    for (var i = 0; i < widget.jobs.length; i++) {
      if (_cancelled || !mounted) break;
      final job = widget.jobs[i];
      final path = job['eegPath'] ?? '';
      final scoring = (job['scoringPath'] ?? '').isEmpty ? null : job['scoringPath'];
      setState(() {
        _current = i;
        _status[path] = 'Running…';
        _progress = 0;
      });
      _add('--- ${_basename(path)} ---');
      if (scoring == null) {
        _add('No scoring file: indices use monitoring time and CAP is skipped.');
      }
      final fileLogs = <String>[];
      void log(String l) {
        fileLogs.add(l);
        _add(l);
      }

      var failed = false;
      Directory? tempDir;
      final reports = <String, Map<String, dynamic>?>{};
      try {
        var edf = path;
        if (!analyseNidraReadsNatively(path)) {
          log('Converting to a temporary EDF…');
          tempDir = await Directory.systemTemp.createTemp('ccs_psg_batch_');
          var stem = _basename(path);
          final dot = stem.lastIndexOf('.');
          if (dot > 0) stem = stem.substring(0, dot);
          edf = '${tempDir.path}${Platform.pathSeparator}$stem.edf';
          await processEdfFile(path, edf, EdfTransformOptions());
        }
        final respOut = respiratoryReportPath(path);
        final plmOut = plmReportPath(path);
        final capOut = capReportPath(path);
        Future<bool> step(String name, List<String> args, String out) async {
          if (_cancelled) return false;
          log('> $name');
          final code = await EegBackend().runCommandStreamAsync(executable: exe, arguments: args, onLine: log);
          if (code != 0) {
            log('$name failed (exit $code)');
            return false;
          }
          reports[name] = await loadPsgReport(out);
          return true;
        }

        if (cfg.respiratory) {
          final ok = await step('respiratory', buildRespiratoryArgs(
            edfPath: edf,
            scoringPath: scoring,
            outPath: respOut,
            settings: {
              'channels': {
                if (cfg.pressure != null) 'pressure': cfg.pressure,
                if (cfg.thermal != null) 'thermal': cfg.thermal,
                if (cfg.spo2 != null) 'spo2': cfg.spo2,
              },
              'hypopneaRule': cfg.hypopneaRule,
              'arousalMode': 'prefer-manual',
            },
          ), respOut);
          failed |= !ok;
        }
        final haveResp = File(respOut).existsSync();
        if (cfg.plm) {
          final ok = await step('plm', buildPlmArgs(
            edfPath: edf,
            scoringPath: scoring,
            outPath: plmOut,
            respiratoryJson: haveResp ? respOut : null,
            settings: {
              if (cfg.leftLeg != null) 'left': cfg.leftLeg,
              if (cfg.rightLeg != null) 'right': cfg.rightLeg,
              'standard': cfg.plmStandard,
              'useRespiratory': haveResp,
            },
          ), plmOut);
          failed |= !ok;
        }
        if (cfg.cap && scoring != null) {
          final ok = await step('cap', buildCapArgs(
            edfPath: edf,
            scoringPath: scoring,
            outPath: capOut,
            respiratoryJson: haveResp ? respOut : null,
            plmJson: File(plmOut).existsSync() ? plmOut : null,
            settings: {
              if (cfg.capEeg != null) 'eeg': cfg.capEeg,
              'sensitivity': cfg.capSensitivity,
              'source': 'prefer-manual',
            },
          ), capOut);
          failed |= !ok;
        }
      } catch (e) {
        log('Exception: $e');
        failed = true;
      } finally {
        if (tempDir != null) {
          try {
            await tempDir.delete(recursive: true);
          } catch (_) {}
        }
      }

      String cell(String analysis, String section, String key) {
        final v = (reports[analysis]?[section] as Map?)?[key];
        if (v == null) return '';
        if (v is num) return v.isFinite ? v.toStringAsFixed(3) : '';
        return v.toString();
      }

      rows.add([
        path,
        scoring ?? '',
        for (final c in _kBatchPsgColumns) cell(c.$1, c.$2, c.$3),
      ]);
      results.add(BatchFileResult(filePath: path, exitCode: failed ? 1 : 0, logs: fileLogs));
      await writeBatchFileLog(
        outputFolder: outDir,
        originalFilePath: path,
        jobType: 'psg',
        exitCode: failed ? 1 : 0,
        logLines: fileLogs,
      );
      if (mounted) setState(() => _status[path] = failed ? 'Completed with errors' : 'Completed');
    }

    if (rows.isNotEmpty) {
      String esc(String v) => v.contains(RegExp(r'[,"\n]')) ? '"${v.replaceAll('"', '""')}"' : v;
      final header = [
        'recording',
        'scoring',
        for (final c in _kBatchPsgColumns) '${c.$1}_${c.$3}',
      ];
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '').split('.').first;
      final csvPath = '$outDir${Platform.pathSeparator}psg_batch_summary_$stamp.csv';
      try {
        await Directory(outDir).create(recursive: true);
        await File(csvPath).writeAsString(
          [header, ...rows].map((r) => r.map(esc).join(',')).join('\n'),
        );
        _summaryPath = csvPath;
        _add('\nSummary table written to: $csvPath');
      } catch (e) {
        _add('Could not write summary CSV: $e');
      }
      await writeBatchRunSummaryLog(
        outputFolder: outDir,
        jobType: 'psg',
        startTime: started,
        endTime: DateTime.now(),
        results: results,
      );
    }
    if (mounted) setState(() => _finished = true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_finished ? 'PSG Batch Analysis Finished' : 'Running PSG Batch Analysis…'),
      content: SizedBox(
        width: 820,
        height: 480,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 260,
              child: ListView(
                children: [
                  for (var i = 0; i < widget.jobs.length; i++)
                    ListTile(
                      dense: true,
                      selected: i == _current && !_finished,
                      title: Text(_basename(widget.jobs[i]['eegPath'] ?? ''), overflow: TextOverflow.ellipsis),
                      subtitle: Text(_status[widget.jobs[i]['eegPath'] ?? ''] ?? ''),
                    ),
                ],
              ),
            ),
            const VerticalDivider(),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _finished ? (_summaryPath == null ? 'Done' : 'Summary: ${_basename(_summaryPath!)}') : _label,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: _finished ? 1 : (_progress > 0 ? _progress : null)),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Container(
                      color: Colors.black87,
                      padding: const EdgeInsets.all(6),
                      child: ListView.builder(
                        controller: _scroll,
                        itemCount: _log.length,
                        itemBuilder: (_, i) => Text(
                          _log[i],
                          style: const TextStyle(color: Colors.lightGreenAccent, fontFamily: 'Courier', fontSize: 11),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (!_finished)
          TextButton(
            onPressed: _cancelled ? null : () => setState(() => _cancelled = true),
            child: Text(_cancelled ? 'Stopping after this recording…' : 'Cancel'),
          ),
        if (_finished)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
      ],
    );
  }
}
