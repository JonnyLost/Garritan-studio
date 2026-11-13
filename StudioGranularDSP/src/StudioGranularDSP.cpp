#include "StudioGranularDSP.h"
#include "StudioSharedPCM.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <new>
#include <vector>

namespace {
constexpr double kTau = 6.28318530717958647692;
constexpr int kVoices = 8;
constexpr int kGrainsPerVoice = 16;
constexpr int kFactoryFrames = 32768;
constexpr uint32_t kQueueCapacity = 512;
constexpr std::array<float, SGR_PARAMETER_COUNT> kDefaults{{
    0.105f, 19.f, 0.45f, 0.f, 0.f, 0.1f, 0.08f,
    0.5f, 0.015f, 0.32f, 0.55f, 0.f, 0.85f
}};
bool valid(int id, float value) noexcept {
    if (id < 0 || id >= SGR_PARAMETER_COUNT || !std::isfinite(value)) return false;
    switch(id) {
        case SGR_PARAM_GRAIN_SIZE: return value >= 0.01f && value <= 0.5f;
        case SGR_PARAM_DENSITY: return value >= 1.f && value <= 80.f;
        case SGR_PARAM_SCAN_SPEED: return value >= -1.f && value <= 1.f;
        case SGR_PARAM_PITCH: return value >= -24.f && value <= 24.f;
        case SGR_PARAM_PITCH_JITTER: return value >= 0.f && value <= 12.f;
        case SGR_PARAM_ATTACK:
        case SGR_PARAM_RELEASE: return value >= 0.001f && value <= 12.f;
        default: return value >= 0.f && value <= 1.f;
    }
}
double wrapped(double v) noexcept { return v - std::floor(v); }
struct Event {
    uint8_t status = 0, data1 = 0, data2 = 0;
    uint32_t frameOffset = 0;
};
struct Queue {
    std::array<Event,kQueueCapacity> data{};
    std::atomic<uint32_t> read{0},write{0};
    bool push(Event e) noexcept {
        const uint32_t w=write.load(std::memory_order_relaxed);
        if(w-read.load(std::memory_order_acquire)>=kQueueCapacity) return false;
        data[w % kQueueCapacity]=e;
        write.store(w+1,std::memory_order_release);
        return true;
    }
    bool pop(Event& e) noexcept {
        const uint32_t r=read.load(std::memory_order_relaxed);
        if(r==write.load(std::memory_order_acquire))return false;
        e=data[r%kQueueCapacity];
        read.store(r+1,std::memory_order_release);
        return true;
    }
    void resetStopped() noexcept {
        read.store(write.load(std::memory_order_relaxed),
                   std::memory_order_relaxed);
    }
};
uint32_t randomStep(uint32_t& state) noexcept {
    state ^= state << 13; state ^= state >> 17; state ^= state << 5;
    return state;
}
float uniform(uint32_t& state) noexcept {
    return float(randomStep(state) & 0xffffffu) / float(0x1000000u);
}
struct Grain {
    bool active=false;
    double pos=0,step=1;
    int32_t age=0,life=1;
    float left=0.7071f,right=0.7071f;
};
struct Voice {
    bool active=false,held=false;
    uint8_t note=0,channel=0;
    uint64_t sequence=0;
    float env=0,releaseStart=0,velocity=0;
    int stage=0; // 0 idle, 1 attack, 2 sustain, 3 release
    double scan=0,clock=0;
    uint32_t random=0x849acd77u;
    std::array<Grain,kGrainsPerVoice> grains{};

    void stop() noexcept {
        active=held=false; env=releaseStart=0; stage=0; clock=0;
        for(auto& g:grains)g.active=false;
    }
    void on(uint8_t n,uint8_t v,uint8_t ch,uint64_t index) noexcept {
        stop();
        active=held=true; note=n; channel=ch; sequence=index;
        velocity=float(v)/127.f; env=0; stage=1; clock=1;
        scan=0;
        random=0x847a4bbdu ^ (uint32_t(n)<<13) ^ uint32_t(index*0x9e3779b9u);
        if(!random)random=1;
    }
    void off() noexcept {
        held=false;
        if(stage==0||stage==3)return;
        releaseStart=env; stage=3;
    }
};
}

struct SGRSynth {
    double sampleRate;
    int polyphony;
    std::vector<float> source; // allocated only while rendering is stopped
    SSSharedPCM* sharedSource=nullptr; // retained for callback lifetime
    double sourceRate=44100;
    std::array<std::atomic<float>,SGR_PARAMETER_COUNT> parameters{};
    std::array<Voice,kVoices> voices{};
    Queue midi{};
    std::array<Event,kQueueCapacity> pending{};
    uint32_t pendingCount=0;
    std::atomic<bool> panic{false};
    std::array<bool,16> sustain{};
    std::array<uint16_t,16> bend{};
    std::array<uint8_t,16> wheel{};
    uint64_t sequence=0;

