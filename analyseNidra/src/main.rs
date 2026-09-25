use analyse_nidra::events;
use analyse_nidra::pac;
use analyse_nidra::pipeline;
use analyse_nidra::regional;
use anyhow::{Context, Result, bail};
use std::collections::{BTreeMap, HashSet};
use std::env;
use std::ffi::OsString;
use std::fs::File;
use std::path::{Path, PathBuf};
use std::time::Instant;

const VERSION: &str = "1.22.0";

const USAGE: &str = "usage: analyse-nidra <recording.edf> <scoring.json> \
[core.json|-] [pac.json|-] [slow-waves.json|-] [spindles.json|-] [regional.csv|-] \
[--out-dir <path>] [--channels F3,F4,C3,C4,O1,O2] [--references M1,M2] \
[--lights-off-sec SEC] [--lights-on-sec SEC] [--per-channel] [--region-map <json_or_file>] \
[--analyses core,pac,slow_waves,spindles,nlg | --skip <list>] [--nlg-out <nlg.json>] [--nlg-bands slow_wave,sigma[,alpha]] \
[--nlg-smooth-rate 0.01666] [--nlg-undersample N] [--nlg-edf-dir DIR] [--version]\n\
   or: analyse-nidra --preprocess <recording.edf> [--out-dir <dir>] [--steps <stimartifact,filter,badchannel,interpolate,gedai,save>] \
[--downsample-hz <hz>] [--bandpass-lo <lo>] [--bandpass-hi <hi>] [--notch-hz <notch>] [--suffix <_clean>] \
[--stim-f0 <hz>] [--stim-win <sec>] [--stim-max-combs <n>]\n\
   or: analyse-nidra --stage <recording.edf> [--algorithm <yasa|luna|sleeptransformer|gssc|tinysleepnet|seqsleepnet|usleep|dreamento|sleepeegpy>] (default yasa + sleepgpt) \
[--sequence-correction <none|sleepgpt>] [--eeg C4,C3] [--ref M1,M2] [--eog E1,E2] [--emg Chin1,Chin2] [--out <output.json>] [--out-dir <dir>] \
[--sleepgpt-alpha <0.1>] [--sleepgpt-ngram <30>]\n\
   or: analyse-nidra --apply-sleepgpt <scoring.json> [--out <output.json>] [--alpha <0.1>] [--ngram <30>]\n\
   or: analyse-nidra --respiratory <recording.edf> [--scoring <s.json>] [--thermal ch] [--pressure ch] [--flow ch] [--thorax ch] \
[--abdomen ch] [--effort-sum ch] [--spo2 ch] [--pulse ch] [--ecg ch] [--snore ch] [--position ch] [--supine-codes 6] \
[--eeg C4-M1] [--chin ch] [--hypopnea-rule 3|4] [--auto-arousals yes|no] [--out <r.json>]\n\
   or: analyse-nidra --plm <recording.edf> [--scoring <s.json>] [--left ch] [--right ch] [--respiratory-json <r.json>] \
[--standard aasm|wasm] [--eeg C4-M1] [--auto-arousals yes|no] [--onset-uv 8] [--offset-uv 2] [--out <p.json>]\n\
   or: analyse-nidra --cap <recording.edf> --scoring <s.json> [--eeg C4-M1] [--respiratory-json <r.json>] \
[--plm-json <p.json>] [--arousals prefer-manual|none] [--sensitivity conservative|standard|sensitive] \
[--a-phases prefer-manual|manual|auto] [--out <c.json>]\n\
   or: analyse-nidra --nlg <recording.edf> [--scoring s.json] [--eeg C4,C3] [--references M1,M2] [--bands slow_wave,sigma] \
[--smooth-rate 0.01666] [--undersample N] [--edf-dir DIR] [--out <n.json>]\n\
   or: analyse-nidra --list-signals <recording.edf>";

#[derive(Debug)]
struct Cli {
    edf_path: PathBuf,
    scoring_path: PathBuf,
    /// Positional output paths; length is always 5 after parsing (may be None).
    outputs: Vec<Option<PathBuf>>,
    out_dir: Option<PathBuf>,
    channels: Vec<String>,
    references: Vec<String>,
    lights_off_seconds: Option<f64>,
    lights_on_seconds: Option<f64>,
    per_channel: bool,
    region_map: Option<BTreeMap<String, String>>,
    /// Analyses to run (core, pac, slow_waves, spindles, nlg).
    analyses: HashSet<String>,
    nlg_out: Option<PathBuf>,
    nlg: NlgCli,
    skip_existing: bool,
}

#[derive(Debug, Clone)]
struct NlgCli {
    bands: Vec<String>,
    smooth_rate: f64,
    undersampler: i32,
    lp_hz: Option<f64>,
    edf_dir: Option<PathBuf>,
    keep_series: bool,
}

impl Default for NlgCli {
    fn default() -> Self {
        Self {
            bands: vec!["slow_wave".into(), "sigma".into()],
            smooth_rate: 0.01666,
            undersampler: 0,
            lp_hz: None,
            edf_dir: None,
            keep_series: true,
        }
    }
}

impl NlgCli {
    fn options(&self) -> Result<analyse_nidra::nlg::NlgOptions> {
        let bands = self
            .bands
            .iter()
            .map(|b| analyse_nidra::nlg::NlgBand::parse(b, self.smooth_rate))
            .collect::<Result<Vec<_>>>()?;
        if bands.is_empty() {
            bail!("--nlg-bands needs at least one band");
        }
        Ok(analyse_nidra::nlg::NlgOptions {
            bands,
            undersampler: self.undersampler,
            lp_hz: self.lp_hz,
            keep_series: self.keep_series,
            write_edf_dir: self.edf_dir.clone(),
        })
    }

    /// Handles one `--nlg-*` option; returns false when `key` is not one.
    fn accept(&mut self, key: &str, value: &mut dyn FnMut() -> Option<String>) -> Result<bool> {
        match key {
            "--nlg-bands" => {
                self.bands = split_channel_arg(&value().context("--nlg-bands requires a value")?);
            }
            "--nlg-smooth-rate" => {
                self.smooth_rate = value().context("--nlg-smooth-rate requires a value")?.parse()?;
            }
            "--nlg-undersample" => {
                self.undersampler = value().context("--nlg-undersample requires a value")?.parse()?;
            }
            "--nlg-lp" => {
                self.lp_hz = Some(value().context("--nlg-lp requires a value")?.parse()?);
            }
            "--nlg-edf-dir" => {
                self.edf_dir = value().map(PathBuf::from);
            }
            "--nlg-no-series" => self.keep_series = false,
            _ => return Ok(false),
        }
        Ok(true)
    }
}

pub const ALL_ANALYSES: [&str; 5] = ["core", "pac", "slow_waves", "spindles", "nlg"];

fn parse_analyses(value: &str) -> Result<HashSet<String>> {
    let mut out = HashSet::new();
    for item in value.split(',').map(|v| v.trim().to_ascii_lowercase()).filter(|v| !v.is_empty()) {
        let canonical = match item.as_str() {
            "all" => {
                out.extend(ALL_ANALYSES.iter().map(|v| v.to_string()));
                continue;
            }
            "core" | "features" | "spectral" => "core",
            "pac" | "coupling" => "pac",
            "slow_waves" | "slowwaves" | "sw" => "slow_waves",
            "spindles" | "sp" => "spindles",
            "nlg" | "neuroloopgain" => "nlg",
            other => bail!("unknown analysis '{other}' (use {})", ALL_ANALYSES.join(",")),
        };
        out.insert(canonical.to_string());
    }
    Ok(out)
}

