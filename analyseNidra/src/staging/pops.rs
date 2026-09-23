//! Native port of Luna's POPS stager (`RUN-POPS lib=s2`), replacing the
//! lunapi dependency of the retired Python backend.
//!
//! Pipeline (mirrors luna-base `proc_runpops` + `pops_indiv_t`):
//!  1. derivation -> 128 Hz (libsamplerate sinc), Kaiser-window FIR
//!     band-pass 0.3-35 Hz (tw = 0.2 Hz, ripple = 0.01)       -> CEN
//!  2. per-30 s-epoch robust standardisation (winsor 0.002)  -> ZEN
//!  3. level-1: Welch log-PSD (SPEC) and relative log-PSD (RSPEC) for CEN and
//!     ZEN (0.75-25 Hz, 4 s Tukey(0.5) segments, 2 s step, median), plus
//!     Petrosian FD, permutation entropy (m = 4) and legacy Hjorth on ZEN
//!  4. epoch outliers (misc block, 10 SD), SVD projection with the trained
//!     V/W matrices, triangular smoothing, robust NORM, time track
//!  5. feature ranges (4 SD, > 33 % -> drop) and the trained LightGBM model.
//!
//! EDGER trimming is not ported: it only ever *narrows* the scored window
//! and never changes posteriors of the retained epochs.

use anyhow::{bail, Context, Result};
use rayon::prelude::*;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

const FS: f64 = 128.0;
const EPOCH_SAMPLES: usize = 30 * 128;
const SEG: usize = 512; // 4 s

// ───────────────────────────── LightGBM (text format) ─────────────────────────────

struct LgbTree {
    split_feature: Vec<usize>,
    threshold: Vec<f64>,
    decision_type: Vec<u8>,
    left: Vec<i32>,
    right: Vec<i32>,
    leaf: Vec<f64>,
}

impl LgbTree {
    #[inline]
    fn predict(&self, x: &[f64]) -> f64 {
        if self.split_feature.is_empty() {
            return self.leaf.first().copied().unwrap_or(0.0);
        }
        let mut node: i32 = 0;
        loop {
            let n = node as usize;
            let dt = self.decision_type[n];
            let missing_type = (dt >> 2) & 3;
            let default_left = dt & 2 != 0;
            let mut v = x[self.split_feature[n]];
            let go_left = if missing_type == 2 && v.is_nan() {
                default_left
            } else {
                if v.is_nan() {
                    v = 0.0;
                }
                if missing_type == 1 && v.abs() <= 1e-35 {
                    default_left
                } else {
                    v <= self.threshold[n]
                }
            };
            let next = if go_left { self.left[n] } else { self.right[n] };
            if next < 0 {
                return self.leaf[(!next) as usize];
            }
            node = next;
        }
    }
}

fn parse_list<T: std::str::FromStr>(value: &str) -> Result<Vec<T>> {
    value
        .split_whitespace()
        .map(|t| t.parse::<T>().map_err(|_| anyhow::anyhow!("bad LightGBM token '{t}'")))
        .collect()
}

fn parse_lgbm_text(text: &str) -> Result<(usize, Vec<LgbTree>)> {
    let mut num_class = 1usize;
    let mut trees = Vec::new();
    let mut cur: Option<HashMap<&str, &str>> = None;
    let flush = |m: HashMap<&str, &str>, trees: &mut Vec<LgbTree>| -> Result<()> {
        let get = |k: &str| m.get(k).copied().unwrap_or("");
        trees.push(LgbTree {
            split_feature: parse_list(get("split_feature"))?,
            threshold: parse_list(get("threshold"))?,
            decision_type: parse_list(get("decision_type"))?,
            left: parse_list(get("left_child"))?,
            right: parse_list(get("right_child"))?,
            leaf: parse_list(get("leaf_value"))?,
        });
        Ok(())
    };
    for line in text.lines() {
        if line.starts_with("end of trees") {
            break;
        }
        if let Some(v) = line.strip_prefix("num_class=") {
            if cur.is_none() {
                num_class = v.trim().parse().unwrap_or(1);
            }
            continue;
        }
        if line.starts_with("Tree=") {
            if let Some(m) = cur.take() {
                flush(m, &mut trees)?;
            }
            cur = Some(HashMap::new());
            continue;
        }
        if let (Some(m), Some((k, v))) = (cur.as_mut(), line.split_once('=')) {
            m.insert(k, v);
        }
    }
    if let Some(m) = cur.take() {
        flush(m, &mut trees)?;
    }
    if trees.is_empty() {
        bail!("no trees found in POPS model");
    }
    Ok((num_class, trees))
}

// ───────────────────────────── model bundle ─────────────────────────────

pub struct PopsModel {
    num_class: usize,
    trees: Vec<LgbTree>,
    /// SVD projection (V * diag(1/W)) for spec1, spec2, rspec1, rspec2.
    proj: [Vec<Vec<f64>>; 4],
    ranges: HashMap<String, (f64, f64)>,
}

