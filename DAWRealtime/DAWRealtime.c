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


// MARK: - MIDI SPSC cursor
// Swift stores the actual event payload; the C11 release/acquire edges
// establish slot ownership without Swift data races on head/tail counters.
struct DAWSPSCCursor {
    uint32_t capacity;
    uint32_t mask;
    _Atomic(uint64_t) head;
    _Atomic(uint64_t) tail;
};

DAWSPSCCursor *daw_spsc_cursor_create(uint32_t requestedCapacity) {
    uint32_t capacity = nextPowerOfTwo(requestedCapacity);
    if (!capacity) return NULL;
    DAWSPSCCursor *cursor = calloc(1, sizeof(*cursor));
    if (!cursor) return NULL;
    cursor->capacity = capacity;
    cursor->mask = capacity - 1u;
    atomic_init(&cursor->head, 0);
    atomic_init(&cursor->tail, 0);
    return cursor;
}

void daw_spsc_cursor_destroy(DAWSPSCCursor *cursor) { free(cursor); }

uint32_t daw_spsc_write_index(const DAWSPSCCursor *cursor) {
    if (!cursor) return UINT32_MAX;
    uint64_t head = atomic_load_explicit(&cursor->head, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&cursor->tail, memory_order_acquire);
    // Preserve one free slot so a full queue is unambiguous.
    if (head - tail >= cursor->capacity - 1u) return UINT32_MAX;
    return (uint32_t)head & cursor->mask;
}

void daw_spsc_commit_write(DAWSPSCCursor *cursor) {
    if (!cursor) return;
    uint64_t head = atomic_load_explicit(&cursor->head, memory_order_relaxed);
    atomic_store_explicit(&cursor->head, head + 1, memory_order_release);
}

uint32_t daw_spsc_read_index(const DAWSPSCCursor *cursor) {
    if (!cursor) return UINT32_MAX;
    uint64_t tail = atomic_load_explicit(&cursor->tail, memory_order_relaxed);
    uint64_t head = atomic_load_explicit(&cursor->head, memory_order_acquire);
    if (head == tail) return UINT32_MAX;
    return (uint32_t)tail & cursor->mask;
}

void daw_spsc_commit_read(DAWSPSCCursor *cursor) {
    if (!cursor) return;
    uint64_t tail = atomic_load_explicit(&cursor->tail, memory_order_relaxed);
    atomic_store_explicit(&cursor->tail, tail + 1, memory_order_release);
}

uint32_t daw_spsc_count(const DAWSPSCCursor *cursor) {
    if (!cursor) return 0;
    uint64_t head = atomic_load_explicit(&cursor->head, memory_order_acquire);
    uint64_t tail = atomic_load_explicit(&cursor->tail, memory_order_acquire);
    uint64_t count = head >= tail ? head - tail : 0;
    return count > cursor->capacity - 1u ? cursor->capacity - 1u : (uint32_t)count;
}

void daw_spsc_clear_quiescent(DAWSPSCCursor *cursor) {
    if (!cursor) return;
    uint64_t head = atomic_load_explicit(&cursor->head, memory_order_acquire);
    atomic_store_explicit(&cursor->tail, head, memory_order_release);
}

void daw_spsc_reset_quiescent(DAWSPSCCursor *cursor) {
    if (!cursor) return;
    atomic_store_explicit(&cursor->tail, 0, memory_order_relaxed);
    atomic_store_explicit(&cursor->head, 0, memory_order_release);
}


