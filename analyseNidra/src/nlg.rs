//! NeuroLoopGain: amplitude-independent analysis of the slow-wave (or
//! sigma / alpha) "microcontinuity" of the EEG.
//!
//! Faithful port of the open-source NeuroLoopGain 2.x analyser by Bob Kemp
//! and Marco Roessen (https://github.com/NeuroloopGain/neuroloopgain,
//! Apache License 2.0), based on B Kemp, AH Zwinderman, B Tuk,
//! HAC Kamphuisen, JJL Oberyé, "Analysis of a sleep-dependent neuronal
//! feedback loop: the slow-wave microcontinuity of the EEG", IEEE-BME
//! 47(9), 2000: 1185-1194.
//!
//! The reference program stores every intermediate trace (SU, SS, their
//! forward/backward smoothed versions, artifact traces, the gain and its
//! jump/event traces) as 16-bit log-converted EDF samples and repeatedly
//! reads them back. This port keeps exactly the same 16-bit traces and the
//! same order of floating-point operations, so its output is sample-for-
//! sample identical to the reference EDF output (verified against the C#
//! build on the bundled PSG recordings).

use anyhow::{Result, bail};
use serde::Serialize;

/// Trace indices, identical to the reference `OutputBufferOffsets` slots.
pub const SU: usize = 1;
pub const SS: usize = 2;
pub const SU_PLUS: usize = 3;
pub const SU_MINUS: usize = 4;
pub const SS_PLUS: usize = 5;
pub const SS_MINUS: usize = 6;
pub const SSP: usize = 7;
pub const SS0: usize = 8;
pub const ART_HF: usize = 9;
pub const ART_LF: usize = 10;
pub const ART_ZERO: usize = 11;
pub const MC: usize = 12;
pub const MC_JUMP: usize = 13;
pub const MC_EVENT: usize = 14;

/// EDF labels of the 14 output traces (reference program, no input copy).
pub const TRACE_LABELS: [&str; 14] = [
    "SU", "SS", "SU+", "SU-", "SS+", "SS-", "SSP", "SS0", "HF artifact", "LF artifact",
    "Missing signal", "MC (Gain)", "MC (Gain)jump", "MC (Gain)event",
];

/// Analysis parameters (defaults of `MCconfiguration.xml`).
#[derive(Debug, Clone, Serialize)]
pub struct NlgConfig {
    /// Centre frequency of the analysed band (Hz).
    pub f0: f64,
    /// Bandwidth of the band-pass (Hz).
    pub bandwidth: f64,
    /// Cut-off of the feedback low-pass (Hz).
    pub fc: f64,
    /// Smoother rate (/s).
    pub smooth_rate: f64,
    /// Output period / integration time (s).
    pub smooth_time: f64,
    /// Under-sampling factor; 0 selects it automatically (closest to 56 Hz).
    pub iir_undersampler: i32,
    /// Lowest low-pass filter of the recording (Hz); `None` = Nyquist.
    pub lp_hz: Option<f64>,
    /// Highest high-pass filter of the recording (Hz).
    pub hp_hz: f64,
    pub xpib_plus: i32,
    pub xpib_minus: i32,
    pub xpib_zero: i32,
    pub art_max_seconds: i32,
    pub mc_event_duration: i32,
    pub mc_event_reject: f64,
    pub mc_jump_find: f64,
    pub mic_gain: f64,
    pub iir_backpolate: f64,
    pub log_float_a: f64,
    pub log_float_y0: f64,
    pub ss_su_min: i16,
    pub ss_su_max: i16,
    pub pib_peak_width: f64,
    pub pib_correlation_buffer: usize,
    pub safety_factor: f64,
}

impl Default for NlgConfig {
    fn default() -> Self {
        Self {
            f0: 1.0,
            bandwidth: 1.5,
            fc: 1.8,
            smooth_rate: 0.01666,
            smooth_time: 1.0,
            iir_undersampler: 0,
            lp_hz: None,
            hp_hz: 0.0,
            xpib_plus: 9,
            xpib_minus: -9,
            xpib_zero: 10,
            art_max_seconds: 7,
            mc_event_duration: 1,
            mc_event_reject: 2.0,
            mc_jump_find: 0.5,
            mic_gain: 10.0,
            iir_backpolate: 0.5,
            log_float_a: 0.001,
            log_float_y0: 0.0001,
            ss_su_min: -2000,
            ss_su_max: 30000,
            pib_peak_width: 0.2,
            pib_correlation_buffer: 6000,
            safety_factor: 3.0,
        }
    }
}

/// Named analysis bands. The presets are the ones of the reference GUI
/// (slow waves, spindles, alpha).
#[derive(Debug, Clone, Serialize)]
pub struct NlgBand {
    pub name: String,
    pub f0: f64,
    pub bandwidth: f64,
    pub fc: f64,
    pub smooth_rate: f64,
}

impl NlgBand {
    pub fn slow_wave(smooth_rate: f64) -> Self {
        Self { name: "slow_wave".into(), f0: 1.0, bandwidth: 1.5, fc: 1.8, smooth_rate }
    }
    pub fn sigma(smooth_rate: f64) -> Self {
        Self { name: "sigma".into(), f0: 14.0, bandwidth: 3.5, fc: 1.8, smooth_rate }
    }
    pub fn alpha(smooth_rate: f64) -> Self {
        Self { name: "alpha".into(), f0: 10.0, bandwidth: 3.5, fc: 1.8, smooth_rate }
    }
    /// Parses `slow_wave`, `sigma`/`spindle`, `alpha` or
    /// `name:f0:bandwidth[:fc[:rate]]`.
    pub fn parse(spec: &str, default_rate: f64) -> Result<Self> {
        let spec = spec.trim();
        match spec.to_ascii_lowercase().as_str() {
            "slow_wave" | "slowwave" | "sw" | "delta" => return Ok(Self::slow_wave(default_rate)),
            "sigma" | "spindle" | "spindles" => return Ok(Self::sigma(default_rate)),
            "alpha" => return Ok(Self::alpha(default_rate)),
            _ => {}
        }
        let parts: Vec<&str> = spec.split(':').collect();
        if parts.len() < 3 {
            bail!("unknown NeuroLoopGain band '{spec}' (use slow_wave, sigma, alpha or name:f0:bandwidth[:fc[:rate]])");
        }
        let num = |i: usize, d: f64| -> Result<f64> {
            parts.get(i).map(|v| v.trim().parse::<f64>()).transpose().map(|v| v.unwrap_or(d)).map_err(Into::into)
        };
        Ok(Self {
            name: parts[0].trim().to_string(),
            f0: num(1, 1.0)?,
            bandwidth: num(2, 1.5)?,
            fc: num(3, 1.8)?,
            smooth_rate: num(4, default_rate)?,
        })
    }
}

// ─── numerical helpers replicating the .NET behaviour ─────────────────────

/// `(int)x` of a double on x86/.NET: out-of-range and NaN give int.MinValue.
fn c_int(x: f64) -> i32 {
    if x.is_nan() || x >= 2147483648.0 || x < -2147483648.0 {
        i32::MIN
    } else {
        x.trunc() as i32
    }
}

/// `MathEx.RoundNearest`: Math.Round(x, AwayFromZero) cast to int.
fn round_nearest(x: f64) -> i32 {
    c_int(x.round())
}

/// `(short)` cast of an int (keeps the low 16 bits).
fn to_short(x: i32) -> i16 {
    x as i16
}

fn ensure_range(x: f64, lo: f64, hi: f64) -> f64 {
    if x < lo {
        lo
    } else if x > hi {
        hi
    } else {
        x
    }
}

fn ensure_range_i(x: i32, lo: i32, hi: i32) -> i32 {
    if x < lo {
        lo
    } else if x > hi {
        hi
    } else {
        x
    }
}

fn heav(x: f64) -> f64 {
    let mut x = x;
    if x != 0.0 {
        x /= x.abs();
    }
    0.5 * (x + 1.0)
}

fn same_value(a: f64, b: f64) -> bool {
    const RES: f64 = 1e-15 * 1000.0;
    let eps = (a.abs().min(b.abs()) * RES).max(RES);
    if a > b { a - b <= eps } else { b - a <= eps }
}

