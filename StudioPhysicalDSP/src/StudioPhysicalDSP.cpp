#include "StudioPhysicalDSP.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <new>

namespace {
constexpr int kMaxVoices = 8;
constexpr int kDelayCapacity = 16384; // Supports A0 at 384 kHz with margin.
constexpr uint32_t kQueueCapacity = 512;
constexpr double kTau = 6.28318530717958647692;
constexpr std::array<float, SPM_PARAMETER_COUNT> kDefaults{{
    0.f, 0.55f, 0.7f, 0.25f, 0.25f, 0.2f, 0.5f
}};

bool valid(int id, float value) noexcept {
    if (id < 0 || id >= SPM_PARAMETER_COUNT || !std::isfinite(value)) return false;
    switch (id) {
        case SPM_PARAM_MODEL: return value == 0.f || value == 1.f;
        case SPM_PARAM_POSITION: return value >= 0.05f && value <= 0.95f;
        case SPM_PARAM_RELEASE: return value >= 0.01f && value <= 4.f;
        default: return value >= 0.f && value <= 1.f;
    }
}
struct Event {
    uint8_t status=0, data1=0, data2=0;
    uint32_t offset=0;
};
struct Queue {
    std::array<Event,kQueueCapacity> events{};
    std::atomic<uint32_t> read{0}, write{0};
    bool push(Event event) noexcept {
        const uint32_t w = write.load(std::memory_order_relaxed);
        if (w - read.load(std::memory_order_acquire) >= kQueueCapacity) return false;
        events[w % kQueueCapacity] = event;
        write.store(w+1, std::memory_order_release);
        return true;
    }
    bool pop(Event& event) noexcept {
        const uint32_t r = read.load(std::memory_order_relaxed);
        if (r == write.load(std::memory_order_acquire)) return false;
        event = events[r % kQueueCapacity];
        read.store(r+1, std::memory_order_release);
        return true;
    }
    void clearStopped() noexcept {
        read.store(write.load(std::memory_order_relaxed),std::memory_order_relaxed);
    }
};
uint32_t randomStep(uint32_t& state) noexcept {
    state ^= state << 13; state ^= state >> 17; state ^= state << 5;
    return state;
}
float randomBipolar(uint32_t& state) noexcept {
    return float(randomStep(state) & 0xFFFFFFu) / 8388608.f - 1.f;
}

/* Stable two-pole resonator. Coefficients are computed at note start, never
 * at audio sample rate; its feedback radius is strictly below one. */
struct Mode {
    float a=0,b=0,y1=0,y2=0,drive=0;
    void configure(double rate, double hertz, double tail) noexcept {
        const double r = std::exp(-1.0/(rate*tail));
        a = float(2.0*r*std::cos(kTau*hertz/rate));
        b = float(r*r);
        drive = float(1.0-r);
        y1=y2=0;
    }
    float process(float input) noexcept {
        const float y=a*y1-b*y2+drive*input;
        y2=y1; y1=y;
        return y;
    }
};
struct Voice {
    std::array<float,kDelayCapacity> delay{};
    int write=0,whole=2;
    float fraction=0,filter=0;
    uint64_t age=0,sequence=0;
    uint32_t random=1;
    uint8_t note=0,channel=0;
    bool active=false,held=false,releasing=false;
    float velocity=0,env=0,releaseStep=0;
    int model=0;
    Mode wood{},metal{};

