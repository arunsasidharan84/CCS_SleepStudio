//! Dev helper: run the accs stage analyser on a text stage list (W/1/2/3/R per line)
//! and print results in the same layout as the Octave parity driver.
use analyse_nidra::accs;
use analyse_nidra::hypnogram::Stage;

fn main() {
    let path = std::env::args().nth(1).expect("stage list");
    let text = std::fs::read_to_string(path).unwrap();
    let stages: Vec<Stage> = text
        .lines()
        .map(|l| match l.trim().trim_start_matches('N') {
            "W" => Stage::Wake,
            "1" => Stage::N1,
            "2" => Stage::N2,
            "3" | "4" => Stage::N3,
            "R" => Stage::Rem,
            _ => Stage::Unscored,
        })
        .collect();
    let Some(r) = accs::analyse(&stages) else {
        println!("ERROR none");
        return;
    };
    for (k, v) in &r.fullnight {
        println!("{k} {v}");
    }
    let s: Vec<String> = r.cycle_starts.iter().map(|v| v.to_string()).collect();
    let e: Vec<String> = r.cycle_ends.iter().map(|v| v.to_string()).collect();
    println!("starts {}", s.join(" "));
    println!("ends {}", e.join(" "));
    for (i, c) in r.cycles.iter().enumerate() {
        for (k, v) in &c.values {
            println!("C{}_{k} {v}", i + 1);
        }
    }
}
