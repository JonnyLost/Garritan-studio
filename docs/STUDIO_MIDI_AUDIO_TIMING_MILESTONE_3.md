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
* Core Audio late note-offs deliver at offset zero rather than disappearing.
  Other overdue events retain the baseline discard policy so a seek does not
  newly retrigger old notes. This is not a substitute for generation filtering
  on seek or replacement; old releases also require generation ownership.
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
late releases affecting a newer voice after an unguarded seek. Keep the PR draft pending macOS and hardware review.

## Milestone 3B — render-clock worker scheduling and generation cancellation

### Baseline and paths inspected

Continued the existing branch at `b4d5cf4a82cb9ab0d23de72549730b7dc0a36b7e`;
remote branch and draft PR #29 matched before editing. No prior commit was
replaced. The M3 timestamp adapter, late-release policy, atomic ring, 20,480
message harness and million-event SPSC test remain intact. The earlier sections
record M3's historical scope; this section describes what 3B supersedes.

Inspected both PlaybackEngine preparation paths, AudioEngine timing/mixdown,
TransportState play/stop/loop events, ProjectViewModel seek/loop/project cleanup,
track/rack removal, Analog's render-local sequence, other native wrappers,
Sampler producers and TrackInstrument AU/ARIA delivery. No DSP/preset/project
format or unrelated integration branch was imported or changed.

### Shared clock and V-Rack changes implemented

A silent AVAudioSourceNode now publishes its AudioTimeStamp sample position to
`StudioMIDITransportClock`. It ensures the engine can advance before the first
rack note or future audio region sounds. Its first render sample maps to the
session's captured absolute project start frame; subsequent positions use the
engine sample delta, not callback arrival time or mach wall time. The source is
the mailbox's sole render writer. Normal and export mixer taps only consume
progress/capture PCM and no longer dispatch MIDI work per buffer.

V-Rack, generic AUs/ARIA, Apple sampler, FM, Hybrid (Wavetable, Additive,
Granular, Physical), native Sampler and Analog's worker fallback now use one
precompiled sample-frame score and monotonic cursor. Complete note pairs,
controllers, bend, program, channel/poly pressure are encoded once; MIDI 1.0
status bytes and destination channel overrides are preserved. Unsupported
native controls remain unsupported. SysEx remains outside this channel-message
scheduler. Precompiled Analog retains its existing DSP score path.

A 1 ms high-priority serial worker poll wakes delivery. **Timer time does not
advance the score**: only published render-frame deadlines do. The old 5 ms
V-Rack MIDI event scan and active-note beat deadline scan were removed.
The remaining 5 ms timer serves auxiliary audio region starts and metronome on
the control thread, using the same published sample position. It is not a MIDI
clock. Automation and ostinato remain their existing control/live systems; this
milestone does not move them into the compiled score.

Worker frames use AVAudioEngine's sample rate, including hybrid V-Rack. The
optional Core Audio backend retains its own correctly rate-converted start.
Transport's runtime sample rate is updated at Play; persisted project rate and
file formats are unchanged.

### Timing guarantees and limits

Musical beats, scheduled project sample frames, actual instrument render time
and device output latency remain distinct. Shared clock math truncates beat
conversion and uses half-open render deadlines. At equal frames: note-off,
controller/program/bend/pressure, note-on, stable original order within classes.
Zero-duration sounding notes receive a minimum one-frame release interval.

The worker has deterministic sample-frame deadlines and preserves their order.
It still calls immediate native/AU/ARIA compatibility APIs. Poll latency,
thread scheduling and instrument queue consumption can delay actual audio.
The source's clock observation does not constitute an AU pre-render delivery
contract, and cannot safely be passed as a future absolute AU timestamp or
native next-buffer offset. M3's direct Core Audio AU timestamp adapter remains
unchanged. Universal sample accuracy is NOT established.

### Generation and cleanup design

The C11 mailbox has monotonically changing generations: even = active,
odd = cancelled. Control operations are serialized; the sole render writer
owns its engine sample anchor. The callback performs bounded atomic loads and
stores, never waits for a coherent snapshot, and allocates nothing. Worker
snapshots are accepted only for the installed generation. Each packet also
checks the current generation before delivery, so invalidation interrupts a
budget of simultaneous events. No old callback dispatch closures survive a
restart because per-buffer dispatch was removed entirely.

