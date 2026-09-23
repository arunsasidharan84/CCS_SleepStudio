//! Periodic limb movement analysis. Two scoring standards are available:
//!
//! **AASM Scoring Manual v3 (default, `standard = "aasm"`)**
//! * LM: tibialis EMG rise >= 8 µV above resting baseline (onset) until it
//!   stays <= 2 µV above baseline for >= 0.5 s (offset); 0.5-10 s long.
//! * LMs on both legs whose onsets are < 5 s apart count as one movement.
//! * LMs within 0.5 s before/after an apnea, hypopnea or RERA are excluded.
//! * PLM series: >= 4 consecutive LMs with onset-to-onset intervals of
//!   5-90 s (an LM < 5 s after the previous one is skipped, not a break).
//!
//! **WASM/IRLSSG 2016 (`standard = "wasm"`, Ferri et al., Sleep Med 2016)**
//! * Bilateral LMs: monolateral LMs overlapping or separated by < 0.5 s;
//!   candidate LMs (CLM) are monolateral 0.5-10 s or bilateral <= 15 s (and
//!   made of <= 4 monolateral LMs).
//! * Respiratory-related LMs (-2.0 s to +10.25 s around the end of an apnea /
//!   hypopnea / RERA) are not CLMs.
//! * PLM series: >= 4 consecutive CLMs with IMI of 10-90 s; an IMI < 10 s or
//!   > 90 s breaks the series.
//!
//! PLM-arousal association (both): arousal and PLM overlap or are separated by
//! < 0.5 s.
//!
//! Novel measures: periodicity index (Ferri 2006), IMI distribution, PLMS by
//! stage and by sleep hour, LM duration, bilateral fraction, series count.

use super::common::*;
use crate::edf::read_signal_infos;
use crate::hypnogram::Stage;
use anyhow::{bail, Result};
use serde::Serialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct PlmOptions {
    pub scoring: Option<PathBuf>,
    pub left: Option<String>,
    pub right: Option<String>,
    pub respiratory_json: Option<PathBuf>,
    pub eeg: Vec<String>,
    pub chin: Option<String>,
    pub auto_arousals: bool,
    /// "prefer-manual" (default), "manual", "auto" or "none"
    pub arousal_mode: String,
    pub onset_uv: f64,
    pub offset_uv: f64,
    /// "aasm" (AASM v3: 5-90 s periods, bilateral onsets < 5 s merged,
    /// respiratory window +-0.5 s) or "wasm" (WASM 2016: 10-90 s, bilateral
    /// gap < 0.5 s, respiratory window -2.0/+10.25 s)
    pub standard: String,
    pub lights_off: Option<f64>,
    pub lights_on: Option<f64>,
}

