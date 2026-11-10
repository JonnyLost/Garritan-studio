#include "DAWRealtime.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct DAWAudioPeakMeter {
    _Atomic(uint32_t) peakBits;
};

struct DAWAudioRing {
    float *frames; // interleaved stereo
    uint32_t capacity; // power of two
    uint32_t mask;
    _Atomic(uint64_t) head;
    _Atomic(uint64_t) tail;
    _Atomic(uint64_t) dropped;
    _Atomic(uint64_t) accepted;
    struct DAWAudioPeakMeter meter;
};

static uint32_t nextPowerOfTwo(uint32_t requested) {
    if (requested < 2) return 2;
    if (requested > (1u << 29)) return 0;
    uint32_t n = 2;
    while (n < requested) n <<= 1;
    return n;
}

static void updatePeak(struct DAWAudioPeakMeter *meter, float value) {
    if (!meter || !isfinite(value)) return;
    value = fabsf(value);
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    uint32_t previous = atomic_load_explicit(&meter->peakBits, memory_order_relaxed);
    while (previous < bits &&
           !atomic_compare_exchange_weak_explicit(
               &meter->peakBits, &previous, bits,
               memory_order_relaxed, memory_order_relaxed)) {}
}

static float takePeak(struct DAWAudioPeakMeter *meter) {
    if (!meter) return 0.0f;
    uint32_t bits = atomic_exchange_explicit(&meter->peakBits, 0, memory_order_acq_rel);
    float peak;
    memcpy(&peak, &bits, sizeof(peak));
    return peak;
}

DAWAudioRing *daw_audio_ring_create(uint32_t requestedFrames) {
    uint32_t capacity = nextPowerOfTwo(requestedFrames);
    if (!capacity) return NULL;
    DAWAudioRing *ring = calloc(1, sizeof(*ring));
    if (!ring) return NULL;
    ring->frames = calloc((size_t)capacity * 2u, sizeof(float));
    if (!ring->frames) {
        free(ring);
        return NULL;
    }
    ring->capacity = capacity;
    ring->mask = capacity - 1u;
    return ring;
}

void daw_audio_ring_destroy(DAWAudioRing *ring) {
    if (!ring) return;
    free(ring->frames);
    free(ring);
}

static inline float sampleAt(const float *first, const float *second,
                              uint32_t channels, uint32_t frame,
                              bool interleaved, uint32_t channel) {
    if (interleaved) {
        return first[(size_t)frame * channels + (channels > 1 ? channel : 0)];
    }
    const float *source = (channel == 0 || channels == 1) ? first : second;
    return source[frame];
}

bool daw_audio_ring_push(DAWAudioRing *ring, const float *first,
                         const float *second, uint32_t channels,
                         uint32_t frames, bool interleaved) {
    if (!ring || !first || channels == 0 || (!interleaved && channels > 1 && !second))
        return false;
    if (frames == 0) return true;
    // Only one producer (the AVAudioEngine tap) may call this method.
    uint64_t head = atomic_load_explicit(&ring->head, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&ring->tail, memory_order_acquire);
    if (frames > ring->capacity - (head - tail)) {
        atomic_fetch_add_explicit(&ring->dropped, frames, memory_order_relaxed);
        return false;
    }
    for (uint32_t i = 0; i < frames; i++) {
        uint32_t index = (uint32_t)(head + i) & ring->mask;
        float left = sampleAt(first, second, channels, i, interleaved, 0);
        float right = sampleAt(first, second, channels, i, interleaved, 1);
        if (!isfinite(left)) left = 0.0f;
        if (!isfinite(right)) right = 0.0f;
        ring->frames[index * 2] = left;
        ring->frames[index * 2 + 1] = right;
        updatePeak(&ring->meter, left);
        updatePeak(&ring->meter, right);
    }
    atomic_store_explicit(&ring->head, head + frames, memory_order_release);
    atomic_fetch_add_explicit(&ring->accepted, frames, memory_order_relaxed);
    return true;
}

uint32_t daw_audio_ring_pop(DAWAudioRing *ring, float *output, uint32_t limit) {
    if (!ring || !output || limit == 0) return 0;
    // Only one consumer (the serial writer) may call this method.
    uint64_t tail = atomic_load_explicit(&ring->tail, memory_order_relaxed);
    uint64_t head = atomic_load_explicit(&ring->head, memory_order_acquire);
    uint32_t available = (uint32_t)(head - tail);
    uint32_t count = available < limit ? available : limit;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t index = (uint32_t)(tail + i) & ring->mask;
        output[i * 2] = ring->frames[index * 2];
        output[i * 2 + 1] = ring->frames[index * 2 + 1];
    }
    atomic_store_explicit(&ring->tail, tail + count, memory_order_release);
    return count;
}

void daw_audio_ring_mark_dropped(DAWAudioRing *ring, uint32_t frames) {
    if (ring) atomic_fetch_add_explicit(&ring->dropped, frames, memory_order_relaxed);
}

uint64_t daw_audio_ring_dropped_frames(const DAWAudioRing *ring) {
    return ring ? atomic_load_explicit(&ring->dropped, memory_order_acquire) : 0;
}

uint64_t daw_audio_ring_accepted_frames(const DAWAudioRing *ring) {
    return ring ? atomic_load_explicit(&ring->accepted, memory_order_acquire) : 0;
}

float daw_audio_ring_take_peak(DAWAudioRing *ring) {
    return ring ? takePeak(&ring->meter) : 0;
}

DAWAudioPeakMeter *daw_audio_peak_meter_create(void) {
    return calloc(1, sizeof(DAWAudioPeakMeter));
}

void daw_audio_peak_meter_destroy(DAWAudioPeakMeter *meter) {
    free(meter);
}

void daw_audio_peak_meter_measure(DAWAudioPeakMeter *meter,
                                  const float *first, const float *second,
                                  uint32_t channels, uint32_t frames,
                                  bool interleaved) {
    if (!meter || !first || channels == 0 || (!interleaved && channels > 1 && !second))
        return;
    for (uint32_t i = 0; i < frames; i++) {
        updatePeak(meter, sampleAt(first, second, channels, i, interleaved, 0));
        if (channels > 1)
            updatePeak(meter, sampleAt(first, second, channels, i, interleaved, 1));
    }
}

float daw_audio_peak_meter_take(DAWAudioPeakMeter *meter) {
    return takePeak(meter);
}
