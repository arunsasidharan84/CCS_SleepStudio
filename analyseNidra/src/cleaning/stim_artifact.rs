//! Stimulation artefact removal (deep brain stimulation and other periodic neurostimulators).
//!
//! DBS pulses (~130–185 Hz) lie far above the EEG band, but PSG amplifiers alias them down to a
//! low "beat" frequency `f0` (e.g. 2.04, 2.21, 3.00 or 17.99 Hz) plus its harmonics. The result is
//! a large, strictly periodic waveform on every channel whose frequency drifts only very slowly
//! through the night. A broad notch or band-stop filter would remove delta/theta/alpha/spindle
//! activity along with it, so this module uses an *adaptive harmonic comb* instead:
//!
//! 1. Whole-recording median-Welch PSD (0.01 Hz resolution) of every channel. The artefact
//!    fundamental is the strongest narrow spectral line, checked against sub-harmonics and refined
//!    from the positions of its harmonics.
//! 2. `f0` is tracked in 2-min blocks by maximising the multi-harmonic energy of the most-affected
//!    channels. Unreliable blocks (flat/paused recording, stimulator off) are interpolated, the
//!    track is median-smoothed and integrated into an artefact phase `phi(t)`.
//! 3. For every affected channel and harmonic `k`, `x(t)·exp(-i2πk·phi(t))` is averaged over
//!    ~20 s (boxcar applied twice, movement bursts down-weighted) to give a slowly varying complex
//!    amplitude `a_k(t)`. The artefact `Σ 2·Re{a_k(t)·exp(i2πk·phi(t))}` is subtracted, i.e. each
//!    harmonic is removed with a narrow (~0.07 Hz noise-bandwidth) notch that follows the drift.
//! 4. The residual spectrum is searched again for further combs (e.g. bilateral stimulators at
//!    slightly different rates, or sidebands), up to `max_families`.
//!
//! Only channels whose spectrum shows the comb are modified.
//! Port of `dbs_artifact_removal.py` v1.1 (NIMHANS DBS sleep study, Sep 2026).

use num_complex::Complex64;
use rayon::prelude::*;
use rustfft::FftPlanner;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::f64::consts::PI;

#[derive(Debug, Clone)]
pub struct StimArtifactConfig {
    /// Amplitude-tracking window in seconds (notch half-width ≈ 0.3 / win_sec Hz).
    pub win_sec: f64,
    /// Force the artefact fundamental (Hz) instead of auto-detection (first comb only).
    pub f0_hz: Option<f64>,
    /// Minimum mean prominence (dB) of the first 3 harmonics for a channel to be cleaned.
    pub chan_thr_db: f64,
    /// Minimum line prominence (dB) to declare the first artefact comb.
    pub min_prom_db: f64,
    /// Minimum line prominence (dB) for additional combs.
    pub min_prom_next_db: f64,
    /// Maximum number of independent combs to remove.
    pub max_families: usize,
    /// Robust-SD threshold above which samples are down-weighted as movement artefact.
    pub move_thr: f64,
    /// Exclude 49.5–50.5 and 59.5–60.5 Hz from fundamental detection (mains is handled by the notch).
    pub exclude_line_noise: bool,
    /// Search range for the fundamental (Hz).
    pub fmin_hz: f64,
    pub fmax_hz: f64,
    /// PSD frequency resolution (Hz).
    pub psd_resolution_hz: f64,
    /// Block length for frequency tracking (s).
    pub track_block_sec: f64,
}

