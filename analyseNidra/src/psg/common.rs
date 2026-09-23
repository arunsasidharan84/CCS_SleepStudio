//! Shared utilities for the cardio-respiratory and limb-movement analyses:
//! zero-phase IIR filtering, resampling, channel-role detection, hypnogram
//! context and arousal handling.

use crate::edf::{channel_match_key, read_edf_annotations, read_native_signals, NativeSignal, SignalInfo};
use crate::hypnogram::Stage;
use anyhow::Result;
use serde::Serialize;
use serde_json::Value;
use std::f64::consts::PI;
use std::path::Path;

// ───────────────────────────── filtering ─────────────────────────────

#[derive(Clone, Copy)]
struct Biquad {
    b: [f64; 3],
    a: [f64; 3],
}

impl Biquad {
    fn lowpass(fc: f64, fs: f64, q: f64) -> Self {
        let w0 = 2.0 * PI * fc / fs;
        let (s, c) = w0.sin_cos();
        let alpha = s / (2.0 * q);
        let a0 = 1.0 + alpha;
        Self {
            b: [(1.0 - c) / 2.0 / a0, (1.0 - c) / a0, (1.0 - c) / 2.0 / a0],
            a: [1.0, -2.0 * c / a0, (1.0 - alpha) / a0],
        }
    }

    fn highpass(fc: f64, fs: f64, q: f64) -> Self {
        let w0 = 2.0 * PI * fc / fs;
        let (s, c) = w0.sin_cos();
        let alpha = s / (2.0 * q);
        let a0 = 1.0 + alpha;
        Self {
            b: [(1.0 + c) / 2.0 / a0, -(1.0 + c) / a0, (1.0 + c) / 2.0 / a0],
            a: [1.0, -2.0 * c / a0, (1.0 - alpha) / a0],
        }
    }

    fn notch(f0: f64, fs: f64, q: f64) -> Self {
        let w0 = 2.0 * PI * f0 / fs;
        let (s, c) = w0.sin_cos();
        let alpha = s / (2.0 * q);
        let a0 = 1.0 + alpha;
        Self {
            b: [1.0 / a0, -2.0 * c / a0, 1.0 / a0],
            a: [1.0, -2.0 * c / a0, (1.0 - alpha) / a0],
        }
    }

    fn run(&self, x: &mut [f64]) {
        let (mut z1, mut z2) = (0.0, 0.0);
        for v in x.iter_mut() {
            let input = *v;
            let out = self.b[0] * input + z1;
            z1 = self.b[1] * input - self.a[1] * out + z2;
            z2 = self.b[2] * input - self.a[2] * out;
            *v = out;
        }
    }
}

/// 4th-order Butterworth Q factors for two cascaded biquads.
const BUTTER4_Q: [f64; 2] = [0.541_196_100_146_197, 1.306_562_964_876_376_7];

fn filtfilt(sections: &[Biquad], x: &[f64], pad: usize) -> Vec<f64> {
    let n = x.len();
    if n < 4 || sections.is_empty() {
        return x.to_vec();
    }
    let pad = pad.min(n - 1);
    // Odd (anti-symmetric) reflection padding, as in scipy.signal.filtfilt.
    let mut ext = Vec::with_capacity(n + 2 * pad);
    for i in (1..=pad).rev() {
        ext.push(2.0 * x[0] - x[i]);
    }
    ext.extend_from_slice(x);
    for i in 1..=pad {
        ext.push(2.0 * x[n - 1] - x[n - 1 - i]);
    }
    for s in sections {
        s.run(&mut ext);
    }
    ext.reverse();
    for s in sections {
        s.run(&mut ext);
    }
    ext.reverse();
    ext[pad..pad + n].to_vec()
}

