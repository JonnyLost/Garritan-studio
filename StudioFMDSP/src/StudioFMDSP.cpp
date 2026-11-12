#include "StudioFMDSP.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <new>

namespace {
constexpr double kPi2 = 6.283185307179586476925286766559;
constexpr int kMaxVoices = 16;
constexpr uint32_t kQueueCapacity = 256;
constexpr int kOpStride = 6;

constexpr std::array<float, SFM_PARAMETER_COUNT> kDefaults{
    0.f, 0.f, 0.65f, 2.f,
    1.f, 0.8f, 0.005f, 0.25f, 0.75f, 0.22f,
    2.f, 0.30f, 0.005f, 0.28f, 0.64f, 0.18f,
    3.f, 0.14f, 0.005f, 0.20f, 0.55f, 0.17f,
    4.f, 0.00f, 0.005f, 0.18f, 0.55f, 0.13f,
    0.f, 0.f, 0.5f, 5.f
};
bool validParameter(int32_t id, float value) noexcept {
    if (id < 0 || id >= SFM_PARAMETER_COUNT || !std::isfinite(value)) return false;
    switch (id) {
        case SFM_PARAM_ALGORITHM:
            return value >= 0.f && value <= 3.f && std::floor(value) == value;
        case SFM_PARAM_FEEDBACK: case SFM_PARAM_OUTPUT_GAIN:
        case SFM_PARAM_VELOCITY_BRIGHTNESS: case SFM_PARAM_MOD_DEPTH:
            return value >= 0.f && value <= 1.f;
        case SFM_PARAM_MOD_TARGET:
            return value == 0.f || value == 1.f;
        case SFM_PARAM_MOD_RATE:
            return value >= 0.1f && value <= 20.f;
        case SFM_PARAM_BEND_RANGE:
            return value >= 0.f && value <= 24.f;
        default: {
            const int offset = (id - SFM_OP1_BASE) % kOpStride;
            if (offset == SFM_OP_RATIO) return value >= 0.125f && value <= 16.f;
            if (offset == SFM_OP_LEVEL || offset == SFM_OP_SUSTAIN)
                return value >= 0.f && value <= 1.f;
            return value >= 0.001f && value <= 30.f;
        }
    }
}

enum class Stage : uint8_t { idle, attack, decay, sustain, release };
struct Envelope {
    Stage stage = Stage::idle;
    float value = 0.f;
    float releaseStart = 0.f;
    void on() noexcept {
        stage = Stage::attack;
        value = 0.f;
        releaseStart = 0.f;
    }
    void off() noexcept {
        if (stage == Stage::idle || stage == Stage::release) return;
        stage = Stage::release;
        releaseStart = value;
    }
    void reset() noexcept {
        stage = Stage::idle;
        value = 0.f;
        releaseStart = 0.f;
    }
    float next(float attack, float decay, float sustain, float release,
               double sampleRate) noexcept {
        switch (stage) {
            case Stage::idle: value = 0.f; break;
            case Stage::attack:
                value += static_cast<float>(1.0 / std::max(1.0, double(attack) * sampleRate));
                if (value >= 1.f) { value = 1.f; stage = Stage::decay; }
                break;
            case Stage::decay:
                value -= static_cast<float>((1.0 - double(sustain)) /
                                           std::max(1.0, double(decay) * sampleRate));
                if (value <= sustain) { value = sustain; stage = Stage::sustain; }
                break;
            case Stage::sustain: value = sustain; break;
            case Stage::release:
                value -= static_cast<float>(double(releaseStart) /
                                           std::max(1.0, double(release) * sampleRate));
                if (value <= 0.f) reset();
                break;
        }
        return value;
    }
};
struct Parameters {
    std::array<float, SFM_PARAMETER_COUNT> p{};
    float operator[](int index) const noexcept {
        return p[static_cast<size_t>(index)];
    }
    float op(int n, int field) const noexcept {
        return p[static_cast<size_t>(SFM_OP1_BASE + n*kOpStride + field)];
    }
};

struct Voice {
    bool active = false;
    bool held = false;
    uint8_t channel = 0;
    uint8_t note = 0;
    uint64_t age = 0;
    float velocity = 0.f;
    double frequency = 0.0;
    std::array<double, SFM_OPERATOR_COUNT> phase{};
    std::array<Envelope, SFM_OPERATOR_COUNT> envelopes{};
    float feedbackLast = 0.f;

