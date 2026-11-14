#include "StudioAnalogDSP.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <new>
#include <vector>

namespace {
constexpr int kNodeCount = 10;
constexpr int kPorts = 3;
constexpr int kMaxVoices = 16;
constexpr int kMaxRoutes = 24;
constexpr int kQueueCapacity = 256;
constexpr size_t kMaxSequenceEvents = 65536;
constexpr double kPi = 3.14159265358979323846;

float clampf(float x, float lo, float hi) noexcept {
    return std::max(lo, std::min(hi, x));
}

struct Parameters {
    std::array<float, SA_PARAMETER_COUNT> values{};
    double osc2Ratio = 1.0;
    float operator[](int i) const noexcept { return values[static_cast<size_t>(i)]; }
};

constexpr std::array<float, SA_PARAMETER_COUNT> kDefaults = {
    2.f, 3.f, 0.48f, 0.28f, 0.f, 0.f, 6500.f, 0.18f, 0.4f,
    0.01f, 0.25f, 0.5f, 0.3f, 0.005f, 0.18f, 0.75f, 0.25f,
    4.f, 0.f, 0.45f, 0.5f, 2.f, 0.5f, 0.f, 0.f
};

bool validParameter(int32_t id, float value) noexcept {
    if (id < 0 || id >= SA_PARAMETER_COUNT || !std::isfinite(value)) return false;
    switch (id) {
        case SA_PARAM_OSC1_WAVE: case SA_PARAM_OSC2_WAVE:
            return value >= 0.f && value <= 3.f && std::floor(value) == value;
        case SA_PARAM_MOD_TARGET:
            return value == 0.f || value == 1.f;
        case SA_PARAM_BEND_RANGE:
            return value >= 0.f && value <= 24.f;
        case SA_PARAM_MOD_DEPTH: case SA_PARAM_VELOCITY_FILTER:
            return value >= 0.f && value <= 1.f;
        case SA_PARAM_OSC1_LEVEL: case SA_PARAM_OSC2_LEVEL:
        case SA_PARAM_NOISE_LEVEL: case SA_PARAM_RESONANCE:
        case SA_PARAM_FILTER_SUSTAIN: case SA_PARAM_AMP_SUSTAIN:
        case SA_PARAM_FILTER_ENV_DEPTH: case SA_PARAM_LFO_DEPTH:
        case SA_PARAM_MASTER_GAIN:
            return value >= 0.f && value <= 1.f;
        case SA_PARAM_PULSE_WIDTH:
            return value >= 0.05f && value <= 0.95f;
        case SA_PARAM_OSC2_SEMITONES:
            return value >= -24.f && value <= 24.f;
        case SA_PARAM_CUTOFF_HZ:
            return value >= 20.f && value <= 20000.f;
        case SA_PARAM_LFO_RATE:
            return value >= 0.01f && value <= 40.f;
        default:
            return value >= 0.f && value <= 30.f;
    }
}

bool isControl(int node) noexcept {
    return node == SA_NODE_FILTER_ENV || node == SA_NODE_LFO ||
           node == SA_NODE_AMP_ENV;
}

int destinationPortType(int node, int port) noexcept {
    if (node == SA_NODE_MIXER && port >= 0 && port <= 2) return 0;
    if (node == SA_NODE_FILTER && port == 0) return 0;
    if (node == SA_NODE_FILTER && (port == 1 || port == 2)) return 1;
    if (node == SA_NODE_VCA && port == 0) return 0;
    if (node == SA_NODE_VCA && port == 1) return 1;
    if (node == SA_NODE_OUTPUT && port == 0) return 0;
    return -1;
}

struct Input {
    int8_t source = -1;
    float gain = 1.f;
};

struct Graph {
    std::array<std::array<Input, kPorts>, kNodeCount> inputs{};
    std::array<uint8_t, kNodeCount> order{};

