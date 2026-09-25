// lib/src/config_dialog.dart
//
// Configuration dialog matching PyQt sleep EEG app's multi-tab layout.
//

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'eeg_backend.dart';
import 'models.dart';
import 'feature_config_dialog.dart';

class ConfigDialog extends StatefulWidget {
  const ConfigDialog({
    super.key,
    required this.config,
    required this.channelLabels,
    required this.onApply,
    this.onPreview,
    this.initialTabIndex = 0,
  });

  final AppConfig config;
  final List<String> channelLabels;
  final void Function(AppConfig) onApply;
  final void Function(AppConfig)? onPreview;
  final int initialTabIndex;

  @override
  State<ConfigDialog> createState() => _ConfigDialogState();
}

class _ConfigDialogState extends State<ConfigDialog> {
  late AppConfig _working;
  bool _applyAllChannels = false;

  // Text controllers
  late final TextEditingController _amplCtrl;
  late final TextEditingController _distanceCtrl;
  late final TextEditingController _referenceCtrl;
  late final TextEditingController _tfMinCtrl;
  late final TextEditingController _tfMaxCtrl;
  late final TextEditingController _tfPowerMinCtrl;
  late final TextEditingController _tfPowerMaxCtrl;
  late final TextEditingController _spectMinCtrl;
  late final TextEditingController _spectMaxCtrl;
  late final TextEditingController _spectFreqMinCtrl;
  late final TextEditingController _spectFreqMaxCtrl;
  late final TextEditingController _periodFreqMinCtrl;
  late final TextEditingController _periodFreqMaxCtrl;
  late final TextEditingController _spectrogramFlexCtrl;
  late final TextEditingController _hypnogramFlexCtrl;
  late final TextEditingController _periodogramFlexCtrl;
  late final TextEditingController _refLineThicknessCtrl;
  late final TextEditingController _reportTitleCtrl;
  late final TextEditingController _studySiteCtrl;
  late final TextEditingController _investigatorCtrl;
  late final TextEditingController _subjectIdCtrl;
  late final TextEditingController _subjectDetailsCtrl;
  late final TextEditingController _recordingDateCtrl;

  @override
  void initState() {
    super.initState();
    // Copy the configuration fields
    _working = AppConfig(
      spectrogramChannelIndex: widget.config.spectrogramChannelIndex,
      swaChannelIndex: widget.config.swaChannelIndex,
      periodogramChannelIndex: widget.config.periodogramChannelIndex,
      tfChannelIndex: widget.config.tfChannelIndex,
      amplitudeRangeUv: widget.config.amplitudeRangeUv,
      tfFreqMin: widget.config.tfFreqMin,
      tfFreqMax: widget.config.tfFreqMax,
      spectrogramFreqMin: widget.config.spectrogramFreqMin,
      spectrogramFreqMax: widget.config.spectrogramFreqMax,
      periodogramFreqMin: widget.config.periodogramFreqMin,
      periodogramFreqMax: widget.config.periodogramFreqMax,
      spectrogramPowerMin: widget.config.spectrogramPowerMin,
      spectrogramPowerMax: widget.config.spectrogramPowerMax,
      tfEnabled: widget.config.tfEnabled,
      tfDisplayMode: widget.config.tfDisplayMode,
      tfFrequencyScale: widget.config.tfFrequencyScale,
      tfShowRidge: widget.config.tfShowRidge,
      tfAutoScale: widget.config.tfAutoScale,
      tfPowerMin: widget.config.tfPowerMin,
      tfPowerMax: widget.config.tfPowerMax,
      stackChannels: widget.config.stackChannels,
      robustZStandardize: widget.config.robustZStandardize,
      periodogramDisplayMode: widget.config.periodogramDisplayMode,
      eegPanelTimeUnit: widget.config.eegPanelTimeUnit,
      distanceBetweenChannelsUv: widget.config.distanceBetweenChannelsUv,
      referenceAmplitudeLineUv: widget.config.referenceAmplitudeLineUv,
      spectrogramFlex: widget.config.spectrogramFlex,
      hypnogramFlex: widget.config.hypnogramFlex,
      periodogramFlex: widget.config.periodogramFlex,
      showSwaPlot: widget.config.showSwaPlot,
      hypnogramOverlayMode: widget.config.hypnogramOverlayMode,
      hypnogramProbabilityStage: widget.config.hypnogramProbabilityStage,
      lightsOffSeconds: widget.config.lightsOffSeconds,
      lightsOnSeconds: widget.config.lightsOnSeconds,
      referenceLineThickness: widget.config.referenceLineThickness,
      referenceLineColor: widget.config.referenceLineColor,
      hypnogramZoom: widget.config.hypnogramZoom,
      reportTitle: widget.config.reportTitle,
      studySite: widget.config.studySite,
      investigatorName: widget.config.investigatorName,
      subjectId: widget.config.subjectId,
      subjectDetails: widget.config.subjectDetails,
      recordingDate: widget.config.recordingDate,
      preprocessDownsampleHz: widget.config.preprocessDownsampleHz,
      preprocessBandpassLo: widget.config.preprocessBandpassLo,
      preprocessBandpassHi: widget.config.preprocessBandpassHi,
      preprocessNotchHz: widget.config.preprocessNotchHz,
      preprocessRansacThresh: widget.config.preprocessRansacThresh,
      preprocessStimArtifact: widget.config.preprocessStimArtifact,
      preprocessStimF0: widget.config.preprocessStimF0,
      preprocessStimWin: widget.config.preprocessStimWin,
      preprocessStimMaxCombs: widget.config.preprocessStimMaxCombs,
      featureAnalyses: List.from(widget.config.featureAnalyses),
      spindleFreqMin: widget.config.spindleFreqMin,
      spindleFreqMax: widget.config.spindleFreqMax,
      spindleDurationMin: widget.config.spindleDurationMin,
      spindleDurationMax: widget.config.spindleDurationMax,
      slowWaveFreqMin: widget.config.slowWaveFreqMin,
      slowWaveFreqMax: widget.config.slowWaveFreqMax,
      slowWaveMinAmpUv: widget.config.slowWaveMinAmpUv,
      bandDeltaLo: widget.config.bandDeltaLo,
      bandDeltaHi: widget.config.bandDeltaHi,
      bandThetaLo: widget.config.bandThetaLo,
      bandThetaHi: widget.config.bandThetaHi,
      bandAlphaLo: widget.config.bandAlphaLo,
      bandAlphaHi: widget.config.bandAlphaHi,
      bandSigmaLo: widget.config.bandSigmaLo,
      bandSigmaHi: widget.config.bandSigmaHi,
      bandBetaLo: widget.config.bandBetaLo,
      bandBetaHi: widget.config.bandBetaHi,
      bandGammaLo: widget.config.bandGammaLo,
      bandGammaHi: widget.config.bandGammaHi,
      channels: widget.config.channels.isNotEmpty
          ? widget.config.channels.map((c) => c.copy()).toList()
          : widget.channelLabels
                .asMap()
                .entries
                .map(
                  (entry) =>
                      ChannelConfig(name: entry.value, sourceIndex: entry.key),
                )
                .toList(),
    );
    _amplCtrl = TextEditingController(
      text: _working.amplitudeRangeUv.toStringAsFixed(1),
    );
    _distanceCtrl = TextEditingController(
      text: _working.distanceBetweenChannelsUv.toStringAsFixed(1),
    );
    _referenceCtrl = TextEditingController(
      text: _working.referenceAmplitudeLineUv.toStringAsFixed(1),
    );
    _tfMinCtrl = TextEditingController(
      text: _working.tfFreqMin.toStringAsFixed(2),
    );
    _tfMaxCtrl = TextEditingController(
      text: _working.tfFreqMax.toStringAsFixed(1),
    );
    _tfPowerMinCtrl = TextEditingController(
      text: _working.tfPowerMin.toStringAsFixed(1),
    );
    _tfPowerMaxCtrl = TextEditingController(
      text: _working.tfPowerMax.toStringAsFixed(1),
    );
    _spectMinCtrl = TextEditingController(
      text: _working.spectrogramPowerMin.toStringAsFixed(1),
    );
    _spectMaxCtrl = TextEditingController(
      text: _working.spectrogramPowerMax.toStringAsFixed(1),
    );
    _spectFreqMinCtrl = TextEditingController(
      text: _working.spectrogramFreqMin.toStringAsFixed(0),
    );
    _spectFreqMaxCtrl = TextEditingController(
      text: _working.spectrogramFreqMax.toStringAsFixed(0),
    );
    _periodFreqMinCtrl = TextEditingController(
      text: _working.periodogramFreqMin.toStringAsFixed(0),
    );
    _periodFreqMaxCtrl = TextEditingController(
      text: _working.periodogramFreqMax.toStringAsFixed(0),
    );
    _spectrogramFlexCtrl = TextEditingController(
      text: _working.spectrogramFlex.toString(),
    );
    _hypnogramFlexCtrl = TextEditingController(
      text: _working.hypnogramFlex.toString(),
    );
    _periodogramFlexCtrl = TextEditingController(
      text: _working.periodogramFlex.toString(),
    );
    _refLineThicknessCtrl = TextEditingController(
      text: _working.referenceLineThickness.toStringAsFixed(2),
    );
    _reportTitleCtrl = TextEditingController(text: _working.reportTitle);
    _studySiteCtrl = TextEditingController(text: _working.studySite);
    _investigatorCtrl = TextEditingController(text: _working.investigatorName);
    _subjectIdCtrl = TextEditingController(text: _working.subjectId);
    _subjectDetailsCtrl = TextEditingController(text: _working.subjectDetails);
    _recordingDateCtrl = TextEditingController(text: _working.recordingDate);
  }