fn read_svd(path: &Path) -> Result<Vec<Vec<f64>>> {
    let text = std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    let vals: Vec<f64> = text
        .split_whitespace()
        .map(|t| t.parse::<f64>())
        .collect::<std::result::Result<_, _>>()
        .with_context(|| format!("parsing {}", path.display()))?;
    if vals.len() < 2 {
        bail!("empty SVD file {}", path.display());
    }
    let nrow = vals[0] as usize;
    let ncol = vals[1] as usize;
    if vals.len() < 2 + nrow * ncol + ncol {
        bail!("truncated SVD file {}", path.display());
    }
    let w: Vec<f64> = vals[2 + nrow * ncol..2 + nrow * ncol + ncol].to_vec();
    let mut p = vec![vec![0.0; ncol]; nrow];
    for i in 0..nrow {
        for j in 0..ncol {
            p[i][j] = vals[2 + i * ncol + j] / w[j];
        }
    }
    Ok(p)
}

fn read_ranges(path: &Path) -> Result<HashMap<String, (f64, f64)>> {
    let text = std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    let mut out = HashMap::new();
    let mut toks = text.split_whitespace();
    let header: Vec<&str> = (0..4).filter_map(|_| toks.next()).collect();
    if header != ["ID", "VAR", "MEAN", "SD"] {
        bail!("bad POPS ranges header in {}", path.display());
    }
    loop {
        let (Some(id), Some(var), Some(m), Some(s)) = (toks.next(), toks.next(), toks.next(), toks.next()) else {
            break;
        };
        if id != "." {
            break;
        }
        let (Ok(mean), Ok(sd)) = (m.parse::<f64>(), s.parse::<f64>()) else {
            continue;
        };
        if !mean.is_finite() || !sd.is_finite() || sd < 1e-6 {
            continue;
        }
        // Later duplicates overwrite earlier ones (std::map semantics in Luna).
        out.insert(var.to_string(), (mean, sd));
    }
    Ok(out)
}

impl PopsModel {
    pub fn load_from_dir(dir: &Path) -> Result<Self> {
        let text = std::fs::read_to_string(dir.join("s2_trees.txt"))
            .with_context(|| format!("reading POPS model in {}", dir.display()))?;
        let (num_class, trees) = parse_lgbm_text(&text)?;
        if num_class != 5 {
            bail!("POPS model must be 5-class, found {num_class}");
        }
        let proj = [
            read_svd(&dir.join("s2.spec1.svd"))?,
            read_svd(&dir.join("s2.spec2.svd"))?,
            read_svd(&dir.join("s2.rspec1.svd"))?,
            read_svd(&dir.join("s2.rspec2.svd"))?,
        ];
        for (p, (rows, cols)) in proj.iter().zip([(98, 6), (98, 6), (98, 4), (98, 4)]) {
            if p.len() != rows || p.first().map(|r| r.len()).unwrap_or(0) != cols {
                bail!("unexpected POPS SVD dimensions");
            }
        }
        let ranges = read_ranges(&dir.join("s2.ranges"))?;
        Ok(Self {
            num_class,
            trees,
            proj,
            ranges,
        })
    }

    pub fn model_dir() -> Result<PathBuf> {
        super::assets::require_model_dir("pops", "s2_trees.txt", "Luna POPS model (s2)")
    }

    pub fn load_default() -> Result<Self> {
        Self::load_from_dir(&Self::model_dir()?)
    }

    /// Returns probabilities in POPS class order [W, R, N1, N2, N3].
    fn predict_raw(&self, x: &[f64]) -> Vec<f64> {
        let mut margins = vec![0.0; self.num_class];
        for (i, t) in self.trees.iter().enumerate() {
            margins[i % self.num_class] += t.predict(x);
        }
        let mx = margins.iter().copied().fold(f64::NEG_INFINITY, f64::max);
        let mut s = 0.0;
        for m in margins.iter_mut() {
            *m = (*m - mx).exp();
            s += *m;
        }
        margins.iter().map(|m| m / s).collect()
    }
}

// ───────────────────────────── DSP helpers (Luna-compatible) ─────────────────────────────

fn bessel_i0_luna(x: f64) -> f64 {
    let x2 = x / 2.0;
    let mut num = 1.0;
    let mut fact = 1.0;
    let mut result = 1.0;
    for i in 1..20 {
        num *= x2 * x2;
        fact *= i as f64;
        result += num / (fact * fact);
    }
    result
}

fn kaiser_params(ripple: f64, tw: f64, fs: f64) -> (usize, f64) {
    let dw = 2.0 * std::f64::consts::PI * tw / fs;
    let a = -20.0 * ripple.log10();
    let m = if a > 21.0 {
        ((a - 7.95) / (2.285 * dw)).ceil()
    } else {
        (5.79 / dw).ceil()
    } as usize;
    let beta = if a <= 21.0 {
        0.0
    } else if a <= 50.0 {
        0.5842 * (a - 21.0).powf(0.4) + 0.07886 * (a - 21.0)
    } else {
        0.1102 * (a - 8.7)
    };
    let mut len = m + 1;
    if len % 2 == 0 {
        len += 1;
    }
    (len, beta)
}