    bool compile(const SARoute *routes, size_t count) noexcept {
        if (!routes || count == 0 || count > kMaxRoutes) return false;
        Graph next;
        for (size_t i = 0; i < count; ++i) {
            const SARoute& route = routes[i];
            const int src = route.source;
            const int dst = route.destination;
            const int port = route.destinationInput;
            if (src >= kNodeCount || dst >= kNodeCount || port >= kPorts ||
                !std::isfinite(route.gain) || std::abs(route.gain) > 4.f ||
                destinationPortType(dst, port) != (isControl(src) ? 1 : 0) ||
                next.inputs[dst][port].source >= 0) {
                return false;
            }
            next.inputs[dst][port] = {static_cast<int8_t>(src), route.gain};
        }
        if (next.inputs[SA_NODE_OUTPUT][0].source < 0 ||
            next.inputs[SA_NODE_VCA][0].source < 0) return false;

        // Topological sort, executed once when loading a patch; never in audio.
        std::array<int, kNodeCount> degree{};
        for (int dst = 0; dst < kNodeCount; ++dst)
            for (const Input& in : next.inputs[dst])
                if (in.source >= 0) ++degree[dst];

        std::array<bool, kNodeCount> used{};
        for (int step = 0; step < kNodeCount; ++step) {
            int candidate = -1;
            for (int i = 0; i < kNodeCount; ++i) {
                if (!used[i] && degree[i] == 0) { candidate = i; break; }
            }
            if (candidate < 0) return false; // Cycle.
            used[candidate] = true;
            next.order[step] = static_cast<uint8_t>(candidate);
            for (int dst = 0; dst < kNodeCount; ++dst)
                for (const Input& in : next.inputs[dst])
                    if (in.source == candidate) --degree[dst];
        }
        *this = next;
        return true;
    }
};

constexpr std::array<SARoute, 9> kDefaultRoutes{{
    {SA_NODE_OSC1, SA_NODE_MIXER, 0, 1.f},
    {SA_NODE_OSC2, SA_NODE_MIXER, 1, 1.f},
    {SA_NODE_NOISE, SA_NODE_MIXER, 2, 1.f},
    {SA_NODE_MIXER, SA_NODE_FILTER, 0, 1.f},
    {SA_NODE_FILTER_ENV, SA_NODE_FILTER, 1, 1.f},
    {SA_NODE_LFO, SA_NODE_FILTER, 2, 1.f},
    {SA_NODE_FILTER, SA_NODE_VCA, 0, 1.f},
    {SA_NODE_AMP_ENV, SA_NODE_VCA, 1, 1.f},
    {SA_NODE_VCA, SA_NODE_OUTPUT, 0, 1.f}
}};

// Antialias discontinuities in saw and pulse oscillators.
double polyBlep(double t, double dt) noexcept {
    if (t < dt) {
        t /= dt;
        return t + t - t*t - 1.0;
    }
    if (t > 1.0 - dt) {
        t = (t - 1.0) / dt;
        return t*t + t + t + 1.0;
    }
    return 0.0;
}

struct Oscillator {
    double phase = 0.0;
    float next(double frequency, int waveform, double width, double sr) noexcept {
        const double dt = std::min(std::max(frequency / sr, 0.0), 0.49);
        const double t = phase;
        double out = 0.0;
        switch (waveform) {
            case SA_WAVE_SINE:
                out = std::sin(2.0*kPi*t); break;
            case SA_WAVE_TRIANGLE:
                out = 1.0 - 4.0*std::abs(t - 0.5); break;
            case SA_WAVE_PULSE: {
                const double shifted = t >= width ? t-width : t+1.0-width;
                out = (t < width ? 1.0 : -1.0)
                    + polyBlep(t, dt) - polyBlep(shifted, dt);
                break;
            }
            default:
                out = 2.0*t - 1.0 - polyBlep(t, dt); break;
        }
        phase += dt;
        if (phase >= 1.0) phase -= 1.0;
        return static_cast<float>(out);
    }
};

struct Envelope {
    enum class Stage : uint8_t { idle, attack, decay, sustain, release };
    Stage stage = Stage::idle;
    float value = 0.f;
    float releaseStart = 0.f;

