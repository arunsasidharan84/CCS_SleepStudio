import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/eeg_backend.dart';
import 'package:ccs_sleep_studio/src/models.dart';
import 'package:ccs_sleep_studio/src/psg_report_data.dart';
import 'package:ccs_sleep_studio/src/publication_sleep_report.dart';

Map<String, dynamic> _respiratoryReport() => {
  'analysis': 'respiratory',
  'channels': {
    'apnea_sensor': 'Flow (nasal pressure)',
    'hypopnea_sensor': 'Flow (nasal pressure)',
  },
  'summary': {
    'AHI': 21.4,
    'AHI_3a': 21.4,
    'AHI_4': 15.2,
    'OAI': 4.1,
    'CAI': 0.5,
    'MAI': 0.1,
    'HI': 16.7,
    'ODI3': 19.0,
    'T90_pct': 3.2,
    'T90_min': 12.5,
    'SpO2_min_sleep': 81.0,
    'hypoxic_burden_pct_min_per_h': 42.0,
    'delta_HR_bpm': 7.5,
    'TST_min': 390.0,
  },
  'flags': {
    'severity': 'moderate',
    'hypopnea_rule': 'AASM 1A (>=3% desaturation or arousal)',
    'REM_related_OSA': 'yes',
    'Cheyne_Stokes_breathing': 'absent',
  },
  'events': [
    {'kind': 'Obstructive Apnea', 'start': 60.0, 'end': 80.0, 'counted': true},
    {'kind': 'Central Apnea', 'start': 100.0, 'end': 115.0, 'counted': true},
    {'kind': 'Obstructive Hypopnea', 'start': 150.0, 'end': 170.0, 'counted': true},
    {'kind': 'Obstructive Hypopnea', 'start': 10.0, 'end': 25.0, 'counted': false},
  ],
  'desaturations': [
    {'start': 70.0, 'end': 95.0, 'drop': 4.0, 'nadir': 90.0, 'in_sleep': true},
    {'start': 5.0, 'end': 20.0, 'drop': 5.0, 'nadir': 91.0, 'in_sleep': false},
  ],
  'epochs': {
    'spo2_min': [96.0, 95.0, 90.0, 93.0, 96.0, 97.0, 95.0, 94.0],
  },
  'warnings': ['No oronasal thermal sensor'],
};

Map<String, dynamic> _plmReport() => {
  'analysis': 'plm',
  'settings': {'standard': 'AASM v3 (2023)', 'onset_uV': '8.0', 'offset_uV': '2.0'},
  'channels': {'left_leg': 'PLMl', 'right_leg': 'PLMr'},
  'summary': {'PLMS_index': 19.7, 'PLMW_index': 40.0, 'periodicity_index': 0.42},
  'flags': {'PLMS_severity': 'mild (15-25/h)'},
  'imi_histogram': [
    ['0-2 s', 3.0],
    ['10-20 s', 9.0],
  ],
  'hourly': [
    {'hour': 1.0, 'PLMS_index': 12.0},
    {'hour': 2.0, 'PLMS_index': 25.0},
  ],
  'movements': [
    {'start': 30.0, 'end': 32.0, 'side': 'L', 'clm': true, 'periodic': true},
    {'start': 50.0, 'end': 52.0, 'side': 'B', 'clm': true, 'periodic': false},
    {'start': 70.0, 'end': 70.2, 'side': 'R', 'clm': false, 'periodic': false},
  ],
};

Map<String, dynamic> _capReport() => {
  'analysis': 'cap',
  'channels': {'eeg': 'C4-A1'},
  'settings': {'sensitivity': 'standard'},
  'flags': {'method': 'automatic A-phase detection', 'CAP_rate_level': 'within the usual adult range (20-45 %)'},
  'summary': {'CAP_rate': 34.5, 'A_index': 41.2, 'A1_pct': 62.0, 'A2_pct': 25.0, 'A3_pct': 13.0},
  'hourly': [
    {'hour': 1.0, 'CAP_rate': 30.0},
    {'hour': 2.0, 'CAP_rate': 40.0},
  ],
  'a_phases': [
    {'start': 30.0, 'end': 35.0, 'subtype': 'A1', 'in_sequence': true},
    {'start': 55.0, 'end': 60.0, 'subtype': 'A2', 'in_sequence': true},
    {'start': 80.0, 'end': 86.0, 'subtype': 'A3', 'in_sequence': true},
    {'start': 200.0, 'end': 204.0, 'subtype': 'A1', 'in_sequence': false},
  ],
  'sequences': [
    {'start': 30.0, 'end': 86.0, 'n_cycles': 2},
  ],
};

void main() {
  test('converts CAP A-phases and sequences into markers', () {
    final events = capEventsFromReport(_capReport());
    expect(events.map((e) => e.digit).toList(), [
      kDigitCapA1,
      kDigitCapA2,
      kDigitCapA3,
      kDigitCapSequence,
    ]);
    expect(capEventsFromReport(_capReport(), includeIsolated: true, sequences: false).length, 4);
    expect(capInterpretation(_capReport()), contains('34.5'));
  });

  test('converts counted respiratory events and sleep desaturations', () {
    final events = respiratoryEventsFromReport(_respiratoryReport());
    expect(events.map((e) => e.digit).toList(), [
      kDigitObstructiveApnea,
      kDigitCentralApnea,
      kDigitHypopnea,
      kDigitDesaturation,
    ]);
    expect(events.every((e) => isRespiratoryEventDigit(e.digit)), isTrue);
  });

  test('converts candidate leg movements into LM / PLM markers', () {
    final events = plmEventsFromReport(_plmReport());
    expect(events.map((e) => e.digit).toList(), [kDigitPlm, kDigitLegMovement]);
    expect(events.first.label, 'PLM');
  });

  test('summary sections and interpretation mention key indices', () {
    final sections = respiratorySummarySections(_respiratoryReport());
    final flat = sections.expand((s) => s.$2).toList();
    expect(flat.any((row) => row.$2 == '21.4'), isTrue);
    expect(respiratoryInterpretation(_respiratoryReport()), contains('21.4'));
    expect(plmInterpretation(_plmReport()), contains('19.7'));
  });

  test('adds respiratory and PLM pages to the PDF report', () {
    final viewport = EegBackend().loadDemoViewport().copyWith(
      stages: const [
        SleepStage.wake,
        SleepStage.n1,
        SleepStage.n2,
        SleepStage.n2,
        SleepStage.n3,
        SleepStage.rem,
        SleepStage.rem,
        SleepStage.n2,
      ],
    );
    final bytes = buildPublicationSleepReport(
      viewport: viewport,
      recordingName: 'psg.edf',
      regionalRows: const [],
      includePages: const [true, false, false, false, false],
      respiratoryReport: _respiratoryReport(),
      plmReport: _plmReport(),
      capReport: _capReport(),
    );
    final text = latin1.decode(bytes);
    expect(text, contains('/Count 4'));
    expect(text, contains('CYCLIC ALTERNATING PATTERN'));
    expect(text, contains('RESPIRATORY EVENTS & OXIMETRY'));
    expect(text, contains('PERIODIC LIMB MOVEMENTS'));
    expect(bytes.every((b) => b >= 0 && b <= 255), isTrue);
  });
}
