#include "DAWRealtime.h"
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>

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
}
