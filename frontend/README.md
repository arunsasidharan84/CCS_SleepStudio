# CCS Sleep Studio - The High-Performance Open-Source Sleep EEG Visualization, Annotation & Scoring Software

Welcome to **CCS Sleep Studio**, a high-performance, cross-platform desktop application designed to assist researchers and clinicians in sleep EEG visualization, event annotation, sleep stage scoring, and quantitative EEG analysis.

CCS Sleep Studio is comprised of the following key modules:
*   **ScoringNidra**: Interactive sleep scoring and event annotation module.
*   **AutoscoreNidra**: Automated sleep scoring module.
*   **AnalyseNidra**: Automated sleep EEG analysis and reporting module.

Rebuilt from the ground up using **Flutter** for a lightweight, fluid UI, and **Rust** for native-speed signal processing, **CCS Sleep Studio** is inspired heavily from the Python-based [ScoringHero](https://github.com/SvennoNito/ScoringHero) repository. It operates without any complex Python or MATLAB runtime setup, bringing near-instant response times to massive sleep EEG files.

![CCS Sleep Studio Main Window](screenshots/main.png)

---

## About

**CCS Sleep Studio** is designed to overcome the performance lag and dependency hurdles of traditional sleep scoring applications. By combining the reactive rendering of Flutter with the computational muscle of Rust (via background Isolates and FFI), the application effortlessly handles full-night EEG recordings, real-time filtering, dynamic Welch periodograms, and Morlet wavelet decompositions.

---

## 📥 Download Pre-built Releases

No installation of Python, MATLAB, or other runtime dependencies is required. Standing alone as pre-compiled binaries, you can download the latest builds directly from the GitHub Releases Page:

👉 **[Download Application Packages from GitHub Releases Page](https://github.com/arunsasidharan84/CCS-Sleep-Studio/releases)**

### For Mac Users
Because the application is signed ad-hoc, you must clear the macOS Gatekeeper quarantine flag after downloading and extracting it:
1.  Open **Terminal** and navigate to your extracted folder.
2.  Run the following command:
    ```sh
    xattr -rd com.apple.quarantine "CCS Sleep Studio.app"
    ```
3.  Right-click `CCS Sleep Studio.app` and choose **Open**.

---

## ⚡ Speed & Architectural Enhancements

CCS Sleep Studio overcomes the main performance bottlenecks of standard Python-based visualization tools:

1.  **Hybrid Flutter + Rust FFI Pipeline**: Heavy mathematical operations (zero-phase Chebyshev/Butterworth filters, Welch periodograms, Morlet wavelets) are written in Rust, leveraging SIMD compiler optimizations and multi-threaded processing via `rayon`.
2.  **Isolate-Based Background Worker**: Computations run off the main thread in background Dart **Isolates**, leaving the main interface to render at a locked 60+ FPS.
3.  **Zero-Copy Memory Access**: Transfers between Dart and Rust utilize direct pointers and `.asTypedList` buffer access to avoid slow copy loops.
    *   *Benchmarks*: Night-wide spectrogram updates complete in just **19 ms**, and wavelet time-frequency updates finish in **113 ms**.
4.  **No Dependency Hell**: Runs without setting up a Python virtual environment or virtual dependencies. Executables are entirely self-contained.

---

## 🚀 Running & Building Locally

### Prerequisites
*   [Flutter SDK](https://docs.flutter.dev/get-started/install) (latest Stable)
*   [Rust Toolchain](https://www.rust-lang.org/tools/install) (cargo)
*   For Windows installer: [Inno Setup](https://jrsoftware.org/isinfo.php) (iscc compiler)

### 1. Build the Rust Backend
Compile the native library for your platform first:
```sh
cd rust_backend
cargo build --release
```

### 2. Run the App
Start the app in development mode:
```sh
# Run on macOS
flutter run -d macos

# Run on Windows
flutter run -d windows
```

### 3. Compile Production Release
To compile the release packages:
```sh
# macOS Release (.app)
flutter build macos --release

# Windows Release (.exe and Inno Setup Installer)
flutter build windows --release
iscc windows/installer.iss
```

---

## 🛠️ Folder Structure

*   `/lib`: Flutter desktop application and UI code.
    *   [lib/main.dart](lib/main.dart): App entry point and permission bypass.
    *   [lib/src/eeg_backend.dart](lib/src/eeg_backend.dart): Dart FFI bridge, isolate wrappers, and display filters.
    *   [lib/src/app.dart](lib/src/app.dart): Main application viewport, layouts, and panels.
*   `/rust_backend`: Rust `cdylib` library crate containing pure native signal processing.
*   `/windows/installer.iss`: Script to compile the Windows release bundle into a standalone installer.

---

## Features

### Multi-Channel EEG Signal Display
*   View multiple EEG channels simultaneously with configurable vertical spacing.
*   Adjust per-channel amplitude scaling and vertical offsets.
*   Predefined, high-contrast channel colors (Black, Blue, Green, Magenta, Orange, Cyan).
*   Add amplitude reference lines and 1-second grid overlays.
*   **Stack channels** on a shared baseline for direct overlay comparison.
*   **Robust z-standardization** (median/IQR normalization) for cross-channel comparison.
*   Configurable time axis units: Seconds, Minutes, or Hours.

### Sleep Stage Scoring
*   Score epochs (default 30s) as **Wake** (`W`), **N1** (`1`), **N2** (`2`), **N3** (`3`), **REM** (`R`), or **Inconclusive** (`I`).
*   Clear a score using the `Delete` key.
*   **Confidence Flagging**: Press `Q` (or the "Toggle uncertain" toolbar button) to flag an epoch as uncertain. Flagged epochs are visually marked on the hypnogram step timeline for later review and saved with low-confidence metadata.
*   Automatic save prompts on close if epochs remain unscored.

### Compare Scoring
*   Import a second scoring file (**Compare → Import scoring for comparison**) to evaluate against the current scoring.
*   **Disagreement Bands**: Epochs with conflicting scores are highlighted directly in the hypnogram timeline with a transparent red background band and a red bottom edge indicator. The disagreement bands are drawn in the background, ensuring that the step chart lines remain clearly visible.
*   **Premium Scoring Report Card**: Displays Cohen's Kappa score ($\kappa$) with strength labels, a dynamically color-shaded Confusion Matrix (green for agreement, red for disagreement, opacity scaled based on counts), and per-stage Precision, Recall (Sensitivity), and F1-Scores.

![Compare Scoring Window](screenshots/compare_scoring.png)
![Scoring Comparison Report](screenshots/comparison_report.png)

### Event Annotation
*   **13 event types**: Artefact (`A`) + 12 fully customizable event markers (`F1`–`F12`).
*   Draw event regions directly on the signal using click-and-drag selection boxes.
*   Real-time display of event duration (seconds) and amplitude while drawing.
*   Double-click on an existing event to remove it.
*   **Erase events in selection**: Draw selection boxes and press `Backspace` to delete all events inside the drawn region.
*   Events are rendered dynamically on both the signal view and the hypnogram timeline.

<p align="center">
    <img src="screenshots/artefact.png" width="49%" alt="Artefact event marked on signal" />
    <img src="screenshots/arousal.png" width="49%" alt="Arousal event marked on signal" />
</p>

### Smart Navigation
Jump to key epochs instantly using dedicated navigation controls:

| Button / Action | Description |
|----------------|-------------|
| **[unscored]** | Jump to the next epoch that hasn't been scored yet |
| **[uncertain]** | Jump to the next epoch flagged with low confidence |
| **[transition]** | Jump to the next sleep stage change |
| **[event]** | Jump to the next epoch containing a marked event |
| **Epoch spinbox** | Type any epoch number to jump there directly |
| **Click on hypnogram** | Navigate to any time point by clicking the hypnogram |
| **Click on spectrogram** | Navigate to any time point by clicking the spectrogram |

### Spectrogram Panel
*   Off by default (it is the slowest step when opening long recordings); turn it on with the **spectrogram [ON/OFF]** toolbar button. The setting is saved per recording.
*   Welch power spectral density computed across the full recording.
*   Configurable frequency range (default: 0–20 Hz) and adjustable log10 power limits.
*   Cached computation in native Rust backend — instant navigation with zero lag.
*   Uses the channel's derivation (re-referencing, polarity); display filters do not change it, so changing a filter never recomputes it.

### Hypnogram Panel
*   Full-night sleep architecture timeline with color-coded stages.
*   **Slow-wave activity (SWA) overlay** showing delta power across the night with adjustable median filter smoothing (computed with the spectrogram, so it needs the spectrogram turned on).
*   Disagreement highlights and uncertainty markers are drawn directly on the hypnogram step blocks.

![Hypnogram Disagreement Markers and Uncertainty Highlights](screenshots/annotations_markers.png)

### Morlet Wavelet Time-Frequency Panel

The wavelet panel is disabled by default to preserve the primary scoring layout and avoid unnecessary scrolling. Enable it from the toolbar or configuration dialog when detailed time-frequency inspection is required.

### AutoscoreNidra and AnalyseNidra

* **AutoscoreNidra** independently scores each selected EEG channel and valid reference combination, then aggregates the epoch-wise probabilities into a consensus hypnogram.
* It supports single-channel EEG while automatically using multi-montage consensus scoring when additional channels or references are available.
* An optional, condition-agnostic SleepGPT pass refines the consensus stage sequence to reduce physiologically implausible transitions.
* AutoscoreNidra provides single-recording and batch execution with validated backend invocation and live progress.
* **AnalyseNidra** provides advanced sleep EEG analysis, regional CSV generation, master-sheet compilation, and the four-page quantitative PDF report.
*   Complex Morlet wavelet decomposition via FFT-based convolution.
*   4 normalization modes: Raw Power, L2-Normalized (unit energy), Z-Standardized, and dB (median baseline).
*   Linear or logarithmic frequency scale.
*   Extended epoch padding to minimize edge artifacts.
*   Toggles on/off to save screen space.
*   Automatically respects display filters, referencing, and polarity configurations.

### Periodogram Panel
*   Welch periodogram of any user-selected EEG region.
*   Draw a selection box on the signal to compute the power spectrum of that region.
*   Updates automatically when a selection is drawn or modified.

### Signal Filtering
*   Apply **high-pass**, **low-pass**, and/or **notch** filters to each EEG channel independently.
*   Zero-phase Chebyshev Type 2 filters.
*   **Tab View Integration**: Located directly inside the Configuration Dialog as the 8th tab; the toolbar **filter** button opens it directly.
*   Live magnitude response plot updates in real time.
*   Display filters: only the visible window is filtered, with a few seconds of real signal on each side so the result equals filtering the whole night. Applying a filter redraws the window instantly and keeps all markers.
*   Filters affect display, zoom, periodograms, and wavelets, while raw signal power computations (spectrogram, SWA) remain unaffected.

### Channel Display
*   Right-click a channel's name or trace to hide it, show hidden channels again, or open its settings.
*   Mouse selection boxes show their duration underneath; with several boxes the last one also shows the cumulative duration (Σ).

![Filter Tab](screenshots/filter.png)

### Automatic K-Complex & Spindle Detection (MT-KCD and MT-Spindle)
*   One-click K-complex and spindle detection via multitaper-based algorithms.
*   Run using background Dart isolates on the native Rust backend.
*   Detections are imported as event annotations for review, modification, and export.

### Configuration & Templates
*   Open the Configuration Dialog (`Ctrl+C`) to manage channels, colors, visual limits, and filtering.
*   Save configuration profiles as `.json` files to act as reusable scoring templates.
*   Load configurations dynamically, or restore factory defaults instantly.

![Configuration Menu & Template Manager](screenshots/config_menu.png)

---

## ⌨️ Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
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

## 📜 Release Log & Changelog

### Version 1.3.0
*   **Branding & Name Consistency**: Application name unified as **CCS Sleep Studio** across code, UI labels, documentation, and Debian/RPM packaging scripts.
*   **Batch Scoring Comparison**: Added interactive 2-column paired comparison table in Batch tab with **Auto-Pairing 2 Folders** support. Computes epoch-by-epoch agreement, Cohen's $\kappa$, stage-by-stage precision/recall/F1 scores, and exports `Batch_Scoring_Comparison_Master.csv`.
*   **AnalyseNidra Non-Sleep Stage Parsing**: Updated Rust backend `analyseNidra/src/hypnogram.rs` to seamlessly parse non-sleep stages (`Inconclusive`, `None`, `Unscored`, `Unknown`, `?`, `Uncertain`, `Uncertainty`, `NOT SCORED`, `N/A`) without raising errors or crashing.
*   **Keyboard Shortcuts**: Added `N`, `0`, `Numpad 0`, `Delete` for **None / Unscored (`?`)** stage and `U` / `Q` for **Uncertainty** toggle during manual scoring.
*   **Auto Spectrogram Power Scaling**: Implemented automatic 2nd–98th percentile log10 power colorbar scaling on load while retaining editable min/max values in config dialog.
*   **EDF Utilities Module**: Added interactive single-file and batch utility dialog for signal downsampling, time cropping, channel renaming, channel filtering, and patient header anonymization (Patient ID, Name, Sex, DOB).
*   **Nihon Kohden (.EEG) Native Rust Loader & EDF Converter**: Implemented binary parser in Rust (`bridge/src/nk.rs`) porting Brainstorm's `in_fopen_nk.m`, `in_fread_nk.m`, and `in_channel_nk.m`. Supports reading `.EEG`, `.PNT` metadata, and `.21E` electrode mapping files with EDF conversion export.

### Version 1.2.12
*   Initial release of **AnalyseNidra** regional spectral analysis, EEG spectrogram heatmaps, and MT-Spindle / MT-KCD detection pipelines.

