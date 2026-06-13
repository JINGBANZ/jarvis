# Sandbox & Security Model

> Jarvis runs on a personal machine and watches the screen and microphone. Its access must be
> tightly bounded, and bounded by **enforcement**, not convention.

## Principle

**Jarvis can see the screen, not the disk.** Anything it can reach is something the OS explicitly
granted; everything else is denied by default.

## Layers

### 1. App Sandbox (OS-enforced)

The app ships with the macOS App Sandbox enabled and requests **only** the entitlements it needs:

- Screen recording (for `capture_screen` / ScreenCaptureKit).
- Microphone / audio input.
- Outbound network (to reach the OpenAI APIs).

It requests **no** general filesystem entitlement. It cannot read the user's documents, browser
data, or home directory. The only files it touches are its own sandbox container and transient
screenshot temp files it creates and deletes.

### 2. Restricted macOS User Account (development & run)

The app is **built and run inside a separate, low-privilege macOS user account**. This bounds the
blast radius of both the build agent and the running app: even a bug or a bad instruction can't
reach the primary account's files. This is also the answer to "can development happen on the VPS?"
— no; it happens on the Mac, in this restricted account (see
[decision 0004](./decisions/0004-build-on-mac-not-vps.md)).

### 3. Secrets

The OpenAI API key lives in the **macOS Keychain**, entered once through the menu bar. It is never
written to disk in plaintext, never committed, never logged.

## Data Egress

Narrow and explicit. Data leaves the machine only via:

- **Audio → OpenAI Realtime API** (continuous, for transcription).
- **Screenshot + transcript window → GPT-5.5** — and *only* when the model triggers a
  `capture_screen` and/or a coaching turn. No screen content leaves the machine on idle turns.

In the MVP there is **no recording to disk** — no rolling screen/audio archive, no "recall"
database. Temp screenshots are deleted after use.

## Behavioral Guardrails (anti-annoyance = anti-misbehavior)

- **Cooldown** between spoken responses.
- **Rate cap** (max interjections per minute).
- **Global mute** hotkey.
- **Visible "listening" indicator** — the user always knows when Jarvis is active (also a consent cue).
- **Session counter** of tokens/calls in the menu bar, so runaway behavior is visible immediately.

## Consent Note

Capturing system audio can record the other side of a call. For personal use this is fine; if this
ever becomes multi-user (it won't in v1), two-party-consent law would require a disclosure UX.