#[derive(Clone, Copy)]
struct LogConv {
    y0: f64,
    a: f64,
}

impl LogConv {
    fn exp(self, v: i16) -> f64 {
        if v > 0 {
            self.y0 * (self.a * v as f64).exp()
        } else if v < 0 {
            -self.y0 * (-self.a * v as f64).exp()
        } else {
            0.0
        }
    }
    fn log(self, value: f64) -> i16 {
        if value > self.y0 {
            let r = (value.ln() - self.y0.ln()) / self.a;
            return r.min(i16::MAX as f64).round_ties_even() as i16;
        }
        if value < -self.y0 {
            let r = (-(-value).ln() + self.y0.ln()) / self.a;
            return r.max(-(i16::MAX as f64)).round_ties_even() as i16;
        }
        0
    }
}

// ─── IIR filters (DUEFilter / SEFilter) ───────────────────────────────────

struct DueFilter {
    z: [f64; 2],
    sz: [f64; 2],
    sp1: f64,
}

impl DueFilter {
    fn new(fs: f64, fc: f64) -> Self {
        let gain = 1.0;
        let ts = 1.0 / fs;
        let fprewarp = (std::f64::consts::PI * fc * ts).tan() / (std::f64::consts::PI * ts);
        let r = 1.0 / (2.0 * std::f64::consts::PI * fprewarp);
        let s = ts / 2.0;
        Self { z: [gain * (s + r), gain * (s - r)], sz: [0.0; 2], sp1: 0.0 }
    }
    /// Anticipating, back-polate 0.
    fn step(&mut self, x: f64) -> f64 {
        self.sz[0] = x;
        let mut r = 0.0;
        r += self.z[0] * self.sz[0];
        r += self.z[1] * self.sz[1];
        let s = r;
        let out = 0.0 * self.sp1 + (1.0 - 0.0) * s;
        self.sp1 = r;
        self.sz[1] = self.sz[0];
        out
    }
}

struct SeFilter {
    p: [f64; 3],
    z: [f64; 3],
    sp: [f64; 3],
    sz: [f64; 3],
    backpolate: f64,
}

impl SeFilter {
    fn new(fs: f64, fc: f64, f0: f64, bw: f64, backpolate: f64) -> Self {
        use std::f64::consts::PI;
        let gain = 1.0;
        let ts = 1.0 / fs;
        let mut fprewarp = (f0 * PI * ts).tan() / (PI * ts);
        let mut r = {
            let v = 2.0 * PI * fprewarp * ts;
            v * v
        };
        let mut s = 2.0 * PI * bw * ts * 2.0;
        let t = 4.0 + r + s;
        let p = [1.0, (8.0 - 2.0 * r) / t, (-4.0 + s - r) / t];
        fprewarp = (fc * PI * ts).tan() / (PI * ts);
        r = 2.0 / (2.0 * PI * fprewarp);
        s = gain * 2.0 * PI * bw * 2.0;
        let z = [s * (r + ts) / t, s * (-2.0 * r) / t, s * (r - ts) / t];
        Self { p, z, sp: [0.0; 3], sz: [0.0; 3], backpolate }
    }
    /// Not anticipating (current input excluded from the output value).
    fn step(&mut self, x: f64) -> f64 {
        self.sz[0] = x;
        let mut r = 0.0;
        r += self.p[1] * self.sp[1];
        r += self.p[2] * self.sp[2];
        let s = r;
        r += self.z[0] * self.sz[0];
        r += self.z[1] * self.sz[1];
        r += self.z[2] * self.sz[2];
        let out = self.backpolate * self.sp[1] + (1.0 - self.backpolate) * s;
        self.sp[2] = self.sp[1];
        self.sp[1] = r;
        self.sz[2] = self.sz[1];
        self.sz[1] = self.sz[0];
        out
    }
}

// ─── EDF data-block geometry (EdfDataBlockSizeCalculator) ──────────────────

fn all_integer_block_size(fs: &[f64]) -> i64 {
    let block_sum: f64 = fs.iter().sum();
    let mut i: i64 = 0;
    loop {
        i += 1;
        if i as f64 * block_sum > i32::MAX as f64 {
            return -1;
        }
        if fs.iter().all(|&f| {
            let d = f * i as f64;
            c_int(d) as f64 == d
        }) {
            return c_int(i as f64 * block_sum) as i64 * 2;
        }
    }
}

/// Output data-record duration chosen by the reference controller.
fn output_record_duration(sfrecs: &[f64]) -> Result<f64> {
    const MAX_BLOCK: i64 = 61440;
    const MAX_DURATION: f64 = 60.0 * 30.0;
    let min_size = all_integer_block_size(sfrecs);
    if min_size <= 0 {
        bail!("failed to assign a data block duration for the NeuroLoopGain output");
    }
    let i_max = ((MAX_BLOCK as f64 / min_size as f64) * 1_000_000.0).trunc() as i64;
    let mut results: Vec<(f64, f64)> = Vec::new();
    let mut min_error = f64::MAX;
    let mut idx: i64 = -1;
    let mut i: i64 = 1;
    while i < i_max && min_error > 0.0 {
        let mut max_error = f64::NAN;
        for &t in sfrecs {
            let n = i as f64 * t;
            let e = n / 1_000_000.0;
            if c_int(e) <= 0 {
                max_error = f64::NAN;
                break;
            }
            let error = (e - e.floor()) / c_int(e) as f64;
            max_error = if max_error.is_nan() { error } else { error.max(max_error) };
        }
        if max_error.is_nan() || max_error > min_error {
            i += 1;
            continue;
        }
        min_error = max_error;
        idx = i;
        if min_error > 0.0 {
            results.push((i as f64 / 1_000_000.0, min_error));
        } else {
            let mut block: i64 = 0;
            for &f in sfrecs {
                block += (f * (i as f64 / 1_000_000.0)).round() as i64 * 2;
            }
            let mut k: i64 = 1;
            while k * block <= MAX_BLOCK {
                results.push((i as f64 * k as f64 / 1_000_000.0, min_error));
                k += 1;
            }
        }
        i += 1;
    }
    if idx <= 0 || results.is_empty() {
        bail!("failed to assign a data block duration for the NeuroLoopGain output");
    }
    let mut best = 0usize;
    let mut best_error = results[0].1;
    for (k, r) in results.iter().enumerate().skip(1) {
        if r.1 < best_error {
            best_error = r.1;
            best = k;
        } else if same_value(r.1, best_error) && r.0 > results[best].0 && r.0 <= MAX_DURATION {
            best = k;
        }
    }
    Ok(results[best].0)
}

/// Automatic under-sampler choice of the reference GUI (`DoCheckInput`).
pub fn auto_undersampler(fs: f64, cfg: &NlgConfig) -> Result<i32> {
    if cfg.bandwidth >= 2.0 * cfg.f0 {
        bail!("bandwidth should be < 2*F0");
    }
    if cfg.iir_undersampler > 0 {
        // Explicit value (the /UNDERSAMPLE= option of NeuroLoopGain 1.x).
        return Ok(cfg.iir_undersampler);
    }
    let lp = cfg.lp_hz.unwrap_or(fs / 2.0);
    if lp <= 0.0 || lp <= cfg.hp_hz {
        bail!("low-pass filter cut-off must satisfy 0 <= HP < LP");
    }
    if cfg.hp_hz >= fs / 2.0 {
        bail!("high-pass filter cut-off must be below the Nyquist frequency {}", fs / 2.0);
    }
    let fmin = cfg.safety_factor * cfg.f0.max(cfg.fc);
    let fmax = (2.0 * 0.75 * lp).min(fs);
    if fmin > fmax {
        bail!("no valid filter set-up: F0 and/or Fc too large, or LP too small");
    }
    if cfg.hp_hz >= cfg.safety_factor * cfg.f0 {
        bail!("HP filter should be < {} Hz", cfg.safety_factor * cfg.f0);
    }
    if cfg.bandwidth >= 2.0 * cfg.f0 {
        bail!("bandwidth should be < 2*F0");
    }
    let lo = c_int((0.99 * fs / fmax).trunc()) + 1;
    let hi = c_int((fs / fmin).trunc());
    if lo > hi {
        bail!("unable to find a valid computation frequency: F0 and/or Fc too large, or LP too small");
    }
    const WANT: f64 = 56.0;
    let mut chosen = lo;
    let mut fcompute = -1.0;
    for i in lo..=hi {
        let d = fs / i as f64;
        if !same_value(fcompute, -1.0) && (WANT - d).abs() >= (WANT - fcompute).abs() {
            continue;
        }
        chosen = i;
        fcompute = d;
    }
    Ok(chosen)
}

