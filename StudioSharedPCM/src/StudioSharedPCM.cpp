#include "StudioSharedPCM.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <new>
#include <vector>

struct SSSharedPCM {
    std::atomic<uint32_t> refs{1};
    std::vector<float> left, right, mono;
    double rate=44100.0;
    bool stereo=false;
};

extern "C" {
SSSharedPCM* sspcm_create_copy(const float* left, const float* right,
                               uint32_t frames, double sampleRate) {
    if (!left || frames<2 || frames>2000000 ||
        !std::isfinite(sampleRate) || sampleRate<8000 || sampleRate>384000)
        return nullptr;
    try {
        auto* pcm=new SSSharedPCM;
        try {
            pcm->rate=sampleRate;
            pcm->stereo=right!=nullptr;
            pcm->left.assign(left,left+frames);
            if (right) pcm->right.assign(right,right+frames);
            pcm->mono.reserve(frames);
            for(uint32_t i=0;i<frames;++i) {
                const float l=pcm->left[i];
                const float r=right ? pcm->right[i] : l;
                if (!std::isfinite(l) || !std::isfinite(r)) {
                    delete pcm; return nullptr;
                }
                const float average=0.5f*l+0.5f*r;
                pcm->mono.push_back(std::max(-1.f,std::min(1.f,average)));
            }
        } catch (...) { delete pcm; return nullptr; }
        return pcm;
    } catch (...) { return nullptr; }
}
SSSharedPCM* sspcm_retain(SSSharedPCM* pcm) {
    if(pcm) pcm->refs.fetch_add(1,std::memory_order_relaxed);
    return pcm;
}
void sspcm_release(SSSharedPCM* pcm) {
    if(pcm && pcm->refs.fetch_sub(1,std::memory_order_acq_rel)==1) delete pcm;
}
uint32_t sspcm_frames(const SSSharedPCM* pcm) {
    return pcm ? uint32_t(pcm->left.size()) : 0;
}
double sspcm_sample_rate(const SSSharedPCM* pcm) {return pcm ? pcm->rate : 0.0;}
const float* sspcm_left(const SSSharedPCM* pcm) {
    return pcm ? pcm->left.data() : nullptr;
}
const float* sspcm_right(const SSSharedPCM* pcm) {
    return pcm ? (pcm->stereo ? pcm->right.data() : pcm->left.data()) : nullptr;
}
const float* sspcm_mono(const SSSharedPCM* pcm) {
    return pcm ? pcm->mono.data() : nullptr;
}
uint64_t sspcm_resident_bytes(const SSSharedPCM* pcm) {
    if(!pcm) return 0;
    return uint64_t(pcm->left.size()+pcm->right.size()+pcm->mono.size())*
           sizeof(float);
}
}
