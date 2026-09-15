#!/usr/bin/env python3
"""Reusable automated sleep scoring pipeline.

The primary scorer is YASA's open-source LightGBM sleep staging model. When the
local SleepGPT checkpoint from this workspace is available, YASA probabilities
can be sequence-corrected with SleepGPT.
"""

from __future__ import annotations

import os
import sys

if __package__:
    from .runtime_bootstrap import configure_runtime
else:
    from runtime_bootstrap import configure_runtime

configure_runtime()

import json
import re
import time
import traceback
import types
import warnings
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Sequence

warnings.filterwarnings("ignore", message="DataFrame is highly fragmented")
warnings.filterwarnings("ignore", message="Using padding='same'")
try:
    import pandas as pd
    warnings.filterwarnings("ignore", category=pd.errors.PerformanceWarning)
except Exception:
    pass



import numpy as np
import scipy.integrate as scipy_integrate

if not hasattr(np, "trapz") and hasattr(np, "trapezoid"):
    np.trapz = np.trapezoid
if not hasattr(np, "in1d"):
    np.in1d = np.isin
if not hasattr(scipy_integrate, "simps") and hasattr(scipy_integrate, "simpson"):
    def _simps_compat(y, x=None, dx=1.0, axis=-1, even=None):
        del even
        return scipy_integrate.simpson(y, x=x, dx=dx, axis=axis)

    scipy_integrate.simps = _simps_compat

import mne
import pandas as pd
import yasa



try:
    from sklearn.exceptions import InconsistentVersionWarning

    warnings.filterwarnings("ignore", category=InconsistentVersionWarning)
except Exception:
    pass


STAGE_COLUMNS = ["W", "N1", "N2", "N3", "R"]
STAGE_BY_INDEX = {0: "W", 1: "N1", 2: "N2", 3: "N3", 4: "R"}
SCORINGHERO_STAGE_LABELS = {"W": "Wake", "N1": "N1", "N2": "N2", "N3": "N3", "R": "REM"}
SCORINGHERO_STAGE_DIGITS = {"W": 1, "N1": -1, "N2": -2, "N3": -3, "R": 0}

LogFn = Callable[[str], None]


@dataclass(frozen=True)
class ChannelGuess:
    eeg: list[str]
    ref: list[str]
    eog: list[str]
    emg: list[str]


@dataclass(frozen=True)
class ScoreResult:
    algorithm: str
    output_json: Path
    probability_json: Path | None
    per_channel_json: Path | None
    stages: list[str]
    montages_used: list[str]


def log_noop(message: str) -> None:
    del message


def _stage_label_to_key(label: str | None) -> str:
    normalized = str(label or "").strip().upper()
    return {
        "WAKE": "W",
        "W": "W",
        "N1": "N1",
        "N2": "N2",
        "N3": "N3",
        "REM": "R",
        "R": "R",
    }.get(normalized, "W")


def _probabilities_from_scoringhero(records: Sequence[dict[str, object]]) -> pd.DataFrame:
    rows: list[dict[str, float]] = []
    for record in records:
        row = {stage: 0.0 for stage in STAGE_COLUMNS}
        probabilities = record.get("probabilities")
        if isinstance(probabilities, dict):
            for key, value in probabilities.items():
                stage = _stage_label_to_key(str(key))
                if stage in row:
                    try:
                        row[stage] = float(value)
                    except (TypeError, ValueError):
                        pass
            total = sum(row.values())
            if total > 0:
                rows.append({key: value / total for key, value in row.items()})
                continue

        stage = _stage_label_to_key(record.get("stage"))
        row[stage] = 1.0
        rows.append(row)
    return pd.DataFrame(rows, columns=STAGE_COLUMNS)