  @override
  void dispose() {
    _amplCtrl.dispose();
    _distanceCtrl.dispose();
    _referenceCtrl.dispose();
    _tfMinCtrl.dispose();
    _tfMaxCtrl.dispose();
    _tfPowerMinCtrl.dispose();
    _tfPowerMaxCtrl.dispose();
    _spectMinCtrl.dispose();
    _spectMaxCtrl.dispose();
    _spectFreqMinCtrl.dispose();
    _spectFreqMaxCtrl.dispose();
    _periodFreqMinCtrl.dispose();
    _periodFreqMaxCtrl.dispose();
    _spectrogramFlexCtrl.dispose();
    _hypnogramFlexCtrl.dispose();
    _periodogramFlexCtrl.dispose();
    _refLineThicknessCtrl.dispose();
    _reportTitleCtrl.dispose();
    _studySiteCtrl.dispose();
    _investigatorCtrl.dispose();
    _subjectIdCtrl.dispose();
    _subjectDetailsCtrl.dispose();
    _recordingDateCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final labels = _working.channels.map((channel) => channel.name).toList();
    return DefaultTabController(
      length: 9,
      initialIndex: widget.initialTabIndex,
      child: AlertDialog(
        title: const Text('Configuration Window'),
        contentPadding: EdgeInsets.zero,
        content: SizedBox(
          width: 980,
          height: 600,
          child: Column(
            children: [
              const TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelColor: Colors.blue,
                unselectedLabelColor: Colors.black54,
                indicatorColor: Colors.blue,
                tabs: [
                  Tab(text: 'Configuration'),
                  Tab(text: 'Report'),
                  Tab(text: 'Channels'),
                  Tab(text: 'Events'),
                  Tab(text: 'Spectrogram'),
                  Tab(text: 'Periodogram'),
                  Tab(text: 'Wavelet'),
                  Tab(text: 'Filters'),
                  Tab(text: 'Features & Preprocessing'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    // Tab 1: General Settings
                    SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          _NumberRow(
                            label: 'Amplitude range (µV ±)',
                            controller: _amplCtrl,
                            onChanged: (v) => _working.amplitudeRangeUv =
                                v ?? _working.amplitudeRangeUv,
                          ),
                          _NumberRow(
                            label: 'Vertical distance between channels (µV)',
                            controller: _distanceCtrl,
                            onChanged: (v) =>
                                _working.distanceBetweenChannelsUv =
                                    v ?? _working.distanceBetweenChannelsUv,
                          ),
                          _NumberRow(
                            label: 'Reference amplitude line (µV)',
                            controller: _referenceCtrl,
                            onChanged: (v) =>
                                _working.referenceAmplitudeLineUv =
                                    v ?? _working.referenceAmplitudeLineUv,
                          ),
                          _StringDropdown(
                            label: 'EEG time unit in',
                            value: _working.eegPanelTimeUnit,
                            options: const [
                              'Seconds',
                              'Minutes',
                              'Hours',
                              'Clock time',
                            ],
                            onChanged: (v) =>
                                setState(() => _working.eegPanelTimeUnit = v),
                          ),
                          _NumberRow(
                            label: 'Spectrogram flex factor',
                            controller: _spectrogramFlexCtrl,
                            onChanged: (v) => _working.spectrogramFlex =
                                v?.toInt() ?? _working.spectrogramFlex,
                          ),
                          _NumberRow(
                            label: 'Hypnogram flex factor',
                            controller: _hypnogramFlexCtrl,
                            onChanged: (v) => _working.hypnogramFlex =
                                v?.toInt() ?? _working.hypnogramFlex,
                          ),
                          _NumberRow(
                            label: 'Periodogram flex factor',
                            controller: _periodogramFlexCtrl,
                            onChanged: (v) => _working.periodogramFlex =
                                v?.toInt() ?? _working.periodogramFlex,
                          ),
                          _NumberRow(
                            label: 'Reference line thickness',
                            controller: _refLineThicknessCtrl,
                            onChanged: (v) => _working.referenceLineThickness =
                                v ?? _working.referenceLineThickness,
                          ),
                          _StringDropdown(
                            label: 'Reference line color',
                            value: _working.referenceLineColor,
                            options: const [
                              'Light Grey',
                              'Dark Grey',
                              'Red',
                              'Blue',
                              'Green',
                              'Orange',
                            ],
                            onChanged: (v) =>
                                setState(() => _working.referenceLineColor = v),
                          ),
                          _StringDropdown(
                            label: 'Hypnogram overlay',
                            value: _working.hypnogramOverlayMode,
                            options: const [
                              'Off',
                              'SWA',
                              'Sleep-stage probability',
                              'NeuroLoopGain',
                            ],
                            onChanged: (v) => setState(() {
                              _working.hypnogramOverlayMode = v;
                              _working.showSwaPlot = v != 'Off';
                            }),
                          ),
                          if (_working.hypnogramOverlayMode ==
                              'Sleep-stage probability')
                            _StringDropdown(
                              label: 'Probability stage',
                              value: _working.hypnogramProbabilityStage,
                              options: const ['Wake', 'N1', 'N2', 'N3', 'REM'],
                              onChanged: (v) => setState(
                                () => _working.hypnogramProbabilityStage = v,
                              ),
                            ),
                          _StringDropdown(
                            label: 'Hypnogram zoom',
                            value: _working.hypnogramZoom,
                            options: const [
                              'Full Night',
                              '100 Epochs',
                              '200 Epochs',
                              '400 Epochs',
                            ],
                            onChanged: (v) =>
                                setState(() => _working.hypnogramZoom = v),
                          ),
                        ],
                      ),
                    ),
                    // Report identity and subject metadata
                    SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'PDF report header and subject information',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'These optional fields are saved with the configuration and appear on page 1 of exported reports.',
                            style: TextStyle(color: Colors.black54),
                          ),
                          const SizedBox(height: 20),
                          _ReportTextField(
                            label: 'Custom report title',
                            controller: _reportTitleCtrl,
                            onChanged: (value) =>
                                _working.reportTitle = value.trim(),
                          ),
                          _ReportTextField(
                            label: 'Place / institution of study',
                            controller: _studySiteCtrl,
                            onChanged: (value) =>
                                _working.studySite = value.trim(),
                          ),
                          _ReportTextField(
                            label: 'Investigator name',
                            controller: _investigatorCtrl,
                            onChanged: (value) =>
                                _working.investigatorName = value.trim(),
                          ),
                          _ReportTextField(
                            label: 'Subject identifier',
                            controller: _subjectIdCtrl,
                            onChanged: (value) =>
                                _working.subjectId = value.trim(),
                          ),
                          _ReportTextField(
                            label: 'Subject details',
                            controller: _subjectDetailsCtrl,
                            maxLines: 3,
                            onChanged: (value) =>
                                _working.subjectDetails = value.trim(),
                          ),
                          _ReportTextField(
                            label: 'Recording date',
                            controller: _recordingDateCtrl,
                            onChanged: (value) =>
                                _working.recordingDate = value.trim(),
                          ),
                        ],
                      ),
                    ),
                    // Tab 2: Per-channel display settings
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: CheckboxListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text(
                                    'Apply changes to all channels',
                                  ),
                                  value: _applyAllChannels,
                                  onChanged: (v) {
                                    setState(
                                      () => _applyAllChannels = v ?? false,
                                    );
                                  },
                                ),
                              ),
                              Expanded(
                                child: CheckboxListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('Stack channels'),
                                  value: _working.stackChannels,
                                  onChanged: (v) {
                                    setState(
                                      () => _working.stackChannels = v ?? false,
                                    );
                                    _preview();
                                  },
                                ),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: CheckboxListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text(
                                    'Select/deselect all channels',
                                  ),
                                  value: _working.channels.every(
                                    (c) => c.displayOnScreen,
                                  ),
                                  onChanged: (v) {
                                    setState(() {
                                      for (final channel in _working.channels) {
                                        channel.displayOnScreen = v ?? true;
                                      }
                                    });
                                    _preview();
                                  },
                                ),
                              ),
                              Expanded(
                                child: CheckboxListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text(
                                    'Robustly z-standardize channels',
                                  ),
                                  value: _working.robustZStandardize,
                                  onChanged: (v) {
                                    setState(
                                      () => _working.robustZStandardize =
                                          v ?? false,
                                    );
                                    _preview();
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const _ChannelHeaderRow(),
                          const SizedBox(height: 4),
                          Expanded(
                            child: ListView.builder(
                              itemCount: _working.channels.length,
                              itemBuilder: (context, i) {
                                return _ChannelConfigTile(
                                  key: ValueKey(_working.channels[i]),
                                  index: i,
                                  config: _working.channels[i],
                                  allChannels: _working.channels,
                                  applyAllChannels: _applyAllChannels,
                                  onApplyAll: (updater) {
                                    setState(() {
                                      for (final channel in _working.channels) {
                                        updater(channel);
                                      }
                                    });
                                    _preview();
                                  },
                                  onMoveUp: i == 0
                                      ? null
                                      : () {
                                          setState(() {
                                            final channel = _working.channels
                                                .removeAt(i);
                                            _working.channels.insert(
                                              i - 1,
                                              channel,
                                            );
                                          });
                                          _preview();
                                        },
                                  onMoveDown: i == _working.channels.length - 1
                                      ? null
                                      : () {
                                          setState(() {
                                            final channel = _working.channels
                                                .removeAt(i);
                                            _working.channels.insert(
                                              i + 1,
                                              channel,
                                            );
                                          });
                                          _preview();
                                        },
                                  onChanged: () {
                                    setState(() {});
                                    _preview();
                                  },
                                  onRemove: () {
                                    setState(() {
                                      final removed = _working.channels
                                          .removeAt(i);
                                      for (final channel in _working.channels) {
                                        if (channel.reReference ==
                                            removed.name) {
                                          channel.reReference = 'None';
                                        }
                                      }
                                    });
                                    _preview();
                                  },
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('Add re-referenced channel'),
                              onPressed: _showAddChannelDialog,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Tab 3: Events
                    const SingleChildScrollView(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Event labels and colors are available from the Events menu. Draw one or more boxes on the signal panel, then press A or F1-F12 to create events.',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                    // Tab 4: Spectrogram Settings
                    SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          _ChannelDropdown(
                            label: 'Channel',
                            channelLabels: labels,
                            value: _working.spectrogramChannelIndex.clamp(
                              0,
                              labels.length - 1,
                            ),
                            onChanged: (v) => setState(
                              () => _working.spectrogramChannelIndex = v,
                            ),
                          ),
                          _ChannelDropdown(
                            label: 'SWA channel',
                            channelLabels: labels,
                            value: _working.swaChannelIndex.clamp(
                              0,
                              labels.length - 1,
                            ),
                            onChanged: (v) =>
                                setState(() => _working.swaChannelIndex = v),
                          ),
                          _NumberRow(
                            label: 'Frequency min (Hz)',
                            controller: _spectFreqMinCtrl,
                            onChanged: (v) => _working.spectrogramFreqMin =
                                v ?? _working.spectrogramFreqMin,
                          ),
                          _NumberRow(
                            label: 'Frequency max (Hz)',
                            controller: _spectFreqMaxCtrl,
                            onChanged: (v) => _working.spectrogramFreqMax =
                                v ?? _working.spectrogramFreqMax,
                          ),
                          _NumberRow(
                            label: 'Power min (log₁₀)',
                            controller: _spectMinCtrl,
                            onChanged: (v) => _working.spectrogramPowerMin =
                                v ?? _working.spectrogramPowerMin,
                          ),
                          _NumberRow(
                            label: 'Power max (log₁₀)',
                            controller: _spectMaxCtrl,
                            onChanged: (v) => _working.spectrogramPowerMax =
                                v ?? _working.spectrogramPowerMax,
                          ),
                        ],
                      ),
                    ),
                    // Tab 5: Periodogram Settings
                    SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          _ChannelDropdown(
                            label: 'Channel',
                            channelLabels: labels,
                            value: _working.periodogramChannelIndex.clamp(
                              0,
                              labels.length - 1,
                            ),
                            onChanged: (v) => setState(
                              () => _working.periodogramChannelIndex = v,
                            ),
                          ),
                          _NumberRow(
                            label: 'Frequency min (Hz)',
                            controller: _periodFreqMinCtrl,
                            onChanged: (v) => _working.periodogramFreqMin =
                                v ?? _working.periodogramFreqMin,
                          ),
                          _NumberRow(
                            label: 'Frequency max (Hz)',
                            controller: _periodFreqMaxCtrl,
                            onChanged: (v) => _working.periodogramFreqMax =
                                v ?? _working.periodogramFreqMax,
                          ),
                          _StringDropdown(
                            label: 'Display mode',
                            value: _working.periodogramDisplayMode,
                            options: const ['Raw Power', 'dB', '1/f Removed'],
                            onChanged: (v) => setState(
                              () => _working.periodogramDisplayMode = v,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Tab 6: Wavelet (Time-Frequency) Settings
                    SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          _SwitchRow(
                            label: 'Enable Time-Frequency Panel',
                            value: _working.tfEnabled,
                            onChanged: (v) =>
                                setState(() => _working.tfEnabled = v),
                          ),
                          if (_working.tfEnabled) ...[
                            _ChannelDropdown(
                              label: 'Channel',
                              channelLabels: labels,
                              value: _working.tfChannelIndex.clamp(
                                0,
                                labels.length - 1,
                              ),
                              onChanged: (v) =>
                                  setState(() => _working.tfChannelIndex = v),
                            ),
                            _StringDropdown(
                              label: 'Frequency scale',
                              value: _working.tfFrequencyScale,
                              options: const ['Logarithmic', 'Linear'],
                              onChanged: (v) =>
                                  setState(() => _working.tfFrequencyScale = v),
                            ),
                            _NumberRow(
                              label: 'Freq min (Hz)',
                              controller: _tfMinCtrl,
                              onChanged: (v) =>
                                  _working.tfFreqMin = v ?? _working.tfFreqMin,
                            ),
                            _NumberRow(
                              label: 'Freq max (Hz)',
                              controller: _tfMaxCtrl,
                              onChanged: (v) =>
                                  _working.tfFreqMax = v ?? _working.tfFreqMax,
                            ),
                            _StringDropdown(
                              label: 'Display mode',
                              value: _working.tfDisplayMode,
                              options: const [
                                'Raw Power',
                                'L2-Normalized Power',
                                'dB (median baseline)',
                                'Z-Standardized Power',
                              ],
                              onChanged: (v) =>
                                  setState(() => _working.tfDisplayMode = v),
                            ),
                            _SwitchRow(
                              label: 'Autoscale once per recording',
                              value: _working.tfAutoScale,
                              onChanged: (v) =>
                                  setState(() => _working.tfAutoScale = v),
                            ),
                            _NumberRow(
                              label: 'Scale min',
                              controller: _tfPowerMinCtrl,
                              enabled: !_working.tfAutoScale,
                              onChanged: (v) => _working.tfPowerMin =
                                  v ?? _working.tfPowerMin,
                            ),
                            _NumberRow(
                              label: 'Scale max',
                              controller: _tfPowerMaxCtrl,
                              enabled: !_working.tfAutoScale,
                              onChanged: (v) => _working.tfPowerMax =
                                  v ?? _working.tfPowerMax,
                            ),
                            _CheckboxRow(
                              label: 'Show ridge',
                              value: _working.tfShowRidge,
                              onChanged: (v) => setState(
                                () => _working.tfShowRidge = v ?? false,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    // Tab 7: Filters Settings
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12.0,
                              vertical: 4.0,
                            ),
                            child: Container(
                              padding: const EdgeInsets.all(8.0),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade50,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: Colors.blue.shade100),
                              ),
                              child: const Row(
                                children: [
                                  Icon(
                                    Icons.info_outline,
                                    color: Colors.blue,
                                    size: 18,
                                  ),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'ℹ High-pass, low-pass, or notch-filter a given EEG channel using a Chebyshev Type 2 filter. '
                                      'Filters affect only the displayed EEG signal, not any power computations.',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.black87,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          CheckboxListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                            ),
                            title: const Text('Apply changes to all channels'),
                            value: _applyAllChannels,
                            onChanged: (v) {
                              setState(() {
                                _applyAllChannels = v ?? false;
                              });
                            },
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 12),
                            child: _FilterHeaderRow(),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: ListView.builder(
                                itemCount: _working.channels.length,
                                itemBuilder: (context, index) {
                                  return _FilterChannelRow(
                                    index: index,
                                    config: _working.channels[index],
                                    applyAllChannels: _applyAllChannels,
                                    onChanged: () => setState(() {}),
                                    onApplyAll: (updater) {
                                      setState(() {
                                        for (final channel
                                            in _working.channels) {
                                          updater(channel);
                                        }
                                      });
                                    },
                                  );
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Tab 9: Features & Preprocessing Settings
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: FeaturesAndPreprocessingWidget(config: _working),
                    ),
                  ],
                ),
              ),
            ],
          ),
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
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddChannelDialog() async {
    if (_working.channels.length < 2) return;
    var source = _working.channels.first.name;
    var reference = _working.channels[1].name;
    final added = await showDialog<ChannelConfig>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Add Re-referenced Channel'),
              content: SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Create a new channel as Channel A - Channel B',
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: source,
                      decoration: const InputDecoration(
                        labelText: 'Channel A',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final channel in _working.channels)
                          DropdownMenuItem(
                            value: channel.name,
                            child: Text(channel.name),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => source = value);
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: reference,
                      decoration: const InputDecoration(
                        labelText: 'Channel B',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final channel in _working.channels)
                          DropdownMenuItem(
                            value: channel.name,
                            child: Text(channel.name),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setDialogState(() => reference = value);
                        }
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: source == reference
                      ? null
                      : () {
                          final sourceCfg = _working.channels.firstWhere(
                            (channel) => channel.name == source,
                          );
                          Navigator.of(context).pop(
                            ChannelConfig(
                              name: '$source-$reference',
                              sourceIndex: sourceCfg.sourceIndex,
                              derived: true,
                              sourceChannel: source,
                              reReference: reference,
                              color: sourceCfg.color,
                            ),
                          );
                        },
                  child: const Text('Add Channel'),
                ),
              ],
            );
          },
        );
      },
    );
    if (added == null) return;
    setState(() {
      _working.channels.add(added);
    });
    _preview();
  }

  void _preview() {
    widget.onPreview?.call(_copyConfig(_working));
  }

  AppConfig _copyConfig(AppConfig cfg) {
    return AppConfig(
      spectrogramChannelIndex: cfg.spectrogramChannelIndex,
      swaChannelIndex: cfg.swaChannelIndex,
      periodogramChannelIndex: cfg.periodogramChannelIndex,
      tfChannelIndex: cfg.tfChannelIndex,
      amplitudeRangeUv: cfg.amplitudeRangeUv,
      tfFreqMin: cfg.tfFreqMin,
      tfFreqMax: cfg.tfFreqMax,
      spectrogramFreqMin: cfg.spectrogramFreqMin,
      spectrogramFreqMax: cfg.spectrogramFreqMax,
      periodogramFreqMin: cfg.periodogramFreqMin,
      periodogramFreqMax: cfg.periodogramFreqMax,
      spectrogramPowerMin: cfg.spectrogramPowerMin,
      spectrogramPowerMax: cfg.spectrogramPowerMax,
      tfEnabled: cfg.tfEnabled,
      tfDisplayMode: cfg.tfDisplayMode,
      tfFrequencyScale: cfg.tfFrequencyScale,
      tfShowRidge: cfg.tfShowRidge,
      tfAutoScale: cfg.tfAutoScale,
      tfPowerMin: cfg.tfPowerMin,
      tfPowerMax: cfg.tfPowerMax,
      stackChannels: cfg.stackChannels,
      robustZStandardize: cfg.robustZStandardize,
      periodogramDisplayMode: cfg.periodogramDisplayMode,
      eegPanelTimeUnit: cfg.eegPanelTimeUnit,
      distanceBetweenChannelsUv: cfg.distanceBetweenChannelsUv,
      referenceAmplitudeLineUv: cfg.referenceAmplitudeLineUv,
      spectrogramFlex: cfg.spectrogramFlex,
      hypnogramFlex: cfg.hypnogramFlex,
      periodogramFlex: cfg.periodogramFlex,
      showSwaPlot: cfg.showSwaPlot,
      hypnogramOverlayMode: cfg.hypnogramOverlayMode,
      hypnogramProbabilityStage: cfg.hypnogramProbabilityStage,
      lightsOffSeconds: cfg.lightsOffSeconds,
      lightsOnSeconds: cfg.lightsOnSeconds,
      referenceLineThickness: cfg.referenceLineThickness,
      referenceLineColor: cfg.referenceLineColor,
      hypnogramZoom: cfg.hypnogramZoom,
      reportTitle: cfg.reportTitle,
      studySite: cfg.studySite,
      investigatorName: cfg.investigatorName,
      subjectId: cfg.subjectId,
      subjectDetails: cfg.subjectDetails,
      recordingDate: cfg.recordingDate,
      channels: cfg.channels.map((c) => c.copy()).toList(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _ReportTextField extends StatelessWidget {
  const _ReportTextField({
    required this.label,
    required this.controller,
    required this.onChanged,
    this.maxLines = 1,
  });

  final String label;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        onChanged: onChanged,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          alignLabelWithHint: maxLines > 1,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _ChannelDropdown extends StatelessWidget {
  const _ChannelDropdown({
    required this.label,
    required this.channelLabels,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final List<String> channelLabels;
  final int value;
  final void Function(int) onChanged;

  @override
  Widget build(BuildContext context) {
    if (channelLabels.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 160,
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
          SizedBox(
            width: 180,
            child: DropdownButtonFormField<int>(
              initialValue: value,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
              ),
              items: [
                for (var i = 0; i < channelLabels.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(
                      '${i + 1}: ${channelLabels[i]}',
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _NumberRow extends StatelessWidget {
  const _NumberRow({
    required this.label,
    required this.controller,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final TextEditingController controller;
  final void Function(double?) onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 160,
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
          SizedBox(
            width: 180,
            child: TextFormField(
              controller: controller,
              enabled: enabled,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d*')),
              ],
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
              ),
              style: const TextStyle(fontSize: 12),
              onChanged: (v) => onChanged(double.tryParse(v)),
            ),
          ),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 160,
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
          SizedBox(
            width: 180,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Switch(value: value, onChanged: onChanged),
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckboxRow extends StatelessWidget {
  const _CheckboxRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final String label;
  final bool value;
  final ValueChanged<bool?> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 160,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: enabled ? null : Colors.grey,
              ),
            ),
          ),
          SizedBox(
            width: 180,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Checkbox(
                visualDensity: VisualDensity.compact,
                value: value,
                onChanged: enabled ? onChanged : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelHeaderRow extends StatelessWidget {
  const _ChannelHeaderRow();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 12, fontWeight: FontWeight.w700);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFDDDDDD))),
      ),
      child: const Row(
        children: [
          SizedBox(width: 36, child: Text('#', style: style)),
          SizedBox(width: 48),
          Expanded(flex: 2, child: Text('Channel', style: style)),
          SizedBox(width: 72, child: Text('Scale', style: style)),
          SizedBox(width: 72, child: Text('Shift', style: style)),
          SizedBox(width: 110, child: Text('Color', style: style)),
          Expanded(child: Text('Re-reference', style: style)),
          SizedBox(width: 64, child: Text('Flip', style: style)),
          SizedBox(width: 42),
        ],
      ),
    );
  }
}

class _ChannelConfigTile extends StatelessWidget {
  const _ChannelConfigTile({
    super.key,
    required this.index,
    required this.config,
    required this.allChannels,
    required this.applyAllChannels,
    required this.onApplyAll,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final ChannelConfig config;
  final List<ChannelConfig> allChannels;
  final bool applyAllChannels;
  final void Function(void Function(ChannelConfig channel)) onApplyAll;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
        color: Colors.white,
      ),
      child: Row(
        children: [
          // Column 1: # Index & Move arrows
          SizedBox(
            width: 36,
            child: Row(
              children: [
                Text(
                  '${index + 1}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.black54,
                  ),
                ),
              ],
            ),
          ),
          // Column 2: Drag & Checkbox
          SizedBox(
            width: 48,
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InkWell(
                        onTap: onMoveUp,
                        child: Icon(
                          Icons.keyboard_arrow_up,
                          size: 12,
                          color: onMoveUp == null
                              ? Colors.black12
                              : Colors.black45,
                        ),
                      ),
                      InkWell(
                        onTap: onMoveDown,
                        child: Icon(
                          Icons.keyboard_arrow_down,
                          size: 12,
                          color: onMoveDown == null
                              ? Colors.black12
                              : Colors.black45,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 2),
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Checkbox(
                    value: config.displayOnScreen,
                    onChanged: (v) {
                      config.displayOnScreen = v ?? true;
                      onChanged();
                    },
                  ),
                ),
              ],
            ),
          ),
          // Column 3: Channel label (textfield)
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: SizedBox(
                height: 28,
                child: TextFormField(
                  initialValue: config.name,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 6,
                    ),
                  ),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  onChanged: (v) {
                    config.name = v;
                    onChanged();
                  },
                ),
              ),
            ),
          ),
          // Column 4: Scale
          SizedBox(
            width: 72,
            child: Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: SizedBox(
                height: 28,
                child: _CompactNumberField(
                  value: config.scalingFactor,
                  suffix: '%',
                  onChanged: (value) {
                    if (applyAllChannels) {
                      onApplyAll((channel) => channel.scalingFactor = value);
                    } else {
                      config.scalingFactor = value;
                      onChanged();
                    }
                  },
                ),
              ),
            ),
          ),
          // Column 5: Shift
          SizedBox(
            width: 72,
            child: Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: SizedBox(
                height: 28,
                child: _CompactNumberField(
                  value: config.verticalShift,
                  onChanged: (value) {
                    if (applyAllChannels) {
                      onApplyAll((channel) => channel.verticalShift = value);
                    } else {
                      config.verticalShift = value;
                      onChanged();
                    }
                  },
                ),
              ),
            ),
          ),
          // Column 6: Color
          SizedBox(
            width: 110,
            child: Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: SizedBox(
                height: 28,
                child: DropdownButtonFormField<String>(
                  value: _validColor(config.color),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 6,
                    ),
                  ),
                  style: const TextStyle(fontSize: 12, color: Colors.black87),
                  items: const [
                    DropdownMenuItem(
                      value: 'Black',
                      child: Text('Black', style: TextStyle(fontSize: 12)),
                    ),
                    DropdownMenuItem(
                      value: 'Blue',
                      child: Text('Blue', style: TextStyle(fontSize: 12)),
                    ),
                    DropdownMenuItem(
                      value: 'Green',
                      child: Text('Green', style: TextStyle(fontSize: 12)),
                    ),
                    DropdownMenuItem(
                      value: 'Magenta',
                      child: Text('Magenta', style: TextStyle(fontSize: 12)),
                    ),
                    DropdownMenuItem(
                      value: 'Orange',
                      child: Text('Orange', style: TextStyle(fontSize: 12)),
                    ),
                    DropdownMenuItem(
                      value: 'Cyan',
                      child: Text('Cyan', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    if (applyAllChannels) {
                      onApplyAll((channel) => channel.color = v);
                    } else {
                      config.color = v;
                      onChanged();
                    }
                  },
                ),
              ),
            ),
          ),
          // Column 7: Re-reference
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: SizedBox(
                height: 28,
                child: DropdownButtonFormField<String>(
                  value: _validReference(config.reReference),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 6,
                    ),
                  ),
                  style: const TextStyle(fontSize: 12, color: Colors.black87),
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(
                      value: 'None',
                      child: Text('None', style: TextStyle(fontSize: 12)),
                    ),
                    for (final channel in allChannels)
                      if (!identical(channel, config))
                        DropdownMenuItem(
                          value: channel.name,
                          child: Text(
                            channel.name,
                            style: const TextStyle(fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    config.reReference = v;
                    onChanged();
                  },
                ),
              ),
            ),
          ),
          // Column 8: Flip
          SizedBox(
            width: 64,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Checkbox(
                    value: config.flipPolarity,
                    onChanged: (v) {
                      config.flipPolarity = v ?? false;
                      onChanged();
                    },
                  ),
                ),
              ],
            ),
          ),
          // Column 9: Delete
          SizedBox(
            width: 42,
            child: InkWell(
              onTap: onRemove,
              child: const Icon(
                Icons.delete_outline,
                size: 16,
                color: Colors.redAccent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _validColor(String color) {
    const colors = {'Black', 'Blue', 'Green', 'Magenta', 'Orange', 'Cyan'};
    return colors.contains(color) ? color : 'Black';
  }

  String _validReference(String? ref) {
    if (ref == null || ref == 'None') return 'None';
    if (allChannels.any((c) => c.name == ref && !identical(c, config))) {
      return ref;
    }
    return 'None';
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.config,
    required this.applyAllChannels,
    required this.onApplyAll,
    required this.onChanged,
  });

  final ChannelConfig config;
  final bool applyAllChannels;
  final void Function(void Function(ChannelConfig channel)) onApplyAll;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(
          width: 86,
          child: Text('Filters', style: TextStyle(fontSize: 12)),
        ),
        Expanded(
          child: _CompactFilterGroup(
            label: 'HP',
            enabled: config.filterHpEnabled,
            cutoff: config.filterHpCutoff,
            order: config.filterHpOrder,
            onEnabled: (value) =>
                _update((channel) => channel.filterHpEnabled = value),
            onCutoff: (value) =>
                _update((channel) => channel.filterHpCutoff = value),
            onOrder: (value) =>
                _update((channel) => channel.filterHpOrder = value),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _CompactFilterGroup(
            label: 'LP',
            enabled: config.filterLpEnabled,
            cutoff: config.filterLpCutoff,
            order: config.filterLpOrder,
            onEnabled: (value) =>
                _update((channel) => channel.filterLpEnabled = value),
            onCutoff: (value) =>
                _update((channel) => channel.filterLpCutoff = value),
            onOrder: (value) =>
                _update((channel) => channel.filterLpOrder = value),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _CompactFilterGroup(
            label: 'Notch',
            enabled: config.filterNotchEnabled,
            cutoff: config.filterNotchCutoff,
            order: config.filterNotchOrder,
            onEnabled: (value) =>
                _update((channel) => channel.filterNotchEnabled = value),
            onCutoff: (value) =>
                _update((channel) => channel.filterNotchCutoff = value),
            onOrder: (value) =>
                _update((channel) => channel.filterNotchOrder = value),
          ),
        ),
      ],
    );
  }

  void _update(void Function(ChannelConfig channel) updater) {
    if (applyAllChannels) {
      onApplyAll(updater);
    } else {
      updater(config);
      onChanged();
    }
  }
}

