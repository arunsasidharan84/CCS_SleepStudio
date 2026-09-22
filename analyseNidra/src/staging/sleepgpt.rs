use anyhow::{Context, Result};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

const EMBED_DIM: usize = 48;
const NUM_HEADS: usize = 6;
const HEAD_DIM: usize = 8; // 48 / 6
const NUM_LAYERS: usize = 3;
const EPS: f32 = 1e-5;

pub struct SleepGptLayer {
    pub ln1_w: Vec<f32>,
    pub ln1_b: Vec<f32>,
    pub c_attn_w: Vec<f32>, // [48, 144]
    pub c_attn_b: Vec<f32>, // [144]
    pub c_proj_w: Vec<f32>, // [48, 48]
    pub c_proj_b: Vec<f32>, // [48]
    pub ln2_w: Vec<f32>,
    pub ln2_b: Vec<f32>,
    pub c_fc_w: Vec<f32>,   // [48, 192]
    pub c_fc_b: Vec<f32>,   // [192]
    pub c_mlp_proj_w: Vec<f32>, // [192, 48]
    pub c_mlp_proj_b: Vec<f32>, // [48]
}

pub struct SleepGptModel {
    pub wte: Vec<f32>, // [6, 48]
    pub wpe: Vec<f32>, // [90, 48]
    pub layers: Vec<SleepGptLayer>,
    pub ln_f_w: Vec<f32>, // [48]
    pub ln_f_b: Vec<f32>, // [48]
    pub lm_head_w: Vec<f32>, // [6, 48]
}

#[inline]
fn layer_norm(x: &[f32], w: &[f32], b: &[f32], t_steps: usize) -> Vec<f32> {
    let mut out = vec![0.0f32; t_steps * EMBED_DIM];
    for t in 0..t_steps {
        let offset = t * EMBED_DIM;
        let slice = &x[offset..offset + EMBED_DIM];
        let mut sum = 0.0f32;
        for &v in slice {
            sum += v;
        }
        let mean = sum / (EMBED_DIM as f32);
        let mut var_sum = 0.0f32;
        for &v in slice {
            let diff = v - mean;
            var_sum += diff * diff;
        }
        let inv_std = 1.0f32 / (var_sum / (EMBED_DIM as f32) + EPS).sqrt();
        for i in 0..EMBED_DIM {
            out[offset + i] = (slice[i] - mean) * inv_std * w[i] + b[i];
        }
    }
    out
}

#[inline]
fn matmul_bias(
    x: &[f32],
    w: &[f32],
    b: &[f32],
    t_steps: usize,
    d_in: usize,
    d_out: usize,
) -> Vec<f32> {
    let mut out = vec![0.0f32; t_steps * d_out];
    for t in 0..t_steps {
        let x_off = t * d_in;
        let out_off = t * d_out;
        for j in 0..d_out {
            let mut sum = b[j];
            for i in 0..d_in {
                sum += x[x_off + i] * w[i * d_out + j];
            }
            out[out_off + j] = sum;
        }
    }
    out
}

#[inline]
fn gelu(x: f32) -> f32 {
    let sqrt_2_over_pi = 0.7978845608028654f32; // sqrt(2 / pi)
    0.5f32 * x * (1.0f32 + (sqrt_2_over_pi * (x + 0.044715f32 * x * x * x)).tanh())
}

