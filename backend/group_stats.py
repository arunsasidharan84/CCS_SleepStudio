#!/usr/bin/env python3
"""Group-level statistical analysis engine for CCS Sleep Studio.

Implements state-of-the-art statistical modeling:
- Linear Mixed-Effects Models (LMM) with random intercepts for repeated-measures / multi-channel data
- General Linear Models (GLM / OLS / ANOVA) for between-subject macroarchitecture data
- Multi-factor modeling (primary group, secondary factor, and arbitrary additional factors)
- Interactive factor label filtering, row value filtering, and custom group/subgroup plot ordering
- Automated post-hoc pairwise contrasts with FDR / Tukey HSD / Bonferroni adjustments, N counts, and Cohen's d / Hedges' g
- Publication-grade figures (400 DPI) with outlier-robust y-scaling, physical y-axis units, per-group N on x-axis,
  explicit Mean & Median legend indicators, and unclipped wrapped titles
- 2D EEG topographic scalp distribution maps (Topoplots) with spatial eTFCE (Threshold-Free Cluster Enhancement)
  permutation testing
- Space-efficient side-by-side figure layout in Word (DOCX) and PDF scientific reports
"""

from __future__ import annotations

import argparse
import datetime
import json
import math
import os
import re
import sys
import textwrap
from pathlib import Path
from typing import Any

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.lines import Line2D
    import matplotlib.patches as mpatches
    HAS_MATPLOTLIB = True
except ImportError:
    matplotlib = None
    plt = None
    Line2D = None
    mpatches = None
    HAS_MATPLOTLIB = False

try:
    from scipy import stats
    import scipy.interpolate
    HAS_SCIPY = True
except ImportError:
    stats = None
    scipy = None
    HAS_SCIPY = False

import numpy as np
import pandas as pd

try:
    import statsmodels.api as sm
    import statsmodels.formula.api as smf
    from statsmodels.stats.multitest import multipletests
    from statsmodels.stats.multicomp import pairwise_tukeyhsd
    HAS_STATSMODELS = True
except ImportError:
    sm = None
    smf = None
    multipletests = None
    pairwise_tukeyhsd = None
    HAS_STATSMODELS = False

try:
    import docx
    from docx.shared import Inches, Pt, RGBColor
    from docx.enum.text import WD_ALIGN_PARAGRAPH
    from docx.enum.table import WD_TABLE_ALIGNMENT, WD_ALIGN_VERTICAL
    from docx.oxml import parse_xml, OxmlElement
    from docx.oxml.ns import nsdecls, qn
except ImportError:
    docx = None

try:
    from reportlab.lib import colors
    from reportlab.lib.pagesizes import letter
    from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
    from reportlab.lib.units import inch
    from reportlab.platypus import (
        SimpleDocTemplate,
        Paragraph,
        Spacer,
        Table,
        TableStyle,
        Image as RLImage,
        KeepTogether,
        HRFlowable,
    )
except ImportError:
    SimpleDocTemplate = None

HAS_DOCX = (docx is not None)
HAS_REPORTLAB = (SimpleDocTemplate is not None)


# ─── SIGNIFICANCE & EFFECT SIZE HELPERS ─────────────────────────────────────

def p_to_star(p: float) -> str:
    if p is None or math.isnan(p):
        return "n/a"
    if p < 0.0001:
        return "****"
    if p < 0.001:
        return "***"
    if p < 0.01:
        return "**"
    if p < 0.05:
        return "*"
    return "ns"


def format_p_value(p: float | None) -> str:
    if p is None or math.isnan(p):
        return "n/a"
    if p < 0.0001:
        return "< 0.0001"
    if p < 0.001:
        return f"{p:.4f}"
    return f"{p:.3f}"


def calc_cohen_d(x: np.ndarray, y: np.ndarray) -> float:
    nx, ny = len(x), len(y)
    dof = nx + ny - 2
    if dof <= 0:
        return 0.0
    vx = np.var(x, ddof=1) if nx > 1 else 0.0
    vy = np.var(y, ddof=1) if ny > 1 else 0.0
    pooled_std = math.sqrt(((nx - 1) * vx + (ny - 1) * vy) / dof)
    if pooled_std == 0:
        return 0.0
    return float((np.mean(x) - np.mean(y)) / pooled_std)


def calc_hedges_g(x: np.ndarray, y: np.ndarray) -> float:
    d = calc_cohen_d(x, y)
    n = len(x) + len(y)
    if n <= 3:
        return d
    correction = 1.0 - (3.0 / (4.0 * n - 9.0))
    return float(d * correction)


def infer_metric_unit(metric: str) -> str:
    """Infers the physical or clinical measurement unit for a sleep metric."""
    m = metric.strip()
    ml = m.lower()

    # Explicit unit suffixes
    if ml.endswith("_s") or ml.endswith("_sec") or "duration_s" in ml:
        return "s"
    if ml.endswith("_min") or ml.endswith("_mins"):
        return "min"
    if ml.endswith("_h") or ml.endswith("_hr") or ml.endswith("_hrs"):
        return "h"
    if ml.endswith("_pct") or "percentage" in ml or "efficiency" in ml or ml == "cap_rate":
        return "%"
    if "relpower" in ml or "rel_power" in ml or "rel_psd" in ml:
        return "rel. fraction"
    if "index" in ml or ml in ("ahi", "plmi", "oai", "cai", "mai", "hi", "odi"):
        return "events/h"

    # Microstructure: Spindles & Slow Waves
    if "sp_" in ml or "spindle" in ml:
        if "density" in ml:
            return "events/min"
        if "duration" in ml:
            return "s"
        if "amplitude" in ml or "ptp" in ml or "rms" in ml:
            return "µV"
        if "frequency" in ml or "freq" in ml or "chirp" in ml:
            return "Hz/s" if "chirp" in ml else "Hz"
        if "count" in ml:
            return "count"
        if "area" in ml:
            return "µV·s"
        if "symmetry" in ml:
            return "ratio"

    if "sw_" in ml or "slowwave" in ml or "slow_wave" in ml:
        if "density" in ml:
            return "events/min"
        if "duration" in ml:
            return "s"
        if "slope" in ml:
            return "µV/s"
        if "amplitude" in ml or "ptp" in ml or "negpeak" in ml or "pospeak" in ml:
            return "µV"
        if "frequency" in ml or "freq" in ml:
            return "Hz"
        if "count" in ml:
            return "count"

    # Spectral Power / PSD
    if any(k in ml for k in ("_psd", "abspower", "abs_power", "bandpower")):
        return "µV²/Hz"
    if any(k in ml for k in ("_freq", "peak_freq", "center_freq", "_cf")):
        return "Hz"
    if "bandwidth" in ml or "_bw" in ml:
        return "Hz"

    # Aperiodic & Complexity
    if "exponent" in ml or "slope_1f" in ml:
        return "a.u. (1/f slope)"
    if "offset" in ml:
        return "log₁₀(µV²/Hz)"
    if "knee" in ml:
        return "Hz"
    if "acw" in ml:
        return "s"
    if any(k in ml for k in ("lzc", "dfa", "entropy", "sampen", "permen", "specen", "higuchi", "hurst", "pac", "mvl", "mi")):
        return "a.u."
    if "phase" in ml or "angle" in ml:
        return "rad" if "rad" in ml else "deg"

    # Macroarchitecture times
    if any(k in ml for k in ("tst", "trt", "spt", "waso", "sol", "latency", "onset", "duration", "streak")):
        return "min"
    if any(k in ml for k in ("count", "number", "transitions", "arousals", "awakenings", "sequences", "cycles")):
        return "count"

    return ""


# ─── DATA INSPECTION, FILTERING & ORDERING ──────────────────────────────────

SUBJECT_CANDIDATE_NAMES = [
    "subject identifier", "subject_code", "subject code", "subjname", "subject_name",
    "subject", "subjid", "subject id", "napid", "nap_id", "mappingcode", "sl.no.",
    "participant_id", "participant", "patient_id", "patient"
]

GROUP_CANDIDATE_NAMES = [
    "group", "groupid", "group_id", "status", "psgtype", "condition",
    "cohort", "arm", "treatment", "diagnosis", "dx", "slept_well"
]

SUBGROUP_CANDIDATE_NAMES = [
    "subsubjname", "chan", "channel", "electrode", "derivation", "eeg channel", "region", "roi",
    "ageid", "age_id", "session", "session_id", "visit", "time_point", "timepoint", "epoch"
]

COVARIATE_CANDIDATE_NAMES = [
    "age", "gender", "sex", "education", "practiceyears", "bmi", "trt", "date_of_birth"
]

# Standard 10-20 and 10-10 scalp EEG derivations + regional centroids normalized to head radius 0.5 (Nose = +Y)
ELECTRODE_COORDS_2D: dict[str, tuple[float, float]] = {
    # Frontal Polar
    "FP1": (-0.15, 0.45), "FP2": (0.15, 0.45), "FPZ": (0.0, 0.47),
    # Anterior Frontal
    "AF3": (-0.18, 0.35), "AF4": (0.18, 0.35), "AF7": (-0.35, 0.35), "AF8": (0.35, 0.35), "AFZ": (0.0, 0.36),
    # Frontal
    "F3": (-0.22, 0.22), "F4": (0.22, 0.22), "FZ": (0.0, 0.24),
    "F1": (-0.11, 0.23), "F2": (0.11, 0.23),
    "F5": (-0.32, 0.22), "F6": (0.32, 0.22),
    "F7": (-0.42, 0.22), "F8": (0.42, 0.22),
    # Fronto-Central
    "FC1": (-0.13, 0.11), "FC2": (0.13, 0.11), "FCZ": (0.0, 0.12),
    "FC3": (-0.26, 0.11), "FC4": (0.26, 0.11),
    "FC5": (-0.42, 0.11), "FC6": (0.42, 0.11),
    # Central
    "C3": (-0.24, 0.0), "C4": (0.24, 0.0), "CZ": (0.0, 0.0),
    "C1": (-0.12, 0.0), "C2": (0.12, 0.0),
    "C5": (-0.35, 0.0), "C6": (0.35, 0.0),
    # Temporal
    "T3": (-0.45, 0.0), "T4": (0.45, 0.0),
    "T7": (-0.45, 0.0), "T8": (0.45, 0.0),
    "T5": (-0.38, -0.28), "T6": (0.38, -0.28),
    "P7": (-0.38, -0.28), "P8": (0.38, -0.28),
    "FT7": (-0.44, 0.12), "FT8": (0.44, 0.12),
    "TP7": (-0.44, -0.12), "TP8": (0.44, -0.12),
    # Centro-Parietal
    "CP1": (-0.13, -0.11), "CP2": (0.13, -0.11), "CPZ": (0.0, -0.12),
    "CP3": (-0.26, -0.11), "CP4": (0.26, -0.11),
    "CP5": (-0.42, -0.11), "CP6": (0.42, -0.11),
    # Parietal
    "P3": (-0.22, -0.22), "P4": (0.22, -0.22), "PZ": (0.0, -0.24),
    "P1": (-0.11, -0.23), "P2": (0.11, -0.23),
    "P5": (-0.30, -0.25), "P6": (0.30, -0.25),
    # Parieto-Occipital
    "PO3": (-0.18, -0.35), "PO4": (0.18, -0.35), "PO7": (-0.35, -0.35), "PO8": (0.35, -0.35), "POZ": (0.0, -0.36),
    # Occipital
    "O1": (-0.15, -0.45), "O2": (0.15, -0.45), "OZ": (0.0, -0.47),
    # Regional Centroids (so Regional CSVs with Frontal, Central, Parietal, Occipital, Temporal also render Topoplots!)
    "FRONTAL": (0.0, 0.28),
    "LEFT FRONTAL": (-0.22, 0.26), "RIGHT FRONTAL": (0.22, 0.26),
    "CENTRAL": (0.0, 0.0),
    "LEFT CENTRAL": (-0.24, 0.0), "RIGHT CENTRAL": (0.24, 0.0),
    "PARIETAL": (0.0, -0.24),
    "LEFT PARIETAL": (-0.22, -0.24), "RIGHT PARIETAL": (0.22, -0.24),
    "OCCIPITAL": (0.0, -0.44),
    "LEFT OCCIPITAL": (-0.16, -0.44), "RIGHT OCCIPITAL": (0.16, -0.44),
    "TEMPORAL": (-0.42, -0.04),
    "LEFT TEMPORAL": (-0.42, 0.0), "RIGHT TEMPORAL": (0.42, 0.0),
}


def normalize_channel_name(ch: str) -> str:
    """Normalizes channel or region name string for 10-20 / regional mapping."""
    c = str(ch).upper().strip()
    c = re.sub(r"^EEG[\s\-_]?", "", c)
    c = re.sub(r"[\-_:](REF|AVG|LE|M1|M2|A1|A2|LER|EAR)$", "", c)
    c = re.sub(r"^REGION[\s\-_:]?", "", c)
    return c.strip()


def check_topoplot_suitability(channels: list[str]) -> tuple[bool, dict[str, tuple[float, float]]]:
    """Checks if recognized 10-20 EEG channels or scalp regions are suitable for 2D scalp mapping."""
    matched: dict[str, tuple[float, float]] = {}
    used_coords: set[tuple[float, float]] = set()
    for ch in channels:
        norm = normalize_channel_name(ch)
        if norm in ELECTRODE_COORDS_2D:
            coord = ELECTRODE_COORDS_2D[norm]
            # Slight jitter if two labels map to the exact same coordinate (e.g. T3 and T7)
            if coord in used_coords:
                coord = (coord[0] + 0.015, coord[1] + 0.015)
            used_coords.add(coord)
            matched[ch] = coord

    if len(matched) >= 4:
        xs = [coord[0] for coord in matched.values()]
        ys = [coord[1] for coord in matched.values()]
        if (max(xs) - min(xs) >= 0.15) or (max(ys) - min(ys) >= 0.25):
            return True, matched

    return False, {}


def ordered_levels(series: pd.Series, custom_order: list[str] | None = None) -> list[str]:
    """Returns unique non-null string levels ordered by custom_order if provided, else naturally sorted."""
    present = [str(v) for v in series.dropna().unique() if str(v).strip() != ""]
    if custom_order:
        ordered = [str(x) for x in custom_order if str(x) in present]
        for p in present:
            if p not in ordered:
                ordered.append(p)
        return ordered
    return sorted(present)


def apply_data_filters(
    df: pd.DataFrame,
    exclude_labels: dict[str, list[str]] | None = None,
    row_filters: list[dict[str, Any]] | None = None,
) -> pd.DataFrame:
    """Applies interactive factor label exclusions and row value filter rules to the dataframe."""
    filtered = df.copy()

    if exclude_labels:
        for col, bad_labels in exclude_labels.items():
            if col in filtered.columns and bad_labels:
                bad_set = {str(lbl).strip() for lbl in bad_labels}
                mask = ~filtered[col].astype(str).str.strip().isin(bad_set)
                filtered = filtered[mask].copy()

    if row_filters:
        for rule in row_filters:
            col = rule.get("column")
            op = str(rule.get("op", "==")).strip().lower()
            val = rule.get("value")
            if not col or col not in filtered.columns:
                continue

            if op in ("is_na", "isna", "empty"):
                filtered = filtered[filtered[col].notna() & (filtered[col].astype(str).str.strip() != "")].copy()
                continue

            if val is None or str(val).strip() == "":
                continue
            val_str = str(val).strip()

            if op in ("==", "=", "equals"):
                # Exclude rows where col == val
                num_val = pd.to_numeric(val_str, errors="coerce")
                col_num = pd.to_numeric(filtered[col], errors="coerce")
                if not pd.isna(num_val) and col_num.notna().any():
                    mask = ~(
                        (filtered[col].astype(str).str.strip() == val_str)
                        | np.isclose(col_num.fillna(np.nan), float(num_val), equal_nan=False)
                    )
                else:
                    mask = filtered[col].astype(str).str.strip() != val_str
                filtered = filtered[mask].copy()
            elif op in ("!=", "not_equals"):
                # Exclude rows where col != val (i.e., keep only col == val)
                mask = filtered[col].astype(str).str.strip() == val_str
                filtered = filtered[mask].copy()
            elif op == "contains":
                mask = ~filtered[col].astype(str).str.contains(val_str, case=False, na=False, regex=False)
                filtered = filtered[mask].copy()
            elif op in ("<", "<=", ">", ">="):
                num_val = pd.to_numeric(val_str, errors="coerce")
                if not pd.isna(num_val):
                    col_num = pd.to_numeric(filtered[col], errors="coerce")
                    if op == "<":
                        mask = ~(col_num < float(num_val))
                    elif op == "<=":
                        mask = ~(col_num <= float(num_val))
                    elif op == ">":
                        mask = ~(col_num > float(num_val))
                    else:
                        mask = ~(col_num >= float(num_val))
                    filtered = filtered[mask].copy()

    return filtered