class _CompactFilterGroup extends StatelessWidget {
  const _CompactFilterGroup({
    required this.label,
    required this.enabled,
    required this.cutoff,
    required this.order,
    required this.onEnabled,
    required this.onCutoff,
    required this.onOrder,
  });

  final String label;
  final bool enabled;
  final double cutoff;
  final int order;
  final void Function(bool value) onEnabled;
  final void Function(double value) onCutoff;
  final void Function(int value) onOrder;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Checkbox(
          visualDensity: VisualDensity.compact,
          value: enabled,
          onChanged: (value) => onEnabled(value ?? false),
        ),
        SizedBox(width: 46, child: Text(label)),
        Expanded(
          child: _CompactNumberField(
            value: cutoff,
            decimals: 2,
            suffix: 'Hz',
            onChanged: onCutoff,
          ),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 52,
          child: _CompactNumberField(
            value: order.toDouble(),
            decimals: 0,
            onChanged: (value) => onOrder(value.round().clamp(1, 10)),
          ),
        ),
      ],
    );
  }
}

class _StringDropdown extends StatelessWidget {
  const _StringDropdown({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<String> options;
  final void Function(String value) onChanged;

  @override
  Widget build(BuildContext context) {
    final currentValue = options.contains(value) ? value : options.first;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 160,
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
          SizedBox(
            width: 180,
            child: DropdownButtonFormField<String>(
              initialValue: currentValue,
              isExpanded: true,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
              ),
              items: [
                for (final option in options)
                  DropdownMenuItem(value: option, child: Text(option)),
              ],
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineNumberField extends StatefulWidget {
  const _InlineNumberField({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double value;
  final void Function(double?) onChanged;

  @override
  State<_InlineNumberField> createState() => _InlineNumberFieldState();
}

class _InlineNumberFieldState extends State<_InlineNumberField> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toStringAsFixed(1));
  }

  @override
  void didUpdateWidget(covariant _InlineNumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_focusNode.hasFocus) {
      _controller.text = widget.value.toStringAsFixed(1);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: _controller,
      focusNode: _focusNode,
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d*')),
      ],
      decoration: InputDecoration(
        labelText: widget.label,
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
      style: const TextStyle(fontSize: 12),
      onChanged: (v) => widget.onChanged(double.tryParse(v)),
    );
  }
}

class _CompactNumberField extends StatefulWidget {
  const _CompactNumberField({
    required this.value,
    required this.onChanged,
    this.decimals = 1,
    this.suffix = '',
  });

  final double value;
  final int decimals;
  final String suffix;
  final void Function(double value) onChanged;

  @override
  State<_CompactNumberField> createState() => _CompactNumberFieldState();
}

class _CompactNumberFieldState extends State<_CompactNumberField> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _formatValue(widget.value));
  }

