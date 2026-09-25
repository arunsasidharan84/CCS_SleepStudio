// lib/src/eeg_backend.dart

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'edf_loader.dart';
import 'mat_loader.dart';
import 'r09_loader.dart' as r09;
import 'orbit_loader.dart';
import 'models.dart';
import 'signal_processing.dart' as sp;

// ─────────────────────────────────────────────────────────────────────────────
// Rust FFI bindings (optional — app works fully without the native library)
// ─────────────────────────────────────────────────────────────────────────────

typedef _LoadViewportNative =
    Pointer<_NativeViewport> Function(Pointer<Utf8> path);
typedef _LoadViewportDart =
    Pointer<_NativeViewport> Function(Pointer<Utf8> path);
typedef _FreeViewportNative = Void Function(Pointer<_NativeViewport> viewport);
typedef _FreeViewportDart = void Function(Pointer<_NativeViewport> viewport);

final class _SleepEegMorletResult extends Struct {
  external Pointer<Float> power;
  @Int32()
  external int powerLen;
  @Int32()
  external int nFreqs;
  @Int32()
  external int nSamples;
}

typedef _ComputeMorletNative =
    Pointer<_SleepEegMorletResult> Function(
      Pointer<Float> signal,
      Int32 nSamples,
      Float srate,
      Pointer<Float> freqs,
      Int32 nFreqs,
      Bool l2Normalize,
    );
typedef _ComputeMorletDart =
    Pointer<_SleepEegMorletResult> Function(
      Pointer<Float> signal,
      int nSamples,
      double srate,
      Pointer<Float> freqs,
      int nFreqs,
      bool l2Normalize,
    );

typedef _FreeMorletNative =
    Void Function(Pointer<_SleepEegMorletResult> result);
typedef _FreeMorletDart = void Function(Pointer<_SleepEegMorletResult> result);

final class _NativePoint extends Struct {
  @Float()
  external double x;
  @Float()
  external double y;
  @Int32()
  external int channel;
}

final class _NativeViewport extends Struct {
  @Float()
  external double sampleRateHz;
  @Int32()
  external int epochSeconds;
  @Int32()
  external int channelCount;
  @Int32()
  external int pointCount;
  external Pointer<_NativePoint> points;
}

final class _EdfSignal extends Struct {
  external Pointer<Utf8> label;
  external Pointer<Float> samples;
  @Int32()
  external int sampleCount;
}

final class _EdfFile extends Struct {
  @Float()
  external double sampleRateHz;
  @Int32()
  external int signalCount;
  external Pointer<_EdfSignal> signals;
  @Float()
  external double durationSeconds;
}

typedef _LoadEdfNative =
    Pointer<_EdfFile> Function(Pointer<Utf8> path, Bool scaleVolts);
typedef _LoadEdfDart =
    Pointer<_EdfFile> Function(Pointer<Utf8> path, bool scaleVolts);
typedef _FreeEdfNative = Void Function(Pointer<_EdfFile> edf);
typedef _FreeEdfDart = void Function(Pointer<_EdfFile> edf);

final class _SpectrogramResult extends Struct {
  external Pointer<Float> power;
  @Int32()
  external int powerLen;
  external Pointer<Float> freqs;
  @Int32()
  external int freqsLen;
  @Int32()
  external int nEpochs;
  @Int32()
  external int nFreqs;
}

typedef _ComputeSpectrogramNative =
    Pointer<_SpectrogramResult> Function(
      Pointer<Float> signal,
      Int32 signalLen,
      Float srate,
      Int32 epochSeconds,
      Int32 extensionSeconds,
    );
typedef _ComputeSpectrogramDart =
    Pointer<_SpectrogramResult> Function(
      Pointer<Float> signal,
      int signalLen,
      double srate,
      int epochSeconds,
      int extensionSeconds,
    );
typedef _FreeSpectrogramNative =
    Void Function(Pointer<_SpectrogramResult> result);
typedef _FreeSpectrogramDart =
    void Function(Pointer<_SpectrogramResult> result);

typedef _RunCommandStreamNative =
    Int32 Function(
      Pointer<Utf8> executable,
      Pointer<Utf8> argumentsJson,
      Pointer<NativeFunction<Void Function(Pointer<Utf8>)>> callback,
    );
typedef _RunCommandStreamDart =
    int Function(
      Pointer<Utf8> executable,
      Pointer<Utf8> argumentsJson,
      Pointer<NativeFunction<Void Function(Pointer<Utf8>)>> callback,
    );

typedef _LoadEsedbJsonNative = Pointer<Utf8> Function(Pointer<Utf8> path);
typedef _LoadEsedbJsonDart = Pointer<Utf8> Function(Pointer<Utf8> path);
typedef _FreeStringNative = Void Function(Pointer<Utf8> ptr);
typedef _FreeStringDart = void Function(Pointer<Utf8> ptr);

// ─────────────────────────────────────────────────────────────────────────────

/// Configuration object passed around to control which channel drives
/// the spectrogram and other display panels.
class AppConfig {
  AppConfig({
    this.spectrogramChannelIndex = 0,
    this.swaChannelIndex = 0,
    this.periodogramChannelIndex = 0,
    this.tfChannelIndex = 0,
    this.amplitudeRangeUv = 75.0,
    this.tfFreqMin = 0.25,
    this.tfFreqMax = 45.0,
    this.spectrogramFreqMin = 0.0,
    this.spectrogramFreqMax = 45.0,
    this.periodogramFreqMin = 4.0,
    this.periodogramFreqMax = 45.0,
    this.spectrogramPowerMin = -1.0,
    this.spectrogramPowerMax = 3.0,
    this.tfEnabled = true,
    this.tfDisplayMode = 'dB (median baseline)',
    this.tfFrequencyScale = 'Linear',
    this.tfShowRidge = false,
    this.tfAutoScale = true,
    this.tfPowerMin = -10.0,
    this.tfPowerMax = 15.0,
    this.stackChannels = false,
    this.robustZStandardize = false,
    this.periodogramDisplayMode = '1/f Removed',
    this.eegPanelTimeUnit = 'Seconds',
    this.distanceBetweenChannelsUv = 25.0,
    this.referenceAmplitudeLineUv = 37.5,
    this.spectrogramFlex = 50,
    this.hypnogramFlex = 27,
    this.periodogramFlex = 12,
    this.showSwaPlot = true,
    String? hypnogramOverlayMode,
    this.hypnogramProbabilityStage = 'N2',
    this.lightsOffSeconds,
    this.lightsOnSeconds,
    this.referenceLineThickness = 0.5,
    this.referenceLineColor = 'Light Grey',
    this.hypnogramZoom = 'Full Night',
    this.reportTitle = 'CCS Sleep Studio Sleep EEG Report',
    this.studySite = '',
    this.investigatorName = '',
    this.subjectId = '',
    this.subjectDetails = '',
    this.recordingDate = '',
    this.channels = const [],
    Map<int, String>? customEventNames,
    // Preprocessing configuration
    this.preprocessDownsampleHz = 250.0,
    this.preprocessBandpassLo = 0.5,
    this.preprocessBandpassHi = 40.0,
    this.preprocessNotchHz = 50.0,
    this.preprocessRansacThresh = 0.75,
    this.preprocessStimArtifact = true,
    this.preprocessStimF0,
    this.preprocessStimWin = 10.0,
    this.preprocessStimMaxCombs = 4,
    // Feature extraction configuration
    List<String>? featureAnalyses,
    this.spindleFreqMin = 11.0,
    this.spindleFreqMax = 16.0,
    this.spindleDurationMin = 0.5,
    this.spindleDurationMax = 3.0,
    this.slowWaveFreqMin = 0.3,
    this.slowWaveFreqMax = 2.0,
    this.slowWaveMinAmpUv = 75.0,
    // Band power definitions
    this.bandDeltaLo = 0.5,
    this.bandDeltaHi = 4.0,
    this.bandThetaLo = 4.0,
    this.bandThetaHi = 8.0,
    this.bandAlphaLo = 8.0,
    this.bandAlphaHi = 12.0,
    this.bandSigmaLo = 12.0,
    this.bandSigmaHi = 16.0,
    this.bandBetaLo = 16.0,
    this.bandBetaHi = 30.0,
    this.bandGammaLo = 30.0,
    this.bandGammaHi = 45.0,
  }) : hypnogramOverlayMode =
           hypnogramOverlayMode ?? (showSwaPlot ? 'SWA' : 'Off'),
       featureAnalyses = featureAnalyses != null
           ? List<String>.from(featureAnalyses)
           : ['core', 'spindles', 'slow_waves', 'pac', 'nlg'],
       customEventNames = customEventNames != null
           ? Map<int, String>.from(customEventNames)
           : {};

  // Preprocessing configuration fields
  double preprocessDownsampleHz;
  double preprocessBandpassLo;
  double preprocessBandpassHi;
  double preprocessNotchHz;
  double preprocessRansacThresh;
  bool preprocessStimArtifact;
  double? preprocessStimF0;
  double preprocessStimWin;
  int preprocessStimMaxCombs;

  // Feature extraction configuration fields
  List<String> featureAnalyses;
  double spindleFreqMin;
  double spindleFreqMax;
  double spindleDurationMin;
  double spindleDurationMax;
  double slowWaveFreqMin;
  double slowWaveFreqMax;
  double slowWaveMinAmpUv;

  double bandDeltaLo;
  double bandDeltaHi;
  double bandThetaLo;
  double bandThetaHi;
  double bandAlphaLo;
  double bandAlphaHi;
  double bandSigmaLo;
  double bandSigmaHi;
  double bandBetaLo;
  double bandBetaHi;
  double bandGammaLo;
  double bandGammaHi;

  int spectrogramChannelIndex;
  int swaChannelIndex;
  int periodogramChannelIndex;
  int tfChannelIndex;
  double amplitudeRangeUv;
  double tfFreqMin;
  double tfFreqMax;
  double spectrogramFreqMin;
  double spectrogramFreqMax;
  double periodogramFreqMin;
  double periodogramFreqMax;
  double spectrogramPowerMin;
  double spectrogramPowerMax;

  /// Whether the Morlet time-frequency panel is shown.
  /// Disabling this skips all wavelet computation for instant navigation.
  bool tfEnabled;

  String tfDisplayMode;
  String tfFrequencyScale;
  bool tfShowRidge;
  bool tfAutoScale;
  double tfPowerMin;
  double tfPowerMax;

  bool stackChannels;
  bool robustZStandardize;
  String periodogramDisplayMode;
  String eegPanelTimeUnit;
  double distanceBetweenChannelsUv;
  double referenceAmplitudeLineUv;
  int spectrogramFlex;
  int hypnogramFlex;
  int periodogramFlex;
  bool showSwaPlot;
  String hypnogramOverlayMode;
  String hypnogramProbabilityStage;
  double? lightsOffSeconds;
  double? lightsOnSeconds;
  double referenceLineThickness;
  String referenceLineColor;
  String hypnogramZoom;
  String reportTitle;
  String studySite;
  String investigatorName;
  String subjectId;
  String subjectDetails;
  String recordingDate;
  List<ChannelConfig> channels;
  Map<int, String> customEventNames;

  Map<String, dynamic> toJson() {
    return {
      'spectrogramChannelIndex': spectrogramChannelIndex,
      'swaChannelIndex': swaChannelIndex,
      'periodogramChannelIndex': periodogramChannelIndex,
      'tfChannelIndex': tfChannelIndex,
      'amplitudeRangeUv': amplitudeRangeUv,
      'tfFreqMin': tfFreqMin,
      'tfFreqMax': tfFreqMax,
      'spectrogramFreqMin': spectrogramFreqMin,
      'spectrogramFreqMax': spectrogramFreqMax,
      'periodogramFreqMin': periodogramFreqMin,
      'periodogramFreqMax': periodogramFreqMax,
      'spectrogramPowerMin': spectrogramPowerMin,
      'spectrogramPowerMax': spectrogramPowerMax,
      'tfEnabled': tfEnabled,
      'tfDisplayMode': tfDisplayMode,
      'tfFrequencyScale': tfFrequencyScale,
      'tfShowRidge': tfShowRidge,
      'tfAutoScale': tfAutoScale,
      'tfPowerMin': tfPowerMin,
      'tfPowerMax': tfPowerMax,
      'stackChannels': stackChannels,
      'robustZStandardize': robustZStandardize,
      'periodogramDisplayMode': periodogramDisplayMode,
      'eegPanelTimeUnit': eegPanelTimeUnit,
      'distanceBetweenChannelsUv': distanceBetweenChannelsUv,
      'referenceAmplitudeLineUv': referenceAmplitudeLineUv,
      'spectrogramFlex': spectrogramFlex,
      'hypnogramFlex': hypnogramFlex,
      'periodogramFlex': periodogramFlex,
      'showSwaPlot': showSwaPlot,
      'hypnogramOverlayMode': hypnogramOverlayMode,
      'hypnogramProbabilityStage': hypnogramProbabilityStage,
      'lightsOffSeconds': lightsOffSeconds,
      'lightsOnSeconds': lightsOnSeconds,
      'referenceLineThickness': referenceLineThickness,
      'referenceLineColor': referenceLineColor,
      'hypnogramZoom': hypnogramZoom,
      'reportTitle': reportTitle,
      'studySite': studySite,
      'investigatorName': investigatorName,
      'subjectId': subjectId,
      'subjectDetails': subjectDetails,
      'recordingDate': recordingDate,
      'channels': channels.map((c) => c.toJson()).toList(),
      'customEventNames':
          customEventNames.map((k, v) => MapEntry(k.toString(), v)),
      // Preprocessing serialization
      'preprocessDownsampleHz': preprocessDownsampleHz,
      'preprocessBandpassLo': preprocessBandpassLo,
      'preprocessBandpassHi': preprocessBandpassHi,
      'preprocessNotchHz': preprocessNotchHz,
      'preprocessRansacThresh': preprocessRansacThresh,
      'preprocessStimArtifact': preprocessStimArtifact,
      'preprocessStimF0': preprocessStimF0,
      'preprocessStimWin': preprocessStimWin,
      'preprocessStimMaxCombs': preprocessStimMaxCombs,
      // Feature extraction serialization
      'featureAnalyses': featureAnalyses,
      'spindleFreqMin': spindleFreqMin,
      'spindleFreqMax': spindleFreqMax,
      'spindleDurationMin': spindleDurationMin,
      'spindleDurationMax': spindleDurationMax,
      'slowWaveFreqMin': slowWaveFreqMin,
      'slowWaveFreqMax': slowWaveFreqMax,
      'slowWaveMinAmpUv': slowWaveMinAmpUv,
      'bandDeltaLo': bandDeltaLo,
      'bandDeltaHi': bandDeltaHi,
      'bandThetaLo': bandThetaLo,
      'bandThetaHi': bandThetaHi,
      'bandAlphaLo': bandAlphaLo,
      'bandAlphaHi': bandAlphaHi,
      'bandSigmaLo': bandSigmaLo,
      'bandSigmaHi': bandSigmaHi,
      'bandBetaLo': bandBetaLo,
      'bandBetaHi': bandBetaHi,
      'bandGammaLo': bandGammaLo,
      'bandGammaHi': bandGammaHi,
    };
  }

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    int safeInt(dynamic v, int def) {
      if (v == null) return def;
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? def;
      return def;
    }

    bool safeBool(dynamic v, bool def) {
      if (v == null) return def;
      if (v is bool) return v;
      if (v is num) return v != 0;
      if (v is String) {
        final l = v.toLowerCase();
        return l == 'true' || l == '1' || l == 'yes';
      }
      return def;
    }

