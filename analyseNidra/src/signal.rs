use num_complex::Complex64;
use rustfft::FftPlanner;
use serde::Deserialize;

pub fn rereference(data: &mut [Vec<f64>], references: &[usize]) {
    let n = data[0].len();
    for sample in 0..n {
        let reference = references
            .iter()
            .map(|&index| data[index][sample])
            .sum::<f64>()
            / references.len() as f64;
        for channel in data.iter_mut() {
            channel[sample] -= reference;
        }
    }
}

pub fn hamming(size: usize) -> Vec<f64> {
    (0..size)
        .map(|index| {
            // scipy.signal.welch uses get_window(..., fftbins=True), which is
            // the periodic form of the Hamming window.
            0.54 - 0.46 * (2.0 * std::f64::consts::PI * index as f64 / size as f64).cos()
        })
        .collect()
}

pub fn rfft_power(signal: &[f64]) -> Vec<f64> {
    let mut planner = FftPlanner::new();
    let fft = planner.plan_fft_forward(signal.len());
    let mut buffer: Vec<Complex64> = signal
        .iter()
        .map(|&value| Complex64::new(value, 0.0))
        .collect();
    fft.process(&mut buffer);
    buffer[..=signal.len() / 2]
        .iter()
        .map(|value| value.norm_sqr())
        .collect()
}

pub fn fft_convolve(signal: &[f64], kernel: &[f64]) -> Vec<f64> {
    let output_len = signal.len() + kernel.len() - 1;
    let fft_len = output_len.next_power_of_two();
    let mut planner = FftPlanner::new();
    let forward = planner.plan_fft_forward(fft_len);
    let inverse = planner.plan_fft_inverse(fft_len);
    let mut left = vec![Complex64::new(0.0, 0.0); fft_len];
    let mut right = vec![Complex64::new(0.0, 0.0); fft_len];
    for (target, &value) in left.iter_mut().zip(signal) {
        target.re = value;
    }
    for (target, &value) in right.iter_mut().zip(kernel) {
        target.re = value;
    }
    forward.process(&mut left);
    forward.process(&mut right);
    for (value, kernel_value) in left.iter_mut().zip(&right) {
        *value *= kernel_value;
    }
    inverse.process(&mut left);
    left.truncate(output_len);
    left.into_iter()
        .map(|value| value.re / fft_len as f64)
        .collect()
}

fn fir_filter_steady(signal: &[f64], coefficients: &[f64]) -> Vec<f64> {
    let prefix = coefficients.len() - 1;
    let mut extended = vec![signal[0]; prefix];
    extended.extend_from_slice(signal);
    let convolution = fft_convolve(&extended, coefficients);
    convolution[prefix..prefix + signal.len()].to_vec()
}

/// SciPy `filtfilt` for an FIR numerator and `a=[1]`, using odd padding.
pub fn scipy_filtfilt_fir(signal: &[f64], coefficients: &[f64], padlen: usize) -> Vec<f64> {
    assert!(signal.len() > padlen + 1);
    let mut extended = Vec::with_capacity(signal.len() + 2 * padlen);
    extended.extend(
        (1..=padlen)
            .rev()
            .map(|index| 2.0 * signal[0] - signal[index]),
    );
    extended.extend_from_slice(signal);
    extended.extend(
        (signal.len() - padlen - 1..signal.len() - 1)
            .rev()
            .map(|index| 2.0 * signal[signal.len() - 1] - signal[index]),
    );
    let forward = fir_filter_steady(&extended, coefficients);
    let reversed: Vec<f64> = forward.into_iter().rev().collect();
    let backward = fir_filter_steady(&reversed, coefficients);
    backward
        .into_iter()
        .rev()
        .skip(padlen)
        .take(signal.len())
        .collect()
}

pub fn analytic_signal(signal: &[f64]) -> Vec<Complex64> {
    analytic_signal_padded(signal, signal.len())
}

