# Architecture

> A living document. Describes the vision, the harness loop, the components, and the principles
> that govern Jarvis. Exact schemas, prompts, and config are not duplicated here — they live in
> `Sources/JarvisCore/` (`ToolDefs.swift`, `Config.swift`, `CoachDriver.swift`).

> **Scope:** This page describes the **native Swift app** — the thing being built. The earlier
> two-phase plan (a Natively fork PoC first) was **dropped on 2026-06-14**; we build this directly,
> including the model-triggered `capture_screen` tool-loop. See [status.md](./status.md#key-decisions).
> Exact schemas, the coach prompt, and config are **not duplicated here** — they live in code
> (`Sources/JarvisCore/`, esp. `ToolDefs.swift`, `Config.swift`, `CoachDriver.swift`); this page is
> the *why*, the code is the *what*.

## 1. Vision

Jarvis is a personal, always-on macOS assistant that **coaches you through a LeetCode problem**.
It listens to you think aloud, and — when it decides it needs to — looks at your screen to see
the problem statement and your code. When it has something genuinely useful to add, it speaks up
**unprompted** with a short tip rendered in an on-screen overlay.

The guiding belief: **build the harness, not the intelligence.** The intelligence already exists
(`gpt-5.5`, the `gpt-4o-transcribe` model on the OpenAI Realtime API). The macOS capabilities already exist (ScreenCaptureKit,
AVFoundation, Vision, the built-in `screencapture` tool, NSPanel). Jarvis is the thin layer of
glue that wires them into a proactive coach. We write the least code possible and reinvent nothing.

## 2. Core Loop

```
            ┌──────────────────────────────────────────────────────────────┐
            │                         JARVIS HARNESS                         │
            │                                                                │
  mic  ─────┤  AudioInput ──► Transcriber (gpt-4o-transcribe) ──► transcript    │
  sys-audio ┤                          │ turn-end / silence events           │
            │                          ▼                                      │
            │                    CoachDriver ──(gpt-5.5 + tools)──┐           │
            │                       ▲   │                         │           │
            │          capture_screen   │ speak(lines)            │           │
            │                       │   ▼                         │           │
  screen ◄──┤   ScreenTool ◄────────┘  Overlay (NSPanel) ◄────────┘           │
            │                                                                │
            └──────────────────────────────────────────────────────────────┘
```

Always-on and cheap: audio streams continuously to the Realtime API, producing a rolling,
speaker-labeled transcript. The transcript — not the screen — is the constant input signal.

On demand and expensive: the screen is **only** captured when the model asks for it via the
`capture_screen` tool, and a coaching response is **only** produced when the model calls `speak`.
This is what keeps Jarvis cheap and fast — the costly vision and generation steps fire only at
moments the model judges worthwhile.

### The turn

1. The Transcriber emits a **turn-end** event (`gpt-4o-transcribe` server VAD ends the turn after a
   tuned silence window) or a **silence check** fires (you've gone quiet, maybe stuck). The silence
   check carries *how long* you've been quiet and backs off across a long silence (the interval
   doubles each step up to a cap — see `Config`), resetting on speech.
2. The CoachDriver calls the brain on **every** trigger — there is no cooldown, rate cap, or
   wake-word gate. Whether to speak (and whether the user just addressed Jarvis) is the model's
   call, governed by the system prompt; the only hard gate is the user's Start/Stop.
3. It calls **`gpt-5.5`** with the coach system prompt, the recent **timestamped** transcript
   window, the timing context (seconds silent, session elapsed), and the tool set
   `[capture_screen, speak]`. The timing is what lets the model tell "thinking" from "stuck."
4. The model may call `capture_screen`. The harness fulfills it (a silent screenshot) and
   returns the image into the conversation. The model may now reason over what's on screen.
5. The model either calls `speak(lines)` — a tip of up to ~3 short lines, returned **already split**
   into an array (Structured Outputs / `strict:true`), so the client never splits prose on
   punctuation — or returns nothing (stay silent).
6. `speak` renders to the **Overlay**, one line at a time (per-line display time set in `Config`).
   A newer tip never interrupts one still showing — tips queue and play in order, so no hint is lost.

**Why the overlay never interrupts and never drops (and why direct-reply latency is a non-issue).**
The queue is deliberately strict: a tip the user may still be reading is never cut off, and nothing
is discarded. The obvious objection — "a direct *'Jarvis, help'* reply could wait tens of seconds
behind a proactive tip" — does not apply in the real use case: **in a live interview the user never
addresses Jarvis out loud** (speaking to an AI would expose it), so overlay traffic is *entirely
proactive coaching* with no latency-critical direct reply to jump the queue. The accepted tradeoff is
that a queued proactive tip can surface some seconds after it was generated; that is bounded in
practice because `CoachDriver` runs a single turn in-flight (so tips are produced no faster than one
brain round-trip) and the prompt keeps the model restrained. So the policy is *not interrupt + not
drop*, not *show-freshest-only* — and adding direct-reply priority/preemption was considered and
rejected as solving a problem the interview workflow doesn't have. (The must-reply-on-direct-address
path still works for testing/practice; it is simply not latency-critical there.)

