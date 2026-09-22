use anyhow::{bail, Context, Result};
use std::path::PathBuf;
use tract_onnx::prelude::*;

pub type RunnablePlan = SimplePlan<TypedFact, Box<dyn TypedOp>, Graph<TypedFact, Box<dyn TypedOp>>>;

pub struct GsscModel {
    pub eeg_path: PathBuf,
    pub eog_path: PathBuf,
    pub both_path: PathBuf,
    pub gru_path: PathBuf,
}

impl GsscModel {
    pub fn resolve_models() -> Result<Self> {
        let candidates = [
            PathBuf::from("assets/models/gssc"),
            PathBuf::from("analyseNidra/assets/models/gssc"),
            PathBuf::from("../assets/models/gssc"),
        ];

        let base_dir = candidates
            .iter()
            .find(|p| p.join("gssc_eeg_dynshape.onnx").exists())
            .cloned()
            .or_else(|| {
                std::env::current_exe().ok().and_then(|mut exe| {
                    exe.pop();
                    let asset = exe.join("assets/models/gssc");
                    if asset.join("gssc_eeg_dynshape.onnx").exists() {
                        Some(asset)
                    } else {
                        None
                    }
                })
            })
            .context("Could not find GSSC models directory")?;

        // Use the dynshape-patched variants: Tract handles [0,G,-1] Reshape incorrectly,
        // so we use models where that Reshape is replaced with dynamic Shape+Gather+Concat.
        Ok(Self {
            eeg_path: base_dir.join("gssc_eeg_dynshape.onnx"),
            eog_path: base_dir.join("gssc_eog_dynshape.onnx"),
            both_path: base_dir.join("gssc_both_dynshape.onnx"),
            gru_path: base_dir.join("gssc_gru.onnx"),
        })
    }

    pub fn build_eeg_plan(&self, n_epochs: usize) -> Result<RunnablePlan> {
        let plan = tract_onnx::onnx()
            .model_for_path(&self.eeg_path)?
            .with_input_fact(
                0,
                InferenceFact::dt_shape(f32::datum_type(), tvec!(n_epochs, 1, 2560)),
            )?
            .into_optimized()?
            .into_runnable()?;
        Ok(plan)
    }

    pub fn build_eog_plan(&self, n_epochs: usize) -> Result<RunnablePlan> {
        let plan = tract_onnx::onnx()
            .model_for_path(&self.eog_path)?
            .with_input_fact(
                0,
                InferenceFact::dt_shape(f32::datum_type(), tvec!(n_epochs, 1, 2560)),
            )?
            .into_optimized()?
            .into_runnable()?;
        Ok(plan)
    }

    pub fn build_both_plan(&self, n_epochs: usize) -> Result<RunnablePlan> {
        let plan = tract_onnx::onnx()
            .model_for_path(&self.both_path)?
            .with_input_fact(
                0,
                InferenceFact::dt_shape(f32::datum_type(), tvec!(n_epochs, 1, 2560)),
            )?
            .with_input_fact(
                1,
                InferenceFact::dt_shape(f32::datum_type(), tvec!(n_epochs, 1, 2560)),
            )?
            .into_optimized()?
            .into_runnable()?;
        Ok(plan)
    }

    pub fn build_gru_plan(&self, n_epochs: usize) -> Result<RunnablePlan> {
        let plan = tract_onnx::onnx()
            .model_for_path(&self.gru_path)?
            .with_input_fact(
                0,
                InferenceFact::dt_shape(f32::datum_type(), tvec!(n_epochs, 1, 512)),
            )?
            .with_input_fact(
                1,
                InferenceFact::dt_shape(f32::datum_type(), tvec!(10, 1, 256)),
            )?
            .into_optimized()?
            .into_runnable()?;
        Ok(plan)
    }

    pub fn encode_eeg(&self, plan: &RunnablePlan, eeg: &[f32], n_epochs: usize) -> Result<Vec<f32>> {
        let mut all_reps = Vec::with_capacity(n_epochs * 512);
        for ep in 0..n_epochs {
            let ep_slice = &eeg[ep * 2560..(ep + 1) * 2560];
            let tensor = tract_ndarray::Array3::from_shape_vec((1, 1, 2560), ep_slice.to_vec())?;
            let tract_tensor: Tensor = tensor.into();
            let outputs = plan.run(tvec!(tract_tensor.into()))?;
            let output = outputs[0].to_array_view::<f32>()?;
            all_reps.extend_from_slice(output.as_slice().unwrap_or(&[]));
        }
        Ok(all_reps)
    }

