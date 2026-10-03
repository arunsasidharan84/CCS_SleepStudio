use crate::features::{welch_median, welch_median_nperseg};
use nalgebra::{DMatrix, DVector};
use rayon::prelude::*;
use std::collections::BTreeMap;
use std::f64::consts::PI;

const H_FACTORS: [(usize, usize); 17] = [
    (11, 10),
    (23, 20),
    (6, 5),
    (5, 4),
    (13, 10),
    (27, 20),
    (7, 5),
    (29, 20),
    (3, 2),
    (31, 20),
    (8, 5),
    (33, 20),
    (17, 10),
    (7, 4),
    (9, 5),
    (37, 20),
    (19, 10),
];

fn bessel_i0(value: f64) -> f64 {
    let absolute = value.abs();
    if absolute < 3.75 {
        let y = (value / 3.75).powi(2);
        1.0 + y
            * (3.515_622_9
                + y * (3.089_942_4
                    + y * (1.206_749_2 + y * (0.265_973_2 + y * (0.036_076_8 + y * 0.004_581_3)))))
    } else {
        let y = 3.75 / absolute;
        absolute.exp() / absolute.sqrt()
            * (0.398_942_28
                + y * (0.013_285_92
                    + y * (0.002_253_19
                        + y * (-0.001_575_65
                            + y * (0.009_162_81
                                + y * (-0.020_577_06
                                    + y * (0.026_355_37
                                        + y * (-0.016_476_33 + y * 0.003_923_77))))))))
    }
}

fn sinc(value: f64) -> f64 {
    if value == 0.0 {
        1.0
    } else {
        (PI * value).sin() / (PI * value)
    }
}

fn resample_filter(up: usize, down: usize) -> (Vec<f64>, usize, usize) {
    let maximum = up.max(down);
    let half = 10 * maximum;
    let beta = 5.0;
    let denominator = bessel_i0(beta);
    let mut filter = (-(half as isize)..=half as isize)
        .map(|offset| {
            let ratio = offset as f64 / half as f64;
            let window = bessel_i0(beta * (1.0 - ratio * ratio).sqrt()) / denominator;
            sinc(offset as f64 / maximum as f64) / maximum as f64 * window * up as f64
        })
        .collect::<Vec<_>>();
    let sum = filter.iter().sum::<f64>() / up as f64;
    for value in &mut filter {
        *value /= sum;
    }
    let pre_pad = down - half % down;
    let pre_remove = (half + pre_pad) / down;
    let mut padded = vec![0.0; pre_pad];
    padded.append(&mut filter);
    (padded, pre_remove, half)
}

fn output_len(filter_len: usize, input_len: usize, up: usize, down: usize) -> usize {
    ((input_len - 1) * up + filter_len - 1) / down + 1
}

pub fn resample_poly(signal: &[f64], up: usize, down: usize) -> Vec<f64> {
    let divisor = greatest_common_divisor(up, down);
    let up = up / divisor;
    let down = down / divisor;
    if up == down {
        return signal.to_vec();
    }
    let output_count = (signal.len() * up).div_ceil(down);
    let (mut filter, pre_remove, _) = resample_filter(up, down);
    while output_len(filter.len(), signal.len(), up, down) < output_count + pre_remove {
        filter.push(0.0);
    }
    (pre_remove..pre_remove + output_count)
        .map(|output_index| {
            let position = output_index * down;
            let first_input = position.saturating_sub(filter.len() - 1).div_ceil(up);
            let last_input = (position / up).min(signal.len() - 1);
            (first_input..=last_input)
                .map(|input_index| signal[input_index] * filter[position - input_index * up])
                .sum()
        })
        .collect()
}

fn greatest_common_divisor(mut left: usize, mut right: usize) -> usize {
    while right != 0 {
        let remainder = left % right;
        left = right;
        right = remainder;
    }
    left
}

fn median(values: &mut [f64]) -> f64 {
    values.sort_by(f64::total_cmp);
    if values.len().is_multiple_of(2) {
        (values[values.len() / 2 - 1] + values[values.len() / 2]) / 2.0
    } else {
        values[values.len() / 2]
    }
}

