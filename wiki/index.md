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
- **[settings-window.md](./settings-window.md)** — the unified Settings window: one menu item → `SettingsWindow` hosting Brain, Connections, Overlay, Screen, and Activity sections; Brain configures the ordered coaching route, shared reasoning effort, and independent transcription provider/model/expected-language list or Apple locale; Connections owns the shared OpenAI credential editor and external Claude Code / Codex CLI account readiness; Overlay configures both coaching surfaces; Screen picks the active window or an entire display for `capture_screen`.
- **[lean-coaching-core.md](./lean-coaching-core.md)** — the approved issue #147 target architecture and phased roadmap: one critical coaching lane, one shared `SessionEvidence` stack with Activity and agent projections, capture heartbeat, preserved fresh-attempt routing, and the Phase 1 implementation contract.
- **[session-audit.md](./session-audit.md)** — the built Phase 0 foundation: optional audit ports, bounded persistence, Start/Stop/Quit ownership, failure containment, completeness evidence, and the evaluator boundary.

## Decisions

- **[decisions.md](./decisions.md)** — the decision log: what was chosen and why, with the rejected
  alternative. Every load-bearing decision has an entry here, newest last; this is the complete
  chronological index.
- **[adr/](./adr/README.md)** — full architecture decision records, for the few decisions whose options
  comparison doesn't fit a log entry. Each links back to its `decisions.md` entry. When a decision earns
  one, and the numbering and supersede rules: see [AGENTS.md](./AGENTS.md) → Convention 8.

## Meta

- **[AGENTS.md](./AGENTS.md)** — conventions for maintaining this wiki. Read before editing any wiki file.

## What Jarvis Is, In One Sentence

A personal, always-on macOS assistant that watches and listens during technical interviews and
proactively coaches behavioral, system-design, and coding questions with short tips in an on-screen
overlay — built as a thin harness over Apple's capture frameworks and the OpenAI APIs, reinventing
nothing.