/// Low-pass value the reference GUI derives from an EDF pre-filter field
/// (`LP:xx.xHz` / `HP:xx.xHz`); without an HP entry it falls back to Nyquist.
pub fn lp_from_prefilter(prefilter: &str, fs: f64) -> Option<f64> {
    let find = |key: &str| -> Option<f64> {
        let up = prefilter.to_ascii_uppercase();
        let pos = up.find(key)?;
        let rest = &prefilter[pos + key.len()..];
        let end = rest.to_ascii_uppercase().find("HZ")?;
        let value = &rest[..end];
        // The reference regex needs digits, one separator and digits.
        if value.len() < 3 || !value.chars().next()?.is_ascii_digit() {
            return None;
        }
        value.replace(',', ".").parse::<f64>().ok()
    };
    let lp = find("LP:");
    let hp = find("HP:");
    if hp.is_none() {
        return Some(fs / 2.0);
    }
    lp
}

// ─── the analyser ─────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, Default)]
struct McJump {
    processed: bool,
    sample_nr: i64,
    size: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum SmoothOption {
    GetArtifactsResetAll,
    DetectEventsResetJumps,
    Smooth,
    SmoothResetAtJumps,
}

/// Result of one NeuroLoopGain run.
#[derive(Debug, Clone)]
pub struct NlgTraces {
    pub config: NlgConfig,
    pub undersampler: i32,
    pub f_compute: f64,
    /// Output sampling rate (Hz) of every trace.
    pub output_rate: f64,
    /// Samples per output data record.
    pub block_samples: usize,
    /// piB as log-converted integer and as physical power.
    pub pib_log: i16,
    pub pib: f64,
    /// Number of output samples that correspond to recorded data (the
    /// reference pads the last data record with zeros).
    pub recorded_samples: usize,
    /// The 14 digital traces, index 1..=14 as `SU` ... `MC_EVENT`
    /// (index 0 unused), each `block_samples * n_records` long.
    pub traces: Vec<Vec<i16>>,
}

impl NlgTraces {
    /// Gain in % (physical value of the `MC (Gain)` trace).
    pub fn gain_percent(&self) -> Vec<f64> {
        self.traces[MC].iter().map(|&d| d as f64 / self.config.mic_gain).collect()
    }
    /// Per-sample artifact / rejection flag used by the smoother.
    pub fn artifact_flags(&self) -> Vec<bool> {
        let thr = round_nearest(
            (self.config.mc_event_reject / self.config.smooth_time)
                * self.config.smooth_rate
                * 100.0
                * self.config.mic_gain,
        );
        (0..self.traces[MC].len())
            .map(|i| {
                self.traces[ART_HF][i] > 0
                    || self.traces[ART_LF][i] > 0
                    || self.traces[ART_ZERO][i] > 0
                    || (self.traces[MC_EVENT][i] as i32).abs() > thr
            })
            .collect()
    }
}

struct Analyser {
    cfg: NlgConfig,
    lc: LogConv,
    t: Vec<Vec<i16>>,
    n_total: i64,
    pib_log: i16,
    pib: f64,
    su_smooth: f64,
    ss_smooth: f64,
    art_hf: i16,
    art_lf: i16,
    art_zero: i16,
    su_forw: Vec<f64>,
    su_back: Vec<f64>,
    ss_forw: Vec<f64>,
    ss_back: Vec<f64>,
    last_jump: McJump,
    mc_event_samples: usize,
    min_samples_between_jumps: i64,
    max_samples_half_jump: i64,
    mc_jump_threshold: f64,
    mc_event_threshold: i32,
}

impl Analyser {
    fn ex(&self, trace: usize, i: usize) -> f64 {
        self.lc.exp(self.t[trace][i])
    }

    fn set_pib(&mut self, v: i16) {
        self.pib_log = v;
        self.pib = self.lc.exp(v);
    }

    fn check_settings(&self) -> Result<()> {
        let c = &self.cfg;
        if c.xpib_plus < 1 || c.xpib_minus > -1 || c.xpib_zero < 1 || c.art_max_seconds < 1 {
            bail!("artifact thresholds or -spread incorrect");
        }
        if c.mc_event_duration < 1 {
            bail!("MCEventDuration = {} but should be >= 1", c.mc_event_duration);
        }
        if self.pib < c.log_float_y0 * 10.0 {
            bail!("piB = {} is smaller than LogFloat_Y0*10 (flat or missing signal?)", self.pib);
        }
        if c.mic_gain < 1.0 {
            bail!("MCgain = {} but should be >= 1.0", c.mic_gain);
        }
        if c.smooth_rate <= 0.0 || c.smooth_rate >= 1.0 {
            bail!("SmoothRate = {} but should be > 0.0 and < 1.0", c.smooth_rate);
        }
        Ok(())
    }

    fn smooth_su_ss(&mut self, su_in: f64, ss_in: f64, artifact: bool, reset: bool) -> (f64, f64) {
        let rate = self.cfg.smooth_rate;
        if reset {
            self.su_smooth = 0.0;
            self.ss_smooth = self.pib;
        }
        if artifact {
            self.su_smooth = (1.0 - rate) * self.su_smooth;
            self.ss_smooth = (1.0 - rate) * self.ss_smooth;
            if self.ss_smooth < self.pib {
                self.ss_smooth = self.pib;
            }
        } else {
            let dsu = if su_in > -self.pib { su_in - self.su_smooth } else { -self.pib - self.su_smooth };
            let dss = ss_in - self.ss_smooth;
            self.su_smooth = 0.0_f64.max(self.su_smooth + rate * dsu);
            self.ss_smooth += rate * dss;
            if self.ss_smooth < self.pib {
                self.ss_smooth = self.pib;
            }
        }
        (self.su_smooth, self.ss_smooth)
    }

    fn update_artifacts(&mut self, reset: bool, ss: f64, su: f64) {
        let c = &self.cfg;
        if reset {
            self.art_hf = 0;
            self.art_lf = 0;
            self.art_zero = 0;
        }
        let art_factor = ensure_range((ss - su - self.pib) / self.pib, -1000.0, 1000.0);
        if art_factor >= c.xpib_plus as f64 {
            self.art_hf = self.art_hf.wrapping_add(to_short(round_nearest(art_factor / c.xpib_plus as f64)));
        } else {
            self.art_hf = self.art_hf.wrapping_sub(1);
        }
        self.art_hf = to_short(ensure_range_i(self.art_hf as i32, 0, c.art_max_seconds));
        if art_factor <= c.xpib_minus as f64 {
            self.art_lf = self.art_lf.wrapping_add(to_short(round_nearest(art_factor / c.xpib_minus as f64)));
        } else {
            self.art_lf = self.art_lf.wrapping_sub(1);
        }
        self.art_lf = to_short(ensure_range_i(self.art_lf as i32, 0, c.art_max_seconds));
        if ss <= self.pib / c.xpib_zero as f64 {
            self.art_zero = self
                .art_zero
                .wrapping_add(to_short(round_nearest((self.pib / c.xpib_zero as f64) - ss)));
        } else {
            self.art_zero = self.art_zero.wrapping_sub(1);
        }
        let hi = 1.0_f64.min(c.smooth_time);
        self.art_zero = to_short(c_int(ensure_range(self.art_zero as f64, 0.0, hi)));
    }

    fn reset_all(&mut self, i: usize) {
        for tr in [SU_PLUS, SU_MINUS, SS_PLUS, SS_MINUS, SSP, SS0, MC, MC_JUMP, MC_EVENT] {
            self.t[tr][i] = 0;
        }
        self.t[ART_HF][i] = self.art_hf;
        self.t[ART_LF][i] = self.art_lf;
        self.t[ART_ZERO][i] = self.art_zero;
    }

