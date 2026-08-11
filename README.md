# Jarvis

Jarvis is a proactive macOS menu-bar coach for technical interviews. While a session is running, it
follows the microphone and system-audio conversation, looks at the screen when visual context is
needed, and shows short coaching tips in capture-invisible overlays.

Coaching is proactive by default. Press **⌥⌘J** during a session when you want an immediate,
screen-aware hint.

> Current implementation status and the next validation task live in
> [`wiki/status.md`](./wiki/status.md). Start at the [`wiki index`](./wiki/index.md) for the design
> documentation.

## How it works

```text
mic + system audio ──► selected transcription provider ──► speaker-labeled transcript
                                                                  │ substantive turn / silence
                                                                  ▼
                                                             CoachDriver
                                                                  │ selected brain
                                           ┌─────────────────────┼──────────────────┐
                                           ▼                     ▼                  ▼
                                    capture_screen          stay_silent          speak
                                           │                                        │
                                  active window + OCR                 caption + overlay box
```

- Microphone and system audio are transcribed separately as `me` and `them`; WebRTC AEC3 reduces
  speaker echo in the microphone stream.
- Substantive turns and silence checks reach the coach. Empty and back-channel-only turns are skipped;
  the model decides whether a useful tip warrants interrupting.
- During proactive turns, screen capture is model-triggered. It captures the active window by default,
  adds on-device OCR, and can instead target an entire display from **Settings → Screen**. The ⌥⌘J
  shortcut captures immediately and forces a hint.
- Transcription defaults to OpenAI **GPT-4o Transcribe**, with **GPT Transcribe** and **GPT Live
  Transcribe** available for session-by-session comparison. Language expectations default to
  automatic; optional English, Mandarin, and English + Mandarin profiles guide recognition without
  choosing a language per turn. On macOS 26 or later, **Apple Speech** is an opt-in, on-device
  provider using one selected conversation locale.
- The coaching brain can use the OpenAI API or an installed Claude Code / Codex CLI. An OpenAI API
  key is required only when OpenAI supplies transcription or appears in the configured brain route.
- The transient **Overlay Caption** is off by default; the persistent **Overlay Box** is on by default.
  Both can be configured independently and are excluded from screen capture.

For the full loop and its design rationale, see
[`wiki/architecture.md`](./wiki/architecture.md).

## Requirements

- Apple silicon Mac running macOS 14 or later
- Swift 6 and the macOS Command Line Tools; full Xcode is not required
- An OpenAI API key when using OpenAI transcription or an OpenAI brain target
- Microphone and Screen Recording permission

## Quick start

```bash
./scripts/build-app.sh --run
```

The first build creates a stable local `Jarvis Dev` signing identity. When macOS asks to let
`codesign` use the key, choose **Always Allow** so permission grants persist across rebuilds.

Then:

1. Grant **Microphone** and **Screen Recording** when macOS prompts.
2. Open the menu-bar item and choose **Settings… → Brain**. The default OpenAI transcription
   provider needs an OpenAI API key; the key is stored in an owner-only file and
   `OPENAI_API_KEY` is available as a headless fallback.
3. Choose the transcription model and expected languages, or choose **Apple Speech** on macOS 26+
   and select the conversation locale. Then choose the brain route, capture scope, and overlay
   appearance.
4. Choose **Start Jarvis**. Use **Stop Jarvis** to end the session, or press **⌥⌘J** while it is
   running to request a hint immediately.

Always launch the app with `open` (the script does this), never by executing the bare binary. macOS
otherwise attributes privacy grants to the terminal instead of `Jarvis.app`. Permission recovery and
signing details are in [`wiki/build-and-run.md`](./wiki/build-and-run.md).

## Session data

When launched with `./scripts/build-app.sh --run`, each Start creates an owner-only directory under
`.jarvis/` containing:

- `jarvis-activity.jsonl` and any screenshots Jarvis actually viewed, shown in **Settings → Activity**;
- `jarvis-debug.log` for lifecycle, transport, retry, and diagnostic detail;
- `brain-traffic.jsonl` for the requests and responses exchanged with the selected brain provider;
- `eval-report.md` and `eval-report.html` only after `scripts/eval-session.sh` runs the agentic audit.

The history is pruned to the ten most recent sessions. Raw audio and the rolling in-memory transcript
are not archived, although finalized `heard:` lines are part of the activity record. The selected
OpenAI transcription model receives audio when OpenAI is the provider; Apple Speech
keeps raw audio on-device after its selected locale model is installed. Coaching text and any
requested screenshot go to the selected brain provider. See
[`wiki/sandbox.md`](./wiki/sandbox.md) for the complete local-persistence, egress, and retention model.

## Development

The repository uses SwiftPM and has no Xcode project.

| Task | Command |
|---|---|
| Compile all targets | `swift build` |
| Run all test targets | `./scripts/run-tests.sh` |
| Run the pre-push gate | `swift build && ./scripts/run-tests.sh` |
| Build the app without launching | `./scripts/build-app.sh [release\|debug]` |
| Build and launch | `./scripts/build-app.sh --run` |
| Audit a finished session | `./scripts/eval-session.sh [session-dir]` |
| Run the fixed system-audio transcription matrix | `./scripts/transcription-benchmark.sh standard` |
| Validate transcription reconnects | `./scripts/transcription-benchmark.sh reconnect` |

Use `./scripts/run-tests.sh`, not raw `swift test`; the wrapper supplies the swift-testing paths
needed by Command Line Tools-only installations.

The transcription benchmark plays only fixed synthetic phrases through Jarvis's own process and
captures that process's system audio without opening a microphone. Standard mode covers every
selectable transcription path with at least three identical repetitions. Reconnect mode is separate:
it automatically closes and holds only Jarvis's transcription connection while the fixed phrases
fill the real replay buffer, then allows the normal reconnect path to replace that connection. Host
Wi-Fi, Ethernet, VPNs, and every other process remain online. Owner-only summaries land under
`.jarvis/transcription-benchmarks/`, which retains only the ten most recent runs, and the temporary
synthetic audio files are removed at exit. See the
[benchmark operating and scoring contract](./wiki/transcription-benchmark.md).

The package boundaries are intentionally small:

| Target | Responsibility |
|---|---|
| `JarvisCore` | Foundation-only logic: audio, transcription, brain clients, coaching, screen contracts, configuration, and diagnostics |
| `JarvisOverlay` | AppKit overlay panels and capture exclusion |
| `CJarvisAEC` | Pure-C facade over the prebuilt WebRTC AEC3 archive |
| `JarvisApp` | Thin macOS shell for capture, permissions, menu bar, settings, shortcuts, and the activity viewer |
| `EvalPrep` | Foundation-only helper used by the developer-side session audit |

Contributor workflow, subsystem placement, and testing rules live in
[`CLAUDE.md`](./CLAUDE.md).
