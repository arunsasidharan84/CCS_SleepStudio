use crate::events::{SlowWaveResults, SpindleResults};
use crate::pac::PacChannelResult;
use crate::pipeline::{CoreStageFeatures, LoadedRecording};
use anyhow::{Context, Result};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::Path;

pub type RegionalRow = BTreeMap<String, f64>;

const ARCHITECTURE_COLUMNS: [&str; 38] = [
    "TRT",
    "TST",
    "SPT",
    "WASO",
    "SOL",
    "Sleep_efficiency",
    "Sleep_Maintenance_Efficiency",
    "W_duration",
    "N1_duration",
    "N2_duration",
    "N3_duration",
    "R_duration",
    "NREM_duration",
    "N1_percentage",
    "N2_percentage",
    "N3_percentage",
    "R_percentage",
    "W_onset",
    "N1_onset",
    "N2_onset",
    "N3_onset",
    "R_onset",
    "W_longest_streak",
    "N1_longest_streak",
    "N2_longest_streak",
    "N3_longest_streak",
    "R_longest_streak",
    "W_mean_length_of_streak",
    "N1_mean_length_of_streak",
    "N2_mean_length_of_streak",
    "N3_mean_length_of_streak",
    "R_mean_length_of_streak",
    "W_median_length_of_streak",
    "N1_median_length_of_streak",
    "N2_median_length_of_streak",
    "N3_median_length_of_streak",
    "R_median_length_of_streak",
    "LZc",
];

fn feature_columns() -> Vec<String> {
    let mut output = Vec::new();
    for stage in ["N1", "N2", "N3", "REM"] {
        for suffix in ["PSD", "FOOOF"] {
            for band in [
                "Delta", "Theta", "Sigma", "Alpha", "Beta1", "Beta2", "Gamma1",
            ] {
                output.push(format!("{stage}_{band}_{suffix}"));
            }
        }
        for parameter in [
            "offset",
            "exponent",
            "cf_0",
            "pw_0",
            "bw_0",
            "cf_1",
            "pw_1",
            "bw_1",
            "error",
            "r_squared",
            "auc",
            "oscspectraledge",
        ] {
            output.push(format!("{stage}_{parameter}_FOOOF"));
        }
        for band in [
            "Delta", "Theta", "Sigma", "Alpha", "Beta1", "Beta2", "Gamma1",
        ] {
            output.push(format!("{stage}_{band}_Irasa"));
        }
        for parameter in ["intercept", "slope", "rsquared", "auc", "oscspectraledge"] {
            output.push(format!("{stage}_{parameter}_Irasa"));
        }
        for parameter in [
            "perm_entropy",
            "svd_entropy",
            "sample_entropy",
            "dfa",
            "petrosian",
            "katz",
            "higuchi",
            "lziv",
        ] {
            output.push(format!("{stage}_{parameter}_nonlinear"));
        }
        output.push(format!("{stage}_ACW"));
    }
    output
}

fn region(channel: &str) -> &'static str {
    let chan = channel.to_ascii_uppercase().trim().to_string();
    if chan == "PPG"
        || chan == "ECG"
        || chan == "EMG"
        || chan == "EOG"
        || chan == "REF"
        || chan == "GND"
    {
        return "NaN";
    }
    // Extract prefix of alphabetic characters
    let prefix: String = chan.chars().take_while(|c| c.is_alphabetic()).collect();

    match prefix.as_str() {
        "FP" | "FPZ" | "AF" | "AFZ" | "F" | "FZ" => "Frontal",
        "FC" | "FCZ" | "C" | "CZ" | "CP" | "CPZ" => "Central",
        "PO" | "POZ" | "O" | "OZ" => "Occipital",
        "FT" | "T" | "TP" | "M" | "A" => "Temporal",
        _ => {
            // Fallback substring/prefix checks
            if chan.contains("FP") || chan.contains("AF") || chan.starts_with('F') {
                "Frontal"
            } else if chan.contains("FC") || chan.contains("CP") || chan.starts_with('C') {
                "Central"
            } else if chan.contains("PO") || chan.starts_with('O') {
                "Occipital"
            } else if chan.contains("FT")
                || chan.contains("TP")
                || chan.starts_with('T')
                || chan.starts_with('M')
                || chan.starts_with('A')
            {
                "Temporal"
            } else {
                "NaN"
            }
        }
    }
}