fn parse_region_map(value: OsString) -> Result<BTreeMap<String, String>> {
    let raw = value
        .into_string()
        .map_err(|_| anyhow::anyhow!("--region-map must be valid UTF-8"))?;
    let content = if Path::new(&raw).exists() {
        std::fs::read_to_string(&raw)
            .with_context(|| format!("reading region map file: {raw}"))?
    } else {
        raw
    };
    let parsed: serde_json::Value = serde_json::from_str(&content)
        .with_context(|| "parsing --region-map JSON")?;
    let mut map = BTreeMap::new();
    if let serde_json::Value::Object(obj) = parsed {
        for (k, v) in obj {
            match v {
                serde_json::Value::String(region_name) => {
                    map.insert(k.to_ascii_uppercase(), region_name);
                }
                serde_json::Value::Array(chans) => {
                    for chan in chans {
                        if let Some(ch_str) = chan.as_str() {
                            map.insert(ch_str.to_ascii_uppercase(), k.clone());
                        }
                    }
                }
                _ => {}
            }
        }
    }
    Ok(map)
}

fn channel_list(value: OsString, option: &str, allow_empty: bool) -> Result<Vec<String>> {
    let value = value
        .into_string()
        .map_err(|_| anyhow::anyhow!("{option} must be valid UTF-8"))?;
    let channels = value
        .split(',')
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| {
            if value.eq_ignore_ascii_case("A1") {
                "M1".to_string()
            } else if value.eq_ignore_ascii_case("A2") {
                "M2".to_string()
            } else {
                value.to_string()
            }
        })
        .collect::<Vec<_>>();
    if channels.is_empty() && !allow_empty {
        bail!("{option} requires at least one channel");
    }
    let mut unique = HashSet::new();
    if channels
        .iter()
        .any(|channel| !unique.insert(channel.to_ascii_lowercase()))
    {
        bail!("{option} contains duplicate channels");
    }
    Ok(channels)
}

fn parse_seconds(value: OsString, option: &str) -> Result<f64> {
    let value = value
        .into_string()
        .map_err(|_| anyhow::anyhow!("{option} must be valid UTF-8"))?;
    let seconds = value
        .parse::<f64>()
        .with_context(|| format!("{option} must be a number of seconds"))?;
    if !seconds.is_finite() || seconds < 0.0 {
        bail!("{option} must be a finite non-negative number");
    }
    Ok(seconds)
}

fn parse_cli(arguments: impl IntoIterator<Item = OsString>) -> Result<Cli> {
    let mut positionals = Vec::new();
    let mut channels = None;
    let mut references = None;
    let mut lights_off_seconds = None;
    let mut lights_on_seconds = None;
    let mut out_dir: Option<PathBuf> = None;
    let mut per_channel = false;
    let mut region_map = None;
    let mut analyses: Option<HashSet<String>> = None;
    let mut nlg_out: Option<PathBuf> = None;
    let mut nlg = NlgCli::default();
    let mut skip_existing = false;
    let mut arguments = arguments.into_iter();
    while let Some(argument) = arguments.next() {
        let text = argument.to_string_lossy().to_string();
        let (key, inline) = match text.split_once('=') {
            Some((k, v)) if k.starts_with("--nlg") || k == "--analyses" || k == "--skip" => {
                (k.to_string(), Some(v.to_string()))
            }
            _ => (text.clone(), None),
        };
        {
            let mut next_value = || inline.clone().or_else(|| arguments.next().map(|v| v.to_string_lossy().to_string()));
            if key == "--analyses" {
                analyses = Some(parse_analyses(&next_value().context("--analyses requires a list")?)?);
                continue;
            }
            if key == "--skip" {
                let skip = parse_analyses(&next_value().context("--skip requires a list")?)?;
                let base = analyses.take().unwrap_or_else(|| ALL_ANALYSES.iter().map(|v| v.to_string()).collect());
                analyses = Some(base.difference(&skip).cloned().collect());
                continue;
            }
            if key == "--nlg-out" {
                nlg_out = next_value().map(PathBuf::from);
                continue;
            }
            if nlg.accept(&key, &mut next_value)? {
                continue;
            }
        }
        if argument == "--version" {
            println!("analyse-nidra {VERSION}");
            std::process::exit(0);
        } else if argument == "--channels" {
            let value = arguments
                .next()
                .context("--channels requires a comma-separated value")?;
            channels = Some(channel_list(value, "--channels", false)?);
        } else if argument == "--references" {
            let value = arguments
                .next()
                .context("--references requires a comma-separated value")?;
            references = Some(channel_list(value, "--references", true)?);
        } else if argument == "--lights-off-sec" {
            let value = arguments
                .next()
                .context("--lights-off-sec requires a value")?;
            lights_off_seconds = Some(parse_seconds(value, "--lights-off-sec")?);
        } else if argument == "--lights-on-sec" {
            let value = arguments
                .next()
                .context("--lights-on-sec requires a value")?;
            lights_on_seconds = Some(parse_seconds(value, "--lights-on-sec")?);
        } else if argument == "--out-dir" {
            let value = arguments
                .next()
                .context("--out-dir requires a path argument")?;
            out_dir = Some(PathBuf::from(value));
        } else if argument == "--per-channel" || argument == "--no-grouping" {
            per_channel = true;
        } else if argument == "--skip-existing" || argument == "--resume" {
            skip_existing = true;
        } else if argument == "--region-map" {
            let value = arguments
                .next()
                .context("--region-map requires a JSON string or file path")?;
            region_map = Some(parse_region_map(value)?);
        } else if let Some(value) = argument
            .to_str()
            .and_then(|value| value.strip_prefix("--channels="))
        {
            channels = Some(channel_list(value.into(), "--channels", false)?);
        } else if let Some(value) = argument
            .to_str()
            .and_then(|value| value.strip_prefix("--references="))
        {
            references = Some(channel_list(value.into(), "--references", true)?);
        } else if let Some(value) = argument
            .to_str()
            .and_then(|value| value.strip_prefix("--lights-off-sec="))
        {
            lights_off_seconds = Some(parse_seconds(value.into(), "--lights-off-sec")?);
        } else if let Some(value) = argument
            .to_str()
            .and_then(|value| value.strip_prefix("--lights-on-sec="))
        {
            lights_on_seconds = Some(parse_seconds(value.into(), "--lights-on-sec")?);
        } else if let Some(value) = argument
            .to_str()
            .and_then(|value| value.strip_prefix("--out-dir="))
        {
            out_dir = Some(PathBuf::from(value));
        } else if let Some(value) = argument
            .to_str()
            .and_then(|value| value.strip_prefix("--region-map="))
        {
            region_map = Some(parse_region_map(value.into())?);
        } else if argument.to_string_lossy().starts_with("--") {
            bail!("unknown option: {}", argument.to_string_lossy());
        } else {
            positionals.push(argument);
        }
    }
    if !(2..=7).contains(&positionals.len()) {
        bail!(USAGE);
    }

    // Friendly hint when no output paths have been given.
    if positionals.len() == 2 && out_dir.is_none() {
        eprintln!(
            "note: no output files specified and --out-dir not set; \
pass output paths after the scoring file or use --out-dir <path> \
to write results automatically"
        );
    }

    let edf_path = PathBuf::from(positionals.remove(0));
    let scoring_path = PathBuf::from(positionals.remove(0));
    let optional_path = |value: OsString| (value != "-").then(|| PathBuf::from(value));
    let mut outputs = positionals
        .into_iter()
        .map(optional_path)
        .collect::<Vec<_>>();
    outputs.resize_with(5, || None);

    // Apply --out-dir defaults for any output slot that was not explicitly provided.
    if let Some(ref dir) = out_dir {
        let stem = edf_path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("recording");

        // (slot index, name suffix, extension)
        let slots: &[(usize, &str, &str)] = &[
            (0, "core", "json"),
            (1, "pac", "json"),
            (2, "slow_waves", "json"),
            (3, "spindles", "json"),
            (4, "regional", "csv"),
        ];

        for &(idx, name, ext) in slots {
            if outputs[idx].is_none() {
                outputs[idx] = Some(dir.join(format!("{stem}_analyse_{name}.{ext}")));
            }
        }
        if nlg_out.is_none() {
            nlg_out = Some(dir.join(format!("{stem}_analyse_nlg.json")));
        }
    }

    Ok(Cli {
        edf_path,
        scoring_path,
        outputs,
        out_dir,
        channels: channels.unwrap_or_else(|| {
            analyse_nidra::DEFAULT_CHANNELS
                .iter()
                .map(|value| value.to_string())
                .collect()
        }),
        references: references.unwrap_or_else(|| {
            analyse_nidra::DEFAULT_REFERENCES
                .iter()
                .map(|value| value.to_string())
                .collect()
        }),
        lights_off_seconds,
        lights_on_seconds,
        per_channel,
        region_map,
        analyses: analyses.unwrap_or_else(|| ALL_ANALYSES.iter().map(|v| v.to_string()).collect()),
        nlg_out,
        nlg,
        skip_existing,
    })
}