    void trigger(uint8_t n, uint8_t v, uint8_t ch, uint64_t order) noexcept {
        active = true;
        held = true;
        note = n;
        channel = ch;
        age = order;
        velocity = v / 127.f;
        frequency = 440.0 * std::exp2((int(n) - 69) / 12.0);
        phase.fill(0.0);
        feedbackLast = 0.f;
        for (Envelope& env : envelopes) env.on();
    }
    void release() noexcept {
        held = false;
        for (Envelope& env : envelopes) env.off();
    }
    void hardStop() noexcept {
        active = false;
        held = false;
        feedbackLast = 0.f;
        for (Envelope& env : envelopes) env.reset();
    }

    float sample(const Parameters& p, double sampleRate, double bendRatio,
                 float modWheel) noexcept {
        std::array<float, SFM_OPERATOR_COUNT> output{};
        const int algorithm = static_cast<int>(p[SFM_PARAM_ALGORITHM]);
        for (int op = SFM_OPERATOR_COUNT - 1; op >= 0; --op) {
            const float envelope = envelopes[op].next(
                p.op(op, SFM_OP_ATTACK), p.op(op, SFM_OP_DECAY),
                p.op(op, SFM_OP_SUSTAIN), p.op(op, SFM_OP_RELEASE), sampleRate);
            float modulation = 0.f;
            if (op == 3) {
                modulation = feedbackLast * (p[SFM_PARAM_FEEDBACK] * 4.f);
            } else if (algorithm == 0) {
                modulation = output[op+1] * 5.f;
            } else if (algorithm == 1) {
                modulation = op == 2 ? output[3]*5.f :
                             op == 0 ? output[1]*5.f : 0.f;
            } else if (algorithm == 2 && op == 0) {
                modulation = (output[1] + output[2] + output[3])*5.f;
            }
            const double rate = std::min(sampleRate * 0.45,
                frequency * bendRatio * double(p.op(op, SFM_OP_RATIO)));
            float level = p.op(op, SFM_OP_LEVEL);
            const bool isModulator = op > 0 && algorithm != 3 &&
                                     (algorithm != 1 || op == 1 || op == 3);
            if (isModulator) {
                // Less-energetic playing produces a softer FM index.
                const float velocityResponse =
                    1.f - p[SFM_PARAM_VELOCITY_BRIGHTNESS] * (1.f - velocity);
                const float wheelResponse = p[SFM_PARAM_MOD_TARGET] == 1.f
                    ? 1.f + 2.f*p[SFM_PARAM_MOD_DEPTH]*modWheel : 1.f;
                level *= velocityResponse*wheelResponse;
            }
            // A zero-level operator still advances its phase/envelope, but
            // avoids expensive trig. This matters for laptop battery life.
            if (level != 0.f && envelope != 0.f) {
                output[op] = level * envelope *
                    static_cast<float>(std::sin(kPi2 * phase[op] + modulation));
            }
            phase[op] += rate / sampleRate;
            if (phase[op] >= 1.0) phase[op] -= std::floor(phase[op]);
            if (op == 3) feedbackLast = output[3];
        }

        bool anyEnvelope = false;
        for (const Envelope& env : envelopes)
            if (env.stage != Stage::idle) anyEnvelope = true;
        if (!anyEnvelope) { active = false; held = false; }

        const float out = algorithm == 1 ? 0.5f*(output[0]+output[2]) :
                          algorithm == 3
                              ? 0.25f*(output[0]+output[1]+output[2]+output[3])
                              : output[0];
        return out*velocity;
    }
};

enum class EventType : uint8_t { noteOn, noteOff, control, bend };
struct Event {
    EventType type = EventType::noteOff;
    uint8_t channel = 0;
    uint8_t data1 = 0;
    uint8_t data2 = 0;
    uint32_t offset = 0;
};
struct Queue {
    std::array<Event, kQueueCapacity> items{};
    std::atomic<uint32_t> read{0}, write{0};
    bool push(Event e) noexcept {
        const uint32_t w = write.load(std::memory_order_relaxed);
        if (w-read.load(std::memory_order_acquire) >= kQueueCapacity) return false;
        items[w % kQueueCapacity] = e;
        write.store(w+1, std::memory_order_release);
        return true;
    }
    bool pop(Event& e) noexcept {
        const uint32_t r = read.load(std::memory_order_relaxed);
        if (r == write.load(std::memory_order_acquire)) return false;
        e = items[r % kQueueCapacity];
        read.store(r+1, std::memory_order_release);
        return true;
    }
    void resetStopped() noexcept {
        read.store(write.load(std::memory_order_relaxed), std::memory_order_relaxed);
    }
};
} // namespace

