# Changelog — CCS Sleep Studio

All notable changes to **CCS Sleep Studio** are documented in this file.

---

## [1.29.1]
*   **Bundled Group Statistics script in desktop app packages:** Fixed `can't open file '//backend/group_stats.py'` error when inspecting data or running models from installed macOS `.app`, Windows, and Linux standalone application packages. The statistical engine script is now bundled directly as an embedded Flutter asset (`assets/group_stats.py`) and automatically extracted to an isolated temporary location if external script paths are not found.
*   **CI/CD packaging for Group Statistics:** Updated release build automation to copy `group_stats.py` into macOS app bundle resources (`Contents/Resources/`), Windows runner release outputs, and Linux `.deb`/`.rpm` install packages.

---

## [1.29.0]
*   **Group-level statistical analysis & publishing workbench:** Added a dedicated "5  Group statistics" tab in the Batch Analysis workspace. Users can interactively load any batch results master CSV (`AnalyseNidra_master_sheet.csv`) or previous runs with one click, along with optional demographic metadata.
*   **State-of-the-art modeling (LMM & GLM):** Automatically selects Linear Mixed-Effects Models (LMM) with subject-level random intercepts for repeated measures and multi-channel metrics (`Outcome ~ Group * Channel + Covariates + (1 | Subject)`), and General Linear Models (GLM / ANOVA Type II) for single-measure macroarchitecture parameters.
*   **Automated post-hoc testing & significance annotations:** Conducts pairwise contrasts with Benjamini-Hochberg FDR, Tukey HSD, or Bonferroni adjustments, computing Cohen's d effect sizes.
*   **Interactive visualization & publication plot generation:** In-app interactive plot viewer renders boxplots with individual jittered data points and annotated post-hoc significance brackets (`*`, `**`, `***`, `****`, `ns`). Automatically saves 300 DPI publication-quality PNG figures into a datastamped `plots/` folder.
*   **Journal-friendly CSV tables:** Automatically outputs APA-structured tables for descriptive statistics (N, Mean ± SD, Median, IQR, Min, Max), model fixed effects, and pairwise contrasts.
*   **Publishing-ready scientific reports (DOCX & PDF):** Generates publication-ready manuscripts in Microsoft Word (`.docx`), PDF (`.pdf`), or both, featuring executive summaries, methodology sections, APA tables, and embedded high-resolution figures with captions.
*   **Windows in-app updater SSL certificate fix:** Resolved `CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate` during in-app updates on Windows by trusting GitHub release binary download redirects to AWS S3.
*   **Linux multi-user server temp permission fix:** Resolved `PathAccessException: Cannot delete file (Operation not permitted, errno = 1)` on shared Linux servers by allocating isolated temporary directories for downloaded installers and scripts.
*   **Windows title bar display:** Updated native Win32 window creation title from `sleep_eeg_desktop` to `CCS Sleep Studio`.

---

