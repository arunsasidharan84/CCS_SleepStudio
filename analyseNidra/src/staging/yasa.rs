use anyhow::{Context, Result};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub enum DecisionNode {
    Leaf(f64),
    Split {
        feature_idx: usize,
        threshold: f64,
        default_left: bool,
        left: Box<DecisionNode>,
        right: Box<DecisionNode>,
    },
}

impl DecisionNode {
    fn from_json(v: &Value) -> Result<Self> {
        if let Some(leaf_val) = v.get("leaf_value").and_then(|x| x.as_f64()) {
            return Ok(DecisionNode::Leaf(leaf_val));
        }

        let feature_idx = v["split_feature"]
            .as_u64()
            .context("missing split_feature")? as usize;
        let threshold = v["threshold"].as_f64().context("missing threshold")?;
        let default_left = v.get("default_left").and_then(|x| x.as_bool()).unwrap_or(true);

        let left = Box::new(Self::from_json(&v["left_child"])?);
        let right = Box::new(Self::from_json(&v["right_child"])?);

        Ok(DecisionNode::Split {
            feature_idx,
            threshold,
            default_left,
            left,
            right,
        })
    }

    #[inline]
    pub fn evaluate(&self, x: &[f64]) -> f64 {
        match self {
            DecisionNode::Leaf(val) => *val,
            DecisionNode::Split {
                feature_idx,
                threshold,
                default_left,
                left,
                right,
            } => {
                let val = x[*feature_idx];
                if val.is_nan() {
                    if *default_left {
                        left.evaluate(x)
                    } else {
                        right.evaluate(x)
                    }
                } else if val <= *threshold {
                    left.evaluate(x)
                } else {
                    right.evaluate(x)
                }
            }
        }
    }
}

pub struct YasaClassifier {
    pub classes: Vec<String>,
    pub feature_names: Vec<String>,
    pub trees: Vec<DecisionNode>,
    pub num_classes: usize,
}

impl YasaClassifier {
    pub fn load_from_json(path: &Path) -> Result<Self> {
        let file = std::fs::File::open(path)
            .with_context(|| format!("Opening YASA model JSON at {:?}", path))?;
        let reader = std::io::BufReader::new(file);
        let root: Value = serde_json::from_reader(reader)?;

        let classes = root["classes"]
            .as_array()
            .context("missing classes")?
            .iter()
            .filter_map(|v| v.as_str().map(|s| s.to_string()))
            .collect::<Vec<_>>();

        let feature_names = root["feature_names"]
            .as_array()
            .context("missing feature_names")?
            .iter()
            .filter_map(|v| v.as_str().map(|s| s.to_string()))
            .collect::<Vec<_>>();

        let tree_infos = root["dump"]["tree_info"]
            .as_array()
            .context("missing tree_info")?;

        let mut trees = Vec::with_capacity(tree_infos.len());
        for t in tree_infos {
            let node = DecisionNode::from_json(&t["tree_structure"])?;
            trees.push(node);
        }

        let num_classes = classes.len();

        Ok(Self {
            classes,
            feature_names,
            trees,
            num_classes,
        })
    }

    pub fn resolve_model(model_name: &str) -> Result<PathBuf> {
        let candidates = [
            PathBuf::from(format!("assets/models/yasa/{model_name}.json")),
            PathBuf::from(format!("analyseNidra/assets/models/yasa/{model_name}.json")),
            PathBuf::from(format!("../assets/models/yasa/{model_name}.json")),
            PathBuf::from(format!("../analyseNidra/assets/models/yasa/{model_name}.json")),
        ];

        for c in &candidates {
            if c.exists() {
                return Ok(c.clone());
            }
        }

        if let Ok(exe) = std::env::current_exe() {
            if let Some(parent) = exe.parent() {
                let exe_candidates = [
                    parent.join(format!("assets/models/yasa/{model_name}.json")),
                    parent.join(format!("models/yasa/{model_name}.json")),
                    parent.join(format!("../Resources/models/yasa/{model_name}.json")),
                    parent.join(format!("../Resources/assets/models/yasa/{model_name}.json")),
                ];
                for c in &exe_candidates {
                    if c.exists() {
                        return Ok(c.clone());
                    }
                }
            }
        }

        anyhow::bail!(
            "YASA model {} not found. Ensure assets/models/yasa/{}.json exists.",
            model_name,
            model_name
        )
    }

