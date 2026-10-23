# 6. Advanced Quantitative Analysis & Publication Reports

Beyond visual sleep scoring, CCS Sleep Studio includes a native **AnalyseNidra** quantitative neurophysiology pipeline capable of producing five-page clinical and research sleep reports.

---

## 🔬 Quantitative Sleep EEG Modules

```
+-----------------------------------------------------------------------------------+
| Module                  | Clinical & Research Insights                            |
+-----------------------------------------------------------------------------------+
| Spectral Power (PSD)    | Relative and absolute power in Delta (1–4Hz), Theta    |
|                         | (4–8Hz), Alpha (8–12Hz), Sigma (11–16Hz), Beta (12–30Hz)|
|                         | and Gamma (30–45Hz) across Wake, N1, N2, N3, REM.       |
| Aperiodic (1/f) Slope   | FOOOF and IRASA parameterization separating true        |
|                         | oscillations from broadband background neural tilt.     |
| Sleep Spindles          | Automated detection: density (spindles/min), frequency  |
|                         | (Hz), amplitude (µV), duration (s), and symmetry.       |
| Slow Waves & Coupling   | Slow oscillation density, amplitude, slope, and phase-  |
|                         | amplitude coupling (SO-Sigma PAC Modulation Index).     |
| NeuroLoopGain (NLG)     | Cortical closed-loop feedback stability index.          |
| Polygraphy: OSA         | Apnea-Hypopnea Index (AHI), Oxygen Desaturation Index   |
|                         | (ODI 3%/4%), Mean & Min SpO2, and Hypoxic Burden.       |
| Polygraphy: PLMS        | Periodic Limb Movement Index (PLMI), total movements,   |
|                         | periodicity index, and movement-related arousals.       |
+-----------------------------------------------------------------------------------+
```

---

## 📄 The 5-Page Publication Sleep Report

The PDF report generator (<kbd>Ctrl+P</kbd> / <kbd>Cmd+P</kbd>) produces publication-ready multi-page documents:

### Page 1: Sleep Macroarchitecture & Hypnogram
- **Clinical Overview**: Patient Demographics, Study Site, Referring Physician, and Diagnostic Impression.
- **Full-Night Hypnogram**: High-resolution stage color bars with sleep staging timeline.
- **Sleep Continuity Metrics**:
  - Total Recording Time (TRT), Total Sleep Time (TST), Sleep Efficiency (SE %)
  - Sleep Onset Latency (SOL), REM Latency, Wake After Sleep Onset (WASO)
  - Time and percentage spent in Wake, N1, N2, N3, and REM.

### Page 2: Thalamocortical Microstructure & Coupling
- **Sleep Spindle Morphometry**: Peak frequency, duration, density, and spindle count.
- **Slow Wave Dynamics**: Negative peak voltage, duration, and slow oscillation count.
- **SO-Sigma Phase-Amplitude Coupling (PAC)**: Preferred phase of slow oscillation for spindle maximal amplitude, and PAC Modulation Index ($MI$).

### Page 3: Neural Excitability, Spectral Landscape & Scalp Topography
- **Side-by-Side Multi-Line Trajectory Charts**:
  - **Chart 1: Aperiodic Slope & Exponent**: FOOOF exponent and IRASA slope across Wake, N1, N2, N3, and REM.
  - **Chart 2: Broadband Offset & Intercept**: Baseline spectral power elevation across sleep stages.
  - **Chart 3: Canonical Relative Band Power Trajectory**: Trajectories for **Delta**, **Theta**, **Alpha**, **Sigma**, **Beta**, and **Gamma** across Wake, N1, N2, N3, and REM.
- **Frequency-Band Relative PSD Table**: Complete matrix of relative band powers across all 5 stages.
- **2D Scalp Topoplots**: When $\ge 5$ scalp electrodes are available, renders realistic head outlines, ears, nose, 10–20 electrode coordinates, spatial gradient interpolation, and microvolt colorbars (e.g. $N_3$ IRASA Slope, $N_3$ FOOOF Offset, $N_2$ Sigma PSD).

### Page 4: Cortical Complexity & Nonlinear Dynamics
- Permutation entropy, SVD entropy, Sample entropy, and Autocorrelation Window (ACW-50) across sleep stages.

### Page 5: Diagnostic Interpretation & Polygraphy Summary
- Comprehensive polygraphy metrics: AHI, ODI, PLMS index, Cardiac events summary (Asystoles, Tachy/Bradycardia episodes, PVC counts, AFib episodes).

---

## ⚡ Batch Processing

Need to analyze 50 or 500 sleep recordings overnight?

1. Select **Batch ➔ Batch PSG Pipeline…** from the top menu.
2. Select your input folder containing `.edf` files.
3. Select your output folder.
4. Check the desired pipeline steps:
   `[✓] Autoscore` $\to$ `[✓] EEG Features` $\to$ `[✓] Respiratory` $\to$ `[✓] PLM` $\to$ `[✓] Compile Master Sheet`
5. Click **Start Batch Queue**.
6. The multi-threaded native backend processes records in parallel and compiles an all-inclusive master spreadsheet (`master_sheet.csv`) ready for statistical software (R, SPSS, Python, JASP)!
