# Alpha 1 — per-track instrument MIDI transmit channel

This change is stacked on the isolated Alpha 1 crash-safety draft branch. It is **not** merged into the tested Alpha 1 checkpoint or main and has not undergone real Mac hardware validation.

## User-facing controls

In the lower Instruments/V-Rack workspace, select a track, then open **Channel**:

- **MIDI Transmit Channel:** *Follow MIDI Source* (compatibility default) or Channel 1–16. This changes the channel of notes (including note-offs/keyswitches), CC, program changes, bends and aftertouch sent to the track instrument. For an ARIA Player part on its default channel, choose **Channel 1** even if the attached keyboard transmits on Channel 10. Changing this during playback requires stopping/restarting transport for the newly compiled timeline.
- **MIDI Input Channel Filter:** *All Input Channels* or Channel 1–16. This decides which input/recorded events the track accepts, without remapping them. Leave it on All unless filtering is intentional.
- **ARIA Volume Channel (CC7):** controls only the outgoing CC7 fader message if explicitly set. It is separate from track MIDI transmit routing; otherwise CC7 prefers the transmit channel.
- **V-Rack instruments:** their destination menu already includes a separate channel per route, which continues to override the track transmit setting.

## Engineering boundaries

- Track gains optional persisted `midiTransmitChannel` (zero-based), with `nil` preserving existing recordings and older project behavior.
- Live input routes to the selected channel before calling the AU/native instrument note, CC, program, and bend APIs.
- AVAudioEngine MIDI worker compilation, native analog sequencer, and experimental Core Audio hybrid preparation use the same channel override. V-Rack destinations keep their explicitly selected channel.
- Note-off and keyswitch emissions remain paired with note-on at the selected channel, and changing the output channel sends sustain-off/all-notes-off to the track's own instrument before updating the model.
- MIDI source events are not destructively rewritten; original clip channel information is preserved in the project.
- The prior crash-safety patch remains separate from the official Alpha 1 candidate; no changes to ARIA hosting, audio graph, Rooms, reverb or persistence systems.

## Verification gate

Run `Alpha 1 track MIDI transmit channel` macOS CI at the exact branch head. It must complete Swift package compilation, full Swift tests, and optimized DAWApp compilation. The new regression tests cover independent input filtering/transmit remapping, output channel consistency for note-off and CC, and old project decoding.

After CI passes, perform **one** disposable-project Mac check: choose **Channel 1** transmit and **All Input Channels** filter on an ARIA track, play keys from a device emitting channel 10, then draw/play a MIDI phrase, save/reopen and verify the channel selection survived. Use the generic ARIA controls while the native ARIA editor remains a suspected crash trigger. Existing projects and sample libraries must not be modified in testing.

Known qualification: changing the transmit channel while the transport is active changes live playthrough immediately, but playback timeline packets were compiled at Play; restart transport to recompile them.