    pub fn encode_eog(&self, plan: &RunnablePlan, eog: &[f32], n_epochs: usize) -> Result<Vec<f32>> {
        let mut all_reps = Vec::with_capacity(n_epochs * 512);
        for ep in 0..n_epochs {
            let ep_slice = &eog[ep * 2560..(ep + 1) * 2560];
            let tensor = tract_ndarray::Array3::from_shape_vec((1, 1, 2560), ep_slice.to_vec())?;
            let tract_tensor: Tensor = tensor.into();
            let outputs = plan.run(tvec!(tract_tensor.into()))?;
            let output = outputs[0].to_array_view::<f32>()?;
            all_reps.extend_from_slice(output.as_slice().unwrap_or(&[]));
        }
        Ok(all_reps)
    }

    pub fn encode_both(
        &self,
        plan: &RunnablePlan,
        eeg: &[f32],
        eog: &[f32],
        n_epochs: usize,
    ) -> Result<Vec<f32>> {
        let mut all_reps = Vec::with_capacity(n_epochs * 512);
        for ep in 0..n_epochs {
            let eeg_slice = &eeg[ep * 2560..(ep + 1) * 2560];
            let eog_slice = &eog[ep * 2560..(ep + 1) * 2560];
            let eeg_tensor = tract_ndarray::Array3::from_shape_vec((1, 1, 2560), eeg_slice.to_vec())?;
            let eog_tensor = tract_ndarray::Array3::from_shape_vec((1, 1, 2560), eog_slice.to_vec())?;
            let tract_eeg: Tensor = eeg_tensor.into();
            let tract_eog: Tensor = eog_tensor.into();
            let outputs = plan.run(tvec!(tract_eeg.into(), tract_eog.into()))?;
            let output = outputs[0].to_array_view::<f32>()?;
            all_reps.extend_from_slice(output.as_slice().unwrap_or(&[]));
        }
        Ok(all_reps)
    }

    pub fn run_gru(
        &self,
        plan: &RunnablePlan,
        reps: &[f32],
        n_epochs: usize,
    ) -> Result<Vec<[f64; 5]>> {
        let reps_tensor = tract_ndarray::Array3::from_shape_vec((n_epochs, 1, 512), reps.to_vec())?;
        let hidden_tensor = tract_ndarray::Array3::<f32>::zeros((10, 1, 256));
        let tract_reps: Tensor = reps_tensor.into();
        let tract_hidden: Tensor = hidden_tensor.into();

        let outputs = plan.run(tvec!(tract_reps.into(), tract_hidden.into()))?;
        let logits_view = outputs[0].to_array_view::<f32>()?;

        let mut result = Vec::with_capacity(n_epochs);
        for ep in 0..n_epochs {
            let mut row = [0.0f64; 5];
            for c in 0..5 {
                row[c] = logits_view[[ep, c]] as f64;
            }
            result.push(row);
        }
        Ok(result)
    }
}

/// Computes the consensus logits and winning permutation index per epoch
/// based on minimum entropy (loudest vote).
pub fn loudest_vote_consensus(all_logits: &[Vec<[f64; 5]>]) -> (Vec<[f64; 5]>, Vec<usize>) {
    assert!(!all_logits.is_empty(), "Must provide at least one montage logits set");
    let n_montages = all_logits.len();
    let n_epochs = all_logits[0].len();

    let mut min_entropy_logits = Vec::with_capacity(n_epochs);
    let mut chosen_montages = Vec::with_capacity(n_epochs);

    for ep in 0..n_epochs {
        let mut min_loss = f64::INFINITY;
        let mut best_m = 0;
        let mut best_logits = [0.0f64; 5];

        for m in 0..n_montages {
            let logits = all_logits[m][ep];

            // Target is argmax of logits
            let mut max_l = logits[0];
            let mut target = 0;
            for c in 1..5 {
                if logits[c] > max_l {
                    max_l = logits[c];
                    target = c;
                }
            }

            // LogSumExp
            let mut sum_exp = 0.0;
            for c in 0..5 {
                sum_exp += (logits[c] - max_l).exp();
            }
            let log_sum_exp = max_l + sum_exp.ln();

            // NLL loss = - (logits[target] - log_sum_exp)
            let loss = log_sum_exp - logits[target];

            if loss < min_loss {
                min_loss = loss;
                best_m = m;
                best_logits = logits;
            }
        }

        min_entropy_logits.push(best_logits);
        chosen_montages.push(best_m);
    }

    (min_entropy_logits, chosen_montages)
}

