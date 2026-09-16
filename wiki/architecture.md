# Architecture

> A living document. Describes the vision, the harness loop, the components, and the principles
> that govern Jarvis. Exact schemas, prompts, and config are not duplicated here — they live in
> `Sources/JarvisCore/` (`Prompts/`, `Coach/Tools/`, `Config/Config.swift`).

> **Scope:** This page describes the **native Swift app**, built directly rather than on a fork of
> an existing tool; why no existing product or open-source base fit is the record in
> [landscape-survey.md](./landscape-survey.md) and [fork-evaluation.md](./fork-evaluation.md).
> Exact schemas, the coach prompt, and config are **not duplicated here** — they live in code
> (`Sources/JarvisCore/`, especially `Prompts/`, `Coach/Tools/`, and
> `Config/Config.swift`); this page is
> the *why*, the code is the *what*.

> The cross-cutting contract for isolating optional runtime work is
> [lean-coaching-core.md](./lean-coaching-core.md); every phase of its roadmap is built, and this
> page describes the resulting runtime.

## 1. Vision

Jarvis is a personal, always-on macOS assistant that **coaches you through technical interviews**:
behavioral, system-design, and coding questions. It listens to you think aloud, and — when it needs
visible context — looks at your screen to see the current question, code, diagram, or notes. When it
has something genuinely useful to add, it speaks up **unprompted** with a short tip rendered in an
on-screen overlay.

The guiding belief: **build the harness, not the intelligence.** The intelligence already exists
(the selected brain model and transcription provider). The macOS capabilities already exist
(SpeechAnalyzer, ScreenCaptureKit, AVFoundation, Vision, the built-in `screencapture` tool, NSPanel).
Jarvis is the thin layer of glue that wires them into a proactive coach. We write the least code
possible and reinvent nothing.

## 2. Core Loop

```
            ┌──────────────────────────────────────────────────────────────┐
            │                         JARVIS HARNESS                         │
            │                                                                │
  mic  ─────┤  AudioInput ──► selected Transcriber ──► transcript              │
  sys-audio ┤                       │ turn-end / silence events                │
            │                       ▼                                          │
            │                 CoachDriver ──(brain model + tools)─┐           │
            │                       ▲   │                         │           │
            │          capture_screen   │ speak(lines)            │           │
            │                       │   ▼                         │           │
  screen ◄──┤   ScreenTool ◄────────┘  Overlay (NSPanel) ◄────────┘           │
            │                                                                │
            └──────────────────────────────────────────────────────────────┘
```

Always-on and cheap: audio streams continuously to the selected transcription adapter, producing a
rolling, speaker-labeled transcript. OpenAI Realtime is the default; Apple Speech is an opt-in,
on-device adapter on macOS 26+. OpenAI defaults to automatic language recognition and lets the user
hint English, Mandarin, or both; Apple uses one user-selected locale per session. The transcript —
not the screen — is the constant input signal.

On demand and expensive: the screen is **only** captured when the model asks for it via the
`capture_screen` tool, and a coaching response is **only** produced when the model calls `speak`.
This is what keeps Jarvis cheap and fast — the costly vision and generation steps fire only at
moments the model judges worthwhile.

### The turn

