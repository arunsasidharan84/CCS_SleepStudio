import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'group_statistics_engine.dart';

/// Interactive publication-grade Box-and-Whisker & Strip Plot widget rendered directly in Flutter.
class GroupStatsBoxplotWidget extends StatelessWidget {
  const GroupStatsBoxplotWidget({
    super.key,
    required this.metric,
    this.unit = '',
    required this.descriptives,
    required this.posthocs,
  });

  final String metric;
  final String unit;
  final List<Map<String, dynamic>> descriptives;
  final List<Map<String, dynamic>> posthocs;

  @override
  Widget build(BuildContext context) {
    if (descriptives.isEmpty) {
      return const Center(child: Padding(padding: EdgeInsets.all(32), child: Text('No observations to plot.')));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final plotWidth = constraints.maxWidth;
        final plotHeight = 440.0;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
                boxShadow: const [
                  BoxShadow(color: Color(0x0A000000), blurRadius: 4, offset: Offset(0, 1)),
                ],
              ),
              padding: const EdgeInsets.only(top: 16, bottom: 8, left: 12, right: 16),
              child: CustomPaint(
                size: Size(plotWidth, plotHeight),
                painter: _BoxplotPainter(
                  descriptives: descriptives,
                  posthocs: posthocs,
                  metric: metric,
                  unit: unit,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: [
                _buildLegendItem(const Color(0xFF1F4E79), 'Box (IQR: Q1–Q3)'),
                _buildLegendItem(Colors.black87, 'Median Line (—)'),
                _buildLegendItem(const Color(0xFFD32F2F), 'Mean Marker (▲)'),
                _buildLegendItem(Colors.grey.shade600, 'Observations (Jittered •)'),
                _buildLegendItem(const Color(0xFF16A34A), 'Sig Contrast (* p<0.05)'),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildLegendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.black87)),
      ],
    );
  }
}

class _BoxplotPainter extends CustomPainter {
  _BoxplotPainter({
    required this.descriptives,
    required this.posthocs,
    required this.metric,
    required this.unit,
  });

  final List<Map<String, dynamic>> descriptives;
  final List<Map<String, dynamic>> posthocs;
  final String metric;
  final String unit;