def apply_sleepgpt_to_scoring_file(
    scoring_json: str | Path,
    output_json: str | Path | None = None,
    alpha: float = 0.1,
    ngram: int = 30,
    log: LogFn = log_noop,
) -> Path:
    """Apply SleepGPT sequence correction to an existing ScoringNidra JSON."""
    scoring_json = Path(scoring_json)
    with scoring_json.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, list) or not payload or not isinstance(payload[0], list):
        raise ValueError("Scoring file must use ScoringNidra/ScoringHero [stages, annotations] JSON format.")

    stage_records = payload[0]
    annotations = payload[1] if len(payload) > 1 and isinstance(payload[1], list) else []
    if not stage_records:
        raise ValueError("Scoring file contains no epochs.")

    probabilities = _probabilities_from_scoringhero(stage_records)
    log(f"Loaded {len(probabilities)} epochs from existing hypnogram.")
    corrected = run_sleepgpt_correction(probabilities, alpha=alpha, ngram=ngram, max_runtime_sec=None, log=log)
    if not corrected:
        raise RuntimeError("SleepGPT correction was unavailable or failed.")

    corrected = corrected[: len(stage_records)]
    corrected_records = build_scoringhero_stage_records(
        corrected,
        probabilities,
        source="manual_sleepgpt",
    )
    output_path = Path(output_json) if output_json else scoring_json.with_name(
        f"{scoring_json.stem}_sleepgpt_scoring.json"
    )
    write_json(output_path, [corrected_records, annotations])
    log(f"Saved SleepGPT-corrected scoring JSON: {output_path}")
    return output_path


def normalize_channel_label(name: str) -> str:
    """Return a readable channel label for loose matching."""
    label = name.strip()
    label = label.replace("EEG ", "").replace("-Ref", "").replace("REF", "")
    label = re.sub(r"^POL\s+", "", label, flags=re.IGNORECASE)
    label = re.sub(r"^E\d+-", "", label, flags=re.IGNORECASE)
    if ":" in label:
        label = label.split(":", 1)[0]
    return label.strip()


def channel_root(name: str) -> str:
    clean = normalize_channel_label(name).upper()
    return re.split(r"[-_\s]", clean)[0]


def referenced_suffix(name: str) -> str | None:
    label = name.strip().upper()
    if ":" in label:
        suffix = label.rsplit(":", 1)[1]
    elif "-" in label:
        suffix = label.rsplit("-", 1)[1]
    else:
        return None
    suffix = normalize_channel_label(suffix).upper()
    suffix = re.split(r"[-_\s]", suffix)[0]
    return suffix or None


def is_prereferenced_channel(name: str) -> bool:
    return referenced_suffix(name) in {"M1", "M2", "A1", "A2"}


def infer_channel_groups(channel_names: Sequence[str]) -> ChannelGuess:
    """Guess EEG/reference/EOG/EMG channel groups from EDF/FIF labels."""
    eeg_standards = {
        "FP1",
        "FP2",
        "F7",
        "F3",
        "FZ",
        "F4",
        "F8",
        "T3",
        "T4",
        "T5",
        "T6",
        "T7",
        "T8",
        "C3",
        "CZ",
        "C4",
        "P3",
        "PZ",
        "P4",
        "O1",
        "OZ",
        "O2",
    }
    ref_standards = {"M1", "M2", "A1", "A2"}

    def is_eeg_root(root: str) -> bool:
        if root in eeg_standards:
            return True
        if re.fullmatch(r"(?:FP|AF|F|FT|FC|T|C|TP|CP|P|PO|O)(?:Z|\d{1,2})", root):
            return True
        return bool(re.fullmatch(r"EEG\d*", root))

    eeg: list[str] = []
    ref: list[str] = []
    eog: list[str] = []
    emg: list[str] = []
    prereferenced_eeg_roots = {
        channel_root(name)
        for name in channel_names
        if is_prereferenced_channel(name) and channel_root(name) in eeg_standards
    }
    prereferenced_eog_roots = {
        channel_root(name)
        for name in channel_names
        if is_prereferenced_channel(name) and channel_root(name) in {"E1", "E2"}
    }

    for original in channel_names:
        upper = original.upper()
        clean = normalize_channel_label(original).upper()
        clean_root = channel_root(original)

        if any(token in upper for token in ("EOG", "LOC", "ROC")) or clean_root in {"E1", "E2"}:
            if not is_prereferenced_channel(original) and clean_root in prereferenced_eog_roots:
                continue
            eog.append(original)
            continue
        if any(token in upper for token in ("EMG", "CHIN", "MYO")):
            emg.append(original)
            continue
        if clean_root in ref_standards:
            ref.append(original)
            continue
        if not is_prereferenced_channel(original) and clean_root in prereferenced_eeg_roots:
            continue
        if is_eeg_root(clean_root):
            eeg.append(original)

    if not eeg and len(channel_names) == 1 and not (ref or eog or emg):
        # Preserve the documented single-channel workflow for generic labels.
        eeg.append(channel_names[0])

    eog_by_root: dict[str, str] = {}
    for channel in eog:
        eog_by_root.setdefault(channel_root(channel), channel)
    return ChannelGuess(eeg=sorted(set(eeg)), ref=sorted(set(ref)), eog=list(eog_by_root.values()), emg=sorted(set(emg)))