/// Zero-phase 4th-order Butterworth band-pass (either edge may be `None`).
pub fn butter_filtfilt(x: &[f64], fs: f64, low: Option<f64>, high: Option<f64>) -> Vec<f64> {
    let nyq = fs / 2.0;
    let mut sections = Vec::new();
    if let Some(lo) = low.filter(|&l| l > 0.0 && l < nyq * 0.95) {
        for q in BUTTER4_Q {
            sections.push(Biquad::highpass(lo, fs, q));
        }
    }
    if let Some(hi) = high.filter(|&h| h > 0.0 && h < nyq * 0.98) {
        for q in BUTTER4_Q {
            sections.push(Biquad::lowpass(hi, fs, q));
        }
    }
    let slowest = low.or(high).unwrap_or(1.0).max(1e-3);
    let pad = ((3.0 * fs / slowest) as usize).max(64);
    filtfilt(&sections, x, pad)
}

/// Zero-phase notch at `f0` (e.g. mains 50/60 Hz).
pub fn notch_filtfilt(x: &[f64], fs: f64, f0: f64) -> Vec<f64> {
    if f0 >= fs / 2.0 {
        return x.to_vec();
    }
    filtfilt(&[Biquad::notch(f0, fs, 30.0)], x, (fs * 2.0) as usize)
}

/// Linear-interpolation resampling with an anti-alias low-pass when
/// decimating. Adequate for respiratory / SpO2 / envelope signals.
pub fn resample_linear(x: &[f64], fs: f64, target: f64) -> Vec<f64> {
    if x.is_empty() || (fs - target).abs() < 1e-9 {
        return x.to_vec();
    }
    let src = if target < fs {
        butter_filtfilt(x, fs, None, Some(target * 0.45))
    } else {
        x.to_vec()
    };
    let n = ((x.len() as f64) * target / fs).floor() as usize;
    (0..n)
        .map(|i| {
            let t = i as f64 * fs / target;
            let k = t.floor() as usize;
            let f = t - k as f64;
            if k + 1 < src.len() {
                src[k] * (1.0 - f) + src[k + 1] * f
            } else {
                src[src.len() - 1]
            }
        })
        .collect()
}

pub fn moving_average(x: &[f64], win: usize) -> Vec<f64> {
    let n = x.len();
    if win <= 1 || n == 0 {
        return x.to_vec();
    }
    let half = win / 2;
    let mut prefix = vec![0.0; n + 1];
    for i in 0..n {
        prefix[i + 1] = prefix[i] + x[i];
    }
    (0..n)
        .map(|i| {
            let a = i.saturating_sub(half);
            let b = (i + half + 1).min(n);
            (prefix[b] - prefix[a]) / (b - a) as f64
        })
        .collect()
}

pub fn percentile(values: &[f64], p: f64) -> f64 {
    let mut v: Vec<f64> = values.iter().copied().filter(|x| x.is_finite()).collect();
    if v.is_empty() {
        return f64::NAN;
    }
    v.sort_by(f64::total_cmp);
    let idx = (p / 100.0).clamp(0.0, 1.0) * (v.len() - 1) as f64;
    let lo = idx.floor() as usize;
    let hi = idx.ceil() as usize;
    v[lo] + (v[hi] - v[lo]) * (idx - lo as f64)
}

pub fn median(values: &[f64]) -> f64 {
    percentile(values, 50.0)
}

pub fn mean(values: &[f64]) -> f64 {
    let v: Vec<f64> = values.iter().copied().filter(|x| x.is_finite()).collect();
    if v.is_empty() {
        f64::NAN
    } else {
        v.iter().sum::<f64>() / v.len() as f64
    }
}

// ───────────────────────────── channel roles ─────────────────────────────

/// A channel role guess reported to the UI.
#[derive(Debug, Clone, Serialize)]
pub struct ChannelGuess {
    pub role: String,
    pub label: String,
}

fn norm(s: &str) -> String {
    s.to_ascii_lowercase()
}

fn has_any(hay: &str, needles: &[&str]) -> bool {
    needles.iter().any(|n| hay.contains(n))
}

