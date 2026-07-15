# Decisions

> The project's decision log — *why* Jarvis is the way it is. One entry per load-bearing, non-obvious
> choice. Unlike the rest of the wiki, this page is **append-mostly and historical**: it is the one
> place [`CLAUDE.md`](./CLAUDE.md) → Convention 3's "write in the present, delete the narration" rule
> does **not** apply, because the rejected alternative is exactly what you don't want to lose. A
> running list, newest last, each entry dated. When a decision is reversed, **supersede it in place**
> (add the `Superseded by` / `Supersedes` lines); never delete it. The *how it works* lives in the
> core design pages — the `Detail:` line links to it rather than restating it here.

### 2026-06-13 — Build our own proactive coach

- **Chose:** Build a native macOS coaching tool from scratch.
- **Why:** No maintained tool does proactive, unprompted speak-up coaching well.
- **Rejected:** Forking/using existing tools — all closed, paid, or answer-dumping (LockedIn AI is the best behavior reference only).
- **Detail:** [landscape-survey.md](./landscape-survey.md), [fork-evaluation.md](./fork-evaluation.md).

### 2026-06-13 — Personal tool first

- **Chose:** A personal single-user tool — no auth/billing, freely reuse open code, <2-day MVP target.
- **Why:** Fastest path to a working coach; product infrastructure is premature.
- **Rejected:** Building shippable product scaffolding up front.
- **Detail:** [architecture.md](./architecture.md).

### 2026-06-13 — Proactive, unprompted coaching is the core differentiator

- **Chose:** Proactive by default; ⌥⌘J is an optional on-demand hint, not a wake key.
- **Why:** Speaking up unprompted is the differentiator versus every wake-word assistant.
- **Detail:** [architecture.md](./architecture.md).

### 2026-06-13 — One mode for v1: LeetCode Coach