def detect_columns(df: pd.DataFrame) -> dict[str, Any]:
    cols = list(df.columns)
    cols_clean = {c: re.sub(r"^metadata:\s*", "", c.lower().strip()) for c in cols}

    # Subject ID
    subject_id = None
    for cand in SUBJECT_CANDIDATE_NAMES:
        for c, cl in cols_clean.items():
            if cl == cand:
                subject_id = c
                break
        if subject_id:
            break
    if not subject_id:
        for c, cl in cols_clean.items():
            if "subject" in cl or "participant" in cl:
                subject_id = c
                break

    # Categorical columns
    categorical_cols = []
    for c in cols:
        cl = cols_clean[c]
        if cl in ("source_file", "source_path", "recording date"):
            continue
        s_num = pd.to_numeric(df[c], errors="coerce")
        is_predominantly_numeric = s_num.notna().sum() >= max(3, len(df) * 0.70)
        is_known_factor_or_id = any(
            cand == cl for cand in (SUBJECT_CANDIDATE_NAMES + GROUP_CANDIDATE_NAMES + SUBGROUP_CANDIDATE_NAMES)
        )
        nunique = df[c].nunique(dropna=True)

        if not is_predominantly_numeric or is_known_factor_or_id:
            if df[c].dtype == "object" or (1 < nunique <= 24 and nunique < max(len(df) * 0.6, 10)):
                categorical_cols.append(c)

    # Primary group
    group_col = None
    for cand in GROUP_CANDIDATE_NAMES:
        for c in categorical_cols:
            if cols_clean[c] == cand:
                group_col = c
                break
        if group_col:
            break
    if not group_col and categorical_cols:
        non_subj_cats = [
            c for c in categorical_cols
            if cols_clean[c] not in SUBJECT_CANDIDATE_NAMES and c != subject_id
        ]
        group_col = non_subj_cats[0] if non_subj_cats else categorical_cols[0]

    # Subgroup / Factor 2
    subgroup_col = None
    for cand in SUBGROUP_CANDIDATE_NAMES:
        for c in categorical_cols:
            if c != group_col and cols_clean[c] == cand:
                subgroup_col = c
                break
        if subgroup_col:
            break

    # Covariates
    covariates = []
    for c in cols:
        cl = cols_clean[c]
        if cl in ("source_file", "source_path") or c in (group_col, subgroup_col, subject_id):
            continue
        if any(cand == cl for cand in COVARIATE_CANDIDATE_NAMES):
            covariates.append(c)

    # Numeric metric columns
    metric_cols = []
    for c in cols:
        if c in (subject_id, group_col, subgroup_col, "source_file", "source_path"):
            continue
        if c in covariates:
            continue
        s = pd.to_numeric(df[c], errors="coerce")
        if s.notna().sum() >= 3 and s.nunique() >= 2:
            metric_cols.append(c)

    # Factor levels and counts for interactive filtering & ordering
    factor_levels: dict[str, list[str]] = {}
    factor_counts: dict[str, dict[str, int]] = {}
    for c in categorical_cols:
        vc = df[c].dropna().astype(str).str.strip()
        vc = vc[vc != ""]
        levels = sorted(vc.unique().tolist())
        factor_levels[c] = levels
        counts = vc.value_counts().to_dict()
        factor_counts[c] = {str(k): int(v) for k, v in counts.items()}

    # Channel / Electrode / Region column
    channel_col = None
    for cand in ["chan", "channel", "subsubjname", "region", "electrode", "derivation", "roi"]:
        for c in cols:
            if cols_clean[c] == cand:
                channel_col = c
                break
        if channel_col:
            break

    # Filterable columns metadata for row filtering UI
    filterable_columns: list[str] = [c for c in cols if c != "source_path"]
    column_Distinct_samples: dict[str, list[str]] = {}
    for c in filterable_columns:
        vals = df[c].dropna().astype(str).str.strip().unique().tolist()
        if len(vals) <= 30:
            column_Distinct_samples[c] = sorted(vals)

    env_info = {
        "python_path": sys.executable,
        "has_pandas": True,
        "has_matplotlib": HAS_MATPLOTLIB,
        "has_scipy": HAS_SCIPY,
        "has_statsmodels": HAS_STATSMODELS,
        "has_docx": HAS_DOCX,
        "has_reportlab": HAS_REPORTLAB,
        "missing_packages": [
            pkg for pkg, has in [
                ("matplotlib", HAS_MATPLOTLIB),
                ("scipy", HAS_SCIPY),
                ("statsmodels", HAS_STATSMODELS),
                ("python-docx", HAS_DOCX),
                ("reportlab", HAS_REPORTLAB),
            ] if not has
        ]
    }

    return {
        "subject_id": subject_id,
        "group_col": group_col,
        "subgroup_col": subgroup_col,
        "channel_col": channel_col,
        "categorical_columns": categorical_cols,
        "covariates": covariates,
        "metric_columns": metric_cols,
        "factor_levels": factor_levels,
        "factor_counts": factor_counts,
        "filterable_columns": filterable_columns,
        "column_distinct_values": column_Distinct_samples,
        "total_rows": len(df),
        "total_columns": len(cols),
        "unique_subjects": int(df[subject_id].nunique(dropna=True)) if subject_id and subject_id in df.columns else len(df),
        "environment": env_info,
    }


def is_macroarchitecture_or_channel_invariant(
    metric: str,
    df: pd.DataFrame,
    subject_id: str | None = None,
    channel_col: str | None = None,
) -> bool:
    """Determines whether a sleep metric represents global macroarchitecture that is redundant across channels."""
    ml = metric.lower().strip()
    macro_keywords = [
        "sleep_efficiency", "sleepefficiency", "tst", "trt", "waso", "sol", "spt",
        "sleep_maintenance_efficiency", "sleep_latency", "rem_latency", "w_onset",
        "w_duration", "n1_duration", "n2_duration", "n3_duration", "r_duration", "rem_duration",
        "nrem_duration", "n1_percentage", "n2_percentage", "n3_percentage", "r_percentage", "rem_percentage",
        "wake_percentage", "wake_duration", "stage_transitions", "stage_arousals", "shortawakenings"
    ]
    if any(k == ml or ml.startswith(k + "_") or ml.endswith("_" + k) for k in macro_keywords):
        return True
    if ml.startswith("cap_") or any(k in ml for k in ["sleep_efficiency", "sleepefficiency", "tst", "trt", "waso", "sol", "spt"]):
        return True

    # If channel_col is specified and present, check if metric has zero variance across channels within subjects
    if subject_id and subject_id in df.columns and channel_col and channel_col in df.columns:
        sub = df[[subject_id, channel_col, metric]].dropna()
        if len(sub) > 0:
            grouped = sub.groupby(subject_id)[metric].nunique()
            if (grouped <= 1).mean() > 0.90:
                return True

    return False


def categorize_metrics(metrics: list[str]) -> dict[str, list[str]]:
    categories: dict[str, list[str]] = {
        "Macroarchitecture": [],
        "Spindles": [],
        "Slow Waves": [],
        "Spectral Power": [],
        "Aperiodic & Complexity": [],
        "CAP (Cyclic Alternating Pattern)": [],
        "Sleep Cycles": [],
        "Other Regional": [],
    }

    for m in metrics:
        ml = m.lower()
        if "cap_" in ml or ml.startswith("cap") or "cyclic" in ml:
            categories["CAP (Cyclic Alternating Pattern)"].append(m)
        elif "cyc" in ml or "cycle" in ml or re.match(r"^c[1-5]_.*cycle", ml):
            categories["Sleep Cycles"].append(m)
        elif "sp_" in ml or "spindle" in ml:
            categories["Spindles"].append(m)
        elif "sw_" in ml or "slow" in ml:
            categories["Slow Waves"].append(m)
        elif any(k in ml for k in ["psd", "relpower", "abspower", "delta", "theta", "alpha", "sigma", "beta", "gamma"]) and "fooof" not in ml and "irasa" not in ml:
            categories["Spectral Power"].append(m)
        elif any(k in ml for k in ["fooof", "irasa", "exponent", "offset", "knee", "lzc", "dfa", "entropy", "nonlinear", "acw"]):
            categories["Aperiodic & Complexity"].append(m)
        elif any(k in ml for k in ["trt", "tst", "spt", "waso", "sol", "efficiency", "percentage", "onset", "latency", "duration", "streak", "transition", "arousal", "awakening", "slept_well"]):
            categories["Macroarchitecture"].append(m)
        else:
            categories["Other Regional"].append(m)

    return {k: v for k, v in categories.items() if v}


# ─── STATISTICAL MODELLING: LMM & GLM WITH MULTI-FACTOR SUPPORT ─────────────

