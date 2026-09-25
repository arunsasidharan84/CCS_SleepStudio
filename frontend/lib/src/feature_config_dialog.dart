// lib/src/feature_config_dialog.dart
//
// Dedicated configuration dialog and reusable widget for:
// 1. EEG Preprocessing parameters & Auto electric stim artefact removal (DBS).
// 2. Feature selection (spectral, complexity, spindles, slow waves, PAC, NLG).
// 3. Quantitative EEG parameters (spindles, slow waves, frequency band cutoffs).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  late final TextEditingController _spindleLoCtrl;
  late final TextEditingController _spindleHiCtrl;
  late final TextEditingController _spindleDurLoCtrl;
  late final TextEditingController _spindleDurHiCtrl;
  late final TextEditingController _swLoCtrl;
  late final TextEditingController _swHiCtrl;
  late final TextEditingController _swAmpCtrl;

  // Band cutoff controllers
  late final TextEditingController _deltaLoCtrl;
  late final TextEditingController _deltaHiCtrl;
  late final TextEditingController _thetaLoCtrl;
  late final TextEditingController _thetaHiCtrl;
  late final TextEditingController _alphaLoCtrl;
  late final TextEditingController _alphaHiCtrl;
  late final TextEditingController _sigmaLoCtrl;
  late final TextEditingController _sigmaHiCtrl;
  late final TextEditingController _betaLoCtrl;
  late final TextEditingController _betaHiCtrl;
  late final TextEditingController _gammaLoCtrl;
  late final TextEditingController _gammaHiCtrl;

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

    _spindleLoCtrl = TextEditingController(text: c.spindleFreqMin.toString());
    _spindleHiCtrl = TextEditingController(text: c.spindleFreqMax.toString());
    _spindleDurLoCtrl = TextEditingController(text: c.spindleDurationMin.toString());
    _spindleDurHiCtrl = TextEditingController(text: c.spindleDurationMax.toString());
    _swLoCtrl = TextEditingController(text: c.slowWaveFreqMin.toString());
    _swHiCtrl = TextEditingController(text: c.slowWaveFreqMax.toString());
    _swAmpCtrl = TextEditingController(text: c.slowWaveMinAmpUv.toString());

    _deltaLoCtrl = TextEditingController(text: c.bandDeltaLo.toString());
    _deltaHiCtrl = TextEditingController(text: c.bandDeltaHi.toString());
    _thetaLoCtrl = TextEditingController(text: c.bandThetaLo.toString());
    _thetaHiCtrl = TextEditingController(text: c.bandThetaHi.toString());
    _alphaLoCtrl = TextEditingController(text: c.bandAlphaLo.toString());
    _alphaHiCtrl = TextEditingController(text: c.bandAlphaHi.toString());
    _sigmaLoCtrl = TextEditingController(text: c.bandSigmaLo.toString());
    _sigmaHiCtrl = TextEditingController(text: c.bandSigmaHi.toString());
    _betaLoCtrl = TextEditingController(text: c.bandBetaLo.toString());
    _betaHiCtrl = TextEditingController(text: c.bandBetaHi.toString());
    _gammaLoCtrl = TextEditingController(text: c.bandGammaLo.toString());
    _gammaHiCtrl = TextEditingController(text: c.bandGammaHi.toString());
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

    _spindleLoCtrl.dispose();
    _spindleHiCtrl.dispose();
    _spindleDurLoCtrl.dispose();
    _spindleDurHiCtrl.dispose();
    _swLoCtrl.dispose();
    _swHiCtrl.dispose();
    _swAmpCtrl.dispose();

    _deltaLoCtrl.dispose();
    _deltaHiCtrl.dispose();
    _thetaLoCtrl.dispose();
    _thetaHiCtrl.dispose();
    _alphaLoCtrl.dispose();
    _alphaHiCtrl.dispose();
    _sigmaLoCtrl.dispose();
    _sigmaHiCtrl.dispose();
    _betaLoCtrl.dispose();
    _betaHiCtrl.dispose();
    _gammaLoCtrl.dispose();
    _gammaHiCtrl.dispose();
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

                  // Frequency Bands
                  const Text('EEG Frequency Band Definitions (Hz):', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: _buildField(
                          label: 'Delta Lo (Hz)',
                          controller: _deltaLoCtrl,
                          onChanged: (v) => c.bandDeltaLo = v ?? 0.5,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Delta Hi (Hz)',
                          controller: _deltaHiCtrl,
                          onChanged: (v) => c.bandDeltaHi = v ?? 4.0,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildField(
                          label: 'Theta Lo (Hz)',
                          controller: _thetaLoCtrl,
                          onChanged: (v) => c.bandThetaLo = v ?? 4.0,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Theta Hi (Hz)',
                          controller: _thetaHiCtrl,
                          onChanged: (v) => c.bandThetaHi = v ?? 8.0,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildField(
                          label: 'Alpha Lo (Hz)',
                          controller: _alphaLoCtrl,
                          onChanged: (v) => c.bandAlphaLo = v ?? 8.0,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Alpha Hi (Hz)',
                          controller: _alphaHiCtrl,
                          onChanged: (v) => c.bandAlphaHi = v ?? 12.0,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _buildField(
                          label: 'Sigma Lo (Hz)',
                          controller: _sigmaLoCtrl,
                          onChanged: (v) => c.bandSigmaLo = v ?? 12.0,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Sigma Hi (Hz)',
                          controller: _sigmaHiCtrl,
                          onChanged: (v) => c.bandSigmaHi = v ?? 16.0,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildField(
                          label: 'Beta Lo (Hz)',
                          controller: _betaLoCtrl,
                          onChanged: (v) => c.bandBetaLo = v ?? 16.0,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Beta Hi (Hz)',
                          controller: _betaHiCtrl,
                          onChanged: (v) => c.bandBetaHi = v ?? 30.0,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildField(
                          label: 'Gamma Lo (Hz)',
                          controller: _gammaLoCtrl,
                          onChanged: (v) => c.bandGammaLo = v ?? 30.0,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Gamma Hi (Hz)',
                          controller: _gammaHiCtrl,
                          onChanged: (v) => c.bandGammaHi = v ?? 45.0,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Spindle & Slow Wave detection thresholds
                  const Text('Event Detection Thresholds:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
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
                          label: 'Spindle Dur Min (s)',
                          controller: _spindleDurLoCtrl,
                          onChanged: (v) => c.spindleDurationMin = v ?? 0.5,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Spindle Dur Max (s)',
                          controller: _spindleDurHiCtrl,
                          onChanged: (v) => c.spindleDurationMax = v ?? 3.0,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildField(
                          label: 'Slow Wave Freq Min',
                          controller: _swLoCtrl,
                          onChanged: (v) => c.slowWaveFreqMin = v ?? 0.3,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Slow Wave Freq Max',
                          controller: _swHiCtrl,
                          onChanged: (v) => c.slowWaveFreqMax = v ?? 2.0,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildField(
                          label: 'Slow Wave Min (µV)',
                          controller: _swAmpCtrl,
                          onChanged: (v) => c.slowWaveMinAmpUv = v ?? 75.0,
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
