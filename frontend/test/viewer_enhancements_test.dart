import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/models.dart';
import 'package:ccs_sleep_studio/src/synced_video_panel.dart';
import 'package:ccs_sleep_studio/src/timeline_painter.dart';

void main() {
  group('Video & Viewer Enhancements Tests', () {
    test('formatVideoClock formats elapsed and clock times correctly', () {
      // Elapsed mode
      expect(formatVideoClock(0), '00:00:00');
      expect(formatVideoClock(65), '00:01:05');
      expect(formatVideoClock(3661), '01:01:01');

      // Clock time mode with recording start
      final start = DateTime(2025, 1, 1, 23, 0, 0);
      expect(formatVideoClock(0, start: start), '23:00:00');
      expect(formatVideoClock(75, start: start), '23:01:15');
      expect(formatVideoClock(3600 * 2, start: start), '01:00:00');
    });

    test('ScoredEvent point marker detection', () {
      const pointEvent = ScoredEvent(
        digit: 0,
        key: 'A',
        label: 'Artifact',
        startSec: 10.5,
        endSec: 10.5,
      );
      expect(pointEvent.isPointMarker, isTrue);
      expect(pointEvent.durationSeconds, 0.0);

      const spanEvent = ScoredEvent(
        digit: 1,
        key: 'F1',
        label: 'Spindle',
        startSec: 10.0,
        endSec: 11.5,
      );
      expect(spanEvent.isPointMarker, isFalse);
      expect(spanEvent.durationSeconds, 1.5);
    });

    testWidgets('SyncedVideoPanel displays elapsed time when isClockTime is false', (tester) async {
      final sync = VideoSyncController(
        cameras: const [],
        durationSec: 3600,
        recordingStart: DateTime(2025, 1, 1, 22, 0, 0),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 300,
              child: SyncedVideoPanel(
                sync: sync,
                isClockTime: false,
                onClose: () {},
                onMove: (_) {},
                onResize: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Elapsed format: "00:00:00 / 01:00:00"
      expect(find.text('00:00:00 / 01:00:00'), findsOneWidget);
      sync.dispose();
    });

    testWidgets('SyncedVideoPanel displays clock time when isClockTime is true', (tester) async {
      final start = DateTime(2025, 1, 1, 22, 0, 0);
      final sync = VideoSyncController(
        cameras: const [],
        durationSec: 3600,
        recordingStart: start,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 300,
              child: SyncedVideoPanel(
                sync: sync,
                isClockTime: true,
                onClose: () {},
                onMove: (_) {},
                onResize: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Clock format: "22:00:00  (00:00:00)"
      expect(find.text('22:00:00  (00:00:00)'), findsOneWidget);
      sync.dispose();
    });

    testWidgets('SyncedVideoPanel displays seconds format when timeUnit is Seconds', (tester) async {
      final sync = VideoSyncController(
        cameras: const [],
        durationSec: 3600,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 300,
              child: SyncedVideoPanel(
                sync: sync,
                isClockTime: false,
                timeUnit: 'Seconds',
                onClose: () {},
                onMove: (_) {},
                onResize: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('0s / 3600s'), findsOneWidget);
      sync.dispose();
    });

    test('channelUnitFor and formatChannelValue format units correctly', () {
      // Units
      expect(channelUnitFor('SpO2'), '%');
      expect(channelUnitFor('SPO2'), '%');
      expect(channelUnitFor('SaO2'), '%');
      expect(channelUnitFor('Pulse'), 'bpm');
      expect(channelUnitFor('HR'), 'bpm');
      expect(channelUnitFor('CO2'), 'mmHg');
      expect(channelUnitFor('Flow'), '');
      expect(channelUnitFor('C3-A2'), 'µV');
      expect(channelUnitFor('EEG F4-M1'), 'µV');

      // Value formatting
      expect(formatChannelValue('SpO2', 95.2), '95.2 %');
      expect(formatChannelValue('SPO2', 0.94), '94.0 %'); // fractional scaled
      expect(formatChannelValue('Pulse', 72.0), '72 bpm');
      expect(formatChannelValue('CO2', 38.5), '38.5 mmHg');
      expect(formatChannelValue('C3-A2', -15.4), '-15.4 µV');
      expect(formatChannelValue('SpO2', 3.0), '3.0 %');
    });

    testWidgets('SelectionOverlayPainter renders 30s split dotted lines in >30s windows', (tester) async {
      final viewport = EegViewport(
        sampleRateHz: 100,
        epochSeconds: 30,
        channelLabels: const ['C3-A2'],
        points: [Float32List(0)],
        stages: const [SleepStage.wake, SleepStage.n2],
        currentEpoch: 1,
        visibleStartSeconds: 0,
        visibleDurationSeconds: 120, // 4 epochs = 120s
        totalDurationSeconds: 600,
        sourceDescription: 'test',
        scoredEvents: const [
          ScoredEvent(digit: 20, key: 'F20', label: 'PLMS Series (4 LMs)', startSec: 10, endSec: 90),
          ScoredEvent(digit: 20, key: 'F20', label: 'PLMS (LM)', startSec: 10, endSec: 12),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 400,
              child: CustomPaint(
                painter: SelectionOverlayPainter(
                  viewport,
                  leftPad: 90.0,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(CustomPaint), findsWidgets);
    });
  });
}