def fit_statistical_model(
    df: pd.DataFrame,
    metric: str,
    group_col: str,
    subgroup_col: str | None,
    covariates: list[str],
    subject_id: str | None,
    channel_col: str | None = None,
    extra_factors: list[str] | None = None,
    include_interactions: bool = True,
    group_order: list[str] | None = None,
    subgroup_order: list[str] | None = None,
    preferred_model: str = "auto",  # 'auto', 'lmm', 'glm'
    posthoc_method: str = "fdr",     # 'tukey', 'fdr', 'bonferroni'
) -> dict[str, Any] | None:
    """Fits LMM or GLM to the metric with support for multiple factors, effect sizes, and N counts."""
    is_macro = is_macroarchitecture_or_channel_invariant(metric, df, subject_id, channel_col)

    # For whole-recording macro / CAP metrics:
    # 1. If group_col is the channel factor, it has zero variance across channels -> skip analysis
    if is_macro and channel_col and group_col == channel_col:
        return None

    # 2. Skip ONLY the channel factor if it was selected as subgroup_col!
    # KEEP all experimental factors (Status, Session, Visit, Condition, etc.) for macro/CAP metrics!
    effective_subgroup_col = subgroup_col
    if is_macro and channel_col and subgroup_col == channel_col:
        effective_subgroup_col = None

    # 3. Omit channel_col from extra_factors for macro metrics
    extra_factors_clean = [
        f for f in (extra_factors or [])
        if f and f in df.columns and f not in (metric, group_col, effective_subgroup_col, subject_id)
        and (not (is_macro and channel_col and f == channel_col))
    ]

    needed_cols = []
    for c in [metric, group_col, effective_subgroup_col, subject_id] + extra_factors_clean + [cv for cv in covariates if cv != metric]:
        if c and c in df.columns and c not in needed_cols:
            needed_cols.append(c)

    sub_df = df[needed_cols].copy()
    sub_df[metric] = pd.to_numeric(sub_df[metric], errors="coerce")
    for cov in covariates:
        if cov != metric and cov in sub_df.columns and cov not in extra_factors_clean:
            sub_df[cov] = pd.to_numeric(sub_df[cov], errors="coerce")
    sub_df = sub_df.dropna(subset=[metric, group_col]).copy()

    # In multi-channel sheets, each subject has multiple rows for each channel.
    # For macro / CAP metrics, collapse redundant channel rows down to 1 observation per experimental condition cell!
    if is_macro:
        session_keys = [k for k in [subject_id, group_col, effective_subgroup_col] + extra_factors_clean if k and k in sub_df.columns]
        if session_keys:
            sub_df = sub_df.drop_duplicates(subset=session_keys).copy()

    # Drop groups with < 2 observations
    group_counts = sub_df[group_col].value_counts()
    valid_groups = group_counts[group_counts >= 2].index.tolist()
    if len(valid_groups) < 2:
        return None
    sub_df = sub_df[sub_df[group_col].isin(valid_groups)].copy()

    if len(sub_df) < 5:
        return None

    # Check repeated measures per subject (e.g. repeated Status, Sessions, or channels)
    has_repeated_measures = False
    if subject_id and subject_id in sub_df.columns:
        n_obs = len(sub_df)
        n_subj = sub_df[subject_id].nunique()
        if n_obs > n_subj * 1.05:
            has_repeated_measures = True

    if preferred_model == "lmm":
        use_lmm = True
    elif preferred_model == "glm":
        use_lmm = False
    else:
        use_lmm = has_repeated_measures and (subject_id is not None)

    # Rename columns to safe patsy names
    rename_map = {metric: "DEP_VAR", group_col: "GRP_VAR"}
    if effective_subgroup_col and effective_subgroup_col in sub_df.columns:
        rename_map[effective_subgroup_col] = "SUBGRP_VAR"
    if subject_id and subject_id in sub_df.columns:
        rename_map[subject_id] = "SUBJ_ID"

    valid_extra_factors = []
    for i, ef in enumerate(extra_factors_clean):
        if ef in sub_df.columns and sub_df[ef].nunique(dropna=True) > 1:
            safe_ef = f"EXTRA_FAC_{i}"
            rename_map[ef] = safe_ef
            valid_extra_factors.append((ef, safe_ef))

    valid_covs = []
    for i, cov in enumerate(covariates):
        if cov in extra_factors_clean:
            continue
        if cov in sub_df.columns and sub_df[cov].notna().sum() >= len(sub_df) * 0.75:
            safe_cov = f"COV_{i}"
            rename_map[cov] = safe_cov
            valid_covs.append((cov, safe_cov))

    safe_df = sub_df.rename(columns=rename_map)
    drop_check_cols = [sc for _, sc in valid_covs] + [sef for _, sef in valid_extra_factors]
    if drop_check_cols:
        safe_df = safe_df.dropna(subset=drop_check_cols)

    if len(safe_df) < 5:
        return None

    n_obs_total = int(len(safe_df))
    n_subj_total = int(safe_df["SUBJ_ID"].nunique()) if "SUBJ_ID" in safe_df.columns else n_obs_total

    # Construct formula
    formula_parts = ["C(GRP_VAR)"]
    has_subgroup = "SUBGRP_VAR" in safe_df.columns and safe_df["SUBGRP_VAR"].nunique() > 1
    if has_subgroup:
        formula_parts.append("C(SUBGRP_VAR)")
        if include_interactions:
            formula_parts.append("C(GRP_VAR):C(SUBGRP_VAR)")
    for orig_ef, safe_ef in valid_extra_factors:
        if safe_df[safe_ef].nunique() > 1:
            formula_parts.append(f"C({safe_ef})")
            if include_interactions and len(safe_df) >= 12:
                formula_parts.append(f"C(GRP_VAR):C({safe_ef})")
    for _, sc in valid_covs:
        formula_parts.append(sc)

    formula = f"DEP_VAR ~ {' + '.join(formula_parts)}"

    def restore_term_name(raw_term: str) -> str:
        t = str(raw_term)
        if effective_subgroup_col:
            t = t.replace("C(SUBGRP_VAR)", effective_subgroup_col).replace("SUBGRP_VAR", effective_subgroup_col)
        t = t.replace("C(GRP_VAR)", group_col).replace("GRP_VAR", group_col)
        for orig_ef, safe_ef in valid_extra_factors:
            t = t.replace(f"C({safe_ef})", orig_ef).replace(safe_ef, orig_ef)
        for orig_cv, safe_cv in valid_covs:
            t = t.replace(safe_cv, orig_cv)
        return t

    model_type = "GLM / OLS"
    model_effects: list[dict[str, Any]] = []
    fit_converged = True
    r_squared = None

    if use_lmm and smf is not None and "SUBJ_ID" in safe_df.columns:
        try:
            lmm_model = smf.mixedlm(formula, safe_df, groups=safe_df["SUBJ_ID"])
            lmm_fit = lmm_model.fit(reml=True)
            model_type = "Linear Mixed Model (LMM)"
            fit_converged = bool(lmm_fit.converged)
            df_resid_approx = max(1, n_obs_total - len(lmm_fit.params))

            try:
                wald = lmm_fit.wald_test_terms()
                w_frame = wald.summary_frame()
                for term_idx, row in w_frame.iterrows():
                    if str(term_idx).strip().lower() == "intercept":
                        continue
                    chi2_val = row.get("chi2", [np.nan])
                    val = float(chi2_val[0][0]) if hasattr(chi2_val, "__getitem__") and hasattr(chi2_val[0], "__getitem__") else float(chi2_val)
                    p_val = float(row.get("P>chi2", np.nan))
                    df_val = int(row.get("df constraint", 1))
                    # Partial eta^2 approximation from Wald Chi^2: chi2 / (chi2 + df_resid)
                    partial_eta = val / (val + df_resid_approx) if (val + df_resid_approx) > 0 and not math.isnan(val) else 0.0
                    cohens_f = math.sqrt(partial_eta / max(1e-9, 1.0 - partial_eta)) if partial_eta > 0 else 0.0
                    term_name = restore_term_name(str(term_idx))
                    model_effects.append({
                        "term": term_name,
                        "n_subjects": n_subj_total,
                        "n_obs": n_obs_total,
                        "statistic": val,
                        "stat_type": "Chi2",
                        "df": df_val,
                        "df_resid": df_resid_approx,
                        "p_value": p_val,
                        "effect_size": float(partial_eta),
                        "effect_size_type": "ηp²",
                        "cohens_f": float(cohens_f),
                        "significance": p_to_star(p_val),
                    })
            except Exception:
                pass

            for param_name, coef in lmm_fit.params.items():
                if param_name in ("Group Var", "Intercept"):
                    continue
                se = float(lmm_fit.bse.get(param_name, np.nan))
                z = float(lmm_fit.tvalues.get(param_name, np.nan))
                p = float(lmm_fit.pvalues.get(param_name, np.nan))
                ci = lmm_fit.conf_int().loc[param_name]
                ci_low, ci_high = float(ci[0]), float(ci[1])
                t_name = restore_term_name(param_name)
                if not any(e["term"] == t_name for e in model_effects):
                    eta_approx = (z * z) / (z * z + df_resid_approx) if not math.isnan(z) else 0.0
                    model_effects.append({
                        "term": t_name,
                        "n_subjects": n_subj_total,
                        "n_obs": n_obs_total,
                        "estimate": float(coef),
                        "std_error": se,
                        "statistic": z,
                        "stat_type": "z",
                        "df": df_resid_approx,
                        "df_resid": df_resid_approx,
                        "p_value": p,
                        "effect_size": float(eta_approx),
                        "effect_size_type": "ηp²",
                        "ci_lower": ci_low,
                        "ci_upper": ci_high,
                        "significance": p_to_star(p),
                    })
        except Exception:
            use_lmm = False

    if not use_lmm and smf is not None:
        try:
            ols_fit = smf.ols(formula, safe_df).fit()
            model_type = "General Linear Model (GLM / ANOVA)"
            r_squared = float(ols_fit.rsquared)
            df_resid_ols = int(ols_fit.df_resid)

            try:
                anova = sm.stats.anova_lm(ols_fit, typ=2)
                for term_idx, row in anova.iterrows():
                    if term_idx == "Residual":
                        continue
                    f_val = float(row.get("F", np.nan))
                    p_val = float(row.get("PR(>F)", np.nan))
                    df_val = int(row.get("df", 1))
                    ss_val = float(row.get("sum_sq", 0.0))
                    resid_ss = float(anova.loc["Residual", "sum_sq"]) if "Residual" in anova.index else 1.0
                    partial_eta = ss_val / (ss_val + resid_ss) if (ss_val + resid_ss) > 0 else 0.0
                    cohens_f = math.sqrt(partial_eta / max(1e-9, 1.0 - partial_eta)) if partial_eta > 0 else 0.0

                    t_name = restore_term_name(str(term_idx))
                    model_effects.append({
                        "term": t_name,
                        "n_subjects": n_subj_total,
                        "n_obs": n_obs_total,
                        "statistic": f_val,
                        "stat_type": "F",
                        "df": df_val,
                        "df_resid": df_resid_ols,
                        "p_value": p_val,
                        "effect_size": float(partial_eta),
                        "effect_size_type": "ηp²",
                        "cohens_f": float(cohens_f),
                        "significance": p_to_star(p_val),
                    })
            except Exception:
                pass

            for param_name, coef in ols_fit.params.items():
                if param_name == "Intercept":
                    continue
                se = float(ols_fit.bse.get(param_name, np.nan))
                t = float(ols_fit.tvalues.get(param_name, np.nan))
                p = float(ols_fit.pvalues.get(param_name, np.nan))
                ci = ols_fit.conf_int().loc[param_name]
                ci_low, ci_high = float(ci[0]), float(ci[1])
                t_name = restore_term_name(param_name)
                if not any(e["term"] == t_name for e in model_effects):
                    eta_p = (t * t) / (t * t + max(1, df_resid_ols)) if not math.isnan(t) else 0.0
                    model_effects.append({
                        "term": t_name,
                        "n_subjects": n_subj_total,
                        "n_obs": n_obs_total,
                        "estimate": float(coef),
                        "std_error": se,
                        "statistic": t,
                        "stat_type": "t",
                        "df": df_resid_ols,
                        "df_resid": df_resid_ols,
                        "p_value": p,
                        "effect_size": float(eta_p),
                        "effect_size_type": "ηp²",
                        "ci_lower": ci_low,
                        "ci_upper": ci_high,
                        "significance": p_to_star(p),
                    })
        except Exception:
            return None

    # ── Descriptive Statistics (respecting custom order) ───────────────────
    descriptive_stats: list[dict[str, Any]] = []
    group_levels = ordered_levels(sub_df[group_col], group_order)
    subgroup_levels = (
        ordered_levels(sub_df[effective_subgroup_col], subgroup_order)
        if (has_subgroup and effective_subgroup_col)
        else [None]
    )

    for sg in subgroup_levels:
        for grp in group_levels:
            if sg is not None and effective_subgroup_col:
                mask = (sub_df[group_col].astype(str) == grp) & (sub_df[effective_subgroup_col].astype(str) == sg)
            else:
                mask = sub_df[group_col].astype(str) == grp
            cell_df = sub_df.loc[mask]
            vals = cell_df[metric].dropna().values
            if len(vals) == 0:
                continue
            n_cell_subj = (
                int(cell_df[subject_id].nunique(dropna=True))
                if (subject_id and subject_id in cell_df.columns)
                else int(len(vals))
            )
            descriptive_stats.append({
                "group": grp,
                "subgroup": sg,
                "n": int(len(vals)),
                "n_subjects": n_cell_subj,
                "mean": float(np.mean(vals)),
                "std": float(np.std(vals, ddof=1)) if len(vals) > 1 else 0.0,
                "sem": float(stats.sem(vals)) if len(vals) > 1 else 0.0,
                "median": float(np.median(vals)),
                "iqr": float(stats.iqr(vals)) if len(vals) > 1 else 0.0,
                "min": float(np.min(vals)),
                "max": float(np.max(vals)),
            })

    # ── Post-Hoc Pairwise Contrasts ─────────────────────────────────────────
    posthoc_contrasts: list[dict[str, Any]] = []

    if has_subgroup and effective_subgroup_col:
        for sg in subgroup_levels:
            sg_mask = sub_df[effective_subgroup_col].astype(str) == sg
            sg_df = sub_df[sg_mask]
            for i in range(len(group_levels)):
                for j in range(i + 1, len(group_levels)):
                    g1, g2 = group_levels[i], group_levels[j]
                    v1 = sg_df[sg_df[group_col].astype(str) == g1][metric].dropna().values
                    v2 = sg_df[sg_df[group_col].astype(str) == g2][metric].dropna().values
                    if len(v1) >= 2 and len(v2) >= 2:
                        t_stat, p_raw = stats.ttest_ind(v1, v2, equal_var=False)
                        d = calc_cohen_d(v1, v2)
                        g_hedges = calc_hedges_g(v1, v2)
                        posthoc_contrasts.append({
                            "contrast_type": "Group within Subgroup",
                            "factor": effective_subgroup_col,
                            "level": sg,
                            "group1": g1,
                            "group2": g2,
                            "n1": int(len(v1)),
                            "n2": int(len(v2)),
                            "mean1": float(np.mean(v1)),
                            "mean2": float(np.mean(v2)),
                            "diff": float(np.mean(v1) - np.mean(v2)),
                            "t_stat": float(t_stat),
                            "p_raw": float(p_raw),
                            "cohen_d": d,
                            "hedges_g": g_hedges,
                        })

    # Contrasts within extra factors if provided
    for orig_ef, _ in valid_extra_factors:
        ef_levels = ordered_levels(sub_df[orig_ef])
        for ef_lvl in ef_levels:
            ef_df = sub_df[sub_df[orig_ef].astype(str) == ef_lvl]
            for i in range(len(group_levels)):
                for j in range(i + 1, len(group_levels)):
                    g1, g2 = group_levels[i], group_levels[j]
                    v1 = ef_df[ef_df[group_col].astype(str) == g1][metric].dropna().values
                    v2 = ef_df[ef_df[group_col].astype(str) == g2][metric].dropna().values
                    if len(v1) >= 2 and len(v2) >= 2:
                        t_stat, p_raw = stats.ttest_ind(v1, v2, equal_var=False)
                        d = calc_cohen_d(v1, v2)
                        posthoc_contrasts.append({
                            "contrast_type": f"Group within {orig_ef}",
                            "factor": orig_ef,
                            "level": f"{orig_ef}={ef_lvl}",
                            "group1": g1,
                            "group2": g2,
                            "n1": int(len(v1)),
                            "n2": int(len(v2)),
                            "mean1": float(np.mean(v1)),
                            "mean2": float(np.mean(v2)),
                            "diff": float(np.mean(v1) - np.mean(v2)),
                            "t_stat": float(t_stat),
                            "p_raw": float(p_raw),
                            "cohen_d": d,
                            "hedges_g": calc_hedges_g(v1, v2),
                        })

    # Overall between-group contrasts (at subject level if repeated measures)
    overall_df = sub_df
    if has_repeated_measures and subject_id and subject_id in sub_df.columns:
        overall_df = (
            sub_df.groupby([subject_id, group_col], as_index=False)[metric]
            .mean()
        )
    for i in range(len(group_levels)):
        for j in range(i + 1, len(group_levels)):
            g1, g2 = group_levels[i], group_levels[j]
            v1 = overall_df[overall_df[group_col].astype(str) == g1][metric].dropna().values
            v2 = overall_df[overall_df[group_col].astype(str) == g2][metric].dropna().values
            if len(v1) >= 2 and len(v2) >= 2:
                t_stat, p_raw = stats.ttest_ind(v1, v2, equal_var=False)
                d = calc_cohen_d(v1, v2)
                posthoc_contrasts.append({
                    "contrast_type": "Main Group Effect",
                    "factor": group_col,
                    "level": "Overall",
                    "group1": g1,
                    "group2": g2,
                    "n1": int(len(v1)),
                    "n2": int(len(v2)),
                    "mean1": float(np.mean(v1)),
                    "mean2": float(np.mean(v2)),
                    "diff": float(np.mean(v1) - np.mean(v2)),
                    "t_stat": float(t_stat),
                    "p_raw": float(p_raw),
                    "cohen_d": d,
                    "hedges_g": calc_hedges_g(v1, v2),
                })

    # Adjust p-values
    if posthoc_contrasts and multipletests is not None:
        raw_ps = [c["p_raw"] for c in posthoc_contrasts]
        method_key = "fdr_bh" if posthoc_method in ("fdr", "tukey") else "bonferroni"
        _, adj_ps, _, _ = multipletests(raw_ps, method=method_key)
        for idx, adj_p in enumerate(adj_ps):
            posthoc_contrasts[idx]["p_adj"] = float(adj_p)
            posthoc_contrasts[idx]["significance"] = p_to_star(float(adj_p))
    else:
        for c in posthoc_contrasts:
            c["p_adj"] = c["p_raw"]
            c["significance"] = p_to_star(c["p_raw"])

    return {
        "metric": metric,
        "unit": infer_metric_unit(metric),
        "group_col": group_col,
        "subgroup_col": effective_subgroup_col if has_subgroup else None,
        "extra_factors": [orig for orig, _ in valid_extra_factors],
        "group_order": group_levels,
        "subgroup_order": [s for s in subgroup_levels if s is not None],
        "subject_id": subject_id,
        "is_macroarchitecture": is_macro,
        "covariates": [orig for orig, _ in valid_covs],
        "model_type": model_type,
        "formula": formula,
        "n_obs": n_obs_total,
        "n_subjects": n_subj_total,
        "fit_converged": fit_converged,
        "r_squared": r_squared,
        "model_effects": model_effects,
        "descriptive_stats": descriptive_stats,
        "posthoc_contrasts": posthoc_contrasts,
    }


# ─── PUBLICATION PLOT GENERATION (ROBUST Y-SCALING, UNITS, N, LEGEND) ───────

def compute_robust_y_bounds(y_vals: np.ndarray) -> tuple[float, float, int]:
    """Computes outlier-robust y-axis limits using Tukey's fences so extreme outliers do not squash boxes."""
    if len(y_vals) == 0:
        return 0.0, 1.0, 0
    raw_min = float(np.min(y_vals))
    raw_max = float(np.max(y_vals))
    if len(y_vals) < 6 or raw_max <= raw_min:
        return raw_min, max(raw_min + 1e-5, raw_max), 0

    q25, q75 = np.percentile(y_vals, [25, 75])
    iqr = float(q75 - q25)
    if iqr <= 1e-9:
        q5, q95 = np.percentile(y_vals, [5, 95])
        iqr = max(1e-6, float(q95 - q5))

    lower_fence = float(q25 - 1.8 * iqr)
    upper_fence = float(q75 + 1.8 * iqr)

    inliers = y_vals[(y_vals >= lower_fence) & (y_vals <= upper_fence)]
    n_outliers = int(len(y_vals) - len(inliers))

    if len(inliers) >= 4 and n_outliers > 0:
        rob_min = float(np.min(inliers))
        rob_max = float(np.max(inliers))
        rob_span = max(1e-6, rob_max - rob_min)
        raw_span = raw_max - raw_min
        # Use robust bounds if raw outliers inflate the span by > 35%
        if raw_span > rob_span * 1.35:
            return rob_min - rob_span * 0.05, rob_max + rob_span * 0.05, n_outliers

    return raw_min, raw_max, 0


