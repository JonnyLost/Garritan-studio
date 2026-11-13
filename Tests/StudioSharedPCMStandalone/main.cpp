#include "StudioSharedPCM.h"
#include "StudioSamplerDSP.h"
#include "StudioGranularDSP.h"
#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>

int main() {
    constexpr int kFrames=4096;
    std::array<float,kFrames> left{}, right{};
    for(int i=0;i<kFrames;++i){
        left[size_t(i)]=0.45f*std::sin(double(i)*0.1);
        right[size_t(i)]=0.2f*std::sin(double(i)*0.1);
    }
    SSSharedPCM* source=sspcm_create_copy(
        left.data(),right.data(),kFrames,44100.0);
    assert(source);
    assert(sspcm_frames(source)==kFrames);
    assert(sspcm_sample_rate(source)==44100.0);
    assert(sspcm_resident_bytes(source)==uint64_t(kFrames)*3*4);
    assert(std::abs(sspcm_mono(source)[1]-
                    0.5f*(left[1]+right[1]))<0.00001f);
    assert(!sspcm_create_copy(nullptr,nullptr,kFrames,44100));
    left[17]=NAN;
    assert(!sspcm_create_copy(left.data(),nullptr,kFrames,44100));
    left[17]=0.45f*std::sin(1.7);

    SSSampler* samplerA=ss_create(44100,8);
    SSSampler* samplerB=ss_create(44100,8);
    SGRSynth* grain=sgr_create(44100,8);
    assert(samplerA&&samplerB&&grain);
    for(auto* sampler: {samplerA,samplerB}){
        assert(ss_add_shared_zone_with_variation(
            sampler,60,0,127,1,127,source,
            0,kFrames,0,0,0,0,0,0,0,0));
        assert(ss_zone_count(sampler)==1);
    }
    assert(sgr_load_shared_pcm_stopped(grain,source));
    assert(sgr_source_frames(grain)==kFrames);
    // Both DSPs now own native references independent of the cache.
    sspcm_release(source);

    assert(ss_note_on(samplerA,60,110,0));
    assert(ss_note_on(samplerB,60,110,0));
    assert(sgr_midi_event(grain,0x90,60,120,0));
    std::array<float,512> a{},b{};
    bool samplerAudible=false,granularAudible=false;
    for(int round=0;round<30;++round){
        ss_render(samplerA,a.data(),b.data(),512);
        for(float v:a){
            assert(std::isfinite(v));
            samplerAudible|=std::abs(v)>1e-5f;
        }
        ss_render(samplerB,a.data(),b.data(),512);
        for(float v:a)assert(std::isfinite(v));
        sgr_render(grain,a.data(),b.data(),512);
        for(float v:a){
            assert(std::isfinite(v));
            granularAudible|=std::abs(v)>1e-5f;
        }
    }
    assert(samplerAudible&&granularAudible);
    // Release independent owners in reverse order; granular can continue
    // to render even after all Sampler instruments are destroyed.
    ss_destroy(samplerA);
    ss_destroy(samplerB);
    sgr_render(grain,a.data(),b.data(),512);
    for(float v:a)assert(std::isfinite(v));
    sgr_destroy(grain);
    puts("Shared PCM zero-copy multi-engine lifetime verified");
}
