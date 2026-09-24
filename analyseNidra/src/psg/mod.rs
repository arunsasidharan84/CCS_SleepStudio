//! Cardio-respiratory (sleep apnea), periodic limb movement and cyclic
//! alternating pattern (CAP) analyses.

pub mod cap;
pub mod common;
pub mod plm;
pub mod respiratory;

use anyhow::Result;
use serde::Serialize;
use std::path::Path;

#[derive(Serialize)]
struct SignalListing {
    signals: Vec<SignalRow>,
    roles: Vec<common::ChannelGuess>,
}

#[derive(Serialize)]
struct SignalRow {
    label: String,
    sfreq: f64,
    unit: String,
    transducer: String,
    role: Option<String>,
}

/// JSON listing of every signal with its native rate and a role guess, used
/// by the UI to pre-fill the OSA / PLM channel pickers.
pub fn list_signals_json(path: &Path) -> Result<String> {
    let infos = crate::edf::read_signal_infos(path)?;
    let roles = common::guess_roles(&infos);
    let signals = infos
        .iter()
        .map(|i| SignalRow {
            label: i.label.clone(),
            sfreq: i.sfreq,
            unit: i.unit.clone(),
            transducer: i.transducer.clone(),
            role: common::guess_role(i).map(String::from),
        })
        .collect();
    Ok(serde_json::to_string_pretty(&SignalListing {
        signals,
        roles,
    })?)
}
