#include "StudioWavetableDSP.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <new>

namespace {
constexpr double kTau = 6.283185307179586476925286766559;
constexpr int kMaxVoices = 16;
constexpr int kFrames = 5; // Factory frames; sixth frame is the custom spectrum.
constexpr int kTableSize = 1024;
constexpr int kMipCount = 9; // 1, 2, 4, ... 256 harmonics per mip.
constexpr uint32_t kQueueCapacity = 256;
constexpr int kPartialCount = SWS_CUSTOM_PARTIALS;
constexpr std::array<float, SWS_PARAMETER_COUNT> kDefaults{
    2.f, 0.f, 0.65f, 0.2f, 0.f,
    0.005f, 0.25f, 0.7f, 0.25f,
    0.7f, 2.f, 0.5f, 0.f, 0.f, 0.f,
    1.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f,
    0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f
};
static_assert(kDefaults.size() == SWS_PARAMETER_COUNT, "parameter/default mismatch");

bool validParameter(int32_t id, float value) noexcept {
    if (id < 0 || id >= SWS_PARAMETER_COUNT || !std::isfinite(value)) return false;
    switch (id) {
        case SWS_PARAM_OSC1_POSITION:
        case SWS_PARAM_OSC2_POSITION: return value >= 0.f && value <= 5.f;
        case SWS_PARAM_OSC1_LEVEL:
        case SWS_PARAM_OSC2_LEVEL:
        case SWS_PARAM_SUSTAIN:
        case SWS_PARAM_OUTPUT_GAIN:
        case SWS_PARAM_LFO_DEPTH:
            return value >= 0.f && value <= 1.f;
        case SWS_PARAM_OSC2_DETUNE: return value >= -24.f && value <= 24.f;
        case SWS_PARAM_ATTACK:
        case SWS_PARAM_DECAY:
        case SWS_PARAM_RELEASE: return value >= 0.001f && value <= 30.f;
        case SWS_PARAM_BEND_RANGE: return value >= 0.f && value <= 24.f;
        case SWS_PARAM_LFO_RATE: return value >= 0.05f && value <= 20.f;
        case SWS_PARAM_VELOCITY_POSITION:
        case SWS_PARAM_MODWHEEL_POSITION: return value >= -1.f && value <= 1.f;
        default: return value >= 0.f && value <= 1.f;
    }
}

float partialAmplitude(int frame, int harmonic) noexcept {
    switch(frame) {
        case 0: return harmonic == 1 ? 1.f : 0.f; // Sine
        case 1: // Triangle: odd harmonics, alternating polarity
            return harmonic % 2 == 0 ? 0.f :
                   ((harmonic / 2) % 2 ? -1.f : 1.f) / float(harmonic * harmonic);
        case 2: return (harmonic % 2 ? 1.f : -1.f) / float(harmonic); // Saw
        case 3: return harmonic % 2 ? 1.f / float(harmonic) : 0.f; // Pulse 50%
        case 4: // Sparse, original glass spectrum
            switch(harmonic) {
                case 1: return 0.72f;
                case 2: return 0.23f;
                case 5: return 0.43f;
                case 7: return -0.28f;
                case 11: return 0.17f;
                case 15: return 0.12f;
                default: return 0.f;
            }
        default: return 0.f;
    }
}

using SampleTable = std::array<float, kTableSize>;
struct TableBank {
    std::array<std::array<SampleTable, kMipCount>, kFrames> frames{};

