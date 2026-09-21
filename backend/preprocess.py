#!/usr/bin/env python3
"""Epoch-level EEG preprocessing pipeline for CCS Sleep Studio.

Wraps the ccstools CCS EEG cleaning pipeline with an MNE-based I/O layer.
Output is a clean EDF file and a JSON log that the Flutter UI can consume.

Resolver note: this file lives alongside scorer.py and cli.py in the
backend/ package directory.  The Flutter autoscore_command.dart pattern
discovers it the same way — by finding the sibling `cli.py` first and then
resolving `preprocess.py` relative to that parent directory.
"""

from __future__ import annotations

import os
import sys
import warnings

warnings.filterwarnings("ignore", message="DataFrame is highly fragmented")
warnings.filterwarnings("ignore", message="Using padding='same'")
warnings.filterwarnings("ignore", category=DeprecationWarning)
warnings.filterwarnings("ignore", category=UserWarning)
warnings.filterwarnings("ignore", category=FutureWarning)

if __package__:
    from .runtime_bootstrap import configure_runtime
else:
    from runtime_bootstrap import configure_runtime

configure_runtime()

import argparse
import json
import re
import traceback
from datetime import datetime, timezone
from pathlib import Path
from typing import Sequence

import mne

# ---------------------------------------------------------------------------
# ccstools import — optional so we can give a friendly error message
# ---------------------------------------------------------------------------
# Stub optional external dependencies from ccstools.eegfeatures (like fooof,
# pycatch22, etc.) if they are not installed in the runtime environment.
# Preprocessing only requires MNE, autoreject, and GEDAI, so missing spectral
# feature extraction packages must not prevent importing ccstools.
from unittest.mock import MagicMock

for _pkg in (
    "fooof",
    "fooof.analysis",
    "fooof.analysis.error",
    "pycatch22",
):
    if _pkg not in sys.modules:
        sys.modules[_pkg] = MagicMock()

try:
    from ccstools.ccs_eeg.pipeline import run_ccs_pipeline  # type: ignore[import]

    _CCSTOOLS_AVAILABLE = True
except ImportError as _ccstools_import_error:
    _CCSTOOLS_AVAILABLE = False
    _CCSTOOLS_IMPORT_ERROR = str(_ccstools_import_error)

# ---------------------------------------------------------------------------
# Allowed preprocessing steps (mirrors pipeline.py DEFAULT_CONFIG + extras)
# ---------------------------------------------------------------------------
VALID_STEPS = {
    "downsample",
    "filter",
    "badchannel",
    "gedai",
    "interpolate",
    "ica1_blink_ecg",
    "ica2_other",
}

DEFAULT_STEPS = ["filter", "badchannel", "interpolate"]

# ---------------------------------------------------------------------------
# EEG channel auto-detection (mirrors scorer.py infer_channel_groups)
# ---------------------------------------------------------------------------

_EEG_STANDARDS = {
    "FP1", "FP2", "F7", "F3", "FZ", "F4", "F8",
    "T3", "T4", "T5", "T6", "T7", "T8",
    "C3", "CZ", "C4",
    "P3", "PZ", "P4",
    "O1", "OZ", "O2",
    "AF7", "AF3", "AFZ", "AF4", "AF8",
}

_REF_STANDARDS = {"M1", "M2", "A1", "A2"}


def _normalize_channel_label(name: str) -> str:
    label = name.strip()
    label = label.replace("EEG ", "").replace("-Ref", "").replace("REF", "")
    label = re.sub(r"^POL\s+", "", label, flags=re.IGNORECASE)
    label = re.sub(r"^E\d+-", "", label, flags=re.IGNORECASE)
    if ":" in label:
        label = label.split(":", 1)[0]
    return label.strip()


def _channel_root(name: str) -> str:
    clean = _normalize_channel_label(name).upper()
    return re.split(r"[-_\s]", clean)[0]


