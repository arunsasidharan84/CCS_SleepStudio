# 1. Getting Started & Installation

CCS Sleep Studio is distributed as a self-contained, pre-compiled application. It does **not** require installing Python, MATLAB, Anaconda, CUDA drivers, or command-line developer tools.

---

## 📥 Choosing Your Download Package

From the [GitHub Releases Page](https://github.com/arunsasidharan84/CCS_SleepStudio/releases/latest), choose the package for your operating system:

| Operating System | Recommended Package | When to use |
| :--- | :--- | :--- |
| **macOS** (Apple Silicon & Intel) | `CCSSleepStudio-macos.zip` | Standard universal bundle for modern macOS computers. |
| **macOS** (Lightweight) | `CCSSleepStudio-lite-macos.zip` | Minimal package for basic scoring and visual review. |
| **Windows** (64-bit) | `CCSSleepStudio-Installer.exe` | Standard Windows installer with desktop and start menu shortcuts. |
| **Linux (Debian / Ubuntu)** | `CCSSleepStudio-linux-amd64.deb` | Ubuntu 20.04+, Debian 11+, Linux Mint. |
| **Linux (RHEL / Fedora)** | `CCSSleepStudio-linux-x86_64.rpm` | Fedora 38+, AlmaLinux 9+, RHEL 9+, Rocky Linux. |

---

## 🍏 macOS Installation Guide

Because development packages are self-distributed outside the Mac App Store, macOS Gatekeeper security will check the downloaded application.

### Step 1: Download & Unzip
1. Download `CCSSleepStudio-macos.zip`.
2. Double-click to unzip it in your `Downloads` folder. You will see **`CCS Sleep Studio.app`**.
3. Drag **`CCS Sleep Studio.app`** into your `/Applications` folder.

### Step 2: First-Time Launch (Bypassing Gatekeeper)
If macOS says *"CCS Sleep Studio cannot be opened because the developer cannot be verified"*:

#### Option A: Quick Right-Click (Easiest)
1. Open **Finder** and go to **Applications**.
2. **Right-click (or Control-click)** `CCS Sleep Studio.app`.
3. Select **Open** from the menu.
4. When the confirmation prompt appears, click **Open**.
5. *You only have to do this once!* Future launches will open normally with a standard double-click.

#### Option B: Terminal Command
Open **Terminal** and paste:
```bash
xattr -rd com.apple.quarantine /Applications/CCS\ Sleep\ Studio.app
```

---

## 🪟 Windows Installation Guide

1. Download `CCSSleepStudio-Installer.exe`.
2. Double-click the installer.
3. If Windows SmartScreen displays *"Windows protected your PC"*:
   - Click **More info**.
   - Click **Run anyway**.
4. Follow the setup wizard to complete the installation.
5. Launch **CCS Sleep Studio** from the Desktop icon or Start Menu.

---

## 🐧 Linux Installation Guide

### Ubuntu / Debian
```bash
# Install the .deb package:
sudo dpkg -i CCSSleepStudio-linux-amd64.deb

# Fix any missing system dependencies if needed:
sudo apt-get install -f
```

### Fedora / RHEL / AlmaLinux
```bash
sudo rpm -i CCSSleepStudio-linux-x86_64.rpm
```

### Launching on Linux
Type `ccs-sleep-studio` in your terminal or launch it from your desktop Application Menu.

---

## 🚀 First-Time Orientation

When you launch CCS Sleep Studio, you are greeted with the primary workspace:

```
+-----------------------------------------------------------------------------------+
|  File   Edit   View   Montage   Autoscore   Events   Utilities   Help             |
+-----------------------------------------------------------------------------------+
|  WORKFLOW: [1. Open File] > [2. AASM Montage] > [3. Autoscore] > [4. Review] ...  |
+-----------------------------------------------------------------------------------+
|  [Toolbar: <<  <  Page 1/960 [30s]  >  >>]  [Grid: ON]  [Font: 1.0x] [Solo: OFF]  |
+-----------------------------------------------------------------------------------+
|  LOC-A2   ~~~~~~~~~~~~~~~~~~\~~~~~~~~~~~~/~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ |
|  ROC-A2   ~~~~~~~~~~~~~~~~~~/~~~~~~~~~~~~\~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ |
|  F4-A1    ~~~~~~~/\/\/\~~~~~~~~~~~~~~~~~~~~~~~~/\/\/\~~~~~~~~~~~~~~~~~~~~~~~~~~~~ |
|  C4-A1    ~~~~~~~~~/\/\/\/\/\~~~~~~~~~~~~~~~~~~~~~/\/\/\/\/\~~~~~~~~~~~~~~~~~~~~~ |
|  O2-A1    ~~~~~~~~~~~~/\/\/\/\~~~~~~~~~~~~~~~~~~~~~~~/\/\/\/\~~~~~~~~~~~~~~~~~~~~ |
|  Chin     ----------------------------------------------------------------------- |
|  ECG      __/\____/\____/\____/\____/\____/\____/\____/\____/\____/\____/\_______ |
|  SpO2     98% ----------------- 98% ----------------- 97% ----------------------- |
+-----------------------------------------------------------------------------------+
|  EPOCH: 1 | TIME: 23:00:00 (00:00:00) | STAGE: WAKE | HR: 68 bpm | SpO2: 98%      |
+-----------------------------------------------------------------------------------+
```

- **Top Menu Bar**: Complete access to all features, configuration dialogs, and tools.
- **Workflow Bar**: Step-by-step guidance showing which action to take next.
- **Timeline Canvas**: 60+ FPS waveform display with configurable time grids, stage watermarks, and annotation overlays.
- **Channel Scales Column (Left)**: Shows electrode labels, sensitivity ($\mu\text{V}$), and double-click channel solo controls.
- **Status Bar (Bottom)**: Displays exact recording time, current epoch number, active sleep stage, and live hover coordinate metrics.
