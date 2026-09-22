use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::File;
use std::io::{BufReader, BufWriter};
use std::path::{Path, PathBuf};
use std::time::Instant;

use super::gssc::{score_gssc_recording, GsscModel};
use super::model::StagingModel;
use super::physioex::{score_physioex_channel, PhysioExModel};
use super::sleepgpt::{run_sleepgpt_correction, SleepGptModel};
use super::usleep::{score_usleep_recording, USleepModel};
use super::windowing::{build_sequence_window, prepare_staging_epochs};
use super::yasa::{extract_yasa_eeg_features, YasaClassifier};
use crate::edf::read_selected;

pub const STAGE_LABELS: [&str; 5] = ["Wake", "N1", "N2", "N3", "REM"];
pub const STAGE_DIGITS: [i32; 5] = [1, -1, -2, -3, 0];

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScoringHeroRecord {
    pub epoch: usize,
    pub start: usize,
    pub end: usize,
    pub stage: String,
    pub digit: i32,
    pub confidence: f64,
    pub probabilities: HashMap<String, f64>,
    pub channels: Vec<String>,
    pub clean: i32,
    pub source: String,
}

#[derive(Debug, Clone)]
pub struct SleepStagingResult {
    pub total_epochs: usize,
    pub output_path: PathBuf,
    pub stages: Vec<String>,
    pub duration_seconds: f64,
}

/// Attempts to find and extract an EOG signal (bipolar or unipolar) from the EDF file.
pub fn try_find_eog_signal(edf_path: &Path) -> Option<Vec<f64>> {
    let eog_pairs = [
        ("LOC1", "ROC1"),
        ("LOC", "ROC"),
        ("E1", "E2"),
        ("E1-M2", "E2-M1"),
        ("EOG-L", "EOG-R"),
    ];
    for (l, r) in eog_pairs {
        if let Ok(data) = read_selected(edf_path, &[l.to_string(), r.to_string()]) {
            if data.data_uv.len() >= 2 {
                let n = data.data_uv[0].len().min(data.data_uv[1].len());
                let bip = (0..n).map(|i| data.data_uv[0][i] - data.data_uv[1][i]).collect();
                return Some(bip);
            }
        }
    }
    let single_eogs = ["EOG", "LOC", "ROC", "E1", "E2", "LOC1", "ROC1"];
    for ch in single_eogs {
        if let Ok(data) = read_selected(edf_path, &[ch.to_string()]) {
            if !data.data_uv.is_empty() {
                return Some(data.data_uv[0].clone());
            }
        }
    }
    None
}