pub fn analytic_signal_padded(signal: &[f64], fft_size: usize) -> Vec<Complex64> {
    assert!(fft_size >= signal.len());
    let size = fft_size;
    let mut planner = FftPlanner::new();
    let forward = planner.plan_fft_forward(size);
    let inverse = planner.plan_fft_inverse(size);
    let mut spectrum = vec![Complex64::new(0.0, 0.0); size];
    for (target, &value) in spectrum.iter_mut().zip(signal) {
        target.re = value;
    }
    forward.process(&mut spectrum);
    for (index, value) in spectrum.iter_mut().enumerate() {
        let multiplier = if index == 0 || (size % 2 == 0 && index == size / 2) {
            1.0
        } else if index < size.div_ceil(2) {
            2.0
        } else {
            0.0
        };
        *value *= multiplier;
    }
    inverse.process(&mut spectrum);
    for value in &mut spectrum {
        *value /= size as f64;
    }
    spectrum.truncate(signal.len());
    spectrum
}

fn mne_resample_padding(input_len: usize) -> [usize; 2] {
    let minimum_addition = (input_len / 8).min(100) * 2;
    let padded_len = (input_len + minimum_addition).next_power_of_two();
    let total_padding = padded_len - input_len;
    [total_padding / 2, total_padding.div_ceil(2)]
}

fn round_ties_even(value: f64) -> usize {
    value.round_ties_even().max(1.0) as usize
}

/// Reproduce MNE's default FFT resampler (`npad="auto"`,
/// `pad="reflect_limited"`, `window="boxcar"`).
pub fn mne_fft_resample(signal: &[f64], source_rate: f64, target_rate: f64) -> Vec<f64> {
    if (source_rate - target_rate).abs() < f64::EPSILON {
        return signal.to_vec();
    }
    let ratio = target_rate / source_rate;
    let final_len = round_ties_even(ratio * signal.len() as f64);
    let padding = mne_resample_padding(signal.len());
    let padded = smart_pad_reflect_limited_asymmetric(signal, padding);
    let old_len = padded.len();
    let new_len = round_ties_even(ratio * old_len as f64);
    let remove_left = round_ties_even(ratio * padding[0] as f64);
    let remove_right = new_len - final_len - remove_left;

    let mut planner = FftPlanner::new();
    let forward = planner.plan_fft_forward(old_len);
    let inverse = planner.plan_fft_inverse(new_len);
    let mut old_spectrum = padded
        .into_iter()
        .map(|value| Complex64::new(value, 0.0))
        .collect::<Vec<_>>();
    forward.process(&mut old_spectrum);

    let retained = old_len.min(new_len);
    let positive_stop = retained / 2;
    let scale = new_len as f64 / old_len as f64;
    let mut new_spectrum = vec![Complex64::new(0.0, 0.0); new_len];
    new_spectrum[0] = old_spectrum[0] * scale;
    for index in 1..positive_stop {
        let value = old_spectrum[index] * scale;
        new_spectrum[index] = value;
        new_spectrum[new_len - index] = value.conj();
    }
    if retained.is_multiple_of(2) {
        let nyquist = retained / 2;
        let mut value = old_spectrum[nyquist] * scale;
        if new_len < old_len {
            value *= 2.0;
        } else {
            value *= 0.5;
        }
        new_spectrum[nyquist] = value;
        if nyquist != new_len - nyquist {
            new_spectrum[new_len - nyquist] = value.conj();
        }
    }
    inverse.process(&mut new_spectrum);
    new_spectrum[remove_left..new_len - remove_right]
        .iter()
        .map(|value| value.re / new_len as f64)
        .collect()
}