Stop/pause, preparation (seek, loop lap, export pass, project replacement), and
engine invalidation cancel before a serial worker barrier. Cleanup executes
against OLD instrument snapshots before new routing/score publication. It
releases tracked keys and CC64/66/123 on used channels even after cancellation;
cleanup deliberately bypasses stale ordinary-event filtering. Removal cleans
only the affected destination, disables its future events and preserves other
rack destinations. Native render-local sequences keep existing stop/all-notes-
off APIs. Ordinary uninterrupted worker playback sends no blanket cleanup.
Once Stop returns, the old serial worker cannot deliver ordinary MIDI into the
next generation. An instrument may retain its own release tail or reject an
underlying API call; those acoustic/receiver behaviors are not proven here.

### Loop, seek, tempo and reconfiguration policy

Loop end excludes new onsets and clamps worker/Analog note ends to the boundary.
A region note already sounding across a seek/loop start is not retriggered;
existing planner restoration supplies latest CC/program/bend/pressure and
articulation state ahead of future notes. Notes are cut/released at a lap
transition; they are not tied seamlessly across laps. The existing UI/control
loop-wrap rebuild remains and may create a gap; sample-accurate seamless loops
are still future work. Cleanup handles pedal-held voices before restoration.
No MIDI editing or saved region durations are modified.

ProjectViewModel tempo edits now pause/clean and rebuild at the captured
musical beat. Direct external tempo publications during playback safely pause
rather than apply a changed BPM to an old score. There is still no persisted
tempo-map implementation. Engine/device or buffer-size reconfiguration cancels
MIDI and pauses transport; Play rebuilds a new generation. A changed source
sample rate recreates the silent clock source off the render thread. Automatic
seamless device switching/resumption is not implemented.

### Capacity, performance and real-time assessment

The clock is a fixed-size coalescing mailbox, not a queue of MIDI packets.
100,000/unbounded position observations can coalesce while the worker is busy
without losing any compiled release. The score retains all packets in memory;
there is no fixed packet capacity in this worker score. The optional Core Audio
ring's 32,768-slot capacity is unchanged. Each worker poll
examines at most 2,048 packets. Remaining packets, including releases, are
retained for later polls, even if no new clock observation arrives. A cancelled
session uses independent cleanup instead of draining obsolete ordinary events.
Memory scales with project score size; controller/note tracking allocates ONLY
on the non-render worker. Dense scores can therefore increase memory and
worker lateness; this is bounded delivery work, not a throughput guarantee.

Render work is limited to zeroing the silent stereo source and C atomic clock
publication. No locks, logging, file access, dispatch or UI state reads were
added there. Worker registry/state is a separate nonactor object confined to
the serial queue; control mutations use barriers outside rendering. Main-thread
auxiliary audio/metronome and existing audio latency compensation remain
limitations. The optional Core Audio graph's older quiescence/reset and fixed
MIDI ring capacity limitations from M3 remain; worker guarantees do not fix them.

The standalone sanitizer harness measures a million clock publications and
prints elapsed host time, separately from its million-event SPSC test and
10,000 concurrent generation transitions. A local instrumented Linux run took
0.011730 s for a million clock observations; this is a synthetic atomic-call
throughput observation, NOT MacBook CPU use, event-to-audio latency or jitter.
No hardware performance figures are claimed.

### Tests and CI evidence

Added 20 deterministic worker/compiler/clock tests covering simultaneous V-Rack
order, explicit note pairs, zero velocity/duration, loop clipping/exclusion,
controller/pressure/program bytes, channel overrides, stale generations,
cancellation within a chord, pedal cleanup, stop/restart/project replacement,
1,000 simulated seeks/laps, 70,000 packets through 17-packet budgets, boundary
releases, destination removal, clock coalescing, frame-based progression,
seek-state restoration, rate/tempo recompilation and no normal blanket cleanup.
These test the production compiler, mailbox and worker; they do not simulate
macOS UI event timing or prove instrument audio output. Prior timing, MIDI
import/export, project/preset, native DSP and sampler regressions are retained.
The C sanitizer test also races one render writer with 10,000 control transitions.

