# Landscape Survey — What I Tried and Evaluated

> The record of existing tools and products considered before deciding to build. The conclusion
> drawn from this page is captured in [decision 0001](./decisions/0001-build-vs-buy.md).

## The Requirement Being Tested

A *proactive* assistant: it speaks up **unprompted** based on what it hears (mic + system audio)
and sees (screen), rather than only answering a hotkey. Everything below is measured against that.

## Tried Hands-On

| Tool | Verdict | What happened |
|---|---|---|
| **Cluely** ([cluely.com](https://cluely.com/)) | ✗ Rejected | The category leader, but **hotkey-only** (Cmd+Enter) — not proactive. Real-world latency 5–10s; "doesn't feel like someone is working with me." Confirmed by reviews. This is what convinced me proactivity is a must-have. |
| **cheating-daddy** ([sohzm/cheating-daddy](https://github.com/sohzm/cheating-daddy)) | ✗ Rejected | The only open tool with auto-answer behavior. In practice it **didn't respond at all**. Discord is full of unanswered help requests; founder appears absent. **Gemini-only**, very limited. Effectively abandoned. |
| **Highlight AI** ([highlightai.com](https://highlightai.com/)) | ✗ Unavailable | **Waitlist-only** — can't even try it. |

## Evaluated (Not Adopted)

| Tool | Proactive? | Why not |
|---|---|---|
| **Pluely** ([iamsrikanthnani/pluely](https://github.com/iamsrikanthnani/pluely)) | No (hotkey) | **Stale** — last commit ~5 months ago. |
| **Glass** ([pickle-com/glass](https://github.com/pickle-com/glass)) | Partial | **Stale** — last commit ~8 months ago. GPL. |
| **Hedy AI** ([hedy.ai](https://www.hedy.ai/)) | Yes | The only finished product that genuinely does proactive coaching during calls — but **closed-source**, and oriented toward **business meeting notes/coaching**, not a Jarvis-like general assistant. |
| **Omi** ([BasedHardware/omi](https://github.com/BasedHardware/omi)) | Yes (framework) | MIT, very active, has a real `proactive_notification` webhook framework. But the experience is built around a **hardware pendant** — not what I want. Kept only as a *design reference* for the proactive pattern. |
| **Natively** ([Natively-AI-assistant](https://github.com/Natively-AI-assistant/natively-cluely-ai-assistant)) | No (hotkey) | Reactive, but has the **best both-sides macOS system-audio capture** reference code (Rust). Pattern reference only. |
| **screenpipe** ([mediar-ai/screenpipe](https://github.com/mediar-ai/screenpipe)) | No | Strong 24/7 capture engine, but **source-available (non-MIT)**, no live overlay. Infrastructure, not an assistant. |
| **OpenAGI** ([spshulem/openAGI](https://github.com/spshulem/openAGI)) | Yes | Proactive, but **screen-only (no audio)** and brand-new/unproven. Its "Adaptive Scrutiny" interjection gate is a nice reference for *when to speak up*. |
| **OpenClaw** ([openclaw.ai](https://openclaw.ai/)) | Time-based | A computer-use **task agent** (does things for you); its "heartbeat" is scheduled, not event-driven interjection. Different paradigm. (Not the 1997 game of the same name.) |

## Building Blocks Confirmed Available (so we don't reinvent them)

- **Screen capture:** macOS built-in `screencapture` CLI; ScreenCaptureKit (screen + system audio).
- **OCR (if needed):** Apple Vision `RecognizeTextRequest` (on-device).
- **Transcription:** OpenAI Realtime API (semantic VAD gives turn-end detection for free).
- **Overlay:** AppKit NSPanel (non-activating, floating, can exclude itself from capture).
- **Brain:** GPT-5.5 with tool-use.

## Conclusion

No maintained, open-source tool does turnkey proactive, unprompted speak-up from live audio +
screen. The proactive options are either hardware-bound (Omi), unproven/screen-only (OpenAGI), or
closed and meeting-oriented (Hedy). The reactive tools are stale or single-purpose. The gap is real
— and small enough to fill with a thin harness over OpenAI + Apple frameworks. → [0001](./decisions/0001-build-vs-buy.md).
