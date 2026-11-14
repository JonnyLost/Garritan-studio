# Studio Analog — Step 6: Preset browser and sound library

## Available in the instrument window

Open a track using Studio Analog and choose **Presets** at the top of the
synth panel. This opens a native, searchable browser. Preset categories are
filterable, and the factory and user banks appear separately.

Selecting a row shows the sound's name, description, oscillator waveforms,
filter setting and routing type. **Load on Track** validates the new patch,
hands its modular graph to the C++ engine for a safe buffer-boundary change,
then updates every native synthesis parameter and embeds the patch in the
project. **Audition C4** plays the loaded instrument using Studio's existing
test note. Browsing a row alone does not alter the current sound.

When the native graph is still processing a previous change, the new patch is
not saved or partially applied. The browser shows the "busy" error and the
user can retry after the pending buffer renders. Abrupt graph/parameter
changes can still click; click-free crossfading remains a future goal.

## First factory library — 24 original sounds

| Category | Sounds |
|---|---|
| Bass | Sub Foundation, Pulse Driver, Acid Walk, Deep Reese |
| Lead | Classic Saw Lead, Pulse Solo, Fifth Horizon, Mellow Solo |
| Pad | Warm Strings, Air Bloom, Slow Brass, Luminous Fifths |
| Keys | Analog Electric Keys, Dusty Keys, Glass Organ, Vintage Square Keys |
| Pluck | Copper Pluck, Wooden Click, Glass Droplet, Fifth Pluck |
| Texture | Noise Wash, Rising Fog, Hollow Wind, Motion Bed |

Each factory preset is a deterministic, versioned recipe of parameter values
for our **original synthesis engine**, not a recording or a third-party bank.
Factory presets are read-only. The native DSP tests and preset tests are run
in GitHub Actions; actual sound judgments still require a listening milestone.

## Saving and recalling your own sounds

Choose **Save Current Sound…** and supply a name (up to 80 characters),
category and optional description. Studio makes a portable JSON copy of the
track's current parameter overrides and patch cable layout. User presets
survive between projects and are stored under:

\`~/Library/Application Support/Garritan Studio/Studio Analog Presets/\`

Files use the suffix \`.studioanalog.json\` and an internally generated UUID
filename. Writes are atomic to reduce partial-file corruption. Unreadable,
invalid or future-version preset files are skipped individually and a visible
warning is shown; other user presets and factory sounds still load.

**Delete Preset** removes only the user-bank file (never factory patches).
Any project that previously loaded a deleted preset still contains its own
embedded snapshot and will sound the same when reopened.

## Safety and compatibility

- A \`StudioAnalogPreset\` includes stable ID, type (factory/user), name,
  description, category and a complete \`StudioAnalogPatch\`.
- Patch versions 1 and 2 can be read. Versions newer than this build supports
  are rejected rather than silently stripping unsupported synthesis features.
- Strict validation rejects unknown parameter IDs, non-finite and out-of-range
  controls, duplicate destination inputs and invalid cable types. The actual
  C++ graph compiler makes the final decision about cycles and topology.
- The currently selected preset ID is optional in project \`Track\` JSON; the
  embedded patch is authoritative. Moving a knob or cable clears the selection
  ID, indicating an edited sound. Old projects do not need migration.
- User presets can be backed up by copying their JSON files. The first
  browser does not yet provide built-in import/export buttons, overwrite
  confirmation, tags/favorites, cloud sync or a preset version history.
- Preset loads and Save Current Sound are not currently integrated with
  Studio-wide undo; cable edits retain their earlier local undo/redo.

## Automated verification

\`StudioAnalogPresetLibraryTests\` covers factory count/IDs/category coverage,
parameter validation, C++ routing acceptance, saving/loading/deleting user
presets from an isolated temporary directory, damaged file isolation, and
legacy patch decoding.

The GitHub workflow also runs the existing native DSP AddressSanitizer /
UndefinedBehaviorSanitizer smoke suite, AVAudioEngine offline sound test,
Swift package tests and an optimized \`DAWApp\` build.

**Scope:** \`feature/studio-analog\` and draft PR #2 only. Do not merge into
\`feature/stage-acoustics-sync\` without explicit user approval.