/// Heuristic role detection from EDF label / transducer / unit.
pub fn guess_role(info: &SignalInfo) -> Option<&'static str> {
    let l = norm(&info.raw_label);
    let t = norm(&info.transducer);
    let u = norm(&info.unit);
    let key = channel_match_key(&info.raw_label).to_ascii_lowercase();
    if l.contains("annotation") {
        return None;
    }
    if has_any(&l, &["spo2", "sao2", "spo 2", "osat", "oxy", "sat "]) || l == "sat" || (u == "%" && l.contains("sp")) {
        return Some("spo2");
    }
    if has_any(&l, &["pleth"]) {
        return Some("pleth");
    }
    if has_any(&l, &["pulse", "heart rate"]) || l == "hr" || l == "pr" || u == "bpm" {
        return Some("pulse");
    }
    if has_any(&l, &["ecg", "ekg"]) {
        return Some("ecg");
    }
    if has_any(&l, &["snor"]) || (l.contains("mic") && !l.contains("micro")) {
        return Some("snore");
    }
    if has_any(&l, &["pos"]) && !has_any(&l, &["post", "pos1", "pos2"]) || l.contains("body") {
        return Some("position");
    }
    if has_any(&l, &["therm", "flow th", "oronasal", "th.", "tflow", "airflow th", "nasal th"]) || has_any(&t, &["therm"]) {
        return Some("thermal");
    }
    if has_any(&l, &["press", "cannula", "pflow", "nasal", "npress"]) || has_any(&t, &["press"]) {
        return Some("pressure");
    }
    if has_any(&l, &["sum"]) && has_any(&l, &["rip", "effort", "resp"]) {
        return Some("effort_sum");
    }
    if has_any(&l, &["thor", "chest", "tho"]) {
        return Some("thorax");
    }
    if has_any(&l, &["abd", "abdo"]) {
        return Some("abdomen");
    }
    if has_any(&l, &["flow", "airflow", "resp"]) {
        return Some("flow");
    }
    // Leg EMG (tibialis anterior)
    if has_any(&l, &["plm", "leg", "tib", "lat", "rat", "lleg", "rleg"]) || key.starts_with("lm") {
        return Some("leg");
    }
    if has_any(&l, &["chin", "emg", "submental", "ment"]) {
        return Some("chin");
    }
    if has_any(&l, &["eog", "loc", "roc"]) || matches!(key.split('-').next().unwrap_or(""), "e1" | "e2") {
        return Some("eog");
    }
    let root = key.split('-').next().unwrap_or("").trim_start_matches("eeg").to_string();
    if matches!(root.as_str(), "c3" | "c4" | "cz") {
        return Some("eeg_central");
    }
    if matches!(root.as_str(), "m1" | "m2" | "a1" | "a2") {
        return Some("reference");
    }
    None
}

/// Which leg a tibialis channel belongs to: `Some(true)` = left.
pub fn leg_side(label: &str) -> Option<bool> {
    let l = norm(label);
    let compact: String = l.chars().filter(|c| c.is_ascii_alphanumeric()).collect();
    if compact.contains("left") || compact.ends_with('l') || compact.starts_with("lat") || compact.starts_with("ll")
        || compact.contains("lleg") || compact.contains("tibl") || compact.contains("legl")
    {
        return Some(true);
    }
    if compact.contains("right") || compact.ends_with('r') || compact.starts_with("rat") || compact.starts_with("rl")
        || compact.contains("rleg") || compact.contains("tibr") || compact.contains("legr")
    {
        return Some(false);
    }
    None
}

pub fn guess_roles(infos: &[SignalInfo]) -> Vec<ChannelGuess> {
    infos
        .iter()
        .filter_map(|i| {
            guess_role(i).map(|r| ChannelGuess {
                role: r.to_string(),
                label: i.label.clone(),
            })
        })
        .collect()
}