def read_raw_file(path: str | Path, preload: bool = False) -> mne.io.BaseRaw:
    """Read common sleep EEG formats supported by MNE."""
    path = Path(path)
    suffix = path.suffix.lower()
    if suffix == ".edf":
        return mne.io.read_raw_edf(path, preload=preload, verbose="ERROR")
    if suffix == ".bdf":
        return mne.io.read_raw_bdf(path, preload=preload, verbose="ERROR")
    if suffix == ".gdf":
        return mne.io.read_raw_gdf(path, preload=preload, verbose="ERROR")
    if suffix == ".fif":
        return mne.io.read_raw_fif(path, preload=preload, verbose="ERROR")
    if suffix == ".set":
        return mne.io.read_raw_eeglab(path, preload=preload, verbose="ERROR")
    if suffix == ".vhdr":
        return mne.io.read_raw_brainvision(path, preload=preload, verbose="ERROR")
    if suffix == ".eeg":
        return mne.io.read_raw_nihon(path, preload=preload, verbose="ERROR")
    raise ValueError(f"Unsupported data file extension: {suffix}. Use EDF/BDF/GDF/FIF/SET/VHDR/EEG.")


def scan_channels(data_file: str | Path) -> tuple[list[str], ChannelGuess, float, float]:
    """Return channel names, guessed groups, sample rate, and duration seconds."""
    raw = read_raw_file(data_file, preload=False)
    duration_sec = raw.n_times / float(raw.info["sfreq"])
    names = list(raw.info["ch_names"])
    return names, infer_channel_groups(names), float(raw.info["sfreq"]), duration_sec


def _pick_existing(raw: mne.io.BaseRaw, names: Iterable[str]) -> list[str]:
    available = set(raw.info["ch_names"])
    return [name for name in names if name in available]


def _make_pair_name(eeg: str, ref: str) -> str:
    return f"{eeg}-{ref}"


def _clinical_reference_for(eeg: str, refs: Sequence[str]) -> str | None:
    if is_prereferenced_channel(eeg):
        return None
    eeg_clean = normalize_channel_label(eeg).upper()
    refs_upper = [(ref, normalize_channel_label(ref).upper()) for ref in refs]
    contralateral = "M1" if eeg_clean.endswith(("4", "Z")) else "M2"
    alternates = [contralateral, "A1" if contralateral == "M1" else "A2", "M1", "M2", "A1", "A2"]
    for target in alternates:
        for original, clean in refs_upper:
            if clean == target:
                return original
    return refs[0] if refs else None


def _dedupe_eeg_channels(eeg_channels: Sequence[str], log: LogFn = log_noop) -> list[str]:
    selected = list(dict.fromkeys(eeg_channels))
    by_root: dict[str, list[str]] = {}
    for channel in selected:
        by_root.setdefault(channel_root(channel), []).append(channel)

    keep: list[str] = []
    dropped: list[str] = []
    for channels in by_root.values():
        prereferenced = [channel for channel in channels if is_prereferenced_channel(channel)]
        chosen = prereferenced if prereferenced else channels
        keep.extend(chosen)
        dropped.extend([channel for channel in channels if channel not in chosen])

    if dropped:
        log(
            "Dropped duplicate unreferenced EEG channel(s) because matching already-referenced "
            f"channels were selected: {', '.join(dropped)}."
        )
    return [channel for channel in selected if channel in set(keep)]


