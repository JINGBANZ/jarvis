# Jarvis

**A personal, proactive AI assistant.** It watches and listens alongside you, and — when it judges
it has something genuinely useful to add — speaks up **unprompted** with a short, well-timed tip.
No hotkey, no prompting; the assistant decides when to help.

The guiding idea is *build the harness, not the intelligence*: the models already exist, so Jarvis
is the thin layer of glue that wires perception (audio, screen) to a proactive voice.

> **Where it is today.** The first concrete capability is a **LeetCode coach on macOS** — it hears
> you think aloud, looks at your screen on demand, and nudges you toward the solution. macOS and
> coaching are the *first step*, not the destination; the architecture is meant to grow into a more
> general assistant. See the design docs in [`wiki/`](./wiki/index.md) (start with
> [`wiki/status.md`](./wiki/status.md)).

## How it works

```
  mic / system audio ──► Transcriber ──► rolling timestamped transcript
                                              │  turn-end / silence
                                              ▼
                                         CoachDriver ──(brain + tools)──┐
                                            ▲   │                       │
                               capture_screen   │ speak(text)           │
                                            │   ▼                       │
  screen ◄───────────────── ScreenTool ◄───┘  Overlay (on-screen) ◄─────┘
```

Audio streams continuously and cheaply into a transcript. The expensive steps — looking at the
screen and speaking — happen **only when the model invokes a tool**, so the model itself governs
cost. Behavioral guardrails (cooldown, rate cap, manual Start/Stop) keep it from talking too much.
Full design: [`wiki/architecture.md`](./wiki/architecture.md).

## Project structure

```
.
├── Package.swift              # SwiftPM manifest (Swift 6, macOS 14+)
├── Sources/
│   ├── JarvisCore/            # the testable harness — no UI, runs anywhere
│   │   ├── CoachDriver.swift      # the event loop: triggers → brain → tool calls
│   │   ├── OpenAIBrainClient.swift# the brain (Responses API, vision + tool-use)
│   │   ├── RealtimeSession.swift  # Realtime transcription wire contract
│   │   ├── Guardrails.swift       # cooldown + rate cap + mute
│   │   ├── Transcript.swift       # rolling, timestamped transcript window
│   │   ├── Config / Clock / Trigger / ToolDefs / Secrets / ...
│   │   └── ActivityLog.swift      # dev-mode live activity viewer (HTML)
│   └── JarvisApp/             # the macOS app shell — the native, OS-bound parts
│       ├── main.swift / AppDelegate.swift
│       ├── MenuBarController.swift # menu-bar item, Start/Stop, key entry
│       ├── AudioInput.swift        # mic + system-audio capture
│       ├── RealtimeTranscriber.swift
│       ├── OverlayPanel.swift      # the on-screen tip overlay (NSPanel)
│       └── Permissions.swift       # TCC priming (Mic, Screen Recording)
├── Tests/JarvisCoreTests/     # unit + offline-pipeline tests for the harness
├── Resources/Info.plist       # bundle id, usage strings
├── scripts/                   # build / run / test (see below)
└── wiki/                      # design & decision docs (single source of truth)
```

The split is deliberate: **`JarvisCore`** holds all the logic and is unit-tested on any machine;
**`JarvisApp`** holds the macOS-only glue (capture, overlay, permissions) verified by a live run.

## Scripts

| Script | What it does |
|---|---|
| `./scripts/run-tests.sh` | Build and run the unit + offline-pipeline tests (no key, no permissions needed). |
| `./scripts/build-app.sh [release\|debug]` | Build, bundle, and sign `Jarvis.app` (defaults to `release`). Creates the stable `Jarvis Dev` signing identity automatically on first run. |
| `./scripts/build-app.sh --dev` | Same build, then launch in **dev mode** and auto-open the live activity viewer. |
| `./scripts/build-app.sh --run` | Same build, then launch the app normally. |

## Develop locally

No Xcode needed — **Swift 6 + the Command Line Tools** only (the CLT SDK ships ScreenCaptureKit,
AVFoundation, AppKit, SwiftUI, Vision, and CoreAudio).

```bash
swift build              # compile
./scripts/run-tests.sh   # run the test suite (JarvisCore is fully testable here)
```

All the logic lives in `JarvisCore` precisely so you can iterate and test it without a Mac UI, a
real API key, or granted permissions.

## Quick start (run it on your Mac)

```bash
./scripts/build-app.sh --run   # build + sign Jarvis.app, then launch it
```

