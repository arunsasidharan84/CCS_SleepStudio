use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct BandDefinition {
    pub low: f64,
    pub high: f64,
    pub label: String,
}

impl BandDefinition {
    pub fn new(low: f64, high: f64, label: impl Into<String>) -> Self {
        Self {
            low,
            high,
            label: label.into(),
        }
    }
}

pub fn default_bands() -> Vec<BandDefinition> {
    vec![
        BandDefinition::new(1.0, 4.0, "Delta"),
        BandDefinition::new(4.0, 8.0, "Theta"),
        BandDefinition::new(10.0, 16.0, "Sigma"),
        BandDefinition::new(8.0, 12.0, "Alpha"),
        BandDefinition::new(12.0, 18.0, "Beta1"),
        BandDefinition::new(18.0, 30.0, "Beta2"),
        BandDefinition::new(30.0, 40.0, "Gamma1"),
    ]
}

fn default_epoch_length() -> f64 {
    30.0
}

fn default_feature_window() -> f64 {
    15.0
}

fn default_spindle_freq_min() -> f64 {
    11.0
}

fn default_spindle_freq_max() -> f64 {
    16.0
}

fn default_spindle_duration_min() -> f64 {
    0.5
}

fn default_spindle_duration_max() -> f64 {
    2.0
}

fn default_spindle_rel_power_thresh() -> f64 {
    0.2
}

fn default_spindle_corr_thresh() -> f64 {
    0.65
}

