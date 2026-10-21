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
    description: 'Standard AASM clinical PSG sequence: EOG (E1-M2, E2-M1), Frontal (F4-M1, F3-M2), Central (C4-M1, C3-M2), Occipital (O2-M1, O1-M2), Chin EMG',
    derivations: [
      ('E1', 'M2'),
      ('E2', 'M1'),
      ('F4', 'M1'),
      ('F3', 'M2'),
      ('C4', 'M1'),
      ('C3', 'M2'),
      ('O2', 'M1'),
      ('O1', 'M2'),
      ('CHIN1', 'CHIN2'),
    ],
  ),
  MontagePreset(
    name: 'AASM Sleep + OSA (Respiratory)',
    description: 'Standard AASM derivations with complete respiratory channels (Flow, Thorax, Abdomen, SpO2, Snore)',
    derivations: [
      ('E1', 'M2'),
      ('E2', 'M1'),
      ('F4', 'M1'),
      ('F3', 'M2'),
      ('C4', 'M1'),
      ('C3', 'M2'),
      ('O2', 'M1'),
      ('O1', 'M2'),
      ('CHIN1', 'CHIN2'),
    ],
  ),
  MontagePreset(
    name: 'AASM Sleep + PLM (Limb Movements)',
    description: 'Standard AASM derivations with bilateral leg EMG (LAT, RAT) and body position',
    derivations: [
      ('E1', 'M2'),
      ('E2', 'M1'),
      ('F4', 'M1'),
      ('F3', 'M2'),
      ('C4', 'M1'),
      ('C3', 'M2'),
      ('O2', 'M1'),
      ('O1', 'M2'),
      ('CHIN1', 'CHIN2'),
    ],
  ),
  MontagePreset(
    name: 'AASM Sleep + PLM + OSA (Comprehensive PSG)',
    description: 'Comprehensive AASM clinical PSG: standard derivations plus bilateral leg movements (LAT, RAT, PLM) and complete respiratory channels (Flow, Thorax, Abdomen, SpO2, Snore, Body Position)',
    derivations: [
      ('E1', 'M2'),
      ('E2', 'M1'),
      ('F4', 'M1'),
      ('F3', 'M2'),
      ('C4', 'M1'),
      ('C3', 'M2'),
      ('O2', 'M1'),
      ('O1', 'M2'),
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

    final activeIdx = widget.availableChannels.indexOf(active);
    final added = ChannelConfig(
      name: label,
      sourceChannel: active,
      sourceIndex: activeIdx >= 0 ? activeIdx : null,
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

  bool _cleanLabelsOnApply = true;

  void _cleanAllChannelLabels() {
    setState(() {
      for (final ch in _channels) {
        ch.name = cleanChannelLabel(ch.name);
      }
      _statusMsg = 'Cleaned acquisition prefixes (EEG/POL) and suffixes (-Ref) from all channel labels.';
    });
  }

  void _applyAllAasmFilters() {
    setState(() {
      applyAasmFiltersToAll(_channels);
      _statusMsg = 'Applied recommended AASM clinical filters (EEG/EOG: 0.3-35 Hz, EMG: 10-100 Hz).';
    });
  }

  String _filterSummary(ChannelConfig ch) {
    if (!ch.filterHpEnabled && !ch.filterLpEnabled && !ch.filterNotchEnabled) {
      return 'Off';
    }
    final hp = ch.filterHpEnabled ? ch.filterHpCutoff.toStringAsFixed(ch.filterHpCutoff < 1 ? 1 : 0) : '0';
    final lp = ch.filterLpEnabled ? ch.filterLpCutoff.toStringAsFixed(0) : '∞';
    final notch = ch.filterNotchEnabled ? ' N${ch.filterNotchCutoff.toStringAsFixed(0)}' : '';
    return '$hp–$lp Hz$notch';
  }

  void _showChannelFilterDialog(ChannelConfig ch) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        var hpOn = ch.filterHpEnabled;
        var hpVal = ch.filterHpCutoff;
        var lpOn = ch.filterLpEnabled;
        var lpVal = ch.filterLpCutoff;
        var notchOn = ch.filterNotchEnabled;
        var notchVal = ch.filterNotchCutoff;

        return StatefulBuilder(
          builder: (ctx, setDlgState) {
            return AlertDialog(
              title: Text('Filter Settings — ${ch.name}'),
              content: SizedBox(
                width: 380,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SwitchListTile(
                      title: const Text('High-Pass Filter', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                      subtitle: Text(hpOn ? '${hpVal.toStringAsFixed(1)} Hz' : 'Off (DC)', style: const TextStyle(fontSize: 12)),
                      value: hpOn,
                      onChanged: (v) => setDlgState(() => hpOn = v),
                    ),
                    if (hpOn)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            for (final f in [0.3, 0.5, 1.0, 10.0])
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: ChoiceChip(
                                  label: Text('${f.toStringAsFixed(f == 10.0 ? 0 : 1)} Hz', style: const TextStyle(fontSize: 11)),
                                  selected: (hpVal - f).abs() < 0.05,
                                  onSelected: (sel) {
                                    if (sel) setDlgState(() => hpVal = f);
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                    const Divider(),
                    SwitchListTile(
                      title: const Text('Low-Pass Filter', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                      subtitle: Text(lpOn ? '${lpVal.toStringAsFixed(0)} Hz' : 'Off', style: const TextStyle(fontSize: 12)),
                      value: lpOn,
                      onChanged: (v) => setDlgState(() => lpOn = v),
                    ),
                    if (lpOn)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Wrap(
                          spacing: 6,
                          children: [
                            for (final f in [15.0, 30.0, 35.0, 70.0, 100.0])
                              ChoiceChip(
                                label: Text('${f.toStringAsFixed(0)} Hz', style: const TextStyle(fontSize: 11)),
                                selected: (lpVal - f).abs() < 0.5,
                                onSelected: (sel) {
                                  if (sel) setDlgState(() => lpVal = f);
                                },
                              ),
                          ],
                        ),
                      ),
                    const Divider(),
                    SwitchListTile(
                      title: const Text('Notch Filter', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                      subtitle: Text(notchOn ? '${notchVal.toStringAsFixed(0)} Hz' : 'Off', style: const TextStyle(fontSize: 12)),
                      value: notchOn,
                      onChanged: (v) => setDlgState(() => notchOn = v),
                    ),
                    if (notchOn)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            for (final f in [50.0, 60.0])
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: ChoiceChip(
                                  label: Text('${f.toStringAsFixed(0)} Hz', style: const TextStyle(fontSize: 11)),
                                  selected: (notchVal - f).abs() < 0.5,
                                  onSelected: (sel) {
                                    if (sel) setDlgState(() => notchVal = f);
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    setState(() {
                      ch.filterHpEnabled = hpOn;
                      ch.filterHpCutoff = hpVal;
                      ch.filterLpEnabled = lpOn;
                      ch.filterLpCutoff = lpVal;
                      ch.filterNotchEnabled = notchOn;
                      ch.filterNotchCutoff = notchVal;
                    });
                    Navigator.of(ctx).pop();
                  },
                  child: const Text('Apply'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _exportMontageJson() async {
    final savePath = await FilePicker.saveFile(
      dialogTitle: 'Save Montage Preset (.ccsmontage / .json)',
      fileName: 'Montage_Preset.ccsmontage',
      type: FileType.custom,
      allowedExtensions: ['ccsmontage', 'json'],
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
      dialogTitle: 'Load Montage Preset (.ccsmontage / .json)',
      type: FileType.custom,
      allowedExtensions: ['ccsmontage', 'json'],
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
    if (_cleanLabelsOnApply) {
      for (final ch in _channels) {
        ch.name = cleanChannelLabel(ch.name);
      }
    }
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
        width: 960,
        height: 660,
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
                ActionChip(
                  avatar: const Icon(Icons.cleaning_services_outlined, size: 14, color: Colors.teal),
                  label: const Text('Clean Channel Labels', style: TextStyle(fontSize: 11.5)),
                  tooltip: 'Strip prefixes (EEG, POL) and suffixes (-Ref) for optimal autodetect',
                  onPressed: _cleanAllChannelLabels,
                ),
                ActionChip(
                  avatar: const Icon(Icons.tune, size: 14, color: Colors.purple),
                  label: const Text('Apply AASM Filters', style: TextStyle(fontSize: 11.5)),
                  tooltip: 'Set recommended AASM clinical filters (EEG/EOG: 0.3-35 Hz, EMG: 10-100 Hz)',
                  onPressed: _applyAllAasmFilters,
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
                      child: const Row(
                        children: [
                          SizedBox(width: 24, child: Text('#', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                          SizedBox(width: 32, child: Text('Vis', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                          Expanded(flex: 3, child: Text('Channel / Derivation', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                          Expanded(flex: 3, child: Text('Re-Reference (-)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                          SizedBox(width: 54, child: Text('Invert', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                          SizedBox(width: 90, child: Text('Scale (µV)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                          SizedBox(width: 100, child: Text('Filters', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                          SizedBox(width: 40),
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
                                      if (ch.sourceChannel != null && !ch.sourceChannel!.equalsIgnoreCase(ch.name)) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: Colors.grey.shade200,
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text('file: ${ch.sourceChannel}', style: TextStyle(fontSize: 9.5, color: Colors.grey.shade800)),
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
                                  width: 54,
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
                                  width: 90,
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<double>(
                                      value: const [20.0, 50.0, 70.0, 100.0, 150.0, 200.0, 500.0, 1000.0].contains(ch.scalingFactor)
                                          ? ch.scalingFactor
                                          : 100.0,
                                      isDense: true,
                                      style: const TextStyle(fontSize: 11, color: Colors.black87),
                                      items: const [20.0, 50.0, 70.0, 100.0, 150.0, 200.0, 500.0, 1000.0]
                                          .map((s) => DropdownMenuItem(
                                                value: s,
                                                child: Text('${s.toStringAsFixed(0)} µV', style: const TextStyle(fontSize: 11)),
                                              ))
                                          .toList(),
                                      onChanged: (v) {
                                        if (v != null) setState(() => ch.scalingFactor = v);
                                      },
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 100,
                                  child: OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                                      visualDensity: VisualDensity.compact,
                                      side: BorderSide(
                                        color: (ch.filterHpEnabled || ch.filterLpEnabled || ch.filterNotchEnabled)
                                            ? Colors.indigo
                                            : Colors.grey.shade300,
                                      ),
                                    ),
                                    onPressed: () => _showChannelFilterDialog(ch),
                                    child: Text(
                                      _filterSummary(ch),
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: (ch.filterHpEnabled || ch.filterLpEnabled || ch.filterNotchEnabled)
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                        color: (ch.filterHpEnabled || ch.filterLpEnabled || ch.filterNotchEnabled)
                                            ? Colors.indigo.shade800
                                            : Colors.grey.shade700,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 40,
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
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: _cleanLabelsOnApply,
                      visualDensity: VisualDensity.compact,
                      onChanged: (v) => setState(() => _cleanLabelsOnApply = v ?? true),
                    ),
                    const Text('Clean channel prefixes/suffixes on apply', style: TextStyle(fontSize: 11.5)),
                  ],
                ),
                const SizedBox(width: 12),
                if (_statusMsg.isNotEmpty)
                  Expanded(
                    child: Text(
                      _statusMsg,
                      style: TextStyle(fontSize: 11.5, color: Colors.indigo.shade800, fontWeight: FontWeight.w500),
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
    // 1. Check if the recording already has this differential channel pre-referenced
    final preRef = findPreReferencedChannel(pair.$1, pair.$2, availableChannels);
    if (preRef != null) {
      final existing = baseList.firstWhere(
        (c) =>
            c.name.equalsIgnoreCase(preRef) ||
            c.sourceChannel?.equalsIgnoreCase(preRef) == true,
        orElse: () => ChannelConfig(name: preRef, sourceChannel: preRef),
      );
      final preIndex = availableChannels.indexOf(preRef);
      final modality = detectChannelModality(preRef);
      final color = modality == ChannelModality.eog
          ? 'Blue'
          : modality == ChannelModality.emg
              ? 'Orange'
              : modality == ChannelModality.ecg
                  ? 'Magenta'
                  : existing.color;
      final displayName = isAasm ? cleanChannelLabel(preRef) : preRef;
      newChannels.add(
        ChannelConfig(
          name: displayName,
          sourceChannel: preRef,
          sourceIndex: preIndex >= 0 ? preIndex : null,
          reReference: 'None',
          derived: false,
          displayOnScreen: true,
          color: color,
          scalingFactor: existing.scalingFactor,
          verticalShift: existing.verticalShift,
          displayMode: existing.displayMode,
        ),
      );
      continue;
    }

    // 2. Otherwise derive active - ref in software
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

      final cleanAct = isAasm ? cleanChannelLabel(active) : active;
      final cleanR = isAasm ? cleanChannelLabel(ref) : ref;
      final label = isAasm ? '$cleanAct-$cleanR' : '$active-$ref';
      final activeIndex = availableChannels.indexOf(active);
      final modality = detectChannelModality(label);
      final color = modality == ChannelModality.eog
          ? 'Blue'
          : modality == ChannelModality.emg
              ? 'Orange'
              : modality == ChannelModality.ecg
                  ? 'Magenta'
                  : existing.color;
      newChannels.add(
        ChannelConfig(
          name: label,
          sourceChannel: active,
          sourceIndex: activeIndex >= 0 ? activeIndex : null,
          reReference: ref,
          derived: true,
          displayOnScreen: true,
          color: color,
          scalingFactor: existing.scalingFactor,
          verticalShift: existing.verticalShift,
          displayMode: existing.displayMode,
        ),
      );
    }
  }

  // Comprehensive AASM standard: ensure EOG, Chin EMG, ECG, OSA, PLM are properly handled
  if (isAasm) {
    // 1. EOG channels (if not already added by derivations above)
    final hasEog = newChannels.any(
      (c) => detectChannelModality(c.name) == ChannelModality.eog,
    );
    if (!hasEog) {
      final e1 = findMatchingElectrode('E1', availableChannels) ??
          findMatchingElectrode('LOC', availableChannels) ??
          findMatchingElectrode('LOC1', availableChannels);
      final e2 = findMatchingElectrode('E2', availableChannels) ??
          findMatchingElectrode('ROC', availableChannels) ??
          findMatchingElectrode('ROC1', availableChannels);
      final m1 = findMatchingElectrode('M1', availableChannels);
      final m2 = findMatchingElectrode('M2', availableChannels);
      if (e1 != null) {
        final ref = m2 ?? m1;
        final existing = baseList.firstWhere(
          (c) => c.name.equalsIgnoreCase(e1),
          orElse: () => ChannelConfig(name: e1),
        );
        final cleanE1 = cleanChannelLabel(e1);
        final cleanR = ref != null ? cleanChannelLabel(ref) : '';
        final label =
            ref != null && !ref.equalsIgnoreCase(e1) ? '$cleanE1-$cleanR' : cleanE1;
        final e1Index = availableChannels.indexOf(e1);
        newChannels.add(
          ChannelConfig(
            name: label,
            sourceChannel: e1,
            sourceIndex: e1Index >= 0 ? e1Index : null,
            reReference:
                ref != null && !ref.equalsIgnoreCase(e1) ? ref : 'None',
            derived: ref != null && !ref.equalsIgnoreCase(e1),
            displayOnScreen: true,
            color: 'Blue',
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
        final cleanE2 = cleanChannelLabel(e2);
        final cleanR = ref != null ? cleanChannelLabel(ref) : '';
        final label =
            ref != null && !ref.equalsIgnoreCase(e2) ? '$cleanE2-$cleanR' : cleanE2;
        final e2Index = availableChannels.indexOf(e2);
        newChannels.add(
          ChannelConfig(
            name: label,
            sourceChannel: e2,
            sourceIndex: e2Index >= 0 ? e2Index : null,
            reReference:
                ref != null && !ref.equalsIgnoreCase(e2) ? ref : 'None',
            derived: ref != null && !ref.equalsIgnoreCase(e2),
            displayOnScreen: true,
            color: 'Blue',
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
        final chin1Index = availableChannels.indexOf(chin1);
        newChannels.add(
          ChannelConfig(
            name: 'CHIN1-CHIN2',
            sourceChannel: chin1,
            sourceIndex: chin1Index >= 0 ? chin1Index : null,
            reReference: chin2,
            derived: true,
            displayOnScreen: true,
            color: 'Orange',
            scalingFactor: existing.scalingFactor,
          ),
        );
      } else if (chin1 != null) {
        final existing = baseList.firstWhere(
          (c) => c.name.equalsIgnoreCase(chin1),
          orElse: () => ChannelConfig(name: chin1),
        );
        final chin1Index = availableChannels.indexOf(chin1);
        newChannels.add(
          ChannelConfig(
            name: cleanChannelLabel(chin1),
            sourceChannel: chin1,
            sourceIndex: chin1Index >= 0 ? chin1Index : null,
            reReference: 'None',
            derived: false,
            displayOnScreen: true,
            color: 'Orange',
            scalingFactor: existing.scalingFactor,
          ),
        );
      }
    }

    // 3. ECG channel if present
    final ecg = findMatchingElectrode('ECG', availableChannels);
    if (ecg != null && !newChannels.any((c) => c.name.equalsIgnoreCase(ecg) || c.name.equalsIgnoreCase('ECG'))) {
      final existing = baseList.firstWhere(
        (c) => c.name.equalsIgnoreCase(ecg),
        orElse: () => ChannelConfig(name: ecg),
      );
      final ecgIndex = availableChannels.indexOf(ecg);
      newChannels.add(
        ChannelConfig(
          name: 'ECG',
          sourceChannel: ecg,
          sourceIndex: ecgIndex >= 0 ? ecgIndex : null,
          reReference: 'None',
          derived: false,
          displayOnScreen: true,
          color: 'Magenta',
          scalingFactor: existing.scalingFactor,
        ),
      );
    }

    // 4. Extended Respiratory channels for OSA Preset or Comprehensive Preset
    if (preset.name.contains('OSA') || preset.name.contains('Comprehensive')) {
      final respSignals = [
        ('Flow', ['FLOW', 'CANNULA', 'THERMAL', 'THERMISTOR', 'AIRFLOW', 'NASAL', 'PNOSE', 'PRESSUREFLOW', 'PRESSURE_FLOW', 'FLOWTH', 'FLOW_TH']),
        ('Thorax', ['THORAX', 'CHEST', 'THOR', 'THO', 'EFFORTTHOR', 'EFFORT_THOR', 'RIPTHORAX', 'RIP_THORAX', 'THORAXRIP']),
        ('Abdomen', ['ABDOMEN', 'ABDO', 'ABD', 'EFFORTABDO', 'EFFORT_ABDO', 'RIPABDOMEN', 'RIP_ABDOMEN', 'ABDOMENRIP']),
        ('SpO2', ['SPO2', 'SAO2', 'OXIMETRY', 'PULSEOX', 'SAT', 'PLETH', 'PULSE']),
        ('Snore', ['SNORE', 'MIC', 'TRACHEA', 'PRESSURESNORE', 'PRESSURE_SNORE']),
      ];
      for (final item in respSignals) {
        final match = findMatchingElectrode(item.$1, availableChannels) ??
            availableChannels.firstWhere(
              (c) {
                final cleanC = cleanChannelLabel(c).toUpperCase();
                final alphanumC = cleanC.replaceAll(RegExp(r'[^A-Z0-9]'), '');
                return item.$2.any((t) {
                  final cleanT = t.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
                  return cleanC.contains(t) || alphanumC.contains(cleanT);
                });
              },
              orElse: () => '',
            );
        if (match.isNotEmpty &&
            !newChannels.any((c) =>
                c.sourceChannel?.equalsIgnoreCase(match) == true ||
                c.name.equalsIgnoreCase(item.$1))) {
          final idx = availableChannels.indexOf(match);
          final existing = baseList.firstWhere(
            (c) => c.name.equalsIgnoreCase(match),
            orElse: () => ChannelConfig(name: match),
          );
          final cleanMatch = cleanChannelLabel(match);
          final displayName = cleanMatch.equalsIgnoreCase(item.$1)
              ? item.$1
              : cleanMatch;
          newChannels.add(
            ChannelConfig(
              name: displayName,
              sourceChannel: match,
              sourceIndex: idx >= 0 ? idx : null,
              reReference: 'None',
              derived: false,
              displayOnScreen: true,
              color: 'Green',
              scalingFactor: existing.scalingFactor,
            ),
          );
        }
      }
    }

    // 5. Extended Limb Movement channels for PLM Preset or Comprehensive Preset
    if (preset.name.contains('PLM') || preset.name.contains('Comprehensive')) {
      final legSignals = [
        ('LAT', ['LAT', 'L-LEG', 'LEG_L', 'LEGL', 'EMG_LEG_L', 'TIB_L', 'TIB_LEFT', 'PLML', 'PLM_L', 'PLM-L', 'L-PLM', 'LPLM']),
        ('RAT', ['RAT', 'R-LEG', 'LEG_R', 'LEGR', 'EMG_LEG_R', 'TIB_R', 'TIB_RIGHT', 'PLMR', 'PLM_R', 'PLM-R', 'R-PLM', 'RPLM']),
        ('Position', ['POS', 'POSITION', 'BODYPOS', 'SLEEP_POS', 'POS.']),
      ];
      for (final item in legSignals) {
        final match = findMatchingElectrode(item.$1, availableChannels) ??
            availableChannels.firstWhere(
              (c) {
                final cleanC = cleanChannelLabel(c).toUpperCase();
                final alphanumC = cleanC.replaceAll(RegExp(r'[^A-Z0-9]'), '');
                return item.$2.any((t) {
                  final cleanT = t.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
                  return cleanC.contains(t) || alphanumC.contains(cleanT);
                });
              },
              orElse: () => '',
            );
        if (match.isNotEmpty &&
            !newChannels.any((c) =>
                c.sourceChannel?.equalsIgnoreCase(match) == true ||
                c.name.equalsIgnoreCase(item.$1))) {
          final idx = availableChannels.indexOf(match);
          final existing = baseList.firstWhere(
            (c) => c.name.equalsIgnoreCase(match),
            orElse: () => ChannelConfig(name: match),
          );
          final cleanMatch = cleanChannelLabel(match);
          final displayName = cleanMatch.equalsIgnoreCase(item.$1)
              ? item.$1
              : cleanMatch;
          newChannels.add(
            ChannelConfig(
              name: displayName,
              sourceChannel: match,
              sourceIndex: idx >= 0 ? idx : null,
              reReference: 'None',
              derived: false,
              displayOnScreen: true,
              color: 'Orange',
              scalingFactor: existing.scalingFactor,
            ),
          );
        }
      }
    }

    // Sort strictly according to standard clinical AASM sequence
    newChannels.sort((a, b) => aasmChannelSortKey(a).compareTo(aasmChannelSortKey(b)));
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
        (n) => n.name.equalsIgnoreCase(orig.name) ||
            (orig.sourceChannel != null && n.sourceChannel?.equalsIgnoreCase(orig.sourceChannel!) == true),
      )) {
        final copy = orig.copy();
        final rawIdx = availableChannels.indexOf(baseName);
        if (rawIdx >= 0) copy.sourceIndex = rawIdx;
        copy.displayOnScreen = false;
        newChannels.add(copy);
      }
    }
  }
  return newChannels;
}

/// Clinical AASM sequence sorting key.
int aasmChannelSortKey(ChannelConfig ch) {
  final name = ch.name.toUpperCase();
  if (name.startsWith('E1') || name.startsWith('EOG1') || name.startsWith('LOC')) return 10;
  if (name.startsWith('E2') || name.startsWith('EOG2') || name.startsWith('ROC')) return 11;
  if (name.startsWith('F4')) return 20;
  if (name.startsWith('F3')) return 21;
  if (name.startsWith('FZ')) return 22;
  if (name.startsWith('C4')) return 30;
  if (name.startsWith('C3')) return 31;
  if (name.startsWith('CZ')) return 32;
  if (name.startsWith('O2')) return 40;
  if (name.startsWith('O1')) return 41;
  if (name.startsWith('OZ')) return 42;
  if (name.contains('CHIN') || (name.contains('EMG') && !name.contains('LEG') && !name.contains('TIB'))) return 50;
  if (name.contains('ECG') || name.contains('EKG')) return 60;
  if (name.contains('FLOW') || name.contains('CANN') || name.contains('THERM') || name.contains('AIR')) return 70;
  if (name.contains('THOR') || name.contains('CHEST')) return 71;
  if (name.contains('ABDO') || name.contains('ABD')) return 72;
  if (name.contains('SPO2') || name.contains('SAO2') || name.contains('OX')) return 73;
  if (name.contains('SNORE') || name.contains('MIC')) return 74;
  if (name.contains('LAT') || name.contains('LEG_L') || name.contains('TIB_L') || name.contains('L-LEG')) return 80;
  if (name.contains('RAT') || name.contains('LEG_R') || name.contains('TIB_R') || name.contains('R-LEG')) return 81;
  if (name.contains('POS')) return 82;
  return 100;
}