def _is_eeg_root(root: str) -> bool:
    if root in _EEG_STANDARDS:
        return True
    if re.fullmatch(r"(?:FP|AF|F|FT|FC|T|C|TP|CP|P|PO|O)(?:Z|\d{1,2})", root):
        return True
    return bool(re.fullmatch(r"EEG\d*", root))


def _auto_detect_eeg_channels(channel_names: Sequence[str]) -> list[str]:
    """Return EEG channel names inferred from standard 10-20 naming patterns."""
    eeg: list[str] = []
    for original in channel_names:
        upper = original.upper()
        # Skip obvious non-EEG channels
        if any(token in upper for token in ("EOG", "LOC", "ROC", "EMG", "CHIN", "MYO", "ECG", "EKG")):
            continue
        root = _channel_root(original)
        if root in _REF_STANDARDS:
            continue
        if _is_eeg_root(root):
            eeg.append(original)
    # Fallback: single unknown channel
    if not eeg and len(channel_names) == 1:
        eeg.append(channel_names[0])
    return sorted(set(eeg))


# ---------------------------------------------------------------------------
# File I/O helpers
# ---------------------------------------------------------------------------

def _read_raw_file(path: Path) -> mne.io.BaseRaw:
    """Read common EEG formats supported by MNE."""
    suffix = path.suffix.lower()
    if suffix == ".edf":
        return mne.io.read_raw_edf(path, preload=True, verbose="ERROR")
    if suffix == ".bdf":
        return mne.io.read_raw_bdf(path, preload=True, verbose="ERROR")
    if suffix == ".fif":
        return mne.io.read_raw_fif(path, preload=True, verbose="ERROR")
    if suffix == ".set":
        return mne.io.read_raw_eeglab(path, preload=True, verbose="ERROR")
    if suffix == ".vhdr":
        return mne.io.read_raw_brainvision(path, preload=True, verbose="ERROR")
    # Generic fallback
    return mne.io.read_raw(path, preload=True, verbose="ERROR")


# ---------------------------------------------------------------------------
# CLI helpers
# ---------------------------------------------------------------------------

def _parse_csv(value: str | None) -> list[str]:
    if not value:
        return []
    return [item.strip() for item in value.split(",") if item.strip()]


def log(message: str) -> None:  # noqa: D103
    print(message, flush=True)


# ---------------------------------------------------------------------------
# Core preprocessing function
# ---------------------------------------------------------------------------