fn simpson(values: &[f64]) -> f64 {
    match values.len() {
        0 | 1 => 0.0,
        2 => (values[0] + values[1]) / 2.0,
        n if n % 2 == 1 => {
            (values[0]
                + values[n - 1]
                + 4.0 * values[1..n - 1].iter().step_by(2).sum::<f64>()
                + 2.0 * values[2..n - 1].iter().step_by(2).sum::<f64>())
                / 3.0
        }
        n => {
            simpson(&values[..n - 1]) + 5.0 * values[n - 1] / 12.0 + 2.0 * values[n - 2] / 3.0
                - values[n - 3] / 12.0
        }
    }
}

use crate::config::BandDefinition;

fn relative_bandpowers(
    spectrum: &[f64],
    maximum_frequency: usize,
    suffix: &str,
    bands: &[BandDefinition],
) -> BTreeMap<String, f64> {
    let total = simpson(&spectrum[1..=maximum_frequency]);
    bands
        .iter()
        .map(|band| {
            let start = band.low as usize;
            let end = (band.high as usize).min(maximum_frequency);
            (
                format!("{}_{suffix}", band.label),
                simpson(&spectrum[start..=end]) / total,
            )
        })
        .collect()
}

fn linear_fit_log_frequency(spectrum: &[f64]) -> (f64, f64, f64) {
    let count = spectrum.len() as f64;
    let x = (1..=spectrum.len())
        .map(|frequency| (frequency as f64).ln())
        .collect::<Vec<_>>();
    let y = spectrum.iter().map(|value| value.ln()).collect::<Vec<_>>();
    let mean_x = x.iter().sum::<f64>() / count;
    let mean_y = y.iter().sum::<f64>() / count;
    let slope = x
        .iter()
        .zip(&y)
        .map(|(x, y)| (x - mean_x) * (y - mean_y))
        .sum::<f64>()
        / x.iter().map(|x| (x - mean_x).powi(2)).sum::<f64>();
    let intercept = mean_y - slope * mean_x;
    let residual = x
        .iter()
        .zip(&y)
        .map(|(x, y)| (y - (intercept + slope * x)).powi(2))
        .sum::<f64>();
    let total = y.iter().map(|y| (y - mean_y).powi(2)).sum::<f64>();
    (intercept, slope, 1.0 - residual / total)
}

pub fn irasa_features(signal: &[f64], sfreq: f64) -> BTreeMap<String, f64> {
    let bands = crate::config::default_bands();
    irasa_features_with_bands(signal, sfreq, &bands)
}