def generate_publication_plot(
    result: dict[str, Any],
    raw_df: pd.DataFrame,
    output_png_path: Path,
) -> Path:
    """Renders a 400-DPI publication figure with robust y-scaling, y-axis units, per-group N on x-axis,
    Mean & Median legend indicators, and wrapped unclipped titles.
    """
    metric = result["metric"]
    unit = result.get("unit") or infer_metric_unit(metric)
    group_col = result["group_col"]
    subgroup_col = result["subgroup_col"]
    contrasts = result["posthoc_contrasts"]

    needed = [metric, group_col]
    if subgroup_col and subgroup_col not in needed:
        needed.append(subgroup_col)
    subjid = result.get("subject_id")
    if subjid and subjid in raw_df.columns and subjid not in needed:
        needed.append(subjid)

    clean = raw_df[needed].dropna(subset=[metric, group_col]).copy()
    clean[metric] = pd.to_numeric(clean[metric], errors="coerce")
    clean = clean.dropna(subset=[metric])

    if result.get("is_macroarchitecture") and subjid and subjid in clean.columns:
        clean = clean.drop_duplicates(subset=[subjid]).copy()

    groups = ordered_levels(clean[group_col], result.get("group_order"))
    palette = ["#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd", "#8c564b", "#e377c2", "#17becf"]
    color_map = {g: palette[i % len(palette)] for i, g in enumerate(groups)}

    has_subgroup = subgroup_col is not None and subgroup_col in clean.columns and clean[subgroup_col].nunique() > 1
    subgroups = ordered_levels(clean[subgroup_col], result.get("subgroup_order")) if has_subgroup else [None]

    fig_width = max(8.6, 3.2 * len(subgroups) if has_subgroup else 2.6 * len(groups))
    fig, ax = plt.subplots(figsize=(fig_width, 5.4), dpi=400)

    ax.set_facecolor("#fafafa")
    fig.patch.set_facecolor("white")
    ax.grid(axis="y", color="#e0e0e0", linestyle="--", linewidth=0.7, alpha=0.7)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.spines["left"].set_color("#333333")
    ax.spines["bottom"].set_color("#333333")

    y_vals_all = clean[metric].values
    rob_min, rob_max, n_clipped_total = compute_robust_y_bounds(y_vals_all)
    y_span = max(1e-5, rob_max - rob_min)
    rng = np.random.default_rng(42)

    if not has_subgroup:
        positions = []
        box_data = []
        box_colors = []
        x_labels = []

        for i, grp in enumerate(groups):
            grp_df = clean[clean[group_col].astype(str) == grp]
            vals = grp_df[metric].values
            n_grp = len(vals)
            pos = i + 1
            positions.append(pos)
            box_data.append(vals)
            box_colors.append(color_map[grp])
            x_labels.append(f"{grp}\n(n={n_grp})")

            if len(vals) > 0:
                jitter = rng.normal(0, 0.055, size=len(vals))
                in_mask = (vals >= rob_min) & (vals <= rob_max)
                if np.any(in_mask):
                    ax.scatter(
                        pos + jitter[in_mask], vals[in_mask],
                        color=color_map[grp], alpha=0.50, s=28, zorder=3, edgecolors="none",
                    )
                high_mask = vals > rob_max
                if np.any(high_mask):
                    ax.scatter(
                        pos + jitter[high_mask], np.full(np.sum(high_mask), rob_max),
                        color=color_map[grp], marker="^", s=38, zorder=4, edgecolors="#222222", linewidths=0.6,
                    )
                low_mask = vals < rob_min
                if np.any(low_mask):
                    ax.scatter(
                        pos + jitter[low_mask], np.full(np.sum(low_mask), rob_min),
                        color=color_map[grp], marker="v", s=38, zorder=4, edgecolors="#222222", linewidths=0.6,
                    )

        bp = ax.boxplot(
            box_data, positions=positions, widths=0.44, patch_artist=True,
            showmeans=True, meanline=True, showfliers=False, zorder=2,
            boxprops=dict(linewidth=1.25),
            whiskerprops=dict(linewidth=1.2, color="#444444"),
            capprops=dict(linewidth=1.2, color="#444444"),
            medianprops=dict(linewidth=2.0, color="#111111", linestyle="-"),
            meanprops=dict(linewidth=1.8, color="#d95f02", linestyle="--"),
        )
        for patch, color in zip(bp["boxes"], box_colors):
            patch.set_facecolor(matplotlib.colors.to_rgba(color, alpha=0.35))
            patch.set_edgecolor(color)

        ax.set_xticks(positions)
        ax.set_xticklabels(x_labels, fontsize=10.5, fontweight="bold")
        ax.set_xlabel(group_col, fontsize=11, fontweight="bold", labelpad=6)

        bracket_y = rob_max + y_span * 0.06
        step = y_span * 0.12
        main_contrasts = [
            c for c in contrasts
            if c.get("contrast_type") == "Main Group Effect"
            and c.get("group1") in groups
            and c.get("group2") in groups
        ]
        if len(groups) > 3:
            sig_contrasts = [c for c in main_contrasts if c.get("significance", "ns") != "ns"]
            if sig_contrasts:
                plot_contrasts = sig_contrasts[:4]
            else:
                plot_contrasts = sorted(main_contrasts, key=lambda x: x.get("p_raw", 1.0))[:2]
        else:
            plot_contrasts = main_contrasts

        for c in plot_contrasts:
            g1, g2 = c["group1"], c["group2"]
            idx1 = groups.index(g1) + 1
            idx2 = groups.index(g2) + 1
            sig = c.get("significance", "ns")
            p_val = c.get("p_adj", c.get("p_raw", 1.0))
            d_val = c.get("cohen_d", 0.0)
            ax.plot(
                [idx1, idx1, idx2, idx2],
                [bracket_y, bracket_y + step * 0.28, bracket_y + step * 0.28, bracket_y],
                color="#222222", lw=1.2,
            )
            label = f"{sig} (p={format_p_value(p_val)}, d={d_val:.2f})" if sig != "ns" else f"ns (d={d_val:.2f})"
            ax.text(
                (idx1 + idx2) / 2.0, bracket_y + step * 0.32, label,
                ha="center", va="bottom", fontsize=9, fontweight="bold",
                color="#d95f02" if sig != "ns" else "#555555",
            )
            bracket_y += step

        top_ylim = bracket_y + y_span * 0.24
        ax.set_ylim(rob_min - y_span * 0.08, top_ylim)

        legend_handles = [
            mpatches.Patch(
                facecolor=matplotlib.colors.to_rgba(color_map[g], alpha=0.45),
                edgecolor=color_map[g],
                label=f"{g} (n={len(clean[clean[group_col].astype(str) == g])})",
            )
            for g in groups
        ]
        legend_handles.extend([
            Line2D([0], [0], color="#111111", lw=2.0, linestyle="-", label="Median"),
            Line2D([0], [0], color="#d95f02", lw=1.8, linestyle="--", label="Mean"),
        ])
        if n_clipped_total > 0:
            legend_handles.append(
                Line2D([0], [0], marker="^", color="w", markerfacecolor="#555555", markeredgecolor="#222222", markersize=6, label=f"Outlier clipped ({n_clipped_total})")
            )
        ax.legend(
            handles=legend_handles,
            loc="upper left",
            bbox_to_anchor=(1.02, 1.0),
            borderaxespad=0,
            framealpha=0.95,
            fontsize=8.5,
        )

    else:
        n_grps = len(groups)
        width = 0.80 / max(1, n_grps)
        x_center = []
        x_sub_labels = []
        step = y_span * 0.12
        max_bracket_top = rob_max + y_span * 0.12

        for s_idx, sg in enumerate(subgroups):
            sg_center = (s_idx + 1) * 1.55
            x_center.append(sg_center)
            sg_mask = clean[subgroup_col].astype(str) == sg
            sg_df = clean[sg_mask]
            per_grp_n = [str(len(sg_df[sg_df[group_col].astype(str) == g])) for g in groups]
            x_sub_labels.append(f"{sg}\n(n={'/'.join(per_grp_n)})")

            cell_rob_max = rob_min
            for g_idx, grp in enumerate(groups):
                vals = sg_df[sg_df[group_col].astype(str) == grp][metric].values
                offset = (g_idx - (n_grps - 1) / 2.0) * width
                pos = sg_center + offset
                if len(vals) > 0:
                    in_vals = vals[(vals >= rob_min) & (vals <= rob_max)]
                    if len(in_vals) > 0:
                        cell_rob_max = max(cell_rob_max, float(np.max(in_vals)))
                    bp = ax.boxplot(
                        [vals], positions=[pos], widths=width * 0.84, patch_artist=True,
                        showmeans=True, meanline=True, showfliers=False, zorder=2,
                        boxprops=dict(linewidth=1.1),
                        whiskerprops=dict(linewidth=1.1, color="#444444"),
                        capprops=dict(linewidth=1.1, color="#444444"),
                        medianprops=dict(linewidth=1.8, color="#111111", linestyle="-"),
                        meanprops=dict(linewidth=1.5, color="#d95f02", linestyle="--"),
                    )
                    bp["boxes"][0].set_facecolor(matplotlib.colors.to_rgba(color_map[grp], alpha=0.35))
                    bp["boxes"][0].set_edgecolor(color_map[grp])
                    jitter = rng.normal(0, width * 0.08, size=len(vals))
                    in_mask = (vals >= rob_min) & (vals <= rob_max)
                    if np.any(in_mask):
                        ax.scatter(
                            pos + jitter[in_mask], vals[in_mask],
                            color=color_map[grp], alpha=0.5, s=20, zorder=3, edgecolors="none",
                        )
                    high_mask = vals > rob_max
                    if np.any(high_mask):
                        ax.scatter(
                            pos + jitter[high_mask], np.full(np.sum(high_mask), rob_max),
                            color=color_map[grp], marker="^", s=32, zorder=4, edgecolors="#222222", linewidths=0.5,
                        )
                    low_mask = vals < rob_min
                    if np.any(low_mask):
                        ax.scatter(
                            pos + jitter[low_mask], np.full(np.sum(low_mask), rob_min),
                            color=color_map[grp], marker="v", s=32, zorder=4, edgecolors="#222222", linewidths=0.5,
                        )

            sg_contrasts = [c for c in contrasts if c.get("factor") == subgroup_col and str(c.get("level")) == str(sg)]
            local_y = min(rob_max, max(cell_rob_max, rob_min + y_span * 0.5)) + y_span * 0.05
            for c in sg_contrasts:
                g1, g2 = c["group1"], c["group2"]
                if g1 in groups and g2 in groups:
                    idx1 = groups.index(g1)
                    idx2 = groups.index(g2)
                    pos1 = sg_center + (idx1 - (n_grps - 1) / 2.0) * width
                    pos2 = sg_center + (idx2 - (n_grps - 1) / 2.0) * width
                    sig = c.get("significance", "ns")
                    if sig != "ns":
                        ax.plot(
                            [pos1, pos1, pos2, pos2],
                            [local_y, local_y + step * 0.24, local_y + step * 0.24, local_y],
                            color="#d95f02", lw=1.15,
                        )
                        ax.text(
                            (pos1 + pos2) / 2.0, local_y + step * 0.28, f"{sig}",
                            ha="center", va="bottom", fontsize=9.5, fontweight="bold", color="#d95f02",
                        )
                        local_y += step * 0.58
                        max_bracket_top = max(max_bracket_top, local_y + step * 0.35)

        ax.set_xticks(x_center)
        ax.set_xticklabels(x_sub_labels, fontsize=9.5, fontweight="bold")
        ax.set_xlabel(f"{subgroup_col} (per-group n shown in parentheses)", fontsize=10.5, fontweight="bold", labelpad=8)
        ax.set_ylim(rob_min - y_span * 0.08, max_bracket_top + y_span * 0.14)

        legend_handles = []
        for g in groups:
            g_df = clean[clean[group_col].astype(str) == g]
            n_g_subj = g_df[subjid].nunique() if (subjid and subjid in g_df.columns) else len(g_df)
            legend_handles.append(
                mpatches.Patch(
                    facecolor=matplotlib.colors.to_rgba(color_map[g], alpha=0.5),
                    edgecolor=color_map[g],
                    label=f"{g} (N={n_g_subj} subj, n={len(g_df)} obs)",
                )
            )
        legend_handles.extend([
            Line2D([0], [0], color="#111111", lw=2.0, linestyle="-", label="Median"),
            Line2D([0], [0], color="#d95f02", lw=1.8, linestyle="--", label="Mean"),
        ])
        if n_clipped_total > 0:
            legend_handles.append(
                Line2D([0], [0], marker="^", color="w", markerfacecolor="#555555", markeredgecolor="#222222", markersize=6, label=f"Outlier clipped ({n_clipped_total})")
            )
        ax.legend(
            handles=legend_handles, title=group_col, title_fontsize=9.5,
            loc="upper left", bbox_to_anchor=(1.02, 1.0), borderaxespad=0,
            framealpha=0.95, fontsize=8.5,
        )

    clean_metric_title = metric.replace("_", " ")
    y_label_str = f"{clean_metric_title} ({unit})" if unit else clean_metric_title
    ax.set_ylabel(y_label_str, fontsize=11, fontweight="bold", labelpad=8)

    model_type = result["model_type"]
    n_subj = result.get("n_subjects", result["n_obs"])
    n_obs = result["n_obs"]
    if result.get("is_macroarchitecture"):
        raw_title = f"{clean_metric_title} by {group_col} ({model_type}, N={n_subj} subjects)"
    else:
        raw_title = (
            f"{clean_metric_title} by {group_col}{f' across {subgroup_col}' if has_subgroup else ''} "
            f"({model_type}, N={n_subj} subj / {n_obs} obs)"
        )
    wrapped_title = "\n".join(textwrap.wrap(raw_title, width=68))
    ax.set_title(wrapped_title, fontsize=11.5, fontweight="bold", pad=14)

    plt.tight_layout()
    output_png_path.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(output_png_path, dpi=400, bbox_inches="tight", pad_inches=0.22)
    plt.close(fig)
    return output_png_path


# ─── 2D EEG TOPOGRAPHIC SCALP DISTRIBUTION WITH SPATIAL eTFCE ───────────────

def _apply_spatial_tfce(
    stat_vec: np.ndarray,
    adj_matrix: np.ndarray,
    E: float = 0.66,
    H: float = 2.0,
    n_steps: int = 40,
) -> np.ndarray:
    """Computes 2D spatial Threshold-Free Cluster Enhancement (eTFCE) over an electrode adjacency graph."""
    n_ch = len(stat_vec)
    tfce_out = np.zeros(n_ch, dtype=float)
    abs_stat = np.abs(stat_vec)
    max_val = float(np.max(abs_stat))
    if max_val <= 1e-8:
        return tfce_out

    dh = max_val / n_steps
    thresholds = np.linspace(dh, max_val, n_steps)

    for h in thresholds:
        # Positive and negative excursions treated separately so opposite signs do not merge into one cluster
        for sign in (1.0, -1.0):
            signed_vals = stat_vec * sign
            supra = np.where(signed_vals >= h)[0]
            if len(supra) == 0:
                continue
            visited = set()
            for node in supra:
                if node in visited:
                    continue
                # BFS connected component within supra-threshold set
                cluster = []
                queue = [node]
                visited.add(node)
                while queue:
                    curr = queue.pop(0)
                    cluster.append(curr)
                    for nb in supra:
                        if nb not in visited and adj_matrix[curr, nb]:
                            visited.add(nb)
                            queue.append(nb)
                extent = float(len(cluster))
                contrib = (extent ** E) * (h ** H) * dh
                for c_idx in cluster:
                    tfce_out[c_idx] += sign * contrib

    return tfce_out