## 3. Components

| Component | Responsibility | Built on (borrowed) |
|---|---|---|
| **AggregateEchoCapture** | The whole capture path: one **private Core Audio aggregate device** = the built-in mic (`me`, clock master) + a system-output **process tap** (`them`, drift-compensated onto the mic's clock). A single IOProc delivers both, sample-synced at 48 kHz — the one-clock case AEC3 needs. Inside that callback it runs AEC3 (tap = far reference, mic = near), removing the other side's speaker bleed from the mic *before* transcription — no headphones, and double-talk works (measured 30–50 dB cancellation). Then downsamples to 24 kHz: cleaned mic → `me` socket, raw tap → `them` socket. Replaces the old separate `AVAudioEngine` mic + `SCStream`. | Core Audio (`AudioHardwareCreateProcessTap`, private aggregate device, drift compensation) + WebRTC **AEC3**. |
| **WebRTCEchoCanceller** | AEC3 echo canceller driven at 48 kHz on 10 ms frames inside the capture IOProc; far reference first, then the mic cleaned in place. | WebRTC **AEC3** (`webrtc-audio-processing`), vendored static + zero-dylib via `scripts/build-aec.sh`. |
| **Transcriber** | Maintain a rolling, speaker-labeled, **timestamped** transcript; emit turn-end events and backing-off silence checks (with quiet duration). Two instances run in parallel — one per side — tagging lines `me`/`them` into one shared transcript. | `gpt-4o-transcribe` (Realtime API; tuned `server_vad`). |
| **CoachDriver** | The event loop. On every trigger, call the brain with the transcript + timing context and tools, route tool calls. No cooldown/rate cap — restraint is the model's. | `gpt-5.5` (vision + tool-use). |
| **ScreenTool** | Fulfill `capture_screen`: take a silent screenshot of the active display, excluding the overlay window. | macOS `screencapture` CLI. |
| **Overlay** | Render `speak` output: up to ~3 short lines (model-split), shown one at a time and queued so a newer tip never cuts off the current one; non-activating, always-on-top, excluded from capture. | AppKit NSPanel. |
| **Response box** | An optional persistent window logging every `speak` tip in full, timestamped — the scrollable history of what the overlay flashed one line at a time. Movable, resizable, opaque, also excluded from capture; toggled from the menu bar, cleared on each Start. Fed by the same `speak` call as the overlay via **`BroadcastOverlay`**, which fans one `OverlayRendering.render` out to both sinks (so `CoachDriver` is unchanged). | AppKit NSPanel; `ResponseLogPanel`. |
| **MenuBar** | Manual **Start/Stop** of the pipeline (two states: ⚪️ stopped / 🟢 running — no auto-start), a **Show/Hide Responses** toggle, status indicator, one-time API-key entry. | AppKit menu-bar item; owner-only file for the key. |

Each component has one job and a narrow interface. The CoachDriver is the only place the
"intelligence" lives, and even there the intelligence is the model — the driver just wires events
to tool calls and enforces safety.

## 4. Data Flow & Cost Model

- **Continuous (cheap):** audio → Realtime → transcript. This runs the whole session.
- **Per-turn (cheap):** a text-only `gpt-5.5` call on each turn-end/silence event. No image unless
  the model asks.
- **On-demand (expensive):** a screenshot + vision tokens, only when the model calls
  `capture_screen`. A coaching response, only when the model calls `speak`.

The model is the cost governor: it spends vision tokens and screen real estate only when it
judges them worthwhile. That is the whole point of making screen capture a model-invoked tool
rather than a per-turn screenshot.

### Models and APIs

- **Brain — `gpt-5.5` via the OpenAI Responses API** (`POST /v1/responses`), not Chat Completions:
  for the gpt-5 family, function/tool calling is the recommended (and least restricted) path on
  Responses. The tool loop is threaded with `function_call` / `function_call_output` items.
- **Per-session memory — the Conversations API.** The coach needs to remember its *own* prior
  replies (the transcript only holds user speech), so the brain opens one server-side conversation
  per Start (`store:true`) and sends only the **new** transcript lines each turn — the server holds
  the rest. (If the conversation can't be created, `CoachDriver` falls back to a **stateless** mode
  that re-sends a recent transcript *window* every turn.) The retention tradeoff this creates
  (transcript + screenshots retained ~30 days at OpenAI) is a deliberate quality-over-privacy choice,
  documented in [sandbox.md](./sandbox.md).
- **Transcription — `gpt-4o-transcribe` over the GA Realtime API** with **tuned `server_vad`** (not
  `semantic_vad`, which is reported flaky in transcription-only mode — it can stop emitting
  `…transcription.completed` entirely). Turn-end fires on `…transcription.completed`, plus a
  client-side debounce so a brief mid-thought pause doesn't fragment one sentence into several turns.

### Latency

Measured **turn-end → first overlay line** (this metric excludes the VAD/debounce window that
*precedes* turn-end). Two paths, with very different costs:

- **Text-only turn** (no screen): a single short `gpt-5.5` round-trip — **< 2s**, and snappier now
  that the answer streams. Transcription is continuous, so there's no STT latency at trigger time.
- **Screen question** (the model calls `capture_screen`): inherently **two sequential brain calls** —
  decide-it-needs-the-screen, then answer-with-the-image — because screen capture is *model-decided*
  (§4), not attached to every call. Left naive this ran ~10s end-to-end; three changes cut a screen
  question to **≈ 2–3s (turn-end → first spoken word)**, ~3.5–4.5s including the talk-detection
  window, *without* removing the round-trip or changing `speak`:
  1. **Capture overlaps the first call** — `CoachDriver` pre-warms the screenshot when the turn fires,
     concurrently with brain call #1, so it's already in hand the instant the model asks (and dropped,
     never written to disk, if the model never asks).
  2. **The answer streams to the overlay** — the brain call is read as an SSE stream (`stream:true`)
     and each `speak` line renders the moment it finishes generating (incrementally parsed in
     `SpeakLinesStreamParser`), so first words appear ~1–2s into the answer instead of after the whole
     response. `speak` stays a tool call: the final `BrainResponse` is still decoded from the terminal
     event (byte-identical to the non-streamed result), and the overlay's queue/pacing is unchanged
     (each streamed line is just a queued one-line tip).
  3. **A decisive capture decision** — the coach prompt tells the model to decide on the first turn
     whether it needs the screen and call `capture_screen` immediately, rather than answer-from-memory-
     then-look.

  The remaining floor — two model passes plus the VAD/debounce "are-you-done-talking" window — is
  structural and accepted. Going lower would mean relaxing a kept constraint (pre-attaching the screen,
  or trimming the VAD floor), deferred until the latency demands it.
