# analyse-nidra

Native Rust port of `SleepAnalysis.py`, verified with:

- `/Users/arunsasidharan/EEGdata/Sleep/PSG/AS_CNT_08_Night1.edf`
- `/Users/arunsasidharan/EEGdata/Sleep/PSG/AS_CNT_08_Night1_yasa_sleepgpt.json`

The EDF `A1` and `A2` channels are normalized to `M1` and `M2`. By default,
`F3,F4,C3,C4,O1,O2` are analyzed after referencing to the mean of `M1,M2`.
Recordings are resampled to 250 Hz with MNE-compatible FFT resampling before
rereferencing and filtering.

## Run

```bash
~/.cargo/bin/cargo run --release -- \
  /path/to/recording.edf \
  /path/to/recording_yasa_sleepgpt.json \
  - - - - \
  /path/to/final_regional.csv
```

Choose EEG and reference channels with optional comma-separated flags:

```bash
~/.cargo/bin/cargo run --release -- \
  /path/to/recording.edf \
  /path/to/recording_yasa_sleepgpt.json \
  - - - - \
  /path/to/final_regional.csv \
  --channels F3,F4,C3,C4,O1,O2 \
  --references M1,M2
```

The flags may appear before or after the positional paths. One or more reference
channels are allowed, and their sample-wise mean is subtracted. Reference-only
channels are not included in feature, event, PAC, or regional output. `A1/A2`
may be used in the flags as aliases for `M1/M2`.

Optional positional outputs after the EDF and scoring JSON are:

1. Core stage features JSON
2. PAC JSON
3. Slow-wave JSON
4. Spindle JSON
5. Final regional CSV

Use `-` to skip an earlier output.

## Stimulation artefact removal (preprocessing step `stimartifact`)

Recordings from patients with deep brain stimulators (or other periodic
neurostimulators) carry a large, strictly periodic waveform: the ~130–185 Hz
pulses are aliased by the amplifier to a low fundamental (e.g. 2.04, 2.21, 3.00
or 17.99 Hz) plus harmonics. `src/cleaning/stim_artifact.rs` removes it with an
adaptive harmonic comb:

1. whole-night median-Welch PSD (0.01 Hz) → strongest narrow line, checked for
   sub-harmonics and refined from its harmonics;
2. the fundamental is tracked in 2-min blocks and integrated to a phase;
3. each harmonic is synchronously demodulated, averaged over ~20 s (movement
   bursts down-weighted) and subtracted, so only a very narrow band around each
   harmonic is touched;
4. the residual spectrum is searched again for further combs (up to 3).

Channels without the comb are left unchanged, and nothing is removed when no
artefact line is found. Run it first, before filtering and bad-channel detection
(the artefact otherwise makes RANSAC flag every channel as bad):

```bash
analyse-nidra --preprocess recording.edf --steps stimartifact,filter,badchannel,interpolate,gedai \
  [--stim-f0 <hz>] [--stim-win <sec, default 20>] [--stim-max-combs <n, default 3>]
```

The detected combs, per-channel artefact RMS and first-harmonic prominence
before/after are written to `stim_artifact` in the `*_log.json`. Parity with the
reference Python implementation (`dbs_artifact_removal.py`) on a 3.3 h DBS
recording: removed artefact correlation ≥ 0.998 and difference ≤ 0.5 µV RMS
across channels.

## Verification

Implemented and verified:

- EDF decoding, channel normalization, mastoid reference, and MNE FIR preprocessing
- Sleep architecture, Welch PSD, nonlinear features, and ACW
- IRASA decomposition and derived features
- YASA spindle detection: all 3,508 events and sample boundaries match
- YASA slow-wave detection: all 4,356 events and sample boundaries match
- Slow-wave/sigma coupling
- TensorPAC modulation index: maximum error below `2e-17`
- Regional aggregation and 253-column CSV export, including
  `sw_all_density_calc` (slow-wave count per total NREM minute)

FOOOF uses a native bounded Levenberg-Marquardt fit. Spectral band averages are
within about `0.002` on the verification recording. Some multi-peak spectra can
choose a different local optimum than SciPy's trust-region solver, so individual
center-frequency and bandwidth values are not bitwise identical.

Measured on the verification recording:

- Python spectral fixture: `194.10 s`
- Rust complete regional pipeline: `30.59 s`
- Speedup: greater than `6x`

Run the native tests with:

```bash
~/.cargo/bin/cargo test --release
```
