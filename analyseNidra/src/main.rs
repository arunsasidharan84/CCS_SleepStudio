use analyse_nidra::events;
use analyse_nidra::features::{acw50, bandpowers};
use analyse_nidra::nonlinear;
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

const VERSION: &str = "1.18.0";

const USAGE: &str = "usage: analyse-nidra <recording.edf> <scoring.json> \
[core.json|-] [pac.json|-] [slow-waves.json|-] [spindles.json|-] [regional.csv|-] \
[--out-dir <path>] [--channels F3,F4,C3,C4,O1,O2] [--references M1,M2] \
[--lights-off-sec SEC] [--lights-on-sec SEC] [--per-channel] [--region-map <json_or_file>] [--version]\n\
   or: analyse-nidra --preprocess <recording.edf> [--out-dir <dir>] [--steps <stimartifact,filter,badchannel,interpolate,gedai,save>] \
[--downsample-hz <hz>] [--bandpass-lo <lo>] [--bandpass-hi <hi>] [--notch-hz <notch>] [--suffix <_clean>] \
[--stim-f0 <hz>] [--stim-win <sec>] [--stim-max-combs <n>]\n\
   or: analyse-nidra --stage <recording.edf> [--algorithm <tinysleepnet|yasa|usleep|seqsleepnet|sleeptransformer|gssc>] [--sequence-correction <none|sleepgpt>] \
[--channel <C4>] [--ref <M1>] [--out <output.json>] [--out-dir <dir>] [--sleepgpt-alpha <0.1>] [--sleepgpt-ngram <30>]\n\
   or: analyse-nidra --apply-sleepgpt <scoring.json> [--out <output.json>] [--alpha <0.1>] [--ngram <30>]";

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
    let mut arguments = arguments.into_iter();
    while let Some(argument) = arguments.next() {
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

fn handle_stage_cli(args: impl IntoIterator<Item = OsString>) -> Result<()> {
    let mut edf_path: Option<PathBuf> = None;
    let mut algorithm: Option<String> = None;
    let mut sequence_correction: Option<String> = None;
    let mut channel: Option<String> = None;
    let mut reference: Option<String> = None;
    let mut out_json: Option<PathBuf> = None;
    let mut out_dir: Option<PathBuf> = None;
    let mut sleepgpt_alpha: Option<f64> = None;
    let mut sleepgpt_ngram: Option<usize> = None;

    let mut it = args.into_iter();
    while let Some(arg) = it.next() {
        let s = arg.to_string_lossy();
        if s == "--stage" {
            if let Some(val) = it.next() {
                if !val.to_string_lossy().starts_with("--") {
                    edf_path = Some(PathBuf::from(val));
                }
            }
        } else if let Some(val) = s.strip_prefix("--stage=") {
            edf_path = Some(PathBuf::from(val));
        } else if s == "--algorithm" || s == "-a" || s == "--algo" || s == "--model" {
            algorithm = it.next().map(|x| x.to_string_lossy().to_string());
        } else if let Some(val) = s.strip_prefix("--algorithm=")
            .or_else(|| s.strip_prefix("--algo="))
            .or_else(|| s.strip_prefix("--model="))
        {
            algorithm = Some(val.to_string());
        } else if s == "--sequence-correction" || s == "--seq-corr" {
            sequence_correction = it.next().map(|x| x.to_string_lossy().to_string());
        } else if let Some(val) = s.strip_prefix("--sequence-correction=")
            .or_else(|| s.strip_prefix("--seq-corr="))
        {
            sequence_correction = Some(val.to_string());
        } else if s == "--sleepgpt-alpha" {
            if let Some(val) = it.next() {
                sleepgpt_alpha = val.to_string_lossy().parse().ok();
            }
        } else if let Some(val) = s.strip_prefix("--sleepgpt-alpha=") {
            sleepgpt_alpha = val.parse().ok();
        } else if s == "--sleepgpt-ngram" {
            if let Some(val) = it.next() {
                sleepgpt_ngram = val.to_string_lossy().parse().ok();
            }
        } else if let Some(val) = s.strip_prefix("--sleepgpt-ngram=") {
            sleepgpt_ngram = val.parse().ok();
        } else if s == "--channel" || s == "-c" {
            channel = it.next().map(|x| x.to_string_lossy().to_string());
        } else if let Some(val) = s.strip_prefix("--channel=") {
            channel = Some(val.to_string());
        } else if s == "--reference" || s == "--ref" {
            reference = it.next().map(|x| x.to_string_lossy().to_string());
        } else if let Some(val) = s.strip_prefix("--reference=") {
            reference = Some(val.to_string());
        } else if let Some(val) = s.strip_prefix("--ref=") {
            reference = Some(val.to_string());
        } else if s == "--out-dir" {
            out_dir = it.next().map(PathBuf::from);
        } else if let Some(val) = s.strip_prefix("--out-dir=") {
            out_dir = Some(PathBuf::from(val));
        } else if s == "--out" || s == "--output" || s == "-o" {
            out_json = it.next().map(PathBuf::from);
        } else if let Some(val) = s.strip_prefix("--out=")
            .or_else(|| s.strip_prefix("--output="))
        {
            out_json = Some(PathBuf::from(val));
        } else if !s.starts_with("--") && edf_path.is_none() {
            edf_path = Some(PathBuf::from(arg));
        }
    }

    let edf_path = edf_path.context("No input EDF file specified for --stage")?;
    let computed_out = out_json.or_else(|| {
        out_dir.map(|d| {
            let stem = edf_path
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("recording");
            d.join(format!("{stem}_scoring.json"))
        })
    });

    analyse_nidra::staging::score_edf_file(
        &edf_path,
        algorithm.as_deref(),
        sequence_correction.as_deref(),
        channel.as_deref(),
        reference.as_deref(),
        computed_out.as_deref(),
        sleepgpt_alpha,
        sleepgpt_ngram,
    )?;
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
    if nrem_samples == 0
        && (pac_output_path.is_some()
            || slow_wave_output_path.is_some()
            || spindle_output_path.is_some()
            || regional_output_path.is_some())
    {
        bail!(
            "sleep scoring contains no N2 or N3 epochs; spindle, slow-wave, coupling, PAC, and regional analysis cannot be computed"
        );
    }

    // Fast smoke calculation on the first complete 15-second N2 window.
    let stage = 2_i8;
    let samples = (15.0 * recording.edf.sfreq) as usize;
    let indices: Vec<usize> = recording
        .sample_stages
        .iter()
        .enumerate()
        .filter_map(|(index, &value)| (value == stage).then_some(index))
        .take(samples)
        .collect();
    if indices.len() == samples {
        println!("first N2 window:");
        for (channel_name, channel) in recording.edf.channels.iter().zip(&recording.edf.data_uv) {
            let window: Vec<f64> = indices.iter().map(|&index| channel[index]).collect();
            let powers = bandpowers(&window, recording.edf.sfreq);
            println!(
                "  {channel_name}: Delta={:.8}, Alpha={:.8}, ACW={:.4}s",
                powers["Delta_PSD"],
                powers["Alpha_PSD"],
                acw50(&window, recording.edf.sfreq)
            );
            if channel_name == "F3" {
                println!("  F3 nonlinear: {:?}", nonlinear::all(&window));
            }
        }
    }
    if let Some(output_path) = output_path {
        let feature_started = Instant::now();
        let features = pipeline::compute_core_stage_features(&recording);
        serde_json::to_writer_pretty(
            File::create(&output_path)
                .with_context(|| format!("creating {}", output_path.display()))?,
            &features,
        )?;
        println!(
            "wrote core stage features to {} in {:.3}s",
            output_path.display(),
            feature_started.elapsed().as_secs_f64()
        );
    }
    if let Some(output_path) = pac_output_path {
        let pac_started = Instant::now();
        let values = pac::compute(&recording);
        serde_json::to_writer_pretty(
            File::create(&output_path)
                .with_context(|| format!("creating {}", output_path.display()))?,
            &values,
        )?;
        println!(
            "wrote PAC results to {} in {:.3}s",
            output_path.display(),
            pac_started.elapsed().as_secs_f64()
        );
    }
    if let Some(output_path) = slow_wave_output_path {
        let event_started = Instant::now();
        let values = events::slow_waves(&recording);
        serde_json::to_writer_pretty(
            File::create(&output_path)
                .with_context(|| format!("creating {}", output_path.display()))?,
            &values,
        )?;
        println!(
            "wrote slow-wave results to {} in {:.3}s",
            output_path.display(),
            event_started.elapsed().as_secs_f64()
        );
    }
    if let Some(output_path) = spindle_output_path {
        let event_started = Instant::now();
        let values = events::spindles(&recording);
        serde_json::to_writer_pretty(
            File::create(&output_path)
                .with_context(|| format!("creating {}", output_path.display()))?,
            &values,
        )?;
        println!(
            "wrote spindle results to {} in {:.3}s",
            output_path.display(),
            event_started.elapsed().as_secs_f64()
        );
    }
    if let Some(output_path) = regional_output_path {
        let regional_started = Instant::now();
        let core = pipeline::compute_core_stage_features(&recording);
        let spindle_values = events::spindles(&recording);
        let slow_wave_values = events::slow_waves(&recording);
        let pac_values = pac::compute(&recording);
        let rows = regional::compile(
            &recording,
            &core,
            &spindle_values,
            &slow_wave_values,
            &pac_values,
            cli.per_channel,
            cli.region_map.as_ref(),
        );
        let recording_name = edf_path
            .file_stem()
            .and_then(|value| value.to_str())
            .context("EDF filename is not valid UTF-8")?;
        regional::write_csv(&output_path, recording_name, &recording, &rows)?;
        println!(
            "wrote final regional CSV to {} in {:.3}s",
            output_path.display(),
            regional_started.elapsed().as_secs_f64()
        );
    }
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
}
