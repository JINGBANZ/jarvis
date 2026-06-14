# jarvis

Personal, proactive LeetCode-coaching assistant for macOS.

Design & docs live in [`wiki/`](./wiki/index.md) — start with [`wiki/status.md`](./wiki/status.md).
The implementation plan is [`wiki/plan-phase2-build.md`](./wiki/plan-phase2-build.md).

## Build

No Xcode needed — Swift 6 + Command Line Tools only.

```bash
./scripts/run-tests.sh        # run the unit + offline-pipeline tests (26 tests)
./scripts/build-app.sh release   # build + ad-hoc sign Jarvis.app
```

## Running Jarvis

1. **Build** the app: `./scripts/build-app.sh release` → produces `Jarvis.app`.
2. **Set your OpenAI API key** via the menu bar → **"Set OpenAI API Key…"**. It saves to your login Keychain and **starts coaching immediately — no relaunch**. (An `OPENAI_API_KEY` env var also works as a headless fallback.)
3. **Launch**: `open ./Jarvis.app` (or run `./Jarvis.app/Contents/MacOS/JarvisApp` in a terminal to see logs). A 🟢 Jarvis menu-bar item appears; it's a menu-bar-only app (no Dock icon).
4. **Grant permissions** when macOS prompts: **Microphone** and **Screen Recording** (System Settings → Privacy & Security). Screen Recording has no prompt dialog for the `screencapture` path — add Jarvis under Privacy & Security → Screen Recording if needed.

### Live smoke checklist (what to verify by hand)

These need a human, a real key, and granted permissions — see [`wiki/specification.md` §8](./wiki/specification.md#8-self-verification-plan):

- Model IDs are **doc-verified** (`gpt-5.5` via the Responses API; `gpt-4o-transcribe` over the GA Realtime API) — no edit expected. The connect URL + session payload are unit-tested in `RealtimeSessionTests`. The one thing only a live run can confirm is that the transcription session negotiates end-to-end (a real key + mic); watch the Console for `transcription session ready` and any `error event` lines.
- Speak — confirm transcript lines arrive (watch Console / terminal logs).
- With a LeetCode problem on screen, say *"Jarvis, I'm stuck on two-sum"* — expect a coaching overlay within ~2s, and observe a `capture_screen` call.
- Confirm the screenshot excludes the overlay window.
- Rapid triggers don't exceed 4 interjections/minute; **Mute** silences output.

### Status of the build

The pure harness (config, transcript, guardrails, the coach tool-loop, the OpenAI client) is **unit-tested and green**. The app shell, overlay, mic capture, and realtime transcriber **compile and launch** but their live behavior is verified only by the checklist above — they were built without a real key or audio device.
