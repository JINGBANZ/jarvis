# Jarvis Wiki — Index

> Single source of truth for the Jarvis project. This is the navigation layer; detailed
> reference lives in the linked pages. If you are an agent joining mid-stream, **start with
> [status.md](./status.md)**.

## Start Here

- **[status.md](./status.md)** — where the project is right now, and what to do next. Read this first.

## Core Pages

- **[architecture.md](./architecture.md)** — the vision, the harness loop, components, data flow, safety, and design principles.
- **[specification.md](./specification.md)** — the buildable spec: tool schemas, the coach prompt, config, pseudocode, latency budget, and the self-verification plan. This is the page another agent should be able to one-shot from.
- **[sandbox.md](./sandbox.md)** — the security/isolation model (file-access restriction, entitlements, egress).
- **[landscape-survey.md](./landscape-survey.md)** — every tool and product we tried or evaluated, and how each measured up. ("What I tried.")
- **[fork-evaluation.md](./fork-evaluation.md)** — code-level evaluation of open-source apps as a fork base for the PoC, and why they're all Electron/Tauri rather than native Swift.

## Decision Log

Architecture Decision Records live in **[decisions/](./decisions/README.md)**:

- [0001 — Build our own vs. use an existing tool](./decisions/0001-build-vs-buy.md) ("Why I'm building my own.")
- [0002 — Personal tool first, not a product](./decisions/0002-personal-tool-first.md)
- [0003 — Native Swift menu-bar app](./decisions/0003-native-swift-stack.md)
- [0004 — Build on the Mac, not the VPS](./decisions/0004-build-on-mac-not-vps.md)
- [0005 — Model-triggered screen capture (tool-use loop)](./decisions/0005-model-triggered-screen-capture.md)
- [0006 — Single LeetCode-coach mode (no tiers)](./decisions/0006-single-coach-mode.md)

## Meta

- **[CLAUDE.md](./CLAUDE.md)** — how to maintain this wiki.

## What Jarvis Is, In One Sentence

A personal, always-on macOS assistant that watches and listens while you solve a LeetCode
problem and proactively coaches you with short tips in an on-screen overlay — built as a thin
harness over Apple's capture frameworks and the OpenAI APIs, reinventing nothing.