impl SleepGptModel {
    pub fn load_from_json(path: &Path) -> Result<Self> {
        let file = std::fs::File::open(path)
            .with_context(|| format!("Opening SleepGPT weights JSON at {:?}", path))?;
        let reader = std::io::BufReader::new(file);
        let weights: HashMap<String, Vec<f32>> = serde_json::from_reader(reader)?;

        let wte = weights.get("transformer.wte.weight").context("missing wte")?.clone();
        let wpe = weights.get("transformer.wpe.weight").context("missing wpe")?.clone();

        let mut layers = Vec::with_capacity(NUM_LAYERS);
        for l in 0..NUM_LAYERS {
            let p = format!("transformer.h.{l}.");
            layers.push(SleepGptLayer {
                ln1_w: weights.get(&format!("{p}ln_1.weight")).context("ln1_w")?.clone(),
                ln1_b: weights.get(&format!("{p}ln_1.bias")).context("ln1_b")?.clone(),
                c_attn_w: weights.get(&format!("{p}attn.c_attn.weight")).context("c_attn_w")?.clone(),
                c_attn_b: weights.get(&format!("{p}attn.c_attn.bias")).context("c_attn_b")?.clone(),
                c_proj_w: weights.get(&format!("{p}attn.c_proj.weight")).context("c_proj_w")?.clone(),
                c_proj_b: weights.get(&format!("{p}attn.c_proj.bias")).context("c_proj_b")?.clone(),
                ln2_w: weights.get(&format!("{p}ln_2.weight")).context("ln2_w")?.clone(),
                ln2_b: weights.get(&format!("{p}ln_2.bias")).context("ln2_b")?.clone(),
                c_fc_w: weights.get(&format!("{p}mlp.c_fc.weight")).context("c_fc_w")?.clone(),
                c_fc_b: weights.get(&format!("{p}mlp.c_fc.bias")).context("c_fc_b")?.clone(),
                c_mlp_proj_w: weights.get(&format!("{p}mlp.c_proj.weight")).context("c_mlp_proj_w")?.clone(),
                c_mlp_proj_b: weights.get(&format!("{p}mlp.c_proj.bias")).context("c_mlp_proj_b")?.clone(),
            });
        }

        let ln_f_w = weights.get("transformer.ln_f.weight").context("ln_f_w")?.clone();
        let ln_f_b = weights.get("transformer.ln_f.bias").context("ln_f_b")?.clone();
        let lm_head_w = weights.get("lm_head.weight").context("lm_head_w")?.clone();

        Ok(Self {
            wte,
            wpe,
            layers,
            ln_f_w,
            ln_f_b,
            lm_head_w,
        })
    }

    pub fn resolve_weights() -> Result<PathBuf> {
        Self::resolve_model(None)
    }

    pub fn resolve_model(model_arg: Option<&str>) -> Result<PathBuf> {
        if let Some(arg) = model_arg {
            let p = PathBuf::from(arg);
            if p.exists() {
                return Ok(p);
            }
        }

        let candidates = [
            PathBuf::from("assets/models/sleepgpt/sleepgpt_weights.json"),
            PathBuf::from("analyseNidra/assets/models/sleepgpt/sleepgpt_weights.json"),
            PathBuf::from("../assets/models/sleepgpt/sleepgpt_weights.json"),
            PathBuf::from("../analyseNidra/assets/models/sleepgpt/sleepgpt_weights.json"),
        ];

        for c in &candidates {
            if c.exists() {
                return Ok(c.clone());
            }
        }

        if let Ok(exe) = std::env::current_exe() {
            if let Some(parent) = exe.parent() {
                let exe_candidates = [
                    parent.join("assets/models/sleepgpt/sleepgpt_weights.json"),
                    parent.join("models/sleepgpt/sleepgpt_weights.json"),
                    parent.join("../Resources/models/sleepgpt/sleepgpt_weights.json"),
                    parent.join("../Resources/assets/models/sleepgpt/sleepgpt_weights.json"),
                ];
                for c in &exe_candidates {
                    if c.exists() {
                        return Ok(c.clone());
                    }
                }
            }
        }

        anyhow::bail!(
            "SleepGPT weights not found. Ensure assets/models/sleepgpt/sleepgpt_weights.json exists."
        )
    }

