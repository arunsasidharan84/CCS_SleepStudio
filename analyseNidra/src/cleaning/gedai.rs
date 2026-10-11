use super::montage::{is_reference_channel, lookup_electrode_pos, standard_1020_montage, ElectrodePos};
use nalgebra::{Cholesky, DMatrix, SymmetricEigen};

/// Configuration parameters for GEDAI denoising.
#[derive(Debug, Clone)]
pub struct GedaiConfig {
    pub epoch_size_sec: f64,
    pub reg_lambda: f64,
    pub threshold_percentile: f64,
    pub n_wavelet_levels: usize,
}

impl Default for GedaiConfig {
    fn default() -> Self {
        Self {
            epoch_size_sec: 1.0,
            reg_lambda: 0.05,
            threshold_percentile: 0.95,
            n_wavelet_levels: 3,
        }
    }
}

/// Computes reference covariance matrix for standard 10-20 channels using spherical leadfield model.
/// Between two electrodes i and j with angle theta:
/// C_ref(i, j) is proportional to the dipolar leadfield correlation: sum_n (2n+1)/(n+1)^2 * P_n(cos theta).
pub fn compute_reference_covariance(positions: &[ElectrodePos]) -> DMatrix<f64> {
    let n = positions.len();
    let mut cov = DMatrix::<f64>::zeros(n, n);

    for i in 0..n {
        for j in 0..n {
            let dot = positions[i].dot(&positions[j]);
            // Dipolar cortical source covariance on spherical head model
            let mut val = 0.0;
            let mut p_prev2 = 1.0;
            let mut p_prev1 = dot;
            val += (3.0 / 4.0) * p_prev1; // n=1

            for degree in 2..=30 {
                let d = degree as f64;
                let p_curr = ((2.0 * d - 1.0) * dot * p_prev1 - (d - 1.0) * p_prev2) / d;
                let factor = (2.0 * d + 1.0) / ((d + 1.0) * (d + 1.0));
                val += factor * p_curr;
                p_prev2 = p_prev1;
                p_prev1 = p_curr;
            }
            cov[(i, j)] = val;
        }
    }

    cov
}

/// Solves Generalized Eigendecomposition A v = lambda B v, where B is symmetric positive definite.
/// Returns sorted eigenvalues (descending) and eigenvectors as matrix columns.
pub fn solve_gevd(a: &DMatrix<f64>, b: &DMatrix<f64>) -> Option<(Vec<f64>, DMatrix<f64>)> {
    let n = a.nrows();
    if n != a.ncols() || n != b.nrows() || n != b.ncols() {
        return None;
    }

    // Cholesky decomposition of B = L L^T
    let cholesky = Cholesky::new(b.clone())?;
    let l = cholesky.l();
    let l_inv = l.clone().try_inverse()?;

    // Symmetric matrix K = L^-1 * A * L^-T
    let k = &l_inv * a * l_inv.transpose();
    let sym_k = (&k + &k.transpose()) * 0.5;

    // Eigendecomposition of K: K y = lambda y
    let eigen = SymmetricEigen::new(sym_k);
    let mut evals: Vec<(f64, usize)> = eigen
        .eigenvalues
        .iter()
        .copied()
        .enumerate()
        .map(|(idx, val)| (val, idx))
        .collect();

    // Sort descending by eigenvalue
    evals.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));

    let sorted_evals: Vec<f64> = evals.iter().map(|&(v, _)| v).collect();
    let mut sorted_evecs = DMatrix::<f64>::zeros(n, n);

    let l_inv_t = l_inv.transpose();
    for (out_col, &(_, orig_idx)) in evals.iter().enumerate() {
        let y_col = eigen.eigenvectors.column(orig_idx);
        let v_col = &l_inv_t * &y_col;
        sorted_evecs.set_column(out_col, &v_col);
    }

    Some((sorted_evals, sorted_evecs))
}

/// Zero-phase Haar MODWT (Maximal Overlap Discrete Wavelet Transform) 1D Multi-Resolution Analysis.
/// Decomposes signal into `level` zero-phase detail components and 1 zero-phase approximation component
/// that sum identically to `signal`.
pub fn haar_modwt_mra(signal: &[f64], level: usize) -> Vec<Vec<f64>> {
    let n = signal.len();
    if n == 0 || level == 0 {
        return vec![signal.to_vec()];
    }

    let mut approx = signal.to_vec();
    let mut details = Vec::with_capacity(level);

    for j in 0..level {
        let step = 1 << j;
        let mut next_approx = vec![0.0; n];
        let mut detail = vec![0.0; n];

        for i in 0..n {
            let prev_idx = if i >= step { i - step } else { 0 };
            let next_idx = if i + step < n { i + step } else { n - 1 };
            // Zero-phase symmetric 2nd-order Haar analysis+synthesis filter:
            // A = 0.25 * x[i-s] + 0.5 * x[i] + 0.25 * x[i+s]
            // D = -0.25 * x[i-s] + 0.5 * x[i] - 0.25 * x[i+s]
            // Exact identity: A[i] + D[i] == approx[i]
            let a = 0.25 * approx[prev_idx] + 0.5 * approx[i] + 0.25 * approx[next_idx];
            let d = approx[i] - a;
            next_approx[i] = a;
            detail[i] = d;
        }

        details.push(detail);
        approx = next_approx;
    }

    // Return [D1, D2, ..., D_level, A_level]
    let mut components = details;
    components.push(approx);
    components
}