def prepare_raw_for_scoring(
    data_file: str | Path,
    eeg_channels: Sequence[str],
    ref_channels: Sequence[str] | None = None,
    eog_channels: Sequence[str] | None = None,
    emg_channels: Sequence[str] | None = None,
    target_sfreq: float = 100.0,
    notch_hz: float | None = 50.0,
    log: LogFn = log_noop,
) -> tuple[mne.io.BaseRaw, list[str], list[str], str | None, str | None]:
    """Load only selected channels and apply staging-oriented preprocessing."""
    eeg_channels = _dedupe_eeg_channels(eeg_channels, log=log)
    ref_channels = list(ref_channels or [])
    eog_channels = list(eog_channels or [])
    emg_channels = list(emg_channels or [])
    if not eeg_channels:
        raise ValueError("Select at least one EEG channel.")

    raw = read_raw_file(data_file, preload=False)
    keep = list(dict.fromkeys(eeg_channels + ref_channels + eog_channels + emg_channels))
    keep = _pick_existing(raw, keep)
    if not keep:
        raise ValueError("None of the selected channels were found in the data file.")
    log("PROGRESS 0.05 Loading selected channels")
    log(f"Loading {len(keep)} selected channel(s).")
    raw.pick(keep)
    raw.load_data(verbose="ERROR")

    if notch_hz:
        nyquist = raw.info["sfreq"] / 2.0
        if notch_hz < nyquist:
            log(f"Applying {notch_hz:g} Hz notch filter.")
            raw.notch_filter(freqs=notch_hz, notch_widths=2, verbose=False)

    eeg_ref_eog = _pick_existing(raw, eeg_channels + ref_channels + eog_channels)
    if eeg_ref_eog:
        log("PROGRESS 0.12 Filtering EEG, reference, and EOG channels")
        log("Applying 0.3-35 Hz bandpass to EEG/reference/EOG channels.")
        raw.filter(l_freq=0.3, h_freq=35.0, picks=eeg_ref_eog, verbose=False)

    emg_existing = _pick_existing(raw, emg_channels)
    if emg_existing:
        h_freq = 100.0 if raw.info["sfreq"] > 200.0 else None
        log("Applying EMG high-pass filter.")
        raw.filter(l_freq=10.0, h_freq=h_freq, picks=emg_existing, verbose=False)

    if raw.info["sfreq"] != target_sfreq:
        log("PROGRESS 0.18 Resampling recording")
        log(f"Resampling to {target_sfreq:g} Hz.")
        raw.resample(target_sfreq, verbose=False)

    eog_name = None
    if len(eog_channels) >= 2 and all(ch in raw.ch_names for ch in eog_channels[:2]):
        eog_name = _make_pair_name(eog_channels[0], eog_channels[1])
        raw = mne.set_bipolar_reference(
            raw,
            anode=eog_channels[0],
            cathode=eog_channels[1],
            ch_name=eog_name,
            drop_refs=False,
            verbose=False,
        )
    elif len(eog_channels) == 1 and eog_channels[0] in raw.ch_names:
        eog_name = eog_channels[0]

    emg_name = None
    if len(emg_channels) >= 2 and all(ch in raw.ch_names for ch in emg_channels[:2]):
        emg_name = _make_pair_name(emg_channels[0], emg_channels[1])
        raw = mne.set_bipolar_reference(
            raw,
            anode=emg_channels[0],
            cathode=emg_channels[1],
            ch_name=emg_name,
            drop_refs=False,
            verbose=False,
        )
    elif len(emg_channels) == 1 and emg_channels[0] in raw.ch_names:
        emg_name = emg_channels[0]

    return raw, _pick_existing(raw, eeg_channels), _pick_existing(raw, ref_channels), eog_name, emg_name


def _normalize_yasa_probabilities(prob: pd.DataFrame) -> pd.DataFrame:
    prob = prob.rename(columns={"WAKE": "W", "REM": "R"})
    missing = [col for col in STAGE_COLUMNS if col not in prob.columns]
    if missing:
        raise RuntimeError(f"YASA probability output is missing columns: {missing}")
    return prob[STAGE_COLUMNS].copy()