    double? safeNullableDouble(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v);
      return null;
    }

    final parsedEventNames = <int, String>{};
    if (json['customEventNames'] is Map) {
      (json['customEventNames'] as Map).forEach((k, v) {
        final d = int.tryParse(k.toString());
        if (d != null && v != null && v.toString().trim().isNotEmpty) {
          parsedEventNames[d] = v.toString().trim();
        }
      });
    }

    return AppConfig(
      spectrogramChannelIndex: safeInt(json['spectrogramChannelIndex'], 0),
      swaChannelIndex: safeInt(
        json['swaChannelIndex'],
        safeInt(json['spectrogramChannelIndex'], 0),
      ),
      periodogramChannelIndex: safeInt(json['periodogramChannelIndex'], 0),
      tfChannelIndex: safeInt(json['tfChannelIndex'], 0),
      amplitudeRangeUv: (json['amplitudeRangeUv'] as num?)?.toDouble() ?? 75.0,
      tfFreqMin: (json['tfFreqMin'] as num?)?.toDouble() ?? 0.25,
      tfFreqMax: (json['tfFreqMax'] as num?)?.toDouble() ?? 45.0,
      spectrogramFreqMin:
          (json['spectrogramFreqMin'] as num?)?.toDouble() ?? 0.0,
      spectrogramFreqMax:
          (json['spectrogramFreqMax'] as num?)?.toDouble() ?? 45.0,
      periodogramFreqMin:
          (json['periodogramFreqMin'] as num?)?.toDouble() ?? 4.0,
      periodogramFreqMax:
          (json['periodogramFreqMax'] as num?)?.toDouble() ?? 45.0,
      spectrogramPowerMin:
          (json['spectrogramPowerMin'] as num?)?.toDouble() ?? -1.0,
      spectrogramPowerMax:
          (json['spectrogramPowerMax'] as num?)?.toDouble() ?? 3.0,
      tfEnabled: safeBool(json['tfEnabled'], false),
      tfDisplayMode: json['tfDisplayMode'] as String? ?? 'dB (median baseline)',
      tfFrequencyScale: json['tfFrequencyScale'] as String? ?? 'Linear',
      tfShowRidge: safeBool(json['tfShowRidge'], false),
      tfAutoScale: safeBool(json['tfAutoScale'], true),
      tfPowerMin: (json['tfPowerMin'] as num?)?.toDouble() ?? 0.0,
      tfPowerMax: (json['tfPowerMax'] as num?)?.toDouble() ?? 20.0,
      stackChannels: safeBool(json['stackChannels'], false),
      robustZStandardize: safeBool(json['robustZStandardize'], false),
      periodogramDisplayMode:
          json['periodogramDisplayMode'] as String? ?? '1/f Removed',
      eegPanelTimeUnit: json['eegPanelTimeUnit'] as String? ?? 'Seconds',
      distanceBetweenChannelsUv:
          (json['distanceBetweenChannelsUv'] as num?)?.toDouble() ?? 25.0,
      referenceAmplitudeLineUv:
          (json['referenceAmplitudeLineUv'] as num?)?.toDouble() ?? 37.5,
      spectrogramFlex: safeInt(json['spectrogramFlex'], 50),
      hypnogramFlex: safeInt(json['hypnogramFlex'], 27),
      periodogramFlex: safeInt(json['periodogramFlex'], 12),
      showSwaPlot: safeBool(json['showSwaPlot'], true),
      hypnogramOverlayMode:
          json['hypnogramOverlayMode'] as String? ??
          (safeBool(json['showSwaPlot'], true) ? 'SWA' : 'Off'),
      hypnogramProbabilityStage:
          json['hypnogramProbabilityStage'] as String? ?? 'N2',
      lightsOffSeconds: safeNullableDouble(json['lightsOffSeconds']),
      lightsOnSeconds: safeNullableDouble(json['lightsOnSeconds']),
      referenceLineThickness:
          (json['referenceLineThickness'] as num?)?.toDouble() ?? 0.5,
      referenceLineColor: json['referenceLineColor'] as String? ?? 'Light Grey',
      hypnogramZoom: json['hypnogramZoom'] as String? ?? 'Full Night',
      reportTitle:
          json['reportTitle'] as String? ?? 'CCS Sleep Studio Sleep EEG Report',
      studySite: json['studySite'] as String? ?? '',
      investigatorName: json['investigatorName'] as String? ?? '',
      subjectId: json['subjectId'] as String? ?? '',
      subjectDetails: json['subjectDetails'] as String? ?? '',
      recordingDate: json['recordingDate'] as String? ?? '',
      customEventNames: parsedEventNames,
      channels:
          (json['channels'] as List<dynamic>?)
              ?.map(
                (c) =>
                    ChannelConfig.fromJson(Map<String, dynamic>.from(c as Map)),
              )
              .toList() ??
          const [],
      // Preprocessing deserialization
      preprocessDownsampleHz:
          (json['preprocessDownsampleHz'] as num?)?.toDouble() ?? 250.0,
      preprocessBandpassLo:
          (json['preprocessBandpassLo'] as num?)?.toDouble() ?? 0.5,
      preprocessBandpassHi:
          (json['preprocessBandpassHi'] as num?)?.toDouble() ?? 40.0,
      preprocessNotchHz:
          (json['preprocessNotchHz'] as num?)?.toDouble() ?? 50.0,
      preprocessRansacThresh:
          (json['preprocessRansacThresh'] as num?)?.toDouble() ?? 0.75,
      preprocessStimArtifact: safeBool(json['preprocessStimArtifact'], true),
      preprocessStimF0: safeNullableDouble(json['preprocessStimF0']),
      preprocessStimWin:
          (json['preprocessStimWin'] as num?)?.toDouble() ?? 10.0,
      preprocessStimMaxCombs: safeInt(json['preprocessStimMaxCombs'], 4),
      // Feature extraction deserialization
      featureAnalyses: (json['featureAnalyses'] as List?)
          ?.map((e) => e.toString())
          .toList(),
      spindleFreqMin: (json['spindleFreqMin'] as num?)?.toDouble() ?? 11.0,
      spindleFreqMax: (json['spindleFreqMax'] as num?)?.toDouble() ?? 16.0,
      spindleDurationMin:
          (json['spindleDurationMin'] as num?)?.toDouble() ?? 0.5,
      spindleDurationMax:
          (json['spindleDurationMax'] as num?)?.toDouble() ?? 3.0,
      slowWaveFreqMin: (json['slowWaveFreqMin'] as num?)?.toDouble() ?? 0.3,
      slowWaveFreqMax: (json['slowWaveFreqMax'] as num?)?.toDouble() ?? 2.0,
      slowWaveMinAmpUv:
          (json['slowWaveMinAmpUv'] as num?)?.toDouble() ?? 75.0,
      bandDeltaLo: (json['bandDeltaLo'] as num?)?.toDouble() ?? 0.5,
      bandDeltaHi: (json['bandDeltaHi'] as num?)?.toDouble() ?? 4.0,
      bandThetaLo: (json['bandThetaLo'] as num?)?.toDouble() ?? 4.0,
      bandThetaHi: (json['bandThetaHi'] as num?)?.toDouble() ?? 8.0,
      bandAlphaLo: (json['bandAlphaLo'] as num?)?.toDouble() ?? 8.0,
      bandAlphaHi: (json['bandAlphaHi'] as num?)?.toDouble() ?? 12.0,
      bandSigmaLo: (json['bandSigmaLo'] as num?)?.toDouble() ?? 12.0,
      bandSigmaHi: (json['bandSigmaHi'] as num?)?.toDouble() ?? 16.0,
      bandBetaLo: (json['bandBetaLo'] as num?)?.toDouble() ?? 16.0,
      bandBetaHi: (json['bandBetaHi'] as num?)?.toDouble() ?? 30.0,
      bandGammaLo: (json['bandGammaLo'] as num?)?.toDouble() ?? 30.0,
      bandGammaHi: (json['bandGammaHi'] as num?)?.toDouble() ?? 45.0,
    );
  }

  List<dynamic> toPythonJson() {
    final global = {
      'Channel_for_spectogram':
          channels.isNotEmpty && spectrogramChannelIndex < channels.length
          ? channels[spectrogramChannelIndex].name
          : '',
      'SWA_channel': channels.isNotEmpty && swaChannelIndex < channels.length
          ? channels[swaChannelIndex].name
          : '',
      'Periodogram_channel':
          channels.isNotEmpty && periodogramChannelIndex < channels.length
          ? channels[periodogramChannelIndex].name
          : '',
      'Wavelet_channel': channels.isNotEmpty && tfChannelIndex < channels.length
          ? channels[tfChannelIndex].name
          : '',
      'Reference_amplitude_line_muV': referenceAmplitudeLineUv,
      'Amplitude_range_muV': amplitudeRangeUv,
      'Wavelet_frequency_limits_hz': [tfFreqMin, tfFreqMax],
      'Wavelet_frequency_scale': tfFrequencyScale,
      'Spectrogram_power_limits': [spectrogramPowerMin, spectrogramPowerMax],
      'Spectogram_limit_hz': [spectrogramFreqMin, spectrogramFreqMax],
      'Periodogram_limit_hz': [periodogramFreqMin, periodogramFreqMax],
      'Periodogram_display_mode': periodogramDisplayMode,
      'Wavelet_panel_visible': tfEnabled,
      'Wavelet_show_ridge': tfShowRidge,
      'Wavelet_autoscale': tfAutoScale,
      'Wavelet_display_mode': tfDisplayMode,
      'Wavelet_power_limits': {
        tfDisplayMode: [tfPowerMin, tfPowerMax],
      },
      'Stack_channels': stackChannels,
      'Robust_z_standardize': robustZStandardize,
      'Distance_between_channels_muV': distanceBetweenChannelsUv,
      'EEG_panel_time_unit': eegPanelTimeUnit,
      'Epoch_length_s': 30,
      'Sampling_rate_hz': 256.0,
      'Extension_epoch_s': [5.0, 5.0],
      'Spectrogram_flex': spectrogramFlex,
      'Hypnogram_flex': hypnogramFlex,
      'Periodogram_flex': periodogramFlex,
      'Show_swa_plot': showSwaPlot,
      'Hypnogram_overlay_mode': hypnogramOverlayMode,
      'Hypnogram_probability_stage': hypnogramProbabilityStage,
      'Lights_off_seconds': lightsOffSeconds,
      'Lights_on_seconds': lightsOnSeconds,
      'Reference_line_thickness': referenceLineThickness,
      'Reference_line_color': referenceLineColor,
      'Hypnogram_zoom': hypnogramZoom,
      'Report_title': reportTitle,
      'Study_site': studySite,
      'Investigator_name': investigatorName,
      'Subject_id': subjectId,
      'Subject_details': subjectDetails,
      'Recording_date': recordingDate,
    };
    final channelsList = channels.map((c) => c.toJson()).toList();
    return [global, channelsList];
  }

  factory AppConfig.fromPythonJson(dynamic json, List<String> loadedLabels) {
    if (json is List && json.length >= 2) {
      final global = json[0] as Map<String, dynamic>;
      final channelsList = json[1] as List<dynamic>;

      final channels = channelsList
          .map(
            (c) => ChannelConfig.fromJson(Map<String, dynamic>.from(c as Map)),
          )
          .toList();
      final channelNames = channels.map((c) => c.name).toList();

      int indexOfChannel(String? name) {
        if (name == null) return 0;
        final idx = channelNames.indexOf(name);
        return idx >= 0 ? idx : 0;
      }

      final specCh = global['Channel_for_spectogram'] as String?;
      final swaCh = global['SWA_channel'] as String?;
      final periodCh = global['Periodogram_channel'] as String?;
      final tfCh = global['Wavelet_channel'] as String?;
      final amp = global['Reference_amplitude_line_muV'] as num?;
      final tfDisplay =
          global['Wavelet_display_mode'] as String? ?? 'dB (median baseline)';
      final tfVis = _boolValue(
        global['Wavelet_panel_visible'],
        fallback: false,
      );
      final tfScale = global['Wavelet_frequency_scale'] as String? ?? 'Linear';
      final tfRidge = _boolValue(global['Wavelet_show_ridge']);
      final tfAutoScale = _boolValue(
        global['Wavelet_autoscale'],
        fallback: true,
      );
      final stack = _boolValue(global['Stack_channels']);
      final robust = _boolValue(global['Robust_z_standardize']);
      final periodogramMode =
          global['Periodogram_display_mode'] as String? ?? '1/f Removed';
      final eegPanelTimeUnit =
          global['EEG_panel_time_unit'] as String? ?? 'Seconds';
      final dist =
          (global['Distance_between_channels_muV'] as num?)?.toDouble() ?? 25.0;

      final specLimits = global['Spectrogram_power_limits'] as List<dynamic>?;
      final specFreqLimits = global['Spectogram_limit_hz'] as List<dynamic>?;
      final periodFreqLimits = global['Periodogram_limit_hz'] as List<dynamic>?;
      final tfPowerLimitsMap =
          global['Wavelet_power_limits'] as Map<String, dynamic>?;

      double tfMin = 0.0;
      double tfMax = 20.0;
      if (tfPowerLimitsMap != null && tfPowerLimitsMap.containsKey(tfDisplay)) {
        final limits = tfPowerLimitsMap[tfDisplay] as List<dynamic>?;
        if (limits != null && limits.length >= 2) {
          tfMin = (limits[0] as num).toDouble();
          tfMax = (limits[1] as num).toDouble();
        }
      } else {
        if (tfDisplay == 'Z-Standardized Power') {
          tfMin = -3.0;
          tfMax = 5.0;
        } else if (tfDisplay == 'dB (median baseline)') {
          tfMin = -10.0;
          tfMax = 15.0;
        } else if (tfDisplay == 'L2-Normalized Power' ||
            tfDisplay == 'Raw Power') {
          tfMin = -6.0;
          tfMax = 0.0;
        }
      }

      final tfFreqLimits =
          global['Wavelet_frequency_limits_hz'] as List<dynamic>?;
      double tfFreqMin = 0.25;
      double tfFreqMax = 45.0;
      if (tfFreqLimits != null && tfFreqLimits.length >= 2) {
        tfFreqMin = (tfFreqLimits[0] as num).toDouble();
        tfFreqMax = (tfFreqLimits[1] as num).toDouble();
      }

      int safeInt(dynamic v, int def) {
        if (v == null) return def;
        if (v is int) return v;
        if (v is num) return v.toInt();
        if (v is String) return int.tryParse(v) ?? def;
        return def;
      }

      bool safeBool(dynamic v, bool def) {
        if (v == null) return def;
        if (v is bool) return v;
        if (v is num) return v != 0;
        if (v is String) {
          final l = v.toLowerCase();
          return l == 'true' || l == '1' || l == 'yes';
        }
        return def;
      }

      final spectrogramFlex = safeInt(global['Spectrogram_flex'], 50);
      final hypnogramFlex = safeInt(global['Hypnogram_flex'], 27);
      final periodogramFlex = safeInt(global['Periodogram_flex'], 12);
      final showSwaPlot = safeBool(global['Show_swa_plot'], true);
      final hypnogramOverlayMode =
          global['Hypnogram_overlay_mode'] as String? ??
          (showSwaPlot ? 'SWA' : 'Off');
      final hypnogramProbabilityStage =
          global['Hypnogram_probability_stage'] as String? ?? 'N2';
      final lightsOffSeconds = (global['Lights_off_seconds'] as num?)
          ?.toDouble();
      final lightsOnSeconds = (global['Lights_on_seconds'] as num?)?.toDouble();
      final referenceLineThickness =
          (global['Reference_line_thickness'] as num?)?.toDouble() ?? 0.5;
      final referenceLineColor =
          global['Reference_line_color'] as String? ?? 'Light Grey';
      final hypnogramZoom = global['Hypnogram_zoom'] as String? ?? 'Full Night';
      final reportTitle =
          global['Report_title'] as String? ?? 'CCS Sleep Studio Sleep EEG Report';
      final studySite = global['Study_site'] as String? ?? '';
      final investigatorName = global['Investigator_name'] as String? ?? '';
      final subjectId = global['Subject_id'] as String? ?? '';
      final subjectDetails = global['Subject_details'] as String? ?? '';
      final recordingDate = global['Recording_date'] as String? ?? '';

      return AppConfig(
        spectrogramChannelIndex: indexOfChannel(specCh),
        swaChannelIndex: indexOfChannel(swaCh ?? specCh),
        periodogramChannelIndex: indexOfChannel(periodCh),
        tfChannelIndex: indexOfChannel(tfCh),
        amplitudeRangeUv:
            (global['Amplitude_range_muV'] as num?)?.toDouble() ?? 75.0,
        referenceAmplitudeLineUv: amp?.toDouble() ?? 37.5,
        tfEnabled: tfVis,
        tfDisplayMode: tfDisplay,
        tfFrequencyScale: tfScale,
        tfShowRidge: tfRidge,
        tfAutoScale: tfAutoScale,
        tfPowerMin: tfMin,
        tfPowerMax: tfMax,
        tfFreqMin: tfFreqMin,
        tfFreqMax: tfFreqMax,
        spectrogramFreqMin: specFreqLimits != null && specFreqLimits.isNotEmpty
            ? (specFreqLimits[0] as num).toDouble()
            : 0.0,
        spectrogramFreqMax: specFreqLimits != null && specFreqLimits.length >= 2
            ? (specFreqLimits[1] as num).toDouble()
            : 45.0,
        periodogramFreqMin:
            periodFreqLimits != null && periodFreqLimits.isNotEmpty
            ? (periodFreqLimits[0] as num).toDouble()
            : 4.0,
        periodogramFreqMax:
            periodFreqLimits != null && periodFreqLimits.length >= 2
            ? (periodFreqLimits[1] as num).toDouble()
            : 45.0,
        spectrogramPowerMin: specLimits != null && specLimits.isNotEmpty
            ? (specLimits[0] as num).toDouble()
            : -1.0,
        spectrogramPowerMax: specLimits != null && specLimits.length >= 2
            ? (specLimits[1] as num).toDouble()
            : 3.0,
        stackChannels: stack,
        robustZStandardize: robust,
        periodogramDisplayMode: periodogramMode,
        eegPanelTimeUnit: eegPanelTimeUnit,
        distanceBetweenChannelsUv: dist,
        spectrogramFlex: spectrogramFlex,
        hypnogramFlex: hypnogramFlex,
        periodogramFlex: periodogramFlex,
        showSwaPlot: showSwaPlot,
        hypnogramOverlayMode: hypnogramOverlayMode,
        hypnogramProbabilityStage: hypnogramProbabilityStage,
        lightsOffSeconds: lightsOffSeconds,
        lightsOnSeconds: lightsOnSeconds,
        referenceLineThickness: referenceLineThickness,
        referenceLineColor: referenceLineColor,
        hypnogramZoom: hypnogramZoom,
        reportTitle: reportTitle,
        studySite: studySite,
        investigatorName: investigatorName,
        subjectId: subjectId,
        subjectDetails: subjectDetails,
        recordingDate: recordingDate,
        channels: channels,
      );
    }

    final defaultChannels = loadedLabels
        .asMap()
        .entries
        .map(
          (entry) => _defaultChannelConfig(
            entry.value,
            entry.key,
            loadedLabels.length,
          ),
        )
        .toList();
    return AppConfig(channels: defaultChannels);
  }

  static AppConfig defaultsForChannels(
    List<String> labels, {
    required double sampleRateHz,
  }) {
    return AppConfig(
      spectrogramChannelIndex: 0,
      swaChannelIndex: 0,
      periodogramChannelIndex: 0,
      tfChannelIndex: 0,
      amplitudeRangeUv: 75.0,
      distanceBetweenChannelsUv: 25.0,
      referenceAmplitudeLineUv: 37.5,
      channels: labels.asMap().entries.map((entry) {
        return _defaultChannelConfig(entry.value, entry.key, labels.length);
      }).toList(),
    );
  }

  static ChannelConfig defaultChannelConfig(
    String name,
    int index,
    int channelCount,
  ) {
    final upper = name.toUpperCase();
    var color = 'Black';
    if (upper.contains('EOG')) {
      color = 'Blue';
    } else if (upper.contains('ECG')) {
      color = 'Magenta';
    } else if (upper.contains('EMG')) {
      color = 'Orange';
    }
    var display = index < 9;
    if (channelCount == 9 && (index == 1 || index == 3 || index == 5)) {
      display = false;
    }
    return ChannelConfig(
      name: name,
      sourceIndex: index,
      color: color,
      displayOnScreen: display,
    );
  }

  static ChannelConfig _defaultChannelConfig(
    String name,
    int index,
    int channelCount,
  ) =>
      defaultChannelConfig(name, index, channelCount);

  void bindLoadedChannels(List<String> loadedLabels, {double? sampleRateHz}) {
    if (channels.isEmpty) {
      channels = defaultsForChannels(
        loadedLabels,
        sampleRateHz: sampleRateHz ?? 256.0,
      ).channels;
    }

    final rawNameToIndex = <String, int>{};
    for (var i = 0; i < loadedLabels.length; i++) {
      rawNameToIndex[loadedLabels[i]] = i;
    }

    for (var i = 0; i < channels.length; i++) {
      final channel = channels[i];
      final sourceName = channel.derived
          ? (channel.sourceChannel ?? channel.name)
          : channel.name;

      // 1. Exact match
      var byName = rawNameToIndex[sourceName];

      // 2. Case-insensitive and trimmed match
      if (byName == null) {
        final normName = sourceName.toLowerCase().trim();
        for (final entry in rawNameToIndex.entries) {
          if (entry.key.toLowerCase().trim() == normName) {
            byName = entry.value;
            break;
          }
        }
      }

      // 3. Partial match (e.g. "EEG L" matches "EEG L-M2")
      if (byName == null) {
        final normName = sourceName.toLowerCase().trim();
        for (final entry in rawNameToIndex.entries) {
          final normKey = entry.key.toLowerCase().trim();
          if (normKey.contains(normName) || normName.contains(normKey)) {
            byName = entry.value;
            break;
          }
        }
      }

      if (byName != null) {
        channel.sourceIndex = byName;
      } else {
        // Fallback: keep existing index if valid, otherwise bind to i
        if (channel.sourceIndex == null ||
            channel.sourceIndex! < 0 ||
            channel.sourceIndex! >= loadedLabels.length) {
          channel.sourceIndex = i < loadedLabels.length ? i : null;
        }
      }
    }

    final configuredRawIndices = channels
        .where((channel) => !channel.derived)
        .map((channel) => channel.sourceIndex)
        .whereType<int>()
        .toSet();
    for (var rawIndex = 0; rawIndex < loadedLabels.length; rawIndex++) {
      if (!configuredRawIndices.contains(rawIndex)) {
        channels.add(
          _defaultChannelConfig(
            loadedLabels[rawIndex],
            rawIndex,
            loadedLabels.length,
          ),
        );
      }
    }

    final availableNames = channels.map((channel) => channel.name).toSet();
    for (final channel in channels) {
      if (channel.reReference != 'None' &&
          !availableNames.contains(channel.reReference)) {
        channel.reReference = 'None';
      }
      channel.filterHpOrder = channel.filterHpOrder.clamp(1, 10);
      channel.filterLpOrder = channel.filterLpOrder.clamp(1, 10);
      channel.filterNotchOrder = channel.filterNotchOrder.clamp(1, 10);
    }

    if (channels.isNotEmpty) {
      spectrogramChannelIndex = spectrogramChannelIndex.clamp(
        0,
        channels.length - 1,
      );
      swaChannelIndex = swaChannelIndex.clamp(0, channels.length - 1);
      periodogramChannelIndex = periodogramChannelIndex.clamp(
        0,
        channels.length - 1,
      );
      tfChannelIndex = tfChannelIndex.clamp(0, channels.length - 1);
    }

    final nyquist = (sampleRateHz ?? 256.0) / 2;
    final maxDisplayFrequency = math.max(0.02, nyquist - 0.01);
    tfFreqMin = tfFreqMin.clamp(0.01, maxDisplayFrequency).toDouble();
    tfFreqMax = tfFreqMax
        .clamp(tfFreqMin, math.max(tfFreqMin, maxDisplayFrequency))
        .toDouble();
    spectrogramFreqMin = spectrogramFreqMin
        .clamp(0.0, maxDisplayFrequency)
        .toDouble();
    spectrogramFreqMax = spectrogramFreqMax
        .clamp(
          spectrogramFreqMin,
          math.max(spectrogramFreqMin, maxDisplayFrequency),
        )
        .toDouble();
    periodogramFreqMin = periodogramFreqMin
        .clamp(0.0, maxDisplayFrequency)
        .toDouble();
    periodogramFreqMax = periodogramFreqMax
        .clamp(
          periodogramFreqMin,
          math.max(periodogramFreqMin, maxDisplayFrequency),
        )
        .toDouble();
  }

  static bool _boolValue(Object? value, {bool fallback = false}) {
    if (value == null) return fallback;
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final lower = value.toLowerCase();
      if (lower == 'true' || lower == '1' || lower == 'yes') return true;
      if (lower == 'false' || lower == '0' || lower == 'no') return false;
    }
    return fallback;
  }
}

