//! Cyclic alternating pattern (CAP) analysis following the atlas rules of
//! Terzano et al. (Sleep Med 2001;2:537-553), with automatic A-phase
//! detection from EEG band descriptors (after Mariani et al., Clin
//! Neurophysiol 2011/2012 and Largo et al. 2019):
//!
//! * EEG (central derivation, C4-A1/C3-A2 preferred) is band-passed into
//!   delta (0.5-4 Hz), alpha (8-11), sigma (11-16) and beta (16-30) and a 1-s
//!   RMS amplitude envelope is sampled every second.
//! * Each envelope is divided by its local NREM background (median of a
//!   centred 65-s window). Synchronised (A1-type) activity: delta ratio >=
//!   `slow_ratio`; desynchronised (A2/A3-type) activity: combined alpha+beta
//!   ratio >= `fast_ratio` and not exceeded by the sigma ratio (so spindles
//!   are not taken for desynchronisation). A candidate must also peak at
//!   `peak_factor` x the threshold. The default ratios were calibrated so
//!   that healthy control recordings give CAP rates and A-phase indices in
//!   the published normative range; `sensitivity` selects stricter or looser
//!   settings.
//! * When the scoring file already contains A-phase markers (A1/A2/A3), those
//!   manual A-phases are used instead of automatic detection.
//! * Activations closer than 2 s are merged; A-phases last 2-60 s and are
//!   scored in NREM only. Scored arousals in NREM are added as A-phases.
//! * Subtypes: A1 when desynchronised activity covers < 20 % of the phase,
//!   A2 20-50 %, A3 > 50 %.
//! * CAP cycle = A-phase + following B-phase (2-60 s). A CAP sequence needs
//!   >= 2 consecutive cycles (>= 3 A-phases) and is broken by B > 60 s or by
//!   wake/REM; its duration runs from the first A onset to the last A end.
//!
//! Standard CAP parameters (CAP time, CAP rate overall and per NREM stage,
//! sequences, cycles, A-phase indices and durations, B duration) plus novel
//! descriptors: isolated A-phase index, cycle-duration variability, CAP rate
//! per hour and per half of the night, A-phase/arousal concordance and
//! coupling of A-phases with respiratory events and leg movements.

use super::common::*;
use crate::edf::read_signal_infos;
use crate::hypnogram::Stage;
use anyhow::{bail, Result};
use serde::Serialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

const FS: f64 = 100.0;

#[derive(Debug, Clone)]
pub struct CapOptions {
    pub scoring: Option<PathBuf>,
    pub eeg: Vec<String>,
    pub respiratory_json: Option<PathBuf>,
    pub plm_json: Option<PathBuf>,
    /// "prefer-manual" (add scored arousals as A-phases) or "none"
    pub arousal_mode: String,
    /// "conservative", "standard" (default) or "sensitive" detector settings
    pub sensitivity: String,
    /// "prefer-manual" (use A1/A2/A3 markers from the scoring file when
    /// present), "manual" or "auto"
    pub a_phase_source: String,
    pub lights_off: Option<f64>,
    pub lights_on: Option<f64>,
}