struct DAWRenderTransport {
    _Atomic(bool) playing;
    _Atomic(int64_t) position;
};
DAWRenderTransport *daw_render_transport_create(void) {
    DAWRenderTransport *state = calloc(1, sizeof(*state));
    if (state) {
        atomic_init(&state->playing, false);
        atomic_init(&state->position, 0);
    }
    return state;
}
void daw_render_transport_destroy(DAWRenderTransport *state) { free(state); }
bool daw_render_transport_is_playing(const DAWRenderTransport *state) {
    return state ? atomic_load_explicit(&state->playing, memory_order_acquire) : false;
}
void daw_render_transport_set_playing(DAWRenderTransport *state, bool playing) {
    if (state) atomic_store_explicit(&state->playing, playing, memory_order_release);
}
int64_t daw_render_transport_position(const DAWRenderTransport *state) {
    return state ? atomic_load_explicit(&state->position, memory_order_acquire) : 0;
}
void daw_render_transport_set_position(DAWRenderTransport *state, int64_t frame) {
    if (state) atomic_store_explicit(&state->position, frame, memory_order_release);
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
    atomic_init(&ring->head, 0);
    atomic_init(&ring->tail, 0);
    atomic_init(&ring->dropped, 0);
    atomic_init(&ring->accepted, 0);
    atomic_init(&ring->meter.peakBits, 0);
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
    float blockPeak = 0.0f;
    for (uint32_t i = 0; i < frames; i++) {
        uint32_t index = (uint32_t)(head + i) & ring->mask;
        float left = sampleAt(first, second, channels, i, interleaved, 0);
        float right = sampleAt(first, second, channels, i, interleaved, 1);
        if (!isfinite(left)) left = 0.0f;
        if (!isfinite(right)) right = 0.0f;
        ring->frames[index * 2] = left;
        ring->frames[index * 2 + 1] = right;
        blockPeak = fmaxf(blockPeak, fmaxf(fabsf(left), fabsf(right)));
    }
    updatePeak(&ring->meter, blockPeak);
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
    DAWAudioPeakMeter *meter = calloc(1, sizeof(DAWAudioPeakMeter));
    if (meter) atomic_init(&meter->peakBits, 0);
    return meter;
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
    float peak = 0.0f;
    for (uint32_t i = 0; i < frames; i++) {
        float left = sampleAt(first, second, channels, i, interleaved, 0);
        if (isfinite(left)) peak = fmaxf(peak, fabsf(left));
        if (channels > 1) {
            float right = sampleAt(first, second, channels, i, interleaved, 1);
            if (isfinite(right)) peak = fmaxf(peak, fabsf(right));
        }
    }
    updatePeak(meter, peak);
}

float daw_audio_peak_meter_take(DAWAudioPeakMeter *meter) {
    return takePeak(meter);
}

struct DAWAudioStereoMeter {
    struct DAWAudioPeakMeter left;
    struct DAWAudioPeakMeter right;
};

DAWAudioStereoMeter *daw_audio_stereo_meter_create(void) {
    DAWAudioStereoMeter *meter = calloc(1, sizeof(DAWAudioStereoMeter));
    if (meter) {
        atomic_init(&meter->left.peakBits, 0);
        atomic_init(&meter->right.peakBits, 0);
    }
    return meter;
}

void daw_audio_stereo_meter_destroy(DAWAudioStereoMeter *meter) {
    free(meter);
}

void daw_audio_stereo_meter_measure(DAWAudioStereoMeter *meter,
                                    const float *first, const float *second,
                                    uint32_t channels, uint32_t frames,
                                    bool interleaved) {
    if (!meter || !first || channels == 0 || (!interleaved && channels > 1 && !second))
        return;
    float leftPeak = 0.0f, rightPeak = 0.0f;
    for (uint32_t i = 0; i < frames; i++) {
        float left = sampleAt(first, second, channels, i, interleaved, 0);
        float right = sampleAt(first, second, channels, i, interleaved, 1);
        if (isfinite(left)) leftPeak = fmaxf(leftPeak, fabsf(left));
        if (isfinite(right)) rightPeak = fmaxf(rightPeak, fabsf(right));
    }
    updatePeak(&meter->left, leftPeak);
    updatePeak(&meter->right, rightPeak);
}

void daw_audio_stereo_meter_take(DAWAudioStereoMeter *meter,
                                 float *leftPeak, float *rightPeak) {
    if (leftPeak) *leftPeak = meter ? takePeak(&meter->left) : 0;
    if (rightPeak) *rightPeak = meter ? takePeak(&meter->right) : 0;
}

