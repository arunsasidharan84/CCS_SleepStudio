# 7. Troubleshooting & Frequently Asked Questions (FAQ)

Answers to common questions and troubleshooting tips for users of CCS Sleep Studio.

---

### Q1: Why do my EEG waveforms look completely flat or huge off-scale?
**Answer**:
- Check the **Channel Scale Factor** in the left scale column.
- Click the channel's $\mu\text{V}$ badge or choose **Montage ➔ Configure Channels…**.
- Standard clinical display sensitivity is usually $50\,\mu\text{V}$ or $70\,\mu\text{V}$ for EEG, $50\,\mu\text{V}$ for EOG, and auto-scaled for respiratory bands.
- Also verify high-pass and low-pass filters: standard sleep EEG uses **0.3 Hz High-Pass** and **35 Hz Low-Pass** (or 0.5–30 Hz) with a **50 Hz / 60 Hz Notch filter**.

---

### Q2: Why does an unhandled error dialog appear, and how do I dismiss it without losing my work?
**Answer**:
- CCS Sleep Studio includes a global **Safe Error Dismissal** handler.
- If an unexpected error occurs, a styled error card appears with a prominent **[Dismiss / Return to Workspace]** button.
- Clicking this safely recovers the viewport without restarting the application or losing unsaved annotations!

---

### Q3: How do I export or save my manual scorings?
**Answer**:
- Press <kbd>Ctrl+S</kbd> (<kbd>Cmd+S</kbd> on macOS) to save your scoring.
- CCS Sleep Studio automatically writes:
  - `<recording_name>.ccsscore`: High-precision sleep stage staging vector.
  - `<recording_name>.ccsevents`: Detailed timestamped clinical annotations and markers.
- You can also export standard **NSRR XML**, **Polyman `.txt`**, or **tabular `.csv`** from **File ➔ Export Annotations…**.

---

### Q4: My EOG channels are inverted or deflecting in the wrong direction.
**Answer**:
- AASM clinical guidelines place:
  - $E_1$ (LOC): $1\text{ cm}$ below and lateral to the left outer canthus.
  - $E_2$ (ROC): $1\text{ cm}$ above and lateral to the right outer canthus.
- When both are referenced to the same mastoid ($M_2$ or $A_2$), conjugate eye movements naturally deflect in **opposite directions** (out-of-phase).
- If your recording requires polarity inversion, open **Montage ➔ Configure Channels…** and toggle **Flip Polarity** on that channel.

---

### Q5: Can I run this software on a computer without an internet connection?
**Answer**:
- **Yes! 100% offline.**
- CCS Sleep Studio does not require internet access, cloud servers, or remote API calls. All signal processing, filtering, AI model inference, topoplot rendering, and report generation execute locally on your device.
- Patient health information (PHI) never leaves your local workstation.

---

### Q6: How do I update to the latest release?
**Answer**:
- When connected to the internet, CCS Sleep Studio automatically checks for new updates on GitHub.
- If a new version is available, an update notification will alert you.
- Click **Download & Update** to download and install the newest release directly, or click **Download via Browser** to download the package from the GitHub Releases page.
