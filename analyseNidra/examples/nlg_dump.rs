//! Dev helper for the NeuroLoopGain parity check:
//! `nlg_dump <edf> <signal label> <out.edf> <f0> <bandwidth> <fc> <smooth rate> [undersampler]`
//! runs the Rust port on one raw EDF signal and writes the 14 traces as EDF.
use analyse_nidra::{edf, nlg};
use std::path::Path;

fn main() -> anyhow::Result<()> {
    let a: Vec<String> = std::env::args().collect();
    let sig = edf::read_signals_kemp(Path::new(&a[1]), &[a[2].clone()])?
        .remove(0)
        .expect("signal not found");
    let p = |i: usize| a[i].parse::<f64>().unwrap();
    let cfg = nlg::NlgConfig {
        f0: p(4),
        bandwidth: p(5),
        fc: p(6),
        smooth_rate: p(7),
        iir_undersampler: a.get(8).map(|v| v.parse().unwrap()).unwrap_or(0),
        lp_hz: nlg::lp_from_prefilter(&sig.prefilter, sig.sfreq),
        ..Default::default()
    };
    let t = std::time::Instant::now();
    let tr = nlg::analyse(&sig.data, sig.samples_per_record, sig.record_duration, &cfg)?;
    eprintln!(
        "undersampler={} fcompute={} piB={} ({}) samples={} in {:.3}s",
        tr.undersampler, tr.f_compute, tr.pib_log, tr.pib, tr.recorded_samples, t.elapsed().as_secs_f64()
    );
    nlg::write_reference_edf(Path::new(&a[3]), &tr, &sig.unit, "01.01.00", "00.00.00")?;
    Ok(())
}