fn handle_preprocess_cli(args: impl IntoIterator<Item = OsString>) -> Result<()> {
    let mut edf_path: Option<PathBuf> = None;
    let mut out_dir: Option<PathBuf> = None;
    let mut steps = None;
    let mut downsample_hz = Some(250.0);
    let mut bandpass_lo = 0.5;
    let mut bandpass_hi = 40.0;
    let mut notch_hz = Some(50.0);
    let mut ransac_thresh = 0.80;
    let mut eeg_channels = None;
    let mut suffix = "_clean".to_string();
    let mut stim = analyse_nidra::cleaning::stim_artifact::StimArtifactConfig::default();

    let mut it = args.into_iter();
    while let Some(arg) = it.next() {
        let s = arg.to_string_lossy();
        if s == "--preprocess" {
            if let Some(val) = it.next() {
                if !val.to_string_lossy().starts_with("--") {
                    edf_path = Some(PathBuf::from(val));
                }
            }
        } else if let Some(val) = s.strip_prefix("--preprocess=") {
            edf_path = Some(PathBuf::from(val));
        } else if s == "--out-dir" {
            out_dir = it.next().map(PathBuf::from);
        } else if let Some(val) = s.strip_prefix("--out-dir=") {
            out_dir = Some(PathBuf::from(val));
        } else if s == "--steps" {
            if let Some(val) = it.next() {
                steps = Some(val.to_string_lossy().split(',').map(|x| x.trim().to_string()).collect());
            }
        } else if s == "--downsample-hz" {
            if let Some(val) = it.next() {
                downsample_hz = val.to_string_lossy().parse().ok();
            }
        } else if s == "--bandpass-lo" {
            if let Some(val) = it.next() {
                bandpass_lo = val.to_string_lossy().parse().unwrap_or(0.5);
            }
        } else if s == "--bandpass-hi" {
            if let Some(val) = it.next() {
                bandpass_hi = val.to_string_lossy().parse().unwrap_or(40.0);
            }
        } else if s == "--notch-hz" {
            if let Some(val) = it.next() {
                let n: f64 = val.to_string_lossy().parse().unwrap_or(50.0);
                notch_hz = if n > 0.0 { Some(n) } else { None };
            }
        } else if s == "--bad-channel-threshold" || s == "--ransac-thresh" {
            if let Some(val) = it.next() {
                ransac_thresh = val.to_string_lossy().parse().unwrap_or(0.80);
            }
        } else if s == "--eeg-channels" {
            if let Some(val) = it.next() {
                eeg_channels = Some(val.to_string_lossy().split(',').map(|x| x.trim().to_string()).collect());
            }
        } else if s == "--suffix" {
            if let Some(val) = it.next() {
                suffix = val.to_string_lossy().to_string();
            }
        } else if s == "--stim-f0" {
            if let Some(val) = it.next() {
                stim.f0_hz = val.to_string_lossy().parse().ok().filter(|v: &f64| *v > 0.0);
            }
        } else if s == "--stim-win" {
            if let Some(val) = it.next() {
                stim.win_sec = val.to_string_lossy().parse().unwrap_or(20.0);
            }
        } else if s == "--stim-max-combs" {
            if let Some(val) = it.next() {
                stim.max_families = val.to_string_lossy().parse().unwrap_or(3);
            }
        } else if !s.starts_with("--") && edf_path.is_none() {
            edf_path = Some(PathBuf::from(arg));
        }
    }

    let edf_path = edf_path.context("No input EDF file specified for --preprocess")?;
    let out_dir = out_dir.unwrap_or_else(|| edf_path.parent().unwrap_or(Path::new(".")).to_path_buf());

    let mut cfg = analyse_nidra::cleaning::PreprocessingPipelineConfig::default();
    if let Some(st) = steps {
        cfg.steps = st;
    }
    cfg.downsample_freq = downsample_hz;
    cfg.filter_bandpass = (bandpass_lo, bandpass_hi);
    cfg.notch_freq = notch_hz;
    cfg.ransac_corr_thresh = ransac_thresh;
    cfg.eeg_channels = eeg_channels;
    cfg.suffix = suffix;
    cfg.stim = stim;

    analyse_nidra::cleaning::run_preprocessing(&edf_path, &out_dir, &cfg)?;
    Ok(())
}

fn split_channel_arg(value: &str) -> Vec<String> {
    value
        .split(',')
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
        .collect()
}

