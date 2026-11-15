#include "DAWRealtime.h"
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdatomic.h>
#include <time.h>

static DAWSPSCCursor *cursor;
static uint64_t slots[256];
static const uint64_t eventCount = 1000000;
static void *produce(void *unused) {
    (void)unused;
    for (uint64_t i = 0; i < eventCount; ++i) {
        uint32_t slot;
        while ((slot = daw_spsc_write_index(cursor)) == UINT32_MAX) {}
        slots[slot] = i;
        daw_spsc_commit_write(cursor);
    }
    return NULL;
}
static DAWMIDIClock *clockState;
static _Atomic(bool) clockDone;
static void *renderClock(void *unused) {
    (void)unused;
    int64_t frame = 0;
    while (!atomic_load_explicit(&clockDone, memory_order_acquire)) {
        daw_midi_clock_observe(clockState, frame, 128);
        frame += 128;
    }
    return NULL;
}
static void testClock(void) {
    clockState = daw_midi_clock_create();
    assert(clockState);
    uint64_t g;
    int64_t frame;
    assert(!daw_midi_clock_snapshot(clockState, &g, &frame));
    uint64_t first = daw_midi_clock_begin(clockState, 24000);
    assert(daw_midi_clock_observe(clockState, 900000, 128));
    assert(daw_midi_clock_snapshot(clockState, &g, &frame));
    assert(g == first && frame == 24128);
    daw_midi_clock_cancel(clockState);
    assert(!daw_midi_clock_snapshot(clockState, &g, &frame));
    assert(!daw_midi_clock_observe(clockState, 900128, 128));
    uint64_t second = daw_midi_clock_begin(clockState, 96000);
    assert(!daw_midi_clock_is_current(clockState, first));
    assert(daw_midi_clock_snapshot(clockState, &g, &frame));
    assert(g == second && frame == 96000);
    assert(daw_midi_clock_observe(clockState, 1024, 64));
    assert(!daw_midi_clock_observe(clockState, 0, 64));
    assert(daw_midi_clock_snapshot(clockState, &g, &frame) && frame == 96064);

    atomic_init(&clockDone, false);
    pthread_t render;
    assert(pthread_create(&render, NULL, renderClock, NULL) == 0);
    for (int64_t i = 0; i < 10000; ++i) {
        daw_midi_clock_cancel(clockState);
        daw_midi_clock_begin(clockState, i * 128);
        if (daw_midi_clock_snapshot(clockState, &g, &frame)) {
            assert(!(g & 1u) && frame >= 0);
        }
    }
    atomic_store_explicit(&clockDone, true, memory_order_release);
    assert(pthread_join(render, NULL) == 0);
    daw_midi_clock_begin(clockState, 0);
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (int64_t i = 0; i < 1000000; ++i) {
        assert(daw_midi_clock_observe(clockState, i * 128, 128));
    }
    clock_gettime(CLOCK_MONOTONIC, &end);
    assert(daw_midi_clock_snapshot(clockState, &g, &frame) && frame == 128000000);
    double elapsed = (double)(end.tv_sec - start.tv_sec) + (double)(end.tv_nsec - start.tv_nsec) / 1e9;
    printf("PASS: 10000 concurrent clock generations; one million coalesced observations in %.6f s (instrumented host, not audio latency)\n", elapsed);
    daw_midi_clock_destroy(clockState);
}
int main(void) {
    cursor = daw_spsc_cursor_create(256);
    assert(cursor);
    assert(daw_spsc_read_index(cursor) == UINT32_MAX);
    for (unsigned i = 0; i < 255; ++i) {
        assert(daw_spsc_write_index(cursor) != UINT32_MAX);
        daw_spsc_commit_write(cursor);
    }
    assert(daw_spsc_write_index(cursor) == UINT32_MAX);
    daw_spsc_clear_quiescent(cursor);
    assert(daw_spsc_count(cursor) == 0);
    daw_spsc_reset_quiescent(cursor);
    pthread_t producer;
    assert(pthread_create(&producer, NULL, produce, NULL) == 0);
    for (uint64_t i = 0; i < eventCount; ++i) {
        uint32_t slot;
        while ((slot = daw_spsc_read_index(cursor)) == UINT32_MAX) {}
        assert(slots[slot] == i);
        daw_spsc_commit_read(cursor);
    }
    assert(pthread_join(producer, NULL) == 0);
    assert(daw_spsc_count(cursor) == 0);
    daw_spsc_cursor_destroy(cursor);
    puts("PASS: one million ordered SPSC events; capacity, clear, reset, wraparound");
    testClock();
}