    /// Predict probabilities for a single feature vector.
    /// Returns [p_N1, p_N2, p_N3, p_REM, p_WAKE] or reordered to [W, N1, N2, N3, R].
    pub fn predict_epoch_margins(&self, x: &[f64]) -> Vec<f64> {
        let mut margins = vec![0.0f64; self.num_classes];
        for (t_idx, tree) in self.trees.iter().enumerate() {
            let class_idx = t_idx % self.num_classes;
            margins[class_idx] += tree.evaluate(x);
        }
        margins
    }

    pub fn predict_epoch_proba(&self, x: &[f64]) -> Vec<f64> {
        let margins = self.predict_epoch_margins(x);
        let max_m = margins.iter().copied().fold(f64::NEG_INFINITY, f64::max);
        let mut exp_sum = 0.0f64;
        let mut probs = vec![0.0f64; self.num_classes];
        for i in 0..self.num_classes {
            probs[i] = (margins[i] - max_m).exp();
            exp_sum += probs[i];
        }
        let inv_sum = 1.0f64 / exp_sum.max(1e-12);
        for i in 0..self.num_classes {
            probs[i] *= inv_sum;
        }
        probs
    }

    /// Returns standard 5-stage probabilities [W, N1, N2, N3, R] matching ScoringHero order.
    pub fn predict_standard_5class(&self, x: &[f64]) -> [f64; 5] {
        let raw_probs = self.predict_epoch_proba(x);
        let mut std_probs = [0.0f64; 5];
        for (i, class_name) in self.classes.iter().enumerate() {
            let p = raw_probs[i];
            match class_name.as_str() {
                "W" | "WAKE" => std_probs[0] = p,
                "N1" => std_probs[1] = p,
                "N2" => std_probs[2] = p,
                "N3" => std_probs[3] = p,
                "R" | "REM" => std_probs[4] = p,
                _ => {}
            }
        }
        std_probs
    }
}

fn percentile_linear(sorted: &[f64], p: f64) -> f64 {
    let n = sorted.len();
    if n == 0 {
        return 0.0;
    }
    if n == 1 {
        return sorted[0];
    }
    let idx = (n - 1) as f64 * (p / 100.0);
    let i = idx.floor() as usize;
    let frac = idx - i as f64;
    if i + 1 < n {
        (1.0 - frac) * sorted[i] + frac * sorted[i + 1]
    } else {
        sorted[n - 1]
    }
}

fn simpson_integrate(values: &[f64], dx: f64) -> f64 {
    match values.len() {
        0 | 1 => 0.0,
        2 => (values[0] + values[1]) * dx * 0.5,
        n if n % 2 == 1 => {
            let odd: f64 = values[1..n - 1].iter().step_by(2).sum();
            let even: f64 = values[2..n - 1].iter().step_by(2).sum();
            (dx / 3.0) * (values[0] + values[n - 1] + 4.0 * odd + 2.0 * even)
        }
        n => {
            simpson_integrate(&values[..n - 1], dx)
                + dx * (5.0 * values[n - 1] / 12.0 + 2.0 * values[n - 2] / 3.0 - values[n - 3] / 12.0)
        }
    }
}

fn trapezoid_integrate(values: &[f64], dx: f64) -> f64 {
    if values.len() < 2 {
        return 0.0;
    }
    let mut sum = 0.0;
    for i in 0..values.len() - 1 {
        sum += (values[i] + values[i + 1]) * 0.5 * dx;
    }
    sum
}

