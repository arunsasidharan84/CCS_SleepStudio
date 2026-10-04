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
  <a href="#-quick-download"><b>📥 Download App</b></a> &nbsp;•&nbsp;
  <a href="#about"><b>About</b></a> &nbsp;•&nbsp;
  <a href="#-key-features"><b>Key Features</b></a> &nbsp;•&nbsp;
  <a href="#-running--building-locally"><b>Build from Source</b></a> &nbsp;•&nbsp;
  <a href="CHANGELOG.md"><b>Release Notes</b></a> &nbsp;•&nbsp;
  <a href="https://github.com/arunsasidharan84/CCS_SleepStudio/issues"><b>Report Issue</b></a>
</p>

---

### 📥 Quick Download

Pre-built standalone desktop installers and application bundles are published through GitHub Releases:

| Platform | Variant | Package Type | Direct Download Link |
| :--- | :--- | :--- | :--- |
| **macOS** | **Full** | Universal ZIP | [CCSSleepStudio-macos.zip](https://github.com/arunsasidharan84/CCS_SleepStudio/releases/latest/download/CCSSleepStudio-macos.zip) |
| | **Lite** | Universal ZIP | [CCSSleepStudio-lite-macos.zip](https://github.com/arunsasidharan84/CCS_SleepStudio/releases/latest/download/CCSSleepStudio-lite-macos.zip) |
| **Windows** | **Full** | x64 Installer EXE | [CCSSleepStudio-Installer.exe](https://github.com/arunsasidharan84/CCS_SleepStudio/releases/latest/download/CCSSleepStudio-Installer.exe) |
| | **Lite** | x64 Installer EXE | [CCSSleepStudio-lite-Installer.exe](https://github.com/arunsasidharan84/CCS_SleepStudio/releases/latest/download/CCSSleepStudio-lite-Installer.exe) |
| **Linux (Debian / Ubuntu)** | **Full** | x64 DEB Installer | [CCSSleepStudio-linux-amd64.deb](https://github.com/arunsasidharan84/CCS_SleepStudio/releases/latest/download/CCSSleepStudio-linux-amd64.deb) |
| | **Lite** | x64 DEB Installer | [CCSSleepStudio-lite-linux-amd64.deb](https://github.com/arunsasidharan84/CCS_SleepStudio/releases/latest/download/CCSSleepStudio-lite-linux-amd64.deb) |
| **Linux (RHEL / AlmaLinux)** | **Full** | x86_64 RPM Installer | [CCSSleepStudio-linux-x86_64.rpm](https://github.com/arunsasidharan84/CCS_SleepStudio/releases/latest/download/CCSSleepStudio-linux-x86_64.rpm) |
| | **Lite** | x86_64 RPM Installer | [CCSSleepStudio-lite-linux-x86_64.rpm](https://github.com/arunsasidharan84/CCS_SleepStudio/releases/latest/download/CCSSleepStudio-lite-linux-x86_64.rpm) |

> 📦 **All Releases & Checksums:** View all published packages and assets on the **[GitHub Releases Page](https://github.com/arunsasidharan84/CCS_SleepStudio/releases/latest)**.  
> 🐧 **Automated Linux Workstations:** For one-line multi-user server installation, see [Quick Install for Linux](#-quick-install-for-linux-servers--multi-user-workstations).  
> 🍏 **macOS Gatekeeper:** For first-time launch instructions, see [macOS Gatekeeper Setup](#for-macos-users).

<p align="center">
  <img src="screenshots/main.png" width="920" alt="CCS Sleep Studio Main Window">
</p>

---

## About

**CCS Sleep Studio** is a standalone, cross-platform desktop application designed to assist researchers and clinicians in sleep EEG visualization, event annotation, sleep scoring, automated staging, and quantitative neurophysiology.

Built from the ground up using **Flutter** for a lightweight, fluid UI and a native **Rust** computational engine for signal processing, CCS Sleep Studio is inspired heavily by the Python-based [ScoringHero](https://github.com/SvennoNito/ScoringHero) repository. It operates without requiring complex Python or MATLAB environment configurations on the end user's computer, bringing near-instant response times to massive multi-hour polysomnography recordings.

### Core Modules
* **ScoringNidra**: Interactive sleep scoring and event annotation module supporting EDF/EDF+, Brain Products (`.vhdr`/`.vmrk`), Nihon Kohden (`.EEG`/`.LOG`), EMBLA (`.ebm`/`.esrc`), Orbit (`.orb`), and R09 (`.r09`).
* **AutoscoreNidra**: Automated sleep scoring engine supporting 9 state-of-the-art ML/DL models with multi-montage consensus scoring, SleepGPT refinement, and single-channel support in both interactive and batch modes.
* **AnalyseNidra**: High-throughput quantitative sleep EEG analysis and publication-grade PDF reporting engine operating across both single files and batch queues.

---

## 🌟 What's New in Version 1.26.0

* **Markers stay on screen after filtering:** Applying or changing display filters (or other settings) no longer removes markers and events from the waveform and hypnogram canvas.
* **Instantaneous display filtering:** Display filters are calculated only for the active visible window (with a real-signal buffer to prevent edge artifacts) using flat, allocation-free buffers and cached filter designs. Window redraws are instant with zero scrolling freeze on multi-channel recordings.
* **On-demand full-night spectrogram:** The full-night spectrogram (and its associated SWA trace) is toggleable via the toolbar **spectrogram [ON/OFF]** button, keeping initial file loading lightning fast while epoch spectra remain active.
* **Duration indicators under selection boxes:** When multiple regions are selected with the mouse, each box displays its individual duration underneath, with cumulative duration ($\Sigma$) shown under the final selection box.
* **Right-click channel management:** Right-click any channel trace or label to hide it, restore hidden channels individually or collectively, or jump straight to channel settings.
* **Direct filter settings shortcut:** Dedicated toolbar button opens the Filters configuration tab with one click.

> 📜 For older release highlights and detailed historical changes, see the complete **[CHANGELOG.md](CHANGELOG.md)**.

---

## 🔬 Key Features

### Multi-Channel EEG Signal Display
* View multiple EEG channels simultaneously with configurable vertical spacing.
* Adjust per-channel amplitude scaling and vertical offsets.
* Predefined, high-contrast channel colors (Black, Blue, Green, Magenta, Orange, Cyan).
* Add amplitude reference lines and 1-second grid overlays.
* **Stack channels** on a shared baseline for direct overlay comparison.
* **Robust z-standardization** (median/IQR normalization) for cross-channel comparison.
* Configurable time axis units: Seconds, Minutes, or Hours.

### Sleep Stage Scoring
* Score epochs (default 30s) as **Wake** (`W`), **N1** (`1`), **N2** (`2`), **N3** (`3`), **REM** (`R`), or **Inconclusive** (`I`).
* Clear a score using the `Delete` key.
* **Confidence Flagging**: Press `Q` (or the "Toggle uncertain" toolbar button) to flag an epoch as uncertain. Flagged epochs are visually marked on the hypnogram step timeline and saved with low-confidence metadata.
* Automatic save prompts on close if epochs remain unscored.

### Compare & Batch Scoring Comparison
* Import a second scoring file (**Compare → Import scoring for comparison**) to evaluate against the current scoring.
* **Disagreement Bands**: Epochs with conflicting scores are highlighted directly in the hypnogram timeline with a transparent red background band.
* **Premium Scoring Report Card**: Displays Cohen's Kappa score ($\kappa$) with strength labels, a dynamically color-shaded Confusion Matrix (green for agreement, red for disagreement), and per-stage Precision, Recall, and F1-Scores.
* **Batch Scoring Comparison**: Pair multiple scoring files interactively or auto-pair entire directories of reference vs comparison files. Generates a collated `Batch_Scoring_Comparison_Master.csv` output.

<p align="center">
  <img src="screenshots/compare_scoring.png" width="450" alt="Compare Scoring Window">
  <img src="screenshots/comparison_report.png" width="450" alt="Scoring Comparison Report">
</p>

### Event Annotation
* **13 event types**: Artefact (`A`) + 12 fully customizable event markers (`F1`–`F12`).
* Draw event regions directly on the signal using click-and-drag selection boxes.
* Real-time display of event duration (seconds) and amplitude while drawing.
* Double-click on an existing event to remove it.
* **Erase events in selection**: Draw selection boxes and press `Backspace` to delete all events inside the drawn region.

### File Formats & EEG Utilities
* **EMBLA / REMlogic (.ebm & .esrc / .esedb) Reader**: Native Rust reader for EMBLA single-channel binary files (`.ebm`) and REMlogic sleep stage scoring XML files (`.esrc`, `.esedb`), with physical unit calibration scaling and full directory assembly.
* **Nihon Kohden (.EEG) Native Reader**: Built-in Rust binary parser for Nihon Kohden `.EEG`, `.PNT` metadata, and `.21E` channel mapping files, with physical voltage calibration and full recording payload assembly.
* **EEG Utilities Module**: Perform signal downsampling, time cropping, channel renaming, channel filtering, and patient header anonymization (Patient ID, Name, Sex, DOB) for single files or in batch across EDF, Nihon Kohden, Orbit, and EMBLA recordings.
* **Orbit (.orb / .signal) File Loader**: Native binary and JSON-lines parser for Orbit recordings, complete with gap-filling, linear interpolation, and automatic calibration scaling.
* **EDF+ Annotations Reader**: Parses TAL structures directly from annotations channels.
* **Polyman CSV Interval Loader**: Imports sleep events and labels from Polyman text logs.
* **YASA List Parser**: Retains epoch alignment by preserving empty lines as unscored elements.

### Signal Filtering & Auto Spectrogram
* Apply high-pass, low-pass, and notch filters independently to each channel (toolbar **filter** button, or the Filters tab of the configuration).
* Zero-phase Chebyshev Type 2 filters, applied as display filters: only the visible window (plus a margin of real signal) is filtered, so filtering never slows down scrolling and never triggers a full-night recomputation.
* The full-night spectrogram is off by default; turn it on with the **spectrogram** toolbar button.
* Live magnitude response plot updates in real time within the configuration dialog.
* **Auto Spectrogram Power Scaling**: Automatically calculates 2nd and 98th log10 power percentiles upon loading signals, keeping color scaling ranges modifiable.

---

## AutoscoreNidra — Automated Sleep Scoring (Full App Only)

**AutoscoreNidra** is the automated sleep-scoring system within CCS Sleep Studio. It provides a consistent UI, dependency preflight, live epoch progress, and local execution for modern deep-learning and machine-learning staging models:

* **Multi-Montage Consensus Scoring**: AutoscoreNidra independently scores every selected EEG channel and clinically valid reference combination. It then combines their epoch-wise probabilities into one consensus hypnogram, reducing dependence on any single channel or montage.
* **Optional SleepGPT Sequence Refinement**: After the base consensus scoring, SleepGPT can apply a condition-agnostic sequence correction pass. It uses the temporal sleep-stage sequence to reduce implausible transitions without requiring a diagnosis-specific model.
* **Single-Channel EEG Support**: AutoscoreNidra can score recordings containing only one usable EEG channel. When multiple channels or reference combinations are available, it automatically expands to the multi-montage consensus workflow.
* **Clear Scoring Filenames**: Final hypnograms use the suffix `_scoring.json`, for example `recording_yasa_scoring.json` or `recording_yasa_sleepgpt_scoring.json`, so they are easy to distinguish from AnalyseNidra and diagnostic JSON files.
* **9 Supported Staging Models**:
  1. **YASA LightGBM Consensus**: Lightweight boosted tree stager.
  2. **Offline U-Sleep Consensus**: Local convolutional neural network inference.
  3. **Luna POPS**: Probabilistic Sleep Stager (`lunapi` adapter).
  4. **Greifswald Sleep Stage Classifier (GSSC)**: Clinical model stager.
  5. **TinySleepNet**: Pretrained PhysioEx model.
  6. **SeqSleepNet**: Sequence-to-sequence model.
  7. **SleepTransformer**: Attention-based transformer stager.
  8. **Dreamento**: Feature-engineered YASA classifier.
  9. **SleepEEGpy**: Standard MNE/YASA scorer.
* **Batch AutoscoreNidra**: Queue multiple EDF/ORB/SIGNAL files for sequential background scoring with live status and epoch progress.
* **Interactive Checklists**: Configure stager EEG, EOG, EMG, and Reference signals dynamically using checklist selectors instead of manual comma-separated text input fields.

<p align="center">
  <img src="screenshots/autoscoring_snapshot.png" width="850" alt="Autoscoring Configuration and Model Run">
</p>

---

## AnalyseNidra — Advanced Sleep EEG Analysis

**AnalyseNidra** is the advanced quantitative neurophysiology subsystem, written in native Rust. It performs fast, multithreaded analysis of sleep architecture, spectral power, phase-amplitude coupling (PAC), slow waves, spindles, aperiodic dynamics, nonlinear complexity, and regional statistics.

By leveraging Rust's compiler optimizations and parallel execution (via `rayon`), the entire analysis runs over 6x faster than standard Python pipelines.

### Features
* **Spectral Analysis**: Fast Welch periodogram computation with median averaging.
* **Aperiodic Fit**: Native Levenberg-Marquardt implementations of FOOOF (Fitting Oscillations & One-Over-F) and IRASA (Irregularly Resampled Auto-Spectral Analysis) to isolate true oscillatory peaks from the background aperiodic 1/f slope.
* **Spindle Detection**: Port of the YASA (Yet Another Spindle Algorithm) spindle detection method.
* **Slow-Wave Detection**: Port of YASA slow-wave detection, including `sw_all_density_calc` normalized as slow-wave count per total NREM minute.
* **Phase-Amplitude Coupling (PAC)**: TensorPAC-compatible modulation index calculation for Slow-Wave/Sigma coupling.
* **Regional Compilation**: Aggregates all spectral features and event detections across scalp channels.
* **Master-Sheet Compilation**: Combines regional CSV outputs from the latest batch or independently completed AnalyseNidra runs into one provenance-preserving CSV.
* **Publication-Grade Sleep Report**: Generates a five-page PDF covering sleep continuity, thalamocortical coupling, FOOOF/IRASA aperiodic trends, oscillatory peaks, entropy, fractal dynamics, Lempel-Ziv complexity, autocorrelation windows, and a plain-English interpretation guide. Configurable study, investigator, and subject metadata can be added from the Report tab in Configuration.

### Command-Line Usage & Parameters
For advanced CLI workflows, the `analyse-nidra` executable can be invoked directly from the command line:

```sh
analyse-nidra <recording.edf> <scoring.json> [core.json|-] [pac.json|-] [slow-waves.json|-] [spindles.json|-] [regional.csv|-] [options]
```

#### Positional Arguments:
1. `<recording.edf>`: **[Required]** Absolute path to the raw input sleep EEG recording (EDF format).
2. `<scoring.json>`: **[Required]** Path to the epoch-by-epoch sleep scoring JSON file.
3. `[core.json|-]`: Path to save the core spectral, temporal, and nonlinear features per stage/channel in JSON format. Use `-` to skip writing this file.
4. `[pac.json|-]`: Path to save Phase-Amplitude Coupling (PAC) matrices. Use `-` to skip.
5. `[slow-waves.json|-]`: Path to save detected slow wave events and summary statistics. Use `-` to skip.
6. `[spindles.json|-]`: Path to save detected spindle events and summary statistics. Use `-` to skip.
7. `[regional.csv|-]`: Path to compile and save the 253-column regional EEG metric CSV. Use `-` to skip.

#### Named Options:
- `--channels <names>`: Comma-separated list of EEG channels to include in the analysis (e.g., `--channels F3,F4,C3,C4,O1,O2`). Defaults to `F3,F4,C3,C4,O1,O2`.
- `--references <names>`: Comma-separated list of reference channels (e.g., `--references M1,M2` or `A1,A2`). Samples from reference channels are averaged and subtracted sample-wise. If not specified, defaults to `M1,M2`. Can be omitted or left blank to run without re-referencing.

<p align="center">
  <img src="screenshots/analyse_nidra_snapshot.png" width="450" alt="analyseNidra Region Analysis Configuration">
  <img src="screenshots/sleep_analysis_report.png" width="450" alt="Publication Sleep Analysis Report">
</p>

---

## 🎨 UI & Visualization Features

* **Smooth Draggable Plot Borders**: Manually adjust the vertical boundaries between the Spectrogram, Hypnogram, and Periodogram panels in real time by dragging. Resizing is cumulative, smooth, locked to respect screen size limits, and is automatically saved to the recording's `.config.json` file.
* **Consolidated Batch Tab**: Houses Batch AutoscoreNidra, Batch AnalyseNidra, and AnalyseNidra master-sheet compilation in one workspace.
* **Hypnogram Horizontal Zoom**: View the hypnogram step chart fully (Full Night) or zoom in on 100, 200, or 400 epoch windows centered around the active epoch. All mouse taps map correctly to coordinates within the zoomed viewport.
* **Wavelet Spectre Toggle**: The complex Morlet wavelet panel is off by default to avoid unnecessary computation and vertical scrolling, and can be enabled when needed.
* **Slow Wave Activity (SWA) Toggle**: Show or hide the SWA delta-power overlay on the hypnogram timeline, hiding its slider controls when inactive.
* **EEG Guide Customization**: Modify the thickness and color of the horizontal reference guide lines in the EEG viewport.
* **Centred Label Layout**: Stage labels on the Hypnogram panel are vertically centered on their corresponding colored bands.

---

## ⚡ Speed & Architectural Highlights

CCS Sleep Studio overcomes the main performance bottlenecks of standard Python-based visualization tools:

1. **Hybrid Flutter + Rust FFI Pipeline**: Heavy mathematical operations (zero-phase Chebyshev/Butterworth filters, Welch periodograms, Morlet wavelets) are written in Rust, leveraging SIMD compiler optimizations and multi-threaded processing via `rayon`.
2. **Isolate-Based Background Worker**: Computations run off the main thread in background Dart **Isolates**, leaving the main interface to render at a locked 60+ FPS.
3. **Zero-Copy Memory Access**: Transfers between Dart and Rust utilize direct pointers and `.asTypedList` buffer access to avoid slow copy loops.
   * *Benchmarks*: Night-wide spectrogram updates complete in just **19 ms**, and wavelet time-frequency updates finish in **113 ms**.
4. **Self-Contained Executables**: Zero environment configuration required. Even the Full edition bundles its model runtimes inside a standalone package.

---

## Sample PSG Data

The repository includes a small demonstration dataset in [`SamplePSGData`](SamplePSGData/) for testing the viewer, manual scoring import, batch workflows, and AnalyseNidra report generation:

* `SamplePSGData/Data/` contains four EDF PSG recordings.
* `SamplePSGData/ManualScorings/` contains matching manual scoring EDF files with the same base filenames.
* `SamplePSGData/Template_config.json` provides a reusable configuration template for the sample recordings.

Load a recording from `SamplePSGData/Data/`, then import the corresponding file from `SamplePSGData/ManualScorings/` as the scoring/comparison file.

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

### For macOS Users
Because the application is signed ad-hoc, clear the macOS Gatekeeper quarantine flag after extracting:
1. Download & Extract the zip folder into your **Downloads** folder.
2. Open **Terminal**.
3. Run:
   ```sh
   xattr -rd com.apple.quarantine ~/Downloads/CCS\ Sleep\ Studio.app
   ```
4. Drag and drop **CCS Sleep Studio.app** into the **Applications** folder.

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
| `Backspace` | Erase events in drawn selection |
| `Z` | Zoom on selected EEG |
| `Ctrl+K` | Open K-Complex Detection (MT-KCD) |
| `Ctrl+Shift+S` | Open Spindle Detection (MT-Spindle) |
| `Ctrl+C` | Open Settings/Configuration Dialog |

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
