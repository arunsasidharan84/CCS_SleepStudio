use std::collections::HashMap;

/// 3D spherical electrode coordinate on unit sphere.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ElectrodePos {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

impl ElectrodePos {
    pub fn new(x: f64, y: f64, z: f64) -> Self {
        let norm = (x * x + y * y + z * z).sqrt();
        if norm > 1e-9 {
            Self {
                x: x / norm,
                y: y / norm,
                z: z / norm,
            }
        } else {
            Self { x: 0.0, y: 0.0, z: 1.0 }
        }
    }

    /// Dot product (cosine of angle between two points on the unit sphere).
    pub fn dot(&self, other: &ElectrodePos) -> f64 {
        (self.x * other.x + self.y * other.y + self.z * other.z).clamp(-1.0, 1.0)
    }

    /// Euclidean distance squared between two points.
    pub fn dist_sq(&self, other: &ElectrodePos) -> f64 {
        let dx = self.x - other.x;
        let dy = self.y - other.y;
        let dz = self.z - other.z;
        dx * dx + dy * dy + dz * dz
    }
}

/// Normalizes channel label to standard 10-20 canonical casing/naming.
/// E.g., "EEG Fp1-Ref" -> "Fp1", "T3" -> "T7", "FP2" -> "Fp2", "cz" -> "Cz".
pub fn canonical_channel_name(label: &str) -> String {
    let mut clean = label.trim().to_uppercase();
    clean = clean.replace("EEG", "").replace("-REF", "").replace(":REF", "").replace("REF", "");
    if clean.starts_with("POL ") {
        clean = clean[4..].to_string();
    }
    if let Some(idx) = clean.find(':') {
        clean = clean[..idx].to_string();
    }
    if let Some(idx) = clean.find('-') {
        clean = clean[..idx].to_string();
    }
    clean = clean.trim().to_string();

    // Map legacy 10-20 to modern 10-10 aliases
    match clean.as_str() {
        "T3" => "T7".to_string(),
        "T4" => "T8".to_string(),
        "T5" => "P7".to_string(),
        "T6" => "P8".to_string(),
        "FP1" => "Fp1".to_string(),
        "FP2" => "Fp2".to_string(),
        "FPZ" => "Fpz".to_string(),
        "FZ" => "Fz".to_string(),
        "CZ" => "Cz".to_string(),
        "PZ" => "Pz".to_string(),
        "OZ" => "Oz".to_string(),
        "FCZ" => "FCz".to_string(),
        "CPZ" => "CPz".to_string(),
        "AFZ" => "AFz".to_string(),
        "POZ" => "POz".to_string(),
        other => {
            // Capitalize first letter, lowercase rest, keep second letter uppercase for C3, F4 etc.
            let chars: Vec<char> = other.chars().collect();
            if chars.is_empty() {
                return String::new();
            }
            if chars.len() == 2 && (chars[0] == 'F' || chars[0] == 'C' || chars[0] == 'P' || chars[0] == 'O' || chars[0] == 'T') {
                return format!("{}{}", chars[0], chars[1]);
            }
            if chars.len() >= 3 && (chars[0] == 'F' || chars[0] == 'C' || chars[0] == 'P' || chars[0] == 'A') && chars[1] == 'P' {
                return format!("Fp{}", &other[2..]);
            }
            // Standard casing: first letter capitalized, 'z' lowercase at end, otherwise uppercase
            if other.ends_with('Z') {
                format!("{}z", &other[..other.len() - 1])
            } else {
                other.to_string()
            }
        }
    }
}