struct SFMSynth {
    double sampleRate;
    int voices;
    std::array<std::atomic<float>, SFM_PARAMETER_COUNT> parameters{};
    std::array<Voice, kMaxVoices> voice{};
    Queue queue{};
    std::array<Event, kQueueCapacity> pending{};
    uint32_t pendingCount = 0;
    std::atomic<bool> panic{false};
    std::array<bool, 16> sustain{};
    std::array<uint16_t,16> bend{};
    std::array<uint8_t,16> wheel{};
    std::array<float,16> smoothWheel{};
    std::array<double,16> wheelPhase{};
    std::array<float,SFM_PARAMETER_COUNT> smoothed{};
    uint64_t counter = 0;

    SFMSynth(double sr, int n) : sampleRate(sr), voices(n) {
        for (size_t i=0; i < kDefaults.size(); ++i)
            parameters[i].store(kDefaults[i], std::memory_order_relaxed);
        bend.fill(8192);
        smoothed = kDefaults;
    }
    void reset() noexcept {
        pendingCount = 0;
        sustain.fill(false);
        bend.fill(8192);
        wheel.fill(0);
        smoothWheel.fill(0.f);
        wheelPhase.fill(0.0);
        for (Voice& v : voice) v.hardStop();
    }
    void event(const Event& e) noexcept {
        const uint8_t ch = e.channel;
        if (e.type == EventType::control) {
            switch(e.data1) {
                case 1:
                    wheel[ch] = e.data2;
                    break;
                case 64: {
                    const bool wasPressed = sustain[ch];
                    sustain[ch] = e.data2 >= 64;
                    if (wasPressed && !sustain[ch])
                        for (int i=0;i<voices;++i) {
                            Voice& v = voice[i];
                            if (v.active && v.channel == ch && !v.held) v.release();
                        }
                    break;
                }
                case 120:
                case 123:
                    for (int i=0;i<voices;++i) {
                        Voice& v = voice[i];
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
            bend[ch] = uint16_t(e.data1) | uint16_t(uint16_t(e.data2)<<7);
            return;
        }
        if (e.type == EventType::noteOff || e.data2 == 0) {
            Voice* oldest = nullptr;
            for (int i=0;i<voices;++i) {
                Voice& v=voice[i];
                if (v.active && v.held && v.channel == ch && v.note == e.data1 &&
                    (!oldest || v.age < oldest->age)) oldest=&v;
            }
            if (oldest) {
                oldest->held = false;
                if (!sustain[ch]) oldest->release();
            }
            return;
        }
        Voice* selected = nullptr;
        for (int i=0;i<voices;++i)
            if (!voice[i].active) {selected=&voice[i]; break;}
        if (!selected)
            for (int i=0;i<voices;++i)
                if (!voice[i].held && (!selected || voice[i].age < selected->age))
                    selected=&voice[i];
        if (!selected) {
            selected=&voice[0];
            for (int i=1;i<voices;++i)
                if (voice[i].age < selected->age) selected=&voice[i];
        }
        selected->trigger(e.data1,e.data2,ch,++counter);
    }
};

extern "C" {
SFMSynth* sfm_create(double sampleRate, int32_t voices) {
    if (!std::isfinite(sampleRate) || sampleRate < 8000 || sampleRate > 384000 ||
        voices < 1 || voices > kMaxVoices) return nullptr;
    return new (std::nothrow) SFMSynth(sampleRate, voices);
}
void sfm_destroy(SFMSynth* synth) { delete synth; }

int32_t sfm_set_parameter(SFMSynth* synth, int32_t id, float value) {
    if (!synth || !validParameter(id,value)) return 0;
    synth->parameters[static_cast<size_t>(id)].store(value,std::memory_order_relaxed);
    return 1;
}
float sfm_get_parameter(const SFMSynth* synth,int32_t id) {
    if (!synth || id < 0 || id >= SFM_PARAMETER_COUNT) return 0.f;
    return synth->parameters[static_cast<size_t>(id)].load(std::memory_order_relaxed);
}
int32_t sfm_midi_event(SFMSynth* synth,uint8_t status,uint8_t d1,uint8_t d2,uint32_t offset) {
    if (!synth || d1 > 127 || d2 > 127 || offset > 65535) return 0;
    EventType type;
    switch (status & 0xF0) {
        case 0x80: type=EventType::noteOff; break;
        case 0x90: type=d2==0 ? EventType::noteOff : EventType::noteOn; break;
        case 0xB0:
            if (d1 != 1 && d1 != 64 && d1 != 120 && d1 != 123) return 0;
            type=EventType::control; break;
        case 0xE0: type=EventType::bend; break;
        default: return 0;
    }
    return synth->queue.push({type,uint8_t(status&0x0F),d1,d2,offset})?1:0;
}
int32_t sfm_note_on(SFMSynth* synth,uint8_t note,uint8_t velocity) {
    return sfm_midi_event(synth,0x90,note,velocity,0);
}
int32_t sfm_note_off(SFMSynth* synth,uint8_t note) {
    return sfm_midi_event(synth,0x80,note,0,0);
}
int32_t sfm_all_notes_off(SFMSynth* synth) {
    if (!synth) return 0;
    synth->panic.store(true,std::memory_order_release);
    return 1;
}
void sfm_reset_stopped(SFMSynth* synth) {
    if (!synth) return;
    synth->queue.resetStopped();
    synth->panic.store(false,std::memory_order_relaxed);
    synth->reset();
}
void sfm_render(SFMSynth* synth,float* left,float* right,int32_t frames) {
    if (!synth || !left || !right || frames <= 0) return;

    Parameters p{};
    for (size_t i=0;i<p.p.size();++i)
        p.p[i]=synth->parameters[i].load(std::memory_order_relaxed);

    Event incoming{};
    if (synth->panic.exchange(false,std::memory_order_acq_rel)) {
        while (synth->queue.pop(incoming)) {}
        synth->reset();
    } else {
        // Stable insertion-sort of bounded offsets once per callback.
        while (synth->pendingCount < kQueueCapacity && synth->queue.pop(incoming)) {
            uint32_t i = synth->pendingCount++;
            while (i > 0 && synth->pending[i-1].offset > incoming.offset) {
                synth->pending[i] = synth->pending[i-1];
                --i;
            }
            synth->pending[i] = incoming;
        }
    }

    std::array<double,16> bendRatios{};
    auto bendRatio=[&](int channel) noexcept {
        const double v = double(int(synth->bend[channel])-8192);
        const double normalized=v/(v>=0.0 ? 8191.0 : 8192.0);
        return std::exp2(normalized * p[SFM_PARAM_BEND_RANGE] / 12.0);
    };
    for (int ch=0;ch<16;++ch) bendRatios[ch]=bendRatio(ch);

    // Smooth only controls which would otherwise create zipper noise.
    // No allocation or locks; parameter storage remains render-thread owned.
    const float slew = static_cast<float>(1.0 -
        std::exp(-1.0 / (0.012 * synth->sampleRate)));
    constexpr std::array<int, 13> kSmoothedIDs{
        SFM_PARAM_FEEDBACK, SFM_PARAM_OUTPUT_GAIN,
        SFM_PARAM_VELOCITY_BRIGHTNESS, SFM_PARAM_MOD_DEPTH,
        SFM_OP1_BASE + SFM_OP_LEVEL, SFM_OP2_BASE + SFM_OP_LEVEL,
        SFM_OP3_BASE + SFM_OP_LEVEL, SFM_OP4_BASE + SFM_OP_LEVEL,
        SFM_OP1_BASE + SFM_OP_RATIO, SFM_OP2_BASE + SFM_OP_RATIO,
        SFM_OP3_BASE + SFM_OP_RATIO, SFM_OP4_BASE + SFM_OP_RATIO,
        SFM_PARAM_MOD_RATE
    };
    // Patch changes made while silent should not glide the NEXT note from
    // the previous patch's oscillator ratios or levels. Snap only when no
    // voice was active at the start of the audio callback.
    bool wasAudible = false;
    for (int i = 0; i < synth->voices; ++i) {
        if (synth->voice[i].active) { wasAudible = true; break; }
    }
    if (!wasAudible) {
        for (int id : kSmoothedIDs)
            synth->smoothed[static_cast<size_t>(id)] = p[id];
    }
    Parameters active = p;
    uint32_t cursor=0;
    for (int32_t frame=0;frame<frames;++frame) {
        while (cursor < synth->pendingCount &&
               synth->pending[cursor].offset <= uint32_t(frame)) {
            const Event e = synth->pending[cursor++];
            synth->event(e);
            if (e.type==EventType::bend) bendRatios[e.channel]=bendRatio(e.channel);
        }
        for (int id : kSmoothedIDs) {
            float &current = synth->smoothed[static_cast<size_t>(id)];
            current += slew*(p[id] - current);
            active.p[static_cast<size_t>(id)] = current;
        }
        // Compute at most one vibrato LFO per active MIDI channel, even
        // during polyphonic chords. CC1 is smoothed to prevent abrupt steps.
        std::array<double,16> channelRatio{};
        std::array<bool,16> channelReady{};
        float mix=0.f;
        for (int i=0;i<synth->voices;++i) {
            Voice& v=synth->voice[i];
            if (!v.active) continue;
            const uint8_t ch = v.channel;
            if (!channelReady[ch]) {
                channelReady[ch] = true;
                const float target = synth->wheel[ch] / 127.f;
                float &amount = synth->smoothWheel[ch];
                amount += slew * (target - amount);
                double vibrato = 1.0;
                if (p[SFM_PARAM_MOD_TARGET] == 0.f && amount > 0.00001f) {
                    const double semitones = 2.0 *
                        active[SFM_PARAM_MOD_DEPTH] * amount *
                        std::sin(kPi2*synth->wheelPhase[ch]);
                    vibrato = std::exp2(semitones/12.0);
                }
                synth->wheelPhase[ch] += active[SFM_PARAM_MOD_RATE]/synth->sampleRate;
                if (synth->wheelPhase[ch] >= 1.0)
                    synth->wheelPhase[ch] -= 1.0;
                channelRatio[ch] = bendRatios[ch]*vibrato;
            }
            mix += v.sample(active,synth->sampleRate,channelRatio[ch],
                            synth->smoothWheel[ch]);
        }
        const float out=std::tanh(mix*active[SFM_PARAM_OUTPUT_GAIN]);
        left[frame]=out;
        right[frame]=out;
    }
    // Retain only future offsets, relative to the start of the next callback.
    for (uint32_t i=cursor;i<synth->pendingCount;++i) {
        Event e=synth->pending[i];
        e.offset-=uint32_t(frames);
        synth->pending[i-cursor]=e;
    }
    synth->pendingCount-=cursor;
}
}