/// Luna (v1.7, as bundled with lunapi 1.7.0 used by the retired backend)
/// `FILTER bandpass=0.3,35 tw=0.2 ripple=0.01`: a single Kaiser-windowed
/// two-transition sinc, applied by FFT convolution with the linear-phase delay
/// removed and zero-padded edges.
fn luna_bandpass(x: &[f64]) -> Vec<f64> {
    let (len, beta) = kaiser_params(0.01, 0.2, FS);
    let ft1 = 0.3 / FS;
    let ft2 = 35.0 / FS;
    let m_2 = 0.5 * (len as f64 - 1.0);
    let half = len / 2;
    let mut h = vec![0.0; len];
    h[half] = 2.0 * (ft2 - ft1);
    for n in 0..half {
        let d = n as f64 - m_2;
        let pi = std::f64::consts::PI;
        let v1 = (2.0 * pi * ft1 * d).sin() / (pi * d);
        let v2 = (2.0 * pi * ft2 * d).sin() / (pi * d);
        h[n] = v2 - v1;
        h[len - n - 1] = v2 - v1;
    }
    let denom = bessel_i0_luna(beta);
    for (n, tap) in h.iter_mut().enumerate() {
        let r = (n as f64 - m_2) / m_2;
        *tap *= bessel_i0_luna(beta * (1.0 - r * r).max(0.0).sqrt()) / denom;
    }
    let full = crate::signal::fft_convolve(x, &h);
    let delay = (h.len() - 1) / 2;
    (0..x.len()).map(|i| full.get(i + delay).copied().unwrap_or(0.0)).collect()
}

fn kth_smallest(v: &[f64], k: usize) -> f64 {
    let mut c = v.to_vec();
    let k = k.min(c.len() - 1);
    let (_, m, _) = c.select_nth_unstable_by(k, |a, b| a.total_cmp(b));
    *m
}

fn luna_median_lower(v: &[f64]) -> f64 {
    let n = v.len();
    if n == 1 {
        return v[0];
    }
    if n % 2 == 1 {
        kth_smallest(v, (n - 1) / 2)
    } else {
        kth_smallest(v, n / 2 - 1)
    }
}

fn luna_median_mean(v: &mut [f64]) -> f64 {
    let n = v.len();
    v.sort_by(|a, b| a.total_cmp(b));
    if n % 2 == 1 {
        v[n / 2]
    } else {
        0.5 * (v[n / 2 - 1] + v[n / 2])
    }
}

fn luna_quantile(sorted: &[f64], p: f64) -> f64 {
    let n = sorted.len();
    if n == 1 {
        return sorted[0];
    }
    let poi = -0.5 + p * n as f64;
    let left = (poi.floor().max(0.0)) as usize;
    let right = (poi.ceil() as i64).min(n as i64 - 1).max(0) as usize;
    let t = poi - left as f64;
    (1.0 - t) * sorted[left] + t * sorted[right]
}

fn luna_iqr(v: &[f64]) -> f64 {
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.total_cmp(b));
    luna_quantile(&s, 0.75) - luna_quantile(&s, 0.25)
}

fn luna_invariant(v: &[f64]) -> bool {
    v.len() < 2 || v.iter().all(|x| (x - v[0]).abs() <= 1e-4)
}

/// `eigen_ops::robust_scale(center=T, normalize=T, w, second_rescale)` on one column.
fn robust_scale_col(v: &mut [f64], w: f64, second: bool) {
    if v.is_empty() {
        return;
    }
    let orig = v.to_vec();
    let median = luna_median_lower(&orig);
    let mut iqr = luna_iqr(&orig);
    let mut is_variable = true;
    let lowvar = iqr <= 1e-8;
    if lowvar {
        if luna_invariant(&orig) {
            is_variable = false;
        }
        iqr = 1.0;
    }
    if w > 0.0 && is_variable && !lowvar {
        let n = orig.len();
        let lwr = kth_smallest(&orig, (n as f64 * w) as usize);
        let upr = kth_smallest(&orig, (n as f64 * (1.0 - w)) as usize);
        if lwr < upr {
            for x in v.iter_mut() {
                *x = x.clamp(lwr, upr);
            }
        }
    }
    if is_variable {
        let rsd = 0.7413 * iqr;
        for x in v.iter_mut() {
            *x = (*x - median) / rsd;
        }
    }
    if second {
        let n = v.len() as f64;
        let mean = v.iter().sum::<f64>() / n;
        let mut sd = (v.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / (n - 1.0)).sqrt();
        if sd == 0.0 || !sd.is_finite() {
            sd = 1.0;
        }
        for x in v.iter_mut() {
            *x = (*x - mean) / sd;
        }
    }
}

