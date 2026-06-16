# Jarvis Wiki — Index

> Single source of truth for the Jarvis project. This is the navigation layer; detailed
> reference lives in the linked pages. If you are an agent joining mid-stream, **start with
> [status.md](./status.md)**.

## Start Here

- **[status.md](./status.md)** — where the project is right now, and what to do next. Read this first.
- **[plan-phase2-build.md](./plan-phase2-build.md)** — the step-by-step implementation plan driving the current native-Swift build.
- **[plan-activity-viewer.md](./plan-activity-viewer.md)** — TDD implementation plan for the in-app `WKWebView` activity viewer + session history (design: [activity-viewer.md](./activity-viewer.md)).

## Core Pages

- **[architecture.md](./architecture.md)** — the vision, the harness loop, components, data flow, safety, and design principles.
- **[specification.md](./specification.md)** — the buildable spec: tool schemas, the coach prompt, config, pseudocode, latency budget, and the self-verification plan. This is the page another agent should be able to one-shot from.
- **[sandbox.md](./sandbox.md)** — the security/isolation model (file-access restriction, entitlements, egress).
- **[landscape-survey.md](./landscape-survey.md)** — every tool and product we tried or evaluated, and how each measured up. ("What I tried.")
- **[fork-evaluation.md](./fork-evaluation.md)** — code-level evaluation of open-source apps as a fork base for the PoC, and why they're all Electron/Tauri rather than native Swift.
- **[fix-responsiveness-vad-stop.md](./fix-responsiveness-vad-stop.md)** — root-cause analysis (verified from five angles) and fix plan for the first live smoke run's issues: direct-address responsiveness, mid-sentence turn-detection, and noisy Stop.
- **[activity-viewer.md](./activity-viewer.md)** — design for the dev-mode activity viewer: an in-app `WKWebView` live log window with a screenshot lightbox and browsable session history (replaces the `file://` + meta-refresh HTML viewer).

## Key Decisions

There is no formal ADR folder — decisions are recorded as a compact log in
**[status.md](./status.md#key-decisions)**, with the *rationale* living in the design pages it links to.

## Meta

- **[CLAUDE.md](./CLAUDE.md)** — how to maintain this wiki.

## What Jarvis Is, In One Sentence

A personal, always-on macOS assistant that watches and listens while you solve a LeetCode
problem and proactively coaches you with short tips in an on-screen overlay — built as a thin
harness over Apple's capture frameworks and the OpenAI APIs, reinventing nothing.
