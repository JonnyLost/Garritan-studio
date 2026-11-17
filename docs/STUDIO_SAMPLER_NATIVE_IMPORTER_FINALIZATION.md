# Studio Sampler Native Importer — Finalization Gate

**Branch:** `feature/studio-sampler-native`
**Review scope:** SFZ, SF2, GIG, EXS24, native `.studioinstrument`, plus the intentionally narrow legacy Kontakt `.nki` subset.
**Disposition:** Feature implementation closed for this scope. Automated macOS verification, representative real-world source fixtures, and the consolidated on-Mac audition are release gates, not presumed passes.

## What this delivers

Studio Sampler can import supported unencrypted sample mappings and preserve their playable sample recordings independently of external instrument plugins. Supported routes can be saved as native `.studioinstrument` packages and restored without losing key/velocity splits, sample trims, loops, release triggers, supported articulations and variation settings. Native patches and the DSP engine remain Studio-owned and do not require Kontakt at playback.

| Source | Implemented boundary | Excluded / cautions |
| --- | --- | --- |
| SFZ | Supported subset of regions, inheritance, key/velocity mapping, audio samples | Do not claim the entire SFZ opcode specification |
| SF2 | Native preset and mapped PCM extraction | Not every SoundFont generator/modulator |
| GIG | Recognized GigaStudio PCM waves and supported variation/controller maps | Proprietary compressed data and unrecognized conditions not generally supported |
| EXS24 | Recognized legacy EXS instrument zones and supported groups | Not every Logic Sampler group/FX/modulation variant |
| `.studioinstrument` | Versioned self-contained native library, checksums, safe restore and sample-file deduplication | Unknown future manifest versions are rejected |
| Kontakt NKI | Only one legacy, unprotected zlib K2_Container XML mapping variant with ordinary external WAV/AIFF/CAF files | No modern NKI versions, encrypted libraries, Kontakt scripting, protected content, NCW, monoliths or NKX; unverified group-start rules are refused |

## Importer quality contract

1. **Do not modify sources.** External instrument and recording bytes remain unchanged during preview/import.
2. **Keep mappings exact.** Do not silently merge similarly named recordings, ignore unsafe selectors, or guess between ambiguous sample locations.
3. **Honor user authorization.** No path traversal, symlink escape, implicit permissions from embedded absolute paths, DTD/entity expansion, or unbounded metadata inflation.
4. **Fail before activation.** Validate mapping and recordings, import a private copy, and activate only on explicit Apply Mapping.
5. **Keep playback native and efficient.** Streaming, polyphony and audio routing belong to Studio's DSP path, not external plugin engines.
6. **Round-trip without corruption.** Portable export/import retains sample contents and zone performance metadata. Custom destinations must not be mislabeled as Studio's global sample folder.

## Final automated verification gate

Run the branch's `Studio Sampler native checks` GitHub Actions workflow **on the final commit** and require:

- `Native DSP with sanitizers` **success**, including multivoice streamed-zone stress.
- `macOS build and DAW regressions` **success**:
  - `swift package resolve`
  - `swift build`
  - `swift test --parallel` (including SF2, GIG, EXS, SFZ, NKI round-trip and native package tests)
  - `swift build -c release --product DAWApp`
- Zero silently skipped/failed importer tests. A queued, cancelled, timed-out or failed job is **not** approval.

## Mac acceptance gate (consolidated with Alpha 1)

On an actual Mac, import legally accessible sample sets with normal sandbox file picker permissions; verify sample-folder relinking and no missing audio after save/reopen; compare representative sources by ear for key splits, velocities, release behavior, loops and variation; record CPU, memory, underruns and streaming behavior in a substantial orchestral session.

This is one consolidated testing checkpoint, not a request for repeated testing during implementation. Real Kontakt compatibility requires representative unprotected source fixtures; synthetic fixtures are useful for regressions but cannot prove compatibility with every generation.

## Integration boundary

- This branch is **not** merged into frozen Alpha 1 sampler candidate PR #34.
- The standalone importer feature is **development-scope complete**, but **not fully release-verified** until final-commit macOS workflow and on-Mac acceptance are green.
- Do not advertise universal `.nki` compatibility.
- Modern Kontakt formats, proprietary compressed audio and advanced group logic are a **separate future project**, not hidden unfinished requirements of this limited importer.
