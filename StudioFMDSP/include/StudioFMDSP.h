#ifndef STUDIO_FM_DSP_H
#define STUDIO_FM_DSP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Original four-operator phase-modulation FM engine (no third-party DSP).
 * Instance ownership: create/destroy only with render stopped.
 * One MIDI producer at a time, serialized by the host; render owns voices.
 * Set/get parameters are atomic and do not acquire locks.
 */
typedef struct SFMSynth SFMSynth;

#define SFM_OPERATOR_COUNT 4
#define SFM_PARAM_ALGORITHM 0
#define SFM_PARAM_FEEDBACK 1
#define SFM_PARAM_OUTPUT_GAIN 2
#define SFM_PARAM_BEND_RANGE 3
/* Operator parameter bases in ascending operator order (OP1 is carrier).
 * Offsets 0 ratio, 1 level, 2 attack, 3 decay, 4 sustain, 5 release.
 */
#define SFM_OP1_BASE 4
#define SFM_OP2_BASE 10
#define SFM_OP3_BASE 16
#define SFM_OP4_BASE 22
#define SFM_OP_RATIO 0
#define SFM_OP_LEVEL 1
#define SFM_OP_ATTACK 2
#define SFM_OP_DECAY 3
#define SFM_OP_SUSTAIN 4
#define SFM_OP_RELEASE 5
/* Appended IDs preserve every existing FM project and factory preset.
 * VelocityBrightness: 0..1 (modulator scaling by note velocity)
 * ModTarget: 0 vibrato / 1 harmonic brightness
 * ModDepth: 0..1, ModRate: 0.1..20 Hz
 */
#define SFM_PARAM_VELOCITY_BRIGHTNESS 28
#define SFM_PARAM_MOD_TARGET 29
#define SFM_PARAM_MOD_DEPTH 30
#define SFM_PARAM_MOD_RATE 31
#define SFM_PARAMETER_COUNT 32

/* Algorithm 0: OP4 -> OP3 -> OP2 -> OP1 (OP1 audible).
 * Algorithm 1: OP4 -> OP3 + OP2 -> OP1 (OP1 and OP3 audible).
 * Algorithm 2: (OP4 + OP3 + OP2) -> OP1 (OP1 audible).
 * Algorithm 3: OP1 + OP2 + OP3 + OP4 (all four audible).
 * Operator 4 has delayed self-feedback controlled by SFM_PARAM_FEEDBACK.
 * This is original phase-modulation FM, not an emulation of any commercial
 * synthesizer's algorithm or patch format.
 */
SFMSynth *sfm_create(double sampleRate, int32_t voices);
void sfm_destroy(SFMSynth *synth);

int32_t sfm_set_parameter(SFMSynth *synth, int32_t parameter, float value);
float sfm_get_parameter(const SFMSynth *synth, int32_t parameter);

/* Bounded single-producer MIDI queue. Note On/Off, CC1 (mod wheel), CC64 (sustain),
 * CC120/123 and 14-bit pitch wheel are supported, with MIDI channels.
 * frameOffset refers to the next sfm_render() call; offsets through
 * successive render buffers are retained, up to 65535 frames.
 * 1 = accepted, 0 = invalid data or queue full.
 */
int32_t sfm_midi_event(SFMSynth *synth, uint8_t status, uint8_t data1,
                       uint8_t data2, uint32_t frameOffset);
int32_t sfm_note_on(SFMSynth *synth, uint8_t note, uint8_t velocity);
int32_t sfm_note_off(SFMSynth *synth, uint8_t note);
int32_t sfm_all_notes_off(SFMSynth *synth);

/* Only call with render stopped; this method clears voices and all queues. */
void sfm_reset_stopped(SFMSynth *synth);

/* Operator gain/ratio, global level/feedback and modulation-depth changes
 * are smoothed within the renderer (approximately 12 ms). Envelope times and
 * discrete algorithms are updated at buffer boundaries.
 * Render writes planar Float32 stereo. It allocates no memory, acquires
 * no locks, invokes no OS APIs and performs no file I/O. */
void sfm_render(SFMSynth *synth, float *left, float *right, int32_t frames);

#ifdef __cplusplus
}
#endif
#endif