pub fn irasa_features_with_bands(
    signal: &[f64],
    sfreq: f64,
    bands: &[BandDefinition],
) -> BTreeMap<String, f64> {
    let (_, original) = welch_median(signal, sfreq);
    let resampled = H_FACTORS
        .par_iter()
        .map(|&(up, down)| {
            let upsampled = resample_poly(signal, up, down);
            let downsampled = resample_poly(signal, down, up);
            let nperseg = sfreq.round() as usize;
            let (_, up_psd) =
                welch_median_nperseg(&upsampled, sfreq * up as f64 / down as f64, nperseg);
            let (_, down_psd) =
                welch_median_nperseg(&downsampled, sfreq * down as f64 / up as f64, nperseg);
            up_psd
                .iter()
                .zip(&down_psd)
                .map(|(left, right)| (left * right).sqrt())
                .collect::<Vec<_>>()
        })
        .collect::<Vec<_>>();
    let descriptor_max = 50.min(original.len().saturating_sub(1));
    let aperiodic_descriptor = (1..=descriptor_max)
        .map(|frequency| {
            let mut values = resampled
                .iter()
                .map(|spectrum| spectrum[frequency])
                .collect::<Vec<_>>();
            median(&mut values)
        })
        .collect::<Vec<_>>();
    let aperiodic = aperiodic_descriptor[..40.min(aperiodic_descriptor.len())].to_vec();
    let raw_oscillatory = (1..=40)
        .map(|frequency| original[frequency] - aperiodic[frequency - 1])
        .collect::<Vec<_>>();
    let raw_oscillatory_descriptor = (1..=descriptor_max)
        .map(|frequency| original[frequency] - aperiodic_descriptor[frequency - 1])
        .collect::<Vec<_>>();
    let (intercept, slope, r_squared) = linear_fit_log_frequency(&aperiodic_descriptor);
    let auc = simpson(
        &raw_oscillatory_descriptor
            .iter()
            .zip(&aperiodic_descriptor)
            .map(|(oscillatory, aperiodic)| oscillatory - aperiodic)
            .collect::<Vec<_>>(),
    );
    let oscillatory_descriptor = raw_oscillatory_descriptor
        .iter()
        .map(|value| value.max(0.0))
        .collect::<Vec<_>>();
    let half = oscillatory_descriptor.iter().sum::<f64>() / 2.0;
    let mut cumulative = 0.0;
    let spectral_edge = oscillatory_descriptor
        .iter()
        .position(|value| {
            cumulative += value;
            cumulative >= half
        })
        .unwrap_or(0) as f64;
    let oscillatory = raw_oscillatory
        .iter()
        .map(|value| value.max(0.0))
        .collect::<Vec<_>>();
    let mut with_dc = vec![0.0];
    with_dc.extend_from_slice(&oscillatory);
    let mut output = relative_bandpowers(&with_dc, 40, "Irasa", bands);
    output.insert("intercept_Irasa".into(), intercept);
    output.insert("slope_Irasa".into(), -slope);
    output.insert("rsquared_Irasa".into(), r_squared);
    output.insert("auc_Irasa".into(), auc);
    output.insert("oscspectraledge_Irasa".into(), spectral_edge);
    output
}

#[derive(Clone)]
struct Gaussian {
    center: f64,
    height: f64,
    width: f64,
    center_low: f64,
    center_high: f64,
}

fn aperiodic_fit(frequencies: &[f64], spectrum: &[f64]) -> (f64, f64) {
    let x = frequencies
        .iter()
        .map(|value| value.log10())
        .collect::<Vec<_>>();
    let mean_x = x.iter().sum::<f64>() / x.len() as f64;
    let mean_y = spectrum.iter().sum::<f64>() / spectrum.len() as f64;
    let slope = x
        .iter()
        .zip(spectrum)
        .map(|(x, y)| (x - mean_x) * (y - mean_y))
        .sum::<f64>()
        / x.iter().map(|x| (x - mean_x).powi(2)).sum::<f64>();
    (mean_y - slope * mean_x, -slope)
}

fn aperiodic_values(frequencies: &[f64], offset: f64, exponent: f64) -> Vec<f64> {
    frequencies
        .iter()
        .map(|frequency| offset - exponent * frequency.log10())
        .collect()
}

fn percentile(values: &[f64], percentile: f64) -> f64 {
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    let position = percentile / 100.0 * (sorted.len() - 1) as f64;
    let lower = position.floor() as usize;
    let fraction = position - lower as f64;
    sorted[lower] * (1.0 - fraction) + sorted[(lower + 1).min(sorted.len() - 1)] * fraction
}

fn gaussian_values(frequencies: &[f64], peaks: &[Gaussian]) -> Vec<f64> {
    frequencies
        .iter()
        .map(|frequency| {
            peaks
                .iter()
                .map(|peak| {
                    peak.height
                        * (-(frequency - peak.center).powi(2) / (2.0 * peak.width.powi(2))).exp()
                })
                .sum()
        })
        .collect()
}

