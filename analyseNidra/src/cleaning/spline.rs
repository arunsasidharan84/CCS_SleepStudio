use super::montage::ElectrodePos;
use nalgebra::DMatrix;

const SPLINE_M: f64 = 4.0;
const N_LEGENDRE_TERMS: usize = 50;
const REGULARIZATION: f64 = 1e-5;

/// Precomputes coefficients for the spherical spline kernel g(x).
/// g(x) = (1 / 4pi) * sum_{n=1}^inf ((2n+1) / (n*(n+1))^m) * P_n(x)
pub fn spherical_spline_g(x: f64) -> f64 {
    let x = x.clamp(-1.0, 1.0);
    let mut p_prev2 = 1.0; // P_0(x)
    let mut p_prev1 = x;   // P_1(x)

    let mut sum = 0.0;
    // n = 1 term: (2*1+1)/(1*2)^m * P_1(x) = 3 / 2^4 * x = 3/16 * x
    let factor_1 = 3.0 / 2.0_f64.powf(SPLINE_M);
    sum += factor_1 * p_prev1;

    for n in 2..=N_LEGENDRE_TERMS {
        let n_f = n as f64;
        let p_curr = ((2.0 * n_f - 1.0) * x * p_prev1 - (n_f - 1.0) * p_prev2) / n_f;
        let denom = (n_f * (n_f + 1.0)).powf(SPLINE_M);
        let factor = (2.0 * n_f + 1.0) / denom;
        sum += factor * p_curr;

        p_prev2 = p_prev1;
        p_prev1 = p_curr;
    }

    sum / (4.0 * std::f64::consts::PI)
}

/// Precomputed Spherical Spline Interpolator.
/// Maps good channel signals (N channels) to target channel signals (M channels) via a precomputed linear matrix.
pub struct SphericalSplineInterpolator {
    /// Projection matrix W: shape (n_targets, n_sources)
    pub projection_matrix: DMatrix<f64>,
}

impl SphericalSplineInterpolator {
    /// Creates an interpolator from source positions to target positions.
    pub fn new(source_positions: &[ElectrodePos], target_positions: &[ElectrodePos]) -> Option<Self> {
        let n_src = source_positions.len();
        if n_src < 3 {
            return None;
        }

        // Build (N+1) x (N+1) system matrix K
        let mut k = DMatrix::<f64>::zeros(n_src + 1, n_src + 1);
        for i in 0..n_src {
            for j in 0..n_src {
                let dot = source_positions[i].dot(&source_positions[j]);
                let mut val = spherical_spline_g(dot);
                if i == j {
                    val += REGULARIZATION;
                }
                k[(i, j)] = val;
            }
            k[(i, n_src)] = 1.0;
            k[(n_src, i)] = 1.0;
        }
        k[(n_src, n_src)] = 0.0;

        // Invert K using LU decomposition
        let k_inv = k.lu().try_inverse()?;

        // Build target evaluation matrix G_target: shape (n_targets, n_src + 1)
        let n_tgt = target_positions.len();
        let mut g_target = DMatrix::<f64>::zeros(n_tgt, n_src + 1);
        for i in 0..n_tgt {
            for j in 0..n_src {
                let dot = target_positions[i].dot(&source_positions[j]);
                g_target[(i, j)] = spherical_spline_g(dot);
            }
            g_target[(i, n_src)] = 1.0;
        }

        // The linear mapping from source potentials v (size n_src) to target potentials (size n_tgt):
        // W = G_target * K_inv[:, 0..n_src]
        let k_inv_top = k_inv.columns(0, n_src);
        let projection_matrix = &g_target * &k_inv_top;

        Some(Self { projection_matrix })
    }

    /// Interpolates target channel time series from source channel time series.
    /// `source_signals`: slice of channel signals [channel_idx][sample_idx], all must have same length T.
    /// Returns: Vec of target channel signals [target_idx][sample_idx].
    pub fn interpolate(&self, source_signals: &[Vec<f64>]) -> Vec<Vec<f64>> {
        if source_signals.is_empty() {
            return Vec::new();
        }
        let n_src = source_signals.len();
        let n_samples = source_signals[0].len();
        let n_tgt = self.projection_matrix.nrows();

        if self.projection_matrix.ncols() != n_src {
            return vec![vec![0.0; n_samples]; n_tgt];
        }

        let mut output = vec![vec![0.0; n_samples]; n_tgt];
        for tgt_idx in 0..n_tgt {
            let row = self.projection_matrix.row(tgt_idx);
            for (src_idx, signal) in source_signals.iter().enumerate() {
                let weight = row[src_idx];
                if weight.abs() > 1e-12 {
                    for (t, &val) in signal.iter().enumerate() {
                        output[tgt_idx][t] += weight * val;
                    }
                }
            }
        }

        output
    }

    /// Interpolate in-place into an epoch matrix (channels x samples).
    pub fn interpolate_epoch(&self, src_epoch: &DMatrix<f64>) -> DMatrix<f64> {
        &self.projection_matrix * src_epoch
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_spherical_spline_g_symmetry_and_monotonicity() {
        let g1 = spherical_spline_g(1.0);
        let g0 = spherical_spline_g(0.0);
        let g_neg = spherical_spline_g(-1.0);

        // Electrodes closer together (larger dot product) should have stronger coupling
        assert!(g1 > g0);
        assert!(g0 > g_neg);
    }

    #[test]
    fn test_spherical_spline_reconstruction() {
        // Create 4 known electrodes and 1 test electrode
        let src_positions = [
            ElectrodePos::new(0.0, 0.719, 0.695),  // Fz
            ElectrodePos::new(-0.719, 0.0, 0.695), // C3
            ElectrodePos::new(0.719, 0.0, 0.695),  // C4
            ElectrodePos::new(0.0, -0.719, 0.695), // Pz
        ];
        // Target: Cz (center of the 4 electrodes)
        let tgt_positions = [ElectrodePos::new(0.0, 0.0, 1.0)];

        let interpolator = SphericalSplineInterpolator::new(&src_positions, &tgt_positions)
            .expect("Interpolator should build");

        // Set symmetrical potentials at the 4 perimeter electrodes: e.g. 10.0 uV each
        let n_samples = 100;
        let src_signals = vec![
            vec![10.0; n_samples],
            vec![10.0; n_samples],
            vec![10.0; n_samples],
            vec![10.0; n_samples],
        ];

        let interpolated = interpolator.interpolate(&src_signals);
        assert_eq!(interpolated.len(), 1);
        assert_eq!(interpolated[0].len(), n_samples);

        // By symmetry, the potential at Cz should be approximately 10.0 uV
        let reconstructed_val = interpolated[0][0];
        assert!(
            (reconstructed_val - 10.0).abs() < 0.5,
            "Reconstructed Cz potential {} should be close to 10.0",
            reconstructed_val
        );
    }
}