/// Applies softmax to raw logits to produce normalized probabilities.
pub fn softmax_5(logits: &[f64; 5]) -> [f64; 5] {
    let mut max_val = logits[0];
    for &val in &logits[1..] {
        if val > max_val {
            max_val = val;
        }
    }
    let mut sum = 0.0;
    let mut probs = [0.0; 5];
    for i in 0..5 {
        probs[i] = (logits[i] - max_val).exp();
        sum += probs[i];
    }
    for i in 0..5 {
        probs[i] /= sum;
    }
    probs
}

/// Preprocesses raw signal for GSSC:
/// 1. Lowpass filter at 30.0 Hz if needed.
/// 2. Crops back overshoot to keep complete 30-second epochs.
/// 3. Resamples each 30s epoch to 2561 samples at (2560 / 30) Hz.
/// 4. Z-score normalizes the channel globally across all samples.
/// 5. Truncates each epoch to exactly 2560 samples.
pub fn prepare_gssc_channel(signal: &[f64], sfreq: f64) -> Result<Vec<f32>> {
    use crate::signal::{mne_fft_resample, mne_overlap_add};

    // Apply 0.3-35 Hz bandpass filter (matches Python scorer.py: raw.filter(0.3, 35.0))
    let sig_bp = if (sfreq - 125.0).abs() < 0.5 {
        let taps: Vec<f64> = serde_json::from_str(include_str!("../../assets/models/usleep/mne_filter_taps_125hz.json"))
            .unwrap_or_default();
        if !taps.is_empty() {
            mne_overlap_add(signal, &taps)
        } else {
            crate::signal::filter_bandpass_fir(signal, sfreq, 0.3, 35.0)
        }
    } else {
        crate::signal::filter_bandpass_fir(signal, sfreq, 0.3, 35.0)
    };

    // Resample to 100 Hz first if needed
    let sig_100 = if (sfreq - 100.0).abs() > 0.01 {
        mne_fft_resample(&sig_bp, sfreq, 100.0)
    } else {
        sig_bp
    };

    // Apply 30 Hz lowpass filter (matches Python: raw.filter(None, 30.0) at 100Hz)
    // Taps were exported from MNE with: filter_data(sfreq=100, l_freq=None, h_freq=30.0)
    static LOWPASS_30HZ_TAPS: std::sync::OnceLock<Vec<f64>> = std::sync::OnceLock::new();
    let lowpass_taps = LOWPASS_30HZ_TAPS.get_or_init(|| {
        let json = include_str!("../../assets/models/gssc/mne_lowpass_30hz_taps_100hz.json");
        serde_json::from_str::<Vec<f64>>(json).expect("Failed to parse 30Hz lowpass taps")
    });
    let sig_100 = mne_overlap_add(&sig_100, lowpass_taps);

    let fs = 100.0;
    let dur = sig_100.len() as f64 / fs;
    let n_epochs = (dur / 30.0).floor() as usize;
    if n_epochs == 0 {
        bail!("Recording is shorter than one 30-second epoch");
    }

    // Resample each 3001-point epoch (tmin=0, tmax=30) to 2561 samples
    let target_sfreq = 2560.0 / 30.0;
    let mut all_resampled = Vec::with_capacity(n_epochs * 2561);

    for ep in 0..n_epochs {
        let start = ep * 3000;
        let end = (start + 3001).min(sig_100.len());
        let mut ep_slice = sig_100[start..end].to_vec();
        if ep_slice.len() < 3001 {
            let last = *ep_slice.last().unwrap_or(&0.0);
            ep_slice.resize(3001, last);
        }

        let resampled_ep = mne_fft_resample(&ep_slice, 100.0, target_sfreq);
        all_resampled.extend(resampled_ep.into_iter().take(2561));
    }

    // Global Z-score across all epochs
    let mean = all_resampled.iter().sum::<f64>() / all_resampled.len() as f64;
    let var = all_resampled
        .iter()
        .map(|&x| (x - mean) * (x - mean))
        .sum::<f64>()
        / all_resampled.len() as f64;
    let std = var.sqrt().max(1e-8);

    // Truncate each epoch to exactly 2560 samples
    let mut output = Vec::with_capacity(n_epochs * 2560);
    for ep in 0..n_epochs {
        let ep_offset = ep * 2561;
        for i in 0..2560 {
            let val = ((all_resampled[ep_offset + i] - mean) / std) as f32;
            output.push(val);
        }
    }

    Ok(output)
}