fn handle_stage_cli(args: impl IntoIterator<Item = OsString>) -> Result<()> {
    let mut edf_path: Option<PathBuf> = None;
    let mut opts = analyse_nidra::staging::scorer::StageOptions {
        // Default: YASA with SleepGPT sequence correction (best agreement
        // with manual scoring on the bundled control recordings).
        algorithm: "yasa".into(),
        sequence_correction: "sleepgpt".into(),
        ..Default::default()
    };

    let mut it = args.into_iter();
    while let Some(arg) = it.next() {
        let s = arg.to_string_lossy().to_string();
        let (key, inline) = match s.split_once('=') {
            Some((k, v)) if k.starts_with("--") => (k.to_string(), Some(v.to_string())),
            _ => (s.clone(), None),
        };
        let mut value = || -> Option<String> {
            inline
                .clone()
                .or_else(|| it.next().map(|x| x.to_string_lossy().to_string()))
        };
        match key.as_str() {
            "--stage" => {
                if let Some(v) = value() {
                    if !v.starts_with("--") {
                        edf_path = Some(PathBuf::from(v));
                    }
                }
            }
            "--algorithm" | "-a" | "--algo" | "--model" => {
                if let Some(v) = value() {
                    opts.algorithm = v;
                }
            }
            "--sequence-correction" | "--seq-corr" => {
                if let Some(v) = value() {
                    opts.sequence_correction = v;
                }
            }
            "--sleepgpt-alpha" => opts.sleepgpt_alpha = value().and_then(|v| v.parse().ok()),
            "--sleepgpt-ngram" => opts.sleepgpt_ngram = value().and_then(|v| v.parse().ok()),
            "--channel" | "-c" | "--eeg" | "--channels" => {
                if let Some(v) = value() {
                    opts.eeg.extend(split_channel_arg(&v));
                }
            }
            "--reference" | "--ref" | "--refs" | "--references" => {
                if let Some(v) = value() {
                    opts.refs.extend(split_channel_arg(&v));
                }
            }
            "--eog" => {
                if let Some(v) = value() {
                    opts.eog.extend(split_channel_arg(&v));
                }
            }
            "--emg" => {
                if let Some(v) = value() {
                    opts.emg.extend(split_channel_arg(&v));
                }
            }
            "--out-dir" => opts.out_dir = value().map(PathBuf::from),
            "--out" | "--output" | "-o" => opts.out_json = value().map(PathBuf::from),
            other => {
                if !other.starts_with("--") && edf_path.is_none() {
                    edf_path = Some(PathBuf::from(other));
                }
            }
        }
    }

    let edf_path = edf_path.context("No input EDF file specified for --stage")?;
    analyse_nidra::staging::scorer::score_recording(&edf_path, &opts)?;
    Ok(())
}

/// Generic `--key value` / `--key=value` parser for the PSG sub-commands.
fn parse_kv(args: Vec<OsString>, positional_flag: &str) -> (Option<PathBuf>, BTreeMap<String, String>) {
    let mut edf = None;
    let mut map = BTreeMap::new();
    let mut it = args.into_iter().map(|a| a.to_string_lossy().to_string()).peekable();
    while let Some(a) = it.next() {
        if a == positional_flag {
            if let Some(v) = it.next() {
                edf = Some(PathBuf::from(v));
            }
        } else if let Some(rest) = a.strip_prefix("--") {
            if let Some((k, v)) = rest.split_once('=') {
                map.insert(k.to_string(), v.to_string());
            } else {
                let takes_value = it.peek().map(|n| !n.starts_with("--")).unwrap_or(false);
                let v = if takes_value { it.next().unwrap_or_default() } else { "true".to_string() };
                map.insert(rest.to_string(), v);
            }
        } else if edf.is_none() {
            edf = Some(PathBuf::from(a));
        }
    }
    (edf, map)
}

fn yes(v: Option<&String>, default: bool) -> bool {
    match v.map(|s| s.to_ascii_lowercase()) {
        Some(s) => matches!(s.as_str(), "1" | "true" | "yes" | "y" | "on"),
        None => default,
    }
}

fn write_json_report<T: serde::Serialize>(report: &T, out: &Path) -> Result<()> {
    if let Some(parent) = out.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).ok();
        }
    }
    let file = File::create(out).with_context(|| format!("creating {}", out.display()))?;
    serde_json::to_writer_pretty(std::io::BufWriter::new(file), report)?;
    Ok(())
}

fn default_sidecar(edf: &Path, out_dir: Option<&String>, suffix: &str) -> PathBuf {
    let stem = edf.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| "recording".into());
    let name = format!("{stem}{suffix}");
    match out_dir {
        Some(d) if !d.trim().is_empty() => Path::new(d).join(name),
        _ => edf.with_file_name(name),
    }
}

fn handle_respiratory_cli(args: Vec<OsString>) -> Result<()> {
    let (edf, kv) = parse_kv(args, "--respiratory");
    let edf = edf.context("usage: analyse-nidra --respiratory <recording.edf> [--scoring s.json] [--thermal ch] [--pressure ch] ...")?;
    let mut o = analyse_nidra::psg::respiratory::RespOptions::defaults();
    let s = |k: &str| kv.get(k).cloned().filter(|v| !v.trim().is_empty());
    o.scoring = s("scoring").map(PathBuf::from);
    o.thermal = s("thermal");
    o.pressure = s("pressure");
    o.flow = s("flow");
    o.thorax = s("thorax");
    o.abdomen = s("abdomen");
    o.effort_sum = s("effort-sum");
    o.spo2 = s("spo2");
    o.pulse = s("pulse");
    o.ecg = s("ecg");
    o.snore = s("snore");
    o.position = s("position");
    o.chin = s("chin");
    o.eeg = s("eeg").map(|v| split_channel_arg(&v)).unwrap_or_default();
    o.supine_codes = s("supine-codes")
        .map(|v| v.split(',').filter_map(|x| x.trim().parse().ok()).collect())
        .unwrap_or_default();
    if let Some(r) = s("hypopnea-rule") {
        o.hypopnea_rule = if r.trim().starts_with('4') { 4 } else { 3 };
    }
    o.auto_arousals = yes(kv.get("auto-arousals"), false);
    if let Some(m) = s("arousals") {
        o.arousal_mode = m;
    }
    if let Some(v) = s("apnea-threshold").and_then(|v| v.parse().ok()) {
        o.apnea_threshold = v;
    }
    if let Some(v) = s("hypopnea-threshold").and_then(|v| v.parse().ok()) {
        o.hypopnea_threshold = v;
    }
    o.lights_off = s("lights-off-sec").and_then(|v| v.parse().ok());
    o.lights_on = s("lights-on-sec").and_then(|v| v.parse().ok());
    let out = s("out").map(PathBuf::from).unwrap_or_else(|| default_sidecar(&edf, kv.get("out-dir"), "_respiratory.json"));
    let started = Instant::now();
    let report = analyse_nidra::psg::respiratory::analyse(&edf, &o)?;
    println!("PROGRESS 0.95 Writing {}", out.display());
    write_json_report(&report, &out)?;
    for w in &report.warnings {
        println!("WARNING {w}");
    }
    println!(
        "AHI {:.1}/h ({}), ODI3 {:.1}/h, events {}",
        report.summary.get("AHI").copied().unwrap_or(f64::NAN),
        report.flags.get("severity").cloned().unwrap_or_default(),
        report.summary.get("ODI3").copied().unwrap_or(f64::NAN),
        report.events.iter().filter(|e| e.counted).count()
    );
    println!("OUTPUT_RESPIRATORY {}", out.display());
    println!("PROGRESS 1.00 Done in {:.1}s", started.elapsed().as_secs_f64());
    Ok(())
}