## [1.28.0]
*   **CAP analysis in batch processing & master sheet integration:** Cyclic Alternating Pattern (CAP) analysis is now integrated into both the Batch EEG Pipeline and Batch PSG Polygraphy workflow. All CAP metrics are formatted with the standard `CAP_` prefix across CSV headers, and companion `_cap.json` metrics are automatically consolidated into `AnalyseNidra_master_sheet.csv`.
*   **Sleep cycle prefix standardisation ("Cyc"):** Updated sleep cycle metrics across ACCS, NeuroLoopGain (NLG), and Regional CSV outputs to use the standard `Cyc` prefix (e.g. `Cyc1_start_epoch`, `Cyc1_Sleep_duration_cycle`, `NLG_SW_Cyc1_NREM`) while maintaining backwards-compatible fallbacks.
*   **Autoload scorings from external folder:** Added a dedicated external scoring folder picker and text field in the Batch Recordings panel. The loader automatically discovers matching scoring files (`.json`, `.csv`) across both the external directory and the recording directory, matching by full stem and base stem.
*   **Case-insensitive and flexible channel matching:** Channel lookups across native EDF headers, BrainVision VHDR files, and frontend feature detectors are now fully case-insensitive and tolerant of common prefixes and reference suffixes (`c3`, `C3`, `c3-m2`, `EEG C3-REF`).
*   **Direct loading of preprocessed files in batch analysis:** Preprocessed recordings (`*_clean.edf`, `*_stimclean.edf`, etc.) can now be loaded directly without being discarded or re-triggering raw file preprocessing. Added a "Prefer preprocessed files" toggle, and automated base-stem resolution pairs preprocessed files with parent scorings automatically.
*   **Official Windows app logo & taskbar icon:** Generated an official multi-resolution `app_icon.ico` (256x256 down to 16x16) for Windows builds and added native `WM_SETICON` handling for reliable taskbar and title bar icon rendering. Added the official logo to the app top bar.
*   **Multi-instance window support & datestamped batch exports:** Added `Cmd+N` / `Ctrl+N` to launch independent app windows to analyse multiple recordings simultaneously. Batch result CSV files now include timestamps to prevent accidental overwrites, and a "Clear File List" button allows quick reloads of batch queues.

---

## [1.27.1]
*   **Video cursor and slider time unit matching:** Video cursor badge and video slider elapsed format strictly respect active time units (`Seconds` as `...s`, `Minutes` as `...m`, `Hours` as `...h`, and `Clock time`).
*   **Easy marker removal & selection box dismissal:** Right-clicking near any marker displays a prominent Delete Marker option with generous hit tolerance; clicking the waveform dismisses active selection boxes; pressing `Escape` clears active selections; Markers & Annotations dialog includes per-row delete and Clear All options.
*   **Fixed AnalyseNidra detection error and app crash on .EEG files:** Wrapped AnalyseNidra detection with native EDF conversion (`_nativeEdfFor`) and guarded progress dialog dismissals against duplicate navigator pops that caused a blank screen and crash.
*   **High-performance streaming EDF conversion:** Replaced dynamic Dart `List<int>` byte allocations in `_writeLoadedEegToEdf` and `processEdfFile` with zero-allocation `ByteData` streaming via `RandomAccessFile`, cutting .EEG conversion time from 60 seconds to ~1 second with near-zero memory footprint. Automatically reuses in-memory EEG and downsamples high-frequency recordings (>200 Hz) for rapid analysis.
*   **Utilities review & enhancements:** Enabled non-EDF file support across all Utilities options, including AnalyseNidra Advanced Analysis, respiratory OSA, PLMS, and CAP analyses.

---

## [1.27.0]
*   **Prompt to update at startup:** The app automatically checks for newer releases at startup and presents a dialog with release notes and one-click update actions. Fails silently when offline.
*   **Smooth video slider scrubbing:** Eliminated lag and glitchy scrolling during video slider dragging by throttling libmpv seeks and coalescing waveform epoch paging at 60 FPS.
*   **Click-to-add markers:** Added ability to add point and duration markers directly at mouse click: right-click on the waveform for instant actions (Artifact, Arousal, or full dialog) or double-click to open the Add Marker dialog.
*   **Spectrogram space distribution:** When full-night spectrogram is disabled, the panel and splitter are hidden and 100% of top strip width is redistributed to the hypnogram and periodogram.
*   **Video time format matching:** Video slider and waveform cursor match the window's active time mode (`eegPanelTimeUnit`), showing elapsed time `HH:MM:SS` when in elapsed mode.
*   **User-definable frequency bands:** Added support for adding, editing, and deleting spectral frequency bands in config and batch processing, including a preset for Theta-Alpha (4–12 Hz).
*   **Windows update SSL certificate fix:** Added custom trust fallback for GitHub API and release download hosts to prevent `CERTIFICATE_VERIFY_FAILED` on Windows.

---

