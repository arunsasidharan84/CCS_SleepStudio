use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::ffi::{CString, CStr};
use std::os::raw::c_char;
use crate::edf::{EdfFile, EdfSignal};

#[derive(Debug, Clone)]
pub struct NkPatient {
    pub id: String,
    pub name: String,
    pub sex: String,
    pub birthday: String,
    pub start_date: String,
    pub start_time: String,
}

impl Default for NkPatient {
    fn default() -> Self {
        Self {
            id: "ANONYMOUS".into(),
            name: "Anonymous".into(),
            sex: "X".into(),
            birthday: "01-JAN-1900".into(),
            start_date: "01.01.20".into(),
            start_time: "00.00.00".into(),
        }
    }
}

pub struct NkDataBlock {
    pub address: u32,
    pub rec_address: u32,
    pub num_samples: usize,
}

pub fn get_nk_channel_name(ch_idx: usize) -> String {
    match ch_idx + 1 {
        1 => "FP1".into(),
        2 => "FP2".into(),
        3 => "F3".into(),
        4 => "F4".into(),
        5 => "C3".into(),
        6 => "C4".into(),
        7 => "P3".into(),
        8 => "P4".into(),
        9 => "O1".into(),
        10 => "O2".into(),
        11 => "F7".into(),
        12 => "F8".into(),
        13 => "T3".into(),
        14 => "T4".into(),
        15 => "T5".into(),
        16 => "T6".into(),
        17 => "FZ".into(),
        18 => "CZ".into(),
        19 => "PZ".into(),
        20 => "E".into(),
        21 => "PG1".into(),
        22 => "PG2".into(),
        23 => "A1".into(),
        24 => "A2".into(),
        25 => "T1".into(),
        26 => "T2".into(),
        27..=37 => format!("X{}", ch_idx + 1 - 26),
        38 => "BN".into(),
        39 => "AV".into(),
        40 => "SD".into(),
        41 => "Aav".into(),
        42 => "0V".into(),
        43..=70 => format!("DC{:02}", ch_idx + 1 - 42),
        71 => "SpO2".into(),
        72 => "EtCO2".into(),
        73 => "Pulse".into(),
        74 => "CO2Wave".into(),
        75 => "BN1".into(),
        76 => "BN2".into(),
        77 => "Mark1".into(),
        78 => "Mark2".into(),
        101 => "BP1".into(),
        102 => "BP2".into(),
        103 => "BP3".into(),
        104 => "BP4".into(),
        other => format!("EEG{}", other),
    }
}

/// Reads channel names from a Nihon Kohden `.21E` electrode file.
///
/// Every `index=name` entry in the `[ELECTRODE]` and `[REFERENCE]` sections is
/// used, for all electrode codes (the same rule as MNE and as Nihon Kohden's own
/// EDF export). Earlier versions ignored codes >= 74, so channels such as M2,
/// O1, O2, LEOG/REOG, EMG and ECG on EEG-1200 systems fell back to generic
/// names ("EEG103", "EEG321", ...) and the mark inputs showed as Mark1/Mark2.
pub fn read_21e_channel_names(path: &Path) -> std::collections::HashMap<usize, String> {
    let mut names = std::collections::HashMap::new();
    let Ok(bytes) = std::fs::read(path) else { return names; };
    // Latin-1 decoding never fails; channel names are ASCII in practice.
    let text: String = bytes.iter().map(|&b| b as char).collect();
    let mut in_section = false;

    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with(';') {
            continue;
        }
        if trimmed.starts_with('[') {
            let upper = trimmed.to_ascii_uppercase();
            in_section = upper == "[ELECTRODE]" || upper == "[REFERENCE]";
            continue;
        }
        if !in_section { continue; }
        if let Some((k, v)) = trimmed.split_once('=') {
            if let Ok(idx) = k.trim().parse::<usize>() {
                let name = v.trim();
                if !name.is_empty() {
                    names.insert(idx, name.to_string());
                }
            }
        }
    }
    names
}

pub fn read_pnt_patient_info(path: &Path) -> NkPatient {
    let mut p = NkPatient::default();
    let Ok(mut file) = File::open(path) else { return p; };
    let mut buf = vec![0u8; 2048];
    if file.read(&mut buf).is_err() { return p; }

    let clean = |b: &[u8]| -> String {
        String::from_utf8_lossy(b).trim_matches(|c: char| c == '\0' || c.is_whitespace()).to_string()
    };

    if buf.len() >= 1550 { p.id = clean(&buf[1540..1550]); }
    if buf.len() >= 1602 { p.name = clean(&buf[1582..1602]); }
    if buf.len() >= 1616 { p.sex = clean(&buf[1610..1616]); }
    if buf.len() >= 1642 { p.birthday = clean(&buf[1632..1642]); }
    if buf.len() >= 78 {
        let date_str = clean(&buf[64..78]);
        if date_str.len() >= 14 {
            p.start_date = format!("{}.{}.{}", &date_str[6..8], &date_str[4..6], &date_str[2..4]);
            p.start_time = format!("{}.{}.{}", &date_str[8..10], &date_str[10..12], &date_str[12..14]);
        }
    }

    p
}