fn handle_plm_cli(args: Vec<OsString>) -> Result<()> {
    let (edf, kv) = parse_kv(args, "--plm");
    let edf = edf.context("usage: analyse-nidra --plm <recording.edf> [--scoring s.json] [--left ch] [--right ch] [--respiratory-json r.json]")?;
    let s = |k: &str| kv.get(k).cloned().filter(|v| !v.trim().is_empty());
    let mut o = analyse_nidra::psg::plm::PlmOptions {
        scoring: s("scoring").map(PathBuf::from),
        left: s("left"),
        right: s("right"),
        respiratory_json: s("respiratory-json")
            .filter(|v| !(v.trim() == "-" || v.trim().eq_ignore_ascii_case("none")))
            .map(PathBuf::from),
        eeg: s("eeg").map(|v| split_channel_arg(&v)).unwrap_or_default(),
        chin: s("chin"),
        auto_arousals: yes(kv.get("auto-arousals"), false),
        lights_off: s("lights-off-sec").and_then(|v| v.parse().ok()),
        lights_on: s("lights-on-sec").and_then(|v| v.parse().ok()),
        ..Default::default()
    };
    if let Some(m) = s("arousals") {
        o.arousal_mode = m;
    }
    if let Some(st) = s("standard") {
        o.standard = st.to_ascii_lowercase();
    }
    if let Some(v) = s("onset-uv").and_then(|v| v.parse().ok()) {
        o.onset_uv = v;
    }
    if let Some(v) = s("offset-uv").and_then(|v| v.parse().ok()) {
        o.offset_uv = v;
    }
    let resp_disabled = s("respiratory-json").is_some();
    if o.respiratory_json.is_none() && !resp_disabled {
        let sidecar = default_sidecar(&edf, kv.get("out-dir"), "_respiratory.json");
        if sidecar.exists() {
            o.respiratory_json = Some(sidecar);
        }
    }
    let out = s("out").map(PathBuf::from).unwrap_or_else(|| default_sidecar(&edf, kv.get("out-dir"), "_plm.json"));
    let started = Instant::now();
    let report = analyse_nidra::psg::plm::analyse(&edf, &o)?;
    println!("PROGRESS 0.95 Writing {}", out.display());
    write_json_report(&report, &out)?;
    for w in &report.warnings {
        println!("WARNING {w}");
    }
    println!(
        "PLMS index {:.1}/h ({}), LM {}",
        report.summary.get("PLMS_index").copied().unwrap_or(f64::NAN),
        report.flags.get("PLMS_severity").cloned().unwrap_or_default(),
        report.summary.get("n_LM_total").copied().unwrap_or(0.0)
    );
    println!("OUTPUT_PLM {}", out.display());
    println!("PROGRESS 1.00 Done in {:.1}s", started.elapsed().as_secs_f64());
    Ok(())
}

fn handle_cap_cli(args: Vec<OsString>) -> Result<()> {
    let (edf, kv) = parse_kv(args, "--cap");
    let edf = edf.context("usage: analyse-nidra --cap <recording.edf> --scoring s.json [--eeg C4-M1]")?;
    let s = |k: &str| kv.get(k).cloned().filter(|v| !v.trim().is_empty());
    let disabled = |v: &String| v.trim() == "-" || v.trim().eq_ignore_ascii_case("none");
    let mut o = analyse_nidra::psg::cap::CapOptions {
        scoring: s("scoring").map(PathBuf::from),
        eeg: s("eeg").filter(|v| !disabled(v)).map(|v| split_channel_arg(&v)).unwrap_or_default(),
        respiratory_json: s("respiratory-json").filter(|v| !disabled(v)).map(PathBuf::from),
        plm_json: s("plm-json").filter(|v| !disabled(v)).map(PathBuf::from),
        lights_off: s("lights-off-sec").and_then(|v| v.parse().ok()),
        lights_on: s("lights-on-sec").and_then(|v| v.parse().ok()),
        ..Default::default()
    };
    if let Some(m) = s("arousals") {
        o.arousal_mode = m;
    }
    if let Some(v) = s("sensitivity") {
        o.sensitivity = v;
    }
    if let Some(v) = s("a-phases") {
        o.a_phase_source = v;
    }
    // Couple with saved respiratory / PLM results unless switched off.
    if o.respiratory_json.is_none() && s("respiratory-json").is_none() {
        let p = default_sidecar(&edf, kv.get("out-dir"), "_respiratory.json");
        if p.exists() {
            o.respiratory_json = Some(p);
        }
    }
    if o.plm_json.is_none() && s("plm-json").is_none() {
        let p = default_sidecar(&edf, kv.get("out-dir"), "_plm.json");
        if p.exists() {
            o.plm_json = Some(p);
        }
    }
    let out = s("out").map(PathBuf::from).unwrap_or_else(|| default_sidecar(&edf, kv.get("out-dir"), "_cap.json"));
    let started = Instant::now();
    let report = analyse_nidra::psg::cap::analyse(&edf, &o)?;
    println!("PROGRESS 0.95 Writing {}", out.display());
    write_json_report(&report, &out)?;
    for w in &report.warnings {
        println!("WARNING {w}");
    }
    println!(
        "CAP rate {:.1}% ({} sequences, A-index {:.1}/h)",
        report.summary.get("CAP_rate").copied().unwrap_or(f64::NAN),
        report.sequences.len(),
        report.summary.get("A_index").copied().unwrap_or(f64::NAN)
    );
    println!("OUTPUT_CAP {}", out.display());
    println!("PROGRESS 1.00 Done in {:.1}s", started.elapsed().as_secs_f64());
    Ok(())
}

fn handle_nlg_cli(args: Vec<OsString>) -> Result<()> {
    let (edf, kv) = parse_kv(args, "--nlg");
    let edf = edf.context(
        "usage: analyse-nidra --nlg <recording.edf> [--scoring s.json] [--eeg C4,C3] [--references M1,M2] \
[--bands slow_wave,sigma] [--smooth-rate 0.01666] [--undersample N] [--lp HZ] [--edf-dir DIR] [--out n.json]",
    )?;
    let s = |k: &str| kv.get(k).cloned().filter(|v| !v.trim().is_empty());
    let mut cli = NlgCli::default();
    if let Some(v) = s("bands") {
        cli.bands = split_channel_arg(&v);
    }
    if let Some(v) = s("smooth-rate") {
        cli.smooth_rate = v.parse().context("--smooth-rate")?;
    }
    if let Some(v) = s("undersample") {
        cli.undersampler = v.parse().context("--undersample")?;
    }
    cli.lp_hz = s("lp").and_then(|v| v.parse().ok());
    cli.edf_dir = s("edf-dir").map(PathBuf::from);
    if yes(kv.get("no-series"), false) {
        cli.keep_series = false;
    }
    let opts = cli.options()?;
    let channels = s("eeg").map(|v| split_channel_arg(&v)).unwrap_or_else(|| vec!["C4".into(), "C3".into()]);
    let references = s("references")
        .filter(|v| !(v == "-" || v.eq_ignore_ascii_case("none")))
        .map(|v| split_channel_arg(&v))
        .unwrap_or_default();
    let stages = match s("scoring") {
        Some(p) => Some(analyse_nidra::hypnogram::read_sleepgpt(Path::new(&p))?),
        None => None,
    };
    if let Some(d) = &opts.write_edf_dir {
        std::fs::create_dir_all(d)?;
    }
    let out = s("out").map(PathBuf::from).unwrap_or_else(|| default_sidecar(&edf, kv.get("out-dir"), "_analyse_nlg.json"));
    let started = Instant::now();
    println!("PROGRESS 0.05 NeuroLoopGain on {}", channels.join(","));
    let report = analyse_nidra::nlg::analyse_recording(&edf, stages.as_deref(), &channels, &references, &opts)?;
    serde_json::to_writer(std::io::BufWriter::new(File::create(&out)?), &report)?;
    for w in &report.warnings {
        println!("WARNING {w}");
    }
    for (band, avg) in &report.average {
        println!(
            "{band}: NREM gain {:.1}%, index {:.1}%",
            avg.get("NREM_mean").copied().unwrap_or(f64::NAN),
            avg.get("upper_quartile_index").copied().unwrap_or(f64::NAN)
        );
    }
    println!("OUTPUT_NLG {}", out.display());
    println!("PROGRESS 1.00 Done in {:.1}s", started.elapsed().as_secs_f64());
    Ok(())
}

