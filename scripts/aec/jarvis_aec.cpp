// C++ implementation of the pure-C jarvis_aec.h facade, wrapping WebRTC AEC3.
// Compiled and merged into libjarvis-aec.a by scripts/build-aec.sh — it is NOT
// part of any SwiftPM target (it needs the webrtc/abseil headers, which we don't
// vendor). Keep it in lockstep with Sources/CJarvisAEC/include/jarvis_aec.h.
//
// Config rationale: we enable ONLY the echo canceller (AEC3, desktop mode) plus
// the high-pass filter that aids it. Noise suppression and automatic gain
// control are left OFF on purpose — they would alter the user's own voice, and
// the only job here is to subtract the other side's audio that leaks off the
// speakers into the mic. The far-end reference is the system audio we already
// capture cleanly, so AEC3 has an ideal reference and removes the bleed before
// transcription (no headphones required).

#include "jarvis_aec.h"

#include "api/audio/audio_processing.h"
#include "api/scoped_refptr.h"

struct JarvisAEC {
  rtc::scoped_refptr<webrtc::AudioProcessing> apm;
  webrtc::StreamConfig stream_config;
  int frame_size; // samples per 10 ms frame
};

extern "C" {

JarvisAEC *jarvis_aec_create(int sample_rate_hz) {
  webrtc::AudioProcessing::Config config;
  config.echo_canceller.enabled = true;   // AEC3
  config.echo_canceller.mobile_mode = false;
  config.high_pass_filter.enabled = true;
  // Intentionally NOT enabled: noise_suppression, gain_controller* — they would
  // distort the user's own voice for the transcriber.

  rtc::scoped_refptr<webrtc::AudioProcessing> apm =
      webrtc::AudioProcessingBuilder().SetConfig(config).Create();
  if (!apm) {
    return nullptr;
  }

  JarvisAEC *h = new JarvisAEC();
  h->apm = apm;
  h->stream_config = webrtc::StreamConfig(sample_rate_hz, /*num_channels=*/1);
  h->frame_size = sample_rate_hz / 100; // 10 ms
  return h;
}

int jarvis_aec_process_reverse(JarvisAEC *h, const int16_t *far_frame, int num_samples) {
  if (!h || num_samples != h->frame_size) {
    return -1;
  }
  // ProcessReverseStream may write to dest; let it write back over the input
  // (we only need the reference registered, not the processed render output).
  int16_t *dest = const_cast<int16_t *>(far_frame);
  return h->apm->ProcessReverseStream(far_frame, h->stream_config, h->stream_config, dest);
}

int jarvis_aec_process(JarvisAEC *h, int16_t *near_frame, int num_samples) {
  if (!h || num_samples != h->frame_size) {
    return -1;
  }
  // In-place clean: src and dest may share memory.
  return h->apm->ProcessStream(near_frame, h->stream_config, h->stream_config, near_frame);
}

void jarvis_aec_destroy(JarvisAEC *h) { delete h; } // scoped_refptr releases the APM

} // extern "C"
