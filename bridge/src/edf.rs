use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom};
use std::path::Path;
use std::ffi::{CString, CStr};
use std::os::raw::c_char;

#[repr(C)]
pub struct EdfSignal {
    pub label: *mut c_char,
    pub samples: *mut f32,
    pub sample_count: i32,
}

#[repr(C)]
pub struct EdfFile {
    pub sample_rate_hz: f32,
    pub signal_count: i32,
    pub signals: *mut EdfSignal,
    pub duration_seconds: f32,
}

fn parse_ascii_string(bytes: &[u8], offset: usize, width: usize) -> String {
    if offset + width > bytes.len() {
        return String::new();
    }
    let sub = &bytes[offset..offset + width];
    let s = String::from_utf8_lossy(sub);
    s.trim().to_string()
}

fn parse_int(bytes: &[u8], offset: usize, width: usize) -> Option<i32> {
    let s = parse_ascii_string(bytes, offset, width);
    s.parse::<i32>().ok()
}

fn parse_double(bytes: &[u8], offset: usize, width: usize) -> Option<f64> {
    let s = parse_ascii_string(bytes, offset, width);
    let s = s.replace(',', ".");
    s.parse::<f64>().ok()
}

fn is_display_signal(label: &str) -> bool {
    let normalized = label.to_lowercase();
    !normalized.contains("annotation")
        && !normalized.contains("status")
        && !normalized.contains("marker")
}