    void trigger() noexcept { stage = Stage::attack; value = 0.f; }
    void noteOff() noexcept {
        if (stage != Stage::idle) {
            releaseStart = value;
            stage = Stage::release;
        }
    }
    float next(double sampleRate, float a, float d, float s, float r) noexcept {
        switch (stage) {
            case Stage::idle: return 0.f;
            case Stage::attack:
                value += 1.f / static_cast<float>(std::max(1.0, double(a)*sampleRate));
                if (value >= 1.f) { value = 1.f; stage = Stage::decay; }
                break;
            case Stage::decay:
                value -= (1.f-s) / static_cast<float>(std::max(1.0, double(d)*sampleRate));
                if (value <= s) { value = s; stage = Stage::sustain; }
                break;
            case Stage::sustain: value = s; break;
            case Stage::release:
                value -= releaseStart / static_cast<float>(std::max(1.0, double(r)*sampleRate));
                if (value <= 0.f) { value = 0.f; stage = Stage::idle; }
                break;
        }
        return value;
    }
};

struct StateVariableFilter {
    double ic1 = 0.0, ic2 = 0.0;
    float next(float input, double cutoff, float resonance, double sr) noexcept {
        cutoff = std::max(20.0, std::min(cutoff, 0.45*sr));
        const double q = 0.707 + 11.0*resonance;
        const double g = std::tan(kPi*cutoff/sr);
        const double k = 1.0 / q;
        const double a1 = 1.0 / (1.0 + g*(g + k));
        const double a2 = g*a1;
        const double a3 = g*a2;
        const double v3 = input - ic2;
        const double v1 = a1*ic1 + a2*v3;
        const double v2 = ic2 + a2*ic1 + a3*v3;
        ic1 = 2.0*v1 - ic1;
        ic2 = 2.0*v2 - ic2;
        // Cut off denormals on nearly-silent tails.
        if (std::abs(ic1) < 1e-20) ic1 = 0.0;
        if (std::abs(ic2) < 1e-20) ic2 = 0.0;
        return static_cast<float>(v2);
    }
};

struct Voice {
    bool active = false;
    bool held = false;
    uint8_t channel = 0;
    uint8_t note = 0;
    float velocity = 0.f;
    double baseFrequency = 440.0;
    uint64_t age = 0;
    uint32_t noise = 0x9e3779b9u;
    double lfoPhase = 0.0;
    Oscillator osc1, osc2;
    StateVariableFilter filter;
    Envelope ampEnvelope, filterEnvelope;

