// Expanded overnight timeline: hypnogram, one row per event type and the
// SpO2 trend for the whole night, for scanning respiratory / CAP / limb
// events and jumping to any part of the recording.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models.dart';
import 'psg_report_data.dart';
import 'timeline_painter.dart';

/// One row of the timeline.
class TimelineRow {
  TimelineRow(this.label, this.color, this.spans);

  final String label;
  final Color color;
  final List<(double, double)> spans;
}

const int kDigitSlowWave = 7;
const int kDigitSpindle = 8;

/// Groups markers into rows: analysis results by type (OA, CA, MA, Hyp,
/// RERA, Desat, Arousal, LM/PLM, CAP, Slow Wave, Spindle), other markers
/// (e.g. scored EDF annotations) by their label.
List<TimelineRow> overnightTimelineRows(
  List<ScoredEvent> events, {
  Set<String> hiddenLabels = const {},
}) {
  final typed = <String, (int, List<(double, double)>)>{};
  final other = <String, List<(double, double)>>{};
  const order = [
    ('OA', kDigitObstructiveApnea),
    ('CA', kDigitCentralApnea),
    ('MA', kDigitMixedApnea),
    ('Hyp', kDigitHypopnea),
    ('RERA', kDigitRera),
    ('Desat', kDigitDesaturation),
    ('Arousal', kDigitArousal),
    ('LM', kDigitLegMovement),
    ('PLM', kDigitPlm),
    ('CAP A1', kDigitCapA1),
    ('CAP A2', kDigitCapA2),
    ('CAP A3', kDigitCapA3),
    ('CAP seq', kDigitCapSequence),
    ('Slow Wave', kDigitSlowWave),
    ('Spindle', kDigitSpindle),
  ];
  final byDigit = {for (final o in order) o.$2: o.$1};
  for (final e in events) {
    if (hiddenLabels.contains(e.label)) continue;
    final a = math.min(e.startSec, e.endSec);
    var b = math.max(e.startSec, e.endSec);
    if (b - a < 1) b = a + 1;
    final String? name;
    final int digit;
    if (e.digit == kDigitSlowWave ||
        e.type == 'AnalyseNidra SlowWave' ||
        e.label.startsWith('SlowWave')) {
      name = 'Slow Wave';
      digit = kDigitSlowWave;
    } else if (e.digit == kDigitSpindle ||
        e.type == 'AnalyseNidra Spindle' ||
        e.label.startsWith('Spindle')) {
      name = 'Spindle';
      digit = kDigitSpindle;
    } else {
      name = byDigit[e.digit];
      digit = e.digit;
    }
    if (name != null) {
      typed.putIfAbsent(name, () => (digit, <(double, double)>[])).$2.add((a, b));
    } else {
      other.putIfAbsent(e.label.trim().isEmpty ? 'Marker' : e.label.trim(), () => []).add((a, b));
    }
  }
  final rows = <TimelineRow>[
    for (final o in order)
      if (typed[o.$1] != null)
        TimelineRow(o.$1, markerColorForDigit(o.$2), typed[o.$1]!.$2),
  ];
  // Other markers: the most frequent labels, each on its own row.
  final otherSorted = other.entries.toList()
    ..sort((x, y) => y.value.length.compareTo(x.value.length));
  const palette = [
    Color(0xFF5E35B1),
    Color(0xFF00897B),
    Color(0xFF6D4C41),
    Color(0xFF3949AB),
    Color(0xFFC0CA33),
    Color(0xFF8E24AA),
    Color(0xFF546E7A),
    Color(0xFFD81B60),
  ];
  for (var i = 0; i < otherSorted.length && i < palette.length; i++) {
    rows.add(TimelineRow(otherSorted[i].key, palette[i], otherSorted[i].value));
  }
  return rows;
}

