#include "StudioSamplerDSP.h"
#include <atomic>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <thread>
#include <vector>

// A deterministic, simultaneous reader/render stress test. The simulated
// background worker occasionally stalls like an external SSD under load.
// Audio rendering must remain nonblocking and its output always finite.
int main() {
    SSSampler *sampler = ss_create(44100, 64);
    assert(sampler);

    constexpr uint32_t sourceFrames = 131072;
    constexpr uint32_t attackFrames = 8192;
    std::vector<float> sourceLeft(sourceFrames);
    std::vector<float> sourceRight(sourceFrames);
    for (uint32_t i = 0; i < sourceFrames; ++i) {
        const float v = std::sin(float(i) * 0.021f) * 0.40f;
        sourceLeft[i] = v;
        sourceRight[i] = v * -0.35f;
    }

    // Three variations on 16 pitches + release tails + a second recorded
    // articulation: 72 streamed zones, all under the native 128-zone limit.
    for (int note = 48; note < 64; ++note) {
        for (int rr = 0; rr < 3; ++rr) {
            assert(ss_add_stream_zone(sampler, uint8_t(note),
                uint8_t(note), uint8_t(note), 1, 127, 44100,
                sourceLeft.data(), sourceRight.data(),
                sourceFrames, attackFrames, 0, sourceFrames,
                21000, 65000, 256, 80, 0, 0, uint8_t(rr), 0));
        }
        if (note < 56) {
            assert(ss_add_stream_zone(sampler, uint8_t(note),
                uint8_t(note), uint8_t(note), 1, 127, 44100,
                sourceLeft.data(), sourceRight.data(),
                sourceFrames, attackFrames, 0, 24000,
                0, 0, 0, 80, 0, 0, 0, 1));
        }
        assert(ss_add_stream_zone(sampler, uint8_t(note),
            uint8_t(note), uint8_t(note), 1, 127, 44100,
            sourceLeft.data(), sourceRight.data(),
            sourceFrames, attackFrames, 0, sourceFrames,
            21000, 65000, 128, 80, 0, 1, 0, 0));
    }
    assert(ss_zone_count(sampler) == 72);
    const uint8_t keys[] = {24, 25};
    const uint8_t ids[] = {0, 1};
    assert(ss_configure_keyswitches(sampler, keys, ids, 2));

    std::atomic<bool> stopping{false};
    std::atomic<unsigned> requests{0};
    std::atomic<unsigned> delayed{0};
    std::thread worker([&] {
        while (!stopping.load(std::memory_order_acquire)) {
            SSStreamRequest req{};
            if (!ss_stream_claim(sampler, &req)) {
                std::this_thread::sleep_for(std::chrono::microseconds(50));
                continue;
            }
            const unsigned requestNumber = requests.fetch_add(
                1, std::memory_order_relaxed);
            assert(req.zone_index >= 0 && req.zone_index < 72);
            assert(req.frame_count <= SS_STREAM_PAGE_FRAMES);
            assert(uint64_t(req.start_frame) + req.frame_count <= sourceFrames);
            // Intermittent 1.5ms delay simulates an I/O stall.
            if (requestNumber % 23 == 0) {
                delayed.fetch_add(1, std::memory_order_relaxed);
                std::this_thread::sleep_for(std::chrono::microseconds(1500));
            }
            if (requestNumber % 37 == 0) {
                // Pretend the external drive returned a transient read error.
                ss_stream_abandon(sampler, &req);
                continue;
            }
            assert(ss_stream_supply(sampler, &req,
                sourceLeft.data() + req.start_frame,
                sourceRight.data() + req.start_frame, req.frame_count));
        }
        // No sampler calls may occur after the thread is joined.
    });

    std::vector<float> outL(256), outR(256);
    unsigned state = 0x62d4a873u;
    auto random = [&state] {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return state;
    };
    double totalEnergy = 0;
    for (int block = 0; block < 720; ++block) {
        // Multiple simultaneous notes, repeated notes, keyswitch changes,
        // CC expression and panic events stress render-thread voice state.
        for (int event = 0; event < 5; ++event) {
            const uint8_t pitch = uint8_t(48 + (random() % 16));
            const uint8_t channel = uint8_t(random() % 4);
            const uint8_t velocity = uint8_t(1 + (random() % 127));
            if (random() % 6 == 0)
                assert(ss_note_off(sampler, pitch, channel));
            else
                assert(ss_note_on(sampler, pitch, velocity, channel));
        }
        if (block % 29 == 0) {
            assert(ss_note_on(sampler, uint8_t((block / 29) % 2 ? 24 : 25),
                              127, 0));
        }
        if (block % 7 == 0) {
            assert(ss_control_change(sampler, 11, uint8_t(random() % 128), 0));
        }
        if (block % 61 == 0) assert(ss_all_notes_off(sampler));

        ss_render(sampler, outL.data(), outR.data(), 256);
        for (size_t i = 0; i < outL.size(); ++i) {
            assert(std::isfinite(outL[i]) && std::isfinite(outR[i]));
            assert(std::abs(outL[i]) <= 1.00001f);
            assert(std::abs(outR[i]) <= 1.00001f);
            totalEnergy += double(outL[i]) * outL[i];
        }
        if (block % 15 == 0) {
            std::this_thread::sleep_for(std::chrono::microseconds(300));
        }
    }
    stopping.store(true, std::memory_order_release);
    worker.join();
    assert(requests.load() > 0);
    assert(delayed.load() > 0);
    assert(totalEnergy > .01);
    const auto misses = ss_stream_underrun_frames(sampler);
    ss_destroy(sampler);
    std::printf("Studio Sampler 72-zone/64-voice disk stress PASS: "
                "%u pages, %u delayed, %llu missed frames\\n",
                requests.load(), delayed.load(),
                static_cast<unsigned long long>(misses));
    return 0;
}