    fn is_artifact(&self, i: usize) -> bool {
        self.t[ART_HF][i] > 0
            || self.t[ART_LF][i] > 0
            || self.t[ART_ZERO][i] > 0
            || (self.t[MC_EVENT][i] as i32).abs() > self.mc_event_threshold
    }

    fn detect_events(&mut self, i: usize, forward: bool) {
        let n = self.mc_event_samples;
        for k in (1..=n).rev() {
            self.su_forw[k] = self.su_forw[k - 1];
            self.su_back[k] = self.su_back[k - 1];
            self.ss_forw[k] = self.ss_forw[k - 1];
            self.ss_back[k] = self.ss_back[k - 1];
        }
        self.su_forw[0] = self.ex(SU_PLUS, i);
        self.su_back[0] = self.ex(SU_MINUS, i);
        self.ss_forw[0] = self.ex(SS_PLUS, i);
        self.ss_back[0] = self.ex(SS_MINUS, i);
        if forward {
            self.t[MC_JUMP][i] = self.lc.log((self.su_back[n] - self.su_forw[n]) / 2.0);
            self.t[MC_EVENT][i] = self.lc.log((self.ss_back[n] + self.ss_forw[n]) / 2.0);
        } else {
            let mut r = self.ex(MC_JUMP, i);
            let mut s = self.ex(MC_EVENT, i);
            r += (self.su_forw[n] - self.su_back[n]) / 2.0;
            s += (self.ss_forw[n] + self.ss_back[n]) / 2.0;
            let mc_event = ensure_range(100.0 * self.cfg.mic_gain * r / s, -(i16::MAX as f64), i16::MAX as f64);
            self.t[MC_JUMP][i] = 0;
            self.t[MC_EVENT][i] = to_short(round_nearest(mc_event));
        }
    }

    fn smooth_forward(&mut self, file_sample: i64, smooth_reset: &mut bool, reset_at_jumps: bool) {
        let mut ifile = file_sample;
        if reset_at_jumps {
            if *smooth_reset {
                self.last_jump = McJump { processed: true, sample_nr: file_sample, size: self.mc_jump_threshold };
            }
            let mc_jump = self.t[MC_JUMP][file_sample as usize] as f64;
            if mc_jump.abs() >= self.last_jump.size.abs() {
                self.last_jump = McJump { processed: false, sample_nr: file_sample, size: mc_jump };
            }
            if !self.last_jump.processed {
                let m = self.last_jump.sample_nr;
                if (file_sample - m) >= self.min_samples_between_jumps || (mc_jump / self.last_jump.size) < 0.0 {
                    let n = (m + self.max_samples_half_jump).min(self.n_total - 1) as usize;
                    self.su_smooth = self.ex(SU_MINUS, n);
                    self.ss_smooth = self.ex(SS_MINUS, n);
                    ifile = m.min(file_sample);
                    self.last_jump = McJump { processed: true, sample_nr: file_sample, size: self.mc_jump_threshold };
                }
            }
        }
        let mut n = (file_sample - ifile).min(self.max_samples_half_jump);
        while ifile <= file_sample {
            let i = ifile as usize;
            let mut artifact = self.is_artifact(i);
            if reset_at_jumps && n > 0 {
                artifact = true;
                n -= 1;
            }
            let (su_in, ss_in) = (self.ex(SU, i), self.ex(SS, i));
            let (r, s) = self.smooth_su_ss(su_in, ss_in, artifact, *smooth_reset);
            self.t[SU_PLUS][i] = self.lc.log(r);
            self.t[SS_PLUS][i] = self.lc.log(s);
            *smooth_reset = false;
            self.su_forw[1] = self.su_forw[0];
            self.ss_forw[1] = self.ss_forw[0];
            self.su_back[0] = self.ex(SU_MINUS, i);
            self.ss_back[0] = self.ex(SS_MINUS, i);
            self.su_forw[0] = r;
            self.ss_forw[0] = s;
            let ssp = self.ss_forw[1] + self.ss_back[0];
            let mut mc_jump = if ssp <= 0.0 { 0.0 } else { (self.su_back[0] - self.su_forw[1]) / ssp };
            mc_jump = ensure_range(self.cfg.mic_gain * 100.0 * mc_jump, -(i16::MAX as f64), i16::MAX as f64);
            self.t[MC_JUMP][i] = to_short(round_nearest(mc_jump));
            ifile += 1;
        }
    }

    fn smooth_backward(&mut self, file_sample: i64, smooth_reset: &mut bool, reset_at_jumps: bool) {
        let mut ifile = file_sample;
        if reset_at_jumps {
            if *smooth_reset {
                self.last_jump = McJump { processed: true, sample_nr: file_sample, size: self.mc_jump_threshold };
            }
            let mc_jump = self.t[MC_JUMP][file_sample as usize] as f64;
            if mc_jump.abs() >= self.last_jump.size.abs() {
                self.last_jump = McJump { processed: false, sample_nr: file_sample, size: mc_jump };
            }
            if !self.last_jump.processed {
                let m = self.last_jump.sample_nr;
                if (m - file_sample) >= self.min_samples_between_jumps || (mc_jump / self.last_jump.size) < 0.0 {
                    let n = 0.max(m - self.max_samples_half_jump) as usize;
                    self.su_back[0] = self.ex(SU_PLUS, n);
                    self.ss_back[0] = self.ex(SS_PLUS, n);
                    self.su_smooth = self.su_back[0];
                    self.ss_smooth = self.ss_back[0];
                    ifile = file_sample.max(m - 1);
                    self.last_jump = McJump { processed: true, sample_nr: file_sample, size: self.mc_jump_threshold };
                }
            }
        }
        let mut n = (file_sample - ifile).min(self.max_samples_half_jump);
        while ifile >= file_sample {
            let i = ifile as usize;
            let mut artifact = self.is_artifact(i);
            if reset_at_jumps && n > 0 {
                artifact = true;
                n -= 1;
            }
            let (su_in, ss_in) = (self.ex(SU, i), self.ex(SS, i));
            let (r, s) = self.smooth_su_ss(su_in, ss_in, artifact, *smooth_reset);
            self.t[SU_MINUS][i] = self.lc.log(r);
            self.t[SS_MINUS][i] = self.lc.log(s);
            *smooth_reset = false;
            self.su_back[1] = self.su_back[0];
            self.ss_back[1] = self.ss_back[0];
            self.su_back[0] = r;
            self.ss_back[0] = s;
            self.su_forw[0] = self.ex(SU_PLUS, i);
            self.ss_forw[0] = self.ex(SS_PLUS, i);
            let mut ssp = self.ss_forw[0] + self.ss_back[1];
            let mut mc = if ssp <= 0.0 { 0.0 } else { (self.su_back[1] + self.su_forw[0]) / ssp };
            ssp /= 2.0;
            let ss0 = ssp * (1.0 - mc);
            mc = ensure_range(self.cfg.mic_gain * 100.0 * mc, -(i16::MAX as f64), i16::MAX as f64);
            self.t[SSP][i] = self.lc.log(ssp);
            self.t[SS0][i] = self.lc.log(ss0);
            self.t[MC][i] = to_short(round_nearest(mc));
            ifile -= 1;
        }
    }

