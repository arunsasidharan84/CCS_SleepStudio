use crate::pipeline::LoadedRecording;
use crate::signal::{analytic_signal_padded, linear_detrend, mne_overlap_add};
use num_complex::Complex64;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::f64::consts::PI;

#[derive(Deserialize)]
struct DetectionFilters {
    spindle_broad: Vec<f64>,
    spindle_sigma: Vec<f64>,
    slow_wave: Vec<f64>,
    coupling_sigma: Vec<f64>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct SpindleEvent {
    pub start: f64,
    pub peak: f64,
    pub end: f64,
    pub duration: f64,
    pub amplitude: f64,
    pub amp_filtered: f64,
    #[serde(rename = "RMS")]
    pub rms: f64,
    pub abs_power: f64,
    pub rel_power: f64,
    pub frequency: f64,
    pub oscillations: f64,
    pub symmetry: f64,
    pub stage: i8,
    pub channel: String,
    pub idx_channel: usize,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct SpindleSummary {
    pub channel: String,
    pub count: usize,
    pub duration: f64,
    pub amplitude: f64,
    pub amp_filtered: f64,
    #[serde(rename = "RMS")]
    pub rms: f64,
    pub abs_power: f64,
    pub rel_power: f64,
    pub frequency: f64,
    pub oscillations: f64,
    pub symmetry: f64,
}

#[derive(Debug, Serialize)]
pub struct SpindleResults {
    pub events: Vec<SpindleEvent>,
    pub summary: Vec<SpindleSummary>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct SlowWaveEvent {
    pub start: f64,
    pub neg_peak: f64,
    pub mid_crossing: f64,
    pub pos_peak: f64,
    pub end: f64,
    pub duration: f64,
    pub val_neg_peak: f64,
    pub val_pos_peak: f64,
    #[serde(rename = "PTP")]
    pub ptp: f64,
    pub slope: f64,
    pub frequency: f64,
    pub sigma_peak: f64,
    pub phase_at_sigma_peak: f64,
    #[serde(rename = "ndPAC")]
    pub nd_pac: f64,
    /// Normalised mean vector length (Canolty et al. 2006):
    /// |sum(A e^{i phi})| / sum(A) over the +-2 s event window.
    #[serde(rename = "MVL")]
    pub mvl: f64,
    /// Phase-locking value (Penny et al. 2008): consistency between the
    /// slow-oscillation phase and the phase of the SO-band-filtered sigma
    /// envelope over the +-2 s event window.
    #[serde(rename = "PLV")]
    pub plv: f64,
    pub stage: i8,
    pub channel: String,
    pub idx_channel: usize,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct SlowWaveSummary {
    pub channel: String,
    pub count: usize,
    pub duration: f64,
    pub val_neg_peak: f64,
    pub val_pos_peak: f64,
    #[serde(rename = "PTP")]
    pub ptp: f64,
    pub slope: f64,
    pub frequency: f64,
    pub phase_at_sigma_peak: f64,
    #[serde(rename = "ndPAC")]
    pub nd_pac: f64,
    #[serde(rename = "MVL")]
    pub mvl: f64,
    #[serde(rename = "PLV")]
    pub plv: f64,
    /// Resultant vector length of the sigma-peak phases across events
    /// (0 = random timing, 1 = every spindle peak at the same SO phase).
    pub phase_consistency: f64,
}

#[derive(Debug, Serialize)]
pub struct SlowWaveResults {
    pub events: Vec<SlowWaveEvent>,
    pub summary: Vec<SlowWaveSummary>,
}

fn next_fast_len(mut size: usize) -> usize {
    loop {
        let mut value = size;
        for factor in [2, 3, 5, 7, 11] {
            while value.is_multiple_of(factor) {
                value /= factor;
                if factor == 11 {
                    break;
                }
            }
        }
        if value == 1 {
            return size;
        }
        size += 1;
    }
}

fn extrema(values: &[f64], positive: bool, minimum: f64, maximum: f64) -> Vec<usize> {
    (1..values.len() - 1)
        .filter(|&index| {
            let value = if positive {
                values[index]
            } else {
                -values[index]
            };
            let left = if positive {
                values[index - 1]
            } else {
                -values[index - 1]
            };
            let right = if positive {
                values[index + 1]
            } else {
                -values[index + 1]
            };
            value > left && value >= right && value >= minimum && value <= maximum
        })
        .collect()
}

fn zero_crossings(values: &[f64]) -> Vec<usize> {
    (0..values.len() - 1)
        .filter(|&index| {
            let positive = values[index] > 0.0;
            let next_positive = values[index + 1] > 0.0;
            positive != next_positive
        })
        .collect()
}

fn upper_bound(values: &[usize], target: usize) -> usize {
    values.partition_point(|&value| value < target)
}

fn median(values: &mut [f64]) -> f64 {
    values.sort_by(f64::total_cmp);
    if values.len().is_multiple_of(2) {
        (values[values.len() / 2 - 1] + values[values.len() / 2]) / 2.0
    } else {
        values[values.len() / 2]
    }
}

fn cubic_second_derivatives(x: &[f64], y: &[f64]) -> Vec<f64> {
    let n = x.len();
    assert!(n >= 4);
    let h = x
        .windows(2)
        .map(|pair| pair[1] - pair[0])
        .collect::<Vec<_>>();
    let rhs = (1..n - 1)
        .map(|index| {
            6.0 * ((y[index + 1] - y[index]) / h[index] - (y[index] - y[index - 1]) / h[index - 1])
        })
        .collect::<Vec<_>>();
    let unknowns = n - 2;
    let mut lower = vec![0.0; unknowns];
    let mut diagonal = vec![0.0; unknowns];
    let mut upper = vec![0.0; unknowns];
    let mut target = rhs;

    let a0 = -h[1];
    let b0 = h[0] + h[1];
    let c0 = -h[0];
    diagonal[0] = 2.0 * (h[0] + h[1]) - h[0] * b0 / a0;
    upper[0] = h[1] - h[0] * c0 / a0;
    for index in 2..n - 2 {
        let row = index - 1;
        lower[row] = h[index - 1];
        diagonal[row] = 2.0 * (h[index - 1] + h[index]);
        upper[row] = h[index];
    }
    let last = unknowns - 1;
    let boundary_a = h[n - 2];
    let boundary_b = -(h[n - 3] + h[n - 2]);
    let boundary_c = h[n - 3];
    lower[last] = h[n - 3] - h[n - 2] * boundary_a / boundary_c;
    diagonal[last] = 2.0 * (h[n - 3] + h[n - 2]) - h[n - 2] * boundary_b / boundary_c;

    for index in 1..unknowns {
        let factor = lower[index] / diagonal[index - 1];
        diagonal[index] -= factor * upper[index - 1];
        target[index] -= factor * target[index - 1];
    }
    let mut interior = vec![0.0; unknowns];
    interior[last] = target[last] / diagonal[last];
    for index in (0..last).rev() {
        interior[index] = (target[index] - upper[index] * interior[index + 1]) / diagonal[index];
    }
    let mut second = vec![0.0; n];
    second[1..n - 1].copy_from_slice(&interior);
    second[0] = -(b0 * second[1] + c0 * second[2]) / a0;
    second[n - 1] = -(boundary_a * second[n - 3] + boundary_b * second[n - 2]) / boundary_c;
    second
}

fn cubic_interpolate(x: &[f64], y: &[f64], sample_count: usize, sfreq: f64) -> Vec<f64> {
    let second = cubic_second_derivatives(x, y);
    let mut interval = 0;
    (0..sample_count)
        .map(|sample| {
            let at = sample as f64 / sfreq;
            if at < x[0] || at > x[x.len() - 1] {
                return 0.0;
            }
            while interval + 1 < x.len() - 1 && at > x[interval + 1] {
                interval += 1;
            }
            let width = x[interval + 1] - x[interval];
            let left = (x[interval + 1] - at) / width;
            let right = (at - x[interval]) / width;
            left * y[interval]
                + right * y[interval + 1]
                + ((left.powi(3) - left) * second[interval]
                    + (right.powi(3) - right) * second[interval + 1])
                    * width.powi(2)
                    / 6.0
        })
        .collect()
}

fn moving_values(x: &[f64], y: Option<&[f64]>, sfreq: f64, correlation: bool) -> Vec<f64> {
    let window = 0.3;
    let step = 0.1;
    let count = (x.len() as f64 / sfreq / step).ceil() as usize;
    let last = x.len() - 1;
    let mut times = Vec::with_capacity(count);
    let mut values = Vec::with_capacity(count);
    for index in 0..count {
        let at = index as f64 * step;
        let begin = (((at - window / 2.0) * sfreq) as isize).clamp(0, last as isize) as usize;
        let end = (((at + window / 2.0) * sfreq) as isize).clamp(0, last as isize) as usize;
        let left = &x[begin..end];
        let value = if correlation {
            let right = &y.unwrap()[begin..end];
            let mean_left = left.iter().sum::<f64>() / left.len() as f64;
            let mean_right = right.iter().sum::<f64>() / right.len() as f64;
            let mut numerator = 0.0;
            let mut variance_left = 0.0;
            let mut variance_right = 0.0;
            for (&left_value, &right_value) in left.iter().zip(right) {
                let left_centered = left_value - mean_left;
                let right_centered = right_value - mean_right;
                numerator += left_centered * right_centered;
                variance_left += left_centered * left_centered;
                variance_right += right_centered * right_centered;
            }
            numerator / (variance_left.sqrt() * variance_right.sqrt())
        } else {
            (left.iter().map(|value| value * value).sum::<f64>() / left.len() as f64).sqrt()
        };
        times.push((begin + end) as f64 / (2.0 * sfreq));
        values.push(value);
    }
    cubic_interpolate(&times, &values, x.len(), sfreq)
}

fn spindle_relative_power(data: &[f64], sfreq: f64) -> Vec<f64> {
    let size = (2.0 * sfreq) as usize;
    let step = (0.2 * sfreq) as usize;
    let half = size / 2;
    let window = (0..size)
        .map(|index| 0.5 - 0.5 * (2.0 * PI * index as f64 / size as f64).cos())
        .collect::<Vec<_>>();
    let mut planner = rustfft::FftPlanner::new();
    let fft = planner.plan_fft_forward(size);
    let centers = (0..=data.len()).step_by(step).collect::<Vec<_>>();
    let power = centers
        .par_iter()
        .map(|&center| {
            let mut buffer = vec![Complex64::new(0.0, 0.0); size];
            for index in 0..size {
                let source = center as isize + index as isize - half as isize;
                if source >= 0 && (source as usize) < data.len() {
                    buffer[index].re = data[source as usize] * window[index];
                }
            }
            fft.process(&mut buffer);
            let mut total = 0.0;
            let mut sigma = 0.0;
            for (bin, value) in buffer[..=size / 2].iter().enumerate() {
                let frequency = bin as f64 * sfreq / size as f64;
                if (1.0..=30.0).contains(&frequency) {
                    let value = value.norm_sqr();
                    total += value;
                    if (12.0..=15.0).contains(&frequency) {
                        sigma += value;
                    }
                }
            }
            sigma / total
        })
        .collect::<Vec<_>>();
    let times = centers
        .iter()
        .map(|&center| center as f64 / sfreq)
        .collect::<Vec<_>>();
    cubic_interpolate(&times, &power, data.len(), sfreq)
}

fn trimmed_sample_std(values: &[f64]) -> f64 {
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    let cut = (0.1 * sorted.len() as f64) as usize;
    let selected = &sorted[cut..sorted.len() - cut];
    let mean = selected.iter().sum::<f64>() / selected.len() as f64;
    (selected
        .iter()
        .map(|value| (value - mean).powi(2))
        .sum::<f64>()
        / (selected.len() - 1) as f64)
        .sqrt()
}

fn local_peaks(values: &[f64], minimum_distance: usize) -> Vec<usize> {
    let candidates = (1..values.len() - 1)
        .filter(|&index| values[index] > values[index - 1] && values[index] >= values[index + 1])
        .collect::<Vec<_>>();
    let mut by_height = candidates.clone();
    by_height.sort_by(|&left, &right| values[right].total_cmp(&values[left]));
    let mut kept = Vec::new();
    for candidate in by_height {
        if kept
            .iter()
            .all(|&other| candidate.abs_diff(other) >= minimum_distance)
        {
            kept.push(candidate);
        }
    }
    kept.sort_unstable();
    kept
}

fn prominence(values: &[f64], peak: usize) -> f64 {
    let mut left_minimum = values[peak];
    for index in (0..peak).rev() {
        if values[index] > values[peak] {
            break;
        }
        left_minimum = left_minimum.min(values[index]);
    }
    let mut right_minimum = values[peak];
    for &value in &values[peak + 1..] {
        if value > values[peak] {
            break;
        }
        right_minimum = right_minimum.min(value);
    }
    values[peak] - left_minimum.max(right_minimum)
}

fn channel_spindles(
    name: &str,
    channel_index: usize,
    data: &[f64],
    stages: &[i8],
    sfreq: f64,
    filters: &DetectionFilters,
) -> Vec<SpindleEvent> {
    let broad = mne_overlap_add(data, &filters.spindle_broad);
    let sigma = mne_overlap_add(data, &filters.spindle_sigma);
    let relative_power = spindle_relative_power(&broad, sfreq);
    let moving_correlation = moving_values(&sigma, Some(&broad), sfreq, true);
    let moving_rms = moving_values(&sigma, None, sfreq, false);
    let included_rms = moving_rms
        .iter()
        .zip(stages)
        .filter_map(|(&value, &stage)| matches!(stage, 2 | 3).then_some(value))
        .collect::<Vec<_>>();
    let rms_threshold = (included_rms.iter().sum::<f64>() / included_rms.len() as f64
        + 1.5 * trimmed_sample_std(&included_rms))
    .min(10.0);
    let flags = relative_power
        .iter()
        .zip(&moving_correlation)
        .zip(&moving_rms)
        .zip(stages)
        .map(|(((&power, &correlation), &rms), &stage)| {
            if matches!(stage, 2 | 3) {
                (power >= 0.2) as usize
                    + (correlation >= 0.65) as usize
                    + (rms >= rms_threshold) as usize
            } else {
                0
            }
        })
        .collect::<Vec<_>>();
    let width = (0.1 * sfreq) as usize;
    let half = width / 2;
    let mut prefix = vec![0_usize; flags.len() + 1];
    for (index, &value) in flags.iter().enumerate() {
        prefix[index + 1] = prefix[index] + value;
    }
    let detected = (0..flags.len())
        .filter(|&index| {
            let start = index.saturating_sub(half);
            let end = (index + width - half).min(flags.len());
            (prefix[end] - prefix[start]) as f64 / width as f64 > 2.0
        })
        .collect::<Vec<_>>();
    if detected.is_empty() {
        return Vec::new();
    }
    let mut runs = Vec::<(usize, usize)>::new();
    let mut start = detected[0];
    let mut previous = detected[0];
    let merge_distance = (0.5 * sfreq) as usize;
    for &index in &detected[1..] {
        if index - previous >= merge_distance {
            runs.push((start, previous));
            start = index;
        }
        previous = index;
    }
    runs.push((start, previous));

    let fft_size = next_fast_len(data.len());
    let analytic = analytic_signal_padded(&sigma, fft_size);
    let instantaneous_power = analytic
        .iter()
        .map(|value| value.norm_sqr())
        .collect::<Vec<_>>();
    let phase = analytic.iter().map(|value| value.arg()).collect::<Vec<_>>();
    let instantaneous_frequency = phase
        .windows(2)
        .map(|pair| sfreq / (2.0 * PI) * (pair[1] - pair[0]))
        .collect::<Vec<_>>();
    let mut events = Vec::new();
    for (start, end) in runs {
        let start_time = start as f64 / sfreq;
        let end_time = end as f64 / sfreq;
        let duration = end_time - start_time;
        if !(duration > 0.5 && duration < 2.0) {
            continue;
        }
        let detrended = linear_detrend(&broad[start..=end]);
        let amplitude = detrended.iter().copied().fold(f64::NEG_INFINITY, f64::max)
            - detrended.iter().copied().fold(f64::INFINITY, f64::min);
        let amp_filtered = sigma[start..=end]
            .iter()
            .copied()
            .fold(f64::NEG_INFINITY, f64::max)
            - sigma[start..=end]
                .iter()
                .copied()
                .fold(f64::INFINITY, f64::min);
        let rms = (detrended.iter().map(|value| value * value).sum::<f64>()
            / detrended.len() as f64)
            .sqrt();
        let mut rel_values = relative_power[start..=end].to_vec();
        let rel_power = median(&mut rel_values);
        let mut power_values = instantaneous_power[start..=end]
            .iter()
            .filter_map(|value| (*value > 0.0).then_some(value.log10()))
            .collect::<Vec<_>>();
        let abs_power = median(&mut power_values);
        let mut frequency_values = instantaneous_frequency[start..=end]
            .iter()
            .filter_map(|&value| (value > 0.0).then_some(value))
            .collect::<Vec<_>>();
        let frequency = median(&mut frequency_values);
        let peaks = local_peaks(&detrended, (0.06 * sfreq) as usize);
        if peaks.is_empty() {
            continue;
        }
        let prominent = *peaks
            .iter()
            .max_by(|&&left, &&right| {
                prominence(&detrended, left).total_cmp(&prominence(&detrended, right))
            })
            .unwrap();
        events.push(SpindleEvent {
            start: start_time,
            peak: start_time + prominent as f64 / sfreq,
            end: end_time,
            duration,
            amplitude,
            amp_filtered,
            rms,
            abs_power,
            rel_power,
            frequency,
            oscillations: peaks.len() as f64,
            symmetry: prominent as f64 / detrended.len() as f64,
            stage: stages[start],
            channel: name.to_string(),
            idx_channel: channel_index,
        });
    }
    events
}

fn ndpac(phases: &[f64], amplitudes: &[f64]) -> f64 {
    let mean = amplitudes.iter().sum::<f64>() / amplitudes.len() as f64;
    let variance = amplitudes
        .iter()
        .map(|value| (value - mean).powi(2))
        .sum::<f64>()
        / (amplitudes.len() - 1) as f64;
    let standard_deviation = variance.sqrt();
    phases
        .iter()
        .zip(amplitudes)
        .map(|(&phase, &amplitude)| {
            Complex64::from_polar((amplitude - mean) / standard_deviation, phase)
        })
        .sum::<Complex64>()
        .norm()
        / phases.len() as f64
}

/// Normalised mean vector length |sum(A e^{i phi})| / sum(A).
fn mean_vector_length(phases: &[f64], amplitudes: &[f64]) -> f64 {
    let total: f64 = amplitudes.iter().sum();
    if total <= 0.0 {
        return f64::NAN;
    }
    phases
        .iter()
        .zip(amplitudes)
        .map(|(&phase, &amplitude)| Complex64::from_polar(amplitude, phase))
        .sum::<Complex64>()
        .norm()
        / total
}

/// Phase-locking value |mean(e^{i (phi_a - phi_b)})|.
fn phase_locking_value(phase_a: &[f64], phase_b: &[f64]) -> f64 {
    if phase_a.is_empty() {
        return f64::NAN;
    }
    phase_a
        .iter()
        .zip(phase_b)
        .map(|(&a, &b)| Complex64::from_polar(1.0, a - b))
        .sum::<Complex64>()
        .norm()
        / phase_a.len() as f64
}

fn channel_slow_waves(
    name: &str,
    channel_index: usize,
    data: &[f64],
    stages: &[i8],
    sfreq: f64,
    filters: &DetectionFilters,
) -> Vec<SlowWaveEvent> {
    let filtered = mne_overlap_add(data, &filters.slow_wave);
    let sigma = mne_overlap_add(data, &filters.coupling_sigma);
    let fft_size = next_fast_len(data.len());
    let phase = analytic_signal_padded(&filtered, fft_size)
        .into_iter()
        .map(|value| value.arg())
        .collect::<Vec<_>>();
    let sigma_amplitude = analytic_signal_padded(&sigma, fft_size)
        .into_iter()
        .map(|value| value.norm())
        .collect::<Vec<_>>();
    // Phase of the sigma envelope's slow-oscillation component (for the PLV).
    let envelope_phase = analytic_signal_padded(&mne_overlap_add(&sigma_amplitude, &filters.slow_wave), fft_size)
        .into_iter()
        .map(|value| value.arg())
        .collect::<Vec<_>>();

    let included = |index: usize| matches!(stages[index], 2 | 3);
    let negative = extrema(&filtered, false, 40.0, 200.0)
        .into_iter()
        .filter(|&index| included(index))
        .collect::<Vec<_>>();
    let mut positive = extrema(&filtered, true, 10.0, 150.0)
        .into_iter()
        .filter(|&index| included(index))
        .collect::<Vec<_>>();
    if negative.is_empty() || positive.is_empty() {
        return Vec::new();
    }
    if positive[positive.len() - 1] < negative[negative.len() - 1] {
        positive.push(negative[negative.len() - 1] + 1);
    }
    let crossings = zero_crossings(&filtered);
    let mut events = Vec::new();
    for neg in negative {
        let pos_index = upper_bound(&positive, neg);
        if pos_index >= positive.len() {
            continue;
        }
        let pos = positive[pos_index];
        if pos == neg {
            continue;
        }
        let ptp = filtered[neg].abs() + filtered[pos];
        if !(ptp > 75.0 && ptp < 350.0) {
            continue;
        }
        let neg_crossing = upper_bound(&crossings, neg);
        let pos_crossing = upper_bound(&crossings, pos);
        if neg_crossing == 0
            || neg_crossing >= crossings.len()
            || pos_crossing == 0
            || pos_crossing >= crossings.len()
        {
            continue;
        }
        let previous_neg = crossings[neg_crossing - 1];
        let following_neg = crossings[neg_crossing];
        let previous_pos = crossings[pos_crossing - 1];
        let following_pos = crossings[pos_crossing];
        let neg_duration = (following_neg - previous_neg) as f64 / sfreq;
        let pos_duration = (following_pos - previous_pos) as f64 / sfreq;
        let start = previous_neg as f64 / sfreq;
        let end = following_pos as f64 / sfreq;
        let duration = ((end - start) * 10_000.0).round() / 10_000.0;
        let both_duration = ((neg_duration + pos_duration) * 10_000.0).round() / 10_000.0;
        let mid_crossing = following_neg as f64 / sfreq;
        let neg_peak = neg as f64 / sfreq;
        let slope = filtered[neg].abs() / (mid_crossing - neg_peak);
        if duration != both_duration
            || duration > 2.5
            || duration < 0.4
            || neg_duration <= 0.3
            || neg_duration >= 1.5
            || pos_duration <= 0.1
            || pos_duration >= 1.0
            || mid_crossing <= start
            || mid_crossing >= end
            || slope <= 0.0
        {
            continue;
        }
        let before = (2.0 * sfreq) as usize;
        if neg < before || neg + before >= data.len() {
            continue;
        }
        let epoch_start = neg - before;
        let epoch_end = neg + before + 1;
        let local_max = sigma_amplitude[epoch_start..epoch_end]
            .iter()
            .enumerate()
            .max_by(|left, right| left.1.total_cmp(right.1))
            .map(|(index, _)| index)
            .unwrap();
        let sigma_index = epoch_start + local_max;
        events.push(SlowWaveEvent {
            start,
            neg_peak,
            mid_crossing,
            pos_peak: pos as f64 / sfreq,
            end,
            duration,
            val_neg_peak: filtered[neg],
            val_pos_peak: filtered[pos],
            ptp,
            slope,
            frequency: 1.0 / duration,
            sigma_peak: sigma_index as f64 / sfreq,
            phase_at_sigma_peak: phase[sigma_index],
            nd_pac: ndpac(
                &phase[epoch_start..epoch_end],
                &sigma_amplitude[epoch_start..epoch_end],
            ),
            mvl: mean_vector_length(
                &phase[epoch_start..epoch_end],
                &sigma_amplitude[epoch_start..epoch_end],
            ),
            plv: phase_locking_value(
                &phase[epoch_start..epoch_end],
                &envelope_phase[epoch_start..epoch_end],
            ),
            stage: stages[neg],
            channel: name.to_string(),
            idx_channel: channel_index,
        });
    }

    let mut starts = HashMap::new();
    let mut ends = HashMap::new();
    for event in &events {
        *starts.entry(event.start.to_bits()).or_insert(0_usize) += 1;
        *ends.entry(event.end.to_bits()).or_insert(0_usize) += 1;
    }
    events.retain(|event| starts[&event.start.to_bits()] == 1 && ends[&event.end.to_bits()] == 1);
    events
}

fn mean(events: &[SlowWaveEvent], value: impl Fn(&SlowWaveEvent) -> f64) -> f64 {
    events.iter().map(value).sum::<f64>() / events.len() as f64
}

fn phase_consistency(events: &[SlowWaveEvent]) -> f64 {
    let sine = mean(events, |event| event.phase_at_sigma_peak.sin());
    let cosine = mean(events, |event| event.phase_at_sigma_peak.cos());
    sine.hypot(cosine)
}

fn circular_mean(events: &[SlowWaveEvent]) -> f64 {
    let sine = mean(events, |event| event.phase_at_sigma_peak.sin());
    let cosine = mean(events, |event| event.phase_at_sigma_peak.cos());
    let mut angle = sine.atan2(cosine);
    if angle < -PI {
        angle += 2.0 * PI;
    }
    angle
}

pub fn slow_waves(recording: &LoadedRecording) -> SlowWaveResults {
    let filters: DetectionFilters =
        serde_json::from_str(include_str!("../assets/mne_fir_250hz.json"))
            .expect("embedded MNE detection filters are valid");
    let channel_events = recording
        .edf
        .channels
        .par_iter()
        .zip(recording.edf.data_uv.par_iter())
        .enumerate()
        .map(|(index, (name, data))| {
            channel_slow_waves(
                name,
                index,
                data,
                &recording.sample_stages,
                recording.edf.sfreq,
                &filters,
            )
        })
        .collect::<Vec<_>>();
    let events = channel_events.into_iter().flatten().collect::<Vec<_>>();
    let grouped = events.iter().fold(
        BTreeMap::<String, Vec<SlowWaveEvent>>::new(),
        |mut output, event| {
            output
                .entry(event.channel.clone())
                .or_default()
                .push(event.clone());
            output
        },
    );
    let summary = grouped
        .into_iter()
        .map(|(channel, events)| SlowWaveSummary {
            channel,
            count: events.len(),
            duration: mean(&events, |event| event.duration),
            val_neg_peak: mean(&events, |event| event.val_neg_peak),
            val_pos_peak: mean(&events, |event| event.val_pos_peak),
            ptp: mean(&events, |event| event.ptp),
            slope: mean(&events, |event| event.slope),
            frequency: mean(&events, |event| event.frequency),
            phase_at_sigma_peak: circular_mean(&events),
            nd_pac: mean(&events, |event| event.nd_pac),
            mvl: mean(&events, |event| event.mvl),
            plv: mean(&events, |event| event.plv),
            phase_consistency: phase_consistency(&events),
        })
        .collect();
    SlowWaveResults { events, summary }
}

fn spindle_mean(events: &[SpindleEvent], value: impl Fn(&SpindleEvent) -> f64) -> f64 {
    events.iter().map(value).sum::<f64>() / events.len() as f64
}

pub fn spindles(recording: &LoadedRecording) -> SpindleResults {
    let filters: DetectionFilters =
        serde_json::from_str(include_str!("../assets/mne_fir_250hz.json"))
            .expect("embedded MNE detection filters are valid");
    let channel_events = recording
        .edf
        .channels
        .par_iter()
        .zip(recording.edf.data_uv.par_iter())
        .enumerate()
        .map(|(index, (name, data))| {
            channel_spindles(
                name,
                index,
                data,
                &recording.sample_stages,
                recording.edf.sfreq,
                &filters,
            )
        })
        .collect::<Vec<_>>();
    let events = channel_events.into_iter().flatten().collect::<Vec<_>>();
    let grouped = events.iter().fold(
        BTreeMap::<String, Vec<SpindleEvent>>::new(),
        |mut output, event| {
            output
                .entry(event.channel.clone())
                .or_default()
                .push(event.clone());
            output
        },
    );
    let summary = grouped
        .into_iter()
        .map(|(channel, events)| SpindleSummary {
            channel,
            count: events.len(),
            duration: spindle_mean(&events, |event| event.duration),
            amplitude: spindle_mean(&events, |event| event.amplitude),
            amp_filtered: spindle_mean(&events, |event| event.amp_filtered),
            rms: spindle_mean(&events, |event| event.rms),
            abs_power: spindle_mean(&events, |event| event.abs_power),
            rel_power: spindle_mean(&events, |event| event.rel_power),
            frequency: spindle_mean(&events, |event| event.frequency),
            oscillations: spindle_mean(&events, |event| event.oscillations),
            symmetry: spindle_mean(&events, |event| event.symmetry),
        })
        .collect();
    SpindleResults { events, summary }
}