// ─────────────────────────────────────────────────────────────────────────────

DynamicLibrary _openDynamicLibrary() {
  String name;
  if (Platform.isMacOS) {
    name = 'librust_sleep_eeg.dylib';
  } else if (Platform.isWindows) {
    name = 'rust_sleep_eeg.dll';
  } else {
    name = 'librust_sleep_eeg.so';
  }

  final paths = [
    name,
    '${Directory.current.path}/../bridge/target/release/$name',
    '${Directory.current.path}/../bridge/target/debug/$name',
    '${Directory.current.path}/bridge/target/release/$name',
    '${Directory.current.path}/bridge/target/debug/$name',
    '${Directory.current.path}/rust_backend/target/release/$name',
    '${Directory.current.path}/rust_backend/target/debug/$name',
    '${File(Platform.resolvedExecutable).parent.path}/$name',
    '${File(Platform.resolvedExecutable).parent.path}/../Frameworks/$name',
  ];

  for (final path in paths) {
    try {
      return DynamicLibrary.open(path);
    } catch (_) {}
  }
  throw OSError('Could not open library: $name');
}

// ─────────────────────────────────────────────────────────────────────────────

class EegBackend {
  EegBackend() {
    try {
      final library = _openDynamicLibrary();
      _loadViewport = library
          .lookupFunction<_LoadViewportNative, _LoadViewportDart>(
            'sleep_eeg_load_viewport',
          );
      _freeViewport = library
          .lookupFunction<_FreeViewportNative, _FreeViewportDart>(
            'sleep_eeg_free_viewport',
          );
      _computeMorlet = library
          .lookupFunction<_ComputeMorletNative, _ComputeMorletDart>(
            'sleep_eeg_compute_morlet_tf',
          );
      _freeMorlet = library.lookupFunction<_FreeMorletNative, _FreeMorletDart>(
        'sleep_eeg_free_morlet_tf',
      );
      try {
        _loadEdf = library.lookupFunction<_LoadEdfNative, _LoadEdfDart>(
          'sleep_eeg_load_edf',
        );
      } catch (e) {
        debugPrint('[EegBackend] sleep_eeg_load_edf lookup error: $e');
      }
      try {
        _loadNk = library.lookupFunction<_LoadEdfNative, _LoadEdfDart>(
          'sleep_eeg_load_nihon_kohden',
        );
      } catch (e) {
        debugPrint('[EegBackend] sleep_eeg_load_nihon_kohden lookup error: $e');
      }
      try {
        _loadEmbla = library.lookupFunction<_LoadEdfNative, _LoadEdfDart>(
          'sleep_eeg_load_embla',
        );
      } catch (e) {
        debugPrint('[EegBackend] sleep_eeg_load_embla lookup error: $e');
      }
      try {
        _loadVhdr = library.lookupFunction<_LoadEdfNative, _LoadEdfDart>(
          'sleep_eeg_load_vhdr',
        );
      } catch (e) {
        debugPrint('[EegBackend] sleep_eeg_load_vhdr lookup error: $e');
      }
      try {
        _freeEdf = library.lookupFunction<_FreeEdfNative, _FreeEdfDart>(
          'sleep_eeg_free_edf',
        );
      } catch (e) {
        debugPrint('[EegBackend] sleep_eeg_free_edf lookup error: $e');
      }
      try {
        _loadEsedbJson = library.lookupFunction<_LoadEsedbJsonNative, _LoadEsedbJsonDart>(
          'sleep_eeg_load_esedb_json',
        );
      } catch (e) {
        debugPrint('[EegBackend] sleep_eeg_load_esedb_json lookup error: $e');
      }
      try {
        _freeString = library.lookupFunction<_FreeStringNative, _FreeStringDart>(
          'sleep_eeg_free_string',
        );
      } catch (e) {
        debugPrint('[EegBackend] sleep_eeg_free_string lookup error: $e');
      }
      try {
        _computeSpectrogramNative = library
            .lookupFunction<_ComputeSpectrogramNative, _ComputeSpectrogramDart>(
              'sleep_eeg_compute_welch_spectrogram',
            );
        _freeSpectrogramNative = library
            .lookupFunction<_FreeSpectrogramNative, _FreeSpectrogramDart>(
              'sleep_eeg_free_spectrogram',
            );
      } catch (_) {}
      try {
        _runCommandStream = library
            .lookupFunction<_RunCommandStreamNative, _RunCommandStreamDart>(
              'sleep_eeg_run_command_stream',
            );
      } catch (_) {}
      isNativeAvailable = true;
    } on Object {
      isNativeAvailable = false;
    }
  }

  late final bool isNativeAvailable;
  _LoadViewportDart? _loadViewport;
  _FreeViewportDart? _freeViewport;
  _ComputeMorletDart? _computeMorlet;
  _FreeMorletDart? _freeMorlet;
  _LoadEdfDart? _loadEdf;
  _LoadEdfDart? _loadNk;
  _LoadEdfDart? _loadEmbla;
  _LoadEdfDart? _loadVhdr;
  _FreeEdfDart? _freeEdf;
  _LoadEsedbJsonDart? _loadEsedbJson;
  _FreeStringDart? _freeString;
  _ComputeSpectrogramDart? _computeSpectrogramNative;
  _FreeSpectrogramDart? _freeSpectrogramNative;
  _RunCommandStreamDart? _runCommandStream;

  static List<({int startSec, String stage})>? loadEsedbNative(String filePath) {
    try {
      final lib = _openDynamicLibrary();
      final loadFn = lib.lookupFunction<_LoadEsedbJsonNative, _LoadEsedbJsonDart>(
        'sleep_eeg_load_esedb_json',
      );
      final freeFn = lib.lookupFunction<_FreeStringNative, _FreeStringDart>(
        'sleep_eeg_free_string',
      );
      final pathPtr = filePath.toNativeUtf8();
      final resultPtr = loadFn(pathPtr);
      calloc.free(pathPtr);
      if (resultPtr == nullptr) return null;

      final jsonStr = resultPtr.toDartString();
      freeFn(resultPtr);

      final List<dynamic> list = jsonDecode(jsonStr);
      return list.map((item) {
        final stage = item['stage'] as String;
        final startSec = (item['start_sec'] as num).toInt();
        return (startSec: startSec, stage: stage);
      }).toList();
    } catch (e) {
      debugPrint('[EegBackend] loadEsedbNative error: $e');
      return null;
    }
  }

  final _displayPointCache = <String, List<Float32List>>{};
  final _displayPointCacheOrder = <String>[];
  final _tfCache = <String, List<List<double>>>{};
  final _tfCacheOrder = <String>[];
  final _tfImageCache = <String, ui.Image>{};
  final _tfImageCacheOrder = <String>[];
  final _tfScaleCache = <String, ({double min, double max})>{};

  /// Clears the waveform display point cache. Call this when filter or
  /// channel display settings change to ensure stale cached waveforms
  /// are not shown.
  void clearDisplayCache() {
    _displayPointCache.clear();
    _displayPointCacheOrder.clear();
  }

  String get _libraryName {
    if (Platform.isMacOS) return 'librust_sleep_eeg.dylib';
    if (Platform.isWindows) return 'rust_sleep_eeg.dll';
    return 'librust_sleep_eeg.so';
  }

  // ─── Public loaders ────────────────────────────────────────────────────────

