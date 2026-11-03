# Garritan Studio — ARIA integration feasibility plan

Status: planning / not yet tested on target Mac.

## Proven source facts
- The fork is based on mpatti/musio-create, a Swift/SwiftUI macOS DAW.
- Package.swift declares DAWCore, DAWUI, VST3Bridge, VST3BridgeCpp and DAWApp targets; macOS 14 minimum.
- DAWApp/Sources/DAWApp/DAWApp.swift declares a project document type and provides open/save commands.
- The upstream README states MIT, but a root LICENSE file has not yet been verified. Confirm full notices before distribution.

## Target libraries
Garritan Personal Orchestra 5; Jazz & Big Band; Concert & Marching Band; World Instruments; Instant Orchestra.

## Integration hypothesis (unverified)
Host the user's already-installed ARIA VST3 (or Audio Unit fallback), send MIDI, receive audio, and persist plugin state. Do not reverse engineer protected samples or redistribute licensed content.

## Investigation checklist
1. Identify the actual VST3 bridge implementation, plugin scan/instantiate functions, and whether it renders audio in real time.
2. Trace MIDI events from DAWCore tracks to hosted plugin and audio to Core Audio output.
3. Inspect project serialization and determine where opaque plugin-state blobs and dependency manifests can be stored.
4. Verify plugin state save/restore after quitting and relaunching.
5. Confirm whether instrument preset selection is host-controllable; retain ARIA's native UI as fallback.
6. Inventory all third-party licenses and upstream copyright notices.

## First acceptance test (on the user's Mac)
- Record Mac model/chip, macOS version, ARIA version, plugin format and paths.
- Load an ARIA instance in the DAW and select a licensed GPO5 instrument.
- Play MIDI notes and hear audio.
- Save, quit, reopen, and verify the same instrument and settings.
- Export a short audio render and record failures/repro steps.

## Preservation rules
- Keep original library files and authorizations outside the repository.
- Never commit proprietary sample content, installers, activation keys, credentials, or private recordings.
- Save portable MIDI, project metadata, plugin-state snapshots where supported, and rendered audio backups.
- Track library dependencies and versions separately from musical project content.

## Pending environment information
Apple Silicon or Intel; exact macOS version; whether ARIA and all five libraries are currently installed and working.

## Upstream attribution
Based on Musio Create by Mike Patti: https://github.com/mpatti/musio-create
Keep original copyright notices and license text; do not assert relicensing until verified.