    void stop() noexcept {
        active=held=releasing=false;
        env=filter=0;age=0;write=0;
    }
    void tune(double rate, uint16_t pitchBend) noexcept {
        const double semitones = double(int(note)-69) +
            (double(int(pitchBend)-8192) / 8192.) * 2.;
        const double frequency = std::max(25.0,
            std::min(rate*0.4,440.0*std::exp2(semitones/12.)));
        const double length = std::max(2.0,
            std::min(double(kDelayCapacity-2),rate/frequency-0.5));
        whole = int(length);
        fraction=float(length-double(whole));
    }
    void start(uint8_t n,uint8_t vel,uint8_t ch,uint64_t order,
               double rate,uint16_t pitchBend,int kind) noexcept {
        stop();
        active=held=true;note=n;channel=ch;sequence=order;
        velocity=float(vel)/127.f;
        model=kind;
        random=0x9E3779B9u ^ (uint32_t(n)<<16) ^ uint32_t(order);
        if(!random) random=1;
        tune(rate,pitchBend);
        wood.configure(rate,190.,0.09);
        metal.configure(rate,460.,0.04);
    }
    void release(double rate, float seconds) noexcept {
        held=false;
        if(releasing||!active) return;
        releasing=true;
        releaseStep=1.f/float(rate*double(seconds));
    }
    float tick(const std::array<float,SPM_PARAMETER_COUNT>& p) noexcept {
        if(!active) return 0;
        // Only read cells written since this note was started. Old buffer
        // contents from a stolen voice are never heard; no O(delay) clear.
        float delayed=0;
        if(age>uint64_t(whole+1)) {
            int a=write-whole;
            if(a<0) a+=kDelayCapacity;
            int b=a-1;
            if(b<0) b+=kDelayCapacity;
            delayed=delay[size_t(a)] +
                (delay[size_t(b)]-delay[size_t(a)])*fraction;
        }
        const float brightness=p[SPM_PARAM_BRIGHTNESS];
        filter += (0.12f + brightness*0.78f)*(delayed-filter);
        const float retained=0.992f + 0.0077f*p[SPM_PARAM_DAMPING];
        float excitation=0;
        if(age<=uint64_t(whole+1)) {
            const float phase=float(age)/float(whole+1);
            if(model==0) {
                const float pos=p[SPM_PARAM_POSITION];
                const float triangle = phase<pos ? phase/pos :
                    (1.f-phase)/(1.f-pos);
                excitation=(2.f*triangle-1.f)*0.48f +
                    randomBipolar(random)*brightness*0.045f;
            } else {
                const float burst=std::exp(-phase*24.f);
                excitation=randomBipolar(random)*brightness*burst*0.8f;
            }
        }
        const float value=excitation+retained*filter;
        delay[size_t(write)]=value;
        if(++write==kDelayCapacity)write=0;
        ++age;
        if(releasing) {
            env -= releaseStep;
            if(env<=0.f) {stop();return 0;}
        } else if(env<1.f) {
            env=std::min(1.f,env+0.05f);
        }
        const float modal=0.55f*wood.process(value)+
                          0.30f*metal.process(value);
        const float mix=p[SPM_PARAM_BODY_MIX];
        return ((1.f-mix)*value+mix*modal)*env*velocity;
    }
};
} // namespace

struct SPMSynth {
    double rate;
    int polyphony;
    std::array<std::atomic<float>,SPM_PARAMETER_COUNT> parameters{};
    std::array<Voice,kMaxVoices> voices{};
    Queue queue{};
    std::array<Event,kQueueCapacity> pending{};
    uint32_t pendingCount=0;
    std::atomic<bool> panic{false};
    std::array<bool,16> sustain{};
    std::array<uint16_t,16> bend{};
    uint64_t sequence=0;

    SPMSynth(double sampleRate,int count):rate(sampleRate),polyphony(count) {
        for(size_t i=0;i<kDefaults.size();++i)
            parameters[i].store(kDefaults[i],std::memory_order_relaxed);
        bend.fill(8192);
    }
    void resetVoices() noexcept {
        pendingCount=0;sequence=0;sustain.fill(false);bend.fill(8192);
        for(auto& v:voices) v.stop();
    }
    void handle(Event e, const std::array<float,SPM_PARAMETER_COUNT>& p) noexcept {
        const uint8_t type=e.status&0xF0, ch=e.status&0x0F;
        if(type==0xE0) {
            bend[ch]=uint16_t(uint16_t(e.data1)|(uint16_t(e.data2)<<7));
            for(int i=0;i<polyphony;++i)
                if(voices[i].active&&voices[i].channel==ch)
                    voices[i].tune(rate,bend[ch]);
            return;
        }
        if(type==0xB0) {
            if(e.data1==64) {
                const bool wasDown=sustain[ch];
                sustain[ch]=e.data2>=64;
                if(wasDown&&!sustain[ch]) for(int i=0;i<polyphony;++i) {
                    Voice& v=voices[i];
                    if(v.active&&v.channel==ch&&!v.held)
                        v.release(rate,p[SPM_PARAM_RELEASE]);
                }
            } else if(e.data1==120||e.data1==123) {
                sustain[ch]=false;
                for(int i=0;i<polyphony;++i) {
                    Voice& v=voices[i];
                    if(v.active&&v.channel==ch) {
                        if(e.data1==120)v.stop();
                        else v.release(rate,p[SPM_PARAM_RELEASE]);
                    }
                }
            }
            return;
        }
        if(type==0x80||(type==0x90&&e.data2==0)) {
            Voice* oldest=nullptr;
            for(int i=0;i<polyphony;++i) {
                Voice& v=voices[i];
                if(v.active&&v.held&&v.note==e.data1&&v.channel==ch &&
                   (!oldest||v.sequence<oldest->sequence))oldest=&v;
            }
            if(oldest) {
                oldest->held=false;
                if(!sustain[ch])oldest->release(rate,p[SPM_PARAM_RELEASE]);
            }
            return;
        }
        if(type!=0x90) return;
        Voice* chosen=nullptr;
        for(int i=0;i<polyphony;++i)
            if(!voices[i].active) {chosen=&voices[i];break;}
        if(!chosen)for(int i=0;i<polyphony;++i)
            if(!voices[i].held&&(!chosen||voices[i].sequence<chosen->sequence))
                chosen=&voices[i];
        if(!chosen) {
            chosen=&voices[0];
            for(int i=1;i<polyphony;++i)
                if(voices[i].sequence<chosen->sequence)chosen=&voices[i];
        }
        chosen->start(e.data1,e.data2,ch,++sequence,rate,bend[ch],
                      int(p[SPM_PARAM_MODEL]));
    }
};

