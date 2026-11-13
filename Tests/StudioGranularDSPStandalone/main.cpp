#include "StudioGranularDSP.h"
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>

static std::vector<float> render(SGRSynth* s,int frames,
                                  float* peakRight=nullptr) {
    std::vector<float> left(size_t(frames),0),right(size_t(frames),0);
    sgr_render(s,left.data(),right.data(),frames);
    float rightPeak=0;
    for(int i=0;i<frames;++i) {
        assert(std::isfinite(left[size_t(i)]));
        assert(std::isfinite(right[size_t(i)]));
        assert(std::abs(left[size_t(i)])<=1.00001f);
        assert(std::abs(right[size_t(i)])<=1.00001f);
        rightPeak=std::max(rightPeak,std::abs(right[size_t(i)]));
    }
    if(peakRight)*peakRight=rightPeak;
    return left;
}
static float peak(const std::vector<float>& values) {
    float p=0;
    for(float v:values)p=std::max(p,std::abs(v));
    return p;
}
static float sumDiff(const std::vector<float>& a,const std::vector<float>& b){
    assert(a.size()==b.size());
    float sum=0;
    for(size_t i=0;i<a.size();++i)sum+=std::abs(a[i]-b[i]);
    return sum;
}
int main() {
    assert(!sgr_create(0,8));
    assert(!sgr_create(44100,0));
    assert(!sgr_create(44100,9));
    SGRSynth* synth=sgr_create(44100,8);
    assert(synth);
    assert(sgr_source_frames(synth)==32768);
    assert(sgr_get_parameter(synth,SGR_PARAM_DENSITY)==19.f);
    assert(!sgr_set_parameter(synth,SGR_PARAM_DENSITY,81.f));
    assert(!sgr_set_parameter(synth,SGR_PARAM_GRAIN_SIZE,0.001f));
    assert(!sgr_set_parameter(synth,SGR_PARAM_GAIN,NAN));
    assert(!sgr_set_parameter(synth,SGR_PARAMETER_COUNT,0.f));
    assert(!sgr_select_factory_source_stopped(synth,4));
    assert(!sgr_midi_event(synth,0xF0,60,127,0));
    assert(!sgr_midi_event(synth,0x90,60,127,65536));
    assert(!sgr_midi_event(synth,0xB0,74,127,0));
    assert(peak(render(synth,128))==0.f);

    // Generated source: polyphonic note starts and becomes silent after off.
    assert(sgr_set_parameter(synth,SGR_PARAM_ATTACK,0.001f));
    assert(sgr_set_parameter(synth,SGR_PARAM_RELEASE,0.1f));
    assert(sgr_midi_event(synth,0x90,60,127,0));
    auto notes=render(synth,8192);
    assert(peak(notes)>0.01f);
    assert(sgr_midi_event(synth,0x80,60,0,0));
    render(synth,22050);
    assert(peak(render(synth,1024))<0.00001f);

    // Grain shape, position and reverse must have audible effect.
    SGRSynth* a=sgr_create(44100,8);
    SGRSynth* b=sgr_create(44100,8);
    assert(a&&b);
    for(auto* s:{a,b}) {
        assert(sgr_set_parameter(s,SGR_PARAM_ATTACK,0.001f));
        assert(sgr_set_parameter(s,SGR_PARAM_POSITION_JITTER,0.f));
        assert(sgr_set_parameter(s,SGR_PARAM_PITCH_JITTER,0.f));
        assert(sgr_midi_event(s,0x90,64,110,0));
    }
    assert(sgr_set_parameter(b,SGR_PARAM_POSITION,0.9f));
    assert(sgr_set_parameter(b,SGR_PARAM_REVERSE,1.f));
    assert(sumDiff(render(a,4096),render(b,4096))>1.f);
    assert(sgr_all_notes_off(a));
    assert(peak(render(a,256))==0.f);
    assert(sgr_all_notes_off(b));
    assert(peak(render(b,256))==0.f);

    // A note scheduled within a buffer must leave earlier frames silent.
    assert(sgr_midi_event(synth,0x90,62,120,64));
    const auto delayed=render(synth,192);
    for(int i=0;i<64;++i)assert(delayed[size_t(i)]==0.f);
    assert(peak(delayed)>0.f);
    assert(sgr_all_notes_off(synth));
    assert(peak(render(synth,512))==0.f);
    sgr_reset_stopped(synth);

    // Sustain holds a released key until CC64 off on the same channel.
    assert(sgr_midi_event(synth,0xB1,64,127,0));
    assert(sgr_midi_event(synth,0x91,60,127,0));
    assert(peak(render(synth,8000))>0.01f);
    assert(sgr_midi_event(synth,0x81,60,0,0));
    assert(peak(render(synth,4096))>0.01f);
    assert(sgr_midi_event(synth,0xB1,64,0,0));
    render(synth,22050);
    assert(peak(render(synth,512))<0.00001f);

    // A source imported at rest is bounded, and invalid samples are rejected.
    std::vector<float> pcm(8192);
    for(int i=0;i<8192;++i)
        pcm[size_t(i)]=float(0.6*std::sin(6.283185307179586*double(i)*440/44100));
    assert(!sgr_load_pcm_stopped(synth,pcm.data(),127,44100));
    pcm[0]=NAN;
    assert(!sgr_load_pcm_stopped(synth,pcm.data(),8192,44100));
    pcm[0]=0.f;
    assert(sgr_load_pcm_stopped(synth,pcm.data(),8192,44100));
    assert(sgr_source_frames(synth)==8192);
    assert(sgr_midi_event(synth,0x90,60,110,0));
    assert(peak(render(synth,7000))>0.01f);
    assert(sgr_all_notes_off(synth));
    assert(peak(render(synth,512))==0.f);

    // Polyphony and extreme parameters remain finite and bounded.
    assert(sgr_set_parameter(synth,SGR_PARAM_DENSITY,80.f));
    assert(sgr_set_parameter(synth,SGR_PARAM_GRAIN_SIZE,0.5f));
    assert(sgr_set_parameter(synth,SGR_PARAM_GAIN,1.f));
    for(int n=48;n<64;++n)
        assert(sgr_midi_event(synth,0x90,uint8_t(n),127,0));
    assert(peak(render(synth,16384))<=1.f);
    assert(sgr_all_notes_off(synth));
    assert(peak(render(synth,512))==0.f);
    sgr_destroy(a);sgr_destroy(b);sgr_destroy(synth);
    std::puts("Studio Granular DSP standalone checks passed");
}