    void trigger(uint8_t n, uint8_t v, uint8_t ch, uint64_t counter) noexcept {
        active = true;
        held = true;
        channel = ch;
        note = n;
        velocity = static_cast<float>(v)/127.f;
        baseFrequency = 440.0*std::pow(2.0, (static_cast<int>(n)-69)/12.0);
        age = counter;
        osc1.phase = osc2.phase = lfoPhase = 0.0;
        filter = {};
        ampEnvelope.trigger();
        filterEnvelope.trigger();
    }
    void release() noexcept {
        held = false;
        ampEnvelope.noteOff();
        filterEnvelope.noteOff();
    }
    void stopImmediately() noexcept {
        held = false;
        active = false;
        ampEnvelope = {};
        filterEnvelope = {};
    }
    float next(const Graph& graph, const Parameters& p, double sr,
               double bendRatio, float wheel) noexcept {
        std::array<float, kNodeCount> sample{};
        // LFO vibrato derives from the same phase as the user-visible LFO node.
        // It is evaluated before oscillators irrespective of graph topo order.
        const float lfo = static_cast<float>(std::sin(2.0*kPi*lfoPhase));
        const float wheelAmount = wheel * p[SA_PARAM_MOD_DEPTH];
        const bool vibrato = p[SA_PARAM_MOD_TARGET] == 0.f && wheelAmount > 0.f;
        const double vibratoRatio = vibrato
            ? std::exp2(2.0 * wheelAmount * lfo / 12.0) : 1.0;
        const double frequency = baseFrequency * bendRatio * vibratoRatio;
        auto input = [&](int node, int port) noexcept -> float {
            const Input& jack = graph.inputs[node][port];
            return jack.source < 0 ? 0.f : sample[static_cast<size_t>(jack.source)]*jack.gain;
        };
        for (uint8_t id : graph.order) {
            switch (id) {
                case SA_NODE_OSC1:
                    sample[id] = osc1.next(frequency, static_cast<int>(p[SA_PARAM_OSC1_WAVE]),
                                           p[SA_PARAM_PULSE_WIDTH], sr)*p[SA_PARAM_OSC1_LEVEL];
                    break;
                case SA_NODE_OSC2:
                    sample[id] = osc2.next(frequency*p.osc2Ratio,
                                           static_cast<int>(p[SA_PARAM_OSC2_WAVE]),
                                           p[SA_PARAM_PULSE_WIDTH], sr)*p[SA_PARAM_OSC2_LEVEL];
                    break;
                case SA_NODE_NOISE:
                    noise ^= noise << 13; noise ^= noise >> 17; noise ^= noise << 5;
                    sample[id] = (static_cast<float>((noise >> 8) & 0xFFFFFFu)
                                  /8388608.f-1.f)*p[SA_PARAM_NOISE_LEVEL];
                    break;
                case SA_NODE_MIXER:
                    sample[id] = input(id, 0) + input(id, 1) + input(id, 2);
                    break;
                case SA_NODE_FILTER_ENV:
                    sample[id] = filterEnvelope.next(sr, p[SA_PARAM_FILTER_ATTACK],
                        p[SA_PARAM_FILTER_DECAY], p[SA_PARAM_FILTER_SUSTAIN],
                        p[SA_PARAM_FILTER_RELEASE]);
                    break;
                case SA_NODE_LFO:
                    sample[id] = lfo;
                    break;
                case SA_NODE_FILTER: {
                    const double wheelFilter = p[SA_PARAM_MOD_TARGET] == 1.f
                        ? 3.0*wheelAmount : 0.0;
                    const double velocityFilter = 2.0*p[SA_PARAM_VELOCITY_FILTER]
                        *(velocity - 0.5f);
                    const double octaves = 4.0*p[SA_PARAM_FILTER_ENV_DEPTH]*input(id, 1)
                                         + 2.0*p[SA_PARAM_LFO_DEPTH]*input(id, 2)
                                         + wheelFilter + velocityFilter;
                    const double cutoff = p[SA_PARAM_CUTOFF_HZ]*std::pow(2.0, octaves);
                    sample[id] = filter.next(input(id, 0), cutoff, p[SA_PARAM_RESONANCE], sr);
                    break;
                }
                case SA_NODE_AMP_ENV:
                    sample[id] = ampEnvelope.next(sr, p[SA_PARAM_AMP_ATTACK],
                        p[SA_PARAM_AMP_DECAY], p[SA_PARAM_AMP_SUSTAIN],
                        p[SA_PARAM_AMP_RELEASE]);
                    break;
                case SA_NODE_VCA:
                    sample[id] = input(id, 0)*clampf(input(id, 1), 0.f, 1.f);
                    break;
                case SA_NODE_OUTPUT:
                    sample[id] = input(id, 0); break;
                default: break;
            }
        }
        lfoPhase += p[SA_PARAM_LFO_RATE]/sr;
        if (lfoPhase >= 1.0) lfoPhase -= 1.0;
        if (ampEnvelope.stage == Envelope::Stage::idle) {
            held = false;
            active = false;
        }
        return sample[SA_NODE_OUTPUT]*velocity;
    }
};

enum class EventType : uint8_t { on, off, control, bend, panic };
struct NoteEvent {
    EventType type = EventType::off;
    uint8_t note = 0;       // Note number, CC controller, or pitch-bend LSB.
    uint8_t value = 0;      // Velocity, CC value, or pitch-bend MSB.
    uint8_t channel = 0;    // 0..15
    uint32_t frameOffset = 0;
};

struct NoteQueue {
    std::array<NoteEvent, kQueueCapacity> events{};
    std::atomic<uint32_t> write{0}, read{0};