fn mean(rows: &[&RegionalRow], column: &str) -> f64 {
    let values = rows
        .iter()
        .filter_map(|row| row.get(column).copied())
        .filter(|value| value.is_finite())
        .collect::<Vec<_>>();
    if values.is_empty() {
        f64::NAN
    } else {
        values.iter().sum::<f64>() / values.len() as f64
    }
}

fn event_density(count: usize, duration_minutes: f64) -> f64 {
    if duration_minutes.is_finite() && duration_minutes > 0.0 {
        count as f64 / duration_minutes
    } else {
        f64::NAN
    }
}

pub fn compile(
    recording: &LoadedRecording,
    core: Option<&CoreStageFeatures>,
    spindles: Option<&SpindleResults>,
    slow_waves: Option<&SlowWaveResults>,
    pac: Option<&BTreeMap<String, PacChannelResult>>,
    nlg: Option<&crate::nlg::NlgReport>,
    per_channel: bool,
    custom_regions: Option<&BTreeMap<String, String>>,
) -> BTreeMap<String, RegionalRow> {
    let spindle_by_channel = spindles
        .map(|s| s.summary.as_slice())
        .unwrap_or(&[])
        .iter()
        .map(|summary| (summary.channel.as_str(), summary))
        .collect::<BTreeMap<_, _>>();
    let slow_wave_by_channel = slow_waves
        .map(|s| s.summary.as_slice())
        .unwrap_or(&[])
        .iter()
        .map(|summary| (summary.channel.as_str(), summary))
        .collect::<BTreeMap<_, _>>();
    // SleepAnalysis.py pairs sorted channel labels with PAC values calculated
    // in raw channel order. Preserve this behavior for output parity.
    let mut sorted_channels = recording
        .edf
        .channels
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>();
    sorted_channels.sort();
    let pac_by_output_channel = sorted_channels
        .iter()
        .copied()
        .zip(recording.edf.channels.iter().map(|channel| pac.and_then(|p| p.get(channel))))
        .collect::<BTreeMap<_, _>>();
    let nrem_minutes = recording
        .architecture
        .values
        .get("N2_duration")
        .copied()
        .unwrap_or(0.0)
        + recording
            .architecture
            .values
            .get("N3_duration")
            .copied()
            .unwrap_or(0.0);
    let total_nrem_minutes = recording
        .architecture
        .values
        .get("NREM_duration")
        .copied()
        .unwrap_or(0.0);

    let mut channels = BTreeMap::<String, RegionalRow>::new();
    for channel in &recording.edf.channels {
        let spindle = spindle_by_channel.get(channel.as_str()).copied();
        let slow_wave = slow_wave_by_channel.get(channel.as_str()).copied();
        let pac_value = pac_by_output_channel.get(channel.as_str()).copied().flatten();
        let pac_or = |f: fn(&PacChannelResult) -> f64| pac_value.map_or(f64::NAN, f);
        let mut row = RegionalRow::from([
            (
                "sp_Count".into(),
                spindle.map_or(f64::NAN, |value| value.count as f64),
            ),
            (
                "sp_Duration".into(),
                spindle.map_or(f64::NAN, |value| value.duration),
            ),
            (
                "sp_Amplitude".into(),
                spindle.map_or(f64::NAN, |value| value.amplitude),
            ),
            (
                "sp_AmpFiltered".into(),
                spindle.map_or(f64::NAN, |value| value.amp_filtered),
            ),
            (
                "sp_RMS".into(),
                spindle.map_or(f64::NAN, |value| value.rms),
            ),
            (
                "sp_AbsPower".into(),
                spindle.map_or(f64::NAN, |value| value.abs_power),
            ),
            (
                "sp_RelPower".into(),
                spindle.map_or(f64::NAN, |value| value.rel_power),
            ),
            (
                "sp_Frequency".into(),
                spindle.map_or(f64::NAN, |value| value.frequency),
            ),
            (
                "sp_Oscillations".into(),
                spindle.map_or(f64::NAN, |value| value.oscillations),
            ),
            (
                "sp_Symmetry".into(),
                spindle.map_or(f64::NAN, |value| value.symmetry),
            ),
            (
                "sp_density".into(),
                spindle.map_or(f64::NAN, |value| event_density(value.count, nrem_minutes)),
            ),
            (
                "sw_all_Count".into(),
                slow_wave.map_or(f64::NAN, |value| value.count as f64),
            ),
            (
                "sw_all_density_calc".into(),
                slow_wave.map_or(f64::NAN, |value| {
                    event_density(value.count, total_nrem_minutes)
                }),
            ),
            (
                "sw_all_Duration".into(),
                slow_wave.map_or(f64::NAN, |value| value.duration),
            ),
            (
                "sw_all_ValNegPeak".into(),
                slow_wave.map_or(f64::NAN, |value| value.val_neg_peak),
            ),
            (
                "sw_all_ValPosPeak".into(),
                slow_wave.map_or(f64::NAN, |value| value.val_pos_peak),
            ),
            (
                "sw_all_PTP".into(),
                slow_wave.map_or(f64::NAN, |value| value.ptp),
            ),
            (
                "sw_all_Slope".into(),
                slow_wave.map_or(f64::NAN, |value| value.slope),
            ),
            (
                "sw_all_Frequency".into(),
                slow_wave.map_or(f64::NAN, |value| value.frequency),
            ),
            (
                "sw_all_PhaseAtSigmaPeak".into(),
                slow_wave.map_or(f64::NAN, |value| value.phase_at_sigma_peak),
            ),
            (
                "sw_all_ndPAC".into(),
                slow_wave.map_or(f64::NAN, |value| value.nd_pac),
            ),
            (
                "sw_all_MVL".into(),
                slow_wave.map_or(f64::NAN, |value| value.mvl),
            ),
            (
                "sw_all_PLV".into(),
                slow_wave.map_or(f64::NAN, |value| value.plv),
            ),
            (
                "sw_all_PhaseConsistency".into(),
                slow_wave.map_or(f64::NAN, |value| value.phase_consistency),
            ),
            ("pac_all_max_MI".into(), pac_or(|p| p.maximum)),
            ("pac_all_max_sp".into(), pac_or(|p| p.amplitude_frequency)),
            ("pac_all_max_sw".into(), pac_or(|p| p.phase_frequency)),
            ("pac_all_max_gcPAC".into(), pac_or(|p| p.maximum_gc)),
            ("pac_all_max_gc_sp".into(), pac_or(|p| p.amplitude_frequency_gc)),
            ("pac_all_max_gc_sw".into(), pac_or(|p| p.phase_frequency_gc)),
        ]);
        if let Some(values) = core.and_then(|c| c.channels.get(channel)) {
            row.extend(values.clone());
        }
        if let Some(bands) = nlg.and_then(|n| n.channels.get(channel)) {
            for (band, result) in bands {
                let Some(prefix) = nlg_prefix(band) else { continue };
                for (key, stat) in NLG_STATS {
                    row.insert(format!("NLG_{prefix}_{key}"), result.summary.get(*stat).copied().unwrap_or(f64::NAN));
                }
            }
        }
        channels.insert(channel.clone(), row);
    }

    if per_channel {
        return channels;
    }

    let resolve_region = |channel: &str| -> String {
        if let Some(map) = custom_regions {
            if let Some(r) = map.get(channel).or_else(|| map.get(&channel.to_ascii_uppercase())) {
                return r.clone();
            }
        }
        region(channel).to_string()
    };

    let mut region_names: BTreeSet<String> = BTreeSet::new();
    for ch in channels.keys() {
        let r = resolve_region(ch);
        if r != "NaN" {
            region_names.insert(r);
        }
    }
    if region_names.is_empty() {
        for r in ["Central", "Frontal", "Occipital", "Temporal"] {
            region_names.insert(r.to_string());
        }
    }

    let mut output = BTreeMap::new();
    for region_name in region_names {
        let selected = channels
            .iter()
            .filter_map(|(channel, row)| (resolve_region(channel) == region_name).then_some(row))
            .collect::<Vec<_>>();
        if selected.is_empty() {
            continue;
        }
        let mut row = RegionalRow::new();
        for column in event_columns().into_iter().chain(feature_columns()).chain(nlg_columns()) {
            row.insert(column.clone(), mean(&selected, &column));
        }
        output.insert(region_name, row);
    }
    output
}

