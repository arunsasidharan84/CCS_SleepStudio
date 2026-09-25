use crate::edf::{EdfData, read_selected};
use crate::features::{acw50, bandpowers};
use crate::hypnogram::{
    ArchitectureWindow, SleepArchitecture, Stage, read_sleepgpt, sleep_architecture, upsample,
};
use crate::nonlinear;
use crate::signal::{preprocess_mne_250hz, rereference, resample_channels_mne};
use crate::spectral::{fooof_features, irasa_features};
use anyhow::{Context, Result, bail};
use rayon::prelude::*;
use serde::Serialize;
use std::collections::BTreeMap;
use std::path::Path;

#[derive(Debug)]
pub struct LoadedRecording {
    pub edf: EdfData,
    pub stages: Vec<Stage>,
    pub sample_stages: Vec<i8>,
    pub architecture: SleepArchitecture,
}

#[derive(Debug, Serialize)]
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
    if channels.is_empty() {
        bail!("at least one EEG channel is required");
    }
    let mut requested = channels.to_vec();
    for reference in references {
        if !requested
            .iter()
            .any(|channel| channel.eq_ignore_ascii_case(reference))
        {
            requested.push(reference.clone());
        }
    }
    let mut edf = read_selected(edf_path, &requested)?;
    if (edf.sfreq - crate::TARGET_SFREQ).abs() >= 1e-9 {
        let source_rate = edf.sfreq;
        resample_channels_mne(&mut edf.data_uv, source_rate, crate::TARGET_SFREQ);
        edf.sfreq = crate::TARGET_SFREQ;
    }
    let stages = read_sleepgpt(scoring_path)?;
    let sample_stages = upsample(&stages, edf.sfreq, edf.data_uv[0].len());
    let window = ArchitectureWindow::from_seconds(
        edf.duration_seconds,
        lights_off_seconds,
        lights_on_seconds,
    );
    let mut architecture = sleep_architecture(&stages, window);
    if let Some(stage_analysis) = crate::accs::analyse(&stages) {
        // Un-prefixed ACCS names (N1_duration, N2_percentage, ...) must not
        // overwrite the standard architecture values of the same name.
        for (key, value) in crate::accs::flatten(&stage_analysis) {
            architecture.values.entry(key).or_insert(value);
        }
    }
    if !references.is_empty() {
        let reference_indices = references
            .iter()
            .map(|reference| {
                edf.channels
                    .iter()
                    .position(|channel| channel.eq_ignore_ascii_case(reference))
                    .with_context(|| format!("reference channel {reference} was not loaded"))
            })
            .collect::<Result<Vec<_>>>()?;
        rereference(&mut edf.data_uv, &reference_indices);
    }
    preprocess_mne_250hz(&mut edf.data_uv);
    let mut selected_data = Vec::with_capacity(channels.len());
    for channel in channels {
        let index = edf
            .channels
            .iter()
            .position(|loaded| loaded.eq_ignore_ascii_case(channel))
            .with_context(|| format!("EEG channel {channel} was not loaded"))?;
        selected_data.push(std::mem::take(&mut edf.data_uv[index]));
    }
    edf.channels = channels.to_vec();
    edf.data_uv = selected_data;
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
    let window_samples = (15.0 * recording.edf.sfreq).round() as usize;
    let stages = [("N1", 1_i8), ("N2", 2_i8), ("N3", 3_i8), ("REM", 4_i8)];
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
                        let mut row = bandpowers(window, recording.edf.sfreq);
                        row.insert("ACW".into(), acw50(window, recording.edf.sfreq));
                        row.extend(
                            nonlinear::all(window)
                                .into_iter()
                                .map(|(name, value)| (name.to_string(), value)),
                        );
                        row.extend(fooof_features(window, recording.edf.sfreq));
                        row.extend(irasa_features(window, recording.edf.sfreq));
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