- **Chose:** A single coaching mode, no tiers.
- **Why:** Scope discipline for the MVP.
- **Detail:** [architecture.md §6](./architecture.md#6-non-goals-v1).

### 2026-06-13 — Model-triggered `capture_screen`

- **Chose:** The brain decides when to capture the screen, via a tool-use loop.
- **Why:** Cheaper and smarter than capturing on every turn.
- **Rejected:** Always-on screen capture.
- **Detail:** [architecture.md §2](./architecture.md#2-core-loop).

### 2026-06-13 — Coach is time-aware

- **Chose:** Feed a timestamped transcript plus silence duration to the coach.
- **Why:** Lets it reason about pacing and when to nudge.
- **Detail:** [architecture.md §2](./architecture.md#2-core-loop).

### 2026-06-13 — Native Swift app

- **Chose:** Native Swift.
- **Why:** Cleanest sandbox/footprint on macOS.
- **Detail:** [architecture.md](./architecture.md), [fork-evaluation.md](./fork-evaluation.md).

### 2026-06-13 — Toolchain: SwiftPM + Command Line Tools

- **Chose:** SwiftPM + CLT, no full Xcode; a hand-built `.app` bundle signed with a stable self-signed `Jarvis Dev` identity.
- **Why:** Removes the Xcode dependency; the stable identity keeps TCC grants across rebuilds.
- **Detail:** [build-and-run.md](./build-and-run.md).

### 2026-06-13 — Server-side conversation per session

- **Chose:** OpenAI Conversations API (`store:true`) for the coach's own multi-turn memory.
- **Why:** Multi-turn coaching quality over local-only retention.
- **Rejected:** Local-only conversation state.
- **Detail:** [architecture.md](./architecture.md#models-and-apis), [sandbox.md](./sandbox.md).

### 2026-06-13 — Activity viewer is an in-app `WKWebView`

- **Chose:** An in-app `WKWebView` viewer — live push (no meta-refresh), screenshot lightbox, persisted JSONL history + clear-history.
- **Why:** Live updates and full session visibility without page reloads.
- **Detail:** [build-and-run.md](./build-and-run.md).

### 2026-06-13 — Overlay hidden from screen capture via `sharingType = .none`

- **Chose:** Set the overlay `NSPanel` `sharingType = .none`, re-asserted on `show()`.
- **Why:** The overlay must not appear in shared/recorded screen; verified on macOS 26.5 including a live `SCStream`.
- **Detail:** [overlay-invisibility.md](./overlay-invisibility.md).

### 2026-06-14 — Two-phase build (fork Natively first)

- **Chose:** A two-phase plan — fork Natively as Phase 1, then build native.
- **Superseded by:** 2026-06-14 — Skip Phase 1; build native Swift directly.
- **Detail:** [fork-evaluation.md](./fork-evaluation.md).

### 2026-06-14 — Skip Phase 1; build native Swift directly

- **Chose:** Drop the two-phase plan and build the clean native app now.
- **Why:** The fork eval and survey already establish the why-build-our-own basis; Natively is at most a reference, not a base.
- **Rejected:** Forking Natively as Phase 1.
- **Supersedes:** Two-phase build (fork Natively first).
- **Detail:** [fork-evaluation.md](./fork-evaluation.md).

### 2026-06-14 — Restricted-account requirement (hard)

- **Chose:** Require building in a separate restricted macOS account.
- **Superseded by:** 2026-06-14 — Build in the main account, restricted-account requirement waived.
- **Detail:** [sandbox.md](./sandbox.md).

### 2026-06-14 — Build in the main `forrest` account, restricted-account requirement waived

- **Chose:** Build in the main account inside a git worktree; waive the hard restricted-account requirement.
- **Why:** Accept the security tradeoff (an unsandboxed app can read the main account's files) for this personal build; the hardened model (App Sandbox + restricted account) stays documented as the path for any shippable version.
- **Supersedes:** Restricted-account requirement (hard).
- **Detail:** [sandbox.md](./sandbox.md).

### 2026-06 — Models verified

- **Chose:** `gpt-5.5` brain via the Responses API (tool-use + vision); `gpt-4o-transcribe` over the GA Realtime API; API-only, no local models.
- **Why:** Best available quality; verified against the docs in 2026-06.
- **Detail:** [architecture.md](./architecture.md#models-and-apis).

### 2026-06-15 — Tuned `server_vad` + debounce; quiet graceful Stop

- **Chose:** Tuned `server_vad` + debounce, and a quiet graceful Stop.
- **Why:** Fixes from the first live smoke run.
- **Rejected:** `semantic_vad`.
- **Detail:** [architecture.md](./architecture.md#models-and-apis).

### 2026-06-16 — System audio shipped

- **Chose:** `SystemAudioInput` (ScreenCaptureKit) → a second `them`-tagged transcriber beside the mic's `me`, into one shared transcript.
- **Why:** Captures the other side of the conversation.
- **Detail:** [architecture.md §3](./architecture.md#3-components).

### 2026-06-16 — Cut the guardrail layer

- **Chose:** No cooldown/rate cap and no wake-word detector; the brain self-gates speaking; the silence check backs off across a long silence.
- **Why:** Simpler flow, less log noise, more natural conversation.
- **Rejected:** Explicit rate-limiting / wake-word guardrails.
- **Detail:** [architecture.md §5](./architecture.md#5-safety-model).

### 2026-06-17 — `speak` returns a `lines` array via Structured Outputs

- **Chose:** `speak` returns a `lines` array (`strict:true`), not a free-form string.
- **Why:** The model splits the tip into overlay lines, so the client no longer splits prose on `.`/`!`/`?` (which shattered code like `Array.from(...)`).
- **Detail:** [architecture.md §2](./architecture.md#2-core-loop).

### 2026-06-17 — Unified Settings window

- **Chose:** One Settings window replaces the separate API-key dialog and log-viewer menu item; overlay text size + background opacity are user-adjustable and persisted via `OverlayAppearance`.
- **Why:** A single place for configuration.
- **Detail:** [settings-window.md](./settings-window.md).

### 2026-06-18 — Tuned overlay/silence timing + sharpened coach prompt

- **Chose:** Longer per-line overlay display, a later first silence nudge over a wider backoff ramp, plain-language hints, explicit `me`/`them` speaker handling; the overlay queues tips.
- **Why:** Better pacing without cutting off the current tip.
- **Detail:** [architecture.md §2](./architecture.md#2-core-loop).

### 2026-06-18 — Overlay is never-interrupt + never-drop

- **Chose:** Queue tips; never preempt the one on screen.
- **Why:** In a live interview the user never addresses Jarvis aloud, so all overlay traffic is proactive coaching with no latency-critical reply that needs to jump the queue.
- **Rejected:** Direct-reply queue-priority/preemption (show-freshest).
- **Detail:** [architecture.md §2](./architecture.md#2-core-loop).

### 2026-06-18 — AEC reverted to a plain `AVAudioEngine` tap (interim)

- **Chose:** Revert `VoiceProcessingIO` AEC; use a plain `AVAudioEngine` mic tap.
- **Why:** `VoiceProcessingIO` came up without throwing, but the `SCStream` starting ~150 ms later changed the audio route and the mic went silent (RMS 0).
- **Superseded by:** 2026-06-19 — Echo cancellation via one-clock aggregate device + AEC3.
- **Detail:** [architecture.md §3](./architecture.md#3-components).

### 2026-06-19 — Echo cancellation via one-clock aggregate device + AEC3

- **Chose:** Capture the mic + a system-output process tap in ONE private aggregate device (mic = clock master, tap drift-compensated) so a single IOProc delivers both synced at 48 kHz, and run AEC3 inside that callback.
- **Why:** The mic was bleeding the other side's speaker audio into the `me` transcript. One aggregate device removes the cross-clock drift that limited a prior two-clock attempt to ~5%; measured 30–50 dB cancellation live, no headphones needed.
- **Rejected:** Two-clock (separate mic + `SCStream` feeding AEC3) — the hard async-AEC case.
- **Supersedes:** AEC reverted to a plain `AVAudioEngine` tap.
- **Revisit if:** Double-talk under loud far audio over-attenuates the user — escalate to a neural canceller (DTLN/Muesli-style) on the same aligned streams.
- **Detail:** [architecture.md §3](./architecture.md#3-components).

### 2026-06-19 — Per-line overlay time is length-proportional

- **Chose:** `noticeBuffer + words × readingRate` (capped), plus a brief blank gap between lines.
- **Why:** Hybrid of the captioning reading-speed standard and our glance-not-watch situation.
- **Rejected:** Hard-coded per-line duration.
- **Detail:** [overlay-timing.md](./overlay-timing.md).

### 2026-06-20 — API key in an owner-only `0600` file, not the Keychain

- **Chose:** Store the API key in an owner-only `0600` file.
- **Why:** A self-signed (no Team ID) app's Keychain access keys to a per-build `cdhash`, so the Keychain re-prompts every rebuild; a file doesn't.
- **Rejected:** Keychain storage.
- **Detail:** [sandbox.md §3](./sandbox.md).

### 2026-06-20 — Brain model + reasoning effort are user-selectable

- **Chose:** A Brain settings tab picks the model from a code-owned `BrainModelCatalog` (default `gpt-5.5`) and one global reasoning effort (default `low`), persisted via `BrainPreferences` and applied on next Start; moved out of `Config`.
- **Why:** The catalog/enum becomes the single source of truth, and the user can trade quality versus cost/latency.
- **Detail:** [settings-window.md](./settings-window.md).

### 2026-06-20 — Persistent response box beside the overlay

- **Chose:** An optional Overlay Box (`OverlayBoxPanel`) logging every `speak` tip in full, also excluded from capture; fed via a `BroadcastOverlay` fan-out so `CoachDriver` is unchanged.
- **Why:** A full, scrollable history of tips.
- **Detail:** [settings-window.md](./settings-window.md), [overlay-invisibility.md](./overlay-invisibility.md).

### 2026-06-21 — Overlay surfaces renamed + independently switchable

- **Chose:** Overlay Caption (transient, `OverlayCaptionPanel`) and Overlay Box (persistent, `OverlayBoxPanel`), each with its own On/Off toggle (defaults: caption off, box on); visibility lives only in Settings. Repo-wide rename of `OverlayAppearance` keys + the `Applying` protocols.
- **Why:** Clear naming and independent control of the two surfaces.
- **Detail:** [settings-window.md](./settings-window.md).

### 2026-06-21 — On-demand hint hotkey (⌥⌘J)

- **Chose:** A global Carbon `RegisterEventHotKey` that, while running, captures the screen and forces a `speak` hint in one brain round-trip.
- **Why:** Complements proactive coaching. Raw Carbon over the `KeyboardShortcuts` package because that package's SwiftUI macros (`@Entry`/`#Preview`) need full Xcode and Jarvis builds CLT-only.
- **Rejected:** The `KeyboardShortcuts` package.
- **Detail:** [architecture.md §2](./architecture.md#on-demand-hint-j).

### 2026-06-22 — Activity log is always on; the `--dev` flag removed

- **Chose:** The activity log (Settings → Activity, plus owner-only per-session disk logs on every launch, pruned to the 10 most recent in the gitignored, workspace-local `.jarvis/`) is always on; removed the `--dev` flag that previously gated it.
- **Why:** The log is useful in every run, not just a dev mode; one always-on path is simpler and the disk logs keep the owner-only, no-`/tmp` posture.
- **Rejected:** Keeping the log behind a `--dev` flag.
- **Detail:** [sandbox.md](./sandbox.md).

### 2026-06-23 — Capture adapts to any input rate; startup fails loud

- **Chose:** Read the device's native rate and resample mic+tap up to AEC3's 48 kHz; centralize startup failures in an `ErrorReporter` (severity-driven `NSAlert`, `UserFacingError` in Core).
- **Why:** The old hard 48 kHz aggregate pin silently failed for devices that can't do 48 kHz (notably AirPods, HFP at 16/24 kHz); now any input device works, and failures surface instead of the menu lying green.
- **Rejected:** The hard 48 kHz aggregate pin.
- **Revisit if:** AirPods-as-mic HFP narrowband quality bites — use the built-in mic for fidelity.
- **Detail:** [architecture.md §3](./architecture.md#3-components).

### 2026-07-03 — Brain call: generous ceiling, one attempt, recover on next trigger

- **Chose:** A single server-side `conversation` per session with a **generous request timeout** (a hang backstop, not a latency knob) and **no in-request retry** — a failed brain call fails the turn and recovers on the next trigger, since sent-state advances only on a successful send.
- **Why:** A tight timeout abandoned a still-generating turn while the server kept the conversation's single-writer lock, so every following turn hit `conversation_locked` and the coach went silent for minutes. Turns are single-flighted, so waiting for a slow turn lets it finish and release the lock naturally; and because the driver re-sends the still-unsent transcript next turn, a retry would only resend a *staler* body while hammering a held lock.
- **Rejected:** (a) In-request retry with backoff — near-useless for `conversation_locked` (a >ceiling generation outlasts it) and it resends stale content; the only thing given up is `Retry-After` backoff on transient 429/5xx, negligible for a single-user app. (b) Cancel-and-send-the-latest via background mode + `POST /responses/{id}/cancel` — the only way to *abandon* a stale turn and jump to freshest context, but a much larger build; deferred.
- **Revisit if:** the app grows beyond single-user (429 backpressure starts to matter), or the ceiling-length wait on a genuinely slow turn proves too laggy live (then reach for background-mode cancel).
- **Superseded by:** 2026-07-15 — Explicit Realtime health and one transient brain retry. The generous ceiling and next-trigger fallback remain; the one-attempt rule does not.
- **Detail:** [architecture.md → Resilience](./architecture.md#resilience).

### 2026-07-06 — Silence is a tool call; audio turns require one

- **Chose:** A `stay_silent` tool alongside `capture_screen`/`speak`, with `tool_choice: "required"` on every audio-driven turn — the model must answer each turn with exactly one tool call, and a stay-quiet decision is the `stay_silent` call, never text.
- **Why:** Under "stay silent — call no tool" the model still has to emit *something*, and at low reasoning effort that came out as leaked deliberation text ("final empty. no. final."). With `store:true` + a server-side conversation, that junk was retained, replayed as context every turn — where the model imitated its own garbage and degenerated further — and re-billed as input on all subsequent turns of the session (a large share of a real hour-long session's ~$13 spend).
- **Rejected:** Filtering the text client-side — the driver already ignores it, but the *server-side conversation* stores whatever the model emits, so only preventing emission fixes it.
- **Detail:** `Sources/JarvisCore/Coach/ToolDefs.swift` (tool + prompt), `CoachDriver.swift` (required tool choice).

### 2026-07-06 — Capture display is a persisted 1-based `screencapture -D` index

- **Chose:** Settings → Screen stores the chosen display as the 1-based index `screencapture -D` uses (`ScreenCapturePreferences`, default 1 = main). `ScreenCaptureCLI` reads it at capture time (change applies to the next screenshot, no restart) and falls back to a plain main-display capture when `-D` fails (monitor unplugged since selection). A user-initiated Start with >1 display also prompts for the screen (`DisplayPicker`, pre-selected to the persisted choice; Cancel aborts the Start) so a session never silently coaches from the wrong screen.
- **Why:** The plain `screencapture` invocation only ever shot the main display, so with a laptop + external monitor the coach never saw the monitor. The index is the CLI's own addressing scheme — no ID translation layer — and for the common two-display case it's stable; the capture-time fallback makes a stale index harmless.
- **Rejected:** (a) Persisting a `CGDirectDisplayID` or display name — more code for stability the fallback already provides, and `screencapture` can't be addressed by ID anyway. (b) Auto-following the frontmost window / mouse across displays — implicit behavior the user can't override; an explicit picker was the ask. (c) Capturing all displays per trigger — doubles image tokens per brain call for a screen usually irrelevant.
- **Detail:** [settings-window.md → Capture Display](./settings-window.md#capture-display).

### 2026-07-07 — Filler-only turn-ends skip the brain (substance gate, speaker-neutral)

- **Chose:** A client-side cost gate in `CoachDriver`: a turn-end whose transcript delta is pure back-channel filler — from *either* speaker — or empty returns `.skippedFillerOnly` without a brain request. `TurnSubstance` decides per line: "?"/"Jarvis" always substantive; else normalize (lowercase, strip punctuation, collapse repeated characters) and treat the closed-class back-channel list (en+zh) and ≤2-character fragments as filler; everything else fails open to the brain. Skipped lines ride along on the next substantive turn (the sent-index only advances on a successful send); silence checks and the manual hint always go through, and every skip is logged for auditing.
- **Why:** Roughly 40–45% of an interviewer-heavy session's turn-ends are back-channel ("Hmm", "嗯", "对") that can never produce a tip, yet each re-billed the whole working set. Normalization + a closed class scales where a raw allowlist wouldn't: back-channels are a small closed set per language and the apparent variety is elongation, which collapsing absorbs. Gating on *what* was said (not *who*) keeps interviewer questions first-class — they may draw a proactive tip for the user (prompt relaxed accordingly).
- **Rejected:** (a) A them-only speaker gate — cheaper, but it silences Jarvis exactly when the interviewer asks the user a question. (b) A longer client debounce window (adds reply latency, merges less). (c) A classifier model for filler (~$0.03/hr and latency; unwarranted while the closed class + fail-open holds).
- **Detail:** `Sources/JarvisCore/Triggers/TurnSubstance.swift`, `CoachDriver.runTurn`.

### 2026-07-07 — Session memory moved client-side, with compaction

- **Chose:** Replace the per-session server-side conversation with client-managed memory (`CoachHistory`): every request is `[system] + memory + new delta`, memory grows append-only (stable prefix → prompt-cache hits), `stay_silent` turns leave no trace, only the newest screenshot stays as pixels (older → one-line stubs), and past `Config.historyCompactionTokenThreshold` the oldest span is condensed into a ≤250-word briefing by `gpt-5.4-mini`. Requests stay `store:true` purely so they remain inspectable in the OpenAI dashboard for debugging. Supersedes the conversation half of the 2026-07-03 entry (its generous-timeout and recover-next-trigger halves stand; its one-attempt half was later superseded on 2026-07-15).
- **Why:** A server conversation can only grow: every screenshot and every stored reply was re-billed as input on all ~350 turns of an hour session (~$12.60 of the observed $13). Owning the memory bounds the per-request working set (~5–6k tokens, mostly cached), keeps the problem statement in context forever via the summary, and removes a failure class outright (`conversation_locked`, dangling tool-call closes). The industry patterns adopted (compaction, observation masking, cache-ordered prefixes) and the cost model live in PR #46's design notes.
- **Rejected:** (a) Keeping conversations and rotating them with a summary seed — same summarization work, but retains the unbounded-growth window and the lock failure mode. (b) `store:false` for privacy — deferred by choice; debuggability wins while the harness is being tuned, and it's now a one-line flip.
- **Detail:** `Sources/JarvisCore/Coach/CoachHistory.swift`, `CoachDriver.compactIfNeeded`, [sandbox.md](./sandbox.md) for the retention posture.

### 2026-07-07 — `capture_screen` is window-scoped with an on-device OCR sidecar

- **Chose:** The default capture scope shoots the **frontmost app window** via `screencapture -l` — the window server keeps one z-order across all displays, so the pick (Core's `FrontWindowSelector`; own windows, non-app layers, and tiny helper windows skipped) is the window the user last clicked or typed into, on whichever monitor. The shot gets an **on-device OCR sidecar** (Apple Vision `.accurate`, language correction off; reading order via Core's `RecognizedTextLayout`) sent in the tool-result text beside the image. An explicit **Capture Scope** setting (Settings → Screen) reverts to entire-display; the display picker keeps governing entire-display mode and every fallback (no eligible window / window capture failed), which skip OCR so a whole display's clutter is never fed back as text.
- **Why:** The full-display shot billed every Retina pixel of dock/widgets/second-browser on each screen turn, and published distractor studies show irrelevant frame content measurably degrades reasoning-model accuracy; exact text beats pixels for reading code. Together these let **low** reasoning effort find bugs that previously needed **high** (the PoC to confirm). Vision runs on-device, so the no-new-egress posture holds. This *complements* the 2026-07-06 display decision: that rejected implicit display-*following* in favor of an explicit picker; this changes capture *scope*, stays an explicit overridable setting, and leaves the picker its fallback job.
- **Rejected:** (a) Downscaling / `detail` tuning — GPT-5.5 ingests full resolution (verified against the vision docs in the PR #30 investigation), so shrink the *area*, not the fidelity. (b) Accessibility-tree text extraction — Chrome exposes web content only under assistive-tech flags and Monaco virtualizes to visible lines; OCR gets the same generically with none of the per-app fragility. (c) OCR *instead of* the image — diagrams and layout need vision, and OCR mangles the odd identifier; the image stays ground truth. (d) Column-aware OCR ordering — deferred until the PoC shows two-column interleave actually hurts.
- **Detail:** [settings-window.md → Capture Scope](./settings-window.md#capture-scope).

### 2026-07-15 — Explicit Realtime health and one transient brain retry

- **Chose:** Treat Realtime connectivity as an explicit state machine. A transcription socket becomes ready only after the server acknowledges `session.update`; a startup deadline plus active ping/pong probes detect silent and idle failures; every failure source enters one generation-guarded reconnect path; and the menu shows starting/reconnecting/degraded states instead of claiming the pipeline is listening. Wrap each self-contained primary brain request in exactly one retry for transient network and retryable server failures, then preserve the existing next-trigger recovery.
- **Why:** Live sessions showed both startup and mid-session WebSockets being reset or losing the network, while the old app accepted the initial handshake as readiness and learned about an idle dead socket only when speech produced network I/O. A separate preflight connection would test a socket that the app immediately discards, so it cannot establish that the two real transcription sockets are healthy. Client-managed brain memory also removed the server-conversation lock that made an in-request retry unsafe: tool effects occur only after the response reaches the driver, so replaying the same request once cannot duplicate a screenshot or tip.
- **Rejected:** (a) A disposable startup connectivity test — it races the real sockets and can pass while they fail. (b) Passive WebSocket keepalive — it leaves half-open sockets invisible until the user speaks. (c) Retrying authentication, malformed requests, or rate limits — these need correction or backoff, not an immediate duplicate. (d) Unlimited brain retries — excessive latency and duplicate load during an outage.
- **Detail:** [architecture.md → Resilience](./architecture.md#resilience).
