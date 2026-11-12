#include "StudioSamplerDSP.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <limits>
#include <new>
#include <vector>

namespace {
constexpr uint32_t kMaxZones = 128;
constexpr uint32_t kMaxSampleFrames = 10000000; // RAM-only phase 1 safety limit
constexpr uint32_t kCommandCapacity = 1024; // one slot deliberately left empty
constexpr int kFadeFrames = 64;
constexpr float kOutputHeadroom = 0.25f;
constexpr float kHalfPi = 1.57079632679489661923f;
constexpr double kMinimumRate = 8000.0;
constexpr double kMaximumRate = 384000.0;

struct Sample {
    std::vector<float> left;
    std::vector<float> right;
    double rate = 44100.0;
    uint8_t root = 60;
    uint8_t low = 0;
    uint8_t high = 127;
    uint8_t minVelocity = 1;
    uint8_t maxVelocity = 127;
};

struct Voice {
    const Sample *sample = nullptr;
    double position = 0;
    double increment = 1;
    float gain = 0;
    uint64_t serial = 0;
    uint8_t note = 0;
    uint8_t channel = 0;
    int attackFrames = 0;
    int releaseFrames = 0;
    bool active = false;
};

enum class CommandKind : uint8_t { on, off, allOff, controller, crossfade };
struct Command {
    CommandKind kind = CommandKind::allOff;
    uint8_t note = 0;
    uint8_t velocity = 0;
    uint8_t channel = 0;
};

inline bool validRate(double rate) {
    return std::isfinite(rate) && rate >= kMinimumRate && rate <= kMaximumRate;
}

inline float readLinear(const std::vector<float>& data, double position) {
    const size_t index = static_cast<size_t>(position);
    if (index >= data.size()) return 0;
    const size_t next = std::min(index + 1, data.size() - 1);
    const float amount = static_cast<float>(position - static_cast<double>(index));
    return data[index] + (data[next] - data[index]) * amount;
}
} // namespace

struct SSSampler {
    explicit SSSampler(double rate, int voices)
        : outputRate(rate), voices(static_cast<size_t>(voices)) {
        samples.reserve(kMaxZones); // stable Sample* pointers throughout render
        smoothCC1.fill(127.f);
        smoothCC11.fill(127.f);
        targetCC1.fill(127.f);
        targetCC11.fill(127.f);
    }

    double outputRate;
    std::vector<Sample> samples;
    std::vector<Voice> voices;
    uint64_t nextSerial = 0;
    bool cc1Crossfade = false; // mutated only while consuming RT commands
    std::array<float, 16> smoothCC1{};
    std::array<float, 16> smoothCC11{};
    std::array<float, 16> targetCC1{};
    std::array<float, 16> targetCC11{};
    std::array<Command, kCommandCapacity> commands{};
    std::atomic<uint32_t> commandWrite{0};
    std::atomic<uint32_t> commandRead{0};

    bool enqueue(Command value) {
        const auto write = commandWrite.load(std::memory_order_relaxed);
        const auto next = (write + 1) % kCommandCapacity;
        if (next == commandRead.load(std::memory_order_acquire)) return false;
        commands[write] = value;
        commandWrite.store(next, std::memory_order_release);
        return true;
    }

    void startVoice(const Sample *selected, uint8_t note,
                    uint8_t velocity, uint8_t channel) {
        Voice *chosen = nullptr;
        for (auto& voice : voices) {
            if (!voice.active) { chosen = &voice; break; }
        }
        if (!chosen) {
            chosen = &*std::min_element(voices.begin(), voices.end(),
                [](const Voice& a, const Voice& b) { return a.serial < b.serial; });
        }

        // Equal-temperament pitch shift relative to recorded root key.
        const double semitones = (int(note) - int(selected->root)) / 12.0;
        const double increment = selected->rate / outputRate * std::pow(2.0, semitones);
        if (!std::isfinite(increment) || increment <= 0) return;
        *chosen = Voice{};
        chosen->sample = selected;
        chosen->note = note;
        chosen->channel = channel;
        chosen->position = 0;
        chosen->increment = increment;
        chosen->gain = float(velocity) / 127.f;
        chosen->attackFrames = kFadeFrames;
        chosen->serial = ++nextSerial;
        chosen->active = true;
    }

