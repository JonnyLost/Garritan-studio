#include "StudioAdditiveDSP.h"
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>

static std::vector<float> render(SADDSynth* synth,int frames) {
    std::vector<float> left(size_t(frames),0.f),right(size_t(frames),0.f);
    sadd_render(synth,left.data(),right.data(),frames);
    for(int i=0;i<frames;++i) {
        assert(std::isfinite(left[size_t(i)]));
        assert(left[size_t(i)]==right[size_t(i)]);
        assert(std::abs(left[size_t(i)])<=1.001f);
    }
    return left;
}
static float peak(const std::vector<float>& values) {
    float p=0;
    for(float x:values)p=std::max(p,std::abs(x));
    return p;
}
static int crossings(const std::vector<float>& values) {
    int count=0;
    for(size_t i=1;i<values.size();++i)
        if(values[i-1]<=0.f&&values[i]>0.f)++count;
    return count;
}
static double difference(const std::vector<float>& a,
                         const std::vector<float>& b) {
    assert(a.size()==b.size());
    double value=0;
    for(size_t i=0;i<a.size();++i)value+=std::abs(a[i]-b[i]);
    return value;
}
int main() {
    assert(!sadd_create(0,8));
    assert(!sadd_create(44100,17));
    auto* synth=sadd_create(44100,8);
    assert(synth);
    assert(sadd_get_parameter(synth,SADD_PARAM_PARTIAL_BASE)==0.8f);
    assert(!sadd_set_parameter(synth,SADD_PARAM_TILT,3));
    assert(!sadd_set_parameter(synth,SADD_PARAM_ATTACK,NAN));
    assert(!sadd_set_parameter(synth,SADD_PARAM_PARTIAL_BASE,-0.1f));
    assert(!sadd_set_parameter(synth,555,0));
    assert(!sadd_midi_event(synth,0xF0,60,100,0));
    assert(!sadd_midi_event(synth,0x90,69,100,65536));
    assert(!sadd_midi_event(synth,0xB0,74,127,0));

    // Fundamental-only A4 has 440 cycles/sec and a clean note release.
    for(int h=0;h<SADD_PARTIAL_COUNT;++h)
        assert(sadd_set_parameter(synth,SADD_PARAM_PARTIAL_BASE+h,
                                  h==0?0.95f:0.f));
    assert(sadd_set_parameter(synth,SADD_PARAM_EVOLVE,0));
    assert(sadd_set_parameter(synth,SADD_PARAM_ATTACK,0.001f));
    assert(sadd_midi_event(synth,0x90,69,127,0));
    auto tone=render(synth,44100);
    assert(std::abs(crossings(tone)-440)<10);
    assert(peak(tone)>0.2f);
    assert(sadd_midi_event(synth,0x80,69,0,0));
    render(synth,22050);
    assert(peak(render(synth,1024))<0.0001f);

    // An upper partial changes the timbre at the same fundamental pitch.
    auto* a=sadd_create(44100,8),*b=sadd_create(44100,8);
    assert(a&&b);
    for(auto* s:{a,b}) {
        assert(sadd_set_parameter(s,SADD_PARAM_ATTACK,0.001f));
        assert(sadd_set_parameter(s,SADD_PARAM_EVOLVE,0));
        for(int h=0;h<SADD_PARTIAL_COUNT;++h)
            assert(sadd_set_parameter(s,SADD_PARAM_PARTIAL_BASE+h,
                                      h==0?0.8f:0.f));
        assert(sadd_midi_event(s,0x90,69,127,0));
    }
    assert(sadd_set_parameter(b,SADD_PARAM_PARTIAL_BASE+4,0.65f));
    const auto pure=render(a,8192),rich=render(b,8192);
    assert(difference(pure,rich)>10);
    assert(sadd_all_notes_off(a));
    assert(sadd_all_notes_off(b));
    assert(peak(render(a,256))==0.f);
    assert(peak(render(b,256))==0.f);

    // Time-varying spectrum changes tone across a held note; pitch remains.
    assert(sadd_set_parameter(synth,SADD_PARAM_PARTIAL_BASE+4,0.7f));
    assert(sadd_set_parameter(synth,SADD_PARAM_EVOLVE,1.4f));
    assert(sadd_set_parameter(synth,SADD_PARAM_EVOLVE_TIME,0.2f));
    assert(sadd_midi_event(synth,0x90,60,110,0));
    const auto early=render(synth,2048);
    const auto late=render(synth,2048);
    assert(difference(early,late)>2);
    assert(sadd_all_notes_off(synth));
    assert(peak(render(synth,256))==0.f);

    // MIDI sample offsets, channel-isolated Note Off, sustain, panic.
    assert(sadd_midi_event(synth,0x91,60,120,64));
    const auto delayed=render(synth,128);
    for(int i=0;i<64;++i)assert(delayed[size_t(i)]==0.f);
    assert(peak(delayed)>0.f);
    assert(sadd_midi_event(synth,0xB1,64,127,0));
    assert(sadd_midi_event(synth,0x80,60,0,0)); // wrong channel
    assert(sadd_midi_event(synth,0x81,60,0,0)); // sustained
    assert(peak(render(synth,2048))>0.01f);
    assert(sadd_midi_event(synth,0xB1,64,0,0));
    render(synth,22050);
    assert(peak(render(synth,1024))<0.0001f);
    assert(sadd_midi_event(synth,0x90,62,127,0));
    assert(peak(render(synth,512))>0.f);
    assert(sadd_all_notes_off(synth));
    assert(peak(render(synth,512))==0.f);
    sadd_reset_stopped(synth);
    assert(peak(render(synth,128))==0.f);

    // Multiple simultaneous notes are bounded and never exceed output range.
    for(int n=48;n<64;++n)
        assert(sadd_midi_event(synth,0x90,uint8_t(n),120,0));
    assert(peak(render(synth,8192))<=1.f);
    assert(sadd_all_notes_off(synth));
    assert(peak(render(synth,512))==0.f);

    sadd_destroy(a);sadd_destroy(b);sadd_destroy(synth);
    std::puts("Studio Additive DSP standalone checks passed");
}
