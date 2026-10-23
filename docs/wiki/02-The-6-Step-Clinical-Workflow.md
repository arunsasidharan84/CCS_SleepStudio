# 2. The 6-Step Clinical Workflow

CCS Sleep Studio includes an interactive **Workflow Bar** positioned directly above the waveform viewer. Designed specifically for clinical environments, this bar acts as an intelligent checklist that tracks your progress through every stage of a sleep study.

```
+-------------------------------------------------------------------------------------------------------+
| WORKFLOW: (1) Open File > (2) AASM Montage > (3) Autoscore > (4) Review > (5) Run Analyses > (6) Report |
+-------------------------------------------------------------------------------------------------------+
```

---

## 🟦 Step 1: Open File

Click **[1. Open File]** on the bar, or press <kbd>Ctrl</kbd>+<kbd>O</kbd> (<kbd>Cmd</kbd>+<kbd>O</kbd> on macOS).

### Supported Formats
- **EDF / EDF+ (`.edf`)**: Standard European Data Format used across all major sleep labs.
- **BrainVision (`.vhdr`, `.vmrk`, `.eeg`)**: High-density clinical and research recordings.
- **Nihon Kohden (`.EEG`, `.LOG`, `.21E`)**: Japanese clinical polysomnography systems.
- **EMBLA (`.ebm`, `.esrc`)**: RemLogic polysomnography systems.
- **Orbit (`.orb`)**: Orbit clinical sleep monitors.
- **R09 (`.r09`)**: Raw neurophysiology telemetry records.

> 💡 **Tip:** If companion video exists (`.m2t`, `.mp4`, `.avi`), CCS Sleep Studio automatically synchronizes video playback with waveform scrolling!

---

## 🟩 Step 2: AASM Montage Setup

Click **[2. AASM Montage]** on the workflow bar.

Sleep EEG recordings often store raw monopolar signals referenced to a common amplifier ground. Clinical scoring according to American Academy of Sleep Medicine (AASM) standards requires differential derivations:

| Modality | Standard Derivations | Purpose |
| :--- | :--- | :--- |
| **Frontal EEG** | $F_4\text{-}M_1$, $F_3\text{-}M_2$ | High-amplitude slow waves (delta activity, N3 sleep) |
| **Central EEG** | $C_4\text{-}M_1$, $C_3\text{-}M_2$ | Sleep spindles (11–16 Hz), vertex sharp waves |
| **Occipital EEG** | $O_2\text{-}M_1$, $O_1\text{-}M_2$ | Posterior dominant alpha rhythm (8–12 Hz, Wake) |
| **EOG (Eyes)** | $E_1\text{-}M_2$, $E_2\text{-}M_2$ (or $M_1$) | Saccades, slow rolling eye movements, REM bursts |
| **EMG (Chin)** | $\text{Chin}_1\text{-}\text{Chin}_2$ | Muscle atonia identification for REM sleep |
| **Respiratory** | Flow, Thorax, Abdomen, $\text{SpO}_2$ | Apneas, hypopneas, desaturations |
| **Cardiac** | ECG | Heart rate variability, arrhythmias |

### Applying the Preset
1. In the Montage Dialog, click the **Presets** dropdown.
2. Select **AASM Sleep Standard** (or **AASM Sleep + OSA** / **AASM Sleep + PLM**).
3. The software automatically maps the correct channels from your file.
4. Click **Apply Montage**. Extraneous raw channels are automatically hidden from the screen to provide a clean, uncluttered display!

---

## 🟨 Step 3: Autoscore (AI Sleep Staging)

Click **[3. Autoscore]** on the workflow bar.

CCS Sleep Studio includes native deep learning and machine learning models that can score an entire 8-hour night in **under 5 seconds**:

```
+-------------------------------------------------------------+
|               AutoscoreNidra Setup                          |
+-------------------------------------------------------------+
|  Model: [YASA / USleep / SleepTransformer / Consensus]     |
|  EEG Channel:  [C4-M1        v]                             |
|  EOG Channel:  [E1-M2        v]                             |
|  EMG Channel:  [Chin1-Chin2  v]                             |
|                                                             |
|  [x] Apply SleepGPT post-processing consistency rules       |
|                                                             |
|          [ Cancel ]            [ Start Autoscoring ]        |
+-------------------------------------------------------------+
```

1. Select your preferred model (e.g. **Consensus Multi-Model** for maximum diagnostic accuracy).
2. Confirm the selected EEG, EOG, and EMG channels.
3. Click **Start Autoscoring**.
4. A progress indicator will show inference running. When finished, the hypnogram bar is instantly populated across all epochs!

---

## 🟧 Step 4: Manual Review & Staging

Click **[4. Review]** on the workflow bar.

Technicians and physicians review epochs and adjust any borderline boundaries:
- Press <kbd>Spacebar</kbd> to move forward 30 seconds.
- Press <kbd>Shift</kbd>+<kbd>Space</kbd> to move backward.
- Press <kbd>0</kbd> (Wake), <kbd>1</kbd> (N1), <kbd>2</kbd> (N2), <kbd>3</kbd> (N3), or <kbd>5</kbd> (REM) to re-score the current epoch instantly.
- The epoch watermark ribbon and bottom status bar update in real-time.

---

## 🟪 Step 5: Run Analyses (All-in-One Pipeline)

Click **[5. Run Analyses]** on the workflow bar.

This opens the **Comprehensive Multi-Modal Analysis Dialog**:

```
[✓] Spectral Powers & Aperiodic 1/f Landscape (FOOOF / IRASA)
[✓] Sleep Spindles & Slow Wave Coupled Events (SO-Sigma PAC)
[✓] Rapid Eye Movement (REM) Conjugate Saccade Dynamics
[✓] Polygraphy: Respiratory & OSA (AHI, ODI, Hypoxic Burden)
[✓] Polygraphy: Periodic Limb Movements (PLMS Index)
[✓] Automated AASM Cardiac & Arrhythmia Analysis
[✓] Cyclic Alternating Pattern (CAP) NREM Instability
```

Click **Run All Selected Analyses**. The native Rust engine processes all signals in parallel, generating detailed `.ccs*` sidecars and master summaries.

---

## 🟥 Step 6: Generate Publication Report

Click **[6. Generate Report]** on the workflow bar, or press <kbd>Ctrl</kbd>+<kbd>P</kbd>.

```
+-------------------------------------------------------------+
|             Generate Clinical Sleep Report                  |
+-------------------------------------------------------------+
|  Subject ID:       [SUB-0824                     ]          |
|  Study Site:       [Sleep Disorders Clinic, NIMHANS]        |
|  Physician:        [Dr. Consultant Neurologist   ]          |
|  Clinical Summary: [54M with excessive daytime somnolence...] |
|                                                             |
|  Included Pages:                                            |
|  [✓] Page 1: Macroarchitecture, Hypnogram & Sleep Continuity|
|  [✓] Page 2: Microstructure, Spindles, Slow Waves & PAC     |
|  [✓] Page 3: Spectral Trajectories & 2D Scalp Topoplots     |
|  [✓] Page 4: Cortical Complexity & Nonlinear Dynamics       |
|  [✓] Page 5: Clinical Interpretation & Diagnostic Overview  |
|                                                             |
|          [ Cancel ]            [ Export & Open PDF ]        |
+-------------------------------------------------------------+
```

Click **Export & Open PDF**. A multi-page, publication-quality report is generated instantly and opened in your system's default PDF viewer.
