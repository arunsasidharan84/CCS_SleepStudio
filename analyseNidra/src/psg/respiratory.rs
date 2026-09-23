//! Sleep-disordered breathing analysis following the AASM Manual for the
//! Scoring of Sleep and Associated Events (v3, 2023):
//!
//! * Apnea: >= 90 % drop of the peak signal excursion (oronasal thermal
//!   sensor, or nasal pressure / RIPsum as alternative sensors) versus the
//!   pre-event baseline for >= 10 s. Obstructive / central / mixed from
//!   thoraco-abdominal effort.
//! * Hypopnea: >= 30 % drop (nasal pressure, or thermal / RIPsum) for >= 10 s
//!   with >= 3 % desaturation or an arousal (recommended rule 1A) — the 4 %
//!   rule (1B / CMS) is always reported alongside.
//! * RERA, oxygen desaturation index (3 % / 4 %), Cheyne-Stokes breathing,
//!   positional and REM-related indices, hypoxic burden (Azarbarzin 2019),
//!   event-related pulse-rate response ΔHR (Azarbarzin 2021) and ventilatory
//!   burden.
//!
//! Breath amplitudes are measured breath-by-breath (hysteresis zero-crossing
//! segmentation of the band-passed airflow), and each breath is compared with
//! the 75th percentile of the preceding 120 s of breaths (the "stable
//! breathing" baseline of the AASM definition, robust to preceding events).

use super::common::*;
use crate::edf::{read_signal_infos, SignalInfo};
use crate::hypnogram::Stage;
use anyhow::{bail, Result};
use serde::Serialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

const FLOW_FS: f64 = 25.0;

#[derive(Debug, Clone, Default)]
pub struct RespOptions {
    pub scoring: Option<PathBuf>,
    pub thermal: Option<String>,
    pub pressure: Option<String>,
    pub flow: Option<String>,
    pub thorax: Option<String>,
    pub abdomen: Option<String>,
    pub effort_sum: Option<String>,
    pub spo2: Option<String>,
    pub pulse: Option<String>,
    pub ecg: Option<String>,
    pub snore: Option<String>,
    pub position: Option<String>,
    pub eeg: Vec<String>,
    pub chin: Option<String>,
    pub supine_codes: Vec<f64>,
    /// 3 = AASM recommended rule 1A (>=3 % or arousal), 4 = rule 1B (>=4 %)
    pub hypopnea_rule: u8,
    pub auto_arousals: bool,
    /// "prefer-manual" (default), "manual", "auto" or "none"
    pub arousal_mode: String,
    pub apnea_threshold: f64,
    pub hypopnea_threshold: f64,
    pub lights_off: Option<f64>,
    pub lights_on: Option<f64>,
}

impl RespOptions {
    pub fn defaults() -> Self {
        Self {
            hypopnea_rule: 3,
            auto_arousals: true,
            arousal_mode: "prefer-manual".into(),
            apnea_threshold: 0.10,
            hypopnea_threshold: 0.70,
            ..Default::default()
        }
    }
}

// ───────────────────────────── breath segmentation ─────────────────────────────

#[derive(Debug, Clone, Copy)]
struct Cycle {
    a: usize,
    b: usize,
    amp: f64,
}

/// Breath cycles by hysteresis zero-crossing on a band-passed signal.
/// Trailing quiet parts (no excursion beyond the hysteresis band for >= 2 s)
/// are split into their own "no-breath" segment so an apnea is not merged
/// with the last breath before it.
fn breath_cycles(x: &[f64], fs: f64, hyst: f64) -> Vec<Cycle> {
    let n = x.len();
    if n < (fs * 10.0) as usize {
        return Vec::new();
    }
    // local scale: median over +-60 s of 10-s block 90th percentiles of |x|
    let blk = (10.0 * fs) as usize;
    let nb = n.div_ceil(blk);
    let p90: Vec<f64> = (0..nb)
        .map(|i| {
            let seg: Vec<f64> = x[i * blk..((i + 1) * blk).min(n)].iter().map(|v| v.abs()).collect();
            percentile(&seg, 90.0)
        })
        .collect();
    let scale_b: Vec<f64> = (0..nb)
        .map(|i| median(&p90[i.saturating_sub(6)..(i + 7).min(nb)]))
        .collect();
    let h = |i: usize| hyst * scale_b[(i / blk).min(nb - 1)];

    let mut starts = Vec::new();
    let mut state = 0i8;
    for (i, &v) in x.iter().enumerate() {
        let hi = h(i);
        if state <= 0 && v > hi {
            if state < 0 {
                // breath onset = the zero crossing preceding the hysteresis crossing
                let mut z = i;
                let floor = starts.last().copied().unwrap_or(0);
                while z > floor + 1 && x[z - 1] > 0.0 {
                    z -= 1;
                }
                starts.push(z);
            }
            state = 1;
        } else if state >= 0 && v < -hi {
            state = -1;
        }
    }
    let mut bounds = Vec::with_capacity(starts.len() + 1);
    let mut prev = 0usize;
    for s in starts {
        if s > prev {
            bounds.push((prev, s));
        }
        prev = s;
    }
    if prev < n {
        bounds.push((prev, n));
    }
    let quiet_min = (2.0 * fs) as usize;
    let amp = |a: usize, b: usize| {
        let seg = &x[a..b];
        // Long no-breath segments: robust excursion (2nd-98th percentile) so
        // filter transients at the edges do not mask an apnea.
        if (b - a) as f64 > 5.0 * fs {
            return percentile(seg, 98.0) - percentile(seg, 2.0);
        }
        let mx = seg.iter().copied().fold(f64::NEG_INFINITY, f64::max);
        let mn = seg.iter().copied().fold(f64::INFINITY, f64::min);
        mx - mn
    };
    let mut out = Vec::with_capacity(bounds.len() + 16);
    for (a, b) in bounds {
        let last = (a..b).rev().find(|&i| x[i].abs() >= h(i)).map(|i| i + 1 - a).unwrap_or(0);
        if last > 0 && b - (a + last) >= quiet_min {
            let mut cut = a + last;
            let sign = x[cut - 1].signum();
            while cut < b - quiet_min && x[cut].signum() == sign {
                cut += 1;
            }
            out.push(Cycle { a, b: cut, amp: amp(a, cut) });
            out.push(Cycle { a: cut, b, amp: amp(cut, b) });
        } else {
            out.push(Cycle { a, b, amp: amp(a, b) });
        }
    }
    out
}

/// Pre-event baseline for each cycle: 75th percentile of breath amplitudes
/// (cycles <= 10 s) in the preceding 120 s (widened when too few breaths).
fn cycle_baselines(cycles: &[Cycle], fs: f64) -> Vec<f64> {
    let global: Vec<f64> = cycles
        .iter()
        .filter(|c| (c.b - c.a) as f64 / fs <= 10.0)
        .map(|c| c.amp)
        .collect();
    let global_med = median(&global);
    let mut out = Vec::with_capacity(cycles.len());
    let mut lo_idx = 0usize;
    for (i, c) in cycles.iter().enumerate() {
        let win_start = c.a as f64 - 120.0 * fs;
        while lo_idx < i && (cycles[lo_idx].a as f64) < win_start {
            lo_idx += 1;
        }
        let mut amps: Vec<f64> = cycles[lo_idx..i]
            .iter()
            .filter(|p| (p.b - p.a) as f64 / fs <= 10.0)
            .map(|p| p.amp)
            .collect();
        if amps.len() < 5 {
            let wide = c.a as f64 - 300.0 * fs;
            amps = cycles[..i]
                .iter()
                .rev()
                .take_while(|p| p.a as f64 >= wide)
                .filter(|p| (p.b - p.a) as f64 / fs <= 10.0)
                .map(|p| p.amp)
                .collect();
        }
        if amps.len() < 3 {
            // start of recording: look forward instead
            amps = cycles[i..]
                .iter()
                .take_while(|p| (p.a as f64) < c.a as f64 + 120.0 * fs)
                .filter(|p| (p.b - p.a) as f64 / fs <= 10.0)
                .map(|p| p.amp)
                .collect();
        }
        let b = if amps.len() >= 3 { percentile(&amps, 75.0) } else { global_med };
        out.push(if b.is_finite() && b > 0.0 { b } else { global_med.max(1e-9) });
    }
    out
}

struct FlowAnalysis {
    cycles: Vec<Cycle>,
    ratio: Vec<f64>,
    /// per-second amplitude ratio (for plots / ventilatory burden)
    ratio_1hz: Vec<f64>,
    /// per-second validity (sensor present and not flat)
    valid_1hz: Vec<bool>,
}