(`build-app.sh` creates the stable `Jarvis Dev` signing identity on first run; on that first build
macOS asks once to let `codesign` use the key — click **"Always Allow"**. Plain
`./scripts/build-app.sh` just builds; then `open ./Jarvis.app` to launch — always via `open`, see below.)

Then:

1. **A ⚪️ Jarvis menu-bar item appears** (menu-bar-only app — no Dock icon). Always launch with
   `open`, *not* the bare binary: running the executable from a terminal makes macOS attribute the
   permission grants to your shell, so they look "denied".
2. **Grant permissions** when prompted on first run — **Microphone** and **Screen Recording**
   (System Settings → Privacy & Security). They persist afterward. To clear a stale *denied* state,
   run `tccutil reset Microphone com.jarvis.coach` (or `ScreenCapture`) and relaunch.
3. **Set your OpenAI API key** via the menu bar → **"Set OpenAI API Key…"** (saved to your login
   Keychain; an `OPENAI_API_KEY` env var works as a headless fallback).
4. **Start / Stop** coaching from the menu bar. Jarvis does **not** auto-start. The icon shows the
   only two states: **⚪️ stopped** and **🟢 running**.

> **Why the stable signing identity.** macOS ties a permission grant to the app's code signature +
> bundle id + path. `build-app.sh` always signs with the stable `Jarvis Dev` identity (creating it on
> first run) so that signature stays constant and your Microphone / Screen Recording grants survive
> rebuilds. There is no ad-hoc fallback — ad-hoc signing changes identity every build, which is
> exactly what makes macOS forget permissions and re-prompt.

## Dev mode — live activity viewer

```bash
./scripts/build-app.sh --dev   # rebuild, launch with --dev, auto-open the viewer
```

In dev mode Jarvis writes a self-contained, auto-refreshing HTML page and opens it in your browser
so you can **watch it think** without tailing a log. It reloads every second and color-codes each
event:

- 🗣 `heard: "…"` — what you said (transcribed) / 🤫 `quiet for 12s` — why it woke
- 💭 `thinking…` — calling the brain
- 👁 `looking at your screen` — the model invoked `capture_screen`
- 💬 `…the tip it spoke…` — a `speak` call rendered to the overlay
- `… staying silent` / `… held back (cooldown or rate cap)` — when it declines

**Privacy posture.** File logging is **dev-only and owner-only.** Outside dev mode nothing is
written to a file (just the unified Console log). In dev mode the activity HTML and
`jarvis-debug.log` are written to the `--log-dir` (`--dev` uses a **gitignored `.jarvis/`** in
the workspace; default otherwise is a per-user `Caches/Jarvis`) with `0600` permissions, truncated
fresh each session — never world-readable `/tmp`. Env overrides `JARVIS_LOG` / `JARVIS_ACTIVITY_HTML`
exist for headless use. To enable on a manual launch:
`open ./Jarvis.app --args --dev --log-dir ./.jarvis`.

## Live smoke checklist

Some behavior can only be verified by a human with a real key, a mic, and granted permissions — see
[`wiki/specification.md` §8](./wiki/specification.md#8-self-verification-plan). Run via
`./scripts/build-app.sh --dev` and watch the live activity viewer; it shows each step as it happens.

- Model IDs are **doc-verified** (`gpt-5.5` via the Responses API; `gpt-4o-transcribe` over the GA
  Realtime API); the connect URL + session payload are unit-tested in `RealtimeSessionTests`. The
  one thing only a live run confirms is that the transcription session negotiates end-to-end — watch
  for `transcription session ready` and any `error event` lines.
- Press **Start Jarvis**, then speak — confirm transcript turns drive 🗣/💭 lines in the viewer.
- With a LeetCode problem on screen, say *"Jarvis, I'm stuck on two-sum"* — expect a coaching overlay
  within ~2s and a 👁 `looking at your screen` (`capture_screen`) line.
- Confirm the screenshot excludes the overlay window.
- Rapid triggers don't exceed 4 interjections/minute (look for `… held back` lines); **Stop Jarvis**
  halts the pipeline entirely.

## Build status

The pure harness (config, transcript, guardrails, the coach tool-loop, the OpenAI client) is
**unit-tested and green** (36 tests). The app shell, overlay, mic capture, and realtime transcriber
**compile and launch**, but their live behavior is verified only by the checklist above — they were
built without a real key or audio device. Current state and next steps live in
[`wiki/status.md`](./wiki/status.md).