1. The Transcriber emits a **turn-end** event after it finalizes an utterance (GPT-4o uses tuned
   server VAD, GPT Transcribe and GPT Live use a local Silero VAD plus an explicit acknowledged
   commit, and Apple Speech uses final `SpeechTranscriber` segments; all paths share the same client
   transcript-batching window, which groups rapid final fragments but does not establish
   cross-speaker chronology),
   or a **silence check** fires (you've gone quiet, maybe stuck). The silence check carries *how
   long* you've been quiet and backs off across a long silence (the interval
   doubles each step up to a cap — see `Config`), resetting on speech; past an idle cutoff it stops
   probing entirely (you've stepped away — a nudge into an empty room still bills a request) until
   speech re-arms it.
2. Before an automatic attempt, `TranscriptionSettlementGate` waits until both provider streams say
   that no active speech, finalization, or recovery can still produce an earlier transcript line.
   OpenAI reconnect-buffered audio remains unsettled even before replay creates a server item; Apple
   PCM silence requests `SpeechAnalyzer.finalize` and remains unsettled until matching final-result
   progress is consumed from the module stream.
   Natural triggers coalesce while waiting. Each finalized turn carries its transcript boundary, so
   a delayed transcript-batch callback arriving after another attempt committed that same line is
   consumed instead of buying a duplicate request. Any explicit coaching shortcut bypasses this wait.
   The CoachDriver then calls the brain on every trigger that carries **substance** — there is no
   cooldown, rate cap, or wake-word gate. Whether to speak (and whether the user just addressed
   Jarvis) is the model's call, governed by the system prompt; the only hard gates are the user's
   Start/Stop and the **substance gate** (`TurnSubstance`): a turn-end whose delta is pure
   clear hesitation sounds ("Hmm", "嗯", or a sequence such as "Uh. Hmm. Oh.") or empty is skipped
   without a request. Those sounds are also removed from a mixed brain-facing delta, while Activity
   keeps the complete finalized transcription. Context-dependent short replies such as "Yes", "No",
   "Okay", "对", and "可以" fail open for either speaker, as do unknown short fragments. Interviewer
   questions remain first-class and may draw a proactive tip. Consumed noise never rides into a
   later request; silence checks and both coaching shortcuts always go through. The gate is a small explicit
   class on purpose: a classifier model would add latency and cost for it, and asking the
   transcription model to drop filler is not a deterministic boundary and would silently alter the
   audit record.
3. It calls the **selected brain model** with the coach system prompt, the session memory
   (`CoachHistory`), the
   new transcript delta, the timing context (seconds silent, session elapsed), and the session's
   switched-on tool set. `capture_screen`, `speak`, and `stay_silent` are always there; `load_tool`
   and a one-line catalog entry for `search_prep_notes` join them when prep sources are configured
   and the user has not switched that capability off (see [Capabilities](#capabilities)). The timing
   is what lets the model tell "thinking" from "stuck."
4. Before speaking, the model calls `capture_screen` when a specific, correct reply depends on
   visible context missing from the conversation — including unresolved references such as “this”
   or “here” — and no fresh capture is already available for that request. It may also capture when
   a silence trigger leaves progress unclear. The harness returns a silent screenshot plus typed
   text evidence. Active-window captures always run on-device OCR over the viewport. With the optional
   Chrome text setting and Accessibility permission, bounded text from the active tab's accessibility
   tree is added as a complementary source. That
   fresh result satisfies the screen gate, so the next model response must speak or stay silent
   rather than capture the same request again. Fully stated questions do not require a reflexive
   capture.
5. The model calls `speak(lines)` — a tip of up to ~3 short lines, returned **already split**
   into an array (Structured Outputs / `strict:true`), so the client never splits prose on
   punctuation — or `stay_silent`. A tool call is **required** on every model response: silence is an
   explicit tool, never plain text. Under a "stay silent by calling no tool" contract the model still
   has to emit *something*, and at low reasoning effort that came out as leaked deliberation text
   ("final empty. no. final.") that polluted the conversation and was imitated on later turns;
   requiring a tool call prevents the emission rather than filtering it afterwards.
6. Activity records every brain action, through the session's one evidence handle: successful or
   failed `capture_screen`, `speak`, `stay_silent`, each prep-notes search, each capability load, and
   the fixed notice that a tip went out without the user's prepared notes. Heard rows and
   model-facing transcript deltas share `ConversationChronology`:
   occurrence time is authoritative, and insertion order breaks timestamp ties. A late-finalizing
   earlier utterance is therefore inserted before a faster later reply. When Activity reaches its
   memory backstop, Core sends the discarded insertion identities so the live DOM trims in lockstep
   and keeps using those same indices. Reopened sessions retain the same newest insertion identities
   before sorting that retained set by occurrence time. The deliberate-silence entry is human-facing
   but stays out of model memory.
7. The scheduler reports the audit facts around the decision through the narrow
   `CoachingAttemptAuditing` port: the natural trigger or pending-work wake, the indexed finalized
   lines considered by the substance gate, whether a provider call is the initial request or a screen
   continuation, and the terminal outcome. Brain clients report matching traffic through
   `BrainTrafficAuditing`; a typed task-local request attribution carries the attempt identity.
   Runtime classification and actual request inclusion are recorded separately so the evaluator can
   observe a gate miss instead of recomputing the fact under audit. `FileSessionAudit` admits these
   typed events best-effort to the bounded process worker; callers outside a persisted live session
   omit the optional observer. This stays diagnostics-only; Activity remains the human-facing record
   and provider scheduling detail remains out of it. See [session-audit.md](./session-audit.md) for
   the component boundary and lifecycle.
8. `speak` renders to the **Overlay**, one line at a time (per-line display time set in `Config`).
   A newer tip never interrupts one still showing — tips queue and play in order, so no hint is lost.

**Why the overlay never interrupts and never drops (and why direct-reply latency is a non-issue).**
The queue is deliberately strict: a tip the user may still be reading is never cut off, and nothing
is discarded. The obvious objection — "a direct *'Jarvis, help'* reply could wait tens of seconds
behind a proactive tip" — does not apply in the real use case: **in a live interview the user never
addresses Jarvis out loud** (speaking to an AI would expose it), so overlay traffic is *entirely
proactive coaching* with no latency-critical direct reply to jump the queue. The accepted tradeoff is
that a queued proactive tip can surface some seconds after it was generated; that is bounded in
practice because `CoachDriver` runs a single turn in-flight (so tips are produced no faster than one
brain round-trip) and the prompt keeps the model restrained. So the policy is *not interrupt + not
drop*, not *show-freshest-only* — and adding direct-reply priority/preemption was considered and
rejected as solving a problem the interview workflow doesn't have. (The must-reply-on-direct-address
path still works for testing/practice; it is simply not latency-critical there.)

### Capabilities

What a session can do is one value, `CoachCapabilities`, composed at Start from the user's switches,
the bundled skills, and whether prep-material sources are configured, then read by the coach loop,
which builds every request's prompt and tool list from it. One value fixed at Start is the whole
point: a set that grew or changed shape mid-session would change what a brain was told it could call
between two requests of the same conversation, and a route can move between brains over one shared
history.

A tool carries its own usage guidance (`ToolDef.guidance`) and a deferred flag. A **hot** tool is
declared with its schema and its guidance from the first request: the tip style is `speak`'s
guidance, because `speak` is the tip. A **deferred** tool appears only as one catalog line, its name
and its one-sentence description, and the model calls `load_tool` to receive its schema and
guidance as a tool result, after which it is declared and callable for the rest of the session. So
the prompt describes exactly the tools the request carries, and the guidance for a tool the model
cannot call is not in the prompt at all. Jarvis defers on every brain in the same way rather than
using a provider's own tool-search feature: the route can move between brains mid-session over one
shared history, and a plain tool result replays on any of them.

A **skill** is coaching guidance for a kind of question, bundled as
`Sources/JarvisCore/Resources/Skills/<name>/SKILL.md` in the agentskills.io format: frontmatter
naming the skill and describing it in one line, then the body. `SkillCatalog` reads and validates
them at Start (a small hand-written frontmatter reader — two keys do not warrant a YAML dependency
in a package that builds under Command Line Tools alone), and a file it rejects costs its own
guidance, never the session. The switched-on skills are the second catalog; `load_skill` returns one
body, framed as an extension of the action policy and tip style so the directives inside it read as
instructions rather than as data. A skill never becomes a callable tool, and its body is never in
the prompt.

Nothing preselects a skill at Start. The model reads the one-line description and loads what the
question in front of it needs, which is what lets one session coach a behavioral question and then a
design question. The alternative of a runtime classifier adds a model call and a wrong answer to
recover from; concatenating every skill into the prompt pays for all of them on every request and
was what a single "general technical" skill existed to work around. The description is written for
the model, with an example, because that line is all it sees before deciding.

A load belongs to the attempt that made it and becomes session state only when that attempt commits
a turn. An attempt that fails simply loads again, at the cost of one round trip, and in exchange
"already loaded" is true exactly when the loaded content is in history the model can still read. Compaction
keeps those pairs verbatim under the summary for the same reason ([`CoachHistory`](../Sources/JarvisCore/Coach/CoachHistory.swift)).

`search_prep_notes` is the first deferred tool. It is in the catalog when prep-material *sources* are
configured and the user has not switched it off. "Configured" is deliberately not "an index exists":
building the index reads files and shells out to `textutil`, so it runs off the Start path and the
search port arrives after the first
attempts. A search that finds no index says so and coaching continues without the notes. That is the
honest answer, and it costs nothing, where changing the offered set mid-session would cost the whole
session. The same answer covers indexing that finished with nothing usable, because the builder
installs no port in either case; which one it was stays in `jlog`, and Activity carries only the
fixed notice that a tip went out without the user's own material. Switching the capability off also
skips the index build, so the file reading and `textutil` work stop with it.

Prep material is shared across interview types: `.md`, `.txt`, `.pdf`, and `.docx` sources can all
supply behavioral, coding, or system-design preparation, including mixed-topic documents. No skill
or topic filters sources by file format. Extraction depends on the file format; coaching depends
on the question and retrieved evidence.

Prep search uses local keyword ranking over paragraph chunks. Only `.md` sources receive Markdown
handling; plain text and extracted PDF/Word text retain paragraph-based chunking without interpreting
literal hash or pipe characters. Markdown section boundaries keep short stories with their accuracy
notes. Consecutive headings stay with their first content block, including the first group of an
oversized table; trailing headings without content are omitted from the search index because they
supply no evidence. The source file is unchanged. Fenced code blocks stay intact, including blank
lines; indented code is not interpreted as headings or tables. Recognized leading/trailing-pipe
tables with an explicit delimiter row split between rows and repeat their column headers, including
when a table immediately follows a heading without a blank line. Comparison rows remain
interpretable and a question map does not become one oversized search result. Unsupported Markdown
constructs retain paragraph behavior. Long prose paragraphs, fenced code, individual rows with their
headers, and a heading plus its first content block can exceed the target; long sections can still span chunks
(see [`PrepMaterialChunker`](../Sources/JarvisCore/PrepMaterial/PrepMaterialChunker.swift)).

Search guidance normally calls for one query per topic. When the results only point to a named
story or section and lack usable facts, the model may make one focused follow-up using that title
and identifying details, then stops searching. Empty or unavailable results do not authorize a
retry. Resolving an explicit reference lets the coach supply the answer content instead of asking
the candidate to consult a document index during the interview. This bounded exception is shared
by all prep formats and interview topics; it changes guidance, not the search index or runtime
scheduling (see [`SearchPrepNotes`](../Sources/JarvisCore/Coach/Tools/SearchPrepNotes.swift)).

The behavioral skill evaluates all returned excerpts against the exact question and distinguishes
personal events from drafts, hypothetical approaches, and criteria. For a new question, the opening
hint pairs the specific behavior or reasoning a strong answer would demonstrate with supported
answer content or a focused recall question. This assessment focus is inferred from the question,
without claiming private interviewer intent or inventing company criteria, so the candidate can
choose and emphasize relevant evidence. Follow-up hints address the current gap without repeating
that framing, and sufficient answers still call for silence. Hints do not rely on story IDs, section labels,
or unexplained project shorthand. Compact wording preserves each action's owner and status and each
metric's qualifier. When no supported story fits, the coach asks for a real example or identifies
the missing fact. A retrieval miss cannot establish that the candidate has never had that experience
or authorize invention.

A call to a tool the session does not offer, or a load naming something it does not have, is answered
with a plain "no tool named X is available" rather than failing the attempt. The per-attempt response
cap is 7, leaving room for loading a skill and tool, an initial search and its permitted reference
follow-up, a capture, and a terminal coaching action.

`capture_screen`, `speak`, and `stay_silent` have no switch: Jarvis cannot start without screen
capture, and a turn cannot end without one of the other two. Neither loader has one either, because
each is composed only while its catalog has something left in it. See
[settings-window.md](./settings-window.md) for the user-facing card.

A [coaching shortcut](#on-demand-coaching-shortcuts) press runs this same loop, so even the first press
of a session can load the skill or tool its question needs and search prep notes, and its loads commit
when it speaks, like any attempt's. What a press may call is narrowed on each response instead: every
callable tool except `stay_silent` and `capture_screen`, since its screen is already in the first
request, and the response at the cap is forced to `speak`. A press therefore always ends in a tip and
never runs out of responses. When `speak` is the only tool left, the request is the plain forced
`speak`, one round trip. On the OpenAI API and Codex the narrowing is an
`allowed_tools` choice over the unchanged declared array, which keeps the cached prefix of automatic
attempts (`BrainAccessor.encodeBody`). Claude Code can neither force nor narrow a call, so
its request declares only the permitted tools under `tool_choice: auto`
([Subscription targets through the bundled proxy](#subscription-targets-through-the-bundled-proxy)).
The accepted cost is a round trip for each first load and each search, and the client resends the
whole input, screenshot included, on each one. One load followed by a
forced `speak` was rejected as too narrow: the shortcut is the fallback for a need the automatic path
missed, so it should not be the less capable of the two.

The runner checks every reply against the tool choice its own request sent instead of trusting the
transport to enforce it, because Claude Code's set is only the tools it declares and the
Codex's path forces parallel calls, so a reply can call outside the set or carry more
than one call. A call outside the permitted set is answered with a tool result saying it is not
available on a press, and a call whose arguments the typed parser (`ToolInvocation.parse`) cannot use
is answered with its tool's schema; either way the model is asked again in the same attempt. The
parser is deliberately more lenient than the schema, so a call the schema would reject but the parser
can use still runs. The response's first call is the one judged, whether or not it parsed. A press speaks its reply's prose instead,
the first three lines recorded in history as a `speak` call: in place of that round trip when the
reply calls outside its set or calls nothing, and on the response at the cap whatever it called.
When a response carries several calls, the first runs and each other one is answered as not
executed, so a replayed call never lacks a result. The forced response at the cap has no later
response to answer into, so an unusable reply there with no prose fails the attempt and the
[ordered route](#ordered-provider-route) retries. An automatic turn whose reply is prose alone fails
the same way, since it must choose between `speak` and `stay_silent`. Answering instead of failing is
deliberate: a failed attempt costs the route's retry delay, and on a press it leaves the user waiting
for a hint they asked for ([`CoachAttemptRunner`](../Sources/JarvisCore/Coach/CoachAttemptRunner.swift)).

### Private architecture hints

The model can attach a visual sketch to `speak` during the high-level-architecture stage of a design
discussion. The nullable diagram field is part of the one `speak` schema on every brain and in every
session, so a route that moves between brains never meets a `speak` it cannot parse. Prompt text
alone governs it: the tip style says to leave it null unless a loaded skill
asks for a graph, the field's own description says the same, and the system-design skill is what
asks. The runtime renders any graph it can parse and classifies nothing — a gate on a session type
is exactly what the capability model removed, and a stray diagram in a session that loaded no skill
is a prompt fix. Keeping it on `speak` also means a diagram arrives with its tip and never costs a
response of its own.

[`DiagramHint`](../Sources/JarvisCore/Overlay/DiagramHint.swift) accepts a bounded Mermaid subset:
rectangular labeled boxes and directed connections. The parser owns the precise grammar and limits;
the model-facing usage guidance lives in the system-design skill. Native
[`DiagramHintImage`](../Sources/JarvisOverlay/DiagramHintImage.swift) draws that inert graph into a
memory-only image inside [`DiagramHintView`](../Sources/JarvisOverlay/DiagramHintView.swift), a pinned
bottom area of the Overlay Box. This limited renderer needs no JavaScript, browser, remote assets,
or extra window. The area appears only after a valid diagram arrives and remains outside the
scrolling hint history for the rest of the session. Ordinary hints and clearing history preserve it;
a valid revision replaces it, while missing or invalid graph output leaves the previous design intact.
Stop discards the reference and a fresh Start has no reserved diagram space. An enabled but empty
code area yields its space to the diagram. This keeps the design available during later tradeoff
discussions without requiring repeated model output.

Graphs retain their layout and scale uniformly within the pinned area's width and height, reserving
room for the text history. They resize during a window drag. The Overlay Box settings include a
persisted **Show diagrams** switch, enabled by default, that hides or restores the latest graph
without discarding it. Collapsing the box hides the area and expanding restores it. Settings preview
never restores a graph from an ended session.
The existing nonactivating panel, capture exclusion, visibility toggle, and Start/Stop rules apply.
Nothing is drawn on the interviewer's shared canvas.

Invalid or unsupported graph syntax degrades to the same text hint, with diagnostic detail only in
`jlog`. Activity records the text tip; graph source follows the existing brain-history and wire-audit
path, and rendered images are never archived. The pinned graph is the latest suggested sketch,
not a continuously synchronized model of the discussion.

### On-demand coaching shortcuts

Hints and explanations are proactive. The shared coach prompt distinguishes needing a next step
from not understanding the question, earlier guidance, or the overall approach using the available
session history, newest speech, and current screen. Clear confusion warrants an explanation; silence
or unchanged code alone does not. Repeated confusion calls for simpler framing or a smaller example,
while productive progress calls for silence. This policy applies to every kind of question without
a separate classifier, timer, or model request.

Three configurable global shortcuts are fallbacks for a missed need: **Give me a hint** (default
**⌥⌘J**) requests the next useful hint; **Explain more** (default **⌥⌘E**) explicitly requests
clarification of the relevant gap, which may span several earlier hints; **Show code** (default
**⌥⌘K**) requests the next small coding component. All snapshot a fresh screen into the first
request, include the available conversation, and always end in a tip: a press may load a skill or
tool and search prep notes first, but never stays silent or captures again (see
[Capabilities](#capabilities)). If capture fails, the
request identifies the missing screen and uses available context without inventing visible details.
They share the ordinary single-flight coach loop and provider route. Natural wakes preserve pending
manual intent; the latest explicit shortcut chooses its kind. A fresh manual press may bypass unsettled
transcription, while an automatic retry waits for settlement. Stop cancels any request; while stopped,
an explicit shortcut only beeps. Activity records which shortcut was pressed.

The `speak` action keeps short `lines` for captions and an optional plain-text `explanation` for fuller
clarification in the persistent box. The prompt targets roughly 60–120 words in short paragraphs,
with a simple rationale, a concrete example when useful, and one starting action. The box scrolls to
the beginning of that entry and preserves its paragraphs. Hints use semibold text; fuller detail uses
regular text at the same configured size under an **Explanation** label, separated by whitespace.
Captions retain only the standalone summary.
[Enable explanations](./settings-window.md#shortcuts) controls both automatic detail and the manual
fallback. `SessionPlan.explanationsEnabled` is fixed at Start and preserved across screen-plan
revisions. Only enabled sessions receive explanation guidance in the system prompt; saved edits take
effect on the next Start, keeping one session's instructions stable. The nullable tool field remains until
[#273](https://github.com/JINGBANZ/jarvis/issues/273) establishes session-composed tools.
At delivery, the runner checks whether the persistent box can show detail. Hidden explanations are
omitted from both Activity and committed tool-call history. This live visibility check also covers a
box hidden while the request was running. Disabling the box turns off the saved explanation setting
and releases its shortcut; enabling the box does not implicitly enable explanations.

Explanation text follows the existing coaching history and Activity paths. It opens no extra window,
never activates Jarvis, and respects the box's enabled/session visibility. Disabling the box leaves
only the brief caption if that surface is enabled; it does not force a hidden surface on.

**Show code with hints** enables matching snippets, defaulting off. `SessionPlan.codeEnabled` is
frozen at Start, preserved across screen revisions, and is the whole gate: only an enabled session
reserves the code area and receives the shortened code guidance in its fixed system prompt. Nothing
in the runtime asks what kind of question this is — that guidance is what keeps a snippet off a
conceptual hint, by telling the model to leave `codeSnippet` null when no implementation would
help. The Show code shortcut
requests the next snippet; it never edits the preference or enables code during a disabled session.
Saved settings take effect on the next Start. Tool-field removal is deferred with explanations to #273.
The fixed `speak.codeSnippet` schema carries language, placement, code, and corrected-line indices;
[`CodeSnippet`](../Sources/JarvisCore/Overlay/CodeSnippet.swift) bounds and validates it without
truncating code. Highlight arrays are bounded before normalization, and trimming leading blank lines
rebases correction indices. Invalid attachments retain the useful text hint. The prompt requests one logical
component matching visible names, language, and structure. Its guidance favors straightforward syntax,
explicit control flow, and intermediate variables that candidates can follow under interview pressure.
Readable expansion is allowed within the snippet bounds; panel space is handled by font fitting and
scrolling rather than dense expressions. Local mistakes include a highlighted
correction and relevant next lines; an invalid overall approach receives a corrective hint instead.
Without visible code, known problem context supports a first component without inventing unseen names.

[`OverlayBoxPanel`](../Sources/JarvisOverlay/OverlayBoxPanel.swift) pins the snippet in a separate
bottom scroll area inside the existing capture-excluded panel. The horizontal divider adjusts
its height by dragging or through VoiceOver increment/decrement actions. The chosen proportion
survives new hints, clear, collapse/expand, and panel resizing for the current session; a new session
restores automatic content sizing. Adjustment preserves space for hints and uses the same bounds
for pointer and accessibility input, without activating Jarvis or taking keyboard focus. Its dark background defaults to opaque
and has its own opacity, independent of the history fill (see [Overlay appearance](./settings-window.md#overlay-appearance)). Long code lines wrap within the dock without changing
source text or correction highlights. The dock measures wrapped content to use available space;
code uses its configured compact monospace size and shrinks only as needed to fit, down to a readable minimum
(see `CodeSnippetView`). Very small panels retain vertical scrolling rather than clipping code or
shrinking it indefinitely. A new code snippet replaces the pinned snippet. Hints without code
leave it in place so the user can keep reading while the conversation continues; those hints
record no new code in Activity or committed tool history.
Dismiss, session clear, and Stop remove the snippet. While enabled, an empty code area remains reserved;
a session started with code off has no dock. The dock collapses
with the header and restores its snippet on expansion. Settings preview
follows saved code enablement while stopped and restores the real snippet on close. The caption carries
only the short hint; Activity includes the accepted placement and code. Explanation preferences do
not govern code. Box visibility and code acceptance are checked together on the main actor at delivery;
a hidden snippet is also removed from committed tool history and Activity. Disabling the master box
releases the shortcut, disables the saved code setting, and clears/disables the current code dock.
Re-enabling the box alone does not restore the dock; code must be enabled before a new Start.

Shortcuts use **Carbon `RegisterEventHotKey`**, which needs no Accessibility/TCC permission.
[`CoachingShortcut`](../Sources/JarvisCore/Config/CoachingShortcut.swift) provides stable event identities;
`HotkeyController` dispatches only matching Jarvis events. Each binding persists independently through
`HotkeyPreferences`. Registering a replacement happens before releasing the old binding, so a
collision—including another Jarvis shortcut—keeps the prior working binding. See
[Settings → Shortcuts](./settings-window.md#shortcuts).

## 3. Components

| Component | Responsibility | Built on (borrowed) |
|---|---|---|
| **SessionComposition** | Own one session from an accepted Start to coaching ready, capture-heartbeat handling, and Stop, over an `AudioSource` (`Sources/JarvisApp/Capture/AudioSource.swift`) the caller supplies. Production passes `AggregateEchoCapture` and keeps the default screen capture, `WindowScopedScreenCapture`; the [live e2e mode](./live-e2e-tests.md) passes `FixtureAudioSource` and `FixtureScreenCapture`. One composition is what lets the live e2e run exercise the production Start path with only the audio and the screen substituted, instead of a second copy of the wiring that could drift from it. `AppDelegate` keeps Start validation and preflight, readiness rendering, the global shortcuts, the menu, Settings, and Activity; `JarvisReadiness.activeSession` is the one readiness token both check callbacks against. | Composition over the components below. |
| **AggregateEchoCapture** | The whole capture path: one **private Core Audio aggregate device** = the built-in mic (`me`, clock master) + a system-output **process tap** (`them`, drift-compensated onto the mic's clock). A single IOProc delivers both sample-synced at the device's **native rate** — the one-clock case AEC3 needs; the capture **reads that rate and resamples mic+tap up to 48 kHz** for AEC3 (a no-op when the device is already 48 kHz). So **any input device works** — built-in, USB, 44.1 kHz gear, or AirPods (Bluetooth HFP at 16/24 kHz) — instead of the old hard 48 kHz pin that silently failed to start on Bluetooth mics. Inside the callback it runs AEC3 (tap = far reference, mic = near), removing the other side's speaker bleed from the mic *before* transcription — no headphones, and double-talk works (measured 30–50 dB cancellation). The untouched resampled tap remains the `them` source while a separate padded/truncated copy aligns AEC; wire delivery is serialized off the realtime IOProc. When a client-commit model is selected, separate Silero VAD instances score these post-AEC streams (resampled to 16 kHz) on the delivery queue rather than the IOProc, and emit content-free turn edges. Both sides then downsample to 24 kHz. Replaces the old separate `AVAudioEngine` mic + `SCStream`. | Core Audio (`AudioHardwareCreateProcessTap`, private aggregate device, drift compensation) + `AVAudioConverter` resampling + WebRTC **AEC3** + **Silero VAD** via Core ML. |
| **WebRTCEchoCanceller** | AEC3 echo canceller driven at 48 kHz on 10 ms frames inside the capture IOProc; far reference first, then the mic cleaned in place. | WebRTC **AEC3** (`webrtc-audio-processing`), vendored static + zero-dylib via `scripts/build-aec.sh`. |
| **ErrorReporter** | The single funnel for user-facing failures. Severity on a Foundation-only `UserFacingError` decides the lifecycle consequence; an explicit startup/runtime context decides presentation. Startup failures may alert, but runtime failures never activate Jarvis or present UI even when they stop the session. `ProviderFailure` feeds attempt outcomes into the finite provider route; cycle exhaustion uses the session recovery policy. Fixed, typed Activity outcomes carry stable on-disk identities while raw detail stays in `JarvisLog`. | AppKit (`NSAlert`) for startup only. |
| **JarvisReadiness** | Compose the selected session's permission, credential, brain preparation, transcription preparation, endpoint, and capture-health snapshots into one typed status: checking, blocked, recovering, fully ready, microphone-only ready, cycle failed, or stopped. An opaque Start generation rejects stale callbacks. Focused subsystems keep owning their own mechanics; this Foundation-only component emits effects that the app renders in both the menu and Activity. | Foundation-only state reduction over `CaptureReadinessMonitor` and typed app observations. |
| **Transcriber** | Maintain a rolling, speaker-labeled, **spoken-time timestamped** transcript; emit transcription-work state, transcript-bound turn-end, and backing-off silence events (with quiet duration). Two instances run in parallel — one per side — tagging lines `me`/`them` into one shared transcript through the provider-neutral `TranscriptionSession` port. The default OpenAI adapter keeps its per-`item_id` reconciliation, delta salvage, acknowledged readiness, ping/pong health, and transactional reconnect path; PCM captured while its socket is unavailable is itself pending recovery until replacement replay reaches a terminal boundary. GPT-4o Transcribe remains its default model and uses tuned server VAD. GPT Transcribe and GPT Live Transcribe remain opt-in with a local Silero VAD: a bounded pre-roll opens at confirmed speech onset, active speech and trailing silence enter the ordered audio FIFO, and indefinite idle silence stays off the wire. Endpoints commit only after that FIFO reaches their boundary, and the server's commit acknowledgement binds each boundary to its `item_id`. GPT Transcribe also reports detected completion languages to debug diagnostics. Both new models receive fixed context for the captured speaker role, and GPT Live additionally requests low transcription delay. The opt-in macOS 26+ Apple adapter prepares one selected-locale asset before capture, converts the existing 24 kHz PCM to `SpeechAnalyzer`'s preferred format, and commits final results only. Its content-free local activity tracker requests analyzer finalization after speech; `TranscriptionFinalizationState` keeps work unsettled until the analyzer completes and matching module-result progress is consumed, including speech or setup races, without gating transcription or retaining PCM. Every path keeps unusable words diagnostic-only and records content-free boundary evidence. | OpenAI Realtime transcription (model-compatible server or local turn detection) or Apple `SpeechAnalyzer` / `SpeechTranscriber` (on-device). |
| **ConversationChronology** | Own the ordering rule for conversation-derived data in Foundation-only Core: both speaker streams use one session time origin, event occurrence time comes first, and stable insertion order breaks ties. It preserves append-index provenance while producing chronological views for the model, live Activity, and reopened sessions. | `TranscriptLine.at` and Activity event timestamps. |
| **CoachDriver** | Coordinate one single-flighted coaching attempt from a natural trigger or pending-work wake-up: admit every automatic attempt only after both transcription streams settle, consume a deferred turn whose transcript boundary is already committed, snapshot one route target plus the latest chronological conversation, route its tool calls, commit only a complete terminal action, and report one outcome to the scheduler. No speaking cooldown/rate cap — restraint is the model's; `TurnSubstance` removes only clear hesitation sounds from mixed deltas and skips a turn-end when no substantive text or saved observation remains. | The selected route target: the OpenAI API, or a subscription through the bundled helper, all on the OpenAI Responses wire shape; see [§4 Subscription targets through the bundled proxy](#subscription-targets-through-the-bundled-proxy). Provider-specific summary tiers are defined in `BrainModelCatalog`. |
| **[Session evidence](./session-audit.md)** | Carry every optional record a live session produces — the human Activity story, attempt provenance, provider traffic, and agent-facing diagnostics — through one bounded worker, per-session handle, and close lifecycle, without coupling any of it to coaching behavior or latency. One uniform best-effort loss contract, and a versioned health marker that keeps incomplete evidence honest to both the evaluator and the reader. | Foundation-only owner-only session artifacts. |
| **LocalProxySupervisor** | Keep the bundled CLIProxyAPI helper serving the subscription targets for the app's whole run: start it on demand, prove each sign-in from its model list, restart a crashed helper on the same endpoint, and run a browser sign-in only on the user's click. It never routes: a subscription it cannot serve becomes an unavailable route target. See [§4 Subscription targets through the bundled proxy](#subscription-targets-through-the-bundled-proxy). | CLIProxyAPI child process on loopback HTTP; `Process`. |
| **ScreenTool** | Fulfill `capture_screen`: silently shoot the **active window** (default scope) — the window-server frontmost, on whichever display, clean even when partially covered — and attach current-viewport OCR. If the user enabled Chrome text and granted Accessibility, a read-only adapter also extracts bounded semantic text from that exact window's active tab. The screenshot remains the authority for diagrams, layout, and visible exact-token claims. Falls back to a full-display capture (no text evidence) — the Settings-chosen display in Entire-display scope, the main display when no window is eligible; the overlay window is excluded either way. See [settings-window.md](./settings-window.md#capture-scope). | macOS `screencapture` CLI + Accessibility + Apple Vision (`VNRecognizeTextRequest`). |
| **Overlay Caption** | Render `speak` output: up to ~3 short lines (model-split), shown one at a time and queued so a newer tip never cuts off the current one; non-activating, always-on-top, excluded from capture. Switchable from Settings — **off by default**; when off, tips are suppressed. | AppKit NSPanel; `OverlayCaptionPanel`. |
| **Overlay Box** | A persistent window logging every `speak` tip in full, timestamped — the scrollable history of what the caption flashed one line at a time. Movable, resizable, translucent, also excluded from capture; switched on/off from Settings (**on by default**). Its own header carries the box's controls: **collapse** on the left, which rolls the panel down to the header strip and back without losing the size the user dragged to, the name in the middle, and **clear** on the right, which appears only when there is something to erase. The header's proportions are derived from the box's height (`OverlayBoxChrome`) rather than fixed, so the strip stays aimable at the floor of `Defaults.Overlay.Box.heightRange` and stays chrome on a box dragged to fill a display. A borderless window advertises no resize affordance, and macOS refuses to let an inactive app set the cursor, so the box draws its own (`OverlayBoxResizeAffordanceView`): the edge or corner under the pointer lights up, on an `.activeAlways` tracking area, which is what reaches a background app. That view also owns the drag, so the region that lights is the region that resizes. Its thin edge grips are the only thing that refuses a window drag, because AppKit applies `mouseDownCanMoveWindow == false` to a view's whole frame: a full-size view refusing it freezes the box in place. It follows the session: shown on Start (cleared and rolled open, for the new conversation) and hidden on Stop. Its size persists across launches; its position does not, so it opens centered. Fed by the same `speak` call as the caption via **`BroadcastOverlay`**, which fans one `OverlayRendering.render` out to both sinks (so `CoachDriver` is unchanged). System-design diagrams remain pinned below the scrolling history in this same box; the caption remains text-only. See [Private architecture hints](#private-architecture-hints). | AppKit NSPanel; `OverlayBoxPanel`. |
| **MenuBar** | Manual **Start/Stop** of the pipeline (no auto-start), the same authoritative readiness status shown by Activity, and one-time API-key entry when OpenAI is in use. Stopped and active use a boxless monochrome eye: closed on the Listening Lens's diagonal axis while stopped and open while active, with the active icon following the system menu-bar foreground instead of a brand color. The attention states retain the lit Listening Lens tile — amber while checking or recovering and red when a Start is blocked before any session begins — and the menu and tooltip name the requirement behind those attention states; stopped is simply labeled `Jarvis is stopped`. A failed system stream may degrade to microphone-only, while a failed microphone stream stops the session. The two overlay surfaces are switched from Settings, and the Overlay Box is cleared from its own header, not from the menu. A centered, disabled caption at the bottom of the menu names the running build, so a user can report it without opening Settings: a release shows a muted `v<version>` from `CFBundleShortVersionString`, and a local build shows a red `Dev`, keyed off the development marker `scripts/build-app.sh` stamps into the assembled bundle (see `MenuBarController.buildCaptionItem()`). | AppKit menu-bar item; owner-only file for the key. |
| **HotkeyController** | Register the independent hint, explanation, and code shortcuts and route each press to its manual coaching request while a session runs (beep otherwise). See [§2 On-demand coaching shortcuts](#on-demand-coaching-shortcuts). | Carbon HIToolbox (`RegisterEventHotKey`, no TCC). |
| **PermissionGate** | Gather every TCC grant at launch instead of mid-session, and keep Jarvis closed until it holds all three: one button walks Microphone, System Audio Recording, and Screen Recording one dialog at a time, and closing the window quits. `SystemAudioPermissionProbe` proves the silently-enforced system-audio grant by playing a muted tone into a tap of Jarvis's own process and listening for it. See [§3 Permissions](#permissions). | AVFoundation, `CGRequestScreenCaptureAccess`, Core Audio process taps. |

Each component has one job and a narrow interface. The CoachDriver is the only place the
"intelligence" lives, and even there the intelligence is the model — the driver just wires events
to tool calls and enforces safety.

### Capture: device-rate adaptation

`AggregateEchoCapture` reads the input device's native sample rate and resamples up to AEC3's
48 kHz, rather than forcing the aggregate to 48 kHz. The earlier hard **pin** existed for two
reasons — AEC3 is created at a fixed 48 kHz, and the downsampler to the selected transcription
provider's wire rate (see [Models and APIs](#models-and-apis)) assumes a true
48 kHz input — so an aggregate that inherited a 44.1 kHz mic would corrupt the echo model and
mislabel the wire rate. But the pin **silently failed to start** on any device that can't do
48 kHz, notably AirPods (Bluetooth HFP runs them at 16/24 kHz). Reading-and-resampling serves both
original concerns *better* (AEC3 always gets true 48 kHz; the wire label stays correct) and works on
every device. The **one-clock aggregate is untouched** — the pin was about *rate*, not the clock;
mic and tap still come off one drift-compensated IOProc, so they stay sample-synced and the far/near
lockstep (now applied post-resample) holds. If the rate can't be read we fail rather than assume.

Alternatives rejected: running AEC at the device's *native* rate doesn't generalize (24/44.1 kHz
aren't AEC3-legal, so you resample anyway, with a variable frame size in the most delicate
component); and **bypassing AEC on "headphone" routes** is unsafe because a Bluetooth *speaker* is
indistinguishable from a headset, so a wrong bypass re-admits the echo. AEC3 therefore stays on for
all routes — it's a near-passthrough on earbuds (no acoustic echo to cancel). Caveat: AirPods *as a
mic* are HFP narrowband and low-fidelity regardless of resampling; for input quality, use the
built-in mic.

### Permissions

Jarvis needs three macOS grants (Microphone, System Audio Recording, Screen Recording) and cannot
coach without any of them, so `PermissionGate` asks for all three at launch and keeps the app closed
until it holds them. One button walks the dialogs, strictly one at a time because macOS queues them.
The window's close button quits: grant or quit is the whole choice. Nothing records that the gate has
run, because it is shown exactly when the grants are incomplete, which is also the only way back in
after a refusal. There is no Permissions tab in Settings: the hard gate makes one unreachable.

Chrome semantic text has a fourth, optional Accessibility grant. **Read Chrome page text** is off by
default and can request this grant only from Settings while Jarvis is stopped. The setting remains
off unless the grant is live. Turning it off during a session takes effect at the next attempt. It is
deliberately outside `PermissionGate`: denial or revocation leaves current-viewport OCR available and
never blocks coaching. Capture itself never prompts, and the setting is frozen into each attempt's
session-plan revision so live teardown cannot produce privacy UI.

The reason it happens at launch rather than at Start is the coaching context. A TCC dialog is system
UI that no capture-exclusion trick can hide, so one arriving mid-interview is visible to whoever the
user is sharing a screen with.

**Screen Recording is invisible to the process that asks.** `CGRequestScreenCaptureAccess` returns
false whether the user allowed or refused, and preflight keeps returning what the process started
with. A *later* launch sees the truth, so `PermissionPreferences.screenRecordingAsked` records that
Jarvis asked, and a launch that has asked before and still lacks the grant treats it as a proven
refusal. Without that, a refusal is indistinguishable from a grant awaiting relaunch and the gate
loops the user through Quit & Reopen forever.

**System Audio Recording is enforced silently.** There is no API to request it and none to read it,
and a refusal changes no observable except the audio itself: with the grant denied, tap creation, the
tap's 48 kHz format, the aggregate's channel count, `AudioDeviceStart`, and the IOProc callbacks all
behave exactly as when granted, and only the samples differ. Measured on macOS 26: 117 callbacks
peaking at 0.25 when allowed, 116 callbacks peaking at 0.0 when denied.

So `SystemAudioPermissionProbe` proves the grant by making a sound and listening for it. It taps
**only Jarvis's own process** rather than the system mix and mutes it, then plays half a second of a
quiet tone: hearing it back is proof, digital silence is proof of refusal. Scoping the tap to Jarvis
is what keeps the check invisible, since nothing the user is playing is tapped and nothing they are
listening to is muted. The private `TCCAccessPreflight` would read this grant exactly and silently,
but it can break on any macOS update, so the tone stays the check. **Grants are proved, never remembered.** Nothing records whether a grant was
held, because a stored answer reads exactly like a current one and the caller deciding whether a
session may run cannot tell which it holds. Being wrong there is the worst outcome in the design: a
denied tap still delivers frames, and `CaptureReadinessMonitor` reads frame arrival as healthy
without inspecting amplitude, so a session would report full readiness while hearing nothing from
the other side.

So proof is gathered twice, and lives only in the process that gathered it. At launch the two
readable grants are checked first, because they cost nothing and cannot prompt; system audio is
probed only when they are held, so anything missing opens the gate and lets the walk raise its
dialogs with a window on screen to explain them. Then every Start proves system audio again, ahead of the
preparation it already runs, since a menu-bar app can sit for days between launches and a grant
withdrawn in that time would otherwise reach a session. Every Start takes that path: there is no
longer a configuration with nothing to await, and nothing before the probe gates on its previous
answer, so a Start that failed on system audio is retried by pressing Start again. A probe that
cannot run proves nothing: it blocks the attempt at hand without counting as a refusal, so the
checklist keeps offering to ask rather than sending the user to a toggle that may already be on.

The one thing that persists is `screenRecordingAsked`, and it is not a grant: it records that Jarvis
asked, which no later grant or refusal makes untrue. It is cleared once the grant is observed held,
because holding it proves the asking was answered — which is what lets a later reset be treated as
undetermined and asked for again, rather than read as a refusal. Mid-session revocation is out of scope — every
way to catch it is either amplitude policing, which contradicts the rule above, or a timer. The next
Start refuses with the reason.

### Failure surfacing — startup loud, runtime ghost

Every user-facing failure flows through one `ErrorReporter`: severity on a Foundation-only
`UserFacingError` decides the lifecycle consequence while an explicit context captured at the
failure site decides presentation. Startup failures caused by an explicit Start may alert; every
runtime context suppresses alerts unconditionally, including after teardown, so a queued main-actor
report cannot reveal Jarvis during screen sharing. Permanent brain, microphone-transcription, and
audio-capture failures stop without presenting UI; the system-audio failure degrades to
microphone-only. Every brain provider crosses one typed `ProviderFailure` boundary, but provider
classification never replays a failed request inside its coaching attempt. A failed attempt leaves
capture, transcription, pending triggers, unsent transcript, and committed history intact; the
provider-route state machine decides whether to try the active target again, advance to the next
user-authorized target, or finish the finite cycle under the session recovery policy. Audio-route rebuilds separately
retry under a bounded schedule before capture is declared unavailable, and stale callbacks are
identity-guarded across Stop → Start. Each Activity row persists a stable event kind. The agentic
session evaluator reads the complete Activity file, using those kinds and the full user-visible
sequence rather than a preselected excerpt; dynamic provider and transport detail remains only in
`JarvisLog`. Route changes and final exhaustion use fixed, provider-level Activity events.
Cycle failures use typed Activity notices with the redacted provider cause; repeated attempts within
a cycle do not add duplicate notices. Raw request errors, scheduling, and failure counts remain
diagnostic detail.

Overall readiness is current UI state rather than an Activity event: `JarvisReadiness` drives the
menu and the live Activity badge from the same effect, while an opened past session shows **Ended**.
A temporary brain failure shows retrying while its finite budget remains. An exhausted cycle shows
a failed status until coaching succeeds; capture and transcription continue, and their failures keep
precedence. See the [ordered route policy](#ordered-provider-route) for quiet recovery and terminal limits.
Readiness transitions never append rows to `jarvis-activity.jsonl`; the persisted record continues
to contain only user-facing coaching, fixed failures, and lifecycle outcomes.

Ghost mode applies from a live pipeline through terminal teardown: no autonomous activation, alert,
window, browser, notification, attention request, or sound is allowed outside the nonactivating,
capture-excluded caption and box overlays. The persistent menu-bar item and user-invoked
Settings/Activity surfaces are explicit exceptions, as is unavoidable macOS privacy UI. The Core
presentation matrix is unit-tested, and `scripts/check-ghost-mode.sh` rejects unreviewed presentation
API calls from the normal test gate. Realtime health remains visible through the menu and current
Activity badge; `ErrorReporter` owns failure lifecycle and permitted startup surfacing.

OpenAI transport diagnostics use per-task URLSession metrics while preserving the shared connection
pool. DNS/connect/TLS/upload/response durations and connection reuse/proxy counts enter the existing
`BrainTrafficAuditEvent.phases` on the same provider-call record the evaluator reads. Missing endpoints
are omitted, not reported as zero. No parallel correlation stream is emitted; diagnostic fields
exclude URLs, headers, payloads, and arbitrary error text.

### Ordered provider route

Settings persists one primary target followed by an ordered list of explicitly authorized fallback
targets. A target is a provider/model pair; the shared reasoning-effort preference is snapshotted with
the route when an attempt begins. Exact duplicate targets are invalid, while two different models from
the same provider are allowed when the user deliberately places both in the list. The live route cursor
starts at the primary, only moves forward, and is session-local: automatic failover never rewrites
preferences. A successful fallback remains active for the rest of the session unless it later exhausts
its own failure budget. Stop → Start begins again at the persisted primary. Only a Settings edit that
changes route topology—the ordered provider/model target identities—installs a fresh route and resets
the live cursor between attempts. A reasoning-effort edit rebuilds clients at the existing cursor and
failure counts; the already-running attempt remains valid, so its success or failure updates route
health normally.

Saving the OpenAI API key refreshes only OpenAI clients and OpenAI transcription reconnect
credentials; it never replaces subscription clients. It preserves the route cursor and counts. An
in-flight OpenAI failure belongs to the superseded credential and is ignored, while an in-flight
attempt on an unaffected subscription retains normal success/failure accounting.

A **coaching attempt** snapshots one target and the latest provider-neutral conversation, then keeps
that target for the complete tool loop. Every provider request in that loop is made once. A complete,
non-truncated terminal `speak` or `stay_silent` commits the attempt and clears that target's consecutive
failure count. A provider error, an incomplete response, a reply the runner cannot answer within the
response cap ([Capabilities](#capabilities)), or failure after an intermediate `capture_screen` fails
the attempt once; cancellation, filler suppression, and local
screen-capture failure do not count as provider failures. The most recent completed screen observation
remains provider-neutral input for the next attempt. When a newer capture is committed, older image
and text evidence collapses to neutral stubs; raw reasoning, tool-call identifiers, and call/result
pairing from failed attempts never cross that boundary.

Failed conversation work remains pending within the cycle's retry budget and schedules another
coaching attempt after a short fixed delay. This internal wake-up does not depend on a new natural trigger. If a turn-end, silence, or
manual coaching trigger arrives first, it coalesces with the pending wake-up; the next attempt contains the
failed conversation plus every newer finalized transcript item. If nothing new arrives, the new
attempt uses the same pending conversation. Every automatic attempt waits while either transcription
stream owns unfinished work so it does not cross an earlier utterance that is about to finalize. An
explicit coaching shortcut interrupts that postponement even after the wait begins and upgrades the same
pending-work attempt to a shortcut attempt, which always ends in a hint; ordinary natural triggers remain parked until transcription
settles. `TriggerReason` remains the model-facing
reason that made coaching useful (`turnEnd`, `silence`, `manualHint`, `manualExplanation`, or `manualCode`); pending work is scheduler
state, not a fourth instruction to the model. An automatic attempt with no newer trigger reuses the
pending work's reason; when another natural trigger arrives, its newer reason describes the fresh
snapshot.

Temporary and unknown failures exhaust a target at the code-owned threshold (see
[`BrainRouteSession.failuresPerTarget`](../Sources/JarvisCore/Coach/BrainRouteSession.swift)). A proven
permanent provider-boundary failure exhausts it immediately. The next fresh attempt advances to the
next configured target; unavailable targets are skipped without synthetic provider attempts. Retries
use a fixed short delay that an incoming natural trigger may wake early, with no exponential backoff.
A successful response clears the target's failure count and preserves successful fallback selection.

A **coaching cycle** is one finite traversal of the remaining route, possibly containing multiple
attempts and HTTP requests. Exhausting a cycle keeps capture and transcription active. The icon,
menu and Activity status remain failed until a successful coaching attempt; only the first failed
cycle in a streak shows a red caption. Failures never add rows to the Box. Activity records the failed
cycle with the provider's redacted cause.

A later explicit coaching shortcut or new finalized speech starts a fresh cycle at the primary;
silence without new transcript does not. Consecutive failed cycles delay that admission by 0, 5, 15,
45, then at most 120 seconds. New input coalesces during the cooldown, and the admitted attempt
snapshots the latest conversation. Any successful terminal coaching action resets the cooldown and
ends the failure streak.
Proven permanent target failures remain excluded for the session, including across fresh cycles and
Settings edits; when all configured targets are permanently unavailable, `brainRouteExhausted` ends
the session and Activity names the cause. A failure streak that reaches the recovery ceiling
([`BrainCycleRecovery.ceiling`](../Sources/JarvisCore/Coach/BrainCycleRecovery.swift), ten minutes)
without a success ends the session through its own `brainRecoveryExpired` reason, even without new
speech, and Activity quotes the most recent failed cycle's cause. The ceiling clock starts at the
streak's first failed cycle, not at the last success. Silence probes stop after a long quiet stretch,
so a clock measured from the last success would end an idle session on its first failure. These
terminal paths add no live presentation.

Provider clients remain owned until replacement or session teardown. Stop cancels pending/in-flight
work and the recovery deadline. This policy is implemented by `BrainRouteSession`,
`BrainCycleRecovery`, and `CoachDriver`; provider preferences remain unchanged. Stop leaves the
bundled helper running, because it serves Settings and the next Start.

```mermaid
flowchart TD
    T[Turn end, silence, manual shortcut,<br/>or pending-work wake] --> S{Either transcription<br/>stream unsettled?}
    S -- Yes, automatic attempt --> P[Keep work pending<br/>and postpone]
    S -- No --> A[Snapshot active target +<br/>latest finalized conversation]
    A --> R[Run one coaching attempt<br/>on one target]
    R -- Complete terminal action --> C[Commit conversation<br/>reset failure count<br/>stay on target]
    R -- Provider attempt fails --> U[Leave work uncommitted]
    U --> D{Proven permanent?}
    D -- No --> B{Consecutive failure<br/>budget reached?}
    B -- No --> W[Schedule a fresh attempt<br/>on the same target]
    D -- Yes --> N{Next configured<br/>target exists?}
    B -- Yes --> N
    N -- Yes --> F[Advance once<br/>schedule a new attempt]
    N -- No --> X[End cycle; apply session<br/>recovery policy]
    W --> T
    F --> T
    P --> T
```

The implementation keeps orchestration, route policy, and OS edges separate:

| Component | Responsibility | Must not do |
|---|---|---|
| Route value (`JarvisCore/Brain`) | Immutable ordered targets and validation. | Schedule work or create UI. |
| Route state machine (`JarvisCore/Coach`) | Count attempt outcomes, move forward, and emit pure transition commands. | Call providers, read preferences, or own timers. |
| Attempt scheduler (`JarvisCore/Coach`) | Own finite cycle retries, trigger coalescing, single-flight, and transcription-settlement admission. | Classify provider payloads or mutate the route directly. |
| Attempt runner (`CoachAttemptRunner`) | Run one snapshotted target's tool loop, normalize completed provider-neutral effects, commit history, and report one outcome. | Retry a failed request, choose another target mid-attempt, or schedule anything. |
| Client factory (`JarvisCore/Brain`) | Build a `BrainClient` for an explicit target and surface preflight availability. | Select or reorder targets. |
| Preferences (`JarvisCore/Config`) | Persist primary, ordered fallbacks, per-provider models, and shared effort. | Store the live route cursor or failure counts. |
| App adapters (`JarvisApp`) | Render the list editor and feed provider transcription-work/timer events into Core. | Contain retry or failover policy. |

## 4. Data Flow & Cost Model

- **Continuous (cheap):** audio → the selected transcription adapter → transcript. This runs the
  whole session; Apple Speech removes continuous audio egress and OpenAI transcription billing.
- **Per-turn (cheap):** a selected-brain call on each substantive turn-end and each silence event,
  with a bounded, mostly-cached working set. Clear non-semantic hesitation sounds are removed before
  brain input, and turn-ends containing only those sounds (from either speaker) are skipped
  client-side — free. No image unless the model asks.
- **On-demand (expensive):** a screenshot + vision tokens and available bounded screen text, only
  when the model calls `capture_screen`. A coaching response, only when the model calls `speak`.

The model is the cost governor: it spends vision tokens and screen real estate only when it
judges them worthwhile. That is the whole point of making screen capture a model-invoked tool
rather than a per-turn screenshot.

### Models and APIs

- **OpenAI brain — the selected catalog model via the Responses API** (`POST /v1/responses`), not Chat Completions:
  for the gpt-5 family, function/tool calling is the recommended (and least restricted) path on
  Responses. The tool loop is threaded with `function_call` / `function_call_output` items, with the
  model's `reasoning` items replayed verbatim ahead of the call — OpenAI's requirement for the model
  to continue its chain of thought over a tool result instead of re-reasoning from scratch.
- **Per-session memory — client-managed (`CoachHistory`).** The coach needs to remember its *own*
  prior replies (the transcript only holds user speech), so `CoachDriver` keeps the session memory
  itself and rebuilds every request as `[system] + memory + new delta`. Owning the memory is what
  keeps it small and cheap: it grows **append-only** (a byte-identical prefix, so OpenAI's prompt
  cache can reuse stable prefixes); a `stay_silent` call leaves no trace, even one a turn was refused
  or went past, so its refusal never tells a later turn that silence is off-limits, while useful
  speech and the newest screen observation survive. At conversation commit, pixels become neutral
  stubs; a newer capture supersedes older screen text, and reasoning items are dropped. Screen text
  carries the `[mm:ss]` session time it was captured, the transcript's own clock, and says the screen
  may have changed since, so a later turn reads it as evidence from then: text that still called
  itself the current viewport let a "how do I solve this" minutes later skip the fresh look the
  screen gate asks for, and the stamp without the clause still lost that look in one live run of two. Past a token
  threshold (see
  `Config.historyCompactionTokenThreshold`) the oldest span is **compacted** into a short,
  briefing written by a cheaper model (`gpt-5.4-mini`). Its size estimate
  treats non-ASCII scripts conservatively; the exact retention and topic-retirement policy lives in
  [`JarvisPrompts.HistorySummary.system`](../Sources/JarvisCore/Prompts/JarvisPrompts+HistorySummary.swift).
  Compaction uses one Core-owned workload deadline across providers and fails soft: a slow or failed
  summary leaves the full history intact for a later attempt. Server-side memory (a Conversations
  API conversation, or `previous_response_id` threading) is deliberately not used: it can only grow,
  so every screenshot and reply is re-billed as input on every later turn of a long session, and its
  single-writer lock turns one slow turn into minutes of `conversation_locked` silence. Requests are sent `store:true`
  so they stay inspectable in the OpenAI dashboard for debugging — the retention tradeoff is
  documented in [sandbox.md](./sandbox.md).
- **Coaching guidance is loaded on demand, not chosen at Start** (see
  [Capabilities](#capabilities) for the mechanism). The prompt holds Jarvis's identity, its action
  policy, and the guidance of its always-on tools; everything else is a one-line catalog entry the
  model loads when the question calls for it. Four skills ship: behavioral shapes candidate-owned
  experience answers with STAR, handles personal and hypothetical questions directly, preserves
  prep-material caveats, and reserves labeled fictional examples for an explicit practice request.
  It avoids refining an answer that is already concrete and complete; coding covers representation and invariant guidance,
  local implementation and defect diagnosis, and boundary tests for a post-completion hint the base
  policy already warrants; coding-with-ai adds guidance for directing another AI, reviewing its
  proposals, challenging an approach against constraints, distinguishing adopted code and execution
  evidence, verifying counterexamples, and checking minimal fixes against reproducing and regression
  cases. It composes with coding when offered and applies only while AI collaboration is relevant.
  Its separate catalog entry keeps that workflow conditional without a round or seniority setting
  (see [`coding-with-ai`](../Sources/JarvisCore/Resources/Skills/coding-with-ai/SKILL.md)).
  System-design supplies the stage vocabulary from requirements through
  trade-offs, and asks for a diagram in the one stage that benefits. The base prompt keeps what is
  true of every session: when to speak or stay silent, hint length, and comprehension before
  strategy. Finishing code alone still does not trigger a hint, and there is no runtime classifier
  or persisted question classification.

  A skill body describes a *kind of question*, never "this session", because a load can arrive
  mid-interview into a discussion that has already been about something else. New skills need only a
  new folder; user-supplied skill files are not supported. `SkillCatalog` probes the installed-app,
  SwiftPM, and test layouts, since packaging copies `Jarvis_JarvisCore.bundle` into
  `Contents/Resources` and `swift test` has neither.

  The composed set is frozen at Start (`SessionComposition`) and handed to the coach loop, whose
  attempt runner builds every request's instructions with `JarvisPrompts.Coach.system(capabilities:)`,
  which keeps file I/O off coaching turns. A skill's body reaches the model inside the turn, as a
  tool result, never by rewriting the system prompt, so every request in a session opens with the
  same instructions and a route switch changes none of them.
- **Transcription has its own provider, model, and language settings.** OpenAI remains the provider
  default and `gpt-4o-transcribe` remains its model default; `gpt-transcribe` and
  `gpt-live-transcribe` are opt-in comparison choices. GPT-4o stays the default because, in a
  same-input macOS 26 system-audio comparison with GPT Live Transcribe and Apple Speech, it alone
  preserved English, Mandarin, and within-sentence language switching; the evidence is directional,
  since GPT Transcribe was not compared. All use the GA Realtime API, but keep their
  model-compatible turn contracts: GPT-4o uses tuned `server_vad`, while GPT Transcribe and GPT Live
  disable automatic turn detection, keep only bounded local pre-roll while idle, and explicitly
  commit endpoints from a local Silero VAD scoring each post-AEC stream at 16 kHz. Silero, not the
  classic WebRTC VAD already inside the vendored AEC archive: that detector is biased toward recall
  and fires on impulsive broadband noise, so laptop typing near the mic held one turn open for
  86 seconds in production, and its one-bit output cannot express the hysteresis
  `SpeechEndpointDetector` runs on Silero's per-frame probabilities. The heavier alternatives were
  rejected on weight or terms: FluidAudio (ASR, TTS, diarization and a Rust XCFramework for 1 MB of
  VAD, with runtime model downloads), ONNX Runtime (tens of MB to run a 2 MB model), TEN VAD (an
  Agora non-compete that propagates to derivatives), Picovoice Cobra (closed, server-validated key),
  and Apple `SoundAnalysis` (windows of 0.5 s or more against 32 ms frames). GPT
  Transcribe and GPT Live receive fixed role-aware recording context; GPT Live also requests low
  transcription delay. Both also receive the user's free-text vocabulary glossary (Settings →
  Transcription) as literal `keywords`, biasing recognition toward jargon and names; GPT-4o
  Transcribe has no such field and ignores the setting. Automatic is the default language
  selection and sends no language hint. A single expected language guides recognition without
  translating. Multiple selections are supplied to GPT Transcribe and GPT Live and leave GPT-4o
  automatic because the older model accepts at most one language hint. GPT Transcribe's completion-language
  metadata is logged for diagnosis without entering Activity or model context. This is one
  session-level expectation shared by both speakers, not a language decision per turn; either
  speaker may switch within a sentence. The macOS 26+ opt-in is Apple `SpeechAnalyzer` with one
  `SpeechTranscriber` locale chosen
  from the framework's runtime-supported list; `SFSpeechRecognizer` is not offered on older macOS,
  because it would be a second Apple adapter with its own authorization, availability, and result
  lifecycle. `AssetInventory` installs that model before the new
  pipeline replaces a running one, and final results alone enter Activity/model context. Apple
  documents `SpeechDetector` as an optional power-saving gate that may trade away transcription
  accuracy, while its result stream does not expose usable VAD boundaries; Jarvis therefore sends
  all audio to the transcriber and uses its existing content-free PCM activity detector only to
  request finalization and postpone coaching until the matching final-result boundary is consumed.
  Both adapters apply the client-side transcript-batching window to group rapid final fragments;
  automatic model admission is controlled separately by provider work state, never by extending
  that fixed delay.
- **Gemini transcription is the third opt-in provider, over the Gemini Live WebSocket
  (`GeminiLiveSession`, `GeminiLiveTranscriber`).** The socket authenticates with the API key as a
  URL query parameter rather than a header — the only one of the three providers that does — so
  `GeminiLiveTranscriber` never logs, interpolates, or stringifies the connect URL or a `URLRequest`
  built from it (a `URLError` can embed the failing URL, key included, in its `description`); every
  diagnostic instead names the fixed, credential-free `GeminiLiveSession.redactedEndpoint`. A caught
  transport error is safe to carry because it reaches a message only through
  `TransportFailureClassifier`'s fixed table, keyed on the error code and never on the error's own
  description, and a server close reason reaches Activity only through `ProviderMessageRedaction`
  (see [One failure record](#one-failure-record-one-table-per-vendor)). Turn detection is **entirely
  server-owned**: Gemini finalizes each utterance itself and returns it as `inputTranscription`, so
  unlike the OpenAI models there is no client-side commit, no Silero endpoint scoring, and no
  ledger reconciling provisional against final items — one server final is one accepted line, mirrored
  in `RealtimeContinuityReporter`'s `expectsServerSpeechEvents: false` for this boundary. The opening
  `setup` frame carries the model, expected-language hints (`languageCodes`, `[]` selects automatic
  detection rather than an omission the server would have to guess at), the optional vocabulary
  glossary (`customVocabulary`), and the verbatim/smart mode; the socket is not usable until the
  server acknowledges it with `setupComplete` — an open socket alone does not prove the format was
  accepted. Reconnect, ping/pong liveness, and bounded offline audio buffering mirror
  `RealtimeTranscriber`'s lifecycle so the two providers fail and recover the same way from the rest
  of the pipeline's perspective, with one deliberate divergence — Gemini's `goAway`-driven
  drain-then-rotate — covered in [Resilience](#resilience). `GeminiLiveTranscriber` is a new,
  independent adapter rather than a generalization of `RealtimeTranscriber` into a shared base: Gemini
  needs neither `RealtimeTranscriber`'s per-item ledger nor its client-commit path (turn detection is
  entirely server-owned), so restructuring the OpenAI adapter — whose live socket cannot be
  unit-tested — to serve a provider that needs neither would risk the primary transcription path for
  speculative reuse. What the two genuinely share is the socket lifecycle (ready-timeout, ping/pong,
  timer invalidation, generation guards), and that part is one driver, because a lifecycle rule
  maintained twice by hand is a rule the two adapters can disagree about without either looking
  wrong: see [Resilience](#resilience). The per-item ledger, the commit path, and turn detection are
  what the adapters keep to themselves, which is what separates them.
- **The wire sample rate is a per-provider requirement, not a quality knob
  (`TranscriptionProvider.audioFormat`, `TranscriptionAudioFormat`).** OpenAI Realtime and Apple
  Speech take 24 kHz PCM16 mono; Gemini Live requires 16 kHz PCM16 mono
  (`audio/pcm;rate=16000`, sent in the chunk's `mimeType`, which must match the PCM actually sent).
  Speech carries nothing above 8 kHz that a recognizer uses, so 16 kHz is already sufficient for
  recognition — Gemini's lower rate is what its API accepts, not a deliberate quality tradeoff Jarvis
  is making. Capture resamples the shared 48 kHz AEC output down to whichever rate the selected
  provider declares, so the AEC3/downsample pipeline and `WebRTCEchoCanceller` stay provider-agnostic
  and only the final resample step varies — an exact 3:1 decimation for Gemini's 16 kHz, cheaper and
  cleaner than a Gemini-private resampler chained after a shared 24 kHz stage (a 24 → 16 kHz second
  hop at a 2:3 ratio), which was rejected for exactly that reason: it resamples twice for no benefit
  and keeps a "shared" constant that actually encodes one provider's requirement. Capturing at 16 kHz
  for every provider — the simplest option — is not available, since OpenAI Realtime requires 24 kHz.

### Subscription targets through the bundled proxy

The **Codex** and **Claude Code** targets (`BrainProvider.codexSubscription`,
`.claudeSubscription`, selected in [Settings → Brain](./settings-window.md#brain)) let the user's
ChatGPT or Claude plan pay for coaching instead of a metered API key. Both are served by
[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (MIT, Go), shipped inside the app at
`Contents/MacOS/cliproxyapi` from the pinned, checksum-verified release in
[`scripts/lib/cliproxyapi.sh`](../scripts/lib/cliproxyapi.sh). The helper holds the OAuth sign-ins
and serves them as an OpenAI Responses endpoint on 127.0.0.1, so every target goes through the one
[`BrainAccessor`](../Sources/JarvisBrainProviders/Accessor/BrainAccessor.swift) and the attempt runner
reads one wire shape. Only the endpoint, the key, and the target's tool policy differ.

A proxy rather than the vendors' own CLIs: driving `claude` and `codex` as coaching processes meant
imitating native function calls with a text protocol the model had to follow and Jarvis had to parse
back, several thousand lines of process ownership, and a prompted tool choice a shortcut press could
not rely on. Bundled rather than installed: users install nothing, and when a vendor changes its wire
format the fix is a Jarvis release with a bumped pin, not an upgrade the user has to find. The cost
is about 60 MB on disk and 20 MB per update.

- **One helper per app launch** ([`LocalProxySupervisor`](../Sources/JarvisBrainProviders/Proxy/LocalProxySupervisor.swift)).
  It starts when the saved route names a subscription at launch, when Connections appears, when the
  Brain tab needs sign-in state and a sign-in is saved, and at a Start or route edit that routes to a
  subscription. It stays up between sessions, because it is idle then and a sign-in made in Settings
  must reach it, and stops at Quit. Each launch writes an owner-only configuration named by Jarvis's
  process id, holding a free loopback port and a key that exists only for that launch; a development
  build and a release running side by side therefore never rewrite each other's file, which the helper
  would hot-reload. The helper starts with `-local-model`, so it never fetches a model catalog, and
  the configuration switches off its management panel and its injected image tool. It is ready when
  its model list answers, within ten seconds.
- **Crashes keep the endpoint.** A helper that exits after it answered restarts on the same port
  with the same key after 1, 5, then 15 seconds, so a session composed against it keeps working; a
  fourth exit within ten minutes gives up until the next explicit start. A helper that exits before
  it answers is a failed start and is not retried until asked. A Jarvis that ended without Quit leaves
  its helper and configuration behind; the next launch stops that helper, once its process is proven
  to be this executable, and removes the files.
- **Readiness is the model list.** One probe per Start or reapply: the helper lists a vendor's models
  only while it holds a credential for that vendor, so an `owned_by` of `openai` or `anthropic` proves
  the Codex or Claude sign-in. A subscription the probe cannot serve becomes an unavailable route
  target carrying a permanent failure, authentication when signed out and unavailable with the
  helper's own reason when it would not start, and the route skips it when the cursor reaches it, so
  a fallback still coaches. A Start or route edit is refused only when no target in the route can
  coach (`UserFacingError.brainRouteUnavailable`).
- **Tool policy per target** ([`ToolChoicePolicy`](../Sources/JarvisCore/Brain/ToolChoicePolicy.swift)).
  The OpenAI API and Codex are `providerEnforced`: `required`, `allowed_tools`, a
  forced function, strict tools, and verbatim reasoning replay all pass through the Codex path intact.
  Claude Code is `filteredAuto`: through the helper a forced tool is a 400 on Claude Fable
  5.1 and strips thinking on Opus 5, and `allowed_tools` is dropped, so Opus called `capture_screen`
  on a press six times in six. Every Claude request therefore sends `tool_choice: auto` with only the
  permitted tools declared, which costs a press the prompt cache from the tools block onward. Its
  reasoning floors at `low`, because `none` disables thinking and Fable 5.1 rejects that. Neither
  policy is trusted on its own: the runner checks every reply against the choice it asked for
  ([Capabilities](#capabilities)).
- **What the helper changes on the wire.** On the Codex path it deletes `max_output_tokens`, so the
  workload timeout is the output bound; forces `store: false`, so the dashboard retention described in
  [sandbox.md](./sandbox.md#data-egress) does not apply there; forces `parallel_tool_calls: true`,
  which the runner answers by running the first call; and reuses `prompt_cache_key` as the upstream
  session id, which is why Jarvis keeps that key stable. On the Claude path it drops `strict`,
  `parallel_tool_calls`, `store`, and `prompt_cache_key`, turns the effort into adaptive thinking,
  and replays reasoning items as signed thinking blocks. Without `strict`, about one Opus 5 `speak`
  in ten arrives with `lines` double-encoded as a string, which the runner answers with the schema in
  the same attempt. The helper's default cloak stays on: it presents Claude traffic as Anthropic's own
  Claude Code client so usage stays on plan limits, which moves Jarvis's system prompt behind that
  client's identity block.
- **Models.** The Codex shares the OpenAI list; an id the Codex backend does not serve
  fails at request time with the helper's `model_not_found`. The Claude list names releases the helper
  routes, which is why Haiku is the dated `claude-haiku-4-5-20251001`: the helper reads the undated
  alias as an unknown model. The Claude summarizer is Haiku; the Codex summarizer is the target model,
  since the Codex backend serves neither mini model.
- **Failures read as the vendor wrote them.** The helper returns the vendor's own error body, which
  [`OpenAIFailureClassifier`](../Sources/JarvisCore/Providers/OpenAI/OpenAIFailureClassifier.swift)
  reads for both vendors. With every credential for a vendor gone it answers 503
  `upstream_authentication_required`, a permanent authentication failure. A model it cannot route
  answers 400 `unknown provider for model`, which stays a configuration failure: the helper sends the
  same reply for a signed-out vendor and for a model it does not serve, so the Start probe is what
  names a signed-out subscription. When every credential is cooling down it answers 429 with its own
  `Retry-After`, a temporary rejection. A helper that stopped mid-session refuses the connection, an
  unreachable failure that is temporary, so the cycle fails, listening continues, and the restart on
  the same endpoint serves the next attempt. Activity gives each its own next step: sign in from
  Connections, reopen Jarvis for the sign-in service, or wait for the plan's limit
  ([`ProviderFailure+Activity`](../Sources/JarvisCore/Providers/ProviderFailure+Activity.swift)).
- **Sign-in happens only on the user's click** ([`LocalProxySignIn`](../Sources/JarvisBrainProviders/Proxy/LocalProxySignIn.swift)).
  Connections runs the helper's own `-codex-login` or `-claude-login` with `-no-browser` against this
  launch's configuration, opens the OAuth page it prints (the one browser open in this design, behind
  the Sign in click), and waits up to ten minutes for the provider to redirect to the helper's fixed
  callback port, 1455 for Codex and 54545 for Claude. A busy port ends the login with the helper's
  message. The credential lands in the auth directory the running helper watches, so no restart is
  needed, and Jarvis narrows it to owner-only. Cancel ends the login; Sign out deletes that
  subscription's credential files.
- **Measured before adoption.** A spike on 2026-09-15 drove the production client through the helper
  with the real coach prompt and tools at low effort, three repeats per scenario, and a 1280 px
  screenshot on presses. Medians in milliseconds:

  | Target | Automatic question | Capture turn 1 / 2 | Press | Outcome |
  |---|---:|---:|---:|---|
  | Codex, `gpt-5.6-sol`, provider-enforced choices | 4,813 | 2,431 / 5,120 | 6,293 | 24 of 24 calls in the permitted set, replay intact |
  | OpenAI API, `gpt-5.6-sol` | 4,982 | 1,358 / 4,075 | 5,504 | 15 of 15 |
  | Claude Code, Opus 5, filtered auto | 2,597 | 1,542 / 3,082 | 7,370 | 48 of 48 calls in the permitted set |
  | Claude Code, Fable 5.1, filtered auto | 3,440 | 2,099 / 4,404 | 9,865 | 48 of 48 |

  Coaching through the vendors' own CLIs measured 5,898 ms for a Codex text turn and 2,654 ms for a
  Claude Code text turn on the same machine, so the proxy's Codex path is faster and a Claude press
  is slower, bounded by the same fifteen-second workload deadline. End to end the
  [live e2e run](./live-e2e-tests.md) shows the same shape: a Codex press reaches its tip in about 6
  to 9 s through the proxy against 10 to 14 s through the app-server, while Claude's press and
  question times sit inside run-to-run noise.
- **Terms risk is accepted, not hidden.** Anthropic's terms prohibit intermediating Claude session
  tokens. The owner accepts that on his own account; a Claude target that stops working fails
  permanently and the route falls forward.

The session evaluator is the one place a vendor CLI still runs, as a one-shot read-only agent, not a
coaching target. `AgentCLIDetector` finds `claude` and `codex` with file probes over stable `$PATH`
entries and known install directories (nvm's versioned installs newest first, and for Codex the Codex
and ChatGPT app bundles), ignoring inherited `$PATH` entries under the system temporary directory,
where terminal launchers leave short-lived wrappers. Claude's sign-in comes from its non-billing
`auth status --json` under a short timeout, because account metadata can outlive an expired OAuth
session; Codex's comes from its auth file. See
[build-and-run.md → The live activity viewer](./build-and-run.md#the-live-activity-viewer).

### Latency

Target for the direct API path: **turn-end → first overlay line < 2s.** Transcription is continuous
(no STT latency at trigger time) and most turns are text-only. Subscription latency depends on the
vendor, model, and network behind one loopback hop through the helper; the measured medians are in
[Subscription targets through the bundled proxy](#subscription-targets-through-the-bundled-proxy),
and neither subscription promises the direct API target. The overlay reveals the already-returned
lines one at a time (paced by `Config`); the brain response itself is not streamed to the overlay.
Session auditing adds only best-effort typed-event admission to the live path. Parsing, redaction,
serialization, file I/O, bounded retention, and close behavior belong to the
[session-audit component](./session-audit.md); ordinary Stop never makes a replacement Start wait for
an older session's disk access, and Quit never waits for audit persistence.

### Resilience

The capture edge keeps two system-audio representations for different contracts: transcription
preserves every real tap sample and pads only a short/empty callback's missing silence so Realtime
VAD keeps advancing; AEC receives a separate exact mic-length padded/truncated reference. Neither
path disables AEC or changes the configured Realtime noise-reduction profile. A route switch may
briefly expose no usable input/output device, so a failed aggregate rebuild follows a bounded
exponential retry schedule before reporting terminal capture loss. Repeated notifications from the
same device transition may supersede the pending work, but share one `RetryIncident` budget; only a
successful rebuild resets it for a later incident.

The always-on legs are built to survive transient failure rather than die on it:

- **Transcription selection is explicit and session-scoped.** Start snapshots one complete
  provider-specific configuration for both speaker endpoints: provider plus OpenAI model and
  expected-language list, or provider plus Apple locale. Changing Settings affects the next Start, reconnects keep
  the same snapshot, and neither adapter silently sends audio to the other provider after failure. A
  microphone-side terminal failure ends the unusable session. A system-audio-side failure degrades to
  microphone-only and says why, unless the failure is one both sockets share (a permanent rejection,
  or a connection that never reached ready), in which case it ends the session instead
  (`ProviderFailure.endsEverySession`). Both sockets use one key and one network, so degrading on
  whichever side reports first would hide the real cause behind a system-audio notice seconds before
  the microphone side failed identically. A socket lost after it was ready is a blip local to that
  one stream and still degrades. Apple Speech and the capture device are `.local`: they share no
  account or network surface, so they never escalate.
- **An OpenAI Realtime transcription socket *will* drop** (network blips, server resets, the ~60-min
  session cap) and a Realtime session **cannot be resumed** — a dropped connection means a new
  session. A socket is not declared ready at the WebSocket handshake: the transcriber waits for the
  server's session-configuration acknowledgement under a startup deadline. Once ready, ping/pong
  probes expose an idle half-open connection before the user's next utterance; send, receive, close,
  startup-timeout, and liveness failures all classify at the edge and enter one idempotent reconnect
  path. A refused WebSocket upgrade whose status proves the request cannot succeed as sent
  (`HandshakeRefusal`, shared by both vendor tables), or a close the vendor table proves permanent,
  skips the reconnect path entirely and ends the session with its cause, because no retry fixes a
  rejected key, a denied region, or a wrong URL. A status that describes a moment rather than a
  contract, such as a proxy's upgrade timeout, keeps its retries like any other temporary failure.
  A socket that has never reached ready gets **three attempts** rather than seven (the two budgets
  `SocketLifecyclePolicy` is built with): it has nothing buffered to preserve, and every further
  attempt is silence the user cannot explain. When that budget runs out, the reported failure keeps the last observed identity and
  message and reads as unreachable rather than lost, which is what ends the session instead of
  degrading. A socket lost after it was ready keeps the longer budget, because there is a working
  session's audio to replay into a replacement. Each replacement
  socket has a generation so stale callbacks cannot damage the new one, and diagnostics label the
  `me`/`them` side, socket generation, server session, and current macOS network-path summary. While
  reconnecting, speech-eligible audio remains in one **transactional FIFO plus recovery tail**
  (`PCMBuffer`, capped at `maxBufferedAudioSeconds`); idle client-commit audio stays in the separate
  bounded `SpeechGatedAudioBuffer` pre-roll until onset. Exactly one oldest chunk is claimed at a time. A
  successful URLSession callback moves it into the in-memory tail rather than deleting it, because Realtime intentionally
  sends no confirmation for `input_audio_buffer.append`; only acknowledged item lifecycle progress
  retires a safe prefix. For GPT Transcribe and GPT Live, an explicit commit never crosses its
  sequence boundary, the returned `input_audio_buffer.committed` event binds that boundary to an
  `item_id`, and committed PCM remains replayable until the item is terminal. On failure, unresolved local boundaries are
  requeued with the unconfirmed tail ahead of audio captured
  during reconnect backoff. This closes the ready-transition, asynchronous-send, and idle half-open
  loss edges; deliberate cap eviction is logged as diagnostic metadata. Within a healthy socket,
  streamed transcript deltas survive a failed or missing terminal event. An utterance-local failure
  remains visible in diagnostics but cannot become pseudo-speech or trigger the brain; a permanent
  quota, authentication, access, or configuration rejection ends the session and records its cause in
  Activity, quoted from the provider.
  Sequence, sample, timestamp, and socket-generation checkpoints cover the capture, delivery,
  WebSocket attempt/completion, and server-event boundaries. Periodic content-free summaries and
  typed anomalies show which boundary stopped advancing. Bounded local activity intervals match
  overlapping provider turn intervals on the session audio clock, including delayed reconnect
  replay, so a quiet dip inside one provider utterance is not reported as a gap. This evidence stays in the
  owner-only session log: it diagnoses loss but cannot reconstruct words that never reached
  transcription, and none of it enters model context. VAD-only start/stop events do not
  restart silence checks without contributing context. Pending items are finalized by bounded
  stopped/active deadlines. On a recoverable socket failure, their old server IDs are cleared and
  their retained PCM is transcribed by the replacement session instead of first emitting a partial
  or gap that the replay would duplicate. Stale speech state therefore cannot suppress silence
  coaching after reconnect. Reconnect uses capped exponential backoff.
- **Both socket providers run that lifecycle from one driver
  (`SocketLifecyclePolicy`, `WebSocketConnection`).** The decisions are Foundation-only and
  unit-tested in Core: when to open, what counts as ready, which failures terminate now, and how much
  retry budget is left. The App-side driver owns the `URLSession`, the task, the generation counter,
  the three timers, and the receive and close paths, and asks the policy for each of those decisions.
  Each transcriber is that driver's adapter and supplies only what its vendor does differently: the
  request, the configuration frame, the frame reader, the two failure classifiers, and the stream
  bookkeeping a socket handoff needs.

  The split costs two locks, and the rule between them is load-bearing. The driver's lock guards
  socket state and is a leaf: the driver never calls an adapter while holding it. Each adapter guards
  its own audio and replay state, mirrors the driver's readiness under that lock, and has its
  producers read only the mirror. Every driver state change is immediately followed by an adapter
  callback that flips the mirror, so a producer sees either the whole pre-change picture or the whole
  post-change one, never a half-applied handoff. Having producers ask the driver directly would
  reopen the race the replay barrier exists to close: a producer that saw "not ready" before the
  handoff had begun would publish a barrier into the lifecycle ahead of the snapshot it belongs to.

  A rotation the server announced (OpenAI's `session_expired` or a 1001 close, Gemini's `goAway`)
  spends no retry budget and waits out no backoff delay, because it is expected churn rather than a
  fault. That freedom belongs only to a socket that reached ready. A warning on a socket that never
  worked describes a connection that is failing, and reading it as a rotation would reopen forever
  against a server that refuses every handshake, so those take the ordinary budgeted path.
- **A Gemini Live socket is capped at roughly 10 minutes, but Google gives advance warning:** a
  `goAway` frame (with a `timeLeft` countdown) arrives before the close, instead of the close simply
  happening as OpenAI's does. `GeminiLiveTranscriber` uses that warning to drain rather than just
  reconnect: `pumpIfPossible` stops sending NEW audio to the expiring socket (it keeps accumulating in
  the same bounded FIFO used for offline buffering — no second buffer), while the utterance already in
  flight gets a bounded grace period to produce its final transcript on the still-open socket. The
  bound is the smaller of a fixed cap and the server's own `timeLeft`, enforced by the same
  main-queue-confined timer discipline as `readyTimeout`/`pongTimeout`, so a lost final can never hang
  the rotation — it proceeds on the deadline regardless. Only then does it open the replacement, which
  sends its own `setup` like any new socket, and the buffered audio drains into it. Both sockets (mic
  and system audio) are opened together, so without this a session loses the transcript line in flight
  and replays audio from the middle roughly every 10 minutes — four times in a 45-minute interview.
  Because Google already warned it was coming, the rotation is not treated as a failure: it skips the
  reconnect backoff schedule entirely (no retry-budget consumption, no `.failed`), whether the
  replacement opens on the grace-period deadline, on the utterance's final arriving early, or on any
  transport failure that lands on the socket while it is draining. A very long utterance that is still
  being spoken exactly when the deadline is reached can still be split across the rotation — the
  residual limitation the drain narrows but does not close; the complete fix is Google's own session
  resumption (`sessionResumptionUpdate`), deliberately left as a follow-up (see
  [status.md → Not yet built](./status.md#not-yet-built)).
- **Apple Speech has no network reconnect loop.** Start validates macOS/device support, resolves the
  selected conversation locale to a supported equivalent, and downloads any missing asset before
  capture replaces an existing pipeline. Each endpoint then owns one analyzer and an ordered
  memory-only input stream. Apple uses one locale for the whole session; OpenAI is the intended path
  for English/Mandarin code-switching rather than parallel Apple analyzers.
  Setup uses the same bounded pre-ready audio budget as OpenAI; overflow is diagnostic. Final
  provider ranges supply spoken timestamps and continuity boundaries. The local activity tracker
  retains only adaptive level state, not PCM, and requests analyzer finalization rather than gating
  transcription input; model admission remains parked until finalization and matching consumed result
  progress agree. An analyzer, result-stream, conversion, or input-stream failure stays inside the Apple
  boundary and follows the terminal/degraded lifecycle above—never an implicit OpenAI fallback.
- **The brain call** is single-flighted (a turn can't double-speak) and runs under a Core-owned
  workload deadline shared by every target, since each is one HTTP request to the same client.
  A failed request is never replayed inside its coaching attempt. The attempt ends, sent-state and provider-neutral work remain uncommitted, and the
  scheduler makes a new attempt within its retry budget after a short delay or earlier coalesced trigger. That
  new attempt rebuilds its input from the latest committed history, the failed conversation, and
  every newer finalized transcript item; with no new speech, it simply re-attempts the pending work.
  The [ordered route](#ordered-provider-route) defines finite retries, fallback transitions, and
  bounded cycle failure. No provider is probed concurrently. Cancellation remains
  quiet. Memory **compaction** fails soft outside
  this route: a failed summary simply leaves the full history for the next attempt.
- **The audit edge** is isolated, bounded, and completeness-aware. Regular Stop drains and closes its
  old audit in a background task while a replacement Start proceeds independently. Quit seals the
  audit and returns without waiting. Capacity or persistence failure loses only affected evidence,
  leaves a sticky partial signal, and does not disable later admission. The health state moves from
  `in_progress` to one immutable terminal `complete` or `partial` state; post-seal callbacks are
  rejected instead of reopening it. The complete observer, lifecycle, privacy, and evaluator contract
  lives in [session-audit.md](./session-audit.md).

## 5. Safety Model

Enforcement-first, not convention. See [sandbox.md](./sandbox.md) for the full model. In short:

- **The current app is unsandboxed.** It is signed with a stable identity and relies on macOS TCC
  prompts for microphone, system-audio, and screen capture. It therefore has the filesystem authority
  of the signed-in user. App Sandbox with a narrow set of capabilities remains a future distribution
  target, not a property of the current build. See [sandbox.md](./sandbox.md).
- **API key in an owner-only file** (`0600`), not the Keychain — see [sandbox.md §3](./sandbox.md) for why.
- **Development happens inside a git worktree** for recoverability. A worktree does not isolate the
  process from the developer's account; a separate Standard account is optional hardening for long
  unattended agent runs. See [sandbox.md](./sandbox.md).
- **Egress is narrow and explicit:** the selected transcription provider's model receives audio —
  OpenAI Realtime when OpenAI is selected, Gemini Live when Gemini is selected — while opt-in Apple
  Speech keeps raw audio on-device; a screenshot + transcript window goes to the selected brain
  provider/model *only when the model triggers a capture/response*. Gemini authenticates its socket
  with the API key as a URL query parameter rather than a header, so it needs its own logging
  discipline — see [Models and APIs](#models-and-apis).
  The audio witness persists only counters, sequence/sample metadata, timestamps, provider
  generations, provider audio-clock values, and a local activity bit in the owner-only session
  log — never PCM or recovered words. The only screen-/audio-derived data written to **local** disk
  is the owner-only, bounded per-session record: Activity (spoken tips, deliberate-silence outcomes,
  failed-action and stop/degrade notices carrying the provider's redacted message, transcribed
  lines, and the screenshots the model saw), the coaching-attempt provenance needed to attribute those finalized lines, and redacted wire
  traffic. Raw mic audio and a separate live-transcript archive are never persisted. Requests
  are sent `store:true`, so what the model saw does remain inspectable (and retained) server-side at
  OpenAI for debugging (see [sandbox.md](./sandbox.md)).
- **Behavioral restraint (model-governed):** there is **no cooldown or rate cap during healthy operation**. Every
  substantive utterance — from either speaker; only clear non-semantic hesitation sounds are removed
  as pure cost — reaches the brain, and the brain decides whether it has anything worth
  saying — that restraint lives in the system prompt (see
  [`JarvisPrompts.Coach.system`](../Sources/JarvisCore/Prompts/JarvisPrompts+Coach.swift)).
  This keeps
  conversation natural during healthy operation. During provider failures, new speech coalesces
  within the finite cycle budget; subsequent cycles follow the [recovery cooldown](#ordered-provider-route). The hard control is
  the menu-bar **Start/Stop** — coaching never runs until explicitly started, and stopping tears the
  pipeline down entirely. Cost is accepted as tracking usage for now (a future improvement, not a
  v1 guardrail).

## 6. Non-Goals (v1)

- A tiered sensitivity dial, or code-level coaching modes with separate trigger gates or
  runtime state. One harness spans behavioral, system-design, and coding questions; the model loads
  the matching skill inside that shared loop — see [§ Capabilities](#capabilities) — and the
  scheduling stays the same whichever it loads.
- Continuous OCR or recording the screen/audio to disk ("recall").
- A dedicated wake-word engine. Direct address is just the word "Jarvis" (or a question) appearing
  in the transcript, which the brain reads and answers — there is no wake-word detector. (A global
  **⌥⌘J** hotkey for an on-demand screen hint *does* exist — see [§2](#on-demand-coaching-shortcuts) — but it
  complements the proactive default; it is not a trigger-to-listen wake key.)
- Productization: hosted auth, billing, onboarding, or arbitrary provider chains.
- Windows / cross-platform.

## 7. Design Principles

1. **Build the harness, not the intelligence.** If a model or an OS framework can do it, we don't write it.
2. **Least code wins.** Prefer a borrowed tool (`screencapture`, an Apple framework, an OpenAI API) over custom code, every time.
3. **The model is the cost governor.** Expensive actions (vision, speaking) happen only when the model opts in.
4. **Proactive, but disciplined.** Speaking up unprompted is the whole point; the model's own restraint (a tuned system prompt) keeps it from being annoying.
5. **Make sensitive capabilities explicit.** TCC, owner-only files, provider selection, and narrow
   egress are enforced today; do not claim filesystem isolation until App Sandbox is implemented.
6. **Self-verifying.** Every build ships with tests and the [live e2e tests](./live-e2e-tests.md) the agent can run to prove it works.
7. **One domain, done well.** Ship the technical-interview coach; expand later.

The same principle applies to runtime structure: the
[lean coaching core contract](./lean-coaching-core.md) keeps only outcome-affecting policy and ports
on the critical lane, while one shared best-effort evidence stack serves the Activity window and
detailed agent/evaluator investigation.

How Jarvis is built, signed, tested, and run — and the activity viewer — is its own
operational page: [build-and-run.md](./build-and-run.md).
