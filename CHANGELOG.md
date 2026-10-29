# Changelog — CCS Sleep Studio

All notable changes to **CCS Sleep Studio** are documented in this file.

---

## [1.50.2]
*   **Prevent Batch Metadata Key Column Collisions & Low-Cardinality Collapsing:**
    - **High-Cardinality Heuristic in `guessKeyColumn`**: Evaluates distinct value uniqueness ratio across metadata rows, automatically penalizing categorical columns (`groupID`, `ageID`, `Gender`, `Status`, `Slept_well`) from being selected as primary matching keys.
    - **Distinct Subject Match Scoring**: Evaluates candidate columns against cohort recordings by the number of *distinct metadata rows matched*, ensuring unique identifier columns (`napID`, `Subject_Code`, `subject_id`) decisively win over categorical grouping columns that collapse an entire cohort onto 1 or 2 rows.
    - **Delimiter-Bounded Token Matching in `matchRecording`**: Prioritizes delimiter-bounded token matches (e.g. `Nap-122` bounded by `_` or `-` in recording filenames) with higher scoring, preventing short categorical strings (like `CNT` or `MCI`) from capturing unrelated files via greedy substring containment.
    - **Numeric Substring Safeguard**: Restricts purely numeric keys (e.g. `Sl.No.`) from greedy substring matching to avoid accidental collisions with dates, timestamps, or hardware indices.


## [1.50.1]
*   **Restored Multi-Channel Selection for CAP EEG Analysis:**
    - Restored multi-channel selection support (`singleSelect: false`) for the CAP EEG channel picker across both the PSG polygraphy workflow and the batch feature extraction cards.
    - Allows providing multiple comma-separated priority candidate channels (e.g. `C4, C3, CZ`) for automatic fallback across cohort recordings.
*   **10-20 to 10-10 Channel Nomenclature Harmonization:**
    - Interactive Channel Picker:
      - Channel chips with legacy 10-20 names display modern 10-10 badges (`EEG T3 [T7]`, `EEG T4 [T8]`, `EEG T5 [P7]`, `EEG T6 [P8]`).
      - Bidirectional alias search: searching `T7` matches `EEG T3`, searching `P7` matches `EEG T5`, searching `T8` matches `EEG T4`, searching `P8` matches `EEG T6`.
      - Added `[✔] Standardize to 10-10 names (T3→T7, T4→T8, T5→P7, T6→P8, clean prefix)` toggle to output clean prefix-free standard names.
    - Master Sheet Compiler:
      - `compileRegionalCsvFiles` automatically standardizes the `Chan` column across all input CSVs, mapping legacy `T3/T4/T5/T6` to modern `T7/T8/P7/P8` and stripping `EEG `/`POL ` prefixes.
      - Cohorts containing both old and new montage conventions merge seamlessly into unified rows without splitting.
    - AnalyseNidra Engine:
      - Per-channel extraction mode automatically canonicalizes channel keys to uppercase 10-10 names (`T7, T8, P7, P8`, `C3, C4...`), eliminating hardware prefixes and honoring custom region maps when specified.

## [1.50.0]
*   **In-App Rich Markdown & Scientific Math Release Notes Viewer:**
    - Integrated native markdown parsing via `ReleaseNotesMarkdownView` in the application update dialog.
    - Clean hierarchy formatting for `#`, `##`, `###`, `####` headers, multi-level bulleted lists, and numbered items.
    - Full inline formatting support for **bold**, *italic*, and highlighted `code` badges.
    - Automated LaTeX math formula translation into clean Unicode scientific symbols ($\ge$, $\le$, $\mu$, $\pm$, $\times$, $\approx$, $\rightarrow$, $\Delta$, `\text{...}` $\to$ $≥$, $≤$, $μ$, $±$, $×$, $≈$, $→$, $Δ$, $\text{ms}$, $\text{bpm}$, $\mu\text{V}$).
    - Expanded update dialog width to 640px and release notes viewport height to 240px with a persistent scrollbar thumb.
*   **Comprehensive Visual User Guide & Tutorial Wiki:**
    - Authored an 8-chapter comprehensive visual tutorial designed for non-technical clinicians, researchers, and sleep technicians.
    - Covers installation (macOS Gatekeeper bypass, Windows installer, Linux), the 6-step workflow bar, waveform tools (time grid, measurement caliper, single-point markers, channel solo, font scaling), manual scoring (AASM rules W/N1/N2/N3/REM, discrete tagging, typable shortcuts `T` and `Shift+M`), automated cardiac/arrhythmia analysis, advanced metrics, and troubleshooting.
    - Published directly in `docs/wiki/` and synced with `wiki/` for GitHub Wiki readiness.
    - Added quick-start tutorial references to `README.md`.