def compute_etfce_topoplot(
    clean_df: pd.DataFrame,
    metric: str,
    group_col: str,
    channel_col: str,
    matched: dict[str, tuple[float, float]],
    groups: list[str],
    n_perm: int = 400,
) -> dict[str, Any]:
    """Computes channel-wise test statistics and FWER-corrected spatial eTFCE p-values via permutation testing."""
    ch_list = list(matched.keys())
    n_ch = len(ch_list)
    pts = np.array([matched[ch] for ch in ch_list])

    # Build spatial adjacency matrix (neighbors within Euclidean distance <= 0.35 on head radius 0.5, plus nearest 2)
    dist_mat = np.sqrt(np.sum((pts[:, None, :] - pts[None, :, :]) ** 2, axis=-1))
    adj = dist_mat <= 0.35
    for i in range(n_ch):
        nearest = np.argsort(dist_mat[i])[: min(3, n_ch)]
        adj[i, nearest] = True
        adj[nearest, i] = True

    obs_stat = np.zeros(n_ch, dtype=float)
    rng = np.random.default_rng(42)
    max_perm_tfce = np.zeros(n_perm, dtype=float)

    if group_col == channel_col or len(groups) < 2:
        # Single-factor scalp topography across channels/regions: test each channel vs overall scalp mean
        grand_mean = float(clean_df[metric].mean())
        ch_arrays = [
            clean_df[clean_df[channel_col].astype(str) == ch][metric].dropna().values - grand_mean
            for ch in ch_list
        ]
        for c_idx, arr in enumerate(ch_arrays):
            if len(arr) >= 2 and np.std(arr, ddof=1) > 1e-12:
                t_val, _ = stats.ttest_1samp(arr, 0.0)
                obs_stat[c_idx] = 0.0 if math.isnan(t_val) else float(t_val)

        obs_tfce = _apply_spatial_tfce(obs_stat, adj)
        abs_obs_tfce = np.abs(obs_tfce)

        for p_i in range(n_perm):
            perm_stat = np.zeros(n_ch, dtype=float)
            for c_idx, arr in enumerate(ch_arrays):
                if len(arr) >= 2:
                    signs = rng.choice([-1.0, 1.0], size=len(arr))
                    flipped = arr * signs
                    sd = float(np.std(flipped, ddof=1))
                    if sd > 1e-12:
                        perm_stat[c_idx] = float(np.mean(flipped) / (sd / math.sqrt(len(flipped))))
            perm_tfce = _apply_spatial_tfce(perm_stat, adj)
            max_perm_tfce[p_i] = float(np.max(np.abs(perm_tfce)))
    else:
        # Multi-group scalp comparison at each channel/region
        ch_group_arrays: list[list[np.ndarray]] = []
        for c_idx, ch in enumerate(ch_list):
            ch_df = clean_df[clean_df[channel_col].astype(str) == ch]
            g_arrays = [ch_df[ch_df[group_col].astype(str) == g][metric].dropna().values for g in groups]
            ch_group_arrays.append(g_arrays)
            if len(groups) == 2:
                v1, v2 = g_arrays[0], g_arrays[1]
                if len(v1) >= 2 and len(v2) >= 2:
                    t_val, _ = stats.ttest_ind(v2, v1, equal_var=False)
                    obs_stat[c_idx] = 0.0 if math.isnan(t_val) else float(t_val)
            else:
                valid_g = [v for v in g_arrays if len(v) >= 2]
                if len(valid_g) >= 2:
                    f_val, _ = stats.f_oneway(*valid_g)
                    obs_stat[c_idx] = 0.0 if math.isnan(f_val) else float(f_val)

        obs_tfce = _apply_spatial_tfce(obs_stat, adj)
        abs_obs_tfce = np.abs(obs_tfce)

        for p_i in range(n_perm):
            perm_stat = np.zeros(n_ch, dtype=float)
            for c_idx in range(n_ch):
                g_arrays = ch_group_arrays[c_idx]
                sizes = [len(a) for a in g_arrays]
                if sum(sizes) < 4 or any(s < 2 for s in sizes):
                    continue
                pooled = np.concatenate(g_arrays)
                shuffled = rng.permutation(pooled)
                if len(groups) == 2:
                    v1 = shuffled[: sizes[0]]
                    v2 = shuffled[sizes[0] :]
                    s1 = np.var(v1, ddof=1) / sizes[0] + np.var(v2, ddof=1) / sizes[1]
                    if s1 > 1e-12:
                        perm_stat[c_idx] = float((np.mean(v2) - np.mean(v1)) / math.sqrt(s1))
                else:
                    splits = np.split(shuffled, np.cumsum(sizes)[:-1])
                    f_val, _ = stats.f_oneway(*splits)
                    perm_stat[c_idx] = 0.0 if math.isnan(f_val) else float(f_val)

            perm_tfce = _apply_spatial_tfce(perm_stat, adj)
            max_perm_tfce[p_i] = float(np.max(np.abs(perm_tfce)))

    p_etfce = {}
    tfce_map = {}
    raw_stat_map = {}
    sig_channels = set()
    channel_details = []

    for c_idx, ch in enumerate(ch_list):
        if abs_obs_tfce[c_idx] <= 1e-8:
            p_fwer = 1.0
        else:
            p_fwer = float((np.sum(max_perm_tfce >= abs_obs_tfce[c_idx]) + 1.0) / (n_perm + 1.0))
        p_etfce[ch] = p_fwer
        tfce_map[ch] = float(obs_tfce[c_idx])
        raw_stat_map[ch] = float(obs_stat[c_idx])
        if p_fwer < 0.05:
            sig_channels.add(ch)
        channel_details.append({
            "channel": ch,
            "raw_stat": float(obs_stat[c_idx]),
            "etfce_score": float(obs_tfce[c_idx]),
            "p_etfce": p_fwer,
            "significance": p_to_star(p_fwer),
        })

    return {
        "raw_stat_map": raw_stat_map,
        "tfce_map": tfce_map,
        "p_etfce": p_etfce,
        "sig_channels": sig_channels,
        "channel_details": channel_details,
    }


def _draw_head_topography(
    ax: plt.Axes,
    xi: np.ndarray,
    yi: np.ndarray,
    mask: np.ndarray,
    pts: np.ndarray,
    matched: dict[str, tuple[float, float]],
    vals: np.ndarray,
    title: str,
    cmap: str,
    vmin: float,
    vmax: float,
    cbar_label: str = "",
    sig_channels: set[str] | None = None,
) -> None:
    """Helper to render a single scalp topography subplot with head outline, nose, ears, and electrodes."""
    r = 0.5
    interp_pts = list(pts)
    interp_vals = list(vals)
    ch_keys = list(matched.keys())
    norm_keys = [normalize_channel_name(k) for k in ch_keys]
    for idx_ch, ch in enumerate(ch_keys):
        if norm_keys[idx_ch] == "TEMPORAL" and "RIGHT TEMPORAL" not in norm_keys:
            # Mirror bilateral Temporal region to the right hemisphere so regional scalp interpolation is symmetric
            lx, ly = matched[ch]
            interp_pts.append((-lx, ly))
            interp_vals.append(vals[idx_ch])

    pts_arr = np.array(interp_pts)
    vals_arr = np.array(interp_vals)
    try:
        rbf = scipy.interpolate.Rbf(pts_arr[:, 0], pts_arr[:, 1], vals_arr, function="multiquadric", smooth=0.01)
        zi = rbf(xi, yi)
    except Exception:
        zi = scipy.interpolate.griddata(pts_arr, vals_arr, (xi, yi), method="nearest")

    zi[~mask] = np.nan
    cf = ax.contourf(xi, yi, zi, levels=28, cmap=cmap, vmin=vmin, vmax=vmax)
    ax.contour(xi, yi, zi, levels=6, colors="k", linewidths=0.4, alpha=0.3)

    # Head outline, nose, ears
    circle = plt.Circle((0, 0), r, color="black", fill=False, linewidth=2.0)
    ax.add_patch(circle)
    ax.plot([-0.05, 0.0, 0.05], [0.49, 0.545, 0.49], color="black", linewidth=2.0)
    ax.plot([-0.505, -0.528, -0.505], [0.05, 0.0, -0.05], color="black", linewidth=1.5)
    ax.plot([0.505, 0.528, 0.505], [0.05, 0.0, -0.05], color="black", linewidth=1.5)

    sig_set = sig_channels or set()
    for ch, (x, y) in matched.items():
        norm_ch = normalize_channel_name(ch)
        is_sig = (ch in sig_set) or (norm_ch in sig_set)
        coords_to_draw = [(x, y)]
        if norm_ch == "TEMPORAL" and "RIGHT TEMPORAL" not in norm_keys:
            coords_to_draw = [(-0.34, y), (0.34, y)]
        for dx, dy in coords_to_draw:
            if is_sig:
                ax.scatter([dx], [dy], color="#ffea00", edgecolors="#d95f02", linewidths=1.8, s=58, zorder=6)
                ax.text(
                    dx, dy + 0.042, f"{norm_ch}*", fontsize=8.0, ha="center", va="bottom",
                    fontweight="bold", color="#b30000",
                    bbox=dict(boxstyle="round,pad=0.12", facecolor="white", edgecolor="none", alpha=0.75),
                )
            else:
                ax.scatter([dx], [dy], color="black", s=26, zorder=5)
                ax.text(dx, dy + 0.035, norm_ch, fontsize=7.5, ha="center", va="bottom", fontweight="bold", color="#111111")

    ax.set_title(title, fontsize=10.5, fontweight="bold", pad=8)
    ax.set_xlim(-0.62, 0.62)
    ax.set_ylim(-0.60, 0.62)
    ax.set_aspect("equal")
    ax.axis("off")
    cbar = plt.colorbar(cf, ax=ax, fraction=0.046, pad=0.03)
    cbar.ax.tick_params(labelsize=7.5)
    if cbar_label:
        cbar.set_label(cbar_label, fontsize=7.5)


def generate_topoplot(
    raw_df: pd.DataFrame,
    metric: str,
    group_col: str,
    channel_col: str,
    posthoc_contrasts: list[dict[str, Any]],
    output_png_path: Path,
    group_order: list[str] | None = None,
) -> tuple[Path | None, dict[str, Any] | None]:
    """Renders 400-DPI 2D EEG topographic scalp distribution map (Topoplot) with spatial eTFCE panel."""
    needed = list(dict.fromkeys([metric, group_col, channel_col]))
    clean = raw_df[needed].dropna().copy()
    clean[metric] = pd.to_numeric(clean[metric], errors="coerce")
    clean = clean.dropna(subset=[metric])
    if len(clean) < 6:
        return None, None

    channels = sorted([str(c) for c in clean[channel_col].unique()])
    is_ok, matched = check_topoplot_suitability(channels)
    if not is_ok or len(matched) < 4:
        return None, None

    clean = clean[clean[channel_col].astype(str).isin(matched.keys())].copy()
    single_factor_topography = (group_col == channel_col)
    groups = ["Grand Mean"] if single_factor_topography else ordered_levels(clean[group_col], group_order)
    if len(groups) < 1:
        return None, None

    unit = infer_metric_unit(metric)
    ch_keys = list(matched.keys())
    pts = np.array([matched[ch] for ch in ch_keys])

    group_means: dict[str, dict[str, float]] = {}
    if single_factor_topography:
        means = clean.groupby(channel_col)[metric].mean()
        group_means["Grand Mean"] = {ch: float(means.get(ch, np.nan)) for ch in ch_keys}
    else:
        for g in groups:
            g_df = clean[clean[group_col].astype(str) == g]
            means = g_df.groupby(channel_col)[metric].mean()
            group_means[g] = {ch: float(means.get(ch, np.nan)) for ch in ch_keys}

    # Compute spatial eTFCE across channels
    etfce_info = compute_etfce_topoplot(clean, metric, group_col, channel_col, matched, groups)
    etfce_sig_channels = set(etfce_info["sig_channels"])
    for c in posthoc_contrasts:
        p_val = c.get("p_adj", c.get("p_raw", 1.0))
        if p_val < 0.05 and c.get("contrast_type") == "Group within Subgroup":
            level = str(c.get("level", ""))
            if level in matched:
                etfce_sig_channels.add(level)

    r = 0.5
    xi, yi = np.mgrid[-0.55:0.55:120j, -0.55:0.55:120j]
    mask = (xi**2 + yi**2) <= r**2

    all_vals = [v for g in groups for v in group_means[g].values() if not math.isnan(v)]
    if not all_vals:
        return None, None
    g_min, g_max = min(all_vals), max(all_vals)
    if g_min == g_max:
        g_min -= 0.1
        g_max += 0.1

    contrast_pairs = []
    if not single_factor_topography and len(groups) >= 2:
        for i in range(len(groups)):
            for j in range(i + 1, len(groups)):
                contrast_pairs.append((groups[i], groups[j]))

    if len(groups) <= 2:
        n_plots = len(groups) + len(contrast_pairs) + 1
        nrows, ncols = 1, n_plots
        fig_w = max(3.6 * ncols, 7.8)
        fig, axes_raw = plt.subplots(nrows, ncols, figsize=(fig_w, 4.2), dpi=400)
        axes = [axes_raw] if n_plots == 1 else list(axes_raw)

        for idx, g in enumerate(groups):
            vals = np.array([group_means[g][ch] for ch in ch_keys])
            _draw_head_topography(
                axes[idx], xi, yi, mask, pts, matched, vals,
                title=g if single_factor_topography else f"{g} (Mean)",
                cmap="viridis", vmin=g_min, vmax=g_max,
                cbar_label=unit,
            )

        curr_ax = len(groups)
        for (g1, g2) in contrast_pairs:
            diff_vals = np.array([group_means[g2][ch] - group_means[g1][ch] for ch in ch_keys])
            max_abs = max(1e-4, float(np.max(np.abs(diff_vals))))
            pair_sig = set()
            for ch in ch_keys:
                ch_df = clean[clean[channel_col].astype(str) == ch]
                v1 = ch_df[ch_df[group_col].astype(str) == g1][metric].dropna().values
                v2 = ch_df[ch_df[group_col].astype(str) == g2][metric].dropna().values
                if len(v1) >= 2 and len(v2) >= 2:
                    try:
                        _, p_val = scipy.stats.ttest_ind(v2, v1, equal_var=False)
                        if p_val < 0.05:
                            pair_sig.add(ch)
                    except Exception:
                        pass
            for c in posthoc_contrasts:
                p_val = c.get("p_adj", c.get("p_raw", 1.0))
                if p_val < 0.05:
                    cg1, cg2 = str(c.get("group1", "")), str(c.get("group2", ""))
                    if (cg1 == g1 and cg2 == g2) or (cg1 == g2 and cg2 == g1):
                        lvl = str(c.get("level", ""))
                        if lvl in matched:
                            pair_sig.add(lvl)

            _draw_head_topography(
                axes[curr_ax], xi, yi, mask, pts, matched, diff_vals,
                title=f"Post-Hoc: {g2} − {g1} (* p<0.05)",
                cmap="RdBu_r", vmin=-max_abs, vmax=max_abs,
                cbar_label=f"Δ {unit}".strip(),
                sig_channels=pair_sig,
            )
            curr_ax += 1

        tfce_vals = np.array([etfce_info["tfce_map"][ch] for ch in ch_keys])
        max_tfce = max(1e-4, float(np.max(np.abs(tfce_vals))))
        signed_tfce = len(groups) == 2 or single_factor_topography
        etfce_cmap = "RdBu_r" if signed_tfce else "YlOrRd"
        etfce_vmin = -max_tfce if signed_tfce else 0.0
        _draw_head_topography(
            axes[curr_ax], xi, yi, mask, pts, matched, tfce_vals,
            title="eTFCE Cluster Map (* p<0.05)",
            cmap=etfce_cmap, vmin=etfce_vmin, vmax=max_tfce,
            cbar_label="eTFCE score",
            sig_channels=etfce_sig_channels,
        )

    else:
        # Multi-group case: 2 Rows (Row 1: Means + Omnibus eTFCE; Row 2: Post-Hoc Pairwise Comparisons)
        ncols = max(len(groups) + 1, len(contrast_pairs))
        nrows = 2
        fig_w = max(3.5 * ncols, 10.5)
        fig_h = 7.6
        fig, axes_grid = plt.subplots(nrows, ncols, figsize=(fig_w, fig_h), dpi=400)

        for idx, g in enumerate(groups):
            vals = np.array([group_means[g][ch] for ch in ch_keys])
            _draw_head_topography(
                axes_grid[0, idx], xi, yi, mask, pts, matched, vals,
                title=f"{g} (Mean)",
                cmap="viridis", vmin=g_min, vmax=g_max,
                cbar_label=unit,
            )

        tfce_vals = np.array([etfce_info["tfce_map"][ch] for ch in ch_keys])
        max_tfce = max(1e-4, float(np.max(np.abs(tfce_vals))))
        _draw_head_topography(
            axes_grid[0, len(groups)], xi, yi, mask, pts, matched, tfce_vals,
            title="eTFCE Cluster Map (* p<0.05)",
            cmap="YlOrRd", vmin=0.0, vmax=max_tfce,
            cbar_label="eTFCE score",
            sig_channels=etfce_sig_channels,
        )
        for col_extra in range(len(groups) + 1, ncols):
            axes_grid[0, col_extra].axis("off")

        for p_idx, (g1, g2) in enumerate(contrast_pairs):
            diff_vals = np.array([group_means[g2][ch] - group_means[g1][ch] for ch in ch_keys])
            max_abs = max(1e-4, float(np.max(np.abs(diff_vals))))

            pair_sig = set()
            for ch in ch_keys:
                ch_df = clean[clean[channel_col].astype(str) == ch]
                v1 = ch_df[ch_df[group_col].astype(str) == g1][metric].dropna().values
                v2 = ch_df[ch_df[group_col].astype(str) == g2][metric].dropna().values
                if len(v1) >= 2 and len(v2) >= 2:
                    try:
                        _, p_val = scipy.stats.ttest_ind(v2, v1, equal_var=False)
                        if p_val < 0.05:
                            pair_sig.add(ch)
                    except Exception:
                        pass
            for c in posthoc_contrasts:
                p_val = c.get("p_adj", c.get("p_raw", 1.0))
                if p_val < 0.05:
                    cg1, cg2 = str(c.get("group1", "")), str(c.get("group2", ""))
                    if (cg1 == g1 and cg2 == g2) or (cg1 == g2 and cg2 == g1):
                        lvl = str(c.get("level", ""))
                        if lvl in matched:
                            pair_sig.add(lvl)

            _draw_head_topography(
                axes_grid[1, p_idx], xi, yi, mask, pts, matched, diff_vals,
                title=f"Post-Hoc: {g2} − {g1} (* p<0.05)",
                cmap="RdBu_r", vmin=-max_abs, vmax=max_abs,
                cbar_label=f"Δ {unit}".strip(),
                sig_channels=pair_sig,
            )

        for col_extra in range(len(contrast_pairs), ncols):
            axes_grid[1, col_extra].axis("off")

    clean_metric_title = metric.replace("_", " ")
    unit_suffix = f" ({unit})" if unit else ""
    sup_text = f"Scalp Topography & eTFCE Cluster Enhancement: {clean_metric_title}{unit_suffix}"
    fig.suptitle(textwrap.fill(sup_text, width=78), fontsize=11.5, fontweight="bold", y=1.02)
    plt.tight_layout()
    output_png_path.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(str(output_png_path), dpi=400, bbox_inches="tight", pad_inches=0.20)
    plt.close(fig)
    return output_png_path, etfce_info


