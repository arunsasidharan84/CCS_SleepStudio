// lib/src/feature_config_dialog.dart
//
// Dedicated configuration dialog and reusable widget for:
// 1. EEG Preprocessing parameters & Auto electric stim artefact removal (DBS).
// 2. Feature selection (spectral, complexity, spindles, slow waves, PAC, NLG).
// 3. Quantitative EEG parameters (spindles, slow waves, frequency band cutoffs).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'models.dart';
import 'eeg_backend.dart';
import 'analyse_options.dart';

class FeatureSelectionAndConfigDialog extends StatefulWidget {
  const FeatureSelectionAndConfigDialog({
    super.key,
    required this.config,
    required this.onApply,
  });

  final AppConfig config;
  final void Function(AppConfig) onApply;

  @override
  State<FeatureSelectionAndConfigDialog> createState() =>
      _FeatureSelectionAndConfigDialogState();
}

class _FeatureSelectionAndConfigDialogState
    extends State<FeatureSelectionAndConfigDialog> {
  late AppConfig _working;

  @override
  void initState() {
    super.initState();
    _working = AppConfig.fromJson(widget.config.toJson());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.tune, color: Colors.indigo),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Feature Selection & Parameter Configuration',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      content: SizedBox(
        width: 880,
        height: 620,
        child: FeaturesAndPreprocessingWidget(config: _working),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            widget.onApply(_working);
            Navigator.of(context).pop();
          },
          child: const Text('Save & Apply Settings'),
        ),
      ],
    );
  }
}

/// Controller wrapper for an individual frequency band row.
class _BandControllers {
  final TextEditingController labelCtrl;
  final TextEditingController lowCtrl;
  final TextEditingController highCtrl;

  _BandControllers({
    required String label,
    required double low,
    required double high,
  })  : labelCtrl = TextEditingController(text: label),
        lowCtrl = TextEditingController(text: low.toString()),
        highCtrl = TextEditingController(text: high.toString());

  void dispose() {
    labelCtrl.dispose();
    lowCtrl.dispose();
    highCtrl.dispose();
  }
}

/// Reusable widget containing all Preprocessing and Feature Extraction parameter controls.
class FeaturesAndPreprocessingWidget extends StatefulWidget {
  const FeaturesAndPreprocessingWidget({super.key, required this.config});

  final AppConfig config;

  @override
  State<FeaturesAndPreprocessingWidget> createState() =>
      _FeaturesAndPreprocessingWidgetState();
}

