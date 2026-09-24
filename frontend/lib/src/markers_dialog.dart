import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'models.dart';

Color _eventColor(int digit) {
  const colors = [
    Color(0xFFE53935), // 0 Red
    Color(0xFF1E88E5), // 1 Blue
    Color(0xFF43A047), // 2 Green
    Color(0xFFFB8C00), // 3 Orange
    Color(0xFF8E24AA), // 4 Purple
    Color(0xFF00ACC1), // 5 Cyan
    Color(0xFFFDD835), // 6 Yellow
    Color(0xFFD81B60), // 7 Pink
    Color(0xFF3949AB), // 8 Indigo
    Color(0xFF00897B), // 9 Teal
    Color(0xFFBCBD22), // 10
    Color(0xFFFFA500), // 11
    Color(0xFF4B0082), // 12
    Color(0xFFC62828), // 13 Obstructive apnea
    Color(0xFF1565C0), // 14 Central apnea
    Color(0xFF6A1B9A), // 15 Mixed apnea
    Color(0xFFEF6C00), // 16 Hypopnea
    Color(0xFFF9A825), // 17 RERA
    Color(0xFF0097A7), // 18 Desaturation
    Color(0xFF7CB342), // 19 Leg movement
    Color(0xFF1B5E20), // 20 PLM
    Color(0xFF03A9F4), // 21 CAP A1
    Color(0xFFFF9800), // 22 CAP A2
    Color(0xFFE91E63), // 23 CAP A3
    Color(0xFF795548), // 24 CAP sequence
  ];
  return colors[digit.clamp(0, colors.length - 1)];
}

class MarkersDialog extends StatefulWidget {
  const MarkersDialog({
    super.key,
    required this.events,
    required this.disabledLabels,
    required this.epochSeconds,
    required this.epochCount,
    this.recordingStartTime,
    this.customEventNames,
    this.onUpdateEventNames,
    required this.onToggleLabel,
    required this.onSetAllLabels,
    required this.onJumpToEvent,
  });

  final List<ScoredEvent> events;
  final Set<String> disabledLabels;
  final int epochSeconds;
  final int epochCount;
  final DateTime? recordingStartTime;
  final Map<int, String>? customEventNames;
  final void Function(Map<int, String> newNames)? onUpdateEventNames;
  final void Function(String label, bool visible) onToggleLabel;
  final void Function(bool selectAll) onSetAllLabels;
  final void Function(ScoredEvent event) onJumpToEvent;

  @override
  State<MarkersDialog> createState() => _MarkersDialogState();
}

class _MarkersDialogState extends State<MarkersDialog> {
  String _searchQuery = '';
  late Set<String> _localDisabledLabels;

  @override
  void initState() {
    super.initState();
    _localDisabledLabels = Set<String>.from(widget.disabledLabels);
  }

