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
mic + system audio ──► realtime transcription ──► speaker-labeled transcript
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
- The coaching brain can use the OpenAI API or an installed Claude Code / Codex CLI. An OpenAI API key
  is always required because realtime voice transcription still uses OpenAI.
- The transient **Overlay Caption** is off by default; the persistent **Overlay Box** is on by default.
  Both can be configured independently and are excluded from screen capture.

For the full loop and its design rationale, see
[`wiki/architecture.md`](./wiki/architecture.md).

## Requirements

- Apple silicon Mac running macOS 14 or later
- Swift 6 and the macOS Command Line Tools; full Xcode is not required
- An OpenAI API key
- Microphone and Screen Recording permission

## Quick start

```bash
./scripts/build-app.sh --run
```

The first build creates a stable local `Jarvis Dev` signing identity. When macOS asks to let
`codesign` use the key, choose **Always Allow** so permission grants persist across rebuilds.

Then:

1. Grant **Microphone** and **Screen Recording** when macOS prompts.
2. Open the menu-bar item, choose **Settings… → Brain**, and save your OpenAI API key. The key is
   stored in an owner-only file; `OPENAI_API_KEY` is available as a headless fallback.
3. Optionally choose the brain provider, model, capture scope, and overlay appearance in Settings.
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
- `eval-report.md` and `eval-report.html` only after a session evaluation is requested.

The history is pruned to the ten most recent sessions. Raw audio and the rolling in-memory transcript
are not archived, although finalized `heard:` lines are part of the activity record. Audio is sent to
OpenAI for transcription, and coaching context is sent to the selected brain provider. See
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

Use `./scripts/run-tests.sh`, not raw `swift test`; the wrapper supplies the swift-testing paths
needed by Command Line Tools-only installations.

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

## Live smoke checklist

Run `./scripts/build-app.sh --run`, choose **Start Jarvis**, and use the new
`.jarvis/<session>/jarvis-debug.log` for readiness and diagnostics. Use **Settings → Activity** only
for the human-facing coaching record.

- Wait for `Jarvis: coaching ready (mic + system audio).` in the debug log. Speak into the microphone
  and play speech through system audio; confirm both appear as finalized `heard:` entries in Activity.
- Show an interview question without speaking its details, then ask, “Jarvis, how can I solve this in
  one pass?” Confirm Activity shows exactly one screen view followed by a screen-specific tip. A fully
  stated behavioral question should not cause an unnecessary capture.
- Press **⌥⌘J** with a question visible; confirm a shortcut entry, one screen view, and a tip appear in
  Activity.
- Confirm saved screenshots exclude both overlay surfaces. Toggle each overlay in Settings, verify its
  controls and preview follow the toggle, and confirm the choice survives relaunch.
- If validating realtime recovery, disconnect the network, say a unique phrase, reconnect, and confirm
  the debug log reports buffered replay and the phrase appears exactly once after recovery.
- Choose **Stop Jarvis** and confirm no later transcription or coaching events are produced.
