# Sample PSG data

A small demonstration dataset for testing the viewer, manual-scoring import, batch workflows, scoring comparison, and AnalyseNidra report generation.

## Contents

| Path | Description |
|:---|:---|
| `Data/AS_CNT_08_Night1.edf`, `AS_CNT_08_Night2.edf` | Overnight PSG recordings, participant AS_CNT_08, two nights (EDF) |
| `Data/AS_CNT_10_Night1.edf`, `AS_CNT_10_Night2.edf` | Overnight PSG recordings, participant AS_CNT_10, two nights (EDF) |
| `ManualScorings/*.edf` | Manual sleep-stage scorings with the same base file names (EDF) |
| `Template_config.json` | Reusable configuration template for these recordings |

## How to use

Load a recording from `Data/`, then import the matching file from `ManualScorings/` as the scoring or comparison file. These recordings are also used for the parity checks described in the repository (NeuroLoopGain, sleep-cycle analysis, YASA spindle and slow-wave detection).

## Provenance, consent and licence

- **Redistribution:** the project maintainers have confirmed these four nights may be redistributed with this repository.
- **Consent / ethics basis:** `[TO BE COMPLETED: study name, ethics committee and approval number, and a statement that participants consented to open sharing of de-identified data]`
- **De-identification:** `[TO BE COMPLETED: confirm that patient name, ID, date of birth and recording date were removed from the EDF headers; the EEG Utilities module can anonymise headers]`
- **Recording details:** `[TO BE COMPLETED: acquisition system, channels, sampling rates, scorer and scoring rules (AASM version)]`
- **Licence:** `[TO BE COMPLETED: for example CC BY 4.0 for the data; the software licence (MIT) does not automatically apply to data]`

If you use these data in a publication, please cite the software (see `CITATION.cff`) and, once available, the data description.
