import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'eeg_backend.dart';
import 'models.dart';

/// Preset definition for standard clinical EEG/PSG montages.
class MontagePreset {
  const MontagePreset({
    required this.name,
    required this.description,
    required this.derivations,
  });

  final String name;
  final String description;

  /// List of (active, reference) pairs.
  final List<(String, String)> derivations;
}

class MontageDialog extends StatefulWidget {
  const MontageDialog({
    super.key,
    required this.config,
    required this.availableChannels,
    required this.onApply,
  });

  final AppConfig config;
  final List<String> availableChannels;
  final ValueChanged<AppConfig> onApply;

  @override
  State<MontageDialog> createState() => _MontageDialogState();
}

class _MontageDialogState extends State<MontageDialog> {
  late List<ChannelConfig> _channels;
  String? _selectedActiveChannel;
  String? _selectedRefChannel;
  final TextEditingController _customLabelCtrl = TextEditingController();
  bool _flipPolarity = false;
  String _statusMsg = '';

  static const List<MontagePreset> _builtInPresets = [
    MontagePreset(
      name: 'AASM Sleep Standard',
      description: 'Standard AASM clinical PSG derivation: F4-M1, C4-M1, O2-M1, F3-M2, C3-M2, O1-M2, EOGs, EMG',
      derivations: [
        ('F4', 'M1'),
        ('C4', 'M1'),
        ('O2', 'M1'),
        ('F3', 'M2'),
        ('C3', 'M2'),
        ('O1', 'M2'),
        ('E1', 'M2'),
        ('E2', 'M1'),
        ('CHIN1', 'CHIN2'),
      ],
    ),
    MontagePreset(
      name: 'Longitudinal Bipolar (Double Banana)',
      description: 'Anterior-to-posterior longitudinal chains covering temporal and parasagittal columns',
      derivations: [
        ('FP1', 'F7'),
        ('F7', 'T3'),
        ('T3', 'T5'),
        ('T5', 'O1'),
        ('FP2', 'F8'),
        ('F8', 'T4'),
        ('T4', 'T6'),
        ('T6', 'O2'),
        ('FP1', 'F3'),
        ('F3', 'C3'),
        ('C3', 'P3'),
        ('P3', 'O1'),
        ('FP2', 'F4'),
        ('F4', 'C4'),
        ('C4', 'P4'),
        ('P4', 'O2'),
        ('FZ', 'CZ'),
        ('CZ', 'PZ'),
      ],
    ),
    MontagePreset(
      name: 'Transverse Bipolar',
      description: 'Coronal chains across frontal, central, and parietal regions',
      derivations: [
        ('F7', 'FP1'),
        ('FP1', 'FP2'),
        ('FP2', 'F8'),
        ('T3', 'C3'),
        ('C3', 'CZ'),
        ('CZ', 'C4'),
        ('C4', 'T4'),
        ('T5', 'P3'),
        ('P3', 'PZ'),
        ('PZ', 'P4'),
        ('P4', 'T6'),
      ],
    ),
    MontagePreset(
      name: 'Contralateral Mastoids',
      description: 'Left hemisphere electrodes referenced to M2/A2, right hemisphere referenced to M1/A1',
      derivations: [
        ('F3', 'M2'),
        ('C3', 'M2'),
        ('P3', 'M2'),
        ('O1', 'M2'),
        ('F4', 'M1'),
        ('C4', 'M1'),
        ('P4', 'M1'),
        ('O2', 'M1'),
      ],
    ),
  ];

  @override
  void initState() {
    super.initState();
    _channels = widget.config.channels.map((c) => c.copy()).toList();
    if (widget.availableChannels.isNotEmpty) {
      _selectedActiveChannel = widget.availableChannels.first;
      _selectedRefChannel = widget.availableChannels.length > 1
          ? widget.availableChannels[1]
          : 'None';
      _updateCustomLabel();
    }
  }

  @override
  void dispose() {
    _customLabelCtrl.dispose();
    super.dispose();
  }

  void _updateCustomLabel() {
    final active = _selectedActiveChannel ?? '';
    final ref = _selectedRefChannel ?? 'None';
    if (ref == 'None' || ref.isEmpty) {
      _customLabelCtrl.text = active;
    } else {
      _customLabelCtrl.text = '$active-$ref';
    }
  }

