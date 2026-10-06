// Multi-camera video synchronised to the EEG time axis.
//
// * One media_kit (libmpv) player per camera, so MPEG-TS (.m2t) files from
//   Nihon Kohden systems play on macOS, Windows and Linux (AVFoundation, used
//   by video_player on macOS, cannot open transport streams — the black
//   picture seen in v1.23).
// * Each camera is a list of time-stamped files (from the .VF2 index). The
//   controller keeps one master clock in EEG seconds and opens / seeks the
//   right file of every camera for that time, including across file
//   boundaries and gaps.
// * The panel is a floating window: drag the title bar to move it, drag the
//   bottom-right corner to resize it.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'nihon_kohden.dart';

class _CameraPlayback {
  _CameraPlayback(this.camera, {required this.muted}) {
    player = Player();
    controller = VideoController(player);
    // Frame-accurate seeks (mpv "hr-seek"); ignored if unavailable.
    unawaited(() async {
      try {
        final platform = player.platform;
        if (platform != null) {
          await (platform as dynamic).setProperty('hr-seek', 'yes');
        }
      } catch (_) {}
    }());
    unawaited(player.setVolume(muted ? 0 : 100));
    _errorSub = player.stream.error.listen((e) {
      if (e.toString().trim().isNotEmpty) error = e.toString();
    });
  }

  final VideoCamera camera;
  late final Player player;
  late final VideoController controller;
  StreamSubscription<dynamic>? _errorSub;

  bool enabled = true;
  bool muted;
  int loadedSegment = -1;
  String? message;
  String? error;

  bool busy = false;
  double? pendingTarget;
  bool pendingForce = false;
  DateTime lastSeek = DateTime.fromMillisecondsSinceEpoch(0);

  String get currentFileName {
    if (loadedSegment < 0 || loadedSegment >= camera.segments.length) return '';
    final parts = camera.segments[loadedSegment].fileName.split(RegExp(r'[\\/]'));
    return parts.last;
  }

  Future<void> dispose() async {
    await _errorSub?.cancel();
    await player.dispose();
  }
}

/// Master clock + per-camera players. Time is always seconds from the start
/// of the EEG recording.
class VideoSyncController extends ChangeNotifier {
  VideoSyncController({
    required List<VideoCamera> cameras,
    required this.durationSec,
    this.recordingStart,
    this.sourceLabel = '',
    this.onTime,
  }) : _cams = [
          for (var i = 0; i < cameras.length; i++)
            _CameraPlayback(cameras[i], muted: i != 0),
        ];

  final double durationSec;
  final DateTime? recordingStart;
  final String sourceLabel;

  /// Called whenever the video time changes (ticks while playing, seeks).
  void Function(double sec)? onTime;

  final List<_CameraPlayback> _cams;
  double _pos = 0;
  bool _playing = false;
  double _rate = 1.0;
  final Stopwatch _sw = Stopwatch();
  double _swBase = 0;
  Timer? _timer;
  bool _disposed = false;
  bool _stopped = false;

  int get cameraCount => _cams.length;
  VideoCamera camera(int i) => _cams[i].camera;
  bool get playing => _playing;
  bool get stopped => _stopped;
  double get rate => _rate;
  List<VideoCamera> get cameras => [for (final c in _cams) c.camera];

  double get position {
    if (!_playing) return _pos;
    final t = _swBase + _sw.elapsedMicroseconds / 1e6 * _rate;
    return t.clamp(0.0, durationSec).toDouble();
  }

  // ── Transport ─────────────────────────────────────────────────────────────

  void seek(double sec) {
    if (_disposed) return;
    _pos = sec.clamp(0.0, durationSec).toDouble();
    if (_playing) {
      _swBase = _pos;
      _sw
        ..reset()
        ..start();
    }
    for (final c in _cams) {
      if (c.enabled && !_stopped) _request(c, _pos, force: true);
    }
    notifyListeners();
    onTime?.call(_pos);
  }

