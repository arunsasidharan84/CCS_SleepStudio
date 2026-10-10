// lib/src/models.dart

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Sleep stage codes matching the Python ScoringHero digit encoding:
///   Wake=1, REM=0, N1=-1, N2=-2, N3=-3, Inconclusive=2, None/unknown=null
enum SleepStage {
  wake('Wake', 1),
  rem('REM', 0),
  n1('N1', -1),
  n2('N2', -2),
  n3('N3', -3),
  inconclusive('Inconclusive', 2),
  unknown('?', -99); // unscored

  const SleepStage(this.label, this.code);

  final String label;
  final int code; // matches Python's digit encoding

  /// Return true if this epoch has been scored by a human.
  bool get isScored => this != SleepStage.unknown;

  /// Short display string for epoch label.
  String get shortLabel {
    switch (this) {
      case SleepStage.wake:
        return 'W';
      case SleepStage.rem:
        return 'REM';
      case SleepStage.n1:
        return 'N1';
      case SleepStage.n2:
        return 'N2';
      case SleepStage.n3:
        return 'N3';
      case SleepStage.inconclusive:
        return '?';
      case SleepStage.unknown:
        return '-';
    }
  }

  static SleepStage fromCode(int code) {
    return SleepStage.values.firstWhere(
      (s) => s.code == code,
      orElse: () => SleepStage.unknown,
    );
  }