    /// Forward pass for input sequence tokens. Returns logits [6] for the final step.
    pub fn predict_last_logits(&self, tokens: &[i64]) -> Result<[f64; 6]> {
        let t_steps = tokens.len();
        if t_steps == 0 {
            anyhow::bail!("Input tokens cannot be empty");
        }
        if t_steps > 90 {
            anyhow::bail!("Input sequence length {} exceeds max 90", t_steps);
        }

        // 1. Embedding: h = wte[token] + wpe[t]
        let mut h = vec![0.0f32; t_steps * EMBED_DIM];
        for t in 0..t_steps {
            let tok = tokens[t] as usize;
            if tok >= 6 {
                anyhow::bail!("Token ID {} exceeds vocab size 6", tok);
            }
            let wte_off = tok * EMBED_DIM;
            let wpe_off = t * EMBED_DIM;
            let h_off = t * EMBED_DIM;
            for i in 0..EMBED_DIM {
                h[h_off + i] = self.wte[wte_off + i] + self.wpe[wpe_off + i];
            }
        }

        let scale = 1.0f32 / (HEAD_DIM as f32).sqrt();

        // 2. Transformer layers
        for layer in &self.layers {
            // LayerNorm 1
            let a = layer_norm(&h, &layer.ln1_w, &layer.ln1_b, t_steps);

            // QKV projection [t_steps, 144]
            let qkv = matmul_bias(&a, &layer.c_attn_w, &layer.c_attn_b, t_steps, EMBED_DIM, 144);

            // Multi-head Causal Self-Attention
            let mut attn_out = vec![0.0f32; t_steps * EMBED_DIM];

            for head in 0..NUM_HEADS {
                let head_off = head * HEAD_DIM;
                for i in 0..t_steps {
                    // Extract query for (head, step i)
                    let q_base = i * 144 + head_off;
                    let q = &qkv[q_base..q_base + HEAD_DIM];

                    // Compute dot-product attention scores for j in 0..=i (causal mask)
                    let mut scores = vec![0.0f32; i + 1];
                    let mut max_score = f32::NEG_INFINITY;
                    for j in 0..=i {
                        let k_base = j * 144 + 48 + head_off; // k starts at offset 48
                        let k = &qkv[k_base..k_base + HEAD_DIM];
                        let mut dot = 0.0f32;
                        for d in 0..HEAD_DIM {
                            dot += q[d] * k[d];
                        }
                        let s = dot * scale;
                        scores[j] = s;
                        if s > max_score {
                            max_score = s;
                        }
                    }

                    // Softmax over scores
                    let mut exp_sum = 0.0f32;
                    for j in 0..=i {
                        scores[j] = (scores[j] - max_score).exp();
                        exp_sum += scores[j];
                    }
                    let inv_exp_sum = 1.0f32 / exp_sum.max(1e-12);
                    for j in 0..=i {
                        scores[j] *= inv_exp_sum;
                    }

                    // Weighted sum of values (v starts at offset 96)
                    let out_base = i * EMBED_DIM + head_off;
                    for d in 0..HEAD_DIM {
                        let mut sum = 0.0f32;
                        for j in 0..=i {
                            let v_val = qkv[j * 144 + 96 + head_off + d];
                            sum += scores[j] * v_val;
                        }
                        attn_out[out_base + d] = sum;
                    }
                }
            }

            // Attention output projection
            let attn_proj = matmul_bias(
                &attn_out,
                &layer.c_proj_w,
                &layer.c_proj_b,
                t_steps,
                EMBED_DIM,
                EMBED_DIM,
            );

            // Residual connection
            for i in 0..h.len() {
                h[i] += attn_proj[i];
            }

            // LayerNorm 2
            let m = layer_norm(&h, &layer.ln2_w, &layer.ln2_b, t_steps);

            // MLP: Linear -> GeLU -> Linear
            let mut fc = matmul_bias(&m, &layer.c_fc_w, &layer.c_fc_b, t_steps, EMBED_DIM, 192);
            for val in &mut fc {
                *val = gelu(*val);
            }
            let mlp_proj = matmul_bias(
                &fc,
                &layer.c_mlp_proj_w,
                &layer.c_mlp_proj_b,
                t_steps,
                192,
                EMBED_DIM,
            );

            // Residual connection
            for i in 0..h.len() {
                h[i] += mlp_proj[i];
            }
        }

        // 3. Final LayerNorm
        let h_final = layer_norm(&h, &self.ln_f_w, &self.ln_f_b, t_steps);

        // 4. Output projection for last token (t = t_steps - 1)
        let last_h = &h_final[(t_steps - 1) * EMBED_DIM..t_steps * EMBED_DIM];
        let mut logits = [0.0f64; 6];
        for c in 0..6 {
            let mut sum = 0.0f64;
            let head_off = c * EMBED_DIM;
            for d in 0..EMBED_DIM {
                sum += (last_h[d] as f64) * (self.lm_head_w[head_off + d] as f64);
            }
            logits[c] = sum;
        }

        Ok(logits)
    }

