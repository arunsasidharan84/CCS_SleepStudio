use anyhow::{Context, Result};
use std::path::{Path, PathBuf};
use tract_onnx::prelude::*;

pub type TractPlan = SimplePlan<TypedFact, Box<dyn TypedOp>, Graph<TypedFact, Box<dyn TypedOp>>>;

pub struct StagingModel {
    pub plan: TractPlan,
}

impl StagingModel {
    /// Loads an ONNX sleep staging model from file path.
    pub fn load_from_path(model_path: &Path) -> Result<Self> {
        if !model_path.exists() {
            anyhow::bail!("ONNX model file not found at {:?}", model_path);
        }

        let plan = tract_onnx::onnx()
            .model_for_path(model_path)
            .with_context(|| format!("Loading ONNX model at {:?}", model_path))?
            .with_input_fact(0, f32::fact([1, 20, 1, 3000]).into())?
            .into_optimized()?
            .into_runnable()?;

        Ok(Self { plan })
    }

    /// Resolves standard bundled model or user provided path.
    pub fn resolve_model(model_arg: Option<&str>) -> Result<PathBuf> {
        if let Some(arg) = model_arg {
            let p = PathBuf::from(arg);
            if p.exists() {
                return Ok(p);
            }
            // Check known named presets
            match arg.to_lowercase().as_str() {
                "psg" | "psg_model" => {
                    let candidates = [
                        PathBuf::from("assets/models/tinysleepnet/psg_model.onnx"),
                        PathBuf::from("../assets/models/tinysleepnet/psg_model.onnx"),
                        PathBuf::from("analyseNidra/assets/models/tinysleepnet/psg_model.onnx"),
                    ];
                    for c in &candidates {
                        if c.exists() {
                            return Ok(c.clone());
                        }
                    }
                }
                "wearable" | "wearable_model" => {
                    let candidates = [
                        PathBuf::from("assets/models/tinysleepnet/wearable_model.onnx"),
                        PathBuf::from("../assets/models/tinysleepnet/wearable_model.onnx"),
                        PathBuf::from("analyseNidra/assets/models/tinysleepnet/wearable_model.onnx"),
                    ];
                    for c in &candidates {
                        if c.exists() {
                            return Ok(c.clone());
                        }
                    }
                }
                _ => {}
            }
        }

        // Default candidate paths
        let default_candidates = [
            PathBuf::from("assets/models/tinysleepnet/psg_model.onnx"),
            PathBuf::from("assets/models/tinysleepnet/model.onnx"),
            PathBuf::from("analyseNidra/assets/models/tinysleepnet/psg_model.onnx"),
            PathBuf::from("analyseNidra/assets/models/tinysleepnet/model.onnx"),
            PathBuf::from("../assets/models/tinysleepnet/psg_model.onnx"),
            PathBuf::from("../analyseNidra/assets/models/tinysleepnet/psg_model.onnx"),
        ];

        // Also check beside current executable
        if let Ok(exe) = std::env::current_exe() {
            if let Some(parent) = exe.parent() {
                let exe_candidates = [
                    parent.join("assets/models/tinysleepnet/psg_model.onnx"),
                    parent.join("models/tinysleepnet/psg_model.onnx"),
                    parent.join("../Resources/models/tinysleepnet/psg_model.onnx"),
                    parent.join("../Resources/assets/models/tinysleepnet/psg_model.onnx"),
                    parent.join("../Resources/flutter_assets/assets/models/tinysleepnet/psg_model.onnx"),
                    parent.join("data/flutter_assets/assets/models/tinysleepnet/psg_model.onnx"),
                    parent.join("../../analyseNidra/assets/models/tinysleepnet/psg_model.onnx"),
                ];
                for c in &exe_candidates {
                    if c.exists() {
                        return Ok(c.clone());
                    }
                }
            }
        }

        for c in &default_candidates {
            if c.exists() {
                return Ok(c.clone());
            }
        }

        anyhow::bail!(
            "TinySleepNet ONNX model not found. Pass --model <path/to/model.onnx> or ensure assets/models/tinysleepnet/ exists."
        )
    }

    /// Scores a 20-epoch sequence of shape (20 * 3000 f32).
    /// Returns: (predicted_stage, confidence, [prob_wake, prob_n1, prob_n2, prob_n3, prob_rem])
    pub fn score_sequence(&self, flat_20_epochs: &[f32]) -> Result<(usize, f64, [f64; 5])> {
        if flat_20_epochs.len() != 20 * 3000 {
            anyhow::bail!(
                "Expected exactly 20 * 3000 = 60000 samples for sequence inference, got {}",
                flat_20_epochs.len()
            );
        }

        let input_tensor = tract_ndarray::Array4::from_shape_vec(
            (1, 20, 1, 3000),
            flat_20_epochs.to_vec(),
        )?;

        let outputs = self.plan.run(tvec!(input_tensor.into_tensor().into()))?;
        let logits = outputs[0].to_array_view::<f32>()?;

        // Extract logits for last epoch in sequence (index 19)
        let mut raw_logits = [0.0_f64; 5];
        for stage in 0..5 {
            raw_logits[stage] = logits[[0, 19, stage]] as f64;
        }

        // Stable softmax
        let max_logit = raw_logits.iter().copied().fold(f64::NEG_INFINITY, f64::max);
        let mut exp_sum = 0.0;
        let mut probs = [0.0_f64; 5];
        for i in 0..5 {
            probs[i] = (raw_logits[i] - max_logit).exp();
            exp_sum += probs[i];
        }
        for i in 0..5 {
            probs[i] /= exp_sum.max(1e-12);
        }

        // Find stage with maximum probability
        let mut best_stage = 0;
        let mut best_prob = probs[0];
        for i in 1..5 {
            if probs[i] > best_prob {
                best_prob = probs[i];
                best_stage = i;
            }
        }

        Ok((best_stage, best_prob, probs))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tinysleepnet_onnx_inference() {
        let model_path = match StagingModel::resolve_model(None) {
            Ok(p) => p,
            Err(_) => return, // Skip if asset not in test runner path
        };
        let model = StagingModel::load_from_path(&model_path).expect("Model should load");
        let dummy_input = vec![0.0_f32; 20 * 3000];
        let (stage, conf, probs) = model.score_sequence(&dummy_input).expect("Inference should succeed");
        assert!(stage < 5);
        assert!(conf > 0.0 && conf <= 1.0);
        let prob_sum: f64 = probs.iter().sum();
        assert!((prob_sum - 1.0).abs() < 1e-4);
    }
}
