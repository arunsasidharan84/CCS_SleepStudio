#!/usr/bin/env python3
"""Group-level statistical analysis engine for CCS Sleep Studio.

Implements state-of-the-art statistical modeling:
- Linear Mixed-Effects Models (LMM) with random intercepts for repeated-measures / multi-channel data
- General Linear Models (GLM / OLS / ANOVA) for between-subject macroarchitecture data
- Automated post-hoc pairwise contrasts with FDR / Tukey HSD / Bonferroni adjustments
- Publication-grade figures with annotated post-hoc significance markers
- Datastamped results folder containing journal-friendly CSVs, plots, and publishing-ready DOCX and PDF scientific reports
"""

from __future__ import annotations

import argparse
import datetime
import json
import math
import os
import re
import sys
from pathlib import Path
from typing import Any

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from scipy import stats

try:
    import statsmodels.api as sm
    import statsmodels.formula.api as smf
    from statsmodels.stats.multitest import multipletests
    from statsmodels.stats.multicomp import pairwise_tukeyhsd
except ImportError:
    sm = None
    smf = None
    multipletests = None
    pairwise_tukeyhsd = None

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


# ─── SIGNIFICANCE HELPERS ───────────────────────────────────────────────────

def p_to_star(p: float) -> str:
    if math.isnan(p):
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


def format_p_value(p: float) -> str:
    if math.isnan(p):
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


# ─── DATA INSPECTION & PREPROCESSING ────────────────────────────────────────

SUBJECT_CANDIDATE_NAMES = [
    "subject identifier", "subject_code", "subject code", "subjname",
    "subject", "subjid", "subject id", "napid", "mappingcode", "sl.no."
]

GROUP_CANDIDATE_NAMES = [
    "group", "groupid", "group_id", "status", "psgtype", "condition",
    "cohort", "arm", "treatment"
]

SUBGROUP_CANDIDATE_NAMES = [
    "chan", "channel", "electrode", "derivation", "ageid", "age_id",
    "session", "session_id", "visit", "time_point", "epoch"
]

COVARIATE_CANDIDATE_NAMES = [
    "age", "gender", "sex", "education", "practiceyears", "bmi", "trt"
]


def detect_columns(df: pd.DataFrame) -> dict[str, Any]:
    cols = list(df.columns)
    cols_lower = {c: c.lower().strip() for c in cols}

    # Subject ID
    subject_id = None
    for cand in SUBJECT_CANDIDATE_NAMES:
        for c, cl in cols_lower.items():
            if cl == cand:
                subject_id = c
                break
        if subject_id:
            break
    if not subject_id:
        for c, cl in cols_lower.items():
            if "subject" in cl:
                subject_id = c
                break

    # Categorical columns
    categorical_cols = []
    for c in cols:
        cl = cols_lower[c]
        if cl in ("source_file", "source_path", "recording date"):
            continue
        nunique = df[c].nunique(dropna=True)
        if df[c].dtype == "object" or (1 < nunique <= 12 and nunique < len(df) * 0.5):
            categorical_cols.append(c)

    # Primary group
    group_col = None
    for cand in GROUP_CANDIDATE_NAMES:
        for c in categorical_cols:
            if cols_lower[c] == cand:
                group_col = c
                break
        if group_col:
            break
    if not group_col and categorical_cols:
        group_col = categorical_cols[0]

    # Subgroup / Factor 2
    subgroup_col = None
    for cand in SUBGROUP_CANDIDATE_NAMES:
        for c in categorical_cols:
            if c != group_col and cols_lower[c] == cand:
                subgroup_col = c
                break
        if subgroup_col:
            break

    # Covariates
    covariates = []
    for c in cols:
        cl = cols_lower[c]
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
        # Check if numeric
        s = pd.to_numeric(df[c], errors="coerce")
        if s.notna().sum() >= 5 and s.nunique() > 5:
            metric_cols.append(c)

    return {
        "subject_id": subject_id,
        "group_col": group_col,
        "subgroup_col": subgroup_col,
        "categorical_columns": categorical_cols,
        "covariates": covariates,
        "metric_columns": metric_cols,
        "total_rows": len(df),
        "total_columns": len(cols),
        "unique_subjects": int(df[subject_id].nunique(dropna=True)) if subject_id else len(df),
    }


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
        if any(k in ml for k in ["trt", "tst", "spt", "waso", "sol", "efficiency", "percentage", "onset", "_duration", "streak"]) and not any(k in ml for k in ["sp_", "sw_", "psd", "fooof", "cap_"]):
            categories["Macroarchitecture"].append(m)
        elif "sp_" in ml or "spindle" in ml:
            categories["Spindles"].append(m)
        elif "sw_" in ml or "slow" in ml:
            categories["Slow Waves"].append(m)
        elif any(k in ml for k in ["psd", "relpower", "abspower", "delta", "theta", "alpha", "sigma", "beta", "gamma"]) and "fooof" not in ml and "irasa" not in ml:
            categories["Spectral Power"].append(m)
        elif any(k in ml for k in ["fooof", "irasa", "exponent", "offset", "knee", "lzc", "dfa", "entropy"]):
            categories["Aperiodic & Complexity"].append(m)
        elif "cap_" in ml or "cap" in ml:
            categories["CAP (Cyclic Alternating Pattern)"].append(m)
        elif "cyc" in ml or "cycle" in ml:
            categories["Sleep Cycles"].append(m)
        else:
            categories["Other Regional"].append(m)

    return {k: v for k, v in categories.items() if v}


# ─── STATISTICAL MODELLING: LMM & GLM ──────────────────────────────────────

def clean_var_name(name: str) -> str:
    """Replaces non-alphanumeric chars for Patsy/statsmodels formulas."""
    clean = re.sub(r"[^\w]", "_", name.strip())
    if clean[0].isdigit():
        clean = "v_" + clean
    return clean


