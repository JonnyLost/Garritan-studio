#ifndef STUDIO_WAVETABLE_DSP_H
#define STUDIO_WAVETABLE_DSP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Original Studio Synth wavetable engine, not an external sample library.
 * Five mathematically generated bandlimited frames and one user-defined
 * 16-partial waveform. Morph continuously across frames 0...5.
 * Instance lifetime and MIDI producer rules match Studio FM.
 */
typedef struct SWSynth SWSynth;
#define SWS_FRAME_COUNT 6
#define SWS_CUSTOM_PARTIALS 16
#define SWS_PARAM_OSC1_POSITION 0
#define SWS_PARAM_OSC2_POSITION 1
#define SWS_PARAM_OSC1_LEVEL 2
#define SWS_PARAM_OSC2_LEVEL 3
#define SWS_PARAM_OSC2_DETUNE 4
#define SWS_PARAM_ATTACK 5
#define SWS_PARAM_DECAY 6
#define SWS_PARAM_SUSTAIN 7
#define SWS_PARAM_RELEASE 8
#define SWS_PARAM_OUTPUT_GAIN 9
#define SWS_PARAM_BEND_RANGE 10
#define SWS_PARAM_LFO_RATE 11
#define SWS_PARAM_LFO_DEPTH 12
#define SWS_PARAM_VELOCITY_POSITION 13
#define SWS_PARAM_MODWHEEL_POSITION 14
#define SWS_PARAM_PARTIAL_BASE 15
#define SWS_PARAMETER_COUNT 31

SWSynth* sws_create(double sampleRate, int32_t voices);
void sws_destroy(SWSynth* synth);
int32_t sws_set_parameter(SWSynth* synth, int32_t id, float value);
float sws_get_parameter(const SWSynth* synth, int32_t id);

/* SPSC MIDI queue. Status: note on/off, CC1, CC64, CC120/123, pitch bend.
 * Events are sorted and scheduled within a render callback by frameOffset.
 * All-note panic is atomic. No operation on this interface may be called
 * on a destroyed synth or concurrently by multiple MIDI producers.
 */
int32_t sws_midi_event(SWSynth* synth, uint8_t status,
                       uint8_t data1, uint8_t data2, uint32_t frameOffset);
int32_t sws_note_on(SWSynth* synth, uint8_t note, uint8_t velocity);
int32_t sws_note_off(SWSynth* synth, uint8_t note);
int32_t sws_all_notes_off(SWSynth* synth);
void sws_reset_stopped(SWSynth* synth);

/* Planar stereo Float32. No allocation, locks, file I/O, or OS calls.
 * The shared factory table bank is fully initialized in sws_create.
 */
void sws_render(SWSynth* synth, float* left, float* right, int32_t frames);

#ifdef __cplusplus
}
#endif
#endif
