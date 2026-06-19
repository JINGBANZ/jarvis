# Overlay Timing

> How long each coaching line stays on screen, and why. The design *why*; the actual numbers live in
> [`Config.swift`](../Sources/JarvisCore/Config/Config.swift) and the formula in
> [`OverlayTiming.swift`](../Sources/JarvisCore/Overlay/OverlayTiming.swift).

## The problem

The brain returns a tip as a pre-split `lines` array; the overlay shows the lines one at a time (see
[architecture.md §2](./architecture.md#2-core-loop) and [the queueing decision](./status.md#key-decisions)).
The question this page answers: **how long should each line stay up?**

A single hard-coded duration is wrong — a two-word nudge and a full sentence shouldn't get the same
time. The display time should scale with the line's length. That much is also how professional
captioning works, so we started from that standard and then adapted it to our situation.

## What the captioning standard does

Film/TV subtitling sizes every cue to its text length, via a *reading speed* plus a min/max clamp:

| | Reading speed | Min on-screen | Max on-screen |
|---|---|---|---|
| **Netflix** (timed-text spec) | 20 CPS adult / 17 CPS kids | 5/6 s (20 frames @24fps) | 7 s |
| **BBC** (subtitle guidelines) | 160–180 WPM ≈ 0.33–0.375 s/word | ~0.3 s/word (≈1.2 s for 4 words) | — |
| **General consensus** | optimal 12–17 CPS | ~1 s (no "flashing") | ~6 s (two lines) |

Two equivalent metrics — characters-per-second (the modern dominant one) or words-per-minute — both
expressing "duration ∝ length," bounded by a floor (don't flash) and a ceiling (don't linger). Every
standard also mandates a **minimum gap between consecutive cues**.

Sources: [Netflix requirements](https://www.gothamlab.com/netflix-subtitle-delivery-requirements-complete-guide/),
[BBC guidelines](https://www.clevercast.com/bbc-subtitling-guidelines/),
[Amara on CPS](https://blog.amara.org/2024/10/17/crafting-accessible-subtitles-the-critical-role-of-characters-per-second-cps/),
[subtitling.net reading speed](https://subtitling.net/standards/subtitle-reading-speed).

## Why we don't just copy it

Every captioning number assumes a viewer whose **eyes are on the screen** and whose **audio reinforces
the text**. Our situation is the opposite:

- The user is mid-conversation; their attention is on the **other person**. They *glance* at the overlay.
- There is **no audio echo** — the screen is the only channel.
- Tips are **ephemeral and time-sensitive**: a coaching hint that's several seconds stale is worse
  than none, and because we **queue** tips (never interrupt), an over-long display also delays the
  next, fresher one.

The consequence: the dominant cost of consuming our tip isn't *reading* it — it's **noticing it and
redirecting your gaze**. And that cost is **fixed**, independent of line length.

## Our model — a deliberate hybrid

We keep the captioning spine, tune it to our context, and add the one term captions don't need:

```
per-line seconds = noticeBuffer + words × readingRate     (capped at a max)
+ a brief blank gap between consecutive lines / tips
```

| Element | Source | Rationale |
|---|---|---|
| Duration ∝ length | captioning standard | The proven core; a long line earns more time than a short one. |
| **Notice buffer** (fixed) | **ours alone** | Models the glance-and-redirect latency captions don't have. It also *is* the floor — a one-word line gets buffer + one word — so there's no separate minimum knob. |
| Reading rate per word | captioning standard | Near normal reading speed; the buffer already covers the glance, so this term need only cover actual reading. |
| Max cap | captioning standard, **tightened** | Lower than the ~6–7 s film cap: our tips go stale fast and an over-long one delays the queue. |
| Word-based (not CPS) | captioning standard (BBC side) | Our lines are short and uniform ("one idea per line"), so per-character precision buys little over word count. |
| **Inter-line gap** | borrowed from the captioning minimum-gap rule | Without a blank between lines, back-to-back lines read as one block and the eye doesn't re-trigger — *worse* for a glancing user than a watching one. |

The net: every line gets a noticing floor, plus reading time that grows with length, capped so the
queue stays fresh — and a blank flash between lines so a glance catches the change.

## Known limitation — per-tip total is unbounded (validate live)

The cap bounds each *line* (≈8s), not the whole *tip*. Since tips queue FIFO and never interrupt,
a worst-case 3-line tip (~6s/line under the prompt's ~12-word limit) can hold the screen ~19s and
delay a fresher queued tip — which cuts against the "stale tip is worse than none" principle above. A
per-tip total budget (scale the lines down proportionally past a ceiling) was considered and
**deferred**: in practice tips are mostly 1–2 short lines, so we'd rather judge real pacing in the
live smoke run before adding another knob. Revisit if multi-line tips feel like they linger.

## Where it lives

- **The formula:** [`OverlayTiming.displaySeconds(for:config:)`](../Sources/JarvisCore/Overlay/OverlayTiming.swift)
  — pure, Foundation-only, unit-tested (`OverlayTimingTests`).
- **The knobs:** `overlayNoticeBufferSeconds`, `overlaySecondsPerWord`, `overlayMaxDisplaySeconds`,
  and the static `overlayLineGapSeconds` in [`Config.swift`](../Sources/JarvisCore/Config/Config.swift)
  (single source of the actual values — tune them there).
- **Playback:** [`CoachDriver`](../Sources/JarvisCore/Coach/CoachDriver.swift) computes a duration per
  line and hands the array to the overlay; [`OverlayPanel`](../Sources/JarvisOverlay/OverlayPanel.swift)
  plays each line for its time and inserts the blank gap between them (`OverlayInvisibilityTests`
  covers the gap and the queue/hide behavior).
