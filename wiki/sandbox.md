# Sandbox & Security Model

> Jarvis runs on a personal machine and watches the screen and microphone. This page describes the
> **hardened** model (the target for any shippable build) and the **relaxed posture currently in
> effect** for the personal build.

## Current Posture (personal build, 2026-06-14)

Two layers below are **relaxed** for the personal build, by explicit decision:

- **No App Sandbox.** The app is **unsandboxed**, signed with a **stable self-signed identity
  (`Jarvis Dev`)** — not ad-hoc, so TCC grants persist across rebuilds (see
  [specification.md §9](./specification.md#9-build--run-constraints)). Screen Recording + Microphone
  are granted via **TCC prompts** at first run. Consequence: the app *could* read the user's files —
  accepted for a personal tool. (Hardened model: §1.)
- **No separate account.** The build and the app run in the **main `forrest` account**, inside a
  **git worktree** for recoverability, rather than a restricted `jarvisbuild` account. The former
  HARD REQUIREMENT is **waived** here. (Hardened model: §2.)

Everything else (Keychain for the key, narrow egress, no recording to disk, behavioral guardrails)
**still holds**. To re-harden for a shippable build, re-enable §1 and §2.

## Principle

**Jarvis can see the screen, not the disk.** Anything it can reach is something the OS explicitly
granted; everything else is denied by default.

## Layers

### 1. App Sandbox (OS-enforced) — *hardened model; relaxed in the current build*

> **Current build:** App Sandbox is **off**; the app is signed with a stable self-signed identity
> (`Jarvis Dev`) and relies on TCC prompts. The description below is the target for a shippable version.

The app ships with the macOS App Sandbox enabled and requests **only** the entitlements it needs:

- Screen recording (for `capture_screen` / ScreenCaptureKit).
- Microphone / audio input.
- Outbound network (to reach the OpenAI APIs).

It requests **no** general filesystem entitlement. It cannot read the user's documents, browser
data, or home directory. The only files it touches are its own sandbox container and transient
screenshot temp files it creates and deletes.

### 2. Restricted macOS User Account (development & run) — *was HARD; waived in the current build*

> **Current build (2026-06-14): waived.** Building and running happen in the main `forrest` account
> inside a **git worktree** (`.claude/worktrees/…`), which gives version-controlled recoverability
> but **not** an OS file-access boundary. The agent is instructed to confine all writes to the
> worktree. The description below is the hardened model, recommended before any long *unattended*
> autonomous run or a shippable build.

The hardened requirement: run the autonomous build agent inside a **separate, low-privilege
(Standard, non-admin) macOS user account** — never the user's primary account — so that *no file on
the user's main account is readable or writable by the build agent*. A separate account is a hard OS
boundary; the agent's reach is confined to that throwaway account's home folder, bounding the blast
radius of both the build agent and the running app.

A Standard account `dev` already exists on this Mac and could serve, or add a fresh one:
**System Settings → Users & Groups → add a Standard user (e.g. `jarvisbuild`) →** log in via Fast
User Switching → run Claude Code there (the session runs *as* that user — true isolation). Note the
build still needs one-time **admin** setup from `forrest` (TCC grants, any tool installs), since a
Standard account cannot grant itself Screen Recording.

### 3. Secrets

The OpenAI API key lives in the **macOS Keychain**, entered once through the menu bar. It is never
written to disk in plaintext, never committed, never logged.

## Data Egress

Narrow and explicit. Data leaves the machine only via:

- **Audio → `gpt-4o-transcribe`** on the OpenAI Realtime API (continuous, for transcription).
- **Screenshot + transcript window → `gpt-5.5`** — and *only* when the model triggers a
  `capture_screen` and/or a coaching turn. No screen content leaves the machine on idle turns.

In the MVP there is **no recording to disk** — no rolling screen/audio archive, no "recall"
database. Temp screenshots are deleted after use. This guarantee covers the **sensitive captured
streams** (mic audio, screenshots, and the transcript derived from them): audio streams to the API
and is dropped, the transcript lives in memory, and nothing is persisted *on this machine* in normal
operation.

> **Temporary exception (2026-06-15) — server-side retention for conversation quality.** To give the
> coach real multi-turn memory, the brain now uses the OpenAI **Conversations API** (`store:true`,
> one `conv_…` per coaching session). This **does** retain the transcript and the screenshots sent to
> the model server-side at OpenAI (≈30-day TTL). This is a deliberate *quality-over-retention* choice
> made for now; revisiting it (encrypted reasoning items / ephemeral conversations / client-side
> history) is tracked as a future privacy item. See
> [fix-responsiveness-vad-stop.md](./fix-responsiveness-vad-stop.md).

**Dev-mode logging is the one bounded exception, and it is hardened to not break the guarantee.**
File logging (the activity HTML + `jarvis-debug.log`, which include the model's spoken tips and the
transcribed "heard:" lines) is written **only when the `--dev` flag is set** — normal launches log
solely to the unified log, never a flat file. When on, the files go to the `--log-dir` (a
**gitignored `.jarvis/` in the workspace**, or a per-user `Caches/Jarvis`) with **`0600`** owner-only
permissions, **truncated fresh each session** — never `/tmp` (which is world-readable and shared
across user accounts). So even the dev affordance produces no world-readable or persistent record.
See [specification.md §9](./specification.md#9-build--run-constraints).

## Behavioral Restraint (anti-annoyance = anti-misbehavior)

- **Model-governed restraint.** There is **no cooldown, rate cap, or mute** in code (the
  `Guardrails` type was removed). Every utterance reaches the brain, which decides whether it has
  anything worth saying — that restraint lives in the system prompt. This keeps conversation natural
  (a follow-up question is never stranded behind a timer). See [architecture.md §5](./architecture.md#5-safety-model).
- **Manual Start/Stop** in the menu bar — the only hard gate. Coaching never runs until started, and
  Stop tears the pipeline down entirely.
- **Visible "listening" indicator** — the user always knows when Jarvis is active (also a consent cue).
- **Session interjection counter** in the menu bar (reset on each Start), so over-talking is visible
  immediately. Cost is accepted as tracking usage for now (a future improvement, not a v1 guardrail).

## Consent Note

Capturing system audio can record the other side of a call. For personal use this is fine; if this
ever becomes multi-user (it won't in v1), two-party-consent law would require a disclosure UX.
