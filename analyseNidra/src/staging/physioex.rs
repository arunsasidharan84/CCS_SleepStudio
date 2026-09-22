use anyhow::{Context, Result};
use num_complex::Complex64;
use rustfft::FftPlanner;
use std::path::{Path, PathBuf};
use tract_onnx::prelude::*;

pub type TractPlan = SimplePlan<TypedFact, Box<dyn TypedOp>, Graph<TypedFact, Box<dyn TypedOp>>>;

pub struct PhysioExModel {
    pub plan: TractPlan,
    pub model_name: String,
}

impl PhysioExModel {
    pub fn load_from_path(model_path: &Path, model_name: &str) -> Result<Self> {
        if !model_path.exists() {
            anyhow::bail!("PhysioEx ONNX model not found at {:?}", model_path);
        }

        let plan = tract_onnx::onnx()
            .model_for_path(model_path)
            .with_context(|| format!("Loading PhysioEx ONNX model at {:?}", model_path))?
            .with_input_fact(0, f32::fact([1, 21, 1, 29, 129]).into())?
            .into_optimized()?
            .into_runnable()?;

        Ok(Self {
            plan,
            model_name: model_name.to_string(),
        })
    }

    pub fn resolve_model(model_name: &str) -> Result<PathBuf> {
        let filename = format!("{}.onnx", model_name);
        let candidates = [
            PathBuf::from(format!("assets/models/physioex/{}", filename)),
            PathBuf::from(format!("analyseNidra/assets/models/physioex/{}", filename)),
            PathBuf::from(format!("../assets/models/physioex/{}", filename)),
            PathBuf::from(format!("../analyseNidra/assets/models/physioex/{}", filename)),
        ];

        for c in &candidates {
            if c.exists() {
                return Ok(c.clone());
            }
        }

        if let Ok(exe) = std::env::current_exe() {
            if let Some(parent) = exe.parent() {
                let exe_candidates = [
                    parent.join(format!("assets/models/physioex/{}", filename)),
                    parent.join(format!("models/physioex/{}", filename)),
                    parent.join(format!("../Resources/models/physioex/{}", filename)),
                    parent.join(format!("../Resources/assets/models/physioex/{}", filename)),
                ];
                for c in &exe_candidates {
                    if c.exists() {
                        return Ok(c.clone());
                    }
                }
            }
        }

        anyhow::bail!(
            "PhysioEx ONNX model {} not found. Ensure assets/models/physioex/{}.onnx exists.",
            model_name,
            model_name
        )
    }

    /// Runs forward pass on a 21-epoch spectrogram sequence [21, 1, 29, 129].
    /// Returns 5 probabilities [W, N1, N2, N3, R] for the central epoch (index 10).
    pub fn score_sequence(&self, sequence: &[[f32; 29 * 129]; 21]) -> Result<[f64; 5]> {
        let mut flat = Vec::with_capacity(21 * 29 * 129);
        for ep in sequence {
            flat.extend_from_slice(ep);
        }

        let tensor = tract_ndarray::Array5::from_shape_vec((1, 21, 1, 29, 129), flat)?;
        let tract_tensor: Tensor = tensor.into();

        let outputs = self.plan.run(tvec!(tract_tensor.into()))?;
        let output = outputs[0].to_array_view::<f32>()?;

        // Output shape is [1, 21, 5]
        let center = 21 / 2; // 10
        let mut logits = [0.0f64; 5];
        for c in 0..5 {
            logits[c] = output[[0, center, c]] as f64;
        }

        // Softmax
        let max_l = logits.iter().copied().fold(f64::NEG_INFINITY, f64::max);
        let mut exp_sum = 0.0f64;
        let mut probs = [0.0f64; 5];
        for i in 0..5 {
            probs[i] = (logits[i] - max_l).exp();
            exp_sum += probs[i];
        }
        let inv_sum = 1.0f64 / exp_sum.max(1e-12);
        for i in 0..5 {
            probs[i] *= inv_sum;
        }

        Ok(probs)
    }
}