    SGRSynth(double rate,int count):sampleRate(rate),polyphony(count) {
        for(size_t i=0;i<kDefaults.size();++i)
            parameters[i].store(kDefaults[i],std::memory_order_relaxed);
        bend.fill(8192);
    }
    ~SGRSynth() {sspcm_release(sharedSource);}
    void clear() noexcept {
        pendingCount=0;
        sustain.fill(false);bend.fill(8192);wheel.fill(0);
        for(auto& v:voices)v.stop();
    }
    void handle(Event e) noexcept {
        const uint8_t command=e.status&0xf0, ch=e.status&0x0f;
        if(command==0xB0) {
            if(e.data1==1){wheel[ch]=e.data2;return;}
            if(e.data1==64) {
                const bool before=sustain[ch];
                sustain[ch]=e.data2>=64;
                if(before&&!sustain[ch])for(int i=0;i<polyphony;++i)
                    if(voices[i].active&&voices[i].channel==ch&&!voices[i].held)
                        voices[i].off();
                return;
            }
            if(e.data1==120||e.data1==123) {
                sustain[ch]=false;
                for(int i=0;i<polyphony;++i) {
                    Voice& v=voices[i];
                    if(v.active && v.channel==ch) {
                        if(e.data1==120)v.stop();
                        else v.off();
                    }
                }
            }
            return;
        }
        if(command==0xE0) {
            bend[ch]=uint16_t(uint16_t(e.data1) | (uint16_t(e.data2)<<7));
            return;
        }
        if(command==0x80 || (command==0x90&&e.data2==0)) {
            Voice* oldest=nullptr;
            for(int i=0;i<polyphony;++i){
                Voice& v=voices[i];
                if(v.active&&v.held&&v.note==e.data1&&v.channel==ch &&
                   (!oldest||v.sequence<oldest->sequence))oldest=&v;
            }
            if(oldest){
                oldest->held=false;
                if(!sustain[ch])oldest->off();
            }
            return;
        }
        if(command!=0x90)return;
        Voice* choice=nullptr;
        for(int i=0;i<polyphony;++i)
            if(!voices[i].active){choice=&voices[i];break;}
        if(!choice)for(int i=0;i<polyphony;++i) {
            Voice& v=voices[i];
            if(!v.held&&(!choice||v.sequence<choice->sequence))choice=&v;
        }
        if(!choice){
            choice=&voices[0];
            for(int i=1;i<polyphony;++i)
                if(voices[i].sequence<choice->sequence)choice=&voices[i];
        }
        choice->on(e.data1,e.data2,ch,++sequence);
    }
};