    bool push(NoteEvent event) noexcept {
        const uint32_t w = write.load(std::memory_order_relaxed);
        if (w - read.load(std::memory_order_acquire) >= kQueueCapacity) return false;
        events[w % kQueueCapacity] = event;
        write.store(w+1, std::memory_order_release);
        return true;
    }
    bool pop(NoteEvent& event) noexcept {
        const uint32_t r = read.load(std::memory_order_relaxed);
        if (r == write.load(std::memory_order_acquire)) return false;
        event = events[r % kQueueCapacity];
        read.store(r+1, std::memory_order_release);
        return true;
    }
    void resetStopped() noexcept {
        read.store(write.load(std::memory_order_relaxed), std::memory_order_relaxed);
    }
};
} // namespace

struct SASynth {
    double sampleRate;
    int voiceCount;
    // Three preallocated immutable graph slots: one consumed by the render
    // block, one pending publication, one free for the control thread.
    // The control thread never edits current or pending; the audio thread
    // advances current only at a block boundary, before accessing the slot.
    std::array<Graph, 3> graphs{};
    std::atomic<uint8_t> currentGraph{0};
    std::atomic<uint8_t> requestedGraph{0};
    std::array<Voice, kMaxVoices> voices{};
    std::array<std::atomic<float>, SA_PARAMETER_COUNT> params{};
    NoteQueue notes;
    // High-priority stop cannot be blocked by a full MIDI queue.
    std::atomic<bool> panicRequested{false};
    // Bounded, preallocated render-thread timeline, stable insertion order
    // for events sharing the same frame. No sorting or allocation in render.
    std::array<NoteEvent, kQueueCapacity> pending{};
    uint32_t pendingCount = 0;
    // Three preallocated identities with control-thread-owned vector storage.
    // Sequence vectors are never resized or deallocated by the render thread.
    std::array<std::vector<SAScheduledMIDI>, 3> sequences{};
    std::atomic<uint8_t> currentSequence{0}, requestedSequence{0};
    std::atomic<bool> sequenceBegin{false}, sequenceEnd{false};
    std::atomic<bool> sequencePlaying{false};
    bool sequenceActive = false;
    size_t sequenceCursor = 0;
    uint64_t sequenceFrame = 0;
    std::array<bool, 16> pedal{};
    std::array<uint8_t, 16> modWheel{};
    std::array<uint16_t, 16> bend{};
    uint64_t counter = 0;

    SASynth(double sr, int count) : sampleRate(sr), voiceCount(count) {
        for (size_t i = 0; i < kDefaults.size(); ++i)
            params[i].store(kDefaults[i], std::memory_order_relaxed);
        graphs[0].compile(kDefaultRoutes.data(), kDefaultRoutes.size());
        bend.fill(8192);
        for (int i = 0; i < kMaxVoices; ++i)
            voices[i].noise += static_cast<uint32_t>(0x85ebca6bu*i);
    }

    void releaseChannel(uint8_t ch, bool hard) noexcept {
        for (int i = 0; i < voiceCount; ++i) {
            if (!voices[i].active || voices[i].channel != ch) continue;
            if (hard) voices[i].stopImmediately();
            else voices[i].release();
        }
    }

