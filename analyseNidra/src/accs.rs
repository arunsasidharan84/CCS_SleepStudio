//! Port of `accs_sleep_StageAnalyser.m` (Dr Arun Sasidharan, NIMHANS, rev.
//! 11 Apr 2020): full-night and sleep-cycle-wise sleep-stage parameters,
//! stage transitions, stage arousals and short awakenings.
//!
//! The port reproduces the MATLAB/Octave results epoch-for-epoch, including
//! its conventions:
//! * sleep onset = first N2, N3 or REM epoch; "total sleep duration" runs
//!   from sleep onset to the end of the record, "actual sleep" counts sleep
//!   epochs only;
//! * stage arousals (Conte et al. 2012) = transitions 2->1, 3->2, 3->1, R->1;
//! * short awakenings = wake bouts < 2 min, long awakenings = >= 5 min;
//! * NREM periods = >= 15 min of consecutive NREM; REM periods separated by
//!   <= 50 epochs belong to the same cycle (Aeschbach & Borbely 1993; Schulz
//!   et al. 1980); a cycle also ends at a long awakening (Armitage 2000);
//! * transition and stage-arousal positions are indexed from sleep onset, as
//!   in the MATLAB code, when they are assigned to cycles.
//!
//! All epoch indices below are 1-based to mirror the MATLAB source.

use crate::hypnogram::Stage;
use std::collections::BTreeMap;

const EPOCH_MIN: f64 = 0.5;

#[derive(Debug, Clone, Default)]
pub struct AccsCycle {
    pub values: BTreeMap<String, f64>,
}

#[derive(Debug, Clone, Default)]
pub struct AccsResult {
    pub fullnight: BTreeMap<String, f64>,
    pub cycles: Vec<AccsCycle>,
    pub cycle_starts: Vec<usize>,
    pub cycle_ends: Vec<usize>,
}

fn code_char(stage: Stage) -> char {
    match stage {
        Stage::Wake => '0',
        Stage::N1 => '1',
        Stage::N2 => '2',
        Stage::N3 => '3',
        Stage::Rem => '5',
        Stage::Unscored => '?',
    }
}

fn find(list: &[Stage], want: Stage) -> Vec<usize> {
    list.iter()
        .enumerate()
        .filter(|(_, s)| **s == want)
        .map(|(i, _)| i + 1)
        .collect()
}

/// Runs of consecutive integers: (first, last, length).
fn consecutive_runs(v: &[usize]) -> Vec<(usize, usize, usize)> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < v.len() {
        let mut j = i;
        while j + 1 < v.len() && v[j + 1] == v[j] + 1 {
            j += 1;
        }
        out.push((v[i], v[j], j - i + 1));
        i = j + 1;
    }
    out
}

/// Groups of indices split where the gap (x(i+1) - x(i) - 1) exceeds `gap`.
fn gap_groups(v: &[usize], gap: usize) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < v.len() {
        let mut j = i;
        while j + 1 < v.len() && v[j + 1] - v[j] - 1 <= gap {
            j += 1;
        }
        out.push((v[i], v[j]));
        i = j + 1;
    }
    out
}

fn intersect_count(a: &[usize], lo: usize, hi: usize) -> usize {
    if hi < lo {
        return 0;
    }
    let mut v: Vec<usize> = a.iter().copied().filter(|&x| x >= lo && x <= hi).collect();
    v.sort_unstable();
    v.dedup();
    v.len()
}

fn intersect_min(a: &[usize], lo: usize, hi: usize) -> Option<usize> {
    if hi < lo {
        return None;
    }
    a.iter().copied().filter(|&x| x >= lo && x <= hi).min()
}

/// Positions (1-based) of every literal 2-character `pat` in `s`,
/// non-overlapping, scanning left to right (MATLAB `regexp` behaviour).
fn regexp_positions(s: &[char], pat: [char; 2]) -> Vec<usize> {
    let mut out = Vec::new();
    let mut i = 0;
    while i + 1 < s.len() {
        if s[i] == pat[0] && s[i + 1] == pat[1] {
            out.push(i + 1);
            i += 2;
        } else {
            i += 1;
        }
    }
    out
}

fn pct(a: f64, b: f64) -> f64 {
    100.0 * a / b
}