/// Inverse Haar MODWT MRA: reconstructs signal from components.
pub fn haar_modwt_mra_reconstruct(components: &[Vec<f64>]) -> Vec<f64> {
    if components.is_empty() {
        return Vec::new();
    }
    let n = components[0].len();
    let mut reconstructed = vec![0.0; n];
    for comp in components {
        for (i, &val) in comp.iter().enumerate().take(n) {
            reconstructed[i] += val;
        }
    }
    reconstructed
}

/// Denoises multi-channel continuous EEG data using GEDAI while preserving
/// reference channels (M1, M2, A1, A2) and physiological sleep rhythms
/// (0-30 Hz: slow waves, K-complexes, delta, theta, alpha, spindles, beta).
pub fn gedai_denoise(
    channel_names: &[String],
    signals: &[Vec<f64>],
    sample_rate: f64,
    config: &GedaiConfig,
) -> Vec<Vec<f64>> {
    let n_total = signals.len();
    if n_total < 2 || signals[0].is_empty() {
        return signals.to_vec();
    }
    let n_samples = signals[0].len();

    // Only run GEDAI spatial decomposition on non-reference scalp electrodes.
    let montage = standard_1020_montage();
    let mut scalp_indices = Vec::new();
    let mut positions = Vec::new();
    for (idx, name) in channel_names.iter().enumerate() {
        if is_reference_channel(name) {
            continue;
        }
        if let Some(pos) = lookup_electrode_pos(&montage, name) {
            scalp_indices.push(idx);
            positions.push(pos);
        }
    }

    let n_chans = scalp_indices.len();
    if n_chans < 2 {
        return signals.to_vec();
    }

    // Build reference covariance for scalp electrodes
    let ref_cov = compute_reference_covariance(&positions);
    let sym_ref = (&ref_cov + &ref_cov.transpose()) * 0.5;
    let eigen_ref = SymmetricEigen::new(sym_ref.clone());
    let mean_eig = eigen_ref.eigenvalues.mean();

    // Regularize reference covariance
    let ref_cov_reg = (1.0 - config.reg_lambda) * sym_ref
        + DMatrix::<f64>::identity(n_chans, n_chans) * (config.reg_lambda * mean_eig);

    // Choose wavelet decomposition depth so only high-frequency detail bands (> ~30 Hz)
    // are spatially filtered and the physiological sleep band (0-30 Hz: slow waves, spindles)
    // is preserved without distortion.
    let n_levels = ((sample_rate / 62.5).log2().round() as usize).clamp(2, 5);
    let mut band_filtered_data = vec![DMatrix::<f64>::zeros(n_chans, n_samples); n_levels + 1];

    for (local_ch, &global_ch) in scalp_indices.iter().enumerate() {
        let wavelet_bands = haar_modwt_mra(&signals[global_ch], n_levels);
        for (band_idx, band) in wavelet_bands.iter().enumerate() {
            for t in 0..n_samples {
                band_filtered_data[band_idx][(local_ch, t)] = band[t];
            }
        }
    }

    // Denoise only high-frequency detail bands (D1..D_{n_levels-1}, > ~30 Hz) with GEDAI,
    // keeping the physiological sleep band (0..30 Hz) and original reference intact.
    let mut cleaned_final = DMatrix::<f64>::zeros(n_chans, n_samples);
    for (band_idx, band_data) in band_filtered_data.iter().enumerate() {
        if band_idx + 1 < n_levels {
            let cleaned_band = gedai_stream_pass(band_data, sample_rate, &ref_cov_reg, config);
            cleaned_final += cleaned_band;
        } else {
            // Keep physiological sleep bands (< ~30 Hz: slow waves, delta, theta, alpha, spindles, beta) unprocessed
            cleaned_final += band_data;
        }
    }

    // Reconstruct full channel list (preserving reference channels untouched)
    let mut result = signals.to_vec();
    for (local_ch, &global_ch) in scalp_indices.iter().enumerate() {
        for t in 0..n_samples {
            result[global_ch][t] = cleaned_final[(local_ch, t)];
        }
    }

    result
}

