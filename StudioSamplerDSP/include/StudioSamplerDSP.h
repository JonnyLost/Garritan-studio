#ifndef STUDIO_SAMPLER_DSP_H
#define STUDIO_SAMPLER_DSP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Native Studio Sampler, authored for this project. No third-party DSP.
 * Build all zones OFF the audio thread, before attaching the renderer.
 * Once rendering starts, zone storage is immutable until destruction.
 * Only ss_render() runs on the audio thread; it never allocates or locks.
 * MIDI submissions use a bounded SPSC queue (one serialized producer).
 */
typedef struct SSSampler SSSampler;

SSSampler *ss_create(double output_sample_rate, int32_t max_voices);
void ss_destroy(SSSampler *sampler);

/* Samples are copied into sampler-owned RAM before first render.
 * left/right are planar Float32; right may be NULL for mono.
 * Returns 1 on success, 0 for invalid input, exceeded limits or allocation.
 * Velocity and note bounds are inclusive. The regular zone API retains
 * the original one-shot behavior when no sustain-loop markers are supplied.
 */
int32_t ss_add_zone(SSSampler *sampler,
                    uint8_t root_note, uint8_t lowest_note, uint8_t highest_note,
                    uint8_t lowest_velocity, uint8_t highest_velocity,
                    double source_sample_rate,
                    const float *left, const float *right, uint32_t frames);
/* Loop bounds are source sample-frame positions, [start, end) with
 * end exclusive. end == 0 disables looping (start and fade must also be 0).
 * For an enabled loop, 0 <= start < end <= frames and fade <= (end-start)/2.
 * Loop crossfades are active only until note-off, after which the sample tail
 * plays under the release envelope.
 */
int32_t ss_add_zone_with_loop(SSSampler *sampler,
                    uint8_t root_note, uint8_t lowest_note, uint8_t highest_note,
                    uint8_t lowest_velocity, uint8_t highest_velocity,
                    double source_sample_rate,
                    const float *left, const float *right, uint32_t frames,
                    uint32_t loop_start_frame, uint32_t loop_end_frame,
                    uint32_t loop_crossfade_frames);
/* Nondestructive playback trim and sustain loop. All offsets are absolute
 * source sample frames, end positions exclusive. 0 <= start < end <= frames.
 * Sustain loop is disabled when loop_start == loop_end == loop_fade == 0.
 * Bounds and samples are immutable once audio rendering starts.
 * Existing ss_add_zone and ss_add_zone_with_loop remain ABI-compatible.
 */
int32_t ss_add_zone_with_region(SSSampler *sampler,
                    uint8_t root_note, uint8_t lowest_note, uint8_t highest_note,
                    uint8_t lowest_velocity, uint8_t highest_velocity,
                    double source_sample_rate,
                    const float *left, const float *right, uint32_t frames,
                    uint32_t playback_start_frame, uint32_t playback_end_frame,
                    uint32_t loop_start_frame, uint32_t loop_end_frame,
                    uint32_t loop_crossfade_frames);
/* Extended zone creation: per-sample fade ramps and articulation group.
 * fade_in + fade_out cannot exceed playback region length. ID 0 is default.
 * Call only while configuring sampler before the first audio callback.
 */
int32_t ss_add_zone_with_options(SSSampler *sampler,
                    uint8_t root_note, uint8_t lowest_note, uint8_t highest_note,
                    uint8_t lowest_velocity, uint8_t highest_velocity,
                    double source_sample_rate,
                    const float *left, const float *right, uint32_t frames,
                    uint32_t playback_start_frame, uint32_t playback_end_frame,
                    uint32_t loop_start_frame, uint32_t loop_end_frame,
                    uint32_t loop_crossfade_frames,
                    uint32_t fade_in_frames, uint32_t fade_out_frames,
                    uint8_t articulation_id);
/* Extended mapped-zone configuration for multisampled instruments.
 * round_robin_index: 0...7 (alternate takes, selected per MIDI note).
 * release_trigger: 0 for note-on recording; 1 for note-off one-shot tail.
 * All zones are configured before rendering; legacy APIs default to 0/0.
 */
int32_t ss_add_zone_with_variation(SSSampler *sampler,
                    uint8_t root_note, uint8_t lowest_note, uint8_t highest_note,
                    uint8_t lowest_velocity, uint8_t highest_velocity,
                    double source_sample_rate,
                    const float *left, const float *right, uint32_t frames,
                    uint32_t playback_start_frame, uint32_t playback_end_frame,
                    uint32_t loop_start_frame, uint32_t loop_end_frame,
                    uint32_t loop_crossfade_frames,
                    uint32_t fade_in_frames, uint32_t fade_out_frames,
                    uint8_t articulation_id,
                    uint8_t round_robin_index, uint8_t release_trigger);