pub fn load_nihon_kohden_impl(eeg_path: &Path) -> Result<EdfFile, String> {
    let parent = eeg_path.parent().unwrap_or_else(|| Path::new("."));
    let stem = eeg_path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    let elec_path_21e = parent.join(format!("{stem}.21E"));
    let elec_path_lower = parent.join(format!("{stem}.21e"));
    let custom_names = if elec_path_21e.exists() {
        read_21e_channel_names(&elec_path_21e)
    } else if elec_path_lower.exists() {
        read_21e_channel_names(&elec_path_lower)
    } else {
        std::collections::HashMap::new()
    };

    let mut file = File::open(eeg_path).map_err(|e| format!("Cannot open .EEG file: {e}"))?;
    let file_len = file.metadata().map_err(|e| e.to_string())?.len() as usize;

    let mut header = vec![0u8; std::cmp::min(file_len, 6144)];
    file.read_exact(&mut header).map_err(|e| format!("EEG file header truncated: {e}"))?;

    let version_str = String::from_utf8_lossy(&header[..16]);
    let is_v2 = version_str.starts_with("EEG-1200A");

    let (n_channels, sample_rate, datastart, n_samples, ch_labels) = if is_v2 && file_len > 0x03EE + 4 {
        // --- Version 2 (EEG-1200A extended block chain) ---
        let ext_address = u32::from_le_bytes([header[0x03EE], header[0x03EF], header[0x03F0], header[0x03F1]]) as usize;
        if ext_address + 22 > file_len {
            return Err("Invalid ext_address in NK v2 file".into());
        }

        file.seek(SeekFrom::Start((ext_address + 18) as u64)).map_err(|e| e.to_string())?;
        let mut buf4 = [0u8; 4];
        file.read_exact(&mut buf4).map_err(|e| e.to_string())?;
        let extblock2_addr = u32::from_le_bytes(buf4) as usize;

        file.seek(SeekFrom::Start((extblock2_addr + 20) as u64)).map_err(|e| e.to_string())?;
        file.read_exact(&mut buf4).map_err(|e| e.to_string())?;
        let extblock3_addr = u32::from_le_bytes(buf4) as usize;

        // Sample rate from data block at 0x17fe
        file.seek(SeekFrom::Start(0x17fe + 0x1A)).map_err(|e| e.to_string())?;
        let mut buf2 = [0u8; 2];
        file.read_exact(&mut buf2).map_err(|e| e.to_string())?;
        let sfreq_raw = u16::from_le_bytes(buf2) & 0x3FFF;
        let srate = if sfreq_raw > 0 { sfreq_raw as f32 } else { 1000.0f32 };

        file.seek(SeekFrom::Start((extblock3_addr + 68) as u64)).map_err(|e| e.to_string())?;
        file.read_exact(&mut buf2).map_err(|e| e.to_string())?;
        let num_channels_raw = u16::from_le_bytes(buf2) as usize;
        let n_chan = num_channels_raw;

        let mut labels = Vec::with_capacity(n_chan);
        for i_ch in 0..n_chan {
            file.seek(SeekFrom::Start((extblock3_addr + 72 + i_ch * 10) as u64)).map_err(|e| e.to_string())?;
            file.read_exact(&mut buf2).map_err(|e| e.to_string())?;
            let idx_0based = u16::from_le_bytes(buf2) as usize;
            let name = custom_names.get(&idx_0based).cloned().unwrap_or_else(|| get_nk_channel_name(idx_0based));
            labels.push(name);
        }

        let rec_address = extblock3_addr + 72 + num_channels_raw * 10;
        let n_frame_channels = n_chan + 1; // +1 for STIM/ref channel
        let total_samples = (file_len.saturating_sub(rec_address)) / (n_frame_channels * 2);

        (n_chan, srate, rec_address, total_samples, labels)
    } else {
        // --- Version 1 (standard datablock header) ---
        let n_ctlblocks = if header.len() > 0x0091 { header[0x0091] as usize } else { 0 };
        if n_ctlblocks == 0 {
            return Err("Invalid Nihon Kohden control block count".into());
        }

        let ctl_offset = 0x0092;
        if ctl_offset + 4 > header.len() {
            return Err("Truncated control block table".into());
        }
        let ctl_addr = u32::from_le_bytes([header[ctl_offset], header[ctl_offset+1], header[ctl_offset+2], header[ctl_offset+3]]) as usize;
        if ctl_addr + 18 > file_len {
            return Err("Invalid control block address".into());
        }

        let mut ctl_hdr = [0u8; 32];
        file.seek(SeekFrom::Start(ctl_addr as u64)).map_err(|e| e.to_string())?;
        file.read_exact(&mut ctl_hdr).map_err(|e| e.to_string())?;

        let data_ptr_addr = ctl_addr + 18;
        file.seek(SeekFrom::Start(data_ptr_addr as u64)).map_err(|e| e.to_string())?;
        let mut addr_buf = [0u8; 4];
        file.read_exact(&mut addr_buf).map_err(|e| e.to_string())?;
        let data_addr = u32::from_le_bytes(addr_buf) as usize;

        let mut dtb_hdr = [0u8; 64];
        file.seek(SeekFrom::Start((data_addr + 0x1A) as u64)).map_err(|e| e.to_string())?;
        file.read_exact(&mut dtb_hdr).map_err(|e| e.to_string())?;

        let sfreq_raw = u16::from_le_bytes([dtb_hdr[0], dtb_hdr[1]]) & 0x3FFF;
        let srate = if sfreq_raw > 0 { sfreq_raw as f32 } else { 200.0f32 };
        let duration_units = u32::from_le_bytes([dtb_hdr[2], dtb_hdr[3], dtb_hdr[4], dtb_hdr[5]]) as usize;
        let total_samples = duration_units * (srate as usize) / 10;

        let n_chan = dtb_hdr[0x26 - 0x1A] as usize;
        if n_chan == 0 {
            return Err("Zero channels in datablock".into());
        }

        let mut labels = Vec::with_capacity(n_chan);
        for i_ch in 0..n_chan {
            let ch_ptr = data_addr + 0x27 + (i_ch * 10);
            file.seek(SeekFrom::Start(ch_ptr as u64)).map_err(|e| e.to_string())?;
            let mut idx_buf = [0u8; 1];
            if file.read_exact(&mut idx_buf).is_ok() {
                let idx = idx_buf[0] as usize;
                let name = custom_names.get(&idx).cloned().unwrap_or_else(|| get_nk_channel_name(idx));
                labels.push(name);
            } else {
                labels.push(get_nk_channel_name(i_ch));
            }
        }

        let rec_address = data_addr + 0x27 + (n_chan * 10);
        (n_chan, srate, rec_address, total_samples, labels)
    };

    file.seek(SeekFrom::Start(datastart as u64)).map_err(|e| e.to_string())?;

    let lsb_microvolts = 0.09765625f32; // ~3200.0 uV / 32768.0
    let n_frame_channels = n_channels + 1; // 1 extra reference channel at end of frame
    let frame_bytes = n_frame_channels * 2;

    let mut channel_samples: Vec<Vec<f32>> = (0..n_channels).map(|_| Vec::with_capacity(n_samples)).collect();

    let chunk_size = 1024 * 1024 * 4; // 4MB chunks
    let mut buf = vec![0u8; chunk_size];
    let total_bytes_to_read = n_samples * frame_bytes;
    let mut remaining = std::cmp::min(total_bytes_to_read, file_len.saturating_sub(datastart));

    while remaining >= frame_bytes {
        let target_read = std::cmp::min(remaining, chunk_size);
        let target_read = (target_read / frame_bytes) * frame_bytes;
        if target_read == 0 { break; }

        let n_read = file.read(&mut buf[..target_read]).unwrap_or(0);
        if n_read < frame_bytes { break; }

        remaining -= n_read;
        let n_frames = n_read / frame_bytes;

        for f in 0..n_frames {
            for ch in 0..n_channels {
                let val_idx = f * n_frame_channels + ch;
                let b0 = buf[val_idx * 2];
                let b1 = buf[val_idx * 2 + 1];
                let raw_u16 = u16::from_le_bytes([b0, b1]);
                let raw_i16 = raw_u16.wrapping_sub(0x8000) as i16;
                let phys_microvolts = (raw_i16 as f32) * lsb_microvolts;
                channel_samples[ch].push(phys_microvolts);
            }
        }
    }

    let mut signals = Vec::with_capacity(n_channels);
    for ch in 0..n_channels {
        let label_c = CString::new(ch_labels[ch].clone()).unwrap_or_else(|_| CString::new("").unwrap());
        let samps = std::mem::take(&mut channel_samples[ch]);
        let count = samps.len() as i32;

        signals.push(EdfSignal {
            label: label_c.into_raw(),
            samples: samps.leak().as_mut_ptr(),
            sample_count: count,
        });
    }

    let total_duration = if n_channels > 0 && !signals.is_empty() {
        signals[0].sample_count as f32 / sample_rate
    } else {
        0.0
    };

    Ok(EdfFile {
        sample_rate_hz: sample_rate,
        signal_count: n_channels as i32,
        signals: signals.leak().as_mut_ptr(),
        duration_seconds: total_duration,
    })
}

#[no_mangle]
pub extern "C" fn sleep_eeg_load_nihon_kohden(path: *const c_char) -> *mut EdfFile {
    if path.is_null() { return std::ptr::null_mut(); }
    let path_str = unsafe { CStr::from_ptr(path) };
    let Ok(path_str) = path_str.to_str() else { return std::ptr::null_mut(); };

    match load_nihon_kohden_impl(Path::new(path_str)) {
        Ok(edf) => Box::into_raw(Box::new(edf)),
        Err(_) => std::ptr::null_mut(),
    }
}