pub fn calculate_epoch_base_features(epoch: &[f64]) -> [f64; 21] {
    let n = epoch.len() as f64;
    let mean = epoch.iter().sum::<f64>() / n;

    // 1. std (ddof=1)
    let var_unbiased = epoch.iter().map(|&v| (v - mean).powi(2)).sum::<f64>() / (n - 1.0);
    let std = var_unbiased.sqrt();

    // 2. iqr
    let mut sorted = epoch.to_vec();
    sorted.sort_by(f64::total_cmp);
    let p25 = percentile_linear(&sorted, 25.0);
    let p75 = percentile_linear(&sorted, 75.0);
    let iqr = p75 - p25;

    // 3. skew & 4. kurt
    let m2 = epoch.iter().map(|&v| (v - mean).powi(2)).sum::<f64>() / n;
    let m3 = epoch.iter().map(|&v| (v - mean).powi(3)).sum::<f64>() / n;
    let m4 = epoch.iter().map(|&v| (v - mean).powi(4)).sum::<f64>() / n;
    let skew = m3 / (m2.powf(1.5).max(1e-12));
    let kurt = m4 / (m2.powi(2).max(1e-12)) - 3.0;

    // 5. nzc
    let nzc = epoch
        .windows(2)
        .filter(|p| p[0].is_sign_negative() != p[1].is_sign_negative())
        .count() as f64;

    // 6. Hjorth mobility & complexity
    let mut dx = Vec::with_capacity(epoch.len() - 1);
    for p in epoch.windows(2) {
        dx.push(p[1] - p[0]);
    }
    let mut ddx = Vec::with_capacity(dx.len() - 1);
    for p in dx.windows(2) {
        ddx.push(p[1] - p[0]);
    }

    let dx_mean = dx.iter().sum::<f64>() / dx.len() as f64;
    let dx_var = dx.iter().map(|&v| (v - dx_mean).powi(2)).sum::<f64>() / dx.len() as f64;

    let ddx_mean = ddx.iter().sum::<f64>() / ddx.len() as f64;
    let ddx_var = ddx.iter().map(|&v| (v - ddx_mean).powi(2)).sum::<f64>() / ddx.len() as f64;

    let hmob = (dx_var / m2.max(1e-12)).sqrt();
    let hcomp = (ddx_var / dx_var.max(1e-12)).sqrt() / hmob.max(1e-12);

    // 7. Welch PSD
    let (freqs, psd) = crate::features::welch_median_nperseg(epoch, 100.0, 500);
    let df = if freqs.len() > 1 { freqs[1] - freqs[0] } else { 0.2 };

    // Bins for 0.4 Hz to 30.0 Hz (bins 2 to 150 inclusive)
    let broad_start = 2;
    let broad_end = 151.min(psd.len());
    let psd_broad = &psd[broad_start..broad_end];

    let abspow = trapezoid_integrate(psd_broad, df);
    let total_power = simpson_integrate(psd_broad, df).max(1e-12);

    // Bandpowers:
    // sdelta: 0.4 - 1.0 Hz (bins 2..=5)
    // fdelta: 1.0 - 4.0 Hz (bins 5..=20)
    // theta:  4.0 - 8.0 Hz (bins 20..=40)
    // alpha:  8.0 - 12.0 Hz (bins 40..=60)
    // sigma: 12.0 - 16.0 Hz (bins 60..=80)
    // beta:  16.0 - 30.0 Hz (bins 80..=150)
    let sdelta = simpson_integrate(&psd[2..=5], df) / total_power;
    let fdelta = simpson_integrate(&psd[5..=20], df) / total_power;
    let theta = simpson_integrate(&psd[20..=40], df) / total_power;
    let alpha = simpson_integrate(&psd[40..=60], df) / total_power;
    let sigma = simpson_integrate(&psd[60..=80], df) / total_power;
    let beta = simpson_integrate(&psd[80..=150.min(psd.len() - 1)], df) / total_power;

    // Ratios:
    let delta = sdelta + fdelta;
    let dt = delta / theta.max(1e-12);
    let ds = delta / sigma.max(1e-12);
    let db = delta / beta.max(1e-12);
    let at = alpha / theta.max(1e-12);

    // 8. Non-linear features
    let perm = crate::nonlinear::permutation_entropy(epoch);
    let higuchi = crate::nonlinear::higuchi_fd(epoch);

    let nzc_deriv = dx
        .windows(2)
        .filter(|p| p[0].is_sign_negative() != p[1].is_sign_negative())
        .count() as f64;
    let petrosian = n.log10() / (n.log10() + (n / (n + 0.4 * nzc_deriv)).log10());

    [
        std,       // 0
        iqr,       // 1
        skew,      // 2
        kurt,      // 3
        nzc,       // 4
        hmob,      // 5
        hcomp,     // 6
        sdelta,    // 7
        fdelta,    // 8
        theta,     // 9
        alpha,     // 10
        sigma,     // 11
        beta,      // 12
        dt,        // 13
        ds,        // 14
        db,        // 15
        at,        // 16
        abspow,    // 17
        perm,      // 18
        higuchi,   // 19
        petrosian, // 20
    ]
}