impl Default for StimArtifactConfig {
    fn default() -> Self {
        Self {
            win_sec: 20.0,
            f0_hz: None,
            chan_thr_db: 6.0,
            min_prom_db: 10.0,
            min_prom_next_db: 12.0,
            max_families: 3,
            move_thr: 6.0,
            exclude_line_noise: true,
            fmin_hz: 0.3,
            fmax_hz: 40.0,
            psd_resolution_hz: 0.01,
            track_block_sec: 120.0,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StimFamily {
    pub f0_hz: f64,
    pub f0_min_hz: f64,
    pub f0_max_hz: f64,
    pub line_prominence_db: f64,
    pub n_harmonics: usize,
    pub channels: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct StimArtifactReport {
    pub families: Vec<StimFamily>,
    pub cleaned_channels: Vec<String>,
    /// RMS of the removed artefact per channel (µV, all combs combined).
    pub artefact_rms_uv: BTreeMap<String, f64>,
    /// Prominence (dB above local background) of the first harmonic of the first comb.
    pub harmonic1_prominence_before_db: BTreeMap<String, f64>,
    pub harmonic1_prominence_after_db: BTreeMap<String, f64>,
}

// ----------------------------------------------------------------------------- spectra

/// PSD on a uniform grid `f_i = i·df`, limited to `f <= fmax` (dB).
struct Spectrum {
    df: f64,
    db: Vec<f64>,
}

impl Spectrum {
    fn freq(&self, i: usize) -> f64 {
        i as f64 * self.df
    }
}

/// Whole-recording median-Welch PSD in dB (Hann, 50 % overlap, constant detrend), bins up to `fmax`.
fn welch_median_db(x: &[f64], fs: f64, res: f64, fmax: f64) -> Spectrum {
    let nper = ((fs / res).round() as usize).min(x.len()).max(16);
    let step = (nper / 2).max(1);
    let nseg = if x.len() >= nper {
        (x.len() - nper) / step + 1
    } else {
        1
    };
    let nfreq_full = nper / 2 + 1;
    let df = fs / nper as f64;
    let nbin = ((fmax / df).floor() as usize + 1).min(nfreq_full);

    let window: Vec<f64> = (0..nper)
        .map(|n| 0.5 - 0.5 * (2.0 * PI * n as f64 / nper as f64).cos())
        .collect();
    let wss: f64 = window.iter().map(|w| w * w).sum();
    let scale = 1.0 / (fs * wss);

    let mut planner = FftPlanner::<f64>::new();
    let fft = planner.plan_fft_forward(nper);
    // layout [bin][segment] for the per-bin median
    let mut table = vec![0f32; nbin * nseg];
    let mut buf = vec![Complex64::new(0.0, 0.0); nper];
    for s in 0..nseg {
        let start = s * step;
        let seg = &x[start..(start + nper).min(x.len())];
        let mean = seg.iter().sum::<f64>() / seg.len() as f64;
        for n in 0..nper {
            let v = if n < seg.len() { seg[n] - mean } else { 0.0 };
            buf[n] = Complex64::new(v * window[n], 0.0);
        }
        fft.process(&mut buf);
        for b in 0..nbin {
            let mut p = buf[b].norm_sqr() * scale;
            if b != 0 && !(nper % 2 == 0 && b == nper / 2) {
                p *= 2.0;
            }
            table[b * nseg + s] = p as f32;
        }
    }
    let db = table
        .par_chunks_mut(nseg)
        .map(|col| {
            let mid = col.len() / 2;
            let (_, m, _) = col.select_nth_unstable_by(mid, |a, b| a.partial_cmp(b).unwrap());
            10.0 * (*m as f64 + 1e-20).log10()
        })
        .collect();
    Spectrum { df, db }
}

/// dB height of each bin above a running median baseline of `width_hz` (scipy median_filter, nearest).
fn prominence(spec: &Spectrum, width_hz: f64) -> Vec<f64> {
    let size = (((width_hz / spec.df).round() as usize) | 1).max(3);
    let half = size / 2;
    let n = spec.db.len();
    (0..n)
        .into_par_iter()
        .map(|i| {
            let mut w: Vec<f64> = (0..size)
                .map(|j| {
                    spec.db[(i as isize + j as isize - half as isize).clamp(0, n as isize - 1)
                        as usize]
                })
                .collect();
            let (_, m, _) = w.select_nth_unstable_by(half, |a, b| a.partial_cmp(b).unwrap());
            spec.db[i] - *m
        })
        .collect()
}

fn prom_at(spec: &Spectrum, prom: &[f64], fr: f64, tol: f64) -> f64 {
    let lo = ((fr - tol) / spec.df).ceil().max(0.0) as usize;
    let hi = (((fr + tol) / spec.df).floor() as usize).min(prom.len().saturating_sub(1));
    if lo > hi || lo >= prom.len() {
        return f64::NAN;
    }
    prom[lo..=hi]
        .iter()
        .cloned()
        .fold(f64::NEG_INFINITY, f64::max)
}

fn parabolic_offset(y0: f64, y1: f64, y2: f64) -> f64 {
    0.5 * (y0 - y2) / (y0 - 2.0 * y1 + y2 + 1e-12)
}

/// Least-squares f0 from the peak positions of its first harmonics.
fn refine_f0(spec: &Spectrum, prom: &[f64], f0: f64, fmax: f64, n_harm: usize) -> f64 {
    let (mut num, mut den) = (0.0, 0.0);
    for k in 1..=n_harm {
        let c = k as f64 * f0;
        if c > fmax {
            break;
        }
        let tol = 0.03 * (k as f64).sqrt();
        let lo = ((c - tol) / spec.df).ceil().max(0.0) as usize;
        let hi = (((c + tol) / spec.df).floor() as usize).min(prom.len() - 1);
        if hi < lo + 2 {
            continue;
        }
        let i = (lo..=hi)
            .max_by(|&a, &b| prom[a].partial_cmp(&prom[b]).unwrap())
            .unwrap();
        if prom[i] < 6.0 || i == 0 || i == prom.len() - 1 {
            continue;
        }
        let d = parabolic_offset(prom[i - 1], prom[i], prom[i + 1]).clamp(-1.0, 1.0);
        let fk = spec.freq(i) + d * spec.df;
        let w = 10f64.powf(prom[i] / 10.0);
        let kf = k as f64;
        num += w * kf * fk;
        den += w * kf * kf;
    }
    if den > 0.0 { num / den } else { f0 }
}

/// Strongest narrow line, checked for being a harmonic of a lower fundamental. Returns (f0, prominence).
fn detect_fundamental(
    spec: &Spectrum,
    prom: &[f64],
    fmin: f64,
    fmax: f64,
    exclude: &[(f64, f64)],
    min_prom: f64,
) -> Option<(f64, f64)> {
    let harm_thr = 6.0;
    let mut best_i = None;
    let mut best_v = f64::NEG_INFINITY;
    for i in 1..prom.len().saturating_sub(1) {
        let f = spec.freq(i);
        if f < fmin || f > fmax || exclude.iter().any(|&(lo, hi)| f >= lo && f <= hi) {
            continue;
        }
        if prom[i] > best_v {
            best_v = prom[i];
            best_i = Some(i);
        }
    }
    let i = best_i?;
    if best_v < min_prom {
        return None;
    }
    let fp = spec.freq(i) + parabolic_offset(prom[i - 1], prom[i], prom[i + 1]) * spec.df;
    let mut best = fp;
    for n in (2..=6).rev() {
        let fc = fp / n as f64;
        if fc < fmin {
            continue;
        }
        if (1..=n).all(|k| prom_at(spec, prom, fc * k as f64, 0.03) > harm_thr) {
            best = fc;
            break;
        }
    }
    Some((refine_f0(spec, prom, best, fmax, 10), best_v))
}

// ----------------------------------------------------------------------------- tracking

fn median_filter_nearest(x: &[f64], size: usize) -> Vec<f64> {
    let n = x.len();
    let half = size / 2;
    (0..n)
        .map(|i| {
            let mut w: Vec<f64> = (0..size)
                .map(|j| {
                    x[(i as isize + j as isize - half as isize).clamp(0, n as isize - 1) as usize]
                })
                .collect();
            w.sort_by(|a, b| a.partial_cmp(b).unwrap());
            w[half]
        })
        .collect()
}

/// Σ_ch Σ_k |Σ_n x[n]·exp(-i2πk f n/fs)|² for k = 1..K.
fn harmonic_energy(segs: &[Vec<f64>], fs: f64, f: f64, k_max: usize) -> f64 {
    let w = -2.0 * PI * f / fs;
    let mut e = 0.0;
    for seg in segs {
        let mut acc = vec![Complex64::new(0.0, 0.0); k_max];
        let mut z = Complex64::new(1.0, 0.0);
        let rot = Complex64::from_polar(1.0, w);
        for (n, &v) in seg.iter().enumerate() {
            if n % 1024 == 0 {
                z = Complex64::from_polar(1.0, w * n as f64);
            }
            let mut zk = z;
            for a in acc.iter_mut() {
                *a += zk * v;
                zk *= z;
            }
            z *= rot;
        }
        e += acc.iter().map(|a| a.norm_sqr()).sum::<f64>();
    }
    e
}

/// Per-block f0 (block centres in s, f0 per block).
fn track_f0(ref_sigs: &[&Vec<f64>], fs: f64, f0: f64, block_sec: f64) -> (Vec<f64>, Vec<f64>) {
    const K: usize = 4;
    const SEARCH: f64 = 0.01;
    let n = ref_sigs[0].len();
    let b_len = ((block_sec * fs) as usize).max(1).min(n);
    let nb = (n / b_len).max(1);
    let results: Vec<(f64, f64, f64, bool)> = (0..nb)
        .into_par_iter()
        .map(|b| {
            let segs: Vec<Vec<f64>> = ref_sigs
                .iter()
                .map(|s| {
                    let seg = &s[b * b_len..((b + 1) * b_len).min(s.len())];
                    let m = seg.iter().sum::<f64>() / seg.len() as f64;
                    seg.iter().map(|v| v - m).collect()
                })
                .collect();
            let n_grid = (2.0 * SEARCH / 0.0005).round() as usize + 1;
            let mut g = f0;
            let mut ge = f64::NEG_INFINITY;
            for j in 0..n_grid {
                let f = f0 - SEARCH + j as f64 * 2.0 * SEARCH / (n_grid - 1) as f64;
                let e = harmonic_energy(&segs, fs, f, K);
                if e > ge {
                    ge = e;
                    g = f;
                }
            }
            // golden-section refinement on [g-0.0006, g+0.0006]
            let (mut a, mut c) = (g - 0.0006, g + 0.0006);
            let r = (5f64.sqrt() - 1.0) / 2.0;
            let mut x1 = c - r * (c - a);
            let mut x2 = a + r * (c - a);
            let mut e1 = harmonic_energy(&segs, fs, x1, K);
            let mut e2 = harmonic_energy(&segs, fs, x2, K);
            while c - a > 1e-7 {
                if e1 > e2 {
                    c = x2;
                    x2 = x1;
                    e2 = e1;
                    x1 = c - r * (c - a);
                    e1 = harmonic_energy(&segs, fs, x1, K);
                } else {
                    a = x1;
                    x1 = x2;
                    e1 = e2;
                    x2 = a + r * (c - a);
                    e2 = harmonic_energy(&segs, fs, x2, K);
                }
            }
            let (x, e) = if e1 > e2 { (x1, e1) } else { (x2, e2) };
            let centre = (b as f64 + 0.5) * b_len as f64 / fs;
            (centre, x, e, (x - f0).abs() > SEARCH - 0.001)
        })
        .collect();

    let centres: Vec<f64> = results.iter().map(|r| r.0).collect();
    let mut est: Vec<f64> = results.iter().map(|r| r.1).collect();
    let energy: Vec<f64> = results.iter().map(|r| r.2).collect();
    let mut sorted_e = energy.clone();
    sorted_e.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let med_e = sorted_e[sorted_e.len() / 2];
    let good: Vec<bool> = results.iter().map(|r| !r.3 && r.2 > 0.05 * med_e).collect();
    let good_idx: Vec<usize> = (0..est.len()).filter(|&i| good[i]).collect();
    if good_idx.len() >= 2 && good_idx.len() < est.len() {
        let xs: Vec<f64> = good_idx.iter().map(|&i| i as f64).collect();
        let ys: Vec<f64> = good_idx.iter().map(|&i| est[i]).collect();
        est = (0..est.len()).map(|i| interp(i as f64, &xs, &ys)).collect();
    }
    if est.len() >= 5 {
        let med = median_filter_nearest(&est, 5);
        let cleaned: Vec<f64> = est
            .iter()
            .zip(&med)
            .map(|(&e, &m)| if (e - m).abs() > 0.002 { m } else { e })
            .collect();
        est = median_filter_nearest(&cleaned, 3);
    }
    (centres, est)
}

/// numpy.interp (clamped at the ends, `xs` increasing).
fn interp(x: f64, xs: &[f64], ys: &[f64]) -> f64 {
    if x <= xs[0] {
        return ys[0];
    }
    let last = xs.len() - 1;
    if x >= xs[last] {
        return ys[last];
    }
    let j = xs.partition_point(|&v| v <= x);
    let (x0, x1, y0, y1) = (xs[j - 1], xs[j], ys[j - 1], ys[j]);
    y0 + (y1 - y0) * (x - x0) / (x1 - x0)
}

/// Artefact phase in cycles; phi(0) = 0.
fn phase_track(centres: &[f64], f_blocks: &[f64], n: usize, fs: f64) -> Vec<f64> {
    let mut phi = Vec::with_capacity(n);
    let mut acc = 0.0;
    let mut f_first = 0.0;
    for i in 0..n {
        let f = interp(i as f64 / fs, centres, f_blocks);
        if i == 0 {
            f_first = f;
        }
        acc += f;
        phi.push(acc / fs - f_first / fs);
    }
    phi
}

// ----------------------------------------------------------------------------- removal

fn movement_weights(x: &[f64], fs: f64, thr: f64, pad_sec: f64) -> Vec<f64> {
    let mut tmp = x.to_vec();
    let mid = tmp.len() / 2;
    let med = *tmp
        .select_nth_unstable_by(mid, |a, b| a.partial_cmp(b).unwrap())
        .1;
    for v in tmp.iter_mut() {
        *v = (*v - med).abs();
    }
    let mad = 1.4826
        * *tmp
            .select_nth_unstable_by(mid, |a, b| a.partial_cmp(b).unwrap())
            .1
        + 1e-9;
    let bad: Vec<bool> = x.iter().map(|v| (v - med).abs() > thr * mad).collect();
    if !bad.iter().any(|&b| b) {
        return vec![1.0; x.len()];
    }
    // dilate (scipy uniform_filter1d(bad, size) > 0)
    let size = ((2.0 * pad_sec * fs) as usize).max(1);
    let (left, right) = (size / 2, (size - 1) / 2);
    let n = x.len();
    let mut csum = vec![0usize; n + 1];
    for i in 0..n {
        csum[i + 1] = csum[i] + bad[i] as usize;
    }
    (0..n)
        .map(|i| {
            let lo = i.saturating_sub(left);
            let hi = (i + right).min(n - 1);
            if csum[hi + 1] - csum[lo] > 0 {
                0.0
            } else {
                1.0
            }
        })
        .collect()
}

/// scipy.ndimage.uniform_filter1d(mode="nearest") applied twice (boxcar² → triangular kernel).
fn smooth2(v: &[Complex64], m: usize) -> Vec<Complex64> {
    let mut cur = v.to_vec();
    for _ in 0..2 {
        let n = cur.len();
        let (left, right) = (m / 2, (m - 1) / 2);
        let mut ext = Vec::with_capacity(n + left + right);
        ext.extend(std::iter::repeat(cur[0]).take(left));
        ext.extend_from_slice(&cur);
        ext.extend(std::iter::repeat(cur[n - 1]).take(right));
        let mut csum = vec![Complex64::new(0.0, 0.0); ext.len() + 1];
        for i in 0..ext.len() {
            csum[i + 1] = csum[i] + ext[i];
        }
        cur = (0..n).map(|i| (csum[i + m] - csum[i]) / m as f64).collect();
    }
    cur
}

/// Adaptive harmonic comb: returns the artefact waveform to subtract from `x`.
fn comb_estimate(
    x: &[f64],
    e1: &[Complex64],
    fs: f64,
    f0_mean: f64,
    win_sec: f64,
    w: &[f64],
) -> Vec<f64> {
    let n = x.len();
    let p = ((fs / f0_mean).round() as usize).max(1); // ~1 artefact period per block
    let nb = n.div_ceil(p);
    let m = ((win_sec * fs / p as f64).round() as usize).max(1); // blocks per boxcar
    let k_max = ((fs / 2.0 - 0.25) / f0_mean).floor().max(0.0) as usize;

    let xw: Vec<f64> = x.iter().zip(w).map(|(a, b)| a * b).collect();
    let wb: Vec<Complex64> = (0..nb)
        .map(|b| Complex64::new(w[b * p..((b + 1) * p).min(n)].iter().sum(), 0.0))
        .collect();
    let den: Vec<f64> = smooth2(&wb, m)
        .iter()
        .map(|c| c.re.max(0.05 * p as f64))
        .collect();
    let centres: Vec<f64> = (0..nb)
        .map(|b| (b * p) as f64 + (p as f64 - 1.0) / 2.0)
        .collect();

    let mut art = vec![0.0; n];
    let mut ek: Vec<Complex64> = vec![Complex64::new(1.0, 0.0); n];
    for _k in 1..=k_max {
        ek.par_iter_mut()
            .zip(e1.par_iter())
            .for_each(|(a, b)| *a *= *b);
        let num: Vec<Complex64> = (0..nb)
            .into_par_iter()
            .map(|b| {
                let (lo, hi) = (b * p, ((b + 1) * p).min(n));
                (lo..hi).map(|i| ek[i] * xw[i]).sum()
            })
            .collect();
        let a: Vec<Complex64> = smooth2(&num, m)
            .iter()
            .zip(&den)
            .map(|(c, d)| c / d)
            .collect();
        art.par_chunks_mut(p).enumerate().for_each(|(b, chunk)| {
            for (j, out) in chunk.iter_mut().enumerate() {
                let i = b * p + j;
                let t = i as f64;
                // linear interpolation of the complex amplitude between block centres
                let a_t = if t <= centres[0] {
                    a[0]
                } else if t >= centres[nb - 1] {
                    a[nb - 1]
                } else {
                    let jb = ((t - centres[0]) / p as f64).floor() as usize;
                    let jb = jb.min(nb - 2);
                    let frac = (t - centres[jb]) / p as f64;
                    a[jb] * (1.0 - frac) + a[jb + 1] * frac
                };
                *out += 2.0 * (a_t * ek[i].conj()).re;
            }
        });
    }
    art
}

// ----------------------------------------------------------------------------- entry point

/// Removes periodic stimulation artefact in place from `signals` (µV, all at `fs`).
pub fn remove_stimulation_artifact(
    channel_names: &[String],
    signals: &mut [Vec<f64>],
    fs: f64,
    cfg: &StimArtifactConfig,
) -> StimArtifactReport {
    let mut report = StimArtifactReport::default();
    let n_ch = signals.len();
    if n_ch == 0 || signals[0].len() < (fs * 60.0) as usize {
        println!("  Stimulation artefact removal skipped (recording shorter than 60 s).");
        return report;
    }
    let fmax = cfg.fmax_hz.min(fs / 2.0 - 1.0);
    let spec_fmax = (fmax + 5.0).min(fs / 2.0);
    let compute_spectra = |sigs: &[Vec<f64>], idx: &[usize]| -> Vec<(usize, Spectrum, Vec<f64>)> {
        idx.par_iter()
            .map(|&i| {
                let s = welch_median_db(&sigs[i], fs, cfg.psd_resolution_hz, spec_fmax);
                let p = prominence(&s, 1.0);
                (i, s, p)
            })
            .collect()
    };
    let all: Vec<usize> = (0..n_ch).collect();
    let mut spectra: Vec<Option<(Spectrum, Vec<f64>)>> = (0..n_ch).map(|_| None).collect();
    for (i, s, p) in compute_spectra(signals, &all) {
        spectra[i] = Some((s, p));
    }
    let mut removed_sq = vec![0.0f64; n_ch];
    let mut cleaned = vec![false; n_ch];
    let mut first_f0: Option<f64> = None;

    for fam in 0..cfg.max_families {
        // median spectrum across channels
        let nbin = spectra
            .iter()
            .map(|s| s.as_ref().unwrap().0.db.len())
            .min()
            .unwrap();
        let df = spectra[0].as_ref().unwrap().0.df;
        let med_db: Vec<f64> = (0..nbin)
            .map(|b| {
                let mut v: Vec<f64> = spectra
                    .iter()
                    .map(|s| s.as_ref().unwrap().0.db[b])
                    .collect();
                let mid = v.len() / 2;
                v.sort_by(|a, b| a.partial_cmp(b).unwrap());
                if v.len() % 2 == 0 {
                    0.5 * (v[mid - 1] + v[mid])
                } else {
                    v[mid]
                }
            })
            .collect();
        let med_spec = Spectrum { df, db: med_db };
        let med_prom = prominence(&med_spec, 1.0);

        let mut exclude: Vec<(f64, f64)> = if cfg.exclude_line_noise {
            vec![(49.5, 50.5), (59.5, 60.5)]
        } else {
            vec![]
        };
        for f in &report.families {
            let kmax = (fs / 2.0 / f.f0_hz) as usize;
            for k in 1..=kmax {
                let c = k as f64 * f.f0_hz;
                exclude.push((c - 0.05, c + 0.05));
            }
        }
        let det = match (fam, cfg.f0_hz) {
            (0, Some(f)) => Some((f, prom_at(&med_spec, &med_prom, f, 0.03))),
            _ => detect_fundamental(
                &med_spec,
                &med_prom,
                cfg.fmin_hz,
                fmax,
                &exclude,
                if fam == 0 {
                    cfg.min_prom_db
                } else {
                    cfg.min_prom_next_db
                },
            ),
        };
        let Some((f0, pk)) = det else {
            if fam == 0 {
                println!("  No periodic stimulation artefact detected — channels left unchanged.");
            }
            break;
        };

        let chan_prom: Vec<f64> = (0..n_ch)
            .map(|i| {
                let (s, p) = spectra[i].as_ref().unwrap();
                let vals: Vec<f64> = (1..=3)
                    .map(|k| prom_at(s, p, f0 * k as f64, 0.03))
                    .filter(|v| v.is_finite())
                    .collect();
                if vals.is_empty() {
                    f64::NAN
                } else {
                    vals.iter().sum::<f64>() / vals.len() as f64
                }
            })
            .collect();
        let affected: Vec<usize> = (0..n_ch)
            .filter(|&i| chan_prom[i] > cfg.chan_thr_db)
            .collect();
        if affected.is_empty() {
            break;
        }
        println!(
            "  Comb {}: f0 = {:.4} Hz (line prominence {:.1} dB), {}/{} channels affected",
            fam + 1,
            f0,
            pk,
            affected.len(),
            n_ch
        );
        if fam == 0 {
            first_f0 = Some(f0);
            for i in 0..n_ch {
                let (s, p) = spectra[i].as_ref().unwrap();
                report
                    .harmonic1_prominence_before_db
                    .insert(channel_names[i].clone(), round1(prom_at(s, p, f0, 0.03)));
            }
        }

        // track f0 on the 3 most affected channels
        let mut ranked = affected.clone();
        ranked.sort_by(|&a, &b| chan_prom[b].partial_cmp(&chan_prom[a]).unwrap());
        let refs: Vec<&Vec<f64>> = ranked.iter().take(3).map(|&i| &signals[i]).collect();
        let (centres, fb) = track_f0(&refs, fs, f0, cfg.track_block_sec);
        let f_mean = fb.iter().sum::<f64>() / fb.len() as f64;
        let f_min = fb.iter().cloned().fold(f64::INFINITY, f64::min);
        let f_max = fb.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
        println!(
            "    f0 track {:.5}–{:.5} Hz over {} blocks",
            f_min,
            f_max,
            fb.len()
        );

        let n = signals[0].len();
        let phi = phase_track(&centres, &fb, n, fs);
        let e1: Vec<Complex64> = phi
            .par_iter()
            .map(|&ph| Complex64::from_polar(1.0, -2.0 * PI * ph.fract()))
            .collect();
        drop(phi);
        for &i in &affected {
            let w = movement_weights(&signals[i], fs, cfg.move_thr, 1.0);
            let art = comb_estimate(&signals[i], &e1, fs, f_mean, cfg.win_sec, &w);
            let mut ss = 0.0;
            for (x, a) in signals[i].iter_mut().zip(&art) {
                *x -= a;
                ss += a * a;
            }
            removed_sq[i] += ss / n as f64;
            cleaned[i] = true;
        }
        report.families.push(StimFamily {
            f0_hz: round_to(f_mean, 5),
            f0_min_hz: round_to(f_min, 5),
            f0_max_hz: round_to(f_max, 5),
            line_prominence_db: round1(pk),
            n_harmonics: ((fs / 2.0 - 0.25) / f_mean).floor() as usize,
            channels: affected.iter().map(|&i| channel_names[i].clone()).collect(),
        });
        for (i, s, p) in compute_spectra(signals, &affected) {
            spectra[i] = Some((s, p));
        }
    }

    if let Some(f0) = first_f0 {
        for i in 0..n_ch {
            let (s, p) = spectra[i].as_ref().unwrap();
            report
                .harmonic1_prominence_after_db
                .insert(channel_names[i].clone(), round1(prom_at(s, p, f0, 0.03)));
        }
    }
    for i in 0..n_ch {
        if cleaned[i] {
            report.cleaned_channels.push(channel_names[i].clone());
            report
                .artefact_rms_uv
                .insert(channel_names[i].clone(), round_to(removed_sq[i].sqrt(), 2));
        }
    }
    report
}

fn round_to(v: f64, d: i32) -> f64 {
    let s = 10f64.powi(d);
    (v * s).round() / s
}

fn round1(v: f64) -> f64 {
    if v.is_finite() { round_to(v, 1) } else { 0.0 }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Deterministic pseudo-random normal noise (xorshift + Box–Muller).
    fn noise(n: usize, seed: u64) -> Vec<f64> {
        let mut s = seed;
        let mut next = || {
            s ^= s << 13;
            s ^= s >> 7;
            s ^= s << 17;
            (s >> 11) as f64 / (1u64 << 53) as f64
        };
        (0..n)
            .map(|_| {
                let (u1, u2) = (next().max(1e-12), next());
                (-2.0 * u1.ln()).sqrt() * (2.0 * PI * u2).cos()
            })
            .collect()
    }

    /// Power in [lo, hi] Hz from a full-length FFT.
    fn band_power(x: &[f64], fs: f64, lo: f64, hi: f64) -> f64 {
        let n = x.len();
        let mut buf: Vec<Complex64> = x.iter().map(|&v| Complex64::new(v, 0.0)).collect();
        FftPlanner::<f64>::new()
            .plan_fft_forward(n)
            .process(&mut buf);
        (0..n / 2)
            .filter(|&i| {
                let f = i as f64 * fs / n as f64;
                f >= lo && f <= hi
            })
            .map(|i| buf[i].norm_sqr())
            .sum()
    }

    #[test]
    fn removes_drifting_comb_and_preserves_eeg() {
        let fs = 128.0;
        let n = (fs * 1800.0) as usize; // 30 min
        let names: Vec<String> = (0..4).map(|i| format!("C{i}")).collect();
        let mut eeg: Vec<Vec<f64>> = (0..4)
            .map(|c| noise(n, 7 + c as u64).iter().map(|v| v * 10.0).collect())
            .collect();
        // add a waxing/waning, frequency-wandering ~10 Hz "alpha" rhythm we must keep
        let jitter = noise(n, 1234);
        for ch in eeg.iter_mut() {
            let (mut ph, mut fdev) = (0.0, 0.0);
            for (i, v) in ch.iter_mut().enumerate() {
                let t = i as f64 / fs;
                fdev = 0.999 * fdev + 0.02 * jitter[i];
                ph += 2.0 * PI * (10.0 + fdev.clamp(-1.5, 1.5)) / fs;
                *v += 8.0 * (0.6 + 0.4 * (2.0 * PI * t / 7.3).sin()) * ph.sin();
            }
        }
        let clean = eeg.clone();
        // aliased stimulation comb: f0 drifting 2.2058 -> 2.2062 Hz, 4 harmonics, per-channel gain
        let mut phase = 0.0;
        let mut art = vec![0.0; n];
        for (i, a) in art.iter_mut().enumerate() {
            let f = 2.2058 + 0.0004 * i as f64 / n as f64;
            phase += f / fs;
            let ph = 2.0 * PI * phase;
            *a = 50.0 * ph.sin()
                + 25.0 * (2.0 * ph + 0.3).sin()
                + 12.0 * (3.0 * ph + 1.0).sin()
                + 6.0 * (4.0 * ph).sin();
        }
        for (c, ch) in eeg.iter_mut().enumerate() {
            let g = 0.5 + 0.25 * c as f64;
            for (v, a) in ch.iter_mut().zip(&art) {
                *v += g * a;
            }
        }
        let rep = remove_stimulation_artifact(&names, &mut eeg, fs, &StimArtifactConfig::default());
        assert_eq!(rep.families.len(), 1, "{rep:?}");
        assert!((rep.families[0].f0_hz - 2.206).abs() < 0.001);
        assert_eq!(rep.cleaned_channels.len(), 4);
        for c in 0..4 {
            let resid: f64 = eeg[c]
                .iter()
                .zip(&clean[c])
                .map(|(a, b)| (a - b).powi(2))
                .sum::<f64>()
                / n as f64;
            let art_pow: f64 =
                art.iter().map(|a| a * a).sum::<f64>() / n as f64 * (0.5 + 0.25 * c as f64).powi(2);
            let atten_db = 10.0 * (art_pow / resid).log10();
            assert!(
                atten_db > 12.0,
                "channel {c}: only {atten_db:.1} dB attenuation"
            );
            for (lo, hi) in [
                (0.5, 4.0),
                (4.0, 8.0),
                (8.0, 12.0),
                (12.0, 16.0),
                (16.0, 30.0),
            ] {
                let before = band_power(&clean[c], fs, lo, hi);
                let after = band_power(&eeg[c], fs, lo, hi);
                let change = after / before - 1.0;
                // each harmonic notch removes ~0.07 Hz of background, i.e. ~2 % per harmonic inside a 4-Hz band
                assert!(
                    change.abs() < 0.05,
                    "{lo}-{hi} Hz power changed by {:.1} %",
                    100.0 * change
                );
            }
        }
    }

    #[test]
    fn leaves_clean_recording_untouched() {
        let fs = 128.0;
        let n = (fs * 900.0) as usize;
        let names: Vec<String> = (0..3).map(|i| format!("C{i}")).collect();
        let mut eeg: Vec<Vec<f64>> = (0..3).map(|c| noise(n, 99 + c as u64)).collect();
        let orig = eeg.clone();
        let rep = remove_stimulation_artifact(&names, &mut eeg, fs, &StimArtifactConfig::default());
        assert!(rep.families.is_empty());
        assert_eq!(eeg, orig);
    }
}
