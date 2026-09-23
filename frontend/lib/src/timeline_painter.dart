// lib/src/timeline_painter.dart
//
// All CustomPainter classes for ScoringHero Flutter port.
// Ported from ScoringHero-0.2.4 widgets/:
//   SpectrogramPainter  ← spectogramWidget.py   (cividis colormap)
//   HypnogramPainter    ← hypnogramWidget.py    (double-plot: stages + SWA)
//   RectanglePowerPainter ← rectanglePower.py   (per-epoch Welch PSD)
//   TimeFrequencyPainter  ← tfWidget.py         (Morlet TF, spectral colormap)
//   TimelinePainter     ← signalWidget.py       (multi-channel EEG)
//   SelectionOverlayPainter                     (event/selection overlay)

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'models.dart';
import 'signal_processing.dart' as sp;

const double _leftPad = 90.0;

// ─────────────────────────────────────────────────────────────────────────────
// Stage colours matching Python HypnogramWidget
// ─────────────────────────────────────────────────────────────────────────────

const _stageColors = {
  SleepStage.wake: Color(0xFF56bf8b),
  SleepStage.rem: Color(0xFF8bbf56),
  SleepStage.n1: Color(0xFFaabcce),
  SleepStage.n2: Color(0xFF405c79),
  SleepStage.n3: Color(0xFF0b1c2c),
  SleepStage.inconclusive: Color(0xFF000000),
  SleepStage.unknown: Color(0xFF888888),
};

Color _stageColor(SleepStage s) => _stageColors[s] ?? const Color(0xFF888888);

/// Y-axis position for each stage in the hypnogram (matching Python digit encoding)
double _stageY(SleepStage s) {
  switch (s) {
    case SleepStage.wake:
      return 1.0;
    case SleepStage.rem:
      return 0.0;
    case SleepStage.n1:
      return -1.0;
    case SleepStage.n2:
      return -2.0;
    case SleepStage.n3:
      return -3.0;
    case SleepStage.inconclusive:
      return 2.0;
    case SleepStage.unknown:
      return 1.0;
  }
}

Color _cividisColor(double t) => sp.cividisColor(t);
Color _spectralColor(double t) => sp.spectralColor(t);

// ─────────────────────────────────────────────────────────────────────────────
// Shared drawing helpers
// ─────────────────────────────────────────────────────────────────────────────

final _axisTextStyle = TextStyle(
  color: Colors.black87,
  fontSize: 11,
  fontWeight: FontWeight.w500,
  fontFamily: 'sans-serif',
  background: Paint()..color = Colors.transparent,
);

final _labelTextStyle = TextStyle(
  color: Colors.white,
  fontSize: 10,
  fontWeight: FontWeight.bold,
  shadows: [Shadow(blurRadius: 2, color: Colors.black54)],
);

void _drawText(
  Canvas canvas,
  String text,
  Offset pos, {
  TextStyle? style,
  TextAlign align = TextAlign.left,
  double maxWidth = 200,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style ?? _axisTextStyle),
    textDirection: TextDirection.ltr,
    textAlign: align,
  )..layout(maxWidth: maxWidth);

  double dx = pos.dx;
  if (align == TextAlign.center) dx -= painter.width / 2;
  if (align == TextAlign.right) dx -= painter.width;

  painter.paint(canvas, Offset(dx, pos.dy - painter.height / 2));
}

// ─────────────────────────────────────────────────────────────────────────────
// Colorbar helper
// ─────────────────────────────────────────────────────────────────────────────

