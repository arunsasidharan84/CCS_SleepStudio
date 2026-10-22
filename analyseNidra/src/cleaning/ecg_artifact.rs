//! ECG (Cardiac / Ballistocardiogram) artefact removal via QRS template subtraction.
//!
//! Cardiac activity (QRS complexes) frequently volume-conducts into EEG electrodes
//! (particularly A1/A2/M1/M2 references, frontopolar, or temporal derivations), producing
//! rhythmic spike-like deflections synchronous with heartbeats (~40–80 µV peak-to-peak).
//!
//! Because clinical PSG recordings typically have 6 EEG channels, ICA is underconstrained and
//! cannot reliably isolate cardiac components without corrupting background delta or spindles.
//! QRS-synchronous template subtraction operates on individual channels without requiring high
//! channel counts:
//! 1. Identifies the ECG channel (ECG I, ECG II, EKG, etc.).
//! 2. Detects R-peaks with high temporal precision using a bandpassed QRS energy detector with
//!    adaptive thresholding and physiological refractory period.
//! 3. Aligns each R-peak to the local maximum deflection.
//! 4. Extracts beat-synchronous windows [-100 ms, +300 ms] across the recording for each EEG channel.
//! 5. Calculates a robust median cardiac template across beats (resistant to background EEG transients).
//! 6. Scales the template per beat and subtracts it, cleanly eliminating cardiac spikes while
//!    preserving sleep EEG oscillations (spindles, slow waves, vertex sharp waves).

use anyhow::{bail, Context, Result};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

use crate::psg::common::butter_filtfilt;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EcgArtifactConfig {
    /// ECG channel name (if None, auto-detected from recording channels).
    pub ecg_channel: Option<String>,
    /// Minimum refractory period between R-peaks in seconds (default: 0.35 s = 171 bpm max HR).
    pub min_r_distance_sec: f64,
    /// Pre-R-peak window in seconds (default: 0.10 s = 100 ms).
    pub pre_r_sec: f64,
    /// Post-R-peak window in seconds (default: 0.30 s = 300 ms).
    pub post_r_sec: f64,
    /// Minimum absolute correlation with ECG to trigger cleaning for an EEG channel (default: 0.05).
    pub min_artifact_corr: f64,
}

