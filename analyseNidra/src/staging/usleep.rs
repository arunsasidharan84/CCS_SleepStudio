use anyhow::{Context, Result};
use std::path::{Path, PathBuf};
use tract_onnx::prelude::*;

pub type TractPlan = SimplePlan<TypedFact, Box<dyn TypedOp>, Graph<TypedFact, Box<dyn TypedOp>>>;

pub struct USleepModel {
    pub plan: TractPlan,
}

impl USleepModel {
    pub fn load_from_path(model_path: &Path) -> Result<Self> {
        if !model_path.exists() {
            anyhow::bail!("U-Sleep ONNX model not found at {:?}", model_path);
        }

        let plan = tract_onnx::onnx()
            .model_for_path(model_path)
            .with_context(|| format!("Loading U-Sleep ONNX model at {:?}", model_path))?
            .with_input_fact(0, f32::fact([1, 3, 2, 3000]).into())?
            .into_optimized()?
            .into_runnable()?;

        Ok(Self { plan })
    }

    pub fn resolve_model(model_arg: Option<&str>) -> Result<PathBuf> {
        if let Some(arg) = model_arg {
            let p = PathBuf::from(arg);
            if p.exists() {
                return Ok(p);
            }
        }

        let candidates = [
            PathBuf::from("assets/models/usleep/usleep.onnx"),
            PathBuf::from("analyseNidra/assets/models/usleep/usleep.onnx"),
            PathBuf::from("../assets/models/usleep/usleep.onnx"),
            PathBuf::from("../analyseNidra/assets/models/usleep/usleep.onnx"),
        ];

        for c in &candidates {
            if c.exists() {
                return Ok(c.clone());
            }
        }

        if let Ok(exe) = std::env::current_exe() {
            if let Some(parent) = exe.parent() {
                let exe_candidates = [
                    parent.join("assets/models/usleep/usleep.onnx"),
                    parent.join("models/usleep/usleep.onnx"),
                    parent.join("../Resources/models/usleep/usleep.onnx"),
                    parent.join("../Resources/assets/models/usleep/usleep.onnx"),
                ];
                for c in &exe_candidates {
                    if c.exists() {
                        return Ok(c.clone());
                    }
                }
            }
        }

        anyhow::bail!("U-Sleep ONNX model not found. Ensure assets/models/usleep/usleep.onnx exists.")
    }