    // A note can activate multiple matching dynamic layers. Layers run in
    // sync from their beginnings; the smoothed CC1 controls their gains.
    void start(uint8_t note, uint8_t velocity, uint8_t channel) {
        const Sample *selected = nullptr;
        int bestDistance = std::numeric_limits<int>::max();
        for (const auto& sample : samples) {
            if (note < sample.low || note > sample.high ||
                (!cc1Crossfade &&
                 (velocity < sample.minVelocity || velocity > sample.maxVelocity))) continue;
            const int distance = std::abs(int(note) - int(sample.root));
            if (distance < bestDistance) {
                selected = &sample;
                bestDistance = distance;
            }
        }
        if (!selected) return;
        if (!cc1Crossfade) {
            startVoice(selected, note, velocity, channel);
            return;
        }
        // Pick a single root-note group, not zones belonging to neighboring
        // recorded notes. Limit layer count to avoid voice exhaustion.
        int started = 0;
        for (const auto& sample : samples) {
            if (sample.root != selected->root ||
                note < sample.low || note > sample.high) continue;
            if (started >= 8) break;
            startVoice(&sample, note, velocity, channel);
            ++started;
        }
    }

    float dynamicWeight(const Sample& current, uint8_t note, float cc1) const {
        const float center = (float(current.minVelocity) +
                              float(current.maxVelocity)) * 0.5f;
        float below = -1.f;
        float above = 129.f;
        for (const auto& zone : samples) {
            if (&zone == &current || zone.root != current.root ||
                note < zone.low || note > zone.high) continue;
            const float other = (float(zone.minVelocity) +
                                 float(zone.maxVelocity)) * 0.5f;
            if (other < center && other > below) below = other;
            if (other > center && other < above) above = other;
        }
        if (cc1 < center && below >= 0.f) {
            const float t = std::max(0.f, std::min(1.f,
                                  (cc1 - below) / (center - below)));
            return std::sin(t * kHalfPi);
        }
        if (cc1 > center && above <= 127.f) {
            const float t = std::max(0.f, std::min(1.f,
                                  (above - cc1) / (above - center)));
            return std::sin(t * kHalfPi);
        }
        return 1.f;
    }

    void stop(uint8_t note, uint8_t channel) {
        for (auto& voice : voices) {
            if (voice.active && voice.note == note && voice.channel == channel &&
                voice.releaseFrames == 0) voice.releaseFrames = kFadeFrames;
        }
    }

    void consumeMIDI() {
        auto read = commandRead.load(std::memory_order_relaxed);
        const auto write = commandWrite.load(std::memory_order_acquire);
        while (read != write) {
            const Command command = commands[read];
            switch (command.kind) {
            case CommandKind::on:
                if (command.velocity) start(command.note, command.velocity, command.channel);
                else stop(command.note, command.channel);
                break;
            case CommandKind::off: stop(command.note, command.channel); break;
            case CommandKind::allOff:
                for (auto& voice : voices) if (voice.active) voice.releaseFrames = kFadeFrames;
                break;
            case CommandKind::controller:
                if (command.note == 1) targetCC1[command.channel] = command.velocity;
                if (command.note == 11) targetCC11[command.channel] = command.velocity;
                if (command.note == 120 || command.note == 123) {
                    for (auto& voice : voices)
                        if (voice.active && voice.channel == command.channel)
                            voice.releaseFrames = kFadeFrames;
                }
                break;
            case CommandKind::crossfade:
                cc1Crossfade = command.velocity != 0;
                break;
            }
            read = (read + 1) % kCommandCapacity;
        }
        commandRead.store(read, std::memory_order_release);
    }
};

