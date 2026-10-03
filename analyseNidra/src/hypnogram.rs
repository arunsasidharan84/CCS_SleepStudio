use anyhow::{Context, Result, bail};
use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeMap;
use std::fs::File;
use std::path::Path;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub enum Stage {
    Wake,
    N1,
    N2,
    N3,
    Rem,
    Unscored,
}

impl Stage {
    pub fn code(self) -> i8 {
        match self {
            Self::Unscored => -2,
            Self::Wake => 0,
            Self::N1 => 1,
            Self::N2 => 2,
            Self::N3 => 3,
            Self::Rem => 4,
        }
    }

    fn parse(value: &str) -> Result<Self> {
        match value.trim().to_ascii_uppercase().as_str() {
            "WAKE" | "W" => Ok(Self::Wake),
            "N1" => Ok(Self::N1),
            "N2" => Ok(Self::N2),
            "N3" => Ok(Self::N3),
            "REM" | "R" => Ok(Self::Rem),
            "INCONCLUSIVE" | "NONE" | "UNSCORED" | "UNKNOWN" | "?" | "UNCERTAIN" | "UNCERTAINTY" | "NOT SCORED" | "UNS" | "" | "-" | "N/A" => Ok(Self::Unscored),
            other => bail!("unsupported sleep stage {other:?}"),
        }
    }
}

#[derive(Deserialize)]
struct EpochRecord {
    stage: Option<String>,
}

pub fn read_sleepgpt(path: &Path) -> Result<Vec<Stage>> {
    let value: Value = serde_json::from_reader(
        File::open(path).with_context(|| format!("opening {}", path.display()))?,
    )
    .with_context(|| format!("parsing {}", path.display()))?;

    let records_value = match value {
        Value::Array(mut outer)
            if !outer.is_empty() && matches!(outer.first(), Some(Value::Array(_))) =>
        {
            outer.remove(0)
        }
        Value::Array(records) => Value::Array(records),
        _ => bail!("sleep scoring root must be an array"),
    };
    let Value::Array(records) = records_value else {
        bail!("sleep scoring epochs must be an array")
    };

    records
        .into_iter()
        .enumerate()
        .map(|(index, record)| {
            let record: EpochRecord = serde_json::from_value(record)
                .with_context(|| format!("invalid scoring epoch {}", index + 1))?;
            match record.stage {
                Some(stage) => Stage::parse(&stage),
                None => Ok(Stage::Unscored),
            }
        })
        .collect()
}

pub fn upsample(stages: &[Stage], sfreq: f64, n_samples: usize) -> Vec<i8> {
    upsample_with_epoch_sec(stages, sfreq, n_samples, 30.0)
}

pub fn upsample_with_epoch_sec(
    stages: &[Stage],
    sfreq: f64,
    n_samples: usize,
    epoch_length_sec: f64,
) -> Vec<i8> {
    let samples_per_epoch = (epoch_length_sec * sfreq).round() as usize;
    let mut output = Vec::with_capacity(n_samples);
    for stage in stages {
        output.extend(std::iter::repeat_n(stage.code(), samples_per_epoch));
        if output.len() >= n_samples {
            output.truncate(n_samples);
            return output;
        }
    }
    output.resize(n_samples, Stage::Unscored.code());
    output
}

#[derive(Debug, Clone)]
pub struct SleepArchitecture {
    pub values: BTreeMap<String, f64>,
}

fn median(values: &mut [f64]) -> f64 {
    values.sort_by(f64::total_cmp);
    let n = values.len();
    if n % 2 == 0 {
        (values[n / 2 - 1] + values[n / 2]) / 2.0
    } else {
        values[n / 2]
    }
}

#[derive(Debug, Clone, Copy)]
pub struct ArchitectureWindow {
    pub recording_minutes: f64,
    pub lights_off_minutes: f64,
    pub lights_on_minutes: f64,
}

impl ArchitectureWindow {
    pub fn from_seconds(
        recording_seconds: f64,
        lights_off_seconds: Option<f64>,
        lights_on_seconds: Option<f64>,
    ) -> Self {
        let recording_seconds = recording_seconds.max(0.0);
        let off = lights_off_seconds
            .unwrap_or(0.0)
            .clamp(0.0, recording_seconds);
        let on = lights_on_seconds
            .unwrap_or(recording_seconds)
            .clamp(off, recording_seconds);
        Self {
            recording_minutes: recording_seconds / 60.0,
            lights_off_minutes: off / 60.0,
            lights_on_minutes: on / 60.0,
        }
    }

    pub fn from_scoring_minutes(scoring_minutes: f64) -> Self {
        let scoring_minutes = scoring_minutes.max(0.0);
        Self {
            recording_minutes: scoring_minutes,
            lights_off_minutes: 0.0,
            lights_on_minutes: scoring_minutes,
        }
    }

    pub fn trt_minutes(self) -> f64 {
        (self.lights_on_minutes - self.lights_off_minutes).max(0.0)
    }
}

pub fn sleep_architecture(input: &[Stage], window: ArchitectureWindow) -> SleepArchitecture {
    sleep_architecture_with_epoch_sec(input, window, 30.0)
}