impl Default for EcgArtifactConfig {
    fn default() -> Self {
        Self {
            ecg_channel: None,
            min_r_distance_sec: 0.35,
            pre_r_sec: 0.10,
            post_r_sec: 0.30,
            min_artifact_corr: 0.05,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EcgChannelReduction {
    pub channel: String,
    pub corr_before: f64,
    pub corr_after: f64,
    pub reduction_pct: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EcgArtifactReport {
    pub ecg_channel: String,
    pub total_r_peaks: usize,
    pub heart_rate_bpm: f64,
    pub cleaned_channels: Vec<EcgChannelReduction>,
}

/// Detects R-peak sample indices in an ECG trace.
pub fn detect_r_peaks(ecg: &[f64], fs: f64, min_dist_sec: f64) -> Vec<usize> {
    if ecg.is_empty() || fs <= 10.0 {
        return Vec::new();
    }
    let n = ecg.len();

    // 1. Bandpass filter 5–30 Hz to isolate QRS energy
    let hi = (fs / 2.0 - 1.0).min(30.0);
    let filtered = if hi > 5.0 {
        butter_filtfilt(ecg, fs, Some(5.0), Some(hi))
    } else {
        ecg.to_vec()
    };

    // 2. Squared derivative
    let mut energy = vec![0.0; n];
    for i in 1..n {
        let diff = filtered[i] - filtered[i - 1];
        energy[i] = diff * diff;
    }

    // 3. Moving average smoothing (approx 100 ms)
    let win = (0.10 * fs).round().max(3.0) as usize;
    let mut smoothed = vec![0.0; n];
    let mut run_sum = 0.0;
    for i in 0..n {
        run_sum += energy[i];
        if i >= win {
            run_sum -= energy[i - win];
            smoothed[i - win / 2] = run_sum / win as f64;
        }
    }

    // 4. Thresholding: mean + 1.2 * std
    let mean: f64 = smoothed.iter().sum::<f64>() / n as f64;
    let var: f64 = smoothed.iter().map(|&x| (x - mean) * (x - mean)).sum::<f64>() / n as f64;
    let std = var.sqrt();
    let threshold = mean + 1.2 * std;

    let min_dist_samples = (min_dist_sec * fs).round().max(5.0) as usize;

    // 5. Peak finding with refractory distance
    let mut candidate_peaks = Vec::new();
    let mut last_peak = 0;
    let check_range = n.saturating_sub(1);

    for i in 1..check_range {
        let val = smoothed[i];
        if val > threshold && val > smoothed[i - 1] && val >= smoothed[i + 1] {
            if candidate_peaks.is_empty() || i - last_peak >= min_dist_samples {
                candidate_peaks.push(i);
                last_peak = i;
            } else if let Some(prev) = candidate_peaks.last_mut() {
                if val > smoothed[*prev] {
                    *prev = i;
                    last_peak = i;
                }
            }
        }
    }

    // 6. Refine peak positions: snap to local maximum absolute amplitude on raw ECG (±50 ms)
    let search_win = (0.05 * fs).round() as usize;
    let mut refined_peaks = Vec::with_capacity(candidate_peaks.len());

    for &cp in &candidate_peaks {
        let start = cp.saturating_sub(search_win);
        let end = (cp + search_win + 1).min(n);
        let mut best_idx = cp;
        let mut best_val = -1.0;
        for j in start..end {
            let abs_val = ecg[j].abs();
            if abs_val > best_val {
                best_val = abs_val;
                best_idx = j;
            }
        }
        if refined_peaks.is_empty() || best_idx - refined_peaks.last().copied().unwrap() >= min_dist_samples {
            refined_peaks.push(best_idx);
        }
    }

    refined_peaks
}

/// Pearson correlation coefficient between two equal-length signals.
fn pearson_corr(a: &[f64], b: &[f64]) -> f64 {
    let n = a.len().min(b.len());
    if n < 10 {
        return 0.0;
    }
    let mean_a = a.iter().take(n).sum::<f64>() / n as f64;
    let mean_b = b.iter().take(n).sum::<f64>() / n as f64;
    let mut cov = 0.0;
    let mut var_a = 0.0;
    let mut var_b = 0.0;
    for i in 0..n {
        let da = a[i] - mean_a;
        let db = b[i] - mean_b;
        cov += da * db;
        var_a += da * da;
        var_b += db * db;
    }
    let denom = (var_a * var_b).sqrt();
    if denom > 1e-12 {
        cov / denom
    } else {
        0.0
    }
}

/// Computes the median of an array of floats.
fn median(mut vals: Vec<f64>) -> f64 {
    if vals.is_empty() {
        return 0.0;
    }
    vals.sort_by(|a, b| a.total_cmp(b));
    let mid = vals.len() / 2;
    if vals.len() % 2 == 1 {
        vals[mid]
    } else {
        (vals[mid - 1] + vals[mid]) / 2.0
    }
}

/// Removes ECG artifact from in-memory EEG channels using QRS template subtraction
/// with an explicitly provided ECG channel and signal.
pub fn clean_ecg_artifact_with_signal(
    ecg_label: &str,
    ecg_sig: &[f64],
    channel_names: &[String],
    signals: &mut [Vec<f64>],
    sfreq: f64,
    config: &EcgArtifactConfig,
) -> Result<EcgArtifactReport> {
    if signals.is_empty() || channel_names.len() != signals.len() {
        bail!("Signals and channel names must not be empty and match in length");
    }

    // 1. Detect R-peaks on ECG signal
    let r_peaks = detect_r_peaks(ecg_sig, sfreq, config.min_r_distance_sec);
    if r_peaks.len() < 5 {
        bail!(
            "Only {} R-peaks detected in ECG channel '{}'; recording may be disconnected or too short",
            r_peaks.len(),
            ecg_label
        );
    }

    let duration_sec = signals[0].len() as f64 / sfreq;
    let hr_bpm = if duration_sec > 0.0 {
        (r_peaks.len() as f64 / duration_sec) * 60.0
    } else {
        0.0
    };

    let pre_samples = (config.pre_r_sec * sfreq).round() as usize;
    let post_samples = (config.post_r_sec * sfreq).round() as usize;
    let w_len = pre_samples + post_samples;

    // Filter valid peaks that fit within the bounds
    let valid_peaks: Vec<usize> = r_peaks
        .into_iter()
        .filter(|&p| p >= pre_samples && p + post_samples <= ecg_sig.len() && p + post_samples <= signals[0].len())
        .collect();

    if valid_peaks.len() < 5 {
        bail!("Insufficient valid QRS complexes within boundaries");
    }

    let n_beats = valid_peaks.len();

    // 2. Process EEG channels
    let target_indices: Vec<usize> = (0..signals.len())
        .filter(|&i| !channel_names[i].eq_ignore_ascii_case(ecg_label))
        .collect();

    let reductions: Vec<EcgChannelReduction> = target_indices
        .par_iter()
        .filter_map(|&ci| {
            let ch_name = &channel_names[ci];
            let sig = &signals[ci];
            let corr_before = pearson_corr(sig, ecg_sig);

            // Clean if correlation exceeds threshold or if channel is an EEG channel
            let is_eeg = {
                let u = ch_name.to_ascii_uppercase();
                !u.contains("ECG") && !u.contains("EKG") && !u.contains("SNORE") && !u.contains("FLOW") && !u.contains("SPO2") && !u.contains("PULSE")
            };

            if corr_before.abs() < config.min_artifact_corr && !is_eeg {
                return None;
            }

            // Extract all beat windows
            let mut beats: Vec<Vec<f64>> = Vec::with_capacity(n_beats);
            for &p in &valid_peaks {
                beats.push(sig[p - pre_samples..p + post_samples].to_vec());
            }

            // Compute robust median template across all beats
            let mut template = vec![0.0; w_len];
            for sample_idx in 0..w_len {
                let sample_vals: Vec<f64> = beats.iter().map(|b| b[sample_idx]).collect();
                template[sample_idx] = median(sample_vals);
            }

            let template_energy: f64 = template.iter().map(|&x| x * x).sum();
            if template_energy <= 1e-12 {
                return None;
            }

            // Clean channel trace by subtracting scaled template beat by beat
            let mut cleaned = sig.clone();
            for (beat_idx, &p) in valid_peaks.iter().enumerate() {
                let beat = &beats[beat_idx];
                let dot_product: f64 = beat.iter().zip(template.iter()).map(|(&b, &t)| b * t).sum();
                let scale = (dot_product / (template_energy + 1e-9)).clamp(0.2, 2.5);

                for k in 0..w_len {
                    cleaned[p - pre_samples + k] -= scale * template[k];
                }
            }

            let corr_after = pearson_corr(&cleaned, ecg_sig);
            let reduction_pct = if corr_before.abs() > 1e-6 {
                ((corr_before.abs() - corr_after.abs()) / corr_before.abs() * 100.0).clamp(0.0, 100.0)
            } else {
                0.0
            };

            Some((ci, cleaned, EcgChannelReduction {
                channel: ch_name.clone(),
                corr_before: (corr_before * 1e3).round() / 1e3,
                corr_after: (corr_after * 1e3).round() / 1e3,
                reduction_pct: (reduction_pct * 10.0).round() / 10.0,
            }))
        })
        .collect::<Vec<_>>()
        .into_iter()
        .map(|(ci, cleaned_sig, red)| {
            signals[ci] = cleaned_sig;
            red
        })
        .collect();

    Ok(EcgArtifactReport {
        ecg_channel: ecg_label.to_string(),
        total_r_peaks: valid_peaks.len(),
        heart_rate_bpm: (hr_bpm * 10.0).round() / 10.0,
        cleaned_channels: reductions,
    })
}

/// Removes ECG artifact from in-memory EEG channels using QRS template subtraction.
pub fn clean_ecg_artifact(
    channel_names: &[String],
    signals: &mut [Vec<f64>],
    sfreq: f64,
    config: &EcgArtifactConfig,
) -> Result<EcgArtifactReport> {
    if signals.is_empty() || channel_names.len() != signals.len() {
        bail!("Signals and channel names must not be empty and match in length");
    }

    // Locate the ECG channel in the channel list
    let ecg_idx = if let Some(ref name) = config.ecg_channel {
        channel_names
            .iter()
            .position(|c| c.eq_ignore_ascii_case(name) || c.to_ascii_uppercase().contains(&name.to_ascii_uppercase()))
            .with_context(|| format!("Specified ECG channel '{}' not found", name))?
    } else {
        channel_names
            .iter()
            .position(|c| {
                let u = c.to_ascii_uppercase();
                u.contains("ECG") || u.contains("EKG")
            })
            .context("No ECG channel found in the recording (channels must include ECG or EKG)")?
    };

    let ecg_label = channel_names[ecg_idx].clone();
    let ecg_sig = signals[ecg_idx].clone();

    clean_ecg_artifact_with_signal(&ecg_label, &ecg_sig, channel_names, signals, sfreq, config)
}

/// Standalone runner: reads an input EDF, removes ECG artifact, and writes `<stem>_noecg.edf`.
pub fn run_ecg_cleaning(
    input_path: &Path,
    out_dir: &Path,
    config: &EcgArtifactConfig,
    target_eeg_channels: Option<&[String]>,
    suffix: &str,
) -> Result<(PathBuf, EcgArtifactReport)> {
    println!("PROGRESS 0.10 Locating ECG channel in {:?}", input_path);

    let all_labels: Vec<String> = crate::edf::read_signal_infos(input_path)?
        .into_iter()
        .map(|i| i.label)
        .collect();

    let ecg_label = if let Some(ref name) = config.ecg_channel {
        all_labels
            .iter()
            .find(|l| l.eq_ignore_ascii_case(name) || l.to_ascii_uppercase().contains(&name.to_ascii_uppercase()))
            .cloned()
            .with_context(|| format!("Specified ECG channel '{}' not found in recording", name))?
    } else {
        all_labels
            .iter()
            .find(|l| {
                let u = l.to_ascii_uppercase();
                u.contains("ECG") || u.contains("EKG")
            })
            .cloned()
            .context("No ECG channel found in the recording (channel list must contain an ECG or EKG track)")?
    };

    println!("PROGRESS 0.15 Loading ECG signal '{}'", ecg_label);
    let ecg_data = crate::edf::read_selected(input_path, std::slice::from_ref(&ecg_label))?;
    let mut ecg_sig = ecg_data.data_uv[0].clone();
    let ecg_fs = ecg_data.sfreq;

    println!("PROGRESS 0.25 Reading target EEG channels");
    let raw_eeg = if let Some(picks) = target_eeg_channels {
        crate::edf::read_available(input_path, picks)?
    } else {
        crate::edf::read_eeg_channels(input_path)?
    };

    let mut signals = raw_eeg.data_uv;
    let channel_names = raw_eeg.channels;
    let sfreq = raw_eeg.sfreq;

    if (ecg_fs - sfreq).abs() > 0.01 {
        ecg_sig = crate::signal::mne_fft_resample(&ecg_sig, ecg_fs, sfreq);
    }

    println!("PROGRESS 0.40 Detecting R-peaks and performing QRS template subtraction");
    let report = clean_ecg_artifact_with_signal(&ecg_label, &ecg_sig, &channel_names, &mut signals, sfreq, config)?;

    println!(
        "  Detected {} R-peaks (HR: {:.1} bpm) on ECG channel '{}'",
        report.total_r_peaks, report.heart_rate_bpm, report.ecg_channel
    );
    for red in &report.cleaned_channels {
        println!(
            "  {} : correlation {:.3} -> {:.3} ({:.1}% reduction)",
            red.channel, red.corr_before, red.corr_after, red.reduction_pct
        );
    }

    println!("PROGRESS 0.85 Exporting cleaned EDF");
    let stem = input_path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("recording");
    let clean_suffix = if suffix.is_empty() { "_noecg" } else { suffix };
    let out_filename = format!("{}{}.edf", stem, clean_suffix);
    let out_path = out_dir.join(out_filename);

    super::export::write_edf_file_with_prefilter(
        &out_path,
        &channel_names,
        &signals,
        sfreq,
        "AnalyseNidra QRS Subtracted",
    )?;

    println!("PROGRESS 1.00 Cleaned recording written to {:?}", out_path);
    Ok((out_path, report))
}