Local C ASan/UBSan tests passed (leak detection unavailable under local ptrace).
Required macOS dependency resolution, full debug build/test, optimized DAWApp,
sampler ASan/UBSan, disk stress and read-only reconciliation run through the
existing consolidated acceptance workflow. Results for the exact 3B head are
linked in draft PR #29 and the branch's GitHub Actions runs; a green M3 run is
not evidence for 3B. Final completion requires those 3B checks to pass.

### MacBook acceptance and recommended 3C

Repeat the earlier acceptance matrix with multiple ARIA instances/channels,
first-note silence and future audio regions, high-density native/Hybrid/Sampler
scores, sustained notes across rapid seeks and 100+ loop laps, stop immediately
after seek, restart immediately after stop, project replacement, tempo edits,
instrument removal and device/buffer/rate changes. Confirm reconfiguration
pauses safely and Play restores controller/articulation state. Record CPU,
buffer/rate/device, dropped/stuck notes and receiver failures. Compare recorded
loopback transients with score frames and audible metronome/audio alignment.
Inspect audio export/stems and save/reopen against the same baseline projects.

3C should establish a real pre-render per-instrument handoff with explicit
engine-frame/AU-frame translation and bounded receiver backpressure, extend
native Sampler/control support, replace control-thread loop rebuilds with
render-owned boundary transitions, schedule metronome/audio on that contract,
and measure MacBook output timing before claiming synchronized acoustic output.
Do not integrate Picture or a competing time authority to solve these gaps.

3B control-order follow-up: MainActor transport/tempo subscriptions and audio
position delivery now remain synchronous. An unnecessary main-queue hop could
otherwise let a queued Play or old sample position execute after a later Stop,
seek or loop rebuild. Added manual AVAudioEngine rendering coverage of the
actual silent clock source (progress, silence, cancellation, re-anchor), plus
synchronous seek/stop/restart transport-subject coverage. These are additional
to the 20 worker/compiler tests; UI hardware behavior remains an acceptance item.

A backwards render sample timestamp now fails closed with a single atomic CAS
that cannot overwrite a newer control generation. The worker cleans old voices;
a new Play re-anchors instead of reusing the invalid device clock. Added a
deterministic regression for this path (23 total new Swift tests in 3B).

The transport toolbar's Return to Zero (and Go to End) now uses pause/locate/play
while running, instead of moving only the UI playhead over an unchanged score.
A regression verifies its synchronous pause/rebuild sequence and that locating
a stopped transport never starts it (24 new Swift tests total in 3B). The first
macOS test build exposed a Swift type-check timeout in the dense fixture; an
explicitly typed loop retains the same 70,000 packets and assertions.

macOS validation also caught a new fixture setup error: AudioEngine prepares
its device graph during initialization, so the offline clock test must fully
stop that graph before enabling manual rendering (the established V-Rack test
pattern). The fixture was corrected without skips or relaxed assertions.

### Verified macOS source validation

At source commit `6755f676f9b52cfb0109ad993ebcfce3d86b4250`,
[Sampler acceptance](https://github.com/JonnyLost/Garritan-studio/actions/runs/43739915103)
passed dependency resolution, complete Swift build, all 460 regressions,
optimized DAWApp build and native DSP sanitizer checks. This includes the
actual offline render-clock source test and all 24 new 3B tests.
[Consolidated acceptance](https://github.com/JonnyLost/Garritan-studio/actions/runs/43739915088)
provides the independent full-suite, sampler/disk/MIDI sanitizer and read-only
reconciliation evidence; inspect that run for its release/final conclusion.
The subsequent documentation-only commit records this evidence. Draft PR #29
links the final head's consolidated run separately; no M3 success was reused
as a substitute for 3B validation.

A spontaneous backwards source timestamp fails MIDI closed. If a structural
graph restart does not also issue a device-configuration notification, the
transport display may require Stop then Play to re-arm. Seamless live graph
replacement, receiver queue acceptance/backpressure and measured acoustic
synchronization remain explicit 3C/hardware gaps.