## [1.49.0]
*   **Automated AASM Cardiac and Arrhythmia Event Analysis:**
    - Integrated automated clinical ECG analysis following AASM Scoring Manual (Section VIII: Cardiac Rules).
    - Pan-Tompkins QRS energy detector with adaptive thresholding, refractory lockout, and sub-sample R-peak snapping.
    - Automated detection and scoring for:
      - **Asystole**: cardiac pause (R-R interval) $\ge 3.0\text{ s}$ in adults.
      - **Sinus Bradycardia**: sustained heart rate $< 40\text{ bpm}$ ($\ge 30\text{ s}$).
      - **Sinus Tachycardia**: sustained heart rate $> 90\text{ bpm}$ ($\ge 30\text{ s}$).
      - **Premature Ventricular Contractions (PVC / VPB)**: premature wide QRS with compensatory pause.
      - **Premature Atrial Contractions (PAC / APB)**: premature narrow QRS without full compensatory pause.
      - **Ventricular Couplets & Non-Sustained Ventricular Tachycardia (NSVT)**: 2 or $\ge 3$ consecutive PVCs at rate $> 100\text{ bpm}$.
      - **Supraventricular Tachycardia (SVT)**: run of $\ge 3$ consecutive PACs at rate $> 100\text{ bpm}$.
      - **Ventricular Bigeminy & Trigeminy**: alternating normal and ectopic beat patterns.
      - **Atrial Fibrillation (AFib)**: sustained irregularly irregular ventricular rhythm ($CV_{RR} \ge 0.19$, $nRMSSD \ge 0.16$).
    - Interactive parameter dialog with ECG channel selector, configurable thresholds, sleep stage heart rate breakdown (Wake, N1, N2, N3, REM), and one-click event commit.
*   **Zoomed Waveform Inspection with Interactive Measurement Caliper:**
    - High-precision time and voltage grid ticks (0.1s / 0.5s intervals and microvolt steps) inside the zoomed signal window.
    - Interactive drag-to-measure caliper: click and drag across the zoomed waveform trace to measure $\Delta t$ (ms), instantaneous frequency ($f = 1/\Delta t$), $\Delta V$, range, and slice mean.
*   **Relative Spectral Multi-Line Trajectory Charts & 2D Scalp Topoplots in PDF Reports:**
    - Integrated multi-line trajectories for canonical frequency bands (Delta, Theta, Alpha, Sigma, Beta, Gamma) across all sleep stages (Wake, N1, N2, N3, REM).
    - Side-by-side compact 3-chart layout: Aperiodic Exponent/Slope, Broadband Offset/Intercept, and Relative Spectral Trajectories.
    - Resolved missing Wake state, Beta, and Gamma power values through unified alias resolution (`W_`, `Wake_`, `R_`, `REM_`, `Beta1`/`Beta2`, `Gamma1`/`Gamma2`).
    - Automated 2D scalp topoplot generator for high-density recordings ($\ge 5$ scalp electrodes): head outline, ears, nose, 10–20 electrode coordinates, spatial gradient interpolation, and microvolt colorbar.
*   **Timeline Single-Point Markers & Typable Custom Shortcuts:**
    - Single-click point markers now render cleanly as dedicated pinpoint indicators without compressed selection boxes or text crowding.
    - Top selection header displays both **Mean** and **Range** (Peak-to-Peak: $\Delta V = V_{\max} - V_{\min}$) in $\mu\text{V}$.
    - Added keyboard shortcuts `T` and `Shift+M` to open instant custom typed marker prompts.
    - Added right-click selection context menu options to add custom markers directly to active regions.
*   **Configurable Epoch Time Grid & Sleep Stage Watermark:**
    - Configurable time grid across epochs (1s dashed / 5s solid lines with subtle timestamps), toggled via toolbar button, View menu, or `G` shortcut.
    - Subtle sleep stage background tint and watermark badge across the epoch canvas.
*   **Channel Solo / Montage Subselection Mode:**
    - Double-click any channel scale tile to isolate/solo that channel for focused inspection; double-click again or press `Esc` to restore full montage.
*   **Waveform Hover & Scroll Performance Optimization:**
    - Decoupled cursor hover coordinate tracking from full-screen `setState()` re-renders using Flutter `ValueNotifier` hooks.
    - Eliminates CPU spikes during mouse moves and dynamically recalculates hover amplitudes across epoch scrolling.
*   **Clinical Smart Decision Aid Tooltips:**
    - Selection windows provide real-time pattern suggestions based on signal properties: Sleep Spindles, Slow Wave / Delta, K-Complexes, Alpha Rhythm, Apnea / Hypopnea, Desaturations, PLM, and Phasic REM.
*   **AASM Montage EOG Mastoid Derivation Standardization:**
    - Aligned EOG derivation presets to common reference standards (`LOC1-A2`, `ROC1-A2` / `E1-M2`, `E2-M2`), preventing contralateral reference mixing.