extern "C" {

SSSampler *ss_create(double output_sample_rate, int32_t max_voices) {
    if (!validRate(output_sample_rate) || max_voices < 1 || max_voices > 64) return nullptr;
    try { return new SSSampler(output_sample_rate, max_voices); }
    catch (...) { return nullptr; }
}

void ss_destroy(SSSampler *sampler) { delete sampler; }

int32_t ss_add_zone(SSSampler *sampler,
                    uint8_t root_note, uint8_t lowest_note, uint8_t highest_note,
                    uint8_t lowest_velocity, uint8_t highest_velocity,
                    double source_sample_rate,
                    const float *left, const float *right, uint32_t frames) {
    if (!sampler || !left || frames < 2 || frames > kMaxSampleFrames ||
        sampler->samples.size() >= kMaxZones || !validRate(source_sample_rate) ||
        root_note > 127 || lowest_note > highest_note || highest_note > 127 ||
        lowest_velocity < 1 || lowest_velocity > highest_velocity || highest_velocity > 127) return 0;
    try {
        Sample zone;
        zone.left.assign(left, left + frames);
        if (right) zone.right.assign(right, right + frames);
        else zone.right = zone.left;
        for (uint32_t index = 0; index < frames; ++index) {
            if (!std::isfinite(zone.left[index]) || !std::isfinite(zone.right[index])) return 0;
        }
        zone.rate = source_sample_rate;
        zone.root = root_note;
        zone.low = lowest_note;
        zone.high = highest_note;
        zone.minVelocity = lowest_velocity;
        zone.maxVelocity = highest_velocity;
        sampler->samples.emplace_back(std::move(zone));
        return 1;
    } catch (...) { return 0; }
}

int32_t ss_zone_count(const SSSampler *sampler) {
    return sampler ? static_cast<int32_t>(sampler->samples.size()) : 0;
}

int32_t ss_note_on(SSSampler *sampler, uint8_t note, uint8_t velocity, uint8_t channel) {
    if (!sampler || note > 127 || velocity > 127 || channel > 15) return 0;
    return sampler->enqueue({CommandKind::on, note, velocity, channel}) ? 1 : 0;
}

int32_t ss_note_off(SSSampler *sampler, uint8_t note, uint8_t channel) {
    if (!sampler || note > 127 || channel > 15) return 0;
    return sampler->enqueue({CommandKind::off, note, 0, channel}) ? 1 : 0;
}

int32_t ss_all_notes_off(SSSampler *sampler) {
    if (!sampler) return 0;
    return sampler->enqueue({CommandKind::allOff, 0, 0, 0}) ? 1 : 0;
}

int32_t ss_control_change(SSSampler *sampler, uint8_t controller,
                          uint8_t value, uint8_t channel) {
    if (!sampler || controller > 127 || value > 127 || channel > 15) return 0;
    if (controller != 1 && controller != 11 &&
        controller != 120 && controller != 123) return 0;
    return sampler->enqueue({CommandKind::controller, controller, value, channel}) ? 1 : 0;
}

int32_t ss_set_cc1_crossfade(SSSampler *sampler, int32_t enabled) {
    if (!sampler) return 0;
    return sampler->enqueue({CommandKind::crossfade, 0,
                             uint8_t(enabled ? 1 : 0), 0}) ? 1 : 0;
}

void ss_render(SSSampler *sampler, float *left, float *right, int32_t frames) {
    if (!sampler || !left || !right || frames <= 0) return;
    sampler->consumeMIDI();
    // Approximately 10 ms one-pole smoothing to avoid zipper noise.
    const float smoothing = std::min(1.f, float(1.0 / (sampler->outputRate * 0.01)));
    for (int32_t frame = 0; frame < frames; ++frame) {
        for (int channel = 0; channel < 16; ++channel) {
            sampler->smoothCC1[channel] +=
                (sampler->targetCC1[channel] - sampler->smoothCC1[channel]) * smoothing;
            sampler->smoothCC11[channel] +=
                (sampler->targetCC11[channel] - sampler->smoothCC11[channel]) * smoothing;
        }
        float leftSum = 0;
        float rightSum = 0;
        for (auto& voice : sampler->voices) {
            if (!voice.active) continue;
            const Sample *sample = voice.sample;
            if (!sample || voice.position >= static_cast<double>(sample->left.size())) {
                voice.active = false;
                continue;
            }
            const float expression = sampler->smoothCC11[voice.channel] / 127.f;
            const float dynamics = sampler->smoothCC1[voice.channel];
            float amplitude = voice.gain * expression;
            if (sampler->cc1Crossfade) {
                amplitude *= sampler->dynamicWeight(*sample, voice.note, dynamics);
            } else {
                // In discrete-layer mode CC1 is still a continuous volume
                // control, but does not switch the sample after note-on.
                amplitude *= dynamics / 127.f;
            }
            if (voice.attackFrames > 0) {
                amplitude *= float(kFadeFrames - voice.attackFrames + 1) / float(kFadeFrames);
                --voice.attackFrames;
            }
            if (voice.releaseFrames > 0) {
                amplitude *= float(voice.releaseFrames) / float(kFadeFrames);
                --voice.releaseFrames;
                if (voice.releaseFrames == 0) voice.active = false;
            }
            leftSum += readLinear(sample->left, voice.position) * amplitude;
            rightSum += readLinear(sample->right, voice.position) * amplitude;
            voice.position += voice.increment;
        }
        left[frame] = std::max(-1.f, std::min(1.f, leftSum * kOutputHeadroom));
        right[frame] = std::max(-1.f, std::min(1.f, rightSum * kOutputHeadroom));
    }
}
} // extern "C"
