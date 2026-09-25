use nalgebra::{Matrix3, SymmetricEigen};
use std::collections::{BTreeMap, BTreeSet};

fn mean(values: &[f64]) -> f64 {
    values.iter().sum::<f64>() / values.len() as f64
}

fn population_std(values: &[f64]) -> f64 {
    let center = mean(values);
    (values
        .iter()
        .map(|value| (value - center).powi(2))
        .sum::<f64>()
        / values.len() as f64)
        .sqrt()
}

fn linear_slope(x: &[f64], y: &[f64]) -> f64 {
    let n = x.len() as f64;
    let sx = x.iter().sum::<f64>();
    let sy = y.iter().sum::<f64>();
    let sx2 = x.iter().map(|value| value * value).sum::<f64>();
    let sxy = x
        .iter()
        .zip(y)
        .map(|(left, right)| left * right)
        .sum::<f64>();
    (n * sxy - sx * sy) / (n * sx2 - sx * sx + 1e-9)
}

pub fn permutation_entropy(signal: &[f64]) -> f64 {
    let mut counts = [0_usize; 27];
    for values in signal.windows(3) {
        let mut order = [0_usize, 1, 2];
        order.sort_by(|&left, &right| values[left].total_cmp(&values[right]));
        let hash = order[0] + 3 * order[1] + 9 * order[2];
        counts[hash] += 1;
    }
    let total = counts.iter().sum::<usize>() as f64;
    let entropy = counts
        .iter()
        .filter(|&&count| count > 0)
        .map(|&count| {
            let probability = count as f64 / total;
            -probability * probability.log2()
        })
        .sum::<f64>();
    entropy / 6_f64.log2()
}

pub fn svd_entropy(signal: &[f64]) -> f64 {
    let mut gram = Matrix3::<f64>::zeros();
    for values in signal.windows(3) {
        for row in 0..3 {
            for column in 0..3 {
                gram[(row, column)] += values[row] * values[column];
            }
        }
    }
    let eigen = SymmetricEigen::new(gram);
    let mut singular = eigen
        .eigenvalues
        .iter()
        .map(|value| value.max(0.0).sqrt())
        .collect::<Vec<_>>();
    let total = singular.iter().sum::<f64>();
    singular.iter_mut().for_each(|value| *value /= total);
    -singular
        .iter()
        .filter(|&&value| value > 0.0)
        .map(|value| value * value.log2())
        .sum::<f64>()
        / 3_f64.log2()
}

pub fn sample_entropy(signal: &[f64]) -> f64 {
    // Exact same pair counts as the classic diagonal-streaming algorithm
    // (`sample_entropy_reference` in the tests): all template pairs among the
    // first `size - order` positions whose first `order` (denominator) or
    // `order + 1` (numerator) samples all differ by less than the tolerance.
    // Templates are sorted by their first sample so only pairs already close
    // in that coordinate are examined -- about 5-8x faster than comparing
    // every pair; this was the most expensive core-stage feature.
    let order = 2;
    let tolerance = 0.2 * population_std(signal);
    let size = signal.len();
    if size <= order + 1 {
        return f64::NAN;
    }
    let n_templates = size - order;
    let mut sorted: Vec<usize> = (0..n_templates).collect();
    sorted.sort_unstable_by(|&i, &j| signal[i].total_cmp(&signal[j]));
    let mut numerator = 0_u64;
    let mut denominator = 0_u64;
    for p in 0..n_templates {
        let i = sorted[p];
        let xi = signal[i];
        for &j in &sorted[p + 1..] {
            if signal[j] - xi >= tolerance {
                break;
            }
            if (1..order).all(|k| (signal[i + k] - signal[j + k]).abs() < tolerance) {
                denominator += 1;
                if (signal[i + order] - signal[j + order]).abs() < tolerance {
                    numerator += 1;
                }
            }
        }
    }
    if denominator == 0 {
        f64::NAN
    } else if numerator == 0 {
        f64::INFINITY
    } else {
        -(numerator as f64 / denominator as f64).ln()
    }
}

