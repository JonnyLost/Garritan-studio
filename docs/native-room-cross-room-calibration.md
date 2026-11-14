# Studio native reverb — cross-room calibration study

**Branch:** `feature/stage-acoustics-sync`  
**Status:** Test fixtures and reporting implemented; review the linked macOS CI measurement artifact before adopting any new acoustic correction.

## Purpose

Calibrate and evaluate **Studio's own algorithmic DSP** against the
six-band design targets from the Room Designer. This is **not** a
comparison against room recordings or a claim that the sound matches
the named historic stages.

The prior single-room baseline is
[here](./six-band-calibration-baseline-2026-11-13.md).
Its default-room 125 Hz T20 exceeded the target by about 30%; checking
one preset alone risks overfitting.

## Test rooms

Scenarios are defined in the native, deterministic
`StudioAcousticCalibrationScenario` source file.

| Scenario | L × W × H (m) | Walls / floor / ceiling | Treatment |
|---|---|---|---|
| Small Treated Studio | 7 × 5 × 3.2 | plaster / heavy carpet / plaster | 55% of wall area, fiberglass panels |
| Medium Wood Scoring Room | 16 × 11 × 7 | wood / wood / plaster | 12% of wall area, heavy curtain |
| Large Reflective Hall | 30 × 22 × 12 | brick / wood / plaster | no added wall treatment |
| Default holdout | 18 × 12 × 8 | wood / wood / plaster | no added wall treatment |

These are original **hypothetical** rooms, not surveyed real venues.

## Eyring estimates, before DSP measurement

The following values are approximate **mathematical input targets**, **not measured output**.

| Case | 125 Hz | 250 Hz | 500 Hz | 1 kHz | 2 kHz | 4 kHz |
|---|---:|---:|---:|---:|---:|---:|
| Small treated | 2.64 | 1.14 | 0.42 | 0.28 | 0.22 | 0.21 |
| Medium wood | 2.31 | 2.96 | 2.88 | 3.36 | 3.42 | 2.92 |
| Large reflective | 8.54 | 10.38 | 10.68 | 10.75 | 9.68 | 7.40 |
| Default holdout | 2.44 | 3.33 | 3.61 | 4.89 | 5.37 | 4.52 |

All times are seconds. The room estimates use representative materials;
actual installed absorption can vary substantially.

## Evaluation method

Run on macOS:

```sh
swift run -c release RoomAcousticCalibration --suite --seconds 12 > native-room-calibration.json
```

The tool renders a wet-only impulse response of the exact native
per-instrument early-reflection processor plus the shared 16-line FDN,
at a default 48 kHz. It evaluates the four *factory* presets, the
default custom-room holdout, and the three contrasting rooms (**8
reports total**).

For each six-band curve, it reports available EDT/T20/T30, the bounded
DSP target, unclamped Eyring/Sabine prediction for custom rooms, the
clamping flag, and absolute/percentage T20 mismatch. Summary metrics
show available T20-band counts and mean/max absolute errors.
A null measurement represents an unavailable estimate, **not zero error**.

The GitHub macOS CI workflow saves the JSON and publishes a table in
the job summary. Distinct scenario IDs prevent collisions among the
four custom cases, which share the same runtime Audio Unit room ID.

## Calibration decision rule

1. Establish error patterns across all **three** contrasting rooms.
2. Use the default design as an **independent holdout**.
3. Do **not** tune factory presets or automatically save adjustments.
4. Propose bounded six-band corrections **only after** inspecting the
   measured data and verifying improvements in more than one room.
5. Reject a correction if it degrades the holdout or increases large
   errors in other conditions.
6. Validate any accepted changes on MacBook listening/CPU tests before
   making native room processing the application default.

**Measurement limitations:** The analyzer uses approximate second-order
octave filters, a finite impulse duration, and backward energy
integration without environmental-noise correction. The short dry room
may have insufficient low-frequency energy; the reflective hall's long
tail may bias finite-window T20 and T30. Neither test demonstrates
ISO 3382 compliance or matches a real venue.
