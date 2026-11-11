#include "StudioAnalogDSP.h"
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>

int main() {
    assert(sa_create(0.0, 8) == nullptr);
    assert(sa_create(44100.0, 17) == nullptr);
    SASynth *s = sa_create(44100.0, 8);
    assert(s != nullptr);
    assert(sa_set_parameter(s, SA_PARAM_OSC1_WAVE, SA_WAVE_SINE));
    assert(sa_set_parameter(s, SA_PARAM_OSC2_LEVEL, 0.f));
    assert(sa_set_parameter(s, SA_PARAM_CUTOFF_HZ, 18000.f));
    assert(!sa_set_parameter(s, SA_PARAM_MASTER_GAIN, NAN));
    assert(sa_note_on(s, 69, 110));
    std::vector<float> l(11025), r(11025);
    sa_render(s, l.data(), r.data(), static_cast<int32_t>(l.size()));
    int crossings = 0;
    for (size_t i = 1025; i < l.size(); ++i) {
        assert(std::isfinite(l[i]));
        assert(l[i] == r[i]);
        assert(std::abs(l[i]) <= 1.f);
        if (l[i-1] <= 0.f && l[i] > 0.f) ++crossings;
    }
    const double frequency = crossings * 44100.0 / (11025.0 - 1024.0);
    assert(std::abs(frequency - 440.0) < 12.0);

    const SARoute cycle[] = {
        {SA_NODE_MIXER, SA_NODE_FILTER, 0, 1.f},
        {SA_NODE_FILTER, SA_NODE_MIXER, 0, 1.f},
        {SA_NODE_FILTER, SA_NODE_VCA, 0, 1.f},
        {SA_NODE_AMP_ENV, SA_NODE_VCA, 1, 1.f},
        {SA_NODE_VCA, SA_NODE_OUTPUT, 0, 1.f}
    };
    assert(!sa_load_patch(s, cycle, sizeof(cycle)/sizeof(cycle[0])));

    assert(sa_note_off(s, 69));
    std::vector<float> tail(22050), tailR(22050);
    sa_render(s, tail.data(), tailR.data(), static_cast<int32_t>(tail.size()));
    for (size_t i = tail.size() - 1024; i < tail.size(); ++i)
        assert(std::abs(tail[i]) < 0.00001f);

    sa_destroy(s);
    std::printf("Studio Analog DSP smoke test passed (%.2f Hz)\n", frequency);
    return 0;
}