def run_yasa_consensus(
    raw: mne.io.BaseRaw,
    eeg_channels: Sequence[str],
    ref_channels: Sequence[str],
    eog_name: str | None,
    emg_name: str | None,
    log: LogFn = log_noop,
) -> tuple[pd.DataFrame, pd.DataFrame, list[str]]:
    """Score each requested EEG channel and return averaged probabilities."""
    yprobs: list[pd.DataFrame] = []
    per_channel_rows: list[pd.DataFrame] = []
    montages_used: list[str] = []

    total_montages = max(len(eeg_channels), 1)
    for montage_index, eeg in enumerate(eeg_channels, start=1):
        try:
            if ref_channels and not is_prereferenced_channel(eeg):
                ref = _clinical_reference_for(eeg, ref_channels)
                if ref is None:
                    raise ValueError(f"No reference channel available for {eeg}")
                montage_name = _make_pair_name(eeg, ref)
                staged_raw = mne.set_bipolar_reference(
                    raw.copy(),
                    anode=eeg,
                    cathode=ref,
                    ch_name=montage_name,
                    drop_refs=False,
                    verbose=False,
                )
                eeg_for_yasa = montage_name
            else:
                staged_raw = raw
                eeg_for_yasa = eeg
                montage_name = eeg

            progress = 0.24 + 0.58 * ((montage_index - 1) / total_montages)
            log(
                f"PROGRESS {progress:.2f} Running YASA montage "
                f"{montage_index}/{total_montages}: {montage_name}"
            )
            log(f"Running YASA on {montage_name}.")
            sls = yasa.SleepStaging(staged_raw, eeg_name=eeg_for_yasa, eog_name=eog_name, emg_name=emg_name)
            prob = _normalize_yasa_probabilities(sls.predict_proba())
            prob["epoch"] = np.arange(len(prob))
            prob["montage"] = montage_name
            per_channel_rows.append(prob)
            yprobs.append(prob[STAGE_COLUMNS])
            montages_used.append(montage_name)
            progress = 0.24 + 0.58 * (montage_index / total_montages)
            log(
                f"PROGRESS {progress:.2f} Finished YASA montage "
                f"{montage_index}/{total_montages}: {montage_name}"
            )
        except Exception as exc:
            log(f"YASA failed for {eeg}: {exc}")
            log(traceback.format_exc())

    if not yprobs:
        raise RuntimeError("YASA failed on every selected EEG channel.")

    min_epochs = min(len(prob) for prob in yprobs)
    trimmed = [prob.iloc[:min_epochs].reset_index(drop=True) for prob in yprobs]
    consensus = sum(trimmed) / len(trimmed)
    per_channel = pd.concat(per_channel_rows, ignore_index=True)
    return consensus, per_channel, montages_used


def stages_from_probabilities(prob: pd.DataFrame) -> list[str]:
    ypred = np.argmax(prob[STAGE_COLUMNS].to_numpy(), axis=1)
    return [STAGE_BY_INDEX[int(index)] for index in ypred]


def resolve_sleepgpt_paths() -> tuple[Path, Path, Path]:
    if getattr(sys, "frozen", False):
        sleepgpt_dir = Path(sys._MEIPASS) / "sleepgpt-main"
    else:
        workspace_root = Path(__file__).resolve().parents[1]
        sleepgpt_dir = workspace_root / "backend" / "sleepgpt-main"
        if not sleepgpt_dir.exists():
            sleepgpt_dir = workspace_root / "sleepgpt-main"
        if not sleepgpt_dir.exists():
            sleepgpt_dir = workspace_root / "CCS_SleepEEGAnalysis" / "sleepgpt-main"
        if not sleepgpt_dir.exists():
            sleepgpt_dir = workspace_root.parent / "CCS_SleepEEGAnalysis" / "sleepgpt-main"
    checkpoint = sleepgpt_dir / "output" / "gpt_shhs_pretrained" / "90_48_3_6.pth.tar"
    model_file = sleepgpt_dir / "models" / "gpt_transformers.py"
    return sleepgpt_dir, checkpoint, model_file


