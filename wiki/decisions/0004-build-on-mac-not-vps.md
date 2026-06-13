# 0004 — Build on the Mac, Not the VPS

**Status:** Accepted

## Context

The user asked whether development could happen on an Ubuntu VPS (preferred for convenience),
given that Jarvis ultimately runs on a MacBook. The design work and code authoring for this project
do happen in a Claude Code session on the VPS.

## Decision

**Code authoring and design can happen on the VPS; the build + verify loop must run on the Mac.**

You cannot, on Linux:
- compile against ScreenCaptureKit / AVFoundation / AppKit,
- trigger or test the macOS permission prompts (TCC),
- capture system audio or the screen,
- render or test the NSPanel overlay.

Since a hard development goal is that **the agent self-verifies with smoke tests**, and those tests
require the macOS runtime, the autonomous build session must run on the MacBook.

## Decision detail

Run the autonomous Claude Code build **on the Mac, inside a separate restricted macOS user
account**. This also satisfies the file-access security requirement better than the VPS would (see
[sandbox.md](../sandbox.md)).

## Consequences

- The VPS is for planning, research, and writing this wiki/spec.
- The repo is synced to the Mac for the build.
- Verification is real (runs against actual macOS APIs), not simulated.