  String _formatElapsed(double seconds) {
    final s = seconds.toInt();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    final dec = ((seconds - s) * 10).toInt();
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}.${dec}s';
  }

  String _formatClock(double seconds) {
    if (widget.recordingStartTime == null) return _formatElapsed(seconds);
    final dt = widget.recordingStartTime!.add(Duration(milliseconds: (seconds * 1000).round()));
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }

  Future<void> _showEditEventNamesDialog(BuildContext context) async {
    final controllers = <int, TextEditingController>{};
    const defaults = <int, String>{
      0: 'Artifact',
      1: 'Event 1',
      2: 'Event 2',
      3: 'Event 3',
      4: 'Event 4',
      5: 'Event 5',
      6: 'Event 6',
      7: 'Event 7',
      8: 'Event 8',
    };
    const shortcuts = <int, String>{
      0: 'A',
      1: 'F1',
      2: 'F2',
      3: 'F3',
      4: 'F4',
      5: 'F5',
      6: 'F6',
      7: 'F7',
      8: 'F8',
    };

    for (var i = 0; i <= 8; i++) {
      final curName = widget.customEventNames?[i] ?? defaults[i]!;
      controllers[i] = TextEditingController(text: curName);
    }

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.label_outline, color: Color(0xFF1E88E5)),
            SizedBox(width: 8),
            Text('Custom Event Names', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Name your event types. These will appear in the application menus, shortcuts, and event overlays.',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 12),
                for (var i = 0; i <= 8; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Container(
                          width: 34,
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          decoration: BoxDecoration(
                            color: _eventColor(i).withOpacity(0.2),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: _eventColor(i), width: 1.0),
                          ),
                          child: Text(
                            shortcuts[i]!,
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: controllers[i],
                            style: const TextStyle(fontSize: 13),
                            decoration: InputDecoration(
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                              border: const OutlineInputBorder(),
                              hintText: defaults[i],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              for (var i = 0; i <= 8; i++) {
                controllers[i]!.text = defaults[i]!;
              }
            },
            child: const Text('Reset Defaults'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (saved == true) {
      final newNames = <int, String>{};
      for (var i = 0; i <= 8; i++) {
        final text = controllers[i]!.text.trim();
        if (text.isNotEmpty) {
          newNames[i] = text;
        }
      }
      widget.onUpdateEventNames?.call(newNames);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Count per label
    final labelCounts = <String, int>{};
    final labelDigit = <String, int>{};
    for (final ev in widget.events) {
      labelCounts[ev.label] = (labelCounts[ev.label] ?? 0) + 1;
      labelDigit[ev.label] = ev.digit;
    }

    final filteredEvents = widget.events.where((ev) {
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final matchLabel = ev.label.toLowerCase().contains(q);
        final matchType = ev.type.toLowerCase().contains(q);
        final matchChan = ev.channel?.toLowerCase().contains(q) ?? false;
        if (!matchLabel && !matchType && !matchChan) return false;
      }
      return true;
    }).toList();

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Container(
        width: 720,
        height: 600,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.bookmark_border, color: Color(0xFF1E88E5), size: 24),
                const SizedBox(width: 10),
                Text(
                  'Markers & Annotations (${widget.events.length})',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (widget.onUpdateEventNames != null) ...[
                  OutlinedButton.icon(
                    icon: const Icon(Icons.edit_note, size: 16),
                    label: const Text('Event Names…', style: TextStyle(fontSize: 12)),
                    onPressed: () => _showEditEventNamesDialog(context),
                  ),
                  const SizedBox(width: 8),
                ],
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Filter Chips Section
            if (labelCounts.isNotEmpty) ...[
              Row(
                children: [
                  const Text(
                    'Marker Types & Visibility:',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.black87),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _localDisabledLabels.clear();
                      });
                      widget.onSetAllLabels(true);
                    },
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    child: const Text('Show All', style: TextStyle(fontSize: 12)),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _localDisabledLabels.addAll(labelCounts.keys);
                      });
                      widget.onSetAllLabels(false);
                    },
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    child: const Text('Hide All', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 110),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: labelCounts.entries.map((entry) {
                      final label = entry.key;
                      final count = entry.value;
                      final digit = labelDigit[label] ?? 0;
                      final isVisible = !_localDisabledLabels.contains(label);
                      return FilterChip(
                        selected: isVisible,
                        avatar: Icon(Icons.circle, size: 10, color: _eventColor(digit)),
                        label: Text('$label ($count)', style: const TextStyle(fontSize: 11)),
                        onSelected: (selected) {
                          setState(() {
                            if (selected) {
                              _localDisabledLabels.remove(label);
                            } else {
                              _localDisabledLabels.add(label);
                            }
                          });
                          widget.onToggleLabel(label, selected);
                        },
                      );
                    }).toList(),
                  ),
                ),
              ),
              const Divider(height: 20),
            ],

            // Search bar
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 32,
                    child: TextField(
                      decoration: InputDecoration(
                        hintText: 'Search markers by label, type, channel…',
                        hintStyle: const TextStyle(fontSize: 12),
                        prefixIcon: const Icon(Icons.search, size: 18),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
                        isDense: true,
                      ),
                      style: const TextStyle(fontSize: 12),
                      onChanged: (q) => setState(() => _searchQuery = q.trim()),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Table of markers
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFFD0D0D0)),
                  borderRadius: BorderRadius.circular(4),
                  color: Colors.white,
                ),
                child: filteredEvents.isEmpty
                    ? const Center(
                        child: Text(
                          'No markers matching search',
                          style: TextStyle(color: Colors.black54),
                        ),
                      )
                    : ListView.separated(
                        itemCount: filteredEvents.length,
                        separatorBuilder: (_, _) => const Divider(height: 1, color: Color(0xFFE5E5E5)),
                        itemBuilder: (ctx, i) {
                          final ev = filteredEvents[i];
                          final epoch = (ev.startSec / widget.epochSeconds).floor() + 1;
                          final isVisible = !_localDisabledLabels.contains(ev.label);
                          final color = _eventColor(ev.digit);

                          return InkWell(
                            onTap: () {
                              widget.onJumpToEvent(ev);
                              Navigator.of(context).pop();
                            },
                            child: Opacity(
                              opacity: isVisible ? 1.0 : 0.45,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 10,
                                      height: 10,
                                      decoration: BoxDecoration(
                                        color: color,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    SizedBox(
                                      width: 70,
                                      child: Text(
                                        'Epoch $epoch',
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 95,
                                      child: Text(
                                        _formatElapsed(ev.startSec),
                                        style: const TextStyle(fontSize: 11, color: Colors.black87),
                                      ),
                                    ),
                                    if (widget.recordingStartTime != null)
                                      SizedBox(
                                        width: 80,
                                        child: Text(
                                          _formatClock(ev.startSec),
                                          style: const TextStyle(fontSize: 11, color: Colors.black54),
                                        ),
                                      ),
                                    SizedBox(
                                      width: 60,
                                      child: Text(
                                        ev.durationSeconds > 0
                                            ? '${ev.durationSeconds.toStringAsFixed(1)}s'
                                            : 'Point',
                                        style: const TextStyle(fontSize: 11, color: Colors.black54),
                                      ),
                                    ),
                                    Expanded(
                                      child: Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              ev.label,
                                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          if (ev.channel != null) ...[
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                              decoration: BoxDecoration(
                                                color: Colors.grey.shade200,
                                                borderRadius: BorderRadius.circular(3),
                                              ),
                                              child: Text(
                                                ev.channel!,
                                                style: const TextStyle(fontSize: 10, color: Colors.black87),
                                              ),
                                            ),
                                          ],
                                          if (ev.digit >= 0 && ev.digit <= 12) ...[
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                              decoration: BoxDecoration(
                                                color: Colors.blue.shade50,
                                                borderRadius: BorderRadius.circular(3),
                                                border: Border.all(color: Colors.blue.shade200, width: 0.5),
                                              ),
                                              child: Text(
                                                ev.digit == 0 ? 'A' : 'F${ev.digit}',
                                                style: TextStyle(
                                                  fontSize: 9.5,
                                                  fontWeight: FontWeight.bold,
                                                  color: Colors.blue.shade900,
                                                ),
                                              ),
                                            ),
                                          ],
                                          if (ev.type.isNotEmpty && ev.type != 'Event') ...[
                                            const SizedBox(width: 6),
                                            Text(
                                              '[${ev.type}]',
                                              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    const Icon(Icons.arrow_forward_ios, size: 12, color: Colors.black45),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
            const SizedBox(height: 12),

            // Bottom bar
            Row(
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.download, size: 16),
                  label: const Text('Export CSV…'),
                  onPressed: widget.events.isEmpty
                      ? null
                      : () async {
                          final path = await FilePicker.saveFile(
                            dialogTitle: 'Export Markers as CSV',
                            fileName: 'markers.csv',
                            type: FileType.custom,
                            allowedExtensions: ['csv'],
                          );
                          if (path != null) {
                            final sb = StringBuffer('Onset_Sec,Duration_Sec,Label,Type,Channel\n');
                            for (final ev in widget.events) {
                              sb.writeln('${ev.startSec},${ev.durationSeconds},"${ev.label}","${ev.type}","${ev.channel ?? ''}"');
                            }
                            await File(path).writeAsString(sb.toString());
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Exported ${widget.events.length} markers to $path')),
                              );
                            }
                          }
                        },
                ),
                const Spacer(),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