# ─── JOURNAL-FRIENDLY DOCX SCIENTIFIC REPORT (COMPACT SIDE-BY-SIDE) ─────────

def _remove_docx_table_borders(table: Any) -> None:
    """Removes borders on a DOCX layout table used to place figures side-by-side."""
    try:
        tblPr = table._tbl.tblPr
        borders = parse_xml(
            f'<w:tblBorders {nsdecls("w")}>'
            '<w:top w:val="none" w:sz="0" w:space="0" w:color="auto"/>'
            '<w:left w:val="none" w:sz="0" w:space="0" w:color="auto"/>'
            '<w:bottom w:val="none" w:sz="0" w:space="0" w:color="auto"/>'
            '<w:right w:val="none" w:sz="0" w:space="0" w:color="auto"/>'
            '<w:insideH w:val="none" w:sz="0" w:space="0" w:color="auto"/>'
            '<w:insideV w:val="none" w:sz="0" w:space="0" w:color="auto"/>'
            '</w:tblBorders>'
        )
        tblPr.append(borders)
    except Exception:
        pass


def generate_docx_report(
    analysis_results: list[dict[str, Any]],
    meta_info: dict[str, Any],
    output_path: Path,
    plot_paths: dict[str, Path],
) -> Path:
    """Creates a publication-ready scientific Word document (.docx) with space-saving side-by-side figures."""
    if docx is None:
        return output_path

    doc = docx.Document()

    for section in doc.sections:
        section.top_margin = Inches(0.8)
        section.bottom_margin = Inches(0.8)
        section.left_margin = Inches(0.8)
        section.right_margin = Inches(0.8)

    style_normal = doc.styles["Normal"]
    style_normal.font.name = "Calibri"
    style_normal.font.size = Pt(10)
    style_normal.font.color.rgb = RGBColor(0x33, 0x33, 0x33)

    # ── Title & Header ─────────────────────────────────────────────────────
    title_p = doc.add_paragraph()
    title_p.paragraph_format.space_before = Pt(0)
    title_p.paragraph_format.space_after = Pt(4)
    run_title = title_p.add_run("Group-Level Statistical Analysis Report")
    run_title.font.name = "Calibri"
    run_title.font.size = Pt(20)
    run_title.font.bold = True
    run_title.font.color.rgb = RGBColor(0x1F, 0x4E, 0x79)

    sub_p = doc.add_paragraph()
    sub_p.paragraph_format.space_after = Pt(10)
    sub_run = sub_p.add_run(
        f"Sleep Neurophysiology & Macroarchitecture Cohort Comparison · "
        f"Generated: {datetime.datetime.now().strftime('%B %d, %Y at %H:%M')}\n"
        f"Source Dataset: {meta_info.get('source_csv_name', 'Master Sheet')} · "
        f"Cohorts: {meta_info.get('group_col')} · Sample Size: N = {meta_info.get('unique_subjects')} subjects ({meta_info.get('total_rows')} observations)"
    )
    sub_run.font.size = Pt(9)
    sub_run.font.italic = True
    sub_run.font.color.rgb = RGBColor(0x66, 0x66, 0x66)

    # ── 1. Executive Summary ───────────────────────────────────────────────
    h1 = doc.add_paragraph()
    h1.paragraph_format.space_before = Pt(10)
    h1.paragraph_format.space_after = Pt(4)
    r1 = h1.add_run("1. Executive Summary & Study Overview")
    r1.font.size = Pt(13)
    r1.font.bold = True
    r1.font.color.rgb = RGBColor(0x1F, 0x4E, 0x79)

    sig_metrics = [
        r["metric"] for r in analysis_results
        if any(e.get("p_value", 1.0) < 0.05 for e in r.get("model_effects", []))
    ]

    exec_p = doc.add_paragraph()
    exec_p.paragraph_format.line_spacing = 1.15
    exec_p.paragraph_format.space_after = Pt(6)
    subgrp_str = f", structured across within-subject factor {meta_info.get('subgroup_col')}" if meta_info.get("subgroup_col") else ""
    extra_facs = meta_info.get("extra_factors") or []
    extra_str = f" and additional factor(s) {', '.join(extra_facs)}" if extra_facs else ""
    exec_p.add_run(
        f"This report presents group-level comparative statistics on {len(analysis_results)} sleep EEG metrics "
        f"extracted across {meta_info.get('unique_subjects')} subjects ({meta_info.get('total_rows')} total observations). "
        f"The primary grouping factor evaluated was '{meta_info.get('group_col')}'{subgrp_str}{extra_str}. "
        f"A total of {len(sig_metrics)} metric(s) demonstrated statistically significant group main effects or interactions (p < 0.05): "
        f"{', '.join(sig_metrics[:10]) if sig_metrics else 'None reached statistical significance'}"
        f"{'...' if len(sig_metrics) > 10 else ''}."
    )

    # ── 2. Statistical Methodology ─────────────────────────────────────────
    h2 = doc.add_paragraph()
    h2.paragraph_format.space_before = Pt(10)
    h2.paragraph_format.space_after = Pt(4)
    r2 = h2.add_run("2. Statistical Methodology")
    r2.font.size = Pt(13)
    r2.font.bold = True
    r2.font.color.rgb = RGBColor(0x1F, 0x4E, 0x79)

    meth_p = doc.add_paragraph()
    meth_p.paragraph_format.line_spacing = 1.15
    meth_p.paragraph_format.space_after = Pt(8)
    meth_p.add_run(
        "Multi-channel / regional features and repeated-measures observations within subjects were analyzed via Linear Mixed-Effects Models (LMM) "
        "using Restricted Maximum Likelihood (REML) with random intercepts for subject clustering. "
        "Single-observation macroarchitectural metrics were evaluated via General Linear Models (GLM / ANOVA Type II). "
        "Effect sizes are reported as Partial Eta Squared (ηp²) for model terms and Cohen's d (with Hedges' g) for pairwise post-hoc contrasts. "
        "Topographic scalp maps include spatial Threshold-Free Cluster Enhancement (eTFCE, E=0.66, H=2.0) with permutation FWER control."
    )

    # ── 3. Detailed Results & Plots ─────────────────────────────────────────
    h3 = doc.add_paragraph()
    h3.paragraph_format.space_before = Pt(12)
    h3.paragraph_format.space_after = Pt(4)
    r3 = h3.add_run("3. Metric-by-Metric Statistical Results")
    r3.font.size = Pt(13)
    r3.font.bold = True
    r3.font.color.rgb = RGBColor(0x1F, 0x4E, 0x79)

    for idx, res in enumerate(analysis_results, start=1):
        metric = res["metric"]
        unit = res.get("unit") or infer_metric_unit(metric)
        clean_name = metric.replace("_", " ")
        unit_label = f" [{unit}]" if unit else ""

        mh = doc.add_paragraph()
        mh.paragraph_format.space_before = Pt(10)
        mh.paragraph_format.space_after = Pt(3)
        m_run = mh.add_run(
            f"3.{idx}  {clean_name}{unit_label} ({res['model_type']} · N={res.get('n_subjects', res['n_obs'])} subj, n={res['n_obs']} obs)"
        )
        m_run.font.size = Pt(11.5)
        m_run.font.bold = True
        m_run.font.color.rgb = RGBColor(0x2B, 0x5C, 0x8F)

        effects = res.get("model_effects", [])
        sig_effects = [e for e in effects if e.get("p_value", 1.0) < 0.05]
        narr_p = doc.add_paragraph()
        narr_p.paragraph_format.line_spacing = 1.12
        narr_p.paragraph_format.space_after = Pt(4)

        if sig_effects:
            eff_strs = [
                f"{e['term']} ({e['stat_type']} = {e['statistic']:.2f}, p = {format_p_value(e['p_value'])}, ηp² = {e.get('effect_size', 0.0):.3f})"
                for e in sig_effects
            ]
            narr_p.add_run(
                f"Significant effect(s) detected for {clean_name}: {'; '.join(eff_strs)}."
            )
        else:
            narr_p.add_run(
                f"No statistically significant group effects were observed for {clean_name} (all p > 0.05)."
            )

        plot_path = plot_paths.get(metric)
        topo_path = res.get("topoplot_path")
        has_plot = plot_path is not None and plot_path.exists()
        has_topo = topo_path is not None and Path(topo_path).exists()

        # Publication-ready figures with strictly preserved aspect ratio
        if has_plot and has_topo:
            p_a = doc.add_paragraph()
            p_a.alignment = WD_ALIGN_PARAGRAPH.CENTER
            p_a.paragraph_format.space_before = Pt(4)
            p_a.paragraph_format.space_after = Pt(2)
            p_a.add_run().add_picture(str(plot_path), width=Inches(5.4))

            c_a = doc.add_paragraph()
            c_a.alignment = WD_ALIGN_PARAGRAPH.CENTER
            c_a.paragraph_format.space_after = Pt(6)
            r_cap_a = c_a.add_run(f"Figure {idx}A: Group distribution & post-hoc contrasts ({clean_name}).")
            r_cap_a.font.size = Pt(8.5)
            r_cap_a.font.italic = True
            r_cap_a.font.color.rgb = RGBColor(0x66, 0x66, 0x66)

            p_b = doc.add_paragraph()
            p_b.alignment = WD_ALIGN_PARAGRAPH.CENTER
            p_b.paragraph_format.space_before = Pt(4)
            p_b.paragraph_format.space_after = Pt(2)
            p_b.add_run().add_picture(str(topo_path), width=Inches(6.6))

            c_b = doc.add_paragraph()
            c_b.alignment = WD_ALIGN_PARAGRAPH.CENTER
            c_b.paragraph_format.space_after = Pt(8)
            r_cap_b = c_b.add_run(f"Figure {idx}B: Scalp topography & spatial eTFCE cluster map ({clean_name}).")
            r_cap_b.font.size = Pt(8.5)
            r_cap_b.font.italic = True
            r_cap_b.font.color.rgb = RGBColor(0x66, 0x66, 0x66)
        elif has_plot:
            img_p = doc.add_paragraph()
            img_p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            img_p.paragraph_format.space_before = Pt(4)
            img_p.paragraph_format.space_after = Pt(2)
            img_p.add_run().add_picture(str(plot_path), width=Inches(5.4))

            cap_p = doc.add_paragraph()
            cap_p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            cap_p.paragraph_format.space_after = Pt(8)
            cap_run = cap_p.add_run(f"Figure {idx}: Distribution and post-hoc pairwise comparisons for {clean_name}.")
            cap_run.font.size = Pt(8.5)
            cap_run.font.italic = True
            cap_run.font.color.rgb = RGBColor(0x66, 0x66, 0x66)

        # Model Effects Table (with N and Effect Size ηp²)
        if effects:
            t_p = doc.add_paragraph()
            t_p.paragraph_format.space_before = Pt(4)
            t_p.paragraph_format.space_after = Pt(2)
            t_run = t_p.add_run(f"Table {idx}A: Model Fixed Effects & Effect Sizes for {clean_name}")
            t_run.font.bold = True
            t_run.font.size = Pt(9)

            headers = ["Factor / Term", "N (Subj/Obs)", "Stat", "Value", "df", "p-value", "Effect Size (ηp²)", "Sig."]
            table = doc.add_table(rows=len(effects) + 1, cols=len(headers))
            table.alignment = WD_TABLE_ALIGNMENT.CENTER
            for c_idx, h_text in enumerate(headers):
                cell = table.cell(0, c_idx)
                cell.text = h_text
                cell.paragraphs[0].runs[0].font.bold = True
                cell.paragraphs[0].runs[0].font.size = Pt(8.5)

            for r_idx, eff in enumerate(effects, start=1):
                n_str = f"{eff.get('n_subjects', res.get('n_subjects', '-'))} / {eff.get('n_obs', res.get('n_obs', '-'))}"
                stat_val = f"{eff.get('statistic', 0.0):.3f}"
                df_val = f"{eff.get('df', 1)}" + (f", {eff.get('df_resid')}" if eff.get("df_resid") else "")
                p_val_str = format_p_value(eff.get("p_value", 1.0))
                es = eff.get("effect_size")
                es_str = f"{es:.3f}" if es is not None and not math.isnan(float(es)) else "-"
                sig_str = eff.get("significance", "ns")

                row_data = [
                    eff.get("term", ""),
                    n_str,
                    eff.get("stat_type", ""),
                    stat_val,
                    df_val,
                    p_val_str,
                    es_str,
                    sig_str,
                ]
                for c_idx, val in enumerate(row_data):
                    cell = table.cell(r_idx, c_idx)
                    cell.text = val
                    if cell.paragraphs[0].runs:
                        cell.paragraphs[0].runs[0].font.size = Pt(8)

        # Compact Post-Hoc Contrasts Table (with n1, n2, and Cohen's d)
        contrasts = res.get("posthoc_contrasts", [])
        if contrasts:
            ph_p = doc.add_paragraph()
            ph_p.paragraph_format.space_before = Pt(4)
            ph_p.paragraph_format.space_after = Pt(2)
            ph_run = ph_p.add_run(f"Table {idx}B: Pairwise Post-Hoc Contrasts & Cohen's d for {clean_name}")
            ph_run.font.bold = True
            ph_run.font.size = Pt(9)

            ph_headers = ["Level", "Comparison", "n1 vs n2", "Mean Diff", "t-stat", "p (adj)", "Cohen's d", "Sig."]
            shown_contrasts = contrasts[:12]
            ph_table = doc.add_table(rows=len(shown_contrasts) + 1, cols=len(ph_headers))
            ph_table.alignment = WD_TABLE_ALIGNMENT.CENTER
            for c_idx, h_text in enumerate(ph_headers):
                cell = ph_table.cell(0, c_idx)
                cell.text = h_text
                cell.paragraphs[0].runs[0].font.bold = True
                cell.paragraphs[0].runs[0].font.size = Pt(8.5)

            for r_idx, c in enumerate(shown_contrasts, start=1):
                row_data = [
                    str(c.get("level", "Overall")),
                    f"{c.get('group1')} vs {c.get('group2')}",
                    f"{c.get('n1', '-')} vs {c.get('n2', '-')}",
                    f"{c.get('diff', 0.0):.3f}",
                    f"{c.get('t_stat', 0.0):.3f}",
                    format_p_value(c.get("p_adj", c.get("p_raw"))),
                    f"{c.get('cohen_d', 0.0):.2f}",
                    c.get("significance", "ns"),
                ]
                for c_idx, val in enumerate(row_data):
                    cell = ph_table.cell(r_idx, c_idx)
                    cell.text = val
                    if cell.paragraphs[0].runs:
                        cell.paragraphs[0].runs[0].font.size = Pt(8)

        doc.add_paragraph().paragraph_format.space_after = Pt(6)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    doc.save(str(output_path))
    return output_path