#[cfg(test)]
fn sample_entropy_reference(signal: &[f64]) -> f64 {
    let order = 2;
    let tolerance = 0.2 * population_std(signal);
    let size = signal.len();
    let mut numerator = 0_u64;
    let mut denominator = 0_u64;
    for offset in 1..size - order {
        let mut n_numerator =
            u32::from((signal[order] - signal[order + offset]).abs() >= tolerance);
        let mut n_denominator = 0_u32;
        for index in 0..order {
            let different = u32::from((signal[index] - signal[index + offset]).abs() >= tolerance);
            n_numerator += different;
            n_denominator += different;
        }
        numerator += u64::from(n_numerator == 0);
        denominator += u64::from(n_denominator == 0);
        let mut previous_in =
            u32::from((signal[order] - signal[offset + order]).abs() >= tolerance);
        for index in 1..size - offset - order {
            let outgoing =
                u32::from((signal[index - 1] - signal[index + offset - 1]).abs() >= tolerance);
            let incoming = u32::from(
                (signal[index + order] - signal[index + offset + order]).abs() >= tolerance,
            );
            n_numerator = n_numerator + incoming - outgoing;
            n_denominator = n_denominator + previous_in - outgoing;
            previous_in = incoming;
            numerator += u64::from(n_numerator == 0);
            denominator += u64::from(n_denominator == 0);
        }
    }
    if denominator == 0 {
        f64::NAN
    } else if numerator == 0 {
        f64::INFINITY
    } else {
        -(numerator as f64 / denominator as f64).ln()
    }
}

pub fn petrosian_fd(signal: &[f64]) -> f64 {
    let derivatives: Vec<f64> = signal.windows(2).map(|pair| pair[1] - pair[0]).collect();
    let crossings = derivatives
        .windows(2)
        .filter(|pair| pair[0].is_sign_negative() != pair[1].is_sign_negative())
        .count() as f64;
    let n = signal.len() as f64;
    n.log10() / (n.log10() + (n / (n + 0.4 * crossings)).log10())
}

pub fn katz_fd(signal: &[f64]) -> f64 {
    let distances: Vec<f64> = signal
        .windows(2)
        .map(|pair| (pair[1] - pair[0]).abs())
        .collect();
    let length = distances.iter().sum::<f64>();
    let average = mean(&distances);
    let diameter = signal
        .iter()
        .map(|value| (value - signal[0]).abs())
        .fold(0.0, f64::max);
    (length / average).log10() / (diameter / average).log10()
}

pub fn higuchi_fd(signal: &[f64]) -> f64 {
    let n = signal.len();
    let mut x = Vec::with_capacity(10);
    let mut y = Vec::with_capacity(10);
    for k in 1..=10 {
        let mut lengths = Vec::with_capacity(k);
        for m in 0..k {
            let n_max = (n - m - 1) / k;
            let mut length = 0.0;
            for index in 1..=n_max {
                length += (signal[m + index * k] - signal[m + (index - 1) * k]).abs();
            }
            length /= k as f64;
            length *= (n - 1) as f64 / (k * n_max) as f64;
            lengths.push(length);
        }
        let average = mean(&lengths);
        x.push((1.0 / k as f64).ln());
        y.push(average.ln());
    }
    linear_slope(&x, &y)
}

fn logarithmic_windows(minimum: f64, maximum: f64, factor: f64) -> Vec<usize> {
    let max_index = ((maximum / minimum).ln() / factor.ln()).floor() as usize;
    let mut values = vec![minimum as usize];
    for index in 0..=max_index {
        let value = (minimum * factor.powi(index as i32)).floor() as usize;
        if value > *values.last().unwrap() {
            values.push(value);
        }
    }
    values
}