*   **Dynamic Display Font Scaling:**
    - Adjustable font multiplier across markers, labels, values, and tooltips via View menu and `Ctrl+Alt+=`, `Ctrl+Alt+-`, `Ctrl+Alt+0`.

## [1.46.0]
*   **AASM Montage Default Selection in Automated Sleep Scoring:**
    - Auto sleep scoring setup dialogs (`AutoScoringDialog` and `BatchAutoScoringDialog`) now prioritize applied/visible AASM derivations (`C4-M1`, `C4-A1`, `F4-M1`, `O2-M1`, `LOC-A2`, `ROC-A1`, `CHIN1-CHIN2`, etc.) by default instead of selecting all available raw channels.
    - If only unreferenced raw channels exist in the recording, auto-scoring selects standard AASM central/lateral channels (`C4, F4, O2`), references (`M1, M2` / `A1, A2`), EOG (`E1, E2` / `LOC, ROC`), and submental EMG (`CHIN1, CHIN2`), leaving extraneous channels unchecked.
    - Added contralateral ear-lobe reference (`A1`, `A2`) recognition and automatic on-the-fly derivation computation to the native `analyseNidra` backend scoring loader.
*   **ECG Artefact Removal (Cardiac QRS Subtraction):**
    - Implemented high-performance native Rust QRS-synchronous cardiac template subtraction (`analyseNidra/src/cleaning/ecg_artifact.rs`).
    - Employs Pan-Tompkins R-peak detection, refractory lockout, robust median template extraction, and adaptive beat scaling to cleanly subtract volume-conducted cardiac artifacts from sleep EEG derivations without attenuating sleep spindles or delta waves.
    - Added full GUI integration via **Utilities > Remove ECG Artefacts (Cardiac QRS Subtraction)…** and the EEG preprocessing dialog, as well as native CLI execution via `--remove-ecg`.
*   **Obstructive Sleep Apnea (OSA) Clinical Validation:**
    - Validated automated respiratory event scoring against manual polysomnography (`S2.edf`), demonstrating 92.7% event parity (253 sleep events vs 273 clinical annotations) and tight AHI concordance (Automated AHI 56.3/hr vs manual AHI 61.0/hr, Severe OSA).

## [1.44.1]
*   **AASM Montage EOG Channel Detection for LOC/ROC Variants:**
    - Expanded EOG electrode matching to recognize `LOC`, `LOC1`, `ROC`, `ROC1`, `ROC2`, `EOGLOC`, `EOGROC`, and prefixed variants (`EOG LOC1`, `EOG-ROC1`, `POL LOC`).
    - Resolves failure of AASM montage auto-detection on recordings with canthal electrode notation (such as `AS_CNT_08_Night1.edf`).
    - Preserves exact derivation names (e.g. `LOC1-A2`, `ROC1-A1`) instead of forcing generic labels.
*   **Resolution of Channel Label vs. File Track Ambiguity:**
    - Montage presets now preserve actual recording channel names (e.g. `PLMl`, `PLMr`) instead of arbitrarily renaming them to `LAT`/`RAT`.
    - In the montage manager, channels with differing display names now display an explicit `[file: <source>]` indicator.
    - On the timeline waveform channel strip, channels with derived or mapped names display a subtle `src: <source>` subtitle note and detailed file track hover tooltip.
*   **30s Epoch Split Dotted Lines for >30s Windows:**
    - In viewing windows $>30$s (e.g. 60s, 120s, 300s/5 min), crisp vertical dotted lines are drawn at every 30s epoch boundary across all channels.
*   **Overarching PLM / PLMS / PLMW Series Extent Markers:**
    - PLM analysis now renders full extent markers encompassing all $\ge 4$ constituent leg movements of each periodic series, labeled with movement count and sleep/wake state (`PLMS Series (X LMs)` vs `PLMW Series (X LMs)`).
    - Constituent movements display individual `PLMS (LM)` / `PLMW (LM)` badges with non-overlapping vertical row stacking.
*   **Total Downloads Metric Badge:**
    - Fixed the downloads badge in README to track total downloads across all releases (`https://img.shields.io/github/downloads/.../total`), avoiding the drop to 0 on new version releases.

## [1.42.0]
*   **Safe Error Dismissal & Config Dialog Fix:**
    - Resolved `Invalid argument(s): 0` index clamping crash in `ConfigDialog` when opening settings with no file loaded.
    - Added a global, styled **Back / Dismiss View** button to `ErrorWidget.builder` allowing immediate recovery and dismissal from any unhandled view exception without restarting the app.
*   **Configurable Workflow & Quick Access:**
    - Added a direct configure icon (`tune`) on the workflow bar for instant access to workflow customization.
    - Workflow strip and individual workflow steps can be toggled and configured from settings.
