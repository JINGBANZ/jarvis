# Sandbox & Security Model

> Jarvis runs on a personal machine and watches the screen and microphone. This page distinguishes
> the controls enforced by the current build from a future App-Sandboxed distribution target.

## Current Posture

Two layers below are **not OS-enforced** in the current build:

- **No App Sandbox.** The app is **unsandboxed**, signed with a **stable self-signed identity
  (`Jarvis Dev`)** — not ad-hoc, so TCC grants persist across rebuilds (see
  [build-and-run.md](./build-and-run.md)). Screen Recording, Microphone, and System Audio Recording
  are granted via **TCC prompts at first launch**
  ([architecture.md](./architecture.md#permissions)). Consequence: the app has the filesystem authority of the signed-in
  user even though Jarvis's own code limits its normal file access. (Future model: §1.)
- **No separate account requirement.** Development normally runs in the developer's current account
  inside a **git worktree** for recoverability. A worktree is not an OS access boundary. (Optional
  hardened development model: §2.)

Everything else (owner-only file for the key, narrow egress, no rolling stream archive, owner-only
activity log, model-governed behavioral restraint) **still holds**. The README must keep the
unsandboxed boundary visible until §1 is actually implemented and validated.

## Current enforcement boundary

TCC gates microphone, system-audio, and screen capture; owner-only permissions protect credentials
and session files; provider choice and egress are explicit in Jarvis's code. Because App Sandbox is
off, **“screen, not disk” is not a current OS guarantee**: another bug in this process could reach
files available to the signed-in user.

## Layers

### 1. App Sandbox (OS-enforced) — *hardened model; relaxed in the current build*

> **Current build:** App Sandbox is **off**; the app is signed with a stable self-signed identity
> (`Jarvis Dev`) and relies on TCC prompts. The description below is a future target, not a claim
> about the downloadable or locally built app. It requires explicit design work for CLI providers,
> session storage, and the `screencapture` helper before it can be enabled.

The app ships with the macOS App Sandbox enabled and requests **only** the entitlements it needs:

- Screen recording (for `capture_screen` / ScreenCaptureKit).
- Microphone / audio input.
- Outbound network (to reach selected remote providers; Apple manages Speech model downloads).

System-audio process-tap access is separately purpose-described in `Resources/Info.plist` and gated
by TCC; it is not a general filesystem entitlement.

It requests **no** general filesystem entitlement. It cannot read the user's documents, browser
data, or home directory. The only files it touches are its own sandbox container and transient
screenshot temp files it creates and deletes.

### 2. Restricted macOS User Account (optional development hardening)

> Development normally happens in the developer's current account inside a **git worktree**, which gives version-controlled recoverability
> but **not** an OS file-access boundary. The agent is instructed to confine all writes to the
> worktree. The description below is recommended before any long *unattended* autonomous run.

The hardened requirement: run the autonomous build agent inside a **separate, low-privilege
(Standard, non-admin) macOS user account** — never the user's primary account — so that *no file on
the user's main account is readable or writable by the build agent*. A separate account is a hard OS
boundary; the agent's reach is confined to that throwaway account's home folder, bounding the blast
radius of both the build agent and the running app.

Create one through **System Settings → Users & Groups → Add User → Standard**, then run the build
agent as that user. Any required administrator setup remains a separate, explicit operator action.

### 3. Secrets

The OpenAI API key lives in an **owner-only file** (`~/Library/Application Support/Jarvis/openai-api-key`,
mode `0600` in a `0700` directory), entered once through the menu bar. It is never committed, never
logged.

We deliberately **don't** use the macOS Keychain. macOS keys Keychain access to a per-build code
*partition* — for a self-signed app with no Apple Team ID, that partition is the binary's `cdhash`,
which changes on every build — so each rebuild is treated as a new program and re-prompts for the
login-keychain password. (TCC grants for Microphone, System Audio Recording, and Screen Recording
don't have this problem: they key to the stable signing identity, not the `cdhash`.) The only ways
to avoid the re-prompt are an
Apple Developer Team ID (stable `teamid:` partition) or moving off the Keychain. A `0600` file has
the same practical trust boundary as the `OPENAI_API_KEY` headless fallback — any process running as
this user can read it — but never prompts and survives every rebuild. If Jarvis ever ships under a
real Developer ID, revisit this and move the key back into the Keychain.

Upgrading from an older Keychain build: the key isn't migrated — re-paste it once (the file starts
empty), and optionally delete the now-orphaned item with `security delete-generic-password -s com.jarvis.coach`.

## Data Egress

Narrow and explicit. Data leaves the machine only via:

- **With the default OpenAI transcription provider, audio → the selected Realtime transcription
  model** continuously (`gpt-4o-transcribe` by default; opt-in `gpt-transcribe` or
  `gpt-live-transcribe`) together with its non-audio transcription configuration; the exact payload
  contract is defined in [architecture.md](./architecture.md#models-and-apis). With opt-in **Apple
  Speech** on macOS 26+, raw audio remains on-device and `SpeechAnalyzer` emits final text using the
  selected conversation locale. `AssetInventory` may download Apple's language model, but it does
  not upload captured audio.
- **Screenshot + transcript window → the selected brain provider/model** — and *only* when the
  model triggers a `capture_screen` and/or a coaching turn. No screen content leaves the machine on
  idle turns.
- **With Claude Code selected for coaching**
  ([architecture.md §4](./architecture.md#local-cli-brain-providers)), the same brain payload instead
  goes to the `claude` subprocess, which sends it to Anthropic under the *user's own signed-in
  account* and Anthropic's consumer retention terms. Claude runs one non-persisted stream-json query
  per coaching-attempt lease. `--safe-mode` excludes CLAUDE.md, skills, plugins, hooks, MCP, agents,
  and other customizations while preserving OAuth; an explicit empty built-in tool set, no settings
  sources, and strict explicit empty MCP config narrow the surface further. Images remain inline.
  There is no one-shot coaching fallback. Runtime failure remains inside the existing fresh-attempt
  provider-route policy, and Stop kills every ready, leased, or preparing process. This trusts a CLI
  the user already runs on this machine without widening what Jarvis itself may touch. Transcription
  audio follows the separately selected transcription provider.
- **With Codex selected for coaching**, the payload goes to one session-scoped `codex app-server`
  under the user's own ChatGPT account and OpenAI's consumer retention terms. It runs under a private
  owner-only `CODEX_HOME` whose only content is an `auth.json` symlink, so no user config, profile,
  plugin, prompt, or execpolicy `.rules` file is loadable — structurally covering what
  `--ignore-user-config` and `--ignore-rules` did. Each attempt opens a fresh thread that is required
  to come back ephemeral, pathless, and free of instruction sources, so no rollout transcript reaches
  `~/.codex`. The thread runs read-only with approvals never, empty MCP config, no project-root
  markers, and zero project-doc bytes; the advertised agentic features are disabled on both the
  launch argv and the per-thread config; and a prompt forbids built-in tool use. Codex publishes no
  control that removes built-in tools, so this envelope is layered rather than a proof of absence —
  an accepted residual risk, backed by a runtime allowlist that aborts the turn on any server request
  or item event outside agent messages and reasoning. The acceptance is measured, not assumed: on
  codex-cli 0.145.0 a captured outgoing request shows `codex exec` and the app-server offering the
  model the same four built-in tools (`exec`, `wait`, `request_user_input`, `collaboration`) whether
  the feature-disable set is applied or absent, because they arrive as an `additional_tools` input
  item rather than through the `tools` array a `features.<name>` gate controls
  (openai/codex#21952). The deny list therefore narrows nothing today; the event allowlist is the
  control that bites. Revisit when Codex publishes a real disable-all-tools control, or when that
  issue is fixed so the disable set provably reaches the tool builder. The separate
  completed-session evaluator remains intentionally agentic under the explicit Evaluate boundary
  below.
- **An explicit Activity → Evaluate click** sends the selected completed session to a read-only,
  non-persisted Claude Code / Codex agent under that CLI account. Unlike a coaching turn, this agent
  may inspect the complete `jarvis-activity.jsonl`, coaching-attempt provenance, brain traffic,
  saved screenshots, and source checkout because correlation across those inputs is the audit's
  purpose. Evaluation is unavailable without a live checkout; the app never substitutes a weaker
  API-only audit.

There is **no rolling screen/audio archive and no "recall" database** — Jarvis keeps no continuous
recording of what it sees or hears. The **raw captured streams stay transient**: audio is either
streamed to OpenAI and dropped or analyzed on-device by Apple Speech, the live transcript lives in
memory, and the transient file `screencapture` writes a frame into is created inside the owner-only
session directory (never `/tmp`) and deleted —
with its absence verified — before the capture returns. The one thing persisted *on this machine* is
the **per-session log directory** — owner-only and bounded; see below.

> **Server-side retention for debuggability (current behavior).** Session memory is client-managed
> (`CoachHistory` — nothing at OpenAI is needed for continuity), but requests are still sent
> `store:true` (`OpenAIBrainClient.swift`) so each request/response remains inspectable in the OpenAI
> dashboard logs while the harness is being tuned. This **does** retain the transcript and the
> screenshots sent to the model server-side at OpenAI (≈30-day TTL), so the no-local-retention
> guarantee above does **not** extend to OpenAI's servers. This remains a deliberate
> *debuggability-over-retention* choice. A future `store:false` change must also preserve stateless
> tool-loop reasoning continuity; it is not part of the public-launch hardening.

**The per-session log directory is the one bounded form of disk persistence, hardened to stay
owner-only.** It holds the **activity log** (the in-app `WKWebView` viewer's `jarvis-activity.jsonl` +
the screenshots the model looked at, alongside `jarvis-debug.log`) — the model's spoken tips and the
transcribed "heard:" lines so a session can be reviewed afterward — plus the **coaching-attempt
provenance** (`coaching-attempts.jsonl`: finalized transcript lines at the decision boundary,
runtime substance classification, trigger/wake, call phase, and terminal outcome) and the **brain
traffic record** (`brain-traffic.jsonl`: the exact request/response bodies exchanged with the LLM
provider, with base64 screenshots redacted to stubs since the pixels are already the shot files).
Once the user runs the agentic session evaluator from Activity or `scripts/eval-session.sh`, the
directory also holds its derived `eval-transcript.txt`, `eval-report.md`, and browsable
`eval-report.html`. The evaluator receives this complete owner-only session directory;
`jarvis-activity.jsonl` is not copied or prefiltered into another prompt artifact. Every
launch writes this record as the default session-review affordance. The files go to a per-session
directory in the **gitignored, workspace-local `.jarvis/`** (passed to the `open`-launched app via
`--log-dir` by `build-app.sh --run`) — or, when the bundle is opened directly with no `--log-dir`, a
per-user **`~/Library/Application Support/Jarvis/sessions/`** alongside the API key — at **`0600`**
owner-only permissions inside a **`0700`** dir, **fresh each session**, and **never `/tmp`**
(world-readable, shared across user accounts). Growth is bounded: each Start prunes to the **10 most recent** session
dirs, and the viewer's clear-history removes all but the current. So the persisted record is small, owner-only, and
readable by this user account and by nothing else. See [build-and-run.md](./build-and-run.md).

## Behavioral Restraint (anti-annoyance = anti-misbehavior)

- **Model-governed restraint.** There is **no cooldown, rate cap, or mute** in code. Every utterance
  reaches the brain, which decides whether it has
  anything worth saying — that restraint lives in the system prompt. This keeps conversation natural
  (a follow-up question is never stranded behind a timer). See [architecture.md §5](./architecture.md#5-safety-model).
- **Manual Start/Stop** in the menu bar — the only hard gate. Coaching never runs until started, and
  Stop tears the pipeline down entirely.
- **Visible "listening" indicator** — the user always knows when Jarvis is active (also a consent cue).
  Cost is accepted as tracking usage for now (a future improvement, not a v1 guardrail).

## Consent Note

Capturing system audio can record other people. Use Jarvis only when every authorization or consent
required by applicable law, workplace policy, platform terms, and the conversation itself has been
obtained. Jarvis does not provide legal advice or a built-in disclosure/consent workflow.