/// Computes xsleepnet 2D spectrogram for each 30s epoch (3000 samples at 100 Hz).
/// Returns array of shape [N, 29 * 129].
pub fn compute_xsleepnet_spectrograms(epochs: &[[f64; 3000]]) -> Vec<[f32; 29 * 129]> {
    let n_epochs = epochs.len();
    if n_epochs == 0 {
        return Vec::new();
    }

    // Periodic Hamming window of size 200
    let win_size = 200;
    let win: Vec<f64> = (0..win_size)
        .map(|i| 0.54 - 0.46 * (2.0 * std::f64::consts::PI * i as f64 / win_size as f64).cos())
        .collect();

    let win_energy: f64 = win.iter().map(|&w| w * w).sum();
    let scale = 1.0 / (100.0 * win_energy);
    let eps = f64::EPSILON;

    let mut planner = FftPlanner::new();
    let fft_256 = planner.plan_fft_forward(256);

    let mut raw_specs: Vec<[f32; 29 * 129]> = Vec::with_capacity(n_epochs);

    for raw_ep in epochs {
        // Standardize epoch: (x - mean) / max(std, 1e-6)
        let mean = raw_ep.iter().sum::<f64>() / 3000.0;
        let var = raw_ep.iter().map(|&x| (x - mean).powi(2)).sum::<f64>() / 3000.0;
        let std = var.sqrt().max(1e-6);

        let ep_norm: Vec<f64> = raw_ep.iter().map(|&x| (x - mean) / std).collect();

        let mut spec_flat = [0.0f32; 29 * 129];

        for t in 0..29 {
            let start = t * 100;
            let end = start + 200;
            let seg = &ep_norm[start..end];

            // Detrend constant: seg - mean(seg)
            let seg_mean = seg.iter().sum::<f64>() / 200.0;

            let mut fft_buffer = vec![Complex64::new(0.0, 0.0); 256];
            for i in 0..200 {
                fft_buffer[i] = Complex64::new((seg[i] - seg_mean) * win[i], 0.0);
            }

            fft_256.process(&mut fft_buffer);

            // One-sided power spectral density:
            for k in 0..129 {
                let mut p = fft_buffer[k].norm_sqr() * scale;
                if k > 0 && k < 128 {
                    p *= 2.0;
                }
                // 20 * log10(p + eps)
                let log_val = 20.0 * (p + eps).log10();
                spec_flat[t * 129 + k] = log_val as f32;
            }
        }

        raw_specs.push(spec_flat);
    }

    // Global standardization matching Python:
    let total_elements = (n_epochs * 29 * 129) as f64;
    let mut min_val = f32::INFINITY;
    let mut max_val = f32::NEG_INFINITY;
    let mut sum = 0.0f64;
    for spec in &raw_specs {
        for &val in spec.iter() {
            if val < min_val { min_val = val; }
            if val > max_val { max_val = val; }
            sum += val as f64;
        }
    }
    let global_mean = sum / total_elements;

    let mut var_sum = 0.0f64;
    for spec in &raw_specs {
        for &val in spec.iter() {
            var_sum += ((val as f64) - global_mean).powi(2);
        }
    }
    let global_std = (var_sum / total_elements).sqrt().max(1e-6);
    println!("Rust raw_specs min: {}, max: {}, mean: {}, std: {}", min_val, max_val, global_mean, global_std);

    let mut standardized_specs = Vec::with_capacity(n_epochs);
    for spec in &raw_specs {
        let mut std_spec = [0.0f32; 29 * 129];
        for i in 0..(29 * 129) {
            std_spec[i] = (((spec[i] as f64) - global_mean) / global_std) as f32;
        }
        standardized_specs.push(std_spec);
    }

    standardized_specs
}

