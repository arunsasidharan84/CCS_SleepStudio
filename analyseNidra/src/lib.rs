pub mod cleaning;
pub mod edf;
pub mod events;
pub mod features;
pub mod hypnogram;
pub mod nonlinear;
pub mod pac;
pub mod pipeline;
pub mod regional;
pub mod signal;
pub mod spectral;
pub mod staging;

pub const TARGET_SFREQ: f64 = 250.0;
pub const DEFAULT_CHANNELS: [&str; 6] = ["F3", "F4", "C3", "C4", "O1", "O2"];
pub const DEFAULT_REFERENCES: [&str; 2] = ["M1", "M2"];
