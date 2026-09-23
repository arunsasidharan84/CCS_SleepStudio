use anyhow::{Context, Result, bail};
use rayon::prelude::*;
use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

#[derive(Debug, Clone)]
struct SignalHeader {
    label: String,
    /// Canonicalised label as stored in the file (ignoring any app config
    /// renames), used as a fallback when a caller passes original labels.
    raw_label: String,
    unit: String,
    transducer: String,
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
    let transducer = read_field_matrix(file, num_signals, 80)?;
    let units = read_field_matrix(file, num_signals, 8)?;
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
            raw_label: canonical_channel(&text(&labels[index])),
            unit: text(&units[index]),
            transducer: text(&transducer[index]),
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

    let selected: Vec<usize> = requested
        .iter()
        .map(|name| {
            find_header_index(&headers, name)
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
    // Read whole data records in large buffered chunks. The previous
    // implementation issued one read() per signal per record (~2 million
    // syscalls for a 60-channel overnight PSG), which is very slow on Windows
    // where every ReadFile passes through antivirus filter drivers.
    let record_bytes: usize = headers.iter().map(|h| h.samples_per_record * 2).sum();
    let offsets: Vec<usize> = headers
        .iter()
        .scan(0usize, |acc, h| {
            let start = *acc;
            *acc += h.samples_per_record * 2;
            Some(start)
        })
        .collect();
    let scales: Vec<(f64, f64)> = headers
        .iter()
        .map(|h| {
            let scale = (h.physical_max - h.physical_min) / (h.digital_max - h.digital_min);
            (scale, h.physical_min - h.digital_min * scale)
        })
        .collect();
    let records_per_chunk = (8 * 1024 * 1024 / record_bytes.max(1)).max(1);
    let mut chunk = vec![0_u8; records_per_chunk * record_bytes];
    let mut remaining = num_records;
    while remaining > 0 {
        let n = remaining.min(records_per_chunk);
        let bytes = &mut chunk[..n * record_bytes];
        if file.read_exact(bytes).is_err() {
            // Truncated file: keep the complete records we already have.
            break;
        }
        for r in 0..n {
            let record = &bytes[r * record_bytes..(r + 1) * record_bytes];
            for (&input, &output) in selected_lookup.iter() {
                let h = &headers[input];
                let (scale, offset) = scales[input];
                let start = offsets[input];
                data[output].extend(
                    record[start..start + h.samples_per_record * 2]
                        .chunks_exact(2)
                        .map(|pair| i16::from_le_bytes([pair[0], pair[1]]) as f64 * scale + offset),
                );
            }
        }
        remaining -= n;
    }
    // Duplicate requests of the same channel share one input slot; copy it.
    for (output, &input) in selected.iter().enumerate() {
        if selected_lookup.get(&input) != Some(&output) {
            let source = selected_lookup[&input];
            data[output] = data[source].clone();
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

/// Loose channel-label key: case-insensitive, ignores "EEG "/"POL " prefixes,
/// "-Ref" suffixes, whitespace, and treats ':' like '-' and A1/A2 like M1/M2.
pub fn channel_match_key(label: &str) -> String {
    let canon = canonical_channel(label.trim());
    let mut key = canon
        .to_ascii_uppercase()
        .replace(':', "-")
        .replace(' ', "")
        .replace('_', "");
    for (from, to) in [("-A1", "-M1"), ("-A2", "-M2")] {
        if key.ends_with(from) {
            key = format!("{}{}", &key[..key.len() - from.len()], to);
        }
    }
    key
}

fn find_header_index(headers: &[SignalHeader], name: &str) -> Option<usize> {
    let wanted = canonical_channel(name).to_ascii_lowercase();
    if let Some(i) = headers.iter().position(|h| h.label.to_ascii_lowercase() == wanted) {
        return Some(i);
    }
    if let Some(i) = headers.iter().position(|h| h.raw_label.to_ascii_lowercase() == wanted) {
        return Some(i);
    }
    let key = channel_match_key(name);
    headers
        .iter()
        .position(|h| channel_match_key(&h.label) == key)
        .or_else(|| headers.iter().position(|h| channel_match_key(&h.raw_label) == key))
}

/// Per-signal header summary (label, sampling rate, physical unit).
#[derive(Debug, Clone)]
pub struct SignalInfo {
    pub label: String,
    pub raw_label: String,
    pub sfreq: f64,
    pub unit: String,
    pub transducer: String,
}

/// One signal loaded at its native sampling rate.
#[derive(Debug, Clone)]
pub struct NativeSignal {
    pub label: String,
    pub sfreq: f64,
    pub unit: String,
    pub data: Vec<f64>,
}

struct EdfLayout {
    header_bytes: usize,
    num_records: usize,
    record_duration: f64,
    headers: Vec<SignalHeader>,
}

fn read_layout(path: &Path) -> Result<(File, EdfLayout)> {
    let mut file = File::open(path).with_context(|| format!("opening {}", path.display()))?;
    let mut fixed = [0_u8; 256];
    file.read_exact(&mut fixed)?;
    let header_bytes = parse_usize(&fixed[184..192], "header bytes")?;
    let mut num_records = parse_usize(&fixed[236..244], "number of records").unwrap_or(0);
    let record_duration = parse_f64(&fixed[244..252], "record duration")?;
    let num_signals = parse_usize(&fixed[252..256], "number of signals")?;
    let headers = read_edf_headers(&mut file, path, num_signals)?;
    let record_bytes: usize = headers.iter().map(|h| h.samples_per_record * 2).sum();
    // Some writers leave "-1" / wrong record counts: trust the file size.
    if let Ok(meta) = std::fs::metadata(path) {
        if record_bytes > 0 && meta.len() as usize > header_bytes {
            let by_size = (meta.len() as usize - header_bytes) / record_bytes;
            if num_records == 0 || by_size < num_records {
                num_records = by_size;
            }
        }
    }
    Ok((
        file,
        EdfLayout {
            header_bytes,
            num_records,
            record_duration,
            headers,
        },
    ))
}

/// Lists every signal in an EDF/EDF+ file with its native sampling rate.
pub fn read_signal_infos(path: &Path) -> Result<Vec<SignalInfo>> {
    let (_, layout) = read_layout(path)?;
    Ok(layout
        .headers
        .iter()
        .map(|h| SignalInfo {
            label: h.label.clone(),
            raw_label: h.raw_label.clone(),
            sfreq: h.samples_per_record as f64 / layout.record_duration.max(1e-9),
            unit: h.unit.clone(),
            transducer: h.transducer.clone(),
        })
        .collect())
}

/// Recording start (dd.mm.yy, hh.mm.ss) from the EDF header, as seconds since
/// local midnight, used for clock-time output.
pub fn read_start_clock_seconds(path: &Path) -> Option<f64> {
    let mut file = File::open(path).ok()?;
    let mut fixed = [0_u8; 256];
    file.read_exact(&mut fixed).ok()?;
    let t = text(&fixed[176..184]);
    let parts: Vec<f64> = t.split(['.', ':']).filter_map(|p| p.trim().parse().ok()).collect();
    if parts.len() == 3 {
        Some(parts[0] * 3600.0 + parts[1] * 60.0 + parts[2])
    } else {
        None
    }
}

/// Reads the requested signals, each at its own native sampling rate
/// (respiratory, SpO2, EMG and EEG channels often differ). Missing labels are
/// returned as `None` instead of failing the whole read.
pub fn read_native_signals(path: &Path, requested: &[String]) -> Result<Vec<Option<NativeSignal>>> {
    let (mut file, layout) = read_layout(path)?;
    let indices: Vec<Option<usize>> = requested
        .iter()
        .map(|name| find_header_index(&layout.headers, name))
        .collect();
    let mut buffers: HashMap<usize, Vec<f64>> = HashMap::new();
    for idx in indices.iter().flatten() {
        let spr = layout.headers[*idx].samples_per_record;
        buffers
            .entry(*idx)
            .or_insert_with(|| Vec::with_capacity(spr * layout.num_records));
    }
    if !buffers.is_empty() {
        file.seek(SeekFrom::Start(layout.header_bytes as u64))?;
        let record_bytes: usize = layout.headers.iter().map(|h| h.samples_per_record * 2).sum();
        let offsets: Vec<usize> = layout
            .headers
            .iter()
            .scan(0usize, |acc, h| {
                let start = *acc;
                *acc += h.samples_per_record * 2;
                Some(start)
            })
            .collect();
        let per_chunk = (8 * 1024 * 1024 / record_bytes.max(1)).max(1);
        let mut chunk = vec![0_u8; per_chunk * record_bytes];
        let mut remaining = layout.num_records;
        while remaining > 0 {
            let n = remaining.min(per_chunk);
            let bytes = &mut chunk[..n * record_bytes];
            if file.read_exact(bytes).is_err() {
                break;
            }
            for r in 0..n {
                let record = &bytes[r * record_bytes..(r + 1) * record_bytes];
                for (&idx, buf) in buffers.iter_mut() {
                    let h = &layout.headers[idx];
                    let scale = (h.physical_max - h.physical_min) / (h.digital_max - h.digital_min);
                    let offset = h.physical_min - h.digital_min * scale;
                    let start = offsets[idx];
                    buf.extend(
                        record[start..start + h.samples_per_record * 2]
                            .chunks_exact(2)
                            .map(|pair| i16::from_le_bytes([pair[0], pair[1]]) as f64 * scale + offset),
                    );
                }
            }
            remaining -= n;
        }
    }
    Ok(requested
        .iter()
        .zip(indices.iter())
        .map(|(_, idx)| {
            idx.map(|i| {
                let h = &layout.headers[i];
                NativeSignal {
                    label: h.label.clone(),
                    sfreq: h.samples_per_record as f64 / layout.record_duration.max(1e-9),
                    unit: h.unit.clone(),
                    data: buffers.get(&i).cloned().unwrap_or_default(),
                }
            })
        })
        .collect())
}

/// One EDF+ TAL annotation.
#[derive(Debug, Clone)]
pub struct EdfAnnotation {
    pub onset: f64,
    pub duration: f64,
    pub text: String,
}

/// Reads EDF+ "EDF Annotations" (TAL) entries. Returns an empty list for plain
/// EDF files. Onsets are relative to the recording start.
pub fn read_edf_annotations(path: &Path) -> Result<Vec<EdfAnnotation>> {
    let ext = path.extension().and_then(|s| s.to_str()).unwrap_or("").to_lowercase();
    if ext != "edf" && ext != "bdf" && ext != "rec" {
        return Ok(Vec::new());
    }
    let (mut file, layout) = read_layout(path)?;
    let Some(ann_idx) = layout
        .headers
        .iter()
        .position(|h| h.raw_label.eq_ignore_ascii_case("EDF Annotations"))
    else {
        return Ok(Vec::new());
    };
    let record_bytes: usize = layout.headers.iter().map(|h| h.samples_per_record * 2).sum();
    let offset: usize = layout.headers[..ann_idx]
        .iter()
        .map(|h| h.samples_per_record * 2)
        .sum();
    let len = layout.headers[ann_idx].samples_per_record * 2;
    let mut out = Vec::new();
    file.seek(SeekFrom::Start(layout.header_bytes as u64))?;
    let mut reader = std::io::BufReader::with_capacity(4 * 1024 * 1024, file);
    let mut record = vec![0_u8; record_bytes];
    let mut first_onset: Option<f64> = None;
    for _ in 0..layout.num_records {
        if reader.read_exact(&mut record).is_err() {
            break;
        }
        let block = &record[offset..offset + len];
        for (tal_index, tal) in block.split(|&b| b == 0).filter(|t| !t.is_empty()).enumerate() {
            let mut parts = tal.split(|&b| b == 0x14);
            let Some(time_part) = parts.next() else { continue };
            let mut time_iter = time_part.split(|&b| b == 0x15);
            let onset = time_iter
                .next()
                .and_then(|t| String::from_utf8_lossy(t).trim().parse::<f64>().ok());
            let duration = time_iter
                .next()
                .and_then(|t| String::from_utf8_lossy(t).trim().parse::<f64>().ok())
                .unwrap_or(0.0);
            let Some(onset) = onset else { continue };
            let texts: Vec<String> = parts
                .map(|t| String::from_utf8_lossy(t).trim().to_string())
                .filter(|t| !t.is_empty())
                .collect();
            if tal_index == 0 && texts.is_empty() {
                // Record time-keeping TAL.
                if first_onset.is_none() {
                    first_onset = Some(onset);
                }
                continue;
            }
            for text in texts {
                out.push(EdfAnnotation {
                    onset,
                    duration,
                    text,
                });
            }
        }
    }
    // EDF+D files may start at a non-zero time-keeping offset.
    if let Some(t0) = first_onset {
        if t0.abs() > 1e-9 {
            for a in out.iter_mut() {
                a.onset -= t0;
            }
        }
    }
    Ok(out)
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