fn analyse_flow(signal: &[f64], fs: f64) -> FlowAnalysis {
    let x = resample_linear(signal, fs, FLOW_FS);
    let x = butter_filtfilt(&x, FLOW_FS, Some(0.05), Some(1.0));
    let cycles = breath_cycles(&x, FLOW_FS, 0.15);
    let base = cycle_baselines(&cycles, FLOW_FS);
    let ratio: Vec<f64> = cycles.iter().zip(&base).map(|(c, b)| c.amp / b).collect();
    let n_sec = (x.len() as f64 / FLOW_FS) as usize;
    let mut ratio_1hz = vec![1.0; n_sec];
    for (c, r) in cycles.iter().zip(&ratio) {
        let a = (c.a as f64 / FLOW_FS) as usize;
        let b = ((c.b as f64 / FLOW_FS).ceil() as usize).min(n_sec);
        for v in ratio_1hz.iter_mut().take(b).skip(a) {
            *v = r.min(2.0);
        }
    }
    // Sensor validity: baselines collapsing to the noise floor or long flat
    // stretches mark disconnected / failed sensors.
    let med_base = median(&base);
    let mut valid_1hz = vec![true; n_sec];
    for (c, b) in cycles.iter().zip(&base) {
        if *b < 0.05 * med_base {
            let a = (c.a as f64 / FLOW_FS) as usize;
            let e = ((c.b as f64 / FLOW_FS).ceil() as usize).min(n_sec);
            for v in valid_1hz.iter_mut().take(e).skip(a) {
                *v = false;
            }
        }
    }
    let win = (120.0 * FLOW_FS) as usize;
    let mut i = 0;
    while i + win <= x.len() {
        let seg = &x[i..i + win];
        let mx = seg.iter().copied().fold(f64::NEG_INFINITY, f64::max);
        let mn = seg.iter().copied().fold(f64::INFINITY, f64::min);
        if mx - mn < 1e-6 * med_base.max(1e-9) || mx - mn <= 0.0 {
            let a = i / FLOW_FS as usize;
            for v in valid_1hz.iter_mut().skip(a).take(120) {
                *v = false;
            }
        }
        i += win / 2;
    }
    // Displaced / near-noise sensors: the signal is present but its excursions
    // collapse far below the night's typical breathing amplitude for minutes.
    // Local baselines follow the collapse (so ratios look normal), therefore
    // judge 60-s window amplitudes against the whole-night distribution.
    let w60 = (60.0 * FLOW_FS) as usize;
    if x.len() >= 10 * w60 {
        let amps: Vec<f64> = x
            .chunks(w60)
            .filter(|c| c.len() == w60)
            .map(|c| {
                let abs: Vec<f64> = c.iter().map(|v| v.abs()).collect();
                percentile(&abs, 90.0)
            })
            .collect();
        let ref_amp = percentile(&amps, 75.0);
        if ref_amp.is_finite() && ref_amp > 0.0 {
            // Require two consecutive low windows so that a single long
            // central apnea is never mistaken for sensor failure.
            let low: Vec<bool> = amps.iter().map(|a| *a < 0.1 * ref_amp).collect();
            for k in 0..low.len() {
                let run = low[k] && ((k > 0 && low[k - 1]) || (k + 1 < low.len() && low[k + 1]));
                if run {
                    for v in valid_1hz.iter_mut().skip(k * 60).take(60) {
                        *v = false;
                    }
                }
            }
        }
    }
    FlowAnalysis {
        cycles,
        ratio,
        ratio_1hz,
        valid_1hz,
    }
}

#[derive(Debug, Clone)]
struct Reduction {
    start: f64,
    end: f64,
    min_ratio: f64,
    /// longest run meeting the apnea criterion (s)
    apnea_run: f64,
    apnea_start: f64,
    apnea_end: f64,
}

/// Runs of consecutive breaths below `thr` lasting >= 10 s; within each the
/// longest apnea-level run (<= `apnea_thr`) is measured, bridging isolated
/// breaths shorter than 3 s that stay below 2x the apnea threshold.
fn reductions(fa: &FlowAnalysis, thr: f64, apnea_thr: f64) -> Vec<Reduction> {
    let c = &fa.cycles;
    let r = &fa.ratio;
    let n = c.len();
    let sec = |i: usize| i as f64 / FLOW_FS;
    let mut out = Vec::new();
    let mut i = 0;
    while i < n {
        if r[i] <= thr {
            let mut j = i;
            while j + 1 < n && r[j + 1] <= thr {
                j += 1;
            }
            let start = sec(c[i].a);
            let end = sec(c[j].b);
            if end - start >= 10.0 {
                let mut best = 0.0;
                let (mut bs, mut be) = (start, start);
                let mut k = i;
                while k <= j {
                    if r[k] <= apnea_thr {
                        let mut m = k;
                        loop {
                            if m < j && r[m + 1] <= apnea_thr {
                                m += 1;
                            } else if m + 2 <= j
                                && r[m + 1] <= apnea_thr * 2.0
                                && sec(c[m + 1].b) - sec(c[m + 1].a) < 3.0
                                && r[m + 2] <= apnea_thr
                            {
                                m += 2;
                            } else {
                                break;
                            }
                        }
                        let d = sec(c[m].b) - sec(c[k].a);
                        if d > best {
                            best = d;
                            bs = sec(c[k].a);
                            be = sec(c[m].b);
                        }
                        k = m + 1;
                    } else {
                        k += 1;
                    }
                }
                let min_ratio = r[i..=j].iter().copied().fold(f64::INFINITY, f64::min);
                out.push(Reduction {
                    start,
                    end,
                    min_ratio,
                    apnea_run: best,
                    apnea_start: bs,
                    apnea_end: be,
                });
            }
            i = j + 1;
        } else {
            i += 1;
        }
    }
    out
}

// ───────────────────────────── SpO2 / pulse ─────────────────────────────

/// SpO2 at 1 Hz with artefact removal (out-of-range values, > 4 %/s jumps)
/// and linear interpolation of gaps up to 10 s.
fn clean_spo2(sig: &[f64], fs: f64) -> Vec<f64> {
    let n = (sig.len() as f64 / fs) as usize;
    let mut s: Vec<f64> = (0..n)
        .map(|i| {
            let a = (i as f64 * fs) as usize;
            let b = (((i + 1) as f64 * fs) as usize).min(sig.len()).max(a + 1);
            median(&sig[a..b])
        })
        .collect();
    for v in s.iter_mut() {
        if !(50.0..=100.5).contains(v) {
            *v = f64::NAN;
        }
    }
    let mut prev = f64::NAN;
    for v in s.iter_mut() {
        if v.is_finite() && prev.is_finite() && (*v - prev).abs() > 4.0 {
            let keep = *v;
            *v = f64::NAN;
            prev = keep;
        } else if v.is_finite() {
            prev = *v;
        }
    }
    interpolate_gaps(&mut s, 10);
    // 5-s running median: removes 1-2 s probe spikes/dropouts that would
    // otherwise act as spurious desaturation baselines (oximeters average
    // over 3-8 s anyway).
    let raw = s.clone();
    for (i, v) in s.iter_mut().enumerate() {
        if raw[i].is_nan() {
            continue;
        }
        let win: Vec<f64> = raw[i.saturating_sub(2)..(i + 3).min(raw.len())]
            .iter()
            .copied()
            .filter(|x| x.is_finite())
            .collect();
        *v = median(&win);
    }
    s
}

fn interpolate_gaps(s: &mut [f64], max_gap: usize) {
    let n = s.len();
    let mut i = 0;
    while i < n {
        if s[i].is_nan() {
            let a = i;
            while i < n && s[i].is_nan() {
                i += 1;
            }
            let b = i;
            if a > 0 && b < n && b - a <= max_gap {
                let (va, vb) = (s[a - 1], s[b]);
                for k in a..b {
                    let f = (k - a + 1) as f64 / (b - a + 1) as f64;
                    s[k] = va + f * (vb - va);
                }
            }
        } else {
            i += 1;
        }
    }
}

fn nan_max(v: &[f64]) -> f64 {
    v.iter().copied().filter(|x| x.is_finite()).fold(f64::NAN, |a, b| if a.is_nan() || b > a { b } else { a })
}

fn nan_min(v: &[f64]) -> f64 {
    v.iter().copied().filter(|x| x.is_finite()).fold(f64::NAN, |a, b| if a.is_nan() || b < a { b } else { a })
}

fn slice_s(v: &[f64], a: f64, b: f64) -> &[f64] {
    let n = v.len();
    let ia = (a.max(0.0).floor() as usize).min(n);
    let ib = (b.max(0.0).ceil() as usize).min(n);
    if ib > ia { &v[ia..ib] } else { &v[0..0] }
}

/// Desaturation associated with an event: pre-event baseline (max SpO2 in
/// the 30 s before onset up to 5 s after) minus the nadir from onset to
/// 30 s after termination (circulatory delay).
fn event_desat(spo2: &[f64], start: f64, end: f64) -> (f64, f64, f64) {
    let pre = nan_max(slice_s(spo2, start - 30.0, start + 5.0));
    let nadir = nan_min(slice_s(spo2, start, end + 30.0));
    (pre - nadir, pre, nadir)
}

#[derive(Debug, Clone, Serialize)]
pub struct Desaturation {
    pub start: f64,
    pub nadir_time: f64,
    pub end: f64,
    pub baseline: f64,
    pub nadir: f64,
    pub drop: f64,
    pub in_sleep: bool,
}