/// NeuroLoopGain columns: (CSV suffix, summary key).
const NLG_STATS: &[(&str, &str)] = &[
    ("W", "W_mean"),
    ("N1", "N1_mean"),
    ("N2", "N2_mean"),
    ("N3", "N3_mean"),
    ("REM", "REM_mean"),
    ("NREM", "NREM_mean"),
    ("NREM_slope", "NREM_slope_per_hour"),
    ("index", "upper_quartile_index"),
    ("artifact_pct", "artifact_percent"),
    ("C1_NREM", "C1_NREM_mean"),
    ("C2_NREM", "C2_NREM_mean"),
    ("C3_NREM", "C3_NREM_mean"),
    ("C4_NREM", "C4_NREM_mean"),
    ("C5_NREM", "C5_NREM_mean"),
];

fn nlg_prefix(band: &str) -> Option<&'static str> {
    match band {
        "slow_wave" => Some("SW"),
        "sigma" => Some("Sigma"),
        "alpha" => Some("Alpha"),
        _ => None,
    }
}

fn nlg_columns() -> Vec<String> {
    let mut out = Vec::new();
    for prefix in ["SW", "Sigma", "Alpha"] {
        for (key, _) in NLG_STATS {
            out.push(format!("NLG_{prefix}_{key}"));
        }
    }
    out
}

