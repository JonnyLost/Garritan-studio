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
constexpr size_t kPercussionModes = 6;
constexpr int kDelayCapacity = 16384; // Supports A0 at 384 kHz with margin.
constexpr uint32_t kQueueCapacity = 512;
constexpr double kTau = 6.28318530717958647692;
constexpr std::array<float, SPM_PARAMETER_COUNT> kDefaults{{
    0.f, 0.55f, 0.7f, 0.25f, 0.25f, 0.2f, 0.5f,
    0.45f, 0.15f, 0.5f, 0.55f, 0.65f, 0.12f, 0.65f, 0.55f, 0.12f, 0.5f,
    0.5f, 0.55f, 0.8f, 0.18f
}};

bool valid(int id, float value) noexcept {
    if (id < 0 || id >= SPM_PARAMETER_COUNT || !std::isfinite(value)) return false;
    switch (id) {
        case SPM_PARAM_MODEL: return value >= 0.f && value <= 7.f &&
            value == std::floor(value);
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
        y2=std::abs(y1)<1.0e-20f ? 0.f : y1;
        y1=std::abs(y)<1.0e-20f ? 0.f : y;
        return y1;
    }
};
/* Six independently tuned, exponentially decaying modes. The oscillator
 * rotation and damping coefficients are prepared on note-on or pitch bend;
 * processing is allocation-free, branch-light and trigonometry-free. */
struct PercussionMode {
    float cosine=1.f, sine=0.f, radius=0.f;
    float real=0.f, imaginary=0.f, gain=0.f;
    double ratio=1.0;
    bool enabled=false;

    void retune(double rate, double fundamental) noexcept {
        const double hz=fundamental*ratio;
        enabled=hz>0.0 && hz<rate*0.45;
        if(!enabled) return;
        const double phase=kTau*hz/rate;
        cosine=float(std::cos(phase));
        sine=float(std::sin(phase));
    }
    void configure(double rate, double fundamental, double modeRatio,
                   double seconds, float amplitude) noexcept {
        ratio=modeRatio;
        gain=amplitude;
        real=imaginary=0.f;
        radius=float(std::exp(-1.0/(rate*seconds)));
        retune(rate,fundamental);
    }
    float tick(float impulse) noexcept {
        if(!enabled) return 0.f;
        const float nextReal=radius*(cosine*real-sine*imaginary)+impulse*gain;
        const float nextImag=radius*(sine*real+cosine*imaginary);
        // Silence subnormal modal tails to avoid expensive denormal arithmetic.
        real=std::abs(nextReal)<1.0e-20f ? 0.f : nextReal;
        imaginary=std::abs(nextImag)<1.0e-20f ? 0.f : nextImag;
        return real;
    }
};
constexpr std::array<double,kPercussionModes> kMalletRatios{{
    1.0,3.93,9.20,16.80,25.40,34.70
}};
constexpr std::array<double,kPercussionModes> kBellRatios{{
    1.0,1.50,2.05,2.66,3.89,5.40
}};
constexpr std::array<double,kPercussionModes> kMembraneRatios{{
    1.0,1.59,2.14,2.30,2.65,2.92
}};

struct Voice {
    std::array<float,kDelayCapacity> delay{};
    int write=0,whole=2;
    float fraction=0,filter=0,dispersion=0;
    uint64_t age=0,sequence=0;
    uint32_t random=1;
    uint8_t note=0,channel=0;
    bool active=false,held=false,releasing=false;
    float velocity=0,env=0,releaseStep=0;
    float burst=1.f,burstDecay=1.f;
    float contact=0.25f,hardness=0.45f,stiffness=0.15f;
    float bowFriction=0.f,bowMotion=0.f;
    float airState=0.f,lipState=0.f;
    std::array<PercussionMode,kPercussionModes> percussion{};
    uint64_t percussionTail=0;
    uint32_t attackSamples=0,tailFadeSamples=1;
    double fundamental=440.0;
    int model=0;
    Mode wood{},metal{};

