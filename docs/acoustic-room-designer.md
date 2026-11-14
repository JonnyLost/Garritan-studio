# Garritan Studio — Acoustic Room Designer

## Status

Implemented on \`feature/stage-acoustics-sync\` with a SwiftUI panel
inside the compact and expanded Orchestral Stage inspector. This is a
**prototype of original algorithmic room design**, not a physically measured
room simulator. The legacy Apple Concert Hall remains unchanged by default.

## Room inputs

- Length / width (3–80 m), height (2.2–35 m).
- Wall, floor and ceiling materials.
- Wall-treatment material and coverage fraction (0–100% of **wall area**,
  replacing the underlying wall surface, not added atop it).
- Sabine or Eyring average absorption model.
- Project-specific custom room name.

Materials carry six representative octave-band absorption coefficients for
125, 250, 500, 1000, 2000 and 4000 Hz. The values are generic engineering
references informed by the [OSHA technical manual](https://www.osha.gov/otm/section-3-health-hazards/chapter-5)
and related architectural-acoustics tables. They are **not** lab-tested
coefficients for a particular product or installation; mounting, thickness,
air gaps, occupancy and humidity are not modeled.

## Calculation

Define volume V = length × width × height, and total internal area
S = 2×LW + 2×LH + 2×WH. Compute octave-specific equivalent absorption
A = floor area×floor coefficient + ceiling area×ceiling coefficient +
wall area×[(1−coverage)×wall coefficient + coverage×treatment coefficient].

Sabine: T60 = 0.161 V / A.

Eyring: T60 = 0.161 V / [−S ln(1−A/S)].

These equations assume a diffuse sound field and do not derive
individual reflected sound paths. Eyring generally produces shorter times
than Sabine for very absorptive surfaces. The UI displays unbounded
mathematical predictions, but the native FDN clamps RT targets to 0.2–15 s.

A separate 7-tap geometry-informed approximation derives early reflection
delay estimates from wall/ceiling/floor dimensions. Stereo gain and timing
are additionally varied by each instrument's stage pan and depth. This is
a simplified psychoacoustic approximation, not full image-source tracing.

## DSP integration

Custom Room is an additional **fifth** Audio Unit room slot; the four
existing venue-inspired factory profiles retain their stable IDs, positions
and original three-band processing. When the custom slot is selected,
the 16-line FDN uses a new six-band decay mode implemented with five
cumulative first-order lowpass filters, split at ~177, 354, 707, 1414
and 2828 Hz. Gains are precomputed per delay line outside audio rendering.
The bands are approximate DSP filters, not IEC octave measurements.

The shared FDN's late field and the per-track early reflection processors
receive the generated profile, without adding a third-party plugin or
runtime convolution. Selecting Apple Medium Hall mutes the added early
reflection return and returns to the tested legacy route.

### Acoustic realism improvements

A custom room now also sets an **FDN delay-spacing scale** based on the
cube root of room volume relative to a reference 1,728 m³ stage. Values
are bounded to approximately 0.72–1.75 so small and large rooms produce
different initial late-field density without excessive memory demand. Each
delay line preallocates the largest required ring buffer before rendering.
When a factory preset is selected, its original delay distances and
three-band damping remain unchanged.

Custom **early reflection brightness** is derived from area-weighted
4 kHz surface absorption, with a single precomputed high-cut coefficient
applied per instrument before its reflection delay. More absorption
typically makes the reflections darker. All filter coefficients are
prepared outside the render callback; factory reflections bypass the new
filter. These are psychoacoustic approximations, not boundary-element
simulation, full ray tracing, or an acoustically exact model.

The **Apply Custom Acoustic Room** action is intentionally disabled during
playback and recording. It stops AVAudioEngine, prepares new native DSP
resources, then restarts the engine. We do not yet provide glitch-free
continuous morphing while playing. Existing custom decay tails may be
cleared when applying new geometry; this is intentional at the milestone.

## Persistence and compatibility

Optional \`DAWState.acousticRoomDesign\` contains the complete Codable room
definition, alongside \`acousticRoomProfileID\`. Older projects decode as
before and default to the Apple hall; a project saved with the custom
room selection will restore its material, geometry and AU configuration.
Only successfully applied settings are persisted.

## Offline six-band calibration and published reference anchors

The `NativeRoomImpulseAnalyzer` now estimates EDT, T20 and T30 separately
at 125, 250, 500, 1,000, 2,000 and 4,000 Hz. It integrates **stereo
energy separately**, avoiding cancellation that occurred when opposite
polarity channels were averaged. A band too near the sample-rate Nyquist
limit returns nil rather than inventing a measurement.

The macOS development command
`swift run -c release RoomAcousticCalibration --seconds 6` produces a JSON
report for **four factory rooms plus the default custom design**.
`--design-file <path>` accepts a JSON-encoded `StudioAcousticRoomDesign`
to measure another design offline. Each row includes:
- Six-band design/reference target (labeled as a real custom design or as
  an *interpolated estimate* for three-band factory presets).
- Measured synthetic EDT, T20 and T30, when enough dynamic range exists.
- T20 absolute error, percentage error and an **unapplied** tuning
  suggestion; these are not authoritative or automatic calibration.
- Wet-only C80, not an ISO-style direct-plus-reverberant C80 value.

The GitHub macOS workflow saves `native-room-calibration.json` and
prints a compact per-frequency comparison. Actual numeric results must
be reviewed before making stronger accuracy claims.

The [REVERBDATA research anchors](./reverbdata-measured-anchors.json)
preserve source-attributed **T30,wide** values and the measurement positions
for Gulbenkian Hall, the Convent of Christ church and refectory, Jerónimos
church, and the Crow's Cloister cistern. These *broadband* values are not
reused as six octave-band RT targets. Website licensing is CC BY-NC-SA,
so no external impulse audio is distributed or embedded in Studio.
Additional dataset rights and measurement conditions need review before
using individual octave-band curves for quantitative tuning.

## Testing and remaining validation

Automated Swift tests cover both RT formulas, surface geometry, absorptive
treatment, backward project decoding, distinct profile impulse responses,
and preservation of the legacy four-profile layout.

A full macOS CI run must verify build + regression suite + Release build.
The in-app plugin instantiation and sound must still be verified in one
consolidated user testing milestone. We should further add smooth
reconfiguration, robust room-mode/standing-wave analysis, manufacturer
material coefficients, and optional calibrated microphone positions before
claiming physical realism.
