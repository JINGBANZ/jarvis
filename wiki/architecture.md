# Architecture

> A living document. Describes the vision, the harness loop, the components, and the principles
> that govern Jarvis. For exact schemas, prompts, and config, see [specification.md](./specification.md).

## 1. Vision

Jarvis is a personal, always-on macOS assistant that **coaches you through a LeetCode problem**.
It listens to you think aloud, and — when it decides it needs to — looks at your screen to see
the problem statement and your code. When it has something genuinely useful to add, it speaks up
**unprompted** with a short tip rendered in an on-screen overlay.

The guiding belief: **build the harness, not the intelligence.** The intelligence already exists
(`gpt-5.5`, the `gpt-realtime-2` model on the OpenAI Realtime API). The macOS capabilities already exist (ScreenCaptureKit,
AVFoundation, Vision, the built-in `screencapture` tool, NSPanel). Jarvis is the thin layer of
glue that wires them into a proactive coach. We write the least code possible and reinvent nothing.

## 2. Core Loop

```
            ┌──────────────────────────────────────────────────────────────┐
            │                         JARVIS HARNESS                         │
            │                                                                │
  mic  ─────┤  AudioInput ──► Transcriber (gpt-realtime-2) ──► transcript    │
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

1. The Transcriber emits a **turn-end** event (`gpt-realtime-2` semantic VAD — "the speaker
   finished a thought") or a **silence-timeout** fires (you've gone quiet, maybe stuck). The
   silence event carries *how long* you've been quiet.
2. The CoachDriver checks its guardrails (mute? within cooldown? under the rate cap?). If
   blocked, it does nothing.
3. Otherwise it calls **`gpt-5.5`** with the coach system prompt, the recent **timestamped**
   transcript window, the timing context (seconds silent, time on the problem), and the tool set
   `[capture_screen, speak]`. The timing is what lets the model tell "thinking" from "stuck."
4. The model may call `capture_screen`. The harness fulfills it (a silent screenshot) and
   returns the image into the conversation. The model may now reason over what's on screen.
5. The model either calls `speak(text)` — a ≤3-sentence tip — or returns nothing (stay silent).
6. `speak` renders to the **Overlay**, one sentence at a time, ~5 seconds each.

## 3. Components

| Component | Responsibility | Built on (borrowed) |
|---|---|---|
| **AudioInput** | Capture mic and (optionally) system audio; stream to the Transcriber. | AVFoundation (mic); ScreenCaptureKit (system audio). |
| **Transcriber** | Maintain a rolling, speaker-labeled, **timestamped** transcript; emit turn-end events and silence events (with quiet duration). | `gpt-realtime-2` (latest realtime model; semantic VAD). |
| **CoachDriver** | The event loop. On triggers, enforce guardrails, call the brain with the transcript + timing context and tools, route tool calls. | `gpt-5.5` (vision + tool-use). |
| **ScreenTool** | Fulfill `capture_screen`: take a silent screenshot of the active display, excluding the overlay window. | macOS `screencapture` CLI / ScreenCaptureKit. |
| **Overlay** | Render `speak` output: ≤3 sentences, ~5s each, non-activating, always-on-top, excluded from capture. | AppKit NSPanel. |
| **MenuBar** | On/off, mute, status indicator, one-time API-key entry. | AppKit menu-bar item; Keychain for the key. |

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
judges them worthwhile. This is the point of [decision 0005](./decisions/0005-model-triggered-screen-capture.md).

## 5. Safety Model

Enforcement-first, not convention. See [sandbox.md](./sandbox.md) for the full model. In short:

- **App Sandbox** with only the entitlements it needs (screen recording, audio input). **No
  general filesystem access** — Jarvis can see your screen, not your files. The OS enforces this.
- **API key in the Keychain**, never plaintext on disk.
- **Built and run in a restricted macOS user account**, limiting blast radius.
- **Egress is narrow and explicit:** audio to `gpt-realtime-2`; a screenshot + transcript window
  to `gpt-5.5` *only when the model triggers a capture/response*. No recording to disk in the MVP.
- **Behavioral guardrails:** a cooldown after each utterance, a rate cap (max N interjections per
  minute), a global mute hotkey, and a visible "listening" indicator. These directly counter the
  central failure mode of a proactive agent — talking too much or at the wrong moment.

## 6. Non-Goals (v1)

- Multiple modes / a tiered sensitivity dial. (One mode: LeetCode Coach.)
- Continuous OCR or recording the screen/audio to disk ("recall").
- A dedicated wake-word engine. (Direct address, if needed, is just the word "Jarvis" appearing
  in the transcript, plus a summon hotkey.)
- Productization: auth, billing, onboarding, multi-provider.
- Windows / cross-platform.

## 7. Design Principles

1. **Build the harness, not the intelligence.** If a model or an OS framework can do it, we don't write it.
2. **Least code wins.** Prefer a borrowed tool (`screencapture`, an Apple framework, an OpenAI API) over custom code, every time.
3. **The model is the cost governor.** Expensive actions (vision, speaking) happen only when the model opts in.
4. **Proactive, but disciplined.** Speaking up unprompted is the whole point; guardrails keep it from being annoying.
5. **Sees the screen, not the disk.** Security is enforced by the sandbox, not by good intentions.
6. **Self-verifying.** Every build ships with tests and a smoke checklist the agent can run to prove it works.
7. **One mode, done well.** Ship the coach; expand later.