fn tukey50(n: usize) -> Vec<f64> {
    let step = 1.0 / (n as f64 - 1.0);
    let r = 0.5;
    let rhalf = r / 2.0;
    (0..n)
        .map(|i| {
            let x = i as f64 * step;
            if x < rhalf {
                0.5 * (1.0 + ((2.0 * std::f64::consts::PI / r) * (x - rhalf)).cos())
            } else if x >= 1.0 - rhalf {
                0.5 * (1.0 + ((2.0 * std::f64::consts::PI / r) * (x - 1.0 + rhalf)).cos())
            } else {
                1.0
            }
        })
        .collect()
}

struct Welch {
    window: Vec<f64>,
    norm: f64,
    fft: std::sync::Arc<dyn rustfft::Fft<f64>>,
}

impl Welch {
    fn new() -> Self {
        let window = tukey50(SEG);
        let norm = 1.0 / (window.iter().map(|w| w * w).sum::<f64>() * FS);
        let fft = rustfft::FftPlanner::new().plan_fft_forward(SEG);
        Self { window, norm, fft }
    }

    /// Median Welch PSD for a 30-s epoch (14 x 4-s segments, 2-s step).
    /// Returns power for bins 0..=256 (0.25 Hz resolution).
    fn psd(&self, x: &[f64]) -> Vec<f64> {
        let total = x.len();
        let n_seg = (total - 256) / (SEG - 256);
        let noverlap = if n_seg > 1 {
            ((n_seg * SEG) as f64 - total as f64) / (n_seg as f64 - 1.0)
        } else {
            0.0
        }
        .ceil() as usize;
        let inc = SEG - noverlap;
        let cutoff = SEG / 2 + 1;
        let mut tracker: Vec<Vec<f64>> = vec![Vec::new(); cutoff];
        let mut buf = vec![rustfft::num_complex::Complex64::new(0.0, 0.0); SEG];
        let mut p = 0;
        while p + SEG <= total {
            for i in 0..SEG {
                buf[i] = rustfft::num_complex::Complex64::new(x[p + i] * self.window[i], 0.0);
            }
            self.fft.process(&mut buf);
            for (i, t) in tracker.iter_mut().enumerate() {
                let mut v = buf[i].norm_sqr() * self.norm;
                if i > 0 && i < cutoff - 1 {
                    v *= 2.0;
                }
                t.push(v);
            }
            p += inc;
        }
        tracker.iter_mut().map(|t| luna_median_mean(t)).collect()
    }
}

fn petrosian_fd(x: &[f64]) -> f64 {
    let n = x.len();
    if n < 3 {
        return 0.0;
    }
    let b: Vec<bool> = (1..n).map(|i| x[i] - x[i - 1] > 0.0).collect();
    let n_delta = (1..n - 1).filter(|&i| b[i] != b[i - 1]).count() as f64;
    let nf = n as f64;
    nf.log10() / (nf.log10() + (nf / (nf + 0.4 * n_delta)).log10())
}

#[inline]
fn pe4_pattern(x: &[f64]) -> usize {
    if x[3]<x[0] {if x[2]<x[0] {if x[3]<x[1] {if x[1]<x[0] {if x[2]<x[1] {if x[3]<x[2] {0}else {1}}else {2}}else {if x[3]<x[2] {3}else {4}}}else {if x[2]<x[1] {5}else {if x[3]<x[2] {6}else {7}}}}else {if x[3]<x[1] {if x[1]<x[0] {8}else {if x[2]<x[1] {9}else {10}}}else {11}}}else {if x[2]<x[0] {if x[3]<x[1] {12}else {if x[1]<x[0] {if x[2]<x[1] {13}else {14}}else {15}}}else {if x[3]<x[1] {if x[2]<x[1] {if x[3]<x[2] {16}else {17}}else {18}}else {if x[1]<x[0] {if x[3]<x[2] {19}else {20}}else {if x[2]<x[1] {21}else {if x[3]<x[2] {22}else {23}}}}}}
}

fn permutation_entropy4(x: &[f64]) -> f64 {
    let mut counts = [0f64; 24];
    if x.len() < 4 {
        return 0.0;
    }
    for i in 0..x.len() - 3 {
        counts[pe4_pattern(&x[i..i + 4])] += 1.0;
    }
    let total: f64 = counts.iter().sum();
    let mut e = 0.0;
    for c in counts {
        if c > 0.0 {
            let p = c / total;
            e -= p * p.log2();
        }
    }
    e / 24f64.log2()
}

