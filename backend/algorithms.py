"""Algorithm adapters for automated sleep staging.

Adapters expose a shared interface:

    score(raw, eeg_channels, ref_channels, eog_name, emg_name, log)

and return consensus probabilities, per-channel probabilities, and the montage
names used. SleepGPT is intentionally not an adapter here; it is applied after
the selected base algorithm as the final sequence-correction stage.
"""

from __future__ import annotations

import os
import sys

if __package__:
    from .runtime_bootstrap import configure_runtime
else:
    from runtime_bootstrap import configure_runtime

configure_runtime()

import importlib.util
import shutil
import warnings
from abc import ABC, abstractmethod
from pathlib import Path
from typing import Sequence

warnings.filterwarnings("ignore", message="DataFrame is highly fragmented")
warnings.filterwarnings("ignore", message="Using padding='same'")
try:
    import pandas as pd
    warnings.filterwarnings("ignore", category=pd.errors.PerformanceWarning)
except Exception:
    pass



if __package__:
    from .scorer import (
        STAGE_COLUMNS,
        LogFn,
        log_noop,
        _clinical_reference_for,
        _make_pair_name,
        _normalize_yasa_probabilities,
        is_prereferenced_channel,
    )
else:
    from scorer import (
        STAGE_COLUMNS,
        LogFn,
        log_noop,
        _clinical_reference_for,
        _make_pair_name,
        _normalize_yasa_probabilities,
        is_prereferenced_channel,
    )


import mne
import numpy as np
import pandas as pd



warnings.filterwarnings("ignore", message="pkg_resources is deprecated as an API.*", category=UserWarning)


class AlgorithmUnavailable(RuntimeError):
    """Raised when an adapter is present but cannot run in this environment."""


class SleepScoringAlgorithm(ABC):
    key: str
    label: str
    description: str

    @abstractmethod
    def score(
        self,
        raw: mne.io.BaseRaw,
        eeg_channels: Sequence[str],
        ref_channels: Sequence[str],
        eog_name: str | None,
        emg_name: str | None,
        log: LogFn,
    ) -> tuple[pd.DataFrame, pd.DataFrame, list[str]]:
        """Return consensus probabilities, per-channel probabilities, montages."""

    def check_available(self) -> None:
        """Raise AlgorithmUnavailable when the packaged runtime is incomplete."""


def _stage_series_to_probabilities(stages: Sequence[str]) -> pd.DataFrame:
    normalized = []
    for stage in stages:
        label = str(stage).strip().upper()
        label = {"WAKE": "W", "REM": "R", "NREM1": "N1", "NREM2": "N2", "NREM3": "N3"}.get(label, label)
        normalized.append(label if label in STAGE_COLUMNS else "W")
    prob = pd.DataFrame(0.0, index=np.arange(len(normalized)), columns=STAGE_COLUMNS)
    for idx, stage in enumerate(normalized):
        prob.loc[idx, stage] = 1.0
    return prob


def _consensus_from_channel_probs(
    channel_probs: list[tuple[str, pd.DataFrame]],
    label: str,
) -> tuple[pd.DataFrame, pd.DataFrame, list[str]]:
    if not channel_probs:
        raise RuntimeError(f"{label} failed on every selected channel.")
    min_epochs = min(len(prob) for _, prob in channel_probs)
    trimmed = [prob.iloc[:min_epochs].reset_index(drop=True) for _, prob in channel_probs]
    consensus = sum(trimmed) / len(trimmed)
    rows = []
    for montage, prob in channel_probs:
        table = prob.iloc[:min_epochs].copy()
        table["epoch"] = np.arange(min_epochs)
        table["montage"] = montage
        rows.append(table)
    return consensus, pd.concat(rows, ignore_index=True), [name for name, _ in channel_probs]