fn smart_pad_reflect_limited_asymmetric(signal: &[f64], padding: [usize; 2]) -> Vec<f64> {
    let left_zero_padding = padding[0].saturating_sub(signal.len() - 1);
    let right_zero_padding = padding[1].saturating_sub(signal.len() - 1);
    let left_reflection = padding[0].min(signal.len() - 1);
    let right_reflection = padding[1].min(signal.len() - 1);
    let mut output = Vec::with_capacity(
        left_zero_padding + left_reflection + signal.len() + right_reflection + right_zero_padding,
    );
    output.resize(left_zero_padding, 0.0);
    output.extend(
        (1..=left_reflection)
            .rev()
            .map(|index| 2.0 * signal[0] - signal[index]),
    );
    output.extend_from_slice(signal);
    output.extend(
        (signal.len() - right_reflection - 1..signal.len() - 1)
            .rev()
            .map(|index| 2.0 * signal[signal.len() - 1] - signal[index]),
    );
    output.resize(output.len() + right_zero_padding, 0.0);
    output
}

pub fn resample_channels_mne(data: &mut [Vec<f64>], source_rate: f64, target_rate: f64) {
    for channel in data {
        *channel = mne_fft_resample(channel, source_rate, target_rate);
    }
}

pub fn linear_detrend(values: &[f64]) -> Vec<f64> {
    let n = values.len() as f64;
    let mean_x = (n - 1.0) / 2.0;
    let mean_y = values.iter().sum::<f64>() / n;
    let numerator = values
        .iter()
        .enumerate()
        .map(|(index, value)| (index as f64 - mean_x) * (value - mean_y))
        .sum::<f64>();
    let denominator = (0..values.len())
        .map(|index| (index as f64 - mean_x).powi(2))
        .sum::<f64>();
    let slope = numerator / denominator;
    values
        .iter()
        .enumerate()
        .map(|(index, value)| value - (mean_y + slope * (index as f64 - mean_x)))
        .collect()
}

#[derive(Deserialize)]
struct MneFilters {
    bandpass: Vec<f64>,
    notch: Vec<f64>,
}

fn smart_pad_reflect_limited(signal: &[f64], edge: usize) -> Vec<f64> {
    if edge == 0 {
        return signal.to_vec();
    }
    let mut padded = Vec::with_capacity(signal.len() + 2 * edge);
    padded.extend(
        (1..=edge)
            .rev()
            .map(|index| 2.0 * signal[0] - signal[index]),
    );
    padded.extend_from_slice(signal);
    padded.extend(
        (signal.len() - edge - 1..signal.len() - 1)
            .rev()
            .map(|index| 2.0 * signal[signal.len() - 1] - signal[index]),
    );
    padded
}

fn choose_fft_length(signal_len: usize, filter_len: usize) -> usize {
    let minimum = 2 * filter_len - 1;
    let start_power = (minimum as f64).log2().ceil() as u32;
    let end_power = (signal_len as f64).log2().ceil() as u32;
    (start_power..=end_power)
        .map(|power| 1_usize << power)
        .min_by(|&left, &right| {
            let cost = |fft_len: usize| {
                let segments = (signal_len as f64 / (fft_len - filter_len + 1) as f64).ceil();
                segments * fft_len as f64 * ((fft_len as f64).log2() + 1.0)
                    + 4e-5 * fft_len as f64 * signal_len as f64
            };
            cost(left).total_cmp(&cost(right))
        })
        .unwrap_or_else(|| minimum.next_power_of_two())
}