/* Streaming zones retain only a source-frame attack prefix. The background
 * reader owns file decoding; the render thread accesses immutable attack PCM
 * and two preallocated 4096-frame pages per active voice.
 * attack PCM starts at playback_start_frame; full_frames is total source
 * length (it may be far larger than the RAM-only zone limit).
 * All other mapping/loop/fade/articulation arguments have the same meaning
 * as ss_add_zone_with_variation. Called only before rendering starts.
 */
int32_t ss_add_stream_zone(SSSampler *sampler,
                    uint8_t root_note, uint8_t lowest_note, uint8_t highest_note,
                    uint8_t lowest_velocity, uint8_t highest_velocity,
                    double source_sample_rate,
                    const float *attack_left, const float *attack_right,
                    uint32_t full_frames, uint32_t attack_frames,
                    uint32_t playback_start_frame, uint32_t playback_end_frame,
                    uint32_t loop_start_frame, uint32_t loop_end_frame,
                    uint32_t loop_crossfade_frames,
                    uint32_t fade_in_frames, uint32_t fade_out_frames,
                    uint8_t articulation_id,
                    uint8_t round_robin_index, uint8_t release_trigger);

enum { SS_STREAM_PAGE_FRAMES = 4096 };
typedef struct SSStreamRequest {
    int32_t voice_index;
    int32_t slot_index;
    int32_t zone_index;
    uint32_t start_frame;
    uint32_t frame_count;
    uint64_t voice_serial;
} SSStreamRequest;

/* Dedicated NON-AUDIO worker ONLY. One serialized background consumer.
 * claim: atomically reserves a requested page for decoding. Returns 1 on
 * success, 0 when idle. Reading a claimed request does no file I/O.
 * supply: copies decoded planar PCM into a fixed buffer and publishes via
 * release/acquire ownership. right may be NULL for mono. Short EOF pages
 * are allowed. abandon: discard a failed request so playback cannot stall.
 * Shutdown must join the worker BEFORE ss_destroy() is called.
 */
int32_t ss_stream_claim(SSSampler *sampler, SSStreamRequest *request);
int32_t ss_stream_supply(SSSampler *sampler, const SSStreamRequest *request,
                         const float *left, const float *right, uint32_t frames);
void ss_stream_abandon(SSSampler *sampler, const SSStreamRequest *request);
uint64_t ss_stream_underrun_frames(const SSSampler *sampler);

int32_t ss_zone_count(const SSSampler *sampler);

/* MIDI events take effect at the next rendering block boundary.
 * Each submission returns 0 if the queue is full or the data is invalid.
 * Channels are MIDI 0...15. */
int32_t ss_note_on(SSSampler *sampler, uint8_t note, uint8_t velocity, uint8_t channel);
int32_t ss_note_off(SSSampler *sampler, uint8_t note, uint8_t channel);
int32_t ss_all_notes_off(SSSampler *sampler);

/* Keyswitch map is immutable configuration, created before first render.
 * Entries map distinct MIDI notes to articulation IDs 0...15.
 * The configured notes do not themselves sound. 0 selects default group.
 */
int32_t ss_configure_keyswitches(SSSampler *sampler,
                                const uint8_t *notes,
                                const uint8_t *articulation_ids,
                                int32_t count);
int32_t ss_select_articulation(SSSampler *sampler,
                              uint8_t articulation_id, uint8_t channel);

/* CC1 drives continuous dynamic-layer crossfading when enabled; CC11 drives
 * expression on held notes. Both are smoothed by the audio renderer.
 * The mode is queued and applies to notes started after it is processed.
 * A single serialized MIDI producer is required, as for note events.
 */
int32_t ss_control_change(SSSampler *sampler, uint8_t controller,
                          uint8_t value, uint8_t channel);
int32_t ss_set_cc1_crossfade(SSSampler *sampler, int32_t enabled);

/* ADSR times in seconds, sustain in linear [0,1]; times in [0,30].
 * The render thread snapshots parameters for newly started voices.
 * The default is a short anti-click attack/release and flat sustain.
 * Changes never allocate, lock or read files in the render callback.
 */
int32_t ss_set_adsr(SSSampler *sampler, float attack_seconds,
                    float decay_seconds, float sustain_level,
                    float release_seconds);

/* Two non-overlapping planar output buffers, frames > 0.
 * No malloc/free, locks, file I/O, Objective-C, Swift, or logging.
 */
void ss_render(SSSampler *sampler, float *left, float *right, int32_t frames);

#ifdef __cplusplus
}
#endif
#endif