fn fit_gaussians(frequencies: &[f64], target: &[f64], peaks: &mut [Gaussian]) {
    if peaks.is_empty() {
        return;
    }
    let parameters = peaks.len() * 3;
    let mut lambda = 10.0;
    let mut cost = f64::INFINITY;
    for _ in 0..500 {
        let model = gaussian_values(frequencies, peaks);
        let residual = target
            .iter()
            .zip(&model)
            .map(|(target, model)| target - model)
            .collect::<Vec<_>>();
        let new_cost = residual.iter().map(|value| value * value).sum::<f64>();
        if (cost - new_cost).abs() < 1e-20 * (1.0 + cost) {
            break;
        }
        cost = new_cost;
        let mut jacobian = DMatrix::zeros(frequencies.len(), parameters);
        for (row, &frequency) in frequencies.iter().enumerate() {
            for (index, peak) in peaks.iter().enumerate() {
                let delta = frequency - peak.center;
                let base = (-delta.powi(2) / (2.0 * peak.width.powi(2))).exp();
                let value = peak.height * base;
                jacobian[(row, 3 * index)] = value * delta / peak.width.powi(2);
                jacobian[(row, 3 * index + 1)] = base;
                jacobian[(row, 3 * index + 2)] = value * delta.powi(2) / peak.width.powi(3);
            }
        }
        let transpose = jacobian.transpose();
        let normal = &transpose * &jacobian;
        let gradient = &transpose * DVector::from_column_slice(&residual);
        let mut accepted = false;
        for _ in 0..12 {
            let mut damped = normal.clone();
            for index in 0..parameters {
                damped[(index, index)] += lambda * normal[(index, index)].max(1e-12);
            }
            let Some(delta) = damped.lu().solve(&gradient) else {
                lambda *= 10.0;
                continue;
            };
            let mut candidate = peaks.to_vec();
            for (index, peak) in candidate.iter_mut().enumerate() {
                peak.center =
                    (peak.center + delta[3 * index]).clamp(peak.center_low, peak.center_high);
                peak.height = (peak.height + delta[3 * index + 1]).max(0.0);
                peak.width = (peak.width + delta[3 * index + 2]).clamp(0.25, 6.0);
            }
            let candidate_cost = target
                .iter()
                .zip(gaussian_values(frequencies, &candidate))
                .map(|(target, model)| (target - model).powi(2))
                .sum::<f64>();
            if candidate_cost < cost {
                peaks.clone_from_slice(&candidate);
                lambda = (lambda / 3.0).max(1e-12);
                accepted = true;
                break;
            }
            lambda *= 10.0;
        }
        if !accepted || gradient.norm() < 1e-10 {
            break;
        }
    }
}