struct DAWAtomicSamplePosition {
    _Atomic(int64_t) frames;
};

DAWAtomicSamplePosition *daw_sample_position_create(void) {
    DAWAtomicSamplePosition *position = calloc(1, sizeof(DAWAtomicSamplePosition));
    if (position) atomic_init(&position->frames, 0);
    return position;
}

void daw_sample_position_destroy(DAWAtomicSamplePosition *position) {
    free(position);
}

void daw_sample_position_publish(DAWAtomicSamplePosition *position, int64_t frames) {
    if (position) atomic_store_explicit(&position->frames, frames, memory_order_release);
}

int64_t daw_sample_position_load(const DAWAtomicSamplePosition *position) {
    return position ? atomic_load_explicit(&position->frames, memory_order_acquire) : 0;
}


// MARK: - Stereo PCM page handoff (disk worker -> Core Audio render)
//
// Each slot uses a one-shot CAS to claim ownership. When the decoder is
// writing a page, the callback never waits: it outputs silence for the
// missing section. When the renderer is reading, the worker never overwrites
// the page until the reader releases it. Page data and its pageIndex are
// accessed only with exclusive slot ownership.
enum { PCM_FREE = 0, PCM_WRITING = 1, PCM_READY = 2, PCM_READING = 3 };
struct DAWPCMPageSlot {
    float *stereo;
    uint64_t pageIndex;
    _Atomic(uint32_t) state;
};
struct DAWPCMPageCache {
    uint32_t pageFrames;
    uint32_t pageCount;
    struct DAWPCMPageSlot *slots;
    _Atomic(uint64_t) requestedPage; // UINT64_MAX means no demand
    _Atomic(uint64_t) underrunFrames;
};

DAWPCMPageCache *daw_pcm_page_cache_create(uint32_t pageFrames,
                                           uint32_t pageCount) {
    if (pageFrames == 0 || pageFrames > 65536 ||
        pageCount == 0 || pageCount > 16) return NULL;
    DAWPCMPageCache *cache = calloc(1, sizeof(*cache));
    if (!cache) return NULL;
    cache->slots = calloc(pageCount, sizeof(struct DAWPCMPageSlot));
    if (!cache->slots) { free(cache); return NULL; }
    cache->pageFrames = pageFrames;
    cache->pageCount = pageCount;
    atomic_init(&cache->requestedPage, UINT64_MAX);
    atomic_init(&cache->underrunFrames, 0);
    for (uint32_t i = 0; i < pageCount; i++) {
        cache->slots[i].stereo = calloc((size_t)pageFrames * 2, sizeof(float));
        if (!cache->slots[i].stereo) {
            daw_pcm_page_cache_destroy(cache);
            return NULL;
        }
        atomic_init(&cache->slots[i].state, PCM_FREE);
    }
    return cache;
}

void daw_pcm_page_cache_destroy(DAWPCMPageCache *cache) {
    if (!cache) return;
    if (cache->slots) {
        for (uint32_t i = 0; i < cache->pageCount; i++)
            free(cache->slots[i].stereo);
        free(cache->slots);
    }
    free(cache);
}

void daw_pcm_page_cache_request(DAWPCMPageCache *cache, uint64_t frame) {
    if (cache)
        atomic_store_explicit(&cache->requestedPage,
                              frame / cache->pageFrames, memory_order_release);
}

bool daw_pcm_page_cache_requested_page(const DAWPCMPageCache *cache,
                                       uint64_t *pageIndex) {
    if (!cache || !pageIndex) return false;
    uint64_t requested = atomic_load_explicit(&cache->requestedPage,
                                               memory_order_acquire);
    if (requested == UINT64_MAX) return false;
    *pageIndex = requested;
    return true;
}

bool daw_pcm_page_cache_contains(const DAWPCMPageCache *cache,
                                 uint64_t pageIndex) {
    if (!cache) return false;
    const struct DAWPCMPageSlot *slot = &cache->slots[pageIndex % cache->pageCount];
    // Only the one disk worker modifies pageIndex; while state is READY
    // the callback may temporarily transition it to READING.
    uint32_t state = atomic_load_explicit(&slot->state, memory_order_acquire);
    return (state == PCM_READY || state == PCM_READING) &&
           slot->pageIndex == pageIndex;
}