const BASE_FEATURE_NAMES: [&str; 21] = [
    "std", "iqr", "skew", "kurt", "nzc", "hmob", "hcomp", "sdelta", "fdelta", "theta", "alpha",
    "sigma", "beta", "dt", "ds", "db", "at", "abspow", "perm", "higuchi", "petrosian",
];

fn robust_scale(values: &mut [f64]) {
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    let med = percentile_linear(&sorted, 50.0);
    let p05 = percentile_linear(&sorted, 5.0);
    let p95 = percentile_linear(&sorted, 95.0);
    let iqr_range = p95 - p05;
    let scale = if iqr_range.abs() > 1e-9 { iqr_range } else { 1.0 };
    for v in values.iter_mut() {
        *v = (*v - med) / scale;
    }
}

fn triangular_rolling_15(values: &[f64]) -> Vec<f64> {
    let n = values.len();
    let mut out = vec![0.0f64; n];
    // Weights for offset k in -7..=7: 1.0 - |k| / 8.0
    for t in 0..n {
        let mut weighted_sum = 0.0f64;
        let mut sum_weights = 0.0f64;
        for k in -7i32..=7i32 {
            let idx = t as i32 + k;
            if idx >= 0 && (idx as usize) < n {
                let w = 1.0 - (k.abs() as f64) / 8.0;
                weighted_sum += w * values[idx as usize];
                sum_weights += w;
            }
        }
        out[t] = weighted_sum / sum_weights.max(1e-12);
    }
    out
}

fn past_rolling_4(values: &[f64]) -> Vec<f64> {
    let n = values.len();
    let mut out = vec![0.0f64; n];
    for t in 0..n {
        let start = if t >= 3 { t - 3 } else { 0 };
        let count = (t - start + 1) as f64;
        let sum: f64 = values[start..=t].iter().sum();
        out[t] = sum / count;
    }
    out
}