    void event(NoteEvent e) noexcept {
        if (e.type == EventType::panic) {
            for (int i = 0; i < voiceCount; ++i) voices[i].stopImmediately();
            pedal.fill(false);
            modWheel.fill(0);
            bend.fill(8192);
            return;
        }
        const uint8_t ch = e.channel;
        if (e.type == EventType::control) {
            switch (e.note) {
                case 1: modWheel[ch] = e.value; break;
                case 64: {
                    const bool wasDown = pedal[ch];
                    pedal[ch] = e.value >= 64;
                    if (wasDown && !pedal[ch]) {
                        for (int i = 0; i < voiceCount; ++i) {
                            Voice& voice = voices[i];
                            if (voice.active && voice.channel == ch && !voice.held)
                                voice.release();
                        }
                    }
                    break;
                }
                case 120: releaseChannel(ch, true); break; // All sound off.
                case 123: releaseChannel(ch, false); break; // All notes off.
                default: break;
            }
            return;
        }
        if (e.type == EventType::bend) {
            bend[ch] = static_cast<uint16_t>(e.note | (uint16_t(e.value) << 7));
            return;
        }
        if (e.type == EventType::off || e.value == 0) {
            // FIFO matching of overlapping same-pitch note-ons: one note-off
            // releases one oldest held voice rather than all voices of pitch.
            Voice *oldest = nullptr;
            for (int i = 0; i < voiceCount; ++i) {
                Voice& voice = voices[i];
                if (voice.active && voice.held && voice.channel == ch &&
                    voice.note == e.note && (!oldest || voice.age < oldest->age))
                    oldest = &voice;
            }
            if (oldest) {
                oldest->held = false;
                if (!pedal[ch]) oldest->release();
            }
            return;
        }
        Voice *candidate = nullptr;
        for (int i = 0; i < voiceCount; ++i) {
            if (!voices[i].active) { candidate = &voices[i]; break; }
        }
        if (!candidate) {
            for (int i = 0; i < voiceCount; ++i)
                if (!voices[i].held &&
                    (!candidate || voices[i].age < candidate->age))
                    candidate = &voices[i];
        }
        if (!candidate) {
            candidate = &voices[0];
            for (int i = 1; i < voiceCount; ++i)
                if (voices[i].age < candidate->age) candidate = &voices[i];
        }
        candidate->trigger(e.note, e.value, ch, ++counter);
    }

};

