use anyhow::{Context, Result, bail};
use rayon::prelude::*;
use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

#[derive(Debug, Clone)]
struct SignalHeader {
    label: String,
    physical_min: f64,
    physical_max: f64,
    digital_min: f64,
    digital_max: f64,
    samples_per_record: usize,
}

#[derive(Debug)]
pub struct EdfData {
    pub sfreq: f64,
    pub duration_seconds: f64,
    pub channels: Vec<String>,
    pub data_uv: Vec<Vec<f64>>,
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).trim().to_string()
}

fn parse_f64(bytes: &[u8], field: &str) -> Result<f64> {
    text(bytes)
        .parse()
        .with_context(|| format!("parsing EDF {field}"))
}

fn parse_usize(bytes: &[u8], field: &str) -> Result<usize> {
    text(bytes)
        .parse()
        .with_context(|| format!("parsing EDF {field}"))
}

fn read_field_matrix(file: &mut File, count: usize, width: usize) -> Result<Vec<Vec<u8>>> {
    let mut bytes = vec![0_u8; count * width];
    file.read_exact(&mut bytes)?;
    Ok(bytes.chunks_exact(width).map(<[u8]>::to_vec).collect())
}

fn canonical_channel(label: &str) -> String {
    let mut name = label.replace("EEG ", "").replace("-Ref", "");
    if let Some(rest) = name.strip_prefix("POL ") {
        name = rest.to_string();
    }
    if name.eq_ignore_ascii_case("A1") {
        "M1".into()
    } else if name.eq_ignore_ascii_case("A2") {
        "M2".into()
    } else {
        name
    }
}

fn load_custom_channel_map(path: &Path) -> HashMap<usize, String> {
    let mut map = HashMap::new();
    let config_path = path.with_extension("config.json");
    if let Ok(content) = std::fs::read_to_string(&config_path) {
        if let Ok(serde_json::Value::Array(arr)) =
            serde_json::from_str::<serde_json::Value>(&content)
        {
            if arr.len() >= 2 {
                if let Some(channels_list) = arr[1].as_array() {
                    for c in channels_list {
                        let is_derived =
                            c.get("derived").and_then(|v| v.as_bool()).unwrap_or(false);
                        if is_derived {
                            continue;
                        }
                        if let (Some(name), Some(idx)) = (
                            c.get("Channel_name").and_then(|v| v.as_str()),
                            c.get("sourceIndex").and_then(|v| v.as_u64()),
                        ) {
                            map.insert(idx as usize, name.to_string());
                        }
                    }
                }
            }
        }
    }
    map
}

fn read_edf_headers(file: &mut File, path: &Path, num_signals: usize) -> Result<Vec<SignalHeader>> {
    let labels = read_field_matrix(file, num_signals, 16)?;
    let _transducer = read_field_matrix(file, num_signals, 80)?;
    let _units = read_field_matrix(file, num_signals, 8)?;
    let physical_min = read_field_matrix(file, num_signals, 8)?;
    let physical_max = read_field_matrix(file, num_signals, 8)?;
    let digital_min = read_field_matrix(file, num_signals, 8)?;
    let digital_max = read_field_matrix(file, num_signals, 8)?;
    let _prefilter = read_field_matrix(file, num_signals, 80)?;
    let samples_per_record = read_field_matrix(file, num_signals, 8)?;
    let _reserved = read_field_matrix(file, num_signals, 32)?;

    let custom_map = load_custom_channel_map(path);
    let mut headers = Vec::with_capacity(num_signals);
    for index in 0..num_signals {
        let label = if let Some(custom_name) = custom_map.get(&index) {
            canonical_channel(custom_name)
        } else {
            canonical_channel(&text(&labels[index]))
        };
        headers.push(SignalHeader {
            label,
            physical_min: parse_f64(&physical_min[index], "physical minimum")?,
            physical_max: parse_f64(&physical_max[index], "physical maximum")?,
            digital_min: parse_f64(&digital_min[index], "digital minimum")?,
            digital_max: parse_f64(&digital_max[index], "digital maximum")?,
            samples_per_record: parse_usize(&samples_per_record[index], "samples per record")?,
        });
    }
    Ok(headers)
}

