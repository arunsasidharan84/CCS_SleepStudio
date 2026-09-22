use super::montage::{lookup_electrode_pos, standard_1020_montage, ElectrodePos};
use super::spline::SphericalSplineInterpolator;
use std::collections::HashSet;

#[derive(Debug, Clone)]
pub struct RansacConfig {
    pub corr_threshold: f64,
    pub flatline_threshold_sec: f64,
    pub n_resample: usize,
    pub min_channels_ratio: f64,
}

impl Default for RansacConfig {
    fn default() -> Self {
        Self {
            corr_threshold: 0.80,
            flatline_threshold_sec: 5.0,
            n_resample: 25,
            min_channels_ratio: 0.35,
        }
    }
}

#[derive(Debug, Clone)]
pub struct BadChannelDetectionResult {
    pub bad_channels: Vec<String>,
    pub bad_channel_indices: Vec<usize>,
    pub flatline_channels: Vec<String>,
    pub ransac_channels: Vec<String>,
    pub mean_correlations: Vec<f64>,
}

/// Detects bad channels using flatline criteria and RANSAC correlation with spherical splines.
pub fn detect_bad_channels(
    channel_names: &[String],
    signals: &[Vec<f64>],
    sample_rate: f64,
    config: &RansacConfig,
) -> BadChannelDetectionResult {
    let n_channels = channel_names.len();
    if n_channels == 0 || signals.is_empty() {
        return BadChannelDetectionResult {
            bad_channels: Vec::new(),
            bad_channel_indices: Vec::new(),
            flatline_channels: Vec::new(),
            ransac_channels: Vec::new(),
            mean_correlations: vec![1.0; n_channels],
        };
    }

    let n_samples = signals[0].len();
    let flat_samples = (config.flatline_threshold_sec * sample_rate).round() as usize;

    let mut bad_indices = HashSet::new();
    let mut flatline_bads = Vec::new();

    // 1. Flatline Detection
    for (idx, sig) in signals.iter().enumerate() {
        // Global variance check
        let mean = sig.iter().sum::<f64>() / sig.len().max(1) as f64;
        let var = sig.iter().map(|&x| (x - mean).powi(2)).sum::<f64>() / sig.len().max(1) as f64;
        if var < 1e-12 {
            bad_indices.insert(idx);
            flatline_bads.push(channel_names[idx].clone());
            continue;
        }

        // Sliding run of identical / flatline values
        let mut max_flat_run = 0;
        let mut curr_flat_run = 0;
        for i in 1..sig.len() {
            if (sig[i] - sig[i - 1]).abs() < 1e-12 {
                curr_flat_run += 1;
                if curr_flat_run > max_flat_run {
                    max_flat_run = curr_flat_run;
                }
            } else {
                curr_flat_run = 0;
            }
        }
        if flat_samples > 0 && max_flat_run >= flat_samples {
            bad_indices.insert(idx);
            flatline_bads.push(channel_names[idx].clone());
        }
    }

    // 2. Lookup electrode positions for RANSAC
    let montage = standard_1020_montage();
    let mut localized_indices = Vec::new();
    let mut localized_positions = Vec::new();

    for (idx, name) in channel_names.iter().enumerate() {
        if bad_indices.contains(&idx) {
            continue;
        }
        if let Some(pos) = lookup_electrode_pos(&montage, name) {
            localized_indices.push(idx);
            localized_positions.push(pos);
        }
    }

    let mut ransac_bads = Vec::new();
    let mut mean_correlations = vec![1.0; n_channels];

    // If we have at least 4 localized non-flat channels, run RANSAC
    if localized_indices.len() >= 4 {
        let epoch_len = sample_rate.round() as usize;
        let n_epochs = (n_samples / epoch_len).min(300); // Check up to 300 1-sec epochs
        let n_loc = localized_indices.len();
        let subset_size = ((n_loc as f64 * config.min_channels_ratio).ceil() as usize).max(3);

        // Store cumulative correlation and count per localized channel
        let mut corr_sums = vec![0.0; n_loc];
        let mut corr_counts = vec![0usize; n_loc];

        // Seeded deterministic pseudo-random sequence for reproducible RANSAC
        let mut rng_state: u64 = 0x853c49e6748fea9b;
        let mut lcg_rand = || -> f64 {
            rng_state = rng_state.wrapping_mul(6364136223846793005).wrapping_add(1);
            ((rng_state >> 33) as f64) / ((1u32 << 31) as f64)
        };

        for ep in 0..n_epochs {
            let start = ep * epoch_len;
            let end = start + epoch_len;

            for _iter in 0..config.n_resample {
                // Randomly select subset of channels
                let mut chosen = vec![false; n_loc];
                let mut chosen_indices = Vec::with_capacity(subset_size);
                while chosen_indices.len() < subset_size {
                    let rand_idx = (lcg_rand() * n_loc as f64) as usize % n_loc;
                    if !chosen[rand_idx] {
                        chosen[rand_idx] = true;
                        chosen_indices.push(rand_idx);
                    }
                }

                let src_positions: Vec<ElectrodePos> = chosen_indices.iter().map(|&i| localized_positions[i]).collect();
                let src_signals: Vec<Vec<f64>> = chosen_indices
                    .iter()
                    .map(|&i| signals[localized_indices[i]][start..end].to_vec())
                    .collect();

                let tgt_indices: Vec<usize> = (0..n_loc).filter(|&i| !chosen[i]).collect();
                let tgt_positions: Vec<ElectrodePos> = tgt_indices.iter().map(|&i| localized_positions[i]).collect();

                if let Some(interpolator) = SphericalSplineInterpolator::new(&src_positions, &tgt_positions) {
                    let reconstructed = interpolator.interpolate(&src_signals);
                    for (k, &loc_idx) in tgt_indices.iter().enumerate() {
                        let actual = &signals[localized_indices[loc_idx]][start..end];
                        let pred = &reconstructed[k];
                        let corr = pearson_correlation(actual, pred);
                        if corr.is_finite() {
                            corr_sums[loc_idx] += corr;
                            corr_counts[loc_idx] += 1;
                        }
                    }
                }
            }
        }

        // Evaluate average correlation
        for loc_idx in 0..n_loc {
            let global_idx = localized_indices[loc_idx];
            if corr_counts[loc_idx] > 0 {
                let avg_corr = corr_sums[loc_idx] / corr_counts[loc_idx] as f64;
                mean_correlations[global_idx] = avg_corr;
                if avg_corr < config.corr_threshold {
                    bad_indices.insert(global_idx);
                    ransac_bads.push(channel_names[global_idx].clone());
                }
            }
        }
    }

    let mut sorted_bad_indices: Vec<usize> = bad_indices.into_iter().collect();
    sorted_bad_indices.sort_unstable();
    let bad_channels: Vec<String> = sorted_bad_indices.iter().map(|&i| channel_names[i].clone()).collect();

    BadChannelDetectionResult {
        bad_channels,
        bad_channel_indices: sorted_bad_indices,
        flatline_channels: flatline_bads,
        ransac_channels: ransac_bads,
        mean_correlations,
    }
}

