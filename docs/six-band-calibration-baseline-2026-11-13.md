# Native Room Reverb — Six-Band Calibration Baseline

**Generated:** November 13, 2026
**Branch:** `feature/stage-acoustics-sync`
**GitHub Actions run:** https://github.com/JonnyLost/Garritan-studio/actions/runs/43383904003
**Environment:** macOS 15 runner, original native DSP (not a third-party IR)
**Test:** 48,000 Hz, six-second stereo wet-only impulse, per-track ER + shared 16-line FDN
**Metric:** synthetic T20, extrapolated to RT60, per approximate octave band.

## Results (T20 in seconds)

| Native room | 125 Hz | 250 Hz | 500 Hz | 1 kHz | 2 kHz | 4 kHz |
|---|---:|---:|---:|---:|---:|---:|
| Abbey Road-inspired | 2.24 | 2.19 | 2.17 | 2.16 | 2.14 | 2.11 |
| MGM/Sony-inspired | 1.23 | 1.19 | 1.15 | 1.07 | 1.04 | 1.03 |
| Vienna-inspired | 1.70 | 1.70 | 1.70 | 1.67 | 1.63 | 1.60 |
| Boston-inspired | 1.95 | 1.90 | 1.86 | 1.83 | 1.77 | 1.72 |
| **Custom room (default design)** | **3.17** | **3.62** | **3.98** | **4.37** | **4.58** | **4.59** |

### Default custom room, prediction versus synthetic decay

| Frequency | Design target | Measured T20 | Difference |
|---|---:|---:|---:|
| 125 Hz | 2.44 s | 3.17 s | +30.1% |
| 250 Hz | 3.33 s | 3.62 s | +8.5% |
| 500 Hz | 3.61 s | 3.98 s | +10.4% |
| 1 kHz | 4.89 s | 4.37 s | -10.5% |
| 2 kHz | 5.37 s | 4.58 s | -14.7% |
| 4 kHz | 4.52 s | 4.59 s | +1.5% |

The custom design uses 18 × 12 × 8 m with wood walls/floor and a
painted-plaster ceiling, no treatment, Eyring prediction.

### Interpretation and calibration limits

- This is a **measurement of the original Studio DSP**, **not of a real
  named recording room**.
- Factory presets have *three-band design targets*; the six per-frequency
  reference numbers printed by the CLI are **interpolated only**. They are
  not measured Abbey Road, Sony, Vienna, or Boston curves.
- The largest deviation in the default *custom* preset is a bass tail
  roughly 30% longer than the predicted 125 Hz decay. The 2 kHz band
  is roughly 15% shorter.
- The estimated T20 relies on approximate octave biquads, no
  noise-floor compensation, and a finite six-second impulse. The source
  has no explicit dry arrival, so its C80 is wet-only and cannot be
  equated to standard room C80.
- The backing JSON and detailed figures can be retrieved from the
  GitHub Actions artifact named **native-room-calibration**.

### Next engineering work, in priority order

1. Measure **multiple** custom geometries and materials at common sample
   rates before tuning coefficients, to avoid overfitting this one room.
2. Develop an offline, bounded, iterative fit for six-band feedback gains;
   avoid expensive fitting in real-time rendering or arbitrary changes
   to the factory presets.
3. Compare band curves with suitably licensed real measured impulse data
   and explicitly matched source/microphone conditions.
4. Run one consolidated MacBook listening/CPU/memory milestone after
   additional acoustic tuning.

External, source-attributed **broadband** room measurements from
REVERBDATA are indexed separately in
[reverbdata-measured-anchors.json](./reverbdata-measured-anchors.json).
They have not been copied into this file as six octave-band calibration
targets; they are not equivalent.