pub fn read_channel_labels(path: &Path) -> Result<Vec<String>> {
    let mut file = File::open(path).with_context(|| format!("opening {}", path.display()))?;
    let mut fixed = [0_u8; 256];
    file.read_exact(&mut fixed)?;
    let num_signals = parse_usize(&fixed[252..256], "number of signals")?;
    let headers = read_edf_headers(&mut file, path, num_signals)?;
    Ok(headers.into_iter().map(|h| h.label).collect())
}

pub fn read_all_channels(path: &Path) -> Result<EdfData> {
    let labels = read_channel_labels(path)?;
    read_selected(path, &labels)
}

pub fn read_eeg_channels(path: &Path) -> Result<EdfData> {
    let mut file = File::open(path).with_context(|| format!("opening {}", path.display()))?;
    let mut fixed = [0_u8; 256];
    file.read_exact(&mut fixed)?;
    let num_signals = parse_usize(&fixed[252..256], "number of signals")?;
    let headers = read_edf_headers(&mut file, path, num_signals)?;
    let montage = crate::cleaning::montage::standard_1020_montage();

    let mut eeg_candidates = Vec::new();
    let mut spr_counts: HashMap<usize, usize> = HashMap::new();

    for h in &headers {
        if crate::cleaning::montage::lookup_electrode_pos(&montage, &h.label).is_some() {
            eeg_candidates.push((h.label.clone(), h.samples_per_record));
            *spr_counts.entry(h.samples_per_record).or_insert(0) += 1;
        }
    }

    let best_spr = spr_counts
        .into_iter()
        .max_by_key(|&(_, count)| count)
        .map(|(spr, _)| spr);

    let picked: Vec<String> = if let Some(target_spr) = best_spr {
        eeg_candidates
            .into_iter()
            .filter(|&(_, spr)| spr == target_spr)
            .map(|(label, _)| label)
            .collect()
    } else {
        crate::DEFAULT_CHANNELS.iter().map(|s| s.to_string()).collect()
    };

    read_selected(path, &picked)
}