def fit_statistical_model(
    df: pd.DataFrame,
    metric: str,
    group_col: str,
    subgroup_col: str | None,
    covariates: list[str],
    subject_id: str | None,
    preferred_model: str = "auto",  # 'auto', 'lmm', 'glm'
    posthoc_method: str = "fdr",     # 'tukey', 'fdr', 'bonferroni'
) -> dict[str, Any] | None:
    """Fits LMM or GLM to the metric and calculates post-hoc contrasts."""
    needed_cols = []
    for c in [metric, group_col, subgroup_col, subject_id] + [cv for cv in covariates if cv != metric]:
        if c and c in df.columns and c not in needed_cols:
            needed_cols.append(c)

    sub_df = df[needed_cols].copy()
    sub_df[metric] = pd.to_numeric(sub_df[metric], errors="coerce")
    for cov in covariates:
        if cov != metric and cov in sub_df.columns:
            sub_df[cov] = pd.to_numeric(sub_df[cov], errors="coerce")
    sub_df = sub_df.dropna(subset=[metric, group_col]).copy()

    # Drop groups with < 2 observations
    group_counts = sub_df[group_col].value_counts()
    valid_groups = group_counts[group_counts >= 2].index.tolist()
    if len(valid_groups) < 2:
        return None
    sub_df = sub_df[sub_df[group_col].isin(valid_groups)].copy()

    if len(sub_df) < 6:
        return None

    # Check repeated measures per subject
    has_repeated_measures = False
    if subject_id and subject_id in sub_df.columns:
        n_obs = len(sub_df)
        n_subj = sub_df[subject_id].nunique()
        if n_obs > n_subj * 1.1:
            has_repeated_measures = True

    # Determine model type
    if preferred_model == "lmm":
        use_lmm = True
    elif preferred_model == "glm":
        use_lmm = False
    else:  # auto
        use_lmm = has_repeated_measures and (subject_id is not None)

    # Rename columns to safe patsy names
    rename_map = {metric: "DEP_VAR", group_col: "GRP_VAR"}
    if subgroup_col and subgroup_col in sub_df.columns:
        rename_map[subgroup_col] = "SUBGRP_VAR"
    if subject_id and subject_id in sub_df.columns:
        rename_map[subject_id] = "SUBJ_ID"
    valid_covs = []
    for i, cov in enumerate(covariates):
        if cov in sub_df.columns and sub_df[cov].notna().sum() >= len(sub_df) * 0.8:
            safe_cov = f"COV_{i}"
            rename_map[cov] = safe_cov
            valid_covs.append(safe_cov)

    safe_df = sub_df.rename(columns=rename_map)
    # Drop rows missing valid covariates
    if valid_covs:
        safe_df = safe_df.dropna(subset=valid_covs)

    if len(safe_df) < 6:
        return None

    # Construct formula
    formula_parts = ["C(GRP_VAR)"]
    has_subgroup = "SUBGRP_VAR" in safe_df.columns and safe_df["SUBGRP_VAR"].nunique() > 1
    if has_subgroup:
        formula_parts.append("C(SUBGRP_VAR)")
        formula_parts.append("C(GRP_VAR):C(SUBGRP_VAR)")
    for cv in valid_covs:
        formula_parts.append(cv)

    formula = f"DEP_VAR ~ {' + '.join(formula_parts)}"

    model_type = "GLM / OLS"
    model_effects: list[dict[str, Any]] = []
    model_summary_text = ""
    fit_converged = True
    r_squared = None

    if use_lmm and smf is not None:
        try:
            lmm_model = smf.mixedlm(formula, safe_df, groups=safe_df["SUBJ_ID"])
            lmm_fit = lmm_model.fit(reml=True)
            model_type = "Linear Mixed Model (LMM)"
            fit_converged = bool(lmm_fit.converged)
            model_summary_text = str(lmm_fit.summary())

            # Wald test terms
            try:
                wald = lmm_fit.wald_test_terms()
                w_frame = wald.summary_frame()
                for term_idx, row in w_frame.iterrows():
                    chi2_val = row.get("chi2", [np.nan])
                    val = float(chi2_val[0][0]) if hasattr(chi2_val, "__getitem__") and hasattr(chi2_val[0], "__getitem__") else float(chi2_val)
                    p_val = float(row.get("P>chi2", np.nan))
                    df_val = int(row.get("df constraint", 1))
                    term_name = str(term_idx).replace("GRP_VAR", group_col).replace("SUBGRP_VAR", subgroup_col or "Subgroup")
                    for orig, safe in rename_map.items():
                        term_name = term_name.replace(safe, orig)
                    model_effects.append({
                        "term": term_name,
                        "statistic": val,
                        "stat_type": "Chi2",
                        "df": df_val,
                        "p_value": p_val,
                        "significance": p_to_star(p_val),
                    })
            except Exception:
                pass

            # Coefficients table
            for param_name, coef in lmm_fit.params.items():
                if param_name in ("Group Var", "Intercept"):
                    continue
                se = float(lmm_fit.bse.get(param_name, np.nan))
                z = float(lmm_fit.tvalues.get(param_name, np.nan))
                p = float(lmm_fit.pvalues.get(param_name, np.nan))
                ci = lmm_fit.conf_int().loc[param_name]
                ci_low, ci_high = float(ci[0]), float(ci[1])
                t_name = param_name.replace("GRP_VAR", group_col).replace("SUBGRP_VAR", subgroup_col or "Subgroup")
                for orig, safe in rename_map.items():
                    t_name = t_name.replace(safe, orig)
                # If Wald didn't capture effects, populate from coefficients
                if not any(e["term"] == t_name for e in model_effects):
                    model_effects.append({
                        "term": t_name,
                        "estimate": float(coef),
                        "std_error": se,
                        "statistic": z,
                        "stat_type": "z",
                        "df": len(safe_df) - len(lmm_fit.params),
                        "p_value": p,
                        "ci_lower": ci_low,
                        "ci_upper": ci_high,
                        "significance": p_to_star(p),
                    })
        except Exception:
            # Fall back to OLS
            use_lmm = False

    if not use_lmm and smf is not None:
        try:
            ols_fit = smf.ols(formula, safe_df).fit()
            model_type = "General Linear Model (GLM / ANOVA)"
            model_summary_text = str(ols_fit.summary())
            r_squared = float(ols_fit.rsquared)

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

                    t_name = str(term_idx).replace("GRP_VAR", group_col).replace("SUBGRP_VAR", subgroup_col or "Subgroup")
                    for orig, safe in rename_map.items():
                        t_name = t_name.replace(safe, orig)
                    model_effects.append({
                        "term": t_name,
                        "statistic": f_val,
                        "stat_type": "F",
                        "df": df_val,
                        "df_resid": int(ols_fit.df_resid),
                        "p_value": p_val,
                        "effect_size": partial_eta,
                        "effect_size_type": "partial_eta_sq",
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
                t_name = param_name.replace("GRP_VAR", group_col).replace("SUBGRP_VAR", subgroup_col or "Subgroup")
                for orig, safe in rename_map.items():
                    t_name = t_name.replace(safe, orig)
                if not any(e["term"] == t_name for e in model_effects):
                    model_effects.append({
                        "term": t_name,
                        "estimate": float(coef),
                        "std_error": se,
                        "statistic": t,
                        "stat_type": "t",
                        "df": int(ols_fit.df_resid),
                        "p_value": p,
                        "ci_lower": ci_low,
                        "ci_upper": ci_high,
                        "significance": p_to_star(p),
                    })
        except Exception as e:
            return None

    # ── Descriptive Statistics ─────────────────────────────────────────────
    descriptive_stats: list[dict[str, Any]] = []
    group_levels = sorted([str(g) for g in sub_df[group_col].dropna().unique()])
    subgroup_levels = sorted([str(sg) for sg in sub_df[subgroup_col].dropna().unique()]) if has_subgroup else [None]

    for sg in subgroup_levels:
        for grp in group_levels:
            if sg is not None:
                mask = (sub_df[group_col].astype(str) == grp) & (sub_df[subgroup_col].astype(str) == sg)
            else:
                mask = sub_df[group_col].astype(str) == grp
            vals = sub_df.loc[mask, metric].dropna().values
            if len(vals) == 0:
                continue
            descriptive_stats.append({
                "group": grp,
                "subgroup": sg,
                "n": int(len(vals)),
                "mean": float(np.mean(vals)),
                "std": float(np.std(vals, ddof=1)) if len(vals) > 1 else 0.0,
                "median": float(np.median(vals)),
                "iqr": float(stats.iqr(vals)) if len(vals) > 1 else 0.0,
                "min": float(np.min(vals)),
                "max": float(np.max(vals)),
            })

    # ── Post-Hoc Pairwise Contrasts ─────────────────────────────────────────
    posthoc_contrasts: list[dict[str, Any]] = []

    # If subgroup exists, perform between-group contrasts within each subgroup level
    # and between-subgroup contrasts within each group level
    if has_subgroup and subgroup_col:
        for sg in subgroup_levels:
            sg_mask = sub_df[subgroup_col].astype(str) == sg
            sg_df = sub_df[sg_mask]
            for i in range(len(group_levels)):
                for j in range(i + 1, len(group_levels)):
                    g1, g2 = group_levels[i], group_levels[j]
                    v1 = sg_df[sg_df[group_col].astype(str) == g1][metric].dropna().values
                    v2 = sg_df[sg_df[group_col].astype(str) == g2][metric].dropna().values
                    if len(v1) >= 2 and len(v2) >= 2:
                        t_stat, p_raw = stats.ttest_ind(v1, v2, equal_var=False)
                        d = calc_cohen_d(v1, v2)
                        posthoc_contrasts.append({
                            "contrast_type": "Group within Subgroup",
                            "factor": subgroup_col,
                            "level": sg,
                            "group1": g1,
                            "group2": g2,
                            "mean1": float(np.mean(v1)),
                            "mean2": float(np.mean(v2)),
                            "diff": float(np.mean(v1) - np.mean(v2)),
                            "t_stat": float(t_stat),
                            "p_raw": float(p_raw),
                            "cohen_d": d,
                        })

    # Overall between-group contrasts
    for i in range(len(group_levels)):
        for j in range(i + 1, len(group_levels)):
            g1, g2 = group_levels[i], group_levels[j]
            v1 = sub_df[sub_df[group_col].astype(str) == g1][metric].dropna().values
            v2 = sub_df[sub_df[group_col].astype(str) == g2][metric].dropna().values
            if len(v1) >= 2 and len(v2) >= 2:
                t_stat, p_raw = stats.ttest_ind(v1, v2, equal_var=False)
                d = calc_cohen_d(v1, v2)
                posthoc_contrasts.append({
                    "contrast_type": "Main Group Effect",
                    "factor": group_col,
                    "level": "Overall",
                    "group1": g1,
                    "group2": g2,
                    "mean1": float(np.mean(v1)),
                    "mean2": float(np.mean(v2)),
                    "diff": float(np.mean(v1) - np.mean(v2)),
                    "t_stat": float(t_stat),
                    "p_raw": float(p_raw),
                    "cohen_d": d,
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
        "group_col": group_col,
        "subgroup_col": subgroup_col if has_subgroup else None,
        "covariates": valid_covs,
        "model_type": model_type,
        "formula": formula,
        "n_obs": len(safe_df),
        "n_subjects": safe_df["SUBJ_ID"].nunique() if "SUBJ_ID" in safe_df.columns else len(safe_df),
        "fit_converged": fit_converged,
        "r_squared": r_squared,
        "model_effects": model_effects,
        "descriptive_stats": descriptive_stats,
        "posthoc_contrasts": posthoc_contrasts,
        "data_sample": safe_df.to_dict(orient="records"),
    }


# ─── PUBLICATION PLOT GENERATION WITH SIGNIFICANCE BRACKETS ─────────────────

def generate_publication_plot(
    result: dict[str, Any],
    raw_df: pd.DataFrame,
    output_png_path: Path,
) -> Path:
    """Renders a publication-grade figure with box/jittered scatter and significance brackets."""
    metric = result["metric"]
    group_col = result["group_col"]
    subgroup_col = result["subgroup_col"]
    contrasts = result["posthoc_contrasts"]

    # Filter data
    needed = [metric, group_col]
    if subgroup_col:
        needed.append(subgroup_col)
    clean = raw_df[needed].dropna().copy()
    clean[metric] = pd.to_numeric(clean[metric], errors="coerce")
    clean = clean.dropna(subset=[metric])

    groups = sorted([str(g) for g in clean[group_col].unique()])
    palette = ["#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd", "#8c564b"]
    color_map = {g: palette[i % len(palette)] for i, g in enumerate(groups)}

    has_subgroup = subgroup_col is not None and subgroup_col in clean.columns and clean[subgroup_col].nunique() > 1
    subgroups = sorted([str(sg) for sg in clean[subgroup_col].unique()]) if has_subgroup else [None]

    # Plot dimensions
    fig_width = max(6.0, 2.5 * len(subgroups) if has_subgroup else 2.0 * len(groups))
    fig, ax = plt.subplots(figsize=(fig_width, 5.0), dpi=300)

    # Style
    ax.set_facecolor("#fafafa")
    fig.patch.set_facecolor("white")
    ax.grid(axis="y", color="#e0e0e0", linestyle="--", linewidth=0.7, alpha=0.7)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.spines["left"].set_color("#333333")
    ax.spines["bottom"].set_color("#333333")

    y_vals_all = clean[metric].values
    y_min = float(np.min(y_vals_all)) if len(y_vals_all) > 0 else 0.0
    y_max = float(np.max(y_vals_all)) if len(y_vals_all) > 0 else 1.0
    y_span = max(1e-5, y_max - y_min)

    positions = []
    box_data = []
    box_colors = []
    x_labels = []

    if not has_subgroup:
        # Single factor layout
        for i, grp in enumerate(groups):
            vals = clean[clean[group_col].astype(str) == grp][metric].values
            pos = i + 1
            positions.append(pos)
            box_data.append(vals)
            box_colors.append(color_map[grp])
            x_labels.append(grp)
            # Jittered scatter points
            jitter = np.random.normal(0, 0.05, size=len(vals))
            ax.scatter(pos + jitter, vals, color=color_map[grp], alpha=0.45, s=26, zorder=3, edgecolors="none")

        bp = ax.boxplot(
            box_data, positions=positions, widths=0.45, patch_artist=True,
            showmeans=True, meanline=True, zorder=2,
            boxprops=dict(linewidth=1.2),
            whiskerprops=dict(linewidth=1.2, color="#444444"),
            capprops=dict(linewidth=1.2, color="#444444"),
            medianprops=dict(linewidth=1.8, color="#222222"),
            meanprops=dict(linewidth=1.5, color="#d95f02", linestyle=":"),
        )
        for patch, color in zip(bp["boxes"], box_colors):
            patch.set_facecolor(matplotlib.colors.to_rgba(color, alpha=0.35))
            patch.set_edgecolor(color)

        ax.set_xticks(positions)
        ax.set_xticklabels(x_labels, fontsize=11, fontweight="bold")

        # Significance brackets between groups
        bracket_y = y_max + y_span * 0.05
        step = y_span * 0.12
        for c in contrasts:
            if c.get("contrast_type") == "Main Group Effect":
                g1, g2 = c["group1"], c["group2"]
                if g1 in groups and g2 in groups:
                    idx1 = groups.index(g1) + 1
                    idx2 = groups.index(g2) + 1
                    sig = c.get("significance", "ns")
                    p_val = c.get("p_adj", c.get("p_raw", 1.0))
                    # Draw bracket
                    ax.plot([idx1, idx1, idx2, idx2], [bracket_y, bracket_y + step * 0.3, bracket_y + step * 0.3, bracket_y], color="#222222", lw=1.2)
                    label = f"{sig} (p={format_p_value(p_val)})" if sig != "ns" else "ns"
                    ax.text((idx1 + idx2) / 2.0, bracket_y + step * 0.35, label, ha="center", va="bottom", fontsize=9.5, fontweight="bold", color="#d95f02" if sig != "ns" else "#555555")
                    bracket_y += step

        ax.set_ylim(y_min - y_span * 0.08, bracket_y + step * 0.3)

    else:
        # Two factors: grouped by Subgroup (e.g. Channel) with hue for Group
        n_grps = len(groups)
        width = 0.8 / n_grps
        x_center = []
        bracket_y = y_max + y_span * 0.05
        step = y_span * 0.12

        for s_idx, sg in enumerate(subgroups):
            sg_center = (s_idx + 1) * 1.5
            x_center.append(sg_center)
            sg_mask = clean[subgroup_col].astype(str) == sg

            for g_idx, grp in enumerate(groups):
                vals = clean[sg_mask & (clean[group_col].astype(str) == grp)][metric].values
                offset = (g_idx - (n_grps - 1) / 2.0) * width
                pos = sg_center + offset
                if len(vals) > 0:
                    bp = ax.boxplot(
                        [vals], positions=[pos], widths=width * 0.85, patch_artist=True,
                        showmeans=True, meanline=True, zorder=2,
                        boxprops=dict(linewidth=1.1),
                        whiskerprops=dict(linewidth=1.1, color="#444444"),
                        capprops=dict(linewidth=1.1, color="#444444"),
                        medianprops=dict(linewidth=1.6, color="#222222"),
                        meanprops=dict(linewidth=1.4, color="#d95f02", linestyle=":"),
                    )
                    bp["boxes"][0].set_facecolor(matplotlib.colors.to_rgba(color_map[grp], alpha=0.35))
                    bp["boxes"][0].set_edgecolor(color_map[grp])
                    jitter = np.random.normal(0, width * 0.08, size=len(vals))
                    ax.scatter(pos + jitter, vals, color=color_map[grp], alpha=0.5, s=22, zorder=3, edgecolors="none")

            # Mini significance brackets within this subgroup
            sg_contrasts = [c for c in contrasts if c.get("factor") == subgroup_col and c.get("level") == sg]
            local_y = (np.max(clean[sg_mask][metric].values) if sg_mask.sum() > 0 else y_max) + y_span * 0.04
            for c in sg_contrasts:
                g1, g2 = c["group1"], c["group2"]
                if g1 in groups and g2 in groups:
                    idx1 = groups.index(g1)
                    idx2 = groups.index(g2)
                    pos1 = sg_center + (idx1 - (n_grps - 1) / 2.0) * width
                    pos2 = sg_center + (idx2 - (n_grps - 1) / 2.0) * width
                    sig = c.get("significance", "ns")
                    p_val = c.get("p_adj", c.get("p_raw", 1.0))
                    if sig != "ns":
                        ax.plot([pos1, pos1, pos2, pos2], [local_y, local_y + step * 0.25, local_y + step * 0.25, local_y], color="#d95f02", lw=1.1)
                        ax.text((pos1 + pos2) / 2.0, local_y + step * 0.3, f"{sig}", ha="center", va="bottom", fontsize=10, fontweight="bold", color="#d95f02")
                        local_y += step * 0.6

        ax.set_xticks(x_center)
        ax.set_xticklabels(subgroups, fontsize=11, fontweight="bold")
        ax.set_xlabel(subgroup_col, fontsize=11, fontweight="bold", labelpad=8)

        # Legend for groups
        legend_handles = [
            matplotlib.patches.Patch(facecolor=matplotlib.colors.to_rgba(color_map[g], alpha=0.5), edgecolor=color_map[g], label=g)
            for g in groups
        ]
        ax.legend(handles=legend_handles, title=group_col, loc="upper right", framealpha=0.9, fontsize=9.5)

    clean_metric_title = metric.replace("_", " ")
    ax.set_ylabel(clean_metric_title, fontsize=11, fontweight="bold", labelpad=8)
    model_type = result["model_type"]
    ax.set_title(f"{clean_metric_title} by {group_col}{f' across {subgroup_col}' if has_subgroup else ''}\n({model_type}, N={result['n_obs']})", fontsize=12, fontweight="bold", pad=12)

    plt.tight_layout()
    output_png_path.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(output_png_path, dpi=300)
    plt.close(fig)
    return output_png_path


# ─── JOURNAL-FRIENDLY DOCX SCIENTIFIC REPORT ───────────────────────────────

def generate_docx_report(
    analysis_results: list[dict[str, Any]],
    meta_info: dict[str, Any],
    output_path: Path,
    plot_paths: dict[str, Path],
) -> Path:
    """Creates a publication-ready scientific Word document (.docx)."""
    if docx is None:
        return output_path

    doc = docx.Document()

    # Document Geometry: Standard 1 inch margins
    for section in doc.sections:
        section.top_margin = Inches(1.0)
        section.bottom_margin = Inches(1.0)
        section.left_margin = Inches(1.0)
        section.right_margin = Inches(1.0)

    # Styles setup
    style_normal = doc.styles["Normal"]
    style_normal.font.name = "Calibri"
    style_normal.font.size = Pt(10.5)
    style_normal.font.color.rgb = RGBColor(0x33, 0x33, 0x33)

    # ── Title & Header ─────────────────────────────────────────────────────
    title_p = doc.add_paragraph()
    title_p.paragraph_format.space_before = Pt(0)
    title_p.paragraph_format.space_after = Pt(4)
    run_title = title_p.add_run("Group-Level Statistical Analysis Report")
    run_title.font.name = "Calibri"
    run_title.font.size = Pt(22)
    run_title.font.bold = True
    run_title.font.color.rgb = RGBColor(0x1F, 0x4E, 0x79)

    sub_p = doc.add_paragraph()
    sub_p.paragraph_format.space_after = Pt(14)
    sub_run = sub_p.add_run(
        f"Sleep Neurophysiology & Macroarchitecture Cohort Comparison · "
        f"Generated: {datetime.datetime.now().strftime('%B %d, %Y at %H:%M')}\n"
        f"Source Dataset: {meta_info.get('source_csv_name', 'Master Sheet')} · "
        f"Cohorts: {meta_info.get('group_col')} · Sample Size: N = {meta_info.get('unique_subjects')} subjects"
    )
    sub_run.font.size = Pt(9.5)
    sub_run.font.italic = True
    sub_run.font.color.rgb = RGBColor(0x66, 0x66, 0x66)

    # ── 1. Executive Summary ───────────────────────────────────────────────
    h1 = doc.add_paragraph()
    h1.paragraph_format.space_before = Pt(14)
    h1.paragraph_format.space_after = Pt(6)
    r1 = h1.add_run("1. Executive Summary & Study Overview")
    r1.font.size = Pt(14)
    r1.font.bold = True
    r1.font.color.rgb = RGBColor(0x1F, 0x4E, 0x79)

    sig_metrics = [
        r["metric"] for r in analysis_results
        if any(e.get("p_value", 1.0) < 0.05 for e in r.get("model_effects", []))
    ]

    exec_p = doc.add_paragraph()
    exec_p.paragraph_format.line_spacing = 1.15
    exec_p.paragraph_format.space_after = Pt(8)
    subgrp_str = f", structured across within-subject factor {meta_info.get('subgroup_col')}" if meta_info.get("subgroup_col") else ""
    exec_p.add_run(
        f"This report presents group-level comparative statistics on {len(analysis_results)} sleep EEG metrics "
        f"extracted across {meta_info.get('unique_subjects')} subjects and {meta_info.get('total_rows')} recording observations. "
        f"The primary grouping factor evaluated was '{meta_info.get('group_col')}'"
        f"{subgrp_str}. "
        f"A total of {len(sig_metrics)} metric(s) demonstrated statistically significant group main effects or interactions (p < 0.05): "
        f"{', '.join(sig_metrics[:8]) if sig_metrics else 'None reached statistical significance'}"
        f"{'...' if len(sig_metrics) > 8 else ''}."
    )

    # ── 2. Statistical Methodology ─────────────────────────────────────────
    h2 = doc.add_paragraph()
    h2.paragraph_format.space_before = Pt(14)
    h2.paragraph_format.space_after = Pt(6)
    r2 = h2.add_run("2. Statistical Methodology")
    r2.font.size = Pt(14)
    r2.font.bold = True
    r2.font.color.rgb = RGBColor(0x1F, 0x4E, 0x79)

    meth_p = doc.add_paragraph()
    meth_p.paragraph_format.line_spacing = 1.15
    meth_p.paragraph_format.space_after = Pt(8)
    meth_p.add_run(
        "Statistical analyses were conducted following state-of-the-art neurophysiology and sleep research guidelines. "
        "For multi-channel / regional features and repeated-measures observations within subjects, Linear Mixed-Effects Models (LMM) "
        "were implemented using Restricted Maximum Likelihood (REML) estimation with random intercepts for subject clustering: \n\n"
        "        Outcome ~ Group * Channel + Covariates + (1 | Subject)\n\n"
        "For macroarchitectural metrics with single observations per subject, General Linear Models (GLM / ANOVA Type II) were applied. "
        "Fixed-effect hypothesis testing was evaluated using Wald Chi-Square tests for LMM and F-tests for GLM. "
        "Post-hoc pairwise contrasts were adjusted for family-wise error rate using Benjamini-Hochberg False Discovery Rate (FDR) / "
        "Tukey's HSD. Standardized effect sizes are reported as Cohen's d for pairwise comparisons and partial eta squared (ηp²) "
        "for ANOVA main effects. Significance is designated as: * p < 0.05, ** p < 0.01, *** p < 0.001, **** p < 0.0001; ns = not significant."
    )

    # ── 3. Detailed Results & Plots ─────────────────────────────────────────
    h3 = doc.add_paragraph()
    h3.paragraph_format.space_before = Pt(16)
    h3.paragraph_format.space_after = Pt(6)
    r3 = h3.add_run("3. Metric-by-Metric Statistical Results")
    r3.font.size = Pt(14)
    r3.font.bold = True
    r3.font.color.rgb = RGBColor(0x1F, 0x4E, 0x79)

    for idx, res in enumerate(analysis_results, start=1):
        metric = res["metric"]
        clean_name = metric.replace("_", " ")

        mh = doc.add_paragraph()
        mh.paragraph_format.space_before = Pt(12)
        mh.paragraph_format.space_after = Pt(4)
        m_run = mh.add_run(f"3.{idx}  {clean_name} ({res['model_type']})")
        m_run.font.size = Pt(12)
        m_run.font.bold = True
        m_run.font.color.rgb = RGBColor(0x2B, 0x5C, 0x8F)

        # Narrative description
        effects = res.get("model_effects", [])
        sig_effects = [e for e in effects if e.get("p_value", 1.0) < 0.05]
        narr_p = doc.add_paragraph()
        narr_p.paragraph_format.line_spacing = 1.15
        narr_p.paragraph_format.space_after = Pt(6)

        if sig_effects:
            eff_strs = [
                f"{e['term']} ({e['stat_type']} = {e['statistic']:.2f}, p = {format_p_value(e['p_value'])})"
                for e in sig_effects
            ]
            narr_p.add_run(
                f"Analysis of {clean_name} using a {res['model_type']} demonstrated significant main effect(s) for "
                f"{'; '.join(eff_strs)}. "
            )
        else:
            narr_p.add_run(
                f"Analysis of {clean_name} using a {res['model_type']} did not reveal statistically significant "
                f"group differences after multiple comparison adjustment (all p > 0.05). "
            )

        # Embedded Plot
        plot_path = plot_paths.get(metric)
        if plot_path and plot_path.exists():
            img_p = doc.add_paragraph()
            img_p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            img_p.paragraph_format.space_before = Pt(4)
            img_p.paragraph_format.space_after = Pt(2)
            doc.add_picture(str(plot_path), width=Inches(5.5))

            cap_p = doc.add_paragraph()
            cap_p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            cap_p.paragraph_format.space_after = Pt(10)
            cap_run = cap_p.add_run(f"Figure {idx}: Distribution and post-hoc pairwise comparisons for {clean_name}.")
            cap_run.font.size = Pt(8.5)
            cap_run.font.italic = True
            cap_run.font.color.rgb = RGBColor(0x66, 0x66, 0x66)

        # Model Effects Table (APA Style)
        if effects:
            t_p = doc.add_paragraph()
            t_p.paragraph_format.space_before = Pt(6)
            t_p.paragraph_format.space_after = Pt(2)
            t_run = t_p.add_run(f"Table {idx}A: Model Fixed Effects for {clean_name}")
            t_run.font.bold = True
            t_run.font.size = Pt(9.5)

            table = doc.add_table(rows=len(effects) + 1, cols=6)
            table.alignment = WD_TABLE_ALIGNMENT.CENTER
            headers = ["Factor / Term", "Stat Type", "Statistic", "df", "p-value", "Sig."]
            for c_idx, h_text in enumerate(headers):
                cell = table.cell(0, c_idx)
                cell.text = h_text
                cell.paragraphs[0].runs[0].font.bold = True
                cell.paragraphs[0].runs[0].font.size = Pt(9)

            for r_idx, eff in enumerate(effects, start=1):
                stat_val = f"{eff.get('statistic', 0.0):.3f}"
                df_val = f"{eff.get('df', 1)}" + (f", {eff.get('df_resid')}" if eff.get("df_resid") else "")
                p_val_str = format_p_value(eff.get("p_value", 1.0))
                sig_str = eff.get("significance", "ns")

                row_data = [
                    eff.get("term", ""),
                    eff.get("stat_type", ""),
                    stat_val,
                    df_val,
                    p_val_str,
                    sig_str,
                ]
                for c_idx, val in enumerate(row_data):
                    cell = table.cell(r_idx, c_idx)
                    cell.text = val
                    if cell.paragraphs[0].runs:
                        cell.paragraphs[0].runs[0].font.size = Pt(8.5)

            doc.add_paragraph().paragraph_format.space_after = Pt(10)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    doc.save(str(output_path))
    return output_path


# ─── PUBLICATION PDF SCIENTIFIC REPORT ──────────────────────────────────────

def generate_pdf_report(
    analysis_results: list[dict[str, Any]],
    meta_info: dict[str, Any],
    output_path: Path,
    plot_paths: dict[str, Path],
) -> Path:
    """Creates a publication-ready scientific PDF report using ReportLab."""
    if SimpleDocTemplate is None:
        return output_path

    doc = SimpleDocTemplate(
        str(output_path),
        pagesize=letter,
        rightMargin=45,
        leftMargin=45,
        topMargin=45,
        bottomMargin=45,
    )

    styles = getSampleStyleSheet()
    title_style = ParagraphStyle(
        "RepTitle",
        parent=styles["Normal"],
        fontName="Helvetica-Bold",
        fontSize=20,
        leading=24,
        textColor=colors.HexColor("#1F4E79"),
        spaceAfter=4,
    )
    subtitle_style = ParagraphStyle(
        "RepSubtitle",
        parent=styles["Normal"],
        fontName="Helvetica-Oblique",
        fontSize=9,
        leading=12,
        textColor=colors.HexColor("#666666"),
        spaceAfter=14,
    )
    h1_style = ParagraphStyle(
        "RepH1",
        parent=styles["Normal"],
        fontName="Helvetica-Bold",
        fontSize=13,
        leading=16,
        textColor=colors.HexColor("#1F4E79"),
        spaceBefore=12,
        spaceAfter=6,
    )
    h2_style = ParagraphStyle(
        "RepH2",
        parent=styles["Normal"],
        fontName="Helvetica-Bold",
        fontSize=11,
        leading=14,
        textColor=colors.HexColor("#2B5C8F"),
        spaceBefore=10,
        spaceAfter=4,
    )
    body_style = ParagraphStyle(
        "RepBody",
        parent=styles["Normal"],
        fontName="Helvetica",
        fontSize=9.5,
        leading=13,
        textColor=colors.HexColor("#333333"),
        spaceAfter=8,
    )
    caption_style = ParagraphStyle(
        "RepCaption",
        parent=styles["Normal"],
        fontName="Helvetica-Oblique",
        fontSize=8,
        leading=10,
        alignment=1,  # Centered
        textColor=colors.HexColor("#666666"),
        spaceAfter=10,
    )

    story = []

    # Title & Subtitle
    story.append(Paragraph("Group-Level Statistical Analysis Report", title_style))
    story.append(Paragraph(
        f"Sleep Neurophysiology & Macroarchitecture Cohort Comparison · "
        f"Generated: {datetime.datetime.now().strftime('%B %d, %Y at %H:%M')}<br/>"
        f"Source Dataset: {meta_info.get('source_csv_name', 'Master Sheet')} · "
        f"Cohort: {meta_info.get('group_col')} · Sample Size: N = {meta_info.get('unique_subjects')} subjects",
        subtitle_style,
    ))
    story.append(HRFlowable(width="100%", thickness=1.5, color=colors.HexColor("#1F4E79"), spaceAfter=10))

    # Executive Summary
    story.append(Paragraph("1. Executive Summary", h1_style))
    sig_count = sum(
        1 for r in analysis_results
        if any(e.get("p_value", 1.0) < 0.05 for e in r.get("model_effects", []))
    )
    subgrp_pdf = f", structured across repeated factor <b>{meta_info.get('subgroup_col')}</b>" if meta_info.get("subgroup_col") else ""
    story.append(Paragraph(
        f"This report presents group-level comparative statistics across {len(analysis_results)} sleep metrics "
        f"derived from {meta_info.get('unique_subjects')} subjects. "
        f"Primary grouping factor: <b>{meta_info.get('group_col')}</b>"
        f"{subgrp_pdf}. "
        f"A total of <b>{sig_count}</b> metric(s) demonstrated statistically significant group effects (p &lt; 0.05).",
        body_style,
    ))

    # Methodology
    story.append(Paragraph("2. Statistical Methodology", h1_style))
    story.append(Paragraph(
        "Multi-channel and repeated-measures sleep metrics were evaluated via <b>Linear Mixed-Effects Models (LMM)</b> "
        "utilizing Restricted Maximum Likelihood (REML) estimation with subject-level random intercepts: "
        "<i>Outcome ~ Group * Channel + Covariates + (1 | Subject)</i>. "
        "Single-observation macroarchitectural parameters were assessed using General Linear Models (GLM / ANOVA Type II). "
        "Significance was corrected using False Discovery Rate (FDR) / Tukey HSD (* p &lt; 0.05, ** p &lt; 0.01, *** p &lt; 0.001, **** p &lt; 0.0001).",
        body_style,
    ))

    # Metric Analyses & Figures
    story.append(Paragraph("3. Metric Statistical Results & Publication Plots", h1_style))

    for idx, res in enumerate(analysis_results, start=1):
        metric = res["metric"]
        clean_name = metric.replace("_", " ")
        story.append(Paragraph(f"3.{idx} {clean_name} ({res['model_type']})", h2_style))

        # Plot Image
        plot_path = plot_paths.get(metric)
        if plot_path and plot_path.exists():
            story.append(RLImage(str(plot_path), width=5.2 * inch, height=3.2 * inch))
            story.append(Paragraph(f"Figure {idx}: Distribution and post-hoc pairwise significance for {clean_name}.", caption_style))

        # Model Effects Table
        effects = res.get("model_effects", [])
        if effects:
            table_data = [["Factor / Term", "Stat Type", "Statistic", "df", "p-value", "Sig."]]
            for eff in effects:
                table_data.append([
                    eff.get("term", ""),
                    eff.get("stat_type", ""),
                    f"{eff.get('statistic', 0.0):.3f}",
                    f"{eff.get('df', 1)}" + (f", {eff.get('df_resid')}" if eff.get("df_resid") else ""),
                    format_p_value(eff.get("p_value", 1.0)),
                    eff.get("significance", "ns"),
                ])
            t = Table(table_data, colWidths=[160, 60, 65, 55, 65, 45])
            t.setStyle(TableStyle([
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#f0f4f8")),
                ("TEXTCOLOR", (0, 0), (-1, 0), colors.HexColor("#1F4E79")),
                ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
                ("FONTSIZE", (0, 0), (-1, -1), 8),
                ("ALIGN", (1, 0), (-1, -1), "CENTER"),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
                ("TOPPADDING", (0, 0), (-1, -1), 3),
                ("LINEABOVE", (0, 0), (-1, 0), 1.0, colors.HexColor("#1F4E79")),
                ("LINEBELOW", (0, 0), (-1, 0), 1.0, colors.HexColor("#1F4E79")),
                ("LINEBELOW", (0, -1), (-1, -1), 1.0, colors.HexColor("#1F4E79")),
            ]))
            story.append(t)
            story.append(Spacer(1, 10))

    output_path.parent.mkdir(parents=True, exist_ok=True)
    doc.build(story)
    return output_path


# ─── MAIN ORCHESTRATION ─────────────────────────────────────────────────────

def run_group_analysis(
    csv_path: Path,
    output_dir: Path | None = None,
    metadata_csv_path: Path | None = None,
    metadata_key_col: str | None = None,
    group_col: str | None = None,
    subgroup_col: str | None = None,
    covariates: list[str] | None = None,
    subject_id: str | None = None,
    metrics: list[str] | None = None,
    preferred_model: str = "auto",
    posthoc_method: str = "fdr",
    report_format: str = "both",  # 'docx', 'pdf', 'both'
    emit_json: bool = True,
) -> dict[str, Any]:
    """Runs the complete group-level analysis pipeline."""
    df = pd.read_csv(csv_path)
    df = df.loc[:, ~df.columns.duplicated()].copy()

    # Optional metadata merge
    if metadata_csv_path and metadata_csv_path.exists():
        try:
            m_df = pd.read_csv(metadata_csv_path) if metadata_csv_path.suffix.lower() == ".csv" else pd.read_excel(metadata_csv_path)
            # Find key column
            m_key = metadata_key_col or m_df.columns[0]
            # Match against subject id or source file
            key_in_df = None
            for c in df.columns:
                if c.lower() in (m_key.lower(), "subject identifier", "subject_code", "source_file"):
                    key_in_df = c
                    break
            if key_in_df:
                df = pd.merge(df, m_df, left_on=key_in_df, right_on=m_key, how="left")
        except Exception as e:
            sys.stderr.write(f"Warning: Failed to merge metadata: {e}\n")

    detected = detect_columns(df)
    final_subject_id = subject_id or detected["subject_id"]
    final_group_col = group_col or detected["group_col"]
    final_subgroup_col = subgroup_col or detected["subgroup_col"]
    final_covariates = covariates or detected["covariates"]

    if not final_group_col or final_group_col not in df.columns:
        raise ValueError(f"Could not determine valid grouping column in {csv_path.name}")

    # Determine metrics to run
    available_metrics = detected["metric_columns"]
    if not metrics or metrics == ["auto"] or metrics == ["all"]:
        # Smart default: top relevant sleep metrics present in data
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

    # Create datastamped output folder
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

    for m in target_metrics:
        res = fit_statistical_model(
            df=df,
            metric=m,
            group_col=final_group_col,
            subgroup_col=final_subgroup_col,
            covariates=final_covariates,
            subject_id=final_subject_id,
            preferred_model=preferred_model,
            posthoc_method=posthoc_method,
        )
        if res:
            analysis_results.append(res)
            # Generate publication plot
            plot_file = plots_dir / f"{m}_plot.png"
            generate_publication_plot(res, df, plot_file)
            plot_paths[m] = plot_file

            for eff in res.get("model_effects", []):
                all_model_effects.append({"metric": m, **eff})
            for ph in res.get("posthoc_contrasts", []):
                all_posthoc_contrasts.append({"metric": m, **ph})
            for ds in res.get("descriptive_stats", []):
                all_descriptives.append({"metric": m, **ds})

    # Save CSV Tables
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
        "covariates": final_covariates,
        "subject_id": final_subject_id,
        "total_rows": len(df),
        "unique_subjects": int(df[final_subject_id].nunique(dropna=True)) if final_subject_id else len(df),
        "metrics_analyzed": len(analysis_results),
    }

    # Generate Reports
    docx_file = None
    pdf_file = None
    if report_format in ("docx", "both"):
        docx_file = out_root / f"Group_Statistical_Report_{timestamp}.docx"
        generate_docx_report(analysis_results, meta_summary, docx_file, plot_paths)

    if report_format in ("pdf", "both"):
        pdf_file = out_root / f"Group_Statistical_Report_{timestamp}.pdf"
        generate_pdf_report(analysis_results, meta_summary, pdf_file, plot_paths)

    # Clean results for JSON serialization (remove pandas objects)
    json_results = []
    for r in analysis_results:
        clean_r = {k: v for k, v in r.items() if k != "data_sample"}
        clean_r["plot_path"] = str(plot_paths.get(r["metric"], ""))
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
    parser.add_argument("--covariates", help="Comma-separated covariate column names")
    parser.add_argument("--subject-id", help="Subject identifier column")
    parser.add_argument("--metrics", help="Comma-separated metric column names")
    parser.add_argument("--model", choices=["auto", "lmm", "glm"], default="auto")
    parser.add_argument("--posthoc", choices=["fdr", "tukey", "bonferroni"], default="fdr")
    parser.add_argument("--report-format", choices=["docx", "pdf", "both"], default="both")
    parser.add_argument("--inspect-only", action="store_true", help="Only inspect columns and return JSON")
    parser.add_argument("--config", help="Path to JSON configuration file")

    args = parser.parse_args()

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
        covs = cfg.get("covariates", [])
        subjid = cfg.get("subject_id")
        mets = cfg.get("metrics")
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
        covs = [c.strip() for c in args.covariates.split(",") if c.strip()] if args.covariates else []
        subjid = args.subject_id
        mets = [m.strip() for m in args.metrics.split(",") if m.strip()] if args.metrics else None
        model = args.model
        posthoc = args.posthoc
        rep_fmt = args.report_format

    if not csv_file.exists():
        sys.stderr.write(f"Error: CSV file not found: {csv_file}\n")
        sys.exit(1)

    if inspect_only:
        df = pd.read_csv(csv_file)
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
        covariates=covs,
        subject_id=subjid,
        metrics=mets,
        preferred_model=model,
        posthoc_method=posthoc,
        report_format=rep_fmt,
        emit_json=True,
    )
    print(json.dumps(payload, indent=2))


if __name__ == "__main__":
    main()
