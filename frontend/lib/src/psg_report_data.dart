// Pure-Dart helpers for the respiratory (OSA), PLM and CAP reports written by
// `analyse-nidra --respiratory` / `--plm` / `--cap`: event digits, sidecar paths,
// marker conversion and the summary tables shared by the app and the PDF.

import 'dart:convert';
import 'dart:io';

import 'models.dart';

// ─── Event digits used for respiratory / limb-movement markers ──────────────
const int kDigitObstructiveApnea = 13;
const int kDigitCentralApnea = 14;
const int kDigitMixedApnea = 15;
const int kDigitHypopnea = 16;
const int kDigitRera = 17;
const int kDigitDesaturation = 18;
const int kDigitLegMovement = 19;
const int kDigitPlm = 20;
const int kDigitCapA1 = 21;
const int kDigitCapA2 = 22;
const int kDigitCapA3 = 23;
const int kDigitCapSequence = 24;

bool isRespiratoryEventDigit(int digit) =>
    digit >= kDigitObstructiveApnea && digit <= kDigitDesaturation;
bool isLimbMovementDigit(int digit) =>
    digit == kDigitLegMovement || digit == kDigitPlm;
bool isCapAPhaseDigit(int digit) =>
    digit >= kDigitCapA1 && digit <= kDigitCapA3;
bool isCapSequenceDigit(int digit) => digit == kDigitCapSequence;
bool isCapDigit(int digit) => isCapAPhaseDigit(digit) || isCapSequenceDigit(digit);

/// Default marker names for the PSG digits (used when no custom name is set).
const Map<int, String> kPsgEventNames = {
  kDigitObstructiveApnea: 'Obstructive Apnea',
  kDigitCentralApnea: 'Central Apnea',
  kDigitMixedApnea: 'Mixed Apnea',
  kDigitHypopnea: 'Hypopnea',
  kDigitRera: 'RERA',
  kDigitDesaturation: 'Desaturation',
  kDigitLegMovement: 'Leg Movement',
  kDigitPlm: 'PLM',
  kDigitCapA1: 'CAP A1',
  kDigitCapA2: 'CAP A2',
  kDigitCapA3: 'CAP A3',
  kDigitCapSequence: 'CAP Sequence',
};

String psgSidecarBase(String recordingPath) {
  final dot = recordingPath.lastIndexOf('.');
  final sep = recordingPath.lastIndexOf(RegExp(r'[\\/]'));
  return dot > sep ? recordingPath.substring(0, dot) : recordingPath;
}

String respiratoryReportPath(String recordingPath) =>
    '${psgSidecarBase(recordingPath)}_respiratory.json';

String plmReportPath(String recordingPath) =>
    '${psgSidecarBase(recordingPath)}_plm.json';

String capReportPath(String recordingPath) =>
    '${psgSidecarBase(recordingPath)}_cap.json';