fn default_spindle_rms_mult() -> f64 {
    1.5
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SpindleConfig {
    #[serde(default = "default_spindle_freq_min")]
    pub freq_min: f64,
    #[serde(default = "default_spindle_freq_max")]
    pub freq_max: f64,
    #[serde(default = "default_spindle_duration_min")]
    pub duration_min: f64,
    #[serde(default = "default_spindle_duration_max")]
    pub duration_max: f64,
    #[serde(default = "default_spindle_rel_power_thresh")]
    pub rel_power_thresh: f64,
    #[serde(default = "default_spindle_corr_thresh")]
    pub corr_thresh: f64,
    #[serde(default = "default_spindle_rms_mult")]
    pub rms_multiplier: f64,
}

impl Default for SpindleConfig {
    fn default() -> Self {
        Self {
            freq_min: default_spindle_freq_min(),
            freq_max: default_spindle_freq_max(),
            duration_min: default_spindle_duration_min(),
            duration_max: default_spindle_duration_max(),
            rel_power_thresh: default_spindle_rel_power_thresh(),
            corr_thresh: default_spindle_corr_thresh(),
            rms_multiplier: default_spindle_rms_mult(),
        }
    }
}

fn default_sw_freq_min() -> f64 {
    0.3
}

fn default_sw_freq_max() -> f64 {
    2.0
}

fn default_sw_min_ptp() -> f64 {
    75.0
}

fn default_sw_max_ptp() -> f64 {
    350.0
}

fn default_sw_min_neg_amp() -> f64 {
    40.0
}

fn default_sw_max_neg_amp() -> f64 {
    200.0
}

fn default_sw_min_pos_amp() -> f64 {
    10.0
}

fn default_sw_max_pos_amp() -> f64 {
    150.0
}

fn default_sw_duration_min() -> f64 {
    0.4
}

fn default_sw_duration_max() -> f64 {
    2.5
}

fn default_sw_neg_duration_min() -> f64 {
    0.3
}

fn default_sw_neg_duration_max() -> f64 {
    1.5
}

fn default_sw_pos_duration_min() -> f64 {
    0.1
}

fn default_sw_pos_duration_max() -> f64 {
    1.0
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SlowWaveConfig {
    #[serde(default = "default_sw_freq_min")]
    pub freq_min: f64,
    #[serde(default = "default_sw_freq_max")]
    pub freq_max: f64,
    #[serde(default = "default_sw_min_ptp")]
    pub min_ptp: f64,
    #[serde(default = "default_sw_max_ptp")]
    pub max_ptp: f64,
    #[serde(default = "default_sw_min_neg_amp")]
    pub min_neg_amp: f64,
    #[serde(default = "default_sw_max_neg_amp")]
    pub max_neg_amp: f64,
    #[serde(default = "default_sw_min_pos_amp")]
    pub min_pos_amp: f64,
    #[serde(default = "default_sw_max_pos_amp")]
    pub max_pos_amp: f64,
    #[serde(default = "default_sw_duration_min")]
    pub duration_min: f64,
    #[serde(default = "default_sw_duration_max")]
    pub duration_max: f64,
    #[serde(default = "default_sw_neg_duration_min")]
    pub neg_duration_min: f64,
    #[serde(default = "default_sw_neg_duration_max")]
    pub neg_duration_max: f64,
    #[serde(default = "default_sw_pos_duration_min")]
    pub pos_duration_min: f64,
    #[serde(default = "default_sw_pos_duration_max")]
    pub pos_duration_max: f64,
}

impl Default for SlowWaveConfig {
    fn default() -> Self {
        Self {
            freq_min: default_sw_freq_min(),
            freq_max: default_sw_freq_max(),
            min_ptp: default_sw_min_ptp(),
            max_ptp: default_sw_max_ptp(),
            min_neg_amp: default_sw_min_neg_amp(),
            max_neg_amp: default_sw_max_neg_amp(),
            min_pos_amp: default_sw_min_pos_amp(),
            max_pos_amp: default_sw_max_pos_amp(),
            duration_min: default_sw_duration_min(),
            duration_max: default_sw_duration_max(),
            neg_duration_min: default_sw_neg_duration_min(),
            neg_duration_max: default_sw_neg_duration_max(),
            pos_duration_min: default_sw_pos_duration_min(),
            pos_duration_max: default_sw_pos_duration_max(),
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct FeatureConfig {
    #[serde(default = "default_epoch_length")]
    pub epoch_length_sec: f64,
    #[serde(default = "default_feature_window")]
    pub feature_window_sec: f64,
    #[serde(default = "default_bands")]
    pub bands: Vec<BandDefinition>,
    #[serde(default)]
    pub spindles: SpindleConfig,
    #[serde(default)]
    pub slow_waves: SlowWaveConfig,
}

impl Default for FeatureConfig {
    fn default() -> Self {
        Self {
            epoch_length_sec: default_epoch_length(),
            feature_window_sec: default_feature_window(),
            bands: default_bands(),
            spindles: SpindleConfig::default(),
            slow_waves: SlowWaveConfig::default(),
        }
    }
}

impl FeatureConfig {
    pub fn from_json_str(content: &str) -> Result<Self> {
        let value: serde_json::Value =
            serde_json::from_str(content).context("parsing JSON configuration")?;

        // 1. If it's already structured as FeatureConfig:
        if value.get("spindles").is_some() || value.get("bands").is_some() {
            if let Ok(cfg) = serde_json::from_value::<FeatureConfig>(value.clone()) {
                return Ok(cfg);
            }
        }

        // 2. Otherwise parse with Flutter AppConfig keys and fallbacks:
        let mut cfg = FeatureConfig::default();

        if let Some(v) = value.get("epochLengthSeconds").and_then(|v| v.as_f64()) {
            cfg.epoch_length_sec = v;
        } else if let Some(v) = value.get("epoch_length_sec").and_then(|v| v.as_f64()) {
            cfg.epoch_length_sec = v;
        }

        if let Some(v) = value.get("featureWindowSeconds").and_then(|v| v.as_f64()) {
            cfg.feature_window_sec = v;
        } else if let Some(v) = value.get("feature_window_sec").and_then(|v| v.as_f64()) {
            cfg.feature_window_sec = v;
        }

        // Band limits from AppConfig
        let delta_lo = value.get("bandDeltaLo").and_then(|v| v.as_f64()).unwrap_or(1.0);
        let delta_hi = value.get("bandDeltaHi").and_then(|v| v.as_f64()).unwrap_or(4.0);
        let theta_lo = value.get("bandThetaLo").and_then(|v| v.as_f64()).unwrap_or(4.0);
        let theta_hi = value.get("bandThetaHi").and_then(|v| v.as_f64()).unwrap_or(8.0);
        let sigma_lo = value.get("bandSigmaLo").and_then(|v| v.as_f64()).unwrap_or(10.0);
        let sigma_hi = value.get("bandSigmaHi").and_then(|v| v.as_f64()).unwrap_or(16.0);
        let alpha_lo = value.get("bandAlphaLo").and_then(|v| v.as_f64()).unwrap_or(8.0);
        let alpha_hi = value.get("bandAlphaHi").and_then(|v| v.as_f64()).unwrap_or(12.0);
        let beta_lo = value.get("bandBetaLo").and_then(|v| v.as_f64()).unwrap_or(12.0);
        let beta_hi = value.get("bandBetaHi").and_then(|v| v.as_f64()).unwrap_or(30.0);
        let gamma_lo = value.get("bandGammaLo").and_then(|v| v.as_f64()).unwrap_or(30.0);
        let gamma_hi = value.get("bandGammaHi").and_then(|v| v.as_f64()).unwrap_or(40.0);

        // If the user specified band parameters in AppConfig, populate them
        if value.get("bandDeltaLo").is_some() || value.get("bandSigmaLo").is_some() {
            cfg.bands = vec![
                BandDefinition::new(delta_lo, delta_hi, "Delta"),
                BandDefinition::new(theta_lo, theta_hi, "Theta"),
                BandDefinition::new(sigma_lo, sigma_hi, "Sigma"),
                BandDefinition::new(alpha_lo, alpha_hi, "Alpha"),
                BandDefinition::new(beta_lo, (beta_lo + beta_hi) / 2.0, "Beta1"),
                BandDefinition::new((beta_lo + beta_hi) / 2.0, beta_hi, "Beta2"),
                BandDefinition::new(gamma_lo, gamma_hi, "Gamma1"),
            ];
        }

        // Spindle parameters
        if let Some(v) = value.get("spindleFreqMin").and_then(|v| v.as_f64()) {
            cfg.spindles.freq_min = v;
        }
        if let Some(v) = value.get("spindleFreqMax").and_then(|v| v.as_f64()) {
            cfg.spindles.freq_max = v;
        }
        if let Some(v) = value.get("spindleDurationMin").and_then(|v| v.as_f64()) {
            cfg.spindles.duration_min = v;
        }
        if let Some(v) = value.get("spindleDurationMax").and_then(|v| v.as_f64()) {
            cfg.spindles.duration_max = v;
        }
        if let Some(v) = value.get("spindleRelPowerThresh").and_then(|v| v.as_f64()) {
            cfg.spindles.rel_power_thresh = v;
        }
        if let Some(v) = value.get("spindleCorrThresh").and_then(|v| v.as_f64()) {
            cfg.spindles.corr_thresh = v;
        }
        if let Some(v) = value.get("spindleRmsMultiplier").and_then(|v| v.as_f64()) {
            cfg.spindles.rms_multiplier = v;
        }

        // Slow wave parameters
        if let Some(v) = value.get("slowWaveFreqMin").and_then(|v| v.as_f64()) {
            cfg.slow_waves.freq_min = v;
        }
        if let Some(v) = value.get("slowWaveFreqMax").and_then(|v| v.as_f64()) {
            cfg.slow_waves.freq_max = v;
        }
        if let Some(v) = value.get("slowWaveMinAmpUv").and_then(|v| v.as_f64()) {
            cfg.slow_waves.min_ptp = v;
        }
        if let Some(v) = value.get("slowWaveMinPtpUv").and_then(|v| v.as_f64()) {
            cfg.slow_waves.min_ptp = v;
        }
        if let Some(v) = value.get("slowWaveMaxPtpUv").and_then(|v| v.as_f64()) {
            cfg.slow_waves.max_ptp = v;
        }
        if let Some(v) = value.get("slowWaveMinNegAmpUv").and_then(|v| v.as_f64()) {
            cfg.slow_waves.min_neg_amp = v;
        }
        if let Some(v) = value.get("slowWaveMaxNegAmpUv").and_then(|v| v.as_f64()) {
            cfg.slow_waves.max_neg_amp = v;
        }
        if let Some(v) = value.get("slowWaveMinPosAmpUv").and_then(|v| v.as_f64()) {
            cfg.slow_waves.min_pos_amp = v;
        }
        if let Some(v) = value.get("slowWaveMaxPosAmpUv").and_then(|v| v.as_f64()) {
            cfg.slow_waves.max_pos_amp = v;
        }
        if let Some(v) = value.get("slowWaveDurationMin").and_then(|v| v.as_f64()) {
            cfg.slow_waves.duration_min = v;
        }
        if let Some(v) = value.get("slowWaveDurationMax").and_then(|v| v.as_f64()) {
            cfg.slow_waves.duration_max = v;
        }
        if let Some(v) = value.get("slowWaveNegDurationMin").and_then(|v| v.as_f64()) {
            cfg.slow_waves.neg_duration_min = v;
        }
        if let Some(v) = value.get("slowWaveNegDurationMax").and_then(|v| v.as_f64()) {
            cfg.slow_waves.neg_duration_max = v;
        }
        if let Some(v) = value.get("slowWavePosDurationMin").and_then(|v| v.as_f64()) {
            cfg.slow_waves.pos_duration_min = v;
        }
        if let Some(v) = value.get("slowWavePosDurationMax").and_then(|v| v.as_f64()) {
            cfg.slow_waves.pos_duration_max = v;
        }

        Ok(cfg)
    }

    pub fn from_file(path: &Path) -> Result<Self> {
        let content = std::fs::read_to_string(path)
            .with_context(|| format!("reading config file {}", path.display()))?;
        Self::from_json_str(&content)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_has_standard_values() {
        let cfg = FeatureConfig::default();
        assert_eq!(cfg.epoch_length_sec, 30.0);
        assert_eq!(cfg.feature_window_sec, 15.0);
        assert_eq!(cfg.spindles.freq_min, 11.0);
        assert_eq!(cfg.spindles.freq_max, 16.0);
        assert_eq!(cfg.slow_waves.min_ptp, 75.0);
        assert_eq!(cfg.bands.len(), 7);
        assert_eq!(cfg.bands[2].label, "Sigma");
    }

    #[test]
    fn parses_app_config_json_format() {
        let json_str = r#"{
            "epochLengthSeconds": 20.0,
            "featureWindowSeconds": 20.0,
            "spindleFreqMin": 12.0,
            "spindleFreqMax": 15.0,
            "spindleDurationMin": 0.6,
            "spindleDurationMax": 2.2,
            "spindleRelPowerThresh": 0.25,
            "spindleCorrThresh": 0.70,
            "spindleRmsMultiplier": 1.8,
            "slowWaveMinAmpUv": 80.0,
            "bandDeltaLo": 0.5,
            "bandDeltaHi": 4.0,
            "bandSigmaLo": 11.0,
            "bandSigmaHi": 15.0
        }"#;
        let cfg = FeatureConfig::from_json_str(json_str).unwrap();
        assert_eq!(cfg.epoch_length_sec, 20.0);
        assert_eq!(cfg.feature_window_sec, 20.0);
        assert_eq!(cfg.spindles.freq_min, 12.0);
        assert_eq!(cfg.spindles.freq_max, 15.0);
        assert_eq!(cfg.spindles.duration_min, 0.6);
        assert_eq!(cfg.spindles.duration_max, 2.2);
        assert_eq!(cfg.spindles.rel_power_thresh, 0.25);
        assert_eq!(cfg.spindles.corr_thresh, 0.70);
        assert_eq!(cfg.spindles.rms_multiplier, 1.8);
        assert_eq!(cfg.slow_waves.min_ptp, 80.0);
        assert_eq!(cfg.bands[2].label, "Sigma");
        assert_eq!(cfg.bands[2].low, 11.0);
        assert_eq!(cfg.bands[2].high, 15.0);
    }
}