/// Reproduce MNE's zero-phase, single-pass overlap-add FIR implementation.
pub fn mne_overlap_add(signal: &[f64], filter: &[f64]) -> Vec<f64> {
    let edge = filter.len().min(signal.len()).saturating_sub(1);
    let padded = smart_pad_reflect_limited(signal, edge);
    let fft_len = choose_fft_length(padded.len(), filter.len());
    let segment_len = fft_len - filter.len() + 1;
    let shift = (filter.len() - 1) / 2 + edge;

    let mut planner = FftPlanner::new();
    let forward = planner.plan_fft_forward(fft_len);
    let inverse = planner.plan_fft_inverse(fft_len);
    let mut filter_fft = vec![Complex64::new(0.0, 0.0); fft_len];
    for (target, &value) in filter_fft.iter_mut().zip(filter) {
        target.re = value;
    }
    forward.process(&mut filter_fft);

    let mut output = vec![0.0; padded.len()];
    for start in (0..padded.len()).step_by(segment_len) {
        let stop = (start + segment_len).min(padded.len());
        let mut block = vec![Complex64::new(0.0, 0.0); fft_len];
        for (target, &value) in block.iter_mut().zip(&padded[start..stop]) {
            target.re = value;
        }
        forward.process(&mut block);
        for (value, response) in block.iter_mut().zip(&filter_fft) {
            *value *= response;
        }
        inverse.process(&mut block);

        let output_start = start.saturating_sub(shift);
        let output_stop = (start + fft_len).saturating_sub(shift).min(padded.len());
        let product_start = shift.saturating_sub(start);
        for output_index in output_start..output_stop {
            let product_index = product_start + output_index - output_start;
            output[output_index] += block[product_index].re / fft_len as f64;
        }
    }
    output.truncate(padded.len() - 2 * edge);
    output
}

pub fn preprocess_mne_250hz(data: &mut [Vec<f64>]) {
    let filters: MneFilters = serde_json::from_str(include_str!("../assets/mne_fir_250hz.json"))
        .expect("embedded MNE FIR coefficients are valid JSON");
    for channel in data {
        let bandpassed = mne_overlap_add(channel, &filters.bandpass);
        *channel = mne_overlap_add(&bandpassed, &filters.notch);
    }
}

pub fn design_bandpass_fir(sfreq: f64, low_hz: f64, high_hz: f64, num_taps: usize) -> Vec<f64> {
    let m = if num_taps % 2 == 0 { num_taps + 1 } else { num_taps };
    let half = (m - 1) / 2;
    let nyq = sfreq / 2.0;
    let fl = (low_hz / nyq).clamp(0.001, 0.999);
    let fh = (high_hz / nyq).clamp(fl + 0.001, 0.999);

    let mut taps = Vec::with_capacity(m);
    for i in 0..m {
        let n = i as f64 - half as f64;
        let sinc_h = if n == 0.0 {
            2.0 * fh
        } else {
            (2.0 * std::f64::consts::PI * fh * n).sin() / (std::f64::consts::PI * n)
        };
        let sinc_l = if n == 0.0 {
            2.0 * fl
        } else {
            (2.0 * std::f64::consts::PI * fl * n).sin() / (std::f64::consts::PI * n)
        };
        let ideal = sinc_h - sinc_l;
        let window = 0.54 - 0.46 * (2.0 * std::f64::consts::PI * i as f64 / (m - 1) as f64).cos();
        taps.push(ideal * window);
    }
    let f0 = (low_hz + high_hz) / 2.0;
    let mut gain_center = 0.0;
    for (i, &val) in taps.iter().enumerate() {
        gain_center += val * (2.0 * std::f64::consts::PI * f0 * (i as f64 - half as f64) / sfreq).cos();
    }
    if gain_center.abs() > 1e-9 {
        for val in &mut taps {
            *val /= gain_center;
        }
    }
    taps
}

pub fn design_notch_fir(sfreq: f64, notch_hz: f64, width_hz: f64, num_taps: usize) -> Vec<f64> {
    let m = if num_taps % 2 == 0 { num_taps + 1 } else { num_taps };
    let half = (m - 1) / 2;
    let nyq = sfreq / 2.0;
    let fl = ((notch_hz - width_hz / 2.0) / nyq).clamp(0.001, 0.999);
    let fh = ((notch_hz + width_hz / 2.0) / nyq).clamp(fl + 0.001, 0.999);

    let mut taps = Vec::with_capacity(m);
    for i in 0..m {
        let n = i as f64 - half as f64;
        let sinc_h = if n == 0.0 {
            2.0 * fh
        } else {
            (2.0 * std::f64::consts::PI * fh * n).sin() / (std::f64::consts::PI * n)
        };
        let sinc_l = if n == 0.0 {
            2.0 * fl
        } else {
            (2.0 * std::f64::consts::PI * fl * n).sin() / (std::f64::consts::PI * n)
        };
        let bandpass_ideal = sinc_h - sinc_l;
        let window = 0.54 - 0.46 * (2.0 * std::f64::consts::PI * i as f64 / (m - 1) as f64).cos();
        let bp_tap = bandpass_ideal * window;
        let delta = if i == half { 1.0 } else { 0.0 };
        taps.push(delta - bp_tap);
    }
    taps
}

