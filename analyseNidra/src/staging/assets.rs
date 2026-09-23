//! Centralised lookup for bundled model assets.
//!
//! Release packaging places `analyseNidra/assets/models` in a different spot on
//! every platform:
//!
//! * macOS   : `CCS Sleep Studio.app/Contents/Resources/models` (the
//!             `analyse-nidra` binary lives in `Contents/Resources/`)
//! * Windows : `<install>/assets/models` next to `analyse-nidra.exe`
//! * Linux   : `/usr/lib/ccs-sleep-studio/assets/models` (bundle `assets/models`)
//! * dev     : `analyseNidra/assets/models` relative to the repo / crate root
//!
//! Each staging module used to carry its own (slightly different) candidate
//! list, which is why e.g. GSSC could not find its models inside the macOS app
//! bundle. Every model lookup now goes through [`models_root_candidates`].

use anyhow::{bail, Result};
use std::path::{Path, PathBuf};

/// Environment variable that can point at an explicit models directory.
pub const MODELS_ENV: &str = "ANALYSE_NIDRA_MODELS";

/// Ordered list of directories that may contain the `models/` tree.
pub fn models_root_candidates() -> Vec<PathBuf> {
    let mut roots: Vec<PathBuf> = Vec::new();
    if let Ok(env_dir) = std::env::var(MODELS_ENV) {
        if !env_dir.trim().is_empty() {
            roots.push(PathBuf::from(env_dir.trim()));
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        let exe = exe.canonicalize().unwrap_or(exe);
        if let Some(dir) = exe.parent() {
            for rel in [
                "models",
                "assets/models",
                // Older Windows packaging copied the models folder *as* assets\
                "assets",
                "../Resources/models",
                "../Resources/assets/models",
                "../Resources/flutter_assets/assets/models",
                "data/flutter_assets/assets/models",
                "lib/assets/models",
                "../lib/ccs-sleep-studio/assets/models",
                "../share/ccs-sleep-studio/models",
                "../../assets/models",
                "../../../assets/models",
                "../../analyseNidra/assets/models",
            ] {
                roots.push(dir.join(rel));
            }
        }
    }
    for rel in [
        "assets/models",
        "analyseNidra/assets/models",
        "../assets/models",
        "../analyseNidra/assets/models",
        "models",
    ] {
        roots.push(PathBuf::from(rel));
    }
    // Development fallback: the crate's own asset folder.
    roots.push(Path::new(env!("CARGO_MANIFEST_DIR")).join("assets/models"));
    roots
}

/// Resolve `relative` (e.g. `"gssc/gssc_gru.onnx"`) against every models root.
pub fn find_model_file(relative: &str) -> Option<PathBuf> {
    models_root_candidates()
        .into_iter()
        .map(|root| root.join(relative))
        .find(|candidate| candidate.exists())
}

/// Like [`find_model_file`] but returns a descriptive error listing the
/// searched locations.
pub fn require_model_file(relative: &str, what: &str) -> Result<PathBuf> {
    if let Some(path) = find_model_file(relative) {
        return Ok(path);
    }
    let searched = models_root_candidates()
        .into_iter()
        .map(|root| format!("  - {}", root.join(relative).display()))
        .collect::<Vec<_>>()
        .join("\n");
    bail!(
        "{what} not found (looked for models/{relative}).\n\
         Install the Full build, or set {MODELS_ENV} to the folder that contains the \
         bundled `models` tree. Searched:\n{searched}"
    )
}

/// Resolve a model *directory* that must contain `marker` (a file inside it).
pub fn require_model_dir(relative_dir: &str, marker: &str, what: &str) -> Result<PathBuf> {
    let rel = format!("{}/{}", relative_dir.trim_end_matches('/'), marker);
    let file = require_model_file(&rel, what)?;
    Ok(file
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from(relative_dir)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dev_models_are_found() {
        assert!(find_model_file("gssc/gssc_gru.onnx").is_some());
        assert!(find_model_file("yasa/clf_eeg_lgb_0.5.0.json").is_some());
    }

    #[test]
    fn missing_model_reports_search_paths() {
        let err = require_model_file("does/not/exist.onnx", "Test model").unwrap_err();
        assert!(err.to_string().contains("Searched"));
    }
}
