# Studio FM — Phase 3: factory sound library and native preset browser

## First FM factory bank

Studio FM now contains 32 original four-operator synthesis recipes. No
sample recordings, commercial synth state, proprietary waveforms, paid
libraries or network access are needed.

| Category | Original factory sounds |
| --- | --- |
| Electric Keys | Aurora Electric; Velvet Tines; Crystal Stage; Midnight Organ |
| Bells | Starlight Bell; Silver Arc; Temple Bronze; Ice Pendant |
| Mallets | Rosewood Mallet; Glass Marimba; Copper Keys; Satin Vibes |
| Bass | Furnace Sub; Fretless Current; Digital Rubber; Octave Circuit |
| Lead | Neon Solo; Hollow Signal; Cobalt Edge; Lyric Glass |
| Pad | Lunar Choir; Glacier Light; Deep Atmosphere; Harmonic Cloud |
| Percussion | Steel Strike; Digital Wood; Glass Tick; Machine Pulse |
| Texture | Nebula Veil; Rust Horizon; Frozen Orbit; Chromatic Drift |

The recipes deliberately use different FM algorithms, operator ratios,
modulation depths, envelope timings and amounts of operator feedback.
Their names describe *intended* tonal characters; final timbral curation
and balancing require a listening session on the Mac.

## How to use the browser

Open an FM track's native editor and select **Presets**. Browse both Factory
Sounds and My Presets; filter by category or search names and descriptions.
Selecting a row previews the algorithm, operator ratios and a description.
**Load on Track** replaces the live synthesis parameters with the chosen
recipe and saves a full copy into the track's FM patch. **Audition Loaded
C4** plays the sound currently loaded on the track (not merely highlighted
in the browser).

**Save Current Sound** creates a user preset containing the algorithm,
four operator ratios, levels, envelopes, feedback, output and pitch bend
settings. A project stores an embedded sound even if the user bank file is
later deleted, and moving a slider clears the preset identity as "edited".
Deleting a factory preset is never allowed.

User sounds are portable JSON files at:

\`~/Library/Application Support/Garritan Studio/Studio FM Presets/\`

All disk operations happen on UI/control paths, *never* the DSP callback.
Files use a UUID filename with extension \`.studiofm.json\`. Writes are
atomic; preset IDs and parameter values are strictly validated, and
individual corrupt or unsupported files are skipped and reported rather
than hiding the entire library. The first bank is offline-first.

## Scope and limitations

FM and Studio Analog have separate factory and personal preset banks.
Neither modifies the sampler branch. Live sound updates use the native
atomic parameter API; note panic clears voices before a new preset loads.
Abrupt parameter changes may click, so per-parameter smoothing remains
a future improvement.

Future sound-library work can include tagging/favorites, imported/exported
sound bundles, richer velocity/modulation and automated loudness analysis.

## Verification

\`StudioFMPresetLibraryTests\` covers 32 distinct sound recipes, complete
eight-category coverage, all four algorithms, parameter range validation,
loading each sound in the C++ FM engine, user preset save/reload/delete,
embedded project restoration, corrupt-file isolation, and older project
format decoding.

GitHub Actions checks original DSP under AddressSanitizer / UBSan, macOS
debug build, Swift regression suite and release DAWApp build.

**Do not merge draft PR #3 without explicit approval.** Hardware listening
and balance adjustment are pending a single consolidated Mac audition.
