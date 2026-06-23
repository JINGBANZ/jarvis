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

### On-demand hint (⌥⌘J)

Proactive coaching is the default, but the user can also **pull** a hint on demand. Pressing the
global hotkey **⌥⌘J** while a session is running fires a `manualHint` trigger that does in **one**
brain round-trip what the proactive screen path needs two for: the harness captures the screenshot
*itself* and injects it — plus a synthetic "give me a hint now" user message — into the *first*
request, and forces the `speak` tool, so a screen-aware hint always comes straight back. (The
proactive path, by contrast, must first let the model decide to call `capture_screen`, then reason
over the returned image on a second trip — the latency this hotkey exists to skip.) It reuses the
live session's brain, conversation, and transcript, so the hint has full context, and it routes
through the same single-in-flight turn box as audio triggers (a press coalesces, never stacks). It is
inert — a beep — when no session is running, since there is no live conversation to hint from. In dev
mode the trigger and its pre-filled message are recorded to the [activity viewer](./build-and-run.md),
so you can see exactly what the shortcut sent to the brain.

The hotkey is registered with **Carbon `RegisterEventHotKey`**, the one global-shortcut API Apple
never modernized, which needs no Accessibility/TCC permission. We deliberately did **not** take the
`KeyboardShortcuts` package: every modern release uses SwiftUI macros (`@Entry`/`#Preview`) whose
plugins ship only with full Xcode, and Jarvis builds **CLT-only** (see
[build-and-run.md](./build-and-run.md)). The binding is fixed for now; a rebinding UI is a later nicety.

## 3. Components

