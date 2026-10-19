use crate::edf::{EdfData, read_available};
use crate::config::FeatureConfig;
use crate::features::{acw50, bandpowers_with_bands};
use crate::hypnogram::{
    ArchitectureWindow, SleepArchitecture, Stage, read_sleepgpt,
    sleep_architecture_with_epoch_sec, upsample_with_epoch_sec,
};
use crate::nonlinear;
use crate::signal::{preprocess_mne_250hz, rereference, resample_channels_mne};
use crate::spectral::{fooof_features_with_bands, irasa_features_with_bands};
use anyhow::Result;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::Path;

#[derive(Debug)]
pub struct LoadedRecording {
    pub edf: EdfData,
    pub stages: Vec<Stage>,
    pub sample_stages: Vec<i8>,
    pub architecture: SleepArchitecture,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CoreStageFeatures {
    pub channels: BTreeMap<String, BTreeMap<String, f64>>,
}

pub fn load(
    edf_path: &Path,
    scoring_path: &Path,
    channels: &[String],
    references: &[String],
    lights_off_seconds: Option<f64>,
    lights_on_seconds: Option<f64>,
) -> Result<LoadedRecording> {
    load_with_epoch(
        edf_path,
        scoring_path,
        channels,
        references,
        lights_off_seconds,
        lights_on_seconds,
        30.0,
    )
}

pub fn load_with_epoch(
    edf_path: &Path,
    scoring_path: &Path,
    channels: &[String],
    references: &[String],
    lights_off_seconds: Option<f64>,
    lights_on_seconds: Option<f64>,
    epoch_length_sec: f64,
) -> Result<LoadedRecording> {
    let mut requested = channels.to_vec();
    for reference in references {
        if !requested
            .iter()
            .any(|channel| channel.eq_ignore_ascii_case(reference))
        {
            requested.push(reference.clone());
        }
    }
    let mut edf = if requested.is_empty() {
        crate::edf::read_eeg_channels(edf_path)?
    } else {
        match read_available(edf_path, &requested) {
            Ok(data) => data,
            Err(e) => {
                match crate::edf::read_eeg_channels(edf_path) {
                    Ok(data) => {
                        eprintln!("Warning: none of requested channels found; loading auto-detected EEG channels for timing/architecture: {}", e);
                        data
                    }
                    Err(_) => {
                        let labels = crate::edf::read_channel_labels(edf_path).unwrap_or_default();
                        if !labels.is_empty() {
                            eprintln!("Warning: none of requested channels found; loading {} for timing/architecture: {}", labels[0], e);
                            read_available(edf_path, &[labels[0].clone()])?
                        } else {
                            return Err(e);
                        }
                    }
                }
            }
        }
    };
    if (edf.sfreq - crate::TARGET_SFREQ).abs() >= 1e-9 {
        let source_rate = edf.sfreq;
        resample_channels_mne(&mut edf.data_uv, source_rate, crate::TARGET_SFREQ);
        edf.sfreq = crate::TARGET_SFREQ;
    }
    let stages = read_sleepgpt(scoring_path)?;
    let n_samples = if !edf.data_uv.is_empty() {
        edf.data_uv[0].len()
    } else {
        (edf.duration_seconds * edf.sfreq).round() as usize
    };
    let sample_stages = upsample_with_epoch_sec(&stages, edf.sfreq, n_samples, epoch_length_sec);
    let window = ArchitectureWindow::from_seconds(
        edf.duration_seconds,
        lights_off_seconds,
        lights_on_seconds,
    );
    let mut architecture = sleep_architecture_with_epoch_sec(&stages, window, epoch_length_sec);
    if let Some(stage_analysis) = crate::accs::analyse(&stages) {
        // Un-prefixed ACCS names (N1_duration, N2_percentage, ...) must not
        // overwrite the standard architecture values of the same name.
        for (key, value) in crate::accs::flatten(&stage_analysis) {
            architecture.values.entry(key).or_insert(value);
        }
    }
    if !references.is_empty() {
        let reference_indices: Vec<usize> = references
            .iter()
            .filter_map(|reference| {
                edf.channels
                    .iter()
                    .position(|channel| channel.eq_ignore_ascii_case(reference))
            })
            .collect();
        if !reference_indices.is_empty() {
            rereference(&mut edf.data_uv, &reference_indices);
        }
    }
    if !crate::edf::is_already_mne_filtered(edf_path) && !edf.data_uv.is_empty() {
        preprocess_mne_250hz(&mut edf.data_uv);
    }
    let mut selected_data: Vec<Vec<f64>> = Vec::with_capacity(channels.len());
    let mut loaded_channels: Vec<String> = Vec::with_capacity(channels.len());
    for channel in channels {
        let ch_key = crate::edf::channel_match_key(channel);
        let ch_root = ch_key.split('-').next().unwrap_or(&ch_key);
        if let Some(index) = edf.channels.iter().position(|loaded| {
            if loaded.eq_ignore_ascii_case(channel) {
                return true;
            }
            let loaded_key = crate::edf::channel_match_key(loaded);
            if loaded_key == ch_key {
                return true;
            }
            let loaded_root = loaded_key.split('-').next().unwrap_or(&loaded_key);
            !ch_root.is_empty() && loaded_root == ch_root
        }) {
            if !loaded_channels.iter().any(|c| c.eq_ignore_ascii_case(channel)) {
                selected_data.push(std::mem::take(&mut edf.data_uv[index]));
                loaded_channels.push(channel.clone());
            }
        }
    }
    if !selected_data.is_empty() {
        edf.channels = loaded_channels;
        edf.data_uv = selected_data;
    }
    Ok(LoadedRecording {
        edf,
        stages,
        sample_stages,
        architecture,
    })
}

fn average_feature_maps(rows: &[BTreeMap<String, f64>]) -> BTreeMap<String, f64> {
    if rows.is_empty() {
        return BTreeMap::new();
    }
    rows[0]
        .keys()
        .map(|name| {
            let values: Vec<f64> = rows
                .iter()
                .filter_map(|row| row.get(name).copied())
                .filter(|value| !value.is_nan())
                .collect();
            let average = if values.is_empty() {
                f64::NAN
            } else {
                values.iter().sum::<f64>() / values.len() as f64
            };
            (name.clone(), average)
        })
        .collect()
}

pub fn compute_core_stage_features(recording: &LoadedRecording) -> CoreStageFeatures {
    compute_core_stage_features_with_config(recording, &FeatureConfig::default())
}

pub fn compute_core_stage_features_with_config(
    recording: &LoadedRecording,
    config: &FeatureConfig,
) -> CoreStageFeatures {
    let window_samples = (config.feature_window_sec * recording.edf.sfreq).round() as usize;
    let stages = [("W", 0_i8), ("N1", 1_i8), ("N2", 2_i8), ("N3", 3_i8), ("REM", 4_i8)];
    let channel_results: Vec<(String, BTreeMap<String, f64>)> = recording
        .edf
        .channels
        .par_iter()
        .zip(recording.edf.data_uv.par_iter())
        .map(|(channel_name, channel)| {
            let mut output = BTreeMap::new();
            for (stage_name, stage_code) in stages {
                let stage_data: Vec<f64> = channel
                    .iter()
                    .zip(&recording.sample_stages)
                    .filter_map(|(&value, &stage)| (stage == stage_code).then_some(value))
                    .collect();
                let rows: Vec<BTreeMap<String, f64>> = stage_data
                    .par_chunks_exact(window_samples)
                    .map(|window| {
                        let mut row = bandpowers_with_bands(window, recording.edf.sfreq, &config.bands);
                        row.insert("ACW".into(), acw50(window, recording.edf.sfreq));
                        row.extend(
                            nonlinear::all(window)
                                .into_iter()
                                .map(|(name, value)| (name.to_string(), value)),
                        );
                        row.extend(fooof_features_with_bands(window, recording.edf.sfreq, &config.bands));
                        row.extend(irasa_features_with_bands(window, recording.edf.sfreq, &config.bands));
                        row
                    })
                    .collect();
                for (name, value) in average_feature_maps(&rows) {
                    output.insert(format!("{stage_name}_{name}"), value);
                }
            }
            (channel_name.clone(), output)
        })
        .collect();
    CoreStageFeatures {
        channels: channel_results.into_iter().collect(),
    }
}