/// Analyses a hypnogram (one stage per 30-s epoch). Trailing unscored epochs
/// are dropped, as the MATLAB stage-list creator does. Returns `None` when
/// the record contains no N2/N3/REM sleep.
pub fn analyse(stages: &[Stage]) -> Option<AccsResult> {
    let mut len = stages.len();
    while len > 0 && stages[len - 1] == Stage::Unscored {
        len -= 1;
    }
    let list = &stages[..len];
    let n = list.len();
    if n == 0 {
        return None;
    }
    let wake = find(list, Stage::Wake);
    let mut n1 = find(list, Stage::N1);
    let mut n2 = find(list, Stage::N2);
    let mut n3 = find(list, Stage::N3);
    let mut rem = find(list, Stage::Rem);

    let sleep_onset = n2.iter().chain(&n3).chain(&rem).copied().min()?;
    let mut sleep_index: Vec<usize> = n1.iter().chain(&n2).chain(&n3).chain(&rem).copied().filter(|&i| i >= sleep_onset).collect();
    sleep_index.sort_unstable();
    let last_sleep = *sleep_index.last()?;
    let first_sleep = sleep_index[0];
    let sleep_offset = (last_sleep + 1).min(n);
    let mut n2_n3: Vec<usize> = n2.iter().chain(&n3).copied().filter(|&i| i >= first_sleep && i <= last_sleep).collect();
    n2_n3.sort_unstable();
    n2_n3.dedup();
    let mut nrem: Vec<usize> = n1.iter().chain(&n2).chain(&n3).copied().filter(|&i| i >= first_sleep && i <= last_sleep).collect();
    nrem.sort_unstable();
    nrem.dedup();
    let waso: Vec<usize> = wake.iter().copied().filter(|&i| i > sleep_onset).collect();

    let count_after = |v: &[usize]| v.iter().filter(|&&i| i >= sleep_onset).count() as f64 * EPOCH_MIN;
    let trd = n as f64 * EPOCH_MIN;
    let wake_dur = wake.len() as f64 * EPOCH_MIN;
    let n1_dur = count_after(&n1);
    let n2_dur = count_after(&n2);
    let n3_dur = count_after(&n3);
    let rem_dur = count_after(&rem);
    let total_sleep = trd - sleep_onset as f64 * EPOCH_MIN;
    let actual = n1_dur + n2_dur + n3_dur + rem_dur;
    let waso_dur = waso.len() as f64 * EPOCH_MIN;

    let n1_lat = if let Some(&m) = n1.iter().min() { m as f64 * EPOCH_MIN } else { n1 = vec![0]; f64::NAN };
    let n2_lat = if let Some(&m) = n2.iter().min() { m as f64 * EPOCH_MIN } else { n2 = vec![0]; f64::NAN };
    let n3_lat = if let Some(m) = n3.iter().copied().filter(|&i| i >= sleep_onset).min() {
        (m - sleep_onset) as f64 * EPOCH_MIN
    } else {
        n3 = vec![0];
        f64::NAN
    };
    let rem_lat = if let Some(m) = rem.iter().copied().filter(|&i| i >= sleep_onset).min() {
        (m - sleep_onset) as f64 * EPOCH_MIN
    } else {
        rem = vec![0];
        f64::NAN
    };

    // Stage codes from sleep onset to sleep offset (inclusive).
    let codes: Vec<char> = list[sleep_onset - 1..sleep_offset].iter().map(|s| code_char(*s)).collect();
    let mut arousals_idx: Vec<usize> = Vec::new();
    for pat in [['2', '1'], ['3', '2'], ['3', '1'], ['5', '1']] {
        arousals_idx.extend(regexp_positions(&codes, pat));
    }
    arousals_idx.sort_unstable();
    // Stage transitions: first index of every run of equal codes (unscored
    // epochs never equal each other, like NaN in MATLAB), minus the first.
    let mut transitions_idx: Vec<usize> = Vec::new();
    for (i, c) in codes.iter().enumerate() {
        if i == 0 || *c != codes[i - 1] || *c == '?' {
            transitions_idx.push(i + 1);
        }
    }
    if !transitions_idx.is_empty() {
        transitions_idx.remove(0);
    }

    // ── Sleep cycles ──────────────────────────────────────────────────────
    let nrem_runs: Vec<(usize, usize, usize)> = consecutive_runs(&nrem).into_iter().filter(|r| r.2 >= 30).collect();
    let mut nrem_starts: Vec<usize> = nrem_runs.iter().map(|r| r.0).collect();
    let mut nrem_ends: Vec<usize> = nrem_runs.iter().map(|r| r.1).collect();
    let rem_present = !(rem.len() == 1 && rem[0] == 0);
    let (rem_starts, rem_ends): (Vec<usize>, Vec<usize>) =
        if rem_present { gap_groups(&rem, 50).into_iter().unzip() } else { (Vec::new(), Vec::new()) };
    if let (Some(&re1), Some(&ns1)) = (rem_ends.first(), nrem_starts.first()) {
        if re1 < ns1 {
            nrem_starts.insert(0, sleep_onset);
            nrem_ends.insert(0, rem_starts[0]);
        }
    }
    let awakenings = consecutive_runs(&wake);
    let long_awake: Vec<usize> = awakenings.iter().filter(|r| r.2 >= 10).map(|r| r.0 - 1).collect();
    let short_awake: Vec<usize> = awakenings.iter().filter(|r| r.2 < 4).map(|r| r.0).collect();

    let mut cyc_start = vec![0usize; n + 1];
    let mut cyc_end = vec![0usize; n + 1];
    let n_pot = nrem_starts.len();
    cyc_start[1] = sleep_onset;
    let window_end = |it: usize, nrem_starts: &Vec<usize>| -> (usize, usize) {
        if it < n_pot {
            (nrem_ends[it - 1], nrem_starts[it])
        } else {
            (nrem_ends[it - 1], sleep_offset)
        }
    };
    let end_in_window = |lo: usize, hi: usize| -> Option<usize> {
        intersect_min(&rem_ends, lo, hi).or_else(|| intersect_min(&long_awake, lo, hi))
    };
    for it in 1..=n_pot {
        let any_end = cyc_end.iter().any(|&e| e != 0);
        if !any_end {
            if n_pot == 1 {
                if nrem_starts.len() < 2 {
                    nrem_starts.push(last_sleep);
                } else {
                    nrem_starts[1] = last_sleep;
                }
            }
            let (lo, hi) = window_end(it, &nrem_starts);
            if let Some(e) = end_in_window(lo, hi) {
                cyc_end[it] = e;
            }
        } else {
            if cyc_end[it - 1] != 0 {
                if let Some(s) = n2_n3.iter().copied().filter(|&i| i > cyc_end[it - 1]).min() {
                    cyc_start[it] = s;
                }
            }
            let (lo, hi) = window_end(it, &nrem_starts);
            if let Some(e) = end_in_window(lo, hi) {
                cyc_end[it] = e;
            }
        }
    }
    cyc_end[n] = last_sleep;
    let mut starts: Vec<usize> = cyc_start.iter().copied().filter(|&v| v != 0).collect();
    let mut ends: Vec<usize> = cyc_end.iter().copied().filter(|&v| v != 0).collect();
    starts.sort_unstable();
    starts.dedup();
    ends.sort_unstable();
    ends.dedup();
    if starts.len() == ends.len() + 1 {
        starts.pop();
    } else if ends.len() == starts.len() + 1 && ends.len() >= 2 {
        if let Some(s) = n2_n3.iter().copied().filter(|&i| i > ends[ends.len() - 2]).min() {
            starts.push(s);
        }
    }
    if starts.len() != ends.len() {
        let k = starts.len().min(ends.len());
        starts.truncate(k);
        ends.truncate(k);
    }

    let mut cycles = Vec::new();
    let mut failed: Vec<(usize, f64, f64)> = Vec::new();
    let mut last_success: Option<usize> = None;
    for c in 0..ends.len() {
        let (s, e) = (starts[c], ends[c]);
        let mut v = BTreeMap::new();
        let dur = |idx: &[usize]| intersect_count(idx, s, e) as f64 * EPOCH_MIN;
        let w = dur(&wake);
        let d1 = dur(&n1);
        let d2 = dur(&n2);
        let d3 = dur(&n3);
        let dr = dur(&rem);
        let dn = d1 + d2 + d3;
        let cycle_dur = if e >= s { (e - s + 1) as f64 * EPOCH_MIN } else { 0.0 };
        v.insert("Sleep_duration_cycle".into(), cycle_dur);
        v.insert("Wake_duration_cycle".into(), w);
        v.insert("N1_duration_cycle".into(), d1);
        v.insert("N2_duration_cycle".into(), d2);
        v.insert("N3_duration_cycle".into(), d3);
        v.insert("REM_duration_cycle".into(), dr);
        v.insert("Wake_percentage_cycle".into(), pct(w, cycle_dur));
        v.insert("N1_percentage_cycle".into(), pct(d1, cycle_dur));
        v.insert("N2_percentage_cycle".into(), pct(d2, cycle_dur));
        v.insert("N3_percentage_cycle".into(), pct(d3, cycle_dur));
        v.insert("REM_percentage_cycle".into(), pct(dr, cycle_dur));
        // NREM and REM parts of the cycle.
        let (nrem_part, rem_part): ((usize, usize), Option<(usize, usize)>) = if dr != 0.0 {
            let first_rem = intersect_min(&rem, s, e).unwrap_or(e + 1);
            if first_rem <= s {
                // MATLAB indexes an empty NREM period here and skips the
                // remaining cycle measures (try/catch). The per-cycle
                // transition arrays are only grown by later cycles, so these
                // measures read back as 0 when a later cycle succeeds (fixed
                // up after the loop) and are absent otherwise.
                if dn == 0.0 {
                    v.insert("NREM_StageTransitions_cycle".into(), 0.0);
                    v.insert("NREM_StageArousals_cycle".into(), 0.0);
                    v.insert("NREM_ShortAwakenings_cycle".into(), 0.0);
                }
                failed.push((c, dn, d2 + d3));
                cycles.push(AccsCycle { values: v });
                continue;
            }
            ((s, first_rem - 1), Some((first_rem, e)))
        } else {
            ((s, e), None)
        };
        let count = |idx: &[usize], lo: usize, hi: usize| intersect_count(idx, lo, hi) as f64;
        let (nt, na, nsw) = (
            count(&transitions_idx, nrem_part.0, nrem_part.1),
            count(&arousals_idx, nrem_part.0, nrem_part.1),
            count(&short_awake, nrem_part.0, nrem_part.1),
        );
        let (rt, ra, rsw) = match rem_part {
            Some((lo, hi)) => (count(&transitions_idx, lo, hi), count(&arousals_idx, lo, hi), count(&short_awake, lo, hi)),
            None => (0.0, 0.0, 0.0),
        };
        if dn != 0.0 {
            v.insert("NREM_StageTransitions_cycle".into(), 60.0 * nt / dn);
            v.insert("NREM_StageArousals_cycle".into(), 60.0 * na / (d2 + d3));
            v.insert("NREM_ShortAwakenings_cycle".into(), 60.0 * nsw / dn);
        } else {
            v.insert("NREM_StageTransitions_cycle".into(), 0.0);
            v.insert("NREM_StageArousals_cycle".into(), 0.0);
            v.insert("NREM_ShortAwakenings_cycle".into(), 0.0);
        }
        if dr != 0.0 {
            v.insert("REM_StageTransitions_cycle".into(), 60.0 * rt / dr);
            v.insert("REM_StageArousals_cycle".into(), 60.0 * ra / dr);
            v.insert("REM_ShortAwakenings_cycle".into(), 60.0 * rsw / dr);
        } else {
            v.insert("REM_StageTransitions_cycle".into(), 0.0);
            v.insert("REM_StageArousals_cycle".into(), 0.0);
            v.insert("REM_ShortAwakenings_cycle".into(), 0.0);
        }
        last_success = Some(c);
        cycles.push(AccsCycle { values: v });
    }
    for (c, dn, d23) in failed {
        if last_success.is_some_and(|l| l > c) {
            let v = &mut cycles[c].values;
            if dn != 0.0 {
                v.insert("NREM_StageTransitions_cycle".into(), 0.0 / dn);
                v.insert("NREM_StageArousals_cycle".into(), 0.0 / d23);
                v.insert("NREM_ShortAwakenings_cycle".into(), 0.0 / dn);
            }
            v.insert("REM_StageTransitions_cycle".into(), 0.0);
            v.insert("REM_StageArousals_cycle".into(), 0.0);
            v.insert("REM_ShortAwakenings_cycle".into(), 0.0);
        }
    }

    let mut f = BTreeMap::new();
    f.insert("TotalRecording_duration".into(), trd);
    f.insert("SleepOnsetLatency".into(), sleep_onset as f64 * EPOCH_MIN);
    f.insert("TotalSleep_duration".into(), total_sleep);
    f.insert("ActualSleep_duration".into(), actual);
    f.insert("Wake_duration".into(), wake_dur);
    f.insert("WASO_duration".into(), waso_dur);
    f.insert("N1_duration".into(), n1_dur);
    f.insert("N2_duration".into(), n2_dur);
    f.insert("N3_duration".into(), n3_dur);
    f.insert("REM_duration".into(), rem_dur);
    f.insert("Wake_percentage".into(), pct(wake_dur, trd));
    f.insert("WASO_percentage".into(), pct(waso_dur, total_sleep));
    f.insert("N1_percentage".into(), pct(n1_dur, actual));
    f.insert("N2_percentage".into(), pct(n2_dur, actual));
    f.insert("N3_percentage".into(), pct(n3_dur, actual));
    f.insert("REM_percentage".into(), pct(rem_dur, actual));
    f.insert("N1_latency".into(), n1_lat);
    f.insert("N2_latency".into(), n2_lat);
    f.insert("N3_latency".into(), n3_lat);
    f.insert("REM_latency".into(), rem_lat);
    f.insert("SleepEfficiency_percentage".into(), pct(actual, trd));
    f.insert("SleepCycle_number".into(), ends.len() as f64);
    f.insert("Stage_transitions".into(), 60.0 * transitions_idx.len() as f64 / actual);
    f.insert("ShortAwakenings".into(), 60.0 * short_awake.len() as f64 / actual);
    f.insert("Stage_arousals".into(), 60.0 * arousals_idx.len() as f64 / (n2_dur + n3_dur + rem_dur));
    Some(AccsResult { fullnight: f, cycles, cycle_starts: starts, cycle_ends: ends })
}

