use crate::pipeline::LoadedRecording;
use crate::signal::{analytic_signal, scipy_filtfilt_fir};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::f64::consts::PI;

#[derive(Deserialize)]
struct FilterDefinition {
    low: f64,
    high: f64,
    order: usize,
    coefficients: Vec<f64>,
}

#[derive(Deserialize)]
struct FilterBank {
    phase: Vec<FilterDefinition>,
    amplitude: Vec<FilterDefinition>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct PacChannelResult {
    pub maximum: f64,
    pub amplitude_frequency: f64,
    pub phase_frequency: f64,
    pub mean_over_epochs: Vec<Vec<f64>>,
    pub maximum_gc: f64,
    pub amplitude_frequency_gc: f64,
    pub phase_frequency_gc: f64,
    pub mean_over_epochs_gc: Vec<Vec<f64>>,
}

#[derive(Debug, Serialize)]
pub struct DebugSeries {
    pub first: Vec<f64>,
    pub mid: Vec<f64>,
    pub last: Vec<f64>,
    pub sum: f64,
    pub sumsq: f64,
    pub min: f64,
    pub max: f64,
}

fn debug_series(values: &[f64]) -> DebugSeries {
    DebugSeries {
        first: values[..10].to_vec(),
        mid: values[1000..1010].to_vec(),
        last: values[values.len() - 10..].to_vec(),
        sum: values.iter().sum(),
        sumsq: values.iter().map(|value| value * value).sum(),
        min: values.iter().copied().fold(f64::INFINITY, f64::min),
        max: values.iter().copied().fold(f64::NEG_INFINITY, f64::max),
    }
}

fn inv_norm_cdf(p: f64) -> f64 {
    // Peter J. Acklam's algorithm for inverse standard normal CDF
    const A: [f64; 6] = [
        -3.969683028665376e+01,
         2.209460984245205e+02,
        -2.759285104469687e+02,
         1.383577518672690e+02,
        -3.066479806614716e+01,
         2.506628277459239e+00,
    ];
    const B: [f64; 5] = [
        -5.447609879822406e+01,
         1.615858368580409e+02,
        -1.556989798598866e+02,
         6.680131188771972e+01,
        -1.328068155288572e+01,
    ];
    const C: [f64; 6] = [
        -7.784894002430293e-03,
        -3.223964580411365e-01,
        -2.400758277161838e+00,
        -2.549732539343734e+00,
         4.374664141464968e+00,
         2.938163982698783e+00,
    ];
    const D: [f64; 4] = [
         7.784695709041462e-03,
         3.224671290700398e-01,
         2.445134137142996e+00,
         3.754408661907416e+00,
    ];
    const P_LOW: f64 = 0.02425;
    const P_HIGH: f64 = 1.0 - P_LOW;

    let p = p.clamp(1e-15, 1.0 - 1e-15);

    if p < P_LOW {
        let q = (-2.0 * p.ln()).sqrt();
        (((((C[0] * q + C[1]) * q + C[2]) * q + C[3]) * q + C[4]) * q + C[5])
            / ((((D[0] * q + D[1]) * q + D[2]) * q + D[3]) * q + 1.0)
    } else if p <= P_HIGH {
        let q = p - 0.5;
        let r = q * q;
        (((((A[0] * r + A[1]) * r + A[2]) * r + A[3]) * r + A[4]) * r + A[5]) * q
            / (((((B[0] * r + B[1]) * r + B[2]) * r + B[3]) * r + B[4]) * r + 1.0)
    } else {
        let q = (-2.0 * (1.0 - p).ln()).sqrt();
        -(((((C[0] * q + C[1]) * q + C[2]) * q + C[3]) * q + C[4]) * q + C[5])
            / ((((D[0] * q + D[1]) * q + D[2]) * q + D[3]) * q + 1.0)
    }
}

pub fn copnorm(values: &[f64]) -> Vec<f64> {
    let n = values.len();
    if n == 0 {
        return Vec::new();
    }
    let mut indices: Vec<usize> = (0..n).collect();
    indices.sort_by(|&a, &b| {
        values[a]
            .partial_cmp(&values[b])
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let mut ranks = vec![0.0; n];
    for (rank, &orig_idx) in indices.iter().enumerate() {
        ranks[orig_idx] = (rank + 1) as f64 / (n + 1) as f64;
    }
    ranks.into_iter().map(inv_norm_cdf).collect()
}

pub fn gc_mi_copnormed(u0: &[f64], u1: &[f64], u2: &[f64]) -> f64 {
    let n = u0.len();
    if n < 4 || n != u1.len() || n != u2.len() {
        return 0.0;
    }
    let inv_dof = 1.0 / (n - 1) as f64;
    let mut c00 = 0.0;
    let mut c01 = 0.0;
    let mut c02 = 0.0;
    let mut c11 = 0.0;
    let mut c12 = 0.0;
    let mut c22 = 0.0;
    for t in 0..n {
        let v0 = u0[t];
        let v1 = u1[t];
        let v2 = u2[t];
        c00 += v0 * v0;
        c01 += v0 * v1;
        c02 += v0 * v2;
        c11 += v1 * v1;
        c12 += v1 * v2;
        c22 += v2 * v2;
    }
    c00 *= inv_dof;
    c01 *= inv_dof;
    c02 *= inv_dof;
    c11 *= inv_dof;
    c12 *= inv_dof;
    c22 *= inv_dof;

    if c00 <= 1e-12 || c22 <= 1e-12 {
        return 0.0;
    }
    let l00 = c00.sqrt();
    let l10 = c01 / l00;
    let l11_sq = c11 - l10 * l10;
    if l11_sq <= 1e-12 {
        return 0.0;
    }
    let l11 = l11_sq.sqrt();
    let l20 = c02 / l00;
    let l21 = (c12 - l20 * l10) / l11;
    let r2 = ((l20 * l20 + l21 * l21) / c22).clamp(0.0, 1.0 - 1e-12);
    (-0.5 * (1.0 - r2).ln() / std::f64::consts::LN_2).max(0.0)
}

pub fn gc_pac(phase: &[f64], amplitude: &[f64]) -> f64 {
    let sin_phase: Vec<f64> = phase.iter().map(|&p| p.sin()).collect();
    let cos_phase: Vec<f64> = phase.iter().map(|&p| p.cos()).collect();
    let u0 = copnorm(&sin_phase);
    let u1 = copnorm(&cos_phase);
    let u2 = copnorm(amplitude);
    gc_mi_copnormed(&u0, &u1, &u2)
}

fn phase_bins(phase: &[f64]) -> Vec<usize> {
    let bins = 18;
    phase
        .iter()
        .map(|&phase_value| {
            let mut bin = (((phase_value + PI) / (2.0 * PI) * bins as f64).floor()) as isize;
            bin = bin.clamp(0, bins as isize - 1);
            bin as usize
        })
        .collect()
}

/// Per-window intermediate results. Windows are processed one at a time (in
/// parallel) so only a window's band-filtered signals are ever held in memory;
/// keeping every band x window x sample array (plus their copula-normalised
/// copies for gcPAC) needed several GB per channel and made the analysis swap
/// on machines with less RAM.
struct WindowPac {
    /// phase-bin counts over every phase band (TensorPAC global counts)
    counts: [usize; 18],
    /// per (amplitude, phase) pair: summed amplitude in each phase bin
    sums: Vec<[f64; 18]>,
    /// per (amplitude, phase) pair: Gaussian-copula MI
    gc: Vec<f64>,
}

fn window_pac(window: &[f64], bank: &FilterBank) -> WindowPac {
    let phases: Vec<Vec<f64>> = bank
        .phase
        .iter()
        .map(|filter| {
            let filtered = scipy_filtfilt_fir(window, &filter.coefficients, filter.order);
            analytic_signal(&filtered).into_iter().map(|value| value.arg()).collect()
        })
        .collect();
    let amplitudes: Vec<Vec<f64>> = bank
        .amplitude
        .iter()
        .map(|filter| {
            let filtered = scipy_filtfilt_fir(window, &filter.coefficients, filter.order);
            analytic_signal(&filtered).into_iter().map(|value| value.norm()).collect()
        })
        .collect();
    let bins: Vec<Vec<usize>> = phases.iter().map(|phase| phase_bins(phase)).collect();
    let mut counts = [0_usize; 18];
    for band in &bins {
        for &bin in band {
            counts[bin] += 1;
        }
    }
    let n_phase = phases.len();
    let mut sums = vec![[0.0_f64; 18]; amplitudes.len() * n_phase];
    for (a, amplitude) in amplitudes.iter().enumerate() {
        for (p, band) in bins.iter().enumerate() {
            let acc = &mut sums[a * n_phase + p];
            for (&bin, &value) in band.iter().zip(amplitude) {
                acc[bin] += value;
            }
        }
    }
    let phase_cop: Vec<(Vec<f64>, Vec<f64>)> = phases
        .iter()
        .map(|phase| {
            let sin_vals: Vec<f64> = phase.iter().map(|&p| p.sin()).collect();
            let cos_vals: Vec<f64> = phase.iter().map(|&p| p.cos()).collect();
            (copnorm(&sin_vals), copnorm(&cos_vals))
        })
        .collect();
    let mut gc = Vec::with_capacity(amplitudes.len() * n_phase);
    for amplitude in &amplitudes {
        let amp_u = copnorm(amplitude);
        for (sin_u, cos_u) in &phase_cop {
            gc.push(gc_mi_copnormed(sin_u, cos_u, &amp_u));
        }
    }
    WindowPac { counts, sums, gc }
}

fn modulation_index_from_sums(sums: &[f64; 18], global_counts: &[usize]) -> f64 {
    let bins = 18;
    let mut means = *sums;
    for (mean, &count) in means.iter_mut().zip(global_counts) {
        if count > 0 {
            *mean /= count as f64;
        }
    }
    let total = means.iter().sum::<f64>();
    if total == 0.0 || means.iter().any(|&value| value <= 0.0) {
        return 0.0;
    }
    1.0 + means
        .iter()
        .map(|value| {
            let probability = value / total;
            probability * probability.ln()
        })
        .sum::<f64>()
        / (bins as f64).ln()
}

fn channel_pac(windows: &[Vec<f64>], bank: &FilterBank) -> PacChannelResult {
    let per_window: Vec<WindowPac> = windows.par_iter().map(|w| window_pac(w, bank)).collect();
    let n_phase = bank.phase.len();
    // Tensorpac's tensor implementation uses idx.sum() across every phase
    // band and epoch when averaging each phase bin.
    let mut global_counts = vec![0_usize; 18];
    for w in &per_window {
        for (g, c) in global_counts.iter_mut().zip(w.counts.iter()) {
            *g += c;
        }
    }
    let mut means = vec![vec![0.0; n_phase]; bank.amplitude.len()];
    let mut means_gc = vec![vec![0.0; n_phase]; bank.amplitude.len()];
    for (amplitude_index, (row, row_gc)) in means.iter_mut().zip(means_gc.iter_mut()).enumerate() {
        for phase_index in 0..n_phase {
            let k = amplitude_index * n_phase + phase_index;
            row[phase_index] = per_window
                .iter()
                .map(|w| modulation_index_from_sums(&w.sums[k], &global_counts))
                .sum::<f64>()
                / windows.len() as f64;
            row_gc[phase_index] =
                per_window.iter().map(|w| w.gc[k]).sum::<f64>() / windows.len().max(1) as f64;
        }
    }
    let mut maximum = f64::NEG_INFINITY;
    let mut maximum_amplitude = 0;
    let mut maximum_phase = 0;
    for (amplitude_index, row) in means.iter().enumerate() {
        for (phase_index, &value) in row.iter().enumerate() {
            if value > maximum {
                maximum = value;
                maximum_amplitude = amplitude_index;
                maximum_phase = phase_index;
            }
        }
    }

    let mut maximum_gc = f64::NEG_INFINITY;
    let mut maximum_amplitude_gc = 0;
    let mut maximum_phase_gc = 0;
    for (amplitude_index, row) in means_gc.iter().enumerate() {
        for (phase_index, &value) in row.iter().enumerate() {
            if value > maximum_gc {
                maximum_gc = value;
                maximum_amplitude_gc = amplitude_index;
                maximum_phase_gc = phase_index;
            }
        }
    }

    PacChannelResult {
        maximum,
        amplitude_frequency: (bank.amplitude[maximum_amplitude].low
            + bank.amplitude[maximum_amplitude].high)
            / 2.0,
        phase_frequency: (bank.phase[maximum_phase].low + bank.phase[maximum_phase].high) / 2.0,
        mean_over_epochs: means,
        maximum_gc,
        amplitude_frequency_gc: (bank.amplitude[maximum_amplitude_gc].low
            + bank.amplitude[maximum_amplitude_gc].high)
            / 2.0,
        phase_frequency_gc: (bank.phase[maximum_phase_gc].low
            + bank.phase[maximum_phase_gc].high)
            / 2.0,
        mean_over_epochs_gc: means_gc,
    }
}

pub fn compute(recording: &LoadedRecording) -> BTreeMap<String, PacChannelResult> {
    let bank: FilterBank =
        serde_json::from_str(include_str!("../assets/tensorpac_pac_filters_250hz.json"))
            .expect("embedded TensorPAC filter bank is valid");
    let samples_per_window = (15.0 * recording.edf.sfreq).round() as usize;
    recording
        .edf
        .channels
        .par_iter()
        .zip(recording.edf.data_uv.par_iter())
        .map(|(name, channel)| {
            let nrem: Vec<f64> = channel
                .iter()
                .zip(&recording.sample_stages)
                .filter_map(|(&value, &stage)| matches!(stage, 2 | 3).then_some(value))
                .collect();
            let windows = nrem
                .chunks_exact(samples_per_window)
                .map(<[f64]>::to_vec)
                .collect::<Vec<_>>();
            (name.clone(), channel_pac(&windows, &bank))
        })
        .collect()
}

pub fn debug_first_window(recording: &LoadedRecording) -> BTreeMap<String, DebugSeries> {
    let bank: FilterBank =
        serde_json::from_str(include_str!("../assets/tensorpac_pac_filters_250hz.json"))
            .expect("embedded TensorPAC filter bank is valid");
    let channel = &recording.edf.data_uv[0];
    let window: Vec<f64> = channel
        .iter()
        .zip(&recording.sample_stages)
        .filter_map(|(&value, &stage)| matches!(stage, 2 | 3).then_some(value))
        .take(3750)
        .collect();
    let phase_filtered =
        scipy_filtfilt_fir(&window, &bank.phase[0].coefficients, bank.phase[0].order);
    let phase = analytic_signal(&phase_filtered)
        .into_iter()
        .map(|value| value.arg())
        .collect::<Vec<_>>();
    let amplitude_filtered = scipy_filtfilt_fir(
        &window,
        &bank.amplitude[0].coefficients,
        bank.amplitude[0].order,
    );
    let amplitude = analytic_signal(&amplitude_filtered)
        .into_iter()
        .map(|value| value.norm())
        .collect::<Vec<_>>();
    BTreeMap::from([
        ("pf".into(), debug_series(&phase_filtered)),
        ("pa".into(), debug_series(&phase)),
        ("af".into(), debug_series(&amplitude_filtered)),
        ("aa".into(), debug_series(&amplitude)),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_inv_norm_cdf_quantiles() {
        assert!((inv_norm_cdf(0.5) - 0.0).abs() < 1e-7);
        assert!((inv_norm_cdf(0.841344746) - 1.0).abs() < 1e-4);
        assert!((inv_norm_cdf(0.977249868) - 2.0).abs() < 1e-4);
        assert!((inv_norm_cdf(0.025) - (-1.95996)).abs() < 1e-4);
    }

    #[test]
    fn test_copnorm_distribution() {
        let values = vec![10.0, 5.0, 20.0, 1.0, 15.0];
        let c = copnorm(&values);
        assert_eq!(c.len(), 5);
        // Smallest element (1.0) has smallest copnorm value
        assert!(c[3] < c[1]);
        assert!(c[1] < c[0]);
        assert!(c[0] < c[4]);
        assert!(c[4] < c[2]);
    }

    #[test]
    fn test_gc_pac_coupling() {
        // Strong phase-amplitude coupling: amplitude peaks at phase = 0
        let n = 1000;
        let phase: Vec<f64> = (0..n)
            .map(|i| (i as f64 * 0.1) % (2.0 * PI) - PI)
            .collect();
        let amp_coupled: Vec<f64> = phase.iter().map(|&p| p.cos() + 2.0).collect();
        let mi_coupled = gc_pac(&phase, &amp_coupled);
        assert!(mi_coupled > 0.1, "Coupled MI should be significant, got {}", mi_coupled);

        // Weak/orthogonal coupling
        let amp_uncoupled: Vec<f64> = (0..n).map(|i| ((i * 37) % 100) as f64 + 1.0).collect();
        let mi_uncoupled = gc_pac(&phase, &amp_uncoupled);
        assert!(mi_uncoupled < mi_coupled, "Uncoupled MI should be lower than coupled");
    }
}

