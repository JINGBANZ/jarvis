# Specification

> The buildable spec for the **native Swift app**. Another agent should be able to implement it from
> this page plus [architecture.md](./architecture.md). Normative: where this says "must," it's a
> requirement.

> **Build note (2026-06-14):** The two-phase plan (Natively fork PoC first) was **dropped** — this
> spec is built directly. The implementation plan is [plan-phase2-build.md](./plan-phase2-build.md).

## 1. Summary

A native Swift/SwiftUI macOS menu-bar app. It transcribes the user's voice continuously with
`gpt-4o-transcribe`, and on each conversational turn (or after a silence) it calls `gpt-5.5` with two
tools — `capture_screen` and `speak`. The model decides whether to look at the screen and whether
to offer a short LeetCode coaching tip, which is rendered in an overlay. The model is given timing
context (timestamped transcript + how long the user has been silent) so it can distinguish
"thinking productively" from "stuck."

## 2. The Harness Loop (pseudocode)

```swift
// Always-on: stream audio to gpt-4o-transcribe, maintain a rolling, timestamped transcript.
transcriber.onTurnEnd = { handleTrigger(.turnEnd) }
// Silence fires after the current backoff interval (base `silenceTimeoutSeconds`, doubling while
// still quiet up to `silenceMaxIntervalSeconds`); the actual quiet duration is passed through.
transcriber.onSilence = { secs in handleTrigger(.silence(secondsQuiet: secs)) }

func handleTrigger(_ reason: TriggerReason) {
    // No cooldown, no rate cap, no wake-word gate: every utterance reaches the brain, and the
    // brain decides whether it has anything worth saying. That restraint lives in the prompt, not
    // in a guardrail — including answering when the user addresses Jarvis by name.
    let messages = coachPrompt(
        transcript: transcriber.recentWindow(seconds: 90),     // each line carries a timestamp
        context: TriggerContext(reason: reason,                // .turnEnd or .silence(secondsQuiet:)
                                secondsSinceLastSpeech: transcriber.silenceDuration,
                                sessionElapsedSeconds: clock.sessionElapsed))
    // Tool-use loop against gpt-5.5
    var convo = messages
    while true {
        let resp = openAI.chat(model: GPT_5_5,
                               messages: convo,
                               tools: [captureScreenTool, speakTool])
        switch resp.toolCall {
        case .captureScreen:
            let image = screenTool.capture()             // silent screenshot
            convo.append(toolResult(.captureScreen, image))
            continue                                     // let the model reason over the image
        case .speak(let text):
            overlay.render(text)                         // <=3 sentences, 5s each
            return
        case .none:
            return                                       // model chose to stay silent
        }
    }
}
```