fn event_columns() -> Vec<String> {
    [
        "sp_Count",
        "sp_Duration",
        "sp_Amplitude",
        "sp_AmpFiltered",
        "sp_RMS",
        "sp_AbsPower",
        "sp_RelPower",
        "sp_Frequency",
        "sp_Oscillations",
        "sp_Symmetry",
        "sp_density",
        "sw_all_Count",
        "sw_all_density_calc",
        "sw_all_Duration",
        "sw_all_ValNegPeak",
        "sw_all_ValPosPeak",
        "sw_all_PTP",
        "sw_all_Slope",
        "sw_all_Frequency",
        "sw_all_PhaseAtSigmaPeak",
        "sw_all_ndPAC",
        "sw_all_MVL",
        "sw_all_PLV",
        "sw_all_PhaseConsistency",
        "pac_all_max_MI",
        "pac_all_max_sp",
        "pac_all_max_sw",
        "pac_all_max_gcPAC",
        "pac_all_max_gc_sp",
        "pac_all_max_gc_sw",
    ]
    .into_iter()
    .map(str::to_string)
    .collect()
}

pub const STAGE_DYNAMICS_COLUMNS: [&str; 4] = [
    "SleepCycle_number",
    "Stage_transitions",
    "Stage_arousals",
    "ShortAwakenings",
];

pub const STAGE_CYCLE_COLUMNS: [&str; 19] = [
    "start_epoch",
    "end_epoch",
    "Sleep_duration_cycle",
    "Wake_duration_cycle",
    "N1_duration_cycle",
    "N2_duration_cycle",
    "N3_duration_cycle",
    "REM_duration_cycle",
    "Wake_percentage_cycle",
    "N1_percentage_cycle",
    "N2_percentage_cycle",
    "N3_percentage_cycle",
    "REM_percentage_cycle",
    "NREM_StageTransitions_cycle",
    "NREM_StageArousals_cycle",
    "NREM_ShortAwakenings_cycle",
    "REM_StageTransitions_cycle",
    "REM_StageArousals_cycle",
    "REM_ShortAwakenings_cycle",
];

fn stage_dynamics_columns() -> Vec<String> {
    let mut out: Vec<String> = STAGE_DYNAMICS_COLUMNS.iter().map(|&c| c.to_string()).collect();
    for cycle in 1..=5 {
        for c in STAGE_CYCLE_COLUMNS {
            out.push(format!("C{cycle}_{c}"));
        }
    }
    out
}

fn csv_escape(value: &str) -> String {
    if value.contains([',', '"', '\n']) {
        format!("\"{}\"", value.replace('"', "\"\""))
    } else {
        value.to_string()
    }
}