fn handle_apply_sleepgpt_cli(args: impl IntoIterator<Item = OsString>) -> Result<()> {
    let mut scoring_path: Option<PathBuf> = None;
    let mut out_json: Option<PathBuf> = None;
    let mut alpha: f64 = 0.1;
    let mut ngram: usize = 30;

    let mut it = args.into_iter();
    while let Some(arg) = it.next() {
        let s = arg.to_string_lossy();
        if s == "--apply-sleepgpt" {
            if let Some(val) = it.next() {
                if !val.to_string_lossy().starts_with("--") {
                    scoring_path = Some(PathBuf::from(val));
                }
            }
        } else if let Some(val) = s.strip_prefix("--apply-sleepgpt=") {
            scoring_path = Some(PathBuf::from(val));
        } else if s == "--alpha" {
            if let Some(val) = it.next() {
                alpha = val.to_string_lossy().parse().unwrap_or(0.1);
            }
        } else if let Some(val) = s.strip_prefix("--alpha=") {
            alpha = val.parse().unwrap_or(0.1);
        } else if s == "--ngram" {
            if let Some(val) = it.next() {
                ngram = val.to_string_lossy().parse().unwrap_or(30);
            }
        } else if let Some(val) = s.strip_prefix("--ngram=") {
            ngram = val.parse().unwrap_or(30);
        } else if s == "--out" || s == "--output" || s == "-o" {
            out_json = it.next().map(PathBuf::from);
        } else if let Some(val) = s.strip_prefix("--out=")
            .or_else(|| s.strip_prefix("--output="))
        {
            out_json = Some(PathBuf::from(val));
        } else if !s.starts_with("--") && scoring_path.is_none() {
            scoring_path = Some(PathBuf::from(arg));
        }
    }

    let scoring_path = scoring_path.context("No input scoring JSON file specified for --apply-sleepgpt")?;
    analyse_nidra::staging::apply_sleepgpt_to_scoring_file(
        &scoring_path,
        alpha,
        ngram,
        out_json.as_deref(),
    )?;
    Ok(())
}

