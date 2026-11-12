# Studio FM — Phase 4: expression, real-time smoothing, and audition plan

Branch: `feature/studio-fm` | Draft pull request #3. No merge permitted
without explicit product-owner approval.

## Performance improvements

- **Velocity → brightness**, range 0–1. MIDI note velocity still controls
  output amplitude as before. Optionally, it now also changes the FM
  modulation index on modulator operators, rather than merely making the
  same waveform quieter. Default is 0 (legacy behavior).
- **CC1 modulation wheel**, independently tracked for 16 MIDI channels.
  It can be assigned to either vibrato or FM harmonic brightness.
  Vibrato: 0–2 semitones at full wheel/depth, user-adjustable LFO speed
  0.1–20 Hz (default 5 Hz); Brightness: up to 3× modulation-index gain
  when depth and wheel are both at maximum. Wheel effects are applied
  only to sounding voices of that MIDI channel.
- **Smooth live controls:** one-pole 12-ms smoothing in the C++ audio
  renderer on operator levels and frequency ratios, global feedback,
  output gain, velocity-to-brightness intensity, modulation wheel depth
  and vibrato rate. CC1 amount itself is smoothed to reduce abrupt
  timbral/pitch transitions. The callback allocates nothing and takes
  no locks. Discrete FM algorithm changes and envelope time edits are
  still buffer-boundary events and may click.
- All original parameter IDs 0–27 are unchanged. Appended new IDs:
  28 Velocity Brightness, 29 Mod Wheel Destination, 30 Wheel Depth,
  31 Vibrato Rate. Existing projects and the 32 original factory sounds
  decode unchanged and receive the backward-compatible defaults.
- The new controls are in the Studio FM instrument's **MIDI Expression**
  card; the patch and user-bank JSON store them as regular native
  FM parameters. Existing CC64 sustain and pitch bend remain intact.

## Automated regression coverage

- Original FM DSP under ASan/UBSan, reject invalid discrete parameters,
  and verify gradual output gain attenuation after a live change.
- Swift FM DSP: compare matched waveform renders to verify CC1 brightness,
  CC1 vibrato, MIDI channel isolation and velocity-driven timbral change.
- Native SwiftUI integration: validate new control IDs/ranges, project
  parameter persistence and older FM project compatibility.
- Full macOS `swift build`, `swift test --parallel` and optimized DAWApp.
  Verify actual latest GitHub Actions run before declaring these passed.

## One consolidated Mac listening milestone — not yet performed

Open Studio FM in a separate worktree and audition the factory bank
through Studio's normal mixer and Concert Hall. Use the same MIDI velocity
and C4/C5 note lengths for comparison, adjusting by ear:

1. **Keyboard and mallet voices:** Aurora Electric, Velvet Tines,
   Rosewood Mallet, Satin Vibes—compare gentle versus hard strikes.
   Ensure brightness response sounds musically useful, not simply louder.
2. **Bells:** Starlight Bell, Temple Bronze, Ice Pendant—check long tails,
   modulation index, clipping, and room sends on repeated notes.
3. **Leads:** Neon Solo and Lyric Glass—test CC1 vibrato at 3–7 Hz,
   pitch bend, fast wheel returns and channel isolation.
4. **Pads and textures:** Lunar Choir, Harmonic Cloud, Nebula Veil,
   Frozen Orbit—check long attack/release, voice reuse, CPU and RAM,
   stage position and reverb while playing dense chords.
5. **Automation and transport:** adjust operator levels/ratios, feedback
   and output during held notes; play/pause/stop MIDI clips, reopen the
   project, and verify a saved user preset. Check no hung notes.
6. **Regressions:** audition Studio Analog and ARIA on separate tracks,
   check metering, pan and Concert Hall are unchanged.

Record observed bugs, excessive CPU, unexpectedly quiet/loud presets,
and objectionable clicks for a single post-test refinement pass.

Remaining separate work: host-to-render-clock sample-accurate FM MIDI
sequencing (Analog already has its own timeline); smooth *algorithm*
switching; proper loudness calibration and timbral curation of the 32
factory sounds, and any optional favorites/import/export features.