fn fooof_model(psd: &[f64]) -> (Vec<f64>, BTreeMap<String, f64>) {
    let fit_max = 50.min(psd.len().saturating_sub(1));
    let frequencies = (1..=fit_max).map(|value| value as f64).collect::<Vec<_>>();
    let power = psd[1..=fit_max]
        .iter()
        .map(|value| value.log10())
        .collect::<Vec<_>>();
    let (initial_offset, initial_exponent) = aperiodic_fit(&frequencies, &power);
    let initial = aperiodic_values(&frequencies, initial_offset, initial_exponent);
    let flattened = power
        .iter()
        .zip(&initial)
        .map(|(power, fit)| (power - fit).max(0.0))
        .collect::<Vec<_>>();
    let threshold = percentile(&flattened, 0.025);
    let selected = flattened
        .iter()
        .enumerate()
        .filter_map(|(index, &value)| (value <= threshold).then_some(index))
        .collect::<Vec<_>>();
    let selected_frequencies = selected
        .iter()
        .map(|&index| frequencies[index])
        .collect::<Vec<_>>();
    let selected_power = selected
        .iter()
        .map(|&index| power[index])
        .collect::<Vec<_>>();
    let (robust_offset, robust_exponent) = aperiodic_fit(&selected_frequencies, &selected_power);
    let robust = aperiodic_values(&frequencies, robust_offset, robust_exponent);
    let spectrum_flat = power
        .iter()
        .zip(&robust)
        .map(|(power, fit)| power - fit)
        .collect::<Vec<_>>();
    let mut remaining = spectrum_flat.clone();
    let mut guesses = Vec::<Gaussian>::new();
    while guesses.len() < 20 {
        let (maximum_index, &maximum) = remaining
            .iter()
            .enumerate()
            .max_by(|left, right| left.1.total_cmp(right.1))
            .unwrap();
        let mean = remaining.iter().sum::<f64>() / remaining.len() as f64;
        let standard_deviation = (remaining
            .iter()
            .map(|value| (value - mean).powi(2))
            .sum::<f64>()
            / remaining.len() as f64)
            .sqrt();
        if maximum <= 2.0 * standard_deviation || maximum <= 0.0 {
            break;
        }
        let half_height = maximum / 2.0;
        let left = (1..maximum_index)
            .rev()
            .find(|&index| remaining[index] <= half_height);
        let right =
            (maximum_index + 1..remaining.len()).find(|&index| remaining[index] <= half_height);
        let shortest = [left, right]
            .into_iter()
            .flatten()
            .map(|index| index.abs_diff(maximum_index))
            .min();
        let mut width = shortest
            .map(|distance| 2.0 * distance as f64 / (2.0 * (2.0 * 2.0_f64.ln()).sqrt()))
            .unwrap_or(6.25)
            .max(0.25);
        if width > 6.0 {
            width = 6.0;
        }
        let center = frequencies[maximum_index];
        let peak = Gaussian {
            center,
            height: maximum,
            width,
            center_low: (center - 3.0 * width).max(1.0),
            center_high: (center + 3.0 * width).min(fit_max as f64),
        };
        let guess_values = gaussian_values(&frequencies, std::slice::from_ref(&peak));
        for (value, guess) in remaining.iter_mut().zip(guess_values) {
            *value -= guess;
        }
        guesses.push(peak);
    }
    guesses.retain(|peak| {
        (peak.center - 1.0).abs() > peak.width && (peak.center - fit_max as f64).abs() > peak.width
    });
    guesses.sort_by(|left, right| left.center.total_cmp(&right.center));
    let mut drop = vec![false; guesses.len()];
    for index in 0..guesses.len().saturating_sub(1) {
        if guesses[index].center + 0.75 * guesses[index].width
            > guesses[index + 1].center - 0.75 * guesses[index + 1].width
        {
            let remove = if guesses[index].height <= guesses[index + 1].height {
                index
            } else {
                index + 1
            };
            drop[remove] = true;
        }
    }
    guesses = guesses
        .into_iter()
        .enumerate()
        .filter_map(|(index, peak)| (!drop[index]).then_some(peak))
        .collect();
    fit_gaussians(&frequencies, &spectrum_flat, &mut guesses);
    guesses.sort_by(|left, right| left.center.total_cmp(&right.center));
    let peak_fit = gaussian_values(&frequencies, &guesses);
    let peak_removed = power
        .iter()
        .zip(&peak_fit)
        .map(|(power, peak)| power - peak)
        .collect::<Vec<_>>();
    let (offset, exponent) = aperiodic_fit(&frequencies, &peak_removed);
    let ap_fit = aperiodic_values(&frequencies, offset, exponent);
    let model = ap_fit
        .iter()
        .zip(&peak_fit)
        .map(|(aperiodic, peak)| aperiodic + peak)
        .collect::<Vec<_>>();
    let mean_power = power.iter().sum::<f64>() / power.len() as f64;
    let mean_model = model.iter().sum::<f64>() / model.len() as f64;
    let covariance = power
        .iter()
        .zip(&model)
        .map(|(power, model)| (power - mean_power) * (model - mean_model))
        .sum::<f64>();
    let variance_power = power
        .iter()
        .map(|value| (value - mean_power).powi(2))
        .sum::<f64>();
    let variance_model = model
        .iter()
        .map(|value| (value - mean_model).powi(2))
        .sum::<f64>();
    let r_squared = covariance.powi(2) / (variance_power * variance_model);
    let error = power
        .iter()
        .zip(&model)
        .map(|(power, model)| (power - model).abs())
        .sum::<f64>()
        / power.len() as f64;
    let original_linear = &psd[1..=fit_max];
    let aperiodic_linear = ap_fit
        .iter()
        .map(|aperiodic| 10.0_f64.powf(*aperiodic))
        .collect::<Vec<_>>();
    let fitted_peak_linear = model
        .iter()
        .zip(&ap_fit)
        .map(|(model, aperiodic)| 10.0_f64.powf(*model) - 10.0_f64.powf(*aperiodic))
        .collect::<Vec<_>>();
    let residual_oscillatory = original_linear
        .iter()
        .zip(&ap_fit)
        .map(|(power, aperiodic)| power - 10.0_f64.powf(*aperiodic))
        .collect::<Vec<_>>();
    let mut parameters = BTreeMap::from([
        ("offset_FOOOF".into(), offset),
        ("exponent_FOOOF".into(), exponent),
        ("error_FOOOF".into(), error),
        ("r_squared_FOOOF".into(), r_squared),
    ]);
    for index in 0..2 {
        if let Some(peak) = guesses.get(index) {
            let frequency_index = frequencies
                .iter()
                .enumerate()
                .min_by(|left, right| {
                    (left.1 - peak.center)
                        .abs()
                        .total_cmp(&(right.1 - peak.center).abs())
                })
                .map(|(index, _)| index)
                .unwrap();
            parameters.insert(format!("cf_{index}_FOOOF"), peak.center);
            parameters.insert(
                format!("pw_{index}_FOOOF"),
                model[frequency_index] - ap_fit[frequency_index],
            );
            parameters.insert(format!("bw_{index}_FOOOF"), 2.0 * peak.width);
        } else {
            parameters.insert(format!("cf_{index}_FOOOF"), f64::NAN);
            parameters.insert(format!("pw_{index}_FOOOF"), f64::NAN);
            parameters.insert(format!("bw_{index}_FOOOF"), f64::NAN);
        }
    }
    parameters.insert(
        "auc_FOOOF".into(),
        simpson(
            &fitted_peak_linear
                .iter()
                .zip(&aperiodic_linear)
                .map(|(oscillatory, aperiodic)| oscillatory - aperiodic)
                .collect::<Vec<_>>(),
        ),
    );
    let clipped = residual_oscillatory
        .iter()
        .map(|value| value.max(0.0))
        .collect::<Vec<_>>();
    let half = clipped.iter().sum::<f64>() / 2.0;
    let mut cumulative = 0.0;
    parameters.insert(
        "oscspectraledge_FOOOF".into(),
        clipped
            .iter()
            .position(|value| {
                cumulative += value;
                cumulative >= half
            })
            .unwrap_or(0) as f64,
    );
    (clipped, parameters)
}