pub fn first_with_role<'a>(guesses: &'a [ChannelGuess], role: &str) -> Option<&'a str> {
    guesses.iter().find(|g| g.role == role).map(|g| g.label.as_str())
}

/// Loads a single named signal at native rate.
pub fn load_signal(path: &Path, label: Option<&str>) -> Result<Option<NativeSignal>> {
    let Some(label) = label.filter(|l| !l.trim().is_empty()) else {
        return Ok(None);
    };
    let mut v = read_native_signals(path, &[label.to_string()])?;
    Ok(v.pop().flatten().filter(|s| !s.data.is_empty()))
}

// ───────────────────────────── hypnogram context ─────────────────────────────

pub const EPOCH_SEC: f64 = 30.0;

#[derive(Debug, Clone)]
pub struct SleepContext {
    pub stages: Vec<Stage>,
    pub has_hypnogram: bool,
    pub duration_sec: f64,
    pub lights_off: f64,
    pub lights_on: f64,
}

impl SleepContext {
    pub fn new(stages: Option<Vec<Stage>>, duration_sec: f64, lights_off: Option<f64>, lights_on: Option<f64>) -> Self {
        let n = (duration_sec / EPOCH_SEC).ceil() as usize;
        let has = stages.as_ref().map(|s| s.iter().any(|x| *x != Stage::Unscored)).unwrap_or(false);
        let mut st = stages.unwrap_or_default();
        st.resize(n, Stage::Unscored);
        let off = lights_off.unwrap_or(0.0).clamp(0.0, duration_sec);
        let on = lights_on.unwrap_or(duration_sec).clamp(off, duration_sec);
        Self {
            stages: st,
            has_hypnogram: has,
            duration_sec,
            lights_off: off,
            lights_on: on,
        }
    }

    pub fn stage_at(&self, t: f64) -> Stage {
        if t < 0.0 {
            return Stage::Unscored;
        }
        let e = (t / EPOCH_SEC) as usize;
        self.stages.get(e).copied().unwrap_or(Stage::Unscored)
    }

    /// Inside the analysis window (lights off -> lights on).
    pub fn in_window(&self, t: f64) -> bool {
        t >= self.lights_off && t < self.lights_on
    }

    /// Sleep (N1-N3/REM). Without a hypnogram every in-window second counts
    /// as "sleep" (indices then refer to monitoring time, i.e. REI-style).
    pub fn is_sleep(&self, t: f64) -> bool {
        if !self.in_window(t) {
            return false;
        }
        if !self.has_hypnogram {
            return true;
        }
        matches!(self.stage_at(t), Stage::N1 | Stage::N2 | Stage::N3 | Stage::Rem)
    }

    pub fn is_rem(&self, t: f64) -> bool {
        self.has_hypnogram && self.in_window(t) && self.stage_at(t) == Stage::Rem
    }

    pub fn is_wake(&self, t: f64) -> bool {
        self.has_hypnogram && self.in_window(t) && self.stage_at(t) == Stage::Wake
    }

    fn epoch_seconds_where(&self, f: impl Fn(Stage) -> bool) -> f64 {
        let mut total = 0.0;
        for (i, s) in self.stages.iter().enumerate() {
            let a = (i as f64 * EPOCH_SEC).max(self.lights_off);
            let b = ((i + 1) as f64 * EPOCH_SEC).min(self.lights_on);
            if b > a && f(*s) {
                total += b - a;
            }
        }
        total
    }

    /// Total sleep time in seconds (or monitoring time without hypnogram).
    pub fn tst_sec(&self) -> f64 {
        if !self.has_hypnogram {
            return self.lights_on - self.lights_off;
        }
        self.epoch_seconds_where(|s| matches!(s, Stage::N1 | Stage::N2 | Stage::N3 | Stage::Rem))
    }

    pub fn stage_sec(&self, stage: Stage) -> f64 {
        if !self.has_hypnogram {
            return 0.0;
        }
        self.epoch_seconds_where(|s| s == stage)
    }

