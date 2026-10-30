<p align="center">
  <img src="screenshots/ccs_logo.png" width="160" alt="Centre for Consciousness Studies Logo">
</p>

<h1 align="center">CCS Sleep Studio</h1>

<p align="center">
  <b>The High-Performance Sleep EEG Visualization, Annotation & Analysis Suite</b>
</p>

<p align="center">
  Developed by the<br>
  <b>Centre for Consciousness Studies (CCS)</b>, Department of Neurophysiology,<br>
  <b>National Institute of Mental Health and Neurosciences (NIMHANS)</b>, Bengaluru, India
</p>

<p align="center">
  <a href="https://github.com/arunsasidharan84/CCS_SleepStudio/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/arunsasidharan84/CCS_SleepStudio?style=for-the-badge&color=2563eb&label=RELEASE"></a>
  <a href="https://github.com/arunsasidharan84/CCS_SleepStudio/actions/workflows/build.yml"><img alt="Desktop build" src="https://img.shields.io/github/actions/workflow/status/arunsasidharan84/CCS_SleepStudio/build.yml?style=for-the-badge&label=BUILD"></a>
  <a href="https://github.com/arunsasidharan84/CCS_SleepStudio/releases"><img alt="Unique Downloads" src="https://img.shields.io/github/downloads/arunsasidharan84/CCS_SleepStudio/total?style=for-the-badge&color=16a34a&label=UNIQUE%20DOWNLOADS"></a>
</p>

<p align="center">
  <b>Current version: 1.50.3</b> ·
  <a href="CHANGELOG.md">Detailed changelog</a> ·
  <a href="https://github.com/arunsasidharan84/CCS_SleepStudio/issues">Report a problem</a>
</p>

<p align="center">
  <a href="#-quick-download"><b>📥 Download App</b></a> &nbsp;•&nbsp;
  <a href="docs/wiki/Home.md"><b>📖 Visual Tutorial & Wiki</b></a> &nbsp;•&nbsp;
  <a href="#about"><b>About</b></a> &nbsp;•&nbsp;
  <a href="#-compatible-file-formats--modalities"><b>File Formats</b></a> &nbsp;•&nbsp;
  <a href="#-key-features"><b>Key Features</b></a> &nbsp;•&nbsp;
  <a href="#-running--building-locally"><b>Build from Source</b></a> &nbsp;•&nbsp;
  <a href="CHANGELOG.md"><b>Release Notes</b></a> &nbsp;•&nbsp;
  <a href="https://github.com/arunsasidharan84/CCS_SleepStudio/issues"><b>Report Issue</b></a>
</p>

---

### 📥 Quick Download

> 📖 **Comprehensive Visual Tutorial:** New to sleep scoring or CCS Sleep Studio? Read our step-by-step **[Visual User Guide & Tutorial Wiki](docs/wiki/Home.md)** covering installation, AASM montage setup, AI autoscoring, manual event tagging, automated arrhythmia analysis, and publication reports.

Pre-built standalone desktop installers and application bundles are published through GitHub Releases:

