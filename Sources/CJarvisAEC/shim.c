// SwiftPM compiles this dependency-free C facade while the actual WebRTC implementations live in
// the prebuilt archive. AEC3 already has its facade compiled into that archive; classic WebRTC VAD
// exposes a C API, so these small forwarding functions can be built here without vendored headers.
#include "jarvis_aec.h"

#include <stddef.h>
#include <stdlib.h>

typedef struct WebRtcVadInst VadInst;

extern VadInst *WebRtcVad_Create(void);
extern void WebRtcVad_Free(VadInst *handle);
extern int WebRtcVad_Init(VadInst *handle);
extern int WebRtcVad_set_mode(VadInst *handle, int mode);
extern int WebRtcVad_Process(VadInst *handle, int sample_rate_hz,
                             const int16_t *audio_frame, size_t frame_length);

struct JarvisVAD {
    VadInst *instance;
};

JarvisVAD *jarvis_vad_create(int mode) {
    if (mode < 0 || mode > 3) {
        return NULL;
    }
    JarvisVAD *vad = (JarvisVAD *)calloc(1, sizeof(JarvisVAD));
    if (vad == NULL) {
        return NULL;
    }
    vad->instance = WebRtcVad_Create();
    if (vad->instance == NULL || WebRtcVad_Init(vad->instance) != 0 ||
        WebRtcVad_set_mode(vad->instance, mode) != 0) {
        if (vad->instance != NULL) {
            WebRtcVad_Free(vad->instance);
        }
        free(vad);
        return NULL;
    }
    return vad;
}

int jarvis_vad_process(JarvisVAD *vad, int sample_rate_hz,
                       const int16_t *frame, int num_samples) {
    if (vad == NULL || vad->instance == NULL || frame == NULL || num_samples <= 0) {
        return -1;
    }
    return WebRtcVad_Process(vad->instance, sample_rate_hz, frame, (size_t)num_samples);
}

void jarvis_vad_destroy(JarvisVAD *vad) {
    if (vad == NULL) {
        return;
    }
    if (vad->instance != NULL) {
        WebRtcVad_Free(vad->instance);
    }
    free(vad);
}
