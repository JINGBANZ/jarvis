# Fix: Responsiveness, Turn-Detection & Graceful Stop

> Root-cause analysis and fix plan for four issues found in the first live smoke run (2026-06-15),
> verified from five independent angles (code-grounding, OpenAI docs, RFC 6455 / Apple URLSession,
> voice-UX best practice, adversarial red-team). This is the *why*; the change lands on branch
> `fix/coach-responsiveness-vad-stop`.

## The four reported symptoms

From the live activity log:

1. **Addressing Jarvis directly does nothing.** "Hello Jarvis, please respond" → `staying silent`.
2. **It cuts the user off mid-sentence.** One spoken sentence arrives as several fragments.
3. **It stays silent generally.** Every trigger logged `… nothing useful to add, staying silent`.
4. **Stop logs errors.** `socket closed: code 1001` + `receive failed … POSIX 57` on every Stop.

## Root causes (verified)

| # | Root cause | Verdict |
|---|---|---|
| 1 & 3 | **Not a plumbing bug.** The pipeline works; `staying silent` (`CoachDriver.swift:107`) is the *zero-tool-call* branch — gpt-5.5 legitimately chose silence because the prompt (`ToolDefs.swift:18`) is silent-by-default with **no concept of direct address**. | Confirmed (high) |
| 2 | `RealtimeSession.sessionUpdate` sets `turn_detection` to bare `server_vad` with no params → server default `silence_duration_ms: 500` ends a turn on a ~0.5 s mid-thought pause. | Confirmed (high) |
| 4 | Stop is **graceful in substance** (no reconnect storm) but **noisy**: `stop()` calls `cancel(with: .goingAway)` (close code 1001); the `didCloseWith` and `receive` `.failure` callbacks **log before checking `stopped`**. | Confirmed (high) |

### Corrections the verification forced

- **Claim 1 is not the *sole* cause of "Jarvis ignores me."** Three other silent-failure modes exist
  and a prompt-only fix can't touch them: (a) `beginHandling()` **silently drops** back-to-back
  triggers with no log when a turn is in flight; (b) `max_output_tokens: 400` + reasoning can return
  `status: incomplete` with zero tool calls — **truncation masquerading as silence** (the decoder
  never inspects `response.status`); (c) a mid-turn `brain.respond` failure (401/quota) logs once and
  returns, looking like "ignored." → We add **observability on every quiet path first**.
- **Do _not_ switch to `semantic_vad`.** It is reported intermittently broken in *transcription-only*
  mode (`speech_started` with no `completed` → **no `onTurnEnd` at all**, worse than fragmentation).
  Primary fix is **tuned `server_vad`** (`silence_duration_ms ~1000`) plus a **client-side debounce**
  at `onTurnEnd`. Fragmentation is partly cosmetic anyway — `RollingTranscript` concatenates the
  window, so the model already sees the whole sentence; the real defect is *premature firing*.
- **Stop hides a latent bug.** `silenceTimer`/`pingTimer` are scheduled on the main runloop but
  invalidated synchronously from whatever thread calls `stop()`; `Timer.invalidate()` must run on the
  scheduling thread, so an off-main `stop()` (reachable via the `onTerminalFailure` Task) can leave a
  **stray timer firing `onSilence` on a torn-down pipeline.** Gating the logs would mask it.

## The fix plan

Built test-first, sequenced so observability lands before behavior changes.

- **B — Observability.** Log the `beginHandling` drop and `Task.isCancelled` returns; inspect
  `response.status`/`incomplete_details` and log the finish reason; make `brain.respond` failures
  distinct; counters for guardrail / model-silence / dropped.
- **A — Direct address.** New `TriggerReason.directAddress`; **hardened** wake-word ("jarvis" anchored
  / fuzzy variants, not a naive substring); bypass the cooldown/rate-cap (still honoring **mute**),
  with a separate looser direct-address ceiling; force `tool_choice:{"type":"function","name":"speak"}`
  on those turns only; prompt rewrite (must-reply-when-addressed + restrained ambient coaching).
- **C — Turn detection.** Tuned `server_vad` (`silence_duration_ms`, Config-driven) + client-side
  `onTurnEnd` debounce; log `speech_started/stopped/completed` counts.