## [1.26.0]
*   **Markers stay on screen after filtering.** Applying or changing display filters (or other settings) no longer removes the markers and events from the waveform and the hypnogram.
*   **Much faster display filtering.** Filters are display filters: only the window on screen is filtered (with a few seconds of real signal on each side so there is no edge artefact), using flat, allocation-free buffers and cached filter designs. Applying a filter redraws the current window instantly instead of re-filtering the whole night, so long multi-channel recordings no longer freeze on low-spec computers and scrolling stays fast. The filtered window now matches filtering the whole night exactly (previously the window edges showed a filter transient).
*   **Spectrogram off by default.** The full-night spectrogram (and the SWA trace computed with it) is the slowest step when opening long files, so it is now off by default. Turn it on with the new **spectrogram [ON/OFF]** toolbar button; the setting is saved with the recording's configuration. The current epoch's spectrum (right-hand panel) is still shown.
*   **Durations under every selection box.** When several regions are selected with the mouse, each box shows its own duration underneath, and the last box also shows the cumulative duration (Σ) of all boxes. The total no longer appears in the status bar.
*   **Hide a channel with a right-click.** Right-click a channel's name or trace to hide it, show hidden channels again (one by one or all), or open the channel settings.
*   **filter button** in the toolbar opens the Filters tab of the configuration directly.

---

## [1.25.0]
*   **Restored Sigma band (10–16 Hz) power extraction:** Fixed an issue where the AnalyseNidra feature engine omitted the Sigma band (`*_Sigma_PSD`, `*_Sigma_FOOOF`, `*_Sigma_Irasa`), leaving Sigma columns blank across all sleep stages (N1, N2, N3, REM) in the regional CSV and master compilation sheet.
*   **Review windows of 60 s, 2 min and 5 min** (toolbar, next to ◀ ▶) for respiratory and CAP events. The window is centred on the current epoch, epoch boundaries are marked and the current epoch is outlined, and ◀ ▶ page by the window. Stages are assigned only in the 30-s scoring window, and switching back to 30 s lands on the epoch that was at the centre.
*   **Night timeline** (toolbar): an expanded overnight view with the hypnogram (one lane per stage), one row per event type (OA, CA, MA, hypopnea, RERA, desaturation, arousal, LM/PLM, CAP, plus scored annotation labels) and the SpO2 trend. Hovering shows the epoch, time, stage and events; clicking goes to that epoch, and double-clicking goes there and closes the view.
*   **Respiratory scoring refinements** (checked against the EDF-annotated apneas of four GoaSleep OSA nights):
    *   Apneas separated by recovery breaths are now scored as separate events, timed by the apnea itself, instead of one long event spanning the whole run of reduced breathing. Median apnea durations now match the annotations (15–25 s, previously 23–38 s).
    *   The slow decay of AC-coupled pressure sensors after the last breath no longer hides an apnea.
    *   A flow sensor that fails for a large part of the night is now recognised, and events there are scored on RIPsum/effort as the AASM allows.
*   **PLM scoring (AASM mode):**
    *   Leg EMG bursts shorter than 0.5 s are no longer treated as LMs.
    *   Bilateral LMs are judged by each leg's duration (0.5–10 s), not by their combined span.
    *   Movements longer than 10 s no longer break a PLM series; under WASM 2016 they still do.
    *   On the GoaSleep PLM recording, the total number of PLMs now matches the clinical report (494 vs 510; previously 362).
*   **Automatically detected arousals** are shown as *Arousal (auto)* markers on the waveforms and hypnogram, can be shown or hidden in *Show / Remove … Markers*, and have their own row in the PDF respiratory timeline (with scored arousals).
*   **PDF report:** pages for analyses without data (spindle/slow-wave, aperiodic, complexity, respiratory, PLM, CAP) are left out instead of being printed empty. The SpO2 axis labels on the respiratory page are fixed.

---

