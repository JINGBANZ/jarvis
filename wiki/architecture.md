# Architecture

> A living document. Describes the vision, the harness loop, the components, and the principles
> that govern Jarvis. Exact schemas, prompts, and config are not duplicated here — they live in
> `Sources/JarvisCore/` (`ToolDefs.swift`, `Config.swift`, `CoachDriver.swift`).

> **Scope:** This page describes the **native Swift app** — the thing being built. The earlier
> two-phase plan (a Natively fork PoC first) was **dropped on 2026-06-14**; we build this directly,
> including the hybrid screen-context loop. See [decisions.md](./decisions.md).
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
speaker-labeled transcript. The transcript — not the screen — is the constant remote input signal.

Screen context is hybrid and still bounded. On ordinary speech, the model applies a general
freshness rule and can call `capture_screen` whenever the meaning of the conversation suggests a
question, prompt, code, or solution may have appeared or changed; there is no phrase list. The
harness pre-captures on silence/manual-hint checks and after a locally detected stable screen
change. Low-rate, low-resolution one-shot ScreenCaptureKit screenshots compare visible pixels
locally without opening a persistent screen-sharing session. After visible content settles, one full
capture plus on-device OCR verifies that it actually changed. The snapshot first waits to join the
next speech request at no extra request cost; a tightly rate-limited screen-only request is the
fallback. Silent monitor turns that produce no tip are not retained in conversation memory. The exact
accepted snapshot becomes the auditable coaching image; intermediate frames are neither sent nor
retained. A coaching response is still produced only when the model calls `speak`.

### The turn