- **D — Graceful stop.** Gate both log sites on a single locked `stopped` read; fix the timer
  thread-affinity bug; reset `reconnectAttempt`/`isReconnecting` in `connect()`; `.goingAway` →
  `.normalClosure` (1000) for wire correctness.
- **E — Proactive screen on silence (prompt-driven).** The model decides — an explicit, directive
  prompt nudge to call `capture_screen` on prolonged silence (the user's preferred design over a
  deterministic pre-capture, which the red-team showed had two holes). Ensure the overlay is excluded
  from capture; run the blocking `ScreenCaptureCLI` off the cooperative pool.
- **F — Stale-turn cancellation + config.** Cancel an in-flight (now-stale) coaching turn on fresh
  user speech instead of dropping it; move new tunables into `Config.swift`.

## Post-review hardening

A multi-angle review of the PR (5 dimensions, each finding adversarially verified) caught real bugs
in the first cut — fixed before merge:

- **Barge-in was broken.** `cancelPrevious` cancelled the in-flight turn but the replacement hit the
  single-in-flight guard and was dropped `.busy` — fresh speech got *no* reply. Fixed by a
  deterministic handoff: `TurnTaskBox` (moved to JarvisCore) makes the replacement `await` the
  cancelled predecessor so the slot is free first. Now unit-tested end-to-end.
- **Wake-word missed trailing vocatives.** "Can you check this, Jarvis?" wasn't detected (the anchor
  only scanned the first three tokens). `DirectAddress` now accepts leading *and* trailing vocatives,
  strips disfluency fillers, and still rejects discourse-marker narration ("So Jarvis told me…").
- **A forced direct-address reply could still truncate to silence** — added a spoken fallback
  (`.spokeFallback`) so a direct address is never unanswered, plus more token headroom.
- **Dead config** (`maxDirectAddressesPerMinute`) is now wired into `Guardrails`; the coalescing
  logic was extracted to a testable `UtteranceBuffer`.

## Live-test round (2026-06-15)

First live run confirmed direct-address, mid-sentence, and Stop fixes. Three follow-ups:

- **Conversation quality** — the brain had no memory of its *own* prior replies (the transcript only
  stored user speech), so it couldn't follow up (e.g. "can you check my screen?" said after a reply
  was ignored). Adopted the OpenAI **Conversations API**: one `conv_…` per coaching session
  (`CoachDriver.ensureConversation`), `store:true`, and we send only the **new** speech each turn
  (`RollingTranscript.renderSince`) — the conversation holds the rest, Jarvis's replies included.
  This reverses the no-server-retention stance (documented in [sandbox.md](./sandbox.md)) as a
  deliberate quality-first choice.
- **Screen-on-request** — added a prompt rule so "can you check my screen?" triggers `capture_screen`
  even without the wake word.
- **Error storm** — a mid-session socket drop flooded the log with hundreds of `send error` lines
  (audio kept streaming to a dead socket). Added a `connected` flag: the ping is gated and per-send
  failures are no longer logged.
- **No lost audio on a drop** — the realtime session can't be resumed (OpenAI: "if the connection
  drops, the session is lost"), and a long-lived socket *will* drop (network blips, the 60-min
  session cap, server resets). So rather than discard mic audio during the reconnect gap, it's
  buffered (`PCMBuffer`, capped at `maxBufferedAudioSeconds` = 60s, oldest evicted) and **flushed
  into the new session on reconnect** — a mid-sentence drop no longer loses the user's words. Also
  recovers the first words spoken before the very first "session ready".

## Decisions

- **Respond when addressed** is the behavior gap behind issues 1 & 3 — Jarvis was *correctly* silent
  per a prompt that never modeled direct address. Output stays **text-overlay only** for now (no TTS).
- **Wake-word + prompt**, not prompt-only: the cooldown and the silent-drop paths mean a pure prompt
  edit would still drop direct questions.
- **Tuned `server_vad` + debounce**, not `semantic_vad`: reliability over the "finished-a-thought"
  ideal, given the documented transcription-mode breakage.
- **Model decides when to look** at the screen on silence (prompt nudge), not a deterministic capture.
