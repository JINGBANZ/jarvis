# Jarvis

**A personal, proactive AI assistant.** It watches and listens alongside you, and — when it judges
it has something genuinely useful to add — speaks up **unprompted** with a short, well-timed tip.
No hotkey, no prompting; the assistant decides when to help.

The guiding idea is *build the harness, not the intelligence*: the models already exist, so Jarvis
is the thin layer of glue that wires perception (audio, screen) to a proactive voice.

## Use cases

Jarvis is a general proactive-assistant harness; each concrete capability is a **use case** built on
top of it. Today there is one. The list is meant to grow — the harness (perception → judgement → a
proactive, unprompted voice) is designed to be reused across future use cases.

### LeetCode coach (macOS) — *current focus*

Jarvis hears you think aloud while you solve a problem, looks at your screen on demand to read the
problem and your code, and proactively nudges you toward the solution with short overlay tips —
asking a pointed question or pointing at the next small step rather than dumping the answer. This is
the first capability and what the current build targets; macOS and coaching are the *first step*,
not the destination.

Design docs live in [`wiki/`](./wiki/index.md) (start with [`wiki/status.md`](./wiki/status.md)).

### More to come

The same harness is meant to extend to other proactive scenarios; new use cases will be added here
as they are designed and built.

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
cost. There's no cooldown or rate cap: every utterance reaches the brain and the brain decides
whether to speak (restraint lives in the prompt); the manual Start/Stop is the only hard gate.
Full design: [`wiki/architecture.md`](./wiki/architecture.md).

## Project structure

```
.
├── Package.swift              # SwiftPM manifest (Swift 6, macOS 14+)
├── CLAUDE.md                  # development rules for agents/humans working in the repo
├── Sources/
│   ├── JarvisCore/            # the testable harness — Foundation-only, runs anywhere
│   │   ├── Audio/                 # PCM + utterance buffering
│   │   ├── Transcription/         # realtime session wire contract + rolling transcript
│   │   ├── Coach/                 # the event loop: CoachDriver, brain client, tool defs
│   │   ├── Triggers/              # turn / silence detection + silence backoff
│   │   ├── Screen/                # screen-capture tool contract
│   │   ├── Overlay/               # overlay text model (the rendered tip)
│   │   ├── Config/                # config + Keychain secrets
│   │   ├── Diagnostics/           # logging, activity log, session-history store
│   │   └── Support/               # small primitives (Clock, TurnTaskBox)
│   ├── JarvisOverlay/         # the on-screen NSPanel overlay — own target so it's unit-testable
│   │   └── OverlayPanel.swift
│   └── JarvisApp/             # the macOS app shell — the native, OS-bound parts
│       ├── App/                   # main.swift, AppDelegate
│       ├── MenuBar/               # menu-bar item, Start/Stop, key entry
│       ├── Capture/               # mic + system-audio capture, realtime transcriber, TCC priming
│       └── Viewer/                # dev-mode WKWebView activity viewer
├── Tests/
│   ├── JarvisCoreTests/      # unit + offline-pipeline tests (mirrors the Core subsystems)
│   ├── JarvisOverlayTests/   # overlay screen-capture-invisibility checks
│   └── JarvisViewerTests/    # WebKit end-to-end tests of the viewer HTML/JS
├── Resources/Info.plist       # bundle id, mic usage string
├── scripts/                   # build / run / test (see below)
└── wiki/                      # design & decision docs (single source of truth)
```

The split is deliberate: **`JarvisCore`** holds all the logic (Foundation-only) and is unit-tested on
any machine; **`JarvisOverlay`** is the AppKit overlay, split into its own target so its behavior is
testable; **`JarvisApp`** is the thin macOS glue (menu bar, capture, permissions, dev viewer) verified
by a live run. Folders are grouped **by subsystem**, following
[`wiki/architecture.md`](./wiki/architecture.md). Working rules live in [`CLAUDE.md`](./CLAUDE.md).

## Scripts

| Script | What it does |
|---|---|
| `./scripts/run-tests.sh` | Build and run the unit + offline-pipeline tests (no key, no permissions needed). |
| `./scripts/build-app.sh [release\|debug]` | Build, bundle, and sign `Jarvis.app` (defaults to `release`). Creates the stable `Jarvis Dev` signing identity automatically on first run. |
| `./scripts/build-app.sh --dev` | Same build, then launch in **dev mode** (open the activity viewer on demand from the menu bar). |
| `./scripts/build-app.sh --run` | Same build, then launch the app normally. |