def _prepare_transformers_env() -> None:
    # 1. Bypass transformers runtime version check (avoids failure when huggingface_hub is vendored)
    if "transformers.dependency_versions_check" not in sys.modules:
        m = types.ModuleType("transformers.dependency_versions_check")
        m.dep_version_check = lambda *args, **kwargs: None
        m.require_version = lambda *args, **kwargs: None
        m.require_version_core = lambda *args, **kwargs: None
        sys.modules["transformers.dependency_versions_check"] = m

    # 2. Prevent torchvision C++ ABI mismatch from breaking vision-checking in transformers
    try:
        import torchvision  # noqa: F401
    except Exception:
        sys.modules["torchvision"] = None
        sys.modules["torchvision.transforms"] = None




def check_sleepgpt_available() -> None:
    """Verify SleepGPT model files, dependencies, and checkpoint loading."""
    sleepgpt_dir, checkpoint, model_file = resolve_sleepgpt_paths()
    if not checkpoint.exists():
        raise RuntimeError(f"SleepGPT checkpoint not found at {checkpoint}")
    if not model_file.exists():
        raise RuntimeError(f"SleepGPT model file not found at {model_file}")

    if str(sleepgpt_dir) not in sys.path:
        sys.path.insert(0, str(sleepgpt_dir))

    _prepare_transformers_env()
    import torch
    import torchutils as utils
    from models.gpt_transformers import GPTLM

    model = GPTLM(vocab_size=6, max_seqlen=90, embed_dim=48, num_layers=3, num_heads=6)
    utils.load_checkpoint(str(checkpoint), model, strict=False)


def run_sleepgpt_correction(
    prob: pd.DataFrame,
    alpha: float = 0.1,
    ngram: int = 30,
    max_runtime_sec: float | None = 180.0,
    log: LogFn = log_noop,
) -> list[str] | None:
    """Apply the local SleepGPT language-model correction if available."""
    sleepgpt_dir, checkpoint, model_file = resolve_sleepgpt_paths()

    if not checkpoint.exists() or not model_file.exists():
        log("SleepGPT files were not found; keeping YASA consensus stages.")
        return None

    if str(sleepgpt_dir) not in sys.path:
        sys.path.insert(0, str(sleepgpt_dir))

    try:
        _prepare_transformers_env()
        import torch
        torch.set_num_threads(1)
        import torch.nn.functional as F
        import torchutils as utils
        from models.gpt_transformers import GPTLM
    except Exception as exc:
        cause = getattr(exc, "__cause__", None)
        detail = f"{exc} (caused by {cause})" if cause else str(exc)
        log(f"Could not import SleepGPT dependencies: {detail}")
        return None

    try:
        device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        if os.getenv("AUTO_SLEEP_USE_MPS") == "1":
            if device.type == "cpu" and hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
                device = torch.device("mps")

        model = GPTLM(vocab_size=6, max_seqlen=90, embed_dim=48, num_layers=3, num_heads=6)
        utils.load_checkpoint(str(checkpoint), model, strict=False)
        model = model.to(device)
        model.eval()

        # Force columns to numeric and fill any missing values to prevent object type errors (e.g. from Luna POPS)
        numeric_df = prob[STAGE_COLUMNS].apply(pd.to_numeric, errors="coerce").fillna(0.0)
        values = numeric_df.to_numpy(dtype=np.float32)
        tensor = torch.tensor(values, dtype=torch.float32, device=device)
        total_epochs = len(tensor)
        min_len = 5
        if total_epochs < min_len:
            log(f"SleepGPT needs at least {min_len} epochs; keeping base scorer stages.")
            return None

        log(
            f"Applying SleepGPT sequence correction to {total_epochs} epochs "
            f"({total_epochs * 30 / 3600:.2f} hours) on {device}."
        )
        start_time = time.perf_counter()
        corrected_tokens = torch.argmax(tensor[:min_len], dim=-1).detach().cpu().numpy().astype(int).tolist()
        with torch.no_grad():
            for index in range(min_len, total_epochs):
                input_ids = torch.tensor([corrected_tokens[-ngram:]], dtype=torch.long, device=device)
                lm_logits = model(input_ids)[0][:, -1, :]
                lm_probs = F.log_softmax(lm_logits, dim=-1).squeeze()
                raw_probs = F.log_softmax(tensor[index, :], dim=-1)
                probs = (1 - alpha) * raw_probs + alpha * lm_probs[: len(raw_probs)]
                next_idx = int(torch.argmax(probs, dim=-1).detach().cpu().item())
                corrected_tokens.append(next_idx)

                done = index + 1
                elapsed = max(time.perf_counter() - start_time, 1e-6)
                if max_runtime_sec is not None and elapsed > max_runtime_sec:
                    log(
                        f"SleepGPT exceeded {max_runtime_sec:.0f}s after {done}/{total_epochs} epochs; "
                        "keeping base scorer stages for this run."
                    )
                    return None
                if done == total_epochs or done <= 10 or done % 10 == 0:
                    epochs_per_sec = done / elapsed
                    remaining = (total_epochs - done) / max(epochs_per_sec, 1e-6)
                    log(
                        f"SleepGPT progress: {done}/{total_epochs} epochs "
                        f"({done / total_epochs:.0%}), elapsed {elapsed:.1f}s, ETA {remaining:.1f}s."
                    )

        elapsed = time.perf_counter() - start_time
        log(f"SleepGPT correction complete in {elapsed:.1f}s.")
        return [STAGE_BY_INDEX[index] for index in corrected_tokens if index in STAGE_BY_INDEX]
    except Exception as exc:
        log(f"SleepGPT correction failed: {exc}")
        log(traceback.format_exc())
        return None