## [1.24.1]
*   **Polygraphic channels recorded at their own sampling rates are now shown at the right time.** EDF channels with a different rate from the EEG (e.g. flow and effort at 100 Hz, snore at 500 Hz, SpO2 at 1 Hz) are resampled to the common rate when loaded. Before, they were drawn against the EEG's clock: flow and effort ran at twice the speed and were out of step with the scored events, and 1 Hz SpO2 was not drawn at all.
*   **Display scaling suited to each kind of channel** (new *Scaling* column in the channel settings):
    *   **Auto:** flow, pressure, effort belts and snore are fitted to their row from the whole night's amplitude, so their relative changes (hypopnoeas) stay comparable across the night.
    *   **Level:** SpO2, pulse, body position and CO2 are drawn on an absolute range, e.g. SpO2 70–100 %, shown under the channel name.
    *   **Fixed µV:** EEG, EOG, EMG and ECG keep the µV scale.
    *   Polygraphic traces are kept inside their own row. The per-channel zoom range is widened to 5–5000 %.
    *   Polygraphic channels in saved settings switch to the new modes automatically, and their old manual gain is reset to 100 %.

---

## [1.24.0]
*   **Synchronised Video via media_kit / libmpv:** Full playback support for Nihon Kohden MPEG transport streams (`.m2t` with H.264 video and MP2 audio) and multi-hour recordings across all platforms. Reads `.VF2` video index files to seamlessly synchronise multi-camera hourly segments across the entire night with millisecond precision.
*   **Waveform Scrub Cursor & Floating Video Window:** Real-time red scrub cursor on the EEG waveform tracks video playback; drag to scrub across the recording. Resizable floating video window with independent camera controls (per-camera time offset, mute, toggle, and double-click to solo). Includes a full-night slider, playback rate control, and a dedicated Stop button that unloads media.
*   **Batch Metadata Integration:** New "Load metadata (CSV / XLSX)…" tool in the Batch Recordings panel. Automatically matches recording rows by file name, parent folder name, or fuzzy partial match with column auto-detection and an interactive preview modal. Merges clinical and demographic metadata directly into the AnalyseNidra master sheet and polygraphy summary CSVs.
*   **Nihon Kohden Binary .LOG & .EVT Triggers:** Native parser for Nihon Kohden binary `.LOG` event files (REC START, electrical stimulation ON/OFF with sub-second timestamps) and `.EVT` trigger files.
*   **Enhanced Nihon Kohden Channel Mapping & Clock Time:** Accurate `.21E` channel name resolution for higher channel codes (e.g. M2, O1, O2, LEOG, REOG, EMG1–3, ECG), automatic migration for previously saved montage settings, and true recording start time extraction for accurate clock time display on `.EEG` files.

---

## [1.23.0]
*   **Batch tab redesigned around the order you work in.** One shared list of **Recordings**, found with their scorings automatically, is used by four sections: **1 Autoscore**, **2 EEG analysis**, **3 Polygraphy (OSA & PLM)** and **4 Scoring comparison**.
    *   **Autoscore** is a step of its own because every other analysis needs a scoring. It never replaces an existing (e.g. manual) scoring: each autoscore is saved as its own file and linked to the recording. The other sections can also *autoscore first*, then continue automatically.
    *   **EEG analysis** is a linked pipeline of collapsible steps: **Preprocess** (stimulation-artefact removal on the continuous signal, then 30-s epoch cleaning) → **Extract features** (AnalyseNidra analyses and CAP on the cleaned EEG, mapped to sleep stages) → **Compile** (master sheet). Each step passes its output on to the next. You can run all ticked steps in one go or run one step on its own. A run window shows a recording × step status table, and *Resume* reuses outputs that already exist.
    *   **Scoring comparison** can pair each recording's scoring with its autoscore.