  /// Parse from ScoringHero JSON "stage" string field.
  static SleepStage fromLabel(String? label) {
    switch (label) {
      case 'Wake':
        return SleepStage.wake;
      case 'N1':
        return SleepStage.n1;
      case 'N2':
        return SleepStage.n2;
      case 'N3':
        return SleepStage.n3;
      case 'REM':
        return SleepStage.rem;
      case 'Inconclusive':
        return SleepStage.inconclusive;
      default:
        return SleepStage.unknown;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class DisplayPoint {
  const DisplayPoint({required this.x, required this.y, required this.channel});
  final double x; // normalised 0..1 within visible window
  final double y; // normalised 0..1 within panel height
  final int channel;
}

// ─────────────────────────────────────────────────────────────────────────────

class EventSelection {
  const EventSelection({
    required this.startSec,
    required this.endSec,
    required this.channel,
    required this.startUv,
    required this.endUv,
    required this.peakToPeakUv,
  });

  final double startSec;
  final double endSec;
  final int channel;
  final double startUv;
  final double endUv;
  final double peakToPeakUv;

  double get durationSeconds => (endSec - startSec).abs();
}

// ─────────────────────────────────────────────────────────────────────────────

class ScoredEvent {
  const ScoredEvent({
    required this.digit,
    required this.key,
    required this.label,
    required this.startSec,
    required this.endSec,
    this.channel,
    this.type = 'Event',
  });

  final int digit;
  final String key;
  final String label;
  final double startSec;
  final double endSec;
  final String? channel;
  final String type;

  double get durationSeconds => (endSec - startSec).abs();
  bool get isPointMarker => durationSeconds < 0.05;

  List<int> epochs(int epochSeconds, int epochCount) {
    final s = startSec < endSec ? startSec : endSec;
    final e = startSec < endSec ? endSec : startSec;
    final first = (s / epochSeconds).floor().clamp(0, epochCount - 1);
    final last = ((e - 1e-9) / epochSeconds).floor().clamp(0, epochCount - 1);
    return [for (var i = first; i <= last; i++) i];
  }

  Map<String, dynamic> toJson() => {
    'digit': digit,
    'key': key,
    'label': label,
    'startSec': startSec,
    'endSec': endSec,
    if (channel != null) 'channel': channel,
    'type': type,
  };

  factory ScoredEvent.fromJson(Map<String, dynamic> json) {
    return ScoredEvent(
      digit: json['digit'] as int? ?? 0,
      key: json['key'] as String? ?? '',
      label: json['label'] as String? ?? 'Event',
      startSec: (json['startSec'] as num?)?.toDouble() ?? 0.0,
      endSec: (json['endSec'] as num?)?.toDouble() ?? 0.0,
      channel: json['channel'] as String?,
      type: json['type'] as String? ?? 'Event',
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

/// All night-level data cached after EDF/MAT load.
/// Heavy arrays (spectrogram, periodograms) live here so they are computed
/// once and referenced (not copied) by each [EegViewport].
class LoadedEeg {
  const LoadedEeg({
    required this.sampleRateHz,
    required this.channelLabels,
    required this.channelSamples,
    required this.sourceDescription,
    // Night-level signal processing products
    this.spectrogramPower = const [],
    this.spectrogramFreqs = const [],
    this.swaPerEpoch = const [],
    this.epochPeriodograms = const [],
    this.epochTfPower = const [],
    this.tfFreqs = const [],
    this.tfNormMedian = const [],
    this.tfNormIqr = const [],
    this.spectrogramChannelIndex = 0,
    this.spectrogramImage,
    this.recordingStartTime,
    this.channelLabelRenames = const {},
  });

  final double sampleRateHz;
  final List<String> channelLabels;

  /// Old label → corrected label for channels whose naming changed in this
  /// version (Nihon Kohden .21E fix). Used once to migrate saved configs.
  final Map<String, String> channelLabelRenames;
  final List<List<double>> channelSamples;
  final String sourceDescription;

  int get sampleCount => channelSamples.isEmpty ? 0 : channelSamples.first.length;

  // ─── Night-level spectrogram (epochs × freqs) ───────────────────────────
  final List<List<double>>
  spectrogramPower; // log10 power displayed in spectrogram
  final List<double> spectrogramFreqs; // frequency bins (Hz)
  final List<double> swaPerEpoch; // mean 0.5–4 Hz power per epoch
  final List<List<double>>
  epochPeriodograms; // per-epoch Welch PSD (power spectrum panel)
  final int spectrogramChannelIndex; // which channel drives the spectrogram
  final ui.Image? spectrogramImage;
  final DateTime? recordingStartTime;

  // ─── Pre-computed Morlet TF (all epochs at load time) ───────────────────
  /// Shape: epochCount × nFreqs × nSamples (z-scored log10 power).
  /// Pre-computed at load time so navigation is O(1). Empty until loaded.
  final List<List<List<double>>> epochTfPower;

  // ─── TF normalisation stats (per TF frequency bin) ──────────────────────
  final List<double> tfFreqs; // geomspace 0.25–45 Hz, 120 points
  final List<double> tfNormMedian; // night-wide log10 power median per TF freq
  final List<double> tfNormIqr; // night-wide log10 power IQR per TF freq

  double get durationSeconds {
    if (channelSamples.isEmpty || sampleRateHz <= 0) return 0;
    return channelSamples.first.length / sampleRateHz;
  }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Per-epoch display viewport — immutable value object passed to all painters.
class EegViewport {
  const EegViewport({
    required this.sampleRateHz,
    required this.epochSeconds,
    required this.channelLabels,
    required this.points,
    required this.stages,
    this.stagesUncertain = const [],
    required this.currentEpoch,
    required this.visibleStartSeconds,
    required this.visibleDurationSeconds,
    required this.totalDurationSeconds,
    required this.sourceDescription,
    // Night-level data (references, not copies)
    this.spectrogramPower = const [],
    this.spectrogramFreqs = const [],
    this.swaPerEpoch = const [],
    this.tfFreqs = const [],
    this.tfNormMedian = const [],
    this.tfNormIqr = const [],
    this.spectrogramChannelIndex = 0,
    this.spectrogramChannelLabel = '',
    this.spectrogramImage,
    // Per-epoch data
    this.currentEpochPeriodogram = const [],
    this.periodogramFreqs = const [],
    this.tfPower = const [], // nFreqs × nSamples Morlet power (log10, z-scored)
    this.tfImage,
    this.periodogramChannelIndex = 0,
    this.periodogramChannelLabel = '',
    this.tfChannelIndex = 0,
    this.tfChannelLabel = '',
    this.amplitudeRangeUv = 75.0,
    this.referenceAmplitudeLineUv = 37.5,
    this.selectionStartSec,
    this.selectionEndSec,
    this.selectionChannel,
    this.selectionStartUv,
    this.selectionEndUv,
    this.selectionPeakToPeakUv,
    this.eventSelections = const [],
    this.scoredEvents = const [],
    this.disabledMarkerLabels = const {},
    this.visibleChannelLabels = const [],
    this.visibleChannelSourceIndices = const [],
    this.visibleChannelColors = const [],
    this.visibleChannelScales = const [],
    this.visibleChannelScaleNotes = const [],
    this.tfDisplayMode = 'dB (median baseline)',
    this.tfPowerMin = 0.0,
    this.tfPowerMax = 20.0,
    this.periodogramFreqMin = 4.0,
    this.periodogramFreqMax = 45.0,
    this.periodogramDisplayMode = '1/f Removed',
    this.spectrogramFiltered = false,
    this.periodogramFiltered = false,
    this.tfFiltered = false,
    this.spectrogramFreqMin = 0.0,
    this.spectrogramFreqMax = 45.0,
    this.spectrogramPowerMin = -1.0,
    this.spectrogramPowerMax = 3.0,
    this.spectrogramFlex = 50,
    this.hypnogramFlex = 27,
    this.periodogramFlex = 12,
    this.showSwaPlot = true,
    this.referenceLineThickness = 0.5,
    this.referenceLineColor = 'Light Grey',
    this.hypnogramZoom = 'Full Night',
    this.hypnogramOverlayMode = 'SWA',
    this.hypnogramProbabilityStage = 'N2',
    this.eegPanelTimeUnit = 'Seconds',
    this.lightsOffSeconds,
    this.lightsOnSeconds,
    this.stagesConfidence = const [],
    this.stageProbabilities = const [],
    this.recordingStartTime,
  });

  final double sampleRateHz;
  final int epochSeconds;
  final List<String> channelLabels;
  final List<Float32List> points;
  final List<SleepStage> stages;
  final List<bool> stagesUncertain;
  final int currentEpoch;
  final double visibleStartSeconds;
  final double visibleDurationSeconds;
  final double totalDurationSeconds;
  final String sourceDescription;

  // Filter status indicators
  final bool spectrogramFiltered;
  final bool periodogramFiltered;
  final bool tfFiltered;

  // Night-level references
  final List<List<double>> spectrogramPower;
  final List<double> spectrogramFreqs;
  final List<double> swaPerEpoch;
  final List<double> tfFreqs;
  final List<double> tfNormMedian;
  final List<double> tfNormIqr;
  final int spectrogramChannelIndex;
  final String spectrogramChannelLabel;
  final ui.Image? spectrogramImage;

  // Per-epoch computed data
  final List<double> currentEpochPeriodogram;
  final List<double> periodogramFreqs;
  final List<List<double>> tfPower; // shape: nFreqs × nSamples, z-scored log10
  final ui.Image? tfImage;
  final int periodogramChannelIndex;
  final String periodogramChannelLabel;
  final int tfChannelIndex;
  final String tfChannelLabel;
  final double amplitudeRangeUv;
  final double referenceAmplitudeLineUv;
  final String tfDisplayMode;
  final double tfPowerMin;
  final double tfPowerMax;
  final double periodogramFreqMin;
  final double periodogramFreqMax;
  final String periodogramDisplayMode;
  final double spectrogramFreqMin;
  final double spectrogramFreqMax;
  final double spectrogramPowerMin;
  final double spectrogramPowerMax;

  final int spectrogramFlex;
  final int hypnogramFlex;
  final int periodogramFlex;
  final bool showSwaPlot;
  final double referenceLineThickness;
  final String referenceLineColor;
  final String hypnogramZoom;
  final String hypnogramOverlayMode;
  final String hypnogramProbabilityStage;
  final String eegPanelTimeUnit;
  final double? lightsOffSeconds;
  final double? lightsOnSeconds;
  final List<double?> stagesConfidence;
  final List<Map<SleepStage, double>> stageProbabilities;
  final DateTime? recordingStartTime;

  // Selection
  final double? selectionStartSec;
  final double? selectionEndSec;
  final int? selectionChannel;
  final double? selectionStartUv;
  final double? selectionEndUv;
  final double? selectionPeakToPeakUv;
  final List<EventSelection> eventSelections;
  final List<ScoredEvent> scoredEvents;
  final Set<String> disabledMarkerLabels;
  final List<String> visibleChannelLabels;
  final List<int> visibleChannelSourceIndices;
  final List<String> visibleChannelColors;
  final List<double> visibleChannelScales;

  /// Short note under each channel name about how it is scaled
  /// (e.g. "auto" or "70–100" for SpO2); empty for EEG-style channels.
  final List<String> visibleChannelScaleNotes;

  int get epochCount => stages.length;
  List<String> get signalChannelLabels =>
      visibleChannelLabels.isNotEmpty ? visibleChannelLabels : channelLabels;
  List<int> get signalChannelSourceIndices =>
      visibleChannelSourceIndices.isNotEmpty
      ? visibleChannelSourceIndices
      : [for (var i = 0; i < channelLabels.length; i++) i];
  List<String> get signalChannelColors => visibleChannelColors.isNotEmpty
      ? visibleChannelColors
      : [for (var i = 0; i < signalChannelLabels.length; i++) 'Black'];
  List<double> get signalChannelScales => visibleChannelScales.isNotEmpty
      ? visibleChannelScales
      : [for (var i = 0; i < signalChannelLabels.length; i++) 100.0];
  int get channelCount => signalChannelLabels.length;

  SleepStage get currentStage =>
      currentEpoch < stages.length ? stages[currentEpoch] : SleepStage.unknown;

  EegViewport copyWith({
    List<SleepStage>? stages,
    List<bool>? stagesUncertain,
    int? currentEpoch,
    List<Float32List>? points,
    double? visibleStartSeconds,
    double? visibleDurationSeconds,
    List<double>? currentEpochPeriodogram,
    List<double>? periodogramFreqs,
    List<List<double>>? tfPower,
    ui.Image? tfImage,
    int? periodogramChannelIndex,
    String? periodogramChannelLabel,
    int? tfChannelIndex,
    String? tfChannelLabel,
    double? amplitudeRangeUv,
    double? referenceAmplitudeLineUv,
    double? selectionStartSec,
    double? selectionEndSec,
    int? selectionChannel,
    double? selectionStartUv,
    double? selectionEndUv,
    double? selectionPeakToPeakUv,
    List<EventSelection>? eventSelections,
    List<ScoredEvent>? scoredEvents,
    Set<String>? disabledMarkerLabels,
    List<String>? visibleChannelLabels,
    List<int>? visibleChannelSourceIndices,
    List<String>? visibleChannelColors,
    List<double>? visibleChannelScales,
    List<String>? visibleChannelScaleNotes,
    bool clearSelection = false,
    bool clearEventSelections = false,
    String? tfDisplayMode,
    double? tfPowerMin,
    double? tfPowerMax,
    double? periodogramFreqMin,
    double? periodogramFreqMax,
    String? periodogramDisplayMode,
    int? spectrogramChannelIndex,
    String? spectrogramChannelLabel,
    ui.Image? spectrogramImage,
    bool clearSpectrogramImage = false,
    bool clearTfImage = false,
    bool? spectrogramFiltered,
    bool? periodogramFiltered,
    bool? tfFiltered,
    double? spectrogramFreqMin,
    double? spectrogramFreqMax,
    double? spectrogramPowerMin,
    double? spectrogramPowerMax,
    int? spectrogramFlex,
    int? hypnogramFlex,
    int? periodogramFlex,
    bool? showSwaPlot,
    double? referenceLineThickness,
    String? referenceLineColor,
    String? hypnogramZoom,
    String? hypnogramOverlayMode,
    String? hypnogramProbabilityStage,
    String? eegPanelTimeUnit,
    List<double?>? stagesConfidence,
    List<Map<SleepStage, double>>? stageProbabilities,
    DateTime? recordingStartTime,
    double? lightsOffSeconds,
    double? lightsOnSeconds,
  }) {
    return EegViewport(
      sampleRateHz: sampleRateHz,
      epochSeconds: epochSeconds,
      channelLabels: channelLabels,
      points: points ?? this.points,
      stages: stages ?? this.stages,
      stagesUncertain: stagesUncertain ?? this.stagesUncertain,
      currentEpoch: currentEpoch ?? this.currentEpoch,
      visibleStartSeconds: visibleStartSeconds ?? this.visibleStartSeconds,
      visibleDurationSeconds:
          visibleDurationSeconds ?? this.visibleDurationSeconds,
      totalDurationSeconds: totalDurationSeconds,
      sourceDescription: sourceDescription,
      spectrogramFiltered: spectrogramFiltered ?? this.spectrogramFiltered,
      periodogramFiltered: periodogramFiltered ?? this.periodogramFiltered,
      tfFiltered: tfFiltered ?? this.tfFiltered,
      spectrogramPower: spectrogramPower,
      spectrogramFreqs: spectrogramFreqs,
      swaPerEpoch: swaPerEpoch,
      tfFreqs: tfFreqs,
      tfNormMedian: tfNormMedian,
      tfNormIqr: tfNormIqr,
      spectrogramChannelIndex:
          spectrogramChannelIndex ?? this.spectrogramChannelIndex,
      spectrogramChannelLabel:
          spectrogramChannelLabel ?? this.spectrogramChannelLabel,
      spectrogramImage: clearSpectrogramImage
          ? null
          : (spectrogramImage ?? this.spectrogramImage),
      currentEpochPeriodogram:
          currentEpochPeriodogram ?? this.currentEpochPeriodogram,
      periodogramFreqs: periodogramFreqs ?? this.periodogramFreqs,
      tfPower: tfPower ?? this.tfPower,
      tfImage: clearTfImage ? null : (tfImage ?? this.tfImage),
      periodogramChannelIndex:
          periodogramChannelIndex ?? this.periodogramChannelIndex,
      periodogramChannelLabel:
          periodogramChannelLabel ?? this.periodogramChannelLabel,
      tfChannelIndex: tfChannelIndex ?? this.tfChannelIndex,
      tfChannelLabel: tfChannelLabel ?? this.tfChannelLabel,
      amplitudeRangeUv: amplitudeRangeUv ?? this.amplitudeRangeUv,
      referenceAmplitudeLineUv:
          referenceAmplitudeLineUv ?? this.referenceAmplitudeLineUv,
      selectionStartSec: clearSelection
          ? null
          : (selectionStartSec ?? this.selectionStartSec),
      selectionEndSec: clearSelection
          ? null
          : (selectionEndSec ?? this.selectionEndSec),
      selectionChannel: clearSelection
          ? null
          : (selectionChannel ?? this.selectionChannel),
      selectionStartUv: clearSelection
          ? null
          : (selectionStartUv ?? this.selectionStartUv),
      selectionEndUv: clearSelection
          ? null
          : (selectionEndUv ?? this.selectionEndUv),
      selectionPeakToPeakUv: clearSelection
          ? null
          : (selectionPeakToPeakUv ?? this.selectionPeakToPeakUv),
      eventSelections: clearEventSelections
          ? const []
          : (eventSelections ?? this.eventSelections),
      scoredEvents: scoredEvents ?? this.scoredEvents,
      disabledMarkerLabels:
          disabledMarkerLabels ?? this.disabledMarkerLabels,
      visibleChannelLabels: visibleChannelLabels ?? this.visibleChannelLabels,
      visibleChannelSourceIndices:
          visibleChannelSourceIndices ?? this.visibleChannelSourceIndices,
      visibleChannelColors: visibleChannelColors ?? this.visibleChannelColors,
      visibleChannelScales: visibleChannelScales ?? this.visibleChannelScales,
      visibleChannelScaleNotes:
          visibleChannelScaleNotes ?? this.visibleChannelScaleNotes,
      tfDisplayMode: tfDisplayMode ?? this.tfDisplayMode,
      tfPowerMin: tfPowerMin ?? this.tfPowerMin,
      tfPowerMax: tfPowerMax ?? this.tfPowerMax,
      periodogramFreqMin: periodogramFreqMin ?? this.periodogramFreqMin,
      periodogramFreqMax: periodogramFreqMax ?? this.periodogramFreqMax,
      periodogramDisplayMode:
          periodogramDisplayMode ?? this.periodogramDisplayMode,
      spectrogramFreqMin: spectrogramFreqMin ?? this.spectrogramFreqMin,
      spectrogramFreqMax: spectrogramFreqMax ?? this.spectrogramFreqMax,
      spectrogramPowerMin: spectrogramPowerMin ?? this.spectrogramPowerMin,
      spectrogramPowerMax: spectrogramPowerMax ?? this.spectrogramPowerMax,
      spectrogramFlex: spectrogramFlex ?? this.spectrogramFlex,
      hypnogramFlex: hypnogramFlex ?? this.hypnogramFlex,
      periodogramFlex: periodogramFlex ?? this.periodogramFlex,
      showSwaPlot: showSwaPlot ?? this.showSwaPlot,
      referenceLineThickness:
          referenceLineThickness ?? this.referenceLineThickness,
      referenceLineColor: referenceLineColor ?? this.referenceLineColor,
      hypnogramZoom: hypnogramZoom ?? this.hypnogramZoom,
      hypnogramOverlayMode: hypnogramOverlayMode ?? this.hypnogramOverlayMode,
      hypnogramProbabilityStage:
          hypnogramProbabilityStage ?? this.hypnogramProbabilityStage,
      eegPanelTimeUnit: eegPanelTimeUnit ?? this.eegPanelTimeUnit,
      lightsOffSeconds: lightsOffSeconds ?? this.lightsOffSeconds,
      lightsOnSeconds: lightsOnSeconds ?? this.lightsOnSeconds,
      stagesConfidence: stagesConfidence ?? this.stagesConfidence,
      stageProbabilities: stageProbabilities ?? this.stageProbabilities,
      recordingStartTime: recordingStartTime ?? this.recordingStartTime,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

const String kChannelDisplayFixed = 'Fixed';
const String kChannelDisplayAuto = 'Auto';
const String kChannelDisplayLevel = 'Level';
const List<String> kChannelDisplayModes = [
  kChannelDisplayFixed,
  kChannelDisplayAuto,
  kChannelDisplayLevel,
];

/// Kind of slowly varying "level" signal, which is shown on an absolute
/// scale instead of around its mean.
enum LevelSignalKind { spo2, pulse, position, co2, other }

final RegExp _eegLikeLabel = RegExp(
  r'\b(EEG|EOG|EMG|ECG|EKG|LOC|ROC|E1|E2|CHIN|LEG|LAT|RAT|TIB)\b|^(F|C|O|P|T|FP|AF|FC|CP|PO|FT|TP)\d',
);
final RegExp _levelLabel = RegExp(
  r'SPO2|SPO₂|SAO2|SAT\b|OXI|OXYG|\bHR\b|\bPR\b|PULSE|HEART ?RATE|POSITION|\bPOS\b|BODY|CO2|LIGHT|\bLUX\b',
);
final RegExp _respiratoryLabel = RegExp(
  r'FLOW|PRESS|PTAF|CANNULA|NASAL|ORAL|THERM|EFFORT|\bTHO|THOR|CHEST|\bABD|ABDO|\bRIP\b|\bSUM\b|SNOR|RESP|PLETH|BREATH',
);

/// Level-signal kind for a channel label, or null for an ordinary trace.
LevelSignalKind? levelSignalKind(String label) {
  final u = label.toUpperCase();
  if (_eegLikeLabel.hasMatch(u)) return null;
  if (u.contains('PLETH') || u.contains('WAVE')) return null;
  if (!_levelLabel.hasMatch(u)) return null;
  if (RegExp(r'SPO2|SPO₂|SAO2|SAT\b|OXI|OXYG').hasMatch(u)) {
    return LevelSignalKind.spo2;
  }
  if (RegExp(r'\bHR\b|\bPR\b|PULSE|HEART ?RATE').hasMatch(u)) {
    return LevelSignalKind.pulse;
  }
  if (RegExp(r'POSITION|\bPOS\b|BODY').hasMatch(u)) {
    return LevelSignalKind.position;
  }
  if (u.contains('CO2')) return LevelSignalKind.co2;
  return LevelSignalKind.other;
}

/// Default display mode for a channel label: SpO2, pulse, position and CO2
/// on an absolute scale; flow, pressure, effort and snore auto-scaled; EEG,
/// EOG, EMG and ECG in µV.
String defaultDisplayModeForLabel(String label) {
  if (levelSignalKind(label) != null) return kChannelDisplayLevel;
  final u = label.toUpperCase();
  if (!_eegLikeLabel.hasMatch(u) && _respiratoryLabel.hasMatch(u)) {
    return kChannelDisplayAuto;
  }
  return kChannelDisplayFixed;
}

/// Night-level amplitude statistics of a channel (from up to ~200 000
/// evenly spaced samples).
class ChannelLevelStats {
  const ChannelLevelStats({
    required this.min,
    required this.p1,
    required this.p50,
    required this.p99,
    required this.max,
  });

  final double min;
  final double p1;
  final double p50;
  final double p99;
  final double max;

  static ChannelLevelStats of(List<double> samples) {
    if (samples.isEmpty) {
      return const ChannelLevelStats(min: 0, p1: -1, p50: 0, p99: 1, max: 0);
    }
    final step = (samples.length / 200000).ceil().clamp(1, 1 << 30);
    final picked = <double>[
      for (var i = 0; i < samples.length; i += step)
        if (samples[i].isFinite) samples[i],
    ]..sort();
    if (picked.isEmpty) {
      return const ChannelLevelStats(min: 0, p1: -1, p50: 0, p99: 1, max: 0);
    }
    double at(double q) => picked[((picked.length - 1) * q).round()];
    return ChannelLevelStats(
      min: picked.first,
      p1: at(0.01),
      p50: at(0.5),
      p99: at(0.99),
      max: picked.last,
    );
  }
}

/// Absolute range shown for a level signal at 100 % scale.
({double lo, double hi}) levelDisplayRange(
  LevelSignalKind kind,
  ChannelLevelStats stats,
) {
  double floorTo(double v, double step) => (v / step).floorToDouble() * step;
  double ceilTo(double v, double step) => (v / step).ceilToDouble() * step;
  switch (kind) {
    case LevelSignalKind.spo2:
      if (stats.p99 <= 1.5) {
        // Saturation stored as a fraction (0–1).
        return (lo: (floorTo(stats.p1 * 100, 10).clamp(50.0, 90.0)) / 100, hi: 1.0);
      }
      // 100 % at the top; the bottom follows the night's lowest values
      // (ignoring probe-off zeros) so desaturations stay readable.
      return (lo: floorTo(stats.p1, 10).clamp(50.0, 90.0).toDouble(), hi: 100.0);
    case LevelSignalKind.pulse:
      var lo = floorTo(stats.p1, 10);
      var hi = ceilTo(stats.p99, 10);
      if (hi - lo < 40) {
        final mid = (lo + hi) / 2;
        lo = floorTo(mid - 20, 10);
        hi = lo + 40;
      }
      return (lo: math.max(0.0, lo), hi: hi);
    case LevelSignalKind.position:
      final lo = stats.min.floorToDouble();
      final hi = stats.max.ceilToDouble();
      return (lo: lo, hi: hi > lo ? hi : lo + 1);
    case LevelSignalKind.co2:
      final lo = floorTo(stats.p1, 5);
      final hi = ceilTo(stats.p99, 5);
      return (lo: lo, hi: hi - lo < 10 ? lo + 10 : hi);
    case LevelSignalKind.other:
      final span = stats.p99 - stats.p1;
      final pad = span > 0 ? span * 0.05 : 1.0;
      return (lo: stats.p1 - pad, hi: stats.p99 + pad);
  }
}

class ChannelConfig {
  ChannelConfig({
    required this.name,
    this.sourceIndex,
    this.derived = false,
    this.sourceChannel,
    this.color = 'Black',
    this.displayOnScreen = true,
    this.scalingFactor = 100.0,
    this.verticalShift = 0.0,
    this.reReference = 'None',
    this.flipPolarity = false,
    this.filterHpEnabled = false,
    this.filterHpCutoff = 0.3,
    this.filterHpOrder = 4,
    this.filterLpEnabled = false,
    this.filterLpCutoff = 50.0,
    this.filterLpOrder = 4,
    this.filterNotchEnabled = false,
    this.filterNotchCutoff = 50.0,
    this.filterNotchOrder = 4,
    this.displayMode = '',
  });

  String name;
  int? sourceIndex;
  bool derived;
  String? sourceChannel;
  String color;
  bool displayOnScreen;
  double scalingFactor;
  double verticalShift;
  String reReference;
  bool flipPolarity;
  bool filterHpEnabled;
  double filterHpCutoff;
  int filterHpOrder;
  bool filterLpEnabled;
  double filterLpCutoff;
  int filterLpOrder;
  bool filterNotchEnabled;
  double filterNotchCutoff;
  int filterNotchOrder;

  /// How the trace is scaled: [kChannelDisplayFixed] (µV, EEG style),
  /// [kChannelDisplayAuto] (night-level amplitude fitted to the row, for
  /// flow / effort / snore) or [kChannelDisplayLevel] (absolute values on a
  /// fixed range, for SpO2, pulse, position…). Empty = chosen from the label.
  String displayMode;

  Map<String, dynamic> toJson() {
    return {
      'Channel_name': name,
      if (sourceIndex != null) 'sourceIndex': sourceIndex,
      if (derived) 'derived': true,
      if (sourceChannel != null && sourceChannel!.isNotEmpty)
        'source_channel': sourceChannel,
      'Channel_color': color,
      'Display_on_screen': displayOnScreen,
      'Scaling_factor': scalingFactor,
      'Vertical_shift': verticalShift,
      'Re_reference': reReference,
      'Flip_polarity': flipPolarity,
      'Filter_hp_enabled': filterHpEnabled,
      'Filter_hp_cutoff': filterHpCutoff,
      'Filter_hp_order': filterHpOrder,
      'Filter_lp_enabled': filterLpEnabled,
      'Filter_lp_cutoff': filterLpCutoff,
      'Filter_lp_order': filterLpOrder,
      'Filter_notch_enabled': filterNotchEnabled,
      'Filter_notch_cutoff': filterNotchCutoff,
      'Filter_notch_order': filterNotchOrder,
      if (displayMode.isNotEmpty) 'Display_mode': displayMode,
    };
  }

  factory ChannelConfig.fromJson(Map<String, dynamic> json) {
    return ChannelConfig(
      name: json['Channel_name'] as String? ?? '',
      sourceIndex: (json['sourceIndex'] as num?)?.toInt(),
      derived: _boolValue(json['derived']),
      sourceChannel: json['source_channel'] as String?,
      color: json['Channel_color'] as String? ?? 'Black',
      displayOnScreen: json.containsKey('Display_on_screen')
          ? _boolValue(json['Display_on_screen'])
          : true,
      scalingFactor: (json['Scaling_factor'] as num?)?.toDouble() ?? 100.0,
      verticalShift: (json['Vertical_shift'] as num?)?.toDouble() ?? 0.0,
      reReference: json['Re_reference'] as String? ?? 'None',
      flipPolarity: _boolValue(json['Flip_polarity']),
      filterHpEnabled: _boolValue(json['Filter_hp_enabled']),
      filterHpCutoff: (json['Filter_hp_cutoff'] as num?)?.toDouble() ?? 0.3,
      filterHpOrder: (json['Filter_hp_order'] as num?)?.toInt() ?? 4,
      filterLpEnabled: _boolValue(json['Filter_lp_enabled']),
      filterLpCutoff: (json['Filter_lp_cutoff'] as num?)?.toDouble() ?? 50.0,
      filterLpOrder: (json['Filter_lp_order'] as num?)?.toInt() ?? 4,
      filterNotchEnabled: _boolValue(json['Filter_notch_enabled']),
      filterNotchCutoff:
          (json['Filter_notch_cutoff'] as num?)?.toDouble() ?? 50.0,
      filterNotchOrder: (json['Filter_notch_order'] as num?)?.toInt() ?? 4,
      displayMode: json['Display_mode'] as String? ?? '',
    );
  }

  ChannelConfig copy() {
    return ChannelConfig(
      name: name,
      sourceIndex: sourceIndex,
      derived: derived,
      sourceChannel: sourceChannel,
      color: color,
      displayOnScreen: displayOnScreen,
      scalingFactor: scalingFactor,
      verticalShift: verticalShift,
      reReference: reReference,
      flipPolarity: flipPolarity,
      filterHpEnabled: filterHpEnabled,
      filterHpCutoff: filterHpCutoff,
      filterHpOrder: filterHpOrder,
      filterLpEnabled: filterLpEnabled,
      filterLpCutoff: filterLpCutoff,
      filterLpOrder: filterLpOrder,
      filterNotchEnabled: filterNotchEnabled,
      filterNotchCutoff: filterNotchCutoff,
      filterNotchOrder: filterNotchOrder,
      displayMode: displayMode,
    );
  }

  /// Display mode actually used (the stored one, or the default for the
  /// channel's label).
  String get effectiveDisplayMode => displayMode.isNotEmpty
      ? displayMode
      : defaultDisplayModeForLabel(sourceChannel ?? name);

  static bool _boolValue(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final lower = value.toLowerCase();
      return lower == 'true' || lower == '1' || lower == 'yes';
    }
    return false;
  }
}

/// A configurable EEG frequency band definition for spectral analysis (PSD, FOOOF, IRASA).
class BandConfig {
  BandConfig({
    required this.label,
    required this.low,
    required this.high,
  });

  String label;
  double low;
  double high;

  Map<String, dynamic> toJson() => {
    'label': label,
    'low': low,
    'high': high,
  };

  factory BandConfig.fromJson(Map<String, dynamic> json) {
    return BandConfig(
      label: json['label'] as String? ?? 'Band',
      low: (json['low'] as num?)?.toDouble() ?? 0.0,
      high: (json['high'] as num?)?.toDouble() ?? 0.0,
    );
  }

  BandConfig copy() => BandConfig(label: label, low: low, high: high);

  @override
  String toString() => '$label (${low.toStringAsFixed(1)} - ${high.toStringAsFixed(1)} Hz)';
}

/// Default standard frequency bands used in sleep EEG analysis.
List<BandConfig> defaultFrequencyBands() => [
  BandConfig(label: 'Delta', low: 0.5, high: 4.0),
  BandConfig(label: 'Theta', low: 4.0, high: 8.0),
  BandConfig(label: 'Alpha', low: 8.0, high: 12.0),
  BandConfig(label: 'Sigma', low: 10.0, high: 16.0),
  BandConfig(label: 'Beta', low: 12.0, high: 30.0),
  BandConfig(label: 'Gamma', low: 30.0, high: 40.0),
];

/// Physiological modality classification for channels in clinical polysomnography / EEG.
enum ChannelModality { eeg, eog, emg, ecg, respiratory, other }

/// Infers the physiological modality of [rawLabel].
ChannelModality detectChannelModality(String rawLabel) {
  final label = rawLabel
      .replaceAll(RegExp(r'^(EEG\s*|POL\s*)', caseSensitive: false), '')
      .replaceAll(RegExp(r'(-Ref|-REF|\s*Ref)$', caseSensitive: false), '')
      .trim();
  final lower = label.toLowerCase();
  if (lower.startsWith('eog') ||
      lower.startsWith('loc') ||
      lower.startsWith('roc') ||
      lower.startsWith('e1') ||
      lower.startsWith('e2') ||
      lower.contains('eye') ||
      lower.contains('eog')) {
    return ChannelModality.eog;
  }
  if (lower.startsWith('emg') ||
      lower.startsWith('chin') ||
      lower.startsWith('submental') ||
      lower.startsWith('leg') ||
      lower.startsWith('lat') ||
      lower.startsWith('rat') ||
      lower.startsWith('tib') ||
      lower.contains('chin') ||
      lower.contains('emg') ||
      lower.contains('tibial')) {
    return ChannelModality.emg;
  }
  if (lower.startsWith('ecg') ||
      lower.startsWith('ekg') ||
      lower.startsWith('heart') ||
      lower.contains('ecg') ||
      lower.contains('ekg')) {
    return ChannelModality.ecg;
  }
  if (lower.startsWith('resp') ||
      lower.startsWith('thor') ||
      lower.contains('thorax') ||
      lower.startsWith('chest') ||
      lower.startsWith('abd') ||
      lower.contains('abdomen') ||
      lower.startsWith('airflow') ||
      lower.startsWith('flow') ||
      lower.startsWith('nasal') ||
      lower.startsWith('therm') ||
      lower.startsWith('cflow') ||
      lower.startsWith('spo2') ||
      lower.startsWith('sao2') ||
      lower.startsWith('pleth') ||
      lower.startsWith('snore') ||
      lower.startsWith('sound') ||
      lower.startsWith('mic') ||
      lower.startsWith('cannula')) {
    return ChannelModality.respiratory;
  }
  final cleanName = lower.replaceAll(RegExp(r'[^a-z0-9]'), '');
  final eegPattern = RegExp(
    r'^(fp[12z]|af[1-9z]|f[1-9z]|fc[1-6z]|ft[7-9]|ft10|c[1-6z]|t[3-8]|tp[7-9]|tp10|cp[1-6z]|p[1-9z]|po[1-9z]|o[12z]|oz|cz|fz|pz|iz)$',
    caseSensitive: false,
  );
  if (eegPattern.hasMatch(cleanName) ||
      cleanName.startsWith('c3') ||
      cleanName.startsWith('c4') ||
      cleanName.startsWith('f3') ||
      cleanName.startsWith('f4') ||
      cleanName.startsWith('o1') ||
      cleanName.startsWith('o2') ||
      cleanName.startsWith('fp1') ||
      cleanName.startsWith('fp2') ||
      cleanName.startsWith('cz') ||
      cleanName.startsWith('fz') ||
      cleanName.startsWith('pz') ||
      cleanName.startsWith('t3') ||
      cleanName.startsWith('t4') ||
      cleanName.startsWith('t5') ||
      cleanName.startsWith('t6') ||
      cleanName.startsWith('t7') ||
      cleanName.startsWith('t8') ||
      cleanName.startsWith('p7') ||
      cleanName.startsWith('p8') ||
      lower.contains('eeg')) {
    return ChannelModality.eeg;
  }

  final firstToken = lower.split(RegExp(r'[\s\-_/]+')).first;
  if (eegPattern.hasMatch(firstToken)) {
    return ChannelModality.eeg;
  }

  return ChannelModality.other;
}

/// Human-readable label for [modality] suitable for popup menus and tooltips.
String channelModalityLabel(ChannelModality modality) {
  return switch (modality) {
    ChannelModality.eeg => 'EEG',
    ChannelModality.eog => 'EOG',
    ChannelModality.emg => 'EMG',
    ChannelModality.ecg => 'ECG',
    ChannelModality.respiratory => 'Respiratory',
    ChannelModality.other => 'Same-Type',
  };
}

/// Configures high-pass and low-pass display filters according to AASM guidelines:
/// - EEG: 0.3 Hz HP, 35.0 Hz LP
/// - EOG: 0.3 Hz HP, 35.0 Hz LP
/// - ECG: 0.3 Hz HP, 35.0 Hz LP
/// - EMG: 10.0 Hz HP, 100.0 Hz LP
/// - Respiratory / other: left disabled to avoid baseline distortion
void applyAasmFiltersToChannel(ChannelConfig channel) {
  var modality = detectChannelModality(channel.name);
  if (modality == ChannelModality.other && channel.sourceChannel != null) {
    modality = detectChannelModality(channel.sourceChannel!);
  }
  switch (modality) {
    case ChannelModality.eeg:
    case ChannelModality.eog:
    case ChannelModality.ecg:
      channel.filterHpEnabled = true;
      channel.filterHpCutoff = 0.3;
      channel.filterHpOrder = 4;
      channel.filterLpEnabled = true;
      channel.filterLpCutoff = 35.0;
      channel.filterLpOrder = 4;
      break;
    case ChannelModality.emg:
      channel.filterHpEnabled = true;
      channel.filterHpCutoff = 10.0;
      channel.filterHpOrder = 4;
      channel.filterLpEnabled = true;
      channel.filterLpCutoff = 100.0;
      channel.filterLpOrder = 4;
      break;
    case ChannelModality.respiratory:
    case ChannelModality.other:
      channel.filterHpEnabled = false;
      channel.filterLpEnabled = false;
      break;
  }
}

/// Applies AASM guideline display filters to all channels in [channels].
void applyAasmFiltersToAll(Iterable<ChannelConfig> channels) {
  for (final channel in channels) {
    applyAasmFiltersToChannel(channel);
  }
}

