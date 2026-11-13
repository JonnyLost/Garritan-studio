#include "StudioAdditiveDSP.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <new>

namespace {
constexpr double kTau = 6.2831853071795864769;
constexpr int kMaxVoices = 16;
constexpr int kTableSize = 2048; // power-of-two; 8 KB per shared table
constexpr uint32_t kQueueSize = 512;
constexpr std::array<float, SADD_PARAMETER_COUNT> makeDefaults() {
    std::array<float, SADD_PARAMETER_COUNT> p{};
    const std::array<float,25> original{{
        0.008f, 0.28f, 0.72f, 0.3f, 0.65f, 0.f, 0.45f, 1.8f, 2.f,
        0.8f, 0.28f, 0.15f, 0.12f, 0.07f, 0.05f, 0.04f, 0.025f,
        0.018f, 0.012f, 0.01f, 0.008f, 0.006f, 0.004f, 0.003f, 0.002f
    }};
    for (size_t i=0;i<original.size();++i) p[i]=original[i];
    p[SADD_PARAM_MOTION_RATE]=0.38f;
    p[SADD_PARAM_MOTION_DEPTH]=0.f; // Old projects remain unchanged.
    p[SADD_PARAM_MOTION_SPREAD]=0.35f;
    p[SADD_PARAM_MOTION_SHAPE]=0.f;
    p[SADD_PARAM_PARTIAL_ENVELOPE_MIX]=0.f; // Global envelope only by default.
    for(int h=0;h<SADD_PARTIAL_COUNT;++h) {
        p[SADD_PARAM_PARTIAL_ATTACK_BASE+h]=0.001f;
        p[SADD_PARAM_PARTIAL_DECAY_BASE+h]=0.2f;
        p[SADD_PARAM_PARTIAL_SUSTAIN_BASE+h]=1.f;
        p[SADD_PARAM_PARTIAL_RELEASE_BASE+h]=0.3f;
        p[SADD_PARAM_PARTIAL_MOTION_BASE+h]=1.f;
    }
    return p;
}
constexpr auto kDefaults=makeDefaults();
static_assert(kDefaults.size() == SADD_PARAMETER_COUNT, "C/Swift parameter mismatch");

bool validParameter(int32_t id, float v) noexcept {
    if (id < 0 || id >= SADD_PARAMETER_COUNT || !std::isfinite(v)) return false;
    switch (id) {
        case SADD_PARAM_ATTACK:
        case SADD_PARAM_DECAY:
        case SADD_PARAM_RELEASE: return v >= 0.001f && v <= 30.f;
        case SADD_PARAM_EVOLVE_TIME: return v >= 0.05f && v <= 20.f;
        case SADD_PARAM_TILT: return v >= -2.f && v <= 2.f;
        case SADD_PARAM_EVOLVE: return v >= -2.f && v <= 2.f;
        case SADD_PARAM_BEND_RANGE: return v >= 0.f && v <= 24.f;
        case SADD_PARAM_MOTION_RATE: return v >= 0.02f && v <= 12.f;
        default:
            if ((id >= SADD_PARAM_PARTIAL_ATTACK_BASE &&
                 id < SADD_PARAM_PARTIAL_SUSTAIN_BASE) ||
                (id >= SADD_PARAM_PARTIAL_RELEASE_BASE &&
                 id < SADD_PARAM_PARTIAL_MOTION_BASE))
                return v >= 0.001f && v <= 30.f;
            return v >= 0.f && v <= 1.f;
    }
}

struct SineTable {
    std::array<float,kTableSize> sample{};
    SineTable() {
        for (int i=0;i<kTableSize;++i)
            sample[static_cast<size_t>(i)] =
                static_cast<float>(std::sin(kTau*double(i)/double(kTableSize)));
    }
    float lookup(double phase) const noexcept {
        const double x = phase * kTableSize;
        const auto a = static_cast<unsigned>(x) & (kTableSize-1);
        const unsigned b = (a+1)&(kTableSize-1);
        const float fraction = static_cast<float>(x-std::floor(x));
        return sample[a] + (sample[b]-sample[a])*fraction;
    }
};

enum class Stage : uint8_t { idle, attack, decay, sustain, release };

/* Each voice has 16 independent envelopes, but no heap allocation and no
 * per-sample divisions: control coefficients are computed once per buffer.
 * Each partial can attack, sustain and release at its own rate.
 */
struct PartialEnvelope {
    Stage stage=Stage::idle;
    float value=0.f, releasedFrom=0.f;
    void trigger() noexcept {
        value=0.f; releasedFrom=0.f; stage=Stage::attack;
    }
    void off() noexcept {
        if(stage==Stage::idle || stage==Stage::release)return;
        releasedFrom=value;
        stage=Stage::release;
    }
    void reset() noexcept {
        value=releasedFrom=0.f; stage=Stage::idle;
    }
    float advance(float attackStep,float decayStep,float sustain,
                  float releaseStep) noexcept {
        switch(stage) {
            case Stage::idle: return 0.f;
            case Stage::attack:
                value+=attackStep;
                if(value>=1.f){value=1.f;stage=Stage::decay;}
                break;
            case Stage::decay:
                value-=decayStep;
                if(value<=sustain){value=sustain;stage=Stage::sustain;}
                break;
            case Stage::sustain: value=sustain;break;
            case Stage::release:
                value-=releasedFrom*releaseStep;
                if(value<=0.f)reset();
                break;
        }
        return value;
    }
};
struct PartialCoefficients {
    float attack=0,decay=0,sustain=1,release=0;
};

struct Voice {
    bool active=false, held=false;
    uint8_t note=0, channel=0;
    uint64_t age=0;
    double frequency=0, phase=0, evolution=1, motionPhase=0;
    float velocity=0, envelope=0, releaseStart=0;
    Stage stage=Stage::idle;
    std::array<PartialEnvelope,SADD_PARTIAL_COUNT> partialEnvelopes{};

