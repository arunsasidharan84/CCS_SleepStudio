# Contributing to CCS Sleep Studio

Thank you for your interest in improving CCS Sleep Studio. Contributions of all kinds are welcome: bug reports, documentation, test recordings or reference results, new file-format readers, and code.

## Getting help and reporting problems

- **Questions and usage help:** open a [GitHub issue](https://github.com/arunsasidharan84/CCS_SleepStudio/issues) using the *Question* label, or start a discussion if Discussions are enabled.
- **Bugs:** open an issue using the *Bug report* template. Include the app version (shown in the About dialog and in `CHANGELOG.md`), your operating system, the file format, and the steps to reproduce. **Do not attach recordings that contain patient-identifiable information.** Use the anonymisation tool in the EEG Utilities module first, or share only a short, de-identified excerpt.
- **Feature requests:** open an issue using the *Feature request* template and describe the research or clinical use case.

## Building and testing

Prerequisites are listed in the [README](README.md#-running--building-locally): the Flutter SDK (stable) and the Rust toolchain.

```sh
git clone --recursive https://github.com/arunsasidharan84/CCS_SleepStudio.git
cd CCS_SleepStudio

# Native libraries and tests
(cd bridge && cargo build --release && cargo test)
(cd analyseNidra && cargo test)

# Flutter static analysis and tests (needs the bridge library built first)
(cd frontend && flutter pub get && flutter analyze && flutter test)
```

`scripts/release_check.sh` runs the full pre-release sequence; see [docs/RELEASE_SOP.md](docs/RELEASE_SOP.md). Tests that need large local recordings skip themselves when the files are absent.

## Making a change

1. Fork the repository and create a branch from `main`.
2. Keep each pull request focused on one change.
3. Add or update tests. For re-implemented scientific methods, please add a comparison against the reference implementation (or a published result) and state the tolerance achieved.
4. Run `cargo test`, `flutter analyze` and `flutter test` and make sure they pass.
5. Add a short entry to `CHANGELOG.md` for user-visible changes.
6. Open a pull request describing what changed and why. A maintainer will review it; please allow some time for a reply.

## Code style

- Rust: `cargo fmt` and `cargo clippy` clean where practical.
- Dart: follow `flutter_lints` (`flutter analyze` must report no errors).
- Prefer clear names and comments that explain *why*, particularly where a method follows a published algorithm (cite the paper or the reference code).

## Contributing data and reference results

Test data must be openly redistributable and fully de-identified, with the consent or ethics basis stated. Please open an issue before sending large files.

## Scientific and clinical use

CCS Sleep Studio is research software. Automated scoring and analysis outputs are not a substitute for review by a qualified scorer or clinician, and the software is not a certified medical device.

## Conduct and licence

Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md). By contributing you agree that your contributions are licensed under the project's [MIT licence](LICENSE).
