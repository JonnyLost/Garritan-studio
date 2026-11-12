#include "StudioWavetableDSP.h"

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>

static std::vector<float> render(SWSynth* synth, int count) {
    std::vector<float> left(size_t(count),0.f),right(size_t(count),0.f);
    sws_render(synth,left.data(),right.data(),count);
    for(int i=0;i<count;++i) {
        assert(std::isfinite(left[i]));
        assert(left[i]==right[i]);
        assert(std::abs(left[i])<=1.00001f);
    }
    return left;
}
static double delta(const std::vector<float>& a,const std::vector<float>& b) {
    assert(a.size()==b.size());
    double result=0.0;
    for(size_t i=0;i<a.size();++i) result+=std::abs(a[i]-b[i]);
    return result;
}
static int positiveCrossings(const std::vector<float>& a) {
    int n=0;
    for(size_t i=1;i<a.size();++i)
        if(a[i-1]<=0.f && a[i]>0.f)++n;
    return n;
}
int main() {
    assert(!sws_create(0,8));
    assert(!sws_create(44100,17));
    SWSynth* synth=sws_create(44100,8);
    assert(synth);
    assert(sws_get_parameter(synth,SWS_PARAM_OSC1_POSITION)==2.f);
    assert(!sws_set_parameter(synth,SWS_PARAM_OSC1_POSITION,5.1f));
    assert(!sws_set_parameter(synth,SWS_PARAM_PARTIAL_BASE,-1.f));
    assert(!sws_set_parameter(synth,SWS_PARAM_OUTPUT_GAIN,NAN));
    assert(!sws_midi_event(synth,0xf0,0,0,0));
    assert(!sws_midi_event(synth,0x90,69,127,65536));
    assert(!sws_midi_event(synth,0xb0,7,127,0));

    // Carrier-only sine A4 at 44.1 kHz.
    assert(sws_set_parameter(synth,SWS_PARAM_OSC1_POSITION,0.f));
    assert(sws_set_parameter(synth,SWS_PARAM_OSC2_LEVEL,0.f));
    assert(sws_note_on(synth,69,127));
    auto sine=render(synth,44100);
    assert(std::abs(positiveCrossings(sine)-440)<12);
    assert(*std::max_element(sine.begin(),sine.end())>0.1f);
    assert(sws_all_notes_off(synth));
    render(synth,512);

    // Six real wavetable frames, including live custom harmonic edits.
    auto a=sws_create(44100,8);
    auto b=sws_create(44100,8);
    assert(a && b);
    for(auto* instance:{a,b}) {
        assert(sws_set_parameter(instance,SWS_PARAM_OSC2_LEVEL,0.f));
        assert(sws_set_parameter(instance,SWS_PARAM_ATTACK,0.001f));
        assert(sws_note_on(instance,69,127));
    }
    assert(sws_set_parameter(a,SWS_PARAM_OSC1_POSITION,0.f));
    assert(sws_set_parameter(b,SWS_PARAM_OSC1_POSITION,4.f));
    auto plain=render(a,4096),spectral=render(b,4096);
    assert(delta(plain,spectral)>5.0);
    assert(sws_all_notes_off(a));
    assert(sws_all_notes_off(b));
    render(a,256);render(b,256);
    sws_reset_stopped(a);sws_reset_stopped(b);

    // At Custom frame 5, editing a harmonic must change the waveform,
    // not just the amplitude. No table regeneration on audio thread.
    for(auto* instance:{a,b}) {
        assert(sws_set_parameter(instance,SWS_PARAM_OSC1_POSITION,5.f));
        assert(sws_set_parameter(instance,SWS_PARAM_PARTIAL_BASE,1.f));
    }
    assert(sws_set_parameter(b,SWS_PARAM_PARTIAL_BASE+2,0.8f));
    assert(sws_note_on(a,69,110));
    assert(sws_note_on(b,69,110));
    auto customA=render(a,4096),customB=render(b,4096);
    assert(delta(customA,customB)>5.0);
    assert(sws_all_notes_off(a));
    assert(sws_all_notes_off(b));
    render(a,256);render(b,256);
    sws_reset_stopped(a);sws_reset_stopped(b);

    // The modulation wheel moves wavetable position, and an unrelated
    // channel's CC1 does not affect the voice's spectrum.
    for(auto* instance:{a,b}) {
        assert(sws_set_parameter(instance,SWS_PARAM_OSC1_POSITION,1.5f));
        assert(sws_set_parameter(instance,SWS_PARAM_MODWHEEL_POSITION,1.f));
        assert(sws_note_on(instance,69,127));
    }
    assert(sws_midi_event(b,0xb1,1,127,0));
    auto baseline=render(a,2048),unrelated=render(b,2048);
    assert(delta(baseline,unrelated)<0.001);
    assert(sws_midi_event(b,0xb0,1,127,0));
    baseline=render(a,8192);
    auto modulated=render(b,8192);
    assert(delta(baseline,modulated)>5.0);

    // Frame-offset scheduling, sustain and panic.
    assert(sws_all_notes_off(synth));
    render(synth,512);
    assert(sws_midi_event(synth,0x90,60,120,64));
    auto delayed=render(synth,128);
    for(int i=0;i<64;++i) assert(delayed[size_t(i)]==0.f);
    assert(sws_midi_event(synth,0xb0,64,127,0));
    assert(sws_note_off(synth,60));
    auto held=render(synth,2048);
    assert(*std::max_element(held.begin(),held.end())>0.01f);
    assert(sws_midi_event(synth,0xb0,64,0,0));
    render(synth,22050);
    auto finished=render(synth,1024);
    for(float x:finished)assert(std::abs(x)<0.0001f);
    assert(sws_all_notes_off(synth));
    auto silent=render(synth,512);
    for(float x:silent)assert(x==0.f);
    sws_destroy(a);sws_destroy(b);sws_destroy(synth);
    std::puts("Studio Wavetable standalone DSP checks passed");
}