void _drawColorbar(
  Canvas canvas,
  Rect rect,
  Color Function(double t) colorFn,
  double minVal,
  double maxVal,
  String unit,
) {
  const nStops = 64;
  final cellH = rect.height / nStops;
  for (var i = 0; i < nStops; i++) {
    final t = 1.0 - i / (nStops - 1);
    final color = colorFn(t);
    canvas.drawRect(
      Rect.fromLTWH(rect.left, rect.top + i * cellH, rect.width, cellH + 0.5),
      Paint()..color = color,
    );
  }
  // Border
  canvas.drawRect(
    rect,
    Paint()
      ..color = Colors.black54
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5,
  );
  // Min/max labels
  _drawText(
    canvas,
    maxVal.toStringAsFixed(1),
    Offset(rect.right + 2, rect.top + 5),
    align: TextAlign.left,
  );
  _drawText(
    canvas,
    minVal.toStringAsFixed(1),
    Offset(rect.right + 2, rect.bottom - 5),
    align: TextAlign.left,
  );
  if (unit.isNotEmpty) {
    _drawText(
      canvas,
      unit,
      Offset(rect.right + 2, rect.top + rect.height / 2),
      align: TextAlign.left,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Epoch tick marks (for X axis of spectrogram + hypnogram)
// ─────────────────────────────────────────────────────────────────────────────

/// Returns a list of (label, fractional_x) pairs for the time axis.
List<(String, double)> _timeTicks(
  double totalSeconds, {
  String unit = 'Hours',
  DateTime? recordingStartTime,
}) {
  final step = _niceTimeStep(totalSeconds, maxTicks: 7);
  final ticks = <(String, double)>[];
  for (double t = step; t < totalSeconds; t += step) {
    final label = _formatTimeTick(t, unit, recordingStartTime);
    ticks.add((label, t / totalSeconds));
  }
  return ticks;
}

List<(String, double)> _timeTicksZoomed(
  double startSeconds,
  double visibleSeconds,
  String unit,
  DateTime? recordingStartTime,
) {
  final step = _niceTimeStep(visibleSeconds, maxTicks: 8);

  final ticks = <(String, double)>[];
  final firstTickTime = ((startSeconds / step).ceil() * step);
  for (double t = firstTickTime; t < startSeconds + visibleSeconds; t += step) {
    final label = _formatTimeTick(t, unit, recordingStartTime);
    ticks.add((label, (t - startSeconds) / visibleSeconds));
  }
  return ticks;
}

double _niceTimeStep(double visibleSeconds, {required int maxTicks}) {
  const stepOptions = [
    30.0,
    60.0,
    120.0,
    300.0,
    600.0,
    900.0,
    1800.0,
    3600.0,
    7200.0,
    10800.0,
    14400.0,
    21600.0,
    43200.0,
    86400.0,
  ];
  for (final step in stepOptions) {
    if (visibleSeconds / step <= maxTicks) return step;
  }
  return stepOptions.last;
}

String _formatTimeTick(double seconds, String unit, DateTime? startTime) {
  if (unit == 'Clock time' && startTime != null) {
    final time = startTime.add(Duration(seconds: seconds.round()));
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
  }
  if (unit == 'Seconds') return '${seconds.round()}s';
  if (unit == 'Minutes') return '${(seconds / 60).toStringAsFixed(0)}m';
  final h = (seconds / 3600).floor();
  final m = ((seconds % 3600) / 60).round();
  return m == 0 ? '${h}h' : '${h}h${m.toString().padLeft(2, '0')}';
}

Color _refColorForName(String name) {
  switch (name) {
    case 'Light Grey':
      return const Color(0xFFDDDDDD);
    case 'Dark Grey':
      return const Color(0xFF888888);
    case 'Red':
      return const Color(0xFFEF4444);
    case 'Blue':
      return const Color(0xFF3B82F6);
    case 'Green':
      return const Color(0xFF10B981);
    case 'Orange':
      return const Color(0xFFF59E0B);
    default:
      return const Color(0xFFDDDDDD);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 1.  SPECTROGRAM PAINTER
// ─────────────────────────────────────────────────────────────────────────────

class SpectrogramPainter extends CustomPainter {
  SpectrogramPainter(this.viewport, {this.onTapEpoch});

  final EegViewport viewport;
  final void Function(int epoch)? onTapEpoch;

  // Cache the rendered spectrogram image between repaints.
  // Only rebuilt when [_cachedDataKey] !== current power list reference.
  static ui.Picture? _cachedPicture;
  static Object? _cachedDataKey;
  static Size _cachedSize = Size.zero;

  @override
  void paint(Canvas canvas, Size size) {
    final power = viewport.spectrogramPower;
    final freqs = viewport.spectrogramFreqs;

    if (power.isEmpty || freqs.isEmpty) {
      _paintPlaceholder(canvas, size, 'Load an EDF to see spectrogram');
      return;
    }

    const bottomPad = 18.0;
    const rightPad = 38.0;
    final plotH = size.height - bottomPad;
    final drawWidth = size.width - _leftPad - rightPad;
    final drawSize = Size(drawWidth, plotH);

    // Draw the spectrogram image (GPU texture) if available, otherwise fallback to picture cache
    if (viewport.spectrogramImage != null) {
      final src = Rect.fromLTWH(
        0,
        0,
        viewport.spectrogramImage!.width.toDouble(),
        viewport.spectrogramImage!.height.toDouble(),
      );
      final dst = Rect.fromLTWH(_leftPad, 0, drawWidth, plotH);
      final paint = Paint()..filterQuality = ui.FilterQuality.low;
      canvas.drawImageRect(viewport.spectrogramImage!, src, dst, paint);
    } else {
      final dataKey = power; // reference identity check
      if (_cachedPicture == null ||
          !identical(_cachedDataKey, dataKey) ||
          _cachedSize != drawSize) {
        _cachedPicture = _buildSpectrogramPicture(drawSize, power, freqs);
        _cachedDataKey = dataKey;
        _cachedSize = drawSize;
      }

      canvas.save();
      canvas.translate(_leftPad, 0);
      canvas.drawPicture(_cachedPicture!);
      canvas.restore();
    }

    // Draw border outline around spectrogram plot
    canvas.drawRect(
      Rect.fromLTWH(_leftPad, 0, drawWidth, plotH),
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );

    // Epoch indicator (drawn fresh each frame — cheap)
    final epochCount = power.length;
    if (epochCount > 0) {
      final x = _leftPad + drawWidth * viewport.currentEpoch / epochCount;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, plotH),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 1.5,
      );
    }

    // X axis ticks
    _drawXTicks(canvas, size, plotH, drawWidth);

    // Y axis label (frequency)
    _drawYAxisLabel(canvas, size, plotH, freqs);

    // Channel label
    final spectChName = viewport.spectrogramChannelLabel.isNotEmpty
        ? viewport.spectrogramChannelLabel
        : viewport.channelLabels.isNotEmpty
        ? viewport.channelLabels[viewport.spectrogramChannelIndex.clamp(
            0,
            viewport.channelLabels.length - 1,
          )]
        : 'Ch 1';
    final labelText = viewport.spectrogramFiltered
        ? '$spectChName (Filtered)'
        : spectChName;
    _drawText(
      canvas,
      labelText,
      Offset(_leftPad + drawWidth / 2, 8),
      style: _labelTextStyle,
      align: TextAlign.center,
    );

    // Colorbar on the right (outside of the plot area)
    final cbarRect = Rect.fromLTWH(
      size.width - rightPad + 6,
      plotH * 0.15,
      7,
      plotH * 0.70,
    );
    _drawColorbar(
      canvas,
      cbarRect,
      _cividisColor,
      viewport.spectrogramPowerMin,
      viewport.spectrogramPowerMax,
      '',
    );
  }

  ui.Picture _buildSpectrogramPicture(
    Size size,
    List<List<double>> power,
    List<double> freqs,
  ) {
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);

    final nEpochs = power.length;
    final lowHz = math.min(
      viewport.spectrogramFreqMin,
      viewport.spectrogramFreqMax,
    );
    final highHz = math.max(
      viewport.spectrogramFreqMin,
      viewport.spectrogramFreqMax,
    );
    final freqIndices = <int>[
      for (var i = 0; i < freqs.length; i++)
        if (freqs[i] >= lowHz && freqs[i] <= highHz) i,
    ];
    final nFreqDisplay = freqIndices.length;
    if (nEpochs == 0 || nFreqDisplay == 0) return recorder.endRecording();

    // Compute global min/max for color scaling (log10 power)
    // Default: -1 to 3 (matches Python config["Spectrogram_power_limits"])
    final colorMin = viewport.spectrogramPowerMin;
    final colorMax = viewport.spectrogramPowerMax > colorMin
        ? viewport.spectrogramPowerMax
        : colorMin + 1.0;

    final cellW = size.width / nEpochs;
    final cellH = size.height / nFreqDisplay;

    for (var e = 0; e < nEpochs; e++) {
      for (var f = 0; f < nFreqDisplay; f++) {
        final rawPsd = power[e][freqIndices[f]];
        final logPsd = rawPsd > 0 ? math.log(rawPsd) / math.ln10 : colorMin;
        final t = ((logPsd - colorMin) / (colorMax - colorMin)).clamp(0.0, 1.0);
        c.drawRect(
          Rect.fromLTWH(
            e * cellW,
            size.height - (f + 1) * cellH, // flip Y (low freq at bottom)
            cellW + 0.5,
            cellH + 0.5,
          ),
          Paint()..color = _cividisColor(t),
        );
      }
    }

    return recorder.endRecording();
  }

  void _drawXTicks(Canvas canvas, Size size, double plotH, double drawWidth) {
    final totalSec = viewport.totalDurationSeconds;
    if (totalSec <= 0) return;
    final ticks = _timeTicks(
      totalSec,
      unit: viewport.eegPanelTimeUnit,
      recordingStartTime: viewport.recordingStartTime,
    );
    final tickPaint = Paint()
      ..color = Colors.black38
      ..strokeWidth = 0.5;
    for (final (label, fx) in ticks) {
      final x = _leftPad + drawWidth * fx;
      canvas.drawLine(Offset(x, plotH), Offset(x, plotH + 4), tickPaint);
      _drawText(
        canvas,
        label,
        Offset(x, plotH + 8),
        style: _axisTextStyle.copyWith(color: Colors.black54),
        align: TextAlign.center,
      );
    }
  }

  void _drawYAxisLabel(
    Canvas canvas,
    Size size,
    double plotH,
    List<double> freqs,
  ) {
    final minHz = math.min(
      viewport.spectrogramFreqMin,
      viewport.spectrogramFreqMax,
    );
    final maxHz = math.max(
      minHz + 1.0,
      math.min(
        math.max(viewport.spectrogramFreqMin, viewport.spectrogramFreqMax),
        freqs.isNotEmpty ? freqs.last : 45.0,
      ),
    );
    final tickStep = (maxHz - minHz) / 4;
    final tickHz = [for (var i = 0; i <= 4; i++) minHz + tickStep * i];
    final tickStyle = _axisTextStyle.copyWith(color: Colors.black87);
    for (final hz in tickHz) {
      final fy = 1.0 - (hz - minHz) / (maxHz - minHz);
      final y = fy * plotH;
      _drawText(
        canvas,
        '${hz.toStringAsFixed(hz < 10 ? 1 : 0)} Hz',
        Offset(_leftPad - 4, y),
        style: tickStyle,
        align: TextAlign.right,
      );
    }
  }

  void _paintPlaceholder(Canvas canvas, Size size, String msg) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF1a1a2e),
    );
    _drawText(
      canvas,
      msg,
      Offset(size.width / 2, size.height / 2),
      style: _axisTextStyle.copyWith(color: Colors.white38),
      align: TextAlign.center,
    );
  }

  @override
  bool shouldRepaint(SpectrogramPainter old) =>
      old.viewport.currentEpoch != viewport.currentEpoch ||
      old.viewport.spectrogramChannelIndex !=
          viewport.spectrogramChannelIndex ||
      !identical(old.viewport.spectrogramImage, viewport.spectrogramImage) ||
      !identical(old.viewport.spectrogramPower, viewport.spectrogramPower) ||
      old.viewport.spectrogramFreqMin != viewport.spectrogramFreqMin ||
      old.viewport.spectrogramFreqMax != viewport.spectrogramFreqMax ||
      old.viewport.spectrogramPowerMin != viewport.spectrogramPowerMin ||
      old.viewport.spectrogramPowerMax != viewport.spectrogramPowerMax ||
      old.viewport.eegPanelTimeUnit != viewport.eegPanelTimeUnit ||
      old.viewport.recordingStartTime != viewport.recordingStartTime;
}

// ─────────────────────────────────────────────────────────────────────────────
// 2.  HYPNOGRAM PAINTER  (double-plot: stage step chart + SWA overlay)
// ─────────────────────────────────────────────────────────────────────────────

class HypnogramPainter extends CustomPainter {
  HypnogramPainter(
    this.viewport, {
    this.swaKernelSize = 1,
    this.comparisonStages,
    this.startEpoch,
    this.endEpoch,
  });

  final EegViewport viewport;
  final int swaKernelSize;
  final List<SleepStage>? comparisonStages;
  final int? startEpoch;
  final int? endEpoch;

  static const _yMin = -4.0;
  static const _yMax = 2.5;
  static const _yRange = _yMax - _yMin;

  static const _bottomPad = 18.0;
  static const _hypPad = 48.0;

  double _toCanvasY(double stageY, double canvasH) {
    final plotH = canvasH - _bottomPad;
    return plotH * (1.0 - (stageY - _yMin) / _yRange);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final stages = viewport.stages;
    if (stages.isEmpty) {
      _drawPlaceholder(canvas, size);
      return;
    }

    _drawBackground(canvas, size);
    _drawDisagreementBands(canvas, size, stages);
    _drawYAxisLabels(canvas, size);
    _drawHypnogramSteps(canvas, size, stages);
    _drawHypnogramOverlay(canvas, size);
    _drawLightsMarkers(canvas, size);
    _drawEventOverlay(canvas, size);
    _drawEpochIndicator(canvas, size);
    _drawXAxisTicks(canvas, size);
  }