  String? _findMatchingElectrode(String target, List<String> available) {
    final cleanTarget = target.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    for (final ch in available) {
      final cleanCh = ch.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
      if (cleanCh == cleanTarget || cleanCh.startsWith(cleanTarget)) {
        return ch;
      }
    }
    // Check aliases like A1 -> M1, A2 -> M2
    if (cleanTarget == 'M1') return _findMatchingElectrode('A1', available);
    if (cleanTarget == 'M2') return _findMatchingElectrode('A2', available);
    if (cleanTarget == 'A1') return _findMatchingElectrode('M1', available);
    if (cleanTarget == 'A2') return _findMatchingElectrode('M2', available);
    return null;
  }

  void _applyBuiltInPreset(MontagePreset preset) {
    final allAvailable = widget.availableChannels;
    int matchedCount = 0;
    final newChannels = <ChannelConfig>[];

    for (final pair in preset.derivations) {
      final active = _findMatchingElectrode(pair.$1, allAvailable);
      final ref = _findMatchingElectrode(pair.$2, allAvailable);

      if (active != null) {
        matchedCount++;
        final existing = _channels.firstWhere(
          (c) => c.name.equalsIgnoreCase(active) || c.sourceChannel?.equalsIgnoreCase(active) == true,
          orElse: () => ChannelConfig(name: active, sourceChannel: active),
        );

        final label = ref != null ? '$active-$ref' : active;
        newChannels.add(ChannelConfig(
          name: label,
          sourceChannel: active,
          reReference: ref ?? 'None',
          derived: ref != null,
          displayOnScreen: true,
          color: existing.color,
          scalingFactor: existing.scalingFactor,
          verticalShift: existing.verticalShift,
          displayMode: existing.displayMode,
        ));
      }
    }

    if (newChannels.isNotEmpty) {
      setState(() {
        // Keep non-matching channels at the bottom (e.g. ECG, respiration, EMG) hidden or visible
        for (final orig in _channels) {
          if (!newChannels.any((n) => n.sourceChannel == orig.name || n.name == orig.name)) {
            final copy = orig.copy();
            copy.displayOnScreen = false;
            newChannels.add(copy);
          }
        }
        _channels = newChannels;
        _statusMsg = 'Applied "${preset.name}" ($matchedCount derivation(s) created).';
      });
    } else {
      setState(() {
        _statusMsg = 'Could not find electrodes matching preset "${preset.name}".';
      });
    }
  }

  void _resetToMonopolar() {
    setState(() {
      for (final ch in _channels) {
        ch.reReference = 'None';
        if (ch.derived && ch.sourceChannel != null) {
          ch.name = ch.sourceChannel!;
          ch.derived = false;
        }
        ch.displayOnScreen = true;
      }
      _statusMsg = 'Reset all channels to native monopolar recordings.';
    });
  }

  void _addCustomDerivation() {
    final active = _selectedActiveChannel;
    final ref = _selectedRefChannel ?? 'None';
    final label = _customLabelCtrl.text.trim().isNotEmpty
        ? _customLabelCtrl.text.trim()
        : (ref == 'None' ? active! : '$active-$ref');

    if (active == null) return;

    final existing = _channels.firstWhere(
      (c) => c.name.equalsIgnoreCase(active),
      orElse: () => _channels.first,
    );

    final added = ChannelConfig(
      name: label,
      sourceChannel: active,
      reReference: ref,
      derived: ref != 'None',
      flipPolarity: _flipPolarity,
      displayOnScreen: true,
      color: existing.color,
      scalingFactor: existing.scalingFactor,
      verticalShift: existing.verticalShift,
      displayMode: existing.displayMode,
    );

    setState(() {
      _channels.add(added);
      _statusMsg = 'Added derivation "$label".';
    });
  }