pub fn load_edf_impl(path: &Path, scale_volts: bool) -> Result<EdfFile, String> {
    let mut file = File::open(path).map_err(|e| e.to_string())?;

    // Read the first 256 bytes (primary header)
    let mut header = vec![0u8; 256];
    file.read_exact(&mut header).map_err(|e| e.to_string())?;

    let header_bytes = parse_int(&header, 184, 8).ok_or("Invalid header bytes length")? as usize;
    let data_record_count = parse_int(&header, 236, 8).unwrap_or(-1);
    let data_record_seconds = parse_double(&header, 244, 8).ok_or("Invalid data record duration seconds")?;
    let signal_count = parse_int(&header, 252, 4).ok_or("Invalid signal count")? as usize;

    if signal_count == 0 || header_bytes < 256 + signal_count * 256 {
        return Err("Invalid EDF signal header dimensions".to_string());
    }

    // Read the rest of the header (channel headers)
    let rest_header_len = header_bytes - 256;
    let mut signal_header = vec![0u8; rest_header_len];
    file.read_exact(&mut signal_header).map_err(|e| e.to_string())?;

    let ns = signal_count;
    let mut labels = Vec::with_capacity(ns);
    let mut physical_dimensions = Vec::with_capacity(ns);
    let mut physical_min = Vec::with_capacity(ns);
    let mut physical_max = Vec::with_capacity(ns);
    let mut digital_min = Vec::with_capacity(ns);
    let mut digital_max = Vec::with_capacity(ns);
    let mut samples_per_record = Vec::with_capacity(ns);

    let mut offset = 0;
    
    // Widths: label 16
    for i in 0..ns {
        labels.push(parse_ascii_string(&signal_header, offset + i * 16, 16));
    }
    offset += ns * 16;
    
    // Transducer type: 80
    offset += ns * 80;
    
    // Physical dimension: 8
    for i in 0..ns {
        physical_dimensions.push(parse_ascii_string(&signal_header, offset + i * 8, 8));
    }
    offset += ns * 8;
    
    // Physical minimum: 8
    for i in 0..ns {
        physical_min.push(parse_double(&signal_header, offset + i * 8, 8).unwrap_or(0.0));
    }
    offset += ns * 8;
    
    // Physical maximum: 8
    for i in 0..ns {
        physical_max.push(parse_double(&signal_header, offset + i * 8, 8).unwrap_or(0.0));
    }
    offset += ns * 8;
    
    // Digital minimum: 8
    for i in 0..ns {
        digital_min.push(parse_double(&signal_header, offset + i * 8, 8).unwrap_or(0.0));
    }
    offset += ns * 8;
    
    // Digital maximum: 8
    for i in 0..ns {
        digital_max.push(parse_double(&signal_header, offset + i * 8, 8).unwrap_or(0.0));
    }
    offset += ns * 8;
    
    // Prefiltering: 80
    offset += ns * 80;
    
    // Number of samples in each data record: 8
    for i in 0..ns {
        samples_per_record.push(parse_int(&signal_header, offset + i * 8, 8).unwrap_or(0) as usize);
    }

    let total_samples_per_record: usize = samples_per_record.iter().sum();

    // Determine number of records
    let metadata = file.metadata().map_err(|e| e.to_string())?;
    let file_len = metadata.len() as usize;
    
    let records = if data_record_count > 0 {
        data_record_count as usize
    } else {
        (file_len.saturating_sub(header_bytes)) / (total_samples_per_record * 2)
    };

    if records == 0 {
        return Err("EDF file contains no complete records".to_string());
    }

    // Filter which signal indexes to keep
    let mut kept_signal_indexes = Vec::new();
    for i in 0..ns {
        if is_display_signal(&labels[i]) && samples_per_record[i] > 0 && digital_max[i] != digital_min[i] {
            kept_signal_indexes.push(i);
        }
    }

    if kept_signal_indexes.is_empty() {
        return Err("EDF contains no displayable signal channels".to_string());
    }

    // Pre-allocate channels
    let mut channel_samples: Vec<Vec<f32>> = kept_signal_indexes
        .iter()
        .map(|&idx| vec![0.0f32; records * samples_per_record[idx]])
        .collect();

    // Move file cursor to data start (in case we did not read exactly up to header_bytes)
    file.seek(SeekFrom::Start(header_bytes as u64)).map_err(|e| e.to_string())?;
    // Buffer the record reads: one read syscall per (small) data record is
    // very slow on Windows, especially with antivirus / network drives.
    let mut file = BufReader::with_capacity(8 << 20, file);

    // Read records one by one
    let mut record_buffer = vec![0u8; total_samples_per_record * 2];

    for record in 0..records {
        if file.read_exact(&mut record_buffer).is_err() {
            break; // Finished reading or hit end of file mid-record
        }

        let mut buf_offset = 0;
        for chan in 0..ns {
            let samples = samples_per_record[chan];
            let gain = (physical_max[chan] - physical_min[chan]) / (digital_max[chan] - digital_min[chan]);
            let intercept = physical_min[chan] - gain * digital_min[chan];
            let is_volt_dim = physical_dimensions[chan].to_lowercase() == "v";

            if let Some(display_idx) = kept_signal_indexes.iter().position(|&x| x == chan) {
                let chan_out = &mut channel_samples[display_idx];
                let out_offset = record * samples;
                for s in 0..samples {
                    let b0 = record_buffer[buf_offset + s * 2];
                    let b1 = record_buffer[buf_offset + s * 2 + 1];
                    let digital = i16::from_le_bytes([b0, b1]) as f64;

                    let mut physical = digital * gain + intercept;
                    if scale_volts || is_volt_dim {
                        physical *= 1e6;
                    }
                    chan_out[out_offset + s] = physical as f32;
                }
            }
            buf_offset += samples * 2;
        }
    }

    // Pack into FFI-compatible structs
    let mut signals = Vec::with_capacity(kept_signal_indexes.len());
    for (display_idx, &orig_idx) in kept_signal_indexes.iter().enumerate() {
        let label_c = CString::new(labels[orig_idx].clone()).unwrap_or_else(|_| CString::new("").unwrap());
        let label_ptr = label_c.into_raw();

        let mut samples_vec = std::mem::take(&mut channel_samples[display_idx]);
        let sample_count = samples_vec.len() as i32;
        let samples_ptr = samples_vec.leak().as_mut_ptr();

        signals.push(EdfSignal {
            label: label_ptr,
            samples: samples_ptr,
            sample_count,
        });
    }

    let sample_rate = samples_per_record[kept_signal_indexes[0]] as f32 / f32::max(data_record_seconds as f32, 1e-9_f32);
    let signal_count_out = signals.len() as i32;
    let signals_ptr = signals.leak().as_mut_ptr();

    Ok(EdfFile {
        sample_rate_hz: sample_rate,
        signal_count: signal_count_out,
        signals: signals_ptr,
        duration_seconds: records as f32 * data_record_seconds as f32,
    })
}

#[no_mangle]
pub extern "C" fn sleep_eeg_load_edf(path: *const c_char, scale_volts: bool) -> *mut EdfFile {
    if path.is_null() {
        return std::ptr::null_mut();
    }
    let path_str = unsafe { CStr::from_ptr(path) };
    let Ok(path_str) = path_str.to_str() else {
        return std::ptr::null_mut();
    };

    match load_edf_impl(Path::new(path_str), scale_volts) {
        Ok(edf) => Box::into_raw(Box::new(edf)),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn sleep_eeg_free_edf(edf: *mut EdfFile) {
    if edf.is_null() {
        return;
    }
    unsafe {
        let edf = Box::from_raw(edf);
        if !edf.signals.is_null() && edf.signal_count > 0 {
            let signals = Vec::from_raw_parts(
                edf.signals,
                edf.signal_count as usize,
                edf.signal_count as usize,
            );
            for sig in signals {
                if !sig.label.is_null() {
                    let _ = CString::from_raw(sig.label);
                }
                if !sig.samples.is_null() && sig.sample_count > 0 {
                    let _ = Vec::from_raw_parts(
                        sig.samples,
                        sig.sample_count as usize,
                        sig.sample_count as usize,
                    );
                }
            }
        }
    }
}