def preprocess_file(
    input_file: str | Path,
    out_dir: str | Path | None = None,
    eeg_channels: list[str] | None = None,
    steps: list[str] | None = None,
    epoch_sec: float = 30.0,
    downsample_hz: float = 250.0,
    bandpass_lo: float = 0.5,
    bandpass_hi: float = 40.0,
    notch_hz: float | None = 50.0,
    bad_channel_method: str = "ransac",
    gedai_leadfield: str | None = None,
    suffix: str = "_clean",
) -> dict:
    """Run the CCS EEG preprocessing pipeline on *input_file*.

    Returns a dict describing the outputs (paths, metadata).
    """
    if not _CCSTOOLS_AVAILABLE:
        raise ImportError(
            f"ccstools is not installed or importable.\n"
            f"Install it by adding the git submodule at vendor/ccstools and\n"
            f"ensuring vendor/ is on sys.path via configure_runtime().\n"
            f"Original error: {_CCSTOOLS_IMPORT_ERROR}"
        )

    input_file = Path(input_file)
    if out_dir is None:
        out_dir = input_file.parent
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    steps = steps or DEFAULT_STEPS
    # Validate step names
    unknown = [s for s in steps if s not in VALID_STEPS]
    if unknown:
        raise ValueError(
            f"Unknown pipeline step(s): {unknown}. "
            f"Valid steps are: {sorted(VALID_STEPS)}"
        )

    # ---- 1. Load --------------------------------------------------------
    log("PROGRESS 0.1 Loading file")
    raw = _read_raw_file(input_file)
    total_duration_sec = raw.n_times / float(raw.info["sfreq"])
    original_sfreq = float(raw.info["sfreq"])

    # ---- 2. Pick channels -----------------------------------------------
    log("PROGRESS 0.2 Setting up pipeline")
    all_channel_names = list(raw.info["ch_names"])

    if eeg_channels:
        # Validate user-specified channels exist
        missing = [ch for ch in eeg_channels if ch not in all_channel_names]
        if missing:
            raise ValueError(
                f"Specified EEG channels not found in file: {missing}\n"
                f"Available channels: {all_channel_names}"
            )
        selected_eeg = eeg_channels
    else:
        selected_eeg = _auto_detect_eeg_channels(all_channel_names)
        if not selected_eeg:
            raise ValueError(
                "No EEG channels could be auto-detected. "
                "Use --eeg-channels to specify channels explicitly."
            )

    log(f"EEG channels selected ({len(selected_eeg)}): {', '.join(selected_eeg)}")

    # Pick only EEG channels before passing to the pipeline
    raw.pick(selected_eeg)
    raw.set_channel_types({ch: "eeg" for ch in selected_eeg})

    # ---- 3. Build pipeline config ----------------------------------------
    notch_freqs: tuple | None = (notch_hz,) if (notch_hz and notch_hz > 0) else None

    # Map user-facing step names to pipeline.py step names
    # 'badchannel' is our user-facing name; pipeline uses 'badchannel' directly
    cfg: dict = {
        "steps": steps,
        "downsample_freq": downsample_hz if "downsample" in steps else None,
        "filter_bandpass": (bandpass_lo, bandpass_hi),
        "notch_freqs": notch_freqs,
        "gedai_leadfield_path": gedai_leadfield,
        # RANSAC is enabled/disabled via the bad channel method choice
        "ChannelCriterion": 0.8 if bad_channel_method == "ransac" else None,
        "FlatlineCriterion": 5,
    }

    # ---- 4. Run pipeline -------------------------------------------------
    log("PROGRESS 0.5 Running preprocessing")
    cleaned_raw = run_ccs_pipeline(
        raw,
        output_dir=str(out_dir),
        config=cfg,
    )

    # Capture bad channels removed during pipeline
    bad_channels_removed: list[str] = list(cleaned_raw.info.get("bads", []))

    # ---- 5. Save EDF -----------------------------------------------------
    log("PROGRESS 0.9 Saving output")
    stem = input_file.stem
    out_edf_name = f"{stem}{suffix}.edf"
    out_edf_path = out_dir / out_edf_name

    try:
        mne.export.export_raw(str(out_edf_path), cleaned_raw, fmt="edf", overwrite=True, verbose="ERROR")
    except Exception as export_exc:
        # Fallback: save as FIF if EDF export unavailable (older MNE)
        log(f"WARNING EDF export failed ({export_exc}); falling back to FIF")
        out_edf_path = out_dir / f"{stem}{suffix}.fif"
        cleaned_raw.save(str(out_edf_path), overwrite=True)

    log(f"OUTPUT_EDF {out_edf_path}")

    # ---- 6. Write JSON log -----------------------------------------------
    log_path = out_dir / f"{stem}{suffix}_log.json"
    log_payload: dict = {
        "input_file": str(input_file),
        "steps_run": steps,
        "eeg_channels": selected_eeg,
        "bad_channels_removed": bad_channels_removed,
        "duration_sec": round(total_duration_sec, 3),
        "original_sample_rate_hz": original_sfreq,
        "output_sample_rate_hz": float(cleaned_raw.info["sfreq"]),
        "epoch_sec": epoch_sec,
        "bandpass_hz": [bandpass_lo, bandpass_hi],
        "notch_hz": notch_hz,
        "bad_channel_method": bad_channel_method,
        "gedai_leadfield": gedai_leadfield,
        "timestamp": datetime.now(tz=timezone.utc).isoformat(),
        "output_edf": str(out_edf_path),
    }
    with log_path.open("w", encoding="utf-8") as fh:
        json.dump(log_payload, fh, indent=2)
    log(f"OUTPUT_LOG {log_path}")

    return log_payload


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main() -> None:  # noqa: D103
    parser = argparse.ArgumentParser(
        description="Epoch-level EEG preprocessing using the CCS pipeline.",
    )
    parser.add_argument(
        "input_file",
        help="Input EEG recording (EDF / BDF / FIF / SET).",
    )
    parser.add_argument(
        "--out-dir",
        default=None,
        help="Output directory. Defaults to the same folder as the input file.",
    )
    parser.add_argument(
        "--eeg-channels",
        default=None,
        help="Comma-separated EEG channel names. Auto-detected if omitted.",
    )
    parser.add_argument(
        "--steps",
        default=",".join(DEFAULT_STEPS),
        help=(
            "Comma-separated pipeline steps to run. "
            f"Valid: {', '.join(sorted(VALID_STEPS))}. "
            f"Default: {','.join(DEFAULT_STEPS)}"
        ),
    )
    parser.add_argument(
        "--epoch-sec",
        type=float,
        default=30.0,
        help="Non-overlapping epoch size in seconds (informational; default 30).",
    )
    parser.add_argument(
        "--downsample-hz",
        type=float,
        default=250.0,
        help="Resample target in Hz (default 250). Only used when 'downsample' is in --steps.",
    )
    parser.add_argument(
        "--bandpass-lo",
        type=float,
        default=0.5,
        help="Bandpass high-pass cut-off in Hz (default 0.5).",
    )
    parser.add_argument(
        "--bandpass-hi",
        type=float,
        default=40.0,
        help="Bandpass low-pass cut-off in Hz (default 40).",
    )
    parser.add_argument(
        "--notch-hz",
        type=float,
        default=50.0,
        help="Notch filter frequency in Hz (default 50). Pass 0 to disable.",
    )
    parser.add_argument(
        "--bad-channel-method",
        choices=["ransac", "none"],
        default="ransac",
        help="Bad channel detection method: 'ransac' (default) or 'none'.",
    )
    parser.add_argument(
        "--gedai-leadfield",
        default=None,
        help=(
            "Path to the GEDAI leadfield .mat file. "
            "If omitted, ccstools uses its bundled resource."
        ),
    )
    parser.add_argument(
        "--suffix",
        default="_clean",
        help="Suffix added to the output EDF filename before the extension (default '_clean').",
    )

    args = parser.parse_args()

    try:
        eeg_channels = _parse_csv(args.eeg_channels) if args.eeg_channels else None
        steps = _parse_csv(args.steps) if args.steps else DEFAULT_STEPS
        out_dir = Path(args.out_dir) if args.out_dir else None
        notch_hz: float | None = float(args.notch_hz) if args.notch_hz else None

        result = preprocess_file(
            input_file=args.input_file,
            out_dir=out_dir,
            eeg_channels=eeg_channels,
            steps=steps,
            epoch_sec=args.epoch_sec,
            downsample_hz=args.downsample_hz,
            bandpass_lo=args.bandpass_lo,
            bandpass_hi=args.bandpass_hi,
            notch_hz=notch_hz,
            bad_channel_method=args.bad_channel_method,
            gedai_leadfield=args.gedai_leadfield,
            suffix=args.suffix,
        )

        log("PROGRESS 1.0 Done")
        log(f"Bad channels removed: {result.get('bad_channels_removed', [])}")
        log(f"Output sample rate: {result.get('output_sample_rate_hz')} Hz")

    except Exception:
        # Print to stdout so the Flutter UI console captures it
        print("ERROR Preprocessing failed:", flush=True)
        print(traceback.format_exc(), flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
