# Third-party notices

CCS Sleep Studio itself is released under the [MIT licence](LICENSE). It builds on, ports, or bundles the third-party work listed below. **Entries marked "to confirm" have not yet been checked against the upstream licence and must be completed by the maintainers before a JOSS submission or a public release that bundles the item.**

## Ported algorithms and code

| Item | Where used | Upstream | Licence | Status |
|:---|:---|:---|:---|:---|
| NeuroLoopGain 2.x (Kemp & Roessen) | `analyseNidra/src/nlg.rs`; see `analyseNidra/THIRD_PARTY_NeuroLoopGain.md` | https://github.com/NeuroloopGain/neuroloopgain | Apache-2.0 | Notice present |
| YASA (spindle, slow-wave detection, LightGBM stager, filters) | `analyseNidra/src/events.rs`, `staging/yasa.rs`, `assets/models/yasa/` | https://github.com/raphaelvallat/yasa | BSD-3-Clause | To confirm; include upstream notice |
| Luna POPS stager (`s2` model and feature pipeline) | `analyseNidra/src/staging/pops.rs`, `assets/models/pops/` | https://zzz.nyspi.org/luna/ | To confirm | **Check licence terms for the ported code and the model files** |
| ScoringHero (UI concepts, scoring JSON format, Python display filters) | `frontend/`, `bridge/`, `docs/PORTING_PLAN.md` | https://github.com/SvennoNito/ScoringHero | To confirm | **Confirm licence and add attribution** |
| TensorPAC (modulation-index reference) | `analyseNidra/src/pac.rs` | https://github.com/EtienneCmb/tensorpac | To confirm | Used as a reference implementation; confirm whether code was ported |
| FOOOF / specparam, IRASA | `analyseNidra/src/spectral.rs` | https://github.com/fooof-tools/fooof | Apache-2.0 | Re-implementation; confirm no code was copied |
| MNE-Python (FIR design and resampling parity) | `analyseNidra/src/signal.rs`, test fixtures | https://github.com/mne-tools/mne-python | BSD-3-Clause | Reference only; confirm |
| ACCS sleep-stage analyser (MATLAB, NIMHANS) | `analyseNidra/src/accs.rs` | Local code of the authors' laboratory | Same as this project | Confirm authors agree to MIT |

## Bundled pretrained models (`analyseNidra/assets/models/`)

| Model | Upstream | Licence | Status |
|:---|:---|:---|:---|
| GSSC (Greifswald Sleep Stage Classifier) | https://github.com/jshanna100/gssc | To confirm | Check licence for redistribution of converted ONNX weights |
| U-Sleep (Braindecode checkpoint) | https://github.com/braindecode/braindecode, Perslev et al. 2021 | To confirm | Check checkpoint terms |
| TinySleepNet | https://github.com/akaraspt/tinysleepnet | To confirm | Check; includes PhysioEx-trained variants |
| SeqSleepNet, SleepTransformer (PhysioEx checkpoints) | https://github.com/guidogagl/physioex | To confirm | Check |
| SleepGPT | https://github.com/yuty2009/sleepgpt (`backend/sleepgpt-main/LICENSE`) | Apache-2.0 | Licence file present in the repo; add notice for the ONNX export |
| YASA classifiers (`clf_*_lgb_0.5.0.json`) | YASA | BSD-3-Clause | To confirm |
| POPS `s2` files | Luna | To confirm | See above |

Converted or re-exported weights are derivative works of the originals; keep each upstream licence text and attribution alongside the weights.

## Libraries

Rust dependencies are listed in `bridge/Cargo.lock` and `analyseNidra/Cargo.lock`; Dart/Flutter dependencies (including `media_kit` and the bundled libmpv builds) in `frontend/pubspec.lock`. Generate a full licence report before release, for example with `cargo install cargo-about` (Rust) and `flutter pub deps` / `dart pub global run license_checker` (Dart). Note that libmpv builds shipped through `media_kit_libs_video` may carry copyleft terms (GPL/LGPL, depending on the build); confirm what the installers distribute.

## Python backend (retired path)

`backend/vendor/` and `backend/external/` hold vendored Python packages and cloned upstream repositories, each under its own licence (their licence files are retained in those folders). Consider removing these from the public repository, since the native engine no longer needs them, which also reduces repository size.

## Sample data

See [`SamplePSGData/README.md`](SamplePSGData/README.md).
