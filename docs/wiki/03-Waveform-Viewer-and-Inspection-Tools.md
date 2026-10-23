# 3. Waveform Viewer & Inspection Tools

The waveform viewing canvas is the core of CCS Sleep Studio. It is optimized for 60+ FPS fluid navigation, responsive dragging, and rich clinical visual aids.

---

## ⏱️ Configurable Time Grid Across Epochs

Standard 30-second sleep epochs can be difficult to measure visually without reference divisions.

- **Toggle Grid On / Off**: Press <kbd>G</kbd> on your keyboard, or click the **Grid** button on the main toolbar, or select **View ➔ Toggle Time Grid**.
- **Visual Design**:
  - **1-Second Sub-divisions**: Crisp dashed vertical lines divide each second.
  - **5-Second Divisions**: Solid vertical reference lines with timestamps (`0s`, `5s`, `10s`, `15s`, `20s`, `25s`, `30s`).
  - Helps clinicians immediately spot brief 0.5-second arousals, 1.0-second spindles, and 10-second respiratory pauses.

---

## 🔍 Single-Point Click Markers vs. Regional Selections

CCS Sleep Studio distinguishes between instantaneous pinpoint events and extended duration events:

### Single-Point Click Marker
- **How to Place**: Simply click once on any channel trace without dragging.
- **Appearance**: A clean, single vertical pinpoint marker with an event icon and label appears.
- **Advantage**: It will never look like a cramped or collapsed selection box!

### Regional Duration Selection
- **How to Place**: Click and drag horizontally across a section of waveform.
- **Top Metrics Badge**: The selection box displays real-time statistics:
  $$\Delta t = 2.45\text{ s} \quad|\quad \text{Mean: } -1.2\,\mu\text{V} \quad|\quad \text{Range (Peak-to-Peak): } 84.5\,\mu\text{V}$$
- **Right-Click Context Menu**: Right-click directly inside any active selection to instantly assign an event marker (e.g. *Spindle*, *K-Complex*, *Arousal*, *Apnea*, or a custom typed name).

---

## 🔎 Zoom Window & Interactive Measurement Caliper

Need to examine a single spindle, sharp wave, or spike discharge in high detail?

1. Click and drag to select the waveform region of interest.
2. Press <kbd>Z</kbd> (or click **Zoom Signal**).
3. The **Zoomed Waveform Inspection Dialog** opens:

```
+-------------------------------------------------------------------------------+
| Zoomed Signal: C4-M1 (Duration: 2.10s)                                [ X ]   |
+-------------------------------------------------------------------------------+
| +50 uV |                                                                      |
|        |           /\        /\                                               |
|        |          /  \  /\  /  \  /\  /\                                      |
|   0 uV |---------/----\/-/--\----\/-/--\------------------------------------- |
|        |        /      \/    \    \/    \                                     |
| -50 uV |                                                                      |
|        +----------------------------------------------------------------------+
|        0.0s       0.5s       1.0s       1.5s       2.0s                       |
|                                                                               |
|  [Caliper Active: Δt = 74 ms | Frequency = 13.5 Hz | ΔV = 68.2 µV]            |
+-------------------------------------------------------------------------------+
```

### Using the Interactive Caliper
- Inside the zoomed dialog, click and drag with your mouse across consecutive peaks or waves.
- The caliper draws caliper measurement lines and instantly calculates:
  - $\Delta t$: Interval duration in milliseconds
  - Frequency $f = \frac{1}{\Delta t}$: Exact frequency in Hertz (e.g. $13.5\text{ Hz}$ for a spindle)
  - $\Delta V$: Voltage difference in microvolts
  - Peak-to-peak amplitude range

---

## 🎯 Channel Solo / Montage Subselection Mode

When scoring high-density setups (16–64 channels), viewing all signals simultaneously can feel overwhelming.

