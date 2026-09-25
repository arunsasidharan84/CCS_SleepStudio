# NeuroLoopGain parity check

`src/nlg.rs` is compared sample for sample with the reference C#
NeuroLoopGain 2.x build (https://github.com/NeuroloopGain/neuroloopgain).

1. Build the reference headless with Mono. Copy `Library/**` and
   `NeuroLoopGain/{NeuroLoopGain,NeuroLoopGainController,MCconfiguration,MCJump,SmoothOption}.cs`
   into a folder and add `RefMain.cs` from this directory. In the copy of
   `NeuroLoopGain.cs`, remove only the progress-bar / `Application.DoEvents`
   lines and the piB-histogram window. Also do the following:
   - Replace `Library/Logging/ErrorLogger.cs` with a console stub.
   - Add `using Range = NeuroLoopGainLibrary.Mathematics.Range;` to files that use `Range.`.

   Then compile:
   `mcs -out:nlgref.exe -r:System.Xml.Linq.dll -r:System.Core.dll -r:System.Xml.dll -r:System.Data.dll $(find . -name '*.cs')`
2. Build the Rust dumper: `cargo build --release --example nlg_dump`.
3. Run `PSG_DIR=/path/to/PSG REF=/path/to/nlgref.exe ./parity.sh`. Each line of
   `parity.txt` reports the number of differing samples over all 14 output
   traces.

Result on the four bundled nights (AS_CNT_08/10, Night1/2; F3, F4, C3, C4, O1
and O2; slow-wave, sigma and alpha bands; smoother rates 0.01666 and 0.01):
144 runs, 0 differing samples.
