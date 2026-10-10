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

const List<MontagePreset> builtInMontagePresets = [
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

  static const List<MontagePreset> _builtInPresets = builtInMontagePresets;

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

  String? _findMatchingElectrode(String target, List<String> available) =>
      findMatchingElectrode(target, available);

  void _applyBuiltInPreset(MontagePreset preset) {
    final newChannels = generateMontagePresetChannels(
      preset: preset,
      availableChannels: widget.availableChannels,
      existingChannels: _channels,
    );

    if (newChannels.any((c) => c.displayOnScreen)) {
      final matchedCount = newChannels.where((c) => c.displayOnScreen).length;
      setState(() {
        _channels = newChannels;
        _statusMsg =
            'Applied "${preset.name}" ($matchedCount derivation(s) created).';
      });
    } else {
      setState(() {
        _statusMsg =
            'Could not find electrodes matching preset "${preset.name}".';
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

String? findMatchingElectrode(String target, List<String> available) {
  // 1. Direct case-insensitive match
  for (final ch in available) {
    if (ch.equalsIgnoreCase(target)) return ch;
  }

  String clean(String s) {
    return s
        .toUpperCase()
        .replaceAll(RegExp(r'^(EEG\s*|POL\s*)'), '')
        .replaceAll(RegExp(r'(-REF|\s*REF)$'), '')
        .replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  final targetClean = clean(target);
  for (final ch in available) {
    if (clean(ch) == targetClean) return ch;
  }

  // 2. Clinical aliases, mastoids, EOG, EMG, and 10-20 <-> 10-10 equivalences
  final aliases = <String, List<String>>{
    // Mastoids / Auricular references
    'M1': ['A1', 'TP9', 'M1REF', 'A1REF'],
    'M2': ['A2', 'TP10', 'M2REF', 'A2REF'],
    'A1': ['M1', 'TP9', 'M1REF', 'A1REF'],
    'A2': ['M2', 'TP10', 'M2REF', 'A2REF'],

    // 10-20 to 10-10 equivalences
    'T3': ['T7'],
    'T7': ['T3'],
    'T4': ['T8'],
    'T8': ['T4'],
    'T5': ['P7'],
    'P7': ['T5'],
    'T6': ['P8'],
    'P8': ['T6'],

    // EOG / Eye channels
    'E1': [
      'EOG1',
      'LOC',
      'EOGL',
      'LEOG',
      'EOGLEFT',
      'LEFTEOG',
      'EYE1',
      'EYEL',
      'EOG1REF',
    ],
    'EOG1': [
      'E1',
      'LOC',
      'EOGL',
      'LEOG',
      'EOGLEFT',
      'LEFTEOG',
      'EYE1',
      'EYEL',
    ],
    'LOC': ['E1', 'EOG1', 'EOGL', 'LEOG', 'EOGLEFT', 'LEFTEOG'],
    'E2': [
      'EOG2',
      'ROC',
      'EOGR',
      'REOG',
      'EOGRIGHT',
      'RIGHTEOG',
      'EYE2',
      'EYER',
      'EOG2REF',
    ],
    'EOG2': [
      'E2',
      'ROC',
      'EOGR',
      'REOG',
      'EOGRIGHT',
      'RIGHTEOG',
      'EYE2',
      'EYER',
    ],
    'ROC': ['E2', 'EOG2', 'EOGR', 'REOG', 'EOGRIGHT', 'RIGHTEOG'],

    // EMG / Chin channels
    'CHIN1': [
      'EMG1',
      'CHINL',
      'CHINLEFT',
      'EMGL',
      'SUBMENTAL1',
      'CHIN',
      'EMG',
    ],
    'EMG1': [
      'CHIN1',
      'CHINL',
      'CHINLEFT',
      'EMGL',
      'SUBMENTAL1',
      'CHIN',
      'EMG',
    ],
    'CHIN2': ['EMG2', 'CHINR', 'CHINRIGHT', 'EMGR', 'CHINZ', 'SUBMENTAL2'],
    'EMG2': ['CHIN2', 'CHINR', 'CHINRIGHT', 'EMGR', 'CHINZ', 'SUBMENTAL2'],
    'CHIN': ['EMG', 'CHIN1', 'EMG1', 'SUBMENTAL'],
    'EMG': ['CHIN', 'EMG1', 'CHIN1', 'SUBMENTAL'],

    // ECG / EKG
    'ECG': ['EKG', 'ECG1', 'EKG1', 'HEART'],
    'EKG': ['ECG', 'ECG1', 'EKG1', 'HEART'],
  };

  final candList = aliases[targetClean];
  if (candList != null) {
    for (final cand in candList) {
      for (final ch in available) {
        if (clean(ch) == cand) return ch;
      }
    }
  }

  return null;
}

List<ChannelConfig> generateMontagePresetChannels({
  required MontagePreset preset,
  required List<String> availableChannels,
  List<ChannelConfig>? existingChannels,
}) {
  final baseList = existingChannels ??
      availableChannels
          .map((name) => ChannelConfig(name: name, sourceChannel: name))
          .toList();
  final newChannels = <ChannelConfig>[];
  final isAasm = preset.name.contains('AASM');

  for (final pair in preset.derivations) {
    final active = findMatchingElectrode(pair.$1, availableChannels);
    final ref = findMatchingElectrode(pair.$2, availableChannels);

    // In bipolar or differential montages, BOTH active and reference must exist and not be identical
    if (active != null && ref != null && !active.equalsIgnoreCase(ref)) {
      final existing = baseList.firstWhere(
        (c) =>
            c.name.equalsIgnoreCase(active) ||
            c.sourceChannel?.equalsIgnoreCase(active) == true,
        orElse: () => ChannelConfig(name: active, sourceChannel: active),
      );

      final label = '$active-$ref';
      newChannels.add(
        ChannelConfig(
          name: label,
          sourceChannel: active,
          reReference: ref,
          derived: true,
          displayOnScreen: true,
          color: existing.color,
          scalingFactor: existing.scalingFactor,
          verticalShift: existing.verticalShift,
          displayMode: existing.displayMode,
        ),
      );
    }
  }

  // Comprehensive AASM standard: ensure EOG and Chin EMG are included
  if (isAasm) {
    // 1. EOG channels (if not already added by derivations above)
    final hasEog = newChannels.any(
      (c) => detectChannelModality(c.name) == ChannelModality.eog,
    );
    if (!hasEog) {
      final e1 = findMatchingElectrode('E1', availableChannels);
      final e2 = findMatchingElectrode('E2', availableChannels);
      final m1 = findMatchingElectrode('M1', availableChannels);
      final m2 = findMatchingElectrode('M2', availableChannels);
      if (e1 != null) {
        final ref = m2 ?? m1;
        final existing = baseList.firstWhere(
          (c) => c.name.equalsIgnoreCase(e1),
          orElse: () => ChannelConfig(name: e1),
        );
        final label =
            ref != null && !ref.equalsIgnoreCase(e1) ? '$e1-$ref' : e1;
        newChannels.add(
          ChannelConfig(
            name: label,
            sourceChannel: e1,
            reReference:
                ref != null && !ref.equalsIgnoreCase(e1) ? ref : 'None',
            derived: ref != null && !ref.equalsIgnoreCase(e1),
            displayOnScreen: true,
            color: existing.color,
            scalingFactor: existing.scalingFactor,
          ),
        );
      }
      if (e2 != null) {
        final ref = m1 ?? m2;
        final existing = baseList.firstWhere(
          (c) => c.name.equalsIgnoreCase(e2),
          orElse: () => ChannelConfig(name: e2),
        );
        final label =
            ref != null && !ref.equalsIgnoreCase(e2) ? '$e2-$ref' : e2;
        newChannels.add(
          ChannelConfig(
            name: label,
            sourceChannel: e2,
            reReference:
                ref != null && !ref.equalsIgnoreCase(e2) ? ref : 'None',
            derived: ref != null && !ref.equalsIgnoreCase(e2),
            displayOnScreen: true,
            color: existing.color,
            scalingFactor: existing.scalingFactor,
          ),
        );
      }
    }

    // 2. Chin EMG channels (if not already added)
    final hasEmg = newChannels.any(
      (c) => detectChannelModality(c.name) == ChannelModality.emg,
    );
    if (!hasEmg) {
      final chin1 = findMatchingElectrode('CHIN1', availableChannels);
      final chin2 = findMatchingElectrode('CHIN2', availableChannels);
      if (chin1 != null && chin2 != null && !chin1.equalsIgnoreCase(chin2)) {
        final existing = baseList.firstWhere(
          (c) => c.name.equalsIgnoreCase(chin1),
          orElse: () => ChannelConfig(name: chin1),
        );
        newChannels.add(
          ChannelConfig(
            name: '$chin1-$chin2',
            sourceChannel: chin1,
            reReference: chin2,
            derived: true,
            displayOnScreen: true,
            color: existing.color,
            scalingFactor: existing.scalingFactor,
          ),
        );
      } else if (chin1 != null) {
        final existing = baseList.firstWhere(
          (c) => c.name.equalsIgnoreCase(chin1),
          orElse: () => ChannelConfig(name: chin1),
        );
        newChannels.add(
          ChannelConfig(
            name: chin1,
            sourceChannel: chin1,
            reReference: 'None',
            derived: false,
            displayOnScreen: true,
            color: existing.color,
            scalingFactor: existing.scalingFactor,
          ),
        );
      }
    }

    // 3. ECG channel if present
    final ecg = findMatchingElectrode('ECG', availableChannels);
    if (ecg != null && !newChannels.any((c) => c.name.equalsIgnoreCase(ecg))) {
      final existing = baseList.firstWhere(
        (c) => c.name.equalsIgnoreCase(ecg),
        orElse: () => ChannelConfig(name: ecg),
      );
      newChannels.add(
        ChannelConfig(
          name: ecg,
          sourceChannel: ecg,
          reReference: 'None',
          derived: false,
          displayOnScreen: true,
          color: existing.color,
          scalingFactor: existing.scalingFactor,
        ),
      );
    }
  }

  if (newChannels.isNotEmpty) {
    for (final ch in newChannels) {
      applyAasmFiltersToChannel(ch);
    }
    // Keep non-montage channels at the bottom with displayOnScreen = false
    // so that ONLY the clean montage channels are displayed on screen.
    for (final orig in baseList) {
      final baseName = orig.sourceChannel ?? orig.name;
      if (!newChannels.any(
        (n) =>
            n.name.equalsIgnoreCase(orig.name) ||
            (n.derived && n.name.startsWith('$baseName-')),
      )) {
        final copy = orig.copy();
        copy.displayOnScreen = false;
        newChannels.add(copy);
      }
    }
  }
  return newChannels;
}