    /// Wake after sleep onset (seconds) within the window.
    pub fn waso_sec(&self) -> f64 {
        if !self.has_hypnogram {
            return 0.0;
        }
        let first = self
            .stages
            .iter()
            .position(|s| matches!(s, Stage::N1 | Stage::N2 | Stage::N3 | Stage::Rem));
        let last = self
            .stages
            .iter()
            .rposition(|s| matches!(s, Stage::N1 | Stage::N2 | Stage::N3 | Stage::Rem));
        match (first, last) {
            (Some(f), Some(l)) => (f..=l)
                .filter(|&i| self.stages[i] == Stage::Wake)
                .map(|i| {
                    let a = (i as f64 * EPOCH_SEC).max(self.lights_off);
                    let b = ((i + 1) as f64 * EPOCH_SEC).min(self.lights_on);
                    (b - a).max(0.0)
                })
                .sum(),
            _ => 0.0,
        }
    }

    pub fn stage_label(&self, t: f64) -> &'static str {
        if !self.has_hypnogram {
            return "?";
        }
        match self.stage_at(t) {
            Stage::Wake => "W",
            Stage::N1 => "N1",
            Stage::N2 => "N2",
            Stage::N3 => "N3",
            Stage::Rem => "REM",
            Stage::Unscored => "?",
        }
    }
}

/// Reads stages and annotation events from a ScoringHero JSON file.
pub fn read_scoring(path: &Path) -> Result<(Vec<Stage>, Vec<(f64, f64, String)>)> {
    let stages = crate::hypnogram::read_sleepgpt(path)?;
    let mut events = Vec::new();
    if let Ok(text) = std::fs::read_to_string(path) {
        if let Ok(Value::Array(root)) = serde_json::from_str::<Value>(&text) {
            if root.len() >= 2 {
                if let Value::Array(ann) = &root[1] {
                    for a in ann {
                        let label = a
                            .get("event")
                            .or_else(|| a.get("label"))
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .to_string();
                        let s = a.get("start").or_else(|| a.get("startSec")).and_then(|v| v.as_f64());
                        let e = a.get("end").or_else(|| a.get("endSec")).and_then(|v| v.as_f64());
                        if let (Some(s), Some(e)) = (s, e) {
                            events.push((s.min(e), s.max(e), label));
                        }
                    }
                }
            }
        }
    }
    Ok((stages, events))
}

// ───────────────────────────── arousals ─────────────────────────────

#[derive(Debug, Clone, Serialize)]
pub struct Arousal {
    pub start: f64,
    pub end: f64,
    /// "manual" (scored annotation) or "auto" (EEG detector)
    pub source: String,
}

/// Manually scored arousals from the scoring JSON and EDF+ annotations.
pub fn manual_arousals(edf: &Path, scoring_events: &[(f64, f64, String)]) -> Vec<Arousal> {
    let mut out: Vec<Arousal> = scoring_events
        .iter()
        .filter(|(_, _, l)| l.to_ascii_lowercase().contains("arous"))
        .filter(|(_, _, l)| !l.to_ascii_lowercase().contains("auto"))
        .map(|(s, e, _)| Arousal {
            start: *s,
            end: if e > s { *e } else { s + 3.0 },
            source: "manual".into(),
        })
        .collect();
    if let Ok(ann) = read_edf_annotations(edf) {
        for a in ann {
            let l = a.text.to_ascii_lowercase();
            if l.contains("arous") && !l.contains("auto") {
                let end = if a.duration > 0.0 { a.onset + a.duration } else { a.onset + 3.0 };
                if !out.iter().any(|x| (x.start - a.onset).abs() < 1.0) {
                    out.push(Arousal {
                        start: a.onset,
                        end,
                        source: "manual".into(),
                    });
                }
            }
        }
    }
    out.sort_by(|a, b| a.start.total_cmp(&b.start));
    out
}