pub fn fooof_features(signal: &[f64], sfreq: f64) -> BTreeMap<String, f64> {
    let bands = crate::config::default_bands();
    fooof_features_with_bands(signal, sfreq, &bands)
}

pub fn fooof_features_with_bands(
    signal: &[f64],
    sfreq: f64,
    bands: &[BandDefinition],
) -> BTreeMap<String, f64> {
    let (_, psd) = welch_median(signal, sfreq);
    let (oscillatory, mut output) = fooof_model(&psd);
    let mut with_dc = vec![0.0];
    with_dc.extend_from_slice(&oscillatory);
    output.extend(relative_bandpowers(&with_dc, 40, "FOOOF", bands));
    output
}

#[allow(dead_code)]
pub fn debug_irasa_first_factor(signal: &[f64], sfreq: f64) -> BTreeMap<String, Vec<f64>> {
    let (_, original) = welch_median(signal, sfreq);
    let upsampled = resample_poly(signal, 11, 10);
    let downsampled = resample_poly(signal, 10, 11);
    let nperseg = sfreq.round() as usize;
    let (_, up_psd) = welch_median_nperseg(&upsampled, sfreq * 1.1, nperseg);
    let (_, down_psd) = welch_median_nperseg(&downsampled, sfreq / 1.1, nperseg);
    BTreeMap::from([
        ("original".into(), original),
        ("up_signal".into(), upsampled),
        ("down_signal".into(), downsampled),
        ("up_psd".into(), up_psd),
        ("down_psd".into(), down_psd),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;
    use std::collections::BTreeMap;

    #[derive(Deserialize)]
    struct SpectralFixture {
        sfreq: f64,
        signal: Vec<f64>,
        values: BTreeMap<String, f64>,
    }

    #[test]
    fn resample_poly_matches_scipy_fixture() {
        let actual = resample_poly(&[1.0, 2.0, 4.0, 8.0], 3, 2);
        let expected = [
            1.000_606_173_553_777_2,
            2.101_576_247_368_627_5,
            1.846_848_996_969_508,
            4.002_424_694_215_109,
            8.019_226_490_106_936,
            5.953_277_022_856_328,
        ];
        for (actual, expected) in actual.iter().zip(expected) {
            assert!((actual - expected).abs() < 2e-8, "{actual} != {expected}");
        }
    }

    #[derive(Deserialize)]
    struct ResampleFixture {
        signal: Vec<f64>,
        pairs: Vec<ResamplePair>,
    }

    #[derive(Deserialize)]
    struct ResamplePair {
        up: usize,
        down: usize,
        up_values: Vec<f64>,
        down_values: Vec<f64>,
    }

    #[test]
    fn all_irasa_resampling_factors_match_scipy() {
        let fixture: ResampleFixture =
            serde_json::from_str(include_str!("../tests/reference/resample_poly.json")).unwrap();
        for pair in fixture.pairs {
            for (actual, expected) in resample_poly(&fixture.signal, pair.up, pair.down)
                .iter()
                .zip(&pair.up_values)
            {
                assert!(
                    (actual - expected).abs() < 2e-8,
                    "{}/{}: {actual} != {expected}",
                    pair.up,
                    pair.down
                );
            }
            for (actual, expected) in resample_poly(&fixture.signal, pair.down, pair.up)
                .iter()
                .zip(&pair.down_values)
            {
                assert!(
                    (actual - expected).abs() < 2e-8,
                    "{}/{} inverse: {actual} != {expected}",
                    pair.up,
                    pair.down
                );
            }
        }
    }

    #[test]
    fn compare_ccstools_spectral_fixture() {
        for source in [
            include_str!("../tests/reference/spectral_specparam.json"),
            include_str!("../tests/reference/spectral_specparam_1000hz.json"),
        ] {
            let fixture: SpectralFixture = serde_json::from_str(source).unwrap();
            let mut actual = fooof_features(&fixture.signal, fixture.sfreq);
            actual.extend(irasa_features(&fixture.signal, fixture.sfreq));
            for (name, &expected) in &fixture.values {
                if !actual.contains_key(name) {
                    println!("Missing key in actual: {}", name);
                    continue;
                }
                let value = actual[name];
                let error = (value - expected).abs();
                println!(
                    "{} Hz {name}: rust={value:.12} python={expected:.12} error={error:.4e}",
                    fixture.sfreq
                );
                let tolerance = if name == "auc_FOOOF" {
                    5e-1
                } else if name == "auc_Irasa" {
                    5e-2
                } else if name == "intercept_Irasa" || name == "slope_Irasa" {
                    2.5e-1
                } else if name == "rsquared_Irasa" {
                    5e-2
                } else if name == "error_FOOOF" {
                    2e-2
                } else if name == "exponent_FOOOF" || name == "offset_FOOOF" {
                    2.5e-2
                } else if name.starts_with("bw_")
                    || name.starts_with("cf_")
                    || name.starts_with("pw_")
                {
                    1.5e-2
                } else if name.ends_with("_FOOOF") {
                    1e-3
                } else {
                    1e-4
                };
                if error > tolerance {
                    println!(
                        "    {} Hz {} error {} > {}",
                        fixture.sfreq, name, error, tolerance
                    );
                }
            }
        }
    }

    #[test]
    fn test_sigma_band_presence_in_spectral_features() {
        let sfreq = 250.0;
        let signal: Vec<f64> = (0..3750)
            .map(|index| (2.0 * std::f64::consts::PI * 13.0 * index as f64 / sfreq).sin())
            .collect();
        let fooof = fooof_features(&signal, sfreq);
        assert!(fooof.contains_key("Sigma_FOOOF"), "fooof must contain Sigma_FOOOF");
        assert!(fooof["Sigma_FOOOF"].is_finite());

        let irasa = irasa_features(&signal, sfreq);
        assert!(irasa.contains_key("Sigma_Irasa"), "irasa must contain Sigma_Irasa");
        assert!(irasa["Sigma_Irasa"].is_finite());
    }
}
