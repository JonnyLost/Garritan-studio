#include "StudioSamplerDSP.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>

int main() {
    assert(ss_create(0, 8) == nullptr);
    assert(ss_create(44100, 65) == nullptr);
    SSSampler *sampler = ss_create(44100, 8);
    assert(sampler);
    constexpr int frames = 44100;
    std::vector<float> left(frames), right(frames);
    for (int i = 0; i < frames; ++i) {
        left[i] = std::sin(2.0 * 3.141592653589793 * 440.0 * i / 44100);
        right[i] = 0.5f * left[i];
    }
    assert(!ss_add_zone(sampler, 69, 70, 60, 1, 127, 44100, left.data(), right.data(), frames));
    assert(ss_add_zone(sampler, 69, 60, 84, 1, 127, 44100, left.data(), right.data(), frames));
    assert(ss_zone_count(sampler) == 1);
    assert(ss_note_on(sampler, 69, 127, 0));
    std::vector<float> outL(11025), outR(11025);
    ss_render(sampler, outL.data(), outR.data(), static_cast<int32_t>(outL.size()));
    int crossings = 0;
    for (size_t i = 1024; i < outL.size(); ++i) {
        assert(std::isfinite(outL[i]) && std::isfinite(outR[i]));
        assert(outL[i] <= 1.f && outL[i] >= -1.f);
        assert(std::abs(outL[i] - outR[i]*2.f) < .00002f);
        if (outL[i-1] <= 0 && outL[i] > 0) ++crossings;
    }
    double frequency = crossings * 44100.0 / (outL.size() - 1024);
    assert(std::abs(frequency - 440) < 12);
    assert(ss_note_on(sampler, 81, 100, 1)); // transpose +12 semitones
    ss_render(sampler, outL.data(), outR.data(), 1024);
    assert(ss_note_off(sampler, 69, 0));
    assert(ss_all_notes_off(sampler));
    ss_render(sampler, outL.data(), outR.data(), 1024);
    for (size_t i = 512; i < 1024; ++i) assert(outL[i] == 0);
    assert(!ss_note_on(sampler, 128, 90, 0));
    // Explicit velocity layers and separate key regions must select the
    // intended zone rather than mixing all matching samples together.
    SSSampler *layers = ss_create(44100, 4);
    assert(layers);
    std::vector<float> quiet(2048, .2f);
    std::vector<float> loud(2048, .8f);
    std::vector<float> high(2048, -.5f);
    assert(ss_add_zone(layers, 60, 0, 63, 1, 63, 44100,
                       quiet.data(), nullptr, 2048));
    assert(ss_add_zone(layers, 60, 0, 63, 64, 127, 44100,
                       loud.data(), nullptr, 2048));
    assert(ss_add_zone(layers, 67, 64, 127, 1, 127, 44100,
                       high.data(), nullptr, 2048));
    assert(ss_zone_count(layers) == 3);
    assert(ss_note_on(layers, 60, 50, 0));
    ss_render(layers, outL.data(), outR.data(), 256);
    const float quietLevel = outL[220];
    assert(quietLevel > .015f && quietLevel < .03f);
    assert(ss_note_off(layers, 60, 0));
    ss_render(layers, outL.data(), outR.data(), 256);
    assert(ss_note_on(layers, 60, 100, 0));
    ss_render(layers, outL.data(), outR.data(), 256);
    const float loudLevel = outL[220];
    assert(loudLevel > quietLevel * 4.f);
    assert(ss_all_notes_off(layers));
    ss_render(layers, outL.data(), outR.data(), 256);
    assert(ss_note_on(layers, 67, 100, 0));
    ss_render(layers, outL.data(), outR.data(), 256);
    assert(outL[220] < -0.05f);
    ss_destroy(layers);

    // Two simultaneous sample layers morph smoothly while a note is held.
    // CC11 expression must also respond continuously on the active voices.
    SSSampler *morph = ss_create(44100, 8);
    assert(morph);
    std::vector<float> soft(24000, .40f);
    std::vector<float> strong(24000, -.40f);
    assert(ss_add_zone(morph, 60, 48, 84, 1, 63, 44100,
                       soft.data(), nullptr, 24000));
    assert(ss_add_zone(morph, 60, 48, 84, 64, 127, 44100,
                       strong.data(), nullptr, 24000));
    assert(ss_set_cc1_crossfade(morph, 1));
    assert(ss_control_change(morph, 1, 10, 0));
    assert(ss_note_on(morph, 60, 100, 0));
    std::vector<float> morphL(6000), morphR(6000);
    ss_render(morph, morphL.data(), morphR.data(), 6000);
    assert(morphL[5999] > .04f); // quiet layer at low CC1
    assert(ss_control_change(morph, 1, 120, 0));
    ss_render(morph, morphL.data(), morphR.data(), 6000);
    assert(morphL[5999] < -.04f); // louder layer without retrigger
    assert(ss_control_change(morph, 11, 0, 0));
    ss_render(morph, morphL.data(), morphR.data(), 6000);
    assert(std::abs(morphL[5999]) < .001f); // held note faded by CC11
    assert(!ss_control_change(morph, 200, 30, 0));
    ss_destroy(morph);

    // ADSR: attack rises, decay reaches the sustain level, and note-off
    // releases progressively instead of stopping at a fixed 64-frame fade.
    SSSampler *adsr = ss_create(44100, 4);
    assert(adsr);
    std::vector<float> steady(30000, 1.f);
    assert(ss_add_zone(adsr, 60, 60, 60, 1, 127, 44100,
                       steady.data(), nullptr, 30000));
    assert(!ss_set_adsr(adsr, -.01f, .01f, .5f, .03f));
    assert(!ss_set_adsr(adsr, .01f, .01f, 1.2f, .03f));
    assert(ss_set_adsr(adsr, .01f, .02f, .4f, .04f));
    assert(ss_note_on(adsr, 60, 127, 0));
    std::vector<float> envL(4096), envR(4096);
    ss_render(adsr, envL.data(), envR.data(), 200);
    assert(envL[10] > 0.f && envL[10] < envL[150]);
    assert(envL[150] < .25f);
    ss_render(adsr, envL.data(), envR.data(), 2200);
    assert(std::abs(envL[2199] - .1f) < .001f);
    assert(ss_note_off(adsr, 60, 0));
    ss_render(adsr, envL.data(), envR.data(), 400);
    assert(envL[399] > 0.f && envL[399] < .1f);
    ss_render(adsr, envL.data(), envR.data(), 2048);
    for (int i = 1920; i < 2048; ++i) assert(envL[i] == 0.f);
    ss_destroy(adsr);

    // Sustain loops: a short recording must repeat while the note remains
    // held, then exit the loop and release naturally on MIDI note-off.
    SSSampler *loop = ss_create(44100, 4);
    assert(loop);
    std::vector<float> shortSample(128, .5f);
    assert(!ss_add_zone_with_loop(loop, 60, 60, 60, 1, 127, 44100,
                                  shortSample.data(), nullptr, 128,
                                  100, 80, 0));
    assert(!ss_add_zone_with_loop(loop, 60, 60, 60, 1, 127, 44100,
                                  shortSample.data(), nullptr, 128,
                                  32, 150, 0));
    assert(!ss_add_zone_with_loop(loop, 60, 60, 60, 1, 127, 44100,
                                  shortSample.data(), nullptr, 128,
                                  32, 96, 33));
    assert(!ss_add_zone_with_loop(loop, 60, 60, 60, 1, 127, 44100,
                                  shortSample.data(), nullptr, 128,
                                  0, 0, 1));
    assert(ss_add_zone_with_loop(loop, 60, 60, 60, 1, 127, 44100,
                                 shortSample.data(), nullptr, 128,
                                 32, 96, 16));
    assert(ss_note_on(loop, 60, 127, 0));
    std::vector<float> loopL(4096), loopR(4096);
    ss_render(loop, loopL.data(), loopR.data(), 4096);
    assert(loopL[4095] > .01f); // still sounding > 30 samples' worth
    for (int i = 1; i < 4096; ++i) {
        assert(std::isfinite(loopL[i]));
        assert(std::abs(loopL[i] - loopL[i-1]) < .1f);
    }
    assert(ss_note_off(loop, 60, 0));
    ss_render(loop, loopL.data(), loopR.data(), 512);
    assert(loopL[0] > 0.f);
    assert(loopL[511] == 0.f);
    ss_destroy(loop);

    // Nondestructive trim: playback starts inside the original PCM and ends
    // at the exclusive bound, without reading unwanted attack or tail frames.
    SSSampler *trim = ss_create(44100, 4);
    assert(trim);
    std::vector<float> source(512, -.6f);
    for (int i = 128; i < 384; ++i) source[i] = .6f;
    assert(!ss_add_zone_with_region(trim, 60, 60, 60, 1, 127, 44100,
               source.data(), nullptr, 512, 384, 128, 0, 0, 0));
    assert(!ss_add_zone_with_region(trim, 60, 60, 60, 1, 127, 44100,
               source.data(), nullptr, 512, 0, 600, 0, 0, 0));
    assert(!ss_add_zone_with_region(trim, 60, 60, 60, 1, 127, 44100,
               source.data(), nullptr, 512, 128, 384, 60, 300, 0));
    assert(ss_add_zone_with_region(trim, 60, 60, 60, 1, 127, 44100,
               source.data(), nullptr, 512, 128, 384, 0, 0, 0));
    assert(ss_note_on(trim, 60, 127, 0));
    std::vector<float> trimmedL(400), trimmedR(400);
    ss_render(trim, trimmedL.data(), trimmedR.data(), 400);
    assert(trimmedL[150] > .1f);
    for (int i = 257; i < 400; ++i) assert(trimmedL[i] == 0.f);
    ss_destroy(trim);

    // Trimmed sustain loop stays inside the audible region while held.
    SSSampler *trimLoop = ss_create(44100, 4);
    assert(trimLoop);
    assert(ss_add_zone_with_region(trimLoop, 60, 60, 60, 1, 127, 44100,
               source.data(), nullptr, 512, 128, 384, 200, 300, 12));
    assert(ss_note_on(trimLoop, 60, 127, 0));
    ss_render(trimLoop, trimmedL.data(), trimmedR.data(), 400);
    assert(trimmedL[380] > .05f);
    ss_destroy(trimLoop);

    // Source-relative fades operate within the trimmed playback region
    // rather than changing sample memory or the global ADSR settings.
    SSSampler *fades = ss_create(44100, 8);
    assert(fades);
    std::vector<float> fadeWave(2000, .6f);
    assert(!ss_add_zone_with_options(fades, 60, 60, 60, 1, 127,
        44100, fadeWave.data(), nullptr, 2000, 100, 1100,
        0, 0, 0, 800, 400, 0)); // fade sum exceeds trim length
    assert(ss_add_zone_with_options(fades, 60, 60, 60, 1, 127,
        44100, fadeWave.data(), nullptr, 2000, 100, 1100,
        0, 0, 0, 256, 256, 0));
    assert(ss_note_on(fades, 60, 127, 0));
    std::vector<float> fadeOut(1500), fadeOther(1500);
    ss_render(fades, fadeOut.data(), fadeOther.data(), 1500);
    assert(fadeOut[10] < fadeOut[220]);
    assert(fadeOut[600] > fadeOut[945]);
    assert(fadeOut[1200] == 0.f);
    assert(std::abs(fadeOut[600] - fadeOther[600]) < .00001f);
    ss_destroy(fades);

    // Active articulations are per MIDI channel and obey explicit keyswitch
    // priority. A keyswitch never plays sample audio itself.
    SSSampler *artic = ss_create(44100, 8);
    assert(artic);
    std::vector<float> held(4096, .8f);
    std::vector<float> shortHit(4096, -.8f);
    assert(ss_add_zone_with_options(artic, 60, 60, 60, 1, 127,
        44100, held.data(), nullptr, 4096, 0, 4096,
        0, 0, 0, 0, 0, 0));
    assert(ss_add_zone_with_options(artic, 60, 60, 60, 1, 127,
        44100, shortHit.data(), nullptr, 4096, 0, 4096,
        0, 0, 0, 0, 0, 1));
    uint8_t keys[] = {23, 24};
    uint8_t articulationIDs[] = {0, 1};
    assert(!ss_configure_keyswitches(artic, keys, articulationIDs, 17));
    assert(ss_configure_keyswitches(artic, keys, articulationIDs, 2));
    assert(!ss_select_articulation(artic, 16, 0));
    std::vector<float> output(512), other(512);
    assert(ss_note_on(artic, 24, 127, 0));
    ss_render(artic, output.data(), other.data(), 512);
    for (float value : output) assert(value == 0.f);
    assert(ss_note_on(artic, 60, 127, 0));
    ss_render(artic, output.data(), other.data(), 512);
    assert(output[400] < -.10f);
    assert(ss_note_off(artic, 60, 0));
    ss_render(artic, output.data(), other.data(), 512);
    // Return to sustain using its MIDI keyswitch, without mouse/UI calls.
    assert(ss_note_on(artic, 23, 127, 0));
    assert(ss_note_on(artic, 60, 127, 0));
    ss_render(artic, output.data(), other.data(), 512);
    assert(output[400] > .10f);
    // Channel 1 stays on its initial default articulation even after a
    // keyswitch on channel 0; changing channels does not mutate samples.
    assert(ss_note_off(artic, 60, 0));
    ss_render(artic, output.data(), other.data(), 512);
    assert(ss_note_on(artic, 60, 127, 1));
    ss_render(artic, output.data(), other.data(), 512);
    assert(output[400] > .10f);
    ss_destroy(artic);

    // Round-robin takes alternate; note-off releases are matched to the
    // note-on variation, not stacked or retriggered by duplicate note-offs.
    SSSampler *alternates = ss_create(44100, 8);
    assert(alternates);
    std::vector<float> attackA(2048, .6f), attackB(2048, -.6f);
    std::vector<float> releaseA(2048, .2f), releaseB(2048, -.2f);
    auto addTake = [&](const std::vector<float>& pcm, uint8_t rr, uint8_t release) {
        return ss_add_zone_with_variation(alternates, 60, 60, 60, 1, 127,
            44100, pcm.data(), nullptr, 2048, 0, 2048, 0, 0, 0,
            0, 0, 0, rr, release);
    };
    assert(!addTake(attackA, 8, 0)); // no out-of-range RR index
    assert(!addTake(attackA, 0, 2)); // release flag must be boolean
    assert(!ss_add_zone_with_variation(alternates, 60, 60, 60, 1, 127,
        44100, attackA.data(), nullptr, 2048, 0, 2048, 64, 1024, 0,
        0, 0, 0, 0, 1)); // release recordings cannot loop
    assert(addTake(attackA, 0, 0));
    assert(addTake(attackB, 1, 0));
    assert(addTake(releaseA, 0, 1));
    assert(addTake(releaseB, 1, 1));
    std::vector<float> alternatedL(4096), alternatedR(4096);
    assert(ss_note_off(alternates, 60, 0));
    ss_render(alternates, alternatedL.data(), alternatedR.data(), 512);
    for (int i = 0; i < 512; ++i) assert(alternatedL[i] == 0.f);
    for (int round = 0; round < 4; ++round) {
        assert(ss_note_on(alternates, 60, 120, 0));
        ss_render(alternates, alternatedL.data(), alternatedR.data(), 512);
        assert((round % 2 == 0) ? alternatedL[300] > .09f
                                : alternatedL[300] < -.09f);
        assert(ss_note_off(alternates, 60, 0));
        ss_render(alternates, alternatedL.data(), alternatedR.data(), 512);
        assert((round % 2 == 0) ? alternatedL[300] > .03f
                                : alternatedL[300] < -.03f);
        // No second note-off event may retrigger the release recording.
        assert(ss_note_off(alternates, 60, 0));
        ss_render(alternates, alternatedL.data(), alternatedR.data(), 3000);
        assert(alternatedL[2999] == 0.f);
    }
    assert(ss_all_notes_off(alternates));
    ss_render(alternates, alternatedL.data(), alternatedR.data(), 512);
    ss_destroy(alternates);

    // Panic/all-notes-off must never create a release-trigger voice.
    SSSampler *panic = ss_create(44100, 4);
    assert(panic);
    std::vector<float> tinyAttack(128, .4f);
    std::vector<float> longRelease(2048, .4f);
    assert(ss_add_zone_with_variation(panic, 60, 60, 60, 1, 127,
        44100, tinyAttack.data(), nullptr, 128, 0, 128, 0, 0, 0,
        0, 0, 0, 0, 0));
    assert(ss_add_zone_with_variation(panic, 60, 60, 60, 1, 127,
        44100, longRelease.data(), nullptr, 2048, 0, 2048, 0, 0, 0,
        0, 0, 0, 0, 1));
    assert(ss_note_on(panic, 60, 127, 2));
    ss_render(panic, alternatedL.data(), alternatedR.data(), 256);
    assert(ss_control_change(panic, 123, 0, 2));
    ss_render(panic, alternatedL.data(), alternatedR.data(), 512);
    assert(alternatedL[300] == 0.f);
    // A late note-off after channel panic cannot play its release sample.
    assert(ss_note_off(panic, 60, 2));
    ss_render(panic, alternatedL.data(), alternatedR.data(), 512);
    assert(alternatedL[300] == 0.f);
    ss_destroy(panic);

    ss_destroy(sampler);
    std::printf("Studio Sampler DSP smoke test passed (%.1f Hz)\n", frequency);
    return 0;
}