    void stop() noexcept {
        active=held=releasing=false;
        env=filter=dispersion=bowFriction=bowMotion=airState=lipState=0;age=0;write=0;
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
        fundamental=frequency;
        // Retune ringing partials in place, preserving their decay state.
        if(model>=5 && age>0)
            for(auto& partial:percussion) partial.retune(rate,frequency);
    }
    void configurePercussion(double rate,
                             const std::array<float,SPM_PARAMETER_COUNT>& p) noexcept {
        const auto& ratios=model==5 ? kMalletRatios :
            (model==6 ? kBellRatios : kMembraneRatios);
        const double hardness=p[SPM_PARAM_PERC_HARDNESS];
        const double material=p[SPM_PARAM_PERC_INHARMONICITY];
        const double decay=p[SPM_PARAM_PERC_DECAY];
        const double tail=model==6 ? 0.25+6.0*decay :
            (model==5 ? 0.12+4.0*decay : 0.06+1.8*decay);
        for(size_t i=0;i<percussion.size();++i) {
            const double harmonic=double(i+1);
            const double ratio=harmonic+(ratios[i]-harmonic)*material;
            const double contactWeight=0.30+0.70*std::abs(
                std::sin(kTau*0.5*ratio*double(contact)));
            const double hardnessWeight=i==0 ? 1.0 : 0.15+0.85*hardness;
            const float amplitude=float(0.70*std::pow(0.64,double(i))*
                contactWeight*hardnessWeight);
            percussion[i].configure(rate,fundamental,ratio,
                tail*std::pow(0.84,double(i)),amplitude);
        }
        attackSamples=uint32_t(rate*(0.0015+0.006*hardness));
        burst=1.f;
        burstDecay=float(std::exp(-8.0/double(std::max(1u,attackSamples))));
        percussionTail=uint64_t(rate*std::min(20.0,tail*6.0));
        tailFadeSamples=std::max(1u,uint32_t(rate*0.02));
        env=1.f; // Preserve the fast transient of a mallet/striker.
    }
    void start(uint8_t n,uint8_t vel,uint8_t ch,uint64_t order,
               double rate,uint16_t pitchBend,
               const std::array<float,SPM_PARAMETER_COUNT>& p) noexcept {
        stop();
        active=held=true;note=n;channel=ch;sequence=order;
        velocity=float(vel)/127.f;
        model=int(p[SPM_PARAM_MODEL]);
        contact=p[SPM_PARAM_POSITION];
        hardness=p[SPM_PARAM_PICK_HARDNESS];
        stiffness=p[SPM_PARAM_STIFFNESS];
        random=0x9E3779B9u ^ (uint32_t(n)<<16) ^ uint32_t(order);
        if(!random) random=1;
        tune(rate,pitchBend);
        burst=1.f;
        burstDecay=float(std::exp(-(12.0+32.0*hardness)/double(whole+1)));
        const double bodyScale=std::exp2((0.5-double(p[SPM_PARAM_BODY_SIZE]))*1.5);
        wood.configure(rate,190.*bodyScale,0.09);
        metal.configure(rate,460.*bodyScale,0.04);
        if(model>=5) configurePercussion(rate,p);
    }
    void release(double rate, float seconds) noexcept {
        held=false;
        if(releasing||!active) return;
        releasing=true;
        releaseStep=1.f/float(rate*double(seconds));
    }
    float tick(const std::array<float,SPM_PARAMETER_COUNT>& p,
               float expression, float dynamics, float breath) noexcept {
        if(!active) return 0;
        if(model>=5) {
            // Single impact excites tuned, inharmonic, material-dependent modes.
            // Short bounded noise burst models mallet and membrane transients.
            float impact=age==0 ? 0.65f : 0.f;
            if(age<attackSamples) {
                impact+=randomBipolar(random)*
                    p[SPM_PARAM_PERC_ATTACK_NOISE]*0.10f*burst;
                burst*=burstDecay;
            }
            float sum=0.f;
            for(auto& partial:percussion) sum+=partial.tick(impact);
            ++age;
            if(releasing) {
                env-=releaseStep;
                if(env<=0.f) {stop();return 0.f;}
            }
            if(age>=percussionTail) {stop();return 0.f;}
            // Prevent clicks when a long metallic ring reaches the bounded
            // maximum tail time: fade the final 20 ms to exact silence.
            const uint64_t remaining=percussionTail-age;
            if(remaining<tailFadeSamples)
                sum*=float(remaining)/float(tailFadeSamples);
            return sum*env*velocity*dynamics;
        }
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
        // A small allpass-like bridge dispersion stage adds controllable
        // string stiffness without unstable feedback or extra allocations.
        const float dispersed=delayed + stiffness*(dispersion-delayed);
        dispersion=delayed;
        const float filterCutoff=(model>=3 ? 0.08f+0.68f*p[SPM_PARAM_BORE] :
            0.12f+brightness*0.78f);
        filter += filterCutoff*(dispersed-filter);
        if(std::abs(filter)<1.0e-20f) filter=0.f;
        const float retained=0.992f + 0.0077f*p[SPM_PARAM_DAMPING];
        float excitation=0;
        if(model==3 || model==4) {
            // Bounded nonlinear reed/lip valve coupled to a resonant bore.
            // Breath pressure is continuously driven, unlike a pluck.
            const float pressure=p[SPM_PARAM_BREATH]*breath;
            const float stiffness=p[SPM_PARAM_REED_STIFFNESS];
            const float bore=p[SPM_PARAM_BORE];
            const float turbulence=randomBipolar(random)*
                p[SPM_PARAM_AIR_NOISE]*pressure*0.006f;
            const float difference=pressure*0.9f-delayed*0.55f;
            const float opening=std::max(0.f, std::min(1.f,
                0.5f+difference*(model==3 ? 1.5f+stiffness : 0.6f+stiffness)));
            const float flow=difference*opening;
            const float drive=(model==3 ? flow/(1.f+4.f*flow*flow) :
                flow*flow*flow/(0.25f+flow*flow));
            const float response=model==3 ? 0.045f : 0.018f;
            lipState += response*(drive-lipState);
            airState += (0.015f+0.08f*bore)*(lipState-airState);
            excitation=(model==3 ? 0.028f : 0.018f)*
                (lipState+airState)+turbulence;
        } else if(model==2) {
            // Nonlinear stick/slip excitation, continuously coupled to the
            // string feedback. The low-pass friction state avoids impulses
            // when bow velocity or pressure changes during a held note.
            const float pressure=p[SPM_PARAM_BOW_PRESSURE];
            const float speed=p[SPM_PARAM_BOW_SPEED]*expression;
            const float relative=speed*0.8f-delayed*0.65f;
            const float slip=relative/(1.f+12.f*relative*relative);
            const float force=(0.001f+0.045f*pressure)*slip;
            bowFriction += 0.08f*(force-bowFriction);
            bowMotion += 0.004f*(bowFriction-bowMotion);
            const float hair=randomBipolar(random)*p[SPM_PARAM_BOW_NOISE]
                *pressure*speed*0.004f;
            excitation=bowFriction+bowMotion+hair;
            if(age<uint64_t(whole))
                excitation+=randomBipolar(random)*0.003f*pressure*speed;
        } else if(age<=uint64_t(whole+1)) {
            const float phase=float(age)/float(whole+1);
            if(model==0) {
                const float triangle = phase<contact ? phase/contact :
                    (1.f-phase)/(1.f-contact);
                const float finger=2.f*triangle-1.f;
                const float noise=randomBipolar(random)*brightness*hardness;
                excitation=finger*(0.45f-0.12f*hardness)+
                    noise*(0.01f+0.09f*hardness);
            } else {
                const float hammer=0.4f+0.6f*hardness;
                excitation=randomBipolar(random)*brightness*burst*hammer;
                burst*=burstDecay;
            }
        }
        // Sustained bow drive needs a lossier string loop than a pluck;
        // its ongoing excitation supplies the missing energy.
        const float feedback=(model>=2 ? 0.995f : retained)*filter;
        const float value=excitation+feedback;
        // Clear inaudible feedback tails before storing them in the delay.
        delay[size_t(write)]=std::abs(value)<1.0e-20f ? 0.f : value;
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
        return ((1.f-mix)*value+mix*modal)*env*velocity*dynamics;
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
    std::array<float,16> bowExpression{}, dynamics{}, breathExpression{};
    uint64_t sequence=0;

    SPMSynth(double sampleRate,int count):rate(sampleRate),polyphony(count) {
        for(size_t i=0;i<kDefaults.size();++i)
            parameters[i].store(kDefaults[i],std::memory_order_relaxed);
        bend.fill(8192);
        bowExpression.fill(1.f);dynamics.fill(1.f);breathExpression.fill(1.f);
    }
    void resetVoices() noexcept {
        pendingCount=0;sequence=0;sustain.fill(false);bend.fill(8192);
        bowExpression.fill(1.f);dynamics.fill(1.f);breathExpression.fill(1.f);
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
            if(e.data1==2) {breathExpression[ch]=float(e.data2)/127.f;return;}
            if(e.data1==1) {bowExpression[ch]=float(e.data2)/127.f;return;}
            if(e.data1==11) {dynamics[ch]=float(e.data2)/127.f;return;}
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
        chosen->start(e.data1,e.data2,ch,++sequence,rate,bend[ch],p);
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
        case 0xB0: if(d1!=1&&d1!=2&&d1!=11&&d1!=64&&d1!=120&&d1!=123)return 0;break;
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
            sample+=s->voices[v].tick(p,
                s->bowExpression[s->voices[v].channel],
                s->dynamics[s->voices[v].channel],
                s->breathExpression[s->voices[v].channel]);
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