*   **Standard AASM Marker Defaults:**
    - Pre-defined standard clinical AASM markers across all shortcut keys (0–12 / A, F1–F12): *Artifact*, *Arousal*, *Obstructive Apnea*, *Central Apnea*, *Hypopnea*, *Mixed Apnea*, *Desaturation*, *Leg Movement*, *PLM*, *RERA*, *Spindle*, *K-Complex*, and *REM*.
    - Fully editable with a **Reset Defaults** button in the marker configuration dialog.
*   **Mouse-Click Point Markers:**
    - Added single-click point marker placement on channels (`startSec == endSec`).
    - Rendered with an instant vertical pinpoint indicator, dot, and label in `SelectionOverlayPainter`.
    - Added comprehensive quick AASM marker items directly in the channel right-click context menu.
*   **Adaptive Low-Voltage REM Detection & LRLR Burst Grouping:**
    - Integrated adaptive baseline standard-deviation thresholding (`relativeThresholdSd: 2.0`) in `RemDetector` to reliably capture low-amplitude ocular saccades in adult sleep recordings.
    - Replaced rigid dot-product criteria with Pearson correlation ($r \le 0.2$), eliminating false rejections from slight DC offsets and in-phase blinks.
    - Implemented **LRLR Alternating Burst Detection** ($\ge 3$ consecutive Left-Right-Left-Right saccade cycles in $\le 2.2$ s) with dedicated `.ccsrem` reporting.
*   **Waveform Pattern Template Search (NCC):**
    - Built interactive sliding Normalized Cross-Correlation (NCC) pattern matcher (`frontend/lib/src/pattern_search.dart`).
    - Allows selecting any waveform snippet in a channel and scanning across the entire night or specific sleep stages (N1, N2, N3, REM, Wake).
    - Includes interactive preview canvas, similarity threshold slider ($50\% - 98\%$), optional inverted matching, match jump navigation, and 1-click **Mark All as Events**.
*   **AASM + PLM + OSA Montage Preset & Robust Channel Matching:**
    - Added `AASM Sleep + PLM + OSA (Comprehensive PSG)` preset to `MontagePresets`.
    - Expanded alias dictionary and alphanumeric normalization for pre-referenced PLM and respiratory channels (`PLMl`, `PLMr`, `Pressure Flow`, `RIP Thorax`, etc.).
*   **README Unique Downloads Badge:**
    - Updated download metrics badge to latest release unique downloads to prevent duplication across multiple version updates.

## [1.41.0]
*   **Configurable Clinical Workflow Bar in Settings:**
    - Added a dedicated **Workflow** configuration tab in the settings dialog (`ConfigDialog`).
    - Added global toggle `Show Guided Clinical Workflow Bar` to show/hide the top workflow strip.
    - Added individual step enable/disable checkboxes (`1. Open File`, `2. AASM Montage`, `3. Autoscore`, `4. Manual Review`, `5. Run Analyses`, `6. Generate Report`).
    - Workflow preferences are persisted to `.ccsconfig` and synchronized across sessions.
*   **Configurable Hypnogram Redundancy Modes for Reports:**
    - Added `Hypnogram on Subsequent Pages` dropdown in both the Report Configuration tab and the Clinical Sleep Report Generator dialog.
    - Supports `Compact Color Strip (strip)` (16–22 pt slim stage timeline strip on subsequent pages to avoid visual redundancy) and `Full Stepped Hypnogram (full)` (repeated full 88 pt hypnogram).
*   **Comprehensive Report Interpretation Cards (Page 8):**
    - Redesigned "Understanding Your Results" into 7 structured visual interpretation cards with category tags, badges, and clinical bullet points:
      - Sleep Macroarchitecture & Continuity
      - Respiration & Nocturnal Breathing (OSA)
      - Periodic Limb Movements in Sleep (PLM)
      - Rapid Eye Movements (REM) & Ocular Saccades
      - Sleep Stability & Microcontinuity (CAP & NeuroLoopGain)
      - Microstructure & Oscillatory Coupling
      - Important Limitations & Disclaimer
*   **Sleep Cycle Table Fallback Support:**
    - Updated `_buildSleepCyclePage` to support both `Cyc${c}_` and `C${c}_` coordinate keys from `analyseNidra`, fixing empty cycle tables and missing Odd/Even raster bars.
*   **Wake Stage Features in Information Theory & ACW:**
    - Added Stage 0 (`W`) to `analyseNidra` regional and feature extraction loops, populating wake values in LZc and Autocorrelation Window (ACW) plots.
*   **NeuroLoopGain Physiological Scaling:**
    - Corrected NeuroLoopGain unitless ratio scaling across both hypnogram overlay painters and report generator timelines.
