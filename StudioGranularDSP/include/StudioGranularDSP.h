#ifndef STUDIO_GRANULAR_DSP_H
#define STUDIO_GRANULAR_DSP_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct SGRSynth SGRSynth;
/* Maximum decoded audio in memory. No file I/O occurs in the render callback. */
#define SGR_MAX_SOURCE_FRAMES 524288
#define SGR_PARAM_GRAIN_SIZE 0
#define SGR_PARAM_DENSITY 1
#define SGR_PARAM_POSITION 2
#define SGR_PARAM_SCAN_SPEED 3
#define SGR_PARAM_PITCH 4
#define SGR_PARAM_PITCH_JITTER 5
#define SGR_PARAM_POSITION_JITTER 6
#define SGR_PARAM_PAN_SPREAD 7
#define SGR_PARAM_ATTACK 8
#define SGR_PARAM_RELEASE 9
#define SGR_PARAM_GAIN 10
#define SGR_PARAM_REVERSE 11
#define SGR_PARAM_WINDOW 12
#define SGR_PARAMETER_COUNT 13
/* Factory source IDs: 0 cloud, 1 strings, 2 bells, 3 noise. */
SGRSynth* sgr_create(double sampleRate, int32_t polyphony);
void sgr_destroy(SGRSynth* synth);
int32_t sgr_set_parameter(SGRSynth* synth, int32_t id, float value);
float sgr_get_parameter(const SGRSynth* synth, int32_t id);
/* Both source-setting methods MUST only run before attaching/starting audio,
 * or after the audio graph is stopped and its callbacks have drained.
 * They are intentionally not safe to call concurrently with sgr_render.
 */
int32_t sgr_select_factory_source_stopped(SGRSynth* synth, int32_t sourceID);
int32_t sgr_load_pcm_stopped(SGRSynth* synth, const float* mono,
                             int32_t frames, double sourceSampleRate);
int32_t sgr_source_frames(const SGRSynth* synth);
int32_t sgr_midi_event(SGRSynth* synth, uint8_t status, uint8_t data1,
                       uint8_t data2, uint32_t frameOffset);
int32_t sgr_all_notes_off(SGRSynth* synth);
void sgr_reset_stopped(SGRSynth* synth);
void sgr_render(SGRSynth* synth, float* left, float* right, int32_t frames);
#ifdef __cplusplus
}
#endif
#endif