/// Oxygen desaturation events (>= `thr` % from a local peak within 120 s).
fn detect_desaturations(spo2: &[f64], thr: f64, ctx: &SleepContext) -> Vec<Desaturation> {
    let n = spo2.len();
    let mut out = Vec::new();
    let mut i = 1;
    while i + 1 < n {
        let (p, a, b) = (spo2[i], spo2[i - 1], spo2[i + 1]);
        if !(p.is_finite() && a.is_finite() && b.is_finite()) || p < a || p < b {
            i += 1;
            continue;
        }
        let mut found = None;
        let mut j = i + 1;
        while j < n.min(i + 120) {
            let v = spo2[j];
            if !v.is_finite() || v > p {
                break;
            }
            if v <= p - thr {
                found = Some(j);
                break;
            }
            j += 1;
        }
        let Some(f) = found else {
            i += 1;
            continue;
        };
        let mut k = f;
        let mut nad = spo2[f];
        let mut kn = f;
        while k + 1 < n && spo2[k + 1].is_finite() && spo2[k + 1] <= nad + 0.5 && k - f < 120 {
            k += 1;
            if spo2[k] < nad {
                nad = spo2[k];
                kn = k;
            }
        }
        let drop = p - nad;
        let target = nad + (2.0f64).max(0.5 * drop);
        let mut m = kn;
        while m + 1 < n && spo2[m + 1].is_finite() && spo2[m + 1] < target && m - kn < 120 {
            m += 1;
        }
        out.push(Desaturation {
            start: i as f64,
            nadir_time: kn as f64,
            end: (m + 1) as f64,
            baseline: p,
            nadir: nad,
            drop,
            in_sleep: ctx.is_sleep(kn as f64),
        });
        i = m + 1;
    }
    out
}

/// Pulse rate at 1 Hz from a pulse/HR channel (bpm), or from ECG R-peaks.
fn pulse_rate_1hz(pulse: Option<(&[f64], f64)>, ecg: Option<(&[f64], f64)>, n_sec: usize) -> Option<(Vec<f64>, String)> {
    if let Some((sig, fs)) = pulse {
        let mut hr: Vec<f64> = (0..n_sec)
            .map(|i| {
                let a = (i as f64 * fs) as usize;
                let b = (((i + 1) as f64 * fs) as usize).min(sig.len());
                if b > a { median(&sig[a..b]) } else { f64::NAN }
            })
            .map(|v| if (25.0..=220.0).contains(&v) { v } else { f64::NAN })
            .collect();
        interpolate_gaps(&mut hr, 10);
        if hr.iter().filter(|v| v.is_finite()).count() > n_sec / 4 {
            return Some((hr, "pulse".into()));
        }
    }
    let (sig, fs) = ecg?;
    if fs < 100.0 {
        return None;
    }
    // Pan-Tompkins-style detector: band-pass 5-20 Hz, derivative, square,
    // 120 ms integration, adaptive threshold with 250 ms refractory period.
    let x = butter_filtfilt(sig, fs, Some(5.0), Some(20.0));
    let d: Vec<f64> = x.windows(2).map(|w| (w[1] - w[0]).powi(2)).collect();
    let integ = moving_average(&d, (0.12 * fs) as usize);
    let blk = (10.0 * fs) as usize;
    let mut peaks = Vec::new();
    let refractory = (0.25 * fs) as usize;
    let mut i = 0;
    while i < integ.len() {
        let a = i.saturating_sub(blk / 2);
        let b = (i + blk / 2).min(integ.len());
        let thr = 0.35 * percentile(&integ[a..b], 98.0);
        let end = (i + blk).min(integ.len());
        let mut k = i;
        while k < end {
            if integ[k] > thr {
                let mut m = k;
                let stop = (k + refractory).min(integ.len());
                let mut best = k;
                while m < stop {
                    if integ[m] > integ[best] {
                        best = m;
                    }
                    m += 1;
                }
                if peaks.last().map(|&p: &usize| best - p > refractory).unwrap_or(true) {
                    peaks.push(best);
                }
                k = stop;
            } else {
                k += 1;
            }
        }
        i = end;
    }
    let mut hr = vec![f64::NAN; n_sec];
    for w in peaks.windows(2) {
        let rr = (w[1] - w[0]) as f64 / fs;
        let bpm = 60.0 / rr;
        if (30.0..=200.0).contains(&bpm) {
            let t = (w[1] as f64 / fs) as usize;
            if t < n_sec {
                hr[t] = if hr[t].is_finite() { 0.5 * (hr[t] + bpm) } else { bpm };
            }
        }
    }
    // median-smooth and fill
    let raw = hr.clone();
    for (t, v) in hr.iter_mut().enumerate() {
        let seg: Vec<f64> = raw[t.saturating_sub(2)..(t + 3).min(n_sec)].iter().copied().filter(|x| x.is_finite()).collect();
        *v = if seg.is_empty() { f64::NAN } else { median(&seg) };
    }
    interpolate_gaps(&mut hr, 10);
    if hr.iter().filter(|v| v.is_finite()).count() > n_sec / 4 {
        Some((hr, "ecg".into()))
    } else {
        None
    }
}

// ───────────────────────────── output model ─────────────────────────────

