use anyhow::{bail, Context, Result};
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
use super::yasa::{extract_yasa_features, YasaClassifier};
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

/// Canonical algorithm keys understood by the native staging engine.
pub const SUPPORTED_ALGORITHMS: [&str; 10] = [
    "tinysleepnet",
    "yasa",
    "usleep",
    "luna",
    "gssc",
    "seqsleepnet",
    "sleeptransformer",
    "dreamento",
    "sleepeegpy",
    "sleepgpt",
];

/// Maps UI / legacy algorithm names onto a canonical key.
pub fn canonical_algorithm(name: &str) -> Result<String> {
    let lower = name.trim().to_lowercase().replace(['-', ' '], "_");
    let lower = lower.trim_end_matches("_sleepgpt").to_string();
    let key = match lower.as_str() {
        "" | "tinysleepnet" | "tinysleepnet_rust" | "tinysleepnet_physioex" | "deepsleepnet_tinysleepnet"
        | "psg" | "psg_model" | "wearable" | "wearable_model" => "tinysleepnet",
        "yasa" | "yasa_lightgbm" => "yasa",
        "dreamento" => "dreamento",
        "sleepeegpy" | "sleep_eeg_py" => "sleepeegpy",
        "usleep" | "u_sleep" => "usleep",
        "luna" | "pops" | "luna_pops" => "luna",
        "gssc" | "greifswald" => "gssc",
        "seqsleepnet" => "seqsleepnet",
        "sleeptransformer" | "sleeptansformer" | "transformer" => "sleeptransformer",
        other => bail!(
            "Unsupported staging algorithm '{other}'. Supported: tinysleepnet, yasa, usleep, luna, gssc, \
             seqsleepnet, sleeptransformer, dreamento, sleepeegpy"
        ),
    };
    Ok(key.to_string())
}

/// Options for [`score_recording`].
#[derive(Debug, Clone, Default)]
pub struct StageOptions {
    pub algorithm: String,
    pub sequence_correction: String,
    pub eeg: Vec<String>,
    pub refs: Vec<String>,
    pub eog: Vec<String>,
    pub emg: Vec<String>,
    pub out_json: Option<PathBuf>,
    pub out_dir: Option<PathBuf>,
    pub sleepgpt_alpha: Option<f64>,
    pub sleepgpt_ngram: Option<usize>,
}

/// Loose channel "root" (e.g. `EEG C4-A1` -> `C4`).
fn channel_root(label: &str) -> String {
    let key = crate::edf::channel_match_key(label);
    key.split(['-', '_']).next().unwrap_or("").to_string()
}

fn referenced_suffix(label: &str) -> Option<String> {
    let key = crate::edf::channel_match_key(label);
    let (_, suffix) = key.rsplit_once('-')?;
    Some(suffix.to_string())
}

/// True for derivations that already carry a mastoid reference (`C4-M1`, `C4:A1`).
pub fn is_prereferenced_channel(label: &str) -> bool {
    matches!(referenced_suffix(label).as_deref(), Some("M1" | "M2"))
}

/// AASM-style contralateral mastoid choice (C4 -> M1, C3 -> M2, midline -> M1).
pub fn clinical_reference_for(eeg: &str, refs: &[String]) -> Option<String> {
    if refs.is_empty() || is_prereferenced_channel(eeg) {
        return None;
    }
    let root = channel_root(eeg);
    let contralateral = if root.ends_with(['2', '4', '6', '8', 'Z']) || root.ends_with("10") {
        "M1"
    } else {
        "M2"
    };
    let order = [contralateral, if contralateral == "M1" { "M2" } else { "M1" }];
    for target in order {
        if let Some(r) = refs.iter().find(|r| channel_root(r) == target) {
            return Some(r.clone());
        }
    }
    refs.first().cloned()
}

