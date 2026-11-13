#ifndef STUDIO_SHARED_PCM_H
#define STUDIO_SHARED_PCM_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Immutable, planar Float32 audio, shared across independent native DSP
 * engines. Created/destroyed ONLY on control threads. The renderer may read
 * the returned pointers without locks while it retains its own reference.
 * Existing sampler/granular import APIs remain compatible. */
typedef struct SSSharedPCM SSSharedPCM;
SSSharedPCM* sspcm_create_copy(const float* left, const float* right,
                               uint32_t frames, double source_sample_rate);
SSSharedPCM* sspcm_retain(SSSharedPCM* pcm);
void sspcm_release(SSSharedPCM* pcm);
uint32_t sspcm_frames(const SSSharedPCM* pcm);
double sspcm_sample_rate(const SSSharedPCM* pcm);
const float* sspcm_left(const SSSharedPCM* pcm);
const float* sspcm_right(const SSSharedPCM* pcm);
const float* sspcm_mono(const SSSharedPCM* pcm);
/* Byte size accounts for resident channels plus precomputed mono downmix. */
uint64_t sspcm_resident_bytes(const SSSharedPCM* pcm);
#ifdef __cplusplus
}
#endif
#endif