    void trigger(uint8_t n,uint8_t v,uint8_t c,uint64_t sequence) noexcept {
        active=held=true; note=n; channel=c; age=sequence;
        frequency=440.0*std::exp2((int(n)-69)/12.0);
        phase=motionPhase=0; evolution=1;
        velocity=float(v)/127.f;
        envelope=releaseStart=0;
        stage=Stage::attack;
        for(auto& e:partialEnvelopes)e.trigger();
    }
    void release() noexcept {
        held=false;
        if (stage==Stage::idle || stage==Stage::release) return;
        releaseStart=envelope;
        stage=Stage::release;
        for(auto& e:partialEnvelopes)e.off();
    }
    void stop() noexcept {
        active=held=false;
        envelope=releaseStart=0;
        stage=Stage::idle;
        for(auto& e:partialEnvelopes)e.reset();
    }
    float advance(const std::array<float,SADD_PARAMETER_COUNT>& p,
                  double sampleRate) noexcept {
        switch (stage) {
            case Stage::idle: stop(); return 0.f;
            case Stage::attack:
                envelope+=static_cast<float>(1.0/(sampleRate*p[SADD_PARAM_ATTACK]));
                if (envelope>=1.f) {envelope=1.f;stage=Stage::decay;}
                break;
            case Stage::decay:
                envelope-=static_cast<float>((1.0-p[SADD_PARAM_SUSTAIN])/
                                             (sampleRate*p[SADD_PARAM_DECAY]));
                if(envelope<=p[SADD_PARAM_SUSTAIN]) {
                    envelope=p[SADD_PARAM_SUSTAIN];stage=Stage::sustain;
                }
                break;
            case Stage::sustain:
                envelope=p[SADD_PARAM_SUSTAIN];break;
            case Stage::release:
                envelope-=static_cast<float>(double(releaseStart)/
                                             (sampleRate*p[SADD_PARAM_RELEASE]));
                if(envelope<=0.f) {stop();return 0.f;}
                break;
        }
        return envelope;
    }
};

enum class EventType : uint8_t { on, off, controller, bend };
struct Event {
    EventType type=EventType::off;
    uint8_t channel=0,data1=0,data2=0;
    uint32_t offset=0;
};
struct Queue {
    std::array<Event,kQueueSize> events{};
    std::atomic<uint32_t> read{0},write{0};
    bool push(Event e) noexcept {
        const uint32_t w=write.load(std::memory_order_relaxed);
        if(w-read.load(std::memory_order_acquire)>=kQueueSize) return false;
        events[w%kQueueSize]=e;
        write.store(w+1,std::memory_order_release);
        return true;
    }
    bool pop(Event& e) noexcept {
        const uint32_t r=read.load(std::memory_order_relaxed);
        if(r==write.load(std::memory_order_acquire)) return false;
        e=events[r%kQueueSize];
        read.store(r+1,std::memory_order_release);
        return true;
    }
    void resetStopped() noexcept {
        read.store(write.load(std::memory_order_relaxed),
                   std::memory_order_relaxed);
    }
};
} // namespace

