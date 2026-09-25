import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/analyse_options.dart';
import 'package:ccs_sleep_studio/src/eeg_backend.dart';
import 'package:ccs_sleep_studio/src/models.dart';
import 'package:ccs_sleep_studio/src/multi_scoring_compare.dart';
import 'package:ccs_sleep_studio/src/publication_sleep_report.dart';

Map<String, dynamic> _nlgReport() {
  Map<String, dynamic> band(String name, double nrem) => {
    'band': {'name': name, 'f0': name == 'sigma' ? 14.0 : 1.0, 'bandwidth': 1.5, 'fc': 1.8, 'smooth_rate': 0.01666},
    'summary': {
      'NREM_mean': nrem,
      'N2_mean': nrem - 5,
      'N3_mean': nrem + 20,
      'REM_mean': 8.0,
      'W_mean': 12.0,
      'N1_mean': 10.0,
      'upper_quartile_index': nrem + 25,
      'NREM_slope_per_hour': -6.0,
      'artifact_percent': 5.0,
      'pib': 100.0,
      'C1_NREM_mean': 62.0,
      'C2_NREM_mean': 40.0,
    },
    'epoch_gain': [null, 10.0, 40.0, 70.0, 65.0, null, 30.0, 20.0],
    'hourly': [
      {'label': '1', 'nrem_gain': 60.0},
      {'label': '2', 'nrem_gain': null},
    ],
    'cycles': [],
  };
  return {
    'analysis': 'neuroloopgain',
    'references': ['M1', 'M2'],
    'channels': {
      'C3': {'slow_wave': band('slow_wave', 43), 'sigma': band('sigma', 42)},
      'C4': {'slow_wave': band('slow_wave', 45), 'sigma': band('sigma', 40)},
    },
    'average': {
      'slow_wave': band('slow_wave', 44)['summary'],
      'sigma': band('sigma', 41)['summary'],
    },
  };
}

void main() {
  test('kappa and confusion matrix against a reference scoring', () {
    const w = SleepStage.wake, n2 = SleepStage.n2, n3 = SleepStage.n3, r = SleepStage.rem;
    final ref = [w, n2, n2, n3, n3, r, r, SleepStage.unknown];
    final same = ScoringAgreement.compute(ref, List.of(ref));
    expect(same.kappa, closeTo(1.0, 1e-12));
    expect(same.accuracy, 1.0);
    expect(same.comparedEpochs, 7);
    final other = [w, n2, n3, n3, n2, r, w, n2];
    final a = ScoringAgreement.compute(ref, other);
    expect(a.comparedEpochs, 7);
    expect(a.accuracy, closeTo(4 / 7, 1e-12));
    // Reference N3 scored as N2 once.
    expect(a.confusion[kCompareStages.indexOf(n3)][kCompareStages.indexOf(n2)], 1);
    expect(a.kappa, lessThan(1));
    expect(a.tstMinutes, closeTo(6 * 0.5, 1e-9));
  });

  test('labels for scoring sidecars', () {
    expect(compareLabelForPath('/x/AS_CNT_10_Night2_yasa_sleepgpt_scoring.json', 'AS_CNT_10_Night2'), 'YASA + SleepGPT');
    expect(compareLabelForPath('/x/AS_CNT_10_Night2_manualscoring.edf', 'AS_CNT_10_Night2'), 'Manual scoring (EDF)');
    expect(compareLabelForPath('/x/AS_CNT_10_Night2_scoring.json', 'AS_CNT_10_Night2'), 'Saved scoring');
    expect(compareLabelForPath('/x/AS_CNT_10_Night2_usleep_scoring.json', 'AS_CNT_10_Night2'), 'U-Sleep');
  });

  test('analysis options build engine arguments', () {
    final all = AnalyseNidraOptions();
    final args = all.toArgs(nlgOutPath: '/o/x_analyse_nlg.json');
    expect(args.sublist(0, 2), ['--analyses', 'core,spindles,slow_waves,pac,nlg']);
    expect(args, containsAllInOrder(['--nlg-bands', 'slow_wave,sigma', '--nlg-smooth-rate']));
    expect(args, contains('/o/x_analyse_nlg.json'));
    final some = AnalyseNidraOptions(analyses: {'spindles'});
    expect(some.toArgs(), ['--analyses', 'spindles']);
    final roundTrip = AnalyseNidraOptions.fromJson(
      jsonDecode(jsonEncode(all.copyWith(nlgSmoothRate: 0.01).toJson())) as Map<String, dynamic>,
    );
    expect(roundTrip.nlgSmoothRate, 0.01);
    expect(roundTrip.analyses, all.analyses);
  });

  test('NeuroLoopGain overlay averages channels per epoch', () {
    final data = NlgOverlayData.fromReport(_nlgReport(), 'x.json')!;
    expect(data.channels, ['C3', 'C4']);
    expect(data.epochGain['slow_wave']![0], isNull);
    expect(data.epochGain['slow_wave']![3], closeTo(70, 1e-9));
    expect(data.isEmpty, isFalse);
  });

  test('adds the NeuroLoopGain page to the PDF report', () {
    final viewport = EegBackend().loadDemoViewport();
    final bytes = buildPublicationSleepReport(
      viewport: viewport,
      recordingName: 'psg.edf',
      regionalRows: const [],
      includePages: const [true, false, false, false, false],
      nlgReport: _nlgReport(),
    );
    final text = latin1.decode(bytes);
    expect(text, contains('/Count 2'));
    expect(text, contains('NEUROLOOPGAIN'));
    expect(nlgInterpretation(_nlgReport()), contains('declined'));
  });
}