/// Luna legacy Hjorth (mean-square based) -> (mobility, complexity).
fn hjorth_legacy(x: &[f64]) -> (f64, f64) {
    let n = x.len();
    if n < 3 {
        return (0.0, 0.0);
    }
    let dx: Vec<f64> = x.windows(2).map(|w| w[1] - w[0]).collect();
    let ddx: Vec<f64> = dx.windows(2).map(|w| w[1] - w[0]).collect();
    let ms = |v: &[f64]| v.iter().map(|a| a * a).sum::<f64>() / v.len() as f64;
    let mx2 = ms(x);
    let mdx2 = ms(&dx);
    let mddx2 = ms(&ddx);
    let mob2 = mdx2 / mx2;
    let mut comp = (mddx2 / mdx2 - mob2).sqrt();
    let mut mob = mob2.sqrt();
    if !mob.is_finite() {
        mob = 0.0;
    }
    if !comp.is_finite() {
        comp = 0.0;
    }
    (mob, comp)
}

fn tri_moving_average(x: &[f64], s: usize, mw: f64) -> Vec<f64> {
    let n = x.len();
    let mut s = s;
    if s == 1 || n == 0 {
        return x.to_vec();
    }
    if s >= n {
        s = n - 1;
        if s % 2 == 0 {
            s = s.saturating_sub(1);
        }
        if s < 2 {
            return x.to_vec();
        }
    }
    let hwin = (s - 1) / 2;
    let w: Vec<f64> = (0..=hwin)
        .map(|i| mw + (hwin - i) as f64 / hwin as f64 * (1.0 - mw))
        .collect();
    (0..n)
        .map(|i| {
            let mut wgt = w[0];
            let mut a = w[0] * x[i];
            for j in 1..=hwin {
                if i >= j {
                    wgt += w[j];
                    a += w[j] * x[i - j];
                }
                if i + j < n {
                    wgt += w[j];
                    a += w[j] * x[i + j];
                }
            }
            a / wgt
        })
        .collect()
}

// ───────────────────────────── feature pipeline ─────────────────────────────

struct Level1 {
    spec: [Vec<f64>; 4], // spec1(CEN) spec2(ZEN) rspec1(CEN) rspec2(ZEN), 98 each
    misc: [f64; 4],      // FD, PE, H2, H3 (ZEN)
}

fn spectral_blocks(psd: &[f64]) -> Option<(Vec<f64>, Vec<f64>)> {
    // bins: frequency = i * 0.25 Hz; bin range 0.5..45 Hz for flat checks
    for i in 2..=180 {
        if psd[i] <= 0.0 {
            return None;
        }
    }
    let lo = 3; // 0.75 Hz
    let hi = 100; // 25 Hz
    let spec: Vec<f64> = (lo..=hi).map(|i| 10.0 * psd[i].log10()).collect();
    let norm: f64 = (lo..=hi).map(|i| psd[i]).sum();
    if norm <= 1e-8 {
        return None;
    }
    let rspec: Vec<f64> = (lo..=hi).map(|i| (psd[i] / norm).ln()).collect();
    Some((spec, rspec))
}

fn level1_epoch(welch: &Welch, cen: &[f64], zen: &[f64]) -> Option<Level1> {
    let centre = |x: &[f64]| -> Vec<f64> {
        let m = x.iter().sum::<f64>() / x.len() as f64;
        x.iter().map(|v| v - m).collect()
    };
    let c = centre(cen);
    let z = centre(zen);
    let (spec1, rspec1) = spectral_blocks(&welch.psd(&c))?;
    let (spec2, rspec2) = spectral_blocks(&welch.psd(&z))?;
    let (mob, comp) = hjorth_legacy(&z);
    Some(Level1 {
        spec: [spec1, spec2, rspec1, rspec2],
        misc: [petrosian_fd(&z), permutation_entropy4(&z), mob, comp],
    })
}

fn outlier_flags(values: &[f64], good: &[bool], th: f64, flags: &mut [bool]) {
    let mut sum = 0.0;
    let mut sumsq = 0.0;
    let mut n = 0.0;
    for (v, g) in values.iter().zip(good) {
        if *g {
            sum += v;
            sumsq += v * v;
            n += 1.0;
        }
    }
    if n < 3.0 {
        return;
    }
    let mean = sum / n;
    let sd = (sumsq / (n - 1.0) - (n / (n - 1.0)) * mean * mean).sqrt();
    let (lwr, upr) = (mean - th * sd, mean + th * sd);
    for (i, v) in values.iter().enumerate() {
        if flags[i] && (*v < lwr || *v > upr) {
            flags[i] = false;
        }
    }
}