extern "C" {
SPMSynth* spm_create(double rate,int32_t polyphony) {
    if(!std::isfinite(rate)||rate<8000||rate>384000||
       polyphony<1||polyphony>kMaxVoices)return nullptr;
    return new(std::nothrow) SPMSynth(rate,polyphony);
}
void spm_destroy(SPMSynth* s){delete s;}
int32_t spm_set_parameter(SPMSynth* s,int32_t id,float value) {
    if(!s||!valid(id,value))return 0;
    s->parameters[size_t(id)].store(value,std::memory_order_relaxed);
    return 1;
}
float spm_get_parameter(const SPMSynth* s,int32_t id) {
    if(!s||id<0||id>=SPM_PARAMETER_COUNT)return 0;
    return s->parameters[size_t(id)].load(std::memory_order_relaxed);
}
int32_t spm_midi_event(SPMSynth* s,uint8_t status,uint8_t d1,
                       uint8_t d2,uint32_t offset) {
    if(!s||d1>127||d2>127||offset>65535)return 0;
    switch(status&0xF0) {
        case 0x80:case 0x90:case 0xE0:break;
        case 0xB0: if(d1!=64&&d1!=120&&d1!=123)return 0;break;
        default:return 0;
    }
    return s->queue.push({status,d1,d2,offset})?1:0;
}
int32_t spm_note_on(SPMSynth* s,uint8_t note,uint8_t velocity) {
    return spm_midi_event(s,0x90,note,velocity,0);
}
int32_t spm_note_off(SPMSynth* s,uint8_t note) {
    return spm_midi_event(s,0x80,note,0,0);
}
int32_t spm_all_notes_off(SPMSynth* s) {
    if(!s)return 0;
    s->panic.store(true,std::memory_order_release);
    return 1;
}
void spm_reset_stopped(SPMSynth* s) {
    if(!s)return;
    s->queue.clearStopped();
    s->panic.store(false,std::memory_order_relaxed);
    s->resetVoices();
}
void spm_render(SPMSynth* s,float* left,float* right,int32_t frames) {
    if(!s||!left||!right||frames<=0)return;
    std::array<float,SPM_PARAMETER_COUNT> p{};
    for(size_t i=0;i<p.size();++i)
        p[i]=s->parameters[i].load(std::memory_order_relaxed);
    Event incoming{};
    if(s->panic.exchange(false,std::memory_order_acq_rel)) {
        while(s->queue.pop(incoming)){}
        s->resetVoices();
    } else {
        while(s->pendingCount<kQueueCapacity&&s->queue.pop(incoming)) {
            uint32_t i=s->pendingCount++;
            while(i>0&&s->pending[i-1].offset>incoming.offset) {
                s->pending[i]=s->pending[i-1];--i;
            }
            s->pending[i]=incoming;
        }
    }
    uint32_t cursor=0;
    for(int32_t i=0;i<frames;++i) {
        while(cursor<s->pendingCount&&s->pending[cursor].offset<=uint32_t(i))
            s->handle(s->pending[cursor++],p);
        float sample=0;
        for(int v=0;v<s->polyphony;++v)
            sample+=s->voices[v].tick(p);
        sample=std::tanh(sample*p[SPM_PARAM_GAIN]*0.6f);
        left[i]=sample;
        right[i]=sample;
    }
    for(uint32_t i=cursor;i<s->pendingCount;++i) {
        Event event=s->pending[i];
        event.offset-=uint32_t(frames);
        s->pending[i-cursor]=event;
    }
    s->pendingCount-=cursor;
}
}
