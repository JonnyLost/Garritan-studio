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

// Independent left/right metering with atomic peak exchange; UI can poll
// without taking a lock on the audio callback.
typedef struct DAWAudioStereoMeter DAWAudioStereoMeter;
DAWAudioStereoMeter *daw_audio_stereo_meter_create(void);
void daw_audio_stereo_meter_destroy(DAWAudioStereoMeter *meter);
void daw_audio_stereo_meter_measure(DAWAudioStereoMeter *meter,
                                    const float *firstChannel,
                                    const float *secondChannel,
                                    uint32_t inputChannels,
                                    uint32_t frames,
                                    bool interleaved);
void daw_audio_stereo_meter_take(DAWAudioStereoMeter *meter,
                                 float *leftPeak, float *rightPeak);

// Atomic transport position handoff from render callback to UI timer.
typedef struct DAWAtomicSamplePosition DAWAtomicSamplePosition;
DAWAtomicSamplePosition *daw_sample_position_create(void);
void daw_sample_position_destroy(DAWAtomicSamplePosition *position);
void daw_sample_position_publish(DAWAtomicSamplePosition *position, int64_t frames);
int64_t daw_sample_position_load(const DAWAtomicSamplePosition *position);


// Fixed-page, nonblocking stereo PCM handoff for Core Audio disk playback.
// The disk worker writes pages after decoding, the audio callback reads only
// published pages. No callback memory allocation, waiting or file access.
// Each page index is a clip-relative frame offset / pageFrames.
typedef struct DAWPCMPageCache DAWPCMPageCache;
DAWPCMPageCache *daw_pcm_page_cache_create(uint32_t pageFrames,
                                           uint32_t pageCount);
void daw_pcm_page_cache_destroy(DAWPCMPageCache *cache);
void daw_pcm_page_cache_request(DAWPCMPageCache *cache, uint64_t frame);
bool daw_pcm_page_cache_requested_page(const DAWPCMPageCache *cache,
                                       uint64_t *pageIndex);
bool daw_pcm_page_cache_contains(const DAWPCMPageCache *cache, uint64_t pageIndex);
bool daw_pcm_page_cache_supply(DAWPCMPageCache *cache, uint64_t pageIndex,
                               const float *interleavedStereo, uint32_t frames);
uint32_t daw_pcm_page_cache_mix(DAWPCMPageCache *cache, uint64_t clipFrame,
                                uint32_t frames, float *outLeft,
                                float *outRight, float gain);
uint64_t daw_pcm_page_cache_underrun_frames(const DAWPCMPageCache *cache);


// C11 atomic ownership cursor for a preallocated Swift SPSC ring.
// Exactly one producer calls write_index/commit_write and exactly one consumer
// calls read_index/commit_read. The producer writes the Swift slot BEFORE
// publishing, and the consumer reads it BEFORE releasing the slot.
// An empty/full query returns UINT32_MAX. Never reset while either side runs.
typedef struct DAWSPSCCursor DAWSPSCCursor;
DAWSPSCCursor *daw_spsc_cursor_create(uint32_t capacity);
void daw_spsc_cursor_destroy(DAWSPSCCursor *cursor);
uint32_t daw_spsc_write_index(const DAWSPSCCursor *cursor);
void daw_spsc_commit_write(DAWSPSCCursor *cursor);
uint32_t daw_spsc_read_index(const DAWSPSCCursor *cursor);
void daw_spsc_commit_read(DAWSPSCCursor *cursor);
uint32_t daw_spsc_count(const DAWSPSCCursor *cursor);
void daw_spsc_clear_quiescent(DAWSPSCCursor *cursor);
void daw_spsc_reset_quiescent(DAWSPSCCursor *cursor);

#ifdef __cplusplus
}
#endif
#endif