  void _drawDisagreementBands(
    Canvas canvas,
    Size size,
    List<SleepStage> stages,
  ) {
    final cmp = comparisonStages;
    if (cmp == null || cmp.isEmpty) return;

    final sEpoch = startEpoch ?? 0;
    final eEpoch = endEpoch ?? stages.length;
    final visibleCount = math.max(1, eEpoch - sEpoch);

    final drawWidth = size.width - _hypPad;
    final epochW = drawWidth / visibleCount;
    final plotH = size.height - _bottomPad;

    final bgPaint = Paint()..color = Colors.red.withOpacity(0.08);
    final indicatorPaint = Paint()..color = Colors.red.shade700;

    final yBotTop = _toCanvasY(-3.7, size.height);
    final yBotBottom = _toCanvasY(-3.95, size.height);

    for (
      var i = sEpoch;
      i < eEpoch && i < stages.length && i < cmp.length;
      i++
    ) {
      final s1 = stages[i];
      final s2 = cmp[i];
      if (s1 != SleepStage.unknown && s2 != SleepStage.unknown && s1 != s2) {
        final x0 = _hypPad + (i - sEpoch) * epochW;
        final x1 = x0 + epochW;
        canvas.drawRect(Rect.fromLTRB(x0, 0, x1, plotH), bgPaint);
        canvas.drawRect(
          Rect.fromLTRB(x0, yBotTop, x1, yBotBottom),
          indicatorPaint,
        );
      }
    }
  }

