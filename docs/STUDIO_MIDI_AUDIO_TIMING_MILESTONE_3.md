# Milestone 3: MIDI timing and audio synchronization

## Status and provenance

This is a bounded implementation toward Milestone 3, **not full milestone completion**.
Baseline verified remotely: `integration/studio-alpha1-consolidated-2026-11-14`
at `7fded2f9b9947cad12baaa31e8c0584bf4bd8024` on 2026-11-15.
Development branch: `codex/studio-midi-audio-timing-m3`.
No merges, preset changes, project format changes or modifications to PRs 27/28.

Reviewed `architecture/studio-independence` at `c055f906` without merging:
its isolated StudioMIDIClockMath and acquire/release SPSC cursor were reused.
Its graph, crossfade, transport and audio architecture were not imported.
Alpha 1 has newer session planning, expression, export and preset functionality
that would be lost by a wholesale replacement.

## Original architecture and verified defects

StudioMIDISessionPlanner already compiles clip bounds, articulation actions,
channel filters and seek restoration. It remains the musical event source.
Core Audio precompiles channel messages into a sorted ring, then MIDIScheduler
computes offsets before RenderGraph renders AUs at session sample positions.
Verified: RenderGraph discarded that offset and scheduled AU MIDI immediately;
it also created a Swift Array per MIDI packet. RingBuffer used ordinary mutable
head/tail variables and memory barriers, which do not provide atomic ownership.
MIDIEventRingBuffer discarded all overdue events, including note-offs.
CoreAudioBackend formatted and printed debug messages inside rendering.

The default AVAudioEngine legacy path dispatches asynchronous MIDI work from
a timing callback, with immediate AU delivery and active-note beat deadlines.
Analog alone has a precompiled render-local score. The optional hybrid backend
uses a 5 ms worker timer for V-Rack, audio clip starts and metronome. Those
clocks remain different. Worker delivery must not be described as sample accurate.

## Implemented contract

* Existing constant session BPM and sample rate define beat/sample conversion:
  `seconds = beats / BPM * 60`; frames truncate toward zero. Invalid input returns
  zero; overflow saturates. No persisted tempo-map representation was introduced.
* PlaybackEngine conversions and native Analog relative-frame compilation use
  StudioMIDIClockMath. Analog previously rounded to the nearest frame; this
  removes that sub-frame rounding discrepancy with the transport conversion.
* Buffers are half-open `[start, end)`. The end belongs to the next callback.
* Core Audio late events deliver at offset zero rather than disappearing.
  This policy assumes events still belong to the current session; it is not a
  substitute for generation filtering on seek or replacement.
* Core Audio AU block receives `max(eventFrame, bufferStart)` in the same
  session sample coordinate as its following AU render timestamp. Legacy
  MusicDevice delivery retains the buffer-relative offset.
* Program and channel pressure packets have two bytes; other channel messages
  have three. Stack tuple storage replaces per-message Array allocation.
* Precompiled ordering remains note-off, controller/program/bend/pressure,
  note-on, then stable insertion order. Worker preparation now explicitly
  preserves planner insertion order at equal beats.
* Ring handoff uses one producer and one consumer with release publication and
  acquire observation. Clear/reset still REQUIRE quiescent producer/consumer.
  Generic payloads containing reference types can still release on consumption;
  MIDI and metronome payloads are value types.

## Coverage and validation

StudioMIDITimingTests is a timestamp measurement harness: 20,480 messages across
irregular 127-frame windows compare expected frames against actual scheduler
callback offsets. It verifies ordering preservation, release delivery, exclusive
boundaries, two-byte AU packet sizing, tempo/sample-rate math and overflow.
Existing session-planner, articulation, preset and project regressions remain
part of the complete Swift suite; they were not weakened.
Tests/DAWRealtimeStandalone/midi_spsc.c tests full/empty capacity, clear/reset,
wraparound and one million ordered values across concurrent producer/consumer.
The existing consolidated acceptance workflow runs the new Swift suite and C
stress along with debug/release builds, sampler sanitizers and disk stress.

Local Linux: C stress passes with ASan/UBSan and leak detection disabled because
LeakSanitizer cannot run under this executor's ptrace environment. No Swift or
Apple SDK is installed here. macOS build/test and optimized app acceptance must
be obtained from GitHub Actions; Linux is not a substitute. No audio-output
latency, jitter, CPU or acoustic measurements are claimed by these tests.

## Remaining work and safety limits

This change does NOT establish generation cancellation, atomic transport/graph
publication, device/sample-rate reconfiguration safety, sample-accurate looping,
live tempo-map edits or synchronized audio/metronome/automation/ostinato output.
Core Audio still has shared mutable transport/graph state; its control APIs do
not yet enforce callback quiescence before reset. Its fixed-size MIDI queue can
still overflow during preparation without reporting failure. A larger coherent
follow-up should solve immutable session publication, bounded/refillable event
storage and generation ownership together before enabling wider use.

FM, Wavetable, Additive, Granular and Physical synths retain existing worker
queue delivery; their DSP was not changed. Native Sampler retains immediate
note/controller delivery and has no pitch-bend implementation in TrackInstrument.
ARIA's compatibility-specific direct delivery remains untouched. Aftertouch is
encoded in Core Audio preparation, but worker handling remains incomplete.
Sustain/CC1/CC11, MIDI Learn, mappings and instrument state restoration remain
existing behavior; this patch does not prove measured output timing for them.

Transport stop already serializes worker cleanup and releases pedal-held notes;
seek rebuilding already uses the session planner's controller restoration.
These existing behaviors are not proof of stale-generation immunity. Stop,
restart, seek, loop and project replacement need integration tests before full
milestone acceptance. Do not infer support for picture scoring from this patch;
future picture interfaces should consume the existing session clock.

## MacBook acceptance

1. Build this branch on macOS 14+ with the project's Swift toolchain; run the
   complete test suite and optimized DAWApp build. Preserve existing projects.
2. In a disposable project, test dense repeated notes and simultaneous chords,
   CC1/11, sustain on/off, bend, aftertouch, articulations and program changes.
   Compare Analog, other native synths, Native Sampler and multiple ARIA/AU
   instances through track and V-Rack routes. Record unsupported controls.
3. Stop while sustain is down; restart, seek both ways, loop a short region,
   edit tempo and time signature, replace the project. Check for stuck/dropped
   notes and stale controller state. Repeat under orchestral load.
4. Change device and 44.1/48/96 kHz rates while stopped, then during playback
   only with safe monitoring levels. Report behavior; this patch does not
   guarantee reconfiguration during playback.
5. Record or loop back output with a known click and MIDI phrase. Compare
   expected sample frames with recorded transients separately from scheduler
   timestamps. Test audio tracks, metronome, automation and ostinato alignment.
   Capture buffer size, device, rate, instrument version, CPU and dropout count.

Primary regression risks: AU implementations interpreting absolute scheduling
differently, one-frame Analog quantization differences, and previously dropped
late events becoming audible. Keep the PR draft pending macOS and hardware review.
