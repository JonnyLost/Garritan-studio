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
int32_t ss_zone_count(const SSSampler *sampler);

/* MIDI events take effect at the next rendering block boundary.
 * Each submission returns 0 if the queue is full or the data is invalid.
 * Channels are MIDI 0...15. */
int32_t ss_note_on(SSSampler *sampler, uint8_t note, uint8_t velocity, uint8_t channel);
int32_t ss_note_off(SSSampler *sampler, uint8_t note, uint8_t channel);
int32_t ss_all_notes_off(SSSampler *sampler);

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