impl Default for CapOptions {
    fn default() -> Self {
        Self {
            scoring: None,
            eeg: Vec::new(),
            respiratory_json: None,
            plm_json: None,
            arousal_mode: "prefer-manual".into(),
            sensitivity: "standard".into(),
            a_phase_source: "prefer-manual".into(),
            lights_off: None,
            lights_on: None,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct APhase {
    pub start: f64,
    pub end: f64,
    pub duration: f64,
    /// "A1", "A2" or "A3"
    pub subtype: String,
    pub stage: String,
    /// fraction of the phase with desynchronised (fast) activity
    pub desync_fraction: f64,
    pub in_sequence: bool,
    /// overlaps a scored arousal
    pub arousal: bool,
    /// begins within 5 s of the end of a respiratory event
    pub respiratory: bool,
    /// a candidate leg movement starts within the phase (+-2 s)
    pub leg_movement: bool,
    /// "auto" (EEG detector) or "arousal" (scored arousal)
    pub source: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct CapSequence {
    pub start: f64,
    pub end: f64,
    pub duration: f64,
    pub n_cycles: usize,
    pub n_a: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct CapReport {
    pub analysis: String,
    pub version: String,
    pub recording: String,
    pub scoring: Option<String>,
    pub channels: BTreeMap<String, String>,
    pub settings: BTreeMap<String, String>,
    pub has_hypnogram: bool,
    pub summary: BTreeMap<String, f64>,
    pub flags: BTreeMap<String, String>,
    pub hourly: Vec<BTreeMap<String, f64>>,
    pub a_phases: Vec<APhase>,
    pub sequences: Vec<CapSequence>,
    pub warnings: Vec<String>,
}

/// 1-s RMS amplitude envelope of `x` band-passed to [lo, hi] Hz, sampled at
/// the centre of every second.
fn band_envelope(x: &[f64], lo: f64, hi: f64, n_sec: usize) -> Vec<f64> {
    let y = butter_filtfilt(x, FS, Some(lo), Some(hi));
    let sq: Vec<f64> = y.iter().map(|v| v * v).collect();
    let ma = moving_average(&sq, FS as usize);
    (0..n_sec)
        .map(|s| {
            let i = ((s as f64 + 0.5) * FS) as usize;
            ma.get(i.min(ma.len().saturating_sub(1))).copied().unwrap_or(0.0).max(0.0).sqrt()
        })
        .collect()
}

/// Ratio of an envelope to its background: median of the NREM values in a
/// centred 65-s window (all values when fewer than 16 NREM seconds).
fn background_ratio(env: &[f64], nrem: &[bool]) -> Vec<f64> {
    let n = env.len();
    let half = 32usize;
    let mut vals: Vec<f64> = Vec::with_capacity(2 * half + 1);
    (0..n)
        .map(|t| {
            let a = t.saturating_sub(half);
            let b = (t + half + 1).min(n);
            vals.clear();
            vals.extend((a..b).filter(|&j| nrem[j]).map(|j| env[j]));
            if vals.len() < 16 {
                vals.clear();
                vals.extend(env[a..b].iter().copied());
            }
            let bg = median(&vals);
            if bg > 0.0 { env[t] / bg } else { 1.0 }
        })
        .collect()
}

/// (slow_ratio, fast_ratio, peak_factor) for a sensitivity setting.
fn thresholds(sensitivity: &str) -> (f64, f64, f64) {
    match sensitivity.to_ascii_lowercase().as_str() {
        "conservative" | "strict" => (2.3, 2.0, 1.3),
        "sensitive" | "liberal" => (1.8, 1.8, 1.0),
        _ => (2.0, 1.8, 1.3),
    }
}

/// Manual A-phase markers (labels such as "A1", "A2 phase", "MCAP-A3") from
/// the scoring file; the "CAP A1/A2/A3" markers written by this analysis are
/// ignored.
fn manual_a_phases(events: &[(f64, f64, String)]) -> Vec<(f64, f64, String)> {
    events
        .iter()
        .filter_map(|(s, e, l)| {
            // "CAP A1/A2/A3" markers are written by this analysis itself.
            if l.trim().to_ascii_uppercase().starts_with("CAP A") {
                return None;
            }
            let u = l.to_ascii_uppercase().replace(['-', '_'], " ");
            let tokens: Vec<&str> = u.split_whitespace().collect();
            let sub = ["A1", "A2", "A3"].into_iter().find(|t| tokens.contains(t) || u.ends_with(&format!("CAP{t}")))?;
            (e > s).then(|| (*s, *e, sub.to_string()))
        })
        .collect()
}

fn read_json_spans(path: &Path, key: &str, filter: &dyn Fn(&serde_json::Value) -> bool) -> Vec<(f64, f64)> {
    let Ok(text) = std::fs::read_to_string(path) else { return Vec::new() };
    let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else { return Vec::new() };
    v.get(key)
        .and_then(|e| e.as_array())
        .map(|arr| {
            arr.iter()
                .filter(|e| filter(e))
                .filter_map(|e| Some((e.get("start")?.as_f64()?, e.get("end")?.as_f64()?)))
                .collect()
        })
        .unwrap_or_default()
}

fn is_nrem(s: Stage) -> bool {
    matches!(s, Stage::N1 | Stage::N2 | Stage::N3)
}

pub fn analyse(edf: &Path, opts: &CapOptions) -> Result<CapReport> {
    println!("PROGRESS 0.05 Reading channel list");
    let infos = read_signal_infos(edf)?;
    let mut warnings = Vec::new();
    let mut channels = BTreeMap::new();

    println!("PROGRESS 0.10 Loading EEG");
    let Some((raw, efs, label)) = load_arousal_eeg(edf, &infos, &opts.eeg)? else {
        bail!("No central/frontal EEG channel found for CAP scoring. Select an EEG derivation (e.g. C4-A1) explicitly.");
    };
    channels.insert("eeg".into(), label.clone());
    let duration = raw.len() as f64 / efs;
    let (stages, scoring_events) = match &opts.scoring {
        Some(p) if p.exists() => {
            let (s, e) = read_scoring(p)?;
            (Some(s), e)
        }
        _ => (None, Vec::new()),
    };
    let ctx = SleepContext::new(stages, duration, opts.lights_off, opts.lights_on);
    if !ctx.has_hypnogram {
        bail!("CAP is scored in NREM sleep only: score or autoscore the recording first so a hypnogram is available.");
    }
    if efs < 100.0 {
        warnings.push(format!("{label} is sampled at {efs} Hz; >= 100 Hz is recommended for CAP scoring."));
    }

    println!("PROGRESS 0.20 Filtering and computing band envelopes");
    let hi = (efs / 2.0 - 1.0).min(35.0);
    let mut x = butter_filtfilt(&raw, efs, Some(0.3), Some(hi));
    for mains in [50.0, 60.0] {
        if mains < efs / 2.0 {
            x = notch_filtfilt(&x, efs, mains);
        }
    }
    let x = if (efs - FS).abs() > 1e-6 { resample_linear(&x, efs, FS) } else { x };
    let n_sec = (x.len() as f64 / FS) as usize;
    if n_sec < 600 {
        bail!("Recording too short for CAP analysis.");
    }
    let nrem: Vec<bool> = (0..n_sec)
        .map(|t| {
            let tt = t as f64 + 0.5;
            ctx.in_window(tt) && is_nrem(ctx.stage_at(tt))
        })
        .collect();
    let nrem_sec = nrem.iter().filter(|v| **v).count() as f64;
    if nrem_sec < 600.0 {
        bail!("Less than 10 minutes of NREM sleep: CAP cannot be scored.");
    }
    let delta = band_envelope(&x, 0.5, 4.0, n_sec);
    let alpha = band_envelope(&x, 8.0, 11.0, n_sec);
    let sigma = band_envelope(&x, 11.0, 16.0, n_sec);
    let beta = band_envelope(&x, 16.0, 30.0, n_sec);
    let fast_env: Vec<f64> = alpha.iter().zip(&beta).map(|(a, b)| (a * a + b * b).sqrt()).collect();

    println!("PROGRESS 0.45 Estimating background activity");
    let r_delta = background_ratio(&delta, &nrem);
    let r_fast = background_ratio(&fast_env, &nrem);
    let r_sigma = background_ratio(&sigma, &nrem);
    let (ts, tf, pk) = thresholds(&opts.sensitivity);
    let slow: Vec<bool> = (0..n_sec).map(|t| r_delta[t] >= ts).collect();
    let fast: Vec<bool> = (0..n_sec).map(|t| r_fast[t] >= tf && r_fast[t] >= r_sigma[t]).collect();
    let strong: Vec<bool> = (0..n_sec).map(|t| r_delta[t] >= pk * ts || (fast[t] && r_fast[t] >= pk * tf)).collect();

    println!("PROGRESS 0.60 Detecting A-phases");
    let manual = manual_a_phases(&scoring_events);
    let use_manual = match opts.a_phase_source.as_str() {
        "manual" => true,
        "auto" => false,
        _ => manual.len() >= 10,
    };
    if opts.a_phase_source == "manual" && manual.is_empty() {
        bail!("No A1/A2/A3 markers found in the scoring file for manual CAP analysis.");
    }
    let arousals = if opts.arousal_mode == "none" { Vec::new() } else { manual_arousals(edf, &scoring_events) };
    let arousal_source = if arousals.is_empty() { "none" } else { "manual" };
    // (start s, end s, source, manual subtype)
    let mut merged: Vec<(usize, usize, String, Option<String>)> = Vec::new();
    if use_manual {
        let mut m = manual.clone();
        m.sort_by(|a, b| a.0.total_cmp(&b.0));
        for (s, e, sub) in m {
            merged.push((s.max(0.0) as usize, (e.ceil() as usize).min(n_sec), "manual".into(), Some(sub)));
        }
    } else {
        // Candidate seconds -> runs, bridging 1-s gaps (< 2 s between activations).
        let active: Vec<bool> = (0..n_sec).map(|t| nrem[t] && (slow[t] || fast[t])).collect();
        let mut runs: Vec<(usize, usize, String, Option<String>)> = Vec::new();
        let mut t = 0;
        while t < n_sec {
            if active[t] {
                let s = t;
                let mut e = t + 1;
                loop {
                    while e < n_sec && active[e] {
                        e += 1;
                    }
                    if e + 1 < n_sec && active[e + 1] && nrem[e] {
                        e += 1;
                        continue;
                    }
                    break;
                }
                if (s..e).any(|k| strong[k]) {
                    runs.push((s, e, "auto".into(), None));
                }
                t = e;
            } else {
                t += 1;
            }
        }
        // Scored arousals in NREM are A-phases (usually A2/A3).
        for a in &arousals {
            let s = a.start.max(0.0) as usize;
            let e = (a.end.ceil() as usize).min(n_sec);
            if e > s && s < n_sec && nrem[s] {
                runs.push((s, e, "arousal".into(), None));
            }
        }
        runs.sort_by_key(|r| r.0);
        for r in runs {
            if let Some(last) = merged.last_mut() {
                if r.0 < last.1 + 2 {
                    last.1 = last.1.max(r.1);
                    if r.2 == "arousal" {
                        last.2 = "arousal".into();
                    }
                    continue;
                }
            }
            merged.push(r);
        }
    }

    let resp = opts
        .respiratory_json
        .as_ref()
        .map(|p| read_json_spans(p, "events", &|e| e.get("counted").and_then(|c| c.as_bool()).unwrap_or(true)))
        .unwrap_or_default();
    let lms = opts
        .plm_json
        .as_ref()
        .map(|p| read_json_spans(p, "movements", &|e| e.get("clm").and_then(|c| c.as_bool()).unwrap_or(false)))
        .unwrap_or_default();
    if opts.respiratory_json.is_some() {
        channels.insert("respiratory_events".into(), format!("{} events", resp.len()));
    }
    if opts.plm_json.is_some() {
        channels.insert("leg_movements".into(), format!("{} candidate LMs", lms.len()));
    }

    let mut phases: Vec<APhase> = Vec::new();
    for (s, e, source, manual_sub) in merged {
        let dur = (e.saturating_sub(s)) as f64;
        if !(2.0..=60.0).contains(&dur) && manual_sub.is_none() {
            continue;
        }
        if dur <= 0.0 {
            continue;
        }
        let n_fast = (s..e).filter(|&k| fast[k]).count() as f64;
        let frac = n_fast / dur;
        let mut subtype = if frac < 0.2 {
            "A1"
        } else if frac <= 0.5 {
            "A2"
        } else {
            "A3"
        }
        .to_string();
        if source == "arousal" && subtype == "A1" {
            subtype = "A2".into();
        }
        if let Some(m) = manual_sub {
            subtype = m;
        }
        let subtype = subtype.as_str();
        let (a, b) = (s as f64, e as f64);
        phases.push(APhase {
            start: a,
            end: b,
            duration: dur,
            subtype: subtype.into(),
            stage: ctx.stage_label(a + 0.5).into(),
            desync_fraction: (frac * 1000.0).round() / 1000.0,
            in_sequence: false,
            arousal: arousals.iter().any(|x| x.start < b && a < x.end),
            respiratory: resp.iter().any(|(_, re)| a >= re - 5.0 && a <= re + 5.0),
            leg_movement: lms.iter().any(|(ls, _)| *ls >= a - 2.0 && *ls <= b),
            source,
        });
    }

    println!("PROGRESS 0.75 Building CAP cycles and sequences");
    let nrem_between = |a: f64, b: f64| -> bool {
        let (i, j) = (a.max(0.0) as usize, (b.ceil() as usize).min(n_sec));
        (i..j).all(|k| nrem[k])
    };
    let mut sequences: Vec<CapSequence> = Vec::new();
    let mut cycle_durs: Vec<f64> = Vec::new();
    let mut b_durs: Vec<f64> = Vec::new();
    let mut i = 0;
    while i < phases.len() {
        let mut j = i;
        while j + 1 < phases.len() {
            let b = phases[j + 1].start - phases[j].end;
            if (2.0..=60.0).contains(&b) && nrem_between(phases[j].end, phases[j + 1].start) {
                j += 1;
            } else {
                break;
            }
        }
        if j - i + 1 >= 3 {
            for k in i..=j {
                phases[k].in_sequence = true;
                if k < j {
                    let b = phases[k + 1].start - phases[k].end;
                    b_durs.push(b);
                    cycle_durs.push(phases[k].duration + b);
                }
            }
            let (s, e) = (phases[i].start, phases[j].end);
            sequences.push(CapSequence {
                start: s,
                end: e,
                duration: e - s,
                n_cycles: j - i,
                n_a: j - i + 1,
            });
        }
        i = j + 1;
    }

    println!("PROGRESS 0.90 Computing CAP parameters");
    let mut in_cap = vec![false; n_sec];
    for sq in &sequences {
        for k in (sq.start as usize)..(sq.end.ceil() as usize).min(n_sec) {
            in_cap[k] = true;
        }
    }
    let stage_of = |k: usize| ctx.stage_at(k as f64 + 0.5);
    let cap_time: f64 = (0..n_sec).filter(|&k| in_cap[k] && nrem[k]).count() as f64;
    let mut v: BTreeMap<String, f64> = BTreeMap::new();
    let per_h = |n: usize, secs: f64| if secs > 0.0 { n as f64 / (secs / 3600.0) } else { f64::NAN };
    let pct = |a: f64, b: f64| if b > 0.0 { 100.0 * a / b } else { f64::NAN };
    let mean_of = |x: &[f64]| if x.is_empty() { f64::NAN } else { mean(x) };
    v.insert("TST_min".into(), ctx.tst_sec() / 60.0);
    v.insert("NREM_min".into(), nrem_sec / 60.0);
    v.insert("CAP_time_min".into(), cap_time / 60.0);
    v.insert("NCAP_time_min".into(), (nrem_sec - cap_time) / 60.0);
    v.insert("CAP_rate".into(), pct(cap_time, nrem_sec));
    for (name, st) in [("N1", Stage::N1), ("N2", Stage::N2), ("N3", Stage::N3)] {
        let secs = (0..n_sec).filter(|&k| nrem[k] && stage_of(k) == st).count() as f64;
        let c = (0..n_sec).filter(|&k| nrem[k] && in_cap[k] && stage_of(k) == st).count() as f64;
        v.insert(format!("CAP_rate_{name}"), pct(c, secs));
        v.insert(format!("{name}_min"), secs / 60.0);
    }
    // First vs second half of the analysis window.
    let mid = 0.5 * (ctx.lights_off + ctx.lights_on);
    for (name, lo, hi) in [("first_half", 0.0, mid), ("second_half", mid, f64::INFINITY)] {
        let secs = (0..n_sec).filter(|&k| nrem[k] && (k as f64) >= lo && (k as f64) < hi).count() as f64;
        let c = (0..n_sec).filter(|&k| nrem[k] && in_cap[k] && (k as f64) >= lo && (k as f64) < hi).count() as f64;
        v.insert(format!("CAP_rate_{name}"), pct(c, secs));
    }
    let seq_durs: Vec<f64> = sequences.iter().map(|s| s.duration).collect();
    v.insert("n_CAP_sequences".into(), sequences.len() as f64);
    v.insert("CAP_sequence_duration_mean_s".into(), mean_of(&seq_durs));
    v.insert(
        "CAP_cycles_per_sequence_mean".into(),
        mean_of(&sequences.iter().map(|s| s.n_cycles as f64).collect::<Vec<_>>()),
    );
    v.insert("n_CAP_cycles".into(), cycle_durs.len() as f64);
    v.insert("CAP_cycle_duration_mean_s".into(), mean_of(&cycle_durs));
    let cycle_cv = if cycle_durs.len() > 1 {
        let m = mean(&cycle_durs);
        let sd = (cycle_durs.iter().map(|c| (c - m).powi(2)).sum::<f64>() / (cycle_durs.len() - 1) as f64).sqrt();
        sd / m
    } else {
        f64::NAN
    };
    v.insert("CAP_cycle_duration_cv".into(), cycle_cv);
    v.insert("B_phase_duration_mean_s".into(), mean_of(&b_durs));

    let in_seq: Vec<&APhase> = phases.iter().filter(|p| p.in_sequence).collect();
    let n_in = in_seq.len();
    v.insert("n_A_phases".into(), n_in as f64);
    v.insert("A_index".into(), per_h(n_in, nrem_sec));
    v.insert("A_phase_duration_mean_s".into(), mean_of(&in_seq.iter().map(|p| p.duration).collect::<Vec<_>>()));
    for st in ["A1", "A2", "A3"] {
        let sub: Vec<&&APhase> = in_seq.iter().filter(|p| p.subtype == st).collect();
        v.insert(format!("n_{st}"), sub.len() as f64);
        v.insert(format!("{st}_index"), per_h(sub.len(), nrem_sec));
        v.insert(format!("{st}_pct"), pct(sub.len() as f64, n_in as f64));
        v.insert(
            format!("{st}_duration_mean_s"),
            mean_of(&sub.iter().map(|p| p.duration).collect::<Vec<_>>()),
        );
    }
    let n_a23 = in_seq.iter().filter(|p| p.subtype != "A1").count();
    v.insert("A2A3_index".into(), per_h(n_a23, nrem_sec));
    let n_a1 = in_seq.iter().filter(|p| p.subtype == "A1").count();
    v.insert(
        "A1_to_A2A3_ratio".into(),
        if n_a23 > 0 { n_a1 as f64 / n_a23 as f64 } else { f64::NAN },
    );
    let isolated = phases.len() - n_in;
    v.insert("n_isolated_A_phases".into(), isolated as f64);
    v.insert("isolated_A_index".into(), per_h(isolated, nrem_sec));
    // A-A onset interval within sequences (the CAP "period").
    let mut aa: Vec<f64> = Vec::new();
    for w in phases.windows(2) {
        if w[0].in_sequence && w[1].in_sequence && w[1].start - w[0].end <= 60.0 {
            aa.push(w[1].start - w[0].start);
        }
    }
    v.insert("A_A_interval_median_s".into(), if aa.is_empty() { f64::NAN } else { median(&aa) });
    // Coupling with arousals, respiratory events and leg movements.
    let n_a23_arousal = in_seq.iter().filter(|p| p.subtype != "A1" && p.arousal).count();
    if !arousals.is_empty() {
        v.insert("A2A3_with_arousal_pct".into(), pct(n_a23_arousal as f64, n_a23 as f64));
        let nrem_arousals: Vec<&Arousal> = arousals.iter().filter(|a| nrem[(a.start.max(0.0) as usize).min(n_sec - 1)]).collect();
        let covered = nrem_arousals
            .iter()
            .filter(|a| phases.iter().any(|p| p.in_sequence && p.start < a.end && a.start < p.end))
            .count();
        v.insert("arousals_within_CAP_pct".into(), pct(covered as f64, nrem_arousals.len() as f64));
    }
    if opts.respiratory_json.is_some() {
        let n_r = in_seq.iter().filter(|p| p.respiratory).count();
        v.insert("A_phases_respiratory_pct".into(), pct(n_r as f64, n_in as f64));
        let nrem_resp: Vec<&(f64, f64)> = resp.iter().filter(|(_, e)| nrem[(e.max(0.0) as usize).min(n_sec - 1)]).collect();
        let followed = nrem_resp
            .iter()
            .filter(|(_, e)| phases.iter().any(|p| p.start >= e - 5.0 && p.start <= e + 5.0))
            .count();
        v.insert("respiratory_events_with_A_phase_pct".into(), pct(followed as f64, nrem_resp.len() as f64));
    }
    if opts.plm_json.is_some() {
        let n_l = in_seq.iter().filter(|p| p.leg_movement).count();
        v.insert("A_phases_with_LM_pct".into(), pct(n_l as f64, n_in as f64));
        let nrem_lm: Vec<&(f64, f64)> = lms.iter().filter(|(s, _)| nrem[(s.max(0.0) as usize).min(n_sec - 1)]).collect();
        let with_a = nrem_lm
            .iter()
            .filter(|(s, _)| phases.iter().any(|p| *s >= p.start - 2.0 && *s <= p.end))
            .count();
        v.insert("LMs_with_A_phase_pct".into(), pct(with_a as f64, nrem_lm.len() as f64));
    }

    // Hourly profile from lights off.
    let mut hourly = Vec::new();
    let mut h = 0usize;
    loop {
        let a = ctx.lights_off + h as f64 * 3600.0;
        if a >= ctx.lights_on {
            break;
        }
        let b = (a + 3600.0).min(ctx.lights_on);
        let (ia, ib) = (a as usize, (b as usize).min(n_sec));
        let secs = (ia..ib).filter(|&k| nrem[k]).count() as f64;
        let c = (ia..ib).filter(|&k| nrem[k] && in_cap[k]).count() as f64;
        let na = phases.iter().filter(|p| p.in_sequence && p.start >= a && p.start < b).count();
        let mut row = BTreeMap::new();
        row.insert("hour".to_string(), (h + 1) as f64);
        row.insert("NREM_min".to_string(), secs / 60.0);
        row.insert("CAP_rate".to_string(), pct(c, secs));
        row.insert("A_index".to_string(), per_h(na, secs));
        hourly.push(row);
        h += 1;
    }

    let mut flags = BTreeMap::new();
    flags.insert("arousal_source".into(), arousal_source.into());
    flags.insert(
        "method".into(),
        if use_manual {
            "manual A-phase markers, Terzano 2001 sequence rules"
        } else {
            "automatic A-phase detection (band descriptors, Terzano 2001 rules)"
        }
        .into(),
    );
    let rate = v.get("CAP_rate").copied().unwrap_or(f64::NAN);
    flags.insert(
        "CAP_rate_level".into(),
        if !rate.is_finite() {
            "unavailable"
        } else if rate < 20.0 {
            "low (< 20 %)"
        } else if rate <= 45.0 {
            "within the usual adult range (20-45 %)"
        } else {
            "elevated (> 45 %)"
        }
        .into(),
    );
    let mut settings = BTreeMap::new();
    settings.insert("sensitivity".into(), opts.sensitivity.clone());
    settings.insert("slow_ratio".into(), format!("{ts:.2}"));
    settings.insert("fast_ratio".into(), format!("{tf:.2}"));
    settings.insert("peak_factor".into(), format!("{pk:.2}"));
    settings.insert("a_phase_source".into(), if use_manual { "manual markers" } else { "automatic" }.into());
    settings.insert("arousals".into(), opts.arousal_mode.clone());
    if ctx.stages.iter().filter(|s| **s == Stage::N3).count() == 0 {
        warnings.push("No N3 in the hypnogram: CAP rate in N3 is unavailable.".into());
    }
    if !use_manual {
        warnings.push(
            "CAP A-phases were detected automatically; review A-phases and sequences against the EEG before clinical use.".into(),
        );
    }

    Ok(CapReport {
        analysis: "cap".into(),
        version: env!("CARGO_PKG_VERSION").into(),
        recording: edf.display().to_string(),
        scoring: opts.scoring.as_ref().map(|p| p.display().to_string()),
        channels,
        settings,
        has_hypnogram: ctx.has_hypnogram,
        summary: v
            .into_iter()
            .map(|(k, x)| (k, if x.is_finite() { (x * 1000.0).round() / 1000.0 } else { x }))
            .collect(),
        flags,
        hourly,
        a_phases: phases,
        sequences,
        warnings,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f64::consts::PI;

    /// Synthetic NREM EEG with 6-s delta bursts every 25 s.
    #[test]
    fn periodic_delta_bursts_are_detected() {
        let n = (1200.0 * FS) as usize;
        let mut seed = 12345u64;
        let mut rnd = || {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            ((seed >> 33) as f64 / (1u64 << 31) as f64) - 0.5
        };
        let mut x: Vec<f64> = (0..n).map(|_| 10.0 * rnd()).collect();
        for (i, v) in x.iter_mut().enumerate() {
            *v += 8.0 * (2.0 * PI * 1.5 * i as f64 / FS).sin();
        }
        let mut t0 = 200.0;
        while t0 < 900.0 {
            for i in (t0 * FS) as usize..((t0 + 6.0) * FS) as usize {
                x[i] += 60.0 * (2.0 * PI * i as f64 / FS).sin();
            }
            t0 += 25.0;
        }
        let n_sec = n / FS as usize;
        let delta = band_envelope(&x, 0.5, 4.0, n_sec);
        let r = background_ratio(&delta, &vec![true; n_sec]);
        let (ts, _, _) = thresholds("standard");
        let active = r.iter().filter(|v| **v >= ts).count();
        assert!(active > 120 && active < 260, "active seconds {active}");
    }

    #[test]
    fn manual_markers_are_recognised() {
        let ev = vec![
            (10.0, 14.0, "A1".to_string()),
            (12.0, 16.0, "CAP A2".to_string()),
            (20.0, 25.0, "MCAP-A3".to_string()),
            (30.0, 31.0, "Arousal".to_string()),
        ];
        let m = manual_a_phases(&ev);
        assert_eq!(m.len(), 2);
        assert_eq!(m[1].2, "A3");
    }
}