class YasaAlgorithm(SleepScoringAlgorithm):
    key = "yasa"
    label = "YASA / SleepEEGpy-compatible LightGBM"
    description = "Open-source YASA feature extraction with LightGBM staging."

    def check_available(self) -> None:
        import yasa  # noqa: F401

    def score(self, raw, eeg_channels, ref_channels, eog_name, emg_name, log):
        import yasa

        yprobs: list[pd.DataFrame] = []
        per_channel_rows: list[pd.DataFrame] = []
        montages_used: list[str] = []

        for eeg_index, eeg in enumerate(eeg_channels):
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

                log(f"Running YASA on {montage_name}.")
                sls = yasa.SleepStaging(staged_raw, eeg_name=eeg_for_yasa, eog_name=eog_name, emg_name=emg_name)
                prob = _normalize_yasa_probabilities(sls.predict_proba())
                prob["epoch"] = np.arange(len(prob))
                prob["montage"] = montage_name
                per_channel_rows.append(prob)
                yprobs.append(prob[STAGE_COLUMNS])
                montages_used.append(montage_name)
                log(
                    f"PROGRESS {0.22 + 0.63 * ((eeg_index + 1) / len(eeg_channels)):.3f} "
                    f"YASA channel {eeg_index + 1} of {len(eeg_channels)} complete"
                )
            except Exception as exc:
                log(f"YASA failed for {eeg}: {exc}")

        if not yprobs:
            raise RuntimeError("YASA failed on every selected EEG channel.")

        min_epochs = min(len(prob) for prob in yprobs)
        trimmed = [prob.iloc[:min_epochs].reset_index(drop=True) for prob in yprobs]
        consensus = sum(trimmed) / len(trimmed)
        per_channel = pd.concat(per_channel_rows, ignore_index=True)
        return consensus, per_channel, montages_used