pub fn read_selected(path: &Path, requested: &[String]) -> Result<EdfData> {
    if requested.is_empty() {
        bail!("at least one EDF channel must be selected");
    }
    let ext = path.extension().and_then(|s| s.to_str()).unwrap_or("").to_lowercase();
    if ext == "vhdr" {
        return read_vhdr_selected(path, requested);
    }
    let mut file = File::open(path).with_context(|| format!("opening {}", path.display()))?;
    let mut fixed = [0_u8; 256];
    file.read_exact(&mut fixed)?;
    let header_bytes = parse_usize(&fixed[184..192], "header bytes")?;
    let num_records = parse_usize(&fixed[236..244], "number of records")?;
    let record_duration = parse_f64(&fixed[244..252], "record duration")?;
    let num_signals = parse_usize(&fixed[252..256], "number of signals")?;

    let headers = read_edf_headers(&mut file, path, num_signals)?;
    file.seek(SeekFrom::Start(header_bytes as u64))?;

    let by_name: HashMap<String, usize> = headers
        .iter()
        .enumerate()
        .map(|(index, header)| (header.label.to_ascii_lowercase(), index))
        .collect();
    let selected: Vec<usize> = requested
        .iter()
        .map(|name| {
            by_name
                .get(&canonical_channel(name).to_ascii_lowercase())
                .copied()
                .with_context(|| format!("EDF channel {name} is missing"))
        })
        .collect::<Result<_>>()?;
    let selected_lookup: HashMap<usize, usize> = selected
        .iter()
        .enumerate()
        .map(|(output, &input)| (input, output))
        .collect();

    let first_spr = headers[selected[0]].samples_per_record;
    if selected
        .iter()
        .any(|&index| headers[index].samples_per_record != first_spr)
    {
        bail!("selected EDF channels do not share one sampling frequency");
    }
    let sfreq = first_spr as f64 / record_duration;
    let mut data = requested
        .iter()
        .map(|_| Vec::with_capacity(num_records * first_spr))
        .collect::<Vec<_>>();
    let max_spr = headers
        .iter()
        .map(|header| header.samples_per_record)
        .max()
        .unwrap_or(0);
    let mut bytes = vec![0_u8; max_spr * 2];

    for _ in 0..num_records {
        for (signal_index, header) in headers.iter().enumerate() {
            let byte_count = header.samples_per_record * 2;
            file.read_exact(&mut bytes[..byte_count])?;
            let Some(&output_index) = selected_lookup.get(&signal_index) else {
                continue;
            };
            let scale = (header.physical_max - header.physical_min)
                / (header.digital_max - header.digital_min);
            let offset = header.physical_min - header.digital_min * scale;
            data[output_index].extend(
                bytes[..byte_count]
                    .chunks_exact(2)
                    .map(|pair| i16::from_le_bytes([pair[0], pair[1]]) as f64 * scale + offset),
            );
        }
    }
    data.par_iter_mut()
        .for_each(|channel| channel.shrink_to_fit());
    Ok(EdfData {
        sfreq,
        duration_seconds: num_records as f64 * record_duration,
        channels: requested.to_vec(),
        data_uv: data,
    })
}

