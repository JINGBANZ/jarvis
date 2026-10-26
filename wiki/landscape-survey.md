# Proactive Assistant Landscape

Jarvis's selection criterion is a proactive assistant that follows both sides of a spoken
conversation, consults the screen when useful, and offers short coaching cues without requiring a
typed prompt. A capture engine, meeting-notes product, or hotkey-driven answer window alone does
not satisfy the [voice-only interaction contract](./architecture.md#1-vision).

## What a reference must establish

Evaluate a candidate against behavior rather than a product category or marketing claim:

- Does it follow microphone and system audio continuously, with useful speaker chronology?
- Can it decide when to help from the conversation, including when to remain silent?
- Can the model request current screen evidence through a bounded tool loop?
- Does the overlay preserve focus, and what do actual receiving applications capture?
- Can it keep credentials and captured evidence within the required privacy boundary?

A proactive trigger and a useful coaching policy are separate properties. A tool that auto-answers
can still give unsuitable coaching; a strong capture implementation can still be a useful reference
without supplying either behavior. Capture protection requires
[measured receiving-app evidence](./overlay-invisibility.md#receiving-app-evidence).

## Reference selection

Jarvis builds the coaching harness directly. The [fork evaluation](./fork-evaluation.md) explains
the native Swift decision. For current implementation, start with
[Models and APIs](./architecture.md#models-and-apis),
[the component map](./architecture.md#3-components), and
[the security boundary](./sandbox.md#current-enforcement-boundary).

A fresh external comparison must inspect a named source revision or tested release, distinguish
hands-on observations from source inspection, and verify current licensing, availability, and
pricing at the primary source. Relative maintenance ages, unpinned code-size rankings, and old
price tables cannot establish a current adoption decision. Keep experiment details in the relevant
issue or PR; retain durable design rationale beside the design it explains.
