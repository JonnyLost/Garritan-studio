#include "StudioSamplerDSP.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <limits>
#include <memory>
#include <cstring>
#include <new>
#include <vector>

namespace {
constexpr uint32_t kMaxZones = 128;
constexpr uint32_t kMaxSampleFrames = 10000000; // maximum resident source
constexpr uint32_t kMaxStreamFrames = 500000000; // bounded source offsets
constexpr uint32_t kMaxAttackFrames = 32768;
constexpr uint32_t kPageFrames = SS_STREAM_PAGE_FRAMES;
constexpr int kStreamPagesPerVoice = 4; // current, next, loop entrance and following
constexpr uint32_t kCommandCapacity = 1024; // one slot deliberately left empty
constexpr int kFadeFrames = 64;
constexpr size_t kHeldDepth = 8; // per-channel, per-pitch repeated note stack
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
    uint32_t playbackStart = 0;
    uint32_t playbackEnd = 0; // exclusive
    uint32_t loopStart = 0;
    uint32_t loopEnd = 0; // exclusive; zero disables looping
    uint32_t loopCrossfade = 0;
    uint32_t fadeIn = 0;
    uint32_t fadeOut = 0;
    uint8_t articulation = 0;
    uint8_t roundRobin = 0;
    bool releaseTrigger = false;
    bool streamed = false;
    uint32_t attackStart = 0; // first decoded source frame in left/right vectors
    uint32_t fullFrames = 0; // source recording may be much larger than attack
};

struct ADSR {
    float attack = 0.0f;
    float decay = 0.0f;
    float sustain = 1.0f;
    float release = 0.0f;
};

enum class EnvelopeStage : uint8_t { attack, decay, sustain, release, done };

struct Voice {
    const Sample *sample = nullptr;
    double position = 0;
    double increment = 1;
    float gain = 0;
    // Prepared at note-on: O(1) layer-gain work in each rendered frame.
    float layerCenter = 64.f;
    float previousCenter = -1.f;
    float nextCenter = 129.f;
    uint64_t serial = 0;
    uint64_t noteSerial = 0;
    uint8_t note = 0;
    uint8_t channel = 0;
    ADSR adsr{};
    EnvelopeStage stage = EnvelopeStage::done;
    float envelopeLevel = 0.f;
    float envelopeDelta = 0.f;
    int stageFrames = 0;
    bool active = false;
    bool releaseTrigger = false;
    uint32_t zoneIndex = 0;
    float lastStreamL = 0.f;
    float lastStreamR = 0.f;
    float streamGain = 1.f;
};

struct HeldNote {
    bool down = false;
    uint8_t velocity = 0;
    uint8_t articulation = 0;
    uint8_t roundRobin = 0;
    uint64_t serial = 0;
};

struct RetiringVoice {
    Voice voice{};
    int framesLeft = 0;
    float gain = 0.f;
};

enum class CommandKind : uint8_t { on, off, allOff, controller, crossfade, envelope, articulation };
struct Command {
    CommandKind kind;
    uint8_t note;
    uint8_t velocity;
    uint8_t channel;
    ADSR adsr;

    Command(CommandKind kindValue = CommandKind::allOff, uint8_t noteValue = 0,
            uint8_t velocityValue = 0, uint8_t channelValue = 0,
            ADSR envelopeValue = ADSR{})
      : kind(kindValue), note(noteValue), velocity(velocityValue),
        channel(channelValue), adsr(envelopeValue) {}
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

/* State 0: unused; 1: requested by audio; 2: claimed by worker;
 * 3: ready. The audio thread never modifies a claimed page. The worker
 * never rewrites data already published as ready. */
struct StreamPage {
    std::atomic<uint32_t> state{0};
    uint64_t serial = 0;
    uint32_t zoneIndex = 0;
    uint32_t start = 0;
    uint32_t frames = 0;
    std::array<float, kPageFrames> left{};
    std::array<float, kPageFrames> right{};
};

struct SSSampler {
    explicit SSSampler(double rate, int voices)
        : outputRate(rate), voices(static_cast<size_t>(voices)),
          retiringVoices(static_cast<size_t>(voices)) {
        samples.reserve(kMaxZones); // stable Sample* pointers throughout render
        smoothCC1.fill(127.f);
        smoothCC11.fill(127.f);
        targetCC1.fill(127.f);
        targetCC11.fill(127.f);
        keyswitchArticulations.fill(255); // 255 denotes ordinary musical note
        selectedArticulations.fill(0); // default articulation for all MIDI channels
        // Defaults match the original short anti-click fades.
        activeADSR.attack = float(kFadeFrames / outputRate);
        activeADSR.release = float(kFadeFrames / outputRate);
    }

    double outputRate;
    std::vector<Sample> samples;
    std::vector<Voice> voices;
    // Preallocated de-click tails preserve an evicted voice for 64 frames.
    // They never add to the normal voice allocation/polyphony budget.
    std::vector<RetiringVoice> retiringVoices;
    // Allocated lazily when the first streamed zone is installed, not for
    // every ordinary RAM-based sampler instrument.
    std::unique_ptr<StreamPage[]> streamPages;
    std::atomic<uint64_t> underrunFrames{0};
    uint64_t nextSerial = 0;
    uint64_t nextNoteSerial = 0;
    std::array<uint8_t, 128> keyswitchArticulations{};
    std::array<uint8_t, 16> selectedArticulations{};
    // Fixed-size, real-time-owned note state and variation counters.
    // No allocation, lock, or mutation on the Swift/MIDI producer thread.
    std::array<std::array<std::array<HeldNote, kHeldDepth>, 128>, 16> heldNotes{};
    std::array<std::array<std::array<uint8_t, 128>, 16>, 16> roundRobinTurns{};
    ADSR activeADSR{};
    bool cc1Crossfade = false; // mutated only while consuming RT commands
    std::array<float, 16> smoothCC1{};
    std::array<float, 16> smoothCC11{};
    std::array<float, 16> targetCC1{};
    std::array<float, 16> targetCC11{};
    std::array<Command, kCommandCapacity> commands{};
    std::atomic<uint32_t> commandWrite{0};
    std::atomic<uint32_t> commandRead{0};

