#include "StudioPhysicalDSP.h"
#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

// Linux/CI smoke and ASan/UBSan exercise for all 8 native models.
// Full DAW/AVAudioEngine integration remains covered by macOS XCTest.
int main() {
    constexpr std::array<double, 6> rates{
        8000.0, 44100.0, 48000.0, 96000.0, 192000.0, 384000.0
    };
    for (double rate : rates) {
        for (int model = 0; model <= 7; ++model) {
            SPMSynth* synth = spm_create(rate, 8);
            assert(synth);
            assert(spm_set_parameter(synth, SPM_PARAM_MODEL, float(model)));
            assert(spm_get_parameter(synth, SPM_PARAM_MODEL) == float(model));
            assert(spm_set_parameter(synth, SPM_PARAM_PERC_DECAY, 0.7f));
            assert(spm_midi_event(synth, 0x92, 57, 120, 31));
            std::array<float, 256> left{}, right{};
            bool audible = false;
            for (int buffer = 0; buffer < 24; ++buffer) {
                spm_render(synth, left.data(), right.data(), 256);
                for (size_t i = 0; i < left.size(); ++i) {
                    assert(std::isfinite(left[i]) && std::isfinite(right[i]));
                    assert(std::abs(left[i]) <= 1.001f);
                    assert(left[i] == right[i]);
                    audible |= std::abs(left[i]) > 0.000001f;
                }
            }
            assert(audible);
            assert(spm_midi_event(synth, 0xE2, 127, 127, 0));
            assert(spm_midi_event(synth, 0xB2, 11, 0, 0));
            spm_render(synth, left.data(), right.data(), 256);
            for (float sample : left) assert(sample == 0.f);
            assert(spm_all_notes_off(synth));
            spm_render(synth, left.data(), right.data(), 256);
            for (float sample : left) assert(sample == 0.f);
            spm_destroy(synth);
        }
    }
    puts("StudioPhysicalDSP all 8 models / 6 rates passed");
    return 0;
}