  String _formatValue(double val) {
    final formattedVal = val % 1 == 0
        ? val.toInt().toString()
        : val.toStringAsFixed(widget.decimals);
    return '$formattedVal${widget.suffix}';
  }

  @override
  void didUpdateWidget(covariant _CompactNumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.value != widget.value ||
            oldWidget.decimals != widget.decimals ||
            oldWidget.suffix != widget.suffix) &&
        !_focusNode.hasFocus) {
      _controller.text = _formatValue(widget.value);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: _controller,
      focusNode: _focusNode,
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d*[a-zA-Z%\s]*')),
      ],
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      ),
      style: const TextStyle(fontSize: 12),
      onChanged: (value) {
        String clean = value;
        if (widget.suffix.isNotEmpty) {
          if (clean.endsWith(widget.suffix)) {
            clean = clean.substring(0, clean.length - widget.suffix.length);
          }
          clean = clean.replaceAll(widget.suffix, '');
        }
        clean = clean.replaceAll('%', '').replaceAll('Hz', '').trim();
        final parsed = double.tryParse(clean);
        if (parsed != null) {
          widget.onChanged(parsed);
        }
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Dedicated Filter Settings Dialog
// ─────────────────────────────────────────────────────────────────────────────

class FilterDialog extends StatefulWidget {
  const FilterDialog({
    super.key,
    required this.config,
    required this.channelLabels,
    required this.onApply,
  });

  final AppConfig config;
  final List<String> channelLabels;
  final void Function(AppConfig) onApply;

  @override
  State<FilterDialog> createState() => _FilterDialogState();
}

class _FilterDialogState extends State<FilterDialog> {
  late AppConfig _working;
  bool _applyAllChannels = false;

  @override
  void initState() {
    super.initState();
    _working = AppConfig(
      spectrogramChannelIndex: widget.config.spectrogramChannelIndex,
      swaChannelIndex: widget.config.swaChannelIndex,
      periodogramChannelIndex: widget.config.periodogramChannelIndex,
      tfChannelIndex: widget.config.tfChannelIndex,
      amplitudeRangeUv: widget.config.amplitudeRangeUv,
      tfFreqMin: widget.config.tfFreqMin,
      tfFreqMax: widget.config.tfFreqMax,
      spectrogramFreqMin: widget.config.spectrogramFreqMin,
      spectrogramFreqMax: widget.config.spectrogramFreqMax,
      periodogramFreqMin: widget.config.periodogramFreqMin,
      periodogramFreqMax: widget.config.periodogramFreqMax,
      spectrogramPowerMin: widget.config.spectrogramPowerMin,
      spectrogramPowerMax: widget.config.spectrogramPowerMax,
      tfEnabled: widget.config.tfEnabled,
      tfDisplayMode: widget.config.tfDisplayMode,
      tfFrequencyScale: widget.config.tfFrequencyScale,
      tfShowRidge: widget.config.tfShowRidge,
      tfAutoScale: widget.config.tfAutoScale,
      tfPowerMin: widget.config.tfPowerMin,
      tfPowerMax: widget.config.tfPowerMax,
      stackChannels: widget.config.stackChannels,
      robustZStandardize: widget.config.robustZStandardize,
      periodogramDisplayMode: widget.config.periodogramDisplayMode,
      eegPanelTimeUnit: widget.config.eegPanelTimeUnit,
      distanceBetweenChannelsUv: widget.config.distanceBetweenChannelsUv,
      referenceAmplitudeLineUv: widget.config.referenceAmplitudeLineUv,
      spectrogramFlex: widget.config.spectrogramFlex,
      hypnogramFlex: widget.config.hypnogramFlex,
      periodogramFlex: widget.config.periodogramFlex,
      showSwaPlot: widget.config.showSwaPlot,
      hypnogramOverlayMode: widget.config.hypnogramOverlayMode,
      hypnogramProbabilityStage: widget.config.hypnogramProbabilityStage,
      lightsOffSeconds: widget.config.lightsOffSeconds,
      lightsOnSeconds: widget.config.lightsOnSeconds,
      referenceLineThickness: widget.config.referenceLineThickness,
      referenceLineColor: widget.config.referenceLineColor,
      hypnogramZoom: widget.config.hypnogramZoom,
      reportTitle: widget.config.reportTitle,
      studySite: widget.config.studySite,
      investigatorName: widget.config.investigatorName,
      subjectId: widget.config.subjectId,
      subjectDetails: widget.config.subjectDetails,
      recordingDate: widget.config.recordingDate,
      channels: widget.config.channels.map((c) => c.copy()).toList(),
    );
  }

  void _propagate(void Function(ChannelConfig) updater) {
    setState(() {
      for (final channel in _working.channels) {
        updater(channel);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Filter Settings'),
      contentPadding: EdgeInsets.zero,
      content: SizedBox(
        width: 960,
        height: 520,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: Container(
                padding: const EdgeInsets.all(8.0),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.blue.shade100),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.blue, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'ℹ High-pass, low-pass, or notch-filter a given EEG channel using a Chebyshev Type 2 filter. '
                        'Filters affect only the displayed EEG signal, not any power computations.',
                        style: TextStyle(fontSize: 12, color: Colors.black87),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              title: const Text('Apply changes to all channels'),
              value: _applyAllChannels,
              onChanged: (v) {
                setState(() {
                  _applyAllChannels = v ?? false;
                });
              },
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: _FilterHeaderRow(),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: ListView.builder(
                  itemCount: _working.channels.length,
                  itemBuilder: (context, index) {
                    return _FilterChannelRow(
                      index: index,
                      config: _working.channels[index],
                      applyAllChannels: _applyAllChannels,
                      onChanged: () => setState(() {}),
                      onApplyAll: _propagate,
                    );
                  },
                ),
              ),
            ),
          ],
        ),
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
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

class _FilterHeaderRow extends StatelessWidget {
  const _FilterHeaderRow();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey.shade200,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      child: const Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              'Channel',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              'High-pass Filter',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
          SizedBox(width: 16),
          Expanded(
            flex: 3,
            child: Text(
              'Low-pass Filter',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
          SizedBox(width: 16),
          Expanded(
            flex: 3,
            child: Text(
              'Notch Filter',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
          SizedBox(width: 16),
          SizedBox(
            width: 50,
            child: Text(
              'All',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterChannelRow extends StatelessWidget {
  const _FilterChannelRow({
    required this.index,
    required this.config,
    required this.applyAllChannels,
    required this.onChanged,
    required this.onApplyAll,
  });

  final int index;
  final ChannelConfig config;
  final bool applyAllChannels;
  final VoidCallback onChanged;
  final void Function(void Function(ChannelConfig)) onApplyAll;

  void _update(void Function(ChannelConfig) updater) {
    if (applyAllChannels) {
      onApplyAll(updater);
    } else {
      updater(config);
      onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final allChecked =
        config.filterHpEnabled &&
        config.filterLpEnabled &&
        config.filterNotchEnabled;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              '${index + 1}  ${config.name}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
          // HP Filter Group
          Expanded(
            flex: 3,
            child: Row(
              children: [
                Expanded(
                  child: _CompactNumberField(
                    value: config.filterHpCutoff,
                    suffix: ' Hz',
                    onChanged: (v) => _update((c) => c.filterHpCutoff = v),
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  width: 32,
                  child: _CompactNumberField(
                    value: config.filterHpOrder.toDouble(),
                    decimals: 0,
                    onChanged: (v) => _update(
                      (c) => c.filterHpOrder = v.round().clamp(1, 10),
                    ),
                  ),
                ),
                Checkbox(
                  value: config.filterHpEnabled,
                  onChanged: (v) =>
                      _update((c) => c.filterHpEnabled = v ?? false),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          // LP Filter Group
          Expanded(
            flex: 3,
            child: Row(
              children: [
                Expanded(
                  child: _CompactNumberField(
                    value: config.filterLpCutoff,
                    suffix: ' Hz',
                    onChanged: (v) => _update((c) => c.filterLpCutoff = v),
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  width: 32,
                  child: _CompactNumberField(
                    value: config.filterLpOrder.toDouble(),
                    decimals: 0,
                    onChanged: (v) => _update(
                      (c) => c.filterLpOrder = v.round().clamp(1, 10),
                    ),
                  ),
                ),
                Checkbox(
                  value: config.filterLpEnabled,
                  onChanged: (v) =>
                      _update((c) => c.filterLpEnabled = v ?? false),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          // Notch Filter Group
          Expanded(
            flex: 3,
            child: Row(
              children: [
                Expanded(
                  child: _CompactNumberField(
                    value: config.filterNotchCutoff,
                    suffix: ' Hz',
                    onChanged: (v) => _update((c) => c.filterNotchCutoff = v),
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  width: 32,
                  child: _CompactNumberField(
                    value: config.filterNotchOrder.toDouble(),
                    decimals: 0,
                    onChanged: (v) => _update(
                      (c) => c.filterNotchOrder = v.round().clamp(1, 10),
                    ),
                  ),
                ),
                Checkbox(
                  value: config.filterNotchEnabled,
                  onChanged: (v) =>
                      _update((c) => c.filterNotchEnabled = v ?? false),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          // All check row-level toggle
          SizedBox(
            width: 50,
            child: Checkbox(
              value: allChecked,
              tristate: true,
              onChanged: (v) {
                final checked = v ?? false;
                _update((c) {
                  c.filterHpEnabled = checked;
                  c.filterLpEnabled = checked;
                  c.filterNotchEnabled = checked;
                });
              },
            ),
          ),
        ],
      ),
    );
  }
}