    // Called only by audio callback. Acquire prevents concurrent reads
    // of a slot until the worker fully publishes its Float32 page.
    bool streamFrame(const Voice& voice, uint32_t frame,
                     float& leftOut, float& rightOut) const {
        const Sample& sample = *voice.sample;
        if (frame >= sample.playbackEnd) return false;
        if (!sample.streamed) {
            if (frame >= sample.left.size()) return false;
            leftOut = sample.left[frame];
            rightOut = sample.right[frame];
            return true;
        }
        if (frame >= sample.attackStart &&
            uint64_t(frame) < uint64_t(sample.attackStart) + sample.left.size()) {
            const size_t offset = size_t(frame - sample.attackStart);
            leftOut = sample.left[offset];
            rightOut = sample.right[offset];
            return true;
        }
        if (!streamPages) return false;
        const size_t voiceIndex = size_t(&voice - voices.data());
        if (voiceIndex >= voices.size()) return false;
        for (int slot = 0; slot < kStreamPagesPerVoice; ++slot) {
            const StreamPage& page = streamPages[voiceIndex * kStreamPagesPerVoice + slot];
            if (page.state.load(std::memory_order_acquire) == 3 &&
                page.serial == voice.serial && page.zoneIndex == voice.zoneIndex &&
                frame >= page.start && uint64_t(frame) < uint64_t(page.start) + page.frames) {
                const size_t offset = size_t(frame - page.start);
                leftOut = page.left[offset];
                rightOut = page.right[offset];
                return true;
            }
        }
        return false;
    }

    bool streamLinear(const Voice& voice, double position, float& leftOut,
                      float& rightOut) const {
        if (!voice.sample->streamed) {
            leftOut = readLinear(voice.sample->left, position);
            rightOut = readLinear(voice.sample->right, position);
            return true;
        }
        if (position < 0 || position >= double(voice.sample->playbackEnd)) return false;
        const uint32_t frame = uint32_t(position);
        const uint32_t next = frame + 1 < voice.sample->playbackEnd ? frame + 1 : frame;
        float aL = 0.f, aR = 0.f, bL = 0.f, bR = 0.f;
        if (!streamFrame(voice, frame, aL, aR) ||
            !streamFrame(voice, next, bL, bR)) return false;
        const float ratio = float(position - double(frame));
        leftOut = aL + (bL - aL) * ratio;
        rightOut = aR + (bR - aR) * ratio;
        return true;
    }

    // Publish one page request from the audio callback with a release store.
    // It NEVER waits for a worker claim, I/O operation or completed page.
    void requestPage(const Voice& voice, uint32_t desiredStart,
                     uint32_t keepStart) {
        if (!streamPages || desiredStart >= voice.sample->playbackEnd) return;
        const size_t voiceIndex = size_t(&voice - voices.data());
        StreamPage *base = &streamPages[voiceIndex * kStreamPagesPerVoice];
        for (int i = 0; i < kStreamPagesPerVoice; ++i) {
            const auto state = base[i].state.load(std::memory_order_acquire);
            if (state != 0 && base[i].serial == voice.serial &&
                base[i].zoneIndex == voice.zoneIndex &&
                base[i].start == desiredStart) return;
        }
        StreamPage *slot = nullptr;
        for (int i = 0; i < kStreamPagesPerVoice; ++i) {
            const auto state = base[i].state.load(std::memory_order_acquire);
            if (state == 0) { slot = &base[i]; break; }
            if (state == 3 && (base[i].serial != voice.serial ||
                              base[i].zoneIndex != voice.zoneIndex)) {
                slot = &base[i]; break;
            }
        }
        if (!slot) {
            for (int i = 0; i < kStreamPagesPerVoice; ++i) {
                if (base[i].state.load(std::memory_order_acquire) == 3 &&
                    base[i].start != keepStart) {
                    slot = &base[i];
                    break;
                }
            }
        }
        if (!slot) return;
        slot->state.store(0, std::memory_order_release);
        slot->serial = voice.serial;
        slot->zoneIndex = voice.zoneIndex;
        slot->start = desiredStart;
        slot->frames = std::min(kPageFrames, voice.sample->fullFrames - desiredStart);
        slot->state.store(1, std::memory_order_release);
    }

    void prefetch(const Voice& voice) {
        const Sample& sample = *voice.sample;
        if (!sample.streamed || !streamPages) return;
        const uint32_t attackEnd = sample.attackStart +
                                   uint32_t(sample.left.size());
        const uint32_t position = uint32_t(std::max(
            0.0, std::min(voice.position, double(sample.playbackEnd - 1))));
        const uint32_t target = std::max(position, attackEnd - 1);
        const uint32_t currentPage = (target / kPageFrames) * kPageFrames;
        requestPage(voice, currentPage, currentPage);

        const uint32_t nextPage = currentPage + kPageFrames;
        const bool sustaining = sample.loopEnd != 0 &&
            voice.stage != EnvelopeStage::release &&
            voice.stage != EnvelopeStage::done;
        const uint32_t exitPage = sustaining
            ? ((sample.loopEnd - 1) / kPageFrames) * kPageFrames : 0;
        // The current page and the sequential next page must stay resident
        // until the loop is actually approached; skipping the next page can
        // cause an underrun on high transpositions.
        if (nextPage < sample.playbackEnd &&
            (!sustaining || currentPage < exitPage))
            requestPage(voice, nextPage, currentPage);

        if (sustaining && currentPage + kPageFrames >= exitPage) {
            // A loop can jump backward from its exit page into two distinct
            // entrance pages within one output block at high transposition.
            // Reserve both ahead of time, alongside current/next pages.
            const uint32_t loopPage =
                (sample.loopStart / kPageFrames) * kPageFrames;
            if (loopPage != currentPage)
                requestPage(voice, loopPage, currentPage);
            const uint32_t loopNext = loopPage + kPageFrames;
            if (loopNext < sample.loopEnd && loopNext != currentPage)
                requestPage(voice, loopNext, currentPage);
        }
    }