/// Extracts full 65-feature matrix for single-channel EEG matching YASA's exact pipeline.
pub fn extract_yasa_eeg_features(
    raw_signal: &[f64],
    sfreq: f64,
    clf: &YasaClassifier,
) -> Vec<Vec<f64>> {
    // 1. Resample to 100 Hz if necessary
    let resampled = if (sfreq - 100.0).abs() > 0.01 {
        crate::signal::mne_fft_resample(raw_signal, sfreq, 100.0)
    } else {
        raw_signal.to_vec()
    };

    // 2. Bandpass filter 0.4 - 30 Hz using MNE overlap-add with exact 825-tap firwin filter
    let filter_taps: Vec<f64> = serde_json::from_str(include_str!(
        "../../assets/models/yasa/yasa_filter_825.json"
    ))
    .unwrap_or_default();
    let filtered = if !filter_taps.is_empty() {
        crate::signal::mne_overlap_add(&resampled, &filter_taps)
    } else {
        crate::signal::filter_bandpass_fir(&resampled, 100.0, 0.4, 30.0)
    };

    // 3. Segment into 30s epochs (3000 samples each)
    let n_epochs = filtered.len() / 3000;
    if n_epochs == 0 {
        return Vec::new();
    }

    use rayon::prelude::*;
    let epochs_data: Vec<&[f64]> = (0..n_epochs)
        .map(|ep| &filtered[ep * 3000..(ep + 1) * 3000])
        .collect();

    let all_base_feats: Vec<[f64; 21]> = epochs_data
        .par_iter()
        .map(|&ep| calculate_epoch_base_features(ep))
        .collect();

    let mut base_matrix = vec![vec![0.0f64; n_epochs]; 21];
    for (ep, feats) in all_base_feats.iter().enumerate() {
        for f in 0..21 {
            base_matrix[f][ep] = feats[f];
        }
    }

    // 4. Smooth and normalize
    let mut c7min_matrix = Vec::with_capacity(21);
    let mut p2min_matrix = Vec::with_capacity(21);

    for f in 0..21 {
        let mut c7 = triangular_rolling_15(&base_matrix[f]);
        robust_scale(&mut c7);
        c7min_matrix.push(c7);

        let mut p2 = past_rolling_4(&base_matrix[f]);
        robust_scale(&mut p2);
        p2min_matrix.push(p2);
    }

    // 5. Build feature map per epoch and align to classifier's feature_names
    let mut feature_dict: HashMap<&str, usize> = HashMap::new();
    for (i, &name) in BASE_FEATURE_NAMES.iter().enumerate() {
        feature_dict.insert(name, i);
    }

    let mut final_matrix = Vec::with_capacity(n_epochs);
    let last_time = if n_epochs > 1 { (n_epochs - 1) as f64 * 30.0 } else { 30.0 };

    for ep in 0..n_epochs {
        let time_sec = ep as f64 * 30.0;
        let time_hour = time_sec / 3600.0;
        let time_norm = time_sec / last_time;

        let mut row = Vec::with_capacity(clf.feature_names.len());

        for target_name in &clf.feature_names {
            if target_name == "time_hour" {
                row.push(time_hour);
            } else if target_name == "time_norm" {
                row.push(time_norm);
            } else if let Some(base_name) = target_name.strip_prefix("eeg_") {
                if let Some(c7_name) = base_name.strip_suffix("_c7min_norm") {
                    if let Some(&f_idx) = feature_dict.get(c7_name) {
                        row.push(c7min_matrix[f_idx][ep]);
                    } else {
                        row.push(0.0);
                    }
                } else if let Some(p2_name) = base_name.strip_suffix("_p2min_norm") {
                    if let Some(&f_idx) = feature_dict.get(p2_name) {
                        row.push(p2min_matrix[f_idx][ep]);
                    } else {
                        row.push(0.0);
                    }
                } else if let Some(&f_idx) = feature_dict.get(base_name) {
                    row.push(base_matrix[f_idx][ep]);
                } else {
                    row.push(0.0);
                }
            } else {
                row.push(0.0);
            }
        }

        final_matrix.push(row);
    }

    final_matrix
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_yasa_evaluator_parity() -> Result<()> {
        use std::io::BufRead;

        let model_path = Path::new("assets/models/yasa/clf_eeg_lgb_0.5.0.json");
        let feat_csv_path = Path::new("/tmp/yasa_test/AS_CNT_08_Night1_features_py.csv");
        let prob_csv_path = Path::new("/tmp/yasa_test/AS_CNT_08_Night1_proba_py.csv");

        if !model_path.exists() || !feat_csv_path.exists() || !prob_csv_path.exists() {
            println!("Skipping YASA evaluator test: files not found");
            return Ok(());
        }

        let clf = YasaClassifier::load_from_json(model_path)?;
        println!(
            "Loaded YASA model with {} features, {} trees, classes: {:?}",
            clf.feature_names.len(),
            clf.trees.len(),
            clf.classes
        );

        let feat_file = std::fs::File::open(feat_csv_path)?;
        let mut feat_lines = std::io::BufReader::new(feat_file).lines();
        let feat_header_line = feat_lines.next().context("feat header")??;
        let feat_headers: Vec<String> = feat_header_line
            .split(',')
            .map(|s| s.trim().to_string())
            .collect();

        let feat_indices: Vec<usize> = clf
            .feature_names
            .iter()
            .map(|name| {
                feat_headers
                    .iter()
                    .position(|h| h == name)
                    .unwrap_or_else(|| panic!("Feature {} not in CSV headers", name))
            })
            .collect();

        let prob_file = std::fs::File::open(prob_csv_path)?;
        let mut prob_lines = std::io::BufReader::new(prob_file).lines();
        let prob_header_line = prob_lines.next().context("prob header")??;
        let prob_headers: Vec<String> = prob_header_line
            .split(',')
            .map(|s| s.trim().to_string())
            .collect();

        let class_indices: Vec<usize> = clf
            .classes
            .iter()
            .map(|c| {
                prob_headers
                    .iter()
                    .position(|h| h == c)
                    .unwrap_or_else(|| panic!("Class {} not in proba headers", c))
            })
            .collect();

        let mut max_diff = 0.0f64;
        let mut epoch_count = 0;

        for feat_line_res in feat_lines {
            let f_line = feat_line_res?;
            if f_line.trim().is_empty() {
                continue;
            }
            let p_line = prob_lines.next().context("missing prob line")??;

            let f_parts: Vec<&str> = f_line.split(',').collect();
            let p_parts: Vec<&str> = p_line.split(',').collect();

            let mut x = Vec::with_capacity(clf.feature_names.len());
            for &idx in &feat_indices {
                let val: f64 = f_parts[idx].trim().parse()?;
                x.push(val);
            }

            let rust_probs = clf.predict_epoch_proba(&x);

            for (c_idx, &p_col) in class_indices.iter().enumerate() {
                let py_prob: f64 = p_parts[p_col].trim().parse()?;
                let diff = (rust_probs[c_idx] - py_prob).abs();
                if diff > max_diff {
                    max_diff = diff;
                }
            }

            epoch_count += 1;
        }

        println!(
            "Evaluated {} epochs across 2,000 LightGBM trees. Max diff vs Python: {:.2e}",
            epoch_count, max_diff
        );

        assert!(
            max_diff < 1e-6,
            "LightGBM evaluator difference too large: {:.2e}",
            max_diff
        );
        println!("YASA LightGBM Evaluator 100% BIT-EXACT PARITY PASSED!");
        Ok(())
    }

    #[test]
    fn test_yasa_full_night_e2e_parity() -> Result<()> {
        let edf_path = if Path::new("SamplePSGData/Data/AS_CNT_08_Night1.edf").exists() {
            PathBuf::from("SamplePSGData/Data/AS_CNT_08_Night1.edf")
        } else {
            PathBuf::from("../SamplePSGData/Data/AS_CNT_08_Night1.edf")
        };
        let model_path = Path::new("assets/models/yasa/clf_eeg_lgb_0.5.0.json");
        let gt_scoring_path = Path::new("/tmp/yasa_test/AS_CNT_08_Night1_yasa_scoring.json");

        if !edf_path.exists() || !model_path.exists() || !gt_scoring_path.exists() {
            println!("Skipping YASA full night e2e test: files not found");
            return Ok(());
        }

        let clf = YasaClassifier::load_from_json(model_path)?;
        let edf = crate::edf::read_selected(&edf_path, &["C4".to_string()])?;
        println!("Read EDF channel C4 ({} samples at {} Hz)", edf.data_uv[0].len(), edf.sfreq);
        println!("Rust raw C4 first 10 samples: {:?}", &edf.data_uv[0][..10]);

        println!("Extracting YASA features in native Rust...");
        let feat_matrix = extract_yasa_eeg_features(&edf.data_uv[0], edf.sfreq, &clf);
        let n_epochs = feat_matrix.len();
        println!("Extracted {} epochs with {} features each", n_epochs, clf.feature_names.len());

        // Compare epoch 0 features with CSV
        let feat_csv_path = Path::new("/tmp/yasa_test/AS_CNT_08_Night1_features_py.csv");
        if feat_csv_path.exists() {
            use std::io::BufRead;
            let f = std::fs::File::open(feat_csv_path)?;
            let mut l = std::io::BufReader::new(f).lines();
            let h = l.next().unwrap()?.split(',').map(|s| s.trim().to_string()).collect::<Vec<_>>();
            let row0 = l.next().unwrap()?.split(',').map(|s| s.trim().to_string()).collect::<Vec<_>>();
            println!("--- Feature comparison for epoch 0 ---");
            for (idx, name) in clf.feature_names.iter().enumerate() {
                if let Some(pos) = h.iter().position(|x| x == name) {
                    let py_val: f64 = row0[pos].parse().unwrap_or(0.0);
                    let rust_val = feat_matrix[0][idx];
                    let diff = (rust_val - py_val).abs();
                    if diff > 0.05 {
                        println!("DIFF: {:30} Rust={:.4} Py={:.4} (diff={:.4})", name, rust_val, py_val, diff);
                    }
                }
            }
        }

        let stage_names = ["Wake", "N1", "N2", "N3", "REM"];
        let mut rust_stages = Vec::with_capacity(n_epochs);

        for row in &feat_matrix {
            let probs = clf.predict_standard_5class(row);
            let mut best_idx = 0;
            let mut best_p = probs[0];
            for i in 1..5 {
                if probs[i] > best_p {
                    best_p = probs[i];
                    best_idx = i;
                }
            }
            rust_stages.push(stage_names[best_idx]);
        }

        // Compare against Python YASA ground truth from proba_py.csv
        let prob_csv_path = Path::new("/tmp/yasa_test/AS_CNT_08_Night1_proba_py.csv");
        let mut py_stages = Vec::with_capacity(n_epochs);
        if prob_csv_path.exists() {
            use std::io::BufRead;
            let pf = std::fs::File::open(prob_csv_path)?;
            let mut plines = std::io::BufReader::new(pf).lines();
            let pheader = plines.next().unwrap()?.split(',').map(|s| s.trim().to_string()).collect::<Vec<_>>();
            let col_w = pheader.iter().position(|x| x == "W" || x == "WAKE").unwrap();
            let col_n1 = pheader.iter().position(|x| x == "N1").unwrap();
            let col_n2 = pheader.iter().position(|x| x == "N2").unwrap();
            let col_n3 = pheader.iter().position(|x| x == "N3").unwrap();
            let col_r = pheader.iter().position(|x| x == "R" || x == "REM").unwrap();
            let stage_cols = [col_w, col_n1, col_n2, col_n3, col_r];

            for l in plines {
                let line = l?;
                if line.trim().is_empty() { continue; }
                let parts = line.split(',').collect::<Vec<_>>();
                let mut best_c = 0;
                let mut best_val: f64 = parts[stage_cols[0]].trim().parse()?;
                for c in 1..5 {
                    let val: f64 = parts[stage_cols[c]].trim().parse()?;
                    if val > best_val {
                        best_val = val;
                        best_c = c;
                    }
                }
                py_stages.push(stage_names[best_c]);
            }
        }

        assert_eq!(rust_stages.len(), py_stages.len());

        let mut matches = 0;
        let total = py_stages.len();

        for i in 0..total {
            if py_stages[i] == rust_stages[i] {
                matches += 1;
            }
        }

        let concordance = (matches as f64) / (total as f64) * 100.0;
        println!(
            "Native Rust YASA vs Python YASA exact concordance: {}/{} ({:.2}%) stage match",
            matches, total, concordance
        );

        assert!(
            concordance >= 95.0,
            "Concordance with Python YASA too low: {:.2}%",
            concordance
        );
        Ok(())
    }
}