pub fn sleep_architecture_with_epoch_sec(
    input: &[Stage],
    window: ArchitectureWindow,
    epoch_length_sec: f64,
) -> SleepArchitecture {
    let trailing_wake = input
        .iter()
        .rev()
        .take_while(|&&stage| stage == Stage::Wake)
        .count();
    let trim = trailing_wake.saturating_sub(10);
    let stages = &input[..input.len().saturating_sub(trim)];
    let epoch_minutes = epoch_length_sec / 60.0;
    let labels = [
        ("W", Stage::Wake),
        ("N1", Stage::N1),
        ("N2", Stage::N2),
        ("N3", Stage::N3),
        ("R", Stage::Rem),
    ];
    let mut values = BTreeMap::new();
    let scored_duration = stages.len() as f64 * epoch_minutes;
    let trt = window.trt_minutes();
    values.insert("TRT".into(), trt);
    values.insert("Recording_duration".into(), window.recording_minutes);
    values.insert("Lights_off".into(), window.lights_off_minutes);
    values.insert("Lights_on".into(), window.lights_on_minutes);
    values.insert("Scored_duration".into(), scored_duration);
    values.insert("Unscored_duration".into(), (trt - scored_duration).max(0.0));

    let first_sleep = stages
        .iter()
        .position(|&stage| matches!(stage, Stage::N1 | Stage::N2 | Stage::N3 | Stage::Rem))
        .unwrap_or(stages.len());
    let sleep_onset_minutes = first_sleep as f64 * epoch_minutes;
    let sol = (sleep_onset_minutes - window.lights_off_minutes).max(0.0);
    let spt = (window.lights_on_minutes - sleep_onset_minutes).max(0.0);
    values.insert("Sleep_onset".into(), sleep_onset_minutes);
    values.insert("SOL".into(), sol);
    values.insert("SPT".into(), spt);

    let mut durations = BTreeMap::new();
    for (label, stage) in labels {
        let onset = stages
            .iter()
            .position(|&item| item == stage)
            .map(|index| index as f64 * epoch_minutes)
            .unwrap_or(f64::NAN);
        values.insert(
            format!("{label}_onset"),
            if stage == Stage::Rem && onset.is_finite() {
                onset - sol
            } else {
                onset
            },
        );
        let duration = stages.iter().filter(|&&item| item == stage).count() as f64 * epoch_minutes;
        values.insert(format!("{label}_duration"), duration);
        durations.insert(stage.code(), duration);
    }

    let nrem = durations[&1] + durations[&2] + durations[&3];
    let tst = nrem + durations[&4];
    values.insert("NREM_duration".into(), nrem);
    values.insert("TST".into(), tst);
    values.insert("WASO".into(), spt - tst);
    values.insert(
        "Sleep_efficiency".into(),
        if trt > 0.0 {
            tst / trt * 100.0
        } else {
            f64::NAN
        },
    );
    values.insert(
        "Sleep_Maintenance_Efficiency".into(),
        if spt > 0.0 {
            tst / spt * 100.0
        } else {
            f64::NAN
        },
    );
    for (label, stage) in labels {
        if stage != Stage::Wake {
            let duration = durations[&stage.code()];
            values.insert(
                format!("{label}_percentage"),
                if spt > 0.0 && duration > 0.0 {
                    (duration / spt * 100.0 * 100.0).round() / 100.0
                } else {
                    f64::NAN
                },
            );
        }
    }

    let mut runs: BTreeMap<i8, Vec<f64>> = BTreeMap::new();
    let mut start = 0;
    while start < stages.len() {
        let stage = stages[start];
        let mut end = start + 1;
        while end < stages.len() && stages[end] == stage {
            end += 1;
        }
        runs.entry(stage.code())
            .or_default()
            .push((end - start) as f64 * epoch_minutes);
        start = end;
    }
    for (label, stage) in labels {
        let stage_runs = runs.get(&stage.code());
        let (longest, mean, med) = if let Some(stage_runs) = stage_runs {
            let longest = stage_runs.iter().copied().fold(f64::NEG_INFINITY, f64::max);
            let mean = stage_runs.iter().sum::<f64>() / stage_runs.len() as f64;
            let mut copy = stage_runs.clone();
            (longest, mean, median(&mut copy))
        } else {
            (f64::NAN, f64::NAN, f64::NAN)
        };
        values.insert(format!("{label}_longest_streak"), longest);
        values.insert(format!("{label}_mean_length_of_streak"), mean);
        values.insert(format!("{label}_median_length_of_streak"), med);
    }
    let stage_text = stages
        .iter()
        .map(|stage| match stage {
            Stage::Wake => "W",
            Stage::N1 => "N1",
            Stage::N2 => "N2",
            Stage::N3 => "N3",
            Stage::Rem => "R",
            Stage::Unscored => "",
        })
        .collect::<String>();
    let symbols: Vec<u32> = stage_text.chars().map(|value| value as u32).collect();
    values.insert("LZc".into(), crate::nonlinear::normalized_lz(&symbols));
    SleepArchitecture { values }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn trims_terminal_wake_like_hypnofunk() {
        let mut stages = vec![Stage::Wake; 4];
        stages.extend(vec![Stage::N2; 20]);
        stages.extend(vec![Stage::Wake; 20]);
        let result = sleep_architecture(&stages, ArchitectureWindow::from_scoring_minutes(17.0));
        assert_eq!(result.values["TRT"], 17.0);
        assert_eq!(result.values["TST"], 10.0);
        assert_eq!(result.values["Scored_duration"], 17.0);
    }

    #[test]
    fn accepts_null_unscored_epoch() {
        let path = std::env::temp_dir().join(format!(
            "analyse_nidra_null_stage_{}.json",
            std::process::id()
        ));
        fs::write(
            &path,
            r#"[[{"epoch":1,"stage":"Wake"},{"epoch":2,"stage":null}],[]]"#,
        )
        .unwrap();
        let stages = read_sleepgpt(&path).unwrap();
        fs::remove_file(path).ok();
        assert_eq!(stages, vec![Stage::Wake, Stage::Unscored]);
    }
}