struct SADDSynth {
    double sampleRate;
    int voices;
    SineTable table{};
    std::array<std::atomic<float>,SADD_PARAMETER_COUNT> parameters{};
    std::array<float,SADD_PARTIAL_COUNT> smoothBeginning{}, smoothEnding{};
    std::array<Voice,kMaxVoices> voice{};
    Queue queue{};
    std::array<Event,kQueueSize> pending{};
    uint32_t pendingCount=0;
    std::atomic<bool> panic{false};
    std::array<bool,16> sustain{};
    std::array<uint16_t,16> bend{};
    std::array<uint8_t,16> wheel{};
    uint64_t sequence=0;

    SADDSynth(double sr,int count):sampleRate(sr),voices(count) {
        for(size_t i=0;i<kDefaults.size();++i)
            parameters[i].store(kDefaults[i],std::memory_order_relaxed);
        bend.fill(8192);
        for(int h=0;h<SADD_PARTIAL_COUNT;++h) {
            smoothEnding[h]=kDefaults[SADD_PARAM_PARTIAL_BASE+h];
            smoothBeginning[h]=smoothEnding[h]*
                std::pow(float(h+1),kDefaults[SADD_PARAM_EVOLVE]);
        }
    }
    void reset() noexcept {
        pendingCount=0;
        sustain.fill(false);
        wheel.fill(0);
        bend.fill(8192);
        for(Voice& v:voice) v.stop();
    }
    void handle(const Event& e) noexcept {
        const uint8_t ch=e.channel;
        if(e.type==EventType::controller) {
            if(e.data1==1) {wheel[ch]=e.data2;return;}
            if(e.data1==64) {
                const bool before=sustain[ch];
                sustain[ch]=e.data2>=64;
                if(before&&!sustain[ch])
                    for(int i=0;i<voices;++i)
                        if(voice[i].active && voice[i].channel==ch &&
                           !voice[i].held) voice[i].release();
                return;
            }
            if(e.data1==120||e.data1==123) {
                sustain[ch]=false;
                for(int i=0;i<voices;++i) if(voice[i].active &&
                                             voice[i].channel==ch) {
                    if(e.data1==120) voice[i].stop();
                    else voice[i].release();
                }
            }
            return;
        }
        if(e.type==EventType::bend) {
            bend[ch]=static_cast<uint16_t>(uint16_t(e.data1) |
                    uint16_t(uint16_t(e.data2)<<7));return;
        }
        if(e.type==EventType::off || e.data2==0) {
            Voice* oldest=nullptr;
            for(int i=0;i<voices;++i) {
                Voice& v=voice[i];
                if(v.active&&v.held&&v.note==e.data1&&v.channel==ch &&
                   (!oldest || v.age<oldest->age)) oldest=&v;
            }
            if(oldest) {
                oldest->held=false;
                if(!sustain[ch]) oldest->release();
            }
            return;
        }
        Voice* selected=nullptr;
        for(int i=0;i<voices;++i)
            if(!voice[i].active) {selected=&voice[i];break;}
        if(!selected)
            for(int i=0;i<voices;++i)
                if(!voice[i].held &&
                   (!selected || voice[i].age<selected->age)) selected=&voice[i];
        if(!selected) {
            selected=&voice[0];
            for(int i=1;i<voices;++i)
                if(voice[i].age<selected->age) selected=&voice[i];
        }
        selected->trigger(e.data1,e.data2,ch,++sequence);
    }
};