*   **Master-sheet compilation fixed.** Regional CSVs left with only a header (from an interrupted or crashed run) are now detected: *Resume* rebuilds them from the cached per-analysis results instead of skipping them. Empty CSVs are also left out of the master sheet and listed. Cached results containing NaN values can now be read back, and results are written atomically. A recording without N2/N3 no longer aborts: its NREM-only analyses are skipped with a warning. The new *Compile all CSVs in a folder…* option builds a master sheet from a whole folder.
*   **NeuroLoopGain** now uses the average of all chosen references when more than one is given, which matches the rest of AnalyseNidra.

---

## [1.22.0]
*   **NeuroLoopGain** (Kemp et al., IEEE-BME 2000): a native port of the open-source NeuroLoopGain 2.x analyser, giving amplitude-independent slow-wave, sigma (and optionally alpha) feedback-loop gain per second. The output matches the reference program sample for sample: all 14 traces, 144 runs on the four sample PSG nights (6 channels × 3 bands × 2 smoother rates). It runs as part of AnalyseNidra (interactive and batch). The gain curves can be overlaid on the hypnogram (*Overlay: NeuroLoopGain*). Stage-wise, per-cycle and per-hour gain and the ACCS upper-quartile index are added to the regional CSV (`NLG_SW_*`, `NLG_Sigma_*`), and a NeuroLoopGain page is added to the PDF report. Polyman-compatible `_NeuroLoopGain.edf` files can also be written (`--nlg-edf-dir`).
*   **Choose which analyses to run** in AnalyseNidra (interactive dialog and batch panel): spectral & complexity features, spindles, slow waves & SO–spindle coupling, PAC, and NeuroLoopGain (`--analyses` / `--skip` on the command line).
*   **Compare multiple scorings** (Compare menu): compare every scoring of a recording (manual, autoscorers, saved files) against the reference you choose. Shows hypnogram strips with Cohen's kappa, agreement and macro-F1, confusion matrices, per-stage F1, and CSV / PNG export.

---

## [1.21.0]
*   **Sleep cycles & stage dynamics** (port of the NIMHANS ACCS `accs_sleep_StageAnalyser`): sleep cycles (NREM ≥15 min, REM periods merged across gaps ≤25 min, cycle end at long awakenings), stage arousals, short awakenings, stage transitions and cycle-wise NREM/REM composition. Non-redundant stage dynamics (`SleepCycle_number`, `Stage_transitions`, `Stage_arousals`, `ShortAwakenings`) and cycle-wise measures (`C1`..`C5`) are written to the AnalyseNidra CSV without confusing redundant duplicates or prefixes, and presented on a new *Sleep cycles & stage dynamics* page of the PDF report. Verified value-for-value against the MATLAB code (Octave) on the sample nights and 900 synthetic hypnograms.
*   **Autoscoring fixes**: SeqSleepNet and SleepTransformer (spectrogram scaling), TinySleepNet (epoch normalisation) and U-Sleep now use the same 50 Hz notch and 0.3–35 Hz band-pass as the original models. U-Sleep is marked experimental. **YASA + SleepGPT** is the default everywhere.
*   **Faster AnalyseNidra**: features are computed once and reused for the regional CSV, PAC/coupling is accumulated window by window (much lower memory use) and sample entropy uses a faster exact search — about 2× faster than 1.20 on full PSG nights.

---

## [1.20.0]
*   **Cyclic alternating pattern (CAP) analysis (Utilities menu and batch)** following Terzano et al. (2001): automatic A-phase detection (or your own A1/A2/A3 markers), A1/A2/A3 subtyping, CAP cycles and sequences, CAP rate overall, per NREM stage, per hour and per half of the night, A-phase indices and durations, B-phase duration, isolated A-phases, cycle variability, and coupling of A-phases with arousals, respiratory events and leg movements. A-phases and CAP sequences are drawn on the waveforms and hypnogram, and a CAP page is added to the PDF report.
*   **Show / Remove OSA, PLM & CAP Markers** (Utilities): switch each group of analysis markers on or off; saved results (including batch results) can be shown again at any time.
*   **PSG batch analysis** (Batch tab): run Respiratory/OSA, PLM and CAP analysis over many recordings, with auto-loaded scorings and optional channel overrides; writes per-recording results and one summary CSV.
*   **Slow oscillation–spindle coupling**: mean vector length (MVL), phase-locking value (PLV) and phase consistency are added alongside PAC MI, gcPAC and ndPAC in AnalyseNidra outputs and the PDF report.

