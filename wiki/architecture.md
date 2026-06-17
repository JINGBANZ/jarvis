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
            │          capture_screen   │ speak(text)             │           │
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
   check carries *how long* you've been quiet and backs off across a long silence (e.g. 30s, 60s,
   120s, …), resetting on speech.
2. The CoachDriver calls the brain on **every** trigger — there is no cooldown, rate cap, or
   wake-word gate. Whether to speak (and whether the user just addressed Jarvis) is the model's
   call, governed by the system prompt; the only hard gate is the user's Start/Stop.
3. It calls **`gpt-5.5`** with the coach system prompt, the recent **timestamped** transcript
   window, the timing context (seconds silent, time on the problem), and the tool set
   `[capture_screen, speak]`. The timing is what lets the model tell "thinking" from "stuck."
4. The model may call `capture_screen`. The harness fulfills it (a silent screenshot) and
   returns the image into the conversation. The model may now reason over what's on screen.
5. The model either calls `speak(text)` — a ≤3-sentence tip — or returns nothing (stay silent).
6. `speak` renders to the **Overlay**, one sentence at a time, ~5 seconds each.

## 3. Components

| Component | Responsibility | Built on (borrowed) |
|---|---|---|
| **AudioInput** | Capture mic and (optionally) system audio; stream to the Transcriber. | AVFoundation (mic); ScreenCaptureKit (system audio). |
| **Transcriber** | Maintain a rolling, speaker-labeled, **timestamped** transcript; emit turn-end events and backing-off silence checks (with quiet duration). | `gpt-4o-transcribe` (Realtime API; tuned `server_vad`). |
| **CoachDriver** | The event loop. On every trigger, call the brain with the transcript + timing context and tools, route tool calls. No cooldown/rate cap — restraint is the model's. | `gpt-5.5` (vision + tool-use). |
| **ScreenTool** | Fulfill `capture_screen`: take a silent screenshot of the active display, excluding the overlay window. | macOS `screencapture` CLI. |
| **Overlay** | Render `speak` output: ≤3 sentences, ~5s each, non-activating, always-on-top, excluded from capture. | AppKit NSPanel. |
| **MenuBar** | Manual **Start/Stop** of the pipeline (two states: ⚪️ stopped / 🟢 running — no auto-start), status indicator, one-time API-key entry. | AppKit menu-bar item; Keychain for the key. |

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

Target: **turn-end → first overlay sentence < 2s.** It holds because transcription is continuous
(no STT latency at trigger time) and most turns are text-only (no `capture_screen`), so the brain
call is a single short round-trip. The overlay then reveals the already-returned sentences one at a
time (~5s each), so the first tip appears immediately — note the brain response itself is **not**
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
- **API key in the Keychain**, never plaintext on disk.
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