  void _drawEventOverlay(Canvas canvas, Size size) {
    final events = viewport.scoredEvents;
    if (events.isEmpty || viewport.totalDurationSeconds <= 0) return;

    final sEpoch = startEpoch ?? 0;
    final eEpoch = endEpoch ?? viewport.stages.length;
    final visibleCount = math.max(1, eEpoch - sEpoch);

    final drawWidth = size.width - _hypPad;
    final cy = _toCanvasY(2.0, size.height);
    final totalDuration = visibleCount * 30.0;
    final startTime = sEpoch * 30.0;
    final endTime = (sEpoch + visibleCount) * 30.0;

    // Filter visible events
    final visibleEvents = <ScoredEvent>[];
    for (final event in events) {
      if (viewport.disabledMarkerLabels.contains(event.label)) continue;
      final start = math.min(event.startSec, event.endSec);
      final end = math.max(event.startSec, event.endSec);
      if (end < startTime || start > endTime) continue;
      visibleEvents.add(event);
    }
    if (visibleEvents.isEmpty) return;

    // Partition events into macro (full-epoch / >= 15s) and micro (spindles, k-complexes, slow waves, spot markers, < 15s)
    final macroEvents = <ScoredEvent>[];
    final microEvents = <ScoredEvent>[];
    for (final ev in visibleEvents) {
      final dur = (ev.endSec - ev.startSec).abs();
      if (dur >= 15.0) {
        macroEvents.add(ev);
      } else {
        microEvents.add(ev);
      }
    }

    // Lane packing: allocate non-overlapping sub-tracks
    final trackEnds = <double>[];
    final eventTrack = <ScoredEvent, int>{};

    // First assign macro events to tracks
    macroEvents.sort((a, b) => a.startSec.compareTo(b.startSec));
    for (final ev in macroEvents) {
      final start = math.min(ev.startSec, ev.endSec);
      final end = math.max(ev.startSec, ev.endSec);
      int assigned = -1;
      for (var t = 0; t < trackEnds.length; t++) {
        if (trackEnds[t] <= start) {
          assigned = t;
          trackEnds[t] = end;
          break;
        }
      }
      if (assigned == -1) {
        assigned = trackEnds.length;
        trackEnds.add(end);
      }
      eventTrack[ev] = assigned;
    }

    // Micro events start on a separate track when macro events are present
    final microBaseTrack = macroEvents.isNotEmpty ? trackEnds.length : 0;
    final microTrackEnds = <double>[];
    microEvents.sort((a, b) => a.startSec.compareTo(b.startSec));
    for (final ev in microEvents) {
      final start = math.min(ev.startSec, ev.endSec);
      final end = math.max(ev.startSec, ev.endSec);
      int assigned = -1;
      for (var t = 0; t < microTrackEnds.length; t++) {
        if (microTrackEnds[t] <= start) {
          assigned = t;
          microTrackEnds[t] = end;
          break;
        }
      }
      if (assigned == -1) {
        assigned = microTrackEnds.length;
        microTrackEnds.add(end);
      }
      eventTrack[ev] = microBaseTrack + assigned;
    }

    final totalTracks =
        math.min(4, math.max(1, trackEnds.length + microTrackEnds.length));
    const bandH = 16.0;
    final topY = cy - 8.0;
    final trackH = bandH / totalTracks;

    for (final event in visibleEvents) {
      final start = math.min(event.startSec, event.endSec);
      final end = math.max(event.startSec, event.endSec);
      final visibleStart = math.max(start, startTime);
      final visibleEnd = math.min(end, endTime);

      final x1 =
          _hypPad + ((visibleStart - startTime) / totalDuration) * drawWidth;
      final x2 =
          _hypPad + ((visibleEnd - startTime) / totalDuration) * drawWidth;

      // Ensure local events (spindles, K-complex, spot events) have a minimum visible width
      final minWidth = event.isPointMarker ? 3.0 : 2.5;
      final renderedX2 = math.max(x1 + minWidth, x2);

      final track = (eventTrack[event] ?? 0).clamp(0, totalTracks - 1);
      final y1 = topY + (track * trackH);
      final y2 = topY + ((track + 1) * trackH) - (totalTracks > 1 ? 0.8 : 0.0);

      final baseColor = _eventColor(event.digit);
      final solidColor = baseColor.withAlpha(255);

      final rect = Rect.fromLTRB(x1, y1, renderedX2, y2);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(1.5)),
        Paint()..color = solidColor,
      );
    }
  }

  void _drawBackground(Canvas canvas, Size size) {
    final plotH = size.height - _bottomPad;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFfafafa),
    );
    canvas.drawRect(
      Rect.fromLTWH(_hypPad, 0, size.width - _hypPad, plotH),
      Paint()
        ..color = const Color(0xFFD0D0D0)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );
    const yVals = [1.0, 0.0, -1.0, -2.0, -3.0];
    final linePaint = Paint()
      ..color = const Color(0xFFDDDDDD)
      ..strokeWidth = 0.5;
    for (final y in yVals) {
      final cy = _toCanvasY(y, size.height);
      canvas.drawLine(Offset(_hypPad, cy), Offset(size.width, cy), linePaint);
    }
  }

  void _drawYAxisLabels(Canvas canvas, Size size) {
    const labels = <(double, String)>[
      (2.0, 'Event'),
      (1.0, 'W'),
      (0.0, 'REM'),
      (-1.0, 'N1'),
      (-2.0, 'N2'),
      (-3.0, 'N3'),
    ];
    for (final (y, label) in labels) {
      final cy = label == 'Event'
          ? _toCanvasY(y, size.height)
          : _toCanvasY(y - 0.5, size.height);
      _drawText(
        canvas,
        label,
        Offset(_hypPad - 4, cy),
        align: TextAlign.right,
      );
    }

    canvas.save();
    canvas.translate(8, size.height / 2);
    canvas.rotate(-math.pi / 2);
    _drawText(
      canvas,
      'Stage',
      Offset.zero,
      style: _axisTextStyle.copyWith(fontWeight: FontWeight.bold, fontSize: 10),
      align: TextAlign.center,
    );
    canvas.restore();
  }

  void _drawHypnogramSteps(Canvas canvas, Size size, List<SleepStage> stages) {
    final sEpoch = startEpoch ?? 0;
    final eEpoch = endEpoch ?? stages.length;
    final visibleCount = math.max(1, eEpoch - sEpoch);
    final drawWidth = size.width - _hypPad;
    final epochW = drawWidth / visibleCount;

    for (var i = sEpoch; i < eEpoch && i < stages.length; i++) {
      final stage = stages[i];
      if (stage == SleepStage.unknown) continue;
      final color = _stageColor(stage);
      final y = _stageY(stage);
      final cyTop = _toCanvasY(y, size.height);
      final cyBottom = _toCanvasY(y - 0.95, size.height);

      final x0 = _hypPad + (i - sEpoch) * epochW;
      final x1 = x0 + epochW;
      canvas.drawRect(
        Rect.fromLTRB(x0, cyTop, x1, cyBottom),
        Paint()..color = color,
      );

      final isUncertain =
          i < viewport.stagesUncertain.length && viewport.stagesUncertain[i];
      if (isUncertain) {
        canvas.drawRect(
          Rect.fromLTRB(x0, cyTop, x1, cyBottom),
          Paint()
            ..color = Colors.orange.shade700
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0,
        );
        canvas.drawLine(
          Offset(x0, cyBottom),
          Offset(x1, cyTop),
          Paint()
            ..color = Colors.orange.shade700
            ..strokeWidth = 1.0,
        );
      }
    }
  }

  void _drawHypnogramOverlay(Canvas canvas, Size size) {
    if (viewport.hypnogramOverlayMode == 'Off') return;
    if (viewport.hypnogramOverlayMode == 'Sleep-stage probability') {
      _drawProbabilityOverlay(canvas, size);
      return;
    }
    final swa = viewport.swaPerEpoch;
    if (swa.isEmpty) return;

    final sEpoch = startEpoch ?? 0;
    final eEpoch = endEpoch ?? viewport.stages.length;
    final visibleCount = math.max(1, eEpoch - sEpoch);
    final smoothed = _medianFilter(swa, swaKernelSize);
    var minV = smoothed.reduce(math.min);
    var maxV = smoothed.reduce(math.max);
    final range = maxV - minV;
    if (range < 1e-10) return;

    final path = Path();
    final drawWidth = size.width - _hypPad;
    final epochW = drawWidth / visibleCount;

    var first = true;
    for (var i = sEpoch; i < eEpoch && i < smoothed.length; i++) {
      final normalised = (smoothed[i] - minV) / range;
      final stageY = 5.0 * normalised - 4.0;
      final cy = _toCanvasY(stageY, size.height);
      final x = _hypPad + (i - sEpoch + 0.5) * epochW;
      if (first) {
        path.moveTo(x, cy);
        first = false;
      } else {
        path.lineTo(x, cy);
      }
    }

    if (!first) {
      final linePaint = Paint()
        ..color = Colors.black.withOpacity(0.55)
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke;
      canvas.drawPath(path, linePaint);

      // Clean top-right badge for SWA range & units
      _drawText(
        canvas,
        'SWA (max ${maxV.toStringAsFixed(1)} µV²)',
        Offset(size.width - 12, 12),
        style: _axisTextStyle.copyWith(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: Colors.black87,
        ),
        align: TextAlign.right,
      );
    }
  }

  void _drawProbabilityOverlay(Canvas canvas, Size size) {
    final probabilities = viewport.stageProbabilities;
    if (probabilities.isEmpty ||
        probabilities.every((entry) => entry.isEmpty)) {
      _drawText(
        canvas,
        'No stage probabilities loaded',
        Offset(size.width - 148, 12),
        style: _axisTextStyle.copyWith(
          color: Colors.black54,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
        align: TextAlign.left,
      );
      return;
    }
    final sEpoch = startEpoch ?? 0;
    final eEpoch = endEpoch ?? viewport.stages.length;
    final visibleCount = math.max(1, eEpoch - sEpoch);
    final drawWidth = size.width - _hypPad;
    final epochW = drawWidth / visibleCount;
    final stage = _probabilityStageFromConfig(
      viewport.hypnogramProbabilityStage,
    );
    final path = Path();
    var first = true;
    for (var i = sEpoch; i < eEpoch && i < probabilities.length; i++) {
      final probability = probabilities[i][stage];
      if (probability == null) continue;
      final stageY = -4.0 + 5.0 * probability.clamp(0.0, 1.0);
      final cy = _toCanvasY(stageY, size.height);
      final x = _hypPad + (i - sEpoch + 0.5) * epochW;
      if (first) {
        path.moveTo(x, cy);
        first = false;
      } else {
        path.lineTo(x, cy);
      }
    }
    if (first) return;
    final color = _stageColor(stage);
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withOpacity(0.95)
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke,
    );

    // Clean top-right badge for Stage Probability range & units
    _drawText(
      canvas,
      'P(${_stageLabel(stage)}): 0 – 100%',
      Offset(size.width - 12, 12),
      style: _axisTextStyle.copyWith(
        color: color,
        fontSize: 10,
        fontWeight: FontWeight.bold,
      ),
      align: TextAlign.right,
    );
  }

  SleepStage _probabilityStageFromConfig(String value) {
    switch (value.toUpperCase()) {
      case 'WAKE':
      case 'W':
        return SleepStage.wake;
      case 'REM':
      case 'R':
        return SleepStage.rem;
      case 'N1':
        return SleepStage.n1;
      case 'N3':
        return SleepStage.n3;
      case 'N2':
      default:
        return SleepStage.n2;
    }
  }

  String _stageLabel(SleepStage stage) {
    switch (stage) {
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
      default:
        return '?';
    }
  }

  void _drawLightsMarkers(Canvas canvas, Size size) {
    final total = viewport.totalDurationSeconds;
    if (total <= 0) return;
    final sEpoch = startEpoch ?? 0;
    final eEpoch = endEpoch ?? viewport.stages.length;
    final visibleCount = math.max(1, eEpoch - sEpoch);
    final epochSeconds = viewport.epochSeconds.toDouble();
    final startTime = sEpoch * epochSeconds;
    final endTime = (sEpoch + visibleCount) * epochSeconds;
    final visibleSeconds = math.max(1.0, endTime - startTime);
    final drawWidth = size.width - _hypPad;
    final plotH = size.height - _bottomPad;
    final markers = <(String, double, Color)>[
      (
        'Lights off',
        (viewport.lightsOffSeconds ?? 0).clamp(0.0, total),
        Colors.deepPurple,
      ),
      (
        'Lights on',
        (viewport.lightsOnSeconds ?? total).clamp(0.0, total),
        Colors.teal,
      ),
    ];
    for (final (label, seconds, color) in markers) {
      if (seconds < startTime || seconds > endTime) continue;
      final x = _hypPad + ((seconds - startTime) / visibleSeconds) * drawWidth;
      final paint = Paint()
        ..color = color.withOpacity(1.0)
        ..strokeWidth = 2.0;
      for (double y = 0; y < plotH; y += 10) {
        canvas.drawLine(Offset(x, y), Offset(x, math.min(y + 6, plotH)), paint);
      }
      canvas.drawCircle(Offset(x, plotH - 5), 4, Paint()..color = color);
      _drawText(
        canvas,
        label,
        Offset(x + 4, 10),
        style: _axisTextStyle.copyWith(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      );
    }
  }

  List<double> _medianFilter(List<double> data, int k) {
    if (k <= 1 || data.isEmpty) return data;
    final half = k ~/ 2;
    return [
      for (var i = 0; i < data.length; i++)
        () {
          final start = math.max(0, i - half);
          final end = math.min(data.length, i + half + 1);
          final w = data.sublist(start, end).toList()..sort();
          return w[w.length ~/ 2];
        }(),
    ];
  }

  void _drawEpochIndicator(Canvas canvas, Size size) {
    final sEpoch = startEpoch ?? 0;
    final eEpoch = endEpoch ?? viewport.epochCount;
    final visibleCount = math.max(1, eEpoch - sEpoch);
    final currentEpoch = viewport.currentEpoch;
    if (currentEpoch < sEpoch || currentEpoch >= eEpoch) return;
    final drawWidth = size.width - _hypPad;
    final x = _hypPad + drawWidth * (currentEpoch - sEpoch) / visibleCount;
    final plotH = size.height - _bottomPad;
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, plotH),
      Paint()
        ..color = Colors.black
        ..strokeWidth = 1.5,
    );
  }

  void _drawXAxisTicks(Canvas canvas, Size size) {
    final totalSec = viewport.totalDurationSeconds;
    if (totalSec <= 0) return;
    final sEpoch = startEpoch ?? 0;
    final eEpoch = endEpoch ?? viewport.epochCount;
    final visibleCount = math.max(1, eEpoch - sEpoch);
    final epochSeconds = viewport.epochSeconds.toDouble();
    final startSeconds = sEpoch * epochSeconds;
    final visibleSeconds = visibleCount * epochSeconds;
    final ticks = _timeTicksZoomed(
      startSeconds,
      visibleSeconds,
      viewport.eegPanelTimeUnit,
      viewport.recordingStartTime,
    );
    final tickPaint = Paint()
      ..color = Colors.black38
      ..strokeWidth = 0.5;
    final drawWidth = size.width - _hypPad;
    final plotH = size.height - _bottomPad;
    for (final (label, fx) in ticks) {
      final x = _hypPad + drawWidth * fx;
      canvas.drawLine(Offset(x, plotH), Offset(x, plotH + 4), tickPaint);
      _drawText(
        canvas,
        label,
        Offset(x, plotH + 8),
        style: _axisTextStyle.copyWith(color: Colors.black54),
        align: TextAlign.center,
      );
    }
  }

  void _drawPlaceholder(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFfafafa),
    );
  }

  @override
  bool shouldRepaint(HypnogramPainter old) =>
      old.viewport.stages != viewport.stages ||
      old.viewport.currentEpoch != viewport.currentEpoch ||
      old.swaKernelSize != swaKernelSize ||
      old.comparisonStages != comparisonStages ||
      old.viewport.hypnogramOverlayMode != viewport.hypnogramOverlayMode ||
      old.viewport.hypnogramProbabilityStage !=
          viewport.hypnogramProbabilityStage ||
      !identical(
        old.viewport.stageProbabilities,
        viewport.stageProbabilities,
      ) ||
      !identical(old.viewport.stagesUncertain, viewport.stagesUncertain) ||
      old.viewport.eegPanelTimeUnit != viewport.eegPanelTimeUnit ||
      old.viewport.recordingStartTime != viewport.recordingStartTime ||
      old.viewport.scoredEvents != viewport.scoredEvents ||
      old.viewport.lightsOffSeconds != viewport.lightsOffSeconds ||
      old.viewport.lightsOnSeconds != viewport.lightsOnSeconds;
}

// ─────────────────────────────────────────────────────────────────────────────
// 3.  RECTANGLE POWER PAINTER  (per-epoch Welch PSD)
// ─────────────────────────────────────────────────────────────────────────────

class RectanglePowerPainter extends CustomPainter {
  RectanglePowerPainter(this.viewport);

  final EegViewport viewport;

