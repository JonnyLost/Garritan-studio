#ifndef STUDIO_ADDITIVE_DSP_H
#define STUDIO_ADDITIVE_DSP_H

#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Studio's original 16-partial polyphonic additive instrument. All partials
 * are computed from a small sine table. Rendering is allocation-free and
 * processes timestamped MIDI on an SPSC queue with an atomic panic path.
 * Serialise producers outside the render callback, as with Studio FM.
 */
typedef struct SADDSynth SADDSynth;
#define SADD_PARTIAL_COUNT 16
#define SADD_PARAM_ATTACK 0
#define SADD_PARAM_DECAY 1
#define SADD_PARAM_SUSTAIN 2
#define SADD_PARAM_RELEASE 3
#define SADD_PARAM_OUTPUT_GAIN 4
#define SADD_PARAM_TILT 5
#define SADD_PARAM_EVOLVE 6
#define SADD_PARAM_EVOLVE_TIME 7
#define SADD_PARAM_BEND_RANGE 8
#define SADD_PARAM_PARTIAL_BASE 9
#define SADD_PARAMETER_COUNT 25

SADDSynth* sadd_create(double sampleRate, int32_t voices);
void sadd_destroy(SADDSynth* synth);
int32_t sadd_set_parameter(SADDSynth* synth, int32_t parameter, float value);
float sadd_get_parameter(const SADDSynth* synth, int32_t parameter);
/* Note on/off, CC1/64/120/123, bend. Frame offsets relative to next
 * render buffer; producers may supply up to 65535 frames ahead.
 */
int32_t sadd_midi_event(SADDSynth* synth, uint8_t status,
                        uint8_t data1, uint8_t data2, uint32_t frameOffset);
int32_t sadd_all_notes_off(SADDSynth* synth);
void sadd_reset_stopped(SADDSynth* synth);
void sadd_render(SADDSynth* synth, float* left, float* right, int32_t frames);

#ifdef __cplusplus
}
#endif
#endif
