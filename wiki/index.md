# Jarvis Wiki — Index

> Single source of truth for the Jarvis project. This is the navigation layer; detailed
> reference lives in the linked pages. If you are an agent joining mid-stream, **start with
> [status.md](./status.md)**.

## Start Here

- **[status.md](./status.md)** — where the project is right now, and what to do next. Read this first.

## Core Pages

- **[architecture.md](./architecture.md)** — the vision, the harness loop, components, data flow, the models/APIs rationale, resilience, safety, and design principles. The design *why*; the *what* lives in `Sources/`.
- **[build-and-run.md](./build-and-run.md)** — the operational *how*: toolchain (SwiftPM + CLT), the three-target split (Core/Overlay/App), swift-testing, packaging/signing and why TCC grants persist, running, and the activity viewer.
- **[transcription-benchmark.md](./transcription-benchmark.md)** — the explicit signed-app transcription regression harness: fixed synthetic inputs, standard and scoped-reconnect modes, deterministic scoring, privacy boundaries, result interpretation, and when to run it.
- **[sandbox.md](./sandbox.md)** — the security/isolation model (file-access restriction, entitlements, egress, server-side retention tradeoff).
- **[overlay-invisibility.md](./overlay-invisibility.md)** — how the coaching overlay stays out of screen recordings and screen shares (the `sharingType = .none` mechanism), with empirical verification on macOS 26.5 and the limits.
- **[overlay-timing.md](./overlay-timing.md)** — how long each coaching line stays on screen: a hybrid of the captioning reading-speed standard and our glance-not-watch situation (length-proportional time + a fixed notice buffer + an inter-line blank gap).
- **[landscape-survey.md](./landscape-survey.md)** — every tool and product we tried or evaluated, and how each measured up. ("What I tried.")
- **[fork-evaluation.md](./fork-evaluation.md)** — code-level evaluation of open-source apps as a fork base for the PoC, and why they're all Electron/Tauri rather than native Swift.
- **[settings-window.md](./settings-window.md)** — the unified Settings window: one menu item → `SettingsWindow` hosting `BrainSection`, `OverlaySection`, `DisplaySection`, and `ActivitySection`; the Brain tab configures the independent transcription provider/model/language or Apple locale, the ordered coaching route (OpenAI API or auto-detected local Claude Code / Codex CLI targets), shared reasoning effort, and the conditionally required OpenAI API key; the Overlay Caption and Overlay Box each have an on/off toggle + size/opacity, persisted via `OverlayAppearance`; the Screen tab picks what `capture_screen` shoots in one dropdown — the active window by default (with an on-device OCR sidecar) or an entire display.
- **[session-audit.md](./session-audit.md)** — the diagnostics-only session audit: optional execution ports, bounded persistence, Start/Stop/Quit ownership, failure containment, completeness evidence, and the evaluator boundary.

## Decisions

- **[decisions.md](./decisions.md)** — the decision log: what was chosen and why, with the rejected
  alternative. One page, no ADR folder by design; see [CLAUDE.md](./CLAUDE.md) → Convention 8.

## Meta

- **[CLAUDE.md](./CLAUDE.md)** — conventions for maintaining this wiki. Read before editing any wiki file.

## What Jarvis Is, In One Sentence

A personal, always-on macOS assistant that watches and listens during technical interviews and
proactively coaches behavioral, system-design, and coding questions with short tips in an on-screen
overlay — built as a thin harness over Apple's capture frameworks and the OpenAI APIs, reinventing
nothing.
