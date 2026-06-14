# jarvis

Personal, proactive LeetCode-coaching assistant for macOS.

Design & docs live in [`wiki/`](./wiki/index.md) — start with [`wiki/status.md`](./wiki/status.md).
The implementation plan is [`wiki/plan-phase2-build.md`](./wiki/plan-phase2-build.md).

## Build

No Xcode needed — Swift 6 + Command Line Tools only.

```bash
./scripts/run-tests.sh        # run the unit + offline-pipeline tests (30 tests)
./scripts/make-signing-identity.sh   # one-time: create the stable "Jarvis Dev" signing identity
./scripts/build-app.sh release       # build + sign Jarvis.app (so TCC permissions persist)
```

Run `make-signing-identity.sh` **once**. It creates a stable self-signed identity so macOS
Microphone / Screen Recording grants persist across rebuilds; without it `build-app.sh` falls back
to ad-hoc signing and macOS re-prompts every build.

## Running Jarvis

1. **Build** the app: `./scripts/build-app.sh release` → produces `Jarvis.app`.
2. **Launch via `open`**: `open ./Jarvis.app`. A **⚪️ Jarvis** menu-bar item appears (menu-bar-only app, no Dock icon). Always launch with `open`, *not* the bare binary — launching the executable from a terminal makes macOS attribute the permission grants to the shell, so they look "denied".
3. **Grant permissions** when macOS prompts (first run only): **Microphone** and **Screen Recording** (System Settings → Privacy & Security). These persist afterward. To recover a stale *denied* state, run `tccutil reset Microphone com.jarvis.coach` (or `ScreenCapture`) and relaunch.
4. **Set your OpenAI API key** via the menu bar → **"Set OpenAI API Key…"**. It saves to your login Keychain. (An `OPENAI_API_KEY` env var also works as a headless fallback.) Jarvis does **not** auto-start.
5. **Start / Stop** coaching from the menu bar (**Start Jarvis** / **Stop Jarvis**). The icon shows the only two states: **⚪️ stopped** and **🟢 running**.

### Dev mode — live activity viewer

```bash
./scripts/run-dev.sh        # rebuild, launch via `open --args --dev`, auto-open the viewer
```

In **dev mode** Jarvis writes a self-contained, auto-refreshing HTML page and opens it in your
browser so you can *watch it think* without tailing a log file. It reloads every second and
color-codes each event:

- 🗣 `you finished a thought` / 🤫 `quiet for 12s` — why the coach loop woke up
- 💭 `thinking…` — calling the brain
- 👁 `looking at your screen` — the model invoked `capture_screen`
- 💬 `…the tip it spoke…` — a `speak` call rendered to the overlay
- `… nothing useful to add, staying silent` / `… held back (cooldown or rate cap)`

Every `jlog` line (lifecycle, errors, realtime-socket events) is mirrored in too. The page is
written to `/tmp/jarvis-activity.html` (override with the `JARVIS_ACTIVITY_HTML` env var); it's
regenerated fresh each session. To enable the viewer on a manual launch, add the flag yourself:
`open ./Jarvis.app --args --dev`.

### Live smoke checklist (what to verify by hand)

These need a human, a real key, and granted permissions — see [`wiki/specification.md` §8](./wiki/specification.md#8-self-verification-plan):

Run with `./scripts/run-dev.sh` and watch the **live activity viewer** (above) — it shows each step below as it happens.

- Model IDs are **doc-verified** (`gpt-5.5` via the Responses API; `gpt-4o-transcribe` over the GA Realtime API) — no edit expected. The connect URL + session payload are unit-tested in `RealtimeSessionTests`. The one thing only a live run can confirm is that the transcription session negotiates end-to-end (a real key + mic); watch for `transcription session ready` and any `error event` lines.
- Press **Start Jarvis**, then speak — confirm transcript turns drive 🗣/💭 lines in the viewer.
- With a LeetCode problem on screen, say *"Jarvis, I'm stuck on two-sum"* — expect a coaching overlay within ~2s, and observe a 👁 `looking at your screen` (`capture_screen`) line.
- Confirm the screenshot excludes the overlay window.
- Rapid triggers don't exceed 4 interjections/minute (look for `… held back` lines); **Stop Jarvis** halts the pipeline entirely.

### Status of the build

The pure harness (config, transcript, guardrails, the coach tool-loop, the OpenAI client) is **unit-tested and green**. The app shell, overlay, mic capture, and realtime transcriber **compile and launch** but their live behavior is verified only by the checklist above — they were built without a real key or audio device.
