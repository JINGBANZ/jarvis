#ifndef JARVIS_AEC_H
#define JARVIS_AEC_H

#include <stdint.h>

// Pure-C facade over the WebRTC AEC3 echo canceller. The C++ implementation
// (scripts/aec/jarvis_aec.cpp) is compiled and merged into libjarvis-aec.a by
// scripts/build-aec.sh, so this header pulls in NO webrtc/abseil headers and
// `swift build` compiles no C++ — it just links the prebuilt archive. This is
// the OS/native-bound edge for acoustic echo cancellation; the Swift wrapper
// (WebRTCEchoCanceller) lives in JarvisApp and resamples our 24 kHz wire format
// to the 48 kHz AEC3 wants and frames it into 10 ms blocks (see PCM16Framer).

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to a WebRTC AudioProcessing (AEC3) instance.
typedef struct JarvisAEC JarvisAEC;

// Create an AEC3 echo canceller for mono audio at `sample_rate_hz`. The WebRTC
// APM accepts only the native rates 8000/16000/32000/48000 Hz — NOT 24000 — so
// callers on the 24 kHz wire format must resample to 48000 before/after.
// Returns NULL on failure.
JarvisAEC *jarvis_aec_create(int sample_rate_hz);

// Feed one 10 ms far-end (reference / "them" / loudspeaker) mono int16 frame.
// `num_samples` must equal sample_rate_hz/100 (e.g. 480 at 48 kHz).
// Returns 0 on success, non-zero on error.
int jarvis_aec_process_reverse(JarvisAEC *aec, const int16_t *far_frame, int num_samples);

// Clean one 10 ms near-end (mic / "me") mono int16 frame IN PLACE, removing the
// echo of recently-registered far-end audio. `num_samples` = sample_rate_hz/100.
// Returns 0 on success, non-zero on error.
int jarvis_aec_process(JarvisAEC *aec, int16_t *near_frame, int num_samples);

// Destroy the handle.
void jarvis_aec_destroy(JarvisAEC *aec);

#ifdef __cplusplus
}
#endif

#endif // JARVIS_AEC_H
