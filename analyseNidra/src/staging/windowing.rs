use crate::signal::mne_fft_resample;

pub const TARGET_STAGING_HZ: f64 = 100.0;
pub const SAMPLES_PER_EPOCH: usize = 3000;
pub const SEQUENCE_LENGTH: usize = 20;

/// Robust median and Interquartile Range (IQR) normalization per epoch.
pub fn normalize_epoch_iqr(epoch: &[f64]) -> Vec<f32> {
    let n = epoch.len();
    if n == 0 {
        return Vec::new();
    }

    let mut sorted = epoch.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));

    let median = if n % 2 == 0 {
        (sorted[n / 2 - 1] + sorted[n / 2]) * 0.5
    } else {
        sorted[n / 2]
    };

    let q1_idx = (n as f64 * 0.25) as usize;
    let q3_idx = (n as f64 * 0.75) as usize;
    let q1 = sorted[q1_idx.min(n - 1)];
    let q3 = sorted[q3_idx.min(n - 1)];
    let iqr = (q3 - q1).max(1e-6);

    epoch.iter().map(|&x| ((x - median) / iqr) as f32).collect()
}

/// Prepares full recording into a series of normalized 30-second 100 Hz epochs.
pub fn prepare_staging_epochs(raw_signal: &[f64], original_sfreq: f64) -> Vec<Vec<f32>> {
    let resampled = if (original_sfreq - TARGET_STAGING_HZ).abs() > 0.01 {
        mne_fft_resample(raw_signal, original_sfreq, TARGET_STAGING_HZ)
    } else {
        raw_signal.to_vec()
    };

    let n_epochs = resampled.len() / SAMPLES_PER_EPOCH;
    let mut epochs = Vec::with_capacity(n_epochs);

    for ep in 0..n_epochs {
        let start = ep * SAMPLES_PER_EPOCH;
        let end = start + SAMPLES_PER_EPOCH;
        let norm_ep = normalize_epoch_iqr(&resampled[start..end]);
        epochs.push(norm_ep);
    }

    epochs
}

/// Constructs a 20-epoch sequence buffer for scoring epoch `epoch_index`.
/// If `epoch_index` < 19, prepends the earliest real epoch to avoid initial flatline artifacts.
pub fn build_sequence_window(epochs: &[Vec<f32>], epoch_index: usize) -> Vec<f32> {
    assert!(!epochs.is_empty());
    let mut flat = Vec::with_capacity(SEQUENCE_LENGTH * SAMPLES_PER_EPOCH);

    for k in (0..SEQUENCE_LENGTH).rev() {
        let idx = if epoch_index >= k {
            epoch_index - k
        } else {
            0 // Repeat earliest real epoch for causal startup
        };
        flat.extend_from_slice(&epochs[idx]);
    }

    flat
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_epoch_iqr() {
        let data: Vec<f64> = (0..3000).map(|x| x as f64).collect();
        let norm = normalize_epoch_iqr(&data);
        assert_eq!(norm.len(), 3000);
        // Median of 0..3000 is ~1499.5, should be normalized to around 0.0
        assert!(norm[1500].abs() < 0.1);
    }
}
