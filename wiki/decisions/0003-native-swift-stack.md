# 0003 — Native Swift Menu-Bar App

**Status:** Accepted

## Context

We need screen capture, both-sides system audio, an always-on-top overlay, and a tight permission/
sandbox story. Candidate stacks: native Swift; Tauri (Rust + web overlay, borrowing Natively's
capture); Python orchestrator + thin Swift helpers.

## Decision

**A single native Swift/SwiftUI menu-bar app.**

- **Capture:** ScreenCaptureKit (screen + system audio), AVFoundation (mic), the built-in
  `screencapture` tool, Apple Vision (OCR if needed).
- **Overlay:** AppKit NSPanel.
- **Brain/transcription:** plain HTTPS to the OpenAI APIs.

## Rationale

- It is the most direct use of the exact Apple frameworks our "reinvent nothing" rule points to.
- Cleanest permission + App Sandbox story — central to the security requirement (see
  [sandbox.md](../sandbox.md)).
- Smallest footprint; one language, one codebase, least to go wrong for an autonomous build.

## Consequences

- Build + verify must happen on macOS (true of any option that touches these APIs anyway) — see
  [0004](./0004-build-on-mac-not-vps.md).
- Swift is slightly less battle-tested for fully-autonomous agent builds than Python/TS; mitigated
  by keeping the harness thin and the logic unit-testable.
- Fallback if a web-tech overlay is ever wanted: Tauri borrowing Natively's Rust capture.