class LocalTorchEpochAlgorithm(SleepScoringAlgorithm):
    model_name: str
    checkpoint: Path | None = None

    def _sleepgpt_dir(self) -> Path:
        if getattr(sys, "frozen", False):
            return Path(sys._MEIPASS) / "sleepgpt-main"
        workspace_root = Path(__file__).resolve().parents[1]
        sleepgpt_dir = workspace_root / "sleepgpt-main"
        if not sleepgpt_dir.exists():
            sleepgpt_dir = workspace_root / "CCS_SleepEEGAnalysis" / "sleepgpt-main"
        if not sleepgpt_dir.exists():
            sleepgpt_dir = workspace_root.parent / "CCS_SleepEEGAnalysis" / "sleepgpt-main"
        return sleepgpt_dir

    def _device(self):
        import torch
        torch.set_num_threads(1)

        return torch.device("cuda" if torch.cuda.is_available() else "cpu")

    def _epoch_tensor(self, raw: mne.io.BaseRaw, channel: str):
        import torch

        sfreq = float(raw.info["sfreq"])
        samples_per_epoch = int(round(sfreq * 30))
        data = raw.get_data(picks=[channel])[0]
        n_epochs = len(data) // samples_per_epoch
        if n_epochs <= 0:
            raise ValueError("Recording is shorter than one 30-second epoch.")
        data = data[: n_epochs * samples_per_epoch].reshape(n_epochs, samples_per_epoch)
        if samples_per_epoch != 3000:
            raise ValueError(f"{self.key} expects 100 Hz data with 3000 samples per epoch.")

        data = data * 1e6
        mean = data.mean(axis=1, keepdims=True)
        std = data.std(axis=1, keepdims=True)
        data = (data - mean) / np.maximum(std, 1e-6)
        return torch.tensor(data[:, None, :, None], dtype=torch.float32)

    def _load_state_dict(self, model, checkpoint: Path):
        import torch

        if not checkpoint.exists():
            raise AlgorithmUnavailable(f"{self.label} checkpoint not found: {checkpoint}")
        state = torch.load(checkpoint, map_location="cpu")
        if isinstance(state, dict) and "state_dict" in state:
            state = state["state_dict"]
        model.load_state_dict(state, strict=True)

    def _score_tensor_model(self, model, epochs, batch_size: int = 128, log: LogFn = log_noop) -> pd.DataFrame:
        import torch

        device = self._device()
        model = model.to(device)
        model.eval()
        rows = []
        total = len(epochs)
        with torch.no_grad():
            for start in range(0, total, batch_size):
                logits = model(epochs[start : start + batch_size].to(device))
                rows.append(torch.softmax(logits, dim=1).detach().cpu().numpy())
                
                done = min(start + batch_size, total)
                if done == total or (done // batch_size) % 5 == 0:
                    log(f"  {self.label} progress: {done}/{total} epochs ({done/total:.0%})")
                    
        return pd.DataFrame(np.vstack(rows), columns=STAGE_COLUMNS)


    def _consensus_from_channel_probs(
        self,
        channel_probs: list[tuple[str, pd.DataFrame]],
    ) -> tuple[pd.DataFrame, pd.DataFrame, list[str]]:
        return _consensus_from_channel_probs(channel_probs, self.label)


class PhysioExSequenceAlgorithm(LocalTorchEpochAlgorithm):
    physioex_model: str
    preprocessing: str
    sequence_length = 21

    def check_available(self) -> None:
        self._ensure_physioex()
        checkpoint_dir = Path(__file__).resolve().parent / "vendor" / "physioex" / "train" / "models" / "checkpoints"
        if not checkpoint_dir.exists():
            try:
                import physioex
                checkpoint_dir = Path(physioex.__file__).resolve().parent / "train" / "models" / "checkpoints"
            except Exception:
                pass
        if not checkpoint_dir.exists() or not any(checkpoint_dir.glob("*.ckpt")):
            raise AlgorithmUnavailable(f"PhysioEx checkpoints are missing from {checkpoint_dir}.")

    def _ensure_physioex(self):
        try:
            from physioex.train.models import load_model
        except Exception as exc:
            raise AlgorithmUnavailable(
                "PhysioEx could not initialize for this pretrained adapter: "
                f"{type(exc).__name__}: {exc}"
            ) from exc
        return load_model

    def _raw_epochs(self, raw: mne.io.BaseRaw, channel: str) -> np.ndarray:
        sfreq = float(raw.info["sfreq"])
        samples_per_epoch = int(round(sfreq * 30))
        data = raw.get_data(picks=[channel])[0]
        n_epochs = len(data) // samples_per_epoch
        data = data[: n_epochs * samples_per_epoch].reshape(n_epochs, samples_per_epoch)
        data = data * 1e6
        data = (data - data.mean(axis=1, keepdims=True)) / np.maximum(data.std(axis=1, keepdims=True), 1e-6)
        return data.astype(np.float32)

    def _xsleepnet_epochs(self, raw_epochs: np.ndarray) -> np.ndarray:
        from physioex.preprocess.utils.signal import xsleepnet_preprocessing

        signals = raw_epochs[:, None, :]
        specs = xsleepnet_preprocessing(signals, (1, 29, 129), fs=100)
        specs = (specs - specs.mean(axis=(0, 2, 3), keepdims=True)) / np.maximum(
            specs.std(axis=(0, 2, 3), keepdims=True),
            1e-6,
        )
        return specs.astype(np.float32)

    def _windows(self, epochs: np.ndarray) -> np.ndarray:
        half = self.sequence_length // 2
        left = np.repeat(epochs[:1], half, axis=0)
        right = np.repeat(epochs[-1:], half, axis=0)
        padded = np.concatenate([left, epochs, right], axis=0)
        return np.stack([padded[i : i + self.sequence_length] for i in range(len(epochs))], axis=0)

    def _load_physioex_model(self):
        import torch

        load_model = self._ensure_physioex()
        device = self._device()
        return load_model(
            self.physioex_model,
            model_kwargs={"sequence_length": self.sequence_length, "in_channels": 1},
            device=device,
            softmax=False,
            summary=False,
        ).to(device).eval()

    def _score_windows(self, model, windows: np.ndarray, log: LogFn = log_noop) -> pd.DataFrame:
        import torch

        device = self._device()
        rows = []
        center = self.sequence_length // 2
        total = len(windows)
        with torch.no_grad():
            for start in range(0, total, 32):
                batch = torch.tensor(windows[start : start + 32], dtype=torch.float32, device=device)
                logits = model(batch)
                probs = torch.softmax(logits[:, center, :], dim=1).detach().cpu().numpy()
                rows.append(probs)
                
                done = min(start + 32, total)
                if done == total or (done // 32) % 10 == 0:
                    log(f"  {self.label} progress: {done}/{total} epochs ({done/total:.0%})")
                    
        return pd.DataFrame(np.vstack(rows), columns=STAGE_COLUMNS)

    def score(self, raw, eeg_channels, ref_channels, eog_name, emg_name, log):
        del ref_channels, eog_name, emg_name
        model = self._load_physioex_model()
        channel_probs = []
        for channel in eeg_channels:
            log(f"Running {self.label} on {channel}.")
            raw_epochs = self._raw_epochs(raw, channel)
            if self.preprocessing == "raw":
                features = raw_epochs[:, None, :]
            elif self.preprocessing == "xsleepnet":
                features = self._xsleepnet_epochs(raw_epochs)
            else:
                raise ValueError(f"Unknown PhysioEx preprocessing mode: {self.preprocessing}")
            windows = self._windows(features)
            channel_probs.append((channel, self._score_windows(model, windows, log=log)))
        return self._consensus_from_channel_probs(channel_probs)



class TinySleepNetAlgorithm(PhysioExSequenceAlgorithm):
    key = "tinysleepnet"
    label = "TinySleepNet"
    description = "PhysioEx pretrained TinySleepNet checkpoint."
    physioex_model = "tinysleepnet"
    preprocessing = "raw"


class GsscAlgorithm(SleepScoringAlgorithm):
    key = "gssc"
    label = "Greifswald Sleep Stage Classifier (GSSC)"
    description = "Automatic sleep stage classifier using GSSC neural networks."

    def check_available(self) -> None:
        from importlib.resources import files
        import gssc  # noqa: F401

        for name in ("sig_net_v1.pt", "gru_net_v1.pt"):
            if not Path(files("gssc.nets").joinpath(name)).exists():
                raise AlgorithmUnavailable(f"GSSC model asset is missing: {name}")

    def score(self, raw, eeg_channels, ref_channels, eog_name, emg_name, log):
        del emg_name
        try:
            import torch
            import torch.nn as nn
            from importlib.resources import files
            from gssc.infer import EEGInfer
            from gssc.utils import prepare_inst, permute_sigs, epo_arr_zscore, loudest_vote
        except ImportError as exc:
            raise AlgorithmUnavailable(
                "GSSC dependencies are missing. Install them with `pip install gssc`."
            ) from exc

        # Set up referenced EEG channels
        staged_raw = raw.copy()
        gssc_eeg_chans = []
        for eeg in eeg_channels:
            if ref_channels and not is_prereferenced_channel(eeg):
                ref = _clinical_reference_for(eeg, ref_channels)
                if ref is None:
                    raise ValueError(f"No reference channel available for {eeg}")
                montage_name = _make_pair_name(eeg, ref)
                staged_raw = mne.set_bipolar_reference(
                    staged_raw,
                    anode=eeg,
                    cathode=ref,
                    ch_name=montage_name,
                    drop_refs=False,
                    verbose=False,
                )
                staged_raw.set_channel_types({montage_name: "eeg"})
                gssc_eeg_chans.append(montage_name)
            else:
                gssc_eeg_chans.append(eeg)

        gssc_eog_chans = [eog_name] if eog_name and eog_name in staged_raw.ch_names else []

        log(f"Running GSSC on EEG channels: {gssc_eeg_chans}, EOG channels: {gssc_eog_chans}")

        # Manually load the models with weights_only=False to support PyTorch 2.6+
        try:
            try:
                net_name = files('gssc.nets').joinpath("sig_net_v1.pt")
                con_net_name = files('gssc.nets').joinpath("gru_net_v1.pt")
                if not Path(net_name).exists():
                    raise FileNotFoundError()
            except Exception:
                meipass = getattr(sys, "_MEIPASS", None)
                if meipass:
                    net_name = Path(meipass) / "gssc" / "nets" / "sig_net_v1.pt"
                    con_net_name = Path(meipass) / "gssc" / "nets" / "gru_net_v1.pt"
                else:
                    raise
            net = torch.load(net_name, weights_only=False)
            con_net = torch.load(con_net_name, weights_only=False)
        except Exception as exc:
            raise RuntimeError(f"Failed to load GSSC pre-trained models: {exc}") from exc

        # Force CPU / single-thread settings to avoid deadlocks
        torch.set_num_threads(1)
        device = torch.device("cpu") # Keep GSSC on CPU to avoid macOS MPS conflicts/deadlocks with YASA/lightgbm
        
        net = net.to(device).eval()
        con_net = con_net.to(device).eval()

        # Replicate mne_infer with consensus probabilities extraction
        sig_len = 2560
        cut = "back"

        # Filter raw data to 0.3 - 30 Hz
        filter_band = [None, None]
        if round(staged_raw.info["highpass"], 2) < 0.3:
            filter_band[0] = 0.3
        if round(staged_raw.info["lowpass"], 2) > 30.0:
            filter_band[1] = 30.0
        if filter_band[0] is not None or filter_band[1] is not None:
            log(f"Filtering staged raw data for GSSC: {filter_band[0]} - {filter_band[1]} Hz")
            staged_raw.filter(*filter_band, verbose=False)

        signals = {
            "eeg": {"chans": gssc_eeg_chans, "drop": True, "flip": False},
            "eog": {"chans": gssc_eog_chans, "drop": True, "flip": False}
        }

        epo, start_time = prepare_inst(staged_raw, sig_len, cut)
        sig_combs, perm_matrix, all_chans, _ = permute_sigs(epo, signals)
        data = epo.get_data(picks=all_chans) * 1e6
        data = epo_arr_zscore(data)

        all_sigs = {}
        for perm_idx in range(len(perm_matrix)):
            these_chans = {"eeg": None, "eog": None}
            perm = perm_matrix[perm_idx,]
            sigs = {}
            for sig_idx, (sig_name, chans) in enumerate(sig_combs.items()):
                if not len(chans[perm[sig_idx]]):
                    continue
                chan = chans[perm[sig_idx]][0]
                from gssc.utils import check_flip_chan
                ch, coef = check_flip_chan(chan)
                all_chans_idx = all_chans.index(ch)
                signal = coef * data[:, all_chans_idx, :]
                sigs[sig_name] = torch.tensor(signal, dtype=torch.float32)
                these_chans[sig_name] = chan
            perm_str = "eeg: {}, eog: {}".format(*these_chans.values())
            all_sigs[perm_str] = sigs

        logits = []
        perm_names = []
        log("PROGRESS 0.45 Running GSSC signal encoder")
        for sig_idx, (perm_str, sigs) in enumerate(all_sigs.items()):
            perm_names.append(perm_str)
            for k in sigs.keys():
                sigs[k] = sigs[k].reshape(-1, 1, sigs[k].shape[-1])
                sigs[k] = torch.FloatTensor(sigs[k][..., :sig_len])
            
            with torch.no_grad():
                hypno_len = len(sigs[list(sigs.keys())[0]])
                all_reps = []
                for start in range(0, hypno_len, hypno_len): # run all at once since chunk_n=0
                    these_sigs = {}
                    for k in sigs.keys():
                        these_sigs[k] = sigs[k][start : start + hypno_len].to(device)
                    reps = net(these_sigs, rep_output="rep_only")
                    reps = reps.swapaxes(-1, 1)
                    all_reps.append(reps)
                reps = torch.cat(all_reps)

                hidden = torch.zeros(10, 1, 256, device=device)
                y, hidden = con_net(reps, hidden)
                del reps
                y = y.float()
                logits.append(y[:, 0, :].cpu().numpy())
            log(
                f"PROGRESS {0.45 + 0.38 * ((sig_idx + 1) / len(all_sigs)):.3f} "
                f"GSSC montage {sig_idx + 1} of {len(all_sigs)} complete"
            )

        # loudest_vote to find the best permutation and its logits
        logits_arr = np.array(logits) # shape (P, E, 5)
        
        # We compute the consensus by finding the permutation with minimal entropy per epoch
        loss_func = nn.NLLLoss(reduction="none")
        logits_tensor = torch.FloatTensor(logits_arr)
        entrs = torch.zeros((logits_tensor.shape[0], logits_tensor.shape[1])) # (P, E)
        for idx in range(len(logits_tensor)):
            targs = torch.LongTensor(np.argmax(logits_arr[idx], axis=-1))
            entrs[idx] = loss_func(logits_tensor[idx], targs)
        
        min_inds = np.argmin(entrs.numpy(), axis=0) # shape (E,)
        min_logits = logits_tensor[min_inds, np.arange(logits_tensor.shape[1])] # shape (E, 5)
        
        # Softmax to get probabilities
        consensus_probs_tensor = torch.softmax(min_logits, dim=-1)
        consensus_df = pd.DataFrame(consensus_probs_tensor.numpy(), columns=STAGE_COLUMNS)

        # Build per-channel probabilities (representing each permutation)
        per_channel_rows = []
        for idx, perm_str in enumerate(perm_names):
            perm_logits = torch.FloatTensor(logits_arr[idx])
            perm_probs = torch.softmax(perm_logits, dim=-1).numpy()
            df = pd.DataFrame(perm_probs, columns=STAGE_COLUMNS)
            df["epoch"] = np.arange(len(df))
            df["montage"] = perm_str
            per_channel_rows.append(df)
        
        per_channel_df = pd.concat(per_channel_rows, ignore_index=True)

        return consensus_df, per_channel_df, perm_names




class SeqSleepNetAlgorithm(PhysioExSequenceAlgorithm):
    key = "seqsleepnet"
    label = "SeqSleepNet"
    description = "PhysioEx pretrained SeqSleepNet checkpoint."
    physioex_model = "seqsleepnet"
    preprocessing = "xsleepnet"

    def score(self, raw, eeg_channels, ref_channels, eog_name, emg_name, log):
        return PhysioExSequenceAlgorithm.score(self, raw, eeg_channels, ref_channels, eog_name, emg_name, log)


class SleepTransformerAlgorithm(PhysioExSequenceAlgorithm):
    key = "sleeptransformer"
    label = "SleepTransformer"
    description = "PhysioEx pretrained SleepTransformer checkpoint."
    physioex_model = "sleeptransformer"
    preprocessing = "xsleepnet"


class UnavailablePackageAlgorithm(SleepScoringAlgorithm):
    package_name: str
    install_hint: str

    def score(self, raw, eeg_channels, ref_channels, eog_name, emg_name, log):
        del raw, eeg_channels, ref_channels, eog_name, emg_name, log
        if importlib.util.find_spec(self.package_name) is None:
            raise AlgorithmUnavailable(self.install_hint)
        raise AlgorithmUnavailable(
            f"{self.label} package is importable, but its project-specific inference API is not wired here yet. "
            "Add the package's pretrained model path and inference call in automated_sleep_scoring/algorithms.py."
        )


class USleepAlgorithm(SleepScoringAlgorithm):
    key = "usleep"
    label = "U-Sleep"
    description = "Offline Braindecode U-Sleep checkpoint with optional official web API fallback."

    def check_available(self) -> None:
        import braindecode  # noqa: F401
        import safetensors  # noqa: F401

        checkpoint = self._local_checkpoint()
        if not checkpoint.exists():
            raise AlgorithmUnavailable(f"Offline U-Sleep checkpoint not found: {checkpoint}")

    def configure(self, data_file: Path, output_dir: Path) -> None:
        self.data_file = Path(data_file)
        self.output_dir = Path(output_dir)

    def _device(self):
        import torch
        torch.set_num_threads(1)

        device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        if os.getenv("AUTO_SLEEP_USE_MPS") == "1":
            if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
                return torch.device("mps")
        return device


    def _local_checkpoint(self) -> Path:
        return Path(__file__).resolve().parent / "models" / "usleep_braindecode" / "params.safetensors"

    def _load_local_model(self):
        import torch
        from braindecode.models import USleep
        from safetensors.torch import load_file

        checkpoint = self._local_checkpoint()
        if not checkpoint.exists():
            raise AlgorithmUnavailable(
                "Offline U-Sleep checkpoint not found. Expected "
                f"{checkpoint}. Download braindecode/plot_sleep_staging_usleep params.safetensors into that folder."
            )
        model = USleep(n_chans=2, sfreq=100, n_times=3000, depth=12, n_outputs=5)
        state = load_file(str(checkpoint))
        model.load_state_dict(state, strict=True)
        device = self._device()
        model = model.to(device)
        model.eval()
        return model, device

    def _normalized_channel(self, raw: mne.io.BaseRaw, channel: str) -> np.ndarray:
        data = raw.get_data(picks=[channel])[0] * 1e6
        median = np.median(data)
        q1, q3 = np.percentile(data, [25, 75])
        iqr = max(float(q3 - q1), 1e-6)
        return ((data - median) / iqr).astype(np.float32)

    def _window_pairs(self, raw: mne.io.BaseRaw, eeg: str, second_channel: str | None) -> np.ndarray:
        sfreq = float(raw.info["sfreq"])
        samples_per_epoch = int(round(sfreq * 30))
        if samples_per_epoch != 3000:
            raise AlgorithmUnavailable("Offline U-Sleep expects the prepared data to be 100 Hz.")

        eeg_data = self._normalized_channel(raw, eeg)
        if second_channel:
            second_data = self._normalized_channel(raw, second_channel)
            montage_name = f"{eeg}+{second_channel}"
        else:
            second_data = eeg_data
            montage_name = f"{eeg}+{eeg}"
        del montage_name

        n_epochs = min(len(eeg_data), len(second_data)) // samples_per_epoch
        if n_epochs <= 0:
            raise ValueError("Recording is shorter than one 30-second epoch.")
        stacked = np.stack([eeg_data[: n_epochs * samples_per_epoch], second_data[: n_epochs * samples_per_epoch]], axis=0)
        return stacked.reshape(2, n_epochs, samples_per_epoch).transpose(1, 0, 2)

    def _sequence_tensor(self, windows: np.ndarray, sequence_length: int = 3):
        import torch

        half = sequence_length // 2
        left = np.repeat(windows[:1], half, axis=0)
        right = np.repeat(windows[-1:], half, axis=0)
        padded = np.concatenate([left, windows, right], axis=0)
        sequences = np.stack([padded[i : i + sequence_length] for i in range(len(windows))], axis=0)
        return torch.tensor(sequences, dtype=torch.float32)

    def _score_local(self, raw, eeg_channels, eog_name, log):
        import torch

        model, device = self._load_local_model()
        channel_probs: list[tuple[str, pd.DataFrame]] = []
        for eeg in eeg_channels:
            try:
                second_channel = eog_name if eog_name in raw.ch_names else None
                montage = f"{eeg}+{second_channel}" if second_channel else f"{eeg}+{eeg}"
                log(f"Running offline U-Sleep on {montage}.")
                sequences = self._sequence_tensor(self._window_pairs(raw, eeg, second_channel))
                rows = []
                with torch.no_grad():
                    for start in range(0, len(sequences), 32):
                        logits = model(sequences[start : start + 32].to(device))
                        if logits.ndim != 3:
                            raise RuntimeError(f"Unexpected U-Sleep output shape: {tuple(logits.shape)}")
                        probs = torch.softmax(logits[:, :, logits.shape[-1] // 2], dim=1)
                        rows.append(probs.detach().cpu().numpy())
                        done = min(start + 32, len(sequences))
                        if done == len(sequences) or (done // 32) % 10 == 0:
                            log(f"  U-Sleep progress: {done}/{len(sequences)} epochs ({done/len(sequences):.0%})")
                prob = pd.DataFrame(np.vstack(rows), columns=STAGE_COLUMNS)
                channel_probs.append((montage, prob))
            except Exception as exc:
                log(f"Offline U-Sleep failed for {eeg}: {exc}")

        return _consensus_from_channel_probs(channel_probs, "Offline U-Sleep")

    def _score_web_api(self, eeg_channels, eog_name, log):
        if self.data_file.suffix.lower() != ".edf":
            raise AlgorithmUnavailable("U-Sleep web API only accepts EDF input files.")
        token = os.getenv("USLEEP_API_TOKEN")
        if not token:
            raise AlgorithmUnavailable("Set USLEEP_API_TOKEN to use the optional U-Sleep web API fallback.")
        try:
            from usleep_api import USleepAPI
        except Exception as exc:
            raise AlgorithmUnavailable("The usleep-api package is not importable from vendor.") from exc

        channel_groups = []
        for eeg_index, eeg in enumerate(eeg_channels):
            group = [eeg]
            if eog_name:
                group.append(eog_name)
            channel_groups.append(group)

        out_npy = self.output_dir / f"{self.data_file.stem}_usleep_raw.npy"
        log(f"Uploading EDF to U-Sleep API with {len(channel_groups)} channel group(s).")
        api = USleepAPI(api_token=token)
        api.quick_predict(
            input_file_path=str(self.data_file),
            output_file_path=str(out_npy),
            anonymize_before_upload=True,
            data_per_prediction=128 * 30,
            channel_groups=channel_groups or None,
            with_confidence_scores=True,
            stream_log=False,
        )
        raw_hyp = np.load(out_npy)
        if raw_hyp.ndim == 2 and raw_hyp.shape[1] >= 5:
            consensus = pd.DataFrame(raw_hyp[:, :5], columns=STAGE_COLUMNS)
        else:
            stages = [STAGE_COLUMNS[int(x)] if int(x) < len(STAGE_COLUMNS) else "W" for x in raw_hyp.reshape(-1)]
            consensus = _stage_series_to_probabilities(stages)
        per_channel = consensus.copy()
        per_channel["epoch"] = np.arange(len(consensus))
        per_channel["montage"] = "U-Sleep API consensus"
        return consensus, per_channel, ["U-Sleep API"]

    def score(self, raw, eeg_channels, ref_channels, eog_name, emg_name, log):
        del ref_channels, emg_name
        try:
            return self._score_local(raw, eeg_channels, eog_name, log)
        except AlgorithmUnavailable:
            raise
        except Exception as exc:
            if os.getenv("USLEEP_API_TOKEN"):
                log(f"Offline U-Sleep failed ({exc}); falling back to U-Sleep web API.")
                return self._score_web_api(eeg_channels, eog_name, log)
            raise


class DreamentoAlgorithm(YasaAlgorithm):
    key = "dreamento"
    label = "Dreamento"
    description = "Dreamento-style autoscoring path using its validated YASA-based offline staging approach."


class SleepEEGpyAlgorithm(YasaAlgorithm):
    key = "sleepeegpy"
    label = "SleepEEGpy"
    description = "SleepEEGpy-style wrapper path using the same MNE/YASA staging core."


class LunaAlgorithm(SleepScoringAlgorithm):
    key = "luna"
    label = "Luna"
    description = "External Luna CLI adapter; requires luna on PATH and a staging model/script."

    def check_available(self) -> None:
        import lunapi  # noqa: F401

        pops_path = Path(__file__).resolve().parent / "models" / "pops"
        if not pops_path.exists():
            raise AlgorithmUnavailable(f"Luna POPS resources not found at {pops_path}.")

    def configure(self, data_file: Path, output_dir: Path) -> None:
        self.data_file = Path(data_file)
        self.output_dir = Path(output_dir)

    def score(self, raw, eeg_channels, ref_channels, eog_name, emg_name, log):
        del raw, eog_name, emg_name
        if self.data_file.suffix.lower() != ".edf":
            raise AlgorithmUnavailable("Luna POPS currently requires EDF input.")
        try:
            import lunapi as lp
        except Exception as exc:
            raise AlgorithmUnavailable("lunapi is not importable from automated_sleep_scoring/vendor.") from exc

        pops_path = Path(__file__).resolve().parent / "models" / "pops"
        if not pops_path.exists():
            raise AlgorithmUnavailable(f"Luna POPS resources not found at {pops_path}.")

        channel_probs = []
        for eeg_index, eeg in enumerate(eeg_channels):
            ref = _clinical_reference_for(eeg, ref_channels) if ref_channels and not is_prereferenced_channel(eeg) else None
            log(f"Running Luna POPS on {eeg}{('-' + ref) if ref else ''}.")
            safe_eeg_file_str = eeg.replace(":", "_")
            sample_list = self.output_dir / f".luna_{self.data_file.stem}_{safe_eeg_file_str}.lst"
            sample_list.write_text(f"record\t{self.data_file}\t.\n")
            
            project = lp.proj(verbose=False)
            project.sample_list(str(sample_list))
            inst = project.inst(1)
            
            luna_eeg = eeg
            if ":" in eeg:
                luna_eeg = eeg.replace(":", "_")
                inst.proc(f"RENAME sig={eeg} new={luna_eeg}")
                
            luna_ref = ref
            if ref and ":" in ref:
                luna_ref = ref.replace(":", "_")
                inst.proc(f"RENAME sig={ref} new={luna_ref}")
                
            command = f'RUN-POPS sig={luna_eeg} path={pops_path} args="force-prefix ignore-obs-staging"'
            if ref:
                command = f'RUN-POPS sig={luna_eeg} ref={luna_ref} path={pops_path} args="force-prefix ignore-obs-staging"'
                
            inst.proc(command)
            table = inst.table("RUN_POPS", "E")
            prob = self._parse_luna_pops_table(table)
            channel_probs.append((_make_pair_name(eeg, ref) if ref else eeg, prob))
            log(
                f"PROGRESS {0.22 + 0.63 * ((eeg_index + 1) / len(eeg_channels)):.3f} "
                f"Luna channel {eeg_index + 1} of {len(eeg_channels)} complete"
            )
        return _consensus_from_channel_probs(channel_probs, self.label)


    def _parse_luna_pops_table(self, table: pd.DataFrame) -> pd.DataFrame:
        table = table.copy()
        probability_aliases = {
            "W": ["pW", "PW", "PP_W", "P_W"],
            "N1": ["pN1", "PN1", "PP_N1", "P_N1"],
            "N2": ["pN2", "PN2", "PP_N2", "P_N2"],
            "N3": ["pN3", "PN3", "PP_N3", "P_N3"],
            "R": ["pR", "PR", "PP_R", "P_R"],
        }
        cols = {}
        for stage, aliases in probability_aliases.items():
            for alias in aliases:
                if alias in table.columns:
                    cols[stage] = alias
                    break
        if len(cols) == 5:
            return table[[cols[stage] for stage in STAGE_COLUMNS]].rename(
                columns={cols[stage]: stage for stage in STAGE_COLUMNS}
            )
        for stage_col in ("STAGE", "Stage", "stage", "SS", "PRED", "pred"):
            if stage_col in table.columns:
                return _stage_series_to_probabilities(table[stage_col].tolist())
        raise AlgorithmUnavailable(f"Could not parse Luna POPS output columns: {list(table.columns)}")


def available_algorithms() -> dict[str, SleepScoringAlgorithm]:
    algorithms: list[SleepScoringAlgorithm] = [
        YasaAlgorithm(),
        SleepEEGpyAlgorithm(),
        TinySleepNetAlgorithm(),
        GsscAlgorithm(),
        SeqSleepNetAlgorithm(),
        USleepAlgorithm(),
        SleepTransformerAlgorithm(),
        LunaAlgorithm(),
        DreamentoAlgorithm(),
    ]
    return {algorithm.key: algorithm for algorithm in algorithms}


def algorithm_availability() -> dict[str, dict[str, str | bool]]:
    results: dict[str, dict[str, str | bool]] = {}
    for key, algorithm in available_algorithms().items():
        try:
            algorithm.check_available()
            results[key] = {"available": True, "message": "Ready"}
        except Exception as exc:
            results[key] = {"available": False, "message": str(exc)}
    try:
        if __package__:
            from .scorer import check_sleepgpt_available
        else:
            from scorer import check_sleepgpt_available
        check_sleepgpt_available()
        results["sleepgpt"] = {"available": True, "message": "Ready"}
    except Exception as exc:
        results["sleepgpt"] = {"available": False, "message": str(exc)}
    return results