- **Solo a Channel**: **Double-click** any channel's label tile on the left scale column.
  - All other channels are temporarily hidden.
  - The isolated channel expands to fill the view for detailed, unobstructed inspection.
- **Restore Montage**: **Double-click** the channel tile again, or press <kbd>Esc</kbd>. The complete montage is instantly restored!

---

## 🔤 Display Font Scale Adjustment

Depending on your screen resolution (laptop 1080p vs 4K external monitor), text labels may appear too large or too small:

- **Increase Font Scale**: Press <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>=</kbd> (<kbd>Cmd</kbd>+<kbd>Alt</kbd>+<kbd>=</kbd> on macOS).
- **Decrease Font Scale**: Press <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>-</kbd> (<kbd>Cmd</kbd>+<kbd>Alt</kbd>+<kbd>-</kbd> on macOS).
- **Reset to 1.0x**: Press <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>0</kbd> (<kbd>Cmd</kbd>+<kbd>Alt</kbd>+<kbd>0</kbd> on macOS).
- Accessible anytime from the top menu: **View ➔ Zoom Font In / Out / Reset**.
- Dynamically resizes all channel labels, time grid values, hover tooltips, and marker text!

---

## 🩸 SpO₂ Percentage Waveform Annotations

Pulse oximetry traces (`SpO2`) now automatically render numeric percentage values (e.g. `98%`, `96%`, `92%`, `88%`) at fixed 5-second intervals directly along the curve:
- Eliminates the need to constantly cross-reference the vertical axis to assess desaturation depth.
- Allows rapid visual scanning for cyclic nocturnal desaturations.

---

## 💡 Clinical Smart Decision Aid Tooltips

When you highlight a waveform section, CCS Sleep Studio's real-time pattern analysis inspects the signal's duration, peak-to-peak amplitude, and dominant frequency, providing immediate diagnostic tips:

| Signal Characteristics | Smart Tooltip Suggestion | Clinical Rule Reference |
| :--- | :--- | :--- |
| **11–16 Hz, 0.5–3.0 s** | 💡 *Candidate Sleep Spindle (N2 feature)* | AASM Chapter IV (EEG Rules) |
| **0.5–2.0 Hz, > 75 µV, ≥ 0.5 s** | 💡 *Candidate Slow Wave / Delta (N3 feature)* | AASM Chapter IV (EEG Rules) |
| **Biphasic, > 100 µV, 0.5–1.5 s** | 💡 *Candidate K-Complex (N2 feature)* | AASM Chapter IV (EEG Rules) |
| **8–12 Hz in Occipital** | 💡 *Candidate Alpha Rhythm (Wakefulness)* | AASM Chapter IV (EEG Rules) |
| **Flat airflow ≥ 10 s** | 💡 *Candidate Apnea (≥ 10 seconds)* | AASM Chapter V (Respiratory) |
| **Airflow drop ≥ 30% for ≥ 10 s** | 💡 *Candidate Hypopnea* | AASM Chapter V (Respiratory) |
| **SpO2 decrease ≥ 3%** | 💡 *Candidate Oxygen Desaturation* | AASM Chapter V (Respiratory) |
| **0.5–10.0 s burst in Leg EMG** | 💡 *Candidate Periodic Limb Movement (PLM)* | AASM Chapter VI (Movement) |
| **Conjugate out-of-phase EOG** | 💡 *Candidate Phasic REM Eye Movement* | AASM Chapter IV (REM Rules) |

---

## ⚡ Fluid 60+ FPS Hover Performance

In previous versions, rapid mouse movements across dense multichannel displays could trigger unnecessary full-screen canvas redraws and CPU spikes.

In modern versions of CCS Sleep Studio:
- Mouse hover coordinates are completely decoupled from widget hierarchy rebuilds using specialized Flutter `ValueNotifier` hooks.
- Hover values update smoothly with zero frame drops, even while continuous auto-scrolling or reviewing long 300-second windows!