pub fn write_csv(
    path: &Path,
    recording_name: &str,
    recording: &LoadedRecording,
    rows: &BTreeMap<String, RegionalRow>,
) -> Result<()> {
    let mut columns = ARCHITECTURE_COLUMNS
        .iter()
        .map(|value| value.to_string())
        .collect::<Vec<_>>();
    columns.extend(["Subjname".into(), "Sessname".into(), "Chan".into()]);
    columns.extend(event_columns());
    columns.extend(feature_columns());
    columns.extend(nlg_columns());
    // Stage dynamics and sleep-cycle parameters: non-redundant full-night
    // dynamics plus the first five sleep cycles (without accs_ prefix).
    let stage_dyn_columns = stage_dynamics_columns();
    columns.extend(stage_dyn_columns.iter().cloned());
    // Write to a temporary file and rename it into place, so an interrupted
    // run never leaves a header-only CSV that looks complete.
    let tmp_path = path.with_extension("csv.partial");
    let mut writer = BufWriter::new(
        File::create(&tmp_path).with_context(|| format!("creating {}", tmp_path.display()))?,
    );
    writeln!(writer, "{}", columns.join(","))?;
    for (region, row) in rows {
        let mut values = Vec::with_capacity(columns.len());
        for column in ARCHITECTURE_COLUMNS {
            let value = recording.architecture.values.get(column).copied().unwrap_or(f64::NAN);
            values.push(if value.is_finite() { value.to_string() } else { String::new() });
        }
        values.push(csv_escape(recording_name));
        values.push(String::new());
        values.push(region.clone());
        for column in event_columns().into_iter().chain(feature_columns()).chain(nlg_columns()) {
            let value = row.get(&column).copied().unwrap_or(f64::NAN);
            values.push(if value.is_finite() {
                value.to_string()
            } else {
                String::new()
            });
        }
        for column in &stage_dyn_columns {
            let value = recording.architecture.values.get(column).copied().unwrap_or(f64::NAN);
            values.push(if value.is_finite() { value.to_string() } else { String::new() });
        }
        writeln!(writer, "{}", values.join(","))?;
    }
    writer.flush()?;
    drop(writer);
    std::fs::rename(&tmp_path, path).with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}

/// Columns that must hold at least one value for an analysis to count as
/// present in an existing regional CSV (used by `--skip-existing`).
pub fn marker_columns(analysis: &str) -> &'static [&'static str] {
    match analysis {
        "core" => &["N1_Delta_PSD", "N2_Delta_PSD", "N3_Delta_PSD", "REM_Delta_PSD"],
        "spindles" => &["sp_Count"],
        "slow_waves" => &["sw_all_Count"],
        "pac" => &["pac_all_max_MI"],
        "nlg" => &["NLG_SW_NREM", "NLG_Sigma_NREM", "NLG_Alpha_NREM", "NLG_SW_W", "NLG_Sigma_W"],
        _ => &[],
    }
}

/// True when `path` is a regional CSV with at least one data row and a value
/// for every requested analysis (an interrupted or older run is not complete).
pub fn is_complete(path: &Path, analyses: &[&str]) -> bool {
    let Ok(text) = std::fs::read_to_string(path) else { return false };
    let mut lines = text.lines().filter(|l| !l.trim().is_empty());
    let Some(header) = lines.next() else { return false };
    let columns: Vec<&str> = header.split(',').collect();
    let rows: Vec<Vec<&str>> = lines.map(|l| l.split(',').collect()).collect();
    if rows.is_empty() {
        return false;
    }
    analyses.iter().all(|analysis| {
        let wanted = marker_columns(analysis);
        wanted.is_empty()
            || wanted.iter().any(|name| {
                columns.iter().position(|c| c == name).is_some_and(|i| {
                    rows.iter().any(|r| r.get(i).is_some_and(|v| !v.trim().is_empty()))
                })
            })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_region_mapping() {
        assert_eq!(region("F3"), "Frontal");
        assert_eq!(region("F4"), "Frontal");
        assert_eq!(region("AF7"), "Frontal");
        assert_eq!(region("AF8"), "Frontal");
        assert_eq!(region("Fp1"), "Frontal");
        assert_eq!(region("C3"), "Central");
        assert_eq!(region("C4"), "Central");
        assert_eq!(region("Ch3"), "Central");
        assert_eq!(region("O1"), "Occipital");
        assert_eq!(region("O2"), "Occipital");
        assert_eq!(region("M1"), "Temporal");
        assert_eq!(region("M2"), "Temporal");
        assert_eq!(region("A1"), "Temporal");
        assert_eq!(region("PPG"), "NaN");
        assert_eq!(region("ECG"), "NaN");
        assert_eq!(region("REF"), "NaN");
    }

    #[test]
    fn event_density_normalizes_count_by_minutes() {
        assert_eq!(event_density(120, 60.0), 2.0);
        assert!(event_density(120, 0.0).is_nan());
        assert!(event_density(120, f64::NAN).is_nan());
        assert!(event_columns().contains(&"sw_all_density_calc".to_string()));
    }
}
