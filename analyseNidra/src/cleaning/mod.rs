pub mod export;
pub mod gedai;
pub mod montage;
pub mod ransac;
pub mod spline;

use anyhow::{Context, Result};
use export::{write_edf_file, write_json_log, PreprocessingLog};
use gedai::{gedai_denoise, GedaiConfig};
use ransac::{detect_bad_channels, interpolate_bad_channels, RansacConfig};
use std::path::{Path, PathBuf};
use std::time::Instant;

use crate::signal::{filter_bandpass_fir, filter_notch, mne_fft_resample};

#[derive(Debug, Clone)]
pub struct PreprocessingPipelineConfig {
    pub steps: Vec<String>,
    pub downsample_freq: Option<f64>,
    pub filter_bandpass: (f64, f64),
    pub notch_freq: Option<f64>,
    pub ransac_corr_thresh: f64,
    pub eeg_channels: Option<Vec<String>>,
    pub suffix: String,
}

impl Default for PreprocessingPipelineConfig {
    fn default() -> Self {
        Self {
            steps: vec![
                "filter".to_string(),
                "badchannel".to_string(),
                "interpolate".to_string(),
                "gedai".to_string(),
                "save".to_string(),
            ],
            downsample_freq: Some(250.0),
            filter_bandpass: (0.5, 40.0),
            notch_freq: Some(50.0),
            ransac_corr_thresh: 0.80,
            eeg_channels: None,
            suffix: "_clean".to_string(),
        }
    }
}

pub struct PreprocessingReport {
    pub output_edf: Option<PathBuf>,
    pub output_log: Option<PathBuf>,
    pub bad_channels: Vec<String>,
    pub duration_seconds: f64,
}

/// Runs the complete native Rust EEG epoch preprocessing pipeline.
pub fn run_preprocessing(
    input_path: &Path,
    out_dir: &Path,
    config: &PreprocessingPipelineConfig,
) -> Result<PreprocessingReport> {
    let start_time = Instant::now();
    println!("PROGRESS 0.10 Loading EDF file: {:?}", input_path);

    let raw_edf = if let Some(ref picks) = config.eeg_channels {
        crate::edf::read_selected(input_path, picks)
            .with_context(|| format!("Reading selected channels from {:?}", input_path))?
    } else {
        crate::edf::read_eeg_channels(input_path)
            .with_context(|| format!("Reading EEG channels from {:?}", input_path))?
    };
    let mut sfreq = raw_edf.sfreq;
    let channel_names = raw_edf.channels;
    let mut signals = raw_edf.data_uv;

    println!(
        "PROGRESS 0.20 Found {} EEG channels. Target steps: {:?}",
        channel_names.len(),
        config.steps
    );

    let mut detected_bads = Vec::new();
    let mut bad_indices = Vec::new();

    for step in &config.steps {
        match step.as_str() {
            "downsample" => {
                if let Some(target_freq) = config.downsample_freq {
                    if sfreq > target_freq {
                        println!("PROGRESS 0.30 Resampling from {} Hz to {} Hz...", sfreq, target_freq);
                        for sig in &mut signals {
                            *sig = mne_fft_resample(sig, sfreq, target_freq);
                        }
                        sfreq = target_freq;
                    }
                }
            }
            "filter" => {
                let (lo, hi) = config.filter_bandpass;
                println!("PROGRESS 0.40 Bandpass filtering ({}-{} Hz)...", lo, hi);
                for sig in &mut signals {
                    *sig = filter_bandpass_fir(sig, sfreq, lo, hi);
                    if let Some(notch) = config.notch_freq {
                        if notch > 0.0 {
                            *sig = filter_notch(sig, sfreq, notch, 2.0);
                        }
                    }
                }
            }
            "badchannel" => {
                println!("PROGRESS 0.60 Detecting bad channels with RANSAC & Flatline check...");
                let ransac_cfg = RansacConfig {
                    corr_threshold: config.ransac_corr_thresh,
                    ..Default::default()
                };
                let result = detect_bad_channels(&channel_names, &signals, sfreq, &ransac_cfg);
                detected_bads = result.bad_channels;
                bad_indices = result.bad_channel_indices;
                println!("  Detected {} bad channel(s): {:?}", detected_bads.len(), detected_bads);
            }
            "interpolate" => {
                if !bad_indices.is_empty() {
                    println!("PROGRESS 0.70 Interpolating bad channels using spherical splines...");
                    interpolate_bad_channels(&channel_names, &mut signals, &bad_indices);
                } else {
                    println!("PROGRESS 0.70 No bad channels to interpolate.");
                }
            }
            "gedai" => {
                println!("PROGRESS 0.80 Running GEDAI artifact removal and Haar MODWT decomposition...");
                let gedai_cfg = GedaiConfig::default();
                signals = gedai_denoise(&channel_names, &signals, sfreq, &gedai_cfg);
            }
            "save" => {
                // Handled below after loop
            }
            other => {
                println!("Warning: Unknown preprocessing step '{}'", other);
            }
        }
    }

    std::fs::create_dir_all(out_dir)?;
    let stem = input_path.file_stem().unwrap_or_default().to_string_lossy();

    let mut out_edf_path = None;
    let mut out_log_path = None;

    if !config.steps.contains(&"no_save".to_string()) {
        println!("PROGRESS 0.90 Saving cleaned EDF and execution log...");
        let edf_name = format!("{}{}.edf", stem, config.suffix);
        let edf_path = out_dir.join(edf_name);
        write_edf_file(&edf_path, &channel_names, &signals, sfreq)?;
        println!("OUTPUT_EDF \"{}\"", edf_path.display());
        out_edf_path = Some(edf_path);

        let log_name = format!("{}{}_log.json", stem, config.suffix);
        let log_path = out_dir.join(log_name);
        let log = PreprocessingLog {
            input_file: input_path.to_string_lossy().to_string(),
            output_file: out_edf_path.as_ref().map(|p| p.to_string_lossy().to_string()).unwrap_or_default(),
            steps_run: config.steps.clone(),
            sample_rate: sfreq,
            original_channels: channel_names,
            bad_channels: detected_bads.clone(),
            duration_seconds: raw_edf.duration_seconds,
            timestamp: {
                let secs = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs();
                format!("epoch-seconds:{}", secs)
            },
        };
        write_json_log(&log_path, &log)?;
        println!("OUTPUT_LOG \"{}\"", log_path.display());
        out_log_path = Some(log_path);
    }

    println!("PROGRESS 1.00 Done in {:.2}s", start_time.elapsed().as_secs_f64());

    Ok(PreprocessingReport {
        output_edf: out_edf_path,
        output_log: out_log_path,
        bad_channels: detected_bads,
        duration_seconds: start_time.elapsed().as_secs_f64(),
    })
}
