# Studio Sampler Milestone 4.12 — Native Kontakt NKI compatibility

**Development branch:** `feature/studio-sampler-native`

**Status:** First unprotected legacy mapping subset implemented; macOS CI and actual Kontakt instrument audition remain necessary. This milestone is *not* broad/full Kontakt compatibility. Frozen Alpha 1 sampler PR #34 is unchanged and remains separate.

## Goal and boundaries

Studio can read and convert **some legacy, unencrypted Kontakt `.nki` files** directly into a native editable sampler patch. Kontakt, Native Instruments Audio Units, commercial importers and third-party decode engines are not required by the conversion or by Studio playback.

NKI is a proprietary family of formats, not one stable public interchange standard. This first importer recognizes **one legacy K2_Container map compressed using RFC1950/zlib**, typically with a binary instrument header. It deliberately does not open protected libraries, interpret scripts, decode embedded monolith audio, convert `.ncw` or `.nkx` archives, or bypass copy protection.

## Implemented

- `StudioSamplerNKIReader.swift`: bounded inspection of a recognizable zlib/DEFLATE XML K2 mapping. Uses Apple's **Compression** and Foundation XML parser; does not execute scripts or read instrument sample audio during metadata inspection.
- Validates RFC1950 header and Adler32 integrity, bounds both source and expanded sizes, enforces one program and no more than 128 zones, disables external XML references and rejects XML DTD/entity constructs.
- Maps each K2 program/group's key and velocity intersections with zone pitch/root note, range, trims, supported sustain loops and release trigger.
- Warns about filter, continuous modulation, effects, per-zone gain, pan and tuning that Studio does not yet fully reproduce. Rejects scripts, more than one program, reverse and non-pitch-tracked zones, incompatible loops, and unknown/protected container layouts.
- `StudioSamplerNKIImporter.swift`: resolves ordinary external WAV/AIFF/CAF sample recordings inside the NKI's folder or a user-selected extra sample folder; prevents parent traversal and symlink escapes; embedded absolute paths are *hints only*, never blanket authorization to read elsewhere.
- Checks referenced audio metadata, sample trim/loop boundaries and native patch validity before installing any samples. Copies distinct validated recordings only once into Studio's library. Original NKI and source recordings remain untouched.
- Resolves sample paths by their exact relative folder hierarchy before fallback; supports explicit relinking to the sample-folder root or its parent. Basename-only recovery is allowed only for a single unambiguous recording in authorized folders, preventing accidental substitution when multiple instrument sections use `tone.wav`.
- Regression fixtures verify two same-named recordings in different section folders retain distinct audio through native save/reopen; explicit folder relinking takes precedence over a misleading basename match, and ambiguous recovery fails with an actionable error.
- `StudioSamplerMapView.swift`: **Import Kontakt Instrument (.nki)…** menu command, compatible file picker and explicit optional sample-folder relinking; conversion is staged until **Apply Mapping**.
- Dedicated synthetic tests: valid compressed K2 XML, key/velocity layers, loop/trim, sample deduplication, safe sample path handling and explicit grants, release triggers, unsupported script/programs, damaged zlib checksum, malicious DTD and out-of-range loops.
- End-to-end `.studioinstrument` save → reopen test also verifies the restored native sampler object can be constructed and receive MIDI.

## Not yet supported

| Variant / behavior | Current result |
| --- | --- |
| Kontakt 1–4 legacy NKI with readable K2/zlib map, external uncompressed samples | First supported subset, conditional on recognized map |
| Contact 4.2+ with newer proprietary state payloads, and many Kontakt 5–8 NKIs | Unsupported; must not be claimed as compatible |
| Factory / commercial encrypted NKIs, NKX or NKS containers | No import or protection bypass |
| NKI monolith containing audio samples | Not extracted |
| NCW-compressed sample references | Not decoded |
| Kontakt scripts, detailed instrument group rules and MIDI processing | Rejected / unsupported, not executed |
| Advanced envelope/filter/LFO, tuning, gain, pan, complex loops | Not fully translated |
| NKM Multi, NKB Bank, NKR Resource, NKSN Snapshot | Separate future formats |

NKI libraries may carry license restrictions independent of the file format. Do not redistribute commercial recordings. This support is aimed at original, user-created and otherwise legitimately accessible materials.

## Remaining verification gates

1. GitHub Actions: **macOS build and DAW regressions**, **Native DSP sanitizers**, and **Release app build** must pass on the same final commit. Do not infer build success from merely queued or cancelled CI.
2. Validate a collection of legally obtained unprotected NKI fixtures from representative Kontakt generations; inspect actual XML variants before expanding mapping assumptions.
3. Check sandbox file picker permissions, sample-folder grants, missing-source recovery and error messaging in the signed macOS app.
4. Audition original vs Studio instruments for correct key splits, velocities, release samples, loops and polyphony.
5. Profile large NKI sample sets on MacBook; confirm streaming, memory use and disk deduplication.
6. Decide later if native NCW decoding or advanced group mapping is technically worthwhile without third-party runtime dependencies.

## Format and framework references

- Native Instruments Kontakt File Formats and Classic View / Save Instrument documentation
- Apple's Compression framework, `COMPRESSION_ZLIB` (raw DEFLATE per RFC1951)
- Publicly shared K2_Container XML format observations used solely as documentation; implementation written natively in Swift

**Integration:** The latest compatibility branch has not been merged. Alpha 1 remains pinned to the separate frozen branch. Only combine after owner authorization and milestone verification.