def build_epoch_output(stages: Sequence[str], probabilities: pd.DataFrame | None = None) -> pd.DataFrame:
    output = pd.DataFrame(
        {
            "epoch": np.arange(len(stages), dtype=int),
            "onset_sec": np.arange(len(stages), dtype=int) * 30,
            "duration_sec": 30,
            "stage": list(stages),
        }
    )
    if probabilities is not None:
        probs = probabilities[STAGE_COLUMNS].iloc[: len(stages)].reset_index(drop=True)
        probs = probs.rename(columns={col: f"prob_{col}" for col in STAGE_COLUMNS})
        output = pd.concat([output, probs], axis=1)
    return output


def build_scoringhero_stage_records(
    stages: Sequence[str],
    probabilities: pd.DataFrame | None,
    source: str,
) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    probs = None
    if probabilities is not None:
        probs = probabilities[STAGE_COLUMNS].iloc[: len(stages)].reset_index(drop=True)

    for index, stage in enumerate(stages):
        confidence = None
        if probs is not None and stage in probs.columns:
            value = probs.loc[index, stage]
            if not pd.isna(value):
                confidence = round(float(value), 6)
        probability_payload = None
        if probs is not None:
            probability_payload = {
                col: round(float(probs.loc[index, col]), 6)
                for col in STAGE_COLUMNS
                if not pd.isna(probs.loc[index, col])
            }

        records.append(
            {
                "epoch": index + 1,
                "start": index * 30,
                "end": (index + 1) * 30,
                "stage": SCORINGHERO_STAGE_LABELS.get(stage),
                "digit": SCORINGHERO_STAGE_DIGITS.get(stage),
                "confidence": confidence,
                "probabilities": probability_payload,
                "channels": [],
                "clean": 1,
                "source": source,
            }
        )
    return records


def write_json(path: Path, payload: object) -> None:
    with path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=1)
        handle.write("\n")


