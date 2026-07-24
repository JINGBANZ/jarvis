# Sandbox & Security Model

> Jarvis runs on a personal machine and watches the screen and microphone. This page describes the
> **hardened** model (the target for any shippable build) and the **relaxed posture currently in
> effect** for the personal build.

## Current Posture (personal build, 2026-06-14)

Two layers below are **relaxed** for the personal build, by explicit decision:

- **No App Sandbox.** The app is **unsandboxed**, signed with a **stable self-signed identity
  (`Jarvis Dev`)** — not ad-hoc, so TCC grants persist across rebuilds (see
  [build-and-run.md](./build-and-run.md)). Screen Recording + Microphone
  are granted via **TCC prompts** at first run. Consequence: the app *could* read the user's files —
  accepted for a personal tool. (Hardened model: §1.)
- **No separate account.** The build and the app run in the **main `forrest` account**, inside a
  **git worktree** for recoverability, rather than a restricted `jarvisbuild` account. The former
  HARD REQUIREMENT is **waived** here. (Hardened model: §2.)

Everything else (owner-only file for the key, narrow egress, no rolling stream archive, owner-only
activity log, model-governed behavioral restraint) **still holds**. To re-harden for a shippable
build, re-enable §1 and §2.

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

The OpenAI API key lives in an **owner-only file** (`~/Library/Application Support/Jarvis/openai-api-key`,
mode `0600` in a `0700` directory), entered once through the menu bar. It is never committed, never
logged.

We deliberately **don't** use the macOS Keychain. macOS keys Keychain access to a per-build code
*partition* — for a self-signed app with no Apple Team ID, that partition is the binary's `cdhash`,
which changes on every build — so each rebuild is treated as a new program and re-prompts for the
login-keychain password. (TCC grants for Microphone/Screen Recording don't have this problem: they
key to the stable signing identity, not the `cdhash`.) The only ways to avoid the re-prompt are an
Apple Developer Team ID (stable `teamid:` partition) or moving off the Keychain. A `0600` file has
the same practical trust boundary as the `OPENAI_API_KEY` headless fallback — any process running as
this user can read it — but never prompts and survives every rebuild. If Jarvis ever ships under a
real Developer ID, revisit this and move the key back into the Keychain.

Upgrading from an older Keychain build: the key isn't migrated — re-paste it once (the file starts
empty), and optionally delete the now-orphaned item with `security delete-generic-password -s com.jarvis.coach`.

## Data Egress

Narrow and explicit. Data leaves the machine only via:

- **Audio → `gpt-4o-transcribe`** on the OpenAI Realtime API (continuous, for transcription).
- **Screenshot + transcript window → `gpt-5.5`** — and *only* when the model triggers a
  `capture_screen` and/or a coaching turn. No screen content leaves the machine on idle turns.
- **With a local CLI brain provider selected** ([architecture.md §4](./architecture.md#local-cli-brain-providers)),
  the same brain payload instead goes to the `claude` / `codex` subprocess, which sends it to
  Anthropic / OpenAI under the *user's own signed-in account* and that vendor's consumer retention
  terms. The subprocess runs with the CLI's own privileges (Codex is invoked `--sandbox read-only`;
  Claude with every built-in tool disabled, cwd pinned to the session dir), and **no user-configured
  MCP server is loaded** in a Jarvis turn (`--strict-mcp-config` / `-c mcp_servers={}`) — the coach
  must never see or trigger that tool surface. This trusts a CLI the user already runs on this
  machine, not widening what Jarvis itself may touch. The CLIs run with
  **session persistence off** (`--no-session-persistence` / `--ephemeral`), so they keep no local
  transcript of the coaching conversation in `~/.claude` / `~/.codex` — the owner-only session dir
  stays the only on-disk copy. Transcription audio still goes to the OpenAI Realtime API regardless.

There is **no rolling screen/audio archive and no "recall" database** — Jarvis keeps no continuous
recording of what it sees or hears. The **raw captured streams stay transient**: mic audio streams to
the API and is dropped, the live transcript lives in memory, and the temp screenshot files used to
hand a frame to `screencapture` are deleted immediately after use. The one thing persisted *on this
machine* is the **per-session log directory** — owner-only and bounded; see below.

> **Server-side retention for debuggability (current behavior).** Session memory is client-managed
> (`CoachHistory` — nothing at OpenAI is needed for continuity), but requests are still sent
> `store:true` (`OpenAIBrainClient.swift`) so each request/response remains inspectable in the OpenAI
> dashboard logs while the harness is being tuned. This **does** retain the transcript and the
> screenshots sent to the model server-side at OpenAI (≈30-day TTL), so the no-local-retention
> guarantee above does **not** extend to OpenAI's servers. A deliberate *debuggability-over-retention*
> choice; flipping to `store:false` — now a one-line change with no quality cost — is tracked as a
> future privacy item.

**The per-session log directory is the one bounded form of disk persistence, hardened to stay
owner-only.** It holds the **activity log** (the in-app `WKWebView` viewer's `jarvis-activity.jsonl` +
the screenshots the model looked at, alongside `jarvis-debug.log`) — the model's spoken tips and the
transcribed "heard:" lines so a session can be reviewed afterward — plus the **brain traffic record**
(`brain-traffic.jsonl`: the exact request/response bodies exchanged with the LLM provider, with
base64 screenshots redacted to stubs since the pixels are already the shot files) and, once the user
runs the dev-side agentic session evaluator, its `eval-report.md` and the browsable
`eval-report.html` rendered from it. The evaluator receives this complete owner-only session
directory; `jarvis-activity.jsonl` is not copied or prefiltered into another prompt artifact. All of
it is written on **every**
launch — the activity log was previously gated to a
`--dev` flag (now removed), an explicit decision to make session review a default affordance. The
hardening that made the old dev affordance safe still applies in full: the files go to a per-session
directory in the **gitignored, workspace-local `.jarvis/`** (passed to the `open`-launched app via
`--log-dir` by `build-app.sh --run`) — or, when the bundle is opened directly with no `--log-dir`, a
per-user **`~/Library/Application Support/Jarvis/sessions/`** alongside the API key — at **`0600`**
owner-only permissions inside a **`0700`** dir, **fresh each session**, and **never `/tmp`**
(world-readable, shared across user accounts). Because
it now records on every launch, growth is bounded: each Start prunes to the **10 most recent** session
dirs, and the viewer's clear-history removes all but the current. So the persisted record is small, owner-only, and
readable by this user account and by nothing else. See [build-and-run.md](./build-and-run.md).

## Behavioral Restraint (anti-annoyance = anti-misbehavior)

- **Model-governed restraint.** There is **no cooldown, rate cap, or mute** in code (the
  `Guardrails` type was removed). Every utterance reaches the brain, which decides whether it has
  anything worth saying — that restraint lives in the system prompt. This keeps conversation natural
  (a follow-up question is never stranded behind a timer). See [architecture.md §5](./architecture.md#5-safety-model).
- **Manual Start/Stop** in the menu bar — the only hard gate. Coaching never runs until started, and
  Stop tears the pipeline down entirely.
- **Visible "listening" indicator** — the user always knows when Jarvis is active (also a consent cue).
  Cost is accepted as tracking usage for now (a future improvement, not a v1 guardrail).

## Consent Note

Capturing system audio can record the other side of a call. For personal use this is fine; if this
ever becomes multi-user (it won't in v1), two-party-consent law would require a disclosure UX.