  LoadedEeg loadEdf(
    String path, {
    bool scaleVoltsToMicrovolts = false,
    AppConfig? config,
  }) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.orb') || lower.endsWith('.signal')) {
      return OrbitLoader().load(path);
    }
    final isNk = lower.endsWith('.eeg');
    final isEmbla = lower.endsWith('.ebm');
    final isVhdr = lower.endsWith('.vhdr');

    if (isVhdr) {
      if (_loadVhdr == null) {
        throw FormatException(
          'Brain Products VHDR native library loader is not initialized.',
        );
      }
      final pathPtr = path.toNativeUtf8();
      try {
        final edfPtr = _loadVhdr!(pathPtr, false);
        if (edfPtr != nullptr) {
          final edf = edfPtr.ref;
          final channelLabels = <String>[];
          final channelSamples = <List<double>>[];

          for (var i = 0; i < edf.signalCount; i++) {
            final sig = edf.signals[i];
            channelLabels.add(sig.label.toDartString());

            final count = sig.sampleCount;
            final samples = Float64List(count);
            samples.setAll(0, sig.samples.asTypedList(count));
            channelSamples.add(samples);
          }

          final sampleRate = edf.sampleRateHz;
          final durationSec = edf.durationSeconds;
          _freeEdf?.call(edfPtr);

          return LoadedEeg(
            sampleRateHz: sampleRate,
            channelLabels: channelLabels,
            channelSamples: channelSamples,
            recordingStartTime: null,
            sourceDescription:
                '${channelLabels.length} channels, ${sampleRate.toStringAsFixed(1)} Hz, ${(durationSec / 60).toStringAsFixed(1)} min (Brain Vision)',
          );
        } else {
          throw FormatException(
            'Native Brain Products VHDR parser returned null for $path. Data file may be missing or corrupt.',
          );
        }
      } catch (e) {
        if (e is FormatException) rethrow;
        throw FormatException(
          'Failed to load Brain Products VHDR recording ($path): $e',
        );
      } finally {
        calloc.free(pathPtr);
      }
    }

    if (isNk) {
      if (_loadNk == null) {
        throw FormatException('Nihon Kohden native library loader is not initialized.');
      }
      final pathPtr = path.toNativeUtf8();
      try {
        final edfPtr = _loadNk!(pathPtr, false);
        if (edfPtr != nullptr) {
          final edf = edfPtr.ref;
          final channelLabels = <String>[];
          final channelSamples = <List<double>>[];

          for (var i = 0; i < edf.signalCount; i++) {
            final sig = edf.signals[i];
            channelLabels.add(sig.label.toDartString());

            final count = sig.sampleCount;
            final samples = Float64List(count);
            samples.setAll(0, sig.samples.asTypedList(count));
            channelSamples.add(samples);
          }

          final sampleRate = edf.sampleRateHz;
          final durationSec = edf.durationSeconds;
          _freeEdf?.call(edfPtr);

          return LoadedEeg(
            sampleRateHz: sampleRate,
            channelLabels: channelLabels,
            channelSamples: channelSamples,
            recordingStartTime: null,
            sourceDescription:
                '${channelLabels.length} channels, ${sampleRate.toStringAsFixed(1)} Hz, ${(durationSec / 60).toStringAsFixed(1)} min (Nihon Kohden)',
          );
        } else {
          throw FormatException('Native Nihon Kohden parser returned null for $path. File may be truncated or corrupted.');
        }
      } catch (e) {
        if (e is FormatException) rethrow;
        throw FormatException('Failed to load Nihon Kohden recording ($path): $e');
      } finally {
        calloc.free(pathPtr);
      }
    }

    if (isEmbla) {
      if (_loadEmbla == null) {
        throw FormatException('EMBLA native library loader is not initialized.');
      }
      final pathPtr = path.toNativeUtf8();
      try {
        final edfPtr = _loadEmbla!(pathPtr, false);
        if (edfPtr != nullptr) {
          final edf = edfPtr.ref;
          final channelLabels = <String>[];
          final channelSamples = <List<double>>[];

          for (var i = 0; i < edf.signalCount; i++) {
            final sig = edf.signals[i];
            channelLabels.add(sig.label.toDartString());

            final count = sig.sampleCount;
            final samples = Float64List(count);
            samples.setAll(0, sig.samples.asTypedList(count));
            channelSamples.add(samples);
          }

          final sampleRate = edf.sampleRateHz;
          final durationSec = edf.durationSeconds;
          _freeEdf?.call(edfPtr);

          return LoadedEeg(
            sampleRateHz: sampleRate,
            channelLabels: channelLabels,
            channelSamples: channelSamples,
            recordingStartTime: null,
            sourceDescription:
                '${channelLabels.length} channels, ${sampleRate.toStringAsFixed(1)} Hz, ${(durationSec / 60).toStringAsFixed(1)} min (EMBLA)',
          );
        } else {
          throw FormatException('Native EMBLA parser returned null for $path. No valid .ebm files found in folder.');
        }
      } catch (e) {
        if (e is FormatException) rethrow;
        throw FormatException('Failed to load EMBLA recording ($path): $e');
      } finally {
        calloc.free(pathPtr);
      }
    }

    if (_loadEdf != null && _freeEdf != null) {
      final pathPtr = path.toNativeUtf8();
      try {
        final edfPtr = _loadEdf!(pathPtr, scaleVoltsToMicrovolts);
        if (edfPtr != nullptr) {
          final edf = edfPtr.ref;
          final channelLabels = <String>[];
          final channelSamples = <List<double>>[];

          for (var i = 0; i < edf.signalCount; i++) {
            final sig = edf.signals[i];
            channelLabels.add(sig.label.toDartString());

            final count = sig.sampleCount;
            final samples = Float64List(count);
            samples.setAll(0, sig.samples.asTypedList(count));
            channelSamples.add(samples);
          }

          final sampleRate = edf.sampleRateHz;
          final durationSec = edf.durationSeconds;
          final recordingStartTime = EdfLoader.readStartDateTime(path);

          _freeEdf!(edfPtr);

          return LoadedEeg(
            sampleRateHz: sampleRate,
            channelLabels: channelLabels,
            channelSamples: channelSamples,
            recordingStartTime: recordingStartTime,
            sourceDescription:
                '${channelLabels.length} channels, ${sampleRate.toStringAsFixed(1)} Hz, ${(durationSec / 60).toStringAsFixed(1)} min (native)',
          );
        }
      } catch (e) {
        debugPrint('Failed native load for $path: $e');
      } finally {
        calloc.free(pathPtr);
      }
    }
    return EdfLoader().load(
      path,
      scaleVoltsToMicrovolts: scaleVoltsToMicrovolts,
    );
  }

  LoadedEeg loadMat(String path, {AppConfig? config}) {
    return MatLoader().load(path);
  }

  LoadedEeg loadR09(String path, {AppConfig? config}) {
    return r09.loadR09(path);
  }

  int runCommandStream({
    required String executable,
    required List<String> arguments,
    required void Function(String line) onLine,
  }) {
    if (_runCommandStream == null) {
      try {
        final result = Process.runSync(executable, arguments);
        for (final line in '${result.stdout}'.split(RegExp(r'\r?\n'))) {
          if (line.isNotEmpty) onLine(line);
        }
        for (final line in '${result.stderr}'.split(RegExp(r'\r?\n'))) {
          if (line.isNotEmpty) onLine(line);
        }
        return result.exitCode;
      } on Object catch (error) {
        onLine('Failed to start AutoscoreNidra backend: $error');
        return -99;
      }
    }

    final execPtr = executable.toNativeUtf8();
    final argsJson = jsonEncode(arguments);
    final argsPtr = argsJson.toNativeUtf8();

    final nativeCallback =
        NativeCallable<Void Function(Pointer<Utf8>)>.listener((
          Pointer<Utf8> linePtr,
        ) {
          final line = linePtr.toDartString();
          onLine(line);
        });

    try {
      final result = _runCommandStream!(
        execPtr,
        argsPtr,
        nativeCallback.nativeFunction,
      );
      return result;
    } finally {
      calloc.free(execPtr);
      calloc.free(argsPtr);
      nativeCallback.close();
    }
  }

  Future<int> runCommandStreamAsync({
    required String executable,
    required List<String> arguments,
    required void Function(String line) onLine,
  }) async {
    try {
      final process = await Process.start(
        executable,
        arguments,
        environment: {...Platform.environment, 'PYTHONUNBUFFERED': '1'},
      );
      final stdoutDone = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach(onLine);
      final stderrDone = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) => onLine('[stderr] $line'));
      final exitCode = await process.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      return exitCode;
    } on Object catch (error) {
      onLine('Failed to start process: $error');
      return -99;
    }
  }

  List<double> getDisplaySegmentForChannel({
    required LoadedEeg eeg,
    required int channelIndex,
    required int start,
    required int end,
    required AppConfig config,
    required bool applyFilters,
  }) {
    final visible = _visibleChannelProjection(eeg, config);
    if (channelIndex < 0 || channelIndex >= visible.configs.length) {
      if (channelIndex >= 0 && channelIndex < eeg.channelSamples.length) {
        final channelCfg = _configForRawChannel(
          channelIndex,
          config,
          eeg.channelSamples.length,
        );
        return _displaySegmentForChannel(
          eeg.channelSamples,
          eeg.sampleRateHz,
          start,
          end,
          channelCfg,
          config,
          applyFilters: applyFilters,
        );
      }
      return const [];
    }
    final channelCfg = visible.configs[channelIndex];
    return _displaySegmentForChannel(
      eeg.channelSamples,
      eeg.sampleRateHz,
      start,
      end,
      channelCfg,
      config,
      applyFilters: applyFilters,
    );
  }

  // ─── Signal processing pipeline (runs after every file load) ──────────────

  /// Compute the full-night spectrogram, SWA, epoch periodograms, and TF norms.
  /// Morlet TF is intentionally computed per viewed epoch, not for the whole
  /// night at load time. Full-night TF precompute makes large EDF opens feel
  /// frozen and uses too much memory.
  Future<LoadedEeg> computeNightProducts(
    LoadedEeg raw,
    AppConfig config,
  ) async {
    if (raw.channelSamples.isEmpty) return raw;

    final srate = raw.sampleRateHz;
    const epochSeconds = 30;

    final spectConfigIndex = _clampConfigIndex(
      config.spectrogramChannelIndex,
      config,
    );
    final periodConfigIndex = _clampConfigIndex(
      config.periodogramChannelIndex,
      config,
    );
    final swaConfigIndex = _clampConfigIndex(config.swaChannelIndex, config);
    final spectSignal = _fullSignalForConfig(
      raw.channelSamples,
      srate,
      config,
      spectConfigIndex,
      applyFilters: true,
    );
    final periodSignal = _fullSignalForConfig(
      raw.channelSamples,
      srate,
      config,
      periodConfigIndex,
      applyFilters: true,
    );
    final swaSignal = swaConfigIndex == spectConfigIndex
        ? spectSignal
        : _fullSignalForConfig(
            raw.channelSamples,
            srate,
            config,
            swaConfigIndex,
            applyFilters: true,
          );
    final spectSource = _sourceIndexForConfig(
      _configAt(config, spectConfigIndex, raw.channelSamples.length),
      config,
      spectConfigIndex,
      raw.channelSamples.length,
    );

    // 1. Full-night Welch spectrogram
    final spectResult = await Isolate.run(
      () => _isolateComputeSpectrogram(spectSignal, srate, epochSeconds, 1),
    );
    final power = spectResult.power;
    final freqs = spectResult.freqs;

    // 2. SWA, optionally from a channel independent of the spectrogram.
    final swaSpectResult = swaConfigIndex == spectConfigIndex
        ? spectResult
        : await Isolate.run(
            () => _isolateComputeSpectrogram(swaSignal, srate, epochSeconds, 1),
          );
    final swa = sp.computeSwa(swaSpectResult.power, swaSpectResult.freqs);

    // 3. Per-epoch Welch periodograms (for RectanglePower panel)
    final periodResult = await Isolate.run(
      () => _isolateComputeSpectrogram(periodSignal, srate, epochSeconds, 0),
    );
    final periodograms = periodResult.power;

    // 4. TF frequency grid (linspace 0.25–45 Hz, 120 bins)
    final nyquist = srate / 2;
    final tfUpper = math.max(0.02, nyquist - 0.01);
    final tfLower = math.min(0.25, tfUpper / 2);
    final tfFreqMin = config.tfFreqMin.clamp(tfLower, tfUpper).toDouble();
    final tfFreqMax = config.tfFreqMax
        .clamp(tfFreqMin, math.max(tfFreqMin, tfUpper))
        .toDouble();
    final tfFreqs = config.tfFrequencyScale == 'Logarithmic'
        ? sp.geomspace(math.max(tfFreqMin, 0.1), tfFreqMax, 120)
        : sp.linspaceList(tfFreqMin, tfFreqMax, 120);

    // 5. TF normalisation stats (night-wide median + IQR per TF freq)
    final (:median, :iqr) = sp.computeTfNormStats(power, freqs, tfFreqs);

    final autoSpecLimits = computeSpectrogramAutoLimits(
      power,
      freqs,
      config.spectrogramFreqMin,
      config.spectrogramFreqMax,
    );
    if (config.spectrogramPowerMin == -1.0 && config.spectrogramPowerMax == 3.0) {
      config.spectrogramPowerMin = autoSpecLimits.min;
      config.spectrogramPowerMax = autoSpecLimits.max;
    }

    final spectrogramImage = await _spectrogramPowerToImage(
      power,
      freqs,
      config.spectrogramPowerMin,
      config.spectrogramPowerMax,
      config.spectrogramFreqMin,
      config.spectrogramFreqMax,
    );

    return LoadedEeg(
      sampleRateHz: raw.sampleRateHz,
      channelLabels: raw.channelLabels,
      channelSamples: raw.channelSamples,
      sourceDescription: raw.sourceDescription,
      spectrogramPower: power,
      spectrogramFreqs: freqs,
      swaPerEpoch: swa,
      epochPeriodograms: periodograms,
      epochTfPower: const [],
      tfFreqs: tfFreqs,
      tfNormMedian: median,
      tfNormIqr: iqr,
      spectrogramChannelIndex: spectSource >= 0 ? spectSource : 0,
      spectrogramImage: spectrogramImage,
      recordingStartTime: raw.recordingStartTime,
    );
  }
  // ─── Viewport construction ─────────────────────────────────────────────────

  Future<EegViewport> viewportFromEeg(
    LoadedEeg eeg, {
    required int currentEpoch,
    AppConfig? config,
    List<SleepStage>? existingStages,
    List<bool>? existingStagesUncertain,
    List<double?>? existingConfidence,
    List<Map<SleepStage, double>>? existingStageProbabilities,
    bool includeTimeFrequency = true,
  }) async {
    final cfg = config ?? AppConfig();
    const epochSeconds = 30;
    final totalDuration = eeg.durationSeconds;
    final epochCount = math.max(1, (totalDuration / epochSeconds).ceil());
    final safeEpoch = currentEpoch.clamp(0, epochCount - 1);
    final startSeconds = safeEpoch * epochSeconds.toDouble();

    // 5s contextual shading on both sides (40s total)
    final displayStartSec = startSeconds - 5.0;
    const displayDurationSec = 40.0;
    final visibleChannels = _visibleChannelProjection(eeg, cfg);

    // EEG display points (normalised 0..1 across the 40s window)
    final points = _displayPointsForEpoch(
      eeg.channelSamples,
      eeg.sampleRateHz,
      displayStartSec,
      displayDurationSec,
      cfg,
      visibleChannels.indices,
      visibleChannels.configs,
    );

    // Per-epoch data for this epoch
    final (periodogram, periodogramFreqs) = _epochPeriodogramWithFreqs(
      eeg,
      safeEpoch,
      cfg,
    );

    final tfCh = _tfSourceIndex(eeg, cfg);
    final tfPower = !includeTimeFrequency || !cfg.tfEnabled
        ? const <List<double>>[]
        : eeg.epochTfPower.isNotEmpty && safeEpoch < eeg.epochTfPower.length
        ? eeg.epochTfPower[safeEpoch]
        : await _timeFrequencyForEpoch(eeg, safeEpoch, cfg);
    final tfLimits = _effectiveTfPowerLimits(eeg, cfg, tfPower);

    ui.Image? tfImage;
    if (tfPower.isNotEmpty) {
      final imageKey = [
        identityHashCode(eeg),
        safeEpoch,
        tfCh,
        eeg.sampleRateHz.toStringAsFixed(3),
        eeg.tfFreqs.length,
        eeg.tfFreqs.first.toStringAsFixed(3),
        eeg.tfFreqs.last.toStringAsFixed(3),
        cfg.tfDisplayMode,
        cfg.tfFrequencyScale,
        tfLimits.min.toStringAsFixed(2),
        tfLimits.max.toStringAsFixed(2),
      ].join(':');

      tfImage = _tfImageCache[imageKey];
      if (tfImage == null) {
        tfImage = await _tfPowerToImage(tfPower, tfLimits.min, tfLimits.max);
        _rememberCacheValue(
          _tfImageCache,
          _tfImageCacheOrder,
          imageKey,
          tfImage,
          50,
        );
      }
    }

    final spectChCfg = _configAt(
      cfg,
      cfg.spectrogramChannelIndex,
      eeg.channelSamples.length,
    );
    final periodChCfg = _configAt(
      cfg,
      cfg.periodogramChannelIndex,
      eeg.channelSamples.length,
    );
    final tfChCfg = _configAt(
      cfg,
      cfg.tfChannelIndex,
      eeg.channelSamples.length,
    );

    return EegViewport(
      sampleRateHz: eeg.sampleRateHz,
      epochSeconds: epochSeconds,
      channelLabels: eeg.channelLabels,
      points: points,
      stages:
          existingStages ??
          [for (var i = 0; i < epochCount; i++) SleepStage.unknown],
      stagesUncertain:
          existingStagesUncertain ??
          [for (var i = 0; i < epochCount; i++) false],
      currentEpoch: safeEpoch,
      visibleStartSeconds: displayStartSec,
      visibleDurationSeconds: displayDurationSec,
      totalDurationSeconds: totalDuration,
      sourceDescription: eeg.sourceDescription,
      spectrogramFiltered: _hasDisplayFilter(spectChCfg),
      periodogramFiltered: _hasDisplayFilter(periodChCfg),
      tfFiltered: _hasDisplayFilter(tfChCfg),
      spectrogramPower: eeg.spectrogramPower,
      spectrogramFreqs: eeg.spectrogramFreqs,
      swaPerEpoch: eeg.swaPerEpoch,
      tfFreqs: eeg.tfFreqs,
      tfNormMedian: eeg.tfNormMedian,
      tfNormIqr: eeg.tfNormIqr,
      spectrogramChannelIndex: eeg.spectrogramChannelIndex,
      spectrogramChannelLabel: spectChCfg.name,
      spectrogramImage: eeg.spectrogramImage,
      currentEpochPeriodogram: periodogram,
      periodogramFreqs: periodogramFreqs,
      tfPower: tfPower,
      tfImage: tfImage,
      tfChannelIndex: cfg.tfChannelIndex,
      tfChannelLabel: tfChCfg.name,
      periodogramChannelIndex: cfg.periodogramChannelIndex,
      periodogramChannelLabel: periodChCfg.name,
      amplitudeRangeUv: cfg.amplitudeRangeUv,
      referenceAmplitudeLineUv: cfg.referenceAmplitudeLineUv,
      visibleChannelLabels: visibleChannels.labels,
      visibleChannelSourceIndices: visibleChannels.indices,
      visibleChannelColors: visibleChannels.colors,
      visibleChannelScales: visibleChannels.scales,
      tfDisplayMode: cfg.tfDisplayMode,
      tfPowerMin: tfLimits.min,
      tfPowerMax: tfLimits.max,
      periodogramFreqMin: cfg.periodogramFreqMin,
      periodogramFreqMax: cfg.periodogramFreqMax,
      periodogramDisplayMode: cfg.periodogramDisplayMode,
      spectrogramFreqMin: cfg.spectrogramFreqMin,
      spectrogramFreqMax: cfg.spectrogramFreqMax,
      spectrogramPowerMin: cfg.spectrogramPowerMin,
      spectrogramPowerMax: cfg.spectrogramPowerMax,
      spectrogramFlex: cfg.spectrogramFlex,
      hypnogramFlex: cfg.hypnogramFlex,
      periodogramFlex: cfg.periodogramFlex,
      showSwaPlot: cfg.showSwaPlot,
      hypnogramOverlayMode: cfg.hypnogramOverlayMode,
      hypnogramProbabilityStage: cfg.hypnogramProbabilityStage,
      eegPanelTimeUnit: cfg.eegPanelTimeUnit,
      lightsOffSeconds: cfg.lightsOffSeconds,
      lightsOnSeconds: cfg.lightsOnSeconds,
      referenceLineThickness: cfg.referenceLineThickness,
      referenceLineColor: cfg.referenceLineColor,
      hypnogramZoom: cfg.hypnogramZoom,
      stagesConfidence:
          existingConfidence ?? [for (var i = 0; i < epochCount; i++) null],
      stageProbabilities:
          existingStageProbabilities ?? const <Map<SleepStage, double>>[],
      recordingStartTime: eeg.recordingStartTime,
    );
  }

  Future<EegViewport> rebuildViewportForEpoch(
    EegViewport old,
    LoadedEeg eeg,
    int epoch, {
    AppConfig? config,
    bool includeTimeFrequency = true,
  }) async {
    final cfg = config ?? AppConfig();
    const epochSeconds = 30;
    final safeEpoch = epoch.clamp(0, old.epochCount - 1);
    final startSeconds = safeEpoch * epochSeconds.toDouble();

    final displayStartSec = startSeconds - 5.0;
    const displayDurationSec = 40.0;
    final visibleChannels = _visibleChannelProjection(eeg, cfg);

    final points = _displayPointsForEpoch(
      eeg.channelSamples,
      eeg.sampleRateHz,
      displayStartSec,
      displayDurationSec,
      cfg,
      visibleChannels.indices,
      visibleChannels.configs,
    );

    final (periodogram, periodogramFreqs) = _epochPeriodogramWithFreqs(
      eeg,
      safeEpoch,
      cfg,
    );

    final tfCh = _tfSourceIndex(eeg, cfg);
    List<List<double>> tfPower;
    if (!includeTimeFrequency || !cfg.tfEnabled) {
      tfPower = old.currentEpoch == safeEpoch ? old.tfPower : const [];
    } else if (eeg.epochTfPower.isNotEmpty &&
        safeEpoch < eeg.epochTfPower.length) {
      // O(1) pre-computed cache lookup — this is the fast path
      tfPower = eeg.epochTfPower[safeEpoch];
    } else {
      // Fallback: compute on demand (slow, only if pre-cache failed)
      tfPower = await _timeFrequencyForEpoch(eeg, safeEpoch, cfg);
    }
    final tfLimits = _effectiveTfPowerLimits(eeg, cfg, tfPower);

    ui.Image? tfImage;
    if (tfPower.isNotEmpty) {
      final imageKey = [
        identityHashCode(eeg),
        safeEpoch,
        tfCh,
        eeg.sampleRateHz.toStringAsFixed(3),
        eeg.tfFreqs.length,
        eeg.tfFreqs.first.toStringAsFixed(3),
        eeg.tfFreqs.last.toStringAsFixed(3),
        cfg.tfDisplayMode,
        cfg.tfFrequencyScale,
        tfLimits.min.toStringAsFixed(2),
        tfLimits.max.toStringAsFixed(2),
      ].join(':');

      tfImage = _tfImageCache[imageKey];
      if (tfImage == null) {
        tfImage = await _tfPowerToImage(tfPower, tfLimits.min, tfLimits.max);
        _rememberCacheValue(
          _tfImageCache,
          _tfImageCacheOrder,
          imageKey,
          tfImage,
          50,
        );
      }
    }

    final spectChCfg = _configAt(
      cfg,
      _clampConfigIndex(cfg.spectrogramChannelIndex, cfg),
      eeg.channelSamples.length,
    );
    final periodChCfg = _configAt(
      cfg,
      _clampConfigIndex(cfg.periodogramChannelIndex, cfg),
      eeg.channelSamples.length,
    );
    final tfChCfg = _configAt(
      cfg,
      _clampConfigIndex(cfg.tfChannelIndex, cfg),
      eeg.channelSamples.length,
    );

    return old.copyWith(
      currentEpoch: safeEpoch,
      points: points,
      visibleStartSeconds: displayStartSec,
      visibleDurationSeconds: displayDurationSec,
      currentEpochPeriodogram: periodogram,
      periodogramFreqs: periodogramFreqs,
      tfPower: tfPower,
      tfImage: tfImage,
      clearTfImage: tfImage == null,
      tfChannelIndex: tfCh,
      tfChannelLabel: tfChCfg.name,
      amplitudeRangeUv: cfg.amplitudeRangeUv,
      visibleChannelLabels: visibleChannels.labels,
      visibleChannelSourceIndices: visibleChannels.indices,
      visibleChannelColors: visibleChannels.colors,
      visibleChannelScales: visibleChannels.scales,
      clearSelection: true, // clear any selection when moving epoch
      clearEventSelections: old.currentEpoch != safeEpoch,
      tfDisplayMode: cfg.tfDisplayMode,
      tfPowerMin: tfLimits.min,
      tfPowerMax: tfLimits.max,
      periodogramFreqMin: cfg.periodogramFreqMin,
      periodogramFreqMax: cfg.periodogramFreqMax,
      periodogramDisplayMode: cfg.periodogramDisplayMode,
      spectrogramImage: eeg.spectrogramImage,
      spectrogramChannelIndex: eeg.spectrogramChannelIndex,
      spectrogramChannelLabel: spectChCfg.name,
      periodogramChannelLabel: periodChCfg.name,
      spectrogramFreqMin: cfg.spectrogramFreqMin,
      spectrogramFreqMax: cfg.spectrogramFreqMax,
      spectrogramPowerMin: cfg.spectrogramPowerMin,
      spectrogramPowerMax: cfg.spectrogramPowerMax,
      spectrogramFlex: cfg.spectrogramFlex,
      hypnogramFlex: cfg.hypnogramFlex,
      periodogramFlex: cfg.periodogramFlex,
      showSwaPlot: cfg.showSwaPlot,
      hypnogramOverlayMode: cfg.hypnogramOverlayMode,
      hypnogramProbabilityStage: cfg.hypnogramProbabilityStage,
      eegPanelTimeUnit: cfg.eegPanelTimeUnit,
      lightsOffSeconds: cfg.lightsOffSeconds,
      lightsOnSeconds: cfg.lightsOnSeconds,
      referenceLineThickness: cfg.referenceLineThickness,
      referenceLineColor: cfg.referenceLineColor,
      hypnogramZoom: cfg.hypnogramZoom,
    );
  }

  EegViewport rebuildViewportForEpochSync(
    EegViewport old,
    LoadedEeg eeg,
    int epoch, {
    AppConfig? config,
  }) {
    final cfg = config ?? AppConfig();
    const epochSeconds = 30;
    final safeEpoch = epoch.clamp(0, old.epochCount - 1);
    final startSeconds = safeEpoch * epochSeconds.toDouble();

    final displayStartSec = startSeconds - 5.0;
    const displayDurationSec = 40.0;
    final visibleChannels = _visibleChannelProjection(eeg, cfg);

    final points = _displayPointsForEpoch(
      eeg.channelSamples,
      eeg.sampleRateHz,
      displayStartSec,
      displayDurationSec,
      cfg,
      visibleChannels.indices,
      visibleChannels.configs,
    );

    final (periodogram, periodogramFreqs) = _epochPeriodogramWithFreqs(
      eeg,
      safeEpoch,
      cfg,
    );

    final tfCh = _tfSourceIndex(eeg, cfg);
    List<List<double>> tfPower;
    if (eeg.epochTfPower.isNotEmpty && safeEpoch < eeg.epochTfPower.length) {
      tfPower = eeg.epochTfPower[safeEpoch];
    } else {
      final tfConfigIndex = cfg.tfChannelIndex.clamp(
        0,
        eeg.channelSamples.length - 1,
      );
      final tfCfg = _configAt(cfg, tfConfigIndex, eeg.channelSamples.length);
      final cacheKey = [
        identityHashCode(eeg),
        safeEpoch,
        tfCh,
        eeg.sampleRateHz.toStringAsFixed(3),
        eeg.tfFreqs.length,
        eeg.tfFreqs.first.toStringAsFixed(3),
        eeg.tfFreqs.last.toStringAsFixed(3),
        cfg.tfDisplayMode,
        cfg.tfFrequencyScale,
        _channelConfigSignature(tfCfg),
      ].join(':');
      final cached = _tfCache[cacheKey];
      if (cached != null) {
        tfPower = cached;
      } else {
        tfPower = old.currentEpoch == safeEpoch ? old.tfPower : const [];
      }
    }
    final tfLimits = _effectiveTfPowerLimits(eeg, cfg, tfPower);

    ui.Image? tfImage;
    if (tfPower.isNotEmpty) {
      final imageKey = [
        identityHashCode(eeg),
        safeEpoch,
        tfCh,
        eeg.sampleRateHz.toStringAsFixed(3),
        eeg.tfFreqs.length,
        eeg.tfFreqs.first.toStringAsFixed(3),
        eeg.tfFreqs.last.toStringAsFixed(3),
        cfg.tfDisplayMode,
        cfg.tfFrequencyScale,
        tfLimits.min.toStringAsFixed(2),
        tfLimits.max.toStringAsFixed(2),
      ].join(':');
      tfImage =
          _tfImageCache[imageKey] ??
          (old.currentEpoch == safeEpoch ? old.tfImage : null);
    }

    final spectChCfg = _configAt(
      cfg,
      cfg.spectrogramChannelIndex,
      eeg.channelSamples.length,
    );
    final periodChCfg = _configAt(
      cfg,
      cfg.periodogramChannelIndex,
      eeg.channelSamples.length,
    );
    final tfChCfg = _configAt(
      cfg,
      cfg.tfChannelIndex,
      eeg.channelSamples.length,
    );

    return old.copyWith(
      currentEpoch: safeEpoch,
      points: points,
      visibleStartSeconds: displayStartSec,
      visibleDurationSeconds: displayDurationSec,
      currentEpochPeriodogram: periodogram,
      periodogramFreqs: periodogramFreqs,
      tfPower: tfPower,
      tfImage: tfImage,
      clearTfImage: tfImage == null,
      tfChannelIndex: tfCh,
      tfChannelLabel: tfChCfg.name,
      amplitudeRangeUv: cfg.amplitudeRangeUv,
      visibleChannelLabels: visibleChannels.labels,
      visibleChannelSourceIndices: visibleChannels.indices,
      visibleChannelColors: visibleChannels.colors,
      visibleChannelScales: visibleChannels.scales,
      clearSelection: true,
      clearEventSelections: old.currentEpoch != safeEpoch,
      tfDisplayMode: cfg.tfDisplayMode,
      tfPowerMin: tfLimits.min,
      tfPowerMax: tfLimits.max,
      periodogramFreqMin: cfg.periodogramFreqMin,
      periodogramFreqMax: cfg.periodogramFreqMax,
      periodogramDisplayMode: cfg.periodogramDisplayMode,
      spectrogramImage: eeg.spectrogramImage,
      spectrogramChannelIndex: eeg.spectrogramChannelIndex,
      spectrogramChannelLabel: spectChCfg.name,
      periodogramChannelLabel: periodChCfg.name,
      spectrogramFreqMin: cfg.spectrogramFreqMin,
      spectrogramFreqMax: cfg.spectrogramFreqMax,
      spectrogramPowerMin: cfg.spectrogramPowerMin,
      spectrogramPowerMax: cfg.spectrogramPowerMax,
      spectrogramFiltered: _hasDisplayFilter(spectChCfg),
      periodogramFiltered: _hasDisplayFilter(periodChCfg),
      tfFiltered: _hasDisplayFilter(tfChCfg),
      spectrogramFlex: cfg.spectrogramFlex,
      hypnogramFlex: cfg.hypnogramFlex,
      periodogramFlex: cfg.periodogramFlex,
      showSwaPlot: cfg.showSwaPlot,
      hypnogramOverlayMode: cfg.hypnogramOverlayMode,
      hypnogramProbabilityStage: cfg.hypnogramProbabilityStage,
      eegPanelTimeUnit: cfg.eegPanelTimeUnit,
      lightsOffSeconds: cfg.lightsOffSeconds,
      lightsOnSeconds: cfg.lightsOnSeconds,
      referenceLineThickness: cfg.referenceLineThickness,
      referenceLineColor: cfg.referenceLineColor,
      hypnogramZoom: cfg.hypnogramZoom,
    );
  }

  Future<EegViewport> refreshTimeFrequencyForEpoch(
    EegViewport old,
    LoadedEeg eeg, {
    AppConfig? config,
    bool Function()? isCancelled,
  }) async {
    final cfg = config ?? AppConfig();
    if (!cfg.tfEnabled) {
      return old.copyWith(
        tfPower: const [],
        tfChannelIndex: _tfSourceIndex(eeg, cfg),
        tfChannelLabel: _configAt(
          cfg,
          _clampConfigIndex(cfg.tfChannelIndex, cfg),
          eeg.channelSamples.length,
        ).name,
        tfDisplayMode: cfg.tfDisplayMode,
        tfPowerMin: cfg.tfPowerMin,
        tfPowerMax: cfg.tfPowerMax,
        clearTfImage: true,
        spectrogramImage: eeg.spectrogramImage,
        spectrogramFlex: cfg.spectrogramFlex,
        hypnogramFlex: cfg.hypnogramFlex,
        periodogramFlex: cfg.periodogramFlex,
        showSwaPlot: cfg.showSwaPlot,
        hypnogramOverlayMode: cfg.hypnogramOverlayMode,
        hypnogramProbabilityStage: cfg.hypnogramProbabilityStage,
        eegPanelTimeUnit: cfg.eegPanelTimeUnit,
        lightsOffSeconds: cfg.lightsOffSeconds,
        lightsOnSeconds: cfg.lightsOnSeconds,
        referenceLineThickness: cfg.referenceLineThickness,
        referenceLineColor: cfg.referenceLineColor,
        hypnogramZoom: cfg.hypnogramZoom,
      );
    }
    final tfCh = _tfSourceIndex(eeg, cfg);
    final tfPower =
        eeg.epochTfPower.isNotEmpty &&
            old.currentEpoch < eeg.epochTfPower.length
        ? eeg.epochTfPower[old.currentEpoch]
        : await _timeFrequencyForEpoch(
            eeg,
            old.currentEpoch,
            cfg,
            isCancelled: isCancelled,
          );
    final tfLimits = _effectiveTfPowerLimits(eeg, cfg, tfPower);

    ui.Image? tfImage;
    if (tfPower.isNotEmpty) {
      final imageKey = [
        identityHashCode(eeg),
        old.currentEpoch,
        tfCh,
        eeg.sampleRateHz.toStringAsFixed(3),
        eeg.tfFreqs.length,
        eeg.tfFreqs.first.toStringAsFixed(3),
        eeg.tfFreqs.last.toStringAsFixed(3),
        cfg.tfDisplayMode,
        cfg.tfFrequencyScale,
        tfLimits.min.toStringAsFixed(2),
        tfLimits.max.toStringAsFixed(2),
      ].join(':');

      tfImage = _tfImageCache[imageKey];
      if (tfImage == null) {
        tfImage = await _tfPowerToImage(tfPower, tfLimits.min, tfLimits.max);
        _rememberCacheValue(
          _tfImageCache,
          _tfImageCacheOrder,
          imageKey,
          tfImage,
          50,
        );
      }
    }

    return old.copyWith(
      tfPower: tfPower,
      tfImage: tfImage,
      clearTfImage: tfImage == null,
      tfChannelIndex: tfCh,
      tfChannelLabel: _configAt(
        cfg,
        _clampConfigIndex(cfg.tfChannelIndex, cfg),
        eeg.channelSamples.length,
      ).name,
      tfDisplayMode: cfg.tfDisplayMode,
      tfPowerMin: tfLimits.min,
      tfPowerMax: tfLimits.max,
      spectrogramImage: eeg.spectrogramImage,
      spectrogramChannelIndex: eeg.spectrogramChannelIndex,
      spectrogramChannelLabel: _configAt(
        cfg,
        _clampConfigIndex(cfg.spectrogramChannelIndex, cfg),
        eeg.channelSamples.length,
      ).name,
      spectrogramFreqMin: cfg.spectrogramFreqMin,
      spectrogramFreqMax: cfg.spectrogramFreqMax,
      spectrogramPowerMin: cfg.spectrogramPowerMin,
      spectrogramPowerMax: cfg.spectrogramPowerMax,
      spectrogramFlex: cfg.spectrogramFlex,
      hypnogramFlex: cfg.hypnogramFlex,
      periodogramFlex: cfg.periodogramFlex,
      showSwaPlot: cfg.showSwaPlot,
      hypnogramOverlayMode: cfg.hypnogramOverlayMode,
      hypnogramProbabilityStage: cfg.hypnogramProbabilityStage,
      eegPanelTimeUnit: cfg.eegPanelTimeUnit,
      lightsOffSeconds: cfg.lightsOffSeconds,
      lightsOnSeconds: cfg.lightsOnSeconds,
      referenceLineThickness: cfg.referenceLineThickness,
      referenceLineColor: cfg.referenceLineColor,
      hypnogramZoom: cfg.hypnogramZoom,
    );
  }

  // ─── Selection updating ───────────────────────────────────────────────────

  Future<EegViewport> updateSelection(
    EegViewport old,
    LoadedEeg eeg,
    double? startSec,
    double? endSec, {
    int? channel,
    double? startUv,
    double? endUv,
    AppConfig? config,
  }) async {
    final cfg = config ?? AppConfig();

    if (startSec == null || endSec == null || channel == null) {
      final (periodogram, freqs) = _epochPeriodogramWithFreqs(
        eeg,
        old.currentEpoch,
        cfg,
      );
      return old.copyWith(
        currentEpochPeriodogram: periodogram,
        periodogramFreqs: freqs,
        clearSelection: true,
      );
    }

    final srate = eeg.sampleRateHz;
    final signalChannelIndices = old.signalChannelSourceIndices;
    final chIdx = channel >= 0 && channel < signalChannelIndices.length
        ? signalChannelIndices[channel]
              .clamp(0, eeg.channelSamples.length - 1)
              .toInt()
        : channel.clamp(0, eeg.channelSamples.length - 1).toInt();
    final visibleLabels = old.signalChannelLabels;
    final selectedLabel = channel >= 0 && channel < visibleLabels.length
        ? visibleLabels[channel]
        : null;
    final configIndex = selectedLabel == null
        ? -1
        : cfg.channels.indexWhere((c) => c.name == selectedLabel);
    final selectedConfig = configIndex >= 0
        ? cfg.channels[configIndex]
        : _configForRawChannel(chIdx, cfg, eeg.channelSamples.length);
    final signal = eeg.channelSamples[chIdx];

    final isClick =
        (endSec - startSec).abs() < 0.1 &&
        startUv != null &&
        endUv != null &&
        (endUv - startUv).abs() < 2.0;

    if (isClick) {
      // 1. Check if click falls inside an existing selection box
      EventSelection? clickedSelection;
      for (final sel in old.eventSelections) {
        if (sel.channel == channel) {
          final tMin = math.min(sel.startSec, sel.endSec);
          final tMax = math.max(sel.startSec, sel.endSec);
          final uvMin = math.min(sel.startUv, sel.endUv);
          final uvMax = math.max(sel.startUv, sel.endUv);
          if (startSec >= tMin &&
              startSec <= tMax &&
              startUv >= uvMin &&
              startUv <= uvMax) {
            clickedSelection = sel;
            break;
          }
        }
      }

      if (clickedSelection != null) {
        final newSelections = old.eventSelections
            .where((s) => s != clickedSelection)
            .toList();
        if (newSelections.isNotEmpty) {
          final lastSel = newSelections.last;
          final lastCh = lastSel.channel;
          final lastChIdx = lastCh >= 0 && lastCh < signalChannelIndices.length
              ? signalChannelIndices[lastCh]
                    .clamp(0, eeg.channelSamples.length - 1)
                    .toInt()
              : lastCh.clamp(0, eeg.channelSamples.length - 1).toInt();
          final lastSignal = eeg.channelSamples[lastChIdx];
          final lastLabel = lastCh >= 0 && lastCh < visibleLabels.length
              ? visibleLabels[lastCh]
              : null;
          final lastCfgIndex = lastLabel == null
              ? -1
              : cfg.channels.indexWhere((c) => c.name == lastLabel);
          final lastCfg = lastCfgIndex >= 0
              ? cfg.channels[lastCfgIndex]
              : _configForRawChannel(lastChIdx, cfg, eeg.channelSamples.length);

          final ls1 = (lastSel.startSec * srate).round().clamp(
            0,
            lastSignal.length,
          );
          final ls2 = (lastSel.endSec * srate).round().clamp(
            0,
            lastSignal.length,
          );
          final lStart = math.min(ls1, ls2);
          final lEnd = math.max(ls1, ls2);
          if (lEnd - lStart >= 4) {
            final slice = _displaySegmentForChannel(
              eeg.channelSamples,
              srate,
              lStart,
              lEnd,
              lastCfg,
              cfg,
              applyFilters: true,
            );
            if (slice.length >= 4) {
              final (psd, freqs) = sp.welchPsd(slice, srate);
              return old.copyWith(
                eventSelections: newSelections,
                currentEpochPeriodogram: psd,
                periodogramFreqs: freqs,
                periodogramChannelIndex: lastChIdx,
                selectionStartSec: lastSel.startSec,
                selectionEndSec: lastSel.endSec,
                selectionChannel: lastSel.channel,
                selectionStartUv: lastSel.startUv,
                selectionEndUv: lastSel.endUv,
                selectionPeakToPeakUv: lastSel.peakToPeakUv,
              );
            }
          }
        }

        final (periodogram, freqs) = _epochPeriodogramWithFreqs(
          eeg,
          old.currentEpoch,
          cfg,
        );
        return old.copyWith(
          eventSelections: newSelections,
          currentEpochPeriodogram: periodogram,
          periodogramFreqs: freqs,
          clearSelection: true,
        );
      }

      // 2. Check if click falls inside a marked event
      ScoredEvent? clickedEvent;
      for (final ev in old.scoredEvents) {
        final tMin = math.min(ev.startSec, ev.endSec);
        final tMax = math.max(ev.startSec, ev.endSec);
        if (startSec >= tMin && startSec <= tMax) {
          clickedEvent = ev;
          break;
        }
      }

      if (clickedEvent != null) {
        final newEvents = old.scoredEvents
            .where((e) => e != clickedEvent)
            .toList();
        return old.copyWith(scoredEvents: newEvents);
      }

      // 3. Otherwise, click outside -> clear all selections!
      final (periodogram, freqs) = _epochPeriodogramWithFreqs(
        eeg,
        old.currentEpoch,
        cfg,
      );
      return old.copyWith(
        eventSelections: const [],
        currentEpochPeriodogram: periodogram,
        periodogramFreqs: freqs,
        clearSelection: true,
      );
    }

    final s1 = (startSec * srate).round().clamp(0, signal.length);
    final s2 = (endSec * srate).round().clamp(0, signal.length);
    final startSamp = math.min(s1, s2);
    final endSamp = math.max(s1, s2);

    if (endSamp - startSamp < 4) return old;

    final slice = _displaySegmentForChannel(
      eeg.channelSamples,
      srate,
      startSamp,
      endSamp,
      selectedConfig,
      cfg,
      applyFilters: true,
    );
    if (slice.length < 4) return old;

    // We can do this synchronously since it's just a subset of an epoch
    final (psd, freqs) = sp.welchPsd(slice, srate);

    // Calculate peak-to-peak amplitude
    double minVal = slice[0];
    double maxVal = slice[0];
    for (var i = 1; i < slice.length; i++) {
      final v = slice[i];
      if (v < minVal) minVal = v;
      if (v > maxVal) maxVal = v;
    }
    final peakToPeak = maxVal - minVal;

    final selection = EventSelection(
      startSec: startSec,
      endSec: endSec,
      channel: channel,
      startUv: startUv ?? 0.0,
      endUv: endUv ?? 0.0,
      peakToPeakUv: peakToPeak,
    );

    return old.copyWith(
      selectionStartSec: startSec,
      selectionEndSec: endSec,
      selectionChannel: channel,
      selectionStartUv: startUv,
      selectionEndUv: endUv,
      selectionPeakToPeakUv: peakToPeak,
      eventSelections: [...old.eventSelections, selection],
      currentEpochPeriodogram: psd,
      periodogramFreqs: freqs,
      periodogramChannelIndex: chIdx,
    );
  }

  // ─── Display points generation ────────────────────────────────────────────────────────

  (List<double>, List<double>) _epochPeriodogramWithFreqs(
    LoadedEeg eeg,
    int epoch,
    AppConfig cfg,
  ) {
    final periodConfigIndex = _clampConfigIndex(
      cfg.periodogramChannelIndex,
      cfg,
    );
    final periodCfg = _configAt(
      cfg,
      periodConfigIndex,
      eeg.channelSamples.length,
    );
    final hasFilters = _hasDisplayFilter(periodCfg);

    // If display filters are active on the periodogram channel, recompute
    // the PSD from the filtered signal so the periodogram matches the display.
    if (!hasFilters &&
        eeg.epochPeriodograms.isNotEmpty &&
        epoch < eeg.epochPeriodograms.length) {
      // Use pre-computed (unfiltered) periodograms
      final freqs = eeg.spectrogramFreqs;
      final psd = eeg.epochPeriodograms[epoch];
      final minFreq = math.max(0.0, cfg.periodogramFreqMin);
      final maxFreq = math.min(cfg.periodogramFreqMax, eeg.sampleRateHz / 2);
      final filteredPsd = <double>[];
      final filteredFreqs = <double>[];
      for (var i = 0; i < freqs.length && i < psd.length; i++) {
        if (freqs[i] >= minFreq && freqs[i] <= maxFreq) {
          filteredFreqs.add(freqs[i]);
          filteredPsd.add(psd[i]);
        }
      }
      return (filteredPsd, filteredFreqs);
    }

    // Compute from (optionally filtered) signal
    const epochSeconds = 30;
    final srate = eeg.sampleRateHz;
    final start = epoch * (epochSeconds * srate).round();
    final end = math.min(
      eeg.channelSamples.isNotEmpty ? eeg.channelSamples.first.length : 0,
      start + (epochSeconds * srate).round(),
    );
    if (start >= end) return ([], []);

    final segment = _displaySegmentForChannel(
      eeg.channelSamples,
      srate,
      start,
      end,
      periodCfg,
      cfg,
      applyFilters: hasFilters,
    );
    if (segment.length < 4) return ([], []);

    final (psd, freqs) = sp.welchPsd(segment, srate);
    final minFreq = math.max(0.0, cfg.periodogramFreqMin);
    final maxFreq = math.min(cfg.periodogramFreqMax, srate / 2);
    final filteredPsd = <double>[];
    final filteredFreqs = <double>[];
    for (var i = 0; i < freqs.length && i < psd.length; i++) {
      if (freqs[i] >= minFreq && freqs[i] <= maxFreq) {
        filteredFreqs.add(freqs[i]);
        filteredPsd.add(psd[i]);
      }
    }
    return (filteredPsd, filteredFreqs);
  }

  /// Compute Morlet TF power for one epoch. Returns z-scored log10 power
  /// shape: List<List<double>> (nFreqs × nSamples).
  // Removed instance _computeEpochTf, now using top-level _isolateComputeMorletTf

  // ─── EEG display point generation ─────────────────────────────────────────

  List<Float32List> _displayPointsForEpoch(
    List<List<double>> channels,
    double sampleRate,
    double startSeconds,
    double durationSeconds,
    AppConfig cfg,
    List<int> visibleIndices,
    List<ChannelConfig> visibleConfigs,
  ) {
    final cacheKey = [
      identityHashCode(channels),
      sampleRate.toStringAsFixed(3),
      startSeconds.toStringAsFixed(3),
      durationSeconds.toStringAsFixed(3),
      cfg.amplitudeRangeUv.toStringAsFixed(3),
      visibleIndices.join(','),
      cfg.stackChannels,
      cfg.robustZStandardize,
      for (final ch in visibleConfigs) _channelConfigSignature(ch),
    ].join(':');
    final cached = _displayPointCache[cacheKey];
    if (cached != null) {
      _touchCacheKey(_displayPointCacheOrder, cacheKey);
      return cached;
    }

    final waves = <Float32List>[];
    if (channels.isEmpty || sampleRate <= 0) return waves;

    final rawStart = (startSeconds * sampleRate).floor();
    final start = math.max(0, rawStart);
    final end = math.min(
      channels.first.length,
      ((startSeconds + durationSeconds) * sampleRate).ceil(),
    );
    final count = math.max(0, end - start);
    if (count == 0) return waves;

    final displayIndices = visibleIndices.isEmpty
        ? [for (var i = 0; i < channels.length; i++) i]
        : visibleIndices.where((i) => i >= 0 && i < channels.length).toList();
    if (displayIndices.isEmpty) return waves;
    final channelHeight = 1.0 / displayIndices.length;

    for (
      var displayIndex = 0;
      displayIndex < displayIndices.length;
      displayIndex++
    ) {
      final channel = displayIndices[displayIndex];
      final channelCfg = displayIndex < visibleConfigs.length
          ? visibleConfigs[displayIndex]
          : _configForRawChannel(channel, cfg, channels.length);
      final sourceSamples = channels[channel];
      final safeEnd = math.min(end, sourceSamples.length);
      final segment = _displaySegmentForChannel(
        channels,
        sampleRate,
        start,
        safeEnd,
        channelCfg,
        cfg,
        applyFilters: true,
      );
      if (segment.isEmpty) {
        waves.add(Float32List(0));
        continue;
      }

      var displayData = segment;
      const targetPoints = 3000;
      if (segment.length > targetPoints) {
        displayData = _minMaxDownsample(segment, targetPoints);
      }

      double sum = 0.0;
      var meanCount = 0;
      for (var i = 0; i < displayData.length; i += 32) {
        sum += displayData[i];
        meanCount++;
      }
      final mean = meanCount > 0 ? sum / meanCount : 0.0;

      final maxAbs = math.max(cfg.amplitudeRangeUv, 1e-6);
      final baseline = cfg.stackChannels
          ? 0.5
          : channelHeight * (displayIndex + 0.5);
      final scale = channelCfg.scalingFactor / 100.0;
      final shift = channelCfg.verticalShift;
      final robustStats = cfg.robustZStandardize
          ? _robustStats(displayData, 0, displayData.length)
          : null;

      final yValues = Float32List(displayData.length);
      for (var sample = 0; sample < displayData.length; sample++) {
        final rawValue = robustStats == null
            ? displayData[sample] - mean
            : ((displayData[sample] - robustStats.median) / robustStats.iqr) *
                  cfg.referenceAmplitudeLineUv;
        final sampleUv = (rawValue * scale) + shift;
        final normalized = sampleUv / maxAbs;
        yValues[sample] = baseline - normalized * channelHeight * 0.42;
      }
      waves.add(yValues);
    }
    _rememberCacheValue(
      _displayPointCache,
      _displayPointCacheOrder,
      cacheKey,
      waves,
      15,
    );
    return waves;
  }

  List<double> _minMaxDownsample(List<double> data, int targetPoints) {
    final count = data.length;
    if (count <= targetPoints) {
      return data;
    }
    final numBins = targetPoints ~/ 2;
    if (numBins <= 0) return data;
    final binSize = count / numBins;
    final result = List<double>.filled(numBins * 2, 0.0);
    var writeIdx = 0;

    for (var bin = 0; bin < numBins; bin++) {
      final startIdx = (bin * binSize).round();
      var endIdx = ((bin + 1) * binSize).round();
      if (endIdx > count) endIdx = count;
      if (startIdx >= endIdx) continue;

      var minVal = data[startIdx];
      var maxVal = data[startIdx];
      var minPos = startIdx;
      var maxPos = startIdx;

      for (var i = startIdx + 1; i < endIdx; i++) {
        final val = data[i];
        if (val < minVal) {
          minVal = val;
          minPos = i;
        }
        if (val > maxVal) {
          maxVal = val;
          maxPos = i;
        }
      }

      if (minPos < maxPos) {
        result[writeIdx++] = minVal;
        result[writeIdx++] = maxVal;
      } else {
        result[writeIdx++] = maxVal;
        result[writeIdx++] = minVal;
      }
    }

    if (writeIdx < result.length) {
      return result.sublist(0, writeIdx);
    }
    return result;
  }

  int _clampConfigIndex(int index, AppConfig cfg) {
    if (cfg.channels.isEmpty) return math.max(0, index);
    return index.clamp(0, cfg.channels.length - 1).toInt();
  }

  ChannelConfig _configAt(AppConfig cfg, int index, int channelCount) {
    if (index >= 0 && index < cfg.channels.length) return cfg.channels[index];
    return ChannelConfig(
      name: 'Channel ${index + 1}',
      sourceIndex: index.clamp(0, math.max(0, channelCount - 1)).toInt(),
    );
  }

  int _tfSourceIndex(LoadedEeg eeg, AppConfig cfg) {
    if (eeg.channelSamples.isEmpty) return 0;
    final tfConfigIndex = _clampConfigIndex(cfg.tfChannelIndex, cfg);
    final tfCfg = _configAt(cfg, tfConfigIndex, eeg.channelSamples.length);
    final source = _sourceIndexForConfig(
      tfCfg,
      cfg,
      tfConfigIndex,
      eeg.channelSamples.length,
    );
    return source >= 0 ? source : 0;
  }

  List<double> _fullSignalForConfig(
    List<List<double>> channels,
    double sampleRate,
    AppConfig cfg,
    int configIndex, {
    bool applyFilters = false,
  }) {
    if (channels.isEmpty) return const [];
    final channelCfg = _configAt(cfg, configIndex, channels.length);
    final sourceIdx = _sourceIndexForConfig(
      channelCfg,
      cfg,
      configIndex,
      channels.length,
    );
    if (sourceIdx < 0 || sourceIdx >= channels.length) return const [];
    final refIdx = _referenceIndexForConfig(channelCfg, cfg, channels.length);
    if (refIdx == null && !channelCfg.flipPolarity && !applyFilters) {
      return channels[sourceIdx];
    }
    return _displaySegmentForChannel(
      channels,
      sampleRate,
      0,
      channels[sourceIdx].length,
      channelCfg,
      cfg,
      applyFilters: applyFilters,
    );
  }

  ({
    List<int> indices,
    List<String> labels,
    List<String> colors,
    List<double> scales,
    List<ChannelConfig> configs,
  })
  _visibleChannelProjection(LoadedEeg eeg, AppConfig cfg) {
    final indices = <int>[];
    final labels = <String>[];
    final colors = <String>[];
    final scales = <double>[];
    final configs = <ChannelConfig>[];
    final channelConfigs = cfg.channels.isEmpty
        ? [
            for (var i = 0; i < eeg.channelSamples.length; i++)
              AppConfig._defaultChannelConfig(
                eeg.channelLabels[i],
                i,
                eeg.channelSamples.length,
              ),
          ]
        : cfg.channels;

    for (var i = 0; i < channelConfigs.length; i++) {
      final channelCfg = channelConfigs[i];
      if (!channelCfg.displayOnScreen) continue;
      final sourceIdx = _sourceIndexForConfig(
        channelCfg,
        cfg,
        i,
        eeg.channelSamples.length,
      );
      if (sourceIdx < 0 || sourceIdx >= eeg.channelSamples.length) continue;
      indices.add(sourceIdx);
      labels.add(
        channelCfg.name.isNotEmpty
            ? channelCfg.name
            : eeg.channelLabels[sourceIdx],
      );
      colors.add(
        channelCfg.color.isNotEmpty
            ? channelCfg.color
            : _defaultChannelColorName(eeg.channelLabels[sourceIdx]),
      );
      scales.add(channelCfg.scalingFactor);
      configs.add(channelCfg);
    }
    if (indices.isEmpty && eeg.channelSamples.isNotEmpty) {
      final fallback = channelConfigs.isNotEmpty
          ? channelConfigs.first
          : AppConfig._defaultChannelConfig(
              eeg.channelLabels.first,
              0,
              eeg.channelSamples.length,
            );
      indices.add(0);
      labels.add(
        fallback.name.isNotEmpty ? fallback.name : eeg.channelLabels.first,
      );
      colors.add(fallback.color);
      scales.add(fallback.scalingFactor);
      configs.add(fallback);
    }
    return (
      indices: indices,
      labels: labels,
      colors: colors,
      scales: scales,
      configs: configs,
    );
  }

  ChannelConfig _configForRawChannel(
    int rawIndex,
    AppConfig cfg,
    int channelCount,
  ) {
    for (final channel in cfg.channels) {
      if (channel.sourceIndex == rawIndex) return channel;
    }
    if (rawIndex >= 0 && rawIndex < cfg.channels.length) {
      return cfg.channels[rawIndex];
    }
    return ChannelConfig(
      name: 'Channel ${rawIndex + 1}',
      sourceIndex: rawIndex.clamp(0, math.max(0, channelCount - 1)).toInt(),
    );
  }

  int _sourceIndexForConfig(
    ChannelConfig channelCfg,
    AppConfig cfg,
    int fallbackIndex,
    int channelCount,
  ) {
    final explicit = channelCfg.sourceIndex;
    if (explicit != null && explicit >= 0 && explicit < channelCount) {
      return explicit;
    }
    final sourceName = channelCfg.derived
        ? (channelCfg.sourceChannel ?? channelCfg.name)
        : channelCfg.name;
    final byName = cfg.channels.indexWhere((c) => c.name == sourceName);
    if (byName >= 0) {
      final mapped = cfg.channels[byName].sourceIndex;
      if (mapped != null && mapped >= 0 && mapped < channelCount) return mapped;
      if (byName < channelCount) return byName;
    }
    return fallbackIndex < channelCount ? fallbackIndex : -1;
  }

  int? _referenceIndexForConfig(
    ChannelConfig channelCfg,
    AppConfig cfg,
    int channelCount,
  ) {
    final refName = channelCfg.reReference;
    if (refName == 'None' || refName.isEmpty) return null;
    final refConfigIndex = cfg.channels.indexWhere((c) => c.name == refName);
    if (refConfigIndex < 0) return null;
    final refCfg = cfg.channels[refConfigIndex];
    final sourceIdx = _sourceIndexForConfig(
      refCfg,
      cfg,
      refConfigIndex,
      channelCount,
    );
    return sourceIdx >= 0 && sourceIdx < channelCount ? sourceIdx : null;
  }

  String _channelConfigSignature(ChannelConfig c) {
    return [
      c.name,
      c.sourceIndex,
      c.derived,
      c.sourceChannel,
      c.color,
      c.scalingFactor.toStringAsFixed(2),
      c.verticalShift.toStringAsFixed(2),
      c.flipPolarity,
      c.displayOnScreen,
      c.reReference,
      c.filterHpEnabled,
      c.filterHpCutoff.toStringAsFixed(2),
      c.filterHpOrder,
      c.filterLpEnabled,
      c.filterLpCutoff.toStringAsFixed(2),
      c.filterLpOrder,
      c.filterNotchEnabled,
      c.filterNotchCutoff.toStringAsFixed(2),
      c.filterNotchOrder,
    ].join(',');
  }

  List<double> _displaySegmentForChannel(
    List<List<double>> channels,
    double sampleRate,
    int start,
    int end,
    ChannelConfig channelCfg,
    AppConfig cfg, {
    required bool applyFilters,
  }) {
    if (channels.isEmpty || start >= end) return const [];
    final sourceIdx = _sourceIndexForConfig(
      channelCfg,
      cfg,
      channelCfg.sourceIndex ?? 0,
      channels.length,
    );
    if (sourceIdx < 0 || sourceIdx >= channels.length) return const [];
    final source = channels[sourceIdx];
    final safeEnd = math.min(end, source.length);
    if (start >= safeEnd) return const [];
    final refIdx = _referenceIndexForConfig(channelCfg, cfg, channels.length);
    final ref = refIdx == null ? null : channels[refIdx];
    final segment = List<double>.generate(safeEnd - start, (offset) {
      final idx = start + offset;
      var value = source[idx];
      if (ref != null && idx < ref.length) {
        value -= ref[idx];
      }
      if (channelCfg.flipPolarity) value = -value;
      return value;
    }, growable: false);
    if (!applyFilters || !_hasDisplayFilter(channelCfg)) return segment;
    return _applyDisplayFilters(segment, sampleRate, channelCfg);
  }

  bool _hasDisplayFilter(ChannelConfig cfg) {
    return cfg.filterHpEnabled ||
        cfg.filterLpEnabled ||
        cfg.filterNotchEnabled ||
        cfg.flipPolarity ||
        (cfg.reReference != 'None' && cfg.reReference.isNotEmpty);
  }

  List<double> _applyDisplayFilters(
    List<double> signal,
    double sampleRate,
    ChannelConfig cfg,
  ) {
    if (signal.length < 8 || sampleRate <= 0) return signal;
    final nyquist = sampleRate / 2.0;

    final List<sp.BiquadSection> sos = [];

    if (cfg.filterHpEnabled &&
        cfg.filterHpCutoff > 0.01 &&
        cfg.filterHpCutoff < nyquist - 0.1) {
      final cutoff = cfg.filterHpCutoff.clamp(0.05, nyquist - 0.5);
      sos.addAll(
        sp.designCheby2SOS(
          order: cfg.filterHpOrder,
          rs: 60.0,
          cutoff: cutoff,
          sampleRate: sampleRate,
          btype: 'highpass',
        ),
      );
    }

    if (cfg.filterLpEnabled &&
        cfg.filterLpCutoff > 0.1 &&
        cfg.filterLpCutoff < nyquist) {
      final cutoff = cfg.filterLpCutoff.clamp(0.1, nyquist - 0.5);
      sos.addAll(
        sp.designCheby2SOS(
          order: cfg.filterLpOrder,
          rs: 60.0,
          cutoff: cutoff,
          sampleRate: sampleRate,
          btype: 'lowpass',
        ),
      );
    }

    if (cfg.filterNotchEnabled &&
        cfg.filterNotchCutoff > 1.0 &&
        cfg.filterNotchCutoff < nyquist - 1.0) {
      final cutoff = cfg.filterNotchCutoff.clamp(1.0, nyquist - 1.0);
      sos.addAll(
        sp.designCheby2SOS(
          order: cfg.filterNotchOrder,
          rs: 60.0,
          cutoff: cutoff,
          sampleRate: sampleRate,
          btype: 'bandstop',
        ),
      );
    }

    if (sos.isEmpty) return signal;
    return _applyZeroPhaseSOS(signal, sos);
  }

  List<double> _applyZeroPhaseSOS(
    List<double> input,
    List<sp.BiquadSection> sos,
  ) {
    if (input.length < 4) return List<double>.from(input);

    // Reflection-pad the signal to suppress edge transients,
    // mirroring scipy.signal.filtfilt's approach.
    // padLen = 3 × number_of_sos_sections (matches 3·order heuristic).
    final padLen = math.min(input.length - 1, sos.length * 3);
    final padded = List<double>.filled(input.length + 2 * padLen, 0.0);

    // Reflect-pad the start: mirror the first padLen samples around input[0]
    final firstVal = input.first;
    for (var i = 0; i < padLen; i++) {
      padded[padLen - 1 - i] = 2.0 * firstVal - input[i + 1];
    }
    // Copy original signal
    for (var i = 0; i < input.length; i++) {
      padded[padLen + i] = input[i];
    }
    // Reflect-pad the end: mirror the last padLen samples around input[last]
    final lastVal = input.last;
    final n = input.length;
    for (var i = 0; i < padLen; i++) {
      padded[padLen + n + i] = 2.0 * lastVal - input[n - 2 - i];
    }

    // Forward pass
    var output = padded;
    for (final section in sos) {
      if (!section.b0.isFinite ||
          !section.b1.isFinite ||
          !section.b2.isFinite ||
          !section.a1.isFinite ||
          !section.a2.isFinite) {
        return List<double>.from(input);
      }
      output = _applyBiquadSection(output, section);
    }
    // Reverse pass (zero-phase)
    output = output.reversed.toList(growable: false);
    for (final section in sos) {
      output = _applyBiquadSection(output, section);
    }
    output = output.reversed.toList(growable: false);

    // Trim padding — return only the original-length segment
    final result = output.sublist(padLen, padLen + input.length);
    for (final x in result) {
      if (!x.isFinite) {
        return List<double>.from(input);
      }
    }
    return result;
  }

  List<double> _applyBiquadSection(List<double> input, sp.BiquadSection c) {
    final out = List<double>.filled(input.length, 0.0, growable: false);
    final x0 = input.first;
    final num = c.b0 + c.b1 + c.b2;
    final den = 1.0 + c.a1 + c.a2;
    final G = den.abs() > 1e-12 ? (num / den) : 0.0;

    double s1 = (G - c.b0) * x0;
    double s2 = (c.b2 - c.a2 * G) * x0;

    for (var i = 0; i < input.length; i++) {
      final x = input[i];
      final y = c.b0 * x + s1;
      out[i] = y;
      s1 = c.b1 * x - c.a1 * y + s2;
      s2 = c.b2 * x - c.a2 * y;
    }
    return out;
  }

  ({double median, double iqr}) _robustStats(
    List<double> values,
    int start,
    int end,
  ) {
    if (start >= end) return (median: 0.0, iqr: 1.0);
    final sampled = <double>[];
    final step = math.max(1, ((end - start) / 512).floor());
    for (var i = start; i < end; i += step) {
      sampled.add(values[i]);
    }
    sampled.sort();
    final q1 =
        sampled[(sampled.length * 0.25).floor().clamp(0, sampled.length - 1)];
    final med =
        sampled[(sampled.length * 0.50).floor().clamp(0, sampled.length - 1)];
    final q3 =
        sampled[(sampled.length * 0.75).floor().clamp(0, sampled.length - 1)];
    final iqr = math.max(q3 - q1, 1e-6);
    return (median: med, iqr: iqr);
  }

  String _defaultChannelColorName(String label) {
    final upper = label.toUpperCase();
    if (upper.contains('EOG')) return 'Blue';
    if (upper.contains('ECG')) return 'Magenta';
    if (upper.contains('EMG')) return 'Orange';
    return 'Black';
  }

  Future<List<List<double>>> _timeFrequencyForEpoch(
    LoadedEeg eeg,
    int epoch,
    AppConfig cfg, {
    bool Function()? isCancelled,
  }) async {
    if (eeg.channelSamples.isEmpty || eeg.tfFreqs.isEmpty) return const [];

    const epochSeconds = 30;
    const extensionSec = 5.0;
    final safeEpoch = epoch.clamp(
      0,
      math.max(0, (eeg.durationSeconds / epochSeconds).ceil() - 1),
    );
    final tfConfigIndex = _clampConfigIndex(cfg.tfChannelIndex, cfg);
    final tfCh = _tfSourceIndex(eeg, cfg);
    final tfCfg = _configAt(cfg, tfConfigIndex, eeg.channelSamples.length);
    final signal = _fullSignalForConfig(
      eeg.channelSamples,
      eeg.sampleRateHz,
      cfg,
      tfConfigIndex,
      applyFilters: true,
    );
    final srate = eeg.sampleRateHz;
    final cacheKey = [
      identityHashCode(eeg),
      safeEpoch,
      tfCh,
      srate.toStringAsFixed(3),
      eeg.tfFreqs.length,
      eeg.tfFreqs.first.toStringAsFixed(3),
      eeg.tfFreqs.last.toStringAsFixed(3),
      cfg.tfDisplayMode,
      cfg.tfFrequencyScale,
      _channelConfigSignature(tfCfg),
    ].join(':');
    final cached = _tfCache[cacheKey];
    if (cached != null) {
      _touchCacheKey(_tfCacheOrder, cacheKey);
      return cached;
    }

    final startSamples = math.max(
      0,
      (safeEpoch * epochSeconds * srate - extensionSec * srate).round(),
    );
    final endSamples = math.min(
      signal.length,
      ((safeEpoch + 1) * epochSeconds * srate + extensionSec * srate).round(),
    );
    final slice = signal.sublist(startSamples, endSamples);
    var waveletRate = srate;
    const maxWaveletRate = 256.0;
    if (waveletRate > maxWaveletRate) {
      final step = (waveletRate / maxWaveletRate).ceil();
      waveletRate /= step;
    }
    if (slice.length < 4 ||
        !waveletRate.isFinite ||
        waveletRate <= 0 ||
        eeg.tfFreqs.any((f) => !f.isFinite || f <= 0 || f >= waveletRate / 2)) {
      return const [];
    }
    if (isCancelled != null && isCancelled()) return const [];
    final tfFreqs = List<double>.from(eeg.tfFreqs, growable: false);
    final rawPower = await Isolate.run(
      () => _isolateComputeMorletTf(slice, srate, tfFreqs),
    );
    if (isCancelled != null && isCancelled()) return const [];
    final logPower = sp.log10TfPower(rawPower);

    List<List<double>> tfPower;
    if (cfg.tfDisplayMode == 'Raw Power' ||
        cfg.tfDisplayMode == 'L2-Normalized Power') {
      tfPower = logPower;
    } else if (cfg.tfDisplayMode == 'dB (median baseline)') {
      tfPower = <List<double>>[];
      for (var f = 0; f < logPower.length; f++) {
        final med = f < eeg.tfNormMedian.length ? eeg.tfNormMedian[f] : 0.0;
        tfPower.add([for (final v in logPower[f]) 10.0 * (v - med)]);
      }
    } else {
      // Z-Standardized Power
      tfPower = sp.zScoreTfPower(logPower, eeg.tfNormMedian, eeg.tfNormIqr);
    }

    _rememberCacheValue(_tfCache, _tfCacheOrder, cacheKey, tfPower, 30);
    return tfPower;
  }

  void _touchCacheKey(List<String> order, String key) {
    order.remove(key);
    order.add(key);
  }

  void _rememberCacheValue<T>(
    Map<String, T> cache,
    List<String> order,
    String key,
    T value,
    int maxEntries,
  ) {
    cache[key] = value;
    _touchCacheKey(order, key);
    while (order.length > maxEntries) {
      cache.remove(order.removeAt(0));
    }
  }

  // ─── Demo viewport ─────────────────────────────────────────────────────────

  EegViewport loadDemoViewport() {
    return EegViewport(
      sampleRateHz: 256,
      epochSeconds: 30,
      channelLabels: const [],
      points: const [],
      stages: const [],
      stagesUncertain: const [],
      currentEpoch: 0,
      visibleStartSeconds: 0,
      visibleDurationSeconds: 30,
      totalDurationSeconds: 30,
      sourceDescription: 'No EDF file loaded',
    );
  }

  EegViewport _fromNative(_NativeViewport native) {
    final channelWaves = List.generate(native.channelCount, (_) => <double>[]);
    for (var index = 0; index < native.pointCount; index++) {
      final point = (native.points + index).ref;
      channelWaves[point.channel.clamp(0, native.channelCount - 1)].add(
        point.y,
      );
    }
    final pointsList = channelWaves
        .map((l) => Float32List.fromList(l))
        .toList();
    return EegViewport(
      sampleRateHz: native.sampleRateHz,
      epochSeconds: native.epochSeconds,
      channelLabels: [
        for (var i = 0; i < native.channelCount; i++) 'Ch ${i + 1}',
      ],
      points: pointsList,
      stages: const [
        SleepStage.wake,
        SleepStage.n1,
        SleepStage.n2,
        SleepStage.n3,
        SleepStage.rem,
      ],
      stagesUncertain: List<bool>.filled(5, false),
      currentEpoch: 0,
      visibleStartSeconds: 0,
      visibleDurationSeconds: 30,
      totalDurationSeconds: 150,
      sourceDescription: 'Rust FFI viewport',
    );
  }

  Future<ui.Image> _tfPowerToImage(
    List<List<double>> tfPower,
    double minVal,
    double maxVal,
  ) {
    final nFreqs = tfPower.length;
    final nTimes = tfPower.isNotEmpty ? tfPower[0].length : 0;
    if (nFreqs == 0 || nTimes == 0) {
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        Uint8List.fromList([0, 0, 0, 0]),
        1,
        1,
        ui.PixelFormat.rgba8888,
        (ui.Image img) => completer.complete(img),
      );
      return completer.future;
    }

    final range = math.max(maxVal - minVal, 1e-6);
    final pixels = Uint8List(nFreqs * nTimes * 4);
    var pixelIdx = 0;

    for (var f = 0; f < nFreqs; f++) {
      final flipF = nFreqs - 1 - f;
      final row = tfPower[flipF];
      for (var t = 0; t < nTimes; t++) {
        final val = row[t];
        final norm = ((val - minVal) / range).clamp(0.0, 1.0);
        final idx = (norm * 255).round();
        final color = sp.spectral[idx];
        final argb = color.toARGB32();
        pixels[pixelIdx++] = (argb >> 16) & 0xFF;
        pixels[pixelIdx++] = (argb >> 8) & 0xFF;
        pixels[pixelIdx++] = argb & 0xFF;
        pixels[pixelIdx++] = 255;
      }
    }

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      nTimes,
      nFreqs,
      ui.PixelFormat.rgba8888,
      (ui.Image img) => completer.complete(img),
    );
    return completer.future;
  }

  ({double min, double max}) _effectiveTfPowerLimits(
    LoadedEeg eeg,
    AppConfig config,
    List<List<double>> power,
  ) {
    if (!config.tfAutoScale || power.isEmpty) {
      return (
        min: config.tfPowerMin,
        max: math.max(config.tfPowerMin + 1e-6, config.tfPowerMax),
      );
    }
    final key = [
      identityHashCode(eeg),
      _tfSourceIndex(eeg, config),
      config.tfDisplayMode,
      config.tfFrequencyScale,
    ].join(':');
    return _tfScaleCache.putIfAbsent(key, () {
      final sampled = <double>[];
      final nTimes = power.first.length;
      final timeStep = math.max(1, nTimes ~/ 200);
      final freqStep = math.max(1, power.length ~/ 40);
      for (var f = 0; f < power.length; f += freqStep) {
        for (var t = 0; t < power[f].length; t += timeStep) {
          final value = power[f][t];
          if (value.isFinite) sampled.add(value);
        }
      }
      if (sampled.isEmpty) {
        return (min: config.tfPowerMin, max: config.tfPowerMax);
      }
      sampled.sort();
      final lower = sampled[(sampled.length * 0.02).floor()];
      final upper =
          sampled[(sampled.length * 0.98).floor().clamp(0, sampled.length - 1)];
      return (min: lower, max: math.max(lower + 1e-6, upper));
    });
  }

  ({double min, double max}) computeSpectrogramAutoLimits(
    List<List<double>> power,
    List<double> freqs,
    double freqMin,
    double freqMax,
  ) {
    if (power.isEmpty || freqs.isEmpty) return (min: -1.0, max: 3.0);
    final lowHz = math.min(freqMin, freqMax);
    final highHz = math.max(freqMin, freqMax);
    final sampled = <double>[];
    for (var e = 0; e < power.length; e++) {
      for (var f = 0; f < freqs.length; f++) {
        if (freqs[f] >= lowHz && freqs[f] <= highHz) {
          final val = power[e][f];
          if (val > 0 && val.isFinite) {
            final logPsd = math.log(val) / math.ln10;
            sampled.add(logPsd);
          }
        }
      }
    }
    if (sampled.isEmpty) return (min: -1.0, max: 3.0);
    sampled.sort();
    final lower = sampled[(sampled.length * 0.02).floor()];
    final upper =
        sampled[(sampled.length * 0.98).floor().clamp(0, sampled.length - 1)];
    final safeUpper = upper > lower ? upper : lower + 1.0;
    return (min: (lower * 10).round() / 10, max: (safeUpper * 10).round() / 10);
  }

  Future<ui.Image> _spectrogramPowerToImage(
    List<List<double>> power,
    List<double> freqs,
    double colorMin,
    double colorMax,
    double freqMin,
    double freqMax,
  ) {
    final nEpochs = power.length;
    final safeColorMax = colorMax > colorMin ? colorMax : colorMin + 1.0;
    final lowHz = math.min(freqMin, freqMax);
    final highHz = math.max(freqMin, freqMax);
    final freqIndices = <int>[
      for (var i = 0; i < freqs.length; i++)
        if (freqs[i] >= lowHz && freqs[i] <= highHz) i,
    ];
    final nFreqDisplay = freqIndices.length;

    if (nEpochs == 0 || nFreqDisplay == 0) {
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        Uint8List.fromList([0, 0, 0, 0]),
        1,
        1,
        ui.PixelFormat.rgba8888,
        (ui.Image img) => completer.complete(img),
      );
      return completer.future;
    }

    final pixels = Uint8List(nFreqDisplay * nEpochs * 4);
    var pixelIdx = 0;

    for (var r = 0; r < nFreqDisplay; r++) {
      final f = freqIndices[nFreqDisplay - 1 - r];
      for (var e = 0; e < nEpochs; e++) {
        final rawPsd = power[e][f];
        final logPsd = rawPsd > 0 ? math.log(rawPsd) / math.ln10 : colorMin;
        final t = ((logPsd - colorMin) / (safeColorMax - colorMin)).clamp(
          0.0,
          1.0,
        );
        final idx = (t * 255).round();
        final color = sp.cividis[idx];
        final argb = color.toARGB32();
        pixels[pixelIdx++] = (argb >> 16) & 0xFF;
        pixels[pixelIdx++] = (argb >> 8) & 0xFF;
        pixels[pixelIdx++] = argb & 0xFF;
        pixels[pixelIdx++] = 255;
      }
    }

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      nEpochs,
      nFreqDisplay,
      ui.PixelFormat.rgba8888,
      (ui.Image img) => completer.complete(img),
    );
    return completer.future;
  }
}