bool daw_pcm_page_cache_supply(DAWPCMPageCache *cache, uint64_t pageIndex,
                               const float *stereo, uint32_t frames) {
    if (!cache || !stereo || frames > cache->pageFrames) return false;
    struct DAWPCMPageSlot *slot = &cache->slots[pageIndex % cache->pageCount];
    uint32_t state = atomic_load_explicit(&slot->state, memory_order_acquire);
    while (state == PCM_READY || state == PCM_FREE) {
        if (atomic_compare_exchange_weak_explicit(
                &slot->state, &state, PCM_WRITING,
                memory_order_acq_rel, memory_order_acquire)) {
            const size_t samples = (size_t)frames * 2;
            memcpy(slot->stereo, stereo, samples * sizeof(float));
            memset(slot->stereo + samples, 0,
                   ((size_t)cache->pageFrames * 2 - samples) * sizeof(float));
            slot->pageIndex = pageIndex;
            atomic_store_explicit(&slot->state, PCM_READY, memory_order_release);
            return true;
        }
    }
    // When the render callback has claimed this slot it must not be touched.
    return false;
}

uint32_t daw_pcm_page_cache_mix(DAWPCMPageCache *cache, uint64_t clipFrame,
                                uint32_t frames, float *outLeft,
                                float *outRight, float gain) {
    if (!cache || !outLeft || !outRight || frames == 0) return 0;
    daw_pcm_page_cache_request(cache, clipFrame);
    uint32_t mixed = 0;
    uint32_t offset = 0;
    while (offset < frames) {
        uint64_t frame = clipFrame + offset;
        if (frame < clipFrame) break; // unsigned overflow protection
        uint64_t page = frame / cache->pageFrames;
        uint32_t pageOffset = (uint32_t)(frame % cache->pageFrames);
        uint32_t section = cache->pageFrames - pageOffset;
        if (section > frames - offset) section = frames - offset;
        struct DAWPCMPageSlot *slot = &cache->slots[page % cache->pageCount];
        uint32_t expected = PCM_READY;
        if (atomic_compare_exchange_strong_explicit(
                &slot->state, &expected, PCM_READING,
                memory_order_acq_rel, memory_order_acquire)) {
            if (slot->pageIndex == page) {
                for (uint32_t i = 0; i < section; i++) {
                    uint32_t source = (pageOffset + i) * 2;
                    outLeft[offset + i] += slot->stereo[source] * gain;
                    outRight[offset + i] += slot->stereo[source + 1] * gain;
                }
                mixed += section;
            }
            atomic_store_explicit(&slot->state, PCM_READY, memory_order_release);
        }
        offset += section;
    }
    atomic_fetch_add_explicit(&cache->underrunFrames,
                              frames - mixed, memory_order_relaxed);
    return mixed;
}

uint64_t daw_pcm_page_cache_underrun_frames(const DAWPCMPageCache *cache) {
    return cache ? atomic_load_explicit(&cache->underrunFrames,
                                        memory_order_acquire) : 0;
}


// MARK: - Atomic render route publication and deferred reclamation
// seq_cst orders reader admission before pointer observation and retirement
// checks after publication. A reader that saw the previous snapshot must
// remain counted until it has fully finished using the pointer.
struct DAWRenderRouteExchange {
    _Atomic(void *) current;
    _Atomic(uint32_t) readers;
    _Atomic(bool) rendering;
};

DAWRenderRouteExchange *daw_route_exchange_create(void *initialSnapshot) {
    if (!initialSnapshot) return NULL;
    DAWRenderRouteExchange *exchange = calloc(1, sizeof(*exchange));
    if (!exchange) return NULL;
    atomic_init(&exchange->current, initialSnapshot);
    atomic_init(&exchange->readers, 0);
    atomic_init(&exchange->rendering, false);
    return exchange;
}

