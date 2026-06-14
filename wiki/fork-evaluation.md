# Fork Evaluation — Can We Build on an Existing Open-Source App?

> Low-level, code-level evaluation of open-source apps as a fork base for the PoC (a proactive
> LeetCode coach). Each candidate was inspected at the source level (clone + read). Decision on
> which base — or whether to stay greenfield native Swift — is summarized in
> [status.md](./status.md#key-decisions). Companion to [landscape-survey.md](./landscape-survey.md).

## The PoC we're trying to reach by forking

Continuous transcription of mic + **both sides** of a call → a **proactive** decision to speak
(no hotkey; silence/timing-aware) → the model calls a **`capture_screen` tool on demand** →
short coaching tips (≤3 sentences) in an overlay. Brain `gpt-5.5`, transcription `gpt-realtime-2`.

## Universal findings (true of every candidate)

- **None have model tool/function-calling.** The OpenAI `capture_screen`-as-a-tool loop is net-new
  on every base (~1–2 days). It is therefore *not* a differentiator between them.
- **The hard macOS parts — both-sides system audio + the always-on-top, content-protected overlay
  — are already built** in the top three. That is the real time-save from forking.
- **All are Electron or Tauri**, because they are cross-platform *products* (Windows + macOS). See
  the note below on why none are native Swift. Forking means setting aside native Swift for the PoC.
- **All must be built/validated on a Mac** — the macOS audio/overlay can't be tested on Linux.

## Scores

| Base | Score | Both-sides audio | Already proactive? | OpenAI-native? | Tool-calling | Size / Maintenance | License |
|---|---|---|---|---|---|---|---|
| **Natively** | **4/5** | best (Core Audio tap + SCK, Rust napi) | **yes** (`maybeSpeculate`) | multi-provider, on `gpt-5.4` | none | ~115k LOC / **active (daily)** | AGPL-3.0 |
| **Glass** | **4/5** | real "Me/Them" diarization | partial (auto every 5 turns + clean hook) | **already OpenAI** (Realtime STT + chat) | none | ~27k LOC / stale ~8mo | GPL-3.0 |
| **Pluely** | **4/5** | Core Audio tap (Tauri/Rust) | no | BYOK curl + vision | none | ~26k LOC / stale ~5mo | GPL-3.0 |
| cheating-daddy | 3/5 | yes (opaque prebuilt binary) | no (Gemini-internal) | no (Gemini) | none | ~9k LOC / abandoned | GPL-3.0 |
| cheating-owo | 3/5 | mixed, no diarization | no | no (Gemini) | none | ~8k LOC / dormant | GPL-3.0 |
| Open-Cluely | 3/5 | **broken on macOS** (Win-only loopback) | no | no (Gemini/AssemblyAI) | none | ~12k LOC / thin | MIT (asserted) |

## Per-candidate notes

### Natively — strongest technical match
Already does proactive speak-up (`IntelligenceEngine.maybeSpeculate`, debounced + gated), the best
and **most current** both-sides audio (Rust native module via `cidre`: Core Audio process tap on
macOS 14.4+, ScreenCaptureKit fallback), a stealth NSPanel-style overlay, and a multi-provider LLM
layer **already defaulting to `gpt-5.4`** (one-line bump to `gpt-5.5`). It even has a screen-
understanding "decide" mode. **Cons:** AGPL-3.0 (network copyleft — fine for a personal tool, a
blocker for any closed product); very large, dense codebase (single files up to ~270–295 KB),
which is hard for an autonomous agent to navigate even though the change-sites are localized.

### Glass — best fit for our exact OpenAI stack (if its stale audio still works)
Already on OpenAI (Realtime transcription WS + chat completions), **real two-speaker diarization**
(separate `Me`/`Them` STT sessions), a clean proactive hook (`listenService.handleTranscription
Complete(speaker, text)`) plus an existing hotkey-free auto-trigger pattern, and `screencapture`
already isolated as a function (trivial to expose as the tool). A quarter the size of Natively.
**Cons:** ~8 months stale (mid-refactor), so the #1 task is proving its prebuilt `SystemAudioDump`
binary + native rebuilds still work on current macOS; GPL-3.0.

### Pluely — closest to "native," lightest
Tauri (Rust core + React), ~10 MB, a real **NSPanel** overlay (non-activating float + content
protection — literally our spec), Core Audio process tap for system audio. **Cons:** its STT is
batch/segment (Whisper-style upload), not streaming — so the realtime leg needs replacing for
`gpt-realtime-2`; no proactive layer; ~5 months stale against fast-moving Rust deps.

### Why the lower three are out
- **cheating-daddy / cheating-owo:** Gemini-fused single-session brain with no provider abstraction
  and no tool-calling — the entire intelligence layer is a rewrite. owo is strictly worse than its
  upstream (dormant, cosmetic-only changes).
- **Open-Cluely:** its system-audio method (`chromeMediaSource:'desktop'` loopback) **does not work
  on macOS** (Chromium delivers silence) — the single most important feature is broken on our target.

## Why are they all Electron/Tauri, not native Swift?

Not because Swift is worse for us — because **they are cross-platform commercial products**:

- They sell to **Windows and macOS** users; one Electron/web codebase ships both. Native Swift is
  macOS-only — a non-starter for that market.
- **Web UI velocity:** chat/overlay UIs are fast to build and style in HTML/CSS/React.
- **JS-first AI ecosystem** and a far larger JS/React contributor pool.
- The "stealth" overlay tricks (content protection, click-through, always-on-top) are well-trodden
  one-liners in Electron.

For a **personal, macOS-only** tool, the #1 driver (cross-platform) doesn't apply to us. The genuinely
hard capability — both-sides system audio — is a **native OS feature** (ScreenCaptureKit / Core Audio
taps); Natively literally drops to a Rust native module to reach it because Electron can't. In Swift
that capability is first-class. So native Swift loses nothing functionally on macOS and wins on
footprint, latency, and sandbox/permission cleanliness — which is exactly why we chose it for the
Phase-2 app (see [architecture.md](./architecture.md)). The live tension: **forking buys a fast PoC
on someone else's Electron body; native Swift
is the clean long-term app but slower to first demo.** A middle path is to use Natively's Rust audio
module + proactive loop as a *reference implementation* while building native Swift.

## Status

**Decided: two-phase build** — fork Natively for the Phase 1 PoC, then a clean native Swift app for
Phase 2 if it validates (see [status.md](./status.md#key-decisions)). Whatever the base, the
`capture_screen` tool-loop (and, except on Natively, the proactive trigger) is net-new.