    TableBank() {
        for (int frame = 0; frame < kFrames; ++frame)
            for (int mip = 0; mip < kMipCount; ++mip) {
                const int harmonics = 1 << mip;
                SampleTable& table = frames[frame][mip];
                float peak = 0.f;
                for (int n = 0; n < kTableSize; ++n) {
                    const double angle = kTau * double(n) / kTableSize;
                    const double sn = std::sin(angle), cs = std::cos(angle);
                    double sh = sn, ch = cs, value = 0.0;
                    for (int h = 1; h <= harmonics; ++h) {
                        value += double(partialAmplitude(frame, h)) * sh;
                        const double nextS = sh * cs + ch * sn;
                        ch = ch * cs - sh * sn;
                        sh = nextS;
                    }
                    table[n] = static_cast<float>(value);
                    peak = std::max(peak, std::abs(table[n]));
                }
                if (peak > 0.f) {
                    const float inv = 1.f/peak;
                    for (float& sample : table) sample *= inv;
                }
            }
    }
};

const TableBank& sharedBank() {
    static const TableBank bank{}; // Initialized before entering any render callback.
    return bank;
}

float interpolate(const SampleTable& table, double phase) noexcept {
    const double x = phase * kTableSize;
    const int a = static_cast<int>(x) & (kTableSize - 1);
    const int b = (a + 1) & (kTableSize - 1);
    const float f = static_cast<float>(x - std::floor(x));
    return table[a] + (table[b] - table[a]) * f;
}
int mipFor(double frequency, double sampleRate) noexcept {
    const int maxHarmonics = static_cast<int>(
        std::max(1.0, std::floor(sampleRate * 0.45 /
        std::max(1.0, frequency))));
    int mip = 0;
    while (mip + 1 < kMipCount &&
           (1 << (mip+1)) <= maxHarmonics) ++mip;
    return mip;
}

enum class Stage : uint8_t { idle, attack, decay, sustain, release };
struct Envelope {
    Stage stage = Stage::idle;
    float value = 0.f, releaseStart = 0.f;
    void on() noexcept { stage = Stage::attack; value = releaseStart = 0.f; }
    void off() noexcept {
        if (stage == Stage::idle || stage == Stage::release) return;
        stage = Stage::release;
        releaseStart = value;
    }
    void reset() noexcept {
        stage = Stage::idle;
        value = releaseStart = 0.f;
    }
    float next(float attack, float decay, float sustain, float release,
               double sampleRate) noexcept {
        switch(stage) {
            case Stage::idle: value = 0.f; break;
            case Stage::attack:
                value += static_cast<float>(
                    1.0/std::max(1.0, double(attack)*sampleRate));
                if (value >= 1.f) { value = 1.f; stage = Stage::decay; }
                break;
            case Stage::decay:
                value -= static_cast<float>(
                    (1.0-double(sustain)) /
                    std::max(1.0, double(decay)*sampleRate));
                if (value <= sustain) { value = sustain; stage = Stage::sustain; }
                break;
            case Stage::sustain: value = sustain; break;
            case Stage::release:
                value -= static_cast<float>(
                    double(releaseStart) /
                    std::max(1.0, double(release)*sampleRate));
                if (value <= 0.f) reset();
                break;
        }
        return value;
    }
};

struct Params {
    std::array<float, SWS_PARAMETER_COUNT> p{};
    float operator[](int id) const noexcept { return p[static_cast<size_t>(id)]; }
};

struct Voice {
    bool active = false, held = false;
    uint8_t note = 0, channel = 0;
    uint64_t age = 0;
    float velocity = 0.f;
    double frequency = 0.0;
    double phase1 = 0.0, phase2 = 0.0;
    Envelope envelope{};

    void trigger(uint8_t n, uint8_t v, uint8_t ch, uint64_t index) noexcept {
        active = held = true;
        note = n; channel = ch; age = index;
        velocity = float(v)/127.f;
        frequency = 440.0*std::exp2((int(n)-69)/12.0);
        phase1 = phase2 = 0.0;
        envelope.on();
    }
    void release() noexcept { held = false; envelope.off(); }
    void hardStop() noexcept { active = held = false; envelope.reset(); }
};

enum class EventType : uint8_t { noteOn, noteOff, cc, bend };
struct Event {
    EventType type = EventType::noteOff;
    uint8_t channel = 0, data1 = 0, data2 = 0;
    uint32_t offset = 0;
};
struct Queue {
    std::array<Event, kQueueCapacity> items{};
    std::atomic<uint32_t> read{0}, write{0};
    bool push(Event e) noexcept {
        const auto w = write.load(std::memory_order_relaxed);
        if (w-read.load(std::memory_order_acquire) >= kQueueCapacity) return false;
        items[w % kQueueCapacity] = e;
        write.store(w+1,std::memory_order_release);
        return true;
    }
    bool pop(Event& e) noexcept {
        const auto r = read.load(std::memory_order_relaxed);
        if (r == write.load(std::memory_order_acquire)) return false;
        e = items[r % kQueueCapacity];
        read.store(r+1,std::memory_order_release);
        return true;
    }
    void resetStopped() noexcept {
        read.store(write.load(std::memory_order_relaxed),
                   std::memory_order_relaxed);
    }
};
} // namespace

struct SWSynth {
    double sampleRate = 44100;
    int voices = 8;
    const TableBank* bank;
    std::array<std::atomic<float>, SWS_PARAMETER_COUNT> parameters{};
    std::array<float,SWS_PARAMETER_COUNT> smoothed{};
    std::array<Voice,kMaxVoices> voice{};
    Queue queue{};
    std::array<Event,kQueueCapacity> pending{};
    uint32_t pendingCount = 0;
    std::atomic<bool> panic{false};
    std::array<bool,16> sustain{};
    std::array<uint8_t,16> wheel{};
    std::array<uint16_t,16> bend{};
    std::array<float,16> smoothWheel{};
    double lfoPhase = 0.0;
    uint64_t counter = 0;