/// Minimum SpO2 per [stepSeconds] (values outside 50–100 % ignored), or
/// null when the recording has no SpO2 channel.
List<double?>? spo2Trend(LoadedEeg eeg, {double stepSeconds = 10}) {
  final idx = eeg.channelLabels.indexWhere(
    (l) => levelSignalKind(l) == LevelSignalKind.spo2,
  );
  if (idx < 0 || eeg.sampleRateHz <= 0) return null;
  final x = eeg.channelSamples[idx];
  final step = math.max(1, (stepSeconds * eeg.sampleRateHz).round());
  // Saturation stored as a 0–1 fraction?
  var maxV = 0.0;
  for (var i = 0; i < x.length; i += step) {
    if (x[i].isFinite && x[i] > maxV) maxV = x[i];
  }
  final factor = maxV > 0 && maxV <= 1.5 ? 100.0 : 1.0;
  final out = <double?>[];
  for (var s = 0; s < x.length; s += step) {
    final e = math.min(x.length, s + step);
    double? m;
    // sub-sample within the bin: SpO2 changes slowly
    final inner = math.max(1, (e - s) ~/ 50);
    for (var i = s; i < e; i += inner) {
      final v = x[i] * factor;
      if (!v.isFinite || v < 50 || v > 100.5) continue;
      if (m == null || v < m) m = v;
    }
    out.add(m);
  }
  return out;
}

class OvernightTimelineDialog extends StatefulWidget {
  const OvernightTimelineDialog({
    super.key,
    required this.title,
    required this.stages,
    required this.epochSeconds,
    required this.rows,
    required this.currentEpoch,
    required this.onJump,
    this.spo2,
    this.spo2StepSeconds = 10,
    this.recordingStart,
  });

  final String title;
  final List<SleepStage> stages;
  final int epochSeconds;
  final List<TimelineRow> rows;
  final int currentEpoch;

  /// Jump the viewer to an epoch (0-based).
  final ValueChanged<int> onJump;
  final List<double?>? spo2;
  final double spo2StepSeconds;
  final DateTime? recordingStart;

  @override
  State<OvernightTimelineDialog> createState() => _OvernightTimelineDialogState();
}

class _OvernightTimelineDialogState extends State<OvernightTimelineDialog> {
  late int _epoch = widget.currentEpoch;
  double? _hoverSec;

  double get _total => math.max(1.0, widget.stages.length * widget.epochSeconds.toDouble());

  String _timeText(double sec) {
    final t = sec.round();
    final rel =
        '${(t ~/ 3600).toString().padLeft(2, '0')}:${((t % 3600) ~/ 60).toString().padLeft(2, '0')}:${(t % 60).toString().padLeft(2, '0')}';
    final start = widget.recordingStart;
    if (start == null) return rel;
    final c = start.add(Duration(seconds: t));
    return '$rel  (${c.hour.toString().padLeft(2, '0')}:${c.minute.toString().padLeft(2, '0')}:${c.second.toString().padLeft(2, '0')})';
  }

  String _hoverText() {
    final s = _hoverSec;
    if (s == null) {
      return 'Click to go to that epoch (double-click to go and close). '
          'Current epoch ${_epoch + 1}.';
    }
    final ep = (s / widget.epochSeconds).floor().clamp(0, math.max(0, widget.stages.length - 1)).toInt();
    final stage = ep < widget.stages.length ? widget.stages[ep].label : '—';
    final here = [
      for (final r in widget.rows)
        if (r.spans.any((p) => p.$1 <= s && s <= p.$2)) r.label,
    ];
    return 'Epoch ${ep + 1} · ${_timeText(s)} · $stage'
        '${here.isEmpty ? '' : ' · ${here.join(', ')}'}';
  }

  double _secAt(Offset local, Size size) {
    final w = size.width - OvernightTimelinePainter.leftPad - OvernightTimelinePainter.rightPad;
    final f = ((local.dx - OvernightTimelinePainter.leftPad) / w).clamp(0.0, 1.0);
    return f * _total;
  }

  void _jumpTo(double sec) {
    final int ep = (sec / widget.epochSeconds).floor().clamp(0, math.max(0, widget.stages.length - 1)).toInt();
    setState(() => _epoch = ep);
    widget.onJump(ep);
  }