/// Interpolates identified bad channels using spherical splines from good channels.
pub fn interpolate_bad_channels(
    channel_names: &[String],
    signals: &mut [Vec<f64>],
    bad_channel_indices: &[usize],
) {
    if bad_channel_indices.is_empty() || signals.is_empty() {
        return;
    }

    let montage = standard_1020_montage();
    let bad_set: HashSet<usize> = bad_channel_indices.iter().copied().collect();

    let mut good_indices = Vec::new();
    let mut good_positions = Vec::new();
    let mut bad_to_interpolate = Vec::new();
    let mut bad_positions = Vec::new();

    for (idx, name) in channel_names.iter().enumerate() {
        if let Some(pos) = lookup_electrode_pos(&montage, name) {
            if bad_set.contains(&idx) {
                bad_to_interpolate.push(idx);
                bad_positions.push(pos);
            } else {
                good_indices.push(idx);
                good_positions.push(pos);
            }
        }
    }

    if good_positions.len() < 3 || bad_positions.is_empty() {
        return;
    }

    if let Some(interpolator) = SphericalSplineInterpolator::new(&good_positions, &bad_positions) {
        let good_signals: Vec<Vec<f64>> = good_indices.iter().map(|&i| signals[i].clone()).collect();
        let interpolated = interpolator.interpolate(&good_signals);
        for (k, &bad_idx) in bad_to_interpolate.iter().enumerate() {
            signals[bad_idx] = interpolated[k].clone();
        }
    }
}

fn pearson_correlation(x: &[f64], y: &[f64]) -> f64 {
    let n = x.len().min(y.len());
    if n < 2 {
        return 0.0;
    }
    let mx = x.iter().sum::<f64>() / n as f64;
    let my = y.iter().sum::<f64>() / n as f64;

    let mut cov = 0.0;
    let mut var_x = 0.0;
    let mut var_y = 0.0;

    for i in 0..n {
        let dx = x[i] - mx;
        let dy = y[i] - my;
        cov += dx * dy;
        var_x += dx * dx;
        var_y += dy * dy;
    }

    let denom = (var_x * var_y).sqrt();
    if denom > 1e-12 {
        cov / denom
    } else {
        0.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_flatline_detection() {
        let names = vec!["Cz".to_string(), "C3".to_string(), "C4".to_string()];
        let signals = vec![
            vec![1.0; 1000],          // Flatline
            vec![5.0; 1000],          // Flatline
            (0..1000).map(|i| (i as f64 * 0.1).sin()).collect(), // Active sine
        ];
        let result = detect_bad_channels(&names, &signals, 100.0, &RansacConfig::default());
        assert!(result.bad_channels.contains(&"Cz".to_string()));
        assert!(result.bad_channels.contains(&"C3".to_string()));
        assert!(!result.bad_channels.contains(&"C4".to_string()));
    }
}
