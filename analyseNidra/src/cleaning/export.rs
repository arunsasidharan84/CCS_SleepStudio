use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::Path;

#[derive(Debug, Serialize, Deserialize)]
pub struct PreprocessingLog {
    pub input_file: String,
    pub output_file: String,
    pub steps_run: Vec<String>,
    pub sample_rate: f64,
    pub original_channels: Vec<String>,
    pub bad_channels: Vec<String>,
    pub duration_seconds: f64,
    /// Present when the "stimartifact" step ran.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stim_artifact: Option<super::stim_artifact::StimArtifactReport>,
    pub timestamp: String,
}

fn pad_ascii(text: &str, width: usize) -> Vec<u8> {
    let mut bytes = text.as_bytes().to_vec();
    if bytes.len() > width {
        bytes.truncate(width);
    } else {
        while bytes.len() < width {
            bytes.push(b' ');
        }
    }
    bytes
}

/// Exports cleaned multi-channel signals to standard European Data Format (EDF).
pub fn write_edf_file(
    out_path: &Path,
    channel_names: &[String],
    signals: &[Vec<f64>],
    sample_rate: f64,
) -> Result<()> {
    write_edf_file_with_prefilter(
        out_path,
        channel_names,
        signals,
        sample_rate,
        "AnalyseNidra Rust Preprocessed",
    )
}

/// Exports cleaned multi-channel signals to standard European Data Format (EDF)
/// with an explicit prefilter header string and adaptive per-channel dynamic range.
pub fn write_edf_file_with_prefilter(
    out_path: &Path,
    channel_names: &[String],
    signals: &[Vec<f64>],
    sample_rate: f64,
    prefilter_label: &str,
) -> Result<()> {
    if channel_names.is_empty() || signals.is_empty() {
        anyhow::bail!("Cannot write empty EDF file");
    }

    let n_signals = channel_names.len();
    let n_samples = signals[0].len();
    let samples_per_record = sample_rate.round() as usize;
    let n_records = n_samples / samples_per_record.max(1);

    // Compute per-channel symmetric physical bound >= 500.0 uV so signals never clip
    let phys_bounds: Vec<f64> = signals
        .iter()
        .map(|sig| {
            let max_abs = sig
                .iter()
                .copied()
                .filter(|v| v.is_finite())
                .fold(0.0_f64, |acc, v| acc.max(v.abs()));
            (max_abs * 1.05).ceil().max(500.0).min(32767.0)
        })
        .collect();

    let file = File::create(out_path).with_context(|| format!("Creating EDF at {:?}", out_path))?;
    let mut writer = BufWriter::new(file);

    // Header size: (n_signals + 1) * 256
    let header_bytes = (n_signals + 1) * 256;

    // Main header (256 bytes)
    writer.write_all(&pad_ascii("0", 8))?; // Version
    writer.write_all(&pad_ascii("AnalyseNidra Cleaned EEG", 80))?; // Patient ID
    writer.write_all(&pad_ascii("Startdate 01-JAN-2026", 80))?; // Recording ID
    writer.write_all(&pad_ascii("01.01.26", 8))?; // Start date
    writer.write_all(&pad_ascii("00.00.00", 8))?; // Start time
    writer.write_all(&pad_ascii(&header_bytes.to_string(), 8))?; // Header bytes
    writer.write_all(&pad_ascii("EDF+C", 44))?; // Reserved
    writer.write_all(&pad_ascii(&n_records.to_string(), 8))?; // Number of records
    writer.write_all(&pad_ascii("1", 8))?; // Duration of record in seconds
    writer.write_all(&pad_ascii(&n_signals.to_string(), 4))?; // Number of signals

    // Signal Headers (256 * n_signals bytes)
    // 1. Labels (16 bytes each)
    for name in channel_names {
        writer.write_all(&pad_ascii(name, 16))?;
    }
    // 2. Transducer type (80 bytes each)
    for _ in 0..n_signals {
        writer.write_all(&pad_ascii("AgAgCl electrode", 80))?;
    }
    // 3. Physical dimension (8 bytes each)
    for _ in 0..n_signals {
        writer.write_all(&pad_ascii("uV", 8))?;
    }
    // 4. Physical minimum (8 bytes each)
    for &bound in &phys_bounds {
        writer.write_all(&pad_ascii(&format!("-{:.1}", bound), 8))?;
    }
    // 5. Physical maximum (8 bytes each)
    for &bound in &phys_bounds {
        writer.write_all(&pad_ascii(&format!("{:.1}", bound), 8))?;
    }
    // 6. Digital minimum (8 bytes each)
    for _ in 0..n_signals {
        writer.write_all(&pad_ascii("-32768", 8))?;
    }
    // 7. Digital maximum (8 bytes each)
    for _ in 0..n_signals {
        writer.write_all(&pad_ascii("32767", 8))?;
    }
    // 8. Prefiltering (80 bytes each)
    for _ in 0..n_signals {
        writer.write_all(&pad_ascii(prefilter_label, 80))?;
    }
    // 9. Samples in each record (8 bytes each)
    for _ in 0..n_signals {
        writer.write_all(&pad_ascii(&samples_per_record.to_string(), 8))?;
    }
    // 10. Reserved (32 bytes each)
    for _ in 0..n_signals {
        writer.write_all(&pad_ascii("", 32))?;
    }

    // Data records: scale uV [-bound, bound] to digital i16 [-32768, 32767]
    let dig_range = 65535.0;

    for rec in 0..n_records {
        let start = rec * samples_per_record;
        let end = start + samples_per_record;

        for ch in 0..n_signals {
            let bound = phys_bounds[ch];
            let scale = dig_range / (2.0 * bound);
            let slice = &signals[ch][start..end];
            for &val in slice {
                let clamped = val.clamp(-bound, bound);
                let digital = ((clamped + bound) * scale - 32768.0).round() as i32;
                let i16_val = digital.clamp(-32768, 32767) as i16;
                writer.write_all(&i16_val.to_le_bytes())?;
            }
        }
    }

    writer.flush()?;
    Ok(())
}

/// Writes JSON preprocessing execution log.
pub fn write_json_log(log_path: &Path, log: &PreprocessingLog) -> Result<()> {
    let file = File::create(log_path).with_context(|| format!("Creating log file at {:?}", log_path))?;
    serde_json::to_writer_pretty(file, log)?;
    Ok(())
}