    int framesForSeconds(float seconds, int minimumFrames) const {
        const double requested = std::ceil(double(seconds) * outputRate);
        return std::max(minimumFrames, static_cast<int>(requested));
    }

    void startRelease(Voice& voice) {
        if (!voice.active || voice.stage == EnvelopeStage::release ||
            voice.stage == EnvelopeStage::done) return;
        voice.stage = EnvelopeStage::release;
        voice.stageFrames = framesForSeconds(voice.adsr.release, kFadeFrames);
        voice.envelopeDelta = -voice.envelopeLevel / float(voice.stageFrames);
    }

    void nextEnvelopeFrame(Voice& voice) {
        if (voice.stage == EnvelopeStage::sustain) {
            voice.envelopeLevel = voice.adsr.sustain;
            return;
        }
        if (voice.stage == EnvelopeStage::done) return;
        voice.envelopeLevel += voice.envelopeDelta;
        if (--voice.stageFrames > 0) return;
        switch (voice.stage) {
        case EnvelopeStage::attack:
            voice.envelopeLevel = 1.f;
            if (voice.adsr.decay > 0.f) {
                voice.stage = EnvelopeStage::decay;
                voice.stageFrames = framesForSeconds(voice.adsr.decay, 1);
                voice.envelopeDelta =
                    (voice.adsr.sustain - 1.f) / float(voice.stageFrames);
            } else {
                voice.stage = EnvelopeStage::sustain;
                voice.envelopeLevel = voice.adsr.sustain;
            }
            break;
        case EnvelopeStage::decay:
            voice.stage = EnvelopeStage::sustain;
            voice.envelopeLevel = voice.adsr.sustain;
            break;
        case EnvelopeStage::release:
            voice.envelopeLevel = 0.f;
            voice.stage = EnvelopeStage::done;
            voice.active = false;
            break;
        case EnvelopeStage::sustain:
        case EnvelopeStage::done:
            break;
        }
    }

    bool enqueue(Command value) {
        const auto write = commandWrite.load(std::memory_order_relaxed);
        const auto next = (write + 1) % kCommandCapacity;
        if (next == commandRead.load(std::memory_order_acquire)) return false;
        commands[write] = value;
        commandWrite.store(next, std::memory_order_release);
        return true;
    }

    // FIFO matching: a second note-on of the same pitch can remain held
    // after the first note-off. Bounded per-pitch stack; on overflow retire
    // the oldest group before storing a new one.
    uint64_t rememberNote(uint8_t note, uint8_t velocity, uint8_t channel,
                          uint8_t articulation, uint8_t variation) {
        auto& held = heldNotes[channel][note];
        HeldNote *slot = nullptr;
        for (auto& item : held) if (!item.down) { slot = &item; break; }
        if (!slot) {
            slot = &held[0];
            for (auto& item : held)
                if (item.serial < slot->serial) slot = &item;
            for (auto& voice : voices)
                if (voice.active && !voice.releaseTrigger &&
                    voice.noteSerial == slot->serial)
                    startRelease(voice);
        }
        *slot = HeldNote{true, velocity, articulation, variation, ++nextNoteSerial};
        return slot->serial;
    }

    void retireVoice(const Voice& voice) {
        if (!voice.active || !voice.sample) return;
        RetiringVoice *slot = nullptr;
        for (auto& tail : retiringVoices) {
            if (tail.framesLeft <= 0) { slot = &tail; break; }
        }
        if (!slot) {
            slot = &*std::min_element(retiringVoices.begin(), retiringVoices.end(),
                [](const RetiringVoice& a, const RetiringVoice& b) {
                    return a.framesLeft < b.framesLeft;
                });
        }
        slot->voice = voice;
        slot->framesLeft = kFadeFrames;
        slot->gain = std::max(0.f, voice.envelopeLevel) * voice.gain;
    }

    void startVoice(const Sample *selected, uint8_t note,
                    uint8_t velocity, uint8_t channel, uint64_t noteSerial,
                    bool releaseSample = false) {
        Voice *chosen = nullptr;
        for (auto& voice : voices) {
            if (!voice.active) { chosen = &voice; break; }
        }
        if (!chosen) {
            chosen = &*std::min_element(voices.begin(), voices.end(),
                [](const Voice& a, const Voice& b) {
                    const bool aReleasing = a.stage == EnvelopeStage::release;
                    const bool bReleasing = b.stage == EnvelopeStage::release;
                    if (aReleasing != bReleasing) return aReleasing;
                    return a.serial < b.serial;
                });
            retireVoice(*chosen);
        }

        // Equal-temperament pitch shift relative to recorded root key.
        const double semitones = (int(note) - int(selected->root)) / 12.0;
        const double increment = selected->rate / outputRate * std::pow(2.0, semitones);
        if (!std::isfinite(increment) || increment <= 0) return;
        *chosen = Voice{};
        chosen->sample = selected;
        chosen->zoneIndex = uint32_t(selected - samples.data());
        chosen->note = note;
        chosen->channel = channel;
        chosen->noteSerial = noteSerial;
        chosen->position = double(selected->playbackStart);
        chosen->increment = increment;
        chosen->gain = float(velocity) / 127.f;
        chosen->layerCenter = (float(selected->minVelocity) +
                               float(selected->maxVelocity)) * 0.5f;
        for (const auto& sample : samples) {
            if (&sample == selected || sample.root != selected->root ||
                sample.articulation != selected->articulation ||
                sample.releaseTrigger != selected->releaseTrigger ||
                note < sample.low || note > sample.high) continue;
            const float other = (float(sample.minVelocity) +
                                 float(sample.maxVelocity)) * 0.5f;
            if (other < chosen->layerCenter && other > chosen->previousCenter)
                chosen->previousCenter = other;
            if (other > chosen->layerCenter && other < chosen->nextCenter)
                chosen->nextCenter = other;
        }
        chosen->adsr = releaseSample
            ? ADSR{float(kFadeFrames / outputRate), 0.f, 1.f, 0.f}
            : activeADSR;
        chosen->releaseTrigger = releaseSample;
        chosen->stage = EnvelopeStage::attack;
        chosen->envelopeLevel = 0.f;
        chosen->stageFrames = framesForSeconds(chosen->adsr.attack, kFadeFrames);
        chosen->envelopeDelta = 1.f / float(chosen->stageFrames);
        chosen->serial = ++nextSerial;
        chosen->active = true;
    }