  @override
  void paint(Canvas canvas, Size size) {
    final psd = viewport.currentEpochPeriodogram;
    final freqs = viewport.periodogramFreqs;

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFfafafa),
    );

    if (psd.isEmpty || freqs.isEmpty) {
      _drawText(
        canvas,
        'Power\nspectrum',
        Offset(size.width / 2, size.height / 2),
        align: TextAlign.center,
      );
      return;
    }

    final minHz = viewport.periodogramFreqMin;
    final maxHz = viewport.periodogramFreqMax;
    final visiblePsd = <double>[];
    final visibleFreqs = <double>[];
    for (var i = 0; i < freqs.length && i < psd.length; i++) {
      if (freqs[i] >= minHz && freqs[i] <= maxHz) {
        visibleFreqs.add(freqs[i]);
        visiblePsd.add(psd[i]);
      }
    }
    if (visiblePsd.isEmpty) return;

    final displayPower = _displayPower(
      visiblePsd,
      viewport.periodogramDisplayMode,
    );

    // Min-max normalise to fit canvas
    final minV = displayPower.reduce(math.min);
    final maxV = displayPower.reduce(math.max);
    final range = maxV - minV < 1e-20 ? 1.0 : maxV - minV;

    const pad = EdgeInsets.only(
      left: 35.0,
      right: 18.0,
      top: 14.0,
      bottom: 26.0,
    );
    final plotW = size.width - pad.left - pad.right;
    final plotH = size.height - pad.top - pad.bottom;
    if (plotW <= 0 || plotH <= 0) return;

    final path = Path();
    for (var i = 0; i < visibleFreqs.length; i++) {
      final fx = maxHz <= minHz
          ? 0.0
          : (visibleFreqs[i] - minHz) / (maxHz - minHz);
      final fy = 1.0 - (displayPower[i] - minV) / range;
      final x = pad.left + fx * plotW;
      final y = pad.top + fy * plotH;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF0b1c2c)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );

    // X axis ticks & vertical gridlines
    final tickPaint = Paint()
      ..color = Colors.black38
      ..strokeWidth = 0.5;
    final gridPaint = Paint()
      ..color = Colors.black.withOpacity(0.06)
      ..strokeWidth = 0.5;

    final step = plotW < 150 ? 10.0 : 5.0;
    final firstTick = (minHz / step).ceil() * step;
    final freqRange = math.max(1e-6, maxHz - minHz);
    for (var hz = firstTick; hz <= maxHz; hz += step) {
      final x = pad.left + ((hz - minHz) / freqRange) * plotW;

      // Vertical gridline
      canvas.drawLine(
        Offset(x, pad.top),
        Offset(x, pad.top + plotH),
        gridPaint,
      );

      // Tick mark
      canvas.drawLine(
        Offset(x, pad.top + plotH),
        Offset(x, pad.top + plotH + 3),
        tickPaint,
      );

      _drawText(
        canvas,
        '${hz.toInt()}',
        Offset(x, pad.top + plotH + 6),
        align: TextAlign.center,
      );
    }

    // Draw horizontal label "Frequency (Hz)" at the bottom
    _drawText(
      canvas,
      'Frequency (Hz)',
      Offset(pad.left + plotW / 2, size.height - 10),
      style: _axisTextStyle.copyWith(
        fontWeight: FontWeight.bold,
        fontSize: 9,
        color: Colors.black54,
      ),
      align: TextAlign.center,
    );

    // Draw vertical label "Power (unitless)" on the left in the padding area
    canvas.save();
    canvas.translate(12, pad.top + plotH / 2);
    canvas.rotate(-math.pi / 2);
    _drawText(
      canvas,
      'Power (unitless)',
      Offset.zero,
      style: _axisTextStyle.copyWith(
        fontWeight: FontWeight.bold,
        fontSize: 9,
        color: Colors.black54,
      ),
      align: TextAlign.center,
    );
    canvas.restore();

    // Channel label badge in top right corner
    final channelName = viewport.periodogramChannelLabel.isNotEmpty
        ? viewport.periodogramChannelLabel
        : viewport.signalChannelLabels.isNotEmpty
        ? viewport.signalChannelLabels[viewport.periodogramChannelIndex.clamp(
            0,
            viewport.signalChannelLabels.length - 1,
          )]
        : 'PSD';
    final labelText = viewport.periodogramFiltered
        ? '$channelName (Filtered)'
        : channelName;

    final tp = TextPainter(
      text: TextSpan(
        text: labelText,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: Color(0xFF0b1c2c),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final badgeRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        pad.left + plotW - tp.width - 6,
        2.0,
        tp.width + 6,
        tp.height + 2,
      ),
      const Radius.circular(3),
    );
    canvas.drawRRect(
      badgeRect,
      Paint()..color = Colors.white.withOpacity(0.92),
    );
    canvas.drawRRect(
      badgeRect,
      Paint()
        ..color = const Color(0x33000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6,
    );
    tp.paint(canvas, Offset(badgeRect.left + 3, badgeRect.top + 1));
  }

  List<double> _movingAverage(List<double> data, int k) {
    if (k <= 1 || data.isEmpty) return data;
    final result = List<double>.filled(data.length, 0.0);
    double sum = 0;
    var count = 0;
    for (var i = 0; i < data.length; i++) {
      sum += data[i];
      count++;
      if (i >= k) {
        sum -= data[i - k];
        count--;
      }
      result[i] = sum / count;
    }
    return result;
  }

  List<double> _displayPower(List<double> visiblePsd, String mode) {
    if (mode == 'Raw Power') return visiblePsd;
    if (mode == 'dB') {
      return [
        for (final p in visiblePsd)
          p > 0 ? 10.0 * math.log(p) / math.ln10 : -300.0,
      ];
    }
    final smoothed = _movingAverage(visiblePsd, 20);
    final detrended = <double>[];
    for (var i = 0; i < visiblePsd.length; i++) {
      final s = smoothed[i] < 1e-30 ? 1e-30 : smoothed[i];
      detrended.add(visiblePsd[i] / s);
    }
    return detrended;
  }

  @override
  bool shouldRepaint(RectanglePowerPainter old) =>
      old.viewport.currentEpoch != viewport.currentEpoch ||
      !identical(
        old.viewport.currentEpochPeriodogram,
        viewport.currentEpochPeriodogram,
      ) ||
      old.viewport.periodogramDisplayMode != viewport.periodogramDisplayMode ||
      old.viewport.periodogramFreqMin != viewport.periodogramFreqMin ||
      old.viewport.periodogramFreqMax != viewport.periodogramFreqMax;
}

// ─────────────────────────────────────────────────────────────────────────────
// 4.  TIME-FREQUENCY (MORLET) PAINTER
// ─────────────────────────────────────────────────────────────────────────────

class TimeFrequencyPainter extends CustomPainter {
  TimeFrequencyPainter(this.viewport);

  final EegViewport viewport;

  static ui.Picture? _cachedPicture;
  static Object? _cachedDataKey;
  static Size _cachedSize = Size.zero;
  static double _cachedMinVal = 0.0;
  static double _cachedMaxVal = 0.0;

  @override
  void paint(Canvas canvas, Size size) {
    final tfPower = viewport.tfPower;
    final tfFreqs = viewport.tfFreqs;

    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);

    if (tfPower.isEmpty || tfFreqs.isEmpty) {
      _drawText(
        canvas,
        'Time-Frequency (load EDF)',
        Offset(size.width / 2, size.height / 2),
        style: _axisTextStyle.copyWith(color: Colors.black38),
        align: TextAlign.center,
      );
      return;
    }

    const bottomPad = 18.0;
    final plotH = size.height - bottomPad;
    final plotW = size.width - _leftPad;
    final plotSize = Size(plotW, plotH);

    final minVal = viewport.tfPowerMin;
    final maxVal = viewport.tfPowerMax;

    // Draw the time-frequency image (GPU texture) if available, otherwise fallback to picture cache
    if (viewport.tfImage != null) {
      final src = Rect.fromLTWH(
        0,
        0,
        viewport.tfImage!.width.toDouble(),
        viewport.tfImage!.height.toDouble(),
      );
      final dst = Rect.fromLTWH(_leftPad, 0, plotW, plotH);
      final paint = Paint()..filterQuality = ui.FilterQuality.low;
      canvas.drawImageRect(viewport.tfImage!, src, dst, paint);
    } else {
      // Rebuild background image only when TF data reference or limits change
      final dataKey = tfPower;
      if (_cachedPicture == null ||
          !identical(_cachedDataKey, dataKey) ||
          _cachedMinVal != minVal ||
          _cachedMaxVal != maxVal ||
          _cachedSize != plotSize) {
        _cachedPicture = _buildTfPicture(
          plotSize,
          tfPower,
          tfFreqs,
          minVal,
          maxVal,
        );
        _cachedDataKey = dataKey;
        _cachedMinVal = minVal;
        _cachedMaxVal = maxVal;
        _cachedSize = plotSize;
      }

      canvas.save();
      canvas.translate(_leftPad, 0);
      canvas.drawPicture(_cachedPicture!);
      canvas.restore();
    }

    // Draw border outline around TF plot
    canvas.drawRect(
      Rect.fromLTWH(_leftPad, 0, plotW, plotH),
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );

    // Extension epoch overlay (grey on edges)
    final epochStart = viewport.currentEpoch * 30.0;
    final leftExt = epochStart - viewport.visibleStartSeconds;
    final totalDuration = viewport.visibleDurationSeconds;
    if (totalDuration > 0) {
      final leftFrac = (leftExt / totalDuration).clamp(0.0, 1.0);
      final rightFrac = ((leftExt + 30.0) / totalDuration).clamp(0.0, 1.0);
      final overlayPaint = Paint()..color = Colors.black.withOpacity(0.30);
      canvas.drawRect(
        Rect.fromLTWH(_leftPad, 0, plotW * leftFrac, plotH),
        overlayPaint,
      );
      canvas.drawRect(
        Rect.fromLTWH(
          _leftPad + plotW * rightFrac,
          0,
          plotW * (1.0 - rightFrac),
          plotH,
        ),
        overlayPaint,
      );
    }

    // Y axis labels (linear spacing mapping to image rows)
    _drawYAxis(canvas, plotH, plotW, tfFreqs);

    // X axis ticks (absolute time in seconds)
    _drawXAxis(canvas, plotH, plotW);

    // Channel label
    final chLabel = viewport.tfChannelLabel.isNotEmpty
        ? viewport.tfChannelLabel
        : viewport.signalChannelLabels.isNotEmpty
        ? viewport.signalChannelLabels[viewport.tfChannelIndex.clamp(
            0,
            viewport.signalChannelLabels.length - 1,
          )]
        : 'TF';
    final labelText = viewport.tfFiltered ? '$chLabel (Filtered)' : chLabel;
    _drawText(
      canvas,
      labelText,
      Offset(_leftPad + plotW / 2, 8),
      style: _labelTextStyle,
      align: TextAlign.center,
    );

    // Colorbar on the right (overlaid on top of the image)
    final cbarRect = Rect.fromLTWH(
      size.width - 35,
      plotH * 0.15,
      8,
      plotH * 0.70,
    );
    _drawColorbar(canvas, cbarRect, _spectralColor, minVal, maxVal, '');
  }

  ui.Picture _buildTfPicture(
    Size size,
    List<List<double>> tfPower,
    List<double> freqs,
    double minVal,
    double maxVal,
  ) {
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);

    final nFreqs = tfPower.length;
    final nTimes = tfPower.isNotEmpty ? tfPower[0].length : 0;
    if (nFreqs == 0 || nTimes == 0) return recorder.endRecording();

    final cellW = size.width / nTimes;
    final cellH = size.height / nFreqs;

    for (var f = 0; f < nFreqs; f++) {
      // Frequency index 0 = lowest freq (bottom of display), nFreqs-1 = highest (top)
      final flipF = nFreqs - 1 - f;
      for (var t = 0; t < nTimes; t++) {
        final val = tfPower[flipF][t];
        final norm = ((val - minVal) / (maxVal - minVal)).clamp(0.0, 1.0);
        c.drawRect(
          Rect.fromLTWH(t * cellW, f * cellH, cellW + 0.5, cellH + 0.5),
          Paint()..color = _spectralColor(norm),
        );
      }
    }
    return recorder.endRecording();
  }

  void _drawYAxis(
    Canvas canvas,
    double plotH,
    double plotW,
    List<double> freqs,
  ) {
    if (freqs.isEmpty) return;
    final nFreqs = freqs.length;
    final minHz = freqs.first;
    final maxHz = freqs.last;

    // Determine ticks we want to show
    final List<double> desiredHz;
    if (maxHz <= 30.1) {
      desiredHz = [5.0, 10.0, 15.0, 20.0, 25.0, 30.0];
    } else {
      desiredHz = [];
      for (double hz = 10.0; hz <= maxHz; hz += 10.0) {
        desiredHz.add(hz);
      }
    }

    final tickStyle = _axisTextStyle.copyWith(color: Colors.black87);
    final gridPaint = Paint()
      ..color = Colors.black.withOpacity(0.12)
      ..strokeWidth = 0.5;

    for (final hz in desiredHz) {
      if (hz < minHz || hz > maxHz) continue;

      // Find the closest index in the freqs array
      var closestIdx = 0;
      var minDiff = (freqs[0] - hz).abs();
      for (var i = 1; i < nFreqs; i++) {
        final diff = (freqs[i] - hz).abs();
        if (diff < minDiff) {
          minDiff = diff;
          closestIdx = i;
        }
      }

      final fy = 1.0 - closestIdx / (nFreqs - 1);
      final y = fy * plotH;

      // Draw horizontal grid line
      _drawDashedLine(
        canvas,
        Offset(_leftPad, y),
        Offset(_leftPad + plotW, y),
        gridPaint,
      );

      // Draw tick label on left
      _drawText(
        canvas,
        '${hz.toInt()} Hz',
        Offset(_leftPad - 4, y),
        style: tickStyle,
        align: TextAlign.right,
      );
    }
  }

  void _drawXAxis(Canvas canvas, double plotH, double plotW) {
    final t_start = viewport.visibleStartSeconds;
    final totalSec = viewport.visibleDurationSeconds;
    if (totalSec <= 0) return;
    final t_end = t_start + totalSec;
    const tick_step = 6.0;

    final startTickMultiplier = (t_start / tick_step).ceil();
    final endTickMultiplier = (t_end / tick_step).floor();

    final tickStyle = _axisTextStyle.copyWith(
      color: Colors.black54,
      fontSize: 10,
    );

    for (var m = startTickMultiplier; m <= endTickMultiplier; m++) {
      final tAbs = m * tick_step;
      final tRel = tAbs - t_start; // relative seconds in window
      final fx = tRel / totalSec;
      final x = _leftPad + fx * plotW;

      // Draw a small tick mark at the bottom of the plot
      canvas.drawLine(
        Offset(x, plotH),
        Offset(x, plotH + 4),
        Paint()
          ..color = Colors.black38
          ..strokeWidth = 0.5,
      );

      // Label with "s" suffix
      _drawText(
        canvas,
        '${tAbs.toInt()} s',
        Offset(x, plotH + 8),
        style: tickStyle,
        align: TextAlign.center,
      );
    }
  }

  @override
  bool shouldRepaint(TimeFrequencyPainter old) =>
      !identical(old.viewport.tfPower, viewport.tfPower) ||
      !identical(old.viewport.tfImage, viewport.tfImage) ||
      !identical(old.viewport.tfFreqs, viewport.tfFreqs) ||
      old.viewport.tfChannelIndex != viewport.tfChannelIndex ||
      old.viewport.tfPowerMin != viewport.tfPowerMin ||
      old.viewport.tfPowerMax != viewport.tfPowerMax;
}

// ─────────────────────────────────────────────────────────────────────────────
// 5.  EEG SIGNAL TIMELINE PAINTER
// ─────────────────────────────────────────────────────────────────────────────

class TimelinePainter extends CustomPainter {
  TimelinePainter(
    this.viewport, {
    this.drawChannelLabels = true,
    this.leftPad = _leftPad,
  });

  final EegViewport viewport;
  final bool drawChannelLabels;
  final double leftPad;

  // Channel colours matching Python SignalWidget defaults
  static const List<Color> channelColors = [
    Color(0xFF000000), // EEG default: black
    Color(0xFF1a1a1a),
    Color(0xFF333333),
    Color(0xFF555555),
    Color(0xFF6495ED), // EOG-like: cornflower blue
    Color(0xFFE91E63), // ECG-like: pink
    Color(0xFFFF8C00), // EMG-like: orange
    Color(0xFF4CAF50), // green
    Color(0xFF9C27B0), // purple
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final points = viewport.points;
    final labels = viewport.signalChannelLabels;
    final n = labels.length;
    if (n == 0 || points.isEmpty) {
      _paintEmpty(canvas, size);
      return;
    }

    _drawBackground(canvas, size, n);
    _drawChannels(canvas, size, points, n);
    if (drawChannelLabels) {
      _drawChannelLabels(canvas, size, labels);
    }
    _drawAmplitudeLines(canvas, size, n, viewport.amplitudeRangeUv);
  }