extern "C" {
SASynth *sa_create(double sampleRate, int32_t voices) {
    if (!std::isfinite(sampleRate) || sampleRate < 8000.0 || sampleRate > 384000.0 ||
        voices < 1 || voices > kMaxVoices) return nullptr;
    return new (std::nothrow) SASynth(sampleRate, voices);
}

void sa_destroy(SASynth *synth) { delete synth; }

int32_t sa_set_parameter(SASynth *synth, int32_t parameter, float value) {
    if (!synth || !validParameter(parameter, value)) return 0;
    synth->params[static_cast<size_t>(parameter)].store(value, std::memory_order_relaxed);
    return 1;
}

float sa_get_parameter(const SASynth *synth, int32_t parameter) {
    if (!synth || parameter < 0 || parameter >= SA_PARAMETER_COUNT) return 0.f;
    return synth->params[static_cast<size_t>(parameter)].load(std::memory_order_relaxed);
}

int32_t sa_midi_event(SASynth *synth, uint8_t status,
                      uint8_t data1, uint8_t data2, uint32_t frameOffset) {
    if (!synth || data1 > 127 || data2 > 127 || frameOffset > 65535) return 0;
    const uint8_t type = status & 0xF0;
    const uint8_t channel = status & 0x0F;
    EventType eventType;
    switch (type) {
        case 0x80: eventType = EventType::off; break;
        case 0x90: eventType = data2 ? EventType::on : EventType::off; break;
        case 0xB0:
            if (data1 != 1 && data1 != 64 && data1 != 120 && data1 != 123) return 0;
            eventType = EventType::control; break;
        case 0xE0: eventType = EventType::bend; break;
        default: return 0;
    }
    return synth->notes.push({eventType, data1, data2, channel, frameOffset}) ? 1 : 0;
}

int32_t sa_note_on(SASynth *synth, uint8_t note, uint8_t velocity) {
    return sa_midi_event(synth, 0x90, note, velocity, 0);
}

int32_t sa_note_off(SASynth *synth, uint8_t note) {
    return sa_midi_event(synth, 0x80, note, 0, 0);
}

int32_t sa_all_notes_off(SASynth *synth) {
    if (!synth) return 0;
    synth->panicRequested.store(true, std::memory_order_release);
    return 1;
}

void sa_reset_midi_stopped(SASynth *synth) {
    if (!synth) return;
    synth->notes.resetStopped();
    synth->panicRequested.store(false, std::memory_order_relaxed);
    synth->pendingCount = 0;
    synth->pedal.fill(false);
    synth->modWheel.fill(0);
    synth->bend.fill(8192);
    for (int i = 0; i < synth->voiceCount; ++i)
        synth->voices[i].stopImmediately();
}

int32_t sa_sequence_load(SASynth *synth, const SAScheduledMIDI *events, size_t count) {
    if (!synth || count > kMaxSequenceEvents || (count && !events) ||
        (synth->sequencePlaying.load(std::memory_order_acquire) &&
         !synth->sequenceEnd.load(std::memory_order_acquire))) return 0;
    const uint8_t current = synth->currentSequence.load(std::memory_order_acquire);
    const uint8_t requested = synth->requestedSequence.load(std::memory_order_acquire);
    if (current != requested) return -1;
    uint64_t previous = 0;
    for (size_t i = 0; i < count; ++i) {
        const SAScheduledMIDI& e = events[i];
        if (e.data1 > 127 || e.data2 > 127 ||
            (i > 0 && e.sampleFrame < previous)) return 0;
        previous = e.sampleFrame;
        const uint8_t status = e.status & 0xF0;
        if (status == 0xB0 &&
            e.data1 != 1 && e.data1 != 64 &&
            e.data1 != 120 && e.data1 != 123) return 0;
        if (status != 0x80 && status != 0x90 &&
            status != 0xB0 && status != 0xE0) return 0;
    }
    const uint8_t slot = static_cast<uint8_t>((current + 1) % 3);
    // Memory allocation and copying happen ONLY on the control thread.
    if (count == 0) synth->sequences[slot].clear();
    else synth->sequences[slot].assign(events, events + count);
    synth->requestedSequence.store(slot, std::memory_order_release);
    return 1;
}

int32_t sa_sequence_start(SASynth *synth) {
    if (!synth) return 0;
    // A start token is consumed by the next render buffer, resetting the
    // sequence cursor. It is independent of live note/MIDI playthrough.
    synth->sequenceBegin.store(true, std::memory_order_release);
    return 1;
}

void sa_sequence_stop(SASynth *synth) {
    if (!synth) return;
    synth->sequenceBegin.store(false, std::memory_order_release);
    synth->sequenceEnd.store(true, std::memory_order_release);
}

void sa_render(SASynth *synth, float *left, float *right, int32_t frames) {
    if (!synth || !left || !right || frames <= 0) return;
    Parameters p;
    for (int i = 0; i < SA_PARAMETER_COUNT; ++i)
        p.values[i] = synth->params[static_cast<size_t>(i)].load(std::memory_order_relaxed);
    p.osc2Ratio = std::exp2(p[SA_PARAM_OSC2_SEMITONES]/12.0);

    NoteEvent incoming{};
    if (synth->panicRequested.exchange(false, std::memory_order_acq_rel)) {
        synth->pendingCount = 0;
        while (synth->notes.pop(incoming)) { /* discard queued notes */ }
        synth->event({EventType::panic, 0, 0, 0, 0});
    } else {
        while (synth->pendingCount < kQueueCapacity && synth->notes.pop(incoming))
            synth->pending[synth->pendingCount++] = incoming;
    }

    // Render-time ownership of immutable graphs is updated only at buffer start.
    const uint8_t nextGraph = synth->requestedGraph.load(std::memory_order_acquire);
    synth->currentGraph.store(nextGraph, std::memory_order_release);
    const Graph& graph = synth->graphs[nextGraph];

    // Publish ownership before using a new immutable pre-sorted timeline.
    const uint8_t sequenceID = synth->requestedSequence.load(std::memory_order_acquire);
    synth->currentSequence.store(sequenceID, std::memory_order_release);
    const auto& timeline = synth->sequences[sequenceID];
    if (synth->sequenceEnd.exchange(false, std::memory_order_acq_rel)) {
        synth->sequenceActive = false;
        synth->sequencePlaying.store(false, std::memory_order_release);
    }
    if (synth->sequenceBegin.exchange(false, std::memory_order_acq_rel)) {
        synth->sequenceCursor = 0;
        synth->sequenceFrame = 0;
        synth->sequenceActive = true;
        synth->sequencePlaying.store(true, std::memory_order_release);
    }

    std::array<double, 16> bendRatio{};
    auto ratio = [&](int ch) noexcept {
        const double bend = static_cast<int>(synth->bend[ch]) - 8192;
        const double normalized = bend / (bend >= 0.0 ? 8191.0 : 8192.0);
        return std::exp2(normalized*p[SA_PARAM_BEND_RANGE]/12.0);
    };
    for (int ch = 0; ch < 16; ++ch) bendRatio[ch] = ratio(ch);

    for (int32_t frame = 0; frame < frames; ++frame) {
        // Complete project MIDI is pre-sorted and indexed by the synth's own
        // sample clock: no worker dispatch and no AU sampleOffset guessing.
        if (synth->sequenceActive) {
            while (synth->sequenceCursor < timeline.size() &&
                   timeline[synth->sequenceCursor].sampleFrame <= synth->sequenceFrame) {
                const SAScheduledMIDI& e = timeline[synth->sequenceCursor++];
                NoteEvent scheduled{};
                const uint8_t type = e.status & 0xF0;
                scheduled.type = type == 0x80 || (type == 0x90 && e.data2 == 0)
                    ? EventType::off : type == 0x90 ? EventType::on
                    : type == 0xB0 ? EventType::control : EventType::bend;
                scheduled.note = e.data1;
                scheduled.value = e.data2;
                scheduled.channel = e.status & 0x0F;
                synth->event(scheduled);
                if (scheduled.type == EventType::bend)
                    bendRatio[scheduled.channel] = ratio(scheduled.channel);
            }
            ++synth->sequenceFrame;
        }
        // Keep order for events at the same offset, including note-off followed
        // by note-on. All queue and bookkeeping storage was preallocated.
        for (uint32_t i = 0; i < synth->pendingCount;) {
            if (synth->pending[i].frameOffset <= static_cast<uint32_t>(frame)) {
                const NoteEvent handled = synth->pending[i];
                synth->event(handled);
                if (handled.type == EventType::bend)
                    bendRatio[handled.channel] = ratio(handled.channel);
                if (handled.type == EventType::panic) bendRatio.fill(1.0);
                for (uint32_t j = i + 1; j < synth->pendingCount; ++j)
                    synth->pending[j-1] = synth->pending[j];
                --synth->pendingCount;
            } else {
                ++i;
            }
        }
        // Pitch ratios update only on pitch-wheel events, not per sample.
        float mix = 0.f;
        for (int i = 0; i < synth->voiceCount; ++i) {
            Voice& voice = synth->voices[i];
            if (voice.active)
                mix += voice.next(graph, p, synth->sampleRate,
                    bendRatio[voice.channel],
                    synth->modWheel[voice.channel]/127.f);
        }
        const float output = std::tanh(mix*p[SA_PARAM_MASTER_GAIN]);
        left[frame] = output;
        right[frame] = output;
    }

    // Retain future events through successive buffers. Offsets are relative
    // to the NEXT block after this one, even when frameCount changes.
    for (uint32_t i = 0; i < synth->pendingCount; ++i)
        synth->pending[i].frameOffset -= static_cast<uint32_t>(frames);
}

int32_t sa_submit_patch(SASynth *synth, const SARoute *routes, size_t count) {
    if (!synth) return 0;
    // Only one control thread may call this method. If a previous update
    // has not been adopted by the audio callback, do not overwrite it.
    const uint8_t pending = synth->requestedGraph.load(std::memory_order_acquire);
    const uint8_t current = synth->currentGraph.load(std::memory_order_acquire);
    if (pending != current) return -1;
    const uint8_t freeSlot = static_cast<uint8_t>((current + 1) % 3);
    Graph compiled;
    if (!compiled.compile(routes, count)) return 0;
    synth->graphs[freeSlot] = compiled;
    synth->requestedGraph.store(freeSlot, std::memory_order_release);
    return 1;
}

int32_t sa_load_patch(SASynth *synth, const SARoute *routes, size_t count) {
    return sa_submit_patch(synth, routes, count);
}
} // extern "C"