---

## [1.19.0]
*   **Respiratory / OSA analysis (Utilities menu)** following the AASM Scoring Manual v3: apneas (obstructive / central / mixed), hypopneas with the 1A (3 % or arousal) or 1B (4 %) rule, RERAs, alternative-sensor fallback when the flow sensor fails, ODI, T90/T88, hypoxic burden, pulse-rate response, ventilatory burden, REM-related and positional OSA and Cheyne-Stokes breathing. Events are shown as markers on the waveforms and hypnogram, and a Respiratory page is added to the PDF report.
*   **Periodic limb movement (PLMS) analysis** using AASM v3 rules (WASM 2016 available): LM, PLMS/PLMW, PLMS-arousal and respiratory-related LM indices, periodicity index, inter-movement-interval histogram, with markers and a PLM page in the PDF report.
*   **All autoscoring algorithms now run in the native engine** (TinySleepNet, YASA, U-Sleep, Luna POPS, GSSC, SeqSleepNet, SleepTransformer, Dreamento, SleepEEGpy), with multi-montage consensus and automatic EOG/EMG. Outputs are saved as `<recording>_<algorithm>_scoring.json`, so your manual scoring file is never overwritten.
*   **Simpler batch file selection**: *Add Single Files…* and *Add from Folder…* in both batch panels, with *Include subfolders*, *Use wildcard pattern* and (AnalyseNidra) *Auto-load scorings* options. Every channel field can be filled from the channel list of the first recording.
*   **Windows performance**: buffered EDF reading, coalesced hypnogram/spectrogram navigation, and a per-user install location under `%LOCALAPPDATA%\Programs` instead of the roaming profile.

---

## [1.7.0]
*   **Universal Markers & Annotations Support**:
    *   Direct decoding of embedded **EDF+ TAL** (Time-stamped Annotation Lists).
    *   Native parsing of **Brain Products / BrainVision (`.vmrk`)** marker files.
    *   Parsing of **Nihon Kohden (`.LOG` / `.log`)** clinical event notes and timestamps.
    *   Support for **Compumedics Profusion / Alice XML (`.xml`)** scored event lists.
    *   Header-adaptive parsing of tabular **CSV / TSV / TXT** marker files (`${stem}_events.csv`).
    *   Crisp canvas rendering distinguishing point markers (vertical lines + top pill badge) and interval spans (shaded boxes + top pill badge).
    *   Interactive **Markers & Annotations Manager Dialog (`M`)** with category filter chips, search, click-to-jump navigation, and CSV export.
*   **Time-Synchronized Video Playback (`V`)**:
    *   Cross-platform video playback supporting MP4, MKV, AVI, MOV, and WebM on macOS and Windows.
    *   Automatic detection of companion video files in the recording directory.
    *   Bidirectional synchronization: epoch jumping immediately seeks the video, and playing video advances the EEG viewport.
    *   Floating control overlay with fine-grained sync offset adjustments (`-1s`, `-0.1s`, `+0.1s`, `+1s`, manual entry, and reset).
*   **Brain Products (`.vhdr` / `.vmrk`) Integration**:
    *   Native loading and channel scaling for Brain Products recordings in both interactive viewer and batch modes.
*   **Enhanced Navigation & Confidence Display**:
    *   Hypnogram overlay dropdown directly on the toolbar (SWA, P(Wake), P(N1), P(N2), P(N3), P(REM), Off).
    *   Context-aware "out-of" navigation readout (`/ 765`, `/ 06:22:30`, `/ 05:22:30`) matching Epoch, Elapsed, and Clock jump modes.
    *   Multi-stage probability display on the status bar showing confidence scores across all competing stages.