  void _paintEmpty(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFfafafa),
    );
    _drawText(
      canvas,
      'No signal data',
      Offset(size.width / 2, size.height / 2),
      align: TextAlign.center,
    );
  }

  void _drawBackground(Canvas canvas, Size size, int n) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    // Horizontal grid lines between channels
    final channelHeight = size.height / n;
    final gridPaint = Paint()
      ..color = const Color(0xFFEEEEEE)
      ..strokeWidth = 0.5;
    for (var i = 1; i < n; i++) {
      final y = i * channelHeight;
      canvas.drawLine(Offset(leftPad, y), Offset(size.width, y), gridPaint);
    }
  }

  void _drawChannels(Canvas canvas, Size size, List<Float32List> waves, int n) {
    final drawWidth = size.width - leftPad;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(leftPad, 0, drawWidth, size.height));
    for (var ch = 0; ch < n; ch++) {
      if (ch >= waves.length) continue;
      final yValues = waves[ch];
      final len = yValues.length;
      if (len < 2) continue;

      final dx = drawWidth / (len - 1);
      final points = Float32List(len * 2);
      for (var i = 0; i < len; i++) {
        points[i * 2] = leftPad + i * dx;
        points[i * 2 + 1] = yValues[i] * size.height;
      }

      final color = _channelColorForName(
        ch < viewport.signalChannelColors.length
            ? viewport.signalChannelColors[ch]
            : 'Black',
        fallbackIndex: ch,
      );
      canvas.drawRawPoints(
        ui.PointMode.polygon,
        points,
        Paint()
          ..color = color
          ..strokeWidth = 0.8
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.restore();
  }

  void _drawChannelLabels(Canvas canvas, Size size, List<String> labels) {
    final channelHeight = size.height / labels.length;
    final labelStyle = TextStyle(
      color: Colors.black87, // Legible dark color
      fontSize: 12, // Professional compact size
      fontWeight: FontWeight.bold,
      fontFamily: 'sans-serif',
    );
    for (var i = 0; i < labels.length; i++) {
      final cy = (i + 0.5) * channelHeight;
      _drawText(
        canvas,
        labels[i],
        Offset(8.0, cy), // Aligned inside the 90px left margin
        style: labelStyle,
        align: TextAlign.left,
      );
    }
  }

  void _drawAmplitudeLines(
    Canvas canvas,
    Size size,
    int n,
    double amplitudeRangeUv,
  ) {
    final channelHeight = size.height / n;
    final refUv = viewport.referenceAmplitudeLineUv;
    final maxUv = amplitudeRangeUv > 0 ? amplitudeRangeUv : 1e-6;
    final guideOffset = 0.42 * (refUv / maxUv);

    // Draw guide lines for every channel
    for (var i = 0; i < n; i++) {
      final cy = (i + 0.5) * channelHeight;
      final plusY = cy - guideOffset * channelHeight;
      final minusY = cy + guideOffset * channelHeight;

      final guideColor = _refColorForName(viewport.referenceLineColor);
      final guidePaint = Paint()
        ..color = guideColor
        ..strokeWidth = viewport.referenceLineThickness;

      _drawDashedLine(
        canvas,
        Offset(leftPad, plusY),
        Offset(size.width, plusY),
        guidePaint,
      );
      _drawDashedLine(
        canvas,
        Offset(leftPad, minusY),
        Offset(size.width, minusY),
        guidePaint,
      );
      // '0' line (center)
      _drawDashedLine(
        canvas,
        Offset(leftPad, cy),
        Offset(size.width, cy),
        guidePaint,
      );

      // Amplitude text ONLY for the first channel (EEG L) on the left axis
      if (i == 0) {
        final tickStyle = _axisTextStyle.copyWith(
          fontSize: 10,
          color: Colors.black54,
        );
        final refStr = refUv % 1 == 0
            ? refUv.toStringAsFixed(0)
            : refUv.toStringAsFixed(1);
        _drawText(
          canvas,
          '+$refStr',
          Offset(leftPad - 4, plusY),
          style: tickStyle,
          align: TextAlign.right,
        );
        _drawText(
          canvas,
          '0',
          Offset(leftPad - 4, cy),
          style: tickStyle,
          align: TextAlign.right,
        );
        _drawText(
          canvas,
          '-$refStr',
          Offset(leftPad - 4, minusY),
          style: tickStyle,
          align: TextAlign.right,
        );
      }
    }

    // Draw central vertical dashed line (at 15s)
    final verticalPaint = Paint()
      ..color = Colors.black.withOpacity(0.06)
      ..strokeWidth = 1.0;

    final drawWidth = size.width - leftPad;
    final centerX = leftPad + drawWidth / 2;
    _drawDashedLine(
      canvas,
      Offset(centerX, 0),
      Offset(centerX, size.height),
      verticalPaint,
    );
  }

  @override
  bool shouldRepaint(TimelinePainter old) =>
      old.leftPad != leftPad ||
      old.viewport.currentEpoch != viewport.currentEpoch ||
      old.viewport.points != viewport.points ||
      old.viewport.signalChannelLabels != viewport.signalChannelLabels ||
      old.viewport.signalChannelColors != viewport.signalChannelColors ||
      old.viewport.stages != viewport.stages ||
      old.viewport.stagesUncertain != viewport.stagesUncertain;
}

Color _channelColorForName(String name, {required int fallbackIndex}) {
  switch (name) {
    case 'Black':
      return const Color(0xFF000000);
    case 'Blue':
      return const Color(0xFF2563EB);
    case 'Green':
      return const Color(0xFF1F9D55);
    case 'Magenta':
      return const Color(0xFFC026D3);
    case 'Orange':
      return const Color(0xFFEA580C);
    case 'Cyan':
      return const Color(0xFF0891B2);
    default:
      return TimelinePainter.channelColors[fallbackIndex %
          TimelinePainter.channelColors.length];
  }
}