Future<Map<String, dynamic>?> loadPsgReport(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

// ─── Converting reports to markers ──────────────────────────────────────────

double _num(dynamic v, [double fallback = double.nan]) =>
    v is num ? v.toDouble() : fallback;

List<ScoredEvent> respiratoryEventsFromReport(
  Map<String, dynamic> report, {
  bool includeDesaturations = true,
}) {
  final out = <ScoredEvent>[];
  for (final e in (report['events'] as List? ?? const [])) {
    if (e is! Map || e['counted'] != true) continue;
    final kind = e['kind']?.toString() ?? '';
    final lower = kind.toLowerCase();
    final digit = lower.contains('central apnea')
        ? kDigitCentralApnea
        : lower.contains('mixed')
        ? kDigitMixedApnea
        : lower.contains('apnea')
        ? kDigitObstructiveApnea
        : lower.contains('rera')
        ? kDigitRera
        : kDigitHypopnea;
    // Short, stable labels: the Markers panel groups and toggles by label.
    out.add(
      ScoredEvent(
        digit: digit,
        key: 'F$digit',
        label: kind.isEmpty ? kPsgEventNames[digit]! : kind,
        type: 'Respiratory',
        startSec: _num(e['start'], 0),
        endSec: _num(e['end'], 0),
      ),
    );
  }
  if (includeDesaturations) {
    for (final d in (report['desaturations'] as List? ?? const [])) {
      if (d is! Map || d['in_sleep'] == false) continue;
      final drop = _num(d['drop']);
      if (!drop.isFinite || drop < 3) continue;
      out.add(
        ScoredEvent(
          digit: kDigitDesaturation,
          key: 'F$kDigitDesaturation',
          label: 'Desaturation',
          type: 'Respiratory',
          startSec: _num(d['start'], 0),
          endSec: _num(d['end'], 0),
        ),
      );
    }
  }
  return out;
}

List<ScoredEvent> plmEventsFromReport(Map<String, dynamic> report) {
  final out = <ScoredEvent>[];
  for (final m in (report['movements'] as List? ?? const [])) {
    if (m is! Map || m['clm'] != true) continue;
    final periodic = m['periodic'] == true;
    final digit = periodic ? kDigitPlm : kDigitLegMovement;
    out.add(
      ScoredEvent(
        digit: digit,
        key: 'F$digit',
        label: periodic ? 'PLM' : 'Leg Movement',
        type: 'Limb Movement',
        startSec: _num(m['start'], 0),
        endSec: _num(m['end'], 0),
      ),
    );
  }
  return out;
}

// ─── Summary tables ─────────────────────────────────────────────────────────

String _fmt(dynamic v, {int digits = 1, String suffix = ''}) {
  if (v is! num || !v.isFinite) return '—';
  return '${v.toStringAsFixed(digits)}$suffix';
}

/// (section, [(metric, value)]) rows shared by the summary dialog and the PDF.
List<(String, List<(String, String)>)> respiratorySummarySections(
  Map<String, dynamic> report,
) {
  final s = (report['summary'] as Map?) ?? const {};
  final f = (report['flags'] as Map?) ?? const {};
  String v(String k, {int d = 1, String u = ''}) => _fmt(s[k], digits: d, suffix: u);
  return [
    (
      'Indices (events/h of sleep)',
      [
        ('AHI (${f['hypopnea_rule'] ?? 'AASM'})', v('AHI')),
        ('Severity', f['severity']?.toString() ?? '—'),
        ('AHI 3% / arousal (1A)', v('AHI_3a')),
        ('AHI 4% (1B, CMS)', v('AHI_4')),
        ('Apnea index', v('AI')),
        ('Obstructive / central / mixed apnea index',
            '${v('OAI')} / ${v('CAI')} / ${v('MAI')}'),
        ('Hypopnea index', v('HI')),
        ('RERA index / RDI', '${v('RERA_index')} / ${v('RDI')}'),
        ('AHI REM / NREM', '${v('AHI_REM')} / ${v('AHI_NREM')}'),
        ('AHI supine / non-supine', '${v('AHI_supine')} / ${v('AHI_nonsupine')}'),
        ('Central event index', v('central_index')),
      ],
    ),
    (
      'Oximetry',
      [
        ('ODI 3% / 4%', '${v('ODI3')} / ${v('ODI4')}'),
        ('SpO₂ baseline / mean / min', '${v('SpO2_baseline', d: 0, u: '%')} / ${v('SpO2_mean_sleep', u: '%')} / ${v('SpO2_min_sleep', d: 0, u: '%')}'),
        ('T90 (time <90%)', '${v('T90_min')} min (${v('T90_pct')}% TST)'),
        ('T88 / T85', '${v('T88_min')} / ${v('T85_min')} min'),
        ('Hypoxic burden', '${v('hypoxic_burden_pct_min_per_h')} %·min/h'),
        ('Mean desaturation depth / duration', '${v('desat_depth_mean')}% / ${v('desat_duration_mean_s', d: 0)} s'),
      ],
    ),
    (
      'Novel & physiological markers',
      [
        ('Pulse-rate response (ΔHR)', '${v('delta_HR_bpm')} bpm'),
        ('Ventilatory burden', v('ventilatory_burden_pct_min_per_h', u: ' %·min/h')),
        ('Mean / max apnea duration', '${v('apnea_duration_mean_s')} / ${v('apnea_duration_max_s')} s'),
        ('Mean / max hypopnea duration', '${v('hypopnea_duration_mean_s')} / ${v('hypopnea_duration_max_s')} s'),
        ('Cheyne–Stokes breathing', '${f['Cheyne_Stokes_breathing'] ?? '—'} (${v('CSB_minutes')} min)'),
        ('REM-related OSA', f['REM_related_OSA']?.toString() ?? '—'),
        ('Positional OSA', f['positional_OSA']?.toString() ?? '—'),
        ('Arousal index (${f['arousal_source'] ?? '—'})', v('arousal_index')),
      ],
    ),
    (
      'Sleep',
      [
        ('TST / TRT', '${v('TST_min')} / ${v('TRT_min')} min'),
        ('REM / NREM time', '${v('REM_min')} / ${v('NREM_min')} min'),
      ],
    ),
  ];
}

List<(String, List<(String, String)>)> plmSummarySections(
  Map<String, dynamic> report,
) {
  final s = (report['summary'] as Map?) ?? const {};
  final f = (report['flags'] as Map?) ?? const {};
  final settings = (report['settings'] as Map?) ?? const {};
  String v(String k, {int d = 1, String u = ''}) => _fmt(s[k], digits: d, suffix: u);
  return [
    (
      'Indices (per hour)',
      [
        ('Standard', settings['standard']?.toString() ?? '—'),
        ('PLMS index', v('PLMS_index')),
        ('Severity', f['PLMS_severity']?.toString() ?? '—'),
        ('PLMW index (per hour of wake)', v('PLMW_index')),
        ('PLMS-arousal index', v('PLMS_arousal_index')),
        ('LM index (sleep)', v('LM_index')),
        ('PLMS index NREM / REM', '${v('PLMS_index_NREM')} / ${v('PLMS_index_REM')}'),
        ('Respiratory-related LM index', v('respiratory_LM_index')),
      ],
    ),
    (
      'Counts',
      [
        ('PLMS / PLMW / all PLMs', '${v('n_PLMS', d: 0)} / ${v('n_PLMW', d: 0)} / ${v('n_PLM_total', d: 0)}'),
        ('Leg movements (sleep / total)', '${v('n_LM_sleep', d: 0)} / ${v('n_LM_total', d: 0)}'),
        ('PLM series in sleep', v('n_PLM_series_sleep', d: 0)),
      ],
    ),
    (
      'Novel & periodicity markers',
      [
        ('Periodicity index (Ferri)', v('periodicity_index', d: 2)),
        ('Median IMI', v('IMI_median_s', u: ' s')),
        ('Mean PLM series length', v('PLM_series_length_mean')),
        ('Mean LM / PLM duration', '${v('LM_duration_mean_s')} / ${v('PLM_duration_mean_s')} s'),
        ('Bilateral LMs', v('bilateral_CLM_pct', u: '%')),
        ('Isolated LM index', v('isolated_LM_index')),
        ('% of PLMS in REM', v('PLMS_pct_in_REM', u: '%')),
        ('Resting EMG L / R', '${v('resting_EMG_left_uV')} / ${v('resting_EMG_right_uV')} µV'),
      ],
    ),
  ];
}


// ─── Plain-language interpretation (used by the PDF report) ─────────────────

double? _val(Map<String, dynamic> report, String key) {
  final v = (report['summary'] as Map?)?[key];
  return v is num && v.isFinite ? v.toDouble() : null;
}

String respiratoryInterpretation(Map<String, dynamic> report) {
  final flags = (report['flags'] as Map?) ?? const {};
  final ahi = _val(report, 'AHI');
  final parts = <String>[];
  if (ahi != null) {
    final severity = flags['severity']?.toString() ?? '';
    parts.add(
      'The apnea-hypopnea index was ${ahi.toStringAsFixed(1)} events per hour of sleep'
      '${severity.isEmpty ? '' : ' ($severity)'}.',
    );
  }
  final oai = _val(report, 'OAI') ?? 0;
  final cai = _val(report, 'CAI') ?? 0;
  final central = _val(report, 'central_index') ?? cai;
  final obstructive = _val(report, 'obstructive_index') ?? oai;
  if (ahi != null && ahi >= 5) {
    parts.add(
      central > 0.5 * ahi
          ? 'Most events were central, which warrants review for central sleep apnea or periodic breathing.'
          : obstructive >= central
          ? 'Events were predominantly obstructive.'
          : 'Events showed a mixed obstructive and central pattern.',
    );
  }
  final t90 = _val(report, 'T90_pct');
  final nadir = _val(report, 'SpO2_min_sleep');
  if (t90 != null && nadir != null) {
    parts.add(
      'Oxygen saturation was below 90% for ${t90.toStringAsFixed(1)}% of sleep, with a nadir of ${nadir.toStringAsFixed(0)}%.',
    );
  }
  final hb = _val(report, 'hypoxic_burden_pct_min_per_h');
  if (hb != null) {
    parts.add(
      'The sleep-apnea-specific hypoxic burden was ${hb.toStringAsFixed(0)} %min/h; higher values have been linked to cardiovascular risk in cohort studies independent of the AHI.',
    );
  }
  if (flags['REM_related_OSA'] == 'yes') {
    parts.add('Events clustered in REM sleep (REM-related OSA pattern).');
  }
  if (flags['positional_OSA'] == 'yes') {
    parts.add('The supine AHI was at least twice the non-supine AHI (positional OSA).');
  }
  final csb = flags['Cheyne_Stokes_breathing']?.toString();
  if (csb != null && csb != 'absent') {
    parts.add('A Cheyne-Stokes breathing pattern was detected ($csb).');
  }
  if (parts.isEmpty) {
    parts.add('No respiratory summary metrics were available.');
  }
  return parts.join(' ');
}

String plmInterpretation(Map<String, dynamic> report) {
  final flags = (report['flags'] as Map?) ?? const {};
  final plmsi = _val(report, 'PLMS_index');
  final parts = <String>[];
  if (plmsi != null) {
    parts.add(
      'The periodic limb movements in sleep index was ${plmsi.toStringAsFixed(1)} per hour'
      '${flags['PLMS_severity'] == null ? '' : ' (${flags['PLMS_severity']})'}; values above 15/h are considered elevated in adults.',
    );
  }
  final ar = _val(report, 'PLMS_arousal_index');
  if (ar != null && ar > 0) {
    parts.add('${ar.toStringAsFixed(1)} PLMs per hour were associated with arousals.');
  }
  final pi = _val(report, 'periodicity_index');
  if (pi != null) {
    parts.add(
      'The periodicity index was ${pi.toStringAsFixed(2)} '
      '(values near 1 indicate strongly periodic movements, typical of restless legs syndrome; low values indicate irregular movements).',
    );
  }
  final rem = _val(report, 'PLMS_pct_in_REM');
  if (rem != null && rem > 30) {
    parts.add('An unusually large share of PLMs occurred in REM sleep (${rem.toStringAsFixed(0)}%), which can accompany REM sleep behaviour disorder or narcolepsy.');
  }
  final resp = _val(report, 'respiratory_LM_index');
  if (resp != null && resp > 0) {
    parts.add('${resp.toStringAsFixed(1)} leg movements per hour were respiratory-related and excluded from the PLM count.');
  }
  if (parts.isEmpty) parts.add('No limb-movement summary metrics were available.');
  return parts.join(' ');
}

// ─── Cyclic alternating pattern (CAP) ───────────────────────────────────────

/// A-phases (A1/A2/A3) and CAP sequences as markers. By default only
/// A-phases that belong to CAP sequences are shown (isolated A-phases are not
/// part of CAP); pass [includeIsolated] to show every detected A-phase.
List<ScoredEvent> capEventsFromReport(
  Map<String, dynamic> report, {
  bool aPhases = true,
  bool sequences = true,
  bool includeIsolated = false,
}) {
  final out = <ScoredEvent>[];
  if (aPhases) {
    for (final p in (report['a_phases'] as List? ?? const [])) {
      if (p is! Map) continue;
      if (!includeIsolated && p['in_sequence'] != true) continue;
      final sub = p['subtype']?.toString() ?? 'A1';
      final digit = sub == 'A3'
          ? kDigitCapA3
          : sub == 'A2'
          ? kDigitCapA2
          : kDigitCapA1;
      out.add(
        ScoredEvent(
          digit: digit,
          key: 'F$digit',
          label: kPsgEventNames[digit]!,
          type: 'CAP',
          startSec: _num(p['start'], 0),
          endSec: _num(p['end'], 0),
        ),
      );
    }
  }
  if (sequences) {
    for (final q in (report['sequences'] as List? ?? const [])) {
      if (q is! Map) continue;
      out.add(
        ScoredEvent(
          digit: kDigitCapSequence,
          key: 'F$kDigitCapSequence',
          label: kPsgEventNames[kDigitCapSequence]!,
          type: 'CAP',
          startSec: _num(q['start'], 0),
          endSec: _num(q['end'], 0),
        ),
      );
    }
  }
  return out;
}

List<(String, List<(String, String)>)> capSummarySections(
  Map<String, dynamic> report,
) {
  final s = (report['summary'] as Map?) ?? const {};
  final f = (report['flags'] as Map?) ?? const {};
  String v(String k, {int d = 1, String u = ''}) => _fmt(s[k], digits: d, suffix: u);
  return [
    (
      'CAP macro-parameters',
      [
        ('CAP rate (CAP time / NREM time)', v('CAP_rate', u: '%')),
        ('Level', f['CAP_rate_level']?.toString() ?? '-'),
        ('CAP rate N1 / N2 / N3', '${v('CAP_rate_N1', u: '%')} / ${v('CAP_rate_N2', u: '%')} / ${v('CAP_rate_N3', u: '%')}'),
        ('CAP time / NCAP time', '${v('CAP_time_min')} / ${v('NCAP_time_min')} min'),
        ('NREM time', '${v('NREM_min')} min'),
        ('CAP sequences / mean duration', '${v('n_CAP_sequences', d: 0)} / ${v('CAP_sequence_duration_mean_s', d: 0)} s'),
        ('CAP cycles / mean duration', '${v('n_CAP_cycles', d: 0)} / ${v('CAP_cycle_duration_mean_s')} s'),
        ('Cycles per sequence', v('CAP_cycles_per_sequence_mean')),
      ],
    ),
    (
      'A-phases (within CAP sequences)',
      [
        ('A-phase index (/h NREM)', v('A_index')),
        ('A1 / A2 / A3 index (/h)', '${v('A1_index')} / ${v('A2_index')} / ${v('A3_index')}'),
        ('A1 / A2 / A3 (% of A-phases)', '${v('A1_pct', d: 0)} / ${v('A2_pct', d: 0)} / ${v('A3_pct', d: 0)} %'),
        ('A2+A3 index (/h)', v('A2A3_index')),
        ('Mean A1 / A2 / A3 duration', '${v('A1_duration_mean_s')} / ${v('A2_duration_mean_s')} / ${v('A3_duration_mean_s')} s'),
        ('Mean B-phase duration', v('B_phase_duration_mean_s', u: ' s')),
      ],
    ),
    (
      'Novel & coupling markers',
      [
        ('CAP rate first / second half', '${v('CAP_rate_first_half', u: '%')} / ${v('CAP_rate_second_half', u: '%')}'),
        ('Isolated A-phase index (/h)', v('isolated_A_index')),
        ('A1 : (A2+A3) ratio', v('A1_to_A2A3_ratio', d: 2)),
        ('Median A-A interval', v('A_A_interval_median_s', u: ' s')),
        ('Cycle-duration variability (CV)', v('CAP_cycle_duration_cv', d: 2)),
        ('A2/A3 with scored arousal', v('A2A3_with_arousal_pct', u: '%')),
        ('A-phases after respiratory events', v('A_phases_respiratory_pct', u: '%')),
        ('Respiratory events followed by A-phase', v('respiratory_events_with_A_phase_pct', u: '%')),
        ('A-phases with leg movement', v('A_phases_with_LM_pct', u: '%')),
        ('Leg movements within A-phases', v('LMs_with_A_phase_pct', u: '%')),
      ],
    ),
  ];
}

String capInterpretation(Map<String, dynamic> report) {
  final flags = (report['flags'] as Map?) ?? const {};
  final rate = _val(report, 'CAP_rate');
  final parts = <String>[];
  if (rate != null) {
    parts.add(
      'Cyclic alternating pattern occupied ${rate.toStringAsFixed(1)}% of NREM sleep'
      '${flags['CAP_rate_level'] == null ? '' : ' (${flags['CAP_rate_level']})'}. '
      'CAP rate rises with age and with sleep instability; values are typically about 25-45% in healthy adults.',
    );
  }
  final a1 = _val(report, 'A1_pct');
  final a23 = (_val(report, 'A2_pct') ?? 0) + (_val(report, 'A3_pct') ?? 0);
  if (a1 != null) {
    parts.add(
      a1 >= 50
          ? 'A1 phases (slow, synchronised bursts that help build and maintain deep sleep) predominated (${a1.toStringAsFixed(0)}%).'
          : 'Arousal-like A2/A3 phases made up ${a23.toStringAsFixed(0)}% of A-phases, indicating a more fragmented, arousal-prone NREM sleep.',
    );
  }
  final resp = _val(report, 'A_phases_respiratory_pct');
  if (resp != null && resp >= 20) {
    parts.add('${resp.toStringAsFixed(0)}% of A-phases followed respiratory events, linking sleep instability to disordered breathing.');
  }
  final lm = _val(report, 'A_phases_with_LM_pct');
  if (lm != null && lm >= 20) {
    parts.add('${lm.toStringAsFixed(0)}% of A-phases coincided with leg movements.');
  }
  if (flags['method']?.toString().startsWith('automatic') ?? false) {
    parts.add('A-phases were detected automatically and should be reviewed on the EEG.');
  }
  if (parts.isEmpty) parts.add('No CAP summary metrics were available.');
  return parts.join(' ');
}