#[derive(Debug, Clone, Serialize)]
pub struct RespEvent {
    /// "Obstructive Apnea" | "Central Apnea" | "Mixed Apnea" | "Apnea" |
    /// "Obstructive Hypopnea" | "Central Hypopnea" | "Hypopnea" | "RERA"
    pub kind: String,
    pub start: f64,
    pub end: f64,
    pub duration: f64,
    pub stage: String,
    pub desaturation: Option<f64>,
    pub spo2_nadir: Option<f64>,
    pub arousal: bool,
    pub min_flow_ratio: f64,
    pub position: Option<f64>,
    /// counted in the primary AHI (sleep, valid sensor, rule satisfied)
    pub counted: bool,
    pub meets_3a: bool,
    pub meets_4: bool,
    pub snoring: bool,
    pub paradox: bool,
    pub note: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct RespSummary {
    pub values: BTreeMap<String, f64>,
    pub flags: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct EpochSeries {
    pub spo2_mean: Vec<Option<f64>>,
    pub spo2_min: Vec<Option<f64>>,
    pub pulse_mean: Vec<Option<f64>>,
    pub flow_ratio_min: Vec<Option<f64>>,
}

#[derive(Debug, Clone, Serialize)]
pub struct RespReport {
    pub analysis: String,
    pub version: String,
    pub recording: String,
    pub scoring: Option<String>,
    pub channels: BTreeMap<String, String>,
    pub settings: BTreeMap<String, String>,
    pub has_hypnogram: bool,
    pub summary: BTreeMap<String, f64>,
    pub flags: BTreeMap<String, String>,
    pub position_table: Vec<BTreeMap<String, f64>>,
    pub hourly: Vec<BTreeMap<String, f64>>,
    pub events: Vec<RespEvent>,
    pub desaturations: Vec<Desaturation>,
    pub arousals: Vec<Arousal>,
    pub csb_segments: Vec<(f64, f64)>,
    pub epochs: EpochSeries,
    pub warnings: Vec<String>,
}

fn opt(v: f64) -> Option<f64> {
    if v.is_finite() { Some((v * 100.0).round() / 100.0) } else { None }
}

fn per_hour(count: usize, seconds: f64) -> f64 {
    if seconds > 0.0 { count as f64 / (seconds / 3600.0) } else { f64::NAN }
}

// ───────────────────────────── main analysis ─────────────────────────────

pub fn analyse(edf: &Path, opts: &RespOptions) -> Result<RespReport> {
    println!("PROGRESS 0.05 Reading channel list");
    let infos: Vec<SignalInfo> = read_signal_infos(edf)?;
    let guesses = guess_roles(&infos);
    let pick = |explicit: &Option<String>, role: &str| -> Option<String> {
        match explicit {
            Some(s) if s.trim() == "-" || s.trim().eq_ignore_ascii_case("none") => None,
            Some(s) if !s.trim().is_empty() => Some(s.trim().to_string()),
            _ => first_with_role(&guesses, role).map(String::from),
        }
    };
    let thermal = pick(&opts.thermal, "thermal");
    let pressure = pick(&opts.pressure, "pressure");
    let generic = pick(&opts.flow, "flow");
    let thorax = pick(&opts.thorax, "thorax");
    let abdomen = pick(&opts.abdomen, "abdomen");
    let effort_sum = pick(&opts.effort_sum, "effort_sum");
    let spo2_l = pick(&opts.spo2, "spo2");
    let pulse_l = pick(&opts.pulse, "pulse");
    let ecg_l = pick(&opts.ecg, "ecg");
    let snore_l = pick(&opts.snore, "snore");
    let pos_l = pick(&opts.position, "position");
    let chin_l = pick(&opts.chin, "chin");

    let mut warnings = Vec::new();
    let mut channels = BTreeMap::new();

    println!("PROGRESS 0.10 Loading respiratory signals");
    let load = |l: &Option<String>| load_signal(edf, l.as_deref());
    let s_thermal = load(&thermal)?;
    let s_pressure = load(&pressure)?;
    let s_generic = if s_thermal.is_none() && s_pressure.is_none() { load(&generic)? } else { None };
    let s_thorax = load(&thorax)?;
    let s_abdomen = load(&abdomen)?;
    let s_sum = load(&effort_sum)?;
    let s_spo2 = load(&spo2_l)?;
    let s_pulse = load(&pulse_l)?;
    let s_ecg = if s_pulse.is_none() { load(&ecg_l)? } else { None };
    let s_snore = load(&snore_l)?;
    let s_pos = load(&pos_l)?;

    // Effort: RIPsum, else thorax + abdomen (resampled to a common rate).
    let effort: Option<(Vec<f64>, f64, String)> = if let Some(s) = &s_sum {
        Some((s.data.clone(), s.sfreq, s.label.clone()))
    } else {
        match (&s_thorax, &s_abdomen) {
            (Some(t), Some(a)) => {
                let fs = t.sfreq.min(a.sfreq);
                let tt = resample_linear(&t.data, t.sfreq, fs);
                let aa = resample_linear(&a.data, a.sfreq, fs);
                // Normalise each belt before summing (gains differ).
                let st = percentile(&tt.iter().map(|v| v.abs()).collect::<Vec<_>>(), 90.0).max(1e-9);
                let sa = percentile(&aa.iter().map(|v| v.abs()).collect::<Vec<_>>(), 90.0).max(1e-9);
                let n = tt.len().min(aa.len());
                Some(((0..n).map(|i| tt[i] / st + aa[i] / sa).collect(), fs, format!("{}+{}", t.label, a.label)))
            }
            (Some(t), None) => Some((t.data.clone(), t.sfreq, t.label.clone())),
            (None, Some(a)) => Some((a.data.clone(), a.sfreq, a.label.clone())),
            _ => None,
        }
    };

    // Apnea sensor: thermal > pressure > generic flow > RIPsum.
    let apnea_src = s_thermal
        .as_ref()
        .map(|s| (s.data.clone(), s.sfreq, s.label.clone(), "thermal"))
        .or_else(|| s_pressure.as_ref().map(|s| (s.data.clone(), s.sfreq, s.label.clone(), "nasal pressure")))
        .or_else(|| s_generic.as_ref().map(|s| (s.data.clone(), s.sfreq, s.label.clone(), "airflow")))
        .or_else(|| effort.as_ref().map(|e| (e.0.clone(), e.1, e.2.clone(), "RIPsum")));
    // Hypopnea sensor: pressure > thermal > generic > RIPsum.
    let hyp_src = s_pressure
        .as_ref()
        .map(|s| (s.data.clone(), s.sfreq, s.label.clone(), "nasal pressure"))
        .or_else(|| s_thermal.as_ref().map(|s| (s.data.clone(), s.sfreq, s.label.clone(), "thermal")))
        .or_else(|| s_generic.as_ref().map(|s| (s.data.clone(), s.sfreq, s.label.clone(), "airflow")))
        .or_else(|| effort.as_ref().map(|e| (e.0.clone(), e.1, e.2.clone(), "RIPsum")));
    let Some(apnea_src) = apnea_src else {
        bail!("No airflow (thermal / nasal pressure / flow) or effort channel found. Select the respiratory channels explicitly.");
    };
    let hyp_src = hyp_src.expect("hypopnea sensor falls back to apnea sensor");
    channels.insert("apnea_sensor".into(), format!("{} ({})", apnea_src.2, apnea_src.3));
    channels.insert("hypopnea_sensor".into(), format!("{} ({})", hyp_src.2, hyp_src.3));
    if apnea_src.3 != "thermal" {
        warnings.push(format!(
            "No oronasal thermal sensor: apneas scored on the alternative sensor ({}), as permitted by AASM.",
            apnea_src.3
        ));
    }
    if let Some(e) = &effort {
        channels.insert("effort".into(), e.2.clone());
    } else {
        warnings.push("No respiratory effort channel: apneas cannot be classified (obstructive/central/mixed).".into());
    }

    let duration = apnea_src.0.len() as f64 / apnea_src.1;
    let (stages, scoring_events) = match &opts.scoring {
        Some(p) if p.exists() => {
            let (s, e) = read_scoring(p)?;
            (Some(s), e)
        }
        _ => (None, Vec::new()),
    };
    let ctx = SleepContext::new(stages, duration, opts.lights_off, opts.lights_on);
    if !ctx.has_hypnogram {
        warnings.push(
            "No sleep staging available: indices use monitoring time (REI-style) and events in wake cannot be excluded.".into(),
        );
    }

    println!("PROGRESS 0.25 Segmenting breaths and measuring flow excursions");
    let fa_apnea = analyse_flow(&apnea_src.0, apnea_src.1);
    let same_sensor = apnea_src.2 == hyp_src.2;
    let fa_hyp = if same_sensor { None } else { Some(analyse_flow(&hyp_src.0, hyp_src.1)) };
    let fa_h = fa_hyp.as_ref().unwrap_or(&fa_apnea);
    let effort_fa = effort.as_ref().map(|e| analyse_flow(&e.0, e.1));

    println!("PROGRESS 0.40 Processing oximetry and pulse");
    let n_sec = duration as usize;
    let spo2 = s_spo2.as_ref().map(|s| clean_spo2(&s.data, s.sfreq));
    if let Some(s) = &s_spo2 {
        channels.insert("spo2".into(), s.label.clone());
    } else {
        warnings.push("No SpO2 channel: hypopneas can only be scored with arousals; ODI and hypoxic burden unavailable.".into());
    }
    let hr = pulse_rate_1hz(
        s_pulse.as_ref().map(|s| (s.data.as_slice(), s.sfreq)),
        s_ecg.as_ref().map(|s| (s.data.as_slice(), s.sfreq)),
        n_sec,
    );
    if let Some((_, src)) = &hr {
        let label = if src == "pulse" {
            s_pulse.as_ref().map(|s| s.label.clone()).unwrap_or_default()
        } else {
            s_ecg.as_ref().map(|s| format!("{} (R-peaks)", s.label)).unwrap_or_default()
        };
        channels.insert("pulse_rate".into(), label);
    }
    let position_1hz: Option<Vec<f64>> = s_pos.as_ref().map(|s| {
        (0..n_sec)
            .map(|i| {
                let a = (i as f64 * s.sfreq) as usize;
                let b = (((i + 1) as f64 * s.sfreq) as usize).min(s.data.len());
                if b > a { s.data[a..b][((b - a) / 2).min(b - a - 1)].round() } else { f64::NAN }
            })
            .collect()
    });
    if let Some(s) = &s_pos {
        channels.insert("position".into(), s.label.clone());
    }

    // Snoring envelope (1 Hz) relative to its night median.
    let snore_1hz: Option<Vec<f64>> = s_snore.as_ref().map(|s| {
        let hp = butter_filtfilt(&s.data, s.sfreq, Some((s.sfreq * 0.02).min(20.0)), None);
        (0..n_sec)
            .map(|i| {
                let a = (i as f64 * s.sfreq) as usize;
                let b = (((i + 1) as f64 * s.sfreq) as usize).min(hp.len());
                if b > a { (hp[a..b].iter().map(|v| v * v).sum::<f64>() / (b - a) as f64).sqrt() } else { 0.0 }
            })
            .collect()
    });
    let snore_med = snore_1hz.as_ref().map(|v| median(v)).unwrap_or(f64::NAN);
    if let Some(s) = &s_snore {
        channels.insert("snore".into(), s.label.clone());
    }

    println!("PROGRESS 0.50 Scoring arousals");
    let force_auto = opts.arousal_mode == "auto";
    let mut arousals = if force_auto || opts.arousal_mode == "none" { Vec::new() } else { manual_arousals(edf, &scoring_events) };
    let mut arousal_source = if arousals.is_empty() { "none".to_string() } else { "manual".to_string() };
    if arousals.is_empty() && (opts.auto_arousals || force_auto) && opts.arousal_mode != "manual" && opts.arousal_mode != "none" && ctx.has_hypnogram {
        if let Some((eeg, efs, label)) = load_arousal_eeg(edf, &infos, &opts.eeg)? {
            let chin = load_signal(edf, chin_l.as_deref())?;
            arousals = detect_arousals(&eeg, efs, chin.as_ref().map(|c| (c.data.as_slice(), c.sfreq)), &ctx);
            arousal_source = format!("auto ({label})");
            channels.insert("arousal_eeg".into(), label);
        }
    }

    println!("PROGRESS 0.60 Scoring apneas and hypopneas");
    let at = opts.apnea_threshold;
    let ht = opts.hypopnea_threshold;
    let red_apnea = reductions(&fa_apnea, ht, at);
    let red_hyp = if same_sensor { red_apnea.clone() } else { reductions(fa_h, ht, at) };

    let valid_at = |fa: &FlowAnalysis, a: f64, b: f64| -> bool {
        let s = slice_s_bool(&fa.valid_1hz, a, b);
        !s.is_empty() && s.iter().filter(|v| **v).count() * 10 >= s.len() * 8
    };
    let effort_absent_frac = |a: f64, b: f64| -> Option<(f64, f64, f64)> {
        let e = effort_fa.as_ref()?;
        let seg = slice_s(&e.ratio_1hz, a, b);
        if seg.is_empty() {
            return None;
        }
        let absent = |s: &[f64]| s.iter().filter(|v| **v < 0.25).count() as f64 / s.len().max(1) as f64;
        let half = seg.len() / 2;
        Some((absent(seg), absent(&seg[..half.max(1)]), absent(&seg[half..])))
    };
    let paradox_at = |a: f64, b: f64| -> bool {
        let (Some(t), Some(ab)) = (&s_thorax, &s_abdomen) else { return false };
        let fs = t.sfreq.min(ab.sfreq);
        let ta = (a * fs) as usize;
        let tb = (b * fs) as usize;
        let tt = resample_linear(&t.data, t.sfreq, fs);
        let aa = resample_linear(&ab.data, ab.sfreq, fs);
        if tb > tt.len().min(aa.len()) || tb <= ta + 10 {
            return false;
        }
        let x = butter_filtfilt(&tt[ta..tb], fs, Some(0.1), Some(1.0));
        let y = butter_filtfilt(&aa[ta..tb], fs, Some(0.1), Some(1.0));
        let mx = mean(&x);
        let my = mean(&y);
        let (mut sxy, mut sxx, mut syy) = (0.0, 0.0, 0.0);
        for (u, v) in x.iter().zip(&y) {
            sxy += (u - mx) * (v - my);
            sxx += (u - mx).powi(2);
            syy += (v - my).powi(2);
        }
        sxy / (sxx * syy).sqrt().max(1e-12) < -0.3
    };
    let snoring_at = |a: f64, b: f64| -> bool {
        let Some(sn) = &snore_1hz else { return false };
        let seg = slice_s(sn, a, b);
        !seg.is_empty() && seg.iter().filter(|v| **v > 3.0 * snore_med.max(1e-9)).count() >= 3
    };
    let pos_at = |t: f64| -> Option<f64> {
        position_1hz.as_ref().and_then(|p| p.get(t as usize).copied()).filter(|v| v.is_finite())
    };

    // Alternative sensors (AASM): when the preferred sensor is invalid, score
    // on the next available one — sensor 0 = preferred, 1 = the other airflow
    // sensor, 2 = RIPsum / effort.
    let invalid_frac = |fa: &FlowAnalysis, a: f64, b: f64| -> f64 {
        let s = slice_s_bool(&fa.valid_1hz, a, b);
        if s.is_empty() { 1.0 } else { s.iter().filter(|v| !**v).count() as f64 / s.len() as f64 }
    };
    let effort_alt = if apnea_src.3 != "RIPsum" { effort_fa.as_ref() } else { None };
    let red_eff: Vec<Reduction> = effort_alt.map(|e| reductions(e, ht, at)).unwrap_or_default();
    let build_cands = |primary: &FlowAnalysis, prim_red: &[Reduction], other: &FlowAnalysis, other_red: &[Reduction], want_apnea: bool| -> Vec<(Reduction, usize)> {
        let keep = |r: &&Reduction| !want_apnea || r.apnea_run >= 10.0;
        let mut out: Vec<(Reduction, usize)> = prim_red.iter().filter(keep).cloned().map(|r| (r, 0)).collect();
        let mut alt: Vec<(Reduction, usize)> = Vec::new();
        if !same_sensor {
            for r in other_red.iter().filter(keep) {
                if invalid_frac(primary, r.start, r.end) >= 0.5 && valid_at(other, r.start, r.end) {
                    alt.push((r.clone(), 1));
                }
            }
        }
        if let Some(e) = effort_alt {
            for r in red_eff.iter().filter(keep) {
                if invalid_frac(primary, r.start, r.end) >= 0.5
                    && (same_sensor || invalid_frac(other, r.start, r.end) >= 0.5)
                    && valid_at(e, r.start, r.end)
                    && !alt.iter().any(|(q, _)| q.start < r.end && r.start < q.end)
                {
                    alt.push((r.clone(), 2));
                }
            }
        }
        // Drop preferred-sensor candidates that are invalid and superseded.
        out.retain(|(r, _)| valid_at(primary, r.start, r.end) || !alt.iter().any(|(q, _)| q.start < r.end && r.start < q.end));
        out.extend(alt);
        out.sort_by(|a, b| a.0.start.partial_cmp(&b.0.start).unwrap_or(std::cmp::Ordering::Equal));
        out
    };
    const ALT_NOTE: [&str; 3] = ["", "alternative airflow sensor", "alternative sensor (RIPsum/effort)"];

    let mut events: Vec<RespEvent> = Vec::new();
    // Apneas
    let apnea_cands = build_cands(&fa_apnea, &red_apnea, fa_h, &red_hyp, true);
    for (r, k) in apnea_cands.iter() {
        let k = *k;
        let src_fa: &FlowAnalysis = match k { 0 => &fa_apnea, 1 => fa_h, _ => effort_alt.unwrap_or(&fa_apnea) };
        let (start, end) = (r.start, r.end);
        let (drop, _pre, nadir) = spo2.as_ref().map(|s| event_desat(s, start, end)).unwrap_or((f64::NAN, f64::NAN, f64::NAN));
        let arousal = arousal_near(&arousals, start, end, 0.0, 5.0);
        let kind = match if k == 2 { None } else { effort_absent_frac(r.apnea_start, r.apnea_end) } {
            None if k == 2 && paradox_at(start, end) => "Obstructive Apnea",
            None => "Apnea",
            Some((all, first, second)) => {
                if all >= 0.8 {
                    "Central Apnea"
                } else if first >= 0.7 && second < 0.5 {
                    "Mixed Apnea"
                } else {
                    "Obstructive Apnea"
                }
            }
        };
        let in_sleep = ctx.is_sleep(0.5 * (start + end));
        let valid = valid_at(src_fa, start, end);
        let mut note = String::new();
        if !in_sleep {
            note = if ctx.in_window(start) { "wake".into() } else { "outside analysis window".into() };
        } else if !valid {
            note = "sensor invalid".into();
        } else if k > 0 {
            note = ALT_NOTE[k].into();
        }
        events.push(RespEvent {
            kind: kind.into(),
            start,
            end,
            duration: end - start,
            stage: ctx.stage_label(start).into(),
            desaturation: opt(drop),
            spo2_nadir: opt(nadir),
            arousal,
            min_flow_ratio: (r.min_ratio * 1000.0).round() / 1000.0,
            position: pos_at(start),
            counted: in_sleep && valid,
            meets_3a: true,
            meets_4: true,
            snoring: snoring_at(start, end),
            paradox: paradox_at(start, end),
            note,
        });
    }
    // Hypopneas (reductions on the hypopnea sensor not overlapping apneas)
    let overlaps = |a: f64, b: f64, list: &[RespEvent]| list.iter().any(|e| e.start < b && a < e.end);
    let apnea_events: Vec<RespEvent> = events.clone();
    let hyp_cands = build_cands(fa_h, &red_hyp, &fa_apnea, &red_apnea, false);
    for (r, k) in hyp_cands.iter() {
        let k = *k;
        let src_fa: &FlowAnalysis = match k { 0 => fa_h, 1 => &fa_apnea, _ => effort_alt.unwrap_or(fa_h) };
        let (start, end) = (r.start, r.end);
        if overlaps(start, end, &apnea_events) {
            continue;
        }
        let (drop, _pre, nadir) = spo2.as_ref().map(|s| event_desat(s, start, end)).unwrap_or((f64::NAN, f64::NAN, f64::NAN));
        let arousal = arousal_near(&arousals, start, end, 0.0, 5.0);
        let meets_3a = (drop.is_finite() && drop >= 3.0) || arousal;
        let meets_4 = drop.is_finite() && drop >= 4.0;
        if !(meets_3a || meets_4) {
            continue;
        }
        let snoring = snoring_at(start, end);
        let paradox = paradox_at(start, end);
        let kind = if effort_fa.is_none() && snore_1hz.is_none() {
            "Hypopnea"
        } else if snoring || paradox {
            "Obstructive Hypopnea"
        } else if k == 2 {
            "Hypopnea"
        } else if let Some((all, _, _)) = effort_absent_frac(start, end) {
            if all < 0.3 { "Obstructive Hypopnea" } else { "Central Hypopnea" }
        } else {
            "Hypopnea"
        };
        let in_sleep = ctx.is_sleep(0.5 * (start + end));
        let valid = valid_at(src_fa, start, end);
        let rule_ok = if opts.hypopnea_rule == 4 { meets_4 } else { meets_3a };
        let mut note = String::new();
        if !in_sleep {
            note = if ctx.in_window(start) { "wake".into() } else { "outside analysis window".into() };
        } else if !valid {
            note = "sensor invalid".into();
        } else if !rule_ok {
            note = format!("does not meet {}% rule", opts.hypopnea_rule);
        } else if k > 0 {
            note = ALT_NOTE[k].into();
        }
        events.push(RespEvent {
            kind: kind.into(),
            start,
            end,
            duration: end - start,
            stage: ctx.stage_label(start).into(),
            desaturation: opt(drop),
            spo2_nadir: opt(nadir),
            arousal,
            min_flow_ratio: (r.min_ratio * 1000.0).round() / 1000.0,
            position: pos_at(start),
            counted: in_sleep && valid && rule_ok,
            meets_3a,
            meets_4,
            snoring,
            paradox,
            note,
        });
    }
    // RERAs: >= 10 s of mild flow limitation (10-30 % reduction) ending in an arousal.
    if !arousals.is_empty() {
        let mild = reductions(fa_h, 0.9, at);
        for r in mild {
            if overlaps(r.start, r.end, &events) {
                continue;
            }
            if !arousal_near(&arousals, r.end - 5.0, r.end, 0.0, 5.0) {
                continue;
            }
            let in_sleep = ctx.is_sleep(0.5 * (r.start + r.end));
            events.push(RespEvent {
                kind: "RERA".into(),
                start: r.start,
                end: r.end,
                duration: r.end - r.start,
                stage: ctx.stage_label(r.start).into(),
                desaturation: None,
                spo2_nadir: None,
                arousal: true,
                min_flow_ratio: (r.min_ratio * 1000.0).round() / 1000.0,
                position: pos_at(r.start),
                counted: in_sleep && valid_at(fa_h, r.start, r.end),
                meets_3a: false,
                meets_4: false,
                snoring: snoring_at(r.start, r.end),
                paradox: false,
                note: String::new(),
            });
        }
    }
    events.sort_by(|a, b| a.start.total_cmp(&b.start));

    println!("PROGRESS 0.75 Computing indices");
    let desats3 = spo2.as_ref().map(|s| detect_desaturations(s, 3.0, &ctx)).unwrap_or_default();
    let desats4 = spo2.as_ref().map(|s| detect_desaturations(s, 4.0, &ctx)).unwrap_or_default();

    let tst = ctx.tst_sec();
    let rem = ctx.stage_sec(Stage::Rem);
    let nrem = tst - rem;
    let mut v: BTreeMap<String, f64> = BTreeMap::new();
    let mut flags: BTreeMap<String, String> = BTreeMap::new();
    let is_apnea = |e: &RespEvent| e.kind.contains("Apnea");
    let is_hyp = |e: &RespEvent| e.kind.contains("Hypopnea");
    let counted: Vec<&RespEvent> = events.iter().filter(|e| e.counted).collect();
    let count_kind = |k: &str| counted.iter().filter(|e| e.kind == k).count();
    let n_oa = count_kind("Obstructive Apnea");
    let n_ca = count_kind("Central Apnea");
    let n_ma = count_kind("Mixed Apnea");
    let n_ua = count_kind("Apnea");
    let n_ap = n_oa + n_ca + n_ma + n_ua;
    let n_hyp = counted.iter().filter(|e| is_hyp(e)).count();
    let n_ohyp = count_kind("Obstructive Hypopnea");
    let n_chyp = count_kind("Central Hypopnea");
    let n_rera = count_kind("RERA");
    // Alternative-rule hypopnea counts (sleep, valid) for side-by-side AHI.
    let alt_valid = |e: &&RespEvent| is_hyp(e) && e.note.is_empty() || (is_hyp(e) && e.note.starts_with("does not meet"));
    let hyp3 = events.iter().filter(|e| alt_valid(e) && e.meets_3a).count();
    let hyp4 = events.iter().filter(|e| alt_valid(e) && e.meets_4).count();
    let ahi = per_hour(n_ap + n_hyp, tst);
    v.insert("TST_min".into(), tst / 60.0);
    v.insert("TRT_min".into(), (ctx.lights_on - ctx.lights_off) / 60.0);
    v.insert("REM_min".into(), rem / 60.0);
    v.insert("NREM_min".into(), nrem / 60.0);
    v.insert("n_obstructive_apnea".into(), n_oa as f64);
    v.insert("n_central_apnea".into(), n_ca as f64);
    v.insert("n_mixed_apnea".into(), n_ma as f64);
    v.insert("n_unclassified_apnea".into(), n_ua as f64);
    v.insert("n_apnea".into(), n_ap as f64);
    v.insert("n_hypopnea".into(), n_hyp as f64);
    v.insert("n_obstructive_hypopnea".into(), n_ohyp as f64);
    v.insert("n_central_hypopnea".into(), n_chyp as f64);
    v.insert("n_rera".into(), n_rera as f64);
    v.insert("AHI".into(), ahi);
    v.insert("AHI_3a".into(), per_hour(n_ap + hyp3, tst));
    v.insert("AHI_4".into(), per_hour(n_ap + hyp4, tst));
    v.insert("AI".into(), per_hour(n_ap, tst));
    v.insert("OAI".into(), per_hour(n_oa, tst));
    v.insert("CAI".into(), per_hour(n_ca, tst));
    v.insert("MAI".into(), per_hour(n_ma, tst));
    v.insert("HI".into(), per_hour(n_hyp, tst));
    v.insert("RERA_index".into(), per_hour(n_rera, tst));
    v.insert("RDI".into(), per_hour(n_ap + n_hyp + n_rera, tst));
    v.insert("central_index".into(), per_hour(n_ca + n_chyp, tst));
    v.insert("obstructive_index".into(), per_hour(n_oa + n_ma + n_ohyp, tst));
    let in_rem = |e: &&&RespEvent| ctx.is_rem(e.start);
    let rem_ev = counted.iter().filter(|e| (is_apnea(e) || is_hyp(e)) && in_rem(e)).count();
    let nrem_ev = counted.iter().filter(|e| (is_apnea(e) || is_hyp(e)) && !in_rem(e)).count();
    if ctx.has_hypnogram {
        v.insert("AHI_REM".into(), per_hour(rem_ev, rem));
        v.insert("AHI_NREM".into(), per_hour(nrem_ev, nrem));
        for (st, name) in [(Stage::N1, "N1"), (Stage::N2, "N2"), (Stage::N3, "N3")] {
            let secs = ctx.stage_sec(st);
            let c = counted
                .iter()
                .filter(|e| (is_apnea(e) || is_hyp(e)) && ctx.stage_at(e.start) == st)
                .count();
            v.insert(format!("AHI_{name}"), per_hour(c, secs));
        }
        let rr = v["AHI_REM"] / v["AHI_NREM"].max(1e-9);
        v.insert("REM_NREM_AHI_ratio".into(), if v["AHI_NREM"] > 0.0 { rr } else { f64::NAN });
        let rem_osa = rem >= 30.0 * 60.0 && v["AHI_REM"] >= 5.0 && v["AHI_NREM"] < 15.0 && rr >= 2.0;
        flags.insert("REM_related_OSA".into(), if rem_osa { "yes" } else { "no" }.into());
    }

    // Event durations
    let durs = |f: &dyn Fn(&RespEvent) -> bool| -> Vec<f64> { counted.iter().filter(|e| f(e)).map(|e| e.duration).collect() };
    let ad = durs(&|e| is_apnea(e));
    let hd = durs(&|e| is_hyp(e));
    let all_d = durs(&|e| is_apnea(e) || is_hyp(e));
    v.insert("apnea_duration_mean_s".into(), mean(&ad));
    v.insert("apnea_duration_max_s".into(), ad.iter().copied().fold(f64::NAN, f64::max));
    v.insert("hypopnea_duration_mean_s".into(), mean(&hd));
    v.insert("hypopnea_duration_max_s".into(), hd.iter().copied().fold(f64::NAN, f64::max));
    v.insert("event_duration_mean_s".into(), mean(&all_d));

    // Oximetry
    if let Some(s) = &spo2 {
        let sleep_vals: Vec<f64> = (0..s.len()).filter(|&t| ctx.is_sleep(t as f64)).map(|t| s[t]).filter(|x| x.is_finite()).collect();
        let valid_secs = sleep_vals.len() as f64;
        v.insert("SpO2_mean_sleep".into(), mean(&sleep_vals));
        v.insert("SpO2_min_sleep".into(), nan_min(&sleep_vals));
        v.insert("SpO2_median_sleep".into(), median(&sleep_vals));
        // baseline: median awake SpO2 before sleep onset, else 95th pct of sleep values
        let onset = (0..s.len()).find(|&t| ctx.has_hypnogram && ctx.is_sleep(t as f64));
        let pre: Vec<f64> = onset
            .map(|o| (0..o).filter(|&t| ctx.in_window(t as f64)).map(|t| s[t]).filter(|x| x.is_finite()).collect())
            .unwrap_or_default();
        let baseline = if pre.len() >= 60 { median(&pre) } else { percentile(&sleep_vals, 95.0) };
        v.insert("SpO2_baseline".into(), baseline);
        for thr in [90.0, 88.0, 85.0, 80.0] {
            let below = sleep_vals.iter().filter(|x| **x < thr).count() as f64;
            v.insert(format!("T{}_min", thr as i32), below / 60.0);
            v.insert(format!("T{}_pct", thr as i32), if valid_secs > 0.0 { 100.0 * below / valid_secs } else { f64::NAN });
        }
        let d3: Vec<&Desaturation> = desats3.iter().filter(|d| d.in_sleep).collect();
        let d4: Vec<&Desaturation> = desats4.iter().filter(|d| d.in_sleep).collect();
        v.insert("ODI3".into(), per_hour(d3.len(), tst));
        v.insert("ODI4".into(), per_hour(d4.len(), tst));
        v.insert("n_desat3".into(), d3.len() as f64);
        v.insert("n_desat4".into(), d4.len() as f64);
        v.insert("desat_depth_mean".into(), mean(&d3.iter().map(|d| d.drop).collect::<Vec<_>>()));
        v.insert("desat_duration_mean_s".into(), mean(&d3.iter().map(|d| d.end - d.start).collect::<Vec<_>>()));
        v.insert("desat_area_total_pct_min".into(), d3.iter().map(|d| desat_area(s, d)).sum::<f64>());

        // Hypoxic burden (Azarbarzin et al., Eur Heart J 2019)
        let resp_ev: Vec<&RespEvent> = counted.iter().copied().filter(|e| is_apnea(e) || is_hyp(e)).collect();
        if !resp_ev.is_empty() {
            let hb = hypoxic_burden(s, &resp_ev, tst);
            v.insert("hypoxic_burden_pct_min_per_h".into(), hb);
        }
    }

    // Pulse-rate response ΔHR (Azarbarzin et al., AJRCCM 2021)
    if let Some((hrs, _)) = &hr {
        let resp_ev: Vec<&RespEvent> = counted.iter().copied().filter(|e| is_apnea(e) || is_hyp(e)).collect();
        let sleep_hr: Vec<f64> = (0..hrs.len()).filter(|&t| ctx.is_sleep(t as f64)).map(|t| hrs[t]).filter(|x| x.is_finite()).collect();
        v.insert("pulse_mean_sleep".into(), mean(&sleep_hr));
        if let Some(dhr) = delta_hr(hrs, &resp_ev) {
            v.insert("delta_HR_bpm".into(), dhr);
        }
    }

    // Ventilatory burden: time-integrated flow deficit during scored events.
    {
        let mut area = 0.0;
        for e in counted.iter().filter(|e| is_apnea(e) || is_hyp(e)) {
            let fa = if is_apnea(e) { &fa_apnea } else { fa_h };
            for r in slice_s(&fa.ratio_1hz, e.start, e.end) {
                area += (1.0 - r.min(1.0)).max(0.0);
            }
        }
        v.insert("ventilatory_burden_pct_min_per_h".into(), if tst > 0.0 { 100.0 * (area / 60.0) / (tst / 3600.0) } else { f64::NAN });
    }

    // Arousals
    let ar_sleep = arousals.iter().filter(|a| ctx.is_sleep(a.start)).count();
    v.insert("n_arousals".into(), ar_sleep as f64);
    v.insert("arousal_index".into(), per_hour(ar_sleep, tst));
    let resp_ar = arousals
        .iter()
        .filter(|a| ctx.is_sleep(a.start))
        .filter(|a| counted.iter().any(|e| a.start >= e.start && a.start <= e.end + 5.0))
        .count();
    v.insert("respiratory_arousal_index".into(), per_hour(resp_ar, tst));

    // Cheyne-Stokes breathing: >= 3 consecutive central events with cycle
    // length >= 40 s, and >= 5 central events/h over >= 2 h of monitoring.
    let central: Vec<&RespEvent> = counted
        .iter()
        .copied()
        .filter(|e| e.kind == "Central Apnea" || e.kind == "Central Hypopnea")
        .collect();
    let mut csb_segments = Vec::new();
    let mut i = 0;
    while i < central.len() {
        let mut j = i;
        while j + 1 < central.len() {
            let cyc = central[j + 1].start - central[j].start;
            if (40.0..=120.0).contains(&cyc) {
                j += 1;
            } else {
                break;
            }
        }
        if j >= i + 2 {
            csb_segments.push((central[i].start, central[j].end));
        }
        i = j + 1;
    }
    let csb_min: f64 = csb_segments.iter().map(|(a, b)| (b - a) / 60.0).sum();
    v.insert("CSB_minutes".into(), csb_min);
    v.insert("CSB_pct_TST".into(), if tst > 0.0 { 100.0 * csb_min * 60.0 / tst } else { f64::NAN });
    let csb = per_hour(central.len(), tst) >= 5.0 && (ctx.lights_on - ctx.lights_off) >= 7200.0 && !csb_segments.is_empty();
    flags.insert("Cheyne_Stokes_breathing".into(), if csb { "present" } else { "absent" }.into());

    // Positional analysis
    let mut position_table = Vec::new();
    if let Some(p) = &position_1hz {
        let mut codes: Vec<i64> = p.iter().filter(|x| x.is_finite()).map(|x| *x as i64).collect();
        codes.sort();
        codes.dedup();
        let mut sup_secs = 0.0;
        let mut sup_ev = 0usize;
        let mut non_secs = 0.0;
        let mut non_ev = 0usize;
        for c in codes {
            let secs = (0..p.len()).filter(|&t| p[t] as i64 == c && ctx.is_sleep(t as f64)).count() as f64;
            if secs < 60.0 {
                continue;
            }
            let ev = counted
                .iter()
                .filter(|e| (is_apnea(e) || is_hyp(e)) && e.position.map(|x| x as i64) == Some(c))
                .count();
            let mut row = BTreeMap::new();
            row.insert("code".into(), c as f64);
            row.insert("sleep_min".into(), secs / 60.0);
            row.insert("pct_TST".into(), if tst > 0.0 { 100.0 * secs / tst } else { f64::NAN });
            row.insert("events".into(), ev as f64);
            row.insert("AHI".into(), per_hour(ev, secs));
            let is_sup = opts.supine_codes.iter().any(|s| (*s as i64) == c);
            row.insert("supine".into(), if is_sup { 1.0 } else { 0.0 });
            if is_sup {
                sup_secs += secs;
                sup_ev += ev;
            } else {
                non_secs += secs;
                non_ev += ev;
            }
            position_table.push(row);
        }
        if !opts.supine_codes.is_empty() {
            let sa = per_hour(sup_ev, sup_secs);
            let na = per_hour(non_ev, non_secs);
            v.insert("AHI_supine".into(), sa);
            v.insert("AHI_nonsupine".into(), na);
            v.insert("supine_pct_TST".into(), if tst > 0.0 { 100.0 * sup_secs / tst } else { f64::NAN });
            let posa = sup_secs >= 1800.0 && non_secs >= 1800.0 && sa >= 2.0 * na && ahi >= 5.0;
            flags.insert("positional_OSA".into(), if posa { "yes" } else { "no" }.into());
            if posa && na < 5.0 {
                flags.insert("positional_OSA_type".into(), "exclusive (non-supine AHI < 5)".into());
            }
        }
    }

    let severity = if !ahi.is_finite() {
        "n/a"
    } else if ahi < 5.0 {
        "normal"
    } else if ahi < 15.0 {
        "mild"
    } else if ahi < 30.0 {
        "moderate"
    } else {
        "severe"
    };
    flags.insert("severity".into(), severity.into());
    flags.insert("hypopnea_rule".into(), if opts.hypopnea_rule == 4 { "AASM 1B (>=4% desaturation)" } else { "AASM 1A (>=3% desaturation or arousal)" }.into());
    flags.insert("arousal_source".into(), arousal_source.clone());
    flags.insert("index_denominator".into(), if ctx.has_hypnogram { "total sleep time" } else { "monitoring time (no staging)" }.into());

    // Hourly breakdown (per clock hour of recording)
    let mut hourly = Vec::new();
    let hours = (duration / 3600.0).ceil() as usize;
    for h in 0..hours {
        let (a, b) = (h as f64 * 3600.0, ((h + 1) as f64 * 3600.0).min(duration));
        let sleep_s = (a as usize..b as usize).filter(|&t| ctx.is_sleep(t as f64)).count() as f64;
        let ev = counted.iter().filter(|e| (is_apnea(e) || is_hyp(e)) && e.start >= a && e.start < b).count();
        let mut row = BTreeMap::new();
        row.insert("hour".into(), (h + 1) as f64);
        row.insert("sleep_min".into(), sleep_s / 60.0);
        row.insert("events".into(), ev as f64);
        row.insert("AHI".into(), per_hour(ev, sleep_s));
        if let Some(s) = &spo2 {
            row.insert("SpO2_min".into(), nan_min(slice_s(s, a, b)));
        }
        hourly.push(row);
    }

    // Per-epoch series for hypnogram overlays
    let n_ep = ctx.stages.len();
    let ep_stat = |series: Option<&Vec<f64>>, f: &dyn Fn(&[f64]) -> f64| -> Vec<Option<f64>> {
        match series {
            None => Vec::new(),
            Some(s) => (0..n_ep).map(|e| opt(f(slice_s(s, e as f64 * EPOCH_SEC, (e + 1) as f64 * EPOCH_SEC)))).collect(),
        }
    };
    let epochs = EpochSeries {
        spo2_mean: ep_stat(spo2.as_ref(), &|x| mean(x)),
        spo2_min: ep_stat(spo2.as_ref(), &|x| nan_min(x)),
        pulse_mean: ep_stat(hr.as_ref().map(|h| &h.0), &|x| mean(x)),
        flow_ratio_min: ep_stat(Some(&fa_h.ratio_1hz), &|x| nan_min(x)),
    };

    let mut settings = BTreeMap::new();
    settings.insert("hypopnea_rule".into(), format!("{}%", opts.hypopnea_rule));
    settings.insert("apnea_threshold".into(), format!("{:.2}", at));
    settings.insert("hypopnea_threshold".into(), format!("{:.2}", ht));
    settings.insert("auto_arousals".into(), opts.auto_arousals.to_string());
    settings.insert(
        "supine_codes".into(),
        opts.supine_codes.iter().map(|c| c.to_string()).collect::<Vec<_>>().join(","),
    );

    // Round summary values
    let summary: BTreeMap<String, f64> = v
        .into_iter()
        .filter(|(_, x)| x.is_finite())
        .map(|(k, x)| (k, (x * 1000.0).round() / 1000.0))
        .collect();

    // Keep desaturation list compact: the 3 % events in the analysis window.
    let desaturations: Vec<Desaturation> = desats3.into_iter().filter(|d| ctx.in_window(d.start)).collect();
    let arousals_out = if arousal_source.starts_with("auto") { arousals } else { Vec::new() };

    Ok(RespReport {
        analysis: "respiratory".into(),
        version: env!("CARGO_PKG_VERSION").into(),
        recording: edf.display().to_string(),
        scoring: opts.scoring.as_ref().map(|p| p.display().to_string()),
        channels,
        settings,
        has_hypnogram: ctx.has_hypnogram,
        summary,
        flags,
        position_table,
        hourly,
        events,
        desaturations,
        arousals: arousals_out,
        csb_segments,
        epochs,
        warnings,
    })
}

fn slice_s_bool(v: &[bool], a: f64, b: f64) -> &[bool] {
    let n = v.len();
    let ia = (a.max(0.0).floor() as usize).min(n);
    let ib = (b.max(0.0).ceil() as usize).min(n);
    if ib > ia { &v[ia..ib] } else { &v[0..0] }
}

fn desat_area(spo2: &[f64], d: &Desaturation) -> f64 {
    slice_s(spo2, d.start, d.end)
        .iter()
        .filter(|x| x.is_finite())
        .map(|x| (d.baseline - x).max(0.0))
        .sum::<f64>()
        / 60.0
}

/// Hypoxic burden: event-specific area under the pre-event SpO2 baseline in
/// a search window derived from the ensemble-averaged desaturation curve,
/// summed over events and normalised by sleep time (%·min/h).
fn hypoxic_burden(spo2: &[f64], events: &[&RespEvent], tst: f64) -> f64 {
    const PRE: usize = 100;
    const POST: usize = 100;
    let len = PRE + POST + 1;
    let mut sum = vec![0.0; len];
    let mut cnt = vec![0.0; len];
    for e in events {
        let end = e.end.round() as i64;
        for k in 0..len {
            let t = end - PRE as i64 + k as i64;
            if t >= 0 && (t as usize) < spo2.len() && spo2[t as usize].is_finite() {
                sum[k] += spo2[t as usize];
                cnt[k] += 1.0;
            }
        }
    }
    let avg: Vec<f64> = sum.iter().zip(&cnt).map(|(s, c)| if *c > 0.0 { s / c } else { f64::NAN }).collect();
    // nadir of ensemble average within [-10, +60] s of event end
    let lo = PRE - 10;
    let hi = (PRE + 60).min(len - 1);
    let mut nadir = lo;
    for k in lo..=hi {
        if avg[k] < avg[nadir] {
            nadir = k;
        }
    }
    // window start: last peak before nadir; end: first peak after nadir
    let mut ws = nadir;
    while ws > 1 && avg[ws - 1] >= avg[ws] {
        ws -= 1;
    }
    let mut we = nadir;
    while we + 1 < len && avg[we + 1] >= avg[we] {
        we += 1;
    }
    let (off_s, off_e) = (ws as i64 - PRE as i64, we as i64 - PRE as i64);
    let mut counted_sec = std::collections::HashSet::new();
    let mut area = 0.0;
    for e in events {
        let end = e.end.round() as i64;
        let base = nan_max(slice_s(spo2, e.end - 100.0, e.end));
        if !base.is_finite() {
            continue;
        }
        for t in (end + off_s)..=(end + off_e) {
            if t < 0 || t as usize >= spo2.len() || !counted_sec.insert(t) {
                continue;
            }
            let v = spo2[t as usize];
            if v.is_finite() {
                area += (base - v).max(0.0);
            }
        }
    }
    if tst > 0.0 { (area / 60.0) / (tst / 3600.0) } else { f64::NAN }
}

/// Event-related pulse-rate response: search window from the ensemble
/// average around event termination; ΔHR per event = max pulse rate in the
/// window minus the mean rate in the 10 s before onset; averaged over events.
fn delta_hr(hr: &[f64], events: &[&RespEvent]) -> Option<f64> {
    if events.len() < 5 {
        return None;
    }
    const PRE: i64 = 30;
    const POST: i64 = 60;
    let len = (PRE + POST + 1) as usize;
    let mut sum = vec![0.0; len];
    let mut cnt = vec![0.0; len];
    for e in events {
        let end = e.end.round() as i64;
        for k in 0..len {
            let t = end - PRE + k as i64;
            if t >= 0 && (t as usize) < hr.len() && hr[t as usize].is_finite() {
                sum[k] += hr[t as usize];
                cnt[k] += 1.0;
            }
        }
    }
    let avg: Vec<f64> = sum.iter().zip(&cnt).map(|(s, c)| if *c > 0.0 { s / c } else { f64::NAN }).collect();
    let mut peak = PRE as usize;
    for k in PRE as usize..len {
        if avg[k] > avg[peak] {
            peak = k;
        }
    }
    let (ws, we) = (peak.saturating_sub(10) as i64 - PRE, (peak + 10).min(len - 1) as i64 - PRE);
    let mut vals = Vec::new();
    for e in events {
        let base = mean(slice_s(hr, e.start - 10.0, e.start));
        let end = e.end.round() as i64;
        let win: Vec<f64> = ((end + ws).max(0)..=(end + we).max(0))
            .filter_map(|t| hr.get(t as usize).copied())
            .filter(|x| x.is_finite())
            .collect();
        let mx = win.iter().copied().fold(f64::NAN, f64::max);
        if base.is_finite() && mx.is_finite() {
            vals.push(mx - base);
        }
    }
    if vals.is_empty() { None } else { Some(mean(&vals)) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn synthetic_flow(fs: f64, apnea_at: &[(f64, f64)], secs: f64) -> Vec<f64> {
        (0..(secs * fs) as usize)
            .map(|i| {
                let t = i as f64 / fs;
                let amp = if apnea_at.iter().any(|(a, b)| t >= *a && t < *b) { 0.03 } else { 1.0 };
                amp * (2.0 * std::f64::consts::PI * 0.25 * t).sin()
            })
            .collect()
    }

    #[test]
    fn detects_synthetic_apneas() {
        let fs = 25.0;
        let x = synthetic_flow(fs, &[(300.0, 320.0), (600.0, 625.0)], 900.0);
        let fa = analyse_flow(&x, fs);
        let red = reductions(&fa, 0.7, 0.1);
        let apneas: Vec<_> = red.iter().filter(|r| r.apnea_run >= 10.0).collect();
        assert_eq!(apneas.len(), 2, "{red:?}");
        assert!((apneas[0].start - 300.0).abs() < 5.0);
        assert!((apneas[1].end - 625.0).abs() < 5.0);
    }

    #[test]
    fn desaturation_detector_counts_drops() {
        let mut s = vec![96.0; 600];
        for t in 100..130 {
            s[t] = 96.0 - (t - 100) as f64 * 0.2;
        }
        for t in 130..160 {
            s[t] = 90.0 + (t - 130) as f64 * 0.2;
        }
        let ctx = SleepContext::new(None, 600.0, None, None);
        let d = detect_desaturations(&s, 3.0, &ctx);
        assert_eq!(d.len(), 1);
        assert!((d[0].drop - 6.0).abs() < 0.5);
    }
}