    fn mc_smooth(&mut self, option: SmoothOption) -> Result<()> {
        self.check_settings()?;
        let c = self.cfg.clone();
        self.mc_event_samples = round_nearest(c.mc_event_duration as f64 / c.smooth_time).max(0) as usize;
        self.min_samples_between_jumps = round_nearest(1.0 / (c.smooth_rate * c.smooth_time)) as i64 + 1;
        self.max_samples_half_jump = self.min_samples_between_jumps / 20 + 1;
        self.mc_jump_threshold = (c.mc_jump_find / c.smooth_time) * 100.0 * c.mic_gain;
        self.mc_event_threshold =
            round_nearest((c.mc_event_reject / c.smooth_time) * c.smooth_rate * 100.0 * c.mic_gain);
        let len = self.mc_event_samples + 1;
        self.su_forw = vec![0.0; len];
        self.su_back = vec![0.0; len];
        self.ss_forw = vec![self.pib; len];
        self.ss_back = vec![self.pib; len];

        let total = self.n_total;
        let mut reset = true;
        // Forward direction.
        for fs in 0..total {
            let i = fs as usize;
            match option {
                SmoothOption::GetArtifactsResetAll => {
                    let (su, ss) = (self.ex(SU, i), self.ex(SS, i));
                    self.update_artifacts(reset, ss, su);
                    self.reset_all(i);
                }
                SmoothOption::DetectEventsResetJumps => self.detect_events(i, true),
                SmoothOption::Smooth => self.smooth_forward(fs, &mut reset, false),
                SmoothOption::SmoothResetAtJumps => self.smooth_forward(fs, &mut reset, true),
            }
            reset = false;
        }
        // Backward direction.
        reset = true;
        self.su_forw.fill(0.0);
        self.su_back.fill(0.0);
        self.ss_forw.fill(self.pib);
        self.ss_back.fill(self.pib);
        for fs in (0..total).rev() {
            let i = fs as usize;
            match option {
                SmoothOption::GetArtifactsResetAll => {
                    let (su, ss) = (self.ex(SU, i), self.ex(SS, i));
                    self.update_artifacts(reset, ss, su);
                    self.t[ART_HF][i] = self.t[ART_HF][i].wrapping_add(self.art_hf);
                    self.t[ART_LF][i] = self.t[ART_LF][i].wrapping_add(self.art_lf);
                    self.t[ART_ZERO][i] = self.t[ART_ZERO][i].wrapping_add(self.art_zero);
                }
                SmoothOption::DetectEventsResetJumps => self.detect_events(i, false),
                SmoothOption::Smooth => self.smooth_backward(fs, &mut reset, false),
                SmoothOption::SmoothResetAtJumps => self.smooth_backward(fs, &mut reset, true),
            }
            reset = false;
        }
        Ok(())
    }