*   **Robust 1000 Hz REM Detection Engine:**
    - Integrated Butterworth zero-phase bandpass filtering, 50 ms moving derivative, and 80 ms saccade gap tolerance to reliably detect REMs on high-frequency recordings.

## [1.40.0]
*   **Guided Clinical Workflow Bar:**
    - Integrated a top clinical workflow toolbar directly above the EEG viewport: `[1. Open File] ➔ [2. AASM Montage] ➔ [3. Autoscore] ➔ [4. Review] ➔ [5. Run Analyses] ➔ [6. Generate Report]`.
    - Features live stage completion badges, current recommended step highlighting, and direct 1-click execution.
*   **Unified Comprehensive Analysis Pipeline:**
    - Added an All-in-One dialog (`_runComprehensiveAnalysisDialog`) with individual and batch toggle checkboxes for:
      - AnalyseNidra Sleep EEG Pipeline (Spectral power, slow waves, spindles, PAC)
      - NeuroLoopGain (NLG) Cortical Feedback Dynamics
      - Rapid Eye Movement (REM) Ocular Saccade Dynamics
      - Cyclic Alternating Pattern (CAP) NREM Instability
      - Respiratory & Sleep Apnea (OSA, Hypopneas, ODI, AHI)
      - Periodic Limb Movements in Sleep (PLMS & PLMI)
    - Supports running all selected modules sequentially in a single automated click.
*   **Research-Grade Rapid Eye Movement (REM) Detection:**
    - Introduced conjugate out-of-phase EOG saccade detection module (`RemDetector`) analyzing bilateral ocular deflections (LOC/E1 and ROC/E2).
    - Computes deflection velocity, peak amplitude, duration, and REM density (events/min REM).
    - Saves standardized `<stem>.ccsrem` sidecar with legacy companion `<stem>_rem.json` and adds markers to the hypnogram and waveform.
*   **Intuitive AnalyseNidra Progress Dialog:**
    - Replaced the overwhelming raw terminal dump with an intuitive clinical interface:
      - Interactive Pipeline Step Tracker (`Channels` ➔ `Core Spectral` ➔ `PAC` ➔ `Slow Waves` ➔ `Spindles` ➔ `NeuroLoopGain` ➔ `Regional Output`).
      - High-level Active Status Card with percentage progress bar and recording indicators.
      - Collapsible Terminal Log Console (`[Show / Hide Terminal Log Console]`) for troubleshooting when desired.
*   **AASM Montage Clinical Ordering & Raw Channel Deduplication:**
    - Enforced strict clinical PSG channel sequencing: EOG (Rows 1–2) ➔ Frontal ➔ Central ➔ Occipital ➔ Chin EMG.
    - Added prefix (`EEG `, `POL `) and suffix (`-Ref`, `_Ref`) stripping during montage combination and canonical channel matching.
    - Fixed raw channel leakage: unconfigured raw channels are set to `displayOnScreen = false` when montage channels exist, preventing duplicated raw traces on screen.
*   **Extended Montages & Midline Fallbacks:**
    - Added extended presets: `AASM Sleep + OSA (Respiratory)` and `AASM Sleep + PLM (Limb Movements)`.
    - Implemented automatic midline electrode fallbacks (`Cz` when `C3/C4` missing, `Fz` for `F3/F4`, `Oz` for `O1/O2`) across both Rust and Dart backends.
    - Added per-channel vertical scale selectors (20 µV to 1000 µV) and filter dialogs directly in the montage manager.
*   **Legacy Sidecar Migration Tool & Startup Prompt:**
    - Automatically checks recording directories upon opening files and prompts the user to migrate legacy `.json` files (`.config.json`, `_scoring.json`, `_spindles.json`) to modern `.ccs*` extensions.
    - Added **Data / File ➔ Migrate Legacy Sidecars in Folder…** to batch-migrate any selected folder on disk with pre-scan preview.
    - Updated configuration file pickers to accept both `.ccsconfig` and `.json`.
*   **Marker Visibility & Group Management:**
    - Integrated "Show / Remove Groups" button directly inside the **Markers & Annotations Manager [M]** dialog and main toolbar.
    - Added full support for REM marker group visibility alongside Spindles, Slow Waves, Respiratory events, PLMs, and CAP.
*   **NeuroLoopGain Referencing & Low Value Resolution:**
    - Fixed reference alias matching bug where raw channels ending in `-Ref` were falsely flagged as pre-referenced, leaving them unreferenced and causing low gain output.
    - Added automatic mastoid reference fallback (`M1/M2` / `A1/A2`) and updated CLI to support `--channels` and `--eeg`.
*   **Clinical Sleep Report Generator:**
    - Added clinical report generator dialog with input fields for Patient ID, Clinical Notes / History / Physician Impression, Study Site, and Reporting Physician.

---

