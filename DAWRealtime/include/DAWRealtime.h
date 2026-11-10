#ifndef DAW_REALTIME_H
#define DAW_REALTIME_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Single-producer / single-consumer bounded FIFO of stereo Float32 frames.
// Allocate and destroy outside audio callbacks. push() never allocates,
// waits on a lock, or performs I/O. A full buffer rejects a whole tap block
// and reports the number of lost frames; never silently export truncated WAVs.
typedef struct DAWAudioRing DAWAudioRing;
DAWAudioRing *daw_audio_ring_create(uint32_t minimumCapacityFrames);
void daw_audio_ring_destroy(DAWAudioRing *ring);
bool daw_audio_ring_push(DAWAudioRing *ring,
                         const float *firstChannel,
                         const float *secondChannel,
                         uint32_t inputChannels,
                         uint32_t frames,
                         bool interleaved);
uint32_t daw_audio_ring_pop(DAWAudioRing *ring,
                            float *interleavedStereo,
                            uint32_t maximumFrames);
void daw_audio_ring_mark_dropped(DAWAudioRing *ring, uint32_t frames);
uint64_t daw_audio_ring_dropped_frames(const DAWAudioRing *ring);
uint64_t daw_audio_ring_accepted_frames(const DAWAudioRing *ring);
float daw_audio_ring_take_peak(DAWAudioRing *ring);

// Lightweight atomic peak accumulator for input monitoring (no allocations
// or actor hops in the render callback). Read/reset on the UI timer.
typedef struct DAWAudioPeakMeter DAWAudioPeakMeter;
DAWAudioPeakMeter *daw_audio_peak_meter_create(void);
void daw_audio_peak_meter_destroy(DAWAudioPeakMeter *meter);
void daw_audio_peak_meter_measure(DAWAudioPeakMeter *meter,
                                  const float *firstChannel,
                                  const float *secondChannel,
                                  uint32_t inputChannels,
                                  uint32_t frames,
                                  bool interleaved);
float daw_audio_peak_meter_take(DAWAudioPeakMeter *meter);

#ifdef __cplusplus
}
#endif
#endif