- **Full-resolution screenshots are kept** (no downscaling): GPT-5.5 reads the shot at full `original`
  resolution by default, and the vision docs *recommend* `original` for large/dense images, so
  reliable code-reading outweighs the upload saving. The brain response is now streamed (the earlier
  "not streamed" note no longer holds). Implementation: `CoachDriver.swift`, `OpenAIBrainClient.swift`,
  `SpeakLinesStreamParser.swift`.

### Resilience

The always-on legs are built to survive transient failure rather than die on it:

- **The realtime transcription socket *will* drop** (network blips, server resets, the ~60-min
  session cap) and a Realtime session **cannot be resumed** — a dropped connection means a new
  session. So instead of discarding mic audio during the reconnect gap, the transcriber **buffers it**
  (`PCMBuffer`, capped at `maxBufferedAudioSeconds`, oldest evicted) and **flushes it into the new
  session on reconnect** — a mid-sentence drop no longer loses the user's words. Reconnect uses
  capped exponential backoff with a ping keepalive.
- **The brain call** retries 429/5xx with bounded backoff (honoring `Retry-After`) under a request
  timeout, and the coach loop is single-flighted so a turn can't double-speak.

## 5. Safety Model

Enforcement-first, not convention. See [sandbox.md](./sandbox.md) for the full model. In short:

- **App Sandbox** with only the entitlements it needs (screen recording, audio input), giving
  **no general filesystem access** — the hardened posture for a shippable build. *For the current
  personal build this is relaxed:* the app is unsandboxed and signed with a stable self-signed
  identity (`Jarvis Dev`, so grants persist), relying on macOS **TCC prompts** for Screen Recording
  + Microphone. It can therefore technically read the user's files;
  that tradeoff is accepted for the personal tool. See [sandbox.md](./sandbox.md).
- **API key in an owner-only file** (`0600`), not the Keychain — see [sandbox.md §3](./sandbox.md) for why.
- **Built and run in the main `forrest` account inside a git worktree** (recoverability). The
  separate-restricted-account requirement is waived for the personal build; see [sandbox.md](./sandbox.md).
- **Egress is narrow and explicit:** audio to `gpt-4o-transcribe`; a screenshot + transcript window
  to `gpt-5.5` *only when the model triggers a capture/response*. Nothing is recorded to **local**
  disk in the MVP; the per-session OpenAI conversation does retain transcript + screenshots
  server-side (see [sandbox.md](./sandbox.md)).
- **Behavioral restraint (model-governed):** there is **no cooldown or rate cap** in code. Every
  utterance reaches the brain, and the brain decides whether it has anything worth saying — that
  restraint lives in the system prompt ("stay silent unless genuinely useful"). This keeps
  conversation natural: a follow-up question is never stranded behind a timer. The hard control is
  the menu-bar **Start/Stop** — coaching never runs until explicitly started, and stopping tears the
  pipeline down entirely. A session interjection counter in the menu bar makes over-talking visible;
  cost is accepted as tracking usage for now (a future improvement, not a v1 guardrail).

## 6. Non-Goals (v1)

- Multiple modes / a tiered sensitivity dial. (One mode: LeetCode Coach.)
- Continuous OCR or recording the screen/audio to disk ("recall").
- A dedicated wake-word engine. Direct address is just the word "Jarvis" (or a question) appearing
  in the transcript, which the brain reads and answers — there is no separate detector or hotkey.
- Productization: auth, billing, onboarding, multi-provider.
- Windows / cross-platform.

## 7. Design Principles

1. **Build the harness, not the intelligence.** If a model or an OS framework can do it, we don't write it.
2. **Least code wins.** Prefer a borrowed tool (`screencapture`, an Apple framework, an OpenAI API) over custom code, every time.
3. **The model is the cost governor.** Expensive actions (vision, speaking) happen only when the model opts in.
4. **Proactive, but disciplined.** Speaking up unprompted is the whole point; the model's own restraint (a tuned system prompt) keeps it from being annoying.
5. **Sees the screen, not the disk.** Security is enforced by the sandbox, not by good intentions.
6. **Self-verifying.** Every build ships with tests and a smoke checklist the agent can run to prove it works.
7. **One mode, done well.** Ship the coach; expand later.

How Jarvis is built, signed, tested, and run — and the dev-mode activity viewer — is its own
operational page: [build-and-run.md](./build-and-run.md).
