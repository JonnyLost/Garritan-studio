# Native acoustic reverb — short-room calibration decision

**Date:** November 13, 2026 (America/New_York)  
**Branch:** `feature/stage-acoustics-sync`  
**Experimental measurements:** [GitHub Actions run 43553162641](https://github.com/JonnyLost/Garritan-studio/actions/runs/43553162641)  
**Release decision:** **REJECT candidate feedback fit. Do not enable in any user-facing custom room.**

## What changed in the calibration analyzer

The original analyzer used a broad second-order octave-ish resonator with
Q ≈ 1.414. To reduce out-of-band leakage, the offline-only analyzer now
supports cascaded second-order Butterworth highpass and lowpass filters
at an octave's approximate half-power edges.

The old filter remains selectable so a single synthetic room impulse can
be analyzed both ways. Neither analyzer is IEC 61260/ISO 3382 compliant
or based on real-world room recordings. The production audio engine was
not changed by the analysis-filter upgrade.

This changed our default custom room's estimated **125 Hz T20** from
3.17 to 2.92 seconds, closer to its 2.44 s theoretical target. But it did
**not** explain the small treated room's 500 Hz error; both methods
measured about **0.70 s**, versus **0.42 s** predicted. There is real
cross-band feedback leakage or model mismatch, not just measurement
filter leakage.

## Rejected candidate: magnitude-only short-room feedback fitting

An experimental offline-precomputed, six-band gain optimizer was
implemented to compensate the complex frequency response of the original
five complementary lowpass crossover filters. It uses regularized
bounded coordinate descent and a spectral stability scan. The fit
adds no allocations or optimization calls to the audio render callback.

However, measured results were **worse**, especially in the bass:

| Band | Predicted RT60 | Unchanged original DSP T20 | Experimental DSP T20 |
|---|---:|---:|---:|
| 125 Hz | 2.64 s | 1.71 s | 8.81 s |
| 250 Hz | 1.14 s | 1.20 s | 2.55 s |
| 500 Hz | 0.42 s | 0.70 s | 0.71 s |
| 1 kHz | 0.28 s | 0.36 s | 0.20 s |
| 2 kHz | 0.22 s | 0.21 s | 0.12 s |
| 4 kHz | 0.21 s | 0.16 s | 0.11 s |

All measurements are **synthetic wet-only Studio reverb T20**. They are not
field measurements, a direct+wet C80 assessment, or a validated acoustic
replica of a real space.

**Diagnosis:** fitting the magnitude response of an individual feedback
loop at six center frequencies does not account for coupled 16-delay
FDN modal energy, its time-varying decay trajectory, or cross-band
feedback interactions. Very high low-band gains can create excessive
long-lived bass modes, even when a coarse spectral grid suggests each
loop is bounded below unity. Frequency-domain fit success must not be
confused with time-domain acoustic accuracy.

**Safety action:** `StudioAcousticRoomDesign.makeProfile()` always sets
`shortRoomFeedbackCalibration: false`. Factory rooms never enable it.
The candidate algorithm is retained as **test-only / offline research**,
under a separate explicit `small-treated-experimental-fit` calibration
scenario, with its uncalibrated impulse as an A/B reference. No user
control exposes the experiment, no plugin is added, and no original
hall/preset is retuned.

## Next engineering approach

1. Keep the current native room as the trusted opt-in experimental
   implementation while investigating a genuinely better
   *energy-stable multiband damping design* with controlled crossover
   coupling and bounded feedback.
2. Add at least two independent **additional short-room** design
   scenarios. Reject modifications that do not improve both and the
   existing default/medium/large holdouts.
3. Test EDT, T20, T30 and synthetic response across sample rates, and
   compare the direct/early/late components independently.
4. Only then consider enabling a new DSP mode, after MacBook CPU,
   listening and real-time safety validation.
5. Microphone realism and smooth room transitions remain separate
   future milestones.

## CI verification

The earlier [A/B experiment run 43553162641](https://github.com/JonnyLost/Garritan-studio/actions/runs/43553162641)
passed builds, regression tests and the nine-band (eight normal plus
experimental candidate) offline research steps **while the candidate
was temporarily auto-enabled**. The candidate therefore passed code
tests **but failed acoustic acceptance**. The subsequent code changes
explicitly disable automatic enablement and update regression guards.
Refer to the latest workflow run on the feature branch for the final
compile and safety check. Do not label that run as passing until it has
actually finished.