1. The Transcriber emits a **turn-end** event (`gpt-4o-transcribe` server VAD ends the turn after a
   tuned silence window), a **silence check** fires (you've gone quiet, maybe stuck), or the local
   screen monitor reports a stable visual change. The silence
   check carries *how long* you've been quiet and backs off across a long silence (the interval
   doubles each step up to a cap — see `Config`), resetting on speech; past an idle cutoff it stops
   probing entirely (you've stepped away — a nudge into an empty room still bills a request) until
   speech re-arms it.
2. The CoachDriver calls the brain on every trigger that carries **substance** — there is no general
   audio-turn cooldown, rate cap, or wake-word gate (the screen-only monitor fallback is bounded
   before it reaches the driver). Whether to speak (and whether the user just addressed
   Jarvis) is the model's call, governed by the system prompt; the only hard gates are the user's
   Start/Stop and the **substance gate** (`TurnSubstance`): a turn-end whose delta is pure
   back-channel filler ("Hmm", "嗯") or empty is skipped without a request. Classification is
   speaker-aware only where conversational meaning demands it: a short interviewer rejection such
   as "No" is substantive, even though the same user-side fragment is normally filler. Interviewer
   questions remain first-class and may draw a proactive tip. Skipped lines ride along on the next
   substantive turn; silence checks, visual changes, and the hint hotkey always go through.
3. It calls **`gpt-5.5`** with the coach system prompt, the session memory (`CoachHistory`), the
   new transcript delta, the timing context (seconds silent, session elapsed), and the tool set
   `[capture_screen, speak, stay_silent]`. The timing is what lets the model tell "thinking" from
   "stuck."
4. Silence, manual hints, and stable local screen changes arrive with a harness-captured image plus
   OCR. A stable monitor snapshot piggybacks on the next speech request when possible; only the
   fallback creates a screen-only request, under the monitor's cost interval. On ordinary speech,
   the model decides from the meaning of the turn whether it needs to call `capture_screen`; a
   screenshot from conversation history is explicitly not evidence of current state. Every
   successful capture resets the local monitor's baseline. If an early capture is still blank, the
   monitor supplies a new turn after the subsequently updated screen becomes stable.
5. The model calls `speak(lines)` — a tip of up to ~3 short lines, returned **already split**
   into an array (Structured Outputs / `strict:true`), so the client never splits prose on
   punctuation — or `stay_silent`. A tool call is **required** on every turn: silence is an
   explicit tool, never plain text, so the session memory stays free of stray model prose
   (see [decisions.md](./decisions.md)).
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
brain round-trip what a model-requested screen path needs two for: the harness captures the screenshot
*itself* and injects it — plus a synthetic "give me a hint now" user message — into the *first*
request, and forces the `speak` tool, so a screen-aware hint always comes straight back. Other
deterministic visual triggers also pre-capture, but do not force speech; ordinary audio turns may
still let the model call `capture_screen` and reason over the result on a second trip. It reuses the
live session's brain, conversation, and transcript, so the hint has full context, and it routes
through the same single-in-flight turn box as audio triggers (a press coalesces, never stacks). It is
inert — a beep — when no session is running, since there is no live conversation to hint from. The
trigger and its pre-filled message are recorded to the [activity viewer](./build-and-run.md), so you
can see exactly what the shortcut sent to the brain.

The hotkey is registered with **Carbon `RegisterEventHotKey`**, the one global-shortcut API Apple
never modernized, which needs no Accessibility/TCC permission. We deliberately did **not** take the
`KeyboardShortcuts` package: every modern release uses SwiftUI macros (`@Entry`/`#Preview`) whose
plugins ship only with full Xcode, and Jarvis builds **CLT-only** (see
[build-and-run.md](./build-and-run.md)). The binding is fixed for now; a rebinding UI is a later nicety.

## 3. Components

| Component | Responsibility | Built on (borrowed) |
|---|---|---|
| **AggregateEchoCapture** | The whole capture path: one **private Core Audio aggregate device** = the built-in mic (`me`, clock master) + a system-output **process tap** (`them`, drift-compensated onto the mic's clock). A single IOProc delivers both sample-synced at the device's **native rate** — the one-clock case AEC3 needs; the capture **reads that rate and resamples mic+tap up to 48 kHz** for AEC3 (a no-op when the device is already 48 kHz). So **any input device works** — built-in, USB, 44.1 kHz gear, or AirPods (Bluetooth HFP at 16/24 kHz) — instead of the old hard 48 kHz pin that silently failed to start on Bluetooth mics. Inside the callback it runs AEC3 (tap = far reference, mic = near), removing the other side's speaker bleed from the mic *before* transcription — no headphones, and double-talk works (measured 30–50 dB cancellation). The untouched resampled tap remains the `them` source while a separate padded/truncated copy aligns AEC; wire delivery is serialized off the realtime IOProc. Then both sides downsample to 24 kHz. Replaces the old separate `AVAudioEngine` mic + `SCStream`. | Core Audio (`AudioHardwareCreateProcessTap`, private aggregate device, drift compensation) + `AVAudioConverter` resampling + WebRTC **AEC3**. |
| **WebRTCEchoCanceller** | AEC3 echo canceller driven at 48 kHz on 10 ms frames inside the capture IOProc; far reference first, then the mic cleaned in place. | WebRTC **AEC3** (`webrtc-audio-processing`), vendored static + zero-dylib via `scripts/build-aec.sh`. |
| **ErrorReporter** | The single funnel for user-facing failures. Severity on a Foundation-only `UserFacingError` (in Core) decides the response — `fatal` pops an `NSAlert` and tears the session down, `warning` alerts without touching a running session (preflight refusals), `degraded` is logged only — so no startup failure is ever silent. The only place an *error* `NSAlert` is raised (confirmation prompts aside); diagnostics stay in `JarvisLog`. | AppKit (`NSAlert`). |
| **Transcriber** | Maintain a rolling, speaker-labeled, **spoken-time timestamped** transcript; emit turn-end events and backing-off silence checks (with quiet duration). Two instances run in parallel — one per side — tagging lines `me`/`them` into one shared transcript. A per-`item_id` ledger reconciles out-of-order delta/completed/failed/VAD events, salvages streamed text, and emits an explicit context-gap marker when a detected utterance cannot be recovered. A privacy-preserving continuity witness records content-free capture/delivery/socket/server checkpoints and locally derived activity, so the session log can locate a future gap without retaining PCM. A socket is ready only after the server acknowledges its configuration; active ping/pong probes, send/receive errors, and startup timeouts all drive the same reconnect path. | `gpt-4o-transcribe` (Realtime API; tuned `server_vad`). |
| **CoachDriver** | The event loop. On every substantive trigger (plus every silence check, stable visual change, and hint keypress), call the brain with the session memory + transcript delta + timing context and tools, route tool calls, and compact the memory when it grows long. It attaches harness-provided snapshots for silence/manual/change triggers and otherwise leaves capture judgment to the model. No cooldown/rate cap — restraint is the model's; the only client-side skip is the filler-only turn-end gate (`TurnSubstance`). | `gpt-5.5` (vision + tool-use) with `gpt-5.4-mini` for memory summaries — or a local Claude Code / Codex CLI on the user's subscription (see [§4 Local CLI brain providers](#local-cli-brain-providers)). |
| **ScreenTool** | Fulfill `capture_screen`: silently shoot the **active window** (default scope) — the window-server frontmost, on whichever display, clean even when partially covered — and attach an **on-device OCR** of the shot to the tool result so the model reads exact text instead of pixels. Falls back to a full-display capture (no OCR) — the Settings-chosen display in Entire-display scope, the main display when no window is eligible; the overlay window is excluded either way. See [settings-window.md](./settings-window.md#capture-scope). | macOS `screencapture` CLI + Apple Vision (`VNRecognizeTextRequest`). |
| **ScreenChangeMonitor** | From session start, take low-rate one-shot ScreenCaptureKit screenshots at a bounded resolution, avoiding a persistent macOS sharing session. `ScreenFrameActivityClassifier` compares one grayscale byte per pixel with the prior poll; visible changes feed `ScreenActivityDetector`, and unchanged polls advance quiescence. Only then does `InMemoryScreenCapture` take one full capture and use a content-free OCR/image fingerprint to suppress duplicates. The stable snapshot waits briefly to piggyback on speech, then falls back to a screen-only request under a strict minimum interval. Intermediate pixels remain memory-only; the accepted snapshot enters `CoachDriver`, and failed delivery re-arms it. | `SCScreenshotManager` + Foundation-only frame/activity/content state machines. |
| **Overlay Caption** | Render `speak` output: up to ~3 short lines (model-split), shown one at a time and queued so a newer tip never cuts off the current one; non-activating, always-on-top, excluded from capture. Switchable from Settings — **off by default**; when off, tips are suppressed. | AppKit NSPanel; `OverlayCaptionPanel`. |
| **Overlay Box** | A persistent window logging every `speak` tip in full, timestamped — the scrollable history of what the caption flashed one line at a time. Movable, resizable, opaque, also excluded from capture; switched on/off from Settings (**on by default**), cleared on each Start. Fed by the same `speak` call as the caption via **`BroadcastOverlay`**, which fans one `OverlayRendering.render` out to both sinks (so `CoachDriver` is unchanged). | AppKit NSPanel; `OverlayBoxPanel`. |
| **MenuBar** | Manual **Start/Stop** of the pipeline (no auto-start), an explicit connection state (starting, listening, reconnecting, system-audio connecting, microphone-only, or stopped), and one-time API-key entry. It turns green only when the microphone transcription socket is configured and ready. The two overlay surfaces are switched from Settings, not the menu. | AppKit menu-bar item; owner-only file for the key. |
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
`UserFacingError` decides the response (`fatal` → `NSAlert` + session teardown; `warning` →
`NSAlert` only, for preflight refusals that must not kill a live session; `degraded` →
log only), so a startup failure can never again flip the menu green and silently revert. Per-failure
copy and severity live in a Core **catalog** (`UserFacingError+Catalog`), the single source of truth
for *which* failures are loud — unit-tested in Core (e.g. the system-audio degrade must stay quiet),
since `JarvisApp` itself can't be headlessly tested and the `NSAlert` display stays a manual smoke
check. Realtime health is a visible state rather than a fatal-only event: startup stays gray,
reconnect attempts are shown, and microphone-only mode is explicit when the secondary system-audio
socket cannot recover. Diagnostics remain `JarvisLog`'s job; `ErrorReporter` owns surfacing +
lifecycle consequence.

## 4. Data Flow & Cost Model

- **Continuous (cheap):** audio → Realtime → transcript. This runs the whole session.
- **Per-turn (cheap):** a `gpt-5.5` call on each substantive turn-end and each silence event, with a
  bounded, mostly-cached working set. Filler-only turn-ends (from either speaker) are skipped
  client-side — free. No per-turn screenshot default.
- **Local visual watch (bounded):** low-resolution one-shot ScreenCaptureKit captures compare visible
  pixels locally without an ongoing sharing session. A full capture and OCR happen only after
  quiescence; unchanged content is suppressed, and intermediate poll pixels are never sent, encoded,
  OCR'd, or persisted (only the immediately previous grayscale frame is held).
- **On-demand (expensive):** a screenshot + vision tokens when the model calls `capture_screen`, or
  when a silence/manual hint or stable local screen change requires current visual context. Stable
  changes first piggyback on a speech call; a screen-only fallback is rate-limited. A coaching
  response is still produced only when the model calls `speak`.

The model remains the response governor, while the harness guarantees freshness at the few points
where stale or missing visual context would make that judgment unreliable. This avoids both a
per-turn screenshot tax and the failure mode where a screen-blind model elects not to look.

### Models and APIs

- **Brain — `gpt-5.5` via the OpenAI Responses API** (`POST /v1/responses`), not Chat Completions:
  for the gpt-5 family, function/tool calling is the recommended (and least restricted) path on
  Responses. The tool loop is threaded with `function_call` / `function_call_output` items, with the
  model's `reasoning` items replayed verbatim ahead of the call — OpenAI's requirement for the model
  to continue its chain of thought over a tool result instead of re-reasoning from scratch.
- **Per-session memory — client-managed (`CoachHistory`).** The coach needs to remember its *own*
  prior replies (the transcript only holds user speech), so `CoachDriver` keeps the session memory
  itself and rebuilds every request as `[system] + memory + new delta`. Owning the memory is what
  keeps it small and cheap: it grows **append-only** (a byte-identical prefix, so OpenAI's prompt
  cache keeps hitting at ~90% discount); `stay_silent` turns leave no trace; screenshots and reasoning
  items live only inside the turn that produced them — at commit, the pixels become a one-line stub
  and the capture's OCR text (in the tool result) is what persists, and reasoning items are dropped;
  and past a token threshold (see
  `Config.historyCompactionTokenThreshold`) the oldest span is **compacted** into a short structured
  summary written by a cheaper model (`gpt-5.4-mini`), so the problem statement never falls out of
  context. Requests are sent `store:true` so they stay inspectable in the OpenAI dashboard for
  debugging — the retention tradeoff is documented in [sandbox.md](./sandbox.md).
- **Transcription — `gpt-4o-transcribe` over the GA Realtime API** with **tuned `server_vad`** (not
  `semantic_vad`, which is reported flaky in transcription-only mode — it can stop emitting
  `…transcription.completed` entirely). Realtime events are reconciled by `item_id`: deltas are
  retained until completed/failed, audio-start timestamps preserve spoken order, and a stopped item
  without a terminal event is salvaged or marked as a context gap after a bounded deadline. Turn-end
  fires only after usable text or that explicit gap lands, plus a client-side debounce so a brief
  mid-thought pause doesn't fragment one sentence into several turns.

### Local CLI brain providers

The brain can alternatively run through a locally installed **Claude Code** or **Codex** CLI
(`BrainProvider`, selected in [Settings → Brain](./settings-window.md#brain)), so coaching turns are
billed to the user's existing Claude / ChatGPT **subscription** instead of the metered API key.
`CLIBrainClient` implements the same `BrainClient` protocol, so `CoachDriver`, the client-managed
memory, retries, and traffic recording are all unchanged — only the transport differs:

- **One stateless subprocess per turn** (`claude -p` / `codex exec`, spawned by
  `AgentCLIProcessRunner`) — no CLI session is created, resumed, or left behind: every call is
  self-contained (client-managed memory, same as the API path), the CLIs run with session
  persistence off (`--no-session-persistence` / `--ephemeral`, so no transcript copy lands in
  `~/.claude` / `~/.codex`), and the process dies with the turn — at reply, at the SIGTERM→SIGKILL
  timeout watchdog, or **immediately when Stop cancels the turn** (task cancellation kills the pid,
  so a cancelled turn never keeps burning quota). Since the CLI has no native function calling, the
  `ToolDef`s are rendered as a **JSON tool protocol** — the model ends its reply with
  `{"tool":…,"arguments":{…}}`, parsed back into the same `ToolInvocation`s (with prose/code-fence
  tolerance, and a forced `speak` degrading to speaking the raw reply so a hotkey press never
  silently vanishes).
- **Every turn is one model call.** Claude takes its input as a stream-json message, so screenshots
  ride **inline as base64 image blocks** — same call, no disk copy, no Read-tool round trip — and
  with `--tools ""` (every built-in disabled) a turn can't go agentic at all. Codex has no inline
  image input, so for it screenshots become 0600 files in the per-session log directory (which
  already persists every screenshot the model sees — same data posture), attached via `-i` and
  deleted when the run finishes; its coach turns have nothing to execute, so they're single-call in
  practice. Codex runs `--sandbox read-only`; Claude runs with its persona replaced
  (`--system-prompt`) and no settings sources, and the one reasoning-effort setting maps onto each
  CLI's own scale.
- **Installed CLIs are auto-detected** (`AgentCLIDetector`: file probes over $PATH + known install
  dirs + on-disk auth markers — no subprocess, no Keychain prompt), so selecting one is one click.
- **The OpenAI key stays required**: transcription always runs on the Realtime API. A CLI provider
  moves the brain/summarizer/evaluator off the key, not the ears. **Latency is the tradeoff**,
  though a modest one now that every turn is one model call: measured coach turns run ~2.6s (text)
  / ~3.3s (with screenshot) on claude sonnet at low effort, ~5–8s on codex — versus the direct
  API's sub-2s target. The invocation is kept deliberately slim (persona replaced, no settings
  sources or personal codex config — `--ignore-user-config` — **zero MCP servers** via
  `--strict-mcp-config` / `-c mcp_servers={}`, no built-in tools),
  so what remains is irreducible from outside: claude's floor is ~0.7s of process overhead + model
  time; codex's is ~4.7s even for a trivial prompt because its fixed coding-agent scaffold (a
  built-in multi-thousand-token system prompt that `exec` offers no flag to replace) rides every
  call. The pipeline absorbs it (single-in-flight turns coalesce; the overlay paces display). If
  more is ever needed, the escalation is a long-lived interactive CLI process (stream-json in/out
  with `/clear` between turns — verified to work) — worth its lifecycle complexity only for
  claude's last ~0.7s, so it's deliberately not built; per-turn session *resume* is pointless (it
  still pays startup per call).

### Latency

Target: **turn-end → first overlay line < 2s.** It holds because transcription is continuous
(no STT latency at trigger time) and most turns are text-only (no `capture_screen`), so the brain
call is a single short round-trip. The overlay then reveals the already-returned lines one at a
time (paced by `Config`), so the first tip appears immediately — note the brain response itself is **not**
streamed (one buffered request; the overlay just paces the display).

### Resilience

The capture edge keeps two system-audio representations for different contracts: transcription
preserves every real tap sample and pads only a short/empty callback's missing silence so Realtime
VAD keeps advancing; AEC receives a separate exact mic-length padded/truncated reference. Neither
path disables AEC or changes the configured Realtime noise-reduction profile.

Stable-screen duplicate suppression likewise combines two local, content-free signals: normalized
OCR and a tolerant 64-bit perceptual image hash. This keeps diagrams, highlighting, and OCR-missed
edits visible without reacting to small JPEG/pixel drift. The one full snapshot bound to a request is
persisted before network send for audit, but its monitor baseline advances only after success; a
newer candidate that settled behind an older in-flight request is resumed rather than discarded.
Monotonic capture ordering prevents an ordinary screenshot from clearing activity observed after
that screenshot began, and switching the watched window/display forces a full-stage reconciliation.
At the cheaper first stage, the downscaled pixels must visibly differ; identical one-shot polls
advance quiescence regardless of how often an app redraws internally. Content-free witness counters
separate changed polls, idle polls, failed polls, full captures, duplicates, piggybacks, and
screen-only requests.

The always-on legs are built to survive transient failure rather than die on it:

- **The realtime transcription socket *will* drop** (network blips, server resets, the ~60-min
  session cap) and a Realtime session **cannot be resumed** — a dropped connection means a new
  session. A socket is not declared ready at the WebSocket handshake: the transcriber waits for the
  server's session-configuration acknowledgement under a startup deadline. Once ready, ping/pong
  probes expose an idle half-open connection before the user's next utterance; send, receive, close,
  startup-timeout, and liveness failures all enter one idempotent reconnect path. Each replacement
  socket has a generation so stale callbacks cannot damage the new one, and diagnostics label the
  `me`/`them` side, socket generation, server session, and current macOS network-path summary. While
  reconnecting, audio remains in one **transactional FIFO plus recovery tail** (`PCMBuffer`, capped at
  `maxBufferedAudioSeconds`). Exactly one oldest chunk is claimed at a time. A successful URLSession
  callback moves it into the in-memory tail rather than deleting it, because Realtime intentionally
  sends no confirmation for `input_audio_buffer.append`; only server VAD/transcription audio-clock
  progress retires a safe prefix. On failure, the unconfirmed tail is requeued ahead of audio captured
  during reconnect backoff. This closes the ready-transition, asynchronous-send, and idle half-open
  loss edges; deliberate cap eviction is logged and carried as an explicit context warning. Within a
  healthy socket, streamed transcript deltas survive
  a failed/missing terminal event;
  an unrecoverable detected utterance becomes an explicit context-gap line instead of disappearing.
  Sequence/sample/timestamp checkpoints cover the capture, delivery, WebSocket attempt/completion,
  and server-event boundaries. Periodic content-free summaries and typed anomalies show which
  boundary stopped advancing; sustained local activity without a server speech event leaves an
  explicit warning for the next real coach turn. This evidence diagnoses loss but cannot reconstruct
  words that never reached transcription.
  VAD-only start/stop events do not restart silence checks without contributing context. Pending
  items are finalized by bounded stopped/active deadlines. On a recoverable socket failure, their old
  server IDs are cleared and their retained PCM is transcribed by the replacement session instead of
  first emitting a partial/gap that the replay would duplicate; terminal reconnect failure still
  finalizes what text is available. Stale speech state therefore cannot suppress silence coaching
  after reconnect. Reconnect uses capped exponential backoff.
- **The brain call** is single-flighted (a turn can't double-speak) and runs under a generous request
  timeout — a hang backstop set well above the reasoning-turn tail, so a slow turn is waited out, not
  abandoned. Because client-owned memory makes every request self-contained and tool effects happen
  only after a response reaches the driver, a transient transport failure or retryable server error
  gets **one immediate automatic retry** without duplicating a screenshot or spoken tip. Cancellation,
  authentication, malformed requests, rate limits, and other permanent failures do not retry. If both
  attempts fail, recovery remains on the **next trigger** — sent-state advances only on a successful
  send, so that turn includes the failed transcript plus anything newer. Memory **compaction** fails
  soft without this wrapper: a failed summary simply leaves the full history for the next attempt.

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
  to `gpt-5.5` only on a model-requested or harness-provided fresh-screen coaching turn. Local change
  frames are neither sent nor persisted. The audio witness persists only counters, sequence/sample
  metadata, timestamps, socket generations, server audio-clock values, and a local activity bit in
  the owner-only session log — never PCM or recovered words. The only screen-/audio-derived data
  written to **local** disk is the owner-only, bounded per-session **activity log** (spoken tips,
  transcribed lines, the screenshots the model saw); raw mic audio and the live transcript are never
  archived. Requests are sent `store:true`, so what the model saw does remain inspectable (and
  retained) server-side at OpenAI for debugging (see [sandbox.md](./sandbox.md)).
- **Behavioral restraint (model-governed):** there is no general audio-turn cooldown or rate cap in
  code; the stable-screen fallback alone has a strict cost interval because it can create a request
  without speech. Pending screen context still joins the next speech request for free, and a silent
  monitor turn that produces no tip does not enlarge later prompts. Every
  substantive utterance — from either speaker; only back-channel filler is skipped as pure cost —
  reaches the brain, and the brain decides whether it has anything worth
  saying — that restraint lives in the system prompt (see [`coachSystemPrompt`](../Sources/JarvisCore/Coach/ToolDefs.swift)).
  This keeps
  conversation natural: a follow-up question is never stranded behind a timer. The hard control is
  the menu-bar **Start/Stop** — coaching never runs until explicitly started, and stopping tears the
  pipeline down entirely. Cost is accepted as tracking usage for now (a future improvement, not a
  v1 guardrail).

## 6. Non-Goals (v1)

- Multiple modes / a tiered sensitivity dial. (One mode: LeetCode Coach.)
- Recording the screen/audio to disk for recall. Stable-change monitoring is in-memory during an active
  coaching session and persists only the stable screenshots the brain actually sees.
- A dedicated wake-word engine. Direct address is just the word "Jarvis" (or a question) appearing
  in the transcript, which the brain reads and answers — there is no wake-word detector. (A global
  **⌥⌘J** hotkey for an on-demand screen hint *does* exist — see [§2](#on-demand-hint-j) — but it
  complements the proactive default; it is not a trigger-to-listen wake key.)
- Productization: auth, billing, onboarding.
- Windows / cross-platform.

## 7. Design Principles

1. **Build the harness, not the intelligence.** If a model or an OS framework can do it, we don't write it.
2. **Least code wins.** Prefer a borrowed tool (`screencapture`, an Apple framework, an OpenAI API) over custom code, every time.
3. **The model is the response governor.** Speaking always requires a model tool call; vision is
   model-requested on ordinary speech and harness-provided for silence/manual hints and stable local
   changes, never a screenshot on every turn.
4. **Proactive, but disciplined.** Speaking up unprompted is the whole point; the model's own restraint (a tuned system prompt) keeps it from being annoying.
5. **Sees the screen, not the disk.** Security is enforced by the sandbox, not by good intentions.
6. **Self-verifying.** Every build ships with tests and a smoke checklist the agent can run to prove it works.
7. **One mode, done well.** Ship the coach; expand later.

How Jarvis is built, signed, tested, and run — and the activity viewer — is its own
operational page: [build-and-run.md](./build-and-run.md).
