#include "StudioFMDSP.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>

static void render(SFMSynth* synth, std::vector<float>& samples) {
    std::vector<float> right(samples.size());
    sfm_render(synth,samples.data(),right.data(),static_cast<int32_t>(samples.size()));
    for (size_t i=0;i<samples.size();++i) {
        assert(std::isfinite(samples[i]));
        assert(samples[i]==right[i]);
        assert(std::abs(samples[i]) <= 1.00001f);
    }
}
static int crossings(const std::vector<float>& samples) {
    int n=0;
    for (size_t i=1;i<samples.size();++i)
        if (samples[i-1] <= 0.f && samples[i] > 0.f) ++n;
    return n;
}
int main() {
    assert(!sfm_create(0,8));
    assert(!sfm_create(44100,17));
    SFMSynth* synth=sfm_create(44100,8);
    assert(synth);
    assert(sfm_get_parameter(synth,SFM_PARAM_ALGORITHM)==0.f);
    assert(!sfm_set_parameter(synth,SFM_PARAM_ALGORITHM,1.25f));
    assert(!sfm_set_parameter(synth,SFM_OP1_BASE+SFM_OP_RATIO,0.f));
    assert(!sfm_set_parameter(synth,SFM_PARAM_OUTPUT_GAIN,NAN));
    assert(!sfm_midi_event(synth,0xF0,0,0,0));
    assert(!sfm_midi_event(synth,0x90,69,110,65536));
    // Carrier-only is A4, proving correct tuning independent of FM routing.
    for (int base : {SFM_OP2_BASE,SFM_OP3_BASE,SFM_OP4_BASE})
        assert(sfm_set_parameter(synth,base+SFM_OP_LEVEL,0.f));
    assert(sfm_set_parameter(synth,SFM_OP1_BASE+SFM_OP_LEVEL,0.9f));
    assert(sfm_note_on(synth,69,127));
    std::vector<float> audio(44100);
    render(synth,audio);
    assert(std::abs(crossings(audio)-440) < 12);
    assert(*std::max_element(audio.begin(),audio.end()) > 0.05f);

    // Sustain holds note after key-up and releases after pedal release.
    assert(sfm_midi_event(synth,0xB0,64,127,0));
    assert(sfm_note_off(synth,69));
    std::vector<float> sustain(8192);
    render(synth,sustain);
    assert(*std::max_element(sustain.begin(),sustain.end()) > 0.01f);
    assert(sfm_midi_event(synth,0xB0,64,0,0));
    std::vector<float> tail(22050);
    render(synth,tail);
    for (size_t i=tail.size()-512;i<tail.size();++i)
        assert(std::abs(tail[i]) < 0.0001f);

    // Notes can be scheduled at a particular sample, crossing buffers.
    assert(sfm_midi_event(synth,0x90,69,127,300));
    std::vector<float> blockA(128),blockB(256);
    render(synth,blockA);
    for(float x:blockA) assert(x==0.f);
    render(synth,blockB);
    for(int i=0;i<172;++i) assert(blockB[i]==0.f);
    float signal=0.f;
    for(int i=172;i<256;++i) signal=std::max(signal,std::abs(blockB[i]));
    assert(signal > 0.001f);

    // FM algorithms genuinely modify the waveform, not just UI metadata.
    assert(sfm_all_notes_off(synth));
    render(synth,blockA);
    assert(sfm_set_parameter(synth,SFM_OP2_BASE+SFM_OP_LEVEL,0.85f));
    assert(sfm_set_parameter(synth,SFM_OP3_BASE+SFM_OP_LEVEL,0.45f));
    assert(sfm_set_parameter(synth,SFM_OP4_BASE+SFM_OP_LEVEL,0.35f));
    assert(sfm_set_parameter(synth,SFM_PARAM_ALGORITHM,0.f));
    assert(sfm_note_on(synth,69,100));
    std::vector<float> serial(1024);
    render(synth,serial);
    assert(sfm_all_notes_off(synth));
    render(synth,blockA);
    assert(sfm_set_parameter(synth,SFM_PARAM_ALGORITHM,3.f));
    assert(sfm_note_on(synth,69,100));
    std::vector<float> parallel(1024);
    render(synth,parallel);
    float difference=0.f;
    for(size_t i=0;i<serial.size();++i) difference+=std::abs(serial[i]-parallel[i]);
    assert(difference > 15.f);

    // Changes are continuously ramped rather than jumping at a buffer edge.
    assert(sfm_set_parameter(synth, SFM_PARAM_OUTPUT_GAIN, 0.f));
    std::vector<float> faded(2205);
    render(synth, faded);
    for(size_t i=faded.size()-256; i<faded.size(); ++i)
        assert(std::abs(faded[i]) < 0.002f);
    assert(sfm_set_parameter(synth, SFM_PARAM_OUTPUT_GAIN, 0.8f));
    render(synth, faded);

    // All four new expression parameters preserve old numeric IDs.
    assert(sfm_set_parameter(synth,SFM_PARAM_VELOCITY_BRIGHTNESS,1.f));
    assert(sfm_set_parameter(synth,SFM_PARAM_MOD_TARGET,1.f));
    assert(sfm_set_parameter(synth,SFM_PARAM_MOD_DEPTH,0.8f));
    assert(sfm_set_parameter(synth,SFM_PARAM_MOD_RATE,6.f));
    assert(!sfm_set_parameter(synth,SFM_PARAM_MOD_TARGET,0.5f));
    assert(!sfm_set_parameter(synth,SFM_PARAM_MOD_RATE,20.1f));
    assert(sfm_get_parameter(synth,SFM_PARAM_MOD_DEPTH)==0.8f);
    assert(sfm_midi_event(synth,0xB0,1,127,0));
    render(synth, faded);
    assert(sfm_midi_event(synth,0xB0,1,0,0));
    render(synth, faded);
    assert(sfm_all_notes_off(synth));
    render(synth,blockA);
    for(float x:blockA) assert(x==0.f);
    sfm_destroy(synth);
    std::printf("Studio FM original DSP smoke test passed\n");
}