fn read_vhdr_selected(path: &Path, requested: &[String]) -> Result<EdfData> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("Failed reading .vhdr header {}", path.display()))?;

    let mut data_file = String::new();
    let mut orientation = String::from("MULTIPLEXED");
    let mut binary_format = String::from("IEEE_FLOAT_32");
    let mut num_channels = 0usize;
    let mut sampling_interval_us = 0.0f64;

    let mut channel_names = HashMap::new();
    let mut channel_resolutions = HashMap::new();

    let mut section = String::new();

    for raw_line in content.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with(';') {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') {
            section = line[1..line.len() - 1].trim().to_string();
            continue;
        }
        if let Some(idx) = line.find('=') {
            let k = line[..idx].trim();
            let v = line[idx + 1..].trim();
            match section.as_str() {
                "Common Infos" => {
                    if k.eq_ignore_ascii_case("DataFile") {
                        data_file = v.to_string();
                    } else if k.eq_ignore_ascii_case("DataOrientation") {
                        orientation = v.to_uppercase();
                    } else if k.eq_ignore_ascii_case("NumberOfChannels") {
                        num_channels = v.parse().unwrap_or(0);
                    } else if k.eq_ignore_ascii_case("SamplingInterval") {
                        sampling_interval_us = v.parse().unwrap_or(0.0);
                    }
                }
                "Binary Infos" => {
                    if k.eq_ignore_ascii_case("BinaryFormat") {
                        binary_format = v.to_uppercase();
                    }
                }
                "Channel Infos" => {
                    if k.to_lowercase().starts_with("ch") {
                        if let Ok(ch_idx) = k[2..].parse::<usize>() {
                            let parts: Vec<&str> = v.split(',').collect();
                            let name = if !parts.is_empty() && !parts[0].trim().is_empty() {
                                parts[0].trim().to_string()
                            } else {
                                format!("Ch{}", ch_idx)
                            };
                            channel_names.insert(ch_idx, name);
                            let res = if parts.len() >= 3 && !parts[2].trim().is_empty() {
                                parts[2].trim().parse::<f64>().unwrap_or(1.0)
                            } else {
                                1.0
                            };
                            channel_resolutions.insert(ch_idx, res);
                        }
                    }
                }
                _ => {}
            }
        }
    }

    if sampling_interval_us <= 0.0 {
        bail!("Invalid SamplingInterval {} in .vhdr", sampling_interval_us);
    }
    let sfreq = 1_000_000.0 / sampling_interval_us;
    if num_channels == 0 {
        bail!("NumberOfChannels is 0 in .vhdr");
    }

    let custom_map = load_custom_channel_map(path);
    let mut labels = Vec::with_capacity(num_channels);
    let mut resolutions = Vec::with_capacity(num_channels);
    for i in 1..=num_channels {
        let label = if let Some(custom_name) = custom_map.get(&(i - 1)) {
            canonical_channel(custom_name)
        } else {
            canonical_channel(channel_names.get(&i).map(String::as_str).unwrap_or(&format!("Ch{}", i)))
        };
        labels.push(label);
        resolutions.push(channel_resolutions.get(&i).cloned().unwrap_or(1.0));
    }

    let by_name: HashMap<String, usize> = labels
        .iter()
        .enumerate()
        .map(|(index, label)| (label.to_ascii_lowercase(), index))
        .collect();
    let selected: Vec<usize> = requested
        .iter()
        .map(|name| {
            by_name
                .get(&canonical_channel(name).to_ascii_lowercase())
                .copied()
                .with_context(|| format!("VHDR channel {name} is missing"))
        })
        .collect::<Result<_>>()?;

    let parent = path.parent().unwrap_or_else(|| Path::new(""));
    let mut data_path = parent.join(&data_file);
    if data_file.is_empty() || !data_path.exists() {
        let eeg_path = path.with_extension("eeg");
        let dat_path = path.with_extension("dat");
        if eeg_path.exists() {
            data_path = eeg_path;
        } else if dat_path.exists() {
            data_path = dat_path;
        } else {
            bail!("Companion data file not found for {}", path.display());
        }
    }

    let bytes = std::fs::read(&data_path)
        .with_context(|| format!("Failed reading EEG data file {}", data_path.display()))?;

    let bytes_per_sample = match binary_format.as_str() {
        "INT_16" | "UINT_16" => 2,
        "INT_32" => 4,
        _ => 4, // IEEE_FLOAT_32
    };

    let total_samples = bytes.len() / (num_channels * bytes_per_sample);
    if total_samples == 0 {
        bail!("Data file {} contains 0 complete samples", data_path.display());
    }

    let mut data = vec![vec![0.0f64; total_samples]; requested.len()];

    let is_vectorized = orientation == "VECTORIZED";
    for (out_idx, &in_idx) in selected.iter().enumerate() {
        let res = resolutions[in_idx];
        let ch_slice = &mut data[out_idx];
        for s in 0..total_samples {
            let offset = if is_vectorized {
                (in_idx * total_samples + s) * bytes_per_sample
            } else {
                (s * num_channels + in_idx) * bytes_per_sample
            };

            if offset + bytes_per_sample <= bytes.len() {
                let v = match binary_format.as_str() {
                    "INT_16" => i16::from_le_bytes([bytes[offset], bytes[offset + 1]]) as f64,
                    "UINT_16" => u16::from_le_bytes([bytes[offset], bytes[offset + 1]]) as f64,
                    "INT_32" => i32::from_le_bytes([
                        bytes[offset],
                        bytes[offset + 1],
                        bytes[offset + 2],
                        bytes[offset + 3],
                    ]) as f64,
                    _ => f32::from_le_bytes([
                        bytes[offset],
                        bytes[offset + 1],
                        bytes[offset + 2],
                        bytes[offset + 3],
                    ]) as f64,
                };
                ch_slice[s] = v * res;
            }
        }
    }

    data.par_iter_mut().for_each(|ch| ch.shrink_to_fit());

    Ok(EdfData {
        sfreq,
        duration_seconds: total_samples as f64 / sfreq,
        channels: requested.to_vec(),
        data_uv: data,
    })
}