| Component | Responsibility | Built on (borrowed) |
|---|---|---|
| **AggregateEchoCapture** | The whole capture path: one **private Core Audio aggregate device** = the built-in mic (`me`, clock master) + a system-output **process tap** (`them`, drift-compensated onto the mic's clock). A single IOProc delivers both sample-synced at the device's **native rate** — the one-clock case AEC3 needs; the capture **reads that rate and resamples mic+tap up to 48 kHz** for AEC3 (a no-op when the device is already 48 kHz). So **any input device works** — built-in, USB, 44.1 kHz gear, or AirPods (Bluetooth HFP at 16/24 kHz) — instead of the old hard 48 kHz pin that silently failed to start on Bluetooth mics. Inside the callback it runs AEC3 (tap = far reference, mic = near), removing the other side's speaker bleed from the mic *before* transcription — no headphones, and double-talk works (measured 30–50 dB cancellation). Then downsamples to 24 kHz: cleaned mic → `me` socket, raw tap → `them` socket. Replaces the old separate `AVAudioEngine` mic + `SCStream`. | Core Audio (`AudioHardwareCreateProcessTap`, private aggregate device, drift compensation) + `AVAudioConverter` resampling + WebRTC **AEC3**. |
| **WebRTCEchoCanceller** | AEC3 echo canceller driven at 48 kHz on 10 ms frames inside the capture IOProc; far reference first, then the mic cleaned in place. | WebRTC **AEC3** (`webrtc-audio-processing`), vendored static + zero-dylib via `scripts/build-aec.sh`. |
| **ErrorReporter** | The single funnel for user-facing failures. Severity on a Foundation-only `UserFacingError` (in Core) decides the response — `fatal` pops an `NSAlert` and tears the session down, `degraded`/`info` are logged only — so no startup failure is ever silent. The only place `NSAlert` is created; diagnostics stay in `JarvisLog`. | AppKit (`NSAlert`). |
| **Transcriber** | Maintain a rolling, speaker-labeled, **timestamped** transcript; emit turn-end events and backing-off silence checks (with quiet duration). Two instances run in parallel — one per side — tagging lines `me`/`them` into one shared transcript. | `gpt-4o-transcribe` (Realtime API; tuned `server_vad`). |
| **CoachDriver** | The event loop. On every trigger, call the brain with the transcript + timing context and tools, route tool calls. No cooldown/rate cap — restraint is the model's. | `gpt-5.5` (vision + tool-use). |
| **ScreenTool** | Fulfill `capture_screen`: take a silent screenshot of the active display, excluding the overlay window. | macOS `screencapture` CLI. |
| **Overlay Caption** | Render `speak` output: up to ~3 short lines (model-split), shown one at a time and queued so a newer tip never cuts off the current one; non-activating, always-on-top, excluded from capture. Switchable from Settings — **off by default**; when off, tips are suppressed. | AppKit NSPanel; `OverlayCaptionPanel`. |
| **Overlay Box** | A persistent window logging every `speak` tip in full, timestamped — the scrollable history of what the caption flashed one line at a time. Movable, resizable, opaque, also excluded from capture; switched on/off from Settings (**on by default**), cleared on each Start. Fed by the same `speak` call as the caption via **`BroadcastOverlay`**, which fans one `OverlayRendering.render` out to both sinks (so `CoachDriver` is unchanged). | AppKit NSPanel; `OverlayBoxPanel`. |
| **MenuBar** | Manual **Start/Stop** of the pipeline (two states: ⚪️ stopped / 🟢 running — no auto-start), status indicator, one-time API-key entry. The two overlay surfaces are switched from Settings, not the menu. | AppKit menu-bar item; owner-only file for the key. |
| **HotkeyController** | Register the global **⌥⌘J** hint hotkey and route a press to a one-trip `manualHint` turn while a session runs (beep otherwise). See [§2 On-demand hint](#on-demand-hint-j). | Carbon HIToolbox (`RegisterEventHotKey`, no TCC). |

Each component has one job and a narrow interface. The CoachDriver is the only place the
"intelligence" lives, and even there the intelligence is the model — the driver just wires events
to tool calls and enforces safety.

### Capture: device-rate adaptation

`AggregateEchoCapture` reads the input device's native sample rate and resamples up to AEC3's
48 kHz, rather than forcing the aggregate to 48 kHz. The earlier hard **pin** existed for two
reasons — AEC3 is created at a fixed 48 kHz, and the 48→24 kHz wire downsampler assumes a true
48 kHz input — so an aggregate that inherited a 44.1 kHz mic would corrupt the echo model and
mislabel the wire rate. But the pin **silently failed to start** on any device that can't do
48 kHz, notably AirPods (Bluetooth HFP runs them at 16/24 kHz). Reading-and-resampling serves both
original concerns *better* (AEC3 always gets true 48 kHz; the wire label stays correct) and works on
every device. The **one-clock aggregate is untouched** — the pin was about *rate*, not the clock;
mic and tap still come off one drift-compensated IOProc, so they stay sample-synced and the far/near
lockstep (now applied post-resample) holds. If the rate can't be read we fail rather than assume.

Alternatives rejected: running AEC at the device's *native* rate doesn't generalize (24/44.1 kHz
aren't AEC3-legal, so you resample anyway, with a variable frame size in the most delicate
component); and **bypassing AEC on "headphone" routes** is unsafe because a Bluetooth *speaker* is
indistinguishable from a headset, so a wrong bypass re-admits the echo. AEC3 therefore stays on for
all routes — it's a near-passthrough on earbuds (no acoustic echo to cancel). Caveat: AirPods *as a
mic* are HFP narrowband and low-fidelity regardless of resampling; for input quality, use the
built-in mic.

### Failure surfacing — fail loud

Every user-facing failure flows through one `ErrorReporter`: severity on a Foundation-only
`UserFacingError` decides the response (`fatal` → `NSAlert` + session teardown; `degraded`/`info` →
log only), so a startup failure can never again flip the menu green and silently revert. Per-failure
copy and severity live in a Core **catalog** (`UserFacingError+Catalog`), the single source of truth
for *which* failures are loud — unit-tested in Core (e.g. the system-audio degrade must stay quiet),
since `JarvisApp` itself can't be headlessly tested and the `NSAlert` display stays a manual smoke
check. Diagnostics remain `JarvisLog`'s job; `ErrorReporter` owns surfacing + lifecycle consequence.

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

Target: **turn-end → first overlay line < 2s.** It holds because transcription is continuous
(no STT latency at trigger time) and most turns are text-only (no `capture_screen`), so the brain
call is a single short round-trip. The overlay then reveals the already-returned lines one at a
time (paced by `Config`), so the first tip appears immediately — note the brain response itself is **not**
streamed (one buffered request; the overlay just paces the display).

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
  in the transcript, which the brain reads and answers — there is no wake-word detector. (A global
  **⌥⌘J** hotkey for an on-demand screen hint *does* exist — see [§2](#on-demand-hint-j) — but it
  complements the proactive default; it is not a trigger-to-listen wake key.)
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