extern "C" {
SGRSynth* sgr_create(double rate,int32_t polyphony) {
    if(!std::isfinite(rate)||rate<8000||rate>384000||
       polyphony<1||polyphony>kVoices)return nullptr;
    auto* synth=new(std::nothrow) SGRSynth(rate,polyphony);
    if(!synth)return nullptr;
    if(!sgr_select_factory_source_stopped(synth,0)) {
        delete synth;return nullptr;
    }
    return synth;
}
void sgr_destroy(SGRSynth* s){delete s;}
int32_t sgr_set_parameter(SGRSynth* s,int32_t id,float v){
    if(!s||!valid(id,v))return 0;
    s->parameters[size_t(id)].store(v,std::memory_order_relaxed);
    return 1;
}
float sgr_get_parameter(const SGRSynth* s,int32_t id){
    if(!s||id<0||id>=SGR_PARAMETER_COUNT)return 0;
    return s->parameters[size_t(id)].load(std::memory_order_relaxed);
}
int32_t sgr_select_factory_source_stopped(SGRSynth* s,int32_t sourceID){
    if(!s||sourceID<0||sourceID>3)return 0;
    // Generated native waveforms; zero sample-library dependencies.
    std::vector<float> samples;
    try{samples.resize(kFactoryFrames);}
    catch(...){return 0;}
    uint32_t noise=0x91f81243u;
    for(int i=0;i<kFactoryFrames;++i){
        const double t=double(i)/double(kFactoryFrames);
        const double phi=kTau*t;
        float x=0;
        switch(sourceID){
            case 0: x=float(0.62*std::sin(phi*128)+
                            0.22*std::sin(phi*256)+0.10*std::sin(phi*384));break;
            case 1: x=float(0.52*std::sin(phi*96)+0.20*std::sin(phi*192)+
                            0.14*std::sin(phi*288)+0.07*std::sin(phi*480));break;
            case 2: x=float(0.46*std::sin(phi*119)+0.23*std::sin(phi*317)+
                            0.15*std::sin(phi*571));break;
            case 3:
                x=(uniform(noise)*2.f-1.f)*0.65f;
                break;
        }
        samples[size_t(i)]=x;
    }
    s->source.swap(samples);
    sspcm_release(s->sharedSource);
    s->sharedSource=nullptr;
    s->sourceRate=s->sampleRate;
    return 1;
}
int32_t sgr_load_pcm_stopped(SGRSynth* s,const float* audio,
                              int32_t frames,double sourceRate){
    if(!s||!audio||frames<128||frames>SGR_MAX_SOURCE_FRAMES||
       !std::isfinite(sourceRate)||sourceRate<8000||sourceRate>384000)return 0;
    std::vector<float> copy;
    try {
        copy.reserve(size_t(frames));
        for(int32_t i=0;i<frames;++i){
            if(!std::isfinite(audio[i]))return 0;
            copy.push_back(std::max(-1.f,std::min(1.f,audio[i])));
        }
    } catch(...){return 0;}
    s->source.swap(copy);
    sspcm_release(s->sharedSource);
    s->sharedSource=nullptr;
    s->sourceRate=sourceRate;
    return 1;
}
int32_t sgr_load_shared_pcm_stopped(SGRSynth* s,SSSharedPCM* asset) {
    if(!s || !asset || sspcm_frames(asset)<128 ||
       sspcm_frames(asset)>SGR_MAX_SOURCE_FRAMES ||
       !sspcm_mono(asset) || !std::isfinite(sspcm_sample_rate(asset)))
        return 0;
    // Only called when callback is stopped and drained. Native refcount
    // operations do not occur in the audio thread.
    SSSharedPCM* retained=sspcm_retain(asset);
    sspcm_release(s->sharedSource);
    s->sharedSource=retained;
    std::vector<float>().swap(s->source);
    s->sourceRate=sspcm_sample_rate(asset);
    return 1;
}
int32_t sgr_source_frames(const SGRSynth* s){
    return s ? int32_t(s->sharedSource ? sspcm_frames(s->sharedSource) : s->source.size()) : 0;
}
int32_t sgr_midi_event(SGRSynth* s,uint8_t status,uint8_t d1,
                       uint8_t d2,uint32_t offset){
    if(!s||d1>127||d2>127||offset>65535)return 0;
    switch(status&0xf0){
        case 0x80:case 0x90:case 0xE0:break;
        case 0xB0:
            if(d1!=1&&d1!=64&&d1!=120&&d1!=123)return 0;
            break;
        default:return 0;
    }
    return s->midi.push({status,d1,d2,offset})?1:0;
}
int32_t sgr_all_notes_off(SGRSynth* s){
    if(!s)return 0;
    s->panic.store(true,std::memory_order_release);return 1;
}
void sgr_reset_stopped(SGRSynth* s){
    if(!s)return;
    s->midi.resetStopped();
    s->panic.store(false,std::memory_order_relaxed);
    s->clear();
}
void sgr_render(SGRSynth* s,float* left,float* right,int32_t frames){
    if(!s||!left||!right||frames<=0)return;
    std::array<float,SGR_PARAMETER_COUNT> p{};
    for(size_t i=0;i<p.size();++i)
        p[i]=s->parameters[i].load(std::memory_order_relaxed);
    Event incoming{};
    if(s->panic.exchange(false,std::memory_order_acq_rel)) {
        while(s->midi.pop(incoming)){}
        s->clear();
    } else {
        while(s->pendingCount<kQueueCapacity && s->midi.pop(incoming)){
            uint32_t pos=s->pendingCount++;
            while(pos>0&&s->pending[pos-1].frameOffset>incoming.frameOffset){
                s->pending[pos]=s->pending[pos-1];--pos;
            }
            s->pending[pos]=incoming;
        }
    }
    const size_t sourceFrames=s->sharedSource ?
        sspcm_frames(s->sharedSource) : s->source.size();
    const float* const source=s->sharedSource ?
        sspcm_mono(s->sharedSource) : s->source.data();
    if(sourceFrames<128) {
        std::fill_n(left,frames,0.f);std::fill_n(right,frames,0.f);
        return;
    }
    const double srcFrames=double(sourceFrames);
    const double sampleRatio=s->sourceRate/s->sampleRate;
    const double grainDuration=double(p[SGR_PARAM_GRAIN_SIZE])*s->sampleRate;
    const double spawnStep=double(p[SGR_PARAM_DENSITY])/s->sampleRate;
    const double scanStep=double(p[SGR_PARAM_SCAN_SPEED])/s->sampleRate;
    const float attackStep=float(1.0/(s->sampleRate*p[SGR_PARAM_ATTACK]));
    const double releaseSamples=s->sampleRate*double(p[SGR_PARAM_RELEASE]);
    std::array<double,16> pitchBend{};
    auto bendRatio=[&](int ch)->double {
        const double normalized=(double(int(s->bend[ch])-8192))/8192.0;
        return std::exp2(normalized*2.0/12.0);
    };
    for(int ch=0;ch<16;++ch)pitchBend[ch]=bendRatio(ch);
    uint32_t cursor=0;
    for(int32_t frame=0;frame<frames;++frame){
        while(cursor<s->pendingCount &&
              s->pending[cursor].frameOffset<=uint32_t(frame)){
            Event e=s->pending[cursor++];
            s->handle(e);
            if((e.status&0xf0)==0xE0)
                pitchBend[e.status&0x0f]=bendRatio(e.status&0x0f);
        }
        float sumLeft=0,sumRight=0;
        for(int vi=0;vi<s->polyphony;++vi){
            Voice& v=s->voices[vi];
            if(!v.active)continue;
            if(v.stage==1) {
                v.env+=attackStep;
                if(v.env>=1.f){v.env=1.f;v.stage=2;}
            }else if(v.stage==3){
                v.env-=float(double(v.releaseStart)/releaseSamples);
                if(v.env<=0.f){v.stop();continue;}
            }
            v.clock+=spawnStep;
            if(v.clock>=1.0) {
                v.clock-=1.0;
                Grain* next=nullptr;
                for(auto& grain:v.grains)if(!grain.active){
                    next=&grain;break;
                }
                if(next) {
                    next->active=true;
                    next->age=0;
                    next->life=int32_t(grainDuration);
                    const float randPitch=(uniform(v.random)*2.f-1.f)*
                        p[SGR_PARAM_PITCH_JITTER];
                    const double semitones=double(int(v.note)-60)+
                        p[SGR_PARAM_PITCH]+randPitch;
                    const double pitch=std::exp2(semitones/12.)*
                        sampleRatio*pitchBend[v.channel];
                    next->step=(uniform(v.random)<p[SGR_PARAM_REVERSE])
                        ? -pitch : pitch;
                    double position=p[SGR_PARAM_POSITION]+v.scan+
                        (double(s->wheel[v.channel])/127.0)*0.3;
                    position+=(double(uniform(v.random))*2.-1.)*
                        p[SGR_PARAM_POSITION_JITTER];
                    next->pos=wrapped(position)*srcFrames;
                    const float pan=(uniform(v.random)*2.f-1.f)*
                        p[SGR_PARAM_PAN_SPREAD];
                    next->left=std::sqrt(0.5f*(1-pan));
                    next->right=std::sqrt(0.5f*(1+pan));
                }
            }
            float voiceL=0,voiceR=0;
            for(auto& grain:v.grains) {
                if(!grain.active)continue;
                const double t=double(grain.age)/double(grain.life);
                // Parabolic/Hann-like windows have zero ends; avoid clicks.
                const float parabolic=float(4.*t*(1.-t));
                const float triangle=float(1.-std::abs(2.*t-1.));
                const float window=triangle+(parabolic-triangle)*
                    p[SGR_PARAM_WINDOW];
                double pos=wrapped(grain.pos/srcFrames)*srcFrames;
                const size_t a=size_t(pos);
                const size_t b=(a+1)%sourceFrames;
                const float fraction=float(pos-double(a));
                const float sample=source[a]+
                    (source[b]-source[a])*fraction;
                const float output=sample*window;
                voiceL+=output*grain.left;
                voiceR+=output*grain.right;
                grain.pos+=grain.step;
                if(++grain.age>=grain.life)grain.active=false;
            }
            // Bound gain when multiple grains overlap; no dynamic allocation.
            const float overlap=std::max(1.f,float(
                p[SGR_PARAM_DENSITY]*p[SGR_PARAM_GRAIN_SIZE])*0.75f);
            const float weight=v.env*v.velocity/std::sqrt(overlap);
            sumLeft+=voiceL*weight;
            sumRight+=voiceR*weight;
            v.scan=wrapped(v.scan+scanStep);
        }
        const float gain=p[SGR_PARAM_GAIN];
        left[frame]=std::tanh(sumLeft*gain);
        right[frame]=std::tanh(sumRight*gain);
    }
    for(uint32_t i=cursor;i<s->pendingCount;++i) {
        Event e=s->pending[i];
        e.frameOffset-=uint32_t(frames);
        s->pending[i-cursor]=e;
    }
    s->pendingCount-=cursor;
}
}