// ─── Top-Level Isolate Functions ─────────────────────────────────────────────

List<List<double>> _isolateComputeMorletTf(
  List<double> originalSlice,
  double originalSrate,
  List<double> freqs,
) {
  var slice = originalSlice;
  var waveletRate = originalSrate;
  const maxWaveletRate = 256.0;
  if (waveletRate > maxWaveletRate) {
    final step = (waveletRate / maxWaveletRate).ceil();
    final length = (slice.length / step).ceil();
    final downsampled = Float64List(length);
    for (var i = 0; i < length; i++) {
      downsampled[i] = slice[i * step];
    }
    slice = downsampled;
    waveletRate /= step;
  }

  _ComputeMorletDart? computeMorlet;
  _FreeMorletDart? freeMorlet;

  try {
    final library = _openDynamicLibrary();
    computeMorlet = library
        .lookupFunction<_ComputeMorletNative, _ComputeMorletDart>(
          'sleep_eeg_compute_morlet_tf',
        );
    freeMorlet = library.lookupFunction<_FreeMorletNative, _FreeMorletDart>(
      'sleep_eeg_free_morlet_tf',
    );
  } catch (_) {
    // Fallback to Dart
  }

  if (computeMorlet != null && freeMorlet != null) {
    final signalPtr = calloc<Float>(slice.length);
    signalPtr.asTypedList(slice.length).setAll(0, slice);

    final freqsPtr = calloc<Float>(freqs.length);
    freqsPtr.asTypedList(freqs.length).setAll(0, freqs);

    final resultPtr = computeMorlet(
      signalPtr,
      slice.length,
      waveletRate,
      freqsPtr,
      freqs.length,
      true,
    );

    calloc.free(signalPtr);
    calloc.free(freqsPtr);

    if (resultPtr != nullptr) {
      final res = resultPtr.ref;
      final dimensionsAreValid =
          res.power != nullptr &&
          res.nFreqs == freqs.length &&
          res.nSamples == slice.length &&
          res.nFreqs > 0 &&
          res.nSamples > 0 &&
          res.powerLen == res.nFreqs * res.nSamples;
      if (!dimensionsAreValid) {
        freeMorlet(resultPtr);
        return sp.computeMorletTf(slice, waveletRate, freqs);
      }
      final totalPowerElements = res.powerLen;
      final nativePower = res.power.asTypedList(totalPowerElements);
      final rawPower = List.generate(res.nFreqs, (i) {
        final start = i * res.nSamples;
        final end = start + res.nSamples;
        final row = Float64List(res.nSamples);
        row.setAll(0, nativePower.sublist(start, end));
        return row;
      });
      freeMorlet(resultPtr);
      return rawPower;
    }
  }

  return sp.computeMorletTf(slice, waveletRate, freqs);
}