/// Automatic EEG arousal detector following the AASM definition: an abrupt
/// shift to theta, alpha and/or >16 Hz (spindle band excluded) lasting at
/// least 3 s, preceded by at least 10 s of stable sleep; in REM a concurrent
/// chin-EMG increase (>= 1 s) is also required when a chin EMG is available.
pub fn detect_arousals(eeg: &[f64], fs: f64, chin: Option<(&[f64], f64)>, ctx: &SleepContext) -> Vec<Arousal> {
    if eeg.len() < (fs * 60.0) as usize {
        return Vec::new();
    }
    let x = notch_filtfilt(&butter_filtfilt(eeg, fs, Some(0.5), Some((fs / 2.0 - 1.0).min(35.0))), fs, 50.0);
    let x = notch_filtfilt(&x, fs, 60.0);
    // 1-s windows, 0.5-s step: power in theta/alpha (4-11 Hz) + beta (16-30 Hz)
    // versus the slow reference band 0.5-4 Hz.
    let win = fs.round() as usize;
    let step = (fs / 2.0).round().max(1.0) as usize;
    let hann: Vec<f64> = (0..win).map(|i| 0.5 - 0.5 * (2.0 * PI * i as f64 / (win - 1) as f64).cos()).collect();
    let mut planner = rustfft::FftPlanner::<f64>::new();
    let fft = planner.plan_fft_forward(win);
    let df = fs / win as f64;
    let mut idx_hf = Vec::new();
    for k in 0..win / 2 {
        let f = k as f64 * df;
        if (4.0..11.0).contains(&f) || (16.0..30.0).contains(&f) {
            idx_hf.push(k);
        }
    }
    let n_win = (x.len().saturating_sub(win)) / step + 1;
    let mut hf = Vec::with_capacity(n_win);
    let mut buf = vec![rustfft::num_complex::Complex64::new(0.0, 0.0); win];
    for w in 0..n_win {
        let a = w * step;
        for i in 0..win {
            buf[i] = rustfft::num_complex::Complex64::new(x[a + i] * hann[i], 0.0);
        }
        fft.process(&mut buf);
        let p: f64 = idx_hf.iter().map(|&k| buf[k].norm_sqr()).sum();
        hf.push((p + 1e-12).log10());
    }
    // Chin EMG envelope (RMS in the same windows) for REM arousals.
    let emg_rms: Option<Vec<f64>> = chin.map(|(sig, efs)| {
        let e = butter_filtfilt(sig, efs, Some(10.0), Some((efs / 2.0 - 1.0).min(100.0)));
        (0..n_win)
            .map(|w| {
                let t0 = w as f64 * step as f64 / fs;
                let a = (t0 * efs) as usize;
                let b = ((t0 + 1.0) * efs) as usize;
                let seg = &e[a.min(e.len())..b.min(e.len())];
                if seg.is_empty() {
                    0.0
                } else {
                    (seg.iter().map(|v| v * v).sum::<f64>() / seg.len() as f64).sqrt()
                }
            })
            .collect()
    });
    // Score = high-frequency log-power relative to the median of the
    // preceding 10-40 s (the "background" of stable sleep).
    let per_sec = fs / step as f64;
    let back_a = (40.0 * per_sec) as usize;
    let back_b = (10.0 * per_sec) as usize;
    let mut score = vec![0.0; n_win];
    for w in back_a..n_win {
        let bg = median(&hf[w - back_a..w - back_b]);
        score[w] = hf[w] - bg;
    }
    let thr = 0.35; // ~2.2x power increase
    let min_len = (3.0 * per_sec) as usize;
    let mut out = Vec::new();
    let mut w = back_a;
    while w < n_win {
        if score[w] > thr {
            let s = w;
            while w < n_win && score[w] > thr * 0.6 {
                w += 1;
            }
            let e = w;
            let t_start = s as f64 * step as f64 / fs;
            let t_end = e as f64 * step as f64 / fs + 1.0;
            let dur = t_end - t_start;
            if e - s >= min_len && dur <= 60.0 {
                // preceded by >= 10 s of sleep, and occurring in sleep
                let stable = (0..10).all(|k| ctx.is_sleep(t_start - 1.0 - k as f64));
                let in_sleep = ctx.is_sleep(t_start);
                let mut ok = stable && in_sleep;
                if ok && ctx.is_rem(t_start) {
                    if let Some(rms) = &emg_rms {
                        let bg = median(&rms[s.saturating_sub(back_a)..s.saturating_sub(back_b).max(1)]);
                        let rise = rms[s..e].iter().filter(|&&v| v > bg * 1.5).count();
                        ok = rise as f64 >= per_sec; // >= 1 s
                    }
                }
                if ok {
                    out.push(Arousal {
                        start: t_start,
                        end: t_end,
                        source: "auto".into(),
                    });
                }
            }
        } else {
            w += 1;
        }
    }
    out
}

