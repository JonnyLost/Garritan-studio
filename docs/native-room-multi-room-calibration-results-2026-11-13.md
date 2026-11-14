# Studio native reverb — Multi-room calibration results

**Verified:** November 13, 2026  
**CI run:** https://github.com/JonnyLost/Garritan-studio/actions/runs/43411913323  
**Branch:** `feature/stage-acoustics-sync`  
**Status:** macOS Debug build, Swift regression tests, optimized Release build,
8-profile six-band calibration and JSON artifact upload all **passed**.

The profile suite comprises four existing factory rooms (unchanged), the default
custom design held out from future fitting, and three contrasting hypothetical
custom environments. Measured figures below are **T20 estimates from Studio's
own synthetic wet-only impulse responses**, NOT measured room acoustics.

## Measurements from the passing macOS workflow

Room dimensions/materials are detailed in
[native-room-cross-room-calibration.md](./native-room-cross-room-calibration.md).

| Scenario | 125 Hz | 250 Hz | 500 Hz | 1 kHz | 2 kHz | 4 kHz | Mean absolute % error |
|---|---:|---:|---:|---:|---:|---:|---:|
| **Small Treated Studio** | 1.71 | 1.19 | 0.70 | 0.37 | 0.21 | 0.16 | ~27.8% |
| **Medium Wood Scoring Room** | 2.61 | 2.83 | 2.96 | 3.07 | 3.11 | 3.06 | ~7.0% |
| **Large Reflective Hall** | 9.37 | 9.76 | 9.93 | 9.64 | 8.97 | 8.35 | ~8.9% |
| **Default custom room** | 3.17 | 3.62 | 3.98 | 4.37 | 4.58 | 4.59 | ~12.6% |

**All T20 values in seconds**, approximately 48 kHz impulse analysis at a
12-second recording duration. These are experimentally approximated octave
bands; no external IRs were bundled.

## Biggest mismatches

- **Small treated room at 500 Hz:** expected ~0.42 s but synthesized
  ~0.70 s, a **67.3% longer** tail. The 125 Hz band is 35.1%
  shorter than predicted. Short and frequency-dependent rooms are
  challenging for the current coupled six-band feedback design.
- **Medium wood room:** all six bands were within approximately 13%
  of the intended DSP target.
- **Large reflective hall:** all six bands were within approximately
  13%, though finite-window analysis of long tails still merits checking.
- **Default room (untuned holdout):** 125 Hz is 30.1% longer than its target.
  This matches the earlier single-room baseline and establishes that
  expanding the calibration harness did not change the original DSP.

The four three-band factory profiles were also measured, but their
interpolated six-band targets remain only approximate diagnostics;
**no factory algorithms, profile IDs, or coefficients were rewritten**.

## Engineering decision

1. **Do not automatically apply** the proposed feedback correction factors.
   The small treated room has substantial, mixed-sign error, so fitting
   just the default room could make the short-room behavior worse.
2. Investigate crossover/band interaction, short-decay Schroeder analysis,
   and separate early versus late tail energy before fitting six-band
   feedback coefficients.
3. Validate an offline bounded optimizer across the three contrasting
   rooms and keep the default room as an independent holdout.
4. Repeat at more than one sample rate, and complete a consolidated
   MacBook audio-device listening/CPU check before shipping the native
   room effect as default.

**Methodological limits:** second-order octave approximations, uncorrected
noise floor, finite tail, simplified Sabine/Eyring geometry and no real
microphone or room measurements. These numbers indicate internal model
consistency, **not accuracy versus Abbey Road, Sony, Vienna, Boston or
REVERBDATA**.

The underlying full-resolution JSON is stored under the workflow artifact
`native-room-calibration` from the passing run.