/// Automatically scores an EDF recording using native Rust algorithms (TinySleepNet, YASA, U-Sleep, SeqSleepNet, SleepTransformer, GSSC)
/// with optional SleepGPT sequence correction.
pub fn score_edf_file(
    edf_path: &Path,
    algorithm_arg: Option<&str>,
    sequence_correction_arg: Option<&str>,
    preferred_channel: Option<&str>,
    preferred_ref: Option<&str>,
    out_json_path: Option<&Path>,
    sleepgpt_alpha: Option<f64>,
    sleepgpt_ngram: Option<usize>,
) -> Result<SleepStagingResult> {
    let start_time = Instant::now();
    let algo_name = algorithm_arg.unwrap_or("tinysleepnet").to_lowercase();
    let is_yasa = algo_name.contains("yasa");
    let is_usleep = algo_name.contains("usleep") || algo_name.contains("u-sleep");
    let is_seqsleepnet = algo_name.contains("seqsleepnet");
    let is_sleeptransformer = algo_name.contains("sleeptransformer") || algo_name.contains("transformer");
    let is_gssc = algo_name.contains("gssc");
    let seq_corr = sequence_correction_arg.unwrap_or("none").to_lowercase();
    let use_sleepgpt = seq_corr == "sleepgpt";

    // Pick channel
    let chan = preferred_channel.unwrap_or("C4").to_string();
    let ref_chan = preferred_ref.map(|r| r.to_string());

    let mut load_list = vec![chan.clone()];
    if let Some(ref r) = ref_chan {
        load_list.push(r.clone());
    }

    println!("PROGRESS 0.10 Loading EDF channel(s) {:?}", load_list);
    let edf = match read_selected(edf_path, &load_list) {
        Ok(data) => data,
        Err(orig_err) => {
            let mut found = None;
            let fallbacks = ["C3", "F4", "F3", "Cz"];
            for fb in fallbacks {
                if let Ok(data) = read_selected(edf_path, &[fb.to_string()]) {
                    println!("  Fallback to channel {}", fb);
                    found = Some(data);
                    break;
                }
            }
            match found {
                Some(d) => d,
                None => anyhow::bail!("Could not load EEG channel from EDF {:?}: {}", edf_path, orig_err),
            }
        }
    };

    // Prepare single-channel EEG (derivation = chan - ref if ref provided)
    let mut signal = edf.data_uv[0].clone();
    if edf.data_uv.len() > 1 {
        for (i, &r_val) in edf.data_uv[1].iter().enumerate().take(signal.len()) {
            signal[i] -= r_val;
        }
    }

    let mut records = Vec::new();
    let mut stages = Vec::new();
    let mut all_probs: Vec<[f64; 5]> = Vec::new();
    let base_source_str: &str;

    if is_yasa {
        base_source_str = "native_yasa";
        println!("PROGRESS 0.20 Loading YASA classifier...");
        let yasa_path = YasaClassifier::resolve_model("clf_eeg_lgb_0.5.0")?;
        let clf = YasaClassifier::load_from_json(&yasa_path)?;

        println!("PROGRESS 0.30 Extracting YASA features in native Rust...");
        let feat_matrix = extract_yasa_eeg_features(&signal, edf.sfreq, &clf);
        let n_epochs = feat_matrix.len();
        println!("PROGRESS 0.60 Scoring {} epochs with YASA LightGBM...", n_epochs);

        for (ep, row) in feat_matrix.iter().enumerate() {
            let probs = clf.predict_standard_5class(row);
            let mut best_idx = 0;
            let mut best_p = probs[0];
            for i in 1..5 {
                if probs[i] > best_p {
                    best_p = probs[i];
                    best_idx = i;
                }
            }

            all_probs.push(probs);
            stages.push(STAGE_LABELS[best_idx].to_string());

            let mut prob_map = HashMap::new();
            prob_map.insert("W".to_string(), (probs[0] * 1e6).round() / 1e6);
            prob_map.insert("N1".to_string(), (probs[1] * 1e6).round() / 1e6);
            prob_map.insert("N2".to_string(), (probs[2] * 1e6).round() / 1e6);
            prob_map.insert("N3".to_string(), (probs[3] * 1e6).round() / 1e6);
            prob_map.insert("R".to_string(), (probs[4] * 1e6).round() / 1e6);

            records.push(ScoringHeroRecord {
                epoch: ep + 1,
                start: ep * 30,
                end: (ep + 1) * 30,
                stage: STAGE_LABELS[best_idx].to_string(),
                digit: STAGE_DIGITS[best_idx],
                confidence: (best_p * 1e4).round() / 1e4,
                probabilities: prob_map,
                channels: vec![chan.clone()],
                clean: 1,
                source: base_source_str.to_string(),
            });
        }
    } else if is_usleep {
        base_source_str = "native_usleep";
        println!("PROGRESS 0.20 Locating U-Sleep model...");
        let model_path = USleepModel::resolve_model(algorithm_arg)?;
        println!("PROGRESS 0.25 Loading U-Sleep model from {:?}", model_path);
        let model = USleepModel::load_from_path(&model_path)?;
        let eog_opt = try_find_eog_signal(edf_path);
        if eog_opt.is_some() {
            println!("  Found and using EOG channel for U-Sleep.");
        }
        println!("PROGRESS 0.35 Scoring recording with U-Sleep...");
        all_probs = score_usleep_recording(&signal, eog_opt.as_deref(), edf.sfreq, &model)?;

        for (ep, probs) in all_probs.iter().enumerate() {
            let mut best_idx = 0;
            let mut best_p = probs[0];
            for i in 1..5 {
                if probs[i] > best_p {
                    best_p = probs[i];
                    best_idx = i;
                }
            }

            let stage_name = STAGE_LABELS[best_idx].to_string();
            let digit = STAGE_DIGITS[best_idx];

            let mut prob_map = HashMap::new();
            prob_map.insert("W".to_string(), (probs[0] * 1e6).round() / 1e6);
            prob_map.insert("N1".to_string(), (probs[1] * 1e6).round() / 1e6);
            prob_map.insert("N2".to_string(), (probs[2] * 1e6).round() / 1e6);
            prob_map.insert("N3".to_string(), (probs[3] * 1e6).round() / 1e6);
            prob_map.insert("R".to_string(), (probs[4] * 1e6).round() / 1e6);

            stages.push(stage_name.clone());
            records.push(ScoringHeroRecord {
                epoch: ep + 1,
                start: ep * 30,
                end: (ep + 1) * 30,
                stage: stage_name,
                digit,
                confidence: (best_p * 1e4).round() / 1e4,
                probabilities: prob_map,
                channels: vec![chan.clone()],
                clean: 1,
                source: base_source_str.to_string(),
            });
        }
    } else if is_seqsleepnet {
        base_source_str = "native_seqsleepnet";
        println!("PROGRESS 0.20 Locating SeqSleepNet model...");
        let model_path = PhysioExModel::resolve_model("seqsleepnet")?;
        println!("PROGRESS 0.25 Loading SeqSleepNet model from {:?}", model_path);
        let model = PhysioExModel::load_from_path(&model_path, "seqsleepnet")?;
        println!("PROGRESS 0.35 Scoring recording with SeqSleepNet...");
        all_probs = score_physioex_channel(&signal, edf.sfreq, &model)?;

        for (ep, probs) in all_probs.iter().enumerate() {
            let mut best_idx = 0;
            let mut best_p = probs[0];
            for i in 1..5 {
                if probs[i] > best_p {
                    best_p = probs[i];
                    best_idx = i;
                }
            }

            let stage_name = STAGE_LABELS[best_idx].to_string();
            let digit = STAGE_DIGITS[best_idx];

            let mut prob_map = HashMap::new();
            prob_map.insert("W".to_string(), (probs[0] * 1e6).round() / 1e6);
            prob_map.insert("N1".to_string(), (probs[1] * 1e6).round() / 1e6);
            prob_map.insert("N2".to_string(), (probs[2] * 1e6).round() / 1e6);
            prob_map.insert("N3".to_string(), (probs[3] * 1e6).round() / 1e6);
            prob_map.insert("R".to_string(), (probs[4] * 1e6).round() / 1e6);

            stages.push(stage_name.clone());
            records.push(ScoringHeroRecord {
                epoch: ep + 1,
                start: ep * 30,
                end: (ep + 1) * 30,
                stage: stage_name,
                digit,
                confidence: (best_p * 1e4).round() / 1e4,
                probabilities: prob_map,
                channels: vec![chan.clone()],
                clean: 1,
                source: base_source_str.to_string(),
            });
        }
    } else if is_sleeptransformer {
        base_source_str = "native_sleeptransformer";
        println!("PROGRESS 0.20 Locating SleepTransformer model...");
        let model_path = PhysioExModel::resolve_model("sleeptransformer")?;
        println!("PROGRESS 0.25 Loading SleepTransformer model from {:?}", model_path);
        let model = PhysioExModel::load_from_path(&model_path, "sleeptransformer")?;
        println!("PROGRESS 0.35 Scoring recording with SleepTransformer...");
        all_probs = score_physioex_channel(&signal, edf.sfreq, &model)?;

        for (ep, probs) in all_probs.iter().enumerate() {
            let mut best_idx = 0;
            let mut best_p = probs[0];
            for i in 1..5 {
                if probs[i] > best_p {
                    best_p = probs[i];
                    best_idx = i;
                }
            }

            let stage_name = STAGE_LABELS[best_idx].to_string();
            let digit = STAGE_DIGITS[best_idx];

            let mut prob_map = HashMap::new();
            prob_map.insert("W".to_string(), (probs[0] * 1e6).round() / 1e6);
            prob_map.insert("N1".to_string(), (probs[1] * 1e6).round() / 1e6);
            prob_map.insert("N2".to_string(), (probs[2] * 1e6).round() / 1e6);
            prob_map.insert("N3".to_string(), (probs[3] * 1e6).round() / 1e6);
            prob_map.insert("R".to_string(), (probs[4] * 1e6).round() / 1e6);

            stages.push(stage_name.clone());
            records.push(ScoringHeroRecord {
                epoch: ep + 1,
                start: ep * 30,
                end: (ep + 1) * 30,
                stage: stage_name,
                digit,
                confidence: (best_p * 1e4).round() / 1e4,
                probabilities: prob_map,
                channels: vec![chan.clone()],
                clean: 1,
                source: base_source_str.to_string(),
            });
        }
    } else if is_gssc {
        base_source_str = "native_gssc";
        println!("PROGRESS 0.20 Locating GSSC models...");
        let model = GsscModel::resolve_models()?;
        let eog_opt = try_find_eog_signal(edf_path);
        if eog_opt.is_some() {
            println!("  Found and using EOG channel for GSSC permutations.");
        }
        println!("PROGRESS 0.35 Scoring recording with GSSC...");
        all_probs = score_gssc_recording(&signal, eog_opt.as_deref(), edf.sfreq, &model)?;

        for (ep, probs) in all_probs.iter().enumerate() {
            let mut best_idx = 0;
            let mut best_p = probs[0];
            for i in 1..5 {
                if probs[i] > best_p {
                    best_p = probs[i];
                    best_idx = i;
                }
            }

            let stage_name = STAGE_LABELS[best_idx].to_string();
            let digit = STAGE_DIGITS[best_idx];

            let mut prob_map = HashMap::new();
            prob_map.insert("W".to_string(), (probs[0] * 1e6).round() / 1e6);
            prob_map.insert("N1".to_string(), (probs[1] * 1e6).round() / 1e6);
            prob_map.insert("N2".to_string(), (probs[2] * 1e6).round() / 1e6);
            prob_map.insert("N3".to_string(), (probs[3] * 1e6).round() / 1e6);
            prob_map.insert("R".to_string(), (probs[4] * 1e6).round() / 1e6);

            stages.push(stage_name.clone());
            records.push(ScoringHeroRecord {
                epoch: ep + 1,
                start: ep * 30,
                end: (ep + 1) * 30,
                stage: stage_name,
                digit,
                confidence: (best_p * 1e4).round() / 1e4,
                probabilities: prob_map,
                channels: vec![chan.clone()],
                clean: 1,
                source: base_source_str.to_string(),
            });
        }
    } else {
        base_source_str = "native_tinysleepnet";
        println!("PROGRESS 0.20 Locating ONNX staging model...");
        let model_path = StagingModel::resolve_model(algorithm_arg)?;
        println!("PROGRESS 0.25 Loading model from {:?}", model_path);
        let model = StagingModel::load_from_path(&model_path)?;

        println!("PROGRESS 0.35 Preparing and normalizing 30s epochs at 100 Hz...");
        let epochs = prepare_staging_epochs(&signal, edf.sfreq);
        let n_epochs = epochs.len();
        println!("PROGRESS 0.45 Scoring {} epochs with TinySleepNet...", n_epochs);

        for ep in 0..n_epochs {
            let seq = build_sequence_window(&epochs, ep);
            let (stage_idx, confidence, probs) = model.score_sequence(&seq)?;

            all_probs.push(probs);
            let stage_name = STAGE_LABELS[stage_idx].to_string();
            let digit = STAGE_DIGITS[stage_idx];

            let mut prob_map = HashMap::new();
            prob_map.insert("W".to_string(), (probs[0] * 1e6).round() / 1e6);
            prob_map.insert("N1".to_string(), (probs[1] * 1e6).round() / 1e6);
            prob_map.insert("N2".to_string(), (probs[2] * 1e6).round() / 1e6);
            prob_map.insert("N3".to_string(), (probs[3] * 1e6).round() / 1e6);
            prob_map.insert("R".to_string(), (probs[4] * 1e6).round() / 1e6);

            stages.push(stage_name.clone());
            records.push(ScoringHeroRecord {
                epoch: ep + 1,
                start: ep * 30,
                end: (ep + 1) * 30,
                stage: stage_name,
                digit,
                confidence: (confidence * 1e4).round() / 1e4,
                probabilities: prob_map,
                channels: vec![chan.clone()],
                clean: 1,
                source: base_source_str.to_string(),
            });

            if ep % 100 == 0 || ep == n_epochs - 1 {
                let pct = 0.45 + 0.35 * ((ep + 1) as f64 / n_epochs as f64);
                println!("PROGRESS {:.2} Scored {}/{} epochs", pct, ep + 1, n_epochs);
            }
        }
    }

    let n_epochs = records.len();

    // Optional SleepGPT sequence correction
    if use_sleepgpt && n_epochs >= 5 {
        println!("PROGRESS 0.85 Applying SleepGPT sequence correction...");
        let gpt_path = SleepGptModel::resolve_weights()?;
        let gpt = SleepGptModel::load_from_json(&gpt_path)?;
        let alpha = sleepgpt_alpha.unwrap_or(0.1);
        let ngram = sleepgpt_ngram.unwrap_or(30);

        let corrected_tokens = run_sleepgpt_correction(&gpt, &all_probs, alpha, ngram)?;
        for (ep, &c_tok) in corrected_tokens.iter().enumerate() {
            let stage_name = STAGE_LABELS[c_tok].to_string();
            let digit = STAGE_DIGITS[c_tok];
            records[ep].stage = stage_name.clone();
            records[ep].digit = digit;
            records[ep].source = format!("{}_sleepgpt", base_source_str);
            stages[ep] = stage_name;
        }
        println!("PROGRESS 0.92 SleepGPT correction complete.");
    }

    // Determine output path
    let default_out = edf_path.with_file_name(format!("{}_scoring.json", edf_path.file_stem().unwrap().to_string_lossy()));
    let target_out = out_json_path.unwrap_or(&default_out);

    println!("PROGRESS 0.95 Writing hypnogram to {:?}", target_out);
    let file = File::create(target_out).with_context(|| format!("Creating output scoring file {:?}", target_out))?;
    let writer = BufWriter::new(file);

    // ScoringHero format: [ [records], [annotations] ]
    let empty_annotations: Vec<serde_json::Value> = Vec::new();
    let payload = (&records, &empty_annotations);
    serde_json::to_writer_pretty(writer, &payload)?;

    println!("OUTPUT_SCORING {:?}", target_out);
    println!("PROGRESS 1.00 Done in {:.2}s", start_time.elapsed().as_secs_f64());

    Ok(SleepStagingResult {
        total_epochs: n_epochs,
        output_path: target_out.to_path_buf(),
        stages,
        duration_seconds: start_time.elapsed().as_secs_f64(),
    })
}