class _SpectrogramResultData {
  _SpectrogramResultData(this.power, this.freqs);
  final List<List<double>> power;
  final List<double> freqs;
}

_SpectrogramResultData _isolateComputeSpectrogram(
  List<double> signal,
  double srate,
  int epochSeconds,
  int extensionSeconds,
) {
  _ComputeSpectrogramDart? computeSpectrogram;
  _FreeSpectrogramDart? freeSpectrogram;

  try {
    final library = _openDynamicLibrary();
    computeSpectrogram = library
        .lookupFunction<_ComputeSpectrogramNative, _ComputeSpectrogramDart>(
          'sleep_eeg_compute_welch_spectrogram',
        );
    freeSpectrogram = library
        .lookupFunction<_FreeSpectrogramNative, _FreeSpectrogramDart>(
          'sleep_eeg_free_spectrogram',
        );
  } catch (_) {
    // Fallback to Dart
  }

  if (computeSpectrogram != null && freeSpectrogram != null) {
    final signalPtr = calloc<Float>(signal.length);
    signalPtr.asTypedList(signal.length).setAll(0, signal);

    final resultPtr = computeSpectrogram(
      signalPtr,
      signal.length,
      srate,
      epochSeconds,
      extensionSeconds,
    );

    calloc.free(signalPtr);

    if (resultPtr != nullptr) {
      final res = resultPtr.ref;
      final totalPowerElements = res.nEpochs * res.nFreqs;
      final nativePower = res.power.asTypedList(totalPowerElements);
      final power = List.generate(res.nEpochs, (i) {
        final start = i * res.nFreqs;
        final end = start + res.nFreqs;
        final row = Float64List(res.nFreqs);
        row.setAll(0, nativePower.sublist(start, end));
        return row;
      });

      final nativeFreqs = res.freqs.asTypedList(res.nFreqs);
      final freqs = Float64List(res.nFreqs);
      freqs.setAll(0, nativeFreqs);

      freeSpectrogram(resultPtr);
      return _SpectrogramResultData(power, freqs);
    }
  }

  if (extensionSeconds > 0) {
    final (:power, :freqs) = sp.computeSpectrogram(
      [signal],
      srate,
      epochSeconds,
      0,
    );
    return _SpectrogramResultData(power, freqs);
  } else {
    final power = sp.precomputeEpochPeriodograms(
      [signal],
      srate,
      epochSeconds,
      0,
    );
    final slice = signal.sublist(
      0,
      math.min(signal.length, (epochSeconds * srate).round()),
    );
    final (_, freqs) = sp.welchPsd(slice, srate);
    return _SpectrogramResultData(power, freqs);
  }
}
