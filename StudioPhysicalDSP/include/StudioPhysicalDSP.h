#ifndef STUDIO_PHYSICAL_DSP_H
#define STUDIO_PHYSICAL_DSP_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Native waveguide / modal physical-modeling foundation.
 * Construction, destruction and reset happen with rendering stopped.
 * One serialized MIDI producer; the audio callback is the only consumer.
 */
typedef struct SPMSynth SPMSynth;
#define SPM_PARAM_MODEL 0          /* 0 plucked string, 1 struck string */
#define SPM_PARAM_BRIGHTNESS 1     /* 0..1 excitation / loop-filter brightness */
#define SPM_PARAM_DAMPING 2        /* 0..1 higher = longer decay */
#define SPM_PARAM_POSITION 3       /* 0.05..0.95 string contact position */
#define SPM_PARAM_BODY_MIX 4       /* 0..1 modal body resonances */
#define SPM_PARAM_RELEASE 5        /* 0.01..4 seconds */
#define SPM_PARAM_GAIN 6           /* 0..1 */
#define SPM_PARAMETER_COUNT 7

SPMSynth* spm_create(double sampleRate, int32_t polyphony);
void spm_destroy(SPMSynth* synth);
int32_t spm_set_parameter(SPMSynth* synth, int32_t parameter, float value);
float spm_get_parameter(const SPMSynth* synth, int32_t parameter);
/* MIDI: note on/off, CC64, CC120/123 and +/-2-semitone pitch bend.
 * Frame offsets carry across successive renders; 1 accepted, 0 rejected. */
int32_t spm_midi_event(SPMSynth* synth, uint8_t status, uint8_t data1,
                       uint8_t data2, uint32_t frameOffset);
int32_t spm_note_on(SPMSynth* synth, uint8_t note, uint8_t velocity);
int32_t spm_note_off(SPMSynth* synth, uint8_t note);
/* Atomic panic: clears active voices at the next render callback. */
int32_t spm_all_notes_off(SPMSynth* synth);
void spm_reset_stopped(SPMSynth* synth);
/* Planar float stereo, overwrites the output. No memory allocation,
 * locks, file I/O or system calls occur during rendering. */
void spm_render(SPMSynth* synth, float* left, float* right, int32_t frames);
#ifdef __cplusplus
}
#endif
#endif