    fn detect_pib(&mut self) {
        let c = &self.cfg;
        let nbins = (c.ss_su_max as i32 - c.ss_su_min as i32 + 1) as usize;
        let mut sssu = vec![0_i16; nbins];
        let mut smoothed = vec![0.0_f64; nbins];
        let tl = c.pib_correlation_buffer;
        let mut template = vec![0.0_f64; tl];
        let mut matched = vec![0.0_f64; nbins];
        for i in 0..self.n_total as usize {
            let su = self.ex(SU, i);
            let ss = self.ex(SS, i);
            if su.abs() >= c.log_float_y0 || ss.abs() >= c.log_float_y0 {
                let j = self.lc.log(ss - su);
                let ji = j as i32;
                if ji >= c.ss_su_min as i32
                    && ji <= c.ss_su_max as i32
                    && sssu[(ji - c.ss_su_min as i32) as usize] < i16::MAX
                    && j != 0
                {
                    sssu[(ji - c.ss_su_min as i32) as usize] += 1;
                }
            }
        }
        let w = ensure_range(((1.0 + c.pib_peak_width).ln() / c.log_float_a / 2.0).trunc(), -(i32::MAX as f64), i32::MAX as f64)
            as i64;
        let span = c.ss_su_max as i64 - c.ss_su_min as i64;
        let mut k = w;
        while k <= span - w {
            let ku = k as usize;
            for k1 in (k - w)..=(k + w) {
                smoothed[ku] += sssu[k1 as usize] as f64;
            }
            smoothed[ku] /= (2 * w + 1) as f64;
            k += 1;
        }
        use std::f64::consts::PI;
        for (k, slot) in template.iter_mut().enumerate().take(tl - 1).skip(1) {
            let x = (k as f64 / (tl - 1) as f64) * 3.0 * PI - 2.0 * PI;
            let value = 2.0 / 3.0 * (-0.5894) * (heav(x + 2.0 * PI) - heav(x + (PI / 2.0)))
                + (heav(x + (PI / 2.0)) - heav(x)) * ((2.0 * x).sin() / (2.0 * x))
                + (heav(x) - heav(x - PI / 2.0)) * ((2.0 * x).sin() / (2.0 * x));
            *slot = value;
        }
        let mut sum = 0.0;
        for &v in &template {
            sum += v;
        }
        let mean = sum / tl as f64;
        let mut peak_value = 0.0;
        let mut peak_idx = 0usize;
        for k in 0..tl - 1 {
            template[k] -= mean;
            if template[k] > peak_value {
                peak_idx = k;
                peak_value = template[k];
            }
        }
        if nbins > tl {
            for k in 0..(nbins - tl) {
                let mut v = 0.0;
                for k1 in 0..tl {
                    v += template[k1] * smoothed[k + k1];
                }
                matched[k + peak_idx] = v;
            }
        }
        let mut pib: i16 = 0;
        let mut peak = 0.0;
        for (k, &m) in matched.iter().enumerate() {
            if m > peak {
                peak = m;
                pib = (k as i32 + c.ss_su_min as i32) as i16;
            }
        }
        self.set_pib(pib);
    }
}

/// Runs NeuroLoopGain on one signal (physical units, as stored in the EDF)
/// sampled at `samples_per_record / record_duration` Hz.
pub fn analyse(
    signal: &[f64],
    samples_per_record: usize,
    record_duration: f64,
    cfg: &NlgConfig,
) -> Result<NlgTraces> {
    let mut cfg = cfg.clone();
    if samples_per_record == 0 || record_duration <= 0.0 {
        bail!("invalid EDF data-record geometry");
    }
    let fs = samples_per_record as f64 / record_duration;
    let undersampler = auto_undersampler(fs, &cfg)?;
    if !(1.0 / cfg.smooth_time <= fs && 1.0 / cfg.smooth_time >= 1.0) {
        bail!("analysis time should be between {} and 1 s", 1.0 / fs);
    }
    cfg.iir_undersampler = undersampler;

    // Output geometry (PrepareEDFFiles).
    let out_rate = round_nearest(1.0 / cfg.smooth_time) as f64;
    let sfrecs = vec![out_rate; 14];
    let duration = output_record_duration(&sfrecs)?;
    cfg.smooth_time = 1.0 / out_rate;
    let block = {
        let n = duration * out_rate;
        n.trunc() as usize
    };
    if block == 0 {
        bail!("invalid NeuroLoopGain output block size");
    }

    // SU / SS reduction (DoSSSUReduction).
    let f_compute = fs / undersampler as f64;
    if c_int(f_compute.trunc()) <= 0 {
        bail!("the under-sampled frequency should be >= 1 Hz");
    }
    let delta = 1.0 / f_compute;
    let mut due = DueFilter::new(f_compute, cfg.fc);
    let mut se = SeFilter::new(f_compute, cfg.fc, cfg.f0, cfg.bandwidth, cfg.iir_backpolate);
    let lc = LogConv { y0: cfg.log_float_y0, a: cfg.log_float_a };
    let mut su_trace: Vec<i16> = Vec::with_capacity(signal.len() / (fs as usize).max(1) + block);
    let mut ss_trace: Vec<i16> = Vec::with_capacity(su_trace.capacity());
    let mut under = 1;
    let (mut su_acc, mut ss_acc, mut integrated, mut count) = (0.0_f64, 0.0_f64, 0.0_f64, 0_i32);
    let n_records = signal.len() / samples_per_record;
    for &x in &signal[..n_records * samples_per_record] {
        if under == undersampler {
            under = 1;
            let du = due.step(x);
            let s = se.step(x);
            su_acc += du * s;
            ss_acc += s.powf(2.0) * delta;
            integrated += delta;
            count += 1;
            if integrated >= cfg.smooth_time {
                let norm = count as f64 * delta;
                su_acc /= norm;
                ss_acc /= norm;
                count = 0;
                integrated -= cfg.smooth_time;
                su_trace.push(lc.log(su_acc));
                ss_trace.push(lc.log(ss_acc));
                su_acc = 0.0;
                ss_acc = 0.0;
            }
        } else {
            under += 1;
        }
    }
    let recorded = su_trace.len();
    let n_blocks = recorded.div_ceil(block).max(1);
    let n_total = n_blocks * block;
    su_trace.resize(n_total, 0);
    ss_trace.resize(n_total, 0);
    let mut traces = vec![vec![0_i16; n_total]; 15];
    traces[SU] = su_trace;
    traces[SS] = ss_trace;

    let mut a = Analyser {
        cfg: cfg.clone(),
        lc,
        t: traces,
        n_total: n_total as i64,
        pib_log: 0,
        pib: 0.0,
        su_smooth: 0.0,
        ss_smooth: 0.0,
        art_hf: 0,
        art_lf: 0,
        art_zero: 0,
        su_forw: vec![],
        su_back: vec![],
        ss_forw: vec![],
        ss_back: vec![],
        last_jump: McJump::default(),
        mc_event_samples: 1,
        min_samples_between_jumps: 0,
        max_samples_half_jump: 0,
        mc_jump_threshold: 0.0,
        mc_event_threshold: 0,
    };
    a.detect_pib();
    a.mc_smooth(SmoothOption::GetArtifactsResetAll)?;
    a.mc_smooth(SmoothOption::Smooth)?;
    a.mc_smooth(SmoothOption::DetectEventsResetJumps)?;
    a.mc_smooth(SmoothOption::Smooth)?;
    a.mc_smooth(SmoothOption::SmoothResetAtJumps)?;
    a.mc_smooth(SmoothOption::SmoothResetAtJumps)?;
    a.mc_smooth(SmoothOption::SmoothResetAtJumps)?;

    Ok(NlgTraces {
        config: cfg,
        undersampler,
        f_compute,
        output_rate: out_rate,
        block_samples: block,
        pib_log: a.pib_log,
        pib: a.pib,
        recorded_samples: recorded,
        traces: a.t,
    })
}

/// Writes the 14 traces as an EDF file laid out like the reference output
/// (so the file opens in Polyman / EDFbrowser as before).
pub fn write_reference_edf(path: &std::path::Path, tr: &NlgTraces, unit: &str, start_date: &str, start_time: &str) -> Result<()> {
    use std::io::Write;
    let ns = 14usize;
    let block = tr.block_samples;
    let n_records = tr.traces[MC].len() / block;
    let duration = block as f64 / tr.output_rate;
    let mut h = String::new();
    let pad = |s: &str, w: usize| -> String {
        let mut v: String = s.chars().take(w).collect();
        while v.len() < w {
            v.push(' ');
        }
        v
    };
    h += &pad("0", 8);
    h += &pad("X X X X", 80);
    h += &pad(&format!("Startdate X NeuroLoop-gain analysis at {:.1}Hz", tr.output_rate), 80);
    h += &pad(start_date, 8);
    h += &pad(start_time, 8);
    h += &pad(&((ns + 1) * 256).to_string(), 8);
    h += &pad("", 44);
    h += &pad(&n_records.to_string(), 8);
    h += &pad(&format!("{}", duration), 8);
    h += &pad(&ns.to_string(), 4);
    let labels: Vec<String> = TRACE_LABELS
        .iter()
        .enumerate()
        .map(|(k, l)| if k < 8 { format!("{l} {unit}**2/x") } else { (*l).to_string() })
        .collect();
    for l in &labels {
        h += &pad(l, 16);
    }
    let transducer = format!(
        "fCompute/fc/f0/B={:.3}/{:.3}/{:.3}/{:.3}Hz.",
        tr.f_compute, tr.config.fc, tr.config.f0, tr.config.bandwidth
    );
    for _ in 0..ns {
        h += &pad(&transducer, 80);
    }
    for k in 0..ns {
        h += &pad(if k < 8 { "Filtered" } else if k < 11 { "" } else { "%" }, 8);
    }
    let phys_max = |k: usize| if k >= 11 { 32767.0 / tr.config.mic_gain } else { 32767.0 };
    for k in 0..ns {
        h += &pad(&format!("{}", -phys_max(k)), 8);
    }
    for k in 0..ns {
        h += &pad(&format!("{}", phys_max(k)), 8);
    }
    for _ in 0..ns {
        h += &pad("-32767", 8);
    }
    for _ in 0..ns {
        h += &pad("32767", 8);
    }
    for k in 0..ns {
        let pre = if k < 8 {
            format!("sign*LN[sign*(uV**2/x)/({})]/({})", tr.config.log_float_y0, tr.config.log_float_a)
        } else {
            String::new()
        };
        h += &pad(&pre, 80);
    }
    for _ in 0..ns {
        h += &pad(&block.to_string(), 8);
    }
    for _ in 0..ns {
        h += &pad("", 32);
    }
    let mut f = std::io::BufWriter::new(std::fs::File::create(path)?);
    f.write_all(h.as_bytes())?;
    for r in 0..n_records {
        for k in 0..ns {
            for &v in &tr.traces[k + 1][r * block..(r + 1) * block] {
                f.write_all(&v.to_le_bytes())?;
            }
        }
    }
    Ok(())
}

// ─── summaries ────────────────────────────────────────────────────────────

/// MATLAB `prctile` (linear interpolation between (i-0.5)/n points).
pub fn matlab_prctile(sorted: &[f64], p: f64) -> f64 {
    let n = sorted.len();
    if n == 0 {
        return f64::NAN;
    }
    let pos = p / 100.0 * n as f64 + 0.5; // 1-based position
    if pos <= 1.0 {
        return sorted[0];
    }
    if pos >= n as f64 {
        return sorted[n - 1];
    }
    let lo = pos.floor() as usize;
    let frac = pos - lo as f64;
    sorted[lo - 1] + frac * (sorted[lo] - sorted[lo - 1])
}

/// Mean of the 75th..100th percentiles, the summary gain used by the NIMHANS
/// ACCS NeuroLoopGain script (`mean(prctile(gain, 75:100))`).
pub fn upper_quartile_index(values: &[f64]) -> f64 {
    let mut v: Vec<f64> = values.iter().copied().filter(|x| x.is_finite()).collect();
    if v.is_empty() {
        return f64::NAN;
    }
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let mut s = 0.0;
    for p in 75..=100 {
        s += matlab_prctile(&v, p as f64);
    }
    s / 26.0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn logfloat_roundtrip_matches_reference_rounding() {
        let lc = LogConv { y0: 1e-4, a: 1e-3 };
        assert_eq!(lc.log(0.0), 0);
        assert_eq!(lc.log(1e-4), 0);
        let v = lc.exp(1234);
        assert_eq!(lc.log(v), 1234);
        assert_eq!(lc.log(-v), -1234);
        assert_eq!(lc.log(1e30), i16::MAX);
    }

    #[test]
    fn one_hz_output_uses_half_hour_records() {
        let d = output_record_duration(&vec![1.0; 14]).unwrap();
        assert_eq!(d, 1800.0);
    }

    #[test]
    fn auto_undersampler_matches_gui() {
        let cfg = NlgConfig { f0: 14.0, bandwidth: 3.5, ..Default::default() };
        assert_eq!(auto_undersampler(250.0, &cfg).unwrap(), 5);
        assert_eq!(auto_undersampler(256.0, &cfg).unwrap(), 5);
        let sw = NlgConfig::default();
        assert_eq!(auto_undersampler(200.0, &sw).unwrap(), 4);
    }

    #[test]
    fn prctile_matches_matlab() {
        let v = vec![1.0, 2.0, 3.0, 4.0];
        assert!((matlab_prctile(&v, 50.0) - 2.5).abs() < 1e-12);
        assert_eq!(matlab_prctile(&v, 100.0), 4.0);
        assert!((matlab_prctile(&v, 75.0) - 3.5).abs() < 1e-12);
    }

    #[test]
    fn synthetic_signal_runs() {
        let fs = 100.0;
        let n = (fs * 3600.0) as usize;
        let mut seed = 12345u64;
        let mut noise = || {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            ((seed >> 11) as f64 / (1u64 << 53) as f64) - 0.5
        };
        let x: Vec<f64> = (0..n)
            .map(|i| {
                let t = i as f64 / fs;
                40.0 * (2.0 * std::f64::consts::PI * 1.0 * t).sin() * (1.0 + (t / 600.0).sin()) + 20.0 * noise()
            })
            .collect();
        let tr = analyse(&x, 100, 1.0, &NlgConfig::default()).unwrap();
        assert_eq!(tr.traces[MC].len() % tr.block_samples, 0);
        assert!(tr.pib > 0.0);
        let g = tr.gain_percent();
        assert!(g[..tr.recorded_samples].iter().any(|&v| v > 0.0));
    }
}

// ─── whole-recording analysis (AnalyseNidra / Utilities) ───────────────────

use crate::hypnogram::Stage;
use rayon::prelude::*;
use std::collections::BTreeMap;
use std::path::Path;

/// Options for [`analyse_recording`].
#[derive(Debug, Clone)]
pub struct NlgOptions {
    pub bands: Vec<NlgBand>,
    /// 0 = automatic (reference GUI rule); otherwise the /UNDERSAMPLE value.
    pub undersampler: i32,
    /// Lowest low-pass filter of the recording (Hz); `None` = read from the
    /// EDF pre-filter field or Nyquist.
    pub lp_hz: Option<f64>,
    /// Also keep the 1-s gain / artifact traces in the report.
    pub keep_series: bool,
    /// Folder for Polyman-compatible `<stem>_<channel>_<band>_NeuroLoopGain.edf` files.
    pub write_edf_dir: Option<std::path::PathBuf>,
}

impl Default for NlgOptions {
    fn default() -> Self {
        Self {
            bands: vec![NlgBand::slow_wave(0.01666), NlgBand::sigma(0.01666)],
            undersampler: 0,
            lp_hz: None,
            keep_series: true,
            write_edf_dir: None,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct NlgPeriod {
    pub label: String,
    pub start_s: f64,
    pub end_s: f64,
    pub nrem_gain: Option<f64>,
    pub nrem_seconds: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct NlgBandResult {
    pub band: NlgBand,
    pub undersampler: i32,
    pub f_compute_hz: f64,
    pub output_rate_hz: f64,
    /// piB (physical, signal unit^2) and its log-converted value.
    pub pib: f64,
    pub pib_log: i16,
    pub recorded_seconds: usize,
    /// Summary statistics (gain in %).
    pub summary: BTreeMap<String, f64>,
    /// Mean gain (%) of the artifact-free seconds of each 30-s epoch.
    pub epoch_gain: Vec<Option<f64>>,
    /// Gain per output sample x mic_gain (digital `MC (Gain)` trace).
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub gain_x10: Vec<i16>,
    /// 1 = sample rejected (HF/LF artifact, missing signal or MC event).
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub artifact: Vec<u8>,
    pub hourly: Vec<NlgPeriod>,
    pub cycles: Vec<NlgPeriod>,
}

#[derive(Debug, Clone, Serialize)]
pub struct NlgReport {
    pub analysis: &'static str,
    pub method: &'static str,
    pub reference: &'static str,
    pub references: Vec<String>,
    pub epoch_seconds: f64,
    /// channel -> band name -> result
    pub channels: BTreeMap<String, BTreeMap<String, NlgBandResult>>,
    /// Mean of the channel summaries (per band).
    pub average: BTreeMap<String, BTreeMap<String, f64>>,
    pub warnings: Vec<String>,
}

fn stage_key(s: Stage) -> Option<&'static str> {
    match s {
        Stage::Wake => Some("W"),
        Stage::N1 => Some("N1"),
        Stage::N2 => Some("N2"),
        Stage::N3 => Some("N3"),
        Stage::Rem => Some("REM"),
        Stage::Unscored => None,
    }
}

fn mean_of(v: &[f64]) -> Option<f64> {
    if v.is_empty() { None } else { Some(v.iter().sum::<f64>() / v.len() as f64) }
}

fn linear_slope(x: &[f64], y: &[f64]) -> f64 {
    let n = x.len() as f64;
    if x.len() < 3 {
        return f64::NAN;
    }
    let mx = x.iter().sum::<f64>() / n;
    let my = y.iter().sum::<f64>() / n;
    let (mut sxy, mut sxx) = (0.0, 0.0);
    for (a, b) in x.iter().zip(y) {
        sxy += (a - mx) * (b - my);
        sxx += (a - mx) * (a - mx);
    }
    if sxx > 0.0 { sxy / sxx } else { f64::NAN }
}

/// Builds the summary of one band from the traces and the hypnogram.
fn summarise(tr: &NlgTraces, band: &NlgBand, stages: Option<&[Stage]>, epoch_seconds: f64, keep_series: bool) -> NlgBandResult {
    let gain = tr.gain_percent();
    let art = tr.artifact_flags();
    let dt = 1.0 / tr.output_rate;
    let n = tr.recorded_samples.min(gain.len());
    let stage_at = |i: usize| -> Option<Stage> {
        let st = stages?;
        let e = ((i as f64 + 0.5) * dt / epoch_seconds).floor() as usize;
        st.get(e).copied()
    };
    let mut by_stage: BTreeMap<&str, Vec<f64>> = BTreeMap::new();
    let mut clean_all = Vec::new();
    let mut nrem_t = Vec::new();
    let mut nrem_g = Vec::new();
    let mut n_art = 0usize;
    for i in 0..n {
        if art[i] {
            n_art += 1;
            continue;
        }
        clean_all.push(gain[i]);
        if let Some(s) = stage_at(i) {
            if let Some(k) = stage_key(s) {
                by_stage.entry(k).or_default().push(gain[i]);
                if matches!(s, Stage::N2 | Stage::N3) {
                    by_stage.entry("NREM").or_default().push(gain[i]);
                    nrem_t.push(i as f64 * dt / 3600.0);
                    nrem_g.push(gain[i]);
                }
            }
        }
    }
    let mut summary = BTreeMap::new();
    for k in ["W", "N1", "N2", "N3", "REM", "NREM"] {
        let v = by_stage.get(k).map(Vec::as_slice).unwrap_or(&[]);
        summary.insert(format!("{k}_mean"), mean_of(v).unwrap_or(f64::NAN));
        let mut s = v.to_vec();
        s.sort_by(|a, b| a.partial_cmp(b).unwrap());
        summary.insert(format!("{k}_median"), matlab_prctile(&s, 50.0));
        summary.insert(format!("{k}_seconds"), v.len() as f64);
    }
    summary.insert("all_clean_mean".into(), mean_of(&clean_all).unwrap_or(f64::NAN));
    summary.insert("artifact_percent".into(), if n > 0 { 100.0 * n_art as f64 / n as f64 } else { f64::NAN });
    // ACCS/MATLAB summary: mean(prctile(gain, 75:100)) of the whole output
    // file (as read back from the NeuroLoopGain EDF, including padding).
    summary.insert("upper_quartile_index".into(), upper_quartile_index(&gain));
    summary.insert("upper_quartile_index_recorded".into(), upper_quartile_index(&gain[..n]));
    summary.insert("NREM_slope_per_hour".into(), linear_slope(&nrem_t, &nrem_g));
    summary.insert("pib".into(), tr.pib);

    // Epoch series.
    let spe = (epoch_seconds * tr.output_rate).round().max(1.0) as usize;
    let n_epochs = n.div_ceil(spe);
    let epoch_gain = (0..n_epochs)
        .map(|e| {
            let vals: Vec<f64> = (e * spe..((e + 1) * spe).min(n)).filter(|&i| !art[i]).map(|i| gain[i]).collect();
            mean_of(&vals).map(|v| (v * 100.0).round() / 100.0)
        })
        .collect();

    // Hourly and per-cycle NREM means.
    let period = |label: String, a: f64, b: f64| -> NlgPeriod {
        let lo = (a / dt).floor().max(0.0) as usize;
        let hi = ((b / dt).ceil() as usize).min(n);
        let vals: Vec<f64> = (lo..hi)
            .filter(|&i| !art[i] && matches!(stage_at(i), Some(Stage::N2 | Stage::N3)))
            .map(|i| gain[i])
            .collect();
        NlgPeriod { label, start_s: a, end_s: b, nrem_gain: mean_of(&vals), nrem_seconds: vals.len() }
    };
    let total_s = n as f64 * dt;
    let mut hourly = Vec::new();
    if stages.is_some() {
        let mut h = 0.0;
        while h < total_s {
            hourly.push(period(format!("{}", (h / 3600.0) as usize + 1), h, (h + 3600.0).min(total_s)));
            h += 3600.0;
        }
    }
    let mut cycles = Vec::new();
    if let Some(st) = stages {
        if let Some(acc) = crate::accs::analyse(st) {
            for (k, (&s, &e)) in acc.cycle_starts.iter().zip(&acc.cycle_ends).enumerate() {
                let a = (s.saturating_sub(1)) as f64 * epoch_seconds;
                let b = e as f64 * epoch_seconds;
                cycles.push(period(format!("C{}", k + 1), a, b));
            }
        }
    }
    for (k, c) in cycles.iter().enumerate().take(5) {
        summary.insert(format!("C{}_NREM_mean", k + 1), c.nrem_gain.unwrap_or(f64::NAN));
    }
    NlgBandResult {
        band: band.clone(),
        undersampler: tr.undersampler,
        f_compute_hz: tr.f_compute,
        output_rate_hz: tr.output_rate,
        pib: tr.pib,
        pib_log: tr.pib_log,
        recorded_seconds: n,
        summary,
        epoch_gain,
        gain_x10: if keep_series { tr.traces[MC][..n].to_vec() } else { vec![] },
        artifact: if keep_series { art[..n].iter().map(|&a| a as u8).collect() } else { vec![] },
        hourly,
        cycles,
    }
}

fn unit_scale(unit: &str) -> f64 {
    match unit.trim() {
        "V" | "v" => 1e6,
        "mV" | "mv" | "MV" => 1e3,
        "nV" | "nv" => 1e-3,
        _ => 1.0,
    }
}

/// Runs NeuroLoopGain on every channel (re-referenced to the mean of
/// `references`; a label like `C4-M1` is also accepted) for every band.
pub fn analyse_recording(
    edf_path: &Path,
    stages: Option<&[Stage]>,
    channels: &[String],
    references: &[String],
    opts: &NlgOptions,
) -> Result<NlgReport> {
    let mut warnings = Vec::new();
    // Resolve derivations.
    let mut derivs: Vec<(String, String, Vec<String>)> = Vec::new();
    for ch in channels {
        if let Some((a, b)) = ch.split_once('-').filter(|(a, b)| !a.is_empty() && !b.is_empty() && !references.iter().any(|r| r.eq_ignore_ascii_case(ch))) {
            if crate::edf::read_signals_kemp(edf_path, &[ch.clone()])?.remove(0).is_some() {
                derivs.push((ch.clone(), ch.clone(), vec![]));
            } else {
                derivs.push((ch.clone(), a.to_string(), vec![b.to_string()]));
            }
        } else {
            let refs: Vec<String> = references.iter().filter(|r| !r.eq_ignore_ascii_case(ch)).cloned().collect();
            derivs.push((ch.clone(), ch.clone(), refs));
        }
    }
    let mut wanted: Vec<String> = Vec::new();
    for (_, a, refs) in &derivs {
        for l in std::iter::once(a).chain(refs.iter()) {
            if !wanted.iter().any(|w| w.eq_ignore_ascii_case(l)) {
                wanted.push(l.clone());
            }
        }
    }
    let sigs = crate::edf::read_signals_kemp(edf_path, &wanted)?;
    let get = |l: &str| -> Option<&crate::edf::KempSignal> {
        wanted.iter().position(|w| w.eq_ignore_ascii_case(l)).and_then(|i| sigs[i].as_ref())
    };
    let mut jobs: Vec<(String, Vec<f64>, usize, f64, String, String)> = Vec::new();
    for (name, a, refs) in &derivs {
        let Some(sa) = get(a) else {
            warnings.push(format!("{name}: channel {a} not found; skipped"));
            continue;
        };
        let scale = unit_scale(&sa.unit);
        let mut x: Vec<f64> = if scale == 1.0 { sa.data.clone() } else { sa.data.iter().map(|v| v * scale).collect() };
        let refsigs: Vec<&crate::edf::KempSignal> = refs.iter().filter_map(|r| get(r)).collect();
        if refsigs.len() != refs.len() {
            warnings.push(format!("{name}: reference channel(s) missing; analysed without them"));
        }
        let refsigs: Vec<&crate::edf::KempSignal> =
            refsigs.into_iter().filter(|r| r.samples_per_record == sa.samples_per_record && r.data.len() == sa.data.len()).collect();
        if !refsigs.is_empty() {
            let k = refsigs.len() as f64;
            for (i, v) in x.iter_mut().enumerate() {
                let r: f64 = refsigs.iter().map(|s| s.data[i] * unit_scale(&s.unit)).sum::<f64>() / k;
                *v -= r;
            }
        }
        let label = if refsigs.is_empty() { a.clone() } else { format!("{a}-{}", refs.join("/")) };
        jobs.push((name.clone(), x, sa.samples_per_record, sa.record_duration, sa.prefilter.clone(), label));
    }
    if jobs.is_empty() {
        bail!("none of the requested EEG channels were found for NeuroLoopGain");
    }
    let epoch_seconds = 30.0;
    let tasks: Vec<(usize, usize)> = (0..jobs.len()).flat_map(|j| (0..opts.bands.len()).map(move |b| (j, b))).collect();
    let results: Vec<(usize, usize, Result<NlgBandResult>)> = tasks
        .par_iter()
        .map(|&(j, b)| {
            let (name, x, spr, dur, prefilter, _) = &jobs[j];
            let band = &opts.bands[b];
            let fs = *spr as f64 / dur;
            let cfg = NlgConfig {
                f0: band.f0,
                bandwidth: band.bandwidth,
                fc: band.fc,
                smooth_rate: band.smooth_rate,
                iir_undersampler: opts.undersampler,
                lp_hz: opts.lp_hz.or_else(|| lp_from_prefilter(prefilter, fs)),
                ..Default::default()
            };
            let r = analyse(x, *spr, *dur, &cfg).map(|tr| {
                if let Some(dir) = &opts.write_edf_dir {
                    let stem = edf_path.file_stem().and_then(|s| s.to_str()).unwrap_or("recording");
                    let p = dir.join(format!("{stem}_{}_{}_NeuroLoopGain.edf", name.replace(['/', '\\'], "_"), band.name));
                    let _ = write_reference_edf(&p, &tr, "uV", "01.01.00", "00.00.00");
                }
                summarise(&tr, band, stages, epoch_seconds, opts.keep_series)
            });
            (j, b, r)
        })
        .collect();
    let mut out: BTreeMap<String, BTreeMap<String, NlgBandResult>> = BTreeMap::new();
    for (j, b, r) in results {
        match r {
            Ok(v) => {
                out.entry(jobs[j].0.clone()).or_default().insert(opts.bands[b].name.clone(), v);
            }
            Err(e) => warnings.push(format!("{} {}: {e}", jobs[j].5, opts.bands[b].name)),
        }
    }
    let mut average: BTreeMap<String, BTreeMap<String, f64>> = BTreeMap::new();
    for band in &opts.bands {
        let rows: Vec<&BTreeMap<String, f64>> = out.values().filter_map(|m| m.get(&band.name)).map(|r| &r.summary).collect();
        if rows.is_empty() {
            continue;
        }
        let mut avg = BTreeMap::new();
        for k in rows[0].keys() {
            let v: Vec<f64> = rows.iter().filter_map(|r| r.get(k)).copied().filter(|v| v.is_finite()).collect();
            avg.insert(k.clone(), mean_of(&v).unwrap_or(f64::NAN));
        }
        average.insert(band.name.clone(), avg);
    }
    Ok(NlgReport {
        analysis: "neuroloopgain",
        method: "NeuroLoopGain 2.x port (Kemp et al. 2000), 1-s gain traces; summaries over artifact-free seconds",
        reference: "Kemp B, Zwinderman AH, Tuk B, Kamphuisen HAC, Oberyé JJL. Analysis of a sleep-dependent neuronal feedback loop: the slow-wave microcontinuity of the EEG. IEEE Trans Biomed Eng 2000;47(9):1185-1194.",
        references: references.to_vec(),
        epoch_seconds,
        channels: out,
        average,
        warnings,
    })
}