def _get_image_pixel_dimensions(image_path: Path | str) -> tuple[int, int]:
    """Reads pixel width and height safely from image file."""
    try:
        from PIL import Image as PILImage
        with PILImage.open(image_path) as im:
            return int(im.size[0]), int(im.size[1])
    except Exception:
        pass
    try:
        with open(image_path, "rb") as f:
            header = f.read(24)
            if len(header) >= 24 and header[:8] == b"\x89PNG\r\n\x1a\n":
                import struct
                w, h = struct.unpack(">II", header[16:24])
                return int(w), int(h)
    except Exception:
        pass
    return 1600, 1200


def _make_aspect_preserved_rl_image(
    image_path: Path | str,
    max_width_pt: float,
    max_height_pt: float,
) -> Any:
    """Creates a ReportLab Image Flowable with strictly preserved native aspect ratio."""
    if RLImage is None:
        return None
    w_px, h_px = _get_image_pixel_dimensions(image_path)
    aspect = max(1e-4, float(w_px) / max(1e-4, float(h_px)))
    target_w = max_width_pt
    target_h = target_w / aspect
    if target_h > max_height_pt:
        target_h = max_height_pt
        target_w = target_h * aspect
    return RLImage(str(image_path), width=target_w, height=target_h)


# ─── PUBLICATION PDF SCIENTIFIC REPORT (PROPORTIONAL HIGH-RES) ──────────────

def generate_pdf_report(
    analysis_results: list[dict[str, Any]],
    meta_info: dict[str, Any],
    output_path: Path,
    plot_paths: dict[str, Path],
) -> Path:
    """Creates a publication-ready scientific PDF report using ReportLab with side-by-side figures."""
    if SimpleDocTemplate is None:
        return output_path

    doc = SimpleDocTemplate(
        str(output_path),
        pagesize=letter,
        rightMargin=36,
        leftMargin=36,
        topMargin=36,
        bottomMargin=36,
    )

    styles = getSampleStyleSheet()
    title_style = ParagraphStyle(
        "RepTitle",
        parent=styles["Normal"],
        fontName="Helvetica-Bold",
        fontSize=18,
        leading=22,
        textColor=colors.HexColor("#1F4E79"),
        spaceAfter=3,
    )
    subtitle_style = ParagraphStyle(
        "RepSubtitle",
        parent=styles["Normal"],
        fontName="Helvetica-Oblique",
        fontSize=8.5,
        leading=11,
        textColor=colors.HexColor("#666666"),
        spaceAfter=10,
    )
    h1_style = ParagraphStyle(
        "RepH1",
        parent=styles["Normal"],
        fontName="Helvetica-Bold",
        fontSize=12.5,
        leading=15,
        textColor=colors.HexColor("#1F4E79"),
        spaceBefore=10,
        spaceAfter=4,
    )
    h2_style = ParagraphStyle(
        "RepH2",
        parent=styles["Normal"],
        fontName="Helvetica-Bold",
        fontSize=10.5,
        leading=13,
        textColor=colors.HexColor("#2B5C8F"),
        spaceBefore=8,
        spaceAfter=3,
    )
    body_style = ParagraphStyle(
        "RepBody",
        parent=styles["Normal"],
        fontName="Helvetica",
        fontSize=9,
        leading=12,
        textColor=colors.HexColor("#333333"),
        spaceAfter=6,
    )
    caption_style = ParagraphStyle(
        "RepCaption",
        parent=styles["Normal"],
        fontName="Helvetica-Oblique",
        fontSize=7.5,
        leading=9.5,
        alignment=1,
        textColor=colors.HexColor("#666666"),
        spaceAfter=6,
    )

    story = []

    story.append(Paragraph("Group-Level Statistical Analysis Report", title_style))
    story.append(Paragraph(
        f"Sleep Neurophysiology & Macroarchitecture Cohort Comparison · "
        f"Generated: {datetime.datetime.now().strftime('%B %d, %Y at %H:%M')}<br/>"
        f"Source Dataset: {meta_info.get('source_csv_name', 'Master Sheet')} · "
        f"Cohort: {meta_info.get('group_col')} · Sample Size: N = {meta_info.get('unique_subjects')} subjects ({meta_info.get('total_rows')} obs)",
        subtitle_style,
    ))
    story.append(HRFlowable(width="100%", thickness=1.2, color=colors.HexColor("#1F4E79"), spaceAfter=8))

    story.append(Paragraph("1. Executive Summary & Methodology", h1_style))
    sig_count = sum(
        1 for r in analysis_results
        if any(e.get("p_value", 1.0) < 0.05 for e in r.get("model_effects", []))
    )
    subgrp_pdf = f", structured across repeated factor <b>{meta_info.get('subgroup_col')}</b>" if meta_info.get("subgroup_col") else ""
    story.append(Paragraph(
        f"Group-level comparative statistics across <b>{len(analysis_results)}</b> sleep metrics "
        f"derived from <b>{meta_info.get('unique_subjects')}</b> subjects ({meta_info.get('total_rows')} observations). "
        f"Primary grouping factor: <b>{meta_info.get('group_col')}</b>{subgrp_pdf}. "
        f"<b>{sig_count}</b> metric(s) demonstrated statistically significant group effects (p &lt; 0.05). "
        f"Models use REML Linear Mixed-Effects (LMM) for repeated measures and Type-II GLM/ANOVA for single-observation metrics, "
        f"reporting Partial Eta Squared (ηp²), Cohen's d, and spatial eTFCE scalp topography.",
        body_style,
    ))

    story.append(Paragraph("2. Metric Statistical Results & Publication Plots", h1_style))

    for idx, res in enumerate(analysis_results, start=1):
        metric = res["metric"]
        unit = res.get("unit") or infer_metric_unit(metric)
        clean_name = metric.replace("_", " ")
        unit_label = f" [{unit}]" if unit else ""
        story.append(Paragraph(
            f"2.{idx} {clean_name}{unit_label} ({res['model_type']} · N={res.get('n_subjects', res['n_obs'])} subj, n={res['n_obs']} obs)",
            h2_style,
        ))

        plot_path = plot_paths.get(metric)
        topo_path = res.get("topoplot_path")
        has_plot = plot_path is not None and plot_path.exists()
        has_topo = topo_path is not None and Path(topo_path).exists()

        # High-resolution publication figures with strictly preserved aspect ratio
        if has_plot and has_topo:
            img_a = _make_aspect_preserved_rl_image(plot_path, max_width_pt=5.4 * inch, max_height_pt=3.7 * inch)
            cap_a = Paragraph(f"Figure {idx}A: Group distribution & post-hoc pairwise contrasts ({clean_name}).", caption_style)
            if img_a:
                story.append(img_a)
                story.append(cap_a)

            img_b = _make_aspect_preserved_rl_image(topo_path, max_width_pt=6.8 * inch, max_height_pt=2.2 * inch)
            cap_b = Paragraph(f"Figure {idx}B: Scalp topography & spatial eTFCE cluster map ({clean_name}).", caption_style)
            if img_b:
                story.append(img_b)
                story.append(cap_b)
        elif has_plot:
            img_a = _make_aspect_preserved_rl_image(plot_path, max_width_pt=5.6 * inch, max_height_pt=3.8 * inch)
            cap_a = Paragraph(f"Figure {idx}: Distribution and post-hoc pairwise significance for {clean_name}.", caption_style)
            if img_a:
                story.append(img_a)
                story.append(cap_a)

        # Model Effects Table (with N and Effect Size ηp²)
        effects = res.get("model_effects", [])
        if effects:
            table_data = [["Factor / Term", "N (Subj/Obs)", "Stat", "Statistic", "df", "p-value", "ηp²", "Sig."]]
            for eff in effects:
                es = eff.get("effect_size")
                es_str = f"{es:.3f}" if es is not None and not math.isnan(float(es)) else "-"
                table_data.append([
                    eff.get("term", ""),
                    f"{eff.get('n_subjects', res.get('n_subjects', '-'))}/{eff.get('n_obs', res.get('n_obs', '-'))}",
                    eff.get("stat_type", ""),
                    f"{eff.get('statistic', 0.0):.3f}",
                    f"{eff.get('df', 1)}" + (f", {eff.get('df_resid')}" if eff.get("df_resid") else ""),
                    format_p_value(eff.get("p_value", 1.0)),
                    es_str,
                    eff.get("significance", "ns"),
                ])
            t = Table(table_data, colWidths=[150, 62, 38, 54, 48, 56, 48, 38])
            t.setStyle(TableStyle([
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#f0f4f8")),
                ("TEXTCOLOR", (0, 0), (-1, 0), colors.HexColor("#1F4E79")),
                ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
                ("FONTSIZE", (0, 0), (-1, -1), 7.5),
                ("ALIGN", (1, 0), (-1, -1), "CENTER"),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 2.5),
                ("TOPPADDING", (0, 0), (-1, -1), 2.5),
                ("LINEABOVE", (0, 0), (-1, 0), 1.0, colors.HexColor("#1F4E79")),
                ("LINEBELOW", (0, 0), (-1, 0), 0.8, colors.HexColor("#1F4E79")),
                ("LINEBELOW", (0, -1), (-1, -1), 1.0, colors.HexColor("#1F4E79")),
            ]))
            story.append(t)
            story.append(Spacer(1, 4))

        # Post-Hoc Contrasts Table (with n1 vs n2 and Cohen's d)
        contrasts = res.get("posthoc_contrasts", [])
        if contrasts:
            ph_data = [["Level", "Comparison", "n1 vs n2", "Mean Diff", "t-stat", "p (adj)", "Cohen's d", "Sig."]]
            for c in contrasts[:10]:
                ph_data.append([
                    str(c.get("level", "Overall")),
                    f"{c.get('group1')} vs {c.get('group2')}",
                    f"{c.get('n1', '-')} vs {c.get('n2', '-')}",
                    f"{c.get('diff', 0.0):.3f}",
                    f"{c.get('t_stat', 0.0):.3f}",
                    format_p_value(c.get("p_adj", c.get("p_raw"))),
                    f"{c.get('cohen_d', 0.0):.2f}",
                    c.get("significance", "ns"),
                ])
            pt = Table(ph_data, colWidths=[85, 115, 58, 56, 48, 54, 52, 36])
            pt.setStyle(TableStyle([
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#f8f9fa")),
                ("TEXTCOLOR", (0, 0), (-1, 0), colors.HexColor("#2B5C8F")),
                ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
                ("FONTSIZE", (0, 0), (-1, -1), 7.2),
                ("ALIGN", (1, 0), (-1, -1), "CENTER"),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
                ("TOPPADDING", (0, 0), (-1, -1), 2),
                ("LINEABOVE", (0, 0), (-1, 0), 0.8, colors.HexColor("#2B5C8F")),
                ("LINEBELOW", (0, 0), (-1, 0), 0.5, colors.HexColor("#2B5C8F")),
                ("LINEBELOW", (0, -1), (-1, -1), 0.8, colors.HexColor("#2B5C8F")),
            ]))
            story.append(pt)
            story.append(Spacer(1, 8))

    output_path.parent.mkdir(parents=True, exist_ok=True)
    doc.build(story)
    return output_path


# ─── MAIN ORCHESTRATION ─────────────────────────────────────────────────────

def load_and_merge_cap_sidecars(df: pd.DataFrame, csv_path: Path) -> pd.DataFrame:
    """Discovers companion *_cap.json files beside regional CSV or recording files and merges CAP metrics."""
    if any(c.startswith("CAP_") for c in df.columns):
        return df

    cap_candidates = []
    stem = csv_path.name
    if stem.lower().endswith("_analyse_regional.csv"):
        base_stem = stem[:-len("_analyse_regional.csv")]
        clean_base = re.sub(r"(_clean|_stimclean|_cleaned|_preprocessed)$", "", base_stem, flags=re.I)
        cap_candidates.extend([
            csv_path.parent / f"{base_stem}_cap.json",
            csv_path.parent / f"{clean_base}_cap.json",
        ])
    else:
        stem_no_ext = csv_path.stem
        cap_candidates.append(csv_path.parent / f"{stem_no_ext}_cap.json")

    for cand in cap_candidates:
        if cand.exists():
            try:
                with open(cand, "r", encoding="utf-8") as f:
                    cap_data = json.load(f)
                summary = cap_data.get("summary", {})
                if summary:
                    for k, v in summary.items():
                        col = k if k.upper().startswith("CAP_") else f"CAP_{k}"
                        df[col] = v
                    break
            except Exception:
                pass

    return df