void daw_route_exchange_destroy(DAWRenderRouteExchange *exchange) {
    // The caller MUST have drained every reader before destruction.
    free(exchange);
}

void *daw_route_exchange_begin_read(DAWRenderRouteExchange *exchange) {
    if (!exchange) return NULL;
    atomic_fetch_add_explicit(&exchange->readers, 1, memory_order_seq_cst);
    return atomic_load_explicit(&exchange->current, memory_order_seq_cst);
}

void daw_route_exchange_end_read(DAWRenderRouteExchange *exchange) {
    if (!exchange) return;
    atomic_fetch_sub_explicit(&exchange->readers, 1, memory_order_seq_cst);
}

void *daw_route_exchange_publish(DAWRenderRouteExchange *exchange, void *newSnapshot) {
    if (!exchange || !newSnapshot) return NULL;
    return atomic_exchange_explicit(&exchange->current, newSnapshot,
                                    memory_order_seq_cst);
}

bool daw_route_exchange_is_quiescent(const DAWRenderRouteExchange *exchange) {
    return exchange && atomic_load_explicit(&exchange->readers,
                                           memory_order_seq_cst) == 0;
}

void *daw_route_exchange_take_current_quiescent(DAWRenderRouteExchange *exchange) {
    if (!exchange || !daw_route_exchange_is_quiescent(exchange)) return NULL;
    // Only use this during final shutdown with no new reader admission.
    return atomic_exchange_explicit(&exchange->current, NULL,
                                    memory_order_seq_cst);
}


// Enforce one active DSP/MIDI render frame per graph. A contended callback
// must emit silence rather than render a non-reentrant plugin concurrently.
bool daw_route_exchange_try_enter_render(DAWRenderRouteExchange *exchange) {
    if (!exchange) return false;
    bool expected = false;
    return atomic_compare_exchange_strong_explicit(
        &exchange->rendering, &expected, true,
        memory_order_acquire, memory_order_relaxed
    );
}

void daw_route_exchange_leave_render(DAWRenderRouteExchange *exchange) {
    if (!exchange) return;
    atomic_store_explicit(&exchange->rendering, false, memory_order_release);
}

// Atomic progress is read by the control thread and advanced only by the
// admitted real-time renderer. Saturation prevents overflow after completion.
struct DAWAudioTransitionProgress {
    uint32_t totalFrames;
    _Atomic(uint32_t) completedFrames;
};

DAWAudioTransitionProgress *daw_transition_create(uint32_t totalFrames) {
    if (totalFrames == 0) return NULL;
    DAWAudioTransitionProgress *progress = malloc(sizeof(*progress));
    if (!progress) return NULL;
    progress->totalFrames = totalFrames;
    atomic_init(&progress->completedFrames, 0);
    return progress;
}

void daw_transition_destroy(DAWAudioTransitionProgress *progress) {
    free(progress);
}

uint32_t daw_transition_advance(DAWAudioTransitionProgress *progress, uint32_t frames) {
    if (!progress) return 0;
    uint32_t old = atomic_load_explicit(&progress->completedFrames, memory_order_relaxed);
    while (old < progress->totalFrames) {
        const uint32_t remaining = progress->totalFrames - old;
        const uint32_t step = frames < remaining ? frames : remaining;
        uint32_t target = old + step;
        if (atomic_compare_exchange_weak_explicit(
                &progress->completedFrames, &old, target,
                memory_order_release, memory_order_relaxed)) {
            return old;
        }
    }
    return progress->totalFrames;
}

uint32_t daw_transition_completed(const DAWAudioTransitionProgress *progress) {
    return progress ? atomic_load_explicit(&progress->completedFrames, memory_order_acquire) : 0;
}

uint32_t daw_transition_total(const DAWAudioTransitionProgress *progress) {
    return progress ? progress->totalFrames : 0;
}

void daw_transition_force_complete(DAWAudioTransitionProgress *progress) {
    if (!progress) return;
    atomic_store_explicit(&progress->completedFrames, progress->totalFrames,
                          memory_order_release);
}