fn is_eeg_like(label: &str) -> bool {
    let root = channel_root(label);
    let bytes = root.as_bytes();
    let prefixes = ["FP", "AF", "FT", "FC", "TP", "CP", "PO", "F", "T", "C", "P", "O"];
    for p in prefixes {
        if let Some(rest) = root.strip_prefix(p) {
            if rest == "Z" || (!rest.is_empty() && rest.chars().all(|c| c.is_ascii_digit()) && rest.len() <= 2) {
                return true;
            }
        }
    }
    bytes.starts_with(b"EEG")
}

/// Channel labels in the recording (EDF or BrainVision).
fn recording_labels(path: &Path) -> Vec<String> {
    crate::edf::read_signal_infos(path)
        .map(|infos| infos.into_iter().map(|i| i.label).collect())
        .unwrap_or_default()
}

/// Picks a default staging derivation when the caller did not choose one.
fn default_eeg_channels(labels: &[String]) -> Vec<String> {
    for wanted in ["C4", "C3", "F4", "F3", "CZ", "O2", "O1"] {
        // Prefer an already-referenced derivation for the wanted electrode.
        if let Some(l) = labels
            .iter()
            .find(|l| channel_root(l) == wanted && is_prereferenced_channel(l))
        {
            return vec![l.clone()];
        }
        if let Some(l) = labels.iter().find(|l| channel_root(l) == wanted) {
            return vec![l.clone()];
        }
    }
    labels
        .iter()
        .find(|l| is_eeg_like(l))
        .map(|l| vec![l.clone()])
        .unwrap_or_default()
}

fn default_refs(labels: &[String]) -> Vec<String> {
    labels
        .iter()
        .filter(|l| matches!(channel_root(l).as_str(), "M1" | "M2" | "A1" | "A2") && !l.contains(['-', ':']))
        .cloned()
        .collect()
}

/// A loaded single-channel derivation ready for staging.
struct Montage {
    name: String,
    signal: Vec<f64>,
    sfreq: f64,
}

fn load_derivation(path: &Path, anode: &str, cathode: Option<&str>) -> Result<Montage> {
    let mut wanted = vec![anode.to_string()];
    if let Some(c) = cathode {
        wanted.push(c.to_string());
    }
    let data = read_selected(path, &wanted)?;
    let mut signal = data.data_uv[0].clone();
    if data.data_uv.len() > 1 {
        for (s, r) in signal.iter_mut().zip(data.data_uv[1].iter()) {
            *s -= *r;
        }
    }
    let name = match cathode {
        Some(c) => format!("{anode}-{c}"),
        None => anode.to_string(),
    };
    Ok(Montage {
        name,
        signal,
        sfreq: data.sfreq,
    })
}

fn resample_to(signal: Vec<f64>, from: f64, to: f64) -> Vec<f64> {
    if (from - to).abs() < 1e-6 {
        signal
    } else {
        crate::signal::mne_fft_resample(&signal, from, to)
    }
}

/// Loads an EOG trace: the user's selection (bipolar when two are given) or an
/// automatically discovered LOC/ROC (E1/E2) pair.
fn load_eog(path: &Path, eog: &[String], labels: &[String]) -> Option<Montage> {
    if eog.len() >= 2 {
        if let Ok(m) = load_derivation(path, &eog[0], Some(&eog[1])) {
            return Some(m);
        }
    }
    if let Some(first) = eog.first() {
        if let Ok(m) = load_derivation(path, first, None) {
            return Some(m);
        }
    }
    if !eog.is_empty() {
        return None;
    }
    // Automatic discovery.
    let find = |cands: &[&str]| -> Option<String> {
        cands.iter().find_map(|c| {
            let key = crate::edf::channel_match_key(c);
            labels.iter().find(|l| crate::edf::channel_match_key(l) == key).cloned()
        })
    };
    let left = find(&["E1-M2", "LOC-M2", "LOC-A2", "E1:M2", "EOG LOC-A2", "E1", "LOC", "LOC1", "EOG-L", "EOGL", "EOG L"]);
    let right = find(&["E2-M1", "ROC-M1", "ROC-A1", "E2:M1", "E2-M2", "ROC-A2", "E2", "ROC", "ROC1", "EOG-R", "EOGR", "EOG R"]);
    match (left, right) {
        (Some(l), Some(r)) => {
            // Two referenced EOGs: use L-R; otherwise the left EOG alone.
            if is_prereferenced_channel(&l) && is_prereferenced_channel(&r) {
                load_derivation(path, &l, None).ok()
            } else {
                load_derivation(path, &l, Some(&r)).ok()
            }
        }
        (Some(l), None) => load_derivation(path, &l, None).ok(),
        (None, Some(r)) => load_derivation(path, &r, None).ok(),
        _ => labels
            .iter()
            .find(|l| l.to_ascii_uppercase().contains("EOG"))
            .and_then(|l| load_derivation(path, l, None).ok()),
    }
}

