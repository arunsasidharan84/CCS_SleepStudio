use crate::signal::{hamming, rfft_power};
use rayon::prelude::*;
use std::collections::BTreeMap;

pub const BANDS: [(f64, f64, &str); 7] = [
    (1.0, 4.0, "Delta"),
    (4.0, 8.0, "Theta"),
    (10.0, 16.0, "Sigma"),
    (8.0, 12.0, "Alpha"),
    (12.0, 18.0, "Beta1"),
    (18.0, 30.0, "Beta2"),
    (30.0, 40.0, "Gamma1"),
];

fn median(values: &mut [f64]) -> f64 {
    values.sort_by(f64::total_cmp);
    let n = values.len();
    if n % 2 == 0 {
        (values[n / 2 - 1] + values[n / 2]) / 2.0
    } else {
        values[n / 2]
    }
}

fn median_bias(n: usize) -> f64 {
    let mut bias = 1.0;
    for index in 1..=((n.saturating_sub(1)) / 2) {
        let even = (2 * index) as f64;
        bias += 1.0 / (even + 1.0) - 1.0 / even;
    }
    bias
}

fn simpson(values: &[f64], dx: f64) -> f64 {
    match values.len() {
        0 | 1 => 0.0,
        2 => (values[0] + values[1]) * dx / 2.0,
        n if n % 2 == 1 => {
            let odd = values[1..n - 1].iter().step_by(2).sum::<f64>();
            let even = values[2..n - 1].iter().step_by(2).sum::<f64>();
            dx / 3.0 * (values[0] + values[n - 1] + 4.0 * odd + 2.0 * even)
        }
        n => {
            // Cartwright correction used by scipy.integrate.simpson for an
            // even number of uniformly spaced samples.
            simpson(&values[..n - 1], dx)
                + dx * (5.0 * values[n - 1] / 12.0 + 2.0 * values[n - 2] / 3.0
                    - values[n - 3] / 12.0)
        }
    }
}

/// SciPy-compatible Welch PSD for the pipeline's fixed configuration:
/// one-second Hamming windows, 50% overlap, density scaling, median average.
pub fn welch_median(signal: &[f64], sfreq: f64) -> (Vec<f64>, Vec<f64>) {
    welch_median_nperseg(signal, sfreq, sfreq.round() as usize)
}

pub fn welch_median_nperseg(signal: &[f64], sfreq: f64, nperseg: usize) -> (Vec<f64>, Vec<f64>) {
    let step = nperseg / 2;
    let window = hamming(nperseg);
    let window_energy = window.iter().map(|value| value * value).sum::<f64>();
    let segments: Vec<&[f64]> = (0..=signal.len().saturating_sub(nperseg))
        .step_by(step)
        .map(|start| &signal[start..start + nperseg])
        .collect();
    let spectra: Vec<Vec<f64>> = segments
        .par_iter()
        .map(|segment| {
            let mean = segment.iter().sum::<f64>() / segment.len() as f64;
            let tapered: Vec<f64> = segment
                .iter()
                .zip(&window)
                .map(|(value, weight)| (value - mean) * weight)
                .collect();
            let mut power = rfft_power(&tapered);
            let scale = 1.0 / (sfreq * window_energy);
            for (index, value) in power.iter_mut().enumerate() {
                *value *= scale;
                if index != 0 && index != nperseg / 2 {
                    *value *= 2.0;
                }
            }
            power
        })
        .collect();
    let bins = nperseg / 2 + 1;
    let mut psd = vec![0.0; bins];
    let bias = median_bias(spectra.len());
    for bin in 0..bins {
        let mut values: Vec<f64> = spectra.iter().map(|spectrum| spectrum[bin]).collect();
        psd[bin] = median(&mut values) / bias;
    }
    let frequencies = (0..bins)
        .map(|index| index as f64 * sfreq / nperseg as f64)
        .collect();
    (frequencies, psd)
}

pub fn bandpowers(signal: &[f64], sfreq: f64) -> BTreeMap<String, f64> {
    let (frequencies, psd) = welch_median(signal, sfreq);
    let minimum = BANDS
        .iter()
        .map(|band| band.0)
        .fold(f64::INFINITY, f64::min);
    let maximum = BANDS
        .iter()
        .map(|band| band.1)
        .fold(f64::NEG_INFINITY, f64::max);
    let selected: Vec<(f64, f64)> = frequencies
        .iter()
        .copied()
        .zip(psd.iter().copied())
        .filter(|(frequency, _)| *frequency >= minimum && *frequency <= maximum)
        .collect();
    let resolution = frequencies[1] - frequencies[0];
    let total_values: Vec<f64> = selected.iter().map(|(_, value)| *value).collect();
    let total = simpson(&total_values, resolution);
    BANDS
        .iter()
        .map(|&(low, high, label)| {
            let values: Vec<f64> = selected
                .iter()
                .filter_map(|(frequency, value)| {
                    (*frequency >= low && *frequency <= high).then_some(*value)
                })
                .collect();
            let power = simpson(&values, resolution);
            (format!("{label}_PSD"), power / total)
        })
        .collect()
}

pub fn acw50(signal: &[f64], sfreq: f64) -> f64 {
    let mean = signal.iter().sum::<f64>() / signal.len() as f64;
    let centered: Vec<f64> = signal.iter().map(|value| value - mean).collect();
    let variance = centered.iter().map(|value| value * value).sum::<f64>();
    if variance == 0.0 {
        return f64::NAN;
    }
    for lag in 1..signal.len() {
        let autocorrelation = centered[..centered.len() - lag]
            .iter()
            .zip(&centered[lag..])
            .map(|(left, right)| left * right)
            .sum::<f64>()
            / variance;
        if autocorrelation <= 0.5 {
            return lag as f64 / sfreq;
        }
    }
    f64::NAN
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sine_power_peaks_in_alpha() {
        let sfreq = 250.0;
        let signal: Vec<f64> = (0..3750)
            .map(|index| (2.0 * std::f64::consts::PI * 10.0 * index as f64 / sfreq).sin())
            .collect();
        let powers = bandpowers(&signal, sfreq);
        assert!(powers["Alpha_PSD"] > powers["Delta_PSD"]);
    }

    #[test]
    fn sine_power_peaks_in_sigma() {
        let sfreq = 250.0;
        let signal: Vec<f64> = (0..3750)
            .map(|index| (2.0 * std::f64::consts::PI * 13.0 * index as f64 / sfreq).sin())
            .collect();
        let powers = bandpowers(&signal, sfreq);
        assert!(powers.contains_key("Sigma_PSD"), "powers must contain Sigma_PSD");
        assert!(powers["Sigma_PSD"] > powers["Delta_PSD"]);
        assert!(powers["Sigma_PSD"] > powers["Beta2_PSD"]);
    }
}