pub fn filter_bandpass_fir(signal: &[f64], sfreq: f64, low_hz: f64, high_hz: f64) -> Vec<f64> {
    if signal.len() < 100 {
        return signal.to_vec();
    }
    let num_taps = ((3.3 * sfreq / low_hz.max(0.5)).round() as usize).clamp(51, 301);
    let taps = design_bandpass_fir(sfreq, low_hz, high_hz, num_taps);
    let padlen = (num_taps * 2).min(signal.len() - 2);
    scipy_filtfilt_fir(signal, &taps, padlen)
}

pub fn filter_notch(signal: &[f64], sfreq: f64, notch_hz: f64, width_hz: f64) -> Vec<f64> {
    if signal.len() < 100 || notch_hz >= sfreq / 2.0 {
        return signal.to_vec();
    }
    let num_taps = ((3.3 * sfreq / width_hz.max(1.0)).round() as usize).clamp(51, 301);
    let taps = design_notch_fir(sfreq, notch_hz, width_hz, num_taps);
    let padlen = (num_taps * 2).min(signal.len() - 2);
    scipy_filtfilt_fir(signal, &taps, padlen)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    #[test]
    fn centered_identity_filter_is_identity() {
        let signal = vec![1.0, 2.0, 3.0, 4.0];
        assert_eq!(mne_overlap_add(&signal, &[1.0]), signal);
    }

    #[test]
    fn rereference_uses_mean_of_selected_channels() {
        let mut data = vec![vec![10.0, 20.0], vec![2.0, 4.0], vec![4.0, 8.0]];
        rereference(&mut data, &[1, 2]);
        assert_eq!(data[0], vec![7.0, 14.0]);
        assert_eq!(data[1], vec![-1.0, -2.0]);
        assert_eq!(data[2], vec![1.0, 2.0]);
    }

    #[test]
    fn scipy_filtfilt_fixture() {
        let signal = vec![1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0];
        let actual = scipy_filtfilt_fir(&signal, &[0.2, 0.3, 0.5], 2);
        let expected = [1.0, 2.61, 5.32, 10.64, 21.28, 42.56, 78.72, 128.0];
        for (actual, expected) in actual.iter().zip(expected) {
            assert!((actual - expected).abs() < 1e-12, "{actual} != {expected}");
        }
    }

    #[derive(Deserialize)]
    struct MneResampleFixture {
        input: Vec<f64>,
        #[serde(rename = "256_to_250")]
        downsampled: Vec<f64>,
        #[serde(rename = "200_to_250")]
        upsampled: Vec<f64>,
    }

    #[test]
    fn mne_fft_resample_matches_python() {
        let fixture: MneResampleFixture =
            serde_json::from_str(include_str!("../tests/reference/mne_resample.json")).unwrap();
        for (actual, expected) in mne_fft_resample(&fixture.input, 256.0, 250.0)
            .iter()
            .zip(&fixture.downsampled)
        {
            assert!((actual - expected).abs() < 1e-12, "{actual} != {expected}");
        }
        for (actual, expected) in mne_fft_resample(&fixture.input, 200.0, 250.0)
            .iter()
            .zip(&fixture.upsampled)
        {
            assert!((actual - expected).abs() < 1e-12, "{actual} != {expected}");
        }
    }
}