    // Variation counters advance per channel / pitch / articulation.
    // Only recorded takes for the same nearest root and velocity band
    // participate. CC1 layering shares one variation across all its layers.
    uint8_t chooseRoundRobin(uint8_t note, uint8_t channel,
                             uint8_t articulation, const Sample& selected) {
        std::array<bool, 8> available{};
        for (const auto& zone : samples) {
            if (zone.releaseTrigger || zone.articulation != articulation ||
                zone.root != selected.root || note < zone.low || note > zone.high)
                continue;
            if (!cc1Crossfade &&
                (zone.minVelocity != selected.minVelocity ||
                 zone.maxVelocity != selected.maxVelocity))
                continue;
            available[zone.roundRobin] = true;
        }
        int count = 0;
        for (bool present : available) if (present) ++count;
        if (count == 0) return selected.roundRobin;
        const uint8_t turn = roundRobinTurns[channel][articulation][note]++;
        int slot = turn % count;
        for (uint8_t index = 0; index < 8; ++index) {
            if (available[index] && slot-- == 0) return index;
        }
        return selected.roundRobin;
    }

    void start(uint8_t note, uint8_t velocity, uint8_t channel) {
        const uint8_t keyswitch = keyswitchArticulations[note];
        if (keyswitch != 255) {
            selectedArticulations[channel] = keyswitch;
            return;
        }
        const uint8_t articulation = selectedArticulations[channel];
        const Sample *selected = nullptr;
        int bestDistance = std::numeric_limits<int>::max();
        for (const auto& sample : samples) {
            if (sample.releaseTrigger || sample.articulation != articulation ||
                note < sample.low || note > sample.high ||
                (!cc1Crossfade &&
                 (velocity < sample.minVelocity || velocity > sample.maxVelocity)))
                continue;
            const int distance = std::abs(int(note) - int(sample.root));
            if (distance < bestDistance) {
                selected = &sample;
                bestDistance = distance;
            }
        }
        if (!selected) return;
        const uint8_t variation =
            chooseRoundRobin(note, channel, articulation, *selected);
        const uint64_t noteSerial = rememberNote(
            note, velocity, channel, articulation, variation);

        if (!cc1Crossfade) {
            const Sample *take = selected;
            for (const auto& sample : samples) {
                if (!sample.releaseTrigger && sample.articulation == articulation &&
                    sample.root == selected->root && sample.roundRobin == variation &&
                    sample.minVelocity == selected->minVelocity &&
                    sample.maxVelocity == selected->maxVelocity &&
                    note >= sample.low && note <= sample.high) {
                    take = &sample;
                    break;
                }
            }
            startVoice(take, note, velocity, channel, noteSerial);
            return;
        }

        // Each dynamic band contributes ONE recorded variation (maximum 8
        // bands), never a sum of all round-robin takes. Missing variations
        // fall back to the first sample for that band.
        std::array<uint16_t, 8> playedBands{};
        int bands = 0;
        for (const auto& sample : samples) {
            if (sample.releaseTrigger || sample.articulation != articulation ||
                sample.root != selected->root || note < sample.low || note > sample.high)
                continue;
            const uint16_t band = uint16_t(sample.minVelocity) << 8 |
                                  uint16_t(sample.maxVelocity);
            bool alreadyPlayed = false;
            for (int i = 0; i < bands; ++i) {
                if (playedBands[i] == band) { alreadyPlayed = true; break; }
            }
            if (alreadyPlayed) continue;
            if (bands >= 8) break;
            playedBands[bands++] = band;
            const Sample *take = &sample;
            for (const auto& possible : samples) {
                if (!possible.releaseTrigger && possible.root == sample.root &&
                    possible.articulation == articulation &&
                    possible.minVelocity == sample.minVelocity &&
                    possible.maxVelocity == sample.maxVelocity &&
                    possible.roundRobin == variation &&
                    note >= possible.low && note <= possible.high) {
                    take = &possible;
                    break;
                }
            }
            startVoice(take, note, velocity, channel, noteSerial);
        }
    }

    float dynamicWeight(const Voice& voice, float cc1) const {
        if (cc1 < voice.layerCenter && voice.previousCenter >= 0.f) {
            const float t = std::max(0.f, std::min(1.f,
                (cc1 - voice.previousCenter) /
                (voice.layerCenter - voice.previousCenter)));
            return std::sin(t * kHalfPi);
        }
        if (cc1 > voice.layerCenter && voice.nextCenter <= 127.f) {
            const float t = std::max(0.f, std::min(1.f,
                (voice.nextCenter - cc1) /
                (voice.nextCenter - voice.layerCenter)));
            return std::sin(t * kHalfPi);
        }
        return 1.f;
    }