fn main() -> Result<()> {
    let raw_args: Vec<OsString> = env::args_os().skip(1).collect();
    if raw_args.is_empty() {
        bail!(USAGE);
    }
    if raw_args[0] == "--version" {
        println!("analyse-nidra {VERSION}");
        return Ok(());
    }
    if raw_args.iter().any(|a| {
        let s = a.to_string_lossy();
        s == "--preprocess" || s.starts_with("--preprocess=")
    }) {
        return handle_preprocess_cli(raw_args);
    }
    if raw_args.iter().any(|a| {
        let s = a.to_string_lossy();
        s == "--stage" || s.starts_with("--stage=")
    }) {
        return handle_stage_cli(raw_args);
    }
    if raw_args.iter().any(|a| {
        let s = a.to_string_lossy();
        s == "--apply-sleepgpt" || s.starts_with("--apply-sleepgpt=")
    }) {
        return handle_apply_sleepgpt_cli(raw_args);
    }
    if raw_args[0] == "--list-signals" {
        let path = raw_args.get(1).context("usage: --list-signals <recording.edf>")?;
        println!("{}", analyse_nidra::psg::list_signals_json(Path::new(path))?);
        return Ok(());
    }
    if raw_args.iter().any(|a| a == "--respiratory") {
        return handle_respiratory_cli(raw_args);
    }
    if raw_args.iter().any(|a| a == "--plm") {
        return handle_plm_cli(raw_args);
    }
    if raw_args.iter().any(|a| a == "--nlg") {
        return handle_nlg_cli(raw_args);
    }
    if raw_args.iter().any(|a| a == "--cap") {
        return handle_cap_cli(raw_args);
    }
    if raw_args[0] == "--pops-debug" {
        // analyse-nidra --pops-debug <edf> <eeg> <ref|-> <out.tsv>
        let a: Vec<String> = raw_args.iter().map(|x| x.to_string_lossy().to_string()).collect();
        if a.len() < 5 {
            bail!("usage: --pops-debug <edf> <eeg> <ref|-> <out.tsv>");
        }
        let mut wanted = vec![a[2].clone()];
        if a[3] != "-" {
            wanted.push(a[3].clone());
        }
        let data = analyse_nidra::edf::read_selected(Path::new(&a[1]), &wanted)?;
        let mut sig = data.data_uv[0].clone();
        if data.data_uv.len() > 1 {
            for (x, r) in sig.iter_mut().zip(&data.data_uv[1]) {
                *x -= r;
            }
        }
        let model = analyse_nidra::staging::pops::PopsModel::load_default()?;
        let (kept, x, labels) = analyse_nidra::staging::pops::debug_features(&sig, data.sfreq, &model);
        let probs = analyse_nidra::staging::pops::score_pops_channel(&sig, data.sfreq, &model)?;
        let mut out = String::from("E\t");
        out.push_str(&labels.join("\t"));
        out.push_str("\tPW\tPN1\tPN2\tPN3\tPR\n");
        for (k, e) in kept.iter().enumerate() {
            out.push_str(&format!("{}", e + 1));
            for v in &x[k] {
                out.push_str(&format!("\t{v}"));
            }
            for v in probs[*e] {
                out.push_str(&format!("\t{v}"));
            }
            out.push('\n');
        }
        std::fs::write(&a[4], out)?;
        return Ok(());
    }

    let cli = parse_cli(raw_args)?;
    let edf_path = cli.edf_path;
    let scoring_path = cli.scoring_path;
    let mut outputs = cli.outputs.into_iter();
    let output_path = outputs.next().flatten();
    let pac_output_path = outputs.next().flatten();
    let slow_wave_output_path = outputs.next().flatten();
    let spindle_output_path = outputs.next().flatten();
    let regional_output_path = outputs.next().flatten();

    // Create --out-dir if it was supplied and does not yet exist.
    if let Some(ref dir) = cli.out_dir {
        std::fs::create_dir_all(dir)
            .with_context(|| format!("creating output directory {}", dir.display()))?;
    }

    // Validate scoring file up-front with a clear error message.
    if !scoring_path.exists() {
        bail!("scoring file not found: {}", scoring_path.display());
    }

    let requested: Vec<&str> = ALL_ANALYSES
        .iter()
        .copied()
        .filter(|a| cli.analyses.contains(*a))
        .collect();
    let need_regional = regional_output_path.is_some();
    let output_for = |analysis: &str| -> Option<&PathBuf> {
        match analysis {
            "core" => output_path.as_ref(),
            "pac" => pac_output_path.as_ref(),
            "slow_waves" => slow_wave_output_path.as_ref(),
            "spindles" => spindle_output_path.as_ref(),
            "nlg" => cli.nlg_out.as_ref(),
            _ => None,
        }
    };
    if cli.skip_existing {
        let components_exist = requested
            .iter()
            .all(|a| output_for(a).is_none_or(|p| p.exists()));
        let regional_ok = regional_output_path
            .as_ref()
            .is_none_or(|p| regional::is_complete(p, &requested));
        if components_exist && regional_ok {
            println!("all requested outputs already exist for {}; skipping recording", edf_path.display());
            if let Some(p) = regional_output_path.as_ref() {
                println!("OUTPUT_REGIONAL {}", p.display());
            }
            return Ok(());
        }
        if let Some(p) = regional_output_path.as_ref().filter(|p| p.exists() && !regional_ok) {
            println!(
                "existing regional CSV {} is incomplete (no data rows or missing analyses); it will be rebuilt",
                p.display()
            );
        }
    }

    let started = Instant::now();
    let recording = pipeline::load(
        &edf_path,
        &scoring_path,
        &cli.channels,
        &cli.references,
        cli.lights_off_seconds,
        cli.lights_on_seconds,
    )
    .with_context(|| format!("loading {}", edf_path.display()))?;
    println!(
        "loaded {} EEG channels ({}) referenced to {} x {} samples at {:.1} Hz in {:.3}s",
        recording.edf.channels.len(),
        recording.edf.channels.join(","),
        cli.references.join(","),
        recording.edf.data_uv[0].len(),
        recording.edf.sfreq,
        started.elapsed().as_secs_f64()
    );
    println!("sleep architecture:");
    for (name, value) in &recording.architecture.values {
        println!("  {name}: {value}");
    }
    let nrem_samples = recording
        .sample_stages
        .iter()
        .filter(|&&stage| matches!(stage, 2 | 3))
        .count();
    let mut active: Vec<&str> = requested.clone();
    if nrem_samples == 0 {
        let dropped: Vec<&str> = active
            .iter()
            .copied()
            .filter(|a| matches!(*a, "pac" | "slow_waves" | "spindles"))
            .collect();
        if !dropped.is_empty() {
            println!(
                "WARNING sleep scoring contains no N2 or N3 epochs; skipping {} (the other analyses still run)",
                dropped.join(", ")
            );
            active.retain(|a| !dropped.contains(a));
        }
    }
    let run = |name: &str| active.contains(&name);
    println!("analyses: {}", active.join(","));

    let core = if run("core") && (output_path.is_some() || need_regional) {
        cached_or_compute(cli.skip_existing, output_path.as_ref(), "core stage features", || {
            let t = Instant::now();
            let v = pipeline::compute_core_stage_features(&recording);
            println!("computed core stage features in {:.3}s", t.elapsed().as_secs_f64());
            Some(v)
        })
    } else {
        (None, false)
    };
    save_if_fresh(&core, output_path.as_ref(), "core stage features", true)?;
    let pac_values = if run("pac") && (pac_output_path.is_some() || need_regional) {
        cached_or_compute(cli.skip_existing, pac_output_path.as_ref(), "PAC results", || {
            let t = Instant::now();
            let v = pac::compute(&recording);
            println!("computed PAC in {:.3}s", t.elapsed().as_secs_f64());
            Some(v)
        })
    } else {
        (None, false)
    };
    save_if_fresh(&pac_values, pac_output_path.as_ref(), "PAC results", true)?;
    let slow_wave_values = if run("slow_waves") && (slow_wave_output_path.is_some() || need_regional) {
        cached_or_compute(cli.skip_existing, slow_wave_output_path.as_ref(), "slow-wave results", || {
            let t = Instant::now();
            let v = events::slow_waves(&recording);
            println!("detected slow waves in {:.3}s", t.elapsed().as_secs_f64());
            Some(v)
        })
    } else {
        (None, false)
    };
    save_if_fresh(&slow_wave_values, slow_wave_output_path.as_ref(), "slow-wave results", true)?;
    let spindle_values = if run("spindles") && (spindle_output_path.is_some() || need_regional) {
        cached_or_compute(cli.skip_existing, spindle_output_path.as_ref(), "spindle results", || {
            let t = Instant::now();
            let v = events::spindles(&recording);
            println!("detected spindles in {:.3}s", t.elapsed().as_secs_f64());
            Some(v)
        })
    } else {
        (None, false)
    };
    save_if_fresh(&spindle_values, spindle_output_path.as_ref(), "spindle results", true)?;
    let nlg_report = if run("nlg") && (cli.nlg_out.is_some() || need_regional) {
        let opts = cli.nlg.options()?;
        cached_or_compute(cli.skip_existing, cli.nlg_out.as_ref(), "NeuroLoopGain results", || {
            let t = Instant::now();
            match analyse_nidra::nlg::analyse_recording(
                &edf_path,
                Some(&recording.stages),
                &cli.channels,
                &cli.references,
                &opts,
            ) {
                Ok(report) => {
                    for w in &report.warnings {
                        println!("WARNING NeuroLoopGain {w}");
                    }
                    println!("computed NeuroLoopGain in {:.3}s", t.elapsed().as_secs_f64());
                    Some(report)
                }
                Err(e) => {
                    println!("WARNING NeuroLoopGain failed: {e}");
                    None
                }
            }
        })
    } else {
        (None, false)
    };
    // Compact JSON: the 1-s gain traces make the pretty form ~4x larger.
    save_if_fresh(&nlg_report, cli.nlg_out.as_ref(), "NeuroLoopGain results", false)?;
    if let (Some(p), Some(_)) = (&cli.nlg_out, &nlg_report.0) {
        println!("OUTPUT_NLG {}", p.display());
    }
    if let Some(output_path) = &regional_output_path {
        // Always rebuilt from the (cached or fresh) components: it takes
        // milliseconds and keeps the CSV consistent with every JSON output.
        let regional_started = Instant::now();
        let rows = regional::compile(
            &recording,
            core.0.as_ref(),
            spindle_values.0.as_ref(),
            slow_wave_values.0.as_ref(),
            pac_values.0.as_ref(),
            nlg_report.0.as_ref(),
            cli.per_channel,
            cli.region_map.as_ref(),
        );
        let recording_name = edf_path
            .file_stem()
            .and_then(|value| value.to_str())
            .context("EDF filename is not valid UTF-8")?;
        regional::write_csv(output_path, recording_name, &recording, &rows)?;
        println!(
            "wrote final regional CSV to {} ({} rows) in {:.3}s",
            output_path.display(),
            rows.len(),
            regional_started.elapsed().as_secs_f64()
        );
        println!("OUTPUT_REGIONAL {}", output_path.display());
    }
    println!("total analysis time {:.1}s", started.elapsed().as_secs_f64());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cli_uses_default_channels_and_references() {
        let cli = parse_cli(["recording.edf", "scoring.json"].map(OsString::from)).unwrap();
        assert_eq!(cli.channels, ["F3", "F4", "C3", "C4", "O1", "O2"]);
        assert_eq!(cli.references, ["M1", "M2"]);
        assert!(cli.outputs.iter().all(Option::is_none));
    }

    #[test]
    fn cli_accepts_options_after_positional_outputs() {
        let cli = parse_cli(
            [
                "recording.edf",
                "scoring.json",
                "-",
                "-",
                "-",
                "-",
                "regional.csv",
                "--channels",
                "F3, C3",
                "--references=A1",
            ]
            .map(OsString::from),
        )
        .unwrap();
        assert_eq!(cli.channels, ["F3", "C3"]);
        assert_eq!(cli.references, ["M1"]);
        assert_eq!(
            cli.outputs[4].as_deref(),
            Some(std::path::Path::new("regional.csv"))
        );
    }

    #[test]
    fn cli_accepts_lights_marker_options() {
        let cli = parse_cli(
            [
                "recording.edf",
                "scoring.json",
                "--lights-off-sec",
                "120.5",
                "--lights-on-sec=3600",
            ]
            .map(OsString::from),
        )
        .unwrap();
        assert_eq!(cli.lights_off_seconds, Some(120.5));
        assert_eq!(cli.lights_on_seconds, Some(3600.0));
    }

    /// --out-dir sets all 5 output slots when no positional output paths are given.
    #[test]
    fn cli_out_dir_overrides_defaults() {
        let cli = parse_cli(
            [
                "my_recording.edf",
                "scoring.json",
                "--out-dir",
                "/tmp/out",
            ]
            .map(OsString::from),
        )
        .unwrap();

        let expected = [
            "/tmp/out/my_recording_analyse_core.json",
            "/tmp/out/my_recording_analyse_pac.json",
            "/tmp/out/my_recording_analyse_slow_waves.json",
            "/tmp/out/my_recording_analyse_spindles.json",
            "/tmp/out/my_recording_analyse_regional.csv",
        ];

        for (slot, exp) in cli.outputs.iter().zip(expected.iter()) {
            assert_eq!(
                slot.as_deref(),
                Some(std::path::Path::new(exp)),
                "mismatch for expected path {exp}"
            );
        }
    }

    /// A positional output path beats --out-dir for the same slot.
    #[test]
    fn cli_positional_wins_over_out_dir() {
        let cli = parse_cli(
            [
                "my_recording.edf",
                "scoring.json",
                "explicit_core.json", // slot 0 — should NOT be overridden
                "--out-dir",
                "/tmp/out",
            ]
            .map(OsString::from),
        )
        .unwrap();

        // Slot 0: explicit positional wins.
        assert_eq!(
            cli.outputs[0].as_deref(),
            Some(std::path::Path::new("explicit_core.json"))
        );
        // Slot 1: falls back to --out-dir.
        assert_eq!(
            cli.outputs[1].as_deref(),
            Some(std::path::Path::new("/tmp/out/my_recording_analyse_pac.json"))
        );
    }

    #[test]
    fn cli_selects_analyses_and_nlg_options() {
        let cli = parse_cli(
            [
                "rec.edf",
                "sc.json",
                "--analyses",
                "spindles,nlg",
                "--nlg-bands=sigma,alpha",
                "--nlg-smooth-rate",
                "0.01",
                "--out-dir",
                "/tmp/o",
            ]
            .map(OsString::from),
        )
        .unwrap();
        assert!(cli.analyses.contains("spindles") && cli.analyses.contains("nlg"));
        assert!(!cli.analyses.contains("pac"));
        assert_eq!(cli.nlg.bands, ["sigma", "alpha"]);
        assert_eq!(cli.nlg.smooth_rate, 0.01);
        assert_eq!(cli.nlg_out.as_deref(), Some(std::path::Path::new("/tmp/o/rec_analyse_nlg.json")));
        let skip = parse_cli(["rec.edf", "sc.json", "--skip", "pac,nlg"].map(OsString::from)).unwrap();
        assert_eq!(skip.analyses.len(), 3);
        assert!(parse_cli(["rec.edf", "sc.json", "--analyses", "bogus"].map(OsString::from)).is_err());
    }

    #[test]
    fn cli_accepts_per_channel_and_region_map() {
        let cli = parse_cli(
            [
                "rec.edf",
                "sc.json",
                "--per-channel",
                "--region-map",
                "{\"Frontal\": [\"F3\", \"F4\"], \"C3\": \"Central\"}",
            ]
            .map(OsString::from),
        )
        .unwrap();

        assert!(cli.per_channel);
        let map = cli.region_map.expect("region map parsed");
        assert_eq!(map.get("F3").map(String::as_str), Some("Frontal"));
        assert_eq!(map.get("F4").map(String::as_str), Some("Frontal"));
        assert_eq!(map.get("C3").map(String::as_str), Some("Central"));
    }

    #[test]
    fn cli_accepts_skip_existing() {
        let cli1 = parse_cli(["rec.edf", "sc.json", "--skip-existing"].map(OsString::from)).unwrap();
        assert!(cli1.skip_existing);
        let cli2 = parse_cli(["rec.edf", "sc.json", "--resume"].map(OsString::from)).unwrap();
        assert!(cli2.skip_existing);
        let cli3 = parse_cli(["rec.edf", "sc.json"].map(OsString::from)).unwrap();
        assert!(!cli3.skip_existing);
    }
}


