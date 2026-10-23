# 4. Manual Sleep Scoring & Clinical Annotations

Sleep scoring requires classifying each 30-second epoch into a standardized sleep stage and annotating discrete clinical events according to AASM criteria.

---

## 🛏️ Epoch Sleep Staging Rules & Shortcuts

Each 30-second epoch is assigned one of the 5 canonical sleep stages:

| Key | Stage | Color | Classical AASM Defining Features |
| :---: | :--- | :--- | :--- |
| <kbd>0</kbd> or <kbd>W</kbd> | **Wake (W)** | Yellow | $\ge 50\%$ epoch contains posterior dominant alpha (8–12 Hz), high chin EMG tone, voluntary eye blinks, or reading saccades. |
| <kbd>1</kbd> | **N1** | Light Blue | Alpha rhythm replaced by low-amplitude mixed-frequency (LAMF, 4–7 Hz) activity for $> 50\%$ epoch; slow rolling eye movements (SEMs); vertex sharp waves. |
| <kbd>2</kbd> | **N2** | Blue | Presence of $\ge 1$ well-defined sleep spindle (11–16 Hz, duration $\ge 0.5\text{ s}$) and/or K-complex (biphasic slow wave $\ge 0.5\text{ s}$) unassociated with arousal. |
| <kbd>3</kbd> | **N3 (Slow Wave Sleep)** | Dark Blue | $\ge 20\%$ of epoch consists of slow wave activity ($\le 2\text{ Hz}$, peak-to-peak amplitude $\ge 75\,\mu\text{V}$) measured in frontal derivations ($F_4\text{-}M_1$). |
| <kbd>5</kbd> or <kbd>R</kbd> | **REM (R)** | Green | Low chin EMG atonia, rapid eye movements (sharp conjugate deflections), and low-amplitude mixed-frequency EEG (sawtooth waves). |

### Stage Watermark Ribbon
Whenever an epoch is scored, the background of the waveform viewport renders a subtle stage tint, and a watermark badge (e.g. `[N2]`, `[N3]`, `[REM]`) appears in the upper right corner, giving instant visual confirmation of the epoch's classification.

---

## 🏷️ Annotating Discrete Clinical Events

To score an event (Arousal, Apnea, Spindle, Limb Movement, etc.):

1. **Click and drag** across the event duration on the relevant channel (e.g. on *Airflow* for apnea, *LAT/RAT* for leg movements, *C4-M1* for spindles).
2. Use one of three methods to assign the label:
   - **Number Shortcuts**: Press keys <kbd>1</kbd>–<kbd>9</kbd> or function keys <kbd>F1</kbd>–<kbd>F12</kbd>.
   - **Right-Click Menu**: Right-click the highlighted box and select the event from the context menu.
   - **Typable Custom Marker**: Press <kbd>T</kbd> or <kbd>Shift</kbd>+<kbd>M</kbd> to type any custom label.

---

## ✍️ Typable Custom Markers (<kbd>T</kbd> / <kbd>Shift+M</kbd>)

Clinicians often need to record unique observations (e.g. *"Patient coughing"*, *"Electrode popped off"*, *"CPAP pressure adjusted to 10 cmH2O"*, *"Bruxism"*).

1. Select a waveform region or position the cursor at the timestamp.
2. Press <kbd>T</kbd> or <kbd>Shift</kbd>+<kbd>M</kbd> (or choose **Events ➔ Custom Typable Marker…**).
3. A prompt appears:

```
+-------------------------------------------------------------+
| Enter Custom Event Label                                    |
+-------------------------------------------------------------+
| Event Name: [ CPAP Titration to 10 cmH2O                  ] |
|                                                             |
|          [ Cancel ]                         [ Add Event ]   |
+-------------------------------------------------------------+
```

4. Type your annotation and press <kbd>Enter</kbd>. The marker is placed directly onto the timeline with exact time bounds and channel attachment!

---

## 🎛️ Markers & Annotations Manager (<kbd>M</kbd>)

Press <kbd>M</kbd> (or select **Events ➔ Manage Markers & Annotations…**) to open the comprehensive manager:

```
+-------------------------------------------------------------------------------+
| Markers & Annotations Manager                                         [ X ]   |
+-------------------------------------------------------------------------------+
| Total Events: 284 | Arousals: 42 | Apneas: 110 | Spindles: 95 | Custom: 37   |
|                                                                               |
| Filter by Group: [ All Events  v ]               [ Show / Hide Groups... ]    |
|                                                                               |
| Time        Duration   Channel     Label                   Type               |
| ----------------------------------------------------------------------------- |
| 23:14:02.5  14.2 s     Flow        Obstructive Apnea       Respiratory        |
| 23:14:18.0   3.5 s     C4-M1       Arousal                 Neurophys          |
| 23:15:45.1   1.2 s     C4-M1       Sleep Spindle (13.5Hz)  Microstructure     |
| 23:22:10.0   0.0 s     Global      CPAP Adjusted           Custom Pinpoint    |
|                                                                               |
| [ Jump to Event ]   [ Delete Selected ]   [ Export CSV ]   [ Clear All ]      |
+-------------------------------------------------------------------------------+
```

- **Jump to Event**: Double-click any row in the list to immediately navigate the timeline and center the waveform on that event.
- **Export CSV / XML**: Export your scoring and annotations in standardized table format for statistical analysis or integration with third-party software.
- **Group Visibility Toggles**: Temporarily hide certain marker categories (e.g. hide micro-events to focus on respiratory scoring).