/// True when an arousal starts within [a - before, b + after].
pub fn arousal_near(arousals: &[Arousal], a: f64, b: f64, before: f64, after: f64) -> bool {
    arousals.iter().any(|x| x.start >= a - before && x.start <= b + after)
}

/// Finds the first central EEG derivation and optional chin EMG for arousal
/// detection. Returns (eeg signal, fs, label).
pub fn load_arousal_eeg(
    path: &Path,
    infos: &[SignalInfo],
    requested: &[String],
) -> Result<Option<(Vec<f64>, f64, String)>> {
    let mut candidates: Vec<String> = requested.to_vec();
    if candidates.is_empty() {
        for want in ["C4", "C3", "CZ", "F4", "F3"] {
            for i in infos {
                let key = channel_match_key(&i.raw_label).to_ascii_uppercase();
                let root = key.split('-').next().unwrap_or("").trim_start_matches("EEG").to_string();
                if root == want {
                    candidates.push(i.label.clone());
                }
            }
        }
    }
    for c in candidates {
        if let Some(sig) = load_signal(path, Some(&c))? {
            let mut data = sig.data;
            // Reference unreferenced central channels to the contralateral mastoid.
            let key = channel_match_key(&c).to_ascii_uppercase();
            if !key.contains('-') {
                let contra = if key.ends_with('3') { ["M2", "A2"] } else { ["M1", "A1"] };
                for r in contra {
                    if let Some(ref_sig) = load_signal(path, Some(r))? {
                        if (ref_sig.sfreq - sig.sfreq).abs() < 1e-6 {
                            for (x, y) in data.iter_mut().zip(ref_sig.data.iter()) {
                                *x -= y;
                            }
                            break;
                        }
                    }
                }
            }
            return Ok(Some((data, sig.sfreq, sig.label)));
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn butterworth_passes_and_blocks() {
        let fs = 100.0;
        let x: Vec<f64> = (0..6000)
            .map(|i| {
                let t = i as f64 / fs;
                (2.0 * PI * 0.3 * t).sin() + (2.0 * PI * 20.0 * t).sin()
            })
            .collect();
        let y = butter_filtfilt(&x, fs, None, Some(2.0));
        let mid = &y[2000..4000];
        let amp = mid.iter().fold(0.0f64, |a, v| a.max(v.abs()));
        assert!((amp - 1.0).abs() < 0.05, "amp {amp}");
    }

    #[test]
    fn sleep_context_counts_tst() {
        let st = vec![Stage::Wake, Stage::N2, Stage::N2, Stage::Rem, Stage::Wake];
        let ctx = SleepContext::new(Some(st), 150.0, None, None);
        assert_eq!(ctx.tst_sec(), 90.0);
        assert!(ctx.is_rem(100.0));
        assert!(!ctx.is_sleep(10.0));
    }
}