extern "C" {
SADDSynth* sadd_create(double sampleRate,int32_t voices) {
    if(!std::isfinite(sampleRate)||sampleRate<8000||sampleRate>384000||
       voices<1||voices>kMaxVoices) return nullptr;
    return new(std::nothrow) SADDSynth(sampleRate,voices);
}
void sadd_destroy(SADDSynth* synth) {delete synth;}
int32_t sadd_set_parameter(SADDSynth* synth,int32_t id,float v) {
    if(!synth||!validParameter(id,v))return 0;
    synth->parameters[static_cast<size_t>(id)].store(v,std::memory_order_relaxed);
    return 1;
}
float sadd_get_parameter(const SADDSynth* synth,int32_t id) {
    if(!synth||id<0||id>=SADD_PARAMETER_COUNT)return 0.f;
    return synth->parameters[static_cast<size_t>(id)].load(
        std::memory_order_relaxed);
}
int32_t sadd_midi_event(SADDSynth* synth,uint8_t status,
                        uint8_t d1,uint8_t d2,uint32_t offset) {
    if(!synth||d1>127||d2>127||offset>65535)return 0;
    EventType type;
    switch(status&0xf0) {
        case 0x80: type=EventType::off;break;
        case 0x90: type=d2==0?EventType::off:EventType::on;break;
        case 0xB0:
            if(d1!=1&&d1!=64&&d1!=120&&d1!=123)return 0;
            type=EventType::controller;break;
        case 0xE0: type=EventType::bend;break;
        default: return 0;
    }
    return synth->queue.push({type,uint8_t(status&0x0f),d1,d2,offset})?1:0;
}
int32_t sadd_all_notes_off(SADDSynth* synth) {
    if(!synth)return 0;
    synth->panic.store(true,std::memory_order_release);
    return 1;
}
void sadd_reset_stopped(SADDSynth* synth) {
    if(!synth)return;
    synth->queue.resetStopped();
    synth->panic.store(false,std::memory_order_relaxed);
    synth->reset();
}
void sadd_render(SADDSynth* synth,float* left,float* right,int32_t frames) {
    if(!synth||!left||!right||frames<=0)return;
    std::array<float,SADD_PARAMETER_COUNT> p{};
    for(size_t i=0;i<p.size();++i)
        p[i]=synth->parameters[i].load(std::memory_order_relaxed);

    Event incoming{};
    if(synth->panic.exchange(false,std::memory_order_acq_rel)) {
        while(synth->queue.pop(incoming)) {}
        synth->reset();
    } else {
        while(synth->pendingCount<kQueueSize &&
              synth->queue.pop(incoming)) {
            uint32_t i=synth->pendingCount++;
            while(i>0 && synth->pending[i-1].offset>incoming.offset) {
                synth->pending[i]=synth->pending[i-1];--i;
            }
            synth->pending[i]=incoming;
        }
    }

    std::array<float,SADD_PARTIAL_COUNT> targetBeginning{},targetEnding{};
    std::array<PartialCoefficients,SADD_PARTIAL_COUNT> envelopeSteps{};
    float normalization=0.f;
    const float envelopeBlend=p[SADD_PARAM_PARTIAL_ENVELOPE_MIX];
    const float motionDepth=p[SADD_PARAM_MOTION_DEPTH];
    const double motionRate=double(p[SADD_PARAM_MOTION_RATE])/synth->sampleRate;
    const float motionSpread=p[SADD_PARAM_MOTION_SPREAD];
    const float motionShape=p[SADD_PARAM_MOTION_SHAPE];
    for(int h=0;h<SADD_PARTIAL_COUNT;++h) {
        const float level=p[SADD_PARAM_PARTIAL_BASE+h];
        const float harmonic=float(h+1);
        targetEnding[h]=level*std::pow(harmonic,p[SADD_PARAM_TILT]);
        targetBeginning[h]=level*
            std::pow(harmonic,p[SADD_PARAM_TILT]+p[SADD_PARAM_EVOLVE]);
        normalization+=std::max(std::abs(targetEnding[h]),
                                std::abs(targetBeginning[h]));
        const float attack=p[SADD_PARAM_PARTIAL_ATTACK_BASE+h];
        const float decay=p[SADD_PARAM_PARTIAL_DECAY_BASE+h];
        const float sustain=p[SADD_PARAM_PARTIAL_SUSTAIN_BASE+h];
        const float release=p[SADD_PARAM_PARTIAL_RELEASE_BASE+h];
        envelopeSteps[h] = {
            float(1.0/(synth->sampleRate*attack)),
            float((1.0-sustain)/(synth->sampleRate*decay)),
            sustain,
            float(1.0/(synth->sampleRate*release))
        };
    }
    // Prevent loud 16-harmonic stacks without normalizing quiet, sparse sounds.
    const float normalize=1.f/std::max(1.f,normalization);
    const double evolveMultiplier=std::exp(-1.0/
        (synth->sampleRate*double(p[SADD_PARAM_EVOLVE_TIME])));
    const float slew=static_cast<float>(1.0-
        std::exp(-1.0/(0.008*synth->sampleRate)));
    std::array<double,16> bends{};
    for(int ch=0;ch<16;++ch) {
        const double raw=double(int(synth->bend[ch])-8192);
        const double normalized=raw/(raw>=0.0?8191.0:8192.0);
        bends[ch]=std::exp2(normalized*p[SADD_PARAM_BEND_RANGE]/12.0);
    }
    uint32_t cursor=0;
    for(int32_t frame=0;frame<frames;++frame) {
        while(cursor<synth->pendingCount &&
              synth->pending[cursor].offset<=uint32_t(frame)) {
            const Event e=synth->pending[cursor++];
            synth->handle(e);
            if(e.type==EventType::bend) {
                const int ch=e.channel;
                const double raw=double(int(synth->bend[ch])-8192);
                const double normalized=raw/(raw>=0.0?8191.0:8192.0);
                bends[ch]=std::exp2(normalized*p[SADD_PARAM_BEND_RANGE]/12.0);
            }
        }
        for(int h=0;h<SADD_PARTIAL_COUNT;++h) {
            synth->smoothEnding[h]+=slew*(targetEnding[h]-synth->smoothEnding[h]);
            synth->smoothBeginning[h]+=
                slew*(targetBeginning[h]-synth->smoothBeginning[h]);
        }
        double mixed=0;
        for(int vi=0;vi<synth->voices;++vi) {
            Voice& v=synth->voice[vi];
            if(!v.active)continue;
            const float env=v.advance(p,synth->sampleRate);
            if(!v.active)continue;
            const double fundamental=v.frequency*bends[v.channel];
            const double evolution=v.evolution;
            const double releaseAmount=1.0-evolution;
            const double nyquist=synth->sampleRate*0.45;
            double harmonics=0;
            for(int h=0;h<SADD_PARTIAL_COUNT;++h) {
                const PartialCoefficients& steps=envelopeSteps[h];
                const float partialEnvelope=v.partialEnvelopes[h].advance(
                    steps.attack,steps.decay,steps.sustain,steps.release);
                // Advance every envelope even above Nyquist, otherwise a
                // pitch bend could reintroduce a stale upper-harmonic stage.
                if(double(h+1)*fundamental>=nyquist)continue;
                float level=static_cast<float>(
                    synth->smoothBeginning[h]*evolution+
                    synth->smoothEnding[h]*releaseAmount);
                if(envelopeBlend>0.f)
                    level*=1.f+envelopeBlend*(partialEnvelope-1.f);
                const float harmonicMotion=p[SADD_PARAM_PARTIAL_MOTION_BASE+h];
                if(motionDepth>0.f && harmonicMotion>0.f) {
                    double motionPosition=v.motionPhase+
                        double(h)*double(motionSpread)/SADD_PARTIAL_COUNT;
                    motionPosition-=std::floor(motionPosition);
                    const float sine=synth->table.lookup(motionPosition);
                    const float triangle=1.f-4.f*static_cast<float>(
                        std::abs(motionPosition-0.5));
                    const float wave=sine+(triangle-sine)*motionShape;
                    level*=1.f+motionDepth*harmonicMotion*wave;
                }
                if(std::abs(level)<0.000001f)continue;
                double partialPhase=v.phase*double(h+1);
                partialPhase-=std::floor(partialPhase);
                harmonics+=level*synth->table.lookup(partialPhase);
            }
            mixed+=harmonics*env*v.velocity*normalize;
            v.evolution*=evolveMultiplier;
            v.motionPhase+=motionRate;
            if(v.motionPhase>=1.0)v.motionPhase-=1.0;
            v.phase+=fundamental/synth->sampleRate;
            if(v.phase>=1.0)v.phase-=std::floor(v.phase);
        }
        const float out=std::tanh(static_cast<float>(mixed)*p[SADD_PARAM_OUTPUT_GAIN]);
        left[frame]=out;
        right[frame]=out;
    }
    for(uint32_t i=cursor;i<synth->pendingCount;++i) {
        Event e=synth->pending[i];
        e.offset-=uint32_t(frames);
        synth->pending[i-cursor]=e;
    }
    synth->pendingCount-=cursor;
}
}
