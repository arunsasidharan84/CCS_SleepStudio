use analyse_nidra::{features, nonlinear, spectral};
use std::time::Instant;
fn main() {
    let fs = 250.0;
    let n = 3750;
    let mut seed = 1u64;
    let x: Vec<f64> = (0..n).map(|i| { seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1); ((seed>>33) as f64/2e9) + (i as f64*0.05).sin()*10.0 }).collect();
    let reps = 20;
    macro_rules! t { ($name:expr, $e:expr) => {{ let s=Instant::now(); for _ in 0..reps { std::hint::black_box($e); } println!("{:28} {:8.2} ms/window", $name, s.elapsed().as_secs_f64()*1000.0/reps as f64); }} }
    t!("bandpowers", features::bandpowers(&x, fs));
    t!("acw50", features::acw50(&x, fs));
    t!("permutation_entropy", nonlinear::permutation_entropy(&x));
    t!("svd_entropy", nonlinear::svd_entropy(&x));
    t!("sample_entropy", nonlinear::sample_entropy(&x));
    t!("higuchi", nonlinear::higuchi_fd(&x));
    t!("dfa", nonlinear::detrended_fluctuation(&x));
    t!("lziv", nonlinear::lziv_complexity(&x));
    t!("fooof", spectral::fooof_features(&x, fs));
    t!("irasa", spectral::irasa_features(&x, fs));
}