---

## [1.6.0]
*   **Nihon Kohden (.EEG) Support**: Native reading of multi-block Nihon Kohden recordings, active channel filtering (<70 channels), and complete extraction of multi-hour (>6h to 36h+) continuous PSG payload data.
*   **EMBLA (.ebm) Folder & File Loading**: Automatic multi-rate channel resampling (e.g. 10 Hz respiratory channels upsampled to match 200 Hz EEG) preserving full 7+ hour recording duration across 35+ channels.
*   **REMlogic & EMBLA Stage Scoring**: Direct native parsing of `.esedb` (OLE event store) and `.esrc` scoring files into 30-second epoch hypnograms and event annotations.
*   **Nihon Kohden (.EEG) Version 1 & Version 2 (`EEG-1200A`) Dual Parser**: Added native Rust parsing for both standard Version 1 and Version 2 (`EEG-1200A` 3-tier extended block pointer chain) Nihon Kohden recordings. Corrected frame byte stride ($N+1$ channels), data start offsets, and physical voltage scaling ($0.09765625\ \mu\text{V}$), achieving **0.000000 µV exact match** against reference EDF files across 41+ channels and multi-hour datasets (up to 33M+ samples / 9.31+ hours).
*   **EMBLA (.ebm) Signal Scaling & Calibration**: Fixed EMBLA physical microvolt scaling factors (`1000.0 / 65536.0` µV/count and Volts-to-microvolts conversion) and multi-channel directory loading.
*   **FFI Symbol Lookup Resilience**: Isolated native FFI function bindings in Dart `EegBackend` so `.EEG`, `.ebm`, and `.edf` loaders operate independently without failing if any single symbol fails to bind.

---

## [1.3.0]
*   **Branding & Name Consistency**: Application name unified as **CCS Sleep Studio** across code, UI labels, documentation, and Debian/RPM packaging scripts.
*   **Batch Scoring Comparison**: Added interactive 2-column paired comparison table in Batch tab with **Auto-Pairing 2 Folders** support. Computes epoch-by-epoch agreement, Cohen's $\kappa$, stage-by-stage precision/recall/F1 scores, and exports `Batch_Scoring_Comparison_Master.csv`.
*   **AnalyseNidra Non-Sleep Stage Parsing**: Updated Rust backend `analyseNidra/src/hypnogram.rs` to seamlessly parse non-sleep stages (`Inconclusive`, `None`, `Unscored`, `Unknown`, `?`, `Uncertain`, `Uncertainty`, `NOT SCORED`, `N/A`) without raising errors or crashing.
*   **Keyboard Shortcuts**: Added `N`, `0`, `Numpad 0`, `Delete` for **None / Unscored (`?`)** stage and `U` / `Q` for **Uncertainty** toggle during manual scoring.
*   **Auto Spectrogram Power Scaling**: Implemented automatic 2nd–98th percentile log10 power colorbar scaling on load while retaining editable min/max values in config dialog.
*   **EDF Utilities Module**: Added interactive single-file and batch utility dialog for signal downsampling, time cropping, channel renaming, channel filtering, and patient header anonymization (Patient ID, Name, Sex, DOB).
*   **Nihon Kohden (.EEG) Native Rust Loader & EDF Converter**: Implemented binary parser in Rust (`bridge/src/nk.rs`) porting Brainstorm's `in_fopen_nk.m`, `in_fread_nk.m`, and `in_channel_nk.m`. Supports reading `.EEG`, `.PNT` metadata, and `.21E` electrode mapping files with EDF conversion export.

---

## [1.2.12]
*   Initial release of **AnalyseNidra** regional spectral analysis, EEG spectrogram heatmaps, and MT-Spindle / MT-KCD detection pipelines.
