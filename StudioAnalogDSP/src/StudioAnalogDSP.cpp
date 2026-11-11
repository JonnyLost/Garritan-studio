#include "StudioAnalogDSP.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <new>

namespace {
constexpr int kNodeCount = 10;
constexpr int kPorts = 3;
constexpr int kMaxVoices = 16;
constexpr int kMaxRoutes = 24;
constexpr int kQueueCapacity = 256;
constexpr double kPi = 3.14159265358979323846;

float clampf(float x, float lo, float hi) noexcept {
    return std::max(lo, std::min(hi, x));
}

struct Parameters {
    std::array<float, SA_PARAMETER_COUNT> values{};
    float operator[](int i) const noexcept { return values[static_cast<size_t>(i)]; }
};

constexpr std::array<float, SA_PARAMETER_COUNT> kDefaults = {
    2.f, 3.f, 0.48f, 0.28f, 0.f, 0.f, 6500.f, 0.18f, 0.4f,
    0.01f, 0.25f, 0.5f, 0.3f, 0.005f, 0.18f, 0.75f, 0.25f,
    4.f, 0.f, 0.45f, 0.5f
};

bool validParameter(int32_t id, float value) noexcept {
    if (id < 0 || id >= SA_PARAMETER_COUNT || !std::isfinite(value)) return false;
    switch (id) {
        case SA_PARAM_OSC1_WAVE: case SA_PARAM_OSC2_WAVE:
            return value >= 0.f && value <= 3.f && std::floor(value) == value;
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

constexpr std::array<SARoute, 10> kDefaultRoutes{{
    {SA_NODE_OSC1, SA_NODE_MIXER, 0, 1.f},
    {SA_NODE_OSC2, SA_NODE_MIXER, 1, 1.f},
    {SA_NODE_NOISE, SA_NODE_MIXER, 2, 1.f},
    {SA_NODE_MIXER, SA_NODE_FILTER, 0, 1.f},
    {SA_NODE_FILTER_ENV, SA_NODE_FILTER, 1, 1.f},
    {SA_NODE_LFO, SA_NODE_FILTER, 2, 1.f},
    {SA_NODE_FILTER, SA_NODE_VCA, 0, 1.f},
    {SA_NODE_AMP_ENV, SA_NODE_VCA, 1, 1.f},
    {SA_NODE_VCA, SA_NODE_OUTPUT, 0, 1.f},
    {SA_NODE_OSC1, SA_NODE_FILTER, 0, 0.f} // Removed below in constructor.
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
    uint8_t note = 0;
    float velocity = 0.f;
    uint64_t age = 0;
    uint32_t noise = 0x9e3779b9u;
    double lfoPhase = 0.0;
    Oscillator osc1, osc2;
    StateVariableFilter filter;
    Envelope ampEnvelope, filterEnvelope;

    void trigger(uint8_t n, uint8_t v, uint64_t counter) noexcept {
        active = true;
        note = n;
        velocity = static_cast<float>(v)/127.f;
        age = counter;
        osc1.phase = osc2.phase = lfoPhase = 0.0;
        filter = {};
        ampEnvelope.trigger();
        filterEnvelope.trigger();
    }
    void release() noexcept {
        ampEnvelope.noteOff();
        filterEnvelope.noteOff();
    }
    float next(const Graph& graph, const Parameters& p, double sr) noexcept {
        std::array<float, kNodeCount> sample{};
        const double frequency = 440.0*std::pow(2.0, (static_cast<int>(note)-69)/12.0);
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
                    sample[id] = osc2.next(frequency*std::pow(2.0, p[SA_PARAM_OSC2_SEMITONES]/12.0),
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
                    sample[id] = static_cast<float>(std::sin(2.0*kPi*lfoPhase));
                    lfoPhase += p[SA_PARAM_LFO_RATE]/sr;
                    if (lfoPhase >= 1.0) lfoPhase -= 1.0;
                    break;
                case SA_NODE_FILTER: {
                    const double octaves = 4.0*p[SA_PARAM_FILTER_ENV_DEPTH]*input(id, 1)
                                         + 2.0*p[SA_PARAM_LFO_DEPTH]*input(id, 2);
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
        if (ampEnvelope.stage == Envelope::Stage::idle) active = false;
        return sample[SA_NODE_OUTPUT]*velocity;
    }
};

enum class EventType : uint8_t { on, off, panic };
struct NoteEvent {
    EventType type;
    uint8_t note;
    uint8_t velocity;
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
};
} // namespace

struct SASynth {
    double sampleRate;
    int voiceCount;
    Graph graph;
    std::array<Voice, kMaxVoices> voices{};
    std::array<std::atomic<float>, SA_PARAMETER_COUNT> params{};
    NoteQueue notes;
    uint64_t counter = 0;

    SASynth(double sr, int count) : sampleRate(sr), voiceCount(count) {
        for (size_t i = 0; i < kDefaults.size(); ++i)
            params[i].store(kDefaults[i], std::memory_order_relaxed);
        // The first nine routes form the default analog patch.
        graph.compile(kDefaultRoutes.data(), 9);
        for (int i = 0; i < kMaxVoices; ++i)
            voices[i].noise += static_cast<uint32_t>(0x85ebca6bu*i);
    }

    void event(NoteEvent e) noexcept {
        if (e.type == EventType::panic) {
            for (int i = 0; i < voiceCount; ++i) voices[i].release();
            return;
        }
        if (e.type == EventType::off || e.velocity == 0) {
            for (int i = 0; i < voiceCount; ++i)
                if (voices[i].active && voices[i].note == e.note) voices[i].release();
            return;
        }
        Voice *candidate = nullptr;
        for (int i = 0; i < voiceCount; ++i) {
            if (!voices[i].active) { candidate = &voices[i]; break; }
        }
        if (!candidate) {
            for (int i = 0; i < voiceCount; ++i)
                if (voices[i].ampEnvelope.stage == Envelope::Stage::release &&
                    (!candidate || voices[i].age < candidate->age))
                    candidate = &voices[i];
        }
        if (!candidate) {
            candidate = &voices[0];
            for (int i = 1; i < voiceCount; ++i)
                if (voices[i].age < candidate->age) candidate = &voices[i];
        }
        candidate->trigger(e.note, e.velocity, ++counter);
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

int32_t sa_note_on(SASynth *synth, uint8_t note, uint8_t velocity) {
    return synth && note <= 127 && synth->notes.push({EventType::on, note, velocity}) ? 1 : 0;
}

int32_t sa_note_off(SASynth *synth, uint8_t note) {
    return synth && note <= 127 && synth->notes.push({EventType::off, note, 0}) ? 1 : 0;
}

int32_t sa_all_notes_off(SASynth *synth) {
    return synth && synth->notes.push({EventType::panic, 0, 0}) ? 1 : 0;
}

void sa_render(SASynth *synth, float *left, float *right, int32_t frames) {
    if (!synth || !left || !right || frames <= 0) return;
    Parameters p;
    for (int i = 0; i < SA_PARAMETER_COUNT; ++i)
        p.values[i] = synth->params[static_cast<size_t>(i)].load(std::memory_order_relaxed);

    NoteEvent e{};
    while (synth->notes.pop(e)) synth->event(e);

    for (int32_t frame = 0; frame < frames; ++frame) {
        float mix = 0.f;
        for (int i = 0; i < synth->voiceCount; ++i) {
            if (synth->voices[i].active)
                mix += synth->voices[i].next(synth->graph, p, synth->sampleRate);
        }
        // Bounded, symmetric soft saturation prevents polyphonic clipping.
        const float output = std::tanh(mix*p[SA_PARAM_MASTER_GAIN]);
        left[frame] = output;
        right[frame] = output;
    }
}

int32_t sa_load_patch(SASynth *synth, const SARoute *routes, size_t count) {
    if (!synth) return 0;
    Graph compiled;
    if (!compiled.compile(routes, count)) return 0;
    synth->graph = compiled;
    return 1;
}
} // extern "C"