  @override
  Widget build(BuildContext context) {
    final height = OvernightTimelinePainter.heightFor(widget.rows.length, widget.spo2 != null);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1500),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              Text(_hoverText(), style: const TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: LayoutBuilder(
                    builder: (context, c) {
                      final size = Size(c.maxWidth, height);
                      return MouseRegion(
                        cursor: SystemMouseCursors.click,
                        onHover: (e) => setState(() => _hoverSec = _secAt(e.localPosition, size)),
                        onExit: (_) => setState(() => _hoverSec = null),
                        child: GestureDetector(
                          onTapUp: (d) => _jumpTo(_secAt(d.localPosition, size)),
                          onDoubleTapDown: (d) => _jumpTo(_secAt(d.localPosition, size)),
                          onDoubleTap: () => Navigator.of(context).pop(),
                          child: CustomPaint(
                            size: size,
                            painter: OvernightTimelinePainter(
                              stages: widget.stages,
                              epochSeconds: widget.epochSeconds,
                              rows: widget.rows,
                              spo2: widget.spo2,
                              spo2StepSeconds: widget.spo2StepSeconds,
                              currentEpoch: _epoch,
                              hoverSec: _hoverSec,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class OvernightTimelinePainter extends CustomPainter {
  OvernightTimelinePainter({
    required this.stages,
    required this.epochSeconds,
    required this.rows,
    required this.spo2,
    required this.spo2StepSeconds,
    required this.currentEpoch,
    this.hoverSec,
  });

  final List<SleepStage> stages;
  final int epochSeconds;
  final List<TimelineRow> rows;
  final List<double?>? spo2;
  final double spo2StepSeconds;
  final int currentEpoch;
  final double? hoverSec;

  static const leftPad = 70.0;
  static const rightPad = 40.0;
  static const _stageRowH = 22.0;
  static const _axisH = 22.0;
  static const _eventRowH = 16.0;
  static const _spo2H = 120.0;
  static const _gap = 10.0;

  static const _stageOrder = [
    SleepStage.wake,
    SleepStage.rem,
    SleepStage.n1,
    SleepStage.n2,
    SleepStage.n3,
  ];

  static double heightFor(int rowCount, bool hasSpo2) =>
      _stageOrder.length * _stageRowH +
      _axisH +
      rowCount * _eventRowH +
      (hasSpo2 ? _gap + _spo2H + 14 : 0) +
      6;

  void _text(Canvas c, String s, Offset at, {double size = 11, Color color = Colors.black87, TextAlign align = TextAlign.right, FontWeight weight = FontWeight.w500}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color, fontWeight: weight)),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout();
    final dx = align == TextAlign.right ? at.dx - tp.width : (align == TextAlign.center ? at.dx - tp.width / 2 : at.dx);
    tp.paint(c, Offset(dx, at.dy - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final total = math.max(1.0, stages.length * epochSeconds.toDouble());
    final w = size.width - leftPad - rightPad;
    double xs(double sec) => leftPad + w * (sec / total).clamp(0.0, 1.0);
    final grid = Paint()
      ..color = const Color(0xFFE3E7EC)
      ..strokeWidth = 0.6;
    final bg = Paint()..color = const Color(0xFFF7F9FB);

    // Hypnogram: one lane per stage.
    var y = 0.0;
    canvas.drawRect(Rect.fromLTWH(leftPad, 0, w, _stageOrder.length * _stageRowH), bg);
    for (var k = 0; k < _stageOrder.length; k++) {
      final st = _stageOrder[k];
      final top = y + k * _stageRowH;
      _text(canvas, st == SleepStage.wake ? 'W' : st.label, Offset(leftPad - 8, top + _stageRowH / 2));
      canvas.drawLine(Offset(leftPad, top + _stageRowH), Offset(leftPad + w, top + _stageRowH), grid);
      final paint = Paint()..color = hypnogramStageColor(st);
      var i = 0;
      while (i < stages.length) {
        if (stages[i] != st) {
          i++;
          continue;
        }
        var j = i;
        while (j + 1 < stages.length && stages[j + 1] == st) {
          j++;
        }
        final x1 = xs(i * epochSeconds.toDouble());
        final x2 = xs((j + 1) * epochSeconds.toDouble());
        canvas.drawRect(Rect.fromLTRB(x1, top + 2, math.max(x1 + 0.8, x2), top + _stageRowH - 2), paint);
        i = j + 1;
      }
    }
    y += _stageOrder.length * _stageRowH;

    // Hour axis
    final hours = (total / 3600).floor();
    for (var h = 1; h <= hours; h++) {
      final x = xs(h * 3600.0);
      canvas.drawLine(Offset(x, y), Offset(x, y + 4), Paint()..color = Colors.black54);
      _text(canvas, '${h}h', Offset(x, y + 13), size: 11, align: TextAlign.center, color: Colors.black54);
    }
    y += _axisH;

    // Event rows
    for (final r in rows) {
      _text(canvas, r.label, Offset(leftPad - 8, y + _eventRowH / 2), size: 10.5, color: r.color.withOpacity(0.95));
      canvas.drawLine(Offset(leftPad, y + _eventRowH / 2), Offset(leftPad + w, y + _eventRowH / 2), grid);
      final p = Paint()..color = r.color;
      for (final (a, b) in r.spans) {
        final x1 = xs(a);
        final x2 = xs(b);
        canvas.drawRect(Rect.fromLTRB(x1, y + 3, math.max(x1 + 1.0, x2), y + _eventRowH - 3), p);
      }
      y += _eventRowH;
    }

    // SpO2 trend
    final sp = spo2;
    if (sp != null) {
      y += _gap;
      final present = sp.whereType<double>().toList();
      final lo = present.isEmpty ? 80.0 : math.min(88.0, (present.reduce(math.min) / 5).floor() * 5.0);
      const hi = 100.0;
      double ys(double v) => y + _spo2H * (1 - (v.clamp(lo, hi) - lo) / (hi - lo));
      canvas.drawRect(Rect.fromLTWH(leftPad, y, w, _spo2H), bg);
      _text(canvas, 'SpO2', Offset(leftPad - 8, y + 10), size: 11, weight: FontWeight.w600);
      _text(canvas, '${hi.toStringAsFixed(0)}%', Offset(leftPad - 8, y + 26), size: 10, color: Colors.black54);
      _text(canvas, '${lo.toStringAsFixed(0)}%', Offset(leftPad - 8, y + _spo2H - 6), size: 10, color: Colors.black54);
      for (final ref in [90.0, 80.0]) {
        if (ref <= lo) continue;
        canvas.drawLine(
          Offset(leftPad, ys(ref)),
          Offset(leftPad + w, ys(ref)),
          Paint()
            ..color = (ref == 90 ? Colors.red : Colors.orange).withOpacity(0.6)
            ..strokeWidth = 0.7,
        );
        _text(canvas, '${ref.toStringAsFixed(0)}%', Offset(leftPad + w + 4, ys(ref)), size: 10, align: TextAlign.left, color: ref == 90 ? Colors.red : Colors.orange);
      }
      final line = Paint()
        ..color = const Color(0xFF00838F)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke;
      var path = Path();
      var open = false;
      for (var i = 0; i < sp.length; i++) {
        final v = sp[i];
        if (v == null) {
          if (open) canvas.drawPath(path, line);
          path = Path();
          open = false;
          continue;
        }
        final x = xs((i + 0.5) * spo2StepSeconds);
        if (!open) {
          path.moveTo(x, ys(v));
          open = true;
        } else {
          path.lineTo(x, ys(v));
        }
      }
      if (open) canvas.drawPath(path, line);
      y += _spo2H;
    }

    // Current epoch and hover cursor
    final cx = xs((currentEpoch + 0.5) * epochSeconds.toDouble());
    canvas.drawLine(
      Offset(cx, 0),
      Offset(cx, y),
      Paint()
        ..color = Colors.black
        ..strokeWidth = 1.4,
    );
    final h = hoverSec;
    if (h != null) {
      final hx = xs(h);
      canvas.drawLine(
        Offset(hx, 0),
        Offset(hx, y),
        Paint()
          ..color = Colors.indigo.withOpacity(0.45)
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(covariant OvernightTimelinePainter old) =>
      old.currentEpoch != currentEpoch ||
      old.hoverSec != hoverSec ||
      !identical(old.rows, rows) ||
      !identical(old.stages, stages) ||
      !identical(old.spo2, spo2);
}