impl Default for PlmOptions {
    fn default() -> Self {
        Self {
            scoring: None,
            left: None,
            right: None,
            respiratory_json: None,
            eeg: Vec::new(),
            chin: None,
            auto_arousals: true,
            arousal_mode: "prefer-manual".into(),
            onset_uv: 8.0,
            offset_uv: 2.0,
            standard: "aasm".into(),
            lights_off: None,
            lights_on: None,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct LegMovement {
    pub start: f64,
    pub end: f64,
    pub duration: f64,
    /// "L", "R" or "B" (bilateral)
    pub side: String,
    pub peak_uv: f64,
    pub stage: String,
    /// candidate LM (eligible for PLM series)
    pub clm: bool,
    pub respiratory: bool,
    pub periodic: bool,
    pub series: Option<usize>,
    pub arousal: bool,
    /// onset-to-onset interval from the previous CLM (s)
    pub imi: Option<f64>,
    pub note: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct PlmReport {
    pub analysis: String,
    pub version: String,
    pub recording: String,
    pub scoring: Option<String>,
    pub channels: BTreeMap<String, String>,
    pub settings: BTreeMap<String, String>,
    pub has_hypnogram: bool,
    pub summary: BTreeMap<String, f64>,
    pub flags: BTreeMap<String, String>,
    pub imi_histogram: Vec<(String, f64)>,
    pub hourly: Vec<BTreeMap<String, f64>>,
    pub movements: Vec<LegMovement>,
    pub series: Vec<(f64, f64, usize)>,
    pub arousals: Vec<Arousal>,
    pub warnings: Vec<String>,
}

/// Monolateral LM detection on one tibialis channel. Returns (start, end, peak).
fn detect_leg(sig: &[f64], fs: f64, onset: f64, offset: f64) -> (Vec<(f64, f64, f64)>, f64) {
    let hi = (0.45 * fs).min(100.0);
    let lo = 10.0f64.min(hi * 0.5);
    let mut x = butter_filtfilt(sig, fs, Some(lo), Some(hi));
    for mains in [50.0, 60.0] {
        if mains < hi {
            x = notch_filtfilt(&x, fs, mains);
        }
    }
    // Rectified EMG, smoothed (200 ms) so single-sample spikes do not
    // trigger onsets; the AASM µV criteria are applied to this envelope.
    let rect: Vec<f64> = x.iter().map(|v| v.abs()).collect();
    let env = moving_average(&rect, ((0.2 * fs).round() as usize).max(1));
    // Resting baseline: 10th percentile of the envelope in sliding 60-s
    // blocks (median-smoothed), i.e. the noise floor between movements.
    let blk = (10.0 * fs) as usize;
    let nb = env.len().div_ceil(blk.max(1));
    let p10: Vec<f64> = (0..nb)
        .map(|b| percentile(&env[b * blk..((b + 1) * blk).min(env.len())], 10.0))
        .collect();
    let base_b: Vec<f64> = (0..nb).map(|b| median(&p10[b.saturating_sub(3)..(b + 4).min(nb)])).collect();
    let base = |i: usize| base_b[(i / blk).min(nb - 1)];
    let noise = median(&base_b);

    let min_off = (0.5 * fs) as usize;
    let mut out = Vec::new();
    let mut i = 0;
    let n = env.len();
    while i < n {
        if env[i] > base(i) + onset {
            let s = i;
            let mut peak = env[i];
            let mut below = 0usize;
            let mut j = i;
            while j < n {
                if env[j] <= base(j) + offset {
                    below += 1;
                    if below >= min_off {
                        break;
                    }
                } else {
                    below = 0;
                    peak = peak.max(env[j]);
                }
                j += 1;
            }
            let e = j.saturating_sub(below).max(s + 1);
            out.push((s as f64 / fs, e as f64 / fs, peak));
            i = j + 1;
        } else {
            i += 1;
        }
    }
    (out, noise)
}

fn read_resp_events(path: &Path) -> Vec<(f64, f64)> {
    let Ok(text) = std::fs::read_to_string(path) else { return Vec::new() };
    let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else { return Vec::new() };
    v.get("events")
        .and_then(|e| e.as_array())
        .map(|arr| {
            arr.iter()
                .filter(|e| e.get("counted").and_then(|c| c.as_bool()).unwrap_or(true))
                .filter_map(|e| Some((e.get("start")?.as_f64()?, e.get("end")?.as_f64()?)))
                .collect()
        })
        .unwrap_or_default()
}

fn per_hour(count: usize, seconds: f64) -> f64 {
    if seconds > 0.0 { count as f64 / (seconds / 3600.0) } else { f64::NAN }
}

pub fn analyse(edf: &Path, opts: &PlmOptions) -> Result<PlmReport> {
    println!("PROGRESS 0.05 Reading channel list");
    let infos = read_signal_infos(edf)?;
    let legs: Vec<String> = infos
        .iter()
        .filter(|i| guess_role(i) == Some("leg"))
        .map(|i| i.label.clone())
        .collect();
    let pick = |explicit: &Option<String>, want_left: bool| -> Option<String> {
        match explicit {
            Some(s) if s.trim() == "-" || s.trim().eq_ignore_ascii_case("none") => None,
            Some(s) if !s.trim().is_empty() => Some(s.trim().to_string()),
            _ => legs
                .iter()
                .find(|l| leg_side(l) == Some(want_left))
                .cloned()
                .or_else(|| if want_left { legs.first().cloned() } else { legs.get(1).cloned() }),
        }
    };
    let left_l = pick(&opts.left, true);
    let right_l = pick(&opts.right, false).filter(|r| Some(r) != left_l.as_ref());
    let mut warnings = Vec::new();
    let mut channels = BTreeMap::new();

    println!("PROGRESS 0.15 Loading tibialis EMG");
    let left = load_signal(edf, left_l.as_deref())?;
    let right = load_signal(edf, right_l.as_deref())?;
    if left.is_none() && right.is_none() {
        bail!("No leg (tibialis anterior) EMG channel found. Select the left/right leg channels explicitly.");
    }
    if left.is_none() || right.is_none() {
        warnings.push("Only one leg EMG channel available: bilateral LMs cannot be identified.".into());
    }
    for s in [&left, &right].into_iter().flatten() {
        if s.sfreq < 200.0 {
            warnings.push(format!(
                "{} is sampled at {} Hz; AASM recommends >= 200 Hz for leg EMG (band limited to {:.0} Hz).",
                s.label,
                s.sfreq,
                (0.45 * s.sfreq).min(100.0)
            ));
        }
    }
    let duration = left
        .as_ref()
        .map(|s| s.data.len() as f64 / s.sfreq)
        .or_else(|| right.as_ref().map(|s| s.data.len() as f64 / s.sfreq))
        .unwrap_or(0.0);
    let (stages, scoring_events) = match &opts.scoring {
        Some(p) if p.exists() => {
            let (s, e) = read_scoring(p)?;
            (Some(s), e)
        }
        _ => (None, Vec::new()),
    };
    let ctx = SleepContext::new(stages, duration, opts.lights_off, opts.lights_on);
    if !ctx.has_hypnogram {
        warnings.push("No sleep staging available: PLMS cannot be separated from PLMW; indices use monitoring time.".into());
    }

    println!("PROGRESS 0.30 Detecting leg movements");
    let mut mono: Vec<(f64, f64, f64, char)> = Vec::new();
    let mut noise = BTreeMap::new();
    for (side, s) in [('L', &left), ('R', &right)] {
        if let Some(s) = s {
            let (lms, nf) = detect_leg(&s.data, s.sfreq, opts.onset_uv, opts.offset_uv);
            channels.insert(if side == 'L' { "left_leg".to_string() } else { "right_leg".to_string() }, s.label.clone());
            noise.insert(side, nf);
            if nf > 10.0 {
                warnings.push(format!(
                    "{}: high resting EMG noise ({nf:.1} µV); consider checking electrode impedance.",
                    s.label
                ));
            }
            for (a, b, p) in lms {
                mono.push((a, b, p, side));
            }
        }
    }
    mono.sort_by(|a, b| a.0.total_cmp(&b.0));

    // Combine monolateral LMs into bilateral LMs (overlap or gap < 0.5 s).
    struct Group {
        start: f64,
        end: f64,
        peak: f64,
        sides: Vec<char>,
        parts: Vec<(f64, f64)>,
    }
    let wasm = opts.standard.eq_ignore_ascii_case("wasm");
    let mut groups: Vec<Group> = Vec::new();
    for (a, b, p, side) in mono {
        if let Some(g) = groups.last_mut() {
            let join = if wasm {
                a - g.end < 0.5 && !(g.sides.len() == 1 && g.sides[0] == side && a > g.end)
            } else {
                // AASM: LMs on different legs with onsets < 5 s apart are one movement
                a <= g.end || (!g.sides.contains(&side) && a - g.start < 5.0)
            };
            if join {
                g.end = g.end.max(b);
                g.peak = g.peak.max(p);
                g.sides.push(side);
                g.parts.push((a, b));
                continue;
            }
        }
        groups.push(Group {
            start: a,
            end: b,
            peak: p,
            sides: vec![side],
            parts: vec![(a, b)],
        });
    }

    println!("PROGRESS 0.50 Loading respiratory events and arousals");
    let resp_events = opts.respiratory_json.as_ref().map(|p| read_resp_events(p)).unwrap_or_default();
    if opts.respiratory_json.is_some() {
        channels.insert("respiratory_events".into(), format!("{} events", resp_events.len()));
    } else {
        warnings.push("No respiratory analysis supplied: respiratory-related LMs were not excluded.".into());
    }
    let force_auto = opts.arousal_mode == "auto";
    let mut arousals = if force_auto || opts.arousal_mode == "none" { Vec::new() } else { manual_arousals(edf, &scoring_events) };
    let mut arousal_source = if arousals.is_empty() { "none".to_string() } else { "manual".to_string() };
    if arousals.is_empty() && (opts.auto_arousals || force_auto) && opts.arousal_mode != "manual" && opts.arousal_mode != "none" && ctx.has_hypnogram {
        if let Some((eeg, efs, label)) = load_arousal_eeg(edf, &infos, &opts.eeg)? {
            let chin_l = opts.chin.clone().or_else(|| {
                infos.iter().find(|i| guess_role(i) == Some("chin")).map(|i| i.label.clone())
            });
            let chin = load_signal(edf, chin_l.as_deref())?;
            arousals = detect_arousals(&eeg, efs, chin.as_ref().map(|c| (c.data.as_slice(), c.sfreq)), &ctx);
            arousal_source = format!("auto ({label})");
        }
    }

    println!("PROGRESS 0.65 Building candidate LMs and PLM series");
    let mut movements: Vec<LegMovement> = groups
        .iter()
        .map(|g| {
            let dur = g.end - g.start;
            let bilateral = g.sides.contains(&'L') && g.sides.contains(&'R');
            let side = if bilateral { "B" } else if g.sides[0] == 'L' { "L" } else { "R" };
            let mut note = String::new();
            let mut clm = true;
            // monolateral components must each be 0.5-10 s
            let comp_ok = g.parts.iter().all(|(a, b)| (0.5..=10.0).contains(&(b - a)));
            if bilateral && !wasm {
                if dur < 0.5 || dur > 10.0 {
                    clm = false;
                    note = "duration outside 0.5-10 s".into();
                }
            } else if bilateral {
                if dur > 15.0 {
                    clm = false;
                    note = "bilateral > 15 s".into();
                } else if g.parts.len() > 4 {
                    clm = false;
                    note = "> 4 monolateral components".into();
                }
            } else if dur < 0.5 {
                clm = false;
                note = "< 0.5 s".into();
            } else if dur > 10.0 {
                clm = false;
                note = "> 10 s".into();
            }
            if clm && !comp_ok && !bilateral {
                clm = false;
            }
            let respiratory = if wasm {
                resp_events.iter().any(|(_, re)| g.end >= re - 2.0 && g.start <= re + 10.25)
            } else {
                // AASM: LM within 0.5 s before/after a respiratory event
                resp_events.iter().any(|(rs, re)| g.start <= re + 0.5 && g.end >= rs - 0.5)
            };
            if clm && respiratory {
                clm = false;
                note = "respiratory-related".into();
            }
            LegMovement {
                start: (g.start * 1000.0).round() / 1000.0,
                end: (g.end * 1000.0).round() / 1000.0,
                duration: (dur * 1000.0).round() / 1000.0,
                side: side.into(),
                peak_uv: (g.peak * 10.0).round() / 10.0,
                stage: ctx.stage_label(g.start).into(),
                clm,
                respiratory,
                periodic: false,
                series: None,
                arousal: arousals.iter().any(|a| a.start <= g.end + 0.5 && a.end >= g.start - 0.5),
                imi: None,
                note,
            }
        })
        .collect();

    // PLM series over CLMs. Non-CLM LMs >= 0.5 s interrupt a series (WASM:
    // an LM that is not a CLM breaks periodicity; short (< 0.5 s) activity
    // does not).
    let mut series: Vec<(f64, f64, usize)> = Vec::new();
    {
        let mut prev_clm: Option<usize> = None;
        let mut run: Vec<usize> = Vec::new();
        let flush = |run: &mut Vec<usize>, movements: &mut Vec<LegMovement>, series: &mut Vec<(f64, f64, usize)>| {
            if run.len() >= 4 {
                let id = series.len();
                for &k in run.iter() {
                    movements[k].periodic = true;
                    movements[k].series = Some(id);
                }
                series.push((movements[run[0]].start, movements[*run.last().unwrap()].end, run.len()));
            }
            run.clear();
        };
        for k in 0..movements.len() {
            if !movements[k].clm {
                if movements[k].duration >= 0.5 {
                    flush(&mut run, &mut movements, &mut series);
                    prev_clm = None;
                }
                continue;
            }
            let min_period = if wasm { 10.0 } else { 5.0 };
            if let Some(p) = prev_clm {
                let imi = movements[k].start - movements[p].start;
                movements[k].imi = Some((imi * 100.0).round() / 100.0);
                if !wasm && imi < min_period {
                    // AASM: an LM closer than 5 s to the previous one is not
                    // part of the series but does not break it.
                    continue;
                }
                if (min_period..=90.0).contains(&imi) {
                    if run.is_empty() {
                        run.push(p);
                    }
                    run.push(k);
                } else {
                    flush(&mut run, &mut movements, &mut series);
                }
            }
            prev_clm = Some(k);
        }
        flush(&mut run, &mut movements, &mut series);
    }

    println!("PROGRESS 0.85 Computing indices");
    let tst = ctx.tst_sec();
    let wake_s = ctx.waso_sec();
    let in_win: Vec<&LegMovement> = movements.iter().filter(|m| ctx.in_window(m.start)).collect();
    let sleep_m: Vec<&LegMovement> = in_win.iter().copied().filter(|m| ctx.is_sleep(m.start)).collect();
    let wake_m: Vec<&LegMovement> = in_win.iter().copied().filter(|m| ctx.is_wake(m.start)).collect();
    let lm_valid = |m: &&LegMovement| m.duration >= 0.5;
    let mut v = BTreeMap::new();
    v.insert("TST_min".to_string(), tst / 60.0);
    v.insert("WASO_min".to_string(), wake_s / 60.0);
    let n_lm = sleep_m.iter().filter(|m| lm_valid(m)).count();
    let n_clm = sleep_m.iter().filter(|m| m.clm).count();
    let n_plms = sleep_m.iter().filter(|m| m.periodic).count();
    let n_plmw = wake_m.iter().filter(|m| m.periodic).count();
    let n_resp = sleep_m.iter().filter(|m| m.respiratory).count();
    let n_plms_ar = sleep_m.iter().filter(|m| m.periodic && m.arousal).count();
    let n_lm_ar = sleep_m.iter().filter(|m| lm_valid(m) && m.arousal).count();
    v.insert("n_LM_sleep".into(), n_lm as f64);
    v.insert("n_CLM_sleep".into(), n_clm as f64);
    v.insert("n_PLMS".into(), n_plms as f64);
    v.insert("n_PLMW".into(), n_plmw as f64);
    v.insert("n_PLM_total".into(), in_win.iter().filter(|m| m.periodic).count() as f64);
    v.insert("n_LM_total".into(), in_win.iter().filter(|m| lm_valid(m)).count() as f64);
    v.insert("n_respiratory_LM".into(), n_resp as f64);
    v.insert("LM_index".into(), per_hour(n_lm, tst));
    v.insert("CLM_index".into(), per_hour(n_clm, tst));
    v.insert("PLMS_index".into(), per_hour(n_plms, tst));
    v.insert("PLMW_index".into(), per_hour(n_plmw, wake_s));
    v.insert("PLMS_arousal_index".into(), per_hour(n_plms_ar, tst));
    v.insert("LM_arousal_index".into(), per_hour(n_lm_ar, tst));
    v.insert("respiratory_LM_index".into(), per_hour(n_resp, tst));
    v.insert("isolated_LM_index".into(), per_hour(sleep_m.iter().filter(|m| m.clm && !m.periodic).count(), tst));
    if ctx.has_hypnogram {
        for (st, name) in [(Stage::N1, "N1"), (Stage::N2, "N2"), (Stage::N3, "N3"), (Stage::Rem, "REM")] {
            let secs = ctx.stage_sec(st);
            let c = sleep_m.iter().filter(|m| m.periodic && ctx.stage_at(m.start) == st).count();
            v.insert(format!("PLMS_index_{name}"), per_hour(c, secs));
        }
        let rem = ctx.stage_sec(Stage::Rem);
        let c_rem = sleep_m.iter().filter(|m| m.periodic && ctx.is_rem(m.start)).count();
        v.insert("PLMS_index_NREM".into(), per_hour(n_plms - c_rem, tst - rem));
        v.insert("PLMS_pct_in_REM".into(), if n_plms > 0 { 100.0 * c_rem as f64 / n_plms as f64 } else { f64::NAN });
    }
    let plm_d: Vec<f64> = sleep_m.iter().filter(|m| m.periodic).map(|m| m.duration).collect();
    v.insert("PLM_duration_mean_s".into(), mean(&plm_d));
    let lm_d: Vec<f64> = sleep_m.iter().filter(|m| lm_valid(m)).map(|m| m.duration).collect();
    v.insert("LM_duration_mean_s".into(), mean(&lm_d));
    let imis: Vec<f64> = sleep_m.iter().filter_map(|m| m.imi).collect();
    let plm_imis: Vec<f64> = sleep_m.iter().filter(|m| m.periodic).filter_map(|m| m.imi).filter(|i| (10.0..=90.0).contains(i)).collect();
    v.insert("IMI_median_s".into(), median(&imis));
    v.insert("PLM_IMI_mean_s".into(), mean(&plm_imis));
    let bil = sleep_m.iter().filter(|m| m.clm && m.side == "B").count();
    v.insert("bilateral_CLM_pct".into(), if n_clm > 0 { 100.0 * bil as f64 / n_clm as f64 } else { f64::NAN });
    let sleep_series: Vec<&(f64, f64, usize)> = series.iter().filter(|s| ctx.is_sleep(s.0)).collect();
    v.insert("n_PLM_series_sleep".into(), sleep_series.len() as f64);
    v.insert("PLM_series_length_mean".into(), mean(&sleep_series.iter().map(|s| s.2 as f64).collect::<Vec<_>>()));
    // Periodicity index (Ferri 2006): IMIs in [10, 90] s that belong to runs
    // of >= 3 consecutive such IMIs, divided by all IMIs (sleep CLMs).
    {
        let seq: Vec<f64> = sleep_m.iter().filter(|m| m.clm).filter_map(|m| m.imi).collect();
        let mut periodic = 0usize;
        let mut run = 0usize;
        for x in seq.iter() {
            if (10.0..=90.0).contains(x) {
                run += 1;
            } else {
                if run >= 3 {
                    periodic += run;
                }
                run = 0;
            }
        }
        if run >= 3 {
            periodic += run;
        }
        v.insert("periodicity_index".into(), if seq.is_empty() { f64::NAN } else { periodic as f64 / seq.len() as f64 });
    }
    if let Some(nl) = noise.get(&'L') {
        v.insert("resting_EMG_left_uV".into(), *nl);
    }
    if let Some(nr) = noise.get(&'R') {
        v.insert("resting_EMG_right_uV".into(), *nr);
    }

    // IMI histogram (sleep CLMs), log-like bins as in Ferri's plots.
    let bins = [(0.0, 2.0), (2.0, 4.0), (4.0, 10.0), (10.0, 20.0), (20.0, 30.0), (30.0, 40.0), (40.0, 60.0), (60.0, 90.0), (90.0, f64::INFINITY)];
    let imi_histogram: Vec<(String, f64)> = bins
        .iter()
        .map(|(a, b)| {
            let label = if b.is_finite() { format!("{a:.0}-{b:.0} s") } else { format!(">{a:.0} s") };
            let c = imis.iter().filter(|x| **x >= *a && **x < *b).count();
            (label, c as f64)
        })
        .collect();

    // Hourly distribution (PLMS per hour of sleep).
    let mut hourly = Vec::new();
    for h in 0..(duration / 3600.0).ceil() as usize {
        let (a, b) = (h as f64 * 3600.0, ((h + 1) as f64 * 3600.0).min(duration));
        let sleep_s = (a as usize..b as usize).filter(|&t| ctx.is_sleep(t as f64)).count() as f64;
        let c = sleep_m.iter().filter(|m| m.periodic && m.start >= a && m.start < b).count();
        let cw = wake_m.iter().filter(|m| m.periodic && m.start >= a && m.start < b).count();
        let mut row = BTreeMap::new();
        row.insert("hour".to_string(), (h + 1) as f64);
        row.insert("sleep_min".to_string(), sleep_s / 60.0);
        row.insert("PLMS".to_string(), c as f64);
        row.insert("PLMW".to_string(), cw as f64);
        row.insert("PLMS_index".to_string(), per_hour(c, sleep_s));
        hourly.push(row);
    }

    let mut flags = BTreeMap::new();
    let plmsi = v["PLMS_index"];
    let severity = if !plmsi.is_finite() {
        "n/a"
    } else if plmsi < 15.0 {
        "normal (< 15/h)"
    } else if plmsi < 25.0 {
        "mild (15-25/h)"
    } else if plmsi < 50.0 {
        "moderate (25-50/h)"
    } else {
        "severe (>= 50/h)"
    };
    flags.insert("PLMS_severity".to_string(), severity.to_string());
    flags.insert("arousal_source".to_string(), arousal_source.clone());
    flags.insert(
        "respiratory_exclusion".to_string(),
        if wasm { "WASM 2016 (-2.0 s to +10.25 s around event end)" } else { "AASM (within 0.5 s of a respiratory event)" }.to_string(),
    );
    flags.insert("index_denominator".into(), if ctx.has_hypnogram { "total sleep time" } else { "monitoring time (no staging)" }.into());

    let mut settings = BTreeMap::new();
    settings.insert("onset_uV".to_string(), format!("{:.1}", opts.onset_uv));
    settings.insert("offset_uV".to_string(), format!("{:.1}", opts.offset_uv));
    settings.insert(
        "standard".to_string(),
        if wasm { "WASM/IRLSSG 2016".to_string() } else { "AASM v3 (2023)".to_string() },
    );

    let summary: BTreeMap<String, f64> = v
        .into_iter()
        .filter(|(_, x)| x.is_finite())
        .map(|(k, x)| (k, (x * 1000.0).round() / 1000.0))
        .collect();
    let arousals_out = if arousal_source.starts_with("auto") { arousals } else { Vec::new() };

    Ok(PlmReport {
        analysis: "plm".into(),
        version: env!("CARGO_PKG_VERSION").into(),
        recording: edf.display().to_string(),
        scoring: opts.scoring.as_ref().map(|p| p.display().to_string()),
        channels,
        settings,
        has_hypnogram: ctx.has_hypnogram,
        summary,
        flags,
        imi_histogram,
        hourly,
        movements,
        series,
        arousals: arousals_out,
        warnings,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_synthetic_leg_bursts() {
        let fs = 256.0;
        let secs = 300.0;
        let mut x: Vec<f64> = (0..(fs * secs) as usize)
            .map(|i| ((i * 7919 % 101) as f64 / 101.0 - 0.5) * 2.0) // ~1 µV noise
            .collect();
        // bursts of 40 µV, 1.5 s long, every 25 s
        for k in 0..10 {
            let s = ((10.0 + 25.0 * k as f64) * fs) as usize;
            for i in s..s + (1.5 * fs) as usize {
                x[i] += 40.0 * (2.0 * std::f64::consts::PI * 40.0 * i as f64 / fs).sin();
            }
        }
        let (lms, _) = detect_leg(&x, fs, 8.0, 2.0);
        assert_eq!(lms.len(), 10, "{lms:?}");
        for (a, b, _) in &lms {
            assert!((b - a - 1.5).abs() < 0.4, "duration {}", b - a);
        }
    }
}