/// Reuses a cached JSON result when `--skip-existing` is set and the file
/// reads back; otherwise computes it. Returns (value, freshly computed).
fn cached_or_compute<T: serde::de::DeserializeOwned>(
    skip_existing: bool,
    path: Option<&PathBuf>,
    what: &str,
    compute: impl FnOnce() -> Option<T>,
) -> (Option<T>, bool) {
    if skip_existing {
        if let Some(p) = path.filter(|p| p.exists()) {
            match analyse_nidra::json_nan::from_path::<T>(p) {
                Ok(v) => {
                    println!("reusing existing {what} from {}", p.display());
                    return (Some(v), false);
                }
                Err(e) => println!("recomputing {what} (cache read failed: {e})"),
            }
        }
    }
    (compute(), true)
}

/// Writes a freshly computed result atomically (temporary file + rename).
fn save_if_fresh<T: serde::Serialize>(
    value: &(Option<T>, bool),
    path: Option<&PathBuf>,
    what: &str,
    pretty: bool,
) -> Result<()> {
    let (Some(v), true, Some(p)) = (&value.0, value.1, path) else {
        return Ok(());
    };
    let tmp = p.with_extension("json.partial");
    {
        let file = File::create(&tmp).with_context(|| format!("creating {}", tmp.display()))?;
        let mut w = std::io::BufWriter::new(file);
        if pretty {
            serde_json::to_writer_pretty(&mut w, v)?;
        } else {
            serde_json::to_writer(&mut w, v)?;
        }
        std::io::Write::flush(&mut w)?;
    }
    std::fs::rename(&tmp, p).with_context(|| format!("writing {}", p.display()))?;
    println!("wrote {what} to {}", p.display());
    Ok(())
}