def run_group_analysis(
    csv_path: Path,
    output_dir: Path | None = None,
    metadata_csv_path: Path | None = None,
    metadata_key_col: str | None = None,
    group_col: str | None = None,
    subgroup_col: str | None = None,
    channel_col: str | None = None,
    extra_factors: list[str] | None = None,
    include_interactions: bool = True,
    covariates: list[str] | None = None,
    subject_id: str | None = None,
    metrics: list[str] | None = None,
    exclude_labels: dict[str, list[str]] | None = None,
    row_filters: list[dict[str, Any]] | None = None,
    group_order: list[str] | None = None,
    subgroup_order: list[str] | None = None,
    preferred_model: str = "auto",
    posthoc_method: str = "fdr",
    report_format: str = "both",  # 'docx', 'pdf', 'both'
    emit_json: bool = True,
) -> dict[str, Any]:
    """Runs the complete group-level analysis pipeline."""
    df = pd.read_csv(csv_path)
    df = df.loc[:, ~df.columns.duplicated()].copy()
    df = load_and_merge_cap_sidecars(df, csv_path)

    # Optional metadata merge
    if metadata_csv_path and metadata_csv_path.exists():
        try:
            m_df = pd.read_csv(metadata_csv_path) if metadata_csv_path.suffix.lower() == ".csv" else pd.read_excel(metadata_csv_path)
            m_key = metadata_key_col or m_df.columns[0]
            key_in_df = None
            for c in df.columns:
                if c.lower() in (m_key.lower(), "subject identifier", "subject_code", "source_file"):
                    key_in_df = c
                    break
            if key_in_df:
                df = pd.merge(df, m_df, left_on=key_in_df, right_on=m_key, how="left")
        except Exception as e:
            sys.stderr.write(f"Warning: Failed to merge metadata: {e}\n")

    # Apply interactive factor label exclusions and row value filters
    df = apply_data_filters(df, exclude_labels=exclude_labels, row_filters=row_filters)

    col_lookup = {c.lower(): c for c in df.columns}
    def _resolve_col(name: str | None) -> str | None:
        if not name or name == "None":
            return None
        if name in df.columns:
            return name
        nl = name.lower().strip()
        if nl in col_lookup:
            return col_lookup[nl]
        if nl in ("region", "channel", "chan") and "subsubjname" in col_lookup:
            return col_lookup["subsubjname"]
        return None

    detected = detect_columns(df)
    final_subject_id = _resolve_col(subject_id) or detected["subject_id"]
    final_group_col = _resolve_col(group_col) or detected["group_col"]
    final_subgroup_col = _resolve_col(subgroup_col) if subgroup_col != "None" else None
    if subgroup_col is None:
        final_subgroup_col = detected["subgroup_col"]
    if final_subgroup_col == final_group_col:
        final_subgroup_col = None
    final_channel_col = _resolve_col(channel_col) or detected.get("channel_col")
    final_covariates = covariates if covariates is not None else detected["covariates"]
    final_extra_factors = [
        resolved for f in (extra_factors or [])
        if (resolved := _resolve_col(f)) is not None
        and resolved not in (final_group_col, final_subgroup_col, final_subject_id)
    ]

    if not final_group_col or final_group_col not in df.columns:
        raise ValueError(f"Could not determine valid grouping column in {csv_path.name}")

    available_metrics = detected["metric_columns"]
    if not metrics or metrics == ["auto"] or metrics == ["all"]:
        prioritized = [
            "Sleep_efficiency", "TST", "WASO", "SOL", "N3_percentage", "R_percentage",
            "sp_Count", "sp_Duration", "sp_Amplitude", "sp_Frequency",
            "sw_Count", "sw_Density", "sw_Duration", "sw_Amplitude",
            "N3_Sigma_PSD", "N3_Delta_PSD", "N3_Theta_PSD", "CAP_rate", "CAP_A_index"
        ]
        target_metrics = [m for m in prioritized if m in available_metrics]
        if len(target_metrics) < 4:
            target_metrics = available_metrics[:15]
    else:
        target_metrics = [m for m in metrics if m in df.columns]

    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    if output_dir:
        out_root = output_dir
    else:
        out_root = csv_path.parent / f"GroupStats_{timestamp}"
    out_root.mkdir(parents=True, exist_ok=True)
    plots_dir = out_root / "plots"
    plots_dir.mkdir(parents=True, exist_ok=True)

    analysis_results: list[dict[str, Any]] = []
    plot_paths: dict[str, Path] = {}
    all_model_effects: list[dict[str, Any]] = []
    all_posthoc_contrasts: list[dict[str, Any]] = []
    all_descriptives: list[dict[str, Any]] = []

    # Check topoplot feasibility across channel column or fallback candidates
    topo_channel_col = final_channel_col or final_subgroup_col
    is_topo_feasible = False
    if topo_channel_col and topo_channel_col in df.columns:
        channels_in_df = [str(c) for c in df[topo_channel_col].dropna().unique()]
        is_topo_feasible, _ = check_topoplot_suitability(channels_in_df)
    if not is_topo_feasible:
        # Check if any column in df is a channel/region column
        for cand_col in df.columns:
            if cand_col.lower().strip() in ("subsubjname", "chan", "channel", "region", "electrode", "derivation", "roi"):
                ch_cand = [str(c) for c in df[cand_col].dropna().unique()]
                ok, _ = check_topoplot_suitability(ch_cand)
                if ok:
                    is_topo_feasible = True
                    topo_channel_col = cand_col
                    if not final_channel_col:
                        final_channel_col = cand_col
                    break

    total_metrics = len(target_metrics)
    for idx, m in enumerate(target_metrics):
        fraction = (idx + 1) / max(1, total_metrics)
        clean_name = m.replace("_", " ")
        sys.stderr.write(f"PROGRESS {fraction:.2f} Analyzing {idx+1}/{total_metrics}: {clean_name}\n")
        sys.stderr.flush()

        res = fit_statistical_model(
            df=df,
            metric=m,
            group_col=final_group_col,
            subgroup_col=final_subgroup_col,
            channel_col=final_channel_col,
            extra_factors=final_extra_factors,
            include_interactions=include_interactions,
            covariates=final_covariates,
            subject_id=final_subject_id,
            group_order=group_order,
            subgroup_order=subgroup_order,
            preferred_model=preferred_model,
            posthoc_method=posthoc_method,
        )
        if res:
            analysis_results.append(res)
            plot_file = plots_dir / f"{m}_plot.png"
            generate_publication_plot(res, df, plot_file)
            plot_paths[m] = plot_file

            if is_topo_feasible and topo_channel_col and not res.get("is_macroarchitecture", False):
                topo_file = plots_dir / f"{m}_topoplot.png"
                topo_res, etfce_info = generate_topoplot(
                    raw_df=df,
                    metric=m,
                    group_col=final_group_col,
                    channel_col=topo_channel_col,
                    posthoc_contrasts=res.get("posthoc_contrasts", []),
                    output_png_path=topo_file,
                    group_order=group_order,
                )
                if topo_res and topo_res.exists():
                    res["topoplot_path"] = str(topo_res)
                if etfce_info:
                    res["etfce_channels"] = etfce_info.get("channel_details", [])

            for eff in res.get("model_effects", []):
                all_model_effects.append({"metric": m, **eff})
            for ph in res.get("posthoc_contrasts", []):
                all_posthoc_contrasts.append({"metric": m, **ph})
            for ds in res.get("descriptive_stats", []):
                all_descriptives.append({"metric": m, **ds})

    if all_descriptives:
        pd.DataFrame(all_descriptives).to_csv(out_root / f"descriptive_statistics_{timestamp}.csv", index=False)
    if all_model_effects:
        pd.DataFrame(all_model_effects).to_csv(out_root / f"model_effects_{timestamp}.csv", index=False)
    if all_posthoc_contrasts:
        pd.DataFrame(all_posthoc_contrasts).to_csv(out_root / f"posthoc_comparisons_{timestamp}.csv", index=False)

    meta_summary = {
        "source_csv_name": csv_path.name,
        "source_csv_path": str(csv_path),
        "output_dir": str(out_root),
        "timestamp": timestamp,
        "group_col": final_group_col,
        "subgroup_col": final_subgroup_col,
        "extra_factors": final_extra_factors,
        "covariates": final_covariates,
        "subject_id": final_subject_id,
        "total_rows": len(df),
        "unique_subjects": int(df[final_subject_id].nunique(dropna=True)) if final_subject_id and final_subject_id in df.columns else len(df),
        "metrics_analyzed": len(analysis_results),
    }

    docx_file = None
    pdf_file = None
    if report_format in ("docx", "both"):
        docx_file = out_root / f"Group_Statistical_Report_{timestamp}.docx"
        generate_docx_report(analysis_results, meta_summary, docx_file, plot_paths)

    if report_format in ("pdf", "both"):
        pdf_file = out_root / f"Group_Statistical_Report_{timestamp}.pdf"
        generate_pdf_report(analysis_results, meta_summary, pdf_file, plot_paths)

    json_results = []
    for r in analysis_results:
        clean_r = {k: v for k, v in r.items() if k != "data_sample"}
        clean_r["plot_path"] = str(plot_paths.get(r["metric"], ""))
        if "topoplot_path" in r:
            clean_r["topoplot_path"] = str(r["topoplot_path"])
        json_results.append(clean_r)

    final_payload = {
        "status": "success",
        "metadata": meta_summary,
        "output_dir": str(out_root),
        "docx_path": str(docx_file) if docx_file and docx_file.exists() else None,
        "pdf_path": str(pdf_file) if pdf_file and pdf_file.exists() else None,
        "results": json_results,
    }

    with open(out_root / f"group_stats_summary_{timestamp}.json", "w", encoding="utf-8") as f:
        json.dump(final_payload, f, indent=2)

    return final_payload


def main() -> None:
    parser = argparse.ArgumentParser(description="CCS Sleep Studio Group Statistical Analysis Engine")
    parser.add_argument("--csv", help="Input master analysis sheet CSV")
    parser.add_argument("--output-dir", help="Output directory for reports and plots")
    parser.add_argument("--metadata-csv", help="Optional metadata CSV/XLSX to merge")
    parser.add_argument("--metadata-key", help="Key column to join metadata")
    parser.add_argument("--group", help="Primary grouping column")
    parser.add_argument("--subgroup", help="Secondary / within-subject factor")
    parser.add_argument("--channel-col", "--channel-factor", dest="channel_col", help="Column containing channel/region/electrode labels for spatial topography and channel-invariance exclusion")
    parser.add_argument("--extra-factors", help="Comma-separated additional categorical factor columns")
    parser.add_argument("--no-interactions", action="store_true", help="Fit main effects only without interaction terms")
    parser.add_argument("--covariates", help="Comma-separated covariate column names")
    parser.add_argument("--subject-id", help="Subject identifier column")
    parser.add_argument("--metrics", help="Comma-separated metric column names")
    parser.add_argument("--exclude-labels", help="JSON dict mapping factor column -> list of labels to exclude")
    parser.add_argument("--row-filters", help="JSON list of row filter objects [{column, op, value}]")
    parser.add_argument("--group-order", help="Comma-separated or JSON list specifying primary group plot order")
    parser.add_argument("--subgroup-order", help="Comma-separated or JSON list specifying subgroup plot order")
    parser.add_argument("--model", choices=["auto", "lmm", "glm"], default="auto")
    parser.add_argument("--posthoc", choices=["fdr", "tukey", "bonferroni"], default="fdr")
    parser.add_argument("--report-format", choices=["docx", "pdf", "both"], default="both")
    parser.add_argument("--inspect-only", action="store_true", help="Only inspect columns and return JSON")
    parser.add_argument("--config", help="Path to JSON configuration file")

    args = parser.parse_args()

    def _parse_order(raw: str | None) -> list[str] | None:
        if not raw:
            return None
        s = raw.strip()
        if s.startswith("["):
            try:
                return [str(x) for x in json.loads(s)]
            except Exception:
                pass
        return [x.strip() for x in s.split(",") if x.strip()]

    if args.config:
        with open(args.config, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        csv_file = Path(cfg["csv"])
        inspect_only = cfg.get("inspect_only", False)
        out_dir = Path(cfg["output_dir"]) if cfg.get("output_dir") else None
        meta_csv = Path(cfg["metadata_csv"]) if cfg.get("metadata_csv") else None
        meta_key = cfg.get("metadata_key")
        grp = cfg.get("group")
        subgrp = cfg.get("subgroup")
        chan_col = cfg.get("channel_col")
        extra_facs = cfg.get("extra_factors", [])
        inc_inter = cfg.get("include_interactions", True)
        covs = cfg.get("covariates", [])
        subjid = cfg.get("subject_id")
        mets = cfg.get("metrics")
        excl_labels = cfg.get("exclude_labels")
        r_filters = cfg.get("row_filters")
        grp_order = cfg.get("group_order")
        subgrp_order = cfg.get("subgroup_order")
        model = cfg.get("model", "auto")
        posthoc = cfg.get("posthoc", "fdr")
        rep_fmt = cfg.get("report_format", "both")
    else:
        if not args.csv:
            parser.print_help()
            sys.exit(1)
        csv_file = Path(args.csv)
        inspect_only = args.inspect_only
        out_dir = Path(args.output_dir) if args.output_dir else None
        meta_csv = Path(args.metadata_csv) if args.metadata_csv else None
        meta_key = args.metadata_key
        grp = args.group
        subgrp = args.subgroup
        chan_col = args.channel_col
        extra_facs = [c.strip() for c in args.extra_factors.split(",") if c.strip()] if args.extra_factors else []
        inc_inter = not args.no_interactions
        covs = [c.strip() for c in args.covariates.split(",") if c.strip()] if args.covariates else []
        subjid = args.subject_id
        mets = [m.strip() for m in args.metrics.split(",") if m.strip()] if args.metrics else None
        excl_labels = json.loads(args.exclude_labels) if args.exclude_labels else None
        r_filters = json.loads(args.row_filters) if args.row_filters else None
        grp_order = _parse_order(args.group_order)
        subgrp_order = _parse_order(args.subgroup_order)
        model = args.model
        posthoc = args.posthoc
        rep_fmt = args.report_format

    if not csv_file.exists():
        sys.stderr.write(f"Error: CSV file not found: {csv_file}\n")
        sys.exit(1)

    if inspect_only:
        df = pd.read_csv(csv_file)
        df = df.loc[:, ~df.columns.duplicated()].copy()
        df = load_and_merge_cap_sidecars(df, csv_file)
        if meta_csv and meta_csv.exists():
            try:
                m_df = pd.read_csv(meta_csv) if meta_csv.suffix.lower() == ".csv" else pd.read_excel(meta_csv)
                m_key = meta_key or m_df.columns[0]
                key_in_df = None
                for c in df.columns:
                    if c.lower() in (m_key.lower(), "subject identifier", "subject_code", "source_file"):
                        key_in_df = c
                        break
                if key_in_df:
                    df = pd.merge(df, m_df, left_on=key_in_df, right_on=m_key, how="left")
            except Exception:
                pass
        df = apply_data_filters(df, exclude_labels=excl_labels, row_filters=r_filters)
        detected = detect_columns(df)
        categorized = categorize_metrics(detected["metric_columns"])
        detected["categorized_metrics"] = categorized
        print(json.dumps(detected, indent=2))
        return

    payload = run_group_analysis(
        csv_path=csv_file,
        output_dir=out_dir,
        metadata_csv_path=meta_csv,
        metadata_key_col=meta_key,
        group_col=grp,
        subgroup_col=subgrp,
        channel_col=chan_col,
        extra_factors=extra_facs,
        include_interactions=inc_inter,
        covariates=covs,
        subject_id=subjid,
        metrics=mets,
        exclude_labels=excl_labels,
        row_filters=r_filters,
        group_order=grp_order,
        subgroup_order=subgrp_order,
        preferred_model=model,
        posthoc_method=posthoc,
        report_format=rep_fmt,
        emit_json=True,
    )
    print(json.dumps(payload, indent=2))


if __name__ == "__main__":
    main()