class _FeaturesAndPreprocessingWidgetState
    extends State<FeaturesAndPreprocessingWidget> {
  // Preprocessing controllers
  late final TextEditingController _downsampleCtrl;
  late final TextEditingController _bpLoCtrl;
  late final TextEditingController _bpHiCtrl;
  late final TextEditingController _notchCtrl;
  late final TextEditingController _ransacCtrl;
  late final TextEditingController _stimF0Ctrl;
  late final TextEditingController _stimWinCtrl;
  late final TextEditingController _stimCombsCtrl;

  // Feature detection controllers
  late final TextEditingController _epochLenCtrl;
  late final TextEditingController _featureWinCtrl;
  late final TextEditingController _spindleLoCtrl;
  late final TextEditingController _spindleHiCtrl;
  late final TextEditingController _spindleDurLoCtrl;
  late final TextEditingController _spindleDurHiCtrl;
  late final TextEditingController _spindleRelPowCtrl;
  late final TextEditingController _spindleCorrCtrl;
  late final TextEditingController _spindleRmsCtrl;

  late final TextEditingController _swLoCtrl;
  late final TextEditingController _swHiCtrl;
  late final TextEditingController _swMinPtpCtrl;
  late final TextEditingController _swMaxPtpCtrl;
  late final TextEditingController _swMinNegAmpCtrl;
  late final TextEditingController _swMaxNegAmpCtrl;
  late final TextEditingController _swMinPosAmpCtrl;
  late final TextEditingController _swMaxPosAmpCtrl;
  late final TextEditingController _swDurMinCtrl;
  late final TextEditingController _swDurMaxCtrl;
  late final TextEditingController _swNegDurMinCtrl;
  late final TextEditingController _swNegDurMaxCtrl;
  late final TextEditingController _swPosDurMinCtrl;
  late final TextEditingController _swPosDurMaxCtrl;

  // Flexible frequency band controllers
  late final List<_BandControllers> _bandCtrls;

  @override
  void initState() {
    super.initState();
    final c = widget.config;
    _downsampleCtrl = TextEditingController(text: c.preprocessDownsampleHz.toString());
    _bpLoCtrl = TextEditingController(text: c.preprocessBandpassLo.toString());
    _bpHiCtrl = TextEditingController(text: c.preprocessBandpassHi.toString());
    _notchCtrl = TextEditingController(text: c.preprocessNotchHz.toString());
    _ransacCtrl = TextEditingController(text: c.preprocessRansacThresh.toString());
    _stimF0Ctrl = TextEditingController(text: c.preprocessStimF0 != null ? c.preprocessStimF0.toString() : '');
    _stimWinCtrl = TextEditingController(text: c.preprocessStimWin.toString());
    _stimCombsCtrl = TextEditingController(text: c.preprocessStimMaxCombs.toString());

    _epochLenCtrl = TextEditingController(text: c.epochLengthSeconds.toString());
    _featureWinCtrl = TextEditingController(text: c.featureWindowSeconds.toString());
    _spindleLoCtrl = TextEditingController(text: c.spindleFreqMin.toString());
    _spindleHiCtrl = TextEditingController(text: c.spindleFreqMax.toString());
    _spindleDurLoCtrl = TextEditingController(text: c.spindleDurationMin.toString());
    _spindleDurHiCtrl = TextEditingController(text: c.spindleDurationMax.toString());
    _spindleRelPowCtrl = TextEditingController(text: c.spindleRelPowerThresh.toString());
    _spindleCorrCtrl = TextEditingController(text: c.spindleCorrThresh.toString());
    _spindleRmsCtrl = TextEditingController(text: c.spindleRmsMultiplier.toString());

    _swLoCtrl = TextEditingController(text: c.slowWaveFreqMin.toString());
    _swHiCtrl = TextEditingController(text: c.slowWaveFreqMax.toString());
    _swMinPtpCtrl = TextEditingController(text: c.slowWaveMinPtpUv.toString());
    _swMaxPtpCtrl = TextEditingController(text: c.slowWaveMaxPtpUv.toString());
    _swMinNegAmpCtrl = TextEditingController(text: c.slowWaveMinNegAmpUv.toString());
    _swMaxNegAmpCtrl = TextEditingController(text: c.slowWaveMaxNegAmpUv.toString());
    _swMinPosAmpCtrl = TextEditingController(text: c.slowWaveMinPosAmpUv.toString());
    _swMaxPosAmpCtrl = TextEditingController(text: c.slowWaveMaxPosAmpUv.toString());
    _swDurMinCtrl = TextEditingController(text: c.slowWaveDurationMin.toString());
    _swDurMaxCtrl = TextEditingController(text: c.slowWaveDurationMax.toString());
    _swNegDurMinCtrl = TextEditingController(text: c.slowWaveNegDurationMin.toString());
    _swNegDurMaxCtrl = TextEditingController(text: c.slowWaveNegDurationMax.toString());
    _swPosDurMinCtrl = TextEditingController(text: c.slowWavePosDurationMin.toString());
    _swPosDurMaxCtrl = TextEditingController(text: c.slowWavePosDurationMax.toString());

    _bandCtrls = c.bands
        .map((b) => _BandControllers(label: b.label, low: b.low, high: b.high))
        .toList();
  }

  @override
  void dispose() {
    _downsampleCtrl.dispose();
    _bpLoCtrl.dispose();
    _bpHiCtrl.dispose();
    _notchCtrl.dispose();
    _ransacCtrl.dispose();
    _stimF0Ctrl.dispose();
    _stimWinCtrl.dispose();
    _stimCombsCtrl.dispose();

    _epochLenCtrl.dispose();
    _featureWinCtrl.dispose();
    _spindleLoCtrl.dispose();
    _spindleHiCtrl.dispose();
    _spindleDurLoCtrl.dispose();
    _spindleDurHiCtrl.dispose();
    _spindleRelPowCtrl.dispose();
    _spindleCorrCtrl.dispose();
    _spindleRmsCtrl.dispose();

    _swLoCtrl.dispose();
    _swHiCtrl.dispose();
    _swMinPtpCtrl.dispose();
    _swMaxPtpCtrl.dispose();
    _swMinNegAmpCtrl.dispose();
    _swMaxNegAmpCtrl.dispose();
    _swMinPosAmpCtrl.dispose();
    _swMaxPosAmpCtrl.dispose();
    _swDurMinCtrl.dispose();
    _swDurMaxCtrl.dispose();
    _swNegDurMinCtrl.dispose();
    _swNegDurMaxCtrl.dispose();
    _swPosDurMinCtrl.dispose();
    _swPosDurMaxCtrl.dispose();

    for (final ctrl in _bandCtrls) {
      ctrl.dispose();
    }
    super.dispose();
  }

  Widget _buildField({
    required String label,
    required TextEditingController controller,
    required void Function(double?) onChanged,
    String? hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500)),
        const SizedBox(height: 3),
        SizedBox(
          height: 32,
          child: TextFormField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*'))],
            decoration: InputDecoration(
              hintText: hint,
              isDense: true,
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            ),
            style: const TextStyle(fontSize: 12),
            onChanged: (v) => onChanged(double.tryParse(v.trim())),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.config;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ─── 1. Preprocessing Configuration ────────────────────────────────
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: Colors.grey.shade300),
            ),
            color: Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.auto_fix_high, color: Colors.purple, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'Preprocessing Pipeline & DBS Artefact Removal',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Default parameters used by ccstools / AnalyseNidra in interactive and batch preprocessing.',
                    style: TextStyle(fontSize: 11.5, color: Colors.black54),
                  ),
                  const Divider(height: 16),

                  // DBS / Electrical Stim Artefact Removal
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade50.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.amber.shade300),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Checkbox(
                              value: c.preprocessStimArtifact,
                              onChanged: (v) => setState(() => c.preprocessStimArtifact = v ?? false),
                            ),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Auto electric stim artefact removal (DBS / neurostimulator)',
                                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
                                  ),
                                  Text(
                                    'Continuous adaptive harmonic comb filter: removes periodic electrical stimulation on the continuous raw signal (not epoch-based like GEDAI).',
                                    style: TextStyle(fontSize: 10.5, color: Colors.black87),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (c.preprocessStimArtifact) ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: _buildField(
                                  label: 'Fundamental Freq f0 (Hz)',
                                  controller: _stimF0Ctrl,
                                  hint: 'blank = auto-detect',
                                  onChanged: (v) => c.preprocessStimF0 = v,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _buildField(
                                  label: 'Comb Window (sec)',
                                  controller: _stimWinCtrl,
                                  hint: '10.0',
                                  onChanged: (v) => c.preprocessStimWin = v ?? 10.0,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _buildField(
                                  label: 'Max Combs',
                                  controller: _stimCombsCtrl,
                                  hint: '4',
                                  onChanged: (v) => c.preprocessStimMaxCombs = v?.toInt() ?? 4,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Signal Filters and Resampling
                  Row(
                    children: [
                      Expanded(
                        child: _buildField(
                          label: 'Bandpass Low (Hz)',
                          controller: _bpLoCtrl,
                          hint: '0.5',
                          onChanged: (v) => c.preprocessBandpassLo = v ?? 0.5,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildField(
                          label: 'Bandpass High (Hz)',
                          controller: _bpHiCtrl,
                          hint: '40.0',
                          onChanged: (v) => c.preprocessBandpassHi = v ?? 40.0,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildField(
                          label: 'Notch Filter (Hz)',
                          controller: _notchCtrl,
                          hint: '50.0 (0=off)',
                          onChanged: (v) => c.preprocessNotchHz = v ?? 50.0,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildField(
                          label: 'Downsample (Hz)',
                          controller: _downsampleCtrl,
                          hint: '250',
                          onChanged: (v) => c.preprocessDownsampleHz = v ?? 250.0,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildField(
                          label: 'RANSAC Bad-Ch Corr',
                          controller: _ransacCtrl,
                          hint: '0.75',
                          onChanged: (v) => c.preprocessRansacThresh = v ?? 0.75,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ─── 2. Feature Selection ──────────────────────────────────────────
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: Colors.grey.shade300),
            ),
            color: Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.hub, color: Colors.blue, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'Feature Selection (AnalyseNidra Extraction Modules)',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Select which quantitative sleep EEG feature families to compute during sleep analysis.',
                    style: TextStyle(fontSize: 11.5, color: Colors.black54),
                  ),
                  const Divider(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final a in kAnalyseNidraAnalyses)
                        SizedBox(
                          width: 380,
                          child: CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(a.$2, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                            subtitle: Text(a.$3, style: const TextStyle(fontSize: 10.5)),
                            value: c.featureAnalyses.contains(a.$1),
                            onChanged: (v) {
                              setState(() {
                                if (v ?? false) {
                                  if (!c.featureAnalyses.contains(a.$1)) c.featureAnalyses.add(a.$1);
                                } else {
                                  c.featureAnalyses.remove(a.$1);
                                }
                              });
                            },
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ─── 3. Quantitative EEG Parameters ────────────────────────────────
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: Colors.grey.shade300),
            ),
            color: Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.graphic_eq, color: Colors.teal, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'Quantitative Sleep EEG Parameters & Frequency Bands',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Define standard frequency band limits (Hz) and spindle / slow-wave event detection thresholds.',
                    style: TextStyle(fontSize: 11.5, color: Colors.black54),
                  ),
                  const Divider(height: 16),

                  // Analysis Windows & Epochs
                  const Text('Epoch & Sub-Window Durations (s):', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: _buildField(
                          label: 'Epoch Length (s)',
                          controller: _epochLenCtrl,
                          hint: '30.0',
                          onChanged: (v) => c.epochLengthSeconds = v ?? 30.0,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildField(
                          label: 'Feature Sub-Window (s)',
                          controller: _featureWinCtrl,
                          hint: '15.0',
                          onChanged: (v) => c.featureWindowSeconds = v ?? 15.0,
                        ),
                      ),
                      const Spacer(),
                      const Spacer(),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Flexible Frequency Bands
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'EEG Frequency Band Definitions (Hz):',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            ),
                            icon: const Icon(Icons.add, size: 16),
                            label: const Text('Add Band', style: TextStyle(fontSize: 11.5)),
                            onPressed: () {
                              setState(() {
                                final newBand = BandConfig(label: 'Custom', low: 4.0, high: 12.0);
                                c.bands.add(newBand);
                                _bandCtrls.add(_BandControllers(
                                  label: newBand.label,
                                  low: newBand.low,
                                  high: newBand.high,
                                ));
                                c.syncLegacyBandFields();
                              });
                            },
                          ),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              foregroundColor: Colors.indigo,
                            ),
                            icon: const Icon(Icons.playlist_add, size: 16),
                            label: const Text('Add Theta-Alpha (4–12 Hz)', style: TextStyle(fontSize: 11.5)),
                            onPressed: () {
                              setState(() {
                                final hasThetaAlpha = c.bands.any(
                                  (b) =>
                                      b.label.toLowerCase() == 'thetaalpha' ||
                                      b.label.toLowerCase() == 'theta-alpha',
                                );
                                if (!hasThetaAlpha) {
                                  final newBand =
                                      BandConfig(label: 'ThetaAlpha', low: 4.0, high: 12.0);
                                  final idx = c.bands.indexWhere((b) => b.label.toLowerCase() == 'theta');
                                  final insertIdx = idx >= 0 ? idx + 1 : c.bands.length;
                                  c.bands.insert(insertIdx, newBand);
                                  _bandCtrls.insert(
                                    insertIdx,
                                    _BandControllers(
                                      label: newBand.label,
                                      low: newBand.low,
                                      high: newBand.high,
                                    ),
                                  );
                                  c.syncLegacyBandFields();
                                }
                              });
                            },
                          ),
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            ),
                            icon: const Icon(Icons.restore, size: 15),
                            label: const Text('Reset Defaults', style: TextStyle(fontSize: 11.5)),
                            onPressed: () {
                              setState(() {
                                for (final ctrl in _bandCtrls) {
                                  ctrl.dispose();
                                }
                                _bandCtrls.clear();
                                c.bands = defaultFrequencyBands();
                                for (final b in c.bands) {
                                  _bandCtrls.add(_BandControllers(
                                    label: b.label,
                                    low: b.low,
                                    high: b.high,
                                  ));
                                }
                                c.syncLegacyBandFields();
                              });
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(6),
                      color: Colors.grey.shade50,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Column(
                      children: [
                        for (int i = 0; i < c.bands.length; i++)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 170,
                                  height: 32,
                                  child: TextFormField(
                                    controller: _bandCtrls[i].labelCtrl,
                                    decoration: const InputDecoration(
                                      labelText: 'Band Name',
                                      isDense: true,
                                      border: OutlineInputBorder(),
                                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                    ),
                                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                                    onChanged: (v) {
                                      c.bands[i].label = v.trim();
                                      c.syncLegacyBandFields();
                                    },
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: SizedBox(
                                    height: 32,
                                    child: TextFormField(
                                      controller: _bandCtrls[i].lowCtrl,
                                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*'))],
                                      decoration: const InputDecoration(
                                        labelText: 'Low (Hz)',
                                        isDense: true,
                                        border: OutlineInputBorder(),
                                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                      ),
                                      style: const TextStyle(fontSize: 12),
                                      onChanged: (v) {
                                        final val = double.tryParse(v.trim());
                                        if (val != null) {
                                          c.bands[i].low = val;
                                          c.syncLegacyBandFields();
                                        }
                                      },
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Text('–', style: TextStyle(fontWeight: FontWeight.bold)),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: SizedBox(
                                    height: 32,
                                    child: TextFormField(
                                      controller: _bandCtrls[i].highCtrl,
                                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*'))],
                                      decoration: const InputDecoration(
                                        labelText: 'High (Hz)',
                                        isDense: true,
                                        border: OutlineInputBorder(),
                                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                      ),
                                      style: const TextStyle(fontSize: 12),
                                      onChanged: (v) {
                                        final val = double.tryParse(v.trim());
                                        if (val != null) {
                                          c.bands[i].high = val;
                                          c.syncLegacyBandFields();
                                        }
                                      },
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                                  tooltip: 'Remove ${c.bands[i].label}',
                                  onPressed: c.bands.length <= 1
                                      ? null
                                      : () {
                                          setState(() {
                                            _bandCtrls[i].dispose();
                                            _bandCtrls.removeAt(i);
                                            c.bands.removeAt(i);
                                            c.syncLegacyBandFields();
                                          });
                                        },
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Spindle detection thresholds
                  const Text('Sleep Spindle Detection Parameters:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: _buildField(
                          label: 'Spindle Freq Min (Hz)',
                          controller: _spindleLoCtrl,
                          onChanged: (v) => c.spindleFreqMin = v ?? 11.0,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Spindle Freq Max (Hz)',
                          controller: _spindleHiCtrl,
                          onChanged: (v) => c.spindleFreqMax = v ?? 16.0,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Duration Min (s)',
                          controller: _spindleDurLoCtrl,
                          onChanged: (v) => c.spindleDurationMin = v ?? 0.5,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Duration Max (s)',
                          controller: _spindleDurHiCtrl,
                          onChanged: (v) => c.spindleDurationMax = v ?? 2.0,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _buildField(
                          label: 'Rel Power Thresh',
                          controller: _spindleRelPowCtrl,
                          hint: '0.20',
                          onChanged: (v) => c.spindleRelPowerThresh = v ?? 0.20,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Correlation Thresh',
                          controller: _spindleCorrCtrl,
                          hint: '0.65',
                          onChanged: (v) => c.spindleCorrThresh = v ?? 0.65,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'RMS Multiplier',
                          controller: _spindleRmsCtrl,
                          hint: '1.5',
                          onChanged: (v) => c.spindleRmsMultiplier = v ?? 1.5,
                        ),
                      ),
                      const Spacer(),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Slow wave detection thresholds
                  const Text('Slow Wave Detection Parameters:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: _buildField(
                          label: 'SW Freq Min (Hz)',
                          controller: _swLoCtrl,
                          hint: '0.3',
                          onChanged: (v) => c.slowWaveFreqMin = v ?? 0.3,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'SW Freq Max (Hz)',
                          controller: _swHiCtrl,
                          hint: '2.0',
                          onChanged: (v) => c.slowWaveFreqMax = v ?? 2.0,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Min PTP Amp (µV)',
                          controller: _swMinPtpCtrl,
                          hint: '75.0',
                          onChanged: (v) {
                            c.slowWaveMinPtpUv = v ?? 75.0;
                            c.slowWaveMinAmpUv = v ?? 75.0;
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Max PTP Amp (µV)',
                          controller: _swMaxPtpCtrl,
                          hint: '350.0',
                          onChanged: (v) => c.slowWaveMaxPtpUv = v ?? 350.0,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _buildField(
                          label: 'Min Neg Amp (µV)',
                          controller: _swMinNegAmpCtrl,
                          hint: '40.0',
                          onChanged: (v) => c.slowWaveMinNegAmpUv = v ?? 40.0,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Max Neg Amp (µV)',
                          controller: _swMaxNegAmpCtrl,
                          hint: '200.0',
                          onChanged: (v) => c.slowWaveMaxNegAmpUv = v ?? 200.0,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Min Pos Amp (µV)',
                          controller: _swMinPosAmpCtrl,
                          hint: '10.0',
                          onChanged: (v) => c.slowWaveMinPosAmpUv = v ?? 10.0,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Max Pos Amp (µV)',
                          controller: _swMaxPosAmpCtrl,
                          hint: '150.0',
                          onChanged: (v) => c.slowWaveMaxPosAmpUv = v ?? 150.0,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _buildField(
                          label: 'Total Dur Min (s)',
                          controller: _swDurMinCtrl,
                          hint: '0.4',
                          onChanged: (v) => c.slowWaveDurationMin = v ?? 0.4,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Total Dur Max (s)',
                          controller: _swDurMaxCtrl,
                          hint: '2.5',
                          onChanged: (v) => c.slowWaveDurationMax = v ?? 2.5,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Neg Dur Min (s)',
                          controller: _swNegDurMinCtrl,
                          hint: '0.3',
                          onChanged: (v) => c.slowWaveNegDurationMin = v ?? 0.3,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Neg Dur Max (s)',
                          controller: _swNegDurMaxCtrl,
                          hint: '1.5',
                          onChanged: (v) => c.slowWaveNegDurationMax = v ?? 1.5,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Pos Dur Min (s)',
                          controller: _swPosDurMinCtrl,
                          hint: '0.1',
                          onChanged: (v) => c.slowWavePosDurationMin = v ?? 0.1,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Pos Dur Max (s)',
                          controller: _swPosDurMaxCtrl,
                          hint: '1.0',
                          onChanged: (v) => c.slowWavePosDurationMax = v ?? 1.0,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