fn load_emg(path: &Path, emg: &[String]) -> Option<Montage> {
    if emg.len() >= 2 {
        if let Ok(m) = load_derivation(path, &emg[0], Some(&emg[1])) {
            return Some(m);
        }
    }
    emg.first().and_then(|e| load_derivation(path, e, None).ok())
}

/// Kept for backwards compatibility with callers that only need an EOG trace.
pub fn try_find_eog_signal(edf_path: &Path) -> Option<Vec<f64>> {
    let labels = recording_labels(edf_path);
    load_eog(edf_path, &[], &labels).map(|m| m.signal)
}

fn argmax5(p: &[f64; 5]) -> usize {
    let mut best = 0;
    for i in 1..5 {
        if p[i] > p[best] {
            best = i;
        }
    }
    best
}

fn prob_map(probs: &[f64; 5]) -> HashMap<String, f64> {
    let mut m = HashMap::new();
    for (k, v) in ["W", "N1", "N2", "N3", "R"].iter().zip(probs.iter()) {
        m.insert((*k).to_string(), (v * 1e6).round() / 1e6);
    }
    m
}

/// Runs one algorithm on one derivation and returns per-epoch probabilities
/// in [W, N1, N2, N3, R] order.
fn score_montage(
    algo: &str,
    eeg: &Montage,
    eog: Option<&[f64]>,
    emg: Option<&[f64]>,
    progress: &(dyn Fn(f64, &str) + Sync),
) -> Result<Vec<[f64; 5]>> {
    match algo {
        "yasa" | "dreamento" | "sleepeegpy" => {
            let model_name = match (eog.is_some(), emg.is_some()) {
                (true, true) => "clf_eeg+eog+emg_lgb_0.5.0",
                (true, false) => "clf_eeg+eog_lgb_0.5.0",
                (false, true) => "clf_eeg+emg_lgb_0.5.0",
                (false, false) => "clf_eeg_lgb_0.5.0",
            };
            progress(0.0, &format!("Loading YASA classifier {model_name}"));
            let clf = YasaClassifier::load_from_json(&YasaClassifier::resolve_model(model_name)?)?;
            progress(0.2, "Extracting YASA features");
            let feats = extract_yasa_features(&eeg.signal, eog, emg, eeg.sfreq, &clf);
            progress(0.8, &format!("Scoring {} epochs with LightGBM", feats.len()));
            use rayon::prelude::*;
            Ok(feats.par_iter().map(|row| clf.predict_standard_5class(row)).collect())
        }
        "usleep" => {
            progress(0.0, "Loading U-Sleep model");
            let model = USleepModel::load_from_path(&USleepModel::resolve_model(None)?)?;
            progress(0.2, "Running U-Sleep");
            score_usleep_recording(&eeg.signal, eog, eeg.sfreq, &model)
        }
        "seqsleepnet" | "sleeptransformer" => {
            progress(0.0, &format!("Loading {algo} model"));
            let model = PhysioExModel::load_from_path(&PhysioExModel::resolve_model(algo)?, algo)?;
            progress(0.2, &format!("Running {algo}"));
            score_physioex_channel(&eeg.signal, eeg.sfreq, &model)
        }
        "gssc" => {
            progress(0.0, "Locating GSSC models");
            let model = GsscModel::resolve_models()?;
            progress(0.2, "Running GSSC");
            score_gssc_recording(&eeg.signal, eog, eeg.sfreq, &model)
        }
        "luna" => {
            progress(0.0, "Loading Luna POPS model");
            let model = super::pops::PopsModel::load_default()?;
            progress(0.2, "Computing POPS features");
            super::pops::score_pops_channel(&eeg.signal, eeg.sfreq, &model)
        }
        _ => {
            progress(0.0, "Loading TinySleepNet model");
            let model = StagingModel::load_from_path(&StagingModel::resolve_model(None)?)?;
            let epochs = prepare_staging_epochs(&eeg.signal, eeg.sfreq);
            let n = epochs.len();
            progress(0.2, &format!("Scoring {n} epochs with TinySleepNet"));
            use rayon::prelude::*;
            let done = std::sync::atomic::AtomicUsize::new(0);
            (0..n)
                .into_par_iter()
                .map(|ep| {
                    let seq = build_sequence_window(&epochs, ep);
                    let (_, _, probs) = model.score_sequence(&seq)?;
                    let k = done.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
                    if k % 200 == 0 {
                        progress(0.2 + 0.8 * k as f64 / n.max(1) as f64, &format!("Scored {k}/{n} epochs"));
                    }
                    Ok(probs)
                })
                .collect()
        }
    }
}