/// Builds the final 113-column POPS feature matrix for the retained epochs.
fn final_features(model: &PopsModel, rows: &[Level1]) -> (Vec<Vec<f64>>, Vec<String>) {
    let ne = rows.len();
    let col = |f: &dyn Fn(&Level1) -> f64| -> Vec<f64> { rows.iter().map(f).collect() };

    // SVD projections (columns mean-centred within this recording).
    let project = |block: usize, pidx: usize| -> Vec<Vec<f64>> {
        let proj = &model.proj[pidx];
        let nb = proj.len();
        let nc = proj[0].len();
        let mut means = vec![0.0; nb];
        for r in rows {
            for b in 0..nb {
                means[b] += r.spec[block][b];
            }
        }
        for m in means.iter_mut() {
            *m /= ne as f64;
        }
        let mut out = vec![vec![0.0; ne]; nc];
        for (e, r) in rows.iter().enumerate() {
            for j in 0..nc {
                let mut acc = 0.0;
                for b in 0..nb {
                    acc += (r.spec[block][b] - means[b]) * proj[b][j];
                }
                out[j][e] = acc;
            }
        }
        out
    };
    let svd_spec1 = project(0, 0);
    let svd_spec2 = project(1, 1);
    let svd_rspec1 = project(2, 2);
    let svd_rspec2 = project(3, 3);
    let misc: Vec<Vec<f64>> = (0..4).map(|k| col(&|r: &Level1| r.misc[k])).collect();

    let smooth = |block: &Vec<Vec<f64>>, hw: usize| -> Vec<Vec<f64>> {
        block.iter().map(|c| tri_moving_average(c, 2 * hw + 1, 0.05)).collect()
    };
    let norm = |block: &Vec<Vec<f64>>| -> Vec<Vec<f64>> {
        block
            .iter()
            .map(|c| {
                let mut v = c.clone();
                robust_scale_col(&mut v, 0.0, true);
                v
            })
            .collect()
    };

    let mut columns: Vec<(String, Vec<f64>)> = Vec::new();
    let mut push = |label: &str, block: &Vec<Vec<f64>>| {
        for (j, c) in block.iter().enumerate() {
            columns.push((format!("{label}.V{}", j + 1), c.clone()));
        }
    };

    let (m1, m2, m3) = (smooth(&misc, 2), smooth(&misc, 10), smooth(&misc, 25));
    // Level-1 misc block first (FD, PE, HJORTH x2) -- its own labels.
    columns_misc(&mut push, &misc);
    push("SVD.SPEC1", &svd_spec1);
    push("SVD.SPEC2", &svd_spec2);
    push("SVD.RSPEC1", &svd_rspec1);
    push("SVD.RSPEC2", &svd_rspec2);
    for hw in [2usize, 10, 25] {
        push("SMOOTH.SPEC1.SVD", &smooth(&svd_spec1, hw));
        push("SMOOTH.SPEC2.SVD", &smooth(&svd_spec2, hw));
        let m = match hw {
            2 => &m1,
            10 => &m2,
            _ => &m3,
        };
        push("SMOOTH.MISC1", m);
    }
    for hw in [2usize, 10, 25] {
        push("SMOOTH.RSPEC1.SVD", &smooth(&svd_rspec1, hw));
        push("SMOOTH.RSPEC2.SVD", &smooth(&svd_rspec2, hw));
    }
    push("NORM.MISC1", &norm(&misc));
    push("NORM.MISC1.SMOOTHED1", &norm(&m1));
    push("NORM.MISC1.SMOOTHED2", &norm(&m2));
    push("NORM.MISC1.SMOOTHED3", &norm(&m3));
    let time: Vec<f64> = (0..ne).map(|r| r as f64 / ne as f64 - 0.5).collect();
    columns.push(("TIME...V1".to_string(), time));

    let labels: Vec<String> = columns.iter().map(|(l, _)| l.clone()).collect();
    let mut x = vec![vec![0.0; columns.len()]; ne];
    for (j, (_, c)) in columns.iter().enumerate() {
        for e in 0..ne {
            x[e][j] = c[e];
        }
    }
    (x, labels)
}

fn columns_misc(push: &mut dyn FnMut(&str, &Vec<Vec<f64>>), misc: &[Vec<f64>]) {
    push("FD.ZEN", &vec![misc[0].clone()]);
    push("PE.ZEN", &vec![misc[1].clone()]);
    push("HJORTH.ZEN", &vec![misc[2].clone(), misc[3].clone()]);
}

fn apply_ranges(model: &PopsModel, x: &mut [Vec<f64>], labels: &[String]) {
    let ne = x.len();
    if ne == 0 {
        return;
    }
    for (j, label) in labels.iter().enumerate() {
        let Some(&(mean, sd)) = model.ranges.get(label) else { continue };
        let (lwr, upr) = (mean - 4.0 * sd, mean + 4.0 * sd);
        let mut outliers = 0usize;
        for row in x.iter_mut() {
            if row[j] < lwr || row[j] > upr {
                row[j] = f64::NAN;
                outliers += 1;
            }
        }
        if outliers as f64 / ne as f64 > 0.33 {
            for row in x.iter_mut() {
                row[j] = f64::NAN;
            }
        }
    }
}