def safe_postfix(algorithm: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", algorithm.lower()).strip("_")


def score_file(
    data_file: str | Path,
    output_dir: str | Path,
    algorithm: str,
    eeg_channels: Sequence[str],
    ref_channels: Sequence[str] | None = None,
    eog_channels: Sequence[str] | None = None,
    emg_channels: Sequence[str] | None = None,
    sequence_correction: str = "none",
    sleepgpt_alpha: float = 0.1,
    sleepgpt_ngram: int = 30,
    export_diagnostics: bool = False,
    log: LogFn = log_noop,
) -> ScoreResult:
    """Score one data file and write a ScoringHero-compatible JSON output."""
    requested_algorithm = algorithm.lower().strip()
    sequence_correction = sequence_correction.lower().strip()
    if requested_algorithm.endswith("_sleepgpt"):
        requested_algorithm = requested_algorithm[: -len("_sleepgpt")]
        sequence_correction = "sleepgpt"
    if requested_algorithm == "deepsleepnet_tinysleepnet":
        requested_algorithm = "tinysleepnet"
    if sequence_correction not in {"none", "sleepgpt"}:
        raise ValueError("sequence_correction must be 'none' or 'sleepgpt'.")

    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    data_file = Path(data_file)
    base = data_file.stem

    if __package__:
        from .algorithms import available_algorithms
    else:
        from algorithms import available_algorithms

    algorithms = available_algorithms()
    if requested_algorithm not in algorithms:
        supported = ", ".join(sorted(algorithms))
        raise ValueError(f"Unsupported algorithm '{algorithm}'. Supported algorithms: {supported}")

    base_algorithm = algorithms[requested_algorithm]
    base_algorithm.check_available()
    log(f"Model preflight passed: {requested_algorithm}.")

    raw, eeg, refs, eog_name, emg_name = prepare_raw_for_scoring(
        data_file=data_file,
        eeg_channels=eeg_channels,
        ref_channels=ref_channels,
        eog_channels=eog_channels,
        emg_channels=emg_channels,
        log=log,
    )

    configure = getattr(base_algorithm, "configure", None)
    if callable(configure):
        configure(data_file=data_file, output_dir=output_dir)
    base_start = time.perf_counter()
    log(f"PROGRESS 0.22 Running {requested_algorithm}")
    consensus_prob, per_channel_prob, montages_used = base_algorithm.score(raw, eeg, refs, eog_name, emg_name, log=log)
    base_elapsed = time.perf_counter() - base_start
    log(
        f"Base scorer complete: {requested_algorithm} produced {len(consensus_prob)} epochs "
        f"from {len(montages_used)} montage(s) in {base_elapsed:.1f}s."
    )

    stages = stages_from_probabilities(consensus_prob)
    stage_algorithm = requested_algorithm
    if sequence_correction == "sleepgpt":
        log("PROGRESS 0.86 Applying SleepGPT sequence correction")
        corrected = run_sleepgpt_correction(consensus_prob, alpha=sleepgpt_alpha, ngram=sleepgpt_ngram, log=log)
        if corrected:
            stages = corrected[: len(stages)]
            stage_algorithm = f"{requested_algorithm}_sleepgpt"
        else:
            log(
                "SleepGPT correction was unavailable; saved the unchanged "
                f"{requested_algorithm} consensus scoring."
            )

    postfix = safe_postfix(stage_algorithm)
    output_json = output_dir / f"{base}_{postfix}_scoring.json"
    probability_json = None
    per_channel_json = None

    stage_records = build_scoringhero_stage_records(stages, consensus_prob, source=stage_algorithm)
    write_json(output_json, [stage_records, []])
    if export_diagnostics:
        diagnostics_dir = output_dir / f"{base}_{safe_postfix(requested_algorithm)}_diagnostics"
        diagnostics_dir.mkdir(parents=True, exist_ok=True)
        probability_json = diagnostics_dir / "consensus_probabilities.json"
        per_channel_json = diagnostics_dir / "per_montage_probabilities.json"
        write_json(probability_json, consensus_prob.to_dict(orient="records"))
        write_json(per_channel_json, per_channel_prob.to_dict(orient="records"))
        log(f"Saved diagnostic probabilities: {diagnostics_dir}")
    log("PROGRESS 1.00 Scoring complete")
    log(f"Saved ScoringHero JSON: {output_json}")

    return ScoreResult(
        algorithm=stage_algorithm,
        output_json=output_json,
        probability_json=probability_json,
        per_channel_json=per_channel_json,
        stages=list(stages),
        montages_used=montages_used,
    )