    /// Run forward pass on a single 3-epoch sequence (shape [3, 2, 3000]).
    /// Returns 5 probabilities [W, N1, N2, N3, R] for the central epoch.
    pub fn score_sequence(&self, sequence: &[[[f32; 3000]; 2]; 3]) -> Result<[f64; 5]> {
        // Flatten into 1 x 3 x 2 x 3000 flat buffer
        let mut flat = Vec::with_capacity(3 * 2 * 3000);
        for s in 0..3 {
            for c in 0..2 {
                flat.extend_from_slice(&sequence[s][c]);
            }
        }

        let tensor = tract_ndarray::Array4::from_shape_vec((1, 3, 2, 3000), flat)?;
        let tract_tensor: Tensor = tensor.into();

        let outputs = self.plan.run(tvec!(tract_tensor.into()))?;
        let output = outputs[0].to_array_view::<f32>()?;

        // Output shape is [1, 5, 3]
        // Central epoch is index 1
        let mut logits = [0.0f64; 5];
        for class_idx in 0..5 {
            logits[class_idx] = output[[0, class_idx, 1]] as f64;
        }

        // Softmax over 5 classes
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

/// Computes robust IQR normalization matching Python:
/// median = median(x)
/// q1, q3 = 25th, 75th percentiles
/// iqr = max(q3 - q1, 1e-6)
/// out = (x - median) / iqr
pub fn normalize_channel_iqr(signal: &[f64]) -> Vec<f32> {
    if signal.is_empty() {
        return Vec::new();
    }
    let mut sorted = signal.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = sorted.len();

    let percentile = |p: f64| -> f64 {
        let idx = p * (n - 1) as f64;
        let lo = idx.floor() as usize;
        let hi = idx.ceil() as usize;
        let weight = idx - lo as f64;
        sorted[lo] * (1.0 - weight) + sorted[hi] * weight
    };

    let median = percentile(0.50);
    let q1 = percentile(0.25);
    let q3 = percentile(0.75);
    let iqr = (q3 - q1).max(1e-6);

    signal
        .iter()
        .map(|&v| ((v - median) / iqr) as f32)
        .collect()
}

/// Builds sliding 3-epoch sequence tensors with edge replication.
/// Each epoch is 30s at 100 Hz (3000 samples).
pub fn build_usleep_sequences(
    eeg_norm: &[f32],
    second_norm: Option<&[f32]>,
) -> Vec<[[[f32; 3000]; 2]; 3]> {
    let samples_per_epoch = 3000;
    let n_epochs = eeg_norm.len() / samples_per_epoch;
    if n_epochs == 0 {
        return Vec::new();
    }

    let second_ch = second_norm.unwrap_or(eeg_norm);

    // Extract raw epochs for both channels: [n_epochs, 2, 3000]
    let mut epochs = Vec::with_capacity(n_epochs);
    for ep in 0..n_epochs {
        let start = ep * samples_per_epoch;
        let end = start + samples_per_epoch;

        let mut ch0 = [0.0f32; 3000];
        let mut ch1 = [0.0f32; 3000];
        ch0.copy_from_slice(&eeg_norm[start..end]);
        ch1.copy_from_slice(&second_ch[start..end]);
        epochs.push([ch0, ch1]);
    }

    // Build 3-epoch sequences with edge replication:
    // Left edge (epoch 0): repeat epoch 0 -> [ep0, ep0, ep1]
    // Middle: [ep_{i-1}, ep_i, ep_{i+1}]
    // Right edge (epoch N-1): repeat epoch N-1 -> [ep_{N-2}, ep_{N-1}, ep_{N-1}]
    let mut sequences = Vec::with_capacity(n_epochs);
    for i in 0..n_epochs {
        let prev = if i == 0 { &epochs[0] } else { &epochs[i - 1] };
        let curr = &epochs[i];
        let next = if i == n_epochs - 1 { &epochs[n_epochs - 1] } else { &epochs[i + 1] };

        sequences.push([*prev, *curr, *next]);
    }

    sequences
}

/// Scores a full recording with U-Sleep.
/// Handles resampling to 100 Hz, 0.3-35 Hz bandpass filtering, IQR normalization,
/// 3-epoch sequence construction, and ONNX model evaluation.
pub fn score_usleep_recording(
    eeg: &[f64],
    eog: Option<&[f64]>,
    sfreq: f64,
    model: &USleepModel,
) -> Result<Vec<[f64; 5]>> {
    use crate::signal::{mne_fft_resample, mne_overlap_add};

    // Filter using exact MNE firwin taps
    let eeg_filt = if (sfreq - 125.0).abs() < 0.5 {
        let taps: Vec<f64> = serde_json::from_str(include_str!("../../assets/models/usleep/mne_filter_taps_125hz.json"))
            .unwrap_or_default();
        if !taps.is_empty() {
            mne_overlap_add(eeg, &taps)
        } else {
            crate::signal::filter_bandpass_fir(eeg, sfreq, 0.3, 35.0)
        }
    } else {
        crate::signal::filter_bandpass_fir(eeg, sfreq, 0.3, 35.0)
    };

    let eog_filt = eog.map(|sig| {
        if (sfreq - 125.0).abs() < 0.5 {
            let taps: Vec<f64> = serde_json::from_str(include_str!("../../assets/models/usleep/mne_filter_taps_125hz.json"))
                .unwrap_or_default();
            if !taps.is_empty() {
                mne_overlap_add(sig, &taps)
            } else {
                crate::signal::filter_bandpass_fir(sig, sfreq, 0.3, 35.0)
            }
        } else {
            crate::signal::filter_bandpass_fir(sig, sfreq, 0.3, 35.0)
        }
    });

    // Resample to 100 Hz if necessary
    let eeg_100 = if (sfreq - 100.0).abs() > 0.01 {
        mne_fft_resample(&eeg_filt, sfreq, 100.0)
    } else {
        eeg_filt
    };

    let eog_100 = eog_filt.map(|sig| {
        if (sfreq - 100.0).abs() > 0.01 {
            mne_fft_resample(&sig, sfreq, 100.0)
        } else {
            sig
        }
    });

    // IQR normalization
    let eeg_norm = normalize_channel_iqr(&eeg_100);
    let eog_norm = eog_100.map(|sig| normalize_channel_iqr(&sig));

    let sequences = build_usleep_sequences(&eeg_norm, eog_norm.as_deref());
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
    fn test_usleep_onnx_load_and_infer() -> Result<()> {
        let model_path = USleepModel::resolve_model(None)?;
        let model = USleepModel::load_from_path(&model_path)?;

        let dummy_seq = [[[0.0f32; 3000]; 2]; 3];
        let probs = model.score_sequence(&dummy_seq)?;

        assert_eq!(probs.len(), 5);
        let sum: f64 = probs.iter().sum();
        assert!((sum - 1.0).abs() < 1e-5, "Softmax sum should be 1.0, got {}", sum);
        println!("U-Sleep dummy inference passed with probabilities: {:?}", probs);
        Ok(())
    }

    #[test]
    fn test_usleep_numerical_parity() -> Result<()> {
        let model_path = USleepModel::resolve_model(None)?;
        let model = USleepModel::load_from_path(&model_path)?;

        let model_dir = model_path.parent().unwrap();
        let bin_path = model_dir.join("usleep_test_input.bin");
        let json_path = model_dir.join("usleep_test_vector.json");

        if !bin_path.exists() || !json_path.exists() {
            println!("Test vector files not found, skipping parity test.");
            return Ok(());
        }

        let raw_bytes = std::fs::read(&bin_path)?;
        assert_eq!(raw_bytes.len(), 3 * 2 * 3000 * 4);

        let mut seq = [[[0.0f32; 3000]; 2]; 3];
        let mut idx = 0;
        for s in 0..3 {
            for c in 0..2 {
                for t in 0..3000 {
                    let b = [
                        raw_bytes[idx * 4],
                        raw_bytes[idx * 4 + 1],
                        raw_bytes[idx * 4 + 2],
                        raw_bytes[idx * 4 + 3],
                    ];
                    seq[s][c][t] = f32::from_le_bytes(b);
                    idx += 1;
                }
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

        println!("Rust U-Sleep probs:     {:?}", probs);
        println!("PyTorch U-Sleep probs:  {:?}", exp_probs);

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

        println!("U-Sleep numerical parity verified within 1e-4 tolerance!");
        Ok(())
    }

    #[test]
    fn test_usleep_night_parity() -> Result<()> {
        let edf_path = PathBuf::from("../SamplePSGData/Data/AS_CNT_08_Night1.edf");
        let gt_path = PathBuf::from("/tmp/py_usleep_test/AS_CNT_08_Night1_usleep_scoring.json");

        if !edf_path.exists() || !gt_path.exists() {
            println!("EDF or ground truth not found, skipping full-night test.");
            return Ok(());
        }

        let model_path = USleepModel::resolve_model(None)?;
        let model = USleepModel::load_from_path(&model_path)?;

        let edf = crate::edf::read_selected(
            &edf_path,
            &["C4".to_string(), "LOC1".to_string(), "ROC1".to_string()],
        )?;

        let c4 = &edf.data_uv[0];
        let mut eog = edf.data_uv[1].clone();
        for (i, &v) in edf.data_uv[2].iter().enumerate() {
            eog[i] -= v;
        }

        println!("Running Rust U-Sleep on {} epochs...", c4.len() / 3750);
        let start = std::time::Instant::now();
        let all_probs = score_usleep_recording(c4, Some(&eog), edf.sfreq, &model)?;
        let elapsed = start.elapsed();
        println!("Rust U-Sleep scored {} epochs in {:.2?}", all_probs.len(), elapsed);

        // Load Python ground truth
        let gt_str = std::fs::read_to_string(&gt_path)?;
        let gt_json: serde_json::Value = serde_json::from_str(&gt_str)?;
        let gt_records = gt_json[0].as_array().unwrap();

        assert_eq!(all_probs.len(), gt_records.len());

        let mut matching_stages = 0;
        let mut max_prob_diff = 0.0f64;
        let stage_names = ["Wake", "N1", "N2", "N3", "REM"];
        let stage_keys = ["W", "N1", "N2", "N3", "R"];

        for (ep, (probs, gt_rec)) in all_probs.iter().zip(gt_records.iter()).enumerate() {
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
            "U-Sleep Stage Concordance: {}/{} ({:.2}%), Max Prob Diff: {:.6}",
            matching_stages,
            all_probs.len(),
            concordance,
            max_prob_diff
        );

        Ok(())
    }

    #[test]
    fn test_usleep_onnx_night_parity_direct() -> Result<()> {
        let model_path = USleepModel::resolve_model(None)?;
        let model = USleepModel::load_from_path(&model_path)?;
        let model_dir = model_path.parent().unwrap();

        let c4_path = model_dir.join("c4_norm.npy");
        let eog_path = model_dir.join("eog_norm.npy");
        let gt_path = model_dir.join("AS_CNT_08_Night1_usleep_scoring.json");

        if !c4_path.exists() || !eog_path.exists() || !gt_path.exists() {
            println!("Saved npy files not found, skipping direct test.");
            return Ok(());
        }

        // Read npy raw data (skipping 128-byte NPY header)
        let c4_bytes = std::fs::read(&c4_path)?;
        let eog_bytes = std::fs::read(&eog_path)?;
        let header_len = 128; // Standard NPY 1.0 header length for 1D float32

        let n_samples = (c4_bytes.len() - header_len) / 4;
        let mut c4_norm = Vec::with_capacity(n_samples);
        let mut eog_norm = Vec::with_capacity(n_samples);

        for i in 0..n_samples {
            let offset = header_len + i * 4;
            c4_norm.push(f32::from_le_bytes([
                c4_bytes[offset],
                c4_bytes[offset + 1],
                c4_bytes[offset + 2],
                c4_bytes[offset + 3],
            ]));
            eog_norm.push(f32::from_le_bytes([
                eog_bytes[offset],
                eog_bytes[offset + 1],
                eog_bytes[offset + 2],
                eog_bytes[offset + 3],
            ]));
        }

        let sequences = build_usleep_sequences(&c4_norm, Some(&eog_norm));
        println!("Scoring {} sequences with Rust ONNX model...", sequences.len());

        let mut all_probs = Vec::with_capacity(sequences.len());
        for seq in &sequences {
            let probs = model.score_sequence(seq)?;
            all_probs.push(probs);
        }

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
            "DIRECT U-Sleep Stage Concordance: {}/{} ({:.2}%), Max Prob Diff: {:.6}",
            matching_stages,
            all_probs.len(),
            concordance,
            max_prob_diff
        );

        assert!(
            concordance >= 99.0,
            "Direct ONNX concordance should be >= 99.0%, got {:.2}%",
            concordance
        );
        Ok(())
    }
}