void _drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint) {
  const dashLen = 8.0;
  const gapLen = 4.0;

  if (p1.dy == p2.dy) {
    // Horizontal
    var x = p1.dx;
    bool drawing = true;
    while (x < p2.dx) {
      final end = x + (drawing ? dashLen : gapLen);
      if (drawing) {
        canvas.drawLine(
          Offset(x, p1.dy),
          Offset(math.min(end, p2.dx), p1.dy),
          paint,
        );
      }
      x = end;
      drawing = !drawing;
    }
  } else if (p1.dx == p2.dx) {
    // Vertical
    var y = p1.dy;
    bool drawing = true;
    while (y < p2.dy) {
      final end = y + (drawing ? dashLen : gapLen);
      if (drawing) {
        canvas.drawLine(
          Offset(p1.dx, y),
          Offset(p1.dx, math.min(end, p2.dy)),
          paint,
        );
      }
      y = end;
      drawing = !drawing;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 6.  SELECTION OVERLAY PAINTER  (drawn on top of signal panel)
// ─────────────────────────────────────────────────────────────────────────────

class SelectionOverlayPainter extends CustomPainter {
  SelectionOverlayPainter(
    this.viewport, {
    this.activeDragStartSec,
    this.activeDragEndSec,
    this.activeDragChannel,
    this.activeDragStartUv,
    this.activeDragEndUv,
    this.leftPad = _leftPad,
  });

  final EegViewport viewport;
  final double? activeDragStartSec;
  final double? activeDragEndSec;
  final int? activeDragChannel;
  final double? activeDragStartUv;
  final double? activeDragEndUv;
  final double leftPad;

  @override
  void paint(Canvas canvas, Size size) {
    // The viewport is 40s total (5s before, 30s epoch, 5s after)
    const displayTotalSec = 40.0;
    const paddingSec = 5.0;

    final drawWidth = size.width - leftPad;
    final leftFrac = paddingSec / displayTotalSec;
    final rightFrac = 1.0 - leftFrac;

    final paint = Paint()..color = Colors.black.withOpacity(0.30);

    // Left shaded region
    canvas.drawRect(
      Rect.fromLTRB(leftPad, 0, leftPad + drawWidth * leftFrac, size.height),
      paint,
    );

    // Right shaded region
    canvas.drawRect(
      Rect.fromLTRB(
        leftPad + drawWidth * rightFrac,
        0,
        size.width,
        size.height,
      ),
      paint,
    );

    final visibleStart = viewport.visibleStartSeconds;
    final visibleEnd = visibleStart + displayTotalSec;
    for (final event in viewport.scoredEvents) {
      if (viewport.disabledMarkerLabels.contains(event.label)) continue;
      final rawStart = math.min(event.startSec, event.endSec);
      final rawEnd = math.max(event.startSec, event.endSec);

      if (rawEnd < visibleStart || rawStart > visibleEnd) continue;

      final start = math.max(rawStart, visibleStart);
      final end = math.min(rawEnd, visibleEnd);

      final x1 =
          leftPad + ((start - visibleStart) / displayTotalSec) * drawWidth;
      final x2 =
          leftPad + ((end - visibleStart) / displayTotalSec) * drawWidth;
      final color = _eventColor(event.digit);

      if (event.isPointMarker || (x2 - x1).abs() < 2.0) {
        // Point marker line
        canvas.drawLine(
          Offset(x1, 0),
          Offset(x1, size.height),
          Paint()
            ..color = color.withOpacity(0.85)
            ..strokeWidth = 1.5,
        );
      } else {
        // Duration span interval
        canvas.drawRect(
          Rect.fromLTRB(x1, 0, x2, size.height),
          Paint()..color = color.withOpacity(0.18),
        );
        canvas.drawRect(
          Rect.fromLTRB(x1, 0, x2, size.height),
          Paint()
            ..color = color.withOpacity(0.75)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0,
        );
      }

      // Draw high-contrast badge pill at the top with event/marker label
      final labelSpan = TextSpan(
        text: ' ${event.label} ',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9.5,
          fontWeight: FontWeight.bold,
        ),
      );
      final labelPainter = TextPainter(
        text: labelSpan,
        textDirection: TextDirection.ltr,
      )..layout();

      final double bgX = x1.clamp(
        leftPad,
        math.max(leftPad, size.width - labelPainter.width - 4),
      ).toDouble();
      final bgRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(bgX, 2, labelPainter.width + 4, labelPainter.height + 2),
        const Radius.circular(3),
      );
      canvas.drawRRect(bgRect, Paint()..color = color.withOpacity(0.88));
      labelPainter.paint(canvas, Offset(bgX + 2, 3));
    }
    for (final selection in viewport.eventSelections) {
      _drawSelectionBox(
        canvas,
        size,
        selection.startSec,
        selection.endSec,
        selection.channel,
        selection.startUv,
        selection.endUv,
        drawWidth,
        visibleStart,
        displayTotalSec,
      );
    }

    // Draw active drag selection on top. Committed selections remain visible and
    // contribute to the total duration, matching Scoring Hero's multi-select use.
    final bool hasActiveDrag =
        (activeDragStartSec != null &&
        activeDragEndSec != null &&
        activeDragChannel != null &&
        activeDragStartUv != null &&
        activeDragEndUv != null);

    final EventSelection? labelTarget = hasActiveDrag
        ? EventSelection(
            startSec: activeDragStartSec!,
            endSec: activeDragEndSec!,
            channel: activeDragChannel!,
            startUv: activeDragStartUv!,
            endUv: activeDragEndUv!,
            peakToPeakUv: 0.0,
          )
        : (viewport.eventSelections.isNotEmpty
              ? viewport.eventSelections.last
              : null);

    if (labelTarget != null) {
      final s = math.min(labelTarget.startSec, labelTarget.endSec);
      final e = math.max(labelTarget.startSec, labelTarget.endSec);

      final x1 = leftPad + ((s - visibleStart) / displayTotalSec) * drawWidth;
      final x2 = leftPad + ((e - visibleStart) / displayTotalSec) * drawWidth;

      final n = viewport.channelCount;
      final baselineFraction = (labelTarget.channel + 0.5) / n;
      final y1 =
          (baselineFraction -
              (labelTarget.startUv / viewport.amplitudeRangeUv) * 0.42 / n) *
          size.height;
      final y2 =
          (baselineFraction -
              (labelTarget.endUv / viewport.amplitudeRangeUv) * 0.42 / n) *
          size.height;

      if (hasActiveDrag) {
        final boxRect = Rect.fromLTRB(
          math.min(x1, x2),
          math.min(y1, y2),
          math.max(x1, x2),
          math.max(y1, y2),
        );

        // Semi-transparent green fill (QColor(10, 100, 10, 40) -> 0x280A640A)
        canvas.drawRect(boxRect, Paint()..color = const Color(0x280A640A));
        // Dark green border
        canvas.drawRect(
          boxRect,
          Paint()
            ..color = const Color(0xFF0A640A)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0,
        );
      }

      // Top label: Height of the box in microvolts
      final heightUv = (labelTarget.endUv - labelTarget.startUv).abs();
      final topText = "${heightUv.toStringAsFixed(1)} µV";
      _drawText(
        canvas,
        topText,
        Offset((x1 + x2) / 2, math.min(y1, y2) - 8),
        style: const TextStyle(
          color: Color(0xFF0A640A),
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
        align: TextAlign.center,
      );

      // Bottom label: Width of the box in seconds
      final widthSec = (labelTarget.endSec - labelTarget.startSec).abs();
      final bottomText = "${widthSec.toStringAsFixed(2)} s";
      _drawText(
        canvas,
        bottomText,
        Offset((x1 + x2) / 2, math.max(y1, y2) + 8),
        style: const TextStyle(
          color: Color(0xFF0A640A),
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
        align: TextAlign.center,
      );

      // Left label: Peak-to-peak amplitude of the signal inside the box, rotated 270 degrees
      double? peakToPeak;
      if (hasActiveDrag) {
        // Estimate from display points in real-time drag
        final ch = labelTarget.channel;
        if (ch >= 0 && ch < viewport.points.length) {
          final yVals = viewport.points[ch];
          final len = yVals.length;
          final i1 = (((s - visibleStart) / displayTotalSec) * len)
              .floor()
              .clamp(0, len - 1);
          final i2 = (((e - visibleStart) / displayTotalSec) * len)
              .ceil()
              .clamp(0, len - 1);
          if (i2 > i1) {
            var minY = yVals[i1];
            var maxY = yVals[i1];
            for (var i = i1 + 1; i <= i2; i++) {
              final y = yVals[i];
              if (y < minY) minY = y;
              if (y > maxY) maxY = y;
            }
            final channelHeight = 1.0 / n;
            final deltaNorm = (maxY - minY) / (channelHeight * 0.42);
            peakToPeak = deltaNorm * viewport.amplitudeRangeUv;
          }
        }
      } else {
        peakToPeak = labelTarget.peakToPeakUv;
      }

      if (peakToPeak != null) {
        final leftText = "${peakToPeak.toStringAsFixed(1)} µV";
        final labelColor =
            TimelinePainter.channelColors[labelTarget.channel %
                TimelinePainter.channelColors.length];
        final leftStyle = TextStyle(
          color: labelColor,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        );
        _drawRotatedText(
          canvas,
          leftText,
          Offset(math.min(x1, x2) - 8, (y1 + y2) / 2),
          -math.pi / 2,
          leftStyle,
        );
      }
    }
  }

  void _drawSelectionBox(
    Canvas canvas,
    Size size,
    double startSec,
    double endSec,
    int channel,
    double startUv,
    double endUv,
    double drawWidth,
    double visibleStart,
    double displayTotalSec,
  ) {
    final x1 =
        leftPad + ((startSec - visibleStart) / displayTotalSec) * drawWidth;
    final x2 =
        leftPad + ((endSec - visibleStart) / displayTotalSec) * drawWidth;
    final n = viewport.channelCount;
    if (n == 0) return;
    final baselineFraction = (channel + 0.5) / n;
    final y1 =
        (baselineFraction - (startUv / viewport.amplitudeRangeUv) * 0.42 / n) *
        size.height;
    final y2 =
        (baselineFraction - (endUv / viewport.amplitudeRangeUv) * 0.42 / n) *
        size.height;
    final boxRect = Rect.fromLTRB(
      math.min(x1, x2),
      math.min(y1, y2),
      math.max(x1, x2),
      math.max(y1, y2),
    );
    canvas.drawRect(boxRect, Paint()..color = const Color(0x280A640A));
    canvas.drawRect(
      boxRect,
      Paint()
        ..color = const Color(0xFF0A640A)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
  }

  void _drawRotatedText(
    Canvas canvas,
    String text,
    Offset pos,
    double angleRad,
    TextStyle style,
  ) {
    canvas.save();
    canvas.translate(pos.dx, pos.dy);
    canvas.rotate(angleRad);
    _drawText(canvas, text, Offset.zero, style: style, align: TextAlign.center);
    canvas.restore();
  }

  @override
  bool shouldRepaint(SelectionOverlayPainter old) =>
      old.leftPad != leftPad ||
      old.viewport.selectionStartSec != viewport.selectionStartSec ||
      old.viewport.selectionEndSec != viewport.selectionEndSec ||
      old.viewport.selectionChannel != viewport.selectionChannel ||
      old.viewport.selectionStartUv != viewport.selectionStartUv ||
      old.viewport.selectionEndUv != viewport.selectionEndUv ||
      old.viewport.selectionPeakToPeakUv != viewport.selectionPeakToPeakUv ||
      !identical(old.viewport.eventSelections, viewport.eventSelections) ||
      !identical(old.viewport.scoredEvents, viewport.scoredEvents) ||
      old.activeDragStartSec != activeDragStartSec ||
      old.activeDragEndSec != activeDragEndSec ||
      old.activeDragChannel != activeDragChannel ||
      old.activeDragStartUv != activeDragStartUv ||
      old.activeDragEndUv != activeDragEndUv;
}

Color _eventColor(int digit) {
  const colors = [
    Color.fromARGB(75, 255, 200, 200),
    Color.fromARGB(100, 100, 149, 237),
    Color.fromARGB(100, 152, 251, 152),
    Color.fromARGB(100, 255, 255, 102),
    Color.fromARGB(100, 64, 224, 208),
    Color.fromARGB(100, 148, 103, 189),
    Color.fromARGB(100, 140, 86, 75),
    Color.fromARGB(100, 227, 119, 194),
    Color.fromARGB(100, 127, 127, 127),
    Color.fromARGB(100, 188, 189, 34),
    Color.fromARGB(100, 255, 165, 0),
    Color.fromARGB(100, 75, 0, 130),
    Color.fromARGB(100, 255, 105, 180),
    // 13-20: respiratory & limb-movement events (psg_analysis.dart)
    Color.fromARGB(120, 198, 40, 40), // 13 obstructive apnea
    Color.fromARGB(120, 21, 101, 192), // 14 central apnea
    Color.fromARGB(120, 106, 27, 154), // 15 mixed apnea
    Color.fromARGB(120, 239, 108, 0), // 16 hypopnea
    Color.fromARGB(120, 249, 168, 37), // 17 RERA
    Color.fromARGB(110, 0, 151, 167), // 18 desaturation
    Color.fromARGB(110, 124, 179, 66), // 19 leg movement
    Color.fromARGB(130, 27, 94, 32), // 20 PLM
  ];
  return colors[digit.clamp(0, colors.length - 1)];
}