  Future<void> _exportMontageJson() async {
    final savePath = await FilePicker.saveFile(
      dialogTitle: 'Save Montage Preset (.json)',
      fileName: 'Montage_Preset.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (savePath == null) return;

    final data = {
      'format': 'CCS_SleepStudio_Montage_v1',
      'created': DateTime.now().toIso8601String(),
      'channels': _channels.map((c) => c.toJson()).toList(),
    };
    await File(savePath).writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    setState(() => _statusMsg = 'Saved montage preset to ${File(savePath).uri.pathSegments.last}');
  }

  Future<void> _importMontageJson() async {
    final pick = await FilePicker.pickFiles(
      dialogTitle: 'Load Montage Preset (.json)',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (pick == null || pick.files.single.path == null) return;

    try {
      final text = await File(pick.files.single.path!).readAsString();
      final map = jsonDecode(text) as Map<String, dynamic>;
      final rawList = map['channels'] as List<dynamic>? ?? [];
      final loaded = <ChannelConfig>[];
      for (final item in rawList) {
        if (item is Map<String, dynamic>) {
          loaded.add(ChannelConfig(
            name: item['Channel_name'] as String? ?? 'Ch',
            sourceChannel: item['source_channel'] as String?,
            derived: item['derived'] as bool? ?? false,
            color: item['Channel_color'] as String? ?? 'Black',
            displayOnScreen: item['Display_on_screen'] as bool? ?? true,
            scalingFactor: (item['Scaling_factor'] as num?)?.toDouble() ?? 100.0,
            verticalShift: (item['Vertical_shift'] as num?)?.toDouble() ?? 0.0,
            reReference: item['Re_reference'] as String? ?? 'None',
            flipPolarity: item['Flip_polarity'] as bool? ?? false,
            displayMode: item['display_mode'] as String? ?? '',
          ));
        }
      }
      if (loaded.isNotEmpty) {
        setState(() {
          _channels = loaded;
          _statusMsg = 'Loaded ${loaded.length} channel(s) from preset.';
        });
      }
    } catch (e) {
      setState(() => _statusMsg = 'Error loading preset: $e');
    }
  }

  void _onApply() {
    final newConfig = widget.config.copy();
    newConfig.channels = _channels;
    widget.onApply(newConfig);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final available = widget.availableChannels;
    final allRefOptions = ['None', ...available];

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: 880,
        height: 640,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.indigo.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.alt_route, color: Colors.indigo),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Channel Montage & Referencing Manager',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        'Apply standard clinical sleep montages (AASM, Bipolar Double Banana, Contralateral Mastoids) or create custom derivations.',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _importMontageJson,
                  icon: const Icon(Icons.file_open_outlined, size: 16),
                  label: const Text('Load Preset'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _exportMontageJson,
                  icon: const Icon(Icons.save_alt_outlined, size: 16),
                  label: const Text('Save Preset'),
                ),
              ],
            ),
            const Divider(height: 20),

