# Garritan Studio — interface direction (v0.1)

Decision: prioritize the clarity and instrument-first workflow of Musio Studio, rather than a dense traditional DAW. This is a design reference, not a request to copy proprietary assets or branding.

## Principles
1. Instruments first: search and browse the user's licensed Garritan libraries without needing to understand plugin internals.
2. Progressive disclosure: keep common actions visible; reveal deep MIDI, routing and mixer controls when needed.
3. One coherent workspace: library browser, loaded instruments, transport, arrangement, and an optional inspector.
4. Reversible choices: users can still open ARIA's native interface and edit original MIDI.
5. Preservation: portable project metadata, clear dependency warnings, exportable MIDI/audio, no sample redistribution.
6. Accessible macOS interface: keyboard navigation, VoiceOver labels, adjustable text and panel sizes.

## Initial layout
- Left: searchable instrument browser, library/family filters, favorites.
- Center: loaded instruments and compact MIDI arrangement, with a piano roll on selection.
- Right: contextual instrument controls, ARIA native-editor button, routing and articulations.
- Top: project name, play/stop/record, tempo, meter, save state.
- Bottom (collapsible): mixer and automation.

## Milestones
M0: Verify existing DAW builds and the ARIA plugin is discoverable.
M1: Load ARIA, play a note, hear audio; show native ARIA editor.
M2: Save/reopen project with instrument and plugin state restored.
M3: Introduce instrument-first browser and simplified workspace.
M4: Optional Orchestra View grouped by orchestral section.

## Important unknowns
- Whether ARIA offers host-visible preset metadata sufficient for direct instrument loading.
- Whether existing VST3 bridge supports plugin UI, MIDI events and state serialization end-to-end.
- How to enumerate installed Garritan library patches without parsing or redistributing proprietary content.

Until validated, use ARIA's native editor as the instrument-selection fallback.