/// End-to-end scoring of an EDF recording using GSSC with channel permutations.
pub fn score_gssc_recording(
    eeg: &[f64],
    eog: Option<&[f64]>,
    sfreq: f64,
    model: &GsscModel,
) -> Result<Vec<[f64; 5]>> {
    let eeg_prep = prepare_gssc_channel(eeg, sfreq)?;
    let n_epochs = eeg_prep.len() / 2560;

    let gru_plan = model.build_gru_plan(n_epochs)?;
    let mut all_logits = Vec::new();

    if let Some(eog_sig) = eog {
        let eog_prep = prepare_gssc_channel(eog_sig, sfreq)?;

        // Montage 1: EOG only
        let eog_plan = model.build_eog_plan(1)?;
        let reps_eog = model.encode_eog(&eog_plan, &eog_prep, n_epochs)?;
        let logits_eog = model.run_gru(&gru_plan, &reps_eog, n_epochs)?;
        all_logits.push(logits_eog);

        // Montage 2: EEG only
        let eeg_plan = model.build_eeg_plan(1)?;
        let reps_eeg = model.encode_eeg(&eeg_plan, &eeg_prep, n_epochs)?;
        let logits_eeg = model.run_gru(&gru_plan, &reps_eeg, n_epochs)?;
        all_logits.push(logits_eeg);

        // Montage 3: Both EEG & EOG
        let both_plan = model.build_both_plan(1)?;
        let reps_both = model.encode_both(&both_plan, &eeg_prep, &eog_prep, n_epochs)?;
        let logits_both = model.run_gru(&gru_plan, &reps_both, n_epochs)?;
        all_logits.push(logits_both);
    } else {
        // Montage 1: EEG only
        let eeg_plan = model.build_eeg_plan(1)?;
        let reps_eeg = model.encode_eeg(&eeg_plan, &eeg_prep, n_epochs)?;
        let logits_eeg = model.run_gru(&gru_plan, &reps_eeg, n_epochs)?;
        all_logits.push(logits_eeg);
    }

    let (consensus_logits, _) = loudest_vote_consensus(&all_logits);
    let probs = consensus_logits.iter().map(softmax_5).collect();
    Ok(probs)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_gssc_numerical_parity() -> Result<()> {
        let model = GsscModel::resolve_models()?;
        let model_dir = model.eeg_path.parent().unwrap();
        let eeg_bin = model_dir.join("test_eeg.bin");
        let eog_bin = model_dir.join("test_eog.bin");
        let json_path = model_dir.join("gssc_test_vector.json");

        if !eeg_bin.exists() || !eog_bin.exists() || !json_path.exists() {
            println!("Test vector files not found, skipping GSSC parity test.");
            return Ok(());
        }

        let eeg_bytes = std::fs::read(&eeg_bin)?;
        let eog_bytes = std::fs::read(&eog_bin)?;
        let json_str = std::fs::read_to_string(&json_path)?;
        let vectors: serde_json::Value = serde_json::from_str(&json_str)?;

        let n_epochs = 4;
        let mut eeg = vec![0.0f32; n_epochs * 2560];
        let mut eog = vec![0.0f32; n_epochs * 2560];

        for i in 0..eeg.len() {
            let b = [eeg_bytes[i * 4], eeg_bytes[i * 4 + 1], eeg_bytes[i * 4 + 2], eeg_bytes[i * 4 + 3]];
            eeg[i] = f32::from_le_bytes(b);
            let b2 = [eog_bytes[i * 4], eog_bytes[i * 4 + 1], eog_bytes[i * 4 + 2], eog_bytes[i * 4 + 3]];
            eog[i] = f32::from_le_bytes(b2);
        }

        // 1. EEG only
        let eeg_plan = model.build_eeg_plan(1)?;
        let rep_eeg = model.encode_eeg(&eeg_plan, &eeg, n_epochs)?;
        println!("rep_eeg len: {}, first 5: {:?}", rep_eeg.len(), &rep_eeg[..5]);
        let exp_eeg = vectors["rep_eeg_sample"].as_array().unwrap();
        println!("exp_eeg first 5: {:?}", &exp_eeg[..5]);
        for (i, val) in exp_eeg.iter().enumerate() {
            let exp = val.as_f64().unwrap() as f32;
            let act = rep_eeg[i];
            let diff = (act - exp).abs();
            assert!(diff < 0.5, "EEG rep diff at {}: actual {}, expected {}", i, act, exp);
        }
        println!("GSSC EEG-only encoder passed parity test.");

        // 2. EOG only
        let eog_plan = model.build_eog_plan(1)?;
        let rep_eog = model.encode_eog(&eog_plan, &eog, n_epochs)?;
        let exp_eog = vectors["rep_eog_sample"].as_array().unwrap();
        for (i, val) in exp_eog.iter().enumerate() {
            let exp = val.as_f64().unwrap() as f32;
            let act = rep_eog[i];
            let diff = (act - exp).abs();
            assert!(diff < 0.5, "EOG rep diff at {}: actual {}, expected {}", i, act, exp);
        }
        println!("GSSC EOG-only encoder passed parity test.");

        // 3. Both
        let both_plan = model.build_both_plan(1)?;
        let rep_both = model.encode_both(&both_plan, &eeg, &eog, n_epochs)?;
        let exp_both = vectors["rep_both_sample"].as_array().unwrap();
        for (i, val) in exp_both.iter().enumerate() {
            let exp = val.as_f64().unwrap() as f32;
            let act = rep_both[i];
            let diff = (act - exp).abs();
            assert!(diff < 1.0, "Both rep diff at {}: actual {}, expected {}", i, act, exp);
        }
        println!("GSSC Both encoder passed parity test.");

        // 4. GRU
        let gru_plan = model.build_gru_plan(n_epochs)?;
        let logits = model.run_gru(&gru_plan, &rep_both, n_epochs)?;
        let exp_logits = vectors["logits_both"].as_array().unwrap();
        println!("Act logits [0]: {:?}", logits[0]);
        println!("Exp logits [0]: {:?}", exp_logits[0]);
        let act_stages: Vec<usize> = logits.iter().map(|row| {
            row.iter().enumerate().max_by(|a, b| a.1.partial_cmp(b.1).unwrap()).unwrap().0
        }).collect();
        let exp_stages: Vec<usize> = (0..n_epochs).map(|ep| {
            let row = exp_logits[ep].as_array().unwrap();
            row.iter().enumerate().max_by(|a, b| a.1.as_f64().unwrap().partial_cmp(&b.1.as_f64().unwrap()).unwrap()).unwrap().0
        }).collect();
        println!("Act stages: {:?}", act_stages);
        println!("Exp stages: {:?}", exp_stages);
        assert_eq!(act_stages, exp_stages, "Predicted stages must match exactly");
        println!("GSSC GRU passed parity test.");

        Ok(())
    }

    #[test]
    fn test_gssc_from_ref_data() -> Result<()> {
        let npy_path = PathBuf::from("/tmp/gssc_ref_data.npy");
        let gt_path = PathBuf::from("/tmp/py_gssc_test/AS_CNT_08_Night1_gssc_scoring.json");
        if !npy_path.exists() || !gt_path.exists() {
            println!("Ref data or ground truth not found, skipping.");
            return Ok(());
        }

        let raw_bytes = std::fs::read(&npy_path)?;
        // Shape (784, 2, 2560) float64 = 784 * 2 * 2560 * 8 = 32,112,640 bytes + 128 byte npy header
        let n_epochs = 784;
        let mut eeg_prep = vec![0.0f32; n_epochs * 2560];
        let mut eog_prep = vec![0.0f32; n_epochs * 2560];

        // Find data offset in npy file (header usually 128 bytes)
        let header_len = if raw_bytes[0..6] == [0x93, b'N', b'U', b'M', b'P', b'Y'] {
            let h_len = u16::from_le_bytes([raw_bytes[8], raw_bytes[9]]) as usize;
            10 + h_len
        } else {
            128
        };

        let data_bytes = &raw_bytes[header_len..];
        for ep in 0..n_epochs {
            for i in 0..2560 {
                let eeg_idx = (ep * 2 * 2560 + 0 * 2560 + i) * 8;
                let eog_idx = (ep * 2 * 2560 + 1 * 2560 + i) * 8;
                let mut b_eeg = [0u8; 8];
                let mut b_eog = [0u8; 8];
                b_eeg.copy_from_slice(&data_bytes[eeg_idx..eeg_idx + 8]);
                b_eog.copy_from_slice(&data_bytes[eog_idx..eog_idx + 8]);
                eeg_prep[ep * 2560 + i] = f64::from_le_bytes(b_eeg) as f32;
                eog_prep[ep * 2560 + i] = f64::from_le_bytes(b_eog) as f32;
            }
        }
        println!("Rust read C4 epoch 0: {:?}", &eeg_prep[..3]);
        println!("Rust read EOG epoch 0: {:?}", &eog_prep[..3]);

        let model = GsscModel::resolve_models()?;
        let gru_plan = model.build_gru_plan(n_epochs)?;
        let mut all_logits = Vec::new();

        // 1. EOG only
        let eog_plan = model.build_eog_plan(1)?;
        let reps_eog = model.encode_eog(&eog_plan, &eog_prep, n_epochs)?;
        println!("Rust r_eog[0, :5]:  {:?}", &reps_eog[..5]);
        let logits_eog = model.run_gru(&gru_plan, &reps_eog, n_epochs)?;
        all_logits.push(logits_eog);

        // 2. EEG only
        let eeg_plan = model.build_eeg_plan(1)?;
        let reps_eeg = model.encode_eeg(&eeg_plan, &eeg_prep, n_epochs)?;
        println!("Rust r_eeg[0, :5]:  {:?}", &reps_eeg[..5]);
        let logits_eeg = model.run_gru(&gru_plan, &reps_eeg, n_epochs)?;
        all_logits.push(logits_eeg);

        // 3. Both
        let both_plan = model.build_both_plan(1)?;
        let reps_both = model.encode_both(&both_plan, &eeg_prep, &eog_prep, n_epochs)?;
        println!("Rust r_both[0, :5]: {:?}", &reps_both[..5]);
        let logits_both = model.run_gru(&gru_plan, &reps_both, n_epochs)?;
        println!("Rust l_both[0]:      {:?}", &logits_both[0]);
        all_logits.push(logits_both);

        let (consensus_logits, _) = loudest_vote_consensus(&all_logits);
        let probs: Vec<[f64; 5]> = consensus_logits.iter().map(softmax_5).collect();

        let gt_str = std::fs::read_to_string(&gt_path)?;
        let gt_outer: Vec<Vec<serde_json::Value>> = serde_json::from_str(&gt_str)?;
        let gt_records = &gt_outer[0];

        let mut matches = 0;
        let stage_names = ["Wake", "N1", "N2", "N3", "REM"];
        for (ep, (p_row, gt_rec)) in probs.iter().zip(gt_records.iter()).enumerate() {
            let mut best_c = 0;
            let mut best_p = p_row[0];
            for c in 1..5 {
                if p_row[c] > best_p {
                    best_p = p_row[c];
                    best_c = c;
                }
            }
            let act_stage = stage_names[best_c];
            let exp_stage = gt_rec["stage"].as_str().unwrap();
            if act_stage == exp_stage {
                matches += 1;
            }
        }

        let match_pct = matches as f64 / n_epochs as f64 * 100.0;
        println!(
            "GSSC from preprocessed ref data: {}/{} ({:.2}%)",
            matches, n_epochs, match_pct
        );
        assert!(match_pct >= 95.0, "Concordance from ref data should be >= 95%");

        Ok(())
    }

    #[test]
    fn test_gssc_night_parity() -> Result<()> {
        let edf_path = PathBuf::from("../SamplePSGData/Data/AS_CNT_08_Night1.edf")
            .canonicalize()
            .or_else(|_| PathBuf::from("SamplePSGData/Data/AS_CNT_08_Night1.edf").canonicalize())
            .context("Could not find AS_CNT_08_Night1.edf")?;

        let gt_path = PathBuf::from("/tmp/py_gssc_test/AS_CNT_08_Night1_gssc_scoring.json");
        if !gt_path.exists() {
            println!("Ground truth file {:?} not found, skipping.", gt_path);
            return Ok(());
        }

        let gt_str = std::fs::read_to_string(&gt_path)?;
        let gt_outer: Vec<Vec<serde_json::Value>> = serde_json::from_str(&gt_str)?;
        let gt_records = &gt_outer[0];
        let n_epochs = gt_records.len();
        println!("Loaded {} ground-truth epochs for GSSC.", n_epochs);

        let edf = crate::edf::read_selected(
            &edf_path,
            &["C4".to_string(), "LOC1".to_string(), "ROC1".to_string()],
        )?;

        let eeg_signal = &edf.data_uv[0];
        let loc1_signal = &edf.data_uv[1];
        let roc1_signal = &edf.data_uv[2];

        // Construct bipolar EOG: LOC1 - ROC1
        let mut eog_bipolar = Vec::with_capacity(loc1_signal.len());
        for i in 0..loc1_signal.len() {
            eog_bipolar.push(loc1_signal[i] - roc1_signal[i]);
        }

        let model = GsscModel::resolve_models()?;
        println!("Scoring full recording with GSSC in native Rust...");
        let probs = score_gssc_recording(eeg_signal, Some(&eog_bipolar), edf.sfreq, &model)?;

        assert_eq!(probs.len(), n_epochs, "Epoch counts must match");

        let mut stage_matches = 0;
        let stage_names = ["Wake", "N1", "N2", "N3", "REM"];

        for (ep, (p_row, gt_rec)) in probs.iter().zip(gt_records.iter()).enumerate() {
            let mut best_c = 0;
            let mut best_p = p_row[0];
            for c in 1..5 {
                if p_row[c] > best_p {
                    best_p = p_row[c];
                    best_c = c;
                }
            }
            let act_stage = stage_names[best_c];
            let exp_stage = gt_rec["stage"].as_str().unwrap();

            if act_stage == exp_stage {
                stage_matches += 1;
            } else if ep < 10 {
                println!(
                    "Epoch {}: diff - Act: {} ({:.4}), Exp: {}",
                    ep + 1,
                    act_stage,
                    best_p,
                    exp_stage
                );
            }
        }

        let match_pct = stage_matches as f64 / n_epochs as f64 * 100.0;
        println!(
            "GSSC Full Night Stage Parity: {}/{} ({:.2}%)",
            stage_matches, n_epochs, match_pct
        );

        assert!(
            match_pct >= 95.0,
            "GSSC stage concordance {:.2}% is below 95.0% threshold",
            match_pct
        );

        Ok(())
    }

    /// Diagnostic test: runs partial GSSC EEG models in Tract to find
    /// where the divergence from ONNX Runtime begins.
    #[test]
    fn test_gssc_tract_bisect() -> Result<()> {
        let models = [
            ("/tmp/gssc_eeg_node0.onnx", "node0_Conv", vec![0.025409697f32, 0.022811931, 0.020601166, 0.018375162, 0.016150754]),
            ("/tmp/gssc_eeg_node100.onnx", "node100_Reshape", vec![0.12315580f32, 0.16485825, 0.15957838, 0.15905167, 0.15626593]),
            ("/tmp/gssc_eeg_node300.onnx", "node300_LeakyRelu", vec![-0.006784964f32, -0.025733298, -0.024546331, -0.020918442, -0.02139978]),
            ("/tmp/gssc_eeg_node700.onnx", "node700_Add", vec![-1.751747727f32, -5.832193851, -9.848796844, -5.745701790, -3.907734632]),
            ("/tmp/gssc_eeg_node1000.onnx", "node1000_LeakyRelu", vec![-0.014197903f32, -0.068826713, 0.111971073, -0.066897571, -0.053936411]),
            ("/tmp/gssc_eeg_node1080.onnx", "node1080_Reshape", vec![-0.388722420f32, -0.735492468, -1.094032049, -1.263935924, -1.111246586]),
            ("/tmp/gssc_eeg_node1101.onnx", "node1101_InstanceNorm", vec![-0.405550659f32, -0.756585360, -1.125297546, -1.306589723, -1.146570921]),
            ("/tmp/gssc_eeg_node1150.onnx", "node1150_Mul", vec![-0.152905300f32, -0.267254859, -0.390455365, -0.455622911, -0.406589866]),
            ("assets/models/gssc/gssc_eeg.onnx", "full_gssc_eeg", vec![4.359996f32, -0.97611046, 3.5161934, -0.8166142, -2.34123]),
            ("assets/models/gssc/gssc_eeg_dynshape.onnx", "full_gssc_eeg_dynshape", vec![4.359996f32, -0.97611046, 3.5161934, -0.8166142, -2.34123]),
        ];

        // Load the single-epoch input
        let input_path = std::path::Path::new("/tmp/gssc_debug_input.bin");
        if !input_path.exists() {
            println!("Debug input not found at /tmp/gssc_debug_input.bin, skipping bisect test.");
            return Ok(());
        }
        let input_bytes = std::fs::read(input_path)?;
        let n_floats = input_bytes.len() / 4;
        let input_f32: Vec<f32> = (0..n_floats)
            .map(|i| f32::from_le_bytes(input_bytes[i*4..i*4+4].try_into().unwrap()))
            .collect();

        for (path, name, expected_first5) in &models {
            let model_path = std::path::Path::new(path);
            if !model_path.exists() {
                println!("Skipping {} - file not found", name);
                continue;
            }

            let plan = tract_onnx::onnx()
                .model_for_path(model_path)?
                .with_input_fact(0, InferenceFact::dt_shape(f32::datum_type(), tvec![1usize, 1usize, 2560usize]))?
                .into_optimized()?
                .into_runnable()?;

            let input_tensor: Tensor = tract_ndarray::Array::from_shape_vec(
                (1, 1, 2560),
                input_f32.clone()
            ).unwrap().into();

            let result = plan.run(tvec![input_tensor.into()])?;
            let out = result[0].to_array_view::<f32>()?;
            let first5: Vec<f32> = out.as_slice().unwrap()[..5].to_vec();

            let max_diff = first5.iter().zip(expected_first5.iter())
                .map(|(a, e)| (a - e).abs())
                .fold(0.0f32, f32::max);

            let status = if max_diff < 0.01 { "✅ MATCHES" } else { "❌ DIVERGES" };
            println!("{} [{}]: tract_first5={:?}", status, name, first5);
            println!("  expected:         {:?}", expected_first5);
            println!("  max_diff: {:.6}", max_diff);
        }

        Ok(())
    }

    #[test]
    fn test_gssc_eeg_batches() -> Result<()> {
        let input_path = std::path::Path::new("/tmp/gssc_debug_input.bin");
        if !input_path.exists() {
            println!("Debug input not found at /tmp/gssc_debug_input.bin, skipping batch test.");
            return Ok(());
        }
        let input_bytes = std::fs::read(input_path)?;
        let n_floats = input_bytes.len() / 4;
        let single_epoch: Vec<f32> = (0..n_floats)
            .map(|i| f32::from_le_bytes(input_bytes[i*4..i*4+4].try_into().unwrap()))
            .collect();

        let model = GsscModel::resolve_models()?;

        // 1 epoch
        let plan1 = model.build_eeg_plan(1)?;
        let r1 = model.encode_eeg(&plan1, &single_epoch, 1)?;
        println!("Tract 1 epoch: len={}, first5={:?}", r1.len(), &r1[..5]);

        // 2 epochs (repeat single epoch twice)
        let two_epochs = [single_epoch.clone(), single_epoch.clone()].concat();
        let r2 = model.encode_eeg(&plan1, &two_epochs, 2)?;
        println!("Tract 2 epochs: len={}, ep0 first5={:?}, ep1 first5={:?}", r2.len(), &r2[..5], &r2[512..517]);

        // 4 epochs
        let four_epochs = [single_epoch.clone(), single_epoch.clone(), single_epoch.clone(), single_epoch.clone()].concat();
        let r4 = model.encode_eeg(&plan1, &four_epochs, 4)?;
        println!("Tract 4 epochs: len={}, ep0 first5={:?}", r4.len(), &r4[..5]);

        Ok(())
    }
}