/// Flattens the result into non-prefixed keys (e.g. `SleepCycle_number`,
/// `Stage_transitions`, `C1_start_epoch`, `C1_Sleep_duration_cycle`, ...),
/// plus `accs_*` aliases for backwards-compatibility.
pub fn flatten(result: &AccsResult) -> BTreeMap<String, f64> {
    let mut out = BTreeMap::new();
    for (k, v) in &result.fullnight {
        out.insert(k.clone(), *v);
        out.insert(format!("accs_{k}"), *v);
    }
    for (i, c) in result.cycles.iter().enumerate() {
        let cycle_idx = i + 1;
        for (k, v) in &c.values {
            out.insert(format!("C{cycle_idx}_{k}"), *v);
            out.insert(format!("accs_C{cycle_idx}_{k}"), *v);
        }
        out.insert(format!("C{cycle_idx}_start_epoch"), result.cycle_starts[i] as f64);
        out.insert(format!("C{cycle_idx}_end_epoch"), result.cycle_ends[i] as f64);
        out.insert(format!("accs_C{cycle_idx}_start_epoch"), result.cycle_starts[i] as f64);
        out.insert(format!("accs_C{cycle_idx}_end_epoch"), result.cycle_ends[i] as f64);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use Stage::*;

    #[test]
    fn two_cycles_and_stage_arousals() {
        let mut h = vec![Wake; 10];
        h.extend(vec![N1; 2]);
        h.extend(vec![N2; 20]);
        h.extend(vec![N3; 20]);
        h.extend(vec![N2, N1, N2]);
        h.extend(vec![Rem; 12]);
        h.extend(vec![Wake; 12]);
        h.extend(vec![N2; 40]);
        h.extend(vec![Rem; 15]);
        h.extend(vec![Wake; 5]);
        let r = analyse(&h).unwrap();
        // Reference values from accs_sleep_StageAnalyser.m (MATLAB R2024b / Octave 8.4).
        assert_eq!(r.fullnight["SleepCycle_number"], 2.0);
        assert_eq!(r.fullnight["SleepOnsetLatency"], 6.5);
        assert!((r.fullnight["Stage_transitions"] - 9.818181818).abs() < 1e-6);
        assert!((r.fullnight["Stage_arousals"] - 2.201834862).abs() < 1e-6);
        assert_eq!(r.cycle_starts, vec![13, 80]);
        assert_eq!(r.cycle_ends, vec![67, 134]);
        assert!((r.cycles[0].values["NREM_StageArousals_cycle"] - 5.714285714).abs() < 1e-6);
        assert_eq!(r.cycles[1].values["REM_duration_cycle"], 7.5);
    }
}