            // Standard Presets Row
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Clinical Presets:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                for (final p in _builtInPresets)
                  ActionChip(
                    avatar: const Icon(Icons.auto_awesome, size: 14, color: Colors.indigo),
                    label: Text(p.name, style: const TextStyle(fontSize: 11.5)),
                    tooltip: p.description,
                    onPressed: () => _applyBuiltInPreset(p),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.restart_alt, size: 14, color: Colors.deepOrange),
                  label: const Text('Reset to Native / Monopolar', style: TextStyle(fontSize: 11.5)),
                  tooltip: 'Set all re-references to None',
                  onPressed: _resetToMonopolar,
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Quick Derivation Builder Card
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Row(
                children: [
                  const Text('Add Derivation:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  const SizedBox(width: 12),
                  // Active
                  Expanded(
                    flex: 3,
                    child: DropdownButtonFormField<String>(
                      value: _selectedActiveChannel,
                      isDense: true,
                      decoration: const InputDecoration(
                        labelText: 'Active (+)',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      ),
                      items: available.map((c) => DropdownMenuItem(value: c, child: Text(c, style: const TextStyle(fontSize: 12)))).toList(),
                      onChanged: (v) {
                        setState(() {
                          _selectedActiveChannel = v;
                          _updateCustomLabel();
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text('–', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(width: 8),
                  // Reference
                  Expanded(
                    flex: 3,
                    child: DropdownButtonFormField<String>(
                      value: _selectedRefChannel,
                      isDense: true,
                      decoration: const InputDecoration(
                        labelText: 'Reference (–)',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      ),
                      items: allRefOptions.map((c) => DropdownMenuItem(value: c, child: Text(c, style: const TextStyle(fontSize: 12)))).toList(),
                      onChanged: (v) {
                        setState(() {
                          _selectedRefChannel = v;
                          _updateCustomLabel();
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Custom Label
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _customLabelCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Derivation Label',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        isDense: true,
                      ),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Invert polarity (–/+)',
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: _flipPolarity,
                          visualDensity: VisualDensity.compact,
                          onChanged: (v) => setState(() => _flipPolarity = v ?? false),
                        ),
                        const Text('Invert', style: TextStyle(fontSize: 11)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _addCustomDerivation,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Add Pair'),
                    style: FilledButton.styleFrom(backgroundColor: Colors.indigo),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // Channels List
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      color: Colors.grey.shade100,
                      child: Row(
                        children: [
                          const SizedBox(width: 24, child: Text('#', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                          const SizedBox(width: 32, child: Text('Vis', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                          const Expanded(flex: 3, child: Text('Channel / Derivation', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                          const Expanded(flex: 3, child: Text('Re-Reference (-)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                          const SizedBox(width: 60, child: Text('Polarity', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                          const SizedBox(width: 80, child: Text('Scale (µV)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                          const SizedBox(width: 48),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ReorderableListView.builder(
                        itemCount: _channels.length,
                        onReorder: (oldIdx, newIdx) {
                          setState(() {
                            if (oldIdx < newIdx) newIdx -= 1;
                            final item = _channels.removeAt(oldIdx);
                            _channels.insert(newIdx, item);
                          });
                        },
                        itemBuilder: (ctx, idx) {
                          final ch = _channels[idx];
                          return Container(
                            key: ValueKey('channel_${ch.name}_$idx'),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                            decoration: BoxDecoration(
                              color: idx.isEven ? Colors.white : Colors.grey.shade50,
                              border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
                            ),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 24,
                                  child: Text('${idx + 1}', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                                ),
                                SizedBox(
                                  width: 32,
                                  child: Checkbox(
                                    value: ch.displayOnScreen,
                                    visualDensity: VisualDensity.compact,
                                    onChanged: (v) => setState(() => ch.displayOnScreen = v ?? true),
                                  ),
                                ),
                                Expanded(
                                  flex: 3,
                                  child: Row(
                                    children: [
                                      Text(
                                        ch.name,
                                        style: TextStyle(
                                          fontWeight: ch.derived ? FontWeight.bold : FontWeight.w500,
                                          fontSize: 12,
                                          color: ch.displayOnScreen ? Colors.black87 : Colors.grey.shade400,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (ch.derived) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: Colors.indigo.shade50,
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text('bipolar', style: TextStyle(fontSize: 9, color: Colors.indigo.shade800)),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                Expanded(
                                  flex: 3,
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<String>(
                                      value: allRefOptions.contains(ch.reReference) ? ch.reReference : 'None',
                                      isDense: true,
                                      style: const TextStyle(fontSize: 12, color: Colors.black87),
                                      items: allRefOptions
                                          .map((r) => DropdownMenuItem(value: r, child: Text(r, style: const TextStyle(fontSize: 12))))
                                          .toList(),
                                      onChanged: (v) {
                                        setState(() {
                                          ch.reReference = v ?? 'None';
                                          ch.derived = ch.reReference != 'None';
                                        });
                                      },
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 60,
                                  child: Tooltip(
                                    message: 'Invert polarity',
                                    child: Checkbox(
                                      value: ch.flipPolarity,
                                      visualDensity: VisualDensity.compact,
                                      onChanged: (v) => setState(() => ch.flipPolarity = v ?? false),
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 80,
                                  child: Text(
                                    '${ch.scalingFactor.toStringAsFixed(0)} µV',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                                SizedBox(
                                  width: 48,
                                  child: IconButton(
                                    icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                                    onPressed: () {
                                      setState(() => _channels.removeAt(idx));
                                    },
                                    tooltip: 'Remove channel',
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
            const SizedBox(height: 8),

            // Footer
            Row(
              children: [
                if (_statusMsg.isNotEmpty)
                  Expanded(
                    child: Text(
                      _statusMsg,
                      style: TextStyle(fontSize: 12, color: Colors.indigo.shade800, fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis,
                    ),
                  )
                else
                  const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _onApply,
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Apply Montage'),
                  style: FilledButton.styleFrom(backgroundColor: Colors.indigo),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

extension on String {
  bool equalsIgnoreCase(String other) => toLowerCase() == other.toLowerCase();
}
