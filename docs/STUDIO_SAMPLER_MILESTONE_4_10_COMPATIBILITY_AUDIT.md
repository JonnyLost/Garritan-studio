# Studio Sampler — Milestone 4.10: Import Compatibility & Safety Audit

Status: implementation committed on `feature/studio-sampler-native`; **macOS CI and real-library audition not yet confirmed**. No Alpha 1 merge.

## Scope and implementation

The existing importers remain offline converters to editable `.studioinstrument` patches. No third-party sampler, DAW, or commercial library runtime is used.

| Format | Currently supported subset | Important remaining limits |
| --- | --- | --- |
| SFZ | Region samples, key/velocity ranges, root, loops, common inheritance, `default_path`, managed import | Complex opcodes, expression, scripting, unsupported codecs, advanced crossfades |
| SF2 | Preset/instrument mappings, key/velocity zones, root, PCM16 WAV extraction, supported loops, linked stereo | Fine pitch, envelopes/filters/modulators, huge banks, compressed SF3 |
| GIG | RIFF/DLS wave-pool lookup, supported dimensions for velocity, RR, release, keyswitch and regular CC1/CC2, PCM16 WAV extraction | GIG3 extended containers/compressed waves, custom thresholds, complex/continuous controller dimensions |
| EXS24 | Little-endian binary zones, stored samples, velocity groups, forward loops, basic release, supported RR/keyswitch/CC1/CC2 selection | Legacy encoding variations, modern Logic extensions, Logic articulation IDs, custom group selectors and synthesis details |

**These are implemented subsets, not claims of broad compatibility with every commercial instrument.**

## Milestone 4.10 corrections

1. **EXS24 sample-file authorization.** An `.exs` file can hold stale absolute paths. Treat these as hints, not permission to access unrelated user files. Restrict source resolution to the instrument directory or a separately, explicitly selected sample folder. Resolve symlinks before checking containment. When a recording is missing, the mapping UI requests a sample folder before retrying.
2. **SFZ sample-file authorization.** SFZ can reference samples outside its own folder only when the user selects the extra root. Reject parent traversal, absolute paths and symlinks that escape an authorized directory. The UI can ask for a missing sample folder and resume importing.
3. **MacBook storage economy.** One sample may be mapped to many MIDI notes. SFZ imports now copy every distinct recording once and reuse the managed reference across all zones. EXS, SF2 and GIG already deduplicate their respective referenced recordings.
4. **SFZ audio validation.** Inspect a distinct source sample's audio metadata only once using AVAudioFile before changing library contents. Reject damaged/unreadable recordings, unsupported channel configurations, and loop points that extend past the recorded frames.
5. **Native package round-trip.** A multi-zone SFZ import is now covered by a test that exports to `.studioinstrument`, reloads the package and verifies that the original note mapping and shared recording survive.

## Regression scenarios committed

- Two SFZ regions referencing one sample result in one managed recording.
- Missing SFZ/EXS samples can be located using an explicit root.
- File-system symlink paths cannot escape the authorized root.
- EXS embedded absolute sample references cannot bypass the selected-folder grant.
- Invalid/corrupted SFZ audio is rejected before copying.
- SFZ out-of-range loops are rejected; valid loop bounds are maintained.
- SFZ import -> package export -> package load preserves the keyboard map and deduplicated recording.
- Previous dedicated SF2/GIG/EXS tests remain in the DAWCore test target.
- Native DSP standalone sanitizers continue to exercise sampler MIDI and streaming primitives.

## Remaining gate before broad compatibility claims

- **CI**: latest macOS Swift build, DAWCore regression tests and Release app build must finish successfully on an unchanged head. Prior runs have often been cancelled by successive commits. Do not report green just from native DSP sanitizer success.
- **Real instrument fixtures**: obtain permission to test representative SFZ, SF2, GIG, and EXS24 files; cover complex dimensions, older encodings, unsupported-case messages and sample-path variants without exposing or redistributing proprietary sample content.
- **Large sessions**: measure peak memory, disk footprint, open files, sample streaming latency and cancellation cleanup on MacBook hardware.
- **Sandbox behavior**: test file-picker security-scoped access and explicit folder grants in the signed sandboxed macOS app.
- **Audio audition**: compare note ranges, velocity splits, articulation switches, release tails, loops and round-robin choices on actual instruments.

Keep the frozen Alpha 1 sampler snapshot (`feature/studio-sampler-alpha1-frozen`, PR #34) independent of these compatibility changes. No merges without owner approval.