/// Luna stores every transformed channel back into 16-bit EDF records
/// (`edf_t::update_signal`), using the channel's empirical min/max and a
/// truncating physical->digital conversion. Ordinal features (Petrosian FD,
/// permutation entropy) depend on the resulting ties, so we mirror it.
fn luna_requantise(x: &mut [f64]) {
    if x.is_empty() {
        return;
    }
    let mut pmin = x[0];
    let mut pmax = x[0];
    for &v in x.iter() {
        if v < pmin {
            pmin = v;
        } else if v > pmax {
            pmax = v;
        }
    }
    if (pmin - pmax).abs() < 1e-6 {
        pmin -= 1.0;
        pmax += 1.0;
    }
    let (dmin, dmax) = (-32768.0f64, 32767.0f64);
    let bv = (pmax - pmin) / (dmax - dmin);
    let os = pmax / bv - dmax;
    for v in x.iter_mut() {
        let c = v.clamp(pmin, pmax);
        let d = (c / bv - os).trunc().clamp(-32768.0, 32767.0);
        *v = bv * (os + d);
    }
}

/// Luna `RESAMPLE` (libsamplerate SRC_SINC_FASTEST via `src_simple`), with
/// the same float32 buffers and fixed-point filter indexing.
fn luna_resample(x: &[f64], sr1: f64, sr2: f64) -> Vec<f64> {
    use super::src_fastest_coeffs::{COEFFS, INCREMENT};
    let n = x.len();
    let ratio = sr2 / sr1;
    let n2 = (n as f64 * ratio) as usize;
    let data: Vec<f32> = x.iter().map(|&v| v as f32).chain(std::iter::repeat(0.0).take(10)).collect();
    let len = data.len() as i64;
    let at = |i: i64| -> f64 {
        if i >= 0 && i < len {
            data[i as usize] as f64
        } else {
            0.0
        }
    };
    const SHIFT: i32 = 12;
    const FP_ONE: f64 = (1i64 << SHIFT) as f64;
    let coeff_half_len: i32 = COEFFS.len() as i32 - 2;
    let index_inc = INCREMENT as f64;
    let float_increment = index_inc * if ratio < 1.0 { ratio } else { 1.0 };
    let increment: i32 = (float_increment * FP_ONE).round_ties_even() as i32;
    let max_fi: i32 = coeff_half_len << SHIFT;
    let scale = float_increment / index_inc;
    let coeff = |fi: i32| -> f64 {
        let frac = (fi & ((1 << SHIFT) - 1)) as f64 / FP_ONE;
        let idx = (fi >> SHIFT) as usize;
        let c0 = COEFFS[idx];
        let c1 = COEFFS[idx + 1];
        c0 as f64 + frac * ((c1 - c0) as f64)
    };
    let fmod_one = |v: f64| -> f64 {
        let r = v - v.round_ties_even();
        if r < 0.0 { r + 1.0 } else { r }
    };
    let mut out = vec![0.0f64; n2];
    let mut cur: i64 = 0;
    let mut input_index = 0.0f64;
    let terminate = 1.0 / ratio + 1e-20;
    for o in out.iter_mut() {
        if cur as f64 + input_index + terminate > len as f64 {
            break;
        }
        let start: i32 = (input_index * float_increment * FP_ONE).round_ties_even() as i32;
        // left half
        let mut fi = start;
        let count = (max_fi - fi) / increment;
        fi += count * increment;
        let mut di = cur - count as i64;
        let mut left = 0.0;
        loop {
            left += coeff(fi) * at(di);
            fi -= increment;
            di += 1;
            if fi < 0 {
                break;
            }
        }
        // right half
        let mut fi = increment - start;
        let count = (max_fi - fi) / increment;
        fi += count * increment;
        let mut di = cur + 1 + count as i64;
        let mut right = 0.0;
        loop {
            right += coeff(fi) * at(di);
            fi -= increment;
            di -= 1;
            if fi <= 0 {
                break;
            }
        }
        *o = ((scale * (left + right)) as f32) as f64;
        input_index += 1.0 / ratio;
        let rem = fmod_one(input_index);
        cur += (input_index - rem).round_ties_even() as i64;
        input_index = rem;
    }
    out
}

/// Prepares CEN / ZEN from a single EEG derivation (µV).
fn prepare_signals(signal: &[f64], sfreq: f64) -> (Vec<f64>, Vec<f64>) {
    let mut at128 = if (sfreq - FS).abs() > 1e-6 {
        let mut r = luna_resample(signal, sfreq, FS);
        luna_requantise(&mut r);
        r
    } else {
        signal.to_vec()
    };
    if at128.is_empty() {
        at128.push(0.0);
    }
    let mut cen = luna_bandpass(&at128);
    luna_requantise(&mut cen);
    let mut zen = cen.clone();
    for chunk in zen.chunks_mut(EPOCH_SAMPLES) {
        if chunk.len() == EPOCH_SAMPLES {
            robust_scale_col(chunk, 0.002, false);
        }
    }
    luna_requantise(&mut zen);
    (cen, zen)
}

