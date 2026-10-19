import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/eeg_backend.dart';
import 'package:ccs_sleep_studio/src/models.dart';
import 'package:ccs_sleep_studio/src/publication_sleep_report.dart';
import 'package:ccs_sleep_studio/src/regional_csv.dart';

void main() {
  test('builds a five-page quantitative sleep report', () {
    final viewport = EegBackend().loadDemoViewport().copyWith(
      currentEpoch: 4,
      stages: const [
        SleepStage.wake,
        SleepStage.n1,
        SleepStage.n2,
        SleepStage.n2,
        SleepStage.n3,
        SleepStage.n3,
        SleepStage.rem,
        SleepStage.rem,
      ],
      stagesUncertain: const [
        false,
        true,
        false,
        false,
        false,
        false,
        false,
        false,
      ],
      showSwaPlot: true,
      scoredEvents: const [
        ScoredEvent(
          digit: 0,
          key: 'A',
          label: 'Artifact',
          startSec: 30,
          endSec: 75,
        ),
        ScoredEvent(
          digit: 1,
          key: 'F1',
          label: 'Spindle',
          startSec: 120,
          endSec: 180,
        ),
      ],
    );
    final bytes = buildPublicationSleepReport(
      viewport: viewport,
      recordingName: 'subject.edf',
      regionalRows: [
        {
          'Chan': 'Central',
          'TRT': '480',
          'TST': '410',
          'SOL': '18',
          'WASO': '52',
          'N2_longest_streak': '34',
          'NREM_duration': '320',
          'W_duration': '70',
          'N1_duration': '20',
          'N2_duration': '200',
          'N3_duration': '100',
          'R_duration': '90',
          'W_exponent_FOOOF': '1.1',
          'W_slope_Irasa': '1.3',
          'W_rsquared_Irasa': '0.9',
          'W_auc_Irasa': '-12.5',
          'W_perm_entropy_nonlinear': '0.9',
          'W_ACW': '0.08',
          'sp_all_density': '2.1',
          'sw_all_Count': '160',
          'sw_all_PhaseAtSigmaPeak': '1.2',
          'sw_all_ndPAC': '0.15',
          'pac_all_max_MI': '0.012',
          'N2_exponent_FOOOF': '1.4',
          'N2_slope_Irasa': '-1.2',
          'N2_Delta_PSD': '0.31',
          'N2_Theta_PSD': '0.22',
          'N2_Sigma_PSD': '0.17',
          'N2_Alpha_PSD': '0.12',
          'N2_Beta1_PSD': '0.09',
          'N2_Beta2_PSD': '0.05',
          'N2_perm_entropy_nonlinear': '0.8',
          'N2_ACW': '0.12',
        },
      ],
      metadata: const ReportMetadata(
        title: 'University Sleep Study',
        studySite: 'Clinical Neurophysiology Laboratory',
        investigatorName: 'Dr Investigator',
        subjectId: 'SUB-001',
        subjectDetails: 'Adult research participant',
      ),
    );
    final pdf = latin1.decode(bytes);
    if (const bool.fromEnvironment('REPORT_PREVIEW')) {
      File('/tmp/CCSSleepStudio_report_preview.pdf').writeAsBytesSync(bytes);
    }

    expect(pdf, startsWith('%PDF-1.4'));
    expect(pdf, contains('/Count 5'));
    expect(pdf, contains('UNIVERSITY SLEEP STUDY'));
    expect(pdf, contains('(Study site: Clinical Neurophysiology Laboratory'));
    expect(pdf, contains('(UNDERSTANDING YOUR RESULTS)'));
    expect(pdf, contains('(Important Limitations & Clinical Disclaimer)'));
    expect(pdf, contains('THALAMOCORTICAL MICROSTRUCTURE'));
    expect(pdf, contains('CORTICAL COMPLEXITY LANDSCAPE'));
    expect(pdf, contains('(Event)'));
    expect(pdf, contains('0.39 0.58 0.93 rg'));
    expect(pdf, contains('(70.0 min \\(14.6%\\))'));
    expect(pdf, contains('(IRASA R2)'));
    expect(pdf, contains('(IRASA AUC)'));
    expect(pdf, contains('(Low)'));
    expect(pdf, contains('(High)'));
    expect(pdf, contains('(410.0 min)'));
    expect(pdf, contains('(18.0 min)'));
    expect(pdf, contains('(Frequency-band relative PSD \\(regional mean\\))'));
    expect(pdf, contains('(0.310)'));
    expect(pdf, contains('(Spindles: 2.10/min)'));
    expect(pdf, contains('(SO-Sigma PAC MI: 0.0120)'));
  });

  test('interpretation page only summarizes selected analysis pages', () {
    final viewport = EegBackend().loadDemoViewport();
    final bytes = buildPublicationSleepReport(
      viewport: viewport,
      recordingName: 'subject.edf',
      includePages: const [true, false, false, false, true],
      regionalRows: [
        {
          'Chan': 'Central',
          'TRT': '480',
          'TST': '410',
          'Sleep_efficiency': '85',
          'sp_all_density': '2.1',
          'pac_all_max_MI': '0.012',
          'N2_exponent_FOOOF': '1.4',
          'N2_perm_entropy_nonlinear': '0.8',
        },
      ],
    );

    final pdf = latin1.decode(bytes);
    expect(pdf, contains('/Count 2'));
    expect(pdf, contains('(Sleep Macroarchitecture & Continuity)'));
    expect(pdf, isNot(contains('(Microstructure & Oscillatory Coupling)')));
  });

  test('optionally renders a supplied AnalyseNidra CSV', () {
    final csvPath = Platform.environment['REPORT_CSV'];
    final outputPath = Platform.environment['REPORT_OUT'];
    if (csvPath == null || outputPath == null) {
      return;
    }

    final csv = File(csvPath);
    expect(csv.existsSync(), isTrue);
    final bytes = buildPublicationSleepReport(
      viewport: EegBackend().loadDemoViewport(),
      recordingName: csv.uri.pathSegments.last,
      regionalRows: parseCsvTable(csv.readAsStringSync()),
      metadata: const ReportMetadata(
        title: 'Clinical Sleep EEG Study',
        studySite: 'Neurophysiology Laboratory',
        investigatorName: 'Study Investigator',
        subjectId: 'Preview Subject',
        subjectDetails: 'Research report preview',
      ),
    );
    File(outputPath).writeAsBytesSync(bytes);

    expect(bytes, isNotEmpty);
  });
}