## Develop locally

No Xcode needed — **Swift 6 + the Command Line Tools** only.

```bash
swift build              # compile
./scripts/run-tests.sh   # run the test suite (JarvisCore is fully testable here)
```

All the logic lives in `JarvisCore` precisely so you can iterate and test it without a Mac UI, a
real API key, or granted permissions.

## Quick start (run it on your Mac)

```bash
./scripts/build-app.sh --run   # build, sign, and launch Jarvis.app
```

On the **first** build macOS asks once to let `codesign` use a new key — click **"Always Allow"**.
(Plain `./scripts/build-app.sh` builds without launching; then `open ./Jarvis.app`.)

Then:

1. **A ⚪️ Jarvis menu-bar item appears** (menu-bar-only app — no Dock icon). Always launch via
   `open`, never the bare binary, or macOS misattributes the permission grants and they look "denied".
2. **Grant Microphone and Screen Recording** when prompted on first run (System Settings → Privacy &
   Security). They persist afterward.
3. **Set your OpenAI API key** via the menu bar → **"Set OpenAI API Key…"** (saved to your login
   Keychain; an `OPENAI_API_KEY` env var works as a headless fallback).
4. **Start / Stop** coaching from the menu bar. Jarvis does **not** auto-start. The icon shows the
   only two states: **⚪️ stopped** and **🟢 running**.

Permissions persist across rebuilds automatically (the app always signs with a stable identity); the
mechanics are in [`wiki/build-and-run.md`](./wiki/build-and-run.md).

## Dev mode — live activity viewer

```bash
./scripts/build-app.sh --dev   # rebuild, launch with --dev
```

In dev mode Jarvis opens an **in-app live viewer** (a `WKWebView` it pushes events into) so you can
**watch it think** without tailing a log. It doesn't pop open on launch — choose **Open Log Viewer**
from the menu bar when you want it (each launch is its own session; you can also browse past sessions
or clear the history). New events stream in live — no reload — and are color-coded:

- 🗣 `heard: "…"` — what you said (transcribed) / 🤫 `quiet for 30s` — why it woke
- 💭 `thinking…` — calling the brain
- 👁 `looking at your screen` — the model invoked `capture_screen`; the captured frame appears as a
  thumbnail you can click to open full size
- 💬 `…the tip it spoke…` — a `speak` call rendered to the overlay
- `… staying silent` — when the model declines to speak

**Privacy posture.** File logging is dev-only — outside dev mode nothing is written to disk (just the
unified Console log). In dev mode the logs (and the screenshot thumbnails) go to a gitignored,
owner-only `.jarvis/<session>/` in the workspace — one fresh subdirectory per launch. The posture and
build/run mechanics are in [`wiki/build-and-run.md`](./wiki/build-and-run.md)
and [`wiki/sandbox.md`](./wiki/sandbox.md).

## Live smoke checklist

Some behavior can only be verified by a human with a real key, a mic, and granted permissions. Run
via `./scripts/build-app.sh --dev`, then open the activity viewer from the menu bar; it shows each
step as it happens.

- Confirm the transcription session connects end-to-end — watch for `transcription session ready`
  (and any `error event` lines). This is the main thing only a live run can verify.
- Press **Start Jarvis**, then speak — confirm transcript turns drive 🗣/💭 lines in the viewer.
- With a LeetCode problem on screen, say *"Jarvis, I'm stuck on two-sum"* — expect a coaching overlay
  within ~2s and a 👁 `looking at your screen` (`capture_screen`) line.
- Confirm the screenshot excludes the overlay window.
- While you talk steadily, Jarvis stays mostly quiet (restraint is the model's, not a rate cap);
  **Stop Jarvis** halts the pipeline entirely.

## Build status

The pure harness (config, transcript, silence backoff, the coach tool-loop, the OpenAI client) is
**unit-tested and green**. The app shell, overlay, mic capture, and realtime transcriber
**compile and launch**, but their live behavior is verified only by the checklist above — they were
built without a real key or audio device. Current state and next steps live in
[`wiki/status.md`](./wiki/status.md).
