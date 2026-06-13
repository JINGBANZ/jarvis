# 0005 — Model-Triggered Screen Capture (Tool-Use Loop)

**Status:** Accepted · supersedes the earlier "snapshot-on-every-trigger" idea

## Context

An early design captured a screenshot on every coaching trigger and always sent it to the model.
That is wasteful: most of the time the model can coach from the transcript alone, and vision tokens
are the expensive part. It also makes the harness "smarter" than it should be — guessing when the
screen matters.

## Decision

**Expose screen capture as a tool the model calls on demand.** The harness runs a tool-use loop:
the always-on input is the audio transcript; `capture_screen` is a tool GPT-5.5 invokes only when
it judges it needs to see the screen. The harness fulfills the call (a silent screenshot) and
returns the image into the conversation.

Likewise, speaking is a tool (`speak`) the model calls only when it has something useful; calling
no tool means stay silent.

## Rationale

- **Cheaper:** vision tokens are spent only when the model opts in.
- **Smarter:** the model — not a hard-coded heuristic — decides when the screen is relevant.
- **Simpler harness:** the loop is just "wire events to tool calls"; all judgment lives in the model.

## Consequences

- The harness is a standard function-calling loop with an image-returning tool. See the pseudocode
  in [specification.md](../specification.md#2-the-harness-loop-pseudocode).
- The harness must support tool results that contain images.
- `capture_screen` must exclude Jarvis's own overlay window from the screenshot.