fn algorithm_label(algo: &str) -> &'static str {
    match algo {
        "yasa" => "YASA",
        "dreamento" => "Dreamento (YASA)",
        "sleepeegpy" => "SleepEEGpy (YASA)",
        "usleep" => "U-Sleep",
        "seqsleepnet" => "SeqSleepNet",
        "sleeptransformer" => "SleepTransformer",
        "gssc" => "GSSC",
        "luna" => "Luna POPS",
        _ => "TinySleepNet",
    }
}

/// Automatically scores a recording with any native algorithm. Every selected
/// EEG channel is staged on its own (re-referenced to the contralateral
/// mastoid when references are given) and the per-montage probabilities are
/// averaged into a consensus, matching the retired Python backend.
pub fn score_recording(edf_path: &Path, opts: &StageOptions) -> Result<SleepStagingResult> {
    let start_time = Instant::now();
    let algo = canonical_algorithm(&opts.algorithm)?;
    let seq_corr = opts.sequence_correction.trim().to_lowercase();
    let use_sleepgpt = seq_corr == "sleepgpt" || opts.algorithm.to_lowercase().ends_with("_sleepgpt");
    let label = algorithm_label(&algo);
    println!("Native {label} engine launched ({}).", edf_path.display());

    let labels = recording_labels(edf_path);
    let mut eeg_list: Vec<String> = opts.eeg.iter().filter(|s| !s.trim().is_empty()).cloned().collect();
    let mut refs: Vec<String> = opts.refs.iter().filter(|s| !s.trim().is_empty()).cloned().collect();
    if eeg_list.is_empty() {
        eeg_list = default_eeg_channels(&labels);
        if refs.is_empty() {
            refs = default_refs(&labels);
        }
        if eeg_list.is_empty() {
            bail!("No EEG channel selected and none could be detected automatically.");
        }
        println!("  Auto-selected EEG channel(s): {}", eeg_list.join(", "));
    }

    println!("PROGRESS 0.05 Loading EEG derivations");
    let mut montages: Vec<Montage> = Vec::new();
    for eeg in &eeg_list {
        let reference = clinical_reference_for(eeg, &refs);
        match load_derivation(edf_path, eeg, reference.as_deref()) {
            Ok(m) => {
                println!("  Loaded {} @ {} Hz", m.name, m.sfreq);
                montages.push(m);
            }
            Err(err) => println!("  Skipping {eeg}: {err}"),
        }
    }
    if montages.is_empty() {
        bail!(
            "Could not load any of the selected EEG channel(s) {:?} from {}",
            eeg_list,
            edf_path.display()
        );
    }

    let needs_eog = matches!(algo.as_str(), "yasa" | "dreamento" | "sleepeegpy" | "usleep" | "gssc");
    let eog = if needs_eog { load_eog(edf_path, &opts.eog, &labels) } else { None };
    if let Some(e) = &eog {
        println!("  Using EOG {} @ {} Hz", e.name, e.sfreq);
    }
    let emg = if matches!(algo.as_str(), "yasa" | "dreamento" | "sleepeegpy") {
        load_emg(edf_path, &opts.emg)
    } else {
        None
    };
    if let Some(e) = &emg {
        println!("  Using EMG {} @ {} Hz", e.name, e.sfreq);
    }

    let n_montages = montages.len();
    let mut per_montage: Vec<(String, Vec<[f64; 5]>)> = Vec::new();
    for (mi, montage) in montages.iter().enumerate() {
        let base = 0.10 + 0.75 * mi as f64 / n_montages as f64;
        let span = 0.75 / n_montages as f64;
        let name = montage.name.clone();
        let progress = |frac: f64, msg: &str| {
            println!(
                "PROGRESS {:.3} [{}/{}] {} {}: {}",
                base + span * frac.clamp(0.0, 1.0),
                mi + 1,
                n_montages,
                label,
                name,
                msg
            );
        };
        let eog_sig = eog
            .as_ref()
            .map(|e| resample_to(e.signal.clone(), e.sfreq, montage.sfreq));
        let emg_sig = emg.as_ref().map(|e| {
            // EMG is high-passed at 10 Hz before YASA (as in the Python backend).
            let hi = (e.sfreq / 2.0 - 1.0).min(100.0);
            let filtered = if hi > 12.0 {
                crate::signal::filter_bandpass_fir(&e.signal, e.sfreq, 10.0, hi)
            } else {
                e.signal.clone()
            };
            resample_to(filtered, e.sfreq, montage.sfreq)
        });
        match score_montage(&algo, montage, eog_sig.as_deref(), emg_sig.as_deref(), &progress) {
            Ok(p) if !p.is_empty() => per_montage.push((montage.name.clone(), p)),
            Ok(_) => println!("  {label} returned no epochs for {}", montage.name),
            Err(err) => {
                // Missing models are fatal; per-channel data problems are not.
                let msg = format!("{err:#}");
                if msg.contains("not found") {
                    return Err(err);
                }
                println!("  {label} failed for {}: {msg}", montage.name);
            }
        }
    }
    if per_montage.is_empty() {
        bail!("{label} failed on every selected EEG channel.");
    }

    let n_epochs = per_montage.iter().map(|(_, p)| p.len()).min().unwrap_or(0);
    let montage_names: Vec<String> = per_montage.iter().map(|(n, _)| n.clone()).collect();
    let mut all_probs: Vec<[f64; 5]> = vec![[0.0; 5]; n_epochs];
    for (_, probs) in &per_montage {
        for (ep, p) in probs.iter().take(n_epochs).enumerate() {
            for k in 0..5 {
                all_probs[ep][k] += p[k] / per_montage.len() as f64;
            }
        }
    }
    println!(
        "Base scorer complete: {label} produced {n_epochs} epochs from {} montage(s).",
        per_montage.len()
    );

    let source = format!("native_{algo}");
    let mut records = Vec::with_capacity(n_epochs);
    let mut stages = Vec::with_capacity(n_epochs);
    for (ep, probs) in all_probs.iter().enumerate() {
        let best = argmax5(probs);
        stages.push(STAGE_LABELS[best].to_string());
        records.push(ScoringHeroRecord {
            epoch: ep + 1,
            start: ep * 30,
            end: (ep + 1) * 30,
            stage: STAGE_LABELS[best].to_string(),
            digit: STAGE_DIGITS[best],
            confidence: (probs[best] * 1e4).round() / 1e4,
            probabilities: prob_map(probs),
            channels: montage_names.clone(),
            clean: 1,
            source: source.clone(),
        });
    }

    let mut postfix = algo.clone();
    if use_sleepgpt && n_epochs >= 5 {
        println!("PROGRESS 0.87 Applying SleepGPT sequence correction...");
        let gpt = SleepGptModel::load_from_json(&SleepGptModel::resolve_weights()?)?;
        let corrected = run_sleepgpt_correction(
            &gpt,
            &all_probs,
            opts.sleepgpt_alpha.unwrap_or(0.1),
            opts.sleepgpt_ngram.unwrap_or(30),
        )?;
        for (ep, &tok) in corrected.iter().enumerate().take(n_epochs) {
            records[ep].stage = STAGE_LABELS[tok].to_string();
            records[ep].digit = STAGE_DIGITS[tok];
            records[ep].source = format!("{source}_sleepgpt");
            stages[ep] = STAGE_LABELS[tok].to_string();
        }
        postfix.push_str("_sleepgpt");
        println!("PROGRESS 0.93 SleepGPT correction complete.");
    }

    // Never write the bare `<stem>_scoring.json`: that is the manual scoring
    // file the viewer auto-saves, so autoscoring would silently overwrite it.
    let stem = edf_path
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "recording".into());
    let file_name = format!("{stem}_{postfix}_scoring.json");
    let target_out = match (&opts.out_json, &opts.out_dir) {
        (Some(p), _) => p.clone(),
        (None, Some(dir)) => {
            std::fs::create_dir_all(dir).ok();
            dir.join(&file_name)
        }
        (None, None) => edf_path.with_file_name(&file_name),
    };

    println!("PROGRESS 0.96 Writing hypnogram to {}", target_out.display());
    let file = File::create(&target_out)
        .with_context(|| format!("Creating output scoring file {}", target_out.display()))?;
    let empty_annotations: Vec<serde_json::Value> = Vec::new();
    serde_json::to_writer_pretty(BufWriter::new(file), &(&records, &empty_annotations))?;

    println!("Saved ScoringHero JSON: {}", target_out.display());
    println!("OUTPUT_SCORING {}", target_out.display());
    println!("PROGRESS 1.00 Done in {:.2}s", start_time.elapsed().as_secs_f64());

    Ok(SleepStagingResult {
        total_epochs: n_epochs,
        output_path: target_out,
        stages,
        duration_seconds: start_time.elapsed().as_secs_f64(),
    })
}

/// Backwards-compatible single-derivation entry point.
#[allow(clippy::too_many_arguments)]
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
    let split = |s: Option<&str>| -> Vec<String> {
        s.map(|v| v.split(',').map(|x| x.trim().to_string()).filter(|x| !x.is_empty()).collect())
            .unwrap_or_default()
    };
    score_recording(
        edf_path,
        &StageOptions {
            algorithm: algorithm_arg.unwrap_or("tinysleepnet").to_string(),
            sequence_correction: sequence_correction_arg.unwrap_or("none").to_string(),
            eeg: split(preferred_channel),
            refs: split(preferred_ref),
            out_json: out_json_path.map(Path::to_path_buf),
            sleepgpt_alpha,
            sleepgpt_ngram,
            ..Default::default()
        },
    )
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

    println!("Saved ScoringHero JSON: {}", target_out.display());
    println!("OUTPUT_SCORING {}", target_out.display());
    println!("PROGRESS 1.00 SleepGPT correction complete in {:.2}s", start_time.elapsed().as_secs_f64());

    Ok(target_out.to_path_buf())
}
