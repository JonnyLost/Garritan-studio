# Studio Sampler — Durable Sample References & Streaming Stress Checks

Feature branch: `feature/studio-sampler-native`.
No branch merges, additional commercial plugins, paid sample libraries or
proprietary SDKs are needed for this milestone.

## Imported sample lifetime and project reopen

Studio already creates its own copy of every audio recording imported through
the sampler interface in:

`~/Library/Application Support/GarritanStudio/SamplerSamples/`

This avoids requiring a persistent security-scoped bookmark for the original
source file in the user's Downloads, external drive or another folder.

The updated sampler patch saves an optional `managedFileName` alongside its
legacy `filePath`. This is a **single validated filename**, never an arbitrary
relative path. On reopen, the current Application Support directory is used
to resolve it, even if the original absolute path referred to a different
macOS user home. Previously imported UUID-prefixed paths in earlier patch
versions are recognized without changing any musical settings.

Before the PlaybackEngine replaces an active instrument, Studio validates
every source file. Missing recordings produce a clear, recoverable error
instead of discarding the old instrument or silently substituting a
different recording. The mapping workspace shows **Relink Sample** for missing
zones. Relinking imports a fresh private copy and updates every zone that
referred to the same missing source, preserving MIDI mappings, velocity
layers, ADSR, loop/trim points, fades, articulations and round-robin flags.
The repair remains a draft until **Apply Mapping**.

The managed library rejects `../`, absolute names and directory traversal
in untrusted saved sample references. It never searches arbitrary locations
for same-named audio, and it never modifies the original external recording.
If a batch import fails, only that batch's newly created copies are rolled
back.

### Important remaining limit

The app-managed sample library is **not yet a portable project package**.
Moving a project to a second Mac still requires transferring the referenced
private samples or relinking them there. An explicit portable export should
be designed separately with space estimation and optional sample deduplication:
silently embedding hundreds of gigabytes into every DAW autosave would be
unacceptable on a MacBook.

## Multi-voice streaming stress

A separate C++17 sanitizer-backed stress binary simulates:

- 72 streamed recording zones (three round-robin takes on 16 pitches,
  release samples on eight pitches, and a second articulation on 16 pitches)
- Up to 64 active voices with overlapping note-ons and note-offs
- Concurrent disk worker claims and page supply on a separate thread
- Occasional 1.5 ms disk-read stalls and transient page failures
- Repeated keyswitches, CC11 expression, panic/all-notes-off and voice stealing
- More than 700 audio render blocks while source PCM is fetched independently

The stress test verifies bounded requests, safe worker shutdown, finite audio
buffers, clipped-output limits and successful command processing. Unlike
simple sequential rendering, it deliberately interleaves the realtime
renderer with a slow or unavailable page supplier.

This is **synthetic disk-stall simulation**, not a benchmark of a particular
USB/Thunderbolt drive or an entire orchestral session. Hardware listening,
battery profiling, drive disconnect/relink tests and actual high-polyphony
performance measurements remain part of the consolidated Mac testing phase.

## Test files

- `Tests/DAWCoreTests/StudioSamplerSampleLibraryTests.swift`
- `Tests/StudioSamplerDSPStandalone/stream_stress.cpp`
- `.github/workflows/studio-sampler.yml`

The existing native audio and project tests continue running, including
offline macOS `AVAudioEngine` playback of a four-second streamed recording.
Build results on the latest commit, not an earlier cancelled attempt, are
the authority for the status of this work.
