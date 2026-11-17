# Studio Sampler — Milestone 4.11: End-to-End Import Verification

**Scope:** Native external-instrument conversion, portable instrument persistence, and initialization of the production sampler. Development branch `feature/studio-sampler-native`; frozen Alpha 1 PR #34 remains separate.

## What is automated

Tests are intentionally built from small, original synthetic file-format fixtures so CI does not depend on copyrighted commercial libraries.

1. **SFZ:** A multi-zone map using one recording imports with one managed sample, round-trips through `.studioinstrument`, and retains note regions and recording bytes. Audio metadata and loop bounds are checked before import; missing sample folders and symlinks are handled conservatively.
2. **SF2:** Synthetic mono and linked-stereo SoundFonts convert to native WAV recordings. Each converted patch is exported into a portable Studio instrument package and reloaded; PCM bytes and full zone/loop metadata are checked.
3. **GIG:** Synthetic uncompressed GigaStudio recordings and combined velocity/round-robin dimension cases round-trip through the instrument package. Distinct recordings and per-zone variation metadata must survive.
4. **EXS24:** Synthetic EXS24 group round-robin and CC1 articulation-group instruments round-trip; sample bytes and articulation/controller settings must survive intact.
5. **Common native acceptance:** The shared helper `StudioSamplerExternalFormatRoundTrip.assertPreserved` verifies:
   - source sample bytes vs. restored sample bytes
   - every zone, note/velocity bound, loop and performance/variation setting
   - equivalent sample sharing (no missing or duplicated recordings)
   - valid package manifest and restoration via the production APIs
   - successful construction of `StudioSamplerInstrument` with the restored patch, and acceptance of MIDI note-on, note-off, and all-notes-off commands, without requiring an attached audio device.

## Gates and confidence level

- GitHub Actions **Native DSP with sanitizers** checks DSP queue and streaming behavior, including the separate streamed-zone stress test.
- GitHub Actions **macOS build and DAW regressions** performs Swift builds, DAWCore tests (including the above fixtures) and a Release app build.
- A green build on the exact latest commit is necessary before calling the automated gate passed. A queued/in-progress/cancelled job is **not** a successful verification.
- Passing synthetic fixtures verifies the converter subset and instrument workflow, **not** broad compatibility with every real SFZ/SF2/GIG/EXS24 bank.
- Real-world validation remains an open gate: user-authorized instrument files on the Mac, sample-folder sandbox grants, expressive articulations, release tails, disk-streaming performance, actual audio audition, large orchestral sessions and comparison with source sampler behavior.

## Remaining known limitations

- SFZ: many modulation/opcode/CC behaviors unsupported.
- SF2: SF2 generator/modulator and effects support is partial; SF3 compressed files unsupported.
- GIG: extended/compressed formats and irregular dimension boundaries unsupported.
- EXS24: modern Logic-specific conditions/articulation IDs and custom controller splits unsupported.
- The importer reports or rejects unsupported behavior rather than silently claiming a perfect sound reproduction.

**Integration:** The compatibility branch must not be merged into the frozen Alpha 1 build without an explicit product-owner decision, full build verification, and the consolidated Mac audition milestone.
