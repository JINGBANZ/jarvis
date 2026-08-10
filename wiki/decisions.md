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
- **Superseded by:** 2026-07-18 — Technical-interview context is broad and screen-dependent.

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
- **Superseded in part by:** 2026-07-30 — Apple SpeechAnalyzer is an opt-in transcription provider.
  The OpenAI model/path and default stand; transcription is no longer API-only.
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
- **Superseded by:** 2026-07-22 — Brain settings hot-switch between coaching turns. Persistence and catalog ownership stand; next-Start-only application does not.
- **Superseded in part by:** 2026-07-27 — Catalog order defines the unset model. The first-entry
  default replaces the pinned `gpt-5.5` default; model selection and shared effort stand.
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
- **Superseded in part by:** 2026-07-25 — Coaching attempts exhaust an ordered provider route. The
  no-in-request-replay boundary returns, and pending work now schedules a new attempt even without a
  natural trigger.
- **Superseded in part by:** 2026-07-31 — Brain response deadlines are workload-owned. The
  no-in-request-replay and next-trigger recovery boundaries stand; a generic provider-owned
  generous ceiling does not.
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
- **Detail:** [settings-window.md → Capture Scope](./settings-window.md#capture-scope).
- **Superseded by:** the 2026-07-16 entry — the standalone picker and the start-time prompt are folded into the capture-scope dropdown; the `-D` index persistence and stale-index fallback stand.

### 2026-07-07 — Filler-only turn-ends skip the brain (substance gate, speaker-neutral)

- **Chose:** A client-side cost gate in `CoachDriver`: a turn-end whose transcript delta is pure back-channel filler — from *either* speaker — or empty returns `.skippedFillerOnly` without a brain request. `TurnSubstance` decides per line: "?"/"Jarvis" always substantive; else normalize (lowercase, strip punctuation, collapse repeated characters) and treat the closed-class back-channel list (en+zh) and ≤2-character fragments as filler; everything else fails open to the brain. Skipped lines ride along on the next substantive turn (the sent-index only advances on a successful send); silence checks and the manual hint always go through, and every skip is logged for auditing.
- **Why:** Roughly 40–45% of an interviewer-heavy session's turn-ends are back-channel ("Hmm", "嗯", "对") that can never produce a tip, yet each re-billed the whole working set. Normalization + a closed class scales where a raw allowlist wouldn't: back-channels are a small closed set per language and the apparent variety is elongation, which collapsing absorbs. Gating on *what* was said (not *who*) keeps interviewer questions first-class — they may draw a proactive tip for the user (prompt relaxed accordingly).
- **Rejected:** (a) A them-only speaker gate — cheaper, but it silences Jarvis exactly when the interviewer asks the user a question. (b) A longer client debounce window (adds reply latency, merges less). (c) A classifier model for filler (~$0.03/hr and latency; unwarranted while the closed class + fail-open holds).
- **Detail:** `Sources/JarvisCore/Triggers/TurnSubstance.swift`, `CoachDriver.runTurn`.
- **Superseded in part by:** 2026-08-07 — Known filler is consumed before brain context. The
  speaker-neutral, fail-open shape stands; deferred filler, the arbitrary short-fragment fallback,
  and the broad acknowledgement list do not.

### 2026-07-07 — Session memory moved client-side, with compaction

- **Chose:** Replace the per-session server-side conversation with client-managed memory (`CoachHistory`): every request is `[system] + memory + new delta`, memory grows append-only (stable prefix → prompt-cache hits), `stay_silent` turns leave no trace, only the newest screenshot stays as pixels (older → one-line stubs), and past `Config.historyCompactionTokenThreshold` the oldest span is condensed into a ≤250-word briefing by `gpt-5.4-mini`. Requests stay `store:true` purely so they remain inspectable in the OpenAI dashboard for debugging. Supersedes the conversation half of the 2026-07-03 entry (its generous-timeout and recover-next-trigger halves stand; its one-attempt half was later superseded on 2026-07-15).
- **Why:** A server conversation can only grow: every screenshot and every stored reply was re-billed as input on all ~350 turns of an hour session (~$12.60 of the observed $13). Owning the memory bounds the per-request working set (~5–6k tokens, mostly cached), keeps the problem statement in context forever via the summary, and removes a failure class outright (`conversation_locked`, dangling tool-call closes). The industry patterns adopted (compaction, observation masking, cache-ordered prefixes) and the cost model live in PR #46's design notes.
- **Rejected:** (a) Keeping conversations and rotating them with a summary seed — same summarization work, but retains the unbounded-growth window and the lock failure mode. (b) `store:false` for privacy — deferred by choice; debuggability wins while the harness is being tuned, and it's now a one-line flip.
- **Detail:** `Sources/JarvisCore/Coach/CoachHistory.swift`, `CoachDriver.compactIfNeeded`, [sandbox.md](./sandbox.md) for the retention posture.
- **Superseded (in part) by:** the 2026-07-16 entry — screenshots now never outlive their turn as pixels; the rest of this entry stands.
- **Superseded in part by:** 2026-08-07 — History compaction is language- and interview-format
  neutral. Client-owned memory and bounded summarization stand; the English-oriented size estimate
  and coding-specific briefing do not.

### 2026-07-07 — `capture_screen` is window-scoped with an on-device OCR sidecar

- **Chose:** The default capture scope shoots the **frontmost app window** via `screencapture -l` — the window server keeps one z-order across all displays, so the pick (Core's `FrontWindowSelector`; own windows, non-app layers, and tiny helper windows skipped) is the window the user last clicked or typed into, on whichever monitor. The shot gets an **on-device OCR sidecar** (Apple Vision `.accurate`, language correction off; reading order via Core's `RecognizedTextLayout`) sent in the tool-result text beside the image. An explicit **Capture Scope** setting (Settings → Screen) reverts to entire-display; the display picker keeps governing entire-display mode and every fallback (no eligible window / window capture failed), which skip OCR so a whole display's clutter is never fed back as text.
- **Why:** The full-display shot billed every Retina pixel of dock/widgets/second-browser on each screen turn, and published distractor studies show irrelevant frame content measurably degrades reasoning-model accuracy; exact text beats pixels for reading code. Together these let **low** reasoning effort find bugs that previously needed **high** (the PoC to confirm). Vision runs on-device, so the no-new-egress posture holds. This *complements* the 2026-07-06 display decision: that rejected implicit display-*following* in favor of an explicit picker; this changes capture *scope*, stays an explicit overridable setting, and leaves the picker its fallback job.
- **Rejected:** (a) Downscaling / `detail` tuning — GPT-5.5 ingests full resolution (verified against the vision docs in the PR #30 investigation), so shrink the *area*, not the fidelity. (b) Accessibility-tree text extraction — Chrome exposes web content only under assistive-tech flags and Monaco virtualizes to visible lines; OCR gets the same generically with none of the per-app fragility. (c) OCR *instead of* the image — diagrams and layout need vision, and OCR mangles the odd identifier; the image stays ground truth. (d) Column-aware OCR ordering — deferred until the PoC shows two-column interleave actually hurts.
- **Detail:** [settings-window.md → Capture Scope](./settings-window.md#capture-scope).
- **Superseded by:** the 2026-07-16 entry — active-window fallbacks now always shoot the main display; the display choice only governs entire-display scope.

### 2026-07-15 — Explicit Realtime health and one transient brain retry

- **Chose:** Treat Realtime connectivity as an explicit state machine. A transcription socket becomes ready only after the server acknowledges `session.update`; a startup deadline plus active ping/pong probes detect silent and idle failures; every failure source enters one generation-guarded reconnect path; and the menu shows starting/reconnecting/degraded states instead of claiming the pipeline is listening. Wrap each self-contained primary brain request in exactly one retry for transient network and retryable server failures, then preserve the existing next-trigger recovery.
- **Why:** Live sessions showed both startup and mid-session WebSockets being reset or losing the network, while the old app accepted the initial handshake as readiness and learned about an idle dead socket only when speech produced network I/O. A separate preflight connection would test a socket that the app immediately discards, so it cannot establish that the two real transcription sockets are healthy. Client-managed brain memory also removed the server-conversation lock that made an in-request retry unsafe: tool effects occur only after the response reaches the driver, so replaying the same request once cannot duplicate a screenshot or tip.
- **Rejected:** (a) A disposable startup connectivity test — it races the real sockets and can pass while they fail. (b) Passive WebSocket keepalive — it leaves half-open sockets invisible until the user speaks. (c) Retrying authentication, malformed requests, or rate limits — these need correction or backoff, not an immediate duplicate. (d) Unlimited brain retries — excessive latency and duplicate load during an outage.
- **Superseded in part by:** 2026-07-25 — Coaching attempts exhaust an ordered provider route.
  Realtime health stands; the immediate brain-request replay does not.
- **Detail:** [architecture.md → Resilience](./architecture.md#resilience).

### 2026-07-15 — Brain traffic is recorded per session; one-click LLM audit

- **Chose:** Every brain round trip (coach + summarizer, tagged apart) is recorded **wire-level** — the exact request body sent and response body received, plus status/latency, with base64 screenshots redacted to stubs (the pixels are already the session's `shot-N.jpg` files) — as owner-only `brain-traffic.jsonl` in the session dir (`BrainTrafficLog` — a **per-session instance** bound to its session's directory at Start, so a request still unwinding across a Stop → Start records into the session that made it, never the new one). The Activity tab's **Evaluate** button feeds a delta-aware rendering of that traffic — instructions/tools/input prefixes that are byte-identical to the previous same-tag call are elided and *marked* elided — to the selected brain model at high reasoning effort with an audit prompt focused on context engineering, then saves and shows the markdown report (`SessionEvaluator` → `eval-report.md`).
- **Why:** Tuning the harness previously meant pulling request logs from the OpenAI dashboard by hand and pasting them into a chat for diagnosis. The wire body is the ground truth a context-engineering audit needs (instructions, message order, tool schemas, `usage.cached_tokens` per call); recording it locally and auditing it in one click closes that loop. The elision markers double as signal: they show the auditor exactly where the prompt cache should be hitting, and keep the audit prompt itself from re-billing every repeated prefix.
- **Rejected:** (a) Staying on the dashboard as the source — manual, and it dies the day `store:true` is flipped off (see the 2026-07-07 memory entry's privacy item). (b) Recording at the `ChatMessage` level — provider-agnostic but a paraphrase: it can't show cache-busting prefix changes or tool-schema bloat, which are the audit's main quarry. (c) Recording the evaluator's own traffic — it would pollute the very session it audits (its client keeps `traffic: nil`).
- **Superseded in part by:** 2026-07-24 — Session evaluation is agentic-only and reads complete source logs. Wire recording and delta-aware rendering stand; the in-app one-click model call does not.
- **Detail:** `Sources/JarvisCore/Diagnostics/BrainTrafficLog.swift`,
  `Sources/JarvisCore/Diagnostics/EvaluationTranscript.swift`; current report discovery lives in
  `ActivityViewer` ([settings-window.md → Sections](./settings-window.md#sections)); retention
  posture in [sandbox.md](./sandbox.md).

### 2026-07-16 — Display choice folded into the capture-scope dropdown; no start-time prompt

- **Chose:** Settings → Screen is one dropdown: **Active window (recommended)** plus one **Entire display** entry per connected display (the row number is the persisted `screencapture -D` index). The standalone Capture Display picker and the start-time `DisplayPicker` prompt are gone, and fallbacks from active-window scope always shoot the **main display** — `ScreenCaptureCLI` applies `-D` only in entire-display scope.
- **Why:** With active-window as the default — and the window pick spanning all displays — the display only matters when the user explicitly chooses entire-display capture, so a standalone always-visible picker (and a prompt on every multi-display Start) configured something that usually had no effect. Folding the display into the scope choice makes every dropdown entry consequential, and a stale index silently steering active-window fallbacks to a long-ago-chosen monitor was a surprise, not a feature.
- **Rejected:** (a) Removing the display choice outright — entire-display scope still needs it. (b) Keeping the Start prompt for entire-display scope only — the scope entry now names its display explicitly; re-confirming an explicit setting on every Start is ceremony.
- **Supersedes:** the picker/prompt parts of the two entries marked above (2026-07-06 capture display, 2026-07-07 window-scoped capture).
- **Detail:** [settings-window.md → Capture Scope](./settings-window.md#capture-scope).

### 2026-07-16 — Screenshots never outlive their turn as pixels

- **Chose:** `CoachHistory.commit` stubs **every** screenshot to its one-line text marker as the turn commits — no image survives into later requests (previously the newest one rode along until displaced by the next capture). The model sees the pixels for the full tool loop of the turn that captured them; after that, the capture's OCR sidecar (riding in the tool-result text) is what persists, and a fresh look is one `capture_screen` call away. Two smaller fixes from the same audit landed alongside: the brain client logs per-call `input`/`cached_tokens` so the prompt-cache hit rate is visible live, and the `speak` tool description says "call stay_silent" instead of "do not call any tool" (matching `tool_choice: "required"`).
- **Why:** The first one-click session audit (2026-07-15 entry) showed the retained screenshot as the dominant per-request cost: prompts jumped from ~1.2k to ~4.9k tokens after a single capture and stayed there for every later call — billed in full whenever the prompt cache missed (3 of 4 follow-up calls in the audited session had 0 cached tokens). A stale screenshot buys little after its turn: the OCR text is what the model actually reads back, and the screen has usually changed.
- **Rejected:** (a) Keeping the newest image (status quo) — ~1.5–3.7k tokens on every subsequent request of the session for a shot that's stale the moment the turn ends. (b) Dropping the OCR text too — it's the exact code text later turns reason over, and it's cheap next to pixels. (c) The audit's suggestion to shrink `max_output_tokens` to ~64–128 — the cap is a combined reasoning+output budget (`ReasoningEffort.maxOutputTokens`); a tight cap recreates the `status:"incomplete"` truncation failure, and actual cost tracks usage, not the ceiling.
- **Detail:** `Sources/JarvisCore/Coach/CoachHistory.swift` (commit-time stubbing), `OpenAIBrainClient.swift` (cache-hit log line), `ToolDefs.swift`.

### 2026-07-16 — Reasoning items ride the tool loop

- **Chose:** Replay the brain's **entire `output` array verbatim** (reasoning and `function_call` items whole — ids and any payload untouched, in order, the canonical `input.push(...response.output)` loop) on the tool loop's follow-up request. At commit, `CoachHistory` converts the passthrough: the `function_call` survives as the proven id-less synthetic call (so the committed `function_call_output` never orphans) and the reasoning is dropped — it lives only inside the turn that produced it, like screenshots.
- **Why:** OpenAI's function-calling and reasoning guides require reasoning items to accompany a client-fulfilled tool call's output; dropping them (our old behavior, and a known ecosystem anti-pattern — the Agents SDK, Vercel AI SDK, and LangChain all round-trip them) discards the chain of thought mid-turn, so the model re-reasons over the screenshot from scratch: worse answers, more reasoning tokens, and OpenAI's own cookbook measured a 40%→80% cache-utilization gain from replaying them.
- **Rejected:** (a) `previous_response_id` server threading — reintroduces the server-side conversation the 2026-07-07 decision removed. (b) `store:false` + `include: reasoning.encrypted_content` — the fully stateless variant; deferred with the existing `store:true` debuggability choice, and it's the same replay path when flipped. (c) Keeping reasoning items across turns — OpenAI ignores stale ones, they'd bloat every later request, and a mid-session brain-model switch invalidates them. (d) A generic SDK/agent-framework dependency to manage the loop — none exists for Swift, and owning the message list is where the harness's cost machinery lives.
- **Detail:** `Sources/JarvisCore/Brain/Adapters/OpenAI/OpenAIBrainClient.swift` (verbatim extract/re-emit), `CoachDriver.swift` (whole-output threading), `CoachHistory.swift` (commit-time conversion), `Brain.swift` (`ChatMessage.rawItems`).

### 2026-07-16 — Local Claude Code / Codex CLIs as alternative brain providers

- **Chose:** A `BrainProvider` selection (Settings → Brain): the OpenAI Responses API (default), or a locally installed **Claude Code** / **Codex** CLI spawned per turn (`CLIBrainClient` behind the same `BrainClient` protocol), so the brain — coach, summarizer, evaluator — bills to the user's existing Claude / ChatGPT **subscription** instead of the metered key. CLIs are auto-detected by pure file probes (`AgentCLIDetector`: $PATH + known install dirs + on-disk auth markers; no subprocess, no Keychain prompt) so selection is one radio click. Tool use rides a prompt-embedded JSON protocol generated from the same `ToolDef`s; every turn is a single model call — screenshots reach Claude inline as base64 image blocks (stream-json input, all built-in tools disabled) and Codex as 0600 session-dir files via `-i` (`--sandbox read-only`); both CLIs run with session persistence off so no transcript copy lands in their own stores. The API-key section merged into the Brain tab — the key stays required for Realtime transcription regardless of provider.
- **Why:** For a subscription holder, per-turn API billing is the product's dominant marginal cost; the CLIs expose the same frontier models under flat-rate plans the user already pays for. The `BrainClient` seam meant the driver, client-managed memory, retry, and traffic audit all carry over unchanged; detection-by-file-probe keeps the Settings tab instant and side-effect-free.
- **Rejected:** (a) Wiring the CLIs' MCP interfaces for native tool calling — a protocol server + handshake per turn for three tools; the JSON-line protocol does the same job with a parser that tolerates prose/fences and degrades a forced `speak` to speaking the raw reply. (b) Auth verification by running the CLI at detection time — slow, may bill a request, and a Keychain prompt from `security` would be worse; the marker heuristic is a UI hint, with failures surfacing loudly at Start. (c) Replacing transcription too — the CLIs have no realtime audio surface; the OpenAI key remains the ears.
- **Superseded in part by:** 2026-07-18 — Claude sign-in uses Claude's bounded auth-status command. Binary discovery and Codex's auth marker stand.
- **Superseded in part by:** 2026-07-18 — Codex coaching invocations are isolated and bounded.
- **Superseded in part by:** 2026-07-30 — Apple SpeechAnalyzer is an opt-in transcription provider.
  The brain-provider seam stands; the OpenAI-key-always-required claim does not.
- **Detail:** [architecture.md → Local CLI brain providers](./architecture.md#local-cli-brain-providers), [settings-window.md → Brain](./settings-window.md#brain); egress note in [sandbox.md](./sandbox.md#data-egress).

### 2026-07-16 — Realtime transcript integrity is tracked per audio item

- **Chose:** Reconcile Realtime transcription by `item_id` instead of treating only
  `…transcription.completed` as meaningful. `RealtimeTranscriptionLedger` records VAD start time and
  streamed deltas, accepts out-of-order completion/failure, salvages delta text on failure or a
  missing-terminal deadline, and emits an explicit context-gap line when failed, timed-out, or
  long VAD-confirmed speech cannot be recovered from an empty completion. Transcript timestamps use
  `audio_start_ms`, so inference completion order cannot reorder speakers. Bare `speech_stopped` no
  longer resets the silence clock. Every real system-output sample is preserved for transcription;
  a short/empty callback is padded only with its missing silence so the Realtime audio clock and
  trailing-silence VAD keep advancing, while a separate exact-length padded/truncated copy feeds AEC.
  Noise-reduction policy stays at its configured setting for both streams; source-specific tuning
  requires representative live evaluation rather than assuming digital loopback is noise-free.
  VAD-only starts/stops cannot restart the silence interval: a due check waits locally for the pending
  item, while socket failure or a long active-item deadline resolves it so stale speech state cannot
  suppress coaching forever.
- **Why:** In the 2026-07-16 interview session, the user's long answer about an AI project reached the
  mic transcript but the interviewer's question never appeared in either the activity log or the
  exact brain traffic. The gap was upstream of `CoachDriver`; the old client ignored documented delta
  and failed events, silently discarded unusable completion text, and mutated the system tap to the
  mic buffer length before sending it. A sentence must either arrive or leave a visible integrity
  failure — never disappear invisibly.
- **Rejected:** (a) Logging only the failure event — observable but still deprives the coach of
  streamed text. (b) Treating every VAD stop as a turn — it supplies no language context and, in the
  old timer path, allowed noise/typing to postpone a silence check indefinitely. (c) Switching
  transcription models as a first response — it changes the commit/VAD contract without fixing the
  client's dropped event paths.
- **Detail:** `Sources/JarvisCore/Transcription/RealtimeTranscriptionLedger.swift`,
  `Sources/JarvisApp/Capture/RealtimeTranscriber.swift`, `AggregateEchoCapture.swift`.
- **Superseded in part by:** 2026-07-17 — Diagnostics never enter the brain transcript. Delta
  salvage and per-item reconciliation stand; explicit context-gap lines do not.

### 2026-07-16 — Short interviewer rejection is substantive

- **Chose:** Keep the closed-class filler gate, but classify exact interviewer-side “No”/“Nope” as
  substantive. The same user-side fragments remain filler unless other substance rules apply.
- **Why:** The interview log showed an interviewer “No.” correction skipped as filler and delivered
  only with a later turn. Speaker identity changes the meaning here: an interviewer rejection is
  actionable feedback, not a back-channel.
- **Rejected:** Removing the filler gate — would restore the large steady-state cost from acknowledgments.
- **Detail:** `Sources/JarvisCore/Triggers/TurnSubstance.swift`.
- **Superseded by:** 2026-08-07 — Clear hesitation sounds are consumed before brain context. Terse
  contextual replies now fail open for either speaker, so the interviewer-only exception is no
  longer needed.

### 2026-07-17 — Audio continuity evidence is content-free, not a recording

- **Chose:** Add a per-side continuity witness across capture, delivery, WebSocket
  attempt/completion, and Realtime server-speech boundaries. It retains sequence/sample counters,
  timestamps, socket generations, server audio-clock values, and a locally derived activity bit;
  periodic summaries and typed anomalies go only to the owner-only session log. Realtime item deltas
  remain the only recoverable words. Sustained local activity without a server speech event adds an
  explicit warning to the rolling transcript for the next real coach turn, without inventing text or
  creating its own coach request. Capture timestamps are assigned in the IOProc, while witness locking
  and PCM activity inspection run on the existing delivery queue so AEC timing is not disturbed.
  Every delivered PCM chunk enters one byte-capped transactional FIFO plus an in-memory recovery
  tail. One typed claim is sent at a time. URLSession completion moves it to that tail but cannot
  retire it: the Realtime contract explicitly provides no confirmation event for
  `input_audio_buffer.append`. Server VAD/transcription audio-clock progress advances only the prefix
  behind the earliest unresolved item, including out-of-order completions. Socket failure requeues
  the remaining tail before never-sent audio, then the replacement session transcribes interrupted
  items from PCM instead of duplicating a partial old-session finalization. Thus the ready transition,
  an asynchronous send error, and a half-open socket cannot silently strand a chunk. An overflow of
  the deliberate cap is itself a typed anomaly and an explicit context warning.
- **Why:** The prior session cannot retrospectively reveal whether the missing question disappeared
  before capture, between capture and delivery, at the socket, or inside transcription. Boundary
  evidence makes the next failure locatable while preserving the rule that raw audio is never
  archived. Live reconnect validation then exposed the remaining boundary: macOS accepted offline
  append messages locally for twelve seconds before ping detected the dead socket, so the old FIFO
  deleted the exact missing phrases and replayed only later silence. The witness isolated that stage;
  the bounded recovery tail now retains and retranscribes those words after reconnect.
- **Rejected:** (a) Persist raw PCM — it would reveal the words but reverses the project's privacy
  posture. (b) Send every stream to a second transcription provider — doubles audio egress and cost.
  (c) Hash audio chunks as proof — a content hash does not reveal what was said or which downstream
  stage failed, while increasing fingerprinting risk.
- **Detail:** `Sources/JarvisCore/Diagnostics/AudioContinuityWitness.swift`,
  `Sources/JarvisCore/Audio/AdaptiveAudioActivityDetector.swift`,
  `Sources/JarvisApp/Capture/RealtimeTranscriber.swift`.
- **Superseded in part by:** 2026-07-17 — Diagnostics never enter the brain transcript. The witness,
  recovery tail, and anomaly logs stand; transcript warning insertion does not.

### 2026-07-17 — Diagnostics never enter the brain transcript

- **Chose:** Keep the rolling transcript semantic: only usable final or salvaged transcription text
  can enter it or trigger a coach turn. Failed, timed-out, overflowed, or locally unmatched audio
  remains diagnostic-only. The continuity witness correlates bounded local activity intervals with
  overlapping server VAD intervals on the session audio clock, retaining warned metadata long enough
  for reconnect replay to resolve it; a new socket generation never unmatches prior evidence.
- **Why:** Live validation produced explicit missing-speech warnings immediately after five correctly
  transcribed utterances. A quiet dip split one locally detected phrase into multiple episodes while
  Realtime correctly reported one longer server interval; matching only the server start mislabeled
  the later episodes. Those heuristic warnings then rode into later brain requests as if they were
  speech, adding cost and misleading context without recovering a single word. Diagnostics can prove
  where continuity stopped, but they are not language and do not belong in semantic context.
- **Rejected:** (a) Increasing the grace timeout — delays real diagnostics without fixing interval
  mismatch. (b) Treating completion/failure events as blanket matches — a late event from an older
  item could hide a newer loss. (c) Sending hedged warning prose to the brain — it is still synthetic
  context and can distort coaching.
- **Detail:** [architecture.md → Resilience](./architecture.md#resilience),
  `Sources/JarvisCore/Diagnostics/AudioContinuityWitness.swift`,
  `Sources/JarvisCore/Transcription/RealtimeTranscriptionLedger.swift`,
  `Sources/JarvisApp/Capture/RealtimeTranscriber.swift`.

### 2026-07-17 — Distribution via release-please + notarized zip on GitHub Releases

- **Chose:** Releases are fully automated in `.github/workflows/release.yml`: release-please (`simple` release type) maintains a Release PR from the conventional-commit history and keeps both `Resources/Info.plist` version keys in sync via `x-release-please-version` line annotations; merging it creates a **draft** GitHub Release, and a `macos-15` job runs the test gate, then `scripts/package-app.sh` — one Developer ID signing pass with hardened runtime, timestamp, and the `audio-input` entitlement (hardened runtime otherwise denies the mic), notarization via an App Store Connect API key, staple, **re-zip after stapling** — and publishes the Release only after `Jarvis-<version>.zip` is attached. `package-app.sh` is self-contained rather than layered on `build-app.sh`, whose self-signed-identity creation can prompt for keychain access and hang a headless runner.
- **Why:** Friends install from the repo's Releases page with zero Gatekeeper friction, and version/CHANGELOG/tag/asset can't drift because no step is manual. Draft-until-attached means a failed sign/notarize run never leaves a public Release without its app.
- **Rejected:** (a) Sharing the `Jarvis Dev`-signed zip — untrusted on every other Mac; macOS 15 removed the right-click-Open bypass, leaving the buried "Open Anyway" flow. (b) A separate tag-triggered build workflow — tags created with `GITHUB_TOKEN` never trigger other workflows, so it would silently never run; the build job is gated on `release_created` in the same workflow instead. (c) Apple ID + app-specific password for notarization — the API key is the recommended CI method (no 2FA/session coupling, revocable). (d) A DMG — a zip is standard for a small menu-bar app and `notarytool` takes it directly.
- **Detail:** [build-and-run.md → Distribution](./build-and-run.md#distribution--signed-notarized-releases-from-ci); `scripts/package-app.sh`, `release-please-config.json`.

### 2026-07-17 — Agentic session audit as a dev-side workflow; single-call path kept as fallback

- **Chose:** A second, *agentic* evaluator that runs the audit through an agentic CLI (Claude Code `claude -p` / Codex `codex exec`) whose workspace is the repo checkout **plus** the session directory, so it verifies each finding against the harness's own code instead of guessing from traffic. It ships as a **dev-side script** (`scripts/eval-session.sh`) driving a thin Foundation-only executable (`EvalPrep`) that reuses Core's delta-aware transcript rendering (`SessionEvaluator.renderTranscript`) to write an owner-only `eval-transcript.txt` beside the traffic and emit the task prompt (`AgenticEvaluation`). The prompt keeps the report skeleton and call-#N citations, points the auditor at the load-bearing files (`CoachHistory.swift`, `CoachDriver.swift`, `ToolDefs.swift`, `ReasoningEffort.swift`), and requires each recommendation to be labelled `[confirmed]` (checked against the code) or `[hypothesis]`. The report is written back as `eval-report.md` — the same filename the in-app path uses. The single-call `SessionEvaluator` (the in-app **Evaluate** button) is unchanged and stays as the cheap fallback.
- **Why:** Grading the first real single-call report (2026-07-15 session) showed it was half wrong in three ways, all rooted in the auditor seeing only wire traffic, not the code: it recommended shrinking `max_output_tokens` (which is a combined reasoning+output budget), blamed 0-cached-token calls on a client bug the elision markers disproved, and proposed mechanisms (`CoachHistory` screenshot stubbing, bulky-result compaction) that already exist. An auditor that can read `CoachHistory.swift`/`CoachDriver.swift`/`ToolDefs.swift` turns those guesses into checkable claims. Keeping it dev-side sidesteps the sandbox/key-handling questions of launching a headless agent from the signed app: `.jarvis/` session dirs are already owner-only and workspace-local, and the CLI authenticates with the developer's own `claude`/`codex` login — Jarvis's owner-only key file is never touched. `EvalPrep` is a separate executable (not a `JarvisApp` subcommand) purely so the render logic is reusable from a script on any machine, keeping the "logic in Core, testable anywhere" boundary.
- **Rejected:** (a) An in-app shell-out from the Evaluate button — raises the sandbox + key-handoff questions with no payoff for a personal dev-time tool. (b) Baking the ground truth into the single-call prompt as static prose (the parked `b32c5be` revision) — the harness description drifts, and a stale sentence makes the auditor confidently wrong, the exact failure it was meant to fix; letting the agent read the live code removes the drift surface entirely. (c) Dropping the single-call path — it's one cheap round trip and the fallback when no agentic CLI is installed. (d) Feeding the agent raw `brain-traffic.jsonl` instead of the rendered transcript — the delta-aware render is the right compact input regardless of consumer, so it's reused, not reimplemented in bash.
- **Superseded by:** 2026-07-24 — Session evaluation is agentic-only and reads complete source logs.
- **Detail:** `Sources/JarvisCore/Diagnostics/AgenticEvaluation.swift`, `Sources/EvalPrep/main.swift`, `scripts/eval-session.sh`; the `[confirmed]`/`[hypothesis]` idea comes from the parked revision noted in issue #71.

### 2026-07-17 — Reports are read in the browser; markdown stays the source of truth

- **Chose:** "Open report" renders the saved `eval-report.md` to a self-contained `eval-report.html` beside it (`EvalReportPage`, a deliberate-subset markdown renderer in Core) and hands the page to the default browser; the page's **Copy as Markdown** button carries the raw report so it can be pasted into an agent chat to work on the findings. The markdown remains the only thing evaluators produce; the HTML is a derived view regenerated on every open (so an agentic re-audit that rewrites the `.md` can never leave a stale page). All report content is HTML-escaped — the report is LLM output and must not be able to inject script into a local page.
- **Rejected:** (a) The prior in-app `NSTextView` window — raw markdown as monospace text; readable but unrendered, and copy meant select-all. (b) Having evaluators emit HTML directly — agents consume markdown, and two authored formats drift. (c) A real markdown dependency (swift-markdown/cmark) — a dependency for a report page whose imperfect corners are always recoverable from the embedded raw markdown fails the no-new-dependencies bar.
- **Detail:** `Sources/JarvisCore/Diagnostics/EvalReportPage.swift`; opened by `ActivityViewer.openReport` and `scripts/eval-session.sh` (via `EvalPrep --html`).

### 2026-07-18 — Technical-interview context is broad and screen-dependent

- **Chose:** One technical-interview coach covers behavioral, system-design, and coding questions.
  When a specific answer depends on visible context missing from the conversation — including an
  unresolved reference such as “this” — the prompt uses a screen gate: `capture_screen` before
  `speak`, with one fresh screenshot/OCR satisfying that request. Each model response chooses one
  action, allowing the intended capture-then-answer tool loop without repeated captures.
- **Why:** In a live session, “How can I solve this in one pass?” triggered a generic coding answer
  because the prompt required capture only for explicit look-at-screen requests. The visible problem
  was the missing referent, and a coding-platform-specific persona also understated the intended
  interview scope.
- **Rejected:** (a) Capturing before every direct answer — fully stated behavioral, system-design,
  and coding questions do not need vision. (b) Recapturing after a fresh result. (c) A longer prompt
  that repeats tool protocol already expressed by the tool definitions. (d) A coding-platform-
  specific coaching identity.
- **Supersedes:** 2026-06-13 — One mode for v1: LeetCode Coach.
- **Detail:** [architecture.md §2](./architecture.md#2-core-loop),
  `Sources/JarvisCore/Coach/ToolDefs.swift`.

### 2026-07-18 — Claude sign-in uses Claude's bounded auth-status command

- **Chose:** Keep CLI binary discovery as file probes, but determine Claude Code authentication by
  running its non-billing `claude auth status --json` command under a short timeout. Model the result
  as signed in, signed out, or unknown; Settings shows all three, Start refuses only a confirmed
  logout, and an actual coaching failure stops the unusable session without activating the app. A
  fixed provider-only Activity notice explains that coaching stopped; the detailed error remains in
  `jarvis-debug.log`. Codex continues to use its auth-file marker.
- **Why:** Session `2026-07-18_15-25-46_366D` had an expired OAuth session, but the persistent
  `oauthAccount` metadata made Settings claim Claude was signed in. Claude's own status command reads
  its real credential store without making a model request and correctly distinguishes that stale
  marker from a working login.
- **Rejected:** (a) Trusting the account marker as signed in — it caused the false status. (b) Treating
  every failed probe as signed out — a slow or broken executable is unknown, not proof of logout.
  (c) Making a model request as preflight — it bills usage and duplicates the first real turn. (d)
  Showing a modal alert for a mid-session failure — activating Jarvis can expose it during screen
  sharing and breaks the app's ghost behavior.
- **Supersedes in part:** 2026-07-16 — Local Claude Code / Codex CLIs as alternative brain providers.
- **Detail:** [settings-window.md → Brain](./settings-window.md#brain),
  `Sources/JarvisCore/Brain/Adapters/LocalAgent/AgentCLIDetector.swift`.

### 2026-07-18 — Runtime failures preserve ghost mode

- **Chose:** Treat startup and runtime failure presentation as separate policy. An explicit Start may
  show a failure alert before a session exists; once a pipeline is live, every error path remains
  non-presenting through terminal teardown. Terminal brain, microphone-transcription, and capture
  failures stop silently; the system-audio path degrades silently. Fixed, non-sensitive notices go
  to Activity and dynamic details go only to `jarvis-debug.log`. Activity evaluation/report opening
  and history confirmation are disabled and race-guarded while coaching runs. A static gate requires
  an inline reviewed exception on every API capable of presenting, activating, opening a URL,
  requesting attention, notifying, or sounding.
- **Why:** A modal or browser appearing during screen sharing exposes the assistant precisely when a
  runtime failure makes it most likely. Severity alone also races: teardown can finish before a
  queued main-actor alert executes. Capturing startup/runtime context at the failure site makes the
  invariant independent of later session state, and the source guard prevents direct AppKit bypasses.
- **Rejected:** (a) Alerting on terminal failures — operationally clear but violates ghost mode. (b)
  Reading only current session state when the UI task executes — teardown turns a runtime failure
  into a false startup state. (c) Hiding the persistent menu-bar item or blocking user-opened
  Settings/Activity — those are named product surfaces and explicit user actions, not autonomous
  disclosure. macOS privacy indicators remain unavoidable.
- **Supersedes in part:** 2026-06-23 — Capture adapts to any input rate; startup fails loud. Startup
  still fails loud; mid-session failures do not.
- **Detail:** [architecture.md → Failure surfacing](./architecture.md#failure-surfacing--startup-loud-runtime-ghost),
  `Sources/JarvisCore/Diagnostics/UserFacingError.swift`, `scripts/check-ghost-mode.sh`.

### 2026-07-18 — Codex coaching invocations are isolated and bounded

- **Chose:** Keep `codex exec` as the subscription-backed transport, but make a coaching turn a
  direct-response decision rather than a coding-agent run: suppress project-root/document and rules
  discovery, probe the installed CLI's advertised feature names and disable its supported
  shell/code-mode/delegation/browser/app/plugin surfaces, explicitly forbid remaining built-in tools
  in the prompt, and retain read-only sandboxing as the enforcement backstop. A missing capability
  probe falls back to no guessed feature flags, so older or renamed CLIs are not rejected before the
  direct-response safeguards run. Codex gets a shorter default stall timeout than Claude, and a
  timed-out process includes its bounded stderr tail in the session diagnostic.
- **Why:** Session `2026-07-18_20-50-10_4AC2` reached the first Codex request, then produced no reply
  for 62.968 seconds; Stop was the only reason it ended, so the traffic record contained only a
  generic cancellation. The installed 0.144.5 CLI still enabled its coding-agent feature surface,
  while Jarvis incorrectly treated `--sandbox read-only` and `--ignore-user-config` as if they
  disabled tools and instruction discovery. That let a three-way coach decision enter Codex's much
  heavier agent runtime, where current GPT-5.6 Sol/macOS releases also have a reported code-mode-host
  stall/failure path.
- **Rejected:** (a) Silently falling back to the metered API or another CLI — changes the user's
  selected provider and billing path. (b) Keeping the two-minute generic timeout — later speech only
  batches behind the stuck turn. (c) Treating read-only as no-tools — it limits filesystem mutation
  but does not remove shell, delegation, browser, or other tool definitions. (d) Replacing the
  coaching transport with Codex app-server/SDK — substantially more lifecycle and protocol surface
  when this call needs one final text object.
- **Supersedes in part:** 2026-07-16 — Local Claude Code / Codex CLIs as alternative brain providers.
- **Superseded in part by:** 2026-07-30 — Live local-agent coaching shares one latency deadline.
  Provider defaults remain provider-specific; the live coach passes an explicit common deadline.
- **Detail:** [architecture.md → Local CLI brain providers](./architecture.md#local-cli-brain-providers),
  `Sources/JarvisCore/Brain/Adapters/LocalAgent/CLIBrainClient+Invocation.swift`,
  `AgentCLIProcessRunner.swift`.

### 2026-07-22 — Brain settings hot-switch between coaching turns

- **Chose:** Apply provider, model, and reasoning-effort changes between coaching turns without
  stopping the session, using a snapshotted, transactional brain configuration in `CoachDriver`.
- **Why:** A live interview is exactly when changing provider or model is useful. The old Settings
  behavior persisted the click but silently kept the start-time client for the entire run, while the
  obvious reuse of the existing restart path would discard the transcript and coaching history.
  Client-managed, provider-neutral committed history makes a between-turn switch safe; provider raw
  reasoning items exist only inside a turn's tool loop, which is why the snapshot boundary matters.
- **Rejected:** (a) Stop and Start automatically — rotates or resets live context and interrupts
  transcription. (b) Looking up preferences on every `BrainClient.respond` call — can split one
  capture/tool loop across providers and invalidate provider-specific reasoning/call linkage. (c)
  Cancelling the in-flight turn on every Settings click — drops a valid response and can churn CLI
  subprocesses while the user adjusts model and effort controls. (d) Stopping after an unconfirmed
  replacement fails — sacrifices a known-working provider and interrupts the live conversation. (e)
  Feeding the failed replacement's partial tool loop into the fallback — provider-specific reasoning
  and call identifiers cannot safely cross transports, so the clean turn input is replayed instead.
- **Supersedes in part:** 2026-06-20 — Brain model + reasoning effort are user-selectable.
- **Detail:** [settings-window.md → Brain](./settings-window.md#brain),
  `Sources/JarvisCore/Coach/CoachDriver.swift`, `Sources/JarvisApp/App/AppDelegate.swift`.

### 2026-07-23 — Settings retains its shell and lazily builds sections

- **Chose:** Retain the lightweight `NSWindow`/`NSTabView` shell between opens, build a section view
  only when its tab is selected, and release all section views when the window closes.
- **Why:** The pre-presentation path rebuilt every section, including Activity's `WKWebView`, then
  ran bounded CLI subprocess probes on the main actor, making a warm open take about 0.95 seconds.
  Moving probes off the main actor and deferring hidden sections reduced warm opens to about
  0.12–0.13 seconds.
  Releasing section views preserves Activity's established fresh-WebView lifecycle while retaining
  only the cheap window shell.
- **Rejected:** Rebuilding the whole window on every open — it repeats unrelated hidden-tab work on
  the latency-sensitive presentation path.
- **Detail:** [settings-window.md](./settings-window.md),
  `Sources/JarvisApp/Settings/SettingsWindow.swift`,
  `Sources/JarvisCore/Brain/Adapters/LocalAgent/AgentCLIDetector.swift`.

### 2026-07-24 — Temporary runtime failures preserve the live conversation

- **Chose:** Make provider recoverability one typed `BrainFailure` decision shared by provider
  adapters, immediate retry, and `CoachDriver` lifecycle handling. Unknown live-turn errors fail
  safe as temporary missed turns—including unknown/request-local HTTP 4xx responses; only a small
  explicit allowlist proving unusable authentication, billing, access, or configuration may latch
  and stop. Temporary failures preserve pending triggers, unsent transcript, capture/transcription,
  and history. Audio-route rebuilds use one incident-scoped bounded retry budget that repeated route
  notifications cannot reset, and capture callbacks are identity-guarded across Stop → Start.
  Saving an API key updates future Realtime reconnects and transactionally replaces an OpenAI brain
  without restarting capture, transcription, transcript, or history; a settings preflight failure
  likewise cannot stop the clients already running.
  Activity persists a stable event kind and is flushed before evaluation, so both session evaluators
  find failure/degrade outcomes without reverse-parsing mutable emoji/prose or racing its writer.
- **Why:** A Codex watchdog timeout was treated as a terminal CLI failure, producing “coaching
  stopped” and destroying the live UX after one stalled turn. Special-casing that exact timeout
  still left retry and lifecycle with incompatible classifiers, let any new CLI error default
  terminal, and let a momentary audio-device gap—or a late callback from an old capture—stop the
  conversation. Liveness must be the default; teardown requires positive evidence that recovery
  cannot work.
- **Rejected:** (a) Enumerating every temporary CLI stderr string or process exit code — neither is a
  stable recoverability contract. (b) Defaulting unknown errors terminal — recreates the regression
  whenever a provider adds a failure shape. (c) Retrying every temporary failure immediately — a
  watchdog miss or rate limit should wait for fresher context/backoff. (d) Filtering Activity
  outcomes only by leading marker — human copy is not a durable schema. (e) Treating every HTTP 4xx
  as permanent — request-local and future status meanings are not proof that the provider is
  unusable for later turns.
- **Supersedes in part:** 2026-07-18 — Claude sign-in uses Claude's bounded auth-status command. A
  proven preflight logout still blocks Start; an unclassified runtime CLI failure no longer stops.
- **Superseded in part by:** 2026-07-24 — Session evaluation is agentic-only and reads complete
  source logs. Stable Activity kinds and Stop-time flushing stand; preselecting evaluator outcomes
  and maintaining two evaluator paths do not.
- **Superseded in part by:** 2026-07-25 — Coaching attempts exhaust an ordered provider route. Failed
  conversation preservation and the typed failure boundary stand; immediate brain retry and
  one-failure terminal teardown do not.
- **Detail:** [architecture.md → Failure surfacing](./architecture.md#failure-surfacing--startup-loud-runtime-ghost),
  [architecture.md → Resilience](./architecture.md#resilience),
  `Sources/JarvisCore/Brain/BrainFailure.swift`,
  `Sources/JarvisCore/Support/RetryIncident.swift`,
  `Sources/JarvisCore/Support/RetrySchedule.swift`,
  `Sources/JarvisCore/Diagnostics/ActivityLog.swift`.

### 2026-07-24 — Session evaluation is agentic-only and reads complete source logs

- **Chose:** Keep one evaluator: the dev-side `scripts/eval-session.sh` workflow backed by
  `AgenticEvaluation`. Its read-only Claude Code / Codex agent receives the repo plus the complete
  session directory. `eval-transcript.txt` remains a compact delta-aware view of wire traffic, while
  the untouched `brain-traffic.jsonl`, complete `jarvis-activity.jsonl`, screenshots, and source
  checkout remain first-class inputs the agent reads whenever needed. The app only discovers and
  opens the resulting report; it never makes a separate evaluation-model call.
- **Why:** A single model call cannot inspect the live implementation and was already producing
  confident but incorrect recommendations. Preselecting only Activity stop/degrade events also
  imposes application-owned relevance judgment before the auditor sees the session, hiding speech,
  hints, actions, and ordering that may explain coaching quality or lifecycle impact. An agent with
  direct file access can inspect the complete source of truth without duplicating it into its prompt.
- **Rejected:** (a) Keeping the in-app evaluator as a cheap fallback — two evaluators produce
  different evidence and confidence levels under one report surface. (b) Copying selected Activity
  outcomes into the wire transcript — redundant and lossy when the agent already has the complete
  file. (c) Concatenating the entire Activity file into `eval-transcript.txt` — duplicates persisted
  session data and prevents the agent from choosing when it needs that evidence.
- **Supersedes:** 2026-07-17 — Agentic session audit as a dev-side workflow; single-call path kept as
  fallback. It also supersedes the in-app evaluation half of the 2026-07-15 wire-audit decision and
  the dual-evaluator/Activity-selection half of the earlier 2026-07-24 resilience decision.
- **Superseded in part by:** 2026-07-24 — Evaluate launches the sole agentic evaluator. The evidence
  model and removal of the single-call fallback stand; making users launch it outside the app does not.
- **Detail:** `Sources/JarvisCore/Diagnostics/AgenticEvaluation.swift`,
  `Sources/JarvisCore/Diagnostics/EvaluationTranscript.swift`, `Sources/EvalPrep/main.swift`,
  `scripts/eval-session.sh`, [settings-window.md](./settings-window.md#sections).

### 2026-07-24 — Evaluate launches the sole agentic evaluator

- **Chose:** Keep the established Activity state machine: a stopped session without a report shows
  **Evaluate**, one click runs the sole agentic Claude Code / Codex auditor over the source checkout
  plus the complete session, saves owner-only `eval-report.md`, and opens it; a saved session shows
  **Open report** and reopens without another run. `AgenticEvaluator` owns CLI discovery, the
  read-only/non-persisted invocation, report stamping, and failure behavior in Core.
  `scripts/eval-session.sh` reaches that same implementation through `EvalPrep`, so the UI and
  terminal are two launch surfaces for one evaluator. A selected local Brain provider is used
  directly and never silently replaced; with the OpenAI API selected, the first installed agent CLI
  in Claude-then-Codex order runs the audit.
- **Why:** Removing the inaccurate single-call evaluator was correct, but conflating “one evaluator”
  with “no in-app launcher” regressed the user experience: a fresh session exposed a disabled
  **Open report** button and required an undocumented terminal step before the app became useful.
  Evaluation quality is defined by the agent's evidence and permissions, not by whether a button or
  shell script starts it.
- **Rejected:** (a) Restoring the old single-call evaluator — it still cannot inspect source and
  recreates two reports with different evidence. (b) Keeping Activity discover-only — makes report
  creation an external manual prerequisite. (c) Having the app launch the shell script — cancellation
  and timeout would target the wrapper rather than reliably terminating the model subprocess.
  (d) Running without a source checkout — that recreates the unverified recommendations the agentic
  path exists to prevent.
- **Supersedes in part:** 2026-07-24 — Session evaluation is agentic-only and reads complete source
  logs. The evaluator stays agentic-only and continues to read the complete files; Activity now
  launches it instead of only discovering its output.
- **Detail:** `Sources/JarvisCore/Diagnostics/AgenticEvaluator.swift`,
  `Sources/JarvisCore/Diagnostics/AgenticEvaluation.swift`,
  `Sources/JarvisApp/Viewer/ActivityViewer.swift`, [settings-window.md](./settings-window.md#sections).

### 2026-07-25 — Provider fallback is explicit, transactional, and cooldown-recovered

- **Chose:** Offer one optional provider distinct from the primary in Settings. After a temporary
  primary failure exhausts its immediate retry policy, retry the same pending turn on that configured
  fallback without restarting the session. Carry client-managed history, unsent transcript, and any
  completed screen observation as provider-neutral context; never carry provider reasoning,
  tool-call ids, or call/result pairing across transports. Keep the fallback active through
  incomplete responses until it completes a non-truncated terminal turn, then serve a bounded
  recovery cooldown before probing the retained primary on a later turn. A failed probe restores the
  fallback for that same turn and resets the cooldown. A terminal fallback failure disables it for
  the live session and leaves the primary available on the next turn. Traffic metrics and evaluation
  transcripts identify the provider per call.
- **Why:** Missing one turn after retries is survivable, but it is avoidable when the user has
  explicitly authorized a second ready provider. Client-owned memory makes the conversation portable;
  provider-owned tool state does not. Keeping one provider active at a time preserves ordering and
  avoids duplicate capture or speech, while a quiet recovery probe returns to the preferred provider
  without turn-by-turn ping-pong.
- **Rejected:** (a) Selecting any installed provider silently — conversation data crosses a new
  provider boundary only by explicit user choice. (b) Calling providers concurrently or racing them —
  duplicates cost, screenshots, and spoken side effects. (c) Copying the failed provider's raw tool
  loop into the fallback — the schemas and reasoning/call linkage are transport-specific. (d)
  Switching back immediately after one fallback response — ordinary subsequent turns would ping-pong
  during an outage. (e) Restarting capture/transcription or rotating the session — failover is a
  brain-transport concern, not a new coaching conversation.
- **Detail:** [settings-window.md → Brain](./settings-window.md#brain),
  [architecture.md → Resilience](./architecture.md#resilience),
  `Sources/JarvisCore/Coach/CoachDriver.swift`,
  `Sources/JarvisCore/Coach/ConfiguredBrainRoute.swift`,
  `Sources/JarvisCore/Coach/ConfiguredBrainTarget.swift`.
- **Superseded by:** 2026-07-25 — Coaching attempts exhaust an ordered provider route.

### 2026-07-25 — Coaching attempts exhaust an ordered provider route

- **Chose:** Persist one primary provider/model target followed by an ordered list of zero or more
  fallback targets. A coaching attempt snapshots one target for its complete tool loop and never
  replays a failed provider request or switches target inside that attempt. Failure leaves the
  conversation uncommitted and schedules a new attempt independently of natural triggers; the new
  attempt batches the failed conversation with every newer finalized transcript item, or re-attempts
  the same pending work when nothing new arrived. Natural triggers and the pending wake-up coalesce,
  and an automatic wake-up waits for active speech to finish.
- **Chose:** Consecutive temporary or unknown failed coaching attempts exhaust the active target at
  the code-owned
  [`BrainRouteSession.failuresPerTarget`](../Sources/JarvisCore/Coach/BrainRouteSession.swift)
  threshold. A provider-boundary failure proven permanent exhausts that target after one attempt.
  Both transitions move the session-local cursor forward once and run the next target only in a
  separate fresh attempt. A complete, non-truncated terminal `speak` or `stay_silent` clears that
  target's failure count without returning to an earlier target. Once fallback is active, it remains
  active until it too exhausts; automatic routing never revisits the primary or another exhausted
  target. A proven-unconstructable target is skipped rather than charged synthetic attempts against
  that threshold. Exhausting the finite route stops coaching with one fixed typed Activity event; raw
  failures and scheduling detail stay in `jarvis-debug.log`.
- **Chose:** Runtime failover never mutates the saved route. Stop → Start begins at the persisted
  primary, while a valid explicit Settings edit may install a new route and reset its cursor between
  attempts. Client-managed history, unsent transcript, and the most recent completed screen
  observation are provider-neutral; older captures, raw reasoning, tool-call identifiers, and provider
  call/result linkage are not carried into a new attempt.
- **Why:** Conversation changes while a failed request is unwinding. Replaying its frozen body inside
  the same attempt is both stale and unnecessary; a new attempt can incorporate the latest speech and
  still make progress when the room stays quiet. A finite user-authored route gives outages a bounded,
  deterministic outcome without sending conversation data to an unapproved provider or making
  preferences reflect a temporary runtime incident.
- **Rejected:** (a) One immediate replay of the failed request — it uses stale input and breaks the
  attempt boundary. (b) Same-attempt failover — it mixes provider ownership inside one tool loop.
  (c) Returning to the primary after a cooldown or success probe — it causes automatic route
  backtracking and outage ping-pong. (d) One scalar fallback — it cannot express an ordered recovery
  policy. (e) Racing providers — it duplicates spend and side effects. (f) Waiting only for the next
  natural trigger — pending work could remain stuck forever in a quiet conversation.
- **Supersedes:** 2026-07-25 — Provider fallback is explicit, transactional, and
  cooldown-recovered; the brain-retry half of 2026-07-15 — Explicit Realtime health and one transient
  brain retry; and the one-failure terminal brain lifecycle in 2026-07-24 — Temporary runtime
  failures preserve the live conversation.
- **Detail:** [architecture.md → Ordered provider route](./architecture.md#ordered-provider-route),
  [settings-window.md → Brain](./settings-window.md#brain),
  `Sources/JarvisCore/Coach/CoachDriver.swift`,
  `Sources/JarvisCore/Config/BrainPreferences.swift`.

### 2026-07-26 — Live route health is scoped to target topology

- **Chose:** Reset the live route cursor and failure counts only when a Settings edit changes the
  ordered provider/model targets. A reasoning-effort edit rebuilds clients at the same topology
  without invalidating the in-flight attempt, so that attempt's success or failure still updates
  health normally. Saving the transcription API key refreshes only OpenAI target clients: an
  in-flight old-key OpenAI failure is stale, while an unaffected CLI attempt remains authoritative.
  Both same-topology paths preserve the forward-only cursor and accumulated failure counts.
- **Why:** Reasoning effort and credentials change how an existing target is invoked, not which
  target the user authorized or where runtime failover has progressed. Treating either as a fresh
  route could silently jump from a working fallback back to primary; treating an effort edit like a
  credential replacement could also erase a valid provider failure already in flight. Provider-
  scoped key refresh avoids probing or replacing unrelated CLIs.
- **Rejected:** (a) Resetting route health for every Brain Settings edit — it makes a presentation
  preference a routing command. (b) Invalidating every in-flight outcome after any client rebuild —
  effort does not make the current target or credential stale. (c) Probing all installed CLIs when
  only OpenAI credentials changed — unrelated local subprocess work cannot improve that refresh.
- **Detail:** [architecture.md → Ordered provider route](./architecture.md#ordered-provider-route),
  `Sources/JarvisCore/Coach/CoachDriver.swift`,
  `Sources/JarvisApp/App/AppDelegate.swift`,
  `Sources/JarvisCore/Brain/Adapters/LocalAgent/AgentCLIDetector.swift`.

### 2026-07-27 — Local coaching uses persistent provider runtimes without one-shot fallback

- **Chose:** Add an attempt-scoped `BrainConversation` lease while keeping committed
  `CoachHistory` client-managed. Claude Code maintains one initialized stream-json query ready for
  the active coach; leasing it starts a replacement immediately, and the leased query owns every
  turn in that coaching attempt. Codex maintains one stdio app-server for the Jarvis session; every
  attempt gets a fresh ephemeral/pathless thread, keeps it across capture follow-ups, and
  unsubscribes when the attempt ends. All Codex targets and its summarizer share that server, while
  Claude coach and summarizer runtimes remain separate because their model and system prompt are
  fixed at query startup.
- **Chose:** Remove the per-turn Claude process and `codex exec` coaching transports completely.
  Claude's long-lived stream-json query still uses the CLI's print-mode flag as required by that
  protocol; it is initialized before its lease and survives every turn in the attempt. If
  preparation, protocol conformance, a turn, timeout, or runtime process fails, that provider
  attempt fails. The existing ordered route may retry or advance only in a later fresh attempt; it
  never drops to a one-shot command before or during the attempt. Stop and route replacement
  synchronously terminate ready, leased, and preparing process trees.
- **Chose:** Isolate the Codex app-server with a private owner-only `CODEX_HOME` that links the
  existing login file but loads no user config or global instructions. Thread startup additionally
  disables project discovery and requires `ephemeral:true`, a null persistence path, and empty
  `instructionSources` before dispatch. Claude continues with no session persistence, no settings
  sources, no built-in tools, and strict empty MCP config. The completed-session agentic evaluator
  remains a deliberately separate one-shot workflow; it is not on the coaching latency path.
- **Why:** Both provider-native interfaces are built for a live client boundary, and the benefit is
  measurable where Jarvis needs continuation. In six paired Claude runs, a ready query improved
  first assistant output from 4,186.0 ms to 3,675.7 ms p50 (12.2%). In six paired two-turn Codex
  runs, the same-thread second turn completed in 1,720.4 ms versus 3,924.5 ms (56.2% faster, six of
  six wins), improving the complete semantic attempt by 26.2%. A production-path signed-in smoke
  then completed `capture_screen` → `stay_silent` on one Claude query in 3,726/1,694 ms and one
  Codex thread in 4,104/1,602 ms. The measurements do not isolate process reuse, connection reuse,
  context reuse, and provider caching, so they justify the end-to-end design rather than a narrower
  causal claim.
- **Rejected:** (a) A two-slot provider-neutral pool — Codex thread creation measured 6.6 ms p50,
  so slots waste memory; Claude needs only one ready replacement because attempts are single-flight.
  (b) A cold command when no ready lease exists — it creates two behavior/security envelopes and
  makes latency depend on a race. (c) Falling back after dispatch — it replays provider-owned work
  inside an attempt and violates the route contract. (d) Reusing one native conversation across
  attempts — it would make provider history authoritative and prevent clean provider changes.
- **Supersedes:** 2026-07-18 — Codex coaching invocations are isolated and bounded. Its
  direct-response, no-tools, read-only, timeout, and instruction-isolation requirements stand; the
  `codex exec` transport and rejection of app-server do not. It also supersedes the per-turn process
  lifecycle in 2026-07-16 — Local Claude Code / Codex CLIs as alternative brain providers.
- **Superseded in part by:** 2026-07-28 — Codex coaching fails closed without a tool-free provider
  surface. Claude's persistent runtime, attempt lease, process ownership, and lack of one-shot
  fallback stand; the Codex coaching runtime does not launch.
- **Detail:** [architecture.md → Local CLI brain providers](./architecture.md#local-cli-brain-providers),
  [sandbox.md → Data Egress](./sandbox.md#data-egress),
  `Sources/JarvisCore/Brain/Adapters/LocalAgent/ClaudeCode/ClaudeCodeRuntime.swift`,
  `Sources/JarvisCore/Brain/Adapters/LocalAgent/Codex/CodexAppServerRuntime.swift`,
  `Sources/JarvisCore/Brain/Adapters/LocalAgent/CLIBrainClient.swift`.

### 2026-07-27 — Catalog order defines the unset model

- **Chose:** Use the first entry in each provider's `BrainModelCatalog` list whenever no valid model
  preference exists. Keep no separate global or provider-specific pinned default. Invalid remembered
  primary ids use that first entry; invalid fallback rows are ignored during route normalization.
- **Why:** The picker is already curated in preferred order. Making that order authoritative removes
  a second default policy that could drift from what Settings presents.
- **Rejected:** Hard-coded defaults independent of list order, and a compatibility mapping from
  retired ids to different current models.
- **Supersedes in part:** 2026-06-20 — Brain model + reasoning effort are user-selectable. Catalog
  ownership and shared effort stand; the pinned default does not.
- **Detail:** [settings-window.md → Brain](./settings-window.md#brain),
  `Sources/JarvisCore/Brain/BrainModelCatalog.swift`.

### 2026-07-27 — Persist concrete model releases, not rolling aliases

- **Chose:** Show and persist concrete model ids for every provider. Refresh
  `BrainModelCatalog` manually from official provider documentation when a new public release should
  replace or extend the curated lists. Invalid remembered ids use the first provider entry; invalid
  fallback rows are ignored. Invitation-only models remain excluded.
- **Why:** A saved route should continue naming the release the user selected. A rolling alias can
  silently retarget that route when its provider advances the alias, changing behavior without a
  Settings edit.
- **Rejected:** Rolling aliases such as `sonnet`, `opus`, and provider-managed CLI defaults as
  persisted picker selections. The Codex summarizer may still omit its model override because that is
  internal compaction behavior, not a saved route selection.
- **Detail:** [settings-window.md → Brain](./settings-window.md#brain),
  `Sources/JarvisCore/Brain/BrainModelCatalog.swift`.

### 2026-07-28 — Keep the persistent local-agent process edge in Core

- **Chose:** Keep Jarvis's small `AgentRuntimeProcess` and `AgentRuntimeLifetime` boundary under the
  local-agent adapter instead of adding Swift Subprocess 0.5. Keep Claude Code and Codex lifecycle
  code in separate provider sub-adapters; `LocalAgentRuntimeSet` owns their one composition
  difference. Process-group membership is recorded only while a known PID/start-time identity proves
  the original group is still alive. The exit monitor observes the exact leader with
  `waitid(..., WNOWAIT)`, snapshots descendant PID/start-time identities before reaping it, and
  teardown revalidates and signals those individual identities rather than the reusable numeric
  group.
- **Why:** Jarvis needs a long-lived newline channel used across separate calls, synchronous
  termination from final-owner release and actor teardown, bounded unread output, and escalation
  that identity-checks descendants even when the leader exits immediately. Observing before reaping
  preserves group provenance long enough to capture those helpers without ever signaling a recycled
  PID. Swift Subprocess's execution handle cannot escape its async run closure, and its stable
  teardown stops when that leader is gone. Wrapping it would leave the safety-critical lifetime code
  in place while adding a pre-1.0 dependency.
- **Rejected:** (a) Swift Subprocess 0.5 plus a command/channel bridge — more code and dependency
  surface without the required teardown semantics. (b) Moving the provider runtimes to
  `JarvisApp` — their state machines are Foundation-only and belong in testable Core. (c) Merging
  Codex credential-home management into the generic client — it is a focused provider security
  policy, not shared Brain configuration.
- **Detail:** [architecture.md → Local CLI brain providers](./architecture.md#local-cli-brain-providers),
  `Sources/JarvisCore/Brain/Adapters/LocalAgent/Runtime/AgentRuntimeProcess.swift`,
  `Sources/JarvisCore/Brain/Adapters/LocalAgent/Runtime/AgentRuntimeLifetime.swift`,
  `Sources/JarvisCore/Brain/Adapters/LocalAgent/LocalAgentRuntimeSet.swift`.

### 2026-07-28 — Screen-capture cancellation owns helper and file cleanup

- **Chose:** Give `ScreenCapturing` an explicit cancellation boundary. `ScreenCaptureRunner` owns
  the active `screencapture` process and its transient JPEG under the owner-only live session
  directory. Stop requests TERM, escalates after a bounded grace period only while the helper's
  PID/start-time identity still matches, and waits for the process to exit and the JPEG's absence to
  be verified before releasing the coaching attempt. Success and ordinary failure use the same
  verified cleanup boundary; a deletion failure poisons the session-local runner so a window/display
  fallback or later capture cannot create another file.
- **Why:** Abandoning a detached synchronous capture released the provider lease quickly but left a
  stuck helper and screen-derived file alive after the session was considered stopped. A temporary
  path also violated the rule that screen-derived disk data stays inside the retained session
  boundary.
- **Rejected:** (a) Finishing the async bridge immediately and ignoring the helper — teardown would
  still be incomplete. (b) Writing to `/tmp` and relying on `defer` after an unbounded wait — a
  wedged helper postpones deletion indefinitely. (c) Best-effort deletion without checking the
  resulting path — it can report completion while screen-derived data remains.
- **Detail:** [architecture.md → Core Loop](./architecture.md#2-core-loop),
  `Sources/JarvisCore/Screen/ScreenCaptureRunner.swift`,
  `Sources/JarvisCore/Coach/CoachDriver.swift`.

### 2026-07-28 — Codex coaching fails closed without a tool-free provider surface

- **Chose:** Treat tool-free coaching as an explicit provider capability independent of Codex's
  advertised feature catalog. App preflight rejects a Codex primary and marks a Codex fallback
  unavailable; direct `CodexAppServerRuntime` use returns a typed permanent failure before creating
  `CODEX_HOME` or spawning a process. Keep the existing ephemeral-thread, private-home, read-only,
  empty-MCP, feature-disable, and event-rejection checks behind a future explicit tool-free launch
  capability as defense in depth, not as evidence that launch is safe.
- **Chose:** Launch Claude's persistent stream-json query with `--safe-mode` as well as an explicit
  empty built-in tool set, no settings sources, no session persistence, and strict explicit empty
  MCP config. Safe mode excludes inherited CLAUDE.md, skills, plugins, hooks, MCP, agents, and other
  customizations without replacing the user's OAuth authentication path.
- **Why:** Codex app-server 0.145 has no stable empty-tools field. A deny list derived from a local
  feature probe can be empty, fail, or drift while built-in planner, shell, delegation, browser, or
  future tool families remain callable. Read-only sandboxing limits mutations but does not remove
  those tools, and rejecting a tool event happens after the unsafe surface was already offered.
  Claude exposes a provider-supported customization-isolation mode, so its coaching boundary can be
  established before launch while preserving subscription authentication.
- **Rejected:** (a) Treating known feature disables as a complete tool inventory — unknown and
  renamed surfaces fail open. (b) Relying on read-only sandboxing, prompt instructions, or
  post-event rejection — none removes built-in tools before inference. (c) Quietly substituting the
  metered Responses API — it changes the selected provider and billing path. (d) Removing Codex from
  saved routes or the evaluator — preferences should remain repairable, and completed-session
  evaluation is explicitly agentic.
- **Supersedes in part:** 2026-07-27 — Local coaching uses persistent provider runtimes without
  one-shot fallback, and 2026-07-18 — Codex coaching invocations are isolated and bounded. Their
  isolation requirements remain defenses in depth; Codex coaching is unavailable until the provider
  exposes a stable tool-free launch surface.
- **Detail:** [architecture.md → Local CLI brain providers](./architecture.md#local-cli-brain-providers),
  [sandbox.md → Data Egress](./sandbox.md#data-egress),
  `Sources/JarvisCore/Brain/Adapters/LocalAgent/DetectedAgentCLI.swift`,
  `Sources/JarvisCore/Brain/Adapters/LocalAgent/ClaudeCode/ClaudeCodeRuntime.swift`,
  `Sources/JarvisCore/Brain/Adapters/LocalAgent/Codex/CodexAppServerRuntime.swift`.
- **Superseded by:** 2026-07-29 — Codex coaching runs at parity with the `codex exec` risk posture.

### 2026-07-29 — Codex coaching runs at parity with the `codex exec` risk posture

- **Chose:** Enable Codex coaching on the persistent app-server runtime, accepting the same residual
  risk `codex exec` coaching already shipped with. There is no coaching-capability gate: preflight,
  route availability, and runtime construction treat Codex like any other detected, signed-in CLI.
- **Chose:** Deliver the agentic-feature disable set through the per-thread `thread/start` config
  (`features.<name> = false`) as well as the launch `--disable` flags, while treating neither as
  load-bearing. Measured on codex-cli 0.145.0 by capturing the outgoing Responses request, both
  transports offer the model the same four built-in tools — `exec`, `wait`, `request_user_input`,
  `collaboration` — with the disable set applied and with it absent. They arrive as an
  `additional_tools` input item rather than the request's `tools` array, which is why a
  `features.<name>` gate does not remove them (openai/codex#21952, open). The deny list therefore
  narrows nothing today on either path; the runtime item-event allowlist is the control that bites.
- **Why:** This is an owner risk acceptance, not a refutation of the analysis above. The absence
  proof the previous entry demanded was never available on `main` either — the shipped `codex exec`
  path conceded that Codex has no disable-all-tools flag and relied on the same layered envelope.
  Holding the app-server path to a stricter bar than the transport it replaces blocked a real
  latency win for no change in exposure. Verified against codex-cli 0.145.0: `codex app-server
  --help` and the generated `ThreadStartParams` schema still expose no field that removes built-in
  tools, so no such control was invented, and a captured-request comparison confirms `codex exec`
  and the app-server offer the model an identical built-in tool set. Parity is therefore measured,
  not assumed — and the shared residual surface includes a JavaScript `exec` tool, which is the
  exposure `main` already carries. Every control `codex exec` enforced is present, and three
  are strengthened — the ephemeral thread's `ephemeral`/`path`/`instructionSources` are verified in
  the `thread/start` response rather than assumed, `--ignore-user-config`/`--ignore-rules` become
  structural (a private `CODEX_HOME` holding only an `auth.json` symlink, so no config, profile,
  plugin, prompt, or `.rules` file exists to load), and any server request or item event outside the
  message/reasoning allowlist aborts the turn, which catches built-in families the deny list never
  named.
- **Rejected:** (a) Shipping the runtime dormant — ~730 lines of untested-in-production code and a
  latency claim for a disabled path. (b) Inventing a launch flag to satisfy the old gate — the flag
  does not exist. (c) Weakening any isolation control to simplify the app-server path.
- **Changes this decision:** Codex publishing a real disable-all-tools control (adopt it and drop
  the layered reliance); openai/codex#21952 being fixed such that the disable set provably reaches
  the tool builder on either transport (re-measure, then drop the duplicate config delivery); or
  evidence that a built-in tool executes before the item-event allowlist can abort the turn.
- **Supersedes:** 2026-07-28 — Codex coaching fails closed without a tool-free provider surface. Its
  Claude `--safe-mode` decision stands unchanged; its Codex capability gate does not.
- **Detail:** [architecture.md → Local CLI brain providers](./architecture.md#local-cli-brain-providers),
  [sandbox.md → Data Egress](./sandbox.md#data-egress),
  `Sources/JarvisCore/Brain/Adapters/LocalAgent/Codex/CodexAppServerRuntime.swift`,
  `Sources/JarvisCore/Brain/Adapters/LocalAgent/Codex/CodexRuntimeHome.swift`.

### 2026-07-30 — Apple SpeechAnalyzer is an opt-in transcription provider

- **Chose:** Separate transcription selection from the brain route through a provider-neutral
  `TranscriptionSession` port. OpenAI Realtime remains the default. On macOS 26 or later, Settings
  offers opt-in Apple Speech backed by `SpeechAnalyzer`/`SpeechTranscriber`; one Start snapshots one
  provider for both `me` and `them`, and a live session never switches providers automatically.
- **Chose:** Keep the Apple first slice fixed to English (US), prepare or download its
  `AssetInventory` model before replacing a running pipeline, convert the existing ordered 24 kHz
  PCM into the framework's preferred format, and admit final transcription results only. A
  content-free adaptive PCM tracker postpones coaching while speech is active but never gates
  analyzer input or retains audio. The OpenAI key is required only when OpenAI supplies
  transcription or appears in the configured brain route.
- **Why:** Apple Speech removes continuous audio egress and transcription API billing for users who
  explicitly choose the on-device path, while the existing OpenAI default preserves installed
  behavior and its proven reconnect/integrity machinery. A session-scoped choice keeps privacy,
  billing, and failure behavior legible: an Apple failure cannot silently turn into an OpenAI upload.
- **Rejected:** (a) Automatic Apple → OpenAI fallback — it crosses an explicit privacy/billing
  boundary and may require a credential the selected path did not need. (b) Mixing providers between
  `me` and `them`, or switching one during a live session — it makes readiness, failure, and
  transcript timing provider-dependent inside one conversation. (c) A locale picker or language
  auto-detection in the first slice — it multiplies model/readiness/accuracy validation before the
  English path has a live A/B. (d) `SFSpeechRecognizer` for older macOS releases — it would add a
  second Apple adapter with a different authorization, availability, and result lifecycle instead
  of the chosen SpeechAnalyzer boundary. (e) Adding `SpeechDetector` as a transcription gate —
  Apple documents an accuracy tradeoff when it drops audio, and its current results sequence does
  not expose usable speech boundaries; local activity therefore affects scheduling only.
- **Supersedes in part:** 2026-06 — Models verified, and 2026-07-16 — Local Claude Code / Codex CLIs
  as alternative brain providers. The OpenAI transcription implementation remains the default; the
  API-only and always-needs-an-OpenAI-key constraints do not.
- **Detail:** [architecture.md → Models and APIs](./architecture.md#models-and-apis),
  [settings-window.md → Brain](./settings-window.md#brain),
  [sandbox.md → Data Egress](./sandbox.md#data-egress).
- **Superseded in part by:** 2026-07-30 — Transcription language is a Start-time profile and GPT
  Live is opt-in. Apple remains one analyzer per speaker and one locale per session; the fixed
  English locale and no-locale-picker choices do not.

### 2026-07-30 — Transcription language is a Start-time profile and GPT Live is opt-in

- **Chose:** Keep OpenAI as the default transcription provider and GPT-4o Transcribe as its default
  model, with GPT Live Transcribe as an explicit session-by-session A/B choice. Language expectations
  default to Automatic, so Jarvis sends no hidden English hint. The optional English, Mandarin, and
  English + Mandarin profiles are one immutable Start snapshot shared by both speakers and every
  reconnect. GPT Live receives both mixed-language expectations; GPT-4o leaves the mixed profile
  automatic because it accepts only one language hint.
- **Chose:** Populate the Apple Speech locale picker from the framework's runtime-supported locales,
  initially suggesting the supported equivalent of the current macOS locale. Keep one Apple locale
  for the complete session and do not run parallel locale transcribers.
- **Why:** Either interview participant may switch between English and Mandarin inside one sentence.
  A per-turn language choice is both too late and conceptually wrong for code-switching; the
  transcription model must recognize the mixed audio itself. An explicit session profile gives the
  model useful prior information when its wire contract supports it without hard-coding English or
  adding a local language classifier. The opt-in model picker makes GPT Live accuracy, finalization
  latency, and stability directly comparable against the existing GPT-4o path.
- **Rejected:** (a) Hard-coding English for either OpenAI or Apple. (b) Choosing a language for every
  utterance in Jarvis—the same utterance may contain both. (c) Parallel Apple transcribers—more
  lifecycle, asset, and reconciliation complexity before evidence that it is needed. (d) Racing
  OpenAI models or sending the same live audio to both—duplicates egress and cost; A/B sessions keep
  the comparison explicit.
- **Supersedes in part:** 2026-07-30 — Apple SpeechAnalyzer is an opt-in transcription provider. Its
  provider/session boundary stands; its fixed-English first slice does not.
- **Detail:** [architecture.md → Models and APIs](./architecture.md#models-and-apis),
  [settings-window.md → Brain](./settings-window.md#brain),
  [sandbox.md → Data Egress](./sandbox.md#data-egress).

### 2026-07-30 — Live local-agent coaching shares one latency deadline

- **Chose:** Give the live Claude Code and Codex coaching clients one explicit latency deadline.
  Keep local-agent provider defaults unchanged for summarization and every other caller. The
  completed-session evaluator, failure classification, fresh-attempt scheduling, observation
  carryover, and ordered-route budgets are unchanged.
- **Why:** In session `2026-07-30_16-41-44_687E`, five Codex turns completed in 3.1–6.6 seconds,
  while one stalled turn reached the prior live ceiling and pushed the recovered useful answer to
  about 45 seconds after the request. The existing fresh-attempt boundary recovered correctly; the
  latency-sensitive overlay should stop waiting sooner without changing that recovery policy.
- **Rejected:** (a) Lowering `CLIBrainClient` provider defaults globally — that would also change
  summarization and other auxiliary clients. (b) Giving the two live local providers different
  deadlines — they serve the same overlay latency contract. (c) Changing API, evaluator, routing,
  retry, or failure semantics — the session evidence did not justify those broader changes.
- **Superseded in part by:** 2026-07-31 — Brain response deadlines are workload-owned. The common
  live deadline stands; generic provider-specific defaults do not.
- **Detail:** `Sources/JarvisApp/App/AppDelegate.swift`,
  `Sources/JarvisCore/Brain/Adapters/LocalAgent/CLIBrainClient.swift`.

### 2026-07-31 — Brain response deadlines are workload-owned

- **Chose:** Define live-coaching and history-compaction deadlines as Core workload policy, shared
  by OpenAI, Claude Code, and Codex instead of keeping transport-specific defaults. Generic clients
  default to the live workload; `AppDelegate` still passes each role explicitly. A one-shot local
  auxiliary request calculates one absolute deadline before provider setup and gives inference only
  the remaining budget. Compaction stays awaited, tool-less, low-effort, and tagged `summarizer`; an
  empty result, timeout, or other failure keeps the full history and never enters provider-route
  health.
- **Chose:** Recover an in-flight Codex turn timeout at thread scope: send `turn/interrupt`, consume
  its response and the matching terminal turn event, then let normal conversation finish retire the
  thread. Keep the shared app-server for later coaching. Invalidate it only when the turn cannot be
  identified or scoped interruption/terminal cleanup cannot be confirmed, because its shared stream
  is then uncertain.
- **Why:** Provider transport does not determine how long newer speech may wait; the foreground or
  auxiliary workload does. Compaction runs before the active handling slot is released, so separate
  setup and inference ceilings could double that delay. A failed summary is lossless, while
  restarting a healthy session-scoped Codex transport adds latency to the next coaching attempt.
- **Rejected:** (a) Provider-specific defaults — they encode workload policy at the wrong boundary.
  (b) A separate Codex summarizer app-server — duplicates a healthy session transport and its
  startup cost. (c) Unsubscribing a timed-out thread without first interrupting and draining its
  terminal event — that leaves the shared event stream unsynchronized. (d) Detached compaction —
  history ordering and snapshot races need a separate design.
- **Supersedes in part:** 2026-07-03 — Brain call: generous ceiling, one attempt, recover on next
  trigger; 2026-07-18 — Codex coaching invocations are isolated and bounded; and 2026-07-30 — Live
  local-agent coaching shares one latency deadline. Their recovery, isolation, and common
  live-latency decisions stand; provider-owned timeout defaults do not.
- **Detail:** `Sources/JarvisCore/Brain/BrainWorkloadTimeout.swift`,
  `Sources/JarvisCore/Brain/Adapters/LocalAgent/CLIBrainClient.swift`,
  `Sources/JarvisCore/Brain/Adapters/LocalAgent/Codex/CodexAppServerRuntime.swift`,
  `Sources/JarvisApp/App/AppDelegate.swift`.

### 2026-08-01 — GPT Live uses local WebRTC VAD and explicit commits

- **Chose:** Keep GPT-4o Transcribe on its existing tuned `server_vad` path. For opt-in GPT Live
  Transcribe, disable unsupported server turn detection and run one classic WebRTC VAD instance per
  post-AEC 48 kHz speaker stream. A Foundation-only endpoint policy confirms speech and waits through
  the configured trailing silence. The socket commits only after its ordered append FIFO reaches
  that sequence boundary; `input_audio_buffer.committed` binds the local timing to the provider's
  `item_id`, and unresolved committed turns retain both PCM and boundary metadata across reconnect.
- **Why:** GPT Live rejects a transcription session configured with server turn detection, while its
  documented transcription workflow requires the client to commit each audio turn. Reusing the VAD
  already present in Jarvis's statically linked WebRTC archive adds no dependency or model download,
  keeps raw audio streaming continuously for recognition, and preserves the existing per-item and
  reconnect integrity guarantees.
- **Rejected:** (a) The existing RMS activity tracker as the commit authority—it is a diagnostics and
  coaching-timing heuristic, not a speech detector. (b) OpenAI server VAD for GPT Live—the model
  rejects that configuration. (c) A new neural VAD dependency—the bundled WebRTC detector is already
  native, lightweight, and sufficient for the first A/B. (d) Parallel transcription or provider
  fallback—both duplicate egress/cost or cross the user's explicit provider boundary.
- **Detail:** [architecture.md → Models and APIs](./architecture.md#models-and-apis),
  `Sources/JarvisCore/Audio/SpeechEndpointDetector.swift`,
  `Sources/JarvisCore/Transcription/RealtimeJarvisManagedTurnCoordinator.swift`,
  `Sources/JarvisApp/Capture/RealtimeTranscriber.swift`.

### 2026-08-06 — GPT Transcribe uses server VAD while GPT Live keeps local endpoints

- **Chose:** Add GPT Transcribe as an opt-in OpenAI model without changing GPT-4o Transcribe as the
  default. GPT Transcribe uses the same tuned server-VAD boundary as GPT-4o; GPT Live retains its
  local WebRTC VAD and acknowledged explicit commits. GPT Transcribe and GPT Live receive fixed,
  speaker-role-aware recording context and plural expected-language hints, while GPT Live also
  requests low transcription delay. GPT Transcribe completion-language metadata goes only to debug
  diagnostics. Vocabulary keywords remain unset.
- **Why:** The current GPT Transcribe Realtime contract accepts server VAD and produces the same
  speech-start, speech-stop, committed-item, and completed-item sequence Jarvis already reconciles.
  That keeps endpoint ownership on the server for models that support it and preserves local VAD
  only where the selected model requires client commits. Fixed context and expected languages apply
  the provider's accuracy guidance without adding changing screen/transcript content to the session
  configuration or persisting new audio-derived data.
- **Rejected:** (a) Requiring local VAD for GPT Transcribe despite its supported server boundary—this
  adds endpoint and reconnect machinery without a provider constraint. (b) Removing GPT Live—the
  opt-in path remains useful for low-latency comparison and has a working client-commit contract.
  (c) Enabling server VAD for GPT Live—the live API rejects that model/configuration combination.
  (d) Dynamic OCR, prior-turn, or transcript-derived prompts—the role context is sufficient for this
  step and avoids another changing data path. (e) Vocabulary keywords—the user explicitly deferred
  them. (f) Changing the default before a same-input three-model comparison.
- **Detail:** [architecture.md → Models and APIs](./architecture.md#models-and-apis),
  [settings-window.md → Brain](./settings-window.md#brain),
  `Sources/JarvisCore/Transcription/RealtimeSession.swift`,
  `Sources/JarvisCore/Transcription/OpenAITranscriptionModel.swift`,
  `Sources/JarvisApp/Capture/RealtimeTranscriber.swift`.
- **Superseded by:** 2026-08-06 — GPT Transcribe requires explicit committed turns.

### 2026-08-06 — GPT Transcribe requires explicit committed turns

- **Chose:** Keep GPT-4o Transcribe on tuned server VAD. Run GPT Transcribe and GPT Live through the
  existing local WebRTC VAD, ordered append, explicit commit, acknowledgement, and `item_id`
  lifecycle path. GPT Transcribe retains its fixed recording context, plural expected-language
  hints, and diagnostic completion-language handling; vocabulary keywords remain unset.
- **Why:** OpenAI documents GPT Transcribe's Realtime mode as a committed-turn workflow with
  `turn_detection: null`, where transcription begins after `input_audio_buffer.commit`. A
  configuration-only live probe accepted `server_vad`, but real session
  `2026-08-06_20-07-57_977B` captured and delivered both streams without a completed transcript
  because Jarvis never sent a commit. Schema acceptance therefore did not prove working endpoint
  behavior. Reusing the already-built client-commit path is the smallest contract-correct fix.
- **Rejected:** (a) Keeping GPT Transcribe on accepted-but-nonfunctional server VAD. (b) Adding a
  second endpoint mechanism when the GPT Live path already provides ordered, reconnect-safe commits.
  (c) Removing GPT Live or changing the GPT-4o default. (d) Enabling vocabulary hints before the
  user requests them.
- **Supersedes:** 2026-08-06 — GPT Transcribe uses server VAD while GPT Live keeps local endpoints.
- **Detail:** [architecture.md → Models and APIs](./architecture.md#models-and-apis),
  `Sources/JarvisCore/Transcription/OpenAITranscriptionModel.swift`,
  `Sources/JarvisCore/Transcription/RealtimeSession.swift`,
  `Sources/JarvisApp/Capture/RealtimeTranscriber.swift`.

### 2026-08-06 — Audio-frame arrival gates coaching readiness

- **Chose:** Make readiness prove capture, not just provider sessions. The app owns endpoint
  connection mechanics and feeds ready/not-ready observations into a Foundation-only
  `CaptureReadinessMonitor`, which combines those observations with independent mic and system frame
  health. Full listening requires both ready providers and a positive sample-count callback from both
  capture paths. Amplitude never enters the decision, so valid digital silence still counts. A required
  stream that delivers no samples within a deadline, or that stalls for a sustained window after frame
  flow begins, becomes a terminal microphone failure or a microphone-only system degrade. The monitor
  reuses `AudioContinuityWitness` stall evidence surfaced through `RealtimeContinuityReporter`; the app
  supplies observations, the polling cadence in `AppDelegate.startCaptureReadiness()`, route-rebuild
  recovery state, connection-attempt presentation, and lifecycle effects.
- **Why:** Ready provider sockets proved sessions were up while both streams sat at capture=0/0 during a
  quiet-start failure; the witness already saw the stall but only logged it. Promoting frame arrival into
  readiness, and giving a sustained stall a typed consequence, closes that gap without weakening ghost
  mode, privacy, the attempt boundary, or the quiet-start-without-playback posture from PR #124. Keeping
  the policy Foundation-only makes the timeouts and degrade/terminal decisions deterministically testable.
- **Rejected:** (a) Inferring capture health from speech energy/amplitude — silence would read as failure.
  (b) A second capture counter in the app — duplicates and can disagree with the witness. (c) Reusing the
  `AudioContinuityWitness.Configuration.captureStallThreshold` directly as the lifecycle consequence —
  too aggressive; `AggregateEchoCapture` explicitly suspends that consequence while its bounded route
  recovery owns the incident, then `CaptureReadinessMonitor.Configuration.sustainedStallTimeout` governs
  a fresh post-recovery window. (d) Restoring
  `kAudioAggregateDeviceTapAutoStartKey` to guarantee frames — reintroduces the system-playback dependency.
- **Detail:** `Sources/JarvisCore/Diagnostics/CaptureReadinessMonitor.swift`,
  `Sources/JarvisCore/Diagnostics/AudioContinuityWitness.swift`,
  `Sources/JarvisApp/Capture/AggregateEchoCapture.swift`,
  `Sources/JarvisApp/Capture/RealtimeContinuityReporter.swift`,
  `Sources/JarvisApp/App/AppDelegate.swift`.

### 2026-08-07 — Clear hesitation sounds are consumed before brain context

- **Chose:** Keep a speaker-neutral, conservative substance gate for clear non-semantic vocal sounds,
  recognize separated sequences of those sounds, and remove them from every brain-facing transcript
  delta. A turn with nothing else consumes its transcript boundary without a request, while Activity
  retains the complete finalized transcription. Context-dependent short replies such as “Yes,” “No,”
  “Okay,” “对,” and “可以” fail open for either speaker, as do unknown short fragments.
- **Why:** Session `2026-08-07_11-15-48_B24D` showed that isolated hesitation sounds were already
  skipped, but combined sounds could escape the exact-phrase check and buy a full-history
  `stay_silent` request. Previously skipped noise also entered the next substantive request, turning
  a saved call into recurring context cost. A narrow discard set saves those calls without silently
  deleting short answers whose meaning depends on the conversation.
- **Rejected:** (a) Asking the transcription model to delete filler — it is not a deterministic
  omission boundary and would silently change the audit record. (b) Treating contextual replies or
  every unknown short fragment as filler — either can carry an answer, correction, or technical term.
  (c) A classifier model — extra latency and cost for a small explicit class. (d) Sending filler or an
  artificial placeholder after a failed attempt — when no substantive text or saved observation
  remains, there is no useful context for a fresh request.
- **Supersedes in part:** 2026-07-07 — Filler-only turn-ends skip the brain. Its speaker-neutral gate
  stands, but the broad acknowledgement list and explicit speaker overrides do not; skipped sounds
  no longer ride forward, and unknown short fragments no longer disappear by length alone.
- **Detail:** [architecture.md → The turn](./architecture.md#the-turn),
  `Sources/JarvisCore/Triggers/TurnSubstance.swift`,
  `Sources/JarvisCore/Coach/CoachDriver.swift`.

### 2026-08-07 — History compaction is language- and interview-format neutral

- **Chose:** Estimate non-ASCII session memory conservatively instead of applying the English
  characters-per-token shortcut to every script. Summarize older history as a general live-coaching
  briefing: preserve durable goals, requirements, progress, decisions, prior advice, feedback, and
  unresolved questions; compress resolved topics and omit obsolete detail. Do not assume a coding
  interview or add an explicit phase state machine.
- **Why:** The Chinese-heavy audited session reached a large recurring request while the old estimate
  still remained below the compaction threshold. Its older project and behavioral discussion would
  also have been forced into a hard-coded coding-problem summary even if compaction had run.
- **Rejected:** (a) Lowering the threshold globally — it does not fix the language bias and compacts
  English sessions too early. (b) A hard-coded interview-phase detector — the general summarizer can
  retire resolved topics first, without adding another brittle state machine. (c) Separate summary
  schemas per interview type — they duplicate policy and can misclassify mixed sessions.
- **Supersedes in part:** 2026-07-07 — Session memory moved client-side, with compaction. Client-owned
  memory, the bounded briefing, and fail-soft behavior stand; the English-biased estimate and
  coding-only summary do not.
- **Detail:** [architecture.md → Models and APIs](./architecture.md#models-and-apis),
  `Sources/JarvisCore/Coach/CoachHistory.swift`,
  `Sources/JarvisCore/Prompts/JarvisPrompts+HistorySummary.swift`.

### 2026-08-08 — Overall readiness is a composition of focused subsystem state

- **Chose:** Add one Foundation-only `JarvisReadiness` reducer that consumes typed snapshots of the
  selected session's permissions, credentials, brain and transcription preparation, endpoint
  connections, capture health, and capture recovery. It emits one typed checking, blocked,
  recovering, fully ready, microphone-only ready, or stopped status plus effects for the app to
  render. Each Start owns an opaque generation, so stale, cancelled, and post-Stop observations
  cannot make a replacement session ready. Existing focused components, including
  `CaptureReadinessMonitor`, continue to own their mechanics.
- **Why:** Readiness had become a second state machine in `AppDelegate` and a separate presentation
  model in the menu, leaving startup dependencies outside capture health and making Activity unable
  to report the same live answer. One pure composition gives every surface the same authoritative
  state without moving timers, provider objects, logging, permissions, or OS behavior into Core.
- **Rejected:** (a) Expanding `CaptureReadinessMonitor` into a session god object — permission,
  credential, and provider preparation are not capture policy. (b) Keeping independent menu and
  Activity checks — they can drift and accept stale callbacks differently. (c) Persisting readiness
  transitions as Activity rows — readiness is current UI state, while Activity remains the durable
  coaching and lifecycle record.
- **Detail:** [architecture.md → Components](./architecture.md#3-components),
  `Sources/JarvisCore/Diagnostics/JarvisReadiness.swift`,
  `Sources/JarvisCore/Diagnostics/CaptureReadinessMonitor.swift`,
  `Sources/JarvisApp/App/AppDelegate.swift`.

### 2026-08-08 — Session evaluation uses persisted coaching-attempt provenance

- **Chose:** Persist one owner-only coaching-attempt companion beside Activity and brain traffic.
  It records the natural trigger versus a pending-work wake, the indexed finalized delta and the
  substance gate's decision, the initial-versus-screen-continuation boundary, and the terminal
  outcome. Every coach wire call carries the matching attempt identity. The evaluator joins those
  records to compute trigger/filler/call-phase counts; absent historical provenance and absent
  provider telemetry remain unavailable rather than zero.
- **Chose:** Keep Activity human-facing and keep raw wire traffic untouched. The derived evaluation
  transcript safely elides the exact shared prefix inside a growing one-item CLI request and removes
  exact reply duplicates from runtime envelopes, with explicit source pointers and stable call
  numbering. Reports separate transcript input, Jarvis output, Activity consequence, and trigger;
  they never use total `stay_silent` actions as an avoidable-call estimate. Recommendations are
  limited to three and distinguish session evidence, source verification, hypotheses, and behavior
  to preserve. Without retained audio, ASR error claims remain hypotheses.
- **Why:** Session `2026-08-07_11-15-48_B24D` proved that traffic plus prose could not recover which
  finalized lines actually caused a call: the evaluator missed local filler skips, over-attributed
  model silence, blurred request speech with generated output, and expanded a growing CLI history
  into a multi-megabyte derived input. Capturing provenance at the attempt boundary makes causal
  accounting deterministic without turning Activity into an engineering log or weakening the
  session's owner-only retention boundary.
- **Rejected:** (a) Inferring triggers from Activity/debug prose—the missing local skips and
  pending-work wakes are not reconstructible. (b) Treating every accumulated filler line as causal,
  or every `stay_silent` as avoidable. (c) Copying diagnostics into Activity—it mixes human history
  with scheduler detail. (d) Rewriting or discarding raw traffic—the complete source remains the
  cardinality and wire-contract authority. (e) Archiving audio to validate ASR—it reverses the
  privacy posture for an evaluator convenience.
- **Extends:** 2026-07-15 — Brain traffic is recorded per session; one-click LLM audit, and
  2026-07-24 — Session evaluation is agentic-only and reads complete source logs.
- **Detail:** [architecture.md → Resilience](./architecture.md#resilience),
  [sandbox.md → Data Egress](./sandbox.md#data-egress),
  `Sources/JarvisCore/Diagnostics/CoachingAttemptLog.swift`,
  `Sources/JarvisCore/Diagnostics/TriggerQualityMetrics.swift`,
  `Sources/JarvisCore/Diagnostics/EvaluationTranscript.swift`.

### 2026-08-09 — Session audit persistence stays off the coaching latency path

- **Chose:** Make coaching-attempt and brain-traffic recording enqueue-only while a session is live.
  Their session-bound serial queues perform request/response parsing, image redaction, JSON
  serialization, and file I/O in order. Stop captures the old session's recorders, waits for cancelled
  coaching work to unwind, and flushes every evidence queue before making that session evaluable.
- **Chose:** Persist actual transcript inclusion separately from its filler classification, label CLI
  failures before actual transport dispatch as pre-request failures rather than provider calls, and surface
  malformed JSONL as unavailable evidence with stable record-number gaps and partial totals.
- **Why:** Synchronous audit writes can sit between a provider response and Jarvis handling or showing
  the coaching result. Moving them behind ordered queues removes that disk/serialization latency while
  the Stop-time durability barrier retains a complete audit. Independent inclusion and explicit
  unavailable records keep the evaluator capable of detecting the very gate/logging failures it audits.
- **Rejected:** (a) Synchronous per-record durability on the coaching path—it makes local filesystem
  behavior part of response latency. (b) A timing-threshold unit test—wall-clock assertions are flaky
  and cannot prove the absence of blocking I/O; the queue boundary and teardown flush are structural.
  (c) Dropping damaged or pre-request records—they would turn missing evidence into exact-looking call
  and telemetry totals.
- **Extends:** 2026-08-08 — Session evaluation uses persisted coaching-attempt provenance.
- **Superseded by:** 2026-08-10 — Session audit persistence is bounded and failure-contained. The
  off-latency-path goal and evaluator classifications stand; per-session queues, complete Stop-time
  draining, and exact-by-default new-format evidence do not.
- **Detail:** [architecture.md → Latency](./architecture.md#latency),
  `Sources/JarvisCore/Diagnostics/BrainTrafficLog.swift`,
  `Sources/JarvisCore/Diagnostics/CoachingAttemptLog.swift`,
  `Sources/JarvisCore/Diagnostics/JSONLRecords.swift`,
  `Sources/JarvisApp/App/AppDelegate.swift`.

### 2026-08-10 — Session audit persistence is bounded and failure-contained

- **Chose:** Give `CoachDriver` and brain clients only the narrow `CoachingAttemptAuditing` and
  `BrainTrafficAuditing` observer ports. They submit typed `Sendable` events, with attempt attribution
  carried through a neutral task local. `FileSessionAudit` admits provider/coach events through a
  nonblocking try-lock into one process-level ring bounded by event count and retained bytes. Callers
  outside a persisted live session omit the optional observer instead of constructing a second no-op
  implementation. Only the worker parses request/response JSON, redacts images, serializes records,
  and performs file I/O.
- **Chose:** Treat persisted audit evidence as best-effort and self-describing. Overload and oversize
  records are dropped; open, write, or serialization failure disables further persistence for that
  session. A versioned `audit-health.json` records completeness and queue-overflow, oversize, open,
  write, close-timeout, late-event, and serialization-failure counts when possible. The evaluator
  renders surviving new-format counts as lower bounds or unavailable when health is partial, while
  retaining the historical interpretation for legacy sessions without a marker.
- **Chose:** Keep lifecycle ownership in the app. One Start creates one `FileSessionAudit`; Stop
  captures and clears it, requests turn cancellation, then closes the old handle asynchronously after
  those tasks unwind. Close has a short deadline, and a replacement Start never waits for an older
  session's parked writer.
- **Why:** Moving work to a per-session serial queue removed JSON and disk work from most callbacks but
  did not bound retained payloads, make admission structurally nonblocking, contain a failed writer, or
  let Stop distinguish complete evidence from a timeout. Coaching latency and restart availability
  must not depend on audit persistence, while an evaluator must not present dropped evidence as an
  exact total.
- **Rejected:** (a) Synchronous or backpressured audit durability—diagnostics cannot delay provider
  response handling or overlay delivery. (b) One unbounded queue per session—it moves rather than
  bounds the failure. (c) Retrying or blocking when the mailbox is full—this couples coaching to a
  diagnostic outage. (d) Silently omitting damaged evidence—the health marker makes uncertainty part
  of the audit contract. (e) Wall-clock latency assertions—deterministic parked/failing writers prove
  isolation without scheduler-dependent thresholds.
- **Supersedes:** 2026-08-09 — Session audit persistence stays off the coaching latency path.
- **Extends:** 2026-08-08 — Session evaluation uses persisted coaching-attempt provenance.
- **Detail:** [architecture.md → Latency](./architecture.md#latency),
  `Sources/JarvisCore/Diagnostics/BrainTrafficAuditing.swift`,
  `Sources/JarvisCore/Diagnostics/CoachingAttemptAuditing.swift`,
  `Sources/JarvisCore/Diagnostics/FileSessionAudit.swift`,
  `Sources/JarvisCore/Diagnostics/SessionAuditWorker.swift`,
  `Sources/JarvisCore/Diagnostics/SessionAuditEvidence.swift`,
  `Sources/JarvisApp/App/AppDelegate.swift`.
