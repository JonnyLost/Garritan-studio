#include "StudioSamplerDSP.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>

int main() {
    assert(ss_create(0, 8) == nullptr);
    assert(ss_create(44100, 65) == nullptr);
    SSSampler *sampler = ss_create(44100, 8);
    assert(sampler);
    constexpr int frames = 44100;
    std::vector<float> left(frames), right(frames);
    for (int i = 0; i < frames; ++i) {
        left[i] = std::sin(2.0 * 3.141592653589793 * 440.0 * i / 44100);
        right[i] = 0.5f * left[i];
    }
    assert(!ss_add_zone(sampler, 69, 70, 60, 1, 127, 44100, left.data(), right.data(), frames));
    assert(ss_add_zone(sampler, 69, 60, 84, 1, 127, 44100, left.data(), right.data(), frames));
    assert(ss_zone_count(sampler) == 1);
    assert(ss_note_on(sampler, 69, 127, 0));
    std::vector<float> outL(11025), outR(11025);
    ss_render(sampler, outL.data(), outR.data(), static_cast<int32_t>(outL.size()));
    int crossings = 0;
    for (size_t i = 1024; i < outL.size(); ++i) {
        assert(std::isfinite(outL[i]) && std::isfinite(outR[i]));
        assert(outL[i] <= 1.f && outL[i] >= -1.f);
        assert(std::abs(outL[i] - outR[i]*2.f) < .00002f);
        if (outL[i-1] <= 0 && outL[i] > 0) ++crossings;
    }
    double frequency = crossings * 44100.0 / (outL.size() - 1024);
    assert(std::abs(frequency - 440) < 12);
    assert(ss_note_on(sampler, 81, 100, 1)); // transpose +12 semitones
    ss_render(sampler, outL.data(), outR.data(), 1024);
    assert(ss_note_off(sampler, 69, 0));
    assert(ss_all_notes_off(sampler));
    ss_render(sampler, outL.data(), outR.data(), 1024);
    for (size_t i = 512; i < 1024; ++i) assert(outL[i] == 0);
    assert(!ss_note_on(sampler, 128, 90, 0));
    ss_destroy(sampler);
    std::printf("Studio Sampler DSP smoke test passed (%.1f Hz)\n", frequency);
    return 0;
}