    SWSynth(double sr, int count, const TableBank& tables)
        : sampleRate(sr), voices(count), bank(&tables) {
        for (size_t i=0;i<parameters.size();++i)
            parameters[i].store(kDefaults[i],std::memory_order_relaxed);
        smoothed = kDefaults;
        bend.fill(8192);
    }
    void reset() noexcept {
        pendingCount = 0;
        sustain.fill(false);
        wheel.fill(0);
        smoothWheel.fill(0.f);
        bend.fill(8192);
        for (Voice& v:voice) v.hardStop();
    }
    void event(const Event& e) noexcept {
        const uint8_t ch = e.channel;
        if (e.type == EventType::cc) {
            switch(e.data1) {
                case 1: wheel[ch] = e.data2; break;
                case 64: {
                    const bool before = sustain[ch];
                    sustain[ch] = e.data2 >= 64;
                    if (before && !sustain[ch]) {
                        for (int i=0;i<voices;++i) {
                            Voice& v = voice[i];
                            if (v.active && v.channel == ch && !v.held)
                                v.release();
                        }
                    }
                    break;
                }
                case 120:
                case 123:
                    for (int i=0;i<voices;++i) {
                        Voice& v=voice[i];
                        if (v.active && v.channel == ch) {
                            if (e.data1 == 120) v.hardStop();
                            else v.release();
                        }
                    }
                    break;
                default: break;
            }
            return;
        }
        if (e.type == EventType::bend) {
            bend[ch] = uint16_t(e.data1) |
                       uint16_t(uint16_t(e.data2)<<7);
            return;
        }
        if (e.type == EventType::noteOff || e.data2 == 0) {
            Voice* oldest = nullptr;
            for(int i=0;i<voices;++i) {
                Voice& v=voice[i];
                if(v.active && v.held && v.channel == ch &&
                   v.note == e.data1 &&
                   (!oldest || v.age < oldest->age)) oldest=&v;
            }
            if(oldest) {
                oldest->held = false;
                if(!sustain[ch]) oldest->release();
            }
            return;
        }
        Voice* selected = nullptr;
        for(int i=0;i<voices;++i) {
            if(!voice[i].active) {selected = &voice[i];break;}
        }
        if(!selected) {
            for(int i=0;i<voices;++i) {
                Voice& v=voice[i];
                if(!v.held && (!selected || v.age < selected->age))
                    selected=&v;
            }
        }
        if(!selected) {
            selected=&voice[0];
            for(int i=1;i<voices;++i)
                if(voice[i].age < selected->age) selected=&voice[i];
        }
        selected->trigger(e.data1,e.data2,ch,++counter);
    }
};