pub fn detrended_fluctuation(signal: &[f64]) -> f64 {
    let center = mean(signal);
    let walk: Vec<f64> = signal
        .iter()
        .scan(0.0, |state, value| {
            *state += value - center;
            Some(*state)
        })
        .collect();
    let windows = logarithmic_windows(4.0, 0.1 * signal.len() as f64, 1.2);
    let mut n_values = Vec::new();
    let mut fluctuations = Vec::new();
    for size in windows {
        let blocks = walk.len() / size;
        let x: Vec<f64> = (0..size).map(|index| index as f64).collect();
        let mut block_variance = 0.0;
        for block in 0..blocks {
            let values = &walk[block * size..(block + 1) * size];
            let slope = linear_slope(&x, values);
            let intercept = mean(values) - slope * mean(&x);
            block_variance += values
                .iter()
                .enumerate()
                .map(|(index, value)| (value - intercept - slope * index as f64).powi(2))
                .sum::<f64>()
                / size as f64;
        }
        let fluctuation = (block_variance / blocks as f64).sqrt();
        if fluctuation > 0.0 {
            n_values.push((size as f64).ln());
            fluctuations.push(fluctuation.ln());
        }
    }
    if fluctuations.is_empty() {
        f64::NAN
    } else {
        linear_slope(&n_values, &fluctuations)
    }
}

pub(crate) fn lz_complexity(sequence: &[u32]) -> usize {
    let mut complexity = 1;
    let mut prefix_len = 1;
    let mut substring_len = 1;
    let mut max_substring_len = 1;
    let mut pointer = 0;
    while prefix_len + substring_len <= sequence.len() {
        if sequence[pointer + substring_len - 1] == sequence[prefix_len + substring_len - 1] {
            substring_len += 1;
        } else {
            max_substring_len = max_substring_len.max(substring_len);
            pointer += 1;
            if pointer == prefix_len {
                complexity += 1;
                prefix_len += max_substring_len;
                pointer = 0;
                max_substring_len = 1;
            }
            substring_len = 1;
        }
    }
    if substring_len != 1 {
        complexity += 1;
    }
    complexity
}

pub(crate) fn normalized_lz(sequence: &[u32]) -> f64 {
    let unique = sequence
        .iter()
        .copied()
        .collect::<BTreeSet<_>>()
        .len()
        .max(2) as f64;
    let n = sequence.len() as f64;
    lz_complexity(sequence) as f64 / (n / (n.ln() / unique.ln()))
}

pub fn lziv_complexity(signal: &[f64]) -> f64 {
    let center = mean(signal);
    let sequence: Vec<u32> = signal
        .iter()
        .map(|value| u32::from(*value > center))
        .collect();
    normalized_lz(&sequence)
}

pub fn all(signal: &[f64]) -> BTreeMap<&'static str, f64> {
    BTreeMap::from([
        ("perm_entropy_nonlinear", permutation_entropy(signal)),
        ("svd_entropy_nonlinear", svd_entropy(signal)),
        ("sample_entropy_nonlinear", sample_entropy(signal)),
        ("dfa_nonlinear", detrended_fluctuation(signal)),
        ("petrosian_nonlinear", petrosian_fd(signal)),
        ("katz_nonlinear", katz_fd(signal)),
        ("higuchi_nonlinear", higuchi_fd(signal)),
        ("lziv_nonlinear", lziv_complexity(signal)),
    ])
}

#[cfg(test)]
mod sample_entropy_tests {
    use super::*;

    #[test]
    fn fast_sample_entropy_matches_reference() {
        let mut seed = 7u64;
        for n in [50usize, 333, 1000, 3750] {
            let x: Vec<f64> = (0..n)
                .map(|i| {
                    seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                    ((seed >> 33) as f64 / 2e9) + (i as f64 * 0.07).sin() * 3.0
                })
                .collect();
            let a = sample_entropy(&x);
            let b = sample_entropy_reference(&x);
            assert!((a - b).abs() < 1e-12 || (a.is_nan() && b.is_nan()), "n={n}: {a} vs {b}");
        }
    }
}