  static const List<Color> _palette = [
    Color(0xFF1F4E79),
    Color(0xFF2E7D32),
    Color(0xFFD32F2F),
    Color(0xFFE65100),
    Color(0xFF6A1B9A),
    Color(0xFF00838F),
    Color(0xFF4E342E),
    Color(0xFF37474F),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final nCells = descriptives.length;
    if (nCells == 0) return;

    // Determine value range
    var globalMin = double.infinity;
    var globalMax = -double.infinity;

    for (final d in descriptives) {
      final minVal = (d['min'] as num).toDouble();
      final maxVal = (d['max'] as num).toDouble();
      if (minVal < globalMin) globalMin = minVal;
      if (maxVal > globalMax) globalMax = maxVal;
    }

    if (globalMin == globalMax) {
      globalMin -= 1.0;
      globalMax += 1.0;
    }

    // Add padding (15% on top for significance brackets)
    final valRange = globalMax - globalMin;
    final yMin = globalMin - valRange * 0.05;
    final yMax = globalMax + valRange * 0.22;

    const marginLeft = 65.0;
    final marginRight = size.width - 20.0;
    const marginTop = 20.0;
    final marginBottom = size.height - 65.0;

    final plotWidth = marginRight - marginLeft;
    final plotHeight = marginBottom - marginTop;

    double mapY(double val) {
      final frac = (val - yMin) / (yMax - yMin);
      return marginBottom - frac * plotHeight;
    }

    // ─── 1. DRAW GRID & Y-AXIS ──────────────────────────────────
    final axisPaint = Paint()
      ..color = Colors.grey.shade400
      ..strokeWidth = 1.0;
    final gridPaint = Paint()
      ..color = Colors.grey.shade200
      ..strokeWidth = 0.8;

    // Y ticks (5 intervals)
    const numTicks = 5;
    for (var i = 0; i <= numTicks; i++) {
      final frac = i / numTicks;
      final val = yMin + frac * (yMax - yMin);
      final y = marginBottom - frac * plotHeight;

      canvas.drawLine(Offset(marginLeft, y), Offset(marginRight, y), gridPaint);
      canvas.drawLine(Offset(marginLeft - 4, y), Offset(marginLeft, y), axisPaint);

      final valStr = val.abs() >= 100 ? val.toStringAsFixed(0) : val.toStringAsFixed(1);
      final tp = TextPainter(
        text: TextSpan(text: valStr, style: TextStyle(fontSize: 10, color: Colors.grey.shade700)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(marginLeft - tp.width - 7, y - tp.height / 2));
    }

    // Y-axis label
    final yLabel = unit.isNotEmpty ? '$metric ($unit)' : metric;
    final yLabelPainter = TextPainter(
      text: TextSpan(
        text: yLabel,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF1F4E79)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    canvas.save();
    canvas.translate(14, marginTop + plotHeight / 2 + yLabelPainter.width / 2);
    canvas.rotate(-math.pi / 2);
    yLabelPainter.paint(canvas, Offset.zero);
    canvas.restore();

    // Axes lines
    canvas.drawLine(Offset(marginLeft, marginTop), Offset(marginLeft, marginBottom), axisPaint);
    canvas.drawLine(Offset(marginLeft, marginBottom), Offset(marginRight, marginBottom), axisPaint);

    // ─── 2. DRAW BOXES & DATA POINTS ───────────────────────────
    final cellWidth = plotWidth / nCells;
    final boxWidth = math.min(55.0, cellWidth * 0.55);

    final boxCenters = <double>[];

    for (var i = 0; i < nCells; i++) {
      final d = descriptives[i];
      final cx = marginLeft + (i + 0.5) * cellWidth;
      boxCenters.add(cx);

      final color = _palette[i % _palette.length];
      final q1 = (d['q1'] as num).toDouble();
      final q3 = (d['q3'] as num).toDouble();
      final median = (d['median'] as num).toDouble();
      final mean = (d['mean'] as num).toDouble();
      final minVal = (d['min'] as num).toDouble();
      final maxVal = (d['max'] as num).toDouble();
      final n = d['n'] as int;

      final yQ1 = mapY(q1);
      final yQ3 = mapY(q3);
      final yMedian = mapY(median);
      final yMean = mapY(mean);
      final yMinVal = mapY(minVal);
      final yMaxVal = mapY(maxVal);

      // Box Rect
      final boxRect = Rect.fromLTRB(cx - boxWidth / 2, yQ3, cx + boxWidth / 2, yQ1);

      // Box Fill
      final fillPaint = Paint()
        ..color = color.withOpacity(0.20)
        ..style = PaintingStyle.fill;
      canvas.drawRRect(RRect.fromRectAndRadius(boxRect, const Radius.circular(3)), fillPaint);

      // Box Outline
      final outlinePaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8;
      canvas.drawRRect(RRect.fromRectAndRadius(boxRect, const Radius.circular(3)), outlinePaint);

      // Median Line
      final medianPaint = Paint()
        ..color = Colors.black87
        ..strokeWidth = 2.4;
      canvas.drawLine(Offset(cx - boxWidth / 2, yMedian), Offset(cx + boxWidth / 2, yMedian), medianPaint);

      // Whiskers
      final whiskerPaint = Paint()
        ..color = color
        ..strokeWidth = 1.2;
      canvas.drawLine(Offset(cx, yQ3), Offset(cx, yMaxVal), whiskerPaint);
      canvas.drawLine(Offset(cx, yQ1), Offset(cx, yMinVal), whiskerPaint);

      // Whisker caps
      final capWidth = boxWidth * 0.4;
      canvas.drawLine(Offset(cx - capWidth / 2, yMaxVal), Offset(cx + capWidth / 2, yMaxVal), whiskerPaint);
      canvas.drawLine(Offset(cx - capWidth / 2, yMinVal), Offset(cx + capWidth / 2, yMinVal), whiskerPaint);

      // Jittered scatter points
      final rawVals = (d['raw_values'] as List<dynamic>? ?? []).map((e) => (e as num).toDouble()).toList();
      final pointPaint = Paint()
        ..color = color.withOpacity(0.55)
        ..style = PaintingStyle.fill;

      final rnd = math.Random(i * 42);
      for (final rv in rawVals) {
        final jitter = (rnd.nextDouble() - 0.5) * (boxWidth * 0.65);
        final py = mapY(rv);
        canvas.drawCircle(Offset(cx + jitter, py), 2.5, pointPaint);
      }

      // Mean indicator (triangle)
      final meanPath = Path()
        ..moveTo(cx, yMean - 5)
        ..lineTo(cx - 5, yMean + 4)
        ..lineTo(cx + 5, yMean + 4)
        ..close();
      canvas.drawPath(meanPath, Paint()..color = const Color(0xFFD32F2F));

      // X-axis label & sample size
      final grpLabel = d['subgroup'] != null ? '${d['group']}\n${d['subgroup']}' : '${d['group']}';
      final xLabelText = '$grpLabel\n(n=$n)';
      final xTp = TextPainter(
        text: TextSpan(
          text: xLabelText,
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black87, height: 1.15),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: cellWidth - 4);
      xTp.paint(canvas, Offset(cx - xTp.width / 2, marginBottom + 8));
    }

    // ─── 3. SIGNIFICANCE BRACKETS ──────────────────────────────
    final sigPosthocs = posthocs.where((p) => p['significant'] == true).take(3).toList();
    var bracketLevel = 0;

    for (final ph in sigPosthocs) {
      final grpA = ph['group_a'] as String;
      final grpB = ph['group_b'] as String;

      int idxA = descriptives.indexWhere((d) {
        final key = d['subgroup'] != null ? '${d['group']}|${d['subgroup']}' : d['group'];
        return key == grpA;
      });
      int idxB = descriptives.indexWhere((d) {
        final key = d['subgroup'] != null ? '${d['group']}|${d['subgroup']}' : d['group'];
        return key == grpB;
      });

      if (idxA < 0 || idxB < 0 || idxA == idxB) continue;
      if (idxA > idxB) {
        final t = idxA;
        idxA = idxB;
        idxB = t;
      }

      final x1 = boxCenters[idxA];
      final x2 = boxCenters[idxB];
      final bracketY = marginTop + 8 + bracketLevel * 22;

      final bracketPaint = Paint()
        ..color = const Color(0xFF16A34A)
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke;

      final path = Path()
        ..moveTo(x1, bracketY + 4)
        ..lineTo(x1, bracketY)
        ..lineTo(x2, bracketY)
        ..lineTo(x2, bracketY + 4);
      canvas.drawPath(path, bracketPaint);

      final pVal = (ph['p_fdr'] ?? ph['p_adj'] ?? 0.05) as double;
      final star = pVal < 0.001 ? '***' : (pVal < 0.01 ? '**' : '*');
      final starTp = TextPainter(
        text: TextSpan(
          text: star,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF16A34A)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      starTp.paint(canvas, Offset((x1 + x2) / 2 - starTp.width / 2, bracketY - starTp.height));

      bracketLevel++;
    }
  }

  @override
  bool shouldRepaint(covariant _BoxplotPainter oldDelegate) => true;
}

/// Interactive 10-20 Scalp Topoplot widget rendered natively in Flutter.
class GroupStatsTopoplotWidget extends StatefulWidget {
  const GroupStatsTopoplotWidget({
    super.key,
    required this.etfceChannels,
    this.posthocTopoplots = const [],
  });

  final List<Map<String, dynamic>> etfceChannels;
  final List<Map<String, dynamic>> posthocTopoplots;

  @override
  State<GroupStatsTopoplotWidget> createState() => _GroupStatsTopoplotWidgetState();
}

class _GroupStatsTopoplotWidgetState extends State<GroupStatsTopoplotWidget> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    if (widget.etfceChannels.isEmpty && widget.posthocTopoplots.isEmpty) {
      return const Center(child: Padding(padding: EdgeInsets.all(32), child: Text('No spatial channel data available.')));
    }

    final hasPostHocs = widget.posthocTopoplots.isNotEmpty;
    final List<Map<String, dynamic>> activeChannels;
    final String currentTitle;

    if (_selectedIndex == 0 || !hasPostHocs || _selectedIndex > widget.posthocTopoplots.length) {
      activeChannels = widget.etfceChannels;
      currentTitle = 'Omnibus / Spatial eTFCE Cluster Map (* p<0.05)';
    } else {
      final pair = widget.posthocTopoplots[_selectedIndex - 1];
      activeChannels = (pair['channels'] as List<dynamic>? ?? []).cast<Map<String, dynamic>>();
      currentTitle = 'Post-Hoc Contrast: ${pair['contrast']} (* p<0.05)';
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = math.min(constraints.maxWidth, 360.0);
        return Center(
          child: Column(
            children: [
              if (hasPostHocs) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  alignment: WrapAlignment.center,
                  children: [
                    ChoiceChip(
                      label: const Text('Omnibus eTFCE Map', style: TextStyle(fontSize: 11)),
                      selected: _selectedIndex == 0,
                      onSelected: (v) => setState(() => _selectedIndex = 0),
                    ),
                    for (var i = 0; i < widget.posthocTopoplots.length; i++)
                      ChoiceChip(
                        label: Text('Post-Hoc: ${widget.posthocTopoplots[i]['contrast']}', style: const TextStyle(fontSize: 11)),
                        selected: _selectedIndex == i + 1,
                        onSelected: (v) => setState(() => _selectedIndex = i + 1),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
              ],
              Text(
                currentTitle,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF1F4E79)),
              ),
              const SizedBox(height: 8),
              Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: const [
                    BoxShadow(color: Color(0x0F000000), blurRadius: 8, offset: Offset(0, 2)),
                  ],
                ),
                child: CustomPaint(
                  size: Size(size, size),
                  painter: _TopoplotPainter(etfceChannels: activeChannels),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                alignment: WrapAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(width: 14, height: 14, decoration: const BoxDecoration(color: Color(0xFFD32F2F), shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                      const Text('Positive Difference (+Δ)', style: TextStyle(fontSize: 11)),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(width: 14, height: 14, decoration: const BoxDecoration(color: Color(0xFF1F4E79), shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                      const Text('Negative Difference (-Δ)', style: TextStyle(fontSize: 11)),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0xFFF59E0B), width: 3),
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Text('Significant Channel (* p<0.05)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TopoplotPainter extends CustomPainter {
  _TopoplotPainter({required this.etfceChannels});

  final List<Map<String, dynamic>> etfceChannels;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width * 0.40;

    // Head outline circle
    final headPaint = Paint()
      ..color = Colors.grey.shade400
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, radius, headPaint);

    // Nose
    final nosePath = Path()
      ..moveTo(center.dx - 12, center.dy - radius + 2)
      ..lineTo(center.dx, center.dy - radius - 14)
      ..lineTo(center.dx + 12, center.dy - radius + 2);
    canvas.drawPath(nosePath, headPaint);

    // Ears
    final leftEar = Rect.fromCenter(center: Offset(center.dx - radius - 3, center.dy), width: 8, height: 26);
    final rightEar = Rect.fromCenter(center: Offset(center.dx + radius + 3, center.dy), width: 8, height: 26);
    canvas.drawOval(leftEar, headPaint);
    canvas.drawOval(rightEar, headPaint);

    // Find min and max t-stat
    var maxAbsT = 1.0;
    for (final ch in etfceChannels) {
      final t = ((ch['t_stat'] ?? 0.0) as num).abs().toDouble();
      if (t > maxAbsT) maxAbsT = t;
    }

    // Channel values map
    final chanMap = {
      for (final ch in etfceChannels)
        (ch['channel'] as String).toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), ''): ch
    };

    for (final entry in kElectrode1020Positions.entries) {
      final normName = entry.key.replaceAll(RegExp(r'[^A-Z0-9]'), '');
      final chData = chanMap[normName];

      final nx = entry.value.$1;
      final ny = entry.value.$2;

      // Map to canvas coordinates
      final px = center.dx + nx * radius * 0.92;
      final py = center.dy - ny * radius * 0.92;

      final tVal = chData != null ? ((chData['t_stat'] ?? 0.0) as num).toDouble() : 0.0;
      final isSig = chData != null && chData['significant'] == true;

      Color color;
      if (tVal > 0) {
        final frac = (tVal / maxAbsT).clamp(0.1, 1.0);
        color = Color.lerp(Colors.orange.shade200, const Color(0xFFD32F2F), frac)!;
      } else if (tVal < 0) {
        final frac = (tVal.abs() / maxAbsT).clamp(0.1, 1.0);
        color = Color.lerp(Colors.blue.shade200, const Color(0xFF1F4E79), frac)!;
      } else {
        color = Colors.grey.shade300;
      }

      // Outer highlight ring for significant channels
      if (isSig) {
        final sigRingPaint = Paint()
          ..color = const Color(0xFFF59E0B)
          ..strokeWidth = 3.0
          ..style = PaintingStyle.stroke;
        canvas.drawCircle(Offset(px, py), 15.0, sigRingPaint);
      }

      // Electrode disc
      canvas.drawCircle(Offset(px, py), 11.0, Paint()..color = color);
      canvas.drawCircle(Offset(px, py), 11.0, Paint()..color = Colors.black54..style = PaintingStyle.stroke..strokeWidth = 1.0);

      // Electrode name label
      final tp = TextPainter(
        text: TextSpan(
          text: entry.key,
          style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.white),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(px - tp.width / 2, py - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _TopoplotPainter oldDelegate) => true;
}