    /// Compute log_softmax over the 6 output logits.
    pub fn next_log_probs(&self, tokens: &[i64]) -> Result<[f64; 6]> {
        let logits = self.predict_last_logits(tokens)?;
        let max_val = logits.iter().copied().fold(f64::NEG_INFINITY, f64::max);
        let mut exp_sum = 0.0;
        let mut exps = [0.0f64; 6];
        for i in 0..6 {
            exps[i] = (logits[i] - max_val).exp();
            exp_sum += exps[i];
        }
        let log_sum = exp_sum.ln();
        let mut log_probs = [0.0f64; 6];
        for i in 0..6 {
            log_probs[i] = logits[i] - max_val - log_sum;
        }
        Ok(log_probs)
    }
}

/// Apply SleepGPT sequence correction given base raw probabilities (N x 5) for ["W", "N1", "N2", "N3", "R"].
pub fn run_sleepgpt_correction(
    model: &SleepGptModel,
    raw_probs: &[[f64; 5]],
    alpha: f64,
    ngram: usize,
) -> Result<Vec<usize>> {
    let total_epochs = raw_probs.len();
    let min_len = 5;
    if total_epochs < min_len {
        anyhow::bail!("SleepGPT requires at least {} epochs, got {}", min_len, total_epochs);
    }

    let mut corrected_tokens = Vec::with_capacity(total_epochs);

    // First min_len tokens: pure argmax over raw probabilities
    for i in 0..min_len {
        let best_idx = raw_probs[i]
            .iter()
            .enumerate()
            .max_by(|(_, a), (_, b)| a.partial_cmp(b).unwrap())
            .map(|(idx, _)| idx)
            .unwrap_or(0);
        corrected_tokens.push(best_idx);
    }

    // Step-by-step autoregressive correction
    for index in min_len..total_epochs {
        let start = if corrected_tokens.len() > ngram {
            corrected_tokens.len() - ngram
        } else {
            0
        };
        let window: Vec<i64> = corrected_tokens[start..]
            .iter()
            .map(|&t| t as i64)
            .collect();

        let lm_log_probs = model.next_log_probs(&window)?;

        // Compute log_softmax on the raw 5-class probabilities of this epoch
        let raw_vals = &raw_probs[index];
        let max_raw = raw_vals.iter().copied().fold(f64::NEG_INFINITY, f64::max);
        let mut exp_raw_sum = 0.0;
        let mut exps_raw = [0.0f64; 5];
        for i in 0..5 {
            exps_raw[i] = (raw_vals[i] - max_raw).exp();
            exp_raw_sum += exps_raw[i];
        }
        let log_sum_raw = exp_raw_sum.ln();
        let mut raw_log_probs = [0.0f64; 5];
        for i in 0..5 {
            raw_log_probs[i] = raw_vals[i] - max_raw - log_sum_raw;
        }

        // Blend: (1 - alpha) * raw + alpha * lm_probs
        let mut best_stage = 0;
        let mut best_score = f64::NEG_INFINITY;
        for i in 0..5 {
            let blended = (1.0 - alpha) * raw_log_probs[i] + alpha * lm_log_probs[i];
            if blended > best_score {
                best_score = blended;
                best_stage = i;
            }
        }

        corrected_tokens.push(best_stage);
    }

    Ok(corrected_tokens)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sleepgpt_native_test_vector() -> Result<()> {
        let model_path = Path::new("assets/models/sleepgpt/sleepgpt_weights.json");
        if !model_path.exists() {
            println!("Skipping test: weights not found at {:?}", model_path);
            return Ok(());
        }

        let model = SleepGptModel::load_from_json(model_path)?;
        let test_tokens = [0i64, 1, 2, 3, 4, 2, 2, 3, 3, 0, 1];
        let logits = model.predict_last_logits(&test_tokens)?;
        let log_probs = model.next_log_probs(&test_tokens)?;

        println!("Native Rust SleepGPT logits: {:?}", logits);
        println!("Native Rust SleepGPT log_probs: {:?}", log_probs);

        // Ground truth from PyTorch test_vector.json:
        // logits: [-1.9441547, -2.717037, -0.04533857, -1.4499363, -4.163909, -20.140556]
        let expected_logits = [-1.9441547, -2.717037, -0.04533857, -1.4499363, -4.163909, -20.140556];
        for i in 0..6 {
            let diff = (logits[i] - expected_logits[i]).abs();
            println!("Logit diff [{}]: {}", i, diff);
            assert!(
                diff < 1e-4,
                "Logit mismatch at index {}: got {}, expected {}",
                i, logits[i], expected_logits[i]
            );
        }

        println!("Native Rust SleepGPT numerical parity PASSED with < 1e-4 error!");
        Ok(())
    }

    #[test]
    fn test_sleepgpt_night_parity() -> Result<()> {
        let model_path = Path::new("assets/models/sleepgpt/sleepgpt_weights.json");
        let raw_scoring_path = Path::new("/tmp/yasa_test/AS_CNT_08_Night1_yasa_scoring.json");
        let gt_sleepgpt_path = Path::new("/tmp/yasa_test/AS_CNT_08_Night1_yasa_sleepgpt_scoring.json");

        if !model_path.exists() || !raw_scoring_path.exists() || !gt_sleepgpt_path.exists() {
            println!("Skipping full night test: test files not present");
            return Ok(());
        }

        let model = SleepGptModel::load_from_json(model_path)?;

        // Read raw YASA scoring JSON
        let raw_file = std::fs::File::open(raw_scoring_path)?;
        let raw_val: serde_json::Value = serde_json::from_reader(raw_file)?;
        let raw_epochs = raw_val[0].as_array().context("epochs array")?;

        let stage_names = ["W", "N1", "N2", "N3", "R"];
        let mut raw_probs = Vec::with_capacity(raw_epochs.len());

        for ep in raw_epochs {
            let probs_obj = &ep["probabilities"];
            let mut p = [0.0f64; 5];
            for (idx, name) in stage_names.iter().enumerate() {
                p[idx] = probs_obj[name].as_f64().unwrap_or(0.0);
            }
            raw_probs.push(p);
        }

        let corrected_indices = run_sleepgpt_correction(&model, &raw_probs, 0.1, 30)?;
        let stage_labels = ["Wake", "N1", "N2", "N3", "REM"];
        let corrected_stages: Vec<&str> = corrected_indices
            .iter()
            .map(|&idx| stage_labels[idx])
            .collect();

        // Read ground truth Python SleepGPT scoring JSON
        let gt_file = std::fs::File::open(gt_sleepgpt_path)?;
        let gt_val: serde_json::Value = serde_json::from_reader(gt_file)?;
        let gt_epochs = gt_val[0].as_array().context("gt epochs array")?;

        assert_eq!(corrected_stages.len(), gt_epochs.len());

        let mut matches = 0;
        let total = gt_epochs.len();

        for (i, ep) in gt_epochs.iter().enumerate() {
            let gt_stage = ep["stage"].as_str().unwrap_or("");
            let rust_stage = corrected_stages[i];
            if gt_stage == rust_stage {
                matches += 1;
            } else {
                println!(
                    "Epoch {} mismatch: Rust={}, Python={}",
                    i + 1, rust_stage, gt_stage
                );
            }
        }

        let agreement = (matches as f64) / (total as f64) * 100.0;
        println!(
            "SleepGPT 784-epoch full night parity: {}/{} ({:.2}%) EXACT MATCH",
            matches, total, agreement
        );

        assert!(
            agreement >= 99.9,
            "SleepGPT agreement too low: {:.2}%",
            agreement
        );
        Ok(())
    }
}