namespace {
float customWave(double phase, int harmonics, const Params& p,
                 float scale, const TableBank& bank) noexcept {
    const auto& sine = bank.frames[0][0]; // One-cycle bandlimited sine.
    float sum = 0.f;
    for(int h=1;h<=kPartialCount && h<=harmonics;++h) {
        const float amplitude = p[SWS_PARAM_PARTIAL_BASE+h-1];
        if (amplitude < 0.00001f) continue;
        double x = phase*h;
        x -= std::floor(x);
        sum += amplitude*interpolate(sine,x);
    }
    return sum*scale;
}
float waveAt(double phase, float position, int mip, int maxHarmonics,
             const Params& p, float customScale, const TableBank& bank) noexcept {
    const float clamped = std::min(5.f,std::max(0.f,position));
    const int lower = static_cast<int>(clamped);
    const int upper = std::min(lower+1,5);
    const float mix = clamped-lower;
    auto sample=[&](int frame) noexcept -> float {
        return frame==5
            ? customWave(phase,maxHarmonics,p,customScale,bank)
            : interpolate(bank.frames[frame][mip],phase);
    };
    const float a=sample(lower);
    if (upper==lower || mix < 0.00001f) return a;
    return a+(sample(upper)-a)*mix;
}
float voiceSample(Voice& v, const Params& p, double sampleRate,
                  double bend, double detuneRatio, float wheel, float lfo,
                  float customScale, const TableBank& bank) noexcept {
    const float amplitude=v.envelope.next(
        p[SWS_PARAM_ATTACK],p[SWS_PARAM_DECAY],
        p[SWS_PARAM_SUSTAIN],p[SWS_PARAM_RELEASE],sampleRate);
    if (v.envelope.stage == Stage::idle) {
        v.active = v.held = false;
        return 0.f;
    }
    const double f1=std::min(sampleRate*0.45,v.frequency*bend);
    const double f2=std::min(sampleRate*0.45,
        v.frequency*bend*detuneRatio);
    const int mip1=mipFor(f1,sampleRate), mip2=mipFor(f2,sampleRate);
    const float movement=(v.velocity-0.5f)*2.f*p[SWS_PARAM_VELOCITY_POSITION]+
                         wheel*p[SWS_PARAM_MODWHEEL_POSITION]+lfo;
    const float pos1=p[SWS_PARAM_OSC1_POSITION]+movement;
    const float pos2=p[SWS_PARAM_OSC2_POSITION]+movement;
    float sample=0.f;
    if (p[SWS_PARAM_OSC1_LEVEL] > 0.f)
        sample += waveAt(v.phase1,pos1,mip1,1<<mip1,p,customScale,bank)
                  *p[SWS_PARAM_OSC1_LEVEL];
    if (p[SWS_PARAM_OSC2_LEVEL] > 0.f)
        sample += waveAt(v.phase2,pos2,mip2,1<<mip2,p,customScale,bank)
                  *p[SWS_PARAM_OSC2_LEVEL];
    v.phase1 += f1/sampleRate;
    v.phase2 += f2/sampleRate;
    if(v.phase1>=1.0) v.phase1-=std::floor(v.phase1);
    if(v.phase2>=1.0) v.phase2-=std::floor(v.phase2);
    return sample*amplitude*v.velocity;
}
} // namespace