| Platform | Variant | Package Type | Extracted App / Binary | Direct Download Link |
| :--- | :--- | :--- | :--- | :--- |
| **macOS** | **Full** | Universal ZIP | **`CCS Sleep Studio.app`** | [CCSSleepStudio-macos.zip](https://github.com/arunsasidharan84/CCS_SleepStudio/releases/latest/download/CCSSleepStudio-macos.zip) |
| | **Lite** | Universal ZIP | **`CCS Sleep Studio.app`** | [CCSSleepStudio-lite-macos.zip](https://github.com/arunsasidharan84/CCS_SleepStudio/releases/latest/download/CCSSleepStudio-lite-macos.zip) |
| **Windows** | **Full** | x64 Installer EXE | `CCSSleepStudio-Installer.exe` | [CCSSleepStudio-Installer.exe](https://github.com/arunsasidharan84/CCS_SleepStudio/releases/latest/download/CCSSleepStudio-Installer.exe) |
| | **Lite** | x64 Installer EXE | `CCSSleepStudio-lite-Installer.exe` | [CCSSleepStudio-lite-Installer.exe](https://github.com/arunsasidharan84/CCS_SleepStudio/releases/latest/download/CCSSleepStudio-lite-Installer.exe) |
| **Linux (Debian / Ubuntu)** | **Full** | x64 DEB Installer | `ccs-sleep-studio` | [CCSSleepStudio-linux-amd64.deb](https://github.com/arunsasidharan84/CCS_SleepStudio/releases/latest/download/CCSSleepStudio-linux-amd64.deb) |
| | **Lite** | x64 DEB Installer | `ccs-sleep-studio` | [CCSSleepStudio-lite-linux-amd64.deb](https://github.com/arunsasidharan84/CCS_SleepStudio/releases/latest/download/CCSSleepStudio-lite-linux-amd64.deb) |
| **Linux (RHEL / AlmaLinux)** | **Full** | x86_64 RPM Installer | `ccs-sleep-studio` | [CCSSleepStudio-linux-x86_64.rpm](https://github.com/arunsasidharan84/CCS_SleepStudio/releases/latest/download/CCSSleepStudio-linux-x86_64.rpm) |
| | **Lite** | x86_64 RPM Installer | `ccs-sleep-studio` | [CCSSleepStudio-lite-linux-x86_64.rpm](https://github.com/arunsasidharan84/CCS_SleepStudio/releases/latest/download/CCSSleepStudio-lite-linux-x86_64.rpm) |

> 📦 **All Releases & Checksums:** View all published packages and assets on the **[GitHub Releases Page](https://github.com/arunsasidharan84/CCS_SleepStudio/releases/latest)**.  
> 🐧 **Automated Linux Workstations:** For one-line multi-user server installation, see [Quick Install for Linux](#-quick-install-for-linux-servers--multi-user-workstations).

#### 🍏 First-Time Launch for macOS Users (Gatekeeper Setup)

When extracting `CCSSleepStudio-macos.zip` (or the Lite zip), macOS extracts **`CCS Sleep Studio.app`** into your `~/Downloads` folder. Because development builds are ad-hoc signed, macOS Gatekeeper blocks opening them by default.

To enable the app, run the following in **Terminal**:

```sh
# 1. Clear Gatekeeper quarantine on the downloaded app:
xattr -rd com.apple.quarantine ~/Downloads/CCS\ Sleep\ Studio.app

# 2. Move to Applications folder:
mv ~/Downloads/CCS\ Sleep\ Studio.app /Applications/
```

> **Tip (Finder alternative):** In Finder, **Right-click (or Control-click)** `CCS Sleep Studio.app` → select **Open** → click **Open** on the security confirmation prompt. You only need to do this once.

<p align="center">
  <img src="screenshots/main.png" width="920" alt="CCS Sleep Studio Main Window">
</p>

---

## About

**CCS Sleep Studio** is a standalone, cross-platform desktop application designed for researchers, sleep clinicians, and neurophysiologists. It delivers an end-to-end environment for sleep EEG/PSG visualization, multi-modal polysomnography event annotation, AI-driven sleep staging, quantitative spectral and nonlinear neurophysiology, and automated publication reporting.

Built using **Flutter** for a high-framerate 60+ FPS UI and a native **Rust** computational engine for signal processing, CCS Sleep Studio is inspired by the Python-based [ScoringHero](https://github.com/SvennoNito/ScoringHero) architecture. It operates without requiring Python, Conda, or MATLAB installations on end-user machines, delivering near-instant response times across massive multi-hour polysomnography recordings.

### Core Modules
* **ScoringNidra**: Interactive sleep scoring and multi-channel PSG review module supporting EDF/EDF+, Brain Products (`.vhdr`/`.vmrk`), Nihon Kohden (`.eeg`/`.log`), EMBLA (`.ebm`/`.esrc`), Compumedics Orbit (`.orb`), EEGLAB (`.mat`), and Zurich (`.r09`/`.vis`).
* **AutoscoreNidra**: Automated sleep scoring engine supporting 9 state-of-the-art ML/DL models with multi-montage consensus scoring, SleepGPT refinement, and single-channel support in both interactive and batch modes.
* **PSG Polygraphy**: Automated clinical event detection adhering to AASM standards:
  - **Cardiac & Arrhythmia**: Pan-Tompkins QRS detection, Asystole, Bradycardia, Tachycardia, PVCs, PACs, Couplets, NSVT, SVT, Bigeminy/Trigeminy, and AFib.
  - **Respiratory / OSA**: Automated Apnea/Hypopnea detection, AHI, RDI, oxygen desaturations, and ODI.
  - **Limb Movements (PLM)**: Periodic limb movements during sleep (PLMS) and wake (PLMW), index calculations, and series grouping.
  - **Cyclic Alternating Pattern (CAP)**: A-phase and B-phase detection, CAP rate, and subtype classification.
* **AnalyseNidra**: High-throughput quantitative sleep EEG analysis (spectral power, FOOOF/IRASA aperiodic dynamics, slow waves, spindles, phase-amplitude coupling, entropy, complexity) with publication-grade 5-page PDF reports.
* **GroupStatsNidra**: Built-in statistical engine computing one-way ANOVA, Welch's t-test, post-hoc Tukey HSD, non-parametric tests (Mann-Whitney U, Kruskal-Wallis), and linear models directly within the desktop app.

---

## 🌟 What's New in Version 1.50.x (Latest: 1.50.3)

* **App Version Traceability in All CSV Exports (v1.50.3):** Embedded an `'App Version'` column across all compiled master sheets (`AnalyseNidra_channel_master_sheet_*.csv`, `AnalyseNidra_regional_master_sheet_*.csv`), polygraphy summaries (`psg_batch_summary_*.csv`), inter-rater comparison tables (`Batch_Scoring_Comparison_Master_*.csv`), and group statistical reports (`GroupStats_*.csv`) ensuring complete provenance traceback for research publications.
* **Batch Collation & Macro Sleep Architecture Parity (v1.50.3):** Enforced strict separation between cohort demographic metadata lookups and raw hypnogram sleep architecture metrics (`TRT`, `TST`, `WASO`, `SOL`, `Sleep_efficiency`, `W_duration`, `N1_duration`, `N2_duration`, `N3_duration`, `R_duration`), preventing demographic overwrites and verifying 100% recording length parity across large cohorts.
* **Smart Batch Metadata Matching & Collision Prevention (v1.50.2):** Introduced high-cardinality uniqueness heuristics in `guessKeyColumn` that automatically penalize categorical grouping columns (`groupID`, `ageID`, `Gender`, `Status`), prioritizing unique identifiers (`napID`, `Subject_Code`) and using delimiter-bounded token matching to prevent cohort collapsing.
* **10-10 & 10-20 Channel Nomenclature Harmonization (v1.50.1):** Added bidirectional alias search and live badges (`EEG T3 [T7]`, `EEG T4 [T8]`, `EEG T5 [P7]`, `EEG T6 [P8]`), one-click 10-10 name standardization, and automatic prefix stripping across both interactive channel pickers and the master sheet compiler.
* **Restored Multi-Channel Fallback for CAP Analysis (v1.50.1):** Re-enabled multi-channel candidate selection for Cyclic Alternating Pattern (CAP) analysis, allowing fallback hierarchies (e.g., `C4, C3, CZ`) across cohort recordings with varying montages.
* **In-App Rich Markdown & Scientific Math Release Notes Viewer (v1.50.0):** Native in-app markdown rendering with automatic LaTeX formula translation into clean Unicode scientific symbols ($≥$, $≤$, $μ$, $±$, $×$, $≈$, $→$, $Δ$, $\text{ms}$, $\text{bpm}$, $\mu\text{V}$) and persistent scrollbars.
* **Comprehensive 8-Chapter Visual User Guide & Tutorial Wiki (v1.50.0):** Published a complete, non-technical visual user guide in `docs/wiki/` covering installation, montage setup, manual scoring, polygraphy event scoring, and publication reports.
* **Automated AASM Cardiac and Arrhythmia Event Analysis (v1.49.0):** Automated QRS detection and event classification adhering to AASM Rules Section VIII (Asystole, Bradycardia, Tachycardia, PVCs, PACs, Couplets, NSVT, SVT, Bigeminy/Trigeminy, AFib) with stage-wise heart rate tables.
* **Interactive Zoom Caliper & Waveform Sub-Second Grids (v1.49.0):** Zoomed signal inspector with 0.1s/0.5s sub-second grids and a drag-to-measure caliper calculating $\Delta t$ (ms), instantaneous frequency ($f = 1/\Delta t$), $\Delta V$, and slice mean.
* **Relative Spectral Multi-Line Trajectories & Scalp Topoplots (v1.49.0):** 3-chart side-by-side spectral landscape in PDF reports (Aperiodic Slope, Intercept, Relative Power trajectories) and automated 2D scalp topoplots for multi-channel montages.

> 📜 For complete historical changes, see the comprehensive **[CHANGELOG.md](CHANGELOG.md)**.

---

## 📂 Compatible File Formats & Modalities

CCS Sleep Studio provides native multi-format interoperability, allowing sleep research centers to seamlessly analyze data recorded on different hardware, clinical software, and proprietary PSG systems:

### 1. Polysomnography & Electrophysiological Signal Formats
| Format | Extensions | Description & Implementation Details |
| :--- | :--- | :--- |
| **European Data Format** | `.edf`, `.edf+` | Full standard and continuous/discontinuous EDF+ reader with 16-bit integer physical calibration, sampling rate preservation, and multi-channel montage generation. |
| **Brain Products BrainVision** | `.vhdr`, `.vmrk`, `.eeg` | Native binary/ASCII multiplexed parser reading BrainVision header (`.vhdr`), marker triggers (`.vmrk`), and raw voltage data (`.eeg`) with resolution scaling. |
| **Nihon Kohden Neurofax** | `.eeg`, `.21e`, `.pnt`, `.log` | Native binary parser decoding raw signals (`.eeg`), electrode montage layout (`.21e`), patient demographics (`.pnt`), and hardware event logs (`.log`). |
| **EMBLA / REMlogic** | `.ebm`, `.esrc`, `.esedb` | Native Rust reader for EMBLA single-channel binary files (`.ebm`) and REMlogic sleep stage scoring XML / Jet database files (`.esrc`, `.esedb`). |
| **Compumedics Orbit** | `.orb`, `.signal` | High-speed binary and JSON-lines parser for Orbit recordings, complete with gap-filling, linear interpolation, and automatic voltage calibration. |
| **EEGLAB MATLAB Structures** | `.mat` | Native MAT parser reading MATLAB v5/v7 structures containing `EEG.data`, `EEG.srate`, `EEG.chanlocs`, and `EEG.event`. |
| **Zurich Sleep Recording** | `.r09` | Native binary reader for Zurich format sleep EEG recordings used extensively in sleep slow-wave research. |
| **Processed Signal Exports** | `.ccseeg`, `.fif`, `.edf` | Export cleaned and preprocessed signals with companion `.ccsmeta` files preserving preprocessing history, filters, and channel montages. |

### 2. Sleep Staging & Hypnogram Scoring Formats
| Format / System | Extensions | Features & Import Capabilities |
| :--- | :--- | :--- |
| **CCS Native / ScoringHero** | `.ccsscoring`, `.json` | Native JSON schema capturing epoch stages (W, N1, N2, N3, REM), confidence flags, stage probabilities, and event logs. 100% backward compatible. |
| **EDF+ Annotations** | `.edf` | Direct extraction of embedded TAL (Time-stamped Annotation Lists) sleep stage markers (`Sleep stage W`, `Sleep stage N1`, etc.). |
| **REMlogic / EMBLA** | `.esrc`, `.esedb` | Direct parsing of REMlogic XML staging exports and Jet/ESEDB database files with automatic epoch boundary alignment. |
| **Zurich Visual Scoring** | `.vis` | Reads Zurich 20s/30s visual scoring files into standardized AASM sleep stages. |
| **Sleepyland** | `.annot` | Parses Sleepyland hypnogram annotation exports. |
| **Somnomedics / Polyman** | `.txt` | Auto-detects Somnomedics `Schlafprofil` text files and Polyman comma-delimited sleep profile logs. |
| **YASA Stage Lists** | `.txt` | Preserves epoch alignment and unscored elements from standard YASA text lists. |
| **GSSC & Sleeptrip** | `.csv`, `.tsv` | Automatically parses GSSC epoch tables and Sleeptrip timestamped hypnogram CSV files. |

### 3. Clinical Event & Marker Formats
| Marker Type | Format / Extension | Supported Features |
| :--- | :--- | :--- |
| **EDF+ Embedded Events** | `.edf` TAL | Extracts clinical events (apneas, hypopneas, arousals, desaturations, leg movements, spindles). |
| **BrainVision Markers** | `.vmrk` | Imports hardware stimulus triggers, response markers, and manual annotations with sample-accurate offsets. |
| **Nihon Kohden Logs & Triggers** | `.log`, `.evt` | Loads binary operator logs, montage switches, impedance checks, and event timestamps. |
| **Compumedics / Alice / Profusion** | `.xml` | Parses comprehensive clinical PSG event export XML files into native timeline markers. |
| **Tabular Marker Logs** | `_events.csv`, `.tsv`, `.txt` | Imports Sleeptrip event lists, Polyman marker exports, and generic comma/tab-delimited event tables. |
| **Interactive In-App Markers** | GUI / Shortcuts | Single-click pinpoint markers, duration bounding boxes, AASM standard categories (Artifact, Arousal, OSA, CSA, Hypopnea, Mixed, Desat, LM, PLM, RERA, Spindle, K-Complex, REM), and custom typed markers (`T`, `Shift+M`). |

### 4. Synchronized Multi-Camera Video Formats
| Format | Extensions | Capabilities |
| :--- | :--- | :--- |
| **Standard Video Files** | `.mp4`, `.mkv`, `.avi`, `.mov`, `.webm`, `.ts`, `.m2ts`, `.mpg` | Multi-camera synchronized playback lock-stepped to EEG viewport scrolling with configurable millisecond audio/video time offset. |
| **Nihon Kohden Video Indices** | `.vf2`, `.vft` | Native parsing of Nihon Kohden video session indices, automatically resolving segmented multi-file video recordings to the absolute recording clock time. |

### 5. Study Metadata & Configuration Spreadsheets
| Type | Extensions | Use Case |
| :--- | :--- | :--- |
| **Cohort Demographic Metadata** | `.csv`, `.tsv`, `.xlsx`, `.xlsm` | Multi-recording demographic merging (`Age`, `Gender`, `Group`, `Diagnosis`) with high-cardinality heuristic to prevent key collision. |
| **App Configuration** | `.ccsconfig`, `_config.json` | Stores per-recording display montage, filter coefficients, spectrogram ranges, and UI layout preferences. |
| **Montage Presets** | `.ccsmontage`, `.json` | Reusable channel montage mappings (AASM Sleep, Comprehensive PSG, 10-20 Scalp, Bipolar chains). |

### 6. Quantitative Analysis Outputs & Feature Sidecars
| Extension | Output Content |
| :--- | :--- |
| **`.ccsspindles`** | Detected sleep spindle events (start, duration, peak frequency, amplitude, symmetry). |
| **`.ccsslowwaves`** | Detected slow wave events (negative peak, peak-to-peak amplitude, slope, duration, density per NREM min). |
| **`.ccspac`** | Slow-Wave / Fast-Sigma Phase-Amplitude Coupling modulation index matrices. |
| **`.ccscore`** | Core spectral powers (Delta, Theta, Alpha, Sigma, Beta, Gamma), FOOOF aperiodic slope/offset, and IRASA. |
| **`.ccsnlg`** | NeuroLoopGain ventilatory stability and loop-gain trajectory sidecars. |
| **`.ccsrespiratory`** | Respiratory event epochs, AHI, RDI, central/obstructive/mixed apnea breakdowns, and desaturations. |
| **`.ccsplm`** | Periodic limb movement series, PLMS/PLMW indices, constituent movement counts, and duration metrics. |
| **`.ccscap`** | Cyclic Alternating Pattern A-phase/B-phase durations, CAP rate (%), and subtype distributions (A1, A2, A3). |
| **Master CSVs** | Collated channel/regional sheets, scoring comparisons, and group statistics with embedded `'App Version'` column. |
| **Publication Reports** | 5-page vector PDF reports covering hypnogram architecture, topoplots, spectral landscapes, and PAC. |

---

## 🔬 Key Features

### Multi-Channel EEG Signal Display
* View multiple EEG channels simultaneously with configurable vertical spacing.
* Adjust per-channel amplitude scaling and vertical offsets.
* Predefined, high-contrast channel colors (Black, Blue, Green, Magenta, Orange, Cyan).
* Add amplitude reference lines and 1-second / 5-second grid overlays.
* **Stack channels** on a shared baseline for direct overlay comparison.
* **Channel Solo Mode**: Double-click any channel scale tile (or press <kbd>Esc</kbd> to exit) to isolate that channel.
* **Robust z-standardization** (median/IQR normalization) for cross-channel comparison.
* Configurable time axis units: Seconds, Minutes, or Clock Time (HH:MM:SS).

### Full AASM Polysomnography & Cardiac Analysis
* **Automated Cardiac Event Scoring**: Full implementation of AASM Section VIII rules for Asystole ($\ge 3.0\text{ s}$), Bradycardia ($< 40\text{ bpm}$), Tachycardia ($> 90\text{ bpm}$), PVCs, PACs, Couplets, NSVT, SVT, Bigeminy/Trigeminy, and AFib.
* **Interactive Zoom Caliper**: Sub-second ticks ($0.1\text{ s} / 0.5\text{ s}$) with interactive drag-to-measure caliper calculating duration ($\Delta t$), frequency ($1/\Delta t$), $\Delta V$, and peak-to-peak amplitude.
* **Automated Respiratory Analysis**: AASM Rule 1A/1B scoring for Obstructive Apneas, Central Apneas, Mixed Apneas, Hypopneas, RERAs, Oxygen Desaturations, AHI, and ODI.
* **Periodic Limb Movements (PLM)**: Automatic detection of periodic leg movements during sleep (PLMS) and wake (PLMW) with series grouping ($\ge 4$ movements) and index calculation.
* **Cyclic Alternating Pattern (CAP)**: Multi-channel candidate fallback for A-phase/B-phase detection, CAP rate, and A1/A2/A3 subtype analysis.

### Sleep Stage Scoring & Comparison
* Score epochs (default 30s) as **Wake** (`W`), **N1** (`1`), **N2** (`2`), **N3** (`3`), **REM** (`R`), or **Inconclusive** (`I`).
* **Confidence Flagging**: Press `Q` to flag an epoch as uncertain; flagged epochs are visually marked on the hypnogram step timeline.
* **Compare & Inter-Rater Reliability**: Import comparison scoring files to visualize disagreement bands on the hypnogram timeline, Cohen's Kappa ($\kappa$), Confusion Matrices, and per-stage Precision, Recall, and F1-Scores.
* **Batch Scoring Comparison**: Collate multiple scorer pairs into `Batch_Scoring_Comparison_Master_*.csv` with embedded App Version provenance.

### Signal Filtering & Preprocessing
* Apply high-pass, low-pass, and notch filters independently to each channel using zero-phase Chebyshev Type 2 display filters without lagging epoch navigation.
* **Cardiac QRS Subtraction**: Native Rust QRS-synchronous median template subtraction cleanly eliminates pulse/ECG artifacts from EEG channels without distorting delta waves or spindles.
* **DBS Stimulus Artefact Removal**: High-frequency deep brain stimulation pulse suppression.
* **Signal Downsampling & Anonymization**: Downsample sampling rates, crop time windows, and anonymize patient headers (Name, ID, Sex, DOB) across EDF, Nihon Kohden, Orbit, and EMBLA files.

---

## AutoscoreNidra — Automated Sleep Scoring (Full App Only)

**AutoscoreNidra** provides automated machine-learning and deep-learning sleep scoring with live epoch progress:

* **Multi-Montage Consensus Scoring**: Independently scores every selected EEG channel and clinically valid reference combination, combining probabilities into one robust consensus hypnogram.
* **SleepGPT Sequence Refinement**: Applies a condition-agnostic sequence correction pass using temporal transition probabilities to eliminate implausible sleep transitions.
* **9 Supported Staging Models**:
  1. **YASA LightGBM Consensus**: Lightweight boosted tree stager.
  2. **Offline U-Sleep Consensus**: Deep convolutional neural network inference.
  3. **Luna POPS**: Probabilistic Sleep Stager (`lunapi` adapter).
  4. **Greifswald Sleep Stage Classifier (GSSC)**: Clinical convolutional model.
  5. **TinySleepNet**: Lightweight temporal RNN stager.
  6. **SeqSleepNet**: Sequence-to-sequence model.
  7. **SleepTransformer**: Self-attention transformer stager.
  8. **Dreamento**: Feature-engineered classifier.
  9. **SleepEEGpy**: Standard MNE/YASA scorer.
* **Batch AutoscoreNidra**: Queue dozens of recordings for sequential unattended scoring with live progress and automatic `.ccsscoring` generation.

---

## AnalyseNidra — Advanced Sleep EEG Analysis

**AnalyseNidra** is the advanced quantitative neurophysiology subsystem, written in native Rust with multithreaded parallel execution via `rayon`:

* **Spectral Dynamics**: Fast Welch periodograms with median averaging.
* **Aperiodic Fit (FOOOF & IRASA)**: Native Levenberg-Marquardt implementations isolating true oscillatory peaks from the background $1/f$ aperiodic slope and offset.
* **Spindle & Slow-Wave Detection**: Automated detection of sleep spindles (peak frequency, duration, amplitude) and slow waves (negative peak, peak-to-peak amplitude, duration, density per NREM minute).
* **Phase-Amplitude Coupling (PAC)**: TensorPAC-compatible modulation index calculation for Slow-Wave/Fast-Sigma coupling.
* **Master Sheet Compilation**: Collates all individual channel and regional feature CSVs into unified master sheets (`AnalyseNidra_channel_master_sheet_*.csv` and `AnalyseNidra_regional_master_sheet_*.csv`) with embedded App Version provenance.
* **Publication Sleep Reports**: Five-page vector PDF reports covering sleep continuity, thalamocortical coupling, FOOOF/IRASA trends, 2D scalp topoplots, relative spectral multi-line trajectories, and entropy metrics.

---

## 📊 GroupStatsNidra — In-App Statistical Analysis Engine

CCS Sleep Studio includes an integrated statistical analysis suite written entirely in pure Dart:
* **One-Way ANOVA & Welch's ANOVA**: Compare neurophysiological features across diagnostic groups (e.g. Healthy Controls vs. MCI vs. Narcolepsy).
* **Post-Hoc Pairwise Tests**: Automated Tukey HSD and Games-Howell post-hoc tests with adjusted p-values.
* **Non-Parametric Tests**: Mann-Whitney U test and Kruskal-Wallis tests for skewed sleep metrics.
* **Interactive Visualizations**: Interactive box plots, violin plots, and distribution histograms with jittered data points.
* **Reproducible CSV Exports**: Exports `GroupStats_Summary.csv`, `GroupStats_PostHoc.csv`, and `GroupStats_Descriptives.csv` with embedded App Version provenance.

---

## ⚡ Speed & Architectural Highlights

CCS Sleep Studio overcomes the main performance bottlenecks of standard Python-based visualization tools:

1. **Hybrid Flutter + Rust FFI Pipeline**: Heavy mathematical operations (zero-phase Chebyshev/Butterworth filters, Welch periodograms, Morlet wavelets) are written in Rust, leveraging SIMD compiler optimizations and multi-threaded processing via `rayon`.
2. **Isolate-Based Background Worker**: Computations run off the main thread in background Dart **Isolates**, leaving the main interface to render at a locked 60+ FPS.
3. **Zero-Copy Memory Access**: Transfers between Dart and Rust utilize direct pointers and `.asTypedList` buffer access to avoid slow copy loops.
   * *Benchmarks*: Night-wide spectrogram updates complete in just **19 ms**, and wavelet time-frequency updates finish in **113 ms**.
4. **Self-Contained Executables**: Zero environment configuration required. Even the Full edition bundles its model runtimes inside a standalone package.

---

## 🐧 Quick Install for Linux Servers & Multi-User Workstations

To install the latest release automatically for all users on enterprise Linux servers (AlmaLinux, RHEL, Rocky, Fedora, Ubuntu, Debian), run this one-line command:

```sh
curl -fsSL https://raw.githubusercontent.com/arunsasidharan84/CCS_SleepStudio/main/scripts/install_linux.sh | sudo bash
```

Or from a local clone:
```sh
sudo bash scripts/install_linux.sh
```

The installer automatically:
1. Enables EPEL and supplementary multimedia repositories (`mpv-libs`, `gtk3`).
2. Downloads and installs the latest verified release package (`.rpm` or `.deb`).
3. Installs an executable desktop launcher into `/etc/skel/Desktop/` so all new users receive it upon account creation.
4. Propagates the launcher (`ccs-sleep-studio.desktop`) with `755` executable permissions across all existing user desktops (`/home/*/Desktop`, `/serverdata/ccshome/*/Desktop`).
5. Updates system desktop and icon databases so CCS Sleep Studio immediately appears in the Applications menu under **Science / Medical** for all VNC and desktop sessions.

### Manual Installation (RPM - AlmaLinux / RHEL / Rocky / Fedora)
```sh
# Enable EPEL (required for mpv multimedia libraries)
sudo dnf install -y epel-release
sudo dnf config-manager --set-enabled crb   # On AlmaLinux / Rocky / RHEL 9

# Install package
sudo dnf install ./CCSSleepStudio-linux-x86_64.rpm
```

### Manual Installation (DEB - Debian / Ubuntu / Mint)
```sh
sudo apt update
sudo apt install ./CCSSleepStudio-linux-amd64.deb
```

---

## 🧪 Sample PSG Data

The repository includes a demonstration dataset in [`SamplePSGData`](SamplePSGData/) for testing the viewer, manual scoring import, batch workflows, and AnalyseNidra report generation:

* `SamplePSGData/Data/` contains four EDF PSG recordings.
* `SamplePSGData/ManualScorings/` contains matching manual scoring EDF files with the same base filenames.
* `SamplePSGData/Template_config.json` provides a reusable configuration template for the sample recordings.

Load a recording from `SamplePSGData/Data/`, then import the corresponding file from `SamplePSGData/ManualScorings/` as the scoring/comparison file.

---

## ⌨️ Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| `W` | Score current epoch as **Wake** |
| `1` | Score current epoch as **N1** |
| `2` | Score current epoch as **N2** |
| `3` | Score current epoch as **N3** |
| `R` | Score current epoch as **REM** |
| `I` | Score current epoch as **Inconclusive** |
| `N` / `0` / `Delete` | Score current epoch as **None / Unscored (`?`)** |
| `U` / `Q` | Toggle low confidence (uncertainty) |
| `ArrowRight` | Go to the next epoch |
| `ArrowLeft` | Go to the previous epoch |
| `A` | Draw **Artefact** event |
| `F1`–`F12` | Draw **Event 1**–**Event 12** |
| `T` / `Shift+M` | Create **Custom Typed Event Marker** |
| `Backspace` | Erase events in drawn selection |
| `Z` | Open Zoomed Signal Inspector with Caliper |
| `G` | Toggle Epoch Time Grid (1s dashed / 5s solid lines) |
| `Esc` | Clear selection / Exit channel solo mode |
| `Ctrl+Alt+=` / `-` / `0` | Display Font Scaling (Zoom In / Zoom Out / Reset) |
| `Ctrl+K` | Open K-Complex Detection (MT-KCD) |
| `Ctrl+Shift+S` | Open Spindle Detection (MT-Spindle) |
| `Ctrl+C` | Open Settings/Configuration Dialog |
| Double-click channel scale | **Solo Channel Mode** (isolate single channel) |
| Right-click on signal | Context menu for markers, pattern search, and caliper |

---

## 🚀 Running & Building Locally

### Prerequisites
* [Flutter SDK](https://docs.flutter.dev/get-started/install) (latest Stable)
* [Rust Toolchain](https://www.rust-lang.org/tools/install) (`cargo` and `rustc`)
* For Windows installer: [Inno Setup](https://jrsoftware.org/isinfo.php) (`iscc` compiler)

### 1. Build the Rust Backend
Compile the native library for your platform first:
```sh
cd bridge
cargo build --release
cd ..
```

### 2. Run the App
Start the app in development mode:
```sh
cd frontend

# Run on macOS
flutter run -d macos

# Run on Windows
flutter run -d windows
```

### 3. Compile Production Release
To compile release packages:
```sh
cd frontend

# macOS Release (.app)
flutter build macos --release

# Windows Release (.exe and Inno Setup Installer)
flutter build windows --release
iscc windows/installer.iss
```

---

## 🤝 Research Collaboration & Acknowledgments

**CCS Sleep Studio** is developed and maintained by the:

* **Centre for Consciousness Studies (CCS)**  
  *Department of Neurophysiology*,  
  **National Institute of Mental Health and Neurosciences (NIMHANS)**, Bengaluru, India.  
  *Advancing scientific inquiry and clinical methodologies in sleep medicine, neurophysiology, consciousness states, and computational neuroscience.*