  void play() {
    if (_disposed || _playing) return;
    if (_pos >= durationSec - 0.05) _pos = 0;
    _stopped = false;
    _playing = true;
    _swBase = _pos;
    _sw
      ..reset()
      ..start();
    for (final c in _cams) {
      if (c.enabled) _request(c, _pos, force: true);
    }
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) => _tick());
    notifyListeners();
  }

  void pause() {
    if (_disposed || !_playing) return;
    _pos = position;
    _playing = false;
    _sw.stop();
    _timer?.cancel();
    _timer = null;
    for (final c in _cams) {
      unawaited(c.player.pause());
    }
    notifyListeners();
    onTime?.call(_pos);
  }

  void togglePlay() => _playing ? pause() : play();

  /// Stops playback completely: pauses, unloads every file and releases the
  /// decoders. The cursor stays where it is; Play starts again from there.
  Future<void> stop() async {
    if (_disposed) return;
    pause();
    _stopped = true;
    for (final c in _cams) {
      c.pendingTarget = null;
      c.loadedSegment = -1;
      c.message = 'Stopped';
      try {
        await c.player.stop();
      } catch (_) {}
    }
    _notify();
  }

  void setRate(double r) {
    if (_disposed) return;
    final t = position;
    _rate = r;
    if (_playing) {
      _swBase = t;
      _sw
        ..reset()
        ..start();
    }
    for (final c in _cams) {
      unawaited(c.player.setRate(r));
    }
    notifyListeners();
  }

  void step(double deltaSec) => seek(position + deltaSec);

  // ── Per-camera settings ───────────────────────────────────────────────────

  bool cameraEnabled(int i) => _cams[i].enabled;
  bool cameraMuted(int i) => _cams[i].muted;
  String? cameraMessage(int i) => _cams[i].error ?? _cams[i].message;
  String cameraFile(int i) => _cams[i].currentFileName;
  VideoController cameraController(int i) => _cams[i].controller;

  void setCameraEnabled(int i, bool enabled) {
    final c = _cams[i];
    c.enabled = enabled;
    if (!enabled) {
      c.pendingTarget = null;
      c.loadedSegment = -1;
      unawaited(c.player.stop());
    } else if (!_stopped) {
      _request(c, position, force: true);
    }
    notifyListeners();
  }

  void setCameraMuted(int i, bool muted) {
    _cams[i].muted = muted;
    unawaited(_cams[i].player.setVolume(muted ? 0 : 100));
    notifyListeners();
  }

  void setCameraOffset(int i, double offsetSec) {
    _cams[i].camera.offsetSec = offsetSec;
    if (_cams[i].enabled && !_stopped) _request(_cams[i], position, force: true);
    notifyListeners();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ── Sync engine ───────────────────────────────────────────────────────────

  void _tick() {
    if (_disposed || !_playing) return;
    final t = position;
    if (t >= durationSec) {
      pause();
      return;
    }
    for (final c in _cams) {
      if (c.enabled) _request(c, t);
    }
    notifyListeners();
    onTime?.call(t);
  }

  /// Queues a sync of camera [c] to EEG time [t]; only the latest request is
  /// applied while a file is opening or seeking.
  void _request(_CameraPlayback c, double t, {bool force = false}) {
    c.pendingTarget = t;
    c.pendingForce = c.pendingForce || force;
    if (c.busy) return;
    c.busy = true;
    unawaited(() async {
      try {
        while (!_disposed && c.pendingTarget != null) {
          final target = c.pendingTarget!;
          final f = c.pendingForce;
          c.pendingTarget = null;
          c.pendingForce = false;
          // While playing, the clock has moved on during a slow open/seek.
          await _apply(c, _playing ? position : target, f);
        }
      } catch (e) {
        c.error = e.toString();
      } finally {
        c.busy = false;
        _notify();
      }
    }());
  }

  Future<void> _apply(_CameraPlayback c, double t, bool force) async {
    if (!c.enabled || _stopped) return;
    final idx = c.camera.segmentIndexAt(t);
    if (idx < 0) {
      if (c.player.state.playing) await c.player.pause();
      c.message = 'No video at this time';
      return;
    }
    final seg = c.camera.segments[idx];
    if (!seg.available) {
      if (c.loadedSegment != -1) {
        await c.player.stop();
        c.loadedSegment = -1;
      }
      c.message = 'File not found: ${seg.fileName.split(RegExp(r'[\\/]')).last}';
      return;
    }

    if (c.loadedSegment != idx) {
      c.message = 'Loading ${seg.fileName.split(RegExp(r'[\\/]')).last}…';
      c.error = null;
      _notify();
      final ready = c.player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 10))
          .catchError((Object _) => Duration.zero);
      await c.player.open(Media(seg.path!), play: false);
      await ready;
      if (_disposed) return;
      c.loadedSegment = idx;
      await c.player.setVolume(c.muted ? 0 : 100);
      if (_rate != 1.0) await c.player.setRate(_rate);
      force = true;
    }
    c.message = null;

    // Re-read the clock: opening a file can take a moment.
    final now = _playing ? position : t;
    final local = math.max(0.0, now + c.camera.offsetSec - seg.startSec);
    final cur = c.player.state.position.inMicroseconds / 1e6;
    final sinceSeek = DateTime.now().difference(c.lastSeek);
    final drift = (cur - local).abs();
    if (force || (sinceSeek > const Duration(milliseconds: 1500) && drift > 0.6)) {
      await c.player.seek(Duration(microseconds: (local * 1e6).round()));
      c.lastSeek = DateTime.now();
    }
    if (_playing && !c.player.state.playing) {
      await c.player.play();
    } else if (!_playing && c.player.state.playing) {
      await c.player.pause();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    for (final c in _cams) {
      unawaited(c.dispose());
    }
    super.dispose();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Floating panel
// ─────────────────────────────────────────────────────────────────────────────

String formatVideoClock(double seconds, {DateTime? start}) {
  if (start != null) {
    final t = start.add(Duration(milliseconds: (seconds * 1000).round()));
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
  final s = seconds.floor();
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
}

class SyncedVideoPanel extends StatefulWidget {
  const SyncedVideoPanel({
    super.key,
    required this.sync,
    required this.onClose,
    required this.onMove,
    required this.onResize,
    this.onAddVideo,
    this.epochStartSec,
    this.isClockTime = false,
    this.timeUnit = 'Elapsed',
  });

  final VideoSyncController sync;
  final VoidCallback onClose;
  final ValueChanged<Offset> onMove;
  final ValueChanged<Offset> onResize;
  final VoidCallback? onAddVideo;

  /// Start of the epoch on screen, for the "go to epoch start" button.
  final double? epochStartSec;

  /// Whether the host window is displaying clock time or elapsed time.
  final bool isClockTime;

  /// Time unit matching the EEG panel: 'Clock time', 'Seconds', 'Minutes', 'Hours'
  final String timeUnit;

  @override
  State<SyncedVideoPanel> createState() => _SyncedVideoPanelState();
}

class _SyncedVideoPanelState extends State<SyncedVideoPanel> {
  int? _solo; // show a single camera
  double? _scrubValue;
  Timer? _scrubThrottleTimer;
  double? _pendingScrubTarget;

  @override
  void dispose() {
    _scrubThrottleTimer?.cancel();
    super.dispose();
  }

  static const _bg = Color(0xFF1E293B);
  static const _bgDark = Color(0xFF0F172A);
  static const _accent = Color(0xFF38BDF8);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.sync,
      builder: (context, _) {
        final s = widget.sync;
        return Material(
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: _bg,
              border: Border.all(color: const Color(0xFF475569)),
              borderRadius: BorderRadius.circular(8),
              boxShadow: const [
                BoxShadow(color: Colors.black38, blurRadius: 10, offset: Offset(0, 4)),
              ],
            ),
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(s),
                    Expanded(child: _cameraGrid(s)),
                    _scrubber(s),
                    _controls(s),
                  ],
                ),
                // Resize handle (bottom-right corner)
                Positioned(
                  right: 0,
                  bottom: 0,
                  width: 18,
                  height: 18,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeDownRight,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (d) => widget.onResize(d.delta),
                      child: const Align(
                        alignment: Alignment.bottomRight,
                        child: Icon(Icons.south_east, size: 13, color: Colors.white38),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _header(VideoSyncController s) {
    final n = s.cameraCount;
    return MouseRegion(
      cursor: SystemMouseCursors.move,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => widget.onMove(d.delta),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: const BoxDecoration(
            color: _bgDark,
            borderRadius: BorderRadius.vertical(top: Radius.circular(7)),
          ),
          child: Row(
            children: [
              const Icon(Icons.drag_indicator, size: 14, color: Colors.white38),
              const SizedBox(width: 4),
              const Icon(Icons.videocam, size: 15, color: _accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${s.sourceLabel.isNotEmpty ? '${s.sourceLabel} · ' : ''}'
                  '$n camera${n == 1 ? '' : 's'}',
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.onAddVideo != null)
                _iconBtn(Icons.add, 'Add a video file as another camera', widget.onAddVideo!),
              if (_solo != null)
                _iconBtn(Icons.grid_view, 'Show all cameras', () => setState(() => _solo = null)),
              _iconBtn(Icons.close, 'Close video (stops and unloads all cameras)', widget.onClose),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, String tip, VoidCallback onTap, {Color color = Colors.white70, double size = 16}) {
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Icon(icon, size: size, color: color),
        ),
      ),
    );
  }

  Widget _cameraGrid(VideoSyncController s) {
    final indices = _solo != null && _solo! < s.cameraCount
        ? [_solo!]
        : [for (var i = 0; i < s.cameraCount; i++) i];
    return LayoutBuilder(
      builder: (context, c) {
        final n = indices.length;
        if (n == 0 || c.maxWidth <= 0 || c.maxHeight <= 0) return const SizedBox.shrink();
        // Pick the column count that gives the largest 16:9 tiles.
        var bestCols = 1;
        var bestArea = 0.0;
        for (var cols = 1; cols <= n; cols++) {
          final rows = (n / cols).ceil();
          var w = c.maxWidth / cols;
          var h = c.maxHeight / rows;
          if (w / h > 16 / 9) {
            w = h * 16 / 9;
          } else {
            h = w * 9 / 16;
          }
          if (w * h > bestArea) {
            bestArea = w * h;
            bestCols = cols;
          }
        }
        final rows = (n / bestCols).ceil();
        return Column(
          children: [
            for (var r = 0; r < rows; r++)
              Expanded(
                child: Row(
                  children: [
                    for (var k = 0; k < bestCols; k++)
                      Expanded(
                        child: r * bestCols + k < n
                            ? _cameraTile(s, indices[r * bestCols + k])
                            : const SizedBox.shrink(),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _cameraTile(VideoSyncController s, int i) {
    final cam = s.camera(i);
    final enabled = s.cameraEnabled(i);
    final msg = s.cameraMessage(i);
    return Padding(
      padding: const EdgeInsets.all(1.5),
      child: GestureDetector(
        onDoubleTap: () => setState(() => _solo = _solo == null ? i : null),
        child: Container(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (enabled)
                Video(
                  controller: s.cameraController(i),
                  controls: NoVideoControls,
                  fill: Colors.black,
                ),
              if (!enabled || msg != null)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      enabled ? msg! : 'Camera off',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white60, fontSize: 11),
                    ),
                  ),
                ),
              // Tile toolbar
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: Container(
                  color: Colors.black45,
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${cam.name}${s.cameraFile(i).isNotEmpty ? ' · ${s.cameraFile(i)}' : ''}',
                          style: const TextStyle(color: Colors.white, fontSize: 10),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (cam.offsetSec.abs() > 1e-6)
                        Text(
                          '${cam.offsetSec >= 0 ? '+' : ''}${cam.offsetSec.toStringAsFixed(2)}s',
                          style: const TextStyle(color: Color(0xFFFBBF24), fontSize: 10),
                        ),
                      _iconBtn(
                        s.cameraMuted(i) ? Icons.volume_off : Icons.volume_up,
                        s.cameraMuted(i) ? 'Unmute' : 'Mute',
                        () => s.setCameraMuted(i, !s.cameraMuted(i)),
                        size: 13,
                      ),
                      _offsetMenu(s, i),
                      _iconBtn(
                        enabled ? Icons.videocam : Icons.videocam_off,
                        enabled ? 'Turn this camera off' : 'Turn this camera on',
                        () => s.setCameraEnabled(i, !enabled),
                        size: 13,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _offsetMenu(VideoSyncController s, int i) {
    final cam = s.camera(i);
    return PopupMenuButton<double>(
      tooltip: 'Sync offset for ${cam.name}',
      padding: EdgeInsets.zero,
      iconSize: 13,
      icon: const Icon(Icons.tune, size: 13, color: Colors.white70),
      onSelected: (delta) {
        s.setCameraOffset(i, delta.isNaN ? 0.0 : cam.offsetSec + delta);
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          enabled: false,
          child: Text('Offset ${cam.offsetSec.toStringAsFixed(2)} s  (+ shows later video)'),
        ),
        for (final d in const [-1.0, -0.1, -0.04, 0.04, 0.1, 1.0])
          PopupMenuItem(value: d, child: Text('${d > 0 ? '+' : ''}${d.toStringAsFixed(2)} s')),
        const PopupMenuItem(value: double.nan, child: Text('Reset to 0')),
      ],
    );
  }

  Widget _scrubber(VideoSyncController s) {
    final dur = math.max(1.0, s.durationSec);
    final value = (_scrubValue ?? s.position).clamp(0.0, dur).toDouble();
    return SizedBox(
      height: 22,
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 2.5,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
          activeTrackColor: _accent,
          inactiveTrackColor: Colors.white24,
          thumbColor: Colors.white,
        ),
        child: Slider(
          value: value,
          min: 0,
          max: dur,
          onChangeStart: (v) {
            setState(() => _scrubValue = v);
          },
          onChanged: (v) {
            setState(() => _scrubValue = v);
            _pendingScrubTarget = v;
            if (_scrubThrottleTimer == null || !_scrubThrottleTimer!.isActive) {
              s.seek(v);
              _scrubThrottleTimer = Timer(const Duration(milliseconds: 60), () {
                if (_pendingScrubTarget != null && _scrubValue != null) {
                  s.seek(_pendingScrubTarget!);
                }
              });
            }
          },
          onChangeEnd: (v) {
            _scrubThrottleTimer?.cancel();
            _pendingScrubTarget = null;
            setState(() => _scrubValue = null);
            s.seek(v);
          },
        ),
      ),
    );
  }

  Widget _controls(VideoSyncController s) {
    final t = s.position;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 2, 20, 6),
      decoration: const BoxDecoration(
        color: _bgDark,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(7)),
      ),
      child: Row(
        children: [
          _iconBtn(Icons.replay_5, 'Back 5 s', () => s.step(-5), size: 18),
          _iconBtn(
            s.playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
            s.playing ? 'Pause' : 'Play (waveform follows the video)',
            s.togglePlay,
            color: Colors.white,
            size: 26,
          ),
          _iconBtn(Icons.stop_circle, 'Stop (unload video)', () => unawaited(s.stop()), color: Colors.white, size: 24),
          _iconBtn(Icons.forward_5, 'Forward 5 s', () => s.step(5), size: 18),
          if (widget.epochStartSec != null)
            _iconBtn(Icons.vertical_align_center, 'Go to start of the current epoch',
                () => s.seek(widget.epochStartSec!), size: 17),
          const SizedBox(width: 4),
          PopupMenuButton<double>(
            tooltip: 'Playback speed',
            initialValue: s.rate,
            onSelected: s.setRate,
            itemBuilder: (_) => [
              for (final r in const [0.25, 0.5, 1.0, 1.5, 2.0, 4.0])
                PopupMenuItem(value: r, child: Text('${r}x')),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('${s.rate}x', style: const TextStyle(color: Colors.white70, fontSize: 11)),
            ),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              () {
                if (widget.isClockTime && s.recordingStart != null) {
                  return '${formatVideoClock(t, start: s.recordingStart)}  (${formatVideoClock(t)})';
                }
                if (widget.timeUnit == 'Seconds') {
                  return '${t.round()}s / ${s.durationSec.round()}s';
                }
                if (widget.timeUnit == 'Minutes') {
                  return '${(t / 60.0).toStringAsFixed(1)}m / ${(s.durationSec / 60.0).toStringAsFixed(1)}m';
                }
                if (widget.timeUnit == 'Hours') {
                  return '${(t / 3600.0).toStringAsFixed(2)}h / ${(s.durationSec / 3600.0).toStringAsFixed(2)}h';
                }
                return '${formatVideoClock(t)} / ${formatVideoClock(s.durationSec)}';
              }(),
              style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