## [1.39.1]
*   **Windows CI Cross-Platform Path Normalization:**
    - Resolved path separator mismatch (`\` vs `/`) in `recording_storage_and_migration_test.dart` and `LegacyFileMigration.apply` across Windows runners.

---

## [1.39.0]
*   **AnalyseNidra Multi-Rate Channel Selection & Spindle / Slow-Wave Detection:**
    - Resolved sampling rate mismatch failures in native `analyse-nidra` spindle and slow-wave detection when reading EDFs with multi-rate auxiliary channels (e.g. `S4.edf` where EEG runs at 200 Hz, Snore at 500 Hz, SpO2 at 1 Hz).
    - Grouped channels by modal sampling rate in `read_available`, dynamically loading matching EEG channels while cleanly skipping non-matching auxiliary channels with diagnostic notices instead of aborting.
    - Upgraded channel selection fallback to utilize `read_eeg_channels` matching normalized roots (e.g. `F3` matches `EEG F3-A2`), and added bounds guards preventing empty channel index panics.
    - Spindle and Slow-Wave dialogs now filter channels to EEG and mastoids and auto-default reference to 'None' for pre-referenced channels.
*   **Top-Level Events Menu & Comprehensive Marker Management:**
    - Promoted "Show / Remove Markers & Polygraphy Events" to the top-level **Events** menu on macOS (`PlatformMenu`) and in-app menus for rapid discovery.
    - Expanded event management to include **Sleep Spindles**, **Slow Waves**, and **K-complexes** alongside Apneas, Hypopneas, Desaturations, EEG Arousals, PLMs, and CAP phases.
    - Added live event count indicators for each event category in the current recording, plus "Select All" and "Deselect All" quick action chips.
    - Added automated marker reload hooks restoring detections immediately without requiring file reload.
*   **Clinical AASM Montage Derivations & Pre-Referenced Waveform Preservation:**
    - Reordered `AASM Sleep Standard` montage preset to place EOG derivations at rows 1 & 2 at the top of the display, matching clinical PSG standards.
    - Introduced `findPreReferencedChannel` to automatically detect existing pre-referenced channels (e.g., `E1:M2`, `E2:M2`, `LOC-A2`, `ROC-A1`). Pre-referenced channels bind directly with `reReference: 'None'`, preventing artificial subtraction and eliminating sleep spindle contamination in EOG traces.
    - Enforced modality color standards: EOG is displayed in **Blue**, EMG in **Orange**, and ECG in **Magenta**.

---

## [1.38.2]
*   **Streamlined Output File Formats (`.ccs*`):**
    - Introduced dedicated, intuitive extensions replacing scattered and ambiguous `.json` sidecars across all subsystems:
      - Configuration: `<stem>.ccsconfig` (replaces `<stem>.config.json` / `<stem>_config.json`)
      - Sleep Staging: `<stem>.ccsscoring` and `<stem>_<model>.ccsscoring` (replaces `<stem>_scoring.json` / `<stem>_<model>_scoring.json`)
      - Spindle Detections: `<stem>.ccsspindles` (replaces `<stem>_analyse_spindles.json` / `<stem>_spindles.json`)
      - Slow-Wave Detections: `<stem>.ccsslowwaves` (replaces `<stem>_analyse_slow_waves.json` / `<stem>_slow_waves.json`)
      - Phase-Amplitude Coupling (PAC): `<stem>.ccspac` (replaces `<stem>_analyse_pac.json`)
      - Core Spectral Metrics: `<stem>.ccscore` (replaces `<stem>_analyse_core.json`)
      - NeuroLoopGain Dynamics: `<stem>.ccsnlg` (replaces `<stem>_analyse_nlg.json`)
      - Respiratory / OSA Reports: `<stem>.ccsrespiratory` (replaces `<stem>_respiratory.json`)
      - Periodic Limb Movements (PLM): `<stem>.ccsplm` (replaces `<stem>_plm.json`)
      - Cyclic Alternating Pattern (CAP): `<stem>.ccscap` (replaces `<stem>_cap.json`)
*   **Recording Storage Architecture (CCSEEG, FIF, EDF+):**
    - Added user-configurable recording storage formats (`RecordingStorage`), matching the architecture in CCS EEG Studio:
      - **CCSEEG**: Native portable floating-point JSON format (`ccseeg-v1`).
      - **FIF**: Floating-point continuous and epoched EEG storage.
      - **EDF+**: 16-bit signal storage paired with `.ccsmeta` metadata.
    - Added preferences persistence to `~/.config/ccs-sleep-studio/storage.ccssettings` (or `%APPDATA%/ccs-sleep-studio/storage.ccssettings` on Windows).
    - Added format selector dropdown in **Configuration Dialog -> Configuration tab**.
*   **EDF Exports with Companion Metadata (`recording.edf.ccsmeta`):**
    - All EDF export and transformation pipelines (`processEdfFile`, `_writeLoadedEegToEdf`) automatically write a companion `recording.edf.ccsmeta` file alongside the binary EDF.
    - Preserves epoch lengths, channel labels, scored event markers, hypnograms/stages, protocols, and transformation provenance together in one place.
*   **Backward Compatibility & One-Click Migration Tool (`LegacyFileMigration`):**
    - Fully backward compatible: All sidecar readers, loaders, and batch search routines check the new `.ccs*` extension first, seamlessly falling back to legacy `.json` naming.
    - Added **"Organise legacy filenames…"** tool in the Configuration dialog allowing users to scan any dataset directory and preview/rename legacy filenames safely with undo manifest generation (`legacy_names.ccsmigration`).

---

## [1.38.0]
*   **10-20 to 10-10 Channel Alias Matching:**
    - Added bidirectional matching in `find_header_index` for standard international 10-20 $\leftrightarrow$ 10-10 electrode nomenclature across EDF and BrainVision (`.vhdr`) loaders (`T3` $\leftrightarrow$ `T7`, `T4` $\leftrightarrow$ `T8`, `T5` $\leftrightarrow$ `P7`, `T6` $\leftrightarrow$ `P8`, `A1` $\leftrightarrow$ `M1`, `A2` $\leftrightarrow$ `M2`).
*   **Lenient Channel Loading (`read_available`):**
    - Switched Preprocessing (`run_preprocessing`) and Feature Extraction (`load_recording`) from strict channel verification (`read_selected`) to lenient channel loading (`read_available`).
    - Recordings missing individual electrodes (such as `T7`) now cleanly proceed through preprocessing and feature extraction on all available channels with clear warning logs instead of failing the file.
*   **Decoupled PSG Batch Pipeline Execution:**
    - In `batch_pipeline.dart`, removed indiscriminate blocking where a failure in Preprocessing blocked all subsequent stages.
    - Subsequent steps (Features, CAP, Respiratory / OSA, PLM) continue independently, with feature extraction falling back to raw recording when a cleaned version is not present.
*   **Guaranteed Sleep Macro-Architecture in Master Sheet:**
    - Master sheet compilation now guarantees inclusion of all scored recordings: if a recording has a hypnogram but lacks regional spectral features, `analyse-nidra` computes macro-architecture metrics via `--analyses none`.
    - All 38 sleep macro-architecture metrics (TST, WASO, SE, SOL, stage durations & percentages, transitions, bout dynamics) are preserved in `AnalyseNidra_master_sheet_<timestamp>.csv`.

---

## [1.37.6]
*   **Unified PSG Batch Analysis Pipeline with Toggleable Substeps:**
    - Merged previously separate "EEG Analysis Pipeline" and "Polygraphy: OSA & PLM" sub-tabs into a single unified **PSG Analysis** pipeline.
    - All stages are now toggleable substeps that can be freely combined in any sequence: `[✓ Autoscore] -> [✓ Preprocess] -> [✓ EEG Features] -> [✓ Respiratory / OSA] -> [✓ Limb / PLM] -> [✓ Compile]`.
    - Each substep features its own collapsible settings card, in-pipeline toggle switch, and a dedicated "Run this step only" action.
    - Automatic integration of companion polygraphy metrics (`_respiratory.json` and `_plm.json`) into `AnalyseNidra_master_sheet_<timestamp>.csv`, including AHI, ODI, hypoxic burden, SpO2 min, and PLMS indices.
    - Standalone compilation of `psg_batch_summary_<timestamp>.csv` when polygraphy is run without EEG feature extraction.
*   **Restructured Utilities Menu:**
    - Reorganized the 15-item flat menu into 6 intuitive categories across both macOS native menu bar (`PlatformMenu`) and in-app menus (`SubmenuButton`):
      1. Signal Preprocessing & Cleaning (Preprocessing Pipeline, Auto DBS Stim Removal, EEG Utilities)
      2. Micro-Events & Transient Detection (MT-Spindle, MT-KCD, AnalyseNidra Spindles & Slow-Waves, CAP Analysis)
      3. Polygraphy: Respiratory (OSA) & PLM (Respiratory / OSA Analysis, PLMS Analysis, Show / Remove Markers)
      4. Advanced Sleep EEG Pipeline (AnalyseNidra, Feature Selection & Parameters)
      5. Interactive Viewer Tools (Zoom on Selected EEG `[Z]`, Find Similar Epochs)
      6. Reporting & Export (Export Sleep Report PDF)
    - Enhanced with styled section headers, leading icons, and dividers.
*   **Zero-Python Migration (Pure Dart Statistical Engine):**
    - Removed all external Python runtime dependencies (`statsmodels`, `scipy`, `numpy`, `matplotlib`, `seaborn`) for Group Analysis.
    - Pure Dart implementation of Linear Mixed-Effects Models (LMM), General Linear Models (GLM) / ANOVA Type II, multiple comparison adjustments (FDR, Tukey HSD, Bonferroni), effect sizes (Cohen's d, partial $\eta^2$), and descriptive statistics.
    - Native Flutter `CustomPainter` rendering for interactive boxplots with jittered points, unclipped titles, robust y-scaling, explicit units, sample counts, and legends placed outside the plot canvas.
*   **Multi-Row Post-Hoc Scalp Topoplots:**
    - Scalp topographic maps now display multi-row pairwise difference contrasts for all cohort pairs (`OLD − MID`, `YNG − MID`, `YNG − OLD`) with empirical significance markers (`*` for $p < 0.05$).
*   **Cross-Platform Fixes:**
    - Resolved Windows and Linux file path resolution in batch statistical workflows.
    - Removed redundant Group Analysis action bar button.

---

## [1.30.1]
*   **Windows In-App Updater Resilience & Certificate Bypass:**
    - Resolved `CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate` during in-app updates on Windows by supporting SSL cert bypass for GitHub/AWS domains, chained HTTP redirects (up to 10 redirects), and built-in `curl.exe -L -k` / PowerShell `Invoke-WebRequest` fallback.
    - Added a prominent "Download via Browser" button in the update dialog so users can download releases directly via their default web browser if firewall or SSL proxies block native downloads.
*   **CAP Analysis Metrics in Individual Regional CSVs:**
    - Fixed missing CAP analysis metrics in individual regional CSVs (`*_analyse_regional.csv`). Companion `*_cap.json` metrics (`CAP_rate`, `CAP_A_index`, `CAP_A1_index`, etc.) are now automatically injected into individual regional CSVs upon completion as well as compiled master sheets.
    - Fallback automatically to the first Central or Frontal channel (`C3/C4/F3/F4`) when `--eeg` is blank for CAP analysis.
    - Added companion `_cap.json` auto-discovery and merging in `group_stats.py`.
*   **Re-organized Batch Analysis Workspace (Inspired by CCS_EEGStudio):**
    - Added a workspace top banner with queue status chips (`X recordings queued`, `Y scored`, `Z preprocessed`, `Master sheet ready`).
    - Added quick action controls: `[Master CSV]`, `[Output Folder]`, `[Group Statistics]`, and `[Run Full Pipeline]`.
    - Elevated and streamlined the workflow stages with clear stage switching and pipeline execution.
*   **Channel Montage & Referencing Manager Accessibility:**
    - Added a dedicated "Channel Montage & Referencing Manager" accessible with 1 click directly from the main toolbar (`Montage` button) and from the `Configuration` and `Data` menus without needing to navigate complex config settings.
    - Features standard clinical presets (AASM Sleep Standard, Longitudinal Bipolar / Double Banana, Transverse Bipolar, Contralateral Mastoids, Monopolar Reset), quick derivation builder with active/reference channel selection and polarity invert, and Save/Load custom montage presets (`.json`).

---

## [1.30.0]
*   **Macroarchitecture Channel-Invariance:** Whole-night sleep macroarchitecture metrics (sleep efficiency, total sleep time, WASO, sleep onset latency, stage percentages/latencies, etc.) are recognized as channel-invariant global metrics. Redundant channel subdivision is eliminated, preventing sample size inflation. Macroarchitecture metrics are automatically modeled at the subject/recording level using GLM/ANOVA and rendered as clean single-factor publication plots.
*   **2D EEG Scalp Topoplot Generator:** Automatically computes and renders 2D scalp topographic maps (topoplots) for channel-level metrics whenever at least 4 channels with sufficient spatial coverage are available (using standard 10-20 coordinates and smooth multiquadric RBF interpolation). Generates group mean topoplots and difference maps with annotated post-hoc significance markers (`*`), embedded directly into the in-app interactive viewer, Word (`.docx`), and PDF reports.
*   **Progress Indicators for Batch Operations:** Added live, animated progress bars and status text across batch workflows:
    - Group Statistical Analysis now tracks model computation and report generation progress in real-time (`0%–100%`) above execution logs.
    - Batch Scoring Comparison displays a dedicated progress dialog with a progress bar, current pair counter, and cancel control.
*   **Clear All in Batch Scoring Comparison:** Added a "Clear All" action button to the Batch Scoring Comparison top action bar alongside "Auto-Pair 2 Folders…" and "Add Pair", as well as consistent clear controls in list headers.
*   **Enhanced Nomenclature & Flexible Metadata Support:** Fully supports newer CSV nomenclature (`groupID`, `ageID`, `napID`, `Subject_Code`, `Cyc*`, `CAP_*`, datastamped files) and improved automatic classification of categorical factors vs continuous numeric variables.

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