/// Level-1 features for every epoch plus the POPS epoch mask (flat-spectrum
/// epochs and misc-block outliers removed). Returns (n_epochs, kept, rows).
fn level1_rows(signal: &[f64], sfreq: f64) -> Result<(usize, Vec<usize>, Vec<Level1>)> {
    let (cen, zen) = prepare_signals(signal, sfreq);
    let ne = cen.len() / EPOCH_SAMPLES;
    if ne < 10 {
        bail!("recording too short for POPS ({ne} epochs)");
    }
    let welch = Welch::new();
    let level1: Vec<Option<Level1>> = (0..ne)
        .into_par_iter()
        .map(|e| {
            let r = e * EPOCH_SAMPLES..(e + 1) * EPOCH_SAMPLES;
            level1_epoch(&welch, &cen[r.clone()], &zen[r])
        })
        .collect();

    // OUTLIERS th=10 on the misc block (stats over the block's input mask).
    let good_before: Vec<bool> = level1.iter().map(|l| l.is_some()).collect();
    let mut good = good_before.clone();
    for k in 0..4 {
        let vals: Vec<f64> = level1.iter().map(|l| l.as_ref().map(|l| l.misc[k]).unwrap_or(0.0)).collect();
        outlier_flags(&vals, &good_before, 10.0, &mut good);
    }
    let kept: Vec<usize> = (0..ne).filter(|&e| good[e]).collect();
    if kept.len() < 10 {
        bail!("POPS rejected nearly every epoch as artefact");
    }
    let rows: Vec<Level1> = level1
        .into_iter()
        .enumerate()
        .filter(|(e, _)| good[*e])
        .filter_map(|(_, l)| l)
        .collect();
    Ok((ne, kept, rows))
}

/// Scores one EEG derivation with POPS. Returns per-epoch probabilities in
/// [W, N1, N2, N3, R] order; epochs POPS rejects as artefact are filled from
/// their nearest scored neighbours.
pub fn score_pops_channel(signal: &[f64], sfreq: f64, model: &PopsModel) -> Result<Vec<[f64; 5]>> {
    let (ne, kept, rows) = level1_rows(signal, sfreq)?;
    let (mut x, labels) = final_features(model, &rows);
    apply_ranges(model, &mut x, &labels);
    let preds: Vec<Vec<f64>> = x.par_iter().map(|row| model.predict_raw(row)).collect();

    // POPS order [W, R, N1, N2, N3] -> [W, N1, N2, N3, R]
    let mut out: Vec<Option<[f64; 5]>> = vec![None; ne];
    for (k, &e) in kept.iter().enumerate() {
        let p = &preds[k];
        out[e] = Some([p[0], p[2], p[3], p[4], p[1]]);
    }
    // Fill rejected epochs from nearest scored neighbours.
    let filled: Vec<[f64; 5]> = (0..ne)
        .map(|e| {
            if let Some(p) = out[e] {
                return p;
            }
            let prev = (0..e).rev().find_map(|i| out[i]);
            let next = (e + 1..ne).find_map(|i| out[i]);
            match (prev, next) {
                (Some(a), Some(b)) => {
                    let mut m = [0.0; 5];
                    for i in 0..5 {
                        m[i] = 0.5 * (a[i] + b[i]);
                    }
                    m
                }
                (Some(a), None) | (None, Some(a)) => a,
                _ => [1.0, 0.0, 0.0, 0.0, 0.0],
            }
        })
        .collect();
    Ok(filled)
}

/// Debug helper: returns (kept epoch indices, final feature matrix, labels).
pub fn debug_features(signal: &[f64], sfreq: f64, model: &PopsModel) -> (Vec<usize>, Vec<Vec<f64>>, Vec<String>) {
    let Ok((_, kept, rows)) = level1_rows(signal, sfreq) else {
        return (Vec::new(), Vec::new(), Vec::new());
    };
    let (mut x, labels) = final_features(model, &rows);
    apply_ranges(model, &mut x, &labels);
    (kept, x, labels)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pops_model_loads() {
        let m = PopsModel::load_default().expect("POPS model");
        assert_eq!(m.trees.len(), 5000);
        assert!(m.ranges.len() >= 60);
        let x = vec![0.0; 113];
        let p = m.predict_raw(&x);
        assert!((p.iter().sum::<f64>() - 1.0).abs() < 1e-9);
    }

    #[test]
    fn bandpass_passes_alpha() {
        let x: Vec<f64> = (0..128 * 60).map(|i| (2.0 * std::f64::consts::PI * 10.0 * i as f64 / FS).sin()).collect();
        let y = luna_bandpass(&x);
        let mid = &y[128 * 20..128 * 40];
        let amp = mid.iter().fold(0.0f64, |a, v| a.max(v.abs()));
        assert!((amp - 1.0).abs() < 0.03, "amp {amp}");
    }

    #[test]
    fn pe4_is_normalised() {
        let mut seed: u64 = 12345;
        let x: Vec<f64> = (0..3840)
            .map(|_| {
                seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                (seed >> 33) as f64
            })
            .collect();
        let pe = permutation_entropy4(&x);
        assert!(pe > 0.5 && pe <= 1.0);
    }
}
