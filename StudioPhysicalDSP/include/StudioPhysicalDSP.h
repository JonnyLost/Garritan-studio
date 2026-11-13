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
#define SPM_PARAM_MODEL 0          /* 0 plucked, 1 struck, 2 bowed, 3 reed, 4 brass,\n                                    5 mallet, 6 bell, 7 membrane */
#define SPM_PARAM_BRIGHTNESS 1     /* 0..1 excitation / loop-filter brightness */
#define SPM_PARAM_DAMPING 2        /* 0..1 higher = longer decay */
#define SPM_PARAM_POSITION 3       /* 0.05..0.95 string contact position */
#define SPM_PARAM_BODY_MIX 4       /* 0..1 modal body resonances */
#define SPM_PARAM_RELEASE 5        /* 0.01..4 seconds */
#define SPM_PARAM_GAIN 6           /* 0..1 */
/* Appended controls preserve the original seven parameter IDs. */
#define SPM_PARAM_PICK_HARDNESS 7  /* 0..1 soft finger to hard pick / mallet */
#define SPM_PARAM_STIFFNESS 8      /* 0..1 inharmonic bridge dispersion */
#define SPM_PARAM_BODY_SIZE 9      /* 0..1 smaller to larger resonant body */
#define SPM_PARAM_BOW_PRESSURE 10  /* 0..1 bow/string contact force */
#define SPM_PARAM_BOW_SPEED 11     /* 0..1 bow velocity */
#define SPM_PARAM_BOW_NOISE 12     /* 0..1 bow hair texture */
#define SPM_PARAM_BREATH 13       /* 0..1 breath pressure */
#define SPM_PARAM_REED_STIFFNESS 14 /* 0..1 reed/lip response */
#define SPM_PARAM_AIR_NOISE 15    /* 0..1 breath turbulence */
#define SPM_PARAM_BORE 16         /* 0..1 bore shape / spectral tilt */
/* Tuned modal percussion: strike excites six decaying resonances. */
#define SPM_PARAM_PERC_HARDNESS 17      /* 0..1 soft to hard mallet/striker */
#define SPM_PARAM_PERC_DECAY 18         /* 0..1 short to long ringing */
#define SPM_PARAM_PERC_INHARMONICITY 19 /* 0..1 harmonic to material modes */
#define SPM_PARAM_PERC_ATTACK_NOISE 20  /* 0..1 strike transient noise */
#define SPM_PARAMETER_COUNT 21

SPMSynth* spm_create(double sampleRate, int32_t polyphony);
void spm_destroy(SPMSynth* synth);
int32_t spm_set_parameter(SPMSynth* synth, int32_t parameter, float value);
float spm_get_parameter(const SPMSynth* synth, int32_t parameter);
/* MIDI: note on/off, CC1 (expression), CC2 (breath), CC11 (volume expression),
 * CC64, CC120/123 and +/-2-semitone pitch bend.
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