/// Builds 21-epoch sequence windows with edge replication matching PhysioEx:
/// left = repeat(epochs[:1], 10), right = repeat(epochs[-1:], 10).
pub fn build_physioex_sequences(specs: &[[f32; 29 * 129]]) -> Vec<[[f32; 29 * 129]; 21]> {
    let n = specs.len();
    if n == 0 {
        return Vec::new();
    }

    let half = 10;
    let mut padded = Vec::with_capacity(n + 2 * half);

    for _ in 0..half {
        padded.push(specs[0]);
    }
    for s in specs {
        padded.push(*s);
    }
    for _ in 0..half {
        padded.push(specs[n - 1]);
    }

    let mut sequences = Vec::with_capacity(n);
    for i in 0..n {
        let mut seq = [[0.0f32; 29 * 129]; 21];
        for k in 0..21 {
            seq[k] = padded[i + k];
        }
        sequences.push(seq);
    }

    sequences
}

/// Scores an EEG recording using a PhysioEx model (SeqSleepNet or SleepTransformer).
pub fn score_physioex_channel(
    signal: &[f64],
    sfreq: f64,
    model: &PhysioExModel,
) -> Result<Vec<[f64; 5]>> {
    use crate::signal::mne_fft_resample;

    let resampled = if (sfreq - 100.0).abs() > 0.01 {
        mne_fft_resample(signal, sfreq, 100.0)
    } else {
        signal.to_vec()
    };

    let n_epochs = resampled.len() / 3000;
    let mut epochs = Vec::with_capacity(n_epochs);
    for ep in 0..n_epochs {
        let mut ep_data = [0.0f64; 3000];
        ep_data.copy_from_slice(&resampled[ep * 3000..(ep + 1) * 3000]);
        epochs.push(ep_data);
    }

    let specs = compute_xsleepnet_spectrograms(&epochs);
    let sequences = build_physioex_sequences(&specs);

    let mut all_probs = Vec::with_capacity(sequences.len());
    for seq in &sequences {
        let probs = model.score_sequence(seq)?;
        all_probs.push(probs);
    }

    Ok(all_probs)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_seqsleepnet_numerical_parity() -> Result<()> {
        let model_path = PhysioExModel::resolve_model("seqsleepnet")?;
        let model = PhysioExModel::load_from_path(&model_path, "seqsleepnet")?;

        let model_dir = model_path.parent().unwrap();
        let bin_path = model_dir.join("seqsleepnet_test_input.bin");
        let json_path = model_dir.join("seqsleepnet_test_vector.json");

        if !bin_path.exists() || !json_path.exists() {
            println!("Test vector files not found, skipping seqsleepnet parity test.");
            return Ok(());
        }

        let raw_bytes = std::fs::read(&bin_path)?;
        assert_eq!(raw_bytes.len(), 21 * 29 * 129 * 4);

        let mut seq = [[0.0f32; 29 * 129]; 21];
        let mut idx = 0;
        for ep in 0..21 {
            for t in 0..(29 * 129) {
                let b = [
                    raw_bytes[idx * 4],
                    raw_bytes[idx * 4 + 1],
                    raw_bytes[idx * 4 + 2],
                    raw_bytes[idx * 4 + 3],
                ];
                seq[ep][t] = f32::from_le_bytes(b);
                idx += 1;
            }
        }

        let probs = model.score_sequence(&seq)?;

        let json_str = std::fs::read_to_string(&json_path)?;
        let test_vec: serde_json::Value = serde_json::from_str(&json_str)?;
        let exp_probs: Vec<f64> = test_vec["expected_probs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_f64().unwrap())
            .collect();

        println!("Rust SeqSleepNet probs:    {:?}", probs);
        println!("PyTorch SeqSleepNet probs: {:?}", exp_probs);

        for (i, (&actual, &expected)) in probs.iter().zip(exp_probs.iter()).enumerate() {
            let diff = (actual - expected).abs();
            assert!(
                diff < 1e-4,
                "Class {} prob mismatch: Rust={}, PyTorch={}, diff={}",
                i,
                actual,
                expected,
                diff
            );
        }

        println!("SeqSleepNet numerical parity verified within 1e-4 tolerance!");
        Ok(())
    }

    #[test]
    fn test_sleeptransformer_numerical_parity() -> Result<()> {
        let model_path = PhysioExModel::resolve_model("sleeptransformer")?;
        let model = PhysioExModel::load_from_path(&model_path, "sleeptransformer")?;

        let model_dir = model_path.parent().unwrap();
        let bin_path = model_dir.join("sleeptransformer_test_input.bin");
        let json_path = model_dir.join("sleeptransformer_test_vector.json");

        if !bin_path.exists() || !json_path.exists() {
            println!("Test vector files not found, skipping sleeptransformer parity test.");
            return Ok(());
        }

        let raw_bytes = std::fs::read(&bin_path)?;
        assert_eq!(raw_bytes.len(), 21 * 29 * 129 * 4);

        let mut seq = [[0.0f32; 29 * 129]; 21];
        let mut idx = 0;
        for ep in 0..21 {
            for t in 0..(29 * 129) {
                let b = [
                    raw_bytes[idx * 4],
                    raw_bytes[idx * 4 + 1],
                    raw_bytes[idx * 4 + 2],
                    raw_bytes[idx * 4 + 3],
                ];
                seq[ep][t] = f32::from_le_bytes(b);
                idx += 1;
            }
        }

        let probs = model.score_sequence(&seq)?;

        let json_str = std::fs::read_to_string(&json_path)?;
        let test_vec: serde_json::Value = serde_json::from_str(&json_str)?;
        let exp_probs: Vec<f64> = test_vec["expected_probs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_f64().unwrap())
            .collect();

        println!("Rust SleepTransformer probs:    {:?}", probs);
        println!("PyTorch SleepTransformer probs: {:?}", exp_probs);

        for (i, (&actual, &expected)) in probs.iter().zip(exp_probs.iter()).enumerate() {
            let diff = (actual - expected).abs();
            assert!(
                diff < 1e-4,
                "Class {} prob mismatch: Rust={}, PyTorch={}, diff={}",
                i,
                actual,
                expected,
                diff
            );
        }

        println!("SleepTransformer numerical parity verified within 1e-4 tolerance!");
        Ok(())
    }

    #[test]
    fn test_xsleepnet_spectrogram_parity() -> Result<()> {
        let raw_path = PathBuf::from("assets/models/physioex/raw_epochs_c4.npy");
        let spec_path = PathBuf::from("assets/models/physioex/specs_c4.npy");

        if !raw_path.exists() || !spec_path.exists() {
            println!("NPY files not found, skipping spectrogram parity test.");
            return Ok(());
        }

        let raw_bytes = std::fs::read(&raw_path)?;
        let spec_bytes = std::fs::read(&spec_path)?;
        let header_len = 128;

        let n_epochs = 784;
        let mut epochs = Vec::with_capacity(n_epochs);
        for ep in 0..n_epochs {
            let mut ep_data = [0.0f64; 3000];
            for t in 0..3000 {
                let off = header_len + (ep * 3000 + t) * 4;
                let b = [
                    raw_bytes[off],
                    raw_bytes[off + 1],
                    raw_bytes[off + 2],
                    raw_bytes[off + 3],
                ];
                ep_data[t] = f32::from_le_bytes(b) as f64;
            }
            epochs.push(ep_data);
        }

        let computed_specs = compute_xsleepnet_spectrograms(&epochs);
        assert_eq!(computed_specs.len(), n_epochs);

        // Compare against SciPy xsleepnet_preprocessing
        let mut max_diff = 0.0f32;
        let mut max_non_nyquist_diff = 0.0f32;
        let mut max_ep = 0;
        let mut max_idx = 0;
        let mut max_actual = 0.0f32;
        let mut max_expected = 0.0f32;
        for ep in 0..n_epochs {
            for idx in 0..(29 * 129) {
                let off = header_len + (ep * 29 * 129 + idx) * 4;
                let b = [
                    spec_bytes[off],
                    spec_bytes[off + 1],
                    spec_bytes[off + 2],
                    spec_bytes[off + 3],
                ];
                let expected = f32::from_le_bytes(b);
                let actual = computed_specs[ep][idx];
                let diff = (actual - expected).abs();
                if diff > max_diff {
                    max_diff = diff;
                    max_ep = ep;
                    max_idx = idx;
                    max_actual = actual;
                    max_expected = expected;
                }
                if idx % 129 < 128 && diff > max_non_nyquist_diff {
                    max_non_nyquist_diff = diff;
                }
            }
        }

        println!(
            "Max diff: {:.6} at ep={}, f={}, Non-Nyquist max diff: {:.8}",
            max_diff,
            max_ep,
            max_idx % 129,
            max_non_nyquist_diff
        );
        assert!(
            max_non_nyquist_diff < 0.005,
            "Non-Nyquist spectrogram should match SciPy within 0.005, got {}",
            max_non_nyquist_diff
        );
        assert!(
            max_diff < 0.10,
            "Overall spectrogram should match SciPy within 0.10, got {}",
            max_diff
        );
        println!("xsleepnet spectrogram parity verified with SciPy!");
        Ok(())
    }

    #[test]
    fn test_seqsleepnet_night_parity() -> Result<()> {
        let spec_path = PathBuf::from("assets/models/physioex/specs_c4.npy");
        let gt_path = PathBuf::from("assets/models/physioex/AS_CNT_08_Night1_seqsleepnet_scoring.json");

        if !spec_path.exists() || !gt_path.exists() {
            println!("Required files not found, skipping SeqSleepNet night parity test.");
            return Ok(());
        }

        let model_path = PhysioExModel::resolve_model("seqsleepnet")?;
        let model = PhysioExModel::load_from_path(&model_path, "seqsleepnet")?;

        let spec_bytes = std::fs::read(&spec_path)?;
        let header_len = 128;
        let n_epochs = 784;

        let mut specs = Vec::with_capacity(n_epochs);
        for ep in 0..n_epochs {
            let mut ep_spec = [0.0f32; 29 * 129];
            for idx in 0..(29 * 129) {
                let off = header_len + (ep * 29 * 129 + idx) * 4;
                let b = [
                    spec_bytes[off],
                    spec_bytes[off + 1],
                    spec_bytes[off + 2],
                    spec_bytes[off + 3],
                ];
                ep_spec[idx] = f32::from_le_bytes(b);
            }
            specs.push(ep_spec);
        }

        let sequences = build_physioex_sequences(&specs);
        let mut all_probs = Vec::with_capacity(sequences.len());

        let start = std::time::Instant::now();
        for seq in &sequences {
            let probs = model.score_sequence(seq)?;
            all_probs.push(probs);
        }
        let elapsed = start.elapsed();
        println!("Rust SeqSleepNet scored {} epochs in {:.2?}", all_probs.len(), elapsed);
        println!("Rust SeqSleepNet epoch 0 probs: {:?}", all_probs[0]);

        let gt_str = std::fs::read_to_string(&gt_path)?;
        let gt_json: serde_json::Value = serde_json::from_str(&gt_str)?;
        let gt_records = gt_json[0].as_array().unwrap();

        let mut matching_stages = 0;
        let mut max_prob_diff = 0.0f64;
        let stage_names = ["Wake", "N1", "N2", "N3", "REM"];
        let stage_keys = ["W", "N1", "N2", "N3", "R"];

        for (_ep, (probs, gt_rec)) in all_probs.iter().zip(gt_records.iter()).enumerate() {
            let rust_stage_idx = probs
                .iter()
                .enumerate()
                .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
                .unwrap()
                .0;
            let rust_stage = stage_names[rust_stage_idx];
            let gt_stage = gt_rec["stage"].as_str().unwrap();

            if rust_stage == gt_stage {
                matching_stages += 1;
            }

            let gt_probs = &gt_rec["probabilities"];
            for (c_idx, &key) in stage_keys.iter().enumerate() {
                let gt_p = gt_probs[key].as_f64().unwrap();
                let diff = (probs[c_idx] - gt_p).abs();
                if diff > max_prob_diff {
                    max_prob_diff = diff;
                }
            }
        }

        let concordance = matching_stages as f64 / all_probs.len() as f64 * 100.0;
        println!(
            "SeqSleepNet Stage Concordance: {}/{} ({:.2}%), Max Prob Diff: {:.6}",
            matching_stages,
            all_probs.len(),
            concordance,
            max_prob_diff
        );

        assert!(
            concordance >= 75.0,
            "SeqSleepNet single-channel C4 concordance should be >= 75.0%, got {:.2}%",
            concordance
        );
        Ok(())
    }

    #[test]
    fn test_sleeptransformer_night_parity() -> Result<()> {
        let spec_path = PathBuf::from("assets/models/physioex/specs_c4.npy");
        let gt_path = PathBuf::from("assets/models/physioex/AS_CNT_08_Night1_sleeptransformer_scoring.json");

        if !spec_path.exists() || !gt_path.exists() {
            println!("Required files not found, skipping SleepTransformer night parity test.");
            return Ok(());
        }

        let model_path = PhysioExModel::resolve_model("sleeptransformer")?;
        let model = PhysioExModel::load_from_path(&model_path, "sleeptransformer")?;

        let spec_bytes = std::fs::read(&spec_path)?;
        let header_len = 128;
        let n_epochs = 784;

        let mut specs = Vec::with_capacity(n_epochs);
        for ep in 0..n_epochs {
            let mut ep_spec = [0.0f32; 29 * 129];
            for idx in 0..(29 * 129) {
                let off = header_len + (ep * 29 * 129 + idx) * 4;
                let b = [
                    spec_bytes[off],
                    spec_bytes[off + 1],
                    spec_bytes[off + 2],
                    spec_bytes[off + 3],
                ];
                ep_spec[idx] = f32::from_le_bytes(b);
            }
            specs.push(ep_spec);
        }

        let sequences = build_physioex_sequences(&specs);
        let mut all_probs = Vec::with_capacity(sequences.len());

        let start = std::time::Instant::now();
        for seq in &sequences {
            let probs = model.score_sequence(seq)?;
            all_probs.push(probs);
        }
        let elapsed = start.elapsed();
        println!("Rust SleepTransformer scored {} epochs in {:.2?}", all_probs.len(), elapsed);

        let gt_str = std::fs::read_to_string(&gt_path)?;
        let gt_json: serde_json::Value = serde_json::from_str(&gt_str)?;
        let gt_records = gt_json[0].as_array().unwrap();

        let mut matching_stages = 0;
        let mut max_prob_diff = 0.0f64;
        let stage_names = ["Wake", "N1", "N2", "N3", "REM"];
        let stage_keys = ["W", "N1", "N2", "N3", "R"];

        for (_ep, (probs, gt_rec)) in all_probs.iter().zip(gt_records.iter()).enumerate() {
            let rust_stage_idx = probs
                .iter()
                .enumerate()
                .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
                .unwrap()
                .0;
            let rust_stage = stage_names[rust_stage_idx];
            let gt_stage = gt_rec["stage"].as_str().unwrap();

            if rust_stage == gt_stage {
                matching_stages += 1;
            }

            let gt_probs = &gt_rec["probabilities"];
            for (c_idx, &key) in stage_keys.iter().enumerate() {
                let gt_p = gt_probs[key].as_f64().unwrap();
                let diff = (probs[c_idx] - gt_p).abs();
                if diff > max_prob_diff {
                    max_prob_diff = diff;
                }
            }
        }

        let concordance = matching_stages as f64 / all_probs.len() as f64 * 100.0;
        println!(
            "SleepTransformer Stage Concordance: {}/{} ({:.2}%), Max Prob Diff: {:.6}",
            matching_stages,
            all_probs.len(),
            concordance,
            max_prob_diff
        );

        assert!(
            concordance >= 98.0,
            "SleepTransformer concordance should be >= 98.0%, got {:.2}%",
            concordance
        );
        Ok(())
    }

}