/// Returns the standard 10-20 unit sphere electrode coordinates lookup table.
pub fn standard_1020_montage() -> HashMap<String, ElectrodePos> {
    let mut m = HashMap::new();

    // Standard 10-20 / 10-10 coordinates normalized to unit sphere (x: right, y: anterior, z: superior)
    let raw_coords = [
        ("Fp1", -0.308, 0.950, -0.035),
        ("Fp2", 0.308, 0.950, -0.035),
        ("Fpz", 0.000, 0.999, -0.035),
        ("AF7", -0.587, 0.809, -0.035),
        ("AF3", -0.380, 0.810, 0.446),
        ("AFz", 0.000, 0.891, 0.454),
        ("AF4", 0.380, 0.810, 0.446),
        ("AF8", 0.587, 0.809, -0.035),
        ("F7", -0.809, 0.587, -0.035),
        ("F5", -0.673, 0.545, 0.499),
        ("F3", -0.545, 0.673, 0.499),
        ("F1", -0.283, 0.707, 0.648),
        ("Fz", 0.000, 0.719, 0.695),
        ("F2", 0.283, 0.707, 0.648),
        ("F4", 0.545, 0.673, 0.499),
        ("F6", 0.673, 0.545, 0.499),
        ("F8", 0.809, 0.587, -0.035),
        ("FT7", -0.950, 0.308, -0.035),
        ("FC5", -0.810, 0.380, 0.446),
        ("FC3", -0.648, 0.380, 0.660),
        ("FC1", -0.342, 0.380, 0.860),
        ("FCz", 0.000, 0.383, 0.924),
        ("FC2", 0.342, 0.380, 0.860),
        ("FC4", 0.648, 0.380, 0.660),
        ("FC6", 0.810, 0.380, 0.446),
        ("FT8", 0.950, 0.308, -0.035),
        ("T7", -0.999, 0.000, -0.035),
        ("T3", -0.999, 0.000, -0.035),
        ("C5", -0.866, 0.000, 0.500),
        ("C3", -0.719, 0.000, 0.695),
        ("C1", -0.383, 0.000, 0.924),
        ("Cz", 0.000, 0.000, 1.000),
        ("C2", 0.383, 0.000, 0.924),
        ("C4", 0.719, 0.000, 0.695),
        ("C6", 0.866, 0.000, 0.500),
        ("T8", 0.999, 0.000, -0.035),
        ("T4", 0.999, 0.000, -0.035),
        ("TP7", -0.950, -0.308, -0.035),
        ("CP5", -0.810, -0.380, 0.446),
        ("CP3", -0.648, -0.380, 0.660),
        ("CP1", -0.342, -0.380, 0.860),
        ("CPz", 0.000, -0.383, 0.924),
        ("CP2", 0.342, -0.380, 0.860),
        ("CP4", 0.648, -0.380, 0.660),
        ("CP6", 0.810, -0.380, 0.446),
        ("TP8", 0.950, -0.308, -0.035),
        ("P7", -0.809, -0.587, -0.035),
        ("T5", -0.809, -0.587, -0.035),
        ("P5", -0.673, -0.545, 0.499),
        ("P3", -0.545, -0.673, 0.499),
        ("P1", -0.283, -0.707, 0.648),
        ("Pz", 0.000, -0.719, 0.695),
        ("P2", 0.283, -0.707, 0.648),
        ("P4", 0.545, -0.673, 0.499),
        ("P6", 0.673, -0.545, 0.499),
        ("P8", 0.809, -0.587, -0.035),
        ("T6", 0.809, -0.587, -0.035),
        ("PO7", -0.587, -0.809, -0.035),
        ("PO3", -0.380, -0.810, 0.446),
        ("POz", 0.000, -0.891, 0.454),
        ("PO4", 0.380, -0.810, 0.446),
        ("PO8", 0.587, -0.809, -0.035),
        ("O1", -0.308, -0.950, -0.035),
        ("Oz", 0.000, -0.999, -0.035),
        ("O2", 0.308, -0.950, -0.035),
        ("Iz", 0.000, -0.999, -0.350),
        ("M1", -0.999, -0.150, -0.250),
        ("M2", 0.999, -0.150, -0.250),
        ("A1", -0.999, -0.050, -0.200),
        ("A2", 0.999, -0.050, -0.200),
    ];

    for (name, x, y, z) in raw_coords {
        let pos = ElectrodePos::new(x, y, z);
        m.insert(name.to_string(), pos);
        m.insert(name.to_uppercase(), pos);
    }
    m
}

/// Lookup electrode position for a channel name with case and alias tolerance.
pub fn lookup_electrode_pos(montage: &HashMap<String, ElectrodePos>, channel_name: &str) -> Option<ElectrodePos> {
    if let Some(pos) = montage.get(channel_name) {
        return Some(*pos);
    }
    let canonical = canonical_channel_name(channel_name);
    if let Some(pos) = montage.get(&canonical) {
        return Some(*pos);
    }
    montage.get(&canonical.to_uppercase()).copied()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_canonical_channel_name() {
        assert_eq!(canonical_channel_name("EEG Fp1-Ref"), "Fp1");
        assert_eq!(canonical_channel_name("EEG T3-A1"), "T7");
        assert_eq!(canonical_channel_name("cz"), "Cz");
        assert_eq!(canonical_channel_name("POL C4:Ref"), "C4");
        assert_eq!(canonical_channel_name("Oz"), "Oz");
    }

    #[test]
    fn test_lookup_electrode_pos() {
        let montage = standard_1020_montage();
        let cz = lookup_electrode_pos(&montage, "Cz").expect("Cz should exist");
        assert!((cz.z - 1.0).abs() < 1e-4);

        let fp1 = lookup_electrode_pos(&montage, "EEG FP1-REF").expect("Fp1 should exist");
        assert!(fp1.y > 0.8);
    }
}