extern "C" {
SWSynth* sws_create(double sr, int32_t voices) {
    if(!std::isfinite(sr) || sr<8000 || sr>384000 ||
       voices<1 || voices>kMaxVoices) return nullptr;
    const TableBank& bank=sharedBank();
    return new(std::nothrow) SWSynth(sr,voices,bank);
}
void sws_destroy(SWSynth* s) {delete s;}
int32_t sws_set_parameter(SWSynth* s,int32_t id,float value) {
    if(!s || !validParameter(id,value)) return 0;
    s->parameters[static_cast<size_t>(id)].store(value,
                                                  std::memory_order_relaxed);
    return 1;
}
float sws_get_parameter(const SWSynth* s,int32_t id) {
    if(!s || id<0 || id>=SWS_PARAMETER_COUNT) return 0.f;
    return s->parameters[static_cast<size_t>(id)].load(
        std::memory_order_relaxed);
}
int32_t sws_midi_event(SWSynth* s,uint8_t status,uint8_t d1,uint8_t d2,
                       uint32_t offset) {
    if(!s || d1>127 || d2>127 || offset>65535) return 0;
    EventType type;
    switch(status & 0xf0) {
        case 0x80: type=EventType::noteOff;break;
        case 0x90: type=d2==0?EventType::noteOff:EventType::noteOn;break;
        case 0xb0:
            if(d1!=1 && d1!=64 && d1!=120 && d1!=123) return 0;
            type=EventType::cc;break;
        case 0xe0: type=EventType::bend;break;
        default: return 0;
    }
    return s->queue.push({type,uint8_t(status&0xf),d1,d2,offset})?1:0;
}
int32_t sws_note_on(SWSynth* s,uint8_t note,uint8_t velocity) {
    return sws_midi_event(s,0x90,note,velocity,0);
}
int32_t sws_note_off(SWSynth* s,uint8_t note) {
    return sws_midi_event(s,0x80,note,0,0);
}
int32_t sws_all_notes_off(SWSynth* s) {
    if(!s) return 0;
    s->panic.store(true,std::memory_order_release);
    return 1;
}
void sws_reset_stopped(SWSynth* s) {
    if(!s) return;
    s->queue.resetStopped();
    s->panic.store(false,std::memory_order_relaxed);
    s->reset();
}
void sws_render(SWSynth* s,float* left,float* right,int32_t frames) {
    if(!s || !left || !right || frames<=0) return;
    Params target{};
    for(size_t i=0;i<target.p.size();++i)
        target.p[i]=s->parameters[i].load(std::memory_order_relaxed);

    Event incoming{};
    if(s->panic.exchange(false,std::memory_order_acq_rel)) {
        while(s->queue.pop(incoming)) {}
        s->reset();
    } else {
        while(s->pendingCount<kQueueCapacity && s->queue.pop(incoming)) {
            uint32_t index=s->pendingCount++;
            while(index>0 && s->pending[index-1].offset>incoming.offset) {
                s->pending[index]=s->pending[index-1];
                --index;
            }
            s->pending[index]=incoming;
        }
    }
    bool sounding=false;
    for(int i=0;i<s->voices;++i) if(s->voice[i].active) {sounding=true;break;}
    constexpr std::array<int, 10> kSmoothed{
        SWS_PARAM_OSC1_POSITION,SWS_PARAM_OSC2_POSITION,
        SWS_PARAM_OSC1_LEVEL,SWS_PARAM_OSC2_LEVEL,
        SWS_PARAM_OSC2_DETUNE,SWS_PARAM_OUTPUT_GAIN,
        SWS_PARAM_LFO_RATE,SWS_PARAM_LFO_DEPTH,
        SWS_PARAM_VELOCITY_POSITION,SWS_PARAM_MODWHEEL_POSITION
    };
    if(!sounding) {
        for(int id:kSmoothed) s->smoothed[id]=target[id];
        for(int i=0;i<kPartialCount;++i)
            s->smoothed[SWS_PARAM_PARTIAL_BASE+i]=target[SWS_PARAM_PARTIAL_BASE+i];
    }
    constexpr double kTime=0.012;
    const float slew=static_cast<float>(1.0-
        std::exp(-1.0/(kTime*s->sampleRate)));
    Params active=target;
    uint32_t cursor=0;
    std::array<double,16> bends{};
    auto bendRatio=[&](int ch) noexcept {
        const double amount=double(int(s->bend[ch])-8192);
        const double normalized=amount/(amount>=0.0?8191.0:8192.0);
        return std::exp2(normalized*target[SWS_PARAM_BEND_RANGE]/12.0);
    };
    for(int ch=0;ch<16;++ch)bends[ch]=bendRatio(ch);

    double detuneRatio=std::exp2(double(s->smoothed[SWS_PARAM_OSC2_DETUNE])/12.0);
    for(int32_t frame=0;frame<frames;++frame) {
        while(cursor<s->pendingCount &&
              s->pending[cursor].offset<=uint32_t(frame)) {
            const Event e=s->pending[cursor++];
            s->event(e);
            if(e.type==EventType::bend) bends[e.channel]=bendRatio(e.channel);
        }
        for(int id:kSmoothed) {
            float& value=s->smoothed[id];
            value+=slew*(target[id]-value);
            active.p[id]=value;
        }
        for(int i=0;i<kPartialCount;++i) {
            const int id=SWS_PARAM_PARTIAL_BASE+i;
            float& value=s->smoothed[id];
            value+=slew*(target[id]-value);
            active.p[id]=value;
        }
        float sumPartials=0.f;
        for(int i=0;i<kPartialCount;++i)
            sumPartials+=std::abs(active[SWS_PARAM_PARTIAL_BASE+i]);
        const float customScale=1.f/std::max(1.f,sumPartials);
        const float lfo=std::sin(kTau*s->lfoPhase)*active[SWS_PARAM_LFO_DEPTH];
        s->lfoPhase+=active[SWS_PARAM_LFO_RATE]/s->sampleRate;
        if(s->lfoPhase>=1.0) s->lfoPhase-=1.0;

        // Detuning changes are already smoothed; updating the ratio every
        // 16 frames avoids expensive exp2 once per voice per audio sample.
        if((frame & 15)==0)
            detuneRatio=std::exp2(double(active[SWS_PARAM_OSC2_DETUNE])/12.0);
        std::array<bool,16> ready{};
        float sum=0.f;
        for(int i=0;i<s->voices;++i) {
            Voice& voice=s->voice[i];
            if(!voice.active)continue;
            const uint8_t ch=voice.channel;
            if(!ready[ch]) {
                ready[ch]=true;
                const float desired=s->wheel[ch]/127.f;
                s->smoothWheel[ch]+=slew*(desired-s->smoothWheel[ch]);
            }
            sum+=voiceSample(voice,active,s->sampleRate,bends[ch],
                             detuneRatio,s->smoothWheel[ch],lfo,
                             customScale,*s->bank);
        }
        const float output=std::tanh(sum*active[SWS_PARAM_OUTPUT_GAIN]);
        left[frame]=output;right[frame]=output;
    }
    for(uint32_t i=cursor;i<s->pendingCount;++i) {
        Event e=s->pending[i];
        e.offset-=uint32_t(frames);
        s->pending[i-cursor]=e;
    }
    s->pendingCount-=cursor;
}
}