    void stop(uint8_t note, uint8_t channel) {
        if (keyswitchArticulations[note] != 255) return;
        auto& heldGroup = heldNotes[channel][note];
        HeldNote *matched = nullptr;
        for (auto& entry : heldGroup) {
            if (entry.down && (!matched || entry.serial < matched->serial))
                matched = &entry;
        }
        // Unmatched/duplicate note-offs do not release voices or fire tails.
        if (!matched) return;
        const HeldNote held = *matched;
        matched->down = false;
        for (auto& voice : voices) {
            if (voice.active && !voice.releaseTrigger &&
                voice.noteSerial == held.serial)
                startRelease(voice);
        }

        const Sample *release = nullptr;
        int nearest = std::numeric_limits<int>::max();
        for (const auto& zone : samples) {
            if (!zone.releaseTrigger || zone.articulation != held.articulation ||
                note < zone.low || note > zone.high ||
                held.velocity < zone.minVelocity || held.velocity > zone.maxVelocity)
                continue;
            const int distance = std::abs(int(note) - int(zone.root));
            if (distance < nearest) {
                release = &zone;
                nearest = distance;
            }
        }
        if (!release) return;
        for (const auto& zone : samples) {
            if (zone.releaseTrigger && zone.articulation == held.articulation &&
                zone.root == release->root &&
                zone.roundRobin == held.roundRobin &&
                note >= zone.low && note <= zone.high &&
                held.velocity >= zone.minVelocity && held.velocity <= zone.maxVelocity) {
                release = &zone;
                break;
            }
        }
        startVoice(release, note, held.velocity, channel, held.serial, true);
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
                for (auto& row : heldNotes)
                    for (auto& group : row)
                        for (auto& held : group) held.down = false;
                for (auto& voice : voices) if (voice.active) startRelease(voice);
                break;
            case CommandKind::controller:
                if (command.note == 1) targetCC1[command.channel] = command.velocity;
                if (command.note == 11) targetCC11[command.channel] = command.velocity;
                if (command.note == 120 || command.note == 123) {
                    for (auto& group : heldNotes[command.channel])
                        for (auto& held : group) held.down = false;
                    for (auto& voice : voices)
                        if (voice.active && voice.channel == command.channel)
                            startRelease(voice);
                }
                break;
            case CommandKind::crossfade:
                cc1Crossfade = command.velocity != 0;
                break;
            case CommandKind::envelope:
                activeADSR = command.adsr;
                break;
            case CommandKind::articulation:
                selectedArticulations[command.channel] = command.note;
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
    return ss_add_zone_with_loop(sampler, root_note, lowest_note, highest_note,
                                 lowest_velocity, highest_velocity,
                                 source_sample_rate, left, right, frames, 0, 0, 0);
}

int32_t ss_add_zone_with_loop(SSSampler *sampler,
                    uint8_t root_note, uint8_t lowest_note, uint8_t highest_note,
                    uint8_t lowest_velocity, uint8_t highest_velocity,
                    double source_sample_rate,
                    const float *left, const float *right, uint32_t frames,
                    uint32_t loop_start_frame, uint32_t loop_end_frame,
                    uint32_t loop_crossfade_frames) {
    return ss_add_zone_with_region(
        sampler, root_note, lowest_note, highest_note,
        lowest_velocity, highest_velocity, source_sample_rate,
        left, right, frames, 0, frames,
        loop_start_frame, loop_end_frame, loop_crossfade_frames);
}

int32_t ss_add_zone_with_region(SSSampler *sampler,
                    uint8_t root_note, uint8_t lowest_note, uint8_t highest_note,
                    uint8_t lowest_velocity, uint8_t highest_velocity,
                    double source_sample_rate,
                    const float *left, const float *right, uint32_t frames,
                    uint32_t playback_start_frame, uint32_t playback_end_frame,
                    uint32_t loop_start_frame, uint32_t loop_end_frame,
                    uint32_t loop_crossfade_frames) {
    return ss_add_zone_with_options(sampler, root_note, lowest_note, highest_note,
        lowest_velocity, highest_velocity, source_sample_rate, left, right, frames,
        playback_start_frame, playback_end_frame, loop_start_frame,
        loop_end_frame, loop_crossfade_frames, 0, 0, 0);
}

int32_t ss_add_zone_with_options(SSSampler *sampler,
                    uint8_t root_note, uint8_t lowest_note, uint8_t highest_note,
                    uint8_t lowest_velocity, uint8_t highest_velocity,
                    double source_sample_rate,
                    const float *left, const float *right, uint32_t frames,
                    uint32_t playback_start_frame, uint32_t playback_end_frame,
                    uint32_t loop_start_frame, uint32_t loop_end_frame,
                    uint32_t loop_crossfade_frames,
                    uint32_t fade_in_frames, uint32_t fade_out_frames,
                    uint8_t articulation_id) {
    return ss_add_zone_with_variation(sampler, root_note, lowest_note, highest_note,
        lowest_velocity, highest_velocity, source_sample_rate, left, right, frames,
        playback_start_frame, playback_end_frame, loop_start_frame,
        loop_end_frame, loop_crossfade_frames, fade_in_frames,
        fade_out_frames, articulation_id, 0, 0);
}

int32_t ss_add_zone_with_variation(SSSampler *sampler,
                    uint8_t root_note, uint8_t lowest_note, uint8_t highest_note,
                    uint8_t lowest_velocity, uint8_t highest_velocity,
                    double source_sample_rate,
                    const float *left, const float *right, uint32_t frames,
                    uint32_t playback_start_frame, uint32_t playback_end_frame,
                    uint32_t loop_start_frame, uint32_t loop_end_frame,
                    uint32_t loop_crossfade_frames,
                    uint32_t fade_in_frames, uint32_t fade_out_frames,
                    uint8_t articulation_id,
                    uint8_t round_robin_index, uint8_t release_trigger) {
    const bool validRegion = playback_start_frame < playback_end_frame &&
        playback_end_frame <= frames && playback_end_frame - playback_start_frame >= 2;
    const bool noLoop = loop_start_frame == 0 && loop_end_frame == 0 &&
                        loop_crossfade_frames == 0;
    const bool validLoop = loop_start_frame >= playback_start_frame &&
        loop_end_frame <= playback_end_frame &&
        loop_start_frame <= loop_end_frame &&
        loop_end_frame - loop_start_frame >= 4 &&
        loop_crossfade_frames <= (loop_end_frame - loop_start_frame) / 2;
    const bool validFade = validRegion &&
        uint64_t(fade_in_frames) + uint64_t(fade_out_frames) <=
            uint64_t(playback_end_frame - playback_start_frame);
    if (!validRegion || !validFade || articulation_id > 15 ||
        round_robin_index > 7 || release_trigger > 1 ||
        (release_trigger == 1 && !noLoop) || (!noLoop && !validLoop) ||
        !sampler || !left || frames < 2 || frames > kMaxSampleFrames ||
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
        zone.playbackStart = playback_start_frame;
        zone.playbackEnd = playback_end_frame;
        zone.loopStart = loop_start_frame;
        zone.loopEnd = loop_end_frame;
        zone.loopCrossfade = loop_crossfade_frames;
        zone.fadeIn = fade_in_frames;
        zone.fadeOut = fade_out_frames;
        zone.articulation = articulation_id;
        zone.roundRobin = round_robin_index;
        zone.releaseTrigger = release_trigger == 1;
        sampler->samples.emplace_back(std::move(zone));
        return 1;
    } catch (...) { return 0; }
}

int32_t ss_add_stream_zone(SSSampler *sampler,
                    uint8_t root_note, uint8_t lowest_note, uint8_t highest_note,
                    uint8_t lowest_velocity, uint8_t highest_velocity,
                    double source_sample_rate,
                    const float *attack_left, const float *attack_right,
                    uint32_t full_frames, uint32_t attack_frames,
                    uint32_t playback_start_frame, uint32_t playback_end_frame,
                    uint32_t loop_start_frame, uint32_t loop_end_frame,
                    uint32_t loop_crossfade_frames,
                    uint32_t fade_in_frames, uint32_t fade_out_frames,
                    uint8_t articulation_id,
                    uint8_t round_robin_index, uint8_t release_trigger) {
    const bool validRegion = playback_start_frame < playback_end_frame &&
        playback_end_frame <= full_frames &&
        playback_end_frame - playback_start_frame >= 2;
    const bool noLoop = loop_start_frame == 0 && loop_end_frame == 0 &&
                        loop_crossfade_frames == 0;
    const bool validLoop = loop_start_frame >= playback_start_frame &&
        loop_end_frame <= playback_end_frame &&
        loop_start_frame <= loop_end_frame &&
        loop_end_frame - loop_start_frame >= 4 &&
        loop_crossfade_frames <= (loop_end_frame - loop_start_frame) / 2;
    const bool validFade = validRegion &&
        uint64_t(fade_in_frames) + uint64_t(fade_out_frames) <=
            uint64_t(playback_end_frame - playback_start_frame);
    if (!sampler || !attack_left || full_frames < 2 ||
        full_frames > kMaxStreamFrames || !validRegion || !validFade ||
        (!noLoop && !validLoop) || (release_trigger == 1 && !noLoop) ||
        attack_frames < 2 || attack_frames > kMaxAttackFrames ||
        uint64_t(attack_frames) > uint64_t(full_frames) - playback_start_frame ||
        sampler->samples.size() >= kMaxZones || !validRate(source_sample_rate) ||
        root_note > 127 || lowest_note > highest_note || highest_note > 127 ||
        lowest_velocity < 1 || lowest_velocity > highest_velocity ||
        highest_velocity > 127 || round_robin_index > 7 ||
        articulation_id > 15 || release_trigger > 1) return 0;
    try {
        Sample zone;
        zone.left.assign(attack_left, attack_left + attack_frames);
        if (attack_right) zone.right.assign(attack_right, attack_right + attack_frames);
        else zone.right = zone.left;
        for (uint32_t index = 0; index < attack_frames; ++index)
            if (!std::isfinite(zone.left[index]) || !std::isfinite(zone.right[index]))
                return 0;
        zone.rate = source_sample_rate;
        zone.root = root_note;
        zone.low = lowest_note;
        zone.high = highest_note;
        zone.minVelocity = lowest_velocity;
        zone.maxVelocity = highest_velocity;
        zone.playbackStart = playback_start_frame;
        zone.playbackEnd = playback_end_frame;
        zone.loopStart = loop_start_frame;
        zone.loopEnd = loop_end_frame;
        zone.loopCrossfade = loop_crossfade_frames;
        zone.fadeIn = fade_in_frames;
        zone.fadeOut = fade_out_frames;
        zone.articulation = articulation_id;
        zone.roundRobin = round_robin_index;
        zone.releaseTrigger = release_trigger == 1;
        zone.streamed = true;
        zone.attackStart = playback_start_frame;
        zone.fullFrames = full_frames;

        // All streaming page memory is allocated while configuring the first
        // zone. The audio callback NEVER allocates these buffers.
        if (!sampler->streamPages)
            sampler->streamPages.reset(new StreamPage[
                sampler->voices.size() * kStreamPagesPerVoice]);
        sampler->samples.emplace_back(std::move(zone));
        return 1;
    } catch (...) { return 0; }
}

int32_t ss_stream_claim(SSSampler *sampler, SSStreamRequest *request) {
    if (!sampler || !request || !sampler->streamPages) return 0;
    const size_t count = sampler->voices.size() * kStreamPagesPerVoice;
    for (size_t i = 0; i < count; ++i) {
        StreamPage& page = sampler->streamPages[i];
        uint32_t expected = 1;
        if (!page.state.compare_exchange_strong(expected, 2,
                std::memory_order_acq_rel)) continue;
        request->voice_index = int32_t(i / kStreamPagesPerVoice);
        request->slot_index = int32_t(i % kStreamPagesPerVoice);
        request->zone_index = int32_t(page.zoneIndex);
        request->start_frame = page.start;
        request->frame_count = page.frames;
        request->voice_serial = page.serial;
        return 1;
    }
    return 0;
}

static StreamPage *claimedPage(SSSampler *sampler,
                              const SSStreamRequest *request) {
    if (!sampler || !request || !sampler->streamPages ||
        request->voice_index < 0 ||
        size_t(request->voice_index) >= sampler->voices.size() ||
        request->slot_index < 0 ||
        request->slot_index >= kStreamPagesPerVoice) return nullptr;
    StreamPage *page = &sampler->streamPages[
        size_t(request->voice_index) * kStreamPagesPerVoice +
        size_t(request->slot_index)];
    if (page->state.load(std::memory_order_acquire) != 2 ||
        page->serial != request->voice_serial ||
        page->zoneIndex != uint32_t(request->zone_index) ||
        page->start != request->start_frame ||
        page->frames != request->frame_count) return nullptr;
    return page;
}

int32_t ss_stream_supply(SSSampler *sampler, const SSStreamRequest *request,
                         const float *left, const float *right, uint32_t frames) {
    StreamPage *page = claimedPage(sampler, request);
    if (!page || !left || !frames || frames > request->frame_count ||
        frames > kPageFrames) return 0;
    // Exclusive write ownership is held by the background worker.
    for (uint32_t frame = 0; frame < frames; ++frame) {
        const float a = left[frame];
        const float b = right ? right[frame] : a;
        if (!std::isfinite(a) || !std::isfinite(b)) return 0;
        page->left[frame] = a;
        page->right[frame] = b;
    }
    page->frames = frames;
    page->state.store(3, std::memory_order_release);
    return 1;
}

void ss_stream_abandon(SSSampler *sampler, const SSStreamRequest *request) {
    StreamPage *page = claimedPage(sampler, request);
    if (page) page->state.store(0, std::memory_order_release);
}

uint64_t ss_stream_underrun_frames(const SSSampler *sampler) {
    return sampler ? sampler->underrunFrames.load(std::memory_order_relaxed) : 0;
}

int32_t ss_zone_count(const SSSampler *sampler) {
    return sampler ? static_cast<int32_t>(sampler->samples.size()) : 0;
}

int32_t ss_configure_keyswitches(SSSampler *sampler,
                                const uint8_t *notes,
                                const uint8_t *articulation_ids,
                                int32_t count) {
    if (!sampler || count < 0 || count > 16 ||
        (count > 0 && (!notes || !articulation_ids))) return 0;
    std::array<uint8_t, 128> prepared{};
    std::array<bool, 16> usedIDs{};
    prepared.fill(255);
    for (int32_t i = 0; i < count; ++i) {
        const uint8_t id = articulation_ids[i];
        const uint8_t note = notes[i];
        if (id > 15 || usedIDs[id] || prepared[note] != 255) return 0;
        usedIDs[id] = true;
        prepared[note] = id;
    }
    sampler->keyswitchArticulations = prepared;
    return 1;
}

int32_t ss_select_articulation(SSSampler *sampler,
                              uint8_t articulation_id, uint8_t channel) {
    if (!sampler || articulation_id > 15 || channel > 15) return 0;
    return sampler->enqueue({CommandKind::articulation, articulation_id, 0, channel}) ? 1 : 0;
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

int32_t ss_set_adsr(SSSampler *sampler, float attack_seconds,
                    float decay_seconds, float sustain_level,
                    float release_seconds) {
    const bool valid = std::isfinite(attack_seconds) &&
                       std::isfinite(decay_seconds) &&
                       std::isfinite(sustain_level) &&
                       std::isfinite(release_seconds) &&
                       attack_seconds >= 0.f && attack_seconds <= 30.f &&
                       decay_seconds >= 0.f && decay_seconds <= 30.f &&
                       sustain_level >= 0.f && sustain_level <= 1.f &&
                       release_seconds >= 0.f && release_seconds <= 30.f;
    if (!sampler || !valid) return 0;
    return sampler->enqueue(Command{CommandKind::envelope, 0, 0, 0,
                              ADSR{attack_seconds, decay_seconds,
                                   sustain_level, release_seconds}}) ? 1 : 0;
}

void ss_render(SSSampler *sampler, float *left, float *right, int32_t frames) {
    if (!sampler || !left || !right || frames <= 0) return;
    sampler->consumeMIDI();
    // One bounded prefetch pass per render block, never a worker wakeup or
    // synchronous disk read from the audio thread.
    for (const auto& voice : sampler->voices)
        if (voice.active && voice.sample && voice.sample->streamed)
            sampler->prefetch(voice);
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
            if (!sample) {
                voice.active = false;
                continue;
            }
            const bool looping = sample->loopEnd != 0 &&
                voice.stage != EnvelopeStage::release &&
                voice.stage != EnvelopeStage::done;
            if (looping && voice.position >= double(sample->loopEnd)) {
                const double region = double(sample->loopEnd - sample->loopStart -
                                             sample->loopCrossfade);
                voice.position = double(sample->loopStart + sample->loopCrossfade) +
                    std::fmod(voice.position - double(sample->loopEnd), region);
            }
            if (voice.position >= double(sample->playbackEnd)) {
                voice.active = false;
                continue;
            }
            sampler->nextEnvelopeFrame(voice);
            if (!voice.active) continue;
            const float expression = sampler->smoothCC11[voice.channel] / 127.f;
            const float dynamics = sampler->smoothCC1[voice.channel];
            float amplitude = voice.gain * expression;
            if (sampler->cc1Crossfade && !voice.releaseTrigger) {
                amplitude *= sampler->dynamicWeight(voice, dynamics);
            } else {
                // In discrete-layer mode CC1 is still a continuous volume
                // control, but does not switch the sample after note-on.
                amplitude *= dynamics / 127.f;
            }
            amplitude *= std::max(0.f, voice.envelopeLevel);
            // Source-relative anti-click ramps. Preserve the original PCM,
            // including when sample playback is transposed or looped.
            if (sample->fadeIn > 0) {
                amplitude *= std::min(1.f, std::max(0.f,
                    float((voice.position - double(sample->playbackStart) + 1.0) /
                          double(sample->fadeIn))));
            }
            if (sample->fadeOut > 0) {
                amplitude *= std::min(1.f, std::max(0.f,
                    float((double(sample->playbackEnd) - voice.position) /
                          double(sample->fadeOut))));
            }
            float sampleL = 0.f, sampleR = 0.f;
            bool available = sampler->streamLinear(voice, voice.position,
                                                    sampleL, sampleR);
            if (looping && sample->loopCrossfade > 0) {
                const double fadeStart = double(sample->loopEnd -
                                                sample->loopCrossfade);
                if (voice.position >= fadeStart) {
                    const double phase = std::min(1.0,
                        (voice.position - fadeStart) /
                        double(sample->loopCrossfade));
                    const float from = std::cos(float(phase) * kHalfPi);
                    const float to = std::sin(float(phase) * kHalfPi);
                    const double incomingPosition =
                        double(sample->loopStart) +
                        phase * double(sample->loopCrossfade);
                    float incomingL = 0.f, incomingR = 0.f;
                    available = sampler->streamLinear(voice, incomingPosition,
                                                       incomingL, incomingR) && available;
                    if (available) {
                        sampleL = sampleL * from + incomingL * to;
                        sampleR = sampleR * from + incomingR * to;
                    }
                }
            }
            if (sample->streamed) {
                if (available) {
                    voice.streamGain = std::min(1.f,
                        voice.streamGain + 1.f / float(kFadeFrames));
                    voice.lastStreamL = sampleL;
                    voice.lastStreamR = sampleR;
                } else {
                    // Never block the audio callback. Smooth an I/O miss to
                    // silence and resume when the worker publishes a page.
                    sampler->underrunFrames.fetch_add(1, std::memory_order_relaxed);
                    voice.streamGain = std::max(0.f,
                        voice.streamGain - 1.f / float(kFadeFrames));
                    sampleL = voice.lastStreamL;
                    sampleR = voice.lastStreamR;
                }
                sampleL *= voice.streamGain;
                sampleR *= voice.streamGain;
            }
            leftSum += sampleL * amplitude;
            rightSum += sampleR * amplitude;
            voice.position += voice.increment;
        }
        // De-click stolen voices using a pool allocated at ss_create().
        // The old sample survives for exactly 64 more output frames,
        // allowing the replacement voice's attack to ramp in normally.
        for (auto& tail : sampler->retiringVoices) {
            if (tail.framesLeft <= 0) continue;
            Voice& old = tail.voice;
            const Sample *sample = old.sample;
            if (!sample) { tail.framesLeft = 0; continue; }
            const bool loop = sample->loopEnd > 0 &&
                old.stage != EnvelopeStage::release &&
                old.stage != EnvelopeStage::done;
            if (loop && old.position >= double(sample->loopEnd)) {
                const double region = double(sample->loopEnd -
                    sample->loopStart - sample->loopCrossfade);
                old.position = double(sample->loopStart + sample->loopCrossfade) +
                    std::fmod(old.position - double(sample->loopEnd), region);
            }
            if (old.position >= double(sample->playbackEnd)) {
                tail.framesLeft = 0;
                continue;
            }
            const float fade = float(tail.framesLeft) / float(kFadeFrames);
            const float cc1 = sampler->smoothCC1[old.channel];
            const float layer = (sampler->cc1Crossfade && !old.releaseTrigger)
                ? sampler->dynamicWeight(old, cc1) : cc1 / 127.f;
            const float expression = sampler->smoothCC11[old.channel] / 127.f;
            float gain = tail.gain * fade * layer * expression;
            // Match the source-relative fades used by normal voices so
            // stealing a voice near a trim edge cannot reintroduce a click.
            if (sample->fadeIn > 0) {
                gain *= std::min(1.f, std::max(0.f,
                    float((old.position - double(sample->playbackStart) + 1.0) /
                          double(sample->fadeIn))));
            }
            if (sample->fadeOut > 0) {
                gain *= std::min(1.f, std::max(0.f,
                    float((double(sample->playbackEnd) - old.position) /
                          double(sample->fadeOut))));
            }
            float sampleL = sample->streamed
                ? old.lastStreamL : readLinear(sample->left, old.position);
            float sampleR = sample->streamed
                ? old.lastStreamR : readLinear(sample->right, old.position);
            if (!sample->streamed && loop && sample->loopCrossfade > 0 &&
                old.position >= double(sample->loopEnd - sample->loopCrossfade)) {
                const double phase = std::min(1.0,
                    (old.position - double(sample->loopEnd - sample->loopCrossfade)) /
                    double(sample->loopCrossfade));
                const float from = std::cos(float(phase) * kHalfPi);
                const float to = std::sin(float(phase) * kHalfPi);
                const double incoming = double(sample->loopStart) +
                    phase * double(sample->loopCrossfade);
                sampleL = sampleL * from + readLinear(sample->left, incoming) * to;
                sampleR = sampleR * from + readLinear(sample->right, incoming) * to;
            }
            leftSum += sampleL * gain;
            rightSum += sampleR * gain;
            old.position += old.increment;
            --tail.framesLeft;
        }
        left[frame] = std::max(-1.f, std::min(1.f, leftSum * kOutputHeadroom));
        right[frame] = std::max(-1.f, std::min(1.f, rightSum * kOutputHeadroom));
    }
}
} // extern "C"