/// Internal GEDAI pass on a high-frequency wavelet detail band.
fn gedai_stream_pass(
    data: &DMatrix<f64>,
    sample_rate: f64,
    ref_cov_reg: &DMatrix<f64>,
    config: &GedaiConfig,
) -> DMatrix<f64> {
    let (n_chans, n_samples) = (data.nrows(), data.ncols());
    let epoch_samples = (config.epoch_size_sec * sample_rate).round() as usize;
    if epoch_samples == 0 || n_samples < epoch_samples {
        return data.clone();
    }

    let n_epochs = n_samples / epoch_samples;
    let mut cleaned_stream1 = DMatrix::<f64>::zeros(n_chans, n_epochs * epoch_samples);

    // Compute covariance and GEVD per epoch for Stream 1
    let mut max_epoch_evals = Vec::with_capacity(n_epochs);
    let mut epoch_evals = Vec::with_capacity(n_epochs);
    let mut epoch_evecs = Vec::with_capacity(n_epochs);

    for ep in 0..n_epochs {
        let start = ep * epoch_samples;
        let ep_slice = data.columns(start, epoch_samples);
        let cov = (&ep_slice * &ep_slice.transpose()) / (epoch_samples as f64 - 1.0).max(1.0);

        if let Some((evals, evecs)) = solve_gevd(&cov, ref_cov_reg) {
            if let Some(&max_ev) = evals.first() {
                if max_ev.is_finite() && max_ev > 1e-12 {
                    max_epoch_evals.push(max_ev);
                }
            }
            epoch_evals.push(evals);
            epoch_evecs.push(evecs);
        } else {
            epoch_evals.push(vec![1.0; n_chans]);
            epoch_evecs.push(DMatrix::identity(n_chans, n_chans));
        }
    }

    // Determine artifact threshold from the distribution of epoch maximum eigenvalues
    max_epoch_evals.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));

    let threshold_val = if !max_epoch_evals.is_empty() {
        let cutoff_idx = ((max_epoch_evals.len() as f64) * config.threshold_percentile) as usize;
        let idx = cutoff_idx.min(max_epoch_evals.len() - 1);
        max_epoch_evals[idx] * 4.0 // Only reject extreme transient artifacts (> 4x 95th percentile max eigenvalue)
    } else {
        f64::INFINITY
    };

    // Clean Stream 1 epochs
    for ep in 0..n_epochs {
        let start = ep * epoch_samples;
        let ep_slice = data.columns(start, epoch_samples);
        let evals = &epoch_evals[ep];
        let evecs = &epoch_evecs[ep];

        // Spatial filter matrix W: zero out non-artifact components (keep artifacts to subtract)
        let mut w = evecs.clone();
        for (col, &val) in evals.iter().enumerate() {
            if val <= threshold_val {
                w.set_column(col, &nalgebra::DVector::zeros(n_chans));
            }
        }

        // Project: artifacts = (V^-T) * (W^T * X)
        let artifact_sources = w.transpose() * &ep_slice;
        if let Some(v_inv_t) = evecs.transpose().try_inverse() {
            let reconstructed_artifacts = &v_inv_t * artifact_sources;
            let cleaned_ep = &ep_slice - reconstructed_artifacts;
            cleaned_stream1.columns_mut(start, epoch_samples).copy_from(&cleaned_ep);
        } else {
            cleaned_stream1.columns_mut(start, epoch_samples).copy_from(&ep_slice);
        }
    }

    // Pad remaining trailing samples if any
    let mut final_out = DMatrix::<f64>::zeros(n_chans, n_samples);
    final_out.columns_mut(0, n_epochs * epoch_samples).copy_from(&cleaned_stream1);
    if n_samples > n_epochs * epoch_samples {
        let rem = n_samples - n_epochs * epoch_samples;
        final_out.columns_mut(n_epochs * epoch_samples, rem).copy_from(&data.columns(n_epochs * epoch_samples, rem));
    }

    final_out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_solve_gevd_synthetic() {
        let a = DMatrix::from_diagonal(&nalgebra::DVector::from_vec(vec![10.0, 1.0]));
        let b = DMatrix::from_diagonal(&nalgebra::DVector::from_vec(vec![1.0, 1.0]));
        let (evals, _) = solve_gevd(&a, &b).expect("GEVD should solve");
        assert!((evals[0] - 10.0).abs() < 1e-4);
        assert!((evals[1] - 1.0).abs() < 1e-4);
    }

    #[test]
    fn test_haar_modwt_mra_perfect_reconstruction() {
        let sig: Vec<f64> = (0..64).map(|i| (i as f64 * 0.2).sin()).collect();
        let comps = haar_modwt_mra(&sig, 3);
        assert_eq!(comps.len(), 4); // D1, D2, D3, A3
        let recon = haar_modwt_mra_reconstruct(&comps);
        assert_eq!(recon.len(), sig.len());
        for i in 0..sig.len() {
            assert!((recon[i] - sig[i]).abs() < 1e-6);
        }
    }
}