/// Applies SleepGPT sequence correction to an existing ScoringHero hypnogram JSON file.
pub fn apply_sleepgpt_to_scoring_file(
    scoring_path: &Path,
    alpha: f64,
    ngram: usize,
    out_json_path: Option<&Path>,
) -> Result<PathBuf> {
    let start_time = Instant::now();
    println!("PROGRESS 0.10 Reading hypnogram from {:?}", scoring_path);
    let file = File::open(scoring_path)
        .with_context(|| format!("Opening scoring file at {:?}", scoring_path))?;
    let mut root: serde_json::Value = serde_json::from_reader(BufReader::new(file))?;

    let epochs = root
        .get_mut(0)
        .and_then(|v| v.as_array_mut())
        .context("Invalid ScoringHero JSON: missing epoch records array")?;
    let total_epochs = epochs.len();
    println!("PROGRESS 0.20 Loaded {} epochs from hypnogram", total_epochs);

    if total_epochs < 5 {
        anyhow::bail!("SleepGPT requires at least 5 epochs, got {}", total_epochs);
    }

    let mut raw_probs = Vec::with_capacity(total_epochs);
    for ep in epochs.iter() {
        let prob_obj = ep.get("probabilities").and_then(|p| p.as_object());
        let mut p_arr = [0.0f64; 5];
        if let Some(obj) = prob_obj {
            let get_p = |keys: &[&str]| -> f64 {
                for &k in keys {
                    if let Some(v) = obj.get(k).and_then(|x| x.as_f64()) {
                        return v;
                    }
                }
                0.0
            };
            p_arr[0] = get_p(&["W", "WAKE", "Wake"]);
            p_arr[1] = get_p(&["N1"]);
            p_arr[2] = get_p(&["N2"]);
            p_arr[3] = get_p(&["N3"]);
            p_arr[4] = get_p(&["R", "REM"]);
        } else {
            // If no probabilities, assign 1.0 to the existing stage
            let cur_stage = ep.get("stage").and_then(|s| s.as_str()).unwrap_or("Wake");
            let idx = match cur_stage {
                "Wake" | "W" => 0,
                "N1" => 1,
                "N2" => 2,
                "N3" => 3,
                "REM" | "R" => 4,
                _ => 0,
            };
            p_arr[idx] = 1.0;
        }
        raw_probs.push(p_arr);
    }

    println!("PROGRESS 0.35 Loading SleepGPT model weights...");
    let gpt_path = SleepGptModel::resolve_weights()?;
    let gpt = SleepGptModel::load_from_json(&gpt_path)?;

    println!("PROGRESS 0.50 Applying SleepGPT sequence correction...");
    let corrected_tokens = run_sleepgpt_correction(&gpt, &raw_probs, alpha, ngram)?;

    for (i, &tok) in corrected_tokens.iter().enumerate() {
        let stage_name = STAGE_LABELS[tok];
        let digit = STAGE_DIGITS[tok];
        if let Some(ep_obj) = epochs[i].as_object_mut() {
            ep_obj.insert("stage".to_string(), serde_json::Value::String(stage_name.to_string()));
            ep_obj.insert("digit".to_string(), serde_json::Value::Number(digit.into()));
            let old_src = ep_obj.get("source").and_then(|s| s.as_str()).unwrap_or("unknown");
            if !old_src.contains("sleepgpt") {
                ep_obj.insert("source".to_string(), serde_json::Value::String(format!("{old_src}_sleepgpt")));
            }
        }
    }

    let default_out = scoring_path.with_file_name(format!(
        "{}_sleepgpt.json",
        scoring_path.file_stem().unwrap().to_string_lossy()
    ));
    let target_out = out_json_path.unwrap_or(&default_out);

    println!("PROGRESS 0.90 Writing updated hypnogram to {:?}", target_out);
    let out_file = File::create(target_out)
        .with_context(|| format!("Creating output file {:?}", target_out))?;
    serde_json::to_writer_pretty(BufWriter::new(out_file), &root)?;

    println!("OUTPUT_SCORING {:?}", target_out);
    println!("PROGRESS 1.00 SleepGPT correction complete in {:.2}s", start_time.elapsed().as_secs_f64());

    Ok(target_out.to_path_buf())
}
