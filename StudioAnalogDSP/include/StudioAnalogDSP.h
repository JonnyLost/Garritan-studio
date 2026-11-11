#ifndef STUDIO_ANALOG_DSP_H
#define STUDIO_ANALOG_DSP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Studio Analog: original virtual-analog DSP, no third-party synth library.
 * Every public function returns immediately and never calls macOS APIs.
 * Only sa_render() may run on the render thread.
 * sa_note_on/off/all_notes_off and sa_set_parameter are lock-free control
 * calls (single MIDI producer); do not call sa_load_patch while rendering.
 */
typedef struct SASynth SASynth;

/* Stable node IDs for the initial modular voice graph. */
#define SA_NODE_OSC1       0
#define SA_NODE_OSC2       1
#define SA_NODE_NOISE      2
#define SA_NODE_MIXER      3
#define SA_NODE_FILTER_ENV 4
#define SA_NODE_LFO        5
#define SA_NODE_FILTER     6
#define SA_NODE_AMP_ENV    7
#define SA_NODE_VCA        8
#define SA_NODE_OUTPUT     9

#define SA_WAVE_SINE       0
#define SA_WAVE_TRIANGLE   1
#define SA_WAVE_SAW        2
#define SA_WAVE_PULSE      3

/* Values are floats. Waveform parameters are integral values 0...3. */
#define SA_PARAM_OSC1_WAVE        0
#define SA_PARAM_OSC2_WAVE        1
#define SA_PARAM_OSC1_LEVEL       2
#define SA_PARAM_OSC2_LEVEL       3
#define SA_PARAM_NOISE_LEVEL      4
#define SA_PARAM_OSC2_SEMITONES   5
#define SA_PARAM_CUTOFF_HZ        6
#define SA_PARAM_RESONANCE        7
#define SA_PARAM_FILTER_ENV_DEPTH 8
#define SA_PARAM_FILTER_ATTACK    9
#define SA_PARAM_FILTER_DECAY    10
#define SA_PARAM_FILTER_SUSTAIN  11
#define SA_PARAM_FILTER_RELEASE  12
#define SA_PARAM_AMP_ATTACK      13
#define SA_PARAM_AMP_DECAY       14
#define SA_PARAM_AMP_SUSTAIN     15
#define SA_PARAM_AMP_RELEASE     16
#define SA_PARAM_LFO_RATE        17
#define SA_PARAM_LFO_DEPTH       18
#define SA_PARAM_MASTER_GAIN     19
#define SA_PARAM_PULSE_WIDTH     20
#define SA_PARAMETER_COUNT       21

/* Each connection terminates at a numbered input jack.
 * MIXER: audio inputs 0,1,2.
 * FILTER: audio input 0; control inputs 1 (envelope),2 (LFO).
 * VCA: audio input 0; control input 1 (amplitude envelope).
 * OUTPUT: audio input 0.
 * The compiler rejects incompatible port types, duplicates and cycles.
 */
typedef struct SARoute {
    uint8_t source;
    uint8_t destination;
    uint8_t destinationInput;
    float gain;
} SARoute;

SASynth *sa_create(double sampleRate, int32_t voices);
void sa_destroy(SASynth *synth);

int32_t sa_set_parameter(SASynth *synth, int32_t parameter, float value);
float sa_get_parameter(const SASynth *synth, int32_t parameter);

/* Notes and parameters are delivered at the next render block boundary.
 * MIDI commands use a bounded single-producer/single-consumer queue.
 * A return of 0 means the queue was full or the arguments were invalid.
 */
int32_t sa_note_on(SASynth *synth, uint8_t note, uint8_t velocity);
int32_t sa_note_off(SASynth *synth, uint8_t note);
int32_t sa_all_notes_off(SASynth *synth);

/* Called with already allocated, non-overlapping planar output buffers.
 * No allocations, locks, logging, or graph compilation occur in render.
 */
void sa_render(SASynth *synth, float *left, float *right, int32_t frames);

/* Prepare/reconfigure the graph OFF the audio thread, while stopped.
 * Returns 0 for invalid patch and preserves the previous patch.
 * This is intentionally NOT safe while rendering; live patch swaps require
 * a future snapshot/RCU mechanism rather than mutating render state.
 */
int32_t sa_load_patch(SASynth *synth, const SARoute *routes, size_t count);

#ifdef __cplusplus
}
#endif
#endif