The loop is deliberately small. All judgment ("do I need to see the screen?", "do I have a useful
tip?", "should I stay quiet?", "was I just addressed?") lives in the model, not the harness. The
**Start/Stop** control is the only hard gate; coaching never runs until explicitly started.

### Timing & "stuck" detection

The model must be **time-aware**, because going quiet is a primary signal that the user is stuck —
but silence is ambiguous (they might be productively thinking). So the harness supplies time, and
lets the model judge:

- **Timestamped transcript:** every line in the window is prefixed with a relative timestamp
  (e.g. `[01:42] me: maybe a hash map…`), so the model can see rhythm and gaps.
- **Silence trigger carries duration:** when the current silence interval of quiet elapses, the
  trigger fires with `secondsQuiet`, and the prompt states it plainly (e.g. "The user has been
  silent for 30 seconds"). The model decides whether that means "offer a nudge" or "let them think."
  The interval **backs off** — base `silenceTimeoutSeconds`, doubling while the user stays quiet up
  to `silenceMaxIntervalSeconds`, and resetting to the base on any speech — so a long silence is
  re-checked occasionally (e.g. 30s, 60s, 120s, …) rather than nudged once or pestered every few
  seconds.
- **Session clock:** `sessionElapsedSeconds` lets the model factor in how long they've been on the
  problem overall.

The harness only *detects and reports* time; it never decides that silence means stuck. That
judgment is the model's, informed by the timing context above.

## 3. Tools Exposed to the Model

### `capture_screen`

```json
{
  "name": "capture_screen",
  "description": "Take a screenshot of the user's active display to see the LeetCode problem and their code. Call this only when you need to see the screen to give a useful, specific tip. Returns an image.",
  "parameters": { "type": "object", "properties": {}, "required": [] }
}
```

- **Implementation:** invoke the built-in macOS tool `screencapture -x -t jpg <tmpfile>` (`-x` =
  silent, no shutter sound), or ScreenCaptureKit for an in-memory frame. **Must exclude Jarvis's
  own overlay window** so the model never sees its own output.
- **Return:** the image is appended to the conversation as a tool result (image content block).
- **Cost control:** this is the only path that spends vision tokens. It fires only when the model calls it.

### `speak`

```json
{
  "name": "speak",
  "description": "Say a short coaching tip to the user via the on-screen overlay. Use at most 3 short sentences. Only call this when you have something genuinely useful to add; otherwise do not call any tool (stay silent).",
  "parameters": {
    "type": "object",
    "properties": { "text": { "type": "string" } },
    "required": ["text"]
  }
}
```

- **Implementation:** render `text` in the Overlay. The harness splits on sentence boundaries and
  shows **at most 3** sentences, **~5 seconds each**; any text beyond 3 sentences is dropped.
- **Silence:** if the model calls no tool, Jarvis says nothing. This is expected and common.

## 4. Coach System Prompt (MVP)

> Stored as a constant (`coachSystemPrompt`); tune freely. Since there is **no cooldown or rate
> cap**, this prompt is the *only* thing governing how much Jarvis talks — the restraint must live
> here. It also carries direct-address handling: the model decides it was addressed by reading
> "Jarvis" / a question in the transcript, so there is no separate wake-word detector.

```
You are Jarvis, a calm, sharp LeetCode coach sitting beside the user while they solve a problem.
You hear them think aloud. You cannot see their screen unless you call capture_screen — do that
when you need to read the problem or their code to be specific and correct.

You are given timing context: a timestamped transcript, how many seconds the user has been silent,
and how long they have been on the problem. Use it.

WHEN THE USER ADDRESSES YOU DIRECTLY (says your name "Jarvis", asks you a question, or tells you to
do something), you MUST reply — call the speak tool with a brief, helpful answer. Never ignore a
direct address; even a simple greeting deserves a short spoken reply. This overrides the
stay-quiet-by-default behavior below.

OTHERWISE, when the user is just thinking aloud, be a restrained, proactive coach. Nudge them toward
the solution with short, encouraging, specific hints. Never dump the full solution unless they are
truly stuck and ask for it. Prefer a pointed question or the next small step (e.g. "What's the time
complexity of that nested loop?"). If they are making good progress, stay silent — call no tool.

IF THE USER ASKS YOU TO LOOK AT OR CHECK THEIR SCREEN, call capture_screen right away — even if they
didn't say your name — then answer based on what you see.

WHEN THE USER HAS BEEN SILENT FOR A WHILE, prefer to call capture_screen to read their current
problem and code before deciding whether a nudge would help. A long silence often means they are
stuck; but if the screen shows steady progress, stay silent and leave them alone.

When you do speak, call the speak tool with at most 3 short sentences.
```

## 5. Configuration

| Key | Default | Notes |
|---|---|---|
| `silenceTimeoutSeconds` | 30 | Base quiet interval before the first "maybe stuck" silence check. The actual quiet duration is passed to the model. |
| `silenceMaxIntervalSeconds` | 240 | Upper bound on the silence-check interval as it backs off (30s → 60s → 120s → 240s, then holds), so a long silence is re-checked occasionally instead of once or constantly. Resets to the base on any speech. |
| `transcriptWindowSeconds` | 90 | How much recent transcript the model sees per turn (timestamped). |
| `sentenceDisplaySeconds` | 5 | How long each overlay sentence stays up. |
| `maxSentences` | 3 | Hard cap on response length. |
| `reasoningEffort` | `low` | Responses-API reasoning effort (gpt-5 family: minimal/low/medium/high). `low` keeps the turn fast while still permitting tool calls. |
| `brainModel` | `gpt-5.5` | **Confirmed** against OpenAI docs (snapshot `gpt-5.5-2026-04-23`). Vision + function calling. Called via the **Responses API**. |
| `transcriptionModel` | `gpt-4o-transcribe` | Supports `server_vad`, so the Realtime server auto-commits the audio buffer per utterance and emits `…transcription.completed` (what fires the coach loop). `gpt-realtime-whisper` is lower-latency but has **no server VAD** — it would need manual `input_audio_buffer.commit`, so it is not used. |

> **Verified against OpenAI docs (2026-06):**
> - **Brain uses the Responses API** (`POST /v1/responses`), not Chat Completions: for gpt-5.5,
>   tool calling is the recommended path on Responses (Chat Completions restricts tool calls under
>   some reasoning modes). Flat function tools; system prompt via `instructions`; the tool loop is
>   threaded with `function_call` / `function_call_output` items; `reasoning.effort` is set.
> - **Transcription** uses **`gpt-4o-transcribe`** over the **GA Realtime API**. (`gpt-4o-transcribe`
>   was never a real ID; `gpt-realtime-whisper` was tried but has no server VAD — it needs manual
>   commits — so it was dropped.) Connect with **`?intent=transcription`** (no `OpenAI-Beta`
>   header); `session.update` sets `session.type:"transcription"` with config nested under
>   `session.audio.input` (24 kHz mono PCM16; `server_vad` → auto-commit). Turn-end fires on
>   `…transcription.completed`. The connect URL + payload are built by a unit-tested `RealtimeSession`
>   helper so this wire contract is verified, not just mocked.
> - **Production hardening:** the brain client retries 429/5xx with backoff (honoring `Retry-After`),
>   sets a request timeout, `store:false` (no server-side retention of screenshots/transcripts),
>   `max_output_tokens`, `parallel_tool_calls:false`, and a `prompt_cache_key`. The transcriber
>   reconnects with backoff + ping keepalive. The coach loop is single-flighted (no double-speak).
> - The screenshot from `capture_screen` goes to the **brain** (`gpt-5.5`, vision), never the
>   transcription model. The two roles stay split.
>
> Sources: [models/gpt-5.5](https://developers.openai.com/api/docs/models/gpt-5.5),
> [function-calling](https://developers.openai.com/api/docs/guides/function-calling),
> [realtime-transcription](https://developers.openai.com/api/docs/guides/realtime-transcription),
> [migrate-to-responses](https://developers.openai.com/api/docs/guides/migrate-to-responses).

API key is read from the **Keychain**, entered via the menu bar ("Set OpenAI API Key…"), which
saves it locally. Jarvis does **not** auto-start — the user presses **Start Jarvis** in the menu
bar to begin (and **Stop Jarvis** to halt); the menu bar shows two states only, ⚪️ stopped and
🟢 running. An `OPENAI_API_KEY` env var is a headless fallback. Never stored in plaintext or committed.

## 6. Audio Sources

- **Mic (critical path):** the user thinking aloud. AVFoundation → Realtime. Must work in MVP.
- **System audio (in MVP, budget-permitting):** the "other side" of a call (e.g. a mock
  interviewer on Zoom). ScreenCaptureKit audio capture, labeled as a distinct speaker. It is part
  of the MVP and rides along with the screen-capture entitlement; it is the **first feature cut if
  it threatens the 2-day budget**, but the intent is to ship it. The design must not preclude it.

## 7. Latency Budget

Target: **turn-end → first overlay sentence < 2 seconds.** Levers:
- Transcription is continuous, so there is no STT latency at trigger time.
- Most turns are text-only (no `capture_screen`) and therefore fast.
- Stream the model's response and render sentence-by-sentence so the first sentence appears before
  the third is generated.

## 8. Self-Verification Plan

The build agent must produce and run these. (See the development goal: the agent verifies its own work.)

**Unit tests (pure logic, run anywhere):**
- CoachDriver turn outcomes: a turn routes capture→speak; staying silent renders nothing; a
  truncated response is reported as `.truncated` (not silence); a concurrent trigger is coalesced.
- Silence backoff (`SilenceBackoff`): the check interval starts at the base, doubles while quiet up
  to the cap, and resets to the base on speech.
- Overlay formatting: a 5-sentence input renders exactly 3 sentences; sentence splitting is correct.

**Offline pipeline test (mock OpenAI client, run anywhere):**
- Feed a fixture transcript ("I think I'll brute-force two-sum with a double loop") + a fixture
  screenshot. Assert the mock model's `capture_screen` request is fulfilled with the image, and a
  `speak` call with the expected shape (≤3 sentences) is produced and routed to a fake overlay.

**Live smoke checklist (run on the Mac, manual or scripted):**
1. App launches; menu-bar icon present; permissions (Screen Recording, Microphone) granted.
2. Speaking produces transcript text within ~1s.
3. A planted prompt — say "Jarvis, I'm stuck on two-sum" aloud with the problem on screen —
   produces a coaching overlay within the latency budget, and the model is observed to call
   `capture_screen`.
4. `capture_screen` returns a valid image and the overlay window is absent from it.
5. Restraint holds: while the user talks steadily, Jarvis stays mostly quiet (the model's judgment,
   not a rate cap); **Stop Jarvis** halts the pipeline entirely.

**Cost guard:** a session **interjection** counter surfaced in the menu bar (reset on each Start),
so runaway behavior is visible. There is no hard rate cap in code — cost tracks usage, and the
counter is the visible signal if the model ever over-talks (tighten the prompt if so).

## 9. Build & Run Constraints

- Built and verified **on the MacBook** (the macOS-native capture, permissions, and overlay cannot
  be tested on Linux).
- **Toolchain: SwiftPM + the Command Line Tools — no full Xcode.** Verified that the CLT SDK
  (`/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`) ships ScreenCaptureKit, AVFoundation,
  AppKit, SwiftUI, Vision, CoreAudio, and Security, and that a SwiftUI+ScreenCaptureKit binary
  compiles and runs with `swiftc`. Build with `swift build`.
- **Packaging:** the executable is assembled into a `.app` bundle by hand — a minimal
  `Contents/MacOS/<bin>` + `Contents/Info.plist` carrying `NSMicrophoneUsageDescription` and the
  stable bundle identifier `com.jarvis.coach`. `scripts/build-app.sh` does this.
- **Signing for permission persistence.** The bundle is signed with a **stable self-signed identity
  (`Jarvis Dev`)**, which `scripts/build-app.sh` creates automatically on first build, *not* ad-hoc.
  This is the crux of permission persistence: macOS TCC keys a grant to the code signature + bundle
  id + bundle path, so an ad-hoc signature (which changes every build) makes macOS forget
  Microphone/Screen Recording and re-prompt on each rebuild. With the stable identity, **grants
  persist across rebuilds and relaunches.** There is no ad-hoc fallback — `build-app.sh` always signs
  with `Jarvis Dev`. On the first build macOS prompts once to let `codesign` use the new key (click
  "Always Allow").
- **Permissions: TCC prompts, not entitlements.** Screen Recording and Microphone are granted by
  the OS on first use (no App-Sandbox entitlement file). `Permissions.primeAll()` requests them at
  launch and is **idempotent**: once a permission is `authorized` it only logs and never re-prompts,
  and Start/Stop never touches permissions. Persistence holds as long as three things stay fixed:
  the **stable signing identity**, the **bundle id** (`com.jarvis.coach`), and the **bundle path**
  (moving `Jarvis.app` re-prompts). Recover a stale *denied* state — which macOS won't re-prompt for
  — with `tccutil reset Microphone com.jarvis.coach` (or `ScreenCapture`), then relaunch and Allow.
- **Account:** built in the main `forrest` account inside a **git worktree** (the restricted-account
  requirement is waived for the personal build — see [sandbox.md](./sandbox.md)).
- **Always launch with `open ./Jarvis.app`**, never the bare binary. Running the executable from a
  terminal makes TCC attribute the grants to the shell, so the app reports Microphone/Screen
  Recording as "denied" even when they're granted. To pass flags, use `open ./Jarvis.app --args …`.
- Target: a working MVP in **< 2 days of autonomous Claude Code build**.

### Dev mode — live activity viewer

For watching Jarvis reason during development, a **dev mode** is enabled by the launch flag
`--dev` (`scripts/build-app.sh --dev` rebuilds and launches via `open ./Jarvis.app --args --dev
--log-dir "$PWD/.jarvis"`). In dev mode the app writes a **self-contained, auto-refreshing HTML page**;
it does **not** auto-open — choose **Open Log Viewer** from the menu bar to open the current session's
page on demand:

- `ActivityLog` (in `JarvisCore`) mirrors **every `jlog` line** into the page — so lifecycle,
  errors, realtime-socket events, and the coach's per-turn decisions all appear with no extra
  wiring. The page reloads every second (`<meta http-equiv="refresh">`), color-codes events, and
  keeps your scroll position unless you're pinned to the bottom. No server — it works off `file://`.
- The viewer keys on human-readable markers: 🗣 `heard: "…"` (your transcribed speech, logged by
  the transcriber) / 🤫 silence (why it woke), 💭 thinking, 👁 `capture_screen`, 💬 the spoken tip,
  and `… staying silent` when the model declines to speak. A `capture_screen` is saved as an
  owner-only JPEG next to the HTML and rendered inline as a **clickable thumbnail** (opens full size
  in a new tab) — so the log shows the visual part of the interaction, not just text.
- **Privacy posture (important).** File logging is **off unless dev mode is on** — outside dev mode
  `jlog` writes only to the unified log (Console.app), never a flat file. In dev mode the activity
  HTML, `jarvis-debug.log`, *and* the screenshot JPEGs are written to a **per-launch session
  subdirectory** under the `--log-dir` (default per-user `Caches/Jarvis`; `--dev` points it at a
  **gitignored `.jarvis/` in the workspace**). Files are **`0600`** and the session directory
  **`0700`** (both owner-only); each launch is a fresh subdirectory. Never `/tmp` (world-readable,
  shared across users).
  Env overrides `JARVIS_LOG` / `JARVIS_ACTIVITY_HTML` exist for headless/test use. This keeps the
  model's screen-derived tips out of any world-readable or persistent location — see
  [sandbox.md](./sandbox.md).
